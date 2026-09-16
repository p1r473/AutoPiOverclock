#!/usr/bin/env bash
# Raspberry Pi OS, Debian, and Ubuntu Pi-layout profile.

APO_PROFILE=debian
APO_LOCAL_WORKER="${APO_ROOT}/workers/debian-worker.sh"
APO_REMOTE_WORK_DIR="/tmp/autopioverclock-${APO_RUN_ID}"
APO_REMOTE_WORKER="${APO_REMOTE_WORK_DIR}/worker.sh"
APO_BOOT_TIMEOUT=300
APO_BOOT_SETTLE_SECONDS=15

apo_profile_dependencies_ready() {
    [[ ${APO_DISCOVERY[CPU_STRESS_AVAILABLE]:-0} == 1 ]] || return 1
    (( APO_REQUIRE_GPU_STRESS == 0 )) || [[ ${APO_DISCOVERY[GPU_STRESS_AVAILABLE]:-0} == 1 ]]
}

apo_profile_install_dependencies() {
    apo_event dependencies INFO '' 'Installing Debian stress dependency: stress-ng'
    if declare -F apo_progress_before_output >/dev/null 2>&1; then apo_progress_before_output; fi
    apo_remote_root 'export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get install -y --no-install-recommends stress-ng'
}

apo_profile_hardware_watchdogs_ready() {
    local boot_timeout=${APO_DISCOVERY[BOOT_WATCHDOG_TIMEOUT]:-0}
    local kernel_timeout=${APO_DISCOVERY[KERNEL_WATCHDOG_TIMEOUT]:-0}
    local runtime_value=${APO_DISCOVERY[RUNTIME_WATCHDOG]:-0}
    local watchdog_device=${APO_DISCOVERY[WATCHDOG_DEVICE]:-}
    local watchdog_runtime_timeout=${APO_DISCOVERY[WATCHDOG_RUNTIME_TIMEOUT]:-0}
    local watchdog_owner=${APO_DISCOVERY[WATCHDOG_OWNER]:-}
    apo_is_uint "$boot_timeout" && (( boot_timeout > 0 )) || return 1
    apo_is_uint "$kernel_timeout" && (( kernel_timeout > 0 )) || return 1
    [[ -n $runtime_value && $runtime_value != 0 && $runtime_value != 0s && $runtime_value != infinity ]] || return 1
    apo_is_uint "$watchdog_runtime_timeout" && (( watchdog_runtime_timeout > 0 )) || return 1
    [[ -n $watchdog_device && -n $watchdog_owner ]]
}

apo_profile_network_watchdog_ready() {
    [[ ( ${APO_DISCOVERY[NETWORK_WATCHDOG_KIND]:-} == debian-systemd-companion ||
         ${APO_DISCOVERY[NETWORK_WATCHDOG_KIND]:-} == debian-watchdog-observer ) &&
       ${APO_DISCOVERY[NETWORK_WATCHDOG_SERVICE_ACTIVE]:-0} == 1 &&
       ${APO_DISCOVERY[NETWORK_WATCHDOG_TARGET]:-} =~ ^[0-9]+([.][0-9]+){3}$ &&
       ${APO_DISCOVERY[NETWORK_WATCHDOG_CONFIG_HASH]:-} =~ ^[0-9a-f]{64}$ &&
       ${APO_DISCOVERY[NETWORK_WATCHDOG_KEEPER_HASH]:-} =~ ^[0-9a-f]{64}$ &&
       ${APO_DISCOVERY[NETWORK_WATCHDOG_SERVICE_HASH]:-} =~ ^[0-9a-f]{64}$ ]]
}

apo_profile_watchdogs_ready() {
    apo_profile_hardware_watchdogs_ready
}

apo_profile_watchdog_description() {
    printf 'EEPROM=%s kernel-handoff=%s systemd=%s device=%s runtime-timeout=%s owner=%s' \
        "${APO_DISCOVERY[BOOT_WATCHDOG_TIMEOUT]:-missing}" "${APO_DISCOVERY[KERNEL_WATCHDOG_TIMEOUT]:-missing}" \
        "${APO_DISCOVERY[RUNTIME_WATCHDOG]:-missing}" "${APO_DISCOVERY[WATCHDOG_DEVICE]:-missing}" \
        "${APO_DISCOVERY[WATCHDOG_RUNTIME_TIMEOUT]:-missing}" \
        "${APO_DISCOVERY[WATCHDOG_OWNER]:-missing}"
}

