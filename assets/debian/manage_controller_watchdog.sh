#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly MANAGED_MARKER='AUTOPIOVERCLOCK MANAGED CONTROLLER NETWORK WATCHDOG'
readonly LEASE_MARKER='AUTOPIOVERCLOCK MANAGED CONTROLLER WATCHDOG LEASE'
readonly RELEASE_MARKER='AUTOPIOVERCLOCK MANAGED CONTROLLER WATCHDOG RELEASE'
readonly PROVIDER_MARKER='AUTOPIOVERCLOCK MANAGED CONTROLLER WATCHDOG PROVIDER'
readonly LIVE_ROOT=${APO_CONTROLLER_WATCHDOG_ROOT:-/var/lib/autopioverclock/controller-network-watchdog}
readonly LIVE_CONFIG=${APO_CONTROLLER_WATCHDOG_CONFIG:-${LIVE_ROOT}/watchdog.conf}
readonly LEASE_ROOT=${APO_CONTROLLER_WATCHDOG_LEASE_ROOT:-${LIVE_ROOT}/leases}
readonly RELEASE_ROOT=${APO_CONTROLLER_WATCHDOG_RELEASE_ROOT:-${LIVE_ROOT}/released}
readonly PROVIDER_FILE=${APO_CONTROLLER_WATCHDOG_PROVIDER_FILE:-${LIVE_ROOT}/provider.conf}
readonly LIVE_KEEPER=${APO_CONTROLLER_WATCHDOG_KEEPER:-/usr/local/lib/autopioverclock/controller-network-watchdog-keeper.py}
readonly LIVE_SERVICE=${APO_CONTROLLER_WATCHDOG_SERVICE:-/etc/systemd/system/autopioverclock-controller-network-watchdog.service}
readonly SERVICE_NAME=${APO_CONTROLLER_WATCHDOG_SERVICE_NAME:-autopioverclock-controller-network-watchdog.service}
readonly LOCK_FILE=${APO_CONTROLLER_WATCHDOG_LOCK_FILE:-/run/lock/autopioverclock-controller-network-watchdog.lock}
readonly SYSTEMCTL=${APO_CONTROLLER_WATCHDOG_SYSTEMCTL:-systemctl}
readonly IP_BINARY=${APO_CONTROLLER_WATCHDOG_IP:-ip}
readonly PING_BINARY=${APO_CONTROLLER_WATCHDOG_PING:-ping}
readonly PING_TIMEOUT=2
readonly CHECK_INTERVAL=10
readonly STARTUP_GRACE=180
readonly FAILURE_WINDOW=180
readonly MAX_REBOOTS=0
readonly REBOOT_WINDOW=1800

PROVIDER_MODE=absent
PROVIDER_TARGET=''
PROVIDER_CONFIG_HASH=absent
PROVIDER_KEEPER_HASH=absent
PROVIDER_SERVICE_HASH=absent

