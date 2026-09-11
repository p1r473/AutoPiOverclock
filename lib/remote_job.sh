#!/usr/bin/env bash
# Durable target-side stress jobs. Only the controller owns classification and
# recovery decisions; the target owns the fixed stress deadline and evidence.

APO_REMOTE_STRESS_RC=1
APO_REMOTE_JOB_COMPLETE=0
APO_REMOTE_JOB_COMPLETE_RC=''
APO_REMOTE_JOB_COMPLETE_SIZE=''
APO_REMOTE_JOB_COMPLETE_HASH=''
APO_REMOTE_JOB_COMPLETE_END_EPOCH=''
APO_REMOTE_JOB_COMPLETE_BOOT_ID=''
APO_REMOTE_JOB_FOLLOW_ERROR=''
APO_REMOTE_JOB_PROBE_BOOT=''

apo_remote_job_pending() {
    [[ $(apo_state_get REMOTE_STRESS_STATUS IDLE) == RUNNING ]] || return 1
    apo_remote_job_valid_id "$(apo_state_get REMOTE_STRESS_JOB_ID '')" || return 1
    apo_remote_job_valid_hash "$(apo_state_get REMOTE_STRESS_TOKEN '')" || return 1
    apo_remote_job_valid_hash "$(apo_state_get REMOTE_STRESS_SPEC_HASH '')" || return 1
    apo_remote_job_valid_boot_id "$(apo_state_get REMOTE_STRESS_SOURCE_BOOT_ID '')" || return 1
    [[ -n $(apo_state_get REMOTE_STRESS_PHASE '') && $(apo_state_get REMOTE_STRESS_DURATION_S '') =~ ^[1-9][0-9]*$ ]]
}

