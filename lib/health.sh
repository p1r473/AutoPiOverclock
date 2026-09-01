#!/usr/bin/env bash
# Controller-side health and stress wrappers.

: "${APO_PERMANENT_HASH_READ_ATTEMPTS:=${APO_TRANSIENT_READ_ATTEMPTS:-30}}"
: "${APO_PERMANENT_HASH_READ_DELAY_SECONDS:=${APO_TRANSIENT_READ_DELAY_SECONDS:-10}}"
APO_PERMANENT_HASH_READ_VALUE=''
APO_PERMANENT_HASH_READ_EVIDENCE=unreadable
APO_PERMANENT_HASH_READ_USED=0

apo_read_permanent_hash() {
    local hash_output='' current_hash='' attempt
    APO_PERMANENT_HASH_READ_VALUE=''
    APO_PERMANENT_HASH_READ_EVIDENCE=unreadable
    APO_PERMANENT_HASH_READ_USED=0
    [[ $APO_PERMANENT_HASH_READ_ATTEMPTS =~ ^[1-9][0-9]*$ ]] || APO_PERMANENT_HASH_READ_ATTEMPTS=30
    [[ $APO_PERMANENT_HASH_READ_DELAY_SECONDS =~ ^[0-9]+$ ]] || APO_PERMANENT_HASH_READ_DELAY_SECONDS=10
    for (( attempt=1; attempt<=APO_PERMANENT_HASH_READ_ATTEMPTS; attempt++ )); do
        APO_PERMANENT_HASH_READ_USED=$attempt
        hash_output=''
        current_hash=''
        if hash_output=$(apo_remote_root "sha256sum $(apo_sh_quote "$APO_BOOT_CONFIG")" 2>/dev/null); then
            current_hash=$(awk 'NR == 1 {print $1}' <<< "$hash_output")
            if [[ $current_hash =~ ^[0-9a-f]{64}$ ]]; then
                APO_PERMANENT_HASH_READ_VALUE=$current_hash
                APO_PERMANENT_HASH_READ_EVIDENCE=valid
                return 0
            fi
            APO_PERMANENT_HASH_READ_EVIDENCE=malformed
        else
            APO_PERMANENT_HASH_READ_EVIDENCE=unreadable
        fi
        if (( attempt < APO_PERMANENT_HASH_READ_ATTEMPTS && APO_PERMANENT_HASH_READ_DELAY_SECONDS > 0 )); then
            sleep "$APO_PERMANENT_HASH_READ_DELAY_SECONDS"
        fi
    done
    return 1
}

apo_verify_permanent_hash() {
    local context=$1 current_hash=''
    if apo_read_permanent_hash; then
        current_hash=$APO_PERMANENT_HASH_READ_VALUE
        if [[ $current_hash != "$APO_PERMANENT_CONFIG_HASH" ]]; then
            APO_LAST_CLASS=RECOVERY_FAILURE
            APO_LAST_REASON="Permanent config hash changed in $context (${APO_PERMANENT_CONFIG_HASH} -> $current_hash)."
            return 1
        fi
        return 0
    fi
    APO_LAST_CLASS=RECOVERY_FAILURE
    if [[ $APO_PERMANENT_HASH_READ_EVIDENCE == malformed ]]; then
        APO_LAST_REASON="Permanent config hash is unavailable in $context after $APO_PERMANENT_HASH_READ_USED attempts; the target returned malformed hash evidence."
    else
        APO_LAST_REASON="Permanent config hash is unavailable in $context after $APO_PERMANENT_HASH_READ_USED attempts; the target did not return readable hash evidence."
    fi
    return 2
}

apo_candidate_fan_policy() {
    if [[ ${APO_MAX_FAN:-1} == 1 ]]; then printf candidate-max; else printf normal; fi
}

apo_current_fan_policy() {
    if [[ $(apo_state_get TRYBOOT_EXPECTED 0) == 1 ]]; then
        apo_candidate_fan_policy
        return
    fi
    printf normal
}

