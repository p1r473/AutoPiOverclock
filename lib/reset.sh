#!/usr/bin/env bash
# Standalone stock-reset controller. This creates a new audit trail and never
# deletes or rewrites artifacts from an earlier tuning or reset operation.

apo_reset_abort_worker() {
    local failure_class=${APO_LAST_CLASS:-HARNESS_FAILURE}
    local failure_reason=${APO_LAST_REASON:-'The stock-reset worker failed without a reason.'}
    apo_die "$failure_reason" "$(apo_class_exit_code "$failure_class")"
}

apo_reset_store_discovery() {
    local discovery_key
    APO_BOOT_CONFIG=${APO_DISCOVERY[BOOT_CONFIG]:-}
    APO_TRYBOOT_CONFIG=${APO_DISCOVERY[TRYBOOT_CONFIG]:-}
    APO_BOOT_MOUNT=${APO_DISCOVERY[BOOT_MOUNT]:-}
    APO_GPU_KEY=${APO_DISCOVERY[GPU_KEY]:-}
    APO_NORMAL_CPU=${APO_DISCOVERY[NORMAL_CPU]:-}
    APO_NORMAL_GPU=${APO_DISCOVERY[NORMAL_GPU]:-}
    APO_NORMAL_VOLTAGE=${APO_DISCOVERY[NORMAL_VOLTAGE]:-}
    APO_PERMANENT_CONFIG_HASH=${APO_DISCOVERY[PERMANENT_HASH]:-}
    APO_STORAGE_LAYOUT=${APO_DISCOVERY[STORAGE_LAYOUT]:-}

    [[ -n $APO_BOOT_CONFIG ]] || apo_die 'Reset discovery omitted the permanent boot-config path.' "$APO_EXIT_PREFLIGHT"
    [[ $APO_PERMANENT_CONFIG_HASH =~ ^[0-9a-f]{64}$ ]] ||
        apo_die 'Reset discovery returned an invalid permanent-config hash.' "$APO_EXIT_PREFLIGHT"

    apo_state_set PROFILE "$APO_PROFILE"
    apo_state_set MODE_EFFECTIVE stock-reset
    apo_state_set BOOT_CONFIG "$APO_BOOT_CONFIG"
    apo_state_set TRYBOOT_CONFIG "$APO_TRYBOOT_CONFIG"
    apo_state_set BOOT_MOUNT "$APO_BOOT_MOUNT"
    apo_state_set GPU_KEY "$APO_GPU_KEY"
    apo_state_set NORMAL_CPU "$APO_NORMAL_CPU"
    apo_state_set NORMAL_GPU "$APO_NORMAL_GPU"
    apo_state_set NORMAL_VOLTAGE "$APO_NORMAL_VOLTAGE"
    apo_state_set RESET_PREVIOUS_CPU "$APO_NORMAL_CPU"
    apo_state_set RESET_PREVIOUS_GPU "$APO_NORMAL_GPU"
    apo_state_set RESET_PREVIOUS_VOLTAGE "$APO_NORMAL_VOLTAGE"
    apo_state_set PERMANENT_HASH "$APO_PERMANENT_CONFIG_HASH"
    apo_state_set STORAGE_LAYOUT "$APO_STORAGE_LAYOUT"
    for discovery_key in MODEL COMPATIBLE ARCH OS_ID OS_VERSION TRYBOOT_EXISTS TRYBOOT_TYPE TRYBOOT_HASH ROOT_SOURCE BOOT_SOURCE; do
        apo_state_set "DISC_${discovery_key}" "${APO_DISCOVERY[$discovery_key]:-}"
    done
    apo_state_save
}

