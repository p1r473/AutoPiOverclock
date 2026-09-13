#!/usr/bin/env bash
# Parse structured worker results and provide conservative fallback classification.

APO_LAST_CLASS=''
APO_LAST_REASON=''
APO_LAST_MAX_TEMP=''
APO_LAST_WORKER_LOG=''
APO_LAST_RESULT_STRUCTURED=0
APO_LAST_RESULT_COMPLETE=0
APO_LAST_PASS_RC_MISMATCH=0
APO_LAST_WORKER_CAPTURE_KIND='not-run'
APO_LAST_WORKER_PIPE_STATUS='not-run'
APO_LAST_WORKER_LASTPIPE_PREEXISTING='not-used'
APO_WORKER_CAPTURE_TRANSPORT_RC=1
APO_WORKER_CAPTURE_STREAM_RC=1
APO_WORKER_CAPTURE_PID=''
APO_WORKER_CAPTURE_FD=''
APO_WORKER_CAPTURE_INPUT_FD=''
declare -Ag APO_WORKER_DATA=()

apo_decode_b64() {
    if declare -F apo_state_decode >/dev/null 2>&1; then
        apo_state_decode "${1-}"
    elif base64 --help 2>&1 | grep -q -- '--decode'; then
        printf '%s' "${1-}" | base64 --decode 2>/dev/null
    else
        printf '%s' "${1-}" | base64 -D 2>/dev/null
    fi
}

apo_classify_output() {
    local output_file=$1 context=${2:-candidate} encoded_reason='' line
    local result_count=0 reason_count=0 reason_valid=0 class_valid=0
    APO_LAST_RESULT_STRUCTURED=0
    APO_LAST_RESULT_COMPLETE=0
    APO_LAST_CLASS=''
    APO_LAST_REASON=''
    APO_LAST_MAX_TEMP=''
    while IFS= read -r line || [[ -n $line ]]; do
        case $line in
            APO_RESULT_CLASS=*)
                APO_LAST_CLASS=${line#APO_RESULT_CLASS=}
                result_count=$((result_count + 1))
                ;;
            APO_RESULT_REASON_B64=*)
                encoded_reason=${line#APO_RESULT_REASON_B64=}
                reason_count=$((reason_count + 1))
                ;;
            APO_MAX_TEMP=*) APO_LAST_MAX_TEMP=${line#APO_MAX_TEMP=} ;;
        esac
    done < "$output_file"
    if (( result_count > 0 || reason_count > 0 )); then APO_LAST_RESULT_STRUCTURED=1; fi
    if (( reason_count > 0 )) && APO_LAST_REASON=$(apo_decode_b64 "$encoded_reason"); then reason_valid=1; fi
    case $APO_LAST_CLASS in
        PASS|PREFLIGHT_FAILURE|HARNESS_FAILURE|BOOT_FAILURE|STABILITY_FAILURE|RECOVERY_FAILURE|APPLY_FAILURE)
            class_valid=1
            ;;
    esac
    if (( result_count == 1 && reason_count == 1 && reason_valid == 1 && class_valid == 1 )); then
        APO_LAST_RESULT_COMPLETE=1
    elif (( APO_LAST_RESULT_STRUCTURED == 1 )); then
        APO_LAST_CLASS=HARNESS_FAILURE
        APO_LAST_REASON='The worker emitted an incomplete, invalid, or ambiguous structured result.'
    fi
    if [[ -z $APO_LAST_CLASS ]]; then
        if grep -Eqi 'Could not initialize|glwindow has never been initialized|Failed to become DRM master|drmModeGetResources|GBM.*(fail|error)|EGL.*(fail|error)|MESA-LOADER.*(fail|error)|failed to open.*(DRM|render|card)|GLIBC_[0-9.]+.*not found|undefined symbol|symbol lookup error|missing (binary|data)|command not found|No such file or directory.*glmark|stress-ng.*not found|error while loading shared libraries|No DRM render node bound to the V3D driver|did not prove a hardware V3D renderer|positive numeric score' "$output_file"; then
            APO_LAST_CLASS=HARNESS_FAILURE
            APO_LAST_REASON='The stress harness did not initialize correctly.'
        elif grep -Eqi 'under.?voltage|Current or new throttle/power flag|thermal thrott|Kernel panic|Internal error[[:space:]]*:|Unable to handle kernel|RCU.*(detected|self-detected).*stall|kthread starved for|kthread timer wakeup.*happen|hung[_ -]?task|task[[:space:]].*blocked for more than[[:space:]]+[0-9]+[[:space:]]+seconds|I/O error|Buffer I/O error|EXT4-fs (error|warning)|device offline|reset (SuperSpeed|high-speed|full-speed) USB|v3d.*(hang|fault|timeout)|drm.*(hang|fault|timeout)|Oops:|BUG:|Call trace|segfault' "$output_file"; then
            APO_LAST_CLASS=STABILITY_FAILURE
            APO_LAST_REASON='A power, thermal, GPU, kernel, USB, storage, or filesystem error was detected.'
        elif grep -Eqi 'tryboot|still in tryboot|no reboot|SSH unavailable|boot timeout|nullxnull\.null|sway.*(timeout|failed)|graphical.*failed|display.*failed|emulationstation.*(missing|failed|not running)|audio.*(missing|failed|not match)' "$output_file"; then
            APO_LAST_CLASS=BOOT_FAILURE
            APO_LAST_REASON="The ${context} boot or required health gate failed."
        else
            APO_LAST_CLASS=HARNESS_FAILURE
            APO_LAST_REASON='The worker failed without a structured result.'
        fi
    fi
    [[ -n $APO_LAST_REASON ]] || APO_LAST_REASON="${APO_LAST_CLASS} reported by remote worker."
}

