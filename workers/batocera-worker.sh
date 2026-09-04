#!/usr/bin/env bash
# AutoPiOverclock remote worker for Batocera/Buildroot on Raspberry Pi 5.
set -u -o pipefail
umask 077

ERROR_PATTERN='under.?voltage|throttl|Hardware Error|SError|Kernel panic|Internal error[[:space:]]*:|Unable to handle kernel|RCU.*(detected|self-detected).*stall|kthread starved for|kthread timer wakeup.*happen|hung[_ -]?task|task[[:space:]].*blocked for more than[[:space:]]+[0-9]+[[:space:]]+seconds|v3d.*(hang|fault|error|timeout)|drm.*(hang|fault|error|timeout)|device offline|I/O error|Buffer I/O error|EXT4-fs (error|warning)|BTRFS.*(error|warning)|segfault|Oops:|BUG:|Call trace|watchdog:.*lockup'
USB_RESET_PATTERN='usb [0-9.-]+: reset (low-speed|full-speed|high-speed|SuperSpeed|SuperSpeed Plus)?[[:space:]]*USB device|reset (low-speed|full-speed|high-speed|SuperSpeed|SuperSpeed Plus)[[:space:]]+USB device'
CLOCK_MARKER_BEGIN='# BEGIN AUTOPIOVERCLOCK MANAGED CLOCKS'
CLOCK_MARKER_END='# END AUTOPIOVERCLOCK MANAGED CLOCKS'
CANDIDATE_FAN_COMMENT='# AUTOPIOVERCLOCK CANDIDATE COOLING: PI PWM FAN 100 PERCENT'
TRYBOOT_RESERVATION_MARKER='# AUTOPIOVERCLOCK TRYBOOT RESERVATION'
PERSISTENT_ROOT=/userdata/system/autopioverclock
MUTATION_LOCK_DIR=/run/autopioverclock-mutation.lock
MUTATION_LOCK_HELD=0
MUTATION_LOCK_OWNER=''
OPENSSL_CPU_BLOCK_BYTES=1048576

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
    [[ $1 == /boot/config.txt && $2 == /boot/tryboot.txt ]]
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

kernel_log() { dmesg 2>/dev/null || true; }
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
boot_mount_has_option() {
    local wanted_option=$1 mounts_file=${2:-/proc/mounts}
    local mount_source mount_point filesystem mount_options dump_frequency pass_number
    [[ $wanted_option == ro || $wanted_option == rw ]] || return 1
    [[ -r $mounts_file ]] || return 1
    while read -r mount_source mount_point filesystem mount_options dump_frequency pass_number; do
        [[ $mount_point == /boot ]] || continue
        case ",$mount_options," in
            *",$wanted_option,"*) return 0 ;;
        esac
    done < "$mounts_file"
    return 1
}
remount_boot_rw() { mount -o remount,rw /boot && boot_mount_has_option rw; }
remount_boot_ro() { mount -o remount,ro /boot && boot_mount_has_option ro; }

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
    local voltage_render_mode=${8:-explicit}
    [[ $voltage_render_mode == explicit || $voltage_render_mode == omit-default-zero ]] || return 1
    [[ $voltage_render_mode != omit-default-zero || $voltage_uv == 0 ]] || return 1
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
    ' "$source_file" > "$destination_file" || return 1
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

batocera_environment() {
    export HOME=/userdata/system
    export DISPLAY=:0.0
    export SWAYSOCK=/var/run/sway-ipc.0.sock
    export XDG_RUNTIME_DIR=/run
    export PIPEWIRE_RUNTIME_DIR=/run
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

sway_first_active_connector() {
    local outputs=$1
    printf '%s' "$outputs" | /usr/bin/python3 -c '
import json
import sys

try:
    outputs = json.load(sys.stdin)
except (TypeError, ValueError):
    raise SystemExit(1)
if not isinstance(outputs, list):
    raise SystemExit(1)

for output in outputs:
    if isinstance(output, dict) and output.get("active") is True and isinstance(output.get("name"), str):
        print(output["name"], end="")
        raise SystemExit(0)
raise SystemExit(1)
'
}

sway_connector_is_active() {
    local outputs=$1 expected_connector=$2
    printf '%s' "$outputs" | /usr/bin/python3 -c '
import json
import sys

expected = sys.argv[1]
try:
    outputs = json.load(sys.stdin)
except (TypeError, ValueError):
    raise SystemExit(1)
if not isinstance(outputs, list):
    raise SystemExit(1)

raise SystemExit(0 if any(
    isinstance(output, dict)
    and output.get("name") == expected
    and output.get("active") is True
    for output in outputs
) else 1)
' "$expected_connector"
}

graphical_baseline() {
    local outputs mode connector_name frontend
    batocera_environment
    outputs=$(timeout 6 swaymsg -t get_outputs -r 2>/dev/null || true)
    connector_name=$(sway_first_active_connector "$outputs" || true)
    mode=$(timeout 6 batocera-resolution currentMode 2>/dev/null || true)
    frontend=$(pidof emulationstation 2>/dev/null || true)
    [[ -n $connector_name && -n $mode && $mode != nullxnull.null && -n $frontend ]] || return 1
    printf 'connector=%s;mode=%s;frontend=emulationstation' "$connector_name" "$mode"
}

audio_identity() {
    local identity='' probe_timeout
    batocera_environment
    probe_timeout=$(bounded_probe_timeout 6) || return 1
    if command -v wpctl >/dev/null 2>&1; then
        identity=$(timeout "$probe_timeout" wpctl inspect @DEFAULT_AUDIO_SINK@ 2>/dev/null | sed -n 's/^[[:space:]]*[*]*[[:space:]]*node\.name[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    elif command -v pactl >/dev/null 2>&1; then
        identity=$(timeout "$probe_timeout" pactl get-default-sink 2>/dev/null | tr -d '\r\n')
    fi
    [[ -n $identity ]] || return 1
    printf '%s' "$identity"
}

display_hardware_present() {
    local drm_root=${1:-/sys/class/drm} status_file
    for status_file in "$drm_root"/card*-*/status; do
        [[ -r $status_file ]] || continue
        [[ $(<"$status_file") == connected ]] && return 0
    done
    return 1
}

find_glmark_binary() {
    local mode=${1:-headless} binary_name candidate_file
    case $mode in
        graphical) binary_name=glmark2-es2-wayland ;;
        headless) binary_name=glmark2-es2-drm ;;
        *) return 1 ;;
    esac
    for candidate_file in \
        "$PERSISTENT_ROOT/glmark2/usr/bin/$binary_name" \
        "/userdata/system/overclock/glmark2/usr/bin/$binary_name"; do
        [[ -x $candidate_file ]] && { printf '%s' "$candidate_file"; return 0; }
    done
    return 1
}

find_glmark_data() {
    local candidate_dir
    for candidate_dir in \
        "$PERSISTENT_ROOT/glmark2/usr/share/glmark2" \
        /userdata/system/overclock/glmark2/usr/share/glmark2; do
        [[ -d $candidate_dir ]] && { printf '%s' "$candidate_dir"; return 0; }
    done
    return 1
}

find_glmark_library_dirs() {
    local candidate_dir result=''
    for candidate_dir in \
        "$PERSISTENT_ROOT/glmark2/jpeg-package/usr/lib/aarch64-linux-gnu" \
        "$PERSISTENT_ROOT/glmark2/usr/lib/aarch64-linux-gnu" \
        /userdata/system/overclock/glmark2/jpeg-package/usr/lib/aarch64-linux-gnu \
        /userdata/system/overclock/glmark2/usr/lib/aarch64-linux-gnu; do
        [[ -d $candidate_dir ]] || continue
        result+="${result:+:}${candidate_dir}"
    done
    printf '%s' "$result"
}

