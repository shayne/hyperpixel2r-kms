# Inactive-Kernel Tryboot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Safely stage, tryboot, promote, normalize, recover, and accept an exact HyperPixel driver for an installed inactive Raspberry Pi kernel while the currently accepted kernel remains the automatic fallback.

**Architecture:** Plane Radar records separate fresh running-kernel facts and an explicit candidate-kernel identity. The driver controller validates a private target export for that candidate, then schema-6 accepted authority snapshots the prior conventional boot pair and exact candidate package pair before any mutation. One-shot tryboot and the first normal boot select deterministic candidate-only files; only while that explicit pair remains selected does the lifecycle replace the inactive conventional pair, restore `auto_initramfs=1`, verify a second normal boot, and publish accepted-receipt schema 4. Every phase is journaled, retryable, and recoverable without ever selecting a mixed kernel/initramfs pair.

**Tech Stack:** Bash 5, Raspberry Pi `config.txt`/tryboot firmware semantics, root-owned boot and lifecycle files, SHA-256 provenance, DKMS, Rust 2024, serde, existing Plane Radar lifecycle/transport abstractions, executable filesystem fixtures, GitButler virtual branches, mise.

## Global Constraints

- Implement driver work in `/Users/shayne/code/hyperpixel2r-kms` on GitButler branch `codex/brightness-night-mode-driver`, starting from `87a02262a7eceb1027dc363a9911a34cf0279685`.
- Implement product work in `/Users/shayne/code/RPi-Plane-Radar` on GitButler branch `codex/brightness-night-mode`, starting from `6c0d60ad0168e7e7c61b88db6da247bed35e4ad0`.
- Do not create worktrees. Preserve unrelated GitButler branches and commit only the paths named by each task.
- Use TDD. Every production behavior begins with a focused executable test that fails for the expected missing behavior.
- Keep same-kernel preparation, staging, verification, commit, retained-driver, uninstall, and schema-1 through schema-5 recovery behavior compatible.
- Accepted-transition schema 6 is valid only for a new, different-kernel candidate. Retained candidates remain schema 4.
- Existing public driver release manifest schema 2 and public release archives remain unchanged. Kernel and initramfs bytes are private target state and must never enter a release package.
- Do not add the private target hostname, username, serial, host key, IP address, package paths containing private data, or captured target output to tracked files, tests, commits, or diagnostics.
- Firmware basenames are derived independently by controller and target. Callers never supply a firmware pathname.
- All boot-file reads and mutations require link-first type checks, exact ownership/mode checks, snapshots, digest revalidation, same-filesystem atomic publication, filesystem sync, and post-publication verification.
- Keep the hardware watchdog enabled. Never load, probe, or bind the candidate module while the accepted kernel is running.
- Stop Plane Radar during boot-config promotion, conventional-pair normalization, and recovery mutation. Do not disable or mask its unit.
- Do not push, tag, release, publish, or cut a public package as part of this plan.
- Do not access or reboot the physical target until Task 10. All earlier tasks use local tests and fixture roots.

---

### Task 1: Version and retain exact inactive-kernel target-export provenance

**Driver files:**
- Modify: `scripts/common.sh`
- Modify: `scripts/export-target-kbuild.sh`
- Modify: `scripts/build-driver.sh`
- Modify: `scripts/check-artifacts.sh`
- Modify: `tests/build-contract.sh`
- Modify: `tests/boot-scripts.sh`

**Interfaces:**
- Preserve the current unversioned 13-row target manifest as readable legacy same-kernel input.
- Add private target-manifest schema 2 with these exact rows: `schema_version`, `target_identity_sha256`, the existing 13 rows, `kernel_image_path`, `kernel_image_sha256`, `initramfs_path`, `initramfs_sha256`, `vc4_overlay_path`, and `vc4_overlay_sha256`.
- Add `export-target-kbuild.sh --kernel-release RELEASE --target-identity-sha256 SHA256`. An explicit non-running release requires both arguments; the existing no-release invocation remains a running-kernel export.
- Candidate package sources are fixed to `/boot/vmlinuz-$release` and `/boot/initrd.img-$release`; the supported shared overlay is `/boot/firmware/overlays/vc4-kms-v3d.dtbo`.

- [ ] **Step 1: Add schema-2 target-manifest RED fixtures**

In `tests/build-contract.sh`, add a valid schema-2 target manifest and table-driven mutations for duplicate, missing, unknown, malformed identity digest, mismatched release path, symlink source, wrong owner, wrong architecture, kernel hash drift, initramfs hash drift, base-DTB hash drift, and VC4-overlay hash drift. Exercise `hp2r_validate_target_manifest` and a new `hp2r_validate_inactive_target_manifest` contract.

Run:

```bash
mise run test-build-contract
```

Expected RED: `scripts/common.sh` rejects the schema-2 manifest because only the legacy 13-row shape is recognized.

- [ ] **Step 2: Implement explicit legacy and schema-2 validators**

In `scripts/common.sh`, split the current validator into these exact contracts:

```bash
hp2r_validate_legacy_target_manifest()   # current 13-row contract
hp2r_validate_target_manifest()          # dispatches legacy or schema 2
hp2r_validate_inactive_target_manifest() # requires schema 2 and all private boot provenance
```

