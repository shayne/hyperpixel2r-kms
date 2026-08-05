#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/scripts/common.sh"

usage() {
  cat <<'USAGE'
Usage: export-target-kbuild.sh [OPTIONS]

Export the exact live target kernel headers, kbuild tree, source package,
and Raspberry Pi Zero 2 W base DTB without modifying the target.

Options:
  --target TARGET                    SSH target (or set HP2R_TARGET)
  --kernel-release RELEASE           Export an inactive kernel release
  --target-identity-sha256 SHA256    Bind inactive provenance to this target
  --output DIR                       Kernel export parent (default: dist/kernel-target)
  -h, --help                         Show this help
USAGE
}

target="${HP2R_TARGET:-}"
output_parent="$repo_root/dist/kernel-target"
requested_release=""
target_identity_sha256=""
while test "$#" -gt 0; do
  case "$1" in
    --target)
      test "$#" -ge 2 || {
        echo "--target requires a value" >&2
        exit 64
      }
      target="$2"
      shift 2
      ;;
    --output)
      test "$#" -ge 2 || {
        echo "--output requires a value" >&2
        exit 64
      }
      output_parent="$2"
      shift 2
      ;;
    --kernel-release)
      test "$#" -ge 2 || {
        echo "--kernel-release requires a value" >&2
        exit 64
      }
      requested_release="$2"
      shift 2
      ;;
    --target-identity-sha256)
      test "$#" -ge 2 || {
        echo "--target-identity-sha256 requires a value" >&2
        exit 64
      }
      target_identity_sha256="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done
: "${target:?set HP2R_TARGET or pass --target}"
hp2r_validate_target "$target"
if test -n "$requested_release" || test -n "$target_identity_sha256"; then
  test -n "$requested_release" && test -n "$target_identity_sha256" || {
    echo "--kernel-release and --target-identity-sha256 must be used together" >&2
    exit 64
  }
  hp2r_validate_release "$requested_release" || exit 64
  [[ "$target_identity_sha256" =~ ^[0-9a-f]{64}$ ]] || {
    echo "--target-identity-sha256 must be lowercase SHA-256" >&2
    exit 64
  }
fi
inactive_export=false
if test -n "$requested_release"; then
  inactive_export=true
fi

base_dtb_path="/boot/firmware/bcm2710-rpi-zero-2-w.dtb"
metadata="$(
  ssh "$target" bash -s -- "$requested_release" "$inactive_export" <<'REMOTE'
set -eu
release="${1-}"
inactive_export="${2-}"
if test -z "$release"; then
  release="$(uname -r)"
fi
arch="$(uname -m)"
test "$arch" = aarch64 || {
  echo "target architecture must be aarch64, got $arch" >&2
  exit 1
}
header_path="$(readlink -f "/lib/modules/$release/build")"
test -d "$header_path"
test -f "$header_path/.config"
test -f "$header_path/Module.symvers"
if "$inactive_export"; then
  test "$(cat "$header_path/include/config/kernel.release")" = "$release"
  modinfo -k "$release" -F vermagic vc4 | grep -Fq "$release "