gpu_stack_probe() {
    local render_node render_name driver_path driver_name
    for render_node in /dev/dri/renderD*; do
        [[ -e $render_node ]] || continue
        render_name=${render_node##*/}
        driver_path=$(readlink -f "/sys/class/drm/${render_name}/device/driver" 2>/dev/null || true)
        driver_name=${driver_path##*/}
        if [[ $driver_name == v3d ]]; then
            printf 'render_node=%s;driver=%s' "$render_node" "$driver_name"
            return 0
        fi
    done
    return 1
}

gpu_output_has_v3d_renderer() {
    local output_file=$1
    grep -Ei '^[[:space:]]*GL_RENDERER:[[:space:]]*.*V3D' "$output_file" >/dev/null 2>&1 &&
        ! grep -Ei '^[[:space:]]*GL_RENDERER:[[:space:]]*.*(llvmpipe|softpipe|swrast|software)' "$output_file" >/dev/null 2>&1
}

gpu_output_has_positive_score() {
    local output_file=$1
    awk '
        /glmark2 Score:/ {
            for (field = 1; field <= NF; field++) {
                if ($field ~ /^[0-9]+([.][0-9]+)?$/ && ($field + 0) > 0) found = 1
            }
        }
        END {exit !found}
    ' "$output_file"
}

gpu_output_has_harness_error() {
    local output_file=$1
    grep -Eqi 'Could not initialize|glwindow has never been initialized|Failed to become DRM master|drmModeGetResources|GBM.*(fail|error)|EGL.*(fail|error)|Wayland.*(fail|error|connect|unavailable)|failed to connect to.*Wayland|XDG_RUNTIME_DIR.*(invalid|not set|unavailable)|WAYLAND_DISPLAY.*(invalid|not set|unavailable)|MESA-LOADER.*(fail|error)|failed to open.*(DRM|render|card)|GLIBC_[0-9.]+.*not found|version [`'\''"]?[^ ]+[`'\''"]? not found|undefined symbol|symbol lookup error|error while loading shared libraries|No such file|Permission denied|unrecognized option|unknown option' "$output_file"
}

gpu_early_exit_class() {
    local exit_code=$1 output_file=$2
    if (( exit_code == 0 )) || ! gpu_output_has_v3d_renderer "$output_file" || gpu_output_has_harness_error "$output_file"; then
        printf HARNESS_FAILURE
    else
        printf STABILITY_FAILURE
    fi
}

stress_completion_tolerance() {
    local duration=$1 tolerance
    tolerance=$((duration / 1000))
    (( tolerance < 3 )) && tolerance=3
    (( tolerance > 30 )) && tolerance=30
    printf '%s' "$tolerance"
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
    local device_path=$1 sys_root=${2:-/sys} device_id major_hex minor_hex expected_dev class_dev_file class_dev watchdog_name='' matched_name timeout_file timeout_value
    device_id=$(stat -Lc '%t:%T' "$device_path" 2>/dev/null || true)
    [[ $device_id == *:* ]] || return 1
    major_hex=${device_id%:*}
    minor_hex=${device_id#*:}
    [[ $major_hex =~ ^[0-9a-fA-F]+$ && $minor_hex =~ ^[0-9a-fA-F]+$ ]] || return 1
    (( ${#major_hex} <= 8 && ${#minor_hex} <= 8 )) || return 1
    expected_dev="$((16#$major_hex)):$((16#$minor_hex))"
    for class_dev_file in "$sys_root"/class/watchdog/watchdog[0-9]*/dev; do
        [[ -f $class_dev_file && -r $class_dev_file ]] || continue
        class_dev=$(cat -- "$class_dev_file" 2>/dev/null) || return 1
        [[ $class_dev =~ ^[0-9]+:[0-9]+$ ]] || return 1
        [[ $class_dev == "$expected_dev" ]] || continue
        matched_name=${class_dev_file%/dev}
        matched_name=${matched_name##*/}
        [[ -z $watchdog_name ]] || return 1
        watchdog_name=$matched_name
    done
    [[ $watchdog_name =~ ^watchdog[0-9]+$ ]] || return 1
    timeout_file="$sys_root/class/watchdog/$watchdog_name/timeout"
    if [[ ! -e $timeout_file ]]; then
        [[ ! -L $timeout_file ]] || return 1
        return 2
    fi
    [[ -f $timeout_file && -r $timeout_file ]] || return 1
    timeout_value=$(cat -- "$timeout_file" 2>/dev/null) || return 1
    [[ $timeout_value =~ ^[1-9][0-9]*$ ]] || return 1
    printf '%s' "$timeout_value"
}

watchdog_owner_pid_fd() {
    local owner=${1-} owner_pattern pid owner_comm owner_fd
    owner_pattern='^pid=([1-9][0-9]*);comm=([A-Za-z0-9_.:+@()-]+);fd=(0|[1-9][0-9]*)$'
    [[ $owner =~ $owner_pattern ]] || return 1
    pid=${BASH_REMATCH[1]}
    owner_comm=${BASH_REMATCH[2]}
    owner_fd=${BASH_REMATCH[3]}
    (( ${#pid} <= 10 && ${#owner_comm} <= 64 && ${#owner_fd} <= 10 )) || return 1
    printf '%s\t%s\t%s' "$pid" "$owner_fd" "$owner_comm"
}

watchdog_runtime_timeout_pidfd() {
    local device_path=$1 owner_pid=$2 owner_fd=$3 owner_comm=$4
    [[ $device_path =~ ^/dev/watchdog([0-9]+)?$ ]] || return 1
    [[ $owner_pid =~ ^[1-9][0-9]*$ && ${#owner_pid} -le 10 ]] || return 1
    [[ $owner_fd =~ ^(0|[1-9][0-9]*)$ && ${#owner_fd} -le 10 ]] || return 1
    [[ $owner_comm =~ ^[A-Za-z0-9_.:+@()-]+$ && ${#owner_comm} -le 64 ]] || return 1
    [[ $(uname -m 2>/dev/null || true) =~ ^(aarch64|arm64)$ ]] || return 1
    [[ -x /usr/bin/python3 ]] || return 1
    command -v timeout >/dev/null 2>&1 || return 1
    timeout -k 1 6 /usr/bin/python3 - "$device_path" "$owner_pid" "$owner_fd" "$owner_comm" 2>/dev/null <<'APO_WATCHDOG_PIDFD_PY'
import array
import ctypes
import fcntl
import glob
import os
import re
import select
import stat
import sys

SYS_PIDFD_OPEN = 434
SYS_PIDFD_GETFD = 438
WDIOC_GETTIMEOUT = 0x80045707
INT_MAX = 2**31 - 1


def reject():
    raise RuntimeError("watchdog proof failed")


def read_bytes(path, limit):
    with open(path, "rb") as handle:
        value = handle.read(limit + 1)
    if len(value) > limit:
        reject()
    return value


def process_starttime(pid):
    value = read_bytes(f"/proc/{pid}/stat", 8192).decode("ascii", "strict")
    marker = value.rfind(") ")
    if marker < 0:
        reject()
    fields = value[marker + 2:].split()
    if len(fields) < 20 or not fields[19].isdigit():
        reject()
    return fields[19]


def process_comm(pid):
    value = read_bytes(f"/proc/{pid}/comm", 256)
    return value.replace(b"\t", b"_").replace(b" ", b"_").replace(b"\r", b"").replace(b"\n", b"")


def fdinfo_snapshot(pid, target_fd):
    value = read_bytes(f"/proc/{pid}/fdinfo/{target_fd}", 8192).decode("ascii", "strict")
    fields = {}
    for line in value.splitlines():
        key, separator, item = line.partition(":")
        if separator:
            fields[key] = item.strip()
    if "flags" not in fields:
        reject()
    flags = int(fields["flags"], 8)
    if (flags & os.O_ACCMODE) not in (os.O_WRONLY, os.O_RDWR):
        reject()
    return flags, fields.get("mnt_id", ""), fields.get("ino", "")


def require_original(pid, target_fd, expected_starttime, expected_comm, expected_rdev):
    if process_starttime(pid) != expected_starttime:
        reject()
    if process_comm(pid) != expected_comm:
        reject()
    target = os.stat(f"/proc/{pid}/fd/{target_fd}")
    if not stat.S_ISCHR(target.st_mode) or target.st_rdev != expected_rdev:
        reject()
    return fdinfo_snapshot(pid, target_fd)


def require_pidfd_live(poller):
    if poller.poll(0):
        reject()


if len(sys.argv) != 5 or os.uname().machine not in ("aarch64", "arm64"):
    reject()

device_path, pid_text, fd_text, owner_comm_text = sys.argv[1:]
if not re.fullmatch(r"/dev/watchdog(?:[0-9]+)?", device_path):
    reject()
if not re.fullmatch(r"[1-9][0-9]*", pid_text) or not re.fullmatch(r"(?:0|[1-9][0-9]*)", fd_text):
    reject()
pid = int(pid_text, 10)
target_fd = int(fd_text, 10)
if pid > INT_MAX or target_fd > INT_MAX:
    reject()
expected_comm = os.fsencode(owner_comm_text)

device = os.stat(device_path)
if not stat.S_ISCHR(device.st_mode):
    reject()
expected_rdev = device.st_rdev
expected_dev_text = f"{os.major(expected_rdev)}:{os.minor(expected_rdev)}"
class_matches = []
for class_dev in glob.glob("/sys/class/watchdog/watchdog[0-9]*/dev"):
    if read_bytes(class_dev, 64).decode("ascii", "strict").strip() == expected_dev_text:
        class_matches.append(class_dev)
if len(class_matches) != 1:
    reject()

starttime = process_starttime(pid)
initial_snapshot = require_original(pid, target_fd, starttime, expected_comm, expected_rdev)

libc = ctypes.CDLL(None, use_errno=True)
libc.syscall.restype = ctypes.c_long
pidfd = -1
duplicate_fd = -1
timeout_value = 0
try:
    pidfd = libc.syscall(ctypes.c_long(SYS_PIDFD_OPEN), ctypes.c_long(pid), ctypes.c_long(0))
    if pidfd < 0:
        reject()
    poller = select.poll()
    poller.register(pidfd, select.POLLIN | select.POLLHUP | select.POLLERR)
    require_pidfd_live(poller)
    if require_original(pid, target_fd, starttime, expected_comm, expected_rdev) != initial_snapshot:
        reject()
    try:
        duplicate_fd = libc.syscall(
            ctypes.c_long(SYS_PIDFD_GETFD), ctypes.c_long(pidfd), ctypes.c_long(target_fd), ctypes.c_long(0)
        )
        if duplicate_fd < 0:
            reject()
        duplicate = os.fstat(duplicate_fd)
        if not stat.S_ISCHR(duplicate.st_mode) or duplicate.st_rdev != expected_rdev:
            reject()
        duplicate_flags = fcntl.fcntl(duplicate_fd, fcntl.F_GETFL)
        if (duplicate_flags & os.O_ACCMODE) not in (os.O_WRONLY, os.O_RDWR):
            reject()
        timeout_buffer = array.array("i", [0])
        if timeout_buffer.itemsize != 4:
            reject()
        fcntl.ioctl(duplicate_fd, WDIOC_GETTIMEOUT, timeout_buffer, True)
        timeout_value = int(timeout_buffer[0])
        if timeout_value <= 0 or timeout_value > INT_MAX:
            reject()
        require_pidfd_live(poller)
        if require_original(pid, target_fd, starttime, expected_comm, expected_rdev) != initial_snapshot:
            reject()
    finally:
        if duplicate_fd >= 0:
            os.close(duplicate_fd)
            duplicate_fd = -1
    require_pidfd_live(poller)
    if require_original(pid, target_fd, starttime, expected_comm, expected_rdev) != initial_snapshot:
        reject()
finally:
    if duplicate_fd >= 0:
        os.close(duplicate_fd)
    if pidfd >= 0:
        os.close(pidfd)

print(timeout_value)
APO_WATCHDOG_PIDFD_PY
}

watchdog_runtime_timeout_effective() {
    local device_path=$1 owner=${2-} sys_root=${3:-/sys}
    local timeout_value runtime_status parsed_owner owner_pid owner_fd owner_comm owner_after
    if timeout_value=$(watchdog_runtime_timeout "$device_path" "$sys_root"); then
        printf '%s' "$timeout_value"
        return 0
    else
        runtime_status=$?
    fi
    (( runtime_status == 2 )) || return 1
    parsed_owner=$(watchdog_owner_pid_fd "$owner") || return 1
    IFS=$'\t' read -r owner_pid owner_fd owner_comm <<< "$parsed_owner"
    timeout_value=$(watchdog_runtime_timeout_pidfd "$device_path" "$owner_pid" "$owner_fd" "$owner_comm") || return 1
    [[ $timeout_value =~ ^[1-9][0-9]*$ ]] || return 1
    owner_after=$(watchdog_userspace_owner "$device_path") || return 1
    [[ $owner_after == "$owner" ]] || return 1
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
    WATCHDOG_LAST_OWNER=$(watchdog_userspace_owner "$WATCHDOG_LAST_DEVICE" || true)
    [[ -n $WATCHDOG_LAST_OWNER ]] || {
        WATCHDOG_LAST_REASON="No userspace process owns $WATCHDOG_LAST_DEVICE."
        return 1
    }
    WATCHDOG_LAST_RUNTIME_TIMEOUT=$(watchdog_runtime_timeout_effective "$WATCHDOG_LAST_DEVICE" "$WATCHDOG_LAST_OWNER" || true)
    [[ $WATCHDOG_LAST_RUNTIME_TIMEOUT =~ ^[0-9]+$ ]] && (( WATCHDOG_LAST_RUNTIME_TIMEOUT > 0 )) || {
        WATCHDOG_LAST_REASON="The active watchdog device has no positive runtime timeout (${WATCHDOG_LAST_RUNTIME_TIMEOUT:-missing})."
        return 1
    }
}

cmd_discover() {
    local boot_config=/boot/config.txt tryboot_config=/boot/tryboot.txt gpu_key normal_cpu normal_gpu normal_voltage normal_voltage_source
    local model compatible version boot_watchdog kernel_watchdog watchdog_device watchdog_runtime_timeout_value watchdog_owner root_device boot_source baseline display_present audio_baseline permanent_hash glmark_binary glmark_wayland_binary glmark_drm_binary glmark_data
    local openssl_binary tryboot_exists tryboot_type tryboot_hash
    [[ -f $boot_config ]] || { emit_result PREFLIGHT_FAILURE 'Batocera boot config /boot/config.txt was not found.'; return 1; }
    audit_permanent_tuning_config "$boot_config"
    inspect_tryboot_path "$tryboot_config" tryboot_exists tryboot_type tryboot_hash
    model=$(tr -d '\000' < /proc/device-tree/model 2>/dev/null || true)
    compatible=$(tr '\000' ',' < /proc/device-tree/compatible 2>/dev/null || true)
    version=$(cat /usr/share/batocera/batocera.version 2>/dev/null || batocera-version 2>/dev/null || true)
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
    watchdog_device=$(watchdog_device_path || true)
    watchdog_owner=$([[ -n $watchdog_device ]] && watchdog_userspace_owner "$watchdog_device" || true)
    watchdog_runtime_timeout_value=$([[ -n $watchdog_device && -n $watchdog_owner ]] && watchdog_runtime_timeout_effective "$watchdog_device" "$watchdog_owner" || true)
    root_device=$(root_source)
    boot_source=$(findmnt -n -o SOURCE /boot 2>/dev/null || mount | awk '$3=="/boot"{print $1; exit}')
    baseline=$(graphical_baseline || true)
    display_present=$(display_hardware_present && printf 1 || printf 0)
    audio_baseline=$(audio_identity || true)
    permanent_hash=$(permanent_config_snapshot_hash "$boot_config" || true)
    if [[ -n $PERMANENT_TUNING_CONFIG_HASH && $permanent_hash != "$PERMANENT_TUNING_CONFIG_HASH" ]]; then
        PERMANENT_TUNING_PROVENANCE=ambiguous
        PERMANENT_TUNING_EVIDENCE='permanent-config-changed-after-audit'
    fi
    glmark_wayland_binary=$(find_glmark_binary graphical || true)
    glmark_drm_binary=$(find_glmark_binary headless || true)
    glmark_binary=$glmark_wayland_binary
    [[ -n $glmark_binary ]] || glmark_binary=$glmark_drm_binary
    glmark_data=$(find_glmark_data || true)
    openssl_binary=$(command -v openssl 2>/dev/null || true)
    fan_pwm_snapshot >/dev/null 2>&1 || true

    emit_data PROFILE batocera
    emit_data MODEL "$model"
    emit_data COMPATIBLE "$compatible"
    emit_data ARCH "$(uname -m)"
    emit_data OS_ID batocera
    emit_data OS_VERSION "$version"
    emit_data BOOT_CONFIG "$boot_config"
    emit_data TRYBOOT_CONFIG "$tryboot_config"
    emit_data TRYBOOT_EXISTS "$tryboot_exists"
    emit_data TRYBOOT_TYPE "$tryboot_type"
    emit_data TRYBOOT_HASH "$tryboot_hash"
    emit_data BOOT_MOUNT /boot
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
    emit_data RUNTIME_WATCHDOG "$watchdog_owner"
    emit_data WATCHDOG_DEVICE "$watchdog_device"
    emit_data WATCHDOG_RUNTIME_TIMEOUT "$watchdog_runtime_timeout_value"
    emit_data WATCHDOG_OWNER "$watchdog_owner"
    emit_data ROOT_SOURCE "$root_device"
    emit_data BOOT_SOURCE "$boot_source"
    emit_data DISPLAY_BASELINE "$baseline"
    emit_data DISPLAY_PRESENT "$display_present"
    emit_data AUDIO_BASELINE "$audio_baseline"
    emit_data DISPLAY_CONNECTED "$([[ -n $baseline ]] && printf 1 || printf 0)"
    emit_data CPU_STRESS_AVAILABLE "$([[ -n $openssl_binary ]] && printf 1 || printf 0)"
    emit_data GPU_STRESS_AVAILABLE "$([[ -n $glmark_data && ( -n $glmark_wayland_binary || -n $glmark_drm_binary ) ]] && printf 1 || printf 0)"
    emit_data OPENSSL_BINARY "$openssl_binary"
    emit_data GLMARK_BINARY "$glmark_binary"
    emit_data GLMARK_WAYLAND_BINARY "$glmark_wayland_binary"
    emit_data GLMARK_DRM_BINARY "$glmark_drm_binary"
    emit_data GLMARK_DATA "$glmark_data"
    emit_data GLMARK_LIBRARY_DIRS "$(find_glmark_library_dirs)"
    emit_data FAN_PWM_STATUS "$FAN_PWM_LAST_STATUS"
    emit_data PERMANENT_HASH "$permanent_hash"
    emit_data STORAGE_LAYOUT "root=${root_device};boot=${boot_source};userdata=$(findmnt -n -o SOURCE /userdata 2>/dev/null || true)"
    emit_result PASS 'Discovery completed.'
}

check_graphical() {
    local baseline=$1 expected_connector expected_mode outputs actual_mode probe_timeout
    batocera_environment
    expected_connector=$(sed -n 's/.*connector=\([^;]*\).*/\1/p' <<< "$baseline")
    expected_mode=$(sed -n 's/.*mode=\([^;]*\).*/\1/p' <<< "$baseline")
    [[ -n $expected_connector && -n $expected_mode ]] || return 1
    probe_timeout=$(bounded_probe_timeout 6) || return 1
    outputs=$(timeout "$probe_timeout" swaymsg -t get_outputs -r 2>/dev/null || true)
    sway_connector_is_active "$outputs" "$expected_connector" || return 1
    probe_timeout=$(bounded_probe_timeout 6) || return 1
    actual_mode=$(timeout "$probe_timeout" batocera-resolution currentMode 2>/dev/null || true)
    [[ $actual_mode == "$expected_mode" ]] || return 1
    probe_timeout=$(bounded_probe_timeout 6) || return 1
    timeout "$probe_timeout" pidof emulationstation >/dev/null 2>&1 || return 1
    [[ -e /tmp/emulationstation.ready ]] || return 1
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
        timeout "$probe_timeout" batocera-services status "$service_name" 2>/dev/null | grep -q running || return 1
    done
}

application_health_ready() {
    local mode=$1 baseline=$2 required_processes=$3 required_services=$4 audio_match=$5 audio_baseline=$6
    local current_audio probe_timeout
    APPLICATION_READINESS_LAST_FAILURE=''
    APPLICATION_READINESS_LAST_AUDIO=''
    check_required_processes "$required_processes" || { APPLICATION_READINESS_LAST_FAILURE=process; return 1; }
    check_required_services "$required_services" || { APPLICATION_READINESS_LAST_FAILURE=service; return 1; }
    if [[ -n $audio_match ]]; then
        batocera_environment
        probe_timeout=$(bounded_probe_timeout 6) || { APPLICATION_READINESS_LAST_FAILURE=audio-match; return 1; }
        if ! timeout "$probe_timeout" wpctl inspect @DEFAULT_AUDIO_SINK@ 2>/dev/null | grep -Fq -- "$audio_match"; then
            APPLICATION_READINESS_LAST_FAILURE=audio-match
            return 1
        fi
    fi
    if [[ $mode == graphical ]]; then
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
        check_graphical "$baseline" || { APPLICATION_READINESS_LAST_FAILURE=graphical; return 1; }
    fi
    return 0
}

wait_application_health() {
    local mode=$1 baseline=$2 required_processes=$3 required_services=$4 audio_match=$5 audio_baseline=$6
    local deadline=$((SECONDS + 180)) previous_deadline=${APPLICATION_READINESS_DEADLINE:-} remaining sleep_for result=1
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
        service) emit_result BOOT_FAILURE "A required service is not running in $context." "$temp" ;;
        audio-match) emit_result HARNESS_FAILURE "Default audio sink does not match the configured requirement in $context." "$temp" ;;
        audio-unavailable) emit_result HARNESS_FAILURE "The default audio sink is unavailable in $context." "$temp" ;;
        audio-changed) emit_result HARNESS_FAILURE "The default audio sink changed in $context: expected $audio_baseline, found ${APPLICATION_READINESS_LAST_AUDIO:-missing}." "$temp" ;;
        graphical) emit_result BOOT_FAILURE "Graphical baseline did not recover within 180 seconds in $context." "$temp" ;;
        *) emit_result BOOT_FAILURE "Application readiness did not recover within 180 seconds in $context." "$temp" ;;
    esac
}

cmd_health() {
    local expected_cpu=$1 expected_gpu=$2 gpu_key=$3 expected_voltage=$4 max_temp=$5 mode=$6 baseline=$7
    local required_processes=$8 required_services=$9 audio_match=${10} extra_ping=${11} health_hook=${12} expected_hash=${13} context=${14} throttle_baseline=${15:-throttled=0x0} audio_baseline=${16:-} fan_policy=${17:-normal}
    local boot_config=/boot/config.txt active_cpu active_gpu active_voltage throttle temp errors permanent_hash test_file
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
    mkdir -p "$PERSISTENT_ROOT"
    test_file="$PERSISTENT_ROOT/.write-test-$$"
    printf test > "$test_file" && sync "$test_file" && rm -f "$test_file" || { emit_result STABILITY_FAILURE "Persistent filesystem write test failed in $context." "$temp"; return 1; }
    if [[ -n $extra_ping ]]; then ping -c 2 -W 2 "$extra_ping" >/dev/null 2>&1 || { emit_result BOOT_FAILURE "Configured ping target is unreachable in $context." "$temp"; return 1; }; fi
    if [[ -n $audio_match ]]; then
        command -v wpctl >/dev/null 2>&1 || { emit_result HARNESS_FAILURE 'AUDIO_SINK_MATCH was configured but wpctl is unavailable.' "$temp"; return 1; }
    fi
    if [[ $mode == graphical ]]; then
        [[ -n $audio_baseline ]] || { emit_result HARNESS_FAILURE "No saved graphical audio baseline is available in $context." "$temp"; return 1; }
    fi
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
    vcgencmd measure_clock arm 2>/dev/null || true; vcgencmd measure_clock v3d 2>/dev/null || true; vcgencmd pmic_read_adc EXT5V_V 2>/dev/null || true
    emit_result PASS "Health passed in $context." "$temp"
}

cmd_plan_candidate() {
    local boot_config=$1 tryboot_config=$2 gpu_key=$3 cpu_mhz=$4 gpu_mhz=$5 voltage_uv=$6 expected_hash=$7 run_id=$8 ownership_token=$9
    local fan_policy=${10:-candidate-max}
    local current_hash temporary_file rendered_hash reservation_file reservation_hash quarantine_path
    tryboot_path_allowed "$boot_config" "$tryboot_config" || { emit_result RECOVERY_FAILURE 'The requested Batocera tryboot path is not /boot/tryboot.txt.'; return 1; }
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
    local current_hash temporary_file='' result_code=0 failure_class=HARNESS_FAILURE failure_reason=''
    local rendered_hash='' installed_hash='' installed_path_hash='' reservation_hash='' tryboot_exists tryboot_type tryboot_hash tryboot_fd=''
    tryboot_path_allowed "$boot_config" "$tryboot_config" || { emit_result RECOVERY_FAILURE 'The requested Batocera tryboot path is not /boot/tryboot.txt.'; return 1; }
    [[ $expected_tryboot_hash =~ ^[0-9a-f]{64}$ && $expected_reservation_hash =~ ^[0-9a-f]{64}$ && $ownership_token =~ ^[0-9a-f]{64}$ ]] || { emit_result HARNESS_FAILURE 'Candidate preparation lacks valid ownership evidence.'; return 1; }
    [[ $fan_policy == candidate-max || $fan_policy == normal ]] || { emit_result HARNESS_FAILURE 'Candidate preparation contains an invalid fan policy.'; return 1; }
    [[ $quarantine_path == "$(tryboot_quarantine_path "$tryboot_config" "$ownership_token")" && ! -e $quarantine_path && ! -L $quarantine_path ]] || { emit_result RECOVERY_FAILURE 'The tryboot quarantine path is invalid or occupied.'; return 1; }
    inspect_tryboot_path "$tryboot_config" tryboot_exists tryboot_type tryboot_hash
    [[ $tryboot_exists == 0 ]] || { emit_result RECOVERY_FAILURE "The tryboot path became occupied ($tryboot_type, hash $tryboot_hash); refusing to overwrite it."; return 1; }
    reset_recent_throttle >/dev/null || { emit_result HARNESS_FAILURE 'Could not clear and verify recent throttle history before candidate boot.'; return 1; }
    current_hash=$(sha256sum "$boot_config" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    [[ $current_hash == "$expected_hash" ]] || { emit_result RECOVERY_FAILURE 'Permanent config hash changed before candidate preparation.'; return 1; }
    apply_install_traps
    APO_APPLY_BOOT_RW=1
    if ! remount_boot_rw; then
        apply_remount_boot_ro >/dev/null 2>&1 || true
        (( APO_APPLY_BOOT_RW == 0 )) && apply_clear_traps
        emit_result HARNESS_FAILURE 'Could not remount and verify /boot read-write.'
        return 1
    fi
    current_hash=$(sha256sum "$boot_config" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    if [[ $current_hash != "$expected_hash" ]]; then
        result_code=1; failure_class=RECOVERY_FAILURE; failure_reason='Permanent config hash changed while /boot was remounted.'
    fi
    if (( result_code == 0 )); then
        inspect_tryboot_path "$tryboot_config" tryboot_exists tryboot_type tryboot_hash
        if [[ $tryboot_exists != 0 || -e $quarantine_path || -L $quarantine_path ]]; then
            result_code=1; failure_class=RECOVERY_FAILURE; failure_reason="The tryboot path became occupied after remount ($tryboot_type, hash $tryboot_hash); refusing to overwrite it."
        fi
    fi
    if (( result_code == 0 )); then
        temporary_file=$(mktemp /tmp/autopioverclock-tryboot.XXXXXX) || { result_code=1; failure_reason='Could not create tryboot temporary file.'; }
    fi
    if (( result_code == 0 )); then render_tryboot_config "$boot_config" "$temporary_file" "$cpu_mhz" "$gpu_mhz" "$gpu_key" "$voltage_uv" "$run_id" "$ownership_token" "$fan_policy" || { result_code=1; failure_reason='Could not render tryboot config.'; }; fi
    if (( result_code == 0 )); then
        rendered_hash=$(sha256sum "$temporary_file" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
        if [[ $rendered_hash != "$expected_tryboot_hash" ]]; then result_code=1; failure_class=RECOVERY_FAILURE; failure_reason='Rendered tryboot config does not match the persisted ownership plan.'; fi
    fi
    if (( result_code == 0 )); then sync "$temporary_file" || { result_code=1; failure_reason='Could not durably stage rendered tryboot config.'; }; fi
    if (( result_code == 0 )); then
        set -o noclobber
        if ! exec {tryboot_fd}> "$tryboot_config" 2>/dev/null; then
            inspect_tryboot_path "$tryboot_config" tryboot_exists tryboot_type tryboot_hash
            result_code=1; failure_class=RECOVERY_FAILURE; failure_reason="The tryboot path became occupied ($tryboot_type, hash $tryboot_hash); refusing to overwrite it."
        fi
        set +o noclobber
    fi
    if (( result_code == 0 )); then
        if ! render_tryboot_reservation "$run_id" "$ownership_token" >&"$tryboot_fd" || ! sync "/proc/self/fd/$tryboot_fd"; then
            result_code=1; failure_class=RECOVERY_FAILURE; failure_reason='Could not durably write the owned tryboot header.'
        fi
    fi
    if (( result_code == 0 )); then
        reservation_hash=$(sha256sum "/proc/self/fd/$tryboot_fd" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
        if [[ $reservation_hash != "$expected_reservation_hash" || ! $tryboot_config -ef /proc/self/fd/$tryboot_fd ]]; then
            result_code=1; failure_class=RECOVERY_FAILURE; failure_reason='The owned tryboot header was replaced before candidate installation.'
        fi
    fi
    if (( result_code == 0 )); then
        if ! tail -n +4 "$temporary_file" >&"$tryboot_fd" \
            || { ! chmod --reference="$boot_config" "/proc/self/fd/$tryboot_fd" 2>/dev/null && ! chmod 644 "/proc/self/fd/$tryboot_fd"; } \
            || ! sync "/proc/self/fd/$tryboot_fd"; then
            result_code=1; failure_class=RECOVERY_FAILURE; failure_reason='Could not durably complete the owned tryboot config.'
        fi
    fi
    if (( result_code == 0 )); then
        installed_hash=$(sha256sum "/proc/self/fd/$tryboot_fd" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
        installed_path_hash=$(sha256sum "$tryboot_config" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
        if [[ $installed_hash != "$expected_tryboot_hash" || $installed_path_hash != "$expected_tryboot_hash" || ! $tryboot_config -ef /proc/self/fd/$tryboot_fd ]]; then
            result_code=1; failure_class=RECOVERY_FAILURE; failure_reason='Installed tryboot config failed final path/ownership verification.'
        fi
    fi
    if (( result_code == 0 )); then
        current_hash=$(sha256sum "$boot_config" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
        if [[ $current_hash != "$expected_hash" ]]; then result_code=1; failure_class=RECOVERY_FAILURE; failure_reason='Permanent config hash changed during candidate preparation.'; fi
    fi
    if [[ -n $tryboot_fd ]]; then exec {tryboot_fd}>&-; fi
    if [[ -n $temporary_file ]]; then rm -f -- "$temporary_file" 2>/dev/null || true; fi
    if ! apply_remount_boot_ro; then
        emit_result RECOVERY_FAILURE "${failure_reason:+$failure_reason }Batocera /boot could not be restored and verified read-only; the exit trap will retry."
        return 1
    fi
    apply_clear_traps
    if (( result_code != 0 )); then emit_result "$failure_class" "$failure_reason"; return 1; fi
    emit_data TRYBOOT_HASH "$installed_hash"
    emit_result PASS 'Candidate tryboot config prepared and /boot restored read-only.'
}

cmd_clear_tryboot() {
    local boot_config=$1 tryboot_config=$2 quarantine_path=$3 expected_permanent_hash=$4 expected_tryboot_hash=$5 expected_reservation_hash=$6 run_id=$7 ownership_token=$8
    local permanent_hash tryboot_hash quarantine_hash result_code=0 failure_reason='' ownership_kind='' moved_kind=''
    local tryboot_exists tryboot_type quarantine_exists quarantine_type source_path
    tryboot_path_allowed "$boot_config" "$tryboot_config" || { emit_result RECOVERY_FAILURE 'The requested Batocera tryboot cleanup path is not /boot/tryboot.txt.'; return 1; }
    [[ $expected_tryboot_hash =~ ^[0-9a-f]{64}$ && $expected_reservation_hash =~ ^[0-9a-f]{64}$ && $ownership_token =~ ^[0-9a-f]{64}$ ]] || { emit_result RECOVERY_FAILURE 'Tryboot cleanup lacks valid persisted ownership evidence.'; return 1; }
    [[ $quarantine_path == "$(tryboot_quarantine_path "$tryboot_config" "$ownership_token")" ]] || { emit_result RECOVERY_FAILURE 'Saved tryboot quarantine path is invalid.'; return 1; }
    permanent_hash=$(sha256sum "$boot_config" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    [[ $permanent_hash == "$expected_permanent_hash" ]] || { emit_result RECOVERY_FAILURE 'Permanent config hash changed before tryboot cleanup.'; return 1; }
    inspect_tryboot_path "$tryboot_config" tryboot_exists tryboot_type tryboot_hash
    inspect_tryboot_path "$quarantine_path" quarantine_exists quarantine_type quarantine_hash
    if [[ $tryboot_exists == 0 && $quarantine_exists == 0 ]]; then
        if ! boot_mount_has_option ro; then
            apply_install_traps
            APO_APPLY_BOOT_RW=1
            if ! apply_remount_boot_ro; then
                emit_result RECOVERY_FAILURE 'Managed tryboot evidence is absent, but /boot could not be restored and verified read-only.'
                return 1
            fi
            apply_clear_traps
        fi
        emit_data TRYBOOT_CLEARED already-absent
        emit_result PASS 'Managed tryboot config and quarantine are absent and /boot is verified read-only.'
        return 0
    fi
    [[ ! ( $tryboot_exists == 1 && $quarantine_exists == 1 ) ]] || { emit_result RECOVERY_FAILURE 'Both tryboot and its token quarantine exist; refusing ambiguous cleanup.'; return 1; }
    if [[ $tryboot_exists == 1 ]]; then
        source_path=$tryboot_config
        ownership_kind=$(owned_tryboot_kind "$tryboot_config" "$expected_tryboot_hash" "$expected_reservation_hash" "$run_id" "$ownership_token" || true)
    else
        source_path=$quarantine_path
        ownership_kind=$(owned_tryboot_kind "$quarantine_path" "$expected_tryboot_hash" "$expected_reservation_hash" "$run_id" "$ownership_token" || true)
    fi
    [[ -n $ownership_kind ]] || { emit_result RECOVERY_FAILURE "The tryboot cleanup source is unowned or changed (${tryboot_type:-$quarantine_type}, hash ${tryboot_hash:-$quarantine_hash}); preserving it."; return 1; }

    apply_install_traps
    APO_APPLY_BOOT_RW=1
    if ! remount_boot_rw; then
        apply_remount_boot_ro >/dev/null 2>&1 || true
        (( APO_APPLY_BOOT_RW == 0 )) && apply_clear_traps
        emit_result RECOVERY_FAILURE 'Could not remount and verify /boot read-write for tryboot cleanup.'
        return 1
    fi
    moved_kind=$(owned_tryboot_kind "$source_path" "$expected_tryboot_hash" "$expected_reservation_hash" "$run_id" "$ownership_token" || true)
    if [[ $moved_kind != "$ownership_kind" ]]; then
        result_code=1; failure_reason='Tryboot content changed while /boot was remounted; refusing cleanup.'
    elif [[ $source_path == "$tryboot_config" ]]; then
        if [[ -e $quarantine_path || -L $quarantine_path ]]; then
            result_code=1; failure_reason='Tryboot quarantine became occupied; refusing cleanup.'
        elif ! mv -n -- "$tryboot_config" "$quarantine_path"; then
            result_code=1; failure_reason='Could not quarantine the owned tryboot file for post-rename verification.'
        elif [[ -e $tryboot_config || -L $tryboot_config ]]; then
            result_code=1; failure_reason='No-clobber quarantine move did not remove the owned tryboot path; preserving both paths.'
        elif ! sync; then
            result_code=1; failure_reason='Could not sync the owned tryboot quarantine rename.'
        fi
    fi
    if (( result_code == 0 )); then
        moved_kind=$(owned_tryboot_kind "$quarantine_path" "$expected_tryboot_hash" "$expected_reservation_hash" "$run_id" "$ownership_token" || true)
        if [[ $moved_kind != "$ownership_kind" ]]; then
            result_code=1; failure_reason="Tryboot quarantine failed post-rename ownership verification; preserving $quarantine_path."
        elif ! rm -f -- "$quarantine_path"; then
            result_code=1; failure_reason='Could not remove the verified tryboot quarantine after normal recovery.'
        elif ! sync; then
            result_code=1; failure_reason='Could not sync removal of the verified tryboot quarantine.'
        fi
    fi
    if ! apply_remount_boot_ro; then
        emit_result RECOVERY_FAILURE 'Tryboot cleanup could not verify that /boot returned read-only; the exit cleanup will retry.'
        return 1
    fi
    apply_clear_traps
    if (( result_code != 0 )); then emit_result RECOVERY_FAILURE "$failure_reason"; return 1; fi
    [[ ! -e $tryboot_config && ! -L $tryboot_config && ! -e $quarantine_path && ! -L $quarantine_path ]] || { emit_result RECOVERY_FAILURE 'A tryboot or quarantine path exists after cleanup; preserving it and stopping.'; return 1; }
    permanent_hash=$(sha256sum "$boot_config" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    [[ $permanent_hash == "$expected_permanent_hash" ]] || { emit_result RECOVERY_FAILURE 'Permanent config hash changed during tryboot cleanup.'; return 1; }
    emit_data TRYBOOT_CLEARED "$ownership_kind-removed"
    emit_result PASS "Managed $ownership_kind tryboot file removed and /boot restored read-only after verified normal recovery."
}

cmd_verify_tryboot() {
    local boot_config=$1 tryboot_config=$2 expected_permanent_hash=$3 expected_tryboot_hash=$4 run_id=$5 ownership_token=$6 permanent_hash ownership_kind
    tryboot_path_allowed "$boot_config" "$tryboot_config" || { emit_result RECOVERY_FAILURE 'Tryboot verification path is invalid.'; return 1; }
    permanent_hash=$(sha256sum "$boot_config" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    [[ $permanent_hash == "$expected_permanent_hash" ]] || { emit_result RECOVERY_FAILURE 'Permanent config hash changed before tryboot trigger.'; return 1; }
    ownership_kind=$(owned_tryboot_kind "$tryboot_config" "$expected_tryboot_hash" impossible "$run_id" "$ownership_token" || true)
    [[ $ownership_kind == candidate ]] || { emit_result RECOVERY_FAILURE 'The planned candidate is absent, incomplete, changed, or unowned; tryboot trigger is refused.'; return 1; }
    boot_mount_has_option ro || { emit_result RECOVERY_FAILURE 'Batocera /boot is not verified read-only before tryboot trigger.'; return 1; }
    emit_result PASS 'Owned tryboot candidate and read-only boot mount verified immediately before trigger.'
}

cmd_trigger_tryboot() {
    cmd_verify_tryboot "$@" >/dev/null || return 1
    /usr/bin/python3 -c 'import ctypes,os; os.sync(); libc=ctypes.CDLL(None,use_errno=True); rc=libc.syscall(142,0xfee1dead,0x28121969,0xa1b2c3d4,ctypes.c_char_p(b"0 tryboot")); raise SystemExit(0 if rc == 0 else ctypes.get_errno())' >/dev/null 2>&1
}

verified_normal_reboot_now() {
    # A successful reboot syscall never returns.  Any return is a failure, even
    # if a platform reports rc=0 unexpectedly.
    /usr/bin/python3 -c 'import ctypes,os; os.sync(); libc=ctypes.CDLL(None,use_errno=True); rc=libc.syscall(142,0xfee1dead,0x28121969,0x01234567,ctypes.c_void_p()); raise SystemExit(ctypes.get_errno() if rc != 0 else 1)' >/dev/null 2>&1
}

cmd_reboot_normal() {
    local expected_hash=${1:-} current_hash
    if [[ -n $expected_hash ]]; then
        valid_sha256 "$expected_hash" || { emit_result RECOVERY_FAILURE 'Verified normal reboot received a malformed permanent-config hash.'; return 1; }
        apply_tryboot_clear /boot/config.txt || { emit_result RECOVERY_FAILURE 'Verified normal reboot requires no live, staged, or quarantined tryboot evidence.'; return 1; }
        boot_mount_has_option ro || { emit_result RECOVERY_FAILURE 'Verified normal reboot requires Batocera /boot to be read-only.'; return 1; }
        current_hash=$(sha256sum /boot/config.txt 2>/dev/null | awk 'NR == 1 {print $1}' || true)
        [[ $current_hash == "$expected_hash" ]] || { emit_result RECOVERY_FAILURE 'Permanent config changed at the verified normal-reboot mutation boundary.'; return 1; }
        vcgencmd get_throttled 0x0f >/dev/null 2>&1 || true
        sync || return 1
        # Keep the target mutation lock present until /run is recreated by the
        # new boot.  If the syscall fails and returns, run_with_mutation_lock
        # still releases the lock explicitly on the ordinary return path.
        trap - EXIT INT TERM HUP
        verified_normal_reboot_now
        emit_result RECOVERY_FAILURE 'The verified normal-reboot syscall returned without restarting the target.'
        return 1
    fi
    vcgencmd get_throttled 0x0f >/dev/null 2>&1 || true
    sync || return 1
    reboot >/dev/null 2>&1
}

cmd_reset_throttle_history() {
    local before_reset after_reset
    before_reset=$(recent_throttle)
    reset_recent_throttle >/dev/null || { emit_result HARNESS_FAILURE 'Recent throttle history reset is unsupported or did not clear.'; return 1; }
    after_reset=$(recent_throttle)
    emit_data THROTTLE_BEFORE_RESET "$before_reset"
    emit_data THROTTLE_AFTER_RESET "$after_reset"
    emit_result PASS 'Recent throttle history was cleared and verified.'
}

wayland_socket_ready() {
    local socket_path=$1
    [[ -S $socket_path && ! -L $socket_path ]]
}

safe_wayland_runtime_dir() {
    local runtime_dir=$1 run_root=${2:-/run} canonical_runtime canonical_root
    [[ -n $runtime_dir && $runtime_dir == /* && $runtime_dir != *$'\t'* && $runtime_dir != *$'\n'* && $runtime_dir != *$'\r'* ]] || return 1
    canonical_root=$(readlink -f -- "$run_root" 2>/dev/null || true)
    canonical_runtime=$(readlink -f -- "$runtime_dir" 2>/dev/null || true)
    [[ -n $canonical_root && -n $canonical_runtime ]] || return 1
    [[ $canonical_runtime == "$canonical_root" || $canonical_runtime == "$canonical_root/"* ]] || return 1
    printf '%s' "$canonical_runtime"
}

wayland_display_name_safe() {
    [[ $1 =~ ^wayland-[0-9]+$ ]]
}

wayland_session_from_frontend_pid() {
    local process_pid=$1 proc_root=${2:-/proc} run_root=${3:-/run}
    local environment_file="$proc_root/$process_pid/environ" environment_entry runtime_dir='' display_name='' canonical_runtime
    [[ $process_pid =~ ^[0-9]+$ && -r $environment_file ]] || return 1
    while IFS= read -r -d '' environment_entry; do
        case $environment_entry in
            XDG_RUNTIME_DIR=*) runtime_dir=${environment_entry#XDG_RUNTIME_DIR=} ;;
            WAYLAND_DISPLAY=*) display_name=${environment_entry#WAYLAND_DISPLAY=} ;;
        esac
    done < "$environment_file"
    [[ -n $runtime_dir ]] || runtime_dir=$run_root
    wayland_display_name_safe "$display_name" || return 1
    canonical_runtime=$(safe_wayland_runtime_dir "$runtime_dir" "$run_root") || return 1
    wayland_socket_ready "$canonical_runtime/$display_name" || return 1
    printf '%s\t%s\n' "$canonical_runtime" "$display_name"
}

discover_wayland_session() {
    local proc_root=${1:-/proc} run_root=${2:-/run} process_pid socket_path display_name pid_output
    local frontend_found=0 canonical_root
    local -a fallback_sockets=() frontend_pids=()
    pid_output=$(pidof emulationstation 2>/dev/null || true)
    read -r -a frontend_pids <<< "$pid_output"
    for process_pid in "${frontend_pids[@]}"; do
        [[ $process_pid =~ ^[0-9]+$ ]] || continue
        [[ -d $proc_root/$process_pid ]] || continue
        frontend_found=1
        wayland_session_from_frontend_pid "$process_pid" "$proc_root" "$run_root" && return 0
    done
    (( frontend_found == 1 )) || return 1
    canonical_root=$(readlink -f -- "$run_root" 2>/dev/null || true)
    [[ -n $canonical_root ]] || return 1
    for socket_path in "$canonical_root"/wayland-*; do
        [[ -e $socket_path || -L $socket_path ]] || continue
        display_name=${socket_path##*/}
        wayland_display_name_safe "$display_name" || continue
        wayland_socket_ready "$socket_path" || continue
        fallback_sockets+=("$socket_path")
    done
    (( ${#fallback_sockets[@]} == 1 )) || return 1
    printf '%s\t%s\n' "$canonical_root" "${fallback_sockets[0]##*/}"
}

write_glmark_launcher() {
    local launcher_file=$1 duration=$2 glmark_binary=$3 glmark_data=$4 library_dirs=$5 mode=$6
    local wayland_runtime_dir=${7:-} wayland_display=${8:-}
    local strategy
    local -a canvas_args=(--off-screen)
    case $mode in
        graphical)
            [[ -n $wayland_runtime_dir ]] || return 1
            wayland_display_name_safe "$wayland_display" || return 1
            strategy=graphical-wayland-off-screen
            canvas_args+=(--size=1280x720)
            ;;
        headless)
            strategy=headless-drm-off-screen
            canvas_args+=(--size=640x480)
            ;;
        *) return 1 ;;
    esac
    {
        printf '#!/usr/bin/env bash\nset -u\n'
        printf 'export HOME=/userdata/system\n'
        if [[ $mode == graphical ]]; then
            printf 'export XDG_RUNTIME_DIR=%q\n' "$wayland_runtime_dir"
            printf 'export WAYLAND_DISPLAY=%q\n' "$wayland_display"
            printf 'printf "%%s\\n" %q\n' "GPU_WAYLAND_SOCKET=${wayland_runtime_dir}/${wayland_display}"
        else
            printf 'unset WAYLAND_DISPLAY\n'
        fi
        printf 'export LD_LIBRARY_PATH=%q${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}\n' "$library_dirs"
        printf 'printf "%%s\\n" %q\n' "GPU_STRATEGY=${strategy}"
        printf 'exec %q --data-path %q' "$glmark_binary" "$glmark_data"
        printf ' %q' "${canvas_args[@]}"
        printf ' --benchmark %q\n' "shading:duration=${duration}:shading=phong"
    } > "$launcher_file" || return 1
    chmod 700 "$launcher_file" || return 1
}

launch_gpu_test() {
    local launcher_file=$1 output_file=$2 mode=$3
    case $mode in
        graphical) printf 'GPU_LAUNCH=wayland-compositor\n' > "$output_file" ;;
        headless) printf 'GPU_LAUNCH=headless-drm\n' > "$output_file" ;;
        *) return 1 ;;
    esac
    /bin/bash "$launcher_file" >>"$output_file" 2>&1 &
    stress_gpu_pid=$!
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

terminate_gpu_child() {
    terminate_child "$1"
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
    if [[ -n ${stress_gpu_pid:-} ]]; then terminate_gpu_child "$stress_gpu_pid"; stress_gpu_pid=''; fi
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
    local stress_kind=$1 duration=$2 max_temp=$3 mode=$4 baseline=$5 io_check=${6:-0} expected_cpu=${7:-0} expected_gpu=${8:-0} throttle_baseline=${9:-throttled=0x0} telemetry_interval=${10:-5} audio_baseline=${11:-} fan_policy=${12:-normal}
    local cpu_output gpu_output launcher_file
    local start_seconds expected_end hard_deadline completion_tolerance now_seconds next_log max_seen=0 temp throttle kernel_lines new_errors
    local cpu_rc=0 gpu_rc=0 io_rc=0 failure_class='' failure_reason='' glmark_binary glmark_data library_dirs gpu_stack
    local arm_sample=0 gpu_sample=0 cpu_clock_seen=0 gpu_clock_seen=0 clock_tolerance=25
    local cpu_alive=0 gpu_alive=0 cpu_dead=0 gpu_dead=0 workloads_complete=0 telemetry_due=0 fan_status=normal-policy elapsed_sample=0
    local wayland_runtime_dir='' wayland_display=''
    : "$baseline" "$audio_baseline"
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
    stress_cpu_pid=''; stress_gpu_pid=''; stress_io_pid=''; stress_work_dir=''; stress_io_file=''
    stress_work_dir=$(mktemp -d /tmp/autopioverclock-stress.XXXXXX) || { emit_result HARNESS_FAILURE 'Could not create stress workspace.'; return 1; }
    cpu_output="$stress_work_dir/cpu.log"; gpu_output="$stress_work_dir/gpu.log"; launcher_file="$stress_work_dir/glmark.sh"; stress_io_file="$PERSISTENT_ROOT/.io-test-$$"
    trap cleanup_stress EXIT
    trap 'stress_signal_cleanup 130' INT
    trap 'stress_signal_cleanup 143' TERM
    trap 'stress_signal_cleanup 129' HUP
    command -v openssl >/dev/null 2>&1 || { emit_result HARNESS_FAILURE 'openssl is unavailable for Batocera CPU stress.'; return 1; }
    if [[ $stress_kind == gpu || $stress_kind == combined ]]; then
        glmark_binary=$(find_glmark_binary "$mode" || true); glmark_data=$(find_glmark_data || true); library_dirs=$(find_glmark_library_dirs)
        [[ -n $glmark_binary && -n $glmark_data ]] || { emit_result HARNESS_FAILURE 'Portable glmark2 binary or data directory is missing.'; return 1; }
        gpu_stack=$(gpu_stack_probe || true)
        [[ -n $gpu_stack ]] || { emit_result HARNESS_FAILURE 'No DRM render node bound to the V3D driver was found.'; return 1; }
        printf 'GPU_STACK=%s\n' "$gpu_stack"
        if [[ $mode == graphical ]]; then
            IFS=$'\t' read -r wayland_runtime_dir wayland_display < <(discover_wayland_session) || true
            [[ -n $wayland_runtime_dir && -n $wayland_display ]] || { emit_result HARNESS_FAILURE 'The live EmulationStation Wayland socket could not be discovered safely.'; return 1; }
            printf 'GPU_WAYLAND_SESSION=runtime:%s;display:%s\n' "$wayland_runtime_dir" "$wayland_display"
        elif [[ $mode != headless ]]; then
            emit_result HARNESS_FAILURE "Unsupported Batocera stress mode: $mode."
            return 1
        fi
        write_glmark_launcher "$launcher_file" "$duration" "$glmark_binary" "$glmark_data" "$library_dirs" "$mode" "$wayland_runtime_dir" "$wayland_display" \
            || { emit_result HARNESS_FAILURE 'Could not create the mode-specific glmark2 launcher.'; return 1; }
    fi

    kernel_lines=$(kernel_log | wc -l)
    start_seconds=$SECONDS; expected_end=$((start_seconds + duration)); hard_deadline=$((expected_end + 60)); next_log=$start_seconds
    completion_tolerance=$(stress_completion_tolerance "$duration")
    # OpenSSL applies -seconds to every default buffer size, and each multi
    # worker records its operation count in a signed 32-bit counter.  Use one
    # 1 MiB block: this keeps the requested duration as the total wall time and
    # lowers the operation rate 64-fold versus 16 KiB, preventing the counter
    # from ending a 24-hour CPU/combined run early on a fast Pi 5.
    if [[ $stress_kind == cpu || $stress_kind == combined ]]; then openssl speed -elapsed -seconds "$duration" -bytes "$OPENSSL_CPU_BLOCK_BYTES" -multi "$(nproc)" sha256 >"$cpu_output" 2>&1 & stress_cpu_pid=$!; fi
    if [[ $stress_kind == gpu || $stress_kind == combined ]]; then launch_gpu_test "$launcher_file" "$gpu_output" "$mode"; fi
    if [[ $io_check == 1 ]]; then mkdir -p "$PERSISTENT_ROOT"; start_io_activity "$stress_io_file"; fi

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
            failure_reason="Persistent filesystem activity failed during load with rc=$io_rc."
            break
        fi
        # Reap every worker found dead in the same supervision poll before
        # assigning one failing domain. Otherwise the CPU-first check can hide
        # a simultaneous GPU failure and make ambiguous combined evidence look
        # CPU-specific. The workload and Bash supervisor use independent
        # whole-second clocks.
        # Permit a clean child to finish within 0.1% of the requested duration
        # (bounded to 3-30 seconds); nonzero exits still fail after wait.
        if (( now_seconds < expected_end - completion_tolerance )); then
            cpu_dead=0; gpu_dead=0
            [[ -n $stress_cpu_pid && $cpu_alive -eq 0 ]] && cpu_dead=1
            [[ -n $stress_gpu_pid && $gpu_alive -eq 0 ]] && gpu_dead=1
            if (( cpu_dead == 1 || gpu_dead == 1 )); then
                if (( cpu_dead == 1 )); then
                    if wait "$stress_cpu_pid"; then cpu_rc=0; else cpu_rc=$?; fi
                    stress_cpu_pid=''
                fi
                if (( gpu_dead == 1 )); then
                    if wait "$stress_gpu_pid"; then gpu_rc=0; else gpu_rc=$?; fi
                    stress_gpu_pid=''
                fi
                if (( cpu_dead == 1 && gpu_dead == 1 )); then
                    if (( cpu_rc == 0 && gpu_rc == 0 )); then
                        failure_class=HARNESS_FAILURE
                        failure_reason='CPU and GPU stress exited early with rc=0/0.'
                    elif (( cpu_rc != 0 && gpu_rc == 0 )); then
                        failure_class=STABILITY_FAILURE
                        failure_reason="CPU stress exited early with rc=$cpu_rc."
                    elif (( cpu_rc == 0 && gpu_rc != 0 )); then
                        failure_class=$(gpu_early_exit_class "$gpu_rc" "$gpu_output")
                        failure_reason="GPU stress exited early with rc=$gpu_rc."
                    else
                        failure_class=STABILITY_FAILURE
                        failure_reason="CPU and GPU stress exited early with rc=$cpu_rc/$gpu_rc."
                    fi
                elif (( cpu_dead == 1 )); then
                    failure_class=$([[ $cpu_rc -eq 0 ]] && printf HARNESS_FAILURE || printf STABILITY_FAILURE)
                    failure_reason="CPU stress exited early with rc=$cpu_rc."
                else
                    failure_class=$(gpu_early_exit_class "$gpu_rc" "$gpu_output")
                    failure_reason="GPU stress exited early with rc=$gpu_rc."
                fi
                break
            fi
        fi
        if (( cpu_alive == 0 && gpu_alive == 0 )); then workloads_complete=1; fi

        # Sample at the configured cadence, plus one forced final sample after
        # both workloads have exited and before their result can be accepted.
        if (( now_seconds >= next_log || workloads_complete == 1 )); then telemetry_due=1; fi
        if (( telemetry_due == 1 )); then
            temp=$(current_temp)
            if [[ -n $temp ]]; then awk -v t="$temp" -v m="$max_seen" 'BEGIN{exit !(t>m)}' && max_seen=$temp || true; if ! awk -v t="$temp" -v m="$max_temp" 'BEGIN{exit !(t<m)}'; then failure_class=STABILITY_FAILURE; failure_reason="Temperature ${temp}C reached the ${max_temp}C ceiling."; fi; else failure_class=HARNESS_FAILURE; failure_reason='Temperature telemetry became unavailable.'; fi
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
        if [[ -n $stress_gpu_pid ]] && kill -0 "$stress_gpu_pid" 2>/dev/null; then
            terminate_gpu_child "$stress_gpu_pid"
            gpu_rc=124
            stress_gpu_pid=''
        fi
    fi
    if [[ -n $stress_cpu_pid ]]; then wait "$stress_cpu_pid" 2>/dev/null; cpu_rc=$?; stress_cpu_pid=''; fi
    if [[ -n $stress_gpu_pid ]]; then wait "$stress_gpu_pid" 2>/dev/null; gpu_rc=$?; stress_gpu_pid=''; fi
    if [[ -n $stress_io_pid ]]; then terminate_child "$stress_io_pid"; stress_io_pid=''; fi
    [[ -f $cpu_output ]] && { printf '%s\n' '--- CPU stress output ---'; cat "$cpu_output"; }
    [[ -f $gpu_output ]] && { printf '%s\n' '--- GPU stress output ---'; cat "$gpu_output"; }
    printf 'CPU_RC=%s GPU_RC=%s IO_RC=%s\n' "$cpu_rc" "$gpu_rc" "$io_rc"
    printf '%s\n' "$(current_throttle)"
    vcgencmd measure_clock arm 2>/dev/null || true; vcgencmd measure_clock v3d 2>/dev/null || true; vcgencmd pmic_read_adc EXT5V_V 2>/dev/null || true
    if [[ -z $failure_class && $cpu_rc -ne 0 && $gpu_rc -ne 0 ]]; then
        failure_class=STABILITY_FAILURE
        failure_reason="Stress processes returned nonzero (CPU=$cpu_rc GPU=$gpu_rc)."
    elif [[ -z $failure_class && $gpu_rc -ne 0 ]]; then
        if ! gpu_output_has_v3d_renderer "$gpu_output" || gpu_output_has_harness_error "$gpu_output"; then failure_class=HARNESS_FAILURE; failure_reason='glmark2 did not initialize a hardware V3D renderer or its portable runtime.'; else failure_class=STABILITY_FAILURE; failure_reason="GPU stress returned rc=$gpu_rc after V3D initialization."; fi
    elif [[ -z $failure_class && $cpu_rc -ne 0 ]]; then
        failure_class=STABILITY_FAILURE
        failure_reason="CPU stress returned rc=$cpu_rc."
    fi
    if [[ -z $failure_class && ( $stress_kind == cpu || $stress_kind == combined ) && $cpu_clock_seen -ne 1 ]]; then failure_class=STABILITY_FAILURE; failure_reason="Requested CPU clock ${expected_cpu}MHz was never observed within ${clock_tolerance}MHz under load."; fi
    if [[ -z $failure_class && ( $stress_kind == gpu || $stress_kind == combined ) && $gpu_clock_seen -ne 1 ]]; then failure_class=STABILITY_FAILURE; failure_reason="Requested GPU clock ${expected_gpu}MHz was never observed within ${clock_tolerance}MHz under load."; fi
    if [[ -z $failure_class && ( $stress_kind == gpu || $stress_kind == combined ) ]]; then
        if ! gpu_output_has_v3d_renderer "$gpu_output"; then failure_class=HARNESS_FAILURE; failure_reason='glmark2 did not prove a hardware V3D renderer.';
        elif ! gpu_output_has_positive_score "$gpu_output"; then failure_class=HARNESS_FAILURE; failure_reason='glmark2 did not produce a positive numeric score.'; fi
    fi

    if [[ -n $failure_class ]]; then emit_result "$failure_class" "$failure_reason" "$max_seen"; return 1; fi
    emit_result PASS "$stress_kind stress completed successfully." "$max_seen"
    cleanup_stress; trap - EXIT INT TERM HUP
}

cmd_render_permanent() {
    local cpu_mhz=$1 gpu_mhz=$2 gpu_key=$3 voltage_uv=$4 run_id=$5 voltage_render_mode=${6:-explicit}
    render_clock_config /boot/config.txt /dev/stdout "$cpu_mhz" "$gpu_mhz" "$gpu_key" "$voltage_uv" "$run_id" "$voltage_render_mode"
}

RESET_STOCK_LAST_REASON=''
RESET_STOCK_TRYBOOT_PATH=''
RESET_STOCK_TRYBOOT_HASH=''
RESET_STOCK_TRYBOOT_KIND=''
RESET_STOCK_TRYBOOT_RUN=''
RESET_STOCK_TRYBOOT_TOKEN=''
RESET_STOCK_BACKUP_DIR=/userdata/system/autopioverclock/backups

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
    local source_file=$1 destination_file=$2
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
    ' "$source_file" > "$destination_file"
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
    local expected_old_hash=$1 reset_id=$2 boot_config=/boot/config.txt old_hash new_hash disabled_keys reset_timestamp backup_dir backup_file tryboot_backup=''
    local rendered_file installed_hash tryboot_flag current_hash planned_tryboot_path planned_tryboot_hash planned_tryboot_kind planned_tryboot_run planned_tryboot_token
    local result_code=0 install_attempted=0 failure_reason=''
    valid_sha256 "$expected_old_hash" || { emit_result APPLY_FAILURE 'Stock reset received a malformed expected permanent-config hash.'; return 1; }
    reset_stock_safe_id "$reset_id" || { emit_result APPLY_FAILURE 'Stock reset received an unsafe reset/run ID.'; return 1; }
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
    planned_tryboot_path=$RESET_STOCK_TRYBOOT_PATH
    planned_tryboot_hash=$RESET_STOCK_TRYBOOT_HASH
    planned_tryboot_kind=$RESET_STOCK_TRYBOOT_KIND
    planned_tryboot_run=$RESET_STOCK_TRYBOOT_RUN
    planned_tryboot_token=$RESET_STOCK_TRYBOOT_TOKEN
    backup_dir=$(reset_stock_prepare_backup_dir "${RESET_STOCK_BACKUP_DIR%/backups}") || { rm -f -- "$rendered_file"; emit_result APPLY_FAILURE "$RESET_STOCK_LAST_REASON"; return 1; }
    reset_timestamp=$(date -u '+%Y%m%dT%H%M%SZ') || { rm -f -- "$rendered_file"; emit_result APPLY_FAILURE 'Could not timestamp the stock-reset backup.'; return 1; }
    backup_file="$backup_dir/config-${reset_timestamp}-reset-${reset_id}.txt"
    reset_stock_backup_verified "$boot_config" "$backup_file" "$old_hash" || { rm -f -- "$rendered_file"; emit_result APPLY_FAILURE 'Could not create a verified no-clobber permanent-config reset backup.'; return 1; }
    if [[ -n $planned_tryboot_path ]]; then
        tryboot_backup="$backup_dir/tryboot-${reset_timestamp}-reset-${reset_id}-${planned_tryboot_token}.txt"
        reset_stock_backup_verified "$planned_tryboot_path" "$tryboot_backup" "$planned_tryboot_hash" || { rm -f -- "$rendered_file"; emit_result APPLY_FAILURE 'Could not create a verified no-clobber managed-tryboot reset backup.'; return 1; }
    fi

    apply_install_traps
    APO_APPLY_BOOT_RW=1
    if ! remount_boot_rw; then
        apply_remount_boot_ro >/dev/null 2>&1 || true
        (( APO_APPLY_BOOT_RW == 0 )) && apply_clear_traps
        rm -f -- "$rendered_file"
        emit_result APPLY_FAILURE 'Could not remount and verify /boot read-write for stock reset.'
        return 1
    fi
    current_hash=$(sha256sum "$boot_config" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    if [[ $current_hash != "$old_hash" ]] || ! reset_stock_validate_config "$boot_config"; then
        result_code=1; failure_reason='Permanent config changed at the stock-reset mutation boundary.'
    elif ! reset_stock_scan_tryboot "$boot_config"; then
        result_code=1; failure_reason=$RESET_STOCK_LAST_REASON
    elif [[ $RESET_STOCK_TRYBOOT_PATH != "$planned_tryboot_path" || $RESET_STOCK_TRYBOOT_HASH != "$planned_tryboot_hash" ||
            $RESET_STOCK_TRYBOOT_KIND != "$planned_tryboot_kind" || $RESET_STOCK_TRYBOOT_RUN != "$planned_tryboot_run" ||
            $RESET_STOCK_TRYBOOT_TOKEN != "$planned_tryboot_token" ]]; then
        result_code=1; failure_reason='Tryboot ownership evidence changed while /boot was remounted; refusing reset.'
    elif ! reset_stock_remove_tryboot "$boot_config" "$reset_id"; then
        result_code=1; failure_reason=$RESET_STOCK_LAST_REASON
    elif ! reset_stock_paths_clear "$boot_config"; then
        result_code=1; failure_reason='Tryboot evidence remained after verified stock-reset cleanup.'
    else
        if [[ $new_hash != "$old_hash" ]]; then
            install_attempted=1
            if ! reset_stock_replace_verified "$rendered_file" "$boot_config" "$new_hash" "$old_hash" "$reset_id"; then
                result_code=1; failure_reason='Atomic stock-config replacement failed.'
            fi
        fi
        if (( result_code == 0 )); then
            installed_hash=$(sha256sum "$boot_config" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
            if [[ $installed_hash != "$new_hash" ]]; then result_code=1; failure_reason='Installed stock config failed final hash verification.'; fi
        fi
    fi
    if (( result_code != 0 && install_attempted == 1 )); then
        installed_hash=$(sha256sum "$boot_config" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
        if [[ $installed_hash == "$new_hash" ]]; then
            if reset_stock_replace_verified "$backup_file" "$boot_config" "$old_hash" "$new_hash" "${reset_id}-restore"; then
                failure_reason="$failure_reason The verified pre-reset config was restored."
            else
                failure_reason="$failure_reason Verified pre-reset config restoration failed."
            fi
        elif [[ $installed_hash == "$old_hash" ]]; then
            failure_reason="$failure_reason The verified original config remains installed."
        else
            failure_reason="$failure_reason Destination hash is ${installed_hash:-unavailable}; unknown content was preserved."
        fi
    fi
    rm -f -- "$rendered_file"
    if ! apply_remount_boot_ro; then
        emit_result APPLY_FAILURE 'Stock reset could not restore and verify /boot read-only; the exit cleanup will retry.'
        return 1
    fi
    apply_clear_traps
    if (( result_code != 0 )); then emit_result APPLY_FAILURE "$failure_reason"; return 1; fi
    sync || { emit_result APPLY_FAILURE 'Could not durably sync the completed stock reset.'; return 1; }
    emit_data RESET_BACKUP "$backup_file"
    [[ -z $tryboot_backup ]] || emit_data RESET_TRYBOOT_BACKUP "$tryboot_backup"
    emit_data RESET_OLD_HASH "$old_hash"
    emit_data RESET_NEW_HASH "$new_hash"
    emit_data RESET_DISABLED_KEYS "$disabled_keys"
    emit_result PASS 'Permanent tuning was disabled, owned tryboot evidence was safely handled, verified reset backups were preserved, and /boot returned read-only.'
}

cmd_reboot_stock_reset() {
    local expected_hash=$1 boot_config=/boot/config.txt current_hash tryboot_flag
    valid_sha256 "$expected_hash" || { emit_result RECOVERY_FAILURE 'Stock-reset reboot received a malformed permanent-config hash.'; return 1; }
    [[ -f $boot_config && ! -L $boot_config ]] || { emit_result RECOVERY_FAILURE 'Stock-reset reboot refuses a missing, non-regular, or symlinked permanent config.'; return 1; }
    reset_stock_paths_clear "$boot_config" || { emit_result RECOVERY_FAILURE 'Stock-reset reboot requires all staged and quarantined tryboot paths to be absent.'; return 1; }
    boot_mount_has_option ro || { emit_result RECOVERY_FAILURE 'Stock-reset reboot requires Batocera /boot to be read-only.'; return 1; }
    current_hash=$(sha256sum "$boot_config" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    [[ $current_hash == "$expected_hash" ]] || { emit_result RECOVERY_FAILURE 'Permanent config changed at the stock-reset reboot boundary.'; return 1; }
    tryboot_flag=$(od -An -tx1 /proc/device-tree/chosen/bootloader/tryboot 2>/dev/null | tr -d ' \n' || true)
    [[ $tryboot_flag == 00000000 || $tryboot_flag == 00000001 ]] || { emit_result RECOVERY_FAILURE "Stock-reset reboot found unreadable tryboot state ${tryboot_flag:-missing}."; return 1; }
    vcgencmd get_throttled 0x0f >/dev/null 2>&1 || true
    sync || { emit_result RECOVERY_FAILURE 'Could not sync before stock-reset reboot.'; return 1; }
    trap - EXIT INT TERM HUP
    verified_normal_reboot_now
    emit_result RECOVERY_FAILURE 'The verified stock-reset reboot syscall returned without restarting the target.'
    return 1
}

cmd_verify_stock_reset() {
    local expected_new_hash=$1 boot_config=/boot/config.txt current_hash model compatible cpu_mhz gpu_mhz voltage_uv throttle throttle_value
    valid_sha256 "$expected_new_hash" || { emit_result RECOVERY_FAILURE 'Stock-reset verification received a malformed expected hash.'; return 1; }
    reset_stock_validate_config "$boot_config" || { emit_result RECOVERY_FAILURE "$RESET_STOCK_LAST_REASON"; return 1; }
    reset_stock_no_artifacts "$boot_config" || { emit_result RECOVERY_FAILURE 'Stock-reset verification found live, staged, quarantined, or unresolved tryboot evidence.'; return 1; }
    boot_mount_has_option ro || { emit_result RECOVERY_FAILURE 'Batocera /boot is not read-only after stock-reset reboot.'; return 1; }
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
    boot_mount_has_option ro || { emit_result RECOVERY_FAILURE 'Batocera /boot changed from read-only during final stock-reset verification.'; return 1; }
    current_hash=$(sha256sum "$boot_config" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    [[ $current_hash == "$expected_new_hash" ]] || { emit_result RECOVERY_FAILURE 'Permanent config changed during final stock-reset verification.'; return 1; }
    emit_data RESET_NEW_HASH "$current_hash"
    emit_data RESET_ACTIVE_CPU "$cpu_mhz"
    emit_data RESET_ACTIVE_GPU "$gpu_mhz"
    emit_data RESET_ACTIVE_VOLTAGE "$voltage_uv"
    emit_result PASS 'Normal boot, protected hash, default provenance, Pi 5 stock clocks, voltage, current power state, watchdogs, and read-only /boot were verified.'
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

APO_APPLY_BOOT_RW=0

apply_remount_boot_ro() {
    local sync_rc=0
    (( APO_APPLY_BOOT_RW == 1 )) || return 0
    sync || sync_rc=$?
    remount_boot_ro || return 1
    APO_APPLY_BOOT_RW=0
    (( sync_rc == 0 ))
}

apply_signal_cleanup() {
    local exit_code=$1
    trap - INT TERM HUP
    apply_remount_boot_ro >/dev/null 2>&1 || true
    if (( APO_APPLY_BOOT_RW == 0 )); then mutation_lock_release >/dev/null 2>&1 || true; fi
    exit "$exit_code"
}

apply_exit_cleanup() {
    apply_remount_boot_ro >/dev/null 2>&1 || true
    if (( APO_APPLY_BOOT_RW == 0 )); then mutation_lock_release >/dev/null 2>&1 || true; fi
}

apply_install_traps() {
    trap apply_exit_cleanup EXIT
    trap 'apply_signal_cleanup 130' INT
    trap 'apply_signal_cleanup 143' TERM
    trap 'apply_signal_cleanup 129' HUP
}

apply_clear_traps() { trap - EXIT INT TERM HUP; }

cmd_apply_permanent() {
    local uploaded_file=$1 expected_old_hash=$2 expected_new_hash=$3 run_id=$4
    local current_hash proposed_hash backup_dir backup_file backup_hash install_ok=0 rollback_ok=0
    valid_sha256 "$expected_old_hash" && valid_sha256 "$expected_new_hash" && [[ $expected_old_hash != "$expected_new_hash" ]] || { emit_result APPLY_FAILURE 'Apply hashes are missing or invalid.'; return 1; }
    apply_tryboot_clear /boot/config.txt || { emit_result APPLY_FAILURE 'Permanent apply requires a normal boot with no live, staged, or quarantined tryboot evidence.'; return 1; }
    current_hash=$(sha256sum /boot/config.txt | awk '{print $1}')
    [[ $current_hash == "$expected_old_hash" ]] || { emit_result APPLY_FAILURE 'Permanent config changed since validation; refusing to apply.'; return 1; }
    [[ -s $uploaded_file ]] || { emit_result APPLY_FAILURE 'Uploaded proposed config is empty.'; return 1; }
    proposed_hash=$(sha256sum "$uploaded_file" | awk '{print $1}')
    [[ $proposed_hash == "$expected_new_hash" ]] || { emit_result APPLY_FAILURE 'Uploaded proposed config does not match the persisted expected hash.'; return 1; }
    backup_dir="$PERSISTENT_ROOT/backups"
    mkdir -p "$backup_dir" || { emit_result APPLY_FAILURE 'Could not create the permanent-config backup directory.'; return 1; }
    backup_file="${backup_dir}/config-${run_id}-before-apply.txt"
    backup_hash=$(sha256sum "$backup_file" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    if [[ $backup_hash != "$expected_old_hash" ]]; then
        atomic_replace_verified /boot/config.txt "$backup_file" "$expected_old_hash" backup || { emit_result APPLY_FAILURE 'Could not create and verify the deterministic permanent backup.'; return 1; }
    fi
    if ! chmod --reference=/boot/config.txt "$uploaded_file" 2>/dev/null && ! chmod 644 "$uploaded_file"; then
        emit_result APPLY_FAILURE 'Could not set proposed permanent-config permissions.'
        return 1
    fi
    apply_install_traps
    APO_APPLY_BOOT_RW=1
    if ! remount_boot_rw; then
        apply_remount_boot_ro >/dev/null 2>&1 || true
        (( APO_APPLY_BOOT_RW == 0 )) && apply_clear_traps
        emit_result APPLY_FAILURE 'Could not remount and verify /boot read-write for apply.'
        return 1
    fi
    if ! apply_tryboot_clear /boot/config.txt; then
        apply_remount_boot_ro >/dev/null 2>&1 || true
        (( APO_APPLY_BOOT_RW == 0 )) && apply_clear_traps
        emit_result APPLY_FAILURE 'Tryboot evidence appeared before permanent replacement; refusing to apply.'
        return 1
    fi
    current_hash=$(sha256sum /boot/config.txt | awk '{print $1}')
    if [[ $current_hash != "$expected_old_hash" ]]; then
        apply_remount_boot_ro >/dev/null 2>&1 || true
        (( APO_APPLY_BOOT_RW == 0 )) && apply_clear_traps
        emit_result APPLY_FAILURE 'Permanent config changed at the apply mutation boundary; refusing to apply.'
        return 1
    fi
    if atomic_replace_verified "$uploaded_file" /boot/config.txt "$expected_new_hash" new; then install_ok=1; fi
    if (( install_ok == 0 )); then
        atomic_replace_verified "$backup_file" /boot/config.txt "$expected_old_hash" restore && rollback_ok=1
    fi
    if ! apply_remount_boot_ro; then
        emit_result APPLY_FAILURE 'Permanent-config apply could not verify that /boot returned read-only; the exit cleanup will retry.'
        return 1
    fi
    apply_clear_traps
    if (( install_ok == 0 )); then
        if (( rollback_ok == 1 )); then emit_result APPLY_FAILURE 'Atomic permanent-config replacement failed; the verified backup was restored.'
        else emit_result APPLY_FAILURE 'Atomic permanent-config replacement failed and backup restoration could not be verified.'; fi
        return 1
    fi
    emit_data BACKUP_FILE "$backup_file"; emit_data NEW_HASH "$expected_new_hash"; emit_result PASS 'Validated clocks were written to permanent config, verified, and /boot returned read-only.'
}

cmd_restore_backup() {
    local backup_file=$1 expected_old_hash=$2 expected_current_hash=$3 backup_hash current_hash
    valid_sha256 "$expected_old_hash" && valid_sha256 "$expected_current_hash" && [[ $expected_old_hash != "$expected_current_hash" ]] \
        || { emit_result APPLY_FAILURE 'Rollback old/current hashes are missing, invalid, or identical.'; return 1; }
    apply_tryboot_clear /boot/config.txt || { emit_result APPLY_FAILURE 'Rollback requires a normal boot with no live, staged, or quarantined tryboot evidence.'; return 1; }
    current_hash=$(sha256sum /boot/config.txt 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    [[ $current_hash == "$expected_current_hash" ]] || { emit_result APPLY_FAILURE 'Permanent config does not match the persisted pre-rollback destination hash; refusing restoration.'; return 1; }
    [[ -f $backup_file ]] || { emit_result APPLY_FAILURE "Backup file is missing: $backup_file"; return 1; }
    backup_hash=$(sha256sum "$backup_file" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    [[ $backup_hash == "$expected_old_hash" ]] || { emit_result APPLY_FAILURE 'Permanent config backup does not match the persisted pre-apply hash.'; return 1; }
    apply_install_traps
    APO_APPLY_BOOT_RW=1
    if ! remount_boot_rw; then
        apply_remount_boot_ro >/dev/null 2>&1 || true
        (( APO_APPLY_BOOT_RW == 0 )) && apply_clear_traps
        emit_result APPLY_FAILURE 'Could not remount and verify /boot read-write for rollback.'
        return 1
    fi
    if ! apply_tryboot_clear /boot/config.txt; then
        apply_remount_boot_ro >/dev/null 2>&1 || true
        (( APO_APPLY_BOOT_RW == 0 )) && apply_clear_traps
        emit_result APPLY_FAILURE 'Tryboot evidence appeared before rollback replacement; refusing mutation.'
        return 1
    fi
    current_hash=$(sha256sum /boot/config.txt 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    if [[ $current_hash != "$expected_current_hash" ]]; then
        apply_remount_boot_ro >/dev/null 2>&1 || true
        (( APO_APPLY_BOOT_RW == 0 )) && apply_clear_traps
        emit_result APPLY_FAILURE 'Permanent config changed at the rollback mutation boundary; refusing restoration.'
        return 1
    fi
    if ! atomic_replace_verified "$backup_file" /boot/config.txt "$expected_old_hash" restore; then
        apply_remount_boot_ro >/dev/null 2>&1 || true
        (( APO_APPLY_BOOT_RW == 0 )) && apply_clear_traps
        emit_result APPLY_FAILURE 'Could not restore and verify the Batocera permanent config backup.'
        return 1
    fi
    if ! apply_remount_boot_ro; then
        emit_result APPLY_FAILURE 'Rollback restored the expected config but could not verify that /boot returned read-only; the exit cleanup will retry.'
        return 1
    fi
    apply_clear_traps
    emit_data RESTORED_HASH "$expected_old_hash"; emit_result PASS 'Permanent config backup restored, verified, and /boot returned read-only.'
}

batocera_watchdog_asset_paths_ready() {
    local installer=$1 keeper=$2 service=$3 installer_directory keeper_directory service_directory
    [[ -f $installer && ! -L $installer && -x $installer ]] || return 1
    [[ -f $keeper && ! -L $keeper && -f $service && ! -L $service ]] || return 1
    installer_directory=$(readlink -f -- "$(dirname "$installer")" 2>/dev/null || true)
    keeper_directory=$(readlink -f -- "$(dirname "$keeper")" 2>/dev/null || true)
    service_directory=$(readlink -f -- "$(dirname "$service")" 2>/dev/null || true)
    [[ -n $installer_directory && $installer_directory == "$keeper_directory" && $installer_directory == "$service_directory" ]] || return 1
    [[ $installer_directory == "$PERSISTENT_ROOT"/runs/* ]] || return 1
    grep -Fq 'AUTOPIOVERCLOCK MANAGED BATOCERA WATCHDOG' "$keeper" &&
        grep -Fq 'AUTOPIOVERCLOCK MANAGED BATOCERA WATCHDOG' "$service"
}

cmd_plan_watchdog_repair() {
    local installer=${1:-} keeper=${2:-} service=${3:-} run_id=${4:-}
    batocera_watchdog_asset_paths_ready "$installer" "$keeper" "$service" || {
        emit_result PREFLIGHT_FAILURE 'Batocera watchdog plan received missing, foreign, or unsafe project assets.'
        return 1
    }
    "$installer" plan "$keeper" "$service" "$run_id"
}

cmd_repair_watchdogs() {
    local installer=${1:-} keeper=${2:-} service=${3:-}
    batocera_watchdog_asset_paths_ready "$installer" "$keeper" "$service" || {
        emit_result PREFLIGHT_FAILURE 'Batocera watchdog repair received missing, foreign, or unsafe project assets.'
        return 1
    }
    "$installer" apply "$keeper" "$service" "${@:4}"
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
        reset-stock) run_with_mutation_lock "reset-${2:-}" APPLY_FAILURE cmd_reset_stock "$@" ;;
        reboot-stock-reset) run_with_mutation_lock "reset-reboot-${BASHPID}" RECOVERY_FAILURE cmd_reboot_stock_reset "$@" ;;
        verify-stock-reset) run_with_mutation_lock "reset-verify-${BASHPID}" RECOVERY_FAILURE cmd_verify_stock_reset "$@" ;;
        apply-permanent) run_with_mutation_lock "apply-${4:-}" APPLY_FAILURE cmd_apply_permanent "$@" ;;
        restore-backup) run_with_mutation_lock "restore-${2:-}" APPLY_FAILURE cmd_restore_backup "$@" ;;
        plan-watchdog-repair) cmd_plan_watchdog_repair "$@" ;;
        repair-watchdogs) run_with_mutation_lock "watchdog-${4:-}" PREFLIGHT_FAILURE cmd_repair_watchdogs "$@" ;;
        classify-kernel-log) cmd_classify_kernel_log "$@" ;;
        *) emit_result HARNESS_FAILURE "Unknown worker command: $command_name"; return 2 ;;
    esac
}

if [[ ${APO_WORKER_LIBRARY_ONLY:-0} != 1 ]]; then main "$@"; fi
