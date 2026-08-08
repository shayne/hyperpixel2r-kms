#!/usr/bin/env bash

HP2R_DRIVER_VERSION="0.2.0"
HP2R_DEFAULT_BUILD_IMAGE="hyperpixel2r-kms-kernel-builder:debian-trixie-gcc14"
HP2R_BACKLIGHT_CAPABILITY="pwm-backlight-v1"
HP2R_LIFECYCLE_CAPABILITY="exact-backlight-metadata-v1"
HP2R_BACKLIGHT_RULE_FILE="70-hyperpixel2r-backlight.rules"

hp2r_validate_target() {
  local target="${1-}"

  case "$target" in
    ""|-*|*[!A-Za-z0-9._@%:+-]*)
      echo "unsafe SSH target: $target" >&2
      return 1
      ;;
  esac
}

hp2r_validate_release() {
  local release="${1-}"

  case "$release" in
    ""|"."|".."|*[!A-Za-z0-9._+-]*)
      echo "unsafe kernel release returned by target: $release" >&2
      return 1
      ;;
  esac
}

hp2r_release_path() {
  local parent="$1"
  local release="$2"
  local parent_path
  local release_path

  hp2r_validate_release "$release" || return
  parent_path="$(cd "$parent" && pwd -P)" || return
  release_path="$parent_path/$release"
  if test -L "$release_path"; then
    echo "symlinked kernel release destination is unsafe: $release_path" >&2
    return 1
  fi
  if test -e "$release_path"; then
    test -d "$release_path" || {
      echo "kernel release destination is not a directory: $release_path" >&2
      return 1
    }
    release_path="$(cd "$release_path" && pwd -P)" || return
  fi
  case "$release_path" in
    "$parent_path"/*) ;;
    *)
      echo "kernel release path escapes fixed parent: $release_path" >&2
      return 1
      ;;
  esac
  printf '%s\n' "$release_path"
}

hp2r_validate_target_path() {
  local path="${1-}"

  case "$path" in
    /*)
      case "/$path/" in
        *"/../"*|*"/./"*|*[!A-Za-z0-9._/+:-]*)
          echo "unsafe path returned by target: $path" >&2
          return 1
          ;;
      esac
      ;;
    *)
      echo "target path is not absolute: $path" >&2
      return 1
      ;;
  esac
}

hp2r_validate_artifact_name() {
  local name="${1-}"

  case "$name" in
    ""|"."|".."|/*|*/*|*\\*|*[$'\t\r\n ']*)
      echo "unsafe artifact path: $name" >&2
      return 1
      ;;
  esac
}

hp2r_require_regular() {
  local file="$1"

  test ! -L "$file" && test -f "$file" || {
    echo "required regular file is missing or a symlink: $file" >&2
    return 1
  }
}

hp2r_sha256() {
  local file="$1"

  hp2r_require_regular "$file" || return
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{ print $1 }'
  else
    shasum -a 256 "$file" | awk '{ print $1 }'
  fi
}

hp2r_verify_sha256() {
  local file="$1"
  local expected="$2"
  local label="${3:-artifact}"
  local actual

  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || {
    echo "$label checksum is not lowercase SHA-256" >&2
    return 1
  }
  actual="$(hp2r_sha256 "$file")" || return
  test "$actual" = "$expected" || {
    echo "$label checksum mismatch for $file" >&2
    return 1
  }
}

hp2r_write_checksum() {
  local file="$1"
  local output="$2"

  printf '%s  %s\n' "$(hp2r_sha256 "$file")" "$(basename "$file")" > "$output"
}

hp2r_validate_backlight_rule() {
  local rule="$1"

  hp2r_require_regular "$rule" || return
  cmp -s "$rule" <(
    printf '%s\n' 'SUBSYSTEM=="backlight", KERNEL=="hyperpixel2r-backlight", RUN+="/usr/bin/chgrp video /sys%p/brightness", RUN+="/usr/bin/chmod 0660 /sys%p/brightness"'
  ) || {
    echo "backlight rule is not the exact narrow permission contract" >&2
    return 1
  }
}

hp2r_validate_checksum_file() {
  local checksum_file="$1"
  local artifact="$2"
  local expected_line

  hp2r_require_regular "$checksum_file" && hp2r_require_regular "$artifact" || {
    echo "checksum evidence is missing" >&2
    return 1
  }
  expected_line="$(printf '%s  %s' "$(hp2r_sha256 "$artifact")" "$(basename "$artifact")")"
  test "$(awk 'END { print NR }' "$checksum_file")" -eq 1 &&
    test "$(cat "$checksum_file")" = "$expected_line" || {
      echo "checksum evidence does not exactly match $(basename "$artifact")" >&2
      return 1
    }
}

hp2r_require_clean_source() {
  git diff-index --quiet HEAD -- || {
    echo "tracked source is dirty; commit the exact source before building artifacts" >&2
    return 1
  }
}