Require lowercase 64-character SHA-256 values, exact fixed filenames, a release-safe suffix, `kernel_arch=aarch64`, and an exact release match in both versioned source paths. Do not follow a local symlink when validating exported regular files.

Run the focused contract again. Expected GREEN for both legacy compatibility and schema-2 parser cases.

- [ ] **Step 3: Add inactive-release export RED coverage**

Extend the shell-command fixture in `tests/build-contract.sh` so a fake target reports running release `6.18.34+rpt-rpi-v8` while an explicit export requests `6.18.39+rpt-rpi-v8`. Assert the remote probe uses the requested release for headers, module metadata, versioned kernel, and versioned initramfs; hashes the active board DTB and shared VC4 overlay; and never substitutes `uname -r` for the requested release.

Run:

```bash
bash tests/build-contract.sh
```

Expected RED: `export-target-kbuild.sh` exits 64 because `--kernel-release` and `--target-identity-sha256` are unknown.

- [ ] **Step 4: Export the candidate without booting it**

Implement the new flags in `scripts/export-target-kbuild.sh`. Pass the validated requested release as a positional value to the fixed remote program. On target, require:

```text
/lib/modules/$release/build/include/config/kernel.release == $release
modinfo -k $release -F vermagic vc4 begins with "$release "
/boot/vmlinuz-$release is root:root regular non-symlink
/boot/initrd.img-$release is root:root regular non-symlink
/boot/firmware/bcm2710-rpi-zero-2-w.dtb is root:root regular non-symlink
/boot/firmware/overlays/vc4-kms-v3d.dtbo is root:root regular non-symlink
```

Snapshot metadata, tar the existing build inputs, and write schema 2 only after all remote and local digests revalidate. Never copy kernel or initramfs bytes into a public artifact directory.

- [ ] **Step 5: Require schema 2 only for cross-kernel build and check paths**

Update `build-driver.sh` and `check-artifacts.sh` so an explicitly selected non-running release requires `hp2r_validate_inactive_target_manifest`, while current same-kernel and already-retained legacy exports remain readable. Continue binding artifact `base_dtb_sha256` and module vermagic to the selected release. Add exact tests proving a candidate build cannot consume a target export for another identity or release.

- [ ] **Step 6: Refresh the executable boot fixture target manifest**

Update `tests/boot-scripts.sh` to emit schema-2 target provenance plus synthetic fixed boot sources for the later inactive-kernel fixture. Keep public artifact manifest schema 2 unchanged.

Run:

```bash
mise run test-build-contract
HP2R_FIXTURE_CASE=smoke mise run test-boot-scripts
```

Expected: both pass and no existing same-kernel fixture changes behavior.

- [ ] **Step 7: Commit Task 1**

```bash
git diff --check
but commit codex/brightness-night-mode-driver -m 'feat: retain inactive kernel boot provenance'
```

---

### Task 2: Separate running and candidate kernel identity in Plane Radar

**Product files:**
- Modify: `crates/planeradarctl/src/target.rs`
- Modify: `crates/planeradarctl/src/preflight.rs`
- Modify: `crates/planeradarctl/src/driver.rs`
- Modify: `crates/planeradarctl/tests/preflight.rs`
- Modify: `crates/planeradarctl/tests/driver.rs`
- Modify: `tests/ctl_end_to_end.rs`

**Interfaces:**
- Add `TargetIdentity::driver_binding_sha256()`, hashing the length-delimited host-key fingerprint, exact model, and exact serial without exposing those values in `Debug` or errors.
- Add `candidate_kernel_release`, `candidate_kernel_vermagic`, and `candidate_kernel_match_count` to `TargetFacts`.
- The package-selected candidate is the one release for which `/boot/vmlinuz` and `/boot/initrd.img` resolve to matching versioned root-owned package leaves and `/lib/modules/$release/build` plus `modinfo -k $release vc4` agree. When the package-selected release is absent, candidate defaults to the running release. Ambiguity is blocking.
- Refactor `DriverContext.kernel_release` into `running_kernel_release` and `candidate_kernel_release`, plus `target_identity_sha256`.

- [ ] **Step 1: Add target-identity binding RED tests**

In `crates/planeradarctl/tests/driver.rs`, prove equal target identities produce the same lowercase SHA-256, every field changes the digest, and formatted errors/debug output contain no host key, serial, target, or digest input.

Run:

```bash
cargo test --locked -p planeradarctl --test driver target_identity
```

Expected RED: `TargetIdentity` has no driver binding method.

- [ ] **Step 2: Add candidate-fact RED tests**

Extend the canonical JSON fixture in `crates/planeradarctl/tests/preflight.rs` and `tests/ctl_end_to_end.rs`. Cover running fallback, one different package-selected candidate, mismatched kernel/initramfs selectors, candidate vermagic mismatch, duplicate candidate count, unsafe release text, and a post-reboot fact set where running and candidate are both the promoted release.

Run:

```bash
cargo test --locked -p planeradarctl --test preflight
```

