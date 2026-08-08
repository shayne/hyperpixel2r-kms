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
run_lifecycle() {
  hp2r_run_remote_lifecycle "$target" "$repo_root/scripts/lifecycle-remote.sh" "$@"
}
run_lifecycle rollback
set +e
ssh "${ssh_options[@]}" "$target" 'sudo reboot' >/dev/null 2>&1
reboot_status=$?
set -e
case "$reboot_status" in 0|255) ;; *) echo "rollback reboot failed with status $reboot_status" >&2; exit "$reboot_status";; esac
printf 'Restored normal boot configuration and requested reboot.\n'
