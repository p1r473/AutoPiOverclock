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
APO_REMOTE_JOB_LAST_CHECKPOINT_EPOCH=0
APO_REMOTE_JOB_CHECKPOINT_FAILURES=0
APO_REMOTE_JOB_DURABLE_REASON='not-checked'
APO_REMOTE_JOB_FOLLOW_TRANSPORT_RC=1
APO_REMOTE_JOB_FOLLOW_PID=''
APO_REMOTE_JOB_FOLLOW_FD=''
APO_REMOTE_JOB_FOLLOW_INPUT_FD=''
APO_REMOTE_STRESS_CREDIT_ADDED=0
APO_REMOTE_STRESS_CREDIT_TOTAL=0
APO_REMOTE_STRESS_CREDIT_REMAINING=0
APO_REMOTE_JOB_TEMP_SEQUENCE=0
readonly APO_REMOTE_JOB_CONFIRMED_SAMPLE_LIMIT=512

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

# Keep enough distinct target telemetry samples to select the newest sample at
# or before a later proved watchdog request. Strict Batocera proof requires the
# request to bound the new boot within 120 seconds and Debian permits up to 300
# seconds for its committed reboot to begin. Retaining 512 distinct one-second
# samples covers either proof window while keeping controller state bounded.
apo_remote_job_record_confirmed_sample() {
    local now=$1 elapsed=$2 duration=$3 history current entry sample_epoch sample_elapsed
    local previous_epoch=0 previous_elapsed=-1 index start_index joined=''
    local -a samples=()
    [[ $now =~ ^[1-9][0-9]*$ && $elapsed =~ ^[0-9]+$ &&
       $duration =~ ^[1-9][0-9]*$ && $elapsed -le $duration ]] || return 1
    history=$(apo_state_get REMOTE_STRESS_CONFIRMED_SAMPLES '')
    current=$(apo_state_get REMOTE_STRESS_CONFIRMED_ELAPSED_S '')
    if [[ -n $history ]]; then
        IFS=',' read -r -a samples <<<"$history"
        for entry in "${samples[@]}"; do
            [[ $entry =~ ^([1-9][0-9]*):([0-9]+)$ ]] || return 1
            sample_epoch=${BASH_REMATCH[1]}
            sample_elapsed=${BASH_REMATCH[2]}
            (( sample_epoch > previous_epoch && sample_elapsed > previous_elapsed &&
               sample_elapsed <= duration )) || return 1
            previous_epoch=$sample_epoch
            previous_elapsed=$sample_elapsed
        done
        [[ $current =~ ^[0-9]+$ && $current == "$previous_elapsed" ]] || return 1
    elif [[ -n $current && ! $current =~ ^[0-9]+$ ]]; then
        return 1
    fi

    # Repeated heartbeats commonly carry the same last telemetry line. Retain
    # the timestamp at which that workload value was first observed instead of
    # moving it past a watchdog request that becomes known only after reboot.
    if [[ -n $current ]] && (( elapsed <= current )); then return 0; fi
    if (( previous_epoch > 0 && now <= previous_epoch )); then return 0; fi
    samples+=("$now:$elapsed")
    start_index=$((${#samples[@]} - APO_REMOTE_JOB_CONFIRMED_SAMPLE_LIMIT))
    if (( start_index < 0 )); then start_index=0; fi
    for (( index=start_index; index<${#samples[@]}; index++ )); do
        [[ -z $joined ]] || joined+=','
        joined+=${samples[$index]}
    done
    apo_state_set REMOTE_STRESS_CONFIRMED_SAMPLES "$joined"
    apo_state_set REMOTE_STRESS_CONFIRMED_ELAPSED_S "$elapsed"
}

# A controller checkpoint failure may leave a valid target-owned stress job
# running. Preserve it only when the last committed state contains the exact
# same run, target, boot, workload, and ownership identity as controller memory.
apo_remote_job_durable_pending() {
    local state_key
    local -A durable_job=()
    local -a identity_keys=(
        FORMAT_VERSION RUN_ID TARGET_SLUG REMOTE_TARGET STATUS
        REMOTE_STRESS_STATUS REMOTE_STRESS_JOB_ID REMOTE_STRESS_TOKEN
        REMOTE_STRESS_SPEC_HASH REMOTE_STRESS_SOURCE_BOOT_ID
        REMOTE_STRESS_PHASE REMOTE_STRESS_DURATION_S REMOTE_STRESS_SEGMENT_DURATION_S
    )
    APO_REMOTE_JOB_DURABLE_REASON='not-proven'
    if [[ -z ${APO_STATE_FILE:-} || ! -f ${APO_STATE_FILE:-} ]]; then
        APO_REMOTE_JOB_DURABLE_REASON='committed-state-unavailable'
        return 1
    fi
    if ! apo_remote_job_pending; then
        APO_REMOTE_JOB_DURABLE_REASON='memory-job-not-pending'
        return 1
    fi
    if ! apo_state_load_fields "$APO_STATE_FILE" durable_job "${identity_keys[@]}"; then
        APO_REMOTE_JOB_DURABLE_REASON='committed-state-invalid'
        return 1
    fi
    if [[ ${durable_job[FORMAT_VERSION]:-} != 1 || ${durable_job[STATUS]:-} != RUNNING ]]; then
        APO_REMOTE_JOB_DURABLE_REASON='committed-run-not-running'
        return 1
    fi
    for state_key in "${identity_keys[@]}"; do
        if [[ ! -v durable_job[$state_key] || ! -v APO_STATE[$state_key] ]]; then
            APO_REMOTE_JOB_DURABLE_REASON="missing-identity-$state_key"
            return 1
        fi
        if [[ ${durable_job[$state_key]} != "${APO_STATE[$state_key]}" ]]; then
            APO_REMOTE_JOB_DURABLE_REASON="identity-mismatch-$state_key"
            return 1
        fi
    done
    APO_REMOTE_JOB_DURABLE_REASON='exact-match'
    return 0
}

apo_remote_job_child_status_log() {
    local operation=$1 command_rc=$2 output_valid=$3 reconciled=$4 timestamp rendered
    printf -v timestamp '%(%Y-%m-%d %H:%M:%S)T' -1
    rendered="$timestamp [WARN] remote-job-child-status: operation=$operation rc=$command_rc output_valid=$output_valid reconciled=$reconciled shell_pid=$BASHPID shell_flags=$-"
    if declare -F apo_progress_before_output >/dev/null 2>&1; then apo_progress_before_output || true; fi
    printf '%s\n' "$rendered" >&2
    if [[ -n ${APO_LOG_FILE:-} ]]; then printf '%s\n' "$rendered" >> "$APO_LOG_FILE" 2>/dev/null || true; fi
    if declare -F apo_progress_after_output >/dev/null 2>&1; then apo_progress_after_output || true; fi
}

apo_remote_job_stage_log() {
    local phase=$1 stage=$2 detail=${3:-none} timestamp rendered
    printf -v timestamp '%(%Y-%m-%d %H:%M:%S)T' -1
    rendered="$timestamp [INFO] remote-job-stage: phase=$phase stage=$stage detail=$detail shell_pid=$BASHPID controller_pid=${APO_CONTROLLER_SHELL_PID:-unknown} shell_flags=$-"
    if [[ -n ${APO_LOG_FILE:-} ]]; then printf '%s\n' "$rendered" >>"$APO_LOG_FILE" 2>/dev/null || true; fi
}

apo_remote_job_create_temporary_file() {
    local output_name=$1 prefix=$2 attempt candidate created=0 noclobber_was_set=0
    [[ $output_name =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
    local -n temporary_output=$output_name
    umask 077
    [[ $- == *C* ]] && noclobber_was_set=1 || set -C
    for (( attempt=1; attempt<=100; attempt++ )); do
        APO_REMOTE_JOB_TEMP_SEQUENCE=$((APO_REMOTE_JOB_TEMP_SEQUENCE + 1))
        candidate="${prefix}.tmp.${BASHPID}.${APO_REMOTE_JOB_TEMP_SEQUENCE}"
        if { : > "$candidate"; } 2>/dev/null; then
            temporary_output=$candidate
            created=1
            break
        fi
    done
    (( noclobber_was_set == 1 )) || set +C
    (( created == 1 ))
}

apo_remote_job_hash_file() {
    local source_file=$1 operation=${2:-sha256sum} attempt command_rc=0 hash_output hash_value remainder
    for (( attempt=1; attempt<=3; attempt++ )); do
        hash_output=''
        if hash_output=$(sha256sum -- "$source_file" 2>/dev/null); then command_rc=0; else command_rc=$?; fi
        hash_value=''
        remainder=''
        IFS=$' \t' read -r hash_value remainder <<< "$hash_output"
        if apo_remote_job_valid_hash "$hash_value"; then
            if (( command_rc != 0 )); then apo_remote_job_child_status_log "$operation" "$command_rc" 1 1; fi
            printf '%s' "$hash_value"
            return 0
        fi
        apo_remote_job_child_status_log "$operation" "$command_rc" 0 0
    done
    return 1
}

apo_remote_job_token() {
    local attempt command_rc=0 raw_token token
    for (( attempt=1; attempt<=3; attempt++ )); do
        raw_token=''
        if raw_token=$(od -An -N32 -tx1 /dev/urandom 2>/dev/null); then command_rc=0; else command_rc=$?; fi
        token=${raw_token//$' '/}
        token=${token//$'\t'/}
        token=${token//$'\r'/}
        token=${token//$'\n'/}
        if apo_remote_job_valid_hash "$token"; then
            if (( command_rc != 0 )); then apo_remote_job_child_status_log token-od "$command_rc" 1 1; fi
            printf '%s' "$token"
            return 0
        fi
        apo_remote_job_child_status_log token-od "$command_rc" 0 0
    done
    return 1
}

apo_remote_job_spec_hash() {
    local phase=$1 worker_command=$2 temporary_file='' hash_value='' hash_rc=0
    shift 2
    apo_remote_job_create_temporary_file temporary_file "${APO_STATE_FILE:-${TMPDIR:-/tmp}/autopioverclock-remote-job}.spec" || return 1
    if ! printf '%s\0' "$phase" "$worker_command" "$@" > "$temporary_file"; then
        rm -f -- "$temporary_file" 2>/dev/null || true
        return 1
    fi
    if hash_value=$(apo_remote_job_hash_file "$temporary_file" spec-sha256); then hash_rc=0; else hash_rc=$?; fi
    rm -f -- "$temporary_file" 2>/dev/null || true
    apo_remote_job_valid_hash "$hash_value" || return 1
    if (( hash_rc != 0 )); then apo_remote_job_child_status_log spec-hash-wrapper "$hash_rc" 1 1; fi
    printf '%s' "$hash_value"
}

apo_remote_job_command() {
    local argument command_line
    command_line=$(apo_sh_quote "$APO_REMOTE_JOB_HELPER")
    for argument in "$@"; do command_line+=" $(apo_sh_quote "$argument")"; done
    if [[ ${APO_REMOTE_JOB_EXEC_TRANSPORT:-0} == 1 ]]; then
        apo_remote_root_exec "$command_line"
    else
        apo_remote_root "$command_line"
    fi
}

# This function runs only in the long-lived follow producer. Close its inherited
# controller lock so a controller failure cannot leave the local transport
# owning the lock.
apo_remote_job_follow_command() {
    local APO_REMOTE_JOB_EXEC_TRANSPORT=1
    if [[ ${APO_LOCK_FD:-} =~ ^[0-9]+$ ]]; then exec {APO_LOCK_FD}>&-; fi
    # Replace the coprocess shell with SSH so the PID retained by the parent is
    # the actual transport. Terminating that PID cannot orphan an SSH child.
    apo_remote_job_command follow "$@"
}

apo_remote_job_follow_transport_cleanup() {
    local follow_pid=${APO_REMOTE_JOB_FOLLOW_PID:-}
    if [[ ${APO_REMOTE_JOB_FOLLOW_FD:-} =~ ^[0-9]+$ ]]; then
        { exec {APO_REMOTE_JOB_FOLLOW_FD}<&-; } 2>/dev/null || true
    fi
    APO_REMOTE_JOB_FOLLOW_FD=''
    if [[ ${APO_REMOTE_JOB_FOLLOW_INPUT_FD:-} =~ ^[0-9]+$ ]]; then
        { exec {APO_REMOTE_JOB_FOLLOW_INPUT_FD}>&-; } 2>/dev/null || true
    fi
    APO_REMOTE_JOB_FOLLOW_INPUT_FD=''
    if [[ $follow_pid =~ ^[1-9][0-9]*$ ]]; then
        kill -TERM "$follow_pid" 2>/dev/null || true
        wait "$follow_pid" 2>/dev/null || true
    fi
    APO_REMOTE_JOB_FOLLOW_PID=''
    unset APO_REMOTE_JOB_FOLLOW_COPROC APO_REMOTE_JOB_FOLLOW_COPROC_PID 2>/dev/null || true
}

# Keep the long-lived SSH producer outside the shell that parses heartbeats and
# writes controller checkpoints. A coprocess supplies the pipe, while the
# controller consumes it as an ordinary redirected function and waits for the
# exact producer PID. This avoids running checkpoint children from inside a
# lastpipe pipeline and keeps the transport status independent of PIPESTATUS.
apo_remote_job_follow_capture() {
    local follow_pid='' follow_fd='' follow_input_fd='' stream_rc=0
    APO_REMOTE_JOB_FOLLOW_TRANSPORT_RC=1
    coproc APO_REMOTE_JOB_FOLLOW_COPROC {
        apo_remote_job_follow_command "$@" 2>/dev/null
    }
    follow_pid=${APO_REMOTE_JOB_FOLLOW_COPROC_PID:-}
    follow_fd=${APO_REMOTE_JOB_FOLLOW_COPROC[0]:-}
    follow_input_fd=${APO_REMOTE_JOB_FOLLOW_COPROC[1]:-}
    APO_REMOTE_JOB_FOLLOW_PID=$follow_pid
    APO_REMOTE_JOB_FOLLOW_FD=$follow_fd
    APO_REMOTE_JOB_FOLLOW_INPUT_FD=$follow_input_fd
    # The SSH wrapper uses -n and never accepts controller input. Close the
    # unused coprocess write side immediately so reattachments cannot leak it.
    if [[ $follow_input_fd =~ ^[0-9]+$ ]]; then
        { exec {APO_REMOTE_JOB_FOLLOW_INPUT_FD}>&-; } 2>/dev/null || true
        APO_REMOTE_JOB_FOLLOW_INPUT_FD=''
    fi
    if [[ ! $follow_pid =~ ^[1-9][0-9]*$ || ! $follow_fd =~ ^[0-9]+$ ]]; then
        APO_REMOTE_JOB_FOLLOW_ERROR='The controller could not create the detached-stress follow transport.'
        apo_remote_job_follow_transport_cleanup
        return 1
    fi
    if apo_remote_job_follow_stream <&"$follow_fd"; then stream_rc=0; else stream_rc=$?; fi
    { exec {APO_REMOTE_JOB_FOLLOW_FD}<&-; } 2>/dev/null || true
    APO_REMOTE_JOB_FOLLOW_FD=''
    if (( stream_rc != 0 )); then kill -TERM "$follow_pid" 2>/dev/null || true; fi
    if wait "$follow_pid"; then APO_REMOTE_JOB_FOLLOW_TRANSPORT_RC=0; else APO_REMOTE_JOB_FOLLOW_TRANSPORT_RC=$?; fi
    APO_REMOTE_JOB_FOLLOW_PID=''
    unset APO_REMOTE_JOB_FOLLOW_COPROC APO_REMOTE_JOB_FOLLOW_COPROC_PID
    (( stream_rc == 0 ))
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
    apo_state_set REMOTE_STRESS_SEGMENT_DURATION_S ''
    apo_state_set REMOTE_STRESS_START_EPOCH ''
    apo_state_set REMOTE_STRESS_LAST_SEEN_EPOCH ''
    apo_state_set REMOTE_STRESS_CONFIRMED_ELAPSED_S ''
    apo_state_set REMOTE_STRESS_CONFIRMED_SAMPLES ''
}

apo_remote_stress_credit_clear() {
    apo_state_set REMOTE_STRESS_CREDIT_CONTEXT ''
    apo_state_set REMOTE_STRESS_CREDIT_SECONDS 0
    apo_state_set REMOTE_STRESS_CREDIT_DURATION_S ''
    apo_state_set REMOTE_STRESS_CREDIT_EVENT_ID ''
}

apo_remote_stress_credit_retain_for_context() {
    local expected_context=$1 expected_duration=$2
    local credit_context credit_seconds credit_duration credit_event
    APO_REMOTE_STRESS_RETAINED_CREDIT=0
    credit_context=$(apo_state_get REMOTE_STRESS_CREDIT_CONTEXT '')
    credit_seconds=$(apo_state_get REMOTE_STRESS_CREDIT_SECONDS 0)
    credit_duration=$(apo_state_get REMOTE_STRESS_CREDIT_DURATION_S '')
    credit_event=$(apo_state_get REMOTE_STRESS_CREDIT_EVENT_ID '')
    if [[ $credit_seconds == 0 && -z $credit_context && -z $credit_duration && -z $credit_event ]]; then
        return 0
    fi
    if [[ $expected_duration =~ ^[1-9][0-9]*$ &&
          $credit_seconds =~ ^[1-9][0-9]*$ && $credit_seconds -lt $expected_duration &&
          $credit_context == "$expected_context" && $credit_duration == "$expected_duration" &&
          $credit_event =~ ^[0-9a-f]{32}$ ]]; then
        APO_REMOTE_STRESS_RETAINED_CREDIT=$credit_seconds
        return 0
    fi
    apo_remote_stress_credit_clear
    return 1
}

apo_remote_job_emit_structured_failure() {
    local output_file=$1 failure_class=$2 failure_reason=$3 encoded_reason=''
    apo_state_encode "$failure_reason" encoded_reason || encoded_reason='VGhlIGNvbnRyb2xsZXIgY291bGQgbm90IGVuY29kZSB0aGUgZmFpbHVyZSByZWFzb24u'
    printf 'APO_RESULT_CLASS=%s\nAPO_RESULT_REASON_B64=%s\n' \
        "$failure_class" "$encoded_reason" >>"$output_file"
}

apo_remote_job_progress_tick() {
    local now=${1:-} start=${2:-} segment_duration=${3:-} elapsed
    local duration credit credit_context expected_context spec_hash phase
    [[ $now =~ ^[0-9]+$ && $start =~ ^[0-9]+$ && $segment_duration =~ ^[1-9][0-9]*$ ]] || return 0
    elapsed=$((now - start))
    (( elapsed < 0 )) && elapsed=0
    (( elapsed > segment_duration )) && elapsed=$segment_duration
    duration=$(apo_state_get REMOTE_STRESS_DURATION_S "$segment_duration")
    credit=$(apo_state_get REMOTE_STRESS_CREDIT_SECONDS 0)
    credit_context=$(apo_state_get REMOTE_STRESS_CREDIT_CONTEXT '')
    spec_hash=$(apo_state_get REMOTE_STRESS_SPEC_HASH '')
    phase=$(apo_state_get REMOTE_STRESS_PHASE '')
    expected_context="${phase}:${spec_hash}"
    if [[ ! $duration =~ ^[1-9][0-9]*$ || ! $credit =~ ^[0-9]+$ ||
          $credit_context != "$expected_context" || $credit -ge $duration ]]; then
        duration=$segment_duration
        credit=0
    fi
    elapsed=$((credit + elapsed))
    (( elapsed > duration )) && elapsed=$duration
    APO_PROGRESS_STRESS_ELAPSED=$elapsed
    APO_PROGRESS_STRESS_DURATION=$duration
    if declare -F apo_progress_render >/dev/null 2>&1; then apo_progress_render "$elapsed" "$duration"; fi
}

apo_remote_job_checkpoint_heartbeat() {
    local now=$1
    [[ $now =~ ^[1-9][0-9]*$ ]] || return 0
    if (( APO_REMOTE_JOB_LAST_CHECKPOINT_EPOCH == 0 || now - APO_REMOTE_JOB_LAST_CHECKPOINT_EPOCH >= 60 )); then
        APO_REMOTE_JOB_LAST_CHECKPOINT_EPOCH=$now
        if declare -F apo_state_save_try >/dev/null 2>&1; then
            if apo_state_save_try; then
                if (( APO_REMOTE_JOB_CHECKPOINT_FAILURES > 0 )) && declare -F apo_recovery_wait_event >/dev/null 2>&1; then
                    apo_recovery_wait_event INFO detached-stress-checkpoint-recovered \
                        "Controller state checkpointing recovered after $APO_REMOTE_JOB_CHECKPOINT_FAILURES failed attempt(s); the exact target job remained active throughout."
                fi
                APO_REMOTE_JOB_CHECKPOINT_FAILURES=0
            else
                APO_REMOTE_JOB_CHECKPOINT_FAILURES=$((APO_REMOTE_JOB_CHECKPOINT_FAILURES + 1))
                if declare -F apo_recovery_wait_event >/dev/null 2>&1; then
                    apo_recovery_wait_event WARN detached-stress-checkpoint \
                        "Controller progress checkpoint failed: ${APO_STATE_SAVE_ERROR:-unknown checkpoint error}. The exact target-owned stress job remains active; checkpointing will retry after another 60 seconds."
                elif declare -F apo_warn_plain >/dev/null 2>&1; then
                    apo_warn_plain "Controller progress checkpoint failed: ${APO_STATE_SAVE_ERROR:-unknown checkpoint error}. The exact target-owned stress job remains active."
                fi
            fi
        else
            apo_state_save
        fi
    fi
}

apo_remote_job_follow_stream() {
    local line record state now start duration source_boot size telemetry confirmed_elapsed confirmed_duration
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
                            if [[ $line =~ elapsed=([0-9]+)/([0-9]+)s ]]; then
                                confirmed_elapsed=${BASH_REMATCH[1]}
                                confirmed_duration=${BASH_REMATCH[2]}
                                if [[ $confirmed_duration == "$duration" && $confirmed_elapsed -le $duration ]]; then
                                    if ! apo_remote_job_record_confirmed_sample "$now" "$confirmed_elapsed" "$duration"; then
                                        APO_REMOTE_JOB_FOLLOW_ERROR='Saved detached-stress telemetry history is malformed.'
                                        return 1
                                    fi
                                fi
                            fi
                            apo_remote_job_progress_tick "$now" "$start" "$duration"
                        fi
                    fi
                    apo_state_set REMOTE_STRESS_START_EPOCH "$start"
                    apo_state_set REMOTE_STRESS_LAST_SEEN_EPOCH "$now"
                    apo_remote_job_checkpoint_heartbeat "$now"
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
    local status job_id token spec_hash source_boot phase duration segment_duration start_epoch last_seen confirmed_elapsed
    local confirmed_samples entry sample_epoch sample_elapsed previous_epoch=0 previous_elapsed=-1 sample_count=0
    local unknown_context unknown_count network_count network_event network_target
    local credit_context credit_seconds credit_duration credit_event expected_credit_context
    local -a confirmed_sample_entries=()
    status=$(apo_state_get REMOTE_STRESS_STATUS IDLE)
    job_id=$(apo_state_get REMOTE_STRESS_JOB_ID '')
    token=$(apo_state_get REMOTE_STRESS_TOKEN '')
    spec_hash=$(apo_state_get REMOTE_STRESS_SPEC_HASH '')
    source_boot=$(apo_state_get REMOTE_STRESS_SOURCE_BOOT_ID '')
    phase=$(apo_state_get REMOTE_STRESS_PHASE '')
    duration=$(apo_state_get REMOTE_STRESS_DURATION_S '')
    segment_duration=$(apo_state_get REMOTE_STRESS_SEGMENT_DURATION_S '')
    start_epoch=$(apo_state_get REMOTE_STRESS_START_EPOCH '')
    last_seen=$(apo_state_get REMOTE_STRESS_LAST_SEEN_EPOCH '')
    confirmed_elapsed=$(apo_state_get REMOTE_STRESS_CONFIRMED_ELAPSED_S '')
    confirmed_samples=$(apo_state_get REMOTE_STRESS_CONFIRMED_SAMPLES '')
    case $status in
        IDLE)
            if [[ -n $job_id || -n $token || -n $spec_hash || -n $source_boot || -n $phase ||
                  -n $duration || -n $segment_duration || -n $start_epoch || -n $last_seen ||
                  -n $confirmed_elapsed || -n $confirmed_samples ]]; then
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
            [[ -z $segment_duration || $segment_duration =~ ^[1-9][0-9]*$ ]] || {
                APO_AUTO_VALIDATION_REASON='Saved detached-stress segment duration is malformed.'
                return 1
            }
            [[ -z $segment_duration || $segment_duration -le $duration ]] || {
                APO_AUTO_VALIDATION_REASON='Saved detached-stress segment duration exceeds its complete gate duration.'
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
            [[ -z $confirmed_elapsed || $confirmed_elapsed =~ ^[0-9]+$ ]] || {
                APO_AUTO_VALIDATION_REASON='Saved detached-stress confirmed elapsed time is malformed.'
                return 1
            }
            [[ -z $confirmed_elapsed || -z $segment_duration || $confirmed_elapsed -le $segment_duration ]] || {
                APO_AUTO_VALIDATION_REASON='Saved detached-stress confirmed elapsed time exceeds its segment duration.'
                return 1
            }
            if [[ -n $confirmed_samples ]]; then
                [[ -n $start_epoch && -n $last_seen && -n $confirmed_elapsed && -n $segment_duration ]] || {
                    APO_AUTO_VALIDATION_REASON='Saved detached-stress telemetry history lacks its timing context.'
                    return 1
                }
                IFS=',' read -r -a confirmed_sample_entries <<<"$confirmed_samples"
                for entry in "${confirmed_sample_entries[@]}"; do
                    [[ $entry =~ ^([1-9][0-9]*):([0-9]+)$ ]] || {
                        APO_AUTO_VALIDATION_REASON='Saved detached-stress telemetry history is malformed.'
                        return 1
                    }
                    sample_epoch=${BASH_REMATCH[1]}
                    sample_elapsed=${BASH_REMATCH[2]}
                    (( sample_epoch >= start_epoch && sample_epoch <= last_seen &&
                       sample_epoch > previous_epoch && sample_elapsed > previous_elapsed &&
                       sample_elapsed <= segment_duration )) || {
                        APO_AUTO_VALIDATION_REASON='Saved detached-stress telemetry history is inconsistent.'
                        return 1
                    }
                    previous_epoch=$sample_epoch
                    previous_elapsed=$sample_elapsed
                    sample_count=$((sample_count + 1))
                done
                (( sample_count <= APO_REMOTE_JOB_CONFIRMED_SAMPLE_LIMIT )) || {
                    APO_AUTO_VALIDATION_REASON='Saved detached-stress telemetry history exceeds its bound.'
                    return 1
                }
                [[ $confirmed_elapsed == "$previous_elapsed" ]] || {
                    APO_AUTO_VALIDATION_REASON='Saved detached-stress telemetry history does not match its latest elapsed value.'
                    return 1
                }
            fi
            ;;
        *)
            APO_AUTO_VALIDATION_REASON="Saved detached-stress status is malformed: ${status:-missing}"
            return 1
            ;;
    esac
    credit_context=$(apo_state_get REMOTE_STRESS_CREDIT_CONTEXT '')
    credit_seconds=$(apo_state_get REMOTE_STRESS_CREDIT_SECONDS 0)
    credit_duration=$(apo_state_get REMOTE_STRESS_CREDIT_DURATION_S '')
    credit_event=$(apo_state_get REMOTE_STRESS_CREDIT_EVENT_ID '')
    [[ $credit_seconds =~ ^[0-9]+$ ]] || {
        APO_AUTO_VALIDATION_REASON='Saved detached-stress network credit is malformed.'
        return 1
    }
    if (( credit_seconds == 0 )); then
        [[ -z $credit_context && -z $credit_duration && -z $credit_event ]] || {
            APO_AUTO_VALIDATION_REASON='Saved detached-stress network credit metadata exists with zero credited time.'
            return 1
        }
    else
        [[ -n $credit_context && $credit_duration =~ ^[1-9][0-9]*$ &&
           $credit_event =~ ^[0-9a-f]{32}$ && $credit_seconds -lt $credit_duration ]] || {
            APO_AUTO_VALIDATION_REASON='Saved detached-stress network credit metadata is incomplete.'
            return 1
        }
        if [[ $status == RUNNING ]]; then
            expected_credit_context="${phase}:${spec_hash}"
            [[ $credit_context == "$expected_credit_context" && $credit_duration == "$duration" ]] || {
                APO_AUTO_VALIDATION_REASON='Saved detached-stress network credit does not match the active gate.'
                return 1
            }
        fi
    fi
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
    local temporary_file='' probe_pid probe_rc=1 probe_output='' now start segment_duration
    apo_remote_job_create_temporary_file temporary_file "${TMPDIR:-/tmp}/autopioverclock-boot-probe" || return 0
    start=$(apo_state_get REMOTE_STRESS_START_EPOCH '')
    segment_duration=$(apo_state_get REMOTE_STRESS_SEGMENT_DURATION_S \
        "$(apo_state_get REMOTE_STRESS_DURATION_S '')")
    APO_REMOTE_JOB_PROBE_BOOT=''
    apo_remote_boot_id_once >"$temporary_file" 2>/dev/null &
    probe_pid=$!
    while kill -0 "$probe_pid" 2>/dev/null; do
        printf -v now '%(%s)T' -1
        apo_remote_job_progress_tick "$now" "$start" "$segment_duration"
        sleep 1
    done
    if wait "$probe_pid"; then probe_rc=0; else probe_rc=$?; fi
    probe_output=$(<"$temporary_file")
    if apo_remote_job_valid_boot_id "$probe_output"; then
        APO_REMOTE_JOB_PROBE_BOOT=$probe_output
        if (( probe_rc != 0 )); then apo_remote_job_child_status_log boot-id-probe "$probe_rc" 1 1; fi
    elif (( probe_rc != 0 )); then
        apo_remote_job_child_status_log boot-id-probe "$probe_rc" 0 0
    fi
    rm -f -- "$temporary_file" 2>/dev/null || true
}

apo_remote_job_wait_for_boot() {
    local context=$1 source_boot=$2 next_notice now start segment_duration
    start=$(apo_state_get REMOTE_STRESS_START_EPOCH '')
    segment_duration=$(apo_state_get REMOTE_STRESS_SEGMENT_DURATION_S \
        "$(apo_state_get REMOTE_STRESS_DURATION_S '')")
    apo_recovery_wait_checkpoint WAITING "$context"
    if declare -F apo_progress_reconnect_begin >/dev/null 2>&1; then apo_progress_reconnect_begin "$context"; fi
    apo_recovery_wait_event WARN "$context" 'Cannot reach the target stress job. Retrying indefinitely without starting a duplicate or changing clocks.'
    next_notice=$((SECONDS + APO_PERSISTENT_SSH_NOTICE_SECONDS))
    while :; do
        apo_remote_job_probe_boot_with_ticks
        if apo_remote_job_valid_boot_id "$APO_REMOTE_JOB_PROBE_BOOT"; then
            if declare -F apo_progress_reconnect_finish >/dev/null 2>&1; then apo_progress_reconnect_finish; fi
            apo_recovery_wait_checkpoint RETURNED "$context"
            if [[ $APO_REMOTE_JOB_PROBE_BOOT == "$source_boot" ]]; then
                apo_recovery_wait_event INFO "$context" 'SSH returned on the same target boot. Reattaching to the existing stress job.'
            else
                apo_recovery_wait_event WARN "$context" "SSH returned on a new target boot $APO_REMOTE_JOB_PROBE_BOOT. Classifying the reboot before any clock decision."
            fi
            return 0
        fi
        printf -v now '%(%s)T' -1
        apo_remote_job_progress_tick "$now" "$start" "$segment_duration"
        if (( SECONDS >= next_notice )); then
            apo_recovery_wait_event INFO "$context" 'The target is still unreachable. The controller will keep retrying and the target-side deadline remains authoritative.'
            next_notice=$((SECONDS + APO_PERSISTENT_SSH_NOTICE_SECONDS))
        fi
        sleep 1
    done
}

apo_remote_job_record_network_credit() {
    local phase=$1 event_id=$2 requested_epoch=$3
    local spec_hash duration segment_duration start_epoch last_seen confirmed_elapsed confirmed_samples context
    local prior_context prior_credit prior_duration observed_seconds total_credit maximum_credit
    local entry sample_epoch sample_elapsed selected_epoch='' sample_count=0 decision='no-safe-sample'
    local previous_epoch=0 previous_elapsed=-1 history_valid=1
    local -a confirmed_sample_entries=()
    spec_hash=$(apo_state_get REMOTE_STRESS_SPEC_HASH '')
    duration=$(apo_state_get REMOTE_STRESS_DURATION_S '')
    segment_duration=$(apo_state_get REMOTE_STRESS_SEGMENT_DURATION_S "$duration")
    start_epoch=$(apo_state_get REMOTE_STRESS_START_EPOCH '')
    last_seen=$(apo_state_get REMOTE_STRESS_LAST_SEEN_EPOCH '')
    confirmed_elapsed=$(apo_state_get REMOTE_STRESS_CONFIRMED_ELAPSED_S '')
    confirmed_samples=$(apo_state_get REMOTE_STRESS_CONFIRMED_SAMPLES '')
    context="${phase}:${spec_hash}"
    prior_context=$(apo_state_get REMOTE_STRESS_CREDIT_CONTEXT '')
    prior_credit=$(apo_state_get REMOTE_STRESS_CREDIT_SECONDS 0)
    prior_duration=$(apo_state_get REMOTE_STRESS_CREDIT_DURATION_S '')
    APO_REMOTE_STRESS_CREDIT_ADDED=0
    APO_REMOTE_STRESS_CREDIT_TOTAL=0
    APO_REMOTE_STRESS_CREDIT_REMAINING=${duration:-0}
    [[ $spec_hash =~ ^[0-9a-f]{64}$ && $event_id =~ ^[0-9a-f]{32}$ &&
       $requested_epoch =~ ^[1-9][0-9]*$ && $duration =~ ^[1-9][0-9]*$ &&
       $segment_duration =~ ^[1-9][0-9]*$ && $segment_duration -le $duration ]] || {
        apo_remote_job_stage_log "$phase" network-credit 'decision=reject-invalid-metadata'
        apo_remote_stress_credit_clear
        return 0
    }
    if [[ $prior_context != "$context" || $prior_duration != "$duration" || ! $prior_credit =~ ^[0-9]+$ ]]; then
        prior_credit=0
    fi
    observed_seconds=0
    if [[ -n $confirmed_samples ]]; then
        if [[ ! $start_epoch =~ ^[1-9][0-9]*$ || ! $last_seen =~ ^[1-9][0-9]*$ ||
              ! $confirmed_elapsed =~ ^[0-9]+$ ]]; then
            history_valid=0
        else
            IFS=',' read -r -a confirmed_sample_entries <<<"$confirmed_samples"
            for entry in "${confirmed_sample_entries[@]}"; do
                if [[ ! $entry =~ ^([1-9][0-9]*):([0-9]+)$ ]]; then
                    history_valid=0
                    break
                fi
                sample_epoch=${BASH_REMATCH[1]}
                sample_elapsed=${BASH_REMATCH[2]}
                sample_count=$((sample_count + 1))
                if (( sample_epoch < start_epoch || sample_epoch > last_seen ||
                      sample_epoch <= previous_epoch || sample_elapsed <= previous_elapsed ||
                      sample_elapsed > segment_duration )); then
                    history_valid=0
                    break
                fi
                previous_epoch=$sample_epoch
                previous_elapsed=$sample_elapsed
                if (( sample_epoch <= requested_epoch )); then
                    selected_epoch=$sample_epoch
                    observed_seconds=$sample_elapsed
                    decision='history-sample'
                fi
            done
            if (( sample_count == 0 || sample_count > APO_REMOTE_JOB_CONFIRMED_SAMPLE_LIMIT )) ||
               [[ $confirmed_elapsed != "$previous_elapsed" ]]; then
                history_valid=0
            fi
        fi
        if (( history_valid == 0 )); then
            observed_seconds=0
            selected_epoch=''
            decision='reject-invalid-history'
        fi
    fi
    apo_remote_job_stage_log "$phase" network-credit \
        "decision=$decision,request_epoch=$requested_epoch,selected_epoch=${selected_epoch:-none},last_seen=${last_seen:-none},samples=$sample_count,observed_seconds=$observed_seconds"
    total_credit=$((prior_credit + observed_seconds))
    maximum_credit=$((duration - 1))
    if (( total_credit > maximum_credit )); then total_credit=$maximum_credit; fi
    if (( total_credit > 0 )); then
        apo_state_set REMOTE_STRESS_CREDIT_CONTEXT "$context"
        apo_state_set REMOTE_STRESS_CREDIT_SECONDS "$total_credit"
        apo_state_set REMOTE_STRESS_CREDIT_DURATION_S "$duration"
        apo_state_set REMOTE_STRESS_CREDIT_EVENT_ID "$event_id"
    else
        apo_remote_stress_credit_clear
    fi
    APO_REMOTE_STRESS_CREDIT_ADDED=$observed_seconds
    APO_REMOTE_STRESS_CREDIT_TOTAL=$total_credit
    APO_REMOTE_STRESS_CREDIT_REMAINING=$((duration - total_credit))
}

apo_remote_job_classify_reboot() {
    local phase=$1 output_file=$2 old_boot=$3 new_boot=$4 proof_reason replay_context replay_count credit_reason
    local duration retained_credit remaining
    if ! apo_redeploy_worker_for_boot "$new_boot" "${phase}-reboot-proof"; then
        apo_remote_job_emit_structured_failure "$output_file" RECOVERY_FAILURE \
            "The target rebooted during stress, but the worker needed for strict reboot proof could not be restored: $APO_LAST_REASON"
        return 1
    fi
    if declare -F apo_profile_prove_network_watchdog_reboot >/dev/null 2>&1 &&
       apo_profile_prove_network_watchdog_reboot "$phase" "$old_boot" "$new_boot"; then
        proof_reason=${APO_NETWORK_WATCHDOG_PROOF_REASON:-A project-owned network-watchdog reboot was strictly proved.}
        apo_remote_job_record_network_credit "$phase" "${APO_NETWORK_WATCHDOG_EVENT_ID:-}" \
            "${APO_NETWORK_WATCHDOG_REQUESTED_EPOCH:-}"
        apo_state_set NETWORK_WATCHDOG_LAST_EVENT_ID "${APO_NETWORK_WATCHDOG_EVENT_ID:-}"
        apo_state_set NETWORK_WATCHDOG_LAST_TARGET "${APO_NETWORK_WATCHDOG_TARGET:-}"
        apo_state_set NETWORK_WATCHDOG_REPLAY_COUNT "$(( $(apo_state_get NETWORK_WATCHDOG_REPLAY_COUNT 0) + 1 ))"
        apo_state_save
        if (( ${APO_REMOTE_STRESS_CREDIT_TOTAL:-0} > 0 )); then
            credit_reason="${APO_REMOTE_STRESS_CREDIT_TOTAL}s of target-reported completed stress is preserved; ${APO_REMOTE_STRESS_CREDIT_REMAINING}s remains at the same clocks."
        else
            credit_reason='No completed stress heartbeat was safely creditable, so the complete duration remains at the same clocks.'
        fi
        apo_remote_job_emit_structured_failure "$output_file" HARNESS_FAILURE "[PROVED_NETWORK_WATCHDOG] $proof_reason $credit_reason"
        return 1
    fi
    replay_context="${phase}:$(apo_state_get REMOTE_STRESS_SPEC_HASH '')"
    duration=$(apo_state_get REMOTE_STRESS_DURATION_S '')
    apo_remote_stress_credit_retain_for_context "$replay_context" "$duration" || :
    retained_credit=${APO_REMOTE_STRESS_RETAINED_CREDIT:-0}
    remaining=$duration
    if [[ $duration =~ ^[1-9][0-9]*$ && $retained_credit =~ ^[0-9]+$ && $retained_credit -lt $duration ]]; then
        remaining=$((duration - retained_credit))
    fi
    replay_count=$(apo_state_get UNATTRIBUTED_REBOOT_REPLAY_COUNT 0)
    [[ $replay_count =~ ^[0-9]+$ ]] || replay_count=0
    if [[ $(apo_state_get UNATTRIBUTED_REBOOT_REPLAY_CONTEXT '') != "$replay_context" ]]; then replay_count=0; fi
    if (( replay_count == 0 )); then
        apo_state_set UNATTRIBUTED_REBOOT_REPLAY_CONTEXT "$replay_context"
        apo_state_set UNATTRIBUTED_REBOOT_REPLAY_COUNT 1
        apo_state_save
        if (( retained_credit > 0 )); then
            credit_reason="No time from the unproved interrupted segment is credited. The earlier ${retained_credit}s proof-bound checkpoint remains valid, so ${remaining}s remains at the same clocks."
        else
            credit_reason='No time from the unproved interrupted segment is credited, so the complete duration remains at the same clocks.'
        fi
        apo_remote_job_emit_structured_failure "$output_file" HARNESS_FAILURE \
            "[UNATTRIBUTED_REBOOT_REPLAY] The target rebooted during stress, but strict network-watchdog proof was absent or incomplete. $credit_reason One conservative replay of the uncredited remainder is required before this pair can be treated as unstable."
        return 1
    fi
    # A second unattributed reboot of the identical gate is intentionally left
    # unstructured so the existing recovery classifier can promote it to an
    # instability boundary and invoke CPU/GPU isolation.
    return 1
}

apo_remote_job_fetch_complete() {
    local output_file=$1 temporary_file actual_size='' actual_hash='' size_rc=1 hash_rc=1
    temporary_file="${output_file}.remote-job.${BASHPID}"
    rm -f -- "$temporary_file"
    apo_remote_job_read_file "$temporary_file" fetch "$APO_REMOTE_WORK_DIR" \
        "$(apo_state_get REMOTE_STRESS_JOB_ID '')" "$(apo_state_get REMOTE_STRESS_TOKEN '')" \
        "$(apo_state_get REMOTE_STRESS_SPEC_HASH '')" || {
            rm -f -- "$temporary_file"
            return 1
        }
    if actual_size=$(stat -c '%s' -- "$temporary_file" 2>/dev/null); then size_rc=0; else size_rc=$?; fi
    if [[ $actual_size =~ ^[0-9]+$ ]]; then
        if (( size_rc != 0 )); then apo_remote_job_child_status_log result-stat "$size_rc" 1 1; fi
    else
        apo_remote_job_child_status_log result-stat "$size_rc" 0 0
        rm -f -- "$temporary_file"
        return 1
    fi
    if actual_hash=$(apo_remote_job_hash_file "$temporary_file" result-sha256); then hash_rc=0; else hash_rc=$?; fi
    if ! apo_remote_job_valid_hash "$actual_hash"; then
        rm -f -- "$temporary_file"
        return 1
    fi
    if (( hash_rc != 0 )); then apo_remote_job_child_status_log result-hash-wrapper "$hash_rc" 1 1; fi
    if [[ $actual_size != "$APO_REMOTE_JOB_COMPLETE_SIZE" || $actual_hash != "$APO_REMOTE_JOB_COMPLETE_HASH" ]]; then
        rm -f -- "$temporary_file"
        return 1
    fi
    : >"$output_file"
    apo_progress_capture_worker_stream "$output_file" <"$temporary_file"
    rm -f -- "$temporary_file"
    APO_REMOTE_STRESS_RC=$APO_REMOTE_JOB_COMPLETE_RC
    apo_remote_job_clear_state
    apo_remote_stress_credit_clear
    apo_state_set UNATTRIBUTED_REBOOT_REPLAY_CONTEXT ''
    apo_state_set UNATTRIBUTED_REBOOT_REPLAY_COUNT 0
    apo_state_save
}

apo_run_remote_stress_capture() {
    local phase=$1 worker_command=$2 output_file=$3
    shift 3
    local duration=${2:-} segment_duration spec_hash job_id token source_boot start_output remote_rc current_boot remote_start_epoch
    local spec_rc=1 token_rc=1 start_rc=1 follow_stream_rc=1 start_shape=empty
    local credit_context credit_seconds credit_duration expected_credit_context
    local launch_attempt=0 launch_attempts=${APO_TRANSIENT_WORKER_ATTEMPTS:-5} launch_reason
    local -a original_arguments=("$@") segment_arguments=("$@")
    [[ $worker_command == stress && $duration =~ ^[1-9][0-9]*$ ]] || return 2
    [[ $launch_attempts =~ ^[1-9][0-9]*$ ]] || launch_attempts=5
    apo_remote_job_stage_log "$phase" entered "duration_valid=1"
    if spec_hash=$(apo_remote_job_spec_hash "$phase" "$worker_command" "${original_arguments[@]}"); then spec_rc=0; else spec_rc=$?; fi
    if ! apo_remote_job_valid_hash "$spec_hash"; then
        apo_remote_job_emit_structured_failure "$output_file" HARNESS_FAILURE 'Could not calculate the detached-stress specification hash.'
        return 1
    fi
    if (( spec_rc != 0 )); then apo_remote_job_child_status_log spec-hash-call "$spec_rc" 1 1; fi
    apo_remote_job_stage_log "$phase" spec-ready "rc=$spec_rc"
    expected_credit_context="${phase}:${spec_hash}"
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
        segment_duration=$(apo_state_get REMOTE_STRESS_SEGMENT_DURATION_S "$duration")
        [[ $segment_duration =~ ^[1-9][0-9]*$ && $segment_duration -le $duration ]] || {
            apo_remote_job_emit_structured_failure "$output_file" RECOVERY_FAILURE \
                'Saved detached-stress segment duration is invalid. Automatic adoption is refused.'
            return 1
        }
        apo_remote_job_stage_log "$phase" owned-state-loaded "duration_valid=1"
    else
        credit_context=$(apo_state_get REMOTE_STRESS_CREDIT_CONTEXT '')
        credit_seconds=$(apo_state_get REMOTE_STRESS_CREDIT_SECONDS 0)
        credit_duration=$(apo_state_get REMOTE_STRESS_CREDIT_DURATION_S '')
        if [[ ! $credit_seconds =~ ^[0-9]+$ || $credit_seconds -ge $duration ||
              $credit_context != "$expected_credit_context" || $credit_duration != "$duration" ]]; then
            credit_seconds=0
            apo_remote_stress_credit_clear
        fi
        segment_duration=$((duration - credit_seconds))
        if token=$(apo_remote_job_token); then token_rc=0; else token_rc=$?; fi
        apo_remote_job_valid_hash "$token" || {
            apo_remote_job_emit_structured_failure "$output_file" HARNESS_FAILURE 'Could not create a detached-stress ownership token.'
            return 1
        }
        if (( token_rc != 0 )); then apo_remote_job_child_status_log token-call "$token_rc" 1 1; fi
        apo_remote_job_stage_log "$phase" token-ready "rc=$token_rc"
        job_id="job-${token:0:32}"
        source_boot=$(apo_remote_boot_id || true)
        apo_remote_job_valid_boot_id "$source_boot" || {
            apo_remote_job_emit_structured_failure "$output_file" HARNESS_FAILURE 'Could not read the target boot ID before detached stress launch.'
            return 1
        }
        apo_remote_job_stage_log "$phase" source-boot-ready "boot_id_valid=1"
        apo_state_set REMOTE_STRESS_STATUS RUNNING
        apo_state_set REMOTE_STRESS_JOB_ID "$job_id"
        apo_state_set REMOTE_STRESS_TOKEN "$token"
        apo_state_set REMOTE_STRESS_SPEC_HASH "$spec_hash"
        apo_state_set REMOTE_STRESS_SOURCE_BOOT_ID "$source_boot"
        apo_state_set REMOTE_STRESS_PHASE "$phase"
        apo_state_set REMOTE_STRESS_DURATION_S "$duration"
        apo_state_set REMOTE_STRESS_SEGMENT_DURATION_S "$segment_duration"
        apo_state_set REMOTE_STRESS_START_EPOCH ''
        apo_state_set REMOTE_STRESS_LAST_SEEN_EPOCH ''
        apo_state_set REMOTE_STRESS_CONFIRMED_ELAPSED_S ''
        apo_state_set REMOTE_STRESS_CONFIRMED_SAMPLES ''
        apo_state_save
        apo_remote_job_stage_log "$phase" ownership-checkpointed "duration_valid=1"
        APO_REMOTE_JOB_LAST_CHECKPOINT_EPOCH=0
        if (( credit_seconds > 0 )); then
            apo_recovery_wait_event INFO "${phase}-network-watchdog-resume" \
                "Resuming the exact same stress gate with ${credit_seconds}s safely credited and ${segment_duration}s remaining."
        fi
    fi
    segment_arguments[1]=$segment_duration
    apo_remote_job_stage_log "$phase" dispatch-ready "segment_valid=1"

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
        apo_remote_job_stage_log "$phase" launcher-call "attempt=$((launch_attempt + 1))"
        if start_output=$(apo_remote_job_command start "$APO_REMOTE_WORK_DIR" "$job_id" "$token" \
            "$spec_hash" "$source_boot" "$segment_duration" "$APO_REMOTE_WORKER" "${segment_arguments[@]}" 2>/dev/null); then
            start_rc=0
        else
            start_rc=$?
        fi
        start_shape=malformed
        if [[ -z $start_output ]]; then
            start_shape=empty
        elif [[ $start_output =~ ^APO_JOB_STARTED$'\t'(RUNNING|COMPLETE)$'\t'([0-9]+)$ ]]; then
            start_shape=started
        elif [[ $start_output =~ ^APO_JOB_ERROR$'\t'(.+)$ ]]; then
            start_shape=error
        fi
        apo_remote_job_stage_log "$phase" launcher-return "rc=$start_rc,shape=$start_shape"
        if [[ $start_output =~ ^APO_JOB_STARTED$'\t'(RUNNING|COMPLETE)$'\t'([0-9]+)$ ]]; then
            remote_start_epoch=${BASH_REMATCH[2]}
            if (( start_rc != 0 )); then apo_remote_job_child_status_log detached-start "$start_rc" 1 1; fi
            launch_attempt=0
            apo_state_set REMOTE_STRESS_START_EPOCH "$remote_start_epoch"
            apo_remote_job_checkpoint_heartbeat "$remote_start_epoch"
        elif [[ $start_output =~ ^APO_JOB_ERROR$'\t'(.+)$ ]]; then
            launch_reason=${BASH_REMATCH[1]}
            apo_remote_job_emit_structured_failure "$output_file" RECOVERY_FAILURE \
                "The target-side detached stress launcher refused the saved job: $launch_reason"
            return 1
        elif (( start_rc != 0 )); then
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
        else
            apo_remote_job_emit_structured_failure "$output_file" RECOVERY_FAILURE 'The detached stress launcher returned malformed ownership evidence.'
            return 1
        fi

        APO_REMOTE_JOB_COMPLETE=0
        APO_REMOTE_JOB_FOLLOW_ERROR=''
        apo_remote_job_stage_log "$phase" follow-call "attempt=$((launch_attempt + 1))"
        if apo_remote_job_follow_capture "$APO_REMOTE_WORK_DIR" "$job_id" "$token" "$spec_hash"; then follow_stream_rc=0; else follow_stream_rc=$?; fi
        remote_rc=$APO_REMOTE_JOB_FOLLOW_TRANSPORT_RC
        apo_remote_job_stage_log "$phase" follow-return "producer_rc=$remote_rc,parser_rc=$follow_stream_rc,complete=$APO_REMOTE_JOB_COMPLETE"
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
            apo_recovery_wait_event INFO "${phase}-network-wait" "SSH interrupted a target-job record (producer rc=$remote_rc parser rc=$follow_stream_rc). The target is on the original boot, so the controller is discarding that partial record and reattaching by saved ownership."
        else
            apo_recovery_wait_event INFO "${phase}-network-wait" "The target is reachable on the original boot after follow producer rc=$remote_rc and parser rc=$follow_stream_rc. Reattaching to the same detached stress job."
        fi
        if declare -F apo_transient_read_delay >/dev/null 2>&1; then apo_transient_read_delay; else sleep 10; fi
    done
}
