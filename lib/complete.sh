#!/usr/bin/env bash
# Explicit finalization of a successfully applied overclock.

APO_COMPLETE_RUN_IDS=()
APO_COMPLETE_LEASE_IDS=()
APO_COMPLETE_STALE_CONTROLLER_RUN_IDS=()
APO_COMPLETE_EXPECTED_HASH=''
APO_COMPLETE_MAINTENANCE_TEMP_FILES=()

apo_complete_valid_hash() { [[ ${1-} =~ ^[0-9a-f]{64}$ ]]; }

apo_complete_add_unique() {
    local value=$1 item
    local -n destination=$2
    for item in "${destination[@]}"; do
        [[ $item == "$value" ]] && return 0
    done
    destination+=("$value")
}

apo_complete_make_maintenance_temp() {
    local output_name=$1 label=$2 temporary_file
    local -n output_value=$output_name
    [[ $label =~ ^[a-z0-9-]+$ ]] || return 1
    temporary_file=$(mktemp "/tmp/autopioverclock-complete-${APO_TARGET_SLUG}-${label}.XXXXXX") || return 1
    chmod 600 "$temporary_file" || { rm -f -- "$temporary_file"; return 1; }
    APO_COMPLETE_MAINTENANCE_TEMP_FILES+=("$temporary_file")
    output_value=$temporary_file
}

apo_complete_cleanup_maintenance_temps() {
    local candidate expected_prefix
    expected_prefix="/tmp/autopioverclock-complete-${APO_TARGET_SLUG:-unknown}-"
    for candidate in "${APO_COMPLETE_MAINTENANCE_TEMP_FILES[@]}"; do
        case $candidate in
            "${expected_prefix}"*) ;;
            *) continue ;;
        esac
        if [[ -f $candidate && ! -L $candidate ]]; then rm -f -- "$candidate" || true; fi
    done
    APO_COMPLETE_MAINTENANCE_TEMP_FILES=()
}

apo_complete_validate_selected_run() {
    local origin status phase apply_status validated validation_schema
    origin=$(apo_state_get ORIGIN_COMMAND '')
    status=$(apo_state_get STATUS '')
    phase=$(apo_state_get PHASE '')
    apply_status=$(apo_state_get APPLY_STATUS '')
    validated=$(apo_state_get VALIDATED 0)
    validation_schema=$(apo_state_get VALIDATION_SCHEMA '')

    [[ $(apo_state_get RUN_SCHEMA '') == "$APO_CURRENT_RUN_SCHEMA" ]] ||
        apo_die 'Complete requires a run created with the current safety schema.' "$APO_EXIT_USAGE"
    [[ $origin == overclock || $origin == run ]] ||
        apo_die 'Complete accepts only a tuning run, not prepare, test, reset, or restore evidence.' "$APO_EXIT_USAGE"
    [[ $status == PASS && $phase == COMPLETE && $validated == 1 &&
       $validation_schema == "$APO_CURRENT_VALIDATION_SCHEMA" ]] ||
        apo_die 'Complete requires a fully passed current-schema final validation.' "$APO_EXIT_USAGE"
    [[ $apply_status == APPLIED ]] ||
        apo_die 'Complete requires the selected validated result to be permanently applied first.' "$APO_EXIT_USAGE"
    [[ $(apo_state_get OVERCLOCK_COMPLETE_RECORDED 0) == 1 ]] ||
        apo_die 'Complete requires the applied overclock completion checkpoint.' "$APO_EXIT_USAGE"
    if apo_remote_job_pending || [[ $(apo_state_get REMOTE_STRESS_STATUS IDLE) == RUNNING ]]; then
        apo_die 'Complete refuses a run that still owns a target-side stress job.' "$APO_EXIT_USAGE"
    fi
    [[ $(apo_state_get FINAL_CPU '') =~ ^[1-9][0-9]*$ &&
       $(apo_state_get FINAL_GPU '') =~ ^[1-9][0-9]*$ ]] ||
        apo_die 'Complete found malformed final clock evidence.' "$APO_EXIT_INTERNAL"
    apo_is_int "$(apo_state_get NORMAL_VOLTAGE '')" ||
        apo_die 'Complete found malformed applied voltage evidence.' "$APO_EXIT_INTERNAL"
    [[ ${APO_GPU_KEY:-} == gpu_freq || ${APO_GPU_KEY:-} == v3d_freq ]] ||
        apo_die 'Complete found an unsupported saved GPU clock key.' "$APO_EXIT_INTERNAL"
    apo_complete_valid_hash "$(apo_state_get PERMANENT_HASH '')" ||
        apo_die 'Complete found malformed permanent-config hash evidence.' "$APO_EXIT_INTERNAL"
}

apo_complete_collect_target_runs() {
    local state_file expected_file run_id status remote_status lease_id leased target_companion controller_status
    local -A fields=()
    local -a candidates=()
    APO_COMPLETE_RUN_IDS=()
    APO_COMPLETE_LEASE_IDS=()
    APO_COMPLETE_STALE_CONTROLLER_RUN_IDS=()
    shopt -s nullglob
    candidates=("${APO_OUTPUT_DIR}/${APO_TARGET_SLUG}-"*.state)
    shopt -u nullglob
    for state_file in "${candidates[@]}"; do
        [[ $state_file == "${APO_OUTPUT_DIR}/${APO_TARGET_SLUG}-latest.state" ]] && continue
        [[ -f $state_file && ! -L $state_file ]] ||
            apo_die "Complete found an unsafe state path and will not delete anything: $state_file" "$APO_EXIT_INTERNAL"
        fields=()
        apo_state_load_fields "$state_file" fields FORMAT_VERSION RUN_ID TARGET_SLUG REMOTE_TARGET STATUS REMOTE_STRESS_STATUS CONTROLLER_WATCHDOG_LEASE_ID CONTROLLER_WATCHDOG_LEASED CONTROLLER_WATCHDOG_STATUS NETWORK_WATCHDOG_INSTALLED_BY_RUN ||
            apo_die "Complete could not validate retained state before cleanup: $state_file" "$APO_EXIT_INTERNAL"
        [[ ${fields[FORMAT_VERSION]:-} == 1 ]] ||
            apo_die "Complete found an unsupported retained state format: $state_file" "$APO_EXIT_INTERNAL"
        if [[ ${fields[TARGET_SLUG]:-} != "$APO_TARGET_SLUG" ||
              ${fields[REMOTE_TARGET]:-} != "$APO_REMOTE_TARGET" ]]; then
            continue
        fi
        run_id=${fields[RUN_ID]:-}
        apo_is_safe_run_id "$run_id" ||
            apo_die "Complete found an invalid retained run ID: $state_file" "$APO_EXIT_INTERNAL"
        expected_file="${APO_OUTPUT_DIR}/${APO_TARGET_SLUG}-${run_id}.state"
        [[ $state_file == "$expected_file" ]] ||
            apo_die "Complete found retained state whose identity does not match its filename: $state_file" "$APO_EXIT_INTERNAL"
        status=${fields[STATUS]:-}
        remote_status=${fields[REMOTE_STRESS_STATUS]:-IDLE}
        if [[ $remote_status == RUNNING ]]; then
            apo_die "Complete refuses cleanup while retained run $run_id still owns a target-side stress job." "$APO_EXIT_USAGE"
        fi
        if [[ $status == RUNNING || $status == PREPARING ]]; then
            # complete already owns the exclusive per-target controller lock.
            # A retained controller status can therefore be stale, but target-
            # side stress ownership above remains a hard refusal.
            apo_complete_add_unique "$run_id" APO_COMPLETE_STALE_CONTROLLER_RUN_IDS
        fi
        target_companion=${fields[NETWORK_WATCHDOG_INSTALLED_BY_RUN]:-0}
        [[ $target_companion == 0 || $target_companion == 1 ]] ||
            apo_die "Complete found malformed target watchdog ownership in run $run_id." "$APO_EXIT_INTERNAL"
        if [[ $target_companion == 1 && $run_id != "$APO_RUN_ID" ]]; then
            apo_die "Complete refuses to erase run $run_id while it still owns a target watchdog companion. Resume that run to remove its companion first." "$APO_EXIT_USAGE"
        fi
        leased=${fields[CONTROLLER_WATCHDOG_LEASED]:-0}
        [[ $leased == 0 || $leased == 1 ]] ||
            apo_die "Complete found malformed controller watchdog lease state in run $run_id." "$APO_EXIT_INTERNAL"
        lease_id=${fields[CONTROLLER_WATCHDOG_LEASE_ID]:-$run_id}
        controller_status=${fields[CONTROLLER_WATCHDOG_STATUS]:-NOT_STARTED}
        if [[ $leased == 1 || $controller_status == RELEASED ]]; then
            apo_is_safe_run_id "$lease_id" ||
                apo_die "Complete found an invalid controller watchdog lease ID in run $run_id." "$APO_EXIT_INTERNAL"
            apo_complete_add_unique "$lease_id" APO_COMPLETE_LEASE_IDS
        fi
        apo_complete_add_unique "$run_id" APO_COMPLETE_RUN_IDS
    done
    apo_complete_add_unique "$APO_RUN_ID" APO_COMPLETE_RUN_IDS
}