Expected RED: serde rejects the new fields and `TARGET_FACTS_SCRIPT` does not emit them.

- [ ] **Step 3: Implement canonical candidate discovery**

Update `TARGET_FACTS_SCRIPT` using fixed shell code and bounded scalar output. Resolve only `/boot/vmlinuz` and `/boot/initrd.img`, require both resolved paths to be exact versioned package leaves for one release, and validate that release's headers and VC4 vermagic. Do not enumerate a newest-looking filename or compare releases lexically.

Update `TargetFacts::validate`, its redacted `Debug` field count, and preflight checks so a safe different candidate is allowed for the accepted inactive-kernel path rather than causing an immediate bare normal reboot. Existing unsupported header/boot-selection cases remain blocking.

- [ ] **Step 4: Refactor driver resolution around candidate identity**

Change the constructor boundary to:

```rust
pub struct DriverContext {
    pub target: String,
    pub running_kernel_release: String,
    pub candidate_kernel_release: String,
    pub target_identity_sha256: String,
    pub kernel_export: PathBuf,
    pub artifacts: PathBuf,
    pub replace_overlay: String,
}
```

`SyncedDriver::tool` resolves prebuilts and cross-builds from a `TargetProbe` for the candidate, while retaining the fresh running release separately for accepted-stage safety. Reject a different candidate when its vermagic or exact export is absent. Preserve current resolver precedence for same-release contexts.

- [ ] **Step 5: Prove exact tool argv and no silent fallback**

Update driver tests to require candidate release on export/build/stage argv, running release only in the context safety boundary, and identity digest on inactive commands. Add a case where only a running-release artifact exists while a different candidate is requested; require `InvalidContext` or `InvalidPrebuiltIdentity`, never a running-release fallback.

Run:

```bash
cargo test --locked -p planeradarctl --test driver
cargo test --locked -p planeradarctl --test preflight
cargo test --locked --test ctl_end_to_end
```

- [ ] **Step 6: Commit Task 2**

```bash
git diff --check
but commit codex/brightness-night-mode -m 'refactor: separate candidate kernel identity'
```

---

### Task 3: Carry accepted cross-kernel authority through typed controller commands

**Driver files:**
- Modify: `scripts/accepted-lifecycle.sh`
- Modify: `scripts/stage-tryboot.sh`
- Modify: `scripts/commit-boot.sh`
- Modify: `scripts/verify-boot.sh`
- Modify: `tests/build-contract.sh`
- Modify: `tests/boot-scripts.sh`

**Product files:**
- Modify: `crates/planeradarctl/src/driver.rs`
- Modify: `crates/planeradarctl/tests/driver.rs`

**Interfaces:**
- `accepted-lifecycle.sh prepare-new` receives `--kernel-target DIR` and `--target-identity-sha256 SHA256`, validates the exact candidate schema-2 target manifest locally, and passes only fixed typed provenance values to `lifecycle-remote.sh`.
- `stage-tryboot.sh --kernel-release RELEASE --target-identity-sha256 SHA256` is allowed for a different release only after a target-side schema-6 authorization probe matches it. A bare generic override fails before artifact payload upload.
- `verify-boot.sh --expect-kernel-release RELEASE` verifies the caller's expected candidate instead of accepting whichever release `uname -r` returned.

- [ ] **Step 1: Add argv and authorization RED tests in both repositories**

Require exact separate argv pairs for candidate release, target-export parent, and target identity. Reject omitted identity, unsafe digest, candidate/manifest mismatch, same-kernel-only calls with cross-kernel flags, and an inactive stage without matching schema-6 authority.

Run:

```bash
mise run test-build-contract
cargo test --locked -p planeradarctl --test driver accepted_driver_protocol
```

Expected RED: the shell controllers and Rust adapter do not expose the new typed arguments.

- [ ] **Step 2: Extend accepted prepare without caller-controlled boot paths**

In `accepted-lifecycle.sh`, resolve `target.txt` under the validated candidate-release directory, require schema 2, verify its target binding, and pass this exact additional positional tuple to `prepare-new-accepted`:

```text
candidate kernel image SHA-256
candidate initramfs SHA-256
candidate base DTB SHA-256
candidate VC4 overlay SHA-256
```

The target half derives `/boot/vmlinuz-$release`, `/boot/initrd.img-$release`, the board DTB, and VC4 overlay path independently. Do not pass paths from the caller.

- [ ] **Step 3: Gate generic inactive stage before artifact upload**

Add a read-only remote `authorize-inactive-stage` action that validates schema 6 and prints one fixed tab-separated tuple containing candidate release, deterministic candidate filenames, candidate digests, and accepted-transition SHA-256. `stage-tryboot.sh` must obtain and compare this tuple before creating or uploading the artifact payload. Same-kernel stage remains unchanged.

- [ ] **Step 4: Make verification release-explicit**

Add `--expect-kernel-release` to `verify-boot.sh`; require the fresh remote `uname -r` to equal it and pass the same value into the remote verifier. Update `commit-boot.sh` identity parsing so a schema-5 generic transaction includes the expected kernel release and commit verifies that exact tryboot kernel before publication.

- [ ] **Step 5: Update the Rust typed adapter**

