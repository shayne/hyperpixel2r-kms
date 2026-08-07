# HyperPixel 2 Round KMS driver

This repository provides a standalone DRM/KMS driver for the Pimoroni
HyperPixel 2.1 Round on a Raspberry Pi Zero 2 W. It is tested with 64-bit
Raspberry Pi OS Lite Trixie and the exact kernel checks described below.

<!-- HP2R_CURRENT_RELEASE=v0.2.0-rc.1 -->

Stable release: [`v0.1.1`](https://github.com/shayne/hyperpixel2r-kms/releases/tag/v0.1.1).
The next candidate is `v0.2.0-rc.1`, which adds controlled PWM backlight
support and a hardened inactive-kernel lifecycle for Plane Radar.

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
good boot configuration. The command requests that one-shot reboot itself;
wait for SSH to return, then verify the candidate before making anything
permanent:

```sh
mise run verify-boot -- --json
# If the screen or touch is wrong:
mise run rollback-boot

# Only after the candidate has been checked:
mise run commit-boot
```

An installer that owns reboot and reconnect may pass `--stage-only`. That
publishes the same verified candidate and transaction state but keeps the Pi
online, giving the installer time to save its own durable phase before it asks
for the one tryboot reboot. For manual operation, use the normal command above.

If a candidate cannot boot, the firmware clears tryboot and the next power
cycle returns to the previous boot path. A successful build is not sufficient
for promotion; verify the display and touch hardware first.

## Exact kernels and DKMS

Each release binds its source archive and any prebuilt bundle to a full source
commit, source tree, architecture, and kernel release. A prebuilt module is
rejected when any of these values differ.

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
gh release download v0.2.0-rc.1 -R shayne/hyperpixel2r-kms -D dist/v0.2.0-rc.1
cd dist/v0.2.0-rc.1
sha256sum -c SHA256SUMS
gh attestation verify hyperpixel2r-kms-source.tar.zst \
  -R shayne/hyperpixel2r-kms \
  --signer-workflow shayne/hyperpixel2r-kms/.github/workflows/release.yml
```

The source archive supports local exact-kernel builds. A module archive is
valid only when its kernel facts match the target Pi.

Stable releases have a stricter two-step path. The draft workflow verifies,
packages, checksums, and attests the four release files, then creates an
unpublished GitHub draft. It does not create the stable tag. After that exact
draft has passed hardware acceptance, the promotion workflow downloads it
again and checks its release ID, asset IDs, sizes, digests, manifest, SBOM,
source identity, and attestations. Only then does it create the annotated tag
and publish the same draft. Promotion does not build or upload anything.

`v0.1.1` is the current stable release. The candidate named above is the next
minor and stays a prerelease until its exact source and boot path pass the same
hardware acceptance process.

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
contract tests. The release packager performs two clean builds in CI and rejects
nondeterministic archives.
