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
        debian) expected_base=/var/tmp/autopioverclock- ;;
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
printf 'test_state_logging: PASS\n'
