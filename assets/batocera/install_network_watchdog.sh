#!/usr/bin/env bash
# Install a temporary Batocera network watcher without changing the hardware watchdog.
set -u -o pipefail
umask 077

readonly MANAGED_MARKER='AUTOPIOVERCLOCK MANAGED BATOCERA NETWORK WATCHDOG'
readonly SERVICE_MARKER='AUTOPIOVERCLOCK MANAGED BATOCERA NETWORK WATCHDOG SERVICE'
readonly SERVICE_BLOCK_BEGIN='# BEGIN AUTOPIOVERCLOCK MANAGED BATOCERA NETWORK WATCHDOG SERVICE'
readonly SERVICE_BLOCK_END='# END AUTOPIOVERCLOCK MANAGED BATOCERA NETWORK WATCHDOG SERVICE'
readonly PREVIOUS_SERVICES_MARKER='# AUTOPIOVERCLOCK-NETWORK-WATCHDOG-SERVICES-PREVIOUS '
readonly SERVICE_NAME=AutoPiOverclockNetworkWatchdog
readonly LIVE_ROOT=/userdata/system/autopioverclock/network-watchdog
readonly LIVE_CONFIG=${LIVE_ROOT}/watchdog.conf
readonly LIVE_KEEPER=${LIVE_ROOT}/network_watchdog_keeper.py
readonly LIVE_SERVICE=/userdata/system/services/${SERVICE_NAME}
readonly PID_FILE=/run/autopioverclock-network-watchdog.pid
readonly BATOCERA_CONFIG=/userdata/system/batocera.conf
readonly BACKUP_ROOT=/userdata/system/autopioverclock/backups
readonly PING_TIMEOUT=2
readonly CHECK_INTERVAL=10
readonly STARTUP_GRACE=180
readonly FAILURE_WINDOW=180
readonly MAX_REBOOTS=0
readonly REBOOT_WINDOW=1800

b64() { printf '%s' "${1-}" | base64 | tr -d '\n'; }
emit_data() { printf 'APO_DATA\t%s\t%s\n' "$1" "$(b64 "${2-}")"; }
emit_result() {
    printf 'APO_RESULT_CLASS=%s\n' "$1"
    printf 'APO_RESULT_REASON_B64=%s\n' "$(b64 "$2")"
}
valid_hash() { [[ ${1-} =~ ^[0-9a-f]{64}$ ]]; }
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

watchdog_device_path() {
    local candidate
    for candidate in /dev/watchdog0 /dev/watchdog; do
        [[ -c $candidate ]] || continue
        printf '%s' "$candidate"
        return 0
    done
    return 1
}

watchdog_has_owner() {
    local device=$1 canonical_device device_id fd_path fd_target fd_id
    canonical_device=$(readlink -f -- "$device" 2>/dev/null || printf '%s' "$device")
    device_id=$(stat -Lc '%t:%T' "$device" 2>/dev/null || true)
    [[ -n $device_id ]] || return 1
    for fd_path in /proc/[0-9]*/fd/*; do
        [[ -L $fd_path ]] || continue
        fd_target=$(readlink -f -- "$fd_path" 2>/dev/null || true)
        if [[ $fd_target == "$canonical_device" ]]; then return 0; fi
        [[ -c $fd_target ]] || continue
        fd_id=$(stat -Lc '%t:%T' "$fd_target" 2>/dev/null || true)
        [[ -n $fd_id && $fd_id == "$device_id" ]] && return 0
    done
    return 1
}

service_block_absent() {
    local source=$1
    awk -v begin="$SERVICE_BLOCK_BEGIN" -v end="$SERVICE_BLOCK_END" -v previous="$PREVIOUS_SERVICES_MARKER" '
        $0 == begin || $0 == end || index($0, previous) == 1 {found=1}
        END {exit found}
    ' "$source"
}

effective_services() {
    local source=$1
    awk -F= '
        /^[[:space:]]*#/ {next}
        /^[[:space:]]*system[.]services[[:space:]]*=/ {
            value=$0
            sub(/^[^=]*=[[:space:]]*/, "", value)
            count++
        }
        END {if (count > 1) exit 1; print value}
    ' "$source"
}

