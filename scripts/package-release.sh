#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/scripts/common.sh"

usage() {
  cat <<'USAGE'
Usage: package-release.sh [OPTIONS]

Create deterministic, source-bound HyperPixel 2 Round driver release assets.

Options:
  --source-revision REF  Bind the release to this tree-identical Git commit
  --artifact-dir DIR     Exact-kernel artifact parent (default: dist/artifacts)
  --output DIR           New output directory (default: dist/release)
  -h, --help             Show this help

The output directory must not exist.  An exact-kernel archive is included only
when a complete, validated artifact bundle matches the selected source commit.
USAGE
}

source_ref=""
artifact_parent="$repo_root/dist/artifacts"
output="$repo_root/dist/release"
while test "$#" -gt 0; do
  case "$1" in
    --source-revision)
      test "$#" -ge 2 || { echo "--source-revision requires a value" >&2; exit 64; }
      source_ref="$2"
      shift 2
      ;;
    --artifact-dir)
      test "$#" -ge 2 || { echo "--artifact-dir requires a value" >&2; exit 64; }
      artifact_parent="$2"
      shift 2
      ;;
    --output)
      test "$#" -ge 2 || { echo "--output requires a value" >&2; exit 64; }
      output="$2"
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

cd "$repo_root"
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
  source_revision="$(hp2r_resolve_build_revision)"
  source_tree="$workspace_tree"