apo_complete_cleanup_controller_watchdog_records() {
    local lease_id output_file
    if [[ $(apo_state_get COMPLETE_CONTROLLER_RELEASED 0) != 1 ]]; then
        for lease_id in "${APO_COMPLETE_LEASE_IDS[@]}"; do
            output_file=$(mktemp "${APO_RUN_PREFIX}-complete-controller-watchdog.XXXXXX") ||
                apo_die 'Complete could not create a controller watchdog cleanup result file.' "$APO_EXIT_INTERNAL"
            chmod 600 "$output_file"
            if ! apo_controller_watchdog_manager_capture release "$lease_id" "$output_file"; then
                rm -f -- "$output_file"
                apo_die "Complete could not release verified controller watchdog lease $lease_id: ${APO_LAST_REASON:-unknown manager failure}" "$APO_EXIT_RECOVERY"
            fi
            rm -f -- "$output_file"
        done
        apo_state_set COMPLETE_CONTROLLER_RELEASED 1
        apo_state_save
    fi
    apo_state_set COMPLETE_CONTROLLER_RECEIPTS_FORGETTING 1
    apo_state_save
    for lease_id in "${APO_COMPLETE_LEASE_IDS[@]}"; do
        output_file=$(mktemp "${APO_RUN_PREFIX}-complete-controller-watchdog.XXXXXX") ||
            apo_die 'Complete could not create a controller watchdog receipt cleanup result file.' "$APO_EXIT_INTERNAL"
        chmod 600 "$output_file"
        if ! apo_controller_watchdog_manager_capture forget-release "$lease_id" "$output_file"; then
            rm -f -- "$output_file"
            apo_die "Complete could not remove controller watchdog receipt $lease_id: ${APO_LAST_REASON:-unknown manager failure}" "$APO_EXIT_RECOVERY"
        fi
        rm -f -- "$output_file"
    done
    apo_state_set COMPLETE_CONTROLLER_WATCHDOG_CLEANED 1
    apo_state_save
}

apo_complete_write_run_manifest() {
    local manifest_path=$1 run_id
    umask 077
    : > "$manifest_path" || return 1
    for run_id in "${APO_COMPLETE_RUN_IDS[@]}"; do
        printf '%s\n' "$run_id" >> "$manifest_path" || return 1
    done
    chmod 600 "$manifest_path"
}

