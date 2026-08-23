#!/usr/bin/env bash
# Local status and concise report generation.

apo_report_value() {
    local value=$1 replacement
    if [[ ${APO_REDACT:-0} == 1 ]]; then
        for replacement in "${APO_REMOTE_TARGET:-}" "${APO_TARGET_HOST:-}" "${APO_OUTPUT_DIR:-}" "${APO_REMOTE_USER:-}"; do
            [[ -n $replacement ]] || continue
            value=${value//"$replacement"/<redacted>}
        done
    fi
    printf '%s' "$value"
}

apo_report_state_value() {
    local state_key=$1 fallback=$2 value
    value=$(apo_state_get "$state_key" '')
    printf '%s' "${value:-$fallback}"
}

apo_print_status() {
    cat <<EOF_STATUS
AutoPiOverclock ${APO_VERSION}
Run ID:         $(apo_state_get RUN_ID)
Target:         $(apo_report_value "$(apo_state_get REMOTE_TARGET)")
Profile:        $(apo_report_state_value PROFILE unknown)
Mode:           $(apo_report_state_value MODE_EFFECTIVE unknown)
Status:         $(apo_report_state_value STATUS unknown)
Phase:          $(apo_report_state_value PHASE unknown)
Subphase:       $(apo_report_state_value SUBPHASE unknown)
Normal clocks:  CPU $(apo_report_state_value NORMAL_CPU '?') MHz / GPU $(apo_report_state_value NORMAL_GPU '?') MHz
Passed CPUs:    $(apo_report_state_value PASSED_CPUS none)
Passed GPUs:    $(apo_report_state_value PASSED_GPUS none)
Recommended:    CPU $(apo_report_state_value RECOMMENDED_CPU "$(apo_report_state_value SAFE_CPU pending)") MHz / GPU $(apo_report_state_value RECOMMENDED_GPU "$(apo_report_state_value SAFE_GPU pending)") MHz
Final clocks:   CPU $(apo_report_state_value FINAL_CPU pending) MHz / GPU $(apo_report_state_value FINAL_GPU pending) MHz
Validated:      $(apo_state_get VALIDATED 0)
Apply status:   $(apo_state_get APPLY_STATUS NOT_APPLIED)
Watchdog repair: $(apo_state_get WATCHDOG_REPAIR_STATUS NOT_STARTED)
Watchdog hashes: old=$(apo_report_state_value WATCHDOG_REPAIR_OLD_HASH none) expected=$(apo_report_state_value WATCHDOG_REPAIR_EXPECTED_HASH none) new=$(apo_report_state_value WATCHDOG_REPAIR_NEW_HASH none)
Failure class:  $(apo_state_get FAILURE_CLASS none)
Failure reason: $(apo_report_value "$(apo_state_get FAILURE_REASON none)")
State file:     $(apo_report_value "$APO_STATE_FILE")
EOF_STATUS
}

apo_generate_report() {
    local suffix='' report_file
    [[ ${APO_REDACT:-0} == 1 ]] && suffix=-public
    report_file="${APO_RUN_PREFIX}${suffix}-report.txt"
    {
        printf 'AutoPiOverclock run report\n'
        printf '==========================\n'
        printf 'Version: %s\n' "$APO_VERSION"
        printf 'Run ID: %s\n' "$(apo_state_get RUN_ID)"
        printf 'Target: %s\n' "$(apo_report_value "$(apo_state_get REMOTE_TARGET)")"
        printf 'Profile: %s\n' "$(apo_report_state_value PROFILE unknown)"
        printf 'Mode: %s\n' "$(apo_report_state_value MODE_EFFECTIVE unknown)"
        printf 'Status: %s\n' "$(apo_report_state_value STATUS unknown)"
        printf 'Phase: %s\n' "$(apo_report_state_value PHASE unknown)"
        printf 'Normal clocks: CPU %s MHz, GPU %s MHz\n' "$(apo_report_state_value NORMAL_CPU '?')" "$(apo_report_state_value NORMAL_GPU '?')"
        printf 'Maximum observed CPU passes: %s\n' "$(apo_report_state_value PASSED_CPUS none)"
        printf 'Maximum observed GPU passes: %s\n' "$(apo_report_state_value PASSED_GPUS none)"
        printf 'Conservative recommendation: CPU %s MHz, GPU %s MHz\n' "$(apo_report_state_value RECOMMENDED_CPU "$(apo_report_state_value SAFE_CPU pending)")" "$(apo_report_state_value RECOMMENDED_GPU "$(apo_report_state_value SAFE_GPU pending)")"
        printf 'Final validated clocks: CPU %s MHz, GPU %s MHz\n' "$(apo_report_state_value FINAL_CPU pending)" "$(apo_report_state_value FINAL_GPU pending)"
        printf 'Voltage delta: %s uV\n' "$(apo_state_get TEST_VOLTAGE '?')"
        printf 'Validated: %s\n' "$(apo_state_get VALIDATED 0)"
        printf 'Apply status: %s\n' "$(apo_state_get APPLY_STATUS NOT_APPLIED)"
        printf 'Watchdog repair: %s\n' "$(apo_state_get WATCHDOG_REPAIR_STATUS NOT_STARTED)"
        printf 'Watchdog repair hashes: old=%s, expected=%s, new=%s\n' \
            "$(apo_report_state_value WATCHDOG_REPAIR_OLD_HASH none)" "$(apo_report_state_value WATCHDOG_REPAIR_EXPECTED_HASH none)" "$(apo_report_state_value WATCHDOG_REPAIR_NEW_HASH none)"
        printf 'Failure class: %s\n' "$(apo_state_get FAILURE_CLASS none)"
        printf 'Failure reason: %s\n' "$(apo_report_value "$(apo_state_get FAILURE_REASON none)")"
        printf 'Storage layout: %s\n' "$(apo_report_value "$(apo_state_get STORAGE_LAYOUT unknown)")"
        printf '\nA short candidate pass is not described as long-term stability. VALIDATED=1 requires the configured endurance run and repeated post-stress boots.\n'
    } | tee "$report_file"
    chmod 600 "$report_file"
    printf '\nReport file: %s\n' "$(apo_report_value "$report_file")"
}