fi
common_makefile="$(
  awk '$1 == "include" && $2 ~ /^\// { print $2; exit }' \
    "$header_path/Makefile"
)"
test -f "$common_makefile"
common_header_path="$(dirname "$common_makefile")"
test -d "$common_header_path"
scripts_path="$(readlink -f "$header_path/scripts")"
test -d "$scripts_path"
kbuild_path="$(dirname "$scripts_path")"
test -d "$kbuild_path"
kbuild_package="$(
  dpkg-query -S "$kbuild_path/scripts/basic/fixdep" |
    awk -F ": " 'NR == 1 { print $1 }'
)"
test -n "$kbuild_package"
kernel_source_package="$(
  dpkg-query -W -f='${source:Package}' "$kbuild_package"
)"
kernel_source_version="$(
  dpkg-query -W -f='${source:Version}' "$kbuild_package"
)"
kernel_series="$(
  printf '%s\n' "$release" |
    sed -nE 's/^([0-9]+\.[0-9]+).*/\1/p'
)"
test -n "$kernel_series"
kernel_source_deb_package="linux-source-$kernel_series"
kernel_source_deb_metadata="$(
  apt-cache show "$kernel_source_deb_package=$kernel_source_version"
)"
kernel_source_deb_arch="$(
  printf '%s\n' "$kernel_source_deb_metadata" |
    awk '$1 == "Architecture:" { print $2; exit }'
)"
kernel_source_deb_filename="$(
  printf '%s\n' "$kernel_source_deb_metadata" |
    awk '$1 == "Filename:" { print $2; exit }'
)"
kernel_source_deb_sha256="$(
  printf '%s\n' "$kernel_source_deb_metadata" |
    awk '$1 == "SHA256:" { print $2; exit }'
)"
test "$kernel_source_package" = linux
test "$kernel_source_deb_arch" = all
test -n "$kernel_source_deb_filename"
test -n "$kernel_source_deb_sha256"
base_dtb_path=/boot/firmware/bcm2710-rpi-zero-2-w.dtb
vc4_overlay_path=/boot/firmware/overlays/vc4-kms-v3d.dtbo
kernel_image_path="/boot/vmlinuz-$release"
initramfs_path="/boot/initrd.img-$release"
if "$inactive_export"; then
  require_root_regular() {
    test ! -L "$1" && test -f "$1" &&
      test "$(stat -c '%u:%g' "$1")" = 0:0
  }
  for path in \
    "$kernel_image_path" \
    "$initramfs_path" \
    "$base_dtb_path" \
    "$vc4_overlay_path"
  do
    require_root_regular "$path"
  done
  kernel_image_sha256="$(sha256sum "$kernel_image_path" | awk '{ print $1 }')"
  initramfs_sha256="$(sha256sum "$initramfs_path" | awk '{ print $1 }')"
  vc4_overlay_sha256="$(sha256sum "$vc4_overlay_path" | awk '{ print $1 }')"
else
  test -f "$base_dtb_path"
fi
base_dtb_sha256="$(sha256sum "$base_dtb_path" | awk '{ print $1 }')"
printf "kernel_release\t%s\n" "$release"
printf "kernel_arch\t%s\n" "$arch"
printf "header_path\t%s\n" "$header_path"
printf "common_header_path\t%s\n" "$common_header_path"
printf "kbuild_path\t%s\n" "$kbuild_path"
printf "kernel_source_package\t%s\n" "$kernel_source_package"
printf "kernel_source_version\t%s\n" "$kernel_source_version"
printf "kernel_source_deb_package\t%s\n" "$kernel_source_deb_package"
printf "kernel_source_deb_filename\t%s\n" "$kernel_source_deb_filename"
printf "kernel_source_deb_sha256\t%s\n" "$kernel_source_deb_sha256"
printf "base_dtb_path\t%s\n" "$base_dtb_path"
printf "base_dtb_sha256\t%s\n" "$base_dtb_sha256"
if "$inactive_export"; then
  printf "kernel_image_path\t%s\n" "$kernel_image_path"
  printf "kernel_image_sha256\t%s\n" "$kernel_image_sha256"
  printf "initramfs_path\t%s\n" "$initramfs_path"
  printf "initramfs_sha256\t%s\n" "$initramfs_sha256"
  printf "vc4_overlay_path\t%s\n" "$vc4_overlay_path"
  printf "vc4_overlay_sha256\t%s\n" "$vc4_overlay_sha256"
fi
REMOTE
)"

