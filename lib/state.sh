#!/usr/bin/env bash
# Atomic non-executable state. Values are base64 encoded and never sourced.

declare -Ag APO_STATE=()
APO_STATE_BASE64_DECODE_OPTION=''

readonly APO_CURRENT_RUN_SCHEMA=10
readonly APO_CURRENT_VALIDATION_SCHEMA=8

apo_state_valid_key() { [[ ${1-} =~ ^[A-Z][A-Z0-9_]*$ ]]; }
apo_state_encode() { printf '%s' "${1-}" | base64 | tr -d '\n'; }
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
    local temporary_file state_key encoded_value
    [[ -n ${APO_STATE_FILE:-} ]] || apo_die 'Internal error: state filename is unset.' "$APO_EXIT_INTERNAL"
    if declare -F apo_progress_checkpoint_state >/dev/null 2>&1; then apo_progress_checkpoint_state; fi
    apo_state_set UPDATED_AT "$(apo_now_iso)"
    temporary_file=$(mktemp "${APO_STATE_FILE}.tmp.XXXXXX") || apo_die 'Could not create a temporary state checkpoint.' "$APO_EXIT_INTERNAL"
    chmod 600 "$temporary_file" || { rm -f -- "$temporary_file"; apo_die 'Could not protect the temporary state checkpoint.' "$APO_EXIT_INTERNAL"; }
    if ! while IFS= read -r state_key; do
        encoded_value=$(apo_state_encode "${APO_STATE[$state_key]}") || { rm -f -- "$temporary_file"; apo_die "Could not encode state key $state_key." "$APO_EXIT_INTERNAL"; }
        printf '%s\t%s\n' "$state_key" "$encoded_value" || { rm -f -- "$temporary_file"; apo_die 'Could not write the temporary state checkpoint.' "$APO_EXIT_INTERNAL"; }
    done < <(printf '%s\n' "${!APO_STATE[@]}" | LC_ALL=C sort) > "$temporary_file"; then
        rm -f -- "$temporary_file"
        apo_die 'Could not complete the temporary state checkpoint.' "$APO_EXIT_INTERNAL"
    fi
    sync "$temporary_file" || { rm -f -- "$temporary_file"; apo_die 'Could not durably flush the temporary state checkpoint.' "$APO_EXIT_INTERNAL"; }
    mv -f -- "$temporary_file" "$APO_STATE_FILE" || { rm -f -- "$temporary_file"; apo_die 'Could not atomically commit the state checkpoint.' "$APO_EXIT_INTERNAL"; }
    sync "$APO_STATE_FILE" || apo_die 'Could not durably flush the committed state checkpoint.' "$APO_EXIT_INTERNAL"
    sync "$(dirname "$APO_STATE_FILE")" || apo_die 'Could not durably flush the state directory checkpoint.' "$APO_EXIT_INTERNAL"
}

apo_state_load() {
    local source_file=$1 source_label=$1 state_key encoded_value decoded_value state_fd
    if apo_is_redacted_observer; then source_label='selected state'; fi
    [[ -f $source_file && -r $source_file ]] || apo_die "State file not found or unreadable: $source_label" "$APO_EXIT_USAGE"
    if ! { exec {state_fd}<"$source_file"; } 2>/dev/null; then
        apo_die "State file not found or unreadable: $source_label" "$APO_EXIT_USAGE"
    fi
    APO_STATE=()
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
    done <&"$state_fd"
    exec {state_fd}<&-
    [[ $(apo_state_get FORMAT_VERSION '') == 1 ]] || apo_die "Unsupported or missing state format in $source_label" "$APO_EXIT_INTERNAL"
    APO_STATE_FILE=$source_file
}

apo_state_initialize() {
    APO_STATE=()
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
    [[ -n $final_cpu && -n $final_gpu && $validation_duration =~ ^[1-9][0-9]{0,6}$ ]] ||
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
