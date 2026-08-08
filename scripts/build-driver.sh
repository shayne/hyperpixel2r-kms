#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/scripts/common.sh"

usage() {
  cat <<'USAGE'
Usage: build-driver.sh [OPTIONS]

Cross-build an exact-kernel HyperPixel 2 Round driver artifact bundle.

Options:
  --target TARGET           SSH target (or set HP2R_TARGET)
  --kernel-release RELEASE  Build for an already-exported target release
  --target-identity-sha256 SHA256  Bind an explicit release to this target
  --kernel-target DIR       Exported kernel target parent (default: dist/kernel-target)
  --source-revision REF     Bind artifacts to this tree-identical Git commit
  --output DIR              Artifact parent (default: dist/artifacts)
  -h, --help                Show this help
USAGE
}

target="${HP2R_TARGET:-}"
release=""
explicit_release=false
target_identity_sha256=""
kernel_target_parent="$repo_root/dist/kernel-target"
source_ref=""
output_parent="$repo_root/dist/artifacts"
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
      explicit_release=true
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
    --kernel-target)
      test "$#" -ge 2 || {
        echo "--kernel-target requires a value" >&2
        exit 64
      }
      kernel_target_parent="$2"
      shift 2
      ;;
    --source-revision)
      test "$#" -ge 2 || {
        echo "--source-revision requires a value" >&2
        exit 64
      }
      source_ref="$2"
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
if "$explicit_release"; then
  [[ "$target_identity_sha256" =~ ^[0-9a-f]{64}$ ]] || {
    echo "--kernel-release requires --target-identity-sha256 as lowercase SHA-256" >&2
    exit 64
  }
elif test -n "$target_identity_sha256"; then
  echo "--target-identity-sha256 requires --kernel-release" >&2
  exit 64
fi
: "${target:?set HP2R_TARGET or pass --target}"
hp2r_validate_target "$target"
if test -z "$release"; then
  release="$(ssh "$target" uname -r)"
fi
hp2r_validate_release "$release"
if "$explicit_release"; then
  target_dir="$(hp2r_release_path "$kernel_target_parent" "$release")"
  target_file="$target_dir/target.txt"
  hp2r_validate_inactive_target_manifest "$target_file" "$target_dir/root"
  hp2r_require_target_identity "$target_file" "$target_identity_sha256"
fi

cd "$repo_root"
release_source_root="${HP2R_RELEASE_SOURCE_ROOT:-$repo_root}"
release_source=false
if hp2r_release_source_available "$release_source_root"; then
  release_source=true
  identity="$release_source_root/release/source-identity.txt"
  source_revision="$(hp2r_manifest_value "$identity" source_revision)"
  source_tree="$(hp2r_manifest_value "$identity" source_tree)"
  hp2r_validate_release_source "$release_source_root" "$source_revision" "$source_tree"
  if test -n "$source_ref"; then
    test "$source_ref" = "$source_revision" || {
      echo "requested source revision does not match the extracted release" >&2
      exit 1
    }
  fi
else
  hp2r_require_clean_source
  workspace_tree="$(git rev-parse 'HEAD^{tree}')"
  if test -n "$source_ref"; then
    source_revision="$(git rev-parse --verify "$source_ref^{commit}")"
    source_tree="$(git rev-parse --verify "$source_ref^{tree}")"
    test "$source_tree" = "$workspace_tree" || {
      echo "source revision tree does not match the clean workspace: $source_ref" >&2
      exit 1
    }
  else
    workspace_revision="$(hp2r_resolve_build_revision)"
    source_revision="$workspace_revision"
    source_tree="$workspace_tree"
  fi
  hp2r_require_durable_source_revision "$source_revision"
fi
[[ "$source_revision" =~ ^[0-9a-f]{40}$ ]]
[[ "$source_tree" =~ ^[0-9a-f]{40}$ ]]
for source_path in \
  kernel/Kbuild \
  kernel/hyperpixel2r_kms_main.c \
  overlays/hyperpixel2r-kms-overlay.dts \
  packaging/70-hyperpixel2r-backlight.rules \
  scripts/common.sh \
  scripts/prepare-kbuild-host-tools.sh
do
  if "$release_source"; then
    hp2r_release_source_file "$release_source_root" "$source_path" >/dev/null
  else
    git cat-file -e "$source_revision:$source_path" || {
      echo "build source is not present in checked revision: $source_path" >&2
      exit 1
    }
  fi
