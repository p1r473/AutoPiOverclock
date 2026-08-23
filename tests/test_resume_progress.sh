#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
APO_ROOT=$ROOT
source "$ROOT/lib/common.sh"
source "$ROOT/lib/state.sh"

declare -Ag APO_CFG=(
    [CANDIDATE_DURATION_S]=60
    [FINAL_DURATION_S]=480
    [BACKOFF_STEPS]=1
    [CANDIDATE_BOOTS]=4
    [FINAL_BOOTS]=5
)
APO_NORMAL_CPU=2400
APO_NORMAL_GPU=800
APO_NORMAL_VOLTAGE=0
APO_TEST_VOLTAGE=50000
APO_GPU_KEY=v3d_freq
APO_REQUIRE_GPU_STRESS=1
APO_LAST_CLASS=''
APO_LAST_REASON=''
APO_STATE=()
ACTIONS=()
SAVE_COUNT=0

apo_state_save() { SAVE_COUNT=$((SAVE_COUNT + 1)); }
apo_event() { :; }
apo_summary_line() { :; }
apo_state_fail() { apo_state_set STATUS FAILED; apo_state_set FAILURE_CLASS "$1"; apo_state_set FAILURE_REASON "$2"; apo_state_save; }
apo_boot_candidate() {
    ACTIONS+=("boot:$3")
    apo_state_set TRYBOOT_EXPECTED 1
    apo_state_set CURRENT_CPU "$1"
    apo_state_set CURRENT_GPU "$2"
}
apo_return_normal() {
    ACTIONS+=("normal:$1")
    apo_state_set TRYBOOT_EXPECTED 0
    apo_state_set CURRENT_CPU ''
    apo_state_set CURRENT_GPU ''
}
apo_run_stress() { ACTIONS+=("stress:$1:$3"); }
apo_health_check() { ACTIONS+=("health:$4"); }
apo_verify_permanent_hash() { ACTIONS+=("hash:$1"); }
apo_recover_preserving_failure() { return 0; }
apo_record_failure_after_recovery() { apo_state_fail "$2" "$3"; }

source "$ROOT/lib/candidates.sh"

# Resume a candidate after its second of four configured boot cycles. Earlier
# boot gates must not be replayed; only cycles 2-4 and later gates run.
apo_state_set CANDIDATE_LABEL cpu-3000_gpu-800
apo_state_set CANDIDATE_CPU 3000
apo_state_set CANDIDATE_GPU 800
apo_state_set CANDIDATE_STAGE NORMAL_2
apo_state_set TRYBOOT_EXPECTED 0
apo_test_candidate 3000 800 cpu-3000_gpu-800 combined
[[ ${ACTIONS[*]} == 'normal:cpu-3000_gpu-800-normal-2 boot:cpu-3000_gpu-800-boot-3 normal:cpu-3000_gpu-800-normal-3 boot:cpu-3000_gpu-800-boot-4 normal:cpu-3000_gpu-800-normal-4 boot:cpu-3000_gpu-800-stress-boot stress:combined:cpu-3000_gpu-800-candidate health:cpu-3000_gpu-800-post-stress normal:cpu-3000_gpu-800-final-normal' ]]
[[ $(apo_state_get CANDIDATE_STAGE) == COMPLETE ]]

# Resume final validation at post-stress boot 2 of five. Endurance and boot 1
# are already checkpointed and must not run again.
ACTIONS=()
APO_STATE=()
apo_state_set RECOMMENDED_CPU 3000
apo_state_set RECOMMENDED_GPU 900
apo_state_set FINAL_TARGET_CPU 3000
apo_state_set FINAL_TARGET_GPU 900
apo_state_set FINAL_STAGE BOOT_2
apo_state_set VALIDATED 0
apo_final_validation
[[ ${ACTIONS[*]} == 'boot:final-post-stress-boot-2 normal:final-post-stress-normal-2 boot:final-post-stress-boot-3 normal:final-post-stress-normal-3 boot:final-post-stress-boot-4 normal:final-post-stress-normal-4 boot:final-post-stress-boot-5 normal:final-post-stress-normal-5 hash:final-completion' ]]
[[ $(apo_state_get STATUS) == PASS ]]
[[ $(apo_state_get PHASE) == COMPLETE ]]
[[ $(apo_state_get FINAL_CPU) == 3000 ]]
[[ $(apo_state_get FINAL_GPU) == 900 ]]
[[ $(apo_state_get VALIDATED) == 1 ]]
[[ $(apo_state_get VALIDATION_SCHEMA) == "$APO_CURRENT_VALIDATION_SCHEMA" ]]

# A saved stage beyond the immutable configured count is corrupt state, not a
# reason to silently skip directly into stress or completion.
ACTIONS=()
APO_STATE=()
apo_state_set CANDIDATE_LABEL cpu-3000_gpu-800
apo_state_set CANDIDATE_CPU 3000
apo_state_set CANDIDATE_GPU 800
apo_state_set CANDIDATE_STAGE BOOT_5
if apo_test_candidate 3000 800 cpu-3000_gpu-800 combined; then
    echo 'out-of-range candidate boot stage was accepted' >&2
    exit 1
fi
[[ $APO_LAST_CLASS == HARNESS_FAILURE ]]
[[ $APO_LAST_REASON == *'exceeds configured candidate_boots=4'* ]]
[[ ${#ACTIONS[@]} == 0 ]]

ACTIONS=()
APO_STATE=()
apo_state_set RECOMMENDED_CPU 3000
apo_state_set RECOMMENDED_GPU 900
apo_state_set FINAL_TARGET_CPU 3000
apo_state_set FINAL_TARGET_GPU 900
apo_state_set FINAL_STAGE NORMAL_6
if apo_final_validation; then
    echo 'out-of-range final boot stage was accepted' >&2
    exit 1
fi
[[ $(apo_state_get STATUS) == FAILED ]]
[[ $(apo_state_get FAILURE_REASON) == *'exceeds configured final_boots=5'* ]]
[[ ${#ACTIONS[@]} == 0 ]]

# The final clocks, validation schema, and PASS/COMPLETE markers are one atomic
# state checkpoint rather than two crash-separable writes.
APO_STATE=()
SAVE_COUNT=0
apo_state_complete 2900 850
[[ $SAVE_COUNT == 1 ]]
[[ $(apo_state_get FINAL_CPU) == 2900 && $(apo_state_get FINAL_GPU) == 850 ]]
[[ $(apo_state_get VALIDATED) == 1 && $(apo_state_get STATUS) == PASS ]]

printf 'test_resume_progress: PASS\n'