apo_profile_repair_hardware_watchdogs() {
    local expected="REPAIR-WATCHDOGS ${APO_TARGET_SLUG}" old_boot_id new_boot_id old_hash expected_hash repair_hash backup_file
    apo_run_worker_capture watchdog-repair-plan plan-watchdog-repair 60 || return 1
    apo_parse_data_file "$APO_LAST_WORKER_LOG" APO_WORKER_DATA
    old_hash=${APO_WORKER_DATA[WATCHDOG_REPAIR_OLD_HASH]:-}
    expected_hash=${APO_WORKER_DATA[WATCHDOG_REPAIR_EXPECTED_HASH]:-}
    if [[ ! $old_hash =~ ^[0-9a-f]{64}$ || ! $expected_hash =~ ^[0-9a-f]{64}$ || $old_hash != "$APO_PERMANENT_CONFIG_HASH" ]]; then
        apo_state_set WATCHDOG_REPAIR_STATUS PLAN_UNVERIFIED
        apo_state_save
        return 1
    fi
    apo_state_set PHASE PREPARE
    apo_state_set SUBPHASE WATCHDOG_REPAIR_PLANNED
    apo_state_set WATCHDOG_REPAIR_STATUS PLANNED
    apo_state_set WATCHDOG_REPAIR_OLD_HASH "$old_hash"
    apo_state_set WATCHDOG_REPAIR_EXPECTED_HASH "$expected_hash"
    apo_state_save
    if (( ${APO_AUTO_PREPARE:-0} == 1 )); then
        apo_info 'The explicit prepare command authorizes the planned Debian watchdog installation and verification.'
    else
        apo_confirm_exact "This preserves and updates the EEPROM config, appends a managed kernel-watchdog block, creates a systemd manager drop-in, and reboots ${APO_REMOTE_TARGET}." "$expected" || return 1
    fi
    apo_state_set MUTATIONS_STARTED 1
    apo_state_set WATCHDOG_REPAIR_STATUS MUTATING
    apo_state_set SUBPHASE WATCHDOG_REPAIR_MUTATING
    apo_state_save
    apo_run_worker_capture watchdog-repair repair-watchdogs 30 60 60 "$old_hash" "$expected_hash" || return 1
    apo_parse_data_file "$APO_LAST_WORKER_LOG" APO_WORKER_DATA
    repair_hash=${APO_WORKER_DATA[WATCHDOG_REPAIR_NEW_HASH]:-}
    backup_file=${APO_WORKER_DATA[WATCHDOG_CONFIG_BACKUP]:-}
    if [[ $repair_hash != "$expected_hash" || -z $backup_file ]]; then
        apo_state_set WATCHDOG_REPAIR_STATUS RESULT_UNVERIFIED
        apo_state_save
        return 1
    fi
    apo_state_set WATCHDOG_REPAIR_STATUS STAGED
    apo_state_set WATCHDOG_REPAIR_NEW_HASH "$repair_hash"
    apo_state_set WATCHDOG_REPAIR_BACKUP "$backup_file"
    apo_state_save
    old_boot_id=$(apo_remote_boot_id) || return 1
    apo_state_set WATCHDOG_REPAIR_STATUS REBOOTING
    apo_state_set LAST_BOOT_ID "$old_boot_id"
    apo_state_save
    apo_remote_worker "$APO_REMOTE_WORKER" reboot-normal >/dev/null 2>&1 || true
    if ! apo_post_reboot_handshake "$old_boot_id" "$APO_BOOT_TIMEOUT" watchdog-repair; then
        APO_LAST_CLASS=RECOVERY_FAILURE
        if [[ ${APO_REBOOT_HANDSHAKE_STAGE:-wait} == worker ]]; then
            APO_LAST_REASON="The watchdog verification reboot returned, but its transient worker could not be restored: $APO_LAST_REASON"
        else
            APO_LAST_REASON='The watchdog verification reboot did not return to SSH.'
        fi
        return 1
    fi
    new_boot_id=$APO_REBOOT_BOOT_ID
    apo_state_set WATCHDOG_REPAIR_STATUS REBOOTED
    apo_state_set LAST_BOOT_ID "$new_boot_id"
    apo_state_set NORMAL_BOOT_ID "$new_boot_id"
    apo_state_save
    sleep "$APO_BOOT_SETTLE_SECONDS"
}

