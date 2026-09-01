#!/usr/bin/env bash
# SSH transport. User aliases/config wrappers are bypassed with command ssh -F /dev/null.

declare -ag APO_SSH_OPTIONS=()
APO_REMOTE_IS_ROOT=0
: "${APO_PERSISTENT_SSH_POLL_SECONDS:=10}"
: "${APO_PERSISTENT_SSH_NOTICE_SECONDS:=300}"
: "${APO_TRANSIENT_READ_ATTEMPTS:=30}"
: "${APO_TRANSIENT_READ_DELAY_SECONDS:=10}"
: "${APO_PREFLIGHT_SSH_TIMEOUT_SECONDS:=300}"
readonly APO_PERSISTENT_SSH_POLL_SECONDS APO_PERSISTENT_SSH_NOTICE_SECONDS

apo_persistent_ssh_recovery_enabled() {
    [[ ${APO_PERSISTENT_SSH_RECOVERY:-0} == 1 ]]
}

apo_transient_read_policy_normalize() {
    [[ $APO_TRANSIENT_READ_ATTEMPTS =~ ^[1-9][0-9]*$ ]] || APO_TRANSIENT_READ_ATTEMPTS=30
    [[ $APO_TRANSIENT_READ_DELAY_SECONDS =~ ^[0-9]+$ ]] || APO_TRANSIENT_READ_DELAY_SECONDS=10
}

apo_transient_read_delay() {
    if (( APO_TRANSIENT_READ_DELAY_SECONDS > 0 )); then sleep "$APO_TRANSIENT_READ_DELAY_SECONDS"; fi
    return 0
}

apo_recovery_wait_checkpoint() {
    local status=$1 context=$2 timeout_count
    [[ -n ${APO_STATE_FILE:-} && -f ${APO_STATE_FILE:-} ]] || return 0
    apo_state_set RECOVERY_WAIT_STATUS "$status"
    apo_state_set RECOVERY_WAIT_CONTEXT "$context"
    case $status in
        WAITING)
            apo_state_set RECOVERY_WAIT_STARTED_AT "$(apo_now_iso)"
            timeout_count=$(apo_state_get RECOVERY_WAIT_TIMEOUTS 0)
            [[ $timeout_count =~ ^[0-9]+$ ]] || timeout_count=0
            apo_state_set RECOVERY_WAIT_TIMEOUTS "$((timeout_count + 1))"
            ;;
        RETURNED|IDLE)
            apo_state_set RECOVERY_WAIT_STARTED_AT ''
            ;;
    esac
    apo_state_save
}

apo_recovery_wait_event() {
    local severity=$1 context=$2 message=$3
    if [[ -n ${APO_LOG_FILE:-} && -f ${APO_LOG_FILE:-} ]]; then
        apo_event "$context" "$severity" '' "$message"
    else
        apo_warn_plain "$message"
    fi
}

apo_recovery_wait_begin() {
    local context=$1 timeout_seconds=$2
    apo_recovery_wait_checkpoint WAITING "$context"
    apo_recovery_wait_event WARN "$context" "The target has not returned to SSH after ${timeout_seconds}s. The unattended operation remains in safe read-only monitoring and will reconcile the boot automatically when SSH returns; Ctrl-C leaves saved work resumable."
}

apo_recovery_wait_finish() {
    local context=$1
    apo_recovery_wait_checkpoint RETURNED "$context"
    apo_recovery_wait_event INFO "$context" 'SSH returned after extended recovery monitoring; reconciling boot identity, tryboot ownership, normal clocks, and health before continuing.'
}

apo_ssh_init() {
    APO_SSH_OPTIONS=(
        -F /dev/null
        -o BatchMode=yes
        -o ConnectTimeout=8
        -o ServerAliveInterval=5
        -o ServerAliveCountMax=3
        -o StrictHostKeyChecking=accept-new
        -p "$APO_SSH_PORT"
    )
    if [[ -n $APO_IDENTITY_FILE ]]; then APO_SSH_OPTIONS+=(-i "$APO_IDENTITY_FILE" -o IdentitiesOnly=yes); fi
}

apo_ssh_exec() { command ssh "${APO_SSH_OPTIONS[@]}" -n -T "$APO_REMOTE_TARGET" "$@"; }
apo_ssh_exec_stdin() {
    local remote_command=$1
    command ssh "${APO_SSH_OPTIONS[@]}" -T "$APO_REMOTE_TARGET" "$remote_command"
}

