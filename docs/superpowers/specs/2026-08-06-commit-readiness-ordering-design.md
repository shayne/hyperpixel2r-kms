# Commit Readiness Ordering Design

## Context

`commit-boot.sh` currently runs the authoritative target `commit-probe` before
the live boot verifier. On a target with volatile journald storage, the probe's
large artifact and boot-pair validation can outlive the retained journal
window. The application emits its KMSDRM/OpenGL ES 2 readiness record when it
starts, so a healthy current boot can lose that record before `verify-boot.sh`
checks it. Promotion then fails before mutation even though the display service
and driver remain healthy.

The target is already staged and running the candidate in one-shot tryboot.
This change must not mutate or reboot that target until the controller fix has
passed review.

## Goals

- Verify current-boot renderer readiness before an expensive target proof can
  age the record out of volatile journald.
- Keep the existing authoritative `commit-probe` and the remote `commit`
  action as the mutation-boundary authorities.
- Fail closed if lifecycle intent, expected boot mode, candidate identity, or
  boot identity changes between live verification and authoritative proof.
- Preserve initial tryboot promotion and every supported inactive-kernel
  replay mode.

## Non-goals

- Re-emitting application readiness, changing journald retention, or persisting
  target logs.
- Weakening any target-side artifact, transaction, boot-pair, writer, or replay
  validation.
- Changing the public artifact format, release process, or product controller.
- Accessing, mutating, or rebooting the physical target during implementation
  or review.

## Selected design

Add a read-only `commit-intent-probe` action to `lifecycle-remote.sh`. It reads
only bounded lifecycle metadata, the small boot-selection files, the tryboot
flag, and `/proc/sys/kernel/random/boot_id`. It validates exact row cardinality,
field syntax, lifecycle-metadata ownership, deterministic overlay identity,
supported phase/mode combinations, and unambiguous replay workspace shape.
Boot-selection configs retain the authoritative probe's established contract:
non-symlink regular leaves bound by their exact recorded hashes, including the
supported root-owned mode-0600 case. The intent probe does not traverse or hash
the large artifact, DKMS, kernel, initramfs, or device trees that make
`commit-probe` expensive.

Both probes return the same strictly typed ten-field tab-separated tuple:

```text
<phase> <boot-mode> <driver-version> <overlay-file> <kernel-release> <module-file> <module-sha256> <retired-tryboot-existed> <retired-tryboot-sha256> <boot-id>
```

The first nine fields retain the existing commit-probe meanings. `boot-id` is
a lowercase canonical UUID read through a link-first regular-file check. The
authoritative probe captures it before validation and re-reads it afterward;
the probe fails if the boot changes while validation is in progress.

`commit-boot.sh` performs this sequence:

1. Run `commit-intent-probe`.
2. Parse the tuple using the existing strict allowlist plus canonical boot-ID
   validation. Construct verifier arguments only from this typed tuple.
3. Run the complete live `verify-boot.sh` immediately, including the current
   boot's renderer-readiness record.
4. Run the existing expensive authoritative `commit-probe`.
5. Parse it through the same strict contract and require byte-for-byte tuple
   equality with the intent tuple. This simultaneously binds lifecycle mode,
   verifier arguments, candidate identity, retired-tryboot identity, and boot
   identity.
6. Only then invoke the existing remote `commit` action. That action retains
   its full transaction, artifact, boot-pair, writer, and replay validation
   immediately before mutation.

The intent tuple is not authority to mutate. A syntactically valid but forged
intent can at most cause a read-only verifier attempt: unless the later full
probe returns exactly the same tuple, `commit` is never called. The verifier
cannot be weakened because every expected value remains mandatory, strictly
typed, and later bound to the full authoritative proof.

## Replay classification

The lightweight probe supports the same modes as the full probe:

- `tryboot:tryboot` for an ordinary staged transaction;
- `explicit-config-reconcile:{tryboot,normal}` when explicit normal config was
  published but the candidate tryboot file is still active;
- `explicit-reconcile:{tryboot,normal}` when explicit normal config and
  retired prior-tryboot state are published but the phase is still staged;
- `explicit-replay:{tryboot,normal}` once the explicit-normal phase is durable.

Classification requires one exact lifecycle state shape. Any ambiguous state,
hold, workspace set, boot selector, or small-config identity fails closed. The
authoritative probe independently recomputes the mode and complete identity.

## Tests

The focused executable fixture makes the fake current-boot readiness record
disappear as soon as `commit-probe` completes. Under the old ordering the
fixture fails at live verification; under the new ordering verification sees
the record before it expires and promotion succeeds.

Additional focused cases reject an authoritative tuple mismatch and a changed
boot ID without changing normal config, tryboot config, lifecycle state, or
accepted transition, and preserve the existing exact mode-0600 config contract.
Existing inactive interruption/replay fixtures exercise all supported modes.
The exhaustive boot gate and every remaining component of the repository's
`verify` aggregate must pass before a signed GitButler commit is offered for
independent review.
