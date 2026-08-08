#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Keep the first assertion blunt.  A missing packager is a real contract
# failure, rather than a later and much less useful failure from a fixture.
test -x "$repo_root/scripts/package-release.sh" || {
  printf 'missing deterministic release packager: scripts/package-release.sh\n' >&2
  exit 1
}

PYTHONDONTWRITEBYTECODE=1 python3 "$repo_root/tests/stable-release-contract.py"

test -f "$repo_root/release/driver-manifest.schema.json" || {
  printf 'missing release manifest schema\n' >&2
  exit 1
}

python3 - "$repo_root" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
failures = []

for relative in (
    ".github/workflows/ci.yml",
    ".github/workflows/release.yml",
    ".github/workflows/stable-draft.yml",
    ".github/workflows/stable-promote.yml",
):
    path = root / relative
    if not path.is_file():
        failures.append(f"missing release workflow: {relative}")
        continue
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if not re.match(r"^\s*uses:\s*", line):
            continue
        if not re.match(r"^\s*uses:\s*[^@\s]+@[0-9a-f]{40}\s+#\s+v[^\s]+\s*$", line):
            failures.append(f"{relative}:{number} must pin its action to a full SHA with a version comment")

dependabot = root / ".github" / "dependabot.yml"
if not dependabot.is_file() or "package-ecosystem: github-actions" not in dependabot.read_text():
    failures.append("Dependabot must track pinned GitHub Actions")

release_marker = root / "release" / "current-release.txt"
if not release_marker.is_file():
    failures.append("missing canonical release/current-release.txt marker")
else:
    marker_bytes = release_marker.read_bytes()
    if not re.fullmatch(rb"v[0-9]+\.[0-9]+\.[0-9]+-rc\.[1-9][0-9]*\n", marker_bytes):
        failures.append("canonical release marker must be exactly one newline-terminated candidate tag")
        current = ""
    else:
        current = marker_bytes[:-1].decode()
    readme = (root / "README.md").read_text()
    tags = set(re.findall(r"v[0-9]+\.[0-9]+\.[0-9]+-rc\.[1-9][0-9]*", readme))
    if tags != {current}:
        failures.append("README status and release commands must use only the canonical release marker")
    if f"<!-- HP2R_CURRENT_RELEASE={current} -->" not in readme:
        failures.append("README must expose the canonical release marker for the contract")

requirements = root / "release" / "validator-requirements.txt"
requirements_input = root / "release" / "validator-requirements.in"
validator = root / "scripts" / "validate-release-metadata.sh"
if not requirements.is_file() or "spdx-tools==0.8.3" not in requirements.read_text():
    failures.append("release validators must pin official spdx-tools 0.8.3")
if not requirements.is_file() or "check-jsonschema==0.37.4" not in requirements.read_text():
    failures.append("release validators must pin check-jsonschema 0.37.4")
if not requirements_input.is_file() or "referencing<0.36" not in requirements_input.read_text():
    failures.append("release validators must constrain referencing to the CPython 3.12-compatible series")
if not validator.is_file() or not validator.stat().st_mode & 0o111:
    failures.append("missing executable real release-metadata validator")
if requirements.is_file():
    lock_lines = requirements.read_text().splitlines()
    requirement_indexes = [
        index
        for index, line in enumerate(lock_lines)
        if re.match(r"^[A-Za-z0-9_.-]+==[^\s\\]+", line)
    ]
    if not requirement_indexes:
        failures.append("validator lock must contain pinned transitive requirements")
    for offset, index in enumerate(requirement_indexes):
        end = requirement_indexes[offset + 1] if offset + 1 < len(requirement_indexes) else len(lock_lines)
        block = "\n".join(lock_lines[index:end])
        if "--hash=sha256:" not in block:
            failures.append(f"validator lock requirement lacks a SHA-256 hash: {lock_lines[index]}")
if validator.is_file():
    validator_text = validator.read_text()
    for flag in ("--isolated", "--require-hashes", "--no-deps"):
        if flag not in validator_text:
            failures.append(f"validator installer must use pip {flag}")
    if "HP2R_VALIDATOR_REQUIREMENTS" not in validator_text:
        failures.append("validator installer must support an isolated lock-file test input")
    if "HP2R_VALIDATOR_ROOT" not in validator_text:
        failures.append("validator installer must support an isolated validator-cache test root")

ci_workflow = root / ".github" / "workflows" / "ci.yml"
if ci_workflow.is_file():
    ci = ci_workflow.read_text()
    validator_ci_contract = (
        "Validate official release metadata on supported Python hosts",
        "os: ubuntu-24.04",
        "os: macos-latest",
        'python: "3.12"',
        'python: "3.13"',
        "python-version: ${{ matrix.python }}",
        "mise run validate-release-metadata --",
    )
    for required in validator_ci_contract:
        if required not in ci:
            failures.append(f"CI must prove the real release validator on hosted Python: {required}")
    for required in (
        "Upload the commit-bound verified release assets",
        "actions/upload-artifact@",
        "name: release-assets-${{ github.sha }}",
        "run: mise run verify-fast",
        "needs: [validate-release-metadata, verify-fast, lifecycle-smoke]",
        "HP2R_FIXTURE_CASE: smoke",
        "github.event_name == 'workflow_dispatch' || github.event_name == 'schedule'",
        'cron: "17 7 * * *"',
        "- core",
        "- inactive-uninstall-backlight",
        "- prior-absent-uninstall-proof",
        "- inactive-kernel-recovery-phases",
        "- inactive-kernel-finalization-interruptions",
    ):
        if required not in ci:
            failures.append(f"CI must publish one commit-bound verified artifact: {required}")
    if "run: mise run verify\n" in ci:
        failures.append("CI must not serialize the complete lifecycle matrix behind verify")

