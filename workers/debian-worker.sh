#!/usr/bin/env bash
# AutoPiOverclock remote worker for Raspberry Pi OS, Debian, and Ubuntu Pi layouts.
set -u -o pipefail
umask 077

ERROR_PATTERN='under.?voltage|throttl|Hardware Error|SError|Kernel panic|Internal error[[:space:]]*:|Unable to handle kernel|RCU.*(detected|self-detected).*stall|kthread starved for|kthread timer wakeup.*happen|hung[_ -]?task|task[[:space:]].*blocked for more than[[:space:]]+[0-9]+[[:space:]]+seconds|v3d.*(hang|fault|error|timeout)|drm.*(hang|fault|error|timeout)|device offline|I/O error|Buffer I/O error|EXT4-fs (error|warning)|BTRFS.*(error|warning)|segfault|Oops:|BUG:|Call trace|watchdog:.*lockup'
USB_RESET_PATTERN='usb [0-9.-]+: reset (low-speed|full-speed|high-speed|SuperSpeed|SuperSpeed Plus)?[[:space:]]*USB device|reset (low-speed|full-speed|high-speed|SuperSpeed|SuperSpeed Plus)[[:space:]]+USB device'
CLOCK_MARKER_BEGIN='# BEGIN AUTOPIOVERCLOCK MANAGED CLOCKS'
CLOCK_MARKER_END='# END AUTOPIOVERCLOCK MANAGED CLOCKS'
CANDIDATE_FAN_COMMENT='# AUTOPIOVERCLOCK CANDIDATE COOLING: PI PWM FAN 100 PERCENT'
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

FAN_PWM_LAST_COUNT=0
FAN_PWM_LAST_STATUS=not-detected
FAN_PWM_LAST_REASON=''

fan_pwm_snapshot() {
    local hwmon_root=${1:-/sys/class/hwmon} hwmon name pwm rpm details='' count=0 all_max=1 all_spinning=1
    FAN_PWM_LAST_COUNT=0
    FAN_PWM_LAST_STATUS=not-detected
    FAN_PWM_LAST_REASON=''
    for hwmon in "$hwmon_root"/hwmon*; do
        [[ -r $hwmon/name && -r $hwmon/pwm1 ]] || continue
        name=$(tr -d '\r\n' < "$hwmon/name" 2>/dev/null || true)
        [[ $name == pwmfan ]] || continue
        count=$((count + 1))
        pwm=$(tr -d '[:space:]' < "$hwmon/pwm1" 2>/dev/null || true)
        if [[ ! $pwm =~ ^[0-9]+$ ]] || (( pwm > 255 )); then
            FAN_PWM_LAST_COUNT=$count
            FAN_PWM_LAST_STATUS=invalid
            FAN_PWM_LAST_REASON="Pi PWM fan telemetry is malformed at $hwmon/pwm1."
            return 1
        fi
        (( pwm == 255 )) || all_max=0
        rpm=unreported
        if [[ -r $hwmon/fan1_input ]]; then
            rpm=$(tr -d '[:space:]' < "$hwmon/fan1_input" 2>/dev/null || true)
            if [[ ! $rpm =~ ^[0-9]+$ ]]; then
                FAN_PWM_LAST_COUNT=$count
                FAN_PWM_LAST_STATUS=invalid
                FAN_PWM_LAST_REASON="Pi PWM fan tachometer telemetry is malformed at $hwmon/fan1_input."
                return 1
            fi
            (( rpm > 0 )) || all_spinning=0
        fi
        details+="${details:+,}$(basename -- "$hwmon"):pwm=${pwm}:rpm=${rpm}"
    done
    FAN_PWM_LAST_COUNT=$count
    if (( count == 0 )); then
        FAN_PWM_LAST_STATUS=not-detected
        return 0
    fi
    FAN_PWM_LAST_STATUS=$details
    if (( all_max != 1 )); then
        FAN_PWM_LAST_REASON="A detected Pi PWM fan is not at the required maximum setting (255): $details"
        return 1
    fi
    if (( all_spinning != 1 )); then
        FAN_PWM_LAST_REASON="A detected Pi PWM fan reports zero RPM at the required maximum setting: $details"
        return 1
    fi
}

candidate_fan_max_ready() {
    fan_pwm_snapshot "${1:-/sys/class/hwmon}"
}

candidate_fan_max_wait() {
    local wait_seconds=${1:-15} hwmon_root=${2:-/sys/class/hwmon} deadline
    deadline=$((SECONDS + wait_seconds))
    while :; do
        candidate_fan_max_ready "$hwmon_root" && return 0
        (( SECONDS >= deadline )) && return 1
        sleep 1
    done
}

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

canonicalize_global_sections() {
    local source_file=$1 destination_file=$2 insert_all=${3:-1}
    [[ $insert_all == 0 || $insert_all == 1 ]] || return 1
    awk -v insert_all="$insert_all" '
        function normalized(value) {
            sub(/\r$/, "", value)
            sub(/^[[:space:]]*/, "", value)
            sub(/[[:space:]]*$/, "", value)
            return value
        }
        function section_header(value) {
            value=normalized(value)
            return length(value) >= 3 && substr(value, 1, 1) == "[" && substr(value, length(value), 1) == "]"
        }
        function active_directive(value) {
            value=normalized(value)
            return value != "" && substr(value, 1, 1) != "#" && !section_header(value)
        }
        {
            lines[NR]=$0
            probe=normalized($0)
            if (section_header(probe)) {
                current_header=NR
                current_non_all=(tolower(probe) != "[all]")
                next
            }
            if (current_non_all && active_directive(probe)) {
                meaningful_header[current_header]=1
                meaningful_non_all=1
            }
        }
        END {
            inserted=0
            current="[all]"
            for (line_number=1; line_number<=NR; line_number++) {
                probe=normalized(lines[line_number])
                if (!meaningful_non_all && section_header(probe)) continue
                if (meaningful_non_all && section_header(probe)) {
                    scope=tolower(probe)
                    if (scope != "[all]" && !meaningful_header[line_number]) continue
                    if (scope == "[all]" && current == "[all]") continue
                    print lines[line_number]
                    current=scope
                    continue
                }
                if (!meaningful_non_all && insert_all && !inserted && active_directive(probe)) {
                    print "[all]"
                    inserted=1
                }
                print lines[line_number]
            }
            if (!meaningful_non_all && insert_all && !inserted) print "[all]"
        }
    ' "$source_file" > "$destination_file"
}

config_needs_global_header_at_eof() {
    local config_file=$1
    awk '
        function normalized(value) {
            sub(/\r$/, "", value)
            sub(/^[[:space:]]*/, "", value)
            sub(/[[:space:]]*$/, "", value)
            return value
        }
        function section_header(value) {
            value=normalized(value)
            return length(value) >= 3 && substr(value, 1, 1) == "[" && substr(value, length(value), 1) == "]"
        }
        BEGIN {current="[all]"}
        {
            probe=normalized($0)
            if (!section_header(probe)) next
            current=tolower(probe)
            if (current == "[all]") seen_all=1
        }
        END {exit !(!seen_all || current != "[all]")}
    ' "$config_file"
}

render_clock_config() {
    local source_file=$1 destination_file=$2 cpu_mhz=$3 gpu_mhz=$4 gpu_key=$5 voltage_uv=$6 run_id=$7
    local voltage_render_mode=${8:-explicit} stripped_file
    [[ $voltage_render_mode == explicit || $voltage_render_mode == omit-default-zero ]] || return 1
    [[ $voltage_render_mode != omit-default-zero || $voltage_uv == 0 ]] || return 1
    stripped_file=$(mktemp /tmp/autopioverclock-clock-render.XXXXXX) || return 1
    awk -v begin="$CLOCK_MARKER_BEGIN" -v end="$CLOCK_MARKER_END" '
        function stripped(value) {
            sub(/\r$/, "", value)
            return value
        }
        function stale_project_artifact(value, lower) {
            value=stripped(value)
            lower=tolower(value)
            sub(/^[[:space:]]*/, "", lower)
            return value ~ /^[[:space:]]*#[[:space:]]*AUTOPIOVERCLOCK-WATCHDOG-DISABLED[[:space:]]+(kernel_watchdog_timeout|watchdog[.]open_timeout)[[:space:]]*=/ ||
                   value ~ /^[[:space:]]*#[[:space:]]*TRON_RECOVERY_DISABLED[[:space:]]+(kernel_watchdog_timeout|watchdog[.]open_timeout)[[:space:]]*=/ ||
                   lower == "# tron recovery: disable firmware-to-os watchdog handoff"
        }
        function watchdog_block_begin(value) {
            value=stripped(value)
            return value == "# BEGIN AUTOPIOVERCLOCK WATCHDOG" ||
                   value == "# BEGIN AUTOPIOVERCLOCK MANAGED WATCHDOG"
        }
        function watchdog_block_end(value) {
            value=stripped(value)
            return value == "# END AUTOPIOVERCLOCK WATCHDOG" ||
                   value == "# END AUTOPIOVERCLOCK MANAGED WATCHDOG"
        }
        {
            lines[NR]=$0
            semantic=stripped($0)
            if (semantic==begin) {
                if (inside) invalid=1
                inside=1
                drop[NR]=1
                next
            }
            if (semantic==end) {
                if (!inside) invalid=1
                inside=0
                drop[NR]=1
                next
            }
            if (inside) {
                drop[NR]=1
                next
            }
            if (watchdog_block_begin(semantic)) {
                if (watchdog_inside) invalid=1
                watchdog_inside=1
                next
            }
            if (watchdog_block_end(semantic)) {
                if (!watchdog_inside) invalid=1
                watchdog_inside=0
                next
            }
            if (!watchdog_inside && stale_project_artifact(semantic)) {
                drop[NR]=1
            }
        }
        END {
            if (invalid || inside || watchdog_inside) exit 1
            kept_count=0
            last_content=0
            for (line_number=1; line_number<=NR; line_number++) {
                if (!drop[line_number]) {
                    kept[++kept_count]=lines[line_number]
                    semantic=stripped(lines[line_number])
                    if (semantic !~ /^[[:space:]]*$/) last_content=kept_count
                }
            }
            for (line_number=1; line_number<=last_content; line_number++) {
                print kept[line_number]
            }
        }
    ' "$source_file" > "$stripped_file" || { rm -f -- "$stripped_file"; return 1; }
    canonicalize_global_sections "$stripped_file" "$destination_file" 0 || { rm -f -- "$stripped_file"; return 1; }
    rm -f -- "$stripped_file"
    printf '\n%s\n# Run: %s\n[all]\n' "$CLOCK_MARKER_BEGIN" "$run_id" >> "$destination_file" || return 1
    if [[ $voltage_render_mode == explicit ]]; then
        printf 'over_voltage_delta=%s\n' "$voltage_uv" >> "$destination_file" || return 1
    fi
    printf 'arm_freq=%s\n%s=%s\n%s\n' "$cpu_mhz" "$gpu_key" "$gpu_mhz" "$CLOCK_MARKER_END" >> "$destination_file"
}

render_tryboot_config() {
    local source_file=$1 destination_file=$2 cpu_mhz=$3 gpu_mhz=$4 gpu_key=$5 voltage_uv=$6 run_id=$7 ownership_token=$8
    local fan_policy=${9:-candidate-max}
    [[ $fan_policy == candidate-max || $fan_policy == normal ]] || return 1
    render_tryboot_reservation "$run_id" "$ownership_token" > "$destination_file" || return 1
    awk -v begin="$CLOCK_MARKER_BEGIN" -v end="$CLOCK_MARKER_END" '
        $0==begin {inside=1; next}
        $0==end {inside=0; next}
        !inside {print}
    ' "$source_file" >> "$destination_file" || return 1
    printf '\n%s\n# Run: %s\n[all]\nover_voltage_delta=%s\narm_freq=%s\n%s=%s\n' \
        "$CLOCK_MARKER_BEGIN" "$run_id" "$voltage_uv" "$cpu_mhz" "$gpu_key" "$gpu_mhz" >> "$destination_file" || return 1
    if [[ $fan_policy == candidate-max ]]; then
        printf '%s\ndtparam=fan_temp0=0\ndtparam=fan_temp0_speed=255\ndtparam=fan_temp1_speed=255\ndtparam=fan_temp2_speed=255\ndtparam=fan_temp3_speed=255\n' \
            "$CANDIDATE_FAN_COMMENT" >> "$destination_file" || return 1
    fi
    printf '%s\n# AUTOPIOVERCLOCK TRYBOOT COMPLETE: %s\n' "$CLOCK_MARKER_END" "$ownership_token" >> "$destination_file"
}

