#!/usr/bin/env bash
# Tryboot state machine and normal-boot recovery.

APO_RECOVERY_IN_PROGRESS=0
APO_RECOVERY_UNEXPECTED_CANDIDATE_REBOOT=0
APO_RECOVERY_UNEXPECTED_REBOOT_FROM=''
APO_RECOVERY_UNEXPECTED_REBOOT_TO=''
APO_BOOT_FAILURE_OBSERVATION_ELIGIBLE=0
APO_TRANSIENT_PHASE_RETRY_MAX=5

apo_transient_worker_failure_is_retryable() {
    local failure_class=$1 failure_reason=$2 result_structured=${3:-0}
    [[ $failure_class == HARNESS_FAILURE && -n $failure_reason ]] || return 1
    # A structured harness diagnosis is never promoted to a clock boundary,
    # but a complete verified normal recovery makes its exact gate safe to
    # repeat. Saved state predating this decision has no structured-result bit,
    # so only the two known clean-early-exit reasons are adopted on resume.
    [[ $result_structured == 1 ]] && return 0
    [[ $result_structured == 0 ]] || return 1
    case $failure_reason in
        'The worker failed without a structured result.') return 0 ;;
        The\ target\ returned\ after\ *,\ but\ its\ run-isolated\ worker\ could\ not\ be\ redeployed.) return 0 ;;
        'CPU stress exited early with rc=0.') return 0 ;;
        'GPU stress exited early with rc=0.') return 0 ;;
        *) return 1 ;;
    esac
}

apo_transient_hash_read_failure_is_retryable() {
    local failure_class=$1 failure_reason=$2
    [[ $failure_class == RECOVERY_FAILURE && -n $failure_reason ]] || return 1
    case $failure_reason in
        Permanent\ config\ hash\ is\ unavailable\ in\ *\;\ the\ target\ did\ not\ return\ readable\ hash\ evidence.) return 0 ;;
        Permanent\ config\ hash\ is\ unavailable\ in\ *\;\ the\ target\ returned\ malformed\ hash\ evidence.) return 0 ;;
        *) return 1 ;;
    esac
}

apo_transient_gate_failure_is_retryable() {
    apo_transient_worker_failure_is_retryable "$@" ||
        apo_transient_hash_read_failure_is_retryable "$1" "$2"
}

apo_stress_reboot_scope_is_active() {
    local stress_reboot_scope=$1
    case $stress_reboot_scope in
        candidate)
            [[ $(apo_state_get CANDIDATE_STAGE '') == STRESS ]]
            ;;
        final)
            [[ $(apo_state_get PHASE '') == FINAL_VALIDATION ]] || return 1
            case $(apo_state_get FINAL_STAGE '') in
                CPU_STRESS|GPU_STRESS|ENDURANCE) return 0 ;;
                *) return 1 ;;
            esac
            ;;
        *)
            return 1
            ;;
    esac
}

apo_reboot_observation_scope_is_active() {
    local reboot_scope=$1
    case $reboot_scope in
        candidate|final)
            apo_stress_reboot_scope_is_active "$reboot_scope"
            ;;
        candidate-boot)
            case $(apo_state_get CANDIDATE_STAGE '') in BOOT_*|STRESS_BOOT|STRESS) return 0 ;; *) return 1 ;; esac
            ;;
        final-boot)
            [[ $(apo_state_get PHASE '') == FINAL_VALIDATION ]] || return 1
            case $(apo_state_get FINAL_STAGE '') in PRE_STRESS_BOOT|ENDURANCE|BOOT_*) return 0 ;; *) return 1 ;; esac
            ;;
        candidate-health)
            [[ $(apo_state_get CANDIDATE_STAGE '') == POST_STRESS_HEALTH ]]
            ;;
        final-health)
            [[ $(apo_state_get PHASE '') == FINAL_VALIDATION && $(apo_state_get FINAL_STAGE '') == ENDURANCE ]]
            ;;
        *)
            return 1
            ;;
    esac
}