apo_health_check() {
    local expected_cpu=$1 expected_gpu=$2 expected_voltage=$3 context=$4 fan_policy
    fan_policy=$(apo_current_fan_policy)
    apo_run_worker_capture "$context" health \
        "$expected_cpu" "$expected_gpu" "$APO_GPU_KEY" "$expected_voltage" "${APO_CFG[MAX_TEMP_C]}" \
        "$APO_MODE_EFFECTIVE" "$APO_DISPLAY_BASELINE" "${APO_CFG[REQUIRED_PROCESSES]}" "${APO_CFG[REQUIRED_SERVICES]}" \
        "${APO_CFG[AUDIO_SINK_MATCH]}" "${APO_CFG[EXTRA_PING_TARGET]}" "${APO_CFG[HEALTH_HOOK]}" \
        "$APO_PERMANENT_CONFIG_HASH" "$context" "$APO_THROTTLE_RUNTIME_BASELINE" "$APO_AUDIO_BASELINE" "$fan_policy"
}

apo_run_stress() {
    local stress_kind=$1 duration=$2 label=$3 io_check=${4:-0} expected_cpu expected_gpu fan_policy
    local stress_rc=0 stress_class='' stress_reason='' hash_rc=0
    expected_cpu=$(apo_state_get CURRENT_CPU '')
    expected_gpu=$(apo_state_get CURRENT_GPU '')
    [[ -n $expected_cpu ]] || expected_cpu=$APO_NORMAL_CPU
    [[ -n $expected_gpu ]] || expected_gpu=$APO_NORMAL_GPU
    fan_policy=$(apo_current_fan_policy)
    apo_verify_permanent_hash "${label}-pre-stress" || return 1
    if declare -F apo_progress_begin_stress >/dev/null 2>&1; then apo_progress_begin_stress "$duration" "$label"; fi
    apo_run_worker_capture "$label" stress "$stress_kind" "$duration" "${APO_CFG[MAX_TEMP_C]}" "$APO_MODE_EFFECTIVE" "$APO_DISPLAY_BASELINE" "$io_check" "$expected_cpu" "$expected_gpu" "$APO_THROTTLE_RUNTIME_BASELINE" "${APO_CFG[TELEMETRY_INTERVAL_S]}" "${APO_AUDIO_BASELINE:-}" "$fan_policy" || {
        stress_rc=$?
        stress_class=${APO_LAST_CLASS:-HARNESS_FAILURE}
        stress_reason=${APO_LAST_REASON:-The stress worker failed without a reason.}
    }
    apo_verify_permanent_hash "${label}-post-stress" || {
        hash_rc=$?
        if declare -F apo_progress_finish_stress >/dev/null 2>&1; then apo_progress_finish_stress; fi
        if (( stress_rc != 0 && hash_rc == 2 )); then
            # Unavailable or malformed hash evidence cannot prove either a
            # match or a mutation.
            # Preserve the worker failure so the caller enters normal recovery;
            # recovery rechecks the exact permanent hash after SSH returns.
            APO_LAST_CLASS=$stress_class
            APO_LAST_REASON=$stress_reason
            return "$stress_rc"
        fi
        return 1
    }
    if declare -F apo_progress_finish_stress >/dev/null 2>&1; then apo_progress_finish_stress; fi
    return "$stress_rc"
}

apo_reset_throttle_history() {
    local label=${1:-throttle-baseline}
    (( APO_THROTTLE_RECENT_SUPPORTED == 1 )) || { APO_LAST_CLASS=HARNESS_FAILURE; APO_LAST_REASON='Recent throttle-history reset is unsupported.'; return 1; }
    apo_run_worker_capture "$label" reset-throttle-history || return 1
    APO_THROTTLE_RUNTIME_BASELINE=throttled=0x0
    apo_state_set THROTTLE_RUNTIME_BASELINE "$APO_THROTTLE_RUNTIME_BASELINE"
    apo_state_save
}
