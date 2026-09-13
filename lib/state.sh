#!/usr/bin/env bash
# Atomic non-executable state. Values are base64 encoded and never sourced.

declare -Ag APO_STATE=()
declare -Ag APO_STATE_ENCODED_CACHE=()
declare -Ag APO_STATE_ENCODED_VALUES=()
APO_STATE_SAVE_ERROR=''
APO_STATE_SAVE_FATAL=0
APO_STATE_TEMP_SEQUENCE=0
APO_STATE_LAST_DEEP_DIAGNOSTIC_EPOCH=0

readonly APO_CURRENT_RUN_SCHEMA=10
readonly APO_CURRENT_VALIDATION_SCHEMA=8
readonly APO_STATE_IO_ATTEMPTS=3
readonly APO_STATE_TEMP_ATTEMPTS=100
readonly APO_STATE_BASE64_ALPHABET='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

apo_state_valid_key() { [[ ${1-} =~ ^[A-Z][A-Z0-9_]*$ ]]; }
apo_state_encode_value() {
    local state_value=${1-} output_name=$2 encoded_buffer='' length offset
    local byte_a byte_b byte_c index_a index_b index_c index_d
    local LC_ALL=C
    [[ $output_name =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
    local -n encoded_output=$output_name
    length=${#state_value}
    for (( offset=0; offset<length; offset+=3 )); do
        byte_b=0
        byte_c=0
        printf -v byte_a '%d' "'${state_value:offset:1}" || return 1
        byte_a=$((byte_a & 255))
        if (( offset + 1 < length )); then
            printf -v byte_b '%d' "'${state_value:offset+1:1}" || return 1
            byte_b=$((byte_b & 255))
        fi
        if (( offset + 2 < length )); then
            printf -v byte_c '%d' "'${state_value:offset+2:1}" || return 1
            byte_c=$((byte_c & 255))
        fi
        index_a=$((byte_a >> 2))
        index_b=$(((byte_a & 3) << 4 | byte_b >> 4))
        index_c=$(((byte_b & 15) << 2 | byte_c >> 6))
        index_d=$((byte_c & 63))
        encoded_buffer+=${APO_STATE_BASE64_ALPHABET:index_a:1}${APO_STATE_BASE64_ALPHABET:index_b:1}
        if (( offset + 1 < length )); then encoded_buffer+=${APO_STATE_BASE64_ALPHABET:index_c:1}; else encoded_buffer+='='; fi
        if (( offset + 2 < length )); then encoded_buffer+=${APO_STATE_BASE64_ALPHABET:index_d:1}; else encoded_buffer+='='; fi
    done
    encoded_output=$encoded_buffer
}

apo_state_base64_index() {
    local character=$1 output_name=$2 character_code index
    local LC_ALL=C
    [[ $output_name =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
    local -n index_output=$output_name
    printf -v character_code '%d' "'$character" || return 1
    case $character in
        [A-Z]) index=$((character_code - 65)) ;;
        [a-z]) index=$((character_code - 71)) ;;
        [0-9]) index=$((character_code + 4)) ;;
        +) index=62 ;;
        /) index=63 ;;
        *) return 1 ;;
    esac
    index_output=$index
}

apo_state_append_decoded_byte() {
    local byte_value=$1 output_name=$2 octal_value character
    (( byte_value > 0 && byte_value <= 255 )) || return 1
    local -n decoded_output=$output_name
    printf -v octal_value '%03o' "$byte_value" || return 1
    printf -v character '%b' "\\$octal_value" || return 1
    decoded_output+=$character
}

apo_state_decode_value() {
    local encoded_value=${1-} output_name=$2 decoded_buffer='' length offset
    local char_a char_b char_c char_d index_a index_b index_c index_d byte_value
    local LC_ALL=C
    [[ $output_name =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
    local -n decoded_output=$output_name
    length=${#encoded_value}
    (( length % 4 == 0 )) || return 1
    [[ $encoded_value != *[^A-Za-z0-9+/=]* ]] || return 1
    for (( offset=0; offset<length; offset+=4 )); do
        char_a=${encoded_value:offset:1}
        char_b=${encoded_value:offset+1:1}
        char_c=${encoded_value:offset+2:1}
        char_d=${encoded_value:offset+3:1}
        apo_state_base64_index "$char_a" index_a || return 1
        apo_state_base64_index "$char_b" index_b || return 1
        byte_value=$((index_a << 2 | index_b >> 4))
        apo_state_append_decoded_byte "$byte_value" decoded_buffer || return 1
        if [[ $char_c == = ]]; then
            if [[ $char_d != = ]] || (( offset + 4 != length )); then
                return 1
            fi
            (( (index_b & 15) == 0 )) || return 1
            continue
        fi
        apo_state_base64_index "$char_c" index_c || return 1
        byte_value=$(((index_b & 15) << 4 | index_c >> 2))
        apo_state_append_decoded_byte "$byte_value" decoded_buffer || return 1
        if [[ $char_d == = ]]; then
            (( offset + 4 == length && (index_c & 3) == 0 )) || return 1
            continue
        fi
        apo_state_base64_index "$char_d" index_d || return 1
        byte_value=$(((index_c & 3) << 6 | index_d))
        apo_state_append_decoded_byte "$byte_value" decoded_buffer || return 1
    done
    decoded_output=$decoded_buffer
}

apo_state_encode() {
    local encoded_stdout_buffer
    case $# in
        1)
            apo_state_encode_value "${1-}" encoded_stdout_buffer || return
            printf '%s' "$encoded_stdout_buffer"
            ;;
        2) apo_state_encode_value "${1-}" "$2" ;;
        *) return 2 ;;
    esac
}

apo_state_decode_policy_init() { :; }

apo_state_decode() {
    local decoded_stdout_buffer
    case $# in
        1)
            apo_state_decode_value "${1-}" decoded_stdout_buffer || return
            printf '%s' "$decoded_stdout_buffer"
            ;;
        2) apo_state_decode_value "${1-}" "$2" ;;
        *) return 2 ;;
    esac
}

