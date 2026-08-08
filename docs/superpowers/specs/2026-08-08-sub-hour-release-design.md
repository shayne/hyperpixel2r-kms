# Sub-Hour Driver Release Design

## Goal

Make a normal driver change move from implementation to a physically accepted
release in roughly one hour without weakening provenance, rollback, or hardware
gates. The hour is a target, not a timeout.

## Boundaries

- Local development runs only tests directly related to the edited behavior.
- The pushed commit receives one complete CI verification.
- Release publication never rebuilds or reruns the complete suite.
- Stable promotion reuses the exact RC bytes accepted on the Pi.
- The standalone driver exposes only HyperPixel-specific current identities.
  Plane Radar names remain only in exact legacy-migration records.

## Driver Identity

The current backlight device becomes `hyperpixel2r-backlight`, its pinctrl node
becomes `hyperpixel2r-backlight-pins`, and its udev rule becomes
`70-hyperpixel2r-backlight.rules`. The overlay symbols use
`hyperpixel2r_backlight` and `hyperpixel2r_backlight_pins`.

Plane Radar discovers and validates the new HyperPixel identity. Existing
Legacy product-prefixed identifiers remain supported only as inputs to the bounded
legacy cleanup path; they are not emitted by new driver artifacts.

## Verification Pipeline

The existing executable fixture remains the source of lifecycle confidence but
is divided into named, independently runnable groups. GitHub Actions runs the
fast C and contract tests together and runs lifecycle groups as a parallel
matrix. A final job accepts only an all-green matrix for one exact commit.

That final job creates the source archive, release manifest, checksums, and
SBOM once, verifies a reproducible second build, attests the subjects, and
uploads one immutable workflow artifact named by the source commit.

## Publication Pipeline

RC publication requires a successful verification run for the exact requested
commit. It downloads the commit-keyed artifact, verifies checksums, manifest,
source identity, and attestations, then creates the annotated RC tag and GitHub
prerelease. It does not build or run tests.

After hardware acceptance, stable promotion downloads the exact published RC
assets, verifies their fingerprint and source identity, creates the stable tag,
and publishes a stable release containing byte-identical assets. There is no
separate stable build or full verification run.

`release/current-release.txt` is the canonical candidate tag. A single release
preparation command updates that file and the human README references together,
then validates the result so a partial version bump cannot be pushed.

## Hardware Acceptance

The application controller performs one exact-kernel build when no matching
prebuilt bundle exists, stages one accepted tryboot candidate, waits for the Pi,
and records machine-readable driver, DRM, touch, renderer, service, brightness,
power, and frame evidence. Successful RC acceptance then promotes that same
candidate through one normal reboot and finalizes the accepted receipt. It does
not recover and restage a healthy candidate merely to exercise rollback again.

Lifecycle commands keep their durable journals and interruption recovery. The
controller avoids repeated redundant calls; it validates each durable boundary
once and carries the exact identity forward.

## Failure Rules

- A failed test produces a new commit and one new CI run.
- A failed or superseded RC is never retagged; the next numbered RC is used.
- A release workflow refuses a missing, incomplete, expired, or wrong-commit CI
  artifact.
- Failed hardware acceptance leaves or restores the prior accepted driver and
  never promotes stable assets.
- Stable publication refuses any asset byte different from the accepted RC.

## Performance Targets

- Focused local feedback: 1-5 minutes.
- Parallel complete CI plus packaging: 15-25 minutes.
- RC publication from verified artifacts: under 5 minutes.
- Pi acceptance and stable promotion: 15-25 minutes.

The design reduces repeated work; it does not skip the single complete CI gate
or the physical display gate.
