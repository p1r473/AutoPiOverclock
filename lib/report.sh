#!/usr/bin/env bash
# Local status and concise report generation.

: "${APO_TRANSIENT_PHASE_RETRY_MAX:=5}"

apo_report_sanitize_scalar() {
    # State is data, but an imported or corrupt value can still contain terminal
    # controls. Keep printable bytes unchanged and make every C0/DEL byte inert.
    printf '%s' "${1-}" | LC_ALL=C tr '\000-\037\177' '?'
}

apo_report_value() {
    local value=$1 replacement
    if [[ ${APO_REDACT:-0} == 1 ]]; then
        for replacement in "${APO_REMOTE_TARGET:-}" "${APO_TARGET_HOST:-}" "${APO_OUTPUT_DIR:-}" "${APO_REMOTE_USER:-}"; do
            [[ -n $replacement ]] || continue
            value=${value//"$replacement"/<redacted>}
        done
    fi
    apo_report_sanitize_scalar "$value"
}

# Free-form diagnostic text can contain identities, service names, addresses,
# or paths that are not represented by the small set of known target fields
# above.  A public report omits those values rather than pretending that
# substring replacement can make arbitrary worker output safe to share.
apo_report_sensitive_value() {
    local value=$1
    if [[ ${APO_REDACT:-0} == 1 ]]; then
        printf '<redacted>'
    else
        apo_report_value "$value"
    fi
}

apo_report_state_value() {
    local state_key=$1 fallback=$2 value
    value=$(apo_state_get "$state_key" '')
    apo_report_value "${value:-$fallback}"
}

apo_report_fan_policy() {
    case $(apo_state_get CFG_MAX_FAN 1) in
        1) printf enabled ;;
        0) printf disabled ;;
        *) printf invalid ;;
    esac
}

