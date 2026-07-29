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
accepted_state="$state_dir/accepted-state"
accepted_stock_config="$state_dir/accepted-stock-config.txt"
accepted_transition="$state_dir/accepted-transition"
accepted_transition_prior_config="$state_dir/accepted-transition-prior-config.txt"
accepted_uninstall="$state_dir/accepted-uninstall"
accepted_uninstall_stock="$state_dir/accepted-uninstall-stock.txt"
rollback_state="$state_dir/rollback-state"
rollback_candidate_inventory="$state_dir/rollback-candidate-dkms-state"
rollback_candidate_tryboot="$state_dir/rollback-candidate-tryboot.txt"
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
state_keys_v1=(
  schema_version driver_version source_revision source_tree kernel_release module_file
  module_sha256 overlay_file overlay_sha256 applied_dtb_file applied_dtb_sha256
  normal_config_sha256 candidate_config_sha256 tryboot_existed prior_tryboot_sha256
  replaced_overlay
)
state_keys_v2=(
  "${state_keys_v1[@]}"
  module_existed overlay_existed
)
state_keys=(
  "${state_keys_v2[@]}"
  prior_dkms_inventory_sha256
)
accepted_keys_v1=(
  schema_version driver_version source_revision kernel_release manifest_sha256
  module_file module_sha256 overlay_file overlay_sha256 normal_config_sha256
  stock_config_sha256
)
accepted_keys=(
  "${accepted_keys_v1[@]}"
  prior_dkms_inventory_sha256
)
accepted_transition_keys_v2=(
  schema_version kind phase prior_driver_version prior_source_revision prior_kernel_release
  candidate_driver_version candidate_source_revision candidate_kernel_release
  candidate_manifest_sha256 candidate_module_file candidate_module_sha256
  candidate_overlay_file candidate_overlay_sha256
  prior_normal_config_sha256 candidate_normal_config_sha256 tryboot_config_sha256
  prior_dkms_status
)
accepted_transition_keys=(
  "${accepted_transition_keys_v2[@]}"
  candidate_dkms_inventory_sha256
)
accepted_uninstall_keys_v2=(
  schema_version phase driver_version source_revision kernel_release
  manifest_sha256 module_file module_sha256 overlay_file overlay_sha256
  stock_config_sha256 dkms_status prior_dkms_status artifact_prior
)
accepted_uninstall_keys=(
  "${accepted_uninstall_keys_v2[@]}"
  prior_dkms_inventory_sha256
)
rollback_keys=(
  schema_version mode phase transaction_sha256 driver_version source_revision
  kernel_release manifest_sha256 module_file module_sha256 overlay_file
  overlay_sha256 candidate_dkms_inventory_sha256 prior_dkms_inventory_sha256
  candidate_tryboot_sha256 tryboot_existed module_existed overlay_existed
)

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

accepted_workspace=''
cleanup_accepted_workspace() {
  local status=$?
  trap - EXIT
  if test -n "$accepted_workspace"; then
    remove_transaction_workspace "$accepted_workspace" 2>/dev/null || true
  fi
  exit "$status"
}
trap cleanup_accepted_workspace EXIT

fixture_interrupt_after() {
  test -n "$root" || return 0
  test "${HP2R_FIXTURE_INTERRUPT_AFTER:-}" = "$1" || return 0
  printf 'fixture interruption after %s\n' "$1" >&2
  if test "${HP2R_FIXTURE_PRESERVE_MUTATIONS:-}" = 1; then
    trap - EXIT
  fi
  exit 97
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
  assert_owned_dir_mode "$1" 755
}

assert_owned_dir_mode() {
  local path="$1"
  local expected_mode="$2"
  sudo test ! -L "$path" && sudo test -d "$path" || {
    printf 'unsafe owned directory: %s\n' "$path" >&2
    return 1
  }
  test "$(sudo stat -c '%U:%G' "$path")" = root:root || {
    printf 'ownership drift: %s\n' "$path" >&2
    return 1
  }
  test "$(sudo stat -c '%a' "$path")" = "$expected_mode" || {
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

assert_dkms_inventory_file() {
  local marker="$1"
  local first source_state count row kernel architecture kernel_state previous=''
  local line_count=0

  assert_owned_regular "$marker" 600 || return
  test "$(sudo stat -c '%s' "$marker")" -le 4096 || {
    echo 'DKMS inventory exceeds its size limit' >&2
    return 1
  }
  sudo awk 'length($0) > 160 { exit 1 }' "$marker" || {
    echo 'DKMS inventory contains an overlong row' >&2
    return 1
  }
  first="$(sudo sed -n '1p' "$marker")"
  case "$first" in
    absent|unregistered|registered|added|built|installed)
      test "$(sudo awk 'END { print NR }' "$marker")" = 1
      return
      ;;
    schema_version=2) ;;
    *) echo 'unsupported DKMS inventory schema' >&2; return 1 ;;
  esac

  source_state="$(sudo sed -n '2s/^source_state=//p' "$marker")"
  count="$(sudo sed -n '3s/^kernel_count=//p' "$marker")"
  case "$source_state" in absent|unregistered|added) ;; *) return 1;; esac
  [[ "$count" =~ ^(0|[1-9]|1[0-6])$ ]] || return
  test "$(sudo awk 'END { print NR }' "$marker")" = "$((count + 3))" || return
  while IFS= read -r row; do
    line_count=$((line_count + 1))
    [[ "$row" =~ ^kernel=([A-Za-z0-9._+-]+)$'\t'(aarch64|arm64)$'\t'(built|installed)$ ]] ||
      return 1
    kernel="${BASH_REMATCH[1]}"
    architecture="${BASH_REMATCH[2]}"
    kernel_state="${BASH_REMATCH[3]}"
    row="$kernel"$'\t'"$architecture"$'\t'"$kernel_state"
    if test -n "$previous"; then
      test "$previous" \< "$row" || {
        echo 'DKMS inventory rows are duplicated or not canonical' >&2
        return 1
      }
    fi
    previous="$row"
  done < <(sudo sed -n '4,$p' "$marker")
  test "$line_count" = "$count" || return
  case "$source_state:$count" in
    absent:0|unregistered:0|added:*) ;;
    *) echo 'DKMS inventory source state conflicts with kernel rows' >&2; return 1 ;;
  esac
}

dkms_inventory_state() {
  local marker="$1"
  local first

  assert_dkms_inventory_file "$marker" || return
  first="$(sudo sed -n '1p' "$marker")"
  if test "$first" = schema_version=2; then
    sudo sed -n '2s/^source_state=//p' "$marker"
  else
    printf '%s\n' "$first"
  fi
}

capture_dkms_inventory() {
  local version="$1"
  local output_file="$2"
  local workspace="$3"
  local status_file status size line source_state=unregistered
  local -a pipeline_status=()
  local kernel architecture kernel_state row previous=''
  local -a rows=() sorted_rows=()

  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return
  assert_private_workspace "$workspace" || return
  case "$output_file" in "$workspace"/*) ;; *) return 1;; esac
  assert_owned_regular "$output_file" 600 || return
  if dkms_available; then
    status_file="$(private_file "$workspace" dkms-status)" || return
    set +e
    run_dkms status -m hyperpixel2r-kms -v "$version" 2>/dev/null |
      sudo head -c 4097 |
      sudo tee "$status_file" >/dev/null
    pipeline_status=("${PIPESTATUS[@]}")
    set -e
    status="${pipeline_status[0]}"
    test "${pipeline_status[1]}" = 0 && test "${pipeline_status[2]}" = 0 || {
      sudo rm -f -- "$status_file" || true
      echo 'failed to capture bounded DKMS status' >&2
      return 1
    }
    size="$(sudo stat -c '%s' "$status_file")" || return
    test "$size" -le 4096 || {
      sudo rm -f -- "$status_file" || true
      echo 'DKMS status exceeds its size limit' >&2
      return 1
    }
    if test "$status" -ne 0; then
      test "$size" = 0 || {
        sudo rm -f -- "$status_file" || true
        echo 'DKMS status failed with output' >&2
        return 1
      }
    else
      while IFS= read -r line; do
        test -n "$line" || continue
        if test "$line" = "hyperpixel2r-kms/$version: added"; then
          source_state=added
          continue
        fi
        if [[ "$line" =~ ^hyperpixel2r-kms/$version,\ ([A-Za-z0-9._+-]+),\ (aarch64|arm64):\ (built|installed)$ ]]; then
          source_state=added
          kernel="${BASH_REMATCH[1]}"
          architecture="${BASH_REMATCH[2]}"
          kernel_state="${BASH_REMATCH[3]}"
          rows+=("$kernel"$'\t'"$architecture"$'\t'"$kernel_state")
          test "${#rows[@]}" -le 16 || {
            sudo rm -f -- "$status_file" || true
            echo 'DKMS status contains too many kernel rows' >&2
            return 1
          }
          continue
        fi
        sudo rm -f -- "$status_file" || true
        printf 'unrecognized DKMS status line: %s\n' "$line" >&2
        return 1
      done < <(sudo cat "$status_file")
    fi
    sudo rm -f -- "$status_file" || return
  fi
  if test "${#rows[@]}" -gt 0; then
    while IFS= read -r row; do sorted_rows+=("$row"); done < <(
      printf '%s\n' "${rows[@]}" | LC_ALL=C sort
    )
    for row in "${sorted_rows[@]}"; do
      test -z "$previous" || test "$previous" != "$row" || {
        echo 'DKMS status contains a duplicate kernel row' >&2
        return 1
      }
      previous="$row"
    done
  fi
  {
    printf 'schema_version=2\n'
    printf 'source_state=%s\n' "$source_state"
    printf 'kernel_count=%s\n' "${#sorted_rows[@]}"
    for row in "${sorted_rows[@]}"; do printf 'kernel=%s\n' "$row"; done
  } | sudo tee "$output_file" >/dev/null || return
  assert_dkms_inventory_file "$output_file"
}

write_empty_dkms_inventory() {
  local source_state="$1"
  local output_file="$2"

  case "$source_state" in absent|unregistered) ;; *) return 1;; esac
  {
    printf 'schema_version=2\n'
    printf 'source_state=%s\n' "$source_state"
    printf 'kernel_count=0\n'
  } | sudo tee "$output_file" >/dev/null || return
  assert_dkms_inventory_file "$output_file"
}

dkms_prior_state() {
  local artifact_dir="$1"
  dkms_inventory_state "$artifact_dir/dkms-prior-state"
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
    unregistered:1|registered:1|added:1|built:1|installed:1) ;;
    *) echo 'prior DKMS backup does not match its state marker' >&2; return 1;;
  esac
  test "$(sha "$artifact_dir/$module_file")" = "$(manifest_value "$manifest" module_sha256)" || return
  test "$(sha "$artifact_dir/$overlay_file")" = "$(manifest_value "$manifest" overlay_sha256)" || return
  test "$(sha "$artifact_dir/$applied_dtb_file")" = "$(manifest_value "$manifest" applied_dtb_sha256)" || return
}

assert_state_schema() {
  local key count schema
  local -a expected_keys

  assert_owned_regular "$state_file" 600 || return
  schema="$(sudo awk -F= '$1 == "schema_version" { print $2 }' "$state_file")"
  case "$schema" in
    1) expected_keys=("${state_keys_v1[@]}") ;;
    2) expected_keys=("${state_keys_v2[@]}") ;;
    3) expected_keys=("${state_keys[@]}") ;;
    *) echo 'unsupported tryboot state schema version' >&2; return 1 ;;
  esac
  test "$(sudo awk 'END { print NR }' "$state_file")" = "${#expected_keys[@]}" || {
    echo 'tryboot state has the wrong cardinality' >&2
    return 1
  }
  sudo awk -F= 'NF != 2 || $1 == "" || $2 == "" { exit 1 }' "$state_file" || {
    echo 'tryboot state has malformed rows' >&2
    return 1
  }
  for key in "${expected_keys[@]}"; do
    count="$(sudo awk -F= -v wanted="$key" '$1 == wanted { count++ } END { print count + 0 }' "$state_file")"
    test "$count" = 1 || {
      printf 'tryboot state key is missing or duplicated: %s\n' "$key" >&2
      return 1
    }
  done
}

state_value() {
  local key="$1"

  assert_owned_regular "$state_file" 600 || return
  sudo awk -F= -v wanted="$key" '$1 == wanted { print $2 }' "$state_file"
}

assert_transaction_state() {
  local schema driver_version revision source_tree release module_file module_sha overlay_file overlay_sha applied_dtb_file applied_dtb_sha normal_sha candidate_sha prior_existed prior_sha replaced_overlay module_existed overlay_existed prior_dkms_inventory_sha artifact_dir manifest overlay_name

  assert_state_schema || return
  schema="$(state_value schema_version)"
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
  if test "$schema" = 2 || test "$schema" = 3; then
    module_existed="$(state_value module_existed)"
    overlay_existed="$(state_value overlay_existed)"
  else
    # Version 1 transactions predate leaf-ownership tracking.  Preserve their
    # original rollback behavior so an already-staged public artifact remains
    # operable, while every new transaction records the distinction.
    module_existed=false
    overlay_existed=false
  fi
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
  case "$module_existed:$overlay_existed" in
    true:true|true:false|false:true|false:false) ;;
    *) echo 'invalid transaction leaf ownership' >&2; return 1 ;;
  esac
  require_regular "$normal_config" || return
  require_regular "$tryboot_config" || return
  test "$(sha "$normal_config")" = "$normal_sha" || { echo 'normal boot config changed since stage' >&2; return 1; }
  test "$(sha "$tryboot_config")" = "$candidate_sha" || { echo 'candidate tryboot config changed since stage' >&2; return 1; }
  artifact_dir="$artifact_root/$driver_version/$revision/$release"
  assert_artifact_tree "$artifact_dir" "$prior_existed" || return
  if test "$schema" = 3; then
    prior_dkms_inventory_sha="$(state_value prior_dkms_inventory_sha256)"
    [[ "$prior_dkms_inventory_sha" =~ ^[0-9a-f]{64}$ ]] || {
      echo 'invalid prior DKMS inventory checksum' >&2
      return 1
    }
    test "$(sha "$artifact_dir/dkms-prior-state")" = "$prior_dkms_inventory_sha" || {
      echo 'stored prior DKMS inventory checksum differs from transaction' >&2
      return 1
    }
  fi
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
  validate_named_dkms_status hyperpixel2r-kms "$version"
}

resolved_module_path() {
  local release="$1"
  local module="$2"
  local module_root="${root}/lib/modules/$release"
  local path relative

  [[ "$release" =~ ^[A-Za-z0-9._+-]+$ ]] || return
  [[ "$module" =~ ^[A-Za-z0-9_]+$ ]] || return
  path="$(sudo modinfo -k "$release" -n "$module")" || return
  test -n "$path" && test "${path#*$'\n'}" = "$path" || return
  case "$path" in
    "$module_root"/*) ;;
    *) printf 'resolved module escaped the running kernel tree: %s\n' "$path" >&2; return 1 ;;
  esac
  relative="${path#"$module_root"/}"
  case "$relative" in
    ''|/*|../*|*/../*|*/..|*"//"*) return 1 ;;
  esac
  case "$relative" in
    extra/"$module".ko|\
    extra/"$module".ko.xz|\
    extra/"$module".ko.zst|\
    extra/"$module".ko.gz|\
    updates/dkms/"$module".ko|\
    updates/dkms/"$module".ko.xz|\
    updates/dkms/"$module".ko.zst|\
    updates/dkms/"$module".ko.gz) ;;
    *) printf 'resolved module has an unsupported leaf: %s\n' "$path" >&2; return 1 ;;
  esac
  assert_owned_regular "$path" 644 || return
  printf '%s\n' "$path"
}

module_leaf_sha() {
  local path="$1"

  assert_owned_regular "$path" 644 || return
  case "$path" in
    *.ko) sha "$path" ;;
    *.ko.xz) sudo xz -dc -- "$path" | sha256sum | awk '{ print $1 }' ;;
    *.ko.zst) sudo zstd -dc -- "$path" | sha256sum | awk '{ print $1 }' ;;
    *.ko.gz) sudo gzip -dc -- "$path" | sha256sum | awk '{ print $1 }' ;;
    *) return 1 ;;
  esac
}

resolved_module_sha() {
  local release="$1"
  local module="$2"
  local path

  path="$(resolved_module_path "$release" "$module")" || return
  module_leaf_sha "$path"
}

validate_named_dkms_status() {
  local module="$1"
  local version="$2"
  local output status line count=0
  [[ "$module" =~ ^[A-Za-z0-9._+-]+$ ]] || return
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return
  if ! dkms_available; then
    printf 'absent\n'
    return
  fi
  set +e
  output="$(run_dkms status -m "$module" -v "$version" 2>/dev/null)"
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
    [[ "$line" =~ ^$module/$version(:\ added|,\ [A-Za-z0-9._+-]+,\ (aarch64|arm64):\ (built|installed))$ ]] || {
      printf 'unrecognized DKMS status line: %s\n' "$line" >&2
      return 1
    }
    count=$((count + 1))
  done <<<"$output"
  test "$count" -gt 0 || { echo 'empty DKMS status is malformed' >&2; return 1; }
  printf 'registered\n'
}

