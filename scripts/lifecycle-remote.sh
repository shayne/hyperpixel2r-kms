#!/usr/bin/env bash
set -euo pipefail

# Target-side half of the boot lifecycle.  This file is copied to a private
# /tmp directory for each controller invocation; it is never installed as a
# mutable target dependency.  Every destructive route starts by proving the
# state file, stored bundle, and candidate leaves it is about to touch.
umask 022

root="${HP2R_INSTALL_ROOT:-}"
state_dir="${root}/var/lib/hyperpixel2r-kms"
state_file="$state_dir/tryboot-state"
normal_config="${root}/boot/firmware/config.txt"
tryboot_config="${root}/boot/firmware/tryboot.txt"
artifact_root="${root}/usr/lib/hyperpixel2r-kms"
dkms_root="${root}/usr/src"
if test -n "$root"; then
  dkms_command=dkms
else
  dkms_command=/usr/sbin/dkms
fi

source_files=(
  Kbuild Makefile dkms.conf hyperpixel2r_kms_main.c hyperpixel2r_kms_gpio.c
  hyperpixel2r_kms_gpio.h hyperpixel2r_kms_protocol.c hyperpixel2r_kms_protocol.h
)
manifest_keys=(
  schema_version driver_version source_revision source_tree kernel_release architecture
  base_dtb_sha256 module_file module_sha256 module_vermagic overlay_file overlay_sha256
  applied_dtb_file applied_dtb_sha256
)
state_keys=(
  schema_version driver_version source_revision source_tree kernel_release module_file
  module_sha256 overlay_file overlay_sha256 applied_dtb_file applied_dtb_sha256
  normal_config_sha256 candidate_config_sha256 tryboot_existed prior_tryboot_sha256
  replaced_overlay
)

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

dkms_available() {
  if test -n "$root"; then
    command -v "$dkms_command" >/dev/null 2>&1
  else
    sudo test -x "$dkms_command"
  fi
}

run_dkms() {
  sudo "$dkms_command" "$@"
}

sha() {
  require_regular "$1" || return
  sudo sha256sum -- "$1" | awk '{print $1}'
}

require_regular() {
  sudo test ! -L "$1" && sudo test -f "$1" || {
    printf 'required regular non-symlink file is missing: %s\n' "$1" >&2
    return 1
  }
}

assert_owned_regular() {
  local path="$1"
  local expected_mode="$2"
  local actual_mode

  require_regular "$path" || return
  test "$(sudo stat -c '%U:%G' "$path")" = root:root || {
    printf 'ownership drift: %s\n' "$path" >&2
    return 1
  }
  actual_mode="$(sudo stat -c '%a' "$path")" || return
  if test "$expected_mode" = boot; then
    case "$actual_mode" in 644|755) ;; *) printf 'boot-file mode drift: %s\n' "$path" >&2; return 1;; esac
  else
    test "$actual_mode" = "$expected_mode" || {
      printf 'mode drift: %s\n' "$path" >&2
      return 1
    }
  fi
}

assert_owned_dir() {
  local path="$1"
  sudo test ! -L "$path" && sudo test -d "$path" || {
    printf 'unsafe owned directory: %s\n' "$path" >&2
    return 1
  }
  test "$(sudo stat -c '%U:%G' "$path")" = root:root || {
    printf 'ownership drift: %s\n' "$path" >&2
    return 1
  }
  test "$(sudo stat -c '%a' "$path")" = 755 || {
    printf 'directory mode drift: %s\n' "$path" >&2
    return 1
  }
}

assert_private_workspace() {
  local workspace="$1"

  assert_owned_dir "$(dirname "$state_dir")" || return
  assert_owned_dir "$state_dir" || return
  transaction_workspace_path "$workspace" || return
  sudo test ! -L "$workspace" && sudo test -d "$workspace" || {
    printf 'unsafe private transaction workspace: %s\n' "$workspace" >&2
    return 1
  }
  test "$(sudo stat -c '%U:%G' "$workspace")" = root:root || return
  test "$(sudo stat -c '%a' "$workspace")" = 700 || return
}

transaction_workspace_path() {
  local workspace="$1"
  local suffix

  case "$workspace" in "$state_dir"/.hp2r-transaction.*) ;; *) return 1 ;; esac
  suffix="${workspace#"$state_dir"/.hp2r-transaction.}"
  [[ "$suffix" =~ ^[A-Za-z0-9]+$ ]] || return
}

allocator_workspace_cleanup() {
  # This deliberately does not call remove_transaction_workspace: allocation
  # checks can fail before the directory has its final owner/mode proof.  The
  # exact path has already passed transaction_workspace_path, while its parent
  # and state directory remain root-owned before we remove anything.
  local workspace="$1"

  transaction_workspace_path "$workspace" || return
  assert_owned_dir "$(dirname "$state_dir")" || return
  assert_owned_dir "$state_dir" || return
  if sudo test -L "$workspace"; then return 1; fi
  if ! sudo test -e "$workspace"; then return 0; fi
  sudo test -d "$workspace" || return
  sudo rm -rf -- "$workspace" || return
  if sudo test -L "$workspace"; then return 1; fi
  sudo test ! -e "$workspace"
}

allocator_workspace_abort() {
  local workspace="$1"
  local reason="$2"

  printf 'private transaction workspace validation failed: %s\n' "$reason" >&2
  if ! allocator_workspace_cleanup "$workspace"; then
    printf 'private transaction workspace cleanup failed; inspect exact path manually: %s\n' "$workspace" >&2
  fi
}

new_transaction_workspace() {
  local workspace state_parent status

  state_parent="$(dirname "$state_dir")"
  assert_owned_dir "$state_parent" || return
  if sudo test -L "$state_dir"; then return 1; fi
  if ! sudo test -e "$state_dir"; then sudo install -d -m 0755 "$state_dir" || return; fi
  assert_owned_dir "$state_dir" || return
  workspace="$(sudo mktemp -d "$state_dir/.hp2r-transaction.XXXXXX")" || return
  if ! transaction_workspace_path "$workspace"; then
    printf 'unsafe transaction workspace path returned by mktemp; no automatic deletion attempted; inspect manually: %s\n' "$workspace" >&2
    return 1
  fi
  if sudo test ! -L "$workspace" && sudo test -d "$workspace"; then :; else
    status=$?
    allocator_workspace_abort "$workspace" 'L-first directory validation'
    return "$status"
  fi
  if test "$(sudo stat -c '%U:%G' "$workspace")" = root:root; then :; else
    status=$?
    allocator_workspace_abort "$workspace" 'owner validation'
    return "$status"
  fi
  if sudo chmod 0700 "$workspace"; then :; else
    status=$?
    allocator_workspace_abort "$workspace" 'mode setup'
    return "$status"
  fi
  if sudo chown root:root "$workspace"; then :; else
    status=$?
    allocator_workspace_abort "$workspace" 'owner setup'
    return "$status"
  fi
  if assert_private_workspace "$workspace"; then :; else
    status=$?
    allocator_workspace_abort "$workspace" 'final owner/mode validation'
    return "$status"
  fi
  printf '%s\n' "$workspace"
}

remove_transaction_workspace() {
  local workspace="$1"

  test -n "$workspace" || return 0
  transaction_workspace_path "$workspace" || return
  assert_owned_dir "$(dirname "$state_dir")" || return
  assert_owned_dir "$state_dir" || return
  if sudo test -L "$workspace"; then return 1; fi
  if ! sudo test -e "$workspace"; then return 0; fi
  assert_private_workspace "$workspace" || return
  sudo rm -rf -- "$workspace" || return
  if sudo test -L "$workspace"; then return 1; fi
  sudo test ! -e "$workspace"
}

private_file() {
  local workspace="$1"
  local name="$2"
  local path

  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || return
  assert_private_workspace "$workspace" || return
  path="$workspace/$name"
  sudo install -o root -g root -m 0600 /dev/null "$path" || return
  assert_private_workspace "$workspace" || return
  assert_owned_regular "$path" 600 || return
  printf '%s\n' "$path"
}

