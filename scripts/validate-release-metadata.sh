#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
schema="$repo_root/release/driver-manifest.schema.json"
requirements="$repo_root/release/validator-requirements.txt"
validator_root="$repo_root/target/release-validators"

usage() {
  cat <<'USAGE'
Usage: validate-release-metadata.sh MANIFEST SBOM

Validate a release manifest with Draft 2020-12 JSON Schema and validate an
SPDX 2.3 SBOM with the official SPDX Python tools. The locked validator
environment is created beneath target/ on first use.
USAGE
}

if test "$#" -ne 2; then
  usage >&2
  exit 64
fi

manifest="$1"
sbom="$2"
test -f "$schema"
test -f "$requirements"
test -f "$manifest"
test -f "$sbom"

requirements_digest="$(sha256sum "$requirements" | awk '{ print $1 }')"
marker="$validator_root/requirements.sha256"
if test ! -x "$validator_root/bin/check-jsonschema" ||
  test ! -x "$validator_root/bin/pyspdxtools" ||
  test ! -f "$marker" ||
  test "$(cat "$marker")" != "$requirements_digest"; then
  rm -rf -- "$validator_root"
  python3 -m venv "$validator_root"
  "$validator_root/bin/pip" install \
    --disable-pip-version-check \
    --quiet \
    --requirement "$requirements"
  printf '%s\n' "$requirements_digest" > "$marker"
fi

"$validator_root/bin/check-jsonschema" --schemafile "$schema" "$manifest"
"$validator_root/bin/pyspdxtools" -i "$sbom"
