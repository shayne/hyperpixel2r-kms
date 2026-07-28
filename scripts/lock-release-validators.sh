#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
input="$repo_root/release/validator-requirements.in"
tools_lock="$repo_root/release/validator-lock-tools.txt"
output="release/validator-requirements.txt"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/hp2r-validator-lock.XXXXXX")"
trap 'rm -rf "$temporary_dir"' EXIT

test -f "$input"
test -f "$tools_lock"
cd "$repo_root"

python3 -m venv "$temporary_dir/venv"
"$temporary_dir/venv/bin/pip" install \
  --isolated \
  --require-hashes \
  --no-deps \
  --only-binary=:all: \
  --disable-pip-version-check \
  --quiet \
  --requirement "$tools_lock"

CUSTOM_COMPILE_COMMAND='./scripts/lock-release-validators.sh' \
  "$temporary_dir/venv/bin/pip-compile" \
    --resolver=backtracking \
    --generate-hashes \
    --upgrade \
    --strip-extras \
    --no-emit-index-url \
    --pip-args='--isolated --only-binary=:all:' \
    --output-file "$output" \
    release/validator-requirements.in
