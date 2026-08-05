#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
required_scripts=(
  "scripts/export-target-kbuild.sh"
  "scripts/build-driver.sh"
  "scripts/check-artifacts.sh"
  "scripts/prepare-kbuild-host-tools.sh"
  "scripts/common.sh"
)
missing=0

for relative_path in "${required_scripts[@]}"; do
  if [[ ! -f "$repo_root/$relative_path" ]]; then
    printf 'missing driver command: %s\n' "$relative_path" >&2
    missing=1
  fi
done

if (( missing != 0 )); then
  exit 1
fi

if grep -EnH '[[:alnum:]_.-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}' \
    "${required_scripts[@]/#/$repo_root/}"; then
  printf 'driver scripts must not contain a hard-coded user-at-host target\n' >&2
  exit 1
fi

legacy_input_prefix="PLANE""RADAR_"
if grep -EnH "$legacy_input_prefix" "${required_scripts[@]/#/$repo_root/}"; then
  printf 'driver scripts must use HP2R inputs, not legacy project inputs\n' >&2
  exit 1
fi

if ! grep -q 'HP2R_TARGET' "${required_scripts[@]/#/$repo_root/}"; then
  printf 'driver scripts must expose HP2R_TARGET\n' >&2
  exit 1
fi

help_output="$("$repo_root/scripts/build-driver.sh" --help)"
for option in --target --kernel-release --target-identity-sha256 --kernel-target --source-revision --output; do
  if [[ "$help_output" != *"$option"* ]]; then
    printf 'build-driver.sh --help must document %s\n' "$option" >&2
    exit 1
  fi
done

check_help_output="$("$repo_root/scripts/check-artifacts.sh" --help)"
for option in --kernel-target --target-identity-sha256; do
  if [[ "$check_help_output" != *"$option"* ]]; then
    printf 'check-artifacts.sh --help must document %s\n' "$option" >&2
    exit 1
  fi
done

stage_help_output="$("$repo_root/scripts/stage-tryboot.sh" --help)"
for option in --kernel-target --stage-only; do
  if [[ "$stage_help_output" != *"$option"* ]]; then
    printf 'stage-tryboot.sh --help must document %s\n' "$option" >&2
    exit 1
  fi
done

temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/hp2r-build-contract.XXXXXX")"
trap 'rm -rf "$temporary_dir"' EXIT
valid_manifest="$temporary_dir/manifest.txt"
backlight_rule="$temporary_dir/70-planeradar-backlight.rules"
printf '%s\n' 'SUBSYSTEM=="backlight", KERNEL=="planeradar-backlight", RUN+="/usr/bin/chgrp video /sys%p/brightness", RUN+="/usr/bin/chmod 0660 /sys%p/brightness"' > "$backlight_rule"
backlight_rule_sha256="$(sha256sum "$backlight_rule" | awk '{ print $1 }')"
cat > "$valid_manifest" <<'MANIFEST'
schema_version	2
driver_version	0.1.1
source_revision	0000000000000000000000000000000000000000
source_tree	1111111111111111111111111111111111111111
kernel_release	6.18.34+rpt-rpi-v8
architecture	aarch64
base_dtb_sha256	2222222222222222222222222222222222222222222222222222222222222222
capability	pwm-backlight-v1
module_file	hyperpixel2r_kms.ko
module_sha256	3333333333333333333333333333333333333333333333333333333333333333
module_vermagic	6.18.34+rpt-rpi-v8 SMP preempt mod_unload aarch64
overlay_file	hyperpixel2r-kms-000000000000.dtbo
overlay_sha256	4444444444444444444444444444444444444444444444444444444444444444
applied_dtb_file	hyperpixel2r-kms-applied.dtb
applied_dtb_sha256	5555555555555555555555555555555555555555555555555555555555555555
backlight_rule_file	70-planeradar-backlight.rules
backlight_rule_sha256	BACKLIGHT_RULE_SHA256
MANIFEST
sed -i.bak "s/BACKLIGHT_RULE_SHA256/$backlight_rule_sha256/" "$valid_manifest"
rm -f "$valid_manifest.bak"

validate_manifest() {
  bash -eu -c \
    'source "$1"; hp2r_validate_artifact_manifest "$2"' \
    bash \
    "$repo_root/scripts/common.sh" \
    "$1"
}

