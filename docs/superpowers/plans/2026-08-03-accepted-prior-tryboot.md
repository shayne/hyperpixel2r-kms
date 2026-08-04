# Accepted Prior Tryboot Authority Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow an accepted driver replacement to preserve an exact pre-existing accepted `tryboot.txt` without permitting ambient-file drift or bypassing lifecycle authority.

**Architecture:** Every new accepted replacement publishes schema-5 transition authority containing the exact prior-tryboot existence and digest plus an optional root-owned mode-0600 companion snapshot. Generic stage must prove its live input and captured backup match that authority before mutation and phase advancement; recovery, commit, verification, and finalization then preserve and revalidate the exact prior bytes. Existing schema-4 retained transitions and the accepted-receipt schema remain unchanged.

**Tech Stack:** Bash 5, root-owned Raspberry Pi boot/state files, SHA-256 identity, executable filesystem lifecycle fixtures, GitButler virtual branches, mise.

## Global Constraints

- Work only in `/Users/shayne/code/hyperpixel2r-kms` on GitButler branch `codex/brightness-night-mode-driver`, starting from design commit `e7d17c8`.
- Do not create a worktree, push, tag, release, publish, deploy, reboot, access the physical target, or modify Plane Radar.
- Use TDD: every production behavior begins with an executable fixture that fails for the expected missing authority.
- Change only `scripts/lifecycle-remote.sh` and `tests/boot-fixtures.sh`; modify `tests/boot-scripts.sh` only if an existing mechanical inventory check explicitly requires it.
- New `prepare-new` transitions use schema 5; existing schema 2–4 readers, schema-4 retained transitions, accepted receipt schema 3, uninstall state, and public release schemas remain compatible and unchanged.
- Never accept caller-controlled paths or digests for prior tryboot authority.
- Never park, rename, delete, or manually bypass a pre-existing accepted prior file.
- All new failures are fixed, sanitized messages that do not echo file contents.
- Use existing link-first type, root ownership/mode, private workspace, `privileged_snapshot`, `atomic_copy`, exact artifact, and SHA-256 helpers.
- Preserve unrelated active/conflicted GitButler branches and commit only this plan's paths.

---

### Task 1: Bind accepted prior tryboot identity through the full replacement lifecycle

**Files:**
- Modify: `scripts/lifecycle-remote.sh`
- Modify: `tests/boot-fixtures.sh`
- Modify only if named by an existing failing mechanical check: `tests/boot-scripts.sh`

**Interfaces:**
- Consumes: accepted receipt identity, accepted artifact `prior-tryboot.txt`, live `/boot/firmware/tryboot.txt`, generic schema-4 tryboot state, accepted replacement identity
- Produces: accepted-transition schema 5 with `prior_tryboot_existed` and `prior_tryboot_sha256`, optional `/var/lib/hyperpixel2r-kms/accepted-transition-prior-tryboot.txt`, exact phase/recovery invariants
- Preserves: `accepted-lifecycle.sh` CLI, accepted receipt schema 3, schema-4 retained transitions, generic stage/rollback/commit interfaces, exact backlight-rule and DKMS authority

- [ ] **Step 1: Add a real accepted-prior fixture and verify the current RED**

In `tests/boot-fixtures.sh`, build a separate accepted target using the existing public lifecycle instead of fabricating state:

```bash
new_target
accepted_prior_tryboot="$root/boot/firmware/tryboot.txt"
printf '%s\n' \
  '[all]' \
  '# accepted prior one-shot configuration' \
  'dtoverlay=hyperpixel2r-kms-eefaf3ae40fd' \
  > "$accepted_prior_tryboot"
chown root:root "$accepted_prior_tryboot"
chmod 0755 "$accepted_prior_tryboot"
accepted_prior_tryboot_sha="$(sha256sum "$accepted_prior_tryboot" | awk '{ print $1 }')"
run_stage >/dev/null
install_live_hardware
run_controller commit-boot.sh >/dev/null
run_accepted_remote record-accepted 0.1.1 "$source_revision" "$release" >/dev/null
accepted_artifact="$root/usr/lib/hyperpixel2r-kms/0.1.1/$source_revision/$release"
cmp -s "$accepted_prior_tryboot" "$accepted_artifact/prior-tryboot.txt" ||
  fail 'fixture did not establish a real accepted prior tryboot backup'
```

