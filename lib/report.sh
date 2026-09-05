#!/usr/bin/env bash
# Local status and concise report generation.

: "${APO_TRANSIENT_PHASE_RETRY_MAX:=5}"
: "${APO_STATUS_CAPTURE_ATTEMPTS:=3}"
: "${APO_STATUS_CAPTURE_DELAY_SECONDS:=2}"

declare -Ag APO_STATUS_LIVE=()
APO_STATUS_LIVE_STATE=NOT_CHECKED
APO_STATUS_CONTROLLER_STATE=UNKNOWN
APO_STATUS_VALIDATED_RUN_ID=''
APO_STATUS_VERDICT=UNKNOWN
APO_STATUS_TRYBOOT=UNKNOWN
APO_STATUS_HEALTH=UNKNOWN

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

apo_report_selection_policy() {
    apo_state_get CFG_SELECTION_POLICY guarded-v1
}

apo_status_controller_state() {
    local lock_file="${APO_OUTPUT_DIR}/.${APO_TARGET_SLUG}.lock" lock_fd
    if ! command -v flock >/dev/null 2>&1; then
        APO_STATUS_CONTROLLER_STATE=UNKNOWN
        return 0
    fi
    if [[ ! -e $lock_file && ! -L $lock_file ]]; then
        APO_STATUS_CONTROLLER_STATE=IDLE
        return 0
    fi
    if [[ -L $lock_file || ! -f $lock_file ]]; then
        APO_STATUS_CONTROLLER_STATE=UNKNOWN
        return 0
    fi
    if ! { exec {lock_fd}<"$lock_file"; } 2>/dev/null; then
        APO_STATUS_CONTROLLER_STATE=UNKNOWN
        return 0
    fi
    if flock -n -s "$lock_fd" 2>/dev/null; then
        APO_STATUS_CONTROLLER_STATE=IDLE
        flock -u "$lock_fd" 2>/dev/null || true
    else
        APO_STATUS_CONTROLLER_STATE=ACTIVE
    fi
    exec {lock_fd}<&-
}

apo_status_probe_target() {
    local probe='' attempt profile uid sudo_ready
    [[ $APO_STATUS_CAPTURE_ATTEMPTS =~ ^[1-9][0-9]*$ ]] || APO_STATUS_CAPTURE_ATTEMPTS=3
    [[ $APO_STATUS_CAPTURE_DELAY_SECONDS =~ ^[0-9]+$ ]] || APO_STATUS_CAPTURE_DELAY_SECONDS=2
    for (( attempt=1; attempt<=APO_STATUS_CAPTURE_ATTEMPTS; attempt++ )); do
        probe=''
        if probe=$(apo_ssh_exec 'profile=unsupported; if [ -f /usr/share/batocera/batocera.version ] || command -v batocera-version >/dev/null 2>&1; then profile=batocera; elif [ -r /etc/os-release ]; then . /etc/os-release; case "${ID:-}" in raspbian|debian|ubuntu) profile=debian ;; esac; fi; uid=$(id -u 2>/dev/null || true); sudo_ready=no; if [ "$uid" = 0 ] || sudo -n true >/dev/null 2>&1; then sudo_ready=yes; fi; printf "%s\t%s\t%s\n" "$profile" "$uid" "$sudo_ready"' 2>/dev/null); then
            IFS=$'\t' read -r profile uid sudo_ready <<< "$probe"
            if [[ ( $profile == debian || $profile == batocera ) && $uid =~ ^[0-9]+$ ]]; then
                printf '%s\t%s\t%s\n' "$profile" "$uid" "$sudo_ready"
                return 0
            fi
        fi
        if (( attempt < APO_STATUS_CAPTURE_ATTEMPTS && APO_STATUS_CAPTURE_DELAY_SECONDS > 0 )); then
            sleep "$APO_STATUS_CAPTURE_DELAY_SECONDS"
        fi
    done
    return 1
}

