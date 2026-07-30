# Accepted Record Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development to implement this plan task-by-task,
> with independent review before the physical Pi is changed.

**Goal:** Make accepted receipt publication clean up after every failure,
canonicalize repeated owned marker comments, and provide a public fail-closed
command that can recover the one legacy recorder workspace on the live Pi.

**Architecture:** Candidate generation removes every exact owned marker before
commit appends one canonical marker. Stock derivation accepts repeated exact
legacy markers while preserving unrelated bytes. Receipt recording binds its
private workspace to the existing process-wide cleanup trap immediately after
allocation. A new explicit `recover-record` action validates one exact orphan
workspace, its two snapshots, the live artifact tuple, and the complete absence
of competing lifecycle authority before removing only that workspace.

**Tech Stack:** Bash, Raspberry Pi OS boot configuration and DKMS state,
Docker-hosted executable shell fixtures, mise, GitButler.

## Global constraints

- Keep the physical Pi on its verified healthy RC18 normal boot until the
  feature stack has passed independent review, landed on `main`, and shipped
  as a strictly verified RC19.
- Do not manually remove the live orphan workspace.
- Do not add implicit garbage collection or broad workspace cleanup.
- Every destructive decision must be based on fixed paths, exact schemas,
  ownership, mode, hashes, and the requested release tuple.
- Preserve schema-1 through schema-3 transactions, durable rollback,
  accepted transitions, retained transitions, uninstall, no-DKMS, and
  multi-kernel behavior.
- Use GitButler for all version-control changes.
- Every Codex-assisted commit has exactly one
  `Co-authored-by: Codex <noreply@openai.com>` trailer.

---

### Task 1: Add RED marker-canonicalization and recorder-cleanup fixtures

**Files:**
- Modify: `tests/boot-fixtures.sh`

**Interfaces:**
- Exercises: `validate_overlay_declarations`,
  `write_surgical_stock_config`, and `record-accepted`.
- Produces: live-shaped failures for the RC18 duplicate-marker and leaked
  workspace defects.

- [ ] **Step 1: Add the live legacy normal-config shape**

Create a fixture normal config containing:

```text
# hyperpixel2r-kms accepted candidate
# hyperpixel2r-kms accepted candidate
# hyperpixel2r-kms accepted candidate
dtoverlay=hyperpixel2r-kms-<revision-prefix>.dtbo
```

Include unrelated comments, sections, and non-HyperPixel declarations before
and after this block. Preserve a byte-exact copy for comparison.

- [ ] **Step 2: Prove stage and commit must canonicalize**

Run stage and commit from the legacy fixture. Assert that the resulting
candidate and normal config contain the exact owned overlay once, the exact
owned marker once, no foreign HyperPixel overlay, and every unrelated byte in
the original order.

- [ ] **Step 3: Prove record must accept legacy markers**

Run `record-accepted` against the legacy normal config. Assert that the
published stock config removes the exact owned overlay and all three exact
owned markers while preserving unrelated content byte-for-byte. Verify the
receipt hashes the unchanged normal config and derived stock config.

- [ ] **Step 4: Add post-allocation recorder failure injection**

Use the existing operation-failure boundary to fail every operation after
`new_transaction_workspace`, including normal snapshot, stock allocation,
stock derivation, receipt allocation/write, stock publication, receipt
publication, workspace removal, sync, and final receipt validation.

For every pre-publication failure, assert:

- no `.hp2r-transaction.*` workspace survives;
- no accepted receipt or stock config is published;
- normal config, artifact tree, module, and overlay are unchanged.

For failures after one accepted leaf has been atomically published, assert the
existing fail-closed authority rules remain intact and no private workspace
survives.

- [ ] **Step 5: Verify RED**

Run:

```sh
mise run test-boot-scripts
```

Expected: duplicate-marker stage/commit or record assertions fail, and at
least one injected recorder failure leaves a private workspace.

### Task 2: Implement canonical markers and unconditional recorder cleanup

**Files:**
- Modify: `scripts/lifecycle-remote.sh`
- Modify: `tests/boot-fixtures.sh`

**Interfaces:**
- `validate_overlay_declarations CONFIG REPLACEMENT OUTPUT WORKSPACE`
  removes every exact trimmed owned marker from its private output.
- `write_surgical_stock_config INPUT OVERLAY OUTPUT WORKSPACE` accepts any
  number of exact owned markers but still requires one exact owned overlay.
- `record_accepted VERSION REVISION RELEASE` assigns
  `accepted_workspace` immediately after allocation.

- [ ] **Step 1: Canonicalize candidate input**

Teach `validate_overlay_declarations` to skip only the exact trimmed marker
`# hyperpixel2r-kms accepted candidate`. Continue to reject malformed overlay
syntax, a missing or repeated selected overlay, and any foreign HyperPixel
overlay. Do not treat similar comments as owned.

- [ ] **Step 2: Accept exact legacy markers in stock derivation**

