#!/usr/bin/env bash
set -euo pipefail

# Typed controller for the accepted-driver receipt and retained transition
# protocol.  The target half is copied for each invocation and is never a
# mutable installed dependency.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$repo_root/scripts/common.sh"

target="${HP2R_TARGET:-}"
action=''
driver_version=''
source_revision=''
kernel_release=''
kernel_target_parent="$repo_root/dist/kernel-target"
kernel_target_explicit=false
target_identity_sha256=''
manifest_sha256=''
module_file=''
module_sha256=''
overlay_file=''
overlay_sha256=''
backlight_rule_file=''
backlight_rule_sha256=''
while test "$#" -gt 0; do
  case "$1" in
    --target) test "$#" -ge 2 || exit 64; target="$2"; shift 2 ;;
    --action) test "$#" -ge 2 || exit 64; action="$2"; shift 2 ;;
    --driver-version) test "$#" -ge 2 || exit 64; driver_version="$2"; shift 2 ;;
    --source-revision) test "$#" -ge 2 || exit 64; source_revision="$2"; shift 2 ;;
    --kernel-release) test "$#" -ge 2 || exit 64; kernel_release="$2"; shift 2 ;;
    --kernel-target) test "$#" -ge 2 || exit 64; kernel_target_parent="$2"; kernel_target_explicit=true; shift 2 ;;
    --target-identity-sha256) test "$#" -ge 2 || exit 64; target_identity_sha256="$2"; shift 2 ;;
    --manifest-sha256) test "$#" -ge 2 || exit 64; manifest_sha256="$2"; shift 2 ;;
    --module-file) test "$#" -ge 2 || exit 64; module_file="$2"; shift 2 ;;
    --module-sha256) test "$#" -ge 2 || exit 64; module_sha256="$2"; shift 2 ;;
    --overlay-file) test "$#" -ge 2 || exit 64; overlay_file="$2"; shift 2 ;;
    --overlay-sha256) test "$#" -ge 2 || exit 64; overlay_sha256="$2"; shift 2 ;;
    --backlight-rule-file) test "$#" -ge 2 || exit 64; backlight_rule_file="$2"; shift 2 ;;
    --backlight-rule-sha256) test "$#" -ge 2 || exit 64; backlight_rule_sha256="$2"; shift 2 ;;
    -h|--help)
      echo 'Usage: accepted-lifecycle.sh --target TARGET --action ACTION [exact identity] [--kernel-target DIR --target-identity-sha256 SHA256]'
      exit 0
      ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
done
: "${target:?set HP2R_TARGET or pass --target}"
hp2r_validate_target "$target"
case "$action" in
  record|recover-record|stage-retained|uninstall|retire-inactive|prepare-new)
    [[ "$driver_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 64
    [[ "$source_revision" =~ ^[0-9a-f]{40}$ ]] || exit 64
    hp2r_validate_release "$kernel_release"
    ;;
  mark-committed|commit-retained|recover|mark-verified|finalize|finalize-uninstall)
    test -z "$driver_version$source_revision$kernel_release" || exit 64
    ;;
  *) echo 'unsupported accepted lifecycle action' >&2; exit 64 ;;
esac
if test "$action" = prepare-new; then
  [[ "$manifest_sha256" =~ ^[0-9a-f]{64}$ ]] || exit 64
  test "$module_file" = hyperpixel2r_kms.ko || exit 64
  [[ "$module_sha256" =~ ^[0-9a-f]{64}$ ]] || exit 64
  test "$overlay_file" = "hyperpixel2r-kms-${source_revision:0:12}.dtbo" || exit 64
  [[ "$overlay_sha256" =~ ^[0-9a-f]{64}$ ]] || exit 64
  test "$backlight_rule_file" = 70-planeradar-backlight.rules || exit 64
  [[ "$backlight_rule_sha256" =~ ^[0-9a-f]{64}$ ]] || exit 64
  if test -n "$target_identity_sha256"; then
    [[ "$target_identity_sha256" =~ ^[0-9a-f]{64}$ ]] || exit 64
  elif "$kernel_target_explicit"; then
    echo '--kernel-target requires --target-identity-sha256' >&2
    exit 64
  fi
else
  test -z "$manifest_sha256$module_file$module_sha256$overlay_file$overlay_sha256$backlight_rule_file$backlight_rule_sha256$target_identity_sha256" || exit 64
fi

