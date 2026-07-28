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
fixture="$(mktemp -d)"
chmod 0755 "$fixture"
root="$fixture/root"
bin="$fixture/bin"
bin_no_dkms="$fixture/bin-no-dkms"
log="$fixture/commands.log"

cleanup() {
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

assert_no_private_workspaces() {
  local workspace

  test -d "$root/var/lib/hyperpixel2r-kms" || return 0
  workspace="$(find "$root/var/lib/hyperpixel2r-kms" -mindepth 1 -maxdepth 1 \
    -name '.hp2r-transaction.*' -print -quit)"
  test -z "$workspace" || fail "private transaction workspace survived: $workspace"
}

assert_incoming_stage_cleaned() {
  assert_absent "$root/tmp/hp2r-tryboot-stage.fixture"
}

new_target() {
  rm -rf -- "$root" "$bin" "$bin_no_dkms" "$log"
  mkdir -p "$root/boot/firmware/overlays" "$root/tmp" "$root/var/lib" "$bin"
  chmod 1777 "$root/tmp"
  printf '[all]\ndtoverlay=vc4-kms-dpi-hyperpixel2r,rotate=90\n' \
    > "$root/boot/firmware/config.txt"
  cc "$repo_root/tests/fixture-sudo.c" -o "$bin/sudo"
  chown root:root "$bin/sudo"
  chmod 4755 "$bin/sudo"

  install -m 0755 /dev/stdin "$bin/cp" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
source_path="${@: -2:1}"
destination="${@: -1}"
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
  printf '%s\n' "$HP2R_FIXTURE_RELEASE"
  exit
fi
if test "${1-}" = mktemp && test "${2-}" = -d; then
  path=/tmp/hp2r-tryboot-stage.fixture
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
  shift
  setpriv --reuid=65534 --regid=65534 --clear-groups \
    env HP2R_INSTALL_ROOT="$HP2R_FIXTURE_ROOT" PATH="$PATH" \
    bash -c 'id -u > "$HP2R_FIXTURE_ROOT/tmp/remote-uid"; exec bash "$@"' bash "$@"
  exit
fi
if test "${1-}" = bash && [[ "${2-}" == /tmp/hp2r-tryboot-stage.*/* ]]; then
  script="$HP2R_FIXTURE_ROOT$2"
  shift 2
  setpriv --reuid=65534 --regid=65534 --clear-groups \
    env HP2R_INSTALL_ROOT="$HP2R_FIXTURE_ROOT" PATH="$PATH" \
    bash -c 'id -u > "$HP2R_FIXTURE_ROOT/tmp/remote-uid"; exec bash "$@"' bash "$script" "$@"
  exit
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
case "$destination" in /tmp/hp2r-tryboot-stage.*/*) ;; *) exit 64 ;; esac
mkdir -p "$HP2R_FIXTURE_ROOT$destination"
cp -RP "${source%/.}/." "$HP2R_FIXTURE_ROOT$destination"
chown -R 65534:65534 "$HP2R_FIXTURE_ROOT$destination"
printf 'scp %s\n' "$destination" >> "$HP2R_FIXTURE_LOG"
SCRIPT

  install -m 0755 /dev/stdin "$bin/depmod" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
printf 'depmod %s\n' "$*" >> "$HP2R_FIXTURE_LOG"
SCRIPT

  install -m 0755 /dev/stdin "$bin/reboot" <<'SCRIPT'
#!/usr/bin/env bash
exit 64
SCRIPT

  install -m 0755 /dev/stdin "$bin/uname" <<'SCRIPT'
#!/usr/bin/env bash
case "${1-}" in -r) printf '%s\n' "$HP2R_FIXTURE_RELEASE";; -m) printf 'aarch64\n';; *) exit 64;; esac
SCRIPT

  install -m 0755 /dev/stdin "$bin/lsmod" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' 'Module Size Used by' 'hyperpixel2r_kms 1 0' 'i2c_algo_bit 1 1' 'edt_ft5x06 1 0' 'vc4 1 1'
SCRIPT

  install -m 0755 /dev/stdin "$bin/journalctl" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' 'fixture: SDL display ready: video_driver=KMSDRM render_driver=opengles2'
SCRIPT

  install -m 0755 /dev/stdin "$bin/dkms" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
