# Durable Driver Recovery Design

## Problem

The RC17 physical tryboot exposed two lifecycle assumptions that the existing
fixtures did not model.

First, an exact eight-file DKMS source tree does not prove that the module
selected by `modules.dep` has the candidate manifest's bytes. The live Pi had
byte-identical prior and candidate source trees, so staging reused the prior
installed registration. The resolved compressed module differed from the
manifest-bound `/extra` candidate module.

Second, rollback restored an installed prior DKMS inventory before detaching
the transaction-owned candidate `/extra` module. Raspberry Pi OS DKMS refused
that ambiguous fixed-name collision. The compensating restore encountered the
same collision and left the schema-3 transaction live.

## Selected design

### Candidate activation

Staging must resolve `hyperpixel2r_kms` through the generated
`modules.dep`, decode `.ko`, `.ko.xz`, `.ko.zst`, or `.ko.gz` as required, and
compare the uncompressed bytes with the manifest module SHA-256.

An exact installed DKMS registration may be reused only when:

- its eight-file source shape equals the candidate source;
- the resolved module is an owned kernel leaf;
- its uncompressed SHA-256 equals the manifest module; and
- a fresh `depmod` still resolves that exact content.

When the source shape matches but the resolved bytes do not, staging captures
the complete prior DKMS inventory and source, removes the prior registration,
leaves the candidate source registered but not installed, runs `depmod`, and
requires resolution to the manifest-bound `/extra` module before publishing
`tryboot.txt` or transaction state.

### Durable rollback protocol

Rollback uses fixed root-owned non-symlink files:

- `/var/lib/hyperpixel2r-kms/rollback-state`
- `/var/lib/hyperpixel2r-kms/rollback-candidate-dkms-state`
- an adjacent same-filesystem module hold named
  `hyperpixel2r_kms.ko.hp2r-rollback-hold`

The hold name does not end in `.ko`, `.ko.xz`, `.ko.zst`, or `.ko.gz`, so
`depmod` cannot treat it as loadable.

The version-1 journal binds the active transaction SHA-256, driver version,
source revision, kernel release, manifest module and overlay identities,
candidate DKMS inventory SHA-256, hold path identity, and one of these durable
phases:

1. `prepared`
2. `candidate-held`
3. `prior-restored`
4. `boot-restored`
5. `depmod-verified`

It also records `mode=rollback` or `mode=compensate`. Every phase publication
is an atomic root-owned mode-0600 replacement followed by `sync`, before the
next destructive operation begins.

Each phase accepts only the exact before-state or exact after-state of its
operation. A crash between an operation and its phase update is therefore
distinguishable and replayable. The candidate module is moved atomically to
the adjacent non-loadable hold before prior DKMS restoration. A failure enters
durable compensation mode; compensation restores the candidate DKMS inventory,
candidate source, held module, overlay, tryboot config, and `depmod` resolution
before it clears the journal. A crash during compensation resumes
compensation.

Successful rollback restores and verifies the complete prior DKMS inventory,
restores the prior tryboot state, detaches only transaction-created module and
overlay leaves, runs `depmod`, verifies prior resolution where the inventory
requires an installed live-kernel module, then removes the active transaction
and durable rollback files.

### Compatibility and ownership

Transaction schemas 1, 2, and 3 remain accepted under their existing identity
rules. Schema-1 transactions keep their legacy leaf-ownership defaults.
Accepted receipt, retained transition, and accepted-uninstall behavior remains
unchanged. Stage, commit, uninstall, and accepted lifecycle actions reject an
unresolved rollback journal rather than creating concurrent authority.

## Verification

Executable fixtures must reproduce:

- the exact live schema-3 state with identical source trees but mismatched
  resolved installed bytes;
- exact resolved installed-byte reuse;
- prior installed restore with a manifest-exact `/extra` collision;
- interruption before and after every durable phase publication, module hold,
  DKMS restore, boot restoration, depmod verification, transaction removal,
  and compensation operation;
- a simulated reboot at every durable phase, followed by successful resume;
- malformed, symlinked, wrongly owned, or checksum-drifted journal, inventory,
  and hold files;
- transaction schema 1, 2, and 3 compatibility; and
- unchanged accepted lifecycle fixtures.

No Pi mutation is permitted until the feature stack passes focused and full
verification and receives independent review.
