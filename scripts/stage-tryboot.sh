#!/usr/bin/env bash
set -euo pipefail

# Stage one verified candidate in firmware tryboot.txt.  The normal boot
# configuration is never changed by this command.
umask 022
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$repo_root/scripts/common.sh"

usage() {
  cat <<'USAGE'
Usage: stage-tryboot.sh [OPTIONS]

Options:
  --target TARGET              SSH target (or set HP2R_TARGET)
  --artifact-dir DIR           Exact-kernel artifact directory
  --kernel-target DIR          Exported kernel target parent (default: dist/kernel-target)
  --kernel-release RELEASE     Inactive candidate release (requires target identity)
  --target-identity-sha256 SHA256
                              Exact identity for the inactive target export
  --replace-overlay NAME       Replace exactly one declared overlay NAME
  --stage-only                 Stage the candidate without requesting a reboot
  -h, --help                   Show this help
USAGE
}

target="${HP2R_TARGET:-}"
artifact_dir=''
kernel_target_parent="$repo_root/dist/kernel-target"
requested_release=''
target_identity_sha256=''
replace_overlay=''
stage_only=false
while test "$#" -gt 0; do
  case "$1" in
    --target) test "$#" -ge 2 || { echo '--target requires a value' >&2; exit 64; }; target="$2"; shift 2 ;;
    --artifact-dir) test "$#" -ge 2 || { echo '--artifact-dir requires a value' >&2; exit 64; }; artifact_dir="$2"; shift 2 ;;
    --kernel-target) test "$#" -ge 2 || { echo '--kernel-target requires a value' >&2; exit 64; }; kernel_target_parent="$2"; shift 2 ;;
    --kernel-release) test "$#" -ge 2 || { echo '--kernel-release requires a value' >&2; exit 64; }; requested_release="$2"; shift 2 ;;
    --target-identity-sha256) test "$#" -ge 2 || { echo '--target-identity-sha256 requires a value' >&2; exit 64; }; target_identity_sha256="$2"; shift 2 ;;
    --replace-overlay) test "$#" -ge 2 || { echo '--replace-overlay requires a value' >&2; exit 64; }; replace_overlay="$2"; shift 2 ;;
    --stage-only) stage_only=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 64 ;;
  esac
done
: "${target:?set HP2R_TARGET or pass --target}"
hp2r_validate_target "$target"
if test -n "$requested_release"; then
  hp2r_validate_release "$requested_release"
  [[ "$target_identity_sha256" =~ ^[0-9a-f]{64}$ ]] || {
    echo '--kernel-release requires --target-identity-sha256 as lowercase SHA-256' >&2
    exit 64
  }
elif test -n "$target_identity_sha256"; then
  echo '--target-identity-sha256 requires --kernel-release' >&2
  exit 64
fi
case "$replace_overlay" in ''|*[!A-Za-z0-9._+-]*) test -z "$replace_overlay" || { echo "unsafe replacement overlay: $replace_overlay" >&2; exit 1; } ;; esac

ssh_options=(-o BatchMode=yes -o ConnectTimeout=8 -o ConnectionAttempts=1)
running_release="$(ssh "${ssh_options[@]}" "$target" uname -r)"
hp2r_validate_release "$running_release"
if test -n "$requested_release"; then
  test "$requested_release" != "$running_release" || {
    echo 'same-kernel stage must not receive inactive target authority' >&2
    exit 64
  }
  release="$requested_release"
  target_dir="$(hp2r_release_path "$kernel_target_parent" "$release")"
  target_manifest="$target_dir/target.txt"
  hp2r_validate_inactive_target_manifest "$target_manifest" "$target_dir/root"
  hp2r_require_target_identity "$target_manifest" "$target_identity_sha256"
else
  release="$running_release"
fi
if test -z "$artifact_dir"; then artifact_dir="$(hp2r_release_path "$repo_root/dist/artifacts" "$release")"; fi
test ! -L "$artifact_dir" && test -d "$artifact_dir" || { echo "artifact directory is missing or a symlink: $artifact_dir" >&2; exit 1; }
artifact_dir="$(cd "$artifact_dir" && pwd -P)"
manifest="$artifact_dir/manifest.txt"
target_manifest="$(hp2r_release_path "$kernel_target_parent" "$release")/target.txt"
hp2r_validate_artifact_provenance "$manifest" "$target_manifest" "$artifact_dir"