apo_transient_phase_retry_schedule() {
    local retry_context=$1 original_class=$2 original_reason=$3 eligible=${4:-0}
    local saved_context retry_count
    [[ $eligible == 1 && $original_class == HARNESS_FAILURE && -n $original_reason ]] || return 1
    saved_context=$(apo_state_get TRANSIENT_RETRY_CONTEXT '')
    retry_count=$(apo_state_get TRANSIENT_RETRY_COUNT 0)
    [[ $retry_count =~ ^[0-9]+$ ]] || return 1
    if [[ $saved_context != "$retry_context" ]]; then retry_count=0; fi
    (( retry_count < APO_TRANSIENT_PHASE_RETRY_MAX )) || return 1
    retry_count=$((retry_count + 1))
    apo_state_set TRANSIENT_RETRY_CONTEXT "$retry_context"
    apo_state_set TRANSIENT_RETRY_COUNT "$retry_count"
    apo_state_set STATUS RUNNING
    apo_state_set FAILURE_CLASS ''
    apo_state_set FAILURE_REASON ''
    apo_state_save
    apo_event automatic-harness-retry WARN HARNESS_FAILURE "Recovered a retryable harness failure in $retry_context; repeating the complete affected gate automatically (retry $retry_count/$APO_TRANSIENT_PHASE_RETRY_MAX): $original_reason"
}

apo_transient_phase_retry_clear() {
    local completed_context=${1:-} saved_context
    saved_context=$(apo_state_get TRANSIENT_RETRY_CONTEXT '')
    [[ -z $saved_context || -z $completed_context || $saved_context == "$completed_context" ]] || return 0
    if [[ -n $saved_context || $(apo_state_get TRANSIENT_RETRY_COUNT 0) != 0 ]]; then
        apo_state_set TRANSIENT_RETRY_CONTEXT ''
        apo_state_set TRANSIENT_RETRY_COUNT 0
        apo_state_save
    fi
}

apo_prepare_candidate() {
    local cpu_mhz=$1 gpu_mhz=$2 label=$3 tryboot_hash reservation_hash installed_hash
    local ownership_token quarantine_path expected_quarantine fan_policy
    if [[ -n $(apo_state_get TRYBOOT_OWNED_HASH '') || -n $(apo_state_get TRYBOOT_RESERVATION_HASH '') ||
          -n $(apo_state_get TRYBOOT_OWNERSHIP_TOKEN '') || -n $(apo_state_get TRYBOOT_QUARANTINE_PATH '') ||
          $(apo_state_get TRYBOOT_FILE_MAY_EXIST 0) == 1 ]]; then
        APO_LAST_CLASS=RECOVERY_FAILURE
        APO_LAST_REASON='A prior tryboot ownership checkpoint is still active; refusing to stage another candidate.'
        return 1
    fi
    ownership_token=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n') || {
        APO_LAST_CLASS=HARNESS_FAILURE
        APO_LAST_REASON='Could not create a cryptographically random tryboot ownership token.'
        return 1
    }
    if [[ ! $ownership_token =~ ^[0-9a-f]{64}$ ]]; then
        APO_LAST_CLASS=HARNESS_FAILURE
        APO_LAST_REASON='The generated tryboot ownership token is malformed.'
        return 1
    fi
    if [[ ${APO_MAX_FAN:-1} == 1 ]]; then fan_policy=candidate-max; else fan_policy=normal; fi
    apo_run_worker_capture "${label}-plan" plan-candidate \
        "$APO_BOOT_CONFIG" "$APO_TRYBOOT_CONFIG" "$APO_GPU_KEY" "$cpu_mhz" "$gpu_mhz" \
        "$APO_TEST_VOLTAGE" "$APO_PERMANENT_CONFIG_HASH" "$APO_RUN_ID" "$ownership_token" "$fan_policy" || return 1
    apo_parse_data_file "$APO_LAST_WORKER_LOG" APO_WORKER_DATA
    tryboot_hash=${APO_WORKER_DATA[TRYBOOT_HASH]:-}
    reservation_hash=${APO_WORKER_DATA[TRYBOOT_RESERVATION_HASH]:-}
    quarantine_path=${APO_WORKER_DATA[TRYBOOT_QUARANTINE]:-}
    expected_quarantine="${APO_TRYBOOT_CONFIG%/*}/.autopioverclock-remove-${ownership_token}"
    if [[ ! $tryboot_hash =~ ^[0-9a-f]{64}$ || ! $reservation_hash =~ ^[0-9a-f]{64}$ ||
          $quarantine_path != "$expected_quarantine" ]]; then
        APO_LAST_CLASS=HARNESS_FAILURE
        APO_LAST_REASON='Candidate planning did not return valid token-bound tryboot ownership evidence.'
        apo_event "${label}-plan" ERROR "$APO_LAST_CLASS" "$APO_LAST_REASON"
        return 1
    fi
    apo_state_set TRYBOOT_OWNED_HASH "$tryboot_hash"
    apo_state_set TRYBOOT_RESERVATION_HASH "$reservation_hash"
    apo_state_set TRYBOOT_OWNERSHIP_TOKEN "$ownership_token"
    apo_state_set TRYBOOT_QUARANTINE_PATH "$quarantine_path"
    apo_state_set TRYBOOT_FILE_MAY_EXIST 1
    apo_state_set MUTATIONS_STARTED 1
    apo_state_save
    apo_run_worker_capture "${label}-prepare" prepare-candidate \
        "$APO_BOOT_CONFIG" "$APO_TRYBOOT_CONFIG" "$APO_GPU_KEY" "$cpu_mhz" "$gpu_mhz" \
        "$APO_TEST_VOLTAGE" "$APO_PERMANENT_CONFIG_HASH" "$APO_RUN_ID" \
        "$tryboot_hash" "$reservation_hash" "$ownership_token" "$quarantine_path" "$fan_policy" || return 1
    apo_parse_data_file "$APO_LAST_WORKER_LOG" APO_WORKER_DATA
    installed_hash=${APO_WORKER_DATA[TRYBOOT_HASH]:-}
    if [[ $installed_hash != "$tryboot_hash" ]]; then
        APO_LAST_CLASS=RECOVERY_FAILURE
        APO_LAST_REASON='Candidate preparation did not confirm the persisted tryboot ownership hash.'
        apo_event "${label}-prepare" ERROR "$APO_LAST_CLASS" "$APO_LAST_REASON"
        return 1
    fi
    apo_state_set TRYBOOT_LAST_HASH "$installed_hash"
    apo_state_save
}