validate_manifest "$valid_manifest"
for mutation in duplicate missing unknown absolute traversal trailing wrong-capability renamed-rule; do
  invalid_manifest="$temporary_dir/$mutation.txt"
  case "$mutation" in
    duplicate)
      {
        cat "$valid_manifest"
        printf 'module_file\thyperpixel2r_kms.ko\n'
      } > "$invalid_manifest"
      ;;
    missing)
      grep -v '^module_file	' "$valid_manifest" > "$invalid_manifest"
      ;;
    unknown)
      sed 's/^module_file	/unknown_file	/' \
        "$valid_manifest" > "$invalid_manifest"
      ;;
    absolute)
      sed 's#^module_file	.*#module_file	/tmp/hyperpixel2r_kms.ko#' \
        "$valid_manifest" > "$invalid_manifest"
      ;;
    traversal)
      sed 's#^module_file	.*#module_file	../hyperpixel2r_kms.ko#' \
        "$valid_manifest" > "$invalid_manifest"
      ;;
    trailing)
      sed 's/^module_file	.*$/module_file	hyperpixel2r_kms.ko	extra/' \
        "$valid_manifest" > "$invalid_manifest"
      ;;
    wrong-capability)
      sed 's/^capability	.*$/capability	gpio-backlight-v1/' \
        "$valid_manifest" > "$invalid_manifest"
      ;;
    renamed-rule)
      sed 's/^backlight_rule_file	.*$/backlight_rule_file	99-display.rules/' \
        "$valid_manifest" > "$invalid_manifest"
      ;;
  esac
  if validate_manifest "$invalid_manifest" >/dev/null 2>&1; then
    printf 'artifact manifest accepted %s data\n' "$mutation" >&2
    exit 1
  fi
done

validate_rule() {
  bash -eu -c \
    'source "$1"; hp2r_validate_backlight_rule "$2"' \
    bash \
    "$repo_root/scripts/common.sh" \
    "$1"
}

validate_rule "$backlight_rule"
for mutation in broad tampered extra; do
  invalid_rule="$temporary_dir/$mutation.rules"
  case "$mutation" in
    broad)
      printf '%s\n' 'SUBSYSTEM=="backlight", RUN+="/usr/bin/chgrp video /sys%p/brightness", RUN+="/usr/bin/chmod 0660 /sys%p/brightness"' > "$invalid_rule"
      ;;
    tampered)
      printf '%s\n' 'SUBSYSTEM=="backlight", KERNEL=="planeradar-backlight", RUN+="/usr/bin/chgrp video /sys%p/actual_brightness", RUN+="/usr/bin/chmod 0660 /sys%p/actual_brightness"' > "$invalid_rule"
      ;;
    extra)
      {
        cat "$backlight_rule"
        printf '%s\n' 'SUBSYSTEM=="backlight", MODE="0666"'
      } > "$invalid_rule"
      ;;
  esac
  if validate_rule "$invalid_rule" >/dev/null 2>&1; then
    printf 'backlight rule validator accepted %s permissions\n' "$mutation" >&2
    exit 1
  fi
done

no_probe_bin="$temporary_dir/no-probe-bin"
no_probe_log="$temporary_dir/no-probe-ssh.log"
mkdir -p "$no_probe_bin"
cat > "$no_probe_bin/ssh" <<'NO_PROBE_SSH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HP2R_NO_PROBE_LOG"
exit 97
NO_PROBE_SSH
chmod +x "$no_probe_bin/ssh"
for command in scripts/build-driver.sh scripts/check-artifacts.sh; do
  pairing_error="$temporary_dir/$(basename "$command").pairing-error"
  set +e
  PATH="$no_probe_bin:$PATH" \
    HP2R_NO_PROBE_LOG="$no_probe_log" \
    "$repo_root/$command" \
      --target fixture-target \
      --target-identity-sha256 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
      >"$pairing_error" 2>&1
  pairing_status=$?
  set -e
  test "$pairing_status" = 64 || {
    cat "$pairing_error" >&2
    printf '%s did not reject unpaired candidate identity with exit 64\n' "$command" >&2
    exit 1
  }
  grep -Fq -- '--target-identity-sha256 requires --kernel-release' "$pairing_error" || {
    cat "$pairing_error" >&2
    printf '%s did not report the candidate option pairing error\n' "$command" >&2
    exit 1
  }
done
test ! -e "$no_probe_log" || {
  cat "$no_probe_log" >&2
  printf 'candidate option validation opened an SSH connection\n' >&2
  exit 1
}

validate_target_manifest() {
  bash -eu -c \
    'source "$1"; hp2r_validate_target_manifest "$2"' \
    bash \
    "$repo_root/scripts/common.sh" \
    "$1"
}

validate_inactive_target_manifest() {
  bash -eu -c \
    'source "$1"; hp2r_validate_inactive_target_manifest "$2" "$3"' \
    bash \
    "$repo_root/scripts/common.sh" \
    "$1" \
    "$2"
}

target_release='6.18.39+rpt-rpi-v8'
target_identity_sha256='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
target_root="$temporary_dir/target-root"
kernel_image_path="/boot/vmlinuz-$target_release"
initramfs_path="/boot/initrd.img-$target_release"
base_dtb_path='/boot/firmware/bcm2710-rpi-zero-2-w.dtb'
vc4_overlay_path='/boot/firmware/overlays/vc4-kms-v3d.dtbo'
mkdir -p \
  "$target_root$(dirname "$kernel_image_path")" \
  "$target_root$(dirname "$initramfs_path")" \
  "$target_root$(dirname "$base_dtb_path")" \
  "$target_root$(dirname "$vc4_overlay_path")"
