#!/usr/bin/env bash
# Atomic non-executable state. Values are base64 encoded and never sourced.

declare -Ag APO_STATE=()

readonly APO_CURRENT_RUN_SCHEMA=8
readonly APO_CURRENT_VALIDATION_SCHEMA=7

apo_state_valid_key() { [[ ${1-} =~ ^[A-Z][A-Z0-9_]*$ ]]; }
apo_state_encode() { printf '%s' "${1-}" | base64 | tr -d '\n'; }
apo_state_decode() {
    if base64 --help 2>&1 | grep -q -- '--decode'; then printf '%s' "${1-}" | base64 --decode 2>/dev/null;
    else printf '%s' "${1-}" | base64 -D 2>/dev/null; fi
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
    local source_file=$1 state_key encoded_value decoded_value
    [[ -f $source_file ]] || apo_die "State file not found: $source_file" "$APO_EXIT_USAGE"
    APO_STATE=()
    while IFS=$'\t' read -r state_key encoded_value || [[ -n ${state_key:-} ]]; do
        [[ -n ${state_key:-} ]] || continue
        apo_state_valid_key "$state_key" || apo_die "Invalid state key in $source_file: $state_key" "$APO_EXIT_INTERNAL"
        decoded_value=$(apo_state_decode "$encoded_value") || apo_die "Corrupt state value for $state_key in $source_file" "$APO_EXIT_INTERNAL"
        APO_STATE[$state_key]=$decoded_value
    done < "$source_file"
    [[ $(apo_state_get FORMAT_VERSION '') == 1 ]] || apo_die "Unsupported or missing state format in $source_file" "$APO_EXIT_INTERNAL"
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
    apo_state_set FLOOR_CPU ''
    apo_state_set FLOOR_GPU ''
    apo_state_set FLOOR_DURATION_S ''
    apo_state_set FLOOR_VALIDATION_SCHEMA ''
    apo_state_set FLOOR_VALIDATED 0
    apo_state_set POST_FLOOR_EDGE 0
    apo_state_set SOURCE_FLOOR_RUN_ID ''
    apo_state_set SOURCE_FLOOR_PERMANENT_HASH ''
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
    apo_state_save
}

apo_state_phase() {
    apo_state_set PHASE "$1"
    apo_state_set SUBPHASE "${2:-}"
    apo_state_set STATUS "${3:-RUNNING}"
    apo_state_save
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