cleanup_legacy_planeradar() {
  local contract="$1"
  local expected_overlay="$2"
  local schema_version='' migration_id='' legacy_module='' legacy_version='' source_dir_relative=''
  local recovery_relative='' recovery_sha='' key field2 field3 extra source_dir source_entry
  local status overlay_path migration_root migration_dir evidence_manifest events contract_sha existing_sha
  local pending_state pending=false source_location=absent source_quarantine_root source_quarantine_path
  local original_count=0 quarantine_count=0 absent_count=0 index entry name
  local -a source_names=() source_hashes=() overlay_names=() overlay_hashes=()
  local -a overlay_locations=() overlay_quarantine_paths=()
  local -A seen_source=() seen_overlay=() source_contract_hashes=()

  if test -n "$root"; then contract="${root}${contract}"; fi
  [[ "$expected_overlay" =~ ^hyperpixel2r-kms-[0-9a-f]{12}\.dtbo$ ]] ||
    die 'unsafe expected external overlay file'
  require_regular "$contract" || die 'legacy migration contract is not a regular file'
  while IFS=$'\t' read -r key field2 field3 extra; do
    test -z "$extra" || die 'legacy migration contract has extra fields'
    case "$key" in
      schema_version)
        test -z "$schema_version" && test -n "$field2" && test -z "$field3" ||
          die 'duplicate or malformed legacy schema version'
        schema_version="$field2"
        ;;
      migration_id)
        test -z "$migration_id" && test -n "$field2" && test -z "$field3" ||
          die 'duplicate or malformed legacy migration id'
        migration_id="$field2"
        ;;
      legacy_module)
        test -z "$legacy_module" && test -n "$field2" && test -z "$field3" ||
          die 'duplicate or malformed legacy module'
        legacy_module="$field2"
        ;;
      legacy_version)
        test -z "$legacy_version" && test -n "$field2" && test -z "$field3" ||
          die 'duplicate or malformed legacy version'
        legacy_version="$field2"
        ;;
      source_dir)
        test -z "$source_dir_relative" && test -n "$field2" && test -z "$field3" ||
          die 'duplicate or malformed legacy source directory'
        source_dir_relative="$field2"
        ;;
      source_file)
        [[ "$field2" =~ ^[A-Za-z0-9._+-]+$ ]] && [[ "$field3" =~ ^[0-9a-f]{64}$ ]] ||
          die 'unsafe legacy source-file contract'
        test -z "${seen_source[$field2]+x}" || die 'duplicate legacy source file'
        seen_source["$field2"]=1
        source_contract_hashes["$field2"]="$field3"
        source_names+=("$field2")
        source_hashes+=("$field3")
        ;;
      overlay_file)
        [[ "$field2" =~ ^planeradar-hyperpixel2r-[0-9a-f]{12}\.dtbo$ ]] &&
          [[ "$field3" =~ ^[0-9a-f]{64}$ ]] ||
          die 'unsafe legacy overlay contract'
        test -z "${seen_overlay[$field2]+x}" || die 'duplicate legacy overlay file'
        seen_overlay["$field2"]=1
        overlay_names+=("$field2")
        overlay_hashes+=("$field3")
        ;;
      recovery_baseline)
        test -z "$recovery_relative" && [[ "$field2" =~ ^/boot/firmware/config\.txt\.task6-baseline\.[A-Za-z0-9._-]+\.bak$ ]] &&
          [[ "$field3" =~ ^[0-9a-f]{64}$ ]] ||
          die 'duplicate or unsafe recovery baseline contract'
        recovery_relative="$field2"
        recovery_sha="$field3"
        ;;
      *) die 'unknown legacy migration contract field' ;;
    esac
  done < "$contract"
  test "$schema_version" = 1 &&
    test "$migration_id" = planeradar-hyperpixel2r-v1 &&
    test "$legacy_module" = planeradar-hyperpixel2r &&
    test "$legacy_version" = 0.1.0 &&
    test "$source_dir_relative" = /usr/src/planeradar-hyperpixel2r-0.1.0 &&
    test "${#source_names[@]}" -gt 0 &&
    test "${#overlay_names[@]}" -gt 0 &&
    test -n "$recovery_relative" ||
    die 'legacy migration contract identity is invalid'

  require_regular "$normal_config" || die 'normal boot config is unsafe during legacy cleanup'
  sudo awk -v expected="$expected_overlay" '
    {
      line=$0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line !~ /^dtoverlay=/) next
      raw=substr(line, 11)
      split(raw, pieces, ",")
      if (pieces[1] ~ /^planeradar-hyperpixel2r-/) bad=1
      if (pieces[1] ~ /^hyperpixel2r-kms-/ && pieces[1] != expected) bad=1
      if (pieces[1] == expected) count++
    }
    END { exit bad || count != 1 }
  ' "$normal_config" || die 'legacy cleanup requires exactly the expected accepted external overlay'
  test ! -L "$state_file" && test ! -e "$state_file" ||
    die 'refusing legacy cleanup while a transaction is active'
  sudo test ! -e "${root}/sys/module/planeradar_hyperpixel2r" ||
    die 'refusing legacy cleanup while the legacy module is loaded'
  assert_owned_regular "${root}${recovery_relative}" boot ||
    die 'recovery baseline is unsafe during legacy cleanup'
  test "$(sha "${root}${recovery_relative}")" = "$recovery_sha" ||
    die 'recovery baseline checksum drifted'

  if sudo test -L "$state_dir"; then die 'unsafe HyperPixel state directory'; fi
  if sudo test -e "$state_dir"; then
    assert_owned_dir "$state_dir" || die 'unsafe HyperPixel state directory'
  fi
  migration_root="$state_dir/migrations"
  if sudo test -L "$migration_root"; then die 'unsafe migration evidence root'; fi
  if sudo test -e "$migration_root"; then
    assert_owned_dir "$migration_root" || die 'unsafe migration evidence root'
  fi
  migration_dir="$migration_root/$migration_id"
  if sudo test -L "$migration_dir"; then die 'unsafe migration evidence directory'; fi
  if sudo test -e "$migration_dir"; then
    assert_owned_dir "$migration_dir" || die 'unsafe migration evidence directory'
  fi
  contract_sha="$(sha "$contract")" || die 'failed to hash legacy migration contract'
  pending_state="$migration_dir/pending.tsv"
  if sudo test -e "$pending_state" || sudo test -L "$pending_state"; then
    assert_owned_regular "$pending_state" 600 || die 'legacy cleanup pending state is unsafe'
    test "$(sha "$pending_state")" = "$contract_sha" ||
      die 'legacy cleanup pending state differs'
    pending=true
  fi

  source_dir="${root}${source_dir_relative}"
  source_quarantine_root="${root}/usr/src/.${migration_id}.quarantine"
  source_quarantine_path="$source_quarantine_root/$(basename "$source_dir_relative")"
  assert_owned_dir "${root}/usr/src" || die 'legacy source parent is unsafe'
  assert_owned_dir "${root}/boot/firmware/overlays" || die 'legacy overlay parent is unsafe'
  if sudo test -L "$source_dir"; then
    die 'legacy source directory is a symlink'
  elif sudo test -e "$source_dir"; then
    assert_owned_dir "$source_dir" || die 'legacy source directory metadata drifted'
    while IFS= read -r -d '' source_entry; do
      field2="$(basename "$source_entry")"
      test -n "${seen_source[$field2]+x}" || die 'legacy source directory has an unowned leaf'
      assert_owned_regular "$source_entry" 644 || die 'legacy source leaf metadata drifted'
    done < <(sudo find -P "$source_dir" -mindepth 1 -maxdepth 1 -print0)
    for ((status = 0; status < ${#source_names[@]}; status++)); do
      source_entry="$source_dir/${source_names[$status]}"
      assert_owned_regular "$source_entry" 644 || die 'legacy source leaf is missing or unsafe'
      test "$(sha "$source_entry")" = "${source_hashes[$status]}" ||
        die 'legacy source leaf checksum drifted'
    done
    source_location=original
  fi
  if sudo test -L "$source_quarantine_root"; then
    die 'legacy source quarantine is a symlink'
  elif sudo test -e "$source_quarantine_root"; then
    assert_owned_dir_mode "$source_quarantine_root" 700 ||
      die 'legacy source quarantine metadata drifted'
    while IFS= read -r -d '' entry; do
      test "$entry" = "$source_quarantine_path" ||
        die 'legacy source quarantine has an unowned leaf'
    done < <(sudo find -P "$source_quarantine_root" -mindepth 1 -maxdepth 1 -print0)
  fi
  if sudo test -L "$source_quarantine_path"; then
    die 'legacy quarantined source directory is a symlink'
  elif sudo test -e "$source_quarantine_path"; then
    test "$source_location" = absent ||
      die 'legacy source exists at original and quarantine paths'
    assert_owned_dir "$source_quarantine_path" ||
      die 'legacy quarantined source directory metadata drifted'
    while IFS= read -r -d '' source_entry; do
      name="$(basename "$source_entry")"
      test -n "${source_contract_hashes[$name]+x}" ||
        die 'legacy quarantined source has an unowned leaf'
      assert_owned_regular "$source_entry" 644 ||
        die 'legacy quarantined source leaf metadata drifted'
      test "$(sha "$source_entry")" = "${source_contract_hashes[$name]}" ||
        die 'legacy quarantined source leaf checksum drifted'
    done < <(sudo find -P "$source_quarantine_path" -mindepth 1 -maxdepth 1 -print0)
    source_location=quarantine
  fi

  for ((status = 0; status < ${#overlay_names[@]}; status++)); do
    overlay_path="${root}/boot/firmware/overlays/${overlay_names[$status]}"
    field2="${root}/boot/firmware/overlays/.${migration_id}.quarantine.${overlay_names[$status]}"
    overlay_quarantine_paths+=("$field2")
    if sudo test -L "$overlay_path" || sudo test -L "$field2"; then
      die 'legacy overlay or quarantine is a symlink'
    elif sudo test -e "$overlay_path" && sudo test -e "$field2"; then
      die 'legacy overlay exists at original and quarantine paths'
    elif sudo test -e "$overlay_path"; then
      assert_owned_regular "$overlay_path" boot || die 'legacy overlay metadata drifted'
      test "$(sha "$overlay_path")" = "${overlay_hashes[$status]}" ||
        die 'legacy overlay checksum drifted'
      overlay_locations+=(original)
      original_count=$((original_count + 1))
    elif sudo test -e "$field2"; then
      assert_owned_regular "$field2" boot || die 'legacy quarantined overlay metadata drifted'
      test "$(sha "$field2")" = "${overlay_hashes[$status]}" ||
        die 'legacy quarantined overlay checksum drifted'
      overlay_locations+=(quarantine)
      quarantine_count=$((quarantine_count + 1))
    else
      overlay_locations+=(absent)
      absent_count=$((absent_count + 1))
    fi
  done
  if ! "$pending"; then
    sudo test ! -e "$source_quarantine_root" && sudo test ! -L "$source_quarantine_root" ||
      die 'legacy cleanup found source quarantine without a pending transaction'
    test "$quarantine_count" = 0 ||
      die 'legacy cleanup found overlay quarantine without a pending transaction'
    if test "$source_location" = original; then
      test "$original_count" = "${#overlay_names[@]}" ||
        die 'legacy cleanup found a partial owned artifact set'
    elif test "$source_location" = absent; then
      test "$absent_count" = "${#overlay_names[@]}" ||
        die 'legacy cleanup found a partial owned artifact set'
    else
      die 'legacy cleanup found a partial owned artifact set'
    fi
  fi

  dkms_available || die 'legacy cleanup requires available DKMS tooling'
  status="$(validate_named_dkms_status "$legacy_module" "$legacy_version")" ||
    die 'legacy DKMS status is malformed'
  if ! "$pending" && test "$source_location" = absent; then
    test "$status" = unregistered ||
      die 'legacy DKMS registration survived without its source tree'
  fi

  if sudo test -L "$state_dir"; then die 'unsafe HyperPixel state directory'; fi
  if ! sudo test -e "$state_dir"; then sudo install -d -m 0755 "$state_dir" || die 'failed to create HyperPixel state directory'; fi
  assert_owned_dir "$state_dir" || die 'unsafe HyperPixel state directory'
  migration_root="$state_dir/migrations"
  if sudo test -L "$migration_root"; then die 'unsafe migration evidence root'; fi
  if ! sudo test -e "$migration_root"; then sudo install -d -m 0755 "$migration_root" || die 'failed to create migration evidence root'; fi
  assert_owned_dir "$migration_root" || die 'unsafe migration evidence root'
  migration_dir="$migration_root/$migration_id"
  if sudo test -L "$migration_dir"; then die 'unsafe migration evidence directory'; fi
  if ! sudo test -e "$migration_dir"; then sudo install -d -m 0755 "$migration_dir" || die 'failed to create migration evidence directory'; fi
  assert_owned_dir "$migration_dir" || die 'unsafe migration evidence directory'
  evidence_manifest="$migration_dir/manifest.tsv"
  if sudo test -e "$evidence_manifest" || sudo test -L "$evidence_manifest"; then
    assert_owned_regular "$evidence_manifest" 600 || die 'migration evidence manifest is unsafe'
    existing_sha="$(sha "$evidence_manifest")" || die 'failed to hash migration evidence manifest'
    test "$existing_sha" = "$contract_sha" || die 'migration evidence manifest differs'
  else
    atomic_copy "$contract" "$evidence_manifest" 600 "$contract_sha" ||
      die 'failed to preserve migration evidence manifest'
  fi
  events="$migration_dir/events.log"
  if sudo test -e "$events" || sudo test -L "$events"; then
    assert_owned_regular "$events" 600 || die 'migration event log is unsafe'
  else
    sudo install -o root -g root -m 0600 /dev/null "$events" ||
      die 'failed to create migration event log'
  fi
  pending_state="$migration_dir/pending.tsv"

  if ! "$pending" && test "$source_location" = absent; then
    printf 'result\talready-absent\n' | sudo tee -a "$events" >/dev/null ||
      die 'failed to record legacy cleanup no-op'
    sudo sync
    printf 'legacy Plane Radar state already absent\n'
    return
  fi

  if ! "$pending"; then
    atomic_copy "$contract" "$pending_state" 600 "$contract_sha" ||
      die 'failed to record exact legacy cleanup pending state'
    printf 'result\tpending\n' | sudo tee -a "$events" >/dev/null ||
      die 'failed to record pending legacy cleanup'
    sudo sync
    pending=true
  fi

  if test "$status" = registered; then
    run_dkms remove -m "$legacy_module" -v "$legacy_version" --all ||
      die 'failed to remove legacy DKMS registration'
  elif test "$status" != unregistered; then
    die 'legacy DKMS state cannot be resumed safely'
  fi

  if test "$source_location" = original; then
    assert_owned_dir "${root}/usr/src" || die 'legacy source parent is unsafe'
    if ! sudo test -e "$source_quarantine_root"; then
      sudo install -o root -g root -m 0700 -d "$source_quarantine_root" ||
        die 'failed to create legacy source quarantine'
    fi
    assert_owned_dir_mode "$source_quarantine_root" 700 ||
      die 'legacy source quarantine metadata drifted'
    sudo test ! -e "$source_quarantine_path" && sudo test ! -L "$source_quarantine_path" ||
      die 'legacy source quarantine destination already exists'
    sudo mv -- "$source_dir" "$source_quarantine_path" ||
      die 'failed to quarantine legacy source directory'
    source_location=quarantine
  fi

  for ((index = 0; index < ${#overlay_names[@]}; index++)); do
    if test "${overlay_locations[$index]}" = original; then
      overlay_path="${root}/boot/firmware/overlays/${overlay_names[$index]}"
      sudo mv -- "$overlay_path" "${overlay_quarantine_paths[$index]}" ||
        die 'failed to quarantine legacy overlay'
      overlay_locations[$index]=quarantine
    fi
  done

  sudo test ! -e "$source_dir" && sudo test ! -L "$source_dir" ||
    die 'legacy source remained active after quarantine'
  for overlay_path in "${overlay_names[@]}"; do
    sudo test ! -e "${root}/boot/firmware/overlays/$overlay_path" &&
      sudo test ! -L "${root}/boot/firmware/overlays/$overlay_path" ||
      die 'legacy overlay remained active after quarantine'
  done

  if sudo test -e "$source_quarantine_path"; then
    for source_entry in "${source_names[@]}"; do
      sudo rm -f -- "$source_quarantine_path/$source_entry" ||
        die 'failed to remove quarantined legacy source leaf'
    done
    sudo rmdir -- "$source_quarantine_path" ||
      die 'failed to remove quarantined legacy source directory'
  fi
  if sudo test -e "$source_quarantine_root"; then
    sudo rmdir -- "$source_quarantine_root" ||
      die 'failed to remove legacy source quarantine'
  fi
  for overlay_path in "${overlay_quarantine_paths[@]}"; do
    sudo rm -f -- "$overlay_path" ||
      die 'failed to remove quarantined legacy overlay'
  done
  printf 'result\tremoved\n' | sudo tee -a "$events" >/dev/null ||
    die 'failed to record completed legacy cleanup'
  sudo sync
  sudo rm -f -- "$pending_state" || die 'failed to clear legacy cleanup pending state'
  sudo sync
  printf 'removed exact legacy Plane Radar state\n'
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
  local inventory_file="$1"
  local source_backup="$2"
  local destination="$3"
  local desired_tree_present="$4"
  local version="$5"
  local running_release="$6"
  local desired_state first row kernel architecture kernel_state current_state

  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return
  [[ "$running_release" =~ ^[A-Za-z0-9._+-]+$ ]] || return
  assert_dkms_inventory_file "$inventory_file" || return
  desired_state="$(dkms_inventory_state "$inventory_file")" || return
  first="$(sudo sed -n '1p' "$inventory_file")"
  case "$desired_tree_present" in true|false) ;; *) return 1;; esac
  if sudo test -L "$destination"; then
    return 1
  elif sudo test -e "$destination"; then
    # The source-tree rollback authority is independent of whether the dkms
    # executable is presently available.  Do not let an absent dkms command
    # short-circuit restoration of the captured candidate bytes.
    if dkms_available; then
      current_state="$(validate_dkms_status "$version")" || return
    else
      current_state=absent
    fi
    case "$current_state" in
      registered) run_dkms remove -m hyperpixel2r-kms -v "$version" --all || return ;;
      absent|unregistered) ;;
      *) return 1 ;;
    esac
    remove_exact_tree "$destination" || return
  fi
  if "$desired_tree_present"; then
    assert_source_tree_shape "$source_backup" || return
    materialize_source_tree "$source_backup" "$destination" || return
    if dkms_available; then
      if test "$first" = schema_version=2; then
        case "$desired_state" in
          added)
            run_dkms add -m hyperpixel2r-kms -v "$version" || return
            while IFS= read -r row; do
              [[ "$row" =~ ^kernel=([A-Za-z0-9._+-]+)$'\t'(aarch64|arm64)$'\t'(built|installed)$ ]] ||
                return 1
              kernel="${BASH_REMATCH[1]}"
              architecture="${BASH_REMATCH[2]}"
              kernel_state="${BASH_REMATCH[3]}"
              run_dkms build -m hyperpixel2r-kms -v "$version" \
                -k "$kernel" -a "$architecture" || return
              if test "$kernel_state" = installed; then
                run_dkms install -m hyperpixel2r-kms -v "$version" \
                  -k "$kernel" -a "$architecture" || return
              fi
            done < <(sudo sed -n '4,$p' "$inventory_file")
            ;;
          absent|unregistered) ;;
          *) return 1 ;;
        esac
      else
        case "$desired_state" in
          registered|added)
            run_dkms add -m hyperpixel2r-kms -v "$version" || return
            ;;
          built)
            run_dkms add -m hyperpixel2r-kms -v "$version" || return
            run_dkms build -m hyperpixel2r-kms -v "$version" -k "$running_release" || return
            ;;
          installed)
            run_dkms add -m hyperpixel2r-kms -v "$version" || return
            run_dkms build -m hyperpixel2r-kms -v "$version" -k "$running_release" || return
            run_dkms install -m hyperpixel2r-kms -v "$version" -k "$running_release" || return
            ;;
          absent|unregistered) ;;
        esac
      fi
    elif test "$desired_state" != absent && test "$desired_state" != unregistered; then
      return 1
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
  module_existed=false
  overlay_existed=false
  created_dkms=false
  dkms_replaced=false
  prior_dkms_state=absent
  prior_dkms_snapshot=''
  prior_dkms_inventory_sha=''
  dkms_added=false
  published_tryboot=false
  published_state=false
  copy_was_created=false
  stage_complete=false
  accepted_bound=false
  accepted_prior_dkms_state=''
  resolved_path=''

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
          unregistered|registered|added|built|installed)
            restore_dkms_source_state "$prior_state_snapshot" "$prior_dkms_snapshot" \
              "$dkms_dir" true "$driver_version" "$release" || true
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

  prior_state_snapshot="$(private_file "$rollback_tmp" dkms-prior-state)" || die 'failed to create private DKMS state snapshot'
  if sudo test -L "$dkms_dir"; then
    die 'partial or unbound DKMS source tree'
  elif sudo test -e "$dkms_dir"; then
    assert_source_tree_shape "$dkms_dir" || die 'partial or unbound DKMS source tree'
    capture_dkms_inventory "$driver_version" "$prior_state_snapshot" "$rollback_tmp" ||
      die 'invalid DKMS inventory before source capture'
    prior_dkms_state="$(dkms_inventory_state "$prior_state_snapshot")" ||
      die 'invalid DKMS source state before source capture'
    case "$prior_dkms_state" in
      unregistered|added) ;;
      *) die 'invalid DKMS source state before source capture' ;;
    esac
    prior_dkms_snapshot="$rollback_tmp/prior-dkms"
    sudo install -d -m 0755 "$prior_dkms_snapshot" || die 'failed to create prior DKMS snapshot directory'
    assert_private_workspace "$rollback_tmp" || die 'private stage workspace changed while capturing DKMS source'
    for name in "${source_files[@]}"; do
      expected_sha="$(sha "$dkms_dir/$name")" || die 'failed to hash prior DKMS source leaf'
      atomic_copy "$dkms_dir/$name" "$prior_dkms_snapshot/$name" 644 "$expected_sha" || die 'failed to capture prior DKMS source leaf'
    done
    assert_source_tree_shape "$prior_dkms_snapshot" "$dkms_dir" || die 'failed to capture prior DKMS source tree'
  else
    write_empty_dkms_inventory absent "$prior_state_snapshot" ||
      die 'failed to capture absent prior DKMS state'
  fi
  assert_owned_regular "$prior_state_snapshot" 600 || die 'prior DKMS state snapshot ownership drifted'

  if sudo test -e "$accepted_state" || sudo test -L "$accepted_state"; then
    assert_accepted_state || die 'accepted driver receipt is unsafe'
    assert_accepted_transition || die 'accepted candidate journal is missing or unsafe'
    test "$(accepted_transition_value kind)" = new ||
      die 'accepted candidate journal has the wrong kind'
    test "$(accepted_transition_value phase)" = prepared ||
      die 'accepted candidate journal is not prepared'
    test "$(accepted_transition_value candidate_driver_version)" = "$driver_version" &&
      test "$(accepted_transition_value candidate_source_revision)" = "$revision" &&
      test "$(accepted_transition_value candidate_kernel_release)" = "$release" &&
      test "$(accepted_transition_value candidate_manifest_sha256)" = "$manifest_sha" &&
      test "$(accepted_transition_value candidate_module_file)" = "$module_file" &&
      test "$(accepted_transition_value candidate_module_sha256)" = "$module_sha" &&
      test "$(accepted_transition_value candidate_overlay_file)" = "$overlay_file" &&
      test "$(accepted_transition_value candidate_overlay_sha256)" = "$overlay_sha" ||
      die 'accepted candidate journal differs from incoming artifact'
    test "$(accepted_transition_value prior_normal_config_sha256)" = "$normal_sha" &&
      test "$(accepted_transition_value candidate_normal_config_sha256)" = \
        "$(sha "$candidate")" ||
      die 'accepted candidate journal differs from staged preconditions'
    accepted_prior_dkms_state="$(accepted_transition_value prior_dkms_status)"
    if test "$accepted_prior_dkms_state" != "$prior_dkms_state"; then
      case "$accepted_prior_dkms_state:$prior_dkms_state" in
        registered:added|registered:built|registered:installed) ;;
        *) die 'accepted candidate journal differs from staged preconditions' ;;
      esac
    fi
    accepted_bound=true
  else
    test ! -L "$accepted_transition" && test ! -e "$accepted_transition" ||
      die 'accepted candidate journal exists without an accepted receipt'
  fi

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
  prior_dkms_inventory_sha="$expected_sha"
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
  fixture_interrupt_after candidate-artifact-published
  if copy_if_absent_or_exact "$artifact_dir/$module_file" "$module_path" 644 "$module_sha"; then
    if "$copy_was_created"; then created_module=true
    else module_existed=true
    fi
  else
    die 'failed to install module from incoming artifact'
  fi
  fixture_interrupt_after candidate-module-installed
  if copy_if_absent_or_exact "$artifact_dir/$overlay_file" "$overlay_path" 644 "$overlay_sha" true; then
    if "$copy_was_created"; then created_overlay=true
    else overlay_existed=true
    fi
  else
    die 'failed to install overlay from incoming artifact'
  fi
  fixture_interrupt_after candidate-overlay-installed
  if sudo test -L "$dkms_dir"; then
    die 'existing DKMS source tree is unsafe'
  elif sudo test -e "$dkms_dir"; then
    if assert_source_tree_shape "$dkms_dir" "$artifact_dir/dkms-source" 2>/dev/null; then
      sudo depmod -a "$release" || die 'failed to refresh module resolution before DKMS reuse'
      resolved_path="$(resolved_module_path "$release" hyperpixel2r_kms)" ||
        die 'failed to resolve installed module before DKMS reuse'
      resolved_sha="$(module_leaf_sha "$resolved_path")" ||
        die 'failed to hash installed module before DKMS reuse'
      if test "$resolved_path" != "$module_path" ||
        test "$resolved_sha" != "$module_sha"; then
        case "$prior_dkms_state" in
          registered|added|built|installed)
            run_dkms remove -m hyperpixel2r-kms -v "$driver_version" --all ||
              die 'failed to remove mismatched DKMS registration'
            dkms_replaced=true
            ;;
          *) die 'mismatched resolved module is not bound to a removable DKMS registration' ;;
        esac
      fi
    else
      test "$prior_dkms_state" != absent || die 'missing prior DKMS capture'
      assert_source_tree_shape "$dkms_dir" "$prior_dkms_snapshot" || die 'DKMS source changed after capture'
      case "$prior_dkms_state" in
        registered|added|built|installed)
          run_dkms remove -m hyperpixel2r-kms -v "$driver_version" --all ||
            die 'failed to remove prior DKMS registration'
          ;;
      esac
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
  sudo depmod -a "$release" || die 'failed to refresh candidate module resolution'
  test "$(resolved_module_path "$release" hyperpixel2r_kms)" = "$module_path" &&
    test "$(module_leaf_sha "$module_path")" = "$module_sha" ||
    die 'candidate module is not selected by running-kernel resolution'
  fixture_interrupt_after candidate-dkms-activated
  test "$(sha "$normal_config")" = "$normal_sha" || die 'normal boot config changed while staging tryboot candidate'
  candidate_snapshot="$(privileged_snapshot "$candidate" "$rollback_tmp" candidate)" || die 'failed to capture candidate config'
  candidate_sha="$(sha "$candidate_snapshot")" || die 'failed to hash candidate config snapshot'
  atomic_copy "$candidate_snapshot" "$tryboot_config" 644 "$candidate_sha" true || die 'failed to publish tryboot config'
  published_tryboot=true
  fixture_interrupt_after candidate-tryboot-published
  test "$(sha "$normal_config")" = "$normal_sha" || die 'normal boot config changed while staging tryboot candidate'
  state_tmp="$(private_file "$rollback_tmp" state)" || die 'failed to create private tryboot state'
  {
    printf 'schema_version=3\n'
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
    printf 'module_existed=%s\n' "$module_existed"
    printf 'overlay_existed=%s\n' "$overlay_existed"
    printf 'prior_dkms_inventory_sha256=%s\n' "$prior_dkms_inventory_sha"
  } | sudo tee "$state_tmp" >/dev/null || die 'failed to write private tryboot state'
  assert_owned_regular "$state_tmp" 600 || die 'private tryboot state ownership drifted'
  state_snapshot="$(privileged_snapshot "$state_tmp" "$rollback_tmp" state)" || die 'failed to capture tryboot state'
  expected_sha="$(sha "$state_snapshot")" || die 'failed to hash tryboot state snapshot'
  atomic_copy "$state_snapshot" "$state_file" 600 "$expected_sha" || die 'failed to publish tryboot state'
  published_state=true
  fixture_interrupt_after candidate-tryboot-state-published
  if "$accepted_bound"; then
    set_accepted_transition_phase prepared staged '' "$prior_dkms_inventory_sha" ||
      die 'failed to mark accepted candidate staged'
    fixture_interrupt_after candidate-staged-published
  fi
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
  local boot_file="${5:-false}"
  local temporary snapshot expected_sha
  sudo test ! -L "$directory" && sudo test -d "$directory" || return
  assert_private_workspace "$workspace" || return
  snapshot="$(privileged_snapshot "$source" "$workspace" prepare)" || return
  expected_sha="$(sha "$snapshot")" || { sudo rm -f -- "$snapshot" || true; return 1; }
  temporary="$(sudo mktemp "$directory/.hp2r-prepare.XXXXXX")" || { sudo rm -f -- "$snapshot" || true; return 1; }
  atomic_copy "$snapshot" "$temporary" "$mode" "$expected_sha" "$boot_file" || {
    sudo rm -f -- "$snapshot" "$temporary" || true
    return 1
  }
  sudo rm -f -- "$snapshot" || { sudo rm -f -- "$temporary" || true; return 1; }
  if test "$boot_file" = true; then
    assert_owned_regular "$temporary" boot || { sudo rm -f -- "$temporary" || true; return 1; }
  else
    assert_owned_regular "$temporary" "$mode" || { sudo rm -f -- "$temporary" || true; return 1; }
  fi
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
  normal_tmp="$(prepare_copy "$normal_candidate" "$(dirname "$normal_config")" 644 "$workspace" true)" || die 'failed to prepare normal config publication'
  if test "$(state_value tryboot_existed)" = true; then prior_tmp="$(prepare_copy "$artifact_dir/prior-tryboot.txt" "$(dirname "$tryboot_config")" 644 "$workspace" true)" || die 'failed to prepare prior tryboot config'; else prior_tmp=''; fi
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

