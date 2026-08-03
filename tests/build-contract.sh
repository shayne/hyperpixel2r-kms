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
for option in --target --kernel-release --kernel-target --source-revision --output; do
  if [[ "$help_output" != *"$option"* ]]; then
    printf 'build-driver.sh --help must document %s\n' "$option" >&2
    exit 1
  fi
done

check_help_output="$("$repo_root/scripts/check-artifacts.sh" --help)"
if [[ "$check_help_output" != *"--kernel-target"* ]]; then
  printf 'check-artifacts.sh --help must document --kernel-target\n' >&2
  exit 1
fi

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

printf 'Driver build contract passed\n'