ssh_options=(-o BatchMode=yes -o ConnectTimeout=8 -o ConnectionAttempts=1)
if test "$action" = prepare-new; then
  running_release="$(ssh "${ssh_options[@]}" "$target" uname -r)"
  hp2r_validate_release "$running_release"
  if test "$kernel_release" = "$running_release"; then
    test -z "$target_identity_sha256" || {
      echo 'same-kernel accepted prepare must not receive inactive target authority' >&2
      exit 64
    }
  else
    [[ "$target_identity_sha256" =~ ^[0-9a-f]{64}$ ]] || {
      echo 'inactive accepted prepare requires --target-identity-sha256' >&2
      exit 64
    }
    target_dir="$(hp2r_release_path "$kernel_target_parent" "$kernel_release")"
    target_manifest="$target_dir/target.txt"
    hp2r_validate_inactive_target_manifest "$target_manifest" "$target_dir/root"
    hp2r_require_target_identity "$target_manifest" "$target_identity_sha256"
    candidate_kernel_sha256="$(hp2r_manifest_value "$target_manifest" kernel_image_sha256)"
    candidate_initramfs_sha256="$(hp2r_manifest_value "$target_manifest" initramfs_sha256)"
    candidate_base_dtb_sha256="$(hp2r_manifest_value "$target_manifest" base_dtb_sha256)"
    candidate_vc4_overlay_sha256="$(hp2r_manifest_value "$target_manifest" vc4_overlay_sha256)"
  fi
fi
remote_stage=''
payload=''
cleanup() {
  local status=$?
  trap - EXIT
  if test -n "$remote_stage"; then
    ssh "${ssh_options[@]}" "$target" rm -rf -- "$remote_stage" >/dev/null 2>&1 || true
  fi
  test -z "$payload" || rm -rf -- "$payload"
  exit "$status"
}
trap cleanup EXIT
remote_stage="$(ssh "${ssh_options[@]}" "$target" mktemp -d /tmp/hp2r-accepted.XXXXXX)"
[[ "$remote_stage" =~ ^/tmp/hp2r-accepted\.[A-Za-z0-9]+$ ]] ||
  { echo 'target returned an unsafe accepted lifecycle path' >&2; exit 1; }
payload="$(mktemp -d "${TMPDIR:-/tmp}/hp2r-accepted.XXXXXX")"
install -m 0644 "$repo_root/scripts/lifecycle-remote.sh" "$payload/lifecycle-remote.sh"
scp "${ssh_options[@]}" -rp "$payload/." "$target:$remote_stage/"
case "$action" in
  record)
    ssh "${ssh_options[@]}" "$target" bash "$remote_stage/lifecycle-remote.sh" \
      record-accepted "$driver_version" "$source_revision" "$kernel_release"
    ;;
  recover-record)
    ssh "${ssh_options[@]}" "$target" bash "$remote_stage/lifecycle-remote.sh" \
      recover-accepted-record "$driver_version" "$source_revision" "$kernel_release"
    ;;
  prepare-new)
    prepare_args=(
      prepare-new-accepted "$driver_version" "$source_revision" "$kernel_release" \
      "$manifest_sha256" "$module_file" "$module_sha256" "$overlay_file" "$overlay_sha256" \
      "$backlight_rule_file" "$backlight_rule_sha256"
    )
    if test "$kernel_release" != "$running_release"; then
      prepare_args+=(
        "$target_identity_sha256" \
        "$candidate_kernel_sha256" "$candidate_initramfs_sha256" \
        "$candidate_base_dtb_sha256" "$candidate_vc4_overlay_sha256"
      )
    fi
    ssh "${ssh_options[@]}" "$target" bash "$remote_stage/lifecycle-remote.sh" \
      "${prepare_args[@]}"
    ;;
  stage-retained)
    ssh "${ssh_options[@]}" "$target" bash "$remote_stage/lifecycle-remote.sh" \
      stage-retained "$driver_version" "$source_revision" "$kernel_release"
    ;;
  mark-committed)
    ssh "${ssh_options[@]}" "$target" bash "$remote_stage/lifecycle-remote.sh" mark-committed-accepted
    ;;
  commit-retained)
    ssh "${ssh_options[@]}" "$target" bash "$remote_stage/lifecycle-remote.sh" commit-retained
    ;;
  recover)
    ssh "${ssh_options[@]}" "$target" bash "$remote_stage/lifecycle-remote.sh" recover-accepted
    ;;
  mark-verified)
    ssh "${ssh_options[@]}" "$target" bash "$remote_stage/lifecycle-remote.sh" mark-verified-accepted
    ;;
  finalize)
    ssh "${ssh_options[@]}" "$target" bash "$remote_stage/lifecycle-remote.sh" finalize-accepted
    ;;
  uninstall)
    ssh "${ssh_options[@]}" "$target" bash "$remote_stage/lifecycle-remote.sh" \
      uninstall-accepted "$driver_version" "$source_revision" "$kernel_release"
    ;;
  retire-inactive)
    ssh "${ssh_options[@]}" "$target" bash "$remote_stage/lifecycle-remote.sh" \
      retire-inactive "$driver_version" "$source_revision" "$kernel_release"
    ;;
  finalize-uninstall)
    ssh "${ssh_options[@]}" "$target" bash "$remote_stage/lifecycle-remote.sh" finalize-uninstall-accepted
    ;;
esac
ssh "${ssh_options[@]}" "$target" rm -rf -- "$remote_stage"
remote_stage=''
rm -rf -- "$payload"
payload=''
trap - EXIT