apo_complete_show_plan() {
    local diff_file=$1 current_file=$2 proposed_file=$3 diff_rc run_id
    if diff -u --label current-config.txt --label completed-config.txt "$current_file" "$proposed_file" > "$diff_file"; then
        diff_rc=0
    else
        diff_rc=$?
    fi
    (( diff_rc == 0 || diff_rc == 1 )) ||
        apo_die 'Complete could not generate the permanent-config diff.' "$APO_EXIT_APPLY"
    if declare -F apo_progress_before_output >/dev/null 2>&1; then apo_progress_before_output; fi
    printf '\n===== EXACT COMPLETED CONFIG DIFF =====\n' >&2
    if (( diff_rc == 0 )); then
        printf '(Permanent config is already in the completed form.)\n' >&2
    else
        cat "$diff_file" >&2
    fi
    printf '=======================================\n\n' >&2
    printf 'Controller and target run IDs scheduled for cleanup:\n' >&2
    for run_id in "${APO_COMPLETE_RUN_IDS[@]}"; do printf '  %s\n' "$run_id" >&2; done
    if (( ${#APO_COMPLETE_STALE_CONTROLLER_RUN_IDS[@]} > 0 )); then
        printf '\nAbandoned controller checkpoints accepted after exclusive target-lock verification:\n' >&2
        for run_id in "${APO_COMPLETE_STALE_CONTROLLER_RUN_IDS[@]}"; do printf '  %s\n' "$run_id" >&2; done
    fi
    printf '\nPermanent native watchdogs and the permanent Batocera watchdog are preserved.\n' >&2
}

apo_complete_collect_sealed_cleanup_runs() {
    local state_file expected_file run_id origin status phase failure_class remote_status
    local target_companion leased controller_status no_headroom tryboot_expected tryboot_may_exist
    local -A fields=()
    local -a candidates=()

    APO_COMPLETE_RUN_IDS=()
    APO_COMPLETE_LEASE_IDS=()
    APO_COMPLETE_STALE_CONTROLLER_RUN_IDS=()
    if [[ -e $APO_OUTPUT_DIR || -L $APO_OUTPUT_DIR ]]; then
        [[ -d $APO_OUTPUT_DIR && ! -L $APO_OUTPUT_DIR ]] ||
            apo_die 'Complete found an unsafe target runs path.' "$APO_EXIT_INTERNAL"
        shopt -s nullglob
        candidates=("${APO_OUTPUT_DIR}/${APO_TARGET_SLUG}-"*.state)
        shopt -u nullglob
    fi

    for state_file in "${candidates[@]}"; do
        [[ $state_file == "${APO_OUTPUT_DIR}/${APO_TARGET_SLUG}-latest.state" ]] && continue
        [[ -f $state_file && ! -L $state_file ]] ||
            apo_die "Complete found an unsafe state path and will not delete anything: $state_file" "$APO_EXIT_INTERNAL"
        fields=()
        apo_state_load_fields "$state_file" fields \
            FORMAT_VERSION RUN_ID TARGET_SLUG REMOTE_TARGET ORIGIN_COMMAND STATUS PHASE FAILURE_CLASS \
            REMOTE_STRESS_STATUS NETWORK_WATCHDOG_INSTALLED_BY_RUN CONTROLLER_WATCHDOG_LEASED \
            CONTROLLER_WATCHDOG_STATUS OVERCLOCK_NO_HEADROOM TRYBOOT_EXPECTED TRYBOOT_FILE_MAY_EXIST \
            TRYBOOT_OWNED_HASH TRYBOOT_RESERVATION_HASH TRYBOOT_OWNERSHIP_TOKEN TRYBOOT_QUARANTINE_PATH ||
            apo_die "Complete could not validate retained state before sealed cleanup: $state_file" "$APO_EXIT_INTERNAL"
        [[ ${fields[FORMAT_VERSION]:-} == 1 ]] ||
            apo_die "Complete found an unsupported retained state format: $state_file" "$APO_EXIT_INTERNAL"
        [[ ${fields[TARGET_SLUG]:-} == "$APO_TARGET_SLUG" &&
           ${fields[REMOTE_TARGET]:-} == "$APO_REMOTE_TARGET" ]] || continue
        run_id=${fields[RUN_ID]:-}
        apo_is_safe_run_id "$run_id" ||
            apo_die "Complete found an invalid retained run ID: $state_file" "$APO_EXIT_INTERNAL"
        expected_file="${APO_OUTPUT_DIR}/${APO_TARGET_SLUG}-${run_id}.state"
        [[ $state_file == "$expected_file" ]] ||
            apo_die "Complete found retained state whose identity does not match its filename: $state_file" "$APO_EXIT_INTERNAL"

        origin=${fields[ORIGIN_COMMAND]:-}
        status=${fields[STATUS]:-}
        phase=${fields[PHASE]:-}
        failure_class=${fields[FAILURE_CLASS]:-}
        remote_status=${fields[REMOTE_STRESS_STATUS]:-IDLE}
        target_companion=${fields[NETWORK_WATCHDOG_INSTALLED_BY_RUN]:-0}
        leased=${fields[CONTROLLER_WATCHDOG_LEASED]:-0}
        controller_status=${fields[CONTROLLER_WATCHDOG_STATUS]:-NOT_STARTED}
        no_headroom=${fields[OVERCLOCK_NO_HEADROOM]:-0}
        tryboot_expected=${fields[TRYBOOT_EXPECTED]:-0}
        tryboot_may_exist=${fields[TRYBOOT_FILE_MAY_EXIST]:-0}

        [[ ( -z $remote_status || $remote_status == IDLE ) &&
           $target_companion == 0 && $leased == 0 &&
           ( $controller_status == NOT_STARTED || -z $controller_status ) &&
           $tryboot_expected == 0 && $tryboot_may_exist == 0 &&
           -z ${fields[TRYBOOT_OWNED_HASH]:-} && -z ${fields[TRYBOOT_RESERVATION_HASH]:-} &&
           -z ${fields[TRYBOOT_OWNERSHIP_TOKEN]:-} && -z ${fields[TRYBOOT_QUARANTINE_PATH]:-} ]] || return 1

        if [[ $origin == prepare && $status == PASS && $phase == COMPLETE && $no_headroom == 0 ]]; then
            :
        elif [[ ( $origin == overclock || $origin == run ) && $status == FAILED &&
                  $failure_class == PREFLIGHT_FAILURE && $no_headroom == 0 ]]; then
            :
        elif [[ ( $origin == overclock || $origin == run ) && $status == PASS &&
                  $phase == COMPLETE && -z $failure_class && $no_headroom == 1 ]]; then
            :
        else
            return 1
        fi
        apo_complete_add_unique "$run_id" APO_COMPLETE_RUN_IDS
    done
    return 0
}

apo_complete_show_sealed_cleanup_plan() {
    local run_id
    if declare -F apo_progress_before_output >/dev/null 2>&1; then apo_progress_before_output; fi
    printf '\n===== ALREADY-COMPLETED CLEANUP =====\n' >&2
    printf 'Sealed applied run: %s at %s/%s MHz\n' \
        "$APO_HISTORY_SEALED_RUN_ID" "$APO_HISTORY_SEALED_CPU" "$APO_HISTORY_SEALED_GPU" >&2
    printf 'Permanent config was already canonicalized and verified. This artifact-cleanup stage does not change it.\n' >&2
    printf 'Safe post-completion controller runs scheduled for cleanup:\n' >&2
    for run_id in "${APO_COMPLETE_RUN_IDS[@]}"; do printf '  %s\n' "$run_id" >&2; done
    printf '=======================================\n\n' >&2
}

apo_complete_attach_cleanup_artifacts() {
    local run_id=$1
    APO_RUN_ID=$run_id
    APO_RUN_PREFIX="${APO_OUTPUT_DIR}/${APO_TARGET_SLUG}-${run_id}"
    APO_STATE_FILE="${APO_RUN_PREFIX}.state"
    APO_LOG_FILE="${APO_RUN_PREFIX}.log"
    APO_CSV_FILE="${APO_RUN_PREFIX}.csv"
    APO_JSONL_FILE="${APO_RUN_PREFIX}.jsonl"
    APO_JSON_FILE="${APO_RUN_PREFIX}.json"
    APO_SUMMARY_FILE="${APO_RUN_PREFIX}-summary.txt"
    APO_EFFECTIVE_CONFIG_FILE="${APO_RUN_PREFIX}.conf"
    APO_DISCOVERY_FILE="${APO_RUN_PREFIX}-discovery.txt"
}

apo_complete_reseal_backup_path() {
    local run_id=$1
    case ${APO_PROFILE:-} in
        debian) printf '/var/lib/autopioverclock/backups/config-%s-before-recomplete.txt' "$run_id" ;;
        batocera) printf '/userdata/system/autopioverclock/backups/config-%s-before-recomplete.txt' "$run_id" ;;
        *) return 1 ;;
    esac
}

apo_complete_validate_reseal_discovery() {
    local expected_hash=$1 recent_throttle tryboot_flag
    [[ ${APO_DISCOVERY[PROFILE]:-} == "${APO_HISTORY_LEDGER_META[PROFILE]}" &&
       ${APO_DISCOVERY[MODEL]:-} == "${APO_HISTORY_LEDGER_META[MODEL]}" &&
       ${APO_DISCOVERY[COMPATIBLE]:-} == "${APO_HISTORY_LEDGER_META[COMPATIBLE]}" &&
       ${APO_DISCOVERY[ARCH]:-} == "${APO_HISTORY_LEDGER_META[ARCH]}" &&
       ${APO_DISCOVERY[BOOT_CONFIG]:-} == "${APO_HISTORY_LEDGER_META[BOOT_CONFIG]}" &&
       ${APO_DISCOVERY[TRYBOOT_CONFIG]:-} == "${APO_HISTORY_LEDGER_META[TRYBOOT_CONFIG]}" &&
       ${APO_DISCOVERY[GPU_KEY]:-} == "${APO_HISTORY_LEDGER_META[GPU_KEY]}" ]] ||
        apo_die 'Repeat complete found target identity or boot-path evidence that differs from the sealed ledger.' "$APO_EXIT_APPLY"
    [[ ${APO_DISCOVERY[NORMAL_CPU]:-} == "$APO_HISTORY_SEALED_CPU" &&
       ${APO_DISCOVERY[NORMAL_GPU]:-} == "$APO_HISTORY_SEALED_GPU" &&
       ${APO_DISCOVERY[NORMAL_VOLTAGE]:-} == "$APO_HISTORY_SEALED_VOLTAGE" ]] ||
        apo_die 'Repeat complete found live clocks or voltage that differ from the sealed applied result.' "$APO_EXIT_APPLY"
    [[ ${APO_DISCOVERY[PERMANENT_HASH]:-} == "$expected_hash" ]] ||
        apo_die 'Permanent config changed while repeat complete was validating the target.' "$APO_EXIT_APPLY"
    [[ ${APO_DISCOVERY[TRYBOOT_EXISTS]:-} == 0 && ${APO_DISCOVERY[TRYBOOT_TYPE]:-} == absent ]] ||
        apo_die 'Repeat complete requires an absent tryboot path.' "$APO_EXIT_APPLY"
    tryboot_flag=$(apo_remote_tryboot_flag_once || true)
    [[ $tryboot_flag == 00000000 ]] ||
        apo_die "Repeat complete requires a normal boot; live tryboot state is ${tryboot_flag:-unreadable}." "$APO_EXIT_APPLY"
    apo_throttle_reading_valid "${APO_DISCOVERY[THROTTLED]:-}" &&
        apo_throttle_active_bits_clear "${APO_DISCOVERY[THROTTLED]:-}" ||
        apo_die "Repeat complete found active or malformed power/throttle evidence: ${APO_DISCOVERY[THROTTLED]:-missing}." "$APO_EXIT_APPLY"
    recent_throttle=${APO_DISCOVERY[RECENT_THROTTLED]:-}
    if [[ -n $recent_throttle ]]; then
        apo_throttle_reading_valid "$recent_throttle" && apo_throttle_active_bits_clear "$recent_throttle" ||
            apo_die "Repeat complete found recent power/throttle evidence: $recent_throttle." "$APO_EXIT_APPLY"
    fi
    apo_profile_watchdogs_ready ||
        apo_die 'Repeat complete found that the permanent hardware-watchdog chain is not ready.' "$APO_EXIT_APPLY"
}