tag_validator = root / "scripts" / "validate-release-tag.sh"
if not tag_validator.is_file() or not tag_validator.stat().st_mode & 0o111:
    failures.append("missing executable release tag/version validator")
stable_tag_validator = root / "scripts" / "validate-stable-release-tag.sh"
if not stable_tag_validator.is_file() or not stable_tag_validator.stat().st_mode & 0o111:
    failures.append("missing executable stable release tag/version validator")

release_workflow = root / ".github" / "workflows" / "release.yml"
if release_workflow.is_file():
    workflow = release_workflow.read_text()
    ordered_steps = [
        "Confirm unused tag and bind selected source",
        "Download commit-bound verified release assets",
        "Validate release metadata and checksums",
        "Create the immutable tag after verification",
        "Attest every published release subject",
        "Create a draft prerelease with immutable assets",
    ]
    offsets = [workflow.find(step) for step in ordered_steps]
    if -1 in offsets or offsets != sorted(offsets):
        failures.append("release workflow must validate/package before creating its immutable tag and attestations")
    if "target_commitish: ${{ steps.tag.outputs.commit }}" not in workflow:
        failures.append("release draft must target the commit proven by the immutable tag step")
    if "scripts/validate-release-tag.sh" not in workflow:
        failures.append("release workflow must bind tag base version to committed driver version")
    if 'source_commit="$(git rev-parse \'HEAD^{commit}\')"' not in workflow:
        failures.append("release workflow must bind the selected source to checked-out HEAD")
    if 'test "$source_commit" = "$DISPATCH_COMMIT"' not in workflow:
        failures.append("release workflow must bind attestation event provenance to selected source")
    if 'source_commit="$(git rev-parse "$GITHUB_SHA^{commit}")"' in workflow:
        failures.append("release workflow must never bind selected source identity through GITHUB_SHA")
    if "DISPATCH_COMMIT: ${{ github.sha }}" not in workflow:
        failures.append("release workflow must expose the dispatch commit separately from selected source")
    if 'git fetch --no-tags origin "$DISPATCH_COMMIT"' not in workflow or \
       'git cat-file -e "$DISPATCH_COMMIT:.github/workflows/release.yml"' not in workflow:
        failures.append("release workflow must prove release.yml exists on its dispatch ref")
    if '.source.commit == $commit' not in workflow:
        failures.append("release workflow must prove packaged manifest targets selected checked-out source")
    if 'git tag --annotate "$TAG" "$RELEASE_COMMIT"' not in workflow or \
       'git push origin "refs/tags/$TAG:refs/tags/$TAG"' not in workflow or \
       'test "$tag_commit" = "$RELEASE_COMMIT"' not in workflow:
        failures.append("release workflow tag race check and push must target the selected source exactly")
    for forbidden in ("mise run verify", "mise run package-release", "docker build"):
        if forbidden in workflow:
            failures.append(f"release workflow must reuse CI assets instead of rebuilding: {forbidden}")
    if 'release-assets-$RELEASE_COMMIT' not in workflow:
        failures.append("release workflow must download the exact commit-bound CI artifact")

stable_draft = root / ".github" / "workflows" / "stable-draft.yml"
if stable_draft.is_file():
    workflow = stable_draft.read_text()
    ordered_steps = [
        "Confirm absent stable tag and bind selected source",
        "Download commit-bound verified stable assets",
        "Validate stable metadata and checksums",
        "Attest every stable draft subject",
        "Attest the stable SPDX bill of materials",
        "Create unpublished stable draft without a tag",
    ]
    offsets = [workflow.find(step) for step in ordered_steps]
    if -1 in offsets or offsets != sorted(offsets):
        failures.append("stable draft workflow must validate and attest before draft creation")
    for required in (
        "permissions:\n  actions: read\n  contents: write\n  id-token: write\n  attestations: write",
        "scripts/validate-stable-release-tag.sh",
        "scripts/stable_release.py draft",
        "HP2R_STABLE_DRAFT_RELEASE_ID",
        "HP2R_STABLE_DRAFT_ASSET_FINGERPRINT",
        'test "$source_commit" = "$DISPATCH_COMMIT"',
    ):
        if required not in workflow:
            failures.append(f"stable draft workflow contract is missing: {required}")
    for forbidden in ("mise run verify", "mise run package-release", "docker build"):
        if forbidden in workflow:
            failures.append(f"stable draft must reuse CI assets instead of rebuilding: {forbidden}")
    if 'release-assets-$RELEASE_COMMIT' not in workflow:
        failures.append("stable draft must download the exact commit-bound CI artifact")
    if "git tag" in workflow or "refs/tags/$TAG:refs/tags/$TAG" in workflow:
        failures.append("stable draft workflow must not create or push the stable tag")

