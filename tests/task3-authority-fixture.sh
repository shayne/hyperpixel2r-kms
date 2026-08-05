# This file is sourced by tests/boot-fixtures.sh after its fake target helpers
# are installed. It deliberately exercises the production stage controller,
# not a text-level or mocked authorization comparison.

# First make every non-identity authority field agree through the real stage
# controller. A test-only SCP stop marker proves the authorization comparison
# was passed before any target mutation occurs.
prepare_aligned_inactive_authorization_target
aligned_tmp="$fixture/aligned-identity-controller-tmp"
mkdir -p "$aligned_tmp"
rm -f -- "$log"
if HP2R_FIXTURE_RUNNING_RELEASE="$release" \
  HP2R_FIXTURE_STOP_AFTER_INACTIVE_AUTH_SCP=1 TMPDIR="$aligned_tmp" \
  HP2R_FIXTURE_ARTIFACT_DIR_OVERRIDE="$aligned_candidate_artifact" \
  run_stage --kernel-release "$aligned_candidate_release" \
    --kernel-target "$aligned_candidate_target_parent" \
    --target-identity-sha256 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    --stage-only >"$fixture/aligned-identity-stage.output" 2>&1
then
  fail 'aligned inactive authority did not stop at the post-authorization SCP sentinel'
fi
if ! test -f "$root/tmp/inactive-authorization-scp-attempted"; then
  cat "$fixture/aligned-identity-stage.output" >&2
  fail 'aligned inactive authority did not reach the post-authorization SCP sentinel'
fi

# With the same aligned artifact/export/firmware tuple, only the stored target
# identity differs. Stage must reject it before allocating or copying payload.
prepare_aligned_inactive_authorization_target
replace_equals_value "$root/var/lib/hyperpixel2r-kms/accepted-transition" \
  target_identity_sha256 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
wrong_target_tmp="$fixture/wrong-target-controller-tmp"
mkdir -p "$wrong_target_tmp"
rm -f -- "$log"
if HP2R_FIXTURE_RUNNING_RELEASE="$release" TMPDIR="$wrong_target_tmp" \
  HP2R_FIXTURE_ARTIFACT_DIR_OVERRIDE="$aligned_candidate_artifact" \
  run_stage --kernel-release "$aligned_candidate_release" \
    --kernel-target "$aligned_candidate_target_parent" \
    --target-identity-sha256 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    --stage-only >/dev/null 2>&1
then
  fail 'inactive stage accepted an authority for a different target identity'
fi
test ! -e "$root/tmp/inactive-authorization-scp-attempted" ||
  fail 'wrong target identity reached the post-authorization SCP sentinel'
test -z "$(find "$wrong_target_tmp" -mindepth 1 -print -quit)" ||
  fail 'wrong target authority allocated a payload before rejection'
test ! -e "$log" || ! grep -q '^scp ' "$log" ||
  fail 'wrong target authority uploaded before rejection'