apo_status_capture_live() {
    local probe profile uid sudo_ready wrapper worker output_file remote_rc attempt
    APO_STATUS_LIVE=()
    APO_STATUS_LIVE_STATE=UNAVAILABLE
    probe=$(apo_status_probe_target) || return 1
    IFS=$'\t' read -r profile uid sudo_ready <<< "$probe"
    worker="${APO_ROOT}/workers/${profile}-worker.sh"
    [[ -r $worker ]] || return 1
    if [[ $uid == 0 ]]; then
        wrapper='/bin/bash -s -- status-snapshot'
    elif [[ $sudo_ready == yes ]]; then
        wrapper='sudo -n /bin/bash -s -- status-snapshot'
    else
        wrapper='/bin/bash -s -- status-snapshot'
    fi
    output_file=$(mktemp /tmp/autopioverclock-status.XXXXXX) || return 1
    for (( attempt=1; attempt<=APO_STATUS_CAPTURE_ATTEMPTS; attempt++ )); do
        : > "$output_file"
        set +e
        command ssh "${APO_SSH_OPTIONS[@]}" -T "$APO_REMOTE_TARGET" "$wrapper" < "$worker" > "$output_file" 2>&1
        remote_rc=$?
        set -e
        apo_classify_output "$output_file" live-status
        if (( remote_rc == 0 )) && [[ $APO_LAST_CLASS == PASS ]]; then
            apo_parse_data_file "$output_file" APO_STATUS_LIVE
            if [[ ${APO_STATUS_LIVE[PROFILE]:-} == "$profile" &&
                  ${APO_STATUS_LIVE[CONFIG_CPU]:-} =~ ^[0-9]+$ &&
                  ${APO_STATUS_LIVE[CONFIG_GPU]:-} =~ ^[0-9]+$ &&
                  ${APO_STATUS_LIVE[PERMANENT_HASH]:-} =~ ^[0-9a-f]{64}$ ]]; then
                APO_STATUS_LIVE_STATE=AVAILABLE
                rm -f -- "$output_file"
                return 0
            fi
        fi
        if (( attempt < APO_STATUS_CAPTURE_ATTEMPTS && APO_STATUS_CAPTURE_DELAY_SECONDS > 0 )); then
            sleep "$APO_STATUS_CAPTURE_DELAY_SECONDS"
        fi
    done
    rm -f -- "$output_file"
    return 1
}

apo_find_latest_tuning_state_file() {
    local candidate newest='' origin target_slug remote_target
    local -A fields=()
    for candidate in "${APO_OUTPUT_DIR}/${APO_TARGET_SLUG}-"*.state; do
        [[ -f $candidate && ! -L $candidate ]] || continue
        apo_state_load_fields "$candidate" fields FORMAT_VERSION RUN_ID TARGET_SLUG REMOTE_TARGET ORIGIN_COMMAND || continue
        [[ ${fields[FORMAT_VERSION]:-} == 1 ]] || continue
        target_slug=${fields[TARGET_SLUG]:-}
        remote_target=${fields[REMOTE_TARGET]:-}
        [[ $target_slug == "$APO_TARGET_SLUG" ]] || continue
        [[ $remote_target == "$APO_REMOTE_TARGET" ]] || continue
        origin=${fields[ORIGIN_COMMAND]:-}
        case $origin in overclock|run|test) ;; *) continue ;; esac
        [[ -z $newest || $candidate -nt $newest ]] && newest=$candidate
    done
    [[ -n $newest ]] || return 1
    printf '%s' "$newest"
}

apo_status_find_validated_match() {
    local candidate newest='' expected_hash
    local live_hash=${APO_STATUS_LIVE[PERMANENT_HASH]:-}
    local live_cpu=${APO_STATUS_LIVE[CONFIG_CPU]:-} live_gpu=${APO_STATUS_LIVE[CONFIG_GPU]:-}
    local -A fields=()
    APO_STATUS_VALIDATED_RUN_ID=''
    [[ $APO_STATUS_LIVE_STATE == AVAILABLE ]] || return 1
    for candidate in "${APO_OUTPUT_DIR}/${APO_TARGET_SLUG}-"*.state; do
        [[ -f $candidate && ! -L $candidate ]] || continue
        apo_state_load_fields "$candidate" fields \
            FORMAT_VERSION RUN_SCHEMA VALIDATION_SCHEMA RUN_ID TARGET_SLUG REMOTE_TARGET ORIGIN_COMMAND STATUS PHASE FINAL_STAGE \
            VALIDATED APPLY_STATUS PERMANENT_HASH APPLY_EXPECTED_HASH FINAL_CPU FINAL_GPU || continue
        case ${fields[ORIGIN_COMMAND]:-} in overclock|run) ;; *) continue ;; esac
        [[ ${fields[FORMAT_VERSION]:-} == 1 &&
           ${fields[RUN_SCHEMA]:-} == "$APO_CURRENT_RUN_SCHEMA" &&
           ${fields[VALIDATION_SCHEMA]:-} == "$APO_CURRENT_VALIDATION_SCHEMA" &&
           ${fields[TARGET_SLUG]:-} == "$APO_TARGET_SLUG" &&
           ${fields[REMOTE_TARGET]:-} == "$APO_REMOTE_TARGET" &&
           ${fields[STATUS]:-} == PASS && ${fields[PHASE]:-} == COMPLETE &&
           ${fields[FINAL_STAGE]:-} == COMPLETE && ${fields[VALIDATED]:-} == 1 &&
           ${fields[APPLY_STATUS]:-} == APPLIED ]] || continue
        expected_hash=${fields[APPLY_EXPECTED_HASH]:-${fields[PERMANENT_HASH]:-}}
        [[ $expected_hash == "$live_hash" && ${fields[FINAL_CPU]:-} == "$live_cpu" &&
           ${fields[FINAL_GPU]:-} == "$live_gpu" ]] || continue
        if [[ -z $newest || $candidate -nt $newest ]]; then
            newest=$candidate
            APO_STATUS_VALIDATED_RUN_ID=${fields[RUN_ID]:-}
        fi
    done
    [[ -n $APO_STATUS_VALIDATED_RUN_ID ]]
}

