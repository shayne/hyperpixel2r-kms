#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'USAGE'
Usage: validate-release-tag.sh TAG SOURCE-REVISION

Require a numbered release-candidate tag whose base semantic version exactly
matches HP2R_DRIVER_VERSION in the selected durable source commit.
USAGE
}

if test "$#" -ne 2; then
  usage >&2
  exit 64
fi

tag="$1"
source_ref="$2"
if [[ ! "$tag" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)-rc\.([1-9][0-9]*)$ ]]; then
  printf 'release tag must be vMAJOR.MINOR.PATCH-rc.N: %s\n' "$tag" >&2
  exit 1
fi
tag_version="${BASH_REMATCH[1]}"

source_revision="$(git -C "$repo_root" rev-parse --verify "$source_ref^{commit}")"
driver_version="$({
  git -C "$repo_root" show "$source_revision:scripts/common.sh" |
    sed -nE 's/^HP2R_DRIVER_VERSION="([0-9]+\.[0-9]+\.[0-9]+)"$/\1/p'
})"
if [[ ! "$driver_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'selected source does not declare a release semantic driver version\n' >&2
  exit 1
fi
if test "$tag_version" != "$driver_version"; then
  printf 'release tag base version %s does not match source driver version %s\n' \
    "$tag_version" "$driver_version" >&2
  exit 1
fi

printf '%s\n' "$source_revision"