apo_clear_managed_tryboot() {
    local context=$1 expected_tryboot_hash expected_reservation_hash ownership_token quarantine_path failure_reason
    if [[ $(apo_state_get TRYBOOT_FILE_MAY_EXIST 0) == 0 && -z $(apo_state_get TRYBOOT_OWNED_HASH '') &&
          -z $(apo_state_get TRYBOOT_RESERVATION_HASH '') && -z $(apo_state_get TRYBOOT_OWNERSHIP_TOKEN '') &&
          -z $(apo_state_get TRYBOOT_QUARANTINE_PATH '') ]]; then
        return 0
    fi
    expected_tryboot_hash=$(apo_state_get TRYBOOT_OWNED_HASH '')
    expected_reservation_hash=$(apo_state_get TRYBOOT_RESERVATION_HASH '')
    ownership_token=$(apo_state_get TRYBOOT_OWNERSHIP_TOKEN '')
    quarantine_path=$(apo_state_get TRYBOOT_QUARANTINE_PATH '')
    if [[ $(apo_state_get TRYBOOT_FILE_MAY_EXIST 0) != 1 || ! $expected_tryboot_hash =~ ^[0-9a-f]{64}$ ||
          ! $expected_reservation_hash =~ ^[0-9a-f]{64}$ || ! $ownership_token =~ ^[0-9a-f]{64}$ ||
          $quarantine_path != "${APO_TRYBOOT_CONFIG%/*}/.autopioverclock-remove-${ownership_token}" ]]; then
        APO_LAST_CLASS=RECOVERY_FAILURE
        APO_LAST_REASON='Saved tryboot ownership evidence is missing or malformed; automatic cleanup is refused.'
        return 1
    fi
    if ! apo_run_worker_capture "${context}-tryboot-cleanup" clear-tryboot \
        "$APO_BOOT_CONFIG" "$APO_TRYBOOT_CONFIG" "$quarantine_path" "$APO_PERMANENT_CONFIG_HASH" \
        "$expected_tryboot_hash" "$expected_reservation_hash" "$APO_RUN_ID" "$ownership_token"; then
        failure_reason=$APO_LAST_REASON
        APO_LAST_CLASS=RECOVERY_FAILURE
        APO_LAST_REASON="Normal boot recovered, but managed tryboot cleanup failed: $failure_reason"
        return 1
    fi
    apo_state_set TRYBOOT_FILE_MAY_EXIST 0
    apo_state_set TRYBOOT_OWNED_HASH ''
    apo_state_set TRYBOOT_RESERVATION_HASH ''
    apo_state_set TRYBOOT_OWNERSHIP_TOKEN ''
    apo_state_set TRYBOOT_QUARANTINE_PATH ''
    apo_state_save
}

