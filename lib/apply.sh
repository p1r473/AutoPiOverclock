#!/usr/bin/env bash
# Explicit permanent application of a fully validated recommendation.

APO_APPLY_RECONCILE_RESULT=''

apo_apply_valid_hash() { [[ ${1-} =~ ^[0-9a-f]{64}$ ]]; }

apo_apply_backup_path() {
    local run_id=$1
    case ${APO_PROFILE:-} in
        debian) printf '/var/lib/autopioverclock/backups/config-%s-before-apply.txt' "$run_id" ;;
        batocera) printf '/userdata/system/autopioverclock/backups/config-%s-before-apply.txt' "$run_id" ;;
        *) return 1 ;;
    esac
}

apo_apply_hash_disposition() {
    local current_hash=$1 old_hash=$2 expected_hash=$3
    if [[ $current_hash == "$old_hash" ]]; then printf OLD
    elif [[ $current_hash == "$expected_hash" ]]; then printf EXPECTED
    else printf UNKNOWN
    fi
}

apo_current_permanent_hash() {
    local current_hash
    current_hash=$(apo_remote_root "sha256sum $(apo_sh_quote "$APO_BOOT_CONFIG")" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    apo_apply_valid_hash "$current_hash" || return 1
    printf '%s' "$current_hash"
}

apo_apply_assert_tryboot_clear() {
    local tryboot_flag tryboot_path_state
    if [[ $(apo_state_get RUN_SCHEMA '') != "$APO_CURRENT_RUN_SCHEMA" ]]; then
        APO_LAST_CLASS=APPLY_FAILURE
        APO_LAST_REASON='Permanent apply is refused for a run created before the current tryboot-ownership safety schema.'
        return 1
    fi
    if [[ $(apo_state_get TRYBOOT_EXPECTED 0) != 0 || $(apo_state_get TRYBOOT_FILE_MAY_EXIST 0) != 0 ||
          -n $(apo_state_get TRYBOOT_OWNED_HASH '') || -n $(apo_state_get TRYBOOT_RESERVATION_HASH '') ||
          -n $(apo_state_get TRYBOOT_OWNERSHIP_TOKEN '') || -n $(apo_state_get TRYBOOT_QUARANTINE_PATH '') ]]; then
        APO_LAST_CLASS=APPLY_FAILURE
        APO_LAST_REASON='Permanent apply is refused while saved state says tryboot may be active, staged, or quarantined.'
        return 1
    fi
    tryboot_flag=$(apo_remote_tryboot_flag || true)
    if [[ $tryboot_flag != 00000000 ]]; then
        APO_LAST_CLASS=APPLY_FAILURE
        APO_LAST_REASON="Permanent apply requires a verified normal boot; live tryboot state is ${tryboot_flag:-unreadable}."
        return 1
    fi
    if [[ -z ${APO_TRYBOOT_CONFIG:-} ]]; then
        APO_LAST_CLASS=APPLY_FAILURE
        APO_LAST_REASON='Permanent apply cannot verify the tryboot path because target discovery state is incomplete.'
        return 1
    fi
    tryboot_path_state=$(apo_remote_root "if [ -e $(apo_sh_quote "$APO_TRYBOOT_CONFIG") ] || [ -L $(apo_sh_quote "$APO_TRYBOOT_CONFIG") ]; then printf present; else printf absent; fi" 2>/dev/null || true)
    if [[ $tryboot_path_state != absent ]]; then
        APO_LAST_CLASS=APPLY_FAILURE
        APO_LAST_REASON='Permanent apply is refused while any tryboot path exists or its absence cannot be verified.'
        return 1
    fi
}

apo_apply_pause() {
    local failure_reason=$1
    apo_state_set APPLY_STATUS APPLYING
    apo_state_set APPLY_FAILURE_REASON "$failure_reason"
    apo_state_save
    apo_event apply-reconcile WARN APPLY_FAILURE "$failure_reason"
    APO_LAST_CLASS=APPLY_FAILURE
    APO_LAST_REASON=$failure_reason
    return 1
}

apo_apply_manual_recovery() {
    local failure_reason=$1
    apo_state_set APPLY_STATUS FAILED_NEEDS_MANUAL_RECOVERY
    apo_state_set APPLY_FAILURE_REASON "$failure_reason"
    apo_state_save
    apo_event apply-reconcile ERROR APPLY_FAILURE "$failure_reason"
    APO_LAST_CLASS=APPLY_FAILURE
    APO_LAST_REASON=$failure_reason
    return 1
}

apo_apply_force_normal_boot_and_health() {
    local expected_hash=$1 expected_cpu=$2 expected_gpu=$3 expected_voltage=$4 context=$5
    local old_boot_id new_boot_id tryboot_flag current_hash previous_hash
    if ! apo_wait_for_ssh "$APO_BOOT_TIMEOUT"; then
        APO_LAST_CLASS=APPLY_FAILURE
        APO_LAST_REASON="SSH did not become reachable before $context."
        return 1
    fi
    apo_apply_assert_tryboot_clear || return 1
    current_hash=$(apo_current_permanent_hash || true)
    if [[ $current_hash != "$expected_hash" ]]; then
        APO_LAST_CLASS=APPLY_FAILURE
        APO_LAST_REASON="Permanent config did not retain the expected hash before $context (${expected_hash} -> ${current_hash:-unavailable})."
        return 1
    fi
    old_boot_id=$(apo_remote_boot_id || true)
    if [[ -z $old_boot_id ]]; then
        APO_LAST_CLASS=APPLY_FAILURE
        APO_LAST_REASON="Could not read the boot ID before $context."
        return 1
    fi
    apo_state_set APPLY_BOOT_ID "$old_boot_id"
    apo_state_set LAST_BOOT_ID "$old_boot_id"
    apo_state_save
    apo_remote_worker "$APO_REMOTE_WORKER" reboot-normal >/dev/null 2>&1 || true
    if ! apo_post_reboot_handshake "$old_boot_id" "$APO_BOOT_TIMEOUT" "$context"; then
        APO_LAST_CLASS=APPLY_FAILURE
        if [[ ${APO_REBOOT_HANDSHAKE_STAGE:-wait} == worker ]]; then
            APO_LAST_REASON="The verification reboot returned before $context, but its transient worker could not be restored: $APO_LAST_REASON"
        else
            APO_LAST_REASON="The verification reboot did not return to SSH before $context."
        fi
        return 1
    fi
    new_boot_id=$APO_REBOOT_BOOT_ID
    tryboot_flag=$(apo_remote_tryboot_flag || true)
    if [[ $tryboot_flag != 00000000 ]]; then
        APO_LAST_CLASS=APPLY_FAILURE
        APO_LAST_REASON="The verification boot for $context did not prove normal boot state (${tryboot_flag:-missing})."
        return 1
    fi
    sleep "$APO_BOOT_SETTLE_SECONDS"
    current_hash=$(apo_current_permanent_hash || true)
    if [[ $current_hash != "$expected_hash" ]]; then
        APO_LAST_CLASS=APPLY_FAILURE
        APO_LAST_REASON="Permanent config did not retain the expected hash after $context (${expected_hash} -> ${current_hash:-unavailable})."
        return 1
    fi
    apo_state_set APPLY_BOOT_ID "$new_boot_id"
    apo_state_set NORMAL_BOOT_ID "$new_boot_id"
    apo_state_set LAST_BOOT_ID "$new_boot_id"
    apo_state_set TRYBOOT_EXPECTED 0
    apo_state_set CURRENT_CPU ''
    apo_state_set CURRENT_GPU ''
    apo_state_save
    previous_hash=$APO_PERMANENT_CONFIG_HASH
    APO_PERMANENT_CONFIG_HASH=$expected_hash
    if ! apo_health_check "$expected_cpu" "$expected_gpu" "$expected_voltage" "$context"; then
        APO_PERMANENT_CONFIG_HASH=$previous_hash
        return 1
    fi
    APO_PERMANENT_CONFIG_HASH=$previous_hash
    apo_apply_assert_tryboot_clear || return 1
}

apo_apply_mark_applied() {
    local expected_hash=$1 final_cpu=$2 final_gpu=$3 final_voltage=$4 backup_file=$5
    APO_PERMANENT_CONFIG_HASH=$expected_hash
    APO_NORMAL_CPU=$final_cpu
    APO_NORMAL_GPU=$final_gpu
    APO_NORMAL_VOLTAGE=$final_voltage
    apo_state_set NORMAL_CPU "$final_cpu"
    apo_state_set NORMAL_GPU "$final_gpu"
    apo_state_set NORMAL_VOLTAGE "$final_voltage"
    apo_state_set PERMANENT_HASH "$expected_hash"
    apo_state_set APPLY_STATUS APPLIED
    apo_state_set APPLY_RECOVERY_ACTION ''
    apo_state_set APPLY_FAILURE_REASON ''
    apo_state_set APPLIED_AT "$(apo_now_iso)"
    apo_state_save
    apo_summary_line "APPLIED: over_voltage_delta=$final_voltage, arm_freq=$final_cpu, $APO_GPU_KEY=$final_gpu"
    apo_event apply PASS '' "Validated clocks applied and verified after a normal reboot; backup=$backup_file"
    APO_APPLY_RECONCILE_RESULT=APPLIED
}

apo_apply_mark_old_verified() {
    local old_hash=$1 apply_status=$2 reason=$3
    APO_PERMANENT_CONFIG_HASH=$old_hash
    apo_state_set PERMANENT_HASH "$old_hash"
    apo_state_set APPLY_STATUS "$apply_status"
    apo_state_set APPLY_RECOVERY_ACTION ''
    apo_state_set APPLY_FAILURE_REASON "$reason"
    apo_state_save
    apo_event apply-reconcile PASS '' "$reason"
    APO_APPLY_RECONCILE_RESULT=$apply_status
}

apo_apply_verify_old_config() {
    local old_hash=$1 apply_status=$2 reason=$3
    if ! apo_apply_force_normal_boot_and_health "$old_hash" "$APO_NORMAL_CPU" "$APO_NORMAL_GPU" "$APO_NORMAL_VOLTAGE" apply-old-config-health; then
        apo_apply_pause "The saved pre-apply config could not be verified after a normal reboot: $APO_LAST_REASON"
        return 1
    fi
    apo_apply_mark_old_verified "$old_hash" "$apply_status" "$reason"
}

apo_apply_restore_old_config() {
    local old_hash=$1 backup_file=$2 failure_reason=$3 restored_hash expected_current_hash
    expected_current_hash=$(apo_state_get APPLY_EXPECTED_HASH '')
    if ! apo_apply_valid_hash "$expected_current_hash" || [[ $expected_current_hash == "$old_hash" ]]; then
        apo_apply_pause 'Rollback remains pending because the persisted expected current permanent-config hash is missing or invalid.'
        return 1
    fi
    apo_state_set APPLY_STATUS APPLYING
    apo_state_set APPLY_RECOVERY_ACTION ROLLBACK
    apo_state_set APPLY_FAILURE_REASON "$failure_reason"
    apo_state_save
    if ! apo_wait_for_ssh "$APO_BOOT_TIMEOUT"; then
        apo_apply_pause "Rollback remains pending because SSH is unavailable. Backup: $backup_file"
        return 1
    fi
    if ! apo_run_worker_capture apply-rollback restore-backup "$backup_file" "$old_hash" "$expected_current_hash"; then
        apo_apply_pause "Rollback remains pending because the verified backup could not be restored: $APO_LAST_REASON Backup: $backup_file"
        return 1
    fi
    apo_parse_data_file "$APO_LAST_WORKER_LOG" APO_WORKER_DATA
    restored_hash=${APO_WORKER_DATA[RESTORED_HASH]:-}
    if [[ $restored_hash != "$old_hash" ]]; then
        apo_apply_manual_recovery "Rollback worker reported an unexpected restored hash (${restored_hash:-missing}); expected $old_hash. Backup: $backup_file"
        return 1
    fi
    if ! apo_apply_force_normal_boot_and_health "$old_hash" "$APO_NORMAL_CPU" "$APO_NORMAL_GPU" "$APO_NORMAL_VOLTAGE" apply-rollback-health; then
        apo_apply_pause "The backup was restored, but its normal boot could not be verified: $APO_LAST_REASON Backup: $backup_file"
        return 1
    fi
    apo_apply_mark_old_verified "$old_hash" ROLLED_BACK "$failure_reason; the verified pre-apply config was restored."
    apo_summary_line "ROLLED BACK: validated permanent config was not retained; backup=$backup_file"
}

apo_apply_validate_expected_config() {
    local old_hash=$1 expected_hash=$2 backup_file=$3 final_cpu=$4 final_gpu=$5 final_voltage=$6 health_reason
    if apo_apply_force_normal_boot_and_health "$expected_hash" "$final_cpu" "$final_gpu" "$final_voltage" apply-post-reboot-health; then
        apo_apply_mark_applied "$expected_hash" "$final_cpu" "$final_gpu" "$final_voltage" "$backup_file"
        return 0
    fi
    health_reason=${APO_LAST_REASON:-'The applied config failed its post-reboot health gate.'}
    apo_warn 'Applied config did not pass the post-reboot gate. Attempting the persisted rollback plan.'
    apo_apply_restore_old_config "$old_hash" "$backup_file" "$health_reason"
}

apo_reconcile_interrupted_apply() {
    local old_hash expected_hash backup_file recovery_action deterministic_backup current_hash disposition
    local final_cpu final_gpu final_voltage
    APO_APPLY_RECONCILE_RESULT=''
    [[ $(apo_state_get APPLY_STATUS NOT_APPLIED) == APPLYING ]] || return 0
    old_hash=$(apo_state_get APPLY_OLD_HASH '')
    expected_hash=$(apo_state_get APPLY_EXPECTED_HASH '')
    backup_file=$(apo_state_get APPLY_BACKUP '')
    recovery_action=$(apo_state_get APPLY_RECOVERY_ACTION '')
    final_cpu=$(apo_state_get FINAL_CPU '')
    final_gpu=$(apo_state_get FINAL_GPU '')
    final_voltage=$(apo_state_get TEST_VOLTAGE '')
    deterministic_backup=$(apo_apply_backup_path "$APO_RUN_ID" || true)
    if ! apo_apply_valid_hash "$old_hash" || ! apo_apply_valid_hash "$expected_hash" || [[ $old_hash == "$expected_hash" ]] ||
        [[ -z $deterministic_backup || $backup_file != "$deterministic_backup" ]] ||
        [[ -z $final_cpu || -z $final_gpu || -z $final_voltage ]] ||
        [[ -n $recovery_action && $recovery_action != ROLLBACK ]]; then
        apo_apply_manual_recovery 'The interrupted apply plan is incomplete or inconsistent; automatic mutation is refused.'
        return 1
    fi
    if ! apo_wait_for_ssh "$APO_BOOT_TIMEOUT"; then
        apo_apply_pause 'Interrupted apply remains pending because SSH did not become reachable.'
        return 1
    fi
    if ! apo_apply_assert_tryboot_clear; then
        apo_apply_pause "Interrupted apply cannot be reconciled until tryboot is fully clear: $APO_LAST_REASON"
        return 1
    fi
    current_hash=$(apo_current_permanent_hash || true)
    if [[ -z $current_hash ]]; then
        apo_apply_pause 'Interrupted apply remains pending because the permanent config hash could not be read.'
        return 1
    fi
    disposition=$(apo_apply_hash_disposition "$current_hash" "$old_hash" "$expected_hash")
    case $disposition in
        OLD)
            if [[ $recovery_action == ROLLBACK ]]; then
                apo_apply_verify_old_config "$old_hash" ROLLED_BACK 'The interrupted apply rollback was completed and the pre-apply config was verified.'
            else
                apo_apply_verify_old_config "$old_hash" INTERRUPTED_NO_CHANGE 'The interrupted apply had not changed permanent config; the pre-apply config was verified.'
            fi
            ;;
        EXPECTED)
            if [[ $recovery_action == ROLLBACK ]]; then
                apo_apply_restore_old_config "$old_hash" "$backup_file" 'Resuming the persisted rollback requested after apply validation failed.'
            else
                apo_apply_validate_expected_config "$old_hash" "$expected_hash" "$backup_file" "$final_cpu" "$final_gpu" "$final_voltage"
            fi
            ;;
        UNKNOWN)
            apo_apply_manual_recovery "Permanent config hash $current_hash matches neither the saved pre-apply hash $old_hash nor the proposed hash $expected_hash. Refusing to overwrite an unknown config. Backup: $backup_file"
            return 1
            ;;
    esac
}