apo_status_evaluate() {
    local current_throttle recent_throttle current_word recent_word provenance saved_status saved_apply
    APO_STATUS_TRYBOOT=UNKNOWN
    APO_STATUS_HEALTH=UNKNOWN
    APO_STATUS_VERDICT=UNKNOWN
    saved_status=$(apo_state_get STATUS '')
    saved_apply=$(apo_state_get APPLY_STATUS '')

    if [[ $APO_STATUS_LIVE_STATE == AVAILABLE ]]; then
        case ${APO_STATUS_LIVE[TRYBOOT_FLAG]:-unavailable}:${APO_STATUS_LIVE[TRYBOOT_EXISTS]:-} in
            00000001:*) APO_STATUS_TRYBOOT=ACTIVE ;;
            00000000:0) APO_STATUS_TRYBOOT=CLEAR ;;
            00000000:1) APO_STATUS_TRYBOOT='FILE PRESENT' ;;
            *) APO_STATUS_TRYBOOT=UNKNOWN ;;
        esac
        current_throttle=${APO_STATUS_LIVE[THROTTLED]:-}
        recent_throttle=${APO_STATUS_LIVE[RECENT_THROTTLED]:-}
        if current_word=$(apo_throttle_word "$current_throttle") && recent_word=$(apo_throttle_word "$recent_throttle"); then
            if (( current_word == 0 && recent_word == 0 )); then
                APO_STATUS_HEALTH=GOOD
            else
                APO_STATUS_HEALTH=ATTENTION
            fi
        fi
    fi

    if [[ $APO_STATUS_CONTROLLER_STATE == ACTIVE ]]; then
        APO_STATUS_VERDICT='IN PROGRESS'
        return 0
    fi
    if [[ $APO_STATUS_LIVE_STATE != AVAILABLE ]]; then
        if [[ $saved_status == RUNNING || $saved_status == PREPARING ]]; then
            APO_STATUS_VERDICT='INTERRUPTED / TARGET UNREACHABLE'
        else
            APO_STATUS_VERDICT='TARGET UNREACHABLE'
        fi
        return 0
    fi
    if [[ $APO_STATUS_TRYBOOT == ACTIVE || $APO_STATUS_TRYBOOT == 'FILE PRESENT' ||
          $saved_apply == FAILED_NEEDS_MANUAL_RECOVERY || $(apo_state_get TRYBOOT_EXPECTED 0) == 1 ||
          $(apo_state_get TRYBOOT_FILE_MAY_EXIST 0) == 1 ]]; then
        APO_STATUS_VERDICT='RECOVERY NEEDED'
        return 0
    fi
    if [[ $APO_STATUS_TRYBOOT == UNKNOWN ]]; then
        APO_STATUS_VERDICT='CONFIG NEEDS REVIEW'
        return 0
    fi
    if [[ $saved_status == RUNNING || $saved_status == PREPARING || $saved_status == INTERRUPTED ]]; then
        APO_STATUS_VERDICT='INTERRUPTED / RESUME AVAILABLE'
        return 0
    fi
    if [[ -n $APO_STATUS_VALIDATED_RUN_ID ]]; then
        APO_STATUS_VERDICT='OVERCLOCKED / VALIDATED'
        return 0
    fi
    provenance=${APO_STATUS_LIVE[PERMANENT_TUNING_PROVENANCE]:-ambiguous}
    case $provenance in
        verified-default) APO_STATUS_VERDICT='STOCK / RESET' ;;
        explicit-override) APO_STATUS_VERDICT='OVERCLOCKED / UNVERIFIED' ;;
        *) APO_STATUS_VERDICT='CONFIG NEEDS REVIEW' ;;
    esac
}

apo_status_collect() {
    apo_status_controller_state
    apo_status_capture_live || true
    apo_status_find_validated_match || true
    apo_status_evaluate
}

