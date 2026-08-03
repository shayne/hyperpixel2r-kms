#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image="${HP2R_BUILD_IMAGE:-hyperpixel2r-kms-kernel-builder:debian-trixie-gcc14}"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/hp2r-backlight-contract.XXXXXX")"
trap 'rm -rf "$temporary_dir"' EXIT

mkdir -p \
  "$temporary_dir/include/dt-bindings/gpio" \
  "$temporary_dir/include/dt-bindings/interrupt-controller" \
  "$temporary_dir/include/dt-bindings/pinctrl"

cat > "$temporary_dir/include/dt-bindings/gpio/gpio.h" <<'HEADER'
#define GPIO_ACTIVE_HIGH 0
#define GPIO_ACTIVE_LOW 1
HEADER
cat > "$temporary_dir/include/dt-bindings/interrupt-controller/irq.h" <<'HEADER'
#define IRQ_TYPE_EDGE_FALLING 2
HEADER
cat > "$temporary_dir/include/dt-bindings/pinctrl/bcm2835.h" <<'HEADER'
#define BCM2835_FSEL_ALT5 2
HEADER

docker run --rm \
  --volume "$repo_root:/source:ro" \
  --volume "$temporary_dir:/work" \
  "$image" \
  sh -eu -c '
    aarch64-linux-gnu-gcc-14 \
      -E \
      -nostdinc \
      -undef \
      -D__DTS__ \
      -x assembler-with-cpp \
      -I/work/include \
      /source/overlays/hyperpixel2r-kms-overlay.dts \
      -o /work/hyperpixel2r-kms-overlay.preprocessed.dts
    dtc \
      -@ \
      -I dts \
      -O dtb \
      -o /work/hyperpixel2r-kms.dtbo \
      /work/hyperpixel2r-kms-overlay.preprocessed.dts
    fdtdump /work/hyperpixel2r-kms.dtbo \
      > /work/hyperpixel2r-kms.fdtdump \
      2>/dev/null
  '

fdtget() {
  local type=""

  if test "${1-}" = -t; then
    type="$2"
    shift 2
  fi
  if test -n "$type"; then
    docker run --rm \
      --volume "$temporary_dir:/work:ro" \
      "$image" \
      fdtget -t "$type" /work/hyperpixel2r-kms.dtbo "$@"
    return
  fi
  docker run --rm \
    --volume "$temporary_dir:/work:ro" \
    "$image" \
    fdtget /work/hyperpixel2r-kms.dtbo "$@"
}

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

panel_path=/fragment@0/__overlay__/hyperpixel2r-kms
backlight_path=/fragment@0/__overlay__/planeradar-backlight
pinctrl_path=/fragment@2/__overlay__/planeradar-backlight-pins
pwm_path=/fragment@3/__overlay__

test "$(fdtget -t s "$backlight_path" compatible)" = pwm-backlight ||
  fail "named PWM backlight compatible is invalid"
test "$(fdtget -t x "$backlight_path" pwms)" = "ffffffff 1 30d40 0" ||
  fail "PWM channel, period, or polarity is invalid"
test "$(fdtget -t x "$backlight_path" brightness-levels)" = "0 ff" ||
  fail "PWM backlight endpoints are invalid"
test "$(fdtget -t x "$backlight_path" num-interpolated-steps)" = ff ||
  fail "PWM backlight interpolation is invalid"
test "$(fdtget -t x "$backlight_path" default-brightness-level)" = d ||
  fail "PWM backlight boot level is invalid"

test "$(fdtget -t x "$pinctrl_path" brcm,pins)" = 13 ||
  fail "PWM pinctrl does not own GPIO19"
test "$(fdtget -t x "$pinctrl_path" brcm,function)" = 2 ||
  fail "GPIO19 is not configured for Alt5"
test "$(fdtget -t x "$pwm_path" clock-frequency)" = f4240 ||
  fail "PWM clock is not 1 MHz"
test "$(fdtget -t s "$pwm_path" status)" = okay ||
  fail "PWM controller is not enabled"

backlight_phandle="$(fdtget -t x "$backlight_path" phandle)"
pinctrl_phandle="$(fdtget -t x "$pinctrl_path" phandle)"
test "$(fdtget -t x "$panel_path" backlight)" = "$backlight_phandle" ||
  fail "panel backlight phandle is invalid"
test "$(fdtget -t x "$pwm_path" pinctrl-0)" = "$pinctrl_phandle" ||
  fail "PWM pinctrl phandle is invalid"
test "$(fdtget -t s "$pwm_path" pinctrl-names)" = default ||
  fail "PWM pinctrl state is invalid"

test "$(fdtget -t s /__symbols__ planeradar_backlight)" = "$backlight_path" ||
  fail "named PWM backlight symbol is missing"
test "$(fdtget -t s /__fixups__ pwm)" = \
  "$backlight_path:pwms:0 /fragment@3:target:0" ||
  fail "PWM controller fixups are invalid"

if fdtget "$panel_path" backlight-gpios >/dev/null 2>&1; then
  fail "compiled panel still exposes backlight-gpios"
fi
if grep -Fq 'backlight-gpios' "$temporary_dir/hyperpixel2r-kms.fdtdump"; then
  fail "compiled overlay dump still exposes backlight-gpios"
fi

source "$repo_root/scripts/common.sh"
hp2r_validate_overlay "$temporary_dir/hyperpixel2r-kms.dtbo" "$image"

printf 'PWM backlight compiled-overlay contract passed\n'