Pass `--kernel-release`, `--target-identity-sha256`, and `--kernel-target` only for the inactive accepted path. `DriverVerification::validate` continues to compare exact candidate release and version. Same-kernel test snapshots must remain byte-for-byte unchanged except where a newly mandatory explicit verification argument is intended.

Run:

```bash
mise run test-build-contract
mise run test-boot-scripts
cargo test --locked -p planeradarctl --test driver
```

- [ ] **Step 6: Commit both repository slices**

```bash
git diff --check
but commit codex/brightness-night-mode-driver -m 'feat: authorize inactive kernel staging'
```

Then in `/Users/shayne/code/RPi-Plane-Radar`:

```bash
git diff --check
but commit codex/brightness-night-mode -m 'feat: carry candidate driver authority'
```

---

### Task 4: Prepare schema-6 authority and exact boot-pair companions

**Driver files:**
- Modify: `scripts/lifecycle-remote.sh`
- Modify: `tests/boot-fixtures.sh`
- Modify only if required by an existing inventory assertion: `tests/boot-scripts.sh`

**Interfaces:**
- Add four fixed companions under `/var/lib/hyperpixel2r-kms`: `accepted-transition-prior-kernel.img`, `accepted-transition-prior-initramfs.img`, `accepted-transition-candidate-kernel.img`, and `accepted-transition-candidate-initramfs.img`.
- Add accepted-transition schema 6 using exactly the schema-5 rows plus the approved inactive-kernel rows and phases.
- Deterministic firmware names are `hp2r-$revision12-$release_tag12-kernel.img` and `hp2r-$revision12-$release_tag12-initramfs.img`, where `release_tag12` is the first 12 lowercase hex characters of SHA-256 over `printf %s "$release"`.

- [ ] **Step 1: Build a focused inactive-kernel fixture and capture the current RED**

Add `HP2R_FIXTURE_CASE=inactive-kernel` with accepted running release `6.18.34+rpt-rpi-v8` and package-selected candidate `6.18.39+rpt-rpi-v8`. Use distinct deterministic bytes for prior/candidate kernels and initramfs files, plus exact base-DTB and VC4-overlay files. Prepare through the public controller and assert schema 6, four root:root mode-0600 companions, exact digests, deterministic names, unchanged normal config, unchanged conventional pair, and no generic tryboot state.

Run:

```bash
HP2R_FIXTURE_CASE=inactive-kernel mise run test-boot-scripts
```

Expected RED: `prepare-new-accepted` either rejects the extra provenance tuple or emits schema 5 without boot-pair authority.

- [ ] **Step 2: Add exact schema, filename, and config-shape helpers**

In `scripts/lifecycle-remote.sh`, add:

```bash
release_tag12()                       # hashes exact release bytes, no newline
inactive_candidate_boot_names()       # prints two deterministic basenames
assert_supported_inactive_config()    # validates active directive cardinality and sections
derive_inactive_tryboot_config()      # creates explicit one-shot candidate config
derive_explicit_normal_config()       # same explicit pair selected as normal
derive_normalized_normal_config()     # auto_initramfs=1 and candidate overlay
assert_no_boot_writers()              # package/initramfs/kernel-hook/DKMS/lifecycle/selector locks
assert_transition_space()             # private and firmware filesystems plus safety margin
assert_inactive_companions()           # exact type, owner, mode, digest, and pair binding
```

Supported config validation requires exactly the directives and section rules in the approved design. Length-check every generated line at 98 characters. Reject active `include`, `autoboot.txt`, kernel/initramfs/ramfs/os/overlay-prefix overrides, duplicate or conditional display selectors, and a shared VC4 overlay other than the exact retained digest.

- [ ] **Step 3: Extend `publish_accepted_transition` for schema 6**

For a different release, write these exact additional rows:

```text
boot_transition=inactive-kernel
prior_normal_kernel_sha256
prior_normal_initramfs_sha256
candidate_kernel_file
candidate_kernel_sha256
candidate_initramfs_file
candidate_initramfs_sha256
candidate_base_dtb_sha256
candidate_vc4_overlay_sha256
explicit_normal_config_sha256=pending
normalized_normal_config_sha256=pending
```

Publish the prior config/tryboot proof and all four boot companions before publishing the complete journal last. Same-release preparation continues to emit schema 5 and creates none of these companions.

- [ ] **Step 4: Implement fail-closed inactive prepare**

Before snapshotting, prove accepted receipt/artifact/module/config/conventional pair, running release equals accepted release, candidate differs, candidate `/lib/modules` and package sources exist, base DTB and VC4 hashes agree with target export, no writer is active, and both filesystems have enough free space. Snapshot all sources into a private workspace, revalidate live sources, derive explicit and normalized configs privately, then publish companions and journal.

- [ ] **Step 5: Add interruption and hostile-input matrices**

Interrupt after each companion publication and before journal publication. Recovery without a journal may remove an orphan only after proving its exact relationship to unchanged live accepted state. For each source, companion, destination, and config input, cover absent, symlink, directory, FIFO, owner/mode drift, hash drift, source replacement during capture, insufficient space, active writer, overlong generated line, duplicate directive, and conditional ambiguity. Unsafe data remains intact and recovery fails closed.

