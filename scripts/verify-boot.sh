#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$repo_root/scripts/common.sh"

usage() {
  cat <<'USAGE'
Usage: verify-boot.sh [--target TARGET] [--expect-tryboot|--expect-normal] [--expect-driver-version VERSION] [--expect-overlay-file FILE] [--json]

Verify the live HyperPixel driver, generic compatible binding, DRM/input path,
and current-boot SDL renderer evidence.  --json is a versioned stable result.
USAGE
}

target="${HP2R_TARGET:-}"
expected_boot=tryboot
expected_driver_version=''
expected_overlay_file=''
json=false
while test "$#" -gt 0; do
  case "$1" in
    --target) test "$#" -ge 2 || { echo '--target requires a value' >&2; exit 64; }; target="$2"; shift 2 ;;
    --expect-tryboot) expected_boot=tryboot; shift ;;
    --expect-normal) expected_boot=normal; shift ;;
    --expect-driver-version) test "$#" -ge 2 || { echo '--expect-driver-version requires a value' >&2; exit 64; }; expected_driver_version="$2"; shift 2 ;;
    --expect-overlay-file) test "$#" -ge 2 || { echo '--expect-overlay-file requires a value' >&2; exit 64; }; expected_overlay_file="$2"; shift 2 ;;
    --json) json=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 64 ;;
  esac
done
: "${target:?set HP2R_TARGET or pass --target}"
hp2r_validate_target "$target"
if test -n "$expected_driver_version"; then [[ "$expected_driver_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'unsafe expected driver version' >&2; exit 64; }; fi
if test -n "$expected_overlay_file"; then [[ "$expected_overlay_file" =~ ^hyperpixel2r-kms-[0-9a-f]{12}\.dtbo$ ]] || { echo 'unsafe expected overlay file' >&2; exit 64; }; fi
ssh_options=(-o BatchMode=yes -o ConnectTimeout=8 -o ConnectionAttempts=1)
release="$(ssh "${ssh_options[@]}" "$target" uname -r)"
hp2r_validate_release "$release"

ssh "${ssh_options[@]}" "$target" bash -s -- "$expected_boot" "$release" "$json" "$expected_driver_version" "$expected_overlay_file" <<'REMOTE'
set -euo pipefail
expected_boot="$1"
release="$2"
json="$3"
expected_driver_version="$4"
expected_overlay_file="$5"
root="${HP2R_INSTALL_ROOT:-}"
path() { printf '%s%s\n' "$root" "$1"; }
tryboot_flag="$(path /proc/device-tree/chosen/bootloader/tryboot)"
module_version_path="$(path /sys/module/hyperpixel2r_kms/version)"
module_name=hyperpixel2r_kms

test "$(uname -m)" = aarch64
test "$(uname -r)" = "$release"
tryboot_hex=''
if test -L "$tryboot_flag"; then
  echo 'tryboot flag is a symlink' >&2
  exit 1
elif test -f "$tryboot_flag"; then
  tryboot_hex="$(od -An -tx1 -N4 "$tryboot_flag" | tr -d '[:space:]')"
fi
case "$expected_boot" in
  tryboot) test "$tryboot_hex" = 00000001 || { echo 'tryboot flag is not one' >&2; exit 1; } ;;
  normal) test "$tryboot_hex" != 00000001 || { echo 'tryboot flag unexpectedly reports one' >&2; exit 1; } ;;
esac

