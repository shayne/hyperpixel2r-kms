#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/scripts/common.sh"

usage() {
  cat <<'USAGE'
Usage: check-artifacts.sh [OPTIONS]

Validate an exact-kernel HyperPixel 2 Round driver artifact bundle.

Options:
  --target TARGET           SSH target (or set HP2R_TARGET)
  --kernel-release RELEASE  Validate an already-exported target release
  --kernel-target DIR       Exported kernel target parent (default: dist/kernel-target)
  --output DIR              Artifact parent (default: dist/artifacts)
  -h, --help                Show this help
USAGE
}

target="${HP2R_TARGET:-}"
release=""
kernel_target_parent="$repo_root/dist/kernel-target"
artifact_parent="$repo_root/dist/artifacts"
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
    --kernel-release)
      test "$#" -ge 2 || {
        echo "--kernel-release requires a value" >&2
        exit 64
      }
      release="$2"
      shift 2
      ;;
    --kernel-target)
      test "$#" -ge 2 || {
        echo "--kernel-target requires a value" >&2
        exit 64
      }
      kernel_target_parent="$2"
      shift 2
      ;;
    --output)
      test "$#" -ge 2 || {
        echo "--output requires a value" >&2
        exit 64
      }
      artifact_parent="$2"
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
if test -z "$release"; then
  release="$(ssh "$target" uname -r)"
fi
hp2r_validate_release "$release"

cd "$repo_root"
test -d "$artifact_parent" || {
  echo "missing artifact parent: $artifact_parent" >&2
  exit 1
}
artifact_parent="$(cd "$artifact_parent" && pwd -P)"
artifact_dir="$(hp2r_release_path "$artifact_parent" "$release")"
manifest="$artifact_dir/manifest.txt"
hp2r_validate_artifact_manifest "$manifest"
module_file="$(hp2r_manifest_value "$manifest" module_file)"
overlay_file="$(hp2r_manifest_value "$manifest" overlay_file)"
applied_dtb_file="$(hp2r_manifest_value "$manifest" applied_dtb_file)"
module="$artifact_dir/$module_file"
overlay="$artifact_dir/$overlay_file"
applied_dtb="$artifact_dir/$applied_dtb_file"

for artifact in \
  "$module" \
  "$overlay" \
  "$applied_dtb" \
  "$artifact_dir/module.file.txt" \
  "$artifact_dir/module.readelf.txt" \
  "$artifact_dir/module.modinfo.txt" \
  "$artifact_dir/module.sha256" \
  "$artifact_dir/overlay.sha256" \
  "$artifact_dir/applied-dtb.sha256" \
  "$artifact_dir/host-tools.txt" \
  "$artifact_dir/host-fixdep" \
  "$artifact_dir/host-modpost" \
  "$artifact_dir/host-genksyms"
do
  test -f "$artifact" || {
    echo "missing driver artifact: $artifact" >&2
    exit 1
  }
done

target_parent="$kernel_target_parent"
test -d "$target_parent" || {
  echo "missing target exports; run mise run export-target-kbuild" >&2
  exit 1
}
target_dir="$(hp2r_release_path "$target_parent" "$release")"
target_file="$target_dir/target.txt"
hp2r_validate_artifact_provenance "$manifest" "$target_file" "$artifact_dir"

source_revision="$(hp2r_manifest_value "$manifest" source_revision)"
source_tree="$(hp2r_manifest_value "$manifest" source_tree)"
release_source_root="${HP2R_RELEASE_SOURCE_ROOT:-$repo_root}"
if hp2r_release_source_available "$release_source_root"; then
  hp2r_validate_release_source "$release_source_root" "$source_revision" "$source_tree"
  checked_source_tree="$source_tree"
else
  hp2r_require_clean_source
  git cat-file -e "$source_revision^{commit}" || {
    echo "artifact source revision is not available in this repository" >&2
    exit 1
  }
  hp2r_require_durable_source_revision "$source_revision"
  checked_source_tree="$(git rev-parse 'HEAD^{tree}')"
  revision_tree="$(git rev-parse "$source_revision^{tree}")"
  test "$revision_tree" = "$checked_source_tree" || {
    echo "artifact source revision tree does not match checked source" >&2
    exit 1
  }
fi
hp2r_validate_source_identity \
  "$source_revision" \
  "$source_tree" \
  "$overlay_file" \
  "$source_revision" \
  "$checked_source_tree"