remote_keys=(
  kernel_release
  kernel_arch
  header_path
  common_header_path
  kbuild_path
  kernel_source_package
  kernel_source_version
  kernel_source_deb_package
  kernel_source_deb_filename
  kernel_source_deb_sha256
  base_dtb_path
  base_dtb_sha256
)
if "$inactive_export"; then
  remote_keys+=(
    kernel_image_path
    kernel_image_sha256
    initramfs_path
    initramfs_sha256
    vc4_overlay_path
    vc4_overlay_sha256
  )
fi
metadata_file="$(mktemp "${TMPDIR:-/tmp}/hp2r-target-metadata.XXXXXX")"
trap 'rm -f "$metadata_file"' EXIT
printf '%s\n' "$metadata" > "$metadata_file"
hp2r_validate_exact_manifest_rows "$metadata_file" "${remote_keys[@]}"

release="$(hp2r_manifest_value "$metadata_file" kernel_release)"
arch="$(hp2r_manifest_value "$metadata_file" kernel_arch)"
header_path="$(hp2r_manifest_value "$metadata_file" header_path)"
common_header_path="$(hp2r_manifest_value "$metadata_file" common_header_path)"
kbuild_path="$(hp2r_manifest_value "$metadata_file" kbuild_path)"
kernel_source_package="$(
  hp2r_manifest_value "$metadata_file" kernel_source_package
)"
kernel_source_version="$(
  hp2r_manifest_value "$metadata_file" kernel_source_version
)"
kernel_source_deb_package="$(
  hp2r_manifest_value "$metadata_file" kernel_source_deb_package
)"
kernel_source_deb_filename="$(
  hp2r_manifest_value "$metadata_file" kernel_source_deb_filename
)"
kernel_source_deb_sha256="$(
  hp2r_manifest_value "$metadata_file" kernel_source_deb_sha256
)"
returned_base_dtb_path="$(
  hp2r_manifest_value "$metadata_file" base_dtb_path
)"
base_dtb_sha256="$(
  hp2r_manifest_value "$metadata_file" base_dtb_sha256
)"
if "$inactive_export"; then
  kernel_image_path="$(
    hp2r_manifest_value "$metadata_file" kernel_image_path
  )"
  kernel_image_sha256="$(
    hp2r_manifest_value "$metadata_file" kernel_image_sha256
  )"
  initramfs_path="$(
    hp2r_manifest_value "$metadata_file" initramfs_path
  )"
  initramfs_sha256="$(
    hp2r_manifest_value "$metadata_file" initramfs_sha256
  )"
  vc4_overlay_path="$(
    hp2r_manifest_value "$metadata_file" vc4_overlay_path
  )"
  vc4_overlay_sha256="$(
    hp2r_manifest_value "$metadata_file" vc4_overlay_sha256
  )"
fi

hp2r_validate_release "$release"
test "$arch" = aarch64
for path in \
  "$header_path" \
  "$common_header_path" \
  "$kbuild_path" \
  "$returned_base_dtb_path"
do
  hp2r_validate_target_path "$path"