stable_promote = root / ".github" / "workflows" / "stable-promote.yml"
if stable_promote.is_file():
    workflow = stable_promote.read_text()
    ordered_steps = [
        "Confirm promotion inputs",
        "Download the exact accepted stable draft",
        "Verify stable checksums, schema, SPDX, and source identity",
        "Verify stable draft attestations",
        "Create annotated tag and publish the unchanged draft",
        "Verify published stable identity",
    ]
    offsets = [workflow.find(step) for step in ordered_steps]
    if -1 in offsets or offsets != sorted(offsets):
        failures.append("stable promotion workflow must verify everything before tag creation")
    for required in (
        "permissions:\n  contents: write",
        "release_id:",
        "asset_fingerprint:",
        "scripts/stable_release.py verify",
        "scripts/stable_release.py publish",
        "scripts/stable_release.py confirm",
        '--result "$RUNNER_TEMP/stable-publication.json"',
        "--repo shayne/hyperpixel2r-kms",
        "--signer-workflow shayne/hyperpixel2r-kms/.github/workflows/stable-draft.yml",
        "--source-ref refs/heads/main",
        "--deny-self-hosted-runners",
        'git config user.name "github-actions[bot]"',
        'git config user.email "41898282+github-actions[bot]@users.noreply.github.com"',
    ):
        if required not in workflow:
            failures.append(f"stable promotion workflow contract is missing: {required}")
    if "--signer-repo " in workflow:
        failures.append("stable promotion must not combine mutually exclusive signer selectors")
    forbidden = (
        "package-release",
        "build-driver",
        "action-gh-release",
        "release upload",
        "/releases/assets?name=",
        "actions/attest@",
    )
    for value in forbidden:
        if value in workflow:
            failures.append(f"stable promotion must not build, attest, or replace assets: {value}")
    if 'git rev-parse "$TAG' in workflow or "git fetch --tags" in workflow:
        failures.append("stable promotion must verify tag state from the remote, not local refs")

for relative in ("scripts/build-driver.sh", "scripts/package-release.sh"):
    text = (root / relative).read_text()
    selection = text.find('if test -n "$source_ref"; then')
    stale_resolution = text.find('workspace_revision="$(hp2r_resolve_build_revision)"')
    fallback_resolution = text.find('source_revision="$(hp2r_resolve_build_revision)"')
    if stale_resolution != -1:
        fallback_resolution = stale_resolution
    if selection == -1 or fallback_resolution == -1 or fallback_resolution < selection:
        failures.append(f"{relative} must skip GitButler source inference when --source-revision is explicit")

contract = (root / "tests" / "release-contract.sh").read_text()
if 'origin/main^{commit}' not in contract:
    failures.append("exact-artifact contract must use an explicit durable origin/main source revision")

if failures:
    print("\n".join(failures), file=sys.stderr)
    raise SystemExit(1)
PY

for workflow in .github/workflows/ci.yml .github/workflows/release.yml; do
  test -f "$repo_root/$workflow" || {
    printf 'missing release workflow: %s\n' "$workflow" >&2
    exit 1
  }
done

release_workflow="$repo_root/.github/workflows/release.yml"
grep -Fxq '          git config user.name "github-actions[bot]"' "$release_workflow" || {
  printf 'release workflow must configure the immutable tag committer name\n' >&2
  exit 1
}
grep -Fxq '          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"' "$release_workflow" || {
  printf 'release workflow must configure the immutable tag committer email\n' >&2
  exit 1
}

test -f "$repo_root/docs/compatibility.md"
test -f "$repo_root/docs/provenance.md"

# The public release must not inherit the device-specific identity or credential
# from the development deployment.  Build the legacy marker at runtime so this
# guard does not match its own source.
legacy_identity="plane""radar"
legacy_user="shayne"
legacy_host_marker="${legacy_user}@"
legacy_password_marker="${legacy_user}s!"
legacy_migration_path="release/legacy-${legacy_identity}-migration-v1.tsv"
current_identity="hyperpixel2r"
allowed_hyphen_interface="${current_identity}-backlight"
allowed_hyphen_pins="${allowed_hyphen_interface}-pins"
allowed_underscore_interface="${current_identity}_backlight"
allowed_underscore_pins="${allowed_underscore_interface}_pins"
allowed_backlight_name="$allowed_hyphen_interface"
allowed_backlight_rule="70-${allowed_hyphen_interface}.rules"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/hp2r-release-contract.XXXXXX")"
trap 'rm -rf "$temporary_dir"' EXIT

check_release_identity() {
  local guard_root="$1"
  local identity_matches=""
  local all_identity_paths=""
  local text_identity_paths=""
  local binary_identity_matches=""
  local invalid_identity_matches=""
  local credential_matches=""
  local match_path=""
  local match_line=""
  local match_text=""
  local identity_token=""

  all_identity_paths="$(
    git -C "$guard_root" grep -ilF "$legacy_identity" -- \
      ':!.env' \
      ":!$legacy_migration_path" \
      ':!scripts/lifecycle-remote.sh' \
      ':!scripts/uninstall.sh' \
      ':!tests/boot-fixtures.sh' || true
  )"
  text_identity_paths="$(
    git -C "$guard_root" grep -ilIF "$legacy_identity" -- \
      ':!.env' \
      ":!$legacy_migration_path" \
      ':!scripts/lifecycle-remote.sh' \
      ':!scripts/uninstall.sh' \
      ':!tests/boot-fixtures.sh' || true
  )"
  binary_identity_matches="$(
    comm -23 \
      <(printf '%s\n' "$all_identity_paths" | sed '/^$/d' | LC_ALL=C sort -u) \
      <(printf '%s\n' "$text_identity_paths" | sed '/^$/d' | LC_ALL=C sort -u)
  )"
  if test -n "$binary_identity_matches"; then
    while IFS= read -r match_path; do
      invalid_identity_matches+="binary identity match: $match_path"$'\n'
    done <<< "$binary_identity_matches"
  fi
  identity_matches="$(
    git -C "$guard_root" grep -niIF "$legacy_identity" -- \
      ':!.env' \
      ":!$legacy_migration_path" \
      ':!scripts/lifecycle-remote.sh' \
      ':!scripts/uninstall.sh' \
      ':!tests/boot-fixtures.sh' || true
  )"
  if test -n "$identity_matches"; then
    while IFS=: read -r match_path match_line match_text; do
      while IFS= read -r identity_token; do
        if ! release_identity_token_allowed "$match_path" "$identity_token"; then
          invalid_identity_matches+="$match_path:$match_line:$match_text"$'\n'
          break
        fi
      done < <(
        printf '%s\n' "$match_text" |
          grep -oEi "[[:alnum:]_.-]*${legacy_identity}[[:alnum:]_.-]*" || true
      )
    done <<< "$identity_matches"
  fi
  credential_matches="$(
    git -C "$guard_root" grep -niE \
      "$legacy_host_marker|$legacy_password_marker" -- \
      ':!.env' \
      ":!$legacy_migration_path" \
      ':!scripts/lifecycle-remote.sh' \
      ':!scripts/uninstall.sh' \
      ':!tests/boot-fixtures.sh' || true
  )"
  if test -n "$invalid_identity_matches" || test -n "$credential_matches"; then
    printf '%s' "$invalid_identity_matches" >&2
    printf '%s\n' "$credential_matches" >&2
    printf 'release source contains a deployment-specific identity or credential\n' >&2
    return 1
  fi
}

