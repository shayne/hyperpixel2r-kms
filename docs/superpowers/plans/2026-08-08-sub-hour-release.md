# Sub-Hour Driver Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish the generic HyperPixel driver and Plane Radar brightness release through one complete CI verification and one physical acceptance cycle, while making the same path reusable in roughly one hour.

**Architecture:** Current driver artifacts use only HyperPixel identities. A push runs focused jobs plus the complete lifecycle suite once and produces one commit-bound release bundle. RC and stable workflows validate and republish those exact bytes; they never rebuild or rerun the full suite. Plane Radar consumes the generic backlight identity and orchestrates one tryboot-to-stable acceptance.

**Tech Stack:** Bash, Rust, Linux DRM/backlight sysfs, Device Tree overlays, GitHub Actions, GitHub artifact attestations, GitButler, Raspberry Pi tryboot.

## Global Constraints

- Keep durable rollback and interruption journals intact.
- Use GitButler for every commit and landing operation.
- Preserve Plane Radar names only in exact legacy-migration inputs.
- Run focused tests locally; run the complete suite once in CI for the pushed commit.
- RC and stable assets must be byte-identical to the successful CI artifact.
- Never print the private target, coordinates, timezone, settings, or credentials.

---

### Task 1: Generic HyperPixel backlight identity

**Files:**
- Modify: `overlays/hyperpixel2r-kms-overlay.dts`
- Rename: `packaging/70-planeradar-backlight.rules` to `packaging/70-hyperpixel2r-backlight.rules`
- Modify: `scripts/common.sh`
- Modify: `scripts/build-driver.sh`
- Modify: `scripts/check-artifacts.sh`
- Modify: `scripts/lifecycle-remote.sh`
- Modify: `scripts/accepted-lifecycle.sh`
- Modify: `tests/backlight-contract.sh`
- Modify: `tests/build-contract.sh`
- Modify: `tests/release-contract.sh`
- Modify: `tests/boot-scripts.sh`
- Modify: `tests/boot-fixtures.sh`

**Interfaces:**
- Produces: sysfs device `hyperpixel2r-backlight`, udev rule `70-hyperpixel2r-backlight.rules`, symbols `hyperpixel2r_backlight` and `hyperpixel2r_backlight_pins`.
- Preserves: `release/legacy-planeradar-migration-v1.tsv` and `cleanup-legacy-planeradar` inputs unchanged.

- [ ] **Step 1: Change focused contracts to expect the generic names**

Replace current-artifact expectations only. Keep every legacy migration fixture using its original `planeradar-*` identity.

- [ ] **Step 2: Run focused contracts and confirm they fail**

Run:

```bash
mise run test-backlight-contract
mise run test-build-contract
mise run test-release-contract
```

Expected: failures naming the old current backlight node or rule.

- [ ] **Step 3: Rename the overlay node, symbols, rule, and current lifecycle constants**

The emitted rule must be exactly:

```text
SUBSYSTEM=="backlight", KERNEL=="hyperpixel2r-backlight", RUN+="/usr/bin/chgrp video /sys%p/brightness", RUN+="/usr/bin/chmod 0660 /sys%p/brightness"
```

- [ ] **Step 4: Run focused contracts**

Run the three commands from Step 2 plus:

```bash
HP2R_FIXTURE_CASE=backlight-permission-restore mise run test-boot-scripts
HP2R_FIXTURE_CASE=schema-two-candidate-upgrade mise run test-boot-scripts
```

Expected: all pass.

- [ ] **Step 5: Commit with GitButler**

Commit message: `refactor: make backlight identity generic`.

### Task 2: Plane Radar consumes the generic driver

**Files:**
- Modify: `/Users/shayne/code/RPi-Plane-Radar/src/backlight.rs`
- Modify: `/Users/shayne/code/RPi-Plane-Radar/crates/planeradarctl/src/driver.rs`
- Modify: `/Users/shayne/code/RPi-Plane-Radar/crates/planeradarctl/src/system_install.rs`
- Modify: matching tests under `/Users/shayne/code/RPi-Plane-Radar/tests/` and `/Users/shayne/code/RPi-Plane-Radar/crates/planeradarctl/tests/`