apo_print_status() {
    cat <<EOF_STATUS
AutoPiOverclock ${APO_VERSION}
Run ID:         $(apo_report_state_value RUN_ID unknown)
Command:        $(apo_report_state_value ORIGIN_COMMAND unknown)
Target:         $(apo_report_state_value REMOTE_TARGET unknown)
Profile:        $(apo_report_state_value PROFILE unknown)
Mode:           $(apo_report_state_value MODE_EFFECTIVE unknown)
Status:         $(apo_report_state_value STATUS unknown)
Phase:          $(apo_report_state_value PHASE unknown)
Subphase:       $(apo_report_state_value SUBPHASE unknown)
Normal clocks:  CPU $(apo_report_state_value NORMAL_CPU '?') MHz / GPU $(apo_report_state_value NORMAL_GPU '?') MHz
Auto baseline:  CPU $(apo_report_state_value AUTO_BASELINE_CPU n/a) MHz / GPU $(apo_report_state_value AUTO_BASELINE_GPU n/a) MHz
Passed CPUs:    $(apo_report_state_value PASSED_CPUS none)
Passed GPUs:    $(apo_report_state_value PASSED_GPUS none)
CPU boundary:   $(apo_report_state_value CPU_FAILURE_BOUNDARY none)
GPU boundary:   $(apo_report_state_value GPU_FAILURE_BOUNDARY none)
CPU qualify:    $(apo_report_state_value CPU_QUALIFICATION_STATUS NOT_STARTED) target=$(apo_report_state_value CPU_QUALIFICATION_TARGET pending)MHz qualified=$(apo_report_state_value CPU_QUALIFIED_CLOCK pending)MHz duration=$(apo_report_state_value CFG_QUALIFICATION_DURATION_S "$APO_DEFAULT_QUALIFICATION_DURATION_S")s
GPU qualify:    $(apo_report_state_value GPU_QUALIFICATION_STATUS NOT_STARTED) target=$(apo_report_state_value GPU_QUALIFICATION_CPU pending)/$(apo_report_state_value GPU_QUALIFICATION_TARGET pending)MHz qualified=$(apo_report_state_value GPU_QUALIFIED_CPU pending)/$(apo_report_state_value GPU_QUALIFIED_CLOCK pending)MHz duration=$(apo_report_state_value CFG_QUALIFICATION_DURATION_S "$APO_DEFAULT_QUALIFICATION_DURATION_S")s
Recommended:    CPU $(apo_report_state_value RECOMMENDED_CPU "$(apo_report_state_value SAFE_CPU pending)") MHz / GPU $(apo_report_state_value RECOMMENDED_GPU "$(apo_report_state_value SAFE_GPU pending)") MHz
Auto backoffs:  $(apo_report_state_value FINAL_BACKOFF_COUNT 0) ($(apo_report_state_value FINAL_BACKOFF_HISTORY none))
Validated floor: CPU $(apo_report_state_value FLOOR_CPU pending) MHz / GPU $(apo_report_state_value FLOOR_GPU pending) MHz ($(apo_report_state_value FLOOR_VALIDATED 0))
Edge CPU:       $(apo_report_state_value EDGE_CPU_STATUS NOT_REQUESTED) target=$(apo_report_state_value EDGE_CPU_TARGET none)MHz duration=$(apo_report_state_value CFG_EDGE_DURATION_S "$APO_DEFAULT_EDGE_DURATION_S")s order=$(apo_report_state_value CFG_EDGE_ORDER floor-first)
Edge source:    run=$(apo_report_state_value SOURCE_FLOOR_RUN_ID none) post-floor=$(apo_report_state_value POST_FLOOR_EDGE 0)
Final extension: $(apo_report_state_value POST_FLOOR_FINAL 0) source=$(apo_report_state_value SOURCE_FINAL_RUN_ID none) stage=$(apo_report_state_value POST_FLOOR_FINAL_STAGE none)
Duration policy: $(apo_report_state_value CFG_DURATION_POLICY default) qualification=$(apo_report_state_value CFG_QUALIFICATION_DURATION_S "$APO_DEFAULT_QUALIFICATION_DURATION_S")s floor-fallback=$(apo_report_state_value CFG_FINAL_DURATION_S "$APO_DEFAULT_FINAL_DURATION_S")s edge=$(apo_report_state_value CFG_EDGE_DURATION_S "$APO_DEFAULT_EDGE_DURATION_S")s
Max fan tuning: $(apo_report_fan_policy)
Manual test:    $(apo_report_state_value MANUAL_TEST_STATUS NOT_REQUESTED) CPU=$(apo_report_state_value MANUAL_CPU n/a)MHz GPU=$(apo_report_state_value MANUAL_GPU n/a)MHz duration=$(apo_report_state_value MANUAL_MINUTES n/a)min
Run max temp:   $(apo_report_state_value RUN_MAX_TEMP pending)C
Final clocks:   CPU $(apo_report_state_value FINAL_CPU pending) MHz / GPU $(apo_report_state_value FINAL_GPU pending) MHz
Validated:      $(apo_report_state_value VALIDATED 0)
Endurance proof: $(apo_report_state_value VALIDATION_DURATION_S pending)s
Apply status:   $(apo_report_state_value APPLY_STATUS NOT_APPLIED)
Watchdog repair: $(apo_report_state_value WATCHDOG_REPAIR_STATUS NOT_STARTED)
Watchdog hashes: old=$(apo_report_state_value WATCHDOG_REPAIR_OLD_HASH none) expected=$(apo_report_state_value WATCHDOG_REPAIR_EXPECTED_HASH none) new=$(apo_report_state_value WATCHDOG_REPAIR_NEW_HASH none)
SSH recovery:   $(apo_report_state_value RECOVERY_WAIT_STATUS IDLE) context=$(apo_report_state_value RECOVERY_WAIT_CONTEXT none) extended-waits=$(apo_report_state_value RECOVERY_WAIT_TIMEOUTS 0)
Gate retries:   $(apo_report_state_value TRANSIENT_RETRY_COUNT 0)/$APO_TRANSIENT_PHASE_RETRY_MAX context=$(apo_report_state_value TRANSIENT_RETRY_CONTEXT none)
Failure class:  $(apo_report_state_value FAILURE_CLASS none)
Failure reason: $(apo_report_sensitive_value "$(apo_report_state_value FAILURE_REASON none)")
State file:     $(apo_report_sensitive_value "$APO_STATE_FILE")
EOF_STATUS
}