fi
hp2r_require_durable_source_revision "$source_revision"
source_epoch="$(git show -s --format=%ct "$source_revision")"
[[ "$source_epoch" =~ ^[0-9]+$ ]]
driver_version="$(git show "$source_revision:scripts/common.sh" | sed -nE 's/^HP2R_DRIVER_VERSION="([0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?)"$/\1/p')"
[[ "$driver_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || {
  echo "source revision does not declare a semantic driver version" >&2
  exit 1
}

case "$output" in
  ''|/)
    echo "unsafe release output directory: $output" >&2
    exit 64
    ;;
esac
test ! -e "$output" || {
  echo "release output already exists: $output" >&2
  exit 1
}
output_parent="$(dirname "$output")"
mkdir -p "$output_parent"
output_parent="$(cd "$output_parent" && pwd -P)"
output="$output_parent/$(basename "$output")"
test ! -e "$output"
stage="$(mktemp -d "$output_parent/.release.XXXXXX")"
work="$(mktemp -d "${TMPDIR:-/tmp}/hp2r-release.XXXXXX")"
cleanup() {
  rm -rf "$stage" "$work"
}
trap cleanup EXIT

source_tar="$work/hyperpixel2r-kms-source.tar"
source_archive="$stage/hyperpixel2r-kms-source.tar.zst"
python3 - "$repo_root" "$source_revision" "$source_tree" "$source_epoch" "$source_tar" "hyperpixel2r-kms-${driver_version}" <<'PY'
import io
import os
import pathlib
import subprocess
import sys
import tarfile

root, revision, tree, epoch, output, prefix = sys.argv[1:]
epoch = int(epoch)

def checked_path(path: str) -> pathlib.PurePosixPath:
    value = pathlib.PurePosixPath(path)
    if value.is_absolute() or not value.parts or ".." in value.parts:
        raise SystemExit(f"unsafe source path in Git tree: {path!r}")
    return value

entries = subprocess.check_output(
    ["git", "-C", root, "ls-tree", "-r", "-z", "--full-tree", revision]
).split(b"\0")
files = []
for entry in entries:
    if not entry:
        continue
    meta, raw_path = entry.split(b"\t", 1)
    mode, kind, object_id = meta.decode("ascii").split()
    path = checked_path(raw_path.decode("utf-8"))
    if kind != "blob" or mode == "120000":
        raise SystemExit(f"release source refuses non-regular Git entry: {path}")
    if mode not in {"100644", "100755"}:
        raise SystemExit(f"release source has unsupported mode {mode}: {path}")
    files.append((str(path), mode, object_id))
files.sort()

with tarfile.open(output, "w", format=tarfile.PAX_FORMAT) as archive:
    directories = set()
    for path, _, _ in files:
        current = pathlib.PurePosixPath(path).parent
        while str(current) != ".":
            directories.add(str(current))
            current = current.parent
    for directory in sorted(directories):
        info = tarfile.TarInfo(f"{prefix}/{directory}/")
        info.type = tarfile.DIRTYPE
        info.mode = 0o755
        info.uid = info.gid = 0
        info.uname = info.gname = ""
        info.mtime = epoch
        archive.addfile(info)
    identity = (
        "schema_version\t1\n"
        "repository\thttps://github.com/shayne/hyperpixel2r-kms\n"
        f"source_revision\t{revision}\n"
        f"source_tree\t{tree}\n"
    ).encode()
    info = tarfile.TarInfo(f"{prefix}/release/source-identity.txt")
    info.size = len(identity)
    info.mode = 0o644
    info.uid = info.gid = 0
    info.uname = info.gname = ""
    info.mtime = epoch
    archive.addfile(info, io.BytesIO(identity))
    for path, mode, object_id in files:
        contents = subprocess.check_output(["git", "-C", root, "cat-file", "blob", object_id])
        info = tarfile.TarInfo(f"{prefix}/{path}")
        info.size = len(contents)
        info.mode = 0o755 if mode == "100755" else 0o644
        info.uid = info.gid = 0
        info.uname = info.gname = ""
        info.mtime = epoch
        archive.addfile(info, io.BytesIO(contents))
PY
zstd -q -19 --threads=1 --no-progress "$source_tar" -o "$source_archive"

exact_entries_file="$work/exact-entries.tsv"
: > "$exact_entries_file"
if test -d "$artifact_parent"; then
  artifact_parent="$(cd "$artifact_parent" && pwd -P)"
  shopt -s nullglob
  for artifact_dir in "$artifact_parent"/*; do
    test -d "$artifact_dir" && test ! -L "$artifact_dir" || continue
    release="$(basename "$artifact_dir")"
    hp2r_validate_release "$release" || {
      echo "artifact directory has an unsafe kernel release: $artifact_dir" >&2
      exit 1
    }
    artifact_manifest="$artifact_dir/manifest.txt"
    test -f "$artifact_manifest" || continue
    if test "$(hp2r_manifest_value "$artifact_manifest" source_revision)" != "$source_revision"; then
      continue
    fi
    test "$(hp2r_manifest_value "$artifact_manifest" source_tree)" = "$source_tree" || {
      echo "exact artifact source tree does not match selected release source" >&2
      exit 1
    }
    target_manifest="$repo_root/dist/kernel-target/$release/target.txt"
    test -f "$target_manifest" || {
      echo "exact artifact is missing its validated kernel export: $release" >&2
      exit 1
    }
    hp2r_validate_artifact_provenance "$artifact_manifest" "$target_manifest" "$artifact_dir"
    for checksum in module.sha256 overlay.sha256 applied-dtb.sha256; do
      test -f "$artifact_dir/$checksum" || {
        echo "exact artifact is missing checksum evidence: $checksum" >&2
        exit 1
      }
    done
    hp2r_validate_checksum_file "$artifact_dir/module.sha256" "$artifact_dir/hyperpixel2r_kms.ko"
    hp2r_validate_checksum_file \
      "$artifact_dir/overlay.sha256" \
      "$artifact_dir/$(hp2r_manifest_value "$artifact_manifest" overlay_file)"
    hp2r_validate_checksum_file \
      "$artifact_dir/applied-dtb.sha256" \
      "$artifact_dir/$(hp2r_manifest_value "$artifact_manifest" applied_dtb_file)"
    printf '%s\t%s\n' "$release" "$artifact_dir" >> "$exact_entries_file"
  done
fi

while IFS=$'\t' read -r release artifact_dir; do
  test -n "$release" || continue
  exact_name="hyperpixel2r-kms-${release}-aarch64.tar.zst"
  exact_tar="$work/${exact_name%.zst}"
  python3 - "$artifact_dir" "$source_epoch" "$exact_tar" "hyperpixel2r-kms-${driver_version}-${release}-aarch64" <<'PY'
import io
import os
import pathlib
import stat
import sys
import tarfile

root = pathlib.Path(sys.argv[1]).resolve()
epoch = int(sys.argv[2])
output = sys.argv[3]
prefix = sys.argv[4]
files = []
for path in sorted(root.rglob("*")):
    relative = path.relative_to(root)
    if path.is_symlink() or not path.is_file():
        if path.is_dir():
            continue
        raise SystemExit(f"exact artifact contains an unsafe non-regular path: {relative}")
    pure = pathlib.PurePosixPath(relative.as_posix())
    if pure.is_absolute() or ".." in pure.parts:
        raise SystemExit(f"exact artifact path escapes archive: {relative}")
    files.append((pure, path))
with tarfile.open(output, "w", format=tarfile.PAX_FORMAT) as archive:
    directories = sorted({str(item.parent) for item, _ in files if str(item.parent) != "."})
    for directory in directories:
        info = tarfile.TarInfo(f"{prefix}/{directory}/")
        info.type = tarfile.DIRTYPE
        info.mode = 0o755
        info.uid = info.gid = 0
        info.uname = info.gname = ""
        info.mtime = epoch
        archive.addfile(info)
    for relative, path in files:
        contents = path.read_bytes()
        info = tarfile.TarInfo(f"{prefix}/{relative}")
        info.size = len(contents)
        info.mode = 0o755 if (path.stat().st_mode & stat.S_IXUSR) else 0o644
        info.uid = info.gid = 0
        info.uname = info.gname = ""
        info.mtime = epoch
        archive.addfile(info, io.BytesIO(contents))
PY
  zstd -q -19 --threads=1 --no-progress "$exact_tar" -o "$stage/$exact_name"
done < "$exact_entries_file"

sbom="$stage/SBOM.spdx.json"
python3 - "$repo_root" "$source_revision" "$source_epoch" "$driver_version" "$sbom" <<'PY'
import datetime
import hashlib
import json
import pathlib
import subprocess
import sys

root, revision, epoch, version, output = sys.argv[1:]
epoch = int(epoch)
entries = subprocess.check_output(
    ["git", "-C", root, "ls-tree", "-r", "-z", "--full-tree", revision]
).split(b"\0")
files = []
for index, entry in enumerate(item for item in entries if item):
    meta, raw_path = entry.split(b"\t", 1)
    mode, kind, object_id = meta.decode("ascii").split()
    if kind != "blob" or mode == "120000":
        raise SystemExit("SBOM source contains an unsupported Git entry")
    path = pathlib.PurePosixPath(raw_path.decode("utf-8"))
    if path.is_absolute() or ".." in path.parts:
        raise SystemExit("SBOM source path is unsafe")
    content = subprocess.check_output(["git", "-C", root, "cat-file", "blob", object_id])
    files.append({
        "SPDXID": f"SPDXRef-File-{index}",
        "fileName": f"./{path.as_posix()}",
        "checksums": [
            {"algorithm": "SHA1", "checksumValue": hashlib.sha1(content).hexdigest()},
            {"algorithm": "SHA256", "checksumValue": hashlib.sha256(content).hexdigest()},
        ],
        "licenseConcluded": "NOASSERTION",
        "copyrightText": "NOASSERTION",
    })
created = datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
document = {
    "spdxVersion": "SPDX-2.3",
    "dataLicense": "CC0-1.0",
    "SPDXID": "SPDXRef-DOCUMENT",
    "name": f"hyperpixel2r-kms-{version}",
    "documentNamespace": f"https://github.com/shayne/hyperpixel2r-kms/tree/{revision}",
    "creationInfo": {
        "created": created,
        "creators": ["Tool: hyperpixel2r-kms package-release.sh"],
    },
    "packages": [{
        "SPDXID": "SPDXRef-Package-hyperpixel2r-kms",
        "name": "hyperpixel2r-kms",
        "versionInfo": version,
        "downloadLocation": "NOASSERTION",
        "filesAnalyzed": True,
        "licenseConcluded": "GPL-2.0-only",
        "licenseDeclared": "GPL-2.0-only",
        "copyrightText": "NOASSERTION",
        "externalRefs": [{
            "referenceCategory": "OTHER",
            "referenceType": "git",
            "referenceLocator": f"git+https://github.com/shayne/hyperpixel2r-kms@{revision}",
        }],
    }],
    "files": files,
    "relationships": [
        {
            "spdxElementId": "SPDXRef-DOCUMENT",
            "relationshipType": "DESCRIBES",
            "relatedSpdxElement": "SPDXRef-Package-hyperpixel2r-kms",
        },
        *[
            {
                "spdxElementId": "SPDXRef-Package-hyperpixel2r-kms",
                "relationshipType": "CONTAINS",
                "relatedSpdxElement": item["SPDXID"],
            }
            for item in files
        ],
    ],
}
pathlib.Path(output).write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
PY

manifest="$stage/driver-manifest.json"
python3 - "$stage" "$manifest" "$source_revision" "$source_tree" "$source_epoch" "$driver_version" "$exact_entries_file" <<'PY'
import hashlib
import json
import pathlib
import sys

stage = pathlib.Path(sys.argv[1])
output = pathlib.Path(sys.argv[2])
commit, tree, epoch, version = sys.argv[3:7]
exact_entries = pathlib.Path(sys.argv[7]).read_text().splitlines()

def artifact(name, kind, **extra):
    path = stage / name
    return {
        "name": name,
        "kind": kind,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "size": path.stat().st_size,
        **extra,
    }

artifacts = [
    artifact("hyperpixel2r-kms-source.tar.zst", "source-archive"),
    artifact("SBOM.spdx.json", "sbom"),
]
for line in exact_entries:
    if not line:
        continue
    release, artifact_directory = line.split("\t", 1)
    bundle_manifest = pathlib.Path(artifact_directory) / "manifest.txt"
    bundle_fields = dict(
        row.split("\t", 1)
        for row in bundle_manifest.read_text().splitlines()
    )
    artifacts.append(artifact(
        f"hyperpixel2r-kms-{release}-aarch64.tar.zst",
        "exact-kernel-bundle",
        architecture="aarch64",
        kernel_release=release,
        vermagic=bundle_fields["module_vermagic"],
        bundle_manifest_sha256=hashlib.sha256(bundle_manifest.read_bytes()).hexdigest(),
    ))
document = {
    "schema_version": 1,
    "driver_version": version,
    "source": {
        "repository": "https://github.com/shayne/hyperpixel2r-kms",
        "commit": commit,
        "tree": tree,
        "date_epoch": int(epoch),
    },
    "supported": {
        "board": "Raspberry Pi Zero 2 W",
        "display": "HyperPixel 2.1 Round",
        "operating_system": "Raspberry Pi OS Lite (Trixie, 64-bit)",
        "architecture": "aarch64",
        "kernel_policy": "exact-release-only",
    },
    "reproducibility": {
        "archive_format": "tar+zstd",
        "source_date_epoch": int(epoch),
        "owner": 0,
        "group": 0,
        "mode_policy": "git-executable-or-regular",
    },
    "artifacts": artifacts,
}
output.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
PY

"$repo_root/scripts/validate-release-metadata.sh" "$manifest" "$sbom"

(
  cd "$stage"
  for asset in driver-manifest.json hyperpixel2r-kms-source.tar.zst SBOM.spdx.json hyperpixel2r-kms-*-aarch64.tar.zst; do
    test -e "$asset" || continue
    hp2r_require_regular "$asset"
    printf '%s  %s\n' "$(hp2r_sha256 "$asset")" "$asset"
  done | LC_ALL=C sort > SHA256SUMS
  sha256sum -c SHA256SUMS >/dev/null
)

mv "$stage" "$output"
stage=""
printf 'Packaged HyperPixel driver release at %s\n' "$output"
