#!/usr/bin/env bash
# Parse structured worker results and provide conservative fallback classification.

APO_LAST_CLASS=''
APO_LAST_REASON=''
APO_LAST_MAX_TEMP=''
APO_LAST_WORKER_LOG=''
APO_LAST_RESULT_STRUCTURED=0
declare -Ag APO_WORKER_DATA=()

apo_decode_b64() {
    if base64 --help 2>&1 | grep -q -- '--decode'; then printf '%s' "$1" | base64 --decode 2>/dev/null;
    else printf '%s' "$1" | base64 -D 2>/dev/null; fi
}

apo_classify_output() {
    local output_file=$1 context=${2:-candidate} encoded_reason=''
    APO_LAST_RESULT_STRUCTURED=0
    APO_LAST_CLASS=$(sed -n 's/^APO_RESULT_CLASS=//p' "$output_file" | tail -1)
    encoded_reason=$(sed -n 's/^APO_RESULT_REASON_B64=//p' "$output_file" | tail -1)
    APO_LAST_REASON=$(apo_decode_b64 "$encoded_reason" || true)
    APO_LAST_MAX_TEMP=$(sed -n 's/^APO_MAX_TEMP=//p' "$output_file" | tail -1)
    [[ -z $APO_LAST_CLASS ]] || APO_LAST_RESULT_STRUCTURED=1
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

apo_run_worker_capture() {
    local phase=$1 worker_command=$2
    shift 2
    local output_file remote_rc
    output_file=$(apo_candidate_log_file "$phase")
    APO_LAST_WORKER_LOG=$output_file
    set +e
    if declare -F apo_progress_capture_worker_stream >/dev/null 2>&1; then
        apo_remote_worker "$APO_REMOTE_WORKER" "$worker_command" "$@" 2>&1 | apo_progress_capture_worker_stream "$output_file"
        remote_rc=${PIPESTATUS[0]}
    else
        apo_remote_worker "$APO_REMOTE_WORKER" "$worker_command" "$@" 2>&1 | tee "$output_file" | tee -a "$APO_LOG_FILE"
        remote_rc=${PIPESTATUS[0]}
    fi
    set -e
    apo_classify_output "$output_file" "$phase"
    if declare -F apo_progress_record_worker_result >/dev/null 2>&1; then
        apo_progress_record_worker_result "$output_file" "$APO_LAST_MAX_TEMP"
    fi
    apo_state_set LAST_FAILURE_CLASS "$([[ $APO_LAST_CLASS == PASS ]] && printf '' || printf '%s' "$APO_LAST_CLASS")"
    apo_state_set LAST_FAILURE_REASON "$([[ $APO_LAST_CLASS == PASS ]] && printf '' || printf '%s' "$APO_LAST_REASON")"
    apo_state_save
    if (( remote_rc == 0 )) && [[ $APO_LAST_CLASS == PASS ]]; then
        apo_event "$phase" PASS '' "$APO_LAST_REASON"
        return 0
    fi
    [[ $APO_LAST_CLASS != PASS ]] || { APO_LAST_CLASS=HARNESS_FAILURE; APO_LAST_REASON="Worker returned rc=$remote_rc despite PASS output."; }
    apo_event "$phase" ERROR "$APO_LAST_CLASS" "$APO_LAST_REASON"
    return 1
}

apo_class_is_edge_failure() { case $1 in BOOT_FAILURE|STABILITY_FAILURE) return 0 ;; *) return 1 ;; esac; }
