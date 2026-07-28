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
docker run --rm \
  --volume "$repo_root:/repo:ro" \
  --workdir /repo \
  --env HP2R_FIXTURE_REPO_ROOT=/repo \
  "$image" \
  bash tests/boot-fixtures.sh

printf 'Driver boot lifecycle executable fixtures passed\n'