apo_remote_job_valid_id() { [[ ${1-} =~ ^job-[0-9a-f]{32}$ ]]; }
apo_remote_job_valid_hash() { [[ ${1-} =~ ^[0-9a-f]{64}$ ]]; }
apo_remote_job_valid_boot_id() { [[ ${1-} =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; }

apo_remote_job_token() {
    od -An -N32 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n'
}

apo_remote_job_spec_hash() {
    local phase=$1 worker_command=$2
    shift 2
    { printf '%s\0' "$phase" "$worker_command" "$@"; } | sha256sum | awk 'NR == 1 {print $1}'
}

apo_remote_job_command() {
    local argument command_line
    command_line=$(apo_sh_quote "$APO_REMOTE_JOB_HELPER")
    for argument in "$@"; do command_line+=" $(apo_sh_quote "$argument")"; done
    apo_remote_root "$command_line"
}

apo_remote_job_read_file() {
    local output_file=$1
    shift
    local argument command_line
    command_line=$(apo_sh_quote "$APO_REMOTE_JOB_HELPER")
    for argument in "$@"; do command_line+=" $(apo_sh_quote "$argument")"; done
    apo_remote_root_read_file "$output_file" "$command_line"
}

apo_remote_job_clear_state() {
    apo_state_set REMOTE_STRESS_STATUS IDLE
    apo_state_set REMOTE_STRESS_JOB_ID ''
    apo_state_set REMOTE_STRESS_TOKEN ''
    apo_state_set REMOTE_STRESS_SPEC_HASH ''
    apo_state_set REMOTE_STRESS_SOURCE_BOOT_ID ''
    apo_state_set REMOTE_STRESS_PHASE ''
    apo_state_set REMOTE_STRESS_DURATION_S ''
    apo_state_set REMOTE_STRESS_START_EPOCH ''
    apo_state_set REMOTE_STRESS_LAST_SEEN_EPOCH ''
}

apo_remote_job_emit_structured_failure() {
    local output_file=$1 failure_class=$2 failure_reason=$3
    printf 'APO_RESULT_CLASS=%s\nAPO_RESULT_REASON_B64=%s\n' \
        "$failure_class" "$(printf '%s' "$failure_reason" | base64 | tr -d '\n')" >>"$output_file"
}

apo_remote_job_progress_tick() {
    local now=${1:-} start=${2:-} duration=${3:-} elapsed
    [[ $now =~ ^[0-9]+$ && $start =~ ^[0-9]+$ && $duration =~ ^[1-9][0-9]*$ ]] || return 0
    elapsed=$((now - start))
    (( elapsed < 0 )) && elapsed=0
    (( elapsed > duration )) && elapsed=$duration
    APO_PROGRESS_STRESS_ELAPSED=$elapsed
    APO_PROGRESS_STRESS_DURATION=$duration
    if declare -F apo_progress_render >/dev/null 2>&1; then apo_progress_render "$elapsed" "$duration"; fi
}

apo_remote_job_follow_stream() {
    local line record state now start duration source_boot size telemetry
    local rc output_hash end_epoch
    while IFS= read -r line || [[ -n $line ]]; do
        IFS=$'\t' read -r record state now start duration source_boot size telemetry <<<"$line"
        case $record in
            APO_JOB_HEARTBEAT)
                if [[ ( $state == RUNNING || $state == COMPLETE ) && $now =~ ^[0-9]+$ &&
                      $start =~ ^[0-9]+$ && $duration =~ ^[1-9][0-9]*$ &&
                      $source_boot == "$(apo_state_get REMOTE_STRESS_SOURCE_BOOT_ID '')" &&
                      $size =~ ^[0-9]+$ ]]; then
                    apo_remote_job_progress_tick "$now" "$start" "$duration"
                    if [[ -n $telemetry ]]; then
                        line=$(apo_decode_b64 "$telemetry" || true)
                        if [[ -n $line ]] && apo_progress_line_is_telemetry "$line"; then
                            apo_progress_parse_telemetry_line "$line"
                            apo_remote_job_progress_tick "$now" "$start" "$duration"
                        fi
                    fi
                    apo_state_set REMOTE_STRESS_START_EPOCH "$start"
                    apo_state_set REMOTE_STRESS_LAST_SEEN_EPOCH "$now"
                else
                    APO_REMOTE_JOB_FOLLOW_ERROR='The detached stress heartbeat was malformed or did not match saved ownership.'
                    return 1
                fi
                ;;
            APO_JOB_COMPLETE)
                rc=$state
                output_hash=$start
                end_epoch=$duration
                if [[ $rc =~ ^[0-9]+$ && $now =~ ^[0-9]+$ && $output_hash =~ ^[0-9a-f]{64}$ &&
                      $end_epoch =~ ^[0-9]+$ && $source_boot == "$(apo_state_get REMOTE_STRESS_SOURCE_BOOT_ID '')" ]]; then
                    APO_REMOTE_JOB_COMPLETE=1
                    APO_REMOTE_JOB_COMPLETE_RC=$rc
                    APO_REMOTE_JOB_COMPLETE_SIZE=$now
                    APO_REMOTE_JOB_COMPLETE_HASH=$output_hash
                    APO_REMOTE_JOB_COMPLETE_END_EPOCH=$end_epoch
                    APO_REMOTE_JOB_COMPLETE_BOOT_ID=$source_boot
                else
                    APO_REMOTE_JOB_FOLLOW_ERROR='The detached stress completion record was malformed or did not match saved ownership.'
                    return 1
                fi
                ;;
            APO_JOB_ERROR)
                APO_REMOTE_JOB_FOLLOW_ERROR=${state:-The target-side stress supervisor reported an error.}
                return 1
                ;;
            '') ;;
            *)
                APO_REMOTE_JOB_FOLLOW_ERROR='The target-side stress supervisor emitted an unknown record.'
                return 1
                ;;
        esac
    done
}

