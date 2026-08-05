#!/usr/bin/env bash
set -euo pipefail

# Promotion is intentionally a compensating transaction on target.  It does
# not leave normal config changed if restoring tryboot or deleting state fails.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$repo_root/scripts/common.sh"

target="${HP2R_TARGET:-}"
while test "$#" -gt 0; do
  case "$1" in
    --target) test "$#" -ge 2 || { echo '--target requires a value' >&2; exit 64; }; target="$2"; shift 2 ;;
    -h|--help) echo 'Usage: commit-boot.sh [--target TARGET]'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
done
: "${target:?set HP2R_TARGET or pass --target}"
hp2r_validate_target "$target"

ssh_options=(-o BatchMode=yes -o ConnectTimeout=8 -o ConnectionAttempts=1)
remote_stage=''
payload=''
commit_probe=''
commit_phase=''
expected_boot=''
driver_version=''
overlay_file=''
kernel_release=''
module_file=''
module_sha256=''
retired_tryboot_existed=''
retired_tryboot_sha256=''
verify_args=()
cleanup() {
  local status=$?
  trap - EXIT
  if test -n "$remote_stage"; then ssh "${ssh_options[@]}" "$target" rm -rf -- "$remote_stage" >/dev/null 2>&1 || true; fi
  test -z "$payload" || rm -rf -- "$payload"
  exit "$status"
}
trap cleanup EXIT
remote_stage="$(ssh "${ssh_options[@]}" "$target" mktemp -d /tmp/hp2r-tryboot-stage.XXXXXX)"
[[ "$remote_stage" =~ ^/tmp/hp2r-tryboot-stage\.[A-Za-z0-9]+$ ]] || { echo 'target returned an unsafe staging path' >&2; exit 1; }
payload="$(mktemp -d "${TMPDIR:-/tmp}/hp2r-commit.XXXXXX")"
install -m 0644 "$repo_root/scripts/lifecycle-remote.sh" "$payload/lifecycle-remote.sh"
scp "${ssh_options[@]}" -rp "$payload/." "$target:$remote_stage/"
commit_probe="$(ssh "${ssh_options[@]}" "$target" bash "$remote_stage/lifecycle-remote.sh" commit-probe)"
[[ "$commit_probe" =~ ^(tryboot|explicit-config-reconcile|explicit-replay|explicit-reconcile)$'\t'(tryboot|normal)$'\t'([0-9]+\.[0-9]+\.[0-9]+)$'\t'(hyperpixel2r-kms-[0-9a-f]{12}\.dtbo)$'\t'([A-Za-z0-9._+-]+)$'\t'(hyperpixel2r_kms\.ko)$'\t'([0-9a-f]{64})$'\t'(active|true|false)$'\t'(none|[0-9a-f]{64})$ ]] || {
  echo 'target returned an unsafe commit probe' >&2
  exit 1
}
commit_phase="${BASH_REMATCH[1]}"
expected_boot="${BASH_REMATCH[2]}"
driver_version="${BASH_REMATCH[3]}"
overlay_file="${BASH_REMATCH[4]}"
kernel_release="${BASH_REMATCH[5]}"
module_file="${BASH_REMATCH[6]}"
module_sha256="${BASH_REMATCH[7]}"
retired_tryboot_existed="${BASH_REMATCH[8]}"
retired_tryboot_sha256="${BASH_REMATCH[9]}"
case "$commit_phase:$expected_boot" in
  tryboot:tryboot|explicit-config-reconcile:tryboot|explicit-config-reconcile:normal|explicit-replay:tryboot|explicit-replay:normal|explicit-reconcile:tryboot|explicit-reconcile:normal) ;;
  *) echo 'target returned an inconsistent commit probe' >&2; exit 1 ;;
esac
verify_args=(
  --target "$target"
  "--expect-$expected_boot"
  --expect-kernel-release "$kernel_release"
  --expect-driver-version "$driver_version"
  --expect-overlay-file "$overlay_file"
  --expect-module-file "$module_file"
  --expect-module-sha256 "$module_sha256"
)
if test "$commit_phase" = explicit-replay || test "$commit_phase" = explicit-reconcile; then
  case "$retired_tryboot_existed:$retired_tryboot_sha256" in
    false:none) verify_args+=(--expect-retired-tryboot-absent) ;;
    true:[0-9a-f]*) verify_args+=(--expect-retired-tryboot-sha256 "$retired_tryboot_sha256") ;;
    *) echo 'target returned an unsafe retired tryboot identity' >&2; exit 1 ;;
  esac
  if test "$expected_boot" = tryboot; then
    verify_args+=(--allow-retired-tryboot-config)
  fi
else
  test "$retired_tryboot_existed:$retired_tryboot_sha256" = active:none || {
    echo 'target returned retired tryboot identity outside replay' >&2
    exit 1
  }
fi
"$repo_root/scripts/verify-boot.sh" "${verify_args[@]}" >/dev/null
ssh "${ssh_options[@]}" "$target" bash "$remote_stage/lifecycle-remote.sh" commit
ssh "${ssh_options[@]}" "$target" rm -rf -- "$remote_stage"
remote_stage=''
rm -rf -- "$payload"
payload=''
trap - EXIT
printf 'Committed owned HyperPixel candidate to normal boot config; reboot when ready.\n'
