# Accepted prior tryboot preservation design

## Problem

An accepted driver replacement currently requires `/boot/firmware/tryboot.txt`
to be absent when `prepare-new` publishes the accepted transition. The generic
stage, rollback, and commit transaction already knows how to capture and
restore a safe pre-existing tryboot file, but the accepted-transition protocol
cannot authorize that path.

This blocks a legitimate accepted replacement when the live tryboot file is
the exact prior file retained by the accepted driver artifact. Moving or
deleting that file outside the lifecycle would discard rollback authority and
is not acceptable.

## Goals

- Allow a new accepted replacement only when a pre-existing tryboot file is
  proven to be the accepted driver's exact retained prior file.
- Bind that exact existence and digest into durable accepted-transition
  authority before staging can mutate active state.
- Make generic staging prove it is capturing the same authorized file, not
  whichever file happens to exist later.
- Preserve the exact prior bytes through interrupted staging, accepted
  recovery, candidate commit, verification, and finalization.
- Preserve the existing absent-file path and fail closed on drift, symlinks,
  unsafe ownership or modes, incomplete journals, and interrupted publication.
- Avoid changing the accepted-receipt schema or Plane Radar's provenance
  parser for this narrowly scoped lifecycle correction.

## Non-goals

- Accepting arbitrary ambient tryboot files.
- Adding a command that parks, renames, deletes, or bypasses a prior file.
- Changing ordinary tryboot behavior, candidate boot configuration contents,
  retained-candidate behavior, uninstall authority, or release schemas.
- Updating a public driver identity or performing target staging as part of
  this change.

## Considered approaches

### 1. Transition-bound prior snapshot (selected)

`prepare-new` validates the live file against the accepted artifact's retained
prior file, snapshots it into accepted-transition storage, and records its
existence and digest in a new transition schema. Generic stage must match the
live file and its own captured backup to that authority.

This is the smallest complete authority boundary. It protects the interval
between prepare and stage, composes with the existing generic rollback path,
and does not change the accepted receipt consumed by Plane Radar.

### 2. Upgrade the accepted receipt

A new receipt schema could permanently record prior-tryboot identity. This is
stronger as a long-term data model, but it requires a legacy migration plus
coordinated Plane Radar parser, fixture, doctor, and release-contract changes.
Those changes do not improve the immediate prepare-to-stage authority once a
transition snapshot exists, so they are out of scope.

### 3. Caller-supplied digest or manual file parking

The controller could supply a digest, or an operator could temporarily move
the file. Neither proves the file belongs to the accepted state, and manual
parking bypasses lifecycle rollback. This approach is rejected.

## Authority model

The new path is valid only for `prepare-new`; retained transitions keep their
current contract.

The transition adds a schema that extends schema 4 with:

```text
prior_tryboot_existed=true|false
prior_tryboot_sha256=<lowercase SHA-256>|none
```

When `prior_tryboot_existed=true`, the durable companion file is:

```text
/var/lib/hyperpixel2r-kms/accepted-transition-prior-tryboot.txt
```

It must be a root-owned, mode-0600, regular non-symlink file whose digest
equals `prior_tryboot_sha256`. When existence is false, the digest must be
`none` and the companion must be absent and non-symlink.

The schema-4 transition remains readable for existing clean transitions and
retained flows. Every newly prepared accepted replacement emits the extended
schema, recording either exact prior-file authority or exact absence. Older
schemas never infer this authority.

## Prepare-new flow

Before allocating or publishing transition state:

1. Validate the accepted receipt and exact accepted artifact as today.
2. Resolve the accepted artifact only from the receipt's driver version,
   source revision, and kernel release.
3. Inspect the live tryboot path with link-first checks.
4. If the live file is absent, require the accepted artifact's
   `prior-tryboot.txt` to be absent. Record `false` and `none`.
5. If the live file exists, require it to be regular, non-symlink, root-owned,
   and in the existing allowed boot-file mode set. Require the accepted
   artifact to contain a root-owned mode-0600 regular non-symlink
   `prior-tryboot.txt`. Require byte equality and equal SHA-256 digests.
6. Snapshot the live file into the private transaction workspace and recheck
   its digest and equality before publication.

Publication remains write-ahead: publish the prior normal-config companion,
then the optional prior-tryboot companion, then the complete transition journal
last. The journal is the mutation authority. If publication stops before the
journal, accepted recovery may remove companion files only after validating
their exact safe path, type, ownership, mode, and relationship. It never acts
on an unvalidated orphan.

## Stage binding