apo_parse_data_file() {
    local source_file=$1 output_name=${2:-APO_WORKER_DATA} record key encoded decoded
    local -n output_array=$output_name
    output_array=()
    while IFS=$'\t' read -r record key encoded; do
        [[ $record == APO_DATA && $key =~ ^[A-Z][A-Z0-9_]*$ ]] || continue
        decoded=$(apo_decode_b64 "$encoded" || true)
        # The nameref resolves to an associative array; this is not arithmetic.
        # shellcheck disable=SC2004
        output_array[$key]=$decoded
    done < "$source_file"
}

: "${APO_TRANSIENT_WORKER_ATTEMPTS:=5}"

apo_worker_transport_status_log() {
    local phase=$1 worker_command=$2 remote_rc=$3 timestamp rendered
    printf -v timestamp '%(%Y-%m-%d %H:%M:%S)T' -1
    rendered="$timestamp [WARN] worker-transport-status: phase=$phase command=$worker_command remote_rc=$remote_rc capture=$APO_LAST_WORKER_CAPTURE_KIND pipeline_statuses=$APO_LAST_WORKER_PIPE_STATUS lastpipe_preexisting=$APO_LAST_WORKER_LASTPIPE_PREEXISTING controller_exit_signal=${APO_EXIT_SIGNAL:-none} shell_pid=$BASHPID shell_flags=$-"
    if declare -F apo_progress_before_output >/dev/null 2>&1; then apo_progress_before_output; fi
    printf '%s\n' "$rendered" >&2
    if [[ -n ${APO_LOG_FILE:-} ]]; then printf '%s\n' "$rendered" >> "$APO_LOG_FILE" 2>/dev/null || true; fi
    if declare -F apo_progress_after_output >/dev/null 2>&1; then apo_progress_after_output; fi
}

apo_worker_capture_command() {
    if [[ ${APO_LOCK_FD:-} =~ ^[0-9]+$ ]]; then exec {APO_LOCK_FD}>&-; fi
    apo_remote_worker "$@"
}

apo_worker_capture_transport_cleanup() {
    local worker_pid=${APO_WORKER_CAPTURE_PID:-}
    if [[ ${APO_WORKER_CAPTURE_FD:-} =~ ^[0-9]+$ ]]; then
        { exec {APO_WORKER_CAPTURE_FD}<&-; } 2>/dev/null || true
    fi
    APO_WORKER_CAPTURE_FD=''
    if [[ ${APO_WORKER_CAPTURE_INPUT_FD:-} =~ ^[0-9]+$ ]]; then
        { exec {APO_WORKER_CAPTURE_INPUT_FD}>&-; } 2>/dev/null || true
    fi
    APO_WORKER_CAPTURE_INPUT_FD=''
    if [[ $worker_pid =~ ^[1-9][0-9]*$ ]]; then
        kill -TERM "$worker_pid" 2>/dev/null || true
        wait "$worker_pid" 2>/dev/null || true
    fi
    APO_WORKER_CAPTURE_PID=''
    unset APO_WORKER_CAPTURE_COPROC APO_WORKER_CAPTURE_COPROC_PID 2>/dev/null || true
}