hp2r_require_durable_source_revision() {
  local revision="$1"
  local ref

  git cat-file -e "$revision^{commit}" 2>/dev/null || {
    echo "source revision is not an available commit: $revision" >&2
    return 1
  }
  while IFS= read -r ref; do
    case "$ref" in
      refs/heads/gitbutler/*|refs/remotes/*/gitbutler/*) continue ;;
    esac
    if git merge-base --is-ancestor "$revision" "$ref"; then
      return 0
    fi
  done < <(git for-each-ref --format='%(refname)' refs/heads refs/remotes refs/tags)

  echo "source revision is not reachable from a durable branch, remote-tracking ref, or tag: $revision" >&2
  return 1
}

hp2r_resolve_build_revision() {
  local workspace_revision
  local workspace_tree
  local workspace_subject
  local candidate_ref
  local candidate_revision
  local candidate_tree
  local -a candidates=()

  workspace_revision="$(git rev-parse HEAD)" || return
  workspace_tree="$(git rev-parse 'HEAD^{tree}')" || return
  workspace_subject="$(git show -s --format=%s "$workspace_revision")" || return
  if test "$workspace_subject" != 'GitButler Workspace Commit'; then
    printf '%s\n' "$workspace_revision"
    return
  fi

  while read -r candidate_ref candidate_revision; do
    case "$candidate_ref" in
      refs/heads/gitbutler/*) continue ;;
    esac
    candidate_tree="$(git rev-parse "$candidate_revision^{tree}")" || return
    test "$candidate_tree" = "$workspace_tree" || continue
    candidates+=("$candidate_revision")
  done < <(git for-each-ref --format='%(refname) %(objectname)' refs/heads)

  if test "${#candidates[@]}" -ne 1; then
    echo "GitButler workspace does not have one stable source revision; pass --source-revision" >&2
    return 1
  fi
  printf '%s\n' "${candidates[0]}"
}

hp2r_validate_source_identity() {
  local source_revision="$1"
  local source_tree="$2"
  local overlay_file="$3"
  local expected_revision="$4"
  local expected_tree="$5"

  [[ "$source_revision" =~ ^[0-9a-f]{40}$ ]] || {
    echo "source revision is not a 40-character hexadecimal Git object ID" >&2
    return 1
  }
  test "$source_revision" = "$expected_revision" || {
    echo "source revision does not match checked source" >&2
    return 1
  }
  [[ "$source_tree" =~ ^[0-9a-f]{40}$ ]] || {
    echo "source tree is not a 40-character hexadecimal Git object ID" >&2
    return 1
  }
  test "$source_tree" = "$expected_tree" || {
    echo "source tree does not match checked source" >&2
    return 1
  }
  test "$overlay_file" = \
    "hyperpixel2r-kms-${source_revision:0:12}.dtbo" || {
    echo "overlay filename does not match source revision" >&2
    return 1
  }
}

hp2r_validate_host_helper() {
  local helper="$1"
  local expected_machine="$2"
  local expected_status="$3"
  local machine
  local helper_status

  hp2r_require_regular "$helper" && test -x "$helper" || {
    echo "host helper is missing or not executable: $helper" >&2
    return 1
  }
  command -v readelf >/dev/null 2>&1 || {
    echo "missing host-tool prerequisite: readelf" >&2
    return 1
  }
  machine="$(
    readelf -h "$helper" |
      awk -F ': *' '$1 ~ /^[[:space:]]*Machine$/ { print $2; exit }'
  )"
  test "$machine" = "$expected_machine" || {
    echo "host helper has the wrong architecture: $helper ($machine)" >&2
    return 1
  }
  set +e
  "$helper" </dev/null >/dev/null 2>&1
  helper_status="$?"
  set -e
  test "$helper_status" -eq "$expected_status" || {
    echo "host helper is not executable in the build container: $helper" >&2
    return 1
  }
}

hp2r_manifest_value() {
  local manifest="$1"
  local key="$2"

  hp2r_require_regular "$manifest" || return
  awk -F '\t' -v wanted="$key" '$1 == wanted { print $2 }' "$manifest"
}

hp2r_validate_exact_manifest_rows() {
  local manifest="$1"
  shift
  local required_keys=("$@")
  local key
  local count

  hp2r_require_regular "$manifest" || {
    echo "manifest is missing: $manifest" >&2
    return 1
  }
  test "$(awk 'END { print NR }' "$manifest")" -eq "${#required_keys[@]}" || {
    echo "manifest schema has the wrong cardinality" >&2
    return 1
  }
  awk -F '\t' 'NF != 2 || $1 == "" || $2 == "" { exit 1 }' "$manifest" || {
    echo "manifest schema has an invalid or trailing-data row" >&2
    return 1
  }
  for key in "${required_keys[@]}"; do
    count="$(
      awk -F '\t' -v wanted="$key" \
        '$1 == wanted { count++ } END { print count + 0 }' \
        "$manifest"
    )"
    test "$count" -eq 1 || {
      echo "manifest schema requires exactly one $key" >&2
      return 1
    }
  done
}

hp2r_validate_release_source() {
  local root="$1"
  local expected_revision="$2"
  local expected_tree="$3"
  local identity="$root/release/source-identity.txt"

  [[ "$expected_revision" =~ ^[0-9a-f]{40}$ ]] &&
    [[ "$expected_tree" =~ ^[0-9a-f]{40}$ ]] || {
      echo "expected release source identity is invalid" >&2
      return 1
    }
  hp2r_validate_exact_manifest_rows \
    "$identity" \
    schema_version \
    repository \
    source_revision \
    source_tree || return
  test "$(hp2r_manifest_value "$identity" schema_version)" = 1 &&
    test "$(hp2r_manifest_value "$identity" repository)" = \
      https://github.com/shayne/hyperpixel2r-kms &&
    test "$(hp2r_manifest_value "$identity" source_revision)" = \
      "$expected_revision" &&
    test "$(hp2r_manifest_value "$identity" source_tree)" = \
      "$expected_tree" || {
      echo "release source identity does not match the locked release" >&2
      return 1
    }
}

hp2r_release_source_available() {
  local root="$1"
  local identity="$root/release/source-identity.txt"

  test ! -L "$identity" && test -f "$identity"
}

hp2r_release_source_file() {
  local root="$1"
  local relative="$2"
  local current="$root"
  local part
  local -a parts

  case "$relative" in
    ""|/*|*\\*|*[$'\t\r\n']*|*".."*)
      echo "unsafe release source path: $relative" >&2
      return 1
      ;;
  esac
  IFS=/ read -r -a parts <<< "$relative"
  for part in "${parts[@]}"; do
    test -n "$part" || return 1
    current="$current/$part"
    test ! -L "$current" || {
      echo "release source path contains a symlink: $relative" >&2
      return 1
    }
  done
  test -f "$current" || {
    echo "release source file is missing: $relative" >&2
    return 1
  }
  printf '%s\n' "$current"
}

hp2r_validate_artifact_manifest() {
  local manifest="$1"
  local required_keys_v2=(
    schema_version
    driver_version
    source_revision
    source_tree
    kernel_release
    architecture
    base_dtb_sha256
    capability
    module_file
    module_sha256
    module_vermagic
    overlay_file
    overlay_sha256
    applied_dtb_file
    applied_dtb_sha256
    backlight_rule_file
    backlight_rule_sha256
  )
  local required_keys=()
  local key
  local value
  local release
  local source_revision

  case "$(hp2r_manifest_value "$manifest" schema_version)" in
    2) required_keys=("${required_keys_v2[@]}") ;;
    3) required_keys=("${required_keys_v2[@]}" lifecycle_capability) ;;
    *) echo "unsupported artifact manifest schema version" >&2; return 1 ;;
  esac
  hp2r_validate_exact_manifest_rows "$manifest" "${required_keys[@]}" || return
  test "$(hp2r_manifest_value "$manifest" driver_version)" = \
    "$HP2R_DRIVER_VERSION" || {
    echo "artifact driver version is unsupported" >&2
    return 1
  }
  source_revision="$(hp2r_manifest_value "$manifest" source_revision)"
  [[ "$source_revision" =~ ^[0-9a-f]{40}$ ]] || {
    echo "artifact source revision is invalid" >&2
    return 1
  }
  value="$(hp2r_manifest_value "$manifest" source_tree)"
  [[ "$value" =~ ^[0-9a-f]{40}$ ]] || {
    echo "artifact source tree is invalid" >&2
    return 1
  }
  release="$(hp2r_manifest_value "$manifest" kernel_release)"
  hp2r_validate_release "$release" || return
  test "$(hp2r_manifest_value "$manifest" architecture)" = aarch64 || {
    echo "artifact architecture must be aarch64" >&2
    return 1
  }
  test "$(hp2r_manifest_value "$manifest" capability)" = \
    "$HP2R_BACKLIGHT_CAPABILITY" || {
    echo "artifact capability is unsupported" >&2
    return 1
  }
  if test "$(hp2r_manifest_value "$manifest" schema_version)" = 3; then
    test "$(hp2r_manifest_value "$manifest" lifecycle_capability)" = \
      "$HP2R_LIFECYCLE_CAPABILITY" || {
      echo "artifact lifecycle capability is unsupported" >&2
      return 1
    }
  fi
  for key in \
    base_dtb_sha256 \
    module_sha256 \
    overlay_sha256 \
    applied_dtb_sha256 \
    backlight_rule_sha256
  do
    value="$(hp2r_manifest_value "$manifest" "$key")"
    [[ "$value" =~ ^[0-9a-f]{64}$ ]] || {
      echo "artifact $key is not lowercase SHA-256" >&2
      return 1
    }
  done
  for key in module_file overlay_file applied_dtb_file backlight_rule_file; do
    hp2r_validate_artifact_name \
      "$(hp2r_manifest_value "$manifest" "$key")" || return
  done
  test "$(hp2r_manifest_value "$manifest" module_file)" = \
    hyperpixel2r_kms.ko || {
    echo "artifact module filename is invalid" >&2
    return 1
  }
  test "$(hp2r_manifest_value "$manifest" overlay_file)" = \
    "hyperpixel2r-kms-${source_revision:0:12}.dtbo" || {
    echo "artifact overlay filename is invalid" >&2
    return 1
  }
  test "$(hp2r_manifest_value "$manifest" applied_dtb_file)" = \
    hyperpixel2r-kms-applied.dtb || {
    echo "artifact applied DTB filename is invalid" >&2
    return 1
  }
  test "$(hp2r_manifest_value "$manifest" backlight_rule_file)" = \
    "$HP2R_BACKLIGHT_RULE_FILE" || {
    echo "artifact backlight rule filename is invalid" >&2
    return 1
  }
  value="$(hp2r_manifest_value "$manifest" module_vermagic)"
  case "$value" in
    "$release"*) ;;
    *)
      echo "artifact module vermagic does not match kernel release" >&2
      return 1
      ;;
  esac
}

hp2r_validate_target_manifest_values() {
  local manifest="$1"
  local key
  local value

  hp2r_validate_release \
    "$(hp2r_manifest_value "$manifest" kernel_release)" || return
  test "$(hp2r_manifest_value "$manifest" kernel_arch)" = aarch64 || {
    echo "target kernel architecture must be aarch64" >&2
    return 1
  }
  for key in header_path common_header_path kbuild_path base_dtb_path; do
    hp2r_validate_target_path \
      "$(hp2r_manifest_value "$manifest" "$key")" || return
  done
  test "$(hp2r_manifest_value "$manifest" kernel_source_package)" = linux || {
    echo "target kernel source package must be linux" >&2
    return 1
  }
  value="$(hp2r_manifest_value "$manifest" kernel_source_version)"
  [[ "$value" =~ ^[A-Za-z0-9.+:~_-]+$ ]] || {
    echo "target kernel source version has an invalid format" >&2
    return 1
  }
  value="$(hp2r_manifest_value "$manifest" kernel_source_deb_package)"
  [[ "$value" =~ ^linux-source-[0-9]+\.[0-9]+$ ]] || {
    echo "target kernel source package name has an invalid format" >&2
    return 1
  }
  value="$(hp2r_manifest_value "$manifest" kernel_source_deb_filename)"
  case "$value" in
    pool/*)
      case "$value" in
        *".."*|*[$'\t\r\n ']*)
          echo "unsafe kernel source package filename: $value" >&2
          return 1
          ;;
      esac
      ;;
    *)
      echo "unexpected kernel source package filename: $value" >&2
      return 1
      ;;
  esac
  test "$(hp2r_manifest_value "$manifest" kernel_source_deb)" = \
    kernel-source.deb || {
    echo "target kernel source artifact name is invalid" >&2
    return 1
  }
  for key in kernel_source_deb_sha256 base_dtb_sha256; do
    value="$(hp2r_manifest_value "$manifest" "$key")"
    [[ "$value" =~ ^[0-9a-f]{64}$ ]] || {
      echo "target $key is not lowercase SHA-256" >&2
      return 1
    }
  done
}

hp2r_validate_legacy_target_manifest() {
  local manifest="$1"
  local required_keys=(
    kernel_release
    kernel_arch
    header_path
    common_header_path
    kbuild_path
    kernel_source_package
    kernel_source_version
    kernel_source_deb_package
    kernel_source_deb_filename
    kernel_source_deb_sha256
    kernel_source_deb
    base_dtb_path
    base_dtb_sha256
  )

  hp2r_validate_exact_manifest_rows "$manifest" "${required_keys[@]}" || return
  hp2r_validate_target_manifest_values "$manifest"
}

hp2r_validate_schema2_target_manifest() {
  local manifest="$1"
  local required_keys=(
    schema_version
    target_identity_sha256
    kernel_release
    kernel_arch
    header_path
    common_header_path
    kbuild_path
    kernel_source_package
    kernel_source_version
    kernel_source_deb_package
    kernel_source_deb_filename
    kernel_source_deb_sha256
    kernel_source_deb
    base_dtb_path
    base_dtb_sha256
    kernel_image_path
    kernel_image_sha256
    initramfs_path
    initramfs_sha256
    vc4_overlay_path
    vc4_overlay_sha256
  )
  local release
  local key
  local value

  hp2r_validate_exact_manifest_rows "$manifest" "${required_keys[@]}" || return
  test "$(hp2r_manifest_value "$manifest" schema_version)" = 2 || {
    echo "unsupported target manifest schema version" >&2
    return 1
  }
  value="$(hp2r_manifest_value "$manifest" target_identity_sha256)"
  [[ "$value" =~ ^[0-9a-f]{64}$ ]] || {
    echo "target identity is not lowercase SHA-256" >&2
    return 1
  }
  hp2r_validate_target_manifest_values "$manifest" || return
  release="$(hp2r_manifest_value "$manifest" kernel_release)"
  test "$(hp2r_manifest_value "$manifest" base_dtb_path)" = \
    /boot/firmware/bcm2710-rpi-zero-2-w.dtb || {
    echo "target base DTB path is invalid" >&2
    return 1
  }
  test "$(hp2r_manifest_value "$manifest" kernel_image_path)" = \
    "/boot/vmlinuz-$release" || {
    echo "target kernel image path does not match kernel release" >&2
    return 1
  }
  test "$(hp2r_manifest_value "$manifest" initramfs_path)" = \
    "/boot/initrd.img-$release" || {
    echo "target initramfs path does not match kernel release" >&2
    return 1
  }
  test "$(hp2r_manifest_value "$manifest" vc4_overlay_path)" = \
    /boot/firmware/overlays/vc4-kms-v3d.dtbo || {
    echo "target VC4 overlay path is invalid" >&2
    return 1
  }
  for key in \
    kernel_image_sha256 \
    initramfs_sha256 \
    vc4_overlay_sha256
  do
    value="$(hp2r_manifest_value "$manifest" "$key")"
    [[ "$value" =~ ^[0-9a-f]{64}$ ]] || {
      echo "target $key is not lowercase SHA-256" >&2
      return 1
    }
  done
}

hp2r_validate_target_manifest() {
  local manifest="$1"
  local schema_version

  hp2r_require_regular "$manifest" || return
  schema_version="$(hp2r_manifest_value "$manifest" schema_version)"
  case "$schema_version" in
    '') hp2r_validate_legacy_target_manifest "$manifest" ;;
    2) hp2r_validate_schema2_target_manifest "$manifest" ;;
    *)
      echo "unsupported target manifest schema version" >&2
      return 1
      ;;
  esac
}

hp2r_validate_inactive_target_manifest() {
  local manifest="$1"
  local root="$2"
  local path_key
  local sha_key
  local path
  local relative
  local component
  local current
  local -a components

  hp2r_validate_schema2_target_manifest "$manifest" || return
  test ! -L "$root" && test -d "$root" || {
    echo "inactive target export root is missing or a symlink: $root" >&2
    return 1
  }
  for path_key in \
    kernel_image_path \
    initramfs_path \
    base_dtb_path \
    vc4_overlay_path
  do
    case "$path_key" in
      kernel_image_path) sha_key=kernel_image_sha256 ;;
      initramfs_path) sha_key=initramfs_sha256 ;;
      base_dtb_path) sha_key=base_dtb_sha256 ;;
      vc4_overlay_path) sha_key=vc4_overlay_sha256 ;;
    esac
    path="$(hp2r_manifest_value "$manifest" "$path_key")"
    relative="${path#/}"
    current="$root"
    IFS=/ read -r -a components <<< "$relative"
    for component in "${components[@]}"; do
      current="$current/$component"
      test ! -L "$current" || {
        echo "inactive target export path contains a symlink: $path" >&2
        return 1
      }
    done
    hp2r_verify_sha256 \
      "$root$path" \
      "$(hp2r_manifest_value "$manifest" "$sha_key")" \
      "exported ${path_key%_path}" || return
  done
}

hp2r_require_target_identity() {
  local manifest="$1"
  local expected_identity_sha256="$2"

  [[ "$expected_identity_sha256" =~ ^[0-9a-f]{64}$ ]] || {
    echo "requested target identity is not lowercase SHA-256" >&2
    return 1
  }
  test "$(hp2r_manifest_value "$manifest" target_identity_sha256)" = \
    "$expected_identity_sha256" || {
    echo "target export identity does not match requested target" >&2
    return 1
  }
}

hp2r_validate_host_tools_manifest() {
  local manifest="$1"
  local required_keys=(
    host_arch
    kernel_source_package
    kernel_source_deb_package
    kernel_source_version
    kernel_source_sha256
    host_fixdep_sha256
    host_modpost_sha256
    host_genksyms_sha256
  )
  local key
  local value

  hp2r_validate_exact_manifest_rows "$manifest" "${required_keys[@]}" || return
  value="$(hp2r_manifest_value "$manifest" host_arch)"
  case "$value" in
    aarch64|arm64|x86_64|amd64) ;;
    *)
      echo "unsupported build host architecture: $value" >&2
      return 1
      ;;
  esac
  test "$(hp2r_manifest_value "$manifest" kernel_source_package)" = linux || {
    echo "host tools source package must be linux" >&2
    return 1
  }
  value="$(hp2r_manifest_value "$manifest" kernel_source_deb_package)"
  [[ "$value" =~ ^linux-source-[0-9]+\.[0-9]+$ ]] || {
    echo "host tools source deb package name has an invalid format" >&2
    return 1
  }
  value="$(hp2r_manifest_value "$manifest" kernel_source_version)"
  [[ "$value" =~ ^[A-Za-z0-9.+:~_-]+$ ]] || {
    echo "host tools source version has an invalid format" >&2
    return 1
  }
  for key in \
    kernel_source_sha256 \
    host_fixdep_sha256 \
    host_modpost_sha256 \
    host_genksyms_sha256
  do
    value="$(hp2r_manifest_value "$manifest" "$key")"
    [[ "$value" =~ ^[0-9a-f]{64}$ ]] || {
      echo "host tools $key is not lowercase SHA-256" >&2
      return 1
    }
  done
}

hp2r_validate_artifact_provenance() {
  local manifest="$1"
  local target_manifest="$2"
  local artifact_dir="$3"
  local host_manifest="$artifact_dir/host-tools.txt"
  local key
  local helper
  local checksum_key
  local backlight_rule

  hp2r_validate_artifact_manifest "$manifest" || return
  hp2r_validate_target_manifest "$target_manifest" || return
  hp2r_validate_host_tools_manifest "$host_manifest" || return
  backlight_rule="$artifact_dir/$(hp2r_manifest_value "$manifest" backlight_rule_file)"
  hp2r_validate_backlight_rule "$backlight_rule" || return
  hp2r_verify_sha256 "$backlight_rule" \
    "$(hp2r_manifest_value "$manifest" backlight_rule_sha256)" \
    'backlight rule' || return
  test "$(hp2r_manifest_value "$manifest" kernel_release)" = \
    "$(hp2r_manifest_value "$target_manifest" kernel_release)" || {
    echo "artifact kernel release does not match target export" >&2
    return 1
  }
  test "$(hp2r_manifest_value "$manifest" architecture)" = \
    "$(hp2r_manifest_value "$target_manifest" kernel_arch)" || {
    echo "artifact architecture does not match target export" >&2
    return 1
  }
  test "$(hp2r_manifest_value "$manifest" base_dtb_sha256)" = \
    "$(hp2r_manifest_value "$target_manifest" base_dtb_sha256)" || {
    echo "artifact base DTB does not match target export" >&2
    return 1
  }
  for key in \
    kernel_source_package \
    kernel_source_deb_package \
    kernel_source_version
  do
    test "$(hp2r_manifest_value "$host_manifest" "$key")" = \
      "$(hp2r_manifest_value "$target_manifest" "$key")" || {
      echo "host tools $key does not match target export" >&2
      return 1
    }
  done
  test "$(hp2r_manifest_value "$host_manifest" kernel_source_sha256)" = \
    "$(hp2r_manifest_value "$target_manifest" kernel_source_deb_sha256)" || {
    echo "host tools source checksum does not match target export" >&2
    return 1
  }
  for specification in \
    host-fixdep:host_fixdep_sha256 \
    host-modpost:host_modpost_sha256 \
    host-genksyms:host_genksyms_sha256
  do
    helper="${specification%%:*}"
    checksum_key="${specification#*:}"
    hp2r_require_regular "$artifact_dir/$helper" || {
      echo "missing host helper evidence: $artifact_dir/$helper" >&2
      return 1
    }
    test "$(hp2r_sha256 "$artifact_dir/$helper")" = \
      "$(hp2r_manifest_value "$host_manifest" "$checksum_key")" || {
      echo "host helper checksum does not match manifest: $helper" >&2
      return 1
    }
  done
}

hp2r_docker() {
  local context="${HP2R_DOCKER_CONTEXT:-}"
  local command=(docker)

  if test -n "$context"; then
    command+=(--context "$context")
  fi
  "${command[@]}" "$@"
}

hp2r_fdt_property_absent() {
  local dtb_path="$1"
  local image="$2"
  local node="$3"
  local property="$4"
  local dtb_dir
  local dtb_file
  local properties

  hp2r_require_regular "$dtb_path" >/dev/null || return 2
  dtb_dir="$(cd "$(dirname "$dtb_path")" && pwd -P)" || return 2
  dtb_file="$(basename "$dtb_path")"
  hp2r_validate_artifact_name "$dtb_file" >/dev/null || return 2
  properties="$(
    hp2r_docker run --rm \
      --volume "$dtb_dir:/device-tree:ro" \
      "$image" \
      fdtget -p "/device-tree/$dtb_file" "$node"
  )" || return 2
  if printf '%s\n' "$properties" | grep -Fxq -- "$property"; then
    return 1
  fi
  return 0
}

hp2r_validate_overlay() {
  local overlay_path="$1"
  local image="$2"
  local overlay_dir
  local overlay_file

  hp2r_require_regular "$overlay_path" || {
    echo "compiled overlay is missing: $overlay_path" >&2
    return 1
  }
  overlay_dir="$(cd "$(dirname "$overlay_path")" && pwd -P)"
  overlay_file="$(basename "$overlay_path")"
  hp2r_validate_artifact_name "$overlay_file" || return

  hp2r_docker run --rm \
    --volume "$overlay_dir:/overlay:ro" \
    "$image" \
    sh -eu -c '
      overlay="/overlay/$1"

      fail() {
        echo "$1" >&2
        exit 1
      }

      require_node_shape() {
        path="$1"
        expected_properties="$2"
        expected_children="$3"
        error="$4"
        properties="$(fdtget -p "$overlay" "$path" | LC_ALL=C sort)" ||
          fail "$error"
        children="$(fdtget -l "$overlay" "$path" | LC_ALL=C sort)" ||
          fail "$error"
        test "$properties" = "$expected_properties" || fail "$error"
        test "$children" = "$expected_children" || fail "$error"
      }

      test "$(fdtget -t s "$overlay" / compatible)" = brcm,bcm2835 ||
        fail "root compatible is invalid"
      require_node_shape \
        / \
        compatible \
        "__fixups__
__local_fixups__
__overrides__
__symbols__
fragment@0
fragment@1
fragment@2
fragment@3" \
        "compiled overlay root shape is invalid"
      require_node_shape /fragment@0 target-path __overlay__ \
        "root fragment shape is invalid"
      require_node_shape \
        /fragment@0/__overlay__ \
        "" \
        "hyperpixel2r-backlight
hyperpixel2r-kms" \
        "root fragment overlay shape is invalid"

      panel_path=/fragment@0/__overlay__/hyperpixel2r-kms
      backlight_path=/fragment@0/__overlay__/hyperpixel2r-backlight
      touch_path="$panel_path/touchscreen@15"
      pinctrl_path=/fragment@2/__overlay__/hyperpixel2r-backlight-pins
      require_node_shape \
        "$panel_path" \
        "#address-cells
#size-cells
backlight
compatible
cs-gpios
phandle
rotation
scl-gpios
sda-gpios" \
        "port
touchscreen@15" \
        "panel subtree shape is invalid"
      require_node_shape \
        "$touch_path" \
        "compatible
interrupt-parent
interrupts
phandle
reg
touchscreen-size-x
touchscreen-size-y" \
        "" \
        "touchscreen subtree shape is invalid"
      require_node_shape \
        "$backlight_path" \
        "brightness-levels
compatible
default-brightness-level
num-interpolated-steps
phandle
pwms" \
        "" \
        "PWM backlight subtree shape is invalid"
      require_node_shape "$panel_path/port" "" endpoint \
        "panel port shape is invalid"
      require_node_shape \
        "$panel_path/port/endpoint" \
        "phandle
remote-endpoint" \
        "" \
        "panel endpoint shape is invalid"

      require_node_shape /fragment@1 target __overlay__ \
        "DPI fragment shape is invalid"
      require_node_shape \
        /fragment@1/__overlay__ \
        "pinctrl-0
pinctrl-names
status" \
        port \
        "DPI overlay shape is invalid"
      require_node_shape /fragment@1/__overlay__/port "" endpoint \
        "DPI port shape is invalid"
      require_node_shape \
        /fragment@1/__overlay__/port/endpoint \
        "phandle
remote-endpoint" \
        "" \
        "DPI endpoint shape is invalid"
      require_node_shape /fragment@2 target __overlay__ \
        "GPIO pinctrl fragment shape is invalid"
      require_node_shape /fragment@2/__overlay__ "" \
        hyperpixel2r-backlight-pins \
        "GPIO pinctrl overlay shape is invalid"
      require_node_shape \
        "$pinctrl_path" \
        "brcm,function
brcm,pins
phandle" \
        "" \
        "PWM pinctrl shape is invalid"
      require_node_shape /fragment@3 target __overlay__ \
        "PWM fragment shape is invalid"
      require_node_shape \
        /fragment@3/__overlay__ \
        "assigned-clock-rates
pinctrl-0
pinctrl-names
status" \
        "" \
        "PWM overlay shape is invalid"

      require_node_shape \
        /__overrides__ \
        "rotate
touchscreen-inverted-x
touchscreen-inverted-y
touchscreen-swapped-x-y" \
        "" \
        "overlay override shape is invalid"
      require_node_shape \
        /__symbols__ \
        "dpi_out
hyperpixel2r_backlight
hyperpixel2r_backlight_pins
hyperpixel2r_panel
panel_in
polytouch" \
        "" \
        "overlay symbol shape is invalid"
      require_node_shape \
        /__fixups__ \
        "dpi
dpi_18bit_cpadhi_gpio0
gpio
pwm" \
        "" \
        "overlay fixup shape is invalid"
      require_node_shape \
        /__local_fixups__ \
        "" \
        "__overrides__
fragment@0
fragment@1
fragment@3" \
        "overlay local-fixup shape is invalid"
      require_node_shape /__local_fixups__/fragment@0 "" __overlay__ \
        "root local-fixup shape is invalid"
      require_node_shape \
        /__local_fixups__/fragment@0/__overlay__ \
        "" \
        hyperpixel2r-kms \
        "root overlay local-fixup shape is invalid"
      require_node_shape \
        /__local_fixups__/fragment@0/__overlay__/hyperpixel2r-kms \
        backlight \
        port \
        "panel local-fixup shape is invalid"
      require_node_shape \
        /__local_fixups__/fragment@0/__overlay__/hyperpixel2r-kms/port \
        "" \
        endpoint \
        "panel port local-fixup shape is invalid"
      require_node_shape \
        /__local_fixups__/fragment@0/__overlay__/hyperpixel2r-kms/port/endpoint \
        remote-endpoint \
        "" \
        "panel endpoint local-fixup shape is invalid"
      require_node_shape /__local_fixups__/fragment@1 "" __overlay__ \
        "DPI local-fixup shape is invalid"
      require_node_shape \
        /__local_fixups__/fragment@1/__overlay__ \
        "" \
        port \
        "DPI overlay local-fixup shape is invalid"
      require_node_shape \
        /__local_fixups__/fragment@1/__overlay__/port \
        "" \
        endpoint \
        "DPI port local-fixup shape is invalid"
      require_node_shape \
        /__local_fixups__/fragment@1/__overlay__/port/endpoint \
        remote-endpoint \
        "" \
        "DPI endpoint local-fixup shape is invalid"
      require_node_shape /__local_fixups__/fragment@3 "" __overlay__ \
        "PWM local-fixup shape is invalid"
      require_node_shape \
        /__local_fixups__/fragment@3/__overlay__ \
        pinctrl-0 \
        "" \
        "PWM overlay local-fixup shape is invalid"
      require_node_shape \
        /__local_fixups__/__overrides__ \
        "rotate
touchscreen-inverted-x
touchscreen-inverted-y
touchscreen-swapped-x-y" \
        "" \
        "override local-fixup shape is invalid"

      test "$(fdtget -t bx "$overlay" /__overrides__ rotate)" = \
        "0 0 0 5 72 6f 74 61 74 69 6f 6e 3a 30 0" ||
        fail "invalid rotate override encoding"
      test "$(
        fdtget -t bx "$overlay" /__overrides__ touchscreen-inverted-x
      )" = \
        "0 0 0 6 74 6f 75 63 68 73 63 72 65 65 6e 2d 69 6e 76 65 72 74 65 64 2d 78 3f 0" ||
        fail "invalid touchscreen-inverted-x override encoding"
      test "$(
        fdtget -t bx "$overlay" /__overrides__ touchscreen-inverted-y
      )" = \
        "0 0 0 6 74 6f 75 63 68 73 63 72 65 65 6e 2d 69 6e 76 65 72 74 65 64 2d 79 3f 0" ||
        fail "invalid touchscreen-inverted-y override encoding"
      test "$(
        fdtget -t bx "$overlay" /__overrides__ touchscreen-swapped-x-y
      )" = \
        "0 0 0 6 74 6f 75 63 68 73 63 72 65 65 6e 2d 73 77 61 70 70 65 64 2d 78 2d 79 3f 0" ||
        fail "invalid touchscreen-swapped-x-y override encoding"

      test "$(fdtget -t x "$overlay" "$panel_path" phandle)" = 5 ||
        fail "rotate override target phandle is invalid"
      test "$(fdtget -t x "$overlay" "$touch_path" phandle)" = 6 ||
        fail "touchscreen override target phandle is invalid"
      for parameter in \
        rotate \
        touchscreen-inverted-x \
        touchscreen-inverted-y \
        touchscreen-swapped-x-y
      do
        test "$(
          fdtget -t x "$overlay" /__local_fixups__/__overrides__ "$parameter"
        )" = 0 || fail "override local fixup is invalid: $parameter"
      done

      test "$(fdtget -t s "$overlay" /__fixups__ dpi)" = \
        "/fragment@1:target:0" || fail "DPI fragment target fixup is invalid"
      test "$(
        fdtget -t s "$overlay" /__fixups__ dpi_18bit_cpadhi_gpio0
      )" = "/fragment@1/__overlay__:pinctrl-0:0" ||
        fail "DPI pinctrl fixup is invalid"
      test "$(fdtget -t s "$overlay" /__fixups__ gpio)" = \
        "/fragment@0/__overlay__/hyperpixel2r-kms:sda-gpios:0 /fragment@0/__overlay__/hyperpixel2r-kms:scl-gpios:0 /fragment@0/__overlay__/hyperpixel2r-kms:cs-gpios:0 /fragment@0/__overlay__/hyperpixel2r-kms/touchscreen@15:interrupt-parent:0 /fragment@2:target:0" ||
        fail "GPIO fixups are invalid"
      test "$(fdtget -t s "$overlay" /__fixups__ pwm)" = \
        "/fragment@0/__overlay__/hyperpixel2r-backlight:pwms:0 /fragment@3:target:0" ||
        fail "PWM fixups are invalid"

      fragments="$(fdtget -l "$overlay" / | grep "^fragment@" | sort)"
      test "$fragments" = "fragment@0
fragment@1
fragment@2
fragment@3" || fail "compiled overlay fragment set is invalid"
      test "$(fdtget -t s "$overlay" /fragment@0 target-path)" = / ||
        fail "root fragment target-path is invalid"
      if fdtget "$overlay" /fragment@0 target >/dev/null 2>&1; then
        fail "root fragment must not contain a target phandle"
      fi
      test "$(fdtget -t x "$overlay" /fragment@1 target)" = ffffffff ||
        fail "DPI fragment target placeholder is invalid"
      if fdtget "$overlay" /fragment@1 target-path >/dev/null 2>&1; then
        fail "DPI fragment must not contain target-path"
      fi
      test "$(fdtget -t x "$overlay" /fragment@2 target)" = ffffffff ||
        fail "GPIO pinctrl fragment target placeholder is invalid"
      test "$(fdtget -t x "$overlay" /fragment@3 target)" = ffffffff ||
        fail "PWM fragment target placeholder is invalid"

      test "$(fdtget -t s "$overlay" "$panel_path" compatible)" = \
        shayne,hyperpixel2r-kms || fail "panel compatible is invalid"
      test "$(fdtget -t x "$overlay" "$panel_path" sda-gpios)" = \
        "ffffffff a 0" || fail "panel SDA GPIO payload is invalid"
      test "$(fdtget -t x "$overlay" "$panel_path" scl-gpios)" = \
        "ffffffff b 0" || fail "panel SCL GPIO payload is invalid"
      test "$(fdtget -t x "$overlay" "$panel_path" cs-gpios)" = \
        "ffffffff 12 1" || fail "panel CS GPIO payload is invalid"
      test "$(fdtget -t x "$overlay" "$panel_path" backlight)" = 1 ||
        fail "panel backlight phandle is invalid"
      if fdtget "$overlay" "$panel_path" backlight-gpios >/dev/null 2>&1; then
        fail "panel must not contain a backlight GPIO"
      fi
      test "$(fdtget -t x "$overlay" "$panel_path" rotation)" = 0 ||
        fail "panel default rotation is invalid"
      test "$(fdtget -t x "$overlay" "$panel_path" "#address-cells")" = 1 ||
        fail "panel address-cell count is invalid"
      test "$(fdtget -t x "$overlay" "$panel_path" "#size-cells")" = 0 ||
        fail "panel size-cell count is invalid"
      test "$(fdtget -t s "$overlay" "$touch_path" compatible)" = \
        edt,edt-ft5406 || fail "touchscreen compatible is invalid"
      test "$(fdtget -t x "$overlay" "$touch_path" reg)" = 15 ||
        fail "touchscreen address is invalid"
      test "$(fdtget -t x "$overlay" "$touch_path" interrupt-parent)" = ffffffff ||
        fail "touchscreen interrupt parent is invalid"
      test "$(fdtget -t x "$overlay" "$touch_path" interrupts)" = "1b 2" ||
        fail "touchscreen interrupt payload is invalid"
      test "$(fdtget -t x "$overlay" "$touch_path" touchscreen-size-x)" = 1e0 ||
        fail "touchscreen X size is invalid"
      test "$(fdtget -t x "$overlay" "$touch_path" touchscreen-size-y)" = 1e0 ||
        fail "touchscreen Y size is invalid"
      test "$(fdtget -t s "$overlay" "$backlight_path" compatible)" = \
        pwm-backlight || fail "PWM backlight compatible is invalid"
      test "$(fdtget -t x "$overlay" "$backlight_path" pwms)" = \
        "ffffffff 1 30d40 0" || fail "PWM backlight payload is invalid"
      test "$(fdtget -t x "$overlay" "$backlight_path" brightness-levels)" = \
        "0 ff" || fail "PWM backlight levels are invalid"
      test "$(fdtget -t x "$overlay" "$backlight_path" num-interpolated-steps)" = \
        ff || fail "PWM backlight interpolation is invalid"
      test "$(fdtget -t x "$overlay" "$backlight_path" default-brightness-level)" = \
        d || fail "PWM backlight default is invalid"
      test "$(fdtget -t x "$overlay" "$pinctrl_path" brcm,pins)" = 13 ||
        fail "PWM pinctrl GPIO is invalid"
      test "$(fdtget -t x "$overlay" "$pinctrl_path" brcm,function)" = 2 ||
        fail "PWM pinctrl function is invalid"
      test "$(fdtget -t s "$overlay" /fragment@3/__overlay__ status)" = okay ||
        fail "PWM status is invalid"
      test "$(fdtget -t s "$overlay" /fragment@3/__overlay__ pinctrl-names)" = \
        default || fail "PWM pinctrl name is invalid"
      test "$(fdtget -t x "$overlay" /fragment@3/__overlay__ pinctrl-0)" = 4 ||
        fail "PWM pinctrl phandle is invalid"
      test "$(
        fdtget -t x "$overlay" /fragment@3/__overlay__ assigned-clock-rates
      )" = f4240 || fail "PWM assigned clock rate is invalid"
      if fdtget "$overlay" /fragment@3/__overlay__ clock-frequency \
        >/dev/null 2>&1
      then
        fail "PWM overlay contains inert clock-frequency property"
      fi
      test "$(
        fdtget -t x "$overlay" "$panel_path/port/endpoint" phandle
      )" = 3 || fail "panel endpoint phandle is invalid"
      test "$(
        fdtget -t x "$overlay" "$panel_path/port/endpoint" remote-endpoint
      )" = 2 || fail "panel endpoint link is invalid"
      test "$(fdtget -t s "$overlay" /fragment@1/__overlay__ status)" = okay ||
        fail "DPI status is invalid"
      test "$(
        fdtget -t s "$overlay" /fragment@1/__overlay__ pinctrl-names
      )" = default || fail "DPI pinctrl name is invalid"
      test "$(
        fdtget -t x "$overlay" /fragment@1/__overlay__ pinctrl-0
      )" = ffffffff || fail "DPI pinctrl payload is invalid"
      test "$(
        fdtget -t x "$overlay" /fragment@1/__overlay__/port/endpoint phandle
      )" = 2 || fail "DPI endpoint phandle is invalid"
      test "$(
        fdtget -t x "$overlay" \
          /fragment@1/__overlay__/port/endpoint remote-endpoint
      )" = 3 || fail "DPI endpoint link is invalid"

      test "$(
        fdtget -t s "$overlay" /__symbols__ hyperpixel2r_panel
      )" = "$panel_path" || fail "panel symbol is invalid"
      test "$(fdtget -t s "$overlay" /__symbols__ polytouch)" = \
        "$touch_path" || fail "touchscreen symbol is invalid"
      test "$(fdtget -t s "$overlay" /__symbols__ hyperpixel2r_backlight)" = \
        "$backlight_path" || fail "PWM backlight symbol is invalid"
      test "$(fdtget -t s "$overlay" /__symbols__ hyperpixel2r_backlight_pins)" = \
        "$pinctrl_path" || fail "PWM pinctrl symbol is invalid"
      test "$(fdtget -t s "$overlay" /__symbols__ panel_in)" = \
        "$panel_path/port/endpoint" || fail "panel endpoint symbol is invalid"
      test "$(fdtget -t s "$overlay" /__symbols__ dpi_out)" = \
        /fragment@1/__overlay__/port/endpoint ||
        fail "DPI endpoint symbol is invalid"

      test "$(
        fdtget -t x "$overlay" \
          /__local_fixups__/fragment@0/__overlay__/hyperpixel2r-kms \
          backlight
      )" = 0 || fail "panel backlight local fixup is invalid"
      test "$(
        fdtget -t x "$overlay" \
          /__local_fixups__/fragment@0/__overlay__/hyperpixel2r-kms/port/endpoint \
          remote-endpoint
      )" = 0 || fail "panel endpoint local fixup is invalid"
      test "$(
        fdtget -t x "$overlay" \
          /__local_fixups__/fragment@1/__overlay__/port/endpoint \
          remote-endpoint
      )" = 0 || fail "DPI endpoint local fixup is invalid"
      test "$(
        fdtget -t x "$overlay" \
          /__local_fixups__/fragment@3/__overlay__ \
          pinctrl-0
      )" = 0 || fail "PWM pinctrl local fixup is invalid"
    ' sh "$overlay_file"
}