apo_reset_validate_verification() {
    local expected_hash=$1 verified_hash verified_cpu verified_gpu verified_voltage
    apo_parse_data_file "$APO_LAST_WORKER_LOG" APO_WORKER_DATA
    verified_hash=${APO_WORKER_DATA[RESET_NEW_HASH]:-}
    verified_cpu=${APO_WORKER_DATA[RESET_ACTIVE_CPU]:-}
    verified_gpu=${APO_WORKER_DATA[RESET_ACTIVE_GPU]:-}
    verified_voltage=${APO_WORKER_DATA[RESET_ACTIVE_VOLTAGE]:-}
    [[ $verified_hash == "$expected_hash" ]] ||
        apo_die 'Post-reset verification did not bind the expected permanent-config hash.' "$APO_EXIT_RECOVERY"
    [[ $verified_cpu == 2400 && ( $verified_gpu == 800 || $verified_gpu == 960 ) && $verified_voltage == 0 ]] ||
        apo_die 'Post-reset verification returned an invalid stock clock/voltage tuple.' "$APO_EXIT_RECOVERY"
    APO_NORMAL_CPU=$verified_cpu
    APO_NORMAL_GPU=$verified_gpu
    APO_NORMAL_VOLTAGE=$verified_voltage
    apo_state_set NORMAL_CPU "$verified_cpu"
    apo_state_set NORMAL_GPU "$verified_gpu"
    apo_state_set NORMAL_VOLTAGE "$verified_voltage"
    apo_state_set RESET_ACTIVE_CPU "$verified_cpu"
    apo_state_set RESET_ACTIVE_GPU "$verified_gpu"
    apo_state_set RESET_ACTIVE_VOLTAGE "$verified_voltage"
    apo_state_save
}

apo_reset_validate_metadata() {
    local discovered_hash=$1 reset_key reset_backup reset_tryboot_backup reset_old_hash reset_new_hash reset_disabled_keys

    for reset_key in RESET_BACKUP RESET_OLD_HASH RESET_NEW_HASH RESET_DISABLED_KEYS; do
        [[ ${APO_WORKER_DATA[$reset_key]+present} == present ]] ||
            apo_die "reset-stock omitted required metadata: $reset_key" "$APO_EXIT_HARNESS"
    done
    reset_backup=${APO_WORKER_DATA[RESET_BACKUP]}
    reset_tryboot_backup=${APO_WORKER_DATA[RESET_TRYBOOT_BACKUP]:-}
    reset_old_hash=${APO_WORKER_DATA[RESET_OLD_HASH]}
    reset_new_hash=${APO_WORKER_DATA[RESET_NEW_HASH]}
    reset_disabled_keys=${APO_WORKER_DATA[RESET_DISABLED_KEYS]}

    [[ -n $reset_backup ]] || apo_die 'reset-stock returned an empty backup path.' "$APO_EXIT_HARNESS"
    [[ $reset_old_hash =~ ^[0-9a-f]{64}$ && $reset_old_hash == "$discovered_hash" ]] ||
        apo_die 'reset-stock old-hash evidence does not match the discovery checkpoint.' "$APO_EXIT_RECOVERY"
    [[ $reset_new_hash =~ ^[0-9a-f]{64}$ ]] ||
        apo_die 'reset-stock returned an invalid new permanent-config hash.' "$APO_EXIT_HARNESS"

    apo_state_set RESET_BACKUP "$reset_backup"
    apo_state_set RESET_TRYBOOT_BACKUP "$reset_tryboot_backup"
    apo_state_set RESET_OLD_HASH "$reset_old_hash"
    apo_state_set RESET_NEW_HASH "$reset_new_hash"
    apo_state_set RESET_DISABLED_KEYS "$reset_disabled_keys"
    apo_state_set PERMANENT_HASH "$reset_new_hash"
    apo_state_set RESET_STATUS STAGED
    apo_state_set SUBPHASE RESET_STAGED
    apo_state_save

    APO_PERMANENT_CONFIG_HASH=$reset_new_hash
    apo_summary_line "Backup: $reset_backup"
    [[ -z $reset_tryboot_backup ]] || apo_summary_line "Tryboot backup: $reset_tryboot_backup"
    apo_summary_line "Original permanent hash: $reset_old_hash"
    apo_summary_line "Stock-reset permanent hash: $reset_new_hash"
    apo_summary_line "Disabled keys: ${reset_disabled_keys:-none}"
}

