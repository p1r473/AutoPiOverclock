#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
APO_ROOT=$ROOT
source "$ROOT/lib/common.sh"
source "$ROOT/lib/config.sh"

declare -Ag APO_STATE=()
APO_CFG=([BACKOFF_STEPS]=1 [CANDIDATE_BOOTS]=2 [FINAL_DURATION_S]=28800)
APO_NORMAL_CPU=2400
APO_NORMAL_GPU=800
APO_NORMAL_VOLTAGE=0
APO_TEST_VOLTAGE=0
APO_AUTO_BASELINE_CPU=''
APO_AUTO_BASELINE_GPU=''
APO_AUTO_BASELINE_VOLTAGE=''
APO_AUTO_BASELINE_PROVENANCE=''
APO_AUTO_BASELINE_EVIDENCE=''
APO_AUTO_GENERATED_CANDIDATES=0
APO_EDGE_CPU_24H=0

apo_state_get() {
    local state_key=$1 fallback=${2-}
    if [[ -v APO_STATE[$state_key] ]]; then printf '%s' "${APO_STATE[$state_key]}"; else printf '%s' "$fallback"; fi
}
apo_state_set() { APO_STATE[$1]=${2-}; }
apo_state_save() { :; }
apo_state_clear_final_validation() {
    apo_state_set FINAL_CPU ''
    apo_state_set FINAL_GPU ''
    apo_state_set VALIDATION_SCHEMA ''
    apo_state_set VALIDATION_DURATION_S ''
    apo_state_set VALIDATED 0
}
apo_summary_line() { :; }
apo_event() { :; }
apo_state_fail() { apo_state_set STATUS FAILED; apo_state_set FAILURE_CLASS "$1"; apo_state_set FAILURE_REASON "$2"; }
apo_class_is_edge_failure() { [[ $1 == BOOT_FAILURE || $1 == STABILITY_FAILURE ]]; }

source "$ROOT/lib/candidates.sh"
APO_STATE[PASSED_CPUS]='2800,2900,3000'
APO_STATE[PASSED_GPUS]='850,900,950'
APO_STATE[FINAL_CPU]='stale'
APO_STATE[FINAL_GPU]='stale'

apo_select_conservative_clocks

[[ ${APO_STATE[RECOMMENDED_CPU]} == 2900 ]]
[[ ${APO_STATE[RECOMMENDED_GPU]} == 900 ]]
[[ -z ${APO_STATE[FINAL_CPU]} ]]
[[ -z ${APO_STATE[FINAL_GPU]} ]]

# Configuration-free auto mode climbs coarsely, refines only the final
# passing-to-failing gap at 25 MHz, then selects a tested CPU clock 50 MHz
# below the refined failure boundary.
APO_STATE=()
APO_AUTO_GENERATED_CANDIDATES=1
APO_AUTO_BASELINE_CPU=2400
APO_AUTO_BASELINE_GPU=800
APO_AUTO_BASELINE_VOLTAGE=0
APO_AUTO_BASELINE_PROVENANCE='verified-default'
APO_AUTO_BASELINE_EVIDENCE=none
APO_REQUIRE_GPU_STRESS=0
APO_CPU_CANDIDATES=(2500 2600 2700 2800 2900 3000 3100 3200)
APO_GPU_CANDIDATES=(850 900 950 1000 1050 1100 1150 1200)
APO_CFG[CPU_CANDIDATES]='2500,2600,2700,2800,2900,3000,3100,3200'
APO_CFG[GPU_CANDIDATES]='850,900,950,1000,1050,1100,1150,1200'
APO_CFG[BACKOFF_STEPS]=0
APO_CFG[VOLTAGE_DELTA_UV]=existing
AUTO_CALLS=()
apo_test_candidate() {
    local cpu_mhz=$1
    AUTO_CALLS+=("cpu:$cpu_mhz")
    if (( cpu_mhz <= 3050 )); then return 0; fi
    APO_LAST_CLASS=STABILITY_FAILURE
    APO_LAST_REASON='fixture boundary'
    return 1
}
apo_sweep_cpu
[[ $(apo_state_get PASSED_CPUS) == '2500,2600,2700,2800,2900,3000,3025,3050' ]]
[[ $(apo_state_get CPU_FAILURE_BOUNDARY) == 3075 ]]
[[ $(apo_state_get CPU_REFINE_CANDIDATES) == '3025,3050' ]]
[[ $(apo_state_get SAFE_CPU) == 3025 ]]
[[ $(apo_state_get CPU_GUARD_TARGET) == 3025 ]]
[[ $(apo_state_get CPU_GUARD_VERIFIED) == 1 ]]
[[ ${AUTO_CALLS[*]} == 'cpu:2500 cpu:2600 cpu:2700 cpu:2800 cpu:2900 cpu:3000 cpu:3100 cpu:3025 cpu:3050 cpu:3075' ]]