printf 'candidate kernel fixture\n' > "$target_root$kernel_image_path"
printf 'candidate initramfs fixture\n' > "$target_root$initramfs_path"
printf 'base dtb fixture\n' > "$target_root$base_dtb_path"
printf 'vc4 overlay fixture\n' > "$target_root$vc4_overlay_path"
kernel_image_sha256="$(sha256sum "$target_root$kernel_image_path" | awk '{ print $1 }')"
initramfs_sha256="$(sha256sum "$target_root$initramfs_path" | awk '{ print $1 }')"
target_base_dtb_sha256="$(sha256sum "$target_root$base_dtb_path" | awk '{ print $1 }')"
vc4_overlay_sha256="$(sha256sum "$target_root$vc4_overlay_path" | awk '{ print $1 }')"
legacy_target_manifest="$temporary_dir/legacy-target.txt"
cat > "$legacy_target_manifest" <<'TARGET_MANIFEST'
kernel_release	6.18.39+rpt-rpi-v8
kernel_arch	aarch64
header_path	/usr/src/linux-headers-6.18.39+rpt-rpi-v8
common_header_path	/usr/src/linux-headers-6.18.39+rpt-common-rpi
kbuild_path	/usr/lib/linux-kbuild-6.18.39+rpt
kernel_source_package	linux
kernel_source_version	1:6.18.39-1+rpt1
kernel_source_deb_package	linux-source-6.18
kernel_source_deb_filename	pool/main/l/linux/linux-source-6.18_6.18.39-1_all.deb
kernel_source_deb_sha256	1111111111111111111111111111111111111111111111111111111111111111
kernel_source_deb	kernel-source.deb
base_dtb_path	/boot/firmware/bcm2710-rpi-zero-2-w.dtb
base_dtb_sha256	TARGET_BASE_DTB_SHA256
TARGET_MANIFEST
sed -i.bak "s/TARGET_BASE_DTB_SHA256/$target_base_dtb_sha256/" "$legacy_target_manifest"
rm -f "$legacy_target_manifest.bak"
validate_target_manifest "$legacy_target_manifest"

schema2_target_manifest="$temporary_dir/schema2-target.txt"
{
  printf 'schema_version\t2\n'
  printf 'target_identity_sha256\t%s\n' "$target_identity_sha256"
  cat "$legacy_target_manifest"
  printf 'kernel_image_path\t%s\n' "$kernel_image_path"
  printf 'kernel_image_sha256\t%s\n' "$kernel_image_sha256"
  printf 'initramfs_path\t%s\n' "$initramfs_path"
  printf 'initramfs_sha256\t%s\n' "$initramfs_sha256"
  printf 'vc4_overlay_path\t%s\n' "$vc4_overlay_path"
  printf 'vc4_overlay_sha256\t%s\n' "$vc4_overlay_sha256"
} > "$schema2_target_manifest"
validate_target_manifest "$schema2_target_manifest"
validate_inactive_target_manifest "$schema2_target_manifest" "$target_root"

for mutation in \
  duplicate \
  missing \
  unknown \
  malformed-identity-digest \
  mismatched-release-path \
  symlink-source \
  intermediate-directory-symlink \
  wrong-architecture \
  kernel-hash-drift \
  initramfs-hash-drift \
  base-dtb-hash-drift \
  vc4-overlay-hash-drift
do
  invalid_target_manifest="$temporary_dir/schema2-$mutation.txt"
  cp "$schema2_target_manifest" "$invalid_target_manifest"
  invalid_target_root="$temporary_dir/schema2-$mutation-root"
  cp -R "$target_root" "$invalid_target_root"
  case "$mutation" in
    duplicate)
      printf 'kernel_image_path\t%s\n' "$kernel_image_path" >> "$invalid_target_manifest"
      ;;
    missing)
      grep -v '^initramfs_sha256	' "$invalid_target_manifest" > "$invalid_target_manifest.next"
      mv "$invalid_target_manifest.next" "$invalid_target_manifest"
      ;;
    unknown)
      sed -i.bak 's/^kernel_image_path\t/unexpected_path\t/' "$invalid_target_manifest"
      rm -f "$invalid_target_manifest.bak"
      ;;
    malformed-identity-digest)
      sed -i.bak 's/^target_identity_sha256\t.*/target_identity_sha256\tUPPERCASE/' "$invalid_target_manifest"
      rm -f "$invalid_target_manifest.bak"
      ;;
    mismatched-release-path)
      sed -i.bak 's#^kernel_image_path\t.*#kernel_image_path\t/boot/vmlinuz-6.18.34+rpt-rpi-v8#' "$invalid_target_manifest"
      rm -f "$invalid_target_manifest.bak"
      ;;
    symlink-source)
      rm "$invalid_target_root$kernel_image_path"
      ln -s /dev/null "$invalid_target_root$kernel_image_path"
      ;;
    intermediate-directory-symlink)
      mv "$invalid_target_root/boot" "$invalid_target_root/boot-real"
      ln -s boot-real "$invalid_target_root/boot"
      ;;
    wrong-architecture)
      sed -i.bak 's/^kernel_arch\t.*/kernel_arch\tarmv7l/' "$invalid_target_manifest"
      rm -f "$invalid_target_manifest.bak"
      ;;
    kernel-hash-drift)
      printf 'drift\n' >> "$invalid_target_root$kernel_image_path"
      ;;
    initramfs-hash-drift)
      printf 'drift\n' >> "$invalid_target_root$initramfs_path"
      ;;
    base-dtb-hash-drift)
      printf 'drift\n' >> "$invalid_target_root$base_dtb_path"
      ;;
    vc4-overlay-hash-drift)
      printf 'drift\n' >> "$invalid_target_root$vc4_overlay_path"
      ;;
  esac
  if validate_target_manifest "$invalid_target_manifest" >/dev/null 2>&1; then
    case "$mutation" in
      symlink-source|intermediate-directory-symlink|kernel-hash-drift|initramfs-hash-drift|base-dtb-hash-drift|vc4-overlay-hash-drift)
        ;;
      *)
        printf 'target manifest validator accepted %s data\n' "$mutation" >&2
        exit 1
        ;;
    esac
  fi
  if validate_inactive_target_manifest \
    "$invalid_target_manifest" \
    "$invalid_target_root" >/dev/null 2>&1
  then
    printf 'inactive target manifest validator accepted %s data\n' "$mutation" >&2
    exit 1
  fi
