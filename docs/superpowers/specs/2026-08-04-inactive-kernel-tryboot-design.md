# Inactive-kernel tryboot design

## Problem

The driver lifecycle currently treats the target's running kernel as the only
kernel that can be staged. `stage-tryboot.sh` derives the artifact release from
remote `uname -r`, and its generated `tryboot.txt` changes only the display
overlay. The kernel and initramfs still come from the conventional normal-boot
files.

That contract is safe for a same-kernel driver replacement, but not for a
driver candidate built for a newly installed, inactive kernel. Selecting the
new kernel before staging its matching module creates an unsafe gap: normal
boot can load the new kernel with the accepted driver's old overlay but without
a matching module. On a constrained target this produced a persistent
VC4/HDMI/udev bind loop, loss of remote responsiveness, and watchdog resets.
The target recovered only after the conventional boot pair was restored to the
accepted kernel and the prepared lifecycle transaction was recovered there.

A production-quality tryboot must therefore select a coherent candidate kernel,
initramfs, module, and overlay while leaving the complete accepted normal boot
as the fallback.

## Goals

- Stage a driver for an installed but inactive candidate kernel while the
  accepted kernel remains running and the display remains healthy.
- Make one-shot tryboot select a coherent candidate kernel, initramfs, module,
  and overlay without changing the accepted normal boot.
- Preserve a real automatic fallback: failed tryboot returns to the exact
  accepted kernel, initramfs, config, overlay, and prior tryboot authority.
- Promote a verified candidate without ever making a mismatched conventional
  kernel/initramfs pair active.
- Bind all boot files, target-export provenance, driver artifacts, and config
  forms into durable lifecycle authority before mutation.
- Recover exactly and resumably from every publication, reboot, promotion,
  normalization, receipt, and cleanup boundary.
- Keep same-kernel staging as the default behavior and preserve existing
  receipts, retained transitions, uninstalls, and public release contracts.
- Keep the hardware watchdog enabled and remove the state mismatch that caused
  resets rather than weakening watchdog protection.

## Non-goals

- A general-purpose remote kernel installer or package manager.
- Staging an arbitrary kernel supplied by a caller.
- A bare `--kernel-release` escape hatch on generic stage.
- Building or installing kernel headers on the target.
- Supporting a candidate whose base board DTB or shared VC4 overlay differs
  from the active target files. Such a target requires a future coherent
  `os_prefix` boot bundle and must fail closed here.
- Changing firmware, EEPROM, watchdog configuration, boot partitions, command
  line files, or `autoboot.txt`.
- Deploying the Plane Radar application or publishing a public driver package
  as part of this design change.

## Considered approaches

### 1. Candidate-specific kernel and initramfs selected by tryboot (selected)

Stage deterministic candidate-only kernel and initramfs leaves on the firmware
partition. The generated tryboot configuration explicitly selects those files
and the candidate overlay. Normal config and the conventional accepted boot
pair remain unchanged until tryboot succeeds.

This is the smallest complete solution for the observed target because its
active base board DTB and shared VC4 overlay are byte-identical across the
accepted and candidate kernel packages. It provides a real fallback without
copying an entire boot filesystem namespace.

### 2. Complete `os_prefix` boot bundle

Stage a separate namespace containing the kernel, initramfs, command line,
board DTBs, every referenced overlay, and `overlays/README`, then select it with
`os_prefix` during tryboot. This provides stronger isolation and is the correct
future path when candidate DTBs or shared overlays differ.

It is rejected for this change because it substantially expands artifact,
firmware, and rollback scope without improving the current byte-identical-DTB
case.

### 3. Select the candidate as normal, then stage its driver

This preserves the current controllers but removes the accepted fallback and
recreates the proven kernel/module mismatch. It is rejected.

### 4. Add only a candidate-release controller flag

The remote stage primitive can install a module for an explicit release, but
tryboot would still use the normal kernel. The candidate would either boot the
wrong kernel or require changing normal boot first. This incomplete override is
rejected.