apo_boot_candidate() {
    local cpu_mhz=$1 gpu_mhz=$2 context=$3 old_boot_id new_boot_id tryboot_flag expected_tryboot_hash ownership_token
    APO_BOOT_FAILURE_OBSERVATION_ELIGIBLE=0
    apo_prepare_candidate "$cpu_mhz" "$gpu_mhz" "$context" || return 1
    expected_tryboot_hash=$(apo_state_get TRYBOOT_OWNED_HASH '')
    ownership_token=$(apo_state_get TRYBOOT_OWNERSHIP_TOKEN '')
    apo_run_worker_capture "${context}-pre-trigger" verify-tryboot \
        "$APO_BOOT_CONFIG" "$APO_TRYBOOT_CONFIG" "$APO_PERMANENT_CONFIG_HASH" \
        "$expected_tryboot_hash" "$APO_RUN_ID" "$ownership_token" || return 1
    old_boot_id=$(apo_remote_boot_id) || { APO_LAST_CLASS=HARNESS_FAILURE; APO_LAST_REASON='Could not read boot ID before tryboot.'; return 1; }
    apo_state_set LAST_BOOT_ID "$old_boot_id"
    apo_state_set TRYBOOT_EXPECTED 1
    apo_state_set CURRENT_CPU "$cpu_mhz"
    apo_state_set CURRENT_GPU "$gpu_mhz"
    apo_state_set CANDIDATE_BOOT_ID ''
    apo_state_set SUBPHASE "$context"
    apo_state_save
    apo_event "$context" INFO '' "Triggering tryboot for CPU=$cpu_mhz GPU=$gpu_mhz"
    apo_remote_worker "$APO_REMOTE_WORKER" trigger-tryboot \
        "$APO_BOOT_CONFIG" "$APO_TRYBOOT_CONFIG" "$APO_PERMANENT_CONFIG_HASH" \
        "$expected_tryboot_hash" "$APO_RUN_ID" "$ownership_token" >/dev/null 2>&1 || true
    if ! apo_post_reboot_handshake "$old_boot_id" "$APO_BOOT_TIMEOUT" "$context"; then
        if [[ ${APO_REBOOT_HANDSHAKE_STAGE:-wait} == worker ]]; then
            APO_LAST_CLASS=HARNESS_FAILURE
            if [[ -n ${APO_REBOOT_OBSERVED_BOOT_ID:-} ]] &&
               apo_transient_worker_failure_is_retryable "$APO_LAST_CLASS" "$APO_LAST_REASON" 0; then
                apo_state_set CANDIDATE_BOOT_ID "$APO_REBOOT_OBSERVED_BOOT_ID"
                apo_state_set LAST_BOOT_ID "$APO_REBOOT_OBSERVED_BOOT_ID"
                apo_state_save
                APO_BOOT_FAILURE_OBSERVATION_ELIGIBLE=1
            fi
        else
            APO_LAST_CLASS=BOOT_FAILURE
            APO_LAST_REASON="No reboot/recovery reached SSH within ${APO_BOOT_TIMEOUT}s for $context."
        fi
        return 1
    fi
    new_boot_id=$APO_REBOOT_BOOT_ID
    tryboot_flag=$(apo_remote_tryboot_flag || true)
    if [[ $tryboot_flag != 00000001 ]]; then
        APO_LAST_CLASS=BOOT_FAILURE
        if [[ $tryboot_flag == 00000000 ]]; then
            apo_state_set TRYBOOT_EXPECTED 0
            apo_state_set CURRENT_CPU ''
            apo_state_set CURRENT_GPU ''
            apo_state_set NORMAL_BOOT_ID "$new_boot_id"
            apo_state_set LAST_BOOT_ID "$new_boot_id"
            apo_state_save
            APO_LAST_REASON="Candidate $context did not remain in tryboot; it failed before SSH and recovered normally."
        else
            APO_LAST_REASON="Candidate $context rebooted, but its tryboot state could not be verified (${tryboot_flag:-missing})."
        fi
        return 1
    fi
    apo_state_set CANDIDATE_BOOT_ID "$new_boot_id"
    apo_state_set LAST_BOOT_ID "$new_boot_id"
    apo_state_save
    sleep "$APO_BOOT_SETTLE_SECONDS"
    if apo_health_check "$cpu_mhz" "$gpu_mhz" "$APO_TEST_VOLTAGE" "$context"; then
        return 0
    fi
    if apo_transient_worker_failure_is_retryable "$APO_LAST_CLASS" "$APO_LAST_REASON" "${APO_LAST_RESULT_STRUCTURED:-0}"; then
        APO_BOOT_FAILURE_OBSERVATION_ELIGIBLE=1
    fi
    return 1
}