done

foreign_identity_sha256='dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
candidate_target_parent="$temporary_dir/candidate-target"
candidate_target_dir="$candidate_target_parent/$target_release"
mkdir -p "$candidate_target_dir"
cp -R "$target_root" "$candidate_target_dir/root"
cp "$schema2_target_manifest" "$candidate_target_dir/target.txt"
for command in scripts/build-driver.sh scripts/check-artifacts.sh; do
  identity_error="$temporary_dir/$(basename "$command").identity-error"
  if "$repo_root/$command" \
    --target fixture-target \
    --kernel-release "$target_release" \
    --target-identity-sha256 "$foreign_identity_sha256" \
    --kernel-target "$candidate_target_parent" \
    --output "$temporary_dir/candidate-artifacts" \
    >"$identity_error" 2>&1
  then
    printf '%s accepted a foreign target identity\n' "$command" >&2
    exit 1
  fi
  grep -Fq 'target export identity does not match requested target' "$identity_error" || {
    cat "$identity_error" >&2
    printf '%s did not reject the foreign target identity at the candidate boundary\n' \
      "$command" >&2
    exit 1
  }
done

if ! awk '
  /\/workspace\/scripts\/prepare-kbuild-host-tools\.sh/ { in_command = 1 }
  in_command && /"\$kernel_source_package"/ { source_package = 1 }
  in_command && /"\$kernel_source_deb_package"/ { source_deb_package = 1 }
  END { exit !(source_package && source_deb_package) }
' "$repo_root/scripts/build-driver.sh"; then
  printf 'build-driver must pass both source and source-deb package identities\n' >&2
  exit 1
fi

if ! grep -Fqx \
  'source_archive="$package_root/usr/src/$source_deb_package.tar.xz"' \
  "$repo_root/scripts/prepare-kbuild-host-tools.sh"; then
  printf 'host-tool preparation must use the verified source-deb archive name\n' >&2
  exit 1
fi

valid_host_tools="$temporary_dir/host-tools.txt"
cat > "$valid_host_tools" <<'HOST_TOOLS'
host_arch	aarch64
kernel_source_package	linux
kernel_source_deb_package	linux-source-6.18
kernel_source_version	1:6.18.34-1+rpt1
kernel_source_sha256	6666666666666666666666666666666666666666666666666666666666666666
host_fixdep_sha256	7777777777777777777777777777777777777777777777777777777777777777
host_modpost_sha256	8888888888888888888888888888888888888888888888888888888888888888
host_genksyms_sha256	9999999999999999999999999999999999999999999999999999999999999999
HOST_TOOLS
if ! bash -eu -c \
  'source "$1"; hp2r_validate_host_tools_manifest "$2"' \
  bash \
  "$repo_root/scripts/common.sh" \
  "$valid_host_tools"; then
  printf 'host-tool manifest must retain separate source-deb package identity\n' >&2
  exit 1
fi

if ! grep -Fq \
  'workspace_revision="$(hp2r_resolve_build_revision)"' \
  "$repo_root/scripts/build-driver.sh"; then
  printf 'implicit builds must retain their resolved source revision for the post-build check\n' >&2
  exit 1
fi

for script in scripts/build-driver.sh scripts/check-artifacts.sh scripts/stage-tryboot.sh; do
  if ! grep -Fq 'hp2r_release_source_available' "$repo_root/$script"; then
    printf '%s must consume a verified extracted release source without Git\n' "$script" >&2
    exit 1
  fi
done

current_source="$(git -C "$repo_root" rev-parse --verify 'origin/main^{commit}')"
bash -eu -c \
  'cd "$1"; source "$2"; hp2r_require_durable_source_revision "$3"' \
  bash \
  "$repo_root" \
  "$repo_root/scripts/common.sh" \
  "$current_source"

