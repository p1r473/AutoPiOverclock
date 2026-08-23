#!/usr/bin/env bash
# Candidate sweep, conservative selection, final endurance validation, and resume phases.

apo_gpu_harness_smoke() {
    local smoke_duration=20 failure_class failure_reason
    apo_state_phase GPU_SMOKE NORMAL_BASELINE RUNNING
    apo_event gpu-smoke INFO '' "Running a ${smoke_duration}s GPU harness smoke test at normal clocks before any GPU candidate or endurance run."
    if ! apo_run_stress gpu "$smoke_duration" gpu-harness-smoke 0; then
        failure_class=$APO_LAST_CLASS
        failure_reason=$APO_LAST_REASON
        apo_record_failure_after_recovery gpu-smoke-recovery-health "$failure_class" "$failure_reason"
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
    local cpu_mhz=$1 gpu_mhz=$2 label=$3 stress_kind=$4 stage failure_class failure_reason boot_number normal_number
    local candidate_boots=${APO_CFG[CANDIDATE_BOOTS]}
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
                if ! apo_run_stress "$stress_kind" "${APO_CFG[CANDIDATE_DURATION_S]}" "${label}-candidate" 0; then
                    failure_class=$APO_LAST_CLASS
                    failure_reason=$APO_LAST_REASON
                    apo_recover_preserving_failure "${label}-stress-recovery" "$failure_class" "$failure_reason" || return 1
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
                APO_LAST_REASON="Candidate passed ${candidate_boots} configured boot/normal cycles, overlapping stress, post-stress health, and final normal recovery."
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

apo_sweep_cpu() {
    local index candidate passed_csv stress_kind
    index=$(apo_state_get CPU_INDEX 0)
    passed_csv=$(apo_state_get PASSED_CPUS '')
    stress_kind=$([[ $APO_REQUIRE_GPU_STRESS == 1 ]] && printf combined || printf cpu)
    for (( ; index < ${#APO_CPU_CANDIDATES[@]}; index++ )); do
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
            if apo_class_is_edge_failure "$APO_LAST_CLASS"; then break; fi
            apo_state_fail "$APO_LAST_CLASS" "$APO_LAST_REASON"
            return 1
        fi
    done
    if (( ${#APO_CPU_CANDIDATES[@]} > 0 )) && [[ -z $passed_csv ]]; then
        apo_state_fail STABILITY_FAILURE 'No CPU candidate passed the complete candidate gate.'
        return 1
    fi
}

apo_sweep_gpu() {
    local index candidate passed_csv safe_cpu
    index=$(apo_state_get GPU_INDEX 0)
    passed_csv=$(apo_state_get PASSED_GPUS '')
    safe_cpu=$(apo_state_get SAFE_CPU "$APO_NORMAL_CPU")
    for (( ; index < ${#APO_GPU_CANDIDATES[@]}; index++ )); do
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
            if apo_class_is_edge_failure "$APO_LAST_CLASS"; then break; fi
            apo_state_fail "$APO_LAST_CLASS" "$APO_LAST_REASON"
            return 1
        fi
    done
    if (( ${#APO_GPU_CANDIDATES[@]} > 0 )) && [[ -z $passed_csv ]]; then
        apo_state_fail STABILITY_FAILURE 'No GPU candidate passed the complete candidate gate.'
        return 1
    fi
}

apo_select_conservative_clocks() {
    local passed_cpu passed_gpu recommended_cpu recommended_gpu
    passed_cpu=$(apo_state_get PASSED_CPUS '')
    passed_gpu=$(apo_state_get PASSED_GPUS '')
    if [[ -n $passed_cpu ]]; then recommended_cpu=$(apo_select_with_backoff "$passed_cpu" "${APO_CFG[BACKOFF_STEPS]}" "$APO_NORMAL_CPU"); else recommended_cpu=$APO_NORMAL_CPU; fi
    if [[ -n $passed_gpu ]]; then recommended_gpu=$(apo_select_with_backoff "$passed_gpu" "${APO_CFG[BACKOFF_STEPS]}" "$APO_NORMAL_GPU"); else recommended_gpu=$APO_NORMAL_GPU; fi
    apo_state_set SAFE_CPU "$recommended_cpu"
    apo_state_set SAFE_GPU "$recommended_gpu"
    apo_state_set RECOMMENDED_CPU "$recommended_cpu"
    apo_state_set RECOMMENDED_GPU "$recommended_gpu"
    apo_state_clear_final_validation
    apo_state_set FINAL_TARGET_CPU ''
    apo_state_set FINAL_TARGET_GPU ''
    apo_state_set FINAL_STAGE ''
    apo_state_save
    apo_summary_line ''
    apo_summary_line "Maximum observed CPU passes: ${passed_cpu:-none}"
    apo_summary_line "Maximum observed GPU passes: ${passed_gpu:-none}"
    apo_summary_line "Conservative recommendation after ${APO_CFG[BACKOFF_STEPS]} backoff step(s): CPU $recommended_cpu MHz / GPU $recommended_gpu MHz"
    apo_event selection PASS '' "Selected conservative recommendation CPU=$recommended_cpu GPU=$recommended_gpu; final clocks remain pending validation"
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

apo_final_record_failure() {
    local recovery_context=$1 failure_class=$2 failure_reason=$3
    apo_state_clear_final_validation
    apo_record_failure_after_recovery "$recovery_context" "$failure_class" "$failure_reason"
}

apo_final_recovery_failure() {
    local failure_reason=$1
    apo_state_clear_final_validation
    apo_state_fail RECOVERY_FAILURE "$failure_reason"
}

apo_final_validation() {
    local recommended_cpu recommended_gpu final_kind failure_class failure_reason stage boot_number normal_number
    local final_boots=${APO_CFG[FINAL_BOOTS]}
    recommended_cpu=$(apo_state_get RECOMMENDED_CPU "$(apo_state_get SAFE_CPU '')")
    recommended_gpu=$(apo_state_get RECOMMENDED_GPU "$(apo_state_get SAFE_GPU '')")
    [[ -n $recommended_cpu && -n $recommended_gpu ]] || { apo_state_clear_final_validation; apo_state_fail HARNESS_FAILURE 'Final validation has no saved conservative recommendation.'; return 1; }
    final_kind=$([[ $APO_REQUIRE_GPU_STRESS == 1 ]] && printf combined || printf cpu)
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
                    apo_final_record_failure final-pre-stress-recovery "$failure_class" "$failure_reason"
                    return 1
                fi
                apo_final_checkpoint "$recommended_cpu" "$recommended_gpu" CPU_STRESS
                ;;
            CPU_STRESS)
                if ! apo_candidate_tryboot_active_in_state "$recommended_cpu" "$recommended_gpu"; then
                    if ! apo_boot_candidate "$recommended_cpu" "$recommended_gpu" final-cpu-resume-boot; then
                        failure_class=$APO_LAST_CLASS; failure_reason=$APO_LAST_REASON
                        apo_final_record_failure final-cpu-resume-recovery "$failure_class" "$failure_reason"
                        return 1
                    fi
                fi
                if ! apo_run_stress cpu "${APO_CFG[CANDIDATE_DURATION_S]}" final-cpu-only 0; then
                    failure_class=$APO_LAST_CLASS; failure_reason=$APO_LAST_REASON
                    apo_final_record_failure final-cpu-recovery "$failure_class" "$failure_reason"
                    return 1
                fi
                if (( APO_REQUIRE_GPU_STRESS == 1 )); then
                    apo_final_checkpoint "$recommended_cpu" "$recommended_gpu" GPU_STRESS
                else
                    apo_final_checkpoint "$recommended_cpu" "$recommended_gpu" ENDURANCE
                fi
                ;;
            GPU_STRESS)
                if ! apo_candidate_tryboot_active_in_state "$recommended_cpu" "$recommended_gpu"; then
                    if ! apo_boot_candidate "$recommended_cpu" "$recommended_gpu" final-gpu-resume-boot; then
                        failure_class=$APO_LAST_CLASS; failure_reason=$APO_LAST_REASON
                        apo_final_record_failure final-gpu-resume-recovery "$failure_class" "$failure_reason"
                        return 1
                    fi
                fi
                if ! apo_run_stress gpu "${APO_CFG[CANDIDATE_DURATION_S]}" final-gpu-only 0; then
                    failure_class=$APO_LAST_CLASS; failure_reason=$APO_LAST_REASON
                    apo_final_record_failure final-gpu-recovery "$failure_class" "$failure_reason"
                    return 1
                fi
                apo_final_checkpoint "$recommended_cpu" "$recommended_gpu" ENDURANCE
                ;;
            ENDURANCE)
                if ! apo_candidate_tryboot_active_in_state "$recommended_cpu" "$recommended_gpu"; then
                    if ! apo_boot_candidate "$recommended_cpu" "$recommended_gpu" final-endurance-resume-boot; then
                        failure_class=$APO_LAST_CLASS; failure_reason=$APO_LAST_REASON
                        apo_final_record_failure final-endurance-resume-recovery "$failure_class" "$failure_reason"
                        return 1
                    fi
                fi
                if ! apo_run_stress "$final_kind" "${APO_CFG[FINAL_DURATION_S]}" final-endurance 1; then
                    failure_class=$APO_LAST_CLASS; failure_reason=$APO_LAST_REASON
                    apo_final_record_failure final-endurance-recovery "$failure_class" "$failure_reason"
                    return 1
                fi
                if ! apo_health_check "$recommended_cpu" "$recommended_gpu" "$APO_TEST_VOLTAGE" final-post-endurance-health; then
                    failure_class=$APO_LAST_CLASS; failure_reason=$APO_LAST_REASON
                    apo_final_record_failure final-health-recovery "$failure_class" "$failure_reason"
                    return 1
                fi
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
                    apo_final_record_failure "final-post-stress-recovery-${boot_number}" "$failure_class" "$failure_reason"
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
                apo_state_complete "$recommended_cpu" "$recommended_gpu"
                apo_summary_line ''
                apo_summary_line 'FINAL VALIDATION: PASS'
                apo_summary_line "Final validated clocks: over_voltage_delta=$APO_TEST_VOLTAGE, arm_freq=$recommended_cpu, $APO_GPU_KEY=$recommended_gpu"
                apo_summary_line 'Permanent config was not modified. Use apply with the validated run for an exact diff and separate confirmation.'
                apo_event final-validation PASS '' "Endurance, post-stress health, ${final_boots} configured candidate boots, normal recovery, and permanent-config hash all passed."
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
    local phase
    while :; do
        phase=$(apo_state_get PHASE TRYBOOT_PROOF)
        case $phase in
            TRYBOOT_PROOF)
                apo_prove_tryboot_recovery || return 1
                if (( APO_REQUIRE_GPU_STRESS == 1 )); then apo_state_phase GPU_SMOKE READY RUNNING; else apo_state_phase CPU_SWEEP READY RUNNING; fi
                ;;
            GPU_SMOKE)
                apo_gpu_harness_smoke || return 1
                apo_state_phase CPU_SWEEP READY RUNNING
                ;;
            CPU_SWEEP)
                apo_sweep_cpu || return 1
                apo_state_phase SELECTION CPU RUNNING
                ;;
            SELECTION)
                if [[ $(apo_state_get SUBPHASE) == CPU ]]; then
                    local passed_cpu safe_cpu
                    passed_cpu=$(apo_state_get PASSED_CPUS '')
                    if [[ -n $passed_cpu ]]; then safe_cpu=$(apo_select_with_backoff "$passed_cpu" "${APO_CFG[BACKOFF_STEPS]}" "$APO_NORMAL_CPU"); else safe_cpu=$APO_NORMAL_CPU; fi
                    apo_state_set SAFE_CPU "$safe_cpu"; apo_state_save
                    if (( APO_NEED_GPU == 1 )); then apo_state_phase GPU_SWEEP READY RUNNING; else apo_select_conservative_clocks; apo_state_phase FINAL_VALIDATION READY RUNNING; fi
                else
                    apo_select_conservative_clocks
                    apo_state_phase FINAL_VALIDATION READY RUNNING
                fi
                ;;
            GPU_SWEEP)
                apo_sweep_gpu || return 1
                apo_state_phase SELECTION GPU RUNNING
                ;;
            FINAL_VALIDATION)
                apo_final_validation || return 1
                ;;
            COMPLETE) return 0 ;;
            PREPARED) apo_state_phase TRYBOOT_PROOF READY RUNNING ;;
            *) apo_state_fail HARNESS_FAILURE "Unknown saved phase: $phase"; return 1 ;;
        esac
    done
}