apo_reset_stock() {
    local probed_profile discovered_hash old_boot_id new_boot_id reset_backup

    apo_init_artifacts
    apo_state_initialize
    apo_store_artifact_state
    apo_state_set PHASE RESET
    apo_state_set SUBPHASE INITIALIZING
    apo_state_set STATUS RUNNING
    apo_state_set RESET_STATUS INITIALIZING
    apo_state_save

    apo_summary_line 'AutoPiOverclock stock reset'
    apo_summary_line "Run ID: $APO_RUN_ID"
    apo_summary_line "Target: $APO_REMOTE_TARGET"
    apo_summary_line 'Previous run artifacts: preserved'
    apo_summary_line ''
    apo_event reset-start INFO '' "command=reset version=$APO_VERSION"

    apo_state_set RESET_STATUS PROBING
    apo_state_set SUBPHASE PROBING
    apo_state_save
    apo_ssh_preflight
    probed_profile=$(apo_probe_profile)
    APO_PROFILE=$probed_profile
    apo_load_profile "$APO_PROFILE"
    APO_HAVE_REMOTE_CONTEXT=1
    apo_deploy_worker

    apo_state_set RESET_STATUS DISCOVERING
    apo_state_set SUBPHASE DISCOVERING
    apo_state_save
    apo_discovery_capture
    [[ ${APO_DISCOVERY[PROFILE]:-} == "$APO_PROFILE" ]] ||
        apo_die 'Profile probe and reset discovery disagree.' "$APO_EXIT_PREFLIGHT"
    apo_validate_pi5
    apo_reset_store_discovery
    discovered_hash=$APO_PERMANENT_CONFIG_HASH
    old_boot_id=$(apo_remote_boot_id || true)
    [[ -n $old_boot_id ]] || apo_die 'Could not record the pre-reset boot ID.' "$APO_EXIT_PREFLIGHT"
    apo_state_set BASELINE_BOOT_ID "$old_boot_id"
    apo_state_set LAST_BOOT_ID "$old_boot_id"
    apo_state_set NORMAL_BOOT_ID "$old_boot_id"
    apo_state_set RESET_STATUS MUTATING
    apo_state_set SUBPHASE RESETTING_STOCK
    apo_state_set MUTATIONS_STARTED 1
    apo_state_save

    if ! apo_run_worker_capture reset-stock reset-stock "$discovered_hash" "$APO_RUN_ID"; then
        apo_reset_abort_worker
    fi
    apo_parse_data_file "$APO_LAST_WORKER_LOG" APO_WORKER_DATA
    apo_reset_validate_metadata "$discovered_hash"

    apo_state_set RESET_STATUS REBOOTING
    apo_state_set SUBPHASE REBOOTING
    apo_state_save
    apo_event reset-reboot INFO '' 'Rebooting to activate the backed-up stock configuration.'
    apo_remote_worker "$APO_REMOTE_WORKER" reboot-stock-reset "$APO_PERMANENT_CONFIG_HASH" >/dev/null 2>&1 || true
    new_boot_id=$(apo_wait_for_new_boot "$old_boot_id" "$APO_BOOT_TIMEOUT" || true)
    [[ -n $new_boot_id ]] ||
        apo_die "Stock-reset reboot did not return with a new boot ID within ${APO_BOOT_TIMEOUT}s." "$APO_EXIT_RECOVERY"
    apo_state_set LAST_BOOT_ID "$new_boot_id"
    apo_state_set NORMAL_BOOT_ID "$new_boot_id"
    apo_state_set RESET_STATUS VERIFYING
    apo_state_set SUBPHASE VERIFYING_STOCK
    apo_state_save
    sleep "$APO_BOOT_SETTLE_SECONDS"

    # The run-isolated worker normally survives reboot on both supported
    # profiles. Upload it again so verification does not depend on /var/tmp
    # retention policy or a target-side cleanup service.
    apo_deploy_worker
    if ! apo_run_worker_capture verify-stock-reset verify-stock-reset "$APO_PERMANENT_CONFIG_HASH"; then
        apo_reset_abort_worker
    fi
    apo_reset_validate_verification "$APO_PERMANENT_CONFIG_HASH"

    apo_state_set RESET_STATUS VERIFIED
    apo_state_set SUBPHASE STOCK_VERIFIED
    apo_state_set PHASE COMPLETE
    apo_state_set STATUS PASS
    apo_state_set FAILURE_CLASS ''
    apo_state_set FAILURE_REASON ''
    apo_state_save
    reset_backup=$(apo_state_get RESET_BACKUP '')
    apo_summary_line "Verified boot ID: $new_boot_id"
    apo_summary_line 'Result: stock reset verified'
    apo_event reset PASS '' "Permanent clock/voltage overrides were disabled, rebooted, and verified at stock settings. Backup: $reset_backup. Prior logs and saved runs were preserved."
}