Run:

```bash
HP2R_FIXTURE_CASE=inactive-kernel mise run test-boot-scripts
bash -n scripts/lifecycle-remote.sh
```

- [ ] **Step 6: Commit Task 4**

```bash
git diff --check
but commit codex/brightness-night-mode-driver -m 'feat: prepare inactive kernel authority'
```

---

### Task 5: Stage the complete one-shot candidate without loading it

**Driver files:**
- Modify: `scripts/lifecycle-remote.sh`
- Modify: `tests/boot-fixtures.sh`

**Interfaces:**
- Add generic tryboot-state schema 5, extending schema 4 with `boot_transition`, candidate kernel/initramfs files and hashes, prior conventional-pair hashes, and `accepted_transition_sha256`.
- Schema-5 stage publishes candidate firmware leaves, candidate module/overlay/rule/DKMS state, explicit tryboot config, and state; it never changes normal config or the conventional pair.

- [ ] **Step 1: Add cross-kernel stage RED assertions**

Extend `exercise_inactive_kernel` to stage while fixture `uname` still reports `6.18.34+rpt-rpi-v8`. Assert exact candidate firmware leaves, module under `/lib/modules/6.18.39+rpt-rpi-v8/extra`, overlay, rule, DKMS inventory, `depmod -a` release, `modinfo -k` release/path/vermagic, schema-5 state, three exact appended tryboot lines, and unchanged normal config/conventional pair. Record every fixture `modprobe`, module-load, bind, and `uname` use; assert no candidate load/probe occurred.

Expected RED: current stage either binds to the running release or emits schema 4 without boot leaves.

- [ ] **Step 2: Extend state parsing and full-transaction validation**

Add `state_keys_v5`, accept it only when matching schema-6 authority exists, and validate the accepted-transition digest before the first mutation and before every phase advancement. Derive firmware basenames independently and compare them to both journals. Existing schemas 1-4 retain their current meaning.

- [ ] **Step 3: Publish candidate firmware leaves from private companions**

Use `copy_if_absent_or_exact` plus boot ownership/mode checks. Exact existing leaves are reusable only when the same schema-6 journal binds them; foreign or mismatched leaves fail without removal. Add interruption points after kernel leaf, initramfs leaf, and each later installed artifact.

- [ ] **Step 4: Install candidate driver state without loading it**

Reuse existing inventory-bound module, overlay, rule, source materialization, DKMS registration, `depmod`, and `modinfo` machinery with the explicit candidate release. Add a hard branch preventing any `modprobe`, sysfs bind, or current-kernel module-resolution helper on a cross-kernel stage.

- [ ] **Step 5: Publish explicit tryboot and advance accepted authority**

The derived tryboot tail must be exactly:

```text
# hyperpixel2r-kms one-shot inactive-kernel candidate
kernel=$candidate_kernel_file
initramfs $candidate_initramfs_file followkernel
dtoverlay=$candidate_overlay_file
```

The dollar-prefixed names above are shell variables written by the implementation; literal dollar signs are not written to `tryboot.txt`. Publish schema-5 generic state last, then move accepted phase `prepared` to `staged` only after every bound leaf revalidates.

- [ ] **Step 6: Prove failed tryboot fallback and exact rollback**

Model a failed tryboot by keeping fixture running release and normal selection at the prior pair. Run supported rollback/recovery and assert byte-exact prior config, conventional pair, tryboot file/absence, module, overlay, rule, DKMS inventory, accepted receipt, and removal of only journal-owned candidate leaves.

Run:

```bash
HP2R_FIXTURE_CASE=inactive-kernel mise run test-boot-scripts
```

- [ ] **Step 7: Commit Task 5**

```bash
git diff --check
but commit codex/brightness-night-mode-driver -m 'feat: stage coherent inactive kernel tryboot'
```

---

### Task 6: Promote through an explicit pair and normalize the inactive conventional pair

**Driver files:**
- Modify: `scripts/lifecycle-remote.sh`
- Modify: `scripts/accepted-lifecycle.sh`
- Modify: `scripts/commit-boot.sh`
- Modify: `scripts/verify-boot.sh`
- Modify: `tests/boot-fixtures.sh`
- Modify: `tests/boot-scripts.sh`

**Interfaces:**
- Schema-6 phases are `prepared`, `staged`, `explicit_normal_published`, `explicit_normal_verified`, `canonical_initramfs_published`, `canonical_pair_published`, `normalized_config_published`, `normalized_verified`, `finalizing`, and `receipt_published`.
- Add accepted actions `mark-explicit-normal-verified`, `normalize-inactive-kernel`, and `mark-normalized-verified`.
- Same-kernel `mark-committed`/`mark-verified` behavior remains unchanged.

- [ ] **Step 1: Add explicit-normal promotion RED fixture**

After simulating a healthy candidate tryboot, run `commit-boot.sh`. Assert normal config atomically selects the candidate-only kernel/initramfs/overlay, conventional files remain exact prior bytes, prior tryboot is restored, generic state is retired, candidate leaves remain, and accepted phase is `explicit_normal_published`.

