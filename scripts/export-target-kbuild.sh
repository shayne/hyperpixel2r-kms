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
  --target TARGET  SSH target (or set HP2R_TARGET)
  --output DIR     Kernel export parent (default: dist/kernel-target)
  -h, --help       Show this help
USAGE
}

target="${HP2R_TARGET:-}"
output_parent="$repo_root/dist/kernel-target"
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

base_dtb_path="/boot/firmware/bcm2710-rpi-zero-2-w.dtb"
metadata="$(
  ssh "$target" bash -s <<'REMOTE'
set -eu
release="$(uname -r)"
arch="$(uname -m)"
test "$arch" = aarch64 || {
  echo "target architecture must be aarch64, got $arch" >&2
  exit 1
}
header_path="$(readlink -f "/lib/modules/$release/build")"
test -d "$header_path"
test -f "$header_path/.config"
test -f "$header_path/Module.symvers"
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
test -f "$base_dtb_path"
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
    base_dtb_sha256
  do
    test "$(hp2r_manifest_value "$target_file" "$key")" = \
      "$(hp2r_manifest_value "$metadata_file" "$key")" || {
      echo "existing export $key does not match live target" >&2
      exit 1
    }
  done
fi

temporary_dir="$(mktemp -d "$output_parent/.${release}.XXXXXX")"
trap 'rm -f "$metadata_file"; rm -rf "$temporary_dir"' EXIT
mkdir -p "$temporary_dir/root"

ssh "$target" \
  tar -C / -cf - -- \
    "${header_path#/}" \
    "${common_header_path#/}" \
    "${kbuild_path#/}" \
    "${base_dtb_path#/}" |
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

{
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
} > "$temporary_dir/target.txt"
hp2r_validate_target_manifest "$temporary_dir/target.txt"

if test -e "$export_dir"; then
  rm -rf "$export_dir"
fi
mv "$temporary_dir" "$export_dir"
rm -f "$metadata_file"
trap - EXIT
printf 'Exported %s kernel build inputs to %s\n' "$release" "$export_dir"