fixture_repo="$temporary_dir/provenance-repo"
git init -q "$fixture_repo"
git -C "$fixture_repo" config user.name 'HyperPixel contract test'
git -C "$fixture_repo" config user.email 'contract@example.invalid'
git -C "$fixture_repo" config commit.gpgsign false
git -C "$fixture_repo" config tag.forceSignAnnotated false
printf 'durable\n' > "$fixture_repo/source.txt"
git -C "$fixture_repo" add source.txt
git -C "$fixture_repo" commit --quiet --no-gpg-sign -m 'durable source'
git -C "$fixture_repo" branch -M main
durable_revision="$(git -C "$fixture_repo" rev-parse HEAD)"
git -C "$fixture_repo" tag --no-sign durable-source "$durable_revision"

git -C "$fixture_repo" checkout -q --detach "$durable_revision"
printf 'gitbutler-only\n' >> "$fixture_repo/source.txt"
git -C "$fixture_repo" add source.txt
git -C "$fixture_repo" commit --quiet --no-gpg-sign -m 'GitButler-only source'
gitbutler_revision="$(git -C "$fixture_repo" rev-parse HEAD)"
git -C "$fixture_repo" update-ref \
  refs/heads/gitbutler/workspace \
  "$gitbutler_revision"

git -C "$fixture_repo" checkout -q --detach "$durable_revision"
printf 'unreferenced\n' >> "$fixture_repo/source.txt"
git -C "$fixture_repo" add source.txt
git -C "$fixture_repo" commit --quiet --no-gpg-sign -m 'unreferenced source'
unreferenced_revision="$(git -C "$fixture_repo" rev-parse HEAD)"
git -C "$fixture_repo" checkout -q main
git -C "$fixture_repo" fsck --no-reflogs --unreachable --no-progress |
  grep -Fqx "unreachable commit $unreferenced_revision"

run_fixture_durability_check() {
  local revision="$1"

  bash -eu -c \
    'cd "$1"; source "$2"; hp2r_require_durable_source_revision "$3"' \
    bash \
    "$fixture_repo" \
    "$repo_root/scripts/common.sh" \
    "$revision"
}

run_fixture_durability_check "$durable_revision"
if run_fixture_durability_check "$gitbutler_revision" >/dev/null 2>&1; then
  printf 'durable source validation accepted a GitButler-only commit\n' >&2
  exit 1
fi
if run_fixture_durability_check "$unreferenced_revision" >/dev/null 2>&1; then
  printf 'durable source validation accepted an unreferenced commit\n' >&2
  exit 1
fi

remote_repo="$temporary_dir/durable-remote.git"
git init -q --bare "$remote_repo"
git -C "$fixture_repo" remote add origin "$remote_repo"
git -C "$fixture_repo" push -q origin main
printf 'remote-only\n' >> "$fixture_repo/source.txt"
git -C "$fixture_repo" add source.txt
git -C "$fixture_repo" commit --quiet --no-gpg-sign -m 'remote durable source'
remote_revision="$(git -C "$fixture_repo" rev-parse HEAD)"
git -C "$fixture_repo" push -q origin main
git -C "$fixture_repo" fetch -q origin main
git -C "$fixture_repo" checkout -q --detach "$durable_revision"
git -C "$fixture_repo" branch -D main >/dev/null
run_fixture_durability_check "$remote_revision" || {
  printf 'durable source validation must accept a fetched remote-tracking branch\n' >&2
  exit 1
}

for script in scripts/build-driver.sh scripts/check-artifacts.sh; do
  if ! grep -Fq \
    'hp2r_require_durable_source_revision "$source_revision"' \
    "$repo_root/$script"; then
    printf '%s must enforce durable source revisions\n' "$script" >&2
    exit 1
  fi
done

post_build_durable_count="$(
  grep -Fc \
    'hp2r_require_durable_source_revision "$source_revision"' \
    "$repo_root/scripts/build-driver.sh"
)"
test "$post_build_durable_count" = 2 || {
  printf 'build-driver must recheck durable provenance before publishing artifacts\n' >&2
  exit 1
}
post_build_stability_line="$(
  grep -n 'source revision changed while building artifacts' \
    "$repo_root/scripts/build-driver.sh" |
    tail -n 1 |
    cut -d : -f 1
)"
post_build_durable_line="$(
  grep -n 'hp2r_require_durable_source_revision "$source_revision"' \
    "$repo_root/scripts/build-driver.sh" |
    tail -n 1 |
    cut -d : -f 1
)"
staging_line="$(
  grep -n 'mkdir -p "$output_parent"' "$repo_root/scripts/build-driver.sh" |
    cut -d : -f 1
)"
test "$post_build_stability_line" -lt "$post_build_durable_line" &&
  test "$post_build_durable_line" -lt "$staging_line" || {
  printf 'post-build durable provenance recheck must run before artifact staging\n' >&2
  exit 1
}

