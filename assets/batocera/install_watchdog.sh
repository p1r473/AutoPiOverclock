#!/usr/bin/env bash
# Install the project-owned Batocera watchdog with hash-bound planning.
set -u -o pipefail
umask 077

readonly MANAGED_MARKER='AUTOPIOVERCLOCK MANAGED BATOCERA WATCHDOG'
readonly WATCHDOG_BLOCK_BEGIN='# BEGIN AUTOPIOVERCLOCK MANAGED WATCHDOG'
readonly WATCHDOG_BLOCK_END='# END AUTOPIOVERCLOCK MANAGED WATCHDOG'
readonly SERVICE_BLOCK_BEGIN='# BEGIN AUTOPIOVERCLOCK MANAGED WATCHDOG SERVICE'
readonly SERVICE_BLOCK_END='# END AUTOPIOVERCLOCK MANAGED WATCHDOG SERVICE'
readonly SERVICE_NAME=AutoPiOverclockWatchdog
readonly BOOT_CONFIG=/boot/config.txt
readonly CMDLINE_FILE=/boot/cmdline.txt
readonly BATOCERA_CONFIG=/userdata/system/batocera.conf
readonly LIVE_ROOT=/userdata/system/autopioverclock/watchdog
readonly LIVE_KEEPER=${LIVE_ROOT}/watchdog_keeper.py
readonly LIVE_SERVICE=/userdata/system/services/${SERVICE_NAME}
readonly LIVE_CONFIG=${LIVE_ROOT}/watchdog.conf
readonly BACKUP_ROOT=/userdata/system/autopioverclock/backups
readonly EEPROM_TIMEOUT=60
readonly KERNEL_TIMEOUT=180
readonly DEVICE_TIMEOUT=15
readonly FEED_INTERVAL=5
readonly CHECK_INTERVAL=10
readonly PING_TIMEOUT=2
readonly STARTUP_GRACE=180
readonly FAILURE_WINDOW=180
readonly MAX_REBOOTS=3
readonly REBOOT_WINDOW=1800

APO_WATCHDOG_APPLY_PLAN_DIR=''
APO_WATCHDOG_APPLY_BOOT_RW=0