release_identity_token_allowed() {
  local match_path="$1"
  local identity_token="$2"

  case "$match_path" in
    overlays/hyperpixel2r-kms-overlay.dts)
      case "$identity_token" in
        "$allowed_hyphen_interface"|\
        "$allowed_hyphen_pins"|\
        "$allowed_underscore_interface"|\
        "$allowed_underscore_pins") return 0 ;;
      esac
      ;;
    scripts/check-artifacts.sh)
      case "$identity_token" in
        "$allowed_hyphen_interface"|"$allowed_hyphen_pins"|"$allowed_backlight_rule") return 0 ;;
      esac
      ;;
    scripts/common.sh)
      case "$identity_token" in
        "$allowed_hyphen_interface"|\
        "$allowed_hyphen_pins"|\
        "$allowed_underscore_interface"|\
        "$allowed_underscore_pins"|\
        "$allowed_backlight_rule") return 0 ;;
      esac
      ;;
    tests/backlight-contract.sh)
      case "$identity_token" in
        "$allowed_hyphen_interface"|\
        "$allowed_hyphen_pins"|\
        "$allowed_underscore_interface") return 0 ;;
      esac
      ;;
    packaging/70-hyperpixel2r-backlight.rules|scripts/accepted-lifecycle.sh|scripts/build-driver.sh|scripts/stage-tryboot.sh|tests/transport-ancestor.sh|tests/boot-scripts.sh|tests/build-contract.sh|tests/release-contract.sh)
      case "$identity_token" in
        "$allowed_backlight_name"|"$allowed_backlight_rule") return 0 ;;
      esac
      ;;
  esac
  return 1
}

check_release_identity "$repo_root"

identity_fixture() {
  local fixture_name="$1"
  local fixture_path="$2"
  local fixture_text="$3"
  local fixture_root="$temporary_dir/identity-$fixture_name"

  mkdir -p "$fixture_root/$(dirname "$fixture_path")"
  printf '%s\n' "$fixture_text" > "$fixture_root/$fixture_path"
  git -C "$fixture_root" init -q
  git -C "$fixture_root" add "$fixture_path"
  printf '%s\n' "$fixture_root"
}

legitimate_identity_root="$(
  identity_fixture legitimate overlays/hyperpixel2r-kms-overlay.dts \
    "$allowed_underscore_interface: $allowed_hyphen_interface { $allowed_underscore_pins: $allowed_hyphen_pins { }"
)"
check_release_identity "$legitimate_identity_root" || {
  printf 'release identity guard rejected exact public interface tokens\n' >&2
  exit 1
}

legitimate_rule_root="$(
  identity_fixture legitimate-rule packaging/70-hyperpixel2r-backlight.rules \
    "KERNEL==\"$allowed_backlight_name\""
)"
check_release_identity "$legitimate_rule_root" || {
  printf 'release identity guard rejected the exact public backlight rule token\n' >&2
  exit 1
}

transport_ancestor_compound_root="$(
  identity_fixture transport-ancestor-compound tests/transport-ancestor.sh \
    "70-${legacy_identity}-backlight.rules-private"
)"
if check_release_identity "$transport_ancestor_compound_root" >/dev/null 2>&1; then
  printf 'release identity guard accepted hostile transport-ancestor compound\n' >&2
  exit 1
fi

transport_ancestor_credential_root="$(
  identity_fixture transport-ancestor-credential tests/transport-ancestor.sh \
    "${legacy_host_marker}private"
)"
if check_release_identity "$transport_ancestor_credential_root" >/dev/null 2>&1; then
  printf 'release identity guard accepted hostile transport-ancestor credential\n' >&2
  exit 1
fi

binary_identity_root="$temporary_dir/identity-binary"
binary_identity_path=overlays/hyperpixel2r-kms-overlay.dts
mkdir -p "$binary_identity_root/$(dirname "$binary_identity_path")"
printf 'prefix\0%s-private\0suffix\n' "$legacy_identity" \
  > "$binary_identity_root/$binary_identity_path"
git -C "$binary_identity_root" init -q
git -C "$binary_identity_root" add "$binary_identity_path"
if check_release_identity "$binary_identity_root" >/dev/null 2>&1; then
  printf 'release identity guard accepted hostile tracked binary\n' >&2
  exit 1
fi

for hostile_fixture in \
  'hyphen-suffix|overlays/hyperpixel2r-kms-overlay.dts' \
  'underscore-suffix|scripts/common.sh' \
  'hyphen-prefix|scripts/check-artifacts.sh' \
  'underscore-prefix|tests/backlight-contract.sh' \
  'rule-suffix|packaging/70-hyperpixel2r-backlight.rules'
