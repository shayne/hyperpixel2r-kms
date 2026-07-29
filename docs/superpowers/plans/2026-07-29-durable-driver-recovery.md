# Durable Driver Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make candidate activation byte-exact and make rollback of an installed prior DKMS inventory durable and crash-resumable.

**Architecture:** Stage verifies both the uncompressed bytes and exact `/extra` path selected by `modules.dep`, removing prior installed registration state before publishing tryboot. Rollback persists a versioned root-owned journal and candidate inventory, atomically holds the candidate module under a non-loadable adjacent name, and resumes rollback or compensation from exact durable phases.

**Tech Stack:** Bash, Raspberry Pi OS DKMS and depmod, Docker-hosted executable shell fixtures, mise, GitButler.

## Global Constraints

- Do not mutate the physical Pi until independent review approves the feature stack.
- Preserve transaction schemas 1, 2, and 3 and the accepted lifecycle protocol.
- Never use DKMS `--force`.
- Every durable phase is atomically published and synced before the next destructive operation.
- Journal, inventory, and hold paths are fixed, root-owned, regular, and non-symlink.
- The hold filename must not be loadable by depmod.
- Every commit has exactly one `Co-authored-by: Codex <noreply@openai.com>` trailer.

---

### Task 1: Add live-shaped RED candidate-resolution fixtures

**Files:**
- Modify: `tests/boot-fixtures.sh`

**Interfaces:**
- Consumes: the fixture DKMS installer and depmod model.
- Produces: executable scenarios in which source equality and resolved module equality are independent facts.

- [ ] **Step 1: Extend the fixture boundary**

Add a decompression-aware resolved-module fixture and a DKMS install collision
mode. The fake depmod must prefer `updates/dkms` over `extra`, matching the live
Pi, while ignoring `hyperpixel2r_kms.ko.hp2r-rollback-hold`.

- [ ] **Step 2: Add the mismatched-reuse scenario**

Create an installed prior DKMS tree whose eight source leaves equal the
candidate source but whose installed module bytes are a literal mismatch.
Assert that successful stage removes the installed registration, runs depmod,
and leaves `modules.dep` resolving the manifest module under `extra`.

- [ ] **Step 3: Add the exact-byte wrong-leaf scenario**

Create the same installed prior state with resolved uncompressed bytes exactly
equal to the manifest module. Assert that stage still detaches the installed
DKMS registration because `updates/dkms` is not the manifest-bound candidate
leaf, and resolves `/extra/hyperpixel2r_kms.ko`.

- [ ] **Step 4: Verify RED**

Run:

```sh
mise run test-boot-scripts
```

Expected: the mismatched-reuse assertion fails because production stage accepts
source equality without checking resolved bytes.

### Task 2: Implement byte-exact candidate activation

**Files:**
- Modify: `scripts/lifecycle-remote.sh`
- Modify: `tests/boot-fixtures.sh`

**Interfaces:**
- Produces: `resolved_module_sha256 RELEASE MODULE`, which accepts only fixed
  `extra` or `updates/dkms` leaves and returns the uncompressed SHA-256.
- Produces: stage behavior that publishes tryboot only after depmod resolves
  manifest-exact bytes from the exact `/extra` leaf.

- [ ] **Step 1: Add the minimal resolver**

Parse the unique `hyperpixel2r_kms.ko:` row in `modules.dep`, validate its
relative path and suffix, require root-owned non-symlink directories from the
kernel-module root through the resolved leaf, and decode compressed leaves
through a private root-owned file with an 8 MiB output ceiling. Reject
overflow, truncation, and decoder failure before returning the uncompressed
SHA-256.

- [ ] **Step 2: Enforce stage resolution**

After candidate `/extra` publication, compare the current resolved path and
bytes with the manifest. Any `updates/dkms` resolution follows the
inventory-backed DKMS replacement path, even when its uncompressed bytes are
equal. Run depmod and require the exact manifest-bound `/extra` path and bytes
before tryboot publication.

- [ ] **Step 3: Verify GREEN**

Run `mise run test-boot-scripts`. Both mismatch replacement and exact-byte
wrong-leaf replacement must pass without weakening existing stage-cleanup
fixtures.

### Task 3: Add RED durable rollback and compensation fixtures

**Files:**
- Modify: `tests/boot-fixtures.sh`

**Interfaces:**
- Consumes: fixed rollback journal, candidate inventory, and adjacent hold
  paths from the design.
- Produces: live-shaped collision and phase/reboot replay coverage.

- [ ] **Step 1: Add the exact live-state collision**