apo_return_normal() {
    local context=${1:-normal-recovery} force_normal_reboot=${2:-0} stress_reboot_scope=${3:-none}
    local old_boot_id new_boot_id tryboot_flag current_boot_id
    local expected_tryboot pending_boot_id reboot_attempts=0 forced_normal_reboot_done=0 controller_reboot_issued=0
    APO_RECOVERY_UNEXPECTED_CANDIDATE_REBOOT=0
    APO_RECOVERY_UNEXPECTED_REBOOT_FROM=''
    APO_RECOVERY_UNEXPECTED_REBOOT_TO=''
    [[ $force_normal_reboot == 0 || $force_normal_reboot == 1 ]] || {
        APO_LAST_CLASS=RECOVERY_FAILURE
        APO_LAST_REASON='The normal-recovery reboot request is malformed.'
        return 1
    }
    case $stress_reboot_scope in
        none|candidate|final|candidate-boot|final-boot|candidate-health|final-health) ;;
        *)
            APO_LAST_CLASS=RECOVERY_FAILURE
            APO_LAST_REASON='The reboot-observation scope is malformed.'
            return 1
            ;;
    esac
    if (( force_normal_reboot == 1 )) && [[ $stress_reboot_scope != none ]]; then
        APO_LAST_CLASS=RECOVERY_FAILURE
        APO_LAST_REASON='Forced graphical recovery and reboot observation cannot be combined.'
        return 1
    fi
    if (( force_normal_reboot == 1 )) && [[ ${APO_PROFILE:-} != batocera || ${APO_MODE_EFFECTIVE:-} != graphical ]]; then
        APO_LAST_CLASS=RECOVERY_FAILURE
        APO_LAST_REASON='A forced normal recovery reboot is permitted only for a Batocera graphical-session recovery failure.'
        return 1
    fi
    APO_RECOVERY_IN_PROGRESS=1
    expected_tryboot=$(apo_state_get TRYBOOT_EXPECTED 0)
    pending_boot_id=$(apo_state_get LAST_BOOT_ID '')
    while :; do
        if ! apo_wait_for_ssh "$APO_BOOT_TIMEOUT" "$context"; then APO_RECOVERY_IN_PROGRESS=0; APO_LAST_CLASS=RECOVERY_FAILURE; APO_LAST_REASON="SSH is unavailable for normal recovery after ${APO_BOOT_TIMEOUT}s."; return 1; fi
        current_boot_id=$(apo_remote_boot_id || true)
        if [[ -z $current_boot_id ]]; then APO_RECOVERY_IN_PROGRESS=0; APO_LAST_CLASS=RECOVERY_FAILURE; APO_LAST_REASON='Could not read the boot ID during normal recovery.'; return 1; fi
        if ! apo_ensure_worker_for_boot "$current_boot_id" "$context"; then
            APO_RECOVERY_IN_PROGRESS=0
            APO_LAST_CLASS=RECOVERY_FAILURE
            APO_LAST_REASON="Normal recovery reached SSH, but its transient worker could not be restored: $APO_LAST_REASON"
            return 1
        fi
        tryboot_flag=$(apo_remote_tryboot_flag || true)
        if (( force_normal_reboot == 1 && forced_normal_reboot_done == 0 )) && [[ $tryboot_flag != 00000000 ]]; then
            APO_RECOVERY_IN_PROGRESS=0
            APO_LAST_CLASS=RECOVERY_FAILURE
            APO_LAST_REASON="A forced normal recovery reboot requires a verified clear tryboot flag; found ${tryboot_flag:-missing}."
            return 1
        fi
        if [[ $tryboot_flag == 00000000 ]]; then
            if (( force_normal_reboot == 1 && forced_normal_reboot_done == 0 )); then
                if [[ $expected_tryboot != 0 || $(apo_state_get TRYBOOT_FILE_MAY_EXIST 0) != 0 ||
                      -n $(apo_state_get TRYBOOT_OWNED_HASH '') || -n $(apo_state_get TRYBOOT_RESERVATION_HASH '') ||
                      -n $(apo_state_get TRYBOOT_OWNERSHIP_TOKEN '') || -n $(apo_state_get TRYBOOT_QUARANTINE_PATH '') ]]; then
                    APO_RECOVERY_IN_PROGRESS=0
                    APO_LAST_CLASS=RECOVERY_FAILURE
                    APO_LAST_REASON='A forced normal recovery reboot was refused because saved tryboot ownership state is not clear.'
                    return 1
                fi
                if ! apo_verify_permanent_hash "${context}-pre-forced-reboot"; then
                    APO_RECOVERY_IN_PROGRESS=0
                    return 1
                fi
                apo_event "$context" WARN '' 'The Batocera graphical worker could not restore its saved session; forcing one verified normal-config reboot.'
            elif [[ $expected_tryboot != 1 || ( -n $pending_boot_id && $current_boot_id != "$pending_boot_id" ) ]]; then
                if [[ $stress_reboot_scope != none ]] && (( controller_reboot_issued == 0 )) &&
                   [[ $expected_tryboot == 1 && -n $pending_boot_id &&
                      $current_boot_id != "$pending_boot_id" &&
                      $(apo_state_get CANDIDATE_BOOT_ID '') == "$pending_boot_id" ]] &&
                   apo_reboot_observation_scope_is_active "$stress_reboot_scope"; then
                    APO_RECOVERY_UNEXPECTED_CANDIDATE_REBOOT=1
                    APO_RECOVERY_UNEXPECTED_REBOOT_FROM=$pending_boot_id
                    APO_RECOVERY_UNEXPECTED_REBOOT_TO=$current_boot_id
                fi
                new_boot_id=$current_boot_id
                break
            else
                apo_event "$context" WARN '' 'Tryboot was expected but the target is still on the pre-trigger boot; forcing a plain reboot to close the trigger/exit race.'
            fi
        elif [[ $tryboot_flag == 00000001 ]]; then
            apo_event "$context" INFO '' 'Rebooting from tryboot to permanent normal config.'
        else
            apo_event "$context" WARN '' "Tryboot state is unreadable (${tryboot_flag:-missing}); forcing a plain reboot before accepting normal recovery."
        fi
        if (( reboot_attempts >= 3 )); then
            APO_RECOVERY_IN_PROGRESS=0
            APO_LAST_CLASS=RECOVERY_FAILURE
            APO_LAST_REASON='Normal recovery exceeded three verified reboot attempts.'
            return 1
        fi
        old_boot_id=$current_boot_id
        pending_boot_id=$old_boot_id
        apo_state_set LAST_BOOT_ID "$old_boot_id"
        apo_state_save
        controller_reboot_issued=1
        if (( force_normal_reboot == 1 && forced_normal_reboot_done == 0 )); then
            apo_remote_worker "$APO_REMOTE_WORKER" reboot-normal "$APO_PERMANENT_CONFIG_HASH" >/dev/null 2>&1 || true
        else
            apo_remote_worker "$APO_REMOTE_WORKER" reboot-normal >/dev/null 2>&1 || true
        fi
        if ! apo_post_reboot_handshake "$old_boot_id" "$APO_BOOT_TIMEOUT" "$context"; then
            APO_RECOVERY_IN_PROGRESS=0
            APO_LAST_CLASS=RECOVERY_FAILURE
            if [[ ${APO_REBOOT_HANDSHAKE_STAGE:-wait} == worker ]]; then
                APO_LAST_REASON="Normal recovery reboot returned, but verification could not continue: $APO_LAST_REASON"
            else
                APO_LAST_REASON='Normal recovery reboot did not return to SSH.'
            fi
            return 1
        fi
        new_boot_id=$APO_REBOOT_BOOT_ID
        sleep "$APO_BOOT_SETTLE_SECONDS"
        if (( force_normal_reboot == 1 && forced_normal_reboot_done == 0 )); then
            forced_normal_reboot_done=1
            tryboot_flag=$(apo_remote_tryboot_flag || true)
            if [[ $tryboot_flag != 00000000 ]]; then
                APO_RECOVERY_IN_PROGRESS=0
                APO_LAST_CLASS=RECOVERY_FAILURE
                APO_LAST_REASON="Forced normal recovery reboot returned with tryboot flag ${tryboot_flag:-missing}."
                return 1
            fi
            if ! apo_verify_permanent_hash "${context}-post-forced-reboot"; then
                APO_RECOVERY_IN_PROGRESS=0
                return 1
            fi
        fi
        reboot_attempts=$((reboot_attempts + 1))
    done
    if [[ -z ${new_boot_id:-} ]]; then APO_RECOVERY_IN_PROGRESS=0; APO_LAST_CLASS=RECOVERY_FAILURE; APO_LAST_REASON='Normal recovery did not produce a verified normal boot ID.'; return 1; fi
    tryboot_flag=$(apo_remote_tryboot_flag || true)
    if [[ $tryboot_flag != 00000000 ]]; then APO_RECOVERY_IN_PROGRESS=0; APO_LAST_CLASS=RECOVERY_FAILURE; APO_LAST_REASON="Normal recovery still reports tryboot flag ${tryboot_flag:-missing}."; return 1; fi
    apo_state_set TRYBOOT_EXPECTED 0
    apo_state_set CURRENT_CPU ''
    apo_state_set CURRENT_GPU ''
    apo_state_set NORMAL_BOOT_ID "$new_boot_id"
    apo_state_set LAST_BOOT_ID "$new_boot_id"
    apo_state_save
    if ! apo_clear_managed_tryboot "$context"; then
        APO_RECOVERY_IN_PROGRESS=0
        return 1
    fi
    if ! apo_health_check "$APO_NORMAL_CPU" "$APO_NORMAL_GPU" "$APO_NORMAL_VOLTAGE" "$context"; then
        [[ $APO_LAST_CLASS == RECOVERY_FAILURE ]] || { APO_LAST_CLASS=RECOVERY_FAILURE; APO_LAST_REASON="Normal config returned but failed health: $APO_LAST_REASON"; }
        APO_RECOVERY_IN_PROGRESS=0
        return 1
    fi
    APO_RECOVERY_IN_PROGRESS=0
}