apo_apply_recommendation() {
    local validated validation_schema final_duration expected_duration edge_status final_cpu final_gpu original_hash expected_hash proposed_file current_file diff_file remote_proposed
    local expected_confirmation old_boot_id backup_file apply_log reported_backup reported_hash diff_rc apply_failure
    apo_apply_assert_tryboot_clear || apo_die "$APO_LAST_REASON" "$APO_EXIT_APPLY"
    validated=$(apo_state_get VALIDATED 0)
    validation_schema=$(apo_state_get VALIDATION_SCHEMA '')
    [[ $validated == 1 && $validation_schema == "$APO_CURRENT_VALIDATION_SCHEMA" &&
       $(apo_state_get STATUS '') == PASS && $(apo_state_get PHASE '') == COMPLETE ]] ||
        apo_die 'Only a fully validated run produced by the current safety gates can be applied.' "$APO_EXIT_APPLY"
    final_duration=$(apo_state_get VALIDATION_DURATION_S 0)
    apo_validate_uint_range "$final_duration" "$APO_MIN_TUNING_DURATION_S" "$APO_MAX_TUNING_DURATION_S" ||
        apo_die 'Permanent apply requires completed final-endurance evidence for the saved duration plan.' "$APO_EXIT_APPLY"
    edge_status=$(apo_state_get EDGE_CPU_STATUS NOT_REQUESTED)
    case $edge_status in
        PASS) expected_duration=$(apo_state_get CFG_EDGE_DURATION_S "$APO_DEFAULT_EDGE_DURATION_S") ;;
        REJECTED|SKIPPED_KNOWN_BOUNDARY) expected_duration=$(apo_state_get FLOOR_DURATION_S '') ;;
        NOT_REQUESTED) expected_duration=$(apo_state_get CFG_FINAL_DURATION_S "$APO_DEFAULT_FINAL_DURATION_S") ;;
        *) apo_die 'Permanent apply found an incomplete or malformed edge-test disposition.' "$APO_EXIT_APPLY" ;;
    esac
    [[ $final_duration == "$expected_duration" ]] ||
        apo_die 'Permanent apply duration evidence does not match the immutable saved qualification/final/edge plan.' "$APO_EXIT_APPLY"
    case $(apo_state_get APPLY_STATUS NOT_APPLIED) in
        APPLIED) apo_info 'This run is already applied.'; return 0 ;;
        APPLYING)
            if ! apo_reconcile_interrupted_apply; then apo_die "$APO_LAST_REASON" "$APO_EXIT_APPLY"; fi
            [[ $(apo_state_get APPLY_STATUS) == APPLIED ]] && return 0
            apo_die 'The interrupted apply was returned to its verified pre-apply config. Run apply again to review the diff and reconfirm.' "$APO_EXIT_APPLY"
            ;;
        FAILED_NEEDS_MANUAL_RECOVERY)
            apo_die "This run has an unresolved permanent-config mismatch: $(apo_state_get APPLY_FAILURE_REASON 'manual recovery required')" "$APO_EXIT_APPLY"
            ;;
    esac
    final_cpu=$(apo_state_get FINAL_CPU)
    final_gpu=$(apo_state_get FINAL_GPU)
    [[ -n $final_cpu && -n $final_gpu ]] || apo_die 'Validated state lacks final clock values.' "$APO_EXIT_APPLY"
    original_hash=$APO_PERMANENT_CONFIG_HASH
    apo_verify_permanent_hash apply-preflight || apo_die "$APO_LAST_REASON" "$APO_EXIT_APPLY"

    proposed_file="${APO_RUN_PREFIX}-apply-proposed-config.txt"
    current_file="${APO_RUN_PREFIX}-apply-current-config.txt"
    diff_file="${APO_RUN_PREFIX}-apply.diff"
    apo_remote_root "cat $(apo_sh_quote "$APO_BOOT_CONFIG")" > "$current_file"
    apo_remote_worker "$APO_REMOTE_WORKER" render-permanent "$final_cpu" "$final_gpu" "$APO_GPU_KEY" "$APO_TEST_VOLTAGE" "$APO_RUN_ID" > "$proposed_file"
    [[ -s $proposed_file ]] || apo_die 'The proposed permanent config rendered empty.' "$APO_EXIT_APPLY"
    expected_hash=$(sha256sum "$proposed_file" | awk 'NR == 1 {print $1}')
    apo_apply_valid_hash "$expected_hash" || apo_die 'Could not calculate the proposed permanent-config hash.' "$APO_EXIT_APPLY"
    set +e
    diff -u --label current-config.txt --label proposed-config.txt "$current_file" "$proposed_file" > "$diff_file"
    diff_rc=$?
    set -e
    if (( diff_rc == 0 )); then
        apo_info 'Permanent config already matches the validated recommendation; proving a fresh normal boot before recording it as applied.'
        if ! apo_apply_force_normal_boot_and_health "$expected_hash" "$final_cpu" "$final_gpu" "$APO_TEST_VOLTAGE" apply-existing-config-health; then
            apo_state_set APPLY_STATUS FAILED_HEALTH
            apo_state_set APPLY_FAILURE_REASON "$APO_LAST_REASON"
            apo_state_save
            apo_die "Matching permanent config did not pass a fresh normal-boot health gate: $APO_LAST_REASON" "$APO_EXIT_APPLY"
        fi
        apo_state_set APPLY_OLD_HASH "$original_hash"
        apo_state_set APPLY_EXPECTED_HASH "$expected_hash"
        apo_state_set APPLY_BACKUP ''
        apo_apply_mark_applied "$expected_hash" "$final_cpu" "$final_gpu" "$APO_TEST_VOLTAGE" 'not-needed'
        apo_summary_line "APPLIED/VERIFIED: permanent config already matched over_voltage_delta=$APO_TEST_VOLTAGE, arm_freq=$final_cpu, $APO_GPU_KEY=$final_gpu"
        return 0
    elif (( diff_rc != 1 )); then
        apo_die 'Could not generate the permanent-config diff.' "$APO_EXIT_APPLY"
    fi
    [[ $expected_hash != "$original_hash" ]] || apo_die 'The proposed config differs byte-for-byte but has the protected hash; refusing an inconsistent apply.' "$APO_EXIT_APPLY"
    printf '\n===== EXACT PERMANENT CONFIG DIFF =====\n' >&2
    cat "$diff_file" >&2
    printf '=======================================\n\n' >&2
    expected_confirmation="APPLY ${APO_TARGET_SLUG} ${APO_RUN_ID}"
    if (( ${APO_AUTO_APPLY:-0} == 1 )); then
        apo_info 'The explicit overclock command authorizes this displayed, fully validated permanent result; applying it now.'
    else
        apo_confirm_exact 'Applying writes the displayed validated clocks to permanent config and reboots the target. --yes never bypasses this confirmation.' "$expected_confirmation" || apo_die 'Permanent application was not confirmed.' "$APO_EXIT_APPLY"
    fi
    apo_apply_assert_tryboot_clear || apo_die "Tryboot state changed while the apply confirmation was pending: $APO_LAST_REASON" "$APO_EXIT_APPLY"

    backup_file=$(apo_apply_backup_path "$APO_RUN_ID" || true)
    [[ -n $backup_file ]] || apo_die "No deterministic apply backup path exists for profile $APO_PROFILE." "$APO_EXIT_APPLY"
    old_boot_id=$(apo_remote_boot_id || true)
    [[ -n $old_boot_id ]] || apo_die 'Could not read boot ID before apply.' "$APO_EXIT_APPLY"
    apo_state_set APPLY_OLD_HASH "$original_hash"
    apo_state_set APPLY_EXPECTED_HASH "$expected_hash"
    apo_state_set APPLY_BACKUP "$backup_file"
    apo_state_set APPLY_BOOT_ID "$old_boot_id"
    apo_state_set APPLY_RECOVERY_ACTION ''
    apo_state_set APPLY_FAILURE_REASON ''
    apo_state_set APPLY_STATUS APPLYING
    apo_state_save

    remote_proposed="${APO_REMOTE_WORK_DIR}/proposed-${APO_RUN_ID}.txt"
    apo_remote_upload_root "$proposed_file" "$remote_proposed"
    if ! apo_run_worker_capture apply-permanent apply-permanent "$remote_proposed" "$original_hash" "$expected_hash" "$APO_RUN_ID"; then
        apply_failure=${APO_LAST_REASON:-'The permanent-config worker failed.'}
        apo_state_set APPLY_RECOVERY_ACTION ROLLBACK
        apo_state_set APPLY_FAILURE_REASON "$apply_failure"
        apo_state_save
        apo_reconcile_interrupted_apply || true
        apo_die "Permanent apply failed: $apply_failure; reconciliation status: $(apo_state_get APPLY_STATUS APPLYING)." "$APO_EXIT_APPLY"
    fi
    apply_log=$APO_LAST_WORKER_LOG
    apo_parse_data_file "$apply_log" APO_WORKER_DATA
    reported_backup=${APO_WORKER_DATA[BACKUP_FILE]:-}
    reported_hash=${APO_WORKER_DATA[NEW_HASH]:-}
    if [[ $reported_backup != "$backup_file" || $reported_hash != "$expected_hash" ]]; then
        apo_state_set APPLY_RECOVERY_ACTION ROLLBACK
        apo_state_set APPLY_FAILURE_REASON 'Apply worker returned metadata that did not match the persisted apply plan.'
        apo_state_save
        apo_reconcile_interrupted_apply || true
        apo_die "Apply worker metadata did not match the persisted plan; reconciliation status: $(apo_state_get APPLY_STATUS APPLYING)." "$APO_EXIT_APPLY"
    fi
    if ! apo_reconcile_interrupted_apply; then apo_die "$APO_LAST_REASON" "$APO_EXIT_APPLY"; fi
    [[ $(apo_state_get APPLY_STATUS) == APPLIED ]] || apo_die "Applied config was not retained; reconciliation status: $(apo_state_get APPLY_STATUS)." "$APO_EXIT_APPLY"
}