apo_generate_report() {
    local report_file
    if [[ ${APO_REDACT:-0} == 1 ]]; then
        # Do not inherit APO_RUN_PREFIX: it contains the target slug.
        report_file="${APO_OUTPUT_DIR}/autopioverclock-${APO_RUN_ID}-public-report.txt"
    else
        report_file="${APO_RUN_PREFIX}-report.txt"
    fi
    {
        printf 'AutoPiOverclock run report\n'
        printf '==========================\n'
        printf 'Version: %s\n' "$APO_VERSION"
        printf 'Run ID: %s\n' "$(apo_report_state_value RUN_ID unknown)"
        printf 'Command: %s\n' "$(apo_report_state_value ORIGIN_COMMAND unknown)"
        printf 'Target: %s\n' "$(apo_report_state_value REMOTE_TARGET unknown)"
        printf 'Profile: %s\n' "$(apo_report_state_value PROFILE unknown)"
        printf 'Mode: %s\n' "$(apo_report_state_value MODE_EFFECTIVE unknown)"
        printf 'Status: %s\n' "$(apo_report_state_value STATUS unknown)"
        printf 'Phase: %s\n' "$(apo_report_state_value PHASE unknown)"
        printf 'Normal clocks: CPU %s MHz, GPU %s MHz\n' "$(apo_report_state_value NORMAL_CPU '?')" "$(apo_report_state_value NORMAL_GPU '?')"
        printf 'Immutable automatic baseline: CPU %s MHz, GPU %s MHz\n' "$(apo_report_state_value AUTO_BASELINE_CPU n/a)" "$(apo_report_state_value AUTO_BASELINE_GPU n/a)"
        printf 'Maximum observed CPU passes: %s\n' "$(apo_report_state_value PASSED_CPUS none)"
        printf 'Maximum observed GPU passes: %s\n' "$(apo_report_state_value PASSED_GPUS none)"
        printf 'CPU failure boundary: %s MHz\n' "$(apo_report_state_value CPU_FAILURE_BOUNDARY none)"
        printf 'GPU failure boundary: %s MHz\n' "$(apo_report_state_value GPU_FAILURE_BOUNDARY none)"
        printf 'CPU qualification: status=%s, target=%s MHz, qualified=%s MHz, duration=%ss\n' \
            "$(apo_report_state_value CPU_QUALIFICATION_STATUS NOT_STARTED)" "$(apo_report_state_value CPU_QUALIFICATION_TARGET pending)" \
            "$(apo_report_state_value CPU_QUALIFIED_CLOCK pending)" "$(apo_report_state_value CFG_QUALIFICATION_DURATION_S "$APO_DEFAULT_QUALIFICATION_DURATION_S")"
        printf 'GPU qualification: status=%s, target=%s/%s MHz, qualified=%s/%s MHz, duration=%ss\n' \
            "$(apo_report_state_value GPU_QUALIFICATION_STATUS NOT_STARTED)" "$(apo_report_state_value GPU_QUALIFICATION_CPU pending)" \
            "$(apo_report_state_value GPU_QUALIFICATION_TARGET pending)" "$(apo_report_state_value GPU_QUALIFIED_CPU pending)" \
            "$(apo_report_state_value GPU_QUALIFIED_CLOCK pending)" "$(apo_report_state_value CFG_QUALIFICATION_DURATION_S "$APO_DEFAULT_QUALIFICATION_DURATION_S")"
        printf 'Conservative recommendation: CPU %s MHz, GPU %s MHz\n' "$(apo_report_state_value RECOMMENDED_CPU "$(apo_report_state_value SAFE_CPU pending)")" "$(apo_report_state_value RECOMMENDED_GPU "$(apo_report_state_value SAFE_GPU pending)")"
        printf 'Automatic qualification/final backoffs: count=%s, target=%s/%s MHz, history=%s\n' \
            "$(apo_report_state_value FINAL_BACKOFF_COUNT 0)" "$(apo_report_state_value FINAL_BACKOFF_CPU none)" \
            "$(apo_report_state_value FINAL_BACKOFF_GPU none)" "$(apo_report_state_value FINAL_BACKOFF_HISTORY none)"
        printf 'Last automatic backoff boundary: stage=%s, class=%s, reason=%s\n' \
            "$(apo_report_state_value FINAL_BACKOFF_LAST_STAGE none)" "$(apo_report_state_value FINAL_BACKOFF_LAST_CLASS none)" \
            "$(apo_report_sensitive_value "$(apo_report_state_value FINAL_BACKOFF_LAST_REASON none)")"
        printf 'Validated production floor: CPU %s MHz, GPU %s MHz (validated=%s, duration=%ss)\n' \
            "$(apo_report_state_value FLOOR_CPU pending)" "$(apo_report_state_value FLOOR_GPU pending)" \
            "$(apo_report_state_value FLOOR_VALIDATED 0)" "$(apo_report_state_value FLOOR_DURATION_S pending)"
        printf 'Edge CPU: status=%s, target=%s MHz, duration=%ss, order=%s\n' \
            "$(apo_report_state_value EDGE_CPU_STATUS NOT_REQUESTED)" "$(apo_report_state_value EDGE_CPU_TARGET none)" \
            "$(apo_report_state_value CFG_EDGE_DURATION_S "$APO_DEFAULT_EDGE_DURATION_S")" "$(apo_report_state_value CFG_EDGE_ORDER floor-first)"
        printf 'Post-floor edge source: enabled=%s, run=%s, permanent-hash=%s\n' \
            "$(apo_report_state_value POST_FLOOR_EDGE 0)" "$(apo_report_state_value SOURCE_FLOOR_RUN_ID none)" \
            "$(apo_report_state_value SOURCE_FLOOR_PERMANENT_HASH none)"
        printf 'Maximum fan cooling during tuning: %s\n' \
            "$(apo_report_fan_policy)"
        printf 'Longer final extension: enabled=%s, source=%s, stage=%s\n' \
            "$(apo_report_state_value POST_FLOOR_FINAL 0)" "$(apo_report_state_value SOURCE_FINAL_RUN_ID none)" \
            "$(apo_report_state_value POST_FLOOR_FINAL_STAGE none)"
        printf 'Duration policy: %s (qualification=%ss each, floor-fallback=%ss, edge=%ss)\n' \
            "$(apo_report_state_value CFG_DURATION_POLICY default)" \
            "$(apo_report_state_value CFG_QUALIFICATION_DURATION_S "$APO_DEFAULT_QUALIFICATION_DURATION_S")" \
            "$(apo_report_state_value CFG_FINAL_DURATION_S "$APO_DEFAULT_FINAL_DURATION_S")" \
            "$(apo_report_state_value CFG_EDGE_DURATION_S "$APO_DEFAULT_EDGE_DURATION_S")"
        printf 'Manual stability test: status=%s, CPU=%s MHz, GPU=%s MHz, duration=%s minutes\n' \
            "$(apo_report_state_value MANUAL_TEST_STATUS NOT_REQUESTED)" "$(apo_report_state_value MANUAL_CPU n/a)" \
            "$(apo_report_state_value MANUAL_GPU n/a)" "$(apo_report_state_value MANUAL_MINUTES n/a)"
        printf 'Maximum observed run temperature: %sC\n' "$(apo_report_state_value RUN_MAX_TEMP pending)"
        printf 'Edge failure: class=%s, reason=%s\n' \
            "$(apo_report_state_value EDGE_CPU_FAILURE_CLASS none)" "$(apo_report_sensitive_value "$(apo_report_state_value EDGE_CPU_FAILURE_REASON none)")"
        printf 'Final validated clocks: CPU %s MHz, GPU %s MHz\n' "$(apo_report_state_value FINAL_CPU pending)" "$(apo_report_state_value FINAL_GPU pending)"
        printf 'Voltage delta: %s uV\n' "$(apo_report_state_value TEST_VOLTAGE '?')"
        printf 'Validated: %s\n' "$(apo_report_state_value VALIDATED 0)"
        printf 'Completed final endurance: %s seconds\n' "$(apo_report_state_value VALIDATION_DURATION_S pending)"
        printf 'Apply status: %s\n' "$(apo_report_state_value APPLY_STATUS NOT_APPLIED)"
        printf 'Watchdog repair: %s\n' "$(apo_report_state_value WATCHDOG_REPAIR_STATUS NOT_STARTED)"
        printf 'Watchdog repair hashes: old=%s, expected=%s, new=%s\n' \
            "$(apo_report_state_value WATCHDOG_REPAIR_OLD_HASH none)" "$(apo_report_state_value WATCHDOG_REPAIR_EXPECTED_HASH none)" "$(apo_report_state_value WATCHDOG_REPAIR_NEW_HASH none)"
        printf 'Extended SSH recovery: status=%s, context=%s, waits=%s\n' \
            "$(apo_report_state_value RECOVERY_WAIT_STATUS IDLE)" "$(apo_report_state_value RECOVERY_WAIT_CONTEXT none)" "$(apo_report_state_value RECOVERY_WAIT_TIMEOUTS 0)"
        printf 'Automatic gate retries: %s/%s, context=%s\n' \
            "$(apo_report_state_value TRANSIENT_RETRY_COUNT 0)" "$APO_TRANSIENT_PHASE_RETRY_MAX" "$(apo_report_state_value TRANSIENT_RETRY_CONTEXT none)"
        printf 'Failure class: %s\n' "$(apo_report_state_value FAILURE_CLASS none)"
        printf 'Failure reason: %s\n' "$(apo_report_sensitive_value "$(apo_report_state_value FAILURE_REASON none)")"
        printf 'Storage layout: %s\n' "$(apo_report_sensitive_value "$(apo_report_state_value STORAGE_LAYOUT unknown)")"
        if [[ ${APO_REDACT:-0} == 1 ]]; then
            printf 'Redaction note: Free-form diagnostic reasons and storage details were omitted. Review this file before sharing it.\n'
        fi
        printf '\nA short candidate pass is not described as long-term stability. VALIDATED=1 requires the configured endurance run and repeated post-stress boots.\n'
    } | tee "$report_file"
    chmod 600 "$report_file"
    if [[ ${APO_REDACT:-0} == 1 ]]; then
        # Do not substring-redact a path: a target name can overlap its parent
        # directory and prevent a later replacement from hiding that directory.
        printf '\nReport file: <redacted>/%s\n' "$(basename "$report_file")"
    else
        printf '\nReport file: %s\n' "$report_file"
    fi
}