Remove the `comments > 1` rejection in `write_surgical_stock_config`. Continue
to strip every exact owned marker and require exactly one exact selected
overlay and no foreign HyperPixel overlay. Extend fixtures with near-match
comments to prove they remain byte-for-byte preserved.

- [ ] **Step 3: Bind recorder cleanup authority**

Set:

```sh
accepted_workspace="$workspace"
```

immediately after successful workspace allocation, before the first snapshot
or private-file allocation. On successful workspace removal, clear
`accepted_workspace`. Let the existing EXIT trap own all failure cleanup.

- [ ] **Step 4: Verify GREEN**

Run:

```sh
mise run test-boot-scripts
bash -n scripts/lifecycle-remote.sh tests/boot-fixtures.sh
```

Expected: marker and recorder-cleanup fixtures pass, with no change to existing
accepted lifecycle behavior.

### Task 3: Add RED explicit legacy workspace recovery fixtures

**Files:**
- Modify: `tests/boot-fixtures.sh`
- Modify: `scripts/accepted-lifecycle.sh`

**Interfaces:**
- Adds controller action:
  `accepted-lifecycle.sh --action recover-record --driver-version VERSION
  --source-revision REVISION --kernel-release RELEASE`.
- Adds remote action:
  `lifecycle-remote.sh recover-accepted-record VERSION REVISION RELEASE`.

- [ ] **Step 1: Add exact recoverable orphan fixture**

Create one root-owned mode-0700
`$state_dir/.hp2r-transaction.<safe-suffix>` containing exactly:

- one root-owned mode-0600
  `.hp2r-accepted-normal.<safe-suffix>` equal to current normal config;
- one root-owned mode-0600 `accepted-stock` equal to newly derived stock
  config.

Install the exact manifest-bound artifact, module, overlay, and normal config
for the requested tuple. Assert `recover-accepted-record` removes only that
workspace, syncs state, and publishes no receipt.

- [ ] **Step 2: Add idempotent replay and interruption fixtures**

Run recovery a second time with no workspace and require a verified no-op.
Inject interruption immediately before removal and immediately after removal;
rerun and require either exact recovery or the same verified no-op.

- [ ] **Step 3: Add ambiguous authority failures**

For each case, assert nonzero exit and byte-identical orphan state:

- active tryboot transaction;
- rollback journal or either rollback auxiliary;
- accepted receipt or accepted stock orphan;
- accepted transition or either transition auxiliary;
- accepted uninstall journal;
- more than one transaction workspace.

- [ ] **Step 4: Add hostile workspace failures**

Independently test an unsafe suffix, symlink workspace, wrong owner, wrong
mode, non-directory workspace, extra leaf, missing leaf, symlink leaf, wrong
leaf owner/mode/type, multiple accepted-normal snapshots, changed normal
snapshot, and changed stock snapshot. None may remove any leaf.

- [ ] **Step 5: Add tuple and installed-state failures**

Independently drift requested version, revision, release, artifact tree,
manifest, module bytes/path, overlay bytes/path, normal config, exact overlay
declaration, and foreign HyperPixel declaration. None may remove the
workspace.

- [ ] **Step 6: Verify RED**

Run:

```sh
mise run test-boot-scripts
```

Expected: the controller rejects `recover-record` as unsupported or the remote
command has no implementation.

### Task 4: Implement fail-closed `recover-record`

**Files:**
- Modify: `scripts/lifecycle-remote.sh`
- Modify: `scripts/accepted-lifecycle.sh`
- Modify: `tests/boot-fixtures.sh`
- Modify: `docs/operations.md`

**Interfaces:**
- Produces:
  `recover_accepted_record VERSION REVISION RELEASE`.
- Produces public controller mapping:
  `recover-record` -> `recover-accepted-record`.

- [ ] **Step 1: Validate the requested tuple and authority boundary**

Reuse the same version, revision, release, artifact-tree, manifest, installed
module, installed overlay, and normal-config validation used by
`record_accepted`. Require every fixed lifecycle authority path and auxiliary
to be absent before inspecting orphan workspaces.

- [ ] **Step 2: Enumerate without broad globs**

Enumerate fixed-state-directory entries and accept only zero or one real
directory whose basename exactly matches
`.hp2r-transaction.<safe-suffix>`. Reject unknown matching entries and a count
greater than one. Validate the workspace with `assert_private_workspace`.

- [ ] **Step 3: Validate exactly two leaves**

Enumerate the workspace without following symlinks. Require exactly one
`.hp2r-accepted-normal.<safe-suffix>` and exactly one `accepted-stock`, both
real root-owned mode-0600 regular files. Reject every other entry.

- [ ] **Step 4: Recompute both snapshot contracts**

Require the accepted-normal snapshot to equal the current normal config.
Allocate a separate private verifier workspace bound to the EXIT trap, derive
stock using `write_surgical_stock_config`, and require it to equal the orphan
`accepted-stock`. Remove the verifier workspace before touching the orphan.

- [ ] **Step 5: Remove only the validated orphan**

