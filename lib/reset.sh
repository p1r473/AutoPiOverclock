#!/usr/bin/env bash
# Standalone stock-reset controller. This creates a new audit trail and keeps
# earlier tuning and reset artifacts unless the explicit force form deletes
# only the history ledger after verified stock and a durable cutoff commit.

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

apo_reset_retire_prior_resumable_runs() {
    apo_state_set RESET_RETIRE_RESUMABLE 1
    apo_state_set RESET_RETIRE_CUTOFF_RUN_ID "$APO_RUN_ID"
    apo_state_save
    apo_event reset-resume-retirement INFO '' \
        'This stock reset retires every earlier tuning checkpoint for this target from continuation while preserving its audit files.'
}

apo_reset_cleanup_owned_watchdog() {
    local kind=${APO_DISCOVERY[NETWORK_WATCHDOG_KIND]:-}
    local installing_run=${APO_DISCOVERY[NETWORK_WATCHDOG_INSTALL_RUN_ID]:-}
    case $kind in
        debian-watchdog-observer|debian-systemd-companion|batocera-network-companion)
            [[ -n $installing_run ]] || {
                apo_die "Reset found the temporary watchdog provider $kind without its installing run ID. No clock reset was attempted." "$APO_EXIT_RECOVERY"
            }
            ;;
    esac
    [[ -n $installing_run ]] || return 0
    declare -F apo_profile_cleanup_discovered_watchdog >/dev/null 2>&1 || {
        apo_die "Reset found an AutoPiOverclock-owned watchdog provider from run $installing_run, but this target profile cannot remove it from target-side ownership evidence." "$APO_EXIT_RECOVERY"
    }
    apo_state_set RESET_STATUS CLEANING_WATCHDOG
    apo_state_set SUBPHASE CLEANING_RUN_WATCHDOG
    apo_state_set MUTATIONS_STARTED 1
    apo_state_save
    apo_event reset-network-watchdog-cleanup INFO '' \
        "Removing the strictly verified AutoPiOverclock-owned watchdog provider from run $installing_run before stock reset."
    if ! apo_profile_cleanup_discovered_watchdog; then
        apo_die "Reset could not safely remove the AutoPiOverclock-owned watchdog provider from run $installing_run: ${APO_LAST_REASON:-unknown cleanup failure}. No clock reset was attempted." "$APO_EXIT_RECOVERY"
    fi
    apo_reset_store_discovery
}

apo_reset_verify_watchdog_ready() {
    declare -F apo_profile_watchdogs_ready >/dev/null 2>&1 || {
        apo_die 'Reset cannot verify the target hardware-watchdog recovery chain for this profile. No clock reset was attempted.' "$APO_EXIT_RECOVERY"
    }
    apo_profile_watchdogs_ready || {
        apo_die "Reset requires the existing hardware-watchdog recovery chain to be healthy before changing clocks. $(apo_profile_watchdog_description 2>/dev/null || true) No clock reset was attempted." "$APO_EXIT_RECOVERY"
    }
}

apo_reset_validation_fail() {
    local failure_reason=$1 failure_class=$2 exit_code=$3 prepare_backup=''
    if [[ ${APO_AUTO_PREPARE:-0} == 1 ]]; then
        prepare_backup=$(apo_state_get PREPARE_BASELINE_BACKUP '')
        [[ -z $prepare_backup ]] || failure_reason="$failure_reason Backup: $prepare_backup."
        apo_prepare_baseline_fail "$failure_class" "$failure_reason"
    fi
    apo_die "$failure_reason" "$exit_code"
}

