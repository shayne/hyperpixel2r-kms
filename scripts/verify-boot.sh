#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$repo_root/scripts/common.sh"

usage() {
  cat <<'USAGE'
Usage: verify-boot.sh [--target TARGET] [--expect-tryboot|--expect-normal] [--expect-kernel-release RELEASE] [--expect-driver-version VERSION] [--expect-overlay-file FILE] [--expect-module-file FILE] [--expect-module-sha256 SHA256] [--allow-retired-tryboot-config] [--expect-retired-tryboot-absent|--expect-retired-tryboot-sha256 SHA256] [--json]

Verify the live HyperPixel driver, generic compatible binding, DRM/input path,
and current-boot SDL renderer evidence.  --json is a versioned stable result.
USAGE
}

target="${HP2R_TARGET:-}"
expected_boot=tryboot
expected_driver_version=''
expected_overlay_file=''
expected_kernel_release=''
expected_module_file=''
expected_module_sha256=''
json=false
allow_retired_tryboot_config=false
retired_tryboot_mode=''
retired_tryboot_sha256=''
while test "$#" -gt 0; do
  case "$1" in
    --target) test "$#" -ge 2 || { echo '--target requires a value' >&2; exit 64; }; target="$2"; shift 2 ;;
    --expect-tryboot) expected_boot=tryboot; shift ;;
    --expect-normal) expected_boot=normal; shift ;;
    --expect-kernel-release) test "$#" -ge 2 || { echo '--expect-kernel-release requires a value' >&2; exit 64; }; expected_kernel_release="$2"; shift 2 ;;
    --expect-driver-version) test "$#" -ge 2 || { echo '--expect-driver-version requires a value' >&2; exit 64; }; expected_driver_version="$2"; shift 2 ;;
    --expect-overlay-file) test "$#" -ge 2 || { echo '--expect-overlay-file requires a value' >&2; exit 64; }; expected_overlay_file="$2"; shift 2 ;;
    --expect-module-file) test "$#" -ge 2 || { echo '--expect-module-file requires a value' >&2; exit 64; }; expected_module_file="$2"; shift 2 ;;
    --expect-module-sha256) test "$#" -ge 2 || { echo '--expect-module-sha256 requires a value' >&2; exit 64; }; expected_module_sha256="$2"; shift 2 ;;
    --allow-retired-tryboot-config) allow_retired_tryboot_config=true; shift ;;
    --expect-retired-tryboot-absent) test -z "$retired_tryboot_mode" || exit 64; retired_tryboot_mode=absent; shift ;;
    --expect-retired-tryboot-sha256) test "$#" -ge 2 && test -z "$retired_tryboot_mode" || exit 64; retired_tryboot_mode=sha256; retired_tryboot_sha256="$2"; shift 2 ;;
    --json) json=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 64 ;;
  esac
