#!/usr/bin/env bash
# Install the project-owned Debian network watchdog with hash-bound planning.
set -u -o pipefail
umask 077

readonly MANAGED_MARKER='AUTOPIOVERCLOCK MANAGED DEBIAN NETWORK WATCHDOG'
readonly LIVE_ROOT=/var/lib/autopioverclock/network-watchdog
readonly LIVE_CONFIG=${LIVE_ROOT}/watchdog.conf
readonly LIVE_KEEPER=/usr/local/lib/autopioverclock/network-watchdog-keeper.py
readonly LIVE_SERVICE=/etc/systemd/system/autopioverclock-network-watchdog.service
readonly SERVICE_NAME=autopioverclock-network-watchdog.service
readonly BACKUP_ROOT=/var/lib/autopioverclock/backups
readonly PING_TIMEOUT=2
readonly CHECK_INTERVAL=10
readonly STARTUP_GRACE=180
readonly FAILURE_WINDOW=180
readonly MAX_REBOOTS=3
readonly REBOOT_WINDOW=1800

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

configured_target() {
    local target count
    regular_file "$LIVE_CONFIG" || return 1
    grep -Fq "$MANAGED_MARKER" "$LIVE_CONFIG" || return 1
    count=$(grep -Ec '^[[:space:]]*TARGET[[:space:]]*=' "$LIVE_CONFIG" 2>/dev/null || true)
    [[ $count == 1 ]] || return 1
    target=$(awk -F= '/^[[:space:]]*TARGET[[:space:]]*=/ {value=$2; gsub(/[[:space:]]/, "", value); print value}' "$LIVE_CONFIG")
    valid_ipv4 "$target" || return 1
    printf '%s' "$target"
}