apo_complete_capture_reseal_discovery() {
    local expected_hash=$1
    APO_DISCOVERY=()
    apo_discovery_capture
    apo_complete_validate_reseal_discovery "$expected_hash"
}

apo_complete_show_reseal_plan() {
    local diff_file=$1 current_file=$2 proposed_file=$3 current_hash=$4 proposed_hash=$5 diff_rc
    if diff -u --label current-config.txt --label canonical-config.txt "$current_file" "$proposed_file" > "$diff_file"; then
        diff_rc=0
    else
        diff_rc=$?
    fi
    (( diff_rc == 0 || diff_rc == 1 )) ||
        apo_die 'Repeat complete could not generate the permanent-config diff.' "$APO_EXIT_APPLY"
    if declare -F apo_progress_before_output >/dev/null 2>&1; then apo_progress_before_output; fi
    printf '\n===== EXACT REPEAT-COMPLETE CONFIG DIFF =====\n' >&2
    if (( diff_rc == 0 )); then
        printf '(Permanent config is already in canonical completed form.)\n' >&2
    else
        cat "$diff_file" >&2
    fi
    printf '================================================\n' >&2
    printf 'Current config hash:  %s\n' "$current_hash" >&2
    printf 'Canonical config hash: %s\n' "$proposed_hash" >&2
    printf 'Sealed ledger hash:    %s\n\n' "$APO_HISTORY_SEALED_HASH" >&2
}

apo_complete_capture_reseal_mutation() {
    local output_file=$1 remote_file=$2 old_hash=$3 new_hash=$4 remote_rc
    if apo_remote_worker "$APO_REMOTE_WORKER" recomplete-permanent \
        "$remote_file" "$old_hash" "$new_hash" "$APO_RUN_ID" \
        "$APO_HISTORY_SEALED_CPU" "$APO_HISTORY_SEALED_GPU" \
        "${APO_HISTORY_LEDGER_META[GPU_KEY]}" "$APO_HISTORY_SEALED_VOLTAGE" \
        "$APO_HISTORY_SEALED_RUN_ID" > "$output_file" 2>&1; then
        remote_rc=0
    else
        remote_rc=$?
    fi
    if declare -F apo_progress_before_output >/dev/null 2>&1; then apo_progress_before_output; fi
    cat "$output_file" >&2
    apo_classify_output "$output_file" repeat-complete-config
    (( remote_rc == 0 && APO_LAST_RESULT_COMPLETE == 1 )) && [[ $APO_LAST_CLASS == PASS ]] ||
        apo_die "Repeat complete could not install the canonical config: ${APO_LAST_REASON:-unstructured worker failure}" "$APO_EXIT_APPLY"
    apo_parse_data_file "$output_file" APO_WORKER_DATA
    [[ ${APO_WORKER_DATA[COMPLETE_NEW_HASH]:-} == "$new_hash" ]] ||
        apo_die 'Repeat-complete worker returned a config hash that differs from the transaction.' "$APO_EXIT_APPLY"
}