atomic_copy() {
  local source="$1"
  local destination="$2"
  local requested_mode="$3"
  local expected_sha="$4"
  local boot_file="${5:-false}"
  local directory temporary temporary_sha destination_existed=false

  [[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]] || return
  directory="$(dirname "$destination")"
  if sudo test -L "$directory"; then
    return
  elif sudo test -e "$directory"; then
    sudo test -d "$directory" || return
  else
    sudo install -d -m 0755 "$directory" || return
  fi
  if sudo test -L "$destination"; then
    return
  elif sudo test -e "$destination"; then
    require_regular "$destination" || {
      printf 'refusing non-regular destination: %s\n' "$destination" >&2
      return 1
    }
    destination_existed=true
  fi
  temporary="$(sudo mktemp "$directory/.$(basename "$destination").XXXXXX")" || return
  # The source may be a controller-owned incoming leaf.  Copy it before any
  # root hash or regular-file check, and never follow a symlink while doing so.
  sudo cp --no-dereference -- "$source" "$temporary" || {
    sudo rm -f -- "$temporary" || true
    return 1
  }
  require_regular "$temporary" || {
    sudo rm -f -- "$temporary" || true
    return 1
  }
  temporary_sha="$(sha "$temporary")" || {
    sudo rm -f -- "$temporary" || true
    return 1
  }
  test "$temporary_sha" = "$expected_sha" || {
    printf 'atomic copy checksum mismatch: %s\n' "$destination" >&2
    sudo rm -f -- "$temporary" || true
    return 1
  }
  sudo chmod "$requested_mode" "$temporary" || { sudo rm -f -- "$temporary" || true; return 1; }
  sudo chown root:root "$temporary" || { sudo rm -f -- "$temporary" || true; return 1; }
  if test "$boot_file" = true; then
    assert_owned_regular "$temporary" boot || { sudo rm -f -- "$temporary" || true; return 1; }
  else
    assert_owned_regular "$temporary" "$requested_mode" || { sudo rm -f -- "$temporary" || true; return 1; }
  fi
  sudo mv -f "$temporary" "$destination" || { sudo rm -f -- "$temporary" || true; return 1; }
  if test "$boot_file" = true; then
    assert_owned_regular "$destination" boot || {
      if ! "$destination_existed"; then sudo rm -f -- "$destination" || true; fi
      return 1
    }
  else
    assert_owned_regular "$destination" "$requested_mode" || {
      if ! "$destination_existed"; then sudo rm -f -- "$destination" || true; fi
      return 1
    }
  fi
  test "$(sha "$destination")" = "$expected_sha" || {
    printf 'atomic copy checksum mismatch: %s\n' "$destination" >&2
    if ! "$destination_existed"; then sudo rm -f -- "$destination" || true; fi
    return 1
  }
}

privileged_snapshot() {
  # Copy an arbitrary source into a root-owned private leaf without hashing or
  # otherwise trusting the source pathname.  Callers derive any authority from
  # the returned immutable leaf, never from the original source.
  local source="$1"
  local directory="$2"
  local label="$3"
  local temporary

  [[ "$label" =~ ^[A-Za-z0-9._-]+$ ]] || {
    printf 'unsafe privileged snapshot label: %s\n' "$label" >&2
    return 1
  }
  assert_private_workspace "$directory" || return
  temporary="$(sudo mktemp "$directory/.hp2r-${label}.XXXXXX")" || return
  assert_private_workspace "$directory" || { sudo rm -f -- "$temporary" || true; return 1; }
  sudo cp --no-dereference -- "$source" "$temporary" || {
    sudo rm -f -- "$temporary" || true
    return 1
  }
  require_regular "$temporary" || {
    sudo rm -f -- "$temporary" || true
    return 1
  }
  sudo chmod 600 "$temporary" || {
    sudo rm -f -- "$temporary" || true
    return 1
  }
  sudo chown root:root "$temporary" || {
    sudo rm -f -- "$temporary" || true
    return 1
  }
  assert_owned_regular "$temporary" 600 || {
    sudo rm -f -- "$temporary" || true
    return 1
  }
  printf '%s\n' "$temporary"
}

copy_if_absent_or_exact() {
  local source="$1"
  local destination="$2"
  local mode="$3"
  local expected_sha="$4"
  local boot_file="${5:-false}"

  copy_was_created=false
  [[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]] || return
  if sudo test -L "$destination"; then
    return
  elif sudo test -e "$destination"; then
    if test "$boot_file" = true; then
      assert_owned_regular "$destination" boot || return
    else
      assert_owned_regular "$destination" "$mode" || return
    fi
    test "$(sha "$destination")" = "$expected_sha" || {
      printf 'existing owned artifact differs: %s\n' "$destination" >&2
      return 1
    }
    return 0
  fi
  atomic_copy "$source" "$destination" "$mode" "$expected_sha" "$boot_file" || return
  copy_was_created=true
  return 0
}

manifest_value() {
  local manifest="$1"
  local key="$2"

  require_regular "$manifest" || return
  sudo awk -F '\t' -v wanted="$key" '$1 == wanted { print $2 }' "$manifest"
}

assert_exact_manifest() {
  local manifest="$1"
  local require_owner="${2:-true}"
  local key count

  if test "$require_owner" = true; then
    assert_owned_regular "$manifest" 644 || return
  else
    require_regular "$manifest" || return
  fi
  test "$(sudo awk 'END { print NR }' "$manifest")" = "${#manifest_keys[@]}" || {
    printf 'artifact manifest has the wrong cardinality\n' >&2
    return 1
  }
  sudo awk -F '\t' 'NF != 2 || $1 == "" || $2 == "" { exit 1 }' "$manifest" || {
    printf 'artifact manifest has malformed rows\n' >&2
    return 1
  }
  for key in "${manifest_keys[@]}"; do
    count="$(sudo awk -F '\t' -v wanted="$key" '$1 == wanted { count++ } END { print count + 0 }' "$manifest")"
    test "$count" = 1 || {
      printf 'artifact manifest key is missing or duplicated: %s\n' "$key" >&2
      return 1
    }
  done
  test "$(manifest_value "$manifest" schema_version)" = 1 || return
  [[ "$(manifest_value "$manifest" driver_version)" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return
  [[ "$(manifest_value "$manifest" source_revision)" =~ ^[0-9a-f]{40}$ ]] || return
  [[ "$(manifest_value "$manifest" source_tree)" =~ ^[0-9a-f]{40}$ ]] || return
  [[ "$(manifest_value "$manifest" kernel_release)" =~ ^[A-Za-z0-9._+-]+$ ]] || return
  test "$(manifest_value "$manifest" architecture)" = aarch64 || return
  for key in base_dtb_sha256 module_sha256 overlay_sha256 applied_dtb_sha256; do
    [[ "$(manifest_value "$manifest" "$key")" =~ ^[0-9a-f]{64}$ ]] || return
  done
  test "$(manifest_value "$manifest" module_file)" = hyperpixel2r_kms.ko || return
  test "$(manifest_value "$manifest" overlay_file)" = \
    "hyperpixel2r-kms-$(manifest_value "$manifest" source_revision | cut -c1-12).dtbo" || return
  test "$(manifest_value "$manifest" applied_dtb_file)" = hyperpixel2r-kms-applied.dtb || return
}

assert_source_tree_shape() {
  local directory="$1"
  local reference="${2:-}"
  local entry relative name
  local -A seen=()

  assert_owned_dir "$directory" || return
  while IFS= read -r -d '' entry; do
    relative="${entry#"$directory"/}"
    case "$relative" in
      "$entry"|*/*) printf 'unexpected nested DKMS path: %s\n' "$entry" >&2; return 1 ;;
    esac
    name="$relative"
    case " ${source_files[*]} " in *" $name "*) ;; *) printf 'unexpected DKMS path: %s\n' "$entry" >&2; return 1;; esac
    require_regular "$entry" || return
    assert_owned_regular "$entry" 644 || return
    seen["$name"]=1
  done < <(sudo find -P "$directory" -mindepth 1 -print0)
  for name in "${source_files[@]}"; do
    test "${seen[$name]-}" = 1 || {
      printf 'incomplete DKMS source tree: %s/%s\n' "$directory" "$name" >&2
      return 1
    }
    if test -n "$reference"; then
      require_regular "$reference/$name" || return
      cmp -s <(sudo cat "$directory/$name") <(sudo cat "$reference/$name") || {
        printf 'DKMS source differs from bound source: %s\n' "$name" >&2
        return 1
      }
    fi
  done
}

dkms_prior_state() {
  local artifact_dir="$1"
  local marker="$artifact_dir/dkms-prior-state"
  local value

  assert_owned_regular "$marker" 600 || return
  value="$(sudo cat "$marker")"
  case "$value" in absent|unregistered|registered) printf '%s\n' "$value";; *) return 1;; esac
}

assert_artifact_tree() {
  local artifact_dir="$1"
  local require_prior="$2"
  local manifest module_file overlay_file applied_dtb_file entry relative name prior_dkms_state_value
  local -A allowed=() seen=()

  assert_owned_dir "$artifact_dir" || return
  manifest="$artifact_dir/manifest.txt"
  assert_exact_manifest "$manifest" || return
  module_file="$(manifest_value "$manifest" module_file)"
  overlay_file="$(manifest_value "$manifest" overlay_file)"
  applied_dtb_file="$(manifest_value "$manifest" applied_dtb_file)"
  allowed[manifest.txt]=1
  allowed["$module_file"]=1
  allowed["$overlay_file"]=1
  allowed["$applied_dtb_file"]=1
  allowed[dkms-source]=1
  allowed[dkms-prior-state]=1
  allowed[prior-dkms]=1
  if test "$require_prior" = true; then allowed[prior-tryboot.txt]=1; fi
  while IFS= read -r -d '' entry; do
    relative="${entry#"$artifact_dir"/}"
    case "$relative" in "$entry"|*/*) printf 'unexpected nested artifact path: %s\n' "$entry" >&2; return 1;; esac
    name="$relative"
    test "${allowed[$name]-}" = 1 || {
      printf 'unexpected artifact path: %s\n' "$entry" >&2
      return 1
    }
    if test "$name" = dkms-source; then
      assert_source_tree_shape "$entry" || return
    elif test "$name" = prior-dkms; then
      assert_source_tree_shape "$entry" || return
    elif test "$name" = dkms-prior-state; then
      assert_owned_regular "$entry" 600 || return
    elif test "$name" = prior-tryboot.txt; then
      assert_owned_regular "$entry" 600 || return
    else
      assert_owned_regular "$entry" 644 || return
    fi
    seen["$name"]=1
  done < <(sudo find -P "$artifact_dir" -mindepth 1 -maxdepth 1 -print0)
  for name in manifest.txt "$module_file" "$overlay_file" "$applied_dtb_file" dkms-source dkms-prior-state; do
    test "${seen[$name]-}" = 1 || { printf 'missing artifact path: %s/%s\n' "$artifact_dir" "$name" >&2; return 1; }
  done
  if test "$require_prior" = true; then
    test "${seen[prior-tryboot.txt]-}" = 1 || { echo 'missing prior tryboot backup' >&2; return 1; }
  else
    test -z "${seen[prior-tryboot.txt]-}" || { echo 'unexpected prior tryboot backup' >&2; return 1; }
  fi
  prior_dkms_state_value="$(dkms_prior_state "$artifact_dir")" || {
    echo 'invalid prior DKMS state marker' >&2
    return 1
  }
  case "$prior_dkms_state_value:${seen[prior-dkms]-}" in
    absent:) ;;
    unregistered:1|registered:1) ;;
    *) echo 'prior DKMS backup does not match its state marker' >&2; return 1;;
  esac
  test "$(sha "$artifact_dir/$module_file")" = "$(manifest_value "$manifest" module_sha256)" || return
  test "$(sha "$artifact_dir/$overlay_file")" = "$(manifest_value "$manifest" overlay_sha256)" || return
  test "$(sha "$artifact_dir/$applied_dtb_file")" = "$(manifest_value "$manifest" applied_dtb_sha256)" || return
}