source_revision="$(hp2r_manifest_value "$manifest" source_revision)"
source_tree="$(hp2r_manifest_value "$manifest" source_tree)"
driver_version="$(hp2r_manifest_value "$manifest" driver_version)"
module_file="$(hp2r_manifest_value "$manifest" module_file)"
overlay_file="$(hp2r_manifest_value "$manifest" overlay_file)"
applied_dtb_file="$(hp2r_manifest_value "$manifest" applied_dtb_file)"
backlight_rule_file="$(hp2r_manifest_value "$manifest" backlight_rule_file)"
[[ "$source_revision" =~ ^[0-9a-f]{40}$ && "$source_tree" =~ ^[0-9a-f]{40}$ ]]
release_source_root="${HP2R_RELEASE_SOURCE_ROOT:-$repo_root}"
if hp2r_release_source_available "$release_source_root"; then
  hp2r_validate_release_source "$release_source_root" "$source_revision" "$source_tree"
else
  git cat-file -e "$source_revision^{commit}" || { echo 'artifact source revision is unavailable locally' >&2; exit 1; }
  test "$(git rev-parse "$source_revision^{tree}")" = "$source_tree" || { echo 'artifact source tree does not match its revision' >&2; exit 1; }
fi
test "$driver_version" = "$HP2R_DRIVER_VERSION"
test "$(hp2r_manifest_value "$manifest" kernel_release)" = "$release"

require_regular() {
  test ! -L "$1" && test -f "$1" || { echo "required regular file is missing: $1" >&2; exit 1; }
}
for artifact in "$manifest" "$artifact_dir/$module_file" "$artifact_dir/$overlay_file" "$artifact_dir/$applied_dtb_file" "$artifact_dir/$backlight_rule_file"; do require_regular "$artifact"; done
hp2r_verify_sha256 "$artifact_dir/$module_file" "$(hp2r_manifest_value "$manifest" module_sha256)" 'driver module'
hp2r_verify_sha256 "$artifact_dir/$overlay_file" "$(hp2r_manifest_value "$manifest" overlay_sha256)" 'driver overlay'
hp2r_verify_sha256 "$artifact_dir/$applied_dtb_file" "$(hp2r_manifest_value "$manifest" applied_dtb_sha256)" 'applied DTB'
hp2r_validate_backlight_rule "$artifact_dir/$backlight_rule_file"
hp2r_verify_sha256 "$artifact_dir/$backlight_rule_file" "$(hp2r_manifest_value "$manifest" backlight_rule_sha256)" 'backlight rule'

if test -n "$requested_release"; then
  candidate_kernel_sha256="$(hp2r_manifest_value "$target_manifest" kernel_image_sha256)"
  candidate_initramfs_sha256="$(hp2r_manifest_value "$target_manifest" initramfs_sha256)"
  candidate_base_dtb_sha256="$(hp2r_manifest_value "$target_manifest" base_dtb_sha256)"
  candidate_vc4_overlay_sha256="$(hp2r_manifest_value "$target_manifest" vc4_overlay_sha256)"
  release_tag="$(printf %s "$release" | sha256sum | awk '{ print substr($1, 1, 12) }')"
  candidate_kernel_file="hp2r-${source_revision:0:12}-${release_tag}-kernel.img"
  candidate_initramfs_file="hp2r-${source_revision:0:12}-${release_tag}-initramfs.img"
  authorization="$(ssh "${ssh_options[@]}" "$target" bash -s -- authorize-inactive-stage < "$repo_root/scripts/lifecycle-remote.sh")"
  IFS=$'\t' read -r authorized_release authorized_kernel_file authorized_kernel_sha \
    authorized_initramfs_file authorized_initramfs_sha authorized_base_dtb_sha \
    authorized_vc4_overlay_sha authorized_transition_sha extra <<<"$authorization"
  test -z "${extra:-}" &&
    test "$authorized_release" = "$release" &&
    test "$authorized_kernel_file" = "$candidate_kernel_file" &&
    test "$authorized_kernel_sha" = "$candidate_kernel_sha256" &&
    test "$authorized_initramfs_file" = "$candidate_initramfs_file" &&
    test "$authorized_initramfs_sha" = "$candidate_initramfs_sha256" &&
    test "$authorized_base_dtb_sha" = "$candidate_base_dtb_sha256" &&
    test "$authorized_vc4_overlay_sha" = "$candidate_vc4_overlay_sha256" &&
    [[ "$authorized_transition_sha" =~ ^[0-9a-f]{64}$ ]] || {
      echo 'inactive stage authorization does not match the local candidate authority' >&2
      exit 1
    }