done
if "$release_source"; then
  backlight_rule_source="$(hp2r_release_source_file "$release_source_root" "packaging/$HP2R_BACKLIGHT_RULE_FILE")"
else
  backlight_rule_source="$repo_root/packaging/$HP2R_BACKLIGHT_RULE_FILE"
fi
hp2r_validate_backlight_rule "$backlight_rule_source"

target_parent="$kernel_target_parent"
test -d "$target_parent" || {
  echo "missing target exports; run mise run export-target-kbuild" >&2
  exit 1
}
target_dir="$(hp2r_release_path "$target_parent" "$release")"
target_file="$target_dir/target.txt"
test -f "$target_file" || {
  echo "missing target export for $release; run mise run export-target-kbuild" >&2
  exit 1
}
hp2r_validate_target_manifest "$target_file"
test "$(hp2r_manifest_value "$target_file" kernel_release)" = "$release"
test "$(hp2r_manifest_value "$target_file" kernel_arch)" = aarch64
header_path="$(hp2r_manifest_value "$target_file" header_path)"
common_header_path="$(hp2r_manifest_value "$target_file" common_header_path)"
kbuild_path="$(hp2r_manifest_value "$target_file" kbuild_path)"
kernel_source_package="$(
  hp2r_manifest_value "$target_file" kernel_source_package
)"
kernel_source_version="$(
  hp2r_manifest_value "$target_file" kernel_source_version
)"
kernel_source_deb_package="$(
  hp2r_manifest_value "$target_file" kernel_source_deb_package
)"
kernel_source_deb_sha256="$(
  hp2r_manifest_value "$target_file" kernel_source_deb_sha256
)"
kernel_source_deb="$(
  hp2r_manifest_value "$target_file" kernel_source_deb
)"
base_dtb_path="$(hp2r_manifest_value "$target_file" base_dtb_path)"
base_dtb_sha256="$(
  hp2r_manifest_value "$target_file" base_dtb_sha256
)"
root_dir="$target_dir/root"
if "$explicit_release"; then
  hp2r_validate_inactive_target_manifest "$target_file" "$root_dir"
  hp2r_require_target_identity "$target_file" "$target_identity_sha256"
fi
config_path="$root_dir$header_path/.config"
test -f "$config_path"
test -f "$root_dir$header_path/Module.symvers"
test -d "$root_dir/usr/src"
test -d "$root_dir$common_header_path/include"
test -d "$root_dir$kbuild_path"
test -f "$root_dir$base_dtb_path"
test -f "$target_dir/$kernel_source_deb"
hp2r_verify_sha256 \
  "$target_dir/$kernel_source_deb" \
  "$kernel_source_deb_sha256" \
  "kernel source package"
hp2r_verify_sha256 \
  "$root_dir$base_dtb_path" \
  "$base_dtb_sha256" \
  "base DTB"

for setting in \
  CONFIG_DRM_PANEL=y \
  CONFIG_I2C_ALGOBIT=m \
  CONFIG_TOUCHSCREEN_EDT_FT5X06=m \
  CONFIG_OF_OVERLAY=y \
  CONFIG_DRM_VC4=m \
  CONFIG_DRM_V3D=m
do
  grep -Fqx "$setting" "$config_path" || {
    echo "target kernel is missing required setting: $setting" >&2
    exit 1
  }
done

image="${HP2R_KERNEL_BUILD_IMAGE:-$HP2R_DEFAULT_BUILD_IMAGE}"
hp2r_docker info >/dev/null 2>&1 || {
  command -v orbctl >/dev/null && orbctl start
}
for attempt in {1..30}; do
  hp2r_docker info >/dev/null 2>&1 && break
  sleep 1
done
hp2r_docker info >/dev/null
hp2r_docker buildx build \
  --load \
  --tag "$image" \
  --file packaging/Dockerfile.kernel \
  .

build_dir="$(mktemp -d "${TMPDIR:-/tmp}/hp2r-kernel-build.XXXXXX")"
staging_dir=""
cleanup() {
  rm -rf "$build_dir"
  if test -n "$staging_dir"; then
    rm -rf "$staging_dir"
  fi
}
trap cleanup EXIT
mkdir "$build_dir/source"
if "$release_source"; then
  mkdir -p "$build_dir/source/scripts"
  cp -R "$release_source_root/kernel" "$release_source_root/overlays" "$build_dir/source/"
  cp \
    "$release_source_root/scripts/common.sh" \
    "$release_source_root/scripts/prepare-kbuild-host-tools.sh" \
    "$build_dir/source/scripts/"
