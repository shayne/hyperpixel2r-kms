#!/usr/bin/env bash
set -euo pipefail

# Typed controller for the accepted-driver receipt and retained transition
# protocol. The target half is streamed into one privileged shell for each
# invocation and is never a mutable installed dependency.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$repo_root/scripts/common.sh"

target="${HP2R_TARGET:-}"
action=''
action_seen=false
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
lifecycle_capability=''
while test "$#" -gt 0; do
  case "$1" in
    --target) test "$#" -ge 2 || exit 64; target="$2"; shift 2 ;;
    --action)
      test "$#" -ge 2 && ! "$action_seen" || exit 64
      action="$2"
      action_seen=true
      shift 2
      ;;
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
    --lifecycle-capability) test "$#" -ge 2 || exit 64; lifecycle_capability="$2"; shift 2 ;;
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
  mark-committed|commit-retained|recover|mark-verified|mark-explicit-normal-verified|normalize-inactive-kernel|mark-normalized-verified|finalize|finalize-uninstall)
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
  test "$backlight_rule_file" = 70-hyperpixel2r-backlight.rules || exit 64
  [[ "$backlight_rule_sha256" =~ ^[0-9a-f]{64}$ ]] || exit 64
  case "$lifecycle_capability" in
    ''|exact-backlight-metadata-v1) ;;
    *) exit 64 ;;
  esac
  if test -n "$target_identity_sha256"; then
    [[ "$target_identity_sha256" =~ ^[0-9a-f]{64}$ ]] || exit 64
  elif "$kernel_target_explicit"; then
    echo '--kernel-target requires --target-identity-sha256' >&2
    exit 64
  fi
else
  test -z "$manifest_sha256$module_file$module_sha256$overlay_file$overlay_sha256$backlight_rule_file$backlight_rule_sha256$lifecycle_capability$target_identity_sha256" || exit 64
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
normal_probe=''
run_lifecycle() {
  hp2r_run_remote_lifecycle "$target" "$repo_root/scripts/lifecycle-remote.sh" "$@"
}
case "$action" in
  mark-explicit-normal-verified) expected_phase=explicit_normal_published ;;
  mark-normalized-verified) expected_phase=normalized_config_published ;;
  *) expected_phase='' ;;
esac
if test -n "$expected_phase"; then
  normal_probe="$(run_lifecycle \
    accepted-normal-probe "$expected_phase")"
  [[ "$normal_probe" =~ ^("$expected_phase")$'\t'([0-9]+\.[0-9]+\.[0-9]+)$'\t'(hyperpixel2r-kms-[0-9a-f]{12}\.dtbo)$'\t'([A-Za-z0-9._+-]+)$'\t'(hyperpixel2r_kms\.ko)$'\t'([0-9a-f]{64})$ ]] || {
    echo 'target returned an unsafe accepted normal probe' >&2
    exit 1
  }
  "$repo_root/scripts/verify-boot.sh" --target "$target" --expect-normal \
    --expect-kernel-release "${BASH_REMATCH[4]}" \
    --expect-driver-version "${BASH_REMATCH[2]}" \
    --expect-overlay-file "${BASH_REMATCH[3]}" \
    --expect-module-file "${BASH_REMATCH[5]}" \
    --expect-module-sha256 "${BASH_REMATCH[6]}" >/dev/null
fi
case "$action" in
  record)
    run_lifecycle \
      record-accepted "$driver_version" "$source_revision" "$kernel_release"
    ;;
  recover-record)
    run_lifecycle \
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
    if test -n "$lifecycle_capability"; then
      prepare_args+=("$lifecycle_capability")
    fi
    run_lifecycle \
      "${prepare_args[@]}"
    ;;
  stage-retained)
    run_lifecycle \
      stage-retained "$driver_version" "$source_revision" "$kernel_release"
    ;;
  mark-committed)
    run_lifecycle mark-committed-accepted
    ;;
  commit-retained)
    run_lifecycle commit-retained
    ;;
  recover)
    run_lifecycle recover-accepted
    ;;
  mark-verified)
    run_lifecycle mark-verified-accepted
    ;;
  mark-explicit-normal-verified)
    run_lifecycle mark-explicit-normal-verified-accepted
    ;;
  normalize-inactive-kernel)
    run_lifecycle normalize-inactive-kernel-accepted
    ;;
  mark-normalized-verified)
    run_lifecycle mark-normalized-verified-accepted
    ;;
  finalize)
    run_lifecycle finalize-accepted
    ;;
  uninstall)
    run_lifecycle \
      uninstall-accepted "$driver_version" "$source_revision" "$kernel_release"
    ;;
  retire-inactive)
    run_lifecycle \
      retire-inactive "$driver_version" "$source_revision" "$kernel_release"
    ;;
  finalize-uninstall)
    run_lifecycle finalize-uninstall-accepted
    ;;
esac