fake_remote_root="$temporary_dir/fake-remote-root"
fake_bin="$temporary_dir/fake-bin"
fake_ssh_log="$temporary_dir/fake-ssh.log"
fake_source_deb="$temporary_dir/kernel-source.deb"
fake_export_parent="$temporary_dir/kernel-target"
requested_release='6.18.39+rpt-rpi-v8'
running_release='6.18.34+rpt-rpi-v8'
requested_identity_sha256='cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
mkdir -p \
  "$fake_bin" \
  "$fake_remote_root/lib/modules/$requested_release" \
  "$fake_remote_root/usr/src/linux-headers-$requested_release/include/config" \
  "$fake_remote_root/usr/src/linux-headers-6.18.39+rpt-common-rpi/include" \
  "$fake_remote_root/usr/lib/linux-kbuild-6.18.39+rpt/scripts" \
  "$fake_remote_root/boot/firmware/overlays"
printf '%s\n' "$requested_release" > \
  "$fake_remote_root/usr/src/linux-headers-$requested_release/include/config/kernel.release"
printf 'CONFIG_DRM_PANEL=y\n' > \
  "$fake_remote_root/usr/src/linux-headers-$requested_release/.config"
printf 'fixture symbols\n' > \
  "$fake_remote_root/usr/src/linux-headers-$requested_release/Module.symvers"
printf 'include %s/usr/src/linux-headers-6.18.39+rpt-common-rpi/Makefile\n' \
  "$fake_remote_root" > "$fake_remote_root/usr/src/linux-headers-$requested_release/Makefile"
printf 'fixture common Makefile\n' > \
  "$fake_remote_root/usr/src/linux-headers-6.18.39+rpt-common-rpi/Makefile"
ln -s "../../../usr/src/linux-headers-$requested_release" \
  "$fake_remote_root/lib/modules/$requested_release/build"
printf 'fixture kernel\n' > \
  "$fake_remote_root/boot/vmlinuz-$requested_release"
printf 'fixture initramfs\n' > \
  "$fake_remote_root/boot/initrd.img-$requested_release"
printf 'fixture base dtb\n' > \
  "$fake_remote_root/boot/firmware/bcm2710-rpi-zero-2-w.dtb"
printf 'fixture vc4 overlay\n' > \
  "$fake_remote_root/boot/firmware/overlays/vc4-kms-v3d.dtbo"
printf 'fixture source deb\n' > "$fake_source_deb"
fake_source_deb_sha256="$(sha256sum "$fake_source_deb" | awk '{ print $1 }')"
fake_kernel_image_sha256="$(sha256sum "$fake_remote_root/boot/vmlinuz-$requested_release" | awk '{ print $1 }')"
fake_initramfs_sha256="$(sha256sum "$fake_remote_root/boot/initrd.img-$requested_release" | awk '{ print $1 }')"
fake_base_dtb_sha256="$(sha256sum "$fake_remote_root/boot/firmware/bcm2710-rpi-zero-2-w.dtb" | awk '{ print $1 }')"
fake_vc4_overlay_sha256="$(sha256sum "$fake_remote_root/boot/firmware/overlays/vc4-kms-v3d.dtbo" | awk '{ print $1 }')"
cat > "$fake_bin/ssh" <<'FAKE_SSH'
#!/usr/bin/env bash
set -euo pipefail
target="$1"
shift
printf '%s\n' "$target $*" >> "$HP2R_FAKE_SSH_LOG"
case "$1" in
  bash)
    program="$(cat)"
    printf '%s\n' "$program" >> "$HP2R_FAKE_SSH_LOG"
    transformed_program="$(printf '%s\n' "$program" | sed \
      "s|/lib/modules|$HP2R_FAKE_REMOTE_ROOT/lib/modules|g; s|/boot|$HP2R_FAKE_REMOTE_ROOT/boot|g")"
    output="$(
      printf '%s\n' "$transformed_program" |
        PATH="$HP2R_FAKE_BIN:$PATH" bash -s -- "${@:4}"
    )"
    printf '%s\n' "$output" | sed "s|$HP2R_FAKE_REMOTE_ROOT||g"
    ;;
  tar)
    while test "$1" != --; do shift; done
    shift
    tar -C "$HP2R_FAKE_REMOTE_ROOT" -cf - -- "$@"
    ;;
  *)
    printf 'unexpected fake SSH command: %s\n' "$1" >&2
    exit 1
    ;;
esac
FAKE_SSH
cat > "$fake_bin/readlink" <<'FAKE_READLINK'
#!/usr/bin/env bash
set -euo pipefail
test "$1" = -f
case "$2" in
  "$HP2R_FAKE_REMOTE_ROOT"/lib/modules/*/build)
    printf '%s/usr/src/linux-headers-%s\n' \
      "$HP2R_FAKE_REMOTE_ROOT" "$HP2R_FAKE_REQUESTED_RELEASE"
    ;;
  "$HP2R_FAKE_REMOTE_ROOT"/usr/src/linux-headers-*/scripts)
    printf '%s/usr/lib/linux-kbuild-6.18.39+rpt/scripts\n' \
      "$HP2R_FAKE_REMOTE_ROOT"
    ;;
  *) exit 64 ;;