Expected RED: current commit generates an overlay-only normal config and cannot preserve a complete cross-kernel selection.

- [ ] **Step 2: Add a schema-5 branch to generic commit**

For a schema-5 generic state, publish the precomputed explicit normal config rather than deriving the same-kernel overlay-only form. Revalidate transition digest, candidate firmware pair, normal prior pair, and service quiescence. Advance schema 6 to `explicit_normal_published` before retiring generic state. Every interruption must leave either the exact prior conventional selection or the exact candidate-specific selection.

- [ ] **Step 3: Verify the first normal candidate boot**

Simulate a normal reboot into the explicit pair, set fresh running facts to the candidate release, and verify module path/digest/vermagic, overlay, KMS, touch, backlight, service, unchanged conventional prior pair, lifecycle authority, watchdog, power, storage, and absence of a bind storm. `mark-explicit-normal-verified` advances only from `explicit_normal_published`.

- [ ] **Step 4: Add normalization RED fixtures at every publication boundary**

Run `normalize-inactive-kernel` and interrupt after candidate initramfs becomes conventional, after candidate kernel becomes conventional, and after normalized config publication. In all three states, assert the active explicit config still selects the complete candidate-only pair until both conventional files verify.

Expected RED: no accepted action or durable phases exist for conventional-pair normalization.

- [ ] **Step 5: Implement resumable inactive normalization**

From `explicit_normal_verified`, stop on any drift, then:

1. Atomically copy the candidate initramfs companion to `initramfs8`, sync, verify, and advance to `canonical_initramfs_published`.
2. Atomically copy the candidate kernel companion to `kernel8.img`, sync, verify both, and advance to `canonical_pair_published`.
3. Atomically publish the precomputed normalized config, verify `auto_initramfs=1`, no explicit boot override, and exact candidate overlay, then advance to `normalized_config_published`.

Retrying the action resumes from any of those exact phases.

- [ ] **Step 6: Verify the normalized normal boot**

Simulate the second normal reboot. Require fresh candidate runtime health plus exact conventional kernel/initramfs digests and normalized config selection. Advance only `normalized_config_published` to `normalized_verified`.

Run:

```bash
HP2R_FIXTURE_CASE=inactive-kernel mise run test-boot-scripts
```

- [ ] **Step 7: Commit Task 6**

```bash
git diff --check
but commit codex/brightness-night-mode-driver -m 'feat: normalize accepted kernel boot pair'
```

---

### Task 7: Finalize schema-4 receipt and recover every cross-kernel phase

**Driver files:**
- Modify: `scripts/lifecycle-remote.sh`
- Modify: `tests/boot-fixtures.sh`
- Modify: `tests/boot-scripts.sh`

**Interfaces:**
- Accepted-receipt schema 4 extends schema 3 with `normal_kernel_file=kernel8.img`, `normal_kernel_sha256`, `normal_initramfs_file=initramfs8`, `normal_initramfs_sha256`, `base_dtb_sha256`, and `vc4_overlay_sha256`.
- Finalization removes candidate-only firmware leaves and boot companions only after the conventional pair and receipt bind the same candidate.
- Recovery is phase-aware and never infers authority from ambient filenames.

- [ ] **Step 1: Add schema-4 finalization RED assertions**

From `normalized_verified`, finalize and require the exact 22-row schema-4 receipt, candidate accepted artifact, conventional boot hashes, target shared-file hashes, restored prior tryboot authority, removal of prior accepted artifact as currently authorized, removal of deterministic candidate-only leaves, removal of all six transition companions, and journal removal last.

Expected RED: finalization emits schema 3 and has no boot-pair cleanup authority.

- [ ] **Step 2: Extend accepted receipt parsing and publication**

Add `accepted_keys_v4` and strict validation. Same-kernel finalization may continue writing schema 3. Cross-kernel finalization writes schema 4 only after exact normalized runtime and boot identity checks. Existing receipt schemas 1-3 remain readable for record, retained, uninstall, and recovery paths.

- [ ] **Step 3: Implement phase-aware prior restoration**

Extend `restore_prior_from_accepted_transition` and `recover_accepted`:

- `prepared`: retire only validated unpublished/staged authority and companions.
- `staged`: use generic rollback, restore prior tryboot, and remove exact candidate firmware leaves.
- `explicit_normal_published` or `explicit_normal_verified`: restore prior normal config; conventional pair is already prior.
- `canonical_initramfs_published`, `canonical_pair_published`, or `normalized_config_published`: keep explicit candidate config active, restore both prior conventional files from companions, verify them, then restore prior config.
- `normalized_verified` or `finalizing`: restore prior until candidate receipt is durably published.
- `receipt_published`: complete candidate finalization; never resurrect the prior receipt.

Recovery that changes normal selection must report reboot required through a fixed exit/result contract consumed by Plane Radar.

- [ ] **Step 4: Add exhaustive interruption replay**

Interrupt after every companion, journal, firmware leaf, module, overlay, rule, DKMS, tryboot, state, phase, explicit config, conventional initramfs, conventional kernel, normalized config, receipt, artifact retirement, candidate-leaf cleanup, companion cleanup, and journal cleanup publication. For each interruption, run recovery twice and forward finalization twice; prove idempotence and byte-exact endpoint state.