b64() { printf '%s' "${1-}" | base64 | tr -d '\n'; }
emit_data() { printf 'APO_DATA\t%s\t%s\n' "$1" "$(b64 "${2-}")"; }
emit_result() {
    printf 'APO_RESULT_CLASS=%s\n' "$1"
    printf 'APO_RESULT_REASON_B64=%s\n' "$(b64 "$2")"
}
safe_run_id() { [[ ${1-} =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; }
valid_hash() { [[ ${1-} =~ ^[0-9a-f]{64}$ ]]; }
valid_saved_hash() { [[ ${1-} == absent ]] || valid_hash "${1-}"; }
valid_ipv4() {
    awk -F. '
        NF != 4 {exit 1}
        {for (i=1; i<=4; i++) if ($i !~ /^[0-9]+$/ || $i+0 > 255 || $i != $i+0) exit 1}
    ' <<<"${1-}"
}
regular_file() { [[ -f $1 && ! -L $1 ]]; }
file_hash() { sha256sum "$1" 2>/dev/null | awk 'NR == 1 {print $1}'; }
path_hash() {
    if regular_file "$1"; then file_hash "$1"
    elif [[ ! -e $1 && ! -L $1 ]]; then printf absent
    else printf unsafe
    fi
}
managed_or_absent() {
    local candidate=$1 marker=$2
    [[ ! -e $candidate && ! -L $candidate ]] && return 0
    regular_file "$candidate" && grep -Fq "$marker" "$candidate"
}
directory_is_safe() {
    local candidate=$1 resolved
    [[ $candidate == /* && -d $candidate && ! -L $candidate ]] || return 1
    resolved=$(readlink -f -- "$candidate" 2>/dev/null) || return 1
    [[ $resolved == "$candidate" ]]
}
ensure_directory() {
    local candidate=$1
    [[ $candidate == /* ]] || return 1
    if [[ -e $candidate || -L $candidate ]]; then
        directory_is_safe "$candidate"
        return
    fi
    mkdir -p -- "$candidate" || return 1
    directory_is_safe "$candidate"
}
hash_is_allowed() {
    local actual=$1
    shift
    local expected
    for expected in "$@"; do [[ $actual == "$expected" ]] && return 0; done
    return 1
}

acquire_lock() {
    [[ $(id -u) == 0 ]] || return 1
    ensure_directory "${LOCK_FILE%/*}" || return 1
    [[ ( ! -e $LOCK_FILE && ! -L $LOCK_FILE ) || ( -f $LOCK_FILE && ! -L $LOCK_FILE ) ]] || return 1
    exec 9>"$LOCK_FILE" || return 1
    flock -x 9
}

atomic_install() {
    local source=$1 destination=$2 mode=$3 expected_hash=$4 temporary
    regular_file "$source" && [[ $(file_hash "$source") == "$expected_hash" ]] || return 1
    ensure_directory "${destination%/*}" || return 1
    temporary=$(mktemp "${destination}.new.XXXXXX") || return 1
    install -m "$mode" "$source" "$temporary" || { rm -f -- "$temporary"; return 1; }
    [[ $(file_hash "$temporary") == "$expected_hash" ]] || { rm -f -- "$temporary"; return 1; }
    mv -f -- "$temporary" "$destination" || { rm -f -- "$temporary"; return 1; }
    sync "$destination"
}

atomic_write() {
    local destination=$1 mode=$2 content=$3 temporary
    ensure_directory "${destination%/*}" || return 1
    temporary=$(mktemp "${destination}.new.XXXXXX") || return 1
    printf '%s\n' "$content" >"$temporary" && chmod "$mode" "$temporary" && sync "$temporary" || {
        rm -f -- "$temporary"
        return 1
    }
    mv -f -- "$temporary" "$destination" || { rm -f -- "$temporary"; return 1; }
    sync "$destination"
}

render_config() {
    local destination=$1 target=$2
    valid_ipv4 "$target" || return 1
    {
        printf '# %s\n' "$MANAGED_MARKER"
        printf 'RUN_ID=controller-shared\n'
        printf 'TARGET=%s\n' "$target"
        printf 'PING_TIMEOUT_SECONDS=%s\n' "$PING_TIMEOUT"
        printf 'CHECK_INTERVAL_SECONDS=%s\n' "$CHECK_INTERVAL"
        printf 'STARTUP_GRACE_SECONDS=%s\n' "$STARTUP_GRACE"
        printf 'FAILURE_WINDOW_SECONDS=%s\n' "$FAILURE_WINDOW"
        printf 'MAX_REBOOTS=%s\n' "$MAX_REBOOTS"
        printf 'REBOOT_WINDOW_SECONDS=%s\n' "$REBOOT_WINDOW"
    } >"$destination"
}

load_provider() {
    local marker format mode target config_hash keeper_hash service_hash extra
    PROVIDER_MODE=absent
    PROVIDER_TARGET=''
    PROVIDER_CONFIG_HASH=absent
    PROVIDER_KEEPER_HASH=absent
    PROVIDER_SERVICE_HASH=absent
    [[ ! -e $PROVIDER_FILE && ! -L $PROVIDER_FILE ]] && return 0
    regular_file "$PROVIDER_FILE" || return 1
    {
        IFS= read -r marker && IFS= read -r format && IFS= read -r mode &&
            IFS= read -r target && IFS= read -r config_hash &&
            IFS= read -r keeper_hash && IFS= read -r service_hash &&
            ! IFS= read -r extra
    } <"$PROVIDER_FILE" || return 1
    [[ $marker == "# $PROVIDER_MARKER" && $format == FORMAT=1 ]] || return 1
    PROVIDER_MODE=${mode#MODE=}
    PROVIDER_TARGET=${target#TARGET=}
    PROVIDER_CONFIG_HASH=${config_hash#CONFIG_SHA256=}
    PROVIDER_KEEPER_HASH=${keeper_hash#KEEPER_SHA256=}
    PROVIDER_SERVICE_HASH=${service_hash#SERVICE_SHA256=}
    [[ $mode == "MODE=$PROVIDER_MODE" && $target == "TARGET=$PROVIDER_TARGET" &&
       $config_hash == "CONFIG_SHA256=$PROVIDER_CONFIG_HASH" &&
       $keeper_hash == "KEEPER_SHA256=$PROVIDER_KEEPER_HASH" &&
       $service_hash == "SERVICE_SHA256=$PROVIDER_SERVICE_HASH" ]] || return 1
    [[ $PROVIDER_MODE == standalone || $PROVIDER_MODE == native-debian ]] || return 1
    valid_ipv4 "$PROVIDER_TARGET" && valid_saved_hash "$PROVIDER_CONFIG_HASH" &&
        valid_saved_hash "$PROVIDER_KEEPER_HASH" && valid_saved_hash "$PROVIDER_SERVICE_HASH" || return 1
    if [[ $PROVIDER_MODE == native-debian ]]; then
        [[ $PROVIDER_CONFIG_HASH == absent && $PROVIDER_KEEPER_HASH == absent &&
           $PROVIDER_SERVICE_HASH == absent ]] || return 1
    else
        valid_hash "$PROVIDER_CONFIG_HASH" && valid_hash "$PROVIDER_KEEPER_HASH" &&
            valid_hash "$PROVIDER_SERVICE_HASH" || return 1
    fi
}

write_provider() {
    local mode=$1 target=$2 config_hash=$3 keeper_hash=$4 service_hash=$5 content
    [[ $mode == standalone || $mode == native-debian ]] && valid_ipv4 "$target" &&
        valid_saved_hash "$config_hash" && valid_saved_hash "$keeper_hash" &&
        valid_saved_hash "$service_hash" || return 1
    content=$(printf '# %s\nFORMAT=1\nMODE=%s\nTARGET=%s\nCONFIG_SHA256=%s\nKEEPER_SHA256=%s\nSERVICE_SHA256=%s\n' \
        "$PROVIDER_MARKER" "$mode" "$target" "$config_hash" "$keeper_hash" "$service_hash")
    atomic_write "$PROVIDER_FILE" 600 "$content"
}

lease_content() {
    printf '# %s\nRUN_ID=%s\n' "$LEASE_MARKER" "$1"
}

lease_valid() {
    local candidate=$1 expected_run=${2:-} marker run_line extra run_id
    regular_file "$candidate" || return 1
    {
        IFS= read -r marker && IFS= read -r run_line && ! IFS= read -r extra
    } <"$candidate" || return 1
    [[ $marker == "# $LEASE_MARKER" && $run_line == RUN_ID=* ]] || return 1
    run_id=${run_line#RUN_ID=}
    safe_run_id "$run_id" || return 1
    [[ -z $expected_run || $run_id == "$expected_run" ]]
}

release_receipt_valid() {
    local candidate=$1 expected_run=$2 marker run_line extra
    regular_file "$candidate" || return 1
    {
        IFS= read -r marker && IFS= read -r run_line && ! IFS= read -r extra
    } <"$candidate" || return 1
    [[ $marker == "# $RELEASE_MARKER" && $run_line == "RUN_ID=$expected_run" ]]
}

create_lease() {
    local run_id=$1 lease=${LEASE_ROOT}/${run_id}.lease releasing=${LEASE_ROOT}/${run_id}.releasing
    [[ ! -e $releasing && ! -L $releasing ]] || return 1
    if [[ -e $lease || -L $lease ]]; then lease_valid "$lease" "$run_id"; return; fi
    atomic_write "$lease" 600 "$(lease_content "$run_id")"
}

active_lease_count() {
    local candidate run_id count=0
    shopt -s nullglob
    for candidate in "$LEASE_ROOT"/*.lease; do
        run_id=${candidate##*/}
        run_id=${run_id%.lease}
        safe_run_id "$run_id" && lease_valid "$candidate" "$run_id" || { shopt -u nullglob; return 1; }
        count=$((count + 1))
    done
    for candidate in "$LEASE_ROOT"/*.releasing; do
        run_id=${candidate##*/}
        run_id=${run_id%.releasing}
        safe_run_id "$run_id" && lease_valid "$candidate" "$run_id" || { shopt -u nullglob; return 1; }
    done
    shopt -u nullglob
    printf '%s' "$count"
}

watchdog_config_value() {
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

native_watchdog_config_path() {
    local service=watchdog.service pid argument expect_config=0 configured_path='' config binary unit
    "$SYSTEMCTL" is-active --quiet "$service" 2>/dev/null || return 1
    pid=$("$SYSTEMCTL" show --property=MainPID --value "$service" 2>/dev/null || true)
    [[ $pid =~ ^[1-9][0-9]*$ && -r /proc/$pid/cmdline ]] || return 2
    kill -0 "$pid" 2>/dev/null || return 2
    binary=$(readlink -f -- "/proc/$pid/exe" 2>/dev/null || true)
    [[ $binary == /* && -x $binary && ! -L $binary ]] || return 2
    while IFS= read -r argument; do
        if (( expect_config == 1 )); then configured_path=$argument; expect_config=0; continue; fi
        case $argument in
            -c|--config-file) expect_config=1 ;;
            -c*) configured_path=${argument#-c} ;;
            --config-file=*) configured_path=${argument#*=} ;;
        esac
    done < <(tr '\000' '\n' <"/proc/$pid/cmdline" 2>/dev/null)
    (( expect_config == 0 )) || return 2
    config=${configured_path:-/etc/watchdog.conf}
    [[ $config == /* && -f $config && ! -L $config ]] || return 2
    unit=$("$SYSTEMCTL" show --property=FragmentPath --value "$service" 2>/dev/null || true)
    [[ $unit == /* && -f $unit ]] || return 2
    printf '%s' "$config"
}

native_watchdog_target() {
    local config target value argument config_rc
    if config=$(native_watchdog_config_path); then config_rc=0; else config_rc=$?; fi
    (( config_rc == 0 )) || return "$config_rc"
    target=$(watchdog_config_value "$config" ping) || return 2
    valid_ipv4 "$target" || return 2
    value=$(watchdog_config_value "$config" repair-binary 1) || return 2
    [[ -z $value || $value == /* ]] || return 2
    for argument in repair-timeout retry-timeout watchdog-timeout; do
        value=$(watchdog_config_value "$config" "$argument" 1) || return 2
        [[ -z $value || $value =~ ^[0-9]+$ ]] || return 2
    done
    printf '%s' "$target"
}

default_gateway() {
    local gateway
    gateway=$("$IP_BINARY" -4 route show default 2>/dev/null | awk '
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

service_ready() {
    local pid argument keeper_found=0 config_found=0
    "$SYSTEMCTL" is-enabled --quiet "$SERVICE_NAME" 2>/dev/null || return 1
    "$SYSTEMCTL" is-active --quiet "$SERVICE_NAME" 2>/dev/null || return 1
    pid=$("$SYSTEMCTL" show --property=MainPID --value "$SERVICE_NAME" 2>/dev/null || true)
    [[ $pid =~ ^[1-9][0-9]*$ && -r /proc/$pid/cmdline ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    while IFS= read -r argument; do
        [[ $argument == "$LIVE_KEEPER" ]] && keeper_found=1
        [[ $argument == "$LIVE_CONFIG" ]] && config_found=1
    done < <(tr '\000' '\n' <"/proc/$pid/cmdline" 2>/dev/null)
    (( keeper_found == 1 && config_found == 1 ))
}

remove_managed_path() {
    local managed_path=$1 marker=$2
    [[ ! -e $managed_path && ! -L $managed_path ]] && return 0
    directory_is_safe "${managed_path%/*}" || return 1
    regular_file "$managed_path" && grep -Fq "$marker" "$managed_path" || return 1
    rm -f -- "$managed_path" && sync "${managed_path%/*}"
}

migrate_to_native() {
    local target=$1
    if [[ $PROVIDER_MODE == standalone ]]; then
        [[ $(path_hash "$LIVE_CONFIG") == "$PROVIDER_CONFIG_HASH" &&
           $(path_hash "$LIVE_KEEPER") == "$PROVIDER_KEEPER_HASH" &&
           $(path_hash "$LIVE_SERVICE") == "$PROVIDER_SERVICE_HASH" ]] || return 1
    else
        [[ $(path_hash "$LIVE_CONFIG") == absent &&
           $(path_hash "$LIVE_KEEPER") == absent &&
           $(path_hash "$LIVE_SERVICE") == absent ]] || return 1
    fi
    "$SYSTEMCTL" disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    "$SYSTEMCTL" stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    remove_managed_path "$LIVE_SERVICE" "$MANAGED_MARKER" || return 1
    remove_managed_path "$LIVE_KEEPER" "$MANAGED_MARKER" || return 1
    remove_managed_path "$LIVE_CONFIG" "$MANAGED_MARKER" || return 1
    "$SYSTEMCTL" daemon-reload || return 1
    write_provider native-debian "$target" absent absent absent
}

install_standalone() {
    local keeper_source=$1 service_source=$2 target=$3
    local keeper_hash service_hash config_hash temporary_config current
    keeper_hash=$(file_hash "$keeper_source" || true)
    service_hash=$(file_hash "$service_source" || true)
    valid_hash "$keeper_hash" && valid_hash "$service_hash" || return 1
    temporary_config=$(mktemp /tmp/autopioverclock-controller-watchdog.XXXXXX) || return 1
    render_config "$temporary_config" "$target" || { rm -f -- "$temporary_config"; return 1; }
    config_hash=$(file_hash "$temporary_config" || true)
    valid_hash "$config_hash" || { rm -f -- "$temporary_config"; return 1; }
    for current in \
        "$(path_hash "$LIVE_CONFIG"):${PROVIDER_CONFIG_HASH}:${config_hash}" \
        "$(path_hash "$LIVE_KEEPER"):${PROVIDER_KEEPER_HASH}:${keeper_hash}" \
        "$(path_hash "$LIVE_SERVICE"):${PROVIDER_SERVICE_HASH}:${service_hash}"; do
        IFS=: read -r actual old desired <<<"$current"
        if [[ $PROVIDER_MODE == standalone ]]; then
            hash_is_allowed "$actual" "$old" "$desired" || {
                rm -f -- "$temporary_config"
                return 1
            }
        else
            hash_is_allowed "$actual" absent "$desired" || {
                rm -f -- "$temporary_config"
                return 1
            }
        fi
        [[ $actual != unsafe ]] || {
            rm -f -- "$temporary_config"
            return 1
        }
    done
    managed_or_absent "$LIVE_CONFIG" "$MANAGED_MARKER" &&
        managed_or_absent "$LIVE_KEEPER" "$MANAGED_MARKER" &&
        managed_or_absent "$LIVE_SERVICE" "$MANAGED_MARKER" || {
            rm -f -- "$temporary_config"
            return 1
        }
    atomic_install "$temporary_config" "$LIVE_CONFIG" 600 "$config_hash" &&
        atomic_install "$keeper_source" "$LIVE_KEEPER" 755 "$keeper_hash" &&
        atomic_install "$service_source" "$LIVE_SERVICE" 644 "$service_hash" || {
            rm -f -- "$temporary_config"
            return 1
        }
    rm -f -- "$temporary_config"
    write_provider standalone "$target" "$config_hash" "$keeper_hash" "$service_hash" || return 1
    "$SYSTEMCTL" daemon-reload || return 1
    if "$SYSTEMCTL" is-active --quiet watchdog.service 2>/dev/null; then return 2; fi
    "$SYSTEMCTL" enable "$SERVICE_NAME" >/dev/null || return 1
    if "$SYSTEMCTL" is-active --quiet watchdog.service 2>/dev/null; then return 2; fi
    "$SYSTEMCTL" restart "$SERVICE_NAME" || return 1
    if "$SYSTEMCTL" is-active --quiet watchdog.service 2>/dev/null; then return 2; fi
    service_ready
}

cmd_ensure() {
    local keeper_source=${1:-} service_source=${2:-} run_id=${3:-}
    local native_target native_rc gateway install_rc lease_count
    [[ -r $keeper_source && -r $service_source ]] && safe_run_id "$run_id" || {
        emit_result PREFLIGHT_FAILURE 'Controller watchdog ensure arguments are invalid.'
        return 1
    }
    grep -Fq "$MANAGED_MARKER" "$keeper_source" && grep -Fq "$MANAGED_MARKER" "$service_source" || {
        emit_result PREFLIGHT_FAILURE 'Controller watchdog source assets lack their ownership marker.'
        return 1
    }
    for required in awk base64 chmod flock grep install mkdir mktemp mv readlink rm sha256sum sync tr; do
        command -v "$required" >/dev/null 2>&1 || {
            emit_result PREFLIGHT_FAILURE "Controller watchdog requires $required on the controller."
            return 1
        }
    done
    command -v "$SYSTEMCTL" >/dev/null 2>&1 && command -v "$IP_BINARY" >/dev/null 2>&1 &&
        command -v "$PING_BINARY" >/dev/null 2>&1 || {
            emit_result PREFLIGHT_FAILURE 'Controller watchdog requires systemctl, ip, and ping.'
            return 1
        }
    acquire_lock || { emit_result PREFLIGHT_FAILURE 'Could not acquire the root controller watchdog lock.'; return 1; }
    ensure_directory "$LIVE_ROOT" && ensure_directory "$LEASE_ROOT" && ensure_directory "$RELEASE_ROOT" || {
        emit_result PREFLIGHT_FAILURE 'Could not create controller watchdog state directories.'
        return 1
    }
    chmod 700 "$LIVE_ROOT" "$LEASE_ROOT" "$RELEASE_ROOT" || {
        emit_result PREFLIGHT_FAILURE 'Could not secure controller watchdog state directories.'
        return 1
    }
    load_provider || { emit_result RECOVERY_FAILURE 'Controller watchdog provider evidence is malformed.'; return 1; }
    lease_count=$(active_lease_count) || {
        emit_result RECOVERY_FAILURE 'Controller watchdog lease evidence is malformed.'
        return 1
    }
    if [[ -e ${RELEASE_ROOT}/${run_id}.released || -L ${RELEASE_ROOT}/${run_id}.released ]]; then
        emit_result RECOVERY_FAILURE 'This controller watchdog lease was already released.'
        return 1
    fi
    if native_target=$(native_watchdog_target); then native_rc=0; else native_rc=$?; fi
    case $native_rc in
        0)
            "$PING_BINARY" -c 3 -W "$PING_TIMEOUT" "$native_target" >/dev/null 2>&1 || {
                emit_result PREFLIGHT_FAILURE "The native controller watchdog target $native_target is not reachable."
                return 1
            }
            migrate_to_native "$native_target" || {
                emit_result RECOVERY_FAILURE 'Could not retire the project controller companion after recognizing the native watchdog.'
                return 1
            }
            create_lease "$run_id" || { emit_result RECOVERY_FAILURE 'Could not create the controller watchdog lease.'; return 1; }
            ;;
        1)
            gateway=$(default_gateway) || {
                emit_result PREFLIGHT_FAILURE 'Could not select exactly one IPv4 default gateway for the controller companion.'
                return 1
            }
            "$PING_BINARY" -c 3 -W "$PING_TIMEOUT" "$gateway" >/dev/null 2>&1 || {
                emit_result PREFLIGHT_FAILURE "The controller gateway $gateway is not reachable."
                return 1
            }
            if install_standalone "$keeper_source" "$service_source" "$gateway"; then install_rc=0; else install_rc=$?; fi
            if (( install_rc == 2 )); then
                if native_target=$(native_watchdog_target); then
                    migrate_to_native "$native_target" || {
                        emit_result RECOVERY_FAILURE 'The native watchdog became active, but the controller companion could not be retired safely.'
                        return 1
                    }
                else
                    emit_result RECOVERY_FAILURE 'The native watchdog changed during controller companion installation.'
                    return 1
                fi
            elif (( install_rc != 0 )); then
                emit_result RECOVERY_FAILURE 'The controller network-watchdog companion could not be installed and verified.'
                return 1
            fi
            create_lease "$run_id" || { emit_result RECOVERY_FAILURE 'Could not create the controller watchdog lease.'; return 1; }
            ;;
        *)
            emit_result PREFLIGHT_FAILURE 'An active watchdog.service could not be proved to have one safe network target; refusing a second network rebooter.'
            return 1
            ;;
    esac
    load_provider || { emit_result RECOVERY_FAILURE 'Installed controller watchdog provider evidence is invalid.'; return 1; }
    lease_count=$(active_lease_count) || { emit_result RECOVERY_FAILURE 'Installed controller watchdog leases are invalid.'; return 1; }
    emit_data CONTROLLER_WATCHDOG_PROVIDER "$PROVIDER_MODE"
    emit_data CONTROLLER_WATCHDOG_TARGET "$PROVIDER_TARGET"
    emit_data CONTROLLER_WATCHDOG_LEASE_COUNT "$lease_count"
    emit_result PASS "Controller network-watchdog protection is ready through $PROVIDER_MODE for $PROVIDER_TARGET."
}

cmd_release() {
    local keeper_source=${1:-} service_source=${2:-} run_id=${3:-}
    local lease=${LEASE_ROOT}/${run_id}.lease releasing=${LEASE_ROOT}/${run_id}.releasing
    local receipt=${RELEASE_ROOT}/${run_id}.released lease_count content
    [[ -r $keeper_source && -r $service_source ]] && safe_run_id "$run_id" || {
        emit_result RECOVERY_FAILURE 'Controller watchdog release arguments are invalid.'
        return 1
    }
    acquire_lock || { emit_result RECOVERY_FAILURE 'Could not acquire the root controller watchdog lock for release.'; return 1; }
    directory_is_safe "$LIVE_ROOT" && directory_is_safe "$LEASE_ROOT" &&
        directory_is_safe "$RELEASE_ROOT" || {
        emit_result RECOVERY_FAILURE 'Controller watchdog state directories are missing or unsafe.'
        return 1
    }
    if [[ -e $receipt || -L $receipt ]]; then
        release_receipt_valid "$receipt" "$run_id" || {
            emit_result RECOVERY_FAILURE 'Controller watchdog release receipt is malformed.'
            return 1
        }
        [[ ! -e $releasing && ! -L $releasing ]] || rm -f -- "$releasing"
        load_provider || { emit_result RECOVERY_FAILURE 'Controller watchdog provider evidence is malformed during repeated release.'; return 1; }
        if [[ -d $LEASE_ROOT && ! -L $LEASE_ROOT ]]; then
            lease_count=$(active_lease_count) || { emit_result RECOVERY_FAILURE 'Controller watchdog lease evidence is malformed.'; return 1; }
        else
            lease_count=0
        fi
        emit_data CONTROLLER_WATCHDOG_PROVIDER "$PROVIDER_MODE"
        emit_data CONTROLLER_WATCHDOG_TARGET "$PROVIDER_TARGET"
        emit_data CONTROLLER_WATCHDOG_LEASE_COUNT "$lease_count"
        emit_result PASS 'Controller watchdog lease was already released safely.'
        return 0
    fi
    if [[ -e $lease || -L $lease ]]; then
        lease_valid "$lease" "$run_id" || { emit_result RECOVERY_FAILURE 'Controller watchdog lease ownership is invalid.'; return 1; }
        [[ ! -e $releasing && ! -L $releasing ]] || { emit_result RECOVERY_FAILURE 'Duplicate controller watchdog release evidence exists.'; return 1; }
        mv -- "$lease" "$releasing" && sync "$LEASE_ROOT" || {
            emit_result RECOVERY_FAILURE 'Could not checkpoint controller watchdog lease release.'
            return 1
        }
    else
        lease_valid "$releasing" "$run_id" || {
            emit_result RECOVERY_FAILURE 'The exact controller watchdog lease is missing.'
            return 1
        }
    fi
    lease_count=$(active_lease_count) || { emit_result RECOVERY_FAILURE 'Controller watchdog lease evidence is malformed.'; return 1; }
    if (( lease_count == 0 )); then
        load_provider || { emit_result RECOVERY_FAILURE 'Controller watchdog provider evidence is malformed during release.'; return 1; }
        if [[ $PROVIDER_MODE == standalone ]]; then
            [[ $(path_hash "$LIVE_CONFIG") == "$PROVIDER_CONFIG_HASH" &&
               $(path_hash "$LIVE_KEEPER") == "$PROVIDER_KEEPER_HASH" &&
               $(path_hash "$LIVE_SERVICE") == "$PROVIDER_SERVICE_HASH" ]] || {
                emit_result RECOVERY_FAILURE 'Controller watchdog live files changed before final release.'
                return 1
            }
            "$SYSTEMCTL" disable "$SERVICE_NAME" >/dev/null 2>&1 || {
                emit_result RECOVERY_FAILURE 'Could not disable the controller watchdog companion before removal.'
                return 1
            }
            "$SYSTEMCTL" stop "$SERVICE_NAME" >/dev/null 2>&1 || {
                emit_result RECOVERY_FAILURE 'Could not stop the controller watchdog companion before removal.'
                return 1
            }
            remove_managed_path "$LIVE_SERVICE" "$MANAGED_MARKER" &&
                remove_managed_path "$LIVE_KEEPER" "$MANAGED_MARKER" &&
                remove_managed_path "$LIVE_CONFIG" "$MANAGED_MARKER" || {
                    emit_result RECOVERY_FAILURE 'Could not remove exactly owned controller watchdog companion files.'
                    return 1
                }
            "$SYSTEMCTL" daemon-reload || { emit_result RECOVERY_FAILURE 'Could not reload systemd after controller watchdog removal.'; return 1; }
        else
            [[ $(path_hash "$LIVE_CONFIG") == absent && $(path_hash "$LIVE_KEEPER") == absent &&
               $(path_hash "$LIVE_SERVICE") == absent ]] || {
                emit_result RECOVERY_FAILURE 'Unexpected project controller watchdog files exist while the native provider is selected.'
                return 1
            }
        fi
        rm -f -- "$PROVIDER_FILE" && sync "$LIVE_ROOT" || {
            emit_result RECOVERY_FAILURE 'Could not remove the completed controller watchdog provider marker.'
            return 1
        }
        PROVIDER_MODE=absent
        PROVIDER_TARGET=''
        PROVIDER_CONFIG_HASH=absent
        PROVIDER_KEEPER_HASH=absent
        PROVIDER_SERVICE_HASH=absent
    fi
    content=$(printf '# %s\nRUN_ID=%s\n' "$RELEASE_MARKER" "$run_id")
    atomic_write "$receipt" 600 "$content" || { emit_result RECOVERY_FAILURE 'Could not write the controller watchdog release receipt.'; return 1; }
    rm -f -- "$releasing" && sync "$LEASE_ROOT" || { emit_result RECOVERY_FAILURE 'Could not finalize controller watchdog lease release.'; return 1; }
    emit_data CONTROLLER_WATCHDOG_PROVIDER "$PROVIDER_MODE"
    emit_data CONTROLLER_WATCHDOG_TARGET "$PROVIDER_TARGET"
    emit_data CONTROLLER_WATCHDOG_LEASE_COUNT "$lease_count"
    emit_result PASS 'Run-owned controller watchdog lease released; project-owned protection remains only for other active runs.'
}

cmd_status() {
    local lease_count
    acquire_lock || { emit_result HARNESS_FAILURE 'Could not acquire the root controller watchdog lock for status.'; return 1; }
    if [[ -e $LIVE_ROOT || -L $LIVE_ROOT ]]; then
        directory_is_safe "$LIVE_ROOT" || { emit_result RECOVERY_FAILURE 'Controller watchdog state directory is unsafe.'; return 1; }
    fi
    load_provider || { emit_result RECOVERY_FAILURE 'Controller watchdog provider evidence is malformed.'; return 1; }
    if [[ -d $LEASE_ROOT && ! -L $LEASE_ROOT ]]; then
        lease_count=$(active_lease_count) || { emit_result RECOVERY_FAILURE 'Controller watchdog lease evidence is malformed.'; return 1; }
    else
        lease_count=0
    fi
    emit_data CONTROLLER_WATCHDOG_PROVIDER "$PROVIDER_MODE"
    emit_data CONTROLLER_WATCHDOG_TARGET "$PROVIDER_TARGET"
    emit_data CONTROLLER_WATCHDOG_LEASE_COUNT "$lease_count"
    emit_result PASS 'Controller watchdog status read successfully.'
}

main() {
    local command_name=${1:-}
    shift || true
    case $command_name in
        ensure) cmd_ensure "$@" ;;
        release) cmd_release "$@" ;;
        status) cmd_status "$@" ;;
        *) emit_result PREFLIGHT_FAILURE 'Unknown controller watchdog manager command.'; return 2 ;;
    esac
}

if [[ ${APO_CONTROLLER_WATCHDOG_MANAGER_LIBRARY_ONLY:-0} != 1 ]]; then main "$@"; fi