## Firmware contract

Raspberry Pi firmware supports an explicit `kernel=<file>` selection and an
explicit `initramfs <file> followkernel` directive. The latter deliberately
uses whitespace rather than `=`. Configuration entries have a 98-character
limit. See the official Raspberry Pi `config.txt` documentation:

<https://www.raspberrypi.com/documentation/computers/config_txt.html>

Inactive-kernel staging requires the accepted normal configuration to have a
supported, unambiguous shape:

- exactly one active `auto_initramfs=1`;
- no active `kernel=`, `initramfs`, `ramfsfile=`, `ramfsaddr=`, `os_prefix=`,
  or `overlay_prefix=` override;
- no `autoboot.txt`;
- exactly one accepted display overlay declaration and exactly one shared VC4
  overlay declaration;
- no active `include` directive;
- every boot-selection and display-overlay directive changed by this workflow
  is either before the first conditional section or inside `[all]`. Other
  conditional sections may remain only when they do not define those keys.

The candidate tryboot copy removes the active `auto_initramfs=1` line, removes
the accepted display overlay declaration, resets parsing to `[all]`, and
appends exactly:

```text
# hyperpixel2r-kms one-shot inactive-kernel candidate
kernel=<candidate-kernel-basename>
initramfs <candidate-initramfs-basename> followkernel
dtoverlay=<candidate-overlay-basename>
```

Every generated line is length-checked before publication. The normal config
is unchanged while tryboot is pending.

Candidate firmware basenames are deterministic and short:

```text
hp2r-<revision12>-<release-tag12>-kernel.img
hp2r-<revision12>-<release-tag12>-initramfs.img
```

`release-tag12` is the first 12 lowercase hexadecimal characters of SHA-256
over the exact candidate kernel-release UTF-8 bytes with no trailing newline,
equivalent to hashing `printf %s "$release"`. Controller and target derive it
independently. Callers never supply a firmware pathname.

## Terminology and invariants

- **Running release**: the kernel returned by the fresh remote `uname -r`.
- **Accepted release**: the kernel named by the accepted driver receipt.
- **Candidate release**: the explicit kernel release bound to the candidate
  target export and driver artifact.
- **Conventional pair**: `/boot/firmware/kernel8.img` and
  `/boot/firmware/initramfs8` for the supported 64-bit Zero 2 W target.
- **Candidate pair**: the deterministic candidate-only firmware leaves.
- **Explicit candidate config**: a config that selects the candidate pair and
  candidate overlay by name.
- **Normalized candidate config**: the final config that restores
  `auto_initramfs=1`, contains no explicit kernel/initramfs override, and selects
  the candidate overlay.

The core invariant is that every boot-visible config selects one complete,
hash-bound pair:

- accepted normal config selects the accepted conventional pair;
- tryboot and explicit normal candidate config select the candidate pair;
- normalized candidate config selects the candidate conventional pair.

No phase may make a mixed conventional pair active.

## Authority model

Angle-bracketed values in the schema and configuration examples below are
required typed metavariables defined by the surrounding text, not unresolved
design placeholders.

### Existing schemas

Accepted receipt schemas 1-3, accepted transition schemas 2-5, retained
transition schema 4, generic tryboot-state schemas 1-4, uninstall journals, and
release manifests remain readable with their current meaning. No older schema
infers inactive-kernel authority.

Same-kernel preparation and staging continue to use the existing path and do
not allocate boot-pair snapshots.

### Inactive-kernel accepted transition

A newly prepared inactive-kernel replacement uses accepted-transition schema
6. It extends the schema-5 new-candidate authority with:

```text
boot_transition=inactive-kernel
prior_normal_kernel_sha256=<sha256>
prior_normal_initramfs_sha256=<sha256>
candidate_kernel_file=<deterministic basename>
candidate_kernel_sha256=<sha256>
candidate_initramfs_file=<deterministic basename>
candidate_initramfs_sha256=<sha256>
candidate_base_dtb_sha256=<sha256>
candidate_vc4_overlay_sha256=<sha256>
explicit_normal_config_sha256=<sha256-or-pending>
normalized_normal_config_sha256=<sha256-or-pending>
```

The existing `candidate_kernel_release`, driver manifest, module, overlay,
backlight rule, prior normal config, candidate tryboot config, prior DKMS, and
prior tryboot fields remain authoritative.

Schema 6 is valid only for `kind=new`. Retained candidates remain schema 4.

### Private transition companions

Before the transition journal is published, prepare creates four root-owned,
mode-0600, regular non-symlink companions:

```text
/var/lib/hyperpixel2r-kms/accepted-transition-prior-kernel.img
/var/lib/hyperpixel2r-kms/accepted-transition-prior-initramfs.img
/var/lib/hyperpixel2r-kms/accepted-transition-candidate-kernel.img
/var/lib/hyperpixel2r-kms/accepted-transition-candidate-initramfs.img
```

Each companion must match its journal digest. The prior companions snapshot the
currently selected conventional pair. The candidate companions snapshot the
exact retained package sources validated by the target export. Package updates
or path replacement after prepare cannot change transition authority.

Publication is write-ahead: publish all validated companions, then publish the
complete journal last. Orphan handling may delete companions only after proving
their exact type, ownership, mode, digest, relationship to unchanged live
state, and absence of a conflicting journal. Uninstall refuses to start while
any transition companion exists or is a symlink.

### Generic tryboot state

Cross-kernel generic stage uses tryboot-state schema 5. It extends schema 4
with the boot transition, candidate firmware names and hashes, prior
conventional-pair hashes, and exact accepted-transition digest. Generic stage
must prove those fields against schema 6 before its first mutation and again
before advancing the accepted phase.

### Accepted receipt

Successful inactive-kernel finalization publishes accepted-receipt schema 4,
extending schema 3 with:

```text
normal_kernel_file=kernel8.img
normal_kernel_sha256=<sha256>
normal_initramfs_file=initramfs8
normal_initramfs_sha256=<sha256>
base_dtb_sha256=<sha256>
vc4_overlay_sha256=<sha256>
```

This records the final conventional boot identity. Same-kernel flows may keep
their current receipt schema. Plane Radar's provenance parser must accept
schema 4 without treating boot hashes as public release identity.

## Target-bound provenance

The product and driver controllers split running and candidate releases. An
inactive candidate is accepted only when all of the following agree:

- explicit candidate release requested by the accepted lifecycle;
- retained target-export manifest for that release and exact target identity;
- candidate driver manifest kernel release, architecture, vermagic, base DTB,
  module, applied DTB, overlay, and rule digests;
- root-owned regular retained package kernel and initramfs sources;
- installed candidate `/lib/modules/<release>` tree and module-resolution
  metadata;
- active firmware base board DTB and shared VC4 overlay digests.

The running release must equal the accepted receipt release during prepare and
stage. The candidate release must differ. A same-release request uses the
existing path.

The active board DTB and VC4 overlay must byte-match the candidate target
export. A mismatch fails with a fixed diagnostic requiring future full-bundle
support. This design never silently copies or substitutes shared DTBs.

No controller may reuse facts captured before a reboot. Tryboot, normal-candidate,
and normalized-candidate verification each perform a fresh target probe.

## Prepare flow

Inactive-kernel `prepare-new` performs no active boot or driver mutation:

1. Validate the accepted receipt, accepted artifact, installed accepted module,
   accepted config, accepted conventional pair, prior tryboot authority, and
   clean lifecycle state.
2. Require the running release to equal the accepted release.
3. Validate the explicit candidate target export, driver artifact, retained
   package kernel/initramfs sources, installed module root, base DTB, and shared
   VC4 overlay.