# Parse command output in the controller shell while the producer runs as a
# separately tracked process. This preserves live progress without lastpipe or
# PIPESTATUS and records the status from the exact producer PID.
apo_worker_capture_function_progress() {
    local output_file=$1 producer_function=$2
    shift 2
    local worker_pid='' worker_fd='' worker_input_fd='' stream_rc=0
    APO_WORKER_CAPTURE_TRANSPORT_RC=1
    APO_WORKER_CAPTURE_STREAM_RC=1
    [[ $producer_function =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    declare -F "$producer_function" >/dev/null 2>&1 || return 1
    coproc APO_WORKER_CAPTURE_COPROC {
        "$producer_function" "$@" 2>&1
    }
    worker_pid=${APO_WORKER_CAPTURE_COPROC_PID:-}
    worker_fd=${APO_WORKER_CAPTURE_COPROC[0]:-}
    worker_input_fd=${APO_WORKER_CAPTURE_COPROC[1]:-}
    APO_WORKER_CAPTURE_PID=$worker_pid
    APO_WORKER_CAPTURE_FD=$worker_fd
    APO_WORKER_CAPTURE_INPUT_FD=$worker_input_fd
    if [[ $worker_input_fd =~ ^[0-9]+$ ]]; then
        { exec {APO_WORKER_CAPTURE_INPUT_FD}>&-; } 2>/dev/null || true
        APO_WORKER_CAPTURE_INPUT_FD=''
    fi
    if [[ ! $worker_pid =~ ^[1-9][0-9]*$ || ! $worker_fd =~ ^[0-9]+$ ]]; then
        apo_worker_capture_transport_cleanup
        return 1
    fi
    if apo_progress_capture_worker_stream "$output_file" <&"$worker_fd"; then stream_rc=0; else stream_rc=$?; fi
    APO_WORKER_CAPTURE_STREAM_RC=$stream_rc
    { exec {APO_WORKER_CAPTURE_FD}<&-; } 2>/dev/null || true
    APO_WORKER_CAPTURE_FD=''
    if (( stream_rc != 0 )); then kill -TERM "$worker_pid" 2>/dev/null || true; fi
    if wait "$worker_pid"; then APO_WORKER_CAPTURE_TRANSPORT_RC=0; else APO_WORKER_CAPTURE_TRANSPORT_RC=$?; fi
    APO_WORKER_CAPTURE_PID=''
    unset APO_WORKER_CAPTURE_COPROC APO_WORKER_CAPTURE_COPROC_PID
    (( stream_rc == 0 ))
}

apo_worker_capture_progress() {
    local output_file=$1
    shift
    apo_worker_capture_function_progress "$output_file" apo_worker_capture_command "$@"
}

apo_worker_command_is_safe_to_retry() {
    case $1 in
        health|plan-candidate|verify-tryboot|verify-stock-reset|reset-throttle-history|plan-watchdog-repair|plan-network-watchdog|render-permanent|classify-kernel-log)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

apo_worker_capture_failure_is_retryable() {
    if declare -F apo_transient_worker_failure_is_retryable >/dev/null 2>&1; then
        apo_transient_worker_failure_is_retryable "$APO_LAST_CLASS" "$APO_LAST_REASON" "${APO_LAST_RESULT_COMPLETE:-0}"
        return
    fi
    [[ $APO_LAST_CLASS == HARNESS_FAILURE && $APO_LAST_REASON == 'The worker failed without a structured result.' ]]
}

apo_run_worker_capture_once() {
    local phase=$1 worker_command=$2
    shift 2
    local output_file remote_rc
    APO_LAST_PASS_RC_MISMATCH=0
    APO_LAST_WORKER_CAPTURE_KIND='not-run'
    APO_LAST_WORKER_PIPE_STATUS='not-run'
    APO_LAST_WORKER_LASTPIPE_PREEXISTING='not-used'
    output_file=$(apo_candidate_log_file "$phase")
    APO_LAST_WORKER_LOG=$output_file
    # A checkpoint retry intentionally reuses its phase-specific path. Start
    # every capture from an empty file so a prior structured PASS/FAIL trailer
    # can never be mistaken for evidence from the new SSH attempt. The
    # non-progress tee path already truncates; the live progress consumer
    # appends line-by-line and therefore needs this explicit reset.
    : > "$output_file"
    if [[ $worker_command == stress ]] && declare -F apo_run_remote_stress_capture >/dev/null 2>&1; then
        if apo_run_remote_stress_capture "$phase" "$worker_command" "$output_file" "$@"; then remote_rc=0; else remote_rc=$?; fi
        APO_LAST_WORKER_CAPTURE_KIND=detached-coprocess
        APO_LAST_WORKER_PIPE_STATUS=$remote_rc
    elif declare -F apo_progress_capture_worker_stream >/dev/null 2>&1; then
        if apo_worker_capture_progress "$output_file" "$APO_REMOTE_WORKER" "$worker_command" "$@"; then :; else :; fi
        remote_rc=$APO_WORKER_CAPTURE_TRANSPORT_RC
        APO_LAST_WORKER_CAPTURE_KIND=progress-coprocess
        APO_LAST_WORKER_PIPE_STATUS="producer=$remote_rc consumer=$APO_WORKER_CAPTURE_STREAM_RC"
    else
        if apo_remote_worker "$APO_REMOTE_WORKER" "$worker_command" "$@" > "$output_file" 2>&1; then remote_rc=0; else remote_rc=$?; fi
        tee -a "$APO_LOG_FILE" < "$output_file" || true
        APO_LAST_WORKER_CAPTURE_KIND=direct-file
        APO_LAST_WORKER_PIPE_STATUS="producer=$remote_rc consumer=not-used"
    fi
    apo_classify_output "$output_file" "$phase"
    if declare -F apo_progress_record_worker_result >/dev/null 2>&1; then
        apo_progress_record_worker_result "$output_file" "$APO_LAST_MAX_TEMP"
    fi
    if (( remote_rc == 0 )) && [[ $APO_LAST_CLASS == PASS ]]; then
        return 0
    fi
    if [[ $APO_LAST_CLASS == PASS ]]; then
        (( APO_LAST_RESULT_COMPLETE == 1 )) && APO_LAST_PASS_RC_MISMATCH=1
        apo_worker_transport_status_log "$phase" "$worker_command" "$remote_rc"
        APO_LAST_CLASS=HARNESS_FAILURE
        if (( APO_LAST_RESULT_COMPLETE == 1 )); then
            APO_LAST_REASON="Worker returned rc=$remote_rc despite one complete PASS result; capture=$APO_LAST_WORKER_CAPTURE_KIND pipeline_statuses=$APO_LAST_WORKER_PIPE_STATUS lastpipe_preexisting=$APO_LAST_WORKER_LASTPIPE_PREEXISTING controller_exit_signal=${APO_EXIT_SIGNAL:-none}."
        else
            APO_LAST_REASON="Worker returned rc=$remote_rc with an invalid or ambiguous PASS result; capture=$APO_LAST_WORKER_CAPTURE_KIND pipeline_statuses=$APO_LAST_WORKER_PIPE_STATUS lastpipe_preexisting=$APO_LAST_WORKER_LASTPIPE_PREEXISTING controller_exit_signal=${APO_EXIT_SIGNAL:-none}."
        fi
    fi
    return 1
}

apo_run_worker_capture() {
    local phase=$1 worker_command=$2 expected_boot_id current_boot_id attempt max_attempts=1 reconcile_clear_tryboot=0
    shift 2
    [[ $APO_TRANSIENT_WORKER_ATTEMPTS =~ ^[1-9][0-9]*$ ]] || APO_TRANSIENT_WORKER_ATTEMPTS=5
    if apo_worker_command_is_safe_to_retry "$worker_command"; then
        max_attempts=$APO_TRANSIENT_WORKER_ATTEMPTS
    elif [[ $worker_command == clear-tryboot ]]; then
        # Only a complete PASS trailer paired with a disagreeing transport rc
        # authorizes one same-boot idempotent postcondition recheck.
        max_attempts=2
        reconcile_clear_tryboot=1
    fi
    for (( attempt=1; attempt<=max_attempts; attempt++ )); do
        if apo_run_worker_capture_once "$phase" "$worker_command" "$@"; then
            apo_state_set LAST_FAILURE_CLASS ''
            apo_state_set LAST_FAILURE_REASON ''
            apo_state_save
            apo_event "$phase" PASS '' "$APO_LAST_REASON"
            return 0
        fi
        if (( attempt >= max_attempts )); then break; fi
        if (( reconcile_clear_tryboot == 1 )); then
            (( APO_LAST_PASS_RC_MISMATCH == 1 )) || break
        elif ! apo_worker_capture_failure_is_retryable; then
            break
        fi
        expected_boot_id=${APO_WORKER_BOOT_ID:-}
        [[ -n $expected_boot_id ]] || break
        current_boot_id=$(apo_remote_boot_id 2>/dev/null || true)
        [[ $current_boot_id == "$expected_boot_id" ]] || break
        if (( reconcile_clear_tryboot == 1 )); then
            apo_event "${phase}-transport-retry" WARN HARNESS_FAILURE 'The tryboot cleanup returned one complete PASS result but its transport status disagreed on the same boot; repeating the idempotent cleanup once to verify every postcondition.'
        else
            apo_event "${phase}-transport-retry" WARN HARNESS_FAILURE "The read-only $worker_command gate returned retryable harness evidence on the same boot; repeating it automatically (attempt $((attempt + 1))/$max_attempts)."
        fi
        if declare -F apo_transient_read_delay >/dev/null 2>&1; then apo_transient_read_delay; else sleep 10; fi
    done
    apo_state_set LAST_FAILURE_CLASS "$APO_LAST_CLASS"
    apo_state_set LAST_FAILURE_REASON "$APO_LAST_REASON"
    apo_state_save
    apo_event "$phase" ERROR "$APO_LAST_CLASS" "$APO_LAST_REASON"
    return 1
}

apo_class_is_edge_failure() { case $1 in BOOT_FAILURE|STABILITY_FAILURE) return 0 ;; *) return 1 ;; esac; }