**Interfaces:**
- Consumes: `/sys/class/backlight/hyperpixel2r-backlight` and `70-hyperpixel2r-backlight.rules`.
- Produces: unchanged brightness, night schedule, red-mode, doctor, and installation behavior.

- [ ] **Step 1: Change focused tests to the generic identity and confirm RED**

Run the exact affected Rust tests by name with `cargo nextest run` filters.

- [ ] **Step 2: Update the product constants and install contract**

Do not add fallback probing for the old current name; the driver transition owns migration.

- [ ] **Step 3: Run the focused Rust tests and `cargo fmt --check`**

Expected: all pass.

- [ ] **Step 4: Commit to the existing Plane Radar feature stack with GitButler**

Commit message: `fix: consume generic HyperPixel backlight`.

### Task 3: Run the expensive lifecycle validation once

**Files:**
- Modify: `scripts/accepted-lifecycle.sh`
- Modify: `scripts/stage-tryboot.sh`
- Modify: `scripts/commit-boot.sh`
- Modify: `scripts/rollback-boot.sh`
- Modify: `scripts/uninstall.sh`
- Modify: `scripts/lifecycle-remote.sh`
- Modify: `tests/boot-fixtures.sh`
- Modify: `tests/transport-ancestor.sh`

**Interfaces:**
- Produces: one root-owned, checksum-verified remote lifecycle script per controller operation.
- Preserves: the same action argv and durable state schemas.

- [ ] **Step 1: Add a fixture proving the root-owned transport copy and exact checksum**

The fixture must reject a changed staged script and prove only the verified root copy executes.

- [ ] **Step 2: Make controllers install one root-owned remote script and execute it as root**

Inside `lifecycle-remote.sh`, use direct commands when `EUID == 0`; retain fixture support without spawning one fake `sudo` process for every assertion.

- [ ] **Step 3: Run transport, schema-two upgrade, and accepted-action fixtures**

```bash
mise run test-protocol
HP2R_FIXTURE_CASE=schema-two-candidate-upgrade mise run test-boot-scripts
HP2R_FIXTURE_CASE=accepted-action-argv mise run test-boot-scripts
```

- [ ] **Step 4: Measure one complete fixture run**

Run `time mise run test-boot-scripts` once. The local target is under 20 minutes. If it exceeds 30 minutes, stop and profile the slowest named section before pushing.

- [ ] **Step 5: Commit with GitButler**

Commit message: `perf: batch remote lifecycle validation`.

### Task 4: One CI verification artifact

**Files:**
- Modify: `.github/workflows/ci.yml`
- Modify: `mise.toml`
- Modify: `scripts/package-release.sh`
- Modify: `tests/release-contract.sh`

**Interfaces:**
- Produces: `hyperpixel2r-kms-release-<40-char-commit>` containing the complete source release bundle and a CI record.
- Requires: all verification jobs for that exact SHA are green before packaging.

- [ ] **Step 1: Add release-contract fixtures for commit-keyed artifact identity**

Reject shortened SHAs, mismatched manifest commits, missing checksums, and an incomplete verification record.

- [ ] **Step 2: Separate fast verification and lifecycle verification jobs**

Run the five fast tasks in one job and the lifecycle suite in one independent job. Package only after both succeed. Do not rerun either task in packaging.

- [ ] **Step 3: Package reproducibly once and upload the verified bundle**

The packaging job performs the existing two-build byte comparison, metadata validation, checksums, attestations, and `upload-artifact` with a bounded retention period.

- [ ] **Step 4: Validate workflow syntax and release contracts locally**

Run `mise run test-release-contract` and parse workflow YAML with the repository's existing validator.

- [ ] **Step 5: Commit with GitButler**

Commit message: `ci: produce one verified release artifact`.