rollback_value() {
  local key="$1"

  assert_owned_regular "$rollback_state" 600 || return
  sudo awk -F= -v wanted="$key" '$1 == wanted { print $2 }' "$rollback_state"
}

assert_rollback_module_state() {
  local module_present=false hold_present=false

  if sudo test -L "$rb_module_path" || sudo test -L "$rb_module_hold"; then
    echo 'rollback module or hold is a symlink' >&2
    return 1
  fi
  if sudo test -e "$rb_module_path"; then
    assert_owned_regular "$rb_module_path" 644 || return
    test "$(sha "$rb_module_path")" = "$rb_module_sha" || {
      echo 'rollback module checksum drifted' >&2
      return 1
    }
    module_present=true
  fi
  if sudo test -e "$rb_module_hold"; then
    assert_owned_regular "$rb_module_hold" 644 || return
    test "$(sha "$rb_module_hold")" = "$rb_module_sha" || {
      echo 'rollback module hold checksum drifted' >&2
      return 1
    }
    hold_present=true
  fi
  if test "$rb_mode" = compensate; then
    if test "$rb_phase" = depmod-verified; then
      test "$module_present:$hold_present" = true:false || {
        echo 'verified compensation module state is not restored' >&2
        return 1
      }
    else
      case "$module_present:$hold_present" in
        true:false|false:true) ;;
        *) echo 'compensation module and hold state is ambiguous' >&2; return 1 ;;
      esac
    fi
    return 0
  fi
  if test "$rb_module_existed" = true; then
    case "$rb_phase:$module_present:$hold_present" in
      prepared:true:false|prepared:false:true) ;;
      candidate-held:false:true) ;;
      prior-restored:false:true|prior-restored:true:false) ;;
      boot-restored:true:false|depmod-verified:true:false) ;;
      *) echo 'forward shared-module rollback state is ambiguous' >&2; return 1 ;;
    esac
  else
    case "$rb_phase:$module_present:$hold_present" in
      prepared:true:false|prepared:false:true) ;;
      candidate-held:false:true) ;;
      prior-restored:false:true|prior-restored:false:false) ;;
      boot-restored:false:false|depmod-verified:false:false) ;;
      *) echo 'forward rollback module and hold state is ambiguous' >&2; return 1 ;;
    esac
  fi
  return 0
}

boot_file_matches_sha() {
  local path="$1"
  local expected_sha="$2"
  local kind="$3"
  local mode

  sudo test ! -L "$path" && sudo test -f "$path" || return
  test "$(sudo stat -c '%U:%G' "$path")" = root:root || return
  mode="$(sudo stat -c '%a' "$path")" || return
  case "$kind:$mode" in
    tryboot:600|tryboot:644|tryboot:755|overlay:644|overlay:755) ;;
    *) return 1 ;;
  esac
  test "$(sha "$path")" = "$expected_sha"
}

rollback_tryboot_matches_candidate() {
  boot_file_matches_sha "$tryboot_config" "$rb_candidate_tryboot_sha" tryboot
}

rollback_tryboot_matches_prior() {
  if test "$rb_tryboot_existed" = true; then
    boot_file_matches_sha "$tryboot_config" \
      "$(sha "$rb_artifact/prior-tryboot.txt")" tryboot
  else
    sudo test ! -L "$tryboot_config" && sudo test ! -e "$tryboot_config"
  fi
}

rollback_overlay_matches_candidate() {
  boot_file_matches_sha "$rb_overlay_path" "$rb_overlay_sha" overlay
}

rollback_overlay_matches_prior() {
  if test "$rb_overlay_existed" = true; then
    rollback_overlay_matches_candidate
  else
    sudo test ! -L "$rb_overlay_path" && sudo test ! -e "$rb_overlay_path"
  fi
}

assert_rollback_boot_state() {
  local tryboot_candidate=false tryboot_prior=false
  local overlay_candidate=false overlay_prior=false

  if rollback_tryboot_matches_candidate; then tryboot_candidate=true; fi
  if rollback_tryboot_matches_prior; then tryboot_prior=true; fi
  if rollback_overlay_matches_candidate; then overlay_candidate=true; fi
  if rollback_overlay_matches_prior; then overlay_prior=true; fi

  if test "$rb_mode" = compensate; then
    if test "$rb_phase" = depmod-verified; then
      test "$tryboot_candidate:$overlay_candidate" = true:true || {
        echo 'verified compensation boot state is not the exact candidate' >&2
        return 1
      }
    else
      test "$tryboot_candidate" = true || test "$tryboot_prior" = true || {
        echo 'compensation tryboot state is neither candidate nor prior' >&2
        return 1
      }
      test "$overlay_candidate" = true || test "$overlay_prior" = true || {
        echo 'compensation overlay state is neither candidate nor prior' >&2
        return 1
      }
    fi
    return 0
  fi

  case "$rb_phase" in
    prepared|candidate-held)
      test "$tryboot_candidate:$overlay_candidate" = true:true || {
        printf 'forward rollback candidate boot state drifted: tryboot=%s overlay=%s\n' \
          "$tryboot_candidate" "$overlay_candidate" >&2
        return 1
      }
      ;;
    prior-restored)
      test "$tryboot_candidate" = true || test "$tryboot_prior" = true || {
        echo 'forward rollback tryboot state drifted during restoration' >&2
        return 1
      }
      test "$overlay_candidate" = true || test "$overlay_prior" = true || {
        echo 'forward rollback overlay state drifted during restoration' >&2
        return 1
      }
      ;;
    boot-restored|depmod-verified)
      test "$tryboot_prior:$overlay_prior" = true:true || {
        echo 'forward rollback restored boot state drifted' >&2
        return 1
      }
      ;;
    *) return 1 ;;
  esac
}

assert_rollback_journal() {
  local key count schema mode phase version revision release artifact manifest
  local module_file module_sha overlay_file overlay_sha transaction_sha
  local candidate_inventory_sha prior_inventory_sha candidate_tryboot_sha
  local finalizing=false auxiliaries_optional=false

  assert_owned_regular "$rollback_state" 600 || return
  schema="$(rollback_value schema_version)"
  test "$schema" = 1 || return
  test "$(sudo awk 'END { print NR }' "$rollback_state")" = "${#rollback_keys[@]}" ||
    return
  sudo awk -F= 'NF != 2 || $1 == "" || $2 == "" { exit 1 }' "$rollback_state" ||
    return
  for key in "${rollback_keys[@]}"; do
    count="$(sudo awk -F= -v wanted="$key" '$1 == wanted { count++ } END { print count + 0 }' "$rollback_state")"
    test "$count" = 1 || return
  done
  mode="$(rollback_value mode)"
  phase="$(rollback_value phase)"
  case "$mode" in rollback|compensate) ;; *) return 1 ;; esac
  case "$phase" in
    prepared|candidate-held|prior-restored|boot-restored|depmod-verified) ;;
    *) return 1 ;;
  esac
  version="$(rollback_value driver_version)"
  revision="$(rollback_value source_revision)"
  release="$(rollback_value kernel_release)"
  module_file="$(rollback_value module_file)"
  module_sha="$(rollback_value module_sha256)"
  overlay_file="$(rollback_value overlay_file)"
  overlay_sha="$(rollback_value overlay_sha256)"
  transaction_sha="$(rollback_value transaction_sha256)"
  candidate_inventory_sha="$(rollback_value candidate_dkms_inventory_sha256)"
  prior_inventory_sha="$(rollback_value prior_dkms_inventory_sha256)"
  candidate_tryboot_sha="$(rollback_value candidate_tryboot_sha256)"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return
  [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || return
  [[ "$release" =~ ^[A-Za-z0-9._+-]+$ ]] || return
  test "$module_file" = hyperpixel2r_kms.ko || return
  test "$overlay_file" = "hyperpixel2r-kms-${revision:0:12}.dtbo" || return
  for key in \
    "$module_sha" "$overlay_sha" "$transaction_sha" \
    "$candidate_inventory_sha" "$prior_inventory_sha" "$candidate_tryboot_sha" \
    "$(rollback_value manifest_sha256)"; do
    [[ "$key" =~ ^[0-9a-f]{64}$ ]] || return
  done
  case "$(rollback_value tryboot_existed):$(rollback_value module_existed):$(rollback_value overlay_existed)" in
    true:true:true|true:true:false|true:false:true|true:false:false|false:true:true|false:true:false|false:false:true|false:false:false) ;;
    *) return 1 ;;
  esac
  artifact="$artifact_root/$version/$revision/$release"
  if test "$(rollback_value tryboot_existed)" = true; then
    assert_artifact_tree "$artifact" true || return
  else
    assert_artifact_tree "$artifact" false || return
  fi
  manifest="$artifact/manifest.txt"
  test "$(sha "$manifest")" = "$(rollback_value manifest_sha256)" || return
  test "$(manifest_value "$manifest" driver_version)" = "$version" || return
  test "$(manifest_value "$manifest" source_revision)" = "$revision" || return
  test "$(manifest_value "$manifest" kernel_release)" = "$release" || return
  test "$(manifest_value "$manifest" module_file)" = "$module_file" || return
  test "$(manifest_value "$manifest" module_sha256)" = "$module_sha" || return
  test "$(manifest_value "$manifest" overlay_file)" = "$overlay_file" || return
  test "$(manifest_value "$manifest" overlay_sha256)" = "$overlay_sha" || return
  test "$(sha "$artifact/dkms-prior-state")" = "$prior_inventory_sha" || return

  if sudo test -L "$state_file"; then
    return 1
  elif sudo test -e "$state_file"; then
    assert_state_schema || return
    test "$(sha "$state_file")" = "$transaction_sha" || return
    test "$(state_value driver_version)" = "$version" || return
    test "$(state_value source_revision)" = "$revision" || return
    test "$(state_value kernel_release)" = "$release" || return
    test "$(state_value module_sha256)" = "$module_sha" || return
    test "$(state_value overlay_sha256)" = "$overlay_sha" || return
  else
    test "$mode:$phase" = rollback:depmod-verified || return
    finalizing=true
  fi
  if test "$mode:$phase" = compensate:depmod-verified; then
    auxiliaries_optional=true
  fi
  rb_mode="$mode"
  rb_phase="$phase"
  rb_module_existed="$(rollback_value module_existed)"
  rb_module_path="${root}/lib/modules/$release/extra/$module_file"
  rb_module_hold="${rb_module_path}.hp2r-rollback-hold"
  rb_module_sha="$module_sha"
  rb_artifact="$artifact"
  rb_candidate_tryboot_sha="$candidate_tryboot_sha"
  rb_tryboot_existed="$(rollback_value tryboot_existed)"
  rb_overlay_existed="$(rollback_value overlay_existed)"
  rb_overlay_path="${root}/boot/firmware/overlays/$overlay_file"
  rb_overlay_sha="$overlay_sha"
  assert_rollback_module_state || return

  if "$finalizing" || "$auxiliaries_optional"; then
    if sudo test -L "$rollback_candidate_inventory" ||
      sudo test -L "$rollback_candidate_tryboot"; then
      return 1
    fi
    if sudo test -e "$rollback_candidate_inventory"; then
      assert_owned_regular "$rollback_candidate_inventory" 600 || return
      assert_dkms_inventory_file "$rollback_candidate_inventory" || return
      test "$(sha "$rollback_candidate_inventory")" = "$candidate_inventory_sha" || return
    fi
    if sudo test -e "$rollback_candidate_tryboot"; then
      assert_owned_regular "$rollback_candidate_tryboot" 600 || return
      test "$(sha "$rollback_candidate_tryboot")" = "$candidate_tryboot_sha" || return
    fi
  else
    assert_owned_regular "$rollback_candidate_inventory" 600 || return
    assert_dkms_inventory_file "$rollback_candidate_inventory" || return
    test "$(sha "$rollback_candidate_inventory")" = "$candidate_inventory_sha" || return
    assert_owned_regular "$rollback_candidate_tryboot" 600 || return
    test "$(sha "$rollback_candidate_tryboot")" = "$candidate_tryboot_sha" || return
  fi
  assert_rollback_boot_state
}