apo_complete_remove_reseal_backup() {
    local backup_file=$1 expected_hash=$2 backup_id=$3 backup_dir remote_command attempt
    [[ -n $backup_file ]] || return 0
    apo_complete_valid_hash "$expected_hash" ||
        apo_die 'Repeat complete received an invalid maintenance-backup hash.' "$APO_EXIT_INTERNAL"
    apo_is_safe_run_id "$backup_id" ||
        apo_die 'Repeat complete received an invalid maintenance-backup ID.' "$APO_EXIT_INTERNAL"
    [[ $backup_file == "$(apo_complete_reseal_backup_path "$backup_id")" ]] ||
        apo_die 'Repeat-complete worker reported an unexpected backup path.' "$APO_EXIT_INTERNAL"
    backup_dir=${backup_file%/*}
    remote_command="backup_file=$(apo_sh_quote "$backup_file")"$'\n'
    remote_command+="backup_dir=$(apo_sh_quote "$backup_dir")"$'\n'
    remote_command+="expected_hash=$(apo_sh_quote "$expected_hash")"$'\n'
    remote_command+=$'if [ -e "$backup_file" ] || [ -L "$backup_file" ]; then\n'
    remote_command+=$'    [ -f "$backup_file" ] && [ ! -L "$backup_file" ]\n'
    remote_command+=$'    actual_hash=$(sha256sum "$backup_file" | awk '\''NR == 1 {print $1}'\'')\n'
    remote_command+=$'    [ "$actual_hash" = "$expected_hash" ]\n'
    remote_command+=$'    rm -f -- "$backup_file"\n'
    remote_command+=$'    sync "$backup_dir"\n'
    remote_command+=$'fi\n'
    for attempt in 1 2 3; do
        if apo_remote_root "$remote_command"; then return 0; fi
    done
    apo_die 'Repeat complete succeeded, but its exact verified maintenance backup could not be removed.' "$APO_EXIT_RECOVERY"
}

apo_complete_recanonicalize_sealed_config() {
    local ledger_file=$1 maintenance_id current_file proposed_file diff_file result_file verify_file log_file
    local current_hash proposed_hash latest_hash expected_confirmation remote_proposed backup_file backup_hash expected_backup
    local baseline_cpu=$APO_HISTORY_LEDGER_BASELINE_CPU baseline_gpu=$APO_HISTORY_LEDGER_BASELINE_GPU
    local baseline_voltage=$APO_HISTORY_LEDGER_BASELINE_VOLTAGE sealed_run_id=$APO_HISTORY_SEALED_RUN_ID expected_record_count

    maintenance_id=$(apo_new_run_id) || apo_die 'Repeat complete could not allocate a maintenance transaction ID.' "$APO_EXIT_INTERNAL"
    apo_is_safe_run_id "$maintenance_id" ||
        apo_die 'Repeat complete allocated an invalid maintenance transaction ID.' "$APO_EXIT_INTERNAL"
    APO_RUN_ID=$maintenance_id
    APO_PROFILE=${APO_HISTORY_LEDGER_META[PROFILE]}
    APO_BOOT_CONFIG=${APO_HISTORY_LEDGER_META[BOOT_CONFIG]}
    APO_TRYBOOT_CONFIG=${APO_HISTORY_LEDGER_META[TRYBOOT_CONFIG]}
    APO_GPU_KEY=${APO_HISTORY_LEDGER_META[GPU_KEY]}
    APO_TEST_VOLTAGE=${APO_HISTORY_LEDGER_META[TEST_VOLTAGE]}
    APO_NORMAL_CPU=$APO_HISTORY_SEALED_CPU
    APO_NORMAL_GPU=$APO_HISTORY_SEALED_GPU
    APO_NORMAL_VOLTAGE=$APO_HISTORY_SEALED_VOLTAGE
    apo_load_profile "$APO_PROFILE"
    apo_ssh_preflight
    apo_deploy_worker
    APO_HAVE_REMOTE_CONTEXT=1

    apo_complete_make_maintenance_temp current_file current || apo_die 'Repeat complete could not create its current-config file.' "$APO_EXIT_INTERNAL"
    apo_complete_make_maintenance_temp proposed_file proposed || apo_die 'Repeat complete could not create its proposed-config file.' "$APO_EXIT_INTERNAL"
    apo_complete_make_maintenance_temp diff_file diff || apo_die 'Repeat complete could not create its diff file.' "$APO_EXIT_INTERNAL"
    apo_complete_make_maintenance_temp result_file result || apo_die 'Repeat complete could not create its result file.' "$APO_EXIT_INTERNAL"
    apo_complete_make_maintenance_temp verify_file verify || apo_die 'Repeat complete could not create its verification file.' "$APO_EXIT_INTERNAL"
    apo_complete_make_maintenance_temp log_file log || apo_die 'Repeat complete could not create its diagnostic log.' "$APO_EXIT_INTERNAL"
    APO_DISCOVERY_FILE=$verify_file
    APO_LOG_FILE=$log_file

    apo_discovery_capture
    current_hash=${APO_DISCOVERY[PERMANENT_HASH]:-}
    apo_complete_valid_hash "$current_hash" ||
        apo_die 'Repeat complete could not read a valid live permanent-config hash.' "$APO_EXIT_APPLY"
    apo_complete_validate_reseal_discovery "$current_hash"
    apo_remote_root_read_file "$current_file" "cat $(apo_sh_quote "$APO_BOOT_CONFIG")" ||
        apo_die 'Repeat complete could not capture the current permanent config.' "$APO_EXIT_APPLY"
    [[ $(sha256sum "$current_file" 2>/dev/null | awk 'NR == 1 {print $1}' || true) == "$current_hash" ]] ||
        apo_die 'Permanent config changed while repeat complete was capturing it.' "$APO_EXIT_APPLY"
    apo_remote_worker_read_file "$proposed_file" "$APO_REMOTE_WORKER" render-recomplete \
        "$APO_HISTORY_SEALED_CPU" "$APO_HISTORY_SEALED_GPU" "$APO_GPU_KEY" \
        "$APO_HISTORY_SEALED_VOLTAGE" "$APO_RUN_ID" "$current_hash" ||
        apo_die 'The live permanent config is not a structurally safe completed config for the sealed clocks.' "$APO_EXIT_APPLY"
    [[ -s $proposed_file ]] || apo_die 'Repeat complete rendered an empty canonical config.' "$APO_EXIT_INTERNAL"
    proposed_hash=$(sha256sum "$proposed_file" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    apo_complete_valid_hash "$proposed_hash" ||
        apo_die 'Repeat complete could not hash the canonical config.' "$APO_EXIT_INTERNAL"

    if [[ $current_hash == "$proposed_hash" && $current_hash == "$APO_HISTORY_SEALED_HASH" ]]; then
        printf 'Permanent config and sealed ledger are already canonical for %s.\n' "$APO_REMOTE_TARGET"
        return 0
    fi

    apo_complete_show_reseal_plan "$diff_file" "$current_file" "$proposed_file" "$current_hash" "$proposed_hash"
    expected_confirmation="COMPLETE ${APO_TARGET_SLUG} ${APO_HISTORY_SEALED_RUN_ID}"
    apo_confirm_exact 'Repeat complete will canonicalize the displayed permanent config when needed and rebind the durable ledger only after exact live identity, clocks, voltage, watchdog, tryboot, hash, and power-state validation.' "$expected_confirmation" ||
        apo_die 'Repeat complete was not confirmed.' "$APO_EXIT_USAGE"

    latest_hash=$(apo_current_permanent_hash || true)
    [[ $latest_hash == "$current_hash" ]] ||
        apo_die 'Permanent config changed at the repeat-complete mutation boundary.' "$APO_EXIT_APPLY"
    remote_proposed="${APO_REMOTE_WORK_DIR}/recomplete-${APO_RUN_ID}.txt"
    apo_remote_upload_root "$proposed_file" "$remote_proposed" ||
        apo_die 'Repeat complete could not upload the canonical config.' "$APO_EXIT_APPLY"
    apo_complete_capture_reseal_mutation "$result_file" "$remote_proposed" "$current_hash" "$proposed_hash"
    backup_file=${APO_WORKER_DATA[COMPLETE_BACKUP_FILE]:-}
    backup_hash=${APO_WORKER_DATA[COMPLETE_BACKUP_HASH]:-}
    if [[ -n $backup_file ]]; then
        apo_complete_valid_hash "$backup_hash" ||
            apo_die 'Repeat-complete worker returned an invalid maintenance-backup hash.' "$APO_EXIT_INTERNAL"
        expected_backup=$(apo_complete_reseal_backup_path "$sealed_run_id") ||
            apo_die 'Repeat complete could not resolve its expected backup path.' "$APO_EXIT_INTERNAL"
        [[ $backup_file == "$expected_backup" ]] ||
            apo_die 'Repeat-complete worker reported an unexpected backup path.' "$APO_EXIT_INTERNAL"
        if [[ $current_hash != "$proposed_hash" ]]; then
            [[ $backup_hash == "$current_hash" ]] ||
                apo_die 'Repeat-complete worker returned a backup that differs from the pre-mutation config.' "$APO_EXIT_INTERNAL"
        fi
    else
        [[ -z $backup_hash ]] ||
            apo_die 'Repeat-complete worker returned a maintenance-backup hash without a path.' "$APO_EXIT_INTERNAL"
        [[ $current_hash == "$proposed_hash" ]] ||
            apo_die 'Repeat-complete worker did not return the required pre-mutation backup.' "$APO_EXIT_INTERNAL"
    fi

    latest_hash=$(apo_current_permanent_hash || true)
    [[ $latest_hash == "$proposed_hash" ]] ||
        apo_die 'Canonical permanent config did not retain its verified hash.' "$APO_EXIT_APPLY"
    apo_complete_capture_reseal_discovery "$proposed_hash"
    apo_remote_root_read_file "$verify_file" "cat $(apo_sh_quote "$APO_BOOT_CONFIG")" ||
        apo_die 'Repeat complete could not recapture the installed canonical config.' "$APO_EXIT_APPLY"
    cmp -s -- "$proposed_file" "$verify_file" ||
        apo_die 'Installed canonical config bytes differ from the verified proposal.' "$APO_EXIT_APPLY"

    expected_record_count=${#APO_HISTORY_LEDGER_RECORDS[@]}
    APO_HISTORY_RENDER_BASELINE_CPU=$baseline_cpu
    APO_HISTORY_RENDER_BASELINE_GPU=$baseline_gpu
    APO_HISTORY_RENDER_BASELINE_VOLTAGE=$baseline_voltage
    APO_HISTORY_SEALED_HASH=$proposed_hash
    apo_history_rebuild_ledger "$ledger_file" ||
        apo_die 'Repeat complete installed the canonical config, but could not atomically rebind the durable ledger. Rerun complete to finish the safe rebind.' "$APO_EXIT_INTERNAL"
    APO_HISTORY_SCAN_BASELINE_CPU=$baseline_cpu
    APO_HISTORY_SCAN_BASELINE_GPU=$baseline_gpu
    APO_HISTORY_SCAN_BASELINE_VOLTAGE=$baseline_voltage
    apo_history_load_machine_ledger "$ledger_file" 0 0 ||
        apo_die 'Repeat complete could not revalidate the rebound durable ledger.' "$APO_EXIT_INTERNAL"
    [[ $APO_HISTORY_SEALED_HASH == "$proposed_hash" &&
       $APO_HISTORY_SEALED_RUN_ID == "$sealed_run_id" &&
       $(awk -F '\t' '$1 == "RECORD" {count++} END {print count+0}' "$ledger_file") == "$expected_record_count" ]] ||
        apo_die 'Repeat complete found that the rebound ledger changed sealed identity or retained record count.' "$APO_EXIT_INTERNAL"
    APO_HISTORY_RENDER_BASELINE_CPU=''
    APO_HISTORY_RENDER_BASELINE_GPU=''
    APO_HISTORY_RENDER_BASELINE_VOLTAGE=''
    APO_HISTORY_SCAN_BASELINE_CPU=''
    APO_HISTORY_SCAN_BASELINE_GPU=''
    APO_HISTORY_SCAN_BASELINE_VOLTAGE=''
    apo_complete_remove_reseal_backup "$backup_file" "$backup_hash" "$sealed_run_id"
    printf 'Repeat complete verified canonical config and rebound durable history for %s.\n' "$APO_REMOTE_TARGET"
}

apo_complete_try_sealed_cleanup() {
    local ledger_file run_id expected_confirmation

    [[ -z ${APO_SELECTED_RUN_ID:-} ]] || return 1
    ledger_file=$(apo_history_ledger_path) || return 1
    [[ -e $ledger_file || -L $ledger_file ]] || return 1
    [[ -f $ledger_file && ! -L $ledger_file && -r $ledger_file ]] ||
        apo_die 'Complete found an unsafe durable failure ledger.' "$APO_EXIT_INTERNAL"
    apo_history_load_machine_ledger "$ledger_file" 1 1 ||
        apo_die 'Complete could not strictly validate the durable sealed failure ledger.' "$APO_EXIT_INTERNAL"
    [[ -n $APO_HISTORY_SEALED_RUN_ID &&
       $APO_HISTORY_SEALED_RUN_SCHEMA == "$APO_CURRENT_RUN_SCHEMA" &&
       $APO_HISTORY_SEALED_VALIDATION_SCHEMA == "$APO_CURRENT_VALIDATION_SCHEMA" ]] || return 1
    apo_complete_collect_sealed_cleanup_runs || return 1
    apo_complete_recanonicalize_sealed_config "$ledger_file"

    if (( ${#APO_COMPLETE_RUN_IDS[@]} == 0 )); then
        printf 'Complete finished for %s. No target runs remain; canonical config and durable history are verified at %s.\n' \
            "$APO_REMOTE_TARGET" "$ledger_file"
        return 0
    fi

    apo_complete_show_sealed_cleanup_plan
    expected_confirmation="COMPLETE ${APO_TARGET_SLUG} ${APO_HISTORY_SEALED_RUN_ID}"
    apo_confirm_exact 'Complete will remove only the listed safe post-completion controller artifacts. This stage will not further change the permanent config, target clocks, watchdogs, or durable failure ledger.' "$expected_confirmation" ||
        apo_die 'Complete was not confirmed.' "$APO_EXIT_USAGE"
    run_id=${APO_COMPLETE_RUN_IDS[0]}
    apo_complete_attach_cleanup_artifacts "$run_id"
    apo_complete_delete_controller_artifacts
    return 0
}

apo_complete_remote_work_dir_is_safe() {
    case ${APO_PROFILE:-} in
        debian) [[ $APO_REMOTE_WORK_DIR == "/tmp/autopioverclock-${APO_RUN_ID}" ]] ;;
        batocera) [[ $APO_REMOTE_WORK_DIR == "/userdata/system/autopioverclock/runs/${APO_RUN_ID}" ]] ;;
        *) return 1 ;;
    esac
}

apo_complete_remove_current_remote_work_dir() {
    local path_state
    apo_complete_remote_work_dir_is_safe ||
        apo_die 'Complete refused an unexpected target work-directory path.' "$APO_EXIT_INTERNAL"
    apo_remote_root "if [ -d $(apo_sh_quote "$APO_REMOTE_WORK_DIR") ] && [ ! -L $(apo_sh_quote "$APO_REMOTE_WORK_DIR") ]; then rm -rf -- $(apo_sh_quote "$APO_REMOTE_WORK_DIR"); elif [ -e $(apo_sh_quote "$APO_REMOTE_WORK_DIR") ] || [ -L $(apo_sh_quote "$APO_REMOTE_WORK_DIR") ]; then exit 1; fi" ||
        apo_die 'Complete could not remove the selected run harness directory safely.' "$APO_EXIT_RECOVERY"
    path_state=$(apo_remote_root_read "if [ -e $(apo_sh_quote "$APO_REMOTE_WORK_DIR") ] || [ -L $(apo_sh_quote "$APO_REMOTE_WORK_DIR") ]; then printf present; else printf absent; fi" || true)
    [[ $path_state == absent ]] ||
        apo_die 'Complete could not verify removal of the selected run harness directory.' "$APO_EXIT_RECOVERY"
    APO_WORKER_DEPLOYED=0
}

apo_complete_controller_path_matches_run() {
    local basename=$1 run_id prefix remainder
    for run_id in "${APO_COMPLETE_RUN_IDS[@]}"; do
        if [[ $basename == "autopioverclock-${run_id}-public-report.txt" ]]; then
            return 0
        fi
        prefix="${APO_TARGET_SLUG}-${run_id}"
        [[ $basename == "$prefix"* ]] || continue
        remainder=${basename#"$prefix"}
        [[ $remainder == .* || $remainder == -* ]] && return 0
    done
    return 1
}

apo_complete_collect_controller_paths() {
    local output_name=$1 candidate basename
    local -n output_paths=$output_name
    local -a entries=()
    output_paths=()
    shopt -s nullglob dotglob
    entries=("${APO_OUTPUT_DIR}"/*)
    shopt -u nullglob dotglob
    for candidate in "${entries[@]}"; do
        basename=${candidate##*/}
        case $basename in
            "${APO_TARGET_SLUG}-latest.log"|"${APO_TARGET_SLUG}-latest-summary.txt"|"${APO_TARGET_SLUG}-latest.state"|"${APO_TARGET_SLUG}-latest.json")
                [[ -L $candidate ]] ||
                    apo_die "Complete refuses a non-symlink latest pointer: $candidate" "$APO_EXIT_INTERNAL"
                output_paths+=("$candidate")
                ;;
            *)
                apo_complete_controller_path_matches_run "$basename" || continue
                [[ -f $candidate && ! -L $candidate ]] ||
                    apo_die "Complete refuses an unsafe controller artifact: $candidate" "$APO_EXIT_INTERNAL"
                output_paths+=("$candidate")
                ;;
        esac
    done
}