- [ ] **Step 5: Harden uninstall and ambient-file behavior**

Block uninstall when any new companion or candidate firmware leaf is a symlink or exists without validated lifecycle authority. Never delete an unrelated `hp2r-*` file. Exact existing leaves may be reconciled only when the current journal names and hashes them.

Run:

```bash
HP2R_FIXTURE_CASE=inactive-kernel mise run test-boot-scripts
mise run test-boot-scripts
```

- [ ] **Step 6: Commit Task 7**

```bash
git diff --check
but commit codex/brightness-night-mode-driver -m 'feat: recover inactive kernel transitions'
```

---

### Task 8: Orchestrate two verified normal boots and expose receipt provenance

**Product files:**
- Modify: `crates/planeradarctl/src/driver.rs`
- Modify: `crates/planeradarctl/src/main.rs`
- Modify: `crates/planeradarctl/src/operations.rs`
- Modify: `crates/planeradarctl/src/preflight.rs`
- Modify: `crates/planeradarctl/tests/driver.rs`
- Modify: `crates/planeradarctl/tests/lifecycle.rs`
- Modify: `crates/planeradarctl/tests/operations.rs`
- Modify: `crates/planeradarctl/tests/preflight.rs`
- Modify: `tests/ctl_end_to_end.rs`

**Interfaces:**
- Add typed driver actions `MarkExplicitNormalVerified`, `NormalizeInactiveKernel`, and `MarkNormalizedVerified`.
- Add product lifecycle phases `ExplicitNormalVerified`, `DriverNormalized`, and `NormalizedBootVerified` between current commit and application activation.
- Add backend methods `verify_explicit_normal_driver`, `normalize_driver`, and `verify_normalized_driver`.
- Every reconnect invalidates cached driver/protocol tools and builds a new context from a fresh identity-bound target probe.

- [ ] **Step 1: Add lifecycle ordering RED tests**

In `crates/planeradarctl/tests/lifecycle.rs` and `operations.rs`, require this exact changed-driver sequence:

```text
stage application
stage driver
tryboot reboot and reconnect
verify candidate tryboot
publish explicit normal candidate
normal reboot and reconnect
verify explicit normal candidate
normalize conventional pair
normal reboot and reconnect
verify normalized candidate
activate application
restart application
verify pair
finalize driver acceptance
```

Inject failures at every new call and assert recovery runs before application mutation continues.

Expected RED: `LifecycleBackend` has only one normal reboot and no normalization methods.

- [ ] **Step 2: Extend serialized lifecycle phases compatibly**

Add the three new enum variants in forward order before `ApplicationActivated`. Update state validation, transition ordering, recovery comparisons, test JSON, and end-to-end fixtures. Existing serialized phase names remain readable and retain their old recovery meaning.

- [ ] **Step 3: Implement the new backend methods**

`verify_explicit_normal_driver` creates a fresh candidate tool, runs exact normal verification, then invokes `mark-explicit-normal-verified`. `normalize_driver` quiesces `planeradar.service`, proves no restart churn/process writer, invokes `normalize-inactive-kernel`, and leaves the unit enabled. `verify_normalized_driver` again creates a fresh tool, verifies conventional selection and candidate runtime, invokes `mark-normalized-verified`, and checks the service restarted normally after reboot. `restore_driver` applies the same quiescence gate before invoking phase-aware accepted recovery and keeps the unit enabled for the required recovery reboot.

- [ ] **Step 4: Eliminate stale post-reboot context**

After each successful `wait_for_reboot`, clear `driver_tool` and `protocol_tool`, reacquire `TargetFacts`, recheck `TargetIdentity`, and construct a new `DriverContext`. Preserve the intended candidate release in the in-process accepted transaction; a process restart takes the existing recovery path and reads target-side journal authority rather than guessing a candidate.

- [ ] **Step 5: Parse and report accepted-receipt schema 4**

Update the fixed accepted-state probe in `crates/planeradarctl/src/operations.rs` to accept exact schema-3 and schema-4 key sets. For schema 4, verify conventional file names/digests plus active base DTB and VC4 overlay. Add optional boot provenance fields to internal doctor/status facts without changing driver version, source commit, or public manifest SHA semantics. Diagnostics remain redacted.

- [ ] **Step 6: Exercise failed tryboot and phase-aware recovery end to end**

In `tests/ctl_end_to_end.rs`, model a failed candidate boot returning automatically to the prior running release, recovery requiring no candidate normal boot, recovery after partial normalization, and a post-receipt interruption that completes candidate finalization. Assert service stop/start order and fresh probe count around every reboot.

Run:

```bash
cargo test --locked -p planeradarctl --test driver
cargo test --locked -p planeradarctl --test lifecycle
cargo test --locked -p planeradarctl --test operations
cargo test --locked -p planeradarctl --test preflight
cargo test --locked --test ctl_end_to_end
```

- [ ] **Step 7: Commit Task 8**

```bash
git diff --check
but commit codex/brightness-night-mode -m 'feat: orchestrate inactive kernel promotion'
```