write_rollback_journal() {
  local mode="$1"
  local phase="$2"
  local temporary journal_sha

  case "$mode" in rollback|compensate) ;; *) return 1 ;; esac
  case "$phase" in
    prepared|candidate-held|prior-restored|boot-restored|depmod-verified) ;;
    *) return 1 ;;
  esac
  temporary="$(private_file "$rb_workspace" rollback-state)" || return
  {
    printf 'schema_version=1\n'
    printf 'mode=%s\n' "$mode"
    printf 'phase=%s\n' "$phase"
    printf 'transaction_sha256=%s\n' "$rb_transaction_sha"
    printf 'driver_version=%s\n' "$rb_version"
    printf 'source_revision=%s\n' "$rb_revision"
    printf 'kernel_release=%s\n' "$rb_release"
    printf 'manifest_sha256=%s\n' "$rb_manifest_sha"
    printf 'module_file=%s\n' "$rb_module_file"
    printf 'module_sha256=%s\n' "$rb_module_sha"
    printf 'overlay_file=%s\n' "$rb_overlay_file"
    printf 'overlay_sha256=%s\n' "$rb_overlay_sha"
    printf 'candidate_dkms_inventory_sha256=%s\n' "$rb_candidate_inventory_sha"
    printf 'prior_dkms_inventory_sha256=%s\n' "$rb_prior_inventory_sha"
    printf 'candidate_tryboot_sha256=%s\n' "$rb_candidate_tryboot_sha"
    printf 'tryboot_existed=%s\n' "$rb_tryboot_existed"
    printf 'module_existed=%s\n' "$rb_module_existed"
    printf 'overlay_existed=%s\n' "$rb_overlay_existed"
  } | sudo tee "$temporary" >/dev/null || return
  assert_owned_regular "$temporary" 600 || return
  journal_sha="$(sha "$temporary")" || return
  atomic_copy "$temporary" "$rollback_state" 600 "$journal_sha" || return
  sudo sync
  assert_rollback_journal
}

load_rollback_journal() {
  assert_rollback_journal || return
  rb_mode="$(rollback_value mode)"
  rb_phase="$(rollback_value phase)"
  rb_transaction_sha="$(rollback_value transaction_sha256)"
  rb_version="$(rollback_value driver_version)"
  rb_revision="$(rollback_value source_revision)"
  rb_release="$(rollback_value kernel_release)"
  rb_manifest_sha="$(rollback_value manifest_sha256)"
  rb_module_file="$(rollback_value module_file)"
  rb_module_sha="$(rollback_value module_sha256)"
  rb_overlay_file="$(rollback_value overlay_file)"
  rb_overlay_sha="$(rollback_value overlay_sha256)"
  rb_candidate_inventory_sha="$(rollback_value candidate_dkms_inventory_sha256)"
  rb_prior_inventory_sha="$(rollback_value prior_dkms_inventory_sha256)"
  rb_candidate_tryboot_sha="$(rollback_value candidate_tryboot_sha256)"
  rb_tryboot_existed="$(rollback_value tryboot_existed)"
  rb_module_existed="$(rollback_value module_existed)"
  rb_overlay_existed="$(rollback_value overlay_existed)"
  rb_artifact="$artifact_root/$rb_version/$rb_revision/$rb_release"
  rb_module_path="${root}/lib/modules/$rb_release/extra/$rb_module_file"
  rb_module_hold="${rb_module_path}.hp2r-rollback-hold"
  rb_overlay_path="${root}/boot/firmware/overlays/$rb_overlay_file"
  rb_dkms_dir="$dkms_root/hyperpixel2r-kms-$rb_version"
}

assert_inventory_restored() {
  local desired="$1"
  local source="$2"
  local tree_present="$3"
  local temporary first desired_state current_state

  desired_state="$(dkms_inventory_state "$desired")" || return
  if "$tree_present"; then
    assert_source_tree_shape "$rb_dkms_dir" "$source" || return
  else
    sudo test ! -L "$rb_dkms_dir" && sudo test ! -e "$rb_dkms_dir" || return
  fi
  if test "$desired_state" = absent; then
    current_state="$(validate_dkms_status "$rb_version")" || return
    case "$current_state" in absent|unregistered) return 0 ;; *) return 1 ;; esac
  fi
  first="$(sudo sed -n '1p' "$desired")"
  if test "$first" = schema_version=2; then
    temporary="$(private_file "$rb_workspace" inventory-check)" || return
    capture_dkms_inventory "$rb_version" "$temporary" "$rb_workspace" || return
    sudo cmp -s -- "$desired" "$temporary"
  else
    current_state="$(validate_dkms_status "$rb_version")" || return
    case "$desired_state:$current_state" in
      absent:absent|unregistered:unregistered|registered:registered|added:registered|built:registered|installed:registered) ;;
      *) return 1 ;;
    esac
  fi
}

restore_prior_rollback_state() {
  local prior_state tree_present=false

  prior_state="$(dkms_prior_state "$rb_artifact")" || return
  if test "$prior_state" != absent; then tree_present=true; fi
  if assert_inventory_restored "$rb_artifact/dkms-prior-state" \
    "$rb_artifact/prior-dkms" "$tree_present" 2>/dev/null; then
    return
  fi
  restore_dkms_source_state "$rb_artifact/dkms-prior-state" \
    "$rb_artifact/prior-dkms" "$rb_dkms_dir" "$tree_present" \
    "$rb_version" "$rb_release" || {
      echo 'prior DKMS restore operation failed' >&2
      return 1
    }
  assert_inventory_restored "$rb_artifact/dkms-prior-state" \
    "$rb_artifact/prior-dkms" "$tree_present" || {
      echo 'prior DKMS state did not match its inventory after restore' >&2
      return 1
    }
}

restore_candidate_rollback_state() {
  if assert_inventory_restored "$rollback_candidate_inventory" \
    "$rb_artifact/dkms-source" true 2>/dev/null; then
    return
  fi
  restore_dkms_source_state "$rollback_candidate_inventory" \
    "$rb_artifact/dkms-source" "$rb_dkms_dir" true \
    "$rb_version" "$rb_release" || return
  assert_inventory_restored "$rollback_candidate_inventory" \
    "$rb_artifact/dkms-source" true
}

verify_prior_module_resolution() {
  local path

  if sudo awk -F '\t' -v wanted="$rb_release" '
    $1 == "kernel=" wanted && ($2 == "aarch64" || $2 == "arm64") && $3 == "installed" {
      found=1
    }
    END { exit(found ? 0 : 1) }
  ' "$rb_artifact/dkms-prior-state" 2>/dev/null; then
    path="$(sudo modinfo -k "$rb_release" -n hyperpixel2r_kms)" || return
    case "$path" in
      "${root}/lib/modules/$rb_release/updates/dkms/hyperpixel2r_kms.ko"|"${root}/lib/modules/$rb_release/updates/dkms/hyperpixel2r_kms.ko.xz"|"${root}/lib/modules/$rb_release/updates/dkms/hyperpixel2r_kms.ko.zst"|"${root}/lib/modules/$rb_release/updates/dkms/hyperpixel2r_kms.ko.gz") ;;
      *) return 1 ;;
    esac
    assert_owned_regular "$path" 644
  elif test "$rb_module_existed" = true; then
    test "$(resolved_module_sha "$rb_release" hyperpixel2r_kms)" = "$rb_module_sha"
  else
    sudo test ! -L "$rb_module_path" && sudo test ! -e "$rb_module_path"
  fi
}

compensate_rollback() {
  local candidate_path_state current_inventory

  rb_mode=compensate
  if test "$rb_phase" != depmod-verified; then
    write_rollback_journal compensate "$rb_phase" || {
      echo 'failed to publish durable compensation mode' >&2
      return 1
    }
    fixture_interrupt_after rollback-compensate-mode-published
    restore_candidate_rollback_state || {
      echo 'failed to restore candidate DKMS state during compensation' >&2
      return 1
    }
    fixture_interrupt_after rollback-compensate-dkms-restored

    candidate_path_state=absent
    if sudo test -L "$rb_module_path" || sudo test -L "$rb_module_hold"; then return 1; fi
    if sudo test -e "$rb_module_path"; then
      assert_owned_regular "$rb_module_path" 644 || return
      test "$(sha "$rb_module_path")" = "$rb_module_sha" || return
      candidate_path_state=module
    fi
    if sudo test -e "$rb_module_hold"; then
      test "$candidate_path_state" = absent || return
      assert_owned_regular "$rb_module_hold" 644 || return
      test "$(sha "$rb_module_hold")" = "$rb_module_sha" || return
      sudo mv -f -- "$rb_module_hold" "$rb_module_path" || return
      candidate_path_state=module
    fi
    if test "$candidate_path_state" = absent; then
      atomic_copy "$rb_artifact/$rb_module_file" "$rb_module_path" 644 "$rb_module_sha" ||
        { echo 'failed to restore candidate module during compensation' >&2; return 1; }
    fi
    if test "$rb_overlay_existed" = false; then
      atomic_copy "$rb_artifact/$rb_overlay_file" "$rb_overlay_path" 644 \
        "$rb_overlay_sha" true || {
        echo 'failed to restore candidate overlay during compensation' >&2
        return 1
      }
    fi
    fixture_interrupt_after rollback-compensate-module-restored
    atomic_copy "$rollback_candidate_tryboot" "$tryboot_config" 644 \
      "$rb_candidate_tryboot_sha" true || {
      echo 'failed to restore candidate tryboot during compensation' >&2
      return 1
    }
    fixture_interrupt_after rollback-compensate-boot-restored
    sudo depmod -a "$rb_release" || {
      echo 'failed to refresh candidate resolution during compensation' >&2
      return 1
    }
    test "$(resolved_module_sha "$rb_release" hyperpixel2r_kms)" = "$rb_module_sha" ||
      { echo 'candidate resolution is not exact after compensation' >&2; return 1; }
    sudo sync
    rb_phase=depmod-verified
    write_rollback_journal compensate "$rb_phase" || {
      echo 'failed to publish verified durable compensation state' >&2
      return 1
    }
    fixture_interrupt_after rollback-compensate-depmod-verified
  else
    assert_source_tree_shape "$rb_dkms_dir" "$rb_artifact/dkms-source" ||
      return
    test "$(sha "$tryboot_config")" = "$rb_candidate_tryboot_sha" || return
    test "$(resolved_module_sha "$rb_release" hyperpixel2r_kms)" = "$rb_module_sha" ||
      return
  fi
  assert_source_tree_shape "$rb_dkms_dir" "$rb_artifact/dkms-source" || return
  current_inventory="$(private_file "$rb_workspace" compensation-live-inventory)" ||
    return
  capture_dkms_inventory "$rb_version" "$current_inventory" "$rb_workspace" ||
    return
  test "$(sha "$current_inventory")" = "$rb_candidate_inventory_sha" || {
    echo 'live candidate DKMS inventory drifted before compensation cleanup' >&2
    return 1
  }
  assert_rollback_boot_state || return
  sudo rm -f -- "$rollback_candidate_tryboot" "$rollback_candidate_inventory" ||
    { echo 'failed to remove durable compensation auxiliaries' >&2; return 1; }
  sudo sync
  fixture_interrupt_after rollback-compensate-aux-removed
  sudo rm -f -- "$rollback_state" ||
    { echo 'failed to clear durable compensation journal' >&2; return 1; }
  sudo sync
}

rollback() {
  local transaction inventory_tmp candidate_tmp transaction_state

  rb_workspace=''
  rb_mode=''
  rb_phase=''
  rb_transaction_sha=''
  rb_version=''
  rb_revision=''
  rb_release=''
  rb_manifest_sha=''
  rb_module_file=''
  rb_module_sha=''
  rb_overlay_file=''
  rb_overlay_sha=''
  rb_candidate_inventory_sha=''
  rb_prior_inventory_sha=''
  rb_candidate_tryboot_sha=''
  rb_tryboot_existed=false
  rb_module_existed=false
  rb_overlay_existed=false
  rb_artifact=''
  rb_module_path=''
  rb_module_hold=''
  rb_overlay_path=''
  rb_dkms_dir=''
  rb_complete=false
  rb_finalizing=false
  rb_loaded=false

  cleanup_durable_rollback() {
    local status=$?
    trap - EXIT
    if test "$status" -ne 0 && "$rb_loaded" && ! "$rb_complete" && ! "$rb_finalizing" &&
      sudo test ! -L "$rollback_state" && sudo test -e "$rollback_state"; then
      compensate_rollback ||
        echo 'durable rollback compensation remains pending' >&2
    fi
    if ! remove_transaction_workspace "$rb_workspace" 2>/dev/null; then
      remove_transaction_workspace "$rb_workspace" 2>/dev/null || true
    fi
    rb_workspace=''
    exit "$status"
  }

  rb_workspace="$(new_transaction_workspace)" ||
    die 'failed to create durable rollback workspace'
  trap cleanup_durable_rollback EXIT

  if sudo test -L "$rollback_state"; then
    die 'rollback journal is unsafe'
  elif sudo test -e "$rollback_state"; then
    load_rollback_journal || die 'rollback journal is unsafe'
    rb_loaded=true
  else
    test ! -L "$rollback_candidate_inventory" &&
      test ! -e "$rollback_candidate_inventory" &&
      test ! -L "$rollback_candidate_tryboot" &&
      test ! -e "$rollback_candidate_tryboot" ||
      die 'orphan durable rollback state exists'
    transaction="$(assert_transaction_state)" ||
      die 'candidate transaction is not safe to roll back'
    IFS=$'\t' read -r rb_version rb_revision rb_release rb_artifact <<<"$transaction"
    rb_transaction_sha="$(sha "$state_file")" ||
      die 'failed to hash active transaction'
    rb_manifest_sha="$(sha "$rb_artifact/manifest.txt")" ||
      die 'failed to hash transaction manifest'
    rb_module_file="$(state_value module_file)"
    rb_module_sha="$(state_value module_sha256)"
    rb_overlay_file="$(state_value overlay_file)"
    rb_overlay_sha="$(state_value overlay_sha256)"
    rb_tryboot_existed="$(state_value tryboot_existed)"
    if test "$(state_value schema_version)" = 2 ||
      test "$(state_value schema_version)" = 3; then
      rb_module_existed="$(state_value module_existed)"
      rb_overlay_existed="$(state_value overlay_existed)"
    fi
    rb_prior_inventory_sha="$(sha "$rb_artifact/dkms-prior-state")" ||
      die 'failed to hash prior DKMS inventory'
    rb_module_path="${root}/lib/modules/$rb_release/extra/$rb_module_file"
    rb_module_hold="${rb_module_path}.hp2r-rollback-hold"
    rb_overlay_path="${root}/boot/firmware/overlays/$rb_overlay_file"
    rb_dkms_dir="$dkms_root/hyperpixel2r-kms-$rb_version"
    test ! -L "$rb_module_hold" && test ! -e "$rb_module_hold" ||
      die 'candidate module rollback hold already exists'
    assert_source_tree_shape "$rb_dkms_dir" "$rb_artifact/dkms-source" ||
      die 'candidate DKMS source is not bound to the active transaction'
    inventory_tmp="$(private_file "$rb_workspace" candidate-inventory)" ||
      die 'failed to allocate durable candidate inventory'
    capture_dkms_inventory "$rb_version" "$inventory_tmp" "$rb_workspace" ||
      die 'invalid candidate DKMS inventory'
    case "$(dkms_inventory_state "$inventory_tmp")" in
      absent|unregistered|added) ;;
      *) die 'invalid candidate DKMS status' ;;
    esac
    rb_candidate_inventory_sha="$(sha "$inventory_tmp")" ||
      die 'failed to hash candidate DKMS inventory'
    atomic_copy "$inventory_tmp" "$rollback_candidate_inventory" 600 \
      "$rb_candidate_inventory_sha" ||
      die 'failed to publish durable candidate DKMS inventory'
    candidate_tmp="$(privileged_snapshot "$tryboot_config" "$rb_workspace" rollback-tryboot)" ||
      die 'failed to capture candidate tryboot config'
    rb_candidate_tryboot_sha="$(sha "$candidate_tmp")" ||
      die 'failed to hash candidate tryboot config'
    atomic_copy "$candidate_tmp" "$rollback_candidate_tryboot" 600 \
      "$rb_candidate_tryboot_sha" ||
      die 'failed to publish durable candidate tryboot config'
    rb_mode=rollback
    rb_phase=prepared
    write_rollback_journal rollback prepared ||
      die 'failed to publish durable rollback journal'
    rb_loaded=true
    fixture_interrupt_after rollback-journal-published
  fi

  if test "$rb_mode" = compensate; then
    compensate_rollback ||
      die 'failed to resume durable rollback compensation'
    if ! remove_transaction_workspace "$rb_workspace"; then
      remove_transaction_workspace "$rb_workspace" || return 1
    fi
    rb_workspace=''
    rb_complete=true
    trap - EXIT
    printf 'resumed prior rollback compensation; retrying rollback\n' >&2
    rollback
    return
  fi

  if test "$rb_phase" = prepared; then
    if sudo test -L "$rb_module_path" || sudo test -L "$rb_module_hold"; then
      die 'candidate module hold state is unsafe'
    elif sudo test -e "$rb_module_path" && sudo test -e "$rb_module_hold"; then
      die 'candidate module and rollback hold coexist'
    elif sudo test -e "$rb_module_path"; then
      assert_owned_regular "$rb_module_path" 644 ||
        die 'candidate module is unsafe before hold'
      test "$(sha "$rb_module_path")" = "$rb_module_sha" ||
        die 'candidate module drifted before hold'
      sudo mv -f -- "$rb_module_path" "$rb_module_hold" ||
        die 'failed to hold candidate module'
    elif sudo test -e "$rb_module_hold"; then
      assert_owned_regular "$rb_module_hold" 644 ||
        die 'candidate module hold is unsafe'
      test "$(sha "$rb_module_hold")" = "$rb_module_sha" ||
        die 'candidate module hold drifted'
    else
      die 'candidate module and rollback hold are both absent'
    fi
    sudo depmod -a "$rb_release" ||
      die 'failed to refresh resolution after candidate hold'
    sudo sync
    fixture_interrupt_after rollback-candidate-held-unpublished
    rb_phase=candidate-held
    write_rollback_journal rollback "$rb_phase" ||
      die 'failed to publish candidate-held rollback phase'
    fixture_interrupt_after rollback-candidate-held
  fi

  if test "$rb_phase" = candidate-held; then
    restore_prior_rollback_state ||
      die 'failed to restore prior DKMS state'
    sudo sync
    fixture_interrupt_after rollback-prior-restored-unpublished
    rb_phase=prior-restored
    write_rollback_journal rollback "$rb_phase" ||
      die 'failed to publish prior-restored rollback phase'
    fixture_interrupt_after rollback-prior-restored
  fi

  if test "$rb_phase" = prior-restored; then
    if test "$rb_tryboot_existed" = true; then
      atomic_copy "$rb_artifact/prior-tryboot.txt" "$tryboot_config" 644 \
        "$(state_value prior_tryboot_sha256)" true ||
        die 'failed to restore prior tryboot config'
    else
      sudo rm -f -- "$tryboot_config" ||
        die 'failed to remove candidate tryboot config'
    fi
    if test "$rb_overlay_existed" = false; then
      sudo rm -f -- "$rb_overlay_path" ||
        die 'failed to remove candidate overlay'
    fi
    if sudo test -L "$rb_module_hold" || sudo test -L "$rb_module_path"; then
      die 'candidate module finalization state is unsafe'
    elif sudo test -e "$rb_module_hold"; then
      assert_owned_regular "$rb_module_hold" 644 ||
        die 'candidate module hold is unsafe before finalization'
      test "$(sha "$rb_module_hold")" = "$rb_module_sha" ||
        die 'candidate module hold drifted before finalization'
      if test "$rb_module_existed" = true; then
        sudo mv -f -- "$rb_module_hold" "$rb_module_path" ||
          die 'failed to restore preexisting candidate module'
      else
        sudo rm -f -- "$rb_module_hold" ||
          die 'failed to remove held candidate module'
      fi
    elif test "$rb_module_existed" = true; then
      assert_owned_regular "$rb_module_path" 644 ||
        die 'preexisting candidate module is missing after finalization'
      test "$(sha "$rb_module_path")" = "$rb_module_sha" ||
        die 'preexisting candidate module drifted after finalization'
    elif sudo test -e "$rb_module_path"; then
      die 'candidate module returned after prior DKMS restore'
    fi
    sudo sync
    fixture_interrupt_after rollback-boot-restored-unpublished
    rb_phase=boot-restored
    write_rollback_journal rollback "$rb_phase" ||
      die 'failed to publish boot-restored rollback phase'
    fixture_interrupt_after rollback-boot-restored
  fi

  if test "$rb_phase" = boot-restored; then
    fixture_interrupt_after rollback-candidate-removed-unpublished
    sudo depmod -a "$rb_release" ||
      die 'failed to refresh prior module resolution'
    verify_prior_module_resolution ||
      die 'prior module resolution is not exact after rollback'
    sudo sync
    rb_phase=depmod-verified
    write_rollback_journal rollback "$rb_phase" ||
      die 'failed to publish depmod-verified rollback phase'
    fixture_interrupt_after rollback-depmod-verified
  fi

  test "$rb_phase" = depmod-verified ||
    die 'durable rollback reached an invalid phase'
  verify_prior_module_resolution ||
    die 'prior module resolution drifted before transaction retirement'
  assert_rollback_boot_state ||
    die 'restored boot state drifted before transaction retirement'
  rb_finalizing=true
  if sudo test -e "$state_file"; then
    test "$(sha "$state_file")" = "$rb_transaction_sha" ||
      die 'active transaction drifted before retirement'
    sudo rm -f -- "$state_file" ||
      die 'failed to retire rolled-back transaction'
    sudo sync
  fi
  fixture_interrupt_after rollback-transaction-retired-unpublished
  sudo rm -f -- "$rollback_candidate_tryboot" "$rollback_candidate_inventory" ||
    die 'failed to remove durable rollback auxiliaries'
  sudo rm -f -- "$rollback_state" ||
    die 'failed to clear durable rollback journal'
  sudo sync
  if ! remove_transaction_workspace "$rb_workspace"; then
    remove_transaction_workspace "$rb_workspace" || return 1
  fi
  rb_workspace=''
  rb_complete=true
  trap - EXIT
  printf 'rolled back %s\n' "$rb_revision"
}