apo_recover_normal() { apo_return_normal "${1:-explicit-recovery}"; }

apo_recover_preserving_failure() {
    local recovery_context=$1 original_class=$2 original_reason=$3 force_normal_reboot=${4:-0} stress_reboot_scope=${5:-none}
    local recovery_class recovery_reason
    if apo_return_normal "$recovery_context" "$force_normal_reboot" "$stress_reboot_scope"; then
        if apo_transient_hash_read_failure_is_retryable "$original_class" "$original_reason" &&
           (( APO_RECOVERY_UNEXPECTED_CANDIDATE_REBOOT == 0 )); then
            if ! apo_verify_permanent_hash "${recovery_context}-hash-recheck"; then
                recovery_class=${APO_LAST_CLASS:-RECOVERY_FAILURE}
                recovery_reason=${APO_LAST_REASON:-unknown-hash-recheck-error}
                APO_LAST_CLASS=RECOVERY_FAILURE
                APO_LAST_REASON="Original $original_class: $original_reason; normal recovery health passed, but protected-config hash re-verification failed with $recovery_class: $recovery_reason"
                return 1
            fi
            APO_LAST_CLASS=HARNESS_FAILURE
            APO_LAST_REASON="Protected-config hash evidence was temporarily unavailable, but complete normal recovery re-proved the exact hash and health. Original evidence failure: $original_reason"
            return 0
        fi
        APO_LAST_CLASS=$original_class
        APO_LAST_REASON=$original_reason
        return 0
    fi
    recovery_class=${APO_LAST_CLASS:-RECOVERY_FAILURE}
    recovery_reason=${APO_LAST_REASON:-unknown-recovery-error}
    APO_LAST_CLASS=RECOVERY_FAILURE
    APO_LAST_REASON="Original $original_class: $original_reason; normal recovery failed with $recovery_class: $recovery_reason"
    return 1
}