Recheck lifecycle authority, workspace identity, ownership, mode, leaf set,
and hashes immediately before removal. Call the existing exact
`remove_transaction_workspace`, run `sync`, and prove no transaction
workspace remains. With zero workspaces, validate the tuple and authority
boundary and return an explicit idempotent no-op.

- [ ] **Step 6: Wire and document the public controller**

Accept `recover-record` in the exact-identity action class. Pass only version,
revision, and release to the remote command. Document why it is explicit, what
it validates, that it never publishes a receipt, and that operators must not
run lifecycle commands concurrently.

- [ ] **Step 7: Verify GREEN and compatibility**

Run:

```sh
mise run test-boot-scripts
mise run verify
bash -n scripts/lifecycle-remote.sh scripts/accepted-lifecycle.sh tests/boot-fixtures.sh
git diff --check
```

Expected: all recovery, hostile-state, interruption, and prior compatibility
fixtures pass with no surviving fixture workspaces or durable authority.

### Task 5: Commit, publish, and independently review the feature

**Files:**
- Modify: this plan's implementation files only.

**Interfaces:**
- Produces: a public GitButler feature ref and an exact independent review of
  `83507076440044dcb810be286201d11eb5b5eb62..<feature-sha>`.
- Does not move `main` or mutate the Pi.

- [ ] **Step 1: Audit the complete diff**

Run `but status`, `but diff`, `git diff --check`, and secret/maintainer-value
searches. Confirm no `.env`, target hostname, IP address, credential, private
evidence, generated artifact, or fixture residue is tracked.

- [ ] **Step 2: Commit through GitButler**

Use focused commits for tests and implementation where the RED/GREEN history
is useful. Every commit must contain exactly one Codex co-author trailer.

- [ ] **Step 3: Push the feature ref**

Push through GitButler and independently verify its public remote SHA without
moving `main`.

- [ ] **Step 4: Perform independent review**

Review the exact base-to-feature diff for Critical, Important, and Minor
findings. Any finding returns to a new RED test and implementation cycle, then
full verification and re-review.

### Task 6: Land, release RC19, and recover the physical Pi

**Files:**
- No unreviewed source changes.
- Update: private ignored Task 21 evidence/report files as applicable.

**Interfaces:**
- Produces: green driver `main`, strictly verified public RC19, a clean
  recovered RC18 state, and a verified accepted RC19 receipt.

- [ ] **Step 1: Land and verify main**

Land the reviewed GitButler branch to `main`, push, verify the public commit
and tree, and wait for all main CI jobs to finish green.

- [ ] **Step 2: Publish and strictly verify RC19**

Create RC19 from the exact landed source. Verify tag object and peel, source
archive, manifest, SBOM, checksums, archive-to-Git tree identity, and SLSA
attestations.

- [ ] **Step 3: Recover the live RC18 orphan with public RC19 tooling**

Against the exact configured maintainer target, first capture read-only normal
boot, service, module, overlay, artifact, and authority state. Run only the
public RC19 `recover-record` command for the exact RC18 tuple. Prove the one
known workspace is absent, no other authority changed, and the RC18 normal
boot remains healthy.

- [ ] **Step 4: Exercise RC19 rollback and acceptance**

Build for the exact live kernel, stage RC19, verify tryboot, roll back, verify
the prior RC18 normal boot, and retire only the verified inactive RC19 bundle.
Restage RC19, verify, commit, reboot normally, and verify exact module,
overlay, manifest, renderer, touch, service, and zero restart count.

- [ ] **Step 5: Record and verify acceptance**

Run public RC19 `record` for the exact RC19 tuple. Verify the accepted receipt,
stock config, normal-config hash, artifact hashes, ownership/modes, and an
idempotent second record. Prove no transaction workspace or unresolved
lifecycle authority remains.

### Task 7: Complete driver stable and hand off to application releases

**Files:**
- No source changes unless a new independently reviewed defect is found.
- Update: public release notes and private acceptance evidence.

**Interfaces:**
- Produces: stable `v0.1.0` from the exact accepted driver source and unblocks
  the application RC/clean-room plan.

- [ ] **Step 1: Build an unpublished stable draft**

Draft `v0.1.0` from the exact accepted RC19 source. Strictly verify all stable
artifacts and deploy the unchanged stable payload to the Pi.

- [ ] **Step 2: Run the physical stable gate**

Require cold power-cycle, healthy normal boot, exact module and overlay
binding, clean 480x480 hardware-accelerated rendering, correct colors, and
working short tap, long hold, and QR interactions.

- [ ] **Step 3: Promote unchanged**

Promote the exact verified draft without rebuilding. Reverify public tag,
release assets, checksums, attestations, and clean-clone install inputs.

- [ ] **Step 4: Continue the approved product program**

Proceed to application RC1/RC2 live acceptance, fresh-SD clean-room
installation/upgrade/rollback/uninstall/reinstall and RC3, then publish the
unchanged application stable release only after every public-path gate passes.
