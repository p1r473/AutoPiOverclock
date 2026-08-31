#!/usr/bin/env bash
# Candidate sweep, conservative selection, final endurance validation, and resume phases.

apo_gpu_harness_smoke() {
    local smoke_duration=20 failure_class failure_reason force_normal_reboot=0
    apo_state_phase GPU_SMOKE NORMAL_BASELINE RUNNING
    apo_event gpu-smoke INFO '' "Running a ${smoke_duration}s GPU harness smoke test at normal clocks before any GPU candidate or endurance run."
    if ! apo_run_stress gpu "$smoke_duration" gpu-harness-smoke 0; then
        failure_class=$APO_LAST_CLASS
        failure_reason=$APO_LAST_REASON
        if [[ ${APO_PROFILE:-} == batocera && ${APO_MODE_EFFECTIVE:-} == graphical && $failure_class == RECOVERY_FAILURE ]]; then
            force_normal_reboot=1
        fi
        apo_record_failure_after_recovery gpu-smoke-recovery-health "$failure_class" "$failure_reason" "$force_normal_reboot"
        return 1
    fi
    apo_health_check "$APO_NORMAL_CPU" "$APO_NORMAL_GPU" "$APO_NORMAL_VOLTAGE" gpu-smoke-post-health || { apo_state_fail "$APO_LAST_CLASS" "$APO_LAST_REASON"; return 1; }
}

apo_candidate_checkpoint() {
    local label=$1 cpu_mhz=$2 gpu_mhz=$3 stage=$4
    apo_state_set CANDIDATE_LABEL "$label"
    apo_state_set CANDIDATE_CPU "$cpu_mhz"
    apo_state_set CANDIDATE_GPU "$gpu_mhz"
    apo_state_set CANDIDATE_STAGE "$stage"
    apo_state_set SUBPHASE "${label}:${stage}"
    apo_state_set STATUS RUNNING
    apo_state_save
}

apo_candidate_identity_matches() {
    [[ $(apo_state_get CANDIDATE_LABEL '') == "$1" &&
       $(apo_state_get CANDIDATE_CPU '') == "$2" &&
       $(apo_state_get CANDIDATE_GPU '') == "$3" ]]
}

apo_candidate_tryboot_active_in_state() {
    [[ $(apo_state_get TRYBOOT_EXPECTED 0) == 1 &&
       $(apo_state_get CURRENT_CPU '') == "$1" &&
       $(apo_state_get CURRENT_GPU '') == "$2" ]]
}

apo_candidate_boot_or_preserve_failure() {
    local cpu_mhz=$1 gpu_mhz=$2 boot_context=$3 recovery_context=$4 failure_class failure_reason
    if apo_boot_candidate "$cpu_mhz" "$gpu_mhz" "$boot_context"; then return 0; fi
    failure_class=$APO_LAST_CLASS
    failure_reason=$APO_LAST_REASON
    apo_recover_preserving_failure "$recovery_context" "$failure_class" "$failure_reason" || return 1
    return 1
}

apo_test_candidate() {
    local cpu_mhz=$1 gpu_mhz=$2 label=$3 stress_kind=$4 stress_duration=${5:-${APO_CFG[CANDIDATE_DURATION_S]}} stage failure_class failure_reason boot_number normal_number
    local candidate_boots=${APO_CFG[CANDIDATE_BOOTS]} stress_result_structured
    if ! apo_candidate_identity_matches "$label" "$cpu_mhz" "$gpu_mhz"; then
        apo_candidate_checkpoint "$label" "$cpu_mhz" "$gpu_mhz" BOOT_1
        apo_event "$label" INFO '' "Testing CPU=$cpu_mhz GPU=$gpu_mhz"
    fi
    while :; do
        stage=$(apo_state_get CANDIDATE_STAGE BOOT_1)
        case $stage in
            BOOT_*)
                if [[ ! $stage =~ ^BOOT_([1-9][0-9]*)$ ]]; then
                    APO_LAST_CLASS=HARNESS_FAILURE
                    APO_LAST_REASON="Malformed saved candidate boot stage for $label: $stage"
                    return 1
                fi
                boot_number=$((10#${BASH_REMATCH[1]}))
                if (( boot_number > candidate_boots )); then
                    APO_LAST_CLASS=HARNESS_FAILURE
                    APO_LAST_REASON="Saved candidate boot $boot_number exceeds configured candidate_boots=$candidate_boots for $label."
                    return 1
                fi
                apo_candidate_checkpoint "$label" "$cpu_mhz" "$gpu_mhz" "BOOT_${boot_number}"
                apo_candidate_boot_or_preserve_failure "$cpu_mhz" "$gpu_mhz" "${label}-boot-${boot_number}" "${label}-boot-${boot_number}-recovery" || return 1
                apo_candidate_checkpoint "$label" "$cpu_mhz" "$gpu_mhz" "NORMAL_${boot_number}"
                ;;
            NORMAL_*)
                if [[ ! $stage =~ ^NORMAL_([1-9][0-9]*)$ ]]; then
                    APO_LAST_CLASS=HARNESS_FAILURE
                    APO_LAST_REASON="Malformed saved candidate normal stage for $label: $stage"
                    return 1
                fi
                normal_number=$((10#${BASH_REMATCH[1]}))
                if (( normal_number > candidate_boots )); then
                    APO_LAST_CLASS=HARNESS_FAILURE
                    APO_LAST_REASON="Saved candidate normal recovery $normal_number exceeds configured candidate_boots=$candidate_boots for $label."
                    return 1
                fi
                apo_return_normal "${label}-normal-${normal_number}" || return 1
                if (( normal_number < candidate_boots )); then
                    apo_candidate_checkpoint "$label" "$cpu_mhz" "$gpu_mhz" "BOOT_$((normal_number + 1))"
                else
                    apo_candidate_checkpoint "$label" "$cpu_mhz" "$gpu_mhz" STRESS_BOOT
                fi
                ;;
            STRESS_BOOT)
                apo_candidate_boot_or_preserve_failure "$cpu_mhz" "$gpu_mhz" "${label}-stress-boot" "${label}-stress-boot-recovery" || return 1
                apo_candidate_checkpoint "$label" "$cpu_mhz" "$gpu_mhz" STRESS
                ;;
            STRESS)
                if ! apo_candidate_tryboot_active_in_state "$cpu_mhz" "$gpu_mhz"; then
                    apo_candidate_boot_or_preserve_failure "$cpu_mhz" "$gpu_mhz" "${label}-stress-resume-boot" "${label}-stress-resume-recovery" || return 1
                fi
                APO_LAST_RESULT_STRUCTURED=0
                if ! apo_run_stress "$stress_kind" "$stress_duration" "${label}-candidate" 0; then
                    failure_class=$APO_LAST_CLASS
                    failure_reason=$APO_LAST_REASON
                    stress_result_structured=${APO_LAST_RESULT_STRUCTURED:-0}
                    apo_recover_stress_failure "${label}-stress-recovery" "$failure_class" "$failure_reason" "$stress_result_structured" candidate || return 1
                    return 1
                fi
                apo_candidate_checkpoint "$label" "$cpu_mhz" "$gpu_mhz" POST_STRESS_HEALTH
                ;;
            POST_STRESS_HEALTH)
                if ! apo_candidate_tryboot_active_in_state "$cpu_mhz" "$gpu_mhz"; then
                    # The controller recovered a tryboot after interruption. The
                    # same-boot post-stress gate can only be preserved by safely
                    # repeating this candidate's stress subphase.
                    apo_candidate_checkpoint "$label" "$cpu_mhz" "$gpu_mhz" STRESS_BOOT
                    continue
                fi
                if ! apo_health_check "$cpu_mhz" "$gpu_mhz" "$APO_TEST_VOLTAGE" "${label}-post-stress"; then
                    failure_class=$APO_LAST_CLASS
                    failure_reason=$APO_LAST_REASON
                    apo_recover_preserving_failure "${label}-post-stress-recovery" "$failure_class" "$failure_reason" || return 1
                    return 1
                fi
                apo_candidate_checkpoint "$label" "$cpu_mhz" "$gpu_mhz" FINAL_NORMAL
                ;;
            FINAL_NORMAL)
                apo_return_normal "${label}-final-normal" || return 1
                apo_candidate_checkpoint "$label" "$cpu_mhz" "$gpu_mhz" COMPLETE
                ;;
            COMPLETE)
                APO_LAST_CLASS=PASS
                APO_LAST_REASON="Candidate passed ${candidate_boots} configured boot/normal cycles, ${stress_duration}s stress, post-stress health, and final normal recovery."
                apo_event "$label" PASS '' "$APO_LAST_REASON"
                return 0
                ;;
            *)
                APO_LAST_CLASS=HARNESS_FAILURE
                APO_LAST_REASON="Unknown saved candidate stage for $label: $stage"
                return 1
                ;;
        esac
    done
}

apo_csv_contains_clock() {
    local csv_value=$1 clock_mhz=$2
    [[ ",$csv_value," == *",$clock_mhz,"* ]]
}

APO_AUTO_VALIDATION_REASON=''

apo_auto_state_invalid() {
    local reason=$1
    APO_LAST_CLASS=HARNESS_FAILURE
    APO_LAST_REASON=$reason
    if (( ${APO_STATE_VALIDATION_READ_ONLY:-0} == 1 )); then
        return 1
    fi
    apo_state_clear_final_validation
    apo_state_fail HARNESS_FAILURE "$reason"
    return 1
}

apo_run_manual_test() {
    local label="manual-cpu-${APO_MANUAL_CPU}_gpu-${APO_MANUAL_GPU}"
    apo_state_phase MANUAL_TEST "$label" RUNNING
    apo_state_set MANUAL_TEST_STATUS RUNNING
    apo_state_set MANUAL_CPU "$APO_MANUAL_CPU"
    apo_state_set MANUAL_GPU "$APO_MANUAL_GPU"
    apo_state_set MANUAL_MINUTES "$APO_MANUAL_MINUTES"
    apo_state_set MANUAL_DURATION_S "$APO_MANUAL_DURATION_S"
    apo_state_save
    apo_event manual-test INFO '' "Testing exact clocks CPU=$APO_MANUAL_CPU GPU=$APO_MANUAL_GPU for $APO_MANUAL_MINUTES timed stress minutes; normal recovery and configured boot cycles remain mandatory."
    if ! apo_test_candidate "$APO_MANUAL_CPU" "$APO_MANUAL_GPU" "$label" combined; then
        apo_state_set MANUAL_TEST_STATUS FAILED
        apo_state_save
        apo_state_fail "${APO_LAST_CLASS:-HARNESS_FAILURE}" "${APO_LAST_REASON:-The manual stability test failed without a classified result.}"
        return 1
    fi
    apo_state_set MANUAL_TEST_STATUS PASS
    apo_state_set STATUS PASS
    apo_state_set PHASE COMPLETE
    apo_state_set SUBPHASE MANUAL_TEST_PASSED
    apo_state_set VALIDATED 0
    apo_state_set VALIDATION_SCHEMA ''
    apo_state_set VALIDATION_DURATION_S ''
    apo_state_set APPLY_STATUS NOT_APPLIED
    apo_state_save
    apo_summary_line 'MANUAL STABILITY TEST: PASS'
    apo_summary_line "Exact tested clocks: CPU $APO_MANUAL_CPU MHz / GPU $APO_MANUAL_GPU MHz"
    apo_summary_line "Timed combined stress: $APO_MANUAL_MINUTES minutes ($APO_MANUAL_DURATION_S seconds)"
    apo_summary_line "Maximum observed temperature: $(apo_state_get RUN_MAX_TEMP unknown)C"
    apo_summary_line 'Permanent config was not modified. This short/manual result is not a validated recommendation and cannot be applied.'
    apo_event manual-test PASS '' "CPU=$APO_MANUAL_CPU GPU=$APO_MANUAL_GPU passed $APO_MANUAL_MINUTES timed stress minutes, post-stress health, configured tryboot/normal cycles, and final normal recovery; permanent config remained unchanged."
}

apo_post_floor_edge_source_is_eligible() {
    local run_id final_cpu final_gpu permanent_hash mode run_schema source_final source_qualification source_edge source_policy expected_policy
    run_id=$(apo_state_get RUN_ID '')
    final_cpu=$(apo_state_get FINAL_CPU '')
    final_gpu=$(apo_state_get FINAL_GPU '')
    permanent_hash=$(apo_state_get PERMANENT_HASH '')
    mode=$(apo_state_get MODE_EFFECTIVE '')
    run_schema=$(apo_state_get RUN_SCHEMA '')
    source_final=$(apo_state_get CFG_FINAL_DURATION_S "$APO_DEFAULT_FINAL_DURATION_S")
    source_qualification=$(apo_state_get CFG_QUALIFICATION_DURATION_S "$APO_DEFAULT_QUALIFICATION_DURATION_S")
    source_edge=$(apo_state_get CFG_EDGE_DURATION_S "$APO_DEFAULT_EDGE_DURATION_S")
    expected_policy=$(apo_config_duration_policy "$source_qualification" "$source_final" "$source_edge")
    source_policy=$(apo_state_get CFG_DURATION_POLICY "$expected_policy")
    apo_is_safe_run_id "$run_id" || return 1
    if [[ $run_schema == "$APO_CURRENT_RUN_SCHEMA" ]]; then
        [[ -v APO_STATE[CFG_QUALIFICATION_DURATION_S] && -v APO_STATE[CFG_FINAL_DURATION_S] &&
           -v APO_STATE[CFG_EDGE_DURATION_S] && -v APO_STATE[CFG_DURATION_POLICY] ]] || return 1
    fi
    apo_validate_uint_range "$source_qualification" "$APO_MIN_TUNING_DURATION_S" "$APO_MAX_TUNING_DURATION_S" || return 1
    apo_validate_uint_range "$source_final" "$APO_MIN_TUNING_DURATION_S" "$APO_MAX_TUNING_DURATION_S" || return 1
    apo_validate_uint_range "$source_edge" "$APO_MIN_TUNING_DURATION_S" "$APO_MAX_TUNING_DURATION_S" || return 1
    apo_config_saved_duration_policy_matches "$source_qualification" "$source_final" "$source_edge" "$source_policy" || return 1
    [[ $(apo_state_get FORMAT_VERSION '') == 1 &&
       ( $run_schema == "$APO_CURRENT_RUN_SCHEMA" || $run_schema == 9 ) &&
       $(apo_state_get ORIGIN_COMMAND '') == overclock &&
       $(apo_state_get READ_ONLY_RUN 0) == 0 &&
       $(apo_state_get CFG_AUTO_GENERATED_CANDIDATES 0) == 1 &&
       $(apo_state_get CFG_EDGE_CPU_24H 0) == 0 &&
       $(apo_state_get STATUS '') == PASS &&
       $(apo_state_get PHASE '') == COMPLETE &&
       $(apo_state_get FINAL_STAGE '') == COMPLETE &&
       $(apo_state_get VALIDATED 0) == 1 &&
       $(apo_state_get VALIDATION_SCHEMA '') == "$APO_CURRENT_VALIDATION_SCHEMA" &&
       $(apo_state_get VALIDATION_DURATION_S '') == "$source_final" &&
       $(apo_state_get APPLY_STATUS '') == APPLIED &&
       $(apo_state_get EDGE_CPU_STATUS NOT_REQUESTED) == NOT_REQUESTED &&
       $(apo_state_get FLOOR_VALIDATED 0) == 0 &&
       $(apo_state_get POST_FLOOR_EDGE 0) == 0 &&
       $(apo_state_get TRYBOOT_EXPECTED 0) == 0 &&
       $(apo_state_get TRYBOOT_FILE_MAY_EXIST 0) == 0 &&
       -z $(apo_state_get TRYBOOT_OWNED_HASH '') &&
       -z $(apo_state_get TRYBOOT_RESERVATION_HASH '') &&
       -z $(apo_state_get TRYBOOT_OWNERSHIP_TOKEN '') &&
       -z $(apo_state_get TRYBOOT_QUARANTINE_PATH '') &&
       ( $mode == graphical || $mode == headless ) ]] || return 1
    [[ $final_cpu =~ ^[0-9]+$ && $final_gpu =~ ^[0-9]+$ &&
       $(apo_state_get RECOMMENDED_CPU '') == "$final_cpu" &&
       $(apo_state_get RECOMMENDED_GPU '') == "$final_gpu" &&
       $(apo_state_get FINAL_TARGET_CPU '') == "$final_cpu" &&
       $(apo_state_get FINAL_TARGET_GPU '') == "$final_gpu" &&
       $(apo_state_get NORMAL_CPU '') == "$final_cpu" &&
       $(apo_state_get NORMAL_GPU '') == "$final_gpu" &&
       $permanent_hash =~ ^[0-9a-f]{64}$ ]]
}

apo_post_floor_final_source_is_eligible() {
    local run_id run_schema profile final_cpu final_gpu normal_voltage test_voltage permanent_hash
    local source_final source_qualification source_edge source_policy expected_policy validation_duration expected_validation
    local edge_status floor_cpu floor_gpu floor_duration floor_validated old_hash expected_hash backup expected_backup
    run_id=$(apo_state_get RUN_ID '')
    run_schema=$(apo_state_get RUN_SCHEMA '')
    profile=$(apo_state_get PROFILE '')
    final_cpu=$(apo_state_get FINAL_CPU '')
    final_gpu=$(apo_state_get FINAL_GPU '')
    normal_voltage=$(apo_state_get NORMAL_VOLTAGE '')
    test_voltage=$(apo_state_get TEST_VOLTAGE '')
    permanent_hash=$(apo_state_get PERMANENT_HASH '')
    source_final=$(apo_state_get CFG_FINAL_DURATION_S "$APO_DEFAULT_FINAL_DURATION_S")
    source_qualification=$(apo_state_get CFG_QUALIFICATION_DURATION_S "$APO_DEFAULT_QUALIFICATION_DURATION_S")
    source_edge=$(apo_state_get CFG_EDGE_DURATION_S "$APO_DEFAULT_EDGE_DURATION_S")
    expected_policy=$(apo_config_duration_policy "$source_qualification" "$source_final" "$source_edge")
    source_policy=$(apo_state_get CFG_DURATION_POLICY "$expected_policy")
    validation_duration=$(apo_state_get VALIDATION_DURATION_S '')
    edge_status=$(apo_state_get EDGE_CPU_STATUS NOT_REQUESTED)
    floor_cpu=$(apo_state_get FLOOR_CPU '')
    floor_gpu=$(apo_state_get FLOOR_GPU '')
    floor_duration=$(apo_state_get FLOOR_DURATION_S '')
    floor_validated=$(apo_state_get FLOOR_VALIDATED 0)
    old_hash=$(apo_state_get APPLY_OLD_HASH '')
    expected_hash=$(apo_state_get APPLY_EXPECTED_HASH '')
    backup=$(apo_state_get APPLY_BACKUP '')

    apo_is_safe_run_id "$run_id" || return 1
    [[ $run_schema == "$APO_CURRENT_RUN_SCHEMA" &&
       -v APO_STATE[CFG_QUALIFICATION_DURATION_S] && -v APO_STATE[CFG_FINAL_DURATION_S] &&
       -v APO_STATE[CFG_EDGE_DURATION_S] && -v APO_STATE[CFG_DURATION_POLICY] ]] || return 1
    apo_validate_uint_range "$source_qualification" "$APO_MIN_TUNING_DURATION_S" "$APO_MAX_TUNING_DURATION_S" || return 1
    apo_validate_uint_range "$source_final" "$APO_MIN_TUNING_DURATION_S" "$APO_MAX_TUNING_DURATION_S" || return 1
    apo_validate_uint_range "$source_edge" "$APO_MIN_TUNING_DURATION_S" "$APO_MAX_TUNING_DURATION_S" || return 1
    apo_config_saved_duration_policy_matches "$source_qualification" "$source_final" "$source_edge" "$source_policy" || return 1

    case $edge_status in
        NOT_REQUESTED)
            [[ $floor_validated == 0 ]] || return 1
            expected_validation=$source_final
            ;;
        REJECTED|SKIPPED_KNOWN_BOUNDARY)
            [[ $floor_validated == 1 && $floor_cpu == "$final_cpu" && $floor_gpu == "$final_gpu" &&
               $floor_duration == "$source_final" ]] || return 1
            expected_validation=$source_final
            ;;
        PASS)
            if [[ $(apo_state_get CFG_EDGE_ORDER floor-first) == edge-first ]]; then
                [[ $floor_validated == 0 && -z $floor_duration ]] || return 1
            else
                [[ $floor_validated == 1 ]] || return 1
            fi
            expected_validation=$source_edge
            ;;
        *) return 1 ;;
    esac
    [[ $validation_duration == "$expected_validation" ]] || return 1

    case $profile in
        debian) expected_backup="/var/lib/autopioverclock/backups/config-${run_id}-before-apply.txt" ;;
        batocera) expected_backup="/userdata/system/autopioverclock/backups/config-${run_id}-before-apply.txt" ;;
        *) return 1 ;;
    esac
    [[ $backup == "$expected_backup" && $old_hash =~ ^[0-9a-f]{64}$ &&
       $expected_hash =~ ^[0-9a-f]{64}$ && $old_hash != "$expected_hash" &&
       $expected_hash == "$permanent_hash" ]] || return 1

    [[ $(apo_state_get FORMAT_VERSION '') == 1 &&
       $(apo_state_get ORIGIN_COMMAND '') == overclock &&
       $(apo_state_get READ_ONLY_RUN 0) == 0 &&
       $(apo_state_get CFG_AUTO_GENERATED_CANDIDATES 0) == 1 &&
       $(apo_state_get STATUS '') == PASS &&
       $(apo_state_get PHASE '') == COMPLETE &&
       $(apo_state_get FINAL_STAGE '') == COMPLETE &&
       $(apo_state_get VALIDATED 0) == 1 &&
       $(apo_state_get VALIDATION_SCHEMA '') == "$APO_CURRENT_VALIDATION_SCHEMA" &&
       $(apo_state_get APPLY_STATUS '') == APPLIED &&
       $(apo_state_get TRYBOOT_EXPECTED 0) == 0 &&
       $(apo_state_get TRYBOOT_FILE_MAY_EXIST 0) == 0 &&
       -z $(apo_state_get TRYBOOT_OWNED_HASH '') &&
       -z $(apo_state_get TRYBOOT_RESERVATION_HASH '') &&
       -z $(apo_state_get TRYBOOT_OWNERSHIP_TOKEN '') &&
       -z $(apo_state_get TRYBOOT_QUARANTINE_PATH '') &&
       ( $(apo_state_get MODE_EFFECTIVE '') == graphical || $(apo_state_get MODE_EFFECTIVE '') == headless ) &&
       $final_cpu =~ ^[0-9]+$ && $final_gpu =~ ^[0-9]+$ &&
       $(apo_state_get RECOMMENDED_CPU '') == "$final_cpu" &&
       $(apo_state_get RECOMMENDED_GPU '') == "$final_gpu" &&
       $(apo_state_get FINAL_TARGET_CPU '') == "$final_cpu" &&
       $(apo_state_get FINAL_TARGET_GPU '') == "$final_gpu" &&
       $(apo_state_get NORMAL_CPU '') == "$final_cpu" &&
       $(apo_state_get NORMAL_GPU '') == "$final_gpu" &&
       $normal_voltage == "$test_voltage" &&
       $permanent_hash =~ ^[0-9a-f]{64}$ ]]
}

