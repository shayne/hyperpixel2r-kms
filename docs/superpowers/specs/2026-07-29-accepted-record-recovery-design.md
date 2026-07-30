# Accepted Record Recovery Design

## Problem

The first public `accepted-lifecycle.sh --action record` invocation against a
healthy committed RC18 normal boot failed closed before publishing an accepted
receipt.

Two lifecycle defects caused the failure:

1. Each successful `commit` preserved every previous
   `# hyperpixel2r-kms accepted candidate` comment and appended another. The
   live normal config therefore contained one exact owned overlay declaration
   and three exact owned marker comments. `write_surgical_stock_config`
   rejected more than one marker.
2. `record_accepted` allocated a root-owned private transaction workspace into
   a local variable without binding it to the existing process-wide cleanup
   trap. Its validation failure therefore left one private workspace behind.

The live driver remains healthy on a normal boot. No accepted receipt,
accepted transition, uninstall journal, tryboot transaction, or rollback
journal exists. The leaked workspace is root-owned, mode 0700, and contains
only the failed recorder's two root-owned mode-0600 snapshots.

## Goals

- Make repeated stage and commit cycles leave one canonical accepted marker.
- Allow a valid legacy normal config containing repeated exact owned markers
  to produce the same stock config as a canonical one.
- Ensure every failed accepted-record operation removes its private workspace.
- Provide an explicit, public, fail-closed recovery action for the single
  legacy workspace created by the old cleanup bug.
- Reject unknown, ambiguous, concurrently authoritative, or hostile state.
- Preserve existing transaction, rollback, accepted-transition, uninstall,
  DKMS, boot-config, and artifact ownership contracts.

## Non-goals

- Do not infer ownership from broad paths, comments, or filenames.
- Do not automatically remove unknown transaction workspaces.
- Do not edit the live Pi manually.
- Do not accept RC18 as stable or publish a stable tag.
- Do not broaden cleanup to unrelated files or directories.

## Selected design

### Canonical owned marker handling

`validate_overlay_declarations` will recognize the exact trimmed marker:

```text
# hyperpixel2r-kms accepted candidate
```

It will remove every exact instance from the generated candidate while
continuing to reject malformed overlay declarations, unexpected HyperPixel
overlays, and an absent or duplicate replacement overlay. Stage and commit
therefore start from a marker-free validated candidate, and commit appends
exactly one owned marker with the exact owned overlay.

`write_surgical_stock_config` will continue to remove the exact owned overlay
and every exact owned marker. It will require one exact selected overlay and
no foreign HyperPixel overlay, but repeated exact marker comments will no
longer make an otherwise exact legacy config unsafe. Other comments remain
byte-for-byte preserved.

### Recorder cleanup

Immediately after `record_accepted` allocates its private workspace, it will
assign that path to `accepted_workspace`, which is already owned by the
process-wide EXIT trap. Every later failure must therefore remove the exact
workspace. Successful publication will remove it explicitly and clear
`accepted_workspace`.

The recorder must remain idempotent when the exact accepted receipt already
exists and must not weaken receipt, stock-config, module, overlay, artifact,
inventory, normal-config, ownership, or mode validation.

### Explicit legacy workspace recovery

Add a public accepted-lifecycle action named `recover-record`. It consumes the
exact driver version, source revision, and kernel release. It is intentionally
separate from `record`; ordinary receipt publication never deletes an
unrecognized workspace.

The action may remove a workspace only when all of these conditions hold:

- no tryboot transaction, rollback journal or auxiliaries, accepted receipt,
  accepted transition or auxiliaries, or accepted-uninstall journal exists;
- the requested artifact tree, manifest, module, overlay, current normal
  config, and exact owned overlay declaration validate for the requested
  tuple;
- exactly one fixed-name `.hp2r-transaction.<safe-suffix>` directory exists;
- the directory is a real root-owned mode-0700 directory beneath the fixed
  state directory;
- it contains exactly two real root-owned mode-0600 regular files:
  one `.hp2r-accepted-normal.<safe-suffix>` snapshot and one
  `accepted-stock`;
- the accepted-normal snapshot is byte-for-byte equal to the current normal
  config;
- the accepted-stock snapshot is byte-for-byte equal to a newly derived stock
  config that removes only the requested exact overlay and exact owned marker
  comments.

Any symlink, extra leaf, missing leaf, wrong type, owner, mode, hash, tuple,
config, module, overlay, artifact, journal, receipt, or workspace count stops
the action without deleting anything.

After deletion, the action syncs durable state and proves that no transaction
workspace remains. If no workspace exists, it returns a verified idempotent
no-op. The action never publishes an accepted receipt.

### Concurrency boundary

`recover-record` is an explicit recovery command, not implicit garbage
collection. Its contract requires the caller to serialize lifecycle actions.
The controller must run it alone and verify that no lifecycle authority file
exists before and after recovery. Unknown workspaces remain an operator-visible
failure rather than an automatic deletion target.

## Public interfaces

The controller gains:

```text
accepted-lifecycle.sh --action recover-record \
  --driver-version VERSION \
  --source-revision REVISION \
  --kernel-release RELEASE
```

Existing `record`, stage, commit, rollback, retained-transition, and uninstall
interfaces remain compatible.

## Failure and recovery behavior

- Marker canonicalization happens only in private candidates before atomic boot
  config publication.
- A commit failure continues to restore the prior normal and tryboot configs
  and transaction state.
- An accepted-record failure leaves no receipt or stock config and removes its
  private workspace.
- A recovery validation failure removes nothing.
- A crash during removal may leave the exact workspace wholly present or
  absent; rerunning `recover-record` accepts either verified state.
- Receipt publication remains a separate action after recovery and full normal
  boot verification.

## Verification

Executable fixtures must cover:

- three legacy exact owned markers through stage, commit, and record;
- stage and commit output with exactly one canonical accepted marker;
- byte preservation of unrelated comments and boot declarations;
- record failures at every operation after workspace allocation, with no
  surviving private workspace;
- exact legacy-workspace recovery and idempotent no-op replay;
- interruption immediately before and after workspace removal;
- hostile workspace suffix, symlink, owner, mode, type, extra leaf, missing
  leaf, snapshot hash, stock derivation, tuple, artifact, module, overlay,
  normal config, active transaction, rollback, accepted transition, uninstall,
  and receipt cases;
- unchanged schema-1 through schema-3 transaction, durable rollback,
  accepted-transition, retained-transition, uninstall, multi-kernel DKMS, and
  no-DKMS behavior.

Focused boot fixtures, shell syntax, `git diff --check`, and the full
`mise run verify` suite must pass. The feature branch receives independent
review before landing.

## Release and live recovery

After review and green main CI:

1. Publish and strictly verify the next numbered candidate, RC19, from the
   exact landed source.
2. Use only verified public RC19 tooling to run `recover-record` against the
   exact healthy RC18 tuple.
3. Build RC19 for the exact live kernel.
4. Stage RC19, verify tryboot, roll back, and verify the prior RC18 normal
   boot.
5. Retire only the verified inactive RC19 bundle.
6. Restage RC19, verify, commit, reboot normally, and verify.
7. Record and verify the exact RC19 accepted receipt.
8. Build an unpublished stable `v0.1.0` draft from that same accepted source,
   verify and deploy it, then stop for the cold-power-cycle, color, and touch
   physical gate before unchanged promotion.

No stable driver, application release, or manual Pi cleanup is permitted
before these gates pass.
