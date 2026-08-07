#!/usr/bin/env bash
set -euo pipefail

# Executable hostile fixtures for the controller-side boot lifecycle.  They run
# the production scripts against a disposable target filesystem; no SSH
# connection or firmware reboot is involved.  Keep this runner Linux-only so
# GNU stat/find behaviour matches Raspberry Pi OS exactly.
repo_root="${HP2R_FIXTURE_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
release='6.18.34+rpt-rpi-v8'
source_revision="$(awk -F '\t' '$1 == "source_revision" { print $2 }' "$repo_root/dist/artifacts/$release/manifest.txt")"
source_tree="$(awk -F '\t' '$1 == "source_tree" { print $2 }' "$repo_root/dist/artifacts/$release/manifest.txt")"
overlay_file="hyperpixel2r-kms-${source_revision:0:12}.dtbo"
backlight_rule_file='70-planeradar-backlight.rules'
fixture="$(mktemp -d)"
chmod 0755 "$fixture"
root="$fixture/root"
backlight_rule_path="$root/etc/udev/rules.d/$backlight_rule_file"
bin="$fixture/bin"
bin_no_dkms="$fixture/bin-no-dkms"
sbin="$fixture/sbin"
log="$fixture/commands.log"

cleanup() {
  if test -f "$fixture/tmp/inactive-late-writer.pid"; then
    kill "$(cat "$fixture/tmp/inactive-late-writer.pid")" 2>/dev/null || true
  fi
  rm -rf -- "$fixture"
}
trap cleanup EXIT

fail() {
  printf 'boot fixture failed: %s\n' "$*" >&2
  exit 1
}

assert_absent() {
  test ! -e "$1" && test ! -L "$1" || fail "unexpected path: $1"
}

assert_file() {
  test -f "$1" && test ! -L "$1" || fail "missing regular file: $1"
}

assert_backlight_rule_installed() {
  assert_file "$backlight_rule_path"
  test "$(stat -c '%U:%G:%a' "$backlight_rule_path")" = root:root:644 ||
    fail 'installed backlight rule ownership or mode drifted'
  cmp -s "$repo_root/dist/artifacts/$release/$backlight_rule_file" \
    "$backlight_rule_path" || fail 'installed backlight rule bytes drifted'
}

assert_no_private_workspaces() {
  local workspace

  test -d "$root/var/lib/hyperpixel2r-kms" || return 0
  workspace="$(find "$root/var/lib/hyperpixel2r-kms" -mindepth 1 -maxdepth 1 \
    -name '.hp2r-transaction.*' -print -quit)"
  test -z "$workspace" || fail "private transaction workspace survived: $workspace"
}

prepare_record_failure_target() {
  local artifact

  new_target
  run_stage >/dev/null
  install_live_hardware
  run_controller commit-boot.sh >/dev/null
  artifact="$root/usr/lib/hyperpixel2r-kms/0.2.0/$source_revision/$release"
  record_normal_before="$fixture/record-normal-before"
  record_artifact_before="$fixture/record-artifact-before"
  record_module_before="$(sha256sum "$root/lib/modules/$release/extra/hyperpixel2r_kms.ko" | awk '{ print $1 }')"
  record_overlay_before="$(sha256sum "$root/boot/firmware/overlays/$overlay_file" | awk '{ print $1 }')"
  cp "$root/boot/firmware/config.txt" "$record_normal_before"
  rm -rf -- "$record_artifact_before"
  cp -a "$artifact" "$record_artifact_before"
}

assert_record_target_unchanged() {
  local artifact="$root/usr/lib/hyperpixel2r-kms/0.2.0/$source_revision/$release"

  cmp -s "$record_normal_before" "$root/boot/firmware/config.txt" ||
    fail 'accepted record failure changed the normal config'
  diff -ru "$record_artifact_before" "$artifact" >/dev/null ||
    fail 'accepted record failure changed the retained artifact tree'
  test "$(sha256sum "$root/lib/modules/$release/extra/hyperpixel2r_kms.ko" | awk '{ print $1 }')" = "$record_module_before" ||
    fail 'accepted record failure changed the installed module'
  test "$(sha256sum "$root/boot/firmware/overlays/$overlay_file" | awk '{ print $1 }')" = "$record_overlay_before" ||
    fail 'accepted record failure changed the installed overlay'
}

assert_record_prepublication_failure() {
  assert_no_private_workspaces
  assert_absent "$root/var/lib/hyperpixel2r-kms/accepted-state"
  assert_absent "$root/var/lib/hyperpixel2r-kms/accepted-stock-config.txt"
  assert_record_target_unchanged
}

assert_no_foreign_hyperpixel_overlay() {
  local config="$1"
  local owned="$2"

  awk -v owned="dtoverlay=$owned" '
    {
      line=$0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line ~ /^dtoverlay=/ && line ~ /hyperpixel2r/ && line != owned) exit 1
    }
  ' "$config" || fail "foreign HyperPixel overlay survived in $config"
}

assert_exact_line_count() {
  local file="$1"
  local line="$2"
  local expected="$3"
  local actual

  actual="$(grep -Fxc "$line" "$file" || true)"
  test "$actual" = "$expected" ||
    fail "unexpected count for $line in $file: $actual"
}

assert_incoming_stage_cleaned() {
  assert_absent "$root/tmp/hp2r-tryboot-stage.fixture"
}

new_target() {
  rm -rf -- "$root" "$bin" "$bin_no_dkms" "$sbin" "$log"
  mkdir -p \
    "$root/boot/firmware/overlays" \
    "$root/lib/modules/$release" \
    "$root/etc/udev/rules.d" \
    "$root/proc/sys/kernel/random" \
    "$root/tmp" \
    "$root/var/lib" \
    "$bin" \
    "$sbin"
  chmod 1777 "$root/tmp"
  : > "$log"
  chmod 0666 "$log"
  printf '[all]\ndtoverlay=vc4-kms-dpi-hyperpixel2r,rotate=90\n' \
    > "$root/boot/firmware/config.txt"
  printf '11111111-2222-4333-8444-555555555555\n' \
    > "$root/proc/sys/kernel/random/boot_id"
  cc "$repo_root/tests/fixture-sudo.c" -o "$bin/sudo"
  chown root:root "$bin/sudo"
  chmod 4755 "$bin/sudo"
  install -m 0755 /bin/sh "$bin/cap-shell"
  python3 - "$bin/cap-shell" <<'PY'
import os
import struct
import sys

# VFS_CAP_REVISION_2 | VFS_CAP_FLAGS_EFFECTIVE with CAP_DAC_OVERRIDE permitted.
os.setxattr(
    sys.argv[1],
    "security.capability",
    struct.pack("<IIIII", 0x02000001, 1 << 1, 0, 0, 0),
)
PY

  install -m 0755 /dev/stdin "$bin/id" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
if test "${1-}" = -u && test "${2-}" = nobody; then
  case "${HP2R_FIXTURE_BACKLIGHT_IDENTITY_SHAPE:-}" in
    uid-missing) exit 1 ;;
    uid-ambiguous) printf '%s\n' 65534 65533; exit 0 ;;
    uid-nonnumeric) printf '%s\n' nobody; exit 0 ;;
    uid-zero) printf '%s\n' 0; exit 0 ;;
    uid-unsafe) printf '%s\n' 4294967295; exit 0 ;;
  esac
  if test "${HP2R_FIXTURE_BACKLIGHT_DYNAMIC_IDS:-}" = 1; then
    printf '%s\n' 4241
    exit 0
  fi
fi
exec /usr/bin/id "$@"
SCRIPT

  install -m 0755 /dev/stdin "$bin/setpriv" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
if test "${HP2R_FIXTURE_RETAIN_BACKLIGHT_CAPABILITY:-}" = 1 &&
  test "${1-}" = --reuid=65534 && test "${2-}" = --regid=44 &&
  test "${3-}" = --clear-groups; then
  reuid="$1"
  regid="$2"
  shift 3
  test "${1-}" = sh || exit 64
  shift
  : > "$HP2R_FIXTURE_ROOT/tmp/backlight-capability-retained"
  exec /usr/bin/setpriv "$reuid" "$regid" --clear-groups \
    "${HP2R_FIXTURE_ROOT%/root}/bin/cap-shell" "$@"
fi
if test "${HP2R_FIXTURE_RETAIN_BACKLIGHT_PRIVILEGE:-}" = 1 &&
  test "${1-}" = --reuid=65534 && test "${2-}" = --regid=44 &&
  test "${3-}" = --clear-groups; then
  shift 3
  : > "$HP2R_FIXTURE_ROOT/tmp/backlight-privilege-retained"
  exec "$@"
fi
if test "${HP2R_FIXTURE_BACKLIGHT_DYNAMIC_IDS:-}" = 1 &&
  test "${1-}" = --reuid=4241 && test "${2-}" = --regid=4242 &&
  test "${3-}" = --clear-groups; then
  : > "$HP2R_FIXTURE_ROOT/tmp/backlight-root-setpriv-used"
fi
exec /usr/bin/setpriv "$@"
SCRIPT

  install -m 0755 /dev/stdin "$bin/find" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
if test -n "${HP2R_INSTALL_ROOT:-}" && test "${HP2R_FIXTURE_FAIL_RECOVERY_FIND:-}" = state; then
  for argument in "$@"; do
    if test "$argument" = "$HP2R_FIXTURE_ROOT/var/lib/hyperpixel2r-kms"; then
      exit 79
    fi
  done
fi
if test -n "${HP2R_INSTALL_ROOT:-}" && test "${HP2R_FIXTURE_FAIL_RECOVERY_FIND:-}" = leaves; then
  for argument in "$@"; do
    if test "$argument" = "$HP2R_FIXTURE_ROOT/var/lib/hyperpixel2r-kms/.hp2r-transaction.WorkspaceFixture"; then
      /usr/bin/find "$@"
      exit 79
    fi
  done
fi
exec /usr/bin/find "$@"
SCRIPT

  install -m 0755 /dev/stdin "$bin/fixture-record-fault" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
operation="$1"
shift
test "${HP2R_FIXTURE_FAIL_RECORD_OPERATION:-}" = "$operation" || exit 0
marker="$HP2R_FIXTURE_ROOT/tmp/record-fault-$operation"
test ! -e "$marker" || exit 0
matches=false
case "$operation" in
  normal-snapshot)
    if test "${1-}" = "$HP2R_FIXTURE_ROOT/boot/firmware/config.txt" &&
      [[ "${2-}" == "$HP2R_FIXTURE_ROOT"/var/lib/hyperpixel2r-kms/.hp2r-transaction.*/.hp2r-accepted-normal.* ]]; then
      matches=true
    fi
    ;;
  stock-allocation)
    if [[ "${1-}" == "$HP2R_FIXTURE_ROOT"/var/lib/hyperpixel2r-kms/.hp2r-transaction.*/accepted-stock ]]; then
      matches=true
    fi
    ;;
  stock-derivation)
    if [[ "${1-}" == "$HP2R_FIXTURE_ROOT"/var/lib/hyperpixel2r-kms/.hp2r-transaction.*/.hp2r-accepted-normal.* ]]; then
      matches=true
    fi
    ;;
  receipt-allocation|receipt-write)
    if [[ "${1-}" == "$HP2R_FIXTURE_ROOT"/var/lib/hyperpixel2r-kms/.hp2r-transaction.*/accepted-state ]]; then
      matches=true
    fi
    ;;
  stock-publication)
    if test "${1-}" = "$HP2R_FIXTURE_ROOT/var/lib/hyperpixel2r-kms/accepted-stock-config.txt"; then
      matches=true
    fi
    ;;
  receipt-publication|final-receipt-validation)
    if test "${1-}" = "$HP2R_FIXTURE_ROOT/var/lib/hyperpixel2r-kms/accepted-state"; then
      matches=true
    fi
    ;;
  workspace-removal)
    for argument in "$@"; do
      if [[ "$argument" == "$HP2R_FIXTURE_ROOT"/var/lib/hyperpixel2r-kms/.hp2r-transaction.* ]]; then
        matches=true
        break
      fi
    done
    ;;
  sync) matches=true ;;
  *) exit 64 ;;
esac
"$matches" || exit 0
: > "$marker"
exit 77
SCRIPT

  install -m 0755 /dev/stdin "$bin/cp" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
source_path="${@: -2:1}"
destination="${@: -1}"
"$(dirname "$0")/fixture-record-fault" normal-snapshot "$source_path" "$destination"
incoming="$HP2R_FIXTURE_ROOT/tmp/hp2r-tryboot-stage.fixture/hyperpixel2r_kms.ko"
no_dereference=false
for argument in "$@"; do
  if test "$argument" = --no-dereference; then no_dereference=true; fi
done
if test -n "${HP2R_INSTALL_ROOT:-}" && test "${HP2R_FIXTURE_INSTRUMENT_SYMLINK_FOLLOW:-}" = 1 && \
  /usr/bin/test -L "$source_path" && ! "$no_dereference"; then
  : > "$HP2R_FIXTURE_ROOT/tmp/symlink-followed-by-cp"
  exit 88
fi
if test -n "${HP2R_INSTALL_ROOT:-}" && test "${HP2R_FIXTURE_RACE_ATOMIC_SOURCE_SYMLINK:-}" = module && \
  test "$source_path" = "$incoming"; then
  marker="$HP2R_FIXTURE_ROOT/tmp/atomic-source-replaced"
  if test ! -e "$marker"; then
    : > "$marker"
    /usr/bin/rm -f -- "$incoming"
    /usr/bin/ln -s /etc/passwd "$incoming"
  fi
fi
/usr/bin/cp "$@"
copy_status=$?
test "$copy_status" = 0 || exit "$copy_status"
if test -n "${HP2R_INSTALL_ROOT:-}" && test -n "${HP2R_FIXTURE_RACE_INACTIVE_SOURCE:-}"; then
  case "${HP2R_FIXTURE_RACE_INACTIVE_SOURCE}:$destination" in
    prior-kernel:*/.hp2r-prior-kernel.*|prior-initramfs:*/.hp2r-prior-initramfs.*|candidate-kernel:*/.hp2r-candidate-kernel.*|candidate-initramfs:*/.hp2r-candidate-initramfs.*|base-dtb:*/.hp2r-candidate-base-dtb.*|vc4-overlay:*/.hp2r-candidate-vc4-overlay.*)
      marker="$HP2R_FIXTURE_ROOT/tmp/inactive-source-${HP2R_FIXTURE_RACE_INACTIVE_SOURCE}-replaced"
      if test ! -e "$marker"; then
        : > "$marker"
        printf 'replacement after capture\n' >> "$source_path"
      fi
      ;;
  esac
fi
if test -n "${HP2R_INSTALL_ROOT:-}" && \
  test -f "$HP2R_FIXTURE_ROOT/tmp/inactive-late-writer-class" && \
  [[ "$destination" == */.hp2r-accepted-prior.* ]]; then
  marker="$HP2R_FIXTURE_ROOT/tmp/inactive-late-writer-start"
  if test ! -e "$marker"; then
    : > "$marker"
  fi
fi
if test -n "${HP2R_INSTALL_ROOT:-}" && test -n "${HP2R_FIXTURE_RACE_LATE_SYMLINK:-}"; then
  case "${HP2R_FIXTURE_RACE_LATE_SYMLINK}:$destination" in
    snapshot:*/.hp2r-incoming-manifest.*|atomic:*/.manifest.txt.*)
      marker="$HP2R_FIXTURE_ROOT/tmp/late-symlink-${HP2R_FIXTURE_RACE_LATE_SYMLINK}-created"
      if test ! -e "$marker"; then
        : > "$marker"
        /usr/bin/rm -f -- "$destination"
        /usr/bin/ln -s /etc/passwd "$destination"
      fi
      ;;
  esac
fi
exit 0
SCRIPT

  install -m 0755 /dev/stdin "$bin/install" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
destination="${@: -1}"
"$(dirname "$0")/fixture-record-fault" stock-allocation "$destination"
"$(dirname "$0")/fixture-record-fault" receipt-allocation "$destination"
if test -n "${HP2R_INSTALL_ROOT:-}" && test "${HP2R_FIXTURE_FAIL_PRIVATE_FILE:-}" = candidate; then
  case "$destination" in
    "$HP2R_FIXTURE_ROOT"/var/lib/hyperpixel2r-kms/.hp2r-transaction.*/candidate)
      marker="$HP2R_FIXTURE_ROOT/tmp/private-file-candidate-failed"
      if ! /usr/bin/test -e "$marker"; then
        : > "$marker"
        exit 78
      fi
      ;;
  esac
fi
exec /usr/bin/install "$@"
SCRIPT

  install -m 0755 /dev/stdin "$bin/tee" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
destination="${@: -1}"
"$(dirname "$0")/fixture-record-fault" receipt-write "$destination"
/usr/bin/tee "$@"
if test -n "${HP2R_INSTALL_ROOT:-}" && test -f "$HP2R_FIXTURE_ROOT/tmp/inactive-force-overlong"; then
  case "$destination" in
    */explicit-normal|*/normalized-normal) printf '%099d\n' 0 >> "$destination" ;;
  esac
fi
SCRIPT

  install -m 0755 /dev/stdin "$bin/test" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
if test -n "${HP2R_INSTALL_ROOT:-}" && test "${HP2R_FIXTURE_INSTRUMENT_SYMLINK_FOLLOW:-}" = 1 && \
  test "${1-}" = -f && test -n "${2-}" && /usr/bin/test -L "$2"; then
  : > "$HP2R_FIXTURE_ROOT/tmp/symlink-followed-by-test-f"
fi
if test -n "${HP2R_INSTALL_ROOT:-}" && test -n "${HP2R_FIXTURE_ALLOCATOR_FAULT:-}" && \
  /usr/bin/test -e "$HP2R_FIXTURE_ROOT/tmp/allocator-workspace"; then
  workspace="$(/usr/bin/cat "$HP2R_FIXTURE_ROOT/tmp/allocator-workspace")"
  case "${HP2R_FIXTURE_ALLOCATOR_FAULT}:$*" in
    lfirst:"! -L $workspace")
      marker="$HP2R_FIXTURE_ROOT/tmp/allocator-fault-lfirst"
      if ! /usr/bin/test -e "$marker"; then : > "$marker"; exit 79; fi
      ;;
    directory:"-d $workspace")
      marker="$HP2R_FIXTURE_ROOT/tmp/allocator-fault-directory"
      if ! /usr/bin/test -e "$marker"; then : > "$marker"; exit 79; fi
      ;;
  esac
fi
exec /usr/bin/test "$@"
SCRIPT

  install -m 0755 /dev/stdin "$bin/awk" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
input="${@: -1}"
"$(dirname "$0")/fixture-record-fault" stock-derivation "$input"
"$(dirname "$0")/fixture-record-fault" final-receipt-validation "$input"
if test -n "${HP2R_INSTALL_ROOT:-}" && test "${HP2R_FIXTURE_INSTRUMENT_SYMLINK_FOLLOW:-}" = 1; then
  for argument in "$@"; do
    if /usr/bin/test -L "$argument"; then
      : > "$HP2R_FIXTURE_ROOT/tmp/symlink-followed-by-awk"
      exit 88
    fi
  done
fi
exec /usr/bin/awk "$@"
SCRIPT

  install -m 0755 /dev/stdin "$bin/stat" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
brightness="$HP2R_FIXTURE_ROOT/sys/class/backlight/planeradar-backlight/brightness"
if test "${3-}" = "$brightness"; then
  case "${2-}:${HP2R_FIXTURE_BACKLIGHT_IDENTITY_SHAPE:-}" in
    %U:%G:%a:%u:%g:metadata-gid-race)
      numeric_gid="$(/usr/bin/stat -c %g "$brightness")"
      chown "root:$((numeric_gid + 1))" "$brightness"
      : > "$HP2R_FIXTURE_ROOT/tmp/backlight-metadata-gid-race"
      printf 'root:video:660:0:%s\n' "$numeric_gid"
      exit 0
      ;;
    %U:%G:%a:%u:%g:metadata-postwrite-drift)
      if test -f "$HP2R_FIXTURE_ROOT/tmp/backlight-metadata-first-snapshot"; then
        numeric_gid="$(/usr/bin/stat -c %g "$brightness")"
        chown "root:$((numeric_gid + 1))" "$brightness"
        : > "$HP2R_FIXTURE_ROOT/tmp/backlight-metadata-postwrite-drift"
        printf 'root:video:660:0:%s\n' "$((numeric_gid + 1))"
      else
        : > "$HP2R_FIXTURE_ROOT/tmp/backlight-metadata-first-snapshot"
        printf 'root:video:660:0:%s\n' \
          "$(/usr/bin/stat -c %g "$brightness")"
      fi
      exit 0
      ;;
    %U:%G:%a:%u:%g:metadata-owner) printf '%s\n' root:root:660:0:0; exit 0 ;;
    %U:%G:%a:%u:%g:metadata-mode)
      printf 'root:video:640:0:%s\n' "$(/usr/bin/stat -c %g "$brightness")"
      exit 0
      ;;
    %U:%G:%a:%u:%g:gid-missing) exit 1 ;;
    %U:%G:%a:%u:%g:gid-ambiguous)
      printf '%s\n' root:video:660:0:44 root:video:660:0:45
      exit 0
      ;;
    %U:%G:%a:%u:%g:gid-nonnumeric) printf '%s\n' root:video:660:0:video; exit 0 ;;
    %U:%G:%a:%u:%g:gid-zero) printf '%s\n' root:video:660:0:0; exit 0 ;;
    %U:%G:%a:%u:%g:gid-unsafe) printf '%s\n' root:video:660:0:4294967295; exit 0 ;;
    %U:%G:%a:%u:%g:*)
      printf 'root:video:660:0:%s\n' "$(/usr/bin/stat -c %g "$brightness")"
      exit 0
      ;;
    %U:%G:%a:metadata-gid-race) printf '%s\n' root:video:660; exit 0 ;;
    %g:metadata-gid-race)
      numeric_gid="$(/usr/bin/stat -c %g "$brightness")"
      chown "root:$((numeric_gid + 1))" "$brightness"
      : > "$HP2R_FIXTURE_ROOT/tmp/backlight-metadata-gid-race"
      printf '%s\n' "$((numeric_gid + 1))"
      exit 0
      ;;
    %U:%G:%a:metadata-postwrite-drift) printf '%s\n' root:video:660; exit 0 ;;
    %g:metadata-postwrite-drift)
      : > "$HP2R_FIXTURE_ROOT/tmp/backlight-metadata-postwrite-drift"
      /usr/bin/stat -c %g "$brightness"
      exit 0
      ;;
    %U:%G:%a:metadata-owner) printf '%s\n' root:root:660; exit 0 ;;
    %U:%G:%a:metadata-mode) printf '%s\n' root:video:640; exit 0 ;;
    %U:%G:%a:*) printf '%s\n' root:video:660; exit 0 ;;
    %g:gid-missing) exit 1 ;;
    %g:gid-ambiguous) printf '%s\n' 44 45; exit 0 ;;
    %g:gid-nonnumeric) printf '%s\n' video; exit 0 ;;
    %g:gid-zero) printf '%s\n' 0; exit 0 ;;
    %g:gid-unsafe) printf '%s\n' 4294967295; exit 0 ;;
    %g:*)
      if test "${HP2R_FIXTURE_BACKLIGHT_DYNAMIC_IDS:-}" = 1; then
        printf '%s\n' 4242
        exit 0
      fi
      ;;
  esac
fi
if test -n "${HP2R_INSTALL_ROOT:-}" && test "${HP2R_FIXTURE_INSTRUMENT_SYMLINK_FOLLOW:-}" = 1; then
  for argument in "$@"; do
    if /usr/bin/test -L "$argument"; then
      : > "$HP2R_FIXTURE_ROOT/tmp/symlink-followed-by-stat"
      exit 88
    fi
  done
fi
if test -n "${HP2R_INSTALL_ROOT:-}" && test -n "${HP2R_FIXTURE_ALLOCATOR_FAULT:-}" && \
  /usr/bin/test -e "$HP2R_FIXTURE_ROOT/tmp/allocator-workspace"; then
  workspace="$(/usr/bin/cat "$HP2R_FIXTURE_ROOT/tmp/allocator-workspace")"
  case "${HP2R_FIXTURE_ALLOCATOR_FAULT}:${2-}:${3-}" in
    owner:%U:%G:"$workspace")
      : > "$HP2R_FIXTURE_ROOT/tmp/allocator-fault-owner"
      printf '%s\n' nobody:nogroup
      exit 0
      ;;
    mode:%a:"$workspace")
      : > "$HP2R_FIXTURE_ROOT/tmp/allocator-fault-mode"
      printf '%s\n' 755
      exit 0
      ;;
  esac
fi
if test "${HP2R_FIXTURE_BOOT_MODE:-}" = 755 && test "${2-}" = %a; then
  case "${3-}" in
    "$HP2R_FIXTURE_ROOT"/boot/firmware/*)
      printf '%s\n' 755
      exit 0
      ;;
  esac
fi
exec /usr/bin/stat "$@"
SCRIPT

  install -m 0755 /dev/stdin "$bin/cat" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
if test -n "${HP2R_INSTALL_ROOT:-}" && test "${HP2R_FIXTURE_INSTRUMENT_SYMLINK_FOLLOW:-}" = 1; then
  for argument in "$@"; do
    if /usr/bin/test -L "$argument"; then
      : > "$HP2R_FIXTURE_ROOT/tmp/symlink-followed-by-cat"
      exit 88
    fi
  done
fi
exec /usr/bin/cat "$@"
SCRIPT

  install -m 0755 /dev/stdin "$bin/ssh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
while test "${1-}" = -o; do shift 2; done
target="$1"
shift
test "$target" = pi@fixture
if test "${1-}" = uname && test "${2-}" = -r; then
  if test -n "${HP2R_FIXTURE_LOG:-}"; then
    printf 'remote-uname %s\n' "$*" >> "$HP2R_FIXTURE_LOG"
  fi
  printf '%s\n' "${HP2R_FIXTURE_RUNNING_RELEASE:-$HP2R_FIXTURE_RELEASE}"
  exit
fi
if test "${1-}" = mktemp && test "${2-}" = -d; then
  if test "${HP2R_FIXTURE_ACCEPTED_CONTROLLER:-}" = 1; then
    path=/tmp/hp2r-accepted.fixture
  else
    path=/tmp/hp2r-tryboot-stage.fixture
  fi
  mkdir -p "$HP2R_FIXTURE_ROOT$path"
  chown 65534:65534 "$HP2R_FIXTURE_ROOT$path"
  chmod 0700 "$HP2R_FIXTURE_ROOT$path"
  printf '%s\n' "$path"
  exit
fi
if test "${1-}" = rm && test "${2-}" = -rf; then
  shift 3
  rm -rf -- "$HP2R_FIXTURE_ROOT$1"
  printf 'remote-rm %s\n' "$1" >> "$HP2R_FIXTURE_LOG"
  exit
fi
if test "${1-}" = bash && test "${2-}" = -s; then
  remote_action="${4-}"
  if test "${HP2R_FIXTURE_FAIL_INACTIVE_AUTH:-}" = 1 && \
    test "${4-}" = authorize-inactive-stage; then
    : > "$HP2R_FIXTURE_ROOT/tmp/inactive-authorization-attempted"
    exit 91
  fi
  shift
  if test "${HP2R_FIXTURE_DROP_EMPTY_SSH_ARGS:-}" = 1; then
    filtered=()
    for argument in "$@"; do
      test -z "$argument" || filtered+=("$argument")
    done
    set -- "${filtered[@]}"
  fi
  run_remote_stdin_action() {
    remote_path="$PATH"
    if test "${HP2R_FIXTURE_REMOTE_RESTRICTED_PATH:-}" = 1; then
      remote_path="$HP2R_FIXTURE_REMOTE_BIN"
    fi
    setpriv --reuid=65534 --regid=65534 --clear-groups \
      env HP2R_INSTALL_ROOT="$HP2R_FIXTURE_ROOT" PATH="$remote_path" \
      HP2R_FIXTURE_REMOTE_RUNNING_RELEASE="${HP2R_FIXTURE_REMOTE_RUNNING_RELEASE:-}" \
      HP2R_FIXTURE_INTERRUPT_AFTER="${HP2R_FIXTURE_INTERRUPT_AFTER:-}" \
      HP2R_FIXTURE_PRESERVE_MUTATIONS="${HP2R_FIXTURE_PRESERVE_MUTATIONS:-}" \
      HP2R_FIXTURE_MUTATE_ACCEPTED_ON_STATE_PUBLISH="${HP2R_FIXTURE_MUTATE_ACCEPTED_ON_STATE_PUBLISH:-}" \
      HP2R_FIXTURE_MUTATE_MODULE_ON_STATE_PUBLISH="${HP2R_FIXTURE_MUTATE_MODULE_ON_STATE_PUBLISH:-}" \
      HP2R_FIXTURE_MUTATE_ARTIFACT_ON_STATE_PUBLISH="${HP2R_FIXTURE_MUTATE_ARTIFACT_ON_STATE_PUBLISH:-}" \
      HP2R_FIXTURE_MUTATE_DKMS_ON_STATE_PUBLISH="${HP2R_FIXTURE_MUTATE_DKMS_ON_STATE_PUBLISH:-}" \
      HP2R_FIXTURE_FAIL_AFTER_STAGED_PUBLICATION="${HP2R_FIXTURE_FAIL_AFTER_STAGED_PUBLICATION:-}" \
      HP2R_FIXTURE_MUTATE_SETTER_AUTHORITY="${HP2R_FIXTURE_MUTATE_SETTER_AUTHORITY:-}" \
      HP2R_FIXTURE_MUTATE_NORMALIZATION_BOUND_LEAF="${HP2R_FIXTURE_MUTATE_NORMALIZATION_BOUND_LEAF:-}" \
      schema5_staged_authority_asserting="${schema5_staged_authority_asserting:-}" \
      schema5_staged_authority_allow_prepared="${schema5_staged_authority_allow_prepared:-}" \
      bash -c 'id -u > "$HP2R_FIXTURE_ROOT/tmp/remote-uid"; exec bash "$@"' bash "$@"
  }
  if test "${HP2R_FIXTURE_REMOTE_RESTRICTED_PATH:-}" = 1; then
    restricted_remote="$HP2R_FIXTURE_ROOT/tmp/restricted-remote.sh"
    sed "s#/usr/sbin:/sbin#$HP2R_FIXTURE_REMOTE_SBIN#g" > "$restricted_remote"
    if run_remote_stdin_action "$@" < "$restricted_remote"; then
      remote_status=0
    else
      remote_status=$?
    fi
  elif test "$remote_action" = authorize-inactive-stage &&
    test -n "${HP2R_FIXTURE_AUTHORIZATION_TUPLE_SHAPE:-}"; then
    if remote_output="$(run_remote_stdin_action "$@")"; then
      remote_status=0
      case "$HP2R_FIXTURE_AUTHORIZATION_TUPLE_SHAPE" in
        valid) ;;
        empty-interior) remote_output="${remote_output/$'\t'/$'\t\t'}" ;;
        trailing-empty) remote_output+=$'\t' ;;
        leading-empty) remote_output=$'\t'"$remote_output" ;;
        nonempty-extra) remote_output+=$'\tforeign' ;;
        *)
          printf 'unknown authorization tuple shape: %s\n' \
            "$HP2R_FIXTURE_AUTHORIZATION_TUPLE_SHAPE" >&2
          exit 64
          ;;
      esac
      printf '%s\t%s\n' "$HP2R_FIXTURE_AUTHORIZATION_TUPLE_SHAPE" \
        "$(awk -F '\t' '{ print NF }' <<<"$remote_output")" \
        > "$HP2R_FIXTURE_ROOT/tmp/authorization-tuple-shape"
      printf '%s\n' "$remote_output"
    else
      remote_status=$?
    fi
  elif run_remote_stdin_action "$@"; then
    remote_status=0
  else
    remote_status=$?
  fi
  if test "$remote_action" = authorize-inactive-stage && \
    test "${HP2R_FIXTURE_CASE:-}" = inactive-kernel-state-digest; then
    sed -i 's/^target_identity_sha256=.*/target_identity_sha256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc/' \
      "$HP2R_FIXTURE_ROOT/var/lib/hyperpixel2r-kms/accepted-transition"
  fi
  if test "$remote_action" = authorize-inactive-stage && \
    test -n "${HP2R_FIXTURE_LEGACY_POST_AUTH_BACKLIGHT_DRIFT:-}"; then
    backlight_rule="$HP2R_FIXTURE_ROOT/etc/udev/rules.d/70-planeradar-backlight.rules"
    case "$HP2R_FIXTURE_LEGACY_POST_AUTH_BACKLIGHT_DRIFT" in
      appearance)
        install -o root -g root -m 0644 \
          "$HP2R_FIXTURE_REPO_ROOT/dist/artifacts/$HP2R_FIXTURE_RELEASE/70-planeradar-backlight.rules" \
          "$backlight_rule"
        ;;
      removal) rm -- "$backlight_rule" ;;
      symlink)
        rm -f -- "$backlight_rule"
        ln -s /etc/passwd "$backlight_rule"
        ;;
      hash) printf 'legacy live rule post-authorization drift\n' >> "$backlight_rule" ;;
      mode) chmod 0600 "$backlight_rule" ;;
      proof)
        printf 'legacy proof post-authorization drift\n' >> \
          "$HP2R_FIXTURE_ROOT/var/lib/hyperpixel2r-kms/accepted-prior-backlight-rule"
        ;;
      *)
        printf 'unknown post-authorization legacy backlight drift: %s\n' \
          "$HP2R_FIXTURE_LEGACY_POST_AUTH_BACKLIGHT_DRIFT" >&2
        exit 64
        ;;
    esac
    : > "$HP2R_FIXTURE_ROOT/tmp/legacy-backlight-mutated-after-authorization"
  fi
  exit "$remote_status"
fi
if test "${1-}" = bash && { [[ "${2-}" == /tmp/hp2r-tryboot-stage.*/* ]] || [[ "${2-}" == /tmp/hp2r-accepted.*/* ]]; }; then
  script="$HP2R_FIXTURE_ROOT$2"
  shift 2
  remote_action="${1-}"
  printf 'remote-action %s\n' "$remote_action" >> "$HP2R_FIXTURE_LOG"
  if test "${HP2R_FIXTURE_FORGE_STAGE_BACKLIGHT_AUTHORITY:-}" = 1 &&
    test "${1-}" = stage &&
    test -e "$HP2R_FIXTURE_ROOT/tmp/legacy-backlight-mutated-after-authorization"; then
    test "$#" = 14 || {
      printf 'unexpected stage argument count while forging backlight authority: %s\n' "$#" >&2
      exit 64
    }
    forged_backlight_rule="$HP2R_FIXTURE_ROOT/etc/udev/rules.d/70-planeradar-backlight.rules"
    test ! -L "$forged_backlight_rule" && test -f "$forged_backlight_rule" || exit 64
    forged_backlight_rule_sha="$(sha256sum "$forged_backlight_rule" | awk '{ print $1 }')"
    set -- "${@:1:12}" true "$forged_backlight_rule_sha"
    : > "$HP2R_FIXTURE_ROOT/tmp/stage-backlight-authority-forged"
  fi
  if test "${HP2R_FIXTURE_DROP_EMPTY_SSH_ARGS:-}" = 1; then
    filtered=()
    for argument in "$@"; do
      test -z "$argument" || filtered+=("$argument")
    done
    set -- "${filtered[@]}"
  fi
  if test "${HP2R_FIXTURE_ACCEPTED_CONTROLLER:-}" = 1; then
    printf '%s\n' "$@" > "$HP2R_FIXTURE_ROOT/tmp/accepted-controller-remote-command"
    if test "${HP2R_FIXTURE_CAPTURE_ACCEPTED_PREPARE:-}" = 1 && \
      test "${1-}" = prepare-new-accepted; then
      : > "$HP2R_FIXTURE_ROOT/tmp/accepted-prepare-command-captured"
      exit 92
    fi
  fi
  run_remote_path_action() {
    setpriv --reuid=65534 --regid=65534 --clear-groups \
      env HP2R_INSTALL_ROOT="$HP2R_FIXTURE_ROOT" PATH="$PATH" \
      HP2R_FIXTURE_REMOTE_RUNNING_RELEASE="${HP2R_FIXTURE_REMOTE_RUNNING_RELEASE:-}" \
      HP2R_FIXTURE_INTERRUPT_AFTER="${HP2R_FIXTURE_INTERRUPT_AFTER:-}" \
      HP2R_FIXTURE_PRESERVE_MUTATIONS="${HP2R_FIXTURE_PRESERVE_MUTATIONS:-}" \
      HP2R_FIXTURE_MUTATE_ACCEPTED_ON_STATE_PUBLISH="${HP2R_FIXTURE_MUTATE_ACCEPTED_ON_STATE_PUBLISH:-}" \
      HP2R_FIXTURE_MUTATE_MODULE_ON_STATE_PUBLISH="${HP2R_FIXTURE_MUTATE_MODULE_ON_STATE_PUBLISH:-}" \
      HP2R_FIXTURE_MUTATE_ARTIFACT_ON_STATE_PUBLISH="${HP2R_FIXTURE_MUTATE_ARTIFACT_ON_STATE_PUBLISH:-}" \
      HP2R_FIXTURE_MUTATE_DKMS_ON_STATE_PUBLISH="${HP2R_FIXTURE_MUTATE_DKMS_ON_STATE_PUBLISH:-}" \
      HP2R_FIXTURE_FAIL_AFTER_STAGED_PUBLICATION="${HP2R_FIXTURE_FAIL_AFTER_STAGED_PUBLICATION:-}" \
      HP2R_FIXTURE_MUTATE_SETTER_AUTHORITY="${HP2R_FIXTURE_MUTATE_SETTER_AUTHORITY:-}" \
      HP2R_FIXTURE_MUTATE_NORMALIZATION_BOUND_LEAF="${HP2R_FIXTURE_MUTATE_NORMALIZATION_BOUND_LEAF:-}" \
      schema5_staged_authority_asserting="${schema5_staged_authority_asserting:-}" \
      schema5_staged_authority_allow_prepared="${schema5_staged_authority_allow_prepared:-}" \
      bash -c 'id -u > "$HP2R_FIXTURE_ROOT/tmp/remote-uid"; exec bash "$@"' \
        bash "$script" "$@"
  }
  if test "${HP2R_FIXTURE_MUTATE_COMMIT_PROBE_TUPLE:-}" = 1 &&
    test "$remote_action" = commit-probe; then
    if remote_output="$(run_remote_path_action "$@")"; then
      remote_status=0
      remote_output="${remote_output/$'\t0.2.0\t'/$'\t9.9.9\t'}"
      printf '%s\n' "$remote_output"
    else
      remote_status=$?
    fi
  elif run_remote_path_action "$@"; then
    remote_status=0
  else
    remote_status=$?
  fi
  if test "${HP2R_FIXTURE_EXPIRE_READINESS_AFTER_COMMIT_PROBE:-}" = 1 &&
    test "$remote_action" = commit-probe; then
    : > "$HP2R_FIXTURE_ROOT/tmp/readiness-expired-after-commit-probe"
  fi
  exit "$remote_status"
fi
if test "${1-}" = 'sudo reboot '\''0 tryboot'\'''; then
  mkdir -p "$HP2R_FIXTURE_ROOT/proc/device-tree/chosen/bootloader"
  printf '\0\0\0\1' > "$HP2R_FIXTURE_ROOT/proc/device-tree/chosen/bootloader/tryboot"
  printf 'tryboot-reboot\n' >> "$HP2R_FIXTURE_LOG"
  exit
fi
if test "${1-}" = 'sudo reboot'; then
  printf 'normal-reboot\n' >> "$HP2R_FIXTURE_LOG"
  exit
fi
printf 'unexpected ssh: %q\n' "$*" >&2
exit 64
SCRIPT

  install -m 0755 /dev/stdin "$bin/scp" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
while test "${1-}" = -o; do shift 2; done
while [[ "${1-}" == -* ]]; do shift; done
source="$1"
destination="${2#*:}"
case "$destination" in
  /tmp/hp2r-tryboot-stage.*/*|/tmp/hp2r-accepted.*/*) ;;
  *) exit 64 ;;
esac
if test "${HP2R_FIXTURE_STOP_AFTER_INACTIVE_AUTH_SCP:-}" = 1 && \
  [[ "$destination" == /tmp/hp2r-tryboot-stage.*/* ]]; then
  : > "$HP2R_FIXTURE_ROOT/tmp/inactive-authorization-scp-attempted"
  exit 93
fi
mkdir -p "$HP2R_FIXTURE_ROOT$destination"
cp -RP "${source%/.}/." "$HP2R_FIXTURE_ROOT$destination"
chown -R 65534:65534 "$HP2R_FIXTURE_ROOT$destination"
printf 'scp %s\n' "$destination" >> "$HP2R_FIXTURE_LOG"
SCRIPT

  install -m 0755 /dev/stdin "$bin/depmod" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
release="${@: -1}"
module_root="$HP2R_FIXTURE_ROOT/lib/modules/$release"
mkdir -p "$module_root"
: > "$module_root/modules.dep"
for relative in \
  updates/dkms/hyperpixel2r_kms.ko \
  updates/dkms/hyperpixel2r_kms.ko.xz \
  updates/dkms/hyperpixel2r_kms.ko.zst \
  updates/dkms/hyperpixel2r_kms.ko.gz \
  extra/hyperpixel2r_kms.ko \
  extra/hyperpixel2r_kms.ko.xz \
  extra/hyperpixel2r_kms.ko.zst \
  extra/hyperpixel2r_kms.ko.gz; do
  if test -f "$module_root/$relative"; then
    printf 'hyperpixel2r_kms.ko: %s\n' "$relative" > "$module_root/modules.dep"
    break
  fi
done
if test -n "${HP2R_FIXTURE_LOG:-}"; then
  printf 'depmod %s\n' "$*" >> "$HP2R_FIXTURE_LOG"
fi
SCRIPT

  install -m 0755 /dev/stdin "$bin/modinfo" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
release=''
module=''
field=''
while test "$#" -gt 0; do
  case "$1" in
    -k) release="$2"; shift 2 ;;
    -F) field="$2"; shift 2 ;;
    -n) shift ;;
    *) module="$1"; shift ;;
  esac
done
test "$module" = hyperpixel2r_kms
test -n "$release"
if test -n "${HP2R_FIXTURE_LOG:-}"; then
  printf 'modinfo -k %s -F %s %s\n' "$release" "${field:-none}" "$module" >> "$HP2R_FIXTURE_LOG"
fi
if test "$field" = vermagic; then
  if test "${HP2R_FIXTURE_VERMAGIC_PREFIX_EVIL:-}" = 1; then
    printf '%sevil fixture\n' "$release"
  else
    printf '%s fixture\n' "$release"
  fi
  exit 0
fi
relative="$(awk -F ': ' '$1 == "hyperpixel2r_kms.ko" { print $2 }' \
  "$HP2R_FIXTURE_ROOT/lib/modules/$release/modules.dep")"
test -n "$relative"
printf '%s\n' "$HP2R_FIXTURE_ROOT/lib/modules/$release/$relative"
SCRIPT

  install -m 0755 /dev/stdin "$bin/gzip" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
if test "${HP2R_FIXTURE_GZIP_BOMB:-}" = 1; then
  test "${1-}" = -dc
  head -c 9437184 /dev/zero
  : > "$HP2R_FIXTURE_ROOT/tmp/gzip-bomb-completed"
  exit 0
fi
exec /usr/bin/gzip "$@"
SCRIPT

  install -m 0755 /dev/stdin "$bin/reboot" <<'SCRIPT'
#!/usr/bin/env bash
exit 64
SCRIPT

  install -m 0755 /dev/stdin "$bin/udevadm" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
case "${1-}" in
  control)
    test "${2-}" = --reload-rules
    printf 'udevadm reload\n' >> "$HP2R_FIXTURE_LOG"
    ;;
  trigger)
    test "$*" = 'trigger --action=add --subsystem-match=backlight --sysname-match=planeradar-backlight --settle'
    rule="$HP2R_FIXTURE_ROOT/etc/udev/rules.d/70-planeradar-backlight.rules"
    brightness="$HP2R_FIXTURE_ROOT/sys/class/backlight/planeradar-backlight/brightness"
    if test -f "$brightness" && test -f "$rule"; then
      expected='SUBSYSTEM=="backlight", KERNEL=="planeradar-backlight", RUN+="/usr/bin/chgrp video /sys%p/brightness", RUN+="/usr/bin/chmod 0660 /sys%p/brightness"'
      if test "$(cat "$rule")" = "$expected"; then
        if test "${HP2R_FIXTURE_BACKLIGHT_DYNAMIC_IDS:-}" = 1; then
          chown root:4242 "$brightness"
        else
          chgrp video "$brightness"
        fi
        chmod 0660 "$brightness"
      fi
    fi
    printf 'udevadm trigger --settle planeradar-backlight\n' >> "$HP2R_FIXTURE_LOG"
    ;;
  *) exit 64 ;;
esac
SCRIPT

  install -m 0755 /dev/stdin "$bin/uname" <<'SCRIPT'
#!/usr/bin/env bash
if test -n "${HP2R_FIXTURE_LOG:-}"; then
  printf 'uname %s\n' "$*" >> "$HP2R_FIXTURE_LOG"
fi
case "${1-}" in -r) printf '%s\n' "${HP2R_FIXTURE_REMOTE_RUNNING_RELEASE:-$HP2R_FIXTURE_RELEASE}";; -m) printf 'aarch64\n';; *) exit 64;; esac
SCRIPT

  for loader in modprobe insmod rmmod; do
    install -m 0755 /dev/stdin "$bin/$loader" <<SCRIPT
#!/usr/bin/env bash
set -euo pipefail
printf 'module-load $loader %s\\n' "\$*" >> "\$HP2R_FIXTURE_LOG"
exit 64
SCRIPT
  done

  install -m 0755 /dev/stdin "$bin/mount" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
printf 'mount %s\n' "$*" >> "$HP2R_FIXTURE_LOG"
case " $* " in *' --bind '*) printf 'bind %s\n' "$*" >> "$HP2R_FIXTURE_LOG";; esac
exit 64
SCRIPT

  # df is a faithful fixture stub for the guard's only input contract: the
  # available blocks of each independently addressed filesystem.  Locks use
  # the container's real fuser and a process that truly holds the descriptor.
  install -m 0755 /dev/stdin "$bin/df" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
path="${@: -1}"
available='999999999'
case "${HP2R_FIXTURE_SPACE:-}:$path" in
  private:"$HP2R_FIXTURE_ROOT"/var/lib/hyperpixel2r-kms) available=1 ;;
  firmware:"$HP2R_FIXTURE_ROOT"/boot/firmware) available=1 ;;
esac
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf 'fixture 999999999 0 %s 0%% /fixture\n' "$available"
SCRIPT

  # Use copies rather than shell wrappers so /proc/<pid>/exe has the precise
  # executable basename the production writer classifier is meant to inspect.
  mkdir -p "$fixture/writer-bin"
  for writer in apt apt-get dpkg unattended-upgrade update-initramfs mkinitramfs \
    kernel-install dkms depmod flash-kernel rpi-eeprom-update
  do
    cp /bin/sleep "$fixture/writer-bin/$writer"
    chmod 0755 "$fixture/writer-bin/$writer"
  done
  for writer in lifecycle-remote.sh accepted-lifecycle.sh stage-tryboot.sh \
    hp2r-boot-selector raspi-config reader harmless-raspi-config-helper; do
    {
      printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
      printf '%s\n' 'while :; do sleep 1; done'
    } | install -m 0755 /dev/stdin "$fixture/writer-bin/$writer"
  done

  install -m 0755 /dev/stdin "$bin/lsmod" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' 'Module Size Used by' 'hyperpixel2r_kms 1 0' 'i2c_algo_bit 1 1' 'edt_ft5x06 1 0' 'vc4 1 1'
SCRIPT

  install -m 0755 /dev/stdin "$bin/journalctl" <<'SCRIPT'
#!/usr/bin/env bash
if test -e "$HP2R_FIXTURE_ROOT/tmp/readiness-expired-after-commit-probe"; then
  exit 0
fi
printf '%s\n' 'fixture: SDL display ready: video_driver=KMSDRM render_driver=opengles2'
if test "${HP2R_FIXTURE_CHANGE_BOOT_ID_AFTER_READINESS:-}" = 1; then
  printf 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee\n' \
    > "$HP2R_FIXTURE_ROOT/proc/sys/kernel/random/boot_id"
fi
SCRIPT

  install -m 0755 /dev/stdin "$bin/dkms" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
version=''
module=''
for ((index = 1; index <= $#; index++)); do
  if test "${!index}" = -m; then
    next=$((index + 1))
    module="${!next}"
  fi
  if test "${!index}" = -v; then
    next=$((index + 1))
    version="${!next}"
  fi
done
test -n "$module" && test -n "$version"
marker="$HP2R_FIXTURE_ROOT/var/lib/dkms/registered"
if test "$module" = planeradar-hyperpixel2r; then
  marker="$HP2R_FIXTURE_ROOT/var/lib/dkms/registered-planeradar"
fi
if test "$module" = hyperpixel2r-kms && test "$version" != 0.2.0; then
  marker="$HP2R_FIXTURE_ROOT/var/lib/dkms/registered-$version"
fi
kernel=''
architecture=aarch64
for ((index = 1; index <= $#; index++)); do
  if test "${!index}" = -k; then
    next=$((index + 1))
    kernel="${!next}"
  fi
  if test "${!index}" = -a; then
    next=$((index + 1))
    architecture="${!next}"
  fi
done
kernel="${kernel:-${HP2R_FIXTURE_RELEASE:-6.18.34+rpt-rpi-v8}}"
installed_module="$HP2R_FIXTURE_ROOT/lib/modules/$kernel/updates/dkms/hyperpixel2r_kms.ko"
write_installed_module() {
  local source="$HP2R_FIXTURE_ROOT/usr/src/$module-$version"
  mkdir -p "$(dirname "$installed_module")"
  (
    cd "$source"
    sha256sum Kbuild Makefile dkms.conf hyperpixel2r_kms_main.c \
      hyperpixel2r_kms_gpio.c hyperpixel2r_kms_gpio.h \
      hyperpixel2r_kms_protocol.c hyperpixel2r_kms_protocol.h
  ) > "$installed_module"
}
set_kernel_state() {
  local next_state="$1"
  local temporary="${marker}.next"
  {
    printf 'added\n'
    if test -f "$marker"; then
      awk -F '\t' -v wanted_kernel="$kernel" -v wanted_arch="$architecture" '
        NR == 1 { next }
        !($1 == wanted_kernel && $2 == wanted_arch) { print }
      ' "$marker"
    fi
    printf '%s\t%s\t%s\n' "$kernel" "$architecture" "$next_state"
  } > "$temporary"
  mv -f -- "$temporary" "$marker"
}
case "${1-}" in
  status)
    if test -n "${HP2R_FIXTURE_DKMS_STATUS+x}"; then printf '%s\n' "$HP2R_FIXTURE_DKMS_STATUS"; exit "${HP2R_FIXTURE_DKMS_EXIT:-0}"; fi
    if test -f "$marker"; then
      test "$(sed -n '1p' "$marker")" = added || exit 65
      if test "$(wc -l < "$marker" | tr -d ' ')" = 1; then
        printf '%s/%s: added\n' "$module" "$version"
      else
        while IFS=$'\t' read -r recorded_kernel recorded_arch recorded_state extra; do
          test -z "$extra" || exit 65
          case "$recorded_state" in built|installed) ;; *) exit 65;; esac
          printf '%s/%s, %s, %s: %s\n' \
            "$module" "$version" "$recorded_kernel" "$recorded_arch" "$recorded_state"
        done < <(sed -n '2,$p' "$marker")
      fi
    fi
    ;;
  add) mkdir -p "$(dirname "$marker")"; printf 'added\n' > "$marker" ;;
  build)
    test -f "$marker"
    set_kernel_state built
    ;;
  install)
    test -f "$marker"
    if test "${HP2R_FIXTURE_DKMS_REJECT_EXTRA_COLLISION:-}" = 1 &&
      test -f "$HP2R_FIXTURE_ROOT/lib/modules/$kernel/extra/hyperpixel2r_kms.ko"; then
      printf 'existing module collision: %s\n' \
        "$HP2R_FIXTURE_ROOT/lib/modules/$kernel/extra/hyperpixel2r_kms.ko" >&2
      exit 86
    fi
    write_installed_module
    set_kernel_state installed
    ;;
  remove)
    test -z "${HP2R_FIXTURE_FAIL_DKMS_REMOVE:-}" || exit 74
    if test -f "$marker"; then
      while IFS=$'\t' read -r recorded_kernel recorded_arch recorded_state extra; do
        test -z "$extra" || exit 65
        rm -f -- \
          "$HP2R_FIXTURE_ROOT/lib/modules/$recorded_kernel/updates/dkms/hyperpixel2r_kms.ko" \
          "$HP2R_FIXTURE_ROOT/lib/modules/$recorded_kernel/updates/dkms/hyperpixel2r_kms.ko.xz" \
          "$HP2R_FIXTURE_ROOT/lib/modules/$recorded_kernel/updates/dkms/hyperpixel2r_kms.ko.zst" \
          "$HP2R_FIXTURE_ROOT/lib/modules/$recorded_kernel/updates/dkms/hyperpixel2r_kms.ko.gz"
      done < <(sed -n '2,$p' "$marker")
    fi
    rm -f -- "$marker"
    ;;
  *) exit 64 ;;
esac
if test -n "${HP2R_FIXTURE_LOG:-}"; then
  printf 'dkms %s\n' "$*" >> "$HP2R_FIXTURE_LOG"
fi
SCRIPT

  install -m 0755 /dev/stdin "$bin/mv" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
source_path="${@: -2:1}"
destination="${@: -1}"
"$(dirname "$0")/fixture-record-fault" stock-publication "$destination"
"$(dirname "$0")/fixture-record-fault" receipt-publication "$destination"
if test -n "${HP2R_INSTALL_ROOT:-}"; then
  if test -n "${HP2R_FIXTURE_FAIL_LEGACY_AT:-}"; then
    inject=false
    case "$HP2R_FIXTURE_FAIL_LEGACY_AT" in
      source-quarantine)
        test "$source_path" = "$HP2R_FIXTURE_ROOT/usr/src/planeradar-hyperpixel2r-0.1.0" &&
          test "$destination" = "$HP2R_FIXTURE_ROOT/usr/src/.planeradar-hyperpixel2r-v1.quarantine/planeradar-hyperpixel2r-0.1.0" &&
          inject=true
        ;;
      overlay-quarantine)
        case "$source_path:$destination" in
          "$HP2R_FIXTURE_ROOT"/boot/firmware/overlays/planeradar-hyperpixel2r-*:"$HP2R_FIXTURE_ROOT"/boot/firmware/overlays/.planeradar-hyperpixel2r-v1.quarantine.planeradar-hyperpixel2r-*) inject=true ;;
        esac
        ;;
    esac
    marker="$HP2R_FIXTURE_ROOT/tmp/legacy-fault-$HP2R_FIXTURE_FAIL_LEGACY_AT"
    if "$inject" && test ! -e "$marker"; then
      : > "$marker"
      exit 82
    fi
  fi
  if test "${HP2R_FIXTURE_RACE_POST_PUBLISH_INCOMING_MODULE:-}" = regular && test -d "$source_path"; then
    case "$source_path:$destination" in
      "$HP2R_FIXTURE_ROOT"/usr/lib/hyperpixel2r-kms/*/."$HP2R_FIXTURE_RELEASE".stage.*:"$HP2R_FIXTURE_ROOT"/usr/lib/hyperpixel2r-kms/*)
        incoming="$HP2R_FIXTURE_ROOT/tmp/hp2r-tryboot-stage.fixture/hyperpixel2r_kms.ko"
        marker="$HP2R_FIXTURE_ROOT/tmp/incoming-module-replaced"
        if test ! -e "$marker"; then
          : > "$marker"
          printf 'fixture raced incoming module\n' > "$incoming"
          chmod 0644 "$incoming"
        fi
        ;;
    esac
  fi
  case "${HP2R_FIXTURE_FAIL_MV:-}:$destination" in
    artifact:"$HP2R_FIXTURE_ROOT"/usr/lib/hyperpixel2r-kms/*|dkms-new:"$HP2R_FIXTURE_ROOT"/usr/src/hyperpixel2r-kms-0.2.0|normal:"$HP2R_FIXTURE_ROOT"/boot/firmware/config.txt|tryboot:"$HP2R_FIXTURE_ROOT"/boot/firmware/tryboot.txt|stage-state:"$HP2R_FIXTURE_ROOT"/var/lib/hyperpixel2r-kms/tryboot-state|state:"$HP2R_FIXTURE_ROOT"/var/lib/hyperpixel2r-kms/.tryboot-state-hold.*|module-hold:"$HP2R_FIXTURE_ROOT"/lib/modules/*/extra/hyperpixel2r_kms.ko.hp2r-rollback-hold)
      marker="$HP2R_FIXTURE_ROOT/tmp/mv-failed-${HP2R_FIXTURE_FAIL_MV}"
      if test ! -e "$marker"; then
        : > "$marker"
        printf 'injected mv failure %s -> %s\n' "$source_path" "$destination" >> "$HP2R_FIXTURE_LOG"
        exit 75
      fi
      ;;
  esac
fi
/usr/bin/mv "$@"
if test "${HP2R_FIXTURE_MUTATE_ACCEPTED_ON_STATE_PUBLISH:-}" = 1 && \
  test "$destination" = "$HP2R_FIXTURE_ROOT/var/lib/hyperpixel2r-kms/tryboot-state"; then
  sed -i 's/^target_identity_sha256=.*/target_identity_sha256=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd/' \
    "$HP2R_FIXTURE_ROOT/var/lib/hyperpixel2r-kms/accepted-transition"
  : > "$HP2R_FIXTURE_ROOT/tmp/accepted-authority-mutated-on-state-publish"
fi
if test "${HP2R_FIXTURE_MUTATE_MODULE_ON_STATE_PUBLISH:-}" = 1 && \
  test "$destination" = "$HP2R_FIXTURE_ROOT/var/lib/hyperpixel2r-kms/tryboot-state"; then
  printf 'late module drift\n' >> "$HP2R_FIXTURE_ROOT/lib/modules/6.18.39+rpt-rpi-v8/extra/hyperpixel2r_kms.ko"
  : > "$HP2R_FIXTURE_ROOT/tmp/module-mutated-on-state-publish"
fi
if test "${HP2R_FIXTURE_MUTATE_ARTIFACT_ON_STATE_PUBLISH:-}" = 1 && \
  test "$destination" = "$HP2R_FIXTURE_ROOT/var/lib/hyperpixel2r-kms/tryboot-state"; then
  printf 'late artifact drift\n' >> "$HP2R_FIXTURE_ROOT/usr/lib/hyperpixel2r-kms/0.2.0/1c64ae9dd22f7e16245154d4caa911859369814e/6.18.39+rpt-rpi-v8/manifest.txt"
  : > "$HP2R_FIXTURE_ROOT/tmp/artifact-mutated-on-state-publish"
fi
if test "${HP2R_FIXTURE_MUTATE_DKMS_ON_STATE_PUBLISH:-}" = 1 && \
  test "$destination" = "$HP2R_FIXTURE_ROOT/var/lib/hyperpixel2r-kms/tryboot-state"; then
  printf 'added\ncorrupt-live-row\n' > "$HP2R_FIXTURE_ROOT/var/lib/dkms/registered"
  : > "$HP2R_FIXTURE_ROOT/tmp/dkms-mutated-on-state-publish"
fi
SCRIPT

  install -m 0755 /dev/stdin "$bin/rm" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
"$(dirname "$0")/fixture-record-fault" workspace-removal "$@"
if test -n "${HP2R_INSTALL_ROOT:-}" && test -n "${HP2R_FIXTURE_FAIL_LEGACY_AT:-}"; then
  inject=false
  for argument in "$@"; do
    case "$HP2R_FIXTURE_FAIL_LEGACY_AT:$argument" in
      source-delete:*/planeradar-hyperpixel2r-0.1.0/planeradar_hyperpixel2r_main.c) inject=true ;;
      overlay-delete:*planeradar-hyperpixel2r-222222222222.dtbo) inject=true ;;
    esac
  done
  marker="$HP2R_FIXTURE_ROOT/tmp/legacy-fault-$HP2R_FIXTURE_FAIL_LEGACY_AT"
  if "$inject" && test ! -e "$marker"; then
    : > "$marker"
    exit 83
  fi
fi
if test -n "${HP2R_INSTALL_ROOT:-}" && test "${HP2R_FIXTURE_FAIL_RM:-}" = state-hold; then
  for argument in "$@"; do
    case "$argument" in "$HP2R_FIXTURE_ROOT"/var/lib/hyperpixel2r-kms/.tryboot-state-hold.*) exit 76;; esac
  done
fi
if test -n "${HP2R_INSTALL_ROOT:-}" && test "${HP2R_FIXTURE_FAIL_RM:-}" = workspace; then
  for argument in "$@"; do
    case "$argument" in "$HP2R_FIXTURE_ROOT"/*) ;; *) continue ;; esac
    if /usr/bin/test "$(/usr/bin/dirname -- "$argument")" = "$HP2R_FIXTURE_ROOT/var/lib/hyperpixel2r-kms"; then
      case "$(/usr/bin/basename "$argument")" in
        .hp2r-transaction.*)
        marker="$HP2R_FIXTURE_ROOT/tmp/workspace-remove-attempts"
        count=0
        if /usr/bin/test -e "$marker"; then count="$(/usr/bin/cat "$marker")"; fi
        count=$((count + 1))
        printf '%s\n' "$count" > "$marker"
        if test "$count" = 1; then exit 78; fi
        ;;
      esac
    fi
  done
fi
if test -n "${HP2R_INSTALL_ROOT:-}" && test "${HP2R_FIXTURE_RECOVERY_SWAP_WORKSPACE:-}" = 1; then
  marker="$HP2R_FIXTURE_ROOT/tmp/recovery-workspace-swapped"
  for argument in "$@"; do
    case "$argument" in
      "$HP2R_FIXTURE_ROOT"/var/lib/hyperpixel2r-kms/.hp2r-transaction.*)
        if test "$argument" != "$HP2R_FIXTURE_ROOT/var/lib/hyperpixel2r-kms/.hp2r-transaction.WorkspaceFixture" && \
          test ! -e "$marker"; then
          /usr/bin/mv \
            "$HP2R_FIXTURE_ROOT/var/lib/hyperpixel2r-kms/.hp2r-transaction.WorkspaceFixture" \
            "$HP2R_FIXTURE_ROOT/var/lib/hyperpixel2r-kms/.hp2r-transaction.ReplacementFixture"
          : > "$marker"
        fi
        ;;
    esac
  done
fi
if test -n "${HP2R_INSTALL_ROOT:-}" && test "${HP2R_FIXTURE_RECOVERY_SWAP_NORMAL_LEAF:-}" = 1; then
  marker="$HP2R_FIXTURE_ROOT/tmp/recovery-normal-leaf-swapped"
  for argument in "$@"; do
    case "$argument" in
      "$HP2R_FIXTURE_ROOT"/var/lib/hyperpixel2r-kms/.hp2r-transaction.*)
        if test "$argument" != "$HP2R_FIXTURE_ROOT/var/lib/hyperpixel2r-kms/.hp2r-transaction.WorkspaceFixture" && \
          test ! -e "$marker"; then
          /usr/bin/mv \
            "$HP2R_FIXTURE_ROOT/var/lib/hyperpixel2r-kms/.hp2r-transaction.WorkspaceFixture/.hp2r-accepted-normal.SnapshotFixture" \
            "$HP2R_FIXTURE_ROOT/var/lib/hyperpixel2r-kms/.hp2r-transaction.WorkspaceFixture/.hp2r-accepted-normal.ReplacementSnapshot"
          : > "$marker"
        fi
        ;;
    esac
  done
fi
exec /usr/bin/rm "$@"
SCRIPT

  install -m 0755 /dev/stdin "$bin/sync" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
"$(dirname "$0")/fixture-record-fault" sync
if test "${HP2R_FIXTURE_TRACK_INACTIVE_RETIRE_SYNC:-}" = 1; then
  kernel=absent
  initramfs=absent
  journal=absent
  /usr/bin/test ! -e "$HP2R_FIXTURE_RETIRE_KERNEL" && \
    /usr/bin/test ! -L "$HP2R_FIXTURE_RETIRE_KERNEL" || kernel=present
  /usr/bin/test ! -e "$HP2R_FIXTURE_RETIRE_INITRAMFS" && \
    /usr/bin/test ! -L "$HP2R_FIXTURE_RETIRE_INITRAMFS" || initramfs=present
  /usr/bin/test ! -e "$HP2R_FIXTURE_RETIRE_JOURNAL" && \
    /usr/bin/test ! -L "$HP2R_FIXTURE_RETIRE_JOURNAL" || journal=present
  printf 'kernel=%s initramfs=%s journal=%s\n' \
    "$kernel" "$initramfs" "$journal" \
    >> "$HP2R_FIXTURE_ROOT/tmp/inactive-retire-sync.log"
fi
if test "${HP2R_FIXTURE_RECOVER_SYNC:-}" = 1; then
  : > "$HP2R_FIXTURE_ROOT/tmp/recover-record-sync"
fi
exec /usr/bin/sync "$@"
SCRIPT

  install -m 0755 /dev/stdin "$bin/chmod" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
if test -n "${HP2R_INSTALL_ROOT:-}" && test "${HP2R_FIXTURE_ALLOCATOR_FAULT:-}" = chmod && \
  /usr/bin/test -e "$HP2R_FIXTURE_ROOT/tmp/allocator-workspace"; then
  workspace="$(/usr/bin/cat "$HP2R_FIXTURE_ROOT/tmp/allocator-workspace")"
  if test "${1-}" = 0700 && test "${2-}" = "$workspace"; then
    : > "$HP2R_FIXTURE_ROOT/tmp/allocator-fault-chmod"
    exit 80
  fi
fi
exec /usr/bin/chmod "$@"
SCRIPT

  install -m 0755 /dev/stdin "$bin/chown" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
if test -n "${HP2R_INSTALL_ROOT:-}" && test "${HP2R_FIXTURE_ALLOCATOR_FAULT:-}" = chown && \
  /usr/bin/test -e "$HP2R_FIXTURE_ROOT/tmp/allocator-workspace"; then
  workspace="$(/usr/bin/cat "$HP2R_FIXTURE_ROOT/tmp/allocator-workspace")"
  if test "${1-}" = root:root && test "${2-}" = "$workspace"; then
    : > "$HP2R_FIXTURE_ROOT/tmp/allocator-fault-chown"
    exit 81
  fi
fi
exec /usr/bin/chown "$@"
SCRIPT

  install -m 0755 /dev/stdin "$bin/mktemp" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
if test -n "${HP2R_INSTALL_ROOT:-}" && test "${HP2R_FIXTURE_FAIL_MKTEMP:-}" = commit; then
  case "${@: -1}" in *hp2r-normal-backup.*|*hp2r-normal-candidate.*) exit 77;; esac
fi
if test -n "${HP2R_INSTALL_ROOT:-}" && test -n "${HP2R_FIXTURE_ALLOCATOR_FAULT:-}"; then
  case "${@: -1}" in
    "$HP2R_FIXTURE_ROOT"/var/lib/hyperpixel2r-kms/.hp2r-transaction.XXXXXX)
      if test "$HP2R_FIXTURE_ALLOCATOR_FAULT" = path; then
        unsafe="$HP2R_FIXTURE_ROOT/tmp/allocator-untrusted-path"
        /usr/bin/mkdir -p "$unsafe"
        /usr/bin/chown root:root "$unsafe"
        /usr/bin/chmod 0700 "$unsafe"
        : > "$HP2R_FIXTURE_ROOT/tmp/allocator-fault-path"
        printf '%s\n' "$unsafe"
        exit 0
      fi
      workspace="$(/usr/bin/mktemp "$@")"
      printf '%s\n' "$workspace" > "$HP2R_FIXTURE_ROOT/tmp/allocator-workspace"
      printf '%s\n' "$workspace"
      exit 0
      ;;
  esac
fi
exec /usr/bin/mktemp "$@"
SCRIPT

  install -m 0755 /dev/stdin "$bin/sha256sum" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
normal="$HP2R_FIXTURE_ROOT/boot/firmware/config.txt"
input="${@: -1}"
if test -n "${HP2R_INSTALL_ROOT:-}" && test "${HP2R_FIXTURE_INSTRUMENT_SYMLINK_FOLLOW:-}" = 1; then
  for argument in "$@"; do
    if /usr/bin/test -L "$argument"; then
      : > "$HP2R_FIXTURE_ROOT/tmp/symlink-followed-by-sha256sum"
      exit 88
    fi
  done
fi
if test -n "${HP2R_INSTALL_ROOT:-}" && test "${HP2R_FIXTURE_RACE_USER_SNAPSHOT_HASH:-}" = 1; then
  case "$input" in
    "$HP2R_FIXTURE_ROOT"/tmp/hp2r-lifecycle.*/.hp2r-normal.*|"$HP2R_FIXTURE_ROOT"/var/lib/hyperpixel2r-kms/.hp2r-transaction.*/.hp2r-normal.*)
      marker="$HP2R_FIXTURE_ROOT/tmp/user-snapshot-attack-attempted"
      if test ! -e "$marker"; then
        : > "$marker"
        workspace="$(dirname "$input")"
        target="$input"
        if setpriv --reuid=65534 --regid=65534 --clear-groups \
          env workspace="$workspace" target="$target" marker_dir="$HP2R_FIXTURE_ROOT/tmp" \
          bash -ceu '
            /usr/bin/test -d "$workspace"
            /usr/bin/ls "$workspace" >/dev/null
            /usr/bin/touch "$marker_dir/user-snapshot-listed"
            /usr/bin/mv "$target" "$target.moved"
            /usr/bin/touch "$marker_dir/user-snapshot-renamed"
            /usr/bin/rm -f -- "$target.moved"
            /usr/bin/touch "$marker_dir/user-snapshot-unlinked"
            printf "[all]\\ndtoverlay=vc4-kms-dpi-hyperpixel2r,rotate=90\\n# user snapshot replacement\\n" > "$target"
            /usr/bin/touch "$marker_dir/user-snapshot-replaced"
          '; then
          : > "$HP2R_FIXTURE_ROOT/tmp/user-snapshot-attack-succeeded"
        fi
      fi
      ;;
  esac
fi
incoming_prefix="$HP2R_FIXTURE_ROOT/tmp/hp2r-tryboot-stage.fixture/"
case "$input" in
  "$incoming_prefix"*)
    if test -n "${HP2R_INSTALL_ROOT:-}" && test "${HP2R_FIXTURE_INSTRUMENT_UNTRUSTED_SHA:-}" = 1; then
      : > "$HP2R_FIXTURE_ROOT/tmp/untrusted-incoming-sha-read"
    fi
    ;;
esac
if test -n "${HP2R_INSTALL_ROOT:-}" && test "${HP2R_FIXTURE_MUTATE_NORMAL:-}" = 1 && test "$input" = "$normal"; then
  marker="$HP2R_FIXTURE_ROOT/tmp/normal-mutated"
  count=0
  if test -f "$marker"; then count="$(cat "$marker")"; fi
  count=$((count + 1))
  printf '%s\n' "$count" > "$marker"
  if test "$count" = 2; then printf '# concurrent writer\n' >> "$normal"; fi
fi
if test -n "${HP2R_INSTALL_ROOT:-}" && test "${HP2R_FIXTURE_MUTATE_COMMIT_NORMAL_AFTER_VALIDATION:-}" = 1 && test "$input" = "$normal"; then
  marker="$HP2R_FIXTURE_ROOT/tmp/normal-commit-sha-count"
  count=0
  if test -f "$marker"; then count="$(cat "$marker")"; fi
  count=$((count + 1))
  printf '%s\n' "$count" > "$marker"
  if test "$count" = 3; then printf '# concurrent writer\n' >> "$normal"; fi
fi
exec /usr/bin/sha256sum "$@"
SCRIPT

  install -m 0755 /dev/stdin "$bin/git" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
if test "${HP2R_FIXTURE_REJECT_GIT:-}" = 1; then
  exit 99
fi
manifest="$HP2R_FIXTURE_REPO_ROOT/dist/artifacts/$HP2R_FIXTURE_RELEASE/manifest.txt"
revision="$(awk -F '\t' '$1 == "source_revision" {print $2}' "$manifest")"
tree="$(awk -F '\t' '$1 == "source_tree" {print $2}' "$manifest")"
case "${1-}" in
  cat-file)
    test "${2-}" = -e
    test "${3-}" = "$revision^{commit}"
    ;;
  rev-parse)
    test "${2-}" = "$revision^{tree}"
    printf '%s\n' "$tree"
    ;;
  show)
    case "${2-}" in "$revision":kernel/*) printf 'fixture committed source: %s\n' "${2#*:kernel/}";; *) exit 64;; esac
    ;;
  *) exit 64 ;;
esac
SCRIPT

  cp -a "$bin" "$bin_no_dkms"
  rm -f -- "$bin_no_dkms/dkms"
}

run_stage() {
  local fixture_release="${HP2R_FIXTURE_RELEASE_OVERRIDE:-$release}"
  local fixture_artifact="${HP2R_FIXTURE_ARTIFACT_DIR_OVERRIDE:-$repo_root/dist/artifacts/$release}"
  local fixture_source_root="${HP2R_FIXTURE_SOURCE_ROOT_OVERRIDE:-$repo_root}"
  local fixture_stage_repo="${HP2R_FIXTURE_STAGE_REPO_OVERRIDE:-$repo_root}"
  local fixture_replace_overlay="${HP2R_FIXTURE_REPLACE_OVERLAY-vc4-kms-dpi-hyperpixel2r}"
  local result

  if PATH="$bin:$PATH" \
    HP2R_FIXTURE_ROOT="$root" \
    HP2R_FIXTURE_RELEASE="$fixture_release" \
    HP2R_FIXTURE_LOG="$log" \
    HP2R_FIXTURE_REPO_ROOT="$fixture_source_root" \
    HP2R_RELEASE_SOURCE_ROOT="${HP2R_RELEASE_SOURCE_ROOT:-}" \
    HP2R_TARGET=pi@fixture \
    "$fixture_stage_repo/scripts/stage-tryboot.sh" \
      --artifact-dir "$fixture_artifact" \
      --replace-overlay "$fixture_replace_overlay" \
      "$@"; then
    if test "${HP2R_FIXTURE_PRESERVE_MUTATIONS:-}" != 1; then
      assert_no_private_workspaces
    fi
    return
  else
    result=$?
    if test "${HP2R_FIXTURE_PRESERVE_MUTATIONS:-}" != 1; then
      assert_no_private_workspaces
    fi
    return "$result"
  fi
}

run_controller() {
  local script="$1"
  shift
  local fixture_bin="$bin" fixture_release="${HP2R_FIXTURE_RELEASE_OVERRIDE:-$release}"
  local accepted_controller=0
  local result
  test "$script" != accepted-lifecycle.sh || accepted_controller=1
  if test "${HP2R_FIXTURE_NO_DKMS:-}" = 1; then fixture_bin="$bin_no_dkms"; fi
  if PATH="$fixture_bin:$PATH" \
    HP2R_FIXTURE_ROOT="$root" \
    HP2R_FIXTURE_RELEASE="$fixture_release" \
    HP2R_FIXTURE_LOG="$log" \
    HP2R_FIXTURE_REPO_ROOT="$repo_root" \
    HP2R_FIXTURE_ACCEPTED_CONTROLLER="$accepted_controller" \
    HP2R_LEGACY_MIGRATION_CONTRACT="${HP2R_LEGACY_MIGRATION_CONTRACT:-}" \
    HP2R_TARGET=pi@fixture \
    "$repo_root/scripts/$script" "$@"; then
    if test "${HP2R_FIXTURE_PRESERVE_MUTATIONS:-}" != 1; then
      assert_no_private_workspaces
    fi
    return
  else
    result=$?
    if test "${HP2R_FIXTURE_PRESERVE_MUTATIONS:-}" != 1; then
      assert_no_private_workspaces
    fi
    return "$result"
  fi
}

run_accepted_action_argv() {
  PATH="$bin:$PATH" \
    HP2R_FIXTURE_ROOT="$root" \
    HP2R_FIXTURE_RELEASE="$release" \
    HP2R_FIXTURE_LOG="$log" \
    HP2R_FIXTURE_REPO_ROOT="$repo_root" \
    HP2R_TARGET=pi@fixture \
    bash -c '
      ssh() { return 99; }
      export -f ssh
      exec "$@"
    ' bash "$repo_root/scripts/accepted-lifecycle.sh" "$@"
}

exercise_accepted_action_argv_parser() {
  local status

  if run_accepted_action_argv \
    --action recover-record \
    --driver-version 0.2.0 \
    --source-revision "$source_revision" \
    --kernel-release "$release" >/dev/null 2>&1; then
    fail 'single accepted action did not reach the controller transport'
  else
    status=$?
    test "$status" = 99 || fail "single accepted action was rejected before transport: $status"
  fi
  for arguments in \
    '--action unsupported' \
    '--action recover-record --action recover-record --driver-version 0.2.0 --source-revision '"$source_revision"' --kernel-release '"$release" \
    '--action recover-record --action unsupported --driver-version 0.2.0 --source-revision '"$source_revision"' --kernel-release '"$release" \
    '--action'; do
    # Intentional shell splitting: each fixture vector is an argv contract.
    if run_accepted_action_argv $arguments >/dev/null 2>&1; then
      fail "accepted action parser accepted malformed argv: $arguments"
    else
      status=$?
      test "$status" = 64 || fail "accepted action parser returned $status for: $arguments"
    fi
  done
}

run_accepted_remote() {
  PATH="$bin:$PATH" \
    HP2R_FIXTURE_ROOT="$root" \
    HP2R_INSTALL_ROOT="$root" \
    HP2R_FIXTURE_RELEASE="${HP2R_FIXTURE_RELEASE_OVERRIDE:-$release}" \
    HP2R_FIXTURE_LOG="$log" \
    bash "$repo_root/scripts/lifecycle-remote.sh" "$@"
}

write_fixture_prepared_anchor() {
  local transition="$1"
  local normalized_sha="${2:-8888888888888888888888888888888888888888888888888888888888888888}"
  local anchor="$(dirname "$transition")/accepted-transition-prepared.sha256"

  {
    printf 'prepared_transition_sha256=%s\n' \
      "$(sha256sum "$transition" | awk '{ print $1 }')"
    printf 'normalized_normal_config_sha256=%s\n' "$normalized_sha"
  } > "$anchor"
  chown root:root "$anchor"
  chmod 0600 "$anchor"
}

prepare_inactive_authorization_target() {
  local state_dir="$root/var/lib/hyperpixel2r-kms"
  local receipt="$state_dir/accepted-state"
  local transition="$state_dir/accepted-transition"
  local prior_config="$state_dir/accepted-transition-prior-config.txt"
  local candidate_release='6.18.39+rpt-rpi-v8'
  local candidate_revision='cccccccccccccccccccccccccccccccccccccccc'
  local release_tag candidate_kernel candidate_initramfs prior_normal_sha
  local prior_backlight_existed prior_backlight_sha

  new_target
  run_stage >/dev/null
  install_live_hardware
  run_controller commit-boot.sh >/dev/null
  run_accepted_remote record-accepted 0.2.0 "$source_revision" "$release" >/dev/null
  mkdir -p "$state_dir"
  cp "$root/boot/firmware/config.txt" "$prior_config"
  chown root:root "$prior_config"
  chmod 0600 "$prior_config"
  prior_normal_sha="$(sha256sum "$prior_config" | awk '{ print $1 }')"
  test "$prior_normal_sha" = "$(awk -F= '$1 == "normal_config_sha256" { print $2 }' "$receipt")" ||
    fail 'inactive authorization fixture did not retain the accepted prior config'
  prior_backlight_existed="$(awk -F= '$1 == "prior_backlight_rule_existed" { print $2 }' "$receipt")"
  prior_backlight_sha="$(awk -F= '$1 == "prior_backlight_rule_sha256" { print $2 }' "$receipt")"
  authorization_target_identity_sha256='9999999999999999999999999999999999999999999999999999999999999999'
  release_tag="$(printf %s "$candidate_release" | sha256sum | awk '{ print substr($1, 1, 12) }')"
  candidate_kernel="hp2r-${candidate_revision:0:12}-${release_tag}-kernel.img"
  candidate_initramfs="hp2r-${candidate_revision:0:12}-${release_tag}-initramfs.img"
  {
    printf 'schema_version=6\n'
    printf 'kind=new\n'
    printf 'phase=prepared\n'
    printf 'prior_driver_version=%s\n' "$(awk -F= '$1 == "driver_version" { print $2 }' "$receipt")"
    printf 'prior_source_revision=%s\n' "$(awk -F= '$1 == "source_revision" { print $2 }' "$receipt")"
    printf 'prior_kernel_release=%s\n' "$(awk -F= '$1 == "kernel_release" { print $2 }' "$receipt")"
    printf 'candidate_driver_version=0.2.1\n'
    printf 'candidate_source_revision=%s\n' "$candidate_revision"
    printf 'candidate_kernel_release=%s\n' "$candidate_release"
    printf 'candidate_manifest_sha256=%s\n' "$(printf a%.0s {1..64})"
    printf 'candidate_module_file=hyperpixel2r_kms.ko\n'
    printf 'candidate_module_sha256=%s\n' "$(printf b%.0s {1..64})"
    printf 'candidate_overlay_file=hyperpixel2r-kms-cccccccccccc.dtbo\n'
    printf 'candidate_overlay_sha256=%s\n' "$(printf d%.0s {1..64})"
    printf 'prior_normal_config_sha256=%s\n' "$prior_normal_sha"
    printf 'candidate_normal_config_sha256=%s\n' "$(printf e%.0s {1..64})"
    printf 'tryboot_config_sha256=%s\n' "$(printf e%.0s {1..64})"
    printf 'prior_dkms_status=registered\n'
    printf 'candidate_dkms_inventory_sha256=pending\n'
    printf 'candidate_backlight_rule_file=70-planeradar-backlight.rules\n'
    printf 'candidate_backlight_rule_sha256=%s\n' "$(printf f%.0s {1..64})"
    printf 'prior_backlight_rule_existed=%s\n' "$prior_backlight_existed"
    printf 'prior_backlight_rule_sha256=%s\n' "$prior_backlight_sha"
    printf 'prior_tryboot_existed=false\n'
    printf 'prior_tryboot_sha256=none\n'
    printf 'target_identity_sha256=%s\n' "$authorization_target_identity_sha256"
    printf 'boot_transition=inactive-kernel\n'
    printf 'prior_normal_kernel_sha256=%s\n' "$(printf 1%.0s {1..64})"
    printf 'prior_normal_initramfs_sha256=%s\n' "$(printf 2%.0s {1..64})"
    printf 'candidate_kernel_file=%s\n' "$candidate_kernel"
    printf 'candidate_kernel_sha256=%s\n' "$(printf 3%.0s {1..64})"
    printf 'candidate_initramfs_file=%s\n' "$candidate_initramfs"
    printf 'candidate_initramfs_sha256=%s\n' "$(printf 4%.0s {1..64})"
    printf 'candidate_base_dtb_sha256=%s\n' "$(printf 5%.0s {1..64})"
    printf 'candidate_vc4_overlay_sha256=%s\n' "$(printf 6%.0s {1..64})"
    printf 'explicit_normal_config_sha256=pending\n'
    printf 'normalized_normal_config_sha256=pending\n'
  } > "$transition"
  chown root:root "$transition"
  chmod 0600 "$transition"
  write_fixture_prepared_anchor "$transition"
  authorization_candidate_release="$candidate_release"
  authorization_candidate_kernel="$candidate_kernel"
  authorization_candidate_initramfs="$candidate_initramfs"
}

prepare_aligned_inactive_authorization_target() {
  local candidate_release='6.18.39+rpt-rpi-v8'
  local candidate_parent="$fixture/aligned-inactive-target"
  local candidate_target="$candidate_parent/$candidate_release"
  local candidate_artifact="$fixture/aligned-inactive-artifact"
  local target_manifest="$candidate_target/target.txt"
  local artifact_manifest="$candidate_artifact/manifest.txt"
  local source_target="$repo_root/dist/kernel-target/$release"
  local source_artifact="$repo_root/dist/artifacts/$release"
  local old_kernel="/boot/vmlinuz-$release"
  local old_initramfs="/boot/initrd.img-$release"
  local candidate_kernel="/boot/vmlinuz-$candidate_release"
  local candidate_initramfs="/boot/initrd.img-$candidate_release"
  local release_tag candidate_kernel_file candidate_initramfs_file transition

  prepare_inactive_authorization_target
  rm -rf -- "$candidate_parent" "$candidate_artifact"
  mkdir -p "$candidate_target"
  cp -a "$source_target/root" "$candidate_target/root"
  cp "$source_target/target.txt" "$target_manifest"
  cp -a "$source_artifact" "$candidate_artifact"
  cp "$candidate_target/root$old_kernel" "$candidate_target/root$candidate_kernel"
  cp "$candidate_target/root$old_initramfs" "$candidate_target/root$candidate_initramfs"
  replace_manifest_value "$artifact_manifest" kernel_release "$candidate_release"
  replace_manifest_value "$artifact_manifest" module_vermagic "$candidate_release fixture"
  replace_manifest_value "$target_manifest" target_identity_sha256 \
    bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  replace_manifest_value "$target_manifest" kernel_release "$candidate_release"
  replace_manifest_value "$target_manifest" kernel_image_path "$candidate_kernel"
  replace_manifest_value "$target_manifest" initramfs_path "$candidate_initramfs"
  replace_manifest_value "$target_manifest" kernel_image_sha256 \
    "$(sha256sum "$candidate_target/root$candidate_kernel" | awk '{ print $1 }')"
  replace_manifest_value "$target_manifest" initramfs_sha256 \
    "$(sha256sum "$candidate_target/root$candidate_initramfs" | awk '{ print $1 }')"

  transition="$root/var/lib/hyperpixel2r-kms/accepted-transition"
  release_tag="$(printf %s "$candidate_release" | sha256sum | awk '{ print substr($1, 1, 12) }')"
  candidate_kernel_file="hp2r-${source_revision:0:12}-${release_tag}-kernel.img"
  candidate_initramfs_file="hp2r-${source_revision:0:12}-${release_tag}-initramfs.img"
  replace_equals_value "$transition" target_identity_sha256 \
    bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  replace_equals_value "$transition" candidate_driver_version 0.2.0
  replace_equals_value "$transition" candidate_source_revision "$source_revision"
  replace_equals_value "$transition" candidate_manifest_sha256 \
    "$(sha256sum "$artifact_manifest" | awk '{ print $1 }')"
  replace_equals_value "$transition" candidate_module_sha256 \
    "$(awk -F '\t' '$1 == "module_sha256" { print $2 }' "$artifact_manifest")"
  replace_equals_value "$transition" candidate_overlay_file "$overlay_file"
  replace_equals_value "$transition" candidate_overlay_sha256 \
    "$(awk -F '\t' '$1 == "overlay_sha256" { print $2 }' "$artifact_manifest")"
  replace_equals_value "$transition" candidate_backlight_rule_sha256 \
    "$(awk -F '\t' '$1 == "backlight_rule_sha256" { print $2 }' "$artifact_manifest")"
  replace_equals_value "$transition" candidate_kernel_file "$candidate_kernel_file"
  replace_equals_value "$transition" candidate_kernel_sha256 \
    "$(awk -F '\t' '$1 == "kernel_image_sha256" { print $2 }' "$target_manifest")"
  replace_equals_value "$transition" candidate_initramfs_file "$candidate_initramfs_file"
  replace_equals_value "$transition" candidate_initramfs_sha256 \
    "$(awk -F '\t' '$1 == "initramfs_sha256" { print $2 }' "$target_manifest")"
  replace_equals_value "$transition" candidate_base_dtb_sha256 \
    "$(awk -F '\t' '$1 == "base_dtb_sha256" { print $2 }' "$target_manifest")"
  replace_equals_value "$transition" candidate_vc4_overlay_sha256 \
    "$(awk -F '\t' '$1 == "vc4_overlay_sha256" { print $2 }' "$target_manifest")"
  chown root:root "$transition"
  chmod 0600 "$transition"
  write_fixture_prepared_anchor "$transition"
  aligned_candidate_release="$candidate_release"
  aligned_candidate_target_parent="$candidate_parent"
  aligned_candidate_artifact="$candidate_artifact"
}

run_accepted_controller() {
  PATH="$bin:$PATH" \
    HP2R_FIXTURE_ROOT="$root" \
    HP2R_FIXTURE_RELEASE="$release" \
    HP2R_FIXTURE_LOG="$log" \
    HP2R_FIXTURE_REPO_ROOT="$repo_root" \
    HP2R_FIXTURE_ACCEPTED_CONTROLLER=1 \
    HP2R_TARGET=pi@fixture \
    "$repo_root/scripts/accepted-lifecycle.sh" \
      --action recover-record \
      --driver-version 0.2.0 \
      --source-revision "$source_revision" \
      --kernel-release "$release"
}

run_accepted_prepare_controller() {
  local manifest="$repo_root/dist/artifacts/$release/manifest.txt"

  PATH="$bin:$PATH" \
    HP2R_FIXTURE_ROOT="$root" \
    HP2R_FIXTURE_RELEASE="$release" \
    HP2R_FIXTURE_LOG="$log" \
    HP2R_FIXTURE_REPO_ROOT="$repo_root" \
    HP2R_FIXTURE_ACCEPTED_CONTROLLER=1 \
    HP2R_TARGET=pi@fixture \
    "$repo_root/scripts/accepted-lifecycle.sh" \
      --action prepare-new \
      --driver-version 0.2.1 \
      --source-revision "$source_revision" \
      --kernel-release "$release" \
      --kernel-target "$repo_root/dist/kernel-target" \
      --target-identity-sha256 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
      --manifest-sha256 "$(sha256sum "$manifest" | awk '{ print $1 }')" \
      --module-file hyperpixel2r_kms.ko \
      --module-sha256 "$(awk -F '\t' '$1 == "module_sha256" { print $2 }' "$manifest")" \
      --overlay-file "$overlay_file" \
      --overlay-sha256 "$(awk -F '\t' '$1 == "overlay_sha256" { print $2 }' "$manifest")" \
      --backlight-rule-file "$backlight_rule_file" \
      --backlight-rule-sha256 "$(awk -F '\t' '$1 == "backlight_rule_sha256" { print $2 }' "$manifest")" \
      --lifecycle-capability exact-backlight-metadata-v1
}

prepare_recoverable_record_orphan() {
  local state_dir="$root/var/lib/hyperpixel2r-kms"
  local workspace_suffix=WorkspaceFixture
  local normal_suffix=SnapshotFixture

  # Derive the stock leaf through the existing recorder, then discard its
  # published receipt.  This leaves the exact two snapshots created by the
  # historical post-allocation cleanup defect, without relying on a hand-coded
  # approximation of stock derivation.
  prepare_record_failure_target
  run_accepted_remote record-accepted 0.2.0 "$source_revision" "$release" >/dev/null
  recover_derived_stock="$fixture/recover-derived-stock"
  cp "$state_dir/accepted-stock-config.txt" "$recover_derived_stock"
  rm -f -- "$state_dir/accepted-state" "$state_dir/accepted-stock-config.txt"
  recover_workspace="$state_dir/.hp2r-transaction.$workspace_suffix"
  mkdir "$recover_workspace"
  recover_normal_snapshot="$recover_workspace/.hp2r-accepted-normal.$normal_suffix"
  cp "$root/boot/firmware/config.txt" "$recover_normal_snapshot"
  cp "$recover_derived_stock" "$recover_workspace/accepted-stock"
  chown root:root "$recover_workspace" "$recover_normal_snapshot" \
    "$recover_workspace/accepted-stock"
  chmod 0700 "$recover_workspace"
  chmod 0600 "$recover_normal_snapshot" "$recover_workspace/accepted-stock"
  printf 'unrelated lifecycle state\n' > "$state_dir/recovery-unrelated-state"
  chown root:root "$state_dir/recovery-unrelated-state"
  chmod 0600 "$state_dir/recovery-unrelated-state"
  mkdir -p "$root/opt"
  printf 'unrelated installed state\n' > "$root/opt/recovery-unrelated-target"
  chown root:root "$root/opt" "$root/opt/recovery-unrelated-target"
  chmod 0755 "$root/opt"
  chmod 0644 "$root/opt/recovery-unrelated-target"
  assert_exact_recoverable_record_orphan
}

assert_exact_recoverable_record_orphan() {
  local normal_snapshot="$recover_normal_snapshot"
  local stock_snapshot="$recover_workspace/accepted-stock"
  local leaf_count
  local workspace_count
  local workspace_suffix="${recover_workspace##*.}"
  local normal_suffix="${normal_snapshot##*.}"

  [[ "$workspace_suffix" =~ ^[A-Za-z0-9]+$ ]] ||
    fail 'recoverable record workspace suffix is unsafe'
  [[ "$normal_suffix" =~ ^[A-Za-z0-9]+$ ]] ||
    fail 'recoverable normal snapshot suffix is unsafe'
  test "$workspace_suffix" != "$normal_suffix" ||
    fail 'recoverable fixture coupled independent mktemp suffixes'
  test "$(stat -c '%U:%G:%a' "$recover_workspace")" = root:root:700 ||
    fail 'recoverable record workspace ownership or mode is wrong'
  assert_file "$normal_snapshot"
  assert_file "$stock_snapshot"
  test "$(stat -c '%U:%G:%a' "$normal_snapshot")" = root:root:600 ||
    fail 'recoverable normal snapshot ownership or mode is wrong'
  test "$(stat -c '%U:%G:%a' "$stock_snapshot")" = root:root:600 ||
    fail 'recoverable stock snapshot ownership or mode is wrong'
  leaf_count="$(find "$recover_workspace" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d ' ')"
  test "$leaf_count" = 2 || fail 'recoverable record workspace has unexpected leaves'
  workspace_count="$(find "$(dirname "$recover_workspace")" -mindepth 1 -maxdepth 1 \
    -name '.hp2r-transaction.*' -print | wc -l | tr -d ' ')"
  test "$workspace_count" = 1 ||
    fail 'recoverable record fixture has competing transaction workspaces'
  cmp -s "$normal_snapshot" "$root/boot/firmware/config.txt" ||
    fail 'recoverable normal snapshot is not the current normal config'
  cmp -s "$stock_snapshot" "$recover_derived_stock" ||
    fail 'recoverable stock snapshot is not freshly derived'
  assert_absent "$root/var/lib/hyperpixel2r-kms/accepted-state"
  assert_absent "$root/var/lib/hyperpixel2r-kms/accepted-stock-config.txt"
}

capture_recovery_state() {
  local archive="$1"
  local state_dir="$root/var/lib/hyperpixel2r-kms"

  # Snapshot every durable entry, but not the containing directory metadata:
  # verifier-workspace allocation may legitimately change only that mtime.
  (
    cd "$state_dir"
    find . -mindepth 1 -maxdepth 1 -print0 |
      sort -z |
      tar --numeric-owner --null -T - -cf "$archive"
  )
}

capture_recovery_target() {
  local archive="$1"
  local state_relative=var/lib/hyperpixel2r-kms

  # The remote action must reject before touching normal boot state, the
  # manifest-bound artifact, installed module, or installed overlay.  Exclude
  # only fixture instrumentation and the state-directory inode itself, then
  # append every durable state entry with metadata and bytes.
  tar --numeric-owner --sort=name \
    --exclude='./tmp' \
    --exclude="./$state_relative" \
    -C "$root" -cf "$archive" .
  (
    cd "$root"
    find "./$state_relative" -mindepth 1 -maxdepth 1 -print0 |
      sort -z |
      tar --numeric-owner --null -T - -rf "$archive"
  )
}

capture_recovery_preserved_target() {
  local archive="$1"
  local state_relative=var/lib/hyperpixel2r-kms

  # A successful recovery may remove only the validated transaction
  # workspace.  Preserve and compare every other target byte and metadata bit,
  # including unrelated fixed-state-directory and installed-target sentinels.
  # Exclude the state directory itself because removing its child necessarily
  # changes the directory mtime, then append every non-workspace entry.
  tar --numeric-owner --sort=name \
    --exclude='./tmp' \
    --exclude="./$state_relative" \
    -C "$root" -cf "$archive" .
  (
    cd "$root"
    find "./$state_relative" -mindepth 1 -maxdepth 1 \
      ! -name '.hp2r-transaction.*' -print0 |
      sort -z |
      tar --numeric-owner --null -T - -rf "$archive"
  )
}

assert_recovery_rejection_preserves_state() {
  local label="$1"
  local version="${2:-0.2.0}"
  local revision="${3:-$source_revision}"
  local kernel="${4:-$release}"
  local before="$fixture/recover-record-$label-before.tar"
  local after="$fixture/recover-record-$label-after.tar"
  local target_before="$fixture/recover-record-$label-target-before.tar"
  local target_after="$fixture/recover-record-$label-target-after.tar"

  capture_recovery_state "$before"
  capture_recovery_target "$target_before"
  if run_accepted_remote recover-accepted-record "$version" "$revision" "$kernel" \
    >"$fixture/recover-record-$label.out" 2>&1; then
    fail "recover-record accepted hostile state: $label"
  fi
  capture_recovery_state "$after"
  cmp -s "$before" "$after" ||
    fail "recover-record mutated workspace or state after rejecting $label"
  capture_recovery_target "$target_after"
  cmp -s "$target_before" "$target_after" ||
    fail "recover-record mutated installed state after rejecting $label"
}

assert_recovery_no_receipt() {
  assert_absent "$root/var/lib/hyperpixel2r-kms/accepted-state"
  assert_absent "$root/var/lib/hyperpixel2r-kms/accepted-stock-config.txt"
}

install_live_hardware() {
  mkdir -p \
    "$root/sys/module/hyperpixel2r_kms" \
    "$root/sys/bus/platform/drivers/hyperpixel2r-kms" \
    "$root/sys/devices/platform/fixture-panel/of_node" \
    "$root/sys/class/drm/card0-DPI-1" \
    "$root/sys/class/backlight/planeradar-backlight" \
    "$root/sys/class/input/event0/device"
  ln -s ../../../../devices/platform/fixture-panel \
    "$root/sys/bus/platform/drivers/hyperpixel2r-kms/fixture-panel"
  printf '%s\n' "${HP2R_FIXTURE_LIVE_DRIVER_VERSION:-0.2.0}" > "$root/sys/module/hyperpixel2r_kms/version"
  printf 'shayne,hyperpixel2r-kms\0' > "$root/sys/devices/platform/fixture-panel/of_node/compatible"
  printf 'connected\n' > "$root/sys/class/drm/card0-DPI-1/status"
  printf '480x480\n' > "$root/sys/class/drm/card0-DPI-1/modes"
  printf '255\n' > "$root/sys/class/backlight/planeradar-backlight/max_brightness"
  printf '128\n' > "$root/sys/class/backlight/planeradar-backlight/brightness"
  printf 'EDT FT5406\n' > "$root/sys/class/input/event0/device/name"
}

exercise_backlight_udev_settle() {
  new_target
  run_stage >/dev/null
  install_live_hardware
  run_controller commit-boot.sh >/dev/null
  grep -Fxq 'udevadm trigger --settle planeradar-backlight' "$log" ||
    fail 'candidate permission reload did not settle its targeted udev event'
}

assert_backlight_brightness_metadata() {
  local expected="$1"
  local brightness="$root/sys/class/backlight/planeradar-backlight/brightness"

  test "$(stat -c '%u:%g:%a' "$brightness")" = "$expected" ||
    fail "backlight brightness metadata differs from $expected"
}

apply_fixture_candidate_backlight_permissions() {
  HP2R_FIXTURE_ROOT="$root" HP2R_FIXTURE_LOG="$log" \
    "$bin/udevadm" trigger --action=add --subsystem-match=backlight \
      --sysname-match=planeradar-backlight --settle
}

exercise_backlight_permission_restore() {
  local original_metadata artifact metadata

  new_target
  install_live_hardware
  chown 0:4242 "$root/sys/class/backlight/planeradar-backlight/brightness"
  chmod 0640 "$root/sys/class/backlight/planeradar-backlight/brightness"
  original_metadata="$(stat -c '%u:%g:%a' \
    "$root/sys/class/backlight/planeradar-backlight/brightness")"
  test "$original_metadata" = 0:4242:640 ||
    fail 'fixture backlight did not begin with non-default metadata'
  run_stage >/dev/null
  apply_fixture_candidate_backlight_permissions
  test "$(stat -c '%U:%G:%a' \
    "$root/sys/class/backlight/planeradar-backlight/brightness")" = root:video:660 ||
    fail 'candidate udev policy did not change backlight metadata'
  run_controller rollback-boot.sh >/dev/null
  assert_backlight_brightness_metadata "$original_metadata"
  artifact="$root/usr/lib/hyperpixel2r-kms/0.2.0/$source_revision/$release"
  cp "$artifact/$backlight_rule_file" "$backlight_rule_path"
  chown root:root "$backlight_rule_path"
  chmod 0644 "$backlight_rule_path"
  apply_fixture_candidate_backlight_permissions
  run_controller uninstall.sh >/dev/null
  assert_backlight_brightness_metadata "$original_metadata"

  new_target
  install_live_hardware
  chown 0:4242 "$root/sys/class/backlight/planeradar-backlight/brightness"
  chmod 0640 "$root/sys/class/backlight/planeradar-backlight/brightness"
  original_metadata="$(stat -c '%u:%g:%a' \
    "$root/sys/class/backlight/planeradar-backlight/brightness")"
  run_stage >/dev/null
  apply_fixture_candidate_backlight_permissions
  if HP2R_FIXTURE_INTERRUPT_AFTER=rollback-boot-restored-unpublished \
    HP2R_FIXTURE_PRESERVE_MUTATIONS=1 \
    run_controller rollback-boot.sh >/dev/null 2>&1; then
    fail 'rollback ignored the backlight-restoration interruption'
  else
    test "$?" = 97 || fail 'interrupted backlight rollback returned the wrong status'
  fi
  assert_backlight_brightness_metadata "$original_metadata"
  find "$root/var/lib/hyperpixel2r-kms" -mindepth 1 -maxdepth 1 \
    -type d -name '.hp2r-transaction.*' -exec rm -rf -- {} +
  run_controller rollback-boot.sh >/dev/null
  assert_backlight_brightness_metadata "$original_metadata"

  new_target
  install_live_hardware
  chown 0:4242 "$root/sys/class/backlight/planeradar-backlight/brightness"
  chmod 0640 "$root/sys/class/backlight/planeradar-backlight/brightness"
  original_metadata="$(stat -c '%u:%g:%a' \
    "$root/sys/class/backlight/planeradar-backlight/brightness")"
  run_stage >/dev/null
  run_controller commit-boot.sh >/dev/null
  run_accepted_remote record-accepted \
    0.2.0 "$source_revision" "$release" >/dev/null
  test "$(stat -c '%U:%G:%a' \
    "$root/sys/class/backlight/planeradar-backlight/brightness")" = root:video:660 ||
    fail 'accepted candidate did not retain its backlight permissions'
  if HP2R_FIXTURE_INTERRUPT_AFTER=uninstall-rule-restored \
    run_accepted_remote uninstall-accepted \
      0.2.0 "$source_revision" "$release" >/dev/null 2>&1; then
    fail 'accepted uninstall ignored the rule-restoration interruption'
  fi
  run_accepted_remote uninstall-accepted \
    0.2.0 "$source_revision" "$release" >/dev/null
  run_accepted_remote finalize-uninstall-accepted >/dev/null
  assert_backlight_brightness_metadata "$original_metadata"

  new_target
  printf 'fixture inert prior backlight policy\n' > "$backlight_rule_path"
  chown root:root "$backlight_rule_path"
  chmod 0644 "$backlight_rule_path"
  run_stage >/dev/null
  install_live_hardware
  apply_fixture_candidate_backlight_permissions
  run_controller rollback-boot.sh >/dev/null
  assert_backlight_brightness_metadata 0:0:644

  new_target
  install_live_hardware
  chown 0:4242 "$root/sys/class/backlight/planeradar-backlight/brightness"
  chmod 0640 "$root/sys/class/backlight/planeradar-backlight/brightness"
  run_stage >/dev/null
  artifact="$root/usr/lib/hyperpixel2r-kms/0.2.0/$source_revision/$release"
  metadata="$artifact/prior-backlight-metadata"
  assert_file "$metadata"
  rm -rf -- "$root/sys/class/backlight/planeradar-backlight"
  if run_controller rollback-boot.sh >/dev/null 2>&1; then
    fail 'rollback retired present backlight metadata while the device was missing'
  fi
  assert_file "$metadata"
}

exercise_backlight_metadata_authority() {
  local artifact metadata metadata_sha transition uninstall

  new_target
  install_live_hardware
  chown 0:4242 "$root/sys/class/backlight/planeradar-backlight/brightness"
  chmod 0640 "$root/sys/class/backlight/planeradar-backlight/brightness"
  run_stage >/dev/null
  apply_fixture_candidate_backlight_permissions
  artifact="$root/usr/lib/hyperpixel2r-kms/0.2.0/$source_revision/$release"
  metadata="$artifact/prior-backlight-metadata"
  rm -- "$metadata"
  if run_controller rollback-boot.sh >/dev/null 2>&1; then
    fail 'rollback accepted missing exact backlight metadata authority'
  fi

  new_target
  install_live_hardware
  chown 0:4242 "$root/sys/class/backlight/planeradar-backlight/brightness"
  chmod 0640 "$root/sys/class/backlight/planeradar-backlight/brightness"
  run_stage >/dev/null
  apply_fixture_candidate_backlight_permissions
  artifact="$root/usr/lib/hyperpixel2r-kms/0.2.0/$source_revision/$release"
  metadata="$artifact/prior-backlight-metadata"
  sed -i 's/^mode=.*/mode=600/' "$metadata"
  if run_controller rollback-boot.sh >/dev/null 2>&1; then
    fail 'rollback accepted modified exact backlight metadata authority'
  fi

  prepare_accepted_prior_tryboot_target
  prepare_prior_tryboot_candidate_source
  run_prior_tryboot_candidate_prepare >/dev/null
  HP2R_FIXTURE_REPLACE_OVERLAY="$overlay_file" \
    HP2R_FIXTURE_ARTIFACT_DIR_OVERRIDE="$candidate_artifact" \
    HP2R_FIXTURE_SOURCE_ROOT_OVERRIDE="$candidate_source" \
    run_stage >/dev/null
  artifact="$root/usr/lib/hyperpixel2r-kms/0.2.0/$candidate_revision/$release"
  metadata="$artifact/prior-backlight-metadata"
  transition="$root/var/lib/hyperpixel2r-kms/accepted-transition"
  metadata_sha="$(sha256sum "$metadata" | awk '{ print $1 }')"
  grep -Fxq "candidate_prior_backlight_metadata_sha256=$metadata_sha" "$transition" ||
    fail 'staged accepted transition did not bind exact backlight metadata'
  sed -i 's/^mode=.*/mode=600/' "$metadata"
  if run_accepted_remote recover-accepted >/dev/null 2>&1; then
    fail 'accepted transition recovery trusted modified backlight metadata'
  fi
  assert_file "$transition"

  new_target
  install_live_hardware
  chown 0:4242 "$root/sys/class/backlight/planeradar-backlight/brightness"
  chmod 0640 "$root/sys/class/backlight/planeradar-backlight/brightness"
  run_stage >/dev/null
  run_controller commit-boot.sh >/dev/null
  run_accepted_remote record-accepted \
    0.2.0 "$source_revision" "$release" >/dev/null
  artifact="$root/usr/lib/hyperpixel2r-kms/0.2.0/$source_revision/$release"
  metadata="$artifact/prior-backlight-metadata"
  metadata_sha="$(sha256sum "$metadata" | awk '{ print $1 }')"
  if HP2R_FIXTURE_INTERRUPT_AFTER=uninstall-journal-published \
    run_accepted_remote uninstall-accepted \
      0.2.0 "$source_revision" "$release" >/dev/null 2>&1; then
    fail 'accepted uninstall ignored metadata journal interruption'
  fi
  uninstall="$root/var/lib/hyperpixel2r-kms/accepted-uninstall"
  grep -Fxq 'backlight_metadata_capability=exact-backlight-metadata-v1' "$uninstall" ||
    fail 'accepted uninstall journal lost backlight metadata capability'
  grep -Fxq "prior_backlight_metadata_sha256=$metadata_sha" "$uninstall" ||
    fail 'accepted uninstall journal lost exact backlight metadata digest'
  sed -i 's/^mode=.*/mode=600/' "$metadata"
  if run_accepted_remote uninstall-accepted \
    0.2.0 "$source_revision" "$release" >/dev/null 2>&1; then
    fail 'accepted uninstall trusted modified backlight metadata authority'
  fi
  assert_file "$uninstall"
}

exercise_schema_two_candidate_upgrade() {
  local candidate_source candidate_artifact candidate_manifest
  local candidate_manifest_sha candidate_module_sha candidate_overlay_sha candidate_rule_sha
  local candidate_revision candidate_overlay transition

  new_target
  run_stage >/dev/null
  install_live_hardware
  run_controller commit-boot.sh >/dev/null
  run_accepted_remote record-accepted \
    0.2.0 "$source_revision" "$release" >/dev/null

  candidate_source="$fixture/schema-two-candidate-source"
  candidate_artifact="$candidate_source/dist/artifacts/$release"
  mkdir -p "$(dirname "$candidate_artifact")"
  cp -a "$repo_root/dist/artifacts/$release" "$candidate_artifact"
  candidate_manifest="$candidate_artifact/manifest.txt"
  candidate_revision='cccccccccccccccccccccccccccccccccccccccc'
  candidate_overlay='hyperpixel2r-kms-cccccccccccc.dtbo'
  mv "$candidate_artifact/$overlay_file" "$candidate_artifact/$candidate_overlay"
  sed -i \
    -e 's/^schema_version\t3$/schema_version\t2/' \
    -e '/^lifecycle_capability\t/d' \
    -e "s/^source_revision\t.*/source_revision\t$candidate_revision/" \
    -e "s/^overlay_file\t.*/overlay_file\t$candidate_overlay/" \
    "$candidate_manifest"
  candidate_manifest_sha="$(sha256sum "$candidate_manifest" | awk '{ print $1 }')"
  candidate_module_sha="$(awk -F '\t' '$1 == "module_sha256" { print $2 }' "$candidate_manifest")"
  candidate_overlay_sha="$(awk -F '\t' '$1 == "overlay_sha256" { print $2 }' "$candidate_manifest")"
  candidate_rule_sha="$(awk -F '\t' '$1 == "backlight_rule_sha256" { print $2 }' "$candidate_manifest")"

  run_accepted_remote prepare-new-accepted \
    0.2.0 "$candidate_revision" "$release" "$candidate_manifest_sha" \
    hyperpixel2r_kms.ko "$candidate_module_sha" \
    "$candidate_overlay" "$candidate_overlay_sha" \
    "$backlight_rule_file" "$candidate_rule_sha" >/dev/null
  transition="$root/var/lib/hyperpixel2r-kms/accepted-transition"
  if grep -q '^backlight_metadata_capability=' "$transition"; then
    fail 'schema-2 candidate transition falsely advertised metadata authority'
  fi
  if ! HP2R_FIXTURE_REPLACE_OVERLAY="$overlay_file" \
    HP2R_FIXTURE_ARTIFACT_DIR_OVERRIDE="$candidate_artifact" \
    HP2R_FIXTURE_SOURCE_ROOT_OVERRIDE="$candidate_source" \
    run_stage >"$fixture/schema-two-stage.out" 2>&1; then
    cat "$fixture/schema-two-stage.out" >&2
    fail 'schema-2 candidate could not stage through the legacy boundary'
  fi
  assert_absent \
    "$root/usr/lib/hyperpixel2r-kms/0.2.0/$candidate_revision/$release/prior-backlight-metadata"
  if ! run_accepted_remote recover-accepted \
    >"$fixture/schema-two-recover.out" 2>&1; then
    cat "$fixture/schema-two-recover.out" >&2
    fail 'schema-2 candidate could not recover through the legacy boundary'
  fi
  assert_absent "$transition"
}

run_verify() {
  PATH="$bin:$PATH" \
    HP2R_FIXTURE_ROOT="$root" \
    HP2R_FIXTURE_RELEASE="$release" \
    HP2R_FIXTURE_LOG="$log" \
    HP2R_FIXTURE_REPO_ROOT="$repo_root" \
    HP2R_FIXTURE_REMOTE_BIN="$bin" \
    HP2R_FIXTURE_REMOTE_SBIN="$sbin" \
    HP2R_TARGET=pi@fixture \
    "$repo_root/scripts/verify-boot.sh" --expect-tryboot --json "$@"
}

exercise_verify_restricted_path() {
  local command_name json resolved

  new_target
  run_stage >/dev/null
  install_live_hardware
  mv "$bin/modinfo" "$sbin/modinfo"
  for command_name in bash id od tr awk grep readlink stat sha256sum dirname sed wc; do
    test ! -e "$bin/$command_name" && test ! -L "$bin/$command_name" || continue
    resolved="$(command -v "$command_name")"
    test "${resolved#/}" != "$resolved" && test -x "$resolved" ||
      fail "restricted verifier fixture is missing $command_name"
    ln -s "$resolved" "$bin/$command_name"
  done
  export HP2R_FIXTURE_REMOTE_RESTRICTED_PATH=1
  json="$(run_verify \
    --expect-driver-version 0.2.0 \
    --expect-overlay-file "$overlay_file" \
    --expect-module-file hyperpixel2r_kms.ko \
    --expect-module-sha256 "$(sha256sum "$root/lib/modules/$release/extra/hyperpixel2r_kms.ko" | awk '{ print $1 }')")"
  unset HP2R_FIXTURE_REMOTE_RESTRICTED_PATH
  mv "$sbin/modinfo" "$bin/modinfo"
  test "$json" = '{"schema_version":1,"driver_version":"0.2.0","kernel_release":"6.18.34+rpt-rpi-v8","module":"hyperpixel2r_kms","drm_mode":"480x480","touch":true,"sdl_driver":"KMSDRM","renderer":"opengles2","accepted":true}' ||
    fail 'verify failed to resolve a target sbin-only modinfo'
}

assert_verify_rejects_binding() {
  local label="$1"

  if run_verify >/dev/null 2>&1; then
    fail "verify accepted $label"
  fi
}

prepare_prior_dkms() {
  local label="$1"
  local registration="${2:-added}"
  local directory="$root/usr/src/hyperpixel2r-kms-0.2.0"
  local name

  mkdir -p "$directory" "$root/var/lib/dkms"
  for name in Kbuild Makefile dkms.conf hyperpixel2r_kms_main.c hyperpixel2r_kms_gpio.c hyperpixel2r_kms_gpio.h hyperpixel2r_kms_protocol.c hyperpixel2r_kms_protocol.h; do
    printf 'fixture prior %s: %s\n' "$label" "$name" > "$directory/$name"
  done
  chown -R root:root "$directory"
  chmod 0755 "$directory"
  chmod 0644 "$directory"/*
  case "$registration" in
    registered|added) printf 'added\n' > "$root/var/lib/dkms/registered" ;;
    built)
      printf 'added\n' > "$root/var/lib/dkms/registered"
      set_prior_dkms_kernel_state "$release" built
      ;;
    installed)
      printf 'added\n' > "$root/var/lib/dkms/registered"
      set_prior_dkms_kernel_state "$release" installed
      ;;
    unregistered) ;;
    *) fail "unsupported prior DKMS registration fixture: $registration" ;;
  esac
}

prepare_exact_candidate_dkms() {
  local registration="${1:-added}"
  local directory="$root/usr/src/hyperpixel2r-kms-0.2.0"
  local name

  mkdir -p "$directory" "$root/var/lib/dkms"
  for name in Kbuild Makefile dkms.conf hyperpixel2r_kms_main.c hyperpixel2r_kms_gpio.c hyperpixel2r_kms_gpio.h hyperpixel2r_kms_protocol.c hyperpixel2r_kms_protocol.h; do
    printf 'fixture committed source: %s\n' "$name" > "$directory/$name"
  done
  chown -R root:root "$directory"
  chmod 0755 "$directory"
  chmod 0644 "$directory"/*
  case "$registration" in
    added) printf 'added\n' > "$root/var/lib/dkms/registered" ;;
    installed)
      printf 'added\n' > "$root/var/lib/dkms/registered"
      set_prior_dkms_kernel_state "$release" installed
      ;;
    *) fail "unsupported exact candidate DKMS registration fixture: $registration" ;;
  esac
}

prepare_installed_rollback_shape() {
  local shape="$1"
  local label="$2"

  shared_extra_module="$root/lib/modules/$release/extra/hyperpixel2r_kms.ko"
  shared_extra_sha=none
  case "$shape" in
    created)
      prepare_exact_candidate_dkms installed
      ;;
    shared)
      prepare_prior_dkms "$label" installed
      mkdir -p "$(dirname "$shared_extra_module")"
      cp "$candidate_manifest_module" "$shared_extra_module"
      chown root:root "$shared_extra_module"
      chmod 0644 "$shared_extra_module"
      shared_extra_sha="$(sha256sum "$shared_extra_module" | awk '{ print $1 }')"
      ;;
    *) fail "unsupported rollback matrix shape: $shape" ;;
  esac
  prior_installed_module="$root/lib/modules/$release/updates/dkms/hyperpixel2r_kms.ko"
  prior_installed_sha="$(sha256sum "$prior_installed_module" | awk '{ print $1 }')"
  PATH="$bin:$PATH" HP2R_FIXTURE_ROOT="$root" HP2R_FIXTURE_RELEASE="$release" depmod -a "$release"
  run_stage >/dev/null
  state="$root/var/lib/hyperpixel2r-kms/tryboot-state"
  grep -Fxq 'schema_version=4' "$state" ||
    fail "rollback matrix shape is not schema 4: $shape"
  if test "$shape" = shared; then
    grep -Fxq 'module_existed=true' "$state" ||
      fail 'shared rollback matrix did not record its preexisting module'
  else
    grep -Fxq 'module_existed=false' "$state" ||
      fail 'created rollback matrix did not record its transaction-created module'
  fi
  first_artifact="$root/usr/lib/hyperpixel2r-kms/0.2.0/$source_revision/$release"
  assert_dkms_inventory "$first_artifact/dkms-prior-state" added \
    "$release"$'\taarch64\tinstalled'
}

assert_installed_rollback_shape_restored() {
  local shape="$1"
  local boundary="$2"

  assert_file "$prior_installed_module"
  test "$(sha256sum "$prior_installed_module" | awk '{ print $1 }')" = "$prior_installed_sha" ||
    fail "$shape replay after $boundary changed prior module bytes"
  assert_absent "$root/var/lib/hyperpixel2r-kms/tryboot-state"
  assert_absent "$root/var/lib/hyperpixel2r-kms/rollback-state"
  assert_absent "$root/var/lib/hyperpixel2r-kms/rollback-candidate-dkms-state"
  assert_absent "$root/var/lib/hyperpixel2r-kms/rollback-candidate-tryboot.txt"
  if test "$shape" = shared; then
    assert_file "$shared_extra_module"
    test "$(sha256sum "$shared_extra_module" | awk '{ print $1 }')" = "$shared_extra_sha" ||
      fail "shared replay after $boundary changed the preexisting /extra module"
  else
    assert_absent "$shared_extra_module"
  fi
  assert_absent "$shared_extra_module.hp2r-rollback-hold"
  grep -Fxq 'hyperpixel2r_kms.ko: updates/dkms/hyperpixel2r_kms.ko' \
    "$root/lib/modules/$release/modules.dep" ||
    fail "$shape replay after $boundary did not resolve prior DKMS"
}

run_fixture_dkms() {
  PATH="$bin:$PATH" \
    HP2R_FIXTURE_ROOT="$root" \
    HP2R_FIXTURE_RELEASE="$release" \
    dkms "$@"
}

set_prior_dkms_kernel_state() {
  local kernel="$1"
  local state="$2"
  local architecture="${3:-aarch64}"

  case "$state" in
    built)
      run_fixture_dkms build -m hyperpixel2r-kms -v 0.2.0 \
        -k "$kernel" -a "$architecture"
      ;;
    installed)
      run_fixture_dkms build -m hyperpixel2r-kms -v 0.2.0 \
        -k "$kernel" -a "$architecture"
      run_fixture_dkms install -m hyperpixel2r-kms -v 0.2.0 \
        -k "$kernel" -a "$architecture"
      ;;
    *) fail "unsupported per-kernel DKMS state fixture: $state" ;;
  esac
}

assert_dkms_kernel_state() {
  local kernel="$1"
  local expected_state="$2"
  local architecture="${3:-aarch64}"
  local marker="$root/var/lib/dkms/registered"

  assert_file "$marker"
  test "$(awk -F '\t' -v wanted_kernel="$kernel" -v wanted_arch="$architecture" '
    NR > 1 && $1 == wanted_kernel && $2 == wanted_arch { print $3 }
  ' "$marker")" = "$expected_state" ||
    fail "prior DKMS status was not restored: $kernel/$architecture $expected_state"
}

assert_dkms_inventory() {
  local marker="$1"
  local source_state="$2"
  shift 2
  local expected="$fixture/expected-dkms-inventory"
  local row

  {
    printf 'schema_version=2\n'
    printf 'source_state=%s\n' "$source_state"
    printf 'kernel_count=%s\n' "$#"
    for row in "$@"; do printf 'kernel=%s\n' "$row"; done
  } > "$expected"
  cmp -s "$expected" "$marker" || {
    printf 'unexpected DKMS inventory in %s\n' "$marker" >&2
    diff -u "$expected" "$marker" >&2 || true
    return 1
  }
}

assert_prior_dkms() {
  local expected_sums="$1"
  local registration="${2:-added}"
  local directory="$root/usr/src/hyperpixel2r-kms-0.2.0"

  test "$(stat -c '%U:%G:%a' "$directory")" = root:root:755 || fail 'prior DKMS directory ownership or mode drifted'
  while IFS=' ' read -r expected name; do
    test "$(sha256sum "$directory/$name" | awk '{print $1}')" = "$expected" ||
      fail "prior DKMS bytes were not restored: $name"
    test "$(stat -c '%U:%G:%a' "$directory/$name")" = root:root:644 ||
      fail "prior DKMS file ownership or mode drifted: $name"
  done < "$expected_sums"
  case "$registration" in
    registered|added)
      assert_file "$root/var/lib/dkms/registered"
      test "$(cat "$root/var/lib/dkms/registered")" = added ||
        fail "prior DKMS status was not restored: $registration"
      ;;
    built|installed) assert_dkms_kernel_state "$release" "$registration" ;;
    inventory)
      assert_file "$root/var/lib/dkms/registered"
      test "$(sed -n '1p' "$root/var/lib/dkms/registered")" = added ||
        fail 'prior DKMS inventory source state was not restored'
      ;;
    unregistered) assert_absent "$root/var/lib/dkms/registered" ;;
    *) fail "unsupported expected prior DKMS registration: $registration" ;;
  esac
}

assert_clean_failed_stage() {
  if test -e "$root/boot/firmware/tryboot.txt" || test -L "$root/boot/firmware/tryboot.txt"; then
    test ! -f "$fixture/last-stage-output" || cat "$fixture/last-stage-output" >&2
  fi
  assert_absent "$root/boot/firmware/tryboot.txt"
  assert_absent "$root/var/lib/hyperpixel2r-kms/tryboot-state"
  assert_absent "$root/lib/modules/$release/extra/hyperpixel2r_kms.ko"
  assert_absent "$root/boot/firmware/overlays/$overlay_file"
  if test -e "$root/usr/lib/hyperpixel2r-kms"; then
    find "$root/usr/lib/hyperpixel2r-kms" -printf 'surviving stage path: %P %u:%g %m\n' >&2
  fi
  assert_absent "$root/usr/lib/hyperpixel2r-kms"
  assert_absent "$root/usr/src/hyperpixel2r-kms-0.2.0"
  assert_absent "$root/var/lib/dkms/registered"
  assert_absent "$backlight_rule_path"
}

assert_workspace_remove_retried() {
  assert_file "$root/tmp/workspace-remove-attempts"
  test "$(cat "$root/tmp/workspace-remove-attempts")" = 2 ||
    fail 'private workspace removal was not retried exactly once'
  assert_no_private_workspaces
}

replace_equals_value() {
  local file="$1"
  local key="$2"
  local value="$3"
  local temporary="$fixture/replaced-value"

  awk -F= -v wanted="$key" -v replacement="$value" '
    $1 == wanted { print wanted "=" replacement; found=1; next }
    { print }
    END { exit !found }
  ' "$file" > "$temporary"
  mv -f -- "$temporary" "$file"
}

replace_manifest_value() {
  local file="$1"
  local key="$2"
  local value="$3"
  local temporary="$fixture/replaced-manifest-value"

  awk -F '\t' -v wanted="$key" -v replacement="$value" '
    $1 == wanted { print wanted "\t" replacement; found=1; next }
    { print }
    END { exit !found }
  ' "$file" > "$temporary"
  mv -f -- "$temporary" "$file"
}

downgrade_artifact_to_schema_one() {
  local artifact="$1"
  local manifest="$artifact/manifest.txt"
  local temporary="$fixture/schema-one-manifest"

  awk -F '\t' '
    $1 == "schema_version" { print "schema_version\t1"; next }
    $1 == "capability" || $1 == "lifecycle_capability" ||
      $1 == "backlight_rule_file" ||
      $1 == "backlight_rule_sha256" { next }
    { print }
  ' "$manifest" > "$temporary"
  mv -f -- "$temporary" "$manifest"
  chown root:root "$manifest"
  chmod 0644 "$manifest"
  rm -f -- "$artifact/$backlight_rule_file" \
    "$artifact/prior-backlight-rule" \
    "$artifact/prior-backlight-metadata" "$backlight_rule_path"
}

prepare_shared_module_inactive_retirement() {
  local config_candidate="$fixture/shared-retirement-config"

  new_target
  run_stage >/dev/null
  install_live_hardware
  run_controller commit-boot.sh >/dev/null

  inactive_retirement_artifact="$root/usr/lib/hyperpixel2r-kms/0.2.0/$source_revision/$release"
  inactive_retirement_overlay="$overlay_file"
  inactive_retirement_overlay_path="$root/boot/firmware/overlays/$inactive_retirement_overlay"
  active_retirement_revision='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  active_retirement_overlay='hyperpixel2r-kms-aaaaaaaaaaaa.dtbo'
  active_retirement_artifact="$root/usr/lib/hyperpixel2r-kms/0.2.0/$active_retirement_revision/$release"
  active_retirement_overlay_path="$root/boot/firmware/overlays/$active_retirement_overlay"
  active_retirement_module_path="$root/lib/modules/$release/extra/hyperpixel2r_kms.ko"

  mkdir -p "$(dirname "$active_retirement_artifact")"
  cp -a "$inactive_retirement_artifact" "$active_retirement_artifact"
  mv "$active_retirement_artifact/$inactive_retirement_overlay" \
    "$active_retirement_artifact/$active_retirement_overlay"
  replace_manifest_value "$active_retirement_artifact/manifest.txt" \
    source_revision "$active_retirement_revision"
  replace_manifest_value "$active_retirement_artifact/manifest.txt" \
    overlay_file "$active_retirement_overlay"
  chown root:root "$active_retirement_artifact/manifest.txt"
  chmod 0644 "$active_retirement_artifact/manifest.txt"

  cp -a "$inactive_retirement_overlay_path" "$active_retirement_overlay_path"
  awk -v old="dtoverlay=$inactive_retirement_overlay" \
    -v new="dtoverlay=$active_retirement_overlay" '
      {
        line=$0
        trim=line
        sub(/^[[:space:]]+/, "", trim)
        sub(/[[:space:]]+$/, "", trim)
        if (trim == old) { print new; replaced++; next }
        print line
      }
      END { exit replaced != 1 }
    ' "$root/boot/firmware/config.txt" > "$config_candidate"
  mv -f -- "$config_candidate" "$root/boot/firmware/config.txt"
  chown root:root "$root/boot/firmware/config.txt"
  chmod 0644 "$root/boot/firmware/config.txt"
  rm -- "$inactive_retirement_overlay_path"

  inactive_retirement_module_sha="$(sha256sum "$active_retirement_module_path" | awk '{ print $1 }')"
  active_retirement_overlay_sha="$(sha256sum "$active_retirement_overlay_path" | awk '{ print $1 }')"
  active_retirement_config_sha="$(sha256sum "$root/boot/firmware/config.txt" | awk '{ print $1 }')"
  active_retirement_artifact_before="$fixture/shared-retirement-active-artifact"
  inactive_retirement_artifact_before="$fixture/shared-retirement-inactive-artifact"
  rm -rf -- "$active_retirement_artifact_before" "$inactive_retirement_artifact_before"
  cp -a "$active_retirement_artifact" "$active_retirement_artifact_before"
  cp -a "$inactive_retirement_artifact" "$inactive_retirement_artifact_before"
}

assert_shared_module_active_target_unchanged() {
  assert_file "$active_retirement_module_path"
  assert_file "$active_retirement_overlay_path"
  test "$(sha256sum "$active_retirement_module_path" | awk '{ print $1 }')" = \
    "$inactive_retirement_module_sha" ||
    fail 'inactive retirement changed the shared active module'
  test "$(sha256sum "$active_retirement_overlay_path" | awk '{ print $1 }')" = \
    "$active_retirement_overlay_sha" ||
    fail 'inactive retirement changed the active overlay'
  test "$(sha256sum "$root/boot/firmware/config.txt" | awk '{ print $1 }')" = \
    "$active_retirement_config_sha" ||
    fail 'inactive retirement changed the active normal config'
  diff -ru "$active_retirement_artifact_before" "$active_retirement_artifact" >/dev/null ||
    fail 'inactive retirement changed the active retained artifact'
}

assert_shared_module_retirement_rejected() {
  local label="$1"

  if run_accepted_remote retire-inactive 0.2.0 "$source_revision" "$release" \
    >"$fixture/shared-retirement-$label.out" 2>&1; then
    fail "inactive retirement accepted unproven shared module ownership: $label"
  fi
  diff -ru "$inactive_retirement_artifact_before" "$inactive_retirement_artifact" >/dev/null ||
    fail "rejected inactive retirement changed its retained artifact: $label"
  assert_shared_module_active_target_unchanged
}

assert_rollback_rejects_state_mutation() {
  local key="$1"
  local value="$2"

  new_target
  run_stage >/dev/null
  replace_equals_value "$root/var/lib/hyperpixel2r-kms/tryboot-state" "$key" "$value"
  if run_controller rollback-boot.sh >/dev/null 2>&1; then
    fail "rollback accepted state identity drift: $key"
  fi
  assert_file "$root/boot/firmware/tryboot.txt"
  assert_file "$root/var/lib/hyperpixel2r-kms/tryboot-state"
}

assert_rollback_rejects_manifest_mutation() {
  local key="$1"
  local value="$2"
  local manifest

  new_target
  run_stage >/dev/null
  manifest="$root/usr/lib/hyperpixel2r-kms/0.2.0/$source_revision/$release/manifest.txt"
  replace_manifest_value "$manifest" "$key" "$value"
  if run_controller rollback-boot.sh >/dev/null 2>&1; then
    fail "rollback accepted manifest identity drift: $key"
  fi
  assert_file "$root/boot/firmware/tryboot.txt"
  assert_file "$root/var/lib/hyperpixel2r-kms/tryboot-state"
}

exercise_inactive_uninstall_backlight_matrix() {
  local artifact prior_sha drift_sha

  # A completed rollback leaves the exact proven predecessor live.  The
  # inactive artifact still owns the proof needed to preserve it and retire
  # the bundle.
  new_target
  printf 'fixture inactive prior backlight policy\n' > "$backlight_rule_path"
  chown root:root "$backlight_rule_path"
  chmod 0644 "$backlight_rule_path"
  prior_sha="$(sha256sum "$backlight_rule_path" | awk '{ print $1 }')"
  run_stage >/dev/null
  run_controller rollback-boot.sh >/dev/null
  run_controller uninstall.sh >/dev/null
  test "$(sha256sum "$backlight_rule_path" | awk '{ print $1 }')" = "$prior_sha" ||
    fail 'inactive uninstall did not preserve the exact proven prior rule'
  assert_absent "$root/usr/lib/hyperpixel2r-kms"

  # Candidate bytes are owned only through the exact artifact digest.  When a
  # predecessor existed, inactive cleanup restores its exact snapshot.
  new_target
  printf 'fixture candidate-replaced prior policy\n' > "$backlight_rule_path"
  chown root:root "$backlight_rule_path"
  chmod 0644 "$backlight_rule_path"
  prior_sha="$(sha256sum "$backlight_rule_path" | awk '{ print $1 }')"
  run_stage >/dev/null
  run_controller rollback-boot.sh >/dev/null
  artifact="$root/usr/lib/hyperpixel2r-kms/0.2.0/$source_revision/$release"
  cp "$artifact/$backlight_rule_file" "$backlight_rule_path"
  chown root:root "$backlight_rule_path"
  chmod 0644 "$backlight_rule_path"
  run_controller uninstall.sh >/dev/null
  test "$(sha256sum "$backlight_rule_path" | awk '{ print $1 }')" = "$prior_sha" ||
    fail 'inactive uninstall did not restore prior bytes over candidate bytes'
  assert_absent "$root/usr/lib/hyperpixel2r-kms"

  # Candidate bytes with a proven-absent predecessor are removed.
  new_target
  run_stage >/dev/null
  run_controller rollback-boot.sh >/dev/null
  artifact="$root/usr/lib/hyperpixel2r-kms/0.2.0/$source_revision/$release"
  cp "$artifact/$backlight_rule_file" "$backlight_rule_path"
  chown root:root "$backlight_rule_path"
  chmod 0644 "$backlight_rule_path"
  run_controller uninstall.sh >/dev/null
  assert_absent "$backlight_rule_path"
  assert_absent "$root/usr/lib/hyperpixel2r-kms"

  # An absent path with a proven-absent predecessor remains absent while the
  # inactive artifact is retired.
  new_target
  run_stage >/dev/null
  run_controller rollback-boot.sh >/dev/null
  assert_absent "$backlight_rule_path"
  run_controller uninstall.sh >/dev/null
  assert_absent "$backlight_rule_path"
  assert_absent "$root/usr/lib/hyperpixel2r-kms"

  # All other regular-file drift is foreign and must be preserved while the
  # inactive artifact remains available as recovery authority.
  new_target
  run_stage >/dev/null
  run_controller rollback-boot.sh >/dev/null
  artifact="$root/usr/lib/hyperpixel2r-kms/0.2.0/$source_revision/$release"
  printf 'foreign inactive backlight policy\n' > "$backlight_rule_path"
  chown root:root "$backlight_rule_path"
  chmod 0644 "$backlight_rule_path"
  drift_sha="$(sha256sum "$backlight_rule_path" | awk '{ print $1 }')"
  if run_controller uninstall.sh >/dev/null 2>&1; then
    fail 'inactive uninstall accepted foreign regular backlight rule drift'
  fi
  test "$(sha256sum "$backlight_rule_path" | awk '{ print $1 }')" = "$drift_sha" ||
    fail 'rejected inactive uninstall changed foreign backlight rule bytes'
  assert_file "$artifact/manifest.txt"

  # A symlink is never owned rule state, including when its target happens to
  # contain candidate bytes.
  new_target
  run_stage >/dev/null
  run_controller rollback-boot.sh >/dev/null
  artifact="$root/usr/lib/hyperpixel2r-kms/0.2.0/$source_revision/$release"
  ln -s "$artifact/$backlight_rule_file" "$backlight_rule_path"
  if run_controller uninstall.sh >/dev/null 2>&1; then
    fail 'inactive uninstall accepted a symlinked backlight rule'
  fi
  test -L "$backlight_rule_path" ||
    fail 'rejected inactive uninstall changed the symlinked backlight rule'
  assert_file "$artifact/manifest.txt"
}

exercise_prior_absent_accepted_uninstall_proof_guard() {
  local proof journal proof_sha

  new_target
  run_stage >/dev/null
  install_live_hardware
  run_controller commit-boot.sh >/dev/null
  run_accepted_remote record-accepted 0.2.0 "$source_revision" "$release" >/dev/null
  run_accepted_remote uninstall-accepted \
    0.2.0 "$source_revision" "$release" >/dev/null
  journal="$root/var/lib/hyperpixel2r-kms/accepted-uninstall"
  proof="$root/var/lib/hyperpixel2r-kms/accepted-prior-backlight-rule"
  grep -Fxq 'phase=receipt_removed' "$journal" ||
    fail 'prior-absent hostile fixture did not reach receipt-removed phase'
  grep -Fxq 'prior_backlight_rule_existed=false' "$journal" ||
    fail 'prior-absent hostile fixture journal has the wrong prior policy'
  assert_absent "$proof"

  printf 'foreign root-owned accepted prior proof\n' > "$proof"
  chown root:root "$proof"
  chmod 0600 "$proof"
  proof_sha="$(sha256sum "$proof" | awk '{ print $1 }')"
  if run_accepted_remote finalize-uninstall-accepted >/dev/null 2>&1; then
    fail 'prior-absent accepted finalizer deleted an unauthorized proof file'
  fi
  assert_file "$proof"
  test "$(sha256sum "$proof" | awk '{ print $1 }')" = "$proof_sha" ||
    fail 'rejected prior-absent finalizer changed unauthorized proof bytes'
  assert_file "$journal"
  grep -Fxq 'phase=receipt_removed' "$journal" ||
    fail 'rejected prior-absent finalizer changed its journal phase'
}

prepare_accepted_prior_tryboot_target() {
  new_target
  accepted_prior_tryboot="$root/boot/firmware/tryboot.txt"
  printf '%s\n' \
    '[all]' \
    '# accepted prior one-shot configuration' \
    'dtoverlay=hyperpixel2r-kms-eefaf3ae40fd' \
    > "$accepted_prior_tryboot"
  chown root:root "$accepted_prior_tryboot"
  chmod 0755 "$accepted_prior_tryboot"
  accepted_prior_tryboot_sha="$(sha256sum "$accepted_prior_tryboot" | awk '{ print $1 }')"
  run_stage >/dev/null
  install_live_hardware
  run_controller commit-boot.sh >/dev/null
  run_accepted_remote record-accepted 0.2.0 "$source_revision" "$release" >/dev/null
  accepted_artifact="$root/usr/lib/hyperpixel2r-kms/0.2.0/$source_revision/$release"
  cmp -s "$accepted_prior_tryboot" "$accepted_artifact/prior-tryboot.txt" ||
    fail 'fixture did not establish a real accepted prior tryboot backup'

  candidate_revision='cccccccccccccccccccccccccccccccccccccccc'
  candidate_overlay='hyperpixel2r-kms-cccccccccccc.dtbo'
  candidate_manifest_sha="$(printf d%.0s {1..64})"
  candidate_module_sha="$(printf e%.0s {1..64})"
  candidate_overlay_sha="$(printf f%.0s {1..64})"
  candidate_rule_sha="$(printf a%.0s {1..64})"
}

run_prior_tryboot_candidate_prepare() {
  run_accepted_remote prepare-new-accepted \
    0.2.0 "$candidate_revision" "$release" "$candidate_manifest_sha" \
    hyperpixel2r_kms.ko "$candidate_module_sha" \
    "$candidate_overlay" "$candidate_overlay_sha" \
    "$backlight_rule_file" "$candidate_rule_sha" \
    exact-backlight-metadata-v1
}

prepare_prior_tryboot_candidate_source() {
  candidate_source="$fixture/accepted-prior-candidate-source"
  candidate_artifact="$candidate_source/dist/artifacts/$release"
  rm -rf -- "$candidate_source"
  mkdir -p "$(dirname "$candidate_artifact")"
  cp -a "$repo_root/dist/artifacts/$release" "$candidate_artifact"
  mv "$candidate_artifact/$overlay_file" "$candidate_artifact/$candidate_overlay"
  printf 'accepted prior candidate overlay\n' >> "$candidate_artifact/$candidate_overlay"
  candidate_module_sha="$(sha256sum "$candidate_artifact/hyperpixel2r_kms.ko" | awk '{ print $1 }')"
  candidate_overlay_sha="$(sha256sum "$candidate_artifact/$candidate_overlay" | awk '{ print $1 }')"
  sed -i \
    -e "s/^source_revision\t.*/source_revision\t$candidate_revision/" \
    -e "s/^module_sha256\t.*/module_sha256\t$candidate_module_sha/" \
    -e "s/^overlay_file\t.*/overlay_file\t$candidate_overlay/" \
    -e "s/^overlay_sha256\t.*/overlay_sha256\t$candidate_overlay_sha/" \
    "$candidate_artifact/manifest.txt"
  printf '%s  %s\n' "$candidate_module_sha" hyperpixel2r_kms.ko \
    > "$candidate_artifact/module.sha256"
  printf '%s  %s\n' "$candidate_overlay_sha" "$candidate_overlay" \
    > "$candidate_artifact/overlay.sha256"
  candidate_manifest_sha="$(sha256sum "$candidate_artifact/manifest.txt" | awk '{ print $1 }')"
  candidate_rule_sha="$(awk -F '\t' '$1 == "backlight_rule_sha256" { print $2 }' \
    "$candidate_artifact/manifest.txt")"
}

run_prior_tryboot_candidate_stage() {
  HP2R_FIXTURE_ARTIFACT_DIR_OVERRIDE="$candidate_artifact" \
    HP2R_FIXTURE_SOURCE_ROOT_OVERRIDE="$candidate_source" \
    HP2R_FIXTURE_REPLACE_OVERLAY="$overlay_file" \
    run_stage
}

prepare_prior_tryboot_postcommit_target() {
  prepare_accepted_prior_tryboot_target
  prepare_prior_tryboot_candidate_source
  run_prior_tryboot_candidate_prepare >/dev/null
  run_prior_tryboot_candidate_stage >/dev/null
  run_controller commit-boot.sh >/dev/null
}

assert_prior_tryboot_mark_committed_rejected() {
  local label="$1"
  local transition="$root/var/lib/hyperpixel2r-kms/accepted-transition"
  local transition_sha normal_sha live_sha

  transition_sha="$(sha256sum "$transition" | awk '{ print $1 }')"
  normal_sha="$(sha256sum "$root/boot/firmware/config.txt" | awk '{ print $1 }')"
  live_sha="$(sha256sum "$accepted_prior_tryboot" | awk '{ print $1 }')"
  if run_accepted_remote mark-committed-accepted \
    >"$fixture/prior-mark-committed-$label.out" 2>&1; then
    fail "accepted mark-committed trusted normal config drift: $label"
  fi
  test "$(sha256sum "$transition" | awk '{ print $1 }')" = "$transition_sha" ||
    fail "rejected mark-committed changed transition authority: $label"
  test "$(sha256sum "$root/boot/firmware/config.txt" | awk '{ print $1 }')" = "$normal_sha" ||
    fail "rejected mark-committed changed normal config drift: $label"
  test "$(sha256sum "$accepted_prior_tryboot" | awk '{ print $1 }')" = "$live_sha" ||
    fail "rejected mark-committed changed accepted prior bytes: $label"
  assert_absent "$root/var/lib/hyperpixel2r-kms/tryboot-state"
}

assert_prior_tryboot_prepare_rejected() {
  local label="$1"
  local receipt="$root/var/lib/hyperpixel2r-kms/accepted-state"
  local receipt_sha normal_sha live_sha=''

  receipt_sha="$(sha256sum "$receipt" | awk '{ print $1 }')"
  normal_sha="$(sha256sum "$root/boot/firmware/config.txt" | awk '{ print $1 }')"
  if test -f "$root/boot/firmware/tryboot.txt" && \
    test ! -L "$root/boot/firmware/tryboot.txt"; then
    live_sha="$(sha256sum "$root/boot/firmware/tryboot.txt" | awk '{ print $1 }')"
  fi
  if run_prior_tryboot_candidate_prepare >"$fixture/prior-prepare-$label.out" 2>&1; then
    fail "accepted prior tryboot preparation accepted unsafe authority: $label"
  fi
  test "$(sha256sum "$receipt" | awk '{ print $1 }')" = "$receipt_sha" ||
    fail "rejected prior tryboot preparation changed the accepted receipt: $label"
  test "$(sha256sum "$root/boot/firmware/config.txt" | awk '{ print $1 }')" = "$normal_sha" ||
    fail "rejected prior tryboot preparation changed the normal config: $label"
  if test -n "$live_sha"; then
    test "$(sha256sum "$root/boot/firmware/tryboot.txt" | awk '{ print $1 }')" = "$live_sha" ||
      fail "rejected prior tryboot preparation changed live bytes: $label"
  fi
  assert_absent "$root/var/lib/hyperpixel2r-kms/accepted-transition"
  assert_absent "$root/var/lib/hyperpixel2r-kms/tryboot-state"
  assert_absent "$root/usr/lib/hyperpixel2r-kms/0.2.0/$candidate_revision/$release"
}

assert_prior_tryboot_transition_rejected() {
  local label="$1"
  local transition="$root/var/lib/hyperpixel2r-kms/accepted-transition"
  local receipt="$root/var/lib/hyperpixel2r-kms/accepted-state"
  local transition_sha receipt_sha normal_sha live_sha

  transition_sha="$(sha256sum "$transition" | awk '{ print $1 }')"
  receipt_sha="$(sha256sum "$receipt" | awk '{ print $1 }')"
  normal_sha="$(sha256sum "$root/boot/firmware/config.txt" | awk '{ print $1 }')"
  live_sha="$(sha256sum "$accepted_prior_tryboot" | awk '{ print $1 }')"
  if run_accepted_remote recover-accepted >"$fixture/prior-transition-$label.out" 2>&1; then
    fail "accepted recovery trusted unsafe prior tryboot transition authority: $label"
  fi
  test "$(sha256sum "$transition" | awk '{ print $1 }')" = "$transition_sha" ||
    fail "rejected transition validation changed the journal: $label"
  test "$(sha256sum "$receipt" | awk '{ print $1 }')" = "$receipt_sha" ||
    fail "rejected transition validation changed the receipt: $label"
  test "$(sha256sum "$root/boot/firmware/config.txt" | awk '{ print $1 }')" = "$normal_sha" ||
    fail "rejected transition validation changed normal config: $label"
  test "$(sha256sum "$accepted_prior_tryboot" | awk '{ print $1 }')" = "$live_sha" ||
    fail "rejected transition validation changed live prior bytes: $label"
  assert_absent "$root/var/lib/hyperpixel2r-kms/tryboot-state"
  assert_absent "$root/usr/lib/hyperpixel2r-kms/0.2.0/$candidate_revision/$release"
}

assert_orphan_transition_proof_blocks_accepted_uninstall() {
  local label="$1"
  local receipt="$root/var/lib/hyperpixel2r-kms/accepted-state"
  local module="$root/lib/modules/$release/extra/hyperpixel2r_kms.ko"
  local overlay="$root/boot/firmware/overlays/$overlay_file"
  local receipt_sha normal_sha tryboot_sha module_sha overlay_sha rule_sha manifest_sha

  receipt_sha="$(sha256sum "$receipt" | awk '{ print $1 }')"
  normal_sha="$(sha256sum "$root/boot/firmware/config.txt" | awk '{ print $1 }')"
  tryboot_sha="$(sha256sum "$accepted_prior_tryboot" | awk '{ print $1 }')"
  module_sha="$(sha256sum "$module" | awk '{ print $1 }')"
  overlay_sha="$(sha256sum "$overlay" | awk '{ print $1 }')"
  rule_sha="$(sha256sum "$backlight_rule_path" | awk '{ print $1 }')"
  manifest_sha="$(sha256sum "$accepted_artifact/manifest.txt" | awk '{ print $1 }')"

  if run_accepted_remote uninstall-accepted \
    0.2.0 "$source_revision" "$release" \
    >"$fixture/orphan-transition-uninstall-$label.out" 2>&1; then
    fail "accepted uninstall ignored orphan transition authority: $label"
  fi
  test "$(sha256sum "$receipt" | awk '{ print $1 }')" = "$receipt_sha" ||
    fail "rejected accepted uninstall changed its receipt: $label"
  test "$(sha256sum "$root/boot/firmware/config.txt" | awk '{ print $1 }')" = \
    "$normal_sha" || fail "rejected accepted uninstall changed normal config: $label"
  test "$(sha256sum "$accepted_prior_tryboot" | awk '{ print $1 }')" = \
    "$tryboot_sha" || fail "rejected accepted uninstall changed tryboot config: $label"
  test "$(sha256sum "$module" | awk '{ print $1 }')" = "$module_sha" ||
    fail "rejected accepted uninstall changed installed module: $label"
  test "$(sha256sum "$overlay" | awk '{ print $1 }')" = "$overlay_sha" ||
    fail "rejected accepted uninstall changed installed overlay: $label"
  test "$(sha256sum "$backlight_rule_path" | awk '{ print $1 }')" = "$rule_sha" ||
    fail "rejected accepted uninstall changed installed backlight rule: $label"
  test "$(sha256sum "$accepted_artifact/manifest.txt" | awk '{ print $1 }')" = \
    "$manifest_sha" || fail "rejected accepted uninstall changed accepted artifact: $label"
  assert_absent "$root/var/lib/hyperpixel2r-kms/accepted-uninstall"
  assert_absent "$root/var/lib/hyperpixel2r-kms/accepted-uninstall-stock.txt"
  assert_absent "${accepted_artifact}.accepted-uninstall"
}

exercise_accepted_prior_committed_recovery() {
  prepare_prior_tryboot_postcommit_target
  if HP2R_FIXTURE_INTERRUPT_AFTER=accepted-committed-published \
    run_accepted_remote mark-committed-accepted >/dev/null 2>&1; then
    fail 'accepted prior lifecycle ignored committed publication interruption'
  fi
  run_accepted_remote recover-accepted >/dev/null
  test "$(sha256sum "$accepted_prior_tryboot" | awk '{ print $1 }')" = \
    "$accepted_prior_tryboot_sha" ||
    fail 'committed recovery changed exact accepted prior bytes'
  cmp -s "$accepted_prior_tryboot" "$accepted_artifact/prior-tryboot.txt" ||
    fail 'committed recovery diverged from retained accepted prior proof'
  assert_absent "$root/var/lib/hyperpixel2r-kms/tryboot-state"
  assert_absent "$root/var/lib/hyperpixel2r-kms/accepted-transition"
  assert_absent "$root/var/lib/hyperpixel2r-kms/accepted-transition-prior-config.txt"
  assert_absent "$root/var/lib/hyperpixel2r-kms/accepted-transition-prior-tryboot.txt"
  assert_absent "$root/usr/lib/hyperpixel2r-kms/0.2.0/$candidate_revision/$release"
}

exercise_accepted_prior_tryboot_authority() {
  local transition transition_prior transition_prior_config orphan_sha artifact_prior mutation_target
  local artifact_before dkms_before prior_config_sha prior_tryboot_sha

  prepare_accepted_prior_tryboot_target
  prepare_prior_tryboot_candidate_source
  run_prior_tryboot_candidate_prepare >/dev/null
  transition="$root/var/lib/hyperpixel2r-kms/accepted-transition"
  transition_prior="$root/var/lib/hyperpixel2r-kms/accepted-transition-prior-tryboot.txt"
  grep -Fxq 'schema_version=5' "$transition"
  grep -Fxq 'prior_tryboot_existed=true' "$transition"
  grep -Fxq "prior_tryboot_sha256=$accepted_prior_tryboot_sha" "$transition"
  test "$(stat -c '%U:%G:%a' "$transition_prior")" = root:root:600
  cmp -s "$transition_prior" "$accepted_prior_tryboot"
  run_prior_tryboot_candidate_stage >/dev/null
  grep -Fxq 'phase=staged' "$transition" ||
    fail 'accepted prior tryboot stage did not publish its staged phase'
  grep -Fxq 'tryboot_existed=true' \
    "$root/var/lib/hyperpixel2r-kms/tryboot-state" ||
    fail 'generic stage did not bind prior tryboot existence'
  grep -Fxq "prior_tryboot_sha256=$accepted_prior_tryboot_sha" \
    "$root/var/lib/hyperpixel2r-kms/tryboot-state" ||
    fail 'generic stage did not bind prior tryboot digest'
  cmp -s "$transition_prior" \
    "$root/usr/lib/hyperpixel2r-kms/0.2.0/$candidate_revision/$release/prior-tryboot.txt" ||
    fail 'generic stage artifact backup differs from accepted transition proof'
  run_controller commit-boot.sh >/dev/null
  assert_absent "$root/var/lib/hyperpixel2r-kms/tryboot-state"
  test "$(sha256sum "$accepted_prior_tryboot" | awk '{ print $1 }')" = \
    "$accepted_prior_tryboot_sha" ||
    fail 'generic commit did not restore exact accepted prior tryboot bytes'
  run_accepted_remote mark-committed-accepted >/dev/null
  run_accepted_remote mark-verified-accepted >/dev/null
  run_accepted_remote finalize-accepted >/dev/null
  grep -Fxq 'schema_version=3' \
    "$root/var/lib/hyperpixel2r-kms/accepted-state" ||
    fail 'new acceptance changed the accepted receipt schema'
  grep -Fxq "source_revision=$candidate_revision" \
    "$root/var/lib/hyperpixel2r-kms/accepted-state" ||
    fail 'new acceptance did not publish the candidate receipt'
  test "$(sha256sum "$accepted_prior_tryboot" | awk '{ print $1 }')" = \
    "$accepted_prior_tryboot_sha" ||
    fail 'accepted finalization changed exact prior tryboot bytes'
  cmp -s "$accepted_prior_tryboot" \
    "$root/usr/lib/hyperpixel2r-kms/0.2.0/$candidate_revision/$release/prior-tryboot.txt" ||
    fail 'final accepted artifact lost exact prior tryboot authority'
  assert_absent "$root/var/lib/hyperpixel2r-kms/accepted-transition"
  assert_absent "$root/var/lib/hyperpixel2r-kms/accepted-transition-prior-config.txt"
  assert_absent "$root/var/lib/hyperpixel2r-kms/accepted-transition-prior-tryboot.txt"

  prepare_accepted_prior_tryboot_target
  prepare_prior_tryboot_candidate_source
  if HP2R_FIXTURE_INTERRUPT_AFTER=accepted-transition-published \
    run_prior_tryboot_candidate_prepare >/dev/null 2>&1; then
    fail 'accepted prior preparation ignored transition publication interruption'
  fi
  run_accepted_remote recover-accepted >/dev/null
  test "$(sha256sum "$accepted_prior_tryboot" | awk '{ print $1 }')" = \
    "$accepted_prior_tryboot_sha" ||
    fail 'transition publication recovery changed accepted prior bytes'
  assert_absent "$root/var/lib/hyperpixel2r-kms/accepted-transition"
  assert_absent "$root/var/lib/hyperpixel2r-kms/accepted-transition-prior-config.txt"
  assert_absent "$root/var/lib/hyperpixel2r-kms/accepted-transition-prior-tryboot.txt"

  for boundary in \
    candidate-artifact-published candidate-module-installed \
    candidate-overlay-installed candidate-dkms-activated \
    candidate-tryboot-published candidate-tryboot-state-published \
    candidate-staged-published
  do
    prepare_accepted_prior_tryboot_target
    prepare_prior_tryboot_candidate_source
    run_prior_tryboot_candidate_prepare >/dev/null
    if HP2R_FIXTURE_INTERRUPT_AFTER="$boundary" \
      HP2R_FIXTURE_PRESERVE_MUTATIONS=1 \
      run_prior_tryboot_candidate_stage >/dev/null 2>&1; then
      fail "accepted prior stage ignored interruption at $boundary"
    fi
    if ! run_accepted_remote recover-accepted \
      >"$fixture/prior-recover-$boundary.out" 2>&1; then
      sed -n '1,20p' "$fixture/prior-recover-$boundary.out" >&2
      fail "accepted prior recovery failed after $boundary"
    fi
    assert_file "$accepted_prior_tryboot"
    test "$(sha256sum "$accepted_prior_tryboot" | awk '{ print $1 }')" = \
      "$accepted_prior_tryboot_sha" ||
      fail "accepted recovery changed prior tryboot bytes after $boundary"
    cmp -s "$accepted_prior_tryboot" "$accepted_artifact/prior-tryboot.txt" ||
      fail "accepted recovery diverged from retained prior proof after $boundary"
    assert_absent "$root/var/lib/hyperpixel2r-kms/tryboot-state"
    assert_absent "$root/var/lib/hyperpixel2r-kms/rollback-state"
    assert_absent "$root/var/lib/hyperpixel2r-kms/accepted-transition"
    assert_absent "$root/var/lib/hyperpixel2r-kms/accepted-transition-prior-config.txt"
    assert_absent "$root/var/lib/hyperpixel2r-kms/accepted-transition-prior-tryboot.txt"
    assert_absent "$root/usr/lib/hyperpixel2r-kms/0.2.0/$candidate_revision/$release"
    find "$root/var/lib/hyperpixel2r-kms" -mindepth 1 -maxdepth 1 \
      -type d -name '.hp2r-transaction.*' -exec rm -rf -- {} +
    assert_no_private_workspaces
  done

  for boundary in accepted-committed-published accepted-verified-published
  do
    prepare_prior_tryboot_postcommit_target
    if test "$boundary" = accepted-committed-published; then
      if HP2R_FIXTURE_INTERRUPT_AFTER="$boundary" \
        run_accepted_remote mark-committed-accepted >/dev/null 2>&1; then
        fail "accepted prior lifecycle ignored interruption at $boundary"
      fi
    else
      run_accepted_remote mark-committed-accepted >/dev/null
      if HP2R_FIXTURE_INTERRUPT_AFTER="$boundary" \
        run_accepted_remote mark-verified-accepted >/dev/null 2>&1; then
        fail "accepted prior lifecycle ignored interruption at $boundary"
      fi
    fi
    if ! run_accepted_remote recover-accepted \
      >"$fixture/prior-phase-recover-$boundary.out" 2>&1; then
      sed -n '1,20p' "$fixture/prior-phase-recover-$boundary.out" >&2
      fail "accepted phase recovery failed after $boundary"
    fi
    test "$(sha256sum "$accepted_prior_tryboot" | awk '{ print $1 }')" = \
      "$accepted_prior_tryboot_sha" ||
      fail "accepted phase recovery changed prior bytes after $boundary"
    assert_absent "$root/var/lib/hyperpixel2r-kms/accepted-transition"
    assert_absent "$root/var/lib/hyperpixel2r-kms/accepted-transition-prior-tryboot.txt"
  done

  for boundary in \
    accepted-finalizing-published accepted-receipt-published \
    accepted-receipt-phase-published accepted-prior-retired \
    accepted-journal-cleared
  do
    prepare_prior_tryboot_postcommit_target
    run_accepted_remote mark-committed-accepted >/dev/null
    run_accepted_remote mark-verified-accepted >/dev/null
    if HP2R_FIXTURE_INTERRUPT_AFTER="$boundary" \
      run_accepted_remote finalize-accepted >/dev/null 2>&1; then
      fail "accepted prior finalizer ignored interruption at $boundary"
    fi
    test "$(sha256sum "$accepted_prior_tryboot" | awk '{ print $1 }')" = \
      "$accepted_prior_tryboot_sha" ||
      fail "accepted finalizer changed prior bytes at $boundary"
    run_accepted_remote finalize-accepted >/dev/null
    run_accepted_remote finalize-accepted >/dev/null
    test "$(sha256sum "$accepted_prior_tryboot" | awk '{ print $1 }')" = \
      "$accepted_prior_tryboot_sha" ||
      fail "accepted finalizer retry changed prior bytes after $boundary"
    assert_absent "$root/var/lib/hyperpixel2r-kms/accepted-transition"
    assert_absent "$root/var/lib/hyperpixel2r-kms/accepted-transition-prior-config.txt"
    assert_absent "$root/var/lib/hyperpixel2r-kms/accepted-transition-prior-tryboot.txt"
  done

  prepare_prior_tryboot_postcommit_target
  run_accepted_remote mark-committed-accepted >/dev/null
  run_accepted_remote mark-verified-accepted >/dev/null
  if HP2R_FIXTURE_INTERRUPT_AFTER=accepted-journal-cleared \
    run_accepted_remote finalize-accepted >/dev/null 2>&1; then
    fail 'accepted prior finalization ignored journal-cleared interruption'
  fi
  assert_absent "$root/var/lib/hyperpixel2r-kms/accepted-transition"
  assert_file "$root/var/lib/hyperpixel2r-kms/accepted-transition-prior-config.txt"
  assert_file "$root/var/lib/hyperpixel2r-kms/accepted-transition-prior-tryboot.txt"
  run_accepted_remote finalize-accepted >/dev/null
  run_accepted_remote finalize-accepted >/dev/null
  assert_absent "$root/var/lib/hyperpixel2r-kms/accepted-transition-prior-config.txt"
  assert_absent "$root/var/lib/hyperpixel2r-kms/accepted-transition-prior-tryboot.txt"
  test "$(sha256sum "$accepted_prior_tryboot" | awk '{ print $1 }')" = \
    "$accepted_prior_tryboot_sha" ||
    fail 'journal-cleared finalization retry changed accepted prior bytes'

  # Recovery from a prepared journal must preserve the accepted prior rather
  # than applying the historical accepted-new assumption of absence.
  prepare_accepted_prior_tryboot_target
  prepare_prior_tryboot_candidate_source
  run_prior_tryboot_candidate_prepare >/dev/null
  run_accepted_remote recover-accepted >/dev/null
  assert_file "$accepted_prior_tryboot"
  test "$(sha256sum "$accepted_prior_tryboot" | awk '{ print $1 }')" = \
    "$accepted_prior_tryboot_sha" ||
    fail 'prepared recovery did not preserve exact accepted prior tryboot bytes'
  assert_absent "$root/var/lib/hyperpixel2r-kms/accepted-transition"
  assert_absent "$root/var/lib/hyperpixel2r-kms/accepted-transition-prior-config.txt"
  assert_absent "$root/var/lib/hyperpixel2r-kms/accepted-transition-prior-tryboot.txt"

  # Crash-style staged recovery follows generic rollback, then must revalidate
  # the restored prior before clearing accepted-transition authority.
  prepare_accepted_prior_tryboot_target
  prepare_prior_tryboot_candidate_source
  run_prior_tryboot_candidate_prepare >/dev/null
  run_prior_tryboot_candidate_stage >/dev/null
  run_accepted_remote recover-accepted >/dev/null
  assert_file "$accepted_prior_tryboot"
  test "$(sha256sum "$accepted_prior_tryboot" | awk '{ print $1 }')" = \
    "$accepted_prior_tryboot_sha" ||
    fail 'staged recovery did not preserve exact accepted prior tryboot bytes'
  assert_absent "$root/var/lib/hyperpixel2r-kms/tryboot-state"
  assert_absent "$root/var/lib/hyperpixel2r-kms/accepted-transition"
  assert_absent "$root/var/lib/hyperpixel2r-kms/accepted-transition-prior-config.txt"
  assert_absent "$root/var/lib/hyperpixel2r-kms/accepted-transition-prior-tryboot.txt"

  prepare_prior_tryboot_postcommit_target
  cp "$root/var/lib/hyperpixel2r-kms/accepted-transition-prior-config.txt" \
    "$root/boot/firmware/config.txt"
  chown root:root "$root/boot/firmware/config.txt"
  chmod 0644 "$root/boot/firmware/config.txt"
  assert_prior_tryboot_mark_committed_rejected prior-normal

  prepare_prior_tryboot_postcommit_target
  printf '# foreign post-commit drift\n' >> "$root/boot/firmware/config.txt"
  assert_prior_tryboot_mark_committed_rejected foreign-bytes

  prepare_prior_tryboot_postcommit_target
  sed -i 's/# hyperpixel2r-kms accepted candidate/# accepted candidate comment drift/' \
    "$root/boot/firmware/config.txt"
  assert_prior_tryboot_mark_committed_rejected comment-drift

  # Normal stage compensation must restore a preexisting accepted prior after
  # any post-publication failure, using a boot-file mode the validator accepts.
  prepare_accepted_prior_tryboot_target
  prepare_prior_tryboot_candidate_source
  run_prior_tryboot_candidate_prepare >/dev/null
  if HP2R_FIXTURE_INTERRUPT_AFTER=candidate-tryboot-published \
    run_prior_tryboot_candidate_stage >/dev/null 2>&1; then
    fail 'accepted prior stage ignored its tryboot publication interruption'
  fi
  assert_file "$accepted_prior_tryboot"
  test "$(sha256sum "$accepted_prior_tryboot" | awk '{ print $1 }')" = \
    "$accepted_prior_tryboot_sha" ||
    fail 'stage compensation did not restore exact accepted prior tryboot bytes'
  cmp -s "$accepted_prior_tryboot" "$accepted_artifact/prior-tryboot.txt" ||
    fail 'stage compensation restored different bytes than accepted authority'
  assert_absent "$root/var/lib/hyperpixel2r-kms/tryboot-state"

  prepare_accepted_prior_tryboot_target
  prepare_prior_tryboot_candidate_source
  run_prior_tryboot_candidate_prepare >/dev/null
  printf 'drift after accepted preparation\n' >> "$accepted_prior_tryboot"
  if run_prior_tryboot_candidate_stage >/dev/null 2>&1; then
    fail 'accepted candidate stage trusted live drift after preparation'
  fi
  assert_absent "$root/var/lib/hyperpixel2r-kms/tryboot-state"
  assert_absent "$root/usr/lib/hyperpixel2r-kms/0.2.0/$candidate_revision/$release"

  prepare_accepted_prior_tryboot_target
  prepare_prior_tryboot_candidate_source
  run_prior_tryboot_candidate_prepare >/dev/null
  mutation_target="$fixture/prior-stage-symlink-target"
  cp "$accepted_prior_tryboot" "$mutation_target"
  rm -- "$accepted_prior_tryboot"
  ln -s "$mutation_target" "$accepted_prior_tryboot"
  if run_prior_tryboot_candidate_stage >/dev/null 2>&1; then
    fail 'accepted candidate stage trusted a live symlink replacement'
  fi
  assert_absent "$root/var/lib/hyperpixel2r-kms/tryboot-state"
  assert_absent "$root/usr/lib/hyperpixel2r-kms/0.2.0/$candidate_revision/$release"

  prepare_accepted_prior_tryboot_target
  prepare_prior_tryboot_candidate_source
  run_prior_tryboot_candidate_prepare >/dev/null
  cp "$root/var/lib/hyperpixel2r-kms/accepted-stock-config.txt" "$accepted_prior_tryboot"
  printf '\n# hyperpixel2r-kms one-shot candidate\ndtoverlay=%s\n' "$candidate_overlay" \
    >> "$accepted_prior_tryboot"
  chown root:root "$accepted_prior_tryboot"
  chmod 0644 "$accepted_prior_tryboot"
  test "$(sha256sum "$accepted_prior_tryboot" | awk '{ print $1 }')" = \
    "$(awk -F= '$1 == "tryboot_config_sha256" { print $2 }' \
      "$root/var/lib/hyperpixel2r-kms/accepted-transition")" ||
    fail 'candidate-byte hostile fixture did not reproduce the exact candidate'
  if run_prior_tryboot_candidate_stage >/dev/null 2>&1; then
    fail 'accepted candidate stage confused exact candidate bytes with prior authority'
  fi
  assert_absent "$root/var/lib/hyperpixel2r-kms/tryboot-state"
  assert_absent "$root/usr/lib/hyperpixel2r-kms/0.2.0/$candidate_revision/$release"

  # The optional companion is durable authority even when interruption occurs
  # before the journal is published.  Recovery may clear it only after proving
  # it against both the accepted artifact and the unchanged live file.
  prepare_accepted_prior_tryboot_target
  transition_prior_config="$root/var/lib/hyperpixel2r-kms/accepted-transition-prior-config.txt"
  transition_prior="$root/var/lib/hyperpixel2r-kms/accepted-transition-prior-tryboot.txt"
  if HP2R_FIXTURE_INTERRUPT_AFTER=accepted-transition-prior-tryboot-published \
    run_prior_tryboot_candidate_prepare >/dev/null 2>&1; then
    fail 'accepted prior tryboot publication ignored its interruption boundary'
  fi
  assert_absent "$root/var/lib/hyperpixel2r-kms/accepted-transition"
  assert_file "$transition_prior_config"
  assert_file "$transition_prior"
  prior_config_sha="$(sha256sum "$transition_prior_config" | awk '{ print $1 }')"
  prior_tryboot_sha="$(sha256sum "$transition_prior" | awk '{ print $1 }')"
  artifact_before="$fixture/orphan-transition-artifact-before"
  dkms_before="$fixture/orphan-transition-dkms-before"
  rm -rf -- "$artifact_before" "$dkms_before"
  cp -a "$accepted_artifact" "$artifact_before"
  cp -a "$root/usr/src/hyperpixel2r-kms-0.2.0" "$dkms_before"
  assert_orphan_transition_proof_blocks_accepted_uninstall interrupted-prepare
  test "$(sha256sum "$transition_prior_config" | awk '{ print $1 }')" = \
    "$prior_config_sha" ||
    fail 'rejected accepted uninstall changed orphan prior-config proof'
  test "$(sha256sum "$transition_prior" | awk '{ print $1 }')" = \
    "$prior_tryboot_sha" ||
    fail 'rejected accepted uninstall changed orphan prior-tryboot proof'
  diff -ru "$artifact_before" "$accepted_artifact" >/dev/null ||
    fail 'rejected accepted uninstall changed the accepted artifact tree'
  diff -ru "$dkms_before" "$root/usr/src/hyperpixel2r-kms-0.2.0" >/dev/null ||
    fail 'rejected accepted uninstall changed the installed DKMS source'
  run_accepted_remote recover-accepted >/dev/null
  assert_absent "$transition_prior_config"
  assert_absent "$transition_prior"
  test "$(sha256sum "$accepted_prior_tryboot" | awk '{ print $1 }')" = \
    "$accepted_prior_tryboot_sha" ||
    fail 'orphan companion recovery changed the accepted prior tryboot bytes'

  # Each companion independently blocks uninstall.  Exact regular orphan
  # authority is recoverable; hostile types remain intact and fail closed.
  cp "$root/boot/firmware/config.txt" "$transition_prior_config"
  chown root:root "$transition_prior_config"
  chmod 0600 "$transition_prior_config"
  prior_config_sha="$(sha256sum "$transition_prior_config" | awk '{ print $1 }')"
  assert_orphan_transition_proof_blocks_accepted_uninstall lone-prior-config
  test "$(sha256sum "$transition_prior_config" | awk '{ print $1 }')" = \
    "$prior_config_sha" ||
    fail 'rejected accepted uninstall changed lone prior-config proof'
  run_accepted_remote recover-accepted >/dev/null
  assert_absent "$transition_prior_config"

  cp "$accepted_prior_tryboot" "$transition_prior"
  chown root:root "$transition_prior"
  chmod 0600 "$transition_prior"
  prior_tryboot_sha="$(sha256sum "$transition_prior" | awk '{ print $1 }')"
  assert_orphan_transition_proof_blocks_accepted_uninstall lone-prior-tryboot
  test "$(sha256sum "$transition_prior" | awk '{ print $1 }')" = \
    "$prior_tryboot_sha" ||
    fail 'rejected accepted uninstall changed lone prior-tryboot proof'
  run_accepted_remote recover-accepted >/dev/null
  assert_absent "$transition_prior"

  ln -s "$root/boot/firmware/config.txt" "$transition_prior_config"
  assert_orphan_transition_proof_blocks_accepted_uninstall prior-config-symlink
  test -L "$transition_prior_config" ||
    fail 'rejected accepted uninstall changed prior-config symlink authority'
  if run_accepted_remote recover-accepted >/dev/null 2>&1; then
    fail 'accepted recovery trusted a symlinked lone prior-config proof'
  fi
  test -L "$transition_prior_config" ||
    fail 'rejected accepted recovery changed prior-config symlink authority'

  prepare_accepted_prior_tryboot_target
  transition_prior_config="$root/var/lib/hyperpixel2r-kms/accepted-transition-prior-config.txt"
  mkdir "$transition_prior_config"
  assert_orphan_transition_proof_blocks_accepted_uninstall prior-config-directory
  test -d "$transition_prior_config" ||
    fail 'rejected accepted uninstall changed prior-config directory authority'
  if run_accepted_remote recover-accepted >/dev/null 2>&1; then
    fail 'accepted recovery trusted a directory lone prior-config proof'
  fi
  test -d "$transition_prior_config" ||
    fail 'rejected accepted recovery changed prior-config directory authority'

  prepare_accepted_prior_tryboot_target
  transition_prior="$root/var/lib/hyperpixel2r-kms/accepted-transition-prior-tryboot.txt"
  ln -s "$accepted_prior_tryboot" "$transition_prior"
  assert_orphan_transition_proof_blocks_accepted_uninstall prior-tryboot-symlink
  test -L "$transition_prior" ||
    fail 'rejected accepted uninstall changed prior-tryboot symlink authority'
  if run_accepted_remote recover-accepted >/dev/null 2>&1; then
    fail 'accepted recovery trusted a symlinked lone prior-tryboot proof'
  fi
  test -L "$transition_prior" ||
    fail 'rejected accepted recovery changed prior-tryboot symlink authority'

  # An orphan with unrelated bytes is not proof and must be rejected intact.
  prepare_accepted_prior_tryboot_target
  transition_prior="$root/var/lib/hyperpixel2r-kms/accepted-transition-prior-tryboot.txt"
  printf 'unrelated orphan prior tryboot proof\n' > "$transition_prior"
  chown root:root "$transition_prior"
  chmod 0600 "$transition_prior"
  orphan_sha="$(sha256sum "$transition_prior" | awk '{ print $1 }')"
  if run_accepted_remote recover-accepted >/dev/null 2>&1; then
    fail 'accepted recovery trusted an unrelated orphan prior tryboot companion'
  fi
  assert_file "$transition_prior"
  test "$(sha256sum "$transition_prior" | awk '{ print $1 }')" = "$orphan_sha" ||
    fail 'rejected orphan prior tryboot recovery changed unrelated bytes'

  prepare_accepted_prior_tryboot_target
  transition_prior="$root/var/lib/hyperpixel2r-kms/accepted-transition-prior-tryboot.txt"
  mutation_target="$fixture/orphan-prior-symlink-target"
  cp "$accepted_prior_tryboot" "$mutation_target"
  ln -s "$mutation_target" "$transition_prior"
  if run_accepted_remote recover-accepted >/dev/null 2>&1; then
    fail 'accepted recovery trusted a symlinked orphan prior tryboot companion'
  fi
  test -L "$transition_prior" ||
    fail 'rejected orphan recovery changed its symlinked proof'

  # Preparation trusts only the exact prior already retained by accepted-state.
  prepare_accepted_prior_tryboot_target
  printf 'live prior drift\n' >> "$accepted_prior_tryboot"
  assert_prior_tryboot_prepare_rejected live-byte-drift

  prepare_accepted_prior_tryboot_target
  mutation_target="$fixture/prior-live-symlink-target"
  cp "$accepted_prior_tryboot" "$mutation_target"
  rm -- "$accepted_prior_tryboot"
  ln -s "$mutation_target" "$accepted_prior_tryboot"
  assert_prior_tryboot_prepare_rejected live-symlink

  prepare_accepted_prior_tryboot_target
  chmod 0666 "$accepted_prior_tryboot"
  assert_prior_tryboot_prepare_rejected live-mode

  prepare_accepted_prior_tryboot_target
  chown 65534:65534 "$accepted_prior_tryboot"
  assert_prior_tryboot_prepare_rejected live-owner

  prepare_accepted_prior_tryboot_target
  rm -- "$accepted_prior_tryboot"
  mkdir "$accepted_prior_tryboot"
  assert_prior_tryboot_prepare_rejected live-directory

  prepare_accepted_prior_tryboot_target
  rm -- "$accepted_prior_tryboot"
  mkfifo "$accepted_prior_tryboot"
  assert_prior_tryboot_prepare_rejected live-fifo

  prepare_accepted_prior_tryboot_target
  artifact_prior="$accepted_artifact/prior-tryboot.txt"
  rm -- "$artifact_prior"
  assert_prior_tryboot_prepare_rejected artifact-prior-missing

  prepare_accepted_prior_tryboot_target
  artifact_prior="$accepted_artifact/prior-tryboot.txt"
  printf 'retained proof drift\n' >> "$artifact_prior"
  assert_prior_tryboot_prepare_rejected artifact-prior-byte-drift

  prepare_accepted_prior_tryboot_target
  artifact_prior="$accepted_artifact/prior-tryboot.txt"
  chmod 0644 "$artifact_prior"
  assert_prior_tryboot_prepare_rejected artifact-prior-mode

  prepare_accepted_prior_tryboot_target
  artifact_prior="$accepted_artifact/prior-tryboot.txt"
  chown 65534:65534 "$artifact_prior"
  assert_prior_tryboot_prepare_rejected artifact-prior-owner

  prepare_accepted_prior_tryboot_target
  artifact_prior="$accepted_artifact/prior-tryboot.txt"
  mutation_target="$fixture/artifact-prior-symlink-target"
  cp "$artifact_prior" "$mutation_target"
  rm -- "$artifact_prior"
  ln -s "$mutation_target" "$artifact_prior"
  assert_prior_tryboot_prepare_rejected artifact-prior-symlink

  prepare_accepted_prior_tryboot_target
  artifact_prior="$accepted_artifact/prior-tryboot.txt"
  rm -- "$artifact_prior"
  mkdir "$artifact_prior"
  assert_prior_tryboot_prepare_rejected artifact-prior-directory

  # A receipt whose retained artifact proves absence cannot adopt an unrelated
  # ambient one-shot file merely because that file is otherwise safe.
  new_target
  run_stage >/dev/null
  install_live_hardware
  run_controller commit-boot.sh >/dev/null
  run_accepted_remote record-accepted 0.2.0 "$source_revision" "$release" >/dev/null
  candidate_revision='cccccccccccccccccccccccccccccccccccccccc'
  candidate_overlay='hyperpixel2r-kms-cccccccccccc.dtbo'
  candidate_manifest_sha="$(printf d%.0s {1..64})"
  candidate_module_sha="$(printf e%.0s {1..64})"
  candidate_overlay_sha="$(printf f%.0s {1..64})"
  candidate_rule_sha="$(printf a%.0s {1..64})"
  printf 'unrelated ambient one-shot config\n' > "$root/boot/firmware/tryboot.txt"
  chown root:root "$root/boot/firmware/tryboot.txt"
  chmod 0644 "$root/boot/firmware/tryboot.txt"
  assert_prior_tryboot_prepare_rejected unrelated-ambient-live

  # Every schema leaf and companion is fail-closed after publication.
  prepare_accepted_prior_tryboot_target
  run_prior_tryboot_candidate_prepare >/dev/null
  transition="$root/var/lib/hyperpixel2r-kms/accepted-transition"
  transition_prior="$root/var/lib/hyperpixel2r-kms/accepted-transition-prior-tryboot.txt"
  rm -- "$transition_prior"
  assert_prior_tryboot_transition_rejected companion-missing

  prepare_accepted_prior_tryboot_target
  run_prior_tryboot_candidate_prepare >/dev/null
  transition_prior="$root/var/lib/hyperpixel2r-kms/accepted-transition-prior-tryboot.txt"
  printf 'companion drift\n' >> "$transition_prior"
  assert_prior_tryboot_transition_rejected companion-drift

  prepare_accepted_prior_tryboot_target
  run_prior_tryboot_candidate_prepare >/dev/null
  transition_prior="$root/var/lib/hyperpixel2r-kms/accepted-transition-prior-tryboot.txt"
  mutation_target="$fixture/transition-prior-symlink-target"
  cp "$transition_prior" "$mutation_target"
  rm -- "$transition_prior"
  ln -s "$mutation_target" "$transition_prior"
  assert_prior_tryboot_transition_rejected companion-symlink

  prepare_accepted_prior_tryboot_target
  run_prior_tryboot_candidate_prepare >/dev/null
  transition_prior="$root/var/lib/hyperpixel2r-kms/accepted-transition-prior-tryboot.txt"
  chmod 0644 "$transition_prior"
  assert_prior_tryboot_transition_rejected companion-mode

  prepare_accepted_prior_tryboot_target
  run_prior_tryboot_candidate_prepare >/dev/null
  transition_prior="$root/var/lib/hyperpixel2r-kms/accepted-transition-prior-tryboot.txt"
  chown 65534:65534 "$transition_prior"
  assert_prior_tryboot_transition_rejected companion-owner

  prepare_accepted_prior_tryboot_target
  run_prior_tryboot_candidate_prepare >/dev/null
  transition_prior="$root/var/lib/hyperpixel2r-kms/accepted-transition-prior-tryboot.txt"
  rm -- "$transition_prior"
  mkdir "$transition_prior"
  assert_prior_tryboot_transition_rejected companion-directory

  prepare_accepted_prior_tryboot_target
  run_prior_tryboot_candidate_prepare >/dev/null
  transition="$root/var/lib/hyperpixel2r-kms/accepted-transition"
  sed -i '/^prior_tryboot_existed=/d' "$transition"
  assert_prior_tryboot_transition_rejected existence-missing

  prepare_accepted_prior_tryboot_target
  run_prior_tryboot_candidate_prepare >/dev/null
  transition="$root/var/lib/hyperpixel2r-kms/accepted-transition"
  printf 'prior_tryboot_existed=true\n' >> "$transition"
  assert_prior_tryboot_transition_rejected existence-duplicated

  prepare_accepted_prior_tryboot_target
  run_prior_tryboot_candidate_prepare >/dev/null
  transition="$root/var/lib/hyperpixel2r-kms/accepted-transition"
  replace_equals_value "$transition" prior_tryboot_existed unknown
  assert_prior_tryboot_transition_rejected existence-unknown

  prepare_accepted_prior_tryboot_target
  run_prior_tryboot_candidate_prepare >/dev/null
  transition="$root/var/lib/hyperpixel2r-kms/accepted-transition"
  replace_equals_value "$transition" prior_tryboot_sha256 none
  assert_prior_tryboot_transition_rejected digest-none-mismatch

  prepare_accepted_prior_tryboot_target
  run_prior_tryboot_candidate_prepare >/dev/null
  transition="$root/var/lib/hyperpixel2r-kms/accepted-transition"
  sed -i '/^prior_tryboot_sha256=/d' "$transition"
  assert_prior_tryboot_transition_rejected digest-missing

  prepare_accepted_prior_tryboot_target
  run_prior_tryboot_candidate_prepare >/dev/null
  transition="$root/var/lib/hyperpixel2r-kms/accepted-transition"
  replace_equals_value "$transition" prior_tryboot_sha256 malformed
  assert_prior_tryboot_transition_rejected digest-malformed

  prepare_accepted_prior_tryboot_target
  run_prior_tryboot_candidate_prepare >/dev/null
  transition="$root/var/lib/hyperpixel2r-kms/accepted-transition"
  printf 'prior_tryboot_sha256=%s\n' "$accepted_prior_tryboot_sha" >> "$transition"
  assert_prior_tryboot_transition_rejected digest-duplicated

  prepare_accepted_prior_tryboot_target
  run_prior_tryboot_candidate_prepare >/dev/null
  transition="$root/var/lib/hyperpixel2r-kms/accepted-transition"
  printf 'unknown_schema5_key=value\n' >> "$transition"
  assert_prior_tryboot_transition_rejected unknown-key
}

exercise_task3_aligned_authority() {
  # ShellCheck cannot model this sourced fixture's intentionally shared state.
  # shellcheck source=tests/task3-authority-fixture.sh
  source "$repo_root/tests/task3-authority-fixture.sh"
}

# This is the single authoritative Task 4 hostile inventory.  Keep names
# stable: the matrix selector prints each exact name and the continuation
# report records these groups/counts verbatim.  A source replacement is only
# applicable to the six boot leaves captured into private authority; the
# candidate module directory and package-status leaf are validated before
# capture and have no snapshot/revalidation phase to race.
inactive_hostile_cases() {
  local source mutation companion lock writer

  printf '%s\n' baseline writer-reader writer-self-nonmatch writer-parent-nonmatch running-third
  for source in prior-kernel prior-initramfs candidate-kernel candidate-initramfs base-dtb vc4-overlay; do
    for mutation in absent symlink directory fifo owner mode; do
      printf 'source-%s-%s\n' "$source" "$mutation"
    done
    case "$source" in
      prior-kernel|prior-initramfs) printf 'source-%s-hash-unbound\n' "$source" ;;
      *) printf 'source-%s-hash\n' "$source" ;;
    esac
    printf 'source-%s-replace-during-capture\n' "$source"
  done
  for mutation in absent symlink directory fifo owner mode hash; do
    printf 'source-prior-module-%s\n' "$mutation"
  done
  for mutation in absent symlink regular fifo owner mode; do
    printf 'source-candidate-module-tree-%s\n' "$mutation"
  done
  for mutation in absent symlink directory fifo owner mode; do
    printf 'source-package-source-%s\n' "$mutation"
  done
  for companion in prior-kernel prior-initramfs candidate-kernel candidate-initramfs; do
    for mutation in symlink directory fifo owner mode hash unrelated-content; do
      printf 'companion-%s-%s\n' "$companion" "$mutation"
    done
  done
  for lock in dpkg dpkg-frontend apt initramfs lifecycle selector; do
    printf 'writer-lock-%s\n' "$lock"
  done
  for writer in apt apt-get dpkg unattended-upgrade update-initramfs mkinitramfs \
    kernel-install dkms depmod flash-kernel rpi-eeprom-update lifecycle-remote.sh \
    accepted-lifecycle.sh stage-tryboot.sh hp2r-boot-selector raspi-config; do
    printf 'writer-process-%s\n' "$writer"
  done
  printf '%s\n' writer-script-bash-lifecycle writer-script-env-accepted \
    writer-script-shebang-stage writer-script-selector writer-script-raspi-config \
    writer-secret-argv writer-oversized-argv writer-token-substring writer-nonmatching-script
  printf '%s\n' writer-late-apt space-private space-firmware
  printf '%s\n' config-generated-output-overlong config-include config-autoboot \
    config-kernel config-initramfs config-ramfs config-os-prefix config-overlay-prefix \
    config-display-duplicate config-display-conditional config-display-competing \
    config-base-vc4-conditional config-platform-section-swapped \
    config-platform-parameter-drift config-platform-unknown \
    config-wrong-vc4-digest
}

inactive_path_fingerprint() {
  local path="$1"

  if test -L "$path"; then
    printf 'symlink\t%s\t%s\t%s\n' "$(stat -c '%U:%G:%a' "$path")" "$(readlink "$path")" \
      "$(sha256sum "$path" 2>/dev/null | awk '{ print $1 }' || true)"
  elif test -e "$path"; then
    printf '%s\t%s\t%s' "$(stat -c '%F' "$path")" "$(stat -c '%U:%G:%a' "$path")" \
      "$(stat -c '%s' "$path")"
    if test -f "$path"; then printf '\t%s' "$(sha256sum "$path" | awk '{ print $1 }')"; fi
    printf '\n'
  else
    printf 'absent\n'
  fi
}

capture_inactive_path() {
  local path="$1" output="$2"
  inactive_path_fingerprint "$path" > "$output"
}

assert_inactive_path_preserved() {
  local path="$1" expected="$2" label="$3"
  local actual="$fixture/inactive-path-actual"

  capture_inactive_path "$path" "$actual"
  cmp -s "$expected" "$actual" || fail "inactive hostile changed $label"
}

inactive_companion_path() {
  local name="$1"
  printf '%s/accepted-transition-%s.img\n' "$root/var/lib/hyperpixel2r-kms" "$name"
}

inactive_assert_failure_preserves_state() {
  local normal_before="$1" module_before="$2" overlay_before="$3" companion_dir="$4"
  local name path

  cmp -s "$normal_before" "$root/boot/firmware/config.txt" ||
    fail "hostile $HP2R_FIXTURE_HOSTILE changed normal config"
  assert_inactive_path_preserved "$root/lib/modules/$release/extra/hyperpixel2r_kms.ko" \
    "$module_before" 'conventional module'
  assert_inactive_path_preserved "$root/boot/firmware/overlays/$overlay_file" \
    "$overlay_before" 'conventional overlay'
  assert_absent "$root/var/lib/hyperpixel2r-kms/accepted-transition"
  assert_absent "$root/boot/firmware/tryboot.txt"
  for name in prior-kernel prior-initramfs candidate-kernel candidate-initramfs; do
    path="$(inactive_companion_path "$name")"
    assert_inactive_path_preserved "$path" "$companion_dir/$name" "companion $name"
  done
  if find "$root/boot/firmware" -maxdepth 1 -type f \
    -name "hp2r-${source_revision:0:12}-*-kernel.img" -print -quit | grep -q . ||
    find "$root/boot/firmware" -maxdepth 1 -type f \
      -name "hp2r-${source_revision:0:12}-*-initramfs.img" -print -quit | grep -q .; then
    fail "hostile $HP2R_FIXTURE_HOSTILE wrote a Task 5 firmware destination"
  fi
}

inactive_mutate_source() {
  local name="$1" mutation="$2" path='' source_kind=file

  case "$name" in
    prior-kernel) path="$root/boot/vmlinuz-$release" ;;
    prior-initramfs) path="$root/boot/initrd.img-$release" ;;
    candidate-kernel) path="$root/boot/vmlinuz-$candidate_release" ;;
    candidate-initramfs) path="$root/boot/initrd.img-$candidate_release" ;;
    base-dtb) path="$root/boot/firmware/bcm2710-rpi-zero-2-w.dtb" ;;
    vc4-overlay) path="$root/boot/firmware/overlays/vc4-kms-v3d.dtbo" ;;
    prior-module) path="$root/lib/modules/$release/extra/hyperpixel2r_kms.ko" ;;
    candidate-module-tree) path="$root/lib/modules/$candidate_release"; source_kind=dir ;;
    package-source) path="$root/var/lib/dpkg/info/linux-image-$candidate_release.list" ;;
    *) fail "unknown inactive source: $name" ;;
  esac
  case "$mutation" in
    replace-during-capture)
      export HP2R_FIXTURE_RACE_INACTIVE_SOURCE="$name"
      return
      ;;
    absent) rm -rf -- "$path" ;;
    symlink)
      rm -rf -- "$path"
      ln -s /etc/passwd "$path"
      ;;
    directory)
      rm -rf -- "$path"
      mkdir "$path"
      ;;
    regular)
      rm -rf -- "$path"
      printf 'not a module directory\n' > "$path"
      ;;
    fifo)
      rm -rf -- "$path"
      mkfifo "$path"
      ;;
    owner) chown 65534:65534 "$path" ;;
    mode)
      if test "$source_kind" = dir; then chmod 0700 "$path"; else chmod 0600 "$path"; fi
      ;;
    hash|hash-unbound) printf 'source digest drift\n' >> "$path" ;;
    *) fail "unknown inactive source mutation: $mutation" ;;
  esac
}

inactive_mutate_companion() {
  local name="$1" mutation="$2" path source
  path="$(inactive_companion_path "$name")"
  case "$name" in
    prior-kernel) source="$root/boot/vmlinuz-$release" ;;
    prior-initramfs) source="$root/boot/initrd.img-$release" ;;
    candidate-kernel) source="$root/boot/vmlinuz-$candidate_release" ;;
    candidate-initramfs) source="$root/boot/initrd.img-$candidate_release" ;;
    *) fail "unknown inactive companion: $name" ;;
  esac
  case "$mutation" in
    symlink) ln -s /etc/passwd "$path" ;;
    directory) mkdir "$path" ;;
    fifo) mkfifo "$path" ;;
    owner) printf 'unsafe companion\n' > "$path"; chown 65534:65534 "$path"; chmod 0600 "$path" ;;
    mode) printf 'unsafe companion\n' > "$path"; chmod 0644 "$path" ;;
    hash) cp "$source" "$path"; chmod 0600 "$path"; printf 'companion digest drift\n' >> "$path" ;;
    unrelated-content) printf 'unrelated companion content\n' > "$path"; chmod 0600 "$path" ;;
    *) fail "unknown inactive companion mutation: $mutation" ;;
  esac
}

prepare_inactive_normalized_verified_for_backlight_probe() {
  local prior_kernel="$1" prior_initramfs="$2" candidate_release="$3"

  cp "$root$prior_kernel" "$root/boot/firmware/kernel8.img"
  cp "$root$prior_initramfs" "$root/boot/firmware/initramfs8"
  chown root:root "$root/boot/firmware/kernel8.img" "$root/boot/firmware/initramfs8"
  chmod 0644 "$root/boot/firmware/kernel8.img" "$root/boot/firmware/initramfs8"
  mkdir -p "$root/proc/device-tree/chosen/bootloader"
  printf '\0\0\0\1' > "$root/proc/device-tree/chosen/bootloader/tryboot"
  install_live_hardware
  export HP2R_FIXTURE_RELEASE_OVERRIDE="$candidate_release"
  run_controller commit-boot.sh >/dev/null
  printf '\0\0\0\0' > "$root/proc/device-tree/chosen/bootloader/tryboot"
  run_controller accepted-lifecycle.sh --action mark-explicit-normal-verified >/dev/null
  run_controller accepted-lifecycle.sh --action normalize-inactive-kernel >/dev/null
  run_controller accepted-lifecycle.sh --action mark-normalized-verified >/dev/null
  grep -Fxq 'phase=normalized_verified' \
    "$root/var/lib/hyperpixel2r-kms/accepted-transition" ||
    fail 'backlight probe fixture did not reach normalized verification'
}

exercise_inactive_kernel_prepare() {
  local candidate_release='6.18.39+rpt-rpi-v8'
  local candidate_driver_version=0.2.0
  if test "${HP2R_FIXTURE_HOSTILE:-}" = config-generated-output-overlong; then
    candidate_release="6.18.39+rpt-rpi-v8-$(printf x%.0s {1..70})"
  fi
  local candidate_parent="$fixture/inactive-kernel-target"
  local candidate_target="$candidate_parent/$candidate_release"
  local candidate_manifest="$candidate_target/target.txt"
  local candidate_artifact="$fixture/inactive-candidate-artifact"
  local artifact_manifest="$candidate_artifact/manifest.txt"
  local state_dir="$root/var/lib/hyperpixel2r-kms"
  local prior_kernel="/boot/vmlinuz-$release"
  local prior_initramfs="/boot/initrd.img-$release"
  local candidate_kernel="/boot/vmlinuz-$candidate_release"
  local candidate_initramfs="/boot/initrd.img-$candidate_release"
  local normal_before="$fixture/inactive-normal-before"
  local conventional_before="$fixture/inactive-conventional-before"
  local prior_kernel_before="$fixture/inactive-prior-kernel-before"
  local prior_initramfs_before="$fixture/inactive-prior-initramfs-before"
  local revision12 release_tag kernel_name initramfs_name companion prepared_in_hostile=false accepted_pre_stage_sha
  local legacy_artifact legacy_backlight_initial legacy_backlight_drift
  local legacy_post_auth_backlight_drift legacy_stage_output
  local legacy_live_before legacy_proof_before legacy_transition_before
  local authorization_tuple_shape authorization_stage_output
  local legacy_stage_completed=false
  local candidate_stage_repo=''

  new_target
  if test "${HP2R_FIXTURE_PRIOR_TRYBOOT:-}" = 1; then
    printf '%s\n' \
      '[all]' \
      '# accepted prior one-shot configuration' \
      'dtoverlay=hyperpixel2r-kms-eefaf3ae40fd.dtbo' \
      > "$root/boot/firmware/tryboot.txt"
    chown root:root "$root/boot/firmware/tryboot.txt"
    chmod 0644 "$root/boot/firmware/tryboot.txt"
  fi
  if [[ "${HP2R_FIXTURE_INTERRUPT_AFTER:-}" == candidate-* ]]; then
    HP2R_FIXTURE_INTERRUPT_AFTER='' run_stage >/dev/null
  else
    run_stage >/dev/null
  fi
  install_live_hardware
  run_controller commit-boot.sh >/dev/null
  if test "${HP2R_FIXTURE_LEGACY_ACCEPTED:-}" = 1; then
    legacy_artifact="$root/usr/lib/hyperpixel2r-kms/0.2.0/$source_revision/$release"
    downgrade_artifact_to_schema_one "$legacy_artifact"
    legacy_backlight_initial="${HP2R_FIXTURE_LEGACY_BACKLIGHT_INITIAL:-present}"
    case "$legacy_backlight_initial" in
      present)
        install -o root -g root -m 0644 \
          "$repo_root/dist/artifacts/$release/$backlight_rule_file" \
          "$backlight_rule_path"
        ;;
      absent) assert_absent "$backlight_rule_path" ;;
      *) fail "unknown legacy backlight initial state: $legacy_backlight_initial" ;;
    esac
  fi
  if test "${HP2R_FIXTURE_CASE:-}" = inactive-kernel-base-vc4; then
    # Production break: the inactive classifier must not count Raspberry Pi's
    # base VC4 KMS enablement as a second competing display selection.
    sed -i "/^dtoverlay=$overlay_file$/i dtoverlay=vc4-kms-v3d" \
      "$root/boot/firmware/config.txt"
  fi
  if test "${HP2R_FIXTURE_CASE:-}" = inactive-kernel-platform-overlays; then
    # Production break: exact Raspberry Pi platform-only overlays must not be
    # classified as conditional display selections.
    platform_config="$fixture/inactive-platform-config"
    {
      printf '[cm5]\ndtoverlay=dwc2,dr_mode=host\n'
      printf '[pi5]\ndtoverlay=nospi10\n'
      cat "$root/boot/firmware/config.txt"
    } > "$platform_config"
    sed -i "/^dtoverlay=$overlay_file$/i dtoverlay=vc4-kms-v3d" "$platform_config"
    mv "$platform_config" "$root/boot/firmware/config.txt"
  fi
  run_accepted_remote record-accepted 0.2.0 "$source_revision" "$release" >/dev/null
  if test "${HP2R_FIXTURE_LEGACY_ACCEPTED:-}" = 1; then
    grep -Fxq 'schema_version=2' "$root/var/lib/hyperpixel2r-kms/accepted-state" ||
      fail 'inactive legacy accepted fixture is not schema 2'
  fi
  cp "$root/boot/firmware/config.txt" "$normal_before"
  cp "$root/boot/firmware/config.txt" "$conventional_before"

  rm -rf -- "$candidate_parent"
  mkdir -p "$candidate_target"
  cp -a "$repo_root/dist/kernel-target/$release/root" "$candidate_target/root"
  cp "$repo_root/dist/kernel-target/$release/target.txt" "$candidate_manifest"
  printf 'inactive prior kernel bytes\n' > "$root$prior_kernel"
  printf 'inactive prior initramfs bytes\n' > "$root$prior_initramfs"
  cp "$root$prior_kernel" "$root/boot/firmware/kernel8.img"
  cp "$root$prior_initramfs" "$root/boot/firmware/initramfs8"
  chown root:root "$root/boot/firmware/kernel8.img" "$root/boot/firmware/initramfs8"
  chmod 0644 "$root/boot/firmware/kernel8.img" "$root/boot/firmware/initramfs8"
  printf 'inactive candidate kernel bytes\n' > "$candidate_target/root$candidate_kernel"
  printf 'inactive candidate initramfs bytes\n' > "$candidate_target/root$candidate_initramfs"
  mkdir -p "$root/lib/modules/$candidate_release" "$root/var/lib/dpkg/info"
  : > "$root/var/lib/dpkg/info/linux-image-$candidate_release.list"
  cp "$candidate_target/root$candidate_kernel" "$root$candidate_kernel"
  cp "$candidate_target/root$candidate_initramfs" "$root$candidate_initramfs"
  cp "$candidate_target/root/boot/firmware/bcm2710-rpi-zero-2-w.dtb" \
    "$root/boot/firmware/bcm2710-rpi-zero-2-w.dtb"
  cp "$candidate_target/root/boot/firmware/overlays/vc4-kms-v3d.dtbo" \
    "$root/boot/firmware/overlays/vc4-kms-v3d.dtbo"
  cp -a "$repo_root/dist/artifacts/$release" "$candidate_artifact"
  if test "${HP2R_FIXTURE_CASE:-}" = inactive-kernel-driver-upgrade; then
    candidate_driver_version=0.2.1
    replace_manifest_value "$artifact_manifest" driver_version "$candidate_driver_version"
    candidate_stage_repo="$fixture/inactive-upgrade-stage-source"
    cp -a "$repo_root" "$candidate_stage_repo"
    sed -i 's/^HP2R_DRIVER_VERSION="0\.2\.0"$/HP2R_DRIVER_VERSION="0.2.1"/' \
      "$candidate_stage_repo/scripts/common.sh"
  fi
  replace_manifest_value "$artifact_manifest" kernel_release "$candidate_release"
  replace_manifest_value "$artifact_manifest" module_vermagic "$candidate_release fixture"
  replace_manifest_value "$candidate_manifest" kernel_release "$candidate_release"
  replace_manifest_value "$candidate_manifest" kernel_image_path "$candidate_kernel"
  replace_manifest_value "$candidate_manifest" initramfs_path "$candidate_initramfs"
  replace_manifest_value "$candidate_manifest" kernel_image_sha256 \
    "$(sha256sum "$candidate_target/root$candidate_kernel" | awk '{ print $1 }')"
  replace_manifest_value "$candidate_manifest" initramfs_sha256 \
    "$(sha256sum "$candidate_target/root$candidate_initramfs" | awk '{ print $1 }')"
  cp "$root$prior_kernel" "$prior_kernel_before"
  cp "$root$prior_initramfs" "$prior_initramfs_before"

  run_inactive_prepare_child() {
    PATH="$bin:$PATH" \
      HP2R_FIXTURE_ROOT="$root" \
      HP2R_FIXTURE_RELEASE="$release" \
      HP2R_FIXTURE_LOG="$log" \
      HP2R_FIXTURE_REPO_ROOT="$repo_root" \
      HP2R_FIXTURE_ACCEPTED_CONTROLLER=1 \
      HP2R_TARGET=pi@fixture \
      scripts/accepted-lifecycle.sh \
        --action prepare-new \
        --driver-version "$candidate_driver_version" \
        --source-revision "$source_revision" \
        --kernel-release "$candidate_release" \
        --kernel-target "$candidate_parent" \
        --target-identity-sha256 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
        --manifest-sha256 "$(sha256sum "$artifact_manifest" | awk '{ print $1 }')" \
        --module-file hyperpixel2r_kms.ko \
        --module-sha256 "$(awk -F '\t' '$1 == "module_sha256" { print $2 }' "$artifact_manifest")" \
        --overlay-file "$overlay_file" \
        --overlay-sha256 "$(awk -F '\t' '$1 == "overlay_sha256" { print $2 }' "$artifact_manifest")" \
        --backlight-rule-file "$backlight_rule_file" \
        --backlight-rule-sha256 "$(awk -F '\t' '$1 == "backlight_rule_sha256" { print $2 }' "$artifact_manifest")" \
        --lifecycle-capability exact-backlight-metadata-v1
  }
  run_inactive_prepare() {
    if test "${HP2R_FIXTURE_OVERSIZED_TRANSPORT_ANCESTOR:-}" = 1; then
      HP2R_FIXTURE_TRANSPORT_DRIVER_VERSION="$candidate_driver_version" \
        HP2R_FIXTURE_TRANSPORT_SOURCE_REVISION="$source_revision" \
        HP2R_FIXTURE_TRANSPORT_KERNEL_RELEASE="$candidate_release" \
        HP2R_FIXTURE_TRANSPORT_KERNEL_TARGET="$candidate_parent" \
        HP2R_FIXTURE_TRANSPORT_TARGET_IDENTITY=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
        HP2R_FIXTURE_TRANSPORT_MANIFEST_SHA="$(sha256sum "$artifact_manifest" | awk '{ print $1 }')" \
        HP2R_FIXTURE_TRANSPORT_MODULE_SHA="$(awk -F '\t' '$1 == "module_sha256" { print $2 }' "$artifact_manifest")" \
        HP2R_FIXTURE_TRANSPORT_OVERLAY_FILE="$overlay_file" \
        HP2R_FIXTURE_TRANSPORT_OVERLAY_SHA="$(awk -F '\t' '$1 == "overlay_sha256" { print $2 }' "$artifact_manifest")" \
        HP2R_FIXTURE_TRANSPORT_BACKLIGHT_RULE_SHA="$(awk -F '\t' '$1 == "backlight_rule_sha256" { print $2 }' "$artifact_manifest")" \
        PATH="$bin:$PATH" \
        HP2R_FIXTURE_ROOT="$root" \
        HP2R_FIXTURE_RELEASE="$release" \
        HP2R_FIXTURE_LOG="$log" \
        HP2R_FIXTURE_REPO_ROOT="$repo_root" \
        HP2R_FIXTURE_ACCEPTED_CONTROLLER=1 \
        HP2R_TARGET=pi@fixture \
        bash "$repo_root/tests/transport-ancestor.sh" "$(printf z%.0s {1..5000})"
      return
    fi
    run_inactive_prepare_child
  }
  run_inactive_stage() {
    HP2R_FIXTURE_REPLACE_OVERLAY="$overlay_file" \
      HP2R_FIXTURE_STAGE_REPO_OVERRIDE="${candidate_stage_repo:-$repo_root}" \
      HP2R_FIXTURE_SOURCE_ROOT_OVERRIDE="${candidate_stage_repo:-$repo_root}" run_stage \
      --stage-only \
      --artifact-dir "$candidate_artifact" \
      --kernel-target "$candidate_parent" \
      --kernel-release "$candidate_release" \
      --target-identity-sha256 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  }
  if test "${HP2R_FIXTURE_CASE:-}" = inactive-kernel-transport-ancestor; then
    local before="$fixture/transport-ancestor-config-before"
    cp "$root/boot/firmware/config.txt" "$before"
    if ! HP2R_FIXTURE_OVERSIZED_TRANSPORT_ANCESTOR=1 run_inactive_prepare >/dev/null 2>&1; then
      cmp -s "$before" "$root/boot/firmware/config.txt" ||
        fail 'oversized transport ancestor rejection changed normal config'
      assert_absent "$state_dir/accepted-transition"
      fail 'writer guard treats the current transport ancestry as a competing process'
    fi
    assert_file "$state_dir/accepted-transition"
    assert_no_private_workspaces
    exit 0
  fi
  if test -n "${HP2R_FIXTURE_HOSTILE:-}"; then
    local hostile="$HP2R_FIXTURE_HOSTILE" negative=true name mutation lock writer pid=''
    local normal_state="$fixture/inactive-hostile-normal" module_state="$fixture/inactive-hostile-module"
    local overlay_state="$fixture/inactive-hostile-overlay" companion_state="$fixture/inactive-hostile-companions"

    mkdir "$companion_state"
    case "$hostile" in
      baseline|writer-self-nonmatch|writer-parent-nonmatch|source-prior-kernel-hash-unbound|source-prior-initramfs-hash-unbound) negative=false ;;
      writer-reader) "$fixture/writer-bin/reader" 30 >/dev/null 2>&1 & pid="$!"; negative=false ;;
      running-third) export HP2R_FIXTURE_REMOTE_RUNNING_RELEASE='6.18.33+rpt-rpi-v8' ;;
      source-*)
        for name in prior-kernel prior-initramfs candidate-kernel candidate-initramfs \
          base-dtb vc4-overlay prior-module candidate-module-tree package-source; do
          if [[ "${hostile#source-}" == "$name-"* ]]; then
            mutation="${hostile#source-$name-}"
            inactive_mutate_source "$name" "$mutation"
            name=''
            break
          fi
        done
        test -z "$name" || fail "unknown inactive hostile source case: $hostile"
        ;;
      companion-*)
        for name in prior-kernel prior-initramfs candidate-kernel candidate-initramfs; do
          if [[ "${hostile#companion-}" == "$name-"* ]]; then
            mutation="${hostile#companion-$name-}"
            inactive_mutate_companion "$name" "$mutation"
            name=''
            break
          fi
        done
        test -z "$name" || fail "unknown inactive hostile companion case: $hostile"
        ;;
      writer-lock-*)
        lock="${hostile#writer-lock-}"
        case "$lock" in
          dpkg) export HP2R_FIXTURE_ACTIVE_LOCK="$root/var/lib/dpkg/lock" ;;
          dpkg-frontend) export HP2R_FIXTURE_ACTIVE_LOCK="$root/var/lib/dpkg/lock-frontend" ;;
          apt) export HP2R_FIXTURE_ACTIVE_LOCK="$root/run/lock/apt" ;;
          initramfs) export HP2R_FIXTURE_ACTIVE_LOCK="$root/run/lock/update-initramfs" ;;
          lifecycle) export HP2R_FIXTURE_ACTIVE_LOCK="$root/run/lock/hyperpixel2r-kms" ;;
          selector) export HP2R_FIXTURE_ACTIVE_LOCK="$root/run/lock/hp2r-boot-selector" ;;
          *) fail "unknown inactive writer lock: $lock" ;;
        esac
        mkdir -p "$(dirname "$HP2R_FIXTURE_ACTIVE_LOCK")"
        bash -c 'exec 9>"$1"; flock -n 9; sleep 30' bash \
          "$HP2R_FIXTURE_ACTIVE_LOCK" >/dev/null 2>&1 & pid="$!"
        ;;
      writer-process-*)
        writer="${hostile#writer-process-}"
        test -x "$fixture/writer-bin/$writer" || fail "unknown inactive writer process: $writer"
        "$fixture/writer-bin/$writer" 30 >/dev/null 2>&1 & pid="$!"
        ;;
      writer-script-bash-lifecycle)
        bash "$fixture/writer-bin/lifecycle-remote.sh" >/dev/null 2>&1 & pid="$!"
        ;;
      writer-script-env-accepted)
        env bash "$fixture/writer-bin/accepted-lifecycle.sh" >/dev/null 2>&1 & pid="$!"
        ;;
      writer-script-shebang-stage)
        "$fixture/writer-bin/stage-tryboot.sh" >/dev/null 2>&1 & pid="$!"
        ;;
      writer-script-selector)
        "$fixture/writer-bin/hp2r-boot-selector" >/dev/null 2>&1 & pid="$!"
        ;;
      writer-script-raspi-config)
        "$fixture/writer-bin/raspi-config" >/dev/null 2>&1 & pid="$!"
        ;;
      writer-secret-argv)
        negative=false
        writer_secret='HP2R_WRITER_SECRET_2cf885d5d42f'
        "$fixture/writer-bin/reader" "$writer_secret" >/dev/null 2>&1 & pid="$!"
        ;;
      writer-oversized-argv)
        writer_oversized="$(printf z%.0s {1..5000})"
        "$fixture/writer-bin/reader" "$writer_oversized" >/dev/null 2>&1 & pid="$!"
        ;;
      writer-token-substring)
        negative=false
        "$fixture/writer-bin/reader" 'not-hp2r-boot-selector-not-a-script' >/dev/null 2>&1 & pid="$!"
        ;;
      writer-nonmatching-script)
        negative=false
        "$fixture/writer-bin/harmless-raspi-config-helper" >/dev/null 2>&1 & pid="$!"
        ;;
      writer-late-apt)
        export HP2R_FIXTURE_LATE_WRITER=apt
        printf 'apt\n' > "$root/tmp/inactive-late-writer-class"
        bash -c 'while ! test -e "$1"; do sleep 0.01; done; exec "$2" 30' bash \
          "$root/tmp/inactive-late-writer-start" "$fixture/writer-bin/apt" \
          >/dev/null 2>&1 & pid="$!"
        ;;
      space-private) export HP2R_FIXTURE_SPACE=private ;;
      space-firmware) export HP2R_FIXTURE_SPACE=firmware ;;
      config-generated-output-overlong) : > "$root/tmp/inactive-force-overlong" ;;
      config-include) printf 'include extra.txt\n' >> "$root/boot/firmware/config.txt" ;;
      config-autoboot) printf 'autoboot.txt\n' >> "$root/boot/firmware/config.txt" ;;
      config-kernel) printf 'kernel=foreign.img\n' >> "$root/boot/firmware/config.txt" ;;
      config-initramfs) printf 'initramfs foreign.img followkernel\n' >> "$root/boot/firmware/config.txt" ;;
      config-ramfs) printf 'ramfsfile=foreign.img\n' >> "$root/boot/firmware/config.txt" ;;
      config-os-prefix) printf 'os_prefix=foreign/\n' >> "$root/boot/firmware/config.txt" ;;
      config-overlay-prefix) printf 'overlay_prefix=foreign/\n' >> "$root/boot/firmware/config.txt" ;;
      config-display-duplicate) printf 'dtoverlay=hyperpixel2r-kms-aaaaaaaaaaaa.dtbo\n' >> "$root/boot/firmware/config.txt" ;;
      config-display-conditional) printf '[pi4]\ndtoverlay=hyperpixel2r-kms-aaaaaaaaaaaa.dtbo\n' >> "$root/boot/firmware/config.txt" ;;
      config-display-competing) printf 'dtoverlay=vc4-fkms-v3d\n' >> "$root/boot/firmware/config.txt" ;;
      config-base-vc4-conditional) printf '[cm5]\ndtoverlay=vc4-kms-v3d\n' >> "$root/boot/firmware/config.txt" ;;
      config-platform-section-swapped) printf '[cm5]\ndtoverlay=nospi10\n' >> "$root/boot/firmware/config.txt" ;;
      config-platform-parameter-drift) printf '[cm5]\ndtoverlay=dwc2,dr_mode=peripheral\n' >> "$root/boot/firmware/config.txt" ;;
      config-platform-unknown) printf '[cm5]\ndtoverlay=foreign-platform\n' >> "$root/boot/firmware/config.txt" ;;
      config-wrong-vc4-digest) printf 'vc4 digest drift\n' >> "$root/boot/firmware/overlays/vc4-kms-v3d.dtbo" ;;
      *) fail "unknown inactive hostile case: $hostile" ;;
    esac
    cp "$root/boot/firmware/config.txt" "$normal_state"
    capture_inactive_path "$root/lib/modules/$release/extra/hyperpixel2r_kms.ko" "$module_state"
    capture_inactive_path "$root/boot/firmware/overlays/$overlay_file" "$overlay_state"
    for name in prior-kernel prior-initramfs candidate-kernel candidate-initramfs; do
      capture_inactive_path "$(inactive_companion_path "$name")" "$companion_state/$name"
    done
    if "$negative"; then
      if run_inactive_prepare >/dev/null 2>&1; then
        if test "$hostile" = writer-late-apt && ! test -f "$root/tmp/inactive-late-writer-start"; then
          fail 'inactive late-writer fixture did not launch after capture'
        fi
        fail "inactive prepare accepted hostile $hostile"
      fi
      test -z "$pid" || { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; }
      inactive_assert_failure_preserves_state "$normal_state" "$module_state" "$overlay_state" "$companion_state"
      exit 0
    fi
    if test "$hostile" = writer-secret-argv; then
      run_inactive_prepare > "$root/tmp/inactive-secret-output" 2>&1 ||
        fail 'inactive prepare rejected harmless secret argv sentinel'
      for output in "$root/tmp/inactive-secret-output" "$log" \
        "$root/tmp/accepted-controller-remote-command"; do
        test ! -e "$output" || ! grep -Fq "$writer_secret" "$output" ||
          fail 'writer secret argv escaped the privileged writer helper'
      done
    elif test "$hostile" = baseline; then
      run_inactive_prepare || fail "inactive prepare rejected harmless $hostile"
    else
      run_inactive_prepare >/dev/null || fail "inactive prepare rejected harmless $hostile"
    fi
    test -z "$pid" || { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; }
    prepared_in_hostile=true
  fi
  if "$prepared_in_hostile"; then
    :
  elif test -n "${HP2R_FIXTURE_INTERRUPT_AFTER:-}" && \
    [[ "${HP2R_FIXTURE_INTERRUPT_AFTER}" == accepted-transition-* ]]; then
    if run_inactive_prepare >/dev/null 2>&1; then
      fail "inactive prepare ignored interruption after $HP2R_FIXTURE_INTERRUPT_AFTER"
    fi
    assert_absent "$state_dir/accepted-transition"
    HP2R_FIXTURE_INTERRUPT_AFTER='' run_inactive_prepare >/dev/null ||
      fail "inactive prepare did not recover exact orphan companions after $HP2R_FIXTURE_INTERRUPT_AFTER"
  else
    run_inactive_prepare >/dev/null
  fi

  revision12="${source_revision:0:12}"
  release_tag="$(printf %s "$candidate_release" | sha256sum | awk '{ print substr($1, 1, 12) }')"
  kernel_name="hp2r-$revision12-$release_tag-kernel.img"
  initramfs_name="hp2r-$revision12-$release_tag-initramfs.img"
  if test "${HP2R_FIXTURE_CASE:-}" = inactive-kernel-uninstall-orphan; then
    local orphan_companion="$state_dir/accepted-transition-prior-kernel.img"

    run_accepted_remote recover-accepted >/dev/null
    ln -s "$root$prior_kernel" "$orphan_companion"
    if run_accepted_remote uninstall-accepted \
      0.2.0 "$source_revision" "$release" >/dev/null 2>&1; then
      fail 'accepted uninstall ignored a symlinked inactive transition companion'
    fi
    test -L "$orphan_companion" ||
      fail 'rejected accepted uninstall changed the symlinked inactive companion'
    exit 0
  fi
  assert_inactive_recovered_prior() {
    local expected_reboot="$1" recovery_endpoint="${2:-prior}"
    local phase="${HP2R_FIXTURE_RECOVERY_PHASE:-unknown}"
    local output="$fixture/recovery-$phase.out"
    local recovery_root="$fixture/phase-recovery-root-$phase"
    local forward_root="$fixture/phase-forward-root-$phase"
    local recovery_log="$fixture/phase-recovery-$phase.log"
    local forward_log="$fixture/phase-forward-$phase.log"

    use_phase_root() {
      root="$1"
      log="$2"
      state_dir="$root/var/lib/hyperpixel2r-kms"
      backlight_rule_path="$root/etc/udev/rules.d/$backlight_rule_file"
    }
    assert_phase_authority_retired() {
      assert_absent "$root/boot/firmware/$kernel_name"
      assert_absent "$root/boot/firmware/$initramfs_name"
      assert_absent "$state_dir/accepted-transition"
      assert_absent "$state_dir/accepted-transition-prior-tryboot.txt"
      for companion in \
        accepted-transition-prior-config.txt accepted-transition-prepared.sha256 \
        accepted-transition-prior-kernel.img accepted-transition-prior-initramfs.img \
        accepted-transition-candidate-kernel.img accepted-transition-candidate-initramfs.img
      do
        assert_absent "$state_dir/$companion"
      done
      assert_no_private_workspaces
    }
    assert_phase_endpoint() {
      local endpoint="$1"
      local candidate_installed_artifact="$root/usr/lib/hyperpixel2r-kms/$candidate_driver_version/$source_revision/$candidate_release"
      local prior_installed_artifact="$root/usr/lib/hyperpixel2r-kms/0.2.0/$source_revision/$release"

      case "$endpoint" in
        prior)
          cmp -s "$normal_before" "$root/boot/firmware/config.txt" ||
            fail "recovery did not restore prior normal config for $phase"
          cmp -s "$root$prior_kernel" "$root/boot/firmware/kernel8.img" ||
            fail "recovery did not restore prior kernel for $phase"
          cmp -s "$root$prior_initramfs" "$root/boot/firmware/initramfs8" ||
            fail "recovery did not restore prior initramfs for $phase"
          grep -Fxq "kernel_release=$release" "$state_dir/accepted-state" ||
            fail "recovery replaced prior receipt for $phase"
          assert_file "$prior_installed_artifact/manifest.txt"
          assert_absent "$candidate_installed_artifact"
          ;;
        candidate)
          grep -Fxq 'schema_version=4' "$state_dir/accepted-state" ||
            fail "forward replay lost schema-4 receipt for $phase"
          grep -Fxq "kernel_release=$candidate_release" "$state_dir/accepted-state" ||
            fail "forward replay retained prior receipt for $phase"
          cmp -s "$root$candidate_kernel" "$root/boot/firmware/kernel8.img" ||
            fail "forward replay changed candidate kernel bytes for $phase"
          cmp -s "$root$candidate_initramfs" "$root/boot/firmware/initramfs8" ||
            fail "forward replay changed candidate initramfs bytes for $phase"
          grep -Fxq "normal_config_sha256=$(sha256sum "$root/boot/firmware/config.txt" | awk '{ print $1 }')" \
            "$state_dir/accepted-state" ||
            fail "forward replay lost normalized config bytes for $phase"
          assert_file "$candidate_installed_artifact/manifest.txt"
          assert_absent "$prior_installed_artifact"
          ;;
        *) fail "unknown phase replay endpoint: $endpoint" ;;
      esac
      assert_phase_authority_retired
    }
    forward_complete_inactive_phase() {
      local forward_phase

      forward_phase="$(awk -F= '$1 == "phase" { print $2 }' "$state_dir/accepted-transition")"
      if test "$forward_phase" = prepared; then
        run_inactive_stage >/dev/null
        forward_phase=staged
      fi
      if test "$forward_phase" = staged; then
        export HP2R_FIXTURE_RELEASE_OVERRIDE="$candidate_release"
        mkdir -p "$root/proc/device-tree/chosen/bootloader"
        printf '\0\0\0\1' > "$root/proc/device-tree/chosen/bootloader/tryboot"
        install_live_hardware
        run_controller commit-boot.sh >/dev/null
        forward_phase=explicit_normal_published
      fi
      if test "$forward_phase" = explicit_normal_published; then
        mkdir -p "$root/proc/device-tree/chosen/bootloader"
        printf '\0\0\0\0' > "$root/proc/device-tree/chosen/bootloader/tryboot"
        run_controller accepted-lifecycle.sh --action mark-explicit-normal-verified >/dev/null
        forward_phase=explicit_normal_verified
      fi
      case "$forward_phase" in
        explicit_normal_verified|canonical_initramfs_published|canonical_pair_published)
          run_controller accepted-lifecycle.sh --action normalize-inactive-kernel >/dev/null
          forward_phase=normalized_config_published
          ;;
      esac
      if test "$forward_phase" = normalized_config_published; then
        run_controller accepted-lifecycle.sh --action mark-normalized-verified >/dev/null
      fi
      export HP2R_FIXTURE_RELEASE_OVERRIDE="$candidate_release"
      run_controller accepted-lifecycle.sh --action finalize >/dev/null
      run_controller accepted-lifecycle.sh --action finalize >/dev/null
      unset HP2R_FIXTURE_RELEASE_OVERRIDE
    }

    find "$state_dir" -mindepth 1 -maxdepth 1 -type d \
      -name '.hp2r-transaction.*' -exec rm -rf -- {} +
    cp -a "$root" "$recovery_root"
    cp -a "$root" "$forward_root"
    cp "$log" "$recovery_log"
    cp "$log" "$forward_log"
    chmod 0666 "$recovery_log" "$forward_log"

    use_phase_root "$recovery_root" "$recovery_log"
    run_accepted_remote recover-accepted >"$output"
    run_accepted_remote recover-accepted >>"$output"
    grep -Fxq "reboot_required=$expected_reboot" "$output" ||
      fail "recovery result contract drifted for $phase"
    test "$(grep -Fxc 'reboot_required=false' "$output")" -ge 1 ||
      fail "repeat recovery did not report fixed no-reboot completion for $phase"
    assert_phase_endpoint "$recovery_endpoint"

    use_phase_root "$forward_root" "$forward_log"
    forward_complete_inactive_phase
    assert_phase_endpoint candidate

    if test "$recovery_endpoint" = candidate; then
      diff -ru "$recovery_root/boot/firmware" "$forward_root/boot/firmware" >/dev/null ||
        fail "phase recovery and forward boot endpoints differ for $phase"
      diff -ru "$recovery_root/var/lib/hyperpixel2r-kms" \
        "$forward_root/var/lib/hyperpixel2r-kms" >/dev/null ||
        fail "phase recovery and forward receipt endpoints differ for $phase"
    fi
  }
  grep -Fxq 'schema_version=6' "$state_dir/accepted-transition" ||
    fail 'inactive prepare did not publish schema-6 authority'
  grep -Fxq 'target_identity_sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
    "$state_dir/accepted-transition" || fail 'inactive prepare did not bind target identity'
  grep -Fxq "candidate_kernel_file=$kernel_name" "$state_dir/accepted-transition" ||
    fail 'inactive prepare did not use deterministic kernel firmware name'
  grep -Fxq "candidate_initramfs_file=$initramfs_name" "$state_dir/accepted-transition" ||
    fail 'inactive prepare did not use deterministic initramfs firmware name'
  for companion in \
    accepted-transition-prior-kernel.img \
    accepted-transition-prior-initramfs.img \
    accepted-transition-candidate-kernel.img \
    accepted-transition-candidate-initramfs.img
  do
    assert_file "$state_dir/$companion"
    test "$(stat -c '%U:%G:%a' "$state_dir/$companion")" = root:root:600 ||
      fail "inactive companion ownership drifted: $companion"
  done
  cmp -s "$root$prior_kernel" "$state_dir/accepted-transition-prior-kernel.img" ||
    fail 'inactive prior kernel companion bytes drifted'
  cmp -s "$root$prior_initramfs" "$state_dir/accepted-transition-prior-initramfs.img" ||
    fail 'inactive prior initramfs companion bytes drifted'
  cmp -s "$root$candidate_kernel" "$state_dir/accepted-transition-candidate-kernel.img" ||
    fail 'inactive candidate kernel companion bytes drifted'
  cmp -s "$root$candidate_initramfs" "$state_dir/accepted-transition-candidate-initramfs.img" ||
    fail 'inactive candidate initramfs companion bytes drifted'
  cmp -s "$normal_before" "$root/boot/firmware/config.txt" ||
    fail 'inactive prepare changed normal boot config'
  cmp -s "$conventional_before" "$root/boot/firmware/config.txt" ||
    fail 'inactive prepare changed conventional normal boot pair'
  if test "${HP2R_FIXTURE_PRIOR_TRYBOOT:-}" = 1; then
    assert_file "$root/boot/firmware/tryboot.txt"
    grep -Fxq '# accepted prior one-shot configuration' \
      "$root/boot/firmware/tryboot.txt" ||
      fail 'inactive prepare changed the accepted prior tryboot config'
  else
    assert_absent "$root/boot/firmware/tryboot.txt"
  fi
  if test "${HP2R_FIXTURE_CASE:-}" = inactive-kernel-recovery-phase-one &&
    test "${HP2R_FIXTURE_RECOVERY_PHASE:-}" = prepared; then
    assert_inactive_recovered_prior false
    exit 0
  fi

  # Task 5 must stage the prepared inactive candidate through the public
  # controller while the fixture still reports the accepted, prior release.
  # The pre-Task-5 generic writer instead binds schema 4 state and its
  # running-kernel resolver, so this is intentionally RED until the target
  # stage branch becomes cross-kernel aware.
  : > "$log"
  accepted_pre_stage_sha="$(sha256sum "$state_dir/accepted-transition" | awk '{ print $1 }')"
  authorization_tuple_shape="${HP2R_FIXTURE_AUTHORIZATION_TUPLE_SHAPE:-none}"
  if test "$authorization_tuple_shape" != none; then
    authorization_stage_output="$fixture/inactive-authorization-tuple-stage.out"
    if test "$authorization_tuple_shape" = valid; then
      run_inactive_stage >"$authorization_stage_output" 2>&1 || {
        cat "$authorization_stage_output" >&2
        fail 'inactive stage rejected a valid raw 11-field authorization tuple'
      }
      grep -Fxq 'valid	11' "$root/tmp/authorization-tuple-shape" ||
        fail 'valid inactive authorization fixture did not emit exactly 11 raw fields'
      assert_file "$state_dir/tryboot-state"
      grep -Fxq 'phase=staged' "$state_dir/accepted-transition" ||
        fail 'valid inactive authorization tuple did not stage the candidate'
      exit 0
    fi
    if run_inactive_stage >"$authorization_stage_output" 2>&1; then
      fail "inactive stage accepted malformed raw authorization tuple: $authorization_tuple_shape"
    fi
    assert_file "$root/tmp/authorization-tuple-shape"
    grep -Fxq "$authorization_tuple_shape"$'\t''12' \
      "$root/tmp/authorization-tuple-shape" ||
      fail "malformed authorization fixture did not emit 12 raw fields: $authorization_tuple_shape"
    grep -Fxq 'inactive stage authorization has an unsafe tuple shape' \
      "$authorization_stage_output" ||
      fail "malformed authorization tuple missed raw shape validation: $authorization_tuple_shape"
    test ! -e "$log" || ! grep -q '^scp ' "$log" ||
      fail "malformed raw authorization tuple reached payload upload: $authorization_tuple_shape"
    test "$(sha256sum "$state_dir/accepted-transition" | awk '{ print $1 }')" = \
      "$accepted_pre_stage_sha" ||
      fail "malformed raw authorization tuple changed accepted authority: $authorization_tuple_shape"
    grep -Fxq 'phase=prepared' "$state_dir/accepted-transition" ||
      fail "malformed raw authorization tuple advanced accepted phase: $authorization_tuple_shape"
    assert_absent "$state_dir/tryboot-state"
    assert_absent "$root/boot/firmware/tryboot.txt"
    assert_absent "$root/boot/firmware/$kernel_name"
    assert_absent "$root/boot/firmware/$initramfs_name"
    assert_no_private_workspaces
    exit 0
  fi
  if test "${HP2R_FIXTURE_LEGACY_ACCEPTED:-}" = 1; then
    legacy_backlight_drift="${HP2R_FIXTURE_LEGACY_BACKLIGHT_DRIFT:-none}"
    legacy_post_auth_backlight_drift="${HP2R_FIXTURE_LEGACY_POST_AUTH_BACKLIGHT_DRIFT:-none}"
    case "$legacy_backlight_initial" in
      present)
        grep -Fxq 'prior_backlight_rule_existed=true' "$state_dir/accepted-transition" ||
          fail 'inactive legacy prepare did not record ambient backlight presence'
        assert_file "$state_dir/accepted-prior-backlight-rule"
        test "$(stat -c '%U:%G:%a' "$state_dir/accepted-prior-backlight-rule")" = root:root:600 ||
          fail 'inactive legacy prepared backlight proof metadata drifted'
        cmp -s "$backlight_rule_path" "$state_dir/accepted-prior-backlight-rule" ||
          fail 'inactive legacy prepared backlight proof differs from live rule'
        ;;
      absent)
        grep -Fxq 'prior_backlight_rule_existed=false' "$state_dir/accepted-transition" ||
          fail 'inactive legacy prepare did not record ambient backlight absence'
        grep -Fxq 'prior_backlight_rule_sha256=none' "$state_dir/accepted-transition" ||
          fail 'inactive legacy prepare did not bind ambient backlight absence'
        assert_absent "$state_dir/accepted-prior-backlight-rule"
        assert_absent "$backlight_rule_path"
        ;;
    esac
    case "$legacy_backlight_drift" in
      none) ;;
      appearance)
        test "$legacy_backlight_initial" = absent || fail 'appearance drift requires absent setup'
        install -o root -g root -m 0644 \
          "$repo_root/dist/artifacts/$release/$backlight_rule_file" \
          "$backlight_rule_path"
        ;;
      removal)
        test "$legacy_backlight_initial" = present || fail 'removal drift requires present setup'
        rm -- "$backlight_rule_path"
        ;;
      symlink)
        rm -f -- "$backlight_rule_path"
        ln -s /etc/passwd "$backlight_rule_path"
        ;;
      hash) printf 'legacy live rule drift\n' >> "$backlight_rule_path" ;;
      mode) chmod 0600 "$backlight_rule_path" ;;
      proof) printf 'legacy proof drift\n' >> "$state_dir/accepted-prior-backlight-rule" ;;
      *) fail "unknown legacy backlight drift: $legacy_backlight_drift" ;;
    esac
    legacy_live_before="$fixture/legacy-live-before-stage"
    legacy_proof_before="$fixture/legacy-proof-before-stage"
    legacy_transition_before="$fixture/legacy-transition-before-stage"
    capture_inactive_path "$backlight_rule_path" "$legacy_live_before"
    capture_inactive_path "$state_dir/accepted-prior-backlight-rule" "$legacy_proof_before"
    cp "$state_dir/accepted-transition" "$legacy_transition_before"
    legacy_stage_output="$fixture/legacy-inactive-stage.out"
    if test "$legacy_post_auth_backlight_drift" != none; then
      if run_inactive_stage >"$legacy_stage_output" 2>&1; then
        fail "inactive legacy stage accepted post-authorization backlight drift: $legacy_post_auth_backlight_drift"
      fi
      assert_file "$root/tmp/legacy-backlight-mutated-after-authorization"
      if test "${HP2R_FIXTURE_FORGE_STAGE_BACKLIGHT_AUTHORITY:-}" = 1; then
        assert_file "$root/tmp/stage-backlight-authority-forged"
      fi
      cmp -s "$legacy_transition_before" "$state_dir/accepted-transition" ||
        fail "rejected post-authorization legacy $legacy_post_auth_backlight_drift drift changed accepted authority"
      grep -Fxq 'phase=prepared' "$state_dir/accepted-transition" ||
        fail "post-authorization legacy $legacy_post_auth_backlight_drift drift advanced accepted phase"
      case "$legacy_post_auth_backlight_drift" in
        appearance)
          assert_file "$backlight_rule_path"
          test "$(stat -c '%U:%G:%a' "$backlight_rule_path")" = root:root:644 ||
            fail 'rejected post-authorization appearance did not preserve the new live rule'
          ;;
        removal) assert_absent "$backlight_rule_path" ;;
        symlink)
          test -L "$backlight_rule_path" &&
            test "$(readlink "$backlight_rule_path")" = /etc/passwd ||
            fail 'rejected post-authorization symlink did not preserve the live rule shape'
          ;;
        hash)
          grep -Fxq 'legacy live rule post-authorization drift' "$backlight_rule_path" ||
            fail 'rejected post-authorization hash drift did not preserve the live rule'
          ;;
        mode)
          test "$(stat -c '%U:%G:%a' "$backlight_rule_path")" = root:root:600 ||
            fail 'rejected post-authorization mode drift did not preserve the live rule'
          ;;
        proof)
          grep -Fxq 'legacy proof post-authorization drift' \
            "$state_dir/accepted-prior-backlight-rule" ||
            fail 'rejected post-authorization proof drift did not preserve the proof mutation'
          ;;
      esac
      cmp -s "$normal_before" "$root/boot/firmware/config.txt" ||
        fail "rejected post-authorization legacy $legacy_post_auth_backlight_drift drift changed normal config"
      assert_absent "$state_dir/tryboot-state"
      assert_absent "$root/boot/firmware/tryboot.txt"
      assert_absent "$root/boot/firmware/$kernel_name"
      assert_absent "$root/boot/firmware/$initramfs_name"
      assert_absent "$root/lib/modules/$candidate_release/extra/hyperpixel2r_kms.ko"
      assert_no_private_workspaces
      exit 0
    fi
    if test "$legacy_backlight_drift" != none; then
      if run_inactive_stage >"$legacy_stage_output" 2>&1; then
        fail "inactive legacy stage accepted backlight drift: $legacy_backlight_drift"
      fi
      cmp -s "$legacy_transition_before" "$state_dir/accepted-transition" ||
        fail "rejected legacy $legacy_backlight_drift drift changed accepted authority"
      grep -Fxq 'phase=prepared' "$state_dir/accepted-transition" ||
        fail "rejected legacy $legacy_backlight_drift drift advanced accepted phase"
      assert_inactive_path_preserved "$backlight_rule_path" "$legacy_live_before" \
        "legacy $legacy_backlight_drift live backlight rule"
      assert_inactive_path_preserved "$state_dir/accepted-prior-backlight-rule" \
        "$legacy_proof_before" "legacy $legacy_backlight_drift backlight proof"
      cmp -s "$normal_before" "$root/boot/firmware/config.txt" ||
        fail "rejected legacy $legacy_backlight_drift drift changed normal config"
      assert_absent "$state_dir/tryboot-state"
      assert_absent "$root/boot/firmware/tryboot.txt"
      assert_absent "$root/boot/firmware/$kernel_name"
      assert_absent "$root/boot/firmware/$initramfs_name"
      assert_absent "$root/lib/modules/$candidate_release/extra/hyperpixel2r_kms.ko"
      assert_no_private_workspaces
      exit 0
    fi
    if ! run_inactive_stage >"$legacy_stage_output" 2>&1; then
      cmp -s "$legacy_transition_before" "$state_dir/accepted-transition" ||
        fail 'rejected exact legacy backlight proof changed accepted authority'
      grep -Fxq 'phase=prepared' "$state_dir/accepted-transition" ||
        fail 'rejected exact legacy backlight proof advanced accepted phase'
      assert_inactive_path_preserved "$backlight_rule_path" "$legacy_live_before" \
        'exact legacy live backlight rule'
      assert_inactive_path_preserved "$state_dir/accepted-prior-backlight-rule" \
        "$legacy_proof_before" 'exact legacy backlight proof'
      cmp -s "$normal_before" "$root/boot/firmware/config.txt" ||
        fail 'rejected exact legacy backlight proof changed normal config'
      assert_absent "$state_dir/tryboot-state"
      assert_absent "$root/boot/firmware/tryboot.txt"
      assert_absent "$root/boot/firmware/$kernel_name"
      assert_absent "$root/boot/firmware/$initramfs_name"
      assert_absent "$root/lib/modules/$candidate_release/extra/hyperpixel2r_kms.ko"
      assert_no_private_workspaces
      cat "$legacy_stage_output" >&2
      fail "inactive stage rejected exact schema-2 accepted backlight proof: $legacy_backlight_initial"
    fi
    legacy_stage_completed=true
  fi
  if test "${HP2R_FIXTURE_CASE:-}" = inactive-kernel-state-digest; then
    if run_inactive_stage >/dev/null 2>&1; then
      fail 'inactive stage accepted an authority changed after controller authorization'
    fi
    cmp -s "$normal_before" "$root/boot/firmware/config.txt" ||
      fail 'digest-rejected inactive stage changed normal config'
    assert_absent "$root/var/lib/hyperpixel2r-kms/tryboot-state"
    assert_absent "$root/boot/firmware/tryboot.txt"
    assert_absent "$root/boot/firmware/$kernel_name"
    assert_absent "$root/boot/firmware/$initramfs_name"
    exit 0
  fi
  if test "${HP2R_FIXTURE_CASE:-}" = inactive-kernel-phase-authority-drift; then
    if HP2R_FIXTURE_MUTATE_ACCEPTED_ON_STATE_PUBLISH=1 run_inactive_stage >/dev/null 2>&1; then
      fail 'inactive stage advanced a journal mutated after schema-5 publication'
    fi
    assert_file "$root/tmp/accepted-authority-mutated-on-state-publish"
    grep -Fxq 'phase=prepared' "$state_dir/accepted-transition" ||
      fail 'mutated inactive authority advanced past prepared phase'
    assert_absent "$root/var/lib/hyperpixel2r-kms/tryboot-state"
    assert_absent "$root/boot/firmware/tryboot.txt"
    assert_absent "$root/boot/firmware/$kernel_name"
    assert_absent "$root/boot/firmware/$initramfs_name"
    exit 0
  fi
  if test "${HP2R_FIXTURE_CASE:-}" = inactive-kernel-final-module-drift; then
    if HP2R_FIXTURE_MUTATE_MODULE_ON_STATE_PUBLISH=1 run_inactive_stage >/dev/null 2>&1; then
      fail 'inactive stage accepted a module mutated in the final window'
    fi
    assert_file "$root/tmp/module-mutated-on-state-publish"
    grep -Fxq 'phase=prepared' "$state_dir/accepted-transition" ||
      fail 'late module drift advanced the accepted phase'
    assert_absent "$root/var/lib/hyperpixel2r-kms/tryboot-state"
    assert_absent "$root/boot/firmware/tryboot.txt"
    assert_absent "$root/boot/firmware/$kernel_name"
    assert_absent "$root/boot/firmware/$initramfs_name"
    exit 0
  fi
  if test "${HP2R_FIXTURE_CASE:-}" = inactive-kernel-final-artifact-drift; then
    if HP2R_FIXTURE_MUTATE_ARTIFACT_ON_STATE_PUBLISH=1 run_inactive_stage >/dev/null 2>&1; then
      fail 'inactive stage accepted an artifact mutated in the final window'
    fi
    assert_file "$root/tmp/artifact-mutated-on-state-publish"
    grep -Fxq 'phase=prepared' "$state_dir/accepted-transition" ||
      fail 'late artifact drift advanced the accepted phase'
    assert_absent "$root/var/lib/hyperpixel2r-kms/tryboot-state"
    assert_absent "$root/boot/firmware/tryboot.txt"
    assert_absent "$root/boot/firmware/$kernel_name"
    assert_absent "$root/boot/firmware/$initramfs_name"
    exit 0
  fi
  if test "${HP2R_FIXTURE_CASE:-}" = inactive-kernel-final-dkms-drift; then
    if HP2R_FIXTURE_MUTATE_DKMS_ON_STATE_PUBLISH=1 run_inactive_stage >/dev/null 2>&1; then
      fail 'inactive stage accepted live candidate DKMS drift in the final window'
    fi
    assert_file "$root/tmp/dkms-mutated-on-state-publish" ||
      fail 'DKMS final-window mutation hook did not run'
    grep -Fxq 'phase=prepared' "$state_dir/accepted-transition" ||
      fail 'late DKMS drift advanced the accepted phase'
    assert_absent "$root/var/lib/hyperpixel2r-kms/tryboot-state"
    assert_absent "$root/boot/firmware/tryboot.txt"
    exit 0
  fi
  if test "${HP2R_FIXTURE_CASE:-}" = inactive-kernel-setter-snapshot; then
    HP2R_FIXTURE_MUTATE_SETTER_AUTHORITY=1 run_inactive_stage >/dev/null ||
      fail 'setter snapshot mutation rejected an otherwise authorized stage'
    assert_file "$root/tmp/setter-authority-mutated"
    grep -Fxq 'target_identity_sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
      "$state_dir/accepted-transition" || fail 'phase setter consumed mutated live authority'
    grep -Fxq 'phase=staged' "$state_dir/accepted-transition" ||
      fail 'setter snapshot did not publish staged authority'
    exit 0
  fi
  if test "${HP2R_FIXTURE_CASE:-}" = inactive-kernel-post-phase-failure; then
    if HP2R_FIXTURE_FAIL_AFTER_STAGED_PUBLICATION=1 run_inactive_stage >/dev/null 2>&1; then
      fail 'post-phase fixture did not fail after staged publication'
    fi
    grep -Fxq 'phase=staged' "$state_dir/accepted-transition" ||
      fail 'post-phase failure did not retain staged authority'
    assert_file "$state_dir/tryboot-state"
    assert_file "$root/boot/firmware/tryboot.txt"
    assert_file "$root/boot/firmware/$kernel_name"
    assert_file "$root/boot/firmware/$initramfs_name"
    exit 0
  fi
  if test "${HP2R_FIXTURE_CASE:-}" = inactive-kernel-foreign-firmware; then
    printf 'foreign inactive firmware leaf\n' > "$root/boot/firmware/$kernel_name"
    chmod 0644 "$root/boot/firmware/$kernel_name"
    cp "$root/boot/firmware/$kernel_name" "$fixture/foreign-inactive-kernel"
    if run_inactive_stage >/dev/null 2>&1; then
      fail 'inactive stage accepted a foreign candidate firmware leaf'
    fi
    cmp -s "$fixture/foreign-inactive-kernel" "$root/boot/firmware/$kernel_name" ||
      fail 'foreign candidate firmware leaf was changed during rejection'
    assert_absent "$root/var/lib/hyperpixel2r-kms/tryboot-state"
    assert_absent "$root/boot/firmware/tryboot.txt"
    assert_absent "$root/boot/firmware/$initramfs_name"
    exit 0
  fi
  if [[ "${HP2R_FIXTURE_INTERRUPT_AFTER:-}" == candidate-* ]]; then
    if run_inactive_stage >/dev/null 2>&1; then
      fail "inactive stage ignored interruption after $HP2R_FIXTURE_INTERRUPT_AFTER"
    fi
    if test "$HP2R_FIXTURE_INTERRUPT_AFTER" = candidate-staged-published; then
      grep -Fxq 'phase=staged' "$state_dir/accepted-transition" ||
        fail 'post-phase interruption did not retain a staged journal'
      assert_file "$root/var/lib/hyperpixel2r-kms/tryboot-state"
      assert_file "$root/boot/firmware/tryboot.txt"
      assert_file "$root/boot/firmware/$kernel_name"
      assert_file "$root/boot/firmware/$initramfs_name"
      exit 0
    fi
    cmp -s "$normal_before" "$root/boot/firmware/config.txt" ||
      fail "inactive interruption changed normal config: $HP2R_FIXTURE_INTERRUPT_AFTER"
    assert_absent "$root/var/lib/hyperpixel2r-kms/tryboot-state"
    assert_absent "$root/boot/firmware/tryboot.txt"
    assert_absent "$root/boot/firmware/$kernel_name"
    assert_absent "$root/boot/firmware/$initramfs_name"
    exit 0
  fi
  if ! "$legacy_stage_completed"; then run_inactive_stage; fi
  grep -Fxq 'schema_version=5' "$state_dir/tryboot-state" ||
    fail 'inactive stage did not publish schema-5 generic state'
  grep -Fxq 'boot_transition=inactive-kernel' "$state_dir/tryboot-state" ||
    fail 'inactive stage did not bind its inactive boot transition'
  grep -Fxq "candidate_kernel_file=$kernel_name" "$state_dir/tryboot-state" ||
    fail 'inactive stage did not bind candidate kernel firmware name'
  grep -Fxq "candidate_initramfs_file=$initramfs_name" "$state_dir/tryboot-state" ||
    fail 'inactive stage did not bind candidate initramfs firmware name'
  grep -Fxq "accepted_transition_sha256=$accepted_pre_stage_sha" \
    "$state_dir/tryboot-state" || fail 'inactive stage did not bind accepted authority digest'
  cmp -s "$root$candidate_kernel" "$root/boot/firmware/$kernel_name" ||
    fail 'inactive stage did not publish exact candidate kernel firmware leaf'
  cmp -s "$root$candidate_initramfs" "$root/boot/firmware/$initramfs_name" ||
    fail 'inactive stage did not publish exact candidate initramfs firmware leaf'
  assert_file "$root/lib/modules/$candidate_release/extra/hyperpixel2r_kms.ko"
  cmp -s "$candidate_artifact/hyperpixel2r_kms.ko" \
    "$root/lib/modules/$candidate_release/extra/hyperpixel2r_kms.ko" ||
    fail 'inactive stage did not install the candidate module in its release tree'
  assert_file "$root/boot/firmware/overlays/$overlay_file"
  assert_file "$root/etc/udev/rules.d/$backlight_rule_file"
  assert_file "$root/usr/src/hyperpixel2r-kms-$candidate_driver_version/dkms.conf"
  grep -Fxq "depmod -a $candidate_release" "$log" ||
    fail 'inactive stage did not run depmod for the candidate release'
  grep -Fxq "modinfo -k $candidate_release -F none hyperpixel2r_kms" "$log" ||
    fail 'inactive stage did not prove the candidate module path explicitly'
  grep -Fxq "modinfo -k $candidate_release -F vermagic hyperpixel2r_kms" "$log" ||
    fail 'inactive stage did not prove the candidate module vermagic explicitly'
  test "$(tail -n 4 "$root/boot/firmware/tryboot.txt")" = "$(printf '%s\n' \
    '# hyperpixel2r-kms one-shot inactive-kernel candidate' \
    "kernel=$kernel_name" \
    "initramfs $initramfs_name followkernel" \
    "dtoverlay=$overlay_file")" ||
    fail 'inactive stage tryboot tail is not the exact four-line candidate selection'
  ! grep -Fq '$' "$root/boot/firmware/tryboot.txt" ||
    fail 'inactive stage wrote a literal shell variable into tryboot config'
  cmp -s "$normal_before" "$root/boot/firmware/config.txt" ||
    fail 'inactive stage changed normal boot config'
  cmp -s "$conventional_before" "$root/boot/firmware/config.txt" ||
    fail 'inactive stage changed conventional normal config selection'
  cmp -s "$prior_kernel_before" "$root$prior_kernel" ||
    fail 'inactive stage changed conventional normal kernel'
  cmp -s "$prior_initramfs_before" "$root$prior_initramfs" ||
    fail 'inactive stage changed conventional normal initramfs'
  grep -Fxq "remote-uname uname -r" "$log" ||
    fail 'inactive stage did not record controller running-release evidence'
  ! grep -Fq "modinfo -k $release " "$log" ||
    fail 'inactive stage used running-kernel module resolution'
  ! grep -Fq 'module-load ' "$log" ||
    fail 'inactive stage loaded or probed a module'
  ! grep -Fq 'bind ' "$log" ||
    fail 'inactive stage bound a candidate device during staging'
  if test "${HP2R_FIXTURE_CASE:-}" = inactive-kernel-recovery-phase-one; then
    local recovery_phase="${HP2R_FIXTURE_RECOVERY_PHASE:-}" recovery_boundary='' recovery_output
    case "$recovery_phase" in
      staged)
        assert_inactive_recovered_prior false
        exit 0
        ;;
      explicit_normal_published|explicit_normal_verified|canonical_initramfs_published|canonical_pair_published|normalized_config_published|normalized_verified|finalizing|receipt_published) ;;
      *) fail "unknown inactive recovery phase: $recovery_phase" ;;
    esac
    mkdir -p "$root/proc/device-tree/chosen/bootloader"
    printf '\0\0\0\1' > "$root/proc/device-tree/chosen/bootloader/tryboot"
    install_live_hardware
    export HP2R_FIXTURE_RELEASE_OVERRIDE="$candidate_release"
    run_controller commit-boot.sh >/dev/null
    if test "$recovery_phase" = explicit_normal_published; then
      assert_inactive_recovered_prior true
      unset HP2R_FIXTURE_RELEASE_OVERRIDE
      exit 0
    fi
    printf '\0\0\0\0' > "$root/proc/device-tree/chosen/bootloader/tryboot"
    run_controller accepted-lifecycle.sh --action mark-explicit-normal-verified >/dev/null
    if test "$recovery_phase" = explicit_normal_verified; then
      assert_inactive_recovered_prior true
      unset HP2R_FIXTURE_RELEASE_OVERRIDE
      exit 0
    fi
    case "$recovery_phase" in
      canonical_initramfs_published) recovery_boundary=inactive-normalize-initramfs-published ;;
      canonical_pair_published) recovery_boundary=inactive-normalize-pair-published ;;
      normalized_config_published) recovery_boundary=inactive-normalize-config-published ;;
      finalizing|receipt_published) ;;
    esac
    if test -n "$recovery_boundary"; then
      if HP2R_FIXTURE_INTERRUPT_AFTER="$recovery_boundary" \
        HP2R_FIXTURE_PRESERVE_MUTATIONS=1 \
        run_controller accepted-lifecycle.sh --action normalize-inactive-kernel >/dev/null 2>&1; then
        fail "normalization ignored recovery-phase interruption: $recovery_phase"
      fi
      find "$state_dir" -mindepth 1 -maxdepth 1 -type d \
        -name '.hp2r-transaction.*' -exec rm -rf -- {} +
      assert_inactive_recovered_prior true
      unset HP2R_FIXTURE_RELEASE_OVERRIDE
      exit 0
    fi
    run_controller accepted-lifecycle.sh --action normalize-inactive-kernel >/dev/null
    run_controller accepted-lifecycle.sh --action mark-normalized-verified >/dev/null
    if test "$recovery_phase" = normalized_verified; then
      assert_inactive_recovered_prior true
      unset HP2R_FIXTURE_RELEASE_OVERRIDE
      exit 0
    fi
    case "$recovery_phase" in
      finalizing) recovery_boundary=accepted-finalizing-published ;;
      receipt_published) recovery_boundary=accepted-receipt-phase-published ;;
    esac
    if HP2R_FIXTURE_INTERRUPT_AFTER="$recovery_boundary" \
      run_controller accepted-lifecycle.sh --action finalize >/dev/null 2>&1; then
      fail "finalization ignored recovery-phase interruption: $recovery_phase"
    fi
    if test "$recovery_phase" = finalizing; then
      assert_inactive_recovered_prior true
    else
      assert_inactive_recovered_prior false candidate
    fi
    unset HP2R_FIXTURE_RELEASE_OVERRIDE
    exit 0
  fi
  if test "${HP2R_FIXTURE_CASE:-}" = inactive-kernel-stale-authority; then
    replace_equals_value "$state_dir/accepted-transition" target_identity_sha256 \
      dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
    if run_accepted_remote identity >/dev/null 2>&1; then
      fail 'schema-5 identity accepted stale staged authority'
    fi
    if run_controller commit-boot.sh >/dev/null 2>&1; then
      fail 'schema-5 commit accepted stale staged authority'
    fi
    if run_controller rollback-boot.sh >/dev/null 2>&1; then
      fail 'schema-5 rollback accepted stale staged authority'
    fi
    exit 0
  fi
  if test "${HP2R_FIXTURE_CASE:-}" = inactive-kernel-hostile-env; then
    replace_equals_value "$state_dir/accepted-transition" target_identity_sha256 \
      dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
    if schema5_staged_authority_asserting=true schema5_staged_authority_allow_prepared=true \
      run_accepted_remote identity >/dev/null 2>&1; then
      fail 'preseeded schema5 guards bypassed stale identity rejection'
    fi
    if schema5_staged_authority_asserting=true schema5_staged_authority_allow_prepared=true \
      run_controller commit-boot.sh >/dev/null 2>&1; then
      fail 'preseeded schema5 guards bypassed stale commit rejection'
    fi
    if schema5_staged_authority_asserting=true schema5_staged_authority_allow_prepared=true \
      run_controller rollback-boot.sh >/dev/null 2>&1; then
      fail 'preseeded schema5 guards bypassed stale rollback rejection'
    fi
    exit 0
  fi
  if test "${HP2R_FIXTURE_CASE:-}" = inactive-kernel-commit-rejected; then
    cp "$root/boot/firmware/config.txt" "$fixture/commit-normal-before"
    cp "$root/boot/firmware/tryboot.txt" "$fixture/commit-tryboot-before"
    cp "$state_dir/tryboot-state" "$fixture/commit-state-before"
    cp "$state_dir/accepted-transition" "$fixture/commit-journal-before"
    cp "$root/boot/firmware/$kernel_name" "$fixture/commit-kernel-before"
    cp "$root/boot/firmware/$initramfs_name" "$fixture/commit-initramfs-before"
    if run_controller commit-boot.sh >/dev/null 2>&1; then
      fail 'generic commit promoted an inactive schema-5 transaction'
    fi
    for pair in \
      "$root/boot/firmware/config.txt:$fixture/commit-normal-before" \
      "$root/boot/firmware/tryboot.txt:$fixture/commit-tryboot-before" \
      "$state_dir/tryboot-state:$fixture/commit-state-before" \
      "$state_dir/accepted-transition:$fixture/commit-journal-before" \
      "$root/boot/firmware/$kernel_name:$fixture/commit-kernel-before" \
      "$root/boot/firmware/$initramfs_name:$fixture/commit-initramfs-before"
    do
      cmp -s "${pair%%:*}" "${pair#*:}" || fail 'rejected inactive commit changed durable state'
    done
    exit 0
  fi
  if test "${HP2R_FIXTURE_CASE:-}" = commit-readiness-expiry ||
    test "${HP2R_FIXTURE_CASE:-}" = commit-intent-tuple-drift ||
    test "${HP2R_FIXTURE_CASE:-}" = commit-boot-id-drift; then
    mkdir -p "$root/proc/device-tree/chosen/bootloader"
    printf '\0\0\0\1' > "$root/proc/device-tree/chosen/bootloader/tryboot"
    install_live_hardware
    cp "$root/boot/firmware/config.txt" "$fixture/readiness-normal-before"
    cp "$root/boot/firmware/tryboot.txt" "$fixture/readiness-tryboot-before"
    cp "$state_dir/tryboot-state" "$fixture/readiness-state-before"
    cp "$state_dir/accepted-transition" "$fixture/readiness-transition-before"
    export HP2R_FIXTURE_RELEASE_OVERRIDE="$candidate_release"
    if test "${HP2R_FIXTURE_CASE:-}" = commit-readiness-expiry; then
      if ! HP2R_FIXTURE_EXPIRE_READINESS_AFTER_COMMIT_PROBE=1 \
        run_controller commit-boot.sh >"$fixture/readiness-commit.out" 2>&1; then
        cat "$fixture/readiness-commit.out" >&2
        fail 'readiness-ordered promotion failed'
      fi
      unset HP2R_FIXTURE_RELEASE_OVERRIDE
      assert_file "$root/tmp/readiness-expired-after-commit-probe"
      grep -Fxq 'phase=explicit_normal_published' "$state_dir/accepted-transition" ||
        fail 'readiness-ordered commit did not publish explicit normal phase'
      assert_absent "$state_dir/tryboot-state"
      assert_absent "$root/boot/firmware/tryboot.txt"
      exit 0
    fi
    if test "${HP2R_FIXTURE_CASE:-}" = commit-intent-tuple-drift; then
      if HP2R_FIXTURE_MUTATE_COMMIT_PROBE_TUPLE=1 \
        run_controller commit-boot.sh >"$fixture/readiness-commit.out" 2>&1; then
        fail 'commit accepted authoritative tuple drift after live verification'
      fi
    else
      if HP2R_FIXTURE_CHANGE_BOOT_ID_AFTER_READINESS=1 \
        run_controller commit-boot.sh >"$fixture/readiness-commit.out" 2>&1; then
        fail 'commit accepted a changed boot identity after live verification'
      fi
    fi
    grep -Fq 'target commit intent changed after live verification' \
      "$fixture/readiness-commit.out" || {
      cat "$fixture/readiness-commit.out" >&2
      fail 'commit identity drift failed for an unexpected reason'
    }
    ! grep -Fxq 'remote-action commit' "$log" ||
      fail 'commit identity drift reached remote mutation'
    cmp -s "$fixture/readiness-normal-before" "$root/boot/firmware/config.txt" ||
      fail 'commit identity drift changed normal config'
    cmp -s "$fixture/readiness-tryboot-before" "$root/boot/firmware/tryboot.txt" ||
      fail 'commit identity drift changed tryboot config'
    cmp -s "$fixture/readiness-state-before" "$state_dir/tryboot-state" ||
      fail 'commit identity drift changed generic state'
    cmp -s "$fixture/readiness-transition-before" "$state_dir/accepted-transition" ||
      fail 'commit identity drift changed accepted transition'
    unset HP2R_FIXTURE_RELEASE_OVERRIDE
    exit 0
  fi
  # A successful cross-kernel promotion must retain the conventional pair as
  # fallback while normal firmware selects the complete candidate-only pair.
  # This catches the old generic commit branch, which derives an overlay-only
  # normal config and therefore cannot safely select an inactive kernel.
  if test "${HP2R_FIXTURE_CASE:-}" = inactive-kernel-explicit-promotion; then
    mkdir -p "$root/proc/device-tree/chosen/bootloader"
    printf '\0\0\0\1' > "$root/proc/device-tree/chosen/bootloader/tryboot"
    install_live_hardware
    export HP2R_FIXTURE_RELEASE_OVERRIDE="$candidate_release"
    run_controller commit-boot.sh >/dev/null
    unset HP2R_FIXTURE_RELEASE_OVERRIDE
    grep -Fxq 'phase=explicit_normal_published' "$state_dir/accepted-transition" ||
      fail 'inactive commit did not publish the explicit normal phase'
    test "$(tail -n 4 "$root/boot/firmware/config.txt")" = "$(printf '%s\n' \
      '# hyperpixel2r-kms one-shot inactive-kernel candidate' \
      "kernel=$kernel_name" \
      "initramfs $initramfs_name followkernel" \
      "dtoverlay=$overlay_file")" ||
      fail 'inactive commit did not select the complete explicit candidate pair'
    cmp -s "$prior_kernel_before" "$root$prior_kernel" ||
      fail 'inactive commit changed the conventional prior kernel'
    cmp -s "$prior_initramfs_before" "$root$prior_initramfs" ||
      fail 'inactive commit changed the conventional prior initramfs'
    assert_absent "$state_dir/tryboot-state"
    assert_absent "$root/boot/firmware/tryboot.txt"
    assert_file "$root/boot/firmware/$kernel_name"
    assert_file "$root/boot/firmware/$initramfs_name"
    exit 0
  fi
  if test "${HP2R_FIXTURE_CASE:-}" = inactive-kernel-explicit-normal-verified; then
    # First commit the healthy tryboot into the explicit candidate selection.
    mkdir -p "$root/proc/device-tree/chosen/bootloader"
    printf '\0\0\0\1' > "$root/proc/device-tree/chosen/bootloader/tryboot"
    install_live_hardware
    export HP2R_FIXTURE_RELEASE_OVERRIDE="$candidate_release"
    run_controller commit-boot.sh >/dev/null
    # The next boot is normal, but still selects the candidate-only pair.
    printf '\0\0\0\0' > "$root/proc/device-tree/chosen/bootloader/tryboot"
    run_controller accepted-lifecycle.sh --action mark-explicit-normal-verified >/dev/null
    grep -Fxq 'phase=explicit_normal_verified' "$state_dir/accepted-transition" ||
      fail 'explicit normal verifier did not publish its typed phase'
    cmp -s "$prior_kernel_before" "$root$prior_kernel" ||
      fail 'explicit normal verifier changed the conventional prior kernel'
    cmp -s "$prior_initramfs_before" "$root$prior_initramfs" ||
      fail 'explicit normal verifier changed the conventional prior initramfs'
    unset HP2R_FIXTURE_RELEASE_OVERRIDE
    exit 0
  fi
  if test "${HP2R_FIXTURE_CASE:-}" = inactive-kernel-explicit-normal-unhealthy; then
    mkdir -p "$root/proc/device-tree/chosen/bootloader"
    printf '\0\0\0\1' > "$root/proc/device-tree/chosen/bootloader/tryboot"
    install_live_hardware
    export HP2R_FIXTURE_RELEASE_OVERRIDE="$candidate_release"
    run_controller commit-boot.sh >/dev/null
    printf '\0\0\0\0' > "$root/proc/device-tree/chosen/bootloader/tryboot"
    rm -f "$root/sys/module/hyperpixel2r_kms/version"
    if run_controller accepted-lifecycle.sh --action mark-explicit-normal-verified >/dev/null 2>&1; then
      fail 'explicit normal verifier accepted unhealthy live hardware'
    fi
    grep -Fxq 'phase=explicit_normal_published' "$state_dir/accepted-transition" ||
      fail 'unhealthy explicit normal verification advanced lifecycle authority'
    unset HP2R_FIXTURE_RELEASE_OVERRIDE
    exit 0
  fi
  if test "${HP2R_FIXTURE_CASE:-}" = inactive-kernel-explicit-normal-conventional-drift; then
    mkdir -p "$root/proc/device-tree/chosen/bootloader"
    printf '\0\0\0\1' > "$root/proc/device-tree/chosen/bootloader/tryboot"
    install_live_hardware
    export HP2R_FIXTURE_RELEASE_OVERRIDE="$candidate_release"
    run_controller commit-boot.sh >/dev/null
    printf '\0\0\0\0' > "$root/proc/device-tree/chosen/bootloader/tryboot"
    printf 'hostile conventional kernel drift\n' >> "$root/boot/firmware/kernel8.img"
    cp "$root/boot/firmware/kernel8.img" "$fixture/explicit-conventional-drift-before"
    if run_controller accepted-lifecycle.sh --action mark-explicit-normal-verified >/dev/null 2>&1; then
      fail 'explicit normal verifier accepted conventional pair drift'
    fi
    grep -Fxq 'phase=explicit_normal_published' "$state_dir/accepted-transition" ||
      fail 'conventional pair drift advanced explicit normal phase'
    cmp -s "$fixture/explicit-conventional-drift-before" "$root/boot/firmware/kernel8.img" ||
      fail 'rejected conventional pair drift was changed'
    assert_no_private_workspaces
    unset HP2R_FIXTURE_RELEASE_OVERRIDE
    exit 0
  fi
  if test "${HP2R_FIXTURE_CASE:-}" = inactive-kernel-explicit-normal-vermagic-prefix; then
    mkdir -p "$root/proc/device-tree/chosen/bootloader"
    printf '\0\0\0\1' > "$root/proc/device-tree/chosen/bootloader/tryboot"
    install_live_hardware
    export HP2R_FIXTURE_RELEASE_OVERRIDE="$candidate_release"
    run_controller commit-boot.sh >/dev/null
    printf '\0\0\0\0' > "$root/proc/device-tree/chosen/bootloader/tryboot"
    export HP2R_FIXTURE_VERMAGIC_PREFIX_EVIL=1
    if run_controller accepted-lifecycle.sh --action mark-explicit-normal-verified >/dev/null 2>&1; then
      fail 'explicit normal verifier accepted a release-prefix vermagic collision'
    fi
    unset HP2R_FIXTURE_VERMAGIC_PREFIX_EVIL
    grep -Fxq 'phase=explicit_normal_published' "$state_dir/accepted-transition" ||
      fail 'release-prefix vermagic collision advanced explicit normal phase'
    assert_no_private_workspaces
    unset HP2R_FIXTURE_RELEASE_OVERRIDE
    exit 0
  fi
  if test "${HP2R_FIXTURE_CASE:-}" = inactive-kernel-explicit-normal-module-resolution-drift; then
    mkdir -p "$root/proc/device-tree/chosen/bootloader"
    printf '\0\0\0\1' > "$root/proc/device-tree/chosen/bootloader/tryboot"
    install_live_hardware
    export HP2R_FIXTURE_RELEASE_OVERRIDE="$candidate_release"
    run_controller commit-boot.sh >/dev/null
    printf '\0\0\0\0' > "$root/proc/device-tree/chosen/bootloader/tryboot"
    mkdir -p "$root/lib/modules/$candidate_release/updates/dkms"
    printf 'stale same-version resolved module\n' > \
      "$root/lib/modules/$candidate_release/updates/dkms/hyperpixel2r_kms.ko"
    printf 'hyperpixel2r_kms.ko: updates/dkms/hyperpixel2r_kms.ko\n' > \
      "$root/lib/modules/$candidate_release/modules.dep"
    if run_controller accepted-lifecycle.sh --action mark-explicit-normal-verified >/dev/null 2>&1; then
      fail 'explicit normal verifier accepted stale same-version module resolution'
    fi
    grep -Fxq 'phase=explicit_normal_published' "$state_dir/accepted-transition" ||
      fail 'stale module resolution advanced explicit normal phase'
    assert_no_private_workspaces
    unset HP2R_FIXTURE_RELEASE_OVERRIDE
    exit 0
  fi
  if test "${HP2R_FIXTURE_CASE:-}" = inactive-kernel-normalized-module-resolution-drift; then
    cp "$root$prior_kernel" "$root/boot/firmware/kernel8.img"
    cp "$root$prior_initramfs" "$root/boot/firmware/initramfs8"
    chown root:root "$root/boot/firmware/kernel8.img" "$root/boot/firmware/initramfs8"
    chmod 0644 "$root/boot/firmware/kernel8.img" "$root/boot/firmware/initramfs8"
    mkdir -p "$root/proc/device-tree/chosen/bootloader"
    printf '\0\0\0\1' > "$root/proc/device-tree/chosen/bootloader/tryboot"
    install_live_hardware
    export HP2R_FIXTURE_RELEASE_OVERRIDE="$candidate_release"
    run_controller commit-boot.sh >/dev/null
    printf '\0\0\0\0' > "$root/proc/device-tree/chosen/bootloader/tryboot"
    run_controller accepted-lifecycle.sh --action mark-explicit-normal-verified >/dev/null
    run_controller accepted-lifecycle.sh --action normalize-inactive-kernel >/dev/null
    mkdir -p "$root/lib/modules/$candidate_release/updates/dkms"
    printf 'stale same-version resolved module\n' > \
      "$root/lib/modules/$candidate_release/updates/dkms/hyperpixel2r_kms.ko"
    printf 'hyperpixel2r_kms.ko: updates/dkms/hyperpixel2r_kms.ko\n' > \
      "$root/lib/modules/$candidate_release/modules.dep"
    if run_controller accepted-lifecycle.sh --action mark-normalized-verified >/dev/null 2>&1; then
      fail 'normalized verifier accepted stale same-version module resolution'
    fi
    grep -Fxq 'phase=normalized_config_published' "$state_dir/accepted-transition" ||
      fail 'stale module resolution advanced normalized phase'
    assert_no_private_workspaces
    unset HP2R_FIXTURE_RELEASE_OVERRIDE
    exit 0
  fi
  if test "${HP2R_FIXTURE_CASE:-}" = inactive-kernel-normalization; then
    cp "$root$prior_kernel" "$fixture/normalization-versioned-kernel-before"
    cp "$root$prior_initramfs" "$fixture/normalization-versioned-initramfs-before"
    cp "$root$prior_kernel" "$root/boot/firmware/kernel8.img"
    cp "$root$prior_initramfs" "$root/boot/firmware/initramfs8"
    chown root:root "$root/boot/firmware/kernel8.img" "$root/boot/firmware/initramfs8"
    chmod 0644 "$root/boot/firmware/kernel8.img" "$root/boot/firmware/initramfs8"
    mkdir -p "$root/proc/device-tree/chosen/bootloader"
    printf '\0\0\0\1' > "$root/proc/device-tree/chosen/bootloader/tryboot"
    install_live_hardware
    export HP2R_FIXTURE_RELEASE_OVERRIDE="$candidate_release"
    run_controller commit-boot.sh >/dev/null
    printf '\0\0\0\0' > "$root/proc/device-tree/chosen/bootloader/tryboot"
    cmp -s "$root$prior_kernel" "$root/boot/firmware/kernel8.img" ||
      fail 'explicit selection changed the conventional prior kernel'
    cmp -s "$root$prior_initramfs" "$root/boot/firmware/initramfs8" ||
      fail 'explicit selection changed the conventional prior initramfs'
    run_controller accepted-lifecycle.sh --action mark-explicit-normal-verified >/dev/null
    run_controller accepted-lifecycle.sh --action normalize-inactive-kernel >/dev/null
    grep -Fxq 'phase=normalized_config_published' "$state_dir/accepted-transition" ||
      fail 'inactive normalization did not publish normalized config phase'
    cmp -s "$root/boot/firmware/$kernel_name" "$root/boot/firmware/kernel8.img" ||
      fail 'inactive normalization did not publish the candidate conventional kernel'
    cmp -s "$root/boot/firmware/$initramfs_name" "$root/boot/firmware/initramfs8" ||
      fail 'inactive normalization did not publish the candidate conventional initramfs'
    cmp -s "$fixture/normalization-versioned-kernel-before" "$root$prior_kernel" ||
      fail 'inactive normalization changed the versioned kernel source'
    cmp -s "$fixture/normalization-versioned-initramfs-before" "$root$prior_initramfs" ||
      fail 'inactive normalization changed the versioned initramfs source'
    grep -Fxq 'auto_initramfs=1' "$root/boot/firmware/config.txt" ||
      fail 'inactive normalization did not publish auto initramfs config'
    if grep -Eq '^(kernel=|initramfs hp2r-)' "$root/boot/firmware/config.txt"; then
      fail 'inactive normalization left an explicit candidate boot override'
    fi
    run_controller accepted-lifecycle.sh --action mark-normalized-verified >/dev/null
    grep -Fxq 'phase=normalized_verified' "$state_dir/accepted-transition" ||
      fail 'normalized normal verifier did not publish its typed phase'
    unset HP2R_FIXTURE_RELEASE_OVERRIDE
    exit 0
  fi
  if test "${HP2R_FIXTURE_CASE:-}" = inactive-kernel-backlight-policy; then
    local brightness="$root/sys/class/backlight/planeradar-backlight/brightness"
    local brightness_before policy_error="$fixture/backlight-policy.err"

    prepare_inactive_normalized_verified_for_backlight_probe \
      "$prior_kernel" "$prior_initramfs" "$candidate_release"
    brightness_before="$(cat "$brightness")"
    export HP2R_FIXTURE_REJECT_SUDO_RUNAS=1
    export HP2R_FIXTURE_BACKLIGHT_DYNAMIC_IDS=1
    "$bin/sudo" true
    "$bin/sudo" setpriv --reuid=4241 --regid=4242 --clear-groups true
    rm -f "$root/tmp/backlight-root-setpriv-used"
    if "$bin/sudo" -u nobody -g video true \
      >"$fixture/backlight-policy.out" 2>"$policy_error"; then
      fail 'fixture sudo policy allowed a passwordless run-as command'
    fi
    grep -Fxq 'sudo: a password is required' "$policy_error" ||
      fail 'fixture sudo policy did not model the target run-as rejection'
    run_controller accepted-lifecycle.sh --action finalize >/dev/null
    assert_file "$root/tmp/backlight-root-setpriv-used"
    test "$(cat "$brightness")" = "$brightness_before" ||
      fail 'accepted finalizer changed brightness during its permission proof'
    grep -Fxq "source_revision=$source_revision" "$state_dir/accepted-state" ||
      fail 'accepted finalizer did not publish the exact candidate receipt'
    assert_absent "$state_dir/accepted-transition"
    unset HP2R_FIXTURE_REJECT_SUDO_RUNAS HP2R_FIXTURE_BACKLIGHT_DYNAMIC_IDS
    unset HP2R_FIXTURE_RELEASE_OVERRIDE
    exit 0
  fi
  if test "${HP2R_FIXTURE_CASE:-}" = inactive-kernel-backlight-hostiles; then
    local brightness="$root/sys/class/backlight/planeradar-backlight/brightness"
    local brightness_before receipt_before shape

    prepare_inactive_normalized_verified_for_backlight_probe \
      "$prior_kernel" "$prior_initramfs" "$candidate_release"
    brightness_before="$(cat "$brightness")"
    receipt_before="$(sha256sum "$state_dir/accepted-state" | awk '{ print $1 }')"
    export HP2R_FIXTURE_REJECT_SUDO_RUNAS=1
    for shape in \
      uid-missing uid-ambiguous uid-nonnumeric uid-zero uid-unsafe \
      gid-missing gid-ambiguous gid-nonnumeric gid-zero gid-unsafe \
      metadata-owner metadata-mode
    do
      export HP2R_FIXTURE_BACKLIGHT_IDENTITY_SHAPE="$shape"
      if run_controller accepted-lifecycle.sh --action finalize \
        >"$fixture/backlight-hostile-$shape.out" 2>&1; then
        fail "accepted finalizer trusted hostile backlight identity: $shape"
      fi
      grep -Fxq 'phase=normalized_verified' "$state_dir/accepted-transition" ||
        fail "backlight identity failure advanced finalization: $shape"
      test "$(sha256sum "$state_dir/accepted-state" | awk '{ print $1 }')" = \
        "$receipt_before" || fail "backlight identity failure changed receipt: $shape"
      test "$(cat "$brightness")" = "$brightness_before" ||
        fail "backlight identity failure changed brightness: $shape"
    done
    unset HP2R_FIXTURE_BACKLIGHT_IDENTITY_SHAPE
    export HP2R_FIXTURE_RETAIN_BACKLIGHT_PRIVILEGE=1
    if run_controller accepted-lifecycle.sh --action finalize \
      >"$fixture/backlight-hostile-retained-root.out" 2>&1; then
      fail 'accepted finalizer retained root during its backlight write proof'
    fi
    assert_file "$root/tmp/backlight-privilege-retained"
    grep -Fxq 'phase=normalized_verified' "$state_dir/accepted-transition" ||
      fail 'retained-root backlight probe advanced finalization'
    test "$(sha256sum "$state_dir/accepted-state" | awk '{ print $1 }')" = \
      "$receipt_before" || fail 'retained-root backlight probe changed receipt'
    test "$(cat "$brightness")" = "$brightness_before" ||
      fail 'retained-root backlight probe changed brightness'
    unset HP2R_FIXTURE_RETAIN_BACKLIGHT_PRIVILEGE HP2R_FIXTURE_REJECT_SUDO_RUNAS
    unset HP2R_FIXTURE_RELEASE_OVERRIDE
    exit 0
  fi
  if test "${HP2R_FIXTURE_CASE:-}" = inactive-kernel-backlight-capability; then
    local brightness="$root/sys/class/backlight/planeradar-backlight/brightness"
    local brightness_before receipt_before

    prepare_inactive_normalized_verified_for_backlight_probe \
      "$prior_kernel" "$prior_initramfs" "$candidate_release"
    brightness_before="$(cat "$brightness")"
    receipt_before="$(sha256sum "$state_dir/accepted-state" | awk '{ print $1 }')"
    export HP2R_FIXTURE_REJECT_SUDO_RUNAS=1
    export HP2R_FIXTURE_RETAIN_BACKLIGHT_CAPABILITY=1
    if ! PATH="$bin:$PATH" HP2R_FIXTURE_ROOT="$root" \
      "$bin/sudo" setpriv --reuid=65534 --regid=44 --clear-groups \
      sh -eu -c '
        actual_uid="$(id -u)"
        actual_gid="$(id -g)"
        actual_groups="$(id -G)"
        writer_capabilities="$(sed -n "s/^CapEff:[[:space:]]*//p" "/proc/$$/status")"
        observer_capabilities="$(sed -n "s/^CapEff:[[:space:]]*//p" /proc/self/status)"
        test "$actual_uid" = 65534
        test "$actual_gid" = 44
        test "$actual_groups" = 44
        case "$writer_capabilities" in ""|*[!0-9a-fA-F]*) exit 1;; esac
        case "$writer_capabilities" in *[1-9a-fA-F]*) ;; *) exit 1;; esac
        case "$observer_capabilities" in ""|*[!0]*) exit 1;; esac
      ' sh >"$fixture/backlight-capability-preflight.out" 2>&1; then
      cat "$fixture/backlight-capability-preflight.out" >&2
      fail 'capability-retaining backlight fixture preflight failed'
    fi
    rm -f "$root/tmp/backlight-capability-retained"
    if run_controller accepted-lifecycle.sh --action finalize \
      >"$fixture/backlight-hostile-capability.out" 2>&1; then
      assert_file "$root/tmp/backlight-capability-retained"
      fail 'accepted finalizer trusted a capability-retaining writer shell'
    fi
    assert_file "$root/tmp/backlight-capability-retained"
    grep -Fxq 'phase=normalized_verified' "$state_dir/accepted-transition" ||
      fail 'retained-capability backlight probe advanced finalization'
    test "$(sha256sum "$state_dir/accepted-state" | awk '{ print $1 }')" = \
      "$receipt_before" || fail 'retained-capability backlight probe changed receipt'
    test "$(cat "$brightness")" = "$brightness_before" ||
      fail 'retained-capability backlight probe changed brightness'
    unset HP2R_FIXTURE_RETAIN_BACKLIGHT_CAPABILITY HP2R_FIXTURE_REJECT_SUDO_RUNAS
    unset HP2R_FIXTURE_RELEASE_OVERRIDE
    exit 0
  fi
  if test "${HP2R_FIXTURE_CASE:-}" = inactive-kernel-backlight-metadata-race ||
    test "${HP2R_FIXTURE_CASE:-}" = inactive-kernel-backlight-metadata-postwrite; then
    local brightness="$root/sys/class/backlight/planeradar-backlight/brightness"
    local brightness_before receipt_before shape marker
    local -a metadata_shapes

    if test "$HP2R_FIXTURE_CASE" = inactive-kernel-backlight-metadata-race; then
      metadata_shapes=(metadata-gid-race)
    else
      metadata_shapes=(metadata-postwrite-drift)
    fi

    prepare_inactive_normalized_verified_for_backlight_probe \
      "$prior_kernel" "$prior_initramfs" "$candidate_release"
    brightness_before="$(cat "$brightness")"
    receipt_before="$(sha256sum "$state_dir/accepted-state" | awk '{ print $1 }')"
    export HP2R_FIXTURE_REJECT_SUDO_RUNAS=1
    for shape in "${metadata_shapes[@]}"; do
      export HP2R_FIXTURE_BACKLIGHT_IDENTITY_SHAPE="$shape"
      rm -f "$root/tmp/backlight-metadata-first-snapshot"
      marker="$root/tmp/backlight-$shape"
      rm -f "$marker"
      if run_controller accepted-lifecycle.sh --action finalize \
        >"$fixture/backlight-hostile-$shape.out" 2>&1; then
        assert_file "$marker"
        fail "accepted finalizer trusted backlight metadata drift: $shape"
      fi
      assert_file "$marker"
      grep -Fxq 'phase=normalized_verified' "$state_dir/accepted-transition" ||
        fail "backlight metadata drift advanced finalization: $shape"
      test "$(sha256sum "$state_dir/accepted-state" | awk '{ print $1 }')" = \
        "$receipt_before" || fail "backlight metadata drift changed receipt: $shape"
      test "$(cat "$brightness")" = "$brightness_before" ||
        fail "backlight metadata drift changed brightness: $shape"
    done
    unset HP2R_FIXTURE_BACKLIGHT_IDENTITY_SHAPE HP2R_FIXTURE_REJECT_SUDO_RUNAS
    unset HP2R_FIXTURE_RELEASE_OVERRIDE
    exit 0
  fi
  if test "${HP2R_FIXTURE_CASE:-}" = inactive-kernel-finalization; then
    local receipt="$state_dir/accepted-state"
    local prior_artifact="$root/usr/lib/hyperpixel2r-kms/0.2.0/$source_revision/$release"
    local candidate_accepted_artifact="$root/usr/lib/hyperpixel2r-kms/$candidate_driver_version/$source_revision/$candidate_release"
    local expected_kernel_sha expected_initramfs_sha expected_base_dtb_sha expected_vc4_sha

    cp "$root$prior_kernel" "$root/boot/firmware/kernel8.img"
    cp "$root$prior_initramfs" "$root/boot/firmware/initramfs8"
    chown root:root "$root/boot/firmware/kernel8.img" "$root/boot/firmware/initramfs8"
    chmod 0644 "$root/boot/firmware/kernel8.img" "$root/boot/firmware/initramfs8"
    mkdir -p "$root/proc/device-tree/chosen/bootloader"
    printf '\0\0\0\1' > "$root/proc/device-tree/chosen/bootloader/tryboot"
    install_live_hardware
    export HP2R_FIXTURE_RELEASE_OVERRIDE="$candidate_release"
    run_controller commit-boot.sh >/dev/null
    printf '\0\0\0\0' > "$root/proc/device-tree/chosen/bootloader/tryboot"
    run_controller accepted-lifecycle.sh --action mark-explicit-normal-verified >/dev/null
    run_controller accepted-lifecycle.sh --action normalize-inactive-kernel >/dev/null
    run_controller accepted-lifecycle.sh --action mark-normalized-verified >/dev/null

    expected_kernel_sha="$(sha256sum "$root/boot/firmware/kernel8.img" | awk '{ print $1 }')"
    expected_initramfs_sha="$(sha256sum "$root/boot/firmware/initramfs8" | awk '{ print $1 }')"
    expected_base_dtb_sha="$(sha256sum "$root/boot/firmware/bcm2710-rpi-zero-2-w.dtb" | awk '{ print $1 }')"
    expected_vc4_sha="$(sha256sum "$root/boot/firmware/overlays/vc4-kms-v3d.dtbo" | awk '{ print $1 }')"
    run_controller accepted-lifecycle.sh --action finalize >/dev/null

    test "$(awk 'END { print NR }' "$receipt")" = 22 ||
      fail 'inactive finalization did not publish the exact 22-row receipt'
    test "$(sed -n '1p' "$receipt")" = schema_version=4 ||
      fail 'inactive finalization did not publish accepted schema 4'
    grep -Fxq 'normal_kernel_file=kernel8.img' "$receipt" ||
      fail 'inactive finalization lost the conventional kernel name'
    grep -Fxq "normal_kernel_sha256=$expected_kernel_sha" "$receipt" ||
      fail 'inactive finalization lost the conventional kernel digest'
    grep -Fxq 'normal_initramfs_file=initramfs8' "$receipt" ||
      fail 'inactive finalization lost the conventional initramfs name'
    grep -Fxq "normal_initramfs_sha256=$expected_initramfs_sha" "$receipt" ||
      fail 'inactive finalization lost the conventional initramfs digest'
    grep -Fxq "base_dtb_sha256=$expected_base_dtb_sha" "$receipt" ||
      fail 'inactive finalization lost the target base-DTB digest'
    grep -Fxq "vc4_overlay_sha256=$expected_vc4_sha" "$receipt" ||
      fail 'inactive finalization lost the target VC4-overlay digest'
    assert_file "$candidate_accepted_artifact/manifest.txt"
    assert_absent "$prior_artifact"
    assert_absent "$root/boot/firmware/$kernel_name"
    assert_absent "$root/boot/firmware/$initramfs_name"
    for companion in \
      accepted-transition-prior-config.txt accepted-transition-prepared.sha256 \
      accepted-transition-prior-kernel.img accepted-transition-prior-initramfs.img \
      accepted-transition-candidate-kernel.img accepted-transition-candidate-initramfs.img
    do
      assert_absent "$state_dir/$companion"
    done
    assert_absent "$state_dir/accepted-transition"
    assert_absent "$root/boot/firmware/tryboot.txt"
    assert_no_private_workspaces
    printf 'unrelated hp2r firmware\n' > "$root/boot/firmware/hp2r-keep-me.img"
    run_accepted_remote uninstall-accepted \
      "$candidate_driver_version" "$source_revision" "$candidate_release" >/dev/null
    run_accepted_remote finalize-uninstall-accepted >/dev/null
    assert_file "$root/boot/firmware/hp2r-keep-me.img"
    unset HP2R_FIXTURE_RELEASE_OVERRIDE
    exit 0
  fi
  if test "${HP2R_FIXTURE_CASE:-}" = inactive-kernel-finalization-interruption-one; then
    local boundary="${HP2R_FIXTURE_FINALIZE_BOUNDARY:-}"
    local recovery_output="$fixture/finalization-recovery-$boundary.out"
    local recovery_root="$fixture/finalization-recovery-root"
    local forward_root="$fixture/finalization-forward-root"
    local recovery_log="$fixture/finalization-recovery.log"
    local forward_log="$fixture/finalization-forward.log"
    local candidate_config="$fixture/finalization-candidate-config"
    local candidate_kernel_bytes="$fixture/finalization-candidate-kernel"
    local candidate_initramfs_bytes="$fixture/finalization-candidate-initramfs"

    use_finalization_root() {
      root="$1"
      log="$2"
      state_dir="$root/var/lib/hyperpixel2r-kms"
      backlight_rule_path="$root/etc/udev/rules.d/$backlight_rule_file"
    }
    assert_finalization_endpoint() {
      local endpoint="$1"
      local candidate_accepted_artifact="$root/usr/lib/hyperpixel2r-kms/$candidate_driver_version/$source_revision/$candidate_release"
      local prior_accepted_artifact="$root/usr/lib/hyperpixel2r-kms/0.2.0/$source_revision/$release"

      case "$endpoint" in
        prior)
          grep -Fxq "kernel_release=$release" "$state_dir/accepted-state" ||
            fail 'recovery endpoint did not retain the prior receipt'
          cmp -s "$normal_before" "$root/boot/firmware/config.txt" ||
            fail 'recovery endpoint did not restore the prior config bytes'
          cmp -s "$root$prior_kernel" "$root/boot/firmware/kernel8.img" ||
            fail 'recovery endpoint did not restore the prior kernel bytes'
          cmp -s "$root$prior_initramfs" "$root/boot/firmware/initramfs8" ||
            fail 'recovery endpoint did not restore the prior initramfs bytes'
          assert_file "$prior_accepted_artifact/manifest.txt"
          assert_absent "$candidate_accepted_artifact"
          ;;
        candidate)
          grep -Fxq 'schema_version=4' "$state_dir/accepted-state" ||
            fail 'forward endpoint lost the schema-4 receipt'
          grep -Fxq "kernel_release=$candidate_release" "$state_dir/accepted-state" ||
            fail 'forward endpoint resurrected the prior receipt'
          cmp -s "$candidate_config" "$root/boot/firmware/config.txt" ||
            fail 'forward endpoint changed normalized candidate config bytes'
          cmp -s "$candidate_kernel_bytes" "$root/boot/firmware/kernel8.img" ||
            fail 'forward endpoint changed normalized candidate kernel bytes'
          cmp -s "$candidate_initramfs_bytes" "$root/boot/firmware/initramfs8" ||
            fail 'forward endpoint changed normalized candidate initramfs bytes'
          assert_file "$candidate_accepted_artifact/manifest.txt"
          assert_absent "$prior_accepted_artifact"
          ;;
        *) fail "unknown finalization endpoint: $endpoint" ;;
      esac
      assert_absent "$root/boot/firmware/$kernel_name"
      assert_absent "$root/boot/firmware/$initramfs_name"
      assert_absent "$state_dir/accepted-transition"
      assert_absent "$state_dir/accepted-transition-prior-tryboot.txt"
      for companion in \
        accepted-transition-prior-config.txt accepted-transition-prepared.sha256 \
        accepted-transition-prior-kernel.img accepted-transition-prior-initramfs.img \
        accepted-transition-candidate-kernel.img accepted-transition-candidate-initramfs.img
      do
        assert_absent "$state_dir/$companion"
      done
      assert_no_private_workspaces
    }

    test -n "$boundary" || fail 'missing inactive finalization interruption boundary'
    cp "$root$prior_kernel" "$root/boot/firmware/kernel8.img"
    cp "$root$prior_initramfs" "$root/boot/firmware/initramfs8"
    chown root:root "$root/boot/firmware/kernel8.img" "$root/boot/firmware/initramfs8"
    chmod 0644 "$root/boot/firmware/kernel8.img" "$root/boot/firmware/initramfs8"
    mkdir -p "$root/proc/device-tree/chosen/bootloader"
    printf '\0\0\0\1' > "$root/proc/device-tree/chosen/bootloader/tryboot"
    install_live_hardware
    export HP2R_FIXTURE_RELEASE_OVERRIDE="$candidate_release"
    run_controller commit-boot.sh >/dev/null
    printf '\0\0\0\0' > "$root/proc/device-tree/chosen/bootloader/tryboot"
    run_controller accepted-lifecycle.sh --action mark-explicit-normal-verified >/dev/null
    run_controller accepted-lifecycle.sh --action normalize-inactive-kernel >/dev/null
    run_controller accepted-lifecycle.sh --action mark-normalized-verified >/dev/null
    cp "$root/boot/firmware/config.txt" "$candidate_config"
    cp "$root/boot/firmware/kernel8.img" "$candidate_kernel_bytes"
    cp "$root/boot/firmware/initramfs8" "$candidate_initramfs_bytes"
    if HP2R_FIXTURE_INTERRUPT_AFTER="$boundary" HP2R_FIXTURE_PRESERVE_MUTATIONS=1 \
      HP2R_FIXTURE_TRACK_INACTIVE_RETIRE_SYNC=1 \
      HP2R_FIXTURE_RETIRE_KERNEL="$root/boot/firmware/$kernel_name" \
      HP2R_FIXTURE_RETIRE_INITRAMFS="$root/boot/firmware/$initramfs_name" \
      HP2R_FIXTURE_RETIRE_JOURNAL="$state_dir/accepted-transition" \
      run_controller accepted-lifecycle.sh --action finalize >/dev/null 2>&1; then
      fail "inactive finalization ignored interruption: $boundary"
    fi
    case "$boundary" in
      accepted-candidate-kernel-retired)
        test "$(tail -n 1 "$root/tmp/inactive-retire-sync.log" 2>/dev/null)" = \
          'kernel=absent initramfs=present journal=present' ||
          fail 'candidate kernel retirement boundary advanced before durable absence'
        ;;
      accepted-candidate-initramfs-retired|accepted-candidate-leaves-retired|accepted-companions-retired)
        test "$(tail -n 1 "$root/tmp/inactive-retire-sync.log" 2>/dev/null)" = \
          'kernel=absent initramfs=absent journal=present' ||
          fail "candidate cleanup boundary advanced before durable absence: $boundary"
        ;;
      accepted-journal-cleared)
        test "$(tail -n 1 "$root/tmp/inactive-retire-sync.log" 2>/dev/null)" = \
          'kernel=absent initramfs=absent journal=absent' ||
          fail 'accepted journal boundary advanced before durable absence'
        ;;
    esac
    find "$state_dir" -mindepth 1 -maxdepth 1 -type d -name '.hp2r-transaction.*' \
      -exec rm -rf -- {} +
    cp -a "$root" "$recovery_root"
    cp -a "$root" "$forward_root"
    cp "$log" "$recovery_log"
    cp "$log" "$forward_log"
    chmod 0666 "$recovery_log" "$forward_log"

    use_finalization_root "$recovery_root" "$recovery_log"
    run_accepted_remote recover-accepted >"$recovery_output"
    run_accepted_remote recover-accepted >>"$recovery_output"
    if test "$boundary" = accepted-finalizing-published; then
      grep -Fxq 'reboot_required=true' "$recovery_output" ||
        fail 'pre-receipt finalization recovery did not require reboot'
      assert_finalization_endpoint prior
    else
      grep -Fxq 'reboot_required=false' "$recovery_output" ||
        fail 'post-receipt finalization recovery unexpectedly required reboot'
      assert_finalization_endpoint candidate
    fi

    use_finalization_root "$forward_root" "$forward_log"
    run_controller accepted-lifecycle.sh --action finalize >/dev/null
    run_controller accepted-lifecycle.sh --action finalize >/dev/null
    assert_finalization_endpoint candidate

    if test "$boundary" != accepted-finalizing-published; then
      diff -ru "$recovery_root/boot/firmware" "$forward_root/boot/firmware" >/dev/null ||
        fail 'recovery and forward candidate boot endpoints differ'
      diff -ru "$recovery_root/var/lib/hyperpixel2r-kms" \
        "$forward_root/var/lib/hyperpixel2r-kms" >/dev/null ||
        fail 'recovery and forward candidate receipt endpoints differ'
      diff -ru "$recovery_root/usr/lib/hyperpixel2r-kms" \
        "$forward_root/usr/lib/hyperpixel2r-kms" >/dev/null ||
        fail 'recovery and forward candidate artifact endpoints differ'
    fi
    unset HP2R_FIXTURE_RELEASE_OVERRIDE
    exit 0
  fi
  if test "${HP2R_FIXTURE_CASE:-}" = inactive-kernel-recovery-normalized; then
    local recovery_output="$fixture/inactive-normalized-recovery.out"
    local candidate_installed_artifact="$root/usr/lib/hyperpixel2r-kms/$candidate_driver_version/$source_revision/$candidate_release"

    cp "$root$prior_kernel" "$root/boot/firmware/kernel8.img"
    cp "$root$prior_initramfs" "$root/boot/firmware/initramfs8"
    chown root:root "$root/boot/firmware/kernel8.img" "$root/boot/firmware/initramfs8"
    chmod 0644 "$root/boot/firmware/kernel8.img" "$root/boot/firmware/initramfs8"
    mkdir -p "$root/proc/device-tree/chosen/bootloader"
    printf '\0\0\0\1' > "$root/proc/device-tree/chosen/bootloader/tryboot"
    install_live_hardware
    export HP2R_FIXTURE_RELEASE_OVERRIDE="$candidate_release"
    run_controller commit-boot.sh >/dev/null
    printf '\0\0\0\0' > "$root/proc/device-tree/chosen/bootloader/tryboot"
    run_controller accepted-lifecycle.sh --action mark-explicit-normal-verified >/dev/null
    run_controller accepted-lifecycle.sh --action normalize-inactive-kernel >/dev/null
    run_controller accepted-lifecycle.sh --action mark-normalized-verified >/dev/null
    run_accepted_remote recover-accepted >"$recovery_output"
    grep -Fxq 'reboot_required=true' "$recovery_output" ||
      fail 'normal-selection recovery did not report its fixed reboot result'
    cmp -s "$normal_before" "$root/boot/firmware/config.txt" ||
      fail 'normalized recovery did not restore the prior normal config'
    cmp -s "$root$prior_kernel" "$root/boot/firmware/kernel8.img" ||
      fail 'normalized recovery did not restore the prior conventional kernel'
    cmp -s "$root$prior_initramfs" "$root/boot/firmware/initramfs8" ||
      fail 'normalized recovery did not restore the prior conventional initramfs'
    grep -Fxq "kernel_release=$release" "$state_dir/accepted-state" ||
      fail 'normalized recovery replaced the prior accepted receipt'
    assert_absent "$candidate_installed_artifact"
    assert_absent "$root/boot/firmware/$kernel_name"
    assert_absent "$root/boot/firmware/$initramfs_name"
    assert_absent "$state_dir/accepted-transition"
    run_accepted_remote recover-accepted >/dev/null
    unset HP2R_FIXTURE_RELEASE_OVERRIDE
    exit 0
  fi
  if test "${HP2R_FIXTURE_CASE:-}" = inactive-kernel-normalization-interruption-one; then
    local boundary="${HP2R_FIXTURE_NORMALIZE_BOUNDARY:-}" expected_phase crash_workspace=''
    test -n "$boundary" || fail 'missing normalization interruption boundary'
    cp "$root$prior_kernel" "$fixture/normalization-versioned-kernel-before"
    cp "$root$prior_initramfs" "$fixture/normalization-versioned-initramfs-before"
    cp "$root$prior_kernel" "$root/boot/firmware/kernel8.img"
    cp "$root$prior_initramfs" "$root/boot/firmware/initramfs8"
    chown root:root "$root/boot/firmware/kernel8.img" "$root/boot/firmware/initramfs8"
    chmod 0644 "$root/boot/firmware/kernel8.img" "$root/boot/firmware/initramfs8"
    mkdir -p "$root/proc/device-tree/chosen/bootloader"
    printf '\0\0\0\1' > "$root/proc/device-tree/chosen/bootloader/tryboot"
    install_live_hardware
    export HP2R_FIXTURE_RELEASE_OVERRIDE="$candidate_release"
    run_controller commit-boot.sh >/dev/null
    printf '\0\0\0\0' > "$root/proc/device-tree/chosen/bootloader/tryboot"
    run_controller accepted-lifecycle.sh --action mark-explicit-normal-verified >/dev/null
    export HP2R_FIXTURE_INTERRUPT_AFTER="$boundary"
    if [[ "$boundary" == *-published || "$boundary" == *-phase-prepared ||
      "$boundary" == *-phase-atomic ]]; then
      export HP2R_FIXTURE_PRESERVE_MUTATIONS=1
    fi
    if run_controller accepted-lifecycle.sh --action normalize-inactive-kernel >/dev/null 2>&1; then
      fail "normalization ignored interruption: $boundary"
    fi
    unset HP2R_FIXTURE_INTERRUPT_AFTER
    if [[ "$boundary" == *-before-phase || "$boundary" == *-published ||
      "$boundary" == *-phase-prepared || "$boundary" == *-phase-atomic ]]; then
      unset HP2R_FIXTURE_PRESERVE_MUTATIONS
      test "$(find "$state_dir" -mindepth 1 -maxdepth 1 -type d \
        -name '.hp2r-transaction.*' -print | wc -l | tr -d ' ')" = 1 ||
        fail 'normalization crash did not retain one exact private workspace'
      crash_workspace="$(find "$state_dir" -mindepth 1 -maxdepth 1 -type d \
        -name '.hp2r-transaction.*' -print)"
    fi
    case "$boundary" in
      inactive-normalize-initramfs-before-phase|accepted-transition-canonical_initramfs_published-phase-prepared)
        expected_phase=explicit_normal_verified
        cmp -s "$root$prior_kernel" "$root/boot/firmware/kernel8.img" ||
          fail 'initramfs pre-phase crash changed conventional kernel'
        cmp -s "$root/boot/firmware/$initramfs_name" "$root/boot/firmware/initramfs8" ||
          fail 'initramfs pre-phase crash lacks candidate initramfs'
        ;;
      inactive-normalize-initramfs-published|accepted-transition-canonical_initramfs_published-phase-atomic)
        expected_phase=canonical_initramfs_published
        cmp -s "$root$prior_kernel" "$root/boot/firmware/kernel8.img" || fail 'initramfs boundary changed conventional kernel'
        cmp -s "$root/boot/firmware/$initramfs_name" "$root/boot/firmware/initramfs8" || fail 'initramfs boundary lacks candidate initramfs'
        grep -Fxq "kernel=$kernel_name" "$root/boot/firmware/config.txt" || fail 'initramfs boundary lost explicit config'
        ;;
      inactive-normalize-pair-before-phase|accepted-transition-canonical_pair_published-phase-prepared)
        expected_phase=canonical_initramfs_published
        cmp -s "$root/boot/firmware/$kernel_name" "$root/boot/firmware/kernel8.img" ||
          fail 'pair pre-phase crash lacks candidate kernel'
        cmp -s "$root/boot/firmware/$initramfs_name" "$root/boot/firmware/initramfs8" ||
          fail 'pair pre-phase crash lacks candidate initramfs'
        ;;
      inactive-normalize-pair-published|accepted-transition-canonical_pair_published-phase-atomic)
        expected_phase=canonical_pair_published
        cmp -s "$root/boot/firmware/$kernel_name" "$root/boot/firmware/kernel8.img" || fail 'pair boundary lacks candidate kernel'
        cmp -s "$root/boot/firmware/$initramfs_name" "$root/boot/firmware/initramfs8" || fail 'pair boundary lacks candidate initramfs'
        grep -Fxq "kernel=$kernel_name" "$root/boot/firmware/config.txt" || fail 'pair boundary lost explicit config'
        ;;
      inactive-normalize-config-before-phase|accepted-transition-normalized_config_published-phase-prepared)
        expected_phase=canonical_pair_published
        grep -Fxq 'auto_initramfs=1' "$root/boot/firmware/config.txt" ||
          fail 'config pre-phase crash lacks normalized config'
        ;;
      inactive-normalize-config-published|accepted-transition-normalized_config_published-phase-atomic)
        expected_phase=normalized_config_published
        grep -Fxq 'auto_initramfs=1' "$root/boot/firmware/config.txt" || fail 'config boundary lacks normalized config'
        ;;
      *)
        fail 'unknown normalization interruption boundary'
        ;;
    esac
    grep -Fxq "phase=$expected_phase" "$state_dir/accepted-transition" || fail 'normalization interruption published wrong phase'
    case "$boundary" in
      inactive-normalize-config-published|accepted-transition-normalized_config_published-phase-atomic)
        expected_config_sha="$(awk -F= '$1 == "normalized_normal_config_sha256" { print $2 }' "$state_dir/accepted-transition")"
        ;;
      inactive-normalize-config-before-phase|accepted-transition-normalized_config_published-phase-prepared)
        expected_config_sha="$(awk -F= '$1 == "normalized_normal_config_sha256" { print $2 }' \
          "$state_dir/accepted-transition-prepared.sha256")"
        ;;
      *)
        expected_config_sha="$(awk -F= '$1 == "explicit_normal_config_sha256" { print $2 }' "$state_dir/accepted-transition")"
        ;;
    esac
    test "$(sha256sum "$root/boot/firmware/config.txt" | awk '{ print $1 }')" = "$expected_config_sha" || fail 'normalization interruption config digest disagrees with journal'
    for companion in \
      accepted-transition-prior-kernel.img \
      accepted-transition-prior-initramfs.img \
      accepted-transition-candidate-kernel.img \
      accepted-transition-candidate-initramfs.img
    do
      assert_file "$state_dir/$companion"
    done
    assert_file "$root/boot/firmware/$kernel_name"
    assert_file "$root/boot/firmware/$initramfs_name"
    assert_absent "$state_dir/tryboot-state"
    assert_absent "$state_dir/.inactive-explicit-state-hold"
    assert_absent "$root/boot/firmware/tryboot.txt"
    cmp -s "$fixture/normalization-versioned-kernel-before" "$root$prior_kernel" || fail 'normalization interruption changed versioned kernel source'
    cmp -s "$fixture/normalization-versioned-initramfs-before" "$root$prior_initramfs" || fail 'normalization interruption changed versioned initramfs source'
    if test "$boundary" = accepted-transition-normalized_config_published-phase-atomic; then
      if HP2R_FIXTURE_PRESERVE_MUTATIONS=1 \
        run_controller accepted-lifecycle.sh --action mark-normalized-verified >/dev/null 2>&1; then
        fail 'normalized verification advanced past an unfinished normalization replay'
      fi
      grep -Fxq 'phase=normalized_config_published' "$state_dir/accepted-transition" ||
        fail 'rejected out-of-order normalized verification changed phase'
      test -d "$crash_workspace" ||
        fail 'rejected out-of-order normalized verification retired the caller workspace'
    fi
    run_controller accepted-lifecycle.sh --action normalize-inactive-kernel >/dev/null
    grep -Fxq 'phase=normalized_config_published' "$state_dir/accepted-transition" || fail 'normalization retry did not finish'
    cmp -s "$root/boot/firmware/$kernel_name" "$root/boot/firmware/kernel8.img" || fail 'normalization retry lacks candidate kernel8'
    cmp -s "$root/boot/firmware/$initramfs_name" "$root/boot/firmware/initramfs8" || fail 'normalization retry lacks candidate initramfs8'
    test "$(sha256sum "$root/boot/firmware/config.txt" | awk '{ print $1 }')" = "$(awk -F= '$1 == "normalized_normal_config_sha256" { print $2 }' "$state_dir/accepted-transition")" || fail 'normalization retry config digest disagrees with journal'
    if test -n "$crash_workspace" && test -d "$crash_workspace"; then
      fail 'normalization retry retained the original abrupt-crash workspace'
    fi
    assert_no_private_workspaces
    unset HP2R_FIXTURE_RELEASE_OVERRIDE
    exit 0
  fi
  if test "${HP2R_FIXTURE_CASE:-}" = inactive-kernel-normalization-race-one; then
    local race="${HP2R_FIXTURE_NORMALIZATION_RACE:-}"
    case "$race" in
      journal|bound-leaf) ;;
      *) fail 'missing normalization snapshot race kind' ;;
    esac
    cp "$root$prior_kernel" "$root/boot/firmware/kernel8.img"
    cp "$root$prior_initramfs" "$root/boot/firmware/initramfs8"
    chown root:root "$root/boot/firmware/kernel8.img" "$root/boot/firmware/initramfs8"
    chmod 0644 "$root/boot/firmware/kernel8.img" "$root/boot/firmware/initramfs8"
    mkdir -p "$root/proc/device-tree/chosen/bootloader"
    printf '\0\0\0\1' > "$root/proc/device-tree/chosen/bootloader/tryboot"
    install_live_hardware
    export HP2R_FIXTURE_RELEASE_OVERRIDE="$candidate_release"
    run_controller commit-boot.sh >/dev/null
    printf '\0\0\0\0' > "$root/proc/device-tree/chosen/bootloader/tryboot"
    run_controller accepted-lifecycle.sh --action mark-explicit-normal-verified >/dev/null
    cp "$state_dir/accepted-transition" "$fixture/normalization-race-journal-before-$race"
    case "$race" in
      journal)
        export HP2R_FIXTURE_MUTATE_SETTER_AUTHORITY=1
        ;;
      bound-leaf)
        export HP2R_FIXTURE_MUTATE_NORMALIZATION_BOUND_LEAF=1
        ;;
    esac
    if run_controller accepted-lifecycle.sh --action normalize-inactive-kernel >/dev/null 2>&1; then
      fail "normalization snapshot race was accepted: $race"
    fi
    unset HP2R_FIXTURE_MUTATE_SETTER_AUTHORITY HP2R_FIXTURE_MUTATE_NORMALIZATION_BOUND_LEAF
    grep -Fxq 'phase=explicit_normal_verified' "$state_dir/accepted-transition" ||
      fail "normalization race advanced phase: $race"
    assert_no_private_workspaces
    cmp -s "$root$prior_initramfs" "$root/boot/firmware/initramfs8" ||
      fail "normalization race did not compensate unpublished initramfs: $race"
    cmp -s "$root$prior_kernel" "$root/boot/firmware/kernel8.img" ||
      fail "normalization race changed conventional kernel before phase commit: $race"
      case "$race" in
        journal)
          assert_file "$root/tmp/setter-authority-mutated"
          cmp -s "$fixture/normalization-race-journal-before-$race" "$state_dir/accepted-transition" && fail 'journal race did not retain hostile drift'
          cp "$fixture/normalization-race-journal-before-$race" "$state_dir/accepted-transition"
          chown root:root "$state_dir/accepted-transition"
          chmod 0600 "$state_dir/accepted-transition"
          ;;
        bound-leaf)
          assert_file "$root/tmp/normalization-bound-leaf-mutated"
          cmp -s "$fixture/normalization-race-journal-before-$race" "$state_dir/accepted-transition" || fail 'bound leaf race rewrote journal'
          cp "$root/boot/firmware/$kernel_name" "$state_dir/accepted-transition-candidate-kernel.img"
          chown root:root "$state_dir/accepted-transition-candidate-kernel.img"
          chmod 0600 "$state_dir/accepted-transition-candidate-kernel.img"
          ;;
      esac
      run_controller accepted-lifecycle.sh --action normalize-inactive-kernel >/dev/null || fail "normalization retry failed after repairing $race"
      grep -Fxq 'phase=normalized_config_published' "$state_dir/accepted-transition" || fail "normalization retry did not finish after $race"
      cmp -s "$root/boot/firmware/$kernel_name" "$root/boot/firmware/kernel8.img" || fail "normalization retry kernel mismatch after $race"
      cmp -s "$root/boot/firmware/$initramfs_name" "$root/boot/firmware/initramfs8" || fail "normalization retry initramfs mismatch after $race"
      test "$(sha256sum "$root/boot/firmware/config.txt" | awk '{ print $1 }')" = "$(awk -F= '$1 == "normalized_normal_config_sha256" { print $2 }' "$state_dir/accepted-transition")" || fail "normalization retry config mismatch after $race"
      assert_no_private_workspaces
    unset HP2R_FIXTURE_RELEASE_OVERRIDE
    exit 0
  fi
  if test "${HP2R_FIXTURE_CASE:-}" = inactive-kernel-normalization-post-atomic; then
    cp "$root$prior_kernel" "$root/boot/firmware/kernel8.img"
    cp "$root$prior_initramfs" "$root/boot/firmware/initramfs8"
    chown root:root "$root/boot/firmware/kernel8.img" "$root/boot/firmware/initramfs8"
    chmod 0644 "$root/boot/firmware/kernel8.img" "$root/boot/firmware/initramfs8"
    mkdir -p "$root/proc/device-tree/chosen/bootloader"
    printf '\0\0\0\1' > "$root/proc/device-tree/chosen/bootloader/tryboot"
    install_live_hardware
    export HP2R_FIXTURE_RELEASE_OVERRIDE="$candidate_release"
    run_controller commit-boot.sh >/dev/null
    printf '\0\0\0\0' > "$root/proc/device-tree/chosen/bootloader/tryboot"
    run_controller accepted-lifecycle.sh --action mark-explicit-normal-verified >/dev/null
    export HP2R_FIXTURE_INTERRUPT_AFTER=accepted-transition-phase-atomic
    export HP2R_FIXTURE_PRESERVE_MUTATIONS=1
    if run_controller accepted-lifecycle.sh --action normalize-inactive-kernel >/dev/null 2>&1; then
      fail 'normalization ignored post-atomic setter power loss'
    else
      status=$?
    fi
    unset HP2R_FIXTURE_INTERRUPT_AFTER HP2R_FIXTURE_PRESERVE_MUTATIONS
    test "$status" = 97 || fail "post-atomic setter power loss returned $status"
    grep -Fxq 'phase=canonical_initramfs_published' "$state_dir/accepted-transition" || fail 'post-atomic failure did not retain committed phase'
    cmp -s "$root/boot/firmware/$initramfs_name" "$root/boot/firmware/initramfs8" || fail 'post-atomic failure compensated committed initramfs'
    grep -Fxq "kernel=$kernel_name" "$root/boot/firmware/config.txt" || fail 'post-atomic failure changed explicit config'
    test "$(find "$state_dir" -mindepth 1 -maxdepth 1 -type d \
      -name '.hp2r-transaction.*' -print | wc -l | tr -d ' ')" = 1 ||
      fail 'post-atomic setter power loss did not retain one exact replay workspace'
    run_controller accepted-lifecycle.sh --action normalize-inactive-kernel >/dev/null ||
      fail 'normalization did not recover post-atomic setter power loss'
    grep -Fxq 'phase=normalized_config_published' "$state_dir/accepted-transition" ||
      fail 'post-atomic setter recovery did not finish normalization'
    assert_no_private_workspaces
    unset HP2R_FIXTURE_RELEASE_OVERRIDE
    exit 0
  fi
  if test "${HP2R_FIXTURE_CASE:-}" = inactive-kernel-verification-phase-atomic ||
    test "${HP2R_FIXTURE_CASE:-}" = inactive-kernel-verification-phase-prepared; then
    local setter_boundary=accepted-transition-phase-atomic
    local explicit_crash_phase=explicit_normal_verified
    local normalized_crash_phase=normalized_verified
    if test "${HP2R_FIXTURE_CASE:-}" = inactive-kernel-verification-phase-prepared; then
      setter_boundary=accepted-transition-phase-prepared
      explicit_crash_phase=explicit_normal_published
      normalized_crash_phase=normalized_config_published
    fi
    cp "$root$prior_kernel" "$root/boot/firmware/kernel8.img"
    cp "$root$prior_initramfs" "$root/boot/firmware/initramfs8"
    chown root:root "$root/boot/firmware/kernel8.img" "$root/boot/firmware/initramfs8"
    chmod 0644 "$root/boot/firmware/kernel8.img" "$root/boot/firmware/initramfs8"
    mkdir -p "$root/proc/device-tree/chosen/bootloader"
    printf '\0\0\0\1' > "$root/proc/device-tree/chosen/bootloader/tryboot"
    install_live_hardware
    export HP2R_FIXTURE_RELEASE_OVERRIDE="$candidate_release"
    run_controller commit-boot.sh >/dev/null
    printf '\0\0\0\0' > "$root/proc/device-tree/chosen/bootloader/tryboot"

    export HP2R_FIXTURE_INTERRUPT_AFTER="$setter_boundary"
    export HP2R_FIXTURE_PRESERVE_MUTATIONS=1
    if run_controller accepted-lifecycle.sh --action mark-explicit-normal-verified >/dev/null 2>&1; then
      fail 'explicit normal verification ignored setter power loss'
    else
      status=$?
    fi
    unset HP2R_FIXTURE_INTERRUPT_AFTER HP2R_FIXTURE_PRESERVE_MUTATIONS
    test "$status" = 97 || fail "explicit normal setter power loss returned $status"
    grep -Fxq "phase=$explicit_crash_phase" "$state_dir/accepted-transition" ||
      fail 'explicit normal setter power loss retained the wrong phase'
    test "$(find "$state_dir" -mindepth 1 -maxdepth 1 -type d \
      -name '.hp2r-transaction.*' -print | wc -l | tr -d ' ')" = 1 ||
      fail 'explicit normal setter power loss did not retain one exact workspace'
    if test -n "${HP2R_FIXTURE_PHASE_SETTER_HOSTILE:-}"; then
      setter_workspace="$(find "$state_dir" -mindepth 1 -maxdepth 1 -type d \
        -name '.hp2r-transaction.*' -print)"
      case "$HP2R_FIXTURE_PHASE_SETTER_HOSTILE" in
        digest)
          printf 'hostile setter digest drift\n' >> "$setter_workspace/accepted-transition"
          ;;
        extra)
          printf 'unexpected setter leaf\n' > "$setter_workspace/unexpected"
          chown root:root "$setter_workspace/unexpected"
          chmod 0600 "$setter_workspace/unexpected"
          ;;
        mode)
          chmod 0644 "$setter_workspace/accepted-transition"
          ;;
        *) fail 'unknown phase-setter hostile kind' ;;
      esac
      if HP2R_FIXTURE_PRESERVE_MUTATIONS=1 \
        run_controller accepted-lifecycle.sh --action mark-explicit-normal-verified >/dev/null 2>&1; then
        fail "phase-setter replay accepted hostile $HP2R_FIXTURE_PHASE_SETTER_HOSTILE"
      fi
      test -d "$setter_workspace" ||
        fail "phase-setter replay deleted hostile $HP2R_FIXTURE_PHASE_SETTER_HOSTILE workspace"
      unset HP2R_FIXTURE_RELEASE_OVERRIDE
      exit 0
    fi
    HP2R_FIXTURE_PRESERVE_MUTATIONS=1 \
      run_controller accepted-lifecycle.sh --action mark-explicit-normal-verified >/dev/null ||
      fail 'explicit normal verification did not recover its setter power loss'
    grep -Fxq 'phase=explicit_normal_verified' "$state_dir/accepted-transition" ||
      fail 'explicit normal verification recovery did not publish verified phase'
    assert_no_private_workspaces

    run_controller accepted-lifecycle.sh --action normalize-inactive-kernel >/dev/null
    export HP2R_FIXTURE_INTERRUPT_AFTER="$setter_boundary"
    export HP2R_FIXTURE_PRESERVE_MUTATIONS=1
    if run_controller accepted-lifecycle.sh --action mark-normalized-verified >/dev/null 2>&1; then
      fail 'normalized verification ignored setter power loss'
    else
      status=$?
    fi
    unset HP2R_FIXTURE_INTERRUPT_AFTER HP2R_FIXTURE_PRESERVE_MUTATIONS
    test "$status" = 97 || fail "normalized setter power loss returned $status"
    grep -Fxq "phase=$normalized_crash_phase" "$state_dir/accepted-transition" ||
      fail 'normalized setter power loss retained the wrong phase'
    test "$(find "$state_dir" -mindepth 1 -maxdepth 1 -type d \
      -name '.hp2r-transaction.*' -print | wc -l | tr -d ' ')" = 1 ||
      fail 'normalized setter power loss did not retain one exact workspace'
    HP2R_FIXTURE_PRESERVE_MUTATIONS=1 \
      run_controller accepted-lifecycle.sh --action mark-normalized-verified >/dev/null ||
      fail 'normalized verification did not recover its setter power loss'
    grep -Fxq 'phase=normalized_verified' "$state_dir/accepted-transition" ||
      fail 'normalized verification recovery did not publish verified phase'
    assert_no_private_workspaces
    unset HP2R_FIXTURE_RELEASE_OVERRIDE
    exit 0
  fi
  if test "${HP2R_FIXTURE_CASE:-}" = inactive-kernel-normalized-unhealthy; then
    cp "$root$prior_kernel" "$root/boot/firmware/kernel8.img"
    cp "$root$prior_initramfs" "$root/boot/firmware/initramfs8"
    chown root:root "$root/boot/firmware/kernel8.img" "$root/boot/firmware/initramfs8"
    chmod 0644 "$root/boot/firmware/kernel8.img" "$root/boot/firmware/initramfs8"
    mkdir -p "$root/proc/device-tree/chosen/bootloader"
    printf '\0\0\0\1' > "$root/proc/device-tree/chosen/bootloader/tryboot"
    install_live_hardware
    export HP2R_FIXTURE_RELEASE_OVERRIDE="$candidate_release"
    run_controller commit-boot.sh >/dev/null
    printf '\0\0\0\0' > "$root/proc/device-tree/chosen/bootloader/tryboot"
    run_controller accepted-lifecycle.sh --action mark-explicit-normal-verified >/dev/null
    run_controller accepted-lifecycle.sh --action normalize-inactive-kernel >/dev/null
    rm -f "$root/sys/module/hyperpixel2r_kms/version"
    if run_controller accepted-lifecycle.sh --action mark-normalized-verified >/dev/null 2>&1; then
      fail 'normalized verifier accepted unhealthy hardware'
    fi
    grep -Fxq 'phase=normalized_config_published' "$state_dir/accepted-transition" || fail 'unhealthy normalized verifier advanced phase'
    assert_no_private_workspaces
    unset HP2R_FIXTURE_RELEASE_OVERRIDE
    exit 0
  fi
  if test "${HP2R_FIXTURE_CASE:-}" = inactive-kernel-normalization-phase-hostile-one; then
    local phase_case="${HP2R_FIXTURE_NORMALIZATION_PHASE_CASE:-}" boundary expected_phase action hostile
    local hostile_secondary='' normalized_hostile_sha=''
    case "$phase_case" in
      initramfs)
        boundary=inactive-normalize-initramfs-published
        expected_phase=canonical_initramfs_published
        action=normalize-inactive-kernel
        hostile="$root/boot/firmware/initramfs8"
        ;;
      pair)
        boundary=inactive-normalize-pair-published
        expected_phase=canonical_pair_published
        action=normalize-inactive-kernel
        hostile="$root/boot/firmware/kernel8.img"
        ;;
      config)
        boundary=inactive-normalize-config-published
        expected_phase=normalized_config_published
        action=mark-normalized-verified
        hostile="$root/boot/firmware/config.txt"
        ;;
      normalized-pair)
        boundary=inactive-normalize-config-published
        expected_phase=normalized_config_published
        action=mark-normalized-verified
        hostile="$state_dir/accepted-transition"
        hostile_secondary="$root/boot/firmware/config.txt"
        ;;
      journal|phase)
        boundary=inactive-normalize-initramfs-published
        expected_phase=canonical_initramfs_published
        action=normalize-inactive-kernel
        hostile="$state_dir/accepted-transition"
        ;;
      anchor-drift|anchor-missing|anchor-symlink)
        boundary=inactive-normalize-initramfs-published
        expected_phase=canonical_initramfs_published
        action=normalize-inactive-kernel
        hostile="$state_dir/accepted-transition-prepared.sha256"
        ;;
      *)
        fail 'unknown normalization hostile phase case'
        ;;
    esac
    cp "$root$prior_kernel" "$root/boot/firmware/kernel8.img"
    cp "$root$prior_initramfs" "$root/boot/firmware/initramfs8"
    chown root:root "$root/boot/firmware/kernel8.img" "$root/boot/firmware/initramfs8"
    chmod 0644 "$root/boot/firmware/kernel8.img" "$root/boot/firmware/initramfs8"
    mkdir -p "$root/proc/device-tree/chosen/bootloader"
    printf '\0\0\0\1' > "$root/proc/device-tree/chosen/bootloader/tryboot"
    install_live_hardware
    export HP2R_FIXTURE_RELEASE_OVERRIDE="$candidate_release"
    run_controller commit-boot.sh >/dev/null
    printf '\0\0\0\0' > "$root/proc/device-tree/chosen/bootloader/tryboot"
    run_controller accepted-lifecycle.sh --action mark-explicit-normal-verified >/dev/null
    export HP2R_FIXTURE_INTERRUPT_AFTER="$boundary"
    if run_controller accepted-lifecycle.sh --action normalize-inactive-kernel >/dev/null 2>&1; then
      fail 'normalization hostile setup ignored interruption'
    fi
    unset HP2R_FIXTURE_INTERRUPT_AFTER
    grep -Fxq "phase=$expected_phase" "$state_dir/accepted-transition" || fail 'normalization hostile setup phase drifted'
    case "$phase_case" in
      journal)
        sed -i 's/^target_identity_sha256=.*/target_identity_sha256=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee/' "$hostile"
        ;;
      phase)
        sed -i 's/^phase=.*/phase=unsupported/' "$hostile"
        ;;
      anchor-drift)
        printf '%064d\n' 0 > "$hostile"
        ;;
      anchor-missing)
        rm -f -- "$hostile"
        ;;
      anchor-symlink)
        rm -f -- "$hostile"
        ln -s accepted-transition "$hostile"
        ;;
      normalized-pair)
        printf 'hostile normalized selection\n' >> "$hostile_secondary"
        normalized_hostile_sha="$(sha256sum "$hostile_secondary" | awk '{ print $1 }')"
        sed -i \
          "s/^normalized_normal_config_sha256=.*/normalized_normal_config_sha256=$normalized_hostile_sha/" \
          "$hostile"
        ;;
      *)
        printf 'hostile normalization drift\n' >> "$hostile"
        ;;
    esac
    if test "$phase_case" != anchor-missing; then
      cp -P "$hostile" "$fixture/normalization-hostile-before-$phase_case"
      if test -n "$hostile_secondary"; then
        cp -P "$hostile_secondary" \
          "$fixture/normalization-hostile-secondary-before-$phase_case"
      fi
    fi
    if run_controller accepted-lifecycle.sh --action "$action" >/dev/null 2>&1; then
      fail "normalization hostile phase was accepted: $phase_case"
    fi
    if test "$phase_case" = anchor-missing; then
      test ! -e "$hostile" && test ! -L "$hostile" || fail 'normalization recreated a missing prepared anchor'
    elif test "$phase_case" = anchor-symlink; then
      test -L "$hostile" || fail 'normalization replaced a symlinked prepared anchor'
    else
      cmp -s "$fixture/normalization-hostile-before-$phase_case" "$hostile" || fail "normalization hostile bytes were changed: $phase_case"
      if test -n "$hostile_secondary"; then
        cmp -s "$fixture/normalization-hostile-secondary-before-$phase_case" \
          "$hostile_secondary" ||
          fail "normalization secondary hostile bytes were changed: $phase_case"
      fi
    fi
    if test "$phase_case" = phase; then
      grep -Fxq 'phase=unsupported' "$state_dir/accepted-transition" ||
        fail 'normalization hostile action changed the unsupported phase'
    else
      grep -Fxq "phase=$expected_phase" "$state_dir/accepted-transition" ||
        fail "normalization hostile action advanced phase: $phase_case"
    fi
    assert_no_private_workspaces
    unset HP2R_FIXTURE_RELEASE_OVERRIDE
    exit 0
  fi
  if test "${HP2R_FIXTURE_CASE:-}" = inactive-kernel-explicit-interruption-one; then
    local boundary="${HP2R_FIXTURE_COMMIT_BOUNDARY:-}" expected_phase
    test -n "$boundary" || fail 'missing inactive explicit interruption boundary'
    mkdir -p "$root/proc/device-tree/chosen/bootloader"
    printf '\0\0\0\1' > "$root/proc/device-tree/chosen/bootloader/tryboot"
    install_live_hardware
    export HP2R_FIXTURE_RELEASE_OVERRIDE="$candidate_release"
    export HP2R_FIXTURE_INTERRUPT_AFTER="$boundary"
    if test "$boundary" = inactive-explicit-normal-published ||
      test "$boundary" = accepted-transition-phase-atomic ||
      test "$boundary" = accepted-transition-phase-prepared ||
      test "$boundary" = inactive-explicit-normal-state-moved ||
      test "$boundary" = inactive-explicit-normal-state-deleted ||
      test "$boundary" = inactive-explicit-normal-files-published ||
      test "$boundary" = inactive-explicit-normal-config-published; then
      export HP2R_FIXTURE_PRESERVE_MUTATIONS=1
    fi
    if run_controller commit-boot.sh >/dev/null 2>&1; then
      fail "inactive commit ignored interruption: $boundary"
    fi
    unset HP2R_FIXTURE_INTERRUPT_AFTER
    if test "$boundary" = inactive-explicit-normal-published ||
      test "$boundary" = accepted-transition-phase-atomic ||
      test "$boundary" = accepted-transition-phase-prepared ||
      test "$boundary" = inactive-explicit-normal-state-moved ||
      test "$boundary" = inactive-explicit-normal-state-deleted ||
      test "$boundary" = inactive-explicit-normal-files-published ||
      test "$boundary" = inactive-explicit-normal-config-published; then
      unset HP2R_FIXTURE_PRESERVE_MUTATIONS
      assert_file "$state_dir/accepted-transition"
      if test "$boundary" = inactive-explicit-normal-published ||
        test "$boundary" = accepted-transition-phase-atomic; then
        grep -Fxq 'phase=explicit_normal_published' "$state_dir/accepted-transition" ||
          fail 'phase-published interruption lost the explicit transition journal'
        assert_file "$state_dir/tryboot-state"
      elif test "$boundary" = inactive-explicit-normal-state-moved; then
        grep -Fxq 'phase=explicit_normal_published' "$state_dir/accepted-transition" ||
          fail 'state-moved interruption did not retain the explicit transition journal'
        assert_file "$state_dir/.inactive-explicit-state-hold"
      elif test "$boundary" = inactive-explicit-normal-state-deleted; then
        grep -Fxq 'phase=explicit_normal_published' "$state_dir/accepted-transition" ||
          fail 'state-deleted interruption lost the explicit transition journal'
        assert_absent "$state_dir/tryboot-state"
        assert_absent "$state_dir/.inactive-explicit-state-hold"
      else
        grep -Fxq 'phase=staged' "$state_dir/accepted-transition" ||
          fail 'files-published crash advanced the explicit transition journal'
        assert_file "$state_dir/tryboot-state"
      fi
      test "$(find "$state_dir" -mindepth 1 -maxdepth 1 -type d \
        -name '.hp2r-transaction.*' -print | wc -l | tr -d ' ')" = 1 ||
        fail 'explicit crash did not retain one exact private workspace'
    fi
    case "$boundary" in
      inactive-explicit-normal-config-published)
        expected_phase=staged
        test "$(tail -n 4 "$root/boot/firmware/config.txt")" = "$(printf '%s\n' \
          '# hyperpixel2r-kms one-shot inactive-kernel candidate' \
          "kernel=$kernel_name" \
          "initramfs $initramfs_name followkernel" \
          "dtoverlay=$overlay_file")" ||
          fail 'config-only crash lost the explicit candidate selection'
        test "$(sha256sum "$root/boot/firmware/tryboot.txt" | awk '{ print $1 }')" = \
          "$(awk -F= '$1 == "candidate_config_sha256" { print $2 }' "$state_dir/tryboot-state")" ||
          fail 'config-only crash changed the active candidate tryboot selection'
        ;;
      inactive-explicit-normal-files-published|accepted-transition-phase-prepared)
        expected_phase=staged
        test "$(tail -n 4 "$root/boot/firmware/config.txt")" = "$(printf '%s\n' \
          '# hyperpixel2r-kms one-shot inactive-kernel candidate' \
          "kernel=$kernel_name" \
          "initramfs $initramfs_name followkernel" \
          "dtoverlay=$overlay_file")" ||
          fail 'files-published crash lost the explicit candidate selection'
        if test "${HP2R_FIXTURE_PRIOR_TRYBOOT:-}" = 1; then
          grep -Fxq '# accepted prior one-shot configuration' \
            "$root/boot/firmware/tryboot.txt" ||
            fail 'files-published crash did not retain the restored prior tryboot config'
        else
          assert_absent "$root/boot/firmware/tryboot.txt"
        fi
        ;;
      inactive-explicit-normal-before-phase)
        expected_phase=staged
        cmp -s "$normal_before" "$root/boot/firmware/config.txt" ||
          fail 'pre-phase interruption did not restore the prior normal selection'
        ;;
      inactive-explicit-normal-published|accepted-transition-phase-atomic)
        expected_phase=explicit_normal_published
        test "$(tail -n 4 "$root/boot/firmware/config.txt")" = "$(printf '%s\n' \
          '# hyperpixel2r-kms one-shot inactive-kernel candidate' \
          "kernel=$kernel_name" \
          "initramfs $initramfs_name followkernel" \
          "dtoverlay=$overlay_file")" ||
          fail 'post-phase interruption did not retain the complete explicit selection'
        ;;
      inactive-explicit-normal-state-moved|inactive-explicit-normal-state-deleted)
        expected_phase=explicit_normal_published
        test "$(tail -n 4 "$root/boot/firmware/config.txt")" = "$(printf '%s\n' \
          '# hyperpixel2r-kms one-shot inactive-kernel candidate' \
          "kernel=$kernel_name" \
          "initramfs $initramfs_name followkernel" \
          "dtoverlay=$overlay_file")" ||
          fail 'state-retirement interruption did not retain the complete explicit selection'
        ;;
      *) fail "unknown inactive explicit interruption boundary: $boundary" ;;
    esac
    grep -Fxq "phase=$expected_phase" "$state_dir/accepted-transition" ||
      fail "inactive interruption published the wrong phase: $boundary"
    case "$boundary" in
      inactive-explicit-normal-config-published|inactive-explicit-normal-files-published|inactive-explicit-normal-before-phase|accepted-transition-phase-prepared|inactive-explicit-normal-published|accepted-transition-phase-atomic)
        assert_file "$state_dir/tryboot-state"
        ;;
      *) assert_absent "$state_dir/tryboot-state" ;;
    esac
    if test "$boundary" = accepted-transition-phase-prepared &&
      test "${HP2R_FIXTURE_PREPHASE_SETTER_HOSTILE:-}" = current-journal; then
      setter_workspace="$(find "$state_dir" -mindepth 1 -maxdepth 1 -type d \
        -name '.hp2r-transaction.*' -print)"
      cp "$state_dir/accepted-transition" "$setter_workspace/accepted-transition"
      chown root:root "$setter_workspace/accepted-transition"
      chmod 0600 "$setter_workspace/accepted-transition"
      if HP2R_FIXTURE_PRESERVE_MUTATIONS=1 \
        run_controller commit-boot.sh >/dev/null 2>&1; then
        fail 'pre-phase replay accepted the current journal as its proposed next journal'
      fi
      grep -Fxq 'phase=staged' "$state_dir/accepted-transition" ||
        fail 'hostile pre-phase setter replay changed the durable phase'
      test -d "$setter_workspace" ||
        fail 'hostile pre-phase setter replay deleted the suspicious caller workspace'
      assert_file "$state_dir/tryboot-state"
      unset HP2R_FIXTURE_RELEASE_OVERRIDE
      exit 0
    fi
    if test "$boundary" = inactive-explicit-normal-published ||
      test "$boundary" = accepted-transition-phase-atomic; then
      if HP2R_FIXTURE_PRESERVE_MUTATIONS=1 \
        run_controller verify-boot.sh --expect-tryboot \
        --expect-kernel-release "$candidate_release" \
        --expect-driver-version "$candidate_driver_version" \
        --expect-overlay-file "$overlay_file" >/dev/null 2>&1; then
        fail 'ordinary tryboot verification accepted a retired active config'
      fi
      if HP2R_FIXTURE_PRESERVE_MUTATIONS=1 \
        run_controller verify-boot.sh --expect-tryboot \
        --allow-retired-tryboot-config >/dev/null 2>&1; then
        fail 'retired tryboot verification accepted an incomplete identity'
      else
        status=$?
        test "$status" = 64 ||
          fail "retired tryboot verification returned $status for an incomplete identity"
      fi
    fi
    if test "$boundary" = accepted-transition-phase-atomic; then
      printf '\0\0\0\0' > "$root/proc/device-tree/chosen/bootloader/tryboot"
      if HP2R_FIXTURE_PRESERVE_MUTATIONS=1 \
        run_controller accepted-lifecycle.sh --action mark-explicit-normal-verified >/dev/null 2>&1; then
        fail 'explicit verification advanced past an unfinished commit replay'
      fi
      grep -Fxq 'phase=explicit_normal_published' "$state_dir/accepted-transition" ||
        fail 'rejected out-of-order explicit verification changed phase'
      assert_file "$state_dir/tryboot-state"
      test "$(find "$state_dir" -mindepth 1 -maxdepth 1 -type d \
        -name '.hp2r-transaction.*' -print | wc -l | tr -d ' ')" = 1 ||
        fail 'rejected out-of-order explicit verification retired the caller workspace'
    fi
    # A public replay must obtain a typed, phase-aware proof before it can
    # invoke commit.  In particular, a moved generic state is authoritative
    # only when the full schema-6 journal and the deterministic hold agree.
    if test "$boundary" = inactive-explicit-normal-state-moved; then
      local commit_probe
      commit_probe="$(run_accepted_remote commit-probe)" ||
        fail 'public moved-state replay could not obtain a strict commit probe'
      [[ "$commit_probe" =~ ^explicit-replay$'\t'tryboot$'\t'[0-9]+\.[0-9]+\.[0-9]+$'\t'hyperpixel2r-kms-[0-9a-f]{12}\.dtbo$'\t'[A-Za-z0-9._+-]+$'\t'hyperpixel2r_kms\.ko$'\t'[0-9a-f]{64}$'\t'false$'\t'none$'\t'[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] ||
        fail 'public moved-state replay returned an unsafe typed commit probe'
    fi
    if test -n "${HP2R_FIXTURE_REPLAY_HOSTILE:-}"; then
      replay_workspace="$(find "$state_dir" -mindepth 1 -maxdepth 1 -type d \
        -name '.hp2r-transaction.*' -print)"
      test -n "$replay_workspace" && test -d "$replay_workspace" ||
        fail 'hostile explicit replay fixture lacks its caller workspace'
      cp -a "$replay_workspace" "$fixture/explicit-hostile-workspace-before"
      find -P "$replay_workspace" -mindepth 0 -maxdepth 1 \
        -printf '%P\t%u:%g:%m\n' | LC_ALL=C sort \
        > "$fixture/explicit-hostile-workspace-metadata-before"
    fi
    case "${HP2R_FIXTURE_REPLAY_HOSTILE:-}" in
      '') ;;
      journal)
        replace_equals_value "$state_dir/accepted-transition" target_identity_sha256 \
          dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
        ;;
      hold)
        printf 'forged generic state\n' >> "$state_dir/.inactive-explicit-state-hold"
        ;;
      *) fail 'unknown inactive explicit replay hostile fixture' ;;
    esac
    if test -n "${HP2R_FIXTURE_REPLAY_HOSTILE:-}"; then
      if run_accepted_remote commit-probe >/dev/null 2>&1; then
        fail 'strict commit probe accepted forged inactive replay authority'
      fi
      if HP2R_FIXTURE_PRESERVE_MUTATIONS=1 \
        run_controller commit-boot.sh >/dev/null 2>&1; then
        fail 'public commit reached replay after a forged inactive authority probe'
      fi
      assert_absent "$state_dir/tryboot-state"
      assert_file "$state_dir/.inactive-explicit-state-hold"
      test -d "$replay_workspace" ||
        fail 'hostile explicit replay deleted the suspicious caller workspace'
      diff -r "$fixture/explicit-hostile-workspace-before" "$replay_workspace" >/dev/null ||
        fail 'hostile explicit replay changed the suspicious caller workspace bytes'
      find -P "$replay_workspace" -mindepth 0 -maxdepth 1 \
        -printf '%P\t%u:%g:%m\n' | LC_ALL=C sort \
        > "$fixture/explicit-hostile-workspace-metadata-after"
      cmp -s "$fixture/explicit-hostile-workspace-metadata-before" \
        "$fixture/explicit-hostile-workspace-metadata-after" ||
        fail 'hostile explicit replay changed the suspicious caller workspace metadata'
      unset HP2R_FIXTURE_RELEASE_OVERRIDE
      exit 0
    fi
    if test "${HP2R_FIXTURE_REPLAY_NORMAL:-}" = 1; then
      printf '\0\0\0\0' > "$root/proc/device-tree/chosen/bootloader/tryboot"
    fi
    if ! HP2R_FIXTURE_PRESERVE_MUTATIONS=1 \
      run_controller commit-boot.sh >"$fixture/inactive-explicit-commit-replay" 2>&1; then
      cat "$fixture/inactive-explicit-commit-replay" >&2
      fail "inactive commit did not resume after interruption: $boundary"
    fi
    assert_absent "$state_dir/tryboot-state"
    assert_absent "$state_dir/.inactive-explicit-state-hold" ||
      fail "inactive commit left a durable state hold after retry: $boundary"
    assert_no_private_workspaces
    grep -Fxq 'phase=explicit_normal_published' "$state_dir/accepted-transition" ||
      fail "inactive commit resume did not retain explicit normal phase: $boundary"
    unset HP2R_FIXTURE_RELEASE_OVERRIDE
    exit 0
  fi
  if test "${HP2R_FIXTURE_CASE:-}" = inactive-kernel-rollback; then
    run_controller rollback-boot.sh >/dev/null
    cmp -s "$normal_before" "$root/boot/firmware/config.txt" ||
      fail 'inactive rollback did not restore the prior normal config'
    cmp -s "$prior_kernel_before" "$root$prior_kernel" ||
      fail 'inactive rollback changed the prior conventional kernel'
    cmp -s "$prior_initramfs_before" "$root$prior_initramfs" ||
      fail 'inactive rollback changed the prior conventional initramfs'
    assert_absent "$root/boot/firmware/tryboot.txt"
    assert_absent "$root/var/lib/hyperpixel2r-kms/tryboot-state"
    assert_absent "$root/boot/firmware/$kernel_name"
    assert_absent "$root/boot/firmware/$initramfs_name"
    assert_absent "$root/lib/modules/$candidate_release/extra/hyperpixel2r_kms.ko"
  fi
  if test "${HP2R_FIXTURE_CASE:-}" = inactive-kernel-driver-upgrade; then
    local upgrade_artifact="$root/usr/lib/hyperpixel2r-kms/$candidate_driver_version/$source_revision/$candidate_release"
    test "$candidate_driver_version" != 0.2.0 || fail 'upgrade fixture did not change candidate driver version'
    assert_file "$upgrade_artifact/dkms-prior-state"
    assert_file "$upgrade_artifact/dkms-candidate-state"
    test "$(sed -n '1,3p' "$upgrade_artifact/dkms-prior-state")" = "$(printf '%s\n' \
      'schema_version=2' 'source_state=absent' 'kernel_count=0')" ||
      fail 'upgrade rollback inventory was not the exact absent candidate-version pre-state'
    test "$(sed -n '1,3p' "$upgrade_artifact/dkms-candidate-state")" = "$(printf '%s\n' \
      'schema_version=2' 'source_state=added' 'kernel_count=0')" ||
      fail 'upgrade candidate inventory was not the exact post-registration state'
    grep -Fxq "candidate_driver_version=$candidate_driver_version" "$state_dir/accepted-transition" ||
      fail 'upgrade staged authority did not bind candidate driver version'
    run_controller rollback-boot.sh >/dev/null || fail 'upgrade rollback failed'
    assert_absent "$root/usr/src/hyperpixel2r-kms-$candidate_driver_version"
    assert_file "$root/usr/src/hyperpixel2r-kms-0.2.0/dkms.conf"
    exit 0
  fi
  if test "${HP2R_FIXTURE_CASE:-}" = inactive-kernel-retirement-one; then
    local foreign="$root/boot/firmware/hp2r-foreign-retirement.img"
    printf 'foreign firmware must survive retirement\n' > "$foreign"
    chmod 0644 "$foreign"
    if HP2R_FIXTURE_INTERRUPT_AFTER="$HP2R_FIXTURE_RETIRE_BOUNDARY" \
      HP2R_FIXTURE_PRESERVE_MUTATIONS=1 run_controller rollback-boot.sh >/dev/null 2>&1; then
      fail "inactive retirement ignored interruption: $HP2R_FIXTURE_RETIRE_BOUNDARY"
    fi
    assert_file "$state_dir/rollback-state"
    case "$HP2R_FIXTURE_RETIRE_BOUNDARY" in
      rollback-retirement-phase-published|rollback-retirement-kernel-removed|rollback-retirement-initramfs-removed)
        grep -Fxq 'phase=retiring-firmware' "$state_dir/rollback-state" ||
          fail 'retirement journal did not retain firmware phase'
        ;;
      rollback-retirement-before-state-retired|rollback-retirement-state-retired)
        grep -Fxq 'phase=retiring-state' "$state_dir/rollback-state" ||
          fail 'retirement journal did not retain generic-state phase'
        ;;
    esac
    # The interruption hook models an abrupt process death by disabling the
    # remote EXIT trap.  Retire that fixture-only private workspace explicitly
    # before the fresh process resumes; the durable rollback journal is the
    # only replay authority, and the normal controller invariant remains that
    # no private workspace is silently carried into another operation.
    find "$state_dir" -mindepth 1 -maxdepth 1 -type d -name '.hp2r-transaction.*' \
      -exec rm -rf -- {} +
    assert_no_private_workspaces
    run_controller rollback-boot.sh >/dev/null ||
      fail "inactive retirement did not resume: $HP2R_FIXTURE_RETIRE_BOUNDARY"
    cmp -s "$normal_before" "$root/boot/firmware/config.txt" ||
      fail 'retirement resume changed prior normal config'
    cmp -s "$prior_kernel_before" "$root$prior_kernel" ||
      fail 'retirement resume changed prior conventional kernel'
    cmp -s "$prior_initramfs_before" "$root$prior_initramfs" ||
      fail 'retirement resume changed prior conventional initramfs'
    assert_absent "$root/boot/firmware/$kernel_name"
    assert_absent "$root/boot/firmware/$initramfs_name"
    assert_absent "$state_dir/tryboot-state"
    assert_absent "$state_dir/rollback-state"
    grep -Fxq 'foreign firmware must survive retirement' "$foreign" ||
      fail 'retirement removed unrelated foreign firmware'
    exit 0
  fi
}

exercise_inactive_kernel_explicit_interruptions() {
  local boundary count=0

  for boundary in \
    inactive-explicit-normal-before-phase \
    accepted-transition-phase-prepared \
    accepted-transition-phase-atomic \
    inactive-explicit-normal-published \
    inactive-explicit-normal-state-moved \
    inactive-explicit-normal-state-deleted
  do
    if HP2R_FIXTURE_CASE=inactive-kernel-explicit-interruption-one \
      HP2R_FIXTURE_COMMIT_BOUNDARY="$boundary" bash "${BASH_SOURCE[0]}" >/dev/null; then
      count=$((count + 1))
    else
      fail "inactive explicit interruption fixture failed: $boundary"
    fi
  done
  test "$count" = 6 || fail 'inactive explicit interruption inventory drifted'
}

exercise_inactive_kernel_explicit_prephase_crash() {
  HP2R_FIXTURE_CASE=inactive-kernel-explicit-interruption-one \
    HP2R_FIXTURE_COMMIT_BOUNDARY=inactive-explicit-normal-files-published \
    bash "${BASH_SOURCE[0]}" >/dev/null ||
    fail 'inactive explicit files-published crash did not resume'
}

exercise_inactive_kernel_explicit_prephase_setter_hostile() {
  HP2R_FIXTURE_CASE=inactive-kernel-explicit-interruption-one \
    HP2R_FIXTURE_COMMIT_BOUNDARY=accepted-transition-phase-prepared \
    HP2R_FIXTURE_PREPHASE_SETTER_HOSTILE=current-journal \
    bash "${BASH_SOURCE[0]}" >/dev/null ||
    fail 'inactive explicit pre-phase setter accepted a non-proposed journal'
}

exercise_inactive_kernel_explicit_interfile_crash() {
  HP2R_FIXTURE_CASE=inactive-kernel-explicit-interruption-one \
    HP2R_FIXTURE_COMMIT_BOUNDARY=inactive-explicit-normal-config-published \
    bash "${BASH_SOURCE[0]}" >/dev/null ||
    fail 'inactive explicit config-only crash did not resume'
}

exercise_inactive_kernel_explicit_prior_tryboot_replay() {
  HP2R_FIXTURE_CASE=inactive-kernel-explicit-interruption-one \
    HP2R_FIXTURE_COMMIT_BOUNDARY=inactive-explicit-normal-published \
    HP2R_FIXTURE_PRIOR_TRYBOOT=1 \
    bash "${BASH_SOURCE[0]}" >/dev/null ||
    fail 'inactive explicit replay rejected the restored accepted prior tryboot config'
}

exercise_inactive_kernel_explicit_normal_replay() {
  HP2R_FIXTURE_CASE=inactive-kernel-explicit-interruption-one \
    HP2R_FIXTURE_COMMIT_BOUNDARY=inactive-explicit-normal-published \
    HP2R_FIXTURE_PRIOR_TRYBOOT=1 \
    HP2R_FIXTURE_REPLAY_NORMAL=1 \
    bash "${BASH_SOURCE[0]}" >/dev/null ||
    fail 'inactive explicit normal-boot replay rejected its retired tryboot identity'
}

exercise_commit_readiness_ordering() {
  local case_name count=0

  for case_name in commit-readiness-expiry commit-intent-tuple-drift \
    commit-boot-id-drift commit-root-owned-config-mode; do
    HP2R_FIXTURE_CASE="$case_name" bash "${BASH_SOURCE[0]}" >/dev/null ||
      fail "commit readiness fixture failed: $case_name"
    count=$((count + 1))
  done
  test "$count" = 4 || fail 'commit readiness fixture inventory drifted'
}

exercise_commit_root_owned_config_mode() {
  new_target
  chmod 0600 "$root/boot/firmware/config.txt"
  run_stage >/dev/null
  chmod 0600 "$root/boot/firmware/tryboot.txt"
  install_live_hardware
  run_controller commit-boot.sh >/dev/null
  assert_absent "$root/boot/firmware/tryboot.txt"
  assert_absent "$root/var/lib/hyperpixel2r-kms/tryboot-state"
}

exercise_inactive_kernel_normalization_prephase_crashes() {
  local boundary count=0

  for boundary in \
    inactive-normalize-initramfs-before-phase \
    inactive-normalize-pair-before-phase \
    inactive-normalize-config-before-phase
  do
    if HP2R_FIXTURE_CASE=inactive-kernel-normalization-interruption-one \
      HP2R_FIXTURE_NORMALIZE_BOUNDARY="$boundary" \
      HP2R_FIXTURE_PRESERVE_MUTATIONS=1 \
      bash "${BASH_SOURCE[0]}" >/dev/null; then
      count=$((count + 1))
    else
      fail "normalization pre-phase crash did not resume: $boundary"
    fi
  done
  test "$count" = 3 || fail 'normalization pre-phase crash inventory drifted'
}

exercise_inactive_kernel_normal_module_provenance() {
  local case_name count=0

  for case_name in \
    inactive-kernel-explicit-normal-module-resolution-drift \
    inactive-kernel-normalized-module-resolution-drift
  do
    if HP2R_FIXTURE_CASE="$case_name" bash "${BASH_SOURCE[0]}" >/dev/null; then
      count=$((count + 1))
    else
      fail "normal verification module provenance fixture failed: $case_name"
    fi
  done
  test "$count" = 2 || fail 'normal verification module provenance inventory drifted'
}

exercise_inactive_kernel_explicit_probe_hostile() {
  local hostile count=0

  for hostile in journal hold; do
    if HP2R_FIXTURE_CASE=inactive-kernel-explicit-interruption-one \
      HP2R_FIXTURE_COMMIT_BOUNDARY=inactive-explicit-normal-state-moved \
      HP2R_FIXTURE_REPLAY_HOSTILE="$hostile" bash "${BASH_SOURCE[0]}" >/dev/null; then
      count=$((count + 1))
    else
      fail "inactive explicit replay hostile fixture failed: $hostile"
    fi
  done
  test "$count" = 2 || fail 'inactive explicit replay hostile inventory drifted'
}

exercise_inactive_kernel_normalization_interruptions() {
  local boundary count=0

  for boundary in \
    inactive-normalize-initramfs-published \
    inactive-normalize-pair-published \
    inactive-normalize-config-published
  do
    if HP2R_FIXTURE_CASE=inactive-kernel-normalization-interruption-one \
      HP2R_FIXTURE_NORMALIZE_BOUNDARY="$boundary" \
      bash "${BASH_SOURCE[0]}" >/dev/null; then
      count=$((count + 1))
    else
      fail "normalization interruption fixture failed: $boundary"
    fi
  done
  test "$count" = 3 || fail 'normalization interruption inventory drifted'
}

exercise_inactive_kernel_normalization_setter_boundaries() {
  local boundary count=0

  for boundary in \
    accepted-transition-canonical_initramfs_published-phase-prepared \
    accepted-transition-canonical_initramfs_published-phase-atomic \
    accepted-transition-canonical_pair_published-phase-prepared \
    accepted-transition-canonical_pair_published-phase-atomic \
    accepted-transition-normalized_config_published-phase-prepared \
    accepted-transition-normalized_config_published-phase-atomic
  do
    if HP2R_FIXTURE_CASE=inactive-kernel-normalization-interruption-one \
      HP2R_FIXTURE_NORMALIZE_BOUNDARY="$boundary" \
      bash "${BASH_SOURCE[0]}" >/dev/null; then
      count=$((count + 1))
    else
      fail "normalization setter boundary fixture failed: $boundary"
    fi
  done
  test "$count" = 6 || fail 'normalization setter boundary inventory drifted'
}

exercise_inactive_kernel_verification_phase_atomic_hostiles() {
  local hostile count=0

  for hostile in digest extra mode; do
    if HP2R_FIXTURE_CASE=inactive-kernel-verification-phase-atomic \
      HP2R_FIXTURE_PHASE_SETTER_HOSTILE="$hostile" \
      bash "${BASH_SOURCE[0]}" >/dev/null; then
      count=$((count + 1))
    else
      fail "verification phase-setter hostile fixture failed: $hostile"
    fi
  done
  test "$count" = 3 || fail 'verification phase-setter hostile inventory drifted'
}

exercise_inactive_kernel_normalization_races() {
  local race count=0

  for race in journal bound-leaf; do
    if HP2R_FIXTURE_CASE=inactive-kernel-normalization-race-one \
      HP2R_FIXTURE_NORMALIZATION_RACE="$race" \
      bash "${BASH_SOURCE[0]}" >/dev/null; then
      count=$((count + 1))
    else
      fail "normalization snapshot race failed: $race"
    fi
  done
  test "$count" = 2 || fail 'normalization snapshot race inventory drifted'
}

exercise_inactive_kernel_normalization_phase_hostiles() {
  local phase_case count=0

  for phase_case in \
    initramfs pair config normalized-pair journal phase \
    anchor-drift anchor-missing anchor-symlink
  do
    if HP2R_FIXTURE_CASE=inactive-kernel-normalization-phase-hostile-one \
      HP2R_FIXTURE_NORMALIZATION_PHASE_CASE="$phase_case" \
      bash "${BASH_SOURCE[0]}" >/dev/null; then
      count=$((count + 1))
    else
      fail "normalization phase hostile failed: $phase_case"
    fi
  done
  test "$count" = 9 || fail 'normalization phase hostile inventory drifted'
}

assert_inactive_phase_guards_fail_closed() {
  local function_name body count=0

  for function_name in \
    assert_schema5_explicit_resume_state \
    assert_schema5_staged_authority \
    assert_explicit_inactive_replay_leaves
  do
    body="$(grep -A 35 "^${function_name}()" "$repo_root/scripts/lifecycle-remote.sh")"
    test -n "$body" || fail "missing inactive phase assertion helper: $function_name"
    printf '%s\n' "$body" | grep -Fq '*) return 1 ;;' ||
      fail "inactive phase assertion can inherit a successful status: $function_name"
    count=$((count + 1))
  done
  test "$count" = 3 || fail 'inactive phase assertion inventory drifted'
}

exercise_inactive_kernel_matrix() {
  local hostile count=0

  while IFS= read -r hostile; do
    test -n "$hostile" || continue
    if HP2R_FIXTURE_CASE=inactive-kernel HP2R_FIXTURE_HOSTILE="$hostile" \
      bash "${BASH_SOURCE[0]}" >/dev/null; then
      count=$((count + 1))
      printf 'PASS inactive-kernel hostile %s\n' "$hostile"
      # A case drives the public controller through nested shell/SSH fixture
      # processes.  Let those exact controller processes reap before the next
      # fresh target asks its fail-closed global writer scan.
      sleep 1
    else
      fail "inactive-kernel hostile matrix failed: $hostile"
    fi
  done < <(inactive_hostile_cases)
  test "$count" = "$(inactive_hostile_cases | wc -l | tr -d ' ')" ||
    fail "inactive-kernel hostile matrix count drifted: $count"
  printf 'inactive-kernel hostile matrix passed: %s cases\n' "$count"
}

exercise_inactive_kernel_interruptions() {
  local boundary count=0

  for boundary in \
    candidate-kernel-firmware-published \
    candidate-initramfs-firmware-published \
    candidate-artifact-published \
    candidate-rule-installed \
    candidate-module-installed \
    candidate-overlay-installed \
    candidate-dkms-activated \
    candidate-tryboot-published \
    candidate-tryboot-state-published
  do
    if HP2R_FIXTURE_CASE=inactive-kernel HP2R_FIXTURE_INTERRUPT_AFTER="$boundary" \
      bash "${BASH_SOURCE[0]}" >/dev/null; then
      count=$((count + 1))
    else
      fail "inactive interruption fixture failed: $boundary"
    fi
  done
  test "$count" = 9 || fail 'inactive interruption inventory drifted'
}

exercise_inactive_kernel_retirement_interruptions() {
  local boundary count=0

  for boundary in \
    rollback-retirement-phase-published \
    rollback-retirement-kernel-removed \
    rollback-retirement-initramfs-removed \
    rollback-retirement-before-state-retired \
    rollback-retirement-state-retired
  do
    if HP2R_FIXTURE_CASE=inactive-kernel-retirement-one \
      HP2R_FIXTURE_RETIRE_BOUNDARY="$boundary" bash "${BASH_SOURCE[0]}" >/dev/null; then
      count=$((count + 1))
    else
      fail "inactive retirement fixture failed: $boundary"
    fi
  done
  test "$count" = 5 || fail 'inactive retirement interruption inventory drifted'
}

exercise_inactive_kernel_recovery_phases() {
  local phase count=0

  for phase in prepared staged explicit_normal_published explicit_normal_verified \
    canonical_initramfs_published canonical_pair_published normalized_config_published \
    normalized_verified finalizing receipt_published
  do
    HP2R_FIXTURE_CASE=inactive-kernel-recovery-phase-one \
      HP2R_FIXTURE_RECOVERY_PHASE="$phase" bash "${BASH_SOURCE[0]}" >/dev/null ||
      fail "inactive recovery phase fixture failed: $phase"
    count=$((count + 1))
  done
  test "$count" = 10 || fail 'inactive recovery phase inventory drifted'
}

exercise_inactive_kernel_finalization_interruptions() {
  local boundary count=0

  for boundary in \
    accepted-finalizing-published accepted-receipt-published \
    accepted-receipt-phase-published accepted-prior-retired \
    accepted-candidate-kernel-retired accepted-candidate-initramfs-retired \
    accepted-candidate-leaves-retired accepted-prior-config-retired \
    accepted-prior-kernel-companion-retired \
    accepted-prior-initramfs-companion-retired \
    accepted-candidate-kernel-companion-retired \
    accepted-candidate-initramfs-companion-retired \
    accepted-prepared-anchor-retired accepted-companions-retired \
    accepted-journal-cleared
  do
    HP2R_FIXTURE_CASE=inactive-kernel-finalization-interruption-one \
      HP2R_FIXTURE_FINALIZE_BOUNDARY="$boundary" bash "${BASH_SOURCE[0]}" >/dev/null ||
      fail "inactive finalization interruption fixture failed: $boundary"
    count=$((count + 1))
  done
  test "$count" = 15 || fail 'inactive finalization interruption inventory drifted'
}

exercise_legacy_accepted_upgrade() {
  local legacy_accepted_artifact legacy_accepted_receipt legacy_successor
  local legacy_transition prepare_output

  # A schema-2 accepted receipt predates driver ownership of the backlight
  # rule. Preparing its first capable successor must preserve the schema-5
  # same-kernel protocol while proving the ambient rule state.
  new_target
  run_stage >/dev/null
  install_live_hardware
  run_controller commit-boot.sh >/dev/null
  legacy_accepted_artifact="$root/usr/lib/hyperpixel2r-kms/0.2.0/$source_revision/$release"
  downgrade_artifact_to_schema_one "$legacy_accepted_artifact"
  run_accepted_remote record-accepted 0.2.0 "$source_revision" "$release" >/dev/null
  legacy_accepted_receipt="$root/var/lib/hyperpixel2r-kms/accepted-state"
  grep -Fxq 'schema_version=2' "$legacy_accepted_receipt" ||
    fail 'legacy accepted upgrade fixture is not schema 2'
  legacy_successor='eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'
  prepare_output="$fixture/legacy-accepted-upgrade-prepare.out"
  if HP2R_FIXTURE_INTERRUPT_AFTER=accepted-transition-published \
    run_accepted_remote prepare-new-accepted \
      0.2.0 "$legacy_successor" "$release" "$(printf d%.0s {1..64})" \
      hyperpixel2r_kms.ko "$(printf e%.0s {1..64})" \
      hyperpixel2r-kms-eeeeeeeeeeee.dtbo "$(printf f%.0s {1..64})" \
      "$backlight_rule_file" "$(printf a%.0s {1..64})" \
      exact-backlight-metadata-v1 >"$prepare_output" 2>&1; then
    fail 'legacy accepted upgrade ignored transition publication interruption'
  fi
  legacy_transition="$root/var/lib/hyperpixel2r-kms/accepted-transition"
  if ! grep -Fxq 'schema_version=5' "$legacy_transition"; then
    cat "$prepare_output" >&2
    fail 'legacy accepted upgrade did not publish a schema-5 transition'
  fi
  grep -Fxq 'prior_backlight_rule_existed=false' "$legacy_transition" ||
    fail 'legacy accepted upgrade did not prove the ambient rule was absent'
  grep -Fxq 'prior_tryboot_existed=false' "$legacy_transition" ||
    fail 'legacy accepted upgrade did not prove prior tryboot absence'
  grep -Fxq 'prior_tryboot_sha256=none' "$legacy_transition" ||
    fail 'legacy accepted upgrade did not bind prior tryboot absence'
  assert_absent "$backlight_rule_path"
  run_accepted_remote recover-accepted >/dev/null
  assert_absent "$legacy_transition"
  assert_absent "$root/var/lib/hyperpixel2r-kms/accepted-prior-backlight-rule"
}

exercise_legacy_inactive_backlight_drift_matrix() {
  local specification initial drift count=0

  for specification in \
    absent:appearance present:removal present:symlink present:hash present:mode present:proof
  do
    initial="${specification%%:*}"
    drift="${specification#*:}"
    HP2R_FIXTURE_CASE=inactive-kernel-legacy-backlight-one \
      HP2R_FIXTURE_LEGACY_ACCEPTED=1 \
      HP2R_FIXTURE_LEGACY_BACKLIGHT_INITIAL="$initial" \
      HP2R_FIXTURE_LEGACY_BACKLIGHT_DRIFT="$drift" \
      bash "${BASH_SOURCE[0]}" >/dev/null ||
      fail "inactive legacy backlight drift fixture failed: $drift"
    count=$((count + 1))
  done
  test "$count" = 6 || fail 'inactive legacy backlight drift inventory drifted'
}

exercise_legacy_inactive_post_auth_backlight_drift_matrix() {
  local specification initial drift count=0

  for specification in \
    absent:appearance present:removal present:symlink present:hash present:mode present:proof
  do
    initial="${specification%%:*}"
    drift="${specification#*:}"
    HP2R_FIXTURE_CASE=inactive-kernel-legacy-backlight-one \
      HP2R_FIXTURE_LEGACY_ACCEPTED=1 \
      HP2R_FIXTURE_LEGACY_BACKLIGHT_INITIAL="$initial" \
      HP2R_FIXTURE_LEGACY_POST_AUTH_BACKLIGHT_DRIFT="$drift" \
      bash "${BASH_SOURCE[0]}" >/dev/null ||
      fail "inactive legacy post-authorization backlight drift fixture failed: $drift"
    count=$((count + 1))
  done
  test "$count" = 6 || fail 'inactive legacy post-authorization backlight drift inventory drifted'
  HP2R_FIXTURE_CASE=inactive-kernel-legacy-backlight-one \
    HP2R_FIXTURE_LEGACY_ACCEPTED=1 \
    HP2R_FIXTURE_LEGACY_BACKLIGHT_INITIAL=present \
    HP2R_FIXTURE_LEGACY_POST_AUTH_BACKLIGHT_DRIFT=hash \
    HP2R_FIXTURE_FORGE_STAGE_BACKLIGHT_AUTHORITY=1 \
    bash "${BASH_SOURCE[0]}" >/dev/null ||
    fail 'inactive legacy forged stage backlight authority fixture failed'
}

exercise_inactive_authorization_tuple_shapes() {
  local shape count=0

  for shape in empty-interior trailing-empty leading-empty nonempty-extra
  do
    HP2R_FIXTURE_CASE=inactive-kernel-authorization-tuple-shape-one \
      HP2R_FIXTURE_AUTHORIZATION_TUPLE_SHAPE="$shape" \
      bash "${BASH_SOURCE[0]}" >/dev/null ||
      fail "inactive authorization tuple-shape fixture failed: $shape"
    count=$((count + 1))
  done
  test "$count" = 4 || fail 'inactive malformed authorization tuple inventory drifted'
  HP2R_FIXTURE_CASE=inactive-kernel-authorization-tuple-shape-one \
    HP2R_FIXTURE_AUTHORIZATION_TUPLE_SHAPE=valid \
    bash "${BASH_SOURCE[0]}" >/dev/null ||
    fail 'inactive valid authorization tuple fixture failed'
}

exercise_rollback_transaction_retired_replay() {
  local failure_status

  new_target
  prepare_installed_rollback_shape created transaction-retired-replay
  if HP2R_FIXTURE_DKMS_REJECT_EXTRA_COLLISION=1 \
    HP2R_FIXTURE_INTERRUPT_AFTER=rollback-transaction-retired-unpublished \
    HP2R_FIXTURE_PRESERVE_MUTATIONS=1 \
    run_controller rollback-boot.sh >/dev/null 2>&1; then
    fail 'transaction-retired rollback ignored its interruption'
  else
    failure_status=$?
  fi
  test "$failure_status" = 97 ||
    fail "transaction-retired rollback interruption returned $failure_status"
  assert_file "$root/var/lib/hyperpixel2r-kms/rollback-state"
  assert_absent "$root/var/lib/hyperpixel2r-kms/tryboot-state"
  find "$root/var/lib/hyperpixel2r-kms" -mindepth 1 -maxdepth 1 \
    -type d -name '.hp2r-transaction.*' -exec rm -rf -- {} +
  HP2R_FIXTURE_DKMS_REJECT_EXTRA_COLLISION=1 \
    run_controller rollback-boot.sh >/dev/null
  assert_installed_rollback_shape_restored created \
    rollback-transaction-retired-unpublished
}

assert_inactive_phase_guards_fail_closed

case "${HP2R_FIXTURE_CASE:-}" in
  backlight-udev-settle)
    exercise_backlight_udev_settle
    exit 0
    ;;
  backlight-permission-restore)
    exercise_backlight_permission_restore
    exit 0
    ;;
  backlight-metadata-authority)
    exercise_backlight_metadata_authority
    exit 0
    ;;
  schema-two-candidate-upgrade)
    exercise_schema_two_candidate_upgrade
    exit 0
    ;;
  verify-restricted-path)
    exercise_verify_restricted_path
    exit 0
    ;;
  inactive-kernel-legacy-accepted-present)
    HP2R_FIXTURE_LEGACY_ACCEPTED=1 \
      HP2R_FIXTURE_LEGACY_BACKLIGHT_INITIAL=present \
      exercise_inactive_kernel_prepare
    exit 0
    ;;
  inactive-kernel-legacy-accepted-absent)
    HP2R_FIXTURE_LEGACY_ACCEPTED=1 \
      HP2R_FIXTURE_LEGACY_BACKLIGHT_INITIAL=absent \
      exercise_inactive_kernel_prepare
    exit 0
    ;;
  inactive-kernel-legacy-backlight-drift)
    exercise_legacy_inactive_backlight_drift_matrix
    exit 0
    ;;
  inactive-kernel-legacy-post-auth-backlight-drift)
    exercise_legacy_inactive_post_auth_backlight_drift_matrix
    exit 0
    ;;
  inactive-kernel-legacy-backlight-one)
    exercise_inactive_kernel_prepare
    exit 0
    ;;
  inactive-kernel-authorization-tuple-shapes)
    exercise_inactive_authorization_tuple_shapes
    exit 0
    ;;
  inactive-kernel-authorization-tuple-shape-one)
    exercise_inactive_kernel_prepare
    exit 0
    ;;
  legacy-accepted-upgrade)
    exercise_legacy_accepted_upgrade
    exit 0
    ;;
  rollback-transaction-retired-replay)
    exercise_rollback_transaction_retired_replay
    exit 0
    ;;
  accepted-action-argv)
    exercise_accepted_action_argv_parser
    exit 0
    ;;
  commit-readiness-ordering)
    exercise_commit_readiness_ordering
    exit 0
    ;;
  commit-root-owned-config-mode)
    exercise_commit_root_owned_config_mode
    exit 0
    ;;
  inactive-kernel-explicit-prephase-crash)
    exercise_inactive_kernel_explicit_prephase_crash
    exit 0
    ;;
  inactive-kernel-explicit-prior-tryboot-replay)
    exercise_inactive_kernel_explicit_prior_tryboot_replay
    exit 0
    ;;
  inactive-kernel-normalization-prephase-crashes)
    exercise_inactive_kernel_normalization_prephase_crashes
    exit 0
    ;;
  inactive-kernel-normal-module-provenance)
    exercise_inactive_kernel_normal_module_provenance
    exit 0
    ;;
  inactive-kernel)
    exercise_inactive_kernel_prepare
    for focused_case in inactive-kernel-finalization inactive-kernel-recovery-normalized \
      inactive-kernel-uninstall-orphan inactive-kernel-backlight-policy \
      inactive-kernel-backlight-hostiles inactive-kernel-backlight-capability \
      inactive-kernel-backlight-metadata-race \
      inactive-kernel-backlight-metadata-postwrite; do
      HP2R_FIXTURE_CASE="$focused_case" bash "${BASH_SOURCE[0]}" >/dev/null ||
        fail "focused inactive-kernel fixture failed: $focused_case"
    done
    HP2R_FIXTURE_CASE=inactive-kernel-finalization-interruption-one \
      HP2R_FIXTURE_FINALIZE_BOUNDARY=accepted-candidate-kernel-retired \
      bash "${BASH_SOURCE[0]}" >/dev/null ||
      fail 'focused inactive-kernel finalization replay failed'
    exit 0
    ;;
  inactive-kernel-state-digest)
    exercise_inactive_kernel_prepare
    exit 0
    ;;
  inactive-kernel-base-vc4)
    exercise_inactive_kernel_prepare
    exit 0
    ;;
  inactive-kernel-platform-overlays)
    exercise_inactive_kernel_prepare
    exit 0
    ;;
  inactive-kernel-foreign-firmware)
    exercise_inactive_kernel_prepare
    exit 0
    ;;
  inactive-kernel-interruptions)
    exercise_inactive_kernel_interruptions
    exit 0
    ;;
  inactive-kernel-rollback)
    exercise_inactive_kernel_prepare
    exit 0
    ;;
  inactive-kernel-post-phase-failure)
    exercise_inactive_kernel_prepare
    exit 0
    ;;
  inactive-kernel-retirement-interruptions)
    exercise_inactive_kernel_retirement_interruptions
    exit 0
    ;;
  inactive-kernel-recovery-phases)
    exercise_inactive_kernel_recovery_phases
    exit 0
    ;;
  inactive-kernel-finalization-interruptions)
    exercise_inactive_kernel_finalization_interruptions
    exit 0
    ;;
  inactive-kernel-retirement-one)
    exercise_inactive_kernel_prepare
    exit 0
    ;;
  inactive-kernel-explicit-interruptions)
    exercise_inactive_kernel_explicit_interruptions
    exit 0
    ;;
  inactive-kernel-explicit-probe-hostile)
    exercise_inactive_kernel_explicit_probe_hostile
    exit 0
    ;;
  inactive-kernel-explicit-interfile-crash)
    exercise_inactive_kernel_explicit_interfile_crash
    exit 0
    ;;
  inactive-kernel-explicit-prephase-setter-hostile)
    exercise_inactive_kernel_explicit_prephase_setter_hostile
    exit 0
    ;;
  inactive-kernel-explicit-normal-replay)
    exercise_inactive_kernel_explicit_normal_replay
    exit 0
    ;;
  inactive-kernel-normalization-interruptions)
    exercise_inactive_kernel_normalization_interruptions
    exit 0
    ;;
  inactive-kernel-normalization-setter-boundaries)
    exercise_inactive_kernel_normalization_setter_boundaries
    exit 0
    ;;
  inactive-kernel-verification-phase-atomic-hostiles)
    exercise_inactive_kernel_verification_phase_atomic_hostiles
    exit 0
    ;;
  inactive-kernel-normalization-races)
    exercise_inactive_kernel_normalization_races
    exit 0
    ;;
  inactive-kernel-normalization-post-atomic)
    exercise_inactive_kernel_prepare
    exit 0
    ;;
  inactive-kernel-normalization-phase-hostiles)
    exercise_inactive_kernel_normalization_phase_hostiles
    exit 0
    ;;
  inactive-kernel-normalized-unhealthy)
    exercise_inactive_kernel_prepare
    exit 0
    ;;
  inactive-kernel-driver-upgrade)
    exercise_inactive_kernel_prepare
    exit 0
    ;;
  commit-readiness-expiry|commit-intent-tuple-drift|commit-boot-id-drift|inactive-kernel-phase-authority-drift|inactive-kernel-final-module-drift|inactive-kernel-final-artifact-drift|inactive-kernel-final-dkms-drift|inactive-kernel-setter-snapshot|inactive-kernel-stale-authority|inactive-kernel-hostile-env|inactive-kernel-commit-rejected|inactive-kernel-explicit-promotion|inactive-kernel-explicit-normal-verified|inactive-kernel-explicit-normal-unhealthy|inactive-kernel-explicit-normal-conventional-drift|inactive-kernel-explicit-normal-vermagic-prefix|inactive-kernel-explicit-normal-module-resolution-drift|inactive-kernel-normalized-module-resolution-drift|inactive-kernel-normalization|inactive-kernel-finalization|inactive-kernel-finalization-interruption-one|inactive-kernel-recovery-normalized|inactive-kernel-recovery-phase-one|inactive-kernel-uninstall-orphan|inactive-kernel-backlight-policy|inactive-kernel-backlight-hostiles|inactive-kernel-backlight-capability|inactive-kernel-backlight-metadata-race|inactive-kernel-backlight-metadata-postwrite|inactive-kernel-normalization-interruption-one|inactive-kernel-normalization-race-one|inactive-kernel-normalization-post-atomic|inactive-kernel-verification-phase-atomic|inactive-kernel-verification-phase-prepared|inactive-kernel-normalized-unhealthy|inactive-kernel-normalization-phase-hostile-one|inactive-kernel-explicit-interruption-one|inactive-kernel-transport-ancestor)
    exercise_inactive_kernel_prepare
    exit 0
    ;;
  inactive-kernel-matrix)
    exercise_inactive_kernel_matrix
    exit 0
    ;;
  task3-authority)
    exercise_task3_aligned_authority
    exit 0
    ;;
  inactive-uninstall-backlight)
    exercise_inactive_uninstall_backlight_matrix
    exit 0
    ;;
  prior-absent-uninstall-proof)
    exercise_prior_absent_accepted_uninstall_proof_guard
    exit 0
    ;;
  accepted-prior-tryboot)
    exercise_accepted_prior_tryboot_authority
    exit 0
    ;;
  accepted-prior-committed-recovery)
    exercise_accepted_prior_committed_recovery
    exit 0
    ;;
  smoke)
    new_target
    run_stage --stage-only >/dev/null
    assert_backlight_rule_installed
    assert_file "$root/boot/firmware/tryboot.txt"
    exit 0
    ;;
  '')
    exercise_inactive_uninstall_backlight_matrix
    exercise_prior_absent_accepted_uninstall_proof_guard
    exercise_inactive_kernel_recovery_phases
    exercise_inactive_kernel_finalization_interruptions
    ;;
  *) fail "unknown fixture case: $HP2R_FIXTURE_CASE" ;;
esac

# RED contract: a declaration with parameters is still exactly one declaration
# of the requested overlay.  The candidate must replace it, not leave it in
# addition to the generic HyperPixel overlay.
new_target
run_stage --stage-only >/dev/null
assert_backlight_rule_installed
assert_file "$root/boot/firmware/tryboot.txt"
assert_file "$root/var/lib/hyperpixel2r-kms/tryboot-state"
if grep -Fxq 'tryboot-reboot' "$log"; then
  fail 'stage-only requested a tryboot reboot'
fi
assert_absent "$root/proc/device-tree/chosen/bootloader/tryboot"
run_controller rollback-boot.sh >/dev/null
assert_absent "$backlight_rule_path"

# Candidate permission state is transactional. A process death after the rule
# is installed must be recoverable without retaining candidate permissions.
new_target
if HP2R_FIXTURE_INTERRUPT_AFTER=candidate-rule-installed run_stage >/dev/null 2>&1; then
  fail 'stage ignored interruption after installing the backlight rule'
fi
assert_clean_failed_stage

# A preexisting exact path is distinct user state. Candidate rollback must
# restore its byte identity rather than deleting or replacing it permanently.
new_target
printf 'fixture prior backlight policy\n' > "$backlight_rule_path"
chown root:root "$backlight_rule_path"
chmod 0644 "$backlight_rule_path"
prior_rule_sha="$(sha256sum "$backlight_rule_path" | awk '{ print $1 }')"
run_stage >/dev/null
assert_backlight_rule_installed
run_controller rollback-boot.sh >/dev/null
test "$(sha256sum "$backlight_rule_path" | awk '{ print $1 }')" = "$prior_rule_sha" ||
  fail 'rollback did not restore the proven prior backlight rule'

new_target
if run_stage; then
  candidate="$root/boot/firmware/tryboot.txt"
  assert_file "$candidate"
  old_count="$(grep -Ec '^[[:space:]]*dtoverlay=vc4-kms-dpi-hyperpixel2r([,[:space:]]|$)' "$candidate" || true)"
  generic_count="$(grep -Ec '^[[:space:]]*dtoverlay=hyperpixel2r-kms-' "$candidate" || true)"
  test "$old_count" = 0 && test "$generic_count" = 1 ||
    fail 'parameterized replacement left a second display overlay'
else
  fail 'baseline stage did not run in the disposable target'
fi
test "$(cat "$root/tmp/remote-uid")" = 65534 || fail 'fake target did not execute as an unprivileged SSH user'

# Real OpenSSH reconstructs the remote command through a shell and does not
# preserve empty argument slots.  The verifier's optional expectations must
# remain optional across that boundary.
new_target
run_stage >/dev/null
install_live_hardware
if ! HP2R_FIXTURE_DROP_EMPTY_SSH_ARGS=1 run_verify >/dev/null; then
  fail 'verify lost optional empty expectations across the OpenSSH command boundary'
fi

# A stock normal config has no display overlay to replace.  Real OpenSSH
# reconstructs the remote command through a shell and drops the trailing empty
# replacement argument, so the remote stage interface must treat an absent
# ninth argument as the intentional no-replacement case.
new_target
sed -i '/dtoverlay=vc4-kms-dpi-hyperpixel2r/d' \
  "$root/boot/firmware/config.txt"
if ! HP2R_FIXTURE_DROP_EMPTY_SSH_ARGS=1 \
  HP2R_FIXTURE_REPLACE_OVERLAY='' run_stage >/dev/null; then
  fail 'stage lost the empty replacement across the OpenSSH command boundary'
fi
assert_file "$root/boot/firmware/tryboot.txt"
grep -Fqx "dtoverlay=$overlay_file" "$root/boot/firmware/tryboot.txt" ||
  fail 'stage did not publish the generic overlay without a replacement'

# Raspberry Pi firmware is normally VFAT with fmask=0022, so chmod 0644 still
# reports mode 0755.  Publishing a boot artifact must accept that mount mode.
new_target
if HP2R_FIXTURE_BOOT_MODE=755 run_stage; then
  assert_file "$root/boot/firmware/tryboot.txt"
  assert_file "$root/boot/firmware/overlays/$overlay_file"
  install_live_hardware
  if HP2R_FIXTURE_BOOT_MODE=755 run_controller commit-boot.sh; then
    grep -Eq "^dtoverlay=hyperpixel2r-kms-[0-9a-f]{12}\.dtbo[[:space:]]*$" \
      "$root/boot/firmware/config.txt" ||
      fail 'commit did not publish the accepted overlay on the VFAT fixture'
    assert_absent "$root/boot/firmware/tryboot.txt"
    assert_absent "$root/var/lib/hyperpixel2r-kms/tryboot-state"
  else
    fail 'commit rejected the Raspberry Pi VFAT boot-file mode'
  fi
else
  fail 'stage rejected the Raspberry Pi VFAT boot-file mode'
fi

# Commit is the first post-reboot acceptance gate.  A published permission
# rule without the named backlight device is not an operational candidate.
new_target
run_stage >/dev/null
install_live_hardware
rm -rf -- "$root/sys/class/backlight/planeradar-backlight"
if run_controller commit-boot.sh >/dev/null 2>&1; then
  fail 'commit accepted a missing named backlight device'
fi
assert_file "$root/var/lib/hyperpixel2r-kms/tryboot-state"
assert_backlight_rule_installed

# Every operation after record-accepted allocates its private workspace has a
# distinct failure boundary.  Before either accepted leaf is published, the
# failure must leave no durable receipt or stock candidate and no workspace.
for record_fault in \
  normal-snapshot stock-allocation stock-derivation receipt-allocation \
  receipt-write stock-publication
do
  prepare_record_failure_target
  export HP2R_FIXTURE_FAIL_RECORD_OPERATION="$record_fault"
  if run_accepted_remote record-accepted 0.2.0 "$source_revision" "$release" \
    > "$fixture/record-fault-$record_fault.out" 2>&1; then
    fail "accepted record ignored injected $record_fault failure"
  fi
  unset HP2R_FIXTURE_FAIL_RECORD_OPERATION
  assert_file "$root/tmp/record-fault-$record_fault"
  assert_record_prepublication_failure
done

# Once a leaf has been atomically published, subsequent failures must preserve
# the existing fail-closed authority shape while still removing the private
# recorder workspace.  A stock-only leaf remains an orphan and blocks replay;
# a complete receipt remains idempotently accepted.
prepare_record_failure_target
export HP2R_FIXTURE_FAIL_RECORD_OPERATION=receipt-publication
if run_accepted_remote record-accepted 0.2.0 "$source_revision" "$release" \
  > "$fixture/record-fault-receipt-publication.out" 2>&1; then
  fail 'accepted record ignored injected receipt-publication failure'
fi
unset HP2R_FIXTURE_FAIL_RECORD_OPERATION
assert_file "$root/tmp/record-fault-receipt-publication"
assert_no_private_workspaces
assert_absent "$root/var/lib/hyperpixel2r-kms/accepted-state"
assert_file "$root/var/lib/hyperpixel2r-kms/accepted-stock-config.txt"
assert_record_target_unchanged
if run_accepted_remote record-accepted 0.2.0 "$source_revision" "$release" >/dev/null 2>&1; then
  fail 'accepted record resumed through an orphan accepted stock config'
fi

for record_fault in workspace-removal sync final-receipt-validation; do
  prepare_record_failure_target
  export HP2R_FIXTURE_FAIL_RECORD_OPERATION="$record_fault"
  if run_accepted_remote record-accepted 0.2.0 "$source_revision" "$release" \
    > "$fixture/record-fault-$record_fault.out" 2>&1; then
    fail "accepted record ignored injected $record_fault failure"
  fi
  unset HP2R_FIXTURE_FAIL_RECORD_OPERATION
  assert_file "$root/tmp/record-fault-$record_fault"
  assert_no_private_workspaces
  assert_file "$root/var/lib/hyperpixel2r-kms/accepted-state"
  assert_file "$root/var/lib/hyperpixel2r-kms/accepted-stock-config.txt"
  assert_record_target_unchanged
  run_accepted_remote record-accepted 0.2.0 "$source_revision" "$release" >/dev/null
done

# RC18's healthy normal boot had accumulated three exact owned markers.  Keep
# a byte-exact legacy copy, and require stage/commit to retain every unrelated
# byte in order while replacing the owned declaration and canonical marker.
new_target
legacy_normal="$fixture/legacy-normal-config.txt"
legacy_normal_original="$fixture/legacy-normal-original.txt"
legacy_stage_expected="$fixture/legacy-stage-expected.txt"
legacy_commit_expected="$fixture/legacy-commit-expected.txt"
legacy_stock_expected="$fixture/legacy-stock-expected.txt"
printf '%s\n' \
  '[all]' \
  '# unrelated comment before accepted ownership' \
  'dtoverlay=vc4-kms-v3d' \
  'dtparam=audio=on' \
  '[pi4]' \
  '# hyperpixel2r-kms accepted candidate' \
  '# hyperpixel2r-kms accepted candidate' \
  '# hyperpixel2r-kms accepted candidate' \
  '# hyperpixel2r-kms accepted candidate (historical note)' \
  '# hyperpixel2r-kms accepted-candidate' \
  "dtoverlay=$overlay_file" \
  '# unrelated comment after accepted ownership' \
  'disable_overscan=1' \
  'dtoverlay=vc4-fkms-v3d' \
  > "$legacy_normal"
cp "$legacy_normal" "$legacy_normal_original"
printf '%s\n' \
  '[all]' \
  '# unrelated comment before accepted ownership' \
  'dtoverlay=vc4-kms-v3d' \
  'dtparam=audio=on' \
  '[pi4]' \
  '# hyperpixel2r-kms accepted candidate (historical note)' \
  '# hyperpixel2r-kms accepted-candidate' \
  '# unrelated comment after accepted ownership' \
  'disable_overscan=1' \
  'dtoverlay=vc4-fkms-v3d' \
  '' \
  '# hyperpixel2r-kms one-shot candidate' \
  "dtoverlay=$overlay_file" \
  > "$legacy_stage_expected"
printf '%s\n' \
  '[all]' \
  '# unrelated comment before accepted ownership' \
  'dtoverlay=vc4-kms-v3d' \
  'dtparam=audio=on' \
  '[pi4]' \
  '# hyperpixel2r-kms accepted candidate (historical note)' \
  '# hyperpixel2r-kms accepted-candidate' \
  '# unrelated comment after accepted ownership' \
  'disable_overscan=1' \
  'dtoverlay=vc4-fkms-v3d' \
  '' \
  '# hyperpixel2r-kms accepted candidate' \
  "dtoverlay=$overlay_file" \
  > "$legacy_commit_expected"
printf '%s\n' \
  '[all]' \
  '# unrelated comment before accepted ownership' \
  'dtoverlay=vc4-kms-v3d' \
  'dtparam=audio=on' \
  '[pi4]' \
  '# hyperpixel2r-kms accepted candidate (historical note)' \
  '# hyperpixel2r-kms accepted-candidate' \
  '# unrelated comment after accepted ownership' \
  'disable_overscan=1' \
  'dtoverlay=vc4-fkms-v3d' \
  > "$legacy_stock_expected"
cp "$legacy_normal" "$root/boot/firmware/config.txt"
chown root:root "$root/boot/firmware/config.txt"
chmod 0644 "$root/boot/firmware/config.txt"
export HP2R_FIXTURE_REPLACE_OVERLAY="$overlay_file"
run_stage >/dev/null
unset HP2R_FIXTURE_REPLACE_OVERLAY
cmp -s "$legacy_normal_original" "$root/boot/firmware/config.txt" ||
  fail 'stage changed the legacy normal config'
candidate="$root/boot/firmware/tryboot.txt"
cmp -s "$legacy_stage_expected" "$candidate" ||
  fail 'stage did not canonicalize the legacy candidate exactly'
assert_exact_line_count "$candidate" "dtoverlay=$overlay_file" 1
assert_exact_line_count "$candidate" '# hyperpixel2r-kms accepted candidate' 0
assert_exact_line_count "$candidate" '# hyperpixel2r-kms one-shot candidate' 1
assert_no_foreign_hyperpixel_overlay "$candidate" "$overlay_file"
install_live_hardware
run_controller commit-boot.sh >/dev/null
cmp -s "$legacy_commit_expected" "$root/boot/firmware/config.txt" ||
  fail 'commit did not canonicalize the legacy normal config exactly'
assert_exact_line_count "$root/boot/firmware/config.txt" "dtoverlay=$overlay_file" 1
assert_exact_line_count "$root/boot/firmware/config.txt" '# hyperpixel2r-kms accepted candidate' 1
assert_no_foreign_hyperpixel_overlay "$root/boot/firmware/config.txt" "$overlay_file"

# Record accepts the unmodified live legacy shape and publishes only the
# derived stock boot config, binding both byte-exact config hashes in receipt.
cp "$legacy_normal_original" "$root/boot/firmware/config.txt"
chown root:root "$root/boot/firmware/config.txt"
chmod 0644 "$root/boot/firmware/config.txt"
run_accepted_remote record-accepted 0.2.0 "$source_revision" "$release" >/dev/null
accepted_receipt="$root/var/lib/hyperpixel2r-kms/accepted-state"
stock_config="$root/var/lib/hyperpixel2r-kms/accepted-stock-config.txt"
cmp -s "$legacy_normal_original" "$root/boot/firmware/config.txt" ||
  fail 'accepted record changed the legacy normal config'
cmp -s "$legacy_stock_expected" "$stock_config" ||
  fail 'accepted record did not derive the exact legacy stock config'
legacy_normal_sha="$(sha256sum "$legacy_normal_original" | awk '{ print $1 }')"
legacy_stock_sha="$(sha256sum "$legacy_stock_expected" | awk '{ print $1 }')"
grep -Fxq "normal_config_sha256=$legacy_normal_sha" "$accepted_receipt" ||
  fail 'accepted record did not bind the unchanged legacy normal config'
grep -Fxq "stock_config_sha256=$legacy_stock_sha" "$accepted_receipt" ||
  fail 'accepted record did not bind the derived legacy stock config'

# The public controller must accept exactly the recovery identity and forward
# it untouched. The empty target then rejects the forwarded action because no
# exact installed tuple or recovery workspace exists there.
new_target
if run_accepted_controller >"$fixture/recover-record-controller.out" 2>&1; then
  fail 'recover-record controller unexpectedly accepted an empty target'
fi
controller_command="$fixture/recover-record-controller-command"
printf '%s\n' recover-accepted-record 0.2.0 "$source_revision" "$release" > "$controller_command"
cmp -s "$controller_command" "$root/tmp/accepted-controller-remote-command" ||
  fail 'recover-record controller did not forward the exact remote command'

# Reconstruct the one live-shaped legacy orphan: exact installed tuple and
# normal boot, no durable lifecycle authority, and only the two root-private
# recorder snapshots.  A valid recovery must remove only that workspace, sync,
# and never publish an accepted receipt.
prepare_recoverable_record_orphan
recovery_find_before="$fixture/recover-record-find-before.tar"
recovery_find_after="$fixture/recover-record-find-after.tar"
capture_recovery_target "$recovery_find_before"
if HP2R_FIXTURE_FAIL_RECOVERY_FIND=state \
  run_accepted_remote recover-accepted-record 0.2.0 "$source_revision" "$release" \
    >"$fixture/recover-record-find.out" 2>&1; then
  fail 'recover-record accepted an unreadable workspace enumeration'
fi
assert_exact_recoverable_record_orphan
capture_recovery_target "$recovery_find_after"
cmp -s "$recovery_find_before" "$recovery_find_after" ||
  fail 'recover-record mutated state after workspace enumeration failure'

prepare_recoverable_record_orphan
recovery_leaves_before="$fixture/recover-record-leaves-before.tar"
recovery_leaves_after="$fixture/recover-record-leaves-after.tar"
capture_recovery_target "$recovery_leaves_before"
if HP2R_FIXTURE_FAIL_RECOVERY_FIND=leaves \
  run_accepted_remote recover-accepted-record 0.2.0 "$source_revision" "$release" \
    >"$fixture/recover-record-leaves.out" 2>&1; then
  fail 'recover-record accepted an unreadable workspace leaf enumeration'
fi
assert_exact_recoverable_record_orphan
capture_recovery_target "$recovery_leaves_after"
cmp -s "$recovery_leaves_before" "$recovery_leaves_after" ||
  fail 'recover-record mutated state after workspace leaf enumeration failure'

prepare_recoverable_record_orphan
recover_success_before="$fixture/recover-record-success-preserved-before.tar"
recover_success_after="$fixture/recover-record-success-preserved-after.tar"
capture_recovery_preserved_target "$recover_success_before"
if ! HP2R_FIXTURE_RECOVER_SYNC=1 \
  run_accepted_remote recover-accepted-record 0.2.0 "$source_revision" "$release" \
    >"$fixture/recover-record-exact.out" 2>&1; then
  cat "$fixture/recover-record-exact.out" >&2
  fail 'recover-record did not recover exact workspace'
fi
assert_absent "$recover_workspace"
assert_no_private_workspaces
assert_recovery_no_receipt
assert_file "$root/tmp/recover-record-sync"
capture_recovery_preserved_target "$recover_success_after"
cmp -s "$recover_success_before" "$recover_success_after" ||
  fail 'recover-record success broadly mutated unrelated target state'

# Once the exact workspace is gone, a repeat is a verified no-op: no receipt,
# no fresh workspace, and no broad state cleanup.
recover_noop_before="$fixture/recover-record-noop-before.tar"
recover_noop_after="$fixture/recover-record-noop-after.tar"
capture_recovery_target "$recover_noop_before"
run_accepted_remote recover-accepted-record 0.2.0 "$source_revision" "$release" >/dev/null
assert_no_private_workspaces
assert_recovery_no_receipt
capture_recovery_target "$recover_noop_after"
cmp -s "$recover_noop_before" "$recover_noop_after" ||
  fail 'recover-record idempotent replay mutated target state'

# A process interruption on either side of removal is replay-safe.  Before
# removal the exact orphan survives for a later recovery; after removal the
# same rerun is the verified no-op above.
for recover_boundary in recover-record-before-removal recover-record-after-removal; do
  prepare_recoverable_record_orphan
  recover_interrupt_full_before="$fixture/$recover_boundary-full-before.tar"
  recover_interrupt_full_after="$fixture/$recover_boundary-full-after.tar"
  recover_interrupt_preserved_before="$fixture/$recover_boundary-preserved-before.tar"
  recover_interrupt_preserved_after="$fixture/$recover_boundary-preserved-after.tar"
  recover_interrupt_replay_before="$fixture/$recover_boundary-replay-before.tar"
  recover_interrupt_replay_after="$fixture/$recover_boundary-replay-after.tar"
  capture_recovery_target "$recover_interrupt_full_before"
  capture_recovery_preserved_target "$recover_interrupt_preserved_before"
  recover_status=0
  if HP2R_FIXTURE_INTERRUPT_AFTER="$recover_boundary" \
    run_accepted_remote recover-accepted-record 0.2.0 "$source_revision" "$release" \
      >"$fixture/$recover_boundary.out" 2>&1; then
    fail "recover-record ignored interruption at $recover_boundary"
  else
    recover_status=$?
  fi
  test "$recover_status" = 97 ||
    fail "recover-record interruption at $recover_boundary returned $recover_status"
  case "$recover_boundary" in
    recover-record-before-removal)
      assert_exact_recoverable_record_orphan
      capture_recovery_target "$recover_interrupt_full_after"
      cmp -s "$recover_interrupt_full_before" "$recover_interrupt_full_after" ||
        fail 'recover-record pre-removal interruption mutated target state'
      ;;
    recover-record-after-removal)
      assert_absent "$recover_workspace"
      assert_no_private_workspaces
      capture_recovery_preserved_target "$recover_interrupt_preserved_after"
      cmp -s "$recover_interrupt_preserved_before" "$recover_interrupt_preserved_after" ||
        fail 'recover-record post-removal interruption broadly mutated target state'
      capture_recovery_target "$recover_interrupt_replay_before"
      ;;
  esac
  run_accepted_remote recover-accepted-record 0.2.0 "$source_revision" "$release" >/dev/null
  assert_no_private_workspaces
  assert_recovery_no_receipt
  capture_recovery_preserved_target "$recover_interrupt_preserved_after"
  cmp -s "$recover_interrupt_preserved_before" "$recover_interrupt_preserved_after" ||
    fail "recover-record replay after $recover_boundary broadly mutated target state"
  if test "$recover_boundary" = recover-record-after-removal; then
    capture_recovery_target "$recover_interrupt_replay_after"
    cmp -s "$recover_interrupt_replay_before" "$recover_interrupt_replay_after" ||
      fail 'recover-record post-removal no-op replay mutated target state'
  fi
done

# Replacing the exact orphan while the verifier workspace is being removed is
# a concurrent authority change, not an invitation to delete the replacement.
prepare_recoverable_record_orphan
recovery_replacement="$root/var/lib/hyperpixel2r-kms/.hp2r-transaction.ReplacementFixture"
if HP2R_FIXTURE_RECOVERY_SWAP_WORKSPACE=1 \
  run_accepted_remote recover-accepted-record 0.2.0 "$source_revision" "$release" \
    >"$fixture/recover-record-workspace-swap.out" 2>&1; then
  fail 'recover-record accepted a replacement workspace after validation'
fi
assert_file "$root/tmp/recovery-workspace-swapped"
assert_absent "$root/var/lib/hyperpixel2r-kms/.hp2r-transaction.WorkspaceFixture"
test "$(stat -c '%U:%G:%a' "$recovery_replacement")" = root:root:700 ||
  fail 'recovery workspace replacement metadata changed'
cmp -s "$recovery_replacement/.hp2r-accepted-normal.SnapshotFixture" \
  "$root/boot/firmware/config.txt" ||
  fail 'recovery workspace replacement normal snapshot changed'
cmp -s "$recovery_replacement/accepted-stock" "$recover_derived_stock" ||
  fail 'recovery workspace replacement stock snapshot changed'
test "$(find "$root/var/lib/hyperpixel2r-kms" -mindepth 1 -maxdepth 1 \
  -name '.hp2r-transaction.*' -print | wc -l | tr -d ' ')" = 1 ||
  fail 'recovery workspace replacement did not remain the sole workspace'
assert_recovery_no_receipt

# The accepted-normal snapshot has its own mktemp suffix. A same-byte rename
# after verifier cleanup must fail identity revalidation before orphan removal.
prepare_recoverable_record_orphan
recovery_normal_replacement="$recover_workspace/.hp2r-accepted-normal.ReplacementSnapshot"
if HP2R_FIXTURE_RECOVERY_SWAP_NORMAL_LEAF=1 \
  run_accepted_remote recover-accepted-record 0.2.0 "$source_revision" "$release" \
    >"$fixture/recover-record-normal-leaf-swap.out" 2>&1; then
  fail 'recover-record accepted a replacement normal snapshot after validation'
fi
assert_file "$root/tmp/recovery-normal-leaf-swapped"
assert_absent "$recover_workspace/.hp2r-accepted-normal.SnapshotFixture"
assert_file "$recovery_normal_replacement"
test "$(stat -c '%U:%G:%a' "$recovery_normal_replacement")" = root:root:600 ||
  fail 'recovery normal snapshot replacement metadata changed'
cmp -s "$recovery_normal_replacement" "$root/boot/firmware/config.txt" ||
  fail 'recovery normal snapshot replacement bytes changed'
cmp -s "$recover_workspace/accepted-stock" "$recover_derived_stock" ||
  fail 'recovery normal snapshot replacement changed stock'
test "$(stat -c '%U:%G:%a' "$recover_workspace")" = root:root:700 ||
  fail 'recovery normal snapshot replacement changed workspace metadata'
assert_recovery_no_receipt

# Any existing lifecycle authority makes the orphan ambiguous.  Every reject
# preserves the complete state-directory archive byte-for-byte, including the
# orphan leaves, and cannot publish an accepted receipt.
for recovery_authority in \
  tryboot-state rollback-state rollback-candidate-dkms-state \
  rollback-candidate-tryboot.txt accepted-state accepted-stock-config.txt \
  accepted-transition accepted-transition-prior-config.txt accepted-uninstall \
  accepted-transition-prior-tryboot.txt accepted-uninstall-stock.txt
do
  prepare_recoverable_record_orphan
  printf 'conflicting recovery authority\n' > "$root/var/lib/hyperpixel2r-kms/$recovery_authority"
  assert_recovery_rejection_preserves_state "authority-$recovery_authority"
done
prepare_recoverable_record_orphan
second_workspace="$root/var/lib/hyperpixel2r-kms/.hp2r-transaction.SecondWorkspace"
second_normal="$second_workspace/.hp2r-accepted-normal.SecondSnapshot"
mkdir "$second_workspace"
cp "$root/boot/firmware/config.txt" "$second_normal"
cp "$recover_derived_stock" "$second_workspace/accepted-stock"
chown root:root "$second_workspace" "$second_normal" "$second_workspace/accepted-stock"
chmod 0700 "$second_workspace"
chmod 0600 "$second_normal" "$second_workspace/accepted-stock"
assert_recovery_rejection_preserves_state authority-multiple-workspaces

# Hostile workspaces and leaves must be rejected independently.  The saved
# state archive proves both the original orphan and every hostile leaf remain
# byte-identical after each nonzero result.
for hostile_workspace in \
  unsafe-suffix symlink-workspace workspace-owner workspace-mode nondirectory \
  extra-leaf missing-leaf symlink-leaf leaf-owner leaf-mode leaf-type \
  multiple-normal changed-normal changed-stock
do
  prepare_recoverable_record_orphan
  case "$hostile_workspace" in
    unsafe-suffix)
      recover_workspace="$root/var/lib/hyperpixel2r-kms/.hp2r-transaction.unsafe-suffix"
      mv "$root/var/lib/hyperpixel2r-kms/.hp2r-transaction.WorkspaceFixture" "$recover_workspace"
      ;;
    symlink-workspace)
      symlink_workspace_target="$root/recovery-symlink-workspace-target"
      symlink_workspace_normal="$symlink_workspace_target/.hp2r-accepted-normal.SymlinkSnapshot"
      mkdir "$symlink_workspace_target"
      cp "$root/boot/firmware/config.txt" "$symlink_workspace_normal"
      cp "$recover_derived_stock" "$symlink_workspace_target/accepted-stock"
      chown root:root "$symlink_workspace_target" "$symlink_workspace_normal" \
        "$symlink_workspace_target/accepted-stock"
      chmod 0700 "$symlink_workspace_target"
      chmod 0600 "$symlink_workspace_normal" "$symlink_workspace_target/accepted-stock"
      rm -rf -- "$recover_workspace"
      ln -s "$symlink_workspace_target" "$recover_workspace"
      ;;
    workspace-owner) chown 65534:65534 "$recover_workspace" ;;
    workspace-mode) chmod 0755 "$recover_workspace" ;;
    nondirectory)
      rm -rf -- "$recover_workspace"
      printf 'not a workspace\n' > "$recover_workspace"
      chown root:root "$recover_workspace"
      chmod 0700 "$recover_workspace"
      ;;
    extra-leaf)
      printf 'unexpected\n' > "$recover_workspace/unexpected-leaf"
      chown root:root "$recover_workspace/unexpected-leaf"
      chmod 0600 "$recover_workspace/unexpected-leaf"
      ;;
    missing-leaf) rm -f -- "$recover_workspace/accepted-stock" ;;
    symlink-leaf)
      symlink_leaf_target="$root/recovery-symlink-leaf-target"
      cp "$recover_derived_stock" "$symlink_leaf_target"
      chown root:root "$symlink_leaf_target"
      chmod 0600 "$symlink_leaf_target"
      rm -f -- "$recover_workspace/accepted-stock"
      ln -s "$symlink_leaf_target" "$recover_workspace/accepted-stock"
      ;;
    leaf-owner) chown 65534:65534 "$recover_workspace/accepted-stock" ;;
    leaf-mode) chmod 0644 "$recover_workspace/accepted-stock" ;;
    leaf-type)
      rm -f -- "$recover_workspace/accepted-stock"
      mkdir "$recover_workspace/accepted-stock"
      chown root:root "$recover_workspace/accepted-stock"
      chmod 0600 "$recover_workspace/accepted-stock"
      ;;
    multiple-normal)
      cp "$recover_normal_snapshot" \
        "$recover_workspace/.hp2r-accepted-normal.SecondFixture"
      chown root:root "$recover_workspace/.hp2r-accepted-normal.SecondFixture"
      chmod 0600 "$recover_workspace/.hp2r-accepted-normal.SecondFixture"
      ;;
    changed-normal) printf 'snapshot drift\n' >> "$recover_normal_snapshot" ;;
    changed-stock) printf 'stock drift\n' >> "$recover_workspace/accepted-stock" ;;
  esac
  assert_recovery_rejection_preserves_state "hostile-$hostile_workspace"
done

# The recovery request remains bound to the exact installed tuple.  Each
# independent artifact, installed-leaf, and normal-config drift must leave the
# old private workspace untouched.
prepare_recoverable_record_orphan
assert_recovery_rejection_preserves_state tuple-version 0.2.1
prepare_recoverable_record_orphan
assert_recovery_rejection_preserves_state tuple-revision 0.2.0 \
  bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
prepare_recoverable_record_orphan
assert_recovery_rejection_preserves_state tuple-release 0.2.0 "$source_revision" \
  6.18.35+rpt-rpi-v8

for installed_drift in artifact-tree manifest module-bytes module-path overlay-bytes overlay-path normal-config exact-overlay foreign-overlay; do
  prepare_recoverable_record_orphan
  artifact="$root/usr/lib/hyperpixel2r-kms/0.2.0/$source_revision/$release"
  module="$root/lib/modules/$release/extra/hyperpixel2r_kms.ko"
  overlay="$root/boot/firmware/overlays/$overlay_file"
  case "$installed_drift" in
    artifact-tree) mv "$artifact" "$artifact.moved" ;;
    manifest) printf 'manifest drift\n' >> "$artifact/manifest.txt" ;;
    module-bytes) printf 'module drift\n' >> "$module" ;;
    module-path) mv "$module" "$module.moved" ;;
    overlay-bytes) printf 'overlay drift\n' >> "$overlay" ;;
    overlay-path) mv "$overlay" "$overlay.moved" ;;
    normal-config) printf '# normal drift\n' >> "$root/boot/firmware/config.txt" ;;
    exact-overlay)
      sed -i "s/^dtoverlay=$overlay_file$/dtoverlay=vc4-kms-v3d/" \
        "$root/boot/firmware/config.txt"
      cp "$root/boot/firmware/config.txt" "$recover_normal_snapshot"
      chown root:root "$recover_normal_snapshot"
      chmod 0600 "$recover_normal_snapshot"
      ;;
    foreign-overlay)
      printf 'dtoverlay=hyperpixel2r-kms-ffffffffffff.dtbo\n' >> "$root/boot/firmware/config.txt"
      cp "$root/boot/firmware/config.txt" "$recover_normal_snapshot"
      chown root:root "$recover_normal_snapshot"
      chmod 0600 "$recover_normal_snapshot"
      ;;
  esac
  assert_recovery_rejection_preserves_state "installed-$installed_drift"
done

exercise_legacy_accepted_upgrade

# Accepted lifecycle ownership is a separate durable protocol.  It records the
# exact retained bundle and a surgical stock-boot candidate, then uninstalls
# only that receipt without enumerating sibling artifacts.
new_target
printf 'fixture accepted prior backlight policy\n' > "$backlight_rule_path"
chown root:root "$backlight_rule_path"
chmod 0644 "$backlight_rule_path"
accepted_prior_rule_sha="$(sha256sum "$backlight_rule_path" | awk '{ print $1 }')"
run_stage >/dev/null
install_live_hardware
run_controller commit-boot.sh >/dev/null
run_accepted_remote record-accepted 0.2.0 "$source_revision" "$release" >/dev/null
accepted_receipt="$root/var/lib/hyperpixel2r-kms/accepted-state"
stock_config="$root/var/lib/hyperpixel2r-kms/accepted-stock-config.txt"
assert_file "$accepted_receipt"
assert_file "$stock_config"
grep -Fxq 'schema_version=3' "$accepted_receipt" ||
  fail 'accepted driver receipt schema is missing'
grep -Fxq 'backlight_rule_file=70-planeradar-backlight.rules' "$accepted_receipt" ||
  fail 'accepted receipt lost the rule identity'
grep -Fxq 'prior_backlight_rule_existed=true' "$accepted_receipt" ||
  fail 'accepted receipt did not preserve existing prior-rule proof'
grep -Fxq "prior_backlight_rule_sha256=$accepted_prior_rule_sha" "$accepted_receipt" ||
  fail 'accepted receipt lost the prior-rule checksum'
accepted_prior_rule="$root/var/lib/hyperpixel2r-kms/accepted-prior-backlight-rule"
assert_file "$accepted_prior_rule"
test "$(stat -c '%U:%G:%a' "$accepted_prior_rule")" = root:root:600 ||
  fail 'accepted prior-rule proof ownership or mode drifted'
test "$(sha256sum "$accepted_prior_rule" | awk '{ print $1 }')" = \
  "$accepted_prior_rule_sha" || fail 'accepted prior-rule proof bytes drifted'
if grep -Eq '^[[:space:]]*dtoverlay=.*hyperpixel2r' "$stock_config"; then
  fail 'accepted stock boot candidate retained a driver declaration'
fi
accepted_artifact="$root/usr/lib/hyperpixel2r-kms/0.2.0/$source_revision/$release"
accepted_inventory_sha="$(sha256sum "$accepted_artifact/dkms-prior-state" | awk '{ print $1 }')"
grep -Fxq "prior_dkms_inventory_sha256=$accepted_inventory_sha" "$accepted_receipt" ||
  fail 'accepted driver receipt did not bind the complete DKMS inventory'
new_revision='cccccccccccccccccccccccccccccccccccccccc'
new_overlay='hyperpixel2r-kms-cccccccccccc.dtbo'
if HP2R_FIXTURE_INTERRUPT_AFTER=accepted-transition-published \
  run_accepted_remote prepare-new-accepted \
    0.2.0 "$new_revision" "$release" "$(printf d%.0s {1..64})" \
    hyperpixel2r_kms.ko "$(printf e%.0s {1..64})" \
    "$new_overlay" "$(printf f%.0s {1..64})" \
    "$backlight_rule_file" "$(printf a%.0s {1..64})" \
    exact-backlight-metadata-v1 >/dev/null 2>&1; then
  fail 'new transition ignored interruption after pre-mutation journal publication'
fi
new_transition="$root/var/lib/hyperpixel2r-kms/accepted-transition"
assert_file "$new_transition"
grep -Fxq 'schema_version=5' "$new_transition" ||
  fail 'new transition did not publish the complete v5 journal'
grep -Fxq 'candidate_backlight_rule_file=70-planeradar-backlight.rules' "$new_transition" ||
  fail 'new transition lost the candidate rule identity'
grep -Fxq 'candidate_dkms_inventory_sha256=pending' "$new_transition" ||
  fail 'prepared new transition did not record its pending DKMS inventory binding'
grep -Fxq 'kind=new' "$new_transition" ||
  fail 'new transition journal lost its candidate kind'
grep -Fxq "candidate_source_revision=$new_revision" "$new_transition" ||
  fail 'new transition journal lost its exact candidate identity'
grep -Fxq 'prior_tryboot_existed=false' "$new_transition" ||
  fail 'new transition did not preserve prior tryboot absence'
grep -Fxq 'prior_tryboot_sha256=none' "$new_transition" ||
  fail 'new transition did not bind prior tryboot absence'
assert_absent "$root/var/lib/hyperpixel2r-kms/accepted-transition-prior-tryboot.txt"
assert_absent "$root/usr/lib/hyperpixel2r-kms/0.2.0/$new_revision/$release"
assert_absent "$root/boot/firmware/tryboot.txt"
grep -Fxq "dtoverlay=$overlay_file" "$root/boot/firmware/config.txt" ||
  fail 'new journal publication mutated the accepted boot config'
run_accepted_remote recover-accepted >/dev/null
assert_absent "$new_transition"
grep -Fxq "source_revision=$source_revision" "$accepted_receipt" ||
  fail 'new prepared-transition recovery changed the accepted receipt'

new_stage_revision='dddddddddddddddddddddddddddddddddddddddd'
new_stage_overlay='hyperpixel2r-kms-dddddddddddd.dtbo'
new_stage_source="$fixture/new-stage-source"
new_stage_artifact="$new_stage_source/dist/artifacts/$release"
mkdir -p "$(dirname "$new_stage_artifact")"
cp -a "$accepted_artifact" "$new_stage_artifact"
mv "$new_stage_artifact/$overlay_file" "$new_stage_artifact/$new_stage_overlay"
printf 'new accepted candidate module\n' >> "$new_stage_artifact/hyperpixel2r_kms.ko"
printf 'new accepted candidate overlay\n' >> "$new_stage_artifact/$new_stage_overlay"
new_stage_module_sha="$(sha256sum "$new_stage_artifact/hyperpixel2r_kms.ko" | awk '{print $1}')"
new_stage_overlay_sha="$(sha256sum "$new_stage_artifact/$new_stage_overlay" | awk '{print $1}')"
sed -i \
  -e "s/^source_revision\t.*/source_revision\t$new_stage_revision/" \
  -e "s/^module_sha256\t.*/module_sha256\t$new_stage_module_sha/" \
  -e "s/^overlay_file\t.*/overlay_file\t$new_stage_overlay/" \
  -e "s/^overlay_sha256\t.*/overlay_sha256\t$new_stage_overlay_sha/" \
  "$new_stage_artifact/manifest.txt"
printf '%s  %s\n' "$new_stage_module_sha" hyperpixel2r_kms.ko \
  > "$new_stage_artifact/module.sha256"
printf '%s  %s\n' "$new_stage_overlay_sha" "$new_stage_overlay" \
  > "$new_stage_artifact/overlay.sha256"
new_stage_manifest_sha="$(sha256sum "$new_stage_artifact/manifest.txt" | awk '{print $1}')"

for boundary in \
  candidate-artifact-published candidate-module-installed candidate-overlay-installed \
  candidate-dkms-activated candidate-tryboot-published \
  candidate-tryboot-state-published candidate-staged-published
do
  run_accepted_remote prepare-new-accepted \
    0.2.0 "$new_stage_revision" "$release" "$new_stage_manifest_sha" \
    hyperpixel2r_kms.ko "$new_stage_module_sha" \
    "$new_stage_overlay" "$new_stage_overlay_sha" \
    "$backlight_rule_file" "$(awk -F '\t' '$1 == "backlight_rule_sha256" { print $2 }' "$new_stage_artifact/manifest.txt")" \
    exact-backlight-metadata-v1 >/dev/null
  if HP2R_FIXTURE_INTERRUPT_AFTER="$boundary" \
    HP2R_FIXTURE_PRESERVE_MUTATIONS=1 \
    HP2R_FIXTURE_ARTIFACT_DIR_OVERRIDE="$new_stage_artifact" \
    HP2R_FIXTURE_SOURCE_ROOT_OVERRIDE="$new_stage_source" \
    run_stage >/dev/null 2>&1; then
    fail "new accepted stage ignored interruption at $boundary"
  fi
  assert_file "$new_transition"
  run_accepted_remote recover-accepted >/dev/null
  assert_absent "$new_transition"
  assert_absent "$root/usr/lib/hyperpixel2r-kms/0.2.0/$new_stage_revision/$release"
  assert_absent "$root/boot/firmware/tryboot.txt"
  grep -Fxq "dtoverlay=$overlay_file" "$root/boot/firmware/config.txt" ||
    fail "new accepted recovery after $boundary did not restore prior boot"
  grep -Fxq "source_revision=$source_revision" "$accepted_receipt" ||
    fail "new accepted recovery after $boundary changed the accepted receipt"
  find "$root/var/lib/hyperpixel2r-kms" -mindepth 1 -maxdepth 1 \
    -type d -name '.hp2r-transaction.*' -exec rm -rf -- {} +
  assert_no_private_workspaces
done

retained_revision='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
retained_overlay='hyperpixel2r-kms-bbbbbbbbbbbb.dtbo'
retained_artifact="$root/usr/lib/hyperpixel2r-kms/0.2.0/$retained_revision/$release"
mkdir -p "$(dirname "$retained_artifact")"
cp -a "$accepted_artifact" "$retained_artifact"
mv "$retained_artifact/$overlay_file" "$retained_artifact/$retained_overlay"
cp -a "$retained_artifact/dkms-source" "$retained_artifact/prior-dkms"
printf 'installed\n' > "$retained_artifact/dkms-prior-state"
sed -i \
  -e "s/^source_revision\t.*/source_revision\t$retained_revision/" \
  -e "s/^overlay_file\t.*/overlay_file\t$retained_overlay/" \
  "$retained_artifact/manifest.txt"

for boundary in \
  accepted-transition-published retained-overlay-installed retained-module-installed \
  retained-dkms-activated retained-tryboot-published retained-staged-published
do
  if HP2R_FIXTURE_INTERRUPT_AFTER="$boundary" \
    run_accepted_remote stage-retained 0.2.0 "$retained_revision" "$release" >/dev/null 2>&1; then
    fail "retained transition accepted interruption at $boundary"
  fi
  assert_file "$root/var/lib/hyperpixel2r-kms/accepted-transition"
  run_accepted_remote recover-accepted >/dev/null
  assert_absent "$root/var/lib/hyperpixel2r-kms/accepted-transition"
  grep -Fxq "dtoverlay=$overlay_file" "$root/boot/firmware/config.txt" ||
    fail "retained recovery after $boundary did not restore prior boot"
done

run_accepted_remote stage-retained 0.2.0 "$retained_revision" "$release" >/dev/null
assert_file "$root/var/lib/hyperpixel2r-kms/accepted-transition"
run_accepted_remote recover-accepted >/dev/null
assert_absent "$root/var/lib/hyperpixel2r-kms/accepted-transition"
grep -Fxq "dtoverlay=$overlay_file" "$root/boot/firmware/config.txt" ||
  fail 'pre-commit accepted recovery did not restore the prior overlay'

run_accepted_remote stage-retained 0.2.0 "$retained_revision" "$release" >/dev/null
run_accepted_remote commit-retained >/dev/null
grep -Fxq "dtoverlay=$retained_overlay" "$root/boot/firmware/config.txt" ||
  fail 'retained commit did not publish the candidate overlay'
run_accepted_remote recover-accepted >/dev/null
grep -Fxq "dtoverlay=$overlay_file" "$root/boot/firmware/config.txt" ||
  fail 'post-commit accepted recovery did not restore the prior overlay'

run_accepted_remote stage-retained 0.2.0 "$retained_revision" "$release" >/dev/null
run_accepted_remote commit-retained >/dev/null
run_accepted_remote mark-verified-accepted >/dev/null
assert_file "$root/var/lib/hyperpixel2r-kms/accepted-transition"
grep -Fxq 'phase=verified' "$root/var/lib/hyperpixel2r-kms/accepted-transition" ||
  fail 'driver acceptance did not retain the verified transition journal'
for boundary in \
  accepted-finalizing-published accepted-receipt-published \
  accepted-receipt-phase-published accepted-prior-retired accepted-journal-cleared
do
  if HP2R_FIXTURE_INTERRUPT_AFTER="$boundary" \
    run_accepted_remote finalize-accepted >/dev/null 2>&1; then
    fail "accepted finalizer ignored interruption at $boundary"
  fi
  if test "$boundary" = accepted-journal-cleared; then
    assert_absent "$root/var/lib/hyperpixel2r-kms/accepted-transition"
  else
    assert_file "$root/var/lib/hyperpixel2r-kms/accepted-transition"
  fi
done
run_accepted_remote finalize-accepted >/dev/null
run_accepted_remote finalize-accepted >/dev/null
assert_backlight_rule_installed
grep -Fxq "source_revision=$retained_revision" "$accepted_receipt" ||
  fail 'retained acceptance did not rotate the exact receipt'
printf 'dtparam=audio=on\n' >> "$root/boot/firmware/config.txt"
for boundary in \
  uninstall-journal-published uninstall-boot-restored uninstall-dkms-restored \
  uninstall-module-removed uninstall-overlay-removed uninstall-rule-restored \
  uninstall-artifact-detached \
  uninstall-receipt-removed
do
  if HP2R_FIXTURE_INTERRUPT_AFTER="$boundary" \
    run_accepted_remote uninstall-accepted 0.2.0 "$retained_revision" "$release" >/dev/null 2>&1; then
    fail "accepted uninstall ignored interruption at $boundary"
  fi
  assert_file "$root/var/lib/hyperpixel2r-kms/accepted-uninstall"
done
run_accepted_remote uninstall-accepted 0.2.0 "$retained_revision" "$release" >/dev/null
grep -Fxq '[all]' "$root/boot/firmware/config.txt" ||
  fail 'accepted uninstall did not restore the proven stock boot candidate'
grep -Fxq 'dtparam=audio=on' "$root/boot/firmware/config.txt" ||
  fail 'accepted uninstall did not preserve an unrelated changed boot line'
assert_absent "$root/lib/modules/$release/extra/hyperpixel2r_kms.ko"
assert_absent "$root/boot/firmware/overlays/$retained_overlay"
assert_file "$backlight_rule_path"
test "$(sha256sum "$backlight_rule_path" | awk '{ print $1 }')" = \
  "$accepted_prior_rule_sha" || fail 'accepted uninstall did not restore the prior rule'
assert_absent "$accepted_receipt"
assert_file "$root/var/lib/hyperpixel2r-kms/accepted-uninstall"
grep -Fxq 'schema_version=4' "$root/var/lib/hyperpixel2r-kms/accepted-uninstall" ||
  fail 'accepted uninstall did not publish the checksum-bound v4 journal'
grep -Fxq 'prior_backlight_rule_existed=true' \
  "$root/var/lib/hyperpixel2r-kms/accepted-uninstall" ||
  fail 'accepted uninstall journal lost existing prior-rule proof'
grep -Fxq "prior_backlight_rule_sha256=$accepted_prior_rule_sha" \
  "$root/var/lib/hyperpixel2r-kms/accepted-uninstall" ||
  fail 'accepted uninstall journal lost the prior-rule checksum'
retained_inventory_sha="$(sha256sum "$retained_artifact.accepted-uninstall/dkms-prior-state" | awk '{ print $1 }')"
grep -Fxq "prior_dkms_inventory_sha256=$retained_inventory_sha" \
  "$root/var/lib/hyperpixel2r-kms/accepted-uninstall" ||
  fail 'accepted uninstall journal lost the complete DKMS inventory binding'
assert_file "$root/lib/modules/$release/updates/dkms/hyperpixel2r_kms.ko"
assert_dkms_kernel_state "$release" installed
grep -Fxq 'hyperpixel2r_kms.ko: updates/dkms/hyperpixel2r_kms.ko' \
  "$root/lib/modules/$release/modules.dep" ||
  fail 'accepted uninstall did not restore prior DKMS module resolution'
run_accepted_remote retire-inactive 0.2.0 "$source_revision" "$release" >/dev/null
assert_absent "$accepted_artifact"
if HP2R_FIXTURE_INTERRUPT_AFTER=uninstall-artifact-removed \
  run_accepted_remote finalize-uninstall-accepted >/dev/null 2>&1; then
  fail 'accepted uninstall finalizer ignored artifact-removal interruption'
fi
assert_file "$root/var/lib/hyperpixel2r-kms/accepted-uninstall"
if HP2R_FIXTURE_INTERRUPT_AFTER=uninstall-journal-cleared \
  run_accepted_remote finalize-uninstall-accepted >/dev/null 2>&1; then
  fail 'accepted uninstall finalizer ignored journal-clear interruption'
fi
run_accepted_remote finalize-uninstall-accepted >/dev/null
assert_absent "$root/var/lib/hyperpixel2r-kms/accepted-uninstall"
assert_absent "$accepted_prior_rule"

# An inactive artifact may share the generic installed module path and exact
# module bytes with a distinct active artifact.  Retirement is safe only when
# the normal config, active overlay, retained active bundle, and installed
# module prove that distinct ownership without ambiguity.
prepare_shared_module_inactive_retirement
run_accepted_remote retire-inactive 0.2.0 "$source_revision" "$release" >/dev/null
assert_absent "$inactive_retirement_artifact"
assert_shared_module_active_target_unchanged

prepare_shared_module_inactive_retirement
rm -rf -- "$active_retirement_artifact"
if run_accepted_remote retire-inactive 0.2.0 "$source_revision" "$release" \
  >"$fixture/shared-retirement-missing-artifact.out" 2>&1; then
  fail 'inactive retirement accepted a shared module without its active retained artifact'
fi
diff -ru "$inactive_retirement_artifact_before" "$inactive_retirement_artifact" >/dev/null ||
  fail 'rejected inactive retirement changed its artifact without active authority'
assert_file "$active_retirement_module_path"
assert_file "$active_retirement_overlay_path"

prepare_shared_module_inactive_retirement
printf 'different active module\n' >> "$active_retirement_artifact/hyperpixel2r_kms.ko"
active_retirement_drift_sha="$(
  sha256sum "$active_retirement_artifact/hyperpixel2r_kms.ko" | awk '{ print $1 }'
)"
replace_manifest_value "$active_retirement_artifact/manifest.txt" \
  module_sha256 "$active_retirement_drift_sha"
chown root:root "$active_retirement_artifact/manifest.txt"
chmod 0644 "$active_retirement_artifact/manifest.txt"
rm -rf -- "$active_retirement_artifact_before"
cp -a "$active_retirement_artifact" "$active_retirement_artifact_before"
assert_shared_module_retirement_rejected module-mismatch

prepare_shared_module_inactive_retirement
printf 'dtoverlay=%s\n' "$active_retirement_overlay" >> "$root/boot/firmware/config.txt"
active_retirement_config_sha="$(sha256sum "$root/boot/firmware/config.txt" | awk '{ print $1 }')"
assert_shared_module_retirement_rejected duplicate-active-declaration

# Accepted uninstall must retain the complete per-kernel inventory authority,
# including replay after the restore happened but its phase write did not.
exercise_accepted_inventory_uninstall() {
  local label="$1"
  local running_state="$2"
  local future_state="$3"
  local future_kernel='6.18.35+rpt-rpi-v8'
  local sums artifact receipt marker marker_sha journal

  new_target
  prepare_prior_dkms "$label" "$running_state"
  if test "$future_state" != none; then
    set_prior_dkms_kernel_state "$future_kernel" "$future_state"
  fi
  sums="$fixture/prior-dkms-$label.sums"
  (cd "$root/usr/src/hyperpixel2r-kms-0.2.0" && sha256sum * | sed 's#  # #') > "$sums"
  run_stage >/dev/null
  install_live_hardware
  run_controller commit-boot.sh >/dev/null
  run_accepted_remote record-accepted 0.2.0 "$source_revision" "$release" >/dev/null
  artifact="$root/usr/lib/hyperpixel2r-kms/0.2.0/$source_revision/$release"
  receipt="$root/var/lib/hyperpixel2r-kms/accepted-state"
  marker="$artifact/dkms-prior-state"
  marker_sha="$(sha256sum "$marker" | awk '{ print $1 }')"
  grep -Fxq 'schema_version=3' "$receipt" ||
    fail "$label accepted receipt is not schema 3"
  grep -Fxq "prior_dkms_inventory_sha256=$marker_sha" "$receipt" ||
    fail "$label accepted receipt lost its DKMS inventory checksum"
  if HP2R_FIXTURE_INTERRUPT_AFTER=uninstall-dkms-restored \
    run_accepted_remote uninstall-accepted \
      0.2.0 "$source_revision" "$release" >/dev/null 2>&1; then
    fail "$label accepted uninstall ignored DKMS-restored interruption"
  fi
  run_accepted_remote uninstall-accepted \
    0.2.0 "$source_revision" "$release" >/dev/null
  journal="$root/var/lib/hyperpixel2r-kms/accepted-uninstall"
  grep -Fxq 'schema_version=4' "$journal" ||
    fail "$label accepted uninstall journal is not schema 4"
  grep -Fxq "prior_dkms_inventory_sha256=$marker_sha" "$journal" ||
    fail "$label accepted uninstall journal lost its DKMS inventory checksum"
  case "$running_state" in
    installed|built) assert_prior_dkms "$sums" "$running_state" ;;
    *) assert_prior_dkms "$sums" inventory ;;
  esac
  if test "$future_state" != none; then
    assert_dkms_kernel_state "$future_kernel" "$future_state"
  fi
  run_accepted_remote finalize-uninstall-accepted >/dev/null
}

exercise_accepted_inventory_uninstall accepted-two-installed installed installed
exercise_accepted_inventory_uninstall accepted-mixed-inventory built installed
exercise_accepted_inventory_uninstall accepted-future-only added installed

# Structurally valid marker drift is still identity drift.  Reject it before
# publishing an uninstall journal or mutating the accepted boot.
new_target
prepare_prior_dkms accepted-inventory-drift installed
run_stage >/dev/null
install_live_hardware
run_controller commit-boot.sh >/dev/null
run_accepted_remote record-accepted 0.2.0 "$source_revision" "$release" >/dev/null
accepted_artifact="$root/usr/lib/hyperpixel2r-kms/0.2.0/$source_revision/$release"
accepted_receipt="$root/var/lib/hyperpixel2r-kms/accepted-state"
sed -i 's/^source_state=added$/source_state=unregistered/' \
  "$accepted_artifact/dkms-prior-state"
if run_accepted_remote uninstall-accepted \
  0.2.0 "$source_revision" "$release" >/dev/null 2>&1; then
  fail 'accepted uninstall accepted a checksum-drifted valid DKMS inventory'
fi
assert_file "$accepted_receipt"
assert_absent "$root/var/lib/hyperpixel2r-kms/accepted-uninstall"
assert_file "$root/lib/modules/$release/extra/hyperpixel2r_kms.ko"

# The same checksum remains authoritative after the artifact is detached and
# across replay of an interrupted destructive phase.
new_target
prepare_prior_dkms accepted-detached-drift installed
run_stage >/dev/null
install_live_hardware
run_controller commit-boot.sh >/dev/null
run_accepted_remote record-accepted 0.2.0 "$source_revision" "$release" >/dev/null
accepted_artifact="$root/usr/lib/hyperpixel2r-kms/0.2.0/$source_revision/$release"
if HP2R_FIXTURE_INTERRUPT_AFTER=uninstall-artifact-detached \
  run_accepted_remote uninstall-accepted \
    0.2.0 "$source_revision" "$release" >/dev/null 2>&1; then
  fail 'accepted uninstall ignored artifact-detached interruption'
fi
detached_artifact="$accepted_artifact.accepted-uninstall"
sed -i 's/^source_state=added$/source_state=unregistered/' \
  "$detached_artifact/dkms-prior-state"
if run_accepted_remote uninstall-accepted \
  0.2.0 "$source_revision" "$release" >/dev/null 2>&1; then
  fail 'accepted uninstall replay accepted a checksum-drifted detached inventory'
fi
assert_file "$root/var/lib/hyperpixel2r-kms/accepted-uninstall"

# Removing the new checksum field cannot downgrade a full inventory into a
# legacy receipt.
new_target
prepare_prior_dkms accepted-hashless-full
run_stage >/dev/null
install_live_hardware
run_controller commit-boot.sh >/dev/null
run_accepted_remote record-accepted 0.2.0 "$source_revision" "$release" >/dev/null
accepted_receipt="$root/var/lib/hyperpixel2r-kms/accepted-state"
sed -i \
  -e 's/^schema_version=3$/schema_version=1/' \
  -e '/^prior_dkms_inventory_sha256=/d' \
  -e '/^backlight_rule_file=/d' \
  -e '/^backlight_rule_sha256=/d' \
  -e '/^prior_backlight_rule_existed=/d' \
  -e '/^prior_backlight_rule_sha256=/d' \
  "$accepted_receipt"
if run_accepted_remote uninstall-accepted \
  0.2.0 "$source_revision" "$release" >/dev/null 2>&1; then
  fail 'accepted uninstall accepted a hashless full DKMS inventory'
fi
assert_absent "$root/var/lib/hyperpixel2r-kms/accepted-uninstall"

# True legacy scalar receipts and schema-2 uninstall journals remain
# recoverable.  This is the only accepted hashless compatibility shape.
new_target
prepare_prior_dkms accepted-legacy-scalar
legacy_sums="$fixture/prior-dkms-accepted-legacy.sums"
(cd "$root/usr/src/hyperpixel2r-kms-0.2.0" && sha256sum * | sed 's#  # #') > "$legacy_sums"
run_stage >/dev/null
install_live_hardware
run_controller commit-boot.sh >/dev/null
accepted_artifact="$root/usr/lib/hyperpixel2r-kms/0.2.0/$source_revision/$release"
downgrade_artifact_to_schema_one "$accepted_artifact"
printf 'registered\n' > "$accepted_artifact/dkms-prior-state"
run_accepted_remote record-accepted 0.2.0 "$source_revision" "$release" >/dev/null
accepted_receipt="$root/var/lib/hyperpixel2r-kms/accepted-state"
sed -i \
  -e 's/^schema_version=2$/schema_version=1/' \
  -e '/^prior_dkms_inventory_sha256=/d' \
  "$accepted_receipt"
if HP2R_FIXTURE_INTERRUPT_AFTER=uninstall-journal-published \
  run_accepted_remote uninstall-accepted \
    0.2.0 "$source_revision" "$release" >/dev/null 2>&1; then
  fail 'legacy accepted uninstall ignored journal interruption'
fi
grep -Fxq 'schema_version=2' \
  "$root/var/lib/hyperpixel2r-kms/accepted-uninstall" ||
  fail 'legacy accepted uninstall did not retain the schema-2 journal'
run_accepted_remote uninstall-accepted \
  0.2.0 "$source_revision" "$release" >/dev/null
assert_prior_dkms "$legacy_sums" added
run_accepted_remote finalize-uninstall-accepted >/dev/null

# A verified release-source extraction has no ambient Git repository.  Its
# exact source identity and regular kernel leaves must be sufficient for
# staging the committed DKMS source.
release_source_root="$fixture/release-source"
mkdir -p "$release_source_root/release"
cp -a "$repo_root/kernel" "$release_source_root/kernel"
{
  printf 'schema_version\t1\n'
  printf 'repository\thttps://github.com/shayne/hyperpixel2r-kms\n'
  printf 'source_revision\t%s\n' "$source_revision"
  printf 'source_tree\t%s\n' "$source_tree"
} > "$release_source_root/release/source-identity.txt"
new_target
export HP2R_FIXTURE_REJECT_GIT=1 HP2R_RELEASE_SOURCE_ROOT="$release_source_root"
if ! run_stage >/dev/null; then
  fail 'stage could not consume the verified extracted release source without Git'
fi
unset HP2R_FIXTURE_REJECT_GIT HP2R_RELEASE_SOURCE_ROOT
run_controller rollback-boot.sh >/dev/null
new_target
run_stage >/dev/null

# State is a strict private schema and the DKMS source must be materialized by
# the controller's committed-revision read, rather than copied from kernel/.
state="$root/var/lib/hyperpixel2r-kms/tryboot-state"
assert_file "$state"
test "$(stat -c '%U:%G:%a' "$state")" = root:root:600 || fail 'state ownership or mode is not exact'
test "$(awk 'END {print NR}' "$state")" = 25 || fail 'state schema cardinality changed'
grep -Fxq 'schema_version=4' "$state"
grep -Eq '^candidate_config_sha256=[0-9a-f]{64}$' "$state"
grep -Eq '^prior_dkms_inventory_sha256=[0-9a-f]{64}$' "$state"
grep -Fxq 'prior_tryboot_sha256=none' "$state"
grep -Fxq 'module_existed=false' "$state"
grep -Fxq 'overlay_existed=false' "$state"
grep -Fxq 'backlight_rule_file=70-planeradar-backlight.rules' "$state"
grep -Eq '^backlight_rule_sha256=[0-9a-f]{64}$' "$state"
grep -Fxq 'prior_backlight_rule_existed=false' "$state"
grep -Fxq 'prior_backlight_rule_sha256=none' "$state"
grep -Fxq 'backlight_metadata_capability=exact-backlight-metadata-v1' "$state"
grep -Eq '^prior_backlight_metadata_sha256=[0-9a-f]{64}$' "$state"
grep -Fq 'fixture committed source: hyperpixel2r_kms_main.c' \
  "$root/usr/src/hyperpixel2r-kms-0.2.0/hyperpixel2r_kms_main.c" ||
  fail 'DKMS source was not materialized from the committed source identity'
test "$(grep -n 'tryboot-reboot\|remote-rm' "$log" | sed -n '1p' | cut -d: -f2-)" = 'remote-rm /tmp/hp2r-tryboot-stage.fixture' ||
  fail 'validated remote stage payload survived until reboot'

# A returned release is untrusted controller input and must be rejected before
# artifact selection or transfer.
new_target
export HP2R_FIXTURE_RELEASE_OVERRIDE='../unsafe'
if run_stage >/dev/null 2>&1; then fail 'unsafe kernel release was accepted'; fi
unset HP2R_FIXTURE_RELEASE_OVERRIDE
assert_absent "$root/boot/firmware/tryboot.txt"

# Reject unsafe, zero, and multiple structural overlay declarations before a
# candidate is published.
new_target
printf '[all]\ndtoverlay=vc4-kms-dpi-hyperpixel2r,rotate=90\ndtoverlay=vc4-kms-dpi-hyperpixel2r\n' > "$root/boot/firmware/config.txt"
if run_stage >/dev/null 2>&1; then fail 'multiple requested overlay declarations were accepted'; fi
assert_clean_failed_stage
new_target
printf '[all]\ndtoverlay=vc4-kms-dpi-hyperpixel2r,rotate=/unsafe\n' > "$root/boot/firmware/config.txt"
if run_stage >/dev/null 2>&1; then fail 'unsafe overlay declaration was accepted'; fi
assert_clean_failed_stage

# A final stage publication failure must restore the pre-stage target, not
# merely tryboot.txt.  This covers artifacts, module, overlay, source tree,
# DKMS registration and state together.
for stage_fault in artifact stage-state; do
  new_target
  export HP2R_FIXTURE_FAIL_MV="$stage_fault"
  if run_stage > "$fixture/last-stage-output" 2>&1; then fail "injected $stage_fault publication failure was accepted"; fi
  unset HP2R_FIXTURE_FAIL_MV
  assert_clean_failed_stage
done

# `mktemp` creates a root-mode-0700 directory before each allocator check.
# Every post-allocation validation failure must remove only that exact,
# syntax-proven transaction path and retain the original stage failure.  A
# malformed returned path is deliberately not targeted; it emits recovery
# guidance and leaves the unrelated fixture path intact for inspection.
for allocator_fault in path lfirst directory owner chmod chown mode; do
  new_target
  export HP2R_FIXTURE_ALLOCATOR_FAULT="$allocator_fault"
  if run_stage > "$fixture/last-stage-output" 2>&1; then
    fail "stage accepted allocator $allocator_fault failure"
  else
    failure_status=$?
  fi
  unset HP2R_FIXTURE_ALLOCATOR_FAULT
  test "$failure_status" = 1 || fail "allocator $allocator_fault cleanup changed the original stage failure status"
  assert_file "$root/tmp/allocator-fault-$allocator_fault"
  assert_no_private_workspaces
  assert_clean_failed_stage
  if test "$allocator_fault" = path; then
    test -d "$root/tmp/allocator-untrusted-path" ||
      fail 'allocator targeted an unvalidated workspace pathname'
    grep -Fq 'no automatic deletion attempted; inspect manually' "$fixture/last-stage-output" ||
      fail 'allocator path failure did not record manual recovery guidance'
  fi
done

# The workspace cleanup trap must be armed before the first private candidate
# allocation.  This is deliberately the earliest operation after workspace
# creation; its original stage failure must survive a transient cleanup fault.
new_target
export HP2R_FIXTURE_FAIL_PRIVATE_FILE=candidate HP2R_FIXTURE_FAIL_RM=workspace
if run_stage > "$fixture/last-stage-output" 2>&1; then
  fail 'stage accepted an injected first private candidate allocation failure'
else
  failure_status=$?
fi
unset HP2R_FIXTURE_FAIL_PRIVATE_FILE HP2R_FIXTURE_FAIL_RM
test "$failure_status" = 1 || fail 'stage cleanup changed the original private candidate failure status'
assert_file "$root/tmp/private-file-candidate-failed"
assert_workspace_remove_retried
assert_clean_failed_stage

# A transient final workspace removal failure is retried by the still-armed
# EXIT cleanup and must not turn a completed transaction into a failed or
# replayable one.  Exercise the successful stage, commit, and rollback ends.
for final_cleanup_operation in stage commit rollback; do
  new_target
  case "$final_cleanup_operation" in
    stage)
      export HP2R_FIXTURE_FAIL_RM=workspace
      if ! run_stage > "$fixture/last-stage-output" 2>&1; then
        cat "$fixture/last-stage-output" >&2
        fail 'stage did not finish after transient final workspace removal failure'
      fi
      unset HP2R_FIXTURE_FAIL_RM
      assert_file "$root/boot/firmware/tryboot.txt"
      assert_file "$root/var/lib/hyperpixel2r-kms/tryboot-state"
      ;;
    commit)
      run_stage >/dev/null
      install_live_hardware
      export HP2R_FIXTURE_FAIL_RM=workspace
      if ! run_controller commit-boot.sh > "$fixture/last-stage-output" 2>&1; then
        cat "$fixture/last-stage-output" >&2
        fail 'commit did not finish after transient final workspace removal failure'
      fi
      unset HP2R_FIXTURE_FAIL_RM
      assert_absent "$root/boot/firmware/tryboot.txt"
      assert_absent "$root/var/lib/hyperpixel2r-kms/tryboot-state"
      ;;
    rollback)
      run_stage >/dev/null
      export HP2R_FIXTURE_FAIL_RM=workspace
      if ! run_controller rollback-boot.sh > "$fixture/last-stage-output" 2>&1; then
        cat "$fixture/last-stage-output" >&2
        fail 'rollback did not finish after transient final workspace removal failure'
      fi
      unset HP2R_FIXTURE_FAIL_RM
      assert_absent "$root/boot/firmware/tryboot.txt"
      assert_absent "$root/var/lib/hyperpixel2r-kms/tryboot-state"
      ;;
  esac
  assert_workspace_remove_retried
done

# Compensation failures retain their original controller failure while the
# independent cleanup handler retries the private workspace removal.
new_target
run_stage >/dev/null
install_live_hardware
export HP2R_FIXTURE_FAIL_MV=state HP2R_FIXTURE_FAIL_RM=workspace
if run_controller commit-boot.sh > "$fixture/last-stage-output" 2>&1; then
  fail 'commit accepted an injected compensation failure'
else
  failure_status=$?
fi
unset HP2R_FIXTURE_FAIL_MV HP2R_FIXTURE_FAIL_RM
test "$failure_status" = 1 || fail 'commit cleanup changed the original compensation failure status'
assert_workspace_remove_retried
assert_file "$root/boot/firmware/tryboot.txt"
assert_file "$root/var/lib/hyperpixel2r-kms/tryboot-state"

new_target
run_stage >/dev/null
export HP2R_FIXTURE_FAIL_MV=module-hold HP2R_FIXTURE_FAIL_RM=workspace
if run_controller rollback-boot.sh > "$fixture/last-stage-output" 2>&1; then
  fail 'rollback accepted an injected compensation failure'
else
  failure_status=$?
fi
unset HP2R_FIXTURE_FAIL_MV HP2R_FIXTURE_FAIL_RM
test "$failure_status" = 1 || fail 'rollback cleanup changed the original compensation failure status'
assert_workspace_remove_retried
assert_file "$root/boot/firmware/tryboot.txt"
assert_file "$root/var/lib/hyperpixel2r-kms/tryboot-state"

# Once the complete root-owned artifact is published, installation must use
# those checksum-bound leaves rather than mutable incoming payload leaves.
new_target
export HP2R_FIXTURE_RACE_POST_PUBLISH_INCOMING_MODULE=regular
if ! run_stage > "$fixture/last-stage-output" 2>&1; then
  cat "$fixture/last-stage-output" >&2
  fail 'post-publication incoming module race rejected a valid staged artifact'
fi
unset HP2R_FIXTURE_RACE_POST_PUBLISH_INCOMING_MODULE
assert_file "$root/tmp/incoming-module-replaced"
expected_module_sha="$(awk -F= '$1 == "module_sha256" { print $2 }' "$root/var/lib/hyperpixel2r-kms/tryboot-state")"
actual_module_sha="$(sha256sum "$root/lib/modules/$release/extra/hyperpixel2r_kms.ko" | awk '{ print $1 }')"
artifact_module_sha="$(sha256sum "$root/usr/lib/hyperpixel2r-kms/0.2.0/$source_revision/$release/hyperpixel2r_kms.ko" | awk '{ print $1 }')"
test "$actual_module_sha" = "$expected_module_sha" || fail 'post-publication incoming module replaced the checksum-bound module'
test "$artifact_module_sha" = "$expected_module_sha" || fail 'stored artifact module does not match transaction state'

# After initial validation, a source symlink race must fail before any root
# hash of the incoming path.  The cp test double swaps the source immediately
# before the production copy primitive receives it.
new_target
export HP2R_FIXTURE_RACE_ATOMIC_SOURCE_SYMLINK=module
export HP2R_FIXTURE_INSTRUMENT_UNTRUSTED_SHA=1
if run_stage > "$fixture/last-stage-output" 2>&1; then fail 'atomic source symlink race was accepted'; fi
unset HP2R_FIXTURE_RACE_ATOMIC_SOURCE_SYMLINK HP2R_FIXTURE_INSTRUMENT_UNTRUSTED_SHA
assert_file "$root/tmp/atomic-source-replaced"
assert_absent "$root/tmp/untrusted-incoming-sha-read"
assert_clean_failed_stage

# A root-owned leaf is not private when its rollback directory belongs to the
# remote user.  The attacker runs as UID 65534 after snapshot creation and
# before the normal-config hash; a private transaction workspace must prevent
# listing, rename, unlink, and replacement so staging can still finish.
new_target
export HP2R_FIXTURE_RACE_USER_SNAPSHOT_HASH=1
if ! run_stage > "$fixture/last-stage-output" 2>&1; then
  cat "$fixture/last-stage-output" >&2
  fail 'unprivileged snapshot replacement influenced privileged staging'
fi
unset HP2R_FIXTURE_RACE_USER_SNAPSHOT_HASH
assert_file "$root/tmp/user-snapshot-attack-attempted"
assert_absent "$root/tmp/user-snapshot-attack-succeeded"
for action in listed renamed unlinked replaced; do
  assert_absent "$root/tmp/user-snapshot-$action"
done
assert_no_private_workspaces
assert_incoming_stage_cleaned

# Both snapshot and atomic-copy temporary leaves must reject a late symlink
# before any `-f`, hash, parser, metadata, or content reader can follow it.
for late_symlink in snapshot atomic; do
  new_target
  export HP2R_FIXTURE_RACE_LATE_SYMLINK="$late_symlink"
  export HP2R_FIXTURE_INSTRUMENT_SYMLINK_FOLLOW=1
  if run_stage > "$fixture/last-stage-output" 2>&1; then
    fail "late $late_symlink symlink was accepted"
  fi
  unset HP2R_FIXTURE_RACE_LATE_SYMLINK HP2R_FIXTURE_INSTRUMENT_SYMLINK_FOLLOW
  assert_file "$root/tmp/late-symlink-${late_symlink}-created"
  for reader in test-f sha256sum awk stat cat cp; do
    assert_absent "$root/tmp/symlink-followed-by-$reader"
  done
  assert_clean_failed_stage
  assert_no_private_workspaces
  assert_incoming_stage_cleaned
done

# Mixed and malformed DKMS output is never treated as an unregistered source.
new_target
export HP2R_FIXTURE_DKMS_STATUS=$'hyperpixel2r-kms/0.2.0: added\nhyperpixel2r-kms/0.2.0: broken'
if run_stage >/dev/null 2>&1; then fail 'mixed DKMS status was accepted'; fi
unset HP2R_FIXTURE_DKMS_STATUS
assert_clean_failed_stage

# Inventory capture is deliberately bounded.  More than sixteen otherwise
# valid per-kernel rows must fail before `dkms remove --all` can destroy the
# real registration.
new_target
prepare_prior_dkms oversized-kernel-inventory
prior_dkms_sums="$fixture/prior-dkms-oversized-inventory.sums"
(cd "$root/usr/src/hyperpixel2r-kms-0.2.0" && sha256sum * | sed 's#  # #') > "$prior_dkms_sums"
HP2R_FIXTURE_DKMS_STATUS=''
for ((index = 1; index <= 17; index++)); do
  HP2R_FIXTURE_DKMS_STATUS+="hyperpixel2r-kms/0.2.0, 6.18.$index+rpt-rpi-v8, aarch64: built"$'\n'
done
export HP2R_FIXTURE_DKMS_STATUS
if run_stage >/dev/null 2>&1; then fail 'oversized DKMS kernel inventory was accepted'; fi
unset HP2R_FIXTURE_DKMS_STATUS
assert_prior_dkms "$prior_dkms_sums" added

# A normal config writer racing the transaction is detected at the final
# publication boundary and leaves no candidate behind.
new_target
export HP2R_FIXTURE_MUTATE_NORMAL=1
if run_stage >/dev/null 2>&1; then fail 'concurrently changed normal config was accepted'; fi
unset HP2R_FIXTURE_MUTATE_NORMAL
grep -Fq '# concurrent writer' "$root/boot/firmware/config.txt" || fail 'fixture did not mutate normal config'
assert_clean_failed_stage

# A second stage invocation is a replay, not an implicit promotion or source
# upgrade.  It must fail closed while the first transaction remains intact.
new_target
run_stage >/dev/null
candidate_sha="$(sha256sum "$root/boot/firmware/tryboot.txt" | awk '{print $1}')"
if run_stage >/dev/null 2>&1; then fail 'active transaction replay was accepted'; fi
test "$(sha256sum "$root/boot/firmware/tryboot.txt" | awk '{print $1}')" = "$candidate_sha" || fail 'replay changed candidate bytes'
assert_file "$root/var/lib/hyperpixel2r-kms/tryboot-state"

# Commit keeps the old normal configuration until both tryboot restoration and
# state deletion have succeeded.  Each injected failure must compensate back
# to the candidate and leave the state replayable.
for fault in tryboot state state-hold-mktemp; do
  new_target
  if test "$fault" = tryboot; then
    printf '[all]\n# prior tryboot\n' > "$root/boot/firmware/tryboot.txt"
    chmod 0600 "$root/boot/firmware/tryboot.txt"
  fi
  baseline="$(sha256sum "$root/boot/firmware/config.txt" | awk '{print $1}')"
  run_stage >/dev/null
  install_live_hardware
  case "$fault" in
    tryboot) export HP2R_FIXTURE_FAIL_MV=tryboot ;;
    state) export HP2R_FIXTURE_FAIL_RM=state-hold ;;
    state-hold-mktemp) export HP2R_FIXTURE_FAIL_MKTEMP=commit ;;
  esac
  if run_controller commit-boot.sh >/dev/null 2>&1; then fail "commit accepted injected $fault failure"; fi
  unset HP2R_FIXTURE_FAIL_MV HP2R_FIXTURE_FAIL_RM HP2R_FIXTURE_FAIL_MKTEMP || true
  test "$(sha256sum "$root/boot/firmware/config.txt" | awk '{print $1}')" = "$baseline" ||
    fail "commit $fault failure left normal config promoted"
  assert_file "$root/boot/firmware/tryboot.txt"
  assert_file "$root/var/lib/hyperpixel2r-kms/tryboot-state"
done

# The normal configuration is part of the candidate identity.  A writer which
# wins after structural overlay validation but before atomic promotion must be
# detected, and the staged candidate must remain replayable.
new_target
run_stage >/dev/null
install_live_hardware
export HP2R_FIXTURE_MUTATE_COMMIT_NORMAL_AFTER_VALIDATION=1
if run_controller commit-boot.sh >/dev/null 2>&1; then
  fail 'commit accepted a normal-config writer after overlay validation'
fi
unset HP2R_FIXTURE_MUTATE_COMMIT_NORMAL_AFTER_VALIDATION
grep -Fq '# concurrent writer' "$root/boot/firmware/config.txt" ||
  fail 'commit race fixture did not mutate normal config'
if grep -Eq '^dtoverlay=hyperpixel2r-kms-[0-9a-f]{12}\.dtbo$' "$root/boot/firmware/config.txt"; then
  fail 'commit race promoted the candidate despite normal-config drift'
fi
assert_file "$root/boot/firmware/tryboot.txt"
assert_file "$root/var/lib/hyperpixel2r-kms/tryboot-state"

# A successful commit probes live rather than local identity and removes both
# the one-shot file and transaction state only after promotion.
new_target
run_stage >/dev/null
install_live_hardware
json="$(run_verify)"
test "$json" = '{"schema_version":1,"driver_version":"0.2.0","kernel_release":"6.18.34+rpt-rpi-v8","module":"hyperpixel2r_kms","drm_mode":"480x480","touch":true,"sdl_driver":"KMSDRM","renderer":"opengles2","accepted":true}' ||
  fail 'verify JSON was not derived from the live fake target'

rm -f -- "$root/sys/bus/platform/drivers/hyperpixel2r-kms/fixture-panel"
mkdir -p "$root/sys/bus/platform/drivers/hyperpixel2r-kms/fixture-panel/of_node"
printf 'shayne,hyperpixel2r-kms\0' \
  > "$root/sys/bus/platform/drivers/hyperpixel2r-kms/fixture-panel/of_node/compatible"
assert_verify_rejects_binding 'a regular fake platform binding'

rm -rf -- "$root/sys/bus/platform/drivers/hyperpixel2r-kms/fixture-panel"
ln -s ../../../../devices/platform/missing-panel \
  "$root/sys/bus/platform/drivers/hyperpixel2r-kms/fixture-panel"
assert_verify_rejects_binding 'an unresolved platform binding symlink'

rm -f -- "$root/sys/bus/platform/drivers/hyperpixel2r-kms/fixture-panel"
mkdir -p "$root/sys/devices/virtual/foreign-panel/of_node"
printf 'shayne,hyperpixel2r-kms\0' > "$root/sys/devices/virtual/foreign-panel/of_node/compatible"
ln -s ../../../../devices/virtual/foreign-panel \
  "$root/sys/bus/platform/drivers/hyperpixel2r-kms/fixture-panel"
assert_verify_rejects_binding 'a platform binding outside sysfs platform devices'

rm -f -- "$root/sys/bus/platform/drivers/hyperpixel2r-kms/fixture-panel"
ln -s ../../../../devices/platform/fixture-panel \
  "$root/sys/bus/platform/drivers/hyperpixel2r-kms/fixture-panel"
mv "$root/sys/devices/platform/fixture-panel/of_node/compatible" \
  "$root/sys/devices/platform/fixture-panel/of_node/compatible-real"
ln -s compatible-real "$root/sys/devices/platform/fixture-panel/of_node/compatible"
assert_verify_rejects_binding 'a symlinked compatible leaf'

rm -f -- \
  "$root/sys/bus/platform/drivers/hyperpixel2r-kms/fixture-panel" \
  "$root/sys/devices/platform/fixture-panel/of_node/compatible"
mv "$root/sys/devices/platform/fixture-panel/of_node/compatible-real" \
  "$root/sys/devices/platform/fixture-panel/of_node/compatible"
assert_verify_rejects_binding 'zero compatible platform bindings'

ln -s ../../../../devices/platform/fixture-panel \
  "$root/sys/bus/platform/drivers/hyperpixel2r-kms/fixture-panel"
mkdir -p "$root/sys/devices/platform/second-panel/of_node"
printf 'shayne,hyperpixel2r-kms\0' > "$root/sys/devices/platform/second-panel/of_node/compatible"
ln -s ../../../../devices/platform/second-panel \
  "$root/sys/bus/platform/drivers/hyperpixel2r-kms/second-panel"
assert_verify_rejects_binding 'multiple compatible platform bindings'

rm -f -- \
  "$root/sys/bus/platform/drivers/hyperpixel2r-kms/second-panel" \
  "$root/sys/bus/platform/drivers/hyperpixel2r-kms/fixture-panel"
rm -rf -- "$root/sys/devices/platform/second-panel"
ln -s ../../../../devices/platform/fixture-panel \
  "$root/sys/bus/platform/drivers/hyperpixel2r-kms/fixture-panel"
if PATH="$bin:$PATH" HP2R_FIXTURE_ROOT="$root" HP2R_FIXTURE_RELEASE="$release" HP2R_FIXTURE_LOG="$log" HP2R_FIXTURE_REPO_ROOT="$repo_root" HP2R_TARGET=pi@fixture \
  "$repo_root/scripts/verify-boot.sh" --expect-tryboot --expect-overlay-file hyperpixel2r-kms-aaaaaaaaaaaa.dtbo >/dev/null 2>&1; then
  fail 'verify accepted a live overlay that differs from its expected candidate identity'
fi
run_controller commit-boot.sh >/dev/null
assert_absent "$root/boot/firmware/tryboot.txt"
assert_absent "$root/var/lib/hyperpixel2r-kms/tryboot-state"
grep -Eq '^dtoverlay=hyperpixel2r-kms-[0-9a-f]{12}\.dtbo$' "$root/boot/firmware/config.txt" || fail 'commit did not promote generic overlay'

# Commit imports the strict candidate identity before probing live hardware, so
# a loaded module from another version cannot be promoted accidentally.
new_target
run_stage >/dev/null
export HP2R_FIXTURE_LIVE_DRIVER_VERSION=0.2.1
install_live_hardware
if run_controller commit-boot.sh >/dev/null 2>&1; then
  fail 'commit accepted a live module version that differs from the candidate'
fi
unset HP2R_FIXTURE_LIVE_DRIVER_VERSION
assert_file "$root/boot/firmware/tryboot.txt"
assert_file "$root/var/lib/hyperpixel2r-kms/tryboot-state"
install_live_hardware
run_controller commit-boot.sh >/dev/null

# Rollback validates every stored identity before mutating.  State or manifest
# drift is a hard stop; a clean rollback removes candidate leaves and restores
# the normal boot path.
new_target
run_stage >/dev/null
printf 'garbage=1\n' >> "$root/var/lib/hyperpixel2r-kms/tryboot-state"
if run_controller rollback-boot.sh >/dev/null 2>&1; then fail 'rollback accepted state garbage'; fi
assert_file "$root/boot/firmware/tryboot.txt"
new_target
run_stage >/dev/null
printf 'tamper\n' >> "$root/usr/lib/hyperpixel2r-kms/0.2.0/$source_revision/$release/manifest.txt"
if run_controller rollback-boot.sh >/dev/null 2>&1; then fail 'rollback accepted manifest drift'; fi
assert_file "$root/boot/firmware/tryboot.txt"

# Table-driven hostile state and manifest mutations cover each persisted
# identity.  Rollback must fail before it moves state or removes a leaf.
state_mutations=(
  'schema_version:1'
  'driver_version:0.2.1'
  'source_revision:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  'source_tree:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
  'kernel_release:6.18.35+rpt-rpi-v8'
  'module_file:foreign.ko'
  'module_sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
  'overlay_file:hyperpixel2r-kms-aaaaaaaaaaaa.dtbo'
  'overlay_sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
  'applied_dtb_file:foreign.dtb'
  'applied_dtb_sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'
  'normal_config_sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff'
  'candidate_config_sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  'tryboot_existed:true'
  'prior_tryboot_sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
  'replaced_overlay:unsafe/value'
  'module_existed:maybe'
  'overlay_existed:maybe'
  'prior_dkms_inventory_sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  'backlight_rule_file:foreign.rules'
  'backlight_rule_sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  'prior_backlight_rule_existed:maybe'
  'prior_backlight_rule_sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
)
for mutation in "${state_mutations[@]}"; do
  assert_rollback_rejects_state_mutation "${mutation%%:*}" "${mutation#*:}"
done
manifest_mutations=(
  'schema_version:1'
  'driver_version:0.2.1'
  'source_tree:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
  'kernel_release:6.18.35+rpt-rpi-v8'
  'capability:foreign-capability'
  'module_file:foreign.ko'
  'module_sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
  'overlay_sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
  'applied_dtb_file:foreign.dtb'
  'applied_dtb_sha256:ddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
  'backlight_rule_file:foreign.rules'
  'backlight_rule_sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
)
for mutation in "${manifest_mutations[@]}"; do
  assert_rollback_rejects_manifest_mutation "${mutation%%:*}" "${mutation#*:}"
done

# source_revision and overlay_file are a single schema-bound pair.  Alter both
# while keeping the artifact manifest structurally valid, so the state binding
# rather than a malformed manifest must reject it.
new_target
run_stage >/dev/null
artifact="$root/usr/lib/hyperpixel2r-kms/0.2.0/$source_revision/$release"
foreign_revision='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
foreign_overlay='hyperpixel2r-kms-aaaaaaaaaaaa.dtbo'
mv "$artifact/$overlay_file" "$artifact/$foreign_overlay"
replace_manifest_value "$artifact/manifest.txt" source_revision "$foreign_revision"
replace_manifest_value "$artifact/manifest.txt" overlay_file "$foreign_overlay"
if run_controller rollback-boot.sh >/dev/null 2>&1; then
  fail 'rollback accepted source revision and overlay identity drift'
fi
assert_file "$root/boot/firmware/tryboot.txt"
assert_file "$root/var/lib/hyperpixel2r-kms/tryboot-state"

new_target
run_stage >/dev/null
run_controller rollback-boot.sh >/dev/null
assert_absent "$root/usr/src/hyperpixel2r-kms-0.2.0"
assert_file "$root/usr/lib/hyperpixel2r-kms/0.2.0/$source_revision/$release/manifest.txt"
if run_stage >/dev/null 2>&1; then fail 'inactive stored artifact was silently replaced'; fi
assert_file "$root/usr/lib/hyperpixel2r-kms/0.2.0/$source_revision/$release/manifest.txt"

# A future schema-6 authority is readable now, before Task 4 owns writing it.
# The real remote action must return a fixed target-bound authorization tuple.
prepare_inactive_authorization_target
authorization_tuple="$(run_accepted_remote authorize-inactive-stage)" ||
  fail 'read-only inactive authorization rejected an otherwise exact schema-6 fixture'
test "$(awk -F '\t' 'NF == 11 { count++ } END { print count + 0 }' <<<"$authorization_tuple")" = 1 ||
  fail 'inactive authorization did not return the target identity in its fixed tuple'
IFS=$'\t' read -r authorized_release authorized_identity authorized_kernel authorized_kernel_sha \
  authorized_initramfs authorized_initramfs_sha authorized_base_dtb_sha authorized_vc4_sha \
  authorized_transition_sha authorized_stage_rule_existed authorized_stage_rule_sha \
  <<<"$authorization_tuple"
test "$authorized_release" = "$authorization_candidate_release" &&
  test "$authorized_identity" = "$authorization_target_identity_sha256" &&
  test "$authorized_kernel" = "$authorization_candidate_kernel" &&
  test "$authorized_initramfs" = "$authorization_candidate_initramfs" &&
  [[ "$authorized_kernel_sha" =~ ^[0-9a-f]{64}$ ]] &&
  [[ "$authorized_initramfs_sha" =~ ^[0-9a-f]{64}$ ]] &&
  [[ "$authorized_base_dtb_sha" =~ ^[0-9a-f]{64}$ ]] &&
  [[ "$authorized_vc4_sha" =~ ^[0-9a-f]{64}$ ]] &&
  test "$authorized_transition_sha" = \
    "$(sha256sum "$root/var/lib/hyperpixel2r-kms/accepted-transition" | awk '{ print $1 }')" &&
  test "$authorized_stage_rule_existed" = true &&
  test "$authorized_stage_rule_sha" = "$(sha256sum "$backlight_rule_path" | awk '{ print $1 }')" ||
  fail 'inactive authorization tuple did not exactly bind the candidate authority'

# The remote authority is intentionally fail-closed before the controller can
# allocate or upload an inactive firmware payload. Exercise malformed rows and
# every accepted-state binding through the production remote action.
for authorization_mutation in wrong-prior wrong-config duplicate unknown malformed unsafe-name; do
  prepare_inactive_authorization_target
  case "$authorization_mutation" in
    wrong-prior)
      sed -i 's/^prior_driver_version=.*/prior_driver_version=9.9.9/' "$root/var/lib/hyperpixel2r-kms/accepted-transition"
      ;;
    wrong-config)
      sed -i 's/^prior_normal_config_sha256=.*/prior_normal_config_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/' "$root/var/lib/hyperpixel2r-kms/accepted-transition"
      ;;
    duplicate)
      sed -i 's/^candidate_manifest_sha256=/target_identity_sha256=/' "$root/var/lib/hyperpixel2r-kms/accepted-transition"
      ;;
    unknown)
      sed -i 's/^candidate_manifest_sha256=/unknown_authority=/' "$root/var/lib/hyperpixel2r-kms/accepted-transition"
      ;;
    malformed)
      sed -i 's/^candidate_manifest_sha256=.*/candidate_manifest_sha256=bad=field/' "$root/var/lib/hyperpixel2r-kms/accepted-transition"
      ;;
    unsafe-name)
      sed -i 's|^candidate_kernel_file=.*|candidate_kernel_file=../kernel.img|' "$root/var/lib/hyperpixel2r-kms/accepted-transition"
      ;;
  esac
  if run_accepted_remote authorize-inactive-stage >/dev/null 2>&1; then
    fail "inactive authorization accepted $authorization_mutation authority"
  fi
done

exercise_task3_aligned_authority

# The controller must ask the real remote authority before it creates a local
# payload or starts a transfer. The fake SSH endpoint fails only that action.
prepare_inactive_authorization_target
controller_tmp="$fixture/inactive-authority-controller-tmp"
mkdir -p "$controller_tmp"
rm -f -- "$log"
if HP2R_FIXTURE_RUNNING_RELEASE='6.18.33+rpt-rpi-v8' \
  HP2R_FIXTURE_FAIL_INACTIVE_AUTH=1 TMPDIR="$controller_tmp" \
  run_stage --kernel-release "$release" \
    --kernel-target "$repo_root/dist/kernel-target" \
    --target-identity-sha256 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    --stage-only >/dev/null 2>&1
then
  fail 'inactive stage accepted a rejected remote authority'
fi
assert_file "$root/tmp/inactive-authorization-attempted"
test -z "$(find "$controller_tmp" -mindepth 1 -print -quit)" ||
  fail 'inactive stage allocated payload before remote authorization'
test ! -e "$log" || ! grep -q '^scp ' "$log" ||
  fail 'inactive stage uploaded before remote authorization'

# Cross-kernel accepted preparation forwards one fixed, typed provenance tuple
# to the remote writer. Capture the real controller command before the fake
# receiver writes any transition; Task 4 remains the owner of schema-6 writes.
prepare_inactive_authorization_target
if HP2R_FIXTURE_RUNNING_RELEASE='6.18.33+rpt-rpi-v8' \
  HP2R_FIXTURE_CAPTURE_ACCEPTED_PREPARE=1 \
  run_accepted_prepare_controller >/dev/null 2>&1
then
  fail 'accepted prepare fixture did not stop at the remote command capture'
fi
assert_file "$root/tmp/accepted-prepare-command-captured"
prepare_command="$root/tmp/accepted-controller-remote-command"
prepare_target_manifest="$repo_root/dist/kernel-target/$release/target.txt"
test "$(sed -n '1p' "$prepare_command")" = prepare-new-accepted &&
  test "$(sed -n '12p' "$prepare_command")" = \
    bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb &&
  test "$(sed -n '13p' "$prepare_command")" = \
    "$(awk -F '\t' '$1 == "kernel_image_sha256" { print $2 }' "$prepare_target_manifest")" &&
  test "$(sed -n '14p' "$prepare_command")" = \
    "$(awk -F '\t' '$1 == "initramfs_sha256" { print $2 }' "$prepare_target_manifest")" &&
  test "$(sed -n '15p' "$prepare_command")" = \
    "$(awk -F '\t' '$1 == "base_dtb_sha256" { print $2 }' "$prepare_target_manifest")" &&
  test "$(sed -n '16p' "$prepare_command")" = \
    "$(awk -F '\t' '$1 == "vc4_overlay_sha256" { print $2 }' "$prepare_target_manifest")" &&
  test "$(sed -n '17p' "$prepare_command")" = exact-backlight-metadata-v1 &&
  test "$(awk 'END { print NR }' "$prepare_command")" = 17 ||
  fail 'accepted prepare did not forward fixed inactive target provenance'

# Supplying inactive-only flags for the running kernel is rejected by the
# production controller before it can create a stage payload or transfer it.
new_target
rm -f -- "$log"
if run_stage --kernel-release "$release" \
  --kernel-target "$repo_root/dist/kernel-target" \
  --target-identity-sha256 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  --stage-only >/dev/null 2>&1
then
  fail 'same-kernel stage accepted inactive target authority'
fi
test ! -e "$log" || ! grep -q '^scp ' "$log" ||
  fail 'same-kernel inactive flags reached payload upload'

# Verify must bind an explicitly requested kernel release to a fresh remote
# uname result, rather than trusting the local candidate state.
new_target
run_stage >/dev/null
install_live_hardware
if run_verify --expect-kernel-release '6.18.39+rpt-rpi-v8' >/dev/null 2>&1; then
  fail 'verify accepted a fresh uname kernel-release mismatch'
fi

# Uninstall must parse overlay declarations structurally: parameters do not
# make an owned generic overlay safe to ignore.
new_target
run_stage >/dev/null
run_controller rollback-boot.sh >/dev/null
printf 'dtoverlay=hyperpixel2r-kms-aaaaaaaaaaaa.dtbo,rotate=90\n' >> "$root/boot/firmware/config.txt"
if run_controller uninstall.sh >/dev/null 2>&1; then
  fail 'uninstall accepted a parameterized owned generic overlay declaration'
fi
assert_file "$root/usr/lib/hyperpixel2r-kms/0.2.0/$source_revision/$release/manifest.txt"

# All firmware snapshots use one audited root-owned primitive.  The static
# contract rejects the redirection and unprivileged-temp forms that broke the
# real Pi rollback path; executable commit and rollback paths use root:root
# mode-0600 config/tryboot files under the unprivileged remote account.
remote_helper="$repo_root/scripts/lifecycle-remote.sh"
grep -Fq 'dkms_command=/usr/sbin/dkms' "$remote_helper" ||
  fail 'production lifecycle must resolve DKMS through the fixed Trixie sbin path'
if grep -Fq 'command -v dkms' "$remote_helper"; then
  fail 'lifecycle must not infer DKMS absence from the unprivileged SSH PATH'
fi
grep -q '^privileged_snapshot()' "$remote_helper" || fail 'missing privileged snapshot primitive'
grep -q '^new_transaction_workspace()' "$remote_helper" || fail 'missing private transaction workspace primitive'
grep -Fq 'workspace="$(sudo mktemp -d "$state_dir/.hp2r-transaction.XXXXXX")"' "$remote_helper" ||
  fail 'transaction workspace is not allocated by sudo beneath state_dir'
grep -Fq 'assert_owned_dir "$(dirname "$state_dir")"' "$remote_helper" ||
  fail 'transaction workspace does not validate its root-owned parent'
grep -Fq 'sudo chmod 0700 "$workspace"' "$remote_helper" ||
  fail 'transaction workspace is not mode 0700'
test "$(grep -c 'privileged_snapshot "\$' "$remote_helper")" -ge 5 ||
  fail 'not every stage, commit, and rollback snapshot uses the primitive'
if grep -Eq 'sudo[[:space:]]+(cat|sh[[:space:]]+-c).*>' "$remote_helper"; then
  fail 'lifecycle snapshots rely on privileged shell redirection'
fi
if grep -Eq '^[[:space:]]*(normal_snapshot|prior_tryboot|normal_backup|candidate_backup)="\$\(mktemp' "$remote_helper"; then
  fail 'a privileged snapshot is created by the unprivileged SSH user'
fi
if grep -Eq '>>?[[:space:]]*"\$(normal_snapshot|prior_tryboot|normal_backup|candidate_backup)"' "$remote_helper"; then
  fail 'an unprivileged write targets a privileged snapshot'
fi
if grep -En 'privileged_snapshot .*\$\{root\}/tmp|mktemp.*\$\{root\}/tmp.*(lifecycle|candidate|backup)' "$remote_helper"; then
  fail 'a lifecycle snapshot or generated private leaf uses target tmp'
fi
for audited in "$remote_helper" "$repo_root/scripts/stage-tryboot.sh" "$repo_root/scripts/verify-boot.sh" "$repo_root/scripts/common.sh"; do
  if grep -En 'test -[fd].*test ! -L|sudo test -[fd].*sudo test ! -L' "$audited"; then
    fail "a regular-file or directory check dereferences before rejecting a symlink: $audited"
  fi
done
if ! awk '
  /^stage\(\)/ { scope="stage" }
  /^commit\(\)/ { scope="commit" }
  /^rollback\(\)/ { scope="rollback" }
  scope == "stage" && $0 == "  rollback_tmp=\"$(new_transaction_workspace)\" || die '\''failed to create private stage workspace'\''" {
    stage_allocations++
    getline
    if ($0 != "  trap stage_cleanup EXIT") bad=1
  }
  scope == "commit" && $0 == "  workspace=\"$(new_transaction_workspace)\" || die '\''failed to create private commit workspace'\''" {
    commit_allocations++
    getline
    if ($0 != "  trap cleanup_commit EXIT") bad=1
  }
  scope == "rollback" && $0 == "  rb_workspace=\"$(new_transaction_workspace)\" ||" {
    rollback_allocations++
    getline
    if ($0 != "    die '\''failed to create durable rollback workspace'\''") bad=1
    getline
    if ($0 != "  trap cleanup_durable_rollback EXIT") bad=1
  }
  /remove_transaction_workspace \"\$(rollback_tmp|workspace)\" \|\| return 1/ && previous == "  trap - EXIT" { bad=1 }
  { previous=$0 }
  END { exit bad || stage_allocations != 1 || commit_allocations != 1 || rollback_allocations != 1 }
' "$remote_helper"; then
  fail 'workspace EXIT cleanup is not armed immediately or is disarmed before validated deletion'
fi
grep -Fq 'if ! sudo test -e "$workspace"; then return 0; fi' "$remote_helper" ||
  fail 'workspace cleanup does not safely accept an already-absent exact workspace'
grep -Fq 'sudo test ! -e "$workspace"' "$remote_helper" ||
  fail 'workspace cleanup does not verify deletion after exact validated removal'
grep -q '^allocator_workspace_cleanup()' "$remote_helper" ||
  fail 'allocator lacks its pre-final-owner-mode cleanup primitive'
if ! awk '
  /^new_transaction_workspace\(\)/ { allocator=1 }
  /^remove_transaction_workspace\(\)/ { allocator=0 }
  allocator && /workspace="\$\(sudo mktemp -d "\$state_dir\/\.hp2r-transaction\.XXXXXX"\)" \|\| return/ { allocated=1 }
  allocator && allocated && /if ! transaction_workspace_path "\$workspace"; then/ { path_checked=1 }
  allocator && /allocator_workspace_abort "\$workspace"/ { aborts++ }
  allocator && /sudo rm/ { direct_remove=1 }
  END { exit !allocated || !path_checked || aborts != 5 || direct_remove }
' "$remote_helper"; then
  fail 'allocator does not path-validate then locally clean every post-mktemp failure'
fi

new_target
chmod 0600 "$root/boot/firmware/config.txt"
run_stage >/dev/null
chmod 0600 "$root/boot/firmware/tryboot.txt"
test "$(stat -c '%U:%G:%a' "$root/boot/firmware/config.txt")" = root:root:600 || fail 'root-owned normal config fixture drifted'
test "$(stat -c '%U:%G:%a' "$root/boot/firmware/tryboot.txt")" = root:root:600 || fail 'root-owned candidate fixture drifted'
run_controller rollback-boot.sh >/dev/null
assert_absent "$root/boot/firmware/tryboot.txt"
assert_absent "$root/var/lib/hyperpixel2r-kms/tryboot-state"

new_target
chmod 0600 "$root/boot/firmware/config.txt"
run_stage >/dev/null
chmod 0600 "$root/boot/firmware/tryboot.txt"
install_live_hardware
run_controller commit-boot.sh >/dev/null
assert_absent "$root/boot/firmware/tryboot.txt"
assert_absent "$root/var/lib/hyperpixel2r-kms/tryboot-state"

# A successful candidate rollback must reinstate the exact complete
# fixed-version source tree and its registration state—not merely remove the
# generic module and overlay.  The persisted private artifact backup is the
# rollback authority.

# DKMS can retain an installed module built from older bytes even when its
# fixed-version source tree is byte-identical to the incoming candidate.  That
# source-tree match is not sufficient authority to reuse the registration:
# next-boot resolution must select the manifest-exact candidate module.
new_target
prepare_exact_candidate_dkms installed
exact_source_installed_module="$root/lib/modules/$release/updates/dkms/hyperpixel2r_kms.ko"
exact_source_mismatch_sha="$(sha256sum "$exact_source_installed_module" | awk '{ print $1 }')"
candidate_manifest_module="$repo_root/dist/artifacts/$release/hyperpixel2r_kms.ko"
candidate_manifest_module_sha="$(sha256sum "$candidate_manifest_module" | awk '{ print $1 }')"
test "$exact_source_mismatch_sha" != "$candidate_manifest_module_sha" ||
  fail 'exact-source mismatch fixture accidentally matched the candidate module'
PATH="$bin:$PATH" HP2R_FIXTURE_ROOT="$root" HP2R_FIXTURE_RELEASE="$release" depmod -a "$release"
run_stage >/dev/null
first_artifact="$root/usr/lib/hyperpixel2r-kms/0.2.0/$source_revision/$release"
assert_dkms_inventory "$first_artifact/dkms-prior-state" added \
  "$release"$'\taarch64\tinstalled'
assert_absent "$exact_source_installed_module"
test "$(cat "$root/var/lib/dkms/registered")" = added ||
  fail 'mismatched installed registration was not reduced to candidate source registration'
grep -Fxq 'hyperpixel2r_kms.ko: extra/hyperpixel2r_kms.ko' \
  "$root/lib/modules/$release/modules.dep" ||
  fail 'exact source with mismatched installed bytes did not resolve the manifest candidate'

# Exact source plus exact module bytes is not sufficient when depmod still
# resolves the DKMS updates leaf.  The staged transaction promises that the
# manifest-bound /extra leaf is authoritative, so even byte-identical DKMS
# installation state must be detached from the running-kernel resolution.
new_target
prepare_exact_candidate_dkms installed
exact_source_installed_module="$root/lib/modules/$release/updates/dkms/hyperpixel2r_kms.ko"
cp "$candidate_manifest_module" "$exact_source_installed_module"
PATH="$bin:$PATH" HP2R_FIXTURE_ROOT="$root" HP2R_FIXTURE_RELEASE="$release" depmod -a "$release"
run_stage >/dev/null
assert_absent "$exact_source_installed_module"
test "$(cat "$root/var/lib/dkms/registered")" = added ||
  fail 'exact-byte DKMS registration was not reduced to candidate source registration'
grep -Fxq 'hyperpixel2r_kms.ko: extra/hyperpixel2r_kms.ko' \
  "$root/lib/modules/$release/modules.dep" ||
  fail 'stage accepted exact bytes from the wrong module leaf'

# A final regular module leaf is not safe when a mutable ancestor in the
# kernel-module path is a symlink.  Reject the path chain before it can become
# candidate authority.
new_target
module_release_root="$root/lib/modules/$release"
mkdir -p "$module_release_root"
mv "$module_release_root" "$module_release_root.real"
ln -s "$release.real" "$module_release_root"
if run_stage >/dev/null 2>&1; then
  fail 'stage accepted a symlinked kernel-module path ancestor'
fi
assert_absent "$root/var/lib/hyperpixel2r-kms/tryboot-state"

# Compressed modules are decoded only to a fixed output ceiling.  The fixture
# producer writes a completion marker after 9 MiB; a bounded reader closes the
# pipe before that marker can be published.
new_target
prepare_exact_candidate_dkms installed
compressed_installed_module="$root/lib/modules/$release/updates/dkms/hyperpixel2r_kms.ko.gz"
gzip -c "$candidate_manifest_module" > "$compressed_installed_module"
rm -f -- "$root/lib/modules/$release/updates/dkms/hyperpixel2r_kms.ko"
chown root:root "$compressed_installed_module"
chmod 0644 "$compressed_installed_module"
PATH="$bin:$PATH" HP2R_FIXTURE_ROOT="$root" HP2R_FIXTURE_RELEASE="$release" depmod -a "$release"
if HP2R_FIXTURE_GZIP_BOMB=1 run_stage >/dev/null 2>&1; then
  fail 'stage accepted oversized compressed module output'
fi
assert_absent "$root/tmp/gzip-bomb-completed"
assert_absent "$root/var/lib/hyperpixel2r-kms/tryboot-state"

# A valid compressed installed leaf remains supported.  It is byte-exact but
# still detached because only the manifest /extra path can become candidate
# authority.
new_target
prepare_exact_candidate_dkms installed
compressed_installed_module="$root/lib/modules/$release/updates/dkms/hyperpixel2r_kms.ko.gz"
gzip -c "$candidate_manifest_module" > "$compressed_installed_module"
rm -f -- "$root/lib/modules/$release/updates/dkms/hyperpixel2r_kms.ko"
chown root:root "$compressed_installed_module"
chmod 0644 "$compressed_installed_module"
PATH="$bin:$PATH" HP2R_FIXTURE_ROOT="$root" HP2R_FIXTURE_RELEASE="$release" depmod -a "$release"
run_stage >/dev/null
assert_absent "$compressed_installed_module"
grep -Fxq 'hyperpixel2r_kms.ko: extra/hyperpixel2r_kms.ko' \
  "$root/lib/modules/$release/modules.dep" ||
  fail 'valid compressed module staging did not select manifest /extra'

new_target
prepare_prior_dkms successful-rollback
prior_dkms_sums="$fixture/prior-dkms-successful.sums"
(cd "$root/usr/src/hyperpixel2r-kms-0.2.0" && sha256sum * | sed 's#  # #') > "$prior_dkms_sums"
run_stage >/dev/null
first_artifact="$root/usr/lib/hyperpixel2r-kms/0.2.0/$source_revision/$release"
assert_dkms_inventory "$first_artifact/dkms-prior-state" added
assert_file "$first_artifact/prior-dkms/hyperpixel2r_kms_main.c"
run_controller rollback-boot.sh >/dev/null
assert_prior_dkms "$prior_dkms_sums"
assert_absent "$root/boot/firmware/tryboot.txt"
assert_absent "$root/var/lib/hyperpixel2r-kms/tryboot-state"

# The inventory is rollback authority, so a different but still structurally
# valid source state must be rejected by the transaction checksum binding.
new_target
prepare_prior_dkms inventory-checksum-binding
run_stage >/dev/null
first_artifact="$root/usr/lib/hyperpixel2r-kms/0.2.0/$source_revision/$release"
sed -i 's/^source_state=added$/source_state=unregistered/' \
  "$first_artifact/dkms-prior-state"
if run_controller rollback-boot.sh >/dev/null 2>&1; then
  fail 'rollback accepted a checksum-drifted valid DKMS inventory'
fi
assert_file "$root/boot/firmware/tryboot.txt"
assert_file "$root/var/lib/hyperpixel2r-kms/tryboot-state"

# Transactions staged by the public version-1 controller used the collapsed
# `registered` marker and did not record leaf ownership.  They remain valid and
# retain their original add-only rollback behavior after this schema change.
new_target
prepare_prior_dkms version-one-compatibility
prior_dkms_sums="$fixture/prior-dkms-version-one.sums"
(cd "$root/usr/src/hyperpixel2r-kms-0.2.0" && sha256sum * | sed 's#  # #') > "$prior_dkms_sums"
run_stage >/dev/null
first_artifact="$root/usr/lib/hyperpixel2r-kms/0.2.0/$source_revision/$release"
downgrade_artifact_to_schema_one "$first_artifact"
printf 'registered\n' > "$first_artifact/dkms-prior-state"
state="$root/var/lib/hyperpixel2r-kms/tryboot-state"
sed -i \
  -e 's/^schema_version=4$/schema_version=1/' \
  -e '/^module_existed=/d' \
  -e '/^overlay_existed=/d' \
  -e '/^prior_dkms_inventory_sha256=/d' \
  -e '/^backlight_rule_file=/d' \
  -e '/^backlight_rule_sha256=/d' \
  -e '/^prior_backlight_rule_existed=/d' \
  -e '/^prior_backlight_rule_sha256=/d' \
  "$state"
run_controller rollback-boot.sh >/dev/null
assert_prior_dkms "$prior_dkms_sums" added

# Public schema-2 transactions already carried the leaf-presence fields but
# predated the inventory checksum.  Exercise that runtime shape directly,
# instead of covering only the older schema-1 compatibility path.
new_target
prepare_prior_dkms version-two-compatibility
prior_dkms_sums="$fixture/prior-dkms-version-two.sums"
(cd "$root/usr/src/hyperpixel2r-kms-0.2.0" && sha256sum * | sed 's#  # #') > "$prior_dkms_sums"
run_stage >/dev/null
state="$root/var/lib/hyperpixel2r-kms/tryboot-state"
first_artifact="$root/usr/lib/hyperpixel2r-kms/0.2.0/$source_revision/$release"
downgrade_artifact_to_schema_one "$first_artifact"
printf 'registered\n' > "$first_artifact/dkms-prior-state"
sed -i \
  -e 's/^schema_version=4$/schema_version=2/' \
  -e '/^prior_dkms_inventory_sha256=/d' \
  -e '/^backlight_rule_file=/d' \
  -e '/^backlight_rule_sha256=/d' \
  -e '/^prior_backlight_rule_existed=/d' \
  -e '/^prior_backlight_rule_sha256=/d' \
  "$state"
run_controller rollback-boot.sh >/dev/null
assert_prior_dkms "$prior_dkms_sums" added

# The reference Pi entered this transaction with the exact kernel installed
# through DKMS under updates/dkms.  Staging removed that registration and its
# installed module.  Rollback must rebuild and reinstall the captured source
# for the exact kernel before removing the candidate /extra leaf, so module
# resolution returns to the prior installed driver.
new_target
prepare_prior_dkms installed-kernel-rollback installed
prior_dkms_sums="$fixture/prior-dkms-installed.sums"
(cd "$root/usr/src/hyperpixel2r-kms-0.2.0" && sha256sum * | sed 's#  # #') > "$prior_dkms_sums"
prior_installed_module="$root/lib/modules/$release/updates/dkms/hyperpixel2r_kms.ko"
prior_installed_sha="$(sha256sum "$prior_installed_module" | awk '{ print $1 }')"
PATH="$bin:$PATH" HP2R_FIXTURE_ROOT="$root" HP2R_FIXTURE_RELEASE="$release" depmod -a "$release"
grep -Fxq 'hyperpixel2r_kms.ko: updates/dkms/hyperpixel2r_kms.ko' \
  "$root/lib/modules/$release/modules.dep" ||
  fail 'fixture did not begin with the prior DKMS module resolved'
run_stage >/dev/null
first_artifact="$root/usr/lib/hyperpixel2r-kms/0.2.0/$source_revision/$release"
assert_dkms_inventory "$first_artifact/dkms-prior-state" added \
  "$release"$'\taarch64\tinstalled'
assert_absent "$prior_installed_module"
grep -Fxq 'hyperpixel2r_kms.ko: extra/hyperpixel2r_kms.ko' \
  "$root/lib/modules/$release/modules.dep" ||
  fail 'staged candidate did not replace prior DKMS module resolution'
run_controller rollback-boot.sh >/dev/null
assert_prior_dkms "$prior_dkms_sums" installed
assert_file "$prior_installed_module"
test "$(sha256sum "$prior_installed_module" | awk '{ print $1 }')" = "$prior_installed_sha" ||
  fail 'rollback did not restore the exact prior installed DKMS module'
assert_absent "$root/lib/modules/$release/extra/hyperpixel2r_kms.ko"
grep -Fxq 'hyperpixel2r_kms.ko: updates/dkms/hyperpixel2r_kms.ko' \
  "$root/lib/modules/$release/modules.dep" ||
  fail 'rollback did not restore prior DKMS module resolution'

# Raspberry Pi OS DKMS refuses to install the prior fixed-version module while
# the manifest-bound candidate `/extra` leaf still occupies the same module
# name.  Rollback must atomically hold the candidate under a non-loadable leaf,
# restore DKMS, and resolve the prior module without `--force`.
new_target
prepare_exact_candidate_dkms installed
prior_installed_module="$root/lib/modules/$release/updates/dkms/hyperpixel2r_kms.ko"
prior_installed_sha="$(sha256sum "$prior_installed_module" | awk '{ print $1 }')"
PATH="$bin:$PATH" HP2R_FIXTURE_ROOT="$root" HP2R_FIXTURE_RELEASE="$release" depmod -a "$release"
run_stage >/dev/null
assert_absent "$prior_installed_module"
assert_file "$root/lib/modules/$release/extra/hyperpixel2r_kms.ko"
HP2R_FIXTURE_DKMS_REJECT_EXTRA_COLLISION=1 \
  run_controller rollback-boot.sh >/dev/null
assert_file "$prior_installed_module"
test "$(sha256sum "$prior_installed_module" | awk '{ print $1 }')" = "$prior_installed_sha" ||
  fail 'collision-safe rollback did not restore the exact prior module'
assert_absent "$root/lib/modules/$release/extra/hyperpixel2r_kms.ko"
assert_absent "$root/lib/modules/$release/extra/hyperpixel2r_kms.ko.hp2r-rollback-hold"
grep -Fxq 'hyperpixel2r_kms.ko: updates/dkms/hyperpixel2r_kms.ko' \
  "$root/lib/modules/$release/modules.dep" ||
  fail 'collision-safe rollback did not resolve the prior DKMS module'

# The live RC17 transaction schema also permits a manifest-exact /extra module
# that predated staging (`module_existed=true`) while the captured prior DKMS
# inventory contains an installed running-kernel row.  The shared leaf must be
# held during DKMS install to avoid the same real collision, then restored
# byte-for-byte after the prior registration is back.
new_target
prepare_prior_dkms shared-module-installed-rollback installed
shared_installed_module="$root/lib/modules/$release/updates/dkms/hyperpixel2r_kms.ko"
shared_installed_sha="$(sha256sum "$shared_installed_module" | awk '{ print $1 }')"
shared_extra_module="$root/lib/modules/$release/extra/hyperpixel2r_kms.ko"
mkdir -p "$(dirname "$shared_extra_module")"
cp "$candidate_manifest_module" "$shared_extra_module"
chown root:root "$shared_extra_module"
chmod 0644 "$shared_extra_module"
shared_extra_sha="$(sha256sum "$shared_extra_module" | awk '{ print $1 }')"
PATH="$bin:$PATH" HP2R_FIXTURE_ROOT="$root" HP2R_FIXTURE_RELEASE="$release" depmod -a "$release"
run_stage >/dev/null
state="$root/var/lib/hyperpixel2r-kms/tryboot-state"
grep -Fxq 'schema_version=4' "$state" ||
  fail 'shared installed rollback fixture is not a schema-4 transaction'
grep -Fxq 'module_existed=true' "$state" ||
  fail 'shared installed rollback fixture did not record the preexisting module'
first_artifact="$root/usr/lib/hyperpixel2r-kms/0.2.0/$source_revision/$release"
assert_dkms_inventory "$first_artifact/dkms-prior-state" added \
  "$release"$'\taarch64\tinstalled'
assert_absent "$shared_installed_module"
HP2R_FIXTURE_DKMS_REJECT_EXTRA_COLLISION=1 \
  run_controller rollback-boot.sh >/dev/null
assert_file "$shared_installed_module"
test "$(sha256sum "$shared_installed_module" | awk '{ print $1 }')" = "$shared_installed_sha" ||
  fail 'shared-leaf rollback changed the prior installed DKMS module'
assert_file "$shared_extra_module"
test "$(sha256sum "$shared_extra_module" | awk '{ print $1 }')" = "$shared_extra_sha" ||
  fail 'shared-leaf rollback did not restore the preexisting /extra module'
assert_absent "$shared_extra_module.hp2r-rollback-hold"
grep -Fxq 'hyperpixel2r_kms.ko: updates/dkms/hyperpixel2r_kms.ko' \
  "$root/lib/modules/$release/modules.dep" ||
  fail 'shared-leaf rollback did not resolve the prior DKMS module'

# Every durable rollback phase and every operation-before-phase window must
# survive a process exit with only the fixed journal, fixed candidate
# inventory, transaction bundle, and adjacent hold as authority.  Delete all
# private workspaces before replay to prove recovery does not depend on them.
for rollback_module_shape in created shared; do
  for rollback_boundary in \
    rollback-journal-published \
    rollback-candidate-held-unpublished rollback-candidate-held \
    rollback-prior-restored-unpublished rollback-prior-restored \
    rollback-boot-restored-unpublished rollback-boot-restored \
    rollback-candidate-removed-unpublished \
    rollback-depmod-verified rollback-transaction-retired-unpublished
  do
    new_target
    prepare_installed_rollback_shape "$rollback_module_shape" \
      "forward-$rollback_module_shape-$rollback_boundary"
    if HP2R_FIXTURE_DKMS_REJECT_EXTRA_COLLISION=1 \
      HP2R_FIXTURE_INTERRUPT_AFTER="$rollback_boundary" \
      HP2R_FIXTURE_PRESERVE_MUTATIONS=1 \
      run_controller rollback-boot.sh >/dev/null 2>&1; then
      fail "$rollback_module_shape rollback ignored interruption at $rollback_boundary"
    else
      failure_status=$?
    fi
    test "$failure_status" = 97 ||
      fail "$rollback_module_shape rollback interruption at $rollback_boundary returned $failure_status"
    assert_file "$root/var/lib/hyperpixel2r-kms/rollback-state"
    assert_file "$root/var/lib/hyperpixel2r-kms/rollback-candidate-dkms-state"
    test "$(stat -c '%U:%G:%a' "$root/var/lib/hyperpixel2r-kms/rollback-state")" = root:root:600 ||
      fail "$rollback_module_shape journal ownership drifted at $rollback_boundary"
    find "$root/var/lib/hyperpixel2r-kms" -mindepth 1 -maxdepth 1 \
      -type d -name '.hp2r-transaction.*' -exec rm -rf -- {} +
    HP2R_FIXTURE_DKMS_REJECT_EXTRA_COLLISION=1 \
      run_controller rollback-boot.sh >/dev/null
    assert_installed_rollback_shape_restored "$rollback_module_shape" \
      "$rollback_boundary"
  done
done

# A durable journal binds boot state as well as transaction and module state.
# Candidate-state drift must stop an early replay, and restored-state drift
# must stop retirement after the boot-restored phase.
for rollback_boot_drift in \
  candidate-tryboot candidate-overlay restored-tryboot restored-overlay
do
  new_target
  prepare_exact_candidate_dkms installed
  PATH="$bin:$PATH" HP2R_FIXTURE_ROOT="$root" HP2R_FIXTURE_RELEASE="$release" depmod -a "$release"
  run_stage >/dev/null
  rollback_boundary=rollback-journal-published
  case "$rollback_boot_drift" in restored-*) rollback_boundary=rollback-boot-restored ;; esac
  if HP2R_FIXTURE_INTERRUPT_AFTER="$rollback_boundary" \
    HP2R_FIXTURE_PRESERVE_MUTATIONS=1 \
    run_controller rollback-boot.sh >/dev/null 2>&1; then
    fail "boot-drift setup ignored interruption for $rollback_boot_drift"
  fi
  find "$root/var/lib/hyperpixel2r-kms" -mindepth 1 -maxdepth 1 \
    -type d -name '.hp2r-transaction.*' -exec rm -rf -- {} +
  case "$rollback_boot_drift" in
    *-tryboot)
      printf '[all]\n# drifted tryboot state\n' > "$root/boot/firmware/tryboot.txt"
      chown root:root "$root/boot/firmware/tryboot.txt"
      chmod 0644 "$root/boot/firmware/tryboot.txt"
      ;;
    *-overlay)
      printf 'drifted overlay\n' > "$root/boot/firmware/overlays/$overlay_file"
      chown root:root "$root/boot/firmware/overlays/$overlay_file"
      chmod 0644 "$root/boot/firmware/overlays/$overlay_file"
      ;;
  esac
  if run_controller rollback-boot.sh >/dev/null 2>&1; then
    fail "rollback accepted durable boot-state drift: $rollback_boot_drift"
  fi
  assert_file "$root/var/lib/hyperpixel2r-kms/tryboot-state"
  assert_file "$root/var/lib/hyperpixel2r-kms/rollback-state"
done

# Compensation has its own durable replay contract.  Fail prior restoration
# after the candidate source and held module have been detached, interrupt
# compensation at each publication/operation boundary, delete private
# workspaces, then require one rollback invocation to finish compensation and
# the requested rollback.
for rollback_module_shape in created shared; do
  for compensation_boundary in \
    rollback-compensate-mode-published \
    rollback-compensate-dkms-restored \
    rollback-compensate-module-restored \
    rollback-compensate-boot-restored \
    rollback-compensate-depmod-verified \
    rollback-compensate-aux-removed
  do
    new_target
    prepare_installed_rollback_shape "$rollback_module_shape" \
      "compensate-$rollback_module_shape-$compensation_boundary"
    if HP2R_FIXTURE_DKMS_REJECT_EXTRA_COLLISION=1 \
      HP2R_FIXTURE_FAIL_MV=dkms-new \
      HP2R_FIXTURE_INTERRUPT_AFTER="$compensation_boundary" \
      HP2R_FIXTURE_PRESERVE_MUTATIONS=1 \
      run_controller rollback-boot.sh >"$fixture/last-stage-output" 2>&1; then
      fail "$rollback_module_shape compensation ignored interruption at $compensation_boundary"
    else
      failure_status=$?
    fi
    if test "$failure_status" != 97; then
      cat "$fixture/last-stage-output" >&2
      fail "$rollback_module_shape compensation interruption at $compensation_boundary returned $failure_status"
    fi
    assert_file "$root/var/lib/hyperpixel2r-kms/rollback-state"
    grep -Fxq 'mode=compensate' "$root/var/lib/hyperpixel2r-kms/rollback-state" ||
      fail "$rollback_module_shape compensation did not persist mode at $compensation_boundary"
    if test "$compensation_boundary" != rollback-compensate-aux-removed; then
      assert_file "$root/var/lib/hyperpixel2r-kms/rollback-candidate-dkms-state"
    fi
    find "$root/var/lib/hyperpixel2r-kms" -mindepth 1 -maxdepth 1 \
      -type d -name '.hp2r-transaction.*' -exec rm -rf -- {} +
    HP2R_FIXTURE_DKMS_REJECT_EXTRA_COLLISION=1 \
      run_controller rollback-boot.sh >/dev/null
    assert_installed_rollback_shape_restored "$rollback_module_shape" \
      "$compensation_boundary"
  done
done

# A depmod-verified compensation journal may outlive its inventory auxiliary,
# but it must never clear recovery authority unless the live DKMS state still
# equals the checksum-bound candidate inventory.
new_target
prepare_exact_candidate_dkms installed
PATH="$bin:$PATH" HP2R_FIXTURE_ROOT="$root" HP2R_FIXTURE_RELEASE="$release" depmod -a "$release"
run_stage >/dev/null
if HP2R_FIXTURE_FAIL_MV=dkms-new \
  HP2R_FIXTURE_INTERRUPT_AFTER=rollback-compensate-depmod-verified \
  HP2R_FIXTURE_PRESERVE_MUTATIONS=1 \
  run_controller rollback-boot.sh >/dev/null 2>&1; then
  fail 'compensation inventory-drift setup ignored interruption'
fi
grep -Fxq 'mode=compensate' "$root/var/lib/hyperpixel2r-kms/rollback-state" ||
  fail 'compensation inventory-drift setup did not persist compensation mode'
grep -Fxq 'phase=depmod-verified' "$root/var/lib/hyperpixel2r-kms/rollback-state" ||
  fail 'compensation inventory-drift setup did not persist verified phase'
printf 'added\n%s\taarch64\tbuilt\n' "$release" > "$root/var/lib/dkms/registered"
find "$root/var/lib/hyperpixel2r-kms" -mindepth 1 -maxdepth 1 \
  -type d -name '.hp2r-transaction.*' -exec rm -rf -- {} +
if run_controller rollback-boot.sh >/dev/null 2>&1; then
  fail 'compensation accepted live DKMS inventory drift'
fi
assert_file "$root/var/lib/hyperpixel2r-kms/rollback-state"
grep -Fxq 'mode=compensate' "$root/var/lib/hyperpixel2r-kms/rollback-state" ||
  fail 'compensation inventory drift cleared or replaced recovery authority'

# Durable authority is strict.  Malformed, mode-drifted, checksum-drifted, or
# symlinked journal state must block replay without mutating the live
# transaction.  A simultaneous candidate and hold is ambiguous and rejected.
for hostile_rollback_state in \
  journal-mode journal-owner journal-phase transaction-hash \
  inventory-symlink inventory-hash hold-symlink hold-hash module-and-hold
do
  new_target
  prepare_exact_candidate_dkms installed
  PATH="$bin:$PATH" HP2R_FIXTURE_ROOT="$root" HP2R_FIXTURE_RELEASE="$release" depmod -a "$release"
  run_stage >/dev/null
  hostile_boundary=rollback-journal-published
  if test "$hostile_rollback_state" = hold-hash ||
    test "$hostile_rollback_state" = module-and-hold; then
    hostile_boundary=rollback-candidate-held
  fi
  if HP2R_FIXTURE_INTERRUPT_AFTER="$hostile_boundary" \
    HP2R_FIXTURE_PRESERVE_MUTATIONS=1 \
    run_controller rollback-boot.sh >/dev/null 2>&1; then
    fail "hostile rollback setup ignored interruption for $hostile_rollback_state"
  fi
  find "$root/var/lib/hyperpixel2r-kms" -mindepth 1 -maxdepth 1 \
    -type d -name '.hp2r-transaction.*' -exec rm -rf -- {} +
  rollback_journal="$root/var/lib/hyperpixel2r-kms/rollback-state"
  rollback_inventory="$root/var/lib/hyperpixel2r-kms/rollback-candidate-dkms-state"
  rollback_module="$root/lib/modules/$release/extra/hyperpixel2r_kms.ko"
  rollback_hold="${rollback_module}.hp2r-rollback-hold"
  case "$hostile_rollback_state" in
    journal-mode) chmod 0644 "$rollback_journal" ;;
    journal-owner) chown 65534:65534 "$rollback_journal" ;;
    journal-phase) sed -i 's/^phase=prepared$/phase=unsafe/' "$rollback_journal" ;;
    transaction-hash)
      sed -i 's/^transaction_sha256=.*/transaction_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/' \
        "$rollback_journal"
      ;;
    inventory-symlink)
      rm -f -- "$rollback_inventory"
      ln -s /etc/passwd "$rollback_inventory"
      ;;
    inventory-hash) printf '\n' >> "$rollback_inventory" ;;
    hold-symlink) ln -s /etc/passwd "$rollback_hold" ;;
    hold-hash) printf 'drift\n' >> "$rollback_hold" ;;
    module-and-hold) cp "$repo_root/dist/artifacts/$release/hyperpixel2r_kms.ko" "$rollback_module" ;;
  esac
  if run_controller rollback-boot.sh >/dev/null 2>&1; then
    fail "rollback accepted hostile durable state: $hostile_rollback_state"
  fi
  assert_file "$root/var/lib/hyperpixel2r-kms/tryboot-state"
done

# No other lifecycle action may create concurrent authority while a valid
# durable rollback is unresolved.
new_target
run_stage >/dev/null
if HP2R_FIXTURE_INTERRUPT_AFTER=rollback-journal-published \
  HP2R_FIXTURE_PRESERVE_MUTATIONS=1 \
  run_controller rollback-boot.sh >/dev/null 2>&1; then
  fail 'concurrent-action rollback setup ignored interruption'
fi
find "$root/var/lib/hyperpixel2r-kms" -mindepth 1 -maxdepth 1 \
  -type d -name '.hp2r-transaction.*' -exec rm -rf -- {} +
if run_controller commit-boot.sh >/dev/null 2>&1; then
  fail 'commit accepted an unresolved durable rollback'
fi
run_controller rollback-boot.sh >/dev/null

# DKMS registration is version-wide.  Removing it with `--all` destroys every
# built and installed kernel row, so rollback authority must preserve the
# complete bounded inventory rather than only the currently running kernel.
future_release='6.18.35+rpt-rpi-v8'

new_target
prepare_prior_dkms direct-built-rollback built
prior_dkms_sums="$fixture/prior-dkms-direct-built.sums"
(cd "$root/usr/src/hyperpixel2r-kms-0.2.0" && sha256sum * | sed 's#  # #') > "$prior_dkms_sums"
run_stage >/dev/null
first_artifact="$root/usr/lib/hyperpixel2r-kms/0.2.0/$source_revision/$release"
assert_dkms_inventory "$first_artifact/dkms-prior-state" added \
  "$release"$'\taarch64\tbuilt'
run_controller rollback-boot.sh >/dev/null
assert_prior_dkms "$prior_dkms_sums" built

new_target
prepare_prior_dkms running-and-future-installed installed
set_prior_dkms_kernel_state "$future_release" installed
prior_dkms_sums="$fixture/prior-dkms-two-installed.sums"
(cd "$root/usr/src/hyperpixel2r-kms-0.2.0" && sha256sum * | sed 's#  # #') > "$prior_dkms_sums"
running_installed="$root/lib/modules/$release/updates/dkms/hyperpixel2r_kms.ko"
future_installed="$root/lib/modules/$future_release/updates/dkms/hyperpixel2r_kms.ko"
running_installed_sha="$(sha256sum "$running_installed" | awk '{ print $1 }')"
future_installed_sha="$(sha256sum "$future_installed" | awk '{ print $1 }')"
run_stage >/dev/null
first_artifact="$root/usr/lib/hyperpixel2r-kms/0.2.0/$source_revision/$release"
assert_dkms_inventory "$first_artifact/dkms-prior-state" added \
  "$release"$'\taarch64\tinstalled' \
  "$future_release"$'\taarch64\tinstalled'
assert_absent "$running_installed"
assert_absent "$future_installed"
run_controller rollback-boot.sh >/dev/null
assert_prior_dkms "$prior_dkms_sums" installed
assert_dkms_kernel_state "$future_release" installed
test "$(sha256sum "$running_installed" | awk '{ print $1 }')" = "$running_installed_sha" ||
  fail 'rollback changed the running-kernel DKMS module'
test "$(sha256sum "$future_installed" | awk '{ print $1 }')" = "$future_installed_sha" ||
  fail 'rollback changed the future-kernel DKMS module'

new_target
prepare_prior_dkms mixed-built-installed built
set_prior_dkms_kernel_state "$future_release" installed
prior_dkms_sums="$fixture/prior-dkms-mixed.sums"
(cd "$root/usr/src/hyperpixel2r-kms-0.2.0" && sha256sum * | sed 's#  # #') > "$prior_dkms_sums"
future_installed="$root/lib/modules/$future_release/updates/dkms/hyperpixel2r_kms.ko"
future_installed_sha="$(sha256sum "$future_installed" | awk '{ print $1 }')"
run_stage >/dev/null
first_artifact="$root/usr/lib/hyperpixel2r-kms/0.2.0/$source_revision/$release"
assert_dkms_inventory "$first_artifact/dkms-prior-state" added \
  "$release"$'\taarch64\tbuilt' \
  "$future_release"$'\taarch64\tinstalled'
run_controller rollback-boot.sh >/dev/null
assert_prior_dkms "$prior_dkms_sums" built
assert_dkms_kernel_state "$future_release" installed
test "$(sha256sum "$future_installed" | awk '{ print $1 }')" = "$future_installed_sha" ||
  fail 'mixed-state rollback changed the future-kernel DKMS module'

new_target
prepare_prior_dkms future-only-installed
set_prior_dkms_kernel_state "$future_release" installed
prior_dkms_sums="$fixture/prior-dkms-future-only.sums"
(cd "$root/usr/src/hyperpixel2r-kms-0.2.0" && sha256sum * | sed 's#  # #') > "$prior_dkms_sums"
future_installed="$root/lib/modules/$future_release/updates/dkms/hyperpixel2r_kms.ko"
future_installed_sha="$(sha256sum "$future_installed" | awk '{ print $1 }')"
run_stage >/dev/null
first_artifact="$root/usr/lib/hyperpixel2r-kms/0.2.0/$source_revision/$release"
assert_dkms_inventory "$first_artifact/dkms-prior-state" added \
  "$future_release"$'\taarch64\tinstalled'
run_controller rollback-boot.sh >/dev/null
assert_prior_dkms "$prior_dkms_sums" inventory
assert_dkms_kernel_state "$future_release" installed
test "$(sha256sum "$future_installed" | awk '{ print $1 }')" = "$future_installed_sha" ||
  fail 'future-only rollback changed the installed DKMS module'

# A stage failure after `dkms remove --all` must restore the same complete
# inventory before it removes the private rollback authority.
new_target
prepare_prior_dkms multi-kernel-stage-cleanup installed
set_prior_dkms_kernel_state "$future_release" installed
prior_dkms_sums="$fixture/prior-dkms-multi-stage-cleanup.sums"
(cd "$root/usr/src/hyperpixel2r-kms-0.2.0" && sha256sum * | sed 's#  # #') > "$prior_dkms_sums"
running_installed="$root/lib/modules/$release/updates/dkms/hyperpixel2r_kms.ko"
future_installed="$root/lib/modules/$future_release/updates/dkms/hyperpixel2r_kms.ko"
running_installed_sha="$(sha256sum "$running_installed" | awk '{ print $1 }')"
future_installed_sha="$(sha256sum "$future_installed" | awk '{ print $1 }')"
export HP2R_FIXTURE_FAIL_MV=stage-state
if run_stage >/dev/null 2>&1; then fail 'multi-kernel stage cleanup accepted injected state failure'; fi
unset HP2R_FIXTURE_FAIL_MV
assert_prior_dkms "$prior_dkms_sums" installed
assert_dkms_kernel_state "$future_release" installed
test "$(sha256sum "$running_installed" | awk '{ print $1 }')" = "$running_installed_sha" ||
  fail 'stage cleanup changed the running-kernel DKMS module'
test "$(sha256sum "$future_installed" | awk '{ print $1 }')" = "$future_installed_sha" ||
  fail 'stage cleanup changed the future-kernel DKMS module'

# Staging can reuse an exact module or overlay already owned by the prior
# normal boot.  Rollback must retain those shared bytes; deleting them leaves
# the restored config with no driver, which is exactly what happened on the
# reference Pi.
new_target
prepare_prior_dkms shared-installed-state
prior_module="$root/lib/modules/$release/extra/hyperpixel2r_kms.ko"
prior_overlay="$root/boot/firmware/overlays/$overlay_file"
mkdir -p "$(dirname "$prior_module")" "$(dirname "$prior_overlay")"
cp "$repo_root/dist/artifacts/$release/hyperpixel2r_kms.ko" "$prior_module"
cp "$repo_root/dist/artifacts/$release/$overlay_file" "$prior_overlay"
chown root:root "$prior_module" "$prior_overlay"
chmod 0644 "$prior_module" "$prior_overlay"
prior_module_sha="$(sha256sum "$prior_module" | awk '{ print $1 }')"
prior_overlay_sha="$(sha256sum "$prior_overlay" | awk '{ print $1 }')"
run_stage >/dev/null
run_controller rollback-boot.sh >/dev/null
assert_file "$prior_module"
assert_file "$prior_overlay"
test "$(sha256sum "$prior_module" | awk '{ print $1 }')" = "$prior_module_sha" ||
  fail 'rollback changed the exact shared prior module'
test "$(sha256sum "$prior_overlay" | awk '{ print $1 }')" = "$prior_overlay_sha" ||
  fail 'rollback changed the exact shared prior overlay'

# The same persistence restores an unregistered preexisting tree without
# inventing a DKMS registration during rollback.
new_target
prepare_prior_dkms successful-unregistered unregistered
prior_dkms_sums="$fixture/prior-dkms-unregistered.sums"
(cd "$root/usr/src/hyperpixel2r-kms-0.2.0" && sha256sum * | sed 's#  # #') > "$prior_dkms_sums"
run_stage >/dev/null
first_artifact="$root/usr/lib/hyperpixel2r-kms/0.2.0/$source_revision/$release"
assert_dkms_inventory "$first_artifact/dkms-prior-state" unregistered
run_controller rollback-boot.sh >/dev/null
assert_prior_dkms "$prior_dkms_sums" unregistered

# If a later rollback step fails after source restoration, compensation must
# put the candidate source/status back before leaving its state replayable.
new_target
prepare_prior_dkms rollback-compensation
run_stage >/dev/null
set_prior_dkms_kernel_state "$future_release" installed
candidate_future_module="$root/lib/modules/$future_release/updates/dkms/hyperpixel2r_kms.ko"
candidate_future_sha="$(sha256sum "$candidate_future_module" | awk '{ print $1 }')"
candidate_dkms_sums="$fixture/candidate-dkms-compensation.sums"
(cd "$root/usr/src/hyperpixel2r-kms-0.2.0" && sha256sum * | sed 's#  # #') > "$candidate_dkms_sums"
export HP2R_FIXTURE_FAIL_MV=module-hold
if run_controller rollback-boot.sh >/dev/null 2>&1; then fail 'rollback accepted injected state move failure'; fi
unset HP2R_FIXTURE_FAIL_MV
while IFS=' ' read -r expected name; do
  test "$(sha256sum "$root/usr/src/hyperpixel2r-kms-0.2.0/$name" | awk '{print $1}')" = "$expected" ||
    fail "rollback compensation did not restore candidate DKMS bytes: $name"
done < "$candidate_dkms_sums"
assert_file "$root/var/lib/dkms/registered"
assert_dkms_kernel_state "$future_release" installed
test "$(sha256sum "$candidate_future_module" | awk '{ print $1 }')" = "$candidate_future_sha" ||
  fail 'rollback compensation changed the candidate future-kernel module'
assert_file "$root/boot/firmware/tryboot.txt"
assert_file "$root/var/lib/hyperpixel2r-kms/tryboot-state"
run_controller rollback-boot.sh >/dev/null

# Registration status is optional evidence; source-tree presence is not.  With
# dkms absent, a later rollback failure must still reconstruct the candidate
# tree exactly so the transaction can be replayed after dkms returns.
new_target
prepare_prior_dkms rollback-no-dkms
run_stage >/dev/null
candidate_dkms_sums="$fixture/candidate-dkms-no-dkms.sums"
(cd "$root/usr/src/hyperpixel2r-kms-0.2.0" && sha256sum * | sed 's#  # #') > "$candidate_dkms_sums"
export HP2R_FIXTURE_NO_DKMS=1 HP2R_FIXTURE_FAIL_MV=module-hold
if run_controller rollback-boot.sh >/dev/null 2>&1; then
  fail 'rollback accepted injected state move failure without dkms'
fi
unset HP2R_FIXTURE_NO_DKMS HP2R_FIXTURE_FAIL_MV
while IFS=' ' read -r expected name; do
  test "$(sha256sum "$root/usr/src/hyperpixel2r-kms-0.2.0/$name" | awk '{print $1}')" = "$expected" ||
    fail "no-dkms rollback compensation did not restore candidate bytes: $name"
done < "$candidate_dkms_sums"
assert_file "$root/boot/firmware/tryboot.txt"
assert_file "$root/var/lib/hyperpixel2r-kms/tryboot-state"
run_controller rollback-boot.sh >/dev/null

# Source restoration itself is transactional: an atomic publish failure after
# candidate removal restores the candidate bytes and registration for replay.
new_target
prepare_prior_dkms rollback-source-compensation
run_stage >/dev/null
candidate_dkms_sums="$fixture/candidate-dkms-source-compensation.sums"
(cd "$root/usr/src/hyperpixel2r-kms-0.2.0" && sha256sum * | sed 's#  # #') > "$candidate_dkms_sums"
export HP2R_FIXTURE_FAIL_MV=dkms-new
if run_controller rollback-boot.sh >/dev/null 2>&1; then fail 'rollback accepted injected DKMS source publish failure'; fi
unset HP2R_FIXTURE_FAIL_MV
while IFS=' ' read -r expected name; do
  test "$(sha256sum "$root/usr/src/hyperpixel2r-kms-0.2.0/$name" | awk '{print $1}')" = "$expected" ||
    fail "rollback source compensation did not restore candidate bytes: $name"
done < "$candidate_dkms_sums"
assert_file "$root/var/lib/dkms/registered"
assert_file "$root/boot/firmware/tryboot.txt"
assert_file "$root/var/lib/hyperpixel2r-kms/tryboot-state"
run_controller rollback-boot.sh >/dev/null

# Replacement failure at unregister, atomic source publication, or any later
# stage boundary restores the complete old source tree and prior registration.
for replacement_fault in dkms-remove dkms-new stage-state; do
  new_target
  prepare_prior_dkms "$replacement_fault"
  prior_dkms_sums="$fixture/prior-dkms-${replacement_fault}.sums"
  (cd "$root/usr/src/hyperpixel2r-kms-0.2.0" && sha256sum * | sed 's#  # #') > "$prior_dkms_sums"
  case "$replacement_fault" in
    dkms-remove) export HP2R_FIXTURE_FAIL_DKMS_REMOVE=1 ;;
    dkms-new|stage-state) export HP2R_FIXTURE_FAIL_MV="$replacement_fault" ;;
  esac
  if run_stage >/dev/null 2>&1; then fail "DKMS replacement accepted injected $replacement_fault failure"; fi
  unset HP2R_FIXTURE_FAIL_DKMS_REMOVE HP2R_FIXTURE_FAIL_MV || true
  assert_prior_dkms "$prior_dkms_sums"
  assert_absent "$root/boot/firmware/tryboot.txt"
  assert_absent "$root/var/lib/hyperpixel2r-kms/tryboot-state"
done
assert_absent "$root/boot/firmware/tryboot.txt"
assert_absent "$root/var/lib/hyperpixel2r-kms/tryboot-state"
assert_absent "$root/lib/modules/$release/extra/hyperpixel2r_kms.ko"
assert_absent "$root/boot/firmware/overlays/$overlay_file"

# Existing reused DKMS trees are complete, regular, root-owned source trees.
# An extra or symlinked leaf is rejected before it can be reused or registered.
printf 'foreign\n' > "$root/usr/src/hyperpixel2r-kms-0.2.0/foreign.c"
if run_stage >/dev/null 2>&1; then fail 'extra DKMS leaf was accepted'; fi
rm -f -- "$root/usr/src/hyperpixel2r-kms-0.2.0/foreign.c"
rm -f -- "$root/usr/src/hyperpixel2r-kms-0.2.0/Kbuild"
ln -s /etc/passwd "$root/usr/src/hyperpixel2r-kms-0.2.0/Kbuild"
if run_stage >/dev/null 2>&1; then fail 'symlinked DKMS leaf was accepted'; fi
rm -f -- "$root/usr/src/hyperpixel2r-kms-0.2.0/Kbuild"
printf 'fixture committed source: Kbuild\n' > "$root/usr/src/hyperpixel2r-kms-0.2.0/Kbuild"

# A new committed source revision may reuse the fixed DKMS package version.
# Its proven old tree is backed up, unregistered, replaced, and registered
# again; the fresh source bytes—not the stale tree—must be left active.
printf 'stale but regular source\n' > "$root/usr/src/hyperpixel2r-kms-0.2.0/hyperpixel2r_kms_main.c"
run_stage >/dev/null
grep -Fq 'fixture committed source: hyperpixel2r_kms_main.c' \
  "$root/usr/src/hyperpixel2r-kms-0.2.0/hyperpixel2r_kms_main.c" ||
  fail 'DKMS source replacement did not install committed bytes'
grep -Fq 'dkms remove -m hyperpixel2r-kms -v 0.2.0 --all' "$log" ||
  fail 'DKMS source replacement did not unregister the prior registration'
run_controller rollback-boot.sh >/dev/null

# Add a second release for the original version plus an independent candidate
# source tree for a second driver version.  Uninstall must validate all stored
# bundles before it mutates anything, preserve the recognized prior 0.2.0 tree,
# and remove only the candidate-owned 0.2.1 tree.
second_release='6.18.35+rpt-rpi-v8'
second_revision='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
first_artifact="$root/usr/lib/hyperpixel2r-kms/0.2.0/$source_revision/$release"
second_artifact="$root/usr/lib/hyperpixel2r-kms/0.2.0/$second_revision/$second_release"
mkdir -p "$(dirname "$second_artifact")"
cp -a "$first_artifact" "$second_artifact"
mv "$second_artifact/$overlay_file" "$second_artifact/hyperpixel2r-kms-aaaaaaaaaaaa.dtbo"
sed -i \
  -e "s/^source_revision\t.*/source_revision\t$second_revision/" \
  -e 's/^source_tree\t.*/source_tree\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/' \
  -e "s/^kernel_release\t.*/kernel_release\t$second_release/" \
  -e 's/^overlay_file\t.*/overlay_file\thyperpixel2r-kms-aaaaaaaaaaaa.dtbo/' \
  "$second_artifact/manifest.txt"
mkdir -p "$root/lib/modules/$second_release/extra" "$root/boot/firmware/overlays"
cp "$second_artifact/hyperpixel2r_kms.ko" "$root/lib/modules/$second_release/extra/hyperpixel2r_kms.ko"
cp "$second_artifact/hyperpixel2r-kms-aaaaaaaaaaaa.dtbo" "$root/boot/firmware/overlays/hyperpixel2r-kms-aaaaaaaaaaaa.dtbo"
third_version='0.2.1'
third_release='6.18.36+rpt-rpi-v8'
third_revision='cccccccccccccccccccccccccccccccccccccccc'
third_overlay='hyperpixel2r-kms-cccccccccccc.dtbo'
third_artifact="$root/usr/lib/hyperpixel2r-kms/$third_version/$third_revision/$third_release"
mkdir -p "$(dirname "$third_artifact")"
cp -a "$first_artifact" "$third_artifact"
mv "$third_artifact/$overlay_file" "$third_artifact/$third_overlay"
sed -i \
  -e "s/^driver_version\t.*/driver_version\t$third_version/" \
  -e "s/^source_revision\t.*/source_revision\t$third_revision/" \
  -e 's/^source_tree\t.*/source_tree\tdddddddddddddddddddddddddddddddddddddddd/' \
  -e "s/^kernel_release\t.*/kernel_release\t$third_release/" \
  -e "s/^overlay_file\t.*/overlay_file\t$third_overlay/" \
  "$third_artifact/manifest.txt"
mkdir -p "$root/lib/modules/$third_release/extra"
cp "$third_artifact/hyperpixel2r_kms.ko" "$root/lib/modules/$third_release/extra/hyperpixel2r_kms.ko"
cp "$third_artifact/$third_overlay" "$root/boot/firmware/overlays/$third_overlay"
cp -a "$third_artifact/dkms-source" "$root/usr/src/hyperpixel2r-kms-$third_version"
printf 'added\n' > "$root/var/lib/dkms/registered-$third_version"

# A malformed third group must stop the all-or-nothing validation pass before
# it can remove either valid version's source tree or installed leaves.
malformed_version_dir="$root/usr/lib/hyperpixel2r-kms/0.3.0"
mkdir -p "$malformed_version_dir/not-a-revision"
if run_controller uninstall.sh >/dev/null 2>&1; then
  fail 'uninstall accepted a mixed malformed artifact state'
fi
assert_file "$root/usr/src/hyperpixel2r-kms-0.2.0/hyperpixel2r_kms_main.c"
assert_file "$root/usr/src/hyperpixel2r-kms-$third_version/hyperpixel2r_kms_main.c"
rmdir -- "$malformed_version_dir/not-a-revision" "$malformed_version_dir"

# Uninstall is idempotent after the rollback.  It removes only checksum-proven
# owned leaves across every recorded release and source tree.
if ! run_controller uninstall.sh >/dev/null 2>&1; then
  fail 'uninstall failed to reconcile the validated multi-version artifact set'
fi
assert_absent "$root/usr/lib/hyperpixel2r-kms"
assert_file "$root/usr/src/hyperpixel2r-kms-0.2.0/hyperpixel2r_kms_main.c"
assert_file "$root/var/lib/dkms/registered"
assert_absent "$root/usr/src/hyperpixel2r-kms-$third_version"
assert_absent "$root/var/lib/dkms/registered-$third_version"
assert_absent "$root/lib/modules/$second_release/extra/hyperpixel2r_kms.ko"
assert_absent "$root/boot/firmware/overlays/hyperpixel2r-kms-aaaaaaaaaaaa.dtbo"
assert_absent "$root/lib/modules/$third_release/extra/hyperpixel2r_kms.ko"
assert_absent "$root/boot/firmware/overlays/$third_overlay"
test "$(grep -c "depmod -a $release" "$log")" -ge 1 || fail 'uninstall did not depmod first recorded release'
test "$(grep -c "depmod -a $second_release" "$log")" -ge 1 || fail 'uninstall did not depmod second recorded release'
test "$(grep -c "depmod -a $third_release" "$log")" -ge 1 || fail 'uninstall did not depmod third recorded release'
run_controller uninstall.sh >/dev/null

# A saved pre-stage tryboot backup is an owned artifact leaf, not a reason to
# strand an otherwise inactive driver during uninstall.
new_target
printf '[all]\n# older candidate\n' > "$root/boot/firmware/tryboot.txt"
chmod 0600 "$root/boot/firmware/tryboot.txt"
run_stage >/dev/null
run_controller rollback-boot.sh >/dev/null
run_controller uninstall.sh >/dev/null
assert_absent "$root/usr/lib/hyperpixel2r-kms"

# Legacy Plane Radar cleanup is a separate, exact migration mode of the
# existing Uninstall action. It must validate every mutation target before
# removing anything, preserve unrelated overlays and the recovery baseline,
# retain durable evidence, and be a no-op on repeat.
prepare_legacy_cleanup() {
  local contract="$fixture/legacy-migration.tsv"
  local source_dir="$root/usr/src/planeradar-hyperpixel2r-0.1.0"
  local baseline="$root/boot/firmware/config.txt.task6-baseline.fixture.bak"
  local legacy_overlay

  new_target
  printf '[all]\ndtoverlay=vc4-kms-v3d\ndtoverlay=hyperpixel2r-kms-aaaaaaaaaaaa.dtbo\n' \
    > "$root/boot/firmware/config.txt"
  cp "$root/boot/firmware/config.txt" "$baseline"
  mkdir -p "$source_dir" "$root/var/lib/dkms"
  printf 'legacy Kbuild\n' > "$source_dir/Kbuild"
  printf 'legacy source\n' > "$source_dir/planeradar_hyperpixel2r_main.c"
  chown -R root:root "$source_dir"
  chmod 0755 "$source_dir"
  chmod 0644 "$source_dir"/*
  printf 'added\n' > "$root/var/lib/dkms/registered-planeradar"
  for legacy_overlay in \
    planeradar-hyperpixel2r-111111111111.dtbo \
    planeradar-hyperpixel2r-222222222222.dtbo; do
    printf 'owned legacy overlay\n' > "$root/boot/firmware/overlays/$legacy_overlay"
    chmod 0644 "$root/boot/firmware/overlays/$legacy_overlay"
  done
  printf 'foreign overlay\n' \
    > "$root/boot/firmware/overlays/planeradar-hyperpixel2r-ffffffffffff.dtbo"
  chmod 0644 "$root/boot/firmware/overlays/planeradar-hyperpixel2r-ffffffffffff.dtbo"
  {
    printf 'schema_version\t1\n'
    printf 'migration_id\tplaneradar-hyperpixel2r-v1\n'
    printf 'legacy_module\tplaneradar-hyperpixel2r\n'
    printf 'legacy_version\t0.1.0\n'
    printf 'source_dir\t/usr/src/planeradar-hyperpixel2r-0.1.0\n'
    printf 'source_file\tKbuild\t%s\n' "$(sha256sum "$source_dir/Kbuild" | awk '{print $1}')"
    printf 'source_file\tplaneradar_hyperpixel2r_main.c\t%s\n' \
      "$(sha256sum "$source_dir/planeradar_hyperpixel2r_main.c" | awk '{print $1}')"
    for legacy_overlay in \
      planeradar-hyperpixel2r-111111111111.dtbo \
      planeradar-hyperpixel2r-222222222222.dtbo; do
      printf 'overlay_file\t%s\t%s\n' "$legacy_overlay" \
        "$(sha256sum "$root/boot/firmware/overlays/$legacy_overlay" | awk '{print $1}')"
    done
    printf 'recovery_baseline\t/boot/firmware/config.txt.task6-baseline.fixture.bak\t%s\n' \
      "$(sha256sum "$baseline" | awk '{print $1}')"
  } > "$contract"
  HP2R_LEGACY_MIGRATION_CONTRACT="$contract"
  export HP2R_LEGACY_MIGRATION_CONTRACT
}

run_legacy_cleanup() {
  run_controller uninstall.sh \
    --cleanup-legacy-planeradar \
    --expect-overlay-file hyperpixel2r-kms-aaaaaaaaaaaa.dtbo
}

prepare_legacy_cleanup
export HP2R_FIXTURE_NO_DKMS=1
if run_legacy_cleanup >/dev/null 2>&1; then
  fail 'legacy cleanup accepted missing DKMS tooling as registration proof'
fi
unset HP2R_FIXTURE_NO_DKMS
assert_file "$root/usr/src/planeradar-hyperpixel2r-0.1.0/Kbuild"
assert_file "$root/var/lib/dkms/registered-planeradar"
assert_file "$root/boot/firmware/overlays/planeradar-hyperpixel2r-111111111111.dtbo"

for legacy_interruption in \
  source-quarantine overlay-quarantine source-delete overlay-delete; do
  prepare_legacy_cleanup
  interrupted_baseline_sha="$(sha256sum "$root/boot/firmware/config.txt.task6-baseline.fixture.bak" | awk '{print $1}')"
  export HP2R_FIXTURE_FAIL_LEGACY_AT="$legacy_interruption"
  if run_legacy_cleanup >/dev/null 2>&1; then
    fail "legacy cleanup did not stop at injected $legacy_interruption boundary"
  fi
  unset HP2R_FIXTURE_FAIL_LEGACY_AT
  pending="$root/var/lib/hyperpixel2r-kms/migrations/planeradar-hyperpixel2r-v1/pending.tsv"
  assert_file "$pending"
  test "$(stat -c '%U:%G:%a' "$pending")" = root:root:600 ||
    fail "legacy cleanup pending state is not root-private after $legacy_interruption"
  grep -Fq $'result\tpending' \
    "$root/var/lib/hyperpixel2r-kms/migrations/planeradar-hyperpixel2r-v1/events.log" ||
    fail "legacy cleanup did not record pending before $legacy_interruption"

  run_legacy_cleanup >/dev/null
  assert_absent "$pending"
  assert_absent "$root/usr/src/planeradar-hyperpixel2r-0.1.0"
  assert_absent "$root/usr/src/.planeradar-hyperpixel2r-v1.quarantine"
  assert_absent "$root/var/lib/dkms/registered-planeradar"
  assert_absent "$root/boot/firmware/overlays/planeradar-hyperpixel2r-111111111111.dtbo"
  assert_absent "$root/boot/firmware/overlays/planeradar-hyperpixel2r-222222222222.dtbo"
  assert_absent "$root/boot/firmware/overlays/.planeradar-hyperpixel2r-v1.quarantine.planeradar-hyperpixel2r-111111111111.dtbo"
  assert_absent "$root/boot/firmware/overlays/.planeradar-hyperpixel2r-v1.quarantine.planeradar-hyperpixel2r-222222222222.dtbo"
  assert_file "$root/boot/firmware/overlays/planeradar-hyperpixel2r-ffffffffffff.dtbo"
  test "$(sha256sum "$root/boot/firmware/config.txt.task6-baseline.fixture.bak" | awk '{print $1}')" = "$interrupted_baseline_sha" ||
    fail "legacy cleanup changed recovery baseline after $legacy_interruption"
  grep -Fq $'result\tremoved' \
    "$root/var/lib/hyperpixel2r-kms/migrations/planeradar-hyperpixel2r-v1/events.log" ||
    fail "legacy cleanup did not record recovered completion after $legacy_interruption"

  run_legacy_cleanup >/dev/null
  grep -Fq $'result\talready-absent' \
    "$root/var/lib/hyperpixel2r-kms/migrations/planeradar-hyperpixel2r-v1/events.log" ||
    fail "legacy cleanup was not idempotent after recovering $legacy_interruption"
done

prepare_legacy_cleanup
legacy_baseline_sha="$(sha256sum "$root/boot/firmware/config.txt.task6-baseline.fixture.bak" | awk '{print $1}')"
run_legacy_cleanup >/dev/null
assert_absent "$root/usr/src/planeradar-hyperpixel2r-0.1.0"
assert_absent "$root/var/lib/dkms/registered-planeradar"
assert_absent "$root/boot/firmware/overlays/planeradar-hyperpixel2r-111111111111.dtbo"
assert_absent "$root/boot/firmware/overlays/planeradar-hyperpixel2r-222222222222.dtbo"
assert_file "$root/boot/firmware/overlays/planeradar-hyperpixel2r-ffffffffffff.dtbo"
test "$(sha256sum "$root/boot/firmware/config.txt.task6-baseline.fixture.bak" | awk '{print $1}')" = "$legacy_baseline_sha" ||
  fail 'legacy cleanup changed the recovery baseline'
grep -Fxq 'dtoverlay=hyperpixel2r-kms-aaaaaaaaaaaa.dtbo' "$root/boot/firmware/config.txt" ||
  fail 'legacy cleanup changed the accepted external overlay'
assert_file "$root/var/lib/hyperpixel2r-kms/migrations/planeradar-hyperpixel2r-v1/manifest.tsv"
assert_file "$root/var/lib/hyperpixel2r-kms/migrations/planeradar-hyperpixel2r-v1/events.log"
grep -Fq $'result\tremoved' "$root/var/lib/hyperpixel2r-kms/migrations/planeradar-hyperpixel2r-v1/events.log" ||
  fail 'legacy cleanup did not retain completion evidence'
run_legacy_cleanup >/dev/null
grep -Fq $'result\talready-absent' "$root/var/lib/hyperpixel2r-kms/migrations/planeradar-hyperpixel2r-v1/events.log" ||
  fail 'repeat legacy cleanup was not a recorded no-op'

for hostile_legacy_state in active loaded source-hash overlay-hash transaction; do
  prepare_legacy_cleanup
  case "$hostile_legacy_state" in
    active)
      printf 'dtoverlay=planeradar-hyperpixel2r-111111111111.dtbo\n' \
        >> "$root/boot/firmware/config.txt"
      ;;
    loaded)
      mkdir -p "$root/sys/module/planeradar_hyperpixel2r"
      ;;
    source-hash)
      printf 'tampered\n' > "$root/usr/src/planeradar-hyperpixel2r-0.1.0/Kbuild"
      ;;
    overlay-hash)
      printf 'tampered\n' \
        > "$root/boot/firmware/overlays/planeradar-hyperpixel2r-111111111111.dtbo"
      ;;
    transaction)
      mkdir -p "$root/var/lib/hyperpixel2r-kms"
      printf 'active\n' > "$root/var/lib/hyperpixel2r-kms/tryboot-state"
      ;;
  esac
  if run_legacy_cleanup >/dev/null 2>&1; then
    fail "legacy cleanup accepted hostile state: $hostile_legacy_state"
  fi
  assert_file "$root/usr/src/planeradar-hyperpixel2r-0.1.0/Kbuild"
  assert_file "$root/var/lib/dkms/registered-planeradar"
  assert_file "$root/boot/firmware/overlays/planeradar-hyperpixel2r-111111111111.dtbo"
done
unset HP2R_LEGACY_MIGRATION_CONTRACT

printf 'Driver executable boot fixtures passed\n'