# GPU keeps a 25 MHz guard: a 1200 MHz coarse failure followed by a passing
# 1175 MHz refinement selects 1175 MHz for production validation.
apo_test_candidate() {
    local gpu_mhz=$2
    AUTO_CALLS+=("gpu:$gpu_mhz")
    if (( gpu_mhz <= 1175 )); then return 0; fi
    APO_LAST_CLASS=STABILITY_FAILURE
    APO_LAST_REASON='fixture boundary'
    return 1
}
apo_sweep_gpu
[[ $(apo_state_get PASSED_GPUS) == '850,900,950,1000,1050,1100,1150,1175' ]]
[[ $(apo_state_get GPU_FAILURE_BOUNDARY) == 1200 ]]
[[ $(apo_state_get GPU_REFINE_CANDIDATES) == 1175 ]]
[[ $(apo_state_get SAFE_GPU) == 1175 ]]
[[ $(apo_state_get GPU_GUARD_TARGET) == 1175 ]]
[[ $(apo_state_get GPU_GUARD_VERIFIED) == 1 ]]

apo_select_conservative_clocks
[[ $(apo_state_get RECOMMENDED_CPU) == 3025 ]]
[[ $(apo_state_get RECOMMENDED_GPU) == 1175 ]]

# If the ceiling passes, the non-coarse 50 MHz CPU guard clock is itself
# candidate-tested before it can be selected.
APO_STATE=()
APO_NORMAL_CPU=2400
GUARD_CALLS=()
apo_test_candidate() { GUARD_CALLS+=("$1"); return 0; }
apo_sweep_cpu
[[ $(apo_state_get CPU_FAILURE_BOUNDARY '') == '' ]]
[[ $(apo_state_get SAFE_CPU) == 3150 ]]
[[ ${GUARD_CALLS[*]} == '2500 2600 2700 2800 2900 3000 3100 3200 3150' ]]

# If an untested ceiling-derived guard candidate fails, treat that lower
# failure as the new boundary and fall back by the full production guard. A
# prior higher short pass must never override the lower reproduced failure.
APO_STATE=()
APO_NORMAL_CPU=2400
GUARD_CALLS=()
apo_test_candidate() {
    GUARD_CALLS+=("$1")
    if (( $1 == 3150 )); then
        APO_LAST_CLASS=STABILITY_FAILURE
        APO_LAST_REASON='guard fixture boundary'
        return 1
    fi
    return 0
}
apo_sweep_cpu
[[ $(apo_state_get CPU_FAILURE_BOUNDARY) == 3150 ]]
[[ $(apo_state_get CPU_GUARD_TARGET) == 3100 ]]
[[ $(apo_state_get SAFE_CPU) == 3100 ]]
[[ $(apo_state_get CPU_GUARD_VERIFIED) == 1 ]]
[[ ${GUARD_CALLS[*]} == '2500 2600 2700 2800 2900 3000 3100 3200 3150' ]]

# Adaptive explicit maxima are tested exactly first.  After that ceiling fails,
# CPU descends coarsely to the first pass and refines upward at the configured
# 5 MHz resolution without selecting an untested clock.
APO_STATE=()
APO_SELECTION_POLICY=adaptive-refined-v1
APO_AUTO_GENERATED_CANDIDATES=1
APO_AUTO_BASELINE_CPU=2400
APO_AUTO_BASELINE_GPU=960
APO_NORMAL_CPU=2400
APO_NORMAL_GPU=960
APO_CPU_MIN=3003
APO_CPU_MAX=3173
APO_CPU_RESOLUTION_MHZ=5
APO_GPU_RESOLUTION_MHZ=25
APO_CPU_SEARCH_DIRECTION=descending
APO_GPU_SEARCH_DIRECTION=forward
APO_CPU_CANDIDATES=(3173)
APO_GPU_CANDIDATES=()
APO_CFG[CPU_CANDIDATES]=3173
APO_CFG[GPU_CANDIDATES]=''
APO_CFG[BACKOFF_STEPS]=0
APO_CFG[VOLTAGE_DELTA_UV]=existing
ADAPTIVE_CPU_CALLS=()
apo_validate_auto_resume_state() { :; }
apo_test_candidate() {
    local cpu_mhz=$1
    ADAPTIVE_CPU_CALLS+=("$cpu_mhz")
    if (( cpu_mhz <= 3123 )); then return 0; fi
    APO_LAST_CLASS=STABILITY_FAILURE
    APO_LAST_REASON='adaptive CPU fixture boundary'
    return 1
}
apo_sweep_cpu
[[ ${ADAPTIVE_CPU_CALLS[0]} == 3173 ]]
[[ ${ADAPTIVE_CPU_CALLS[1]} == 3073 ]]
[[ ${ADAPTIVE_CPU_CALLS[-1]} == 3128 ]]
[[ $(apo_state_get CPU_REVERSE_PASS '') == 3073 ]]
[[ $(apo_state_get CPU_FAILURE_BOUNDARY '') == 3128 ]]
[[ $(apo_state_get CPU_REFINE_CANDIDATES '') == '3078,3083,3088,3093,3098,3103,3108,3113,3118,3123' ]]
[[ $(apo_state_get SAFE_CPU '') == 3123 ]]
[[ $(apo_state_get CPU_GUARD_TARGET '') == 3123 && $(apo_state_get CPU_GUARD_VERIFIED 0) == 1 ]]

