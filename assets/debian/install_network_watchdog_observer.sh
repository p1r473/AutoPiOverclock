#!/usr/bin/env bash
# Install a passive proof observer for an existing Debian watchdog daemon.
set -u -o pipefail
umask 077

readonly MANAGED_MARKER='AUTOPIOVERCLOCK MANAGED DEBIAN NETWORK WATCHDOG OBSERVER'
readonly LIVE_ROOT=/var/lib/autopioverclock/network-watchdog
readonly LIVE_CONFIG=${LIVE_ROOT}/observer.conf
readonly LIVE_OBSERVER=/usr/local/lib/autopioverclock/network-watchdog-observer.py
readonly LIVE_SERVICE=/etc/systemd/system/autopioverclock-network-watchdog-observer.service
readonly SERVICE_NAME=autopioverclock-network-watchdog-observer.service
readonly NATIVE_SERVICE=watchdog.service
readonly BACKUP_ROOT=/var/lib/autopioverclock/backups
readonly PING_TIMEOUT=2
readonly INSTALL_RECEIPT_NAME=install.receipt

NATIVE_CONFIG=''
NATIVE_BINARY=''
NATIVE_UNIT=''
NATIVE_TARGET=''
NATIVE_REPAIR_BINARY=absent
NATIVE_REPAIR_TIMEOUT=0
NATIVE_RETRY_TIMEOUT=0
NATIVE_WATCHDOG_TIMEOUT=0
NATIVE_EVIDENCE_WINDOW=300

