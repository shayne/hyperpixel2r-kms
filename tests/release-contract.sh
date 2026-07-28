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
assert (output / "SBOM.spdx.json").read_text().startswith("{")
PY

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
  current_revision="$(
    bash -eu -c \
      'cd "$1"; source "$2"; hp2r_resolve_build_revision' \
      bash \
      "$repo_root" \
      "$repo_root/scripts/common.sh"
  )"
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