apo_profile_install_network_watchdog() {
    local local_asset_dir=${APO_ROOT}/assets/debian remote_asset_dir=${APO_REMOTE_WORK_DIR}/network-watchdog-assets
    local local_installer=$local_asset_dir/install_network_watchdog.sh
    local local_keeper=$local_asset_dir/network_watchdog_keeper.py
    local local_service=$local_asset_dir/autopioverclock-network-watchdog.service
    local remote_installer=$remote_asset_dir/install_network_watchdog.sh
    local remote_keeper=$remote_asset_dir/network_watchdog_keeper.py
    local remote_service=$remote_asset_dir/autopioverclock-network-watchdog.service
    local target keeper_hash service_hash config_hash old_keeper_hash old_service_hash old_config_hash old_enabled old_active
    local reported_target reported_config_hash backup_path local_keeper_hash local_service_hash
    [[ -r $local_installer && -r $local_keeper && -r $local_service ]] || {
        APO_LAST_CLASS=PREFLIGHT_FAILURE
        APO_LAST_REASON='The packaged Debian network-watchdog assets are missing.'
        return 1
    }
    apo_remote_upload_root "$local_installer" "$remote_installer" || return 1
    apo_remote_upload_root "$local_keeper" "$remote_keeper" || return 1
    apo_remote_upload_root "$local_service" "$remote_service" || return 1
    apo_run_worker_capture network-watchdog-plan plan-network-watchdog \
        "$remote_installer" "$remote_keeper" "$remote_service" "$APO_RUN_ID" || return 1
    apo_parse_data_file "$APO_LAST_WORKER_LOG" APO_WORKER_DATA
    target=${APO_WORKER_DATA[NETWORK_WATCHDOG_TARGET]:-}
    keeper_hash=${APO_WORKER_DATA[NETWORK_WATCHDOG_KEEPER_HASH]:-}
    service_hash=${APO_WORKER_DATA[NETWORK_WATCHDOG_SERVICE_HASH]:-}
    config_hash=${APO_WORKER_DATA[NETWORK_WATCHDOG_CONFIG_HASH]:-}
    old_keeper_hash=${APO_WORKER_DATA[NETWORK_WATCHDOG_OLD_KEEPER_HASH]:-}
    old_service_hash=${APO_WORKER_DATA[NETWORK_WATCHDOG_OLD_SERVICE_HASH]:-}
    old_config_hash=${APO_WORKER_DATA[NETWORK_WATCHDOG_OLD_CONFIG_HASH]:-}
    old_enabled=${APO_WORKER_DATA[NETWORK_WATCHDOG_OLD_SERVICE_ENABLED]:-}
    old_active=${APO_WORKER_DATA[NETWORK_WATCHDOG_OLD_SERVICE_ACTIVE]:-}
    local_keeper_hash=$(sha256sum "$local_keeper" | awk 'NR == 1 {print $1}')
    local_service_hash=$(sha256sum "$local_service" | awk 'NR == 1 {print $1}')
    if [[ ! $target =~ ^[0-9]+([.][0-9]+){3}$ || $keeper_hash != "$local_keeper_hash" ||
          $service_hash != "$local_service_hash" || ! $config_hash =~ ^[0-9a-f]{64}$ ||
          ! $old_keeper_hash =~ ^(absent|[0-9a-f]{64})$ ||
          ! $old_service_hash =~ ^(absent|[0-9a-f]{64})$ ||
          ! $old_config_hash =~ ^(absent|[0-9a-f]{64})$ ||
          ( $old_enabled != 0 && $old_enabled != 1 ) || ( $old_active != 0 && $old_active != 1 ) ]]; then
        APO_LAST_CLASS=PREFLIGHT_FAILURE
        APO_LAST_REASON='The Debian network-watchdog installation plan could not be verified.'
        return 1
    fi
    apo_state_set NETWORK_WATCHDOG_INSTALL_KIND debian-systemd-companion
    apo_state_set NETWORK_WATCHDOG_INSTALL_TARGET "$target"
    apo_state_set NETWORK_WATCHDOG_INSTALL_CONFIG_HASH "$config_hash"
    apo_state_set NETWORK_WATCHDOG_INSTALL_KEEPER_HASH "$keeper_hash"
    apo_state_set NETWORK_WATCHDOG_INSTALL_SERVICE_HASH "$service_hash"
    apo_state_set NETWORK_WATCHDOG_INSTALL_OLD_KEEPER_HASH "$old_keeper_hash"
    apo_state_set NETWORK_WATCHDOG_INSTALL_OLD_SERVICE_HASH "$old_service_hash"
    apo_state_set NETWORK_WATCHDOG_INSTALL_OLD_CONFIG_HASH "$old_config_hash"
    apo_state_set NETWORK_WATCHDOG_INSTALL_OLD_SERVICE_ENABLED "$old_enabled"
    apo_state_set NETWORK_WATCHDOG_INSTALL_OLD_SERVICE_ACTIVE "$old_active"
    apo_state_set NETWORK_WATCHDOG_INSTALL_STATUS PLANNED
    apo_state_save
    apo_state_set MUTATIONS_STARTED 1
    apo_state_set NETWORK_WATCHDOG_INSTALL_STATUS MUTATING
    apo_state_save
    apo_run_worker_capture network-watchdog-install install-network-watchdog \
        "$remote_installer" "$remote_keeper" "$remote_service" "$APO_RUN_ID" "$target" \
        "$keeper_hash" "$service_hash" "$config_hash" "$old_keeper_hash" "$old_service_hash" "$old_config_hash" \
        "$old_enabled" "$old_active" || return 1
    apo_parse_data_file "$APO_LAST_WORKER_LOG" APO_WORKER_DATA
    reported_target=${APO_WORKER_DATA[NETWORK_WATCHDOG_TARGET]:-}
    reported_config_hash=${APO_WORKER_DATA[NETWORK_WATCHDOG_CONFIG_HASH]:-}
    backup_path=${APO_WORKER_DATA[NETWORK_WATCHDOG_BACKUP]:-}
    if [[ $reported_target != "$target" || $reported_config_hash != "$config_hash" || -z $backup_path ]]; then
        APO_LAST_CLASS=PREFLIGHT_FAILURE
        APO_LAST_REASON='The installed Debian network-watchdog result could not be matched to its plan.'
        apo_state_set NETWORK_WATCHDOG_INSTALL_STATUS RESULT_UNVERIFIED
        apo_state_save
        return 1
    fi
    apo_state_set NETWORK_WATCHDOG_INSTALLED_BY_RUN 1
    apo_state_set NETWORK_WATCHDOG_INSTALL_KIND debian-systemd-companion
    apo_state_set NETWORK_WATCHDOG_INSTALL_TARGET "$target"
    apo_state_set NETWORK_WATCHDOG_INSTALL_BACKUP "$backup_path"
    apo_state_set NETWORK_WATCHDOG_INSTALL_CONFIG_HASH "$config_hash"
    apo_state_set NETWORK_WATCHDOG_INSTALL_KEEPER_HASH "$keeper_hash"
    apo_state_set NETWORK_WATCHDOG_INSTALL_SERVICE_HASH "$service_hash"
    apo_state_set NETWORK_WATCHDOG_INSTALL_OLD_KEEPER_HASH "$old_keeper_hash"
    apo_state_set NETWORK_WATCHDOG_INSTALL_OLD_SERVICE_HASH "$old_service_hash"
    apo_state_set NETWORK_WATCHDOG_INSTALL_OLD_CONFIG_HASH "$old_config_hash"
    apo_state_set NETWORK_WATCHDOG_INSTALL_OLD_SERVICE_ENABLED "$old_enabled"
    apo_state_set NETWORK_WATCHDOG_INSTALL_OLD_SERVICE_ACTIVE "$old_active"
    apo_state_set NETWORK_WATCHDOG_INSTALL_STATUS INSTALLED
    apo_state_save
}

