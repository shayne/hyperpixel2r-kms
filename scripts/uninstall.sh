#!/usr/bin/env bash
set -euo pipefail

# Remove inactive, checksum-proven lifecycle state only.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$repo_root/scripts/common.sh"

target="${HP2R_TARGET:-}"
cleanup_legacy=false
expected_overlay_file=''
while test "$#" -gt 0; do
  case "$1" in
    --target) test "$#" -ge 2 || { echo '--target requires a value' >&2; exit 64; }; target="$2"; shift 2 ;;
    --cleanup-legacy-planeradar) cleanup_legacy=true; shift ;;
    --expect-overlay-file) test "$#" -ge 2 || { echo '--expect-overlay-file requires a value' >&2; exit 64; }; expected_overlay_file="$2"; shift 2 ;;
    -h|--help) echo 'Usage: uninstall.sh [--target TARGET] [--cleanup-legacy-planeradar --expect-overlay-file FILE]'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
done
: "${target:?set HP2R_TARGET or pass --target}"
hp2r_validate_target "$target"
if "$cleanup_legacy"; then
  [[ "$expected_overlay_file" =~ ^hyperpixel2r-kms-[0-9a-f]{12}\.dtbo$ ]] ||
    { echo 'legacy cleanup requires an exact expected external overlay file' >&2; exit 64; }
else
  test -z "$expected_overlay_file" ||
    { echo '--expect-overlay-file requires --cleanup-legacy-planeradar' >&2; exit 64; }
fi
ssh_options=(-o BatchMode=yes -o ConnectTimeout=8 -o ConnectionAttempts=1)
remote_stage=''
payload=''
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
payload="$(mktemp -d "${TMPDIR:-/tmp}/hp2r-uninstall.XXXXXX")"
install -m 0644 "$repo_root/scripts/lifecycle-remote.sh" "$payload/lifecycle-remote.sh"
if "$cleanup_legacy"; then
  contract="${HP2R_LEGACY_MIGRATION_CONTRACT:-$repo_root/release/legacy-planeradar-migration-v1.tsv}"
  test -f "$contract" && test ! -L "$contract" ||
    { echo 'legacy migration contract is missing or unsafe' >&2; exit 1; }
  install -m 0644 "$contract" "$payload/legacy-planeradar-migration-v1.tsv"
fi
scp "${ssh_options[@]}" -rp "$payload/." "$target:$remote_stage/"
if "$cleanup_legacy"; then
  ssh "${ssh_options[@]}" "$target" bash "$remote_stage/lifecycle-remote.sh" \
    cleanup-legacy-planeradar "$remote_stage/legacy-planeradar-migration-v1.tsv" \
    "$expected_overlay_file"
else
  ssh "${ssh_options[@]}" "$target" bash "$remote_stage/lifecycle-remote.sh" uninstall
fi
ssh "${ssh_options[@]}" "$target" rm -rf -- "$remote_stage"
remote_stage=''
rm -rf -- "$payload"
payload=''
trap - EXIT
if "$cleanup_legacy"; then
  printf 'Removed exact inactive legacy Plane Radar driver state.\n'
else
  printf 'Removed inactive owned HyperPixel driver state.\n'
fi