test "$(hp2r_manifest_value "$manifest" kernel_release)" = "$release" || {
  echo "driver artifact kernel release does not match live target" >&2
  exit 1
}
test "$(hp2r_manifest_value "$manifest" architecture)" = aarch64
test "$(hp2r_sha256 "$module")" = \
  "$(hp2r_manifest_value "$manifest" module_sha256)" || {
  echo "driver module checksum does not match manifest" >&2
  exit 1
}
test "$(hp2r_sha256 "$overlay")" = \
  "$(hp2r_manifest_value "$manifest" overlay_sha256)" || {
  echo "driver overlay checksum does not match manifest" >&2
  exit 1
}
test "$(hp2r_sha256 "$applied_dtb")" = \
  "$(hp2r_manifest_value "$manifest" applied_dtb_sha256)" || {
  echo "driver applied DTB checksum does not match manifest" >&2
  exit 1
}
hp2r_validate_checksum_file "$artifact_dir/module.sha256" "$module"
hp2r_validate_checksum_file "$artifact_dir/overlay.sha256" "$overlay"
hp2r_validate_checksum_file \
  "$artifact_dir/applied-dtb.sha256" \
  "$applied_dtb"

base_dtb_path="$(hp2r_manifest_value "$target_file" base_dtb_path)"
target_root="$target_dir/root"
base_dtb="$target_root$base_dtb_path"
test -f "$base_dtb" || {
  echo "missing exported base DTB: $base_dtb" >&2
  exit 1
}
actual_base_dtb_sha256="$(hp2r_sha256 "$base_dtb")"
test "$(hp2r_manifest_value "$target_file" base_dtb_sha256)" = \
  "$actual_base_dtb_sha256" || {
  echo "exported base DTB checksum does not match target metadata" >&2
  exit 1
}
test "$(hp2r_manifest_value "$manifest" base_dtb_sha256)" = \
  "$actual_base_dtb_sha256" || {
  echo "artifact is not bound to the exported base DTB" >&2
  exit 1
}

image="${HP2R_KERNEL_BUILD_IMAGE:-$HP2R_DEFAULT_BUILD_IMAGE}"
hp2r_docker info >/dev/null
hp2r_validate_overlay "$overlay" "$image"
inspection_dir="$(mktemp -d "${TMPDIR:-/tmp}/hp2r-module-check.XXXXXX")"
trap 'rm -rf "$inspection_dir"' EXIT
hp2r_docker run --rm \
  --volume "$artifact_dir:/artifacts:ro" \
  --volume "$inspection_dir:/inspection" \
  --volume "$target_root:/target-root:ro" \
  "$image" \
  sh -eu -c '
    cd /artifacts
    file "$1" > /inspection/module.file.txt
    readelf -h "$1" > /inspection/module.readelf.txt
    modinfo "$1" > /inspection/module.modinfo.txt
    cmp module.file.txt /inspection/module.file.txt
    cmp module.readelf.txt /inspection/module.readelf.txt
    sed "/^filename:/d" module.modinfo.txt > /inspection/stored.modinfo.txt
    sed "/^filename:/d" /inspection/module.modinfo.txt \
      > /inspection/fresh.modinfo.txt
    cmp /inspection/stored.modinfo.txt /inspection/fresh.modinfo.txt
    case "$5" in
      arm64|aarch64) expected_machine=AArch64 ;;
      amd64|x86_64) expected_machine="Advanced Micro Devices X86-64" ;;
      *) exit 64 ;;
    esac
    for specification in \
      host-fixdep:1 \
      host-modpost:0 \
      host-genksyms:0
    do
      helper="${specification%:*}"
      expected_status="${specification#*:}"
      machine="$(
        readelf -h "$helper" |
          sed -n "s/^[[:space:]]*Machine:[[:space:]]*//p" |
          head -n 1
      )"
      test "$machine" = "$expected_machine"
      set +e
      "./$helper" </dev/null >/dev/null 2>&1
      status="$?"
      set -e
      test "$status" -eq "$expected_status"
    done
    fdtoverlay \
      -i "/target-root$2" \
      -o /inspection/reapplied.dtb \
      "$3"
    cmp /inspection/reapplied.dtb "$4"
    dtc \
      -q \
      -I dtb \
      -O dts \
      -o /inspection/applied.dts \
      "$4"
    dtc \
      -q \
      -I dtb \
      -O dts \
      -o /inspection/overlay.dts \
      "$3"
    cat /inspection/module.file.txt
    cat /inspection/module.readelf.txt
    cat /inspection/module.modinfo.txt
  ' sh \
    "$module_file" \
    "$base_dtb_path" \
    "$overlay_file" \
    "$applied_dtb_file" \
    "$(hp2r_manifest_value "$artifact_dir/host-tools.txt" host_arch)" \
  > "$inspection_dir/module-inspection.txt"

grep -Fq 'ARM aarch64' "$inspection_dir/module-inspection.txt"
grep -Eq 'Machine:[[:space:]]+AArch64' \
  "$inspection_dir/module-inspection.txt"
