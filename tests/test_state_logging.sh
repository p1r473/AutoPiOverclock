#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
APO_ROOT=$ROOT
source "$ROOT/lib/common.sh"
source "$ROOT/lib/state.sh"
source "$ROOT/lib/logging.sh"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

APO_OUTPUT_DIR=$TEMP_DIR
APO_TARGET_SLUG=fixture-target
APO_RAW_TARGET=fixture-target
APO_REMOTE_TARGET="$(id -un)@fixture-target"
APO_TARGET_HOST=fixture-target
APO_MODE_REQUESTED=auto
apo_init_artifacts
FIRST_RUN=$APO_RUN_ID
[[ $FIRST_RUN =~ ^[0-9]{8}-[0-9]{6}-[0-9a-f]{16}$ ]]
apo_state_initialize
apo_state_set MULTILINE $'line one\nline two with spaces'
STATE_DURABILITY_TRACE="$TEMP_DIR/state-durability.trace"
sync() { printf 'sync:%s\n' "$1" >> "$STATE_DURABILITY_TRACE"; command sync "$@"; }
mv() {
    local -a move_args=("$@")
    local move_count=${#move_args[@]}
    printf 'mv:%s:%s\n' "${move_args[$((move_count - 2))]}" "${move_args[$((move_count - 1))]}" >> "$STATE_DURABILITY_TRACE"
    command mv "$@"
}
: > "$STATE_DURABILITY_TRACE"
apo_state_save
mapfile -t durability_calls < "$STATE_DURABILITY_TRACE"
[[ ${#durability_calls[@]} == 4 ]]
[[ ${durability_calls[0]} == sync:"${APO_STATE_FILE}.tmp."* ]]
[[ ${durability_calls[1]} == mv:"${APO_STATE_FILE}.tmp."*:"$APO_STATE_FILE" ]]
[[ ${durability_calls[2]} == sync:"$APO_STATE_FILE" ]]
[[ ${durability_calls[3]} == sync:"$TEMP_DIR" ]]
FIRST_STATE=$APO_STATE_FILE
SENTINEL="$TEMP_DIR/fixture-target-old-run.log"
printf keep > "$SENTINEL"
apo_event test INFO '' 'event one'
FIRST_CANDIDATE_LOG=$(apo_candidate_log_file candidate)
: > "$FIRST_CANDIDATE_LOG"
SECOND_CANDIDATE_LOG=$(apo_candidate_log_file candidate)
[[ $FIRST_CANDIDATE_LOG != "$SECOND_CANDIDATE_LOG" ]]
[[ $SECOND_CANDIDATE_LOG == *-retry-01.log ]]
apo_finalize_json
[[ -s $APO_JSON_FILE ]]

APO_STATE=()
apo_state_load "$FIRST_STATE"
[[ $(apo_state_get MULTILINE) == $'line one\nline two with spaces' ]]

# Saved artifact path values are compatibility metadata, never write
# authority. Attach from the verified state pathname and keep observers from
# creating or timestamping anything, even when those values are tampered.
(
    APO_COMMAND=status
    APO_STATE_FILE=$FIRST_STATE
    APO_STATE=()
    apo_state_load "$FIRST_STATE"
    tampered_dir="$TEMP_DIR/tampered-artifacts"
    apo_state_set LOG_FILE "$tampered_dir/arbitrary.log"
    apo_state_set CSV_FILE "$tampered_dir/arbitrary.csv"
    apo_state_set JSONL_FILE "$tampered_dir/arbitrary.jsonl"
    apo_state_set JSON_FILE "$tampered_dir/arbitrary.json"
    apo_state_set SUMMARY_FILE "$tampered_dir/arbitrary-summary.txt"
    apo_state_set EFFECTIVE_CONFIG_FILE "$tampered_dir/arbitrary.conf"
    apo_state_set DISCOVERY_FILE "$tampered_dir/arbitrary-discovery.txt"
    apo_attach_artifacts_from_state
    expected_prefix=${FIRST_STATE%.state}
    [[ $APO_RUN_PREFIX == "$expected_prefix" ]]
    [[ $APO_LOG_FILE == "${expected_prefix}.log" ]]
    [[ $APO_CSV_FILE == "${expected_prefix}.csv" ]]
    [[ $APO_JSONL_FILE == "${expected_prefix}.jsonl" ]]
    [[ $APO_JSON_FILE == "${expected_prefix}.json" ]]
    [[ $APO_SUMMARY_FILE == "${expected_prefix}-summary.txt" ]]
    [[ $APO_EFFECTIVE_CONFIG_FILE == "${expected_prefix}.conf" ]]
    [[ $APO_DISCOVERY_FILE == "${expected_prefix}-discovery.txt" ]]
    [[ ! -e $tampered_dir ]]
)

# Observer cleanup preserves its exit status without changing state, finalizing
# JSON, cleaning workers, or invoking recovery. These stubs turn any such
# side effect into a visible regression marker.
OBSERVER_MARKER="$TEMP_DIR/observer-cleanup-mutated"
FIRST_STATE_HASH=$(sha256sum "$FIRST_STATE" | awk '{print $1}')
for observer_command in status summary report; do
    observer_status=0
    if (
        APO_CLI_LIBRARY_ONLY=1
        export APO_CLI_LIBRARY_ONLY
        # shellcheck source=/dev/null
        source "$ROOT/autopioverclock"
        APO_COMMAND=$observer_command
        APO_STATE_FILE=$FIRST_STATE
        APO_STATE=()
        apo_state_load "$FIRST_STATE"
        apo_state_set STATUS RUNNING
        APO_JSONL_FILE=$FIRST_STATE
        APO_HAVE_REMOTE_CONTEXT=1
        APO_MUTATING_COMMAND=1
        apo_state_fail() { printf 'state-fail\n' >> "$OBSERVER_MARKER"; }
        apo_state_interrupt() { printf 'state-interrupt\n' >> "$OBSERVER_MARKER"; }
        apo_finalize_json() { printf 'json-finalize\n' >> "$OBSERVER_MARKER"; }
        apo_recover_normal() { printf 'remote-recovery\n' >> "$OBSERVER_MARKER"; }
        apo_profile_cleanup_worker() { printf 'worker-cleanup\n' >> "$OBSERVER_MARKER"; }
        set +e
        false
        apo_cleanup_handler
    ); then
        echo "$observer_command cleanup unexpectedly returned success" >&2
        exit 1
    else
        observer_status=$?
    fi
    [[ $observer_status == 1 ]]
done
[[ ! -e $OBSERVER_MARKER ]]
[[ $(sha256sum "$FIRST_STATE" | awk '{print $1}') == "$FIRST_STATE_HASH" ]]

# Even a matching, tampered state file cannot turn a saved run ID into the
# special `.` or `..` path segments used by target-side worker directories.
TAMPERED_STATE="$TEMP_DIR/fixture-target-safe-selection.state"
apo_state_set RUN_ID '..'
APO_STATE_FILE=$TAMPERED_STATE
apo_state_save
set +e
tampered_output=$("$ROOT/autopioverclock" status fixture-target --output-dir "$TEMP_DIR" --run-id safe-selection 2>&1)
tampered_status=$?
set -e
if (( tampered_status != APO_EXIT_INTERNAL )) || [[ $tampered_output != *'Saved state contains an invalid run ID.'* ]]; then
    printf 'tampered saved run ID was not rejected before profile loading (rc=%s):\n%s\n' "$tampered_status" "$tampered_output" >&2
    exit 1
fi
APO_STATE=()
apo_state_load "$FIRST_STATE"

apo_init_artifacts
[[ $APO_RUN_ID != "$FIRST_RUN" ]]
SECOND_RUN=$APO_RUN_ID
[[ -f $SENTINEL ]]
[[ -L "$TEMP_DIR/fixture-target-latest.log" ]]
[[ $(find "$TEMP_DIR" -mindepth 1 -type d | wc -l) -eq 0 ]]

# Collision-resistant run IDs must also isolate remote workers. Cleanup is
# deliberately scoped to the exact current run directory, never a shared
# parent or wildcard that could remove another run still in progress.
for profile_name in debian batocera; do
    case $profile_name in
        debian) expected_base=/tmp/autopioverclock- ;;
        batocera) expected_base=/userdata/system/autopioverclock/runs/ ;;
    esac
    APO_RUN_ID=$FIRST_RUN
    # shellcheck source=/dev/null
    source "$ROOT/profiles/${profile_name}.sh"
    first_remote_dir=$APO_REMOTE_WORK_DIR
    first_remote_worker=$APO_REMOTE_WORKER
    APO_RUN_ID=$SECOND_RUN
    # shellcheck source=/dev/null
    source "$ROOT/profiles/${profile_name}.sh"
    second_remote_dir=$APO_REMOTE_WORK_DIR
    second_remote_worker=$APO_REMOTE_WORKER
    [[ $first_remote_dir == "$expected_base$FIRST_RUN" ]]
    [[ $second_remote_dir == "$expected_base$SECOND_RUN" ]]
    [[ $first_remote_dir != "$second_remote_dir" ]]
    [[ $first_remote_worker == "$first_remote_dir/worker.sh" ]]
    [[ $second_remote_worker == "$second_remote_dir/worker.sh" ]]

    declare -a cleanup_commands=()
    apo_remote_root() { cleanup_commands+=("$1"); }
    apo_profile_cleanup_worker
    [[ ${#cleanup_commands[@]} == 1 ]]
    [[ ${cleanup_commands[0]} == "rm -rf $(apo_sh_quote "$second_remote_dir")" ]]
    [[ ${cleanup_commands[0]} != *"$first_remote_dir"* ]]
    [[ ${cleanup_commands[0]} != *'*'* ]]
done

source "$ROOT/lib/report.sh"
APO_VERSION=fixture
APO_REDACT=0
apo_state_set CFG_MAX_FAN 0
status_output=$(apo_print_status)
grep -Fq 'Max fan tuning: disabled' <<< "$status_output"
grep -Fq 'Gate retries:   0/5 context=none' <<< "$status_output"
APO_RUN_PREFIX="$TEMP_DIR/fixture-report"
report_output=$(apo_generate_report)
grep -Fq 'Maximum fan cooling during tuning: disabled' "$TEMP_DIR/fixture-report-report.txt"
grep -Fq 'Automatic gate retries: 0/5, context=none' "$TEMP_DIR/fixture-report-report.txt"
grep -Fq 'Report file:' <<< "$report_output"

# Every state scalar rendered by status/summary/report passes through one terminal-safe
# boundary. Printable UTF-8 is retained; line breaks, ANSI escapes, and other
# controls cannot forge additional output lines or terminal instructions.
SCALAR_INJECTION=$'printable-value\nFORGED-SCALAR\r\e[31mRED\e[0m\tTAB\001CTRL\177'
[[ $(apo_report_sanitize_scalar 'plain ASCII / café') == 'plain ASCII / café' ]]
[[ $(apo_report_sanitize_scalar "$SCALAR_INJECTION") == 'printable-value?FORGED-SCALAR??[31mRED?[0m?TAB?CTRL?' ]]
for rendered_key in \
    RUN_ID ORIGIN_COMMAND REMOTE_TARGET PROFILE MODE_EFFECTIVE STATUS PHASE SUBPHASE \
    NORMAL_CPU NORMAL_GPU AUTO_BASELINE_CPU AUTO_BASELINE_GPU PASSED_CPUS PASSED_GPUS \
    CPU_FAILURE_BOUNDARY GPU_FAILURE_BOUNDARY CPU_QUALIFICATION_STATUS CPU_QUALIFICATION_TARGET \
    CPU_QUALIFIED_CLOCK GPU_QUALIFICATION_STATUS GPU_QUALIFICATION_CPU GPU_QUALIFICATION_TARGET \
    GPU_QUALIFIED_CPU GPU_QUALIFIED_CLOCK CFG_QUALIFICATION_DURATION_S SAFE_CPU SAFE_GPU \
    RECOMMENDED_CPU RECOMMENDED_GPU FINAL_BACKOFF_COUNT FINAL_BACKOFF_CPU FINAL_BACKOFF_GPU \
    FINAL_BACKOFF_HISTORY FINAL_BACKOFF_LAST_STAGE FINAL_BACKOFF_LAST_CLASS FINAL_BACKOFF_LAST_REASON \
    FLOOR_CPU FLOOR_GPU FLOOR_VALIDATED FLOOR_DURATION_S EDGE_CPU_STATUS EDGE_CPU_TARGET \
    EDGE_CPU_FAILURE_CLASS EDGE_CPU_FAILURE_REASON CFG_EDGE_DURATION_S CFG_EDGE_ORDER POST_FLOOR_EDGE \
    SOURCE_FLOOR_RUN_ID SOURCE_FLOOR_PERMANENT_HASH POST_FLOOR_FINAL SOURCE_FINAL_RUN_ID \
    POST_FLOOR_FINAL_STAGE CFG_DURATION_POLICY CFG_FINAL_DURATION_S MANUAL_TEST_STATUS MANUAL_CPU \
    MANUAL_GPU MANUAL_MINUTES RUN_MAX_TEMP FINAL_CPU FINAL_GPU TEST_VOLTAGE VALIDATED \
    VALIDATION_DURATION_S APPLY_STATUS WATCHDOG_REPAIR_STATUS WATCHDOG_REPAIR_OLD_HASH \
    WATCHDOG_REPAIR_EXPECTED_HASH WATCHDOG_REPAIR_NEW_HASH RECOVERY_WAIT_STATUS \
    RECOVERY_WAIT_CONTEXT RECOVERY_WAIT_TIMEOUTS TRANSIENT_RETRY_COUNT TRANSIENT_RETRY_CONTEXT \
    FAILURE_CLASS FAILURE_REASON STORAGE_LAYOUT
do
    apo_state_set "$rendered_key" "$SCALAR_INJECTION"
done
sanitized_status_output=$(apo_print_status)
APO_RUN_PREFIX="$TEMP_DIR/scalar-report"
sanitized_report_output=$(apo_generate_report)
for rendered_output in "$sanitized_status_output" "$sanitized_report_output" "$(<"$TEMP_DIR/scalar-report-report.txt")"; do
    [[ $rendered_output == *'printable-value?FORGED-SCALAR??[31mRED?[0m?TAB?CTRL?'* ]]
    [[ $rendered_output != *$'\nFORGED-SCALAR'* ]]
    [[ $rendered_output != *$'\r'* ]]
    [[ $rendered_output != *$'\e'* ]]
    [[ $rendered_output != *$'\t'* ]]
    [[ $rendered_output != *$'\001'* ]]
    [[ $rendered_output != *$'\177'* ]]
done

# A public report uses a target-neutral filename and omits free-form fields
# that can contain paths, service names, addresses, or device identities.
APO_REDACT=1
PUBLIC_OUTPUT_DIR="$TEMP_DIR/private-user/sensitive-target-results"
mkdir -p "$PUBLIC_OUTPUT_DIR"
APO_OUTPUT_DIR=$PUBLIC_OUTPUT_DIR
APO_RUN_PREFIX="$PUBLIC_OUTPUT_DIR/sensitive-target-$APO_RUN_ID"
APO_STATE_FILE="$PUBLIC_OUTPUT_DIR/198-51-100-24-$APO_RUN_ID.state"
apo_state_set FAILURE_REASON 'audio identity sensitive-output-name at /media/sensitive-library'
apo_state_set FINAL_BACKOFF_LAST_REASON 'service sensitive-service-name failed'
apo_state_set EDGE_CPU_FAILURE_REASON 'address sensitive.example.invalid was unreachable'
apo_state_set STORAGE_LAYOUT 'root=/dev/sensitive-root;boot=/media/sensitive-boot'
public_report_output=$(apo_generate_report)
PUBLIC_REPORT="$PUBLIC_OUTPUT_DIR/autopioverclock-$APO_RUN_ID-public-report.txt"
[[ -f $PUBLIC_REPORT ]]
[[ $(basename "$PUBLIC_REPORT") != *fixture-target* ]]
grep -Fq 'Failure reason: <redacted>' "$PUBLIC_REPORT"
grep -Fq 'Storage layout: <redacted>' "$PUBLIC_REPORT"
grep -Fq 'Review this file before sharing it.' "$PUBLIC_REPORT"
if grep -Eq 'sensitive-output-name|sensitive-library|sensitive-service-name|sensitive\.example|sensitive-root|sensitive-boot' "$PUBLIC_REPORT"; then
    echo 'public report retained a sensitive free-form value' >&2
    exit 1
fi
grep -Fq 'Report file: <redacted>/autopioverclock-' <<< "$public_report_output"
if grep -Eq 'private-user|sensitive-target-results|198-51-100-24' <<< "$public_report_output"; then
    echo 'redacted report output retained a controller path or target identity' >&2
    exit 1
fi
public_status_output=$(apo_print_status)
grep -Fq 'State file:     <redacted>' <<< "$public_status_output"
if grep -Fq '198-51-100-24' <<< "$public_status_output"; then
    echo 'redacted status retained a target-derived state filename' >&2
    exit 1
fi

# Redacted selection/load failures must not expose the CLI target, a conflicting
# stored target, the state filename, or its private output directory.
ERROR_OUTPUT_DIR="$TEMP_DIR/private-redaction-errors"
ERROR_TARGET=cli-secret-target
ERROR_RUN=missing-secret-run
mkdir -p "$ERROR_OUTPUT_DIR"
set +e
redacted_error_output=$("$ROOT/autopioverclock" status "$ERROR_TARGET" --output-dir "$ERROR_OUTPUT_DIR" --run-id "$ERROR_RUN" --redact 2>&1)
redacted_error_status=$?
set -e
[[ $redacted_error_status == "$APO_EXIT_USAGE" ]]
grep -Fq 'No saved state found for the selected target and run.' <<< "$redacted_error_output"
for forbidden_value in "$ERROR_TARGET" "$ERROR_OUTPUT_DIR" "$ERROR_RUN.state"; do
    if grep -Fq -- "$forbidden_value" <<< "$redacted_error_output"; then
        echo 'redacted missing-state error exposed selection details' >&2
        exit 1
    fi
done

CORRUPT_RUN=corrupt-secret-run
CORRUPT_STATE="$ERROR_OUTPUT_DIR/${ERROR_TARGET}-${CORRUPT_RUN}.state"
printf 'invalid-key\tAAAA\n' > "$CORRUPT_STATE"
set +e
redacted_error_output=$("$ROOT/autopioverclock" report "$ERROR_TARGET" --output-dir "$ERROR_OUTPUT_DIR" --run-id "$CORRUPT_RUN" --redact 2>&1)
redacted_error_status=$?
set -e
[[ $redacted_error_status == "$APO_EXIT_INTERNAL" ]]
grep -Fq 'Invalid state key in selected state.' <<< "$redacted_error_output"
for forbidden_value in "$ERROR_TARGET" "$ERROR_OUTPUT_DIR" "$CORRUPT_RUN.state" invalid-key; do
    if grep -Fq -- "$forbidden_value" <<< "$redacted_error_output"; then
        echo 'redacted corrupt-state error exposed state details' >&2
        exit 1
    fi
done

MISMATCH_RUN=mismatch-secret-run
MISMATCH_STATE="$ERROR_OUTPUT_DIR/${ERROR_TARGET}-${MISMATCH_RUN}.state"
(
    APO_COMMAND=status
    APO_REDACT=1
    APO_STATE=()
    apo_state_load "$FIRST_STATE"
    apo_state_set RUN_ID "$MISMATCH_RUN"
    apo_state_set REMOTE_TARGET 'root@stored-secret-target'
    APO_STATE_FILE=$MISMATCH_STATE
    apo_state_save
)
set +e
redacted_error_output=$("$ROOT/autopioverclock" status "$ERROR_TARGET" --output-dir "$ERROR_OUTPUT_DIR" --run-id "$MISMATCH_RUN" --redact 2>&1)
redacted_error_status=$?
set -e
[[ $redacted_error_status == "$APO_EXIT_USAGE" ]]
grep -Fq 'Selected state belongs to a different target.' <<< "$redacted_error_output"
for forbidden_value in "$ERROR_TARGET" stored-secret-target "$ERROR_OUTPUT_DIR" "$MISMATCH_RUN.state"; do
    if grep -Fq -- "$forbidden_value" <<< "$redacted_error_output"; then
        echo 'redacted target-mismatch error exposed selection details' >&2
        exit 1
    fi
done
printf 'test_state_logging: PASS\n'