else
  git archive --format=tar "$source_revision" -- \
    kernel \
    overlays \
    scripts/common.sh \
    scripts/prepare-kbuild-host-tools.sh |
    tar -x -C "$build_dir/source"
fi
cp -R "$build_dir/source/kernel" "$build_dir/kernel"
mkdir "$build_dir/out"

overlay_revision="${source_revision:0:12}"
[[ "$overlay_revision" =~ ^[0-9a-f]{12}$ ]] || {
  echo "source revision does not have a 12-character hexadecimal prefix" >&2
  exit 1
}
overlay_file="hyperpixel2r-kms-${overlay_revision}.dtbo"
applied_dtb_file="hyperpixel2r-kms-applied.dtb"
hp2r_docker run --rm \
  --volume "$build_dir:/build" \
  --volume "$build_dir/source:/workspace:ro" \
  --volume "$target_dir:/target-export:ro" \
  "$image" \
  /workspace/scripts/prepare-kbuild-host-tools.sh \
    "/target-export/$kernel_source_deb" \
    "$kernel_source_deb_sha256" \
    "$kernel_source_package" \
    "$kernel_source_deb_package" \
    "$kernel_source_version" \
    "/target-export/root$header_path/.config" \
    "/target-export/root$kbuild_path" \
    /build/kbuild \
    /build/host-build

host_tools_file="$build_dir/host-build/host-tools.txt"
hp2r_validate_host_tools_manifest "$host_tools_file"
hp2r_docker run --rm \
  --volume "$build_dir:/build" \
  --volume "$build_dir/source:/workspace:ro" \
  --volume "$root_dir:/target-root:ro" \
  --volume "$root_dir/usr/src:/usr/src:ro" \
  --volume "$build_dir/kbuild:$kbuild_path:ro" \
  "$image" \
  sh -eu -c '
    ln -s /usr/bin/aarch64-linux-gnu-as /usr/local/bin/as
    ln -s /usr/bin/aarch64-linux-gnu-readelf /usr/local/bin/readelf
    make -C "/usr/src/linux-headers-$1" \
      M=/build/kernel \
      ARCH=arm64 \
      CROSS_COMPILE=aarch64-linux-gnu- \
      W=1 \
      modules
    cd /build/kernel
    file hyperpixel2r_kms.ko > module.file.txt
    readelf -h hyperpixel2r_kms.ko > module.readelf.txt
    modinfo hyperpixel2r_kms.ko > module.modinfo.txt
    sha256sum hyperpixel2r_kms.ko > module.sha256
    cat module.file.txt module.readelf.txt module.modinfo.txt
    aarch64-linux-gnu-gcc-14 \
      -E \
      -nostdinc \
      -undef \
      -D__DTS__ \
      -x assembler-with-cpp \
      -I"/target-root$3/include" \
      /workspace/overlays/hyperpixel2r-kms-overlay.dts \
      -o /build/hyperpixel2r-kms-overlay.preprocessed.dts
    if ! dtc \
      -@ \
      -I dts \
      -O dtb \
      -o "/build/out/$2" \
      /build/hyperpixel2r-kms-overlay.preprocessed.dts \
      2>/build/overlay-dtc.stderr
    then
      cat /build/overlay-dtc.stderr >&2
      exit 1
    fi
    if test -s /build/overlay-dtc.stderr; then
      echo "overlay compilation emitted warnings:" >&2
      cat /build/overlay-dtc.stderr >&2
      exit 1
    fi
    fdtoverlay \
      -i "/target-root$4" \
      -o "/build/out/$5" \
      "/build/out/$2"
  ' sh \
    "$release" \
    "$overlay_file" \
    "$common_header_path" \
    "$base_dtb_path" \
    "$applied_dtb_file"

hp2r_validate_overlay "$build_dir/out/$overlay_file" "$image"
if "$release_source"; then
  hp2r_validate_release_source "$release_source_root" "$source_revision" "$source_tree"
else
  hp2r_require_clean_source
  test "$(git rev-parse 'HEAD^{tree}')" = "$workspace_tree" || {
    echo "source tree changed while building artifacts" >&2
    exit 1
  }
  if test -n "$source_ref"; then
    test "$(git rev-parse --verify "$source_ref^{tree}")" = "$source_tree" || {
      echo "explicit source revision changed while building artifacts" >&2
      exit 1
    }
  else
    test "$(hp2r_resolve_build_revision)" = "$workspace_revision" || {
      echo "source revision changed while building artifacts" >&2
      exit 1
    }
  fi
  hp2r_require_durable_source_revision "$source_revision"