render_watchdog_config() {
    local source_file=$1 destination_file=$2 kernel_timeout=$3
    awk -v begin="$WATCHDOG_MARKER_BEGIN" -v end="$WATCHDOG_MARKER_END" '
        $0==begin {inside=1; next}
        $0==end {inside=0; next}
        !inside {print}
    ' "$source_file" > "$destination_file" || return 1
    printf '\n%s\n' "$WATCHDOG_MARKER_BEGIN" >> "$destination_file" || return 1
    if config_needs_global_header_at_eof "$destination_file"; then
        printf '[all]\n' >> "$destination_file" || return 1
    fi
    printf 'kernel_watchdog_timeout=%s\n%s\n' "$kernel_timeout" "$WATCHDOG_MARKER_END" >> "$destination_file"
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

alsa_playback_identity() {
    local asound_root=${1:-/proc/asound} card_dir pcm_dir card_id pcm_device pcm_id pcm_name info_file
    local -a identities=()
    for pcm_dir in "$asound_root"/card*/pcm*p; do
        [[ -d $pcm_dir ]] || continue
        card_dir=${pcm_dir%/*}
        info_file=$pcm_dir/info
        [[ -r $card_dir/id && -r $info_file ]] || continue
        card_id=$(tr -d '\r\n' < "$card_dir/id")
        pcm_device=$(basename -- "$pcm_dir")
        pcm_id=$(awk -F: '$1 ~ /^[[:space:]]*id[[:space:]]*$/ {sub(/^[^:]*:[[:space:]]*/, ""); print; exit}' "$info_file")
        pcm_name=$(awk -F: '$1 ~ /^[[:space:]]*name[[:space:]]*$/ {sub(/^[^:]*:[[:space:]]*/, ""); print; exit}' "$info_file")
        [[ -n $pcm_name ]] || pcm_name=$pcm_id
        [[ -n $card_id && -n $pcm_device && -n $pcm_id && -n $pcm_name ]] || continue
        identities+=("alsa:card=${card_id};device=${pcm_device};id=${pcm_id};name=${pcm_name}")
    done
    (( ${#identities[@]} > 0 )) || return 1
    printf '%s\n' "${identities[@]}" | LC_ALL=C sort -u | awk '
        NR > 1 {printf "|"}
        {printf "%s", $0}
        END {if (NR > 0) printf "\n"}
    '
}

audio_identity() {
    local asound_root=${1:-/proc/asound} identity='' inspect_output
    inspect_output=$(audio_inspect || true)
    if [[ -n $inspect_output ]]; then
        identity=$(sed -n 's/^[[:space:]]*[*]*[[:space:]]*node\.name[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' <<< "$inspect_output" | head -1)
        [[ -n $identity ]] || identity=$(head -1 <<< "$inspect_output" | tr -d '\r\n')
        [[ -n $identity ]] && { printf '%s' "$identity"; return 0; }
    fi
    alsa_playback_identity "$asound_root"
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
        [[ -n $output ]] && { printf '%s\n' "$output"; return 0; }
    fi
    if command -v pactl >/dev/null 2>&1; then
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

stress_ng_has_gpu_devnode() {
    command -v stress-ng >/dev/null 2>&1 &&
        stress-ng --help 2>&1 |
            grep -E -- '(^|[[:space:]])--gpu-devnode([[:space:]]|$)' >/dev/null
}

v3d_render_node() {
    local dri_root=${1:-/dev/dri} drm_class_root=${2:-/sys/class/drm}
    local node node_name driver_path driver_name uevent_file
    for node in "$dri_root"/renderD*; do
        [[ -e $node ]] || continue
        node_name=${node##*/}
        driver_path=$(readlink -f "$drm_class_root/${node_name}/device/driver" 2>/dev/null || true)
        driver_name=${driver_path##*/}
        uevent_file="$drm_class_root/${node_name}/device/uevent"
        if [[ $driver_name == v3d ]] || { [[ -r $uevent_file ]] && grep -qx 'DRIVER=v3d' "$uevent_file"; }; then
            printf '%s' "$node"
            return 0
        fi
    done
    return 1
}

stress_ng_gpu_strategy() {
    local render_node=$1 dri_root=${2:-/dev/dri} node only_node='' node_count=0
    stress_ng_has_gpu || return 1
    [[ -n $render_node && -e $render_node ]] || return 1
    if stress_ng_has_gpu_devnode; then
        printf 'explicit-v3d-device'
        return 0
    fi
    for node in "$dri_root"/renderD*; do
        [[ -e $node ]] || continue
        node_count=$((node_count + 1))
        only_node=$node
    done
    if (( node_count == 1 )) && [[ $only_node == "$render_node" ]]; then
        printf 'single-v3d-default'
        return 0
    fi
    return 1
}

# Read-only, compact live evidence for the controller-side status/summary
# commands. This deliberately avoids dependency, watchdog, or boot mutation.
cmd_status_snapshot() {
    local boot_config tryboot_config gpu_key=v3d_freq config_cpu config_gpu config_voltage measured_cpu measured_gpu
    local model compatible arch permanent_hash tryboot_exists tryboot_type tryboot_hash tryboot_flag throttle recent temp boot_id uptime_seconds
    boot_config=$(find_boot_config) || { emit_result HARNESS_FAILURE 'The permanent boot config could not be located.'; return 1; }
    tryboot_config="$(dirname "$boot_config")/tryboot.txt"
    audit_permanent_tuning_config "$boot_config"
    inspect_tryboot_path "$tryboot_config" tryboot_exists tryboot_type tryboot_hash
    model=$(tr -d '\000' < /proc/device-tree/model 2>/dev/null || true)
    compatible=$(tr '\000' ',' < /proc/device-tree/compatible 2>/dev/null || true)
    arch=$(uname -m 2>/dev/null || true)
    config_cpu=$(active_config_value arm_freq)
    config_gpu=$(active_config_value "$gpu_key")
    config_voltage=$(active_config_value over_voltage_delta)
    if [[ -z $config_voltage ]] && active_config_interface_ready; then config_voltage=0; fi
    measured_cpu=$(clock_mhz arm)
    measured_gpu=$(clock_mhz v3d)
    permanent_hash=$(permanent_config_snapshot_hash "$boot_config" || true)
    if [[ ! $PERMANENT_TUNING_CONFIG_HASH =~ ^[0-9a-f]{64}$ ||
          $permanent_hash != "$PERMANENT_TUNING_CONFIG_HASH" ]]; then
        permanent_hash=''
        PERMANENT_TUNING_PROVENANCE=ambiguous
        PERMANENT_TUNING_EVIDENCE='permanent-config-changed-during-live-snapshot'
    fi
    tryboot_flag=$(od -An -tx1 /proc/device-tree/chosen/bootloader/tryboot 2>/dev/null | tr -d ' \n' || true)
    [[ $tryboot_flag == 00000000 || $tryboot_flag == 00000001 ]] || tryboot_flag=unavailable
    throttle=$(permanent_throttle)
    recent=$(recent_throttle)
    temp=$(current_temp)
    boot_id=$(tr -d '\r\n' < /proc/sys/kernel/random/boot_id 2>/dev/null || true)
    uptime_seconds=$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null || true)

    emit_data PROFILE debian
    emit_data MODEL "$model"
    emit_data COMPATIBLE "$compatible"
    emit_data ARCH "$arch"
    emit_data BOOT_CONFIG "$boot_config"
    emit_data TRYBOOT_CONFIG "$tryboot_config"
    emit_data GPU_KEY "$gpu_key"
    emit_data CONFIG_CPU "$config_cpu"
    emit_data CONFIG_GPU "$config_gpu"
    emit_data CONFIG_VOLTAGE "$config_voltage"
    emit_data MEASURED_CPU "$measured_cpu"
    emit_data MEASURED_GPU "$measured_gpu"
    emit_data PERMANENT_HASH "$permanent_hash"
    emit_data PERMANENT_TUNING_PROVENANCE "$PERMANENT_TUNING_PROVENANCE"
    emit_data PERMANENT_TUNING_EVIDENCE "$PERMANENT_TUNING_EVIDENCE"
    emit_data TRYBOOT_EXISTS "$tryboot_exists"
    emit_data TRYBOOT_TYPE "$tryboot_type"
    emit_data TRYBOOT_HASH "$tryboot_hash"
    emit_data TRYBOOT_FLAG "$tryboot_flag"
    emit_data THROTTLED "$throttle"
    emit_data RECENT_THROTTLED "$recent"
    emit_data TEMP "$temp"
    emit_data BOOT_ID "$boot_id"
    emit_data UPTIME_SECONDS "$uptime_seconds"

    [[ -n $model && -n $compatible && -n $arch &&
       $config_cpu =~ ^[0-9]+$ && $config_gpu =~ ^[0-9]+$ && $config_voltage =~ ^-?[0-9]+$ &&
       $permanent_hash =~ ^[0-9a-f]{64}$ ]] || {
        emit_result HARNESS_FAILURE 'The live clock/config snapshot is incomplete.'
        return 1
    }
    emit_result PASS 'Live clock/config snapshot completed.'
}

cmd_discover() {
    local boot_config tryboot_config boot_mount model compatible os_id os_version gpu_key normal_cpu normal_gpu normal_voltage normal_voltage_source
    local boot_watchdog kernel_watchdog runtime_watchdog watchdog_device watchdog_runtime_timeout_value watchdog_owner root_device boot_source display_baseline display_present audio_baseline permanent_hash
    local stress_ng_binary stress_ng_gpu_available stress_ng_gpu_strategy_value render_node tryboot_exists tryboot_type tryboot_hash
    local network_root=/var/lib/autopioverclock/network-watchdog network_config network_keeper network_service
    local observer_config observer_keeper observer_service
    local network_kind='' network_target='' network_config_hash='' network_keeper_hash='' network_service_hash='' network_service_active=0
    local network_install_run_id='' network_install_backup='' network_fields=''
    local native_network_watchdog_present=0 native_network_watchdog_ready=0 native_network_watchdog_target=''
    local native_watchdog_service_active=0 native_watchdog_config_inspected=0
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
    render_node=$(v3d_render_node || true)
    stress_ng_gpu_strategy_value=$([[ -n $stress_ng_binary && -n $render_node ]] && stress_ng_gpu_strategy "$render_node" || true)
    stress_ng_gpu_available=$([[ -n $stress_ng_gpu_strategy_value ]] && printf 1 || printf 0)
    fan_pwm_snapshot >/dev/null 2>&1 || true
    observer_config=$network_root/observer.conf
    observer_keeper=/usr/local/lib/autopioverclock/network-watchdog-observer.py
    observer_service=/etc/systemd/system/autopioverclock-network-watchdog-observer.service
    network_config=$network_root/watchdog.conf
    network_keeper=/usr/local/lib/autopioverclock/network-watchdog-keeper.py
    network_service=/etc/systemd/system/autopioverclock-network-watchdog.service
    if [[ -f $observer_config && ! -L $observer_config ]] &&
       grep -Fq 'AUTOPIOVERCLOCK MANAGED DEBIAN NETWORK WATCHDOG OBSERVER' "$observer_config"; then
        network_kind=debian-watchdog-observer
        network_fields=$(debian_network_watchdog_observer_config_fields "$observer_config" || true)
        IFS=$'\t' read -r network_target network_install_run_id <<<"$network_fields"
        network_config_hash=$(sha256sum "$observer_config" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
        if [[ -f $observer_keeper && ! -L $observer_keeper ]]; then network_keeper_hash=$(sha256sum "$observer_keeper" 2>/dev/null | awk 'NR == 1 {print $1}' || true); fi
        if [[ -f $observer_service && ! -L $observer_service ]]; then network_service_hash=$(sha256sum "$observer_service" 2>/dev/null | awk 'NR == 1 {print $1}' || true); fi
        if [[ -n $network_target ]] && debian_network_watchdog_observer_service_ready "$observer_keeper" "$observer_service"; then
            network_service_active=1
        fi
    elif [[ -f $network_config && ! -L $network_config ]] &&
       grep -Fq 'AUTOPIOVERCLOCK MANAGED DEBIAN NETWORK WATCHDOG' "$network_config"; then
        network_kind=debian-systemd-companion
        network_fields=$(debian_network_watchdog_config_fields "$network_config" || true)
        IFS=$'\t' read -r network_target network_install_run_id <<<"$network_fields"
        network_config_hash=$(sha256sum "$network_config" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
        if [[ -f $network_keeper && ! -L $network_keeper ]]; then network_keeper_hash=$(sha256sum "$network_keeper" 2>/dev/null | awk 'NR == 1 {print $1}' || true); fi
        if [[ -f $network_service && ! -L $network_service ]]; then network_service_hash=$(sha256sum "$network_service" 2>/dev/null | awk 'NR == 1 {print $1}' || true); fi
        if [[ -n $network_target ]] && debian_network_watchdog_service_ready "$network_keeper" "$network_config" "$network_service"; then
            network_service_active=1
        fi
    fi
    if [[ -n $network_install_run_id ]]; then
        network_install_backup=$(debian_network_watchdog_backup_for_run "$network_kind" "$network_install_run_id" || true)
    fi
    if debian_native_watchdog_service_active; then
        native_watchdog_service_active=1
        if debian_native_network_watchdog_config_path >/dev/null; then
            native_watchdog_config_inspected=1
        fi
        if debian_native_network_watchdog_blocks_fallback; then native_network_watchdog_present=1; fi
    fi
    native_network_watchdog_target=$(debian_native_network_watchdog_target || true)
    [[ -n $native_network_watchdog_target ]] && native_network_watchdog_ready=1

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
    emit_data NETWORK_WATCHDOG_KIND "$network_kind"
    emit_data NETWORK_WATCHDOG_TARGET "$network_target"
    emit_data NETWORK_WATCHDOG_CONFIG_HASH "$network_config_hash"
    emit_data NETWORK_WATCHDOG_KEEPER_HASH "$network_keeper_hash"
    emit_data NETWORK_WATCHDOG_SERVICE_HASH "$network_service_hash"
    emit_data NETWORK_WATCHDOG_SERVICE_ACTIVE "$network_service_active"
    emit_data NETWORK_WATCHDOG_INSTALL_RUN_ID "$network_install_run_id"
    emit_data NETWORK_WATCHDOG_INSTALL_BACKUP "$network_install_backup"
    emit_data NATIVE_NETWORK_WATCHDOG_PRESENT "$native_network_watchdog_present"
    emit_data NATIVE_NETWORK_WATCHDOG_READY "$native_network_watchdog_ready"
    emit_data NATIVE_NETWORK_WATCHDOG_TARGET "$native_network_watchdog_target"
    emit_data NATIVE_WATCHDOG_SERVICE_ACTIVE "$native_watchdog_service_active"
    emit_data NATIVE_WATCHDOG_CONFIG_INSPECTED "$native_watchdog_config_inspected"
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
    emit_data STRESS_NG_GPU_STRATEGY "$stress_ng_gpu_strategy_value"
    emit_data DRM_RENDER_NODE "$render_node"
    emit_data FAN_PWM_STATUS "$FAN_PWM_LAST_STATUS"
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
    if [[ $mode == graphical ]]; then
        check_display "$baseline" || { APPLICATION_READINESS_LAST_FAILURE=display; return 1; }
    fi
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
    elif [[ $mode == graphical ]]; then
        current_audio=$(audio_identity || true)
        APPLICATION_READINESS_LAST_AUDIO=$current_audio
        if [[ -z $audio_baseline ]]; then
            printf '%s\n' 'WARNING: No automatically captured graphical audio baseline is available; continuing because audio_sink_pattern is not configured.' >&2
        elif [[ -z $current_audio ]]; then
            printf 'WARNING: The automatically captured graphical audio output %s is not currently observable; continuing because audio_sink_pattern is not configured.\n' "$audio_baseline" >&2
        elif [[ $current_audio != "$audio_baseline" ]]; then
            printf 'WARNING: The automatically captured graphical audio output changed from %s to %s; continuing because audio_sink_pattern is not configured.\n' "$audio_baseline" "$current_audio" >&2
        fi
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
        audio-match) emit_result HARNESS_FAILURE "Default audio sink does not match the configured requirement in $context." "$temp" ;;
        audio-baseline-missing) emit_result HARNESS_FAILURE "No Debian audio-output baseline was supplied for graphical validation in $context." "$temp" ;;
        audio-unavailable) emit_result HARNESS_FAILURE "The captured audio output is unavailable in $context." "$temp" ;;
        audio-changed) emit_result HARNESS_FAILURE "The captured audio output changed in $context: expected $audio_baseline, found ${APPLICATION_READINESS_LAST_AUDIO:-missing}." "$temp" ;;
        display) emit_result BOOT_FAILURE "Graphical baseline did not recover within 60 seconds in $context." "$temp" ;;
        *) emit_result BOOT_FAILURE "Application readiness did not recover within 60 seconds in $context." "$temp" ;;
    esac
}

cmd_health() {
    local expected_cpu=$1 expected_gpu=$2 gpu_key=$3 expected_voltage=$4 max_temp=$5 mode=$6 baseline=$7
    local required_processes=$8 required_services=$9 audio_match=${10} extra_ping=${11} health_hook=${12} expected_hash=${13} context=${14} throttle_baseline=${15:-throttled=0x0} audio_baseline=${16:-} fan_policy=${17:-normal}
    local boot_config active_cpu active_gpu active_voltage throttle temp errors permanent_hash test_file
    boot_config=$(find_boot_config) || { emit_result PREFLIGHT_FAILURE 'Boot config is missing.'; return 1; }
    permanent_hash=$(sha256sum "$boot_config" | awk '{print $1}')
    [[ -z $expected_hash || $permanent_hash == "$expected_hash" ]] || { emit_result RECOVERY_FAILURE "Permanent config hash changed during $context."; return 1; }
    active_cpu=$(active_config_value arm_freq)
    active_gpu=$(active_config_value "$gpu_key")
    active_voltage=$(active_config_value over_voltage_delta)
    [[ -n $active_voltage ]] || { active_config_interface_ready && active_voltage=0; }
    [[ -n $active_cpu && -n $active_gpu && -n $active_voltage ]] || { emit_result HARNESS_FAILURE "Active CPU/GPU/voltage configuration telemetry is unavailable in $context."; return 1; }
    if [[ $active_cpu != "$expected_cpu" && $active_gpu != "$expected_gpu" ]]; then
        emit_result BOOT_FAILURE "CPU and GPU config mismatch in $context: expected $expected_cpu/$expected_gpu, found ${active_cpu:-missing}/${active_gpu:-missing}."
        return 1
    fi
    [[ $active_cpu == "$expected_cpu" ]] || { emit_result BOOT_FAILURE "CPU config mismatch in $context: expected $expected_cpu, found ${active_cpu:-missing}."; return 1; }
    [[ $active_gpu == "$expected_gpu" ]] || { emit_result BOOT_FAILURE "GPU config mismatch in $context: expected $expected_gpu, found ${active_gpu:-missing}."; return 1; }
    [[ $active_voltage == "$expected_voltage" ]] || { emit_result BOOT_FAILURE "Voltage delta mismatch in $context: expected $expected_voltage, found $active_voltage."; return 1; }
    case $fan_policy in
        normal) ;;
        candidate-max)
            candidate_fan_max_wait || { emit_result HARNESS_FAILURE "Candidate fan max-speed proof failed in $context: ${FAN_PWM_LAST_REASON:-unknown fan telemetry failure}"; return 1; }
            ;;
        *) emit_result HARNESS_FAILURE "Unknown fan policy in $context: $fan_policy"; return 1 ;;
    esac
    watchdog_health_ready "$boot_config" || { emit_result BOOT_FAILURE "Watchdog recovery chain failed in $context: $WATCHDOG_LAST_REASON"; return 1; }
    throttle=$(current_throttle)
    throttle_word "$throttle" >/dev/null || { emit_result HARNESS_FAILURE "Malformed throttle telemetry in $context: ${throttle:-missing}"; return 1; }
    throttle_clean_relative "$throttle" "$throttle_baseline" || { printf '%s\n' "$throttle"; emit_result STABILITY_FAILURE "Current or new throttle/power flag in $context: $throttle (baseline $throttle_baseline)"; return 1; }
    temp=$(current_temp)
    [[ -n $temp ]] || { emit_result HARNESS_FAILURE "Temperature unavailable in $context."; return 1; }
    awk -v t="$temp" -v m="$max_temp" 'BEGIN{exit !(t<m)}' || { emit_result STABILITY_FAILURE "Temperature ${temp}C reached the ${max_temp}C ceiling in $context." "$temp"; return 1; }
    errors=$(kernel_error_lines 1 | tail -40 || true)
    if [[ -n $errors ]]; then printf '%s\n' "$errors"; emit_result STABILITY_FAILURE "Current-boot kernel, power, GPU, USB, storage, or filesystem error in $context." "$temp"; return 1; fi
    test_file=/tmp/autopioverclock-write-test-$$
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
    if [[ $fan_policy == candidate-max ]] && ! candidate_fan_max_ready; then
        emit_result HARNESS_FAILURE "Candidate fan max-speed proof failed after application readiness in $context: ${FAN_PWM_LAST_REASON:-unknown fan telemetry failure}"
        return 1
    fi
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
    [[ $fan_policy != candidate-max ]] || printf 'FAN_COOLING_POLICY=candidate-max FAN_PWM_STATUS=%s\n' "$FAN_PWM_LAST_STATUS"
    vcgencmd measure_clock arm 2>/dev/null || true
    vcgencmd measure_clock v3d 2>/dev/null || true
    vcgencmd pmic_read_adc EXT5V_V 2>/dev/null || true
    emit_result PASS "Health passed in $context." "$temp"
}