apo_complete_delete_controller_artifacts() {
    local candidate retained_entry
    local -a cleanup_paths=() deferred_paths=()
    apo_complete_collect_controller_paths cleanup_paths

    # Delete other runs first. Keep the selected state and its log until every
    # earlier deletion succeeds, so an interrupted cleanup remains diagnosable.
    for candidate in "${cleanup_paths[@]}"; do
        if [[ $candidate == "$APO_RUN_PREFIX"* ]]; then
            deferred_paths+=("$candidate")
            continue
        fi
        rm -f -- "$candidate" ||
            apo_die "Complete could not remove controller artifact: $candidate" "$APO_EXIT_INTERNAL"
    done
    sync "$APO_OUTPUT_DIR" ||
        apo_die 'Complete could not durably flush controller artifact cleanup.' "$APO_EXIT_INTERNAL"

    apo_event complete PASS '' 'Permanent config was simplified and verified; run harnesses, target backups, controller logs, state, reports, and evidence are being removed.'
    if declare -F apo_progress_clear_line >/dev/null 2>&1; then apo_progress_clear_line; fi

    # The normal exit trap writes state and JSON. Disable it immediately before
    # deleting the selected run so successful cleanup cannot recreate files.
    trap - EXIT ERR INT TERM HUP
    for candidate in "${deferred_paths[@]}"; do
        [[ $candidate == "$APO_STATE_FILE" ]] && continue
        rm -f -- "$candidate" || {
            printf 'ERROR: Complete could not remove controller artifact: %s\n' "$candidate" >&2
            return "$APO_EXIT_INTERNAL"
        }
    done
    if [[ -f $APO_STATE_FILE && ! -L $APO_STATE_FILE ]]; then
        rm -f -- "$APO_STATE_FILE" || {
            printf 'ERROR: Complete could not remove the selected state file: %s\n' "$APO_STATE_FILE" >&2
            return "$APO_EXIT_INTERNAL"
        }
    fi
    sync "$APO_OUTPUT_DIR" || {
        printf 'ERROR: Complete could not durably flush final controller cleanup.\n' >&2
        return "$APO_EXIT_INTERNAL"
    }
    APO_STATE_FILE=''
    APO_LOG_FILE=''
    APO_CSV_FILE=''
    APO_JSONL_FILE=''
    APO_JSON_FILE=''
    APO_SUMMARY_FILE=''
    if [[ $APO_OUTPUT_DIR != "$APO_TARGET_STATE_DIR" ]]; then
        if ! rmdir -- "$APO_OUTPUT_DIR" 2>/dev/null; then
            retained_entry=''
            shopt -s nullglob dotglob
            for candidate in "${APO_OUTPUT_DIR}"/*; do
                retained_entry=${candidate##*/}
                break
            done
            shopt -u nullglob dotglob
            if [[ -n $retained_entry ]]; then
                printf 'WARNING: Complete preserved unrecognized entry %s in the target runs directory.\n' "$retained_entry" >&2
            elif [[ -e $APO_OUTPUT_DIR || -L $APO_OUTPUT_DIR ]]; then
                printf 'WARNING: Complete could not remove the empty target runs directory.\n' >&2
            fi
        fi
    fi
    printf 'Complete finished for %s. Final clocks remain applied; durable history remains at %s; native and permanent watchdogs were preserved.\n' \
        "$APO_REMOTE_TARGET" "$(apo_history_ledger_path)"
}