fi

mkdir -p "$output_parent"
output_parent="$(cd "$output_parent" && pwd -P)"
output_dir="$(hp2r_release_path "$output_parent" "$release")"
staging_dir="$(mktemp -d "$output_parent/.${release}.XXXXXX")"
cp \
  "$build_dir/kernel/hyperpixel2r_kms.ko" \
  "$build_dir/kernel/module.file.txt" \
  "$build_dir/kernel/module.readelf.txt" \
  "$build_dir/kernel/module.modinfo.txt" \
  "$build_dir/kernel/module.sha256" \
  "$build_dir/out/$overlay_file" \
  "$build_dir/out/$applied_dtb_file" \
  "$backlight_rule_source" \
  "$host_tools_file" \
  "$staging_dir/"
install -m 0755 \
  "$build_dir/kbuild/scripts/basic/fixdep" \
  "$staging_dir/host-fixdep"
install -m 0755 \
  "$build_dir/kbuild/scripts/mod/modpost" \
  "$staging_dir/host-modpost"
install -m 0755 \
  "$build_dir/kbuild/scripts/genksyms/genksyms" \
  "$staging_dir/host-genksyms"

module="$staging_dir/hyperpixel2r_kms.ko"
overlay="$staging_dir/$overlay_file"
applied_dtb="$staging_dir/$applied_dtb_file"
backlight_rule="$staging_dir/$HP2R_BACKLIGHT_RULE_FILE"
hp2r_validate_checksum_file "$staging_dir/module.sha256" "$module"
hp2r_write_checksum "$overlay" "$staging_dir/overlay.sha256"
hp2r_write_checksum "$applied_dtb" "$staging_dir/applied-dtb.sha256"
module_sha256="$(hp2r_sha256 "$module")"
overlay_sha256="$(hp2r_sha256 "$overlay")"
applied_dtb_sha256="$(hp2r_sha256 "$applied_dtb")"
backlight_rule_sha256="$(hp2r_sha256 "$backlight_rule")"
module_vermagic="$(
  awk -F ': *' '$1 == "vermagic" { sub(/^vermagic: */, ""); print; exit }' \
    "$staging_dir/module.modinfo.txt"
)"
module_license="$(
  awk -F ': *' '$1 == "license" { sub(/^license: */, ""); print; exit }' \
    "$staging_dir/module.modinfo.txt"
)"
test "$module_license" = GPL || {
  echo "driver module license metadata is invalid" >&2
  exit 1
}

{
  printf 'schema_version\t3\n'
  printf 'driver_version\t%s\n' "$HP2R_DRIVER_VERSION"
  printf 'source_revision\t%s\n' "$source_revision"
  printf 'source_tree\t%s\n' "$source_tree"
  printf 'kernel_release\t%s\n' "$release"
  printf 'architecture\taarch64\n'
  printf 'base_dtb_sha256\t%s\n' "$base_dtb_sha256"
  printf 'capability\t%s\n' "$HP2R_BACKLIGHT_CAPABILITY"
  printf 'lifecycle_capability\t%s\n' "$HP2R_LIFECYCLE_CAPABILITY"
  printf 'module_file\thyperpixel2r_kms.ko\n'
  printf 'module_sha256\t%s\n' "$module_sha256"
  printf 'module_vermagic\t%s\n' "$module_vermagic"
  printf 'overlay_file\t%s\n' "$overlay_file"
  printf 'overlay_sha256\t%s\n' "$overlay_sha256"
  printf 'applied_dtb_file\t%s\n' "$applied_dtb_file"
  printf 'applied_dtb_sha256\t%s\n' "$applied_dtb_sha256"
  printf 'backlight_rule_file\t%s\n' "$HP2R_BACKLIGHT_RULE_FILE"
  printf 'backlight_rule_sha256\t%s\n' "$backlight_rule_sha256"
} > "$staging_dir/manifest.txt"

hp2r_validate_artifact_provenance \
  "$staging_dir/manifest.txt" \
  "$target_file" \
  "$staging_dir"
hp2r_validate_checksum_file "$staging_dir/overlay.sha256" "$overlay"
hp2r_validate_checksum_file \
  "$staging_dir/applied-dtb.sha256" \
  "$applied_dtb"

if test -e "$output_dir"; then
  rm -rf "$output_dir"
fi
mv "$staging_dir" "$output_dir"
staging_dir=""
printf 'Built HyperPixel driver bundle at %s\n' "$output_dir"
