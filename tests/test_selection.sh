#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
APO_ROOT=$ROOT
source "$ROOT/lib/common.sh"

declare -Ag APO_STATE=()
declare -Ag APO_CFG=([BACKOFF_STEPS]=1)
APO_NORMAL_CPU=2400
APO_NORMAL_GPU=800

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
    apo_state_set VALIDATED 0
}
apo_summary_line() { :; }
apo_event() { :; }

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
printf 'test_selection: PASS\n'