apo_auto_uint_in_range() {
    local value=$1 minimum=$2 maximum=$3
    [[ $value =~ ^[0-9]{1,7}$ ]] && (( value >= minimum && value <= maximum ))
}

apo_auto_validate_boolean() {
    local label=$1 value=$2
    [[ $value == 0 || $value == 1 ]] || {
        APO_AUTO_VALIDATION_REASON="Saved $label marker is malformed: ${value:-missing}"
        return 1
    }
}

apo_auto_validate_final_backoff_state() {
    local count backoff_cpu backoff_gpu history last_stage last_class last_reason
    local safe_cpu safe_gpu expected_cpu expected_gpu entry domain from_clock to_clock extra expected_next
    local from_cpu from_gpu to_cpu to_gpu pair_extra expected_cpu_next expected_gpu_next
    local -a entries=()
    count=$(apo_state_get FINAL_BACKOFF_COUNT 0)
    backoff_cpu=$(apo_state_get FINAL_BACKOFF_CPU '')
    backoff_gpu=$(apo_state_get FINAL_BACKOFF_GPU '')
    history=$(apo_state_get FINAL_BACKOFF_HISTORY '')
    last_stage=$(apo_state_get FINAL_BACKOFF_LAST_STAGE '')
    last_class=$(apo_state_get FINAL_BACKOFF_LAST_CLASS '')
    last_reason=$(apo_state_get FINAL_BACKOFF_LAST_REASON '')
    apo_auto_uint_in_range "$count" 0 64 || {
        APO_AUTO_VALIDATION_REASON="Saved final backoff count is malformed: ${count:-missing}"
        return 1
    }
    if (( count == 0 )); then
        [[ -z $backoff_cpu && -z $backoff_gpu && -z $history && -z $last_stage && -z $last_class && -z $last_reason ]] || {
            APO_AUTO_VALIDATION_REASON='Saved final backoff evidence exists without a backoff count'
            return 1
        }
        return 0
    fi
    safe_cpu=$(apo_state_get SAFE_CPU '')
    safe_gpu=$(apo_state_get SAFE_GPU '')
    apo_auto_uint_in_range "$safe_cpu" "$APO_AUTO_BASELINE_CPU" "$APO_AUTO_CPU_MAX_MHZ" || {
        APO_AUTO_VALIDATION_REASON='Saved final CPU backoff has no valid guarded CPU origin'
        return 1
    }
    apo_auto_uint_in_range "$safe_gpu" "$APO_AUTO_BASELINE_GPU" "$APO_AUTO_GPU_MAX_MHZ" || {
        APO_AUTO_VALIDATION_REASON='Saved final GPU backoff has no valid guarded GPU origin'
        return 1
    }
    apo_auto_uint_in_range "$backoff_cpu" "$APO_AUTO_BASELINE_CPU" "$APO_AUTO_CPU_MAX_MHZ" || {
        APO_AUTO_VALIDATION_REASON="Saved final CPU backoff is malformed: ${backoff_cpu:-missing}"
        return 1
    }
    apo_auto_uint_in_range "$backoff_gpu" "$APO_AUTO_BASELINE_GPU" "$APO_AUTO_GPU_MAX_MHZ" || {
        APO_AUTO_VALIDATION_REASON="Saved final GPU backoff is malformed: ${backoff_gpu:-missing}"
        return 1
    }
    (( backoff_cpu <= safe_cpu && backoff_gpu <= safe_gpu )) || {
        APO_AUTO_VALIDATION_REASON='Saved final backoff raises a clock above its candidate-tested production guard'
        return 1
    }
    (( backoff_cpu > APO_AUTO_BASELINE_CPU || backoff_gpu > APO_AUTO_BASELINE_GPU )) || {
        APO_AUTO_VALIDATION_REASON='Saved final backoff no longer contains an overclock above the stock baseline'
        return 1
    }
    [[ -n $history ]] || {
        APO_AUTO_VALIDATION_REASON='Saved final backoff history is missing'
        return 1
    }
    IFS=',' read -r -a entries <<< "$history"
    (( ${#entries[@]} == count )) || {
        APO_AUTO_VALIDATION_REASON='Saved final backoff count does not match its history'
        return 1
    }
    expected_cpu=$safe_cpu
    expected_gpu=$safe_gpu
    for entry in "${entries[@]}"; do
        domain=''; from_clock=''; to_clock=''; extra=''
        IFS=':>' read -r domain from_clock to_clock extra <<< "$entry"
        [[ -n $domain && -n $from_clock && -n $to_clock && -z $extra ]] || {
            APO_AUTO_VALIDATION_REASON="Saved final backoff entry is malformed: $entry"
            return 1
        }
        case $domain in
            CPU)
                [[ $from_clock == "$expected_cpu" ]] || {
                    APO_AUTO_VALIDATION_REASON="Saved final CPU backoff does not continue from $expected_cpu MHz"
                    return 1
                }
                apo_auto_uint_in_range "$to_clock" "$APO_AUTO_BASELINE_CPU" "$APO_AUTO_CPU_MAX_MHZ" || {
                    APO_AUTO_VALIDATION_REASON="Saved final CPU backoff destination is malformed: $to_clock"
                    return 1
                }
                expected_next=$((from_clock - APO_AUTO_CPU_GUARD_MHZ))
                (( expected_next < APO_AUTO_BASELINE_CPU )) && expected_next=$APO_AUTO_BASELINE_CPU
                (( to_clock == expected_next && to_clock < from_clock )) || {
                    APO_AUTO_VALIDATION_REASON="Saved final CPU backoff is not one bounded ${APO_AUTO_CPU_GUARD_MHZ} MHz step: $entry"
                    return 1
                }
                expected_cpu=$to_clock
                ;;
            GPU)
                [[ $from_clock == "$expected_gpu" ]] || {
                    APO_AUTO_VALIDATION_REASON="Saved final GPU backoff does not continue from $expected_gpu MHz"
                    return 1
                }
                apo_auto_uint_in_range "$to_clock" "$APO_AUTO_BASELINE_GPU" "$APO_AUTO_GPU_MAX_MHZ" || {
                    APO_AUTO_VALIDATION_REASON="Saved final GPU backoff destination is malformed: $to_clock"
                    return 1
                }
                expected_next=$((from_clock - APO_AUTO_GPU_GUARD_MHZ))
                (( expected_next < APO_AUTO_BASELINE_GPU )) && expected_next=$APO_AUTO_BASELINE_GPU
                (( to_clock == expected_next && to_clock < from_clock )) || {
                    APO_AUTO_VALIDATION_REASON="Saved final GPU backoff is not one bounded ${APO_AUTO_GPU_GUARD_MHZ} MHz step: $entry"
                    return 1
                }
                expected_gpu=$to_clock
                ;;
            PAIR)
                from_cpu=''; from_gpu=''; to_cpu=''; to_gpu=''; pair_extra=''
                IFS='/' read -r from_cpu from_gpu pair_extra <<< "$from_clock"
                [[ -n $from_cpu && -n $from_gpu && -z $pair_extra ]] || {
                    APO_AUTO_VALIDATION_REASON="Saved final paired backoff origin is malformed: $from_clock"
                    return 1
                }
                pair_extra=''
                IFS='/' read -r to_cpu to_gpu pair_extra <<< "$to_clock"
                [[ -n $to_cpu && -n $to_gpu && -z $pair_extra ]] || {
                    APO_AUTO_VALIDATION_REASON="Saved final paired backoff destination is malformed: $to_clock"
                    return 1
                }
                [[ $from_cpu == "$expected_cpu" && $from_gpu == "$expected_gpu" ]] || {
                    APO_AUTO_VALIDATION_REASON="Saved final paired backoff does not continue from CPU $expected_cpu MHz / GPU $expected_gpu MHz"
                    return 1
                }
                apo_auto_uint_in_range "$to_cpu" "$APO_AUTO_BASELINE_CPU" "$APO_AUTO_CPU_MAX_MHZ" || {
                    APO_AUTO_VALIDATION_REASON="Saved final paired CPU destination is malformed: $to_cpu"
                    return 1
                }
                apo_auto_uint_in_range "$to_gpu" "$APO_AUTO_BASELINE_GPU" "$APO_AUTO_GPU_MAX_MHZ" || {
                    APO_AUTO_VALIDATION_REASON="Saved final paired GPU destination is malformed: $to_gpu"
                    return 1
                }
                expected_cpu_next=$expected_cpu
                expected_gpu_next=$expected_gpu
                if (( expected_cpu > APO_AUTO_BASELINE_CPU )); then
                    expected_cpu_next=$((expected_cpu - APO_AUTO_CPU_GUARD_MHZ))
                    (( expected_cpu_next < APO_AUTO_BASELINE_CPU )) && expected_cpu_next=$APO_AUTO_BASELINE_CPU
                fi
                if (( expected_gpu > APO_AUTO_BASELINE_GPU )); then
                    expected_gpu_next=$((expected_gpu - APO_AUTO_GPU_GUARD_MHZ))
                    (( expected_gpu_next < APO_AUTO_BASELINE_GPU )) && expected_gpu_next=$APO_AUTO_BASELINE_GPU
                fi
                (( to_cpu == expected_cpu_next && to_gpu == expected_gpu_next &&
                   (to_cpu < from_cpu || to_gpu < from_gpu) )) || {
                    APO_AUTO_VALIDATION_REASON="Saved final paired backoff is not one bounded CPU/GPU guard step: $entry"
                    return 1
                }
                expected_cpu=$to_cpu
                expected_gpu=$to_gpu
                ;;
            *)
                APO_AUTO_VALIDATION_REASON="Saved final backoff domain is malformed: $domain"
                return 1
                ;;
        esac
    done
    [[ $expected_cpu == "$backoff_cpu" && $expected_gpu == "$backoff_gpu" ]] || {
        APO_AUTO_VALIDATION_REASON='Saved final backoff clocks do not match their ordered history'
        return 1
    }
    case $last_stage in
        CPU_QUALIFICATION|CPU_STRESS) [[ ${entries[-1]} == CPU:* ]] ;;
        GPU_QUALIFICATION|GPU_STRESS) [[ ${entries[-1]} == GPU:* ]] ;;
        ENDURANCE|PRE_STRESS_BOOT|BOOT_*) [[ ${entries[-1]} == PAIR:* ]] ;;
        *) false ;;
    esac || {
        APO_AUTO_VALIDATION_REASON='Saved final backoff stage does not match the last history entry'
        return 1
    }
    apo_class_is_edge_failure "$last_class" && [[ -n $last_reason ]] || {
        APO_AUTO_VALIDATION_REASON='Saved final backoff lacks its recovered boot/stability-failure evidence'
        return 1
    }
}

apo_auto_validate_qualification_state() {
    local phase subphase edge_status cpu_status cpu_target cpu_qualified cpu_history cpu_last_class cpu_last_reason
    local gpu_status gpu_cpu gpu_target gpu_qualified_cpu gpu_qualified_clock safe_cpu safe_gpu
    local expected_cpu expected_gpu entry domain from_clock to_clock extra history_end
    local -a history_entries=()
    phase=$(apo_state_get PHASE '')
    subphase=$(apo_state_get SUBPHASE '')
    edge_status=$(apo_state_get EDGE_CPU_STATUS NOT_REQUESTED)
    cpu_status=$(apo_state_get CPU_QUALIFICATION_STATUS NOT_STARTED)
    cpu_target=$(apo_state_get CPU_QUALIFICATION_TARGET '')
    cpu_qualified=$(apo_state_get CPU_QUALIFIED_CLOCK '')
    cpu_history=$(apo_state_get CPU_QUALIFICATION_HISTORY '')
    cpu_last_class=$(apo_state_get CPU_QUALIFICATION_LAST_CLASS '')
    cpu_last_reason=$(apo_state_get CPU_QUALIFICATION_LAST_REASON '')
    gpu_status=$(apo_state_get GPU_QUALIFICATION_STATUS NOT_STARTED)
    gpu_cpu=$(apo_state_get GPU_QUALIFICATION_CPU '')
    gpu_target=$(apo_state_get GPU_QUALIFICATION_TARGET '')
    gpu_qualified_cpu=$(apo_state_get GPU_QUALIFIED_CPU '')
    gpu_qualified_clock=$(apo_state_get GPU_QUALIFIED_CLOCK '')
    safe_cpu=$(apo_state_get SAFE_CPU '')
    safe_gpu=$(apo_state_get SAFE_GPU '')

    case $cpu_status in NOT_STARTED|RUNNING|PASS) ;; *) APO_AUTO_VALIDATION_REASON="Saved CPU qualification status is malformed: ${cpu_status:-missing}"; return 1 ;; esac
    case $gpu_status in NOT_STARTED|RUNNING|PASS) ;; *) APO_AUTO_VALIDATION_REASON="Saved GPU qualification status is malformed: ${gpu_status:-missing}"; return 1 ;; esac

    if [[ -n $cpu_target ]]; then
        apo_auto_uint_in_range "$cpu_target" "$APO_AUTO_BASELINE_CPU" "$APO_AUTO_CPU_MAX_MHZ" || {
            APO_AUTO_VALIDATION_REASON="Saved CPU qualification target is malformed: $cpu_target"
            return 1
        }
        [[ -n $safe_cpu ]] && (( cpu_target <= safe_cpu )) || {
            APO_AUTO_VALIDATION_REASON='Saved CPU qualification target is not bounded by a verified CPU guard'
            return 1
        }
    fi
    case $cpu_status in
        NOT_STARTED|RUNNING)
            [[ -z $cpu_qualified ]] || { APO_AUTO_VALIDATION_REASON='Incomplete CPU qualification already claims a qualified clock'; return 1; }
            [[ $cpu_status == NOT_STARTED || -n $cpu_target ]] || { APO_AUTO_VALIDATION_REASON='Running CPU qualification has no target'; return 1; }
            ;;
        PASS)
            [[ -n $cpu_target && $cpu_qualified == "$cpu_target" ]] || {
                APO_AUTO_VALIDATION_REASON='Passed CPU qualification is not bound to its exact target'
                return 1
            }
            ;;
    esac
    if [[ -n $cpu_history ]]; then
        [[ -n $safe_cpu ]] || { APO_AUTO_VALIDATION_REASON='CPU qualification backoff history has no guarded origin'; return 1; }
        IFS=',' read -r -a history_entries <<< "$cpu_history"
        history_end=$safe_cpu
        for entry in "${history_entries[@]}"; do
            domain=''; from_clock=''; to_clock=''; extra=''
            IFS=':>' read -r domain from_clock to_clock extra <<< "$entry"
            [[ $domain == CPU && $from_clock == "$history_end" && $to_clock =~ ^[0-9]+$ && -z $extra ]] || {
                APO_AUTO_VALIDATION_REASON="Saved CPU qualification backoff entry is malformed or unordered: $entry"
                return 1
            }
            expected_cpu=$((from_clock - APO_AUTO_CPU_GUARD_MHZ))
            (( expected_cpu < APO_AUTO_BASELINE_CPU )) && expected_cpu=$APO_AUTO_BASELINE_CPU
            (( to_clock == expected_cpu && to_clock < from_clock )) || {
                APO_AUTO_VALIDATION_REASON="Saved CPU qualification backoff is not one ${APO_AUTO_CPU_GUARD_MHZ} MHz step: $entry"
                return 1
            }
            history_end=$to_clock
        done
        [[ -n $cpu_target ]] && (( cpu_target <= history_end )) || {
            APO_AUTO_VALIDATION_REASON='Saved CPU qualification target is inconsistent with its backoff history'
            return 1
        }
        apo_class_is_edge_failure "$cpu_last_class" && [[ -n $cpu_last_reason ]] || {
            APO_AUTO_VALIDATION_REASON='CPU qualification backoff history lacks recovered boot/stability evidence'
            return 1
        }
    elif [[ -n $cpu_last_class || -n $cpu_last_reason ]]; then
        APO_AUTO_VALIDATION_REASON='CPU qualification failure evidence exists without a backoff history'
        return 1
    fi

    if [[ -n $gpu_cpu || -n $gpu_target ]]; then
        [[ $gpu_cpu =~ ^[0-9]+$ && $gpu_target =~ ^[0-9]+$ && -n $safe_cpu && -n $safe_gpu ]] || {
            APO_AUTO_VALIDATION_REASON='Saved GPU qualification identity is incomplete or lacks verified guards'
            return 1
        }
        (( gpu_cpu >= APO_AUTO_BASELINE_CPU && gpu_cpu <= safe_cpu &&
           gpu_target >= APO_AUTO_BASELINE_GPU && gpu_target <= safe_gpu )) || {
            APO_AUTO_VALIDATION_REASON='Saved GPU qualification identity exceeds its verified production guards'
            return 1
        }
    fi
    case $gpu_status in
        NOT_STARTED|RUNNING)
            [[ -z $gpu_qualified_cpu && -z $gpu_qualified_clock ]] || {
                APO_AUTO_VALIDATION_REASON='Incomplete GPU qualification already claims qualified clocks'
                return 1
            }
            [[ $gpu_status == NOT_STARTED || ( -n $gpu_cpu && -n $gpu_target ) ]] || {
                APO_AUTO_VALIDATION_REASON='Running GPU qualification has no exact CPU/GPU target'
                return 1
            }
            ;;
        PASS)
            [[ -n $gpu_cpu && -n $gpu_target && $gpu_qualified_cpu == "$gpu_cpu" && $gpu_qualified_clock == "$gpu_target" ]] || {
                APO_AUTO_VALIDATION_REASON='Passed GPU qualification is not bound to its exact CPU/GPU target'
                return 1
            }
            ;;
    esac

    case $phase in
        GPU_SWEEP)
            [[ $cpu_status == PASS ]] || { APO_AUTO_VALIDATION_REASON='GPU sweep started before CPU qualification passed'; return 1; }
            ;;
        SELECTION)
            if [[ $subphase == GPU ]]; then
                [[ $cpu_status == PASS ]] || { APO_AUTO_VALIDATION_REASON='GPU selection started before CPU qualification passed'; return 1; }
            fi
            ;;
        GPU_QUALIFICATION)
            expected_cpu=$(apo_state_get RECOMMENDED_CPU '')
            expected_gpu=$(apo_state_get RECOMMENDED_GPU '')
            [[ $cpu_status == PASS && $cpu_qualified == "$expected_cpu" &&
               $gpu_cpu == "$expected_cpu" && $gpu_target == "$expected_gpu" ]] || {
                APO_AUTO_VALIDATION_REASON='GPU qualification is not bound to the qualified CPU and current GPU target'
                return 1
            }
            ;;
        FINAL_VALIDATION|COMPLETE)
            if [[ $edge_status == RUNNING || $edge_status == PASS || $edge_status == REJECTED || $edge_status == SKIPPED_KNOWN_BOUNDARY ]]; then
                expected_cpu=$(apo_state_get FLOOR_CPU '')
                expected_gpu=$(apo_state_get FLOOR_GPU '')
            else
                expected_cpu=$(apo_state_get RECOMMENDED_CPU '')
                expected_gpu=$(apo_state_get RECOMMENDED_GPU '')
            fi
            [[ $cpu_status == PASS && $cpu_qualified == "$expected_cpu" ]] || {
                APO_AUTO_VALIDATION_REASON='Final validation is missing exact CPU qualification for its production floor'
                return 1
            }
            if (( ${APO_REQUIRE_GPU_STRESS:-0} == 1 )); then
                [[ $gpu_status == PASS && $gpu_qualified_cpu == "$expected_cpu" && $gpu_qualified_clock == "$expected_gpu" ]] || {
                    APO_AUTO_VALIDATION_REASON='Final validation is missing exact GPU qualification for its production floor'
                    return 1
                }
            fi
            ;;
    esac
}

