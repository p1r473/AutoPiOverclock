#!/usr/bin/env bash
# Atomic non-executable state. Values are base64 encoded and never sourced.

declare -Ag APO_STATE=()
declare -Ag APO_STATE_ENCODED_CACHE=()
declare -Ag APO_STATE_ENCODED_VALUES=()
APO_STATE_BASE64_DECODE_OPTION=''
APO_STATE_ENCODE_LAST_STAGE=''
APO_STATE_ENCODE_LAST_INPUT_RC=''
APO_STATE_ENCODE_LAST_BASE64_RC=''
APO_STATE_ENCODE_LAST_STDERR=''

readonly APO_CURRENT_RUN_SCHEMA=10
readonly APO_CURRENT_VALIDATION_SCHEMA=8
readonly APO_STATE_ENCODE_ATTEMPTS=3

apo_state_valid_key() { [[ ${1-} =~ ^[A-Z][A-Z0-9_]*$ ]]; }
apo_state_encode_input() { printf '%s' "${1-}"; }
apo_state_encode_once() {
    local state_value=$1 output_name=$2 input_file=$3 output_file=$4 error_file=$5 input_rc
    local -n encoded_output=$output_name
    encoded_output=''
    APO_STATE_ENCODE_LAST_STAGE=prepare-error
    APO_STATE_ENCODE_LAST_INPUT_RC=not-run
    APO_STATE_ENCODE_LAST_BASE64_RC=not-run
    APO_STATE_ENCODE_LAST_STDERR=''
    if ! : > "$error_file"; then
        APO_STATE_ENCODE_LAST_STDERR='could not prepare the encoder error file'
        return 1
    fi
    APO_STATE_ENCODE_LAST_STAGE=input
    if apo_state_encode_input "$state_value" 2>> "$error_file" > "$input_file"; then
        APO_STATE_ENCODE_LAST_INPUT_RC=0
    else
        input_rc=$?
        APO_STATE_ENCODE_LAST_INPUT_RC=$input_rc
        IFS= read -r -d '' APO_STATE_ENCODE_LAST_STDERR < "$error_file" || true
        return 1
    fi
    APO_STATE_ENCODE_LAST_STAGE=base64
    if base64 2>> "$error_file" < "$input_file" > "$output_file"; then
        APO_STATE_ENCODE_LAST_BASE64_RC=0
    else
        APO_STATE_ENCODE_LAST_BASE64_RC=$?
    fi
    IFS= read -r -d '' APO_STATE_ENCODE_LAST_STDERR < "$error_file" || true
    if [[ $APO_STATE_ENCODE_LAST_INPUT_RC == 0 && $APO_STATE_ENCODE_LAST_BASE64_RC == 0 ]]; then
        IFS= read -r -d '' encoded_output < "$output_file" || true
        encoded_output=${encoded_output//$'\n'/}
        return 0
    fi
    return 1
}

apo_state_encode_log_failure() {
    local state_key=$1 attempt=$2 severity=WARN timestamp stderr_excerpt stderr_quoted
    local open_fds=unknown nofile_limit=unknown nproc_limit=unknown system_tasks=unknown
    local mem_available_kb=unknown file_handles_allocated=unknown cgroup_path='' cgroup_pids=unknown cgroup_pids_max=unknown
    local rendered limit_line mem_key mem_value
    local -a fd_paths=()
    (( attempt == APO_STATE_ENCODE_ATTEMPTS )) && severity=ERROR
    printf -v timestamp '%(%Y-%m-%d %H:%M:%S)T' -1
    stderr_excerpt=${APO_STATE_ENCODE_LAST_STDERR:0:512}
    printf -v stderr_quoted '%q' "$stderr_excerpt"
    fd_paths=(/proc/$BASHPID/fd/*)
    if [[ -e ${fd_paths[0]} ]]; then open_fds=${#fd_paths[@]}; fi
    while IFS= read -r limit_line; do
        if [[ $limit_line =~ ^Max[[:space:]]open[[:space:]]files[[:space:]]+([^[:space:]]+) ]]; then
            nofile_limit=${BASH_REMATCH[1]}
        elif [[ $limit_line =~ ^Max[[:space:]]processes[[:space:]]+([^[:space:]]+) ]]; then
            nproc_limit=${BASH_REMATCH[1]}
        fi
    done < "/proc/$BASHPID/limits"
    if read -r _ _ _ system_tasks _ < /proc/loadavg; then :; else system_tasks=unknown; fi
    while read -r mem_key mem_value _; do
        if [[ $mem_key == MemAvailable: ]]; then mem_available_kb=$mem_value; break; fi
    done < /proc/meminfo
    read -r file_handles_allocated _ < /proc/sys/fs/file-nr || file_handles_allocated=unknown
    while IFS=: read -r _ _ cgroup_path; do
        [[ -n $cgroup_path ]] && break
    done < "/proc/$BASHPID/cgroup"
    if [[ -n $cgroup_path && -r /sys/fs/cgroup$cgroup_path/pids.current ]]; then
        read -r cgroup_pids < "/sys/fs/cgroup$cgroup_path/pids.current" || cgroup_pids=unknown
    fi
    if [[ -n $cgroup_path && -r /sys/fs/cgroup$cgroup_path/pids.max ]]; then
        read -r cgroup_pids_max < "/sys/fs/cgroup$cgroup_path/pids.max" || cgroup_pids_max=unknown
    fi
    rendered="$timestamp [$severity] state-checkpoint-encode: key=$state_key attempt=$attempt/$APO_STATE_ENCODE_ATTEMPTS stage=$APO_STATE_ENCODE_LAST_STAGE input_rc=$APO_STATE_ENCODE_LAST_INPUT_RC base64_rc=$APO_STATE_ENCODE_LAST_BASE64_RC stderr=$stderr_quoted pid=$BASHPID open_fds=$open_fds nofile_limit=$nofile_limit nproc_limit=$nproc_limit system_tasks=$system_tasks cgroup_pids=$cgroup_pids cgroup_pids_max=$cgroup_pids_max mem_available_kb=$mem_available_kb file_handles_allocated=$file_handles_allocated"
    if declare -F apo_progress_before_output >/dev/null 2>&1; then apo_progress_before_output; fi
    printf '%s\n' "$rendered" >&2
    if [[ -n ${APO_LOG_FILE:-} ]]; then printf '%s\n' "$rendered" >> "$APO_LOG_FILE" 2>/dev/null || true; fi
    if declare -F apo_progress_after_output >/dev/null 2>&1; then apo_progress_after_output; fi
}

apo_state_encode() {
    local state_value=${1-} encoded_compat
    if (( $# == 1 )); then
        encoded_compat=$(apo_state_encode_input "$state_value" | base64) || return 1
        encoded_compat=${encoded_compat//$'\n'/}
        printf '%s' "$encoded_compat"
        return 0
    fi
    (( $# == 6 )) || return 2
    local state_key=$1 output_name=$3 input_file=$4 output_file=$5 error_file=$6 attempt
    state_value=${2-}
    for (( attempt=1; attempt<=APO_STATE_ENCODE_ATTEMPTS; attempt++ )); do
        if apo_state_encode_once "$state_value" "$output_name" "$input_file" "$output_file" "$error_file"; then return 0; fi
        apo_state_encode_log_failure "$state_key" "$attempt"
    done
    return 1
}
apo_state_decode_policy_init() {
    [[ -z $APO_STATE_BASE64_DECODE_OPTION ]] || return 0
    if base64 --help 2>&1 | grep -q -- '--decode'; then
        APO_STATE_BASE64_DECODE_OPTION=--decode
    else
        APO_STATE_BASE64_DECODE_OPTION=-D
    fi
}
apo_state_decode() {
    apo_state_decode_policy_init
    printf '%s' "${1-}" | base64 "$APO_STATE_BASE64_DECODE_OPTION" 2>/dev/null
}

# Selection paths often need only a small metadata subset from many retained
# runs. Decode only those named fields; a candidate that survives this screen
# is still loaded and validated in full before it can authorize any action.
apo_state_load_fields() {
    local source_file=$1 output_name=$2 state_key encoded_value decoded_value requested_key
    local -n output_fields=$output_name
    local -A requested_fields=()
    shift 2
    [[ -f $source_file && -r $source_file ]] || return 1
    (( $# > 0 )) || return 1
    for requested_key in "$@"; do
        apo_state_valid_key "$requested_key" || return 1
        requested_fields[$requested_key]=1
    done
    output_fields=()
    apo_state_decode_policy_init
    while IFS=$'\t' read -r state_key encoded_value || [[ -n ${state_key:-} ]]; do
        [[ -n ${state_key:-} ]] || continue
        apo_state_valid_key "$state_key" || return 1
        [[ -v requested_fields[$state_key] ]] || continue
        decoded_value=$(apo_state_decode "$encoded_value") || return 1
        # The nameref resolves to an associative array; this is not arithmetic.
        # shellcheck disable=SC2004
        output_fields[$state_key]=$decoded_value
    done < "$source_file"
}

apo_state_set() {
    local state_key=$1 state_value=${2-}
    apo_state_valid_key "$state_key" || apo_die "Invalid state key: $state_key" "$APO_EXIT_INTERNAL"
    APO_STATE[$state_key]=$state_value
}

apo_state_get() {
    local state_key=$1 fallback=${2-}
    if [[ -v APO_STATE[$state_key] ]]; then printf '%s' "${APO_STATE[$state_key]}"; else printf '%s' "$fallback"; fi
}

apo_state_save() {
    local temporary_file encode_input_file encode_output_file encode_error_file state_key encoded_value
    local -A checkpoint_encoded=() checkpoint_values=()
    [[ -n ${APO_STATE_FILE:-} ]] || apo_die 'Internal error: state filename is unset.' "$APO_EXIT_INTERNAL"
    if declare -F apo_progress_checkpoint_state >/dev/null 2>&1; then apo_progress_checkpoint_state; fi
    apo_state_set UPDATED_AT "$(apo_now_iso)"
    temporary_file=$(mktemp "${APO_STATE_FILE}.tmp.XXXXXX") || apo_die 'Could not create a temporary state checkpoint.' "$APO_EXIT_INTERNAL"
    encode_input_file="${temporary_file}.encode-input"
    encode_output_file="${temporary_file}.encode-output"
    encode_error_file="${temporary_file}.encode-error"
    chmod 600 "$temporary_file" || { rm -f -- "$temporary_file"; apo_die 'Could not protect the temporary state checkpoint.' "$APO_EXIT_INTERNAL"; }
    if ! while IFS= read -r state_key; do
        if [[ -v APO_STATE_ENCODED_CACHE[$state_key] && -v APO_STATE_ENCODED_VALUES[$state_key] &&
              ${APO_STATE_ENCODED_VALUES[$state_key]} == "${APO_STATE[$state_key]}" ]]; then
            encoded_value=${APO_STATE_ENCODED_CACHE[$state_key]}
        else
            apo_state_encode "$state_key" "${APO_STATE[$state_key]}" encoded_value "$encode_input_file" "$encode_output_file" "$encode_error_file" || {
                rm -f -- "$temporary_file" "$encode_input_file" "$encode_output_file" "$encode_error_file"
                apo_die "Could not encode state key $state_key after $APO_STATE_ENCODE_ATTEMPTS attempts." "$APO_EXIT_INTERNAL"
            }
        fi
        checkpoint_encoded[$state_key]=$encoded_value
        checkpoint_values[$state_key]=${APO_STATE[$state_key]}
        printf '%s\t%s\n' "$state_key" "$encoded_value" || {
            rm -f -- "$temporary_file" "$encode_input_file" "$encode_output_file" "$encode_error_file"
            apo_die 'Could not write the temporary state checkpoint.' "$APO_EXIT_INTERNAL"
        }
    done < <(printf '%s\n' "${!APO_STATE[@]}" | LC_ALL=C sort) > "$temporary_file"; then
        rm -f -- "$temporary_file" "$encode_input_file" "$encode_output_file" "$encode_error_file"
        apo_die 'Could not complete the temporary state checkpoint.' "$APO_EXIT_INTERNAL"
    fi
    rm -f -- "$encode_input_file" "$encode_output_file" "$encode_error_file"
    sync "$temporary_file" || { rm -f -- "$temporary_file"; apo_die 'Could not durably flush the temporary state checkpoint.' "$APO_EXIT_INTERNAL"; }
    mv -f -- "$temporary_file" "$APO_STATE_FILE" || { rm -f -- "$temporary_file"; apo_die 'Could not atomically commit the state checkpoint.' "$APO_EXIT_INTERNAL"; }
    sync "$APO_STATE_FILE" || apo_die 'Could not durably flush the committed state checkpoint.' "$APO_EXIT_INTERNAL"
    sync "$(dirname "$APO_STATE_FILE")" || apo_die 'Could not durably flush the state directory checkpoint.' "$APO_EXIT_INTERNAL"
    APO_STATE_ENCODED_CACHE=()
    APO_STATE_ENCODED_VALUES=()
    for state_key in "${!checkpoint_encoded[@]}"; do
        APO_STATE_ENCODED_CACHE[$state_key]=${checkpoint_encoded[$state_key]}
        APO_STATE_ENCODED_VALUES[$state_key]=${checkpoint_values[$state_key]}
    done
}

apo_state_load() {
    local source_file=$1 source_label=$1 state_key encoded_value decoded_value state_fd
    if apo_is_redacted_observer; then source_label='selected state'; fi
    [[ -f $source_file && -r $source_file ]] || apo_die "State file not found or unreadable: $source_label" "$APO_EXIT_USAGE"
    if ! { exec {state_fd}<"$source_file"; } 2>/dev/null; then
        apo_die "State file not found or unreadable: $source_label" "$APO_EXIT_USAGE"
    fi
    APO_STATE=()
    APO_STATE_ENCODED_CACHE=()
    APO_STATE_ENCODED_VALUES=()
    apo_state_decode_policy_init
    while IFS=$'\t' read -r state_key encoded_value || [[ -n ${state_key:-} ]]; do
        [[ -n ${state_key:-} ]] || continue
        if ! apo_state_valid_key "$state_key"; then
            if apo_is_redacted_observer; then
                apo_die 'Invalid state key in selected state.' "$APO_EXIT_INTERNAL"
            fi
            apo_die "Invalid state key in $source_file: $state_key" "$APO_EXIT_INTERNAL"
        fi
        decoded_value=$(apo_state_decode "$encoded_value") || apo_die "Corrupt state value for $state_key in $source_label" "$APO_EXIT_INTERNAL"
        APO_STATE[$state_key]=$decoded_value
        # A successfully decoded token is safe to reuse while its value stays
        # unchanged. State is parsed as data and is never sourced.
        APO_STATE_ENCODED_CACHE[$state_key]=$encoded_value
        APO_STATE_ENCODED_VALUES[$state_key]=$decoded_value
    done <&"$state_fd"
    exec {state_fd}<&-
    [[ $(apo_state_get FORMAT_VERSION '') == 1 ]] || apo_die "Unsupported or missing state format in $source_label" "$APO_EXIT_INTERNAL"
    APO_STATE_FILE=$source_file
}

apo_state_initialize() {
    APO_STATE=()
    APO_STATE_ENCODED_CACHE=()
    APO_STATE_ENCODED_VALUES=()
    apo_state_set FORMAT_VERSION 1
    apo_state_set RUN_SCHEMA "$APO_CURRENT_RUN_SCHEMA"
    apo_state_set APP_VERSION "$APO_VERSION"
    apo_state_set RUN_ID "$APO_RUN_ID"
    apo_state_set CREATED_AT "$(apo_now_iso)"
    apo_state_set RAW_TARGET "$APO_RAW_TARGET"
    apo_state_set REMOTE_TARGET "$APO_REMOTE_TARGET"
    apo_state_set TARGET_HOST "$APO_TARGET_HOST"
    apo_state_set TARGET_SLUG "$APO_TARGET_SLUG"
    apo_state_set OUTPUT_DIR "$APO_OUTPUT_DIR"
    apo_state_set ORIGIN_COMMAND "${APO_ORIGIN_COMMAND:-${APO_COMMAND:-run}}"
    apo_state_set READ_ONLY_RUN "${APO_DRY_RUN:-0}"
    apo_state_set STATUS PREPARING
    apo_state_set PHASE PREPARE
    apo_state_set SUBPHASE INITIAL
    apo_state_set PROFILE ''
    apo_state_set MODE_REQUESTED "$APO_MODE_REQUESTED"
    apo_state_set MODE_EFFECTIVE ''
    apo_state_set CURRENT_CPU ''
    apo_state_set CURRENT_GPU ''
    apo_state_set AUTO_BASELINE_CPU ''
    apo_state_set AUTO_BASELINE_GPU ''
    apo_state_set AUTO_BASELINE_VOLTAGE ''
    apo_state_set AUTO_BASELINE_PROVENANCE ''
    apo_state_set AUTO_BASELINE_EVIDENCE ''
    apo_state_set SOURCE_APPLIED_RUN_ID "${APO_SOURCE_APPLIED_RUN_ID:-}"
    apo_state_set SOURCE_APPLIED_PERMANENT_HASH "${APO_SOURCE_APPLIED_PERMANENT_HASH:-}"
    apo_state_set SOURCE_APPLIED_LIVE_HASH "${APO_SOURCE_APPLIED_LIVE_HASH:-}"
    apo_state_set SOURCE_APPLIED_HASH_RELATION "${APO_SOURCE_APPLIED_HASH_RELATION:-}"
    apo_state_set SOURCE_APPLIED_HASH_EVIDENCE "${APO_SOURCE_APPLIED_HASH_EVIDENCE:-}"
    apo_state_set SOURCE_APPLIED_CPU "${APO_SOURCE_APPLIED_CPU:-}"
    apo_state_set SOURCE_APPLIED_GPU "${APO_SOURCE_APPLIED_GPU:-}"
    apo_state_set SOURCE_APPLIED_VOLTAGE "${APO_SOURCE_APPLIED_VOLTAGE:-}"
    apo_state_set SOURCE_APPLIED_PROFILE "${APO_SOURCE_APPLIED_PROFILE:-}"
    apo_state_set SOURCE_APPLIED_BOOT_CONFIG "${APO_SOURCE_APPLIED_BOOT_CONFIG:-}"
    apo_state_set SOURCE_APPLIED_TRYBOOT_CONFIG "${APO_SOURCE_APPLIED_TRYBOOT_CONFIG:-}"
    apo_state_set SOURCE_APPLIED_GPU_KEY "${APO_SOURCE_APPLIED_GPU_KEY:-}"
    apo_state_set SOURCE_AUTO_BASELINE_CPU "${APO_SOURCE_AUTO_BASELINE_CPU:-}"
    apo_state_set SOURCE_AUTO_BASELINE_GPU "${APO_SOURCE_AUTO_BASELINE_GPU:-}"
    apo_state_set SOURCE_AUTO_BASELINE_VOLTAGE "${APO_SOURCE_AUTO_BASELINE_VOLTAGE:-}"
    apo_state_set SOURCE_AUTO_BASELINE_PROVENANCE "${APO_SOURCE_AUTO_BASELINE_PROVENANCE:-}"
    apo_state_set SOURCE_AUTO_BASELINE_EVIDENCE "${APO_SOURCE_AUTO_BASELINE_EVIDENCE:-}"
    apo_state_set CPU_INDEX 0
    apo_state_set GPU_INDEX 0
    apo_state_set CPU_FAILURE_BOUNDARY ''
    apo_state_set GPU_FAILURE_BOUNDARY ''
    apo_state_set CPU_REFINE_CANDIDATES ''
    apo_state_set GPU_REFINE_CANDIDATES ''
    apo_state_set CPU_REFINE_INDEX 0
    apo_state_set GPU_REFINE_INDEX 0
    apo_state_set CPU_REFINE_COMPLETE 0
    apo_state_set GPU_REFINE_COMPLETE 0
    apo_state_set CPU_REVERSE_PASS ''
    apo_state_set GPU_REVERSE_PASS ''
    apo_state_set CPU_REVERSE_FAILURES ''
    apo_state_set GPU_REVERSE_FAILURES ''
    apo_state_set CPU_GUARD_TARGET ''
    apo_state_set GPU_GUARD_TARGET ''
    apo_state_set CPU_GUARD_VERIFIED 0
    apo_state_set GPU_GUARD_VERIFIED 0
    apo_state_set CPU_QUALIFICATION_STATUS NOT_STARTED
    apo_state_set CPU_QUALIFICATION_TARGET ''
    apo_state_set CPU_QUALIFIED_CLOCK ''
    apo_state_set CPU_QUALIFICATION_HISTORY ''
    apo_state_set CPU_QUALIFICATION_LAST_CLASS ''
    apo_state_set CPU_QUALIFICATION_LAST_REASON ''
    apo_state_set GPU_QUALIFICATION_STATUS NOT_STARTED
    apo_state_set GPU_QUALIFICATION_CPU ''
    apo_state_set GPU_QUALIFICATION_TARGET ''
    apo_state_set GPU_QUALIFIED_CPU ''
    apo_state_set GPU_QUALIFIED_CLOCK ''
    apo_state_set FLOOR_CPU ''
    apo_state_set FLOOR_GPU ''
    apo_state_set FLOOR_DURATION_S ''
    apo_state_set FLOOR_VALIDATION_SCHEMA ''
    apo_state_set FLOOR_VALIDATED 0
    apo_state_set POST_FLOOR_EDGE 0
    apo_state_set SOURCE_FLOOR_RUN_ID ''
    apo_state_set SOURCE_FLOOR_PERMANENT_HASH ''
    apo_state_set POST_FLOOR_FINAL 0
    apo_state_set POST_FLOOR_FINAL_STAGE ''
    apo_state_set SOURCE_FINAL_RUN_ID ''
    apo_state_set SOURCE_FINAL_PERMANENT_HASH ''
    apo_state_set SOURCE_FINAL_VALIDATION_DURATION_S ''
    apo_state_set SOURCE_FINAL_APPLY_BACKUP ''
    apo_state_set EDGE_CPU_TARGET ''
    apo_state_set EDGE_CPU_STATUS NOT_REQUESTED
    apo_state_set EDGE_CPU_FAILURE_CLASS ''
    apo_state_set EDGE_CPU_FAILURE_REASON ''
    apo_state_set PASSED_CPUS ''
    apo_state_set PASSED_GPUS ''
    apo_state_set RECOMMENDED_CPU ''
    apo_state_set RECOMMENDED_GPU ''
    apo_state_set FINAL_CPU ''
    apo_state_set FINAL_GPU ''
    apo_state_set VALIDATION_SCHEMA ''
    apo_state_set VALIDATION_DURATION_S ''
    apo_state_set VALIDATED 0
    apo_state_set CANDIDATE_LABEL ''
    apo_state_set CANDIDATE_CPU ''
    apo_state_set CANDIDATE_GPU ''
    apo_state_set CANDIDATE_STAGE ''
    apo_state_set FINAL_TARGET_CPU ''
    apo_state_set FINAL_TARGET_GPU ''
    apo_state_set FINAL_STAGE ''
    apo_state_set FINAL_BACKOFF_COUNT 0
    apo_state_set FINAL_BACKOFF_CPU ''
    apo_state_set FINAL_BACKOFF_GPU ''
    apo_state_set FINAL_BACKOFF_HISTORY ''
    apo_state_set FINAL_BACKOFF_LAST_STAGE ''
    apo_state_set FINAL_BACKOFF_LAST_CLASS ''
    apo_state_set FINAL_BACKOFF_LAST_REASON ''
    apo_state_set FINAL_BACKOFF_ANCHOR_CPU ''
    apo_state_set FINAL_BACKOFF_ANCHOR_GPU ''
    apo_state_set FINAL_BACKOFF_TRIAL ''
    apo_state_set FINAL_BACKOFF_ANCHOR_CPU_QUALIFIED_CLOCK ''
    # Retained-history scheduling is intentionally separate from the current
    # run's FINAL_BACKOFF_HISTORY.  The latter may describe only failures that
    # this run actually observed and replayed.
    apo_state_set HISTORY_ISOLATION_STAGE NONE
    apo_state_set HISTORY_CPU_FAILURE_BOUNDARY ''
    apo_state_set HISTORY_GPU_FAILURE_BOUNDARY ''
    apo_state_set HISTORY_PAIR_FRONTIERS ''
    apo_state_set HISTORY_PROVENANCE ''
    apo_state_set HISTORY_LEDGER_FILE ''
    apo_state_set HISTORY_SCANNED_STATES 0
    apo_state_set HISTORY_ACCEPTED_STATES 0
    apo_state_set HISTORY_EVIDENCE_COUNT 0
    apo_state_set HISTORY_ISOLATION_ANCHOR_CPU ''
    apo_state_set HISTORY_ISOLATION_ANCHOR_GPU ''
    apo_state_set HISTORY_CPU_TRIAL_CPU ''
    apo_state_set HISTORY_CPU_TRIAL_GPU ''
    apo_state_set HISTORY_GPU_TRIAL_CPU ''
    apo_state_set HISTORY_GPU_TRIAL_GPU ''
    apo_state_set HISTORY_PAIR_TRIAL_CPU ''
    apo_state_set HISTORY_PAIR_TRIAL_GPU ''
    apo_state_set HISTORY_BASE_CPU_QUALIFIED_CLOCK ''
    apo_state_set HISTORY_CPU_TRIAL_QUALIFIED_CLOCK ''
    apo_state_set HISTORY_ISOLATION_HANDOFF_CPU ''
    apo_state_set HISTORY_ISOLATION_HANDOFF_GPU ''
    apo_state_set HISTORY_ISOLATION_HISTORY ''
    apo_state_set HISTORY_FAILURE_EVENTS ''
    apo_state_set APPLY_STATUS NOT_APPLIED
    apo_state_set APPLY_OLD_HASH ''
    apo_state_set APPLY_EXPECTED_HASH ''
    apo_state_set APPLY_BACKUP ''
    apo_state_set APPLY_BOOT_ID ''
    apo_state_set APPLY_RECOVERY_ACTION ''
    apo_state_set APPLY_FAILURE_REASON ''
    apo_state_set OVERCLOCK_COMPLETE_RECORDED 0
    apo_state_set WATCHDOG_REPAIR_STATUS NOT_STARTED
    apo_state_set WATCHDOG_REPAIR_OLD_HASH ''
    apo_state_set WATCHDOG_REPAIR_EXPECTED_HASH ''
    apo_state_set WATCHDOG_REPAIR_NEW_HASH ''
    apo_state_set WATCHDOG_REPAIR_BACKUP ''
    apo_state_set FAILURE_CLASS ''
    apo_state_set FAILURE_REASON ''
    apo_state_set LAST_FAILURE_CLASS ''
    apo_state_set LAST_FAILURE_REASON ''
    apo_state_set TRYBOOT_EXPECTED 0
    apo_state_set TRYBOOT_FILE_MAY_EXIST 0
    apo_state_set TRYBOOT_OWNED_HASH ''
    apo_state_set TRYBOOT_RESERVATION_HASH ''
    apo_state_set TRYBOOT_OWNERSHIP_TOKEN ''
    apo_state_set TRYBOOT_QUARANTINE_PATH ''
    apo_state_set TRYBOOT_LAST_HASH ''
    apo_state_set MUTATIONS_STARTED 0
    apo_state_set BASELINE_BOOT_ID ''
    apo_state_set LAST_BOOT_ID ''
    apo_state_set CANDIDATE_BOOT_ID ''
    apo_state_set NORMAL_BOOT_ID ''
    apo_state_set RECOVERY_WAIT_STATUS IDLE
    apo_state_set RECOVERY_WAIT_CONTEXT ''
    apo_state_set RECOVERY_WAIT_STARTED_AT ''
    apo_state_set RECOVERY_WAIT_TIMEOUTS 0
    apo_state_set TRANSIENT_RETRY_CONTEXT ''
    apo_state_set TRANSIENT_RETRY_COUNT 0
    apo_state_set NORMAL_RETURN_RETRY_PENDING 0
    apo_state_set NORMAL_RETURN_RETRY_SOURCE ''
    apo_state_set NORMAL_RETURN_RETRY_REASON ''
    apo_state_set MANUAL_TEST "${APO_MANUAL_TEST:-0}"
    apo_state_set MANUAL_CPU "${APO_MANUAL_CPU:-}"
    apo_state_set MANUAL_GPU "${APO_MANUAL_GPU:-}"
    apo_state_set MANUAL_MINUTES "${APO_MANUAL_MINUTES:-}"
    apo_state_set MANUAL_DURATION_S "${APO_MANUAL_DURATION_S:-}"
    apo_state_set MANUAL_TEST_STATUS "$([[ ${APO_MANUAL_TEST:-0} == 1 ]] && printf READY || printf NOT_REQUESTED)"
    apo_state_set PROGRESS_ACTIVE_SECONDS 0
    apo_state_set PROGRESS_LAST_TEMP ''
    apo_state_set PROGRESS_LAST_CPU ''
    apo_state_set PROGRESS_LAST_GPU ''
    apo_state_set PROGRESS_LAST_THROTTLE ''
    apo_state_set PROGRESS_LAST_FAN ''
    apo_state_set PROGRESS_STRESS_LABEL ''
    apo_state_set PROGRESS_STRESS_ELAPSED 0
    apo_state_set PROGRESS_STRESS_DURATION 0
    apo_state_set RUN_MAX_TEMP ''
    apo_state_set REMOTE_STRESS_STATUS IDLE
    apo_state_set REMOTE_STRESS_JOB_ID ''
    apo_state_set REMOTE_STRESS_TOKEN ''
    apo_state_set REMOTE_STRESS_SPEC_HASH ''
    apo_state_set REMOTE_STRESS_SOURCE_BOOT_ID ''
    apo_state_set REMOTE_STRESS_PHASE ''
    apo_state_set REMOTE_STRESS_DURATION_S ''
    apo_state_set REMOTE_STRESS_SEGMENT_DURATION_S ''
    apo_state_set REMOTE_STRESS_START_EPOCH ''
    apo_state_set REMOTE_STRESS_LAST_SEEN_EPOCH ''
    apo_state_set REMOTE_STRESS_CONFIRMED_ELAPSED_S ''
    apo_state_set REMOTE_STRESS_CREDIT_CONTEXT ''
    apo_state_set REMOTE_STRESS_CREDIT_SECONDS 0
    apo_state_set REMOTE_STRESS_CREDIT_DURATION_S ''
    apo_state_set REMOTE_STRESS_CREDIT_EVENT_ID ''
    apo_state_set UNATTRIBUTED_REBOOT_REPLAY_CONTEXT ''
    apo_state_set UNATTRIBUTED_REBOOT_REPLAY_COUNT 0
    apo_state_set NETWORK_WATCHDOG_REPLAY_COUNT 0
    apo_state_set NETWORK_WATCHDOG_LAST_EVENT_ID ''
    apo_state_set NETWORK_WATCHDOG_LAST_TARGET ''
    apo_state_save
}

apo_state_phase() {
    apo_state_set PHASE "$1"
    apo_state_set SUBPHASE "${2:-}"
    apo_state_set STATUS "${3:-RUNNING}"
    apo_state_save
    if declare -F apo_progress_render >/dev/null 2>&1; then apo_progress_render; fi
}

apo_state_fail() {
    local failure_class=$1 failure_reason=$2
    apo_state_set STATUS FAILED
    apo_state_set FAILURE_CLASS "$failure_class"
    apo_state_set FAILURE_REASON "$failure_reason"
    apo_state_save
    apo_event failure ERROR "$failure_class" "$failure_reason"
}

apo_state_interrupt() {
    local interruption_reason=$1
    apo_state_set STATUS INTERRUPTED
    apo_state_set FAILURE_CLASS ''
    apo_state_set FAILURE_REASON "$interruption_reason"
    apo_state_save
    apo_event interrupted WARN '' "$interruption_reason"
}

apo_state_clear_final_validation() {
    apo_state_set FINAL_CPU ''
    apo_state_set FINAL_GPU ''
    apo_state_set VALIDATION_SCHEMA ''
    apo_state_set VALIDATION_DURATION_S ''
    apo_state_set VALIDATED 0
}

apo_state_complete() {
    local final_cpu=$1 final_gpu=$2 validation_duration=$3
    [[ -n $final_cpu && -n $final_gpu ]] &&
        apo_validate_uint_range "$validation_duration" "$APO_MIN_TUNING_DURATION_S" "$APO_MAX_TUNING_DURATION_S" ||
        apo_die 'Internal error: final validation completion lacks clock or endurance-duration evidence.' "$APO_EXIT_INTERNAL"
    apo_state_set FINAL_CPU "$final_cpu"
    apo_state_set FINAL_GPU "$final_gpu"
    apo_state_set VALIDATION_SCHEMA "$APO_CURRENT_VALIDATION_SCHEMA"
    apo_state_set VALIDATION_DURATION_S "$validation_duration"
    apo_state_set STATUS PASS
    apo_state_set PHASE COMPLETE
    apo_state_set SUBPHASE DONE
    apo_state_set FINAL_STAGE COMPLETE
    apo_state_set VALIDATED 1
    apo_state_save
}