b64() { printf '%s' "${1-}" | base64 | tr -d '\n'; }
emit_data() { printf 'APO_DATA\t%s\t%s\n' "$1" "$(b64 "${2-}")"; }
emit_result() {
    printf 'APO_RESULT_CLASS=%s\n' "$1"
    printf 'APO_RESULT_REASON_B64=%s\n' "$(b64 "$2")"
}
valid_hash() { [[ ${1-} =~ ^[0-9a-f]{64}$ ]]; }
valid_old_hash() { [[ ${1-} == absent ]] || valid_hash "${1-}"; }
valid_bit() { [[ ${1-} == 0 || ${1-} == 1 ]]; }
safe_run_id() { [[ ${1-} =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; }
regular_file() { [[ -f $1 && ! -L $1 ]]; }
file_hash() { sha256sum "$1" 2>/dev/null | awk 'NR == 1 {print $1}'; }
path_hash() { if regular_file "$1"; then file_hash "$1"; else printf absent; fi; }

valid_ipv4() {
    awk -F. '
        NF != 4 {exit 1}
        {for (i=1; i<=4; i++) if ($i !~ /^[0-9]+$/ || $i+0 > 255 || $i != $i+0) exit 1}
    ' <<<"${1-}"
}

managed_or_absent() {
    local candidate=$1
    [[ ! -L $candidate && ( ! -e $candidate || -f $candidate ) ]] || return 1
    [[ ! -e $candidate ]] || grep -Fq "$MANAGED_MARKER" "$candidate"
}

config_value() {
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

positive_or_zero() { [[ ${1-} =~ ^[0-9]+$ ]]; }

discover_native_watchdog() {
    local pid argument expect_config=0 configured_path='' repair_value='' timeout_value total_window
    systemctl is-active --quiet "$NATIVE_SERVICE" 2>/dev/null || return 1
    pid=$(systemctl show --property=MainPID --value "$NATIVE_SERVICE" 2>/dev/null || true)
    [[ $pid =~ ^[1-9][0-9]*$ && -r /proc/$pid/cmdline ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    NATIVE_BINARY=$(readlink -f -- "/proc/$pid/exe" 2>/dev/null || true)
    [[ $NATIVE_BINARY == /* && -x $NATIVE_BINARY && ! -L $NATIVE_BINARY ]] || return 1
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
    NATIVE_CONFIG=${configured_path:-/etc/watchdog.conf}
    [[ $NATIVE_CONFIG == /* ]] || return 1
    regular_file "$NATIVE_CONFIG" || return 1
    NATIVE_UNIT=$(systemctl show --property=FragmentPath --value "$NATIVE_SERVICE" 2>/dev/null || true)
    [[ $NATIVE_UNIT == /* && -f $NATIVE_UNIT ]] || return 1
    NATIVE_TARGET=$(config_value "$NATIVE_CONFIG" ping) || return 1
    valid_ipv4 "$NATIVE_TARGET" || return 1
    repair_value=$(config_value "$NATIVE_CONFIG" repair-binary 1) || return 1
    if [[ -n $repair_value ]]; then
        [[ $repair_value == /* ]] || return 1
        NATIVE_REPAIR_BINARY=$repair_value
    else
        NATIVE_REPAIR_BINARY=absent
    fi
    timeout_value=$(config_value "$NATIVE_CONFIG" repair-timeout 1) || return 1
    NATIVE_REPAIR_TIMEOUT=${timeout_value:-0}
    timeout_value=$(config_value "$NATIVE_CONFIG" retry-timeout 1) || return 1
    NATIVE_RETRY_TIMEOUT=${timeout_value:-0}
    timeout_value=$(config_value "$NATIVE_CONFIG" watchdog-timeout 1) || return 1
    NATIVE_WATCHDOG_TIMEOUT=${timeout_value:-0}
    positive_or_zero "$NATIVE_REPAIR_TIMEOUT" && positive_or_zero "$NATIVE_RETRY_TIMEOUT" &&
        positive_or_zero "$NATIVE_WATCHDOG_TIMEOUT" || return 1
    total_window=$((NATIVE_REPAIR_TIMEOUT + NATIVE_RETRY_TIMEOUT + NATIVE_WATCHDOG_TIMEOUT + 180))
    (( total_window >= 300 )) || total_window=300
    (( total_window <= 3600 )) || total_window=3600
    NATIVE_EVIDENCE_WINDOW=$total_window
}

render_config() {
    local destination=$1 run_id=$2 observer_hash=$3 service_hash=$4
    safe_run_id "$run_id" && valid_hash "$observer_hash" && valid_hash "$service_hash" || return 1
    {
        printf '# %s\n' "$MANAGED_MARKER"
        printf 'FORMAT=1\n'
        printf 'PROVIDER=debian-watchdog-observer\n'
        printf 'INSTALL_RUN_ID=%s\n' "$run_id"
        printf 'TARGET=%s\n' "$NATIVE_TARGET"
        printf 'NATIVE_SERVICE=%s\n' "$NATIVE_SERVICE"
        printf 'NATIVE_CONFIG_PATH=%s\n' "$NATIVE_CONFIG"
        printf 'NATIVE_BINARY_PATH=%s\n' "$NATIVE_BINARY"
        printf 'REPAIR_BINARY_PATH=%s\n' "$NATIVE_REPAIR_BINARY"
        printf 'REPAIR_TIMEOUT_SECONDS=%s\n' "$NATIVE_REPAIR_TIMEOUT"
        printf 'RETRY_TIMEOUT_SECONDS=%s\n' "$NATIVE_RETRY_TIMEOUT"
        printf 'WATCHDOG_TIMEOUT_SECONDS=%s\n' "$NATIVE_WATCHDOG_TIMEOUT"
        printf 'EVIDENCE_WINDOW_SECONDS=%s\n' "$NATIVE_EVIDENCE_WINDOW"
        printf 'OBSERVER_SHA256=%s\n' "$observer_hash"
        printf 'SERVICE_SHA256=%s\n' "$service_hash"
    } >"$destination"
}

preflight() {
    local observer_source=$1 service_source=$2 run_id=$3
    [[ $(id -u) == 0 ]] || return 1
    safe_run_id "$run_id" || return 1
    regular_file "$observer_source" && regular_file "$service_source" || return 1
    grep -Fq "$MANAGED_MARKER" "$observer_source" && grep -Fq "$MANAGED_MARKER" "$service_source" || return 1
    managed_or_absent "$LIVE_OBSERVER" && managed_or_absent "$LIVE_SERVICE" && managed_or_absent "$LIVE_CONFIG" || return 1
    for required in awk base64 chmod date grep install mkdir mktemp mv ping readlink rm sha256sum systemctl sync tr; do
        command -v "$required" >/dev/null 2>&1 || return 1
    done
    [[ -x /usr/bin/python3 ]] || return 1
    discover_native_watchdog
}

cmd_plan() {
    local observer_source=${1:-} service_source=${2:-} run_id=${3:-}
    local temporary_config observer_hash service_hash config_hash old_enabled=0 old_active=0
    preflight "$observer_source" "$service_source" "$run_id" || {
        emit_result PREFLIGHT_FAILURE 'No active, supported Debian watchdog daemon is available for passive observation.'
        return 1
    }
    ping -c 3 -W "$PING_TIMEOUT" "$NATIVE_TARGET" >/dev/null 2>&1 || {
        emit_result PREFLIGHT_FAILURE "The native Debian watchdog target $NATIVE_TARGET is not currently reachable."
        return 1
    }
    observer_hash=$(file_hash "$observer_source" || true)
    service_hash=$(file_hash "$service_source" || true)
    valid_hash "$observer_hash" && valid_hash "$service_hash" || return 1
    temporary_config=$(mktemp /tmp/autopioverclock-watchdog-observer.XXXXXX) || return 1
    render_config "$temporary_config" "$run_id" "$observer_hash" "$service_hash" || {
        rm -f -- "$temporary_config"
        return 1
    }
    config_hash=$(file_hash "$temporary_config" || true)
    rm -f -- "$temporary_config"
    valid_hash "$config_hash" || return 1
    systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null && old_enabled=1
    systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null && old_active=1
    emit_data NETWORK_WATCHDOG_PROVIDER debian-watchdog-observer
    emit_data NETWORK_WATCHDOG_TARGET "$NATIVE_TARGET"
    emit_data NETWORK_WATCHDOG_KEEPER_HASH "$observer_hash"
    emit_data NETWORK_WATCHDOG_SERVICE_HASH "$service_hash"
    emit_data NETWORK_WATCHDOG_CONFIG_HASH "$config_hash"
    emit_data NETWORK_WATCHDOG_OLD_KEEPER_HASH "$(path_hash "$LIVE_OBSERVER")"
    emit_data NETWORK_WATCHDOG_OLD_SERVICE_HASH "$(path_hash "$LIVE_SERVICE")"
    emit_data NETWORK_WATCHDOG_OLD_CONFIG_HASH "$(path_hash "$LIVE_CONFIG")"
    emit_data NETWORK_WATCHDOG_OLD_SERVICE_ENABLED "$old_enabled"
    emit_data NETWORK_WATCHDOG_OLD_SERVICE_ACTIVE "$old_active"
    emit_result PASS "Passive Debian watchdog observation is ready for native target $NATIVE_TARGET."
}

backup_path() {
    local source=$1 destination=$2 expected_hash=$3
    if [[ $expected_hash == absent ]]; then
        [[ ! -e $source && ! -L $source ]] || return 1
        : >"${destination}.absent"
        return
    fi
    regular_file "$source" && [[ $(file_hash "$source" || true) == "$expected_hash" ]] || return 1
    install -m 600 "$source" "$destination" || return 1
    [[ $(file_hash "$destination" || true) == "$expected_hash" ]]
}

atomic_install() {
    local source=$1 destination=$2 mode=$3 expected_hash=$4 expected_current_hash=$5 temporary
    [[ $(file_hash "$source" || true) == "$expected_hash" && $(path_hash "$destination") == "$expected_current_hash" ]] || return 1
    mkdir -p -- "${destination%/*}" || return 1
    temporary=$(mktemp "${destination}.new.XXXXXX") || return 1
    install -m "$mode" "$source" "$temporary" || { rm -f -- "$temporary"; return 1; }
    [[ $(file_hash "$temporary" || true) == "$expected_hash" && $(path_hash "$destination") == "$expected_current_hash" ]] || {
        rm -f -- "$temporary"
        return 1
    }
    mv -f -- "$temporary" "$destination" || { rm -f -- "$temporary"; return 1; }
    sync "$destination" || return 1
    [[ $(file_hash "$destination" || true) == "$expected_hash" ]]
}

restore_path() {
    local backup=$1 destination=$2 old_hash=$3 installed_hash=$4 mode=$5 current_hash
    current_hash=$(path_hash "$destination")
    [[ $current_hash == "$old_hash" ]] && return 0
    [[ $current_hash == "$installed_hash" ]] || return 1
    if [[ $old_hash == absent ]]; then
        rm -f -- "$destination" || return 1
        sync "${destination%/*}" 2>/dev/null || sync
        [[ $(path_hash "$destination") == absent ]]
        return
    fi
    atomic_install "$backup" "$destination" "$mode" "$old_hash" "$installed_hash"
}

backup_path_valid() {
    local backup=$1 expected_hash=$2
    if [[ $expected_hash == absent ]]; then
        [[ -f ${backup}.absent && ! -L ${backup}.absent ]]
    else
        regular_file "$backup" && [[ $(file_hash "$backup" || true) == "$expected_hash" ]]
    fi
}

cleanup_marker_valid_for_run() {
    local marker=$1 run_id=$2 component_key=$3
    local run_line config_line component_line service_line extra
    regular_file "$marker" || return 1
    {
        IFS= read -r run_line &&
            IFS= read -r config_line &&
            IFS= read -r component_line &&
            IFS= read -r service_line &&
            ! IFS= read -r extra
    } <"$marker" || return 1
    [[ $run_line == "RUN_ID=$run_id" &&
       $config_line =~ ^CONFIG_SHA256=[0-9a-f]{64}$ &&
       $component_line =~ ^${component_key}=[0-9a-f]{64}$ &&
       $service_line =~ ^SERVICE_SHA256=[0-9a-f]{64}$ ]]
}

archive_stale_cleanup_marker() {
    local marker=$1 run_id=$2 component_key=$3 marker_hash archive
    cleanup_marker_valid_for_run "$marker" "$run_id" "$component_key" || return 1
    marker_hash=$(file_hash "$marker")
    valid_hash "$marker_hash" || return 1
    archive=${marker}.previous-${marker_hash}
    if [[ -e $archive || -L $archive ]]; then
        regular_file "$archive" && [[ $(file_hash "$archive") == "$marker_hash" ]] || return 1
        rm -f -- "$marker" || return 1
    else
        mv -- "$marker" "$archive" || return 1
    fi
    sync "$archive" && sync "${marker%/*}"
}

write_cleanup_marker() {
    local marker=$1 expected=$2 temporary
    temporary=$(mktemp "${marker}.new.XXXXXX") || return 1
    printf '%s\n' "$expected" >"$temporary" && chmod 600 "$temporary" && sync "$temporary" || {
        rm -f -- "$temporary"
        return 1
    }
    if [[ -e $marker || -L $marker ]]; then
        rm -f -- "$temporary"
        return 1
    fi
    mv -- "$temporary" "$marker" && sync "$marker" || {
        rm -f -- "$temporary"
        return 1
    }
}

install_receipt_text() {
    local run_id=$1 config_hash=$2 observer_hash=$3 service_hash=$4
    local old_observer_hash=$5 old_service_hash=$6 old_config_hash=$7 old_enabled=$8 old_active=$9
    printf 'FORMAT=1\nPROVIDER=debian-watchdog-observer\nRUN_ID=%s\nCONFIG_SHA256=%s\nOBSERVER_SHA256=%s\nSERVICE_SHA256=%s\nOLD_OBSERVER_SHA256=%s\nOLD_SERVICE_SHA256=%s\nOLD_CONFIG_SHA256=%s\nOLD_SERVICE_ENABLED=%s\nOLD_SERVICE_ACTIVE=%s' \
        "$run_id" "$config_hash" "$observer_hash" "$service_hash" "$old_observer_hash" \
        "$old_service_hash" "$old_config_hash" "$old_enabled" "$old_active"
}

write_install_receipt() {
    local backup_dir=$1 expected=$2 receipt temporary actual
    receipt=$backup_dir/$INSTALL_RECEIPT_NAME
    if [[ -e $receipt || -L $receipt ]]; then
        regular_file "$receipt" || return 1
        actual=$(<"$receipt")
        [[ $actual == "$expected" ]]
        return
    fi
    temporary=$(mktemp "$backup_dir/${INSTALL_RECEIPT_NAME}.new.XXXXXX") || return 1
    printf '%s\n' "$expected" >"$temporary" && chmod 600 "$temporary" && sync "$temporary" || {
        rm -f -- "$temporary"
        return 1
    }
    [[ ! -e $receipt && ! -L $receipt ]] || { rm -f -- "$temporary"; return 1; }
    mv -- "$temporary" "$receipt" && sync "$receipt" && sync "$backup_dir" || {
        rm -f -- "$temporary"
        return 1
    }
}

receipt_value() {
    local receipt=$1 wanted=$2
    awk -F= -v wanted="$wanted" '
        $1 == wanted {value=substr($0, index($0, "=")+1); count++}
        END {if (count == 1 && value != "") print value; else exit 1}
    ' "$receipt"
}

load_install_receipt() {
    local receipt=$1 run_id=$2 config_hash=$3 observer_hash=$4 service_hash=$5
    local format provider receipt_run receipt_config receipt_observer receipt_service line_count
    regular_file "$receipt" || return 1
    line_count=$(awk 'END {print NR}' "$receipt")
    [[ $line_count == 11 ]] || return 1
    format=$(receipt_value "$receipt" FORMAT) || return 1
    provider=$(receipt_value "$receipt" PROVIDER) || return 1
    receipt_run=$(receipt_value "$receipt" RUN_ID) || return 1
    receipt_config=$(receipt_value "$receipt" CONFIG_SHA256) || return 1
    receipt_observer=$(receipt_value "$receipt" OBSERVER_SHA256) || return 1
    receipt_service=$(receipt_value "$receipt" SERVICE_SHA256) || return 1
    RECEIPT_OLD_KEEPER_HASH=$(receipt_value "$receipt" OLD_OBSERVER_SHA256) || return 1
    RECEIPT_OLD_SERVICE_HASH=$(receipt_value "$receipt" OLD_SERVICE_SHA256) || return 1
    RECEIPT_OLD_CONFIG_HASH=$(receipt_value "$receipt" OLD_CONFIG_SHA256) || return 1
    RECEIPT_OLD_ENABLED=$(receipt_value "$receipt" OLD_SERVICE_ENABLED) || return 1
    RECEIPT_OLD_ACTIVE=$(receipt_value "$receipt" OLD_SERVICE_ACTIVE) || return 1
    [[ $format == 1 && $provider == debian-watchdog-observer && $receipt_run == "$run_id" &&
       $receipt_config == "$config_hash" && $receipt_observer == "$observer_hash" &&
       $receipt_service == "$service_hash" ]] || return 1
    valid_old_hash "$RECEIPT_OLD_KEEPER_HASH" && valid_old_hash "$RECEIPT_OLD_SERVICE_HASH" &&
        valid_old_hash "$RECEIPT_OLD_CONFIG_HASH" && valid_bit "$RECEIPT_OLD_ENABLED" &&
        valid_bit "$RECEIPT_OLD_ACTIVE"
}

backup_for_run() {
    local run_id=$1 candidate
    local -a matches=()
    safe_run_id "$run_id" || return 2
    shopt -s nullglob
    for candidate in "$BACKUP_ROOT"/network-watchdog-observer-[0-9]*-"$run_id".*; do
        [[ -d $candidate && ! -L $candidate ]] && matches+=("$candidate")
    done
    shopt -u nullglob
    (( ${#matches[@]} == 0 )) && return 1
    (( ${#matches[@]} == 1 )) || return 2
    printf '%s' "${matches[0]}"
}

cmd_apply() {
    local observer_source=${1:-} service_source=${2:-} run_id=${3:-} target=${4:-}
    local observer_hash=${5:-} service_hash=${6:-} config_hash=${7:-}
    local old_observer_hash=${8:-} old_service_hash=${9:-} old_config_hash=${10:-}
    local old_enabled=${11:-} old_active=${12:-} temporary_config backup_dir='' backup_rc
    local current_observer_hash current_service_hash current_config_hash failure_reason='' receipt_text
    preflight "$observer_source" "$service_source" "$run_id" || {
        emit_result PREFLIGHT_FAILURE 'Debian watchdog observer apply preflight failed.'
        return 1
    }
    valid_ipv4 "$target" && valid_hash "$observer_hash" && valid_hash "$service_hash" && valid_hash "$config_hash" &&
        valid_old_hash "$old_observer_hash" && valid_old_hash "$old_service_hash" && valid_old_hash "$old_config_hash" &&
        valid_bit "$old_enabled" && valid_bit "$old_active" || {
        emit_result PREFLIGHT_FAILURE 'Debian watchdog observer plan evidence is malformed.'
        return 1
    }
    [[ $NATIVE_TARGET == "$target" && $(file_hash "$observer_source" || true) == "$observer_hash" &&
       $(file_hash "$service_source" || true) == "$service_hash" ]] || {
        emit_result PREFLIGHT_FAILURE 'Debian watchdog observer source assets or native liveness target changed after planning.'
        return 1
    }
    temporary_config=$(mktemp /tmp/autopioverclock-watchdog-observer.XXXXXX) || return 1
    render_config "$temporary_config" "$run_id" "$observer_hash" "$service_hash" || {
        rm -f -- "$temporary_config"
        return 1
    }
    [[ $(file_hash "$temporary_config" || true) == "$config_hash" ]] || {
        rm -f -- "$temporary_config"
        emit_result PREFLIGHT_FAILURE 'Rendered observer configuration no longer matches its plan.'
        return 1
    }
    current_observer_hash=$(path_hash "$LIVE_OBSERVER")
    current_service_hash=$(path_hash "$LIVE_SERVICE")
    current_config_hash=$(path_hash "$LIVE_CONFIG")
    if backup_dir=$(backup_for_run "$run_id"); then
        backup_rc=0
    else
        backup_rc=$?
        backup_dir=''
    fi
    (( backup_rc != 2 )) || failure_reason='Multiple backup directories claim this watchdog-observer run.'
    if [[ -z $failure_reason && -n $backup_dir ]]; then
        backup_path_valid "$backup_dir/observer.py" "$old_observer_hash" &&
            backup_path_valid "$backup_dir/service" "$old_service_hash" &&
            backup_path_valid "$backup_dir/observer.conf" "$old_config_hash" ||
            failure_reason='The existing watchdog-observer backup does not match the checkpointed prior files.'
    fi
    if [[ -z $failure_reason && $current_observer_hash == "$observer_hash" &&
          $current_service_hash == "$service_hash" && $current_config_hash == "$config_hash" ]]; then
        [[ -n $backup_dir ]] || failure_reason='Installed watchdog-observer files exist without their run backup.'
        [[ -n $failure_reason ]] || grep -Fqx "INSTALL_RUN_ID=$run_id" "$LIVE_CONFIG" || failure_reason='Installed watchdog-observer ownership does not match this run.'
        if [[ -z $failure_reason ]]; then
            receipt_text=$(install_receipt_text "$run_id" "$config_hash" "$observer_hash" "$service_hash" \
                "$old_observer_hash" "$old_service_hash" "$old_config_hash" "$old_enabled" "$old_active")
            write_install_receipt "$backup_dir" "$receipt_text" || failure_reason='Could not preserve the reconciled watchdog observer installation receipt.'
        fi
        [[ -n $failure_reason ]] || systemctl daemon-reload || failure_reason='systemd daemon-reload failed during watchdog-observer reconciliation.'
        [[ -n $failure_reason ]] || systemctl enable "$SERVICE_NAME" || failure_reason='Could not enable the reconciled watchdog observer.'
        [[ -n $failure_reason ]] || systemctl restart "$SERVICE_NAME" || failure_reason='Could not restart the reconciled watchdog observer.'
        [[ -n $failure_reason ]] || systemctl is-active --quiet "$SERVICE_NAME" || failure_reason='The reconciled watchdog observer is not active.'
        [[ -n $failure_reason ]] || systemctl is-active --quiet "$NATIVE_SERVICE" || failure_reason='The native Debian watchdog is not active during observer reconciliation.'
        if [[ -z $failure_reason ]]; then
            emit_data NETWORK_WATCHDOG_PROVIDER debian-watchdog-observer
            emit_data NETWORK_WATCHDOG_BACKUP "$backup_dir"
            emit_data NETWORK_WATCHDOG_TARGET "$target"
            emit_data NETWORK_WATCHDOG_CONFIG_HASH "$config_hash"
            emit_result PASS "Reconciled the completed Debian watchdog-observer installation for native target $target."
            return 0
        fi
    elif [[ -z $failure_reason && -n $backup_dir ]]; then
        [[ ( $current_observer_hash == "$old_observer_hash" || $current_observer_hash == "$observer_hash" ) &&
           ( $current_service_hash == "$old_service_hash" || $current_service_hash == "$service_hash" ) &&
           ( $current_config_hash == "$old_config_hash" || $current_config_hash == "$config_hash" ) ]] ||
            failure_reason='Interrupted watchdog-observer files do not match either side of the checkpoint.'
        if [[ -z $failure_reason ]]; then
            systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
            restore_path "$backup_dir/observer.py" "$LIVE_OBSERVER" "$old_observer_hash" "$observer_hash" 755 || failure_reason='Could not restore the prior observer before retry.'
            [[ -n $failure_reason ]] || restore_path "$backup_dir/service" "$LIVE_SERVICE" "$old_service_hash" "$service_hash" 644 || failure_reason='Could not restore the prior observer service before retry.'
            [[ -n $failure_reason ]] || restore_path "$backup_dir/observer.conf" "$LIVE_CONFIG" "$old_config_hash" "$config_hash" 600 || failure_reason='Could not restore the prior observer config before retry.'
            [[ -n $failure_reason ]] || systemctl daemon-reload || failure_reason='systemd daemon-reload failed before watchdog-observer retry.'
            if [[ -z $failure_reason && $old_enabled == 1 ]]; then systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || failure_reason='Could not restore prior observer enablement before retry.'; fi
            if [[ -z $failure_reason && $old_active == 1 ]]; then systemctl start "$SERVICE_NAME" >/dev/null 2>&1 || failure_reason='Could not restore prior observer activation before retry.'; fi
        fi
    elif [[ -z $failure_reason ]]; then
        [[ $current_observer_hash == "$old_observer_hash" && $current_service_hash == "$old_service_hash" &&
           $current_config_hash == "$old_config_hash" ]] || failure_reason='Debian watchdog observer inputs changed after planning.'
        [[ -n $failure_reason ]] || mkdir -p -- "$BACKUP_ROOT" "$LIVE_ROOT" "${LIVE_OBSERVER%/*}" "${LIVE_SERVICE%/*}" || failure_reason='Could not create observer directories.'
        [[ -n $failure_reason ]] || backup_dir=$(mktemp -d "$BACKUP_ROOT/network-watchdog-observer-$(date -u +%Y%m%dT%H%M%SZ)-${run_id}.XXXXXX") || failure_reason='Could not reserve a no-clobber observer backup directory.'
        [[ -n $failure_reason ]] || chmod 700 "$backup_dir" "$LIVE_ROOT" || failure_reason='Could not secure observer directories.'
        [[ -n $failure_reason ]] || backup_path "$LIVE_OBSERVER" "$backup_dir/observer.py" "$old_observer_hash" || failure_reason='Could not verify the observer backup boundary.'
        [[ -n $failure_reason ]] || backup_path "$LIVE_SERVICE" "$backup_dir/service" "$old_service_hash" || failure_reason='Could not verify the observer-service backup boundary.'
        [[ -n $failure_reason ]] || backup_path "$LIVE_CONFIG" "$backup_dir/observer.conf" "$old_config_hash" || failure_reason='Could not verify the observer-config backup boundary.'
    fi
    if [[ -z $failure_reason ]]; then
        receipt_text=$(install_receipt_text "$run_id" "$config_hash" "$observer_hash" "$service_hash" \
            "$old_observer_hash" "$old_service_hash" "$old_config_hash" "$old_enabled" "$old_active")
        write_install_receipt "$backup_dir" "$receipt_text" || failure_reason='Could not preserve the watchdog observer installation receipt.'
    fi
    [[ -n $failure_reason ]] || atomic_install "$temporary_config" "$LIVE_CONFIG" 600 "$config_hash" "$old_config_hash" || failure_reason='Could not install the watchdog observer config.'
    [[ -n $failure_reason ]] || atomic_install "$observer_source" "$LIVE_OBSERVER" 755 "$observer_hash" "$old_observer_hash" || failure_reason='Could not install the watchdog observer.'
    [[ -n $failure_reason ]] || atomic_install "$service_source" "$LIVE_SERVICE" 644 "$service_hash" "$old_service_hash" || failure_reason='Could not install the watchdog observer service.'
    rm -f -- "$temporary_config"
    [[ -n $failure_reason ]] || systemctl daemon-reload || failure_reason='systemd daemon-reload failed.'
    [[ -n $failure_reason ]] || systemctl enable "$SERVICE_NAME" || failure_reason='Could not enable the watchdog observer.'
    [[ -n $failure_reason ]] || systemctl restart "$SERVICE_NAME" || failure_reason='Could not start the installed watchdog observer.'
    [[ -n $failure_reason ]] || systemctl is-active --quiet "$SERVICE_NAME" || failure_reason='The watchdog observer is not active.'
    [[ -n $failure_reason ]] || systemctl is-active --quiet "$NATIVE_SERVICE" || failure_reason='The native Debian watchdog stopped during observer installation.'
    if [[ -n $failure_reason ]]; then
        if [[ -n $backup_dir ]]; then
            systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
            restore_path "$backup_dir/observer.py" "$LIVE_OBSERVER" "$old_observer_hash" "$observer_hash" 755 || failure_reason+=" Observer rollback failed."
            restore_path "$backup_dir/service" "$LIVE_SERVICE" "$old_service_hash" "$service_hash" 644 || failure_reason+=" Service rollback failed."
            restore_path "$backup_dir/observer.conf" "$LIVE_CONFIG" "$old_config_hash" "$config_hash" 600 || failure_reason+=" Config rollback failed."
            systemctl daemon-reload >/dev/null 2>&1 || failure_reason+=" systemd reload after rollback failed."
            if (( old_enabled == 1 )); then systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true; fi
            if (( old_active == 1 )); then systemctl start "$SERVICE_NAME" >/dev/null 2>&1 || true; fi
        fi
        emit_result PREFLIGHT_FAILURE "$failure_reason"
        return 1
    fi
    emit_data NETWORK_WATCHDOG_PROVIDER debian-watchdog-observer
    emit_data NETWORK_WATCHDOG_BACKUP "$backup_dir"
    emit_data NETWORK_WATCHDOG_TARGET "$target"
    emit_data NETWORK_WATCHDOG_CONFIG_HASH "$config_hash"
    emit_result PASS "Passive Debian watchdog observer installed for native target $target without changing the native watchdog."
}

cmd_cleanup() {
    local run_id=${1:-} backup_dir=${2:-} config_hash=${3:-} observer_hash=${4:-} service_hash=${5:-}
    local old_observer_hash=${6:-} old_service_hash=${7:-} old_config_hash=${8:-}
    local old_enabled=${9:-} old_active=${10:-} failure_reason='' cleanup_marker
    local current_config_hash current_observer_hash current_service_hash expected_marker actual_marker live_owned=0
    safe_run_id "$run_id" && [[ $backup_dir == "$BACKUP_ROOT"/network-watchdog-observer-[0-9]*-${run_id}.* ]] &&
        [[ -d $backup_dir && ! -L $backup_dir ]] && valid_hash "$config_hash" && valid_hash "$observer_hash" &&
        valid_hash "$service_hash" && valid_old_hash "$old_observer_hash" && valid_old_hash "$old_service_hash" &&
        valid_old_hash "$old_config_hash" && valid_bit "$old_enabled" && valid_bit "$old_active" || {
        emit_result RECOVERY_FAILURE 'Debian watchdog observer cleanup ownership evidence is malformed.'
        return 1
    }
    backup_path_valid "$backup_dir/observer.py" "$old_observer_hash" &&
        backup_path_valid "$backup_dir/service" "$old_service_hash" &&
        backup_path_valid "$backup_dir/observer.conf" "$old_config_hash" || {
        emit_result RECOVERY_FAILURE 'Debian watchdog observer cleanup backup evidence is invalid.'
        return 1
    }
    expected_marker=$(printf 'RUN_ID=%s\nCONFIG_SHA256=%s\nOBSERVER_SHA256=%s\nSERVICE_SHA256=%s\n' \
        "$run_id" "$config_hash" "$observer_hash" "$service_hash")
    cleanup_marker=$backup_dir/cleanup.plan
    current_config_hash=$(path_hash "$LIVE_CONFIG")
    current_observer_hash=$(path_hash "$LIVE_OBSERVER")
    current_service_hash=$(path_hash "$LIVE_SERVICE")
    if [[ $current_config_hash == "$config_hash" && $current_observer_hash == "$observer_hash" &&
          $current_service_hash == "$service_hash" ]] && grep -Fqx "INSTALL_RUN_ID=$run_id" "$LIVE_CONFIG"; then
        live_owned=1
    fi
    if [[ ! -e $cleanup_marker && ! -L $cleanup_marker ]]; then
        (( live_owned == 1 )) || {
            emit_result RECOVERY_FAILURE 'Debian watchdog observer cleanup could not prove the installing run.'
            return 1
        }
        write_cleanup_marker "$cleanup_marker" "$expected_marker" || {
                emit_result RECOVERY_FAILURE 'Could not checkpoint Debian watchdog observer cleanup.'
                return 1
            }
    fi
    regular_file "$cleanup_marker" || {
        emit_result RECOVERY_FAILURE 'Debian watchdog observer cleanup checkpoint is missing or unsafe.'
        return 1
    }
    actual_marker=$(<"$cleanup_marker")
    if [[ $actual_marker != "$expected_marker" ]]; then
        (( live_owned == 1 )) &&
            archive_stale_cleanup_marker "$cleanup_marker" "$run_id" OBSERVER_SHA256 &&
            write_cleanup_marker "$cleanup_marker" "$expected_marker" || {
                emit_result RECOVERY_FAILURE 'Debian watchdog observer cleanup checkpoint does not match this run.'
                return 1
            }
        actual_marker=$(<"$cleanup_marker")
    fi
    [[ $actual_marker == "$expected_marker" ]] || {
        emit_result RECOVERY_FAILURE 'Debian watchdog observer cleanup checkpoint does not match this run.'
        return 1
    }
    [[ ( $current_config_hash == "$config_hash" || $current_config_hash == "$old_config_hash" ) &&
       ( $current_observer_hash == "$observer_hash" || $current_observer_hash == "$old_observer_hash" ) &&
       ( $current_service_hash == "$service_hash" || $current_service_hash == "$old_service_hash" ) ]] || {
        emit_result RECOVERY_FAILURE 'Debian watchdog observer cleanup refused changed or foreign live files.'
        return 1
    }
    if [[ $current_service_hash == "$service_hash" ]]; then
        systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || failure_reason='Could not stop the run-owned watchdog observer.'
        if [[ -z $failure_reason ]] && systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
            failure_reason='The run-owned watchdog observer remained active after its stop request.'
        fi
    fi
    [[ -n $failure_reason ]] || restore_path "$backup_dir/observer.py" "$LIVE_OBSERVER" "$old_observer_hash" "$observer_hash" 755 || failure_reason='Could not restore the prior observer path.'
    [[ -n $failure_reason ]] || restore_path "$backup_dir/service" "$LIVE_SERVICE" "$old_service_hash" "$service_hash" 644 || failure_reason='Could not restore the prior observer service path.'
    [[ -n $failure_reason ]] || restore_path "$backup_dir/observer.conf" "$LIVE_CONFIG" "$old_config_hash" "$config_hash" 600 || failure_reason='Could not restore the prior observer config path.'
    [[ -n $failure_reason ]] || systemctl daemon-reload || failure_reason='systemd daemon-reload failed after observer cleanup.'
    if [[ -z $failure_reason && $old_enabled == 1 ]]; then systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || failure_reason='Could not restore the prior observer enablement.'; fi
    if [[ -z $failure_reason && $old_active == 1 ]]; then systemctl start "$SERVICE_NAME" >/dev/null 2>&1 || failure_reason='Could not restore the prior observer activation.'; fi
    if [[ -z $failure_reason && $old_enabled == 1 ]] && ! systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then failure_reason='The prior observer enablement was not restored.'; fi
    if [[ -z $failure_reason && $old_enabled == 0 ]] && systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then failure_reason='The removed observer remained enabled.'; fi
    if [[ -z $failure_reason && $old_active == 1 ]] && ! systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then failure_reason='The prior observer activation was not restored.'; fi
    if [[ -z $failure_reason && $old_active == 0 ]] && systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then failure_reason='The removed observer remained active.'; fi
    if [[ -n $failure_reason ]]; then
        emit_result RECOVERY_FAILURE "$failure_reason"
        return 1
    fi
    emit_result PASS 'Run-owned Debian watchdog observer removed; native watchdog configuration and evidence were retained.'
}

cmd_cleanup_owned() {
    local run_id=${1:-} backup_dir=${2:-} config_hash=${3:-} observer_hash=${4:-} service_hash=${5:-}
    local receipt
    local old_observer_hash old_service_hash old_config_hash old_enabled old_active
    receipt=$backup_dir/$INSTALL_RECEIPT_NAME
    safe_run_id "$run_id" && [[ $backup_dir == "$BACKUP_ROOT"/network-watchdog-observer-[0-9]*-${run_id}.* ]] &&
        [[ -d $backup_dir && ! -L $backup_dir ]] && valid_hash "$config_hash" &&
        valid_hash "$observer_hash" && valid_hash "$service_hash" || {
        emit_result RECOVERY_FAILURE 'Discovered Debian watchdog observer cleanup evidence is malformed.'
        return 1
    }
    [[ $(path_hash "$LIVE_CONFIG") == "$config_hash" && $(path_hash "$LIVE_OBSERVER") == "$observer_hash" &&
       $(path_hash "$LIVE_SERVICE") == "$service_hash" ]] && grep -Fqx "INSTALL_RUN_ID=$run_id" "$LIVE_CONFIG" || {
        emit_result RECOVERY_FAILURE 'Discovered Debian watchdog observer ownership no longer matches the live files.'
        return 1
    }
    if [[ -e $receipt || -L $receipt ]]; then
        load_install_receipt "$receipt" "$run_id" "$config_hash" "$observer_hash" "$service_hash" || {
            emit_result RECOVERY_FAILURE 'The Debian watchdog observer installation receipt is missing fields or does not match the live provider.'
            return 1
        }
        old_observer_hash=$RECEIPT_OLD_KEEPER_HASH
        old_service_hash=$RECEIPT_OLD_SERVICE_HASH
        old_config_hash=$RECEIPT_OLD_CONFIG_HASH
        old_enabled=$RECEIPT_OLD_ENABLED
        old_active=$RECEIPT_OLD_ACTIVE
    else
        for receipt in "$backup_dir/observer.py.absent" "$backup_dir/service.absent" "$backup_dir/observer.conf.absent"; do
            [[ -f $receipt && ! -L $receipt && ! -s $receipt ]] || {
                emit_result RECOVERY_FAILURE 'The state-independent observer cleanup lacks a complete installation receipt or an exact absent-path backup.'
                return 1
            }
        done
        [[ ! -e $backup_dir/observer.py && ! -L $backup_dir/observer.py &&
           ! -e $backup_dir/service && ! -L $backup_dir/service &&
           ! -e $backup_dir/observer.conf && ! -L $backup_dir/observer.conf ]] || {
            emit_result RECOVERY_FAILURE 'The absent-path observer backup conflicts with retained prior file content.'
            return 1
        }
        old_observer_hash=absent
        old_service_hash=absent
        old_config_hash=absent
        old_enabled=0
        old_active=0
    fi
    cmd_cleanup "$run_id" "$backup_dir" "$config_hash" "$observer_hash" "$service_hash" \
        "$old_observer_hash" "$old_service_hash" "$old_config_hash" "$old_enabled" "$old_active"
}

main() {
    local command_name=${1:-}
    shift || true
    case $command_name in
        plan) cmd_plan "$@" ;;
        apply) cmd_apply "$@" ;;
        cleanup) cmd_cleanup "$@" ;;
        cleanup-owned) cmd_cleanup_owned "$@" ;;
        *) emit_result PREFLIGHT_FAILURE 'Unknown Debian watchdog observer installer command.'; return 2 ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