accepted_value() {
  local key="$1"

  assert_owned_regular "$accepted_state" 600 || return
  sudo awk -F= -v wanted="$key" '$1 == wanted { print $2 }' "$accepted_state"
}

assert_accepted_state() {
  local key count schema version revision release manifest artifact marker prior=false
  local -a keys=()

  assert_owned_regular "$accepted_state" 600 || return
  assert_owned_regular "$accepted_stock_config" 600 || return
  schema="$(accepted_value schema_version)"
  case "$schema" in
    1) keys=("${accepted_keys_v1[@]}") ;;
    2) keys=("${accepted_keys[@]}") ;;
    *) return 1 ;;
  esac
  test "$(sudo awk 'END { print NR }' "$accepted_state")" = "${#keys[@]}" || {
    echo 'accepted state has the wrong cardinality' >&2
    return 1
  }
  sudo awk -F= 'NF != 2 || $1 == "" || $2 == "" { exit 1 }' "$accepted_state" || {
    echo 'accepted state has malformed rows' >&2
    return 1
  }
  for key in "${keys[@]}"; do
    count="$(sudo awk -F= -v wanted="$key" '$1 == wanted { count++ } END { print count + 0 }' "$accepted_state")"
    test "$count" = 1 || {
      printf 'accepted state key is missing or duplicated: %s\n' "$key" >&2
      return 1
    }
  done
  version="$(accepted_value driver_version)"
  revision="$(accepted_value source_revision)"
  release="$(accepted_value kernel_release)"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return
  [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || return
  [[ "$release" =~ ^[A-Za-z0-9._+-]+$ ]] || return
  for key in manifest_sha256 module_sha256 overlay_sha256 normal_config_sha256 stock_config_sha256; do
    [[ "$(accepted_value "$key")" =~ ^[0-9a-f]{64}$ ]] || return
  done
  test "$(accepted_value module_file)" = hyperpixel2r_kms.ko || return
  test "$(accepted_value overlay_file)" = "hyperpixel2r-kms-${revision:0:12}.dtbo" || return
  test "$(sha "$accepted_stock_config")" = "$(accepted_value stock_config_sha256)" || return
  artifact="$artifact_root/$version/$revision/$release"
  if sudo test -L "$artifact/prior-tryboot.txt"; then return 1
  elif sudo test -e "$artifact/prior-tryboot.txt"; then prior=true
  fi
  assert_artifact_tree "$artifact" "$prior" || return
  marker="$artifact/dkms-prior-state"
  if test "$schema" = 1; then
    test "$(sudo sed -n '1p' "$marker")" != schema_version=2 || {
      echo 'legacy accepted state cannot authorize a full DKMS inventory' >&2
      return 1
    }
  else
    [[ "$(accepted_value prior_dkms_inventory_sha256)" =~ ^[0-9a-f]{64}$ ]] || return
    test "$(sha "$marker")" = "$(accepted_value prior_dkms_inventory_sha256)" || {
      echo 'accepted DKMS inventory checksum differs' >&2
      return 1
    }
  fi
  manifest="$artifact/manifest.txt"
  test "$(sha "$manifest")" = "$(accepted_value manifest_sha256)" || return
  test "$(manifest_value "$manifest" driver_version)" = "$version" || return
  test "$(manifest_value "$manifest" source_revision)" = "$revision" || return
  test "$(manifest_value "$manifest" kernel_release)" = "$release" || return
  test "$(manifest_value "$manifest" module_file)" = "$(accepted_value module_file)" || return
  test "$(manifest_value "$manifest" module_sha256)" = "$(accepted_value module_sha256)" || return
  test "$(manifest_value "$manifest" overlay_file)" = "$(accepted_value overlay_file)" || return
  test "$(manifest_value "$manifest" overlay_sha256)" = "$(accepted_value overlay_sha256)" || return
}

write_surgical_stock_config() {
  local input="$1"
  local overlay_file="$2"
  local output="$3"
  local workspace="$4"

  require_regular "$input" || return
  assert_private_workspace "$workspace" || return
  assert_owned_regular "$output" 600 || return
  sudo awk -v wanted="dtoverlay=$overlay_file" '
    {
      line=$0
      trim=line
      sub(/^[[:space:]]+/, "", trim)
      sub(/[[:space:]]+$/, "", trim)
      if (trim == wanted) { selected++; next }
      if (trim == "# hyperpixel2r-kms accepted candidate") { comments++; next }
      if (trim ~ /^dtoverlay=/ && trim ~ /hyperpixel2r/) foreign++
      print line
    }
    END {
      if (selected != 1 || foreign != 0 || comments > 1) exit 1
    }
  ' "$input" | sudo tee "$output" >/dev/null || return
  assert_private_workspace "$workspace" || return
  assert_owned_regular "$output" 600 || return
}

record_accepted() {
  local version="$1"
  local revision="$2"
  local release="$3"
  local artifact manifest module_file module_sha overlay_file overlay_sha module_path overlay_path
  local workspace normal_snapshot stock receipt manifest_sha normal_sha stock_sha receipt_sha
  local prior_dkms_inventory_sha prior=false

  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'unsafe accepted driver version'
  [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || die 'unsafe accepted source revision'
  [[ "$release" =~ ^[A-Za-z0-9._+-]+$ ]] || die 'unsafe accepted kernel release'
  test ! -L "$state_file" && test ! -e "$state_file" || die 'refusing acceptance while a tryboot transaction is active'
  if sudo test -e "$accepted_state" || sudo test -L "$accepted_state"; then
    assert_accepted_state || die 'existing accepted state is unsafe'
    test "$(accepted_value driver_version)" = "$version" &&
      test "$(accepted_value source_revision)" = "$revision" &&
      test "$(accepted_value kernel_release)" = "$release" ||
      die 'a different driver is already accepted'
    printf 'already accepted %s\n' "$revision"
    return
  fi
  test ! -L "$accepted_stock_config" && test ! -e "$accepted_stock_config" ||
    die 'orphan accepted stock config exists'
  artifact="$artifact_root/$version/$revision/$release"
  if sudo test -L "$artifact/prior-tryboot.txt"; then die 'unsafe prior tryboot receipt'
  elif sudo test -e "$artifact/prior-tryboot.txt"; then prior=true
  fi
  assert_artifact_tree "$artifact" "$prior" || die 'accepted artifact tree is unsafe'
  prior_dkms_inventory_sha="$(sha "$artifact/dkms-prior-state")" ||
    die 'accepted DKMS inventory is unsafe'
  manifest="$artifact/manifest.txt"
  test "$(manifest_value "$manifest" driver_version)" = "$version" || die 'accepted version differs'
  test "$(manifest_value "$manifest" source_revision)" = "$revision" || die 'accepted revision differs'
  test "$(manifest_value "$manifest" kernel_release)" = "$release" || die 'accepted kernel differs'
  module_file="$(manifest_value "$manifest" module_file)"
  module_sha="$(manifest_value "$manifest" module_sha256)"
  overlay_file="$(manifest_value "$manifest" overlay_file)"
  overlay_sha="$(manifest_value "$manifest" overlay_sha256)"
  module_path="${root}/lib/modules/$release/extra/$module_file"
  overlay_path="${root}/boot/firmware/overlays/$overlay_file"
  assert_owned_regular "$module_path" 644 || die 'accepted module is unsafe'
  assert_owned_regular "$overlay_path" boot || die 'accepted overlay is unsafe'
  test "$(sha "$module_path")" = "$module_sha" || die 'accepted module differs'
  test "$(sha "$overlay_path")" = "$overlay_sha" || die 'accepted overlay differs'
  assert_owned_regular "$normal_config" boot || die 'accepted normal boot config is unsafe'

  workspace="$(new_transaction_workspace)" || die 'failed to create acceptance workspace'
  normal_snapshot="$(privileged_snapshot "$normal_config" "$workspace" accepted-normal)" ||
    die 'failed to snapshot accepted normal config'
  stock="$(private_file "$workspace" accepted-stock)" || die 'failed to allocate stock config'
  write_surgical_stock_config "$normal_snapshot" "$overlay_file" "$stock" "$workspace" ||
    die 'accepted normal config does not have one exact owned declaration'
  receipt="$(private_file "$workspace" accepted-state)" || die 'failed to allocate accepted state'
  manifest_sha="$(sha "$manifest")"
  normal_sha="$(sha "$normal_snapshot")"
  stock_sha="$(sha "$stock")"
  {
    printf 'schema_version=2\n'
    printf 'driver_version=%s\n' "$version"
    printf 'source_revision=%s\n' "$revision"
    printf 'kernel_release=%s\n' "$release"
    printf 'manifest_sha256=%s\n' "$manifest_sha"
    printf 'module_file=%s\n' "$module_file"
    printf 'module_sha256=%s\n' "$module_sha"
    printf 'overlay_file=%s\n' "$overlay_file"
    printf 'overlay_sha256=%s\n' "$overlay_sha"
    printf 'normal_config_sha256=%s\n' "$normal_sha"
    printf 'stock_config_sha256=%s\n' "$stock_sha"
    printf 'prior_dkms_inventory_sha256=%s\n' "$prior_dkms_inventory_sha"
  } | sudo tee "$receipt" >/dev/null || die 'failed to write accepted state'
  assert_owned_regular "$receipt" 600 || die 'accepted state allocation drifted'
  receipt_sha="$(sha "$receipt")"
  atomic_copy "$stock" "$accepted_stock_config" 600 "$stock_sha" ||
    die 'failed to publish accepted stock config'
  atomic_copy "$receipt" "$accepted_state" 600 "$receipt_sha" ||
    die 'failed to publish accepted state'
  remove_transaction_workspace "$workspace" || die 'failed to remove acceptance workspace'
  sudo sync
  assert_accepted_state || die 'published accepted state failed validation'
  printf 'accepted %s\n' "$revision"
}

accepted_transition_value() {
  local key="$1"

  assert_owned_regular "$accepted_transition" 600 || return
  sudo awk -F= -v wanted="$key" '$1 == wanted { print $2 }' "$accepted_transition"
}

publish_accepted_transition() {
  local kind="$1"
  local candidate_version="$2"
  local candidate_revision="$3"
  local candidate_release="$4"
  local candidate_manifest_sha="$5"
  local candidate_module_file="$6"
  local candidate_module_sha="$7"
  local candidate_overlay_file="$8"
  local candidate_overlay_sha="$9"
  local prior_snapshot="${10}"
  local candidate_snapshot="${11}"
  local prior_status="${12}"
  local workspace="${13}"
  local prior_sha candidate_sha state_tmp state_sha candidate_artifact candidate_inventory_sha

  prior_sha="$(sha "$prior_snapshot")" || return
  candidate_sha="$(sha "$candidate_snapshot")" || return
  if test "$kind" = new; then
    candidate_inventory_sha=pending
  else
    candidate_artifact="$artifact_root/$candidate_version/$candidate_revision/$candidate_release"
    assert_dkms_inventory_file "$candidate_artifact/dkms-prior-state" || return
    candidate_inventory_sha="$(sha "$candidate_artifact/dkms-prior-state")" || return
  fi
  state_tmp="$(private_file "$workspace" accepted-transition)" || return
  {
    printf 'schema_version=3\n'
    printf 'kind=%s\n' "$kind"
    printf 'phase=prepared\n'
    printf 'prior_driver_version=%s\n' "$(accepted_value driver_version)"
    printf 'prior_source_revision=%s\n' "$(accepted_value source_revision)"
    printf 'prior_kernel_release=%s\n' "$(accepted_value kernel_release)"
    printf 'candidate_driver_version=%s\n' "$candidate_version"
    printf 'candidate_source_revision=%s\n' "$candidate_revision"
    printf 'candidate_kernel_release=%s\n' "$candidate_release"
    printf 'candidate_manifest_sha256=%s\n' "$candidate_manifest_sha"
    printf 'candidate_module_file=%s\n' "$candidate_module_file"
    printf 'candidate_module_sha256=%s\n' "$candidate_module_sha"
    printf 'candidate_overlay_file=%s\n' "$candidate_overlay_file"
    printf 'candidate_overlay_sha256=%s\n' "$candidate_overlay_sha"
    printf 'prior_normal_config_sha256=%s\n' "$prior_sha"
    printf 'candidate_normal_config_sha256=%s\n' "$candidate_sha"
    printf 'tryboot_config_sha256=%s\n' "$candidate_sha"
    printf 'prior_dkms_status=%s\n' "$prior_status"
    printf 'candidate_dkms_inventory_sha256=%s\n' "$candidate_inventory_sha"
  } | sudo tee "$state_tmp" >/dev/null || return
  state_sha="$(sha "$state_tmp")" || return
  atomic_copy "$prior_snapshot" "$accepted_transition_prior_config" 600 "$prior_sha" || return
  atomic_copy "$state_tmp" "$accepted_transition" 600 "$state_sha" || return
  assert_accepted_transition || return
  fixture_interrupt_after accepted-transition-published
}

set_accepted_transition_phase() {
  local expected="$1"
  local next="$2"
  local normal_sha="${3:-}"
  local inventory_sha="${4:-}"
  local schema workspace state_tmp state_sha

  assert_accepted_transition || return
  test "$(accepted_transition_value phase)" = "$expected" || return
  schema="$(accepted_transition_value schema_version)"
  if test "$schema" = 3 &&
    test "$(accepted_transition_value candidate_dkms_inventory_sha256)" = pending; then
    test "$expected:$next" = prepared:staged || return
    [[ "$inventory_sha" =~ ^[0-9a-f]{64}$ ]] || return
  elif test -n "$inventory_sha"; then
    test "$schema" = 3 || return
    test "$(accepted_transition_value candidate_dkms_inventory_sha256)" = \
      "$inventory_sha" || return
    inventory_sha=''
  fi
  workspace="$(new_transaction_workspace)" || return
  accepted_workspace="$workspace"
  state_tmp="$(private_file "$workspace" accepted-transition)" || return
  if test -n "$normal_sha" && test -n "$inventory_sha"; then
    sudo sed \
      -e "s/^phase=$expected\$/phase=$next/" \
      -e "s/^candidate_normal_config_sha256=.*/candidate_normal_config_sha256=$normal_sha/" \
      -e "s/^candidate_dkms_inventory_sha256=pending\$/candidate_dkms_inventory_sha256=$inventory_sha/" \
      "$accepted_transition" | sudo tee "$state_tmp" >/dev/null || return
  elif test -n "$normal_sha"; then
    sudo sed \
      -e "s/^phase=$expected\$/phase=$next/" \
      -e "s/^candidate_normal_config_sha256=.*/candidate_normal_config_sha256=$normal_sha/" \
      "$accepted_transition" | sudo tee "$state_tmp" >/dev/null || return
  elif test -n "$inventory_sha"; then
    sudo sed \
      -e "s/^phase=$expected\$/phase=$next/" \
      -e "s/^candidate_dkms_inventory_sha256=pending\$/candidate_dkms_inventory_sha256=$inventory_sha/" \
      "$accepted_transition" | sudo tee "$state_tmp" >/dev/null || return
  else
    sudo sed -e "s/^phase=$expected\$/phase=$next/" \
      "$accepted_transition" | sudo tee "$state_tmp" >/dev/null || return
  fi
  state_sha="$(sha "$state_tmp")" || return
  atomic_copy "$state_tmp" "$accepted_transition" 600 "$state_sha" || return
  remove_transaction_workspace "$workspace" || return
  accepted_workspace=''
  assert_accepted_transition
}

prepare_new_accepted() {
  local version="$1"
  local revision="$2"
  local release="$3"
  local manifest_sha="$4"
  local module_file="$5"
  local module_sha="$6"
  local overlay_file="$7"
  local overlay_sha="$8"
  local prior_version prior_status workspace prior_snapshot stock candidate stock_sha

  assert_accepted_state || die 'accepted driver state is missing or unsafe'
  test ! -L "$accepted_transition" && test ! -e "$accepted_transition" ||
    die 'an accepted driver transition is already active'
  test ! -L "$accepted_transition_prior_config" && test ! -e "$accepted_transition_prior_config" ||
    die 'orphan accepted transition config exists'
  test ! -L "$state_file" && test ! -e "$state_file" ||
    die 'a legacy tryboot transaction is active'
  test ! -L "$tryboot_config" && test ! -e "$tryboot_config" ||
    die 'accepted transition requires an unused tryboot config'
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'unsafe candidate driver version'
  [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || die 'unsafe candidate source revision'
  [[ "$release" =~ ^[A-Za-z0-9._+-]+$ ]] || die 'unsafe candidate kernel release'
  [[ "$manifest_sha" =~ ^[0-9a-f]{64}$ ]] || die 'unsafe candidate manifest checksum'
  test "$module_file" = hyperpixel2r_kms.ko || die 'unsafe candidate module file'
  [[ "$module_sha" =~ ^[0-9a-f]{64}$ ]] || die 'unsafe candidate module checksum'
  test "$overlay_file" = "hyperpixel2r-kms-${revision:0:12}.dtbo" ||
    die 'unsafe candidate overlay file'
  [[ "$overlay_sha" =~ ^[0-9a-f]{64}$ ]] || die 'unsafe candidate overlay checksum'
  test "$version:$revision:$release" != \
    "$(accepted_value driver_version):$(accepted_value source_revision):$(accepted_value kernel_release)" ||
    die 'candidate is already accepted'
  prior_version="$(accepted_value driver_version)"
  prior_status="$(validate_dkms_status "$prior_version")" ||
    die 'accepted prior DKMS status is invalid'
  case "$prior_status" in absent|unregistered|registered) ;; *) die 'accepted prior DKMS status is invalid';; esac
  test "$(sha "$normal_config")" = "$(accepted_value normal_config_sha256)" ||
    die 'accepted normal config drifted before transition'
  workspace="$(new_transaction_workspace)" || die 'failed to create accepted transition workspace'
  accepted_workspace="$workspace"
  prior_snapshot="$(privileged_snapshot "$normal_config" "$workspace" accepted-prior)" ||
    die 'failed to snapshot accepted normal config'
  stock="$(private_file "$workspace" accepted-stock)" || die 'failed to allocate accepted stock'
  write_surgical_stock_config "$prior_snapshot" "$(accepted_value overlay_file)" "$stock" "$workspace" ||
    die 'accepted normal config cannot be separated from prior driver'
  candidate="$(private_file "$workspace" accepted-candidate)" ||
    die 'failed to allocate accepted candidate'
  stock_sha="$(sha "$stock")"
  atomic_copy "$stock" "$candidate" 600 "$stock_sha" || die 'failed to seed accepted candidate'
  printf '\n# hyperpixel2r-kms one-shot candidate\ndtoverlay=%s\n' "$overlay_file" |
    sudo tee -a "$candidate" >/dev/null || die 'failed to append accepted candidate'
  publish_accepted_transition new "$version" "$revision" "$release" "$manifest_sha" \
    "$module_file" "$module_sha" "$overlay_file" "$overlay_sha" \
    "$prior_snapshot" "$candidate" "$prior_status" "$workspace" ||
    die 'failed to publish accepted candidate journal'
  remove_transaction_workspace "$workspace" || die 'failed to remove accepted transition workspace'
  accepted_workspace=''
  printf 'prepared accepted %s\n' "$revision"
}