apo_profile_install_network_watchdog_observer() {
    local local_asset_dir=${APO_ROOT}/assets/debian remote_asset_dir=${APO_REMOTE_WORK_DIR}/network-watchdog-observer-assets
    local local_installer=$local_asset_dir/install_network_watchdog_observer.sh
    local local_observer=$local_asset_dir/network_watchdog_observer.py
    local local_service=$local_asset_dir/autopioverclock-network-watchdog-observer.service
    local remote_installer=$remote_asset_dir/install_network_watchdog_observer.sh
    local remote_observer=$remote_asset_dir/network_watchdog_observer.py
    local remote_service=$remote_asset_dir/autopioverclock-network-watchdog-observer.service
    local target observer_hash service_hash config_hash old_observer_hash old_service_hash old_config_hash old_enabled old_active
    local reported_target reported_config_hash backup_path local_observer_hash local_service_hash
    [[ -r $local_installer && -r $local_observer && -r $local_service ]] || {
        APO_LAST_CLASS=PREFLIGHT_FAILURE
        APO_LAST_REASON='The packaged Debian watchdog-observer assets are missing.'
        return 1
    }
    apo_remote_upload_root "$local_installer" "$remote_installer" || return 1
    apo_remote_upload_root "$local_observer" "$remote_observer" || return 1
    apo_remote_upload_root "$local_service" "$remote_service" || return 1
    apo_run_worker_capture network-watchdog-observer-plan plan-network-watchdog-observer \
        "$remote_installer" "$remote_observer" "$remote_service" "$APO_RUN_ID" || return 1
    apo_parse_data_file "$APO_LAST_WORKER_LOG" APO_WORKER_DATA
    target=${APO_WORKER_DATA[NETWORK_WATCHDOG_TARGET]:-}
    observer_hash=${APO_WORKER_DATA[NETWORK_WATCHDOG_KEEPER_HASH]:-}
    service_hash=${APO_WORKER_DATA[NETWORK_WATCHDOG_SERVICE_HASH]:-}
    config_hash=${APO_WORKER_DATA[NETWORK_WATCHDOG_CONFIG_HASH]:-}
    old_observer_hash=${APO_WORKER_DATA[NETWORK_WATCHDOG_OLD_KEEPER_HASH]:-}
    old_service_hash=${APO_WORKER_DATA[NETWORK_WATCHDOG_OLD_SERVICE_HASH]:-}
    old_config_hash=${APO_WORKER_DATA[NETWORK_WATCHDOG_OLD_CONFIG_HASH]:-}
    old_enabled=${APO_WORKER_DATA[NETWORK_WATCHDOG_OLD_SERVICE_ENABLED]:-}
    old_active=${APO_WORKER_DATA[NETWORK_WATCHDOG_OLD_SERVICE_ACTIVE]:-}
    local_observer_hash=$(sha256sum "$local_observer" | awk 'NR == 1 {print $1}')
    local_service_hash=$(sha256sum "$local_service" | awk 'NR == 1 {print $1}')
    if [[ ! $target =~ ^[0-9]+([.][0-9]+){3}$ || $observer_hash != "$local_observer_hash" ||
          $service_hash != "$local_service_hash" || ! $config_hash =~ ^[0-9a-f]{64}$ ||
          ! $old_observer_hash =~ ^(absent|[0-9a-f]{64})$ || ! $old_service_hash =~ ^(absent|[0-9a-f]{64})$ ||
          ! $old_config_hash =~ ^(absent|[0-9a-f]{64})$ ||
          ( $old_enabled != 0 && $old_enabled != 1 ) || ( $old_active != 0 && $old_active != 1 ) ]]; then
        APO_LAST_CLASS=PREFLIGHT_FAILURE
        APO_LAST_REASON='The Debian watchdog-observer installation plan could not be verified.'
        return 1
    fi
    apo_state_set NETWORK_WATCHDOG_INSTALL_KIND debian-watchdog-observer
    apo_state_set NETWORK_WATCHDOG_INSTALL_TARGET "$target"
    apo_state_set NETWORK_WATCHDOG_INSTALL_CONFIG_HASH "$config_hash"
    apo_state_set NETWORK_WATCHDOG_INSTALL_KEEPER_HASH "$observer_hash"
    apo_state_set NETWORK_WATCHDOG_INSTALL_SERVICE_HASH "$service_hash"
    apo_state_set NETWORK_WATCHDOG_INSTALL_OLD_KEEPER_HASH "$old_observer_hash"
    apo_state_set NETWORK_WATCHDOG_INSTALL_OLD_SERVICE_HASH "$old_service_hash"
    apo_state_set NETWORK_WATCHDOG_INSTALL_OLD_CONFIG_HASH "$old_config_hash"
    apo_state_set NETWORK_WATCHDOG_INSTALL_OLD_SERVICE_ENABLED "$old_enabled"
    apo_state_set NETWORK_WATCHDOG_INSTALL_OLD_SERVICE_ACTIVE "$old_active"
    apo_state_set NETWORK_WATCHDOG_INSTALL_STATUS PLANNED
    apo_state_save
    apo_state_set MUTATIONS_STARTED 1
    apo_state_set NETWORK_WATCHDOG_INSTALL_STATUS MUTATING
    apo_state_save
    apo_run_worker_capture network-watchdog-observer-install install-network-watchdog-observer \
        "$remote_installer" "$remote_observer" "$remote_service" "$APO_RUN_ID" "$target" \
        "$observer_hash" "$service_hash" "$config_hash" "$old_observer_hash" "$old_service_hash" "$old_config_hash" \
        "$old_enabled" "$old_active" || return 1
    apo_parse_data_file "$APO_LAST_WORKER_LOG" APO_WORKER_DATA
    reported_target=${APO_WORKER_DATA[NETWORK_WATCHDOG_TARGET]:-}
    reported_config_hash=${APO_WORKER_DATA[NETWORK_WATCHDOG_CONFIG_HASH]:-}
    backup_path=${APO_WORKER_DATA[NETWORK_WATCHDOG_BACKUP]:-}
    [[ $reported_target == "$target" && $reported_config_hash == "$config_hash" && -n $backup_path ]] || {
        APO_LAST_CLASS=PREFLIGHT_FAILURE
        APO_LAST_REASON='The installed Debian watchdog-observer result could not be matched to its plan.'
        apo_state_set NETWORK_WATCHDOG_INSTALL_STATUS RESULT_UNVERIFIED
        apo_state_save
        return 1
    }
    apo_state_set NETWORK_WATCHDOG_INSTALLED_BY_RUN 1
    apo_state_set NETWORK_WATCHDOG_INSTALL_KIND debian-watchdog-observer
    apo_state_set NETWORK_WATCHDOG_INSTALL_TARGET "$target"
    apo_state_set NETWORK_WATCHDOG_INSTALL_BACKUP "$backup_path"
    apo_state_set NETWORK_WATCHDOG_INSTALL_CONFIG_HASH "$config_hash"
    apo_state_set NETWORK_WATCHDOG_INSTALL_KEEPER_HASH "$observer_hash"
    apo_state_set NETWORK_WATCHDOG_INSTALL_SERVICE_HASH "$service_hash"
    apo_state_set NETWORK_WATCHDOG_INSTALL_OLD_KEEPER_HASH "$old_observer_hash"
    apo_state_set NETWORK_WATCHDOG_INSTALL_OLD_SERVICE_HASH "$old_service_hash"
    apo_state_set NETWORK_WATCHDOG_INSTALL_OLD_CONFIG_HASH "$old_config_hash"
    apo_state_set NETWORK_WATCHDOG_INSTALL_OLD_SERVICE_ENABLED "$old_enabled"
    apo_state_set NETWORK_WATCHDOG_INSTALL_OLD_SERVICE_ACTIVE "$old_active"
    apo_state_set NETWORK_WATCHDOG_INSTALL_STATUS INSTALLED
    apo_state_save
}