done
: "${target:?set HP2R_TARGET or pass --target}"
hp2r_validate_target "$target"
if test -n "$expected_driver_version"; then [[ "$expected_driver_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'unsafe expected driver version' >&2; exit 64; }; fi
if test -n "$expected_overlay_file"; then [[ "$expected_overlay_file" =~ ^hyperpixel2r-kms-[0-9a-f]{12}\.dtbo$ ]] || { echo 'unsafe expected overlay file' >&2; exit 64; }; fi
if test -n "$expected_module_file"; then test "$expected_module_file" = hyperpixel2r_kms.ko || { echo 'unsafe expected module file' >&2; exit 64; }; fi
if test -n "$expected_module_sha256"; then [[ "$expected_module_sha256" =~ ^[0-9a-f]{64}$ ]] || { echo 'unsafe expected module checksum' >&2; exit 64; }; fi
if test -n "$expected_module_file"; then
  test -n "$expected_module_sha256" || { echo 'expected module file and checksum must be supplied together' >&2; exit 64; }
elif test -n "$expected_module_sha256"; then
  echo 'expected module file and checksum must be supplied together' >&2
  exit 64
fi
if test -n "$expected_kernel_release"; then hp2r_validate_release "$expected_kernel_release"; fi
if test -n "$retired_tryboot_mode"; then
  test -n "$expected_kernel_release" && test -n "$expected_driver_version" &&
    test -n "$expected_overlay_file" || {
      echo 'retired tryboot expectation requires an exact candidate identity' >&2
      exit 64
    }
  if test "$retired_tryboot_mode" = sha256; then
    [[ "$retired_tryboot_sha256" =~ ^[0-9a-f]{64}$ ]] || { echo 'unsafe retired tryboot checksum' >&2; exit 64; }
  fi
fi
if "$allow_retired_tryboot_config"; then
  test "$expected_boot" = tryboot && test -n "$retired_tryboot_mode" || {
    echo '--allow-retired-tryboot-config requires an exact retired tryboot identity' >&2
    exit 64
  }
elif test "$expected_boot" = tryboot && test -n "$retired_tryboot_mode"; then
  echo 'tryboot verification of a retired config requires --allow-retired-tryboot-config' >&2
  exit 64
fi
ssh_options=(-o BatchMode=yes -o ConnectTimeout=8 -o ConnectionAttempts=1)
release="$(ssh "${ssh_options[@]}" "$target" uname -r)"
hp2r_validate_release "$release"
if test -n "$expected_kernel_release" && test "$release" != "$expected_kernel_release"; then
  echo 'running kernel release does not match the expected candidate' >&2
  exit 1
fi
remote_expected_kernel_release="${expected_kernel_release:-$release}"
remote_expected_driver_version="${expected_driver_version:-none}"
remote_expected_overlay_file="${expected_overlay_file:-none}"
remote_expected_module_file="${expected_module_file:-none}"
remote_expected_module_sha256="${expected_module_sha256:-none}"
remote_retired_tryboot_mode="${retired_tryboot_mode:-active}"
remote_retired_tryboot_sha256="${retired_tryboot_sha256:-none}"

ssh "${ssh_options[@]}" "$target" bash -s -- "$expected_boot" "$remote_expected_kernel_release" "$json" "$remote_expected_driver_version" "$remote_expected_overlay_file" "$allow_retired_tryboot_config" "$remote_expected_module_file" "$remote_expected_module_sha256" "$remote_retired_tryboot_mode" "$remote_retired_tryboot_sha256" <<'REMOTE'
set -euo pipefail
export PATH="${PATH:+$PATH:}/usr/sbin:/sbin"
expected_boot="$1"
release="$2"
json="$3"
expected_driver_version="$4"
expected_overlay_file="$5"
allow_retired_tryboot_config="$6"
expected_module_file="$7"
expected_module_sha256="$8"
retired_tryboot_mode="$9"
retired_tryboot_sha256="${10}"
if test "$expected_driver_version" = none; then expected_driver_version=''; fi
if test "$expected_overlay_file" = none; then expected_overlay_file=''; fi
if test "$expected_module_file" = none; then expected_module_file=''; fi
if test "$expected_module_sha256" = none; then expected_module_sha256=''; fi
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
if test -n "$expected_module_file"; then
  expected_module_path="$(path "/lib/modules/$release/extra/$expected_module_file")"
  test ! -L "$expected_module_path" && test -f "$expected_module_path" || {
    echo 'expected candidate module path is unsafe' >&2
    exit 1
  }
  test "$(stat -c '%U:%G:%a' "$expected_module_path")" = root:root:644 || {
    echo 'expected candidate module ownership or mode is unsafe' >&2
    exit 1
  }
  resolved_module_path="$(modinfo -k "$release" -n "$module_name")"
  resolved_module_canonical="$(readlink -f -- "$resolved_module_path")"
  expected_module_canonical="$(readlink -f -- "$expected_module_path")"
  test "$resolved_module_canonical" = "$expected_module_canonical" || {
    echo 'resolved module path does not match the staged candidate' >&2
    exit 1
  }
  test "$(sha256sum "$expected_module_path" | awk '{ print $1 }')" = "$expected_module_sha256" || {
    echo 'resolved module checksum does not match the staged candidate' >&2
    exit 1
  }
  module_vermagic="$(modinfo -k "$release" -F vermagic "$module_name")"
  case "$module_vermagic" in "$release "*) ;; *) echo 'resolved module vermagic does not match the running kernel' >&2; exit 1 ;; esac
fi

generic_driver="$(path /sys/bus/platform/drivers/hyperpixel2r-kms)"
platform_devices="$(path /sys/devices/platform)"
generic_bound_count=0
if test ! -L "$generic_driver" && test -d "$generic_driver"; then
  for entry in "$generic_driver"/*; do
    test -L "$entry" || continue
    resolved_entry="$(readlink -f -- "$entry")" || continue
    case "$resolved_entry" in
      "$platform_devices"/*) ;;
      *) continue ;;
    esac
    compatible="$resolved_entry/of_node/compatible"
    test ! -L "$compatible" && test -f "$compatible" || continue
    tr '\0' '\n' < "$compatible" | grep -Fxq shayne,hyperpixel2r-kms || continue
    generic_bound_count=$((generic_bound_count + 1))
  done
fi
test "$generic_bound_count" = 1 || {
  echo 'generic HyperPixel compatible is not bound exactly once by the live platform driver' >&2
  exit 1
}

case "$expected_boot" in
  tryboot) active_config_name=tryboot.txt ;;
  normal) active_config_name=config.txt ;;
  *) echo 'unsupported boot expectation' >&2; exit 1 ;;
esac
config="$(path "/boot/firmware/$active_config_name")"
if test "$retired_tryboot_mode" != active; then
  retired_config="$(path /boot/firmware/tryboot.txt)"
  case "$retired_tryboot_mode" in
    absent)
      test ! -L "$retired_config" && test ! -e "$retired_config" || {
        echo 'retired tryboot config was expected to be absent' >&2
        exit 1
      }
      ;;
    sha256)
      test ! -L "$retired_config" && test -f "$retired_config" || {
        echo 'retired tryboot config is unsafe' >&2
        exit 1
      }
      test "$(sudo sha256sum "$retired_config" | awk '{ print $1 }')" = "$retired_tryboot_sha256" || {
        echo 'retired tryboot config does not match accepted prior authority' >&2
        exit 1
      }
      ;;
    *) echo 'retired tryboot expectation is unsafe' >&2; exit 1 ;;
  esac
fi
if test "$allow_retired_tryboot_config" = true; then
  overlay_name="$expected_overlay_file"
elif test -L "$config"; then
  echo 'active boot config is a symlink' >&2
  exit 1
elif test -f "$config"; then
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
elif test -e "$config"; then
  echo 'active boot config is not a regular file' >&2
  exit 1
else
  echo 'active boot config is missing' >&2
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