Then attempt `prepare-new-accepted` with the existing exact candidate arguments and require it to succeed. Assert the expected schema-5 facts and companion:

```bash
candidate_revision='cccccccccccccccccccccccccccccccccccccccc'
candidate_overlay='hyperpixel2r-kms-cccccccccccc.dtbo'
candidate_manifest_sha="$(printf d%.0s {1..64})"
candidate_module_sha="$(printf e%.0s {1..64})"
candidate_overlay_sha="$(printf f%.0s {1..64})"
candidate_rule_sha="$(printf a%.0s {1..64})"
run_accepted_remote prepare-new-accepted \
  0.1.1 "$candidate_revision" "$release" "$candidate_manifest_sha" \
  hyperpixel2r_kms.ko "$candidate_module_sha" \
  "$candidate_overlay" "$candidate_overlay_sha" \
  "$backlight_rule_file" "$candidate_rule_sha" >/dev/null
transition="$root/var/lib/hyperpixel2r-kms/accepted-transition"
transition_prior="$root/var/lib/hyperpixel2r-kms/accepted-transition-prior-tryboot.txt"
grep -Fxq 'schema_version=5' "$transition"
grep -Fxq 'prior_tryboot_existed=true' "$transition"
grep -Fxq "prior_tryboot_sha256=$accepted_prior_tryboot_sha" "$transition"
test "$(stat -c '%U:%G:%a' "$transition_prior")" = root:root:600
cmp -s "$transition_prior" "$accepted_prior_tryboot"
```

Place this scenario and all focused mutations added by later steps in an
`exercise_accepted_prior_tryboot_authority` function. Extend the existing
fixture selector without changing its other cases:

```bash
accepted-prior-tryboot)
  exercise_accepted_prior_tryboot_authority
  exit 0
  ;;
```

Run:

```bash
HP2R_FIXTURE_CASE=accepted-prior-tryboot mise run test-boot-scripts
```

Expected RED: `prepare-new-accepted` exits nonzero with `accepted transition requires an unused tryboot config`; the schema-5 transition and companion are absent.

- [ ] **Step 2: Define schema-5 paths, keys, and exact prior-authority validators**

In `scripts/lifecycle-remote.sh`, add the fixed companion path and schema keys:

```bash
accepted_transition_prior_tryboot="$state_dir/accepted-transition-prior-tryboot.txt"

accepted_transition_keys_v5=(
  "${accepted_transition_keys_v4[@]}"
  prior_tryboot_existed prior_tryboot_sha256
)
```

Add focused helpers with these contracts:

```bash
accepted_prior_artifact_path()       # prints the exact artifact path resolved only from accepted_state
validate_accepted_prior_tryboot()    # arguments: expected existence, expected digest; validates live, companion, accepted artifact
validate_prepared_prior_tryboot()    # requires live exact prior/absence immediately before generic stage mutation
validate_staged_prior_tryboot()      # requires generic state/artifact backup to equal transition companion/digest
restore_accepted_prior_tryboot()     # exact atomic restore from companion, or exact removal only for recorded absence
clear_accepted_prior_tryboot_proof() # removes only a validated companion at transition retirement
```

`accepted_prior_artifact_path` must derive:

```bash
printf '%s/%s/%s/%s\n' \
  "$artifact_root" \
  "$(accepted_value driver_version)" \
  "$(accepted_value source_revision)" \
  "$(accepted_value kernel_release)"
```

For `true`, validation requires:

```bash
assert_artifact_tree "$prior_artifact" true
assert_owned_regular "$tryboot_config" boot
assert_owned_regular "$accepted_transition_prior_tryboot" 600
assert_owned_regular "$prior_artifact/prior-tryboot.txt" 600
test "$(sha "$tryboot_config")" = "$expected_sha"
test "$(sha "$accepted_transition_prior_tryboot")" = "$expected_sha"
test "$(sha "$prior_artifact/prior-tryboot.txt")" = "$expected_sha"
sudo cmp -s -- "$tryboot_config" "$accepted_transition_prior_tryboot"
sudo cmp -s -- "$prior_artifact/prior-tryboot.txt" "$accepted_transition_prior_tryboot"
```

For `false`, require digest `none`, live/companion/artifact backup all absent with link-first checks, and `assert_artifact_tree "$prior_artifact" false`.

Extend `assert_accepted_transition` to select `accepted_transition_keys_v5` for schema 5, require `kind=new`, validate the boolean/digest pair, and call the phase-appropriate helper. Schema 2–4 behavior remains byte-for-byte compatible.

Run:

```bash
bash -n scripts/lifecycle-remote.sh
HP2R_FIXTURE_CASE=accepted-prior-tryboot mise run test-boot-scripts
```

Expected intermediate result: schema parsing/validator unit fixtures can pass, while the positive RED remains because `prepare_new_accepted` still rejects the live file.

- [ ] **Step 3: Publish exact prior authority before the transition journal**

Extend `prepare_new_accepted` to resolve and validate the accepted artifact before creating candidate state. Replace the unconditional unused-file rejection with exact prior discovery:

```bash
if sudo test -L "$tryboot_config"; then
  die 'accepted prior tryboot config is unsafe'
elif sudo test -e "$tryboot_config"; then
  assert_owned_regular "$tryboot_config" boot ||
    die 'accepted prior tryboot config is unsafe'
  assert_artifact_tree "$prior_artifact" true ||
    die 'accepted prior tryboot artifact is unsafe'
  sudo cmp -s -- "$tryboot_config" "$prior_artifact/prior-tryboot.txt" ||
    die 'accepted prior tryboot config differs from retained proof'
  prior_tryboot_existed=true
  prior_tryboot_sha="$(sha "$tryboot_config")"
  prior_tryboot_snapshot="$(privileged_snapshot \
    "$tryboot_config" "$workspace" accepted-prior-tryboot)" ||
    die 'failed to snapshot accepted prior tryboot config'
else
  assert_artifact_tree "$prior_artifact" false ||
    die 'accepted prior tryboot absence differs from retained proof'
  prior_tryboot_existed=false
  prior_tryboot_sha=none
  prior_tryboot_snapshot=''
fi
```

Extend `publish_accepted_transition` so `kind=new` writes schema 5 and the two prior fields. Publish in this order:

```text
accepted-transition-prior-config.txt
accepted-transition-prior-tryboot.txt (only when true)
accepted-transition (complete journal, last)
```

Add a fixture interruption point after the optional companion is published but before the journal. Extend `recover_accepted`'s no-journal path to clear an orphan prior-tryboot companion only after accepted-state, live-file, accepted-artifact, owner/mode, digest, and byte-equality validation. Unsafe or unrelated orphan data must be preserved and rejected.

Run:

```bash
HP2R_FIXTURE_CASE=accepted-prior-tryboot mise run test-boot-scripts
```

Expected GREEN for the Step 1 positive fixture and new orphan-publication recovery fixtures.

- [ ] **Step 4: Add exhaustive fail-closed publication and parser fixtures**

Add table-driven fixture mutations for each authority leaf. For every case, assert `prepare-new-accepted` or transition validation fails, the accepted receipt/config/live prior bytes remain exact, and no candidate artifact, generic state, or unproven proof file is deleted:

```text
unrelated ambient live file
live byte drift
live symlink
live directory/FIFO
live owner drift
live mode drift
accepted artifact prior missing
accepted artifact prior byte drift
accepted artifact prior symlink/non-regular/owner/mode drift
transition companion missing/drift/symlink/non-regular/owner/mode drift
prior_tryboot_existed missing/duplicated/unknown value
prior_tryboot_sha256 missing/duplicated/malformed/none mismatch
unknown schema-5 key and wrong row cardinality
unsafe orphan companion and mismatched safe orphan companion
```

Use fresh fixtures per mutation; never repair a rejected fixture in place and then reuse it as success evidence.

Run:

```bash
HP2R_FIXTURE_CASE=accepted-prior-tryboot mise run test-boot-scripts
```

Expected: all new rejection fixtures pass and the original lifecycle suite remains green.

- [ ] **Step 5: Bind generic stage capture to prepared authority before mutation**

In `stage()`, after existing candidate/normal/DKMS identity checks recognize an accepted-bound schema-5 transition, call `validate_prepared_prior_tryboot` before the first artifact, rule, module, overlay, DKMS, or tryboot mutation.

After generic stage snapshots the live prior and computes `prior_existed` / `prior_sha`, require exact equality with the transition:

```bash
test "$prior_existed" = "$(accepted_transition_value prior_tryboot_existed)" ||
  die 'captured prior tryboot existence differs from accepted transition'
test "$prior_sha" = "$(accepted_transition_value prior_tryboot_sha256)" ||
  die 'captured prior tryboot checksum differs from accepted transition'
if "$prior_existed"; then
  sudo cmp -s -- "$prior_tryboot" "$accepted_transition_prior_tryboot" ||
    die 'captured prior tryboot bytes differ from accepted transition'
fi
```

Before `set_accepted_transition_phase prepared staged`, require the published generic state and candidate artifact backup to pass `validate_staged_prior_tryboot`. Update schema-5 transition validation so:

- prepared with no generic state accepts only exact prior/absence or the exact bound candidate left by an interrupted stage;
- prepared with valid generic state requires the state/artifact prior backup and current candidate;
- staged accepts exactly two fail-closed substates:
  - before generic commit, valid generic state and artifact prior binding, the
    live exact candidate tryboot, and normal config equal to
    `prior_normal_config_sha256`;
  - after generic commit but before `mark-committed-accepted`, generic state
    absent, the live exact authorized prior or absence restored, and normal
    config byte-equal to an exact accepted-normal candidate derived in a private
    workspace from `accepted-transition-prior-config.txt` by surgically removing
    the prior accepted overlay declaration and appending the generic commit's
    exact accepted-candidate comment plus candidate overlay declaration;
  mixed substates such as state absent plus prior normal config or state present
  plus restored prior are rejected. `mark-committed-accepted` publishes the
  derived live digest into `candidate_normal_config_sha256` while advancing;
- later phases require exact restored prior/absence and no generic state.

Add a deterministic fixture that changes the live file after `prepare-new` but before `stage`; require stage to reject before any candidate leaf appears. Repeat with symlink replacement and exact candidate bytes that are not the prior bytes. At the post-generic-commit boundary, prove the exact derived accepted-normal config passes while prior-normal bytes, foreign bytes, and comment drift all fail.

Run:

```bash
HP2R_FIXTURE_CASE=accepted-prior-tryboot mise run test-boot-scripts
```

Expected: prepare-to-stage drift tests and the real positive stage pass.

- [ ] **Step 6: Restore exact prior authority across every interruption and phase**

Extend `restore_prior_from_accepted_transition`, `recover_accepted`, `mark_committed_accepted`, `mark_verified_accepted`, and `finalize_accepted`:

```text
prepared recovery: verify unchanged prior or exact interrupted candidate, restore only from companion when needed, retire candidate, clear validated companions
staged recovery: generic rollback restores prior, then compare live bytes/digest with transition companion before clearing authority
committed/verified/finalizing/receipt_published: require generic state absent and exact prior/absence restored
finalization: remove transition journal first under the existing resumable phase machine, then remove normal-config companion and prior-tryboot companion only after validating both; retry remains idempotent
```