apo_validate_remote_job_state() {
    local status job_id token spec_hash source_boot phase duration start_epoch last_seen
    local unknown_context unknown_count network_count network_event network_target
    status=$(apo_state_get REMOTE_STRESS_STATUS IDLE)
    job_id=$(apo_state_get REMOTE_STRESS_JOB_ID '')
    token=$(apo_state_get REMOTE_STRESS_TOKEN '')
    spec_hash=$(apo_state_get REMOTE_STRESS_SPEC_HASH '')
    source_boot=$(apo_state_get REMOTE_STRESS_SOURCE_BOOT_ID '')
    phase=$(apo_state_get REMOTE_STRESS_PHASE '')
    duration=$(apo_state_get REMOTE_STRESS_DURATION_S '')
    start_epoch=$(apo_state_get REMOTE_STRESS_START_EPOCH '')
    last_seen=$(apo_state_get REMOTE_STRESS_LAST_SEEN_EPOCH '')
    case $status in
        IDLE)
            if [[ -n $job_id || -n $token || -n $spec_hash || -n $source_boot || -n $phase ||
                  -n $duration || -n $start_epoch || -n $last_seen ]]; then
                APO_AUTO_VALIDATION_REASON='Saved detached-stress state retains ownership fields while idle.'
                return 1
            fi
            ;;
        RUNNING)
            apo_remote_job_valid_id "$job_id" && apo_remote_job_valid_hash "$token" &&
                apo_remote_job_valid_hash "$spec_hash" && apo_remote_job_valid_boot_id "$source_boot" &&
                [[ -n $phase && $duration =~ ^[1-9][0-9]*$ ]] || {
                    APO_AUTO_VALIDATION_REASON='Saved detached-stress ownership is incomplete or malformed.'
                    return 1
                }
            [[ -z $start_epoch || $start_epoch =~ ^[1-9][0-9]*$ ]] || {
                APO_AUTO_VALIDATION_REASON='Saved detached-stress start time is malformed.'
                return 1
            }
            [[ -z $last_seen || $last_seen =~ ^[1-9][0-9]*$ ]] || {
                APO_AUTO_VALIDATION_REASON='Saved detached-stress heartbeat time is malformed.'
                return 1
            }
            ;;
        *)
            APO_AUTO_VALIDATION_REASON="Saved detached-stress status is malformed: ${status:-missing}"
            return 1
            ;;
    esac
    unknown_context=$(apo_state_get UNATTRIBUTED_REBOOT_REPLAY_CONTEXT '')
    unknown_count=$(apo_state_get UNATTRIBUTED_REBOOT_REPLAY_COUNT 0)
    [[ $unknown_count =~ ^[0-9]+$ ]] || {
        APO_AUTO_VALIDATION_REASON='Saved unattributed-reboot replay count is malformed.'
        return 1
    }
    if (( unknown_count == 0 )); then
        [[ -z $unknown_context ]] || {
            APO_AUTO_VALIDATION_REASON='Saved unattributed-reboot replay context exists with a zero count.'
            return 1
        }
    else
        [[ $unknown_count == 1 && -n $unknown_context ]] || {
            APO_AUTO_VALIDATION_REASON='Saved unattributed-reboot replay evidence is incomplete.'
            return 1
        }
    fi
    network_count=$(apo_state_get NETWORK_WATCHDOG_REPLAY_COUNT 0)
    network_event=$(apo_state_get NETWORK_WATCHDOG_LAST_EVENT_ID '')
    network_target=$(apo_state_get NETWORK_WATCHDOG_LAST_TARGET '')
    [[ $network_count =~ ^[0-9]+$ ]] || {
        APO_AUTO_VALIDATION_REASON='Saved network-watchdog replay count is malformed.'
        return 1
    }
    if (( network_count == 0 )); then
        [[ -z $network_event && -z $network_target ]] || {
            APO_AUTO_VALIDATION_REASON='Saved network-watchdog identity exists with a zero replay count.'
            return 1
        }
    else
        [[ $network_event =~ ^[0-9a-f]{32}$ && $network_target =~ ^[0-9]+([.][0-9]+){3}$ ]] || {
            APO_AUTO_VALIDATION_REASON='Saved network-watchdog replay identity is malformed.'
            return 1
        }
    fi
}