b64() { printf '%s' "${1-}" | base64 | tr -d '\n'; }
emit_data() { printf 'APO_DATA\t%s\t%s\n' "$1" "$(b64 "${2-}")"; }
emit_result() {
    printf 'APO_RESULT_CLASS=%s\n' "$1"
    printf 'APO_RESULT_REASON_B64=%s\n' "$(b64 "$2")"
}
valid_hash() { [[ ${1-} =~ ^[0-9a-f]{64}$ ]]; }
file_hash() { sha256sum "$1" 2>/dev/null | awk 'NR == 1 {print $1}'; }
safe_run_id() { [[ ${1-} =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; }
regular_file() { [[ -f $1 && ! -L $1 ]]; }

boot_is_read_only() {
    local source target filesystem options dump pass
    while read -r source target filesystem options dump pass; do
        [[ $target == /boot ]] || continue
        case ",$options," in *,ro,*) return 0 ;; esac
    done < /proc/mounts
    return 1
}

remount_boot() {
    local wanted=$1
    mount -o "remount,$wanted" /boot || return 1
    if [[ $wanted == ro ]]; then boot_is_read_only; else ! boot_is_read_only; fi
}

tryboot_clear() {
    local flag quarantine
    [[ ! -e /boot/tryboot.txt && ! -L /boot/tryboot.txt ]] || return 1
    flag=$(od -An -tx1 /proc/device-tree/chosen/bootloader/tryboot 2>/dev/null | tr -d ' \n' || true)
    [[ $flag == 00000000 ]] || return 1
    for quarantine in /boot/.autopioverclock-remove-*; do
        [[ ! -e $quarantine && ! -L $quarantine ]] || return 1
    done
}

watchdog_device_path() {
    local candidate
    for candidate in /dev/watchdog0 /dev/watchdog; do
        [[ -c $candidate ]] || continue
        printf '%s' "$candidate"
        return 0
    done
    return 1
}

watchdog_owner_pid() {
    local device=$1 canonical_device device_id fd_path fd_target fd_id pid
    canonical_device=$(readlink -f -- "$device" 2>/dev/null || printf '%s' "$device")
    device_id=$(stat -Lc '%t:%T' "$device" 2>/dev/null || true)
    [[ -n $device_id ]] || return 1
    for fd_path in /proc/[0-9]*/fd/*; do
        [[ -L $fd_path ]] || continue
        fd_target=$(readlink -f -- "$fd_path" 2>/dev/null || true)
        if [[ $fd_target != "$canonical_device" ]]; then
            [[ -c $fd_target ]] || continue
            fd_id=$(stat -Lc '%t:%T' "$fd_target" 2>/dev/null || true)
            [[ -n $fd_id && $fd_id == "$device_id" ]] || continue
        fi
        pid=${fd_path#/proc/}
        pid=${pid%%/*}
        [[ $pid =~ ^[1-9][0-9]*$ ]] || return 1
        printf '%s' "$pid"
        return 0
    done
    return 1
}

watchdog_owner_compatible() {
    local device=$1 owner_pid
    owner_pid=$(watchdog_owner_pid "$device" || true)
    [[ -n $owner_pid ]] || return 0
    [[ -r /proc/$owner_pid/cmdline ]] || return 1
    /usr/bin/python3 - "$owner_pid" "$LIVE_KEEPER" "$LIVE_CONFIG" <<'PY'
from pathlib import Path
import sys

pid, keeper, config = sys.argv[1:]
arguments = Path(f"/proc/{pid}/cmdline").read_bytes().rstrip(b"\0").split(b"\0")
expected = {keeper.encode(), config.encode()}
raise SystemExit(0 if expected.issubset(set(arguments)) else 1)
PY
}

valid_ipv4() {
    awk -F. '
        NF != 4 {exit 1}
        {for (i=1; i<=4; i++) if ($i !~ /^[0-9]+$/ || $i+0 > 255 || $i != $i+0) exit 1}
    ' <<< "${1-}"
}

default_gateway() {
    local gateway
    gateway=$(ip -4 route show default 2>/dev/null | awk '
        $1 == "default" {
            value=""
            for (i=1; i<NF; i++) if ($i == "via") value=$(i+1)
            if (value != "") {count++; selected=value}
        }
        END {if (count == 1) print selected}
    ')
    valid_ipv4 "$gateway" || return 1
    printf '%s' "$gateway"
}

managed_or_absent() {
    local candidate=$1
    if [[ -L $candidate || ( -e $candidate && ! -f $candidate ) ]]; then return 1; fi
    [[ ! -e $candidate ]] || grep -Fq "$MANAGED_MARKER" "$candidate"
}

managed_block_valid() {
    local source=$1 begin=$2 end=$3
    awk -v begin="$begin" -v end="$end" '
        $0 == begin {
            if (inside || seen_begin) {invalid=1; next}
            inside=1
            seen_begin=1
            next
        }
        $0 == end {
            if (!inside || seen_end) {invalid=1; next}
            inside=0
            seen_end=1
            next
        }
        END {exit (invalid || inside || seen_begin != seen_end)}
    ' "$source"
}

render_boot_config() {
    local source=$1 destination=$2
    managed_block_valid "$source" "$WATCHDOG_BLOCK_BEGIN" "$WATCHDOG_BLOCK_END" || return 1
    awk -v begin="$WATCHDOG_BLOCK_BEGIN" -v end="$WATCHDOG_BLOCK_END" '
        $0 == begin {inside=1; next}
        $0 == end {inside=0; next}
        inside {next}
        /^[[:space:]]*kernel_watchdog_timeout[[:space:]]*=/ {
            print "# AUTOPIOVERCLOCK-WATCHDOG-DISABLED " $0
            next
        }
        {print}
    ' "$source" > "$destination" || return 1
    printf '%s\n[all]\nkernel_watchdog_timeout=%s\n%s\n' \
        "$WATCHDOG_BLOCK_BEGIN" "$KERNEL_TIMEOUT" "$WATCHDOG_BLOCK_END" >> "$destination"
}

render_cmdline() {
    local source=$1 destination=$2 line token rendered='' line_count
    local -a tokens=()
    line_count=$(awk 'NF {count++} END {print count+0}' "$source")
    [[ $line_count == 1 ]] || return 1
    line=$(awk 'NF {print; exit}' "$source")
    read -r -a tokens <<< "$line"
    for token in "${tokens[@]}"; do
        [[ $token == watchdog.open_timeout=* ]] && continue
        rendered=${rendered:+$rendered }$token
    done
    [[ -n $rendered ]] || return 1
    printf '%s watchdog.open_timeout=%s\n' "$rendered" "$KERNEL_TIMEOUT" > "$destination"
}

effective_services() {
    local source=$1
    awk -F= '
        /^[[:space:]]*#/ {next}
        /^[[:space:]]*system[.]services[[:space:]]*=/ {
            value=$0
            sub(/^[^=]*=[[:space:]]*/, "", value)
        }
        END {print value}
    ' "$source"
}