apo_state_read_diagnostic_file() {
    local source_file=$1 output_name=$2 line content=''
    local -n diagnostic_output=$output_name
    [[ -f $source_file && -r $source_file ]] || { diagnostic_output=''; return 1; }
    while IFS= read -r line || [[ -n $line ]]; do
        content+="${content:+ | }$line"
        if (( ${#content} >= 512 )); then content=${content:0:512}; break; fi
    done < "$source_file"
    diagnostic_output=$content
}

# A deep probe runs only after a real checkpoint failure and no more than once
# every five minutes. It recreates the former child-process patterns with fixed
# public input, then records both observed status and independently checked
# output/postconditions. No state value is read or logged.
apo_state_checkpoint_debug_probe() {
    local now timestamp state_directory diagnostic_file='' expected_base64 base64_output='' base64_stderr=''
    local pipeline_output='' pipeline_stderr='' mktemp_output='' mktemp_stderr='' df_output='' df_stderr=''
    local base64_rc=127 base64_match=0 pipeline_rc=127 pipeline_match=0 mktemp_rc=127 mktemp_created=0
    local true_rc=127 subshell_rc=127 df_rc=127 process_state=unknown process_threads=unknown
    local sigq=unknown sigpnd=unknown shdpnd=unknown sigblk=unknown sigign=unknown sigcgt=unknown
    local cgroup_path='' pids_events='unknown' memory_events='unknown' cpu_pressure='unknown' io_pressure='unknown' memory_pressure='unknown'
    local status_key status_value event_key event_value pressure_line rendered
    printf -v now '%(%s)T' -1 || return 0
    if (( APO_STATE_LAST_DEEP_DIAGNOSTIC_EPOCH > 0 && now - APO_STATE_LAST_DEEP_DIAGNOSTIC_EPOCH < 300 )); then
        return 0
    fi
    APO_STATE_LAST_DEEP_DIAGNOSTIC_EPOCH=$now
    printf -v timestamp '%(%Y-%m-%d %H:%M:%S)T' -1
    state_directory=${APO_STATE_FILE%/*}
    [[ $state_directory != "$APO_STATE_FILE" ]] || state_directory=.
    if ! apo_state_create_temporary_file "${APO_STATE_FILE}.diagnostic" diagnostic_file; then
        rendered="$timestamp [WARN] state-checkpoint-debug: probe_setup=failed shell_pid=$BASHPID bash_version=$BASH_VERSION shell_flags=$-"
        printf '%s\n' "$rendered" >&2
        if [[ -n ${APO_LOG_FILE:-} ]]; then printf '%s\n' "$rendered" >> "$APO_LOG_FILE" 2>/dev/null || true; fi
        return 0
    fi

    printf '%s' 'APO_CHECKPOINT_DIAGNOSTIC' > "$diagnostic_file"
    apo_state_encode 'APO_CHECKPOINT_DIAGNOSTIC' expected_base64 || expected_base64='unavailable'
    if base64 "$diagnostic_file" > "${diagnostic_file}.base64" 2> "${diagnostic_file}.base64.stderr"; then base64_rc=0; else base64_rc=$?; fi
    apo_state_read_diagnostic_file "${diagnostic_file}.base64" base64_output || true
    apo_state_read_diagnostic_file "${diagnostic_file}.base64.stderr" base64_stderr || true
    [[ $base64_output == "$expected_base64" ]] && base64_match=1
    if pipeline_output=$(printf '%s' 'APO_CHECKPOINT_DIAGNOSTIC' | base64 2> "${diagnostic_file}.pipeline.stderr"); then pipeline_rc=0; else pipeline_rc=$?; fi
    apo_state_read_diagnostic_file "${diagnostic_file}.pipeline.stderr" pipeline_stderr || true
    [[ $pipeline_output == "$expected_base64" ]] && pipeline_match=1
    if mktemp_output=$(mktemp "${diagnostic_file}.mktemp.XXXXXX" 2> "${diagnostic_file}.mktemp.stderr"); then mktemp_rc=0; else mktemp_rc=$?; fi
    apo_state_read_diagnostic_file "${diagnostic_file}.mktemp.stderr" mktemp_stderr || true
    if [[ $mktemp_output == "${diagnostic_file}.mktemp."* && -f $mktemp_output && ! -L $mktemp_output ]]; then mktemp_created=1; fi
    if /usr/bin/true; then true_rc=0; else true_rc=$?; fi
    if ( : ); then subshell_rc=0; else subshell_rc=$?; fi
    if command -v df >/dev/null 2>&1; then
        if df -Pk "$state_directory" > "${diagnostic_file}.df" 2> "${diagnostic_file}.df.stderr"; then df_rc=0; else df_rc=$?; fi
        apo_state_read_diagnostic_file "${diagnostic_file}.df" df_output || true
        apo_state_read_diagnostic_file "${diagnostic_file}.df.stderr" df_stderr || true
    fi
    if [[ -r /proc/$BASHPID/status ]]; then
        while read -r status_key status_value _; do
            case $status_key in
                State:) process_state=$status_value ;;
                Threads:) process_threads=$status_value ;;
                SigQ:) sigq=$status_value ;;
                SigPnd:) sigpnd=$status_value ;;
                ShdPnd:) shdpnd=$status_value ;;
                SigBlk:) sigblk=$status_value ;;
                SigIgn:) sigign=$status_value ;;
                SigCgt:) sigcgt=$status_value ;;
            esac
        done < "/proc/$BASHPID/status"
    fi
    if [[ -r /proc/$BASHPID/cgroup ]]; then
        while IFS=: read -r _ _ cgroup_path; do [[ -n $cgroup_path ]] && break; done < "/proc/$BASHPID/cgroup"
    fi
    if [[ -n $cgroup_path && -r /sys/fs/cgroup$cgroup_path/pids.events ]]; then
        pids_events=''
        while read -r event_key event_value; do pids_events+="${pids_events:+,}$event_key=$event_value"; done < "/sys/fs/cgroup$cgroup_path/pids.events"
    fi
    if [[ -n $cgroup_path && -r /sys/fs/cgroup$cgroup_path/memory.events ]]; then
        memory_events=''
        while read -r event_key event_value; do memory_events+="${memory_events:+,}$event_key=$event_value"; done < "/sys/fs/cgroup$cgroup_path/memory.events"
    fi
    if [[ -r /proc/pressure/cpu ]] && IFS= read -r pressure_line < /proc/pressure/cpu; then cpu_pressure=${pressure_line:0:160}; fi
    if [[ -r /proc/pressure/io ]] && IFS= read -r pressure_line < /proc/pressure/io; then io_pressure=${pressure_line:0:160}; fi
    if [[ -r /proc/pressure/memory ]] && IFS= read -r pressure_line < /proc/pressure/memory; then memory_pressure=${pressure_line:0:160}; fi
    printf -v base64_stderr '%q' "$base64_stderr"
    printf -v pipeline_stderr '%q' "$pipeline_stderr"
    printf -v mktemp_stderr '%q' "$mktemp_stderr"
    printf -v df_output '%q' "${df_output:0:512}"
    printf -v df_stderr '%q' "$df_stderr"
    printf -v pids_events '%q' "$pids_events"
    printf -v memory_events '%q' "$memory_events"
    printf -v cpu_pressure '%q' "$cpu_pressure"
    printf -v io_pressure '%q' "$io_pressure"
    printf -v memory_pressure '%q' "$memory_pressure"
    rendered="$timestamp [WARN] state-checkpoint-debug: shell_pid=$BASHPID bash_version=$BASH_VERSION shell_flags=$- process_state=$process_state threads=$process_threads sigq=$sigq sigpnd=$sigpnd shdpnd=$shdpnd sigblk=$sigblk sigign=$sigign sigcgt=$sigcgt external_true_rc=$true_rc subshell_rc=$subshell_rc base64_rc=$base64_rc base64_output_match=$base64_match base64_stderr=$base64_stderr pipeline_rc=$pipeline_rc pipeline_output_match=$pipeline_match pipeline_stderr=$pipeline_stderr mktemp_rc=$mktemp_rc mktemp_created=$mktemp_created mktemp_stderr=$mktemp_stderr df_rc=$df_rc df_output=$df_output df_stderr=$df_stderr pids_events=$pids_events memory_events=$memory_events cpu_pressure=$cpu_pressure io_pressure=$io_pressure memory_pressure=$memory_pressure"
    if declare -F apo_progress_before_output >/dev/null 2>&1; then apo_progress_before_output; fi
    printf '%s\n' "$rendered" >&2
    if [[ -n ${APO_LOG_FILE:-} ]]; then printf '%s\n' "$rendered" >> "$APO_LOG_FILE" 2>/dev/null || true; fi
    if declare -F apo_progress_after_output >/dev/null 2>&1; then apo_progress_after_output; fi
    if (( mktemp_created == 1 )); then rm -f -- "$mktemp_output" 2>/dev/null || true; fi
    rm -f -- "$diagnostic_file" "${diagnostic_file}.base64" "${diagnostic_file}.base64.stderr" \
        "${diagnostic_file}.pipeline.stderr" "${diagnostic_file}.mktemp.stderr" \
        "${diagnostic_file}.df" "${diagnostic_file}.df.stderr" 2>/dev/null || true
    return 0
}

apo_state_checkpoint_log_failure() {
    local stage=$1 attempt=$2 maximum_attempts=$3 command_rc=$4 detail=${5:-none}
    local severity=WARN timestamp detail_quoted
    local open_fds=unknown nofile_limit=unknown nproc_limit=unknown system_tasks=unknown
    local mem_available_kb=unknown file_handles_allocated=unknown cgroup_path='' cgroup_pids=unknown cgroup_pids_max=unknown
    local rendered limit_line mem_key mem_value
    local -a fd_paths=()
    (( attempt == maximum_attempts )) && severity=ERROR
    printf -v timestamp '%(%Y-%m-%d %H:%M:%S)T' -1
    printf -v detail_quoted '%q' "${detail:0:512}"
    fd_paths=(/proc/$BASHPID/fd/*)
    if [[ -e ${fd_paths[0]} ]]; then open_fds=${#fd_paths[@]}; fi
    if [[ -r /proc/$BASHPID/limits ]]; then
        while IFS= read -r limit_line; do
            if [[ $limit_line =~ ^Max[[:space:]]open[[:space:]]files[[:space:]]+([^[:space:]]+) ]]; then
                nofile_limit=${BASH_REMATCH[1]}
            elif [[ $limit_line =~ ^Max[[:space:]]processes[[:space:]]+([^[:space:]]+) ]]; then
                nproc_limit=${BASH_REMATCH[1]}
            fi
        done < "/proc/$BASHPID/limits"
    fi
    if [[ -r /proc/loadavg ]] && read -r _ _ _ system_tasks _ < /proc/loadavg; then :; fi
    if [[ -r /proc/meminfo ]]; then
        while read -r mem_key mem_value _; do
            if [[ $mem_key == MemAvailable: ]]; then mem_available_kb=$mem_value; break; fi
        done < /proc/meminfo
    fi
    if [[ -r /proc/sys/fs/file-nr ]]; then read -r file_handles_allocated _ < /proc/sys/fs/file-nr || file_handles_allocated=unknown; fi
    if [[ -r /proc/$BASHPID/cgroup ]]; then
        while IFS=: read -r _ _ cgroup_path; do
            [[ -n $cgroup_path ]] && break
        done < "/proc/$BASHPID/cgroup"
    fi
    if [[ -n $cgroup_path && -r /sys/fs/cgroup$cgroup_path/pids.current ]]; then
        read -r cgroup_pids < "/sys/fs/cgroup$cgroup_path/pids.current" || cgroup_pids=unknown
    fi
    if [[ -n $cgroup_path && -r /sys/fs/cgroup$cgroup_path/pids.max ]]; then
        read -r cgroup_pids_max < "/sys/fs/cgroup$cgroup_path/pids.max" || cgroup_pids_max=unknown
    fi
    rendered="$timestamp [$severity] state-checkpoint-io: stage=$stage attempt=$attempt/$maximum_attempts rc=$command_rc detail=$detail_quoted pid=$BASHPID open_fds=$open_fds nofile_limit=$nofile_limit nproc_limit=$nproc_limit system_tasks=$system_tasks cgroup_pids=$cgroup_pids cgroup_pids_max=$cgroup_pids_max mem_available_kb=$mem_available_kb file_handles_allocated=$file_handles_allocated"
    if declare -F apo_progress_before_output >/dev/null 2>&1; then apo_progress_before_output; fi
    printf '%s\n' "$rendered" >&2
    if [[ -n ${APO_LOG_FILE:-} ]]; then printf '%s\n' "$rendered" >> "$APO_LOG_FILE" 2>/dev/null || true; fi
    if declare -F apo_progress_after_output >/dev/null 2>&1; then apo_progress_after_output; fi
    apo_state_checkpoint_debug_probe
    return 0
}

# Selection paths often need only a small metadata subset from many retained
# runs. Decode only those named fields; a candidate that survives this screen
# is still loaded and validated in full before it can authorize any action.
apo_state_load_fields() {
    local source_file=$1 output_name=$2 line state_key encoded_value decoded_value requested_key
    local -n output_fields=$output_name
    local -A requested_fields=() seen_fields=()
    shift 2
    [[ -f $source_file && -r $source_file ]] || return 1
    (( $# > 0 )) || return 1
    for requested_key in "$@"; do
        apo_state_valid_key "$requested_key" || return 1
        requested_fields[$requested_key]=1
    done
    output_fields=()
    while IFS= read -r line || [[ -n $line ]]; do
        [[ -n $line ]] || continue
        [[ $line == *$'\t'* ]] || return 1
        state_key=${line%%$'\t'*}
        encoded_value=${line#*$'\t'}
        apo_state_valid_key "$state_key" || return 1
        [[ -v requested_fields[$state_key] ]] || continue
        [[ $encoded_value != *$'\t'* && ! -v seen_fields[$state_key] ]] || return 1
        apo_state_decode "$encoded_value" decoded_value || return 1
        seen_fields[$state_key]=1
        # The nameref resolves to an associative array; this is not arithmetic.
        # shellcheck disable=SC2004
        output_fields[$state_key]=$decoded_value
    done < "$source_file"
}

apo_state_set() {
    local state_key=$1 state_value=${2-}
    apo_state_valid_key "$state_key" || apo_die "Invalid state key: $state_key" "$APO_EXIT_INTERNAL"
    APO_STATE[$state_key]=$state_value
}

apo_state_get() {
    local state_key=$1 fallback=${2-}
    if [[ -v APO_STATE[$state_key] ]]; then printf '%s' "${APO_STATE[$state_key]}"; else printf '%s' "$fallback"; fi
}

apo_state_sorted_keys() {
    local output_name=$1 index scan key
    local LC_ALL=C
    local -n sorted_keys=$output_name
    sorted_keys=("${!APO_STATE[@]}")
    for (( index=1; index<${#sorted_keys[@]}; index++ )); do
        key=${sorted_keys[index]}
        scan=$((index - 1))
        while (( scan >= 0 )) && [[ ${sorted_keys[scan]} > "$key" ]]; do
            sorted_keys[scan + 1]=${sorted_keys[scan]}
            scan=$((scan - 1))
        done
        sorted_keys[scan + 1]=$key
    done
}

apo_state_create_temporary_file() {
    local destination=$1 output_name=$2 attempt candidate created=0 noclobber_was_set=0
    local -n temporary_output=$output_name
    # The controller starts under umask 077; repeat it here so a library caller
    # cannot create a state checkpoint with broader permissions.
    umask 077
    [[ $- == *C* ]] && noclobber_was_set=1 || set -C
    for (( attempt=1; attempt<=APO_STATE_TEMP_ATTEMPTS; attempt++ )); do
        APO_STATE_TEMP_SEQUENCE=$((APO_STATE_TEMP_SEQUENCE + 1))
        candidate="${destination}.tmp.${BASHPID}.${APO_STATE_TEMP_SEQUENCE}"
        if { : > "$candidate"; } 2>/dev/null; then
            temporary_output=$candidate
            created=1
            break
        fi
    done
    (( noclobber_was_set == 1 )) || set +C
    (( created == 1 ))
}

apo_state_discard_temporary_file() {
    local temporary_file=${1-}
    [[ -n $temporary_file && ( -e $temporary_file || -L $temporary_file ) ]] || return 0
    rm -f -- "$temporary_file" 2>/dev/null || true
}

apo_state_sync_path() {
    local sync_path=$1 stage=$2 attempt command_rc=0
    for (( attempt=1; attempt<=APO_STATE_IO_ATTEMPTS; attempt++ )); do
        if sync "$sync_path"; then return 0; else command_rc=$?; fi
        apo_state_checkpoint_log_failure "$stage" "$attempt" "$APO_STATE_IO_ATTEMPTS" "$command_rc" "path=$sync_path"
    done
    return 1
}

apo_state_checkpoint_matches() {
    local source_file=$1 encoded_name=$2 keys_name=$3 line state_key encoded_value index=0
    local -n expected_encoded=$encoded_name expected_keys=$keys_name
    [[ -f $source_file && -r $source_file ]] || return 1
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line == *$'\t'* ]] || return 1
        state_key=${line%%$'\t'*}
        encoded_value=${line#*$'\t'}
        [[ $encoded_value != *$'\t'* && index -lt ${#expected_keys[@]} ]] || return 1
        [[ $state_key == "${expected_keys[index]}" && -v expected_encoded[$state_key] ]] || return 1
        [[ $encoded_value == "${expected_encoded[$state_key]}" ]] || return 1
        index=$((index + 1))
    done < "$source_file"
    (( index == ${#expected_keys[@]} ))
}

apo_state_commit_temporary_file() {
    local temporary_file=$1 destination=$2 encoded_name=$3 keys_name=$4 attempt command_rc=0
    for (( attempt=1; attempt<=APO_STATE_IO_ATTEMPTS; attempt++ )); do
        if mv -f -- "$temporary_file" "$destination"; then
            if apo_state_checkpoint_matches "$destination" "$encoded_name" "$keys_name"; then return 0; fi
            apo_state_checkpoint_log_failure commit-verify "$attempt" "$APO_STATE_IO_ATTEMPTS" 1 'destination content did not match the complete checkpoint'
            return 1
        else
            command_rc=$?
        fi
        apo_state_checkpoint_log_failure commit-rename "$attempt" "$APO_STATE_IO_ATTEMPTS" "$command_rc" "temporary=$temporary_file destination=$destination"
        if apo_state_checkpoint_matches "$destination" "$encoded_name" "$keys_name"; then
            apo_state_discard_temporary_file "$temporary_file"
            return 0
        fi
        [[ -e $temporary_file && ! -L $temporary_file ]] || return 1
    done
    return 1
}

apo_state_save_try() {
    local temporary_file='' state_directory state_key encoded_value updated_at write_rc=0
    local -a state_keys=()
    local -A checkpoint_encoded=() checkpoint_values=()
    APO_STATE_SAVE_ERROR=''
    [[ -n ${APO_STATE_FILE:-} ]] || { APO_STATE_SAVE_ERROR='Internal error: state filename is unset.'; return 1; }
    if declare -F apo_progress_checkpoint_state >/dev/null 2>&1; then apo_progress_checkpoint_state; fi
    apo_now_iso updated_at || { APO_STATE_SAVE_ERROR='Could not timestamp the state checkpoint.'; return 1; }
    apo_state_set UPDATED_AT "$updated_at"
    if ! apo_state_create_temporary_file "$APO_STATE_FILE" temporary_file; then
        APO_STATE_SAVE_ERROR='Could not create a temporary state checkpoint.'
        apo_state_checkpoint_log_failure temp-create 1 1 1 'all collision-safe Bash creation attempts failed'
        return 1
    fi
    apo_state_sorted_keys state_keys
    if ! {
        for state_key in "${state_keys[@]}"; do
        if [[ -v APO_STATE_ENCODED_CACHE[$state_key] && -v APO_STATE_ENCODED_VALUES[$state_key] &&
              ${APO_STATE_ENCODED_VALUES[$state_key]} == "${APO_STATE[$state_key]}" ]]; then
            encoded_value=${APO_STATE_ENCODED_CACHE[$state_key]}
        else
            if ! apo_state_encode "${APO_STATE[$state_key]}" encoded_value; then write_rc=1; break; fi
        fi
        checkpoint_encoded[$state_key]=$encoded_value
        checkpoint_values[$state_key]=${APO_STATE[$state_key]}
            if ! printf '%s\t%s\n' "$state_key" "$encoded_value"; then write_rc=1; break; fi
        done
        (( write_rc == 0 ))
    } > "$temporary_file"; then
        apo_state_discard_temporary_file "$temporary_file"
        APO_STATE_SAVE_ERROR="Could not encode or write state key ${state_key:-unknown}."
        apo_state_checkpoint_log_failure encode-write 1 1 1 "key=${state_key:-unknown}"
        return 1
    fi
    if ! apo_state_sync_path "$temporary_file" temp-sync; then
        apo_state_discard_temporary_file "$temporary_file"
        APO_STATE_SAVE_ERROR="Could not durably flush the temporary state checkpoint after $APO_STATE_IO_ATTEMPTS attempts."
        return 1
    fi
    if ! apo_state_commit_temporary_file "$temporary_file" "$APO_STATE_FILE" checkpoint_encoded state_keys; then
        apo_state_discard_temporary_file "$temporary_file"
        APO_STATE_SAVE_ERROR="Could not atomically commit the state checkpoint after $APO_STATE_IO_ATTEMPTS attempts."
        return 1
    fi
    if ! apo_state_sync_path "$APO_STATE_FILE" committed-sync; then
        APO_STATE_SAVE_ERROR="Could not durably flush the committed state checkpoint after $APO_STATE_IO_ATTEMPTS attempts."
        return 1
    fi
    state_directory=${APO_STATE_FILE%/*}
    [[ $state_directory != "$APO_STATE_FILE" ]] || state_directory=.
    if ! apo_state_sync_path "$state_directory" directory-sync; then
        APO_STATE_SAVE_ERROR="Could not durably flush the state directory checkpoint after $APO_STATE_IO_ATTEMPTS attempts."
        return 1
    fi
    APO_STATE_ENCODED_CACHE=()
    APO_STATE_ENCODED_VALUES=()
    for state_key in "${!checkpoint_encoded[@]}"; do
        APO_STATE_ENCODED_CACHE[$state_key]=${checkpoint_encoded[$state_key]}
        APO_STATE_ENCODED_VALUES[$state_key]=${checkpoint_values[$state_key]}
    done
    return 0
}

apo_state_save() {
    APO_STATE_SAVE_FATAL=0
    if apo_state_save_try; then return 0; fi
    APO_STATE_SAVE_FATAL=1
    apo_die "${APO_STATE_SAVE_ERROR:-Could not save the state checkpoint.}" "$APO_EXIT_INTERNAL"
}

apo_state_load() {
    local source_file=$1 source_label=$1 line state_key encoded_value decoded_value state_fd
    local -A seen_keys=()
    if apo_is_redacted_observer; then source_label='selected state'; fi
    [[ -f $source_file && -r $source_file ]] || apo_die "State file not found or unreadable: $source_label" "$APO_EXIT_USAGE"
    if ! { exec {state_fd}<"$source_file"; } 2>/dev/null; then
        apo_die "State file not found or unreadable: $source_label" "$APO_EXIT_USAGE"
    fi
    APO_STATE=()
    APO_STATE_ENCODED_CACHE=()
    APO_STATE_ENCODED_VALUES=()
    while IFS= read -r line || [[ -n $line ]]; do
        [[ -n $line ]] || continue
        if [[ $line != *$'\t'* ]]; then
            if apo_is_redacted_observer; then apo_die 'Invalid state record in selected state.' "$APO_EXIT_INTERNAL"; fi
            apo_die "Invalid state record in $source_file." "$APO_EXIT_INTERNAL"
        fi
        state_key=${line%%$'\t'*}
        encoded_value=${line#*$'\t'}
        if ! apo_state_valid_key "$state_key"; then
            if apo_is_redacted_observer; then
                apo_die 'Invalid state key in selected state.' "$APO_EXIT_INTERNAL"
            fi
            apo_die "Invalid state key in $source_file: $state_key" "$APO_EXIT_INTERNAL"
        fi
        if [[ $encoded_value == *$'\t'* || -v seen_keys[$state_key] ]]; then
            apo_die "Duplicate or malformed state record for $state_key in $source_label" "$APO_EXIT_INTERNAL"
        fi
        apo_state_decode "$encoded_value" decoded_value || apo_die "Corrupt state value for $state_key in $source_label" "$APO_EXIT_INTERNAL"
        seen_keys[$state_key]=1
        APO_STATE[$state_key]=$decoded_value
        # A successfully decoded token is safe to reuse while its value stays
        # unchanged. State is parsed as data and is never sourced.
        APO_STATE_ENCODED_CACHE[$state_key]=$encoded_value
        APO_STATE_ENCODED_VALUES[$state_key]=$decoded_value
    done <&"$state_fd"
    exec {state_fd}<&-
    [[ $(apo_state_get FORMAT_VERSION '') == 1 ]] || apo_die "Unsupported or missing state format in $source_label" "$APO_EXIT_INTERNAL"
    APO_STATE_FILE=$source_file
}

apo_state_initialize() {
    APO_STATE=()
    APO_STATE_ENCODED_CACHE=()
    APO_STATE_ENCODED_VALUES=()
    apo_state_set FORMAT_VERSION 1
    apo_state_set RUN_SCHEMA "$APO_CURRENT_RUN_SCHEMA"
    apo_state_set APP_VERSION "$APO_VERSION"
    apo_state_set RUN_ID "$APO_RUN_ID"
    apo_state_set CREATED_AT "$(apo_now_iso)"
    apo_state_set RAW_TARGET "$APO_RAW_TARGET"
    apo_state_set REMOTE_TARGET "$APO_REMOTE_TARGET"
    apo_state_set TARGET_HOST "$APO_TARGET_HOST"
    apo_state_set TARGET_SLUG "$APO_TARGET_SLUG"
    apo_state_set OUTPUT_DIR "$APO_OUTPUT_DIR"
    apo_state_set ORIGIN_COMMAND "${APO_ORIGIN_COMMAND:-${APO_COMMAND:-run}}"
    apo_state_set READ_ONLY_RUN "${APO_DRY_RUN:-0}"
    apo_state_set STATUS PREPARING
    apo_state_set PHASE PREPARE
    apo_state_set SUBPHASE INITIAL
    apo_state_set PROFILE ''
    apo_state_set MODE_REQUESTED "$APO_MODE_REQUESTED"
    apo_state_set MODE_EFFECTIVE ''
    apo_state_set CURRENT_CPU ''
    apo_state_set CURRENT_GPU ''
    apo_state_set AUTO_BASELINE_CPU ''
    apo_state_set AUTO_BASELINE_GPU ''
    apo_state_set AUTO_BASELINE_VOLTAGE ''
    apo_state_set AUTO_BASELINE_PROVENANCE ''
    apo_state_set AUTO_BASELINE_EVIDENCE ''
    apo_state_set SOURCE_APPLIED_RUN_ID "${APO_SOURCE_APPLIED_RUN_ID:-}"
    apo_state_set SOURCE_APPLIED_PERMANENT_HASH "${APO_SOURCE_APPLIED_PERMANENT_HASH:-}"
    apo_state_set SOURCE_APPLIED_LIVE_HASH "${APO_SOURCE_APPLIED_LIVE_HASH:-}"
    apo_state_set SOURCE_APPLIED_HASH_RELATION "${APO_SOURCE_APPLIED_HASH_RELATION:-}"
    apo_state_set SOURCE_APPLIED_HASH_EVIDENCE "${APO_SOURCE_APPLIED_HASH_EVIDENCE:-}"
    apo_state_set SOURCE_APPLIED_CPU "${APO_SOURCE_APPLIED_CPU:-}"
    apo_state_set SOURCE_APPLIED_GPU "${APO_SOURCE_APPLIED_GPU:-}"
    apo_state_set SOURCE_APPLIED_VOLTAGE "${APO_SOURCE_APPLIED_VOLTAGE:-}"
    apo_state_set SOURCE_APPLIED_PROFILE "${APO_SOURCE_APPLIED_PROFILE:-}"
    apo_state_set SOURCE_APPLIED_BOOT_CONFIG "${APO_SOURCE_APPLIED_BOOT_CONFIG:-}"
    apo_state_set SOURCE_APPLIED_TRYBOOT_CONFIG "${APO_SOURCE_APPLIED_TRYBOOT_CONFIG:-}"
    apo_state_set SOURCE_APPLIED_GPU_KEY "${APO_SOURCE_APPLIED_GPU_KEY:-}"
    apo_state_set SOURCE_AUTO_BASELINE_CPU "${APO_SOURCE_AUTO_BASELINE_CPU:-}"
    apo_state_set SOURCE_AUTO_BASELINE_GPU "${APO_SOURCE_AUTO_BASELINE_GPU:-}"
    apo_state_set SOURCE_AUTO_BASELINE_VOLTAGE "${APO_SOURCE_AUTO_BASELINE_VOLTAGE:-}"
    apo_state_set SOURCE_AUTO_BASELINE_PROVENANCE "${APO_SOURCE_AUTO_BASELINE_PROVENANCE:-}"
    apo_state_set SOURCE_AUTO_BASELINE_EVIDENCE "${APO_SOURCE_AUTO_BASELINE_EVIDENCE:-}"
    apo_state_set CPU_INDEX 0
    apo_state_set GPU_INDEX 0
    apo_state_set CPU_FAILURE_BOUNDARY ''
    apo_state_set GPU_FAILURE_BOUNDARY ''
    apo_state_set CPU_REFINE_CANDIDATES ''
    apo_state_set GPU_REFINE_CANDIDATES ''
    apo_state_set CPU_REFINE_INDEX 0
    apo_state_set GPU_REFINE_INDEX 0
    apo_state_set CPU_REFINE_COMPLETE 0
    apo_state_set GPU_REFINE_COMPLETE 0
    apo_state_set CPU_REVERSE_PASS ''
    apo_state_set GPU_REVERSE_PASS ''
    apo_state_set CPU_REVERSE_FAILURES ''
    apo_state_set GPU_REVERSE_FAILURES ''
    apo_state_set CPU_GUARD_TARGET ''
    apo_state_set GPU_GUARD_TARGET ''
    apo_state_set CPU_GUARD_VERIFIED 0
    apo_state_set GPU_GUARD_VERIFIED 0
    apo_state_set CPU_QUALIFICATION_STATUS NOT_STARTED
    apo_state_set CPU_QUALIFICATION_TARGET ''
    apo_state_set CPU_QUALIFIED_CLOCK ''
    apo_state_set CPU_QUALIFICATION_HISTORY ''
    apo_state_set CPU_QUALIFICATION_LAST_CLASS ''
    apo_state_set CPU_QUALIFICATION_LAST_REASON ''
    apo_state_set GPU_QUALIFICATION_STATUS NOT_STARTED
    apo_state_set GPU_QUALIFICATION_CPU ''
    apo_state_set GPU_QUALIFICATION_TARGET ''
    apo_state_set GPU_QUALIFIED_CPU ''
    apo_state_set GPU_QUALIFIED_CLOCK ''
    apo_state_set FLOOR_CPU ''
    apo_state_set FLOOR_GPU ''
    apo_state_set FLOOR_DURATION_S ''
    apo_state_set FLOOR_VALIDATION_SCHEMA ''
    apo_state_set FLOOR_VALIDATED 0
    apo_state_set POST_FLOOR_EDGE 0
    apo_state_set SOURCE_FLOOR_RUN_ID ''
    apo_state_set SOURCE_FLOOR_PERMANENT_HASH ''
    apo_state_set POST_FLOOR_FINAL 0
    apo_state_set POST_FLOOR_FINAL_STAGE ''
    apo_state_set SOURCE_FINAL_RUN_ID ''
    apo_state_set SOURCE_FINAL_PERMANENT_HASH ''
    apo_state_set SOURCE_FINAL_VALIDATION_DURATION_S ''
    apo_state_set SOURCE_FINAL_APPLY_BACKUP ''
    apo_state_set EDGE_CPU_TARGET ''
    apo_state_set EDGE_CPU_STATUS NOT_REQUESTED
    apo_state_set EDGE_CPU_FAILURE_CLASS ''
    apo_state_set EDGE_CPU_FAILURE_REASON ''
    apo_state_set PASSED_CPUS ''
    apo_state_set PASSED_GPUS ''
    apo_state_set RECOMMENDED_CPU ''
    apo_state_set RECOMMENDED_GPU ''
    apo_state_set FINAL_CPU ''
    apo_state_set FINAL_GPU ''
    apo_state_set VALIDATION_SCHEMA ''
    apo_state_set VALIDATION_DURATION_S ''
    apo_state_set VALIDATED 0
    apo_state_set CANDIDATE_LABEL ''
    apo_state_set CANDIDATE_CPU ''
    apo_state_set CANDIDATE_GPU ''
    apo_state_set CANDIDATE_STAGE ''
    apo_state_set FINAL_TARGET_CPU ''
    apo_state_set FINAL_TARGET_GPU ''
    apo_state_set FINAL_STAGE ''
    apo_state_set FINAL_BACKOFF_COUNT 0
    apo_state_set FINAL_BACKOFF_CPU ''
    apo_state_set FINAL_BACKOFF_GPU ''
    apo_state_set FINAL_BACKOFF_HISTORY ''
    apo_state_set FINAL_BACKOFF_LAST_STAGE ''
    apo_state_set FINAL_BACKOFF_LAST_CLASS ''
    apo_state_set FINAL_BACKOFF_LAST_REASON ''
    apo_state_set FINAL_BACKOFF_ANCHOR_CPU ''
    apo_state_set FINAL_BACKOFF_ANCHOR_GPU ''
    apo_state_set FINAL_BACKOFF_TRIAL ''
    apo_state_set FINAL_BACKOFF_ANCHOR_CPU_QUALIFIED_CLOCK ''
    # Retained-history scheduling is intentionally separate from the current
    # run's FINAL_BACKOFF_HISTORY.  The latter may describe only failures that
    # this run actually observed and replayed.
    apo_state_set HISTORY_ISOLATION_STAGE NONE
    apo_state_set HISTORY_CPU_FAILURE_BOUNDARY ''
    apo_state_set HISTORY_GPU_FAILURE_BOUNDARY ''
    apo_state_set HISTORY_PAIR_FRONTIERS ''
    apo_state_set HISTORY_PROVENANCE ''
    apo_state_set HISTORY_LEDGER_FILE ''
    apo_state_set HISTORY_SCANNED_STATES 0
    apo_state_set HISTORY_ACCEPTED_STATES 0
    apo_state_set HISTORY_EVIDENCE_COUNT 0
    apo_state_set HISTORY_ISOLATION_ANCHOR_CPU ''
    apo_state_set HISTORY_ISOLATION_ANCHOR_GPU ''
    apo_state_set HISTORY_CPU_TRIAL_CPU ''
    apo_state_set HISTORY_CPU_TRIAL_GPU ''
    apo_state_set HISTORY_GPU_TRIAL_CPU ''
    apo_state_set HISTORY_GPU_TRIAL_GPU ''
    apo_state_set HISTORY_PAIR_TRIAL_CPU ''
    apo_state_set HISTORY_PAIR_TRIAL_GPU ''
    apo_state_set HISTORY_BASE_CPU_QUALIFIED_CLOCK ''
    apo_state_set HISTORY_CPU_TRIAL_QUALIFIED_CLOCK ''
    apo_state_set HISTORY_ISOLATION_HANDOFF_CPU ''
    apo_state_set HISTORY_ISOLATION_HANDOFF_GPU ''
    apo_state_set HISTORY_ISOLATION_HISTORY ''
    apo_state_set HISTORY_FAILURE_EVENTS ''
    apo_state_set APPLY_STATUS NOT_APPLIED
    apo_state_set APPLY_OLD_HASH ''
    apo_state_set APPLY_EXPECTED_HASH ''
    apo_state_set APPLY_BACKUP ''
    apo_state_set APPLY_BOOT_ID ''
    apo_state_set APPLY_RECOVERY_ACTION ''
    apo_state_set APPLY_FAILURE_REASON ''
    apo_state_set OVERCLOCK_COMPLETE_RECORDED 0
    apo_state_set WATCHDOG_REPAIR_STATUS NOT_STARTED
    apo_state_set WATCHDOG_REPAIR_OLD_HASH ''
    apo_state_set WATCHDOG_REPAIR_EXPECTED_HASH ''
    apo_state_set WATCHDOG_REPAIR_NEW_HASH ''
    apo_state_set WATCHDOG_REPAIR_BACKUP ''
    apo_state_set FAILURE_CLASS ''
    apo_state_set FAILURE_REASON ''
    apo_state_set LAST_FAILURE_CLASS ''
    apo_state_set LAST_FAILURE_REASON ''
    apo_state_set TRYBOOT_EXPECTED 0
    apo_state_set TRYBOOT_FILE_MAY_EXIST 0
    apo_state_set TRYBOOT_OWNED_HASH ''
    apo_state_set TRYBOOT_RESERVATION_HASH ''
    apo_state_set TRYBOOT_OWNERSHIP_TOKEN ''
    apo_state_set TRYBOOT_QUARANTINE_PATH ''
    apo_state_set TRYBOOT_LAST_HASH ''
    apo_state_set MUTATIONS_STARTED 0
    apo_state_set BASELINE_BOOT_ID ''
    apo_state_set LAST_BOOT_ID ''
    apo_state_set CANDIDATE_BOOT_ID ''
    apo_state_set NORMAL_BOOT_ID ''
    apo_state_set RECOVERY_WAIT_STATUS IDLE
    apo_state_set RECOVERY_WAIT_CONTEXT ''
    apo_state_set RECOVERY_WAIT_STARTED_AT ''
    apo_state_set RECOVERY_WAIT_TIMEOUTS 0
    apo_state_set TRANSIENT_RETRY_CONTEXT ''
    apo_state_set TRANSIENT_RETRY_COUNT 0
    apo_state_set NORMAL_RETURN_RETRY_PENDING 0
    apo_state_set NORMAL_RETURN_RETRY_SOURCE ''
    apo_state_set NORMAL_RETURN_RETRY_REASON ''
    apo_state_set MANUAL_TEST "${APO_MANUAL_TEST:-0}"
    apo_state_set MANUAL_CPU "${APO_MANUAL_CPU:-}"
    apo_state_set MANUAL_GPU "${APO_MANUAL_GPU:-}"
    apo_state_set MANUAL_MINUTES "${APO_MANUAL_MINUTES:-}"
    apo_state_set MANUAL_DURATION_S "${APO_MANUAL_DURATION_S:-}"
    apo_state_set MANUAL_TEST_STATUS "$([[ ${APO_MANUAL_TEST:-0} == 1 ]] && printf READY || printf NOT_REQUESTED)"
    apo_state_set PROGRESS_ACTIVE_SECONDS 0
    apo_state_set PROGRESS_LAST_TEMP ''
    apo_state_set PROGRESS_LAST_CPU ''
    apo_state_set PROGRESS_LAST_GPU ''
    apo_state_set PROGRESS_LAST_THROTTLE ''
    apo_state_set PROGRESS_LAST_FAN ''
    apo_state_set PROGRESS_STRESS_LABEL ''
    apo_state_set PROGRESS_STRESS_ELAPSED 0
    apo_state_set PROGRESS_STRESS_DURATION 0
    apo_state_set RUN_MAX_TEMP ''
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
    apo_state_set REMOTE_STRESS_CREDIT_CONTEXT ''
    apo_state_set REMOTE_STRESS_CREDIT_SECONDS 0
    apo_state_set REMOTE_STRESS_CREDIT_DURATION_S ''
    apo_state_set REMOTE_STRESS_CREDIT_EVENT_ID ''
    apo_state_set UNATTRIBUTED_REBOOT_REPLAY_CONTEXT ''
    apo_state_set UNATTRIBUTED_REBOOT_REPLAY_COUNT 0
    apo_state_set NETWORK_WATCHDOG_REPLAY_COUNT 0
    apo_state_set NETWORK_WATCHDOG_LAST_EVENT_ID ''
    apo_state_set NETWORK_WATCHDOG_LAST_TARGET ''
    apo_state_save
}

apo_state_phase() {
    apo_state_set PHASE "$1"
    apo_state_set SUBPHASE "${2:-}"
    apo_state_set STATUS "${3:-RUNNING}"
    apo_state_save
    if declare -F apo_progress_render >/dev/null 2>&1; then apo_progress_render; fi
}

apo_state_fail() {
    local failure_class=$1 failure_reason=$2
    apo_state_set STATUS FAILED
    apo_state_set FAILURE_CLASS "$failure_class"
    apo_state_set FAILURE_REASON "$failure_reason"
    apo_state_save
    apo_event failure ERROR "$failure_class" "$failure_reason"
}

apo_state_interrupt() {
    local interruption_reason=$1
    apo_state_set STATUS INTERRUPTED
    apo_state_set FAILURE_CLASS ''
    apo_state_set FAILURE_REASON "$interruption_reason"
    apo_state_save
    apo_event interrupted WARN '' "$interruption_reason"
}

apo_state_clear_final_validation() {
    apo_state_set FINAL_CPU ''
    apo_state_set FINAL_GPU ''
    apo_state_set VALIDATION_SCHEMA ''
    apo_state_set VALIDATION_DURATION_S ''
    apo_state_set VALIDATED 0
}

apo_state_complete() {
    local final_cpu=$1 final_gpu=$2 validation_duration=$3
    [[ -n $final_cpu && -n $final_gpu ]] &&
        apo_validate_uint_range "$validation_duration" "$APO_MIN_TUNING_DURATION_S" "$APO_MAX_TUNING_DURATION_S" ||
        apo_die 'Internal error: final validation completion lacks clock or endurance-duration evidence.' "$APO_EXIT_INTERNAL"
    apo_state_set FINAL_CPU "$final_cpu"
    apo_state_set FINAL_GPU "$final_gpu"
    apo_state_set VALIDATION_SCHEMA "$APO_CURRENT_VALIDATION_SCHEMA"
    apo_state_set VALIDATION_DURATION_S "$validation_duration"
    apo_state_set STATUS PASS
    apo_state_set PHASE COMPLETE
    apo_state_set SUBPHASE DONE
    apo_state_set FINAL_STAGE COMPLETE
    apo_state_set VALIDATED 1
    apo_state_save
}