apo_validate_recovery_wait_state() {
    local wait_status wait_context wait_started wait_timeouts
    wait_status=$(apo_state_get RECOVERY_WAIT_STATUS IDLE)
    wait_context=$(apo_state_get RECOVERY_WAIT_CONTEXT '')
    wait_started=$(apo_state_get RECOVERY_WAIT_STARTED_AT '')
    wait_timeouts=$(apo_state_get RECOVERY_WAIT_TIMEOUTS 0)
    [[ $wait_timeouts =~ ^[0-9]+$ ]] || { APO_AUTO_VALIDATION_REASON='Saved extended SSH recovery count is malformed'; return 1; }
    case $wait_status in
        IDLE)
            [[ -z $wait_started ]] || { APO_AUTO_VALIDATION_REASON='Idle SSH recovery state retains an active wait timestamp'; return 1; }
            ;;
        WAITING)
            [[ -n $wait_context && -n $wait_started ]] || { APO_AUTO_VALIDATION_REASON='Active SSH recovery state lacks context or start time'; return 1; }
            ;;
        RETURNED)
            [[ -n $wait_context && -z $wait_started ]] || { APO_AUTO_VALIDATION_REASON='Returned SSH recovery state is incomplete'; return 1; }
            ;;
        *) APO_AUTO_VALIDATION_REASON="Saved SSH recovery status is malformed: ${wait_status:-missing}"; return 1 ;;
    esac
}

apo_auto_parse_clock_csv() {
    local label=$1 csv_value=$2 minimum=$3 maximum=$4 output_name=$5 item previous=-1
    local -n output_values=$output_name
    output_values=()
    [[ -n $csv_value ]] || return 0
    [[ $csv_value =~ ^[0-9]+(,[0-9]+)*$ ]] || {
        APO_AUTO_VALIDATION_REASON="Saved $label list is malformed: $csv_value"
        return 1
    }
    IFS=',' read -r -a output_values <<< "$csv_value"
    for item in "${output_values[@]}"; do
        apo_auto_uint_in_range "$item" "$minimum" "$maximum" || {
            APO_AUTO_VALIDATION_REASON="Saved $label clock is outside $minimum-$maximum MHz: $item"
            return 1
        }
        (( item > previous )) || {
            APO_AUTO_VALIDATION_REASON="Saved $label clocks are not strictly increasing: $csv_value"
            return 1
        }
        previous=$item
    done
}