apo_profile_reconcile_network_watchdog_install() {
    local kind target live_run=${APO_DISCOVERY[NETWORK_WATCHDOG_INSTALL_RUN_ID]:-}
    local local_asset_dir=${APO_ROOT}/assets/debian remote_asset_dir=${APO_REMOTE_WORK_DIR}/network-watchdog-reconcile-assets
    local local_installer local_keeper local_service remote_installer remote_keeper remote_service worker_command
    local keeper_hash service_hash config_hash old_keeper_hash old_service_hash old_config_hash old_enabled old_active
    local reported_target reported_config_hash backup_path local_keeper_hash local_service_hash
    kind=$(apo_state_get NETWORK_WATCHDOG_INSTALL_KIND '')
    target=$(apo_state_get NETWORK_WATCHDOG_INSTALL_TARGET '')
    [[ -z $live_run || $live_run == "$APO_RUN_ID" ]] || {
        APO_LAST_CLASS=RECOVERY_FAILURE
        APO_LAST_REASON='A foreign Debian network-watchdog installation occupies the protected project paths.'
        return 1
    }
    case $kind in
        debian-watchdog-observer)
            local_installer=$local_asset_dir/install_network_watchdog_observer.sh
            local_keeper=$local_asset_dir/network_watchdog_observer.py
            local_service=$local_asset_dir/autopioverclock-network-watchdog-observer.service
            remote_installer=$remote_asset_dir/install_network_watchdog_observer.sh
            remote_keeper=$remote_asset_dir/network_watchdog_observer.py
            remote_service=$remote_asset_dir/autopioverclock-network-watchdog-observer.service
            worker_command=install-network-watchdog-observer
            ;;
        debian-systemd-companion)
            local_installer=$local_asset_dir/install_network_watchdog.sh
            local_keeper=$local_asset_dir/network_watchdog_keeper.py
            local_service=$local_asset_dir/autopioverclock-network-watchdog.service
            remote_installer=$remote_asset_dir/install_network_watchdog.sh
            remote_keeper=$remote_asset_dir/network_watchdog_keeper.py
            remote_service=$remote_asset_dir/autopioverclock-network-watchdog.service
            worker_command=install-network-watchdog
            ;;
        *) return 1 ;;
    esac
    keeper_hash=$(apo_state_get NETWORK_WATCHDOG_INSTALL_KEEPER_HASH '')
    service_hash=$(apo_state_get NETWORK_WATCHDOG_INSTALL_SERVICE_HASH '')
    config_hash=$(apo_state_get NETWORK_WATCHDOG_INSTALL_CONFIG_HASH '')
    old_keeper_hash=$(apo_state_get NETWORK_WATCHDOG_INSTALL_OLD_KEEPER_HASH '')
    old_service_hash=$(apo_state_get NETWORK_WATCHDOG_INSTALL_OLD_SERVICE_HASH '')
    old_config_hash=$(apo_state_get NETWORK_WATCHDOG_INSTALL_OLD_CONFIG_HASH '')
    old_enabled=$(apo_state_get NETWORK_WATCHDOG_INSTALL_OLD_SERVICE_ENABLED '')
    old_active=$(apo_state_get NETWORK_WATCHDOG_INSTALL_OLD_SERVICE_ACTIVE '')
    [[ -r $local_installer && -r $local_keeper && -r $local_service &&
       $target =~ ^[0-9]+([.][0-9]+){3}$ && $keeper_hash =~ ^[0-9a-f]{64}$ &&
       $service_hash =~ ^[0-9a-f]{64}$ && $config_hash =~ ^[0-9a-f]{64}$ &&
       $old_keeper_hash =~ ^(absent|[0-9a-f]{64})$ && $old_service_hash =~ ^(absent|[0-9a-f]{64})$ &&
       $old_config_hash =~ ^(absent|[0-9a-f]{64})$ && ( $old_enabled == 0 || $old_enabled == 1 ) &&
       ( $old_active == 0 || $old_active == 1 ) ]] || {
        APO_LAST_CLASS=RECOVERY_FAILURE
        APO_LAST_REASON='The interrupted Debian network-watchdog checkpoint is incomplete.'
        return 1
    }
    local_keeper_hash=$(sha256sum "$local_keeper" | awk 'NR == 1 {print $1}')
    local_service_hash=$(sha256sum "$local_service" | awk 'NR == 1 {print $1}')
    [[ $keeper_hash == "$local_keeper_hash" && $service_hash == "$local_service_hash" ]] || {
        APO_LAST_CLASS=RECOVERY_FAILURE
        APO_LAST_REASON='The packaged Debian network-watchdog assets changed after the interrupted installation checkpoint.'
        return 1
    }
    apo_remote_upload_root "$local_installer" "$remote_installer" || return 1
    apo_remote_upload_root "$local_keeper" "$remote_keeper" || return 1
    apo_remote_upload_root "$local_service" "$remote_service" || return 1
    apo_state_set NETWORK_WATCHDOG_INSTALL_STATUS RECONCILING
    apo_state_save
    apo_run_worker_capture network-watchdog-reconcile "$worker_command" \
        "$remote_installer" "$remote_keeper" "$remote_service" "$APO_RUN_ID" "$target" \
        "$keeper_hash" "$service_hash" "$config_hash" "$old_keeper_hash" "$old_service_hash" "$old_config_hash" \
        "$old_enabled" "$old_active" || return 1
    apo_parse_data_file "$APO_LAST_WORKER_LOG" APO_WORKER_DATA
    reported_target=${APO_WORKER_DATA[NETWORK_WATCHDOG_TARGET]:-}
    reported_config_hash=${APO_WORKER_DATA[NETWORK_WATCHDOG_CONFIG_HASH]:-}
    backup_path=${APO_WORKER_DATA[NETWORK_WATCHDOG_BACKUP]:-}
    [[ $reported_target == "$target" && $reported_config_hash == "$config_hash" && -n $backup_path ]] || {
        APO_LAST_CLASS=RECOVERY_FAILURE
        APO_LAST_REASON='The reconciled Debian network-watchdog result could not be matched to its checkpoint.'
        apo_state_set NETWORK_WATCHDOG_INSTALL_STATUS RESULT_UNVERIFIED
        apo_state_save
        return 1
    }
    apo_state_set NETWORK_WATCHDOG_INSTALLED_BY_RUN 1
    apo_state_set NETWORK_WATCHDOG_INSTALL_BACKUP "$backup_path"
    apo_state_set NETWORK_WATCHDOG_INSTALL_STATUS INSTALLED
    apo_state_save
    apo_event network-watchdog-reconcile PASS '' 'Reconciled the interrupted run-owned Debian watchdog installation from hash-bound target evidence.'
}