# The GPU branch follows the same exact-first contract independently and uses
# its own 1 MHz resolution.
APO_STATE=()
APO_CPU_MIN=''
APO_GPU_MIN=1102
APO_GPU_MAX=1187
APO_CPU_RESOLUTION_MHZ=5
APO_GPU_RESOLUTION_MHZ=1
APO_CPU_SEARCH_DIRECTION=forward
APO_GPU_SEARCH_DIRECTION=descending
APO_CPU_CANDIDATES=()
APO_GPU_CANDIDATES=(1187)
APO_CFG[CPU_CANDIDATES]=''
APO_CFG[GPU_CANDIDATES]=1187
apo_state_set SAFE_CPU 3100
apo_state_set CPU_QUALIFIED_CLOCK 3100
ADAPTIVE_GPU_CALLS=()
apo_test_candidate() {
    local gpu_mhz=$2
    ADAPTIVE_GPU_CALLS+=("$gpu_mhz")
    if (( gpu_mhz <= 1160 )); then return 0; fi
    APO_LAST_CLASS=STABILITY_FAILURE
    APO_LAST_REASON='adaptive GPU fixture boundary'
    return 1
}
apo_sweep_gpu
[[ ${ADAPTIVE_GPU_CALLS[0]} == 1187 ]]
[[ ${ADAPTIVE_GPU_CALLS[1]} == 1137 ]]
[[ ${ADAPTIVE_GPU_CALLS[-1]} == 1161 ]]
[[ $(apo_state_get GPU_REVERSE_PASS '') == 1137 ]]
[[ $(apo_state_get GPU_FAILURE_BOUNDARY '') == 1161 ]]
[[ $(apo_last_passed_clock "$(apo_state_get PASSED_GPUS '')" 960) == 1160 ]]
[[ $(apo_state_get SAFE_GPU '') == 1160 ]]
[[ $(apo_state_get GPU_GUARD_TARGET '') == 1160 && $(apo_state_get GPU_GUARD_VERIFIED 0) == 1 ]]

# A descending coarse jump may not cross an explicit hard minimum.  The exact
# minimum is tested even when it is not aligned to either the coarse step or
# final resolution.
APO_STATE=()
APO_CPU_MIN=3003
APO_CPU_MAX=3050
APO_CPU_RESOLUTION_MHZ=5
APO_CPU_SEARCH_DIRECTION=descending
apo_state_set CPU_FAILURE_BOUNDARY 3050
HARD_MIN_CALLS=()
apo_test_candidate() { HARD_MIN_CALLS+=("CPU:$1"); return 0; }
apo_auto_descend_to_pass CPU 2400 960 cpu
[[ ${HARD_MIN_CALLS[*]} == 'CPU:3003' ]]
[[ $(apo_state_get CPU_REVERSE_PASS '') == 3003 ]]

APO_STATE=()
APO_GPU_MIN=1102
APO_GPU_MAX=1120
APO_GPU_RESOLUTION_MHZ=1
APO_GPU_SEARCH_DIRECTION=descending
apo_state_set GPU_FAILURE_BOUNDARY 1120
HARD_MIN_CALLS=()
apo_test_candidate() { HARD_MIN_CALLS+=("GPU:$2"); return 0; }
apo_auto_descend_to_pass GPU 960 3100 combined
[[ ${HARD_MIN_CALLS[*]} == 'GPU:1102' ]]
[[ $(apo_state_get GPU_REVERSE_PASS '') == 1102 ]]

printf 'test_selection: PASS\n'