render_batocera_config() {
    local source=$1 destination=$2 services token rendered=''
    local -a service_tokens=()
    managed_block_valid "$source" "$SERVICE_BLOCK_BEGIN" "$SERVICE_BLOCK_END" || return 1
    services=$(effective_services "$source")
    read -r -a service_tokens <<< "$services"
    for token in "${service_tokens[@]}"; do
        [[ $token =~ ^[A-Za-z0-9._-]+$ ]] || return 1
        [[ $token == "$SERVICE_NAME" ]] && continue
        rendered=${rendered:+$rendered }$token
    done
    rendered=${rendered:+$rendered }$SERVICE_NAME
    awk -v begin="$SERVICE_BLOCK_BEGIN" -v end="$SERVICE_BLOCK_END" '
        $0 == begin {inside=1; next}
        $0 == end {inside=0; next}
        inside {next}
        /^[[:space:]]*system[.]services[[:space:]]*=/ {
            print "# AUTOPIOVERCLOCK-WATCHDOG-SERVICES-PREVIOUS " $0
            next
        }
        {print}
    ' "$source" > "$destination" || return 1
    printf '%s\nsystem.services=%s\n%s\n' \
        "$SERVICE_BLOCK_BEGIN" "$rendered" "$SERVICE_BLOCK_END" >> "$destination"
}

render_keeper_config() {
    local destination=$1 target=$2
    valid_ipv4 "$target" || return 1
    cat > "$destination" <<EOF
# $MANAGED_MARKER
TARGET=$target
DEVICE_TIMEOUT_SECONDS=$DEVICE_TIMEOUT
FEED_INTERVAL_SECONDS=$FEED_INTERVAL
CHECK_INTERVAL_SECONDS=$CHECK_INTERVAL
PING_TIMEOUT_SECONDS=$PING_TIMEOUT
STARTUP_GRACE_SECONDS=$STARTUP_GRACE
FAILURE_WINDOW_SECONDS=$FAILURE_WINDOW
MAX_REBOOTS=$MAX_REBOOTS
REBOOT_WINDOW_SECONDS=$REBOOT_WINDOW
EOF
}

render_eeprom() {
    local source=$1 destination=$2
    awk -F= -v wanted="$EEPROM_TIMEOUT" '
        BEGIN {done=0}
        {
            key=$1
            gsub(/[[:space:]]/, "", key)
            if (key == "BOOT_WATCHDOG_TIMEOUT") {
                if (!done) print "BOOT_WATCHDOG_TIMEOUT=" wanted
                done=1
                next
            }
            print
        }
        END {if (!done) print "BOOT_WATCHDOG_TIMEOUT=" wanted}
    ' "$source" > "$destination"
}

eeprom_watchdog_timeout() {
    local source=$1
    awk -F= '
        /^[[:space:]]*#/ {next}
        {
            key=$1
            gsub(/[[:space:]]/, "", key)
            if (key != "BOOT_WATCHDOG_TIMEOUT") next
            value=$0
            sub(/^[^=]*=/, "", value)
            gsub(/[[:space:]]/, "", value)
            count++
        }
        END {
            if (count == 0) {print 0; exit}
            if (count != 1 || value !~ /^[0-9]+$/) exit 1
            print value + 0
        }
    ' "$source"
}

plan_eeprom() {
    local source=$1 destination=$2 current_timeout
    current_timeout=$(eeprom_watchdog_timeout "$source") || return 1
    [[ $current_timeout =~ ^[0-9]+$ ]] || return 1
    PLAN_EEPROM_CURRENT_TIMEOUT=$current_timeout
    if (( current_timeout > 0 )); then
        cp -- "$source" "$destination" || return 1
        PLAN_EEPROM_EFFECTIVE_TIMEOUT=$current_timeout
        PLAN_EEPROM_APPLY_REQUIRED=0
    else
        render_eeprom "$source" "$destination" || return 1
        PLAN_EEPROM_EFFECTIVE_TIMEOUT=$EEPROM_TIMEOUT
        PLAN_EEPROM_APPLY_REQUIRED=1
    fi
}