apo_auto_validate_domain_state() {
    local domain=$1 normal_clock minimum maximum guard_mhz passed_key boundary_key candidates_key
    local index_key complete_key target_key verified_key safe_key coarse_index refine_index complete verified
    local passed_csv boundary refinement_csv target safe coarse_name refine_pass_count i expected coarse_last coarse_boundary expected_refinement
    local -a passed_values=() refinement_values=()
    case $domain in
        CPU)
            coarse_name=APO_CPU_CANDIDATES
            normal_clock=$APO_AUTO_BASELINE_CPU; minimum=$APO_AUTO_BASELINE_CPU; maximum=$APO_AUTO_CPU_MAX_MHZ
            guard_mhz=$APO_AUTO_CPU_GUARD_MHZ; passed_key=PASSED_CPUS; boundary_key=CPU_FAILURE_BOUNDARY
            candidates_key=CPU_REFINE_CANDIDATES; index_key=CPU_REFINE_INDEX; complete_key=CPU_REFINE_COMPLETE
            target_key=CPU_GUARD_TARGET; verified_key=CPU_GUARD_VERIFIED; safe_key=SAFE_CPU
            coarse_index=$(apo_state_get CPU_INDEX 0)
            ;;
        GPU)
            coarse_name=APO_GPU_CANDIDATES
            normal_clock=$APO_AUTO_BASELINE_GPU; minimum=$APO_AUTO_BASELINE_GPU; maximum=$APO_AUTO_GPU_MAX_MHZ
            guard_mhz=$APO_AUTO_GPU_GUARD_MHZ; passed_key=PASSED_GPUS; boundary_key=GPU_FAILURE_BOUNDARY
            candidates_key=GPU_REFINE_CANDIDATES; index_key=GPU_REFINE_INDEX; complete_key=GPU_REFINE_COMPLETE
            target_key=GPU_GUARD_TARGET; verified_key=GPU_GUARD_VERIFIED; safe_key=SAFE_GPU
            coarse_index=$(apo_state_get GPU_INDEX 0)
            ;;
        *) APO_AUTO_VALIDATION_REASON="Unknown automatic state domain: $domain"; return 1 ;;
    esac
    local -n coarse_candidates=$coarse_name
    apo_auto_uint_in_range "$coarse_index" 0 "${#coarse_candidates[@]}" || {
        APO_AUTO_VALIDATION_REASON="Saved $domain coarse index is malformed: ${coarse_index:-missing}"
        return 1
    }
    passed_csv=$(apo_state_get "$passed_key" '')
    boundary=$(apo_state_get "$boundary_key" '')
    refinement_csv=$(apo_state_get "$candidates_key" '')
    refine_index=$(apo_state_get "$index_key" 0)
    complete=$(apo_state_get "$complete_key" 0)
    target=$(apo_state_get "$target_key" '')
    verified=$(apo_state_get "$verified_key" 0)
    safe=$(apo_state_get "$safe_key" '')
    apo_auto_validate_boolean "$domain refinement-complete" "$complete" || return 1
    apo_auto_validate_boolean "$domain guard-verified" "$verified" || return 1
    apo_auto_parse_clock_csv "$domain passed" "$passed_csv" "$((minimum + 1))" "$maximum" passed_values || return 1
    apo_auto_parse_clock_csv "$domain refinement" "$refinement_csv" "$((minimum + 1))" "$maximum" refinement_values || return 1
    apo_auto_uint_in_range "$refine_index" 0 "${#refinement_values[@]}" || {
        APO_AUTO_VALIDATION_REASON="Saved $domain refinement index is malformed: ${refine_index:-missing}"
        return 1
    }
    if [[ -n $boundary ]]; then
        apo_auto_uint_in_range "$boundary" "$((minimum + 1))" "$maximum" || {
            APO_AUTO_VALIDATION_REASON="Saved $domain failure boundary is malformed: $boundary"
            return 1
        }
    fi
    (( ${#passed_values[@]} >= coarse_index )) || {
        APO_AUTO_VALIDATION_REASON="Saved $domain passed clocks do not cover coarse index $coarse_index"
        return 1
    }
    for ((i = 0; i < coarse_index; i++)); do
        [[ ${passed_values[$i]} == "${coarse_candidates[$i]}" ]] || {
            APO_AUTO_VALIDATION_REASON="Saved $domain coarse pass prefix disagrees with the recorded plan at index $i"
            return 1
        }
    done
    refine_pass_count=$((${#passed_values[@]} - coarse_index))
    (( refine_pass_count <= ${#refinement_values[@]} )) || {
        APO_AUTO_VALIDATION_REASON="Saved $domain passed clocks exceed its refinement plan"
        return 1
    }
    for ((i = 0; i < refine_pass_count; i++)); do
        [[ ${passed_values[$((coarse_index + i))]} == "${refinement_values[$i]}" ]] || {
            APO_AUTO_VALIDATION_REASON="Saved $domain refinement passes are not a prefix of its plan"
            return 1
        }
    done
    coarse_last=$normal_clock
    (( coarse_index > 0 )) && coarse_last=${coarse_candidates[$((coarse_index - 1))]}
    if (( ${#refinement_values[@]} > 0 )); then
        [[ -n $boundary ]] || { APO_AUTO_VALIDATION_REASON="Saved $domain refinement plan has no failure boundary"; return 1; }
        expected=$((coarse_last + APO_AUTO_REFINE_STEP_MHZ))
        for i in "${refinement_values[@]}"; do
            (( i == expected )) || {
                APO_AUTO_VALIDATION_REASON="Saved $domain refinement plan is not a canonical ${APO_AUTO_REFINE_STEP_MHZ} MHz ladder"
                return 1
            }
            expected=$((expected + APO_AUTO_REFINE_STEP_MHZ))
        done
    fi
    if [[ -z $boundary ]]; then
        (( ${#refinement_values[@]} == 0 && refine_pass_count == 0 && refine_index == 0 )) || {
            APO_AUTO_VALIDATION_REASON="Saved $domain refinement evidence exists without a failure boundary"
            return 1
        }
        if (( complete == 1 && coarse_index != ${#coarse_candidates[@]} )); then
            APO_AUTO_VALIDATION_REASON="Saved $domain refinement is complete before the coarse plan reached a boundary or ceiling"
            return 1
        fi
    elif (( coarse_index < ${#coarse_candidates[@]} )); then
        coarse_boundary=${coarse_candidates[$coarse_index]}
        (( boundary > coarse_last && boundary <= coarse_boundary )) || {
            APO_AUTO_VALIDATION_REASON="Saved $domain failure boundary is outside its coarse passing-to-failing gap"
            return 1
        }
        expected_refinement=$(apo_auto_refinement_ladder "$coarse_last" "$boundary")
        if (( complete == 0 )); then
            (( boundary == coarse_boundary )) || {
                APO_AUTO_VALIDATION_REASON="Saved in-progress $domain refinement boundary no longer matches the failed coarse candidate"
                return 1
            }
            if [[ -n $refinement_csv && $refinement_csv != "$expected_refinement" ]]; then
                APO_AUTO_VALIDATION_REASON="Saved in-progress $domain refinement plan reaches or crosses its failure boundary"
                return 1
            fi
        else
            [[ $refinement_csv == "$expected_refinement" ]] || {
                APO_AUTO_VALIDATION_REASON="Saved completed $domain refinement plan is not the exact passed prefix below its failure boundary"
                return 1
            }
            (( refine_pass_count == ${#refinement_values[@]} )) || {
                APO_AUTO_VALIDATION_REASON="Saved completed $domain refinement plan contains an unpassed candidate"
                return 1
            }
        fi
    elif [[ -z $target ]]; then
        APO_AUTO_VALIDATION_REASON="Saved $domain failure boundary has no remaining coarse candidate"
        return 1
    elif (( ${#refinement_values[@]} != 0 || refine_pass_count != 0 || refine_index != 0 || complete != 1 )); then
        APO_AUTO_VALIDATION_REASON="Saved ceiling-derived $domain guard boundary contains impossible refinement evidence"
        return 1
    fi
    if (( complete == 0 )); then
        (( refine_index == refine_pass_count )) || {
            APO_AUTO_VALIDATION_REASON="Saved $domain mid-refinement index does not match its passed prefix"
            return 1
        }
    else
        (( refine_index == ${#refinement_values[@]} )) || {
            APO_AUTO_VALIDATION_REASON="Saved completed $domain refinement index is not at the end of its plan"
            return 1
        }
    fi
    if [[ -n $target ]]; then
        apo_auto_uint_in_range "$target" "$minimum" "$maximum" || {
            APO_AUTO_VALIDATION_REASON="Saved $domain guard target is malformed: $target"
            return 1
        }
        if [[ -n $boundary ]]; then expected=$((boundary - guard_mhz)); else expected=$(apo_last_passed_clock "$passed_csv" "$normal_clock"); expected=$((expected - guard_mhz)); fi
        (( expected < normal_clock )) && expected=$normal_clock
        (( target == expected )) || {
            APO_AUTO_VALIDATION_REASON="Saved $domain guard target $target does not match the ${guard_mhz} MHz guard from ${boundary:-the highest pass}"
            return 1
        }
    elif (( verified == 1 )); then
        APO_AUTO_VALIDATION_REASON="Saved $domain guard is marked verified without a target"
        return 1
    fi
    if (( verified == 1 )); then
        [[ $safe == "$target" ]] || {
            APO_AUTO_VALIDATION_REASON="Saved safe $domain clock does not match its verified guard target"
            return 1
        }
    elif [[ -n $safe ]]; then
        APO_AUTO_VALIDATION_REASON="Saved safe $domain clock exists before its guard was verified"
        return 1
    fi
}

apo_auto_validate_edge_state() {
    local floor_validated edge_status floor_cpu floor_gpu floor_duration floor_schema edge_target
    local recommended_cpu recommended_gpu final_target_cpu final_target_gpu production_cpu production_gpu backoff_count edge_order
    floor_validated=$(apo_state_get FLOOR_VALIDATED 0)
    edge_status=$(apo_state_get EDGE_CPU_STATUS NOT_REQUESTED)
    edge_order=${APO_EDGE_ORDER:-floor-first}
    apo_auto_validate_boolean 'production-floor validated' "$floor_validated" || return 1
    case $edge_status in NOT_REQUESTED|RUNNING|PASS|REJECTED|SKIPPED_KNOWN_BOUNDARY) ;; *) APO_AUTO_VALIDATION_REASON="Saved edge CPU status is malformed: ${edge_status:-missing}"; return 1 ;; esac
    floor_cpu=$(apo_state_get FLOOR_CPU '')
    floor_gpu=$(apo_state_get FLOOR_GPU '')
    floor_duration=$(apo_state_get FLOOR_DURATION_S '')
    floor_schema=$(apo_state_get FLOOR_VALIDATION_SCHEMA '')
    edge_target=$(apo_state_get EDGE_CPU_TARGET '')
    if (( floor_validated == 0 )) && [[ $edge_status == NOT_REQUESTED ]]; then
        [[ -z $floor_cpu && -z $floor_gpu && -z $floor_duration && -z $floor_schema && -z $edge_target ]] || {
            APO_AUTO_VALIDATION_REASON='Saved edge CPU state contains floor/target evidence that is not validated'
            return 1
        }
        return 0
    fi
    [[ ${APO_AUTO_GENERATED_CANDIDATES:-0} == 1 && ${APO_EDGE_CPU_24H:-0} == 1 ]] || {
        APO_AUTO_VALIDATION_REASON='Saved production-floor evidence is attached to a non-auto or non-edge run'
        return 1
    }
    apo_auto_uint_in_range "$floor_cpu" "$APO_AUTO_BASELINE_CPU" "$APO_AUTO_CPU_MAX_MHZ" || { APO_AUTO_VALIDATION_REASON="Saved production-floor CPU is malformed: ${floor_cpu:-missing}"; return 1; }
    apo_auto_uint_in_range "$floor_gpu" "$APO_AUTO_BASELINE_GPU" "$APO_AUTO_GPU_MAX_MHZ" || { APO_AUTO_VALIDATION_REASON="Saved production-floor GPU is malformed: ${floor_gpu:-missing}"; return 1; }
    backoff_count=$(apo_state_get FINAL_BACKOFF_COUNT 0)
    if (( backoff_count > 0 )); then
        production_cpu=$(apo_state_get FINAL_BACKOFF_CPU '')
        production_gpu=$(apo_state_get FINAL_BACKOFF_GPU '')
    else
        production_cpu=$(apo_state_get SAFE_CPU '')
        production_gpu=$(apo_state_get SAFE_GPU '')
    fi
    [[ $floor_cpu == "$production_cpu" && $floor_gpu == "$production_gpu" ]] || {
        APO_AUTO_VALIDATION_REASON='Saved production-floor clocks do not match the guarded final plan'
        return 1
    }
    apo_auto_uint_in_range "$edge_target" "$((APO_AUTO_BASELINE_CPU + APO_AUTO_REFINE_STEP_MHZ))" "$((APO_AUTO_CPU_MAX_MHZ + APO_AUTO_REFINE_STEP_MHZ))" || { APO_AUTO_VALIDATION_REASON="Saved edge CPU target is malformed: ${edge_target:-missing}"; return 1; }
    (( edge_target == floor_cpu + APO_AUTO_REFINE_STEP_MHZ )) || { APO_AUTO_VALIDATION_REASON='Saved edge CPU target is not exactly 25 MHz above its production floor'; return 1; }
    recommended_cpu=$(apo_state_get RECOMMENDED_CPU '')
    recommended_gpu=$(apo_state_get RECOMMENDED_GPU '')
    final_target_cpu=$(apo_state_get FINAL_TARGET_CPU '')
    final_target_gpu=$(apo_state_get FINAL_TARGET_GPU '')
    [[ $recommended_gpu == "$floor_gpu" && $final_target_gpu == "$floor_gpu" ]] || {
        APO_AUTO_VALIDATION_REASON='Saved edge/floor GPU identities disagree'
        return 1
    }
    if (( floor_validated == 0 )); then
        [[ $edge_order == edge-first && -z $floor_duration && -z $floor_schema ]] || {
            APO_AUTO_VALIDATION_REASON='Unvalidated floor evidence is valid only during the edge-first final sequence'
            return 1
        }
        case $edge_status in
            RUNNING|PASS)
                [[ $recommended_cpu == "$edge_target" && $final_target_cpu == "$edge_target" ]] || {
                    APO_AUTO_VALIDATION_REASON='Edge-first CPU identities disagree'
                    return 1
                }
                ;;
            REJECTED|SKIPPED_KNOWN_BOUNDARY)
                [[ $recommended_cpu == "$floor_cpu" && $final_target_cpu == "$floor_cpu" ]] || {
                    APO_AUTO_VALIDATION_REASON='Pending edge-first floor identities disagree'
                    return 1
                }
                ;;
            *)
                APO_AUTO_VALIDATION_REASON='Unvalidated edge-first floor has no valid edge disposition'
                return 1
                ;;
        esac
        return 0
    fi
    [[ $floor_duration == "${APO_CFG[FINAL_DURATION_S]}" && $floor_schema == "$APO_CURRENT_VALIDATION_SCHEMA" ]] || {
        APO_AUTO_VALIDATION_REASON='Saved production-floor duration/schema does not match the recorded final plan'
        return 1
    }
    case $edge_status in
        RUNNING)
            [[ $recommended_cpu == "$edge_target" && $final_target_cpu == "$edge_target" && $(apo_state_get VALIDATED 0) == 0 ]] || {
                APO_AUTO_VALIDATION_REASON='Running edge CPU state does not target the recorded edge clock or still claims final validation'
                return 1
            }
            ;;
        PASS)
            [[ $recommended_cpu == "$edge_target" && $final_target_cpu == "$edge_target" ]] || { APO_AUTO_VALIDATION_REASON='Passed edge CPU identities disagree'; return 1; }
            ;;
        REJECTED|SKIPPED_KNOWN_BOUNDARY)
            [[ $recommended_cpu == "$floor_cpu" && $final_target_cpu == "$floor_cpu" ]] || { APO_AUTO_VALIDATION_REASON='Retained production-floor identities disagree'; return 1; }
            ;;
        NOT_REQUESTED)
            APO_AUTO_VALIDATION_REASON='Validated production-floor evidence has no edge disposition'
            return 1
            ;;
    esac
}

apo_auto_validate_final_state() {
    local edge_status stage duration validated validation_schema status phase expected_cpu expected_gpu expected_duration
    local final_cpu final_gpu recommended_cpu recommended_gpu target_cpu target_gpu completion_claimed=0 backoff_count qualification_target floor_validated
    edge_status=$(apo_state_get EDGE_CPU_STATUS NOT_REQUESTED)
    stage=$(apo_state_get FINAL_STAGE '')
    duration=$(apo_state_get VALIDATION_DURATION_S '')
    validated=$(apo_state_get VALIDATED 0)
    validation_schema=$(apo_state_get VALIDATION_SCHEMA '')
    status=$(apo_state_get STATUS '')
    phase=$(apo_state_get PHASE '')
    final_cpu=$(apo_state_get FINAL_CPU '')
    final_gpu=$(apo_state_get FINAL_GPU '')
    recommended_cpu=$(apo_state_get RECOMMENDED_CPU '')
    recommended_gpu=$(apo_state_get RECOMMENDED_GPU '')
    target_cpu=$(apo_state_get FINAL_TARGET_CPU '')
    target_gpu=$(apo_state_get FINAL_TARGET_GPU '')
    backoff_count=$(apo_state_get FINAL_BACKOFF_COUNT 0)
    floor_validated=$(apo_state_get FLOOR_VALIDATED 0)
    if (( backoff_count > 0 )); then
        expected_cpu=$(apo_state_get FINAL_BACKOFF_CPU '')
        expected_gpu=$(apo_state_get FINAL_BACKOFF_GPU '')
    else
        expected_cpu=$(apo_state_get SAFE_CPU '')
        expected_gpu=$(apo_state_get SAFE_GPU '')
    fi
    # Before the GPU guard exists, an isolated CPU qualification may have
    # safely backed the CPU below the short-search guard. That backoff cannot
    # be materialized into the final paired history until GPU selection has a
    # verified guard of its own. Bind these intermediate phases to the exact
    # qualification target instead of incorrectly demanding the old CPU guard.
    if (( backoff_count == 0 )); then
        case $phase in
            CPU_QUALIFICATION|GPU_SWEEP)
                qualification_target=$(apo_state_get CPU_QUALIFICATION_TARGET '')
                [[ -z $qualification_target ]] || expected_cpu=$qualification_target
                ;;
            SELECTION)
                if [[ $(apo_state_get SUBPHASE '') == GPU ]]; then
                    qualification_target=$(apo_state_get CPU_QUALIFICATION_TARGET '')
                    [[ -z $qualification_target ]] || expected_cpu=$qualification_target
                fi
                ;;
        esac
    fi
    expected_duration=${APO_CFG[FINAL_DURATION_S]}
    case $edge_status in
        RUNNING|PASS)
            expected_cpu=$(apo_state_get EDGE_CPU_TARGET '')
            expected_gpu=$(apo_state_get FLOOR_GPU '')
            expected_duration=$APO_EDGE_DURATION_S
            ;;
        REJECTED|SKIPPED_KNOWN_BOUNDARY)
            expected_cpu=$(apo_state_get FLOOR_CPU '')
            expected_gpu=$(apo_state_get FLOOR_GPU '')
            ;;
    esac
    if [[ $edge_status == NOT_REQUESTED ]]; then
        if [[ -n $recommended_cpu && -n $recommended_gpu ]]; then
            [[ -n $expected_cpu && -n $expected_gpu && $recommended_cpu == "$expected_cpu" && $recommended_gpu == "$expected_gpu" ]] || {
                APO_AUTO_VALIDATION_REASON='Saved automatic recommendation does not match its verified production guards'
                return 1
            }
        elif [[ -n $recommended_cpu || -n $recommended_gpu ]]; then
            [[ $recommended_cpu == "$expected_cpu" && -z $recommended_gpu &&
               ( $phase == CPU_QUALIFICATION || $phase == GPU_SWEEP || ( $phase == SELECTION && $(apo_state_get SUBPHASE '') == GPU ) ) ]] || {
                APO_AUTO_VALIDATION_REASON='Saved partial automatic recommendation exists outside CPU qualification or GPU planning'
                return 1
            }
        fi
        if [[ -n $stage ]]; then
            [[ $target_cpu == "$expected_cpu" && $target_gpu == "$expected_gpu" ]] || {
                APO_AUTO_VALIDATION_REASON='Saved automatic final-validation target does not match its verified production guards'
                return 1
            }
        fi
    fi
    case $stage in
        '') [[ -z $duration ]] || { APO_AUTO_VALIDATION_REASON='Saved final duration exists before final validation starts'; return 1; } ;;
        PRE_STRESS_BOOT|ENDURANCE)
            [[ -z $duration ]] || { APO_AUTO_VALIDATION_REASON="Saved final duration exists before endurance completed at stage $stage"; return 1; }
            ;;
        RETURN_NORMAL|VERIFY|COMPLETE)
            [[ $duration == "$expected_duration" ]] || { APO_AUTO_VALIDATION_REASON="Saved final stage $stage lacks its required ${expected_duration}s endurance evidence"; return 1; }
            ;;
        BOOT_*|NORMAL_*)
            [[ $stage =~ ^(BOOT|NORMAL)_([1-9][0-9]*)$ ]] || { APO_AUTO_VALIDATION_REASON="Saved final stage is malformed: $stage"; return 1; }
            [[ $duration == "$expected_duration" ]] || { APO_AUTO_VALIDATION_REASON="Saved final stage $stage lacks its required ${expected_duration}s endurance evidence"; return 1; }
            ;;
        *) APO_AUTO_VALIDATION_REASON="Saved final stage is malformed: $stage"; return 1 ;;
    esac
    if [[ $edge_status == RUNNING && $stage == COMPLETE ]]; then
        APO_AUTO_VALIDATION_REASON='Running edge CPU state cannot already be complete'
        return 1
    fi
    if [[ $validated == 1 || -n $final_cpu || -n $final_gpu || -n $validation_schema || $stage == COMPLETE ||
          $edge_status == PASS ]] ||
       { (( floor_validated == 1 )) && [[ $edge_status == REJECTED || $edge_status == SKIPPED_KNOWN_BOUNDARY ]]; }; then
        completion_claimed=1
    fi
    if (( completion_claimed == 1 )); then
        [[ $validated == 1 && $validation_schema == "$APO_CURRENT_VALIDATION_SCHEMA" && $status == PASS && $phase == COMPLETE && $stage == COMPLETE &&
           -n $expected_cpu && -n $expected_gpu && $recommended_cpu == "$expected_cpu" && $recommended_gpu == "$expected_gpu" &&
           $target_cpu == "$expected_cpu" && $target_gpu == "$expected_gpu" && $final_cpu == "$expected_cpu" && $final_gpu == "$expected_gpu" ]] || {
            APO_AUTO_VALIDATION_REASON='Saved automatic completion is not bound to its guarded final clocks and current validation evidence'
            return 1
        }
    elif [[ -n $final_cpu || -n $final_gpu || -n $validation_schema || $validated != 0 ]]; then
        APO_AUTO_VALIDATION_REASON='Saved automatic run contains partial final-validation evidence'
        return 1
    fi
}

apo_auto_validate_non_auto_state() {
    local key value
    if [[ -n ${APO_AUTO_BASELINE_CPU:-} || -n ${APO_AUTO_BASELINE_GPU:-} ||
          -n ${APO_AUTO_BASELINE_VOLTAGE:-} || -n ${APO_AUTO_BASELINE_PROVENANCE:-} ||
          -n ${APO_AUTO_BASELINE_EVIDENCE:-} ]]; then
        APO_AUTO_VALIDATION_REASON='Saved non-auto run retains automatic stock-baseline evidence'
        return 1
    fi
    for key in CPU_REFINE_CANDIDATES GPU_REFINE_CANDIDATES CPU_GUARD_TARGET GPU_GUARD_TARGET \
               FLOOR_CPU FLOOR_GPU FLOOR_DURATION_S FLOOR_VALIDATION_SCHEMA EDGE_CPU_TARGET \
               EDGE_CPU_FAILURE_CLASS EDGE_CPU_FAILURE_REASON FINAL_BACKOFF_CPU FINAL_BACKOFF_GPU \
               FINAL_BACKOFF_HISTORY FINAL_BACKOFF_LAST_STAGE FINAL_BACKOFF_LAST_CLASS FINAL_BACKOFF_LAST_REASON \
               CPU_QUALIFICATION_TARGET CPU_QUALIFIED_CLOCK CPU_QUALIFICATION_HISTORY CPU_QUALIFICATION_LAST_CLASS \
               CPU_QUALIFICATION_LAST_REASON GPU_QUALIFICATION_CPU GPU_QUALIFICATION_TARGET GPU_QUALIFIED_CPU GPU_QUALIFIED_CLOCK; do
        value=$(apo_state_get "$key" '')
        [[ -z $value ]] || {
            APO_AUTO_VALIDATION_REASON="Saved non-auto run retains automatic state in $key"
            return 1
        }
    done
    for key in CPU_REFINE_INDEX GPU_REFINE_INDEX CPU_REFINE_COMPLETE GPU_REFINE_COMPLETE \
               CPU_GUARD_VERIFIED GPU_GUARD_VERIFIED FLOOR_VALIDATED FINAL_BACKOFF_COUNT; do
        value=$(apo_state_get "$key" 0)
        [[ $value == 0 ]] || {
            APO_AUTO_VALIDATION_REASON="Saved non-auto run retains automatic state in $key"
            return 1
        }
    done
    [[ $(apo_state_get EDGE_CPU_STATUS NOT_REQUESTED) == NOT_REQUESTED ]] || {
        APO_AUTO_VALIDATION_REASON='Saved non-auto run retains an automatic edge CPU disposition'
        return 1
    }
    [[ $(apo_state_get CPU_QUALIFICATION_STATUS NOT_STARTED) == NOT_STARTED &&
       $(apo_state_get GPU_QUALIFICATION_STATUS NOT_STARTED) == NOT_STARTED ]] || {
        APO_AUTO_VALIDATION_REASON='Saved non-auto run retains automatic qualification status'
        return 1
    }
}

apo_validate_auto_resume_state() {
    local auto_marker=${APO_AUTO_GENERATED_CANDIDATES:-0} edge_marker=${APO_EDGE_CPU_24H:-0}
    local expected_cpu_csv expected_gpu_csv apply_status final_cpu final_gpu
    local post_floor_edge source_floor_run_id source_floor_hash floor_cpu floor_gpu permanent_hash edge_status
    local post_floor_final post_floor_final_stage source_final_run_id source_final_hash source_final_duration source_final_backup
    APO_AUTO_VALIDATION_REASON=''
    apo_validate_recovery_wait_state || { apo_auto_state_invalid "$APO_AUTO_VALIDATION_REASON"; return 1; }
    apo_auto_validate_boolean 'automatic-candidate' "$auto_marker" || { apo_auto_state_invalid "$APO_AUTO_VALIDATION_REASON"; return 1; }
    apo_auto_validate_boolean 'edge CPU option' "$edge_marker" || { apo_auto_state_invalid "$APO_AUTO_VALIDATION_REASON"; return 1; }
    post_floor_edge=$(apo_state_get POST_FLOOR_EDGE 0)
    source_floor_run_id=$(apo_state_get SOURCE_FLOOR_RUN_ID '')
    source_floor_hash=$(apo_state_get SOURCE_FLOOR_PERMANENT_HASH '')
    apo_auto_validate_boolean 'post-floor edge continuation' "$post_floor_edge" || { apo_auto_state_invalid "$APO_AUTO_VALIDATION_REASON"; return 1; }
    if (( post_floor_edge == 0 )); then
        if [[ -n $source_floor_run_id || -n $source_floor_hash ]]; then
            apo_auto_state_invalid 'Saved source-floor identity exists outside a post-floor edge continuation.'
            return 1
        fi
    elif (( auto_marker != 1 || edge_marker != 1 )); then
        apo_auto_state_invalid 'Post-floor edge continuation is saved on a non-auto or non-edge run.'
        return 1
    elif ! apo_is_safe_run_id "$source_floor_run_id" || [[ $source_floor_run_id == $(apo_state_get RUN_ID '') || ! $source_floor_hash =~ ^[0-9a-f]{64}$ ]]; then
        apo_auto_state_invalid 'Saved post-floor edge continuation has an invalid source run or permanent-config hash.'
        return 1
    fi
    post_floor_final=$(apo_state_get POST_FLOOR_FINAL 0)
    post_floor_final_stage=$(apo_state_get POST_FLOOR_FINAL_STAGE '')
    source_final_run_id=$(apo_state_get SOURCE_FINAL_RUN_ID '')
    source_final_hash=$(apo_state_get SOURCE_FINAL_PERMANENT_HASH '')
    source_final_duration=$(apo_state_get SOURCE_FINAL_VALIDATION_DURATION_S '')
    source_final_backup=$(apo_state_get SOURCE_FINAL_APPLY_BACKUP '')
    apo_auto_validate_boolean 'post-floor longer final continuation' "$post_floor_final" || { apo_auto_state_invalid "$APO_AUTO_VALIDATION_REASON"; return 1; }
    if (( post_floor_final == 0 )); then
        if [[ -n $post_floor_final_stage || -n $source_final_run_id || -n $source_final_hash ||
              -n $source_final_duration || -n $source_final_backup ]]; then
            apo_auto_state_invalid 'Saved source-final identity exists outside a longer final-validation continuation.'
            return 1
        fi
    elif (( post_floor_edge == 1 || auto_marker != 1 )); then
        apo_auto_state_invalid 'Longer final-validation continuation is saved on a post-floor edge or non-auto run.'
        return 1
    elif ! apo_is_safe_run_id "$source_final_run_id" ||
         [[ $source_final_run_id == $(apo_state_get RUN_ID '') || ! $source_final_hash =~ ^[0-9a-f]{64}$ ]] ||
         ! apo_validate_uint_range "$source_final_duration" "$APO_MIN_TUNING_DURATION_S" "$APO_MAX_TUNING_DURATION_S" ||
         [[ -z $source_final_backup ]]; then
        apo_auto_state_invalid 'Saved longer final-validation continuation has invalid source run, hash, duration, or backup evidence.'
        return 1
    else
        case $post_floor_final_stage in VALIDATING|BACKOFF_TUNING|COMPLETE|FAILED) ;; *)
            apo_auto_state_invalid "Saved longer final-validation stage is malformed: ${post_floor_final_stage:-missing}"
            return 1
            ;;
        esac
        if [[ $post_floor_final_stage == VALIDATING && $edge_marker != 0 ]]; then
            apo_auto_state_invalid 'Initial longer final validation unexpectedly contains an edge-first plan.'
            return 1
        fi
        if [[ $post_floor_final_stage == BACKOFF_TUNING && $edge_marker != 1 ]]; then
            apo_auto_state_invalid 'Longer-final automatic backoff is missing its edge-first plan.'
            return 1
        fi
        if (( edge_marker == 1 )) &&
           [[ ${APO_EDGE_ORDER:-floor-first} != edge-first ||
              $(apo_state_get CFG_EDGE_DURATION_S '') != "$(apo_state_get CFG_FINAL_DURATION_S '')" ]]; then
            apo_auto_state_invalid 'Longer-final automatic backoff must use one equal-duration edge-first final plan.'
            return 1
        fi
    fi
    if (( auto_marker == 1 )); then
        if [[ ${APO_AUTO_BASELINE_PROVENANCE:-missing} != verified-default || ${APO_AUTO_BASELINE_EVIDENCE:-missing} != none ||
              ${APO_AUTO_BASELINE_CPU:-missing} != "$APO_PI5_STOCK_CPU_MHZ" ||
              ( ${APO_AUTO_BASELINE_GPU:-missing} != 800 && ${APO_AUTO_BASELINE_GPU:-missing} != 960 ) ||
              ${APO_AUTO_BASELINE_VOLTAGE:-missing} != "$APO_PI5_STOCK_VOLTAGE_UV" ]]; then
            apo_auto_state_invalid "Saved automatic stock-baseline evidence is missing or inconsistent: CPU=${APO_AUTO_BASELINE_CPU:-missing}, GPU=${APO_AUTO_BASELINE_GPU:-missing}, voltage=${APO_AUTO_BASELINE_VOLTAGE:-missing}, audit=${APO_AUTO_BASELINE_PROVENANCE:-missing}, evidence=${APO_AUTO_BASELINE_EVIDENCE:-missing}."
            return 1
        fi
        expected_cpu_csv=$(apo_config_auto_ladder "$APO_AUTO_BASELINE_CPU" "$APO_AUTO_CPU_STEP_MHZ" "$APO_AUTO_CPU_MAX_MHZ" "$APO_CPU_CLOCK_MIN_MHZ") || {
            apo_auto_state_invalid 'Saved automatic CPU plan could not be reconstructed from its stock baseline.'
            return 1
        }
        expected_gpu_csv=$(apo_config_auto_ladder "$APO_AUTO_BASELINE_GPU" "$APO_AUTO_GPU_STEP_MHZ" "$APO_AUTO_GPU_MAX_MHZ" "$APO_GPU_CLOCK_MIN_MHZ") || {
            apo_auto_state_invalid 'Saved automatic GPU plan could not be reconstructed from its stock baseline.'
            return 1
        }
        if [[ ${APO_CFG[CPU_CANDIDATES]:-} != "$expected_cpu_csv" || ${APO_CFG[GPU_CANDIDATES]:-} != "$expected_gpu_csv" ||
              ${APO_CFG[BACKOFF_STEPS]:-missing} != 0 || ${APO_CFG[VOLTAGE_DELTA_UV]:-missing} != existing ||
              ${APO_TEST_VOLTAGE:-missing} != "$APO_PI5_STOCK_VOLTAGE_UV" ]]; then
            apo_auto_state_invalid 'Saved automatic candidate or voltage plan no longer matches the deterministic stock-derived plan.'
            return 1
        fi
        apply_status=$(apo_state_get APPLY_STATUS NOT_APPLIED)
        if [[ $apply_status == APPLIED ]]; then
            final_cpu=$(apo_state_get FINAL_CPU '')
            final_gpu=$(apo_state_get FINAL_GPU '')
            if [[ -z $final_cpu || -z $final_gpu || $APO_NORMAL_CPU != "$final_cpu" || $APO_NORMAL_GPU != "$final_gpu" ||
                  $APO_NORMAL_VOLTAGE != "$APO_TEST_VOLTAGE" ]]; then
                apo_auto_state_invalid 'Applied automatic state does not bind its current normal clocks to the validated final clocks.'
                return 1
            fi
        elif (( post_floor_edge == 1 )); then
            floor_cpu=$(apo_state_get FLOOR_CPU '')
            floor_gpu=$(apo_state_get FLOOR_GPU '')
            permanent_hash=$(apo_state_get PERMANENT_HASH '')
            if [[ $(apo_state_get FLOOR_VALIDATED 0) != 1 || $APO_NORMAL_CPU != "$floor_cpu" ||
                  $APO_NORMAL_GPU != "$floor_gpu" || $APO_NORMAL_VOLTAGE != "$APO_TEST_VOLTAGE" ||
                  $permanent_hash != "$source_floor_hash" ]]; then
                apo_auto_state_invalid 'Unapplied post-floor edge state is not bound to its already-applied validated floor.'
                return 1
            fi
        elif [[ $APO_NORMAL_CPU != "$APO_AUTO_BASELINE_CPU" || $APO_NORMAL_GPU != "$APO_AUTO_BASELINE_GPU" ||
                $APO_NORMAL_VOLTAGE != "$APO_AUTO_BASELINE_VOLTAGE" ]]; then
            apo_auto_state_invalid 'Unapplied automatic state no longer matches its immutable stock baseline.'
            return 1
        fi
        apo_auto_validate_domain_state CPU || { apo_auto_state_invalid "$APO_AUTO_VALIDATION_REASON"; return 1; }
        apo_auto_validate_domain_state GPU || { apo_auto_state_invalid "$APO_AUTO_VALIDATION_REASON"; return 1; }
        apo_auto_validate_final_backoff_state || { apo_auto_state_invalid "$APO_AUTO_VALIDATION_REASON"; return 1; }
        apo_auto_validate_qualification_state || { apo_auto_state_invalid "$APO_AUTO_VALIDATION_REASON"; return 1; }
    elif (( edge_marker == 1 )); then
        apo_auto_state_invalid 'Edge CPU validation is saved on a non-auto run.'
        return 1
    else
        apo_auto_validate_non_auto_state || { apo_auto_state_invalid "$APO_AUTO_VALIDATION_REASON"; return 1; }
    fi
    apo_auto_validate_edge_state || { apo_auto_state_invalid "$APO_AUTO_VALIDATION_REASON"; return 1; }
    if (( auto_marker == 1 )); then
        apo_auto_validate_final_state || { apo_auto_state_invalid "$APO_AUTO_VALIDATION_REASON"; return 1; }
    fi
    if [[ $post_floor_edge == 1 && $apply_status == APPLIED ]]; then
        permanent_hash=$(apo_state_get PERMANENT_HASH '')
        edge_status=$(apo_state_get EDGE_CPU_STATUS NOT_REQUESTED)
        case $edge_status in
            PASS)
                [[ $permanent_hash =~ ^[0-9a-f]{64}$ && $permanent_hash != "$source_floor_hash" ]] || {
                    apo_auto_state_invalid 'Applied post-floor edge result did not advance beyond its source-floor config hash.'
                    return 1
                }
                ;;
            REJECTED|SKIPPED_KNOWN_BOUNDARY)
                [[ $permanent_hash == "$source_floor_hash" ]] || {
                    apo_auto_state_invalid 'Retained post-floor result no longer matches its source-floor config hash.'
                    return 1
                }
                ;;
            *)
                apo_auto_state_invalid 'Applied post-floor edge state has no completed edge disposition.'
                return 1
                ;;
        esac
    fi
}

apo_last_passed_clock() {
    local csv_value=$1 fallback=$2
    local -a values=()
    apo_csv_to_array "$csv_value" values
    if (( ${#values[@]} > 0 )); then printf '%s' "${values[-1]}"; else printf '%s' "$fallback"; fi
}

apo_auto_refinement_ladder() {
    local last_pass=$1 failure_boundary=$2 candidate ladder=''
    candidate=$((last_pass + APO_AUTO_REFINE_STEP_MHZ))
    while (( candidate < failure_boundary )); do
        ladder=$(apo_append_csv "$ladder" "$candidate")
        candidate=$((candidate + APO_AUTO_REFINE_STEP_MHZ))
    done
    printf '%s' "$ladder"
}

apo_auto_refine_domain() {
    local domain=$1 normal_clock=$2 fixed_clock=$3 stress_kind=$4
    local passed_key boundary_key candidates_key index_key complete_key candidate label passed_csv boundary refinement_csv index truncated_index truncated_csv
    local -a refinement_candidates=()
    case $domain in
        CPU)
            passed_key=PASSED_CPUS; boundary_key=CPU_FAILURE_BOUNDARY; candidates_key=CPU_REFINE_CANDIDATES
            index_key=CPU_REFINE_INDEX; complete_key=CPU_REFINE_COMPLETE
            ;;
        GPU)
            passed_key=PASSED_GPUS; boundary_key=GPU_FAILURE_BOUNDARY; candidates_key=GPU_REFINE_CANDIDATES
            index_key=GPU_REFINE_INDEX; complete_key=GPU_REFINE_COMPLETE
            ;;
        *) apo_state_fail HARNESS_FAILURE "Unknown automatic refinement domain: $domain"; return 1 ;;
    esac
    apo_validate_auto_resume_state || return 1
    [[ $(apo_state_get "$complete_key" 0) == 1 ]] && return 0
    boundary=$(apo_state_get "$boundary_key" '')
    if [[ -z $boundary ]]; then
        apo_state_set "$complete_key" 1
        apo_state_save
        return 0
    fi
    refinement_csv=$(apo_state_get "$candidates_key" '')
    if [[ -z $refinement_csv ]]; then
        passed_csv=$(apo_state_get "$passed_key" '')
        refinement_csv=$(apo_auto_refinement_ladder "$(apo_last_passed_clock "$passed_csv" "$normal_clock")" "$boundary")
        apo_state_set "$candidates_key" "$refinement_csv"
        apo_state_set "$index_key" 0
        apo_state_save
        apo_validate_auto_resume_state || return 1
    fi
    apo_csv_to_array "$refinement_csv" refinement_candidates
    index=$(apo_state_get "$index_key" 0)
    [[ $index =~ ^[0-9]+$ ]] && (( index <= ${#refinement_candidates[@]} )) || {
        apo_state_fail HARNESS_FAILURE "Saved $domain refinement index is malformed: $index"
        return 1
    }
    for (( ; index < ${#refinement_candidates[@]}; index++ )); do
        candidate=${refinement_candidates[$index]}
        if [[ $domain == CPU ]]; then
            label="cpu-refine-${candidate}_gpu-${fixed_clock}"
            if apo_test_candidate "$candidate" "$fixed_clock" "$label" "$stress_kind"; then
                :
            else
                apo_summary_line "BOUNDARY CPU refinement $candidate MHz: $APO_LAST_CLASS — $APO_LAST_REASON"
                if apo_class_is_edge_failure "$APO_LAST_CLASS"; then
                    truncated_csv=''
                    for ((truncated_index = 0; truncated_index < index; truncated_index++)); do
                        truncated_csv=$(apo_append_csv "$truncated_csv" "${refinement_candidates[$truncated_index]}")
                    done
                    apo_state_set "$boundary_key" "$candidate"
                    apo_state_set "$candidates_key" "$truncated_csv"
                    apo_state_set "$index_key" "$index"
                    apo_state_set "$complete_key" 1
                    apo_state_save
                    return 0
                fi
                apo_state_fail "$APO_LAST_CLASS" "$APO_LAST_REASON"
                return 1
            fi
        else
            label="cpu-${fixed_clock}_gpu-refine-${candidate}"
            if apo_test_candidate "$fixed_clock" "$candidate" "$label" "$stress_kind"; then
                :
            else
                apo_summary_line "BOUNDARY GPU refinement $candidate MHz: $APO_LAST_CLASS — $APO_LAST_REASON"
                if apo_class_is_edge_failure "$APO_LAST_CLASS"; then
                    truncated_csv=''
                    for ((truncated_index = 0; truncated_index < index; truncated_index++)); do
                        truncated_csv=$(apo_append_csv "$truncated_csv" "${refinement_candidates[$truncated_index]}")
                    done
                    apo_state_set "$boundary_key" "$candidate"
                    apo_state_set "$candidates_key" "$truncated_csv"
                    apo_state_set "$index_key" "$index"
                    apo_state_set "$complete_key" 1
                    apo_state_save
                    return 0
                fi
                apo_state_fail "$APO_LAST_CLASS" "$APO_LAST_REASON"
                return 1
            fi
        fi
        passed_csv=$(apo_state_get "$passed_key" '')
        passed_csv=$(apo_append_csv "$passed_csv" "$candidate")
        apo_state_set "$passed_key" "$passed_csv"
        apo_state_set "$index_key" "$((index + 1))"
        apo_state_save
        apo_summary_line "PASS $domain refinement $candidate MHz"
    done
    apo_state_set "$complete_key" 1
    apo_state_save
}

apo_auto_verify_guard() {
    local domain=$1 normal_clock=$2 fixed_clock=$3 stress_kind=$4 guard_mhz=$5
    local passed_key boundary_key target_key verified_key safe_key passed_csv boundary highest target label
    case $domain in
        CPU)
            passed_key=PASSED_CPUS; boundary_key=CPU_FAILURE_BOUNDARY; target_key=CPU_GUARD_TARGET
            verified_key=CPU_GUARD_VERIFIED; safe_key=SAFE_CPU
            ;;
        GPU)
            passed_key=PASSED_GPUS; boundary_key=GPU_FAILURE_BOUNDARY; target_key=GPU_GUARD_TARGET
            verified_key=GPU_GUARD_VERIFIED; safe_key=SAFE_GPU
            ;;
        *) apo_state_fail HARNESS_FAILURE "Unknown automatic guard domain: $domain"; return 1 ;;
    esac
    apo_validate_auto_resume_state || return 1
    [[ $(apo_state_get "$verified_key" 0) == 1 ]] && return 0
    passed_csv=$(apo_state_get "$passed_key" '')
    boundary=$(apo_state_get "$boundary_key" '')
    highest=$(apo_last_passed_clock "$passed_csv" "$normal_clock")
    target=$(apo_state_get "$target_key" '')
    if [[ -z $target ]]; then
        if [[ -n $boundary ]]; then target=$((boundary - guard_mhz)); else target=$((highest - guard_mhz)); fi
        (( target < normal_clock )) && target=$normal_clock
        apo_state_set "$target_key" "$target"
        apo_state_save
        apo_validate_auto_resume_state || return 1
    fi
    while :; do
        if (( target == normal_clock )) || apo_csv_contains_clock "$passed_csv" "$target"; then
            apo_state_set "$safe_key" "$target"
            apo_state_set "$verified_key" 1
            apo_state_save
            apo_summary_line "AUTO GUARD $domain: selected tested $target MHz (${guard_mhz} MHz below ${boundary:+failure boundary }${boundary:-highest ceiling pass})"
            return 0
        fi
        if [[ $domain == CPU ]]; then
            label="cpu-guard-${target}_gpu-${fixed_clock}"
            if apo_test_candidate "$target" "$fixed_clock" "$label" "$stress_kind"; then
                :
            else
                apo_summary_line "BOUNDARY CPU guard candidate $target MHz: $APO_LAST_CLASS — $APO_LAST_REASON"
                if ! apo_class_is_edge_failure "$APO_LAST_CLASS"; then apo_state_fail "$APO_LAST_CLASS" "$APO_LAST_REASON"; return 1; fi
                apo_state_set "$boundary_key" "$target"
                target=$((target - guard_mhz))
                (( target < normal_clock )) && target=$normal_clock
                apo_state_set "$target_key" "$target"
                apo_state_save
                continue
            fi
        else
            label="cpu-${fixed_clock}_gpu-guard-${target}"
            if apo_test_candidate "$fixed_clock" "$target" "$label" "$stress_kind"; then
                :
            else
                apo_summary_line "BOUNDARY GPU guard candidate $target MHz: $APO_LAST_CLASS — $APO_LAST_REASON"
                if ! apo_class_is_edge_failure "$APO_LAST_CLASS"; then apo_state_fail "$APO_LAST_CLASS" "$APO_LAST_REASON"; return 1; fi
                apo_state_set "$boundary_key" "$target"
                target=$((target - guard_mhz))
                (( target < normal_clock )) && target=$normal_clock
                apo_state_set "$target_key" "$target"
                apo_state_save
                continue
            fi
        fi
        apo_state_set "$safe_key" "$target"
        apo_state_set "$verified_key" 1
        apo_state_save
        apo_summary_line "PASS $domain production guard candidate $target MHz"
        return 0
    done
}

apo_sweep_cpu() {
    local index candidate passed_csv stress_kind boundary cpu_guard
    apo_validate_auto_resume_state || return 1
    index=$(apo_state_get CPU_INDEX 0)
    passed_csv=$(apo_state_get PASSED_CPUS '')
    stress_kind=$([[ $APO_REQUIRE_GPU_STRESS == 1 ]] && printf combined || printf cpu)
    boundary=$(apo_state_get CPU_FAILURE_BOUNDARY '')
    for (( ; index < ${#APO_CPU_CANDIDATES[@]} && ${#boundary} == 0; index++ )); do
        candidate=${APO_CPU_CANDIDATES[$index]}
        apo_state_set CPU_INDEX "$index"
        apo_state_save
        if apo_test_candidate "$candidate" "$APO_NORMAL_GPU" "cpu-${candidate}_gpu-${APO_NORMAL_GPU}" "$stress_kind"; then
            passed_csv=$(apo_append_csv "$passed_csv" "$candidate")
            apo_state_set PASSED_CPUS "$passed_csv"
            apo_state_set CPU_INDEX "$((index + 1))"
            apo_state_save
            apo_summary_line "PASS CPU $candidate MHz at GPU $APO_NORMAL_GPU MHz"
        else
            apo_summary_line "BOUNDARY CPU $candidate MHz: $APO_LAST_CLASS — $APO_LAST_REASON"
            if apo_class_is_edge_failure "$APO_LAST_CLASS"; then
                boundary=$candidate
                apo_state_set CPU_FAILURE_BOUNDARY "$boundary"
                apo_state_save
                break
            fi
            apo_state_fail "$APO_LAST_CLASS" "$APO_LAST_REASON"
            return 1
        fi
    done
    if (( APO_AUTO_GENERATED_CANDIDATES == 1 )); then
        apo_auto_refine_domain CPU "$APO_NORMAL_CPU" "$APO_NORMAL_GPU" "$stress_kind" || return 1
        cpu_guard=$APO_AUTO_CPU_GUARD_MHZ
        apo_auto_verify_guard CPU "$APO_NORMAL_CPU" "$APO_NORMAL_GPU" "$stress_kind" "$cpu_guard" || return 1
    elif (( ${#APO_CPU_CANDIDATES[@]} > 0 )) && [[ -z $passed_csv ]]; then
        apo_state_fail STABILITY_FAILURE 'No CPU candidate passed the complete candidate gate.'
        return 1
    fi
}

apo_sweep_gpu() {
    local index candidate passed_csv safe_cpu boundary
    apo_validate_auto_resume_state || return 1
    index=$(apo_state_get GPU_INDEX 0)
    passed_csv=$(apo_state_get PASSED_GPUS '')
    safe_cpu=$(apo_state_get CPU_QUALIFIED_CLOCK "$(apo_state_get SAFE_CPU "$APO_NORMAL_CPU")")
    boundary=$(apo_state_get GPU_FAILURE_BOUNDARY '')
    for (( ; index < ${#APO_GPU_CANDIDATES[@]} && ${#boundary} == 0; index++ )); do
        candidate=${APO_GPU_CANDIDATES[$index]}
        apo_state_set GPU_INDEX "$index"
        apo_state_save
        if apo_test_candidate "$safe_cpu" "$candidate" "cpu-${safe_cpu}_gpu-${candidate}" combined; then
            passed_csv=$(apo_append_csv "$passed_csv" "$candidate")
            apo_state_set PASSED_GPUS "$passed_csv"
            apo_state_set GPU_INDEX "$((index + 1))"
            apo_state_save
            apo_summary_line "PASS GPU $candidate MHz at CPU $safe_cpu MHz"
        else
            apo_summary_line "BOUNDARY GPU $candidate MHz: $APO_LAST_CLASS — $APO_LAST_REASON"
            if apo_class_is_edge_failure "$APO_LAST_CLASS"; then
                boundary=$candidate
                apo_state_set GPU_FAILURE_BOUNDARY "$boundary"
                apo_state_save
                break
            fi
            apo_state_fail "$APO_LAST_CLASS" "$APO_LAST_REASON"
            return 1
        fi
    done
    if (( APO_AUTO_GENERATED_CANDIDATES == 1 )); then
        apo_auto_refine_domain GPU "$APO_NORMAL_GPU" "$safe_cpu" combined || return 1
        apo_auto_verify_guard GPU "$APO_NORMAL_GPU" "$safe_cpu" combined "$APO_AUTO_GPU_GUARD_MHZ" || return 1
    elif (( ${#APO_GPU_CANDIDATES[@]} > 0 )) && [[ -z $passed_csv ]]; then
        apo_state_fail STABILITY_FAILURE 'No GPU candidate passed the complete candidate gate.'
        return 1
    fi
}

apo_clear_candidate_checkpoint() {
    apo_state_set CANDIDATE_LABEL ''
    apo_state_set CANDIDATE_CPU ''
    apo_state_set CANDIDATE_GPU ''
    apo_state_set CANDIDATE_STAGE ''
}

apo_cpu_qualification_schedule_backoff() {
    local failure_class=$1 failure_reason=$2 current_cpu next_cpu history entry
    apo_class_is_edge_failure "$failure_class" || return 1
    if [[ $(apo_state_get FINAL_BACKOFF_COUNT 0) =~ ^[1-9][0-9]*$ ]] &&
       apo_final_schedule_stress_backoff CPU_QUALIFICATION "$failure_class" "$failure_reason"; then
        return 0
    fi
    current_cpu=$(apo_state_get CPU_QUALIFICATION_TARGET '')
    [[ $current_cpu =~ ^[0-9]+$ ]] || return 1
    (( current_cpu > APO_AUTO_BASELINE_CPU )) || return 1
    next_cpu=$((current_cpu - APO_AUTO_CPU_GUARD_MHZ))
    (( next_cpu < APO_AUTO_BASELINE_CPU )) && next_cpu=$APO_AUTO_BASELINE_CPU
    entry="CPU:${current_cpu}>${next_cpu}"
    history=$(apo_state_get CPU_QUALIFICATION_HISTORY '')
    history=$(apo_append_csv "$history" "$entry")
    apo_state_set CPU_QUALIFICATION_STATUS RUNNING
    apo_state_set CPU_QUALIFICATION_TARGET "$next_cpu"
    apo_state_set CPU_QUALIFIED_CLOCK ''
    apo_state_set CPU_QUALIFICATION_HISTORY "$history"
    apo_state_set CPU_QUALIFICATION_LAST_CLASS "$failure_class"
    apo_state_set CPU_QUALIFICATION_LAST_REASON "$failure_reason"
    apo_state_set RECOMMENDED_CPU "$next_cpu"
    apo_state_set FAILURE_CLASS ''
    apo_state_set FAILURE_REASON ''
    apo_clear_candidate_checkpoint
    apo_state_phase CPU_QUALIFICATION READY RUNNING
    apo_summary_line "CPU QUALIFICATION BACKOFF: $entry after verified normal recovery; repeating the ${APO_QUALIFICATION_DURATION_S}s CPU qualification at stock GPU"
    apo_event cpu-qualification-backoff WARN "$failure_class" "CPU qualification rejected ${current_cpu} MHz: $failure_reason; reduced CPU by ${APO_AUTO_CPU_GUARD_MHZ} MHz and will repeat at ${next_cpu} MHz with stock GPU"
}

apo_qualify_cpu() {
    local target_cpu failure_class failure_reason label
    target_cpu=$(apo_state_get CPU_QUALIFICATION_TARGET '')
    if [[ -z $target_cpu ]]; then
        target_cpu=$(apo_state_get RECOMMENDED_CPU "$(apo_state_get SAFE_CPU '')")
        apo_state_set CPU_QUALIFICATION_TARGET "$target_cpu"
        apo_state_set CPU_QUALIFICATION_STATUS RUNNING
        apo_state_save
    fi
    [[ $target_cpu =~ ^[0-9]+$ ]] || {
        apo_state_fail HARNESS_FAILURE 'CPU qualification has no valid guarded CPU target.'
        return 1
    }
    if [[ $(apo_state_get CPU_QUALIFICATION_STATUS NOT_STARTED) == PASS &&
          $(apo_state_get CPU_QUALIFIED_CLOCK '') == "$target_cpu" ]]; then
        return 0
    fi
    while :; do
        target_cpu=$(apo_state_get CPU_QUALIFICATION_TARGET '')
        apo_state_phase CPU_QUALIFICATION "CPU_${target_cpu}_GPU_${APO_NORMAL_GPU}" RUNNING
        label="cpu-qualification-${target_cpu}_gpu-${APO_NORMAL_GPU}"
        apo_event cpu-qualification INFO '' "Qualifying CPU=$target_cpu MHz for ${APO_QUALIFICATION_DURATION_S}s with GPU held at stock ${APO_NORMAL_GPU} MHz."
        if apo_test_candidate "$target_cpu" "$APO_NORMAL_GPU" "$label" cpu "$APO_QUALIFICATION_DURATION_S"; then
            apo_state_set CPU_QUALIFICATION_STATUS PASS
            apo_state_set CPU_QUALIFIED_CLOCK "$target_cpu"
            apo_state_set RECOMMENDED_CPU "$target_cpu"
            apo_state_save
            apo_summary_line "CPU QUALIFICATION: PASS — CPU $target_cpu MHz / stock GPU $APO_NORMAL_GPU MHz for ${APO_QUALIFICATION_DURATION_S}s"
            apo_event cpu-qualification PASS '' "CPU=$target_cpu passed isolated ${APO_QUALIFICATION_DURATION_S}s qualification at stock GPU=$APO_NORMAL_GPU."
            return 0
        fi
        failure_class=${APO_LAST_CLASS:-HARNESS_FAILURE}
        failure_reason=${APO_LAST_REASON:-CPU qualification failed without a classified reason.}
        if (( APO_AUTO_GENERATED_CANDIDATES == 1 )) &&
           apo_cpu_qualification_schedule_backoff "$failure_class" "$failure_reason"; then
            continue
        fi
        apo_state_fail "$failure_class" "$failure_reason"
        return 1
    done
}

apo_materialize_cpu_qualification_backoff() {
    local history count qualified_cpu safe_gpu
    local -a history_entries=()
    history=$(apo_state_get CPU_QUALIFICATION_HISTORY '')
    qualified_cpu=$(apo_state_get CPU_QUALIFIED_CLOCK '')
    safe_gpu=$(apo_state_get SAFE_GPU '')
    if [[ -n $history ]]; then IFS=',' read -r -a history_entries <<< "$history"; fi
    count=${#history_entries[@]}
    apo_state_set FINAL_BACKOFF_COUNT "$count"
    if (( count == 0 )); then
        apo_state_set FINAL_BACKOFF_CPU ''
        apo_state_set FINAL_BACKOFF_GPU ''
        apo_state_set FINAL_BACKOFF_HISTORY ''
        apo_state_set FINAL_BACKOFF_LAST_STAGE ''
        apo_state_set FINAL_BACKOFF_LAST_CLASS ''
        apo_state_set FINAL_BACKOFF_LAST_REASON ''
        return 0
    fi
    [[ $qualified_cpu =~ ^[0-9]+$ && $safe_gpu =~ ^[0-9]+$ ]] || return 1
    apo_state_set FINAL_BACKOFF_CPU "$qualified_cpu"
    apo_state_set FINAL_BACKOFF_GPU "$safe_gpu"
    apo_state_set FINAL_BACKOFF_HISTORY "$history"
    apo_state_set FINAL_BACKOFF_LAST_STAGE CPU_QUALIFICATION
    apo_state_set FINAL_BACKOFF_LAST_CLASS "$(apo_state_get CPU_QUALIFICATION_LAST_CLASS '')"
    apo_state_set FINAL_BACKOFF_LAST_REASON "$(apo_state_get CPU_QUALIFICATION_LAST_REASON '')"
}

apo_qualify_gpu() {
    local target_cpu target_gpu failure_class failure_reason label
    target_cpu=$(apo_state_get RECOMMENDED_CPU '')
    target_gpu=$(apo_state_get RECOMMENDED_GPU '')
    [[ $target_cpu =~ ^[0-9]+$ && $target_gpu =~ ^[0-9]+$ ]] || {
        apo_state_fail HARNESS_FAILURE 'GPU qualification has no valid CPU/GPU production target.'
        return 1
    }
    if [[ $(apo_state_get GPU_QUALIFICATION_STATUS NOT_STARTED) == PASS &&
          $(apo_state_get GPU_QUALIFIED_CPU '') == "$target_cpu" &&
          $(apo_state_get GPU_QUALIFIED_CLOCK '') == "$target_gpu" ]]; then
        return 0
    fi
    while :; do
        target_cpu=$(apo_state_get RECOMMENDED_CPU '')
        target_gpu=$(apo_state_get RECOMMENDED_GPU '')
        apo_state_set GPU_QUALIFICATION_STATUS RUNNING
        apo_state_set GPU_QUALIFICATION_CPU "$target_cpu"
        apo_state_set GPU_QUALIFICATION_TARGET "$target_gpu"
        apo_state_phase GPU_QUALIFICATION "CPU_${target_cpu}_GPU_${target_gpu}" RUNNING
        label="gpu-qualification-${target_cpu}_gpu-${target_gpu}"
        apo_event gpu-qualification INFO '' "Qualifying GPU=$target_gpu MHz for ${APO_QUALIFICATION_DURATION_S}s at qualified CPU=$target_cpu MHz."
        if apo_test_candidate "$target_cpu" "$target_gpu" "$label" gpu "$APO_QUALIFICATION_DURATION_S"; then
            apo_state_set GPU_QUALIFICATION_STATUS PASS
            apo_state_set GPU_QUALIFIED_CPU "$target_cpu"
            apo_state_set GPU_QUALIFIED_CLOCK "$target_gpu"
            apo_state_save
            apo_summary_line "GPU QUALIFICATION: PASS — CPU $target_cpu MHz / GPU $target_gpu MHz for ${APO_QUALIFICATION_DURATION_S}s"
            apo_event gpu-qualification PASS '' "GPU=$target_gpu passed isolated ${APO_QUALIFICATION_DURATION_S}s qualification at qualified CPU=$target_cpu."
            return 0
        fi
        failure_class=${APO_LAST_CLASS:-HARNESS_FAILURE}
        failure_reason=${APO_LAST_REASON:-GPU qualification failed without a classified reason.}
        if (( APO_AUTO_GENERATED_CANDIDATES == 1 )) &&
           apo_final_schedule_stress_backoff GPU_QUALIFICATION "$failure_class" "$failure_reason"; then
            continue
        fi
        apo_state_fail "$failure_class" "$failure_reason"
        return 1
    done
}

apo_select_conservative_clocks() {
    local passed_cpu passed_gpu recommended_cpu recommended_gpu
    apo_validate_auto_resume_state || return 1
    passed_cpu=$(apo_state_get PASSED_CPUS '')
    passed_gpu=$(apo_state_get PASSED_GPUS '')
    if (( APO_AUTO_GENERATED_CANDIDATES == 1 )); then
        recommended_cpu=$(apo_state_get CPU_QUALIFIED_CLOCK "$(apo_state_get SAFE_CPU "$APO_NORMAL_CPU")")
        recommended_gpu=$(apo_state_get SAFE_GPU "$APO_NORMAL_GPU")
    else
        if [[ -n $passed_cpu ]]; then recommended_cpu=$(apo_select_with_backoff "$passed_cpu" "${APO_CFG[BACKOFF_STEPS]}" "$APO_NORMAL_CPU"); else recommended_cpu=$APO_NORMAL_CPU; fi
        if [[ -n $passed_gpu ]]; then recommended_gpu=$(apo_select_with_backoff "$passed_gpu" "${APO_CFG[BACKOFF_STEPS]}" "$APO_NORMAL_GPU"); else recommended_gpu=$APO_NORMAL_GPU; fi
    fi
    if (( APO_AUTO_GENERATED_CANDIDATES == 1 )) && (( recommended_cpu == APO_NORMAL_CPU && recommended_gpu == APO_NORMAL_GPU )); then
        apo_state_fail STABILITY_FAILURE 'Automatic refinement found no buffered overclock above the verified stock baseline.'
        return 1
    fi
    if (( APO_AUTO_GENERATED_CANDIDATES == 0 )); then
        apo_state_set SAFE_CPU "$recommended_cpu"
        apo_state_set SAFE_GPU "$recommended_gpu"
    fi
    apo_state_set RECOMMENDED_CPU "$recommended_cpu"
    apo_state_set RECOMMENDED_GPU "$recommended_gpu"
    if (( APO_AUTO_GENERATED_CANDIDATES == 1 )); then
        apo_materialize_cpu_qualification_backoff || {
            apo_state_fail HARNESS_FAILURE 'CPU qualification backoff evidence could not be bound to the selected GPU guard.'
            return 1
        }
    else
        apo_state_set FINAL_BACKOFF_COUNT 0
        apo_state_set FINAL_BACKOFF_CPU ''
        apo_state_set FINAL_BACKOFF_GPU ''
        apo_state_set FINAL_BACKOFF_HISTORY ''
        apo_state_set FINAL_BACKOFF_LAST_STAGE ''
        apo_state_set FINAL_BACKOFF_LAST_CLASS ''
        apo_state_set FINAL_BACKOFF_LAST_REASON ''
    fi
    if [[ $(apo_state_get GPU_QUALIFIED_CPU '') != "$recommended_cpu" ||
          $(apo_state_get GPU_QUALIFIED_CLOCK '') != "$recommended_gpu" ]]; then
        apo_state_set GPU_QUALIFICATION_STATUS NOT_STARTED
        apo_state_set GPU_QUALIFICATION_CPU "$recommended_cpu"
        apo_state_set GPU_QUALIFICATION_TARGET "$recommended_gpu"
        apo_state_set GPU_QUALIFIED_CPU ''
        apo_state_set GPU_QUALIFIED_CLOCK ''
    fi
    apo_state_clear_final_validation
    apo_state_set FINAL_TARGET_CPU "$recommended_cpu"
    apo_state_set FINAL_TARGET_GPU "$recommended_gpu"
    apo_state_set FINAL_STAGE ''
    apo_state_save
    apo_summary_line ''
    apo_summary_line "Maximum observed CPU passes: ${passed_cpu:-none}"
    apo_summary_line "Maximum observed GPU passes: ${passed_gpu:-none}"
    if (( APO_AUTO_GENERATED_CANDIDATES == 1 )); then
        apo_summary_line "Buffered automatic recommendation: CPU $recommended_cpu MHz / GPU $recommended_gpu MHz"
        apo_event selection PASS '' "Selected refined and guarded automatic recommendation CPU=$recommended_cpu GPU=$recommended_gpu; final clocks remain pending validation"
    else
        apo_summary_line "Conservative recommendation after ${APO_CFG[BACKOFF_STEPS]} backoff step(s): CPU $recommended_cpu MHz / GPU $recommended_gpu MHz"
        apo_event selection PASS '' "Selected conservative recommendation CPU=$recommended_cpu GPU=$recommended_gpu; final clocks remain pending validation"
    fi
}

apo_final_checkpoint() {
    local cpu_mhz=$1 gpu_mhz=$2 stage=$3
    apo_state_set FINAL_TARGET_CPU "$cpu_mhz"
    apo_state_set FINAL_TARGET_GPU "$gpu_mhz"
    apo_state_set FINAL_STAGE "$stage"
    apo_state_set PHASE FINAL_VALIDATION
    apo_state_set SUBPHASE "$stage"
    apo_state_set STATUS RUNNING
    apo_state_save
}

apo_final_identity_matches() {
    [[ $(apo_state_get FINAL_TARGET_CPU '') == "$1" && $(apo_state_get FINAL_TARGET_GPU '') == "$2" ]]
}

apo_final_saved_failure_is_retryable() {
    local run_schema=${1:-$APO_CURRENT_RUN_SCHEMA}
    [[ $(apo_state_get RUN_SCHEMA '') == "$run_schema" &&
       $(apo_state_get CFG_AUTO_GENERATED_CANDIDATES 0) == 1 &&
       $(apo_state_get ORIGIN_COMMAND '') == overclock &&
       $(apo_state_get STATUS '') == FAILED &&
       $(apo_state_get PHASE '') == FINAL_VALIDATION &&
       ( $(apo_state_get FAILURE_CLASS '') == BOOT_FAILURE || $(apo_state_get FAILURE_CLASS '') == STABILITY_FAILURE ) &&
       -n $(apo_state_get FAILURE_REASON '') &&
       $(apo_state_get EDGE_CPU_STATUS NOT_REQUESTED) == NOT_REQUESTED &&
       $(apo_state_get FLOOR_VALIDATED 0) == 0 &&
       $(apo_state_get TRYBOOT_EXPECTED 0) == 0 &&
       $(apo_state_get TRYBOOT_FILE_MAY_EXIST 0) == 0 &&
       -z $(apo_state_get TRYBOOT_OWNED_HASH '') &&
       -z $(apo_state_get TRYBOOT_RESERVATION_HASH '') &&
       -z $(apo_state_get TRYBOOT_OWNERSHIP_TOKEN '') &&
       -z $(apo_state_get TRYBOOT_QUARANTINE_PATH '') &&
       $(apo_state_get RECOMMENDED_CPU '') == "$(apo_state_get FINAL_TARGET_CPU '')" &&
       $(apo_state_get RECOMMENDED_GPU '') == "$(apo_state_get FINAL_TARGET_GPU '')" ]] || return 1
    case $(apo_state_get FINAL_STAGE '') in
        CPU_STRESS|GPU_STRESS) (( run_schema < APO_CURRENT_RUN_SCHEMA )) ;;
        PRE_STRESS_BOOT|ENDURANCE|BOOT_*) return 0 ;;
        *) return 1 ;;
    esac
}

apo_final_initialize_backoff_state() {
    local key
    for key in FINAL_BACKOFF_CPU FINAL_BACKOFF_GPU FINAL_BACKOFF_HISTORY FINAL_BACKOFF_LAST_STAGE \
               FINAL_BACKOFF_LAST_CLASS FINAL_BACKOFF_LAST_REASON; do
        [[ -v APO_STATE[$key] ]] || apo_state_set "$key" ''
    done
    [[ -v APO_STATE[FINAL_BACKOFF_COUNT] ]] || apo_state_set FINAL_BACKOFF_COUNT 0
}

apo_initialize_current_qualification_state() {
    local key
    for key in CPU_QUALIFICATION_TARGET CPU_QUALIFIED_CLOCK CPU_QUALIFICATION_HISTORY \
               CPU_QUALIFICATION_LAST_CLASS CPU_QUALIFICATION_LAST_REASON GPU_QUALIFICATION_CPU \
               GPU_QUALIFICATION_TARGET GPU_QUALIFIED_CPU GPU_QUALIFIED_CLOCK \
               RECOVERY_WAIT_CONTEXT RECOVERY_WAIT_STARTED_AT; do
        [[ -v APO_STATE[$key] ]] || apo_state_set "$key" ''
    done
    [[ -v APO_STATE[CPU_QUALIFICATION_STATUS] ]] || apo_state_set CPU_QUALIFICATION_STATUS NOT_STARTED
    [[ -v APO_STATE[GPU_QUALIFICATION_STATUS] ]] || apo_state_set GPU_QUALIFICATION_STATUS NOT_STARTED
    [[ -v APO_STATE[RECOVERY_WAIT_STATUS] ]] || apo_state_set RECOVERY_WAIT_STATUS IDLE
    [[ -v APO_STATE[RECOVERY_WAIT_TIMEOUTS] ]] || apo_state_set RECOVERY_WAIT_TIMEOUTS 0
}

apo_migrate_active_automatic_state() {
    local legacy_schema=$1 status phase failed_stage='' failure_class='' failure_reason=''
    local expected_cpu_csv expected_gpu_csv target_cpu target_gpu
    [[ $legacy_schema == 7 || $legacy_schema == 8 ]] || return 1
    [[ ${APO_AUTO_GENERATED_CANDIDATES:-0} == 1 &&
       $(apo_state_get CFG_AUTO_GENERATED_CANDIDATES 0) == 1 &&
       $(apo_state_get ORIGIN_COMMAND '') == overclock &&
       $(apo_state_get APPLY_STATUS NOT_APPLIED) != APPLIED &&
       $(apo_state_get FLOOR_VALIDATED 0) == 0 &&
       $(apo_state_get EDGE_CPU_STATUS NOT_REQUESTED) == NOT_REQUESTED ]] || return 1
    status=$(apo_state_get STATUS '')
    phase=$(apo_state_get PHASE '')
    [[ $status == RUNNING || $status == INTERRUPTED ]] || {
        apo_final_saved_failure_is_retryable "$legacy_schema" || return 1
        failed_stage=$(apo_state_get FINAL_STAGE '')
        failure_class=$(apo_state_get FAILURE_CLASS '')
        failure_reason=$(apo_state_get FAILURE_REASON '')
    }
    [[ ${APO_AUTO_BASELINE_PROVENANCE:-missing} == verified-default &&
       ${APO_AUTO_BASELINE_EVIDENCE:-missing} == none &&
       ${APO_AUTO_BASELINE_CPU:-missing} == "$APO_PI5_STOCK_CPU_MHZ" &&
       ( ${APO_AUTO_BASELINE_GPU:-missing} == 800 || ${APO_AUTO_BASELINE_GPU:-missing} == 960 ) &&
       ${APO_AUTO_BASELINE_VOLTAGE:-missing} == "$APO_PI5_STOCK_VOLTAGE_UV" ]] || return 1
    expected_cpu_csv=$(apo_config_auto_ladder "$APO_AUTO_BASELINE_CPU" "$APO_AUTO_CPU_STEP_MHZ" "$APO_AUTO_CPU_MAX_MHZ" "$APO_CPU_CLOCK_MIN_MHZ") || return 1
    expected_gpu_csv=$(apo_config_auto_ladder "$APO_AUTO_BASELINE_GPU" "$APO_AUTO_GPU_STEP_MHZ" "$APO_AUTO_GPU_MAX_MHZ" "$APO_GPU_CLOCK_MIN_MHZ") || return 1
    [[ ${APO_CFG[CPU_CANDIDATES]:-} == "$expected_cpu_csv" &&
       ${APO_CFG[GPU_CANDIDATES]:-} == "$expected_gpu_csv" &&
       ${APO_CFG[BACKOFF_STEPS]:-missing} == 0 &&
       ${APO_CFG[VOLTAGE_DELTA_UV]:-missing} == existing &&
       ${APO_CFG[FINAL_DURATION_S]:-missing} == 28800 &&
       ${APO_TEST_VOLTAGE:-missing} == "$APO_PI5_STOCK_VOLTAGE_UV" ]] || return 1
    apo_auto_validate_domain_state CPU || return 1
    apo_auto_validate_domain_state GPU || return 1
    apo_final_initialize_backoff_state
    apo_initialize_current_qualification_state
    APO_QUALIFICATION_DURATION_S=$APO_DEFAULT_QUALIFICATION_DURATION_S
    APO_EDGE_DURATION_S=$APO_DEFAULT_EDGE_DURATION_S
    APO_FINAL_DURATION_S=${APO_CFG[FINAL_DURATION_S]}
    APO_DURATION_POLICY=$(apo_config_duration_policy "$APO_QUALIFICATION_DURATION_S" "$APO_FINAL_DURATION_S" "$APO_EDGE_DURATION_S")
    apo_state_set CFG_QUALIFICATION_DURATION_S "$APO_QUALIFICATION_DURATION_S"
    apo_state_set CFG_EDGE_DURATION_S "$APO_EDGE_DURATION_S"
    apo_state_set CFG_DURATION_POLICY "$APO_DURATION_POLICY"
    apo_state_set RUN_SCHEMA "$APO_CURRENT_RUN_SCHEMA"
    apo_state_set APP_VERSION "${APO_VERSION:-$(apo_state_get APP_VERSION unknown)}"

    if [[ -n $failed_stage ]]; then
        apo_final_schedule_stress_backoff "$failed_stage" "$failure_class" "$failure_reason" || return 1
    else
        case $phase in
            TRYBOOT_PROOF|GPU_SMOKE|CPU_SWEEP)
                ;;
            SELECTION)
                if [[ $(apo_state_get SUBPHASE '') != CPU ]]; then
                    target_cpu=$(apo_state_get SAFE_CPU '')
                    target_gpu=$(apo_state_get SAFE_GPU '')
                    [[ $target_cpu =~ ^[0-9]+$ ]] || return 1
                    apo_state_set CPU_QUALIFICATION_STATUS NOT_STARTED
                    apo_state_set CPU_QUALIFICATION_TARGET "$target_cpu"
                    apo_state_set CPU_QUALIFIED_CLOCK ''
                    apo_state_set GPU_QUALIFICATION_STATUS NOT_STARTED
                    apo_state_set GPU_QUALIFICATION_CPU "$target_cpu"
                    apo_state_set GPU_QUALIFICATION_TARGET "$target_gpu"
                    apo_state_set GPU_QUALIFIED_CPU ''
                    apo_state_set GPU_QUALIFIED_CLOCK ''
                    apo_state_set RECOMMENDED_CPU "$target_cpu"
                    apo_state_set RECOMMENDED_GPU "$target_gpu"
                    apo_state_set PHASE CPU_QUALIFICATION
                    apo_state_set SUBPHASE READY
                fi
                ;;
            CPU_QUALIFICATION)
                target_cpu=$(apo_state_get SAFE_CPU '')
                [[ $target_cpu =~ ^[0-9]+$ ]] || return 1
                apo_state_set CPU_QUALIFICATION_STATUS NOT_STARTED
                apo_state_set CPU_QUALIFICATION_TARGET "$target_cpu"
                apo_state_set CPU_QUALIFIED_CLOCK ''
                apo_state_set RECOMMENDED_CPU "$target_cpu"
                ;;
            GPU_SWEEP|GPU_QUALIFICATION|FINAL_VALIDATION)
                target_cpu=$(apo_state_get RECOMMENDED_CPU "$(apo_state_get SAFE_CPU '')")
                target_gpu=$(apo_state_get RECOMMENDED_GPU "$(apo_state_get SAFE_GPU '')")
                [[ $target_cpu =~ ^[0-9]+$ ]] || return 1
                apo_state_set CPU_QUALIFICATION_STATUS NOT_STARTED
                apo_state_set CPU_QUALIFICATION_TARGET "$target_cpu"
                apo_state_set CPU_QUALIFIED_CLOCK ''
                apo_state_set GPU_QUALIFICATION_STATUS NOT_STARTED
                apo_state_set GPU_QUALIFICATION_CPU "$target_cpu"
                apo_state_set GPU_QUALIFICATION_TARGET "$target_gpu"
                apo_state_set GPU_QUALIFIED_CPU ''
                apo_state_set GPU_QUALIFIED_CLOCK ''
                apo_state_set RECOMMENDED_CPU "$target_cpu"
                apo_state_set RECOMMENDED_GPU "$target_gpu"
                apo_state_clear_final_validation
                apo_state_set FINAL_STAGE ''
                apo_state_set FINAL_TARGET_CPU "$target_cpu"
                apo_state_set FINAL_TARGET_GPU "$target_gpu"
                apo_clear_candidate_checkpoint
                apo_state_set PHASE CPU_QUALIFICATION
                apo_state_set SUBPHASE READY
                ;;
            *) return 1 ;;
        esac
        apo_state_set STATUS RUNNING
        apo_state_set FAILURE_CLASS ''
        apo_state_set FAILURE_REASON ''
        apo_state_save
    fi
    apo_event overclock-state-upgrade INFO '' "Upgraded active automatic run schema $legacy_schema to $APO_CURRENT_RUN_SCHEMA; the new isolated CPU/GPU qualifications will run before combined production validation."
}

apo_final_migrate_legacy_retry_state() {
    local legacy_schema=$1
    apo_migrate_active_automatic_state "$legacy_schema"
}

apo_restart_clear_final_sequence() {
    local key
    apo_state_clear_final_validation
    for key in FLOOR_CPU FLOOR_GPU FLOOR_DURATION_S FLOOR_VALIDATION_SCHEMA EDGE_CPU_TARGET \
               EDGE_CPU_FAILURE_CLASS EDGE_CPU_FAILURE_REASON FINAL_TARGET_CPU FINAL_TARGET_GPU FINAL_STAGE; do
        apo_state_set "$key" ''
    done
    apo_state_set FLOOR_VALIDATED 0
    apo_state_set EDGE_CPU_STATUS NOT_REQUESTED
    apo_clear_candidate_checkpoint
}

apo_restart_production_pair() {
    local backoff_count
    backoff_count=$(apo_state_get FINAL_BACKOFF_COUNT 0)
    if (( backoff_count > 0 )); then
        APO_RESTART_PAIR_CPU=$(apo_state_get FINAL_BACKOFF_CPU '')
        APO_RESTART_PAIR_GPU=$(apo_state_get FINAL_BACKOFF_GPU '')
    else
        APO_RESTART_PAIR_CPU=$(apo_state_get RECOMMENDED_CPU "$(apo_state_get SAFE_CPU '')")
        APO_RESTART_PAIR_GPU=$(apo_state_get RECOMMENDED_GPU "$(apo_state_get SAFE_GPU '')")
    fi
    [[ $APO_RESTART_PAIR_CPU =~ ^[0-9]+$ && $APO_RESTART_PAIR_GPU =~ ^[0-9]+$ ]]
}

apo_restart_active_automatic_state() {
    local checkpoint=$1 phase cpu_target gpu_target
    [[ $(apo_state_get RUN_SCHEMA '') == "$APO_CURRENT_RUN_SCHEMA" &&
       $(apo_state_get ORIGIN_COMMAND '') == overclock &&
       $(apo_state_get CFG_AUTO_GENERATED_CANDIDATES 0) == 1 &&
       $(apo_state_get APPLY_STATUS NOT_APPLIED) != APPLIED &&
       $(apo_state_get POST_FLOOR_EDGE 0) == 0 &&
       $(apo_state_get POST_FLOOR_FINAL 0) == 0 ]] || {
        APO_LAST_REASON='Checkpoint restart requires an unapplied current-schema automatic overclock run.'
        return 1
    }
    phase=$(apo_state_get PHASE '')
    [[ $phase != PREPARE && $phase != PREPARED && $phase != COMPLETE ]] || {
        APO_LAST_REASON="Checkpoint restart is unavailable from phase ${phase:-missing}."
        return 1
    }
    if [[ $phase == FINAL_VALIDATION || -n $(apo_state_get FINAL_STAGE '') ||
          $(apo_state_get EDGE_CPU_STATUS NOT_REQUESTED) != NOT_REQUESTED ||
          $(apo_state_get FLOOR_VALIDATED 0) != 0 ]]; then
        APO_LAST_REASON='An active final sequence cannot be relabeled or rewound. Resume it as saved, or use a completed applied result for a new final extension.'
        return 1
    fi
    if [[ $checkpoint != current ]]; then
        apo_restart_production_pair || {
            APO_LAST_REASON='The saved run does not yet have a complete guarded CPU/GPU pair for checkpoint restart.'
            return 1
        }
        cpu_target=$APO_RESTART_PAIR_CPU
        gpu_target=$APO_RESTART_PAIR_GPU
    fi

    APO_QUALIFICATION_DURATION_S=$APO_RESTART_QUALIFICATION_DURATION_S
    APO_FINAL_DURATION_S=$APO_RESTART_FINAL_DURATION_S
    APO_EDGE_DURATION_S=$APO_RESTART_EDGE_DURATION_S
    APO_EDGE_CPU_24H=1
    APO_EDGE_ORDER=edge-first
    APO_CFG[FINAL_DURATION_S]=$APO_FINAL_DURATION_S
    APO_DURATION_POLICY=$(apo_config_duration_policy "$APO_QUALIFICATION_DURATION_S" "$APO_FINAL_DURATION_S" "$APO_EDGE_DURATION_S")
    apo_state_set CFG_QUALIFICATION_DURATION_S "$APO_QUALIFICATION_DURATION_S"
    apo_state_set CFG_FINAL_DURATION_S "$APO_FINAL_DURATION_S"
    apo_state_set CFG_EDGE_DURATION_S "$APO_EDGE_DURATION_S"
    apo_state_set CFG_DURATION_POLICY "$APO_DURATION_POLICY"
    apo_state_set CFG_EDGE_CPU_24H 1
    apo_state_set CFG_EDGE_ORDER edge-first
    apo_state_set APP_VERSION "${APO_VERSION:-$(apo_state_get APP_VERSION unknown)}"

    case $checkpoint in
        current)
            ;;
        cpu-qualification)
            apo_restart_clear_final_sequence
            apo_state_set RECOMMENDED_CPU "$cpu_target"
            apo_state_set RECOMMENDED_GPU "$gpu_target"
            apo_state_set CPU_QUALIFICATION_STATUS NOT_STARTED
            apo_state_set CPU_QUALIFICATION_TARGET "$cpu_target"
            apo_state_set CPU_QUALIFIED_CLOCK ''
            apo_state_set GPU_QUALIFICATION_STATUS NOT_STARTED
            apo_state_set GPU_QUALIFICATION_CPU "$cpu_target"
            apo_state_set GPU_QUALIFICATION_TARGET "$gpu_target"
            apo_state_set GPU_QUALIFIED_CPU ''
            apo_state_set GPU_QUALIFIED_CLOCK ''
            apo_state_set PHASE CPU_QUALIFICATION
            apo_state_set SUBPHASE RESTART_REQUESTED
            ;;
        gpu-qualification)
            [[ $(apo_state_get CPU_QUALIFICATION_STATUS NOT_STARTED) == PASS &&
               $(apo_state_get CPU_QUALIFIED_CLOCK '') == "$cpu_target" &&
               $(apo_state_get GPU_GUARD_VERIFIED 0) == 1 ]] || {
                APO_LAST_REASON='GPU-qualification restart requires the exact retained CPU qualification and a verified GPU guard.'
                return 1
            }
            apo_restart_clear_final_sequence
            apo_state_set RECOMMENDED_CPU "$cpu_target"
            apo_state_set RECOMMENDED_GPU "$gpu_target"
            apo_state_set GPU_QUALIFICATION_STATUS NOT_STARTED
            apo_state_set GPU_QUALIFICATION_CPU "$cpu_target"
            apo_state_set GPU_QUALIFICATION_TARGET "$gpu_target"
            apo_state_set GPU_QUALIFIED_CPU ''
            apo_state_set GPU_QUALIFIED_CLOCK ''
            apo_state_set PHASE GPU_QUALIFICATION
            apo_state_set SUBPHASE RESTART_REQUESTED
            ;;
        final)
            [[ $(apo_state_get CPU_QUALIFICATION_STATUS NOT_STARTED) == PASS &&
               $(apo_state_get CPU_QUALIFIED_CLOCK '') == "$cpu_target" ]] || {
                APO_LAST_REASON='Final restart requires the exact retained CPU qualification.'
                return 1
            }
            if (( ${APO_REQUIRE_GPU_STRESS:-0} == 1 )); then
                [[ $(apo_state_get GPU_QUALIFICATION_STATUS NOT_STARTED) == PASS &&
                   $(apo_state_get GPU_QUALIFIED_CPU '') == "$cpu_target" &&
                   $(apo_state_get GPU_QUALIFIED_CLOCK '') == "$gpu_target" ]] || {
                    APO_LAST_REASON='Final restart requires the exact retained GPU qualification.'
                    return 1
                }
            fi
            apo_restart_clear_final_sequence
            apo_state_set RECOMMENDED_CPU "$cpu_target"
            apo_state_set RECOMMENDED_GPU "$gpu_target"
            apo_state_set FINAL_TARGET_CPU "$cpu_target"
            apo_state_set FINAL_TARGET_GPU "$gpu_target"
            apo_state_set PHASE FINAL_VALIDATION
            apo_state_set SUBPHASE RESTART_REQUESTED
            ;;
        *)
            APO_LAST_REASON="Unknown checkpoint restart: $checkpoint"
            return 1
            ;;
    esac
    apo_state_set STATUS RUNNING
    apo_state_set FAILURE_CLASS ''
    apo_state_set FAILURE_REASON ''
    apo_state_save
    apo_event overclock-checkpoint-restart INFO '' "Restarted from $checkpoint using retained guarded clocks and CLI durations qualification=${APO_QUALIFICATION_DURATION_S}s final=${APO_FINAL_DURATION_S}s edge=${APO_EDGE_DURATION_S}s; the final sequence is edge-first with a fresh floor fallback."
    apo_validate_auto_resume_state
}

apo_final_schedule_stress_backoff() {
    local failed_stage=$1 failure_class=$2 failure_reason=$3
    local current_cpu current_gpu next_cpu next_gpu domain step count history entry next_phase edge_status edge_order
    [[ ${APO_AUTO_GENERATED_CANDIDATES:-0} == 1 && -n $failure_reason ]] || return 1
    apo_class_is_edge_failure "$failure_class" || return 1
    edge_status=$(apo_state_get EDGE_CPU_STATUS NOT_REQUESTED)
    edge_order=${APO_EDGE_ORDER:-floor-first}
    [[ $edge_status == NOT_REQUESTED ||
       ( $edge_order == edge-first && $(apo_state_get FLOOR_VALIDATED 0) == 0 &&
         ( $edge_status == REJECTED || $edge_status == SKIPPED_KNOWN_BOUNDARY ) ) ]] || return 1
    [[
       $(apo_state_get FLOOR_VALIDATED 0) == 0 &&
       $(apo_state_get TRYBOOT_EXPECTED 0) == 0 &&
       $(apo_state_get TRYBOOT_FILE_MAY_EXIST 0) == 0 &&
       -z $(apo_state_get TRYBOOT_OWNED_HASH '') &&
       -z $(apo_state_get TRYBOOT_RESERVATION_HASH '') &&
       -z $(apo_state_get TRYBOOT_OWNERSHIP_TOKEN '') &&
        -z $(apo_state_get TRYBOOT_QUARANTINE_PATH '') ]] || return 1
    current_cpu=$(apo_state_get RECOMMENDED_CPU '')
    current_gpu=$(apo_state_get RECOMMENDED_GPU '')
    [[ $current_cpu =~ ^[0-9]+$ && $current_gpu =~ ^[0-9]+$ &&
       $current_cpu == "$(apo_state_get FINAL_TARGET_CPU '')" &&
       $current_gpu == "$(apo_state_get FINAL_TARGET_GPU '')" ]] || return 1
    next_cpu=$current_cpu
    next_gpu=$current_gpu
    case $failed_stage in
        CPU_QUALIFICATION|CPU_STRESS)
            domain=CPU
            next_phase=CPU_QUALIFICATION
            step=$APO_AUTO_CPU_GUARD_MHZ
            (( current_cpu > APO_AUTO_BASELINE_CPU )) || return 1
            next_cpu=$((current_cpu - step))
            (( next_cpu < APO_AUTO_BASELINE_CPU )) && next_cpu=$APO_AUTO_BASELINE_CPU
            entry="CPU:${current_cpu}>${next_cpu}"
            ;;
        GPU_QUALIFICATION|GPU_STRESS)
            domain=GPU
            next_phase=GPU_QUALIFICATION
            step=$APO_AUTO_GPU_GUARD_MHZ
            (( current_gpu > APO_AUTO_BASELINE_GPU )) || return 1
            next_gpu=$((current_gpu - step))
            (( next_gpu < APO_AUTO_BASELINE_GPU )) && next_gpu=$APO_AUTO_BASELINE_GPU
            entry="GPU:${current_gpu}>${next_gpu}"
            ;;
        ENDURANCE|PRE_STRESS_BOOT|BOOT_*)
            domain=PAIR
            next_phase=CPU_QUALIFICATION
            (( current_cpu > APO_AUTO_BASELINE_CPU || current_gpu > APO_AUTO_BASELINE_GPU )) || return 1
            if (( current_cpu > APO_AUTO_BASELINE_CPU )); then
                next_cpu=$((current_cpu - APO_AUTO_CPU_GUARD_MHZ))
                (( next_cpu < APO_AUTO_BASELINE_CPU )) && next_cpu=$APO_AUTO_BASELINE_CPU
            fi
            if (( current_gpu > APO_AUTO_BASELINE_GPU )); then
                next_gpu=$((current_gpu - APO_AUTO_GPU_GUARD_MHZ))
                (( next_gpu < APO_AUTO_BASELINE_GPU )) && next_gpu=$APO_AUTO_BASELINE_GPU
            fi
            entry="PAIR:${current_cpu}/${current_gpu}>${next_cpu}/${next_gpu}"
            ;;
        *) return 1 ;;
    esac
    (( next_cpu > APO_AUTO_BASELINE_CPU || next_gpu > APO_AUTO_BASELINE_GPU )) || return 1
    count=$(apo_state_get FINAL_BACKOFF_COUNT 0)
    [[ $count =~ ^[0-9]+$ ]] || return 1
    count=$((count + 1))
    (( count <= 64 )) || return 1
    history=$(apo_state_get FINAL_BACKOFF_HISTORY '')
    history=$(apo_append_csv "$history" "$entry")
    apo_state_set FINAL_BACKOFF_COUNT "$count"
    apo_state_set FINAL_BACKOFF_CPU "$next_cpu"
    apo_state_set FINAL_BACKOFF_GPU "$next_gpu"
    apo_state_set FINAL_BACKOFF_HISTORY "$history"
    apo_state_set FINAL_BACKOFF_LAST_STAGE "$failed_stage"
    apo_state_set FINAL_BACKOFF_LAST_CLASS "$failure_class"
    apo_state_set FINAL_BACKOFF_LAST_REASON "$failure_reason"
    apo_state_set RECOMMENDED_CPU "$next_cpu"
    apo_state_set RECOMMENDED_GPU "$next_gpu"
    apo_state_set FAILURE_CLASS ''
    apo_state_set FAILURE_REASON ''
    apo_state_clear_final_validation
    if [[ $edge_status != NOT_REQUESTED ]]; then
        # The first edge disposition remains in the immutable log. After the
        # guarded pair itself proves unstable, the newly reduced pair owns a
        # new edge-first sequence rather than inheriting stale clock identity.
        apo_state_set FLOOR_CPU ''
        apo_state_set FLOOR_GPU ''
        apo_state_set FLOOR_DURATION_S ''
        apo_state_set FLOOR_VALIDATION_SCHEMA ''
        apo_state_set FLOOR_VALIDATED 0
        apo_state_set EDGE_CPU_TARGET ''
        apo_state_set EDGE_CPU_STATUS NOT_REQUESTED
        apo_state_set EDGE_CPU_FAILURE_CLASS ''
        apo_state_set EDGE_CPU_FAILURE_REASON ''
    fi
    apo_state_set FINAL_TARGET_CPU "$next_cpu"
    apo_state_set FINAL_TARGET_GPU "$next_gpu"
    apo_state_set FINAL_STAGE ''
    apo_clear_candidate_checkpoint
    case $next_phase in
        CPU_QUALIFICATION)
            apo_state_set CPU_QUALIFICATION_STATUS NOT_STARTED
            apo_state_set CPU_QUALIFICATION_TARGET "$next_cpu"
            apo_state_set CPU_QUALIFIED_CLOCK ''
            apo_state_set GPU_QUALIFICATION_STATUS NOT_STARTED
            apo_state_set GPU_QUALIFICATION_CPU "$next_cpu"
            apo_state_set GPU_QUALIFICATION_TARGET "$next_gpu"
            apo_state_set GPU_QUALIFIED_CPU ''
            apo_state_set GPU_QUALIFIED_CLOCK ''
            apo_state_phase CPU_QUALIFICATION READY RUNNING
            ;;
        GPU_QUALIFICATION)
            apo_state_set GPU_QUALIFICATION_STATUS NOT_STARTED
            apo_state_set GPU_QUALIFICATION_CPU "$next_cpu"
            apo_state_set GPU_QUALIFICATION_TARGET "$next_gpu"
            apo_state_set GPU_QUALIFIED_CPU ''
            apo_state_set GPU_QUALIFIED_CLOCK ''
            apo_state_phase GPU_QUALIFICATION READY RUNNING
            ;;
    esac
    if [[ $domain == PAIR ]]; then
        apo_summary_line "FINAL BACKOFF PAIR: $entry after verified normal recovery; pair-level evidence did not identify one failing domain, so every still-overclocked domain was reduced before CPU and GPU qualification restart"
        apo_event final-backoff WARN "$failure_class" "Pair-level validation rejected CPU=$current_cpu GPU=$current_gpu without identifying one failing domain: $failure_reason; conservatively reduced the pair to CPU=$next_cpu GPU=$next_gpu and restarted both domain qualifications"
    else
        apo_summary_line "QUALIFICATION BACKOFF $domain: $entry after verified normal recovery; repeating $domain qualification at CPU $next_cpu MHz / GPU $next_gpu MHz"
        apo_event qualification-backoff WARN "$failure_class" "$domain qualification rejected CPU=$current_cpu GPU=$current_gpu: $failure_reason; reduced $domain by $step MHz and will repeat at CPU=$next_cpu GPU=$next_gpu"
    fi
}

