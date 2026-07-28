# HyperPixel 2 Round KMS driver

This is a small, standalone DRM/KMS driver for one oddly specific piece of
hardware: a HyperPixel 2.1 Round on a Raspberry Pi Zero 2 W. That specificity
is not an accident. Display drivers are where a one-line configuration change
can turn into an evening with a serial console, so the project chooses one
known shape over a heroic compatibility matrix.

<!-- HP2R_CURRENT_RELEASE=v0.1.0-rc.10 -->

Current release: `v0.1.0-rc.10` is a release candidate. It has host-side build
and boot-lifecycle checks, reproducible source packaging, and signed GitHub
provenance. It is still a release candidate, which is a useful warning label:
the package can prove what it built, but it cannot make every future Raspberry
Pi kernel agree to run it.

## Supported shape

| Part | Supported value |
| --- | --- |
| Board | Raspberry Pi Zero 2 W |
| Display | Pimoroni HyperPixel 2.1 Round, 480×480 touch display |
| OS | Raspberry Pi OS Lite (Trixie, 64-bit) |
| Userland | `aarch64` |
| Kernel policy | An exact release match, or a local exact-kernel build |

This repository is an independent GPL driver project. It is not a fork,
submodule, or hidden component of an application project.

## The shortest safe path

Start on a Mac with Docker or OrbStack, OpenSSH access to the Pi, and
[mise](https://mise.jdx.dev/) available. The Pi needs a working network and
SSH login already; this project intentionally does not configure Wi-Fi or
users for you.

```sh
git clone https://github.com/shayne/hyperpixel2r-kms.git
cd hyperpixel2r-kms
mise install

export HP2R_TARGET=pi@raspberrypi.local
mise run export-target-kbuild
mise run build-driver
mise run check-artifacts
mise run stage-tryboot
```

`stage-tryboot` changes the next boot only. It does not overwrite the known
good boot configuration. Reboot the Pi once, then verify the candidate before
making anything permanent:

```sh
mise run verify-boot -- --json
# If the screen or touch is wrong:
mise run rollback-boot

# Only after the candidate has been checked:
mise run commit-boot
```

The recovery story is deliberately boring: if a candidate cannot boot, the
firmware clears tryboot and the next power cycle returns to the old boot path.
Do not promote a candidate because it merely compiled. Compilers are very
polite about helping you make a bad boot decision.

## Exact kernels and DKMS

Each release binds its source archive and any prebuilt bundle to a full source
commit, source tree, architecture, and kernel release. A prebuilt module is
accepted only when those facts, its vermagic, module metadata, overlay, and
applied-DTB evidence agree. Anything less is how “close enough” becomes a
display that is very close to not displaying.

The installed source supports DKMS for the normal Raspberry Pi OS maintenance
path. DKMS is not a guarantee that an arbitrary future kernel or display stack
is supported. If the exact-kernel checks cannot prove a match, build against
the running target kernel and use the one-boot trial.

See [compatibility](docs/compatibility.md) for the hard boundary and
[operations](docs/operations.md) for the boot lifecycle.

## Releases and verification

Release candidates contain a deterministic source archive,
`driver-manifest.json`, `SHA256SUMS`, and an SPDX 2.3 SBOM. A matching
exact-kernel archive is included only when the release workflow has verified a
complete bundle for that kernel. That distinction matters: a source release is
useful everywhere, while a module archive is only useful when its kernel facts
match the Pi in front of you. GitHub Actions creates provenance and SBOM
attestations for the published payloads.

```sh
gh release download v0.1.0-rc.10 -R shayne/hyperpixel2r-kms -D dist/v0.1.0-rc.10
cd dist/v0.1.0-rc.10
sha256sum -c SHA256SUMS
gh attestation verify hyperpixel2r-kms-source.tar.zst \
  -R shayne/hyperpixel2r-kms \
  --signer-workflow shayne/hyperpixel2r-kms/.github/workflows/release.yml
```

The source archive is the durable fallback. An exact archive is a convenience,
not a substitute for checking that the Pi in front of you still matches it.

## Provenance and license

The driver is GPL-2.0-only. Its panel initialization sequence is derived from
the upstream Raspberry Pi Linux ST7701 panel support; the source, notices, and
the practical limits of that derivation are in [provenance](docs/provenance.md).

The work has been developed with substantial AI assistance under human
direction. That explains authorship; it does not waive the need to inspect a
boot change, test the hardware, or take responsibility for a released driver.

## Development

```sh
mise run verify
```

That runs the protocol, GPIO, build-contract, boot-lifecycle, and release
contract tests. The release packager also runs two clean builds in CI so a
different archive is treated as a failure to explain, not as a cute property of
compression.