apply_eeprom_plan() {
    local source=$1 apply_required=$2 diagnostic_file=$3
    case $apply_required in
        0) return 0 ;;
        1) rpi-eeprom-config --apply "$source" > "$diagnostic_file" 2>&1 ;;
        *) return 2 ;;
    esac
}

atomic_install() {
    local source=$1 destination=$2 expected_old_hash=$3 expected_new_hash=$4 mode=$5 temporary current_hash installed_hash
    regular_file "$source" || return 1
    installed_hash=$(file_hash "$source" || true)
    [[ $installed_hash == "$expected_new_hash" ]] || return 1
    if [[ -e $destination || -L $destination ]]; then
        regular_file "$destination" || return 1
        current_hash=$(file_hash "$destination" || true)
        [[ $current_hash == "$expected_old_hash" ]] || return 1
    else
        [[ $expected_old_hash == absent ]] || return 1
    fi
    temporary=$(mktemp "$(dirname "$destination")/.autopioverclock-watchdog.XXXXXX") || return 1
    cp -- "$source" "$temporary" || { rm -f -- "$temporary"; return 1; }
    chmod "$mode" "$temporary" || { rm -f -- "$temporary"; return 1; }
    installed_hash=$(file_hash "$temporary" || true)
    [[ $installed_hash == "$expected_new_hash" ]] || { rm -f -- "$temporary"; return 1; }
    if [[ -e $destination || -L $destination ]]; then
        current_hash=$(file_hash "$destination" || true)
        [[ $current_hash == "$expected_old_hash" ]] || { rm -f -- "$temporary"; return 1; }
    else
        [[ $expected_old_hash == absent ]] || { rm -f -- "$temporary"; return 1; }
    fi
    mv -f -- "$temporary" "$destination" || { rm -f -- "$temporary"; return 1; }
    sync "$destination" || return 1
    [[ $(file_hash "$destination" || true) == "$expected_new_hash" ]]
}

preflight() {
    local keeper_source=$1 service_source=$2 run_id=$3 watchdog_device
    safe_run_id "$run_id" || return 1
    regular_file "$keeper_source" && regular_file "$service_source" || return 1
    grep -Fq "$MANAGED_MARKER" "$keeper_source" && grep -Fq "$MANAGED_MARKER" "$service_source" || return 1
    regular_file "$BOOT_CONFIG" && regular_file "$CMDLINE_FILE" && regular_file "$BATOCERA_CONFIG" || return 1
    managed_or_absent "$LIVE_KEEPER" && managed_or_absent "$LIVE_SERVICE" && managed_or_absent "$LIVE_CONFIG" || return 1
    boot_is_read_only && tryboot_clear || return 1
    watchdog_device=$(watchdog_device_path) || return 1
    for required in awk base64 grep ip mount nohup od ping readlink rpi-eeprom-config sha256sum stat sync; do
        command -v "$required" >/dev/null 2>&1 || return 1
    done
    [[ -x /usr/bin/python3 ]] || return 1
    watchdog_owner_compatible "$watchdog_device"
}