apo_profile_install_best_network_watchdog() {
    if [[ ${APO_DISCOVERY[NATIVE_NETWORK_WATCHDOG_READY]:-0} == 1 ]]; then
        apo_profile_install_network_watchdog_observer || return 1
        APO_LAST_CLASS=''
        APO_LAST_REASON=''
        apo_info 'Installed a passive proof observer without changing the native Debian watchdog configuration or repair command.'
        return 0
    fi
    if [[ ${APO_DISCOVERY[NATIVE_NETWORK_WATCHDOG_PRESENT]:-0} == 1 ]]; then
        APO_LAST_CLASS=PREFLIGHT_FAILURE
        APO_LAST_REASON='An active native Debian network watchdog was found, but its ping configuration is not safe for passive proof. The run will not add a second network watcher or change the native configuration.'
        return 1
    fi
    apo_event network-watchdog-fallback INFO '' 'No active supported Debian network watchdog was available for passive observation; installing the isolated run-owned gateway watcher.'
    apo_profile_install_network_watchdog
}

apo_profile_network_watchdog_packaged_hashes() {
    local kind=$1 keeper_output=$2 service_output=$3 keeper_path service_path keeper_hash service_hash
    case $kind in
        debian-watchdog-observer)
            keeper_path=${APO_ROOT}/assets/debian/network_watchdog_observer.py
            service_path=${APO_ROOT}/assets/debian/autopioverclock-network-watchdog-observer.service
            ;;
        debian-systemd-companion)
            keeper_path=${APO_ROOT}/assets/debian/network_watchdog_keeper.py
            service_path=${APO_ROOT}/assets/debian/autopioverclock-network-watchdog.service
            ;;
        *) return 1 ;;
    esac
    [[ -r $keeper_path && -r $service_path ]] || return 1
    keeper_hash=$(sha256sum "$keeper_path" | awk 'NR == 1 {print $1}')
    service_hash=$(sha256sum "$service_path" | awk 'NR == 1 {print $1}')
    [[ $keeper_hash =~ ^[0-9a-f]{64}$ && $service_hash =~ ^[0-9a-f]{64}$ ]] || return 1
    printf -v "$keeper_output" '%s' "$keeper_hash"
    printf -v "$service_output" '%s' "$service_hash"
}

