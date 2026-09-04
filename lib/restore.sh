#!/usr/bin/env bash
# Restore a retained, fully validated permanent configuration after an
# out-of-band edit. This is deliberately distinct from tryboot recovery and
# from returning a target to firmware stock clocks.

APO_RESTORE_SOURCE_STATE=''
APO_RESTORE_SOURCE_ARTIFACT=''
APO_RESTORE_SOURCE_RUN_ID=''
APO_RESTORE_SOURCE_HASH=''
APO_RESTORE_SOURCE_CPU=''
APO_RESTORE_SOURCE_GPU=''
APO_RESTORE_SOURCE_VOLTAGE=''
APO_RESTORE_SOURCE_PROFILE=''
APO_RESTORE_SOURCE_MODE=''
APO_RESTORE_SOURCE_BOOT_CONFIG=''
APO_RESTORE_SOURCE_TRYBOOT_CONFIG=''
APO_RESTORE_SOURCE_BOOT_MOUNT=''
APO_RESTORE_SOURCE_GPU_KEY=''
APO_RESTORE_SOURCE_DISPLAY_BASELINE=''
APO_RESTORE_SOURCE_AUDIO_BASELINE=''
APO_RESTORE_SOURCE_STORAGE_LAYOUT=''
APO_RESTORE_SOURCE_THROTTLE_BASELINE=''
APO_RESTORE_SOURCE_THROTTLE_RUNTIME_BASELINE=''
APO_RESTORE_SOURCE_THROTTLE_RECENT_SUPPORTED=0
APO_RESTORE_SOURCE_AUTO_BASELINE_CPU=''
APO_RESTORE_SOURCE_AUTO_BASELINE_GPU=''
APO_RESTORE_SOURCE_AUTO_BASELINE_VOLTAGE=''
APO_RESTORE_SOURCE_AUTO_BASELINE_PROVENANCE=''
APO_RESTORE_SOURCE_AUTO_BASELINE_EVIDENCE=''