cmd_plan_candidate() {
    local boot_config=$1 tryboot_config=$2 gpu_key=$3 cpu_mhz=$4 gpu_mhz=$5 voltage_uv=$6 expected_hash=$7 run_id=$8 ownership_token=$9
    local fan_policy=${10:-candidate-max}
    local current_hash temporary_file rendered_hash reservation_file reservation_hash quarantine_path
    tryboot_path_allowed "$boot_config" "$tryboot_config" || { emit_result RECOVERY_FAILURE 'The requested tryboot path is outside the permitted boot-config directory.'; return 1; }
    [[ $ownership_token =~ ^[0-9a-f]{64}$ ]] || { emit_result HARNESS_FAILURE 'Candidate planning lacks a valid random ownership token.'; return 1; }
    [[ $fan_policy == candidate-max || $fan_policy == normal ]] || { emit_result HARNESS_FAILURE 'Candidate planning contains an invalid fan policy.'; return 1; }
    quarantine_path=$(tryboot_quarantine_path "$tryboot_config" "$ownership_token")
    [[ ! -e $quarantine_path && ! -L $quarantine_path ]] || { emit_result RECOVERY_FAILURE 'The token-specific tryboot quarantine path is already occupied.'; return 1; }
    current_hash=$(sha256sum "$boot_config" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    [[ $current_hash == "$expected_hash" ]] || { emit_result RECOVERY_FAILURE 'Permanent config hash changed before candidate planning.'; return 1; }
    temporary_file=$(mktemp /tmp/autopioverclock-plan.XXXXXX) || { emit_result HARNESS_FAILURE 'Could not create candidate-plan temporary file.'; return 1; }
    reservation_file=$(mktemp /tmp/autopioverclock-reservation.XXXXXX) || { rm -f -- "$temporary_file"; emit_result HARNESS_FAILURE 'Could not create reservation-plan temporary file.'; return 1; }
    if ! render_tryboot_config "$boot_config" "$temporary_file" "$cpu_mhz" "$gpu_mhz" "$gpu_key" "$voltage_uv" "$run_id" "$ownership_token" "$fan_policy" \
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
    local fan_policy=${13:-candidate-max}
    local current_hash temporary_file rendered_hash installed_hash installed_path_hash reservation_hash tryboot_exists tryboot_type tryboot_hash tryboot_fd
    tryboot_path_allowed "$boot_config" "$tryboot_config" || { emit_result RECOVERY_FAILURE 'The requested tryboot path is outside the permitted boot-config directory.'; return 1; }
    [[ $expected_tryboot_hash =~ ^[0-9a-f]{64}$ && $expected_reservation_hash =~ ^[0-9a-f]{64}$ && $ownership_token =~ ^[0-9a-f]{64}$ ]] || { emit_result HARNESS_FAILURE 'Candidate preparation lacks valid ownership evidence.'; return 1; }
    [[ $fan_policy == candidate-max || $fan_policy == normal ]] || { emit_result HARNESS_FAILURE 'Candidate preparation contains an invalid fan policy.'; return 1; }
    [[ $quarantine_path == "$(tryboot_quarantine_path "$tryboot_config" "$ownership_token")" && ! -e $quarantine_path && ! -L $quarantine_path ]] || { emit_result RECOVERY_FAILURE 'The tryboot quarantine path is invalid or occupied.'; return 1; }
    inspect_tryboot_path "$tryboot_config" tryboot_exists tryboot_type tryboot_hash
    [[ $tryboot_exists == 0 ]] || { emit_result RECOVERY_FAILURE "The tryboot path became occupied ($tryboot_type, hash $tryboot_hash); refusing to overwrite it."; return 1; }
    reset_recent_throttle >/dev/null || { emit_result HARNESS_FAILURE 'Could not clear and verify recent throttle history before candidate boot.'; return 1; }
    current_hash=$(sha256sum "$boot_config" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    [[ $current_hash == "$expected_hash" ]] || { emit_result RECOVERY_FAILURE 'Permanent config hash changed before candidate preparation.'; return 1; }
    temporary_file=$(mktemp /tmp/autopioverclock-tryboot.XXXXXX) || { emit_result HARNESS_FAILURE 'Could not create tryboot temporary file.'; return 1; }
    render_tryboot_config "$boot_config" "$temporary_file" "$cpu_mhz" "$gpu_mhz" "$gpu_key" "$voltage_uv" "$run_id" "$ownership_token" "$fan_policy" || { rm -f -- "$temporary_file"; emit_result HARNESS_FAILURE 'Could not render tryboot config.'; return 1; }
    rendered_hash=$(sha256sum "$temporary_file" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    [[ $rendered_hash == "$expected_tryboot_hash" ]] || { rm -f -- "$temporary_file"; emit_result RECOVERY_FAILURE 'Rendered tryboot config does not match the persisted ownership plan.'; return 1; }
    sync "$temporary_file" || { rm -f -- "$temporary_file"; emit_result HARNESS_FAILURE 'Could not durably stage rendered tryboot config.'; return 1; }
    set -o noclobber
    if ! { exec {tryboot_fd}> "$tryboot_config"; } 2>/dev/null; then
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

stress_completion_tolerance() {
    local duration=$1 tolerance
    tolerance=$((duration / 1000))
    (( tolerance < 3 )) && tolerance=3
    (( tolerance > 30 )) && tolerance=30
    printf '%s' "$tolerance"
}

# Keep individual stress tools inside conservative one-hour counters while the
# controller-visible gate remains one uninterrupted wall-clock interval.
stress_segment_limit() { printf '3600'; }

stress_segment_duration() {
    local remaining=$1 limit
    limit=$(stress_segment_limit) || return 1
    [[ $remaining =~ ^[1-9][0-9]*$ && $limit =~ ^[1-9][0-9]*$ ]] || return 1
    if (( remaining < limit )); then printf '%s' "$remaining"; else printf '%s' "$limit"; fi
}

launch_debian_cpu_segment() {
    local segment_duration=$1 output_file=$2 segment_number=$3
    printf '%s\n' "--- CPU segment ${segment_number}: ${segment_duration}s ---" >> "$output_file"
    stress-ng --cpu "$(nproc)" --cpu-method all --verify --timeout "${segment_duration}s" --metrics-brief >>"$output_file" 2>&1 &
    stress_cpu_pid=$!
}

launch_debian_gpu_segment() {
    local segment_duration=$1 output_file=$2 segment_number=$3 render_node=$4 gpu_strategy=$5
    printf '%s\n' "--- GPU segment ${segment_number}: ${segment_duration}s ---" >> "$output_file"
    case $gpu_strategy in
        explicit-v3d-device)
            { printf 'GPU_STRESS_STRATEGY=%s\n' "$gpu_strategy"; stress-ng --gpu 1 --gpu-devnode "$render_node" --verify --timeout "${segment_duration}s" --metrics-brief; } >>"$output_file" 2>&1 &
            ;;
        single-v3d-default)
            { printf 'GPU_STRESS_STRATEGY=%s\n' "$gpu_strategy"; stress-ng --gpu 1 --verify --timeout "${segment_duration}s" --metrics-brief; } >>"$output_file" 2>&1 &
            ;;
        *) return 1 ;;
    esac
    stress_gpu_pid=$!
}

cmd_stress() {
    local stress_kind=$1 duration=$2 max_temp=$3 mode=${4:-headless} baseline=${5:-} io_check=${6:-0} expected_cpu=${7:-0} expected_gpu=${8:-0} throttle_baseline=${9:-throttled=0x0} telemetry_interval=${10:-5} audio_baseline=${11:-} fan_policy=${12:-normal}
    local start_seconds expected_end hard_deadline now_seconds next_log max_seen=0 temp throttle new_errors
    local kernel_lines cpu_rc=0 gpu_rc=0 io_rc=0 failure_class='' failure_reason='' cpu_output gpu_output render_node gpu_strategy
    local arm_sample=0 gpu_sample=0 cpu_clock_seen=0 gpu_clock_seen=0 clock_tolerance=25
    local cpu_alive=0 gpu_alive=0 cpu_dead=0 gpu_dead=0 workloads_complete=0 telemetry_due=0 fan_status=normal-policy elapsed_sample=0
    local cpu_segment_duration=0 gpu_segment_duration=0 cpu_segment_end=0 gpu_segment_end=0
    local cpu_segment_number=0 gpu_segment_number=0 remaining=0 segment_tolerance=0 cpu_segment_bad=0 gpu_segment_bad=0
    : "$audio_baseline"
    [[ $telemetry_interval =~ ^[0-9]+$ ]] && (( telemetry_interval >= 1 && telemetry_interval <= 60 )) \
        || { emit_result HARNESS_FAILURE 'Telemetry interval must be an integer from 1 to 60 seconds.'; return 1; }
    case $fan_policy in
        normal) ;;
        candidate-max)
            candidate_fan_max_wait || { emit_result HARNESS_FAILURE "Candidate fan max-speed proof failed before stress: ${FAN_PWM_LAST_REASON:-unknown fan telemetry failure}"; return 1; }
            fan_status=$FAN_PWM_LAST_STATUS
            ;;
        *) emit_result HARNESS_FAILURE "Unknown fan policy for stress: $fan_policy"; return 1 ;;
    esac
    command -v stress-ng >/dev/null 2>&1 || { emit_result HARNESS_FAILURE 'stress-ng is not installed.'; return 1; }
    stress_cpu_pid=''; stress_gpu_pid=''; stress_io_pid=''; stress_work_dir=''; stress_io_file=''
    stress_work_dir=$(mktemp -d /tmp/autopioverclock-stress.XXXXXX) || { emit_result HARNESS_FAILURE 'Could not create stress workspace.'; return 1; }
    cpu_output="$stress_work_dir/cpu.log"; gpu_output="$stress_work_dir/gpu.log"; stress_io_file=/tmp/autopioverclock-io-$$
    trap cleanup_stress EXIT
    trap 'stress_signal_cleanup 130' INT
    trap 'stress_signal_cleanup 143' TERM
    trap 'stress_signal_cleanup 129' HUP
    kernel_lines=$(kernel_log | wc -l)
    start_seconds=$SECONDS; expected_end=$((start_seconds + duration)); hard_deadline=$((expected_end + 60)); next_log=$start_seconds
    : > "$cpu_output"; : > "$gpu_output"
    case $stress_kind in
        cpu|combined)
            cpu_segment_duration=$(stress_segment_duration "$duration") || { emit_result HARNESS_FAILURE 'Could not derive a safe CPU stress segment.'; return 1; }
            cpu_segment_number=1
            launch_debian_cpu_segment "$cpu_segment_duration" "$cpu_output" "$cpu_segment_number"
            cpu_segment_end=$((start_seconds + cpu_segment_duration))
            ;;
    esac
    case $stress_kind in
        gpu|combined)
            stress_ng_has_gpu || { emit_result HARNESS_FAILURE 'Installed stress-ng does not provide the GPU stressor.'; return 1; }
            render_node=$(v3d_render_node || true)
            [[ -n $render_node ]] || { emit_result HARNESS_FAILURE 'No V3D DRM render node is available.'; return 1; }
            gpu_strategy=$(stress_ng_gpu_strategy "$render_node" || true)
            case $gpu_strategy in explicit-v3d-device|single-v3d-default) ;; *) emit_result HARNESS_FAILURE 'The installed stress-ng cannot select the V3D node and more than one DRM render node exists.'; return 1 ;; esac
            gpu_segment_duration=$(stress_segment_duration "$duration") || { emit_result HARNESS_FAILURE 'Could not derive a safe GPU stress segment.'; return 1; }
            gpu_segment_number=1
            launch_debian_gpu_segment "$gpu_segment_duration" "$gpu_output" "$gpu_segment_number" "$render_node" "$gpu_strategy" || { emit_result HARNESS_FAILURE 'Could not launch the GPU stress segment.'; return 1; }
            gpu_segment_end=$((start_seconds + gpu_segment_duration))
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
        # Reap every worker found dead in the same supervision poll. A clean
        # segment completion is accepted only near that segment's deadline,
        # then the domain is relaunched immediately for the shared remaining
        # wall time. Nonzero or genuinely early exits still fail at once.
        cpu_dead=0; gpu_dead=0; cpu_segment_bad=0; gpu_segment_bad=0
        [[ -n $stress_cpu_pid && $cpu_alive -eq 0 ]] && cpu_dead=1
        [[ -n $stress_gpu_pid && $gpu_alive -eq 0 ]] && gpu_dead=1
        if (( cpu_dead == 1 )); then
            if wait "$stress_cpu_pid"; then cpu_rc=0; else cpu_rc=$?; fi
            stress_cpu_pid=''
            segment_tolerance=$(stress_completion_tolerance "$cpu_segment_duration")
            (( cpu_rc != 0 || now_seconds < cpu_segment_end - segment_tolerance )) && cpu_segment_bad=1
        fi
        if (( gpu_dead == 1 )); then
            if wait "$stress_gpu_pid"; then gpu_rc=0; else gpu_rc=$?; fi
            stress_gpu_pid=''
            segment_tolerance=$(stress_completion_tolerance "$gpu_segment_duration")
            (( gpu_rc != 0 || now_seconds < gpu_segment_end - segment_tolerance )) && gpu_segment_bad=1
        fi
        if (( cpu_segment_bad == 1 || gpu_segment_bad == 1 )); then
            if (( cpu_segment_bad == 1 && gpu_segment_bad == 1 )); then
                if (( cpu_rc == 0 && gpu_rc == 0 )); then
                    failure_class=HARNESS_FAILURE
                    failure_reason='CPU and GPU stress exited early with rc=0/0.'
                elif (( cpu_rc != 0 && gpu_rc == 0 )); then
                    failure_class=STABILITY_FAILURE; failure_reason="CPU stress exited early with rc=$cpu_rc."
                elif (( cpu_rc == 0 && gpu_rc != 0 )); then
                    if grep -Eqi 'unrecognized option|invalid option|not found|No such file' "$gpu_output"; then failure_class=HARNESS_FAILURE; else failure_class=STABILITY_FAILURE; fi
                    failure_reason="GPU stress exited early with rc=$gpu_rc."
                else
                    failure_class=STABILITY_FAILURE; failure_reason="CPU and GPU stress exited early with rc=$cpu_rc/$gpu_rc."
                fi
            elif (( cpu_segment_bad == 1 )); then
                failure_class=$([[ $cpu_rc -eq 0 ]] && printf HARNESS_FAILURE || printf STABILITY_FAILURE)
                failure_reason="CPU stress exited early with rc=$cpu_rc."
            else
                if (( gpu_rc == 0 )) || grep -Eqi 'unrecognized option|invalid option|not found|No such file' "$gpu_output"; then failure_class=HARNESS_FAILURE; else failure_class=STABILITY_FAILURE; fi
                failure_reason="GPU stress exited early with rc=$gpu_rc."
            fi
            break
        fi
        if (( cpu_dead == 1 && now_seconds < expected_end )); then
            remaining=$((expected_end - now_seconds))
            cpu_segment_duration=$(stress_segment_duration "$remaining") || { failure_class=HARNESS_FAILURE; failure_reason='Could not derive the next CPU stress segment.'; break; }
            cpu_segment_number=$((cpu_segment_number + 1))
            launch_debian_cpu_segment "$cpu_segment_duration" "$cpu_output" "$cpu_segment_number"
            cpu_segment_end=$((now_seconds + cpu_segment_duration)); cpu_alive=1
        fi
        if (( gpu_dead == 1 && now_seconds < expected_end )); then
            remaining=$((expected_end - now_seconds))
            gpu_segment_duration=$(stress_segment_duration "$remaining") || { failure_class=HARNESS_FAILURE; failure_reason='Could not derive the next GPU stress segment.'; break; }
            gpu_segment_number=$((gpu_segment_number + 1))
            launch_debian_gpu_segment "$gpu_segment_duration" "$gpu_output" "$gpu_segment_number" "$render_node" "$gpu_strategy" || { failure_class=HARNESS_FAILURE; failure_reason='Could not launch the next GPU stress segment.'; break; }
            gpu_segment_end=$((now_seconds + gpu_segment_duration)); gpu_alive=1
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
            if [[ $fan_policy == candidate-max ]]; then
                if candidate_fan_max_ready; then fan_status=$FAN_PWM_LAST_STATUS
                else failure_class=HARNESS_FAILURE; failure_reason="Candidate fan max-speed proof failed during stress: ${FAN_PWM_LAST_REASON:-unknown fan telemetry failure}"; fi
            fi
            elapsed_sample=$((now_seconds - start_seconds))
            (( elapsed_sample > duration )) && elapsed_sample=$duration
            printf '%s temp=%sC arm=%sMHz v3d=%sMHz expected=%s/%s %s fan=%s elapsed=%s/%ss\n' "$(date '+%F %T')" "${temp:-unknown}" "$arm_sample" "$gpu_sample" "$expected_cpu" "$expected_gpu" "$throttle" "$fan_status" "$elapsed_sample" "$duration"
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
    local cpu_mhz=$1 gpu_mhz=$2 gpu_key=$3 voltage_uv=$4 run_id=$5 voltage_render_mode=${6:-explicit} boot_config
    boot_config=$(find_boot_config) || return 1
    render_clock_config "$boot_config" /dev/stdout "$cpu_mhz" "$gpu_mhz" "$gpu_key" "$voltage_uv" "$run_id" "$voltage_render_mode"
}

RESET_STOCK_LAST_REASON=''
RESET_STOCK_TRYBOOT_PATH=''
RESET_STOCK_TRYBOOT_HASH=''
RESET_STOCK_TRYBOOT_KIND=''
RESET_STOCK_TRYBOOT_RUN=''
RESET_STOCK_TRYBOOT_TOKEN=''
RESET_STOCK_BACKUP_DIR=/var/lib/autopioverclock/backups