apo_remote_job_probe_boot_with_ticks() {
    local temporary_file probe_pid now start duration
    temporary_file=$(mktemp)
    start=$(apo_state_get REMOTE_STRESS_START_EPOCH '')
    duration=$(apo_state_get REMOTE_STRESS_DURATION_S '')
    APO_REMOTE_JOB_PROBE_BOOT=''
    apo_remote_boot_id_once >"$temporary_file" 2>/dev/null &
    probe_pid=$!
    while kill -0 "$probe_pid" 2>/dev/null; do
        now=$(date +%s)
        apo_remote_job_progress_tick "$now" "$start" "$duration"
        sleep 1
    done
    if wait "$probe_pid"; then
        APO_REMOTE_JOB_PROBE_BOOT=$(<"$temporary_file")
    fi
    rm -f -- "$temporary_file"
}

apo_remote_job_wait_for_boot() {
    local context=$1 source_boot=$2 next_notice now start duration
    start=$(apo_state_get REMOTE_STRESS_START_EPOCH '')
    duration=$(apo_state_get REMOTE_STRESS_DURATION_S '')
    apo_recovery_wait_checkpoint WAITING "$context"
    apo_recovery_wait_event WARN "$context" 'Cannot reach the target stress job. Retrying indefinitely without starting a duplicate or changing clocks.'
    next_notice=$((SECONDS + APO_PERSISTENT_SSH_NOTICE_SECONDS))
    while :; do
        apo_remote_job_probe_boot_with_ticks
        if apo_remote_job_valid_boot_id "$APO_REMOTE_JOB_PROBE_BOOT"; then
            apo_recovery_wait_checkpoint RETURNED "$context"
            if [[ $APO_REMOTE_JOB_PROBE_BOOT == "$source_boot" ]]; then
                apo_recovery_wait_event INFO "$context" 'SSH returned on the same target boot. Reattaching to the existing stress job.'
            else
                apo_recovery_wait_event WARN "$context" "SSH returned on a new target boot $APO_REMOTE_JOB_PROBE_BOOT. Classifying the reboot before any clock decision."
            fi
            return 0
        fi
        now=$(date +%s)
        apo_remote_job_progress_tick "$now" "$start" "$duration"
        if (( SECONDS >= next_notice )); then
            apo_recovery_wait_event INFO "$context" 'The target is still unreachable. The controller will keep retrying and the target-side deadline remains authoritative.'
            next_notice=$((SECONDS + APO_PERSISTENT_SSH_NOTICE_SECONDS))
        fi
        sleep 1
    done
}

