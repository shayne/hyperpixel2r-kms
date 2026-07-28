# Source provenance

`hyperpixel2r-kms` is a clean, standalone driver implementation for the
HyperPixel 2.1 Round hardware. It is GPL-2.0-only; the complete license text is
in [`LICENSE`](../LICENSE).

## Upstream starting point

The panel command sequence and associated display behavior were studied from
Raspberry Pi Linux commit
[`33bb14b06b3fb5a682d4a7a3db3963fe558fc6f9`](https://github.com/raspberrypi/linux/blob/33bb14b06b3fb5a682d4a7a3db3963fe558fc6f9/drivers/gpu/drm/panel/panel-sitronix-st7701.c),
in `drivers/gpu/drm/panel/panel-sitronix-st7701.c`. The relevant upstream notice
is retained in the driver source:

```text
Copyright (C) 2019, Amarula Solutions.
Author: Jagan Teki <jagan@amarulasolutions.com>
```

The GPIO protocol, KMS integration, build tooling, exact-kernel validation,
and tryboot lifecycle here are project-local work. They are not copied from an
application repository and this repository carries no application code.

## Release provenance

Each release manifest binds the semantic driver version to its full Git commit,
Git tree, source-date epoch, deterministic archive layout, and SHA-256 digests.
GitHub Actions builds and attests published release files. A matching exact
kernel bundle includes the module, overlay, module metadata, checksum evidence,
and DTB application result.

The release contract validates `driver-manifest.json` with Draft 2020-12 JSON
Schema and validates the SPDX 2.3 document with the official SPDX Python tools.
`release/validator-requirements.in` names the two validator versions;
`release/validator-requirements.txt` is the complete transitive SHA-256 lock.
The installer uses pip's isolated hash-checking mode with dependency resolution
disabled, so a missing or changed wheel is a failure rather than an opportunity
for pip to improvise.  Regenerate that lock with
`./scripts/lock-release-validators.sh`; its wheel-only, hash-locked
`pip-tools` bootstrap keeps the maintenance path reproducible on macOS and
Linux. The boring part is the point: JSON that looks plausible is not the same
thing as metadata another tool can actually consume.

The release process uses a pinned Debian Trixie Slim OCI image digest for the
cross-build container. Tags move; digests do not. Kernel source packages and
the Pi's exported headers remain explicit inputs, checked by digest before the
module build starts.

Consumers should verify both the checksums and the GitHub attestation before
using a release artifact:

```sh
sha256sum -c SHA256SUMS
gh attestation verify hyperpixel2r-kms-source.tar.zst -R shayne/hyperpixel2r-kms
```