do
  IFS='|' read -r fixture_name fixture_path <<< "$hostile_fixture"
  case "$fixture_name" in
    hyphen-suffix) fixture_text="${legacy_identity}-backlight-secret" ;;
    underscore-suffix) fixture_text="${legacy_identity}_backlight_pins_private" ;;
    hyphen-prefix) fixture_text="secret-${legacy_identity}-backlight" ;;
    underscore-prefix) fixture_text="private_${legacy_identity}_backlight_pins" ;;
    rule-suffix) fixture_text="${legacy_identity}-backlight-private" ;;
  esac
  hostile_identity_root="$(
    identity_fixture "$fixture_name" "$fixture_path" "$fixture_text"
  )"
  if check_release_identity "$hostile_identity_root" >/dev/null 2>&1; then
    printf 'release identity guard accepted hostile compound: %s\n' \
      "$fixture_text" >&2
    exit 1
  fi
done
printf 'release identity binary and compound simulations passed\n'

fixture="$temporary_dir/fixture"
mkdir "$fixture"

# A release must bind to a durable source commit.  Build a small clean clone of
# this working tree so the test can exercise packaging while the developer is
# still editing the real checkout.
tar \
  --exclude=.git \
  --exclude=.env \
  --exclude=dist \
  --exclude=target \
  -C "$repo_root" \
  -cf - . |
  tar -C "$fixture" -xf -
git -C "$fixture" init -q
git -C "$fixture" config user.name 'HyperPixel release contract'
git -C "$fixture" config user.email 'release-contract@example.invalid'
git -C "$fixture" add .
git -C "$fixture" commit -q --no-gpg-sign -m 'release fixture'
source_revision="$(git -C "$fixture" rev-parse HEAD)"
source_tree="$(git -C "$fixture" rev-parse 'HEAD^{tree}')"
canonical_release="$(tr -d '\n' < "$fixture/release/current-release.txt")"
release='6.18.34+rpt-rpi-v8'
artifact_dir="$fixture/dist/artifacts/$release"
target_dir="$fixture/dist/kernel-target/$release"
mkdir -p "$artifact_dir" "$target_dir"
overlay_file="hyperpixel2r-kms-${source_revision:0:12}.dtbo"
printf 'synthetic module fixture\n' > "$artifact_dir/hyperpixel2r_kms.ko"
printf 'synthetic overlay fixture\n' > "$artifact_dir/$overlay_file"
printf 'synthetic applied dtb fixture\n' > "$artifact_dir/hyperpixel2r-kms-applied.dtb"
printf '%s\n' 'SUBSYSTEM=="backlight", KERNEL=="hyperpixel2r-backlight", RUN+="/usr/bin/chgrp video /sys%p/brightness", RUN+="/usr/bin/chmod 0660 /sys%p/brightness"' > "$artifact_dir/70-hyperpixel2r-backlight.rules"
for helper in host-fixdep host-modpost host-genksyms; do
  printf 'synthetic %s fixture\n' "$helper" > "$artifact_dir/$helper"
done
module_sha256="$(sha256sum "$artifact_dir/hyperpixel2r_kms.ko" | awk '{print $1}')"
overlay_sha256="$(sha256sum "$artifact_dir/$overlay_file" | awk '{print $1}')"
applied_dtb_sha256="$(sha256sum "$artifact_dir/hyperpixel2r-kms-applied.dtb" | awk '{print $1}')"
backlight_rule_sha256="$(sha256sum "$artifact_dir/70-hyperpixel2r-backlight.rules" | awk '{print $1}')"
host_fixdep_sha256="$(sha256sum "$artifact_dir/host-fixdep" | awk '{print $1}')"
host_modpost_sha256="$(sha256sum "$artifact_dir/host-modpost" | awk '{print $1}')"
host_genksyms_sha256="$(sha256sum "$artifact_dir/host-genksyms" | awk '{print $1}')"
source_deb_sha256='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
base_dtb_sha256='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
{
  printf 'schema_version\t3\n'
  printf 'driver_version\t0.2.0\n'
  printf 'source_revision\t%s\n' "$source_revision"
  printf 'source_tree\t%s\n' "$source_tree"
  printf 'kernel_release\t%s\n' "$release"
  printf 'architecture\taarch64\n'
  printf 'base_dtb_sha256\t%s\n' "$base_dtb_sha256"
  printf 'capability\tpwm-backlight-v1\n'
  printf 'lifecycle_capability\texact-backlight-metadata-v1\n'
  printf 'module_file\thyperpixel2r_kms.ko\n'
  printf 'module_sha256\t%s\n' "$module_sha256"
  printf 'module_vermagic\t%s SMP preempt mod_unload modversions aarch64\n' "$release"
  printf 'overlay_file\t%s\n' "$overlay_file"
  printf 'overlay_sha256\t%s\n' "$overlay_sha256"
  printf 'applied_dtb_file\thyperpixel2r-kms-applied.dtb\n'
  printf 'applied_dtb_sha256\t%s\n' "$applied_dtb_sha256"
  printf 'backlight_rule_file\t%s\n' "$allowed_backlight_rule"
  printf 'backlight_rule_sha256\t%s\n' "$backlight_rule_sha256"
} > "$artifact_dir/manifest.txt"
printf '%s  hyperpixel2r_kms.ko\n' "$module_sha256" > "$artifact_dir/module.sha256"
printf '%s  %s\n' "$overlay_sha256" "$overlay_file" > "$artifact_dir/overlay.sha256"
printf '%s  hyperpixel2r-kms-applied.dtb\n' "$applied_dtb_sha256" > "$artifact_dir/applied-dtb.sha256"
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
  printf 'base_dtb_path\t/boot/firmware/bcm2710-rpi-zero-2-w.dtb\n'
  printf 'base_dtb_sha256\t%s\n' "$base_dtb_sha256"
} > "$target_dir/target.txt"