apo_remote_job_classify_reboot() {
    local phase=$1 output_file=$2 old_boot=$3 new_boot=$4 proof_reason replay_context replay_count
    if ! apo_redeploy_worker_for_boot "$new_boot" "${phase}-reboot-proof"; then
        apo_remote_job_emit_structured_failure "$output_file" RECOVERY_FAILURE \
            "The target rebooted during stress, but the worker needed for strict reboot proof could not be restored: $APO_LAST_REASON"
        return 1
    fi
    if declare -F apo_profile_prove_network_watchdog_reboot >/dev/null 2>&1 &&
       apo_profile_prove_network_watchdog_reboot "$phase" "$old_boot" "$new_boot"; then
        proof_reason=${APO_NETWORK_WATCHDOG_PROOF_REASON:-A project-owned network-watchdog reboot was strictly proved.}
        apo_state_set NETWORK_WATCHDOG_LAST_EVENT_ID "${APO_NETWORK_WATCHDOG_EVENT_ID:-}"
        apo_state_set NETWORK_WATCHDOG_LAST_TARGET "${APO_NETWORK_WATCHDOG_TARGET:-}"
        apo_state_set NETWORK_WATCHDOG_REPLAY_COUNT "$(( $(apo_state_get NETWORK_WATCHDOG_REPLAY_COUNT 0) + 1 ))"
        apo_state_save
        apo_remote_job_emit_structured_failure "$output_file" HARNESS_FAILURE "[PROVED_NETWORK_WATCHDOG] $proof_reason The complete stress duration must restart at the same clocks."
        return 1
    fi
    replay_context="${phase}:$(apo_state_get REMOTE_STRESS_SPEC_HASH '')"
    replay_count=$(apo_state_get UNATTRIBUTED_REBOOT_REPLAY_COUNT 0)
    [[ $replay_count =~ ^[0-9]+$ ]] || replay_count=0
    if [[ $(apo_state_get UNATTRIBUTED_REBOOT_REPLAY_CONTEXT '') != "$replay_context" ]]; then replay_count=0; fi
    if (( replay_count == 0 )); then
        apo_state_set UNATTRIBUTED_REBOOT_REPLAY_CONTEXT "$replay_context"
        apo_state_set UNATTRIBUTED_REBOOT_REPLAY_COUNT 1
        apo_state_save
        apo_remote_job_emit_structured_failure "$output_file" HARNESS_FAILURE \
            'The target rebooted during stress, but strict network-watchdog proof was absent or incomplete. One conservative full-duration replay at the same clocks is required before this pair can be treated as unstable.'
        return 1
    fi
    # A second unattributed reboot of the identical gate is intentionally left
    # unstructured so the existing recovery classifier can promote it to an
    # instability boundary and invoke CPU/GPU isolation.
    return 1
}

apo_remote_job_fetch_complete() {
    local output_file=$1 temporary_file actual_size actual_hash
    temporary_file="${output_file}.remote-job.${BASHPID}"
    rm -f -- "$temporary_file"
    apo_remote_job_read_file "$temporary_file" fetch "$APO_REMOTE_WORK_DIR" \
        "$(apo_state_get REMOTE_STRESS_JOB_ID '')" "$(apo_state_get REMOTE_STRESS_TOKEN '')" \
        "$(apo_state_get REMOTE_STRESS_SPEC_HASH '')" || {
            rm -f -- "$temporary_file"
            return 1
        }
    actual_size=$(wc -c <"$temporary_file" | tr -d '[:space:]')
    actual_hash=$(sha256sum "$temporary_file" | awk 'NR == 1 {print $1}')
    if [[ $actual_size != "$APO_REMOTE_JOB_COMPLETE_SIZE" || $actual_hash != "$APO_REMOTE_JOB_COMPLETE_HASH" ]]; then
        rm -f -- "$temporary_file"
        return 1
    fi
    : >"$output_file"
    apo_progress_capture_worker_stream "$output_file" <"$temporary_file"
    rm -f -- "$temporary_file"
    APO_REMOTE_STRESS_RC=$APO_REMOTE_JOB_COMPLETE_RC
    apo_remote_job_clear_state
    apo_state_set UNATTRIBUTED_REBOOT_REPLAY_CONTEXT ''
    apo_state_set UNATTRIBUTED_REBOOT_REPLAY_COUNT 0
    apo_state_save
}

