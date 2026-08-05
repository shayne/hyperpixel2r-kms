#!/usr/bin/env bash
set -euo pipefail

# The fixture is the test.  These short checks are only lint around the
# executable target model, never substitutes for a lifecycle scenario.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
scripts=(
  scripts/stage-tryboot.sh
  scripts/verify-boot.sh
  scripts/commit-boot.sh
  scripts/rollback-boot.sh
  scripts/uninstall.sh
  scripts/accepted-lifecycle.sh
  scripts/lifecycle-remote.sh
)
for relative in "${scripts[@]}"; do
  test -f "$repo_root/$relative" && test ! -L "$repo_root/$relative"
  bash -n "$repo_root/$relative"
done
test -f "$repo_root/docs/operations.md"
for task in stage-tryboot verify-boot commit-boot rollback-boot uninstall; do grep -Fq "[tasks.$task]" "$repo_root/mise.toml"; done

fixture_runner="$repo_root/tests/boot-fixtures.sh"
test -f "$fixture_runner" && test ! -L "$fixture_runner"
image="${HP2R_BOOT_FIXTURE_IMAGE:-${HP2R_KERNEL_BUILD_IMAGE:-hyperpixel2r-kms-kernel-builder:debian-trixie-gcc14}}"
docker image inspect "$image" >/dev/null

# Keep the executable lifecycle suite hermetic.  A real exact-kernel bundle is
# deliberately a maintainer artifact, not CI input; these fixtures need only a
# regular, provenance-valid payload because their fake target never loads it.
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/hp2r-boot-repo.XXXXXX")"
fixture_repo="$fixture_root/repo"
trap 'rm -rf -- "$fixture_root"' EXIT
source_revision="$(git -C "$repo_root" rev-parse --verify 'origin/main^{commit}')"
git clone --quiet --no-hardlinks "$repo_root" "$fixture_repo"
git -C "$fixture_repo" checkout --quiet --detach "$source_revision"

# Overlay the tracked working files so a developer's uncommitted lifecycle
# change is tested too, while dist/ and other untracked deployment state stay
# outside the fixture repository.
while IFS= read -r -d '' relative_path; do
  test -f "$repo_root/$relative_path" && test ! -L "$repo_root/$relative_path"
  mkdir -p "$fixture_repo/$(dirname "$relative_path")"
  cp -p "$repo_root/$relative_path" "$fixture_repo/$relative_path"
done < <(git -C "$repo_root" ls-files -z)

release='6.18.34+rpt-rpi-v8'
source_tree="$(git -C "$fixture_repo" rev-parse "$source_revision^{tree}")"
artifact_dir="$fixture_repo/dist/artifacts/$release"
target_dir="$fixture_repo/dist/kernel-target/$release"
target_root="$target_dir/root"
mkdir -p \
  "$artifact_dir" \
  "$target_root/boot/firmware/overlays"
module_file='hyperpixel2r_kms.ko'
overlay_file="hyperpixel2r-kms-${source_revision:0:12}.dtbo"
applied_dtb_file='hyperpixel2r-kms-applied.dtb'
backlight_rule_file='70-planeradar-backlight.rules'
printf 'synthetic module fixture\n' > "$artifact_dir/$module_file"
printf 'synthetic overlay fixture\n' > "$artifact_dir/$overlay_file"
printf 'synthetic applied dtb fixture\n' > "$artifact_dir/$applied_dtb_file"
printf '%s\n' 'SUBSYSTEM=="backlight", KERNEL=="planeradar-backlight", RUN+="/usr/bin/chgrp video /sys%p/brightness", RUN+="/usr/bin/chmod 0660 /sys%p/brightness"' > "$artifact_dir/$backlight_rule_file"
for helper in host-fixdep host-modpost host-genksyms; do
  printf 'synthetic %s fixture\n' "$helper" > "$artifact_dir/$helper"
done

module_sha256="$(sha256sum "$artifact_dir/$module_file" | awk '{print $1}')"
overlay_sha256="$(sha256sum "$artifact_dir/$overlay_file" | awk '{print $1}')"
applied_dtb_sha256="$(sha256sum "$artifact_dir/$applied_dtb_file" | awk '{print $1}')"
backlight_rule_sha256="$(sha256sum "$artifact_dir/$backlight_rule_file" | awk '{print $1}')"
host_fixdep_sha256="$(sha256sum "$artifact_dir/host-fixdep" | awk '{print $1}')"
host_modpost_sha256="$(sha256sum "$artifact_dir/host-modpost" | awk '{print $1}')"
host_genksyms_sha256="$(sha256sum "$artifact_dir/host-genksyms" | awk '{print $1}')"
source_deb_sha256='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
target_identity_sha256='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
kernel_image_path="/boot/vmlinuz-$release"
initramfs_path="/boot/initrd.img-$release"
base_dtb_path='/boot/firmware/bcm2710-rpi-zero-2-w.dtb'
vc4_overlay_path='/boot/firmware/overlays/vc4-kms-v3d.dtbo'
printf 'synthetic candidate kernel fixture\n' > "$target_root$kernel_image_path"
printf 'synthetic candidate initramfs fixture\n' > "$target_root$initramfs_path"
printf 'synthetic base DTB fixture\n' > "$target_root$base_dtb_path"
printf 'synthetic VC4 overlay fixture\n' > "$target_root$vc4_overlay_path"
kernel_image_sha256="$(sha256sum "$target_root$kernel_image_path" | awk '{print $1}')"
initramfs_sha256="$(sha256sum "$target_root$initramfs_path" | awk '{print $1}')"
base_dtb_sha256="$(sha256sum "$target_root$base_dtb_path" | awk '{print $1}')"
vc4_overlay_sha256="$(sha256sum "$target_root$vc4_overlay_path" | awk '{print $1}')"