apo_complete_run() {
    local final_cpu final_gpu final_voltage current_hash old_hash expected_hash saved_expected saved_old complete_status
    local current_file proposed_file diff_file manifest_file remote_manifest manifest_hash expected_confirmation previous_hash
    local reported_hash ledger_file

    apo_complete_validate_selected_run
    apo_apply_assert_tryboot_clear || apo_die "$APO_LAST_REASON" "$APO_EXIT_APPLY"
    apo_complete_collect_target_runs
    ledger_file=$(apo_history_ledger_path) ||
        apo_die 'Complete could not resolve the target history ledger path.' "$APO_EXIT_INTERNAL"

    APO_HISTORY_SCAN_BASELINE_CPU=$(apo_state_get AUTO_BASELINE_CPU '')
    APO_HISTORY_SCAN_BASELINE_GPU=$(apo_state_get AUTO_BASELINE_GPU '')
    APO_HISTORY_SCAN_BASELINE_VOLTAGE=$(apo_state_get AUTO_BASELINE_VOLTAGE '')
    [[ -n $APO_HISTORY_SCAN_BASELINE_CPU && -n $APO_HISTORY_SCAN_BASELINE_GPU &&
       -n $APO_HISTORY_SCAN_BASELINE_VOLTAGE ]] ||
        apo_die 'Complete found incomplete automatic-baseline lineage in the selected run.' "$APO_EXIT_INTERNAL"
    apo_history_scan_retained_states ||
        apo_die "Complete could not consolidate retained failure evidence: ${APO_HISTORY_SCAN_ERROR:-invalid retained history}" "$APO_EXIT_INTERNAL"
    APO_HISTORY_SCAN_BASELINE_CPU=''
    APO_HISTORY_SCAN_BASELINE_GPU=''
    APO_HISTORY_SCAN_BASELINE_VOLTAGE=''

    final_cpu=$(apo_state_get FINAL_CPU '')
    final_gpu=$(apo_state_get FINAL_GPU '')
    final_voltage=$(apo_state_get NORMAL_VOLTAGE '')
    old_hash=$(apo_state_get PERMANENT_HASH '')
    complete_status=$(apo_state_get COMPLETE_STATUS '')
    saved_old=$(apo_state_get COMPLETE_OLD_HASH '')
    saved_expected=$(apo_state_get COMPLETE_EXPECTED_HASH '')
    current_hash=$(apo_current_permanent_hash || true)
    apo_complete_valid_hash "$current_hash" ||
        apo_die 'Complete could not read a valid live permanent-config hash.' "$APO_EXIT_APPLY"

    current_file="${APO_RUN_PREFIX}-complete-current-config.txt"
    proposed_file="${APO_RUN_PREFIX}-complete-proposed-config.txt"
    diff_file="${APO_RUN_PREFIX}-complete.diff"
    manifest_file="${APO_RUN_PREFIX}-complete-run-ids.txt"
    remote_manifest="${APO_REMOTE_WORK_DIR}/complete-run-ids.txt"

    if [[ -n $complete_status ]]; then
        case $complete_status in SEALING|SEALED|VERIFIED|TARGET_CLEANED) ;; *)
            apo_die "Complete found an unknown saved finalization stage: $complete_status" "$APO_EXIT_INTERNAL" ;;
        esac
        apo_complete_valid_hash "$saved_old" && apo_complete_valid_hash "$saved_expected" ||
            apo_die 'Complete found malformed saved finalization hashes.' "$APO_EXIT_INTERNAL"
        old_hash=$saved_old
        expected_hash=$saved_expected
        if [[ $current_hash != "$old_hash" && $current_hash != "$expected_hash" ]]; then
            apo_die 'Permanent config changed outside the saved complete transaction; refusing cleanup.' "$APO_EXIT_APPLY"
        fi
    else
        [[ $current_hash == "$old_hash" ]] ||
            apo_die 'Permanent config no longer matches the applied run; refusing cleanup.' "$APO_EXIT_APPLY"
    fi

    apo_remote_root_read_file "$current_file" "cat $(apo_sh_quote "$APO_BOOT_CONFIG")" ||
        apo_die 'Complete could not capture the current permanent config.' "$APO_EXIT_APPLY"
    [[ $(sha256sum "$current_file" 2>/dev/null | awk 'NR == 1 {print $1}' || true) == "$current_hash" ]] ||
        apo_die 'Permanent config changed while complete was capturing it.' "$APO_EXIT_APPLY"

    if [[ $current_hash == "$saved_expected" && -n $saved_expected ]]; then
        cp -- "$current_file" "$proposed_file" ||
            apo_die 'Complete could not stage the already simplified config for verification.' "$APO_EXIT_INTERNAL"
        expected_hash=$saved_expected
    else
        apo_remote_worker_read_file "$proposed_file" "$APO_REMOTE_WORKER" render-complete \
            "$final_cpu" "$final_gpu" "$APO_GPU_KEY" "$final_voltage" "$APO_RUN_ID" "$old_hash" ||
            apo_die 'Complete could not safely render the simplified permanent config.' "$APO_EXIT_APPLY"
        [[ -s $proposed_file ]] ||
            apo_die 'Complete rendered an empty permanent config.' "$APO_EXIT_APPLY"
        expected_hash=$(sha256sum "$proposed_file" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
        apo_complete_valid_hash "$expected_hash" ||
            apo_die 'Complete could not hash the simplified permanent config.' "$APO_EXIT_INTERNAL"
    fi

    apo_complete_write_run_manifest "$manifest_file" ||
        apo_die 'Complete could not write its verified run cleanup manifest.' "$APO_EXIT_INTERNAL"
    manifest_hash=$(sha256sum "$manifest_file" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    apo_complete_valid_hash "$manifest_hash" ||
        apo_die 'Complete could not hash its run cleanup manifest.' "$APO_EXIT_INTERNAL"
    apo_complete_show_plan "$diff_file" "$current_file" "$proposed_file"

    expected_confirmation="COMPLETE ${APO_TARGET_SLUG} ${APO_RUN_ID}"
    apo_confirm_exact "Complete permanently deletes this target's retained AutoPiOverclock logs, state, reports, backups, evidence, and transient harnesses after simplifying the displayed config. It does not remove native or permanent watchdogs." "$expected_confirmation" ||
        apo_die 'Complete was not confirmed.' "$APO_EXIT_USAGE"

    apo_apply_assert_tryboot_clear ||
        apo_die "Tryboot state changed while complete confirmation was pending: $APO_LAST_REASON" "$APO_EXIT_APPLY"
    current_hash=$(apo_current_permanent_hash || true)
    if [[ $current_hash != "$old_hash" && $current_hash != "$expected_hash" ]]; then
        apo_die 'Permanent config changed at the complete mutation boundary.' "$APO_EXIT_APPLY"
    fi

    apo_state_set COMPLETE_STATUS SEALING
    apo_state_set COMPLETE_OLD_HASH "$old_hash"
    apo_state_set COMPLETE_EXPECTED_HASH "$expected_hash"
    apo_state_set COMPLETE_RUN_IDS "$(printf '%s\n' "${APO_COMPLETE_RUN_IDS[@]}")"
    apo_state_save

    if [[ $current_hash == "$old_hash" ]]; then
        apo_remote_upload_root "$proposed_file" "${APO_REMOTE_WORK_DIR}/complete-${APO_RUN_ID}.txt" ||
            apo_die 'Complete could not upload the simplified permanent config.' "$APO_EXIT_APPLY"
        apo_run_worker_capture complete-config complete-permanent \
            "${APO_REMOTE_WORK_DIR}/complete-${APO_RUN_ID}.txt" "$old_hash" "$expected_hash" "$APO_RUN_ID" \
            "$final_cpu" "$final_gpu" "$APO_GPU_KEY" "$final_voltage" ||
            apo_die "Complete could not install the simplified config: ${APO_LAST_REASON:-unknown worker failure}" "$APO_EXIT_APPLY"
        apo_parse_data_file "$APO_LAST_WORKER_LOG" APO_WORKER_DATA
        reported_hash=${APO_WORKER_DATA[COMPLETE_NEW_HASH]:-}
        [[ $reported_hash == "$expected_hash" ]] ||
            apo_die 'Complete worker returned a permanent hash that does not match the saved transaction.' "$APO_EXIT_APPLY"
    fi

    APO_PERMANENT_CONFIG_HASH=$expected_hash
    apo_state_set COMPLETE_STATUS SEALED
    apo_state_save
    apo_apply_assert_tryboot_clear || apo_die "$APO_LAST_REASON" "$APO_EXIT_APPLY"
    previous_hash=$APO_PERMANENT_CONFIG_HASH
    if ! apo_health_check "$final_cpu" "$final_gpu" "$final_voltage" complete-health; then
        APO_PERMANENT_CONFIG_HASH=$previous_hash
        apo_die "The simplified config did not pass live health verification: ${APO_LAST_REASON:-unknown health failure}" "$APO_EXIT_APPLY"
    fi
    APO_PERMANENT_CONFIG_HASH=$expected_hash
    apo_state_set COMPLETE_STATUS VERIFIED
    apo_state_save

    APO_HISTORY_RENDER_BASELINE_CPU=$final_cpu
    APO_HISTORY_RENDER_BASELINE_GPU=$final_gpu
    APO_HISTORY_RENDER_BASELINE_VOLTAGE=$final_voltage
    APO_HISTORY_SEALED_RUN_ID=$APO_RUN_ID
    APO_HISTORY_SEALED_CPU=$final_cpu
    APO_HISTORY_SEALED_GPU=$final_gpu
    APO_HISTORY_SEALED_VOLTAGE=$final_voltage
    APO_HISTORY_SEALED_HASH=$expected_hash
    APO_HISTORY_SEALED_RUN_SCHEMA=$APO_CURRENT_RUN_SCHEMA
    APO_HISTORY_SEALED_VALIDATION_SCHEMA=$APO_CURRENT_VALIDATION_SCHEMA
    apo_history_rebuild_ledger "$ledger_file" ||
        apo_die 'Complete could not durably seal the retained failure ledger, so no run artifacts were deleted.' "$APO_EXIT_INTERNAL"
    APO_HISTORY_RENDER_BASELINE_CPU=''
    APO_HISTORY_RENDER_BASELINE_GPU=''
    APO_HISTORY_RENDER_BASELINE_VOLTAGE=''
    APO_HISTORY_SCAN_BASELINE_CPU=$final_cpu
    APO_HISTORY_SCAN_BASELINE_GPU=$final_gpu
    APO_HISTORY_SCAN_BASELINE_VOLTAGE=$final_voltage
    if ! apo_history_load_machine_ledger "$ledger_file" 0; then
        APO_HISTORY_SCAN_BASELINE_CPU=''
        APO_HISTORY_SCAN_BASELINE_GPU=''
        APO_HISTORY_SCAN_BASELINE_VOLTAGE=''
        apo_die 'Complete could not revalidate the sealed retained failure ledger, so no run artifacts were deleted.' "$APO_EXIT_INTERNAL"
    fi
    APO_HISTORY_SCAN_BASELINE_CPU=''
    APO_HISTORY_SCAN_BASELINE_GPU=''
    APO_HISTORY_SCAN_BASELINE_VOLTAGE=''
    [[ $APO_HISTORY_SEALED_RUN_ID == "$APO_RUN_ID" &&
       $APO_HISTORY_SEALED_CPU == "$final_cpu" &&
       $APO_HISTORY_SEALED_GPU == "$final_gpu" &&
       $APO_HISTORY_SEALED_VOLTAGE == "$final_voltage" &&
       $APO_HISTORY_SEALED_HASH == "$expected_hash" ]] ||
        apo_die 'Complete reloaded a retained failure ledger that does not match the verified applied result.' "$APO_EXIT_INTERNAL"

    apo_cleanup_completed_run_watchdog
    apo_complete_cleanup_controller_watchdog_records
    apo_remote_upload_root "$manifest_file" "$remote_manifest" ||
        apo_die 'Complete could not upload the verified target cleanup manifest.' "$APO_EXIT_RECOVERY"
    apo_run_worker_capture complete-target-cleanup cleanup-complete-artifacts \
        "$remote_manifest" "$manifest_hash" "$APO_RUN_ID" ||
        apo_die "Complete could not remove target artifacts safely: ${APO_LAST_REASON:-unknown worker failure}" "$APO_EXIT_RECOVERY"
    apo_state_set COMPLETE_STATUS TARGET_CLEANED
    apo_state_save
    apo_complete_remove_current_remote_work_dir
    apo_complete_delete_controller_artifacts
}