apo_run_remote_stress_capture() {
    local phase=$1 worker_command=$2 output_file=$3
    shift 3
    local duration=${2:-} spec_hash job_id token source_boot start_output remote_rc current_boot lastpipe_was_set=0
    local launch_attempt=0 launch_attempts=${APO_TRANSIENT_WORKER_ATTEMPTS:-5} launch_reason
    [[ $worker_command == stress && $duration =~ ^[1-9][0-9]*$ ]] || return 2
    [[ $launch_attempts =~ ^[1-9][0-9]*$ ]] || launch_attempts=5
    spec_hash=$(apo_remote_job_spec_hash "$phase" "$worker_command" "$@")
    if [[ $(apo_state_get REMOTE_STRESS_STATUS IDLE) == RUNNING ]]; then
        job_id=$(apo_state_get REMOTE_STRESS_JOB_ID '')
        token=$(apo_state_get REMOTE_STRESS_TOKEN '')
        source_boot=$(apo_state_get REMOTE_STRESS_SOURCE_BOOT_ID '')
        if ! apo_remote_job_valid_id "$job_id" || ! apo_remote_job_valid_hash "$token" ||
           ! apo_remote_job_valid_boot_id "$source_boot" ||
           [[ $(apo_state_get REMOTE_STRESS_SPEC_HASH '') != "$spec_hash" ||
              $(apo_state_get REMOTE_STRESS_PHASE '') != "$phase" ||
              $(apo_state_get REMOTE_STRESS_DURATION_S '') != "$duration" ]]; then
            apo_remote_job_emit_structured_failure "$output_file" RECOVERY_FAILURE \
                'Saved detached-stress ownership does not match the requested gate. Automatic adoption is refused.'
            return 1
        fi
    else
        token=$(apo_remote_job_token)
        apo_remote_job_valid_hash "$token" || {
            apo_remote_job_emit_structured_failure "$output_file" HARNESS_FAILURE 'Could not create a detached-stress ownership token.'
            return 1
        }
        job_id="job-${token:0:32}"
        source_boot=$(apo_remote_boot_id || true)
        apo_remote_job_valid_boot_id "$source_boot" || {
            apo_remote_job_emit_structured_failure "$output_file" HARNESS_FAILURE 'Could not read the target boot ID before detached stress launch.'
            return 1
        }
        apo_state_set REMOTE_STRESS_STATUS RUNNING
        apo_state_set REMOTE_STRESS_JOB_ID "$job_id"
        apo_state_set REMOTE_STRESS_TOKEN "$token"
        apo_state_set REMOTE_STRESS_SPEC_HASH "$spec_hash"
        apo_state_set REMOTE_STRESS_SOURCE_BOOT_ID "$source_boot"
        apo_state_set REMOTE_STRESS_PHASE "$phase"
        apo_state_set REMOTE_STRESS_DURATION_S "$duration"
        apo_state_set REMOTE_STRESS_START_EPOCH ''
        apo_state_set REMOTE_STRESS_LAST_SEEN_EPOCH ''
        apo_state_save
    fi

    while :; do
        current_boot=$(apo_remote_boot_id_once 2>/dev/null || true)
        if [[ -z $current_boot ]]; then
            apo_remote_job_wait_for_boot "${phase}-network-wait" "$source_boot"
            current_boot=$APO_REMOTE_JOB_PROBE_BOOT
        fi
        if [[ $current_boot != "$source_boot" ]]; then
            apo_remote_job_classify_reboot "$phase" "$output_file" "$source_boot" "$current_boot"
            apo_remote_job_clear_state
            apo_state_save
            return 1
        fi
        start_output=''
        if ! start_output=$(apo_remote_job_command start "$APO_REMOTE_WORK_DIR" "$job_id" "$token" \
            "$spec_hash" "$source_boot" "$duration" "$APO_REMOTE_WORKER" "$@" 2>/dev/null); then
            if [[ $start_output =~ ^APO_JOB_ERROR$'\t'(.+)$ ]]; then
                launch_reason=${BASH_REMATCH[1]}
                apo_remote_job_emit_structured_failure "$output_file" RECOVERY_FAILURE \
                    "The target-side detached stress launcher refused the saved job: $launch_reason"
                return 1
            fi
            if [[ -n $start_output ]]; then
                apo_remote_job_emit_structured_failure "$output_file" RECOVERY_FAILURE \
                    'The target-side detached stress launcher returned malformed failure evidence.'
                return 1
            fi
            current_boot=$(apo_remote_boot_id_once 2>/dev/null || true)
            if [[ -z $current_boot ]]; then
                apo_remote_job_wait_for_boot "${phase}-launch-wait" "$source_boot"
                current_boot=$APO_REMOTE_JOB_PROBE_BOOT
                launch_attempt=0
            fi
            if [[ $current_boot != "$source_boot" ]]; then
                apo_remote_job_classify_reboot "$phase" "$output_file" "$source_boot" "$current_boot"
                apo_remote_job_clear_state
                apo_state_save
                return 1
            fi
            launch_attempt=$((launch_attempt + 1))
            if (( launch_attempt >= launch_attempts )); then
                apo_remote_job_emit_structured_failure "$output_file" HARNESS_FAILURE \
                    "The detached stress launcher remained unavailable on the original boot after $launch_attempts attempts."
                return 1
            fi
            apo_recovery_wait_event WARN "${phase}-launch-retry" \
                "The target is reachable on the original boot, but detached stress launch did not complete. Retrying the same owned launch (attempt $((launch_attempt + 1))/$launch_attempts)."
            if declare -F apo_transient_read_delay >/dev/null 2>&1; then apo_transient_read_delay; else sleep 10; fi
            continue
        fi
        if [[ $start_output =~ ^APO_JOB_STARTED$'\t'(RUNNING|COMPLETE)$'\t'([0-9]+)$ ]]; then
            launch_attempt=0
            apo_state_set REMOTE_STRESS_START_EPOCH "${BASH_REMATCH[2]}"
            apo_state_save
        else
            apo_remote_job_emit_structured_failure "$output_file" RECOVERY_FAILURE 'The detached stress launcher returned malformed ownership evidence.'
            return 1
        fi

        APO_REMOTE_JOB_COMPLETE=0
        APO_REMOTE_JOB_FOLLOW_ERROR=''
        set +e
        shopt -q lastpipe && lastpipe_was_set=1
        shopt -s lastpipe
        # SSH diagnostics belong to the transport, not the target job protocol.
        apo_remote_job_command follow "$APO_REMOTE_WORK_DIR" "$job_id" "$token" "$spec_hash" 2>/dev/null |
            apo_remote_job_follow_stream
        remote_rc=${PIPESTATUS[0]}
        (( lastpipe_was_set == 1 )) || shopt -u lastpipe
        set -e
        if (( APO_REMOTE_JOB_COMPLETE == 1 )); then
            if ! apo_remote_job_fetch_complete "$output_file"; then
                apo_remote_job_emit_structured_failure "$output_file" RECOVERY_FAILURE 'Completed detached-stress evidence could not be fetched and hash-verified.'
                return 1
            fi
            return "$APO_REMOTE_STRESS_RC"
        fi
        current_boot=$(apo_remote_boot_id_once 2>/dev/null || true)
        if [[ -z $current_boot ]]; then
            apo_remote_job_wait_for_boot "${phase}-network-wait" "$source_boot"
            current_boot=$APO_REMOTE_JOB_PROBE_BOOT
        elif [[ -n $APO_REMOTE_JOB_FOLLOW_ERROR && $remote_rc != 255 ]]; then
            apo_remote_job_emit_structured_failure "$output_file" RECOVERY_FAILURE "$APO_REMOTE_JOB_FOLLOW_ERROR"
            return 1
        elif (( remote_rc == 0 )); then
            apo_remote_job_emit_structured_failure "$output_file" RECOVERY_FAILURE \
                'The detached stress follow stream ended cleanly without a completion record.'
            return 1
        fi
        if [[ $current_boot != "$source_boot" ]]; then
            apo_remote_job_classify_reboot "$phase" "$output_file" "$source_boot" "$current_boot"
            apo_remote_job_clear_state
            apo_state_save
            return 1
        fi
        if [[ -n $APO_REMOTE_JOB_FOLLOW_ERROR ]]; then
            apo_recovery_wait_event INFO "${phase}-network-wait" 'SSH interrupted a target-job record. The target is on the original boot, so the controller is discarding that partial record and reattaching by saved ownership.'
        else
            apo_recovery_wait_event INFO "${phase}-network-wait" 'The target is reachable on the original boot. Reattaching to the same detached stress job.'
        fi
    done
}