run_package() {
  local output="$1"

  "$fixture/scripts/package-release.sh" \
    --source-revision "$source_revision" \
    --artifact-dir "$fixture/dist/artifacts" \
    --output "$output"
}

first_output="$temporary_dir/first"
second_output="$temporary_dir/second"
run_package "$first_output"
run_package "$second_output"

"$fixture/scripts/validate-release-metadata.sh" \
  "$first_output/driver-manifest.json" \
  "$first_output/SBOM.spdx.json"

expected_assets=(
  hyperpixel2r-kms-source.tar.zst
  driver-manifest.json
  SHA256SUMS
  SBOM.spdx.json
  "hyperpixel2r-kms-${release}-aarch64.tar.zst"
)
for asset in "${expected_assets[@]}"; do
  test -f "$first_output/$asset" || {
    printf 'release asset is missing: %s\n' "$asset" >&2
    exit 1
  }
  cmp "$first_output/$asset" "$second_output/$asset"
done

test "$(find "$first_output" -maxdepth 1 -type f | wc -l | tr -d ' ')" = \
  "${#expected_assets[@]}"

(
  cd "$first_output"
  sha256sum -c SHA256SUMS
)

python3 - "$first_output" "$source_revision" "$source_tree" "$release" <<'PY'
import hashlib
import json
import pathlib
import re
import sys
import tarfile
import tempfile
import subprocess

output = pathlib.Path(sys.argv[1])
commit = sys.argv[2]
tree = sys.argv[3]
release = sys.argv[4]
manifest = json.loads((output / "driver-manifest.json").read_text())
schema = json.loads((output.parent / "fixture" / "release" / "driver-manifest.schema.json").read_text())

assert schema["$schema"] == "https://json-schema.org/draft/2020-12/schema"
assert manifest["schema_version"] == 2
assert manifest["capabilities"] == ["pwm-backlight-v1"]
assert manifest["driver_version"] == "0.2.0"
assert manifest["source"]["commit"] == commit
assert manifest["source"]["tree"] == tree
assert manifest["supported"]["architecture"] == "aarch64"
assert manifest["supported"]["kernel_policy"] == "exact-release-only"
artifacts = manifest["artifacts"]
assert [artifact["name"] for artifact in artifacts] == [
    "hyperpixel2r-kms-source.tar.zst",
    "SBOM.spdx.json",
    f"hyperpixel2r-kms-{release}-aarch64.tar.zst",
]
for artifact in artifacts:
    assert re.fullmatch(r"[0-9a-f]{64}", artifact["sha256"])
    assert artifact["size"] > 0
exact = artifacts[2]
assert exact["vermagic"] == (
    f"{release} SMP preempt mod_unload modversions aarch64"
)
assert re.fullmatch(r"[0-9a-f]{64}", exact["bundle_manifest_sha256"])
with tempfile.TemporaryDirectory(prefix="hp2r-exact-contract.") as temporary:
    tar_path = pathlib.Path(temporary) / "exact.tar"
    subprocess.run(
        ["zstd", "-q", "-d", "-c", output / exact["name"]],
        check=True,
        stdout=tar_path.open("wb"),
    )
    with tarfile.open(tar_path) as archive:
        manifest_member = next(
            member for member in archive.getmembers()
            if member.name.endswith("/manifest.txt")
        )
        manifest_bytes = archive.extractfile(manifest_member).read()
assert hashlib.sha256(manifest_bytes).hexdigest() == exact["bundle_manifest_sha256"]
PY

python3 - "$first_output" "$fixture/scripts/validate-release-metadata.sh" <<'PY'
import copy
import json
import pathlib
import subprocess
import sys
import tempfile

output = pathlib.Path(sys.argv[1])
validator = pathlib.Path(sys.argv[2])
manifest = json.loads((output / "driver-manifest.json").read_text())
sbom = output / "SBOM.spdx.json"

def reject(name, mutate):
    candidate = copy.deepcopy(manifest)
    mutate(candidate)
    with tempfile.TemporaryDirectory(prefix="hp2r-manifest-negative.") as temporary:
        path = pathlib.Path(temporary) / "manifest.json"
        path.write_text(json.dumps(candidate))
        result = subprocess.run([validator, path, sbom], capture_output=True, text=True)
        if result.returncode == 0:
            raise SystemExit(f"release metadata validator accepted invalid manifest: {name}")

reject("unknown-field", lambda value: value.__setitem__("unexpected", True))
reject("missing-source-tree", lambda value: value["source"].pop("tree"))
reject("bad-supported-constant", lambda value: value["supported"].__setitem__("board", "other"))
reject("wrong-capability", lambda value: value.__setitem__("capabilities", ["gpio-backlight-v1"]))
reject("missing-capability", lambda value: value.pop("capabilities"))
reject("bad-digest", lambda value: value["artifacts"][0].__setitem__("sha256", "bad"))
reject("exact-without-architecture", lambda value: value["artifacts"].append({
    "name": "hyperpixel2r-kms-test-aarch64.tar.zst",
    "kind": "exact-kernel-bundle",
    "sha256": "0" * 64,
    "size": 1,
    "kernel_release": "6.18.34+rpt-rpi-v8",
}))
reject("source-with-kernel-fields", lambda value: value["artifacts"][0].__setitem__("architecture", "aarch64"))
PY

python3 - "$first_output/SBOM.spdx.json" "$fixture/scripts/validate-release-metadata.sh" <<'PY'
import json
import pathlib
import subprocess
import sys
import tempfile