4. Require package-manager, initramfs, kernel-hook, DKMS, lifecycle, and boot
   selector writers to be absent.
5. Prove sufficient space on the private state filesystem and firmware
   filesystem for all snapshots, staged leaves, temporary copies, and safety
   overhead.
6. Snapshot and revalidate the prior conventional pair and candidate package
   pair into a private workspace.
7. Derive both explicit and normalized config forms privately and validate
   their syntax, directives, overlays, cardinality, and line lengths.
8. Publish the four boot companions, existing config/tryboot companions, and
   complete schema-6 journal last.

Preparation fails closed if any source, destination, package fact, config fact,
or target-export fact changes during capture.

## Cross-kernel stage flow

The accepted lifecycle, not generic callers, authorizes cross-kernel staging.
The controller accepts an explicit candidate release only when an exact
schema-6 prepared transition already binds it. A bare generic override remains
unsupported.

Stage:

1. Revalidate schema 6, all companions, accepted live state, running accepted
   release, target export, package sources, writer absence, and free space.
2. Publish the deterministic candidate kernel and initramfs leaves atomically
   from the private candidate companions. Existing exact leaves may be reused
   only when their full authority matches; foreign or drifted leaves fail
   closed.
3. Install the candidate module under `/lib/modules/<candidate>/extra`, the
   candidate overlay, and the exact backlight rule.
4. Materialize and register the candidate DKMS source using the existing
   inventory-bound rollback protocol.
5. Run `depmod -a <candidate>` and require `modinfo -k <candidate>` to resolve
   the exact staged module and vermagic. Never load or probe the candidate
   module while the accepted kernel is running.
6. Publish the explicit tryboot config and schema-5 generic state.
7. Advance accepted transition from `prepared` to `staged` only after generic
   state, firmware leaves, module, overlay, rule, DKMS inventory, prior config,
   and prior tryboot binding all revalidate.

Normal config and the accepted conventional pair remain byte-identical
throughout stage.

## Tryboot and verification

The controller requests only the firmware's one-shot tryboot reboot. A bounded
reconnect must prove:

- target identity and host-key continuity;
- changed boot ID and firmware tryboot mode;
- running kernel equals the candidate release;
- loaded module path, digest, version, and vermagic equal the candidate;
- candidate overlay is active exactly once;
- KMS card, render node, DPI connector, touch, and backlight capability are
  healthy;
- Plane Radar is active without restart churn;
- lifecycle state and candidate firmware leaves remain exact;
- power, storage, watchdog, and kernel health evidence is clean.

If tryboot fails, firmware returns to the unchanged accepted normal config and
accepted conventional pair. Recovery then runs on the accepted kernel. It
never requires a bare candidate normal boot.

## Safe promotion and normalization

Directly replacing conventional initramfs and kernel files creates a transient
mixed-pair risk. Promotion therefore uses the already staged explicit candidate
pair as an atomic selection boundary.

### Phase 1: explicit normal candidate

After verified tryboot, commit atomically publishes the exact explicit
candidate config as normal `config.txt`. The conventional pair remains the
accepted pair and is not selected by this config.

The accepted transition advances durably through `staged` to
`explicit_normal_published`. A normal reboot must then prove the candidate
kernel, module, overlay, KMS, input, backlight, service, and unchanged lifecycle
authority. A mark action advances to `explicit_normal_verified`.

At every point, the normal config selects either the prior conventional pair or
the complete candidate-specific pair. There is no mixed active pair.

### Phase 2: inactive conventional-pair normalization

While normal boot remains pinned to the explicit candidate pair:

1. Copy the candidate initramfs companion to conventional `initramfs8`, sync
   the firmware filesystem, and verify the exact digest. Advance to
   `canonical_initramfs_published`.
2. Copy the candidate kernel companion to conventional `kernel8.img`, sync,
   and verify both conventional digests. Advance to
   `canonical_pair_published`.
