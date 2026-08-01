# Compatibility boundary

The supported setup is narrow on purpose:

- Raspberry Pi Zero 2 W;
- Pimoroni HyperPixel 2.1 Round, 480×480 touch display;
- 64-bit Raspberry Pi OS Lite, Trixie release line;
- an `aarch64` userland and matching running kernel headers;
- a Mac build host with Docker or OrbStack and SSH access to the Pi.

Desktop Raspberry Pi OS, 32-bit userlands, other Raspberry Pi boards, other
HyperPixel panels, Bookworm, and arbitrary Debian derivatives are outside the
version 0.1 support boundary. They may be interesting experiments. They are
not a reason to relax a boot-time safety check.

## Kernel compatibility is exact

The driver does not use a vague “Linux 6.x” promise. An exact bundle names the
kernel release, architecture, source revision and tree, module vermagic,
overlay digest, module digest, and the DTB application evidence that produced
it. The installer scripts reject a bundle when any one of those facts differs.

If there is no matching prebuilt bundle, export the running Pi's kernel build
context and cross-build locally:

```sh
export HP2R_TARGET=pi@raspberrypi.local
mise run export-target-kbuild
mise run build-driver
mise run check-artifacts
```

That is slower than downloading a file, but it is a better failure mode than
loading a module built for an almost-identical kernel.

## One-boot acceptance

The first candidate boot uses Raspberry Pi tryboot. Normal `config.txt` remains
unchanged until the candidate proves the expected 480×480 DRM connector, touch
device, SDL KMSDRM backend, and OpenGL ES 2 renderer are present.

```sh
mise run stage-tryboot
# stage-tryboot requests the one-shot reboot; wait for SSH to return
mise run verify-boot -- --json
mise run commit-boot
```

If verification fails, run `mise run rollback-boot`. If the Pi is unreachable
after a candidate boot, power-cycle it: firmware clears tryboot after use, so
the previous normal boot configuration gets another turn.

## DKMS is maintenance, not magic

After an accepted boot, the driver source is registered with DKMS so normal
Raspberry Pi OS kernel maintenance can rebuild it. That removes one manual
step; it does not prove that a future kernel, firmware, or graphics stack has
the same behavior. Version 0.1 rejects an unsupported build rather than
advertising automatic compatibility it cannot verify.