Stage from an identical source tree with a mismatched installed leaf, then make
the fixture DKMS installer reject the candidate `/extra` collision exactly as
Raspberry Pi OS did. Assert rollback restores prior installed resolution
without `--force`.

- [ ] **Step 2: Add phase interruption table**

For every journal publication and destructive boundary, inject a one-shot
process exit, assert journal/hold/transaction checksums remain valid, simulate
a reboot by recreating only the command environment, rerun rollback, and assert
the exact prior inventory and normal boot state. Run the table for both
transaction-created and preexisting `/extra` module leaves in live-shaped
schema-3 transactions with an installed prior running-kernel DKMS row.

- [ ] **Step 3: Add compensation interruption table**

Inject failure during prior restore, enter durable compensation, interrupt
before and after candidate inventory, source, held module, depmod, and journal
cleanup operations, then resume and assert the exact candidate transaction is
replayable. Run the same table for both transaction-created and shared
schema-3 module leaves.

- [ ] **Step 4: Add hostile durable-state cases**

Reject journal, inventory, or hold symlinks; wrong ownership/mode; bad phase;
transaction-hash drift; module-hash drift; and simultaneous candidate plus hold
states. Reject candidate or restored tryboot/overlay drift and verified
compensation whose live DKMS inventory differs from its checksum-bound
candidate inventory.

- [ ] **Step 5: Verify RED**

Run `mise run test-boot-scripts`. Expected: the first collision or interruption
scenario fails because production rollback has no durable journal and restores
DKMS before detaching the candidate module.

### Task 4: Implement durable resumable rollback

**Files:**
- Modify: `scripts/lifecycle-remote.sh`
- Modify: `tests/boot-fixtures.sh`
- Modify: `docs/operations.md`

**Interfaces:**
- Produces: schema-1 `rollback-state` and a checksum-bound candidate inventory.
- Produces: idempotent rollback and compensation resume from all durable phases.

- [ ] **Step 1: Add strict journal primitives**

Implement exact-schema parsing, root ownership/mode checks, fixed-path checks,
atomic phase publication, fsync-by-`sync`, and transaction identity binding.

- [ ] **Step 2: Add atomic candidate hold**

Move the manifest-validated `/extra` leaf to
`hyperpixel2r_kms.ko.hp2r-rollback-hold`, including a leaf that existed before
staging when an installed prior DKMS row must be restored. Accept exact before
or after state on resume, restore shared leaves after DKMS installation, and
reject every ambiguous state.

- [ ] **Step 3: Add forward rollback phases**

Capture the candidate inventory durably, hold the module, restore and verify
the prior inventory, restore boot state and candidate-created overlay
ownership, run depmod, verify prior resolution, then retire transaction and
journal state in recoverable order.

- [ ] **Step 4: Add durable compensation phases**

On an ordinary failure, publish `mode=compensate` before changing candidate
state. Resume exact candidate source/inventory, held module, overlay, tryboot,
and depmod resolution until the original transaction is fully replayable.
Recapture the live DKMS inventory and compare it with the journal checksum
immediately before clearing durable recovery authority.

- [ ] **Step 5: Preserve compatibility**

Run direct schema-1, schema-2, schema-3, accepted receipt, retained transition,
accepted uninstall, no-DKMS, and multi-kernel inventory scenarios.

- [ ] **Step 6: Document operator outcomes**

Document that reboot at each journal phase is safe but requires rerunning the
generic rollback controller before any commit, uninstall, stage, or accepted
lifecycle action.

- [ ] **Step 7: Verify GREEN**

Run:

```sh
mise run test-boot-scripts
mise run verify
bash -n scripts/lifecycle-remote.sh tests/boot-fixtures.sh
```

Expected: all commands pass with no warnings or surviving private/durable
fixture state.

### Task 5: Publish the reviewed feature stack only

**Files:**
- Modify: ignored Task 21 report in the application repository.

**Interfaces:**
- Produces: one GitButler feature commit and remote feature ref; does not move
  main or contact the Pi.

- [ ] **Step 1: Review the exact diff**

Run `but status`, `but diff`, and `git diff --check`. Confirm no `.env`, target,
IP address, serial, credential, or raw private evidence is tracked.

- [ ] **Step 2: Commit through GitButler**

Commit the implementation and tests with a clear lifecycle-recovery subject
and exactly:

```text
Co-authored-by: Codex <noreply@openai.com>
```

- [ ] **Step 3: Push feature only**

Push the GitButler feature branch and verify its public remote SHA. Do not land
to main.

- [ ] **Step 4: Stop for independent review**

Report RED/GREEN evidence, full verification duration, commit SHA, remote
feature SHA, and the unchanged frozen Pi state.