plan_values() {
    local keeper_source=$1 service_source=$2 run_id=$3 plan_dir=$4
    preflight "$keeper_source" "$service_source" "$run_id" || return 1
    PLAN_TARGET=$(default_gateway) || return 1
    ping -c 3 -W "$PING_TIMEOUT" "$PLAN_TARGET" >/dev/null 2>&1 || return 1
    PLAN_KEEPER_HASH=$(file_hash "$keeper_source" || true)
    PLAN_SERVICE_HASH=$(file_hash "$service_source" || true)
    valid_hash "$PLAN_KEEPER_HASH" && valid_hash "$PLAN_SERVICE_HASH" || return 1
    PLAN_BOOT_OLD_HASH=$(file_hash "$BOOT_CONFIG" || true)
    PLAN_CMDLINE_OLD_HASH=$(file_hash "$CMDLINE_FILE" || true)
    PLAN_BATOCERA_OLD_HASH=$(file_hash "$BATOCERA_CONFIG" || true)
    valid_hash "$PLAN_BOOT_OLD_HASH" && valid_hash "$PLAN_CMDLINE_OLD_HASH" && valid_hash "$PLAN_BATOCERA_OLD_HASH" || return 1
    render_boot_config "$BOOT_CONFIG" "$plan_dir/config.txt" || return 1
    render_cmdline "$CMDLINE_FILE" "$plan_dir/cmdline.txt" || return 1
    render_batocera_config "$BATOCERA_CONFIG" "$plan_dir/batocera.conf" || return 1
    render_keeper_config "$plan_dir/watchdog.conf" "$PLAN_TARGET" || return 1
    rpi-eeprom-config > "$plan_dir/eeprom-current" || return 1
    plan_eeprom "$plan_dir/eeprom-current" "$plan_dir/eeprom-new" || return 1
    PLAN_BOOT_NEW_HASH=$(file_hash "$plan_dir/config.txt" || true)
    PLAN_CMDLINE_NEW_HASH=$(file_hash "$plan_dir/cmdline.txt" || true)
    PLAN_BATOCERA_NEW_HASH=$(file_hash "$plan_dir/batocera.conf" || true)
    PLAN_KEEPER_CONFIG_HASH=$(file_hash "$plan_dir/watchdog.conf" || true)
    PLAN_EEPROM_NEW_HASH=$(file_hash "$plan_dir/eeprom-new" || true)
    valid_hash "$PLAN_BOOT_NEW_HASH" && valid_hash "$PLAN_CMDLINE_NEW_HASH" && valid_hash "$PLAN_BATOCERA_NEW_HASH" &&
        valid_hash "$PLAN_KEEPER_CONFIG_HASH" && valid_hash "$PLAN_EEPROM_NEW_HASH"
}

emit_plan() {
    emit_data WATCHDOG_REPAIR_TARGET "$PLAN_TARGET"
    emit_data WATCHDOG_REPAIR_OLD_HASH "$PLAN_BOOT_OLD_HASH"
    emit_data WATCHDOG_REPAIR_EXPECTED_HASH "$PLAN_BOOT_NEW_HASH"
    emit_data WATCHDOG_REPAIR_CMDLINE_OLD_HASH "$PLAN_CMDLINE_OLD_HASH"
    emit_data WATCHDOG_REPAIR_CMDLINE_NEW_HASH "$PLAN_CMDLINE_NEW_HASH"
    emit_data WATCHDOG_REPAIR_BATOCERA_OLD_HASH "$PLAN_BATOCERA_OLD_HASH"
    emit_data WATCHDOG_REPAIR_BATOCERA_NEW_HASH "$PLAN_BATOCERA_NEW_HASH"
    emit_data WATCHDOG_REPAIR_KEEPER_HASH "$PLAN_KEEPER_HASH"
    emit_data WATCHDOG_REPAIR_SERVICE_HASH "$PLAN_SERVICE_HASH"
    emit_data WATCHDOG_REPAIR_KEEPER_CONFIG_HASH "$PLAN_KEEPER_CONFIG_HASH"
    emit_data WATCHDOG_REPAIR_EEPROM_HASH "$PLAN_EEPROM_NEW_HASH"
    emit_data WATCHDOG_REPAIR_EEPROM_CURRENT_TIMEOUT "$PLAN_EEPROM_CURRENT_TIMEOUT"
    emit_data WATCHDOG_REPAIR_EEPROM_TIMEOUT "$PLAN_EEPROM_EFFECTIVE_TIMEOUT"
    emit_data WATCHDOG_REPAIR_EEPROM_APPLY_REQUIRED "$PLAN_EEPROM_APPLY_REQUIRED"
}

plan() {
    local keeper_source=$1 service_source=$2 run_id=$3 plan_dir
    plan_dir=$(mktemp -d /tmp/autopioverclock-watchdog-plan.XXXXXX) || {
        emit_result PREFLIGHT_FAILURE 'Could not create the Batocera watchdog plan directory.'
        return 1
    }
    if ! plan_values "$keeper_source" "$service_source" "$run_id" "$plan_dir"; then
        rm -rf -- "$plan_dir"
        emit_result PREFLIGHT_FAILURE 'Batocera watchdog planning failed: require one reachable IPv4 default gateway, a live watchdog device without a foreign owner, clear tryboot state, read-only /boot, Python, ping, EEPROM tooling, and no foreign managed-service paths.'
        return 1
    fi
    emit_plan
    rm -rf -- "$plan_dir"
    emit_result PASS "Batocera watchdog installation is ready for target $PLAN_TARGET with bounded network-loss reboot protection."
}