apo_post_floor_final_schedule_stress_backoff() {
    local failed_stage=$1 failure_class=$2 failure_reason=$3
    local failed_cpu failed_gpu next_cpu next_gpu
    local old_edge_marker old_edge_order old_edge_duration old_duration_policy old_extension_stage old_app_version
    [[ $(apo_state_get POST_FLOOR_FINAL 0) == 1 ]] || return 1
    case $(apo_state_get POST_FLOOR_FINAL_STAGE '') in VALIDATING|FAILED) ;; *) return 1 ;; esac
    apo_class_is_edge_failure "$failure_class" || return 1

    failed_cpu=$(apo_state_get FINAL_TARGET_CPU '')
    failed_gpu=$(apo_state_get FINAL_TARGET_GPU '')
    old_edge_marker=${APO_EDGE_CPU_24H:-0}
    old_edge_order=${APO_EDGE_ORDER:-floor-first}
    old_edge_duration=${APO_EDGE_DURATION_S:-$APO_DEFAULT_EDGE_DURATION_S}
    old_duration_policy=${APO_DURATION_POLICY:-default}
    old_extension_stage=$(apo_state_get POST_FLOOR_FINAL_STAGE '')
    old_app_version=$(apo_state_get APP_VERSION '')

    # The requested longer-final duration becomes both alternatives in the
    # fresh edge-first sequence. These state changes are intentionally held in
    # memory until the generic scheduler performs its single atomic save.
    APO_EDGE_CPU_24H=1
    APO_EDGE_ORDER=edge-first
    APO_EDGE_DURATION_S=$APO_FINAL_DURATION_S
    APO_DURATION_POLICY=$(apo_config_duration_policy "$APO_QUALIFICATION_DURATION_S" "$APO_FINAL_DURATION_S" "$APO_EDGE_DURATION_S")
    apo_state_set CFG_EDGE_CPU_24H 1
    apo_state_set CFG_EDGE_ORDER edge-first
    apo_state_set CFG_EDGE_DURATION_S "$APO_EDGE_DURATION_S"
    apo_state_set CFG_DURATION_POLICY "$APO_DURATION_POLICY"
    apo_state_set POST_FLOOR_FINAL_STAGE BACKOFF_TUNING
    apo_state_set APP_VERSION "${APO_VERSION:-$(apo_state_get APP_VERSION unknown)}"

    if ! apo_final_schedule_stress_backoff "$failed_stage" "$failure_class" "$failure_reason"; then
        APO_EDGE_CPU_24H=$old_edge_marker
        APO_EDGE_ORDER=$old_edge_order
        APO_EDGE_DURATION_S=$old_edge_duration
        APO_DURATION_POLICY=$old_duration_policy
        apo_state_set CFG_EDGE_CPU_24H "$old_edge_marker"
        apo_state_set CFG_EDGE_ORDER "$old_edge_order"
        apo_state_set CFG_EDGE_DURATION_S "$old_edge_duration"
        apo_state_set CFG_DURATION_POLICY "$old_duration_policy"
        apo_state_set POST_FLOOR_FINAL_STAGE "$old_extension_stage"
        apo_state_set APP_VERSION "$old_app_version"
        return 1
    fi

    next_cpu=$(apo_state_get RECOMMENDED_CPU '?')
    next_gpu=$(apo_state_get RECOMMENDED_GPU '?')
    apo_summary_line "LONGER FINAL AUTO BACKOFF: CPU $failed_cpu MHz / GPU $failed_gpu MHz was safely rejected; stock remains active while CPU $next_cpu MHz / GPU $next_gpu MHz is requalified before a fresh edge-first ${APO_FINAL_DURATION_S}s final sequence"
    apo_event post-floor-final-backoff WARN "$failure_class" "Longer validation safely rejected CPU=$failed_cpu GPU=$failed_gpu: $failure_reason; source clocks were not reapplied, conservatively reduced pair CPU=$next_cpu GPU=$next_gpu will repeat both qualifications, then edge-first and guarded-floor alternatives each use ${APO_FINAL_DURATION_S}s"
}

