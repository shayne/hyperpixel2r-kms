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
`tryboot.txt`, and records a root-owned `0600` transaction state file. If any
stage step fails, it restores the previous tryboot file and removes every new
candidate leaf, source tree, DKMS registration, artifact, and state file.
Normal boot config is never rewritten by a trial.

If normal config already names a different HyperPixel overlay, name that exact
overlay explicitly. `--replace-overlay` parses declarations by overlay name,
including parameters, and rejects zero, multiple, unsafe, or conflicting
matches. It never leaves both display overlays in the candidate.

```sh
mise run stage-tryboot -- --replace-overlay existing-overlay-name
```

After SSH returns, inspect the candidate with the machine-readable check:

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
restores the pre-stage `tryboot.txt`, the exact pre-stage DKMS source tree and
its registration state, then removes only candidate module and overlay leaves
before rebooting normally. If there was no prior DKMS tree, it removes the
candidate tree. The normal config was left alone, so the known-good display
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
