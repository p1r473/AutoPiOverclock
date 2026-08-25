#!/usr/bin/env bash
# AutoPiOverclock remote worker for Raspberry Pi OS, Debian, and Ubuntu Pi layouts.
set -u -o pipefail
umask 077

ERROR_PATTERN='under.?voltage|throttl|Hardware Error|SError|Kernel panic|Internal error[[:space:]]*:|Unable to handle kernel|RCU.*(detected|self-detected).*stall|kthread starved for|kthread timer wakeup.*happen|hung[_ -]?task|task[[:space:]].*blocked for more than[[:space:]]+[0-9]+[[:space:]]+seconds|v3d.*(hang|fault|error|timeout)|drm.*(hang|fault|error|timeout)|device offline|I/O error|Buffer I/O error|EXT4-fs (error|warning)|BTRFS.*(error|warning)|segfault|Oops:|BUG:|Call trace|watchdog:.*lockup'
USB_RESET_PATTERN='usb [0-9.-]+: reset (low-speed|full-speed|high-speed|SuperSpeed|SuperSpeed Plus)?[[:space:]]*USB device|reset (low-speed|full-speed|high-speed|SuperSpeed|SuperSpeed Plus)[[:space:]]+USB device'
CLOCK_MARKER_BEGIN='# BEGIN AUTOPIOVERCLOCK MANAGED CLOCKS'
CLOCK_MARKER_END='# END AUTOPIOVERCLOCK MANAGED CLOCKS'
TRYBOOT_RESERVATION_MARKER='# AUTOPIOVERCLOCK TRYBOOT RESERVATION'
WATCHDOG_MARKER_BEGIN='# BEGIN AUTOPIOVERCLOCK WATCHDOG'
WATCHDOG_MARKER_END='# END AUTOPIOVERCLOCK WATCHDOG'
MUTATION_LOCK_DIR=/run/autopioverclock-mutation.lock
MUTATION_LOCK_HELD=0
MUTATION_LOCK_OWNER=''

b64() { printf '%s' "${1-}" | base64 | tr -d '\n'; }
emit_data() { printf 'APO_DATA\t%s\t%s\n' "$1" "$(b64 "${2-}")"; }
emit_result() {
    local result_class=$1 result_reason=$2 max_temp=${3:-}
    printf 'APO_RESULT_CLASS=%s\n' "$result_class"
    printf 'APO_RESULT_REASON_B64=%s\n' "$(b64 "$result_reason")"
    if [[ -n $max_temp ]]; then printf 'APO_MAX_TEMP=%s\n' "$max_temp"; fi
    return 0
}

mutation_lock_release() {
    local recorded_owner=''
    (( MUTATION_LOCK_HELD == 1 )) || return 0
    [[ -d $MUTATION_LOCK_DIR && ! -L $MUTATION_LOCK_DIR ]] || return 1
    recorded_owner=$(cat "$MUTATION_LOCK_DIR/owner" 2>/dev/null || true)
    [[ $recorded_owner == "$MUTATION_LOCK_OWNER" ]] || return 1
    rm -f -- "$MUTATION_LOCK_DIR/owner" || return 1
    rmdir -- "$MUTATION_LOCK_DIR" || return 1
    MUTATION_LOCK_HELD=0
    MUTATION_LOCK_OWNER=''
}

mutation_lock_signal() {
    local exit_code=$1
    trap - EXIT INT TERM HUP
    mutation_lock_release >/dev/null 2>&1 || true
    exit "$exit_code"
}

mutation_lock_acquire() {
    local owner=$1
    [[ $owner =~ ^[A-Za-z0-9._:-]+$ ]] || return 1
    mkdir -- "$MUTATION_LOCK_DIR" 2>/dev/null || return 1
    MUTATION_LOCK_HELD=1
    MUTATION_LOCK_OWNER=$owner
    if ! printf '%s\n' "$owner" > "$MUTATION_LOCK_DIR/owner"; then
        rmdir -- "$MUTATION_LOCK_DIR" 2>/dev/null || true
        MUTATION_LOCK_HELD=0
        MUTATION_LOCK_OWNER=''
        return 1
    fi
}

run_with_mutation_lock() {
    local owner=$1 failure_class=$2 locked_command=$3 command_rc release_rc=0
    shift 3
    if ! mutation_lock_acquire "$owner"; then
        emit_result "$failure_class" 'Another target mutation is active or left an unresolved target-side lock; refusing concurrent mutation.'
        return 1
    fi
    trap 'mutation_lock_release >/dev/null 2>&1 || true' EXIT
    trap 'mutation_lock_signal 130' INT
    trap 'mutation_lock_signal 143' TERM
    trap 'mutation_lock_signal 129' HUP
    "$locked_command" "$@"
    command_rc=$?
    if [[ ${APO_APPLY_BOOT_RW:-0} == 1 ]]; then
        if (( command_rc == 0 )); then
            emit_result "$failure_class" 'The target mutation returned success while its boot filesystem still required read-only restoration.'
            command_rc=1
        fi
    else
        mutation_lock_release || release_rc=$?
        trap - EXIT INT TERM HUP
    fi
    if (( command_rc == 0 && release_rc != 0 )); then
        emit_result "$failure_class" 'The target mutation completed, but its target-side lock could not be released safely.'
        return 1
    fi
    return "$command_rc"
}

apply_tryboot_clear() {
    local boot_config=$1 tryboot_config tryboot_exists tryboot_type tryboot_hash live_flag quarantine_path
    tryboot_config="$(dirname "$boot_config")/tryboot.txt"
    inspect_tryboot_path "$tryboot_config" tryboot_exists tryboot_type tryboot_hash
    [[ $tryboot_exists == 0 ]] || return 1
    live_flag=$(od -An -tx1 /proc/device-tree/chosen/bootloader/tryboot 2>/dev/null | tr -d ' \n' || true)
    [[ $live_flag == 00000000 ]] || return 1
    for quarantine_path in "$(dirname "$boot_config")"/.autopioverclock-remove-*; do
        [[ ! -e $quarantine_path && ! -L $quarantine_path ]] || return 1
    done
}

find_boot_config() {
    if [[ -f /boot/firmware/config.txt ]]; then printf '/boot/firmware/config.txt';
    elif [[ -f /boot/config.txt ]]; then printf '/boot/config.txt';
    else return 1; fi
}