3. Atomically publish the normalized candidate config, which restores
   `auto_initramfs=1`, removes explicit kernel/initramfs directives, and keeps
   the candidate overlay. Advance to `normalized_config_published`.

The explicit config keeps the partially written conventional pair inactive
until both files are complete and verified.

A second normal reboot must prove conventional selection of the candidate pair,
candidate runtime health, and exact lifecycle authority. The final mark action
advances to `normalized_verified`.

### Phase 3: receipt and cleanup

Finalization:

1. Revalidates the normalized config, conventional pair, running candidate,
   module, overlay, rule, DKMS, target DTB, VC4 overlay, and prior tryboot
   restoration.
2. Publishes accepted-receipt schema 4.
3. Retires the prior accepted artifact under existing accepted-transition
   authority.
4. Removes candidate-specific firmware leaves and all boot-pair/config
   companions only after proving the conventional pair and receipt contain the
   same candidate identity.
5. Clears the transition journal last.

Finalization is retryable after every interruption.

## Recovery by phase

Recovery never guesses from ambient filenames. It validates journal-bound
names and hashes, exact companion authority, and the currently selected config
before mutation.

- `prepared`: normal boot is unchanged. Remove only validated orphan/staged
  authority and companions.
- `staged`: use generic rollback to remove the candidate module, overlay, rule,
  DKMS changes, tryboot state, and exact candidate firmware leaves; restore the
  prior tryboot file or absence.
- `explicit_normal_published` or `explicit_normal_verified`: the conventional
  pair is still the accepted pair. Atomically restore the prior normal config,
  reboot if necessary, verify the accepted runtime, then retire candidate
  state.
- `canonical_initramfs_published`, `canonical_pair_published`, or
  `normalized_config_published`: keep the explicit candidate config active
  while restoring both conventional files from the private prior companions,
  verifying the pair, and only then atomically restore prior normal config.
- `normalized_verified`, `finalizing`, or `receipt_published`: reconcile the
  receipt and artifacts according to the existing write-ahead rules. Before a
  new receipt is authoritative, recovery restores the full prior pair and
  config. After the candidate receipt is durably authoritative, retry completes
  candidate finalization rather than resurrecting the prior receipt.

Any drift, missing companion, symlink, unsafe type/owner/mode, unexpected
config form, ambiguous module resolution, or unbound firmware leaf leaves the
state intact and fails closed.

## Service and watchdog behavior

The product orchestration stops Plane Radar during normal-config promotion,
conventional-pair normalization, and recovery mutation. It does not disable or
mask the unit. It verifies no process, restart job, or changing restart count
before boot writes and relies on the normal enabled unit after reboot.

The hardware watchdog remains configured and active. Reconnect and stability
gates span longer than the target's watchdog envelope and require an unchanged
boot ID, stable service restart count, clean power evidence, normal watchdog
refresh, and absence of VC4/HDMI/udev bind storms.

The lifecycle must not boot an inactive kernel merely to build or stage its
driver. A candidate whose artifacts cannot be validated from the retained
target export stays unstageable.

## Error handling and security

- All caller-supplied releases, revisions, and target identities use the
  existing strict validators. Firmware basenames are derived, never supplied.
- Link-first checks precede every file read, copy, comparison, or removal.
- Private companions are root-owned mode 0600; firmware leaves and installed
  artifacts use their exact existing boot/module modes.
- Every copy is snapshot-based, digest-checked, same-filesystem published where
  required, and revalidated after publication.
- Publication journals are written last; cleanup journals or durable phases are
  written before destructive retirement.
- Package-manager, kernel-hook, initramfs, DKMS, lifecycle, and selector
  concurrency is rejected before boot mutation.
- Space checks include source files, snapshots, temporary atomic copies, and a
  fixed safety margin. No phase relies on a partial copy succeeding.
- Errors use fixed diagnostics and never echo configuration contents, private
  target names, usernames, serials, or file contents.