{
  printf 'schema_version\t2\n'
  printf 'driver_version\t0.1.1\n'
  printf 'source_revision\t%s\n' "$source_revision"
  printf 'source_tree\t%s\n' "$source_tree"
  printf 'kernel_release\t%s\n' "$release"
  printf 'architecture\taarch64\n'
  printf 'base_dtb_sha256\t%s\n' "$base_dtb_sha256"
  printf 'capability\tpwm-backlight-v1\n'
  printf 'module_file\t%s\n' "$module_file"
  printf 'module_sha256\t%s\n' "$module_sha256"
  printf 'module_vermagic\t%s fixture\n' "$release"
  printf 'overlay_file\t%s\n' "$overlay_file"
  printf 'overlay_sha256\t%s\n' "$overlay_sha256"
  printf 'applied_dtb_file\t%s\n' "$applied_dtb_file"
  printf 'applied_dtb_sha256\t%s\n' "$applied_dtb_sha256"
  printf 'backlight_rule_file\t%s\n' "$backlight_rule_file"
  printf 'backlight_rule_sha256\t%s\n' "$backlight_rule_sha256"
} > "$artifact_dir/manifest.txt"
{
  printf 'host_arch\tx86_64\n'
  printf 'kernel_source_package\tlinux\n'
  printf 'kernel_source_deb_package\tlinux-source-6.18\n'
  printf 'kernel_source_version\t6.18.34-1\n'
  printf 'kernel_source_sha256\t%s\n' "$source_deb_sha256"
  printf 'host_fixdep_sha256\t%s\n' "$host_fixdep_sha256"
  printf 'host_modpost_sha256\t%s\n' "$host_modpost_sha256"
  printf 'host_genksyms_sha256\t%s\n' "$host_genksyms_sha256"
} > "$artifact_dir/host-tools.txt"
{
  printf 'schema_version\t2\n'
  printf 'target_identity_sha256\t%s\n' "$target_identity_sha256"
  printf 'kernel_release\t%s\n' "$release"
  printf 'kernel_arch\taarch64\n'
  printf 'header_path\t/usr/src/linux-headers-6.18.34+rpt-rpi-v8\n'
  printf 'common_header_path\t/usr/src/linux-headers-6.18.34+rpt-common-rpi\n'
  printf 'kbuild_path\t/usr/lib/linux-kbuild-6.18.34+rpt\n'
  printf 'kernel_source_package\tlinux\n'
  printf 'kernel_source_version\t6.18.34-1\n'
  printf 'kernel_source_deb_package\tlinux-source-6.18\n'
  printf 'kernel_source_deb_filename\tpool/main/l/linux/linux-source-6.18_6.18.34-1_all.deb\n'
  printf 'kernel_source_deb_sha256\t%s\n' "$source_deb_sha256"
  printf 'kernel_source_deb\tkernel-source.deb\n'
  printf 'base_dtb_path\t%s\n' "$base_dtb_path"
  printf 'base_dtb_sha256\t%s\n' "$base_dtb_sha256"
  printf 'kernel_image_path\t%s\n' "$kernel_image_path"
  printf 'kernel_image_sha256\t%s\n' "$kernel_image_sha256"
  printf 'initramfs_path\t%s\n' "$initramfs_path"
  printf 'initramfs_sha256\t%s\n' "$initramfs_sha256"
  printf 'vc4_overlay_path\t%s\n' "$vc4_overlay_path"
  printf 'vc4_overlay_sha256\t%s\n' "$vc4_overlay_sha256"
} > "$target_dir/target.txt"

docker run --rm \
  --volume "$fixture_repo:/repo:ro" \
  --workdir /repo \
  --env HP2R_FIXTURE_REPO_ROOT=/repo \
  --env HP2R_FIXTURE_CASE="${HP2R_FIXTURE_CASE:-}" \
  --env HP2R_FIXTURE_INTERRUPT_AFTER="${HP2R_FIXTURE_INTERRUPT_AFTER:-}" \
  --env HP2R_FIXTURE_RETIRE_BOUNDARY="${HP2R_FIXTURE_RETIRE_BOUNDARY:-}" \
  --env HP2R_FIXTURE_FAIL_AFTER_STAGED_PUBLICATION="${HP2R_FIXTURE_FAIL_AFTER_STAGED_PUBLICATION:-}" \
  --env HP2R_FIXTURE_HOSTILE="${HP2R_FIXTURE_HOSTILE:-}" \
  "$image" \
  bash tests/boot-fixtures.sh

printf 'Driver boot lifecycle executable fixtures passed\n'
