#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Keep the first assertion blunt.  A missing packager is a real contract
# failure, rather than a later and much less useful failure from a fixture.
test -x "$repo_root/scripts/package-release.sh" || {
  printf 'missing deterministic release packager: scripts/package-release.sh\n' >&2
  exit 1
}

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

for relative in (".github/workflows/ci.yml", ".github/workflows/release.yml"):
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
    current = release_marker.read_text().strip()
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+-rc\.[1-9][0-9]*", current):
        failures.append("canonical release marker must be a numbered release-candidate tag")
    readme = (root / "README.md").read_text()
    tags = set(re.findall(r"v[0-9]+\.[0-9]+\.[0-9]+-rc\.[1-9][0-9]*", readme))
    if tags != {current}:
        failures.append("README status and release commands must use only the canonical release marker")
    if f"<!-- HP2R_CURRENT_RELEASE={current} -->" not in readme:
        failures.append("README must expose the canonical release marker for the contract")

requirements = root / "release" / "validator-requirements.txt"
validator = root / "scripts" / "validate-release-metadata.sh"
if not requirements.is_file() or "spdx-tools==0.8.3" not in requirements.read_text():
    failures.append("release validators must pin official spdx-tools 0.8.3")
if not requirements.is_file() or "check-jsonschema==0.37.4" not in requirements.read_text():
    failures.append("release validators must pin check-jsonschema 0.37.4")
if not validator.is_file() or not validator.stat().st_mode & 0o111:
    failures.append("missing executable real release-metadata validator")

tag_validator = root / "scripts" / "validate-release-tag.sh"
if not tag_validator.is_file() or not tag_validator.stat().st_mode & 0o111:
    failures.append("missing executable release tag/version validator")

release_workflow = root / ".github" / "workflows" / "release.yml"
if release_workflow.is_file():
    workflow = release_workflow.read_text()
    ordered_steps = [
        "Confirm unused tag and bind selected source",
        "Verify the selected source before release packaging",
        "Build reproducible release assets",
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
if git -C "$repo_root" grep -niE "$legacy_identity|$legacy_host_marker|$legacy_password_marker" -- ':!.env'; then
  printf 'release source contains a deployment-specific identity or credential\n' >&2
  exit 1
fi

temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/hp2r-release-contract.XXXXXX")"
trap 'rm -rf "$temporary_dir"' EXIT
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

run_package() {
  local output="$1"

  "$fixture/scripts/package-release.sh" \
    --source-revision "$source_revision" \
    --artifact-dir "$fixture/no-artifacts" \
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

python3 - "$first_output" "$source_revision" "$source_tree" <<'PY'
import json
import pathlib
import re
import sys

output = pathlib.Path(sys.argv[1])
commit = sys.argv[2]
tree = sys.argv[3]
manifest = json.loads((output / "driver-manifest.json").read_text())
schema = json.loads((output.parent / "fixture" / "release" / "driver-manifest.schema.json").read_text())

assert schema["$schema"] == "https://json-schema.org/draft/2020-12/schema"
assert manifest["schema_version"] == 1
assert manifest["driver_version"] == "0.1.0"
assert manifest["source"]["commit"] == commit
assert manifest["source"]["tree"] == tree
assert manifest["supported"]["architecture"] == "aarch64"
assert manifest["supported"]["kernel_policy"] == "exact-release-only"
artifacts = manifest["artifacts"]
assert [artifact["name"] for artifact in artifacts] == [
    "hyperpixel2r-kms-source.tar.zst",
    "SBOM.spdx.json",
]
for artifact in artifacts:
    assert re.fullmatch(r"[0-9a-f]{64}", artifact["sha256"])
    assert artifact["size"] > 0
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

"$fixture/scripts/validate-release-tag.sh" "v0.1.0-rc.3" "$source_revision"
if "$fixture/scripts/validate-release-tag.sh" "v0.1.1-rc.3" "$source_revision"; then
  printf 'release tag validator accepted a tag whose base version mismatches the driver\n' >&2
  exit 1
fi

archive_tar="$temporary_dir/source.tar"
zstd -q -d -c "$first_output/hyperpixel2r-kms-source.tar.zst" > "$archive_tar"
python3 - "$archive_tar" <<'PY'
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
PY

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