sbom = pathlib.Path(sys.argv[1])
validator = pathlib.Path(sys.argv[2])
document = json.loads(sbom.read_text())
document["files"][0]["checksums"] = [
    value for value in document["files"][0]["checksums"]
    if value["algorithm"] != "SHA1"
]
with tempfile.TemporaryDirectory(prefix="hp2r-spdx-negative.") as temporary:
    path = pathlib.Path(temporary) / "SBOM.spdx.json"
    path.write_text(json.dumps(document))
    result = subprocess.run([
        validator,
        sbom.parent / "driver-manifest.json",
        path,
    ], capture_output=True, text=True)
    if result.returncode == 0:
        raise SystemExit("official SPDX validator accepted an SBOM without a file SHA1")
PY

python3 - "$fixture/release/validator-requirements.txt" "$fixture/scripts/validate-release-metadata.sh" "$first_output/driver-manifest.json" "$first_output/SBOM.spdx.json" "$temporary_dir" <<'PY'
import os
import pathlib
import re
import subprocess
import sys

lock = pathlib.Path(sys.argv[1])
validator = pathlib.Path(sys.argv[2])
manifest = pathlib.Path(sys.argv[3])
sbom = pathlib.Path(sys.argv[4])
temporary = pathlib.Path(sys.argv[5])
text = lock.read_text()
match = re.search(r"--hash=sha256:([0-9a-f]{64})", text)
if match is None:
    raise SystemExit("validator lock has no SHA-256 hash to tamper")
replacement = ("0" if match.group(1)[0] != "0" else "1") + match.group(1)[1:]
tampered_lock = temporary / "validator-requirements-tampered.txt"
tampered_lock.write_text(text[:match.start(1)] + replacement + text[match.end(1):])
environment = os.environ | {
    "HP2R_VALIDATOR_REQUIREMENTS": str(tampered_lock),
    "HP2R_VALIDATOR_ROOT": str(temporary / "tampered-validator-root"),
}
result = subprocess.run([validator, manifest, sbom], capture_output=True, text=True, env=environment)
if result.returncode == 0:
    raise SystemExit("validator installer accepted a tampered dependency hash")
if "DO NOT MATCH THE HASHES" not in (result.stdout + result.stderr):
    raise SystemExit("tampered validator lock did not fail in pip hash-checking mode")
PY

"$fixture/scripts/validate-release-tag.sh" "$canonical_release" "$source_revision"
if "$fixture/scripts/validate-release-tag.sh" "v0.2.0-rc.18" "$source_revision"; then
  printf 'release tag validator accepted a tag that mismatches the canonical source release\n' >&2
  exit 1
fi
if "$fixture/scripts/validate-release-tag.sh" "v0.2.1-rc.19" "$source_revision"; then
  printf 'release tag validator accepted a tag whose base version mismatches the driver\n' >&2
  exit 1
fi

git -C "$fixture" switch -q -c release-marker-contract "$source_revision"
printf 'v0.2.0-rc.19\n\n' > "$fixture/release/current-release.txt"
git -C "$fixture" add release/current-release.txt
git -C "$fixture" commit -q --no-gpg-sign -m 'malformed release marker fixture'
malformed_marker_revision="$(git -C "$fixture" rev-parse HEAD)"
if "$fixture/scripts/validate-release-tag.sh" "v0.2.0-rc.19" "$malformed_marker_revision"; then
  printf 'release tag validator accepted a marker with a trailing blank line\n' >&2
  exit 1
fi

printf 'v0.2.0-rc.19' > "$fixture/release/current-release.txt"
git -C "$fixture" add release/current-release.txt
git -C "$fixture" commit -q --no-gpg-sign -m 'unterminated release marker fixture'
unterminated_marker_revision="$(git -C "$fixture" rev-parse HEAD)"
if "$fixture/scripts/validate-release-tag.sh" "v0.2.0-rc.19" "$unterminated_marker_revision"; then
  printf 'release tag validator accepted a marker without its final newline\n' >&2
  exit 1
fi

git -C "$fixture" rm -q release/current-release.txt
git -C "$fixture" commit -q --no-gpg-sign -m 'missing release marker fixture'
missing_marker_revision="$(git -C "$fixture" rev-parse HEAD)"
if "$fixture/scripts/validate-release-tag.sh" "v0.2.0-rc.19" "$missing_marker_revision"; then
  printf 'release tag validator accepted a source without its canonical marker\n' >&2
  exit 1
fi

printf 'v0.2.1-rc.19\n' > "$fixture/release/current-release.txt"
git -C "$fixture" add release/current-release.txt
git -C "$fixture" commit -q --no-gpg-sign -m 'driver version mismatch fixture'
driver_mismatch_revision="$(git -C "$fixture" rev-parse HEAD)"
if "$fixture/scripts/validate-release-tag.sh" "v0.2.1-rc.19" "$driver_mismatch_revision"; then
  printf 'release tag validator accepted a marker whose base version mismatches the driver\n' >&2
  exit 1
fi

printf 'v0.2.0-rc.18\n' > "$fixture/release/current-release.txt"
git -C "$fixture" add release/current-release.txt
git -C "$fixture" commit -q --no-gpg-sign -m 'distinct selected release marker fixture'
rc18_source_revision="$(git -C "$fixture" rev-parse HEAD)"
"$fixture/scripts/validate-release-tag.sh" "$canonical_release" "$source_revision"
"$fixture/scripts/validate-release-tag.sh" "v0.2.0-rc.18" "$rc18_source_revision"
git -C "$fixture" switch -q --detach "$source_revision"

"$fixture/scripts/validate-stable-release-tag.sh" "v0.2.0" "$source_revision"
if "$fixture/scripts/validate-stable-release-tag.sh" "v0.2.0-rc.3" "$source_revision"; then
  printf 'stable tag validator accepted a release-candidate tag\n' >&2
  exit 1