apo_profile_reconcile_network_watchdog_provider() {
    local protected_hash=${1:-} current_kind desired_kind live_run live_backup state_kind
    local packaged_keeper_hash='' packaged_service_hash='' refresh_required=0 action=migration
    APO_NETWORK_WATCHDOG_PROVIDER_CHANGED=0
    current_kind=${APO_DISCOVERY[NETWORK_WATCHDOG_KIND]:-}
    case $current_kind in
        debian-systemd-companion)
            if [[ ${APO_DISCOVERY[NATIVE_NETWORK_WATCHDOG_READY]:-0} == 1 ]]; then
                desired_kind=debian-watchdog-observer
            elif [[ ${APO_DISCOVERY[NATIVE_WATCHDOG_SERVICE_ACTIVE]:-0} == 1 ||
                    ${APO_DISCOVERY[NATIVE_NETWORK_WATCHDOG_PRESENT]:-0} == 1 ]]; then
                APO_LAST_CLASS=PREFLIGHT_FAILURE
                APO_LAST_REASON='The native Debian watchdog became active but is not safe for passive proof. The run will not keep a second rebooting watcher or change the native configuration.'
                return 1
            else
                desired_kind=debian-systemd-companion
            fi
            ;;
        debian-watchdog-observer)
            if [[ ${APO_DISCOVERY[NATIVE_NETWORK_WATCHDOG_READY]:-0} == 1 ]]; then
                desired_kind=debian-watchdog-observer
            elif [[ ${APO_DISCOVERY[NATIVE_WATCHDOG_SERVICE_ACTIVE]:-0} == 1 ||
                  ${APO_DISCOVERY[NATIVE_NETWORK_WATCHDOG_PRESENT]:-0} == 1 ]]; then
                APO_LAST_CLASS=PREFLIGHT_FAILURE
                APO_LAST_REASON='The active native Debian watchdog is no longer safe for passive proof. The run will not replace it or add a second rebooting watcher.'
                return 1
            else
                desired_kind=debian-systemd-companion
            fi
            ;;
        *) return 0 ;;
    esac

    live_run=${APO_DISCOVERY[NETWORK_WATCHDOG_INSTALL_RUN_ID]:-}
    live_backup=${APO_DISCOVERY[NETWORK_WATCHDOG_INSTALL_BACKUP]:-}
    state_kind=$(apo_state_get NETWORK_WATCHDOG_INSTALL_KIND '')
    [[ $(apo_state_get NETWORK_WATCHDOG_INSTALLED_BY_RUN 0) == 1 &&
       $live_run == "$APO_RUN_ID" && -n $live_backup && $current_kind == "$state_kind" &&
       ${APO_DISCOVERY[NETWORK_WATCHDOG_CONFIG_HASH]:-} == "$(apo_state_get NETWORK_WATCHDOG_INSTALL_CONFIG_HASH '')" &&
       ${APO_DISCOVERY[NETWORK_WATCHDOG_KEEPER_HASH]:-} == "$(apo_state_get NETWORK_WATCHDOG_INSTALL_KEEPER_HASH '')" &&
       ${APO_DISCOVERY[NETWORK_WATCHDOG_SERVICE_HASH]:-} == "$(apo_state_get NETWORK_WATCHDOG_INSTALL_SERVICE_HASH '')" ]] || {
        APO_LAST_CLASS=RECOVERY_FAILURE
        APO_LAST_REASON='The run-owned Debian watchdog provider cannot be migrated because its live ownership hashes no longer match the checkpoint.'
        return 1
    }
    if [[ $current_kind == "$desired_kind" ]]; then
        if ! apo_profile_network_watchdog_packaged_hashes "$current_kind" packaged_keeper_hash packaged_service_hash; then
            APO_LAST_CLASS=RECOVERY_FAILURE
            APO_LAST_REASON='The packaged Debian network-watchdog assets could not be hashed for live refresh.'
            return 1
        fi
        if [[ ${APO_DISCOVERY[NETWORK_WATCHDOG_KEEPER_HASH]:-} == "$packaged_keeper_hash" &&
              ${APO_DISCOVERY[NETWORK_WATCHDOG_SERVICE_HASH]:-} == "$packaged_service_hash" ]]; then
            return 0
        fi
        refresh_required=1
        action=refresh
    fi
    [[ $protected_hash =~ ^[0-9a-f]{64}$ ]] || {
        APO_LAST_CLASS=RECOVERY_FAILURE
        APO_LAST_REASON='The protected permanent config hash is unavailable for the Debian watchdog-provider migration.'
        return 1
    }

    if (( refresh_required == 1 )); then
        apo_event network-watchdog-provider-refresh INFO '' \
            "Refreshing the run-owned Debian watchdog proof provider $current_kind from hash-verified packaged assets without changing the native watchdog configuration or repair command."
    else
        apo_event network-watchdog-provider-migration INFO '' \
            "Migrating the run-owned Debian watchdog proof provider from $current_kind to $desired_kind without changing the native watchdog configuration or repair command."
    fi
    apo_profile_cleanup_run_watchdog || return 1
    apo_discovery_capture || return 1
    [[ ${APO_DISCOVERY[PROFILE]:-} == "$APO_PROFILE" &&
       ${APO_DISCOVERY[PERMANENT_HASH]:-} == "$protected_hash" ]] || {
        APO_LAST_CLASS=RECOVERY_FAILURE
        APO_LAST_REASON='The target profile or protected permanent config changed while migrating the Debian watchdog proof provider.'
        return 1
    }
    case $desired_kind in
        debian-watchdog-observer)
            [[ ${APO_DISCOVERY[NATIVE_NETWORK_WATCHDOG_READY]:-0} == 1 ]] || {
                APO_LAST_CLASS=PREFLIGHT_FAILURE
                APO_LAST_REASON='The native Debian watchdog stopped or changed before passive observer installation.'
                return 1
            }
            apo_profile_install_network_watchdog_observer || return 1
            ;;
        debian-systemd-companion)
            [[ ${APO_DISCOVERY[NATIVE_WATCHDOG_SERVICE_ACTIVE]:-0} == 0 &&
               ${APO_DISCOVERY[NATIVE_NETWORK_WATCHDOG_PRESENT]:-0} == 0 ]] || {
                APO_LAST_CLASS=PREFLIGHT_FAILURE
                APO_LAST_REASON='The native Debian watchdog became active before fallback-companion installation.'
                return 1
            }
            apo_profile_install_network_watchdog || return 1
            ;;
        *)
            APO_LAST_CLASS=PREFLIGHT_FAILURE
            APO_LAST_REASON='The Debian watchdog-provider migration selected an unsupported destination.'
            return 1
            ;;
    esac
    APO_NETWORK_WATCHDOG_PROVIDER_CHANGED=1
    if [[ $action == refresh ]]; then
        apo_event network-watchdog-provider-refresh PASS '' \
            "Refreshed the run-owned Debian watchdog proof provider $current_kind from hash-verified packaged assets; the native watchdog configuration and repair command were not changed."
    else
        apo_event network-watchdog-provider-migration PASS '' \
            "Migrated the run-owned Debian watchdog proof provider from $current_kind to $desired_kind; the native watchdog configuration and repair command were not changed."
    fi
}

apo_profile_prove_network_watchdog_reboot() {
    local context=$1 old_boot=$2 new_boot=$3 output_file='' rc attempt attempts=${APO_TRANSIENT_WORKER_ATTEMPTS:-5}
    local expected_kind expected_target expected_config_hash expected_keeper_hash expected_service_hash previous_event
    expected_kind=$(apo_state_get DISC_NETWORK_WATCHDOG_KIND '')
    expected_target=$(apo_state_get DISC_NETWORK_WATCHDOG_TARGET '')
    expected_config_hash=$(apo_state_get DISC_NETWORK_WATCHDOG_CONFIG_HASH '')
    expected_keeper_hash=$(apo_state_get DISC_NETWORK_WATCHDOG_KEEPER_HASH '')
    expected_service_hash=$(apo_state_get DISC_NETWORK_WATCHDOG_SERVICE_HASH '')
    previous_event=$(apo_state_get NETWORK_WATCHDOG_LAST_EVENT_ID '')
    APO_NETWORK_WATCHDOG_EVENT_ID=''
    APO_NETWORK_WATCHDOG_TARGET=''
    APO_NETWORK_WATCHDOG_REQUESTED_EPOCH=''
    [[ $attempts =~ ^[1-9][0-9]*$ ]] || attempts=5
    for (( attempt=1; attempt<=attempts; attempt++ )); do
        # Keep the worker status separate from its complete output. The exact-file
        # SSH reader discards output on any nonzero status and performs its own
        # 30-attempt loop, neither of which is valid for a structured proof miss.
        if apo_run_worker_capture_once "${context}-network-watchdog-proof" prove-network-watchdog-reboot \
            "$old_boot" "$new_boot" "$expected_target" "$expected_config_hash" \
            "$expected_keeper_hash" "$expected_service_hash" "$expected_kind" "$previous_event"; then
            rc=0
        else
            rc=$?
        fi
        output_file=$APO_LAST_WORKER_LOG
        if (( rc == 0 )) && [[ $APO_LAST_CLASS == PASS ]]; then break; fi
        if (( attempt >= attempts )); then
            apo_event "${context}-network-watchdog-proof-failed" WARN '' \
                "Strict network-watchdog evidence remained incomplete after $attempts read-only captures; class=${APO_LAST_CLASS:-missing} capture=${APO_LAST_WORKER_CAPTURE_KIND:-unknown} status=${APO_LAST_WORKER_PIPE_STATUS:-unknown}: ${APO_LAST_REASON:-no structured reason}."
            return 1
        fi
        apo_event "${context}-network-watchdog-proof-retry" WARN '' \
            "Strict network-watchdog evidence is not complete yet; class=${APO_LAST_CLASS:-missing} capture=${APO_LAST_WORKER_CAPTURE_KIND:-unknown} status=${APO_LAST_WORKER_PIPE_STATUS:-unknown}: ${APO_LAST_REASON:-no structured reason}. Retrying one read-only capture (attempt $((attempt + 1))/$attempts)."
        if declare -F apo_transient_read_delay >/dev/null 2>&1; then apo_transient_read_delay; else sleep 10; fi
    done
    apo_parse_data_file "$output_file" APO_WORKER_DATA
    APO_NETWORK_WATCHDOG_EVENT_ID=${APO_WORKER_DATA[NETWORK_WATCHDOG_EVENT_ID]:-}
    APO_NETWORK_WATCHDOG_TARGET=${APO_WORKER_DATA[NETWORK_WATCHDOG_TARGET]:-}
    APO_NETWORK_WATCHDOG_REQUESTED_EPOCH=${APO_WORKER_DATA[NETWORK_WATCHDOG_REQUESTED_EPOCH]:-}
    [[ $APO_NETWORK_WATCHDOG_EVENT_ID =~ ^[0-9a-f]{32}$ &&
       $APO_NETWORK_WATCHDOG_TARGET == "$expected_target" &&
       $APO_NETWORK_WATCHDOG_REQUESTED_EPOCH =~ ^[1-9][0-9]*$ &&
       ${APO_WORKER_DATA[NETWORK_WATCHDOG_SOURCE_BOOT_ID]:-} == "$old_boot" ]] || return 1
    APO_NETWORK_WATCHDOG_PROOF_REASON="Project-owned Debian watchdog evidence proves that liveness target $APO_NETWORK_WATCHDOG_TARGET caused the reboot from boot $old_boot."
}