Before generic stage performs its first active mutation for an accepted-bound
candidate, it must validate the prepared transition and then prove:

- live tryboot existence matches `prior_tryboot_existed`;
- when present, the live file matches the transition digest and durable
  companion byte-for-byte;
- when absent, neither live file nor companion exists;
- candidate identity, manifest, module, overlay, rule, normal config, and DKMS
  facts still match existing transition authority.

Generic stage continues to create its ordinary `prior-tryboot.txt` artifact
and `tryboot-state` fields. Before candidate publication, that captured backup
must match the accepted-transition companion and digest. This closes the
prepare-to-stage time-of-check/time-of-use gap.

After stage publishes the candidate tryboot file and state, the accepted
transition advances to `staged` only if the generic transaction records the
same prior existence/digest. A mismatch fails before phase advancement and is
handled by existing transaction compensation.

## Phase invariants and cleanup

- `prepared`: the live prior tryboot file and durable companion must match the
  recorded prior authority.
- `staged` has exactly two valid substates. Before generic commit, generic state
  and its artifact prior backup must match the accepted-transition prior
  authority, the live tryboot file must be the exact candidate, and normal config
  must still match `prior_normal_config_sha256`. After generic commit but before
  `mark-committed-accepted`, generic state must be absent, the live exact prior
  file or absence must be restored, and normal config must byte-match an exact
  accepted-normal candidate derived in a private workspace from
  `accepted-transition-prior-config.txt`: surgically remove the prior accepted
  overlay declaration, then append the generic commit's exact accepted-candidate
  comment and candidate overlay declaration. `mark-committed-accepted` publishes
  the derived live digest into `candidate_normal_config_sha256` while advancing
  the phase. Mixed states, including state absent with prior normal config, state
  present with restored prior, or any foreign/comment drift from the derived
  normal candidate, are invalid.
- `committed`, `verified`, `finalizing`, and `receipt_published`: generic commit
  must already have restored the exact authorized prior file (or exact
  absence), and every accepted operation revalidates that fact.

Accepted recovery uses the generic rollback transaction whenever generic
state exists. It then verifies exact prior restoration before retiring the
candidate and accepted transition. Recovery of a merely prepared transition
does not rewrite the live file; it verifies the prior is unchanged and removes
only the validated journal companions.

Finalization removes the prior-tryboot companion only after the new accepted
receipt is durably published and the prior file is still exact. Interrupted
finalization remains resumable through the existing phase machine.

No path manually deletes a previously authorized prior tryboot file. Exact
absence is used only when the transition recorded absence.

## Error handling and security

Every new check fails closed before later mutation. Errors remain fixed and do
not echo file contents. The implementation reuses existing link-first regular
file, ownership, mode, private workspace, snapshot, checksum, atomic-copy, and
exact-path helpers. It never accepts caller-controlled paths or basenames.

The accepted artifact and transition companions are validated independently;
matching two unsafe or symlinked paths is never sufficient. Drift after
prepare, replacement between stage checks, incomplete companion publication,
and unauthorized orphan files all stop the operation without weakening the
existing recovery authority.

## Tests

Executable lifecycle fixtures must establish a real prior file through the
ordinary generic stage/commit/accepted-record path, then cover:

- absent prior remains accepted and restores absence;
- exact accepted prior permits `prepare-new` and publishes the new authority;
- unrelated ambient file, byte drift, symlink, non-regular file, ownership
  drift, mode drift, missing accepted backup, backup drift, duplicate keys,
  unknown keys, malformed booleans, and malformed digests are rejected;
- drift between prepare and stage is rejected before candidate mutation;
- stage captures the exact authorized prior bytes and state fields;
- every existing stage interruption restores the exact prior bytes;
- prepared recovery validates and clears only exact companions;
- staged recovery restores exact bytes and clears journals/candidate state;
- commit restores exact bytes before accepted `mark-committed` succeeds;
- interruption and retry across commit, mark-verified, and finalization keep
  the exact prior file;
- orphan companion publication is either safely recoverable or rejected
  without deleting unproven data;
- existing schema-4/absent, retained, uninstall, and legacy recovery fixtures
  remain unchanged and green.

The full driver verification suite must pass before target execution resumes.

## Deployment consequence

This change only repairs lifecycle authority. After review and verification,
Task 12 restarts its source gate from the new durable driver branch tip, rebuilds
all target-bound artifacts from that tip, and repeats the read-only hard
checkpoint before any boot selection or staging. No existing artifact from the
older driver tip is eligible for deployment.