esac
FAKE_READLINK
cat > "$fake_bin/uname" <<'FAKE_UNAME'
#!/usr/bin/env bash
printf 'uname %s\n' "$*" >> "$HP2R_FAKE_SSH_LOG"
case "${1-}" in
  -m) printf 'aarch64\n' ;;
  -r) printf '%s\n' "$HP2R_FAKE_RUNNING_RELEASE" ;;
  *) exit 64 ;;
esac
FAKE_UNAME
cat > "$fake_bin/modinfo" <<'FAKE_MODINFO'
#!/usr/bin/env bash
set -euo pipefail
printf 'modinfo %s\n' "$*" >> "$HP2R_FAKE_SSH_LOG"
test "$1" = -k
test "$2" = "$HP2R_FAKE_REQUESTED_RELEASE"
test "$3" = -F
test "$4" = vermagic
test "$5" = vc4
printf '%s SMP preempt\n' "$2"
FAKE_MODINFO
cat > "$fake_bin/dpkg-query" <<'FAKE_DPKG_QUERY'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *'-S '*) printf 'linux-kbuild-6.18.39: fixture\n' ;;
  *'source:Package'*) printf 'linux\n' ;;
  *'source:Version'*) printf '1:6.18.39-1+rpt1\n' ;;
  *) exit 64 ;;
esac
FAKE_DPKG_QUERY
cat > "$fake_bin/apt-cache" <<'FAKE_APT_CACHE'
#!/usr/bin/env bash
set -euo pipefail
test "$1" = show
printf '%s\n' \
  'Architecture: all' \
  'Filename: pool/main/l/linux/linux-source-6.18_6.18.39-1_all.deb' \
  "SHA256: $HP2R_FAKE_SOURCE_DEB_SHA256"
FAKE_APT_CACHE
cat > "$fake_bin/stat" <<'FAKE_STAT'
#!/usr/bin/env bash
set -euo pipefail
printf 'stat %s\n' "$*" >> "$HP2R_FAKE_SSH_LOG"
test "$1" = -c
test "$2" = %u:%g
printf '%s\n' "$HP2R_FAKE_OWNER"
FAKE_STAT
cat > "$fake_bin/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -euo pipefail
output=''
while test "$#" -gt 0; do
  case "$1" in
    --output)
      output="$2"
      shift 2
      ;;
    *) shift ;;
  esac
done
test -n "$output"
cp "$HP2R_FAKE_SOURCE_DEB" "$output"
FAKE_CURL
chmod +x "$fake_bin/ssh" "$fake_bin/curl" "$fake_bin/readlink" "$fake_bin/uname" "$fake_bin/modinfo" \
  "$fake_bin/dpkg-query" "$fake_bin/apt-cache" "$fake_bin/stat"
PATH="$fake_bin:$PATH" \
  HP2R_FAKE_SSH_LOG="$fake_ssh_log" \
  HP2R_FAKE_REMOTE_ROOT="$fake_remote_root" \
  HP2R_FAKE_BIN="$fake_bin" \
  HP2R_FAKE_RUNNING_RELEASE="$running_release" \
  HP2R_FAKE_OWNER='0:0' \
  HP2R_FAKE_REQUESTED_RELEASE="$requested_release" \
  HP2R_FAKE_SOURCE_DEB="$fake_source_deb" \
  HP2R_FAKE_SOURCE_DEB_SHA256="$fake_source_deb_sha256" \
  HP2R_FAKE_KERNEL_IMAGE_SHA256="$fake_kernel_image_sha256" \
  HP2R_FAKE_INITRAMFS_SHA256="$fake_initramfs_sha256" \
  HP2R_FAKE_BASE_DTB_SHA256="$fake_base_dtb_sha256" \
  HP2R_FAKE_VC4_OVERLAY_SHA256="$fake_vc4_overlay_sha256" \
  "$repo_root/scripts/export-target-kbuild.sh" \
    --target fixture-target \
    --kernel-release "$requested_release" \
    --target-identity-sha256 "$requested_identity_sha256" \
    --output "$fake_export_parent"
fake_export_dir="$fake_export_parent/$requested_release"
test -f "$fake_export_dir/target.txt"
grep -Fqx $'schema_version\t2' "$fake_export_dir/target.txt"
grep -Fqx \
  "$(printf 'target_identity_sha256\t%s' "$requested_identity_sha256")" \
  "$fake_export_dir/target.txt"
test -f "$fake_export_dir/root/boot/vmlinuz-$requested_release"
test -f "$fake_export_dir/root/boot/initrd.img-$requested_release"
test ! -e "$temporary_dir/artifacts/vmlinuz-$requested_release"
test ! -e "$temporary_dir/artifacts/initrd.img-$requested_release"
grep -Fq "fixture-target bash -s -- $requested_release" "$fake_ssh_log"
grep -Fq 'release="${1-}"' "$fake_ssh_log"
grep -Fq '"/lib/modules/$release/build"' "$fake_ssh_log"
grep -Fq 'modinfo -k "$release" -F vermagic vc4' "$fake_ssh_log"
grep -Fq '"/boot/vmlinuz-$release"' "$fake_ssh_log"
grep -Fq '"/boot/initrd.img-$release"' "$fake_ssh_log"
grep -Fq '/boot/firmware/overlays/vc4-kms-v3d.dtbo' "$fake_ssh_log"
grep -Fq "modinfo -k $requested_release -F vermagic vc4" "$fake_ssh_log"
grep -Fq "stat -c %u:%g $fake_remote_root/boot/vmlinuz-$requested_release" \
  "$fake_ssh_log"