backup_file() {
    local source=$1 destination=$2
    if [[ -e $source || -L $source ]]; then
        regular_file "$source" || return 1
        cp -a -- "$source" "$destination" || return 1
        [[ $(file_hash "$source" || true) == $(file_hash "$destination" || true) ]] || return 1
    else
        printf 'ABSENT\n' > "${destination}.absent"
    fi
}

restore_file() {
    local backup=$1 destination=$2 mode=$3
    if [[ -f ${backup}.absent ]]; then
        rm -f -- "$destination"
    else
        cp -a -- "$backup" "$destination" && chmod "$mode" "$destination"
    fi
}

watchdog_apply_exit_cleanup() {
    local exit_code=$?
    trap - EXIT INT TERM HUP
    if (( APO_WATCHDOG_APPLY_BOOT_RW == 1 )); then
        if remount_boot ro; then
            APO_WATCHDOG_APPLY_BOOT_RW=0
        else
            printf 'AutoPiOverclock watchdog cleanup could not restore /boot read-only.\n' >&2
            exit_code=1
        fi
    fi
    if [[ -n $APO_WATCHDOG_APPLY_PLAN_DIR ]]; then
        rm -rf -- "$APO_WATCHDOG_APPLY_PLAN_DIR"
        APO_WATCHDOG_APPLY_PLAN_DIR=''
    fi
    exit "$exit_code"
}

watchdog_apply_clear_exit_cleanup() {
    trap - EXIT INT TERM HUP
    APO_WATCHDOG_APPLY_PLAN_DIR=''
    APO_WATCHDOG_APPLY_BOOT_RW=0
}