fi
if "$fixture/scripts/validate-stable-release-tag.sh" "v0.2.1" "$source_revision"; then
  printf 'stable tag validator accepted a tag whose version mismatches the driver\n' >&2
  exit 1
fi

# GitHub runs the workflow definition from its dispatch ref, while the user can
# select a different source_ref.  Simulate those two commits locally: the
# dispatch commit must carry release.yml, but packaging and the annotated tag
# must bind the checked-out source branch rather than that dispatch commit.
git -C "$fixture" branch release-source "$source_revision"
git -C "$fixture" switch -q -c dispatch-context "$source_revision"
printf 'workflow dispatch context\n' > "$fixture/.release-dispatch-context"
git -C "$fixture" add .release-dispatch-context
git -C "$fixture" commit -q --no-gpg-sign -m 'dispatch context fixture'
dispatch_commit="$(git -C "$fixture" rev-parse HEAD)"
git -C "$fixture" cat-file -e "$dispatch_commit:.github/workflows/release.yml"
git -C "$fixture" switch -q release-source
checked_out_source="$(git -C "$fixture" rev-parse 'HEAD^{commit}')"
test "$checked_out_source" = "$source_revision"
test "$checked_out_source" != "$dispatch_commit"
binding_output="$temporary_dir/source-ref-binding"
"$fixture/scripts/package-release.sh" \
  --source-revision "$checked_out_source" \
  --artifact-dir "$fixture/no-artifacts" \
  --output "$binding_output"
jq -e --arg commit "$checked_out_source" '.source.commit == $commit' \
  "$binding_output/driver-manifest.json" >/dev/null
"$fixture/scripts/validate-release-tag.sh" "$canonical_release" "$checked_out_source"
git -C "$fixture" tag --annotate "$canonical_release" "$checked_out_source" --message 'source-ref binding fixture'
test "$(git -C "$fixture" rev-parse "$canonical_release^{}")" = "$checked_out_source"

archive_tar="$temporary_dir/source.tar"
zstd -q -d -c "$first_output/hyperpixel2r-kms-source.tar.zst" > "$archive_tar"
python3 - "$archive_tar" "$source_revision" "$source_tree" <<'PY'
import pathlib
import tarfile
import sys

with tarfile.open(sys.argv[1]) as archive:
    members = archive.getmembers()
    assert members
    for member in members:
        path = pathlib.PurePosixPath(member.name)
        assert not path.is_absolute()
        assert ".." not in path.parts
        assert not member.issym()
        assert not member.islnk()
        assert member.uid == 0
        assert member.gid == 0
    names = {member.name for member in members}
    assert any(name.endswith("/scripts/package-release.sh") for name in names)
    identity_name = next(
        name for name in names if name.endswith("/release/source-identity.txt")
    )
    identity = archive.extractfile(identity_name).read().decode()
    assert identity == (
        "schema_version\t1\n"
        "repository\thttps://github.com/shayne/hyperpixel2r-kms\n"
        f"source_revision\t{sys.argv[2]}\n"
        f"source_tree\t{sys.argv[3]}\n"
    )
PY

release_source_root="$temporary_dir/release-source"
mkdir "$release_source_root"
tar -C "$release_source_root" -xf "$archive_tar"
release_source="$(find "$release_source_root" -mindepth 1 -maxdepth 1 -type d)"
test -n "$release_source"
test ! -e "$release_source/.git"
bash -eu -c \
  'source "$1/scripts/common.sh"; hp2r_validate_release_source "$1" "$2" "$3"' \
  bash \
  "$release_source" \
  "$source_revision" \
  "$source_tree"

if test -d "$repo_root/dist/artifacts" &&
  git -C "$repo_root" diff-index --quiet HEAD --; then
  current_revision="$(git -C "$repo_root" rev-parse --verify 'origin/main^{commit}')"
  for manifest in "$repo_root"/dist/artifacts/*/manifest.txt; do
    test -f "$manifest" || continue
    if test "$(awk -F '\t' '$1 == "source_revision" { print $2 }' "$manifest")" != "$current_revision"; then
      continue
    fi
    exact_output="$temporary_dir/exact"
    "$repo_root/scripts/package-release.sh" \
      --source-revision "$current_revision" \
      --artifact-dir "$repo_root/dist/artifacts" \
      --output "$exact_output"
    exact_archive="$(find "$exact_output" -maxdepth 1 -type f -name 'hyperpixel2r-kms-*-aarch64.tar.zst')"
    test -n "$exact_archive"
    test "$(printf '%s\n' "$exact_archive" | wc -l | tr -d ' ')" = 1
    exact_tar="$temporary_dir/exact.tar"
    zstd -q -d -c "$exact_archive" > "$exact_tar"
    python3 - "$exact_tar" <<'PY'
import pathlib
import tarfile
import sys

with tarfile.open(sys.argv[1]) as archive:
    members = archive.getmembers()
    assert members
    for member in members:
        path = pathlib.PurePosixPath(member.name)
        assert not path.is_absolute()
        assert ".." not in path.parts
        assert not member.issym()
        assert not member.islnk()
        assert member.uid == 0
        assert member.gid == 0
    names = {member.name for member in members}
    assert any(name.endswith("/hyperpixel2r_kms.ko") for name in names)
    assert any(name.endswith("/manifest.txt") for name in names)
PY
    jq -e --arg release "$(basename "$(dirname "$manifest")")" '
      .artifacts[] |
      select(.kind == "exact-kernel-bundle") |
      .architecture == "aarch64" and .kernel_release == $release
    ' "$exact_output/driver-manifest.json" >/dev/null
  done
fi

printf 'release contract passed\n'