apo_profile_repair_watchdogs() {
    local hardware_ready=0 expected_hash=$APO_PERMANENT_CONFIG_HASH
    if apo_profile_hardware_watchdogs_ready; then hardware_ready=1; fi
    if (( hardware_ready == 0 )); then
        apo_profile_repair_hardware_watchdogs || return 1
        expected_hash=$(apo_state_get WATCHDOG_REPAIR_EXPECTED_HASH '')
    fi
    if ! apo_profile_network_watchdog_ready; then
        apo_profile_install_best_network_watchdog || return 1
    fi
    [[ $expected_hash =~ ^[0-9a-f]{64}$ ]] || {
        APO_LAST_CLASS=PREFLIGHT_FAILURE
        APO_LAST_REASON='The combined Debian watchdog repair lost its protected config hash.'
        return 1
    }
    apo_state_set WATCHDOG_REPAIR_EXPECTED_HASH "$expected_hash"
    apo_state_set WATCHDOG_REPAIR_NEW_HASH "$expected_hash"
    apo_state_set WATCHDOG_REPAIR_STATUS STAGED
    apo_state_save
}

apo_profile_cleanup_run_watchdog() {
    local kind installer remote_installer
    [[ $(apo_state_get NETWORK_WATCHDOG_INSTALLED_BY_RUN 0) == 1 ]] || return 0
    kind=$(apo_state_get NETWORK_WATCHDOG_INSTALL_KIND '')
    case $kind in
        debian-watchdog-observer)
            installer=${APO_ROOT}/assets/debian/install_network_watchdog_observer.sh
            remote_installer=${APO_REMOTE_WORK_DIR}/network-watchdog-observer-cleanup.sh
            ;;
        debian-systemd-companion)
            installer=${APO_ROOT}/assets/debian/install_network_watchdog.sh
            remote_installer=${APO_REMOTE_WORK_DIR}/network-watchdog-cleanup.sh
            ;;
        *)
            APO_LAST_CLASS=RECOVERY_FAILURE
            APO_LAST_REASON="The run-owned Debian watchdog provider is malformed: ${kind:-missing}."
            return 1
            ;;
    esac
    apo_remote_upload_root "$installer" "$remote_installer" || return 1
    apo_state_set NETWORK_WATCHDOG_INSTALL_STATUS CLEANING
    apo_state_save
    apo_run_worker_capture network-watchdog-cleanup cleanup-network-watchdog \
        "$remote_installer" "$APO_RUN_ID" \
        "$(apo_state_get NETWORK_WATCHDOG_INSTALL_BACKUP '')" \
        "$(apo_state_get NETWORK_WATCHDOG_INSTALL_CONFIG_HASH '')" \
        "$(apo_state_get NETWORK_WATCHDOG_INSTALL_KEEPER_HASH '')" \
        "$(apo_state_get NETWORK_WATCHDOG_INSTALL_SERVICE_HASH '')" \
        "$(apo_state_get NETWORK_WATCHDOG_INSTALL_OLD_KEEPER_HASH '')" \
        "$(apo_state_get NETWORK_WATCHDOG_INSTALL_OLD_SERVICE_HASH '')" \
        "$(apo_state_get NETWORK_WATCHDOG_INSTALL_OLD_CONFIG_HASH '')" \
        "$(apo_state_get NETWORK_WATCHDOG_INSTALL_OLD_SERVICE_ENABLED 0)" \
        "$(apo_state_get NETWORK_WATCHDOG_INSTALL_OLD_SERVICE_ACTIVE 0)" || return 1
    apo_state_set NETWORK_WATCHDOG_INSTALLED_BY_RUN 0
    apo_state_set NETWORK_WATCHDOG_INSTALL_STATUS REMOVED
    apo_state_save
    apo_event network-watchdog-cleanup PASS '' 'Removed only the run-owned Debian watchdog proof component and retained native watchdogs and durable evidence.'
}

apo_profile_cleanup_worker() { apo_remote_root "rm -rf $(apo_sh_quote "$APO_REMOTE_WORK_DIR")" >/dev/null 2>&1 || true; }
