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
APO_AUTO_BASELINE_PROVENANCE=verified-default
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
printf 'test_selection: PASS\n'