### Task 5: Metadata-only RC and stable publication

**Files:**
- Modify: `.github/workflows/release.yml`
- Replace: `.github/workflows/stable-draft.yml`
- Modify: `.github/workflows/stable-promote.yml`
- Modify: `scripts/stable_release.py`
- Modify: `scripts/validate-release-tag.sh`
- Modify: `scripts/validate-stable-release-tag.sh`
- Create: `scripts/prepare-release.sh`
- Modify: `release/current-release.txt`
- Modify: `README.md`
- Modify: `tests/release-contract.sh`

**Interfaces:**
- RC consumes: exact successful CI artifact for the selected commit.
- Stable consumes: exact accepted RC release ID, tag, commit, and asset fingerprint.
- Produces: byte-identical RC and stable asset inventories.

- [ ] **Step 1: Add hostile release simulations**

Cover wrong CI SHA, failed CI, modified download, RC/stable fingerprint mismatch, and partial release-marker updates.

- [ ] **Step 2: Add the single release preparation command**

`scripts/prepare-release.sh v0.2.0-rc.2` atomically updates
`release/current-release.txt` and README candidate references, then invokes the existing validators.

- [ ] **Step 3: Make RC publication download and verify the CI artifact**

Remove Docker build, `mise run verify`, and release package rebuilds from `release.yml`.

- [ ] **Step 4: Make stable promotion copy exact accepted RC assets**

Remove the independent stable build. Verify the accepted RC fingerprint before creating `v0.2.0` and publishing the stable release.

- [ ] **Step 5: Run focused release contracts**

Run `mise run test-release-contract`.

- [ ] **Step 6: Commit with GitButler**

Commit message: `ci: reuse verified assets for releases`.

### Task 6: Land once and let CI verify once

**Files:**
- No new files.

**Interfaces:**
- Consumes: Tasks 1, 3, 4, and 5 on one ordered driver stack.
- Produces: one exact pushed driver commit and one complete CI run.

- [ ] **Step 1: Run only final fast local checks**

Run `git diff --check`, shell syntax checks, focused contracts changed since their last green run, and signature verification for every stack commit. Do not rerun the complete lifecycle suite if Task 3's complete run is still current.

- [ ] **Step 2: Land with GitButler and verify `origin/main`**

- [ ] **Step 3: Watch the single Verify driver workflow**

Require all jobs green and record its artifact identity and wall-clock duration.

### Task 7: Publish, accept, and finish both products

**Files:**
- Modify: `/Users/shayne/code/RPi-Plane-Radar/driver.lock`
- Modify: Plane Radar release notes/version files selected by its existing release workflow.

**Interfaces:**
- Produces: published driver `v0.2.0-rc.2` and `v0.2.0`, published Plane Radar release, and a Pi running the exact stable application and driver.

- [ ] **Step 1: Publish driver RC from the successful CI artifact**

Verify the tag, commit, assets, checksums, attestations, and workflow conclusion independently.

- [ ] **Step 2: Run one Pi acceptance cycle**

Stage the exact RC, tryboot once, verify exact driver/DRM/touch/renderer/service/brightness/power facts, capture and inspect a 480x480 frame, promote normal boot, reboot once, and finalize the accepted receipt.

- [ ] **Step 3: Promote stable driver from the exact accepted RC bytes**

Verify stable asset fingerprints equal the RC fingerprints.

- [ ] **Step 4: Update Plane Radar to the stable driver and land its feature stack**

Run focused product tests locally. Land with GitButler, then let its CI run the complete suite once.

- [ ] **Step 5: Publish and deploy Plane Radar**

Use the existing RC/stable workflow, install the published stable version on the Pi, reboot, and verify settings persistence, 80% day brightness, scheduled 20% night brightness, red-only rendering, full-color restoration, service health, watchdog ownership, and `throttled=0x0`.

- [ ] **Step 6: Report exact truth**

Separate local cleanliness, signed commits, `origin/main`, workflow conclusions, published releases, and deployed identities.