apo_report_duration() {
    local seconds=${1:-} hours minutes
    [[ $seconds =~ ^[0-9]+$ ]] || { printf unknown; return 0; }
    hours=$((seconds / 3600))
    minutes=$(((seconds % 3600) / 60))
    if (( hours > 0 && minutes > 0 )); then printf '%dh%02dm' "$hours" "$minutes"
    elif (( hours > 0 )); then printf '%dh' "$hours"
    elif (( minutes > 0 )); then printf '%dm' "$minutes"
    else printf '%ss' "$seconds"; fi
}

apo_report_manual_duration() {
    local seconds minutes
    seconds=$(apo_state_get MANUAL_DURATION_S "$(apo_state_get CFG_MANUAL_DURATION_S '')")
    if [[ $seconds =~ ^[0-9]+$ ]]; then
        apo_report_duration "$seconds"
        return 0
    fi
    minutes=$(apo_state_get MANUAL_MINUTES "$(apo_state_get CFG_MANUAL_MINUTES '')")
    if [[ $minutes =~ ^[0-9]+$ ]]; then
        apo_report_duration "$((minutes * 60))"
    else
        printf n/a
    fi
}

apo_report_friendly_phase() {
    case ${1:-} in
        TRYBOOT_PROOF) printf 'baseline safety proof' ;;
        GPU_SMOKE) printf 'GPU harness check' ;;
        CPU_SWEEP) printf 'CPU sweep' ;;
        CPU_QUALIFICATION) printf 'CPU qualification' ;;
        GPU_SWEEP) printf 'GPU sweep' ;;
        GPU_QUALIFICATION) printf 'GPU qualification' ;;
        FINAL_VALIDATION) printf 'final validation' ;;
        MANUAL_TEST) printf 'manual stability test' ;;
        COMPLETE) printf complete ;;
        PREPARE|PREPARED) printf preparation ;;
        '') printf unknown ;;
        *) apo_report_value "$1" ;;
    esac
}

apo_print_live_status() {
    local target cpu gpu measured_cpu measured_gpu profile temp uptime validated_run
    target=$(apo_report_value "${APO_REMOTE_TARGET:-unknown}")
    if [[ $APO_STATUS_LIVE_STATE == AVAILABLE ]]; then
        cpu=$(apo_report_value "${APO_STATUS_LIVE[CONFIG_CPU]:-unknown}")
        gpu=$(apo_report_value "${APO_STATUS_LIVE[CONFIG_GPU]:-unknown}")
        measured_cpu=$(apo_report_value "${APO_STATUS_LIVE[MEASURED_CPU]:-unknown}")
        measured_gpu=$(apo_report_value "${APO_STATUS_LIVE[MEASURED_GPU]:-unknown}")
        profile=$(apo_report_value "${APO_STATUS_LIVE[PROFILE]:-unknown}")
        temp=$(apo_report_value "${APO_STATUS_LIVE[TEMP]:-unknown}")
        uptime=$(apo_report_duration "${APO_STATUS_LIVE[UPTIME_SECONDS]:-}")
    else
        cpu=unavailable gpu=unavailable measured_cpu=unavailable measured_gpu=unavailable
        profile=unavailable temp=unavailable uptime=unavailable
    fi
    validated_run=${APO_STATUS_VALIDATED_RUN_ID:-none}
    [[ ${APO_REDACT:-0} == 0 ]] || validated_run='<redacted>'
    cat <<EOF_LIVE
Current target
==============
Target:         $target
Verdict:        $(apo_report_value "$APO_STATUS_VERDICT")
Controller:     $(apo_report_value "$APO_STATUS_CONTROLLER_STATE")
Profile:        $profile
Active clocks:  CPU $cpu MHz / GPU $gpu MHz
Measured now:   CPU $measured_cpu MHz / GPU $measured_gpu MHz
Quick health:   $(apo_report_value "$APO_STATUS_HEALTH") (throttle evidence only; not a stability test)
Tryboot:        $(apo_report_value "$APO_STATUS_TRYBOOT")
Temperature:    ${temp}C
Uptime:         $uptime
Validated run:  $(apo_report_value "$validated_run")
EOF_LIVE
}