apo_recover_observed_phase_failure() {
    local recovery_context=$1 original_class=$2 original_reason=$3 eligible=${4:-0}
    local observation_scope=${5:-none} promoted_class=${6:-BOOT_FAILURE} phase_description=${7:-candidate-gate}
    if ! apo_recover_preserving_failure "$recovery_context" "$original_class" "$original_reason" 0 "$observation_scope"; then
        return 1
    fi
    if [[ $original_class == HARNESS_FAILURE && $eligible == 1 &&
          $APO_RECOVERY_UNEXPECTED_CANDIDATE_REBOOT == 1 ]]; then
        APO_LAST_CLASS=$promoted_class
        APO_LAST_REASON="Candidate became unreachable without a structured result during $phase_description and rebooted unexpectedly from boot ${APO_RECOVERY_UNEXPECTED_REBOOT_FROM:-unknown} to verified normal boot ${APO_RECOVERY_UNEXPECTED_REBOOT_TO:-unknown}."
        apo_state_set LAST_FAILURE_CLASS "$APO_LAST_CLASS"
        apo_state_set LAST_FAILURE_REASON "$APO_LAST_REASON"
        apo_state_save
    fi
}

apo_recover_stress_failure() {
    local recovery_context=$1 original_class=$2 original_reason=$3 result_structured=${4:-1} stress_reboot_scope=${5:-none}
    if ! apo_recover_preserving_failure "$recovery_context" "$original_class" "$original_reason" 0 "$stress_reboot_scope"; then
        return 1
    fi
    if [[ $original_class == HARNESS_FAILURE && $result_structured == 0 &&
          $original_reason == 'The worker failed without a structured result.' &&
          $APO_RECOVERY_UNEXPECTED_CANDIDATE_REBOOT == 1 ]]; then
        APO_LAST_CLASS=STABILITY_FAILURE
        APO_LAST_REASON="Candidate became unreachable without a structured result during stress and rebooted unexpectedly from boot ${APO_RECOVERY_UNEXPECTED_REBOOT_FROM:-unknown} to verified normal boot ${APO_RECOVERY_UNEXPECTED_REBOOT_TO:-unknown}."
        apo_state_set LAST_FAILURE_CLASS "$APO_LAST_CLASS"
        apo_state_set LAST_FAILURE_REASON "$APO_LAST_REASON"
        apo_state_save
    fi
}

apo_record_failure_after_recovery() {
    local recovery_context=$1 original_class=$2 original_reason=$3 force_normal_reboot=${4:-0}
    if apo_recover_preserving_failure "$recovery_context" "$original_class" "$original_reason" "$force_normal_reboot"; then
        apo_state_fail "$original_class" "$original_reason"
    else
        apo_state_fail RECOVERY_FAILURE "$APO_LAST_REASON"
    fi
}

apo_prove_tryboot_recovery() {
    apo_state_phase TRYBOOT_PROOF CANDIDATE_BOOT RUNNING
    apo_boot_candidate "$APO_NORMAL_CPU" "$APO_NORMAL_GPU" baseline-safety-proof || {
        local candidate_class=$APO_LAST_CLASS candidate_reason=$APO_LAST_REASON
        apo_record_failure_after_recovery baseline-safety-fallback "$candidate_class" "$candidate_reason"
        return 1
    }
    apo_return_normal baseline-safety-normal || { apo_state_fail RECOVERY_FAILURE "$APO_LAST_REASON"; return 1; }
    apo_event baseline-safety-proof PASS '' 'The installed baseline completed a temporary tryboot and verified normal recovery before clock sweeping began.'
}