---

### Task 9: Run hostile matrices, privacy checks, and full repository verification

**Driver files:**
- Modify only for failures revealed by the complete suite: files already named in Tasks 1-7

**Product files:**
- Modify only for failures revealed by the complete suite: files already named in Tasks 2, 3, and 8

- [ ] **Step 1: Run all focused hostile cases**

```bash
HP2R_FIXTURE_CASE=inactive-kernel mise run test-boot-scripts
HP2R_FIXTURE_CASE=accepted-prior-tryboot mise run test-boot-scripts
mise run test-build-contract
```

Expected: exact schema/cardinality, unsafe-type, drift, interruption, retry, same-kernel, retained, uninstall, and recovery cases pass.

- [ ] **Step 2: Run the full driver repository gate**

```bash
mise run verify
git diff --check
git status --short
```

Expected: every driver test passes; status contains only intentional Task 9 fixes before their commit.

- [ ] **Step 3: Run the full Plane Radar repository gate**

In `/Users/shayne/code/RPi-Plane-Radar`:

```bash
mise run verify
git diff --check
git status --short
```

Expected: formatting, clippy, all tests, and dependency policy pass.

- [ ] **Step 4: Scan both branches for forbidden private or public boot data**

Inspect only the branch diffs and tracked files. Require no private target identifiers and no kernel/initramfs binary leaves in release/package paths:

```bash
git diff --stat 1c64ae9...codex/brightness-night-mode-driver
git diff --check 1c64ae9...codex/brightness-night-mode-driver
```

In the product repository:

```bash
git diff --stat 437eba2...codex/brightness-night-mode
git diff --check 437eba2...codex/brightness-night-mode
```

Use a locally supplied private-pattern file for any private-value scan; never put private strings directly in shell history captured by the plan or in tracked tests.

- [ ] **Step 5: Commit any suite-only fixes separately**

If the full suite required changes, commit them in the owning repository with `test: harden inactive kernel lifecycle`. If no changes were required, make no empty commit.

- [ ] **Step 6: Record exact branch truth**

For both repositories, capture `but status`, `git status --short`, branch tip, and tree hash. Do not claim pushed, released, or published state.

---

### Task 10: Perform reversible physical acceptance on the configured test target

**Tracked files:** None unless a reproducible, target-independent bug is discovered and first covered by a local test.

**Precondition:** Tasks 1-9 are green and both GitButler branches are clean. The target address is supplied only through the existing private environment variable.

- [ ] **Step 1: Reconfirm the accepted fallback before mutation**

Using identity-bound transport and fresh probes, require accepted running kernel, exact accepted receipt/artifact/config/conventional pair, healthy KMS/touch/backlight, active Plane Radar with stable restart count, clean power evidence, working watchdog refresh, sufficient storage, and no lifecycle state or boot writer.

- [ ] **Step 2: Export, build/check, prepare, and stage the inactive candidate**

Run the supported product workflow with the explicit candidate selected from fresh facts. Before reboot, independently verify normal config and conventional pair are unchanged; candidate firmware leaves/module/overlay/rule/journals are exact; and no candidate module is loaded.

- [ ] **Step 3: Exercise failed-tryboot recovery first**

Request one-shot tryboot, allow the target to return to the accepted normal kernel, then run supported recovery. Over a stability window longer than the watchdog envelope, prove unchanged boot ID, stable service restart count, clean KMS/udev logs, exact accepted conventional pair, and complete candidate cleanup.

- [ ] **Step 4: Reprepare and verify successful candidate tryboot**

Stage again, request one-shot tryboot, and require fresh candidate release, module path/digest/vermagic, explicit tryboot selection, KMS/touch/backlight, active Plane Radar, stable restart count, clean watchdog/power/storage evidence, and no VC4/HDMI/udev bind storm.

- [ ] **Step 5: Promote, verify, normalize, and verify again**

Publish explicit normal candidate config, normal reboot, and verify. Quiesce the service, normalize initramfs then kernel then config, normal reboot, and verify the conventional candidate pair. Publish schema-4 receipt and finalize. Confirm candidate-only firmware leaves and private companions are gone while the conventional pair remains exact.

- [ ] **Step 6: Install and exercise the exact Plane Radar application candidate**

Deploy the already-built reversible application candidate through its supported installer. Verify doctor/status/smoke provenance, brightness 5/30/100 behavior, scheduled night dimming, sunrise restoration, red-mode rendering, touch, KMS, service restart, and a full normal reboot. Restore the owner's settings and any temporary test state afterward.

- [ ] **Step 7: Run final stability and recovery readiness checks**

Observe longer than the watchdog envelope. Require one unchanged boot ID, `NRestarts=0`, normal watchdog refresh, clean power evidence, no kernel/VC4/HDMI/udev storm, exact schema-4 receipt, normalized config, correct conventional pair, and no active/generic/accepted transition state.

- [ ] **Step 8: Report exact final state**

Report physical pass/fail evidence, both local branch tips/tree hashes, clean/dirty status, and explicitly state that nothing was pushed, tagged, released, or publicly published. Do not include private target identifiers in the report or commits.