reset_stock_safe_id() {
    local value=${1-}
    [[ $value =~ ^[A-Za-z0-9._-]+$ && $value != . && $value != .. && ${#value} -le 128 ]]
}

reset_stock_managed_block_valid() {
    local run_line=${1-} section_line=${2-} voltage_line='' cpu_line='' gpu_line='' managed_run
    case $# in
        4) cpu_line=$3; gpu_line=$4 ;;
        5) voltage_line=$3; cpu_line=$4; gpu_line=$5 ;;
        *) return 1 ;;
    esac
    [[ $run_line == '# Run: '* ]] || return 1
    managed_run=${run_line#\# Run: }
    reset_stock_safe_id "$managed_run" || return 1
    [[ $section_line == '[all]' ]] || return 1
    [[ -z $voltage_line || $voltage_line =~ ^over_voltage_delta=-?[0-9]+$ ]] || return 1
    [[ $cpu_line =~ ^arm_freq=[0-9]+$ ]] || return 1
    [[ $gpu_line =~ ^(gpu_freq|v3d_freq)=[0-9]+$ ]]
}

reset_stock_validate_config() {
    local config_file=$1 line semantic trimmed lower inside=0 marker_count=0
    local -a managed_lines=()
    RESET_STOCK_LAST_REASON=''
    [[ -f $config_file && ! -L $config_file && -r $config_file ]] || {
        RESET_STOCK_LAST_REASON='The permanent config is missing, unreadable, non-regular, or a symlink.'
        return 1
    }
    while IFS= read -r line || [[ -n $line ]]; do
        semantic=${line%$'\r'}
        if [[ $semantic == "$CLOCK_MARKER_BEGIN" ]]; then
            (( inside == 0 )) || { RESET_STOCK_LAST_REASON='The permanent config contains nested AutoPiOverclock clock markers.'; return 1; }
            marker_count=$((marker_count + 1))
            (( marker_count == 1 )) || { RESET_STOCK_LAST_REASON='The permanent config contains multiple AutoPiOverclock clock blocks.'; return 1; }
            inside=1
            managed_lines=()
            continue
        fi
        if [[ $semantic == "$CLOCK_MARKER_END" ]]; then
            (( inside == 1 )) || { RESET_STOCK_LAST_REASON='The permanent config contains an unmatched AutoPiOverclock clock end marker.'; return 1; }
            reset_stock_managed_block_valid "${managed_lines[@]}" || {
                RESET_STOCK_LAST_REASON='The permanent config contains a malformed AutoPiOverclock clock block; reset refuses to delete unknown content.'
                return 1
            }
            inside=0
            continue
        fi
        if [[ $semantic == *'AUTOPIOVERCLOCK MANAGED CLOCKS'* ]]; then
            RESET_STOCK_LAST_REASON='The permanent config contains a malformed AutoPiOverclock clock marker.'
            return 1
        fi
        if (( inside == 1 )); then
            managed_lines+=("$semantic")
            continue
        fi
        trimmed=${semantic#"${semantic%%[![:space:]]*}"}
        [[ -n $trimmed && $trimmed != \#* ]] || continue
        lower=${trimmed,,}
        if [[ $lower =~ ^include([[:space:]]|$) ]]; then
            RESET_STOCK_LAST_REASON='The permanent config contains an active include directive; reset cannot prove or safely rewrite the included configuration graph.'
            return 1
        fi
    done < "$config_file"
    (( inside == 0 )) || { RESET_STOCK_LAST_REASON='The permanent config contains an unmatched AutoPiOverclock clock begin marker.'; return 1; }
}

reset_stock_render_config() {
    local source_file=$1 destination_file=$2 rendered_file had_managed=0
    grep -Fqx -- "$CLOCK_MARKER_BEGIN" "$source_file" && had_managed=1
    rendered_file=$(mktemp /tmp/autopioverclock-reset-render.XXXXXX) || return 1
    awk -v begin="$CLOCK_MARKER_BEGIN" -v end="$CLOCK_MARKER_END" '
        function is_tuning_key(key) {
            key=tolower(key)
            return key=="arm_boost" || key=="force_turbo" || key=="initial_turbo" || key=="core_freq_fixed" ||
                   key ~ /_freq$/ || key ~ /_freq_min$/ || key ~ /^over_voltage/
        }
        {
            raw=$0
            semantic=$0
            sub(/\r$/, "", semantic)
            if (semantic==begin) {inside=1; next}
            if (semantic==end) {inside=0; print "[all]"; next}
            if (inside) next
            probe=semantic
            sub(/^[[:space:]]*/, "", probe)
            if (probe !~ /^#/ && probe ~ /^[[:alnum:]_]+[[:space:]]*=/) {
                key=probe
                sub(/[[:space:]]*=.*$/, "", key)
                if (is_tuning_key(key)) {
                    print "# AUTOPIOVERCLOCK-STOCK-DISABLED " raw
                    next
                }
            }
            print raw
        }
    ' "$source_file" > "$rendered_file" || { rm -f -- "$rendered_file"; return 1; }
    if (( had_managed == 1 )); then
        canonicalize_global_sections "$rendered_file" "$destination_file" 1 || { rm -f -- "$rendered_file"; return 1; }
    else
        cp -- "$rendered_file" "$destination_file" || { rm -f -- "$rendered_file"; return 1; }
    fi
    rm -f -- "$rendered_file"
}

reset_stock_tryboot_kind() {
    local tryboot_file=$1 required_suffix=${2-} marker run_line ownership_line run_id ownership_token
    local begin_count end_count run_count complete_count complete_line actual_content expected_content
    [[ -f $tryboot_file && ! -L $tryboot_file && -r $tryboot_file ]] || return 1
    marker=$(sed -n '1{s/\r$//;p;q;}' "$tryboot_file" 2>/dev/null || true)
    run_line=$(sed -n '2{s/\r$//;p;q;}' "$tryboot_file" 2>/dev/null || true)
    ownership_line=$(sed -n '3{s/\r$//;p;q;}' "$tryboot_file" 2>/dev/null || true)
    [[ $marker == "$TRYBOOT_RESERVATION_MARKER" && $run_line == '# Run: '* && $ownership_line == '# Ownership: '* ]] || return 1
    run_id=${run_line#\# Run: }
    ownership_token=${ownership_line#\# Ownership: }
    reset_stock_safe_id "$run_id" || return 1
    [[ $ownership_token =~ ^[0-9a-f]{64}$ ]] || return 1
    [[ -z $required_suffix || $required_suffix == "$ownership_token" ]] || return 1
    RESET_STOCK_TRYBOOT_RUN=$run_id
    RESET_STOCK_TRYBOOT_TOKEN=$ownership_token
    actual_content=$(<"$tryboot_file")
    expected_content=$(render_tryboot_reservation "$run_id" "$ownership_token")
    if [[ $actual_content == "$expected_content" ]]; then printf reservation; return 0; fi
    begin_count=$(grep -Fxc -- "$CLOCK_MARKER_BEGIN" "$tryboot_file" 2>/dev/null || true)
    end_count=$(grep -Fxc -- "$CLOCK_MARKER_END" "$tryboot_file" 2>/dev/null || true)
    run_count=$(grep -Fxc -- "# Run: $run_id" "$tryboot_file" 2>/dev/null || true)
    complete_line="# AUTOPIOVERCLOCK TRYBOOT COMPLETE: $ownership_token"
    complete_count=$(grep -Fc -- '# AUTOPIOVERCLOCK TRYBOOT COMPLETE:' "$tryboot_file" 2>/dev/null || true)
    [[ $begin_count == 1 && $end_count == 1 && $run_count == 2 ]] || return 1
    awk -v begin="$CLOCK_MARKER_BEGIN" -v end="$CLOCK_MARKER_END" -v run_line="# Run: $run_id" -v fan_comment="$CANDIDATE_FAN_COMMENT" '
        {
            line=$0; sub(/\r$/, "", line)
            if (line==begin) {if (inside || seen) exit 1; inside=1; seen=1; next}
            if (line==end) {if (!inside) exit 1; inside=0; ended=1; next}
            if (inside) {block[++count]=line}
        }
        END {
            if (!seen || inside || !ended || (count!=5 && count!=11)) exit 1
            if (block[1]!=run_line || block[2]!="[all]") exit 1
            if (block[3] !~ /^over_voltage_delta=-?[0-9]+$/) exit 1
            if (block[4] !~ /^arm_freq=[0-9]+$/) exit 1
            if (block[5] !~ /^(gpu_freq|v3d_freq)=[0-9]+$/) exit 1
            if (count==11 && (block[6]!=fan_comment ||
                              block[7]!="dtparam=fan_temp0=0" ||
                              block[8]!="dtparam=fan_temp0_speed=255" ||
                              block[9]!="dtparam=fan_temp1_speed=255" ||
                              block[10]!="dtparam=fan_temp2_speed=255" ||
                              block[11]!="dtparam=fan_temp3_speed=255")) exit 1
        }
    ' "$tryboot_file" || return 1
    if [[ $complete_count == 0 ]]; then
        printf managed
    elif [[ $complete_count == 1 ]] && grep -Fqx -- "$complete_line" "$tryboot_file"; then
        printf complete
    else
        return 1
    fi
}

reset_stock_scan_tryboot() {
    local boot_config=$1 boot_dir tryboot_file candidate suffix count=0 kind hash candidate_name reset_owner reset_run
    RESET_STOCK_LAST_REASON=''
    RESET_STOCK_TRYBOOT_PATH=''
    RESET_STOCK_TRYBOOT_HASH=''
    RESET_STOCK_TRYBOOT_KIND=''
    RESET_STOCK_TRYBOOT_RUN=''
    RESET_STOCK_TRYBOOT_TOKEN=''
    boot_dir=$(dirname "$boot_config")
    tryboot_file="$boot_dir/tryboot.txt"
    for candidate in "$tryboot_file" "$boot_dir"/.autopioverclock-remove-* "$boot_dir"/.autopioverclock-stock-reset-*; do
        [[ -e $candidate || -L $candidate ]] || continue
        count=$((count + 1))
        (( count == 1 )) || { RESET_STOCK_LAST_REASON='Multiple tryboot or quarantine paths exist; refusing ambiguous cleanup.'; return 1; }
        suffix=''
        case $candidate in
            "$tryboot_file") ;;
            "$boot_dir"/.autopioverclock-remove-*) suffix=${candidate#"$boot_dir/.autopioverclock-remove-"} ;;
            "$boot_dir"/.autopioverclock-stock-reset-*)
                candidate_name=${candidate#"$boot_dir/.autopioverclock-stock-reset-"}
                reset_owner=${candidate_name##*-}
                reset_run=${candidate_name%"-$reset_owner"}
                reset_stock_safe_id "$reset_run" || { RESET_STOCK_LAST_REASON="The stock-reset quarantine path at $candidate has an invalid reset ID; preserving it."; return 1; }
                suffix=$reset_owner
                ;;
        esac
        [[ -z $suffix || $suffix =~ ^[0-9a-f]{64}$ ]] || { RESET_STOCK_LAST_REASON="The tryboot quarantine path at $candidate has an invalid ownership suffix; preserving it."; return 1; }
        kind=$(reset_stock_tryboot_kind "$candidate" "$suffix" || true)
        [[ -n $kind ]] || { RESET_STOCK_LAST_REASON="The tryboot artifact at $candidate is foreign, malformed, changed, or a symlink; preserving it."; return 1; }
        RESET_STOCK_TRYBOOT_RUN=$(sed -n '2{s/\r$//;s/^# Run: //;p;q;}' "$candidate" 2>/dev/null || true)
        RESET_STOCK_TRYBOOT_TOKEN=$(sed -n '3{s/\r$//;s/^# Ownership: //;p;q;}' "$candidate" 2>/dev/null || true)
        reset_stock_safe_id "$RESET_STOCK_TRYBOOT_RUN" && [[ $RESET_STOCK_TRYBOOT_TOKEN =~ ^[0-9a-f]{64}$ ]] || { RESET_STOCK_LAST_REASON="The managed tryboot identity at $candidate is malformed; preserving it."; return 1; }
        hash=$(sha256sum "$candidate" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
        valid_sha256 "$hash" || { RESET_STOCK_LAST_REASON="The managed tryboot artifact at $candidate could not be hashed; preserving it."; return 1; }
        RESET_STOCK_TRYBOOT_PATH=$candidate
        RESET_STOCK_TRYBOOT_HASH=$hash
        RESET_STOCK_TRYBOOT_KIND=$kind
    done
}

reset_stock_prepare_backup_dir() {
    local root=$1 backup_dir="$1/backups"
    if [[ -L $root || ( -e $root && ! -d $root ) ]]; then RESET_STOCK_LAST_REASON="Unsafe reset backup root: $root"; return 1; fi
    [[ -d $root ]] || mkdir -- "$root" || { RESET_STOCK_LAST_REASON="Could not create reset backup root: $root"; return 1; }
    if [[ -L $backup_dir || ( -e $backup_dir && ! -d $backup_dir ) ]]; then RESET_STOCK_LAST_REASON="Unsafe reset backup directory: $backup_dir"; return 1; fi
    [[ -d $backup_dir ]] || mkdir -- "$backup_dir" || { RESET_STOCK_LAST_REASON="Could not create reset backup directory: $backup_dir"; return 1; }
    chmod 700 "$backup_dir" 2>/dev/null || true
    printf '%s' "$backup_dir"
}

reset_stock_backup_verified() {
    local source_file=$1 backup_file=$2 expected_hash=$3 temporary_file actual_hash
    [[ -f $source_file && ! -L $source_file ]] || return 1
    [[ ! -e $backup_file && ! -L $backup_file ]] || return 1
    temporary_file="${backup_file}.tmp-${BASHPID}"
    [[ ! -e $temporary_file && ! -L $temporary_file ]] || return 1
    cp -a -- "$source_file" "$temporary_file" || { rm -f -- "$temporary_file"; return 1; }
    actual_hash=$(sha256sum "$temporary_file" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    [[ $actual_hash == "$expected_hash" ]] || { rm -f -- "$temporary_file"; return 1; }
    sync "$temporary_file" || { rm -f -- "$temporary_file"; return 1; }
    mv -n -- "$temporary_file" "$backup_file" || { rm -f -- "$temporary_file"; return 1; }
    [[ ! -e $temporary_file && ! -L $temporary_file && -f $backup_file && ! -L $backup_file ]] || { rm -f -- "$temporary_file"; return 1; }
    actual_hash=$(sha256sum "$backup_file" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    [[ $actual_hash == "$expected_hash" ]] || return 1
    sync "$backup_file"
}

reset_stock_remove_tryboot() {
    local boot_config=$1 reset_id=$2 boot_dir quarantine_path moved_kind moved_hash required_suffix=''
    [[ -n $RESET_STOCK_TRYBOOT_PATH ]] || return 0
    boot_dir=$(dirname "$boot_config")
    quarantine_path="$boot_dir/.autopioverclock-stock-reset-${reset_id}-${RESET_STOCK_TRYBOOT_TOKEN}"
    [[ ! -e $quarantine_path && ! -L $quarantine_path ]] || { RESET_STOCK_LAST_REASON='The reset tryboot quarantine path is already occupied.'; return 1; }
    case $RESET_STOCK_TRYBOOT_PATH in
        "$boot_dir/tryboot.txt") ;;
        "$boot_dir"/.autopioverclock-remove-*) required_suffix=${RESET_STOCK_TRYBOOT_PATH#"$boot_dir/.autopioverclock-remove-"} ;;
        "$boot_dir"/.autopioverclock-stock-reset-*) required_suffix=${RESET_STOCK_TRYBOOT_PATH##*-} ;;
        *) RESET_STOCK_LAST_REASON='The planned reset tryboot source path is outside the approved lifecycle paths.'; return 1 ;;
    esac
    moved_kind=$(reset_stock_tryboot_kind "$RESET_STOCK_TRYBOOT_PATH" "$required_suffix" 2>/dev/null || true)
    moved_hash=$(sha256sum "$RESET_STOCK_TRYBOOT_PATH" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    [[ $moved_kind == "$RESET_STOCK_TRYBOOT_KIND" && $moved_hash == "$RESET_STOCK_TRYBOOT_HASH" ]] || { RESET_STOCK_LAST_REASON='The managed tryboot artifact changed at the reset mutation boundary.'; return 1; }
    mv -n -- "$RESET_STOCK_TRYBOOT_PATH" "$quarantine_path" || { RESET_STOCK_LAST_REASON='Could not quarantine the managed tryboot artifact for verified removal.'; return 1; }
    [[ ! -e $RESET_STOCK_TRYBOOT_PATH && ! -L $RESET_STOCK_TRYBOOT_PATH ]] || { RESET_STOCK_LAST_REASON='The managed tryboot path remained after its no-clobber quarantine move.'; return 1; }
    moved_kind=$(reset_stock_tryboot_kind "$quarantine_path" || true)
    moved_hash=$(sha256sum "$quarantine_path" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    [[ $moved_kind == "$RESET_STOCK_TRYBOOT_KIND" && $moved_hash == "$RESET_STOCK_TRYBOOT_HASH" ]] || { RESET_STOCK_LAST_REASON="The reset tryboot quarantine failed ownership verification; preserving $quarantine_path."; return 1; }
    sync || { RESET_STOCK_LAST_REASON="Could not sync the reset tryboot quarantine; preserving $quarantine_path."; return 1; }
    rm -f -- "$quarantine_path" || { RESET_STOCK_LAST_REASON="Could not remove the verified reset tryboot quarantine; preserving $quarantine_path."; return 1; }
    sync || { RESET_STOCK_LAST_REASON='Could not sync managed tryboot removal.'; return 1; }
}

reset_stock_no_artifacts() {
    local boot_config=$1 live_flag
    live_flag=$(od -An -tx1 /proc/device-tree/chosen/bootloader/tryboot 2>/dev/null | tr -d ' \n' || true)
    [[ $live_flag == 00000000 ]] || return 1
    reset_stock_paths_clear "$boot_config"
}

reset_stock_paths_clear() {
    local boot_config=$1 tryboot_config path exists _type _hash
    tryboot_config="$(dirname "$boot_config")/tryboot.txt"
    inspect_tryboot_path "$tryboot_config" exists _type _hash
    [[ $exists == 0 ]] || return 1
    for path in "$(dirname "$boot_config")"/.autopioverclock-remove-*; do
        [[ ! -e $path && ! -L $path ]] || return 1
    done
    for path in "$(dirname "$boot_config")"/.autopioverclock-stock-reset-*; do
        [[ ! -e $path && ! -L $path ]] || return 1
    done
}

reset_stock_replace_verified() {
    local source_file=$1 destination_file=$2 expected_source_hash=$3 expected_destination_hash=$4 reset_id=$5
    local temporary_file='' actual_hash destination_hash
    valid_sha256 "$expected_source_hash" || return 1
    valid_sha256 "$expected_destination_hash" || return 1
    reset_stock_safe_id "$reset_id" || return 1
    [[ -f $source_file && ! -L $source_file && -f $destination_file && ! -L $destination_file ]] || return 1
    actual_hash=$(sha256sum "$source_file" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    [[ $actual_hash == "$expected_source_hash" ]] || return 1
    destination_hash=$(sha256sum "$destination_file" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    [[ $destination_hash == "$expected_destination_hash" ]] || return 1
    temporary_file=$(mktemp "${destination_file}.autopioverclock-reset-${reset_id}.XXXXXX") || return 1
    [[ -f $temporary_file && ! -L $temporary_file ]] || { rm -f -- "$temporary_file"; return 1; }
    cp -a -- "$source_file" "$temporary_file" || { rm -f -- "$temporary_file"; return 1; }
    actual_hash=$(sha256sum "$temporary_file" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    [[ $actual_hash == "$expected_source_hash" ]] || { rm -f -- "$temporary_file"; return 1; }
    sync "$temporary_file" || { rm -f -- "$temporary_file"; return 1; }
    [[ -f $destination_file && ! -L $destination_file ]] || { rm -f -- "$temporary_file"; return 1; }
    destination_hash=$(sha256sum "$destination_file" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    [[ $destination_hash == "$expected_destination_hash" ]] || { rm -f -- "$temporary_file"; return 1; }
    mv -f -- "$temporary_file" "$destination_file" || { rm -f -- "$temporary_file"; return 1; }
    sync "$destination_file" || return 1
    actual_hash=$(sha256sum "$destination_file" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    [[ $actual_hash == "$expected_source_hash" ]]
}

cmd_reset_stock() {
    local expected_old_hash=$1 reset_id=$2 boot_config old_hash new_hash disabled_keys reset_timestamp backup_dir backup_file tryboot_backup=''
    local rendered_file installed_hash tryboot_flag current_hash
    valid_sha256 "$expected_old_hash" || { emit_result APPLY_FAILURE 'Stock reset received a malformed expected permanent-config hash.'; return 1; }
    reset_stock_safe_id "$reset_id" || { emit_result APPLY_FAILURE 'Stock reset received an unsafe reset/run ID.'; return 1; }
    boot_config=$(find_boot_config) || { emit_result APPLY_FAILURE 'Raspberry Pi boot config was not found for stock reset.'; return 1; }
    reset_stock_validate_config "$boot_config" || { emit_result APPLY_FAILURE "$RESET_STOCK_LAST_REASON"; return 1; }
    old_hash=$(sha256sum "$boot_config" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    [[ $old_hash == "$expected_old_hash" ]] || { emit_result APPLY_FAILURE 'Permanent config changed before stock-reset planning.'; return 1; }
    if ! disabled_keys=$(permanent_tuning_override_evidence "$boot_config"); then
        emit_result APPLY_FAILURE "Permanent tuning audit was ambiguous before reset (${disabled_keys:-unknown audit error})."
        return 1
    fi
    [[ -n $disabled_keys ]] || disabled_keys=none
    rendered_file=$(mktemp /tmp/autopioverclock-stock-reset.XXXXXX) || { emit_result APPLY_FAILURE 'Could not create the stock-reset rendering file.'; return 1; }
    if ! reset_stock_render_config "$boot_config" "$rendered_file"; then rm -f -- "$rendered_file"; emit_result APPLY_FAILURE 'Could not render the stock permanent config.'; return 1; fi
    new_hash=$(sha256sum "$rendered_file" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    if ! valid_sha256 "$new_hash"; then rm -f -- "$rendered_file"; emit_result APPLY_FAILURE 'Could not hash the rendered stock permanent config.'; return 1; fi
    if ! chmod --reference="$boot_config" "$rendered_file" 2>/dev/null && ! chmod 644 "$rendered_file"; then rm -f -- "$rendered_file"; emit_result APPLY_FAILURE 'Could not preserve permanent-config permissions in the stock rendering.'; return 1; fi
    audit_permanent_tuning_config "$rendered_file"
    if [[ $PERMANENT_TUNING_PROVENANCE != verified-default || $PERMANENT_TUNING_EVIDENCE != none || $PERMANENT_TUNING_CONFIG_HASH != "$new_hash" ]]; then
        rm -f -- "$rendered_file"; emit_result APPLY_FAILURE 'Rendered stock config did not pass the explicit-tuning provenance audit.'; return 1
    fi
    tryboot_flag=$(od -An -tx1 /proc/device-tree/chosen/bootloader/tryboot 2>/dev/null | tr -d ' \n' || true)
    reset_stock_scan_tryboot "$boot_config" || { rm -f -- "$rendered_file"; emit_result APPLY_FAILURE "$RESET_STOCK_LAST_REASON"; return 1; }
    case $tryboot_flag in
        00000000) ;;
        # A previous reset may have removed its owned candidate and then lost
        # the controller before issuing the normal reboot. With no staged or
        # quarantined path left to delete, rewriting the backed-up permanent
        # config to stock and rebooting is the safe, idempotent recovery.
        00000001) ;;
        *) rm -f -- "$rendered_file"; emit_result APPLY_FAILURE "Stock reset requires a readable normal/tryboot state; found ${tryboot_flag:-unreadable}."; return 1 ;;
    esac
    backup_dir=$(reset_stock_prepare_backup_dir "${RESET_STOCK_BACKUP_DIR%/backups}") || { rm -f -- "$rendered_file"; emit_result APPLY_FAILURE "$RESET_STOCK_LAST_REASON"; return 1; }
    reset_timestamp=$(date -u '+%Y%m%dT%H%M%SZ') || { rm -f -- "$rendered_file"; emit_result APPLY_FAILURE 'Could not timestamp the stock-reset backup.'; return 1; }
    backup_file="$backup_dir/config-${reset_timestamp}-reset-${reset_id}.txt"
    reset_stock_backup_verified "$boot_config" "$backup_file" "$old_hash" || { rm -f -- "$rendered_file"; emit_result APPLY_FAILURE 'Could not create a verified no-clobber permanent-config reset backup.'; return 1; }
    if [[ -n $RESET_STOCK_TRYBOOT_PATH ]]; then
        tryboot_backup="$backup_dir/tryboot-${reset_timestamp}-reset-${reset_id}-${RESET_STOCK_TRYBOOT_TOKEN}.txt"
        reset_stock_backup_verified "$RESET_STOCK_TRYBOOT_PATH" "$tryboot_backup" "$RESET_STOCK_TRYBOOT_HASH" || { rm -f -- "$rendered_file"; emit_result APPLY_FAILURE 'Could not create a verified no-clobber managed-tryboot reset backup.'; return 1; }
    fi
    current_hash=$(sha256sum "$boot_config" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    if [[ $current_hash != "$old_hash" ]] || ! reset_stock_validate_config "$boot_config"; then rm -f -- "$rendered_file"; emit_result APPLY_FAILURE 'Permanent config changed at the stock-reset mutation boundary.'; return 1; fi
    if ! reset_stock_remove_tryboot "$boot_config" "$reset_id"; then rm -f -- "$rendered_file"; emit_result APPLY_FAILURE "$RESET_STOCK_LAST_REASON"; return 1; fi
    reset_stock_paths_clear "$boot_config" || { rm -f -- "$rendered_file"; emit_result APPLY_FAILURE 'Tryboot evidence remained after verified stock-reset cleanup.'; return 1; }
    if [[ $new_hash != "$old_hash" ]] && ! reset_stock_replace_verified "$rendered_file" "$boot_config" "$new_hash" "$old_hash" "$reset_id"; then
        installed_hash=$(sha256sum "$boot_config" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
        rm -f -- "$rendered_file"
        if [[ $installed_hash == "$new_hash" ]] && reset_stock_replace_verified "$backup_file" "$boot_config" "$old_hash" "$new_hash" "${reset_id}-restore"; then
            emit_result APPLY_FAILURE 'Atomic stock-config replacement failed after installation; the verified pre-reset config was restored.'
        elif [[ $installed_hash == "$old_hash" ]]; then
            emit_result APPLY_FAILURE 'Atomic stock-config replacement failed before changing the permanent config; the verified original remains installed.'
        else
            emit_result APPLY_FAILURE "Atomic stock-config replacement failed with unknown destination hash ${installed_hash:-unavailable}; refusing to overwrite unknown content."
        fi
        return 1
    fi
    rm -f -- "$rendered_file"
    installed_hash=$(sha256sum "$boot_config" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    if [[ $installed_hash != "$new_hash" ]]; then
        if [[ $installed_hash == "$old_hash" ]]; then
            emit_result APPLY_FAILURE 'Installed stock config failed final hash verification, but the verified original config remains installed.'
        else
            emit_result APPLY_FAILURE "Installed stock config has unknown hash ${installed_hash:-unavailable}; refusing to overwrite unknown content."
        fi
        return 1
    fi
    sync || { emit_result APPLY_FAILURE 'Could not durably sync the completed stock reset.'; return 1; }
    emit_data RESET_BACKUP "$backup_file"
    [[ -z $tryboot_backup ]] || emit_data RESET_TRYBOOT_BACKUP "$tryboot_backup"
    emit_data RESET_OLD_HASH "$old_hash"
    emit_data RESET_NEW_HASH "$new_hash"
    emit_data RESET_DISABLED_KEYS "$disabled_keys"
    emit_result PASS 'Permanent tuning was disabled, owned tryboot evidence was safely handled, and verified reset backups were preserved.'
}

cmd_reboot_stock_reset() {
    local expected_hash=$1 boot_config current_hash tryboot_flag
    valid_sha256 "$expected_hash" || { emit_result RECOVERY_FAILURE 'Stock-reset reboot received a malformed permanent-config hash.'; return 1; }
    boot_config=$(find_boot_config) || { emit_result RECOVERY_FAILURE 'Raspberry Pi boot config was not found before stock-reset reboot.'; return 1; }
    [[ -f $boot_config && ! -L $boot_config ]] || { emit_result RECOVERY_FAILURE 'Stock-reset reboot refuses a missing, non-regular, or symlinked permanent config.'; return 1; }
    reset_stock_paths_clear "$boot_config" || { emit_result RECOVERY_FAILURE 'Stock-reset reboot requires all staged and quarantined tryboot paths to be absent.'; return 1; }
    current_hash=$(sha256sum "$boot_config" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    [[ $current_hash == "$expected_hash" ]] || { emit_result RECOVERY_FAILURE 'Permanent config changed at the stock-reset reboot boundary.'; return 1; }
    tryboot_flag=$(od -An -tx1 /proc/device-tree/chosen/bootloader/tryboot 2>/dev/null | tr -d ' \n' || true)
    [[ $tryboot_flag == 00000000 || $tryboot_flag == 00000001 ]] || { emit_result RECOVERY_FAILURE "Stock-reset reboot found unreadable tryboot state ${tryboot_flag:-missing}."; return 1; }
    vcgencmd get_throttled 0x0f >/dev/null 2>&1 || true
    sync || { emit_result RECOVERY_FAILURE 'Could not sync before stock-reset reboot.'; return 1; }
    reboot >/dev/null 2>&1
    emit_result RECOVERY_FAILURE 'The stock-reset reboot command returned without restarting the target.'
    return 1
}

cmd_verify_stock_reset() {
    local expected_new_hash=$1 boot_config current_hash model compatible cpu_mhz gpu_mhz voltage_uv throttle throttle_value
    valid_sha256 "$expected_new_hash" || { emit_result RECOVERY_FAILURE 'Stock-reset verification received a malformed expected hash.'; return 1; }
    boot_config=$(find_boot_config) || { emit_result RECOVERY_FAILURE 'Raspberry Pi boot config was not found after stock reset.'; return 1; }
    reset_stock_validate_config "$boot_config" || { emit_result RECOVERY_FAILURE "$RESET_STOCK_LAST_REASON"; return 1; }
    reset_stock_no_artifacts "$boot_config" || { emit_result RECOVERY_FAILURE 'Stock-reset verification found live, staged, quarantined, or unresolved tryboot evidence.'; return 1; }
    current_hash=$(sha256sum "$boot_config" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    [[ $current_hash == "$expected_new_hash" ]] || { emit_result RECOVERY_FAILURE 'Permanent config does not match the expected stock-reset hash.'; return 1; }
    audit_permanent_tuning_config "$boot_config"
    [[ $PERMANENT_TUNING_PROVENANCE == verified-default && $PERMANENT_TUNING_EVIDENCE == none && $PERMANENT_TUNING_CONFIG_HASH == "$expected_new_hash" ]] || { emit_result RECOVERY_FAILURE 'Permanent config did not retain verified-default tuning provenance after reboot.'; return 1; }
    model=$(tr -d '\000' < /proc/device-tree/model 2>/dev/null || true)
    compatible=$(tr '\000' ',' < /proc/device-tree/compatible 2>/dev/null || true)
    [[ $model == *'Raspberry Pi 5'* || $compatible == *bcm2712* ]] || { emit_result RECOVERY_FAILURE 'Stock-reset verification target is not Raspberry Pi 5/bcm2712.'; return 1; }
    cpu_mhz=$(active_config_value arm_freq)
    gpu_mhz=$(active_config_value v3d_freq)
    voltage_uv=$(active_config_value over_voltage_delta)
    if [[ -z $voltage_uv ]] && active_config_interface_ready; then voltage_uv=0; fi
    [[ $cpu_mhz == 2400 && ( $gpu_mhz == 800 || $gpu_mhz == 960 ) && $voltage_uv == 0 ]] || { emit_result RECOVERY_FAILURE "Active clocks are not verified Pi 5 stock values (CPU=${cpu_mhz:-missing}, V3D=${gpu_mhz:-missing}, voltage=${voltage_uv:-missing})."; return 1; }
    throttle=$(permanent_throttle)
    throttle_value=$(throttle_word "$throttle" || true)
    [[ $throttle_value =~ ^[0-9]+$ ]] && (( (throttle_value & 0xffff) == 0 )) || { emit_result RECOVERY_FAILURE "Current throttle/power bits are active or unreadable after stock reset (${throttle:-missing})."; return 1; }
    watchdog_health_ready "$boot_config" || { emit_result RECOVERY_FAILURE "Post-reset watchdog proof failed: ${WATCHDOG_LAST_REASON:-unknown watchdog error}"; return 1; }
    reset_stock_no_artifacts "$boot_config" || { emit_result RECOVERY_FAILURE 'Tryboot evidence appeared during final stock-reset verification.'; return 1; }
    current_hash=$(sha256sum "$boot_config" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    [[ $current_hash == "$expected_new_hash" ]] || { emit_result RECOVERY_FAILURE 'Permanent config changed during final stock-reset verification.'; return 1; }
    emit_data RESET_NEW_HASH "$current_hash"
    emit_data RESET_ACTIVE_CPU "$cpu_mhz"
    emit_data RESET_ACTIVE_GPU "$gpu_mhz"
    emit_data RESET_ACTIVE_VOLTAGE "$voltage_uv"
    emit_result PASS 'Normal boot, protected hash, default provenance, Pi 5 stock clocks, voltage, and current power state were verified.'
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

COMPLETE_LAST_REASON=''
COMPLETE_RUN_IDS=()
COMPLETE_CLEANUP_PATHS=()

complete_safe_id() {
    local value=${1-}
    [[ $value =~ ^[A-Za-z0-9._-]+$ && $value != . && $value != .. && ${#value} -le 128 ]]
}

complete_tuning_key() {
    local key=${1,,}
    [[ $key == arm_boost || $key == force_turbo || $key == initial_turbo ||
       $key == core_freq_fixed || $key == *_freq || $key == *_freq_min ||
       $key == over_voltage* ]]
}

complete_validate_managed_lines() {
    local expected_cpu=$1 expected_gpu=$2 expected_gpu_key=$3 expected_voltage=$4 expected_run=$5
    shift 5
    local -a lines=("$@")
    local index=0
    (( ${#lines[@]} >= 4 )) || return 1
    [[ ${lines[index++]} == "# Run: ${expected_run}" ]] || return 1
    [[ ${lines[index++]} == '[all]' ]] || return 1
    if [[ ${lines[index]:-} == over_voltage_delta=* ]]; then
        [[ ${lines[index++]} == "over_voltage_delta=${expected_voltage}" ]] || return 1
    else
        [[ $expected_voltage == 0 ]] || return 1
    fi
    [[ ${lines[index++]:-} == "arm_freq=${expected_cpu}" ]] || return 1
    [[ ${lines[index++]:-} == "${expected_gpu_key}=${expected_gpu}" ]] || return 1
    if (( index < ${#lines[@]} )); then
        [[ ${lines[index++]:-} == "$CANDIDATE_FAN_COMMENT" &&
           ${lines[index++]:-} == 'dtparam=fan_temp0=0' &&
           ${lines[index++]:-} == 'dtparam=fan_temp0_speed=255' &&
           ${lines[index++]:-} == 'dtparam=fan_temp1_speed=255' &&
           ${lines[index++]:-} == 'dtparam=fan_temp2_speed=255' &&
           ${lines[index++]:-} == 'dtparam=fan_temp3_speed=255' ]] || return 1
    fi
    (( index == ${#lines[@]} ))
}

complete_validate_config() {
    local config_file=$1 expected_cpu=$2 expected_gpu=$3 expected_gpu_key=$4 expected_voltage=$5 expected_run=$6
    local line semantic trimmed lower key inside=0 marker_count=0
    local -a managed_lines=()
    COMPLETE_LAST_REASON=''
    [[ -f $config_file && ! -L $config_file && -r $config_file ]] || {
        COMPLETE_LAST_REASON='The permanent config is missing, unreadable, non-regular, or a symlink.'
        return 1
    }
    complete_safe_id "$expected_run" || { COMPLETE_LAST_REASON='The selected run ID is unsafe.'; return 1; }
    [[ $expected_cpu =~ ^[1-9][0-9]*$ && $expected_gpu =~ ^[1-9][0-9]*$ &&
       ( $expected_gpu_key == gpu_freq || $expected_gpu_key == v3d_freq ) &&
       $expected_voltage =~ ^-?[0-9]+$ ]] || {
        COMPLETE_LAST_REASON='The selected applied clock evidence is malformed.'
        return 1
    }
    while IFS= read -r line || [[ -n $line ]]; do
        semantic=${line%$'\r'}
        if [[ $semantic == "$CLOCK_MARKER_BEGIN" ]]; then
            (( inside == 0 )) || { COMPLETE_LAST_REASON='The permanent config contains nested managed clock markers.'; return 1; }
            marker_count=$((marker_count + 1))
            (( marker_count == 1 )) || { COMPLETE_LAST_REASON='The permanent config contains multiple managed clock blocks.'; return 1; }
            inside=1
            managed_lines=()
            continue
        fi
        if [[ $semantic == "$CLOCK_MARKER_END" ]]; then
            (( inside == 1 )) || { COMPLETE_LAST_REASON='The permanent config contains an unmatched managed clock end marker.'; return 1; }
            complete_validate_managed_lines "$expected_cpu" "$expected_gpu" "$expected_gpu_key" "$expected_voltage" "$expected_run" "${managed_lines[@]}" || {
                COMPLETE_LAST_REASON='The managed clock block does not exactly match the selected applied run.'
                return 1
            }
            inside=0
            continue
        fi
        if [[ $semantic == *'AUTOPIOVERCLOCK MANAGED CLOCKS'* ]]; then
            COMPLETE_LAST_REASON='The permanent config contains a malformed managed clock marker.'
            return 1
        fi
        if (( inside == 1 )); then
            managed_lines+=("$semantic")
            continue
        fi
        trimmed=${semantic#"${semantic%%[![:space:]]*}"}
        [[ -n $trimmed && $trimmed != \#* ]] || continue
        lower=${trimmed,,}
        if [[ $lower =~ ^include([[:space:]]|$) ]]; then
            COMPLETE_LAST_REASON='The permanent config contains an active include directive, so complete cannot prove the full configuration graph.'
            return 1
        fi
        if [[ $lower =~ ^([[:alnum:]_]+)[[:space:]]*= ]]; then
            key=${BASH_REMATCH[1]}
            if complete_tuning_key "$key"; then
                COMPLETE_LAST_REASON='The permanent config contains an active tuning key outside the managed clock block.'
                return 1
            fi
        fi
    done < "$config_file"
    (( inside == 0 && marker_count == 1 )) || {
        COMPLETE_LAST_REASON='The permanent config does not contain exactly one complete managed clock block.'
        return 1
    }
}

complete_render_config() {
    local source_file=$1 destination_file=$2 cpu_mhz=$3 gpu_mhz=$4 gpu_key=$5 voltage_uv=$6 rendered_file
    rendered_file=$(mktemp /tmp/autopioverclock-complete-canonical.XXXXXX) || return 1
    awk -v begin="$CLOCK_MARKER_BEGIN" -v end="$CLOCK_MARKER_END" \
        -v cpu="$cpu_mhz" -v gpu="$gpu_mhz" -v gpu_key="$gpu_key" -v voltage="$voltage_uv" '
        function tuning_key(key) {
            key=tolower(key)
            return key=="arm_boost" || key=="force_turbo" || key=="initial_turbo" || key=="core_freq_fixed" ||
                   key ~ /_freq$/ || key ~ /_freq_min$/ || key ~ /^over_voltage/
        }
        {
            raw=$0
            semantic=$0
            sub(/\r$/, "", semantic)
            if (semantic==begin) {inside=1; next}
            if (semantic==end) {
                inside=0
                print "[all]"
                print "over_voltage_delta=" voltage
                print "arm_freq=" cpu
                print gpu_key "=" gpu
                next
            }
            if (inside) next
            if (semantic ~ /^# AUTOPIOVERCLOCK TRYBOOT COMPLETE: [0-9a-f]+$/) {
                token=semantic
                sub(/^# AUTOPIOVERCLOCK TRYBOOT COMPLETE: /, "", token)
                if (length(token)==64) next
            }
            if (semantic ~ /^# AUTOPIOVERCLOCK-STOCK-DISABLED /) {
                payload=semantic
                sub(/^# AUTOPIOVERCLOCK-STOCK-DISABLED /, "", payload)
                probe=payload
                sub(/^[[:space:]]*/, "", probe)
                if (probe ~ /^[[:alnum:]_]+[[:space:]]*=/) {
                    key=probe
                    sub(/[[:space:]]*=.*$/, "", key)
                    if (tuning_key(key)) next
                }
            }
            print raw
        }
    ' "$source_file" > "$rendered_file" || { rm -f -- "$rendered_file"; return 1; }
    canonicalize_global_sections "$rendered_file" "$destination_file" 1 || { rm -f -- "$rendered_file"; return 1; }
    rm -f -- "$rendered_file"
}

complete_validate_sealed_config() {
    local config_file=$1 expected_cpu=$2 expected_gpu=$3 expected_gpu_key=$4 expected_voltage=$5
    local line semantic trimmed lower key section=all index match_count=0 voltage_count=0 cpu_count=0 gpu_count=0
    local section_count=0 all_count=0 meaningful_non_all=0
    local -a lines=()
    [[ -f $config_file && ! -L $config_file && -r $config_file ]] || return 1
    while IFS= read -r line || [[ -n $line ]]; do
        semantic=${line%$'\r'}
        [[ $semantic != "$CLOCK_MARKER_BEGIN" && $semantic != "$CLOCK_MARKER_END" &&
           $semantic != "$CANDIDATE_FAN_COMMENT" &&
           $semantic != '# AUTOPIOVERCLOCK TRYBOOT COMPLETE: '* &&
           $semantic != '# AUTOPIOVERCLOCK-STOCK-DISABLED '* ]] || return 1
        trimmed=${semantic#"${semantic%%[![:space:]]*}"}
        trimmed=${trimmed%"${trimmed##*[![:space:]]}"}
        if [[ -n $trimmed && $trimmed != \#* ]]; then
            lower=${trimmed,,}
            if [[ $lower == \[*\] ]]; then
                section=${lower#\[}
                section=${section%\]}
                section_count=$((section_count + 1))
                [[ $section != all ]] || all_count=$((all_count + 1))
                lines+=("$semantic")
                continue
            fi
            [[ $section == all ]] || meaningful_non_all=1
            [[ ! $lower =~ ^include([[:space:]]|$) ]] || return 1
            if [[ $lower =~ ^([[:alnum:]_]+)[[:space:]]*= ]]; then
                key=${BASH_REMATCH[1]}
                if complete_tuning_key "$key"; then
                    [[ $section == all ]] || return 1
                    case $semantic in
                        "over_voltage_delta=${expected_voltage}") voltage_count=$((voltage_count + 1)) ;;
                        "arm_freq=${expected_cpu}") cpu_count=$((cpu_count + 1)) ;;
                        "${expected_gpu_key}=${expected_gpu}") gpu_count=$((gpu_count + 1)) ;;
                        *) return 1 ;;
                    esac
                fi
            fi
        fi
        lines+=("$semantic")
    done < "$config_file"
    for (( index=0; index+2<${#lines[@]}; index++ )); do
        if [[ ${lines[index]} == "over_voltage_delta=${expected_voltage}" &&
              ${lines[index+1]} == "arm_freq=${expected_cpu}" &&
              ${lines[index+2]} == "${expected_gpu_key}=${expected_gpu}" ]]; then
            match_count=$((match_count + 1))
        fi
    done
    if (( meaningful_non_all == 0 )); then
        (( section_count == 1 && all_count == 1 )) || return 1
    fi
    (( match_count == 1 && voltage_count == 1 && cpu_count == 1 && gpu_count == 1 ))
}

cmd_render_complete() {
    local cpu_mhz=$1 gpu_mhz=$2 gpu_key=$3 voltage_uv=$4 run_id=$5 expected_hash=$6
    local boot_config current_hash rendered_file
    valid_sha256 "$expected_hash" && complete_safe_id "$run_id" || return 1
    boot_config=$(find_boot_config) || return 1
    apply_tryboot_clear "$boot_config" || return 1
    current_hash=$(sha256sum "$boot_config" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    [[ $current_hash == "$expected_hash" ]] || return 1
    complete_validate_config "$boot_config" "$cpu_mhz" "$gpu_mhz" "$gpu_key" "$voltage_uv" "$run_id" || return 1
    rendered_file=$(mktemp /tmp/autopioverclock-complete-render.XXXXXX) || return 1
    if ! complete_render_config "$boot_config" "$rendered_file" "$cpu_mhz" "$gpu_mhz" "$gpu_key" "$voltage_uv" ||
       ! complete_validate_sealed_config "$rendered_file" "$cpu_mhz" "$gpu_mhz" "$gpu_key" "$voltage_uv"; then
        rm -f -- "$rendered_file"
        return 1
    fi
    cat -- "$rendered_file"
    rm -f -- "$rendered_file"
}

cmd_complete_permanent() {
    local uploaded_file=$1 expected_old_hash=$2 expected_new_hash=$3 run_id=$4
    local cpu_mhz=$5 gpu_mhz=$6 gpu_key=$7 voltage_uv=$8
    local boot_config current_hash proposed_hash backup_dir backup_file backup_hash
    valid_sha256 "$expected_old_hash" && valid_sha256 "$expected_new_hash" && complete_safe_id "$run_id" || {
        emit_result APPLY_FAILURE 'Complete received malformed transaction evidence.'
        return 1
    }
    boot_config=$(find_boot_config) || { emit_result APPLY_FAILURE 'Boot config is missing for complete.'; return 1; }
    apply_tryboot_clear "$boot_config" || { emit_result APPLY_FAILURE 'Complete requires normal boot with no tryboot evidence.'; return 1; }
    current_hash=$(sha256sum "$boot_config" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    if [[ $current_hash == "$expected_new_hash" ]]; then
        complete_validate_sealed_config "$boot_config" "$cpu_mhz" "$gpu_mhz" "$gpu_key" "$voltage_uv" || {
            emit_result APPLY_FAILURE 'The saved completed hash does not have the expected simplified structure.'
            return 1
        }
        emit_data COMPLETE_NEW_HASH "$expected_new_hash"
        emit_result PASS 'Permanent config already has the verified completed form.'
        return 0
    fi
    [[ $current_hash == "$expected_old_hash" ]] || { emit_result APPLY_FAILURE 'Permanent config changed before complete.'; return 1; }
    complete_validate_config "$boot_config" "$cpu_mhz" "$gpu_mhz" "$gpu_key" "$voltage_uv" "$run_id" || {
        emit_result APPLY_FAILURE "$COMPLETE_LAST_REASON"
        return 1
    }
    [[ -f $uploaded_file && ! -L $uploaded_file ]] || { emit_result APPLY_FAILURE 'Uploaded completed config is unsafe.'; return 1; }
    proposed_hash=$(sha256sum "$uploaded_file" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    [[ $proposed_hash == "$expected_new_hash" ]] || { emit_result APPLY_FAILURE 'Uploaded completed config hash does not match the saved transaction.'; return 1; }
    complete_validate_sealed_config "$uploaded_file" "$cpu_mhz" "$gpu_mhz" "$gpu_key" "$voltage_uv" || {
        emit_result APPLY_FAILURE 'Uploaded completed config does not have the expected simplified structure.'
        return 1
    }
    backup_dir=/var/lib/autopioverclock/backups
    mkdir -p -- "$backup_dir" || { emit_result APPLY_FAILURE 'Could not create complete backup directory.'; return 1; }
    [[ -d $backup_dir && ! -L $backup_dir ]] || { emit_result APPLY_FAILURE 'Complete backup directory is unsafe.'; return 1; }
    backup_file="${backup_dir}/config-${run_id}-before-complete.txt"
    backup_hash=$(sha256sum "$backup_file" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    if [[ $backup_hash != "$expected_old_hash" ]]; then
        [[ ! -e $backup_file && ! -L $backup_file ]] || { emit_result APPLY_FAILURE 'Unexpected complete backup already exists.'; return 1; }
        atomic_replace_verified "$boot_config" "$backup_file" "$expected_old_hash" complete-backup || {
            emit_result APPLY_FAILURE 'Could not create the verified complete backup.'
            return 1
        }
    fi
    if ! chmod --reference="$boot_config" "$uploaded_file" 2>/dev/null && ! chmod 644 "$uploaded_file"; then
        emit_result APPLY_FAILURE 'Could not preserve completed-config permissions.'
        return 1
    fi
    apply_tryboot_clear "$boot_config" || { emit_result APPLY_FAILURE 'Tryboot evidence appeared at the complete mutation boundary.'; return 1; }
    current_hash=$(sha256sum "$boot_config" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    [[ $current_hash == "$expected_old_hash" ]] || { emit_result APPLY_FAILURE 'Permanent config changed at the complete mutation boundary.'; return 1; }
    if ! atomic_replace_verified "$uploaded_file" "$boot_config" "$expected_new_hash" complete; then
        atomic_replace_verified "$backup_file" "$boot_config" "$expected_old_hash" complete-restore || true
        emit_result APPLY_FAILURE 'Could not install the simplified permanent config; verified restoration was attempted.'
        return 1
    fi
    emit_data COMPLETE_NEW_HASH "$expected_new_hash"
    emit_result PASS 'Permanent config was simplified without changing the applied clock values.'
}

complete_worker_dir() { cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P; }
complete_run_dir() { printf '/tmp/autopioverclock-%s' "$1"; }
complete_backup_root() { printf '/var/lib/autopioverclock/backups'; }

complete_supervisor_identity_matches() {
    local pid=$1 root=$2 helper_path index candidate
    local -a command_line=()
    helper_path="${root}/remote-stress-job.sh"
    [[ -r /proc/${pid}/cmdline ]] || return 1
    mapfile -d '' -t command_line < "/proc/${pid}/cmdline" || return 1
    for (( index=0; index<${#command_line[@]}; index++ )); do
        candidate=${command_line[index]}
        if [[ $candidate == "$helper_path" && ${command_line[index+1]:-} == run &&
              ${command_line[index+2]:-} == "$root" ]]; then
            return 0
        fi
    done
    return 1
}

complete_run_has_live_stress() {
    local run_dir=$1 pid_file pid
    local -a pid_files=()
    shopt -s nullglob
    pid_files=("$run_dir"/jobs/job-*/supervisor.pid)
    shopt -u nullglob
    for pid_file in "${pid_files[@]}"; do
        [[ -f $pid_file && ! -L $pid_file ]] || return 0
        IFS= read -r pid < "$pid_file" || return 0
        if [[ $pid =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null &&
           complete_supervisor_identity_matches "$pid" "$run_dir"; then
            return 0
        fi
    done
    return 1
}

complete_collect_backup_paths() {
    local run_id=$1 backup_root candidate
    local -a candidates=()
    backup_root=$(complete_backup_root)
    [[ ! -e $backup_root && ! -L $backup_root ]] && return 0
    [[ -d $backup_root && ! -L $backup_root ]] || return 1
    shopt -s nullglob
    candidates=(
        "$backup_root/config-${run_id}-before-apply.txt"
        "$backup_root/config-${run_id}-before-complete.txt"
        "$backup_root"/config-????????T??????Z-reset-"$run_id".txt
        "$backup_root"/tryboot-????????T??????Z-reset-"$run_id"-*.txt
        "$backup_root"/network-watchdog-????????T??????Z-"$run_id".*
        "$backup_root"/network-watchdog-observer-????????T??????Z-"$run_id".*
    )
    shopt -u nullglob
    for candidate in "${candidates[@]}"; do
        [[ $candidate == "$backup_root/"* && $candidate != "$backup_root" ]] || return 1
        [[ ! -e $candidate && ! -L $candidate ]] && continue
        if [[ -L $candidate || ( ! -f $candidate && ! -d $candidate ) ]]; then return 1; fi
        COMPLETE_CLEANUP_PATHS+=("$candidate")
    done
}

cmd_cleanup_complete_artifacts() {
    local manifest_file=$1 expected_hash=$2 current_run=$3 worker_dir actual_hash line run_id run_dir candidate
    local removed_runs=0 removed_backups=0 found_current=0
    local -A seen=()
    valid_sha256 "$expected_hash" && complete_safe_id "$current_run" || { emit_result RECOVERY_FAILURE 'Complete cleanup received malformed transaction evidence.'; return 1; }
    worker_dir=$(complete_worker_dir) || { emit_result RECOVERY_FAILURE 'Complete cleanup could not resolve its worker directory.'; return 1; }
    [[ $manifest_file == "$worker_dir/complete-run-ids.txt" && -f $manifest_file && ! -L $manifest_file ]] || {
        emit_result RECOVERY_FAILURE 'Complete cleanup manifest path is unsafe.'
        return 1
    }
    actual_hash=$(sha256sum "$manifest_file" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    [[ $actual_hash == "$expected_hash" ]] || { emit_result RECOVERY_FAILURE 'Complete cleanup manifest hash does not match.'; return 1; }
    COMPLETE_RUN_IDS=()
    COMPLETE_CLEANUP_PATHS=()
    while IFS= read -r line || [[ -n $line ]]; do
        run_id=${line%$'\r'}
        complete_safe_id "$run_id" && [[ ! -v seen[$run_id] ]] || { emit_result RECOVERY_FAILURE 'Complete cleanup manifest contains an unsafe or duplicate run ID.'; return 1; }
        seen[$run_id]=1
        COMPLETE_RUN_IDS+=("$run_id")
        [[ $run_id == "$current_run" ]] && found_current=1
    done < "$manifest_file"
    (( found_current == 1 && ${#COMPLETE_RUN_IDS[@]} > 0 )) || { emit_result RECOVERY_FAILURE 'Complete cleanup manifest omits the selected run.'; return 1; }
    for run_id in "${COMPLETE_RUN_IDS[@]}"; do
        run_dir=$(complete_run_dir "$run_id")
        [[ $run_dir == "/tmp/autopioverclock-${run_id}" ]] || { emit_result RECOVERY_FAILURE 'Complete cleanup resolved an unsafe run path.'; return 1; }
        if [[ -e $run_dir || -L $run_dir ]]; then
            [[ -d $run_dir && ! -L $run_dir ]] || { emit_result RECOVERY_FAILURE "Unsafe run harness path: $run_dir"; return 1; }
            if complete_run_has_live_stress "$run_dir"; then emit_result RECOVERY_FAILURE "A target stress supervisor is still active in $run_dir."; return 1; fi
        fi
        complete_collect_backup_paths "$run_id" || { emit_result RECOVERY_FAILURE 'Complete found an unsafe target backup path.'; return 1; }
    done
    for run_id in "${COMPLETE_RUN_IDS[@]}"; do
        [[ $run_id == "$current_run" ]] && continue
        run_dir=$(complete_run_dir "$run_id")
        if [[ -d $run_dir && ! -L $run_dir ]]; then rm -rf -- "$run_dir" || { emit_result RECOVERY_FAILURE "Could not remove run harness $run_dir."; return 1; }; removed_runs=$((removed_runs + 1)); fi
    done
    for candidate in "${COMPLETE_CLEANUP_PATHS[@]}"; do
        if [[ -d $candidate && ! -L $candidate ]]; then rm -rf -- "$candidate"
        elif [[ -f $candidate && ! -L $candidate ]]; then rm -f -- "$candidate"
        else emit_result RECOVERY_FAILURE "Target cleanup path changed before deletion: $candidate"; return 1
        fi || { emit_result RECOVERY_FAILURE "Could not remove target cleanup path: $candidate"; return 1; }
        removed_backups=$((removed_backups + 1))
    done
    sync || { emit_result RECOVERY_FAILURE 'Could not durably flush completed target cleanup.'; return 1; }
    emit_data COMPLETE_REMOVED_RUN_DIRS "$removed_runs"
    emit_data COMPLETE_REMOVED_BACKUPS "$removed_backups"
    emit_result PASS 'Run harnesses and run-specific target backups were removed; native and permanent watchdogs were preserved.'
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

debian_network_watchdog_valid_ipv4() {
    awk -F. '
        NF != 4 {exit 1}
        {for (i=1; i<=4; i++) if ($i !~ /^[0-9]+$/ || $i+0 > 255 || $i != $i+0) exit 1}
    ' <<<"${1-}"
}

debian_watchdog_config_value() {
    local source=$1 wanted=$2 optional=${3:-0}
    awk -F= -v wanted="$wanted" -v optional="$optional" '
        /^[[:space:]]*#/ {next}
        {
            key=$1
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
            if (key != wanted) next
            value=substr($0, index($0, "=")+1)
            sub(/[[:space:]]*#.*/, "", value)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            if (value == "") exit 2
            count++
            selected=value
        }
        END {
            if (count == 1) print selected
            else if (count == 0 && optional == 1) exit 0
            else exit 1
        }
    ' "$source"
}

debian_native_watchdog_service_active() {
    command -v systemctl >/dev/null 2>&1 || return 1
    systemctl is-active --quiet watchdog.service 2>/dev/null
}

debian_native_network_watchdog_config_path() {
    local service=watchdog.service pid argument expect_config=0 configured_path='' config binary unit
    command -v systemctl >/dev/null 2>&1 && command -v journalctl >/dev/null 2>&1 || return 1
    debian_native_watchdog_service_active || return 1
    pid=$(systemctl show --property=MainPID --value "$service" 2>/dev/null || true)
    [[ $pid =~ ^[1-9][0-9]*$ && -r /proc/$pid/cmdline ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    binary=$(readlink -f -- "/proc/$pid/exe" 2>/dev/null || true)
    [[ $binary == /* && -x $binary && ! -L $binary ]] || return 1
    while IFS= read -r argument; do
        if (( expect_config == 1 )); then
            configured_path=$argument
            expect_config=0
            continue
        fi
        case $argument in
            -c|--config-file) expect_config=1 ;;
            -c*) configured_path=${argument#-c} ;;
            --config-file=*) configured_path=${argument#*=} ;;
        esac
    done < <(tr '\000' '\n' <"/proc/$pid/cmdline" 2>/dev/null)
    (( expect_config == 0 )) || return 1
    config=${configured_path:-/etc/watchdog.conf}
    [[ $config == /* && -f $config && ! -L $config ]] || return 1
    unit=$(systemctl show --property=FragmentPath --value "$service" 2>/dev/null || true)
    [[ $unit == /* && -f $unit ]] || return 1
    printf '%s' "$config"
}

debian_native_network_watchdog_present() {
    local config
    config=$(debian_native_network_watchdog_config_path) || return 1
    awk -F= '
        /^[[:space:]]*#/ {next}
        {
            key=$1
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
            if (key != "ping") next
            value=substr($0, index($0, "=")+1)
            sub(/[[:space:]]*#.*/, "", value)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            if (value != "") found=1
        }
        END {exit !found}
    ' "$config"
}

debian_native_network_watchdog_blocks_fallback() {
    debian_native_watchdog_service_active || return 1
    debian_native_network_watchdog_config_path >/dev/null || return 0
    debian_native_network_watchdog_present
}

debian_native_network_watchdog_target() {
    local config target value argument
    config=$(debian_native_network_watchdog_config_path) || return 1
    target=$(debian_watchdog_config_value "$config" ping) || return 1
    debian_network_watchdog_valid_ipv4 "$target" || return 1
    value=$(debian_watchdog_config_value "$config" repair-binary 1) || return 1
    [[ -z $value || $value == /* ]] || return 1
    for argument in repair-timeout retry-timeout watchdog-timeout; do
        value=$(debian_watchdog_config_value "$config" "$argument" 1) || return 1
        [[ -z $value || $value =~ ^[0-9]+$ ]] || return 1
    done
    printf '%s' "$target"
}

debian_network_watchdog_config_fields() {
    local config=$1
    awk -F= '
        BEGIN {
            allowed["TARGET"]=1; allowed["PING_TIMEOUT_SECONDS"]=1
            allowed["CHECK_INTERVAL_SECONDS"]=1; allowed["STARTUP_GRACE_SECONDS"]=1
            allowed["FAILURE_WINDOW_SECONDS"]=1; allowed["MAX_REBOOTS"]=1
            allowed["REBOOT_WINDOW_SECONDS"]=1; allowed["RUN_ID"]=1
        }
        $0 == "# AUTOPIOVERCLOCK MANAGED DEBIAN NETWORK WATCHDOG" {
            if (marker) invalid=1
            marker=1
            next
        }
        /^[[:space:]]*$/ {next}
        /^[[:space:]]*#/ {invalid=1; next}
        {
            key=$1
            value=substr($0, index($0, "=")+1)
            if (NF < 2 || !allowed[key] || seen[key]++ || value == "") {invalid=1; next}
            values[key]=value
            count++
        }
        END {
            if (invalid || marker != 1 || count != 8) exit 1
            print values["TARGET"] "\t" values["RUN_ID"]
        }
    ' "$config" | {
        IFS=$'\t' read -r target run_id || return 1
        debian_network_watchdog_valid_ipv4 "$target" || return 1
        [[ $run_id =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || return 1
        printf '%s\t%s' "$target" "$run_id"
    }
}

debian_network_watchdog_config_target() {
    local fields
    fields=$(debian_network_watchdog_config_fields "$1") || return 1
    printf '%s' "${fields%%$'\t'*}"
}

debian_network_watchdog_observer_config_fields() {
    local config=$1
    awk -F= '
        BEGIN {
            allowed["FORMAT"]=1; allowed["PROVIDER"]=1; allowed["INSTALL_RUN_ID"]=1
            allowed["TARGET"]=1; allowed["NATIVE_SERVICE"]=1; allowed["NATIVE_CONFIG_PATH"]=1
            allowed["NATIVE_BINARY_PATH"]=1; allowed["REPAIR_BINARY_PATH"]=1
            allowed["REPAIR_TIMEOUT_SECONDS"]=1; allowed["RETRY_TIMEOUT_SECONDS"]=1
            allowed["WATCHDOG_TIMEOUT_SECONDS"]=1; allowed["EVIDENCE_WINDOW_SECONDS"]=1
            allowed["OBSERVER_SHA256"]=1; allowed["SERVICE_SHA256"]=1
        }
        $0 == "# AUTOPIOVERCLOCK MANAGED DEBIAN NETWORK WATCHDOG OBSERVER" {
            if (marker) invalid=1
            marker=1
            next
        }
        /^[[:space:]]*$/ {next}
        /^[[:space:]]*#/ {invalid=1; next}
        {
            key=$1
            value=substr($0, index($0, "=")+1)
            if (NF < 2 || !allowed[key] || seen[key]++ || value == "") {invalid=1; next}
            values[key]=value
            count++
        }
        END {
            if (invalid || marker != 1 || count != 14 || values["FORMAT"] != 1 ||
                values["PROVIDER"] != "debian-watchdog-observer") exit 1
            print values["TARGET"] "\t" values["INSTALL_RUN_ID"]
        }
    ' "$config" | {
        IFS=$'\t' read -r target run_id || return 1
        debian_network_watchdog_valid_ipv4 "$target" || return 1
        [[ $run_id =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || return 1
        printf '%s\t%s' "$target" "$run_id"
    }
}

debian_network_watchdog_observer_config_target() {
    local fields
    fields=$(debian_network_watchdog_observer_config_fields "$1") || return 1
    printf '%s' "${fields%%$'\t'*}"
}

debian_network_watchdog_backup_for_run() {
    local kind=$1 run_id=$2 candidate prefix backup_root=/var/lib/autopioverclock/backups
    local -a matches=()
    [[ $run_id =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || return 1
    case $kind in
        debian-systemd-companion) prefix=network-watchdog ;;
        debian-watchdog-observer) prefix=network-watchdog-observer ;;
        *) return 1 ;;
    esac
    shopt -s nullglob
    for candidate in "$backup_root"/"${prefix}"-[0-9]*-"${run_id}".*; do
        [[ -d $candidate && ! -L $candidate ]] && matches+=("$candidate")
    done
    shopt -u nullglob
    (( ${#matches[@]} == 1 )) || return 1
    printf '%s' "${matches[0]}"
}

debian_network_watchdog_service_ready() {
    local keeper=$1 config=$2 service=$3 pid argument keeper_found=0 config_found=0
    [[ -f $keeper && ! -L $keeper && -f $config && ! -L $config && -f $service && ! -L $service ]] || return 1
    command -v systemctl >/dev/null 2>&1 || return 1
    systemctl is-enabled --quiet autopioverclock-network-watchdog.service 2>/dev/null || return 1
    systemctl is-active --quiet autopioverclock-network-watchdog.service 2>/dev/null || return 1
    pid=$(systemctl show --property=MainPID --value autopioverclock-network-watchdog.service 2>/dev/null || true)
    [[ $pid =~ ^[1-9][0-9]*$ && -r /proc/$pid/cmdline ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    while IFS= read -r argument; do
        [[ $argument == "$keeper" ]] && keeper_found=1
        [[ $argument == "$config" ]] && config_found=1
    done < <(tr '\000' '\n' <"/proc/$pid/cmdline" 2>/dev/null)
    (( keeper_found == 1 && config_found == 1 ))
}

debian_network_watchdog_observer_service_ready() {
    local observer=$1 service=$2 pid argument observer_found=0
    [[ -f $observer && ! -L $observer && -f $service && ! -L $service ]] || return 1
    command -v systemctl >/dev/null 2>&1 || return 1
    systemctl is-enabled --quiet autopioverclock-network-watchdog-observer.service 2>/dev/null || return 1
    systemctl is-active --quiet autopioverclock-network-watchdog-observer.service 2>/dev/null || return 1
    systemctl is-active --quiet watchdog.service 2>/dev/null || return 1
    pid=$(systemctl show --property=MainPID --value autopioverclock-network-watchdog-observer.service 2>/dev/null || true)
    [[ $pid =~ ^[1-9][0-9]*$ && -r /proc/$pid/cmdline ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    while IFS= read -r argument; do
        [[ $argument == "$observer" ]] && observer_found=1
    done < <(tr '\000' '\n' <"/proc/$pid/cmdline" 2>/dev/null)
    (( observer_found == 1 ))
}

debian_network_watchdog_asset_paths_ready() {
    local installer=$1 payload=$2 service=$3 run_id=$4 marker=$5
    local installer_directory payload_directory service_directory run_root
    [[ $run_id =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || return 1
    [[ -f $installer && ! -L $installer && -x $installer ]] || return 1
    [[ -f $payload && ! -L $payload && -f $service && ! -L $service ]] || return 1
    installer_directory=$(readlink -f -- "${installer%/*}" 2>/dev/null || true)
    payload_directory=$(readlink -f -- "${payload%/*}" 2>/dev/null || true)
    service_directory=$(readlink -f -- "${service%/*}" 2>/dev/null || true)
    run_root="/tmp/autopioverclock-${run_id}"
    [[ -n $installer_directory && $installer_directory == "$payload_directory" &&
       $installer_directory == "$service_directory" && $installer_directory == "$run_root"/* ]] || return 1
    grep -Fq "$marker" "$installer" && grep -Fq "$marker" "$payload" && grep -Fq "$marker" "$service"
}

debian_network_watchdog_installer_ready() {
    local installer=$1 run_id=$2 marker=$3 installer_directory run_root
    [[ $run_id =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || return 1
    [[ -f $installer && ! -L $installer && -x $installer ]] || return 1
    installer_directory=$(readlink -f -- "${installer%/*}" 2>/dev/null || true)
    run_root="/tmp/autopioverclock-${run_id}"
    [[ -n $installer_directory && ( $installer_directory == "$run_root" || $installer_directory == "$run_root"/* ) ]] || return 1
    grep -Fq "$marker" "$installer"
}

debian_network_watchdog_event_fields() {
    local event_file=$1
    awk -F= '
        BEGIN {
            allowed["FORMAT"]=1; allowed["EVENT_ID"]=1; allowed["SOURCE_BOOT_ID"]=1
            allowed["TARGET"]=1; allowed["FAILURE_STARTED_EPOCH"]=1
            allowed["REBOOT_REQUESTED_EPOCH"]=1; allowed["CONFIG_SHA256"]=1
            allowed["KEEPER_SHA256"]=1; allowed["SERVICE_SHA256"]=1; allowed["REASON"]=1
        }
        $0 == "# AUTOPIOVERCLOCK NETWORK WATCHDOG EVENT V1" {
            if (marker) invalid=1
            marker=1
            next
        }
        /^[[:space:]]*$/ {next}
        /^[[:space:]]*#/ {invalid=1; next}
        {
            key=$1
            value=substr($0, index($0, "=")+1)
            if (NF < 2 || !allowed[key] || seen[key]++ || value == "") {invalid=1; next}
            values[key]=value
            count++
        }
        END {
            if (invalid || marker != 1 || count != 10) exit 1
            printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
                values["FORMAT"], values["EVENT_ID"], values["SOURCE_BOOT_ID"],
                values["TARGET"], values["FAILURE_STARTED_EPOCH"],
                values["REBOOT_REQUESTED_EPOCH"], values["CONFIG_SHA256"],
                values["KEEPER_SHA256"], values["SERVICE_SHA256"], values["REASON"]
        }
    ' "$event_file"
}

network_watchdog_accepted_event_fields() {
    local event_file=$1
    awk -F= '
        BEGIN {
            allowed["FORMAT"]=1; allowed["EVENT_ID"]=1; allowed["SOURCE_BOOT_ID"]=1
            allowed["CURRENT_BOOT_ID"]=1; allowed["TARGET"]=1
            allowed["FAILURE_STARTED_EPOCH"]=1; allowed["REBOOT_REQUESTED_EPOCH"]=1
            allowed["CONFIG_SHA256"]=1; allowed["KEEPER_SHA256"]=1
            allowed["SERVICE_SHA256"]=1; allowed["REASON"]=1; allowed["PROOF_METHOD"]=1
        }
        $0 == "# AUTOPIOVERCLOCK NETWORK WATCHDOG EVENT V1" {
            if (marker) invalid=1
            marker=1
            next
        }
        /^[[:space:]]*$/ {next}
        /^[[:space:]]*#/ {invalid=1; next}
        {
            key=$1
            value=substr($0, index($0, "=")+1)
            if (NF < 2 || !allowed[key] || seen[key]++ || value == "") {invalid=1; next}
            values[key]=value
            count++
        }
        END {
            if (invalid || marker != 1 || count != 12) exit 1
            printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
                values["FORMAT"], values["EVENT_ID"], values["SOURCE_BOOT_ID"],
                values["CURRENT_BOOT_ID"], values["TARGET"],
                values["FAILURE_STARTED_EPOCH"], values["REBOOT_REQUESTED_EPOCH"],
                values["CONFIG_SHA256"], values["KEEPER_SHA256"],
                values["SERVICE_SHA256"], values["REASON"], values["PROOF_METHOD"]
        }
    ' "$event_file"
}

network_watchdog_archive_chain() {
    local root=$1 expected_old=$2 expected_new=$3 expected_target=$4
    local expected_config_hash=$5 expected_keeper_hash=$6 expected_service_hash=$7
    local expected_method=$8 previous_event=$9
    local archive archive_name fields format event_id source_boot destination_boot target
    local failure_epoch request_epoch config_hash keeper_hash service_hash reason proof_method
    local cursor=$expected_old last_request=0 final_event='' final_source='' final_request='' count=0 found=0 record existing_record
    local -A destination_by_source=() event_by_source=() target_by_source=()
    local -A failure_by_source=() request_by_source=() config_by_source=()
    local -A keeper_by_source=() service_by_source=() method_by_source=() seen_source=()
    for archive in "$root"/accepted-network-reboot-*; do
        [[ -e $archive || -L $archive ]] || continue
        found=1
        [[ -f $archive && ! -L $archive ]] || return 1
        fields=$(network_watchdog_accepted_event_fields "$archive" 2>/dev/null) || return 1
        IFS=$'\t' read -r format event_id source_boot destination_boot target failure_epoch request_epoch \
            config_hash keeper_hash service_hash reason proof_method <<<"$fields"
        archive_name=${archive##*/}
        [[ $format == 1 && $archive_name == "accepted-network-reboot-$event_id" &&
           $event_id =~ ^[0-9a-f]{32}$ &&
           $source_boot =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ &&
           $destination_boot =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ &&
           $source_boot != "$destination_boot" && $failure_epoch =~ ^[1-9][0-9]*$ &&
           $request_epoch =~ ^[1-9][0-9]*$ && $failure_epoch -le $request_epoch &&
           $config_hash =~ ^[0-9a-f]{64}$ && $keeper_hash =~ ^[0-9a-f]{64}$ &&
           $service_hash =~ ^[0-9a-f]{64}$ && $reason == TARGET_UNREACHABLE ]] || return 1
        record="$event_id|$destination_boot|$target|$failure_epoch|$request_epoch|$config_hash|$keeper_hash|$service_hash|$proof_method"
        if [[ -n ${destination_by_source[$source_boot]+present} ]]; then
            existing_record="${event_by_source[$source_boot]}|${destination_by_source[$source_boot]}|${target_by_source[$source_boot]}|${failure_by_source[$source_boot]}|${request_by_source[$source_boot]}|${config_by_source[$source_boot]}|${keeper_by_source[$source_boot]}|${service_by_source[$source_boot]}|${method_by_source[$source_boot]}"
            [[ $existing_record == "$record" ]] || return 1
            continue
        fi
        event_by_source[$source_boot]=$event_id
        destination_by_source[$source_boot]=$destination_boot
        target_by_source[$source_boot]=$target
        failure_by_source[$source_boot]=$failure_epoch
        request_by_source[$source_boot]=$request_epoch
        config_by_source[$source_boot]=$config_hash
        keeper_by_source[$source_boot]=$keeper_hash
        service_by_source[$source_boot]=$service_hash
        method_by_source[$source_boot]=$proof_method
    done
    (( found == 1 )) || return 1
    while [[ $cursor != "$expected_new" ]]; do
        [[ -n ${destination_by_source[$cursor]+present} && -z ${seen_source[$cursor]+present} ]] || return 1
        seen_source[$cursor]=1
        event_id=${event_by_source[$cursor]}
        destination_boot=${destination_by_source[$cursor]}
        request_epoch=${request_by_source[$cursor]}
        [[ $event_id != "$previous_event" && ${target_by_source[$cursor]} == "$expected_target" &&
           ${config_by_source[$cursor]} == "$expected_config_hash" &&
           ${keeper_by_source[$cursor]} == "$expected_keeper_hash" &&
           ${service_by_source[$cursor]} == "$expected_service_hash" &&
           ${method_by_source[$cursor]} == "$expected_method" && request_epoch -gt last_request ]] || return 1
        final_event=$event_id
        final_source=$cursor
        final_request=$request_epoch
        last_request=$request_epoch
        cursor=$destination_boot
        count=$((count + 1))
    done
    (( count > 0 )) || return 1
    APO_WATCHDOG_CHAIN_EVENT_ID=$final_event
    APO_WATCHDOG_CHAIN_FINAL_SOURCE=$final_source
    APO_WATCHDOG_CHAIN_REQUEST_EPOCH=$final_request
    APO_WATCHDOG_CHAIN_COUNT=$count
}

network_watchdog_log_chain() {
    local log=$1 expected_old=$2 expected_new=$3 expected_target=$4 expected_method=$5 previous_event=$6
    local chain_output event_id source_boot destination_boot target target_regex request_epoch
    local final_event='' final_source='' final_request='' last_request=0 count=0
    local -a log_files=()
    if [[ -e $log.1 || -L $log.1 ]]; then
        [[ -f $log.1 && ! -L $log.1 ]] || return 1
        log_files+=("$log.1")
    fi
    [[ -f $log && ! -L $log ]] || return 1
    log_files+=("$log")
    chain_output=$(awk -v begin="$expected_old" -v finish="$expected_new" '
        function event_ok(value) {return length(value) == 32 && value !~ /[^0-9a-f]/}
        function boot_ok(value) {
            return length(value) == 36 && value !~ /[^0-9a-f-]/ &&
                substr(value,9,1) == "-" && substr(value,14,1) == "-" &&
                substr(value,19,1) == "-" && substr(value,24,1) == "-"
        }
        $2 == "network_reboot_accepted" {
            if (NF != 7 || split($3,a,"=") != 2 || a[1] != "event_id" ||
                split($4,b,"=") != 2 || b[1] != "source_boot_id" ||
                split($5,c,"=") != 2 || c[1] != "target" ||
                split($6,d,"=") != 2 || d[1] != "requested_epoch" ||
                split($7,e,"=") != 2 || e[1] != "current_boot_id" ||
                !event_ok(a[2]) || !boot_ok(b[2]) || !boot_ok(e[2]) ||
                b[2] == e[2] || d[2] !~ /^[1-9][0-9]*$/) {bad=1; next}
            record=a[2] "\t" e[2] "\t" c[2] "\t" d[2]
            if ((b[2] in record_by_source) && record_by_source[b[2]] != record) {bad=1; next}
            record_by_source[b[2]]=record
            event_by_source[b[2]]=a[2]
            destination_by_source[b[2]]=e[2]
            target_by_source[b[2]]=c[2]
            request_by_source[b[2]]=d[2]
        }
        END {
            if (bad) exit 1
            cursor=begin
            while (cursor != finish) {
                if (!(cursor in destination_by_source) || seen[cursor]++) exit 1
                printf "%s\t%s\t%s\t%s\t%s\n", event_by_source[cursor], cursor,
                    destination_by_source[cursor], target_by_source[cursor], request_by_source[cursor]
                cursor=destination_by_source[cursor]
            }
        }
    ' "${log_files[@]}") || return 1
    [[ -n $chain_output ]] || return 1
    while IFS=$'\t' read -r event_id source_boot destination_boot target request_epoch; do
        [[ $event_id =~ ^[0-9a-f]{32}$ && $event_id != "$previous_event" &&
           $source_boot =~ ^[0-9a-f-]{36}$ && $destination_boot =~ ^[0-9a-f-]{36}$ &&
           $target == "$expected_target" && $request_epoch =~ ^[1-9][0-9]*$ &&
           request_epoch -gt last_request ]] || return 1
        target_regex=${target//./\\.}
        grep -Eq "network_reboot_prepared event_id=$event_id source_boot_id=$source_boot target=$target_regex prepared_epoch=[1-9][0-9]*( method=debian-watchdog-journal)?$" "${log_files[@]}" || return 1
        grep -Eq "network_reboot_committed event_id=$event_id source_boot_id=$source_boot target=$target_regex requested_epoch=$request_epoch method=$expected_method( outcome=[A-Za-z0-9-]+)?$" "${log_files[@]}" || return 1
        final_event=$event_id
        final_source=$source_boot
        final_request=$request_epoch
        last_request=$request_epoch
        count=$((count + 1))
    done <<<"$chain_output"
    (( count > 0 )) || return 1
    APO_WATCHDOG_CHAIN_EVENT_ID=$final_event
    APO_WATCHDOG_CHAIN_FINAL_SOURCE=$final_source
    APO_WATCHDOG_CHAIN_REQUEST_EPOCH=$final_request
    APO_WATCHDOG_CHAIN_COUNT=$count
}

cmd_plan_network_watchdog() {
    local installer=${1:-} keeper=${2:-} service=${3:-} run_id=${4:-}
    debian_network_watchdog_asset_paths_ready "$installer" "$keeper" "$service" "$run_id" \
        'AUTOPIOVERCLOCK MANAGED DEBIAN NETWORK WATCHDOG' || {
        emit_result PREFLIGHT_FAILURE 'The uploaded Debian network-watchdog assets are missing, foreign, or unsafe.'
        return 1
    }
    "$installer" plan "$keeper" "$service" "$run_id"
}

cmd_plan_network_watchdog_observer() {
    local installer=${1:-} observer=${2:-} service=${3:-} run_id=${4:-}
    debian_network_watchdog_asset_paths_ready "$installer" "$observer" "$service" "$run_id" \
        'AUTOPIOVERCLOCK MANAGED DEBIAN NETWORK WATCHDOG OBSERVER' || {
        emit_result PREFLIGHT_FAILURE 'The uploaded Debian watchdog-observer assets are missing, foreign, or unsafe.'
        return 1
    }
    "$installer" plan "$observer" "$service" "$run_id"
}

cmd_install_network_watchdog() {
    local installer=${1:-} keeper=${2:-} service=${3:-} run_id=${4:-}
    debian_network_watchdog_asset_paths_ready "$installer" "$keeper" "$service" "$run_id" \
        'AUTOPIOVERCLOCK MANAGED DEBIAN NETWORK WATCHDOG' || {
        emit_result PREFLIGHT_FAILURE 'The uploaded Debian network-watchdog assets are missing, foreign, or unsafe.'
        return 1
    }
    "$installer" apply "$keeper" "$service" "${@:4}"
}

cmd_install_network_watchdog_observer() {
    local installer=${1:-} observer=${2:-} service=${3:-} run_id=${4:-}
    debian_network_watchdog_asset_paths_ready "$installer" "$observer" "$service" "$run_id" \
        'AUTOPIOVERCLOCK MANAGED DEBIAN NETWORK WATCHDOG OBSERVER' || {
        emit_result PREFLIGHT_FAILURE 'The uploaded Debian watchdog-observer assets are missing, foreign, or unsafe.'
        return 1
    }
    "$installer" apply "$observer" "$service" "${@:4}"
}

cmd_cleanup_network_watchdog() {
    local installer=${1:-} run_id=${2:-} marker
    if [[ $installer == *observer* ]]; then
        marker='AUTOPIOVERCLOCK MANAGED DEBIAN NETWORK WATCHDOG OBSERVER'
    else
        marker='AUTOPIOVERCLOCK MANAGED DEBIAN NETWORK WATCHDOG'
    fi
    debian_network_watchdog_installer_ready "$installer" "$run_id" "$marker" || {
        emit_result RECOVERY_FAILURE 'The uploaded Debian watchdog cleanup installer is missing or unsafe.'
        return 1
    }
    "$installer" cleanup "${@:2}"
}

cmd_prove_network_watchdog_reboot() {
    local expected_old_boot=${1:-} expected_new_boot=${2:-} expected_target=${3:-}
    local expected_config_hash=${4:-} expected_keeper_hash=${5:-} expected_service_hash=${6:-}
    local expected_kind=${7:-} previous_event=${8:-}
    local root=/var/lib/autopioverclock/network-watchdog
    local config keeper service proof_method
    local event=$root/last-network-reboot pending=$root/pending-network-reboot log=$root/watchdog.log
    local fields format event_id source_boot target failure_epoch request_epoch marker_config_hash marker_keeper_hash marker_service_hash reason
    local current_boot config_target config_hash keeper_hash service_hash native_target now uptime boot_epoch
    local chain_count=1 chain_reason
    [[ $expected_old_boot =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ &&
       $expected_new_boot =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ &&
       $expected_old_boot != "$expected_new_boot" &&
       ( $expected_kind == debian-systemd-companion || $expected_kind == debian-watchdog-observer ) &&
       ( -z $previous_event || $previous_event =~ ^[0-9a-f]{32}$ ) ]] || {
        emit_result HARNESS_FAILURE 'Strict network-watchdog proof received malformed boot identity.'
        return 1
    }
    case $expected_kind in
        debian-systemd-companion)
            config=$root/watchdog.conf
            keeper=/usr/local/lib/autopioverclock/network-watchdog-keeper.py
            service=/etc/systemd/system/autopioverclock-network-watchdog.service
            proof_method=systemctl-reboot
            ;;
        debian-watchdog-observer)
            config=$root/observer.conf
            keeper=/usr/local/lib/autopioverclock/network-watchdog-observer.py
            service=/etc/systemd/system/autopioverclock-network-watchdog-observer.service
            proof_method=debian-watchdog-journal
            ;;
    esac
    debian_network_watchdog_valid_ipv4 "$expected_target" && valid_sha256 "$expected_config_hash" &&
        valid_sha256 "$expected_keeper_hash" && valid_sha256 "$expected_service_hash" || {
        emit_result HARNESS_FAILURE 'Strict network-watchdog proof received malformed saved discovery hashes.'
        return 1
    }
    for required_file in "$config" "$keeper" "$event" "$log" "$service"; do
        [[ -f $required_file && ! -L $required_file ]] || {
            emit_result HARNESS_FAILURE 'Strict network-watchdog proof is missing a regular project-owned evidence file.'
            return 1
        }
    done
    [[ ! -e $pending && ! -L $pending ]] || {
        emit_result HARNESS_FAILURE 'The network-watchdog reboot still has an unresolved pending marker.'
        return 1
    }
    current_boot=$(tr -d '\r\n' </proc/sys/kernel/random/boot_id 2>/dev/null || true)
    [[ $current_boot == "$expected_new_boot" ]] || {
        emit_result HARNESS_FAILURE 'Strict network-watchdog proof does not match the current target boot.'
        return 1
    }
    fields=$(debian_network_watchdog_event_fields "$event" 2>/dev/null) || {
        emit_result HARNESS_FAILURE 'The project-owned network-watchdog marker is malformed.'
        return 1
    }
    IFS=$'\t' read -r format event_id source_boot target failure_epoch request_epoch marker_config_hash marker_keeper_hash marker_service_hash reason <<<"$fields"
    [[ $format == 1 && $event_id =~ ^[0-9a-f]{32}$ && $event_id != "$previous_event" &&
       $reason == TARGET_UNREACHABLE &&
       $failure_epoch =~ ^[1-9][0-9]*$ && $request_epoch =~ ^[1-9][0-9]*$ &&
       $failure_epoch -le $request_epoch ]] || {
        emit_result HARNESS_FAILURE 'The project-owned network-watchdog marker does not identify this reboot uniquely.'
        return 1
    }
    if [[ $source_boot != "$expected_old_boot" ]]; then
        APO_WATCHDOG_CHAIN_EVENT_ID=''
        APO_WATCHDOG_CHAIN_FINAL_SOURCE=''
        APO_WATCHDOG_CHAIN_REQUEST_EPOCH=''
        APO_WATCHDOG_CHAIN_COUNT=0
        if network_watchdog_archive_chain "$root" "$expected_old_boot" "$expected_new_boot" \
            "$expected_target" "$expected_config_hash" "$expected_keeper_hash" \
            "$expected_service_hash" "$proof_method" "$previous_event" ||
           network_watchdog_log_chain "$log" "$expected_old_boot" "$expected_new_boot" \
            "$expected_target" "$proof_method" "$previous_event"; then
            [[ $APO_WATCHDOG_CHAIN_EVENT_ID == "$event_id" &&
               $APO_WATCHDOG_CHAIN_FINAL_SOURCE == "$source_boot" &&
               $APO_WATCHDOG_CHAIN_REQUEST_EPOCH == "$request_epoch" &&
               $APO_WATCHDOG_CHAIN_COUNT =~ ^[1-9][0-9]*$ ]] || {
                emit_result HARNESS_FAILURE 'The accepted watchdog chain does not terminate at the current reboot marker.'
                return 1
            }
            chain_count=$APO_WATCHDOG_CHAIN_COUNT
        else
            emit_result HARNESS_FAILURE 'The project-owned watchdog evidence does not form a complete reboot chain to the current boot.'
            return 1
        fi
    fi
    if [[ $expected_kind == debian-watchdog-observer ]]; then
        config_target=$(debian_network_watchdog_observer_config_target "$config" || true)
        native_target=$(debian_native_network_watchdog_target || true)
        [[ -n $native_target && $native_target == "$expected_target" ]] || {
            emit_result HARNESS_FAILURE 'The native Debian watchdog no longer has the observed liveness target.'
            return 1
        }
    else
        config_target=$(debian_network_watchdog_config_target "$config" || true)
    fi
    [[ -n $config_target && $target == "$config_target" && $target == "$expected_target" ]] || {
        emit_result HARNESS_FAILURE 'The network-watchdog marker target does not match the active managed configuration.'
        return 1
    }
    config_hash=$(sha256sum "$config" | awk 'NR == 1 {print $1}')
    keeper_hash=$(sha256sum "$keeper" | awk 'NR == 1 {print $1}')
    service_hash=$(sha256sum "$service" | awk 'NR == 1 {print $1}')
    [[ $config_hash == "$marker_config_hash" && $config_hash == "$expected_config_hash" &&
       $keeper_hash == "$marker_keeper_hash" && $keeper_hash == "$expected_keeper_hash" &&
       $service_hash == "$marker_service_hash" && $service_hash == "$expected_service_hash" ]] || {
        emit_result HARNESS_FAILURE 'The network-watchdog marker is not hash-bound to the active packaged service.'
        return 1
    }
    now=$(date +%s)
    uptime=$(cut -d. -f1 /proc/uptime 2>/dev/null || true)
    [[ $now =~ ^[1-9][0-9]*$ && $uptime =~ ^[0-9]+$ ]] || {
        emit_result HARNESS_FAILURE 'The current boot time could not be established for strict watchdog proof.'
        return 1
    }
    boot_epoch=$((now - uptime))
    (( request_epoch >= boot_epoch - 300 && request_epoch <= boot_epoch + 120 )) || {
        emit_result HARNESS_FAILURE 'The network-watchdog marker timestamp does not bound the current boot.'
        return 1
    }
    grep -Fq "network_reboot_accepted event_id=$event_id source_boot_id=$source_boot target=$target requested_epoch=$request_epoch" "$log" || {
        emit_result HARNESS_FAILURE 'The durable watchdog log does not corroborate the accepted reboot request.'
        return 1
    }
    grep -Eq "network_reboot_prepared event_id=$event_id source_boot_id=$source_boot target=$target prepared_epoch=[1-9][0-9]*( method=debian-watchdog-journal)?$" "$log" || {
        emit_result HARNESS_FAILURE 'The durable watchdog log does not corroborate preparation of the reboot request.'
        return 1
    }
    grep -Eq "network_reboot_committed event_id=$event_id source_boot_id=$source_boot target=$target requested_epoch=$request_epoch method=$proof_method( outcome=[A-Za-z0-9-]+)?$" "$log" || {
        emit_result HARNESS_FAILURE 'The durable watchdog log does not prove that systemd accepted this reboot request.'
        return 1
    }
    if [[ $expected_kind == debian-watchdog-observer ]]; then
        debian_network_watchdog_observer_service_ready "$keeper" "$service"
    else
        debian_network_watchdog_service_ready "$keeper" "$config" "$service"
    fi || {
        emit_result HARNESS_FAILURE 'The project-owned network-watchdog service is not active with the verified assets.'
        return 1
    }
    emit_data NETWORK_WATCHDOG_EVENT_ID "$event_id"
    emit_data NETWORK_WATCHDOG_TARGET "$target"
    emit_data NETWORK_WATCHDOG_SOURCE_BOOT_ID "$expected_old_boot"
    emit_data NETWORK_WATCHDOG_FINAL_SOURCE_BOOT_ID "$source_boot"
    emit_data NETWORK_WATCHDOG_REQUESTED_EPOCH "$request_epoch"
    emit_data NETWORK_WATCHDOG_REBOOT_COUNT "$chain_count"
    if (( chain_count == 1 )); then
        chain_reason="Project-owned network watchdog strictly proved that target $target caused the reboot from boot $expected_old_boot."
    else
        chain_reason="Project-owned network watchdog strictly proved $chain_count consecutive target-$target watchdog reboots from boot $expected_old_boot to boot $expected_new_boot."
    fi
    emit_result PASS "$chain_reason"
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
        status-snapshot) cmd_status_snapshot "$@" ;;
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
        render-complete) cmd_render_complete "$@" ;;
        reset-stock) run_with_mutation_lock "reset-${2:-}" APPLY_FAILURE cmd_reset_stock "$@" ;;
        reboot-stock-reset) run_with_mutation_lock "reset-reboot-${BASHPID}" RECOVERY_FAILURE cmd_reboot_stock_reset "$@" ;;
        verify-stock-reset) run_with_mutation_lock "reset-verify-${BASHPID}" RECOVERY_FAILURE cmd_verify_stock_reset "$@" ;;
        apply-permanent) run_with_mutation_lock "apply-${4:-}" APPLY_FAILURE cmd_apply_permanent "$@" ;;
        complete-permanent) run_with_mutation_lock "complete-${4:-}" APPLY_FAILURE cmd_complete_permanent "$@" ;;
        cleanup-complete-artifacts) run_with_mutation_lock "complete-cleanup-${3:-}" RECOVERY_FAILURE cmd_cleanup_complete_artifacts "$@" ;;
        restore-backup) run_with_mutation_lock "restore-${2:-}" APPLY_FAILURE cmd_restore_backup "$@" ;;
        plan-watchdog-repair) cmd_plan_watchdog_repair "$@" ;;
        repair-watchdogs) run_with_mutation_lock "watchdog-${5:-}" PREFLIGHT_FAILURE cmd_repair_watchdogs "$@" ;;
        plan-network-watchdog) cmd_plan_network_watchdog "$@" ;;
        install-network-watchdog) run_with_mutation_lock "network-watchdog-${4:-}" PREFLIGHT_FAILURE cmd_install_network_watchdog "$@" ;;
        plan-network-watchdog-observer) cmd_plan_network_watchdog_observer "$@" ;;
        install-network-watchdog-observer) run_with_mutation_lock "network-watchdog-observer-${4:-}" PREFLIGHT_FAILURE cmd_install_network_watchdog_observer "$@" ;;
        cleanup-network-watchdog) run_with_mutation_lock "network-watchdog-cleanup-${2:-}" RECOVERY_FAILURE cmd_cleanup_network_watchdog "$@" ;;
        prove-network-watchdog-reboot) cmd_prove_network_watchdog_reboot "$@" ;;
        classify-kernel-log) cmd_classify_kernel_log "$@" ;;
        *) emit_result HARNESS_FAILURE "Unknown worker command: $command_name"; return 2 ;;
    esac
}

if [[ ${APO_WORKER_LIBRARY_ONLY:-0} != 1 ]]; then main "$@"; fi