assert_state_schema() {
  local key count
  assert_owned_regular "$state_file" 600 || return
  test "$(sudo awk 'END { print NR }' "$state_file")" = "${#state_keys[@]}" || {
    echo 'tryboot state has the wrong cardinality' >&2
    return 1
  }
  sudo awk -F= 'NF != 2 || $1 == "" || $2 == "" { exit 1 }' "$state_file" || {
    echo 'tryboot state has malformed rows' >&2
    return 1
  }
  for key in "${state_keys[@]}"; do
    count="$(sudo awk -F= -v wanted="$key" '$1 == wanted { count++ } END { print count + 0 }' "$state_file")"
    test "$count" = 1 || {
      printf 'tryboot state key is missing or duplicated: %s\n' "$key" >&2
      return 1
    }
  done
  test "$(state_value schema_version)" = 1 || {
    echo 'unsupported tryboot state schema version' >&2
    return 1
  }
}

state_value() {
  local key="$1"

  assert_owned_regular "$state_file" 600 || return
  sudo awk -F= -v wanted="$key" '$1 == wanted { print $2 }' "$state_file"
}

assert_transaction_state() {
  local driver_version revision source_tree release module_file module_sha overlay_file overlay_sha applied_dtb_file applied_dtb_sha normal_sha candidate_sha prior_existed prior_sha replaced_overlay artifact_dir manifest overlay_name

  assert_state_schema || return
  driver_version="$(state_value driver_version)"
  revision="$(state_value source_revision)"
  source_tree="$(state_value source_tree)"
  release="$(state_value kernel_release)"
  module_file="$(state_value module_file)"
  module_sha="$(state_value module_sha256)"
  overlay_file="$(state_value overlay_file)"
  overlay_sha="$(state_value overlay_sha256)"
  applied_dtb_file="$(state_value applied_dtb_file)"
  applied_dtb_sha="$(state_value applied_dtb_sha256)"
  normal_sha="$(state_value normal_config_sha256)"
  candidate_sha="$(state_value candidate_config_sha256)"
  prior_existed="$(state_value tryboot_existed)"
  prior_sha="$(state_value prior_tryboot_sha256)"
  replaced_overlay="$(state_value replaced_overlay)"
  [[ "$driver_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'invalid transaction driver version' >&2; return 1; }
  [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || { echo 'invalid transaction source revision' >&2; return 1; }
  [[ "$source_tree" =~ ^[0-9a-f]{40}$ ]] || { echo 'invalid transaction source tree' >&2; return 1; }
  [[ "$release" =~ ^[A-Za-z0-9._+-]+$ ]] || { echo 'invalid transaction kernel release' >&2; return 1; }
  test "$module_file" = hyperpixel2r_kms.ko || { echo 'invalid transaction module file' >&2; return 1; }
  [[ "$overlay_file" =~ ^hyperpixel2r-kms-[0-9a-f]{12}\.dtbo$ ]] || { echo 'invalid transaction overlay file' >&2; return 1; }
  test "$applied_dtb_file" = hyperpixel2r-kms-applied.dtb || { echo 'invalid transaction applied dtb file' >&2; return 1; }
  for value in "$module_sha" "$overlay_sha" "$applied_dtb_sha" "$normal_sha" "$candidate_sha"; do
    [[ "$value" =~ ^[0-9a-f]{64}$ ]] || { echo 'invalid transaction checksum' >&2; return 1; }
  done
  case "$prior_existed" in
    true) [[ "$prior_sha" =~ ^[0-9a-f]{64}$ ]] || { echo 'invalid prior tryboot checksum' >&2; return 1; } ;;
    false) test "$prior_sha" = none || { echo 'invalid empty prior tryboot checksum sentinel' >&2; return 1; } ;;
    *) return 1 ;;
  esac
  case "$replaced_overlay" in none|*[!A-Za-z0-9._+-]*) test "$replaced_overlay" = none || { echo 'invalid replaced overlay identity' >&2; return 1; };; esac
  require_regular "$normal_config" || return
  require_regular "$tryboot_config" || return
  test "$(sha "$normal_config")" = "$normal_sha" || { echo 'normal boot config changed since stage' >&2; return 1; }
  test "$(sha "$tryboot_config")" = "$candidate_sha" || { echo 'candidate tryboot config changed since stage' >&2; return 1; }
  artifact_dir="$artifact_root/$driver_version/$revision/$release"
  assert_artifact_tree "$artifact_dir" "$prior_existed" || return
  manifest="$artifact_dir/manifest.txt"
  test "$(manifest_value "$manifest" schema_version)" = 1 || { echo 'artifact and transaction schema versions differ' >&2; return 1; }
  test "$(manifest_value "$manifest" driver_version)" = "$driver_version" || { echo 'artifact and transaction driver versions differ' >&2; return 1; }
  test "$(manifest_value "$manifest" source_revision)" = "$revision" || { echo 'artifact and transaction source revisions differ' >&2; return 1; }
  test "$(manifest_value "$manifest" source_tree)" = "$source_tree" || { echo 'artifact and transaction source trees differ' >&2; return 1; }
  test "$(manifest_value "$manifest" kernel_release)" = "$release" || { echo 'artifact and transaction kernel releases differ' >&2; return 1; }
  test "$(manifest_value "$manifest" module_file)" = "$module_file" || { echo 'artifact and transaction module files differ' >&2; return 1; }
  test "$(manifest_value "$manifest" module_sha256)" = "$module_sha" || { echo 'artifact and transaction module checksums differ' >&2; return 1; }
  test "$(manifest_value "$manifest" overlay_file)" = "$overlay_file" || { echo 'artifact and transaction overlay files differ' >&2; return 1; }
  test "$(manifest_value "$manifest" overlay_sha256)" = "$overlay_sha" || { echo 'artifact and transaction overlay checksums differ' >&2; return 1; }
  test "$(manifest_value "$manifest" applied_dtb_file)" = "$applied_dtb_file" || { echo 'artifact and transaction applied dtb files differ' >&2; return 1; }
  test "$(manifest_value "$manifest" applied_dtb_sha256)" = "$applied_dtb_sha" || { echo 'artifact and transaction applied dtb checksums differ' >&2; return 1; }
  if test "$prior_existed" = true; then
    test "$(sha "$artifact_dir/prior-tryboot.txt")" = "$prior_sha" || { echo 'stored prior tryboot checksum differs' >&2; return 1; }
  fi
  assert_owned_regular "${root}/lib/modules/$release/extra/$module_file" 644 || return
  assert_owned_regular "${root}/boot/firmware/overlays/$overlay_file" boot || return
  test "$(sha "${root}/lib/modules/$release/extra/$module_file")" = "$module_sha" || { echo 'installed module checksum differs from transaction' >&2; return 1; }
  test "$(sha "${root}/boot/firmware/overlays/$overlay_file")" = "$overlay_sha" || { echo 'installed overlay checksum differs from transaction' >&2; return 1; }
  overlay_name="${overlay_file%.dtbo}"
  test "$(sudo awk -v wanted="dtoverlay=$overlay_file" '
    { line=$0; sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line); if (line == wanted) count++ }
    END { print count + 0 }
  ' "$tryboot_config")" = 1 || { echo 'candidate does not contain its exact generic overlay declaration' >&2; return 1; }
  printf '%s\t%s\t%s\t%s\n' "$driver_version" "$revision" "$release" "$artifact_dir"
}