license="$(
  awk -F ': *' '$1 == "license" { sub(/^license: */, ""); print; exit }' \
    "$inspection_dir/module-inspection.txt"
)"
vermagic="$(
  awk -F ': *' '$1 == "vermagic" { sub(/^vermagic: */, ""); print; exit }' \
    "$inspection_dir/module-inspection.txt"
)"
depends="$(
  awk -F ': *' '$1 == "depends" { sub(/^depends: */, ""); print; exit }' \
    "$inspection_dir/module-inspection.txt"
)"
test "$license" = GPL
grep -Eq '^alias:[[:space:]]+of:N\*T\*Cshayne,hyperpixel2r-kms$' \
  "$inspection_dir/module-inspection.txt"
grep -Eq '^softdep:[[:space:]]+pre: edt_ft5x06$' \
  "$inspection_dir/module-inspection.txt"
grep -Eq '^name:[[:space:]]+hyperpixel2r_kms$' \
  "$inspection_dir/module-inspection.txt"
case "$vermagic" in
  "$release"*) ;;
  *)
    echo "driver module vermagic does not match live kernel: $vermagic" >&2
    exit 1
    ;;
esac
printf '%s\n' "$depends" | tr ',-' '\n_' | grep -Fqx i2c_algo_bit
test "$(hp2r_manifest_value "$manifest" module_vermagic)" = "$vermagic"

artifact_abs="$artifact_dir"
fdt_hex() {
  hp2r_docker run --rm \
    --volume "$artifact_abs:/artifacts:ro" \
    "$image" \
    fdtget -t x "/artifacts/$applied_dtb_file" "$1" "$2"
}

fdt_string() {
  hp2r_docker run --rm \
    --volume "$artifact_abs:/artifacts:ro" \
    "$image" \
    fdtget -t s "/artifacts/$applied_dtb_file" "$1" "$2"
}

base_symbol_path() {
  hp2r_docker run --rm \
    --volume "$target_root:/target-root:ro" \
    "$image" \
    fdtget -t s "/target-root$base_dtb_path" /__symbols__ "$1"
}

applied_dts="$inspection_dir/applied.dts"
overlay_dts="$inspection_dir/overlay.dts"
test "$(grep -Fc 'compatible = "shayne,hyperpixel2r-kms";' "$applied_dts")" \
  -eq 1
test "$(grep -Fc 'compatible = "edt,edt-ft5406";' "$applied_dts")" -eq 1

panel_path=/hyperpixel2r-kms
touch_path="$panel_path/touchscreen@15"
panel_endpoint_path="$panel_path/port/endpoint"
gpio_path="$(base_symbol_path gpio)"
dpi_path="$(base_symbol_path dpi)"
dpi_endpoint_path="$dpi_path/port/endpoint"
dpi_pinctrl_path="$(base_symbol_path dpi_18bit_cpadhi_gpio0)"

gpio_phandle="$(fdt_hex "$gpio_path" phandle)"
dpi_pinctrl_phandle="$(fdt_hex "$dpi_pinctrl_path" phandle)"
test "$(fdt_string "$panel_path" compatible)" = shayne,hyperpixel2r-kms
test "$(fdt_hex "$panel_path" sda-gpios)" = "$gpio_phandle a 0"
test "$(fdt_hex "$panel_path" scl-gpios)" = "$gpio_phandle b 0"
test "$(fdt_hex "$panel_path" cs-gpios)" = "$gpio_phandle 12 1"
test "$(fdt_hex "$panel_path" backlight-gpios)" = "$gpio_phandle 13 0"
test "$(fdt_hex "$panel_path" rotation)" = 0

test "$(fdt_string "$touch_path" compatible)" = edt,edt-ft5406
test "$(fdt_hex "$touch_path" reg)" = 15
test "$(fdt_hex "$touch_path" interrupt-parent)" = "$gpio_phandle"
test "$(fdt_hex "$touch_path" interrupts)" = "1b 2"
test "$(fdt_hex "$touch_path" touchscreen-size-x)" = 1e0
test "$(fdt_hex "$touch_path" touchscreen-size-y)" = 1e0

panel_endpoint_phandle="$(fdt_hex "$panel_endpoint_path" phandle)"
dpi_endpoint_phandle="$(fdt_hex "$dpi_endpoint_path" phandle)"
test "$(fdt_hex "$panel_endpoint_path" remote-endpoint)" = \
  "$dpi_endpoint_phandle"
test "$(fdt_hex "$dpi_endpoint_path" remote-endpoint)" = \
  "$panel_endpoint_phandle"

test "$(fdt_string "$dpi_path" status)" = okay
test "$(fdt_string "$dpi_path" pinctrl-names)" = default
test "$(fdt_hex "$dpi_path" pinctrl-0)" = "$dpi_pinctrl_phandle"

for parameter in \
  rotate \
  touchscreen-inverted-x \
  touchscreen-inverted-y \
  touchscreen-swapped-x-y
do
  grep -Eq "^[[:space:]]*$parameter =" "$overlay_dts"
done

printf 'HyperPixel driver artifacts match live target %s\n' "$release"
