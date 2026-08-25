#!/usr/bin/env bash
# Controller-side health and stress wrappers.

apo_verify_permanent_hash() {
    local context=$1 current_hash
    current_hash=$(apo_remote_root "sha256sum $(apo_sh_quote "$APO_BOOT_CONFIG")" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    if [[ $current_hash != "$APO_PERMANENT_CONFIG_HASH" ]]; then
        APO_LAST_CLASS=RECOVERY_FAILURE
        APO_LAST_REASON="Permanent config hash changed in $context (${APO_PERMANENT_CONFIG_HASH} -> ${current_hash:-unavailable})."
        return 1
    fi
}

apo_health_check() {
    local expected_cpu=$1 expected_gpu=$2 expected_voltage=$3 context=$4
    apo_run_worker_capture "$context" health \
        "$expected_cpu" "$expected_gpu" "$APO_GPU_KEY" "$expected_voltage" "${APO_CFG[MAX_TEMP_C]}" \
        "$APO_MODE_EFFECTIVE" "$APO_DISPLAY_BASELINE" "${APO_CFG[REQUIRED_PROCESSES]}" "${APO_CFG[REQUIRED_SERVICES]}" \
        "${APO_CFG[AUDIO_SINK_MATCH]}" "${APO_CFG[EXTRA_PING_TARGET]}" "${APO_CFG[HEALTH_HOOK]}" \
        "$APO_PERMANENT_CONFIG_HASH" "$context" "$APO_THROTTLE_RUNTIME_BASELINE" "$APO_AUDIO_BASELINE"
}

apo_run_stress() {
    local stress_kind=$1 duration=$2 label=$3 io_check=${4:-0} expected_cpu expected_gpu
    expected_cpu=$(apo_state_get CURRENT_CPU '')
    expected_gpu=$(apo_state_get CURRENT_GPU '')
    [[ -n $expected_cpu ]] || expected_cpu=$APO_NORMAL_CPU
    [[ -n $expected_gpu ]] || expected_gpu=$APO_NORMAL_GPU
    apo_verify_permanent_hash "${label}-pre-stress" || return 1
    local stress_rc=0
    apo_run_worker_capture "$label" stress "$stress_kind" "$duration" "${APO_CFG[MAX_TEMP_C]}" "$APO_MODE_EFFECTIVE" "$APO_DISPLAY_BASELINE" "$io_check" "$expected_cpu" "$expected_gpu" "$APO_THROTTLE_RUNTIME_BASELINE" "${APO_CFG[TELEMETRY_INTERVAL_S]}" "${APO_AUDIO_BASELINE:-}" || stress_rc=$?
    apo_verify_permanent_hash "${label}-post-stress" || return 1
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