mark_committed_accepted() {
  local normal_sha

  assert_accepted_transition || die 'accepted driver transition is missing or unsafe'
  test "$(accepted_transition_value phase)" = staged ||
    die 'accepted driver transition is not staged'
  test ! -L "$state_file" && test ! -e "$state_file" ||
    die 'legacy tryboot state survived commit'
  assert_owned_regular "$normal_config" boot || die 'committed normal config is unsafe'
  normal_sha="$(sha "$normal_config")"
  set_accepted_transition_phase staged committed "$normal_sha" ||
    die 'failed to publish committed binding state'
  fixture_interrupt_after accepted-committed-published
  assert_accepted_transition || die 'committed binding failed validation'
  printf 'marked committed %s\n' "$(accepted_transition_value candidate_source_revision)"
}

assert_accepted_transition() {
  local key count schema kind phase prior_version prior_revision prior_release
  local candidate_version candidate_revision candidate_release candidate_artifact marker
  local -a keys=()

  assert_owned_regular "$accepted_transition" 600 || return
  assert_owned_regular "$accepted_transition_prior_config" 600 || return
  schema="$(accepted_transition_value schema_version)"
  case "$schema" in
    2) keys=("${accepted_transition_keys_v2[@]}") ;;
    3) keys=("${accepted_transition_keys[@]}") ;;
    *) return 1 ;;
  esac
  test "$(sudo awk 'END { print NR }' "$accepted_transition")" = "${#keys[@]}" || return
  sudo awk -F= 'NF != 2 || $1 == "" || $2 == "" { exit 1 }' "$accepted_transition" || return
  for key in "${keys[@]}"; do
    count="$(sudo awk -F= -v wanted="$key" '$1 == wanted { count++ } END { print count + 0 }' "$accepted_transition")"
    test "$count" = 1 || return
  done
  kind="$(accepted_transition_value kind)"
  case "$kind" in new|retained) ;; *) return 1;; esac
  phase="$(accepted_transition_value phase)"
  case "$phase" in prepared|staged|committed|verified|finalizing|receipt_published) ;; *) return 1;; esac
  prior_version="$(accepted_transition_value prior_driver_version)"
  prior_revision="$(accepted_transition_value prior_source_revision)"
  prior_release="$(accepted_transition_value prior_kernel_release)"
  candidate_version="$(accepted_transition_value candidate_driver_version)"
  candidate_revision="$(accepted_transition_value candidate_source_revision)"
  candidate_release="$(accepted_transition_value candidate_kernel_release)"
  [[ "$prior_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return
  [[ "$candidate_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return
  [[ "$prior_revision" =~ ^[0-9a-f]{40}$ ]] || return
  [[ "$candidate_revision" =~ ^[0-9a-f]{40}$ ]] || return
  [[ "$prior_release" =~ ^[A-Za-z0-9._+-]+$ ]] || return
  [[ "$candidate_release" =~ ^[A-Za-z0-9._+-]+$ ]] || return
  for key in \
    candidate_manifest_sha256 candidate_module_sha256 candidate_overlay_sha256 \
    prior_normal_config_sha256 candidate_normal_config_sha256 tryboot_config_sha256; do
    [[ "$(accepted_transition_value "$key")" =~ ^[0-9a-f]{64}$ ]] || return
  done
  test "$(accepted_transition_value candidate_module_file)" = hyperpixel2r_kms.ko || return
  test "$(accepted_transition_value candidate_overlay_file)" = \
    "hyperpixel2r-kms-${candidate_revision:0:12}.dtbo" || return
  case "$(accepted_transition_value prior_dkms_status)" in absent|unregistered|registered) ;; *) return 1;; esac
  candidate_artifact="$artifact_root/$candidate_version/$candidate_revision/$candidate_release"
  marker="$candidate_artifact/dkms-prior-state"
  if test "$schema" = 3; then
    if test "$(accepted_transition_value candidate_dkms_inventory_sha256)" = pending; then
      test "$kind:$phase" = new:prepared || return
    else
      [[ "$(accepted_transition_value candidate_dkms_inventory_sha256)" =~ ^[0-9a-f]{64}$ ]] ||
        return
      assert_dkms_inventory_file "$marker" || return
      test "$(sha "$marker")" = \
        "$(accepted_transition_value candidate_dkms_inventory_sha256)" || return
    fi
  elif sudo test -e "$marker" || sudo test -L "$marker"; then
    assert_dkms_inventory_file "$marker" || return
    test "$(sudo sed -n '1p' "$marker")" != schema_version=2 || return
  fi
  test "$(sha "$accepted_transition_prior_config")" = \
    "$(accepted_transition_value prior_normal_config_sha256)" || return
  if test "$phase" = receipt_published; then
    test "$(accepted_value driver_version)" = "$candidate_version" || return
    test "$(accepted_value source_revision)" = "$candidate_revision" || return
    test "$(accepted_value kernel_release)" = "$candidate_release" || return
  elif test "$phase" = finalizing; then
    if test "$(accepted_value source_revision)" = "$prior_revision"; then
      test "$(accepted_value driver_version)" = "$prior_version" || return
      test "$(accepted_value kernel_release)" = "$prior_release" || return
    else
      test "$(accepted_value driver_version)" = "$candidate_version" || return
      test "$(accepted_value source_revision)" = "$candidate_revision" || return
      test "$(accepted_value kernel_release)" = "$candidate_release" || return
    fi
  else
    test "$(accepted_value driver_version)" = "$prior_version" || return
    test "$(accepted_value source_revision)" = "$prior_revision" || return
    test "$(accepted_value kernel_release)" = "$prior_release" || return
  fi
}

replace_active_dkms_source() {
  local prior_version="$1"
  local prior_artifact="$2"
  local prior_status="$3"
  local candidate_version="$4"
  local candidate_artifact="$5"
  local prior_dir="$dkms_root/hyperpixel2r-kms-$prior_version"
  local candidate_dir="$dkms_root/hyperpixel2r-kms-$candidate_version"
  local current_status

  assert_source_tree_shape "$prior_dir" "$prior_artifact/dkms-source" || return
  current_status="$(validate_dkms_status "$prior_version")" || return
  test "$current_status" = "$prior_status" || return
  if test "$prior_status" = registered; then
    run_dkms remove -m hyperpixel2r-kms -v "$prior_version" --all || return
  fi
  remove_exact_tree "$prior_dir" || return
  if test "$candidate_dir" != "$prior_dir"; then
    if sudo test -L "$candidate_dir"; then return 1
    elif sudo test -e "$candidate_dir"; then
      assert_source_tree_shape "$candidate_dir" "$candidate_artifact/dkms-source" || return
      current_status="$(validate_dkms_status "$candidate_version")" || return
      if test "$current_status" = registered; then
        run_dkms remove -m hyperpixel2r-kms -v "$candidate_version" --all || return
      fi
      remove_exact_tree "$candidate_dir" || return
    fi
  fi
  materialize_source_tree "$candidate_artifact/dkms-source" "$candidate_dir" || return
  run_dkms add -m hyperpixel2r-kms -v "$candidate_version" || return
}

stage_retained() {
  local version="$1"
  local revision="$2"
  local release="$3"
  local prior_version prior_revision prior_release prior_artifact candidate_artifact candidate_manifest
  local prior_status module_file module_sha overlay_file overlay_sha module_path overlay_path
  local workspace prior_snapshot stock candidate candidate_snapshot prior_sha candidate_sha tryboot_sha
  local prior=false candidate_prior=false

  assert_accepted_state || die 'accepted driver state is missing or unsafe'
  test ! -L "$accepted_transition" && test ! -e "$accepted_transition" ||
    die 'an accepted driver transition is already active'
  test ! -L "$accepted_transition_prior_config" && test ! -e "$accepted_transition_prior_config" ||
    die 'orphan accepted transition config exists'
  test ! -L "$state_file" && test ! -e "$state_file" ||
    die 'a legacy tryboot transaction is active'
  test ! -L "$tryboot_config" && test ! -e "$tryboot_config" ||
    die 'accepted retained transition requires an unused tryboot config'
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'unsafe retained driver version'
  [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || die 'unsafe retained source revision'
  [[ "$release" =~ ^[A-Za-z0-9._+-]+$ ]] || die 'unsafe retained kernel release'
  prior_version="$(accepted_value driver_version)"
  prior_revision="$(accepted_value source_revision)"
  prior_release="$(accepted_value kernel_release)"
  test "$version:$revision:$release" != "$prior_version:$prior_revision:$prior_release" ||
    die 'retained candidate is already accepted'
  prior_artifact="$artifact_root/$prior_version/$prior_revision/$prior_release"
  candidate_artifact="$artifact_root/$version/$revision/$release"
  if sudo test -e "$candidate_artifact/prior-tryboot.txt"; then candidate_prior=true; fi
  assert_artifact_tree "$candidate_artifact" "$candidate_prior" ||
    die 'retained candidate artifact is unsafe'
  candidate_manifest="$candidate_artifact/manifest.txt"
  test "$(manifest_value "$candidate_manifest" driver_version)" = "$version" || die 'retained version differs'
  test "$(manifest_value "$candidate_manifest" source_revision)" = "$revision" || die 'retained revision differs'
  test "$(manifest_value "$candidate_manifest" kernel_release)" = "$release" || die 'retained kernel differs'
  module_file="$(manifest_value "$candidate_manifest" module_file)"
  module_sha="$(manifest_value "$candidate_manifest" module_sha256)"
  overlay_file="$(manifest_value "$candidate_manifest" overlay_file)"
  overlay_sha="$(manifest_value "$candidate_manifest" overlay_sha256)"
  module_path="${root}/lib/modules/$release/extra/$module_file"
  overlay_path="${root}/boot/firmware/overlays/$overlay_file"
  prior_status="$(validate_dkms_status "$prior_version")" || die 'accepted prior DKMS status is invalid'
  case "$prior_status" in absent|unregistered|registered) ;; *) die 'accepted prior DKMS status is invalid';; esac
  assert_owned_regular "$normal_config" boot || die 'accepted normal config is unsafe'
  test "$(sha "$normal_config")" = "$(accepted_value normal_config_sha256)" ||
    die 'accepted normal config drifted before retained transition'

  workspace="$(new_transaction_workspace)" || die 'failed to create retained transition workspace'
  accepted_workspace="$workspace"
  prior_snapshot="$(privileged_snapshot "$normal_config" "$workspace" retained-prior)" ||
    die 'failed to snapshot accepted normal config'
  stock="$(private_file "$workspace" retained-stock)" || die 'failed to allocate retained stock'
  write_surgical_stock_config "$prior_snapshot" "$(accepted_value overlay_file)" "$stock" "$workspace" ||
    die 'accepted normal config cannot be separated from prior driver'
  candidate="$(private_file "$workspace" retained-candidate)" || die 'failed to allocate retained candidate'
  stock_sha="$(sha "$stock")"
  atomic_copy "$stock" "$candidate" 600 "$stock_sha" || die 'failed to seed retained candidate'
  printf '\n# hyperpixel2r-kms one-shot candidate\ndtoverlay=%s\n' "$overlay_file" |
    sudo tee -a "$candidate" >/dev/null || die 'failed to append retained candidate declaration'
  candidate_sha="$(sha "$candidate")"
  candidate_snapshot="$(privileged_snapshot "$candidate" "$workspace" retained-candidate)" ||
    die 'failed to snapshot retained candidate config'
  tryboot_sha="$(sha "$candidate_snapshot")"
  prior_sha="$(sha "$prior_snapshot")"
  publish_accepted_transition retained "$version" "$revision" "$release" \
    "$(sha "$candidate_manifest")" "$module_file" "$module_sha" \
    "$overlay_file" "$overlay_sha" "$prior_snapshot" "$candidate_snapshot" \
    "$prior_status" "$workspace" || die 'failed to publish retained transition journal'

  # The complete durable journal precedes the first active mutation.
  assert_owned_regular "$candidate_artifact/$module_file" 644 || die 'retained module is unsafe'
  assert_owned_regular "$candidate_artifact/$overlay_file" 644 || die 'retained overlay is unsafe'
  copy_if_absent_or_exact "$candidate_artifact/$overlay_file" "$overlay_path" 644 "$overlay_sha" true ||
    die 'failed to install retained overlay'
  fixture_interrupt_after retained-overlay-installed
  atomic_copy "$candidate_artifact/$module_file" "$module_path" 644 "$module_sha" ||
    die 'failed to install retained module'
  fixture_interrupt_after retained-module-installed
  replace_active_dkms_source "$prior_version" "$prior_artifact" "$prior_status" \
    "$version" "$candidate_artifact" || die 'failed to activate retained DKMS source'
  fixture_interrupt_after retained-dkms-activated
  atomic_copy "$candidate_snapshot" "$tryboot_config" 644 "$tryboot_sha" true ||
    die 'failed to publish retained tryboot config'
  fixture_interrupt_after retained-tryboot-published
  set_accepted_transition_phase prepared staged ||
    die 'failed to mark retained transition staged'
  fixture_interrupt_after retained-staged-published
  remove_transaction_workspace "$workspace" || die 'failed to remove retained transition workspace'
  accepted_workspace=''
  sudo depmod -a "$release"
  sudo sync
  assert_accepted_transition || die 'retained transition failed validation'
  printf 'staged retained %s\n' "$revision"
}

commit_retained() {
  local version revision release candidate_artifact manifest overlay_file workspace prior_snapshot stock normal_candidate
  local normal_sha normal_snapshot state_tmp state_sha

  assert_accepted_transition || die 'accepted retained transition is unsafe'
  test "$(accepted_transition_value phase)" = staged || die 'accepted retained transition is not staged'
  version="$(accepted_transition_value candidate_driver_version)"
  revision="$(accepted_transition_value candidate_source_revision)"
  release="$(accepted_transition_value candidate_kernel_release)"
  candidate_artifact="$artifact_root/$version/$revision/$release"
  manifest="$candidate_artifact/manifest.txt"
  overlay_file="$(manifest_value "$manifest" overlay_file)"
  assert_owned_regular "$tryboot_config" boot || die 'retained tryboot config is unsafe'
  test "$(sha "$tryboot_config")" = "$(accepted_transition_value tryboot_config_sha256)" ||
    die 'retained tryboot config drifted'
  test "$(sha "$normal_config")" = "$(accepted_transition_value prior_normal_config_sha256)" ||
    die 'normal config drifted before retained commit'
  workspace="$(new_transaction_workspace)" || die 'failed to create retained commit workspace'
  accepted_workspace="$workspace"
  prior_snapshot="$(privileged_snapshot "$normal_config" "$workspace" commit-prior)" ||
    die 'failed to snapshot prior normal config'
  stock="$(private_file "$workspace" commit-stock)" || die 'failed to allocate commit stock'
  write_surgical_stock_config "$prior_snapshot" "$(accepted_value overlay_file)" "$stock" "$workspace" ||
    die 'prior normal config cannot be separated'
  normal_candidate="$(private_file "$workspace" commit-normal)" ||
    die 'failed to allocate retained normal config'
  stock_sha="$(sha "$stock")"
  atomic_copy "$stock" "$normal_candidate" 600 "$stock_sha" || die 'failed to seed retained normal config'
  printf '\n# hyperpixel2r-kms accepted candidate\ndtoverlay=%s\n' "$overlay_file" |
    sudo tee -a "$normal_candidate" >/dev/null || die 'failed to append retained normal declaration'
  normal_sha="$(sha "$normal_candidate")"
  normal_snapshot="$(privileged_snapshot "$normal_candidate" "$workspace" commit-normal)" ||
    die 'failed to snapshot retained normal config'
  atomic_copy "$normal_snapshot" "$normal_config" 644 "$normal_sha" true ||
    die 'failed to publish retained normal config'
  fixture_interrupt_after retained-normal-published
  sudo rm -- "$tryboot_config" || die 'failed to remove retained tryboot config'
  remove_transaction_workspace "$workspace" || die 'failed to remove retained commit workspace'
  accepted_workspace=''
  set_accepted_transition_phase staged committed "$normal_sha" ||
    die 'failed to publish committed transition state'
  fixture_interrupt_after retained-committed-published
  sudo sync
  assert_accepted_transition || die 'committed retained transition failed validation'
  printf 'committed retained %s\n' "$revision"
}