apo_final_record_failure() {
    local recovery_context=$1 failure_class=$2 failure_reason=$3 stress_result_structured=${4-} floor_cpu floor_gpu failed_stage edge_order
    failed_stage=$(apo_state_get FINAL_STAGE '')
    if [[ -n $stress_result_structured ]]; then
        if ! apo_recover_stress_failure "$recovery_context" "$failure_class" "$failure_reason" "$stress_result_structured" final; then
            apo_state_clear_final_validation
            apo_state_fail RECOVERY_FAILURE "$APO_LAST_REASON"
            return 1
        fi
        failure_class=$APO_LAST_CLASS
        failure_reason=$APO_LAST_REASON
    elif ! apo_recover_preserving_failure "$recovery_context" "$failure_class" "$failure_reason"; then
        apo_state_clear_final_validation
        apo_state_fail RECOVERY_FAILURE "$APO_LAST_REASON"
        return 1
    fi
    if [[ $(apo_state_get POST_FLOOR_FINAL 0) == 1 &&
          $(apo_state_get POST_FLOOR_FINAL_STAGE '') != BACKOFF_TUNING ]]; then
        if apo_post_floor_final_schedule_stress_backoff "$failed_stage" "$failure_class" "$failure_reason"; then
            return 2
        fi
        apo_state_clear_final_validation
        apo_state_fail "$failure_class" "$failure_reason"
        apo_state_set POST_FLOOR_FINAL_STAGE FAILED
        apo_state_save
        apo_summary_line "LONGER FINAL VALIDATION: FAILED — source clocks were not reapplied; verified stock config remains active."
        apo_event post-floor-final ERROR "$failure_class" "CPU=$(apo_state_get FINAL_TARGET_CPU '?') GPU=$(apo_state_get FINAL_TARGET_GPU '?') failed the requested longer validation: $failure_reason; stock config remains active."
        return 1
    fi
    edge_order=${APO_EDGE_ORDER:-floor-first}
    if [[ $(apo_state_get EDGE_CPU_STATUS NOT_REQUESTED) == RUNNING && $edge_order == edge-first ]] &&
       apo_class_is_edge_failure "$failure_class" &&
       [[ $(apo_state_get FLOOR_VALIDATED 0) == 0 ]]; then
        APO_AUTO_VALIDATION_REASON=''
        apo_auto_validate_edge_state || {
            apo_auto_state_invalid "${APO_AUTO_VALIDATION_REASON:-Saved edge-first evidence is invalid.}"
            return 1
        }
        floor_cpu=$(apo_state_get FLOOR_CPU '')
        floor_gpu=$(apo_state_get FLOOR_GPU '')
        [[ -n $floor_cpu && -n $floor_gpu ]] || {
            apo_state_clear_final_validation
            apo_state_fail HARNESS_FAILURE 'The edge-first test failed but its guarded floor clocks are missing.'
            return 1
        }
        apo_state_set EDGE_CPU_STATUS REJECTED
        apo_state_set EDGE_CPU_FAILURE_CLASS "$failure_class"
        apo_state_set EDGE_CPU_FAILURE_REASON "$failure_reason"
        apo_state_set RECOMMENDED_CPU "$floor_cpu"
        apo_state_set RECOMMENDED_GPU "$floor_gpu"
        apo_state_clear_final_validation
        apo_state_set FINAL_TARGET_CPU "$floor_cpu"
        apo_state_set FINAL_TARGET_GPU "$floor_gpu"
        apo_state_set FINAL_STAGE ''
        apo_state_set PHASE FINAL_VALIDATION
        apo_state_set SUBPHASE FLOOR_AFTER_EDGE_REJECTION
        apo_state_set STATUS RUNNING
        apo_state_set FAILURE_CLASS ''
        apo_state_set FAILURE_REASON ''
        apo_state_save
        apo_summary_line "EDGE CPU: REJECTED — CPU $(apo_state_get EDGE_CPU_TARGET '?') MHz / GPU $floor_gpu MHz; beginning fresh ${APO_CFG[FINAL_DURATION_S]}s guarded-floor validation at CPU $floor_cpu MHz / GPU $floor_gpu MHz."
        apo_event edge-cpu WARN "$failure_class" "Edge CPU clock was safely rejected: $failure_reason; beginning fresh guarded-floor validation at CPU=$floor_cpu GPU=$floor_gpu"
        return 2
    fi
    if [[ $(apo_state_get EDGE_CPU_STATUS NOT_REQUESTED) == RUNNING ]] &&
       apo_class_is_edge_failure "$failure_class" &&
       [[ $(apo_state_get FLOOR_VALIDATED 0) == 1 &&
          $(apo_state_get FLOOR_VALIDATION_SCHEMA '') == "$APO_CURRENT_VALIDATION_SCHEMA" ]]; then
        APO_AUTO_VALIDATION_REASON=''
        apo_auto_validate_edge_state || {
            apo_auto_state_invalid "${APO_AUTO_VALIDATION_REASON:-Saved optional edge evidence is invalid.}"
            return 1
        }
        floor_cpu=$(apo_state_get FLOOR_CPU '')
        floor_gpu=$(apo_state_get FLOOR_GPU '')
        [[ -n $floor_cpu && -n $floor_gpu ]] || {
            apo_state_clear_final_validation
            apo_state_fail HARNESS_FAILURE 'The optional edge test failed but its validated production-floor clocks are missing.'
            return 1
        }
        apo_state_set EDGE_CPU_STATUS REJECTED
        apo_state_set EDGE_CPU_FAILURE_CLASS "$failure_class"
        apo_state_set EDGE_CPU_FAILURE_REASON "$failure_reason"
        apo_state_set RECOMMENDED_CPU "$floor_cpu"
        apo_state_set RECOMMENDED_GPU "$floor_gpu"
        apo_state_set FINAL_TARGET_CPU "$floor_cpu"
        apo_state_set FINAL_TARGET_GPU "$floor_gpu"
        apo_state_complete "$floor_cpu" "$floor_gpu" "${APO_CFG[FINAL_DURATION_S]}"
        apo_summary_line "OPTIONAL EDGE CPU: REJECTED — retained validated production floor CPU $floor_cpu MHz / GPU $floor_gpu MHz"
        apo_event edge-cpu-24h WARN "$failure_class" "Optional edge CPU clock was rejected: $failure_reason; retained validated production floor CPU=$floor_cpu GPU=$floor_gpu"
        return 0
    fi
    if apo_final_schedule_stress_backoff "$failed_stage" "$failure_class" "$failure_reason"; then
        return 2
    fi
    apo_state_clear_final_validation
    apo_state_fail "$failure_class" "$failure_reason"
    if [[ $(apo_state_get POST_FLOOR_FINAL 0) == 1 ]]; then
        apo_state_set POST_FLOOR_FINAL_STAGE FAILED
        apo_state_save
    fi
    return 1
}