# Scalar read helpers retry transport loss without replaying a mutation. Their
# stdout is emitted only after a successful attempt so a partial SSH response
# can never be mistaken for complete evidence.
apo_ssh_read() {
    local remote_command=$1 output='' attempt
    apo_transient_read_policy_normalize
    for (( attempt=1; attempt<=APO_TRANSIENT_READ_ATTEMPTS; attempt++ )); do
        output=''
        if output=$(apo_ssh_exec "$remote_command" 2>/dev/null); then
            printf '%s' "$output"
            return 0
        fi
        (( attempt < APO_TRANSIENT_READ_ATTEMPTS )) && apo_transient_read_delay
    done
    return 1
}

# Exact-file reads preserve final newlines and never expose a partial attempt.
apo_ssh_read_file() {
    local output_file=$1 remote_command=$2 attempt temporary_file
    apo_transient_read_policy_normalize
    for (( attempt=1; attempt<=APO_TRANSIENT_READ_ATTEMPTS; attempt++ )); do
        temporary_file="${output_file}.read.${BASHPID}.${attempt}"
        rm -f -- "$temporary_file"
        if apo_ssh_exec "$remote_command" > "$temporary_file" 2>/dev/null; then
            mv -f -- "$temporary_file" "$output_file"
            return 0
        fi
        rm -f -- "$temporary_file"
        (( attempt < APO_TRANSIENT_READ_ATTEMPTS )) && apo_transient_read_delay
    done
    return 1
}

apo_remote_root() {
    local remote_command=$1 wrapper
    if (( APO_REMOTE_IS_ROOT == 1 )); then wrapper="/bin/bash -c $(apo_sh_quote "$remote_command")";
    else wrapper="sudo -n /bin/bash -c $(apo_sh_quote "$remote_command")"; fi
    apo_ssh_exec "$wrapper"
}

apo_remote_root_read() {
    local remote_command=$1 wrapper
    if (( APO_REMOTE_IS_ROOT == 1 )); then wrapper="/bin/bash -c $(apo_sh_quote "$remote_command")";
    else wrapper="sudo -n /bin/bash -c $(apo_sh_quote "$remote_command")"; fi
    apo_ssh_read "$wrapper"
}

apo_remote_root_read_file() {
    local output_file=$1 remote_command=$2 wrapper
    if (( APO_REMOTE_IS_ROOT == 1 )); then wrapper="/bin/bash -c $(apo_sh_quote "$remote_command")";
    else wrapper="sudo -n /bin/bash -c $(apo_sh_quote "$remote_command")"; fi
    apo_ssh_read_file "$output_file" "$wrapper"
}

apo_remote_root_stdin() {
    local remote_command=$1 wrapper
    if (( APO_REMOTE_IS_ROOT == 1 )); then wrapper="/bin/bash -c $(apo_sh_quote "$remote_command")";
    else wrapper="sudo -n /bin/bash -c $(apo_sh_quote "$remote_command")"; fi
    apo_ssh_exec_stdin "$wrapper"
}

apo_ssh_preflight() {
    local uid has_bash sudo_ready
    apo_wait_for_ssh "$APO_PREFLIGHT_SSH_TIMEOUT_SECONDS" preflight-connect ||
        apo_die "Noninteractive SSH failed for $APO_REMOTE_TARGET. Configure key authentication and run prepare again." "$APO_EXIT_PREFLIGHT"
    uid=$(apo_ssh_read 'id -u') || apo_die "Could not determine remote UID after $APO_TRANSIENT_READ_ATTEMPTS attempts." "$APO_EXIT_PREFLIGHT"
    has_bash=$(apo_ssh_read 'command -v bash >/dev/null 2>&1 && printf yes || printf no' || true)
    [[ $has_bash == yes ]] || apo_die 'Remote Bash is required.' "$APO_EXIT_PREFLIGHT"
    if [[ $uid == 0 ]]; then APO_REMOTE_IS_ROOT=1;
    else
        # Return a semantic yes/no through a successful remote shell. That
        # keeps a real sudo refusal distinct from a transient SSH failure,
        # which receives the same bounded read retry as every other preflight
        # fact.
        sudo_ready=$(apo_ssh_read 'if sudo -n true >/dev/null 2>&1; then printf yes; else printf no; fi' || true)
        [[ $sudo_ready == yes ]] || apo_die "$APO_REMOTE_TARGET is not root and passwordless sudo -n is unavailable." "$APO_EXIT_PREFLIGHT"
        APO_REMOTE_IS_ROOT=0
    fi
}