loaded_module="$(lsmod | awk 'NR > 1 && $1 == "hyperpixel2r_kms" { print $1; exit }')"
test "$loaded_module" = "$module_name" || { echo 'generic HyperPixel module is not loaded' >&2; exit 1; }
for dependency in i2c_algo_bit edt_ft5x06 vc4; do lsmod | awk 'NR > 1 { print $1 }' | grep -Fxq "$dependency"; done
test ! -L "$module_version_path" && test -f "$module_version_path" || { echo 'loaded module does not expose version metadata' >&2; exit 1; }
driver_version="$(tr -d '\n' < "$module_version_path")"
[[ "$driver_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'loaded module has invalid version metadata' >&2; exit 1; }
if test -n "$expected_driver_version" && test "$driver_version" != "$expected_driver_version"; then
  echo 'loaded module version does not match the staged candidate' >&2
  exit 1
fi

generic_bound=false
generic_driver="$(path /sys/bus/platform/drivers/hyperpixel2r-kms)"
for entry in "$generic_driver"/*; do
  test ! -L "$entry" && test -e "$entry" || continue
  compatible="$entry/of_node/compatible"
  test ! -L "$compatible" && test -f "$compatible" || continue
  tr '\0' '\n' < "$compatible" | grep -Fxq shayne,hyperpixel2r-kms || continue
  generic_bound=true
done
"$generic_bound" || { echo 'generic HyperPixel compatible is not bound by the live platform driver' >&2; exit 1; }

case "$expected_boot" in
  tryboot) active_config_name=tryboot.txt ;;
  normal) active_config_name=config.txt ;;
  *) echo 'unsupported boot expectation' >&2; exit 1 ;;
esac
config="$(path "/boot/firmware/$active_config_name")"
test ! -L "$config" && test -f "$config"
overlay_name="$(sudo awk '
  {
    line=$0; sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line)
    if (line ~ /^dtoverlay=hyperpixel2r-kms-[0-9a-f]{12}\.dtbo$/) {
      sub(/^dtoverlay=/, "", line); print line
    }
  }
' "$config")"
test "$(printf '%s\n' "$overlay_name" | sed '/^$/d' | wc -l | tr -d ' ')" = 1 || { echo 'active boot config does not declare exactly one generic overlay' >&2; exit 1; }
[[ "$overlay_name" =~ ^hyperpixel2r-kms-[0-9a-f]{12}\.dtbo$ ]] || {
  echo 'active boot config has an invalid generic overlay name' >&2
  exit 1
}
if test -n "$expected_overlay_file" && test "$overlay_name" != "$expected_overlay_file"; then
  echo 'active generic overlay does not match the staged candidate' >&2
  exit 1
fi

connected=0
drm_mode=''
for status in "$(path /sys/class/drm)"/card*-*/status; do
  test ! -L "$status" && test -f "$status" || continue
  test "$(cat "$status")" = connected || continue
  grep -Fxq 480x480 "$(dirname "$status")/modes" || continue
  connected=$((connected + 1))
  drm_mode=480x480
done
test "$connected" = 1 || { echo 'expected exactly one connected 480x480 DRM connector' >&2; exit 1; }

touch=false
for name in "$(path /sys/class/input)"/event*/device/name; do
  test ! -L "$name" && test -f "$name" || continue
  grep -Eiq 'EDT|FT5' "$name" && touch=true && break
done
"$touch" || { echo 'no HyperPixel EDT/FT5 touch input was found' >&2; exit 1; }

# The service is application-independent; renderer proof is a live current
# boot probe rather than a repository constant.
sudo journalctl -b --no-pager | grep -E 'SDL display ready: video_driver=(kmsdrm|KMSDRM) render_driver=opengles2' >/dev/null || {
  echo 'no KMSDRM/OpenGL ES 2 SDL readiness record in current boot' >&2
  exit 1
}

if test "$json" = true; then
  printf '{"schema_version":1,"driver_version":"%s","kernel_release":"%s","module":"%s","drm_mode":"%s","touch":true,"sdl_driver":"KMSDRM","renderer":"opengles2","accepted":true}\n' \
    "$driver_version" "$(uname -r)" "$loaded_module" "$drm_mode"
else
  printf 'Verified live HyperPixel driver %s: generic overlay %s, 480x480 DRM, touch, KMSDRM, OpenGL ES 2\n' "$driver_version" "$overlay_name"
fi
REMOTE