legacy_watchdog_target() {
    local target count
    [[ -f /etc/watchdog.conf && ! -L /etc/watchdog.conf ]] || return 1
    count=$(awk -F= '
        /^[[:space:]]*#/ {next}
        /^[[:space:]]*ping[[:space:]]*=/ {
            value=$2; sub(/[[:space:]]*#.*/, "", value); gsub(/[[:space:]]/, "", value)
            if (value != "") {count++; selected=value}
        }
        END {print count+0}
    ' /etc/watchdog.conf)
    [[ $count == 1 ]] || return 1
    target=$(awk -F= '
        /^[[:space:]]*#/ {next}
        /^[[:space:]]*ping[[:space:]]*=/ {
            value=$2; sub(/[[:space:]]*#.*/, "", value); gsub(/[[:space:]]/, "", value)
            if (value != "") print value
        }
    ' /etc/watchdog.conf)
    valid_ipv4 "$target" || return 1
    printf '%s' "$target"
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

select_target() {
    configured_target || default_gateway
}

render_config() {
    local destination=$1 target=$2 run_id=$3
    valid_ipv4 "$target" && safe_run_id "$run_id" || return 1
    {
        printf '# %s\n' "$MANAGED_MARKER"
        printf 'RUN_ID=%s\n' "$run_id"
        printf 'TARGET=%s\n' "$target"
        printf 'PING_TIMEOUT_SECONDS=%s\n' "$PING_TIMEOUT"
        printf 'CHECK_INTERVAL_SECONDS=%s\n' "$CHECK_INTERVAL"
        printf 'STARTUP_GRACE_SECONDS=%s\n' "$STARTUP_GRACE"
        printf 'FAILURE_WINDOW_SECONDS=%s\n' "$FAILURE_WINDOW"
        printf 'MAX_REBOOTS=%s\n' "$MAX_REBOOTS"
        printf 'REBOOT_WINDOW_SECONDS=%s\n' "$REBOOT_WINDOW"
    } >"$destination"
}

preflight() {
    local keeper_source=$1 service_source=$2 run_id=$3
    [[ $(id -u) == 0 ]] || return 1
    safe_run_id "$run_id" || return 1
    regular_file "$keeper_source" && regular_file "$service_source" || return 1
    grep -Fq "$MANAGED_MARKER" "$keeper_source" && grep -Fq "$MANAGED_MARKER" "$service_source" || return 1
    managed_or_absent "$LIVE_KEEPER" && managed_or_absent "$LIVE_SERVICE" && managed_or_absent "$LIVE_CONFIG" || return 1
    for required in awk base64 chmod date grep ip install mkdir mktemp mv ping rm sha256sum systemctl sync; do
        command -v "$required" >/dev/null 2>&1 || return 1
    done
    [[ -x /usr/bin/python3 ]]
}

cmd_plan() {
    local keeper_source=${1:-} service_source=${2:-} run_id=${3:-}
    local target temporary_config keeper_hash service_hash config_hash
    preflight "$keeper_source" "$service_source" "$run_id" || {
        emit_result PREFLIGHT_FAILURE 'Debian network-watchdog preflight failed.'
        return 1
    }
    target=$(select_target) || {
        emit_result PREFLIGHT_FAILURE 'Could not select exactly one managed or default-route liveness target.'
        return 1
    }
    ping -c 3 -W "$PING_TIMEOUT" "$target" >/dev/null 2>&1 || {
        emit_result PREFLIGHT_FAILURE "The selected liveness target $target is not currently reachable."
        return 1
    }
    temporary_config=$(mktemp /tmp/autopioverclock-network-watchdog.XXXXXX) || return 1
    render_config "$temporary_config" "$target" "$run_id" || { rm -f -- "$temporary_config"; return 1; }
    keeper_hash=$(file_hash "$keeper_source" || true)
    service_hash=$(file_hash "$service_source" || true)
    config_hash=$(file_hash "$temporary_config" || true)
    rm -f -- "$temporary_config"
    valid_hash "$keeper_hash" && valid_hash "$service_hash" && valid_hash "$config_hash" || {
        emit_result PREFLIGHT_FAILURE 'Could not hash all Debian network-watchdog assets.'
        return 1
    }
    emit_data NETWORK_WATCHDOG_TARGET "$target"
    emit_data NETWORK_WATCHDOG_KEEPER_HASH "$keeper_hash"
    emit_data NETWORK_WATCHDOG_SERVICE_HASH "$service_hash"
    emit_data NETWORK_WATCHDOG_CONFIG_HASH "$config_hash"
    emit_data NETWORK_WATCHDOG_OLD_KEEPER_HASH "$(path_hash "$LIVE_KEEPER")"
    emit_data NETWORK_WATCHDOG_OLD_SERVICE_HASH "$(path_hash "$LIVE_SERVICE")"
    emit_data NETWORK_WATCHDOG_OLD_CONFIG_HASH "$(path_hash "$LIVE_CONFIG")"
    emit_data NETWORK_WATCHDOG_OLD_SERVICE_ENABLED "$(systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null && printf 1 || printf 0)"
    emit_data NETWORK_WATCHDOG_OLD_SERVICE_ACTIVE "$(systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null && printf 1 || printf 0)"
    emit_result PASS "Debian network-watchdog installation is ready for liveness target $target."
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
    local source=$1 destination=$2 mode=$3 expected_hash=$4 expected_current_hash=$5 temporary current_hash
    [[ $(file_hash "$source" || true) == "$expected_hash" ]] || return 1
    current_hash=$(path_hash "$destination")
    [[ $current_hash == "$expected_current_hash" ]] || return 1
    mkdir -p -- "${destination%/*}" || return 1
    temporary=$(mktemp "${destination}.new.XXXXXX") || return 1
    install -m "$mode" "$source" "$temporary" || { rm -f -- "$temporary"; return 1; }
    [[ $(file_hash "$temporary" || true) == "$expected_hash" ]] || { rm -f -- "$temporary"; return 1; }
    current_hash=$(path_hash "$destination")
    [[ $current_hash == "$expected_current_hash" ]] || { rm -f -- "$temporary"; return 1; }
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
        rm -f -- "$destination"
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

backup_for_run() {
    local run_id=$1 candidate
    local -a matches=()
    safe_run_id "$run_id" || return 2
    shopt -s nullglob
    for candidate in "$BACKUP_ROOT"/network-watchdog-[0-9]*-"$run_id".*; do
        [[ -d $candidate && ! -L $candidate ]] && matches+=("$candidate")
    done
    shopt -u nullglob
    (( ${#matches[@]} == 0 )) && return 1
    (( ${#matches[@]} == 1 )) || return 2
    printf '%s' "${matches[0]}"
}

cmd_apply() {
    local keeper_source=${1:-} service_source=${2:-} run_id=${3:-} target=${4:-}
    local keeper_hash=${5:-} service_hash=${6:-} config_hash=${7:-}
    local old_keeper_hash=${8:-} old_service_hash=${9:-} old_config_hash=${10:-}
    local old_enabled=${11:-} old_active=${12:-}
    local temporary_config backup_dir='' backup_rc current_keeper_hash current_service_hash current_config_hash failure_reason=''
    preflight "$keeper_source" "$service_source" "$run_id" || {
        emit_result PREFLIGHT_FAILURE 'Debian network-watchdog apply preflight failed.'
        return 1
    }
    valid_ipv4 "$target" && valid_hash "$keeper_hash" && valid_hash "$service_hash" && valid_hash "$config_hash" &&
        valid_old_hash "$old_keeper_hash" && valid_old_hash "$old_service_hash" && valid_old_hash "$old_config_hash" &&
        valid_bit "$old_enabled" && valid_bit "$old_active" || {
        emit_result PREFLIGHT_FAILURE 'Debian network-watchdog apply evidence is malformed.'
        return 1
    }
    [[ $(select_target) == "$target" && $(file_hash "$keeper_source" || true) == "$keeper_hash" &&
       $(file_hash "$service_source" || true) == "$service_hash" ]] || {
        emit_result PREFLIGHT_FAILURE 'Debian network-watchdog source assets or liveness target changed after planning.'
        return 1
    }
    ping -c 3 -W "$PING_TIMEOUT" "$target" >/dev/null 2>&1 || {
        emit_result PREFLIGHT_FAILURE "The selected liveness target $target became unreachable before installation."
        return 1
    }
    temporary_config=$(mktemp /tmp/autopioverclock-network-watchdog.XXXXXX) || return 1
    render_config "$temporary_config" "$target" "$run_id" || { rm -f -- "$temporary_config"; return 1; }
    [[ $(file_hash "$temporary_config" || true) == "$config_hash" ]] || {
        rm -f -- "$temporary_config"
        emit_result PREFLIGHT_FAILURE 'Rendered Debian network-watchdog config no longer matches its plan.'
        return 1
    }
    current_keeper_hash=$(path_hash "$LIVE_KEEPER")
    current_service_hash=$(path_hash "$LIVE_SERVICE")
    current_config_hash=$(path_hash "$LIVE_CONFIG")
    if backup_dir=$(backup_for_run "$run_id"); then
        backup_rc=0
    else
        backup_rc=$?
        backup_dir=''
    fi
    (( backup_rc != 2 )) || failure_reason='Multiple backup directories claim this network-watchdog run.'
    if [[ -z $failure_reason && -n $backup_dir ]]; then
        backup_path_valid "$backup_dir/keeper.py" "$old_keeper_hash" &&
            backup_path_valid "$backup_dir/service" "$old_service_hash" &&
            backup_path_valid "$backup_dir/watchdog.conf" "$old_config_hash" ||
            failure_reason='The existing network-watchdog backup does not match the checkpointed prior files.'
    fi
    if [[ -z $failure_reason && $current_keeper_hash == "$keeper_hash" &&
          $current_service_hash == "$service_hash" && $current_config_hash == "$config_hash" ]]; then
        [[ -n $backup_dir ]] || failure_reason='Installed network-watchdog files exist without their run backup.'
        [[ -n $failure_reason ]] || grep -Fqx "RUN_ID=$run_id" "$LIVE_CONFIG" || failure_reason='Installed network-watchdog ownership does not match this run.'
        [[ -n $failure_reason ]] || systemctl daemon-reload || failure_reason='systemd daemon-reload failed during network-watchdog reconciliation.'
        [[ -n $failure_reason ]] || systemctl enable "$SERVICE_NAME" || failure_reason='Could not enable the reconciled network-watchdog service.'
        [[ -n $failure_reason ]] || systemctl restart "$SERVICE_NAME" || failure_reason='Could not restart the reconciled network-watchdog service.'
        [[ -n $failure_reason ]] || systemctl is-active --quiet "$SERVICE_NAME" || failure_reason='The reconciled network-watchdog service is not active.'
        if [[ -z $failure_reason ]]; then
            emit_data NETWORK_WATCHDOG_BACKUP "$backup_dir"
            emit_data NETWORK_WATCHDOG_TARGET "$target"
            emit_data NETWORK_WATCHDOG_CONFIG_HASH "$config_hash"
            emit_result PASS "Reconciled the completed Debian network-watchdog installation for liveness target $target."
            return 0
        fi
    elif [[ -z $failure_reason && -n $backup_dir ]]; then
        [[ ( $current_keeper_hash == "$old_keeper_hash" || $current_keeper_hash == "$keeper_hash" ) &&
           ( $current_service_hash == "$old_service_hash" || $current_service_hash == "$service_hash" ) &&
           ( $current_config_hash == "$old_config_hash" || $current_config_hash == "$config_hash" ) ]] ||
            failure_reason='Interrupted network-watchdog files do not match either side of the checkpoint.'
        if [[ -z $failure_reason ]]; then
            systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
            restore_path "$backup_dir/keeper.py" "$LIVE_KEEPER" "$old_keeper_hash" "$keeper_hash" 755 || failure_reason='Could not restore the prior keeper before retry.'
            [[ -n $failure_reason ]] || restore_path "$backup_dir/service" "$LIVE_SERVICE" "$old_service_hash" "$service_hash" 644 || failure_reason='Could not restore the prior service before retry.'
            [[ -n $failure_reason ]] || restore_path "$backup_dir/watchdog.conf" "$LIVE_CONFIG" "$old_config_hash" "$config_hash" 600 || failure_reason='Could not restore the prior config before retry.'
            [[ -n $failure_reason ]] || systemctl daemon-reload || failure_reason='systemd daemon-reload failed before network-watchdog retry.'
            if [[ -z $failure_reason && $old_enabled == 1 ]]; then systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || failure_reason='Could not restore prior enablement before retry.'; fi
            if [[ -z $failure_reason && $old_active == 1 ]]; then systemctl start "$SERVICE_NAME" >/dev/null 2>&1 || failure_reason='Could not restore prior activation before retry.'; fi
        fi
    elif [[ -z $failure_reason ]]; then
        [[ $current_keeper_hash == "$old_keeper_hash" && $current_service_hash == "$old_service_hash" &&
           $current_config_hash == "$old_config_hash" ]] || failure_reason='Debian network-watchdog inputs changed after planning.'
        [[ -n $failure_reason ]] || mkdir -p -- "$BACKUP_ROOT" "$LIVE_ROOT" "${LIVE_KEEPER%/*}" "${LIVE_SERVICE%/*}" || failure_reason='Could not create network-watchdog directories.'
        [[ -n $failure_reason ]] || backup_dir=$(mktemp -d "$BACKUP_ROOT/network-watchdog-$(date -u +%Y%m%dT%H%M%SZ)-${run_id}.XXXXXX") || failure_reason='Could not reserve a no-clobber network-watchdog backup directory.'
        [[ -n $failure_reason ]] || chmod 700 "$backup_dir" "$LIVE_ROOT" || failure_reason='Could not secure network-watchdog directories.'
        [[ -n $failure_reason ]] || backup_path "$LIVE_KEEPER" "$backup_dir/keeper.py" "$old_keeper_hash" || failure_reason='Could not verify the keeper backup boundary.'
        [[ -n $failure_reason ]] || backup_path "$LIVE_SERVICE" "$backup_dir/service" "$old_service_hash" || failure_reason='Could not verify the service backup boundary.'
        [[ -n $failure_reason ]] || backup_path "$LIVE_CONFIG" "$backup_dir/watchdog.conf" "$old_config_hash" || failure_reason='Could not verify the config backup boundary.'
    fi
    [[ -n $failure_reason ]] || atomic_install "$temporary_config" "$LIVE_CONFIG" 600 "$config_hash" "$old_config_hash" || failure_reason='Could not install the network-watchdog config.'
    [[ -n $failure_reason ]] || atomic_install "$keeper_source" "$LIVE_KEEPER" 755 "$keeper_hash" "$old_keeper_hash" || failure_reason='Could not install the network-watchdog keeper.'
    [[ -n $failure_reason ]] || atomic_install "$service_source" "$LIVE_SERVICE" 644 "$service_hash" "$old_service_hash" || failure_reason='Could not install the network-watchdog service.'
    rm -f -- "$temporary_config"
    [[ -n $failure_reason ]] || systemctl daemon-reload || failure_reason='systemd daemon-reload failed.'
    [[ -n $failure_reason ]] || systemctl enable "$SERVICE_NAME" || failure_reason='Could not enable the network-watchdog service.'
    [[ -n $failure_reason ]] || systemctl restart "$SERVICE_NAME" || failure_reason='Could not start the installed network-watchdog service.'
    [[ -n $failure_reason ]] || systemctl is-active --quiet "$SERVICE_NAME" || failure_reason='The network-watchdog service is not active.'
    if [[ -n $failure_reason ]]; then
        if [[ -n $backup_dir ]]; then
            systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
            restore_path "$backup_dir/keeper.py" "$LIVE_KEEPER" "$old_keeper_hash" "$keeper_hash" 755 || failure_reason+=" Keeper rollback failed."
            restore_path "$backup_dir/service" "$LIVE_SERVICE" "$old_service_hash" "$service_hash" 644 || failure_reason+=" Service rollback failed."
            restore_path "$backup_dir/watchdog.conf" "$LIVE_CONFIG" "$old_config_hash" "$config_hash" 600 || failure_reason+=" Config rollback failed."
            systemctl daemon-reload >/dev/null 2>&1 || failure_reason+=" systemd reload after rollback failed."
            if (( old_enabled == 1 )); then systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true; fi
            if (( old_active == 1 )); then systemctl start "$SERVICE_NAME" >/dev/null 2>&1 || true; fi
        fi
        emit_result PREFLIGHT_FAILURE "$failure_reason"
        return 1
    fi
    emit_data NETWORK_WATCHDOG_BACKUP "$backup_dir"
    emit_data NETWORK_WATCHDOG_TARGET "$target"
    emit_data NETWORK_WATCHDOG_CONFIG_HASH "$config_hash"
    emit_result PASS "Debian network-watchdog companion installed for liveness target $target."
}

cmd_cleanup() {
    local run_id=${1:-} backup_dir=${2:-} config_hash=${3:-} keeper_hash=${4:-} service_hash=${5:-}
    local old_keeper_hash=${6:-} old_service_hash=${7:-} old_config_hash=${8:-}
    local old_enabled=${9:-} old_active=${10:-} failure_reason='' cleanup_marker
    local current_config_hash current_keeper_hash current_service_hash expected_marker actual_marker
    safe_run_id "$run_id" && [[ $backup_dir == "$BACKUP_ROOT"/network-watchdog-[0-9]*-${run_id}.* ]] &&
        [[ -d $backup_dir && ! -L $backup_dir ]] && valid_hash "$config_hash" && valid_hash "$keeper_hash" &&
        valid_hash "$service_hash" && valid_old_hash "$old_keeper_hash" && valid_old_hash "$old_service_hash" &&
        valid_old_hash "$old_config_hash" && valid_bit "$old_enabled" && valid_bit "$old_active" || {
        emit_result RECOVERY_FAILURE 'Debian network-watchdog cleanup ownership evidence is malformed.'
        return 1
    }
    backup_path_valid "$backup_dir/keeper.py" "$old_keeper_hash" &&
        backup_path_valid "$backup_dir/service" "$old_service_hash" &&
        backup_path_valid "$backup_dir/watchdog.conf" "$old_config_hash" || {
        emit_result RECOVERY_FAILURE 'Debian network-watchdog cleanup backup evidence is invalid.'
        return 1
    }
    expected_marker=$(printf 'RUN_ID=%s\nCONFIG_SHA256=%s\nKEEPER_SHA256=%s\nSERVICE_SHA256=%s\n' \
        "$run_id" "$config_hash" "$keeper_hash" "$service_hash")
    cleanup_marker=$backup_dir/cleanup.plan
    if [[ ! -e $cleanup_marker && ! -L $cleanup_marker ]]; then
        [[ $(path_hash "$LIVE_CONFIG") == "$config_hash" && $(path_hash "$LIVE_KEEPER") == "$keeper_hash" &&
           $(path_hash "$LIVE_SERVICE") == "$service_hash" ]] && grep -Fqx "RUN_ID=$run_id" "$LIVE_CONFIG" || {
            emit_result RECOVERY_FAILURE 'Debian network-watchdog cleanup could not prove the installing run.'
            return 1
        }
        printf '%s\n' "$expected_marker" >"${cleanup_marker}.new" && chmod 600 "${cleanup_marker}.new" &&
            [[ ! -e $cleanup_marker && ! -L $cleanup_marker ]] && mv -- "${cleanup_marker}.new" "$cleanup_marker" &&
            sync "$cleanup_marker" || {
                rm -f -- "${cleanup_marker}.new"
                emit_result RECOVERY_FAILURE 'Could not checkpoint Debian network-watchdog cleanup.'
                return 1
            }
    fi
    regular_file "$cleanup_marker" || {
        emit_result RECOVERY_FAILURE 'Debian network-watchdog cleanup checkpoint is missing or unsafe.'
        return 1
    }
    actual_marker=$(<"$cleanup_marker")
    [[ $actual_marker == "$expected_marker" ]] || {
        emit_result RECOVERY_FAILURE 'Debian network-watchdog cleanup checkpoint does not match this run.'
        return 1
    }
    current_config_hash=$(path_hash "$LIVE_CONFIG")
    current_keeper_hash=$(path_hash "$LIVE_KEEPER")
    current_service_hash=$(path_hash "$LIVE_SERVICE")
    [[ ( $current_config_hash == "$config_hash" || $current_config_hash == "$old_config_hash" ) &&
       ( $current_keeper_hash == "$keeper_hash" || $current_keeper_hash == "$old_keeper_hash" ) &&
       ( $current_service_hash == "$service_hash" || $current_service_hash == "$old_service_hash" ) ]] || {
        emit_result RECOVERY_FAILURE 'Debian network-watchdog cleanup refused changed or foreign live files.'
        return 1
    }
    if [[ $current_service_hash == "$service_hash" ]]; then
        systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || failure_reason='Could not stop the run-owned network watchdog.'
    fi
    [[ -n $failure_reason ]] || restore_path "$backup_dir/keeper.py" "$LIVE_KEEPER" "$old_keeper_hash" "$keeper_hash" 755 || failure_reason='Could not restore the prior keeper path.'
    [[ -n $failure_reason ]] || restore_path "$backup_dir/service" "$LIVE_SERVICE" "$old_service_hash" "$service_hash" 644 || failure_reason='Could not restore the prior service path.'
    [[ -n $failure_reason ]] || restore_path "$backup_dir/watchdog.conf" "$LIVE_CONFIG" "$old_config_hash" "$config_hash" 600 || failure_reason='Could not restore the prior config path.'
    [[ -n $failure_reason ]] || systemctl daemon-reload || failure_reason='systemd daemon-reload failed after network-watchdog cleanup.'
    if [[ -z $failure_reason && $old_enabled == 1 ]]; then systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || failure_reason='Could not restore prior service enablement.'; fi
    if [[ -z $failure_reason && $old_active == 1 ]]; then systemctl start "$SERVICE_NAME" >/dev/null 2>&1 || failure_reason='Could not restore prior service activation.'; fi
    if [[ -n $failure_reason ]]; then
        emit_result RECOVERY_FAILURE "$failure_reason"
        return 1
    fi
    emit_result PASS 'Run-owned Debian network-watchdog companion removed; durable evidence was retained.'
}

main() {
    local command_name=${1:-}
    shift || true
    case $command_name in
        plan) cmd_plan "$@" ;;
        apply) cmd_apply "$@" ;;
        cleanup) cmd_cleanup "$@" ;;
        *) emit_result PREFLIGHT_FAILURE 'Unknown Debian network-watchdog installer command.'; return 2 ;;
    esac
}

main "$@"