version=''
for ((index = 1; index <= $#; index++)); do
  if test "${!index}" = -v; then
    next=$((index + 1))
    version="${!next}"
    break
  fi
done
test -n "$version"
marker="$HP2R_FIXTURE_ROOT/var/lib/dkms/registered"
if test "$version" != 0.1.0; then marker="$HP2R_FIXTURE_ROOT/var/lib/dkms/registered-$version"; fi
case "${1-}" in
  status)
    if test -n "${HP2R_FIXTURE_DKMS_STATUS+x}"; then printf '%s\n' "$HP2R_FIXTURE_DKMS_STATUS"; exit "${HP2R_FIXTURE_DKMS_EXIT:-0}"; fi
    test ! -f "$marker" || printf 'hyperpixel2r-kms/%s: added\n' "$version"
    ;;
  add) mkdir -p "$(dirname "$marker")"; : > "$marker" ;;
  remove)
    test -z "${HP2R_FIXTURE_FAIL_DKMS_REMOVE:-}" || exit 74
    rm -f -- "$marker"
    ;;
  *) exit 64 ;;
esac
printf 'dkms %s\n' "$*" >> "$HP2R_FIXTURE_LOG"
SCRIPT

  install -m 0755 /dev/stdin "$bin/mv" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
source_path="${@: -2:1}"
destination="${@: -1}"
if test -n "${HP2R_INSTALL_ROOT:-}"; then
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
    artifact:"$HP2R_FIXTURE_ROOT"/usr/lib/hyperpixel2r-kms/*|dkms-new:"$HP2R_FIXTURE_ROOT"/usr/src/hyperpixel2r-kms-0.1.0|normal:"$HP2R_FIXTURE_ROOT"/boot/firmware/config.txt|tryboot:"$HP2R_FIXTURE_ROOT"/boot/firmware/tryboot.txt|stage-state:"$HP2R_FIXTURE_ROOT"/var/lib/hyperpixel2r-kms/tryboot-state|state:"$HP2R_FIXTURE_ROOT"/var/lib/hyperpixel2r-kms/.tryboot-state-hold.*)
      marker="$HP2R_FIXTURE_ROOT/tmp/mv-failed-${HP2R_FIXTURE_FAIL_MV}"
      if test ! -e "$marker"; then
        : > "$marker"
        printf 'injected mv failure %s -> %s\n' "$source_path" "$destination" >> "$HP2R_FIXTURE_LOG"
        exit 75
      fi
      ;;
  esac
fi
exec /usr/bin/mv "$@"
SCRIPT

  install -m 0755 /dev/stdin "$bin/rm" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
if test -n "${HP2R_INSTALL_ROOT:-}" && test "${HP2R_FIXTURE_FAIL_RM:-}" = state-hold; then
  for argument in "$@"; do
    case "$argument" in "$HP2R_FIXTURE_ROOT"/var/lib/hyperpixel2r-kms/.tryboot-state-hold.*) exit 76;; esac
  done
fi
if test -n "${HP2R_INSTALL_ROOT:-}" && test "${HP2R_FIXTURE_FAIL_RM:-}" = workspace; then
  for argument in "$@"; do
    if /usr/bin/test "$(/usr/bin/dirname "$argument")" = "$HP2R_FIXTURE_ROOT/var/lib/hyperpixel2r-kms"; then
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
exec /usr/bin/rm "$@"
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
  local result

  if PATH="$bin:$PATH" \
    HP2R_FIXTURE_ROOT="$root" \
    HP2R_FIXTURE_RELEASE="$fixture_release" \
    HP2R_FIXTURE_LOG="$log" \
    HP2R_FIXTURE_REPO_ROOT="$repo_root" \
    HP2R_RELEASE_SOURCE_ROOT="${HP2R_RELEASE_SOURCE_ROOT:-}" \
    HP2R_TARGET=pi@fixture \
    "$repo_root/scripts/stage-tryboot.sh" \
      --artifact-dir "$repo_root/dist/artifacts/$release" \
      --replace-overlay vc4-kms-dpi-hyperpixel2r; then
    assert_no_private_workspaces
    return
  else
    result=$?
    assert_no_private_workspaces
    return "$result"
  fi
}

run_controller() {
  local script="$1"
  local fixture_bin="$bin"
  local result
  if test "${HP2R_FIXTURE_NO_DKMS:-}" = 1; then fixture_bin="$bin_no_dkms"; fi
  if PATH="$fixture_bin:$PATH" \
    HP2R_FIXTURE_ROOT="$root" \
    HP2R_FIXTURE_RELEASE="$release" \
    HP2R_FIXTURE_LOG="$log" \
    HP2R_FIXTURE_REPO_ROOT="$repo_root" \
    HP2R_TARGET=pi@fixture \
    "$repo_root/scripts/$script"; then
    assert_no_private_workspaces
    return
  else
    result=$?
    assert_no_private_workspaces
    return "$result"
  fi
}

install_live_hardware() {
  mkdir -p \
    "$root/sys/module/hyperpixel2r_kms" \
    "$root/sys/bus/platform/drivers/hyperpixel2r-kms" \
    "$root/sys/devices/platform/fixture-panel/of_node" \
    "$root/sys/class/drm/card0-DPI-1" \
    "$root/sys/class/input/event0/device"
  ln -s ../../../../devices/platform/fixture-panel \
    "$root/sys/bus/platform/drivers/hyperpixel2r-kms/fixture-panel"
  printf '%s\n' "${HP2R_FIXTURE_LIVE_DRIVER_VERSION:-0.1.0}" > "$root/sys/module/hyperpixel2r_kms/version"
  printf 'shayne,hyperpixel2r-kms\0' > "$root/sys/devices/platform/fixture-panel/of_node/compatible"
  printf 'connected\n' > "$root/sys/class/drm/card0-DPI-1/status"
  printf '480x480\n' > "$root/sys/class/drm/card0-DPI-1/modes"
  printf 'EDT FT5406\n' > "$root/sys/class/input/event0/device/name"
}

run_verify() {
  PATH="$bin:$PATH" \
    HP2R_FIXTURE_ROOT="$root" \
    HP2R_FIXTURE_RELEASE="$release" \
    HP2R_FIXTURE_LOG="$log" \
    HP2R_FIXTURE_REPO_ROOT="$repo_root" \
    HP2R_TARGET=pi@fixture \
    "$repo_root/scripts/verify-boot.sh" --expect-tryboot --json
}

assert_verify_rejects_binding() {
  local label="$1"

  if run_verify >/dev/null 2>&1; then
    fail "verify accepted $label"
  fi
}

prepare_prior_dkms() {
  local label="$1"
  local registration="${2:-registered}"
  local directory="$root/usr/src/hyperpixel2r-kms-0.1.0"
  local name

  mkdir -p "$directory" "$root/var/lib/dkms"
  for name in Kbuild Makefile dkms.conf hyperpixel2r_kms_main.c hyperpixel2r_kms_gpio.c hyperpixel2r_kms_gpio.h hyperpixel2r_kms_protocol.c hyperpixel2r_kms_protocol.h; do
    printf 'fixture prior %s: %s\n' "$label" "$name" > "$directory/$name"
  done
  chown -R root:root "$directory"
  chmod 0755 "$directory"
  chmod 0644 "$directory"/*
  case "$registration" in
    registered) : > "$root/var/lib/dkms/registered" ;;
    unregistered) ;;
    *) fail "unsupported prior DKMS registration fixture: $registration" ;;
  esac
}

assert_prior_dkms() {
  local expected_sums="$1"
  local registration="${2:-registered}"
  local directory="$root/usr/src/hyperpixel2r-kms-0.1.0"

  test "$(stat -c '%U:%G:%a' "$directory")" = root:root:755 || fail 'prior DKMS directory ownership or mode drifted'
  while IFS=' ' read -r expected name; do
    test "$(sha256sum "$directory/$name" | awk '{print $1}')" = "$expected" ||
      fail "prior DKMS bytes were not restored: $name"
    test "$(stat -c '%U:%G:%a' "$directory/$name")" = root:root:644 ||
      fail "prior DKMS file ownership or mode drifted: $name"
  done < "$expected_sums"
  case "$registration" in
    registered) assert_file "$root/var/lib/dkms/registered" ;;
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
  assert_absent "$root/usr/lib/hyperpixel2r-kms"
  assert_absent "$root/usr/src/hyperpixel2r-kms-0.1.0"
  assert_absent "$root/var/lib/dkms/registered"
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
  manifest="$root/usr/lib/hyperpixel2r-kms/0.1.0/$source_revision/$release/manifest.txt"
  replace_manifest_value "$manifest" "$key" "$value"
  if run_controller rollback-boot.sh >/dev/null 2>&1; then
    fail "rollback accepted manifest identity drift: $key"
  fi
  assert_file "$root/boot/firmware/tryboot.txt"
  assert_file "$root/var/lib/hyperpixel2r-kms/tryboot-state"
}

# RED contract: a declaration with parameters is still exactly one declaration
# of the requested overlay.  The candidate must replace it, not leave it in
# addition to the generic HyperPixel overlay.
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
test "$(awk 'END {print NR}' "$state")" = 16 || fail 'state schema cardinality changed'
grep -Fxq 'schema_version=1' "$state"
grep -Eq '^candidate_config_sha256=[0-9a-f]{64}$' "$state"
grep -Fxq 'prior_tryboot_sha256=none' "$state"
grep -Fq 'fixture committed source: hyperpixel2r_kms_main.c' \
  "$root/usr/src/hyperpixel2r-kms-0.1.0/hyperpixel2r_kms_main.c" ||
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
export HP2R_FIXTURE_FAIL_MV=state HP2R_FIXTURE_FAIL_RM=workspace
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
artifact_module_sha="$(sha256sum "$root/usr/lib/hyperpixel2r-kms/0.1.0/$source_revision/$release/hyperpixel2r_kms.ko" | awk '{ print $1 }')"
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
export HP2R_FIXTURE_DKMS_STATUS=$'hyperpixel2r-kms/0.1.0: added\nhyperpixel2r-kms/0.1.0: broken'
if run_stage >/dev/null 2>&1; then fail 'mixed DKMS status was accepted'; fi
unset HP2R_FIXTURE_DKMS_STATUS
assert_clean_failed_stage

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
test "$json" = '{"schema_version":1,"driver_version":"0.1.0","kernel_release":"6.18.34+rpt-rpi-v8","module":"hyperpixel2r_kms","drm_mode":"480x480","touch":true,"sdl_driver":"KMSDRM","renderer":"opengles2","accepted":true}' ||
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
export HP2R_FIXTURE_LIVE_DRIVER_VERSION=0.1.1
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
printf 'tamper\n' >> "$root/usr/lib/hyperpixel2r-kms/0.1.0/$source_revision/$release/manifest.txt"
if run_controller rollback-boot.sh >/dev/null 2>&1; then fail 'rollback accepted manifest drift'; fi
assert_file "$root/boot/firmware/tryboot.txt"

# Table-driven hostile state and manifest mutations cover each persisted
# identity.  Rollback must fail before it moves state or removes a leaf.
state_mutations=(
  'schema_version:2'
  'driver_version:0.1.1'
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
)
for mutation in "${state_mutations[@]}"; do
  assert_rollback_rejects_state_mutation "${mutation%%:*}" "${mutation#*:}"
done
manifest_mutations=(
  'schema_version:2'
  'driver_version:0.1.1'
  'source_tree:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
  'kernel_release:6.18.35+rpt-rpi-v8'
  'module_file:foreign.ko'
  'module_sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
  'overlay_sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
  'applied_dtb_file:foreign.dtb'
  'applied_dtb_sha256:ddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
)
for mutation in "${manifest_mutations[@]}"; do
  assert_rollback_rejects_manifest_mutation "${mutation%%:*}" "${mutation#*:}"
done

# source_revision and overlay_file are a single schema-bound pair.  Alter both
# while keeping the artifact manifest structurally valid, so the state binding
# rather than a malformed manifest must reject it.
new_target
run_stage >/dev/null
artifact="$root/usr/lib/hyperpixel2r-kms/0.1.0/$source_revision/$release"
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
assert_absent "$root/usr/src/hyperpixel2r-kms-0.1.0"
assert_file "$root/usr/lib/hyperpixel2r-kms/0.1.0/$source_revision/$release/manifest.txt"
if run_stage >/dev/null 2>&1; then fail 'inactive stored artifact was silently replaced'; fi
assert_file "$root/usr/lib/hyperpixel2r-kms/0.1.0/$source_revision/$release/manifest.txt"

# Uninstall must parse overlay declarations structurally: parameters do not
# make an owned generic overlay safe to ignore.
new_target
run_stage >/dev/null
run_controller rollback-boot.sh >/dev/null
printf 'dtoverlay=hyperpixel2r-kms-aaaaaaaaaaaa.dtbo,rotate=90\n' >> "$root/boot/firmware/config.txt"
if run_controller uninstall.sh >/dev/null 2>&1; then
  fail 'uninstall accepted a parameterized owned generic overlay declaration'
fi
assert_file "$root/usr/lib/hyperpixel2r-kms/0.1.0/$source_revision/$release/manifest.txt"

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
  scope == "rollback" && $0 == "  workspace=\"$(new_transaction_workspace)\" || die '\''failed to create private rollback workspace'\''" {
    rollback_allocations++
    getline
    if ($0 != "  trap cleanup_rollback EXIT") bad=1
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
new_target
prepare_prior_dkms successful-rollback
prior_dkms_sums="$fixture/prior-dkms-successful.sums"
(cd "$root/usr/src/hyperpixel2r-kms-0.1.0" && sha256sum * | sed 's#  # #') > "$prior_dkms_sums"
run_stage >/dev/null
first_artifact="$root/usr/lib/hyperpixel2r-kms/0.1.0/$source_revision/$release"
test "$(cat "$first_artifact/dkms-prior-state")" = registered || fail 'artifact did not record prior DKMS registration'
assert_file "$first_artifact/prior-dkms/hyperpixel2r_kms_main.c"
run_controller rollback-boot.sh >/dev/null
assert_prior_dkms "$prior_dkms_sums"
assert_absent "$root/boot/firmware/tryboot.txt"
assert_absent "$root/var/lib/hyperpixel2r-kms/tryboot-state"

# The same persistence restores an unregistered preexisting tree without
# inventing a DKMS registration during rollback.
new_target
prepare_prior_dkms successful-unregistered unregistered
prior_dkms_sums="$fixture/prior-dkms-unregistered.sums"
(cd "$root/usr/src/hyperpixel2r-kms-0.1.0" && sha256sum * | sed 's#  # #') > "$prior_dkms_sums"
run_stage >/dev/null
first_artifact="$root/usr/lib/hyperpixel2r-kms/0.1.0/$source_revision/$release"
test "$(cat "$first_artifact/dkms-prior-state")" = unregistered || fail 'artifact did not record unregistered prior DKMS state'
run_controller rollback-boot.sh >/dev/null
assert_prior_dkms "$prior_dkms_sums" unregistered

# If a later rollback step fails after source restoration, compensation must
# put the candidate source/status back before leaving its state replayable.
new_target
prepare_prior_dkms rollback-compensation
run_stage >/dev/null
candidate_dkms_sums="$fixture/candidate-dkms-compensation.sums"
(cd "$root/usr/src/hyperpixel2r-kms-0.1.0" && sha256sum * | sed 's#  # #') > "$candidate_dkms_sums"
export HP2R_FIXTURE_FAIL_MV=state
if run_controller rollback-boot.sh >/dev/null 2>&1; then fail 'rollback accepted injected state move failure'; fi
unset HP2R_FIXTURE_FAIL_MV
while IFS=' ' read -r expected name; do
  test "$(sha256sum "$root/usr/src/hyperpixel2r-kms-0.1.0/$name" | awk '{print $1}')" = "$expected" ||
    fail "rollback compensation did not restore candidate DKMS bytes: $name"
done < "$candidate_dkms_sums"
assert_file "$root/var/lib/dkms/registered"
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
(cd "$root/usr/src/hyperpixel2r-kms-0.1.0" && sha256sum * | sed 's#  # #') > "$candidate_dkms_sums"
export HP2R_FIXTURE_NO_DKMS=1 HP2R_FIXTURE_FAIL_MV=state
if run_controller rollback-boot.sh >/dev/null 2>&1; then
  fail 'rollback accepted injected state move failure without dkms'
fi
unset HP2R_FIXTURE_NO_DKMS HP2R_FIXTURE_FAIL_MV
while IFS=' ' read -r expected name; do
  test "$(sha256sum "$root/usr/src/hyperpixel2r-kms-0.1.0/$name" | awk '{print $1}')" = "$expected" ||
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
(cd "$root/usr/src/hyperpixel2r-kms-0.1.0" && sha256sum * | sed 's#  # #') > "$candidate_dkms_sums"
export HP2R_FIXTURE_FAIL_MV=dkms-new
if run_controller rollback-boot.sh >/dev/null 2>&1; then fail 'rollback accepted injected DKMS source publish failure'; fi
unset HP2R_FIXTURE_FAIL_MV
while IFS=' ' read -r expected name; do
  test "$(sha256sum "$root/usr/src/hyperpixel2r-kms-0.1.0/$name" | awk '{print $1}')" = "$expected" ||
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
  (cd "$root/usr/src/hyperpixel2r-kms-0.1.0" && sha256sum * | sed 's#  # #') > "$prior_dkms_sums"
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
printf 'foreign\n' > "$root/usr/src/hyperpixel2r-kms-0.1.0/foreign.c"
if run_stage >/dev/null 2>&1; then fail 'extra DKMS leaf was accepted'; fi
rm -f -- "$root/usr/src/hyperpixel2r-kms-0.1.0/foreign.c"
rm -f -- "$root/usr/src/hyperpixel2r-kms-0.1.0/Kbuild"
ln -s /etc/passwd "$root/usr/src/hyperpixel2r-kms-0.1.0/Kbuild"
if run_stage >/dev/null 2>&1; then fail 'symlinked DKMS leaf was accepted'; fi
rm -f -- "$root/usr/src/hyperpixel2r-kms-0.1.0/Kbuild"
printf 'fixture committed source: Kbuild\n' > "$root/usr/src/hyperpixel2r-kms-0.1.0/Kbuild"

# A new committed source revision may reuse the fixed DKMS package version.
# Its proven old tree is backed up, unregistered, replaced, and registered
# again; the fresh source bytes—not the stale tree—must be left active.
printf 'stale but regular source\n' > "$root/usr/src/hyperpixel2r-kms-0.1.0/hyperpixel2r_kms_main.c"
run_stage >/dev/null
grep -Fq 'fixture committed source: hyperpixel2r_kms_main.c' \
  "$root/usr/src/hyperpixel2r-kms-0.1.0/hyperpixel2r_kms_main.c" ||
  fail 'DKMS source replacement did not install committed bytes'
grep -Fq 'dkms remove -m hyperpixel2r-kms -v 0.1.0 --all' "$log" ||
  fail 'DKMS source replacement did not unregister the prior registration'
run_controller rollback-boot.sh >/dev/null

# Add a second release for the original version plus an independent candidate
# source tree for a second driver version.  Uninstall must validate all stored
# bundles before it mutates anything, preserve the recognized prior 0.1.0 tree,
# and remove only the candidate-owned 0.2.0 tree.
second_release='6.18.35+rpt-rpi-v8'
second_revision='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
first_artifact="$root/usr/lib/hyperpixel2r-kms/0.1.0/$source_revision/$release"
second_artifact="$root/usr/lib/hyperpixel2r-kms/0.1.0/$second_revision/$second_release"
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
third_version='0.2.0'
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
: > "$root/var/lib/dkms/registered-$third_version"

# A malformed third group must stop the all-or-nothing validation pass before
# it can remove either valid version's source tree or installed leaves.
malformed_version_dir="$root/usr/lib/hyperpixel2r-kms/0.3.0"
mkdir -p "$malformed_version_dir/not-a-revision"
if run_controller uninstall.sh >/dev/null 2>&1; then
  fail 'uninstall accepted a mixed malformed artifact state'
fi
assert_file "$root/usr/src/hyperpixel2r-kms-0.1.0/hyperpixel2r_kms_main.c"
assert_file "$root/usr/src/hyperpixel2r-kms-$third_version/hyperpixel2r_kms_main.c"
rmdir -- "$malformed_version_dir/not-a-revision" "$malformed_version_dir"

# Uninstall is idempotent after the rollback.  It removes only checksum-proven
# owned leaves across every recorded release and source tree.
if ! run_controller uninstall.sh >/dev/null 2>&1; then
  fail 'uninstall failed to reconcile the validated multi-version artifact set'
fi
assert_absent "$root/usr/lib/hyperpixel2r-kms"
assert_file "$root/usr/src/hyperpixel2r-kms-0.1.0/hyperpixel2r_kms_main.c"
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

printf 'Driver executable boot fixtures passed\n'
