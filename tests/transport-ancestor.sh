#!/usr/bin/env bash
set -euo pipefail

# Fixture-only benign transport process kept alive above the real accepted
# controller. The live SSH transport presents the same oversized,
# non-lifecycle ancestor shape to the remote writer guard.
repo_root="${HP2R_FIXTURE_REPO_ROOT:?}"
oversized="${1:?}"
test "${#oversized}" -gt 4096

"$repo_root/scripts/accepted-lifecycle.sh" \
  --action prepare-new \
  --driver-version "${HP2R_FIXTURE_TRANSPORT_DRIVER_VERSION:?}" \
  --source-revision "${HP2R_FIXTURE_TRANSPORT_SOURCE_REVISION:?}" \
  --kernel-release "${HP2R_FIXTURE_TRANSPORT_KERNEL_RELEASE:?}" \
  --kernel-target "${HP2R_FIXTURE_TRANSPORT_KERNEL_TARGET:?}" \
  --target-identity-sha256 "${HP2R_FIXTURE_TRANSPORT_TARGET_IDENTITY:?}" \
  --manifest-sha256 "${HP2R_FIXTURE_TRANSPORT_MANIFEST_SHA:?}" \
  --module-file hyperpixel2r_kms.ko \
  --module-sha256 "${HP2R_FIXTURE_TRANSPORT_MODULE_SHA:?}" \
  --overlay-file "${HP2R_FIXTURE_TRANSPORT_OVERLAY_FILE:?}" \
  --overlay-sha256 "${HP2R_FIXTURE_TRANSPORT_OVERLAY_SHA:?}" \
  --backlight-rule-file 70-planeradar-backlight.rules \
  --backlight-rule-sha256 "${HP2R_FIXTURE_TRANSPORT_BACKLIGHT_RULE_SHA:?}"