test "$(grep -Fc "stat -c %u:%g $fake_remote_root/boot/vmlinuz-$requested_release" "$fake_ssh_log")" \
  = 2 || {
  printf 'inactive export did not revalidate the kernel image on the target\n' >&2
  exit 1
}
if grep -Fq "$running_release" "$fake_ssh_log"; then
  printf 'inactive export substituted the running release for the requested release\n' >&2
  exit 1
fi

owner_error="$temporary_dir/wrong-owner-export.error"
set +e
PATH="$fake_bin:$PATH" \
  HP2R_FAKE_SSH_LOG="$fake_ssh_log" \
  HP2R_FAKE_REMOTE_ROOT="$fake_remote_root" \
  HP2R_FAKE_BIN="$fake_bin" \
  HP2R_FAKE_RUNNING_RELEASE="$running_release" \
  HP2R_FAKE_OWNER='501:20' \
  HP2R_FAKE_REQUESTED_RELEASE="$requested_release" \
  HP2R_FAKE_SOURCE_DEB="$fake_source_deb" \
  HP2R_FAKE_SOURCE_DEB_SHA256="$fake_source_deb_sha256" \
  HP2R_FAKE_KERNEL_IMAGE_SHA256="$fake_kernel_image_sha256" \
  HP2R_FAKE_INITRAMFS_SHA256="$fake_initramfs_sha256" \
  HP2R_FAKE_BASE_DTB_SHA256="$fake_base_dtb_sha256" \
  HP2R_FAKE_VC4_OVERLAY_SHA256="$fake_vc4_overlay_sha256" \
  "$repo_root/scripts/export-target-kbuild.sh" \
    --target fixture-target \
    --kernel-release "$requested_release" \
    --target-identity-sha256 "$requested_identity_sha256" \
    --output "$temporary_dir/wrong-owner-target" \
  >"$owner_error" 2>&1
owner_status=$?
set -e
test "$owner_status" -ne 0 || {
  printf 'inactive export accepted a wrong-owner boot source\n' >&2
  exit 1
}
grep -Fq "target boot source is not a root:root regular file: $fake_remote_root/boot/vmlinuz-$requested_release" \
  "$owner_error" || {
  cat "$owner_error" >&2
  printf 'wrong-owner export did not reach the root-owner guard\n' >&2
  exit 1
}

rm -f "$fake_ssh_log.invocations"
PATH="$fake_bin:$PATH" \
  HP2R_FAKE_SSH_LOG="$fake_ssh_log" \
  HP2R_FAKE_REMOTE_ROOT="$fake_remote_root" \
  HP2R_FAKE_BIN="$fake_bin" \
  HP2R_FAKE_RUNNING_RELEASE="$running_release" \
  HP2R_FAKE_OWNER='0:0' \
  HP2R_FAKE_REQUESTED_RELEASE="$requested_release" \
  HP2R_FAKE_SOURCE_DEB="$fake_source_deb" \
  HP2R_FAKE_SOURCE_DEB_SHA256="$fake_source_deb_sha256" \
  HP2R_FAKE_KERNEL_IMAGE_SHA256="$fake_kernel_image_sha256" \
  HP2R_FAKE_INITRAMFS_SHA256="$fake_initramfs_sha256" \
  HP2R_FAKE_BASE_DTB_SHA256="$fake_base_dtb_sha256" \
  HP2R_FAKE_VC4_OVERLAY_SHA256="$fake_vc4_overlay_sha256" \
  "$repo_root/scripts/export-target-kbuild.sh" \
    --target fixture-target \
    --output "$fake_export_parent"
legacy_export_dir="$fake_export_parent/$running_release"
test "$(awk 'END { print NR }' "$legacy_export_dir/target.txt")" = 13
if grep -Eq '^schema_version\t' "$legacy_export_dir/target.txt"; then
  printf 'same-kernel export unexpectedly changed the legacy target manifest\n' >&2
  exit 1
fi
test ! -e "$legacy_export_dir/root/boot/vmlinuz-$running_release"
test ! -e "$legacy_export_dir/root/boot/initrd.img-$running_release"

for script in scripts/build-driver.sh scripts/check-artifacts.sh; do
  if ! grep -Fq 'explicit_release=true' "$repo_root/$script" ||
    ! grep -Fq 'hp2r_validate_inactive_target_manifest' "$repo_root/$script"
  then
    printf '%s must require schema-2 inactive provenance for explicit releases\n' \
      "$script" >&2
    exit 1
  fi
done

printf 'Driver build contract passed\n'