restore_prior_from_accepted_transition() {
  local prior_version prior_revision prior_release candidate_version candidate_revision candidate_release
  local prior_artifact candidate_artifact prior_manifest candidate_manifest prior_module prior_module_sha prior_overlay prior_overlay_sha
  local candidate_overlay module_path prior_overlay_path candidate_overlay_path prior_status candidate_status prior_dir candidate_dir

  assert_accepted_transition || return
  prior_version="$(accepted_transition_value prior_driver_version)"
  prior_revision="$(accepted_transition_value prior_source_revision)"
  prior_release="$(accepted_transition_value prior_kernel_release)"
  candidate_version="$(accepted_transition_value candidate_driver_version)"
  candidate_revision="$(accepted_transition_value candidate_source_revision)"
  candidate_release="$(accepted_transition_value candidate_kernel_release)"
  prior_artifact="$artifact_root/$prior_version/$prior_revision/$prior_release"
  candidate_artifact="$artifact_root/$candidate_version/$candidate_revision/$candidate_release"
  prior_manifest="$prior_artifact/manifest.txt"
  assert_artifact_tree "$prior_artifact" false 2>/dev/null ||
    assert_artifact_tree "$prior_artifact" true || return
  prior_module="$(manifest_value "$prior_manifest" module_file)"
  prior_module_sha="$(manifest_value "$prior_manifest" module_sha256)"
  prior_overlay="$(manifest_value "$prior_manifest" overlay_file)"
  prior_overlay_sha="$(manifest_value "$prior_manifest" overlay_sha256)"
  module_path="${root}/lib/modules/$prior_release/extra/$prior_module"
  prior_overlay_path="${root}/boot/firmware/overlays/$prior_overlay"
  prior_status="$(accepted_transition_value prior_dkms_status)"
  prior_dir="$dkms_root/hyperpixel2r-kms-$prior_version"
  candidate_dir="$dkms_root/hyperpixel2r-kms-$candidate_version"
  if ! sudo test -e "$candidate_artifact" && ! sudo test -L "$candidate_artifact"; then
    assert_source_tree_shape "$prior_dir" "$prior_artifact/dkms-source" || return
    assert_owned_regular "$module_path" 644 || return
    test "$(sha "$module_path")" = "$prior_module_sha" || return
    assert_owned_regular "$prior_overlay_path" boot || return
    test "$(sha "$prior_overlay_path")" = "$prior_overlay_sha" || return
    test "$(sha "$normal_config")" = \
      "$(accepted_transition_value prior_normal_config_sha256)" || return
    sudo rm -f -- "$tryboot_config"
    sudo rm -- "$accepted_transition" || return
    sudo rm -- "$accepted_transition_prior_config" || return
    sudo sync
    return
  fi
  candidate_manifest="$candidate_artifact/manifest.txt"
  candidate_overlay="$(manifest_value "$candidate_manifest" overlay_file)"
  candidate_overlay_path="${root}/boot/firmware/overlays/$candidate_overlay"
  if assert_source_tree_shape "$candidate_dir" "$candidate_artifact/dkms-source" 2>/dev/null; then
    candidate_status="$(validate_dkms_status "$candidate_version")" || return
    if test "$candidate_status" = registered; then
      run_dkms remove -m hyperpixel2r-kms -v "$candidate_version" --all || return
    fi
    remove_exact_tree "$candidate_dir" || return
  elif test "$candidate_dir" != "$prior_dir" && sudo test -e "$candidate_dir"; then
    return 1
  fi
  if sudo test -e "$prior_dir"; then
    assert_source_tree_shape "$prior_dir" "$prior_artifact/dkms-source" ||
      remove_exact_tree "$prior_dir" || return
  fi
  if ! sudo test -e "$prior_dir"; then
    materialize_source_tree "$prior_artifact/dkms-source" "$prior_dir" || return
  fi
  if test "$prior_status" = registered; then
    run_dkms add -m hyperpixel2r-kms -v "$prior_version" || return
  fi
  atomic_copy "$prior_artifact/$prior_module" "$module_path" 644 "$prior_module_sha" || return
  copy_if_absent_or_exact "$prior_artifact/$prior_overlay" "$prior_overlay_path" 644 "$prior_overlay_sha" true || return
  if test "$candidate_overlay_path" != "$prior_overlay_path"; then
    if sudo test -e "$candidate_overlay_path" || sudo test -L "$candidate_overlay_path"; then
      assert_owned_regular "$candidate_overlay_path" boot || return
      test "$(sha "$candidate_overlay_path")" = "$(manifest_value "$candidate_manifest" overlay_sha256)" || return
      sudo rm -- "$candidate_overlay_path" || return
    fi
  fi
  atomic_copy "$accepted_transition_prior_config" "$normal_config" 644 \
    "$(accepted_transition_value prior_normal_config_sha256)" true || return
  sudo rm -f -- "$tryboot_config"
  retire_unaccepted_transition_artifact || return
  sudo rm -- "$accepted_transition" || return
  sudo rm -- "$accepted_transition_prior_config" || return
  sudo depmod -a "$prior_release"
  sudo sync
}

retire_unaccepted_transition_artifact() {
  local version revision release artifact manifest prior=false

  assert_accepted_transition || return
  test "$(accepted_transition_value kind)" = new || return 0
  version="$(accepted_transition_value candidate_driver_version)"
  revision="$(accepted_transition_value candidate_source_revision)"
  release="$(accepted_transition_value candidate_kernel_release)"
  artifact="$artifact_root/$version/$revision/$release"
  if ! sudo test -e "$artifact" && ! sudo test -L "$artifact"; then
    return 0
  fi
  if sudo test -L "$artifact/prior-tryboot.txt"; then return 1
  elif sudo test -e "$artifact/prior-tryboot.txt"; then prior=true
  fi
  assert_artifact_tree "$artifact" "$prior" || return
  manifest="$artifact/manifest.txt"
  test "$(sha "$manifest")" = \
    "$(accepted_transition_value candidate_manifest_sha256)" || return
  test "$(manifest_value "$manifest" driver_version)" = "$version" || return
  test "$(manifest_value "$manifest" source_revision)" = "$revision" || return
  test "$(manifest_value "$manifest" kernel_release)" = "$release" || return
  test "$(manifest_value "$manifest" module_file)" = \
    "$(accepted_transition_value candidate_module_file)" || return
  test "$(manifest_value "$manifest" module_sha256)" = \
    "$(accepted_transition_value candidate_module_sha256)" || return
  test "$(manifest_value "$manifest" overlay_file)" = \
    "$(accepted_transition_value candidate_overlay_file)" || return
  test "$(manifest_value "$manifest" overlay_sha256)" = \
    "$(accepted_transition_value candidate_overlay_sha256)" || return
  remove_artifact_tree "$artifact" "$prior"
}

recover_accepted() {
  if ! sudo test -e "$accepted_transition" && ! sudo test -L "$accepted_transition"; then
    assert_accepted_state || die 'accepted driver receipt is missing or unsafe'
    if sudo test -e "$accepted_transition_prior_config" || sudo test -L "$accepted_transition_prior_config"; then
      assert_owned_regular "$accepted_transition_prior_config" 600 ||
        die 'orphan accepted recovery config is unsafe'
      sudo rm -- "$accepted_transition_prior_config" ||
        die 'failed to clear orphan accepted recovery config'
    fi
    printf 'accepted recovery already complete\n'
    return
  fi
  assert_accepted_transition || die 'accepted driver transition is missing or unsafe'
  case "$(accepted_transition_value phase)" in
    prepared|staged|committed|verified) ;;
    *) die 'accepted transition is already finalizing'
      ;;
  esac
  if sudo test -e "$state_file"; then
    rollback
    retire_unaccepted_transition_artifact ||
      die 'failed to retire recovered unaccepted driver artifact'
    sudo rm -- "$accepted_transition" "$accepted_transition_prior_config" ||
      die 'failed to clear recovered accepted binding'
    assert_accepted_state || die 'restored accepted driver receipt is unsafe'
    printf 'recovered accepted %s\n' "$(accepted_value source_revision)"
    return
  fi
  restore_prior_from_accepted_transition || die 'failed to restore prior accepted driver'
  assert_accepted_state || die 'restored accepted driver receipt is unsafe'
  printf 'recovered accepted %s\n' "$(accepted_value source_revision)"
}

mark_verified_accepted() {
  assert_accepted_transition || die 'accepted driver transition is missing or unsafe'
  test "$(accepted_transition_value phase)" = committed ||
    die 'accepted driver transition is not committed'
  set_accepted_transition_phase committed verified ||
    die 'failed to publish verified accepted transition'
  fixture_interrupt_after accepted-verified-published
  printf 'verified accepted %s\n' "$(accepted_transition_value candidate_source_revision)"
}

finalize_accepted() {
  local version revision release artifact manifest module_file module_sha overlay_file overlay_sha
  local workspace receipt receipt_sha normal_sha prior_version prior_revision prior_release
  local prior_artifact prior_manifest prior_overlay prior_overlay_sha prior_overlay_path stock_sha phase
  local candidate_inventory_sha

  if ! sudo test -e "$accepted_transition" && ! sudo test -L "$accepted_transition"; then
    assert_accepted_state || die 'accepted driver receipt is missing or unsafe'
    if sudo test -e "$accepted_transition_prior_config" || sudo test -L "$accepted_transition_prior_config"; then
      assert_owned_regular "$accepted_transition_prior_config" 600 ||
        die 'orphan accepted transition config is unsafe'
      sudo rm -- "$accepted_transition_prior_config" ||
        die 'failed to clear orphan accepted transition config'
    fi
    printf 'accepted transition already finalized\n'
    return
  fi

  assert_accepted_transition || die 'accepted transition is missing or unsafe'
  phase="$(accepted_transition_value phase)"
  case "$phase" in verified|finalizing|receipt_published) ;; *)
    die 'accepted transition is not verified'
    ;;
  esac
  version="$(accepted_transition_value candidate_driver_version)"
  revision="$(accepted_transition_value candidate_source_revision)"
  release="$(accepted_transition_value candidate_kernel_release)"
  artifact="$artifact_root/$version/$revision/$release"
  candidate_inventory_sha="$(sha "$artifact/dkms-prior-state")" ||
    die 'candidate DKMS inventory is unsafe'
  if test "$(accepted_transition_value schema_version)" = 3; then
    test "$candidate_inventory_sha" = \
      "$(accepted_transition_value candidate_dkms_inventory_sha256)" ||
      die 'candidate DKMS inventory differs from accepted transition'
  else
    test "$(sudo sed -n '1p' "$artifact/dkms-prior-state")" != schema_version=2 ||
      die 'legacy accepted transition cannot authorize a full DKMS inventory'
  fi
  manifest="$artifact/manifest.txt"
  module_file="$(manifest_value "$manifest" module_file)"
  module_sha="$(manifest_value "$manifest" module_sha256)"
  overlay_file="$(manifest_value "$manifest" overlay_file)"
  overlay_sha="$(manifest_value "$manifest" overlay_sha256)"
  test "$(sha "$manifest")" = "$(accepted_transition_value candidate_manifest_sha256)" ||
    die 'candidate manifest differs from accepted transition'
  test "$module_file" = "$(accepted_transition_value candidate_module_file)" &&
    test "$module_sha" = "$(accepted_transition_value candidate_module_sha256)" &&
    test "$overlay_file" = "$(accepted_transition_value candidate_overlay_file)" &&
    test "$overlay_sha" = "$(accepted_transition_value candidate_overlay_sha256)" ||
    die 'candidate artifacts differ from accepted transition'
  normal_sha="$(sha "$normal_config")"
  test "$normal_sha" = "$(accepted_transition_value candidate_normal_config_sha256)" ||
    die 'candidate normal config is not committed'
  assert_owned_regular "${root}/lib/modules/$release/extra/$module_file" 644 ||
    die 'candidate module is not accepted'
  test "$(sha "${root}/lib/modules/$release/extra/$module_file")" = "$module_sha" ||
    die 'candidate module differs'
  assert_owned_regular "${root}/boot/firmware/overlays/$overlay_file" boot ||
    die 'candidate overlay is not accepted'
  test "$(sha "${root}/boot/firmware/overlays/$overlay_file")" = "$overlay_sha" ||
    die 'candidate overlay differs'
  prior_version="$(accepted_transition_value prior_driver_version)"
  prior_revision="$(accepted_transition_value prior_source_revision)"
  prior_release="$(accepted_transition_value prior_kernel_release)"
  prior_artifact="$artifact_root/$prior_version/$prior_revision/$prior_release"
  prior_manifest="$prior_artifact/manifest.txt"
  prior_overlay="$(manifest_value "$prior_manifest" overlay_file)"
  prior_overlay_sha="$(manifest_value "$prior_manifest" overlay_sha256)"
  prior_overlay_path="${root}/boot/firmware/overlays/$prior_overlay"
  if test "$(accepted_value source_revision)" = "$prior_revision"; then
    stock_sha="$(accepted_value stock_config_sha256)"
  else
    test "$(accepted_value source_revision)" = "$revision" ||
      die 'accepted receipt is neither transition endpoint'
    stock_sha="$(accepted_value stock_config_sha256)"
  fi
  if test "$phase" = verified; then
    set_accepted_transition_phase verified finalizing ||
      die 'failed to publish acceptance finalizer'
    fixture_interrupt_after accepted-finalizing-published
    phase=finalizing
  fi
  if test "$phase" = finalizing; then
    if test "$(accepted_value source_revision)" = "$prior_revision"; then
      workspace="$(new_transaction_workspace)" || die 'failed to create acceptance workspace'
      accepted_workspace="$workspace"
      receipt="$(private_file "$workspace" accepted-state)" || die 'failed to allocate accepted receipt'
      {
        printf 'schema_version=2\n'
        printf 'driver_version=%s\n' "$version"
        printf 'source_revision=%s\n' "$revision"
        printf 'kernel_release=%s\n' "$release"
        printf 'manifest_sha256=%s\n' "$(sha "$manifest")"
        printf 'module_file=%s\n' "$module_file"
        printf 'module_sha256=%s\n' "$module_sha"
        printf 'overlay_file=%s\n' "$overlay_file"
        printf 'overlay_sha256=%s\n' "$overlay_sha"
        printf 'normal_config_sha256=%s\n' "$normal_sha"
        printf 'stock_config_sha256=%s\n' "$stock_sha"
        printf 'prior_dkms_inventory_sha256=%s\n' "$candidate_inventory_sha"
      } | sudo tee "$receipt" >/dev/null || die 'failed to write accepted receipt'
      receipt_sha="$(sha "$receipt")"
      atomic_copy "$receipt" "$accepted_state" 600 "$receipt_sha" ||
        die 'failed to publish accepted receipt'
      remove_transaction_workspace "$workspace" || die 'failed to remove acceptance workspace'
      accepted_workspace=''
      fixture_interrupt_after accepted-receipt-published
    fi
    set_accepted_transition_phase finalizing receipt_published ||
      die 'failed to publish accepted receipt phase'
    fixture_interrupt_after accepted-receipt-phase-published
  fi
  if test "$prior_overlay" != "$overlay_file"; then
    if sudo test -e "$prior_overlay_path" || sudo test -L "$prior_overlay_path"; then
      assert_owned_regular "$prior_overlay_path" boot || die 'prior accepted overlay is unsafe'
      test "$(sha "$prior_overlay_path")" = "$prior_overlay_sha" ||
        die 'prior accepted overlay drifted'
      sudo rm -- "$prior_overlay_path" || die 'failed to retire prior installed overlay'
    fi
  fi
  fixture_interrupt_after accepted-prior-retired
  sudo rm -- "$accepted_transition" || die 'failed to clear accepted transition journal'
  fixture_interrupt_after accepted-journal-cleared
  sudo rm -- "$accepted_transition_prior_config" ||
    die 'failed to clear accepted transition config'
  sudo sync
  assert_accepted_state || die 'accepted receipt failed validation'
  printf 'accepted %s\n' "$revision"
}

accepted_uninstall_value() {
  local key="$1"
  assert_owned_regular "$accepted_uninstall" 600 || return
  sudo awk -F= -v wanted="$key" '$1 == wanted { print $2 }' "$accepted_uninstall"
}

assert_accepted_uninstall() {
  local key count schema phase version revision release artifact detached prior marker
  local -a keys=()

  assert_owned_regular "$accepted_uninstall" 600 || return
  assert_owned_regular "$accepted_uninstall_stock" 600 || return
  schema="$(accepted_uninstall_value schema_version)"
  case "$schema" in
    2) keys=("${accepted_uninstall_keys_v2[@]}") ;;
    3) keys=("${accepted_uninstall_keys[@]}") ;;
    *) return 1 ;;
  esac
  test "$(sudo awk 'END { print NR }' "$accepted_uninstall")" = \
    "${#keys[@]}" || return
  sudo awk -F= 'NF != 2 || $1 == "" || $2 == "" { exit 1 }' "$accepted_uninstall" || return
  for key in "${keys[@]}"; do
    count="$(sudo awk -F= -v wanted="$key" '$1 == wanted { count++ } END { print count + 0 }' "$accepted_uninstall")"
    test "$count" = 1 || return
  done
  phase="$(accepted_uninstall_value phase)"
  case "$phase" in prepared|boot_restored|dkms_restored|module_removed|overlay_removed|artifact_detached|receipt_removed|artifact_removed) ;; *) return 1;; esac
  version="$(accepted_uninstall_value driver_version)"
  revision="$(accepted_uninstall_value source_revision)"
  release="$(accepted_uninstall_value kernel_release)"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return
  [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || return
  [[ "$release" =~ ^[A-Za-z0-9._+-]+$ ]] || return
  for key in manifest_sha256 module_sha256 overlay_sha256 stock_config_sha256; do
    [[ "$(accepted_uninstall_value "$key")" =~ ^[0-9a-f]{64}$ ]] || return
  done
  test "$(accepted_uninstall_value module_file)" = hyperpixel2r_kms.ko || return
  test "$(accepted_uninstall_value overlay_file)" = \
    "hyperpixel2r-kms-${revision:0:12}.dtbo" || return
  case "$(accepted_uninstall_value dkms_status)" in absent|unregistered|registered) ;; *) return 1;; esac
  case "$(accepted_uninstall_value prior_dkms_status)" in
    absent|unregistered|registered|added|built|installed) ;;
    *) return 1 ;;
  esac
  case "$(accepted_uninstall_value artifact_prior)" in true|false) ;; *) return 1;; esac
  test "$(sha "$accepted_uninstall_stock")" = \
    "$(accepted_uninstall_value stock_config_sha256)" || return
  artifact="$artifact_root/$version/$revision/$release"
  detached="${artifact}.accepted-uninstall"
  prior="$(accepted_uninstall_value artifact_prior)"
  if sudo test -e "$artifact" || sudo test -L "$artifact"; then
    assert_artifact_tree "$artifact" "$prior" || return
    test "$(sha "$artifact/manifest.txt")" = \
      "$(accepted_uninstall_value manifest_sha256)" || return
    marker="$artifact/dkms-prior-state"
  elif sudo test -e "$detached" || sudo test -L "$detached"; then
    assert_artifact_tree "$detached" "$prior" || return
    test "$(sha "$detached/manifest.txt")" = \
      "$(accepted_uninstall_value manifest_sha256)" || return
    marker="$detached/dkms-prior-state"
  else
    case "$phase" in receipt_removed|artifact_removed) ;; *) return 1;; esac
  fi
  if test "$schema" = 3; then
    [[ "$(accepted_uninstall_value prior_dkms_inventory_sha256)" =~ ^[0-9a-f]{64}$ ]] ||
      return
    if test -n "${marker:-}"; then
      test "$(sha "$marker")" = \
        "$(accepted_uninstall_value prior_dkms_inventory_sha256)" || return
    fi
  elif test -n "${marker:-}"; then
    test "$(sudo sed -n '1p' "$marker")" != schema_version=2 || return
  fi
}

set_accepted_uninstall_phase() {
  local expected="$1"
  local next="$2"
  local workspace state_tmp state_sha
  assert_accepted_uninstall || return
  test "$(accepted_uninstall_value phase)" = "$expected" || return
  workspace="$(new_transaction_workspace)" || return
  accepted_workspace="$workspace"
  state_tmp="$(private_file "$workspace" accepted-uninstall)" || return
  sudo sed -e "s/^phase=$expected\$/phase=$next/" "$accepted_uninstall" |
    sudo tee "$state_tmp" >/dev/null || return
  state_sha="$(sha "$state_tmp")" || return
  atomic_copy "$state_tmp" "$accepted_uninstall" 600 "$state_sha" || return
  remove_transaction_workspace "$workspace" || return
  accepted_workspace=''
  assert_accepted_uninstall
}

