#!/usr/bin/env bash
set -euo pipefail

# Restore the exact pre-stage tryboot file and leave normal config untouched.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$repo_root/scripts/common.sh"

target="${HP2R_TARGET:-}"
while test "$#" -gt 0; do
  case "$1" in
    --target) test "$#" -ge 2 || { echo '--target requires a value' >&2; exit 64; }; target="$2"; shift 2 ;;
    -h|--help) echo 'Usage: rollback-boot.sh [--target TARGET]'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
done
: "${target:?set HP2R_TARGET or pass --target}"
hp2r_validate_target "$target"
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
payload="$(mktemp -d "${TMPDIR:-/tmp}/hp2r-rollback.XXXXXX")"
install -m 0644 "$repo_root/scripts/lifecycle-remote.sh" "$payload/lifecycle-remote.sh"
scp "${ssh_options[@]}" -rp "$payload/." "$target:$remote_stage/"
ssh "${ssh_options[@]}" "$target" bash "$remote_stage/lifecycle-remote.sh" rollback
ssh "${ssh_options[@]}" "$target" rm -rf -- "$remote_stage"
remote_stage=''
rm -rf -- "$payload"
payload=''
set +e
ssh "${ssh_options[@]}" "$target" 'sudo reboot' >/dev/null 2>&1
reboot_status=$?
set -e
case "$reboot_status" in 0|255) ;; *) echo "rollback reboot failed with status $reboot_status" >&2; exit "$reboot_status";; esac
trap - EXIT
printf 'Restored normal boot configuration and requested reboot.\n'