apo_restore_capture_source() {
    local source_state=$1 source_run_id source_artifact source_hash source_zero_mode expected_name

    [[ -f $source_state && ! -L $source_state && -r $source_state ]] || return 1
    apo_state_load "$source_state"
    apo_domain_sweep_source_is_eligible || return 1

    source_run_id=$(apo_state_get RUN_ID '')
    expected_name="${APO_TARGET_SLUG}-${source_run_id}.state"
    [[ $(basename -- "$source_state") == "$expected_name" ]] || return 1
    source_artifact="${source_state%.state}-apply-proposed-config.txt"
    [[ -f $source_artifact && ! -L $source_artifact && -r $source_artifact ]] || return 1
    source_hash=$(sha256sum "$source_artifact" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    [[ $source_hash == "$(apo_state_get PERMANENT_HASH '')" &&
       $source_hash == "$(apo_state_get APPLY_EXPECTED_HASH '')" ]] || return 1
    source_zero_mode=$(apo_domain_source_managed_clock_zero_mode "$source_artifact" "$source_run_id" \
        "$(apo_state_get FINAL_CPU '')" "$(apo_state_get FINAL_GPU '')" \
        "$(apo_state_get GPU_KEY '')" "$(apo_state_get NORMAL_VOLTAGE '')" || true)
    [[ $source_zero_mode == present || $source_zero_mode == absent ]] || return 1

    APO_RESTORE_SOURCE_STATE=$source_state
    APO_RESTORE_SOURCE_ARTIFACT=$source_artifact
    APO_RESTORE_SOURCE_RUN_ID=$source_run_id
    APO_RESTORE_SOURCE_HASH=$source_hash
    APO_RESTORE_SOURCE_CPU=$(apo_state_get FINAL_CPU '')
    APO_RESTORE_SOURCE_GPU=$(apo_state_get FINAL_GPU '')
    APO_RESTORE_SOURCE_VOLTAGE=$(apo_state_get NORMAL_VOLTAGE '')
    APO_RESTORE_SOURCE_PROFILE=$(apo_state_get PROFILE '')
    APO_RESTORE_SOURCE_MODE=$(apo_state_get MODE_EFFECTIVE '')
    APO_RESTORE_SOURCE_BOOT_CONFIG=$(apo_state_get BOOT_CONFIG '')
    APO_RESTORE_SOURCE_TRYBOOT_CONFIG=$(apo_state_get TRYBOOT_CONFIG '')
    APO_RESTORE_SOURCE_BOOT_MOUNT=$(apo_state_get BOOT_MOUNT '')
    APO_RESTORE_SOURCE_GPU_KEY=$(apo_state_get GPU_KEY '')
    APO_RESTORE_SOURCE_DISPLAY_BASELINE=$(apo_state_get DISPLAY_BASELINE '')
    APO_RESTORE_SOURCE_AUDIO_BASELINE=$(apo_state_get AUDIO_BASELINE '')
    APO_RESTORE_SOURCE_STORAGE_LAYOUT=$(apo_state_get STORAGE_LAYOUT '')
    APO_RESTORE_SOURCE_THROTTLE_BASELINE=$(apo_state_get THROTTLE_BASELINE throttled=0x0)
    APO_RESTORE_SOURCE_THROTTLE_RUNTIME_BASELINE=$(apo_state_get THROTTLE_RUNTIME_BASELINE throttled=0x0)
    APO_RESTORE_SOURCE_THROTTLE_RECENT_SUPPORTED=$(apo_state_get THROTTLE_RECENT_SUPPORTED 0)
    APO_RESTORE_SOURCE_AUTO_BASELINE_CPU=$(apo_state_get AUTO_BASELINE_CPU '')
    APO_RESTORE_SOURCE_AUTO_BASELINE_GPU=$(apo_state_get AUTO_BASELINE_GPU '')
    APO_RESTORE_SOURCE_AUTO_BASELINE_VOLTAGE=$(apo_state_get AUTO_BASELINE_VOLTAGE '')
    APO_RESTORE_SOURCE_AUTO_BASELINE_PROVENANCE=$(apo_state_get AUTO_BASELINE_PROVENANCE '')
    APO_RESTORE_SOURCE_AUTO_BASELINE_EVIDENCE=$(apo_state_get AUTO_BASELINE_EVIDENCE '')

    # Preserve the source run's health policy for the fresh post-restore proof.
    apo_config_restore_from_state
}

apo_restore_select_source() {
    local state_file state_index
    local -a state_files=()
    local -A state_screen=()

    if [[ -n ${APO_SELECTED_RUN_ID:-} ]]; then
        state_file=$(apo_find_state_file "$APO_SELECTED_RUN_ID" || true)
        [[ -n $state_file ]] ||
            apo_die "No retained state exists for restore run $APO_SELECTED_RUN_ID." "$APO_EXIT_USAGE"
        apo_restore_capture_source "$state_file" ||
            apo_die 'The selected run is not a current-schema, fully validated, applied result with an intact hash-bound config artifact.' "$APO_EXIT_APPLY"
        return 0
    fi

    shopt -s nullglob
    state_files=("${APO_OUTPUT_DIR}/${APO_TARGET_SLUG}-"*.state)
    shopt -u nullglob
    for ((state_index=${#state_files[@]} - 1; state_index >= 0; state_index--)); do
        state_file=${state_files[$state_index]}
        [[ $state_file != "${APO_OUTPUT_DIR}/${APO_TARGET_SLUG}-latest.state" && -f $state_file && ! -L $state_file ]] || continue
        apo_state_load_fields "$state_file" state_screen \
            FORMAT_VERSION RUN_SCHEMA REMOTE_TARGET ORIGIN_COMMAND STATUS PHASE FINAL_STAGE \
            VALIDATED VALIDATION_SCHEMA APPLY_STATUS || continue
        [[ ${state_screen[FORMAT_VERSION]:-} == 1 &&
           ${state_screen[RUN_SCHEMA]:-} == "$APO_CURRENT_RUN_SCHEMA" &&
           ${state_screen[REMOTE_TARGET]:-} == "$APO_REMOTE_TARGET" &&
           ${state_screen[ORIGIN_COMMAND]:-} == overclock &&
           ${state_screen[STATUS]:-} == PASS && ${state_screen[PHASE]:-} == COMPLETE &&
           ${state_screen[FINAL_STAGE]:-} == COMPLETE &&
           ${state_screen[VALIDATED]:-0} == 1 &&
           ${state_screen[VALIDATION_SCHEMA]:-} == "$APO_CURRENT_VALIDATION_SCHEMA" &&
           ${state_screen[APPLY_STATUS]:-} == APPLIED ]] || continue
        if apo_restore_capture_source "$state_file"; then return 0; fi
    done
    apo_die 'No retained current-schema, fully validated, applied result with an intact config artifact is available to restore.' "$APO_EXIT_APPLY"
}

apo_restore_initialize_audit() {
    apo_init_artifacts
    apo_state_initialize
    apo_config_store_in_state
    apo_store_artifact_state
    apo_state_set PHASE RESTORE
    apo_state_set SUBPHASE INITIALIZING
    apo_state_set STATUS RUNNING
    apo_state_set RESTORE_STATUS INITIALIZING
    apo_state_set RESTORE_SOURCE_RUN_ID "$APO_RESTORE_SOURCE_RUN_ID"
    apo_state_set RESTORE_SOURCE_HASH "$APO_RESTORE_SOURCE_HASH"
    apo_state_set SOURCE_APPLIED_RUN_ID "$APO_RESTORE_SOURCE_RUN_ID"
    apo_state_set SOURCE_APPLIED_PERMANENT_HASH "$APO_RESTORE_SOURCE_HASH"
    apo_state_set FINAL_CPU "$APO_RESTORE_SOURCE_CPU"
    apo_state_set FINAL_GPU "$APO_RESTORE_SOURCE_GPU"
    apo_state_set FINAL_TARGET_CPU "$APO_RESTORE_SOURCE_CPU"
    apo_state_set FINAL_TARGET_GPU "$APO_RESTORE_SOURCE_GPU"
    apo_state_set TEST_VOLTAGE "$APO_RESTORE_SOURCE_VOLTAGE"
    apo_state_set PROFILE "$APO_RESTORE_SOURCE_PROFILE"
    apo_state_set MODE_EFFECTIVE "$APO_RESTORE_SOURCE_MODE"
    apo_state_set BOOT_CONFIG "$APO_RESTORE_SOURCE_BOOT_CONFIG"
    apo_state_set TRYBOOT_CONFIG "$APO_RESTORE_SOURCE_TRYBOOT_CONFIG"
    apo_state_set BOOT_MOUNT "$APO_RESTORE_SOURCE_BOOT_MOUNT"
    apo_state_set GPU_KEY "$APO_RESTORE_SOURCE_GPU_KEY"
    apo_state_set DISPLAY_BASELINE "$APO_RESTORE_SOURCE_DISPLAY_BASELINE"
    apo_state_set AUDIO_BASELINE "$APO_RESTORE_SOURCE_AUDIO_BASELINE"
    apo_state_set STORAGE_LAYOUT "$APO_RESTORE_SOURCE_STORAGE_LAYOUT"
    apo_state_set THROTTLE_BASELINE "$APO_RESTORE_SOURCE_THROTTLE_BASELINE"
    apo_state_set THROTTLE_RUNTIME_BASELINE "$APO_RESTORE_SOURCE_THROTTLE_RUNTIME_BASELINE"
    apo_state_set THROTTLE_RECENT_SUPPORTED "$APO_RESTORE_SOURCE_THROTTLE_RECENT_SUPPORTED"
    apo_state_set AUTO_BASELINE_CPU "$APO_RESTORE_SOURCE_AUTO_BASELINE_CPU"
    apo_state_set AUTO_BASELINE_GPU "$APO_RESTORE_SOURCE_AUTO_BASELINE_GPU"
    apo_state_set AUTO_BASELINE_VOLTAGE "$APO_RESTORE_SOURCE_AUTO_BASELINE_VOLTAGE"
    apo_state_set AUTO_BASELINE_PROVENANCE "$APO_RESTORE_SOURCE_AUTO_BASELINE_PROVENANCE"
    apo_state_set AUTO_BASELINE_EVIDENCE "$APO_RESTORE_SOURCE_AUTO_BASELINE_EVIDENCE"
    apo_state_save

    apo_summary_line 'AutoPiOverclock validated-config restore'
    apo_summary_line "Run ID: $APO_RUN_ID"
    apo_summary_line "Target: $APO_REMOTE_TARGET"
    apo_summary_line "Validated source run: $APO_RESTORE_SOURCE_RUN_ID"
    apo_summary_line "Validated source hash: $APO_RESTORE_SOURCE_HASH"
    apo_summary_line "Validated clocks: CPU $APO_RESTORE_SOURCE_CPU MHz / $APO_RESTORE_SOURCE_GPU_KEY $APO_RESTORE_SOURCE_GPU MHz"
    apo_summary_line 'Previous run artifacts: preserved'
    apo_summary_line ''
    apo_event restore-start INFO '' "command=restore source-run=$APO_RESTORE_SOURCE_RUN_ID version=$APO_VERSION"
}

apo_restore_store_live_discovery() {
    APO_BOOT_CONFIG=${APO_DISCOVERY[BOOT_CONFIG]:-}
    APO_TRYBOOT_CONFIG=${APO_DISCOVERY[TRYBOOT_CONFIG]:-}
    APO_BOOT_MOUNT=${APO_DISCOVERY[BOOT_MOUNT]:-}
    APO_GPU_KEY=${APO_DISCOVERY[GPU_KEY]:-}
    APO_NORMAL_CPU=${APO_DISCOVERY[NORMAL_CPU]:-}
    APO_NORMAL_GPU=${APO_DISCOVERY[NORMAL_GPU]:-}
    APO_NORMAL_VOLTAGE=${APO_DISCOVERY[NORMAL_VOLTAGE]:-}
    APO_PERMANENT_CONFIG_HASH=${APO_DISCOVERY[PERMANENT_HASH]:-}
    APO_STORAGE_LAYOUT=${APO_DISCOVERY[STORAGE_LAYOUT]:-}
    APO_MODE_EFFECTIVE=$APO_RESTORE_SOURCE_MODE
    APO_DISPLAY_BASELINE=$APO_RESTORE_SOURCE_DISPLAY_BASELINE
    APO_AUDIO_BASELINE=$APO_RESTORE_SOURCE_AUDIO_BASELINE
    APO_TEST_VOLTAGE=$APO_RESTORE_SOURCE_VOLTAGE
    APO_THROTTLE_BASELINE=$APO_RESTORE_SOURCE_THROTTLE_BASELINE
    APO_THROTTLE_RUNTIME_BASELINE=$APO_RESTORE_SOURCE_THROTTLE_RUNTIME_BASELINE
    APO_THROTTLE_RECENT_SUPPORTED=$APO_RESTORE_SOURCE_THROTTLE_RECENT_SUPPORTED

    [[ $APO_BOOT_CONFIG == "$APO_RESTORE_SOURCE_BOOT_CONFIG" &&
       $APO_TRYBOOT_CONFIG == "$APO_RESTORE_SOURCE_TRYBOOT_CONFIG" &&
       $APO_GPU_KEY == "$APO_RESTORE_SOURCE_GPU_KEY" ]] ||
        apo_die 'Live profile or boot paths do not match the retained validated result; restore is refused.' "$APO_EXIT_APPLY"
    [[ -n $APO_STORAGE_LAYOUT && $APO_STORAGE_LAYOUT == "$APO_RESTORE_SOURCE_STORAGE_LAYOUT" ]] ||
        apo_die 'Live storage layout does not match the retained validated result; restore is refused.' "$APO_EXIT_APPLY"
    [[ $APO_PERMANENT_CONFIG_HASH =~ ^[0-9a-f]{64}$ &&
       $APO_NORMAL_CPU =~ ^[1-9][0-9]*$ && $APO_NORMAL_GPU =~ ^[1-9][0-9]*$ ]] ||
        apo_die 'Restore discovery returned incomplete permanent-config or clock evidence.' "$APO_EXIT_PREFLIGHT"
    apo_is_int "$APO_NORMAL_VOLTAGE" ||
        apo_die 'Restore discovery returned malformed voltage evidence.' "$APO_EXIT_PREFLIGHT"
    [[ ${APO_DISCOVERY[TRYBOOT_EXISTS]:-} == 0 ]] ||
        apo_die 'Restore requires an absent tryboot path; preserve and reconcile the existing evidence first.' "$APO_EXIT_APPLY"

    apo_state_set BOOT_CONFIG "$APO_BOOT_CONFIG"
    apo_state_set TRYBOOT_CONFIG "$APO_TRYBOOT_CONFIG"
    apo_state_set BOOT_MOUNT "$APO_BOOT_MOUNT"
    apo_state_set GPU_KEY "$APO_GPU_KEY"
    apo_state_set NORMAL_CPU "$APO_NORMAL_CPU"
    apo_state_set NORMAL_GPU "$APO_NORMAL_GPU"
    apo_state_set NORMAL_VOLTAGE "$APO_NORMAL_VOLTAGE"
    apo_state_set PERMANENT_HASH "$APO_PERMANENT_CONFIG_HASH"
    apo_state_set STORAGE_LAYOUT "$APO_STORAGE_LAYOUT"
    apo_state_set RESTORE_PREVIOUS_CPU "$APO_NORMAL_CPU"
    apo_state_set RESTORE_PREVIOUS_GPU "$APO_NORMAL_GPU"
    apo_state_set RESTORE_PREVIOUS_VOLTAGE "$APO_NORMAL_VOLTAGE"
    apo_state_set RESTORE_PREVIOUS_HASH "$APO_PERMANENT_CONFIG_HASH"
    apo_state_set RESTORE_STATUS DISCOVERED
    apo_state_set SUBPHASE SOURCE_VERIFIED
    apo_state_save
}

apo_restore_validated_config() {
    local probed_profile current_hash expected_hash current_file diff_file diff_rc backup_file remote_proposed
    local restore_log reported_backup reported_hash restore_failure

    apo_restore_select_source
    apo_restore_initialize_audit

    apo_ssh_preflight
    probed_profile=$(apo_probe_profile)
    [[ $probed_profile == "$APO_RESTORE_SOURCE_PROFILE" ]] ||
        apo_die 'The live target profile does not match the retained validated result.' "$APO_EXIT_APPLY"
    APO_PROFILE=$probed_profile
    apo_load_profile "$APO_PROFILE"
    APO_HAVE_REMOTE_CONTEXT=1
    apo_deploy_worker
    apo_discovery_capture
    [[ ${APO_DISCOVERY[PROFILE]:-} == "$APO_PROFILE" ]] ||
        apo_die 'Profile probe and restore discovery disagree.' "$APO_EXIT_PREFLIGHT"
    apo_validate_pi5
    apo_restore_store_live_discovery
    apo_apply_assert_tryboot_clear || apo_die "$APO_LAST_REASON" "$APO_EXIT_APPLY"

    expected_hash=$(sha256sum "$APO_RESTORE_SOURCE_ARTIFACT" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    [[ $expected_hash == "$APO_RESTORE_SOURCE_HASH" ]] ||
        apo_die 'The retained validated config artifact changed before restore; no target mutation was attempted.' "$APO_EXIT_APPLY"
    current_hash=$APO_PERMANENT_CONFIG_HASH
    current_file="${APO_RUN_PREFIX}-restore-current-config.txt"
    diff_file="${APO_RUN_PREFIX}-restore.diff"
    apo_remote_root_read_file "$current_file" "cat $(apo_sh_quote "$APO_BOOT_CONFIG")" ||
        apo_die "The current permanent config could not be captured after $APO_TRANSIENT_READ_ATTEMPTS attempts." "$APO_EXIT_APPLY"
    [[ $(sha256sum "$current_file" 2>/dev/null | awk 'NR == 1 {print $1}' || true) == "$current_hash" ]] ||
        apo_die 'The permanent config changed between discovery and restore planning.' "$APO_EXIT_APPLY"

    set +e
    diff -u --label current-config.txt --label validated-config.txt "$current_file" "$APO_RESTORE_SOURCE_ARTIFACT" > "$diff_file"
    diff_rc=$?
    set -e
    if (( diff_rc != 0 && diff_rc != 1 )); then
        apo_die 'Could not generate the validated-config restore diff.' "$APO_EXIT_APPLY"
    fi
    if (( diff_rc == 1 )); then
        printf '\n===== EXACT VALIDATED CONFIG RESTORE DIFF =====\n' >&2
        cat "$diff_file" >&2
        printf '===============================================\n\n' >&2
    fi

    apo_state_set APPLY_OLD_HASH "$current_hash"
    apo_state_set APPLY_EXPECTED_HASH "$expected_hash"
    apo_state_set APPLY_BOOT_ID "$(apo_remote_boot_id || true)"
    apo_state_set APPLY_RECOVERY_ACTION ''
    apo_state_set APPLY_FAILURE_REASON ''
    apo_state_set RESTORE_STATUS VERIFYING
    apo_state_set SUBPHASE VERIFYING_RESTORED_CONFIG
    apo_state_save

    if (( diff_rc == 0 )); then
        apo_event restore INFO '' 'Permanent config already matches the retained validated result; proving it through a fresh normal reboot.'
        if ! apo_apply_force_normal_boot_and_health "$expected_hash" "$APO_RESTORE_SOURCE_CPU" \
            "$APO_RESTORE_SOURCE_GPU" "$APO_RESTORE_SOURCE_VOLTAGE" restore-existing-config-health; then
            apo_die "The matching validated config failed fresh reboot verification: $APO_LAST_REASON" "$APO_EXIT_APPLY"
        fi
        apo_state_set APPLY_BACKUP ''
        apo_apply_mark_applied "$expected_hash" "$APO_RESTORE_SOURCE_CPU" "$APO_RESTORE_SOURCE_GPU" \
            "$APO_RESTORE_SOURCE_VOLTAGE" not-needed
    else
        backup_file=$(apo_apply_backup_path "$APO_RUN_ID" || true)
        [[ -n $backup_file ]] ||
            apo_die "No deterministic restore backup path exists for profile $APO_PROFILE." "$APO_EXIT_APPLY"
        apo_state_set APPLY_BACKUP "$backup_file"
        apo_state_set APPLY_STATUS APPLYING
        apo_state_set RESTORE_STATUS APPLYING
        apo_state_set SUBPHASE RESTORING_VALIDATED_CONFIG
        apo_state_save
        remote_proposed="${APO_REMOTE_WORK_DIR}/restore-${APO_RUN_ID}.txt"
        apo_remote_upload_root "$APO_RESTORE_SOURCE_ARTIFACT" "$remote_proposed"
        if ! apo_run_worker_capture restore-config apply-permanent "$remote_proposed" "$current_hash" "$expected_hash" "$APO_RUN_ID"; then
            restore_failure=${APO_LAST_REASON:-'The validated-config restore worker failed.'}
            apo_state_set APPLY_RECOVERY_ACTION ROLLBACK
            apo_state_set APPLY_FAILURE_REASON "$restore_failure"
            apo_state_save
            apo_reconcile_interrupted_apply || true
            apo_die "Validated-config restore failed: $restore_failure; reconciliation status: $(apo_state_get APPLY_STATUS APPLYING)." "$APO_EXIT_APPLY"
        fi
        restore_log=$APO_LAST_WORKER_LOG
        apo_parse_data_file "$restore_log" APO_WORKER_DATA
        reported_backup=${APO_WORKER_DATA[BACKUP_FILE]:-}
        reported_hash=${APO_WORKER_DATA[NEW_HASH]:-}
        if [[ $reported_backup != "$backup_file" || $reported_hash != "$expected_hash" ]]; then
            apo_state_set APPLY_RECOVERY_ACTION ROLLBACK
            apo_state_set APPLY_FAILURE_REASON 'Restore worker metadata did not match the persisted plan.'
            apo_state_save
            apo_reconcile_interrupted_apply || true
            apo_die "Restore worker metadata did not match the persisted plan; reconciliation status: $(apo_state_get APPLY_STATUS APPLYING)." "$APO_EXIT_APPLY"
        fi
        apo_reconcile_interrupted_apply || apo_die "$APO_LAST_REASON" "$APO_EXIT_APPLY"
        [[ $(apo_state_get APPLY_STATUS '') == APPLIED ]] ||
            apo_die "The validated config was not retained; reconciliation status: $(apo_state_get APPLY_STATUS unknown)." "$APO_EXIT_APPLY"
    fi

    APO_PERMANENT_CONFIG_HASH=$expected_hash
    apo_state_set RESTORE_STATUS VERIFIED
    apo_state_set SUBPHASE VALIDATED_CONFIG_RESTORED
    apo_state_set PHASE COMPLETE
    apo_state_set STATUS PASS
    apo_state_set FAILURE_CLASS ''
    apo_state_set FAILURE_REASON ''
    apo_state_save
    apo_summary_line "Backup of replaced config: $(apo_state_get APPLY_BACKUP not-needed)"
    apo_summary_line "Verified permanent hash: $expected_hash"
    apo_summary_line "Verified clocks: CPU $APO_RESTORE_SOURCE_CPU MHz / $APO_RESTORE_SOURCE_GPU_KEY $APO_RESTORE_SOURCE_GPU MHz"
    apo_summary_line 'Result: retained validated config restored and verified'
    apo_event restore PASS '' "Retained validated config from run $APO_RESTORE_SOURCE_RUN_ID was restored and verified after a normal reboot."
}
