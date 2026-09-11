#!/usr/bin/env bash
# Target-side, run-isolated stress supervisor. A controller may disconnect and
# reattach without terminating the worker. Every job has a fixed deadline.

set -Eeuo pipefail

readonly APO_JOB_FORMAT=1
: "${APO_JOB_HARD_GRACE_SECONDS:=300}"
[[ $APO_JOB_HARD_GRACE_SECONDS =~ ^[1-9][0-9]*$ ]] || APO_JOB_HARD_GRACE_SECONDS=300
readonly APO_JOB_HARD_GRACE_SECONDS

job_die() {
    printf 'APO_JOB_ERROR\t%s\n' "$1"
    return 1
}

valid_hex64() { [[ ${1-} =~ ^[0-9a-f]{64}$ ]]; }
valid_uint() { [[ ${1-} =~ ^[0-9]+$ ]]; }
valid_boot_id() { [[ ${1-} =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; }
valid_job_id() { [[ ${1-} =~ ^job-[0-9a-f]{32}$ ]]; }

read_boot_id() {
    local boot_id
    IFS= read -r boot_id </proc/sys/kernel/random/boot_id || return 1
    valid_boot_id "$boot_id" || return 1
    printf '%s' "$boot_id"
}

read_monotonic_seconds() {
    local seconds
    seconds=$(cut -d. -f1 /proc/uptime 2>/dev/null) || return 1
    valid_uint "$seconds" || return 1
    printf '%s' "$seconds"
}

atomic_lines() {
    local destination=$1 temporary
    shift
    temporary="${destination}.new.${BASHPID}"
    umask 077
    : >"$temporary"
    printf '%s\n' "$@" >"$temporary"
    sync "$temporary" 2>/dev/null || sync
    mv -f -- "$temporary" "$destination"
    sync "${destination%/*}" 2>/dev/null || sync
}

manifest_value() {
    local manifest=$1 key=$2
    sed -n "s/^${key}=//p" "$manifest" | tail -1
}

validate_job() {
    local root=$1 job_id=$2 token=$3 spec_hash=${4:-} job_dir manifest
    valid_job_id "$job_id" || return 1
    valid_hex64 "$token" || return 1
    [[ $root == /* && $root != / ]] || return 1
    job_dir="${root}/jobs/${job_id}"
    manifest="${job_dir}/manifest"
    [[ -d $job_dir && ! -L $job_dir && -f $manifest && ! -L $manifest ]] || return 1
    [[ $(manifest_value "$manifest" FORMAT) == "$APO_JOB_FORMAT" ]] || return 1
    [[ $(manifest_value "$manifest" JOB_ID) == "$job_id" ]] || return 1
    [[ $(manifest_value "$manifest" TOKEN) == "$token" ]] || return 1
    if [[ -n $spec_hash ]]; then
        valid_hex64 "$spec_hash" || return 1
        [[ $(manifest_value "$manifest" SPEC_HASH) == "$spec_hash" ]] || return 1
    fi
    printf '%s' "$job_dir"
}

supervisor_identity_matches() {
    local pid=$1 root=$2 job_id=$3 token=$4 helper_path index candidate
    local -a command_line=()
    helper_path=$(readlink -f -- "$0" 2>/dev/null || printf '%s' "$0")
    [[ -r /proc/${pid}/cmdline ]] || return 1
    mapfile -d '' -t command_line <"/proc/${pid}/cmdline" || return 1
    for (( index=0; index<${#command_line[@]}; index++ )); do
        candidate=$(readlink -f -- "${command_line[$index]}" 2>/dev/null || printf '%s' "${command_line[$index]}")
        if [[ $candidate == "$helper_path" && ${command_line[$((index + 1))]:-} == run &&
              ${command_line[$((index + 2))]:-} == "$root" &&
              ${command_line[$((index + 3))]:-} == "$job_id" &&
              ${command_line[$((index + 4))]:-} == "$token" ]]; then
            return 0
        fi
    done
    return 1
}

job_state() {
    local job_dir=$1 root=$2 job_id=$3 token=$4 pid
    if [[ -f ${job_dir}/complete && ! -L ${job_dir}/complete ]]; then
        printf COMPLETE
        return
    fi
    pid=$(sed -n '1p' "${job_dir}/supervisor.pid" 2>/dev/null || true)
    if valid_uint "$pid" && (( pid > 1 )) && kill -0 "$pid" 2>/dev/null &&
       supervisor_identity_matches "$pid" "$root" "$job_id" "$token"; then
        printf RUNNING
    else
        printf ORPHANED
    fi
}

run_job() {
    local root=$1 job_id=$2 token=$3
    shift 3
    local job_dir manifest output complete worker duration start_epoch start_monotonic source_boot_id spec_hash
    local hard_deadline hard_limit rc=0 now output_size output_hash end_epoch
    job_dir=$(validate_job "$root" "$job_id" "$token") || return 2
    manifest="${job_dir}/manifest"
    output="${job_dir}/worker.log"
    complete="${job_dir}/complete"
    worker=$(manifest_value "$manifest" WORKER)
    duration=$(manifest_value "$manifest" DURATION)
    start_epoch=$(manifest_value "$manifest" START_EPOCH)
    start_monotonic=$(manifest_value "$manifest" START_MONOTONIC_SECONDS)
    source_boot_id=$(manifest_value "$manifest" SOURCE_BOOT_ID)
    spec_hash=$(manifest_value "$manifest" SPEC_HASH)
    [[ -x $worker && ! -L $worker ]] || return 2
    valid_uint "$duration" && (( duration > 0 )) || return 2
    valid_uint "$start_epoch" || return 2
    valid_uint "$start_monotonic" || return 2
    valid_boot_id "$source_boot_id" || return 2
    valid_hex64 "$spec_hash" || return 2
    [[ $(read_boot_id) == "$source_boot_id" ]] || return 2
    printf '%s\n' "$BASHPID" >"${job_dir}/supervisor.pid"
    : >"$output"
    trap '' HUP
    hard_deadline=$((start_monotonic + duration + APO_JOB_HARD_GRACE_SECONDS))
    now=$(read_monotonic_seconds) || return 2
    hard_limit=$((hard_deadline - now))
    if (( hard_limit <= 0 )); then
        rc=124
    else
        set +e
        timeout -s TERM -k 30 "$hard_limit" "$worker" stress "$@" >>"$output" 2>&1
        rc=$?
        set -e
    fi
    if (( rc == 124 || rc == 137 )); then
        printf 'APO_RESULT_CLASS=HARNESS_FAILURE\n' >>"$output"
        printf 'APO_RESULT_REASON_B64=%s\n' "$(printf '%s' 'The detached stress worker exceeded its fixed deadline and was terminated.' | base64 | tr -d '\n')" >>"$output"
        rc=124
    fi
    sync "$output" 2>/dev/null || sync
    output_size=$(wc -c <"$output" | tr -d '[:space:]')
    output_hash=$(sha256sum "$output" | awk 'NR == 1 {print $1}')
    end_epoch=$(date +%s)
    atomic_lines "$complete" \
        "FORMAT=$APO_JOB_FORMAT" \
        "JOB_ID=$job_id" \
        "TOKEN=$token" \
        "SPEC_HASH=$spec_hash" \
        "SOURCE_BOOT_ID=$source_boot_id" \
        "START_EPOCH=$start_epoch" \
        "END_EPOCH=$end_epoch" \
        "DURATION=$duration" \
        "RC=$rc" \
        "OUTPUT_SIZE=$output_size" \
        "OUTPUT_SHA256=$output_hash"
    return 0
}

start_job() {
    local root=$1 job_id=$2 token=$3 spec_hash=$4 source_boot_id=$5 duration=$6 worker=$7
    shift 7
    local current_boot job_dir manifest state start_epoch start_monotonic supervisor_pid
    [[ $root == /* && $root != / ]] || job_die 'invalid job root'
    valid_job_id "$job_id" || job_die 'invalid job id'
    valid_hex64 "$token" || job_die 'invalid job token'
    valid_hex64 "$spec_hash" || job_die 'invalid job specification hash'
    valid_boot_id "$source_boot_id" || job_die 'invalid source boot id'
    valid_uint "$duration" && (( duration > 0 )) || job_die 'invalid duration'
    [[ $worker == /* && -x $worker && ! -L $worker ]] || job_die 'invalid worker path'
    command -v nohup >/dev/null 2>&1 || job_die 'nohup is unavailable'
    command -v setsid >/dev/null 2>&1 || job_die 'setsid is unavailable'
    command -v timeout >/dev/null 2>&1 || job_die 'timeout is unavailable'
    current_boot=$(read_boot_id) || job_die 'unreadable current boot id'
    [[ $current_boot == "$source_boot_id" ]] || job_die 'source boot id does not match current boot'
    mkdir -p -- "${root}/jobs"
    chmod 700 "$root" "${root}/jobs" 2>/dev/null || true
    job_dir="${root}/jobs/${job_id}"
    manifest="${job_dir}/manifest"
    if [[ -e $job_dir || -L $job_dir ]]; then
        job_dir=$(validate_job "$root" "$job_id" "$token" "$spec_hash") || job_die 'existing job ownership does not match'
        [[ $(manifest_value "$manifest" SOURCE_BOOT_ID) == "$source_boot_id" ]] || job_die 'existing job boot id does not match'
        [[ $(manifest_value "$manifest" DURATION) == "$duration" ]] || job_die 'existing job duration does not match'
        [[ $(manifest_value "$manifest" WORKER) == "$worker" ]] || job_die 'existing job worker path does not match'
        state=$(job_state "$job_dir" "$root" "$job_id" "$token")
        printf 'APO_JOB_STARTED\t%s\t%s\n' "$state" "$(manifest_value "$manifest" START_EPOCH)"
        [[ $state != ORPHANED ]]
        return
    fi
    mkdir -- "$job_dir"
    chmod 700 "$job_dir"
    start_epoch=$(date +%s)
    start_monotonic=$(read_monotonic_seconds) || job_die 'could not read the monotonic start time'
    atomic_lines "$manifest" \
        "FORMAT=$APO_JOB_FORMAT" \
        "JOB_ID=$job_id" \
        "TOKEN=$token" \
        "SPEC_HASH=$spec_hash" \
        "SOURCE_BOOT_ID=$source_boot_id" \
        "START_EPOCH=$start_epoch" \
        "START_MONOTONIC_SECONDS=$start_monotonic" \
        "DURATION=$duration" \
        "WORKER=$worker"
    nohup setsid "$0" run "$root" "$job_id" "$token" "$@" </dev/null >"${job_dir}/supervisor.log" 2>&1 &
    supervisor_pid=$!
    printf '%s\n' "$supervisor_pid" >"${job_dir}/launcher.pid"
    sleep 1
    state=$(job_state "$job_dir" "$root" "$job_id" "$token")
    printf 'APO_JOB_STARTED\t%s\t%s\n' "$state" "$start_epoch"
    [[ $state != ORPHANED ]]
}

last_telemetry_b64() {
    local output=$1 line
    line=$(tail -n 200 "$output" 2>/dev/null | grep -E ' temp=[^[:space:]]+C arm=[0-9]+MHz v3d=[0-9]+MHz .*elapsed=[0-9]+/[0-9]+s' | tail -1 || true)
    printf '%s' "$line" | base64 | tr -d '\n'
}

follow_job() {
    local root=$1 job_id=$2 token=$3 spec_hash=$4 job_dir manifest output complete
    local state source_boot_id current_boot start_epoch start_monotonic current_monotonic duration now size telemetry
    local rc output_hash end_epoch
    job_dir=$(validate_job "$root" "$job_id" "$token" "$spec_hash") || job_die 'job ownership does not match'
    manifest="${job_dir}/manifest"
    output="${job_dir}/worker.log"
    complete="${job_dir}/complete"
    source_boot_id=$(manifest_value "$manifest" SOURCE_BOOT_ID)
    start_epoch=$(manifest_value "$manifest" START_EPOCH)
    start_monotonic=$(manifest_value "$manifest" START_MONOTONIC_SECONDS)
    duration=$(manifest_value "$manifest" DURATION)
    valid_uint "$start_epoch" && valid_uint "$start_monotonic" || job_die 'job timing metadata is malformed'
    while :; do
        current_boot=$(read_boot_id) || job_die 'unreadable current boot id'
        [[ $current_boot == "$source_boot_id" ]] || job_die 'job boot id changed'
        state=$(job_state "$job_dir" "$root" "$job_id" "$token")
        size=$(wc -c <"$output" 2>/dev/null | tr -d '[:space:]' || printf 0)
        valid_uint "$size" || size=0
        telemetry=$(last_telemetry_b64 "$output")
        current_monotonic=$(read_monotonic_seconds) || job_die 'current monotonic time is unreadable'
        now=$((start_epoch + current_monotonic - start_monotonic))
        printf 'APO_JOB_HEARTBEAT\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$state" "$now" "$start_epoch" "$duration" "$source_boot_id" "$size" "$telemetry"
        if [[ $state == COMPLETE ]]; then
            rc=$(manifest_value "$complete" RC)
            size=$(manifest_value "$complete" OUTPUT_SIZE)
            output_hash=$(manifest_value "$complete" OUTPUT_SHA256)
            end_epoch=$(manifest_value "$complete" END_EPOCH)
            valid_uint "$rc" && valid_uint "$size" && valid_hex64 "$output_hash" && valid_uint "$end_epoch" || job_die 'completion metadata is malformed'
            printf 'APO_JOB_COMPLETE\t%s\t%s\t%s\t%s\t%s\n' "$rc" "$size" "$output_hash" "$end_epoch" "$source_boot_id"
            return 0
        fi
        [[ $state == RUNNING ]] || job_die 'detached stress supervisor is not running'
        sleep 1
    done
}

fetch_job() {
    local root=$1 job_id=$2 token=$3 spec_hash=$4 job_dir complete
    job_dir=$(validate_job "$root" "$job_id" "$token" "$spec_hash") || job_die 'job ownership does not match'
    complete="${job_dir}/complete"
    [[ -f $complete && ! -L $complete ]] || job_die 'job is not complete'
    cat -- "${job_dir}/worker.log"
}

inspect_job() {
    local root=$1 job_id=$2 token=$3 spec_hash=$4 job_dir manifest state
    job_dir=$(validate_job "$root" "$job_id" "$token" "$spec_hash") || job_die 'job ownership does not match'
    manifest="${job_dir}/manifest"
    state=$(job_state "$job_dir" "$root" "$job_id" "$token")
    printf 'APO_JOB_INSPECT\t%s\t%s\t%s\t%s\n' "$state" \
        "$(manifest_value "$manifest" SOURCE_BOOT_ID)" \
        "$(manifest_value "$manifest" START_EPOCH)" \
        "$(manifest_value "$manifest" DURATION)"
}

main() {
    local command_name=${1:-}
    [[ -n $command_name ]] || job_die 'command is required'
    shift || true
    case $command_name in
        start) start_job "$@" ;;
        run) run_job "$@" ;;
        follow) follow_job "$@" ;;
        fetch) fetch_job "$@" ;;
        inspect) inspect_job "$@" ;;
        *) job_die 'unknown command' ;;
    esac
}

main "$@"