render_batocera_config() {
    local source=$1 destination=$2 services token rendered=''
    local -a service_tokens=()
    service_block_absent "$source" || return 1
    services=$(effective_services "$source") || return 1
    read -r -a service_tokens <<<"$services"
    for token in "${service_tokens[@]}"; do
        [[ $token =~ ^[A-Za-z0-9._-]+$ && $token != "$SERVICE_NAME" ]] || return 1
        rendered=${rendered:+$rendered }$token
    done
    rendered=${rendered:+$rendered }$SERVICE_NAME
    awk -v previous="$PREVIOUS_SERVICES_MARKER" '
        /^[[:space:]]*system[.]services[[:space:]]*=/ {print previous $0; next}
        {print}
    ' "$source" >"$destination" || return 1
    printf '%s\nsystem.services=%s\n%s\n' "$SERVICE_BLOCK_BEGIN" "$rendered" "$SERVICE_BLOCK_END" >>"$destination"
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

service_active() {
    local pid argument keeper_found=0 config_found=0
    [[ -r $PID_FILE ]] || return 1
    pid=$(sed -n '1p' "$PID_FILE" 2>/dev/null || true)
    [[ $pid =~ ^[1-9][0-9]*$ && -r /proc/$pid/cmdline ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    while IFS= read -r argument; do
        [[ $argument == "$LIVE_KEEPER" ]] && keeper_found=1
        [[ $argument == "$LIVE_CONFIG" ]] && config_found=1
    done < <(tr '\000' '\n' <"/proc/$pid/cmdline" 2>/dev/null)
    (( keeper_found == 1 && config_found == 1 ))
}

preflight() {
    local keeper_source=$1 service_source=$2 run_id=$3 device
    [[ $(id -u) == 0 ]] || return 1
    safe_run_id "$run_id" || return 1
    regular_file "$keeper_source" && regular_file "$service_source" && regular_file "$BATOCERA_CONFIG" || return 1
    grep -Fq 'AUTOPIOVERCLOCK MANAGED' "$keeper_source" && grep -Fq "$SERVICE_MARKER" "$service_source" || return 1
    [[ ! -e $LIVE_CONFIG && ! -L $LIVE_CONFIG && ! -e $LIVE_KEEPER && ! -L $LIVE_KEEPER &&
       ! -e $LIVE_SERVICE && ! -L $LIVE_SERVICE ]] || return 1
    service_block_absent "$BATOCERA_CONFIG" || return 1
    device=$(watchdog_device_path) || return 1
    watchdog_has_owner "$device" || return 1
    for required in awk base64 chmod cp date grep id ip kill mkdir mktemp mv nohup ping readlink rm sed sha256sum sleep stat sync tr; do
        command -v "$required" >/dev/null 2>&1 || return 1
    done
    [[ -x /usr/bin/python3 ]]
}

cmd_plan() {
    local keeper_source=${1:-} service_source=${2:-} run_id=${3:-}
    local target plan_dir keeper_hash service_hash config_hash batocera_old_hash batocera_new_hash
    preflight "$keeper_source" "$service_source" "$run_id" || {
        emit_result PREFLIGHT_FAILURE 'Batocera temporary network-watchdog preflight failed; the existing hardware watchdog must remain active and project paths must be absent.'
        return 1
    }
    target=$(default_gateway) || { emit_result PREFLIGHT_FAILURE 'Could not select exactly one active IPv4 default gateway.'; return 1; }
    ping -c 3 -W "$PING_TIMEOUT" "$target" >/dev/null 2>&1 || {
        emit_result PREFLIGHT_FAILURE "The selected liveness target $target is not currently reachable."
        return 1
    }
    plan_dir=$(mktemp -d /tmp/autopioverclock-batocera-network-watchdog.XXXXXX) || return 1
    render_config "$plan_dir/watchdog.conf" "$target" "$run_id" || { rm -rf -- "$plan_dir"; return 1; }
    render_batocera_config "$BATOCERA_CONFIG" "$plan_dir/batocera.conf" || { rm -rf -- "$plan_dir"; return 1; }
    keeper_hash=$(file_hash "$keeper_source" || true)
    service_hash=$(file_hash "$service_source" || true)
    config_hash=$(file_hash "$plan_dir/watchdog.conf" || true)
    batocera_old_hash=$(file_hash "$BATOCERA_CONFIG" || true)
    batocera_new_hash=$(file_hash "$plan_dir/batocera.conf" || true)
    rm -rf -- "$plan_dir"
    valid_hash "$keeper_hash" && valid_hash "$service_hash" && valid_hash "$config_hash" &&
        valid_hash "$batocera_old_hash" && valid_hash "$batocera_new_hash" || return 1
    emit_data NETWORK_WATCHDOG_PROVIDER batocera-network-companion
    emit_data NETWORK_WATCHDOG_TARGET "$target"
    emit_data NETWORK_WATCHDOG_KEEPER_HASH "$keeper_hash"
    emit_data NETWORK_WATCHDOG_SERVICE_HASH "$service_hash"
    emit_data NETWORK_WATCHDOG_CONFIG_HASH "$config_hash"
    emit_data NETWORK_WATCHDOG_OLD_KEEPER_HASH absent
    emit_data NETWORK_WATCHDOG_OLD_SERVICE_HASH absent
    emit_data NETWORK_WATCHDOG_OLD_CONFIG_HASH absent
    emit_data NETWORK_WATCHDOG_OLD_SERVICE_ENABLED 0
    emit_data NETWORK_WATCHDOG_OLD_SERVICE_ACTIVE 0
    emit_data NETWORK_WATCHDOG_BATOCERA_OLD_HASH "$batocera_old_hash"
    emit_data NETWORK_WATCHDOG_BATOCERA_NEW_HASH "$batocera_new_hash"
    emit_result PASS "Batocera temporary network-watchdog installation is ready for liveness target $target."
}

atomic_install_absent() {
    local source=$1 destination=$2 expected_hash=$3 mode=$4 temporary
    regular_file "$source" && [[ $(file_hash "$source" || true) == "$expected_hash" ]] || return 1
    [[ ! -e $destination && ! -L $destination ]] || return 1
    mkdir -p -- "${destination%/*}" || return 1
    temporary=$(mktemp "${destination}.new.XXXXXX") || return 1
    cp -- "$source" "$temporary" || { rm -f -- "$temporary"; return 1; }
    chmod "$mode" "$temporary" || { rm -f -- "$temporary"; return 1; }
    [[ $(file_hash "$temporary" || true) == "$expected_hash" && ! -e $destination && ! -L $destination ]] || { rm -f -- "$temporary"; return 1; }
    mv -- "$temporary" "$destination" || { rm -f -- "$temporary"; return 1; }
    sync "$destination" || return 1
    [[ $(file_hash "$destination" || true) == "$expected_hash" ]]
}

atomic_replace() {
    local source=$1 destination=$2 expected_old=$3 expected_new=$4 mode=$5 temporary
    regular_file "$source" && regular_file "$destination" || return 1
    [[ $(file_hash "$source" || true) == "$expected_new" && $(file_hash "$destination" || true) == "$expected_old" ]] || return 1
    temporary=$(mktemp "${destination}.new.XXXXXX") || return 1
    cp -- "$source" "$temporary" || { rm -f -- "$temporary"; return 1; }
    chmod "$mode" "$temporary" || { rm -f -- "$temporary"; return 1; }
    [[ $(file_hash "$temporary" || true) == "$expected_new" && $(file_hash "$destination" || true) == "$expected_old" ]] || { rm -f -- "$temporary"; return 1; }
    mv -- "$temporary" "$destination" || { rm -f -- "$temporary"; return 1; }
    sync "$destination" || return 1
    [[ $(file_hash "$destination" || true) == "$expected_new" ]]
}

backup_for_run() {
    local run_id=$1 candidate
    local -a matches=()
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
    local keeper_hash=${5:-} service_hash=${6:-} config_hash=${7:-} batocera_old_hash=${8:-} batocera_new_hash=${9:-}
    local plan_dir backup_dir='' backup_rc failure_reason=''
    safe_run_id "$run_id" && valid_ipv4 "$target" && valid_hash "$keeper_hash" && valid_hash "$service_hash" &&
        valid_hash "$config_hash" && valid_hash "$batocera_old_hash" && valid_hash "$batocera_new_hash" || {
        emit_result PREFLIGHT_FAILURE 'Batocera network-watchdog apply evidence is malformed.'
        return 1
    }
    regular_file "$keeper_source" && regular_file "$service_source" || return 1
    [[ $(file_hash "$keeper_source" || true) == "$keeper_hash" && $(file_hash "$service_source" || true) == "$service_hash" ]] || return 1
    [[ $(default_gateway) == "$target" ]] || {
        emit_result PREFLIGHT_FAILURE 'The Batocera default gateway changed after planning.'
        return 1
    }
    ping -c 3 -W "$PING_TIMEOUT" "$target" >/dev/null 2>&1 || {
        emit_result PREFLIGHT_FAILURE "The selected liveness target $target is not reachable at the mutation boundary."
        return 1
    }
    plan_dir=$(mktemp -d /tmp/autopioverclock-batocera-network-watchdog-apply.XXXXXX) || return 1
    render_config "$plan_dir/watchdog.conf" "$target" "$run_id" || { rm -rf -- "$plan_dir"; return 1; }
    [[ $(file_hash "$plan_dir/watchdog.conf" || true) == "$config_hash" ]] || { rm -rf -- "$plan_dir"; return 1; }
    if backup_dir=$(backup_for_run "$run_id"); then backup_rc=0; else backup_rc=$?; backup_dir=''; fi
    (( backup_rc != 2 )) || failure_reason='Multiple backup directories claim this Batocera network-watchdog run.'
    if [[ -z $failure_reason && -n $backup_dir && $(path_hash "$LIVE_CONFIG") == "$config_hash" &&
          $(path_hash "$LIVE_KEEPER") == "$keeper_hash" && $(path_hash "$LIVE_SERVICE") == "$service_hash" &&
          $(file_hash "$BATOCERA_CONFIG" || true) == "$batocera_new_hash" ]]; then
        regular_file "$backup_dir/batocera.conf" && [[ $(file_hash "$backup_dir/batocera.conf" || true) == "$batocera_old_hash" ]] || failure_reason='The Batocera network-watchdog backup is invalid.'
        [[ -n $failure_reason ]] || grep -Fqx "RUN_ID=$run_id" "$LIVE_CONFIG" || failure_reason='The installed Batocera network-watchdog belongs to another run.'
        [[ -n $failure_reason ]] || "$LIVE_SERVICE" restart || failure_reason='Could not restart the reconciled Batocera network-watchdog service.'
        [[ -n $failure_reason ]] || service_active || failure_reason='The reconciled Batocera network-watchdog service is not active.'
        if [[ -z $failure_reason ]]; then
            rm -rf -- "$plan_dir"
            emit_data NETWORK_WATCHDOG_BACKUP "$backup_dir"
            emit_data NETWORK_WATCHDOG_TARGET "$target"
            emit_data NETWORK_WATCHDOG_CONFIG_HASH "$config_hash"
            emit_result PASS "Reconciled the completed Batocera network-watchdog installation for liveness target $target."
            return 0
        fi
    elif [[ -z $failure_reason && -n $backup_dir ]]; then
        "$LIVE_SERVICE" stop >/dev/null 2>&1 || true
        [[ $(path_hash "$LIVE_CONFIG") == absent || $(path_hash "$LIVE_CONFIG") == "$config_hash" ]] || failure_reason='Interrupted Batocera network-watchdog config is foreign.'
        [[ $(path_hash "$LIVE_KEEPER") == absent || $(path_hash "$LIVE_KEEPER") == "$keeper_hash" ]] || failure_reason='Interrupted Batocera network-watchdog keeper is foreign.'
        [[ $(path_hash "$LIVE_SERVICE") == absent || $(path_hash "$LIVE_SERVICE") == "$service_hash" ]] || failure_reason='Interrupted Batocera network-watchdog service is foreign.'
        [[ -n $failure_reason || $(file_hash "$BATOCERA_CONFIG" || true) == "$batocera_old_hash" || $(file_hash "$BATOCERA_CONFIG" || true) == "$batocera_new_hash" ]] || failure_reason='Interrupted batocera.conf is outside the checkpoint.'
        if [[ -z $failure_reason ]]; then
            rm -f -- "$LIVE_CONFIG" "$LIVE_KEEPER" "$LIVE_SERVICE"
            if [[ $(file_hash "$BATOCERA_CONFIG" || true) == "$batocera_new_hash" ]]; then
                atomic_replace "$backup_dir/batocera.conf" "$BATOCERA_CONFIG" "$batocera_new_hash" "$batocera_old_hash" 644 || failure_reason='Could not restore batocera.conf before retry.'
            fi
        fi
    elif [[ -z $failure_reason ]]; then
        preflight "$keeper_source" "$service_source" "$run_id" || failure_reason='Batocera network-watchdog state changed after planning.'
        [[ -n $failure_reason || $(default_gateway) == "$target" ]] || failure_reason='The Batocera default gateway changed after planning.'
        [[ -n $failure_reason || $(file_hash "$BATOCERA_CONFIG" || true) == "$batocera_old_hash" ]] || failure_reason='batocera.conf changed after planning.'
        [[ -n $failure_reason ]] || mkdir -p -- "$BACKUP_ROOT" "$LIVE_ROOT" "${LIVE_SERVICE%/*}" || failure_reason='Could not create Batocera network-watchdog directories.'
        [[ -n $failure_reason ]] || backup_dir=$(mktemp -d "$BACKUP_ROOT/network-watchdog-$(date -u +%Y%m%dT%H%M%SZ)-${run_id}.XXXXXX") || failure_reason='Could not reserve a Batocera network-watchdog backup directory.'
        [[ -n $failure_reason ]] || chmod 700 "$backup_dir" "$LIVE_ROOT" || failure_reason='Could not secure Batocera network-watchdog directories.'
        [[ -n $failure_reason ]] || cp -- "$BATOCERA_CONFIG" "$backup_dir/batocera.conf" || failure_reason='Could not back up batocera.conf.'
        [[ -n $failure_reason || $(file_hash "$backup_dir/batocera.conf" || true) == "$batocera_old_hash" ]] || failure_reason='The batocera.conf backup hash is wrong.'
    fi
    [[ -n $failure_reason ]] || render_batocera_config "$BATOCERA_CONFIG" "$plan_dir/batocera.conf" || failure_reason='Could not render batocera.conf.'
    [[ -n $failure_reason || $(file_hash "$plan_dir/batocera.conf" || true) == "$batocera_new_hash" ]] || failure_reason='Rendered batocera.conf no longer matches its plan.'
    [[ -n $failure_reason ]] || atomic_install_absent "$plan_dir/watchdog.conf" "$LIVE_CONFIG" "$config_hash" 600 || failure_reason='Could not install the Batocera network-watchdog config.'
    [[ -n $failure_reason ]] || atomic_install_absent "$keeper_source" "$LIVE_KEEPER" "$keeper_hash" 700 || failure_reason='Could not install the Batocera network-watchdog keeper.'
    [[ -n $failure_reason ]] || atomic_install_absent "$service_source" "$LIVE_SERVICE" "$service_hash" 755 || failure_reason='Could not install the Batocera network-watchdog service.'
    [[ -n $failure_reason ]] || atomic_replace "$plan_dir/batocera.conf" "$BATOCERA_CONFIG" "$batocera_old_hash" "$batocera_new_hash" 644 || failure_reason='Could not register the Batocera network-watchdog service.'
    [[ -n $failure_reason ]] || "$LIVE_SERVICE" start || failure_reason='Could not start the Batocera network-watchdog service.'
    [[ -n $failure_reason ]] || service_active || failure_reason='The Batocera network-watchdog service is not active.'
    rm -rf -- "$plan_dir"
    if [[ -n $failure_reason ]]; then
        if [[ -n $backup_dir && -d $backup_dir && ! -L $backup_dir ]]; then
            "$LIVE_SERVICE" stop >/dev/null 2>&1 || true
            [[ $(path_hash "$LIVE_CONFIG") == "$config_hash" ]] && rm -f -- "$LIVE_CONFIG"
            [[ $(path_hash "$LIVE_KEEPER") == "$keeper_hash" ]] && rm -f -- "$LIVE_KEEPER"
            [[ $(path_hash "$LIVE_SERVICE") == "$service_hash" ]] && rm -f -- "$LIVE_SERVICE"
            if [[ $(file_hash "$BATOCERA_CONFIG" || true) == "$batocera_new_hash" ]]; then
                atomic_replace "$backup_dir/batocera.conf" "$BATOCERA_CONFIG" "$batocera_new_hash" "$batocera_old_hash" 644 || failure_reason+=" batocera.conf rollback failed."
            fi
        fi
        emit_result PREFLIGHT_FAILURE "$failure_reason"
        return 1
    fi
    sync || { emit_result RECOVERY_FAILURE 'Could not sync the Batocera network-watchdog installation.'; return 1; }
    emit_data NETWORK_WATCHDOG_BACKUP "$backup_dir"
    emit_data NETWORK_WATCHDOG_TARGET "$target"
    emit_data NETWORK_WATCHDOG_CONFIG_HASH "$config_hash"
    emit_result PASS "Batocera temporary network-watchdog companion installed for liveness target $target."
}

cmd_cleanup() {
    local run_id=${1:-} backup_dir=${2:-} config_hash=${3:-} keeper_hash=${4:-} service_hash=${5:-}
    local batocera_old_hash=${6:-} batocera_new_hash=${7:-} failure_reason='' cleanup_marker
    local current_config_hash current_keeper_hash current_service_hash current_batocera_hash
    local archived_config_hash archived_keeper_hash archived_service_hash expected_marker actual_marker ownership_config
    safe_run_id "$run_id" && [[ $backup_dir == "$BACKUP_ROOT"/network-watchdog-[0-9]*-${run_id}.* ]] &&
        [[ -d $backup_dir && ! -L $backup_dir ]] && valid_hash "$config_hash" && valid_hash "$keeper_hash" &&
        valid_hash "$service_hash" && valid_hash "$batocera_old_hash" && valid_hash "$batocera_new_hash" || {
        emit_result RECOVERY_FAILURE 'Batocera network-watchdog cleanup ownership evidence is malformed.'
        return 1
    }
    regular_file "$backup_dir/batocera.conf" &&
        [[ $(file_hash "$backup_dir/batocera.conf" || true) == "$batocera_old_hash" ]] || {
        emit_result RECOVERY_FAILURE 'Batocera network-watchdog cleanup backup evidence is invalid.'
        return 1
    }
    expected_marker=$(printf 'RUN_ID=%s\nCONFIG_SHA256=%s\nKEEPER_SHA256=%s\nSERVICE_SHA256=%s\nBATOCERA_OLD_SHA256=%s\nBATOCERA_NEW_SHA256=%s\n' \
        "$run_id" "$config_hash" "$keeper_hash" "$service_hash" "$batocera_old_hash" "$batocera_new_hash")
    cleanup_marker=$backup_dir/cleanup.plan
    if [[ ! -e $cleanup_marker && ! -L $cleanup_marker ]]; then
        [[ $(path_hash "$LIVE_CONFIG") == "$config_hash" && $(path_hash "$LIVE_KEEPER") == "$keeper_hash" &&
           $(path_hash "$LIVE_SERVICE") == "$service_hash" && $(file_hash "$BATOCERA_CONFIG" || true) == "$batocera_new_hash" &&
           ! -e $backup_dir/removed-watchdog.conf && ! -L $backup_dir/removed-watchdog.conf &&
           ! -e $backup_dir/removed-keeper.py && ! -L $backup_dir/removed-keeper.py &&
           ! -e $backup_dir/removed-service && ! -L $backup_dir/removed-service ]] &&
            grep -Fqx "RUN_ID=$run_id" "$LIVE_CONFIG" || {
                emit_result RECOVERY_FAILURE 'Batocera network-watchdog cleanup could not prove the installing run.'
                return 1
            }
        printf '%s\n' "$expected_marker" >"${cleanup_marker}.new" && chmod 600 "${cleanup_marker}.new" &&
            [[ ! -e $cleanup_marker && ! -L $cleanup_marker ]] && mv -- "${cleanup_marker}.new" "$cleanup_marker" &&
            sync "$cleanup_marker" || {
                rm -f -- "${cleanup_marker}.new"
                emit_result RECOVERY_FAILURE 'Could not checkpoint Batocera network-watchdog cleanup.'
                return 1
            }
    fi
    regular_file "$cleanup_marker" || {
        emit_result RECOVERY_FAILURE 'Batocera network-watchdog cleanup checkpoint is missing or unsafe.'
        return 1
    }
    actual_marker=$(<"$cleanup_marker")
    [[ $actual_marker == "$expected_marker" ]] || {
        emit_result RECOVERY_FAILURE 'Batocera network-watchdog cleanup checkpoint does not match this run.'
        return 1
    }
    current_config_hash=$(path_hash "$LIVE_CONFIG")
    current_keeper_hash=$(path_hash "$LIVE_KEEPER")
    current_service_hash=$(path_hash "$LIVE_SERVICE")
    current_batocera_hash=$(file_hash "$BATOCERA_CONFIG" || true)
    archived_config_hash=$(path_hash "$backup_dir/removed-watchdog.conf")
    archived_keeper_hash=$(path_hash "$backup_dir/removed-keeper.py")
    archived_service_hash=$(path_hash "$backup_dir/removed-service")
    [[ ( ( $current_config_hash == "$config_hash" && $archived_config_hash == absent ) ||
         ( $current_config_hash == absent && $archived_config_hash == "$config_hash" ) ) &&
       ( ( $current_keeper_hash == "$keeper_hash" && $archived_keeper_hash == absent ) ||
         ( $current_keeper_hash == absent && $archived_keeper_hash == "$keeper_hash" ) ) &&
       ( ( $current_service_hash == "$service_hash" && $archived_service_hash == absent ) ||
         ( $current_service_hash == absent && $archived_service_hash == "$service_hash" ) ) &&
       ( $current_batocera_hash == "$batocera_new_hash" || $current_batocera_hash == "$batocera_old_hash" ) ]] || {
        emit_result RECOVERY_FAILURE 'Batocera network-watchdog cleanup refused changed or foreign files.'
        return 1
    }
    if [[ $current_config_hash == "$config_hash" ]]; then ownership_config=$LIVE_CONFIG; else ownership_config=$backup_dir/removed-watchdog.conf; fi
    grep -Fqx "RUN_ID=$run_id" "$ownership_config" || {
        emit_result RECOVERY_FAILURE 'Batocera network-watchdog cleanup lost its run ownership marker.'
        return 1
    }
    if [[ $current_service_hash == "$service_hash" ]]; then
        "$LIVE_SERVICE" stop || failure_reason='Could not stop the run-owned Batocera network-watchdog service.'
    fi
    if [[ -z $failure_reason && $current_config_hash == "$config_hash" ]]; then
        mv -- "$LIVE_CONFIG" "$backup_dir/removed-watchdog.conf" || failure_reason='Could not archive the run-owned Batocera network-watchdog config.'
    fi
    if [[ -z $failure_reason && $current_keeper_hash == "$keeper_hash" ]]; then
        mv -- "$LIVE_KEEPER" "$backup_dir/removed-keeper.py" || failure_reason='Could not archive the run-owned Batocera network-watchdog keeper.'
    fi
    if [[ -z $failure_reason && $current_service_hash == "$service_hash" ]]; then
        mv -- "$LIVE_SERVICE" "$backup_dir/removed-service" || failure_reason='Could not archive the run-owned Batocera network-watchdog service.'
    fi
    [[ -n $failure_reason || ( $(path_hash "$backup_dir/removed-watchdog.conf") == "$config_hash" &&
       $(path_hash "$backup_dir/removed-keeper.py") == "$keeper_hash" &&
       $(path_hash "$backup_dir/removed-service") == "$service_hash" ) ]] || failure_reason='The archived Batocera network-watchdog hashes are wrong.'
    if [[ -z $failure_reason && $(file_hash "$BATOCERA_CONFIG" || true) == "$batocera_new_hash" ]]; then
        atomic_replace "$backup_dir/batocera.conf" "$BATOCERA_CONFIG" "$batocera_new_hash" "$batocera_old_hash" 644 || failure_reason='Could not restore the original batocera.conf.'
    fi
    [[ -n $failure_reason ]] || sync || failure_reason='Could not sync Batocera network-watchdog cleanup.'
    if [[ -n $failure_reason ]]; then
        if [[ $(file_hash "$BATOCERA_CONFIG" || true) == "$batocera_new_hash" ]]; then
            [[ -e $LIVE_CONFIG ]] || { [[ -f $backup_dir/removed-watchdog.conf ]] && mv -- "$backup_dir/removed-watchdog.conf" "$LIVE_CONFIG" || true; }
            [[ -e $LIVE_KEEPER ]] || { [[ -f $backup_dir/removed-keeper.py ]] && mv -- "$backup_dir/removed-keeper.py" "$LIVE_KEEPER" || true; }
            [[ -e $LIVE_SERVICE ]] || { [[ -f $backup_dir/removed-service ]] && mv -- "$backup_dir/removed-service" "$LIVE_SERVICE" || true; }
            if [[ $(path_hash "$LIVE_CONFIG") == "$config_hash" && $(path_hash "$LIVE_KEEPER") == "$keeper_hash" &&
                  $(path_hash "$LIVE_SERVICE") == "$service_hash" ]]; then
                "$LIVE_SERVICE" start >/dev/null 2>&1 || failure_reason+=" service rollback failed."
            else
                failure_reason+=" file rollback failed."
            fi
        fi
        emit_result RECOVERY_FAILURE "$failure_reason"
        return 1
    fi
    emit_result PASS 'Run-owned Batocera network-watchdog companion removed; native hardware-watchdog state and durable evidence were retained.'
}

main() {
    local action=${1:-}
    shift || true
    case $action in
        plan) [[ $# == 3 ]] || return 2; cmd_plan "$@" ;;
        apply) [[ $# == 9 ]] || return 2; cmd_apply "$@" ;;
        cleanup) [[ $# == 7 ]] || return 2; cmd_cleanup "$@" ;;
        *) emit_result PREFLIGHT_FAILURE 'Unknown Batocera network-watchdog installer command.'; return 2 ;;
    esac
}

main "$@"
