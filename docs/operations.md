# Operating the driver

The dangerous part of a display driver is not compiling it. It is discovering
that a perfectly good module makes the next boot unpleasant. This repository
therefore treats a new driver as a one-boot candidate first. Normal
`config.txt` stays put until the candidate proves it can draw, accept touch,
and start an SDL OpenGL ES 2 client.

The commands below assume a Mac has built an exact-kernel artifact bundle and
can already reach the Pi through OpenSSH. `HP2R_TARGET` is deliberately an
input. It is not a hidden default pretending every network looks alike.

```sh
export HP2R_TARGET=pi@raspberrypi.local
mise run check-artifacts
mise run stage-tryboot
```

`stage-tryboot` materializes the DKMS source from the artifact manifest's
committed source revision, then copies the verified module, overlay, complete
manifest, and source tree to versioned driver-owned locations on the Pi. It
snapshots normal config, writes a candidate `tryboot.txt`, saves any older
`tryboot.txt`, records a root-owned `0600` transaction state file, and requests
one one-shot tryboot reboot. If any stage step fails, it restores the previous
tryboot file and removes every new candidate leaf, source tree, DKMS
registration, artifact, and state file. Normal boot config is never rewritten
by a trial.

Before candidate publication, staging requires a root-owned non-symlink
kernel-module directory chain and verifies that `depmod` selects the exact
manifest `/extra` leaf. Compressed installed modules are decoded only through
a private root-owned workspace with an 8 MiB output ceiling; overflow,
truncation, or decoder failure stops staging.

If normal config already names a different HyperPixel overlay, name that exact
overlay explicitly. `--replace-overlay` parses declarations by overlay name,
including parameters, and rejects zero, multiple, unsafe, or conflicting
matches. It never leaves both display overlays in the candidate.

```sh
mise run stage-tryboot -- --replace-overlay existing-overlay-name
```

Supervising installers must separate staging from reboot so their own durable
transaction record cannot lose a race with SSH disappearing. They can publish
the verified candidate without rebooting:

```sh
mise run stage-tryboot -- --stage-only
```

That mode leaves the same root-owned driver transaction and `tryboot.txt` in
place. It does not boot the candidate. The supervising installer must first
persist its staged phase, then request exactly one `reboot '0 tryboot'`, wait
for SSH to return, and continue with verification. The ordinary command still
stages and requests the reboot itself.

After the Pi reboots and SSH returns, inspect the candidate with the
machine-readable check:

```sh
mise run verify-boot -- --json
```

The command derives its driver version from the loaded module metadata and
requires the live generic compatible binding, one connected 480×480 DRM
connector, an EDT/FT5 touch device, and a current-boot SDL readiness line for
KMSDRM with the OpenGL ES 2 renderer. It prints one JSON object with those
facts. A failed check is not a vote. Roll it back.

```sh
mise run rollback-boot
```

Rollback validates the private transaction state, complete stored manifest,
and checksum-proven regular candidate leaves before it changes anything. It
restores the pre-stage `tryboot.txt` and the exact pre-stage DKMS source tree.
It also restores a bounded, checksum-bound inventory of every kernel and
architecture for which that source was built or installed. This matters
because replacing a fixed DKMS package version uses `dkms remove --all`;
rollback rebuilds every captured row, not only the kernel that happened to be
running when staging began. Older scalar rollback records remain supported.

Rollback publishes a root-owned recovery journal before its first destructive
step. It moves the manifest-exact candidate module to the adjacent
`hyperpixel2r_kms.ko.hp2r-rollback-hold` name before restoring an installed
prior DKMS package. That filename is deliberately not a loadable module
suffix, so `depmod` cannot select it. This temporary hold is also used when the
same exact module leaf existed before staging; rollback restores that shared
leaf after DKMS installation. Each journal phase is synced before the next
operation.

An unexpected reboot during rollback is safe, but it leaves the rollback
unfinished. Rerun `mise run rollback-boot` after SSH returns. The command
validates the journal against the original transaction, accepts only the exact
before- or after-state of the interrupted operation, including exact tryboot
and overlay state, and resumes. If an ordinary operation failed, the same
journal records compensation; the next rollback invocation restores and
verifies the candidate, recaptures its live DKMS inventory, then retries the
requested rollback. Do not stage, commit, uninstall, or run an accepted
lifecycle action while this journal exists. Those commands refuse concurrent
authority.

The transaction records whether the module and overlay files already existed.
Rollback removes only files created by staging; exact files shared with the
prior normal boot stay in place. If there was no prior DKMS tree, it removes
the candidate tree. Normal config was left alone, so the known-good display
configuration gets another turn without reconstructing it from a
half-remembered command history.

Rollback deliberately leaves the validated stored transaction artifact in
place for `uninstall`; run `mise run uninstall` before staging another
candidate. That prevents an inactive artifact from being silently overwritten.

`commit-boot` uses the state recorded by staging to remove the one explicitly
selected old declaration and promote the generic candidate. It prepares all
replacement files before publishing normal config. If restoring `tryboot.txt`
or deleting transaction state fails, it compensates by restoring the old
normal config and candidate state.

```sh
mise run commit-boot
mise run uninstall
```

`uninstall` refuses while an owned generic overlay or active tryboot
transaction is present. It validates every stored release, full DKMS source
tree, and DKMS status line; removes only checksum-proven module and overlay
leaves; and runs `depmod` for every recorded kernel release. It does not tidy
unknown files for you. Unknown files are just state with better marketing.

## Recovering a legacy accepted-record workspace

`recover-record` is an explicit, one-time recovery command for the legacy
recorder workspace created by older tooling after it failed before publishing
an accepted receipt. Do not remove that workspace by hand. With the exact
installed tuple, run:

```sh
HP2R_TARGET=pi@YOUR_PI_HOST scripts/accepted-lifecycle.sh \
  --action recover-record \
  --driver-version VERSION \
  --source-revision REVISION \
  --kernel-release RELEASE
```

It refuses unless there is no tryboot, rollback, accepted receipt, transition,
or uninstall authority; the requested artifact, manifest, installed module,
installed overlay, and normal configuration exactly match; and there is zero
or one safe root-owned recorder workspace. If one workspace exists, it must
contain only a matching normal-config snapshot and a freshly re-derived stock
snapshot before the command removes that exact directory. It never publishes
an accepted receipt. A verified zero-workspace invocation is an idempotent
no-op. Run no other lifecycle command concurrently with recovery; serialize
the operator action so the pre-removal validation remains authoritative.

The application adapter also exposes a one-time product migration through the
same typed `Uninstall` action. That mode accepts only the shipped immutable
legacy manifest and an exact expected generic overlay. It refuses active
transactions, active or loaded legacy state, partial artifact sets, and any
source, overlay, metadata, or recovery-baseline drift. On success it preserves
the manifest and append-only result evidence below
`/var/lib/hyperpixel2r-kms/migrations/`; repeating the migration records a
no-op.