assert_accepted_receipt_matches_uninstall() {
  local key count schema journal_schema
  local -a keys=()
  assert_owned_regular "$accepted_state" 600 || return
  assert_owned_regular "$accepted_stock_config" 600 || return
  schema="$(accepted_value schema_version)"
  journal_schema="$(accepted_uninstall_value schema_version)"
  case "$schema:$journal_schema" in
    1:2) keys=("${accepted_keys_v1[@]}") ;;
    2:3) keys=("${accepted_keys[@]}") ;;
    *) return 1 ;;
  esac
  test "$(sudo awk 'END { print NR }' "$accepted_state")" = "${#keys[@]}" || return
  for key in "${keys[@]}"; do
    count="$(sudo awk -F= -v wanted="$key" '$1 == wanted { count++ } END { print count + 0 }' "$accepted_state")"
    test "$count" = 1 || return
  done
  test "$(accepted_value driver_version)" = "$(accepted_uninstall_value driver_version)" || return
  test "$(accepted_value source_revision)" = "$(accepted_uninstall_value source_revision)" || return
  test "$(accepted_value kernel_release)" = "$(accepted_uninstall_value kernel_release)" || return
  test "$(accepted_value manifest_sha256)" = "$(accepted_uninstall_value manifest_sha256)" || return
  test "$(accepted_value module_file)" = "$(accepted_uninstall_value module_file)" || return
  test "$(accepted_value module_sha256)" = "$(accepted_uninstall_value module_sha256)" || return
  test "$(accepted_value overlay_file)" = "$(accepted_uninstall_value overlay_file)" || return
  test "$(accepted_value overlay_sha256)" = "$(accepted_uninstall_value overlay_sha256)" || return
  if test "$schema" = 2; then
    test "$(accepted_value prior_dkms_inventory_sha256)" = \
      "$(accepted_uninstall_value prior_dkms_inventory_sha256)" || return
  fi
  test "$(sha "$accepted_stock_config")" = "$(accepted_value stock_config_sha256)" || return
}

uninstall_accepted() {
  local version="$1"
  local revision="$2"
  local release="$3"
  local artifact detached manifest module_file module_sha overlay_file overlay_sha
  local module_path overlay_path workspace current_snapshot boot_candidate boot_sha prior=false
  local prior_dkms_state_value prior_dkms_inventory_sha receipt_schema journal_schema
  local dkms_dir dkms_status state_tmp state_sha phase current_status

  test ! -L "$state_file" && test ! -e "$state_file" ||
    die 'refusing accepted uninstall while a tryboot transaction is active'
  test ! -L "$accepted_transition" && test ! -e "$accepted_transition" ||
    die 'refusing accepted uninstall while a transition is active'
  if ! sudo test -e "$accepted_uninstall" && ! sudo test -L "$accepted_uninstall"; then
    assert_accepted_state || die 'accepted driver state is missing or unsafe'
    test "$(accepted_value driver_version)" = "$version" &&
      test "$(accepted_value source_revision)" = "$revision" &&
      test "$(accepted_value kernel_release)" = "$release" ||
      die 'requested uninstall identity is not accepted'
    test ! -L "$accepted_uninstall_stock" && test ! -e "$accepted_uninstall_stock" ||
      die 'orphan accepted uninstall stock exists'
    artifact="$artifact_root/$version/$revision/$release"
    manifest="$artifact/manifest.txt"
    module_file="$(accepted_value module_file)"
    module_sha="$(accepted_value module_sha256)"
    overlay_file="$(accepted_value overlay_file)"
    overlay_sha="$(accepted_value overlay_sha256)"
    module_path="${root}/lib/modules/$release/extra/$module_file"
    overlay_path="${root}/boot/firmware/overlays/$overlay_file"
    assert_owned_regular "$module_path" 644 || die 'accepted module is unsafe'
    assert_owned_regular "$overlay_path" boot || die 'accepted overlay is unsafe'
    test "$(sha "$module_path")" = "$module_sha" || die 'accepted module drifted'
    test "$(sha "$overlay_path")" = "$overlay_sha" || die 'accepted overlay drifted'
    prior_dkms_state_value="$(dkms_prior_state "$artifact")" ||
      die 'accepted prior DKMS state is unsafe'
    receipt_schema="$(accepted_value schema_version)"
    if test "$receipt_schema" = 2; then
      prior_dkms_inventory_sha="$(accepted_value prior_dkms_inventory_sha256)"
      test "$(sha "$artifact/dkms-prior-state")" = "$prior_dkms_inventory_sha" ||
        die 'accepted DKMS inventory differs from its receipt'
      journal_schema=3
    else
      test "$receipt_schema" = 1 ||
        die 'accepted receipt schema is unsafe'
      test "$(sudo sed -n '1p' "$artifact/dkms-prior-state")" != schema_version=2 ||
        die 'legacy accepted receipt cannot authorize a full DKMS inventory'
      prior_dkms_inventory_sha=''
      journal_schema=2
    fi
    dkms_dir="$dkms_root/hyperpixel2r-kms-$version"
    assert_source_tree_shape "$dkms_dir" "$artifact/dkms-source" ||
      die 'active DKMS source is not the accepted source'
    dkms_status="$(validate_dkms_status "$version")" || die 'accepted DKMS state is invalid'
    if sudo test -e "$artifact/prior-tryboot.txt"; then prior=true; fi
    workspace="$(new_transaction_workspace)" || die 'failed to create accepted uninstall workspace'
    accepted_workspace="$workspace"
    current_snapshot="$(privileged_snapshot "$normal_config" "$workspace" uninstall-normal)" ||
      die 'failed to snapshot normal boot config'
    boot_candidate="$(private_file "$workspace" uninstall-stock)" ||
      die 'failed to allocate uninstall boot config'
    if test "$(sha "$current_snapshot")" = "$(accepted_value normal_config_sha256)"; then
      atomic_copy "$accepted_stock_config" "$boot_candidate" 600 \
        "$(accepted_value stock_config_sha256)" ||
        die 'failed to prepare proven stock config'
    else
      write_surgical_stock_config "$current_snapshot" "$overlay_file" "$boot_candidate" "$workspace" ||
        die 'changed boot config cannot be separated from the accepted driver'
    fi
    boot_sha="$(sha "$boot_candidate")"
    atomic_copy "$boot_candidate" "$accepted_uninstall_stock" 600 "$boot_sha" ||
      die 'failed to publish accepted uninstall stock'
    state_tmp="$(private_file "$workspace" accepted-uninstall)" ||
      die 'failed to allocate accepted uninstall journal'
    {
      printf 'schema_version=%s\n' "$journal_schema"
      printf 'phase=prepared\n'
      printf 'driver_version=%s\n' "$version"
      printf 'source_revision=%s\n' "$revision"
      printf 'kernel_release=%s\n' "$release"
      printf 'manifest_sha256=%s\n' "$(sha "$manifest")"
      printf 'module_file=%s\n' "$module_file"
      printf 'module_sha256=%s\n' "$module_sha"
      printf 'overlay_file=%s\n' "$overlay_file"
      printf 'overlay_sha256=%s\n' "$overlay_sha"
      printf 'stock_config_sha256=%s\n' "$boot_sha"
      printf 'dkms_status=%s\n' "$dkms_status"
      printf 'prior_dkms_status=%s\n' "$prior_dkms_state_value"
      printf 'artifact_prior=%s\n' "$prior"
      if test "$journal_schema" = 3; then
        printf 'prior_dkms_inventory_sha256=%s\n' "$prior_dkms_inventory_sha"
      fi
    } | sudo tee "$state_tmp" >/dev/null || die 'failed to write accepted uninstall journal'
    state_sha="$(sha "$state_tmp")"
    atomic_copy "$state_tmp" "$accepted_uninstall" 600 "$state_sha" ||
      die 'failed to publish accepted uninstall journal'
    remove_transaction_workspace "$workspace" || die 'failed to remove accepted uninstall workspace'
    accepted_workspace=''
    assert_accepted_uninstall || die 'accepted uninstall journal failed validation'
    fixture_interrupt_after uninstall-journal-published
  else
    assert_accepted_uninstall || die 'accepted uninstall journal is unsafe'
    test "$(accepted_uninstall_value driver_version)" = "$version" &&
      test "$(accepted_uninstall_value source_revision)" = "$revision" &&
      test "$(accepted_uninstall_value kernel_release)" = "$release" ||
      die 'requested uninstall identity differs from active journal'
  fi

  artifact="$artifact_root/$version/$revision/$release"
  detached="${artifact}.accepted-uninstall"
  module_file="$(accepted_uninstall_value module_file)"
  module_sha="$(accepted_uninstall_value module_sha256)"
  overlay_file="$(accepted_uninstall_value overlay_file)"
  overlay_sha="$(accepted_uninstall_value overlay_sha256)"
  module_path="${root}/lib/modules/$release/extra/$module_file"
  overlay_path="${root}/boot/firmware/overlays/$overlay_file"
  dkms_dir="$dkms_root/hyperpixel2r-kms-$version"
  phase="$(accepted_uninstall_value phase)"
  if test "$phase" = prepared; then
    atomic_copy "$accepted_uninstall_stock" "$normal_config" 644 \
      "$(accepted_uninstall_value stock_config_sha256)" true ||
      die 'failed to publish stock normal boot config'
    fixture_interrupt_after uninstall-boot-restored
    set_accepted_uninstall_phase prepared boot_restored ||
      die 'failed to publish boot-restored uninstall phase'
    phase=boot_restored
  fi
  if test "$phase" = boot_restored; then
    if sudo test -e "$dkms_dir" || sudo test -L "$dkms_dir"; then
      if assert_source_tree_shape "$dkms_dir" "$artifact/dkms-source" 2>/dev/null; then
        current_status="$(validate_dkms_status "$version")" || die 'active DKMS status is invalid'
        if test "$current_status" = registered; then
          run_dkms remove -m hyperpixel2r-kms -v "$version" --all ||
            die 'failed to remove accepted DKMS registration'
        fi
        remove_exact_tree "$dkms_dir" || die 'failed to remove accepted DKMS source'
      elif test "$(accepted_uninstall_value prior_dkms_status)" != absent &&
        assert_source_tree_shape "$dkms_dir" "$artifact/prior-dkms" 2>/dev/null; then
        :
      else
        die 'DKMS source is neither accepted nor proven prior'
      fi
    fi
    if test "$(accepted_uninstall_value prior_dkms_status)" != absent; then
      restore_dkms_source_state "$artifact/dkms-prior-state" "$artifact/prior-dkms" \
        "$dkms_dir" true "$version" "$release" ||
        die 'failed to restore complete prior DKMS inventory'
    fi
    fixture_interrupt_after uninstall-dkms-restored
    set_accepted_uninstall_phase boot_restored dkms_restored ||
      die 'failed to publish DKMS-restored uninstall phase'
    phase=dkms_restored
  fi
  if test "$phase" = dkms_restored; then
    if sudo test -e "$module_path" || sudo test -L "$module_path"; then
      assert_owned_regular "$module_path" 644 || die 'accepted module became unsafe'
      test "$(sha "$module_path")" = "$module_sha" || die 'accepted module drifted'
      sudo rm -- "$module_path" || die 'failed to remove accepted module'
    fi
    fixture_interrupt_after uninstall-module-removed
    set_accepted_uninstall_phase dkms_restored module_removed ||
      die 'failed to publish module-removed uninstall phase'
    phase=module_removed
  fi
  if test "$phase" = module_removed; then
    if sudo test -e "$overlay_path" || sudo test -L "$overlay_path"; then
      assert_owned_regular "$overlay_path" boot || die 'accepted overlay became unsafe'
      test "$(sha "$overlay_path")" = "$overlay_sha" || die 'accepted overlay drifted'
      sudo rm -- "$overlay_path" || die 'failed to remove accepted overlay'
    fi
    fixture_interrupt_after uninstall-overlay-removed
    set_accepted_uninstall_phase module_removed overlay_removed ||
      die 'failed to publish overlay-removed uninstall phase'
    phase=overlay_removed
  fi
  if test "$phase" = overlay_removed; then
    if sudo test -e "$artifact" || sudo test -L "$artifact"; then
      assert_artifact_tree "$artifact" "$(accepted_uninstall_value artifact_prior)" ||
        die 'accepted artifact became unsafe'
      test ! -L "$detached" && test ! -e "$detached" ||
        die 'accepted artifact tombstone already exists'
      sudo mv -- "$artifact" "$detached" || die 'failed to detach accepted artifact'
    fi
    fixture_interrupt_after uninstall-artifact-detached
    set_accepted_uninstall_phase overlay_removed artifact_detached ||
      die 'failed to publish artifact-detached uninstall phase'
    phase=artifact_detached
  fi
  if test "$phase" = artifact_detached; then
    if sudo test -e "$accepted_state" || sudo test -L "$accepted_state"; then
      assert_accepted_receipt_matches_uninstall || die 'accepted receipt became unsafe'
      sudo rm -- "$accepted_state" || die 'failed to remove accepted receipt'
    fi
    fixture_interrupt_after uninstall-receipt-removed
    if sudo test -e "$accepted_stock_config" || sudo test -L "$accepted_stock_config"; then
      assert_owned_regular "$accepted_stock_config" 600 || die 'accepted stock became unsafe'
      sudo rm -- "$accepted_stock_config" || die 'failed to remove accepted stock receipt'
    fi
    set_accepted_uninstall_phase artifact_detached receipt_removed ||
      die 'failed to publish receipt-removed uninstall phase'
  fi
  sudo depmod -a "$release"
  sudo sync
  printf 'uninstalled accepted %s\n' "$revision"
}

finalize_uninstall_accepted() {
  local version revision release artifact detached phase

  if ! sudo test -e "$accepted_uninstall" && ! sudo test -L "$accepted_uninstall"; then
    if sudo test -e "$accepted_uninstall_stock" || sudo test -L "$accepted_uninstall_stock"; then
      assert_owned_regular "$accepted_uninstall_stock" 600 ||
        die 'orphan accepted uninstall stock is unsafe'
      sudo rm -- "$accepted_uninstall_stock" ||
        die 'failed to clear orphan accepted uninstall stock'
    fi
    printf 'accepted uninstall already finalized\n'
    return
  fi
  assert_accepted_uninstall || die 'accepted uninstall journal is unsafe'
  phase="$(accepted_uninstall_value phase)"
  case "$phase" in receipt_removed|artifact_removed) ;; *)
    die 'accepted uninstall is not ready to finalize'
    ;;
  esac
  version="$(accepted_uninstall_value driver_version)"
  revision="$(accepted_uninstall_value source_revision)"
  release="$(accepted_uninstall_value kernel_release)"
  artifact="$artifact_root/$version/$revision/$release"
  detached="${artifact}.accepted-uninstall"
  if test "$phase" = receipt_removed; then
    test ! -L "$artifact" && test ! -e "$artifact" ||
      die 'accepted artifact was republished after detach'
    if sudo test -e "$detached" || sudo test -L "$detached"; then
      assert_artifact_tree "$detached" "$(accepted_uninstall_value artifact_prior)" ||
        die 'detached accepted artifact is unsafe'
      sudo rm -rf -- "$detached" || die 'failed to remove detached accepted artifact'
    fi
    fixture_interrupt_after uninstall-artifact-removed
    set_accepted_uninstall_phase receipt_removed artifact_removed ||
      die 'failed to publish artifact-removed uninstall phase'
  fi
  sudo rm -- "$accepted_uninstall" || die 'failed to clear accepted uninstall journal'
  fixture_interrupt_after uninstall-journal-cleared
  sudo rm -- "$accepted_uninstall_stock" ||
    die 'failed to clear accepted uninstall stock'
  sudo sync
  printf 'finalized accepted uninstall %s\n' "$revision"
}

retire_inactive_accepted() {
  local version="$1"
  local revision="$2"
  local release="$3"
  local artifact manifest module_file overlay_file module_path overlay_path prior=false

  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'unsafe inactive driver version'
  [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || die 'unsafe inactive source revision'
  [[ "$release" =~ ^[A-Za-z0-9._+-]+$ ]] || die 'unsafe inactive kernel release'
  test ! -L "$accepted_state" && test ! -e "$accepted_state" ||
    die 'refusing inactive retirement while a driver is accepted'
  test ! -L "$accepted_transition" && test ! -e "$accepted_transition" ||
    die 'refusing inactive retirement during a transition'
  test ! -L "$state_file" && test ! -e "$state_file" ||
    die 'refusing inactive retirement during a legacy transition'
  artifact="$artifact_root/$version/$revision/$release"
  if ! sudo test -e "$artifact" && ! sudo test -L "$artifact"; then
    printf 'inactive artifact already retired %s\n' "$revision"
    return
  fi
  if sudo test -L "$artifact/prior-tryboot.txt"; then die 'unsafe inactive prior tryboot receipt'
  elif sudo test -e "$artifact/prior-tryboot.txt"; then prior=true
  fi
  assert_artifact_tree "$artifact" "$prior" || die 'inactive artifact bundle is unsafe'
  manifest="$artifact/manifest.txt"
  test "$(manifest_value "$manifest" driver_version)" = "$version" || die 'inactive version differs'
  test "$(manifest_value "$manifest" source_revision)" = "$revision" || die 'inactive revision differs'
  test "$(manifest_value "$manifest" kernel_release)" = "$release" || die 'inactive kernel differs'
  module_file="$(manifest_value "$manifest" module_file)"
  overlay_file="$(manifest_value "$manifest" overlay_file)"
  module_path="${root}/lib/modules/$release/extra/$module_file"
  overlay_path="${root}/boot/firmware/overlays/$overlay_file"
  test ! -L "$module_path" && test ! -e "$module_path" ||
    die 'inactive module is still installed'
  test ! -L "$overlay_path" && test ! -e "$overlay_path" ||
    die 'inactive overlay is still installed'
  require_regular "$normal_config" || die 'normal config is unsafe'
  test "$(sudo awk -v wanted="dtoverlay=$overlay_file" '
    { line=$0; sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line); if (line == wanted) count++ }
    END { print count + 0 }
  ' "$normal_config")" = 0 || die 'inactive overlay remains configured'
  remove_artifact_tree "$artifact" "$prior" || die 'failed to retire inactive artifact bundle'
  sudo sync
  printf 'retired inactive %s\n' "$revision"
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

if test "${1-}" != rollback; then
  if sudo test -e "$rollback_state" || sudo test -L "$rollback_state" ||
    sudo test -e "$rollback_candidate_inventory" || sudo test -L "$rollback_candidate_inventory" ||
    sudo test -e "$rollback_candidate_tryboot" || sudo test -L "$rollback_candidate_tryboot"; then
    die 'an unresolved durable rollback blocks this lifecycle action'
  fi
fi

case "${1-}" in
  stage) shift; stage "$@" ;;
  identity) identity ;;
  commit) commit ;;
  rollback) rollback ;;
  record-accepted) shift; record_accepted "$@" ;;
  prepare-new-accepted) shift; prepare_new_accepted "$@" ;;
  mark-committed-accepted) mark_committed_accepted ;;
  stage-retained) shift; stage_retained "$@" ;;
  commit-retained) commit_retained ;;
  recover-accepted) recover_accepted ;;
  mark-verified-accepted) mark_verified_accepted ;;
  finalize-accepted) finalize_accepted ;;
  uninstall-accepted) shift; uninstall_accepted "$@" ;;
  finalize-uninstall-accepted) finalize_uninstall_accepted ;;
  retire-inactive) shift; retire_inactive_accepted "$@" ;;
  uninstall) uninstall ;;
  cleanup-legacy-planeradar) shift; cleanup_legacy_planeradar "$@" ;;
  *) die 'usage: lifecycle-remote.sh {stage|identity|commit|rollback|record-accepted|prepare-new-accepted|mark-committed-accepted|stage-retained|commit-retained|recover-accepted|mark-verified-accepted|finalize-accepted|uninstall-accepted|finalize-uninstall-accepted|retire-inactive|uninstall|cleanup-legacy-planeradar}' ;;
esac