apo_final_recovery_failure() {
    local failure_reason=$1
    apo_state_clear_final_validation
    apo_state_fail RECOVERY_FAILURE "$failure_reason"
    if [[ $(apo_state_get POST_FLOOR_FINAL 0) == 1 ]]; then
        apo_state_set POST_FLOOR_FINAL_STAGE FAILED
        apo_state_save
    fi
}

apo_final_validation() {
    local recommended_cpu recommended_gpu final_kind failure_class failure_reason stress_result_structured stage boot_number normal_number endurance_duration edge_target cpu_boundary failure_action_rc edge_order
    local final_boots=${APO_CFG[FINAL_BOOTS]}
    apo_validate_auto_resume_state || return 1
    edge_order=${APO_EDGE_ORDER:-floor-first}
    if (( ${APO_EDGE_CPU_24H:-0} == 1 )) && [[ $edge_order == edge-first && $(apo_state_get EDGE_CPU_STATUS NOT_REQUESTED) == NOT_REQUESTED ]]; then
        recommended_cpu=$(apo_state_get RECOMMENDED_CPU "$(apo_state_get SAFE_CPU '')")
        recommended_gpu=$(apo_state_get RECOMMENDED_GPU "$(apo_state_get SAFE_GPU '')")
        [[ -n $recommended_cpu && -n $recommended_gpu ]] || {
            apo_state_clear_final_validation
            apo_state_fail HARNESS_FAILURE 'The edge-first final sequence has no saved guarded floor.'
            return 1
        }
        edge_target=$((recommended_cpu + APO_AUTO_REFINE_STEP_MHZ))
        cpu_boundary=$(apo_state_get CPU_FAILURE_BOUNDARY '')
        apo_state_set FLOOR_CPU "$recommended_cpu"
        apo_state_set FLOOR_GPU "$recommended_gpu"
        apo_state_set FLOOR_DURATION_S ''
        apo_state_set FLOOR_VALIDATION_SCHEMA ''
        apo_state_set FLOOR_VALIDATED 0
        apo_state_set EDGE_CPU_TARGET "$edge_target"
        apo_state_clear_final_validation
        if (( edge_target > APO_AUTO_CPU_MAX_MHZ )) ||
           { [[ -n $cpu_boundary ]] && (( edge_target >= cpu_boundary )); }; then
            apo_state_set EDGE_CPU_STATUS SKIPPED_KNOWN_BOUNDARY
            apo_state_set FINAL_TARGET_CPU "$recommended_cpu"
            apo_state_set FINAL_TARGET_GPU "$recommended_gpu"
            apo_summary_line "EDGE CPU: SKIPPED — ${edge_target} MHz meets or exceeds the known failure/ceiling boundary; beginning fresh guarded-floor validation."
            apo_event edge-cpu WARN STABILITY_FAILURE "Skipped known unsafe edge CPU target $edge_target MHz; beginning guarded-floor validation at CPU=$recommended_cpu GPU=$recommended_gpu"
        else
            apo_state_set EDGE_CPU_STATUS RUNNING
            apo_state_set RECOMMENDED_CPU "$edge_target"
            apo_state_set RECOMMENDED_GPU "$recommended_gpu"
            apo_state_set FINAL_TARGET_CPU "$edge_target"
            apo_state_set FINAL_TARGET_GPU "$recommended_gpu"
            apo_summary_line "EDGE CPU: beginning ${APO_EDGE_DURATION_S}s combined validation at CPU $edge_target MHz / GPU $recommended_gpu MHz before committing time to the guarded floor."
            apo_event edge-cpu INFO '' "Beginning edge-first ${APO_EDGE_DURATION_S}s combined validation at CPU=$edge_target GPU=$recommended_gpu"
        fi
        apo_state_set FINAL_STAGE ''
        apo_state_set PHASE FINAL_VALIDATION
        apo_state_set SUBPHASE EDGE_FIRST_READY
        apo_state_set STATUS RUNNING
        apo_state_save
        apo_validate_auto_resume_state || return 1
    fi
    recommended_cpu=$(apo_state_get RECOMMENDED_CPU "$(apo_state_get SAFE_CPU '')")
    recommended_gpu=$(apo_state_get RECOMMENDED_GPU "$(apo_state_get SAFE_GPU '')")
    [[ -n $recommended_cpu && -n $recommended_gpu ]] || { apo_state_clear_final_validation; apo_state_fail HARNESS_FAILURE 'Final validation has no saved conservative recommendation.'; return 1; }
    final_kind=$([[ $APO_REQUIRE_GPU_STRESS == 1 ]] && printf combined || printf cpu)
    endurance_duration=${APO_CFG[FINAL_DURATION_S]}
    if [[ $(apo_state_get EDGE_CPU_STATUS NOT_REQUESTED) == RUNNING ]]; then
        endurance_duration=$APO_EDGE_DURATION_S
        [[ $APO_REQUIRE_GPU_STRESS == 1 ]] || {
            apo_state_fail HARNESS_FAILURE 'The optional CPU edge requires the qualified GPU workload; CPU-only edge validation is refused.'
            return 1
        }
        final_kind=combined
    fi
    if ! apo_final_identity_matches "$recommended_cpu" "$recommended_gpu" || [[ -z $(apo_state_get FINAL_STAGE '') ]]; then
        apo_state_clear_final_validation
        apo_final_checkpoint "$recommended_cpu" "$recommended_gpu" PRE_STRESS_BOOT
    fi
    while :; do
        stage=$(apo_state_get FINAL_STAGE PRE_STRESS_BOOT)
        case $stage in
            PRE_STRESS_BOOT)
                if ! apo_boot_candidate "$recommended_cpu" "$recommended_gpu" final-pre-stress-boot; then
                    failure_class=$APO_LAST_CLASS; failure_reason=$APO_LAST_REASON
                    if apo_final_record_failure final-pre-stress-recovery "$failure_class" "$failure_reason"; then return 0; else failure_action_rc=$?; fi
                    (( failure_action_rc == 2 )) && return 2
                    return 1
                fi
                apo_final_checkpoint "$recommended_cpu" "$recommended_gpu" ENDURANCE
                ;;
            ENDURANCE)
                if ! apo_candidate_tryboot_active_in_state "$recommended_cpu" "$recommended_gpu"; then
                    if ! apo_boot_candidate "$recommended_cpu" "$recommended_gpu" final-endurance-resume-boot; then
                        failure_class=$APO_LAST_CLASS; failure_reason=$APO_LAST_REASON
                        if apo_final_record_failure final-endurance-resume-recovery "$failure_class" "$failure_reason"; then return 0; else failure_action_rc=$?; fi
                        (( failure_action_rc == 2 )) && return 2
                        return 1
                    fi
                fi
                APO_LAST_RESULT_STRUCTURED=0
                if ! apo_run_stress "$final_kind" "$endurance_duration" final-endurance 1; then
                    failure_class=$APO_LAST_CLASS; failure_reason=$APO_LAST_REASON
                    stress_result_structured=${APO_LAST_RESULT_STRUCTURED:-0}
                    if apo_final_record_failure final-endurance-recovery "$failure_class" "$failure_reason" "$stress_result_structured"; then
                        return 0
                    else
                        failure_action_rc=$?
                    fi
                    (( failure_action_rc == 2 )) && return 2
                    return 1
                fi
                if ! apo_health_check "$recommended_cpu" "$recommended_gpu" "$APO_TEST_VOLTAGE" final-post-endurance-health; then
                    failure_class=$APO_LAST_CLASS; failure_reason=$APO_LAST_REASON
                    if apo_final_record_failure final-health-recovery "$failure_class" "$failure_reason"; then return 0; else failure_action_rc=$?; fi
                    (( failure_action_rc == 2 )) && return 2
                    return 1
                fi
                apo_state_set VALIDATION_DURATION_S "$endurance_duration"
                apo_final_checkpoint "$recommended_cpu" "$recommended_gpu" RETURN_NORMAL
                ;;
            RETURN_NORMAL)
                if ! apo_return_normal final-post-endurance-normal; then apo_final_recovery_failure "$APO_LAST_REASON"; return 1; fi
                apo_final_checkpoint "$recommended_cpu" "$recommended_gpu" BOOT_1
                ;;
            BOOT_*)
                if [[ ! $stage =~ ^BOOT_([1-9][0-9]*)$ ]]; then
                    apo_state_clear_final_validation
                    apo_state_fail HARNESS_FAILURE "Malformed saved final-validation boot stage: $stage"
                    return 1
                fi
                boot_number=$((10#${BASH_REMATCH[1]}))
                if (( boot_number > final_boots )); then
                    apo_state_clear_final_validation
                    apo_state_fail HARNESS_FAILURE "Saved final-validation boot $boot_number exceeds configured final_boots=$final_boots."
                    return 1
                fi
                if ! apo_boot_candidate "$recommended_cpu" "$recommended_gpu" "final-post-stress-boot-${boot_number}"; then
                    failure_class=$APO_LAST_CLASS; failure_reason=$APO_LAST_REASON
                    if apo_final_record_failure "final-post-stress-recovery-${boot_number}" "$failure_class" "$failure_reason"; then return 0; else failure_action_rc=$?; fi
                    (( failure_action_rc == 2 )) && return 2
                    return 1
                fi
                apo_final_checkpoint "$recommended_cpu" "$recommended_gpu" "NORMAL_${boot_number}"
                ;;
            NORMAL_*)
                if [[ ! $stage =~ ^NORMAL_([1-9][0-9]*)$ ]]; then
                    apo_state_clear_final_validation
                    apo_state_fail HARNESS_FAILURE "Malformed saved final-validation normal stage: $stage"
                    return 1
                fi
                normal_number=$((10#${BASH_REMATCH[1]}))
                if (( normal_number > final_boots )); then
                    apo_state_clear_final_validation
                    apo_state_fail HARNESS_FAILURE "Saved final-validation normal recovery $normal_number exceeds configured final_boots=$final_boots."
                    return 1
                fi
                if ! apo_return_normal "final-post-stress-normal-${normal_number}"; then apo_final_recovery_failure "$APO_LAST_REASON"; return 1; fi
                if (( normal_number < final_boots )); then
                    apo_final_checkpoint "$recommended_cpu" "$recommended_gpu" "BOOT_$((normal_number + 1))"
                else
                    apo_final_checkpoint "$recommended_cpu" "$recommended_gpu" VERIFY
                fi
                ;;
            VERIFY)
                if ! apo_verify_permanent_hash final-completion; then apo_final_recovery_failure "$APO_LAST_REASON"; return 1; fi
                if (( ${APO_EDGE_CPU_24H:-0} == 1 )) && [[ $edge_order == floor-first ]] &&
                   [[ $(apo_state_get EDGE_CPU_STATUS NOT_REQUESTED) == NOT_REQUESTED ]]; then
                    apo_state_set FLOOR_CPU "$recommended_cpu"
                    apo_state_set FLOOR_GPU "$recommended_gpu"
                    apo_state_set FLOOR_DURATION_S "${APO_CFG[FINAL_DURATION_S]}"
                    apo_state_set FLOOR_VALIDATION_SCHEMA "$APO_CURRENT_VALIDATION_SCHEMA"
                    apo_state_set FLOOR_VALIDATED 1
                    edge_target=$((recommended_cpu + APO_AUTO_REFINE_STEP_MHZ))
                    cpu_boundary=$(apo_state_get CPU_FAILURE_BOUNDARY '')
                    if (( edge_target > APO_AUTO_CPU_MAX_MHZ )) ||
                       { [[ -n $cpu_boundary ]] && (( edge_target >= cpu_boundary )); }; then
                        apo_state_set EDGE_CPU_TARGET "$edge_target"
                        apo_state_set EDGE_CPU_STATUS SKIPPED_KNOWN_BOUNDARY
                        apo_state_complete "$recommended_cpu" "$recommended_gpu" "${APO_CFG[FINAL_DURATION_S]}"
                        apo_summary_line "EDGE CPU: SKIPPED — ${edge_target} MHz meets or exceeds the known failure/ceiling boundary; retained validated production floor."
                        apo_event edge-cpu WARN STABILITY_FAILURE "Skipped known unsafe edge CPU target $edge_target MHz; retained validated production floor CPU=$recommended_cpu GPU=$recommended_gpu"
                        return 0
                    fi
                    apo_state_set EDGE_CPU_TARGET "$edge_target"
                    apo_state_set EDGE_CPU_STATUS RUNNING
                    apo_state_clear_final_validation
                    apo_state_set RECOMMENDED_CPU "$edge_target"
                    apo_state_set RECOMMENDED_GPU "$recommended_gpu"
                    apo_state_set FINAL_TARGET_CPU "$edge_target"
                    apo_state_set FINAL_TARGET_GPU "$recommended_gpu"
                    apo_state_set FINAL_STAGE PRE_STRESS_BOOT
                    apo_state_set PHASE FINAL_VALIDATION
                    apo_state_set SUBPHASE EDGE_CPU_24H_PRE_STRESS_BOOT
                    apo_state_set STATUS RUNNING
                    apo_state_save
                    apo_summary_line "PRODUCTION FLOOR: PASS — CPU $recommended_cpu MHz / GPU $recommended_gpu MHz for ${APO_CFG[FINAL_DURATION_S]}s; beginning ${APO_EDGE_DURATION_S}s CPU edge validation at $edge_target MHz."
                    apo_event production-floor PASS '' "${APO_CFG[FINAL_DURATION_S]}s production floor validated at CPU=$recommended_cpu GPU=$recommended_gpu; beginning ${APO_EDGE_DURATION_S}s CPU edge validation at $edge_target MHz"
                    recommended_cpu=$edge_target
                    endurance_duration=$APO_EDGE_DURATION_S
                    continue
                fi
                if [[ $(apo_state_get EDGE_CPU_STATUS NOT_REQUESTED) == RUNNING ]]; then
                    apo_state_set EDGE_CPU_STATUS PASS
                    apo_summary_line "EDGE CPU: PASS — CPU $recommended_cpu MHz / GPU $recommended_gpu MHz completed the full ${endurance_duration}s combined validation."
                elif [[ $edge_order == edge-first && $(apo_state_get FLOOR_VALIDATED 0) == 0 ]] &&
                     { [[ $(apo_state_get EDGE_CPU_STATUS NOT_REQUESTED) == REJECTED ]] ||
                       [[ $(apo_state_get EDGE_CPU_STATUS NOT_REQUESTED) == SKIPPED_KNOWN_BOUNDARY ]]; }; then
                    apo_state_set FLOOR_DURATION_S "${APO_CFG[FINAL_DURATION_S]}"
                    apo_state_set FLOOR_VALIDATION_SCHEMA "$APO_CURRENT_VALIDATION_SCHEMA"
                    apo_state_set FLOOR_VALIDATED 1
                    apo_summary_line "GUARDED FLOOR: PASS — CPU $recommended_cpu MHz / GPU $recommended_gpu MHz completed the full ${endurance_duration}s combined validation after the edge disposition."
                fi
                apo_state_complete "$recommended_cpu" "$recommended_gpu" "$endurance_duration"
                apo_summary_line ''
                apo_summary_line 'FINAL VALIDATION: PASS'
                apo_summary_line "Final validated clocks: over_voltage_delta=$APO_TEST_VOLTAGE, arm_freq=$recommended_cpu, $APO_GPU_KEY=$recommended_gpu"
                if (( ${APO_AUTO_APPLY:-0} == 1 )); then
                    apo_summary_line 'Permanent application is next in this overclock command; the exact diff will be retained and displayed.'
                else
                    apo_summary_line 'Permanent config was not modified. Use apply with the validated run for an exact diff and separate confirmation.'
                fi
                apo_event final-validation PASS '' "${endurance_duration}s endurance, post-stress health, ${final_boots} configured candidate boots, normal recovery, and permanent-config hash all passed."
                return 0
                ;;
            COMPLETE)
                [[ $(apo_state_get VALIDATED 0) == 1 && $(apo_state_get VALIDATION_SCHEMA '') == "$APO_CURRENT_VALIDATION_SCHEMA" ]] || {
                    apo_state_clear_final_validation
                    apo_state_fail HARNESS_FAILURE 'Saved final completion lacks current validation-schema evidence.'
                    return 1
                }
                return 0
                ;;
            *)
                apo_state_clear_final_validation
                apo_state_fail HARNESS_FAILURE "Unknown saved final-validation stage: $stage"
                return 1
                ;;
        esac
    done
}