done
test "$returned_base_dtb_path" = "$base_dtb_path" || {
  echo "unexpected target DTB path: $returned_base_dtb_path" >&2
  exit 1
}
test "$kernel_source_package" = linux
[[ "$kernel_source_version" =~ ^[A-Za-z0-9.+:~_-]+$ ]]
[[ "$kernel_source_deb_package" =~ ^linux-source-[0-9]+\.[0-9]+$ ]]
case "$kernel_source_deb_filename" in
  pool/*)
    case "$kernel_source_deb_filename" in
      *".."*|*[$'\t\r\n ']*)
        echo "unsafe kernel source package filename: $kernel_source_deb_filename" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "unexpected kernel source package filename: $kernel_source_deb_filename" >&2
    exit 1
    ;;
esac
[[ "$kernel_source_deb_sha256" =~ ^[0-9a-f]{64}$ ]]
[[ "$base_dtb_sha256" =~ ^[0-9a-f]{64}$ ]]
if "$inactive_export"; then
  test "$kernel_image_path" = "/boot/vmlinuz-$release"
  test "$initramfs_path" = "/boot/initrd.img-$release"
  test "$vc4_overlay_path" = /boot/firmware/overlays/vc4-kms-v3d.dtbo
  for sha256 in \
    "$kernel_image_sha256" \
    "$initramfs_sha256" \
    "$vc4_overlay_sha256"
  do
    [[ "$sha256" =~ ^[0-9a-f]{64}$ ]]
  done
  test "$release" = "$requested_release" || {
    echo "target did not export the requested kernel release" >&2
    exit 1
  }
fi

mkdir -p "$output_parent"
output_parent="$(cd "$output_parent" && pwd -P)"
export_dir="$(hp2r_release_path "$output_parent" "$release")"
target_file="$export_dir/target.txt"
if test -f "$target_file"; then
  hp2r_validate_target_manifest "$target_file"
  for key in \
    kernel_release \
    kernel_arch \
    kernel_source_version \
    kernel_source_deb_sha256 \
    base_dtb_sha256 \
    kernel_image_sha256 \
    initramfs_sha256 \
    vc4_overlay_sha256
  do
    if test -n "$requested_release"; then
      test "$(hp2r_manifest_value "$target_file" "$key")" = \
        "$(hp2r_manifest_value "$metadata_file" "$key")" || {
        echo "existing export $key does not match live target" >&2
        exit 1
      }
    elif case "$key" in kernel_image_sha256|initramfs_sha256|vc4_overlay_sha256) true ;; *) false ;; esac; then
      continue
    elif test "$(hp2r_manifest_value "$target_file" "$key")" != \
      "$(hp2r_manifest_value "$metadata_file" "$key")"; then
      echo "existing export $key does not match live target" >&2
      exit 1
    fi
  done
  if test -n "$requested_release"; then
    test "$(hp2r_manifest_value "$target_file" target_identity_sha256)" = \
      "$target_identity_sha256" || {
      echo "existing export target identity does not match requested target" >&2
      exit 1
    }
  fi
fi

temporary_dir="$(mktemp -d "$output_parent/.${release}.XXXXXX")"
trap 'rm -f "$metadata_file"; rm -rf "$temporary_dir"' EXIT
mkdir -p "$temporary_dir/root"

export_paths=(
  "${header_path#/}"
  "${common_header_path#/}"
  "${kbuild_path#/}"
  "${base_dtb_path#/}"
)
if test -n "$requested_release"; then
  export_paths+=(
    "${kernel_image_path#/}"
    "${initramfs_path#/}"
    "${vc4_overlay_path#/}"
  )
fi
ssh "$target" \
  tar -C / -cf - -- \
    "${export_paths[@]}" |
  tar -C "$temporary_dir/root" -xf -

test -f "$temporary_dir/root$header_path/.config"
test -f "$temporary_dir/root$header_path/Module.symvers"
test -d "$temporary_dir/root$common_header_path"
test -d "$temporary_dir/root$kbuild_path"
test -f "$temporary_dir/root$base_dtb_path"
hp2r_verify_sha256 \
  "$temporary_dir/root$base_dtb_path" \
  "$base_dtb_sha256" \
  "base DTB"
if test -n "$requested_release"; then
  hp2r_verify_sha256 \
    "$temporary_dir/root$kernel_image_path" \
    "$kernel_image_sha256" \
    "kernel image"
  hp2r_verify_sha256 \
    "$temporary_dir/root$initramfs_path" \
    "$initramfs_sha256" \
    "initramfs"
  hp2r_verify_sha256 \
    "$temporary_dir/root$vc4_overlay_path" \
    "$vc4_overlay_sha256" \
    "VC4 overlay"
fi
command -v curl >/dev/null 2>&1 || {
  echo "curl is required to fetch the exact target kernel source package" >&2
  exit 1
}
kernel_source_base_url="$(
  printf '%s' \
    "${HP2R_KERNEL_SOURCE_BASE_URL:-https://archive.raspberrypi.com/debian}" |
    sed 's:/*$::'
)"
kernel_source_deb="$temporary_dir/kernel-source.deb"
curl \
  --fail \
  --location \
  --retry 2 \
  --output "$kernel_source_deb" \
  "$kernel_source_base_url/$kernel_source_deb_filename"
hp2r_verify_sha256 \
  "$kernel_source_deb" \
  "$kernel_source_deb_sha256" \
  "kernel source package"

if test -n "$requested_release"; then
  ssh "$target" bash -s -- \
    "$release" \
    "$kernel_image_sha256" \
    "$initramfs_sha256" \
    "$base_dtb_sha256" \
    "$vc4_overlay_sha256" <<'REMOTE'
set -eu
release="$1"
kernel_image_sha256="$2"
initramfs_sha256="$3"
base_dtb_sha256="$4"
vc4_overlay_sha256="$5"
require_root_regular() {
  test ! -L "$1" && test -f "$1" &&
    test "$(stat -c '%u:%g' "$1")" = 0:0
}
verify() {
  path="$1"
  expected="$2"
  require_root_regular "$path"
  test "$(sha256sum "$path" | awk '{ print $1 }')" = "$expected"
}
verify "/boot/vmlinuz-$release" "$kernel_image_sha256"
verify "/boot/initrd.img-$release" "$initramfs_sha256"
verify /boot/firmware/bcm2710-rpi-zero-2-w.dtb "$base_dtb_sha256"
verify /boot/firmware/overlays/vc4-kms-v3d.dtbo "$vc4_overlay_sha256"
REMOTE
fi

{
  if test -n "$requested_release"; then
    printf 'schema_version\t2\n'
    printf 'target_identity_sha256\t%s\n' "$target_identity_sha256"
  fi
  printf 'kernel_release\t%s\n' "$release"
  printf 'kernel_arch\taarch64\n'
  printf 'header_path\t%s\n' "$header_path"
  printf 'common_header_path\t%s\n' "$common_header_path"
  printf 'kbuild_path\t%s\n' "$kbuild_path"
  printf 'kernel_source_package\t%s\n' "$kernel_source_package"
  printf 'kernel_source_version\t%s\n' "$kernel_source_version"
  printf 'kernel_source_deb_package\t%s\n' "$kernel_source_deb_package"
  printf 'kernel_source_deb_filename\t%s\n' "$kernel_source_deb_filename"
  printf 'kernel_source_deb_sha256\t%s\n' "$kernel_source_deb_sha256"
  printf 'kernel_source_deb\tkernel-source.deb\n'
  printf 'base_dtb_path\t%s\n' "$base_dtb_path"
  printf 'base_dtb_sha256\t%s\n' "$base_dtb_sha256"
  if test -n "$requested_release"; then
    printf 'kernel_image_path\t%s\n' "$kernel_image_path"
    printf 'kernel_image_sha256\t%s\n' "$kernel_image_sha256"
    printf 'initramfs_path\t%s\n' "$initramfs_path"
    printf 'initramfs_sha256\t%s\n' "$initramfs_sha256"
    printf 'vc4_overlay_path\t%s\n' "$vc4_overlay_path"
    printf 'vc4_overlay_sha256\t%s\n' "$vc4_overlay_sha256"
  fi
} > "$temporary_dir/target.txt"
if test -n "$requested_release"; then
  hp2r_validate_inactive_target_manifest \
    "$temporary_dir/target.txt" \
    "$temporary_dir/root"
else
  hp2r_validate_target_manifest "$temporary_dir/target.txt"
fi

if test -e "$export_dir"; then
  rm -rf "$export_dir"
fi
mv "$temporary_dir" "$export_dir"
rm -f "$metadata_file"
trap - EXIT
printf 'Exported %s kernel build inputs to %s\n' "$release" "$export_dir"