fi

payload="$(mktemp -d "${TMPDIR:-/tmp}/hp2r-tryboot-payload.XXXXXX")"
remote_stage=''
cleanup() {
  local status=$?
  if test -n "$remote_stage"; then ssh "${ssh_options[@]}" "$target" rm -rf -- "$remote_stage" >/dev/null 2>&1 || true; fi
  rm -rf -- "$payload"
  exit "$status"
}
trap cleanup EXIT
mkdir -p "$payload/dkms-source"
for artifact in "$manifest" "$artifact_dir/$module_file" "$artifact_dir/$overlay_file" "$artifact_dir/$applied_dtb_file" "$artifact_dir/$backlight_rule_file"; do install -m 0644 "$artifact" "$payload/$(basename "$artifact")"; done
install -m 0644 "$repo_root/scripts/lifecycle-remote.sh" "$payload/lifecycle-remote.sh"

# Source is materialized from the artifact's committed revision, never from a
# possibly changed controller checkout.  The remote validates this complete
# tree before reusing or registering it with DKMS.
kernel_sources=(Kbuild Makefile dkms.conf hyperpixel2r_kms_main.c hyperpixel2r_kms_gpio.c hyperpixel2r_kms_gpio.h hyperpixel2r_kms_protocol.c hyperpixel2r_kms_protocol.h)
for name in "${kernel_sources[@]}"; do
  if hp2r_release_source_available "$release_source_root"; then
    source_file="$(hp2r_release_source_file "$release_source_root" "kernel/$name")"
    cp "$source_file" "$payload/dkms-source/$name"
  else
    git show "$source_revision:kernel/$name" > "$payload/dkms-source/$name"
  fi
  test -s "$payload/dkms-source/$name" || { echo "committed kernel source is empty: $name" >&2; exit 1; }
  chmod 0644 "$payload/dkms-source/$name"
done

remote_stage="$(ssh "${ssh_options[@]}" "$target" mktemp -d /tmp/hp2r-tryboot-stage.XXXXXX)"
[[ "$remote_stage" =~ ^/tmp/hp2r-tryboot-stage\.[A-Za-z0-9]+$ ]] || { echo "target returned an unsafe staging path: $remote_stage" >&2; exit 1; }
scp "${ssh_options[@]}" -rp "$payload/." "$target:$remote_stage/"
ssh "${ssh_options[@]}" "$target" bash "$remote_stage/lifecycle-remote.sh" stage \
  "$remote_stage" "$driver_version" "$source_revision" "$source_tree" "$release" \
  "$module_file" "$overlay_file" "$applied_dtb_file" "$backlight_rule_file" "$replace_overlay"

# Delete the validated incoming payload before the reboot is requested.  The
# transaction is fully published on target at this point; keeping /tmp input
# around can only widen a later recovery surface.
ssh "${ssh_options[@]}" "$target" rm -rf -- "$remote_stage"
remote_stage=''
if "$stage_only"; then
  printf 'Staged tryboot candidate without requesting a reboot\n'
  exit 0
fi
set +e
ssh "${ssh_options[@]}" "$target" "sudo reboot '0 tryboot'" >/dev/null 2>&1
reboot_status=$?
set -e
case "$reboot_status" in 0|255) ;; *) echo "tryboot reboot command failed with status $reboot_status" >&2; exit "$reboot_status";; esac
printf 'Requested one-shot tryboot reboot for %s\n' "$target"
