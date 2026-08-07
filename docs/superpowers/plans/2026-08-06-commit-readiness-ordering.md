# Commit Readiness Ordering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Verify live renderer readiness before expensive promotion proof while preserving exact mutation-boundary authority and rejecting lifecycle or boot identity drift.

**Architecture:** A new bounded target `commit-intent-probe` returns the same typed lifecycle tuple as the authoritative `commit-probe`, extended with the current boot UUID. The controller verifies the live boot from the intent tuple, runs the full proof, requires exact tuple equality, and only then calls the unchanged full-validation remote commit action.

**Tech Stack:** Bash 5, executable Linux filesystem fixtures, strict tab-separated protocols, Raspberry Pi tryboot state, GitButler, mise.

## Global Constraints

- Work only in `/Users/shayne/code/hyperpixel2r-kms` on GitButler stack `codex/legacy-inactive-backlight-authority`.
- Preserve unrelated GitButler stacks and commit only the files named below.
- Use strict TDD: the expiring-readiness behavioral fixture must fail for the old ordering before production code changes.
- The physical target remains frozen staged/uncommitted. Do not access, mutate, or reboot it.
- Do not record target endpoints, usernames, addresses, serials, host keys, target identity digests, or captured private output.
- Do not push, tag, release, publish, or change the product repository.
- `commit-intent-probe` is read-only and non-authoritative. Remote `commit` retains all existing mutation-boundary validation.
- Every verifier identity field is mandatory and strictly typed; exact authoritative tuple equality and the same boot UUID are required before commit.

---

### Task 1: Reorder promotion around a typed intent probe

**Files:**
- Modify: `tests/boot-fixtures.sh`
- Modify: `scripts/lifecycle-remote.sh`
- Modify: `scripts/commit-boot.sh`
- Modify: `tests/boot-scripts.sh` only if the focused fixture needs a new forwarded environment selector
- Create: `docs/superpowers/specs/2026-08-06-commit-readiness-ordering-design.md`
- Create: `docs/superpowers/plans/2026-08-06-commit-readiness-ordering.md`

**Interfaces:**
- Produce remote action `commit-intent-probe` with the exact ten-field typed tuple defined in the design.
- Extend `commit-probe` with the same canonical boot UUID and reject a boot change during its own validation.
- Consume both tuples through one controller parser; expose parsed fields only after strict validation.
- Preserve remote action `commit` and all of its existing full validations.

- [ ] **Step 1: Write the expiring-readiness RED fixture**

Add `HP2R_FIXTURE_EXPIRE_READINESS_AFTER_COMMIT_PROBE=1` behavior to the fake
transport. After the authoritative `commit-probe` returns, mark the current
boot readiness record expired; fake `journalctl` then emits no readiness line.
Add a focused `commit-readiness-ordering` case that stages a candidate, creates
the tryboot flag and live hardware, invokes `commit-boot.sh`, and asserts exact
promotion state.

Run:

```bash
HP2R_FIXTURE_CASE=commit-readiness-ordering mise run test-boot-scripts
```

Expected RED: promotion fails with `no KMSDRM/OpenGL ES 2 SDL readiness record in current boot` because the current controller calls `commit-probe` first.

- [ ] **Step 2: Add lightweight typed intent and boot identity**

In `scripts/lifecycle-remote.sh`, add helpers that:

```text
read and validate canonical /proc/sys/kernel/random/boot_id
validate bounded state or schema-6 transition row shape
validate all tuple field types and allowed phase/boot combinations
classify initial, config-only reconcile, pre-phase reconcile, and durable replay
reject ambiguous state, hold, workspace, selector, or small-config identity
```

The intent path must not traverse or hash artifact, DKMS, module, overlay,
kernel, initramfs, device, or sysfs trees. Wrap the full `commit-probe` so its
boot UUID is equal before and after authoritative validation.

- [ ] **Step 3: Reorder the controller and make the RED green**

In `scripts/commit-boot.sh`, centralize strict tuple parsing. Run intent probe,
complete live verifier, full commit probe, exact raw tuple comparison, then
remote commit. Reject malformed tuples, inconsistent phase/boot pairs,
retired-tryboot misuse, tuple mismatch, and boot UUID mismatch before commit.

Run:

```bash
HP2R_FIXTURE_CASE=commit-readiness-ordering mise run test-boot-scripts
```

Expected GREEN: the verifier observes readiness before the fake full probe
expires it, then exact proof equality permits promotion.

- [ ] **Step 4: Add drift and replay coverage**

Extend the focused fixture so a changed authoritative identity field and a
changed boot UUID both reject promotion while byte-for-byte snapshots of normal
config, tryboot config, state, and accepted transition remain unchanged. Run
the existing inactive explicit interruption, config-only replay, prior-tryboot
replay, and normal replay cases to cover every supported mode.

Run:

```bash
HP2R_FIXTURE_CASE=commit-readiness-ordering mise run test-boot-scripts
HP2R_FIXTURE_CASE=inactive-kernel-explicit-interruptions mise run test-boot-scripts
HP2R_FIXTURE_CASE=inactive-kernel-explicit-interfile-crash mise run test-boot-scripts
HP2R_FIXTURE_CASE=inactive-kernel-explicit-prior-tryboot-replay mise run test-boot-scripts
HP2R_FIXTURE_CASE=inactive-kernel-explicit-normal-replay mise run test-boot-scripts
```

Expected: all pass, and no rejected case invokes remote commit or changes
durable lifecycle bytes.

- [ ] **Step 5: Run proportional and full verification**

Run:

```bash
bash -n scripts/commit-boot.sh scripts/lifecycle-remote.sh tests/boot-fixtures.sh
mise run test-boot-scripts
mise run test-protocol
mise run test-gpio
mise run test-backlight-contract
mise run test-build-contract
mise run test-release-contract
git diff --check
git status --short
```

The five non-boot component tasks plus the single exhaustive boot run are the
complete `mise run verify` dependency set without executing the long boot suite
twice. Expected: all commands pass; status contains only the scoped files above.

- [ ] **Step 6: Create the signed GitButler commit and stop for review**

Run:

```bash
but commit codex/legacy-inactive-backlight-authority -m 'fix: verify readiness before commit proof'
git log -1 --show-signature --format=fuller
git status --short
but status
```

Expected: a signed commit on only the requested stack, clean workspace, no
push/tag/release, and no physical-target access. Stop for independent review.