validate_overlay_declarations() {
  local config="$1"
  local replacement="$2"
  local output="$3"
  local workspace="$4"

  require_regular "$config" || return
  assert_private_workspace "$workspace" || return
  case "$output" in "$workspace"/*) ;; *) return 1 ;; esac
  assert_owned_regular "$output" 600 || return

  sudo awk -v wanted="$replacement" '
    {
      line=$0
      trim=line
      sub(/^[[:space:]]+/, "", trim)
      sub(/[[:space:]]+$/, "", trim)
      if (trim ~ /^dtoverlay=/) {
        raw=substr(trim, 11)
        if (raw !~ /^[A-Za-z0-9._+-]+(,[A-Za-z0-9._+=:-]+)*$/) bad=1
        split(raw, pieces, ",")
        name=pieces[1]
        if (wanted != "" && name == wanted) { selected++; next }
        if (name ~ /hyperpixel2r/) foreign++
      }
      print line
    }
    END {
        if (bad || (wanted != "" && selected != 1) || foreign != 0) exit 1
    }
  ' "$config" | sudo tee "$output" >/dev/null || {
    echo 'unsafe, absent, multiple, or conflicting display overlay declaration' >&2
    return 1
  }
  assert_private_workspace "$workspace" || return
  assert_owned_regular "$output" 600 || return
}

assert_no_owned_generic_overlay() {
  local config="$1"

  require_regular "$config" || return

  sudo awk '
    {
      line=$0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line !~ /^dtoverlay=/) next
      raw=substr(line, 11)
      split(raw, pieces, ",")
      if (pieces[1] ~ /^hyperpixel2r-kms-[0-9a-f]{12}\.dtbo$/) exit 1
    }
  ' "$config" || {
    echo 'refusing uninstall while an owned generic overlay is configured' >&2
    return 1
  }
}

validate_dkms_status() {
  local version="$1"
  local output status line count=0
  if ! dkms_available; then
    printf 'absent\n'
    return
  fi
  set +e
  output="$(run_dkms status -m hyperpixel2r-kms -v "$version" 2>/dev/null)"
  status=$?
  set -e
  if test "$status" -ne 0; then
    test -z "$output" || { echo 'DKMS status failed with output' >&2; return 1; }
    printf 'unregistered\n'
    return
  fi
  if test -z "$output"; then printf 'unregistered\n'; return; fi
  while IFS= read -r line; do
    test -n "$line" || continue
    [[ "$line" =~ ^hyperpixel2r-kms/$version(:\ added|,\ [A-Za-z0-9._+-]+,\ (aarch64|arm64):\ (built|installed))$ ]] || {
      printf 'unrecognized DKMS status line: %s\n' "$line" >&2
      return 1
    }
    count=$((count + 1))
  done <<<"$output"
  test "$count" -gt 0 || { echo 'empty DKMS status is malformed' >&2; return 1; }
  printf 'registered\n'
}

remove_exact_tree() {
  local directory="$1"
  local name
  assert_source_tree_shape "$directory" || return
  for name in "${source_files[@]}"; do sudo rm -f -- "$directory/$name" || return; done
  sudo rmdir -- "$directory" || return
}

materialize_source_tree() {
  # Publish a complete, checksum-bound DKMS source tree only after its private
  # root-owned staging directory has been proven structurally exact.
  local source="$1"
  local destination="$2"
  local parent base staging name expected_sha

  assert_source_tree_shape "$source" || return
  test ! -L "$destination" && test ! -e "$destination" || {
    printf 'refusing to overwrite DKMS source tree: %s\n' "$destination" >&2
    return 1
  }
  parent="$(dirname "$destination")"
  base="$(basename "$destination")"
  sudo test ! -L "$parent" && sudo test -d "$parent" || return
  staging="$(sudo mktemp -d "$parent/.${base}.restore.XXXXXX")" || return
  sudo chmod 0755 "$staging" || { sudo rm -rf -- "$staging" || true; return 1; }
  for name in "${source_files[@]}"; do
    expected_sha="$(sha "$source/$name")" || { sudo rm -rf -- "$staging" || true; return 1; }
    atomic_copy "$source/$name" "$staging/$name" 644 "$expected_sha" || { sudo rm -rf -- "$staging" || true; return 1; }
  done
  assert_source_tree_shape "$staging" "$source" || { sudo rm -rf -- "$staging"; return 1; }
  sudo mv -f "$staging" "$destination" || { sudo rm -rf -- "$staging" || true; return 1; }
}

restore_dkms_source_state() {
  # The source backup and desired registration state were captured before the
  # candidate was published.  Refuse to remove a tree unless the caller has
  # already proven it is lifecycle-owned.
  local desired_state="$1"
  local source_backup="$2"
  local destination="$3"
  local desired_tree_present="$4"
  local current_state

  case "$desired_state" in absent|unregistered|registered) ;; *) return 1;; esac
  case "$desired_tree_present" in true|false) ;; *) return 1;; esac
  if sudo test -L "$destination"; then
    return 1
  elif sudo test -e "$destination"; then
    # The source-tree rollback authority is independent of whether the dkms
    # executable is presently available.  Do not let an absent dkms command
    # short-circuit restoration of the captured candidate bytes.
    if dkms_available; then
      current_state="$(validate_dkms_status "$driver_version")" || return
    else
      current_state=absent
    fi
    case "$current_state" in
      registered) run_dkms remove -m hyperpixel2r-kms -v "$driver_version" --all || return ;;
      absent|unregistered) ;;
      *) return 1 ;;
    esac
    remove_exact_tree "$destination" || return
  fi
  if "$desired_tree_present"; then
    assert_source_tree_shape "$source_backup" || return
    materialize_source_tree "$source_backup" "$destination" || return
    if test "$desired_state" = registered && dkms_available; then
      run_dkms add -m hyperpixel2r-kms -v "$driver_version" || return
    fi
  fi
}

remove_artifact_tree() {
  local artifact_dir="$1"
  local prior="$2"
  local manifest module_file overlay_file applied_dtb_file prior_dkms_state_value
  assert_artifact_tree "$artifact_dir" "$prior" || return
  manifest="$artifact_dir/manifest.txt"
  module_file="$(manifest_value "$manifest" module_file)"
  overlay_file="$(manifest_value "$manifest" overlay_file)"
  applied_dtb_file="$(manifest_value "$manifest" applied_dtb_file)"
  prior_dkms_state_value="$(dkms_prior_state "$artifact_dir")" || return
  remove_exact_tree "$artifact_dir/dkms-source" || return
  if test "$prior_dkms_state_value" != absent; then remove_exact_tree "$artifact_dir/prior-dkms" || return; fi
  for name in manifest.txt "$module_file" "$overlay_file" "$applied_dtb_file"; do sudo rm -f -- "$artifact_dir/$name" || return; done
  sudo rm -f -- "$artifact_dir/dkms-prior-state" || return
  if test "$prior" = true; then sudo rm -f -- "$artifact_dir/prior-tryboot.txt" || return; fi
  sudo rmdir -- "$artifact_dir" || return
  sudo rmdir -- "$(dirname "$artifact_dir")" 2>/dev/null || true
  sudo rmdir -- "$(dirname "$(dirname "$artifact_dir")")" 2>/dev/null || true
  sudo rmdir -- "$artifact_root" 2>/dev/null || true
}

stage() {
  # These transaction fields deliberately remain global until the process EXIT
  # trap runs: Bash unwinds function locals before an EXIT trap on `set -e`.
  incoming_logical="$1"
  driver_version="$2"
  revision="$3"
  source_tree="$4"
  release="$5"
  module_file="$6"
  overlay_file="$7"
  applied_dtb_file="$8"
  replacement="$9"
  incoming="${root}${incoming_logical}"
  artifact_dir="$artifact_root/$driver_version/$revision/$release"
  module_path="${root}/lib/modules/$release/extra/$module_file"
  overlay_path="${root}/boot/firmware/overlays/$overlay_file"
  dkms_dir="$dkms_root/hyperpixel2r-kms-$driver_version"
  rollback_tmp=''
  incoming_manifest=''
  manifest_sha=''
  module_sha=''
  overlay_sha=''
  applied_dtb_sha=''
  normal_snapshot=''
  candidate=''
  candidate_snapshot=''
  prior_tryboot=''
  prior_state_snapshot=''
  state_tmp=''
  state_snapshot=''
  artifact_stage_dir=''
  normal_sha=''
  candidate_sha=''
  prior_sha=none
  prior_existed=false
  created_artifact=false
  created_module=false
  created_overlay=false
  created_dkms=false
  dkms_replaced=false
  prior_dkms_state=absent
  prior_dkms_snapshot=''
  dkms_added=false
  published_tryboot=false
  published_state=false
  copy_was_created=false
  stage_complete=false

  stage_cleanup() {
    local status=$?
    if test "$status" -ne 0 && ! "$stage_complete"; then
      if "$published_state"; then sudo rm -f -- "$state_file" || true; fi
      if "$published_tryboot"; then
        if "$prior_existed"; then atomic_copy "$prior_tryboot" "$tryboot_config" 600 "$prior_sha" true || true
        else sudo rm -f -- "$tryboot_config" || true
        fi
      fi
      if "$dkms_added" && dkms_available; then run_dkms remove -m hyperpixel2r-kms -v "$driver_version" --all || true; fi
      if "$created_dkms" || "$dkms_replaced"; then
        if sudo test -L "$dkms_dir"; then :
        elif sudo test -e "$dkms_dir"; then remove_exact_tree "$dkms_dir" || true
        fi
        case "$prior_dkms_state" in
          absent) ;;
          unregistered|registered)
            materialize_source_tree "$prior_dkms_snapshot" "$dkms_dir" || true
            if test "$prior_dkms_state" = registered && dkms_available; then
              run_dkms add -m hyperpixel2r-kms -v "$driver_version" || true
            fi
            ;;
        esac
      fi
      if "$created_overlay"; then sudo rm -f -- "$overlay_path" || true; fi
      if "$created_module"; then sudo rm -f -- "$module_path" || true; fi
      if "$created_artifact"; then remove_artifact_tree "$artifact_dir" "$prior_existed" || true; fi
      if test -n "$artifact_stage_dir"; then
        sudo rm -rf -- "$artifact_stage_dir" || true
        sudo rmdir -- "$(dirname "$artifact_stage_dir")" 2>/dev/null || true
        sudo rmdir -- "$(dirname "$(dirname "$artifact_stage_dir")")" 2>/dev/null || true
        sudo rmdir -- "$artifact_root" 2>/dev/null || true
      fi
    fi
    if ! remove_transaction_workspace "$rollback_tmp" 2>/dev/null; then
      remove_transaction_workspace "$rollback_tmp" 2>/dev/null || exit "$status"
    fi
    rollback_tmp=''
    trap - EXIT
    if "$stage_complete"; then exit 0; fi
    exit "$status"
  }

  [[ "$driver_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'unsafe incoming driver version'
  [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || die 'unsafe incoming source revision'
  [[ "$source_tree" =~ ^[0-9a-f]{40}$ ]] || die 'unsafe incoming source tree'
  [[ "$release" =~ ^[A-Za-z0-9._+-]+$ ]] || die 'unsafe incoming kernel release'
  test "$module_file" = hyperpixel2r_kms.ko || die 'unsafe incoming module file'
  [[ "$overlay_file" = "hyperpixel2r-kms-${revision:0:12}.dtbo" ]] || die 'unsafe incoming overlay file'
  test "$applied_dtb_file" = hyperpixel2r-kms-applied.dtb || die 'unsafe incoming applied dtb file'
  test ! -L "$state_file" && test ! -e "$state_file" || die 'refusing active tryboot transaction'
  rollback_tmp="$(new_transaction_workspace)" || die 'failed to create private stage workspace'
  trap stage_cleanup EXIT
  candidate="$(private_file "$rollback_tmp" candidate)" || die 'failed to create private candidate config'
  incoming_manifest="$(privileged_snapshot "$incoming/manifest.txt" "$rollback_tmp" incoming-manifest)" || die 'failed to capture incoming manifest'
  assert_exact_manifest "$incoming_manifest" false || die 'incoming artifact manifest is invalid'
  manifest_sha="$(sha "$incoming_manifest")" || die 'failed to hash incoming manifest snapshot'
  test "$(manifest_value "$incoming_manifest" driver_version)" = "$driver_version" || die 'incoming manifest driver version differs'
  test "$(manifest_value "$incoming_manifest" source_revision)" = "$revision" || die 'incoming manifest source revision differs'
  test "$(manifest_value "$incoming_manifest" source_tree)" = "$source_tree" || die 'incoming manifest source tree differs'
  test "$(manifest_value "$incoming_manifest" kernel_release)" = "$release" || die 'incoming manifest kernel release differs'
  test "$(manifest_value "$incoming_manifest" module_file)" = "$module_file" || die 'incoming manifest module file differs'
  test "$(manifest_value "$incoming_manifest" overlay_file)" = "$overlay_file" || die 'incoming manifest overlay file differs'
  test "$(manifest_value "$incoming_manifest" applied_dtb_file)" = "$applied_dtb_file" || die 'incoming manifest applied dtb file differs'
  module_sha="$(manifest_value "$incoming_manifest" module_sha256)"
  overlay_sha="$(manifest_value "$incoming_manifest" overlay_sha256)"
  applied_dtb_sha="$(manifest_value "$incoming_manifest" applied_dtb_sha256)"
  for expected_sha in "$module_sha" "$overlay_sha" "$applied_dtb_sha"; do
    [[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]] || die 'incoming manifest checksum is invalid'
  done
  normal_snapshot="$(privileged_snapshot "$normal_config" "$rollback_tmp" normal)" || die 'failed to capture normal boot config'
  normal_sha="$(sha "$normal_snapshot")" || die 'failed to hash normal boot config snapshot'
  sudo awk '{ line=$0; sub(/\r$/, "", line); if (length(line) > 98) exit 1 }' "$normal_snapshot" || die 'normal boot config has a firmware-line-length violation'
  validate_overlay_declarations "$normal_snapshot" "$replacement" "$candidate" "$rollback_tmp" || die 'unsafe, absent, multiple, or conflicting display overlay declaration'
  assert_private_workspace "$rollback_tmp" || die 'private stage workspace changed while creating candidate'
  printf '\n# hyperpixel2r-kms one-shot candidate\ndtoverlay=%s\n' "$overlay_file" | sudo tee -a "$candidate" >/dev/null || die 'failed to append candidate boot config'
  assert_owned_regular "$candidate" 600 || die 'candidate boot config ownership drifted'
  LC_ALL=C sudo awk '{ line=$0; sub(/\r$/, "", line); if (length(line) > 98) exit 1 }' "$candidate" || die 'candidate boot config has a firmware-line-length violation'
  if sudo test -L "$tryboot_config"; then
    die 'unsafe preexisting tryboot config'
  elif sudo test -e "$tryboot_config"; then
    require_regular "$tryboot_config" || die 'unsafe preexisting tryboot config'
    test "$(sudo stat -c '%U:%G' "$tryboot_config")" = root:root || die 'unsafe preexisting tryboot config'
    case "$(sudo stat -c '%a' "$tryboot_config")" in 600|644|755) ;; *) die 'unsafe preexisting tryboot config';; esac
    prior_tryboot="$(privileged_snapshot "$tryboot_config" "$rollback_tmp" prior-tryboot)" || die 'failed to capture prior tryboot config'
    prior_sha="$(sha "$prior_tryboot")" || die 'failed to hash prior tryboot config snapshot'
    prior_existed=true
  fi
  test "$(sha "$normal_config")" = "$normal_sha" || die 'normal boot config changed while staging tryboot candidate'

  if sudo test -L "$dkms_dir"; then
    die 'partial or unbound DKMS source tree'
  elif sudo test -e "$dkms_dir"; then
    assert_source_tree_shape "$dkms_dir" || die 'partial or unbound DKMS source tree'
    prior_dkms_state="$(validate_dkms_status "$driver_version")" || die 'invalid DKMS status before source capture'
    case "$prior_dkms_state" in unregistered|registered) ;; *) die 'invalid DKMS source state before source capture';; esac
    prior_dkms_snapshot="$rollback_tmp/prior-dkms"
    sudo install -d -m 0755 "$prior_dkms_snapshot" || die 'failed to create prior DKMS snapshot directory'
    assert_private_workspace "$rollback_tmp" || die 'private stage workspace changed while capturing DKMS source'
    for name in "${source_files[@]}"; do
      expected_sha="$(sha "$dkms_dir/$name")" || die 'failed to hash prior DKMS source leaf'
      atomic_copy "$dkms_dir/$name" "$prior_dkms_snapshot/$name" 644 "$expected_sha" || die 'failed to capture prior DKMS source leaf'
    done
    assert_source_tree_shape "$prior_dkms_snapshot" "$dkms_dir" || die 'failed to capture prior DKMS source tree'
  fi
  prior_state_snapshot="$(private_file "$rollback_tmp" dkms-prior-state)" || die 'failed to create private DKMS state snapshot'
  printf '%s\n' "$prior_dkms_state" | sudo tee "$prior_state_snapshot" >/dev/null || die 'failed to write prior DKMS state snapshot'
  assert_owned_regular "$prior_state_snapshot" 600 || die 'prior DKMS state snapshot ownership drifted'

  if sudo test -L "$artifact_dir"; then
    die 'stored inactive artifact is unsafe'
  elif sudo test -e "$artifact_dir"; then
    assert_artifact_tree "$artifact_dir" "$prior_existed" || die 'existing artifact tree is unsafe'
    die 'stored inactive artifact exists; uninstall it before staging another candidate'
  fi
  sudo install -d -m 0755 "$(dirname "$artifact_dir")" || die 'failed to create artifact parent directory'
  artifact_stage_dir="$(sudo mktemp -d "$(dirname "$artifact_dir")/.${release}.stage.XXXXXX")" || die 'failed to create artifact staging directory'
  sudo chmod 0755 "$artifact_stage_dir" || die 'failed to set artifact staging directory mode'
  sudo install -d -m 0755 "$artifact_stage_dir/dkms-source" || die 'failed to create artifact DKMS staging directory'
  atomic_copy "$incoming_manifest" "$artifact_stage_dir/manifest.txt" 644 "$manifest_sha" || die 'failed to copy incoming manifest snapshot'
  atomic_copy "$incoming/$module_file" "$artifact_stage_dir/$module_file" 644 "$module_sha" || die 'failed to copy incoming module leaf'
  atomic_copy "$incoming/$overlay_file" "$artifact_stage_dir/$overlay_file" 644 "$overlay_sha" || die 'failed to copy incoming overlay leaf'
  atomic_copy "$incoming/$applied_dtb_file" "$artifact_stage_dir/$applied_dtb_file" 644 "$applied_dtb_sha" || die 'failed to copy incoming applied DTB leaf'
  for name in "${source_files[@]}"; do
    incoming_source_snapshot="$(privileged_snapshot "$incoming/dkms-source/$name" "$rollback_tmp" "incoming-$name")" || die 'failed to capture incoming DKMS source leaf'
    expected_sha="$(sha "$incoming_source_snapshot")" || die 'failed to hash incoming DKMS source snapshot'
    atomic_copy "$incoming_source_snapshot" "$artifact_stage_dir/dkms-source/$name" 644 "$expected_sha" || die 'failed to copy incoming DKMS source leaf'
    sudo rm -f -- "$incoming_source_snapshot" || die 'failed to remove incoming DKMS source snapshot'
  done
  expected_sha="$(sha "$prior_state_snapshot")" || die 'failed to hash prior DKMS state snapshot'
  atomic_copy "$prior_state_snapshot" "$artifact_stage_dir/dkms-prior-state" 600 "$expected_sha" || die 'failed to copy prior DKMS state'
  if test "$prior_dkms_state" != absent; then
    sudo install -d -m 0755 "$artifact_stage_dir/prior-dkms" || die 'failed to create prior DKMS artifact directory'
    for name in "${source_files[@]}"; do
      expected_sha="$(sha "$prior_dkms_snapshot/$name")" || die 'failed to hash prior DKMS source leaf'
      atomic_copy "$prior_dkms_snapshot/$name" "$artifact_stage_dir/prior-dkms/$name" 644 "$expected_sha" || die 'failed to copy prior DKMS source leaf'
    done
  fi
  if "$prior_existed"; then atomic_copy "$prior_tryboot" "$artifact_stage_dir/prior-tryboot.txt" 600 "$prior_sha" || die 'failed to copy prior tryboot config'; fi
  assert_artifact_tree "$artifact_stage_dir" "$prior_existed" || die 'staged artifact tree is unsafe'
  sudo mv -f "$artifact_stage_dir" "$artifact_dir" || die 'failed to publish artifact tree'
  artifact_stage_dir=''
  created_artifact=true
  if copy_if_absent_or_exact "$artifact_dir/$module_file" "$module_path" 644 "$module_sha"; then
    if "$copy_was_created"; then created_module=true; fi
  else
    die 'failed to install module from incoming artifact'
  fi
  if copy_if_absent_or_exact "$artifact_dir/$overlay_file" "$overlay_path" 644 "$overlay_sha" true; then
    if "$copy_was_created"; then created_overlay=true; fi
  else
    die 'failed to install overlay from incoming artifact'
  fi
  if sudo test -L "$dkms_dir"; then
    die 'existing DKMS source tree is unsafe'
  elif sudo test -e "$dkms_dir"; then
    if assert_source_tree_shape "$dkms_dir" "$artifact_dir/dkms-source" 2>/dev/null; then
      : # Exact source revision already registered or ready for registration.
    else
      test "$prior_dkms_state" != absent || die 'missing prior DKMS capture'
      assert_source_tree_shape "$dkms_dir" "$prior_dkms_snapshot" || die 'DKMS source changed after capture'
      if test "$prior_dkms_state" = registered; then run_dkms remove -m hyperpixel2r-kms -v "$driver_version" --all || die 'failed to remove prior DKMS registration'; fi
      dkms_replaced=true
      remove_exact_tree "$dkms_dir" || die 'failed to remove replaced DKMS source tree'
      materialize_source_tree "$artifact_dir/dkms-source" "$dkms_dir" || die 'failed to materialize replacement DKMS source tree'
    fi
  else
    sudo install -d -m 0755 "$dkms_dir" || die 'failed to create DKMS source directory'
    for name in "${source_files[@]}"; do
      expected_sha="$(sha "$artifact_dir/dkms-source/$name")" || die 'failed to hash artifact DKMS source leaf'
      atomic_copy "$artifact_dir/dkms-source/$name" "$dkms_dir/$name" 644 "$expected_sha" || die 'failed to materialize DKMS source leaf'
    done
    created_dkms=true
  fi
  dkms_status="$(validate_dkms_status "$driver_version")" || die 'failed to validate DKMS status after staging'
  case "$dkms_status" in
    absent|registered) ;;
    unregistered) run_dkms add -m hyperpixel2r-kms -v "$driver_version" || die 'failed to register DKMS source'; dkms_added=true ;;
    *) die 'invalid DKMS status result' ;;
  esac
  test "$(sha "$normal_config")" = "$normal_sha" || die 'normal boot config changed while staging tryboot candidate'
  candidate_snapshot="$(privileged_snapshot "$candidate" "$rollback_tmp" candidate)" || die 'failed to capture candidate config'
  candidate_sha="$(sha "$candidate_snapshot")" || die 'failed to hash candidate config snapshot'
  atomic_copy "$candidate_snapshot" "$tryboot_config" 644 "$candidate_sha" true || die 'failed to publish tryboot config'
  published_tryboot=true
  test "$(sha "$normal_config")" = "$normal_sha" || die 'normal boot config changed while staging tryboot candidate'
  state_tmp="$(private_file "$rollback_tmp" state)" || die 'failed to create private tryboot state'
  {
    printf 'schema_version=1\n'
    printf 'driver_version=%s\n' "$driver_version"
    printf 'source_revision=%s\n' "$revision"
    printf 'source_tree=%s\n' "$source_tree"
    printf 'kernel_release=%s\n' "$release"
    printf 'module_file=%s\n' "$module_file"
    printf 'module_sha256=%s\n' "$module_sha"
    printf 'overlay_file=%s\n' "$overlay_file"
    printf 'overlay_sha256=%s\n' "$overlay_sha"
    printf 'applied_dtb_file=%s\n' "$applied_dtb_file"
    printf 'applied_dtb_sha256=%s\n' "$applied_dtb_sha"
    printf 'normal_config_sha256=%s\n' "$normal_sha"
    printf 'candidate_config_sha256=%s\n' "$candidate_sha"
    printf 'tryboot_existed=%s\n' "$prior_existed"
    printf 'prior_tryboot_sha256=%s\n' "$prior_sha"
    printf 'replaced_overlay=%s\n' "${replacement:-none}"
  } | sudo tee "$state_tmp" >/dev/null || die 'failed to write private tryboot state'
  assert_owned_regular "$state_tmp" 600 || die 'private tryboot state ownership drifted'
  state_snapshot="$(privileged_snapshot "$state_tmp" "$rollback_tmp" state)" || die 'failed to capture tryboot state'
  expected_sha="$(sha "$state_snapshot")" || die 'failed to hash tryboot state snapshot'
  atomic_copy "$state_snapshot" "$state_file" 600 "$expected_sha" || die 'failed to publish tryboot state'
  published_state=true
  sudo depmod -a "$release"
  sudo sync
  stage_complete=true
  remove_transaction_workspace "$rollback_tmp" || return 1
  rollback_tmp=''
  trap - EXIT
  printf 'staged %s\n' "$revision"
}

prepare_copy() {
  local source="$1"
  local directory="$2"
  local mode="$3"
  local workspace="$4"
  local temporary snapshot expected_sha
  sudo test ! -L "$directory" && sudo test -d "$directory" || return
  assert_private_workspace "$workspace" || return
  snapshot="$(privileged_snapshot "$source" "$workspace" prepare)" || return
  expected_sha="$(sha "$snapshot")" || { sudo rm -f -- "$snapshot" || true; return 1; }
  temporary="$(sudo mktemp "$directory/.hp2r-prepare.XXXXXX")" || { sudo rm -f -- "$snapshot" || true; return 1; }
  atomic_copy "$snapshot" "$temporary" "$mode" "$expected_sha" || {
    sudo rm -f -- "$snapshot" "$temporary" || true
    return 1
  }
  sudo rm -f -- "$snapshot" || { sudo rm -f -- "$temporary" || true; return 1; }
  assert_owned_regular "$temporary" "$mode" || {
    sudo rm -f -- "$temporary" || true
    return 1
  }
  printf '%s\n' "$temporary"
}

identity() {
  local transaction driver_version revision release artifact_dir overlay_file

  transaction="$(assert_transaction_state)" || die 'candidate transaction is not safe to inspect'
  IFS=$'\t' read -r driver_version revision release artifact_dir <<<"$transaction"
  overlay_file="$(state_value overlay_file)"
  printf '%s\t%s\n' "$driver_version" "$overlay_file"
}

commit() {
  # Keep compensation fields alive for the process EXIT trap on set -e.
  transaction=''
  driver_version=''
  revision=''
  release=''
  artifact_dir=''
  workspace=''
  replacement=''
  normal_backup=''
  candidate_backup=''
  normal_candidate=''
  normal_tmp=''
  normal_sha=''
  normal_backup_sha=''
  candidate_backup_sha=''
  prior_tmp=''
  state_hold=''
  normal_published=false
  tryboot_restored=false
  state_moved=false
  state_deleted=false
  commit_complete=false

  cleanup_commit() {
    local status=$?
    if test "$status" -ne 0 && ! "$commit_complete"; then
      if "$state_moved" && require_regular "$state_hold"; then sudo mv -f "$state_hold" "$state_file" || true; fi
      if "$tryboot_restored"; then atomic_copy "$candidate_backup" "$tryboot_config" 644 "$candidate_backup_sha" true || true; fi
      if "$normal_published"; then atomic_copy "$normal_backup" "$normal_config" 644 "$normal_backup_sha" true || true; fi
    fi
    sudo rm -f -- "$normal_tmp" "$prior_tmp" "$state_hold" 2>/dev/null || true
    if ! remove_transaction_workspace "$workspace" 2>/dev/null; then
      remove_transaction_workspace "$workspace" 2>/dev/null || exit "$status"
    fi
    workspace=''
    trap - EXIT
    if "$commit_complete"; then exit 0; fi
    exit "$status"
  }

  transaction="$(assert_transaction_state)" || die 'candidate transaction is not safe to commit'
  IFS=$'\t' read -r driver_version revision release artifact_dir <<<"$transaction"
  workspace="$(new_transaction_workspace)" || die 'failed to create private commit workspace'
  trap cleanup_commit EXIT
  normal_sha="$(state_value normal_config_sha256)"
  normal_backup="$(privileged_snapshot "$normal_config" "$workspace" normal-backup)" || die 'failed to snapshot normal boot config for commit'
  candidate_backup="$(privileged_snapshot "$tryboot_config" "$workspace" candidate-backup)" || die 'failed to snapshot tryboot config for commit'
  normal_backup_sha="$(sha "$normal_backup")" || die 'failed to hash normal boot config snapshot'
  candidate_backup_sha="$(sha "$candidate_backup")" || die 'failed to hash tryboot config snapshot'
  normal_candidate="$(private_file "$workspace" normal-candidate)" || die 'failed to create private normal config candidate'
  replacement="$(state_value replaced_overlay)"
  test "$replacement" != none || replacement=''
  validate_overlay_declarations "$normal_config" "$replacement" "$normal_candidate" "$workspace" || die 'unsafe display overlay declaration during commit'
  assert_private_workspace "$workspace" || die 'private commit workspace changed while creating candidate'
  printf '\n# hyperpixel2r-kms accepted candidate\ndtoverlay=%s\n' "$(state_value overlay_file)" | sudo tee -a "$normal_candidate" >/dev/null || die 'failed to append normal config candidate'
  assert_owned_regular "$normal_candidate" 600 || die 'normal config candidate ownership drifted'
  LC_ALL=C sudo awk '{ line=$0; sub(/\r$/, "", line); if (length(line) > 98) exit 1 }' "$normal_candidate" || die 'normal boot config has a firmware-line-length violation'
  normal_tmp="$(prepare_copy "$normal_candidate" "$(dirname "$normal_config")" 644 "$workspace")" || die 'failed to prepare normal config publication'
  if test "$(state_value tryboot_existed)" = true; then prior_tmp="$(prepare_copy "$artifact_dir/prior-tryboot.txt" "$(dirname "$tryboot_config")" 600 "$workspace")" || die 'failed to prepare prior tryboot config'; else prior_tmp=''; fi
  state_hold="$(sudo mktemp "$state_dir/.tryboot-state-hold.XXXXXX")" || die 'failed to create commit state hold'
  test "$(sha "$normal_config")" = "$normal_sha" || die 'normal boot config changed after commit validation'
  sudo mv -f "$normal_tmp" "$normal_config" || die 'failed to publish accepted normal config'
  normal_published=true
  if test -n "$prior_tmp"; then sudo mv -f "$prior_tmp" "$tryboot_config" || die 'failed to restore prior tryboot config'; else sudo rm -f -- "$tryboot_config" || die 'failed to remove tryboot config'; fi
  tryboot_restored=true
  sudo mv -f "$state_file" "$state_hold" || die 'failed to move commit state hold'
  state_moved=true
  sudo rm -f -- "$state_hold" || die 'failed to delete committed tryboot state'
  state_deleted=true
  sudo sync
  sudo rm -f -- "$normal_tmp" "$prior_tmp" "$state_hold" || die 'failed to clean private commit publications'
  commit_complete=true
  remove_transaction_workspace "$workspace" || return 1
  workspace=''
  trap - EXIT
  printf 'committed %s\n' "$revision"
}

rollback() {
  # Keep compensation fields alive for the process EXIT trap on set -e.
  transaction=''
  driver_version=''
  revision=''
  release=''
  artifact_dir=''
  workspace=''
  module_file=''
  module_sha=''
  overlay_file=''
  overlay_sha=''
  module_path=''
  overlay_path=''
  prior_tmp=''
  candidate_backup=''
  candidate_backup_sha=''
  state_hold=''
  prior_dkms_state=''
  candidate_dkms_state=''
  candidate_dkms_tree_present=false
  candidate_dkms_backup=''
  dkms_restore_started=false
  tryboot_restored=false
  module_removed=false
  overlay_removed=false
  state_moved=false
  rollback_complete=false

  cleanup_rollback() {
    local status=$?
    if test "$status" -ne 0 && ! "$rollback_complete"; then
      if "$state_moved" && require_regular "$state_hold"; then sudo mv -f "$state_hold" "$state_file" || true; fi
      if "$dkms_restore_started"; then
        restore_dkms_source_state "$candidate_dkms_state" "$candidate_dkms_backup" "$dkms_root/hyperpixel2r-kms-$driver_version" "$candidate_dkms_tree_present" || true
      fi
      if "$overlay_removed"; then atomic_copy "$artifact_dir/$overlay_file" "$overlay_path" 644 "$overlay_sha" true || true; fi
      if "$module_removed"; then atomic_copy "$artifact_dir/$module_file" "$module_path" 644 "$module_sha" || true; fi
      if "$tryboot_restored"; then atomic_copy "$candidate_backup" "$tryboot_config" 644 "$candidate_backup_sha" true || true; fi
    fi
    sudo rm -f -- "$prior_tmp" "$state_hold" 2>/dev/null || true
    if ! remove_transaction_workspace "$workspace" 2>/dev/null; then
      remove_transaction_workspace "$workspace" 2>/dev/null || exit "$status"
    fi
    workspace=''
    trap - EXIT
    if "$rollback_complete"; then exit 0; fi
    exit "$status"
  }

  transaction="$(assert_transaction_state)" || die 'candidate transaction is not safe to roll back'
  IFS=$'\t' read -r driver_version revision release artifact_dir <<<"$transaction"
  workspace="$(new_transaction_workspace)" || die 'failed to create private rollback workspace'
  trap cleanup_rollback EXIT
  module_file="$(state_value module_file)"
  module_sha="$(state_value module_sha256)"
  overlay_file="$(state_value overlay_file)"
  overlay_sha="$(state_value overlay_sha256)"
  module_path="${root}/lib/modules/$release/extra/$module_file"
  overlay_path="${root}/boot/firmware/overlays/$overlay_file"
  prior_dkms_state="$(dkms_prior_state "$artifact_dir")" || die 'invalid prior DKMS rollback marker'
  assert_source_tree_shape "$dkms_root/hyperpixel2r-kms-$driver_version" "$artifact_dir/dkms-source" ||
    die 'candidate DKMS source is not bound to the active transaction'
  candidate_dkms_tree_present=true
  candidate_dkms_state="$(validate_dkms_status "$driver_version")" || die 'invalid candidate DKMS status'
  case "$candidate_dkms_state" in absent|unregistered|registered) ;; *) die 'invalid candidate DKMS status';; esac
  case "$prior_dkms_state" in
    absent) ;;
    unregistered|registered) assert_source_tree_shape "$artifact_dir/prior-dkms" || die 'invalid prior DKMS backup' ;;
    *) die 'invalid prior DKMS rollback marker' ;;
  esac
  candidate_backup="$(privileged_snapshot "$tryboot_config" "$workspace" candidate-backup)" || die 'failed to snapshot candidate tryboot config'
  candidate_backup_sha="$(sha "$candidate_backup")" || die 'failed to hash candidate tryboot snapshot'
  assert_private_workspace "$workspace" || die 'private rollback workspace changed before DKMS snapshot'
  candidate_dkms_backup="$(sudo mktemp -d "$workspace/.hp2r-dkms-candidate.XXXXXX")" || die 'failed to create candidate DKMS backup'
  sudo chmod 0755 "$candidate_dkms_backup" || die 'failed to set candidate DKMS backup mode'
  sudo chown root:root "$candidate_dkms_backup" || die 'failed to set candidate DKMS backup ownership'
  assert_private_workspace "$workspace" || die 'private rollback workspace changed while capturing DKMS source'
  for name in "${source_files[@]}"; do
    expected_sha="$(sha "$dkms_root/hyperpixel2r-kms-$driver_version/$name")" || die 'failed to hash candidate DKMS source leaf'
    atomic_copy "$dkms_root/hyperpixel2r-kms-$driver_version/$name" "$candidate_dkms_backup/$name" 644 "$expected_sha" || die 'failed to capture candidate DKMS source leaf'
  done
  assert_source_tree_shape "$candidate_dkms_backup" "$artifact_dir/dkms-source" || die 'failed to capture candidate DKMS source'
  if test "$(state_value tryboot_existed)" = true; then prior_tmp="$(prepare_copy "$artifact_dir/prior-tryboot.txt" "$(dirname "$tryboot_config")" 600 "$workspace")" || die 'failed to prepare prior tryboot config'; else prior_tmp=''; fi
  state_hold="$(sudo mktemp "$state_dir/.tryboot-state-hold.XXXXXX")" || die 'failed to create rollback state hold'
  dkms_restore_started=true
  if test "$prior_dkms_state" = absent; then
    restore_dkms_source_state "$prior_dkms_state" "$artifact_dir/prior-dkms" "$dkms_root/hyperpixel2r-kms-$driver_version" false || die 'failed to restore absent prior DKMS state'
  else
    restore_dkms_source_state "$prior_dkms_state" "$artifact_dir/prior-dkms" "$dkms_root/hyperpixel2r-kms-$driver_version" true || die 'failed to restore prior DKMS state'
  fi
  if test -n "$prior_tmp"; then sudo mv -f "$prior_tmp" "$tryboot_config" || die 'failed to restore prior tryboot config'; else sudo rm -f -- "$tryboot_config" || die 'failed to remove tryboot config'; fi
  tryboot_restored=true
  sudo rm -f -- "$module_path" || die 'failed to remove staged module'
  module_removed=true
  sudo rm -f -- "$overlay_path" || die 'failed to remove staged overlay'
  overlay_removed=true
  sudo depmod -a "$release"
  sudo mv -f "$state_file" "$state_hold" || die 'failed to move rollback state hold'
  state_moved=true
  sudo rm -f -- "$state_hold" || die 'failed to delete rolled-back tryboot state'
  sudo sync
  sudo rm -f -- "$prior_tmp" "$state_hold" || die 'failed to clean private rollback publications'
  rollback_complete=true
  remove_transaction_workspace "$workspace" || return 1
  workspace=''
  trap - EXIT
  printf 'rolled back %s\n' "$revision"
}

uninstall() {
  local config version_dir revision_dir release_dir manifest version revision release module_file overlay_file applied_dtb_file
  local -a artifacts=() releases=() overlays=() driver_versions=()
  local artifact record_tail prior record_version known_version source_match prior_dkms_state_value dkms_dir="" restore_prior_dkms=false remove_dkms=false
  for config in "$normal_config" "$tryboot_config"; do
    test ! -L "$config" && test ! -e "$config" && continue
    require_regular "$config" || die 'unsafe boot config during uninstall'
    assert_no_owned_generic_overlay "$config" || die 'refusing uninstall while an owned generic overlay is configured'
  done
  test ! -L "$state_file" && test ! -e "$state_file" || die 'refusing uninstall while a transaction is active'
  if sudo test -L "$artifact_root"; then die 'unsafe artifact root'; fi
  if ! sudo test -e "$artifact_root"; then printf 'nothing installed\n'; return; fi
  assert_owned_dir "$artifact_root" || die 'unsafe artifact root'
  while IFS= read -r -d '' version_dir; do
    assert_owned_dir "$version_dir" || die 'unsafe artifact version directory'
    version="$(basename "$version_dir")"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'unsafe artifact version directory'
    while IFS= read -r -d '' revision_dir; do
      assert_owned_dir "$revision_dir" || die 'unsafe artifact revision directory'
      revision="$(basename "$revision_dir")"
      [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || die 'unsafe artifact revision directory'
      while IFS= read -r -d '' release_dir; do
        assert_owned_dir "$release_dir" || die 'unsafe artifact release directory'
        release="$(basename "$release_dir")"
        [[ "$release" =~ ^[A-Za-z0-9._+-]+$ ]] || die 'unsafe artifact release directory'
        manifest="$release_dir/manifest.txt"
        prior=false
        if sudo test -L "$release_dir/prior-tryboot.txt"; then die 'unsafe stored prior tryboot config'
        elif sudo test -e "$release_dir/prior-tryboot.txt"; then prior=true
        fi
        assert_artifact_tree "$release_dir" "$prior" || die 'unsafe stored artifact tree'
        test "$(manifest_value "$manifest" driver_version)" = "$version" || die 'artifact driver version does not match its directory'
        test "$(manifest_value "$manifest" source_revision)" = "$revision" || die 'artifact source revision does not match its directory'
        test "$(manifest_value "$manifest" kernel_release)" = "$release" || die 'artifact kernel release does not match its directory'
        artifacts+=("$release_dir:$prior:$version")
        releases+=("$release")
        overlays+=("$release_dir/$(manifest_value "$manifest" overlay_file)")
        known_version=false
        for known_version in "${driver_versions[@]}"; do
          if test "$known_version" = "$version"; then known_version=true; break; fi
        done
        if test "$known_version" != true; then driver_versions+=("$version"); fi
      done < <(sudo find -P "$revision_dir" -mindepth 1 -maxdepth 1 -print0)
    done < <(sudo find -P "$version_dir" -mindepth 1 -maxdepth 1 -print0)
  done < <(sudo find -P "$artifact_root" -mindepth 1 -maxdepth 1 -print0)
  test "${#artifacts[@]}" -gt 0 || die 'artifact root is empty or malformed'
  for version in "${driver_versions[@]}"; do
    dkms_dir="$dkms_root/hyperpixel2r-kms-$version"
    test ! -L "$dkms_dir" && test ! -e "$dkms_dir" && continue
    restore_prior_dkms=false
    remove_dkms=false
    prior_dkms_state_value=''
    # A recognized pre-stage source tree wins over a candidate-tree match: it
    # belongs to the user's prior setup and must be preserved.
    for record in "${artifacts[@]}"; do
      artifact="${record%%:*}"
      record_tail="${record#*:}"
      prior="${record_tail%%:*}"
      record_version="${record_tail#*:}"
      test "$record_version" = "$version" || continue
      known_version="$(dkms_prior_state "$artifact")" || die 'invalid stored prior DKMS marker'
      test "$known_version" != absent || continue
      if assert_source_tree_shape "$dkms_dir" "$artifact/prior-dkms" 2>/dev/null; then
        if "$restore_prior_dkms" && test "$prior_dkms_state_value" != "$known_version"; then
          die 'conflicting stored prior DKMS registration states'
        fi
        restore_prior_dkms=true
        prior_dkms_state_value="$known_version"
      fi
    done
    if ! "$restore_prior_dkms"; then
      source_match=false
      for record in "${artifacts[@]}"; do
        artifact="${record%%:*}"
        record_tail="${record#*:}"
        record_version="${record_tail#*:}"
        test "$record_version" = "$version" || continue
        if assert_source_tree_shape "$dkms_dir" "$artifact/dkms-source" 2>/dev/null; then
          source_match=true
          break
        fi
      done
      "$source_match" || die 'DKMS source is not bound to a stored artifact'
      remove_dkms=true
    fi
    if "$remove_dkms"; then
      dkms_status="$(validate_dkms_status "$version")" || die 'failed to validate DKMS status during uninstall'
      case "$dkms_status" in
        absent|unregistered) ;;
        registered) run_dkms remove -m hyperpixel2r-kms -v "$version" --all ;;
        *) die 'invalid DKMS status result' ;;
      esac
      remove_exact_tree "$dkms_dir" || die 'failed to remove DKMS source tree during uninstall'
    elif test "$prior_dkms_state_value" = unregistered; then
      dkms_status="$(validate_dkms_status "$version")" || die 'failed to validate prior DKMS status during uninstall'
      case "$dkms_status" in
        absent|unregistered) ;;
        registered) run_dkms remove -m hyperpixel2r-kms -v "$version" --all ;;
        *) die 'invalid DKMS status result' ;;
      esac
    fi
  done
  for release in "${releases[@]}"; do
    [[ "$release" =~ ^[A-Za-z0-9._+-]+$ ]] || die 'unsafe recorded release'
    module_path="${root}/lib/modules/$release/extra/hyperpixel2r_kms.ko"
    if sudo test -L "$module_path"; then
      die 'unsafe installed module'
    elif sudo test -e "$module_path"; then
      assert_owned_regular "$module_path" 644 || die 'unsafe installed module'
      source_match=false
      for record in "${artifacts[@]}"; do
        artifact="${record%%:*}"
        test "$(manifest_value "$artifact/manifest.txt" kernel_release)" = "$release" || continue
        if test "$(sha "$module_path")" = "$(sha "$artifact/hyperpixel2r_kms.ko")"; then source_match=true; break; fi
      done
      "$source_match" || die 'installed module is not checksum-proven owned'
      sudo rm -f -- "$module_path"
    fi
    sudo depmod -a "$release"
  done
  for source in "${overlays[@]}"; do
    overlay_path="${root}/boot/firmware/overlays/$(basename "$source")"
    if sudo test -L "$overlay_path"; then
      die 'unsafe installed overlay'
    elif sudo test -e "$overlay_path"; then
      assert_owned_regular "$overlay_path" boot || die 'unsafe installed overlay'
      test "$(sha "$overlay_path")" = "$(sha "$source")" || die 'installed overlay is not checksum-proven owned'
      sudo rm -f -- "$overlay_path"
    fi
  done
  for record in "${artifacts[@]}"; do
    artifact="${record%%:*}"
    record_tail="${record#*:}"
    prior="${record_tail%%:*}"
    remove_artifact_tree "$artifact" "$prior" || die 'failed to remove stored artifact tree'
  done
  sudo sync
  printf 'uninstalled %s stored bundles\n' "${#artifacts[@]}"
}

case "${1-}" in
  stage) shift; stage "$@" ;;
  identity) identity ;;
  commit) commit ;;
  rollback) rollback ;;
  uninstall) uninstall ;;
  *) die 'usage: lifecycle-remote.sh {stage|identity|commit|rollback|uninstall}' ;;
esac