apo_reset_validate_verification() {
    local expected_hash=$1 verified_hash verified_cpu verified_gpu verified_voltage
    apo_parse_data_file "$APO_LAST_WORKER_LOG" APO_WORKER_DATA
    verified_hash=${APO_WORKER_DATA[RESET_NEW_HASH]:-}
    verified_cpu=${APO_WORKER_DATA[RESET_ACTIVE_CPU]:-}
    verified_gpu=${APO_WORKER_DATA[RESET_ACTIVE_GPU]:-}
    verified_voltage=${APO_WORKER_DATA[RESET_ACTIVE_VOLTAGE]:-}
    [[ $verified_hash == "$expected_hash" ]] ||
        apo_reset_validation_fail 'Post-reset verification did not bind the expected permanent-config hash.' RECOVERY_FAILURE "$APO_EXIT_RECOVERY"
    [[ $verified_cpu == 2400 && ( $verified_gpu == 800 || $verified_gpu == 960 ) && $verified_voltage == 0 ]] ||
        apo_reset_validation_fail 'Post-reset verification returned an invalid stock clock/voltage tuple.' RECOVERY_FAILURE "$APO_EXIT_RECOVERY"
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
            apo_reset_validation_fail "reset-stock omitted required metadata: $reset_key" HARNESS_FAILURE "$APO_EXIT_HARNESS"
    done
    reset_backup=${APO_WORKER_DATA[RESET_BACKUP]}
    reset_tryboot_backup=${APO_WORKER_DATA[RESET_TRYBOOT_BACKUP]:-}
    reset_old_hash=${APO_WORKER_DATA[RESET_OLD_HASH]}
    reset_new_hash=${APO_WORKER_DATA[RESET_NEW_HASH]}
    reset_disabled_keys=${APO_WORKER_DATA[RESET_DISABLED_KEYS]}

    [[ -n $reset_backup ]] || apo_reset_validation_fail 'reset-stock returned an empty backup path.' HARNESS_FAILURE "$APO_EXIT_HARNESS"
    [[ $reset_old_hash =~ ^[0-9a-f]{64}$ && $reset_old_hash == "$discovered_hash" ]] ||
        apo_reset_validation_fail 'reset-stock old-hash evidence does not match the discovery checkpoint.' RECOVERY_FAILURE "$APO_EXIT_RECOVERY"
    [[ $reset_new_hash =~ ^[0-9a-f]{64}$ ]] ||
        apo_reset_validation_fail 'reset-stock returned an invalid new permanent-config hash.' HARNESS_FAILURE "$APO_EXIT_HARNESS"

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

apo_prepare_baseline_fail() {
    local failure_class=${1:-HARNESS_FAILURE} failure_reason=${2:-'First-time baseline normalization failed.'}
    apo_state_set PREPARE_BASELINE_STATUS FAILED
    apo_state_set PREPARE_BASELINE_FAILURE_CLASS "$failure_class"
    apo_state_set PREPARE_BASELINE_FAILURE_REASON "$failure_reason"
    apo_state_save
    apo_die "$failure_reason" "$(apo_class_exit_code "$failure_class")"
}

apo_prepare_stock_baseline() {
    local discovered_hash old_boot_id new_boot_id reset_backup

    [[ ${APO_AUTO_PREPARE:-0} == 1 && ${APO_DRY_RUN:-0} == 0 ]] || return 0
    if apo_config_stock_auto_baseline_ready "$APO_NORMAL_CPU" "$APO_NORMAL_GPU" "$APO_NORMAL_VOLTAGE" \
        "$APO_PERMANENT_TUNING_PROVENANCE" "$APO_PERMANENT_TUNING_EVIDENCE"; then
        apo_state_set PREPARE_BASELINE_STATUS NOT_NEEDED
        apo_state_save
        return 0
    fi

    discovered_hash=$APO_PERMANENT_CONFIG_HASH
    [[ $discovered_hash =~ ^[0-9a-f]{64}$ ]] ||
        apo_prepare_baseline_fail PREFLIGHT_FAILURE 'First-time preparation cannot normalize an invalid permanent-config hash.'
    old_boot_id=$(apo_remote_boot_id || true)
    [[ -n $old_boot_id ]] ||
        apo_prepare_baseline_fail PREFLIGHT_FAILURE 'First-time preparation could not record the boot ID before stock normalization.'

    apo_state_set PREPARE_BASELINE_STATUS PLANNED
    apo_state_set PREPARE_BASELINE_OLD_HASH "$discovered_hash"
    apo_state_set PREPARE_BASELINE_NEW_HASH ''
    apo_state_set PREPARE_BASELINE_BACKUP ''
    apo_state_set PREPARE_BASELINE_DISABLED_KEYS ''
    apo_state_set PREPARE_BASELINE_OLD_BOOT_ID "$old_boot_id"
    apo_state_set PREPARE_BASELINE_NEW_BOOT_ID ''
    apo_state_set PREPARE_BASELINE_PROFILE "$APO_PROFILE"
    apo_state_set PREPARE_BASELINE_BOOT_CONFIG "$APO_BOOT_CONFIG"
    apo_state_set PREPARE_BASELINE_TRYBOOT_CONFIG "$APO_TRYBOOT_CONFIG"
    apo_state_set PREPARE_BASELINE_GPU_KEY "$APO_GPU_KEY"
    apo_state_set PREPARE_BASELINE_CPU "$APO_NORMAL_CPU"
    apo_state_set PREPARE_BASELINE_GPU "$APO_NORMAL_GPU"
    apo_state_set PREPARE_BASELINE_VOLTAGE "$APO_NORMAL_VOLTAGE"
    apo_state_set PREPARE_BASELINE_PROVENANCE "$APO_PERMANENT_TUNING_PROVENANCE"
    apo_state_set PREPARE_BASELINE_EVIDENCE "$APO_PERMANENT_TUNING_EVIDENCE"
    apo_state_set PREPARE_BASELINE_FAILURE_CLASS ''
    apo_state_set PREPARE_BASELINE_FAILURE_REASON ''
    apo_state_set MUTATIONS_STARTED 1
    apo_state_save
    apo_event prepare-stock-normalization INFO '' "Backing up and disabling first-time permanent tuning controls before a verified stock reboot (audit=$APO_PERMANENT_TUNING_PROVENANCE evidence=$APO_PERMANENT_TUNING_EVIDENCE)."

    if ! apo_run_worker_capture prepare-stock-normalization reset-stock "$discovered_hash" "$APO_RUN_ID"; then
        apo_prepare_baseline_fail "${APO_LAST_CLASS:-HARNESS_FAILURE}" "${APO_LAST_REASON:-The first-time stock-normalization worker failed without a reason.}"
    fi
    apo_parse_data_file "$APO_LAST_WORKER_LOG" APO_WORKER_DATA
    apo_reset_validate_metadata "$discovered_hash"
    reset_backup=$(apo_state_get RESET_BACKUP '')
    apo_state_set PREPARE_BASELINE_STATUS STAGED
    apo_state_set PREPARE_BASELINE_NEW_HASH "$APO_PERMANENT_CONFIG_HASH"
    apo_state_set PREPARE_BASELINE_BACKUP "$reset_backup"
    apo_state_set PREPARE_BASELINE_DISABLED_KEYS "$(apo_state_get RESET_DISABLED_KEYS '')"
    apo_state_save

    apo_state_set PREPARE_BASELINE_STATUS REBOOTING
    apo_state_set SUBPHASE PREPARE_BASELINE_REBOOTING
    apo_state_save
    apo_event prepare-stock-reboot INFO '' 'Rebooting once to activate the backed-up stock baseline required by first-time preparation.'
    apo_remote_worker "$APO_REMOTE_WORKER" reboot-stock-reset "$APO_PERMANENT_CONFIG_HASH" >/dev/null 2>&1 || true
    if ! apo_post_reboot_handshake "$old_boot_id" "$APO_BOOT_TIMEOUT" prepare-stock-normalization; then
        if [[ ${APO_REBOOT_HANDSHAKE_STAGE:-wait} == worker ]]; then
            apo_prepare_baseline_fail RECOVERY_FAILURE "The stock-normalization reboot returned, but verification could not continue: $APO_LAST_REASON Backup: ${reset_backup:-unavailable}."
        fi
        apo_prepare_baseline_fail RECOVERY_FAILURE "The stock-normalization reboot did not return with a new boot ID within ${APO_BOOT_TIMEOUT}s. Backup: ${reset_backup:-unavailable}."
    fi
    new_boot_id=$APO_REBOOT_BOOT_ID
    apo_state_set PREPARE_BASELINE_NEW_BOOT_ID "$new_boot_id"
    apo_state_set LAST_BOOT_ID "$new_boot_id"
    apo_state_set NORMAL_BOOT_ID "$new_boot_id"
    apo_state_set PREPARE_BASELINE_STATUS VERIFYING
    apo_state_set SUBPHASE PREPARE_BASELINE_VERIFYING
    apo_state_save
    sleep "$APO_BOOT_SETTLE_SECONDS"

    if ! apo_run_worker_capture prepare-stock-verification verify-stock-reset "$APO_PERMANENT_CONFIG_HASH"; then
        apo_prepare_baseline_fail "${APO_LAST_CLASS:-RECOVERY_FAILURE}" "${APO_LAST_REASON:-Post-reboot stock verification failed.} Backup: ${reset_backup:-unavailable}."
    fi
    apo_reset_validate_verification "$APO_PERMANENT_CONFIG_HASH"
    apo_state_set PREPARE_BASELINE_STATUS VERIFIED
    apo_state_set SUBPHASE PREPARE_BASELINE_VERIFIED
    apo_state_save
    apo_event prepare-stock-normalization PASS '' "First-time permanent tuning controls were backed up, disabled, rebooted, and verified at stock settings. Backup: $reset_backup."
}

apo_reset_stock() {
    local probed_profile discovered_hash old_boot_id new_boot_id reset_backup fresh_history_note=''

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
    if (( ${APO_FRESH_TUNING_FORCE:-0} == 1 )); then
        apo_summary_line 'Fresh tuning history: destructive deletion requested'
    else
        apo_summary_line "Fresh tuning boundary: $([[ ${APO_FRESH_TUNING:-0} == 1 ]] && printf requested || printf unchanged)"
    fi
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
    if (( ${APO_FRESH_TUNING:-0} == 1 )); then
        apo_history_prepare_fresh_tuning_boundary ||
            apo_die "Fresh-tuning history preparation failed: ${APO_HISTORY_SCAN_ERROR:-invalid retained history}" "$APO_EXIT_PREFLIGHT"
    fi
    apo_reset_retire_prior_resumable_runs
    apo_reset_cleanup_owned_watchdog
    apo_reset_verify_watchdog_ready
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
    if ! apo_post_reboot_handshake "$old_boot_id" "$APO_BOOT_TIMEOUT" stock-reset; then
        if [[ ${APO_REBOOT_HANDSHAKE_STAGE:-wait} == worker ]]; then
            apo_die "Stock-reset reboot returned, but verification could not continue: $APO_LAST_REASON" "$APO_EXIT_RECOVERY"
        fi
        apo_die "Stock-reset reboot did not return with a new boot ID within ${APO_BOOT_TIMEOUT}s." "$APO_EXIT_RECOVERY"
    fi
    new_boot_id=$APO_REBOOT_BOOT_ID
    apo_state_set LAST_BOOT_ID "$new_boot_id"
    apo_state_set NORMAL_BOOT_ID "$new_boot_id"
    apo_state_set RESET_STATUS VERIFYING
    apo_state_set SUBPHASE VERIFYING_STOCK
    apo_state_save
    sleep "$APO_BOOT_SETTLE_SECONDS"

    if ! apo_run_worker_capture verify-stock-reset verify-stock-reset "$APO_PERMANENT_CONFIG_HASH"; then
        apo_reset_abort_worker
    fi
    apo_reset_validate_verification "$APO_PERMANENT_CONFIG_HASH"

    if (( ${APO_FRESH_TUNING:-0} == 1 )); then
        if (( ${APO_FRESH_TUNING_FORCE:-0} == 1 )); then
            apo_state_set RESET_STATUS DELETING_TUNING_HISTORY
            apo_state_set SUBPHASE DELETING_TUNING_HISTORY
        else
            apo_state_set RESET_STATUS RECORDING_FRESH_TUNING_BOUNDARY
            apo_state_set SUBPHASE RECORDING_FRESH_TUNING_BOUNDARY
        fi
        apo_state_save
        apo_history_commit_fresh_tuning_boundary ||
            apo_die 'Stock was verified, but the requested fresh-tuning history operation could not be committed safely.' "$APO_EXIT_INTERNAL"
        if (( ${APO_FRESH_TUNING_FORCE:-0} == 1 )); then
            apo_summary_line "Fresh tuning history: old ledger deleted at $APO_HISTORY_FRESH_CUTOFF_AT"
            apo_event reset-fresh-tuning-purge PASS '' 'The old history ledger was deleted after verified stock recovery. Earlier retained run states remain audit files but are excluded from future tuning by this reset cutoff.'
        else
            apo_summary_line "Fresh tuning boundary: $APO_HISTORY_FRESH_CUTOFF_AT, reset $APO_HISTORY_FRESH_CUTOFF_RUN_ID"
            apo_event reset-fresh-tuning PASS '' 'Earlier retained tuning evidence remains readable above the boundary but no longer constrains future tuning. New evidence below the boundary is authoritative.'
        fi
    fi

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
    if (( ${APO_FRESH_TUNING_FORCE:-0} == 1 )); then
        fresh_history_note=' The old history ledger was deleted and earlier run-state evidence is below the destructive cutoff.'
    elif (( ${APO_FRESH_TUNING:-0} == 1 )); then
        fresh_history_note=' Earlier tuning boundaries are audit-only for future searches.'
    fi
    apo_event reset PASS '' "Permanent clock/voltage overrides were disabled, rebooted, and verified at stock settings. Backup: $reset_backup. Prior logs and saved runs were preserved as audit evidence, but earlier tuning checkpoints are no longer resumable.${fresh_history_note}"
}