- Existing public artifact manifests and release packages do not contain
  target-specific kernel images or initramfs files. Boot companions are private
  target state only.

## Product integration

Plane Radar's driver model separates running release from candidate release:

- discovery and health continue to describe the fresh running release;
- resolver may select an exact retained target export and artifact for an
  installed inactive release;
- accepted prepare and stage carry the explicit candidate release;
- same-kernel tools keep their current defaults;
- post-reboot verification discards cached context and constructs a new context
  from fresh target facts;
- schema-4 receipt parsing exposes candidate boot provenance to doctor/status
  without changing public driver version semantics.

Cross-kernel behavior is available only through the accepted replacement
workflow. Generic `stage-tryboot.sh` may accept the candidate release only when
it can prove the matching schema-6 transition; otherwise it rejects the
override before upload.

## Tests

### Controller and product tests

- Running accepted release plus explicit different candidate release selects
  the candidate target export and artifact.
- Missing explicit release never falls back to an inactive artifact.
- Wrong target identity, export digest, architecture, vermagic, base DTB, VC4
  overlay, kernel, or initramfs rejects before upload.
- Product prepare/stage carries separate running and candidate releases and
  refreshes facts after every reboot.
- Same-kernel behavior and existing resolver precedence remain unchanged.
- Schema-4 accepted receipt parsing, doctor, status, and provenance tests pass.

### Executable lifecycle fixtures

- Stage a candidate release while fixture `uname` reports the accepted release;
  prove no candidate module load or modprobe occurs.
- Prove exact candidate module installation, `depmod`/`modinfo` resolution,
  deterministic firmware leaves, explicit tryboot directives, and unchanged
  normal config/conventional pair.
- Simulate successful candidate tryboot and failed tryboot returning to exact
  accepted normal boot.
- Cover every interruption after each companion, journal, candidate kernel,
  candidate initramfs, module, overlay, rule, DKMS, tryboot, state, phase,
  explicit normal config, conventional initramfs, conventional kernel,
  normalized config, receipt, artifact retirement, companion cleanup, and
  journal cleanup publication.
- Recover every phase and prove byte-exact prior kernel, initramfs, config,
  tryboot, module, overlay, rule, DKMS, and receipt restoration.
- Retry every forward phase and finalization after interruption.
- Reject missing files, insufficient space, symlinks, directories, FIFOs,
  ownership/mode drift, hash drift, duplicate or conflicting boot directives,
  overlong firmware lines, non-deterministic names, stale exports, active
  writers, and unrelated ambient firmware files.
- Prove exact existing candidate leaves may be reconciled only when bound by
  the same journal; mismatched or orphan leaves remain intact and fail closed.
- Keep schema-1 through schema-5, retained, uninstall, accepted-prior-tryboot,
  and same-kernel interruption matrices green.

### Physical acceptance

Physical execution starts again from a clean accepted kernel:

1. Re-run complete source verification and target preflight.
2. Prepare and stage the inactive candidate while the accepted kernel is
   running and healthy.
3. Tryboot the candidate kernel/module/overlay bundle and verify objective
   display, touch, backlight, service, watchdog, and provenance evidence.
4. Exercise supported recovery and prove automatic return to the accepted
   kernel with exact cleanup.
5. Reprepare and restage, tryboot again, publish explicit normal candidate,
   normal-reboot verify, normalize the conventional pair, normal-reboot verify,
   publish the receipt, and finalize.
6. Deploy the exact reversible Plane Radar application candidate.
7. Run objective brightness, schedule, red-mode, restart, reboot, touch, KMS,
   doctor, smoke, and provenance acceptance while restoring owner settings and
   temporary test state.

Subjective panel qualities remain an owner checklist: visible 5/30/100
brightness distinction, flicker, red-mode legibility, touch response, and no
perceived brightness flash.

No push, tag, public release, or public package is part of physical acceptance.