apo_print_saved_status() {
    local policy sweep_domain
    policy=$(apo_report_selection_policy)
    sweep_domain=$(apo_state_get CFG_SWEEP_DOMAIN all)
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
Sweep scope:    $(apo_report_state_value CFG_SWEEP_DOMAIN all)
Selection:      $(apo_report_state_value CFG_SELECTION_POLICY guarded-v1)
Requested start: CPU $(apo_report_state_value CFG_CPU_START_AT auto) MHz / GPU $(apo_report_state_value CFG_GPU_START_AT auto) MHz
Normal clocks:  CPU $(apo_report_state_value NORMAL_CPU '?') MHz / GPU $(apo_report_state_value NORMAL_GPU '?') MHz
Auto baseline:  CPU $(apo_report_state_value AUTO_BASELINE_CPU n/a) MHz / GPU $(apo_report_state_value AUTO_BASELINE_GPU n/a) MHz
EOF_STATUS
    if [[ $sweep_domain != all ]]; then
        printf 'Applied source: run=%s CPU=%sMHz GPU=%sMHz hash=%s\n' \
            "$(apo_report_state_value SOURCE_APPLIED_RUN_ID missing)" \
            "$(apo_report_state_value SOURCE_APPLIED_CPU missing)" \
            "$(apo_report_state_value SOURCE_APPLIED_GPU missing)" \
            "$(apo_report_state_value SOURCE_APPLIED_PERMANENT_HASH missing)"
    fi
    cat <<EOF_STATUS
Passed CPUs:    $(apo_report_state_value PASSED_CPUS none)
Passed GPUs:    $(apo_report_state_value PASSED_GPUS none)
CPU boundary:   $(apo_report_state_value CPU_FAILURE_BOUNDARY none)
GPU boundary:   $(apo_report_state_value GPU_FAILURE_BOUNDARY none)
CPU qualify:    $(apo_report_state_value CPU_QUALIFICATION_STATUS NOT_STARTED) target=$(apo_report_state_value CPU_QUALIFICATION_TARGET pending)MHz qualified=$(apo_report_state_value CPU_QUALIFIED_CLOCK pending)MHz duration=$(apo_report_state_value CFG_QUALIFICATION_DURATION_S "$APO_DEFAULT_QUALIFICATION_DURATION_S")s
GPU qualify:    $(apo_report_state_value GPU_QUALIFICATION_STATUS NOT_STARTED) target=$(apo_report_state_value GPU_QUALIFICATION_CPU pending)/$(apo_report_state_value GPU_QUALIFICATION_TARGET pending)MHz qualified=$(apo_report_state_value GPU_QUALIFIED_CPU pending)/$(apo_report_state_value GPU_QUALIFIED_CLOCK pending)MHz duration=$(apo_report_state_value CFG_QUALIFICATION_DURATION_S "$APO_DEFAULT_QUALIFICATION_DURATION_S")s
EOF_STATUS
    if [[ $policy == refined-max-25 ]]; then
        printf 'Selected clocks: CPU %s MHz / GPU %s MHz\n' \
            "$(apo_report_state_value RECOMMENDED_CPU "$(apo_report_state_value SAFE_CPU pending)")" \
            "$(apo_report_state_value RECOMMENDED_GPU "$(apo_report_state_value SAFE_GPU pending)")"
        printf 'Final duration:  %ss uninterrupted; failed attempts receive no time credit\n' \
            "$(apo_report_state_value CFG_FINAL_DURATION_S "$APO_DEFAULT_FINAL_DURATION_S")"
        printf 'Final recovery:  anchor=%s/%sMHz trial=%s history=%s\n' \
            "$(apo_report_state_value FINAL_BACKOFF_ANCHOR_CPU none)" \
            "$(apo_report_state_value FINAL_BACKOFF_ANCHOR_GPU none)" \
            "$(apo_report_state_value FINAL_BACKOFF_TRIAL none)" \
            "$(apo_report_state_value FINAL_BACKOFF_HISTORY none)"
    else
        cat <<EOF_STATUS
Recommended:    CPU $(apo_report_state_value RECOMMENDED_CPU "$(apo_report_state_value SAFE_CPU pending)") MHz / GPU $(apo_report_state_value RECOMMENDED_GPU "$(apo_report_state_value SAFE_GPU pending)") MHz
Validated floor: CPU $(apo_report_state_value FLOOR_CPU pending) MHz / GPU $(apo_report_state_value FLOOR_GPU pending) MHz ($(apo_report_state_value FLOOR_VALIDATED 0))
Edge CPU:       $(apo_report_state_value EDGE_CPU_STATUS NOT_REQUESTED) target=$(apo_report_state_value EDGE_CPU_TARGET none)MHz duration=$(apo_report_state_value CFG_EDGE_DURATION_S "$APO_DEFAULT_EDGE_DURATION_S")s order=$(apo_report_state_value CFG_EDGE_ORDER floor-first)
Edge source:    run=$(apo_report_state_value SOURCE_FLOOR_RUN_ID none) post-floor=$(apo_report_state_value POST_FLOOR_EDGE 0)
Final extension: $(apo_report_state_value POST_FLOOR_FINAL 0) source=$(apo_report_state_value SOURCE_FINAL_RUN_ID none) stage=$(apo_report_state_value POST_FLOOR_FINAL_STAGE none)
EOF_STATUS
    fi
    cat <<EOF_STATUS
Auto retries:   $(apo_report_state_value FINAL_BACKOFF_COUNT 0)
Duration policy: $(apo_report_state_value CFG_DURATION_POLICY default) qualification=$(apo_report_state_value CFG_QUALIFICATION_DURATION_S "$APO_DEFAULT_QUALIFICATION_DURATION_S")s final=$(apo_report_state_value CFG_FINAL_DURATION_S "$APO_DEFAULT_FINAL_DURATION_S")s
Max fan tuning: $(apo_report_fan_policy)
Manual test:    $(apo_report_state_value MANUAL_TEST_STATUS NOT_REQUESTED) CPU=$(apo_report_state_value MANUAL_CPU n/a)MHz GPU=$(apo_report_state_value MANUAL_GPU n/a)MHz duration=$(apo_report_manual_duration)
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
State file:     $(apo_report_sensitive_value "${APO_STATE_FILE:-none}")
EOF_STATUS
}

