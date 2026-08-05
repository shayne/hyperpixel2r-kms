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
identity=''
driver_version=''
overlay_file=''
kernel_release=''
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
identity="$(ssh "${ssh_options[@]}" "$target" bash "$remote_stage/lifecycle-remote.sh" identity)"
[[ "$identity" =~ ^([0-9]+\.[0-9]+\.[0-9]+)$'\t'(hyperpixel2r-kms-[0-9a-f]{12}\.dtbo)$'\t'([A-Za-z0-9._+-]+)$ ]] || {
  echo 'target returned an unsafe candidate identity' >&2
  exit 1
}
driver_version="${BASH_REMATCH[1]}"
overlay_file="${BASH_REMATCH[2]}"
kernel_release="${BASH_REMATCH[3]}"
"$repo_root/scripts/verify-boot.sh" --target "$target" --expect-tryboot \
  --expect-kernel-release "$kernel_release" --expect-driver-version "$driver_version" \
  --expect-overlay-file "$overlay_file" >/dev/null
ssh "${ssh_options[@]}" "$target" bash "$remote_stage/lifecycle-remote.sh" commit
ssh "${ssh_options[@]}" "$target" rm -rf -- "$remote_stage"
remote_stage=''
rm -rf -- "$payload"
payload=''
trap - EXIT
printf 'Committed owned HyperPixel candidate to normal boot config; reboot when ready.\n'