apply_plan() {
    local keeper_source=$1 service_source=$2 run_id=$3 expected_target=$4 expected_boot_old=$5 expected_boot_new=$6
    local expected_cmd_old=$7 expected_cmd_new=$8 expected_bat_old=$9 expected_bat_new=${10}
    local expected_keeper_hash=${11} expected_service_hash=${12} expected_keeper_config_hash=${13} expected_eeprom_hash=${14}
    local expected_eeprom_current_timeout=${15} expected_eeprom_timeout=${16} expected_eeprom_apply_required=${17}
    local plan_dir backup_dir timestamp eeprom_committed=0 boot_rw=0 failure_reason=''
    local old_keeper_hash=absent old_service_hash=absent old_live_config_hash=absent

    plan_dir=$(mktemp -d /tmp/autopioverclock-watchdog-apply.XXXXXX) || {
        emit_result PREFLIGHT_FAILURE 'Could not create the Batocera watchdog staging directory.'
        return 1
    }
    APO_WATCHDOG_APPLY_PLAN_DIR=$plan_dir
    APO_WATCHDOG_APPLY_BOOT_RW=0
    trap watchdog_apply_exit_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    if ! plan_values "$keeper_source" "$service_source" "$run_id" "$plan_dir"; then
        rm -rf -- "$plan_dir"
        emit_result PREFLIGHT_FAILURE 'Batocera watchdog state changed or no longer passes installation preflight.'
        return 1
    fi
    if [[ $PLAN_TARGET != "$expected_target" || $PLAN_BOOT_OLD_HASH != "$expected_boot_old" || $PLAN_BOOT_NEW_HASH != "$expected_boot_new" ||
          $PLAN_CMDLINE_OLD_HASH != "$expected_cmd_old" || $PLAN_CMDLINE_NEW_HASH != "$expected_cmd_new" ||
          $PLAN_BATOCERA_OLD_HASH != "$expected_bat_old" || $PLAN_BATOCERA_NEW_HASH != "$expected_bat_new" ||
          $PLAN_KEEPER_HASH != "$expected_keeper_hash" || $PLAN_SERVICE_HASH != "$expected_service_hash" ||
          $PLAN_KEEPER_CONFIG_HASH != "$expected_keeper_config_hash" || $PLAN_EEPROM_NEW_HASH != "$expected_eeprom_hash" ||
          $PLAN_EEPROM_CURRENT_TIMEOUT != "$expected_eeprom_current_timeout" ||
          $PLAN_EEPROM_EFFECTIVE_TIMEOUT != "$expected_eeprom_timeout" ||
          $PLAN_EEPROM_APPLY_REQUIRED != "$expected_eeprom_apply_required" ]]; then
        rm -rf -- "$plan_dir"
        emit_result RECOVERY_FAILURE 'Batocera watchdog plan evidence changed before the mutation boundary.'
        return 1
    fi

    mkdir -p -- "$BACKUP_ROOT" "$LIVE_ROOT" "$(dirname "$LIVE_SERVICE")" || {
        rm -rf -- "$plan_dir"; emit_result PREFLIGHT_FAILURE 'Could not create Batocera watchdog directories.'; return 1;
    }
    timestamp=$(date -u '+%Y%m%dT%H%M%SZ') || {
        rm -rf -- "$plan_dir"; emit_result PREFLIGHT_FAILURE 'Could not timestamp the Batocera watchdog backup.'; return 1;
    }
    backup_dir=$(mktemp -d "$BACKUP_ROOT/watchdog-${timestamp}-${run_id}.XXXXXX") || {
        rm -rf -- "$plan_dir"; emit_result PREFLIGHT_FAILURE 'Could not reserve a no-clobber watchdog backup directory.'; return 1;
    }
    chmod 700 "$backup_dir" || failure_reason='Could not protect the watchdog backup directory.'
    [[ -n $failure_reason ]] || backup_file "$BOOT_CONFIG" "$backup_dir/config.txt" || failure_reason='Could not back up the permanent boot config.'
    [[ -n $failure_reason ]] || backup_file "$CMDLINE_FILE" "$backup_dir/cmdline.txt" || failure_reason='Could not back up the kernel command line.'
    [[ -n $failure_reason ]] || backup_file "$BATOCERA_CONFIG" "$backup_dir/batocera.conf" || failure_reason='Could not back up batocera.conf.'
    [[ -n $failure_reason ]] || backup_file "$LIVE_KEEPER" "$backup_dir/watchdog_keeper.py" || failure_reason='Could not back up the existing keeper.'
    [[ -n $failure_reason ]] || backup_file "$LIVE_SERVICE" "$backup_dir/AutoPiOverclockWatchdog" || failure_reason='Could not back up the existing service.'
    [[ -n $failure_reason ]] || backup_file "$LIVE_CONFIG" "$backup_dir/watchdog.conf" || failure_reason='Could not back up the existing watchdog config.'
    [[ -n $failure_reason ]] || cp -a -- "$plan_dir/eeprom-current" "$backup_dir/eeprom.conf" || failure_reason='Could not back up the EEPROM config.'

    [[ -e $LIVE_KEEPER ]] && old_keeper_hash=$(file_hash "$LIVE_KEEPER" || true)
    [[ -e $LIVE_SERVICE ]] && old_service_hash=$(file_hash "$LIVE_SERVICE" || true)
    [[ -e $LIVE_CONFIG ]] && old_live_config_hash=$(file_hash "$LIVE_CONFIG" || true)
    [[ -n $failure_reason ]] || atomic_install "$keeper_source" "$LIVE_KEEPER" "$old_keeper_hash" "$PLAN_KEEPER_HASH" 700 || failure_reason='Could not install the watchdog keeper.'
    [[ -n $failure_reason ]] || atomic_install "$service_source" "$LIVE_SERVICE" "$old_service_hash" "$PLAN_SERVICE_HASH" 755 || failure_reason='Could not install the Batocera watchdog service.'
    [[ -n $failure_reason ]] || atomic_install "$plan_dir/watchdog.conf" "$LIVE_CONFIG" "$old_live_config_hash" "$PLAN_KEEPER_CONFIG_HASH" 600 || failure_reason='Could not install the watchdog configuration.'
    [[ -n $failure_reason ]] || atomic_install "$plan_dir/batocera.conf" "$BATOCERA_CONFIG" "$PLAN_BATOCERA_OLD_HASH" "$PLAN_BATOCERA_NEW_HASH" 644 || failure_reason='Could not enable the watchdog service in batocera.conf.'

    if [[ -z $failure_reason ]]; then
        if remount_boot rw; then
            boot_rw=1
            APO_WATCHDOG_APPLY_BOOT_RW=1
        else
            failure_reason='Could not remount /boot read-write for watchdog installation.'
        fi
    fi
    [[ -n $failure_reason ]] || atomic_install "$plan_dir/config.txt" "$BOOT_CONFIG" "$PLAN_BOOT_OLD_HASH" "$PLAN_BOOT_NEW_HASH" 644 || failure_reason='Could not install the kernel watchdog handoff config.'
    [[ -n $failure_reason ]] || atomic_install "$plan_dir/cmdline.txt" "$CMDLINE_FILE" "$PLAN_CMDLINE_OLD_HASH" "$PLAN_CMDLINE_NEW_HASH" 644 || failure_reason='Could not install watchdog.open_timeout.'
    if [[ -z $failure_reason && $PLAN_EEPROM_APPLY_REQUIRED == 1 ]]; then
        eeprom_committed=1
        apply_eeprom_plan "$plan_dir/eeprom-new" "$PLAN_EEPROM_APPLY_REQUIRED" "$backup_dir/eeprom-apply.log" ||
            failure_reason="EEPROM watchdog scheduling failed after the no-rollback boundary; diagnostics were retained in $backup_dir/eeprom-apply.log."
    fi
    if (( boot_rw == 1 )); then
        if remount_boot ro; then
            boot_rw=0
            APO_WATCHDOG_APPLY_BOOT_RW=0
        else
            failure_reason=${failure_reason:+$failure_reason }'/boot could not be restored read-only.'
        fi
    fi

    if [[ -n $failure_reason && $eeprom_committed == 0 ]]; then
        restore_file "$backup_dir/batocera.conf" "$BATOCERA_CONFIG" 644 || failure_reason="$failure_reason batocera.conf rollback failed."
        restore_file "$backup_dir/watchdog_keeper.py" "$LIVE_KEEPER" 700 || failure_reason="$failure_reason keeper rollback failed."
        restore_file "$backup_dir/AutoPiOverclockWatchdog" "$LIVE_SERVICE" 755 || failure_reason="$failure_reason service rollback failed."
        restore_file "$backup_dir/watchdog.conf" "$LIVE_CONFIG" 600 || failure_reason="$failure_reason watchdog-config rollback failed."
        if remount_boot rw; then
            boot_rw=1
            APO_WATCHDOG_APPLY_BOOT_RW=1
            restore_file "$backup_dir/config.txt" "$BOOT_CONFIG" 644 || failure_reason="$failure_reason boot-config rollback failed."
            restore_file "$backup_dir/cmdline.txt" "$CMDLINE_FILE" 644 || failure_reason="$failure_reason cmdline rollback failed."
            if remount_boot ro; then
                boot_rw=0
                APO_WATCHDOG_APPLY_BOOT_RW=0
            else
                failure_reason="$failure_reason /boot rollback remount failed."
            fi
        else
            failure_reason="$failure_reason /boot could not be remounted for rollback."
        fi
    fi
    rm -rf -- "$plan_dir"
    APO_WATCHDOG_APPLY_PLAN_DIR=''
    if [[ -n $failure_reason ]]; then
        emit_data WATCHDOG_CONFIG_BACKUP "$backup_dir"
        emit_result RECOVERY_FAILURE "$failure_reason"
        return 1
    fi
    boot_is_read_only || { emit_result RECOVERY_FAILURE 'Watchdog installation completed but /boot is not read-only.'; return 1; }
    sync || { emit_result RECOVERY_FAILURE 'Could not durably sync the Batocera watchdog installation.'; return 1; }
    watchdog_apply_clear_exit_cleanup
    emit_data WATCHDOG_CONFIG_BACKUP "$backup_dir"
    emit_data WATCHDOG_REPAIR_NEW_HASH "$PLAN_BOOT_NEW_HASH"
    emit_data WATCHDOG_REPAIR_TARGET "$PLAN_TARGET"
    emit_result PASS "Batocera watchdog installed for default gateway $PLAN_TARGET; reboot required for activation."
}

main() {
    local action=${1:-}
    shift || true
    case $action in
        plan)
            [[ $# == 3 ]] || { emit_result PREFLIGHT_FAILURE 'Batocera watchdog plan received invalid arguments.'; return 2; }
            plan "$@"
            ;;
        apply)
            [[ $# == 17 ]] || { emit_result PREFLIGHT_FAILURE 'Batocera watchdog apply received invalid arguments.'; return 2; }
            apply_plan "$@"
            ;;
        *) emit_result PREFLIGHT_FAILURE 'Batocera watchdog installer action is required.'; return 2 ;;
    esac
}

if [[ ${APO_WATCHDOG_INSTALLER_LIBRARY_ONLY:-0} != 1 ]]; then main "$@"; fi
