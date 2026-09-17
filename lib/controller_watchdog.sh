#!/usr/bin/env bash
# Run-scoped controller network-watchdog lease management.

apo_controller_watchdog_valid_ipv4() {
    awk -F. '
        NF != 4 {exit 1}
        {for (i=1; i<=4; i++) if ($i !~ /^[0-9]+$/ || $i+0 > 255 || $i != $i+0) exit 1}
    ' <<<"${1-}"
}

apo_controller_watchdog_new_lease_id() {
    local role=${1:-run}
    printf '%s.%s.%s.%s' "$APO_RUN_ID" "$role" "$(date -u +%s)" "$BASHPID"
}

apo_controller_watchdog_manager_capture() {
    local action=$1 lease_id=$2 output_file=$3
    local manager=${APO_ROOT}/assets/debian/manage_controller_watchdog.sh
    local keeper=${APO_ROOT}/assets/debian/network_watchdog_keeper.py
    local service=${APO_ROOT}/assets/debian/autopioverclock-controller-network-watchdog.service
    local command_rc
    [[ -f $manager && ! -L $manager && -r $manager &&
       -f $keeper && ! -L $keeper && -r $keeper &&
       -f $service && ! -L $service && -r $service ]] || {
        APO_LAST_CLASS=PREFLIGHT_FAILURE
        APO_LAST_REASON='The packaged controller watchdog assets are missing or unsafe.'
        return 1
    }
    if (( EUID == 0 )); then
        if /bin/bash "$manager" "$action" "$keeper" "$service" "$lease_id" >"$output_file" 2>&1; then
            command_rc=0
        else
            command_rc=$?
        fi
    else
        command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1 || {
            APO_LAST_CLASS=PREFLIGHT_FAILURE
            APO_LAST_REASON='The controller watchdog requires root or passwordless sudo on the controller.'
            return 1
        }
        if sudo -n /bin/bash "$manager" "$action" "$keeper" "$service" "$lease_id" >"$output_file" 2>&1; then
            command_rc=0
        else
            command_rc=$?
        fi
    fi
    if [[ -n ${APO_LOG_FILE:-} ]]; then
        printf '\n[controller-watchdog-%s]\n' "$action" >>"$APO_LOG_FILE"
        command sed 's/^/[controller-watchdog] /' "$output_file" >>"$APO_LOG_FILE" 2>/dev/null || true
    fi
    apo_classify_output "$output_file" controller-watchdog
    (( command_rc == 0 && APO_LAST_RESULT_COMPLETE == 1 )) && [[ $APO_LAST_CLASS == PASS ]]
}

apo_controller_watchdog_ensure_for_run() {
    local lease_id output_file provider target lease_count
    [[ $(apo_state_get READ_ONLY_RUN 0) == 0 ]] || return 0
    lease_id=$(apo_state_get CONTROLLER_WATCHDOG_LEASE_ID '')
    if [[ -z $lease_id ]]; then
        lease_id=$(apo_state_get RUN_ID "${APO_RUN_ID:-}")
        [[ -n $lease_id ]] || {
            APO_LAST_CLASS=HARNESS_FAILURE
            APO_LAST_REASON='The controller watchdog cannot derive a run identity for its lease.'
            return 1
        }
        apo_state_set CONTROLLER_WATCHDOG_LEASE_ID "$lease_id"
        apo_state_save
    fi
    apo_is_safe_run_id "$lease_id" || {
        APO_LAST_CLASS=HARNESS_FAILURE
        APO_LAST_REASON='The saved controller watchdog lease identity is invalid.'
        return 1
    }
    output_file=$(mktemp "${APO_RUN_PREFIX}-controller-watchdog-ensure.XXXXXX") || {
        APO_LAST_CLASS=HARNESS_FAILURE
        APO_LAST_REASON='Could not create the controller watchdog result file.'
        return 1
    }
    chmod 600 "$output_file"
    if ! apo_controller_watchdog_manager_capture ensure "$lease_id" "$output_file"; then
        rm -f -- "$output_file"
        return 1
    fi
    apo_parse_data_file "$output_file" APO_WORKER_DATA
    rm -f -- "$output_file"
    provider=${APO_WORKER_DATA[CONTROLLER_WATCHDOG_PROVIDER]:-}
    target=${APO_WORKER_DATA[CONTROLLER_WATCHDOG_TARGET]:-}
    lease_count=${APO_WORKER_DATA[CONTROLLER_WATCHDOG_LEASE_COUNT]:-}
    [[ ( $provider == native-debian || $provider == standalone ) &&
       $lease_count =~ ^[1-9][0-9]*$ ]] && apo_controller_watchdog_valid_ipv4 "$target" || {
        APO_LAST_CLASS=HARNESS_FAILURE
        APO_LAST_REASON='The controller watchdog manager returned malformed readiness evidence.'
        return 1
    }
    apo_state_set CONTROLLER_WATCHDOG_LEASED 1
    apo_state_set CONTROLLER_WATCHDOG_PROVIDER "$provider"
    apo_state_set CONTROLLER_WATCHDOG_TARGET "$target"
    apo_state_set CONTROLLER_WATCHDOG_LEASE_COUNT "$lease_count"
    apo_state_set CONTROLLER_WATCHDOG_STATUS READY
    apo_state_save
    apo_event controller-watchdog PASS '' "Controller network-watchdog protection is ready through $provider for $target; active leases=$lease_count."
}

apo_controller_watchdog_release_for_run() {
    local lease_id output_file lease_count provider target
    [[ $(apo_state_get CONTROLLER_WATCHDOG_LEASED 0) == 1 ]] || return 0
    lease_id=$(apo_state_get CONTROLLER_WATCHDOG_LEASE_ID '')
    apo_is_safe_run_id "$lease_id" || {
        APO_LAST_CLASS=RECOVERY_FAILURE
        APO_LAST_REASON='The saved controller watchdog lease identity is invalid during cleanup.'
        return 1
    }
    output_file=$(mktemp "${APO_RUN_PREFIX}-controller-watchdog-release.XXXXXX") || {
        APO_LAST_CLASS=RECOVERY_FAILURE
        APO_LAST_REASON='Could not create the controller watchdog cleanup result file.'
        return 1
    }
    chmod 600 "$output_file"
    if ! apo_controller_watchdog_manager_capture release "$lease_id" "$output_file"; then
        rm -f -- "$output_file"
        return 1
    fi
    apo_parse_data_file "$output_file" APO_WORKER_DATA
    rm -f -- "$output_file"
    lease_count=${APO_WORKER_DATA[CONTROLLER_WATCHDOG_LEASE_COUNT]:-0}
    provider=${APO_WORKER_DATA[CONTROLLER_WATCHDOG_PROVIDER]:-absent}
    target=${APO_WORKER_DATA[CONTROLLER_WATCHDOG_TARGET]:-}
    [[ $lease_count =~ ^[0-9]+$ ]] || {
        APO_LAST_CLASS=HARNESS_FAILURE
        APO_LAST_REASON='The controller watchdog manager returned malformed cleanup evidence.'
        return 1
    }
    apo_state_set CONTROLLER_WATCHDOG_LEASED 0
    apo_state_set CONTROLLER_WATCHDOG_PROVIDER "$provider"
    apo_state_set CONTROLLER_WATCHDOG_TARGET "$target"
    apo_state_set CONTROLLER_WATCHDOG_LEASE_COUNT "$lease_count"
    apo_state_set CONTROLLER_WATCHDOG_STATUS RELEASED
    apo_state_save
    apo_event controller-watchdog-cleanup PASS '' "Run-owned controller watchdog lease released; active leases=$lease_count."
}