apo_print_status() {
    apo_print_live_status
    if [[ -n ${APO_STATE_FILE:-} ]]; then
        printf '\nSaved operation\n===============\n'
        apo_print_saved_status
    else
        printf '\nSaved operation\n===============\nNo retained operation was found for this target.\n'
    fi
}

apo_summary_next_action() {
    local rendered_target
    rendered_target=$(apo_report_value "${APO_RAW_TARGET:-${APO_REMOTE_TARGET:-TARGET}}")
    case $APO_STATUS_VERDICT in
        'IN PROGRESS')
            printf 'Let the active controller continue; no second command is needed.'
            ;;
        'INTERRUPTED / RESUME AVAILABLE'|'INTERRUPTED / TARGET UNREACHABLE')
            if [[ ${APO_REDACT:-0} == 1 ]]; then
                printf 'Resume the target after confirming it is reachable.'
            else
                printf 'Run: autopioverclock resume %s' "$rendered_target"
            fi
            ;;
        'RECOVERY NEEDED')
            if [[ ${APO_REDACT:-0} == 1 ]]; then
                printf 'Recover the selected run before starting another operation.'
            else
                printf 'Run: autopioverclock recover %s' "$rendered_target"
            fi
            ;;
        'STOCK / RESET')
            printf 'The target is at stock clocks and is ready for preparation or a fresh overclock.'
            ;;
        'OVERCLOCKED / VALIDATED')
            printf 'No recovery action is required; the live config matches retained completed validation.'
            ;;
        'TARGET UNREACHABLE')
            printf 'Restore SSH reachability, then run status again before changing the target.'
            ;;
        *)
            printf 'Review the live configuration and retained evidence before changing clocks.'
            ;;
    esac
}

apo_print_summary() {
    local phase qualification_duration final_duration policy sweep_domain
    apo_print_live_status
    printf '\nRun story\n=========\n'
    if [[ -z ${APO_STATE_FILE:-} ]]; then
        printf 'No retained tuning run was found for this target.\n'
        printf 'Next: %s\n' "$(apo_summary_next_action)"
        return 0
    fi
    phase=$(apo_report_friendly_phase "$(apo_state_get PHASE '')")
    qualification_duration=$(apo_report_duration "$(apo_state_get CFG_QUALIFICATION_DURATION_S "$APO_DEFAULT_QUALIFICATION_DURATION_S")")
    final_duration=$(apo_report_duration "$(apo_state_get CFG_FINAL_DURATION_S "$APO_DEFAULT_FINAL_DURATION_S")")
    policy=$(apo_report_selection_policy)
    sweep_domain=$(apo_state_get CFG_SWEEP_DOMAIN all)
    cat <<EOF_SUMMARY
Run:            $(apo_report_state_value RUN_ID unknown) ($(apo_report_state_value ORIGIN_COMMAND unknown))
Scope:          $(apo_report_value "$sweep_domain")
State:          $(apo_report_state_value STATUS unknown) — $phase / $(apo_report_state_value SUBPHASE unknown)
Search:         CPU passes=$(apo_report_state_value PASSED_CPUS none), boundary=$(apo_report_state_value CPU_FAILURE_BOUNDARY none) MHz
                GPU passes=$(apo_report_state_value PASSED_GPUS none), boundary=$(apo_report_state_value GPU_FAILURE_BOUNDARY none) MHz
CPU decision:   $(apo_report_state_value CPU_QUALIFICATION_STATUS NOT_STARTED), target=$(apo_report_state_value CPU_QUALIFICATION_TARGET pending) MHz, qualified=$(apo_report_state_value CPU_QUALIFIED_CLOCK pending) MHz
GPU decision:   $(apo_report_state_value GPU_QUALIFICATION_STATUS NOT_STARTED), target=$(apo_report_state_value GPU_QUALIFICATION_CPU pending)/$(apo_report_state_value GPU_QUALIFICATION_TARGET pending) MHz, qualified=$(apo_report_state_value GPU_QUALIFIED_CPU pending)/$(apo_report_state_value GPU_QUALIFIED_CLOCK pending) MHz
Selected pair:  CPU $(apo_report_state_value RECOMMENDED_CPU "$(apo_report_state_value SAFE_CPU pending)") MHz / GPU $(apo_report_state_value RECOMMENDED_GPU "$(apo_report_state_value SAFE_GPU pending)") MHz
Test lengths:   qualification=$qualification_duration per domain; final=$final_duration uninterrupted
Final recovery: retries=$(apo_report_state_value FINAL_BACKOFF_COUNT 0), trial=$(apo_report_state_value FINAL_BACKOFF_TRIAL none), history=$(apo_report_state_value FINAL_BACKOFF_HISTORY none)
Final proof:    validated=$(apo_report_state_value VALIDATED 0), duration=$(apo_report_duration "$(apo_state_get VALIDATION_DURATION_S '')"), clocks=CPU $(apo_report_state_value FINAL_CPU pending) / GPU $(apo_report_state_value FINAL_GPU pending) MHz
Application:    $(apo_report_state_value APPLY_STATUS NOT_APPLIED)
Maximum temp:   $(apo_report_state_value RUN_MAX_TEMP pending)C
SSH recovery:   $(apo_report_state_value RECOVERY_WAIT_STATUS IDLE), extended waits=$(apo_report_state_value RECOVERY_WAIT_TIMEOUTS 0)
Gate retries:   $(apo_report_state_value TRANSIENT_RETRY_COUNT 0)/$APO_TRANSIENT_PHASE_RETRY_MAX, context=$(apo_report_state_value TRANSIENT_RETRY_CONTEXT none)
Failure:        $(apo_report_state_value FAILURE_CLASS none) — $(apo_report_sensitive_value "$(apo_state_get FAILURE_REASON none)")
Policy:         $(apo_report_value "$policy")
Next:           $(apo_summary_next_action)
EOF_SUMMARY
}

