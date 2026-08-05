#!/usr/bin/env bash
set -euo pipefail

# Fixture-only process kept alive above a real accepted controller. Its argv
# is deliberately inspected by the remote writer guard while the child runs.
repo_root="${HP2R_FIXTURE_REPO_ROOT:?}"

"$repo_root/scripts/accepted-lifecycle.sh" \
  --action prepare-new \
  --driver-version "${HP2R_FIXTURE_ANCESTOR_DRIVER_VERSION:?}" \
  --source-revision "${HP2R_FIXTURE_ANCESTOR_SOURCE_REVISION:?}" \
  --kernel-release "${HP2R_FIXTURE_ANCESTOR_KERNEL_RELEASE:?}" \
  --kernel-target "${HP2R_FIXTURE_ANCESTOR_KERNEL_TARGET:?}" \
  --target-identity-sha256 "${HP2R_FIXTURE_ANCESTOR_TARGET_IDENTITY:?}" \
  --manifest-sha256 "${HP2R_FIXTURE_ANCESTOR_MANIFEST_SHA:?}" \
  --module-file hyperpixel2r_kms.ko \
  --module-sha256 "${HP2R_FIXTURE_ANCESTOR_MODULE_SHA:?}" \
  --overlay-file "${HP2R_FIXTURE_ANCESTOR_OVERLAY_FILE:?}" \
  --overlay-sha256 "${HP2R_FIXTURE_ANCESTOR_OVERLAY_SHA:?}" \
  --backlight-rule-file 70-planeradar-backlight.rules \
  --backlight-rule-sha256 "${HP2R_FIXTURE_ANCESTOR_BACKLIGHT_RULE_SHA:?}"