When `finalize_accepted` is retried after `accepted-journal-cleared`, its
no-transition branch must validate the accepted receipt plus both orphan
companions, remove only the exact proven companions, and leave an unsafe or
mismatched companion untouched with a failure. This is the recovery path for
the existing journal-first interruption boundary.

Where current code uses `sudo rm -f -- "$tryboot_config"` during accepted recovery, replace it with `restore_accepted_prior_tryboot`. Exact removal remains allowed only for a schema-5 transition that records `false/none`, or for unchanged legacy schemas whose historical contract required absence.

Run every existing new-candidate interruption boundary with the real accepted prior fixture:

```text
accepted-transition-prior-tryboot-published
accepted-transition-published
candidate-artifact-published
candidate-module-installed
candidate-overlay-installed
candidate-dkms-activated
candidate-tryboot-published
candidate-tryboot-state-published
candidate-staged-published
accepted-committed-published
accepted-verified-published
accepted-finalizing-published
accepted-receipt-published
accepted-receipt-phase-published
accepted-prior-retired
accepted-journal-cleared
```

After each failed invocation and supported retry/recovery, assert:

```bash
test "$(sha256sum "$accepted_prior_tryboot" | awk '{ print $1 }')" = \
  "$accepted_prior_tryboot_sha"
cmp -s "$accepted_prior_tryboot" "$accepted_artifact/prior-tryboot.txt"
assert_absent "$root/var/lib/hyperpixel2r-kms/tryboot-state"
assert_absent "$root/var/lib/hyperpixel2r-kms/rollback-state"
```

Also assert journal/companions are present only in the phase that owns them and are all cleared after recovery/finalization. Do not assert live prior absence for the true case.

Run:

```bash
HP2R_FIXTURE_CASE=accepted-prior-tryboot mise run test-boot-scripts
```

Expected: interruption, recovery, commit, verification, and finalization fixtures all preserve exact prior bytes.

- [ ] **Step 7: Prove compatibility, full GREEN, and commit**

Run focused static and executable checks:

```bash
bash -n scripts/lifecycle-remote.sh
bash -n tests/boot-fixtures.sh
HP2R_FIXTURE_CASE=accepted-prior-tryboot mise run test-boot-scripts
mise run test-boot-scripts
```

Run the complete driver gate:

```bash
mise run verify
```

Expected: protocol, GPIO, compiled backlight, build/release, privacy, executable boot, legacy schema, retained, uninstall, and new accepted-prior lifecycle suites all pass. Record elapsed time and every configured skip/warning.

Inspect scope and privacy:

```bash
git diff --check
Review the implementation and fixture paths for deployment-specific host or
user identities; the search must return no matches.
but status
```

Commit only the implementation/test paths to `codex/brightness-night-mode-driver` through GitButler:

```bash
but status
but commit co -m "fix: preserve accepted prior tryboot authority"
```

Immediately before committing, require `but status` to show no uncommitted path
outside the authorized implementation/test set. If any unrelated path appears,
stop instead of committing it.

Append RED/GREEN, schema/phase, interruption, compatibility, full verification,
commit, and clean-workspace evidence to the ignored Plane Radar execution report
for Task 12. Do not resume target work until a fresh independent reviewer
approves the exact implementation commit.

---

## Post-implementation review and deployment gate

- Independently review the immutable design-base-to-candidate delta.
- Reproduce the real accepted-prior positive path and drift/interruption
  rejection fixtures.
- Confirm no accepted receipt, retained, uninstall, public schema, CLI, or
  release behavior changed.
- Resolve every Important or Critical finding with a test-first correction and
  fresh full verification.
- Update Task 12's durable driver tip to the approved implementation commit.
- Rerun complete driver verification from that tip and repeat the entire
  read-only target hard checkpoint before executing the separately reviewed
  boot-selection amendment.