apo_generate_report() {
    local report_file policy sweep_domain
    if [[ ${APO_REDACT:-0} == 1 ]]; then
        # Do not inherit APO_RUN_PREFIX: it contains the target slug.
        report_file="${APO_OUTPUT_DIR}/autopioverclock-${APO_RUN_ID}-public-report.txt"
    else
        report_file="${APO_RUN_PREFIX}-report.txt"
    fi
    policy=$(apo_report_selection_policy)
    sweep_domain=$(apo_state_get CFG_SWEEP_DOMAIN all)
    {
        printf 'AutoPiOverclock run report\n'
        printf '==========================\n'
        printf 'Version: %s\n' "$APO_VERSION"
        printf 'Run ID: %s\n' "$(apo_report_state_value RUN_ID unknown)"
        printf 'Command: %s\n' "$(apo_report_state_value ORIGIN_COMMAND unknown)"
        printf 'Target: %s\n' "$(apo_report_state_value REMOTE_TARGET unknown)"
        printf 'Profile: %s\n' "$(apo_report_state_value PROFILE unknown)"
        printf 'Mode: %s\n' "$(apo_report_state_value MODE_EFFECTIVE unknown)"
        printf 'Automatic sweep scope: %s\n' "$(apo_report_state_value CFG_SWEEP_DOMAIN all)"
        printf 'Automatic selection policy: %s\n' "$(apo_report_state_value CFG_SELECTION_POLICY guarded-v1)"
        printf 'Requested automatic starts: CPU %s MHz, GPU %s MHz\n' \
            "$(apo_report_state_value CFG_CPU_START_AT auto)" "$(apo_report_state_value CFG_GPU_START_AT auto)"
        if [[ $sweep_domain != all ]]; then
            printf 'Applied source: run=%s, CPU=%s MHz, GPU=%s MHz, hash=%s\n' \
                "$(apo_report_state_value SOURCE_APPLIED_RUN_ID missing)" \
                "$(apo_report_state_value SOURCE_APPLIED_CPU missing)" \
                "$(apo_report_state_value SOURCE_APPLIED_GPU missing)" \
                "$(apo_report_state_value SOURCE_APPLIED_PERMANENT_HASH missing)"
        fi
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
        if [[ $policy == refined-max-25 ]]; then
            printf 'Highest selected passing clocks: CPU %s MHz, GPU %s MHz\n' \
                "$(apo_report_state_value RECOMMENDED_CPU "$(apo_report_state_value SAFE_CPU pending)")" \
                "$(apo_report_state_value RECOMMENDED_GPU "$(apo_report_state_value SAFE_GPU pending)")"
            printf 'Final-failure isolation: anchor=%s/%s MHz, trial=%s, history=%s\n' \
                "$(apo_report_state_value FINAL_BACKOFF_ANCHOR_CPU none)" \
                "$(apo_report_state_value FINAL_BACKOFF_ANCHOR_GPU none)" \
                "$(apo_report_state_value FINAL_BACKOFF_TRIAL none)" \
                "$(apo_report_state_value FINAL_BACKOFF_HISTORY none)"
        else
            printf 'Conservative recommendation: CPU %s MHz, GPU %s MHz\n' \
                "$(apo_report_state_value RECOMMENDED_CPU "$(apo_report_state_value SAFE_CPU pending)")" \
                "$(apo_report_state_value RECOMMENDED_GPU "$(apo_report_state_value SAFE_GPU pending)")"
        fi
        printf 'Automatic qualification/final retries: count=%s, target=%s/%s MHz, history=%s\n' \
            "$(apo_report_state_value FINAL_BACKOFF_COUNT 0)" "$(apo_report_state_value FINAL_BACKOFF_CPU none)" \
            "$(apo_report_state_value FINAL_BACKOFF_GPU none)" "$(apo_report_state_value FINAL_BACKOFF_HISTORY none)"
        printf 'Last automatic backoff boundary: stage=%s, class=%s, reason=%s\n' \
            "$(apo_report_state_value FINAL_BACKOFF_LAST_STAGE none)" "$(apo_report_state_value FINAL_BACKOFF_LAST_CLASS none)" \
            "$(apo_report_sensitive_value "$(apo_report_state_value FINAL_BACKOFF_LAST_REASON none)")"
        if [[ $policy != refined-max-25 ]]; then
            printf 'Validated production floor: CPU %s MHz, GPU %s MHz (validated=%s, duration=%ss)\n' \
                "$(apo_report_state_value FLOOR_CPU pending)" "$(apo_report_state_value FLOOR_GPU pending)" \
                "$(apo_report_state_value FLOOR_VALIDATED 0)" "$(apo_report_state_value FLOOR_DURATION_S pending)"
            printf 'Edge CPU: status=%s, target=%s MHz, duration=%ss, order=%s\n' \
                "$(apo_report_state_value EDGE_CPU_STATUS NOT_REQUESTED)" "$(apo_report_state_value EDGE_CPU_TARGET none)" \
                "$(apo_report_state_value CFG_EDGE_DURATION_S "$APO_DEFAULT_EDGE_DURATION_S")" "$(apo_report_state_value CFG_EDGE_ORDER floor-first)"
            printf 'Post-floor edge source: enabled=%s, run=%s, permanent-hash=%s\n' \
                "$(apo_report_state_value POST_FLOOR_EDGE 0)" "$(apo_report_state_value SOURCE_FLOOR_RUN_ID none)" \
                "$(apo_report_state_value SOURCE_FLOOR_PERMANENT_HASH none)"
        fi
        printf 'Maximum fan cooling during tuning: %s\n' \
            "$(apo_report_fan_policy)"
        if [[ $policy != refined-max-25 ]]; then
            printf 'Longer final extension: enabled=%s, source=%s, stage=%s\n' \
                "$(apo_report_state_value POST_FLOOR_FINAL 0)" "$(apo_report_state_value SOURCE_FINAL_RUN_ID none)" \
                "$(apo_report_state_value POST_FLOOR_FINAL_STAGE none)"
        fi
        printf 'Duration policy: %s (qualification=%ss each, final=%ss uninterrupted)\n' \
            "$(apo_report_state_value CFG_DURATION_POLICY default)" \
            "$(apo_report_state_value CFG_QUALIFICATION_DURATION_S "$APO_DEFAULT_QUALIFICATION_DURATION_S")" \
            "$(apo_report_state_value CFG_FINAL_DURATION_S "$APO_DEFAULT_FINAL_DURATION_S")"
        printf 'Manual stability test: status=%s, CPU=%s MHz, GPU=%s MHz, duration=%s\n' \
            "$(apo_report_state_value MANUAL_TEST_STATUS NOT_REQUESTED)" "$(apo_report_state_value MANUAL_CPU n/a)" \
            "$(apo_report_state_value MANUAL_GPU n/a)" "$(apo_report_manual_duration)"
        printf 'Maximum observed run temperature: %sC\n' "$(apo_report_state_value RUN_MAX_TEMP pending)"
        if [[ $policy != refined-max-25 ]]; then
            printf 'Edge failure: class=%s, reason=%s\n' \
                "$(apo_report_state_value EDGE_CPU_FAILURE_CLASS none)" "$(apo_report_sensitive_value "$(apo_report_state_value EDGE_CPU_FAILURE_REASON none)")"
        fi
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