apo_run_tuning() {
    local phase tuning_rc passed_cpu safe_cpu
    while :; do
        phase=$(apo_state_get PHASE TRYBOOT_PROOF)
        case $phase in
            TRYBOOT_PROOF)
                apo_prove_tryboot_recovery || return 1
                if (( APO_REQUIRE_GPU_STRESS == 1 )); then
                    apo_state_phase GPU_SMOKE READY RUNNING
                elif (( ${APO_MANUAL_TEST:-0} == 1 )); then
                    apo_state_phase MANUAL_TEST READY RUNNING
                else
                    apo_state_phase CPU_SWEEP READY RUNNING
                fi
                ;;
            GPU_SMOKE)
                apo_gpu_harness_smoke || return 1
                if (( ${APO_MANUAL_TEST:-0} == 1 )); then apo_state_phase MANUAL_TEST READY RUNNING
                else apo_state_phase CPU_SWEEP READY RUNNING; fi
                ;;
            MANUAL_TEST)
                apo_run_manual_test || return 1
                ;;
            CPU_SWEEP)
                apo_sweep_cpu || return 1
                apo_state_phase SELECTION CPU RUNNING
                ;;
            SELECTION)
                if [[ $(apo_state_get SUBPHASE) == CPU ]]; then
                    passed_cpu=$(apo_state_get PASSED_CPUS '')
                    if (( APO_AUTO_GENERATED_CANDIDATES == 1 )); then
                        safe_cpu=$(apo_state_get SAFE_CPU "$APO_NORMAL_CPU")
                    elif [[ -n $passed_cpu ]]; then
                        safe_cpu=$(apo_select_with_backoff "$passed_cpu" "${APO_CFG[BACKOFF_STEPS]}" "$APO_NORMAL_CPU")
                    else
                        safe_cpu=$APO_NORMAL_CPU
                    fi
                    apo_state_set SAFE_CPU "$safe_cpu"; apo_state_save
                    if (( APO_AUTO_GENERATED_CANDIDATES == 1 )); then
                        apo_state_set RECOMMENDED_CPU "$safe_cpu"
                        if [[ $(apo_state_get CPU_QUALIFIED_CLOCK '') != "$safe_cpu" ]]; then
                            apo_state_set CPU_QUALIFICATION_STATUS NOT_STARTED
                            apo_state_set CPU_QUALIFICATION_TARGET "$safe_cpu"
                            apo_state_set CPU_QUALIFIED_CLOCK ''
                        fi
                        apo_state_phase CPU_QUALIFICATION READY RUNNING
                    elif (( APO_NEED_GPU == 1 )); then
                        apo_state_phase GPU_SWEEP READY RUNNING
                    else
                        apo_select_conservative_clocks || return 1
                        apo_state_phase FINAL_VALIDATION READY RUNNING
                    fi
                else
                    apo_select_conservative_clocks || return 1
                    if (( APO_AUTO_GENERATED_CANDIDATES == 1 && APO_REQUIRE_GPU_STRESS == 1 )); then
                        apo_state_phase GPU_QUALIFICATION READY RUNNING
                    else
                        apo_state_phase FINAL_VALIDATION READY RUNNING
                    fi
                fi
                ;;
            CPU_QUALIFICATION)
                apo_qualify_cpu || return 1
                if (( APO_NEED_GPU == 1 )); then
                    if [[ $(apo_state_get GPU_GUARD_VERIFIED 0) == 1 ]]; then
                        apo_state_set GPU_QUALIFICATION_CPU "$(apo_state_get RECOMMENDED_CPU '')"
                        apo_state_set GPU_QUALIFICATION_TARGET "$(apo_state_get RECOMMENDED_GPU '')"
                        apo_state_phase GPU_QUALIFICATION READY RUNNING
                    else
                        apo_state_phase GPU_SWEEP READY RUNNING
                    fi
                else
                    apo_select_conservative_clocks || return 1
                    apo_state_phase FINAL_VALIDATION READY RUNNING
                fi
                ;;
            GPU_SWEEP)
                apo_sweep_gpu || return 1
                apo_state_phase SELECTION GPU RUNNING
                ;;
            GPU_QUALIFICATION)
                apo_qualify_gpu || return 1
                apo_state_phase FINAL_VALIDATION READY RUNNING
                ;;
            FINAL_VALIDATION)
                if apo_final_validation; then
                    :
                else
                    tuning_rc=$?
                    (( tuning_rc == 2 )) && continue
                    return 1
                fi
                ;;
            COMPLETE) return 0 ;;
            PREPARED) apo_state_phase TRYBOOT_PROOF READY RUNNING ;;
            *) apo_state_fail HARNESS_FAILURE "Unknown saved phase: $phase"; return 1 ;;
        esac
    done
}
