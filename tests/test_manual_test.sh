#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
APO_ROOT=$ROOT
source "$ROOT/lib/common.sh"
source "$ROOT/lib/config.sh"
source "$ROOT/lib/state.sh"

TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT
APO_MANUAL_TEST=1
APO_MANUAL_CPU=3100
APO_MANUAL_GPU=1150
APO_MANUAL_MINUTES=90
APO_MANUAL_DURATION_S=5400
APO_COMMAND=run
APO_CONFIG_FILE=''
APO_MODE_REQUESTED=auto
APO_EDGE_CPU_24H=0
APO_MAX_FAN=1

apo_config_load_for_new_run
[[ ${APO_CFG[CPU_CANDIDATES]} == 3100 ]]
[[ ${APO_CFG[GPU_CANDIDATES]} == 1150 ]]
[[ ${APO_CFG[CANDIDATE_DURATION_S]} == 5400 ]]
[[ ${APO_CFG[BACKOFF_STEPS]} == 0 ]]
[[ ${APO_CPU_CANDIDATES[*]} == 3100 ]]
[[ ${APO_GPU_CANDIDATES[*]} == 1150 ]]

APO_STATE=()
apo_config_store_in_state
[[ ${APO_STATE[CFG_MANUAL_TEST]} == 1 ]]
[[ ${APO_STATE[CFG_MANUAL_CPU]} == 3100 ]]
[[ ${APO_STATE[CFG_MANUAL_GPU]} == 1150 ]]
[[ ${APO_STATE[CFG_MANUAL_MINUTES]} == 90 ]]
[[ ${APO_STATE[CFG_MANUAL_DURATION_S]} == 5400 ]]

APO_MANUAL_TEST=0
APO_MANUAL_CPU=''
APO_MANUAL_GPU=''
APO_MANUAL_MINUTES=''
APO_MANUAL_DURATION_S=''
apo_config_restore_from_state
[[ $APO_MANUAL_TEST == 1 ]]
[[ $APO_MANUAL_CPU == 3100 && $APO_MANUAL_GPU == 1150 ]]
[[ $APO_MANUAL_MINUTES == 90 && $APO_MANUAL_DURATION_S == 5400 ]]

APO_RUN_ID=manual-fixture
apo_write_effective_config "$TEMP_DIR/manual.conf"
grep -Fq '# manual_stability_test=CPU:3100MHz GPU:1150MHz duration:5400s; never eligible for permanent apply' "$TEMP_DIR/manual.conf"

# Exact tests may use the same 1-168 hour range as final validation without
# widening the advanced automatic candidate-duration limit.
APO_MANUAL_MINUTES=10080
APO_MANUAL_DURATION_S=604800
apo_config_load_for_new_run
[[ ${APO_CFG[CANDIDATE_DURATION_S]} == 604800 ]]
apo_config_validate
APO_STATE=()
apo_config_store_in_state
APO_MANUAL_TEST=0
APO_MANUAL_MINUTES=''
APO_MANUAL_DURATION_S=''
apo_config_restore_from_state
[[ $APO_MANUAL_MINUTES == 10080 && $APO_MANUAL_DURATION_S == 604800 ]]
APO_MANUAL_MINUTES=90
APO_MANUAL_DURATION_S=5400

APO_STATE=()
APO_STATE_FILE="$TEMP_DIR/manual.state"
APO_LOG_FILE="$TEMP_DIR/manual.log"
APO_CSV_FILE="$TEMP_DIR/manual.csv"
APO_JSONL_FILE="$TEMP_DIR/manual.jsonl"
APO_SUMMARY_FILE="$TEMP_DIR/manual-summary.txt"
: > "$APO_LOG_FILE"
: > "$APO_CSV_FILE"
: > "$APO_JSONL_FILE"
: > "$APO_SUMMARY_FILE"
apo_state_set FORMAT_VERSION 1
apo_state_set STATUS RUNNING
apo_state_set PHASE MANUAL_TEST
apo_state_set APPLY_STATUS NOT_APPLIED
apo_event() { :; }
apo_summary_line() { printf '%s\n' "$*" >> "$APO_SUMMARY_FILE"; }
apo_state_save() { :; }
source "$ROOT/lib/candidates.sh"

# A headless/manual run skips graphical GPU smoke but must still route to the
# exact requested pair instead of entering the automatic CPU sweep.
APO_REQUIRE_GPU_STRESS=0
apo_prove_tryboot_recovery() { return 0; }
apo_run_manual_test() { apo_state_set MANUAL_ROUTED 1; apo_state_set PHASE COMPLETE; }
apo_state_set PHASE TRYBOOT_PROOF
apo_run_tuning
[[ $(apo_state_get MANUAL_ROUTED 0) == 1 ]]
unset -f apo_prove_tryboot_recovery apo_run_manual_test
source "$ROOT/lib/candidates.sh"

CANDIDATE_ARGS=''
apo_test_candidate() {
    CANDIDATE_ARGS="$*"
    apo_state_set RUN_MAX_TEMP 64.2
    APO_LAST_CLASS=PASS
    APO_LAST_REASON='manual fixture passed'
}
apo_run_manual_test
[[ $CANDIDATE_ARGS == '3100 1150 manual-cpu-3100_gpu-1150 combined' ]]
[[ $(apo_state_get STATUS) == PASS ]]
[[ $(apo_state_get PHASE) == COMPLETE ]]
[[ $(apo_state_get SUBPHASE) == MANUAL_TEST_PASSED ]]
[[ $(apo_state_get MANUAL_TEST_STATUS) == PASS ]]
[[ $(apo_state_get VALIDATED) == 0 ]]
[[ $(apo_state_get APPLY_STATUS) == NOT_APPLIED ]]
grep -Fq 'MANUAL STABILITY TEST: PASS' "$APO_SUMMARY_FILE"
grep -Fq 'cannot be applied' "$APO_SUMMARY_FILE"

APO_STATE=()
apo_state_set FORMAT_VERSION 1
apo_state_set STATUS RUNNING
apo_state_set PHASE MANUAL_TEST
apo_state_set APPLY_STATUS NOT_APPLIED
APO_LAST_CLASS=''
APO_LAST_REASON=''
apo_test_candidate() {
    APO_LAST_CLASS=STABILITY_FAILURE
    APO_LAST_REASON='manual fixture instability'
    return 1
}
if apo_run_manual_test; then
    echo 'manual-test failure fixture unexpectedly passed' >&2
    exit 1
fi
[[ $(apo_state_get STATUS) == FAILED ]]
[[ $(apo_state_get MANUAL_TEST_STATUS) == FAILED ]]
[[ $(apo_state_get FAILURE_CLASS) == STABILITY_FAILURE ]]
[[ $(apo_state_get FAILURE_REASON) == 'manual fixture instability' ]]
[[ $(apo_state_get VALIDATED 0) == 0 ]]
[[ $(apo_state_get APPLY_STATUS NOT_APPLIED) == NOT_APPLIED ]]

printf 'test_manual_test: PASS\n'