inspect_tryboot_path() {
    local candidate_path=$1 exists_name=$2 type_name=$3 hash_name=$4
    local inspected_exists=0 inspected_type=absent inspected_hash=unavailable
    if [[ -L $candidate_path ]]; then
        inspected_exists=1
        inspected_type=symlink
    elif [[ -f $candidate_path ]]; then
        inspected_exists=1
        inspected_type=regular
        inspected_hash=$(sha256sum "$candidate_path" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
        [[ $inspected_hash =~ ^[0-9a-f]{64}$ ]] || inspected_hash=unavailable
    elif [[ -d $candidate_path ]]; then
        inspected_exists=1
        inspected_type=directory
    elif [[ -e $candidate_path ]]; then
        inspected_exists=1
        inspected_type=other
    fi
    printf -v "$exists_name" '%s' "$inspected_exists"
    printf -v "$type_name" '%s' "$inspected_type"
    printf -v "$hash_name" '%s' "$inspected_hash"
}

tryboot_path_allowed() {
    local boot_config=$1 tryboot_config=$2
    [[ $boot_config == /* && $tryboot_config == "$(dirname "$boot_config")/tryboot.txt" ]]
}

render_tryboot_reservation() {
    printf '%s\n# Run: %s\n# Ownership: %s\n' "$TRYBOOT_RESERVATION_MARKER" "$1" "$2"
}

managed_tryboot_matches_run() {
    local tryboot_file=$1 run_id=$2 ownership_token=$3
    tryboot_header_matches_run "$tryboot_file" "$run_id" "$ownership_token" &&
    [[ $(grep -Fxc -- "$CLOCK_MARKER_BEGIN" "$tryboot_file" 2>/dev/null || true) == 1 &&
       $(grep -Fxc -- "$CLOCK_MARKER_END" "$tryboot_file" 2>/dev/null || true) == 1 &&
       $(grep -Fxc -- "# Run: $run_id" "$tryboot_file" 2>/dev/null || true) == 2 &&
       $(grep -Fxc -- "# AUTOPIOVERCLOCK TRYBOOT COMPLETE: $ownership_token" "$tryboot_file" 2>/dev/null || true) == 1 ]]
}

tryboot_reservation_matches_run() {
    local tryboot_file=$1 run_id=$2 ownership_token=$3 actual_content expected_content
    actual_content=$(<"$tryboot_file")
    expected_content=$(render_tryboot_reservation "$run_id" "$ownership_token")
    [[ $actual_content == "$expected_content" ]]
}

tryboot_header_matches_run() {
    local tryboot_file=$1 run_id=$2 ownership_token=$3 actual_header expected_header
    actual_header=$(head -n 3 "$tryboot_file" 2>/dev/null || true)
    expected_header=$(render_tryboot_reservation "$run_id" "$ownership_token")
    [[ $actual_header == "$expected_header" ]]
}

tryboot_quarantine_path() {
    printf '%s/.autopioverclock-remove-%s' "$(dirname "$1")" "$2"
}

owned_tryboot_kind() {
    local tryboot_file=$1 expected_tryboot_hash=$2 expected_reservation_hash=$3 run_id=$4 ownership_token=$5 actual_hash
    [[ -f $tryboot_file && ! -L $tryboot_file ]] || return 1
    actual_hash=$(sha256sum "$tryboot_file" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    if [[ $actual_hash == "$expected_tryboot_hash" ]] && managed_tryboot_matches_run "$tryboot_file" "$run_id" "$ownership_token"; then
        printf candidate
    elif [[ $actual_hash == "$expected_reservation_hash" ]] && tryboot_reservation_matches_run "$tryboot_file" "$run_id" "$ownership_token"; then
        printf reservation
    elif tryboot_header_matches_run "$tryboot_file" "$run_id" "$ownership_token" &&
        [[ $(grep -Fxc -- "# AUTOPIOVERCLOCK TRYBOOT COMPLETE: $ownership_token" "$tryboot_file" 2>/dev/null || true) == 0 ]]; then
        printf partial
    else
        return 1
    fi
}

config_last_value() {
    local config_file=$1 config_key=$2
    awk -v wanted="$config_key" '
        /^[[:space:]]*#/ {next}
        {line=$0; sub(/^[[:space:]]*/, "", line); if(line ~ "^" wanted "[[:space:]]*="){sub("^" wanted "[[:space:]]*=[[:space:]]*", "", line); sub(/[[:space:]]*#.*/, "", line); value=line}}
        END{if(value!="") print value}
    ' "$config_file" 2>/dev/null
}

active_config_value() {
    local config_key=$1 value=''
    value=$(vcgencmd get_config "$config_key" 2>/dev/null | awk -F= -v wanted="$config_key" '$1==wanted{v=$2} END{print v}')
    [[ -n $value ]] || value=$(vcgencmd get_config int 2>/dev/null | awk -F= -v wanted="$config_key" '$1==wanted{v=$2} END{print v}')
    printf '%s' "$value"
}

active_config_interface_ready() { vcgencmd get_config int >/dev/null 2>&1; }

discovered_config_value() {
    active_config_value "$1"
}

permanent_config_snapshot_hash() {
    local config_file=$1 snapshot_hash
    snapshot_hash=$(sha256sum "$config_file" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    [[ $snapshot_hash =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s' "$snapshot_hash"
}

permanent_tuning_key() {
    case $1 in
        arm_boost|force_turbo|initial_turbo|core_freq_fixed|*_freq|*_freq_min|over_voltage*) return 0 ;;
        *) return 1 ;;
    esac
}

permanent_tuning_override_evidence() {
    local root_config=$1 root_dir canonical_file line trimmed key evidence=''
    root_dir=$(readlink -f -- "$(dirname "$root_config")" 2>/dev/null || true)
    [[ -n $root_dir && -d $root_dir ]] || { printf 'unresolvable-boot-root'; return 2; }
    [[ -e $root_config ]] || { printf 'unreadable-config'; return 2; }
    canonical_file=$(readlink -f -- "$root_config" 2>/dev/null || true)
    [[ -n $canonical_file ]] || { printf 'unresolvable-config-path'; return 2; }
    [[ $canonical_file == "$root_dir"/* && -f $canonical_file && -r $canonical_file ]] || { printf 'unreadable-config'; return 2; }
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        if [[ $line =~ ^[[:space:]]*([[:alnum:]_]+)[[:space:]]*= ]]; then
            key=${BASH_REMATCH[1],,}
            if permanent_tuning_key "$key"; then
                [[ ",$evidence," == *",$key,"* ]] || evidence=${evidence:+$evidence,}$key
                continue
            fi
        fi
        trimmed=${line#"${line%%[![:space:]]*}"}
        [[ -n $trimmed && $trimmed != \#* ]] || continue
        if [[ $trimmed =~ ^include([[:space:]]|$) ]]; then
            printf 'include-not-bound-to-permanent-hash%s' "${evidence:+:$evidence}"
            return 2
        fi
    done < "$canonical_file"
    printf '%s' "$evidence"
}

audit_permanent_tuning_config() {
    local config_file=$1 scan_output audit_rc hash_before hash_after
    PERMANENT_TUNING_PROVENANCE=ambiguous
    PERMANENT_TUNING_EVIDENCE='audit-failed'
    PERMANENT_TUNING_CONFIG_HASH=''
    hash_before=$(permanent_config_snapshot_hash "$config_file" || true)
    if [[ ! $hash_before =~ ^[0-9a-f]{64}$ ]]; then
        PERMANENT_TUNING_EVIDENCE='unreadable-config-snapshot'
        return 0
    fi
    if scan_output=$(permanent_tuning_override_evidence "$config_file"); then
        audit_rc=0
    else
        audit_rc=$?
    fi
    hash_after=$(permanent_config_snapshot_hash "$config_file" || true)
    if [[ ! $hash_after =~ ^[0-9a-f]{64}$ ]]; then
        PERMANENT_TUNING_EVIDENCE='unreadable-config-snapshot'
        return 0
    fi
    if [[ $hash_before != "$hash_after" ]]; then
        PERMANENT_TUNING_EVIDENCE='permanent-config-changed-during-audit'
        return 0
    fi
    PERMANENT_TUNING_CONFIG_HASH=$hash_after
    if (( audit_rc != 0 )); then
        PERMANENT_TUNING_PROVENANCE=ambiguous
        PERMANENT_TUNING_EVIDENCE=${scan_output:-audit-failed-rc-$audit_rc}
    elif [[ -n $scan_output ]]; then
        PERMANENT_TUNING_PROVENANCE=explicit-override
        PERMANENT_TUNING_EVIDENCE=$scan_output
    else
        PERMANENT_TUNING_PROVENANCE=verified-default
        PERMANENT_TUNING_EVIDENCE=none
    fi
}

kernel_log() {
    if command -v journalctl >/dev/null 2>&1; then journalctl -k -b --no-pager 2>/dev/null || dmesg 2>/dev/null;
    else dmesg 2>/dev/null; fi
}

root_source() { findmnt -n -o SOURCE / 2>/dev/null || mount | awk '$3=="/"{print $1; exit}'; }

kernel_error_lines() {
    local start_line=${1:-1} log_text common_errors usb_errors
    log_text=$(kernel_log | tail -n "+${start_line}")
    common_errors=$(printf '%s\n' "$log_text" | grep -Ei "$ERROR_PATTERN" || true)
    usb_errors=$(printf '%s\n' "$log_text" | grep -Ei "$USB_RESET_PATTERN" || true)
    printf '%s\n%s\n' "$common_errors" "$usb_errors" | awk 'NF && !seen[$0]++'
}

current_temp() { vcgencmd measure_temp 2>/dev/null | sed -n 's/.*=\([0-9.]*\).*/\1/p'; }
permanent_throttle() { vcgencmd get_throttled 2>/dev/null || true; }
recent_throttle() { vcgencmd get_throttled 0x10000 2>/dev/null || true; }
current_throttle() { recent_throttle; }
clock_mhz() { vcgencmd measure_clock "$1" 2>/dev/null | awk -F= '{printf "%d", $2/1000000}'; }

throttle_word() {
    local reading=${1-} hex_value
    [[ $reading =~ ^throttled=0x([0-9A-Fa-f]+)$ ]] || return 1
    hex_value=${BASH_REMATCH[1]}
    printf '%u' "$((16#$hex_value))"
}

throttle_clean_relative() {
    local current_word baseline_word
    current_word=$(throttle_word "${1-}") || return 1
    baseline_word=$(throttle_word "${2-}") || return 1
    (( (current_word & 0xffff) == 0 && (current_word & ~baseline_word) == 0 ))
}

reset_recent_throttle() {
    local reset_output after_reset
    reset_output=$(vcgencmd get_throttled 0x0f 2>/dev/null || true)
    throttle_word "$reset_output" >/dev/null || return 1
    after_reset=$(recent_throttle)
    throttle_clean_relative "$after_reset" throttled=0x0 || return 1
    printf '%s\n' "$reset_output"
}

render_clock_config() {
    local source_file=$1 destination_file=$2 cpu_mhz=$3 gpu_mhz=$4 gpu_key=$5 voltage_uv=$6 run_id=$7
    awk -v begin="$CLOCK_MARKER_BEGIN" -v end="$CLOCK_MARKER_END" '
        $0==begin {inside=1; next}
        $0==end {inside=0; next}
        !inside {print}
    ' "$source_file" > "$destination_file" || return 1
    printf '\n%s\n# Run: %s\n[all]\nover_voltage_delta=%s\narm_freq=%s\n%s=%s\n%s\n' \
        "$CLOCK_MARKER_BEGIN" "$run_id" "$voltage_uv" "$cpu_mhz" "$gpu_key" "$gpu_mhz" "$CLOCK_MARKER_END" >> "$destination_file"
}

render_tryboot_config() {
    local source_file=$1 destination_file=$2 cpu_mhz=$3 gpu_mhz=$4 gpu_key=$5 voltage_uv=$6 run_id=$7 ownership_token=$8
    render_tryboot_reservation "$run_id" "$ownership_token" > "$destination_file" || return 1
    awk -v begin="$CLOCK_MARKER_BEGIN" -v end="$CLOCK_MARKER_END" '
        $0==begin {inside=1; next}
        $0==end {inside=0; next}
        !inside {print}
    ' "$source_file" >> "$destination_file" || return 1
    printf '\n%s\n# Run: %s\n[all]\nover_voltage_delta=%s\narm_freq=%s\n%s=%s\n%s\n# AUTOPIOVERCLOCK TRYBOOT COMPLETE: %s\n' \
        "$CLOCK_MARKER_BEGIN" "$run_id" "$voltage_uv" "$cpu_mhz" "$gpu_key" "$gpu_mhz" "$CLOCK_MARKER_END" "$ownership_token" >> "$destination_file"
}

render_watchdog_config() {
    local source_file=$1 destination_file=$2 kernel_timeout=$3
    awk -v begin="$WATCHDOG_MARKER_BEGIN" -v end="$WATCHDOG_MARKER_END" '
        $0==begin {inside=1; next}
        $0==end {inside=0; next}
        !inside {print}
    ' "$source_file" > "$destination_file" || return 1
    printf '\n%s\n[all]\nkernel_watchdog_timeout=%s\n%s\n' "$WATCHDOG_MARKER_BEGIN" "$kernel_timeout" "$WATCHDOG_MARKER_END" >> "$destination_file"
}

display_hardware_present() {
    local drm_root=${1:-/sys/class/drm} status_file
    for status_file in "$drm_root"/card*-*/status; do
        [[ -r $status_file ]] || continue
        [[ ${status_file%/status} == *-Writeback-* ]] && continue
        [[ $(<"$status_file") == connected ]] && return 0
    done
    return 1
}

connected_display_baseline() {
    local drm_root=${1:-/sys/class/drm} connector_path connector_name preferred_mode
    for connector_path in "$drm_root"/card*-*; do
        [[ -r $connector_path/status ]] || continue
        [[ $connector_path == *-Writeback-* ]] && continue
        [[ $(<"$connector_path/status") == connected ]] || continue
        [[ $(cat "$connector_path/enabled" 2>/dev/null || true) == enabled ]] || continue
        preferred_mode=$(head -1 "$connector_path/modes" 2>/dev/null || true)
        [[ -n $preferred_mode ]] || continue
        connector_name=$(basename "$connector_path")
        printf 'connector=%s;mode=%s;enabled=enabled' "$connector_name" "$preferred_mode"
        return 0
    done
    return 1
}

audio_identity() {
    local identity='' inspect_output
    inspect_output=$(audio_inspect || true)
    [[ -n $inspect_output ]] || return 1
    identity=$(sed -n 's/^[[:space:]]*[*]*[[:space:]]*node\.name[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' <<< "$inspect_output" | head -1)
    [[ -n $identity ]] || identity=$(head -1 <<< "$inspect_output" | tr -d '\r\n')
    [[ -n $identity ]] || return 1
    printf '%s' "$identity"
}

audio_runtime_exec() {
    local runtime_dir=$1 runtime_uid runtime_user
    shift
    runtime_uid=${runtime_dir##*/}
    [[ $runtime_uid =~ ^[0-9]+$ ]] || return 1
    runtime_user=$(awk -F: -v wanted="$runtime_uid" '$3 == wanted {print $1; exit}' /etc/passwd 2>/dev/null || true)
    if [[ -n $runtime_user ]] && command -v runuser >/dev/null 2>&1; then
        runuser -u "$runtime_user" -- env XDG_RUNTIME_DIR="$runtime_dir" PIPEWIRE_RUNTIME_DIR="$runtime_dir" "$@"
    else
        env XDG_RUNTIME_DIR="$runtime_dir" PIPEWIRE_RUNTIME_DIR="$runtime_dir" "$@"
    fi
}

bounded_probe_timeout() {
    local maximum=${1:-6} remaining
    if [[ ${APPLICATION_READINESS_DEADLINE:-} =~ ^[0-9]+$ ]]; then
        remaining=$((APPLICATION_READINESS_DEADLINE - SECONDS))
        (( remaining > 0 )) || return 1
        (( remaining < maximum )) && maximum=$remaining
    fi
    printf '%s' "$maximum"
}

audio_inspect() {
    local runtime_dir output='' probe_timeout
    if command -v wpctl >/dev/null 2>&1; then
        for runtime_dir in /run/user/[0-9]*; do
            [[ -d $runtime_dir ]] || continue
            probe_timeout=$(bounded_probe_timeout 6) || return 1
            output=$(audio_runtime_exec "$runtime_dir" timeout "$probe_timeout" wpctl inspect @DEFAULT_AUDIO_SINK@ 2>/dev/null || true)
            [[ -n $output ]] && { printf '%s\n' "$output"; return 0; }
        done
        probe_timeout=$(bounded_probe_timeout 6) || return 1
        output=$(timeout "$probe_timeout" wpctl inspect @DEFAULT_AUDIO_SINK@ 2>/dev/null || true)
    elif command -v pactl >/dev/null 2>&1; then
        for runtime_dir in /run/user/[0-9]*; do
            [[ -d $runtime_dir ]] || continue
            probe_timeout=$(bounded_probe_timeout 6) || return 1
            output=$(audio_runtime_exec "$runtime_dir" timeout "$probe_timeout" pactl get-default-sink 2>/dev/null || true)
            [[ -n $output ]] && { printf '%s\n' "$output"; return 0; }
        done
        probe_timeout=$(bounded_probe_timeout 6) || return 1
        output=$(timeout "$probe_timeout" pactl get-default-sink 2>/dev/null || true)
    fi
    [[ -n $output ]] || return 1
    printf '%s\n' "$output"
}

watchdog_boot_timeout() {
    rpi-eeprom-config 2>/dev/null | awk -F= '
        $1 ~ /^[[:space:]]*BOOT_WATCHDOG_TIMEOUT[[:space:]]*$/ {
            value=$2
            gsub(/[[:space:]]/, "", value)
        }
        END {if(value != "") print value}
    '
}

watchdog_kernel_open_timeout() {
    local cmdline_file=${1:-/proc/cmdline}
    awk '
        {
            for (field = 1; field <= NF; field++) {
                if ($field ~ /^watchdog[.]open_timeout=/) {
                    value = $field
                    sub(/^watchdog[.]open_timeout=/, "", value)
                }
            }
        }
        END {if (value != "") print value}
    ' "$cmdline_file" 2>/dev/null
}

watchdog_device_path() {
    local candidate_device
    for candidate_device in /dev/watchdog0 /dev/watchdog; do
        [[ -c $candidate_device ]] || continue
        printf '%s' "$candidate_device"
        return 0
    done
    return 1
}

watchdog_runtime_timeout() {
    local device_path=$1 sys_root=${2:-/sys} canonical_device watchdog_name device_id major_hex minor_hex timeout_file timeout_value
    canonical_device=$(readlink -f "$device_path" 2>/dev/null || printf '%s' "$device_path")
    watchdog_name=${canonical_device##*/}
    if [[ ! $watchdog_name =~ ^watchdog[0-9]+$ ]]; then
        device_id=$(stat -Lc '%t:%T' "$device_path" 2>/dev/null || true)
        [[ $device_id == *:* ]] || return 1
        major_hex=${device_id%:*}
        minor_hex=${device_id#*:}
        [[ $major_hex =~ ^[0-9a-fA-F]+$ && $minor_hex =~ ^[0-9a-fA-F]+$ ]] || return 1
        watchdog_name=$(basename "$(readlink -f "$sys_root/dev/char/$((16#$major_hex)):$((16#$minor_hex))" 2>/dev/null || true)")
    fi
    [[ $watchdog_name =~ ^watchdog[0-9]+$ ]] || return 1
    timeout_file="$sys_root/class/watchdog/$watchdog_name/timeout"
    [[ -r $timeout_file ]] || return 1
    timeout_value=$(tr -d '[:space:]' < "$timeout_file" 2>/dev/null || true)
    [[ $timeout_value =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$timeout_value"
}

watchdog_userspace_owner() {
    local device_path=$1 proc_root=${2:-/proc} canonical_device device_id fd_path fd_target fd_id pid owner_name
    canonical_device=$(readlink -f "$device_path" 2>/dev/null || printf '%s' "$device_path")
    device_id=$(stat -Lc '%t:%T' "$device_path" 2>/dev/null || true)
    for fd_path in "$proc_root"/[0-9]*/fd/*; do
        [[ -L $fd_path ]] || continue
        fd_target=$(readlink -f "$fd_path" 2>/dev/null || true)
        if [[ $fd_target != "$canonical_device" ]]; then
            [[ -c $fd_target && -n $device_id ]] || continue
            fd_id=$(stat -Lc '%t:%T' "$fd_target" 2>/dev/null || true)
            [[ -n $fd_id && $fd_id == "$device_id" ]] || continue
        fi
        pid=${fd_path#"$proc_root"/}
        pid=${pid%%/*}
        owner_name=$(tr '\t ' '__' < "$proc_root/$pid/comm" 2>/dev/null | tr -d '\r\n' || true)
        printf 'pid=%s;comm=%s;fd=%s' "$pid" "${owner_name:-unknown}" "${fd_path##*/}"
        return 0
    done
    return 1
}

WATCHDOG_LAST_BOOT_TIMEOUT=''
WATCHDOG_LAST_KERNEL_TIMEOUT=''
WATCHDOG_LAST_DEVICE=''
WATCHDOG_LAST_RUNTIME_TIMEOUT=''
WATCHDOG_LAST_OWNER=''
WATCHDOG_LAST_REASON=''

watchdog_health_ready() {
    local _boot_config=${1-}
    WATCHDOG_LAST_BOOT_TIMEOUT=$(watchdog_boot_timeout || true)
    WATCHDOG_LAST_KERNEL_TIMEOUT=$(watchdog_kernel_open_timeout || true)
    WATCHDOG_LAST_DEVICE=$(watchdog_device_path || true)
    WATCHDOG_LAST_RUNTIME_TIMEOUT=''
    WATCHDOG_LAST_OWNER=''
    WATCHDOG_LAST_REASON=''
    [[ $WATCHDOG_LAST_BOOT_TIMEOUT =~ ^[0-9]+$ ]] && (( WATCHDOG_LAST_BOOT_TIMEOUT > 0 )) || {
        WATCHDOG_LAST_REASON="EEPROM BOOT_WATCHDOG_TIMEOUT is not enabled (${WATCHDOG_LAST_BOOT_TIMEOUT:-missing})."
        return 1
    }
    [[ $WATCHDOG_LAST_KERNEL_TIMEOUT =~ ^[0-9]+$ ]] && (( WATCHDOG_LAST_KERNEL_TIMEOUT > 0 )) || {
        WATCHDOG_LAST_REASON="The active kernel command line does not contain a positive watchdog.open_timeout (${WATCHDOG_LAST_KERNEL_TIMEOUT:-missing})."
        return 1
    }
    [[ -n $WATCHDOG_LAST_DEVICE ]] || {
        WATCHDOG_LAST_REASON='No watchdog character device is present.'
        return 1
    }
    WATCHDOG_LAST_RUNTIME_TIMEOUT=$(watchdog_runtime_timeout "$WATCHDOG_LAST_DEVICE" || true)
    [[ $WATCHDOG_LAST_RUNTIME_TIMEOUT =~ ^[0-9]+$ ]] && (( WATCHDOG_LAST_RUNTIME_TIMEOUT > 0 )) || {
        WATCHDOG_LAST_REASON="The active watchdog device has no positive runtime timeout (${WATCHDOG_LAST_RUNTIME_TIMEOUT:-missing})."
        return 1
    }
    WATCHDOG_LAST_OWNER=$(watchdog_userspace_owner "$WATCHDOG_LAST_DEVICE" || true)
    [[ -n $WATCHDOG_LAST_OWNER ]] || {
        WATCHDOG_LAST_REASON="No userspace process owns $WATCHDOG_LAST_DEVICE."
        return 1
    }
}

stress_ng_has_gpu() {
    command -v stress-ng >/dev/null 2>&1 &&
        stress-ng --help 2>&1 |
            grep -E -- '(^|[[:space:]])--gpu([[:space:]]|$)' >/dev/null
}

cmd_discover() {
    local boot_config tryboot_config boot_mount model compatible os_id os_version gpu_key normal_cpu normal_gpu normal_voltage normal_voltage_source
    local boot_watchdog kernel_watchdog runtime_watchdog watchdog_device watchdog_runtime_timeout_value watchdog_owner root_device boot_source display_baseline display_present audio_baseline permanent_hash
    local stress_ng_binary stress_ng_gpu_available render_node tryboot_exists tryboot_type tryboot_hash
    boot_config=$(find_boot_config) || { emit_result PREFLIGHT_FAILURE 'Raspberry Pi boot config was not found.'; return 1; }
    audit_permanent_tuning_config "$boot_config"
    tryboot_config="$(dirname "$boot_config")/tryboot.txt"
    boot_mount=$(dirname "$boot_config")
    inspect_tryboot_path "$tryboot_config" tryboot_exists tryboot_type tryboot_hash
    model=$(tr -d '\000' < /proc/device-tree/model 2>/dev/null || true)
    compatible=$(tr '\000' ',' < /proc/device-tree/compatible 2>/dev/null || true)
    os_id=$(sed -n 's/^ID=//p' /etc/os-release 2>/dev/null | tr -d '"' | head -1)
    os_version=$(sed -n 's/^VERSION_ID=//p' /etc/os-release 2>/dev/null | tr -d '"' | head -1)
    gpu_key=v3d_freq
    normal_cpu=$(discovered_config_value arm_freq "$boot_config")
    [[ $normal_cpu =~ ^[0-9]+$ ]] || { emit_result PREFLIGHT_FAILURE 'The permanent/active CPU clock could not be discovered; no default clock will be assumed.'; return 1; }
    normal_gpu=$(discovered_config_value "$gpu_key" "$boot_config")
    [[ $normal_gpu =~ ^[0-9]+$ ]] || { emit_result PREFLIGHT_FAILURE "The permanent/active $gpu_key clock could not be discovered; no default clock will be assumed."; return 1; }
    normal_voltage=$(active_config_value over_voltage_delta)
    if [[ -n $normal_voltage ]]; then
        normal_voltage_source=active-firmware
    elif active_config_interface_ready; then
        normal_voltage=0
        normal_voltage_source=verified-implicit-zero
    else
        emit_result PREFLIGHT_FAILURE 'The active firmware configuration interface is unavailable, so the voltage delta cannot be established.'
        return 1
    fi
    [[ $normal_voltage =~ ^-?[0-9]+$ ]] || { emit_result PREFLIGHT_FAILURE 'The permanent/active voltage delta is malformed.'; return 1; }
    boot_watchdog=$(watchdog_boot_timeout || true)
    kernel_watchdog=$(watchdog_kernel_open_timeout || true)
    runtime_watchdog=$(systemctl show --property=RuntimeWatchdogUSec --value 2>/dev/null || true)
    watchdog_device=$(watchdog_device_path || true)
    watchdog_runtime_timeout_value=$([[ -n $watchdog_device ]] && watchdog_runtime_timeout "$watchdog_device" || true)
    watchdog_owner=$([[ -n $watchdog_device ]] && watchdog_userspace_owner "$watchdog_device" || true)
    root_device=$(root_source)
    boot_source=$(findmnt -n -o SOURCE "$boot_mount" 2>/dev/null || true)
    display_baseline=$(connected_display_baseline || true)
    display_present=$(display_hardware_present && printf 1 || printf 0)
    audio_baseline=$(audio_identity || true)
    permanent_hash=$(permanent_config_snapshot_hash "$boot_config" || true)
    if [[ -n $PERMANENT_TUNING_CONFIG_HASH && $permanent_hash != "$PERMANENT_TUNING_CONFIG_HASH" ]]; then
        PERMANENT_TUNING_PROVENANCE=ambiguous
        PERMANENT_TUNING_EVIDENCE='permanent-config-changed-after-audit'
    fi
    stress_ng_binary=$(command -v stress-ng 2>/dev/null || true)
    stress_ng_gpu_available=$([[ -n $stress_ng_binary ]] && stress_ng_has_gpu && printf 1 || printf 0)
    render_node=$([[ -e /dev/dri/renderD128 ]] && printf /dev/dri/renderD128 || true)

    emit_data PROFILE debian
    emit_data MODEL "$model"
    emit_data COMPATIBLE "$compatible"
    emit_data ARCH "$(uname -m)"
    emit_data OS_ID "$os_id"
    emit_data OS_VERSION "$os_version"
    emit_data BOOT_CONFIG "$boot_config"
    emit_data TRYBOOT_CONFIG "$tryboot_config"
    emit_data TRYBOOT_EXISTS "$tryboot_exists"
    emit_data TRYBOOT_TYPE "$tryboot_type"
    emit_data TRYBOOT_HASH "$tryboot_hash"
    emit_data BOOT_MOUNT "$boot_mount"
    emit_data GPU_KEY "$gpu_key"
    emit_data NORMAL_CPU "$normal_cpu"
    emit_data NORMAL_GPU "$normal_gpu"
    emit_data NORMAL_VOLTAGE "$normal_voltage"
    emit_data NORMAL_VOLTAGE_SOURCE "$normal_voltage_source"
    emit_data PERMANENT_TUNING_PROVENANCE "$PERMANENT_TUNING_PROVENANCE"
    emit_data PERMANENT_TUNING_EVIDENCE "$PERMANENT_TUNING_EVIDENCE"
    emit_data THROTTLED "$(permanent_throttle)"
    emit_data RECENT_THROTTLED "$(recent_throttle)"
    emit_data THROTTLE_RECENT_SUPPORTED "$(throttle_word "$(recent_throttle)" >/dev/null 2>&1 && printf 1 || printf 0)"
    emit_data TEMP "$(current_temp)"
    emit_data BOOT_WATCHDOG_TIMEOUT "$boot_watchdog"
    emit_data KERNEL_WATCHDOG_TIMEOUT "$kernel_watchdog"
    emit_data RUNTIME_WATCHDOG "$runtime_watchdog"
    emit_data WATCHDOG_DEVICE "$watchdog_device"
    emit_data WATCHDOG_RUNTIME_TIMEOUT "$watchdog_runtime_timeout_value"
    emit_data WATCHDOG_OWNER "$watchdog_owner"
    emit_data ROOT_SOURCE "$root_device"
    emit_data BOOT_SOURCE "$boot_source"
    emit_data DISPLAY_BASELINE "$display_baseline"
    emit_data DISPLAY_PRESENT "$display_present"
    emit_data AUDIO_BASELINE "$audio_baseline"
    emit_data DISPLAY_CONNECTED "$([[ -n $display_baseline ]] && printf 1 || printf 0)"
    emit_data CPU_STRESS_AVAILABLE "$([[ -n $stress_ng_binary ]] && printf 1 || printf 0)"
    emit_data GPU_STRESS_AVAILABLE "$([[ $stress_ng_gpu_available == 1 && -n $render_node ]] && printf 1 || printf 0)"
    emit_data STRESS_NG_BINARY "$stress_ng_binary"
    emit_data STRESS_NG_GPU_AVAILABLE "$stress_ng_gpu_available"
    emit_data DRM_RENDER_NODE "$render_node"
    emit_data PERMANENT_HASH "$permanent_hash"
    emit_data STORAGE_LAYOUT "root=${root_device};boot=${boot_source}"
    emit_result PASS 'Discovery completed.'
}

check_display() {
    local baseline=$1 connector_name connector_location expected_mode actual_mode
    connector_name=$(sed -n 's/.*connector=\([^;]*\).*/\1/p' <<< "$baseline")
    expected_mode=$(sed -n 's/.*mode=\([^;]*\).*/\1/p' <<< "$baseline")
    [[ -n $connector_name ]] || return 1
    connector_location="/sys/class/drm/${connector_name}"
    [[ -r $connector_location/status && $(<"$connector_location/status") == connected ]] || return 1
    [[ $(cat "$connector_location/enabled" 2>/dev/null || true) == enabled ]] || return 1
    actual_mode=$(head -1 "$connector_location/modes" 2>/dev/null || true)
    [[ -z $expected_mode || $actual_mode == "$expected_mode" ]]
}

wait_display_baseline() {
    local baseline=$1 elapsed=0
    while (( elapsed < 60 )); do
        check_display "$baseline" && return 0
        sleep 5
        elapsed=$((elapsed + 5))
    done
    return 1
}

check_required_processes() {
    local csv_value=$1 process_name probe_timeout
    local -a required=()
    IFS=',' read -r -a required <<< "$csv_value"
    for process_name in "${required[@]}"; do
        [[ -n $process_name ]] || continue
        probe_timeout=$(bounded_probe_timeout 6) || return 1
        timeout "$probe_timeout" pidof "$process_name" >/dev/null 2>&1 || return 1
    done
}

check_required_services() {
    local csv_value=$1 service_name probe_timeout
    local -a required=()
    IFS=',' read -r -a required <<< "$csv_value"
    for service_name in "${required[@]}"; do
        [[ -n $service_name ]] || continue
        probe_timeout=$(bounded_probe_timeout 6) || return 1
        timeout "$probe_timeout" systemctl is-active --quiet "$service_name" || return 1
    done
}

application_health_ready() {
    local mode=$1 baseline=$2 required_processes=$3 required_services=$4 audio_match=$5 audio_baseline=$6
    local current_audio current_audio_inspect
    APPLICATION_READINESS_LAST_FAILURE=''
    APPLICATION_READINESS_LAST_AUDIO=''
    check_required_processes "$required_processes" || { APPLICATION_READINESS_LAST_FAILURE=process; return 1; }
    check_required_services "$required_services" || { APPLICATION_READINESS_LAST_FAILURE=service; return 1; }
    if [[ -n $audio_match ]]; then
        current_audio_inspect=$(audio_inspect || true)
        if [[ -z $current_audio_inspect ]]; then
            APPLICATION_READINESS_LAST_FAILURE=audio-inspection
            return 1
        fi
        if ! grep -Fq -- "$audio_match" <<< "$current_audio_inspect"; then
            APPLICATION_READINESS_LAST_FAILURE=audio-match
            return 1
        fi
    fi
    if [[ $mode == graphical ]]; then
        if [[ -n $audio_baseline ]]; then
            current_audio=$(audio_identity || true)
            APPLICATION_READINESS_LAST_AUDIO=$current_audio
            if [[ -z $current_audio ]]; then
                APPLICATION_READINESS_LAST_FAILURE=audio-unavailable
                return 1
            fi
            if [[ $current_audio != "$audio_baseline" ]]; then
                APPLICATION_READINESS_LAST_FAILURE=audio-changed
                return 1
            fi
        fi
        check_display "$baseline" || { APPLICATION_READINESS_LAST_FAILURE=display; return 1; }
    fi
    return 0
}

wait_application_health() {
    local mode=$1 baseline=$2 required_processes=$3 required_services=$4 audio_match=$5 audio_baseline=$6
    local deadline=$((SECONDS + 60)) previous_deadline=${APPLICATION_READINESS_DEADLINE:-} remaining sleep_for result=1
    APPLICATION_READINESS_DEADLINE=$deadline
    while (( SECONDS <= deadline )); do
        if application_health_ready "$mode" "$baseline" "$required_processes" "$required_services" "$audio_match" "$audio_baseline"; then
            (( SECONDS <= deadline )) && result=0
            break
        fi
        remaining=$((deadline - SECONDS))
        (( remaining > 0 )) || break
        sleep_for=5
        (( remaining < sleep_for )) && sleep_for=$remaining
        sleep "$sleep_for"
    done
    if [[ -n $previous_deadline ]]; then APPLICATION_READINESS_DEADLINE=$previous_deadline; else unset APPLICATION_READINESS_DEADLINE; fi
    return "$result"
}

emit_application_health_failure() {
    local context=$1 temp=$2 audio_baseline=$3
    case ${APPLICATION_READINESS_LAST_FAILURE:-} in
        process) emit_result BOOT_FAILURE "A required process is missing in $context." "$temp" ;;
        service) emit_result BOOT_FAILURE "A required service is not active in $context." "$temp" ;;
        audio-inspection) emit_result HARNESS_FAILURE 'AUDIO_SINK_MATCH was configured but default-sink inspection is unavailable.' "$temp" ;;
        audio-match) emit_result BOOT_FAILURE "Default audio sink does not match the configured requirement in $context." "$temp" ;;
        audio-unavailable) emit_result BOOT_FAILURE "The default audio sink is unavailable in $context." "$temp" ;;
        audio-changed) emit_result BOOT_FAILURE "The default audio sink changed in $context: expected $audio_baseline, found ${APPLICATION_READINESS_LAST_AUDIO:-missing}." "$temp" ;;
        display) emit_result BOOT_FAILURE "Graphical baseline did not recover within 60 seconds in $context." "$temp" ;;
        *) emit_result BOOT_FAILURE "Application readiness did not recover within 60 seconds in $context." "$temp" ;;
    esac
}

cmd_health() {
    local expected_cpu=$1 expected_gpu=$2 gpu_key=$3 expected_voltage=$4 max_temp=$5 mode=$6 baseline=$7
    local required_processes=$8 required_services=$9 audio_match=${10} extra_ping=${11} health_hook=${12} expected_hash=${13} context=${14} throttle_baseline=${15:-throttled=0x0} audio_baseline=${16:-}
    local boot_config active_cpu active_gpu active_voltage throttle temp errors permanent_hash test_file
    boot_config=$(find_boot_config) || { emit_result PREFLIGHT_FAILURE 'Boot config is missing.'; return 1; }
    permanent_hash=$(sha256sum "$boot_config" | awk '{print $1}')
    [[ -z $expected_hash || $permanent_hash == "$expected_hash" ]] || { emit_result RECOVERY_FAILURE "Permanent config hash changed during $context."; return 1; }
    active_cpu=$(active_config_value arm_freq)
    active_gpu=$(active_config_value "$gpu_key")
    active_voltage=$(active_config_value over_voltage_delta)
    [[ -n $active_voltage ]] || { active_config_interface_ready && active_voltage=0; }
    [[ -n $active_cpu && -n $active_gpu && -n $active_voltage ]] || { emit_result HARNESS_FAILURE "Active CPU/GPU/voltage configuration telemetry is unavailable in $context."; return 1; }
    [[ $active_cpu == "$expected_cpu" ]] || { emit_result BOOT_FAILURE "CPU config mismatch in $context: expected $expected_cpu, found ${active_cpu:-missing}."; return 1; }
    [[ $active_gpu == "$expected_gpu" ]] || { emit_result BOOT_FAILURE "GPU config mismatch in $context: expected $expected_gpu, found ${active_gpu:-missing}."; return 1; }
    [[ $active_voltage == "$expected_voltage" ]] || { emit_result BOOT_FAILURE "Voltage delta mismatch in $context: expected $expected_voltage, found $active_voltage."; return 1; }
    watchdog_health_ready "$boot_config" || { emit_result BOOT_FAILURE "Watchdog recovery chain failed in $context: $WATCHDOG_LAST_REASON"; return 1; }
    throttle=$(current_throttle)
    throttle_word "$throttle" >/dev/null || { emit_result HARNESS_FAILURE "Malformed throttle telemetry in $context: ${throttle:-missing}"; return 1; }
    throttle_clean_relative "$throttle" "$throttle_baseline" || { printf '%s\n' "$throttle"; emit_result STABILITY_FAILURE "Current or new throttle/power flag in $context: $throttle (baseline $throttle_baseline)"; return 1; }
    temp=$(current_temp)
    [[ -n $temp ]] || { emit_result HARNESS_FAILURE "Temperature unavailable in $context."; return 1; }
    awk -v t="$temp" -v m="$max_temp" 'BEGIN{exit !(t<m)}' || { emit_result STABILITY_FAILURE "Temperature ${temp}C reached the ${max_temp}C ceiling in $context." "$temp"; return 1; }
    errors=$(kernel_error_lines 1 | tail -40 || true)
    if [[ -n $errors ]]; then printf '%s\n' "$errors"; emit_result STABILITY_FAILURE "Current-boot kernel, power, GPU, USB, storage, or filesystem error in $context." "$temp"; return 1; fi
    test_file=/var/tmp/autopioverclock-write-test-$$
    printf test > "$test_file" && sync "$test_file" && rm -f "$test_file" || { emit_result STABILITY_FAILURE "Filesystem write test failed in $context." "$temp"; return 1; }
    if [[ -n $extra_ping ]]; then ping -c 2 -W 2 "$extra_ping" >/dev/null 2>&1 || { emit_result BOOT_FAILURE "Configured ping target is unreachable in $context." "$temp"; return 1; }; fi
    if ! wait_application_health "$mode" "$baseline" "$required_processes" "$required_services" "$audio_match" "$audio_baseline"; then
        emit_application_health_failure "$context" "$temp" "$audio_baseline"
        return 1
    fi
    permanent_hash=$(sha256sum "$boot_config" | awk '{print $1}')
    [[ -z $expected_hash || $permanent_hash == "$expected_hash" ]] || { emit_result RECOVERY_FAILURE "Permanent config hash changed while application readiness was settling in $context."; return 1; }
    active_cpu=$(active_config_value arm_freq)
    active_gpu=$(active_config_value "$gpu_key")
    active_voltage=$(active_config_value over_voltage_delta)
    [[ -n $active_voltage ]] || { active_config_interface_ready && active_voltage=0; }
    [[ -n $active_cpu && -n $active_gpu && -n $active_voltage ]] || { emit_result HARNESS_FAILURE "Active CPU/GPU/voltage telemetry became unavailable after application readiness in $context."; return 1; }
    [[ $active_cpu == "$expected_cpu" && $active_gpu == "$expected_gpu" && $active_voltage == "$expected_voltage" ]] || { emit_result BOOT_FAILURE "Active clocks or voltage changed while application readiness was settling in $context."; return 1; }
    watchdog_health_ready "$boot_config" || { emit_result BOOT_FAILURE "Watchdog recovery chain failed after application readiness in $context: $WATCHDOG_LAST_REASON"; return 1; }
    throttle=$(current_throttle)
    throttle_word "$throttle" >/dev/null || { emit_result HARNESS_FAILURE "Malformed throttle telemetry after application readiness in $context: ${throttle:-missing}"; return 1; }
    throttle_clean_relative "$throttle" "$throttle_baseline" || { printf '%s\n' "$throttle"; emit_result STABILITY_FAILURE "Current or new throttle/power flag appeared while application readiness was settling in $context: $throttle (baseline $throttle_baseline)"; return 1; }
    temp=$(current_temp)
    [[ -n $temp ]] || { emit_result HARNESS_FAILURE "Temperature unavailable after application readiness in $context."; return 1; }
    awk -v t="$temp" -v m="$max_temp" 'BEGIN{exit !(t<m)}' || { emit_result STABILITY_FAILURE "Temperature ${temp}C reached the ${max_temp}C ceiling while application readiness was settling in $context." "$temp"; return 1; }
    errors=$(kernel_error_lines 1 | tail -40 || true)
    if [[ -n $errors ]]; then printf '%s\n' "$errors"; emit_result STABILITY_FAILURE "A kernel, power, GPU, USB, storage, or filesystem error appeared while application readiness was settling in $context." "$temp"; return 1; fi
    if [[ -n $health_hook ]]; then
        [[ -x $health_hook ]] || { emit_result HARNESS_FAILURE "Health hook is not executable: $health_hook" "$temp"; return 1; }
        command -v timeout >/dev/null 2>&1 || { emit_result HARNESS_FAILURE 'A health hook was configured but timeout is unavailable.' "$temp"; return 1; }
        timeout 60 "$health_hook" || { emit_result BOOT_FAILURE "Health hook failed or exceeded 60 seconds in $context." "$temp"; return 1; }
    fi
    printf 'ACTIVE_CPU=%s\nACTIVE_GPU=%s\nACTIVE_VOLTAGE=%s\n%s\n' "$active_cpu" "$active_gpu" "$active_voltage" "$throttle"
    printf 'WATCHDOG_EEPROM=%s WATCHDOG_KERNEL=%s WATCHDOG_DEVICE=%s WATCHDOG_RUNTIME_TIMEOUT=%s WATCHDOG_OWNER=%s\n' \
        "$WATCHDOG_LAST_BOOT_TIMEOUT" "$WATCHDOG_LAST_KERNEL_TIMEOUT" "$WATCHDOG_LAST_DEVICE" "$WATCHDOG_LAST_RUNTIME_TIMEOUT" "$WATCHDOG_LAST_OWNER"
    vcgencmd measure_clock arm 2>/dev/null || true
    vcgencmd measure_clock v3d 2>/dev/null || true
    vcgencmd pmic_read_adc EXT5V_V 2>/dev/null || true
    emit_result PASS "Health passed in $context." "$temp"
}

cmd_plan_candidate() {
    local boot_config=$1 tryboot_config=$2 gpu_key=$3 cpu_mhz=$4 gpu_mhz=$5 voltage_uv=$6 expected_hash=$7 run_id=$8 ownership_token=$9
    local current_hash temporary_file rendered_hash reservation_file reservation_hash quarantine_path
    tryboot_path_allowed "$boot_config" "$tryboot_config" || { emit_result RECOVERY_FAILURE 'The requested tryboot path is outside the permitted boot-config directory.'; return 1; }
    [[ $ownership_token =~ ^[0-9a-f]{64}$ ]] || { emit_result HARNESS_FAILURE 'Candidate planning lacks a valid random ownership token.'; return 1; }
    quarantine_path=$(tryboot_quarantine_path "$tryboot_config" "$ownership_token")
    [[ ! -e $quarantine_path && ! -L $quarantine_path ]] || { emit_result RECOVERY_FAILURE 'The token-specific tryboot quarantine path is already occupied.'; return 1; }
    current_hash=$(sha256sum "$boot_config" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    [[ $current_hash == "$expected_hash" ]] || { emit_result RECOVERY_FAILURE 'Permanent config hash changed before candidate planning.'; return 1; }
    temporary_file=$(mktemp /tmp/autopioverclock-plan.XXXXXX) || { emit_result HARNESS_FAILURE 'Could not create candidate-plan temporary file.'; return 1; }
    reservation_file=$(mktemp /tmp/autopioverclock-reservation.XXXXXX) || { rm -f -- "$temporary_file"; emit_result HARNESS_FAILURE 'Could not create reservation-plan temporary file.'; return 1; }
    if ! render_tryboot_config "$boot_config" "$temporary_file" "$cpu_mhz" "$gpu_mhz" "$gpu_key" "$voltage_uv" "$run_id" "$ownership_token" \
        || ! rendered_hash=$(sha256sum "$temporary_file" 2>/dev/null | awk 'NR == 1 {print $1}') \
        || [[ ! $rendered_hash =~ ^[0-9a-f]{64}$ ]] \
        || ! render_tryboot_reservation "$run_id" "$ownership_token" > "$reservation_file" \
        || ! reservation_hash=$(sha256sum "$reservation_file" 2>/dev/null | awk 'NR == 1 {print $1}') \
        || [[ ! $reservation_hash =~ ^[0-9a-f]{64}$ ]]; then
        rm -f -- "$temporary_file" "$reservation_file"
        emit_result HARNESS_FAILURE 'Could not render and hash the candidate ownership plan.'
        return 1
    fi
    rm -f -- "$temporary_file" "$reservation_file"
    current_hash=$(sha256sum "$boot_config" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    [[ $current_hash == "$expected_hash" ]] || { emit_result RECOVERY_FAILURE 'Permanent config hash changed during candidate planning.'; return 1; }
    emit_data TRYBOOT_HASH "$rendered_hash"
    emit_data TRYBOOT_RESERVATION_HASH "$reservation_hash"
    emit_data TRYBOOT_QUARANTINE "$quarantine_path"
    emit_result PASS 'Candidate ownership plan prepared without changing the boot filesystem.'
}

cmd_prepare_candidate() {
    local boot_config=$1 tryboot_config=$2 gpu_key=$3 cpu_mhz=$4 gpu_mhz=$5 voltage_uv=$6 expected_hash=$7 run_id=$8
    local expected_tryboot_hash=$9 expected_reservation_hash=${10} ownership_token=${11} quarantine_path=${12}
    local current_hash temporary_file rendered_hash installed_hash installed_path_hash reservation_hash tryboot_exists tryboot_type tryboot_hash tryboot_fd
    tryboot_path_allowed "$boot_config" "$tryboot_config" || { emit_result RECOVERY_FAILURE 'The requested tryboot path is outside the permitted boot-config directory.'; return 1; }
    [[ $expected_tryboot_hash =~ ^[0-9a-f]{64}$ && $expected_reservation_hash =~ ^[0-9a-f]{64}$ && $ownership_token =~ ^[0-9a-f]{64}$ ]] || { emit_result HARNESS_FAILURE 'Candidate preparation lacks valid ownership evidence.'; return 1; }
    [[ $quarantine_path == "$(tryboot_quarantine_path "$tryboot_config" "$ownership_token")" && ! -e $quarantine_path && ! -L $quarantine_path ]] || { emit_result RECOVERY_FAILURE 'The tryboot quarantine path is invalid or occupied.'; return 1; }
    inspect_tryboot_path "$tryboot_config" tryboot_exists tryboot_type tryboot_hash
    [[ $tryboot_exists == 0 ]] || { emit_result RECOVERY_FAILURE "The tryboot path became occupied ($tryboot_type, hash $tryboot_hash); refusing to overwrite it."; return 1; }
    reset_recent_throttle >/dev/null || { emit_result HARNESS_FAILURE 'Could not clear and verify recent throttle history before candidate boot.'; return 1; }
    current_hash=$(sha256sum "$boot_config" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    [[ $current_hash == "$expected_hash" ]] || { emit_result RECOVERY_FAILURE 'Permanent config hash changed before candidate preparation.'; return 1; }
    temporary_file=$(mktemp /tmp/autopioverclock-tryboot.XXXXXX) || { emit_result HARNESS_FAILURE 'Could not create tryboot temporary file.'; return 1; }
    render_tryboot_config "$boot_config" "$temporary_file" "$cpu_mhz" "$gpu_mhz" "$gpu_key" "$voltage_uv" "$run_id" "$ownership_token" || { rm -f -- "$temporary_file"; emit_result HARNESS_FAILURE 'Could not render tryboot config.'; return 1; }
    rendered_hash=$(sha256sum "$temporary_file" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    [[ $rendered_hash == "$expected_tryboot_hash" ]] || { rm -f -- "$temporary_file"; emit_result RECOVERY_FAILURE 'Rendered tryboot config does not match the persisted ownership plan.'; return 1; }
    sync "$temporary_file" || { rm -f -- "$temporary_file"; emit_result HARNESS_FAILURE 'Could not durably stage rendered tryboot config.'; return 1; }
    set -o noclobber
    if ! exec {tryboot_fd}> "$tryboot_config" 2>/dev/null; then
        set +o noclobber
        rm -f -- "$temporary_file"
        inspect_tryboot_path "$tryboot_config" tryboot_exists tryboot_type tryboot_hash
        emit_result RECOVERY_FAILURE "The tryboot path became occupied ($tryboot_type, hash $tryboot_hash); refusing to overwrite it."
        return 1
    fi
    set +o noclobber
    if ! render_tryboot_reservation "$run_id" "$ownership_token" >&"$tryboot_fd" \
        || ! sync "/proc/self/fd/$tryboot_fd"; then
        exec {tryboot_fd}>&-
        rm -f -- "$temporary_file"
        emit_result RECOVERY_FAILURE 'Could not durably write the owned tryboot header.'
        return 1
    fi
    reservation_hash=$(sha256sum "/proc/self/fd/$tryboot_fd" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    if [[ $reservation_hash != "$expected_reservation_hash" || ! $tryboot_config -ef /proc/self/fd/$tryboot_fd ]]; then
        exec {tryboot_fd}>&-
        rm -f -- "$temporary_file"
        emit_result RECOVERY_FAILURE 'The owned tryboot header was replaced before candidate installation.'
        return 1
    fi
    if ! tail -n +4 "$temporary_file" >&"$tryboot_fd" \
        || { ! chmod --reference="$boot_config" "/proc/self/fd/$tryboot_fd" 2>/dev/null && ! chmod 644 "/proc/self/fd/$tryboot_fd"; } \
        || ! sync "/proc/self/fd/$tryboot_fd"; then
        exec {tryboot_fd}>&-
        rm -f -- "$temporary_file"
        emit_result RECOVERY_FAILURE 'Could not durably complete the owned tryboot config.'
        return 1
    fi
    installed_hash=$(sha256sum "/proc/self/fd/$tryboot_fd" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    installed_path_hash=$(sha256sum "$tryboot_config" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    if [[ $installed_hash != "$expected_tryboot_hash" || $installed_path_hash != "$expected_tryboot_hash" || ! $tryboot_config -ef /proc/self/fd/$tryboot_fd ]]; then
        exec {tryboot_fd}>&-
        rm -f -- "$temporary_file"
        emit_result RECOVERY_FAILURE 'Installed tryboot config failed final path/ownership verification.'
        return 1
    fi
    exec {tryboot_fd}>&-
    rm -f -- "$temporary_file"
    current_hash=$(sha256sum "$boot_config" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    [[ $current_hash == "$expected_hash" ]] || { emit_result RECOVERY_FAILURE 'Permanent config hash changed during candidate preparation.'; return 1; }
    emit_data TRYBOOT_HASH "$installed_hash"
    emit_result PASS 'Candidate tryboot config prepared.'
}

cmd_clear_tryboot() {
    local boot_config=$1 tryboot_config=$2 quarantine_path=$3 expected_permanent_hash=$4 expected_tryboot_hash=$5 expected_reservation_hash=$6 run_id=$7 ownership_token=$8
    local permanent_hash tryboot_exists tryboot_type tryboot_hash quarantine_exists quarantine_type quarantine_hash ownership_kind='' moved_kind=''
    tryboot_path_allowed "$boot_config" "$tryboot_config" || { emit_result RECOVERY_FAILURE 'The requested tryboot cleanup path is outside the permitted boot-config directory.'; return 1; }
    [[ $expected_tryboot_hash =~ ^[0-9a-f]{64}$ && $expected_reservation_hash =~ ^[0-9a-f]{64}$ && $ownership_token =~ ^[0-9a-f]{64}$ ]] || { emit_result RECOVERY_FAILURE 'Tryboot cleanup lacks valid persisted ownership evidence.'; return 1; }
    [[ $quarantine_path == "$(tryboot_quarantine_path "$tryboot_config" "$ownership_token")" ]] || { emit_result RECOVERY_FAILURE 'Saved tryboot quarantine path is invalid.'; return 1; }
    permanent_hash=$(sha256sum "$boot_config" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    [[ $permanent_hash == "$expected_permanent_hash" ]] || { emit_result RECOVERY_FAILURE 'Permanent config hash changed before tryboot cleanup.'; return 1; }
    inspect_tryboot_path "$tryboot_config" tryboot_exists tryboot_type tryboot_hash
    inspect_tryboot_path "$quarantine_path" quarantine_exists quarantine_type quarantine_hash
    if [[ $tryboot_exists == 0 && $quarantine_exists == 0 ]]; then
        emit_data TRYBOOT_CLEARED already-absent
        emit_result PASS 'Managed tryboot config and quarantine are already absent.'
        return 0
    fi
    [[ ! ( $tryboot_exists == 1 && $quarantine_exists == 1 ) ]] || { emit_result RECOVERY_FAILURE 'Both tryboot and its token quarantine exist; refusing ambiguous cleanup.'; return 1; }
    if [[ $tryboot_exists == 1 ]]; then
        ownership_kind=$(owned_tryboot_kind "$tryboot_config" "$expected_tryboot_hash" "$expected_reservation_hash" "$run_id" "$ownership_token" || true)
        [[ -n $ownership_kind ]] || { emit_result RECOVERY_FAILURE "The tryboot path is unowned or changed ($tryboot_type, hash $tryboot_hash); refusing cleanup."; return 1; }
        [[ ! -e $quarantine_path && ! -L $quarantine_path ]] || { emit_result RECOVERY_FAILURE 'Tryboot quarantine became occupied; refusing cleanup.'; return 1; }
        mv -n -- "$tryboot_config" "$quarantine_path" || { emit_result RECOVERY_FAILURE 'Could not quarantine the owned tryboot file for post-rename verification.'; return 1; }
        [[ ! -e $tryboot_config && ! -L $tryboot_config ]] || { emit_result RECOVERY_FAILURE 'No-clobber quarantine move did not remove the owned tryboot path; preserving both paths.'; return 1; }
        sync || { emit_result RECOVERY_FAILURE 'Could not sync the owned tryboot quarantine rename.'; return 1; }
    else
        ownership_kind=$(owned_tryboot_kind "$quarantine_path" "$expected_tryboot_hash" "$expected_reservation_hash" "$run_id" "$ownership_token" || true)
        [[ -n $ownership_kind ]] || { emit_result RECOVERY_FAILURE "The saved tryboot quarantine is unowned or changed ($quarantine_type, hash $quarantine_hash); preserving it."; return 1; }
    fi
    moved_kind=$(owned_tryboot_kind "$quarantine_path" "$expected_tryboot_hash" "$expected_reservation_hash" "$run_id" "$ownership_token" || true)
    [[ $moved_kind == "$ownership_kind" ]] || { emit_result RECOVERY_FAILURE "Tryboot quarantine failed post-rename ownership verification; preserving $quarantine_path."; return 1; }
    rm -f -- "$quarantine_path" || { emit_result RECOVERY_FAILURE 'Could not remove the verified tryboot quarantine after normal recovery.'; return 1; }
    sync || { emit_result RECOVERY_FAILURE 'Could not sync removal of the managed tryboot config.'; return 1; }
    [[ ! -e $tryboot_config && ! -L $tryboot_config && ! -e $quarantine_path && ! -L $quarantine_path ]] || { emit_result RECOVERY_FAILURE 'A tryboot or quarantine path exists after cleanup; preserving it and stopping.'; return 1; }
    permanent_hash=$(sha256sum "$boot_config" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    [[ $permanent_hash == "$expected_permanent_hash" ]] || { emit_result RECOVERY_FAILURE 'Permanent config hash changed during tryboot cleanup.'; return 1; }
    emit_data TRYBOOT_CLEARED "$ownership_kind-removed"
    emit_result PASS "Managed $ownership_kind tryboot file removed after verified normal recovery."
}

cmd_verify_tryboot() {
    local boot_config=$1 tryboot_config=$2 expected_permanent_hash=$3 expected_tryboot_hash=$4 run_id=$5 ownership_token=$6 permanent_hash ownership_kind
    tryboot_path_allowed "$boot_config" "$tryboot_config" || { emit_result RECOVERY_FAILURE 'Tryboot verification path is invalid.'; return 1; }
    permanent_hash=$(sha256sum "$boot_config" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    [[ $permanent_hash == "$expected_permanent_hash" ]] || { emit_result RECOVERY_FAILURE 'Permanent config hash changed before tryboot trigger.'; return 1; }
    ownership_kind=$(owned_tryboot_kind "$tryboot_config" "$expected_tryboot_hash" impossible "$run_id" "$ownership_token" || true)
    [[ $ownership_kind == candidate ]] || { emit_result RECOVERY_FAILURE 'The planned candidate is absent, incomplete, changed, or unowned; tryboot trigger is refused.'; return 1; }
    emit_result PASS 'Owned tryboot candidate verified immediately before trigger.'
}

cmd_trigger_tryboot() {
    cmd_verify_tryboot "$@" >/dev/null || return 1
    sync || return 1
    reboot '0 tryboot' >/dev/null 2>&1
}
cmd_reboot_normal() { vcgencmd get_throttled 0x0f >/dev/null 2>&1 || true; sync || return 1; reboot >/dev/null 2>&1; }

cmd_reset_throttle_history() {
    local before_reset after_reset
    before_reset=$(recent_throttle)
    reset_recent_throttle >/dev/null || { emit_result HARNESS_FAILURE 'Recent throttle history reset is unsupported or did not clear.'; return 1; }
    after_reset=$(recent_throttle)
    emit_data THROTTLE_BEFORE_RESET "$before_reset"
    emit_data THROTTLE_AFTER_RESET "$after_reset"
    emit_result PASS 'Recent throttle history was cleared and verified.'
}

process_tree_pids() {
    local root_pid=$1 proc_root=${2:-/proc} child_pid children_file
    children_file="${proc_root}/${root_pid}/task/${root_pid}/children"
    [[ $root_pid =~ ^[0-9]+$ ]] || return 0
    if [[ -r $children_file ]]; then
        for child_pid in $(<"$children_file"); do process_tree_pids "$child_pid" "$proc_root"; done
    fi
    printf '%s\n' "$root_pid"
}

terminate_child() {
    local child_pid=$1 attempts=0 process_pid alive
    local -a process_tree=()
    [[ -n $child_pid ]] || return 0
    mapfile -t process_tree < <(process_tree_pids "$child_pid")
    (( ${#process_tree[@]} > 0 )) || process_tree=("$child_pid")
    kill -TERM "${process_tree[@]}" 2>/dev/null || true
    while (( attempts < 10 )); do
        alive=0
        for process_pid in "${process_tree[@]}"; do kill -0 "$process_pid" 2>/dev/null && alive=1; done
        (( alive == 0 )) && break
        sleep 1
        attempts=$((attempts + 1))
    done
    for process_pid in "${process_tree[@]}"; do kill -KILL "$process_pid" 2>/dev/null || true; done
    wait "$child_pid" 2>/dev/null || true
}

start_io_activity() {
    local destination=$1
    (
        trap 'exit 0' TERM INT HUP
        while :; do
            dd if=/dev/zero of="${destination}.new" bs=1M count=1 conv=fsync status=none || exit 1
            mv -f "${destination}.new" "$destination" || exit 1
            sha256sum "$destination" >/dev/null || exit 1
            pause_seconds=0
            while (( pause_seconds < 300 )); do sleep 1; pause_seconds=$((pause_seconds + 1)); done
        done
    ) >/dev/null 2>&1 &
    stress_io_pid=$!
}

stress_cpu_pid=''
stress_gpu_pid=''
stress_io_pid=''
stress_work_dir=''
stress_io_file=''

cleanup_stress() {
    trap '' INT TERM HUP
    if [[ -n ${stress_cpu_pid:-} ]]; then terminate_child "$stress_cpu_pid"; stress_cpu_pid=''; fi
    if [[ -n ${stress_gpu_pid:-} ]]; then terminate_child "$stress_gpu_pid"; stress_gpu_pid=''; fi
    if [[ -n ${stress_io_pid:-} ]]; then terminate_child "$stress_io_pid"; stress_io_pid=''; fi
    if [[ -n ${stress_io_file:-} ]]; then rm -f -- "$stress_io_file" "${stress_io_file}.new" 2>/dev/null || true; stress_io_file=''; fi
    if [[ ${stress_work_dir:-} == /tmp/autopioverclock-stress.* ]]; then rm -rf -- "$stress_work_dir"; fi
    stress_work_dir=''
}

stress_signal_cleanup() {
    local exit_code=$1
    trap - EXIT
    trap '' INT TERM HUP
    cleanup_stress
    exit "$exit_code"
}

cmd_stress() {
    local stress_kind=$1 duration=$2 max_temp=$3 mode=${4:-headless} baseline=${5:-} io_check=${6:-0} expected_cpu=${7:-0} expected_gpu=${8:-0} throttle_baseline=${9:-throttled=0x0} telemetry_interval=${10:-5}
    local start_seconds expected_end hard_deadline now_seconds next_log max_seen=0 temp throttle new_errors
    local kernel_lines cpu_rc=0 gpu_rc=0 io_rc=0 failure_class='' failure_reason='' cpu_output gpu_output
    local arm_sample=0 gpu_sample=0 cpu_clock_seen=0 gpu_clock_seen=0 clock_tolerance=25
    local cpu_alive=0 gpu_alive=0 workloads_complete=0 telemetry_due=0
    [[ $telemetry_interval =~ ^[0-9]+$ ]] && (( telemetry_interval >= 1 && telemetry_interval <= 60 )) \
        || { emit_result HARNESS_FAILURE 'Telemetry interval must be an integer from 1 to 60 seconds.'; return 1; }
    command -v stress-ng >/dev/null 2>&1 || { emit_result HARNESS_FAILURE 'stress-ng is not installed.'; return 1; }
    stress_cpu_pid=''; stress_gpu_pid=''; stress_io_pid=''; stress_work_dir=''; stress_io_file=''
    stress_work_dir=$(mktemp -d /tmp/autopioverclock-stress.XXXXXX) || { emit_result HARNESS_FAILURE 'Could not create stress workspace.'; return 1; }
    cpu_output="$stress_work_dir/cpu.log"; gpu_output="$stress_work_dir/gpu.log"; stress_io_file=/var/tmp/autopioverclock-io-$$
    trap cleanup_stress EXIT
    trap 'stress_signal_cleanup 130' INT
    trap 'stress_signal_cleanup 143' TERM
    trap 'stress_signal_cleanup 129' HUP
    kernel_lines=$(kernel_log | wc -l)
    start_seconds=$SECONDS; expected_end=$((start_seconds + duration)); hard_deadline=$((expected_end + 60)); next_log=$start_seconds
    case $stress_kind in cpu|combined) stress-ng --cpu "$(nproc)" --cpu-method all --verify --timeout "${duration}s" --metrics-brief >"$cpu_output" 2>&1 & stress_cpu_pid=$! ;; esac
    case $stress_kind in
        gpu|combined)
            stress_ng_has_gpu || { emit_result HARNESS_FAILURE 'Installed stress-ng does not provide the GPU stressor.'; return 1; }
            [[ -e /dev/dri/renderD128 ]] || { emit_result HARNESS_FAILURE '/dev/dri/renderD128 is unavailable.'; return 1; }
            stress-ng --gpu 1 --gpu-devnode /dev/dri/renderD128 --verify --timeout "${duration}s" --metrics-brief >"$gpu_output" 2>&1 & stress_gpu_pid=$!
            ;;
    esac
    [[ -n $stress_cpu_pid || -n $stress_gpu_pid ]] || { emit_result HARNESS_FAILURE "Unknown stress kind: $stress_kind"; return 1; }
    if [[ $io_check == 1 ]]; then start_io_activity "$stress_io_file"; fi

    while :; do
        now_seconds=$SECONDS
        cpu_alive=0; gpu_alive=0; workloads_complete=0; telemetry_due=0
        [[ -n $stress_cpu_pid ]] && kill -0 "$stress_cpu_pid" 2>/dev/null && cpu_alive=1
        [[ -n $stress_gpu_pid ]] && kill -0 "$stress_gpu_pid" 2>/dev/null && gpu_alive=1

        # Workload liveness and the IO companion are safety supervision, not
        # telemetry.  Poll them every second regardless of the configured
        # telemetry/logging cadence so a clean early exit cannot hide between
        # samples.
        # Once a poll occurs past the hard deadline, completion timing is no
        # longer provable: fail closed even if the child died between polls.
        # A child already observed dead exactly at the deadline may continue to
        # the forced final telemetry sample below.
        if (( now_seconds > hard_deadline )); then
            failure_class=HARNESS_FAILURE
            failure_reason="Stress workers exceeded the requested ${duration}s duration plus a 60s shutdown grace period."
            break
        fi
        if [[ -n $stress_io_pid ]] && ! kill -0 "$stress_io_pid" 2>/dev/null; then
            wait "$stress_io_pid"; io_rc=$?; stress_io_pid=''
            failure_class=STABILITY_FAILURE
            failure_reason="Filesystem activity failed during load with rc=$io_rc."
            break
        fi
        # Classify individual early exits before considering the aggregate
        # all-dead state.  CPU-only/GPU-only and simultaneous clean exits must
        # never bypass the requested-duration gate.
        if (( now_seconds < expected_end - 2 )); then
            if [[ -n $stress_cpu_pid && $cpu_alive -eq 0 ]]; then wait "$stress_cpu_pid"; cpu_rc=$?; stress_cpu_pid=''; failure_class=$([[ $cpu_rc -eq 0 ]] && printf HARNESS_FAILURE || printf STABILITY_FAILURE); failure_reason="CPU stress exited early with rc=$cpu_rc."; break; fi
            if [[ -n $stress_gpu_pid && $gpu_alive -eq 0 ]]; then wait "$stress_gpu_pid"; gpu_rc=$?; stress_gpu_pid=''; if grep -Eqi 'unrecognized option|invalid option|not found|No such file' "$gpu_output"; then failure_class=HARNESS_FAILURE; else failure_class=STABILITY_FAILURE; fi; failure_reason="GPU stress exited early with rc=$gpu_rc."; break; fi
        fi
        if (( cpu_alive == 0 && gpu_alive == 0 )); then workloads_complete=1; fi

        # Sample at the configured cadence, plus one forced final sample after
        # both workloads have exited and before their result can be accepted.
        if (( now_seconds >= next_log || workloads_complete == 1 )); then telemetry_due=1; fi
        if (( telemetry_due == 1 )); then
            temp=$(current_temp)
            if [[ -n $temp ]]; then
                awk -v t="$temp" -v m="$max_seen" 'BEGIN{exit !(t>m)}' && max_seen=$temp || true
                if ! awk -v t="$temp" -v m="$max_temp" 'BEGIN{exit !(t<m)}'; then failure_class=STABILITY_FAILURE; failure_reason="Temperature ${temp}C reached the ${max_temp}C ceiling."; fi
            else failure_class=HARNESS_FAILURE; failure_reason='Temperature telemetry became unavailable.'; fi
            throttle=$(current_throttle)
            if ! throttle_word "$throttle" >/dev/null; then failure_class=HARNESS_FAILURE; failure_reason="Throttle telemetry became malformed: ${throttle:-missing}.";
            elif ! throttle_clean_relative "$throttle" "$throttle_baseline"; then failure_class=STABILITY_FAILURE; failure_reason="Current or new power/throttle flag changed to $throttle from baseline $throttle_baseline."; fi
            arm_sample=$(clock_mhz arm); gpu_sample=$(clock_mhz v3d)
            if [[ $stress_kind == cpu || $stress_kind == combined ]]; then [[ $arm_sample =~ ^[0-9]+$ ]] && (( arm_sample + clock_tolerance >= expected_cpu )) && cpu_clock_seen=1; fi
            if [[ $stress_kind == gpu || $stress_kind == combined ]]; then [[ $gpu_sample =~ ^[0-9]+$ ]] && (( gpu_sample + clock_tolerance >= expected_gpu )) && gpu_clock_seen=1; fi
            new_errors=$(kernel_error_lines "$((kernel_lines + 1))" || true)
            if [[ -n $new_errors ]]; then printf '%s\n' "$new_errors"; failure_class=STABILITY_FAILURE; failure_reason='A new kernel, power, GPU, USB, storage, or filesystem error appeared during stress.'; fi
            printf '%s temp=%sC arm=%sMHz v3d=%sMHz expected=%s/%s %s\n' "$(date '+%F %T')" "${temp:-unknown}" "$arm_sample" "$gpu_sample" "$expected_cpu" "$expected_gpu" "$throttle"
            next_log=$((now_seconds + telemetry_interval))
        fi
        if [[ -n $failure_class ]]; then break; fi
        if (( workloads_complete == 1 )); then break; fi
        sleep 1
    done

    if [[ -n $failure_class ]]; then
        if [[ -n $stress_cpu_pid ]] && kill -0 "$stress_cpu_pid" 2>/dev/null; then terminate_child "$stress_cpu_pid"; cpu_rc=124; stress_cpu_pid=''; fi
        if [[ -n $stress_gpu_pid ]] && kill -0 "$stress_gpu_pid" 2>/dev/null; then terminate_child "$stress_gpu_pid"; gpu_rc=124; stress_gpu_pid=''; fi
    fi
    if [[ -n $stress_cpu_pid ]]; then wait "$stress_cpu_pid" 2>/dev/null; cpu_rc=$?; stress_cpu_pid=''; fi
    if [[ -n $stress_gpu_pid ]]; then wait "$stress_gpu_pid" 2>/dev/null; gpu_rc=$?; stress_gpu_pid=''; fi
    if [[ -n $stress_io_pid ]]; then terminate_child "$stress_io_pid"; stress_io_pid=''; fi
    [[ -f $cpu_output ]] && { printf '%s\n' '--- CPU stress output ---'; cat "$cpu_output"; }
    [[ -f $gpu_output ]] && { printf '%s\n' '--- GPU stress output ---'; cat "$gpu_output"; }
    printf 'CPU_RC=%s GPU_RC=%s IO_RC=%s\n' "$cpu_rc" "$gpu_rc" "$io_rc"
    printf '%s\n' "$(current_throttle)"
    vcgencmd measure_clock arm 2>/dev/null || true; vcgencmd measure_clock v3d 2>/dev/null || true; vcgencmd pmic_read_adc EXT5V_V 2>/dev/null || true
    if [[ -z $failure_class && ( $cpu_rc -ne 0 || $gpu_rc -ne 0 ) ]]; then failure_class=STABILITY_FAILURE; failure_reason="Stress process returned nonzero (CPU=$cpu_rc GPU=$gpu_rc)."; fi
    if [[ -z $failure_class && ( $stress_kind == cpu || $stress_kind == combined ) && $cpu_clock_seen -ne 1 ]]; then failure_class=STABILITY_FAILURE; failure_reason="Requested CPU clock ${expected_cpu}MHz was never observed within ${clock_tolerance}MHz under load."; fi
    if [[ -z $failure_class && ( $stress_kind == gpu || $stress_kind == combined ) && $gpu_clock_seen -ne 1 ]]; then failure_class=STABILITY_FAILURE; failure_reason="Requested GPU clock ${expected_gpu}MHz was never observed within ${clock_tolerance}MHz under load."; fi
    if [[ -z $failure_class ]]; then
        [[ $stress_kind != cpu ]] || [[ -s $cpu_output ]] || { failure_class=HARNESS_FAILURE; failure_reason='CPU stress produced no output.'; }
        [[ $stress_kind != gpu && $stress_kind != combined ]] || [[ -s $gpu_output ]] || { failure_class=HARNESS_FAILURE; failure_reason='GPU stress produced no output.'; }
    fi
    if [[ -n $failure_class ]]; then emit_result "$failure_class" "$failure_reason" "$max_seen"; return 1; fi
    emit_result PASS "$stress_kind stress completed successfully." "$max_seen"
    cleanup_stress; trap - EXIT INT TERM HUP
}

cmd_render_permanent() {
    local cpu_mhz=$1 gpu_mhz=$2 gpu_key=$3 voltage_uv=$4 run_id=$5 boot_config
    boot_config=$(find_boot_config) || return 1
    render_clock_config "$boot_config" /dev/stdout "$cpu_mhz" "$gpu_mhz" "$gpu_key" "$voltage_uv" "$run_id"
}

valid_sha256() { [[ ${1-} =~ ^[0-9a-f]{64}$ ]]; }

atomic_replace_verified() {
    local source_file=$1 destination_file=$2 expected_hash=$3 suffix=$4 temporary_file actual_hash
    actual_hash=$(sha256sum "$source_file" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    [[ $actual_hash == "$expected_hash" ]] || return 1
    temporary_file="${destination_file}.autopioverclock-${suffix}"
    cp -a "$source_file" "$temporary_file" || return 1
    actual_hash=$(sha256sum "$temporary_file" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    if [[ $actual_hash != "$expected_hash" ]]; then rm -f -- "$temporary_file"; return 1; fi
    sync "$temporary_file" || { rm -f -- "$temporary_file"; return 1; }
    mv -f -- "$temporary_file" "$destination_file" || return 1
    sync "$destination_file" || return 1
    actual_hash=$(sha256sum "$destination_file" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    [[ $actual_hash == "$expected_hash" ]]
}

cmd_apply_permanent() {
    local uploaded_file=$1 expected_old_hash=$2 expected_new_hash=$3 run_id=$4
    local boot_config current_hash proposed_hash backup_dir backup_file backup_hash
    valid_sha256 "$expected_old_hash" && valid_sha256 "$expected_new_hash" && [[ $expected_old_hash != "$expected_new_hash" ]] || { emit_result APPLY_FAILURE 'Apply hashes are missing or invalid.'; return 1; }
    boot_config=$(find_boot_config) || { emit_result APPLY_FAILURE 'Boot config is missing.'; return 1; }
    apply_tryboot_clear "$boot_config" || { emit_result APPLY_FAILURE 'Permanent apply requires a normal boot with no live, staged, or quarantined tryboot evidence.'; return 1; }
    current_hash=$(sha256sum "$boot_config" | awk '{print $1}')
    [[ $current_hash == "$expected_old_hash" ]] || { emit_result APPLY_FAILURE 'Permanent config changed since validation; refusing to apply.'; return 1; }
    [[ -s $uploaded_file ]] || { emit_result APPLY_FAILURE 'Uploaded proposed config is empty.'; return 1; }
    proposed_hash=$(sha256sum "$uploaded_file" | awk '{print $1}')
    [[ $proposed_hash == "$expected_new_hash" ]] || { emit_result APPLY_FAILURE 'Uploaded proposed config does not match the persisted expected hash.'; return 1; }
    backup_dir=/var/lib/autopioverclock/backups
    mkdir -p "$backup_dir" || { emit_result APPLY_FAILURE 'Could not create the permanent-config backup directory.'; return 1; }
    backup_file="${backup_dir}/config-${run_id}-before-apply.txt"
    backup_hash=$(sha256sum "$backup_file" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    if [[ $backup_hash != "$expected_old_hash" ]]; then
        atomic_replace_verified "$boot_config" "$backup_file" "$expected_old_hash" backup || { emit_result APPLY_FAILURE 'Could not create and verify the deterministic permanent backup.'; return 1; }
    fi
    if ! chmod --reference="$boot_config" "$uploaded_file" 2>/dev/null && ! chmod 644 "$uploaded_file"; then
        emit_result APPLY_FAILURE 'Could not set proposed permanent-config permissions.'
        return 1
    fi
    apply_tryboot_clear "$boot_config" || { emit_result APPLY_FAILURE 'Tryboot evidence appeared before permanent replacement; refusing to apply.'; return 1; }
    current_hash=$(sha256sum "$boot_config" | awk '{print $1}')
    [[ $current_hash == "$expected_old_hash" ]] || { emit_result APPLY_FAILURE 'Permanent config changed at the apply mutation boundary; refusing to apply.'; return 1; }
    if ! atomic_replace_verified "$uploaded_file" "$boot_config" "$expected_new_hash" new; then
        if atomic_replace_verified "$backup_file" "$boot_config" "$expected_old_hash" restore; then
            emit_result APPLY_FAILURE 'Atomic permanent-config replacement failed; the verified backup was restored.'
        else
            emit_result APPLY_FAILURE 'Atomic permanent-config replacement failed and backup restoration could not be verified.'
        fi
        return 1
    fi
    emit_data BACKUP_FILE "$backup_file"; emit_data NEW_HASH "$expected_new_hash"; emit_result PASS 'Validated clocks were written to permanent config and its hash was verified.'
}

cmd_restore_backup() {
    local backup_file=$1 expected_old_hash=$2 expected_current_hash=$3 boot_config backup_hash current_hash
    valid_sha256 "$expected_old_hash" && valid_sha256 "$expected_current_hash" && [[ $expected_old_hash != "$expected_current_hash" ]] \
        || { emit_result APPLY_FAILURE 'Rollback old/current hashes are missing, invalid, or identical.'; return 1; }
    boot_config=$(find_boot_config) || { emit_result APPLY_FAILURE 'Boot config is missing for rollback.'; return 1; }
    apply_tryboot_clear "$boot_config" || { emit_result APPLY_FAILURE 'Rollback requires a normal boot with no live, staged, or quarantined tryboot evidence.'; return 1; }
    current_hash=$(sha256sum "$boot_config" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    [[ $current_hash == "$expected_current_hash" ]] || { emit_result APPLY_FAILURE 'Permanent config does not match the persisted pre-rollback destination hash; refusing restoration.'; return 1; }
    [[ -f $backup_file ]] || { emit_result APPLY_FAILURE "Backup file is missing: $backup_file"; return 1; }
    backup_hash=$(sha256sum "$backup_file" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    [[ $backup_hash == "$expected_old_hash" ]] || { emit_result APPLY_FAILURE 'Permanent config backup does not match the persisted pre-apply hash.'; return 1; }
    apply_tryboot_clear "$boot_config" || { emit_result APPLY_FAILURE 'Tryboot evidence appeared before rollback replacement; refusing mutation.'; return 1; }
    current_hash=$(sha256sum "$boot_config" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    [[ $current_hash == "$expected_current_hash" ]] || { emit_result APPLY_FAILURE 'Permanent config changed at the rollback mutation boundary; refusing restoration.'; return 1; }
    atomic_replace_verified "$backup_file" "$boot_config" "$expected_old_hash" restore || { emit_result APPLY_FAILURE 'Could not restore and verify the permanent config backup.'; return 1; }
    emit_data RESTORED_HASH "$expected_old_hash"; emit_result PASS 'Permanent config backup restored and verified.'
}

cmd_plan_watchdog_repair() {
    local kernel_timeout=${1:-} boot_config temporary_config old_hash expected_hash
    [[ $kernel_timeout =~ ^[0-9]+$ ]] && (( kernel_timeout > 0 )) \
        || { emit_result PREFLIGHT_FAILURE 'Watchdog repair planning requires a positive integer kernel timeout.'; return 1; }
    boot_config=$(find_boot_config) || { emit_result PREFLIGHT_FAILURE 'Boot config is missing.'; return 1; }
    temporary_config=$(mktemp /tmp/autopioverclock-watchdog-plan.XXXXXX) \
        || { emit_result PREFLIGHT_FAILURE 'Could not create the watchdog planning file.'; return 1; }
    if ! render_watchdog_config "$boot_config" "$temporary_config" "$kernel_timeout"; then
        rm -f -- "$temporary_config"
        emit_result PREFLIGHT_FAILURE 'Could not render the planned kernel watchdog config.'
        return 1
    fi
    old_hash=$(sha256sum "$boot_config" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    expected_hash=$(sha256sum "$temporary_config" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    rm -f -- "$temporary_config"
    valid_sha256 "$old_hash" && valid_sha256 "$expected_hash" \
        || { emit_result PREFLIGHT_FAILURE 'Could not hash the current and planned watchdog configs.'; return 1; }
    emit_data WATCHDOG_REPAIR_OLD_HASH "$old_hash"
    emit_data WATCHDOG_REPAIR_EXPECTED_HASH "$expected_hash"
    emit_result PASS 'Watchdog repair hashes were planned without modifying the target.'
}

cmd_repair_watchdogs() {
    local boot_timeout=${1:-} kernel_timeout=${2:-} runtime_timeout=${3:-} expected_old_hash=${4:-} expected_new_hash=${5:-} boot_config current_eeprom='' new_eeprom='' temporary_config='' temporary_dropin='' apply_log=''
    local backup_dir=/var/lib/autopioverclock/backups backup_config='' backup_dropin='' dropin_file=/etc/systemd/system.conf.d/99-autopioverclock-watchdog.conf
    local old_config_hash new_config_hash old_dropin_hash='' new_dropin_hash new_eeprom_timeout dropin_existed=0 config_installed=0 dropin_installed=0 committed=0

    repair_watchdog_cleanup() {
        [[ -z $current_eeprom ]] || rm -f -- "$current_eeprom"
        [[ -z $new_eeprom ]] || rm -f -- "$new_eeprom"
        [[ -z $temporary_config ]] || rm -f -- "$temporary_config"
        [[ -z $temporary_dropin ]] || rm -f -- "$temporary_dropin"
        [[ -z $apply_log ]] || rm -f -- "$apply_log"
    }
    repair_watchdog_rollback() {
        local rollback_failed=0
        if (( dropin_installed == 1 )); then
            if (( dropin_existed == 1 )); then
                atomic_replace_verified "$backup_dropin" "$dropin_file" "$old_dropin_hash" watchdog-dropin-restore || rollback_failed=1
            else
                rm -f -- "$dropin_file" || rollback_failed=1
                sync "$(dirname "$dropin_file")" || rollback_failed=1
            fi
        fi
        if (( config_installed == 1 )); then
            atomic_replace_verified "$backup_config" "$boot_config" "$old_config_hash" watchdog-config-restore || rollback_failed=1
        fi
        return "$rollback_failed"
    }
    repair_watchdog_abort() {
        local reason=$1
        trap - INT TERM HUP
        if ! repair_watchdog_rollback; then reason="$reason Automatic rollback could not be fully verified."; fi
        repair_watchdog_cleanup
        emit_result PREFLIGHT_FAILURE "$reason"
        return 1
    }
    repair_watchdog_signal() {
        local signal_status=$1
        trap - INT TERM HUP
        (( committed == 1 )) || repair_watchdog_rollback >/dev/null 2>&1 || true
        repair_watchdog_cleanup
        exit "$signal_status"
    }

    [[ $boot_timeout =~ ^[0-9]+$ && $kernel_timeout =~ ^[0-9]+$ && $runtime_timeout =~ ^[0-9]+$ ]] \
        && (( boot_timeout > 0 && kernel_timeout > 0 && runtime_timeout > 0 )) \
        || { emit_result PREFLIGHT_FAILURE 'Watchdog repair requires positive integer EEPROM, kernel, and runtime timeouts.'; return 1; }
    valid_sha256 "$expected_old_hash" && valid_sha256 "$expected_new_hash" \
        || { emit_result PREFLIGHT_FAILURE 'Watchdog repair requires valid checkpointed current and expected config hashes.'; return 1; }
    command -v rpi-eeprom-config >/dev/null 2>&1 || { emit_result PREFLIGHT_FAILURE 'rpi-eeprom-config is unavailable.'; return 1; }
    command -v systemctl >/dev/null 2>&1 || { emit_result PREFLIGHT_FAILURE 'systemd is unavailable.'; return 1; }
    boot_config=$(find_boot_config) || { emit_result PREFLIGHT_FAILURE 'Boot config is missing.'; return 1; }
    apply_tryboot_clear "$boot_config" || { emit_result PREFLIGHT_FAILURE 'Watchdog repair requires a normal boot with no live, staged, or quarantined tryboot evidence.'; return 1; }
    mkdir -p "$backup_dir" "$(dirname "$dropin_file")" || { emit_result PREFLIGHT_FAILURE 'Could not create watchdog staging directories.'; return 1; }
    trap 'repair_watchdog_signal 130' INT
    trap 'repair_watchdog_signal 143' TERM
    trap 'repair_watchdog_signal 129' HUP

    current_eeprom=$(mktemp /tmp/autopioverclock-eeprom-current.XXXXXX) || { repair_watchdog_abort 'Could not create the EEPROM readback file.'; return 1; }
    new_eeprom=$(mktemp /tmp/autopioverclock-eeprom-new.XXXXXX) || { repair_watchdog_abort 'Could not create the EEPROM staging file.'; return 1; }
    temporary_config=$(mktemp "$(dirname "$boot_config")/.autopioverclock-watchdog.XXXXXX") || { repair_watchdog_abort 'Could not create the boot-config staging file.'; return 1; }
    temporary_dropin=$(mktemp "$(dirname "$dropin_file")/.autopioverclock-watchdog.XXXXXX") || { repair_watchdog_abort 'Could not create the systemd watchdog staging file.'; return 1; }
    apply_log=$(mktemp /tmp/autopioverclock-eeprom-apply.XXXXXX) || { repair_watchdog_abort 'Could not create the EEPROM apply log.'; return 1; }
    backup_config=$(mktemp "$backup_dir/config-watchdog-$(date +%Y%m%d-%H%M%S)-XXXXXX.txt") || { repair_watchdog_abort 'Could not reserve a boot-config backup path.'; return 1; }

    rpi-eeprom-config > "$current_eeprom" || { repair_watchdog_abort 'Could not read EEPROM configuration.'; return 1; }
    if ! awk -F= -v wanted="$boot_timeout" '
        BEGIN {done=0}
        {
            key=$1
            gsub(/[[:space:]]/, "", key)
            if (key == "BOOT_WATCHDOG_TIMEOUT") {print "BOOT_WATCHDOG_TIMEOUT=" wanted; done=1; next}
            print
        }
        END {if (!done) print "BOOT_WATCHDOG_TIMEOUT=" wanted}
    ' "$current_eeprom" > "$new_eeprom"; then
        repair_watchdog_abort 'Could not render the EEPROM watchdog update.'
        return 1
    fi
    new_eeprom_timeout=$(awk -F= '$1 == "BOOT_WATCHDOG_TIMEOUT" {value=$2} END {gsub(/[[:space:]]/, "", value); print value}' "$new_eeprom")
    [[ $new_eeprom_timeout == "$boot_timeout" ]] || { repair_watchdog_abort 'The staged EEPROM watchdog timeout could not be verified.'; return 1; }

    render_watchdog_config "$boot_config" "$temporary_config" "$kernel_timeout" || { repair_watchdog_abort 'Could not render kernel watchdog config.'; return 1; }
    [[ $(config_last_value "$temporary_config" kernel_watchdog_timeout) == "$kernel_timeout" ]] || { repair_watchdog_abort 'The staged kernel watchdog config could not be verified.'; return 1; }
    chmod --reference="$boot_config" "$temporary_config" 2>/dev/null || chmod 644 "$temporary_config" || { repair_watchdog_abort 'Could not set staged boot-config permissions.'; return 1; }
    printf '[Manager]\nRuntimeWatchdogSec=%ss\nRebootWatchdogSec=%ss\n' "$runtime_timeout" "$((runtime_timeout * 2))" > "$temporary_dropin" \
        || { repair_watchdog_abort 'Could not render the systemd watchdog drop-in.'; return 1; }
    chmod 644 "$temporary_dropin" || { repair_watchdog_abort 'Could not set staged systemd drop-in permissions.'; return 1; }

    old_config_hash=$(sha256sum "$boot_config" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    new_config_hash=$(sha256sum "$temporary_config" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    new_dropin_hash=$(sha256sum "$temporary_dropin" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    valid_sha256 "$old_config_hash" && valid_sha256 "$new_config_hash" && valid_sha256 "$new_dropin_hash" \
        || { repair_watchdog_abort 'Could not hash all staged watchdog files.'; return 1; }
    [[ $old_config_hash == "$expected_old_hash" ]] \
        || { repair_watchdog_abort 'Permanent config changed after the watchdog repair checkpoint; refusing mutation.'; return 1; }
    [[ $new_config_hash == "$expected_new_hash" ]] \
        || { repair_watchdog_abort 'Rendered watchdog config does not match the checkpointed expected hash.'; return 1; }
    atomic_replace_verified "$boot_config" "$backup_config" "$old_config_hash" watchdog-config-backup \
        || { repair_watchdog_abort 'Could not create and verify the permanent boot-config backup.'; return 1; }

    if [[ -e $dropin_file ]]; then
        dropin_existed=1
        old_dropin_hash=$(sha256sum "$dropin_file" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
        valid_sha256 "$old_dropin_hash" || { repair_watchdog_abort 'Could not hash the existing systemd watchdog drop-in.'; return 1; }
        backup_dropin=$(mktemp "$backup_dir/systemd-watchdog-$(date +%Y%m%d-%H%M%S)-XXXXXX.conf") \
            || { repair_watchdog_abort 'Could not reserve a systemd watchdog backup path.'; return 1; }
        atomic_replace_verified "$dropin_file" "$backup_dropin" "$old_dropin_hash" watchdog-dropin-backup \
            || { repair_watchdog_abort 'Could not create and verify the systemd watchdog backup.'; return 1; }
    fi

    config_installed=1
    atomic_replace_verified "$temporary_config" "$boot_config" "$new_config_hash" watchdog-config-install \
        || { repair_watchdog_abort 'Could not atomically install and verify the kernel watchdog config.'; return 1; }
    dropin_installed=1
    atomic_replace_verified "$temporary_dropin" "$dropin_file" "$new_dropin_hash" watchdog-dropin-install \
        || { repair_watchdog_abort 'Could not atomically install and verify the systemd watchdog drop-in.'; return 1; }
    sync "$boot_config" || { repair_watchdog_abort 'Could not sync the kernel watchdog config.'; return 1; }
    sync "$dropin_file" || { repair_watchdog_abort 'Could not sync the systemd watchdog drop-in.'; return 1; }

    # Once EEPROM scheduling begins, its outcome can be ambiguous if the
    # controller connection or worker is interrupted. Do not automatically
    # roll back the matching boot/runtime files across that uncertainty; the
    # persisted PREPARE checkpoint forces manual inspection and a fresh run.
    committed=1
    if ! rpi-eeprom-config --apply "$new_eeprom" >"$apply_log" 2>&1; then
        cat "$apply_log"
        repair_watchdog_cleanup
        emit_result PREFLIGHT_FAILURE 'EEPROM watchdog scheduling failed after the no-rollback boundary; inspect the saved repair hashes and target state before starting a new run.'
        return 1
    fi
    trap - INT TERM HUP
    repair_watchdog_cleanup
    emit_data WATCHDOG_CONFIG_BACKUP "$backup_config"
    emit_data WATCHDOG_REPAIR_NEW_HASH "$new_config_hash"
    emit_result PASS 'Watchdog remediation was staged; a normal reboot is required.'
}

cmd_classify_kernel_log() {
    local log_file=$1 common_errors usb_errors
    [[ -r $log_file ]] || { emit_result HARNESS_FAILURE "Kernel-log fixture is unreadable: $log_file"; return 1; }
    common_errors=$(grep -Ei "$ERROR_PATTERN" "$log_file" || true)
    usb_errors=$(grep -Ei "$USB_RESET_PATTERN" "$log_file" || true)
    if [[ -n $common_errors || -n $usb_errors ]]; then printf '%s\n%s\n' "$common_errors" "$usb_errors" | awk 'NF && !seen[$0]++'; emit_result STABILITY_FAILURE 'Kernel-log fixture contains a kernel, power, GPU, USB, storage, or filesystem failure.'; return 1; fi
    emit_result PASS 'Kernel-log fixture is clean.'
}

main() {
    local command_name=${1:-}
    [[ -n $command_name ]] || { emit_result HARNESS_FAILURE 'Worker command is required.'; return 2; }
    shift || true
    case $command_name in
        discover) cmd_discover "$@" ;;
        health) cmd_health "$@" ;;
        plan-candidate) cmd_plan_candidate "$@" ;;
        prepare-candidate) run_with_mutation_lock "${11:-}" RECOVERY_FAILURE cmd_prepare_candidate "$@" ;;
        verify-tryboot) cmd_verify_tryboot "$@" ;;
        clear-tryboot) run_with_mutation_lock "${8:-}" RECOVERY_FAILURE cmd_clear_tryboot "$@" ;;
        trigger-tryboot) run_with_mutation_lock "${6:-}" RECOVERY_FAILURE cmd_trigger_tryboot "$@" ;;
        reboot-normal) run_with_mutation_lock "reboot-${BASHPID}" RECOVERY_FAILURE cmd_reboot_normal "$@" ;;
        stress) cmd_stress "$@" ;;
        reset-throttle-history) cmd_reset_throttle_history "$@" ;;
        render-permanent) cmd_render_permanent "$@" ;;
        apply-permanent) run_with_mutation_lock "apply-${4:-}" APPLY_FAILURE cmd_apply_permanent "$@" ;;
        restore-backup) run_with_mutation_lock "restore-${2:-}" APPLY_FAILURE cmd_restore_backup "$@" ;;
        plan-watchdog-repair) cmd_plan_watchdog_repair "$@" ;;
        repair-watchdogs) run_with_mutation_lock "watchdog-${5:-}" PREFLIGHT_FAILURE cmd_repair_watchdogs "$@" ;;
        classify-kernel-log) cmd_classify_kernel_log "$@" ;;
        *) emit_result HARNESS_FAILURE "Unknown worker command: $command_name"; return 2 ;;
    esac
}

if [[ ${APO_WORKER_LIBRARY_ONLY:-0} != 1 ]]; then main "$@"; fi