apo_remote_upload_root() {
    local local_file=$1 remote_file=$2 remote_directory expected_hash remote_command attempt
    [[ -r $local_file ]] || apo_die "Local upload file is unreadable: $local_file" "$APO_EXIT_INTERNAL"
    remote_directory=${remote_file%/*}
    expected_hash=$(sha256sum "$local_file" | awk 'NR == 1 {print $1}')
    [[ $expected_hash =~ ^[0-9a-f]{64}$ ]] || apo_die "Could not hash local upload file: $local_file" "$APO_EXIT_INTERNAL"
    remote_command=$'set -Eeuo pipefail\numask 077\n'
    remote_command+="remote_directory=$(apo_sh_quote "$remote_directory")"$'\n'
    remote_command+="remote_file=$(apo_sh_quote "$remote_file")"$'\n'
    remote_command+="expected_hash=$(apo_sh_quote "$expected_hash")"$'\n'
    remote_command+=$(cat <<'APO_REMOTE_UPLOAD'
mkdir -p -- "$remote_directory"
temporary_file=$(mktemp "${remote_file}.upload.XXXXXX")
trap 'rm -f -- "$temporary_file"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
cat > "$temporary_file"
actual_hash=$(sha256sum "$temporary_file" | awk 'NR == 1 {print $1}')
[[ $actual_hash == "$expected_hash" ]]
chmod 700 "$temporary_file"
sync
mv -f -- "$temporary_file" "$remote_file"
actual_hash=$(sha256sum "$remote_file" | awk 'NR == 1 {print $1}')
[[ $actual_hash == "$expected_hash" ]]
sync
trap - EXIT INT TERM HUP
APO_REMOTE_UPLOAD
)
    remote_command+=$'\n'
    apo_transient_read_policy_normalize
    for (( attempt=1; attempt<=APO_TRANSIENT_READ_ATTEMPTS; attempt++ )); do
        if apo_remote_root_stdin "$remote_command" < "$local_file"; then return 0; fi
        (( attempt < APO_TRANSIENT_READ_ATTEMPTS )) && apo_transient_read_delay
    done
    return 1
}

apo_remote_worker() {
    local remote_worker=$1 argument command_line
    shift
    command_line=$(apo_sh_quote "$remote_worker")
    for argument in "$@"; do command_line+=" $(apo_sh_quote "$argument")"; done
    apo_remote_root "$command_line"
}

apo_remote_worker_read_file() {
    local output_file=$1 remote_worker=$2 argument command_line
    shift 2
    command_line=$(apo_sh_quote "$remote_worker")
    for argument in "$@"; do command_line+=" $(apo_sh_quote "$argument")"; done
    apo_remote_root_read_file "$output_file" "$command_line"
}

apo_remote_boot_id_once() {
    local boot_id
    boot_id=$(apo_ssh_exec 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null) || return 1
    boot_id=${boot_id//$'\r'/}
    boot_id=${boot_id//$'\n'/}
    [[ $boot_id =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || return 1
    printf '%s' "$boot_id"
}

apo_remote_boot_id() {
    local attempt boot_id
    apo_transient_read_policy_normalize
    for (( attempt=1; attempt<=APO_TRANSIENT_READ_ATTEMPTS; attempt++ )); do
        if boot_id=$(apo_remote_boot_id_once); then printf '%s' "$boot_id"; return 0; fi
        (( attempt < APO_TRANSIENT_READ_ATTEMPTS )) && apo_transient_read_delay
    done
    return 1
}

apo_remote_tryboot_flag_once() {
    local tryboot_flag
    tryboot_flag=$(apo_ssh_exec 'od -An -tx1 /proc/device-tree/chosen/bootloader/tryboot 2>/dev/null | tr -d " \n"' 2>/dev/null) || return 1
    tryboot_flag=${tryboot_flag//$'\r'/}
    tryboot_flag=${tryboot_flag//$'\n'/}
    [[ $tryboot_flag == 00000000 || $tryboot_flag == 00000001 ]] || return 1
    printf '%s' "$tryboot_flag"
}

apo_remote_tryboot_flag() {
    local attempt tryboot_flag
    apo_transient_read_policy_normalize
    for (( attempt=1; attempt<=APO_TRANSIENT_READ_ATTEMPTS; attempt++ )); do
        if tryboot_flag=$(apo_remote_tryboot_flag_once); then printf '%s' "$tryboot_flag"; return 0; fi
        (( attempt < APO_TRANSIENT_READ_ATTEMPTS )) && apo_transient_read_delay
    done
    return 1
}

apo_wait_for_ssh() {
    local timeout_seconds=$1 context=${2:-ssh-recovery} deadline remaining next_notice
    deadline=$((SECONDS + timeout_seconds))
    while (( SECONDS < deadline )); do
        if declare -F apo_progress_render >/dev/null 2>&1; then apo_progress_render; fi
        if apo_ssh_exec true >/dev/null 2>&1; then return 0; fi
        remaining=$((deadline - SECONDS))
        (( remaining > 0 )) || break
        if (( remaining < 3 )); then sleep "$remaining"; else sleep 3; fi
    done
    apo_persistent_ssh_recovery_enabled || return 1
    apo_recovery_wait_begin "$context" "$timeout_seconds"
    next_notice=$((SECONDS + APO_PERSISTENT_SSH_NOTICE_SECONDS))
    while :; do
        if declare -F apo_progress_render >/dev/null 2>&1; then apo_progress_render; fi
        if apo_ssh_exec true >/dev/null 2>&1; then
            apo_recovery_wait_finish "$context"
            return 0
        fi
        if (( SECONDS >= next_notice )); then
            apo_recovery_wait_event INFO "$context" 'The target is still unreachable; unattended recovery monitoring remains active and no additional reboot is being requested.'
            next_notice=$((SECONDS + APO_PERSISTENT_SSH_NOTICE_SECONDS))
        fi
        sleep "$APO_PERSISTENT_SSH_POLL_SECONDS"
    done
}

apo_wait_for_new_boot() {
    local old_boot_id=$1 timeout_seconds=$2 context=${3:-reboot} deadline remaining current='' next_notice last_observation=unreachable
    deadline=$((SECONDS + timeout_seconds))
    while (( SECONDS < deadline )); do
        if declare -F apo_progress_render >/dev/null 2>&1; then apo_progress_render; fi
        current=$(apo_remote_boot_id_once 2>/dev/null || true)
        if [[ -n $current ]]; then
            if [[ $current != "$old_boot_id" ]]; then printf '%s' "$current"; return 0; fi
            last_observation=old-boot
        else
            last_observation=unreachable
        fi
        remaining=$((deadline - SECONDS))
        (( remaining > 0 )) || break
        if (( remaining < 3 )); then sleep "$remaining"; else sleep 3; fi
    done
    # A continuously reachable old boot means the requested reboot was not
    # proved. If it disappeared before the deadline, however, keep observing:
    # a slow target must not be abandoned merely because its old boot answered
    # once while shutdown was beginning.
    [[ $last_observation != old-boot ]] || return 1
    apo_persistent_ssh_recovery_enabled || return 1
    apo_recovery_wait_begin "$context" "$timeout_seconds"
    next_notice=$((SECONDS + APO_PERSISTENT_SSH_NOTICE_SECONDS))
    while :; do
        if declare -F apo_progress_render >/dev/null 2>&1; then apo_progress_render; fi
        current=$(apo_remote_boot_id_once 2>/dev/null || true)
        if [[ -n $current ]]; then
            apo_recovery_wait_finish "$context"
            printf '%s' "$current"
            if [[ $current != "$old_boot_id" ]]; then return 0; fi
            return 1
        fi
        if (( SECONDS >= next_notice )); then
            apo_recovery_wait_event INFO "$context" 'The target is still unreachable; unattended recovery monitoring remains active and no additional reboot is being requested.'
            next_notice=$((SECONDS + APO_PERSISTENT_SSH_NOTICE_SECONDS))
        fi
        sleep "$APO_PERSISTENT_SSH_POLL_SECONDS"
    done
}
