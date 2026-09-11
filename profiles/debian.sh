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
    local local_keeper=${APO_ROOT}/assets/debian/network_watchdog_keeper.py
    local local_service=${APO_ROOT}/assets/debian/autopioverclock-network-watchdog.service
    local expected_keeper_hash expected_service_hash
    [[ ${APO_DISCOVERY[NETWORK_WATCHDOG_KIND]:-} == debian-systemd-companion &&
       ${APO_DISCOVERY[NETWORK_WATCHDOG_SERVICE_ACTIVE]:-0} == 1 &&
       ${APO_DISCOVERY[NETWORK_WATCHDOG_TARGET]:-} =~ ^[0-9]+([.][0-9]+){3}$ &&
       ${APO_DISCOVERY[NETWORK_WATCHDOG_CONFIG_HASH]:-} =~ ^[0-9a-f]{64}$ ]] || return 1
    expected_keeper_hash=$(sha256sum "$local_keeper" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    expected_service_hash=$(sha256sum "$local_service" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    [[ $expected_keeper_hash =~ ^[0-9a-f]{64}$ && $expected_service_hash =~ ^[0-9a-f]{64}$ &&
       ${APO_DISCOVERY[NETWORK_WATCHDOG_KEEPER_HASH]:-} == "$expected_keeper_hash" &&
       ${APO_DISCOVERY[NETWORK_WATCHDOG_SERVICE_HASH]:-} == "$expected_service_hash" ]]
}

apo_profile_watchdogs_ready() {
    apo_profile_hardware_watchdogs_ready && apo_profile_network_watchdog_ready
}

apo_profile_watchdog_description() {
    printf 'EEPROM=%s kernel-handoff=%s systemd=%s device=%s runtime-timeout=%s owner=%s network-target=%s managed-network-service=%s' \
        "${APO_DISCOVERY[BOOT_WATCHDOG_TIMEOUT]:-missing}" "${APO_DISCOVERY[KERNEL_WATCHDOG_TIMEOUT]:-missing}" \
        "${APO_DISCOVERY[RUNTIME_WATCHDOG]:-missing}" "${APO_DISCOVERY[WATCHDOG_DEVICE]:-missing}" \
        "${APO_DISCOVERY[WATCHDOG_RUNTIME_TIMEOUT]:-missing}" \
        "${APO_DISCOVERY[WATCHDOG_OWNER]:-missing}" \
        "${APO_DISCOVERY[NETWORK_WATCHDOG_TARGET]:-missing}" \
        "${APO_DISCOVERY[NETWORK_WATCHDOG_SERVICE_ACTIVE]:-0}"
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
    local expected="INSTALL-NETWORK-WATCHDOG ${APO_TARGET_SLUG}"
    local local_asset_dir=${APO_ROOT}/assets/debian remote_asset_dir=${APO_REMOTE_WORK_DIR}/network-watchdog-assets
    local local_installer=$local_asset_dir/install_network_watchdog.sh
    local local_keeper=$local_asset_dir/network_watchdog_keeper.py
    local local_service=$local_asset_dir/autopioverclock-network-watchdog.service
    local remote_installer=$remote_asset_dir/install_network_watchdog.sh
    local remote_keeper=$remote_asset_dir/network_watchdog_keeper.py
    local remote_service=$remote_asset_dir/autopioverclock-network-watchdog.service
    local target keeper_hash service_hash config_hash old_keeper_hash old_service_hash old_config_hash
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
    local_keeper_hash=$(sha256sum "$local_keeper" | awk 'NR == 1 {print $1}')
    local_service_hash=$(sha256sum "$local_service" | awk 'NR == 1 {print $1}')
    if [[ ! $target =~ ^[0-9]+([.][0-9]+){3}$ || $keeper_hash != "$local_keeper_hash" ||
          $service_hash != "$local_service_hash" || ! $config_hash =~ ^[0-9a-f]{64}$ ||
          ! $old_keeper_hash =~ ^(absent|[0-9a-f]{64})$ ||
          ! $old_service_hash =~ ^(absent|[0-9a-f]{64})$ ||
          ! $old_config_hash =~ ^(absent|[0-9a-f]{64})$ ]]; then
        APO_LAST_CLASS=PREFLIGHT_FAILURE
        APO_LAST_REASON='The Debian network-watchdog installation plan could not be verified.'
        return 1
    fi
    apo_state_set PHASE PREPARE
    apo_state_set SUBPHASE NETWORK_WATCHDOG_PLANNED
    apo_state_set WATCHDOG_REPAIR_STATUS PLANNED
    apo_state_set NETWORK_WATCHDOG_REPAIR_TARGET "$target"
    apo_state_set NETWORK_WATCHDOG_REPAIR_CONFIG_HASH "$config_hash"
    apo_state_save
    if (( ${APO_AUTO_PREPARE:-0} == 1 )); then
        apo_info "The explicit prepare command authorizes the planned Debian network-watchdog companion for liveness target $target."
    else
        apo_confirm_exact "Prepare will preserve verified backups and install a project-owned Debian network-watchdog companion for liveness target $target. systemd remains the hardware-watchdog owner." "$expected" || return 1
    fi
    apo_state_set MUTATIONS_STARTED 1
    apo_state_set WATCHDOG_REPAIR_STATUS MUTATING
    apo_state_set SUBPHASE NETWORK_WATCHDOG_MUTATING
    apo_state_save
    apo_run_worker_capture network-watchdog-install install-network-watchdog \
        "$remote_installer" "$remote_keeper" "$remote_service" "$APO_RUN_ID" "$target" \
        "$keeper_hash" "$service_hash" "$config_hash" "$old_keeper_hash" "$old_service_hash" "$old_config_hash" || return 1
    apo_parse_data_file "$APO_LAST_WORKER_LOG" APO_WORKER_DATA
    reported_target=${APO_WORKER_DATA[NETWORK_WATCHDOG_TARGET]:-}
    reported_config_hash=${APO_WORKER_DATA[NETWORK_WATCHDOG_CONFIG_HASH]:-}
    backup_path=${APO_WORKER_DATA[NETWORK_WATCHDOG_BACKUP]:-}
    if [[ $reported_target != "$target" || $reported_config_hash != "$config_hash" || -z $backup_path ]]; then
        APO_LAST_CLASS=PREFLIGHT_FAILURE
        APO_LAST_REASON='The installed Debian network-watchdog result could not be matched to its plan.'
        apo_state_set WATCHDOG_REPAIR_STATUS RESULT_UNVERIFIED
        apo_state_save
        return 1
    fi
    apo_state_set NETWORK_WATCHDOG_REPAIR_BACKUP "$backup_path"
    apo_state_set WATCHDOG_REPAIR_STATUS STAGED
    apo_state_set SUBPHASE NETWORK_WATCHDOG_STAGED
    apo_state_save
}

apo_profile_prove_network_watchdog_reboot() {
    local context=$1 old_boot=$2 new_boot=$3 output_file rc attempt attempts=${APO_TRANSIENT_WORKER_ATTEMPTS:-5}
    local expected_target expected_config_hash expected_keeper_hash expected_service_hash previous_event
    output_file=$(apo_candidate_log_file "${context}-network-watchdog-proof")
    expected_target=$(apo_state_get DISC_NETWORK_WATCHDOG_TARGET '')
    expected_config_hash=$(apo_state_get DISC_NETWORK_WATCHDOG_CONFIG_HASH '')
    expected_keeper_hash=$(sha256sum "${APO_ROOT}/assets/debian/network_watchdog_keeper.py" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    expected_service_hash=$(sha256sum "${APO_ROOT}/assets/debian/autopioverclock-network-watchdog.service" 2>/dev/null | awk 'NR == 1 {print $1}' || true)
    previous_event=$(apo_state_get NETWORK_WATCHDOG_LAST_EVENT_ID '')
    [[ $attempts =~ ^[1-9][0-9]*$ ]] || attempts=5
    for (( attempt=1; attempt<=attempts; attempt++ )); do
        set +e
        apo_remote_worker_read_file "$output_file" "$APO_REMOTE_WORKER" prove-network-watchdog-reboot \
            "$old_boot" "$new_boot" "$expected_target" "$expected_config_hash" \
            "$expected_keeper_hash" "$expected_service_hash" "$previous_event"
        rc=$?
        set -e
        [[ -z ${APO_LOG_FILE:-} || ! -f ${APO_LOG_FILE:-} ]] || cat "$output_file" >>"$APO_LOG_FILE"
        apo_classify_output "$output_file" "${context}-network-watchdog-proof"
        if (( rc == 0 )) && [[ $APO_LAST_CLASS == PASS ]]; then break; fi
        (( attempt < attempts )) || return 1
        apo_event "${context}-network-watchdog-proof-retry" WARN HARNESS_FAILURE \
            "Strict network-watchdog evidence is not complete yet; retrying the read-only proof (attempt $((attempt + 1))/$attempts)."
        if declare -F apo_transient_read_delay >/dev/null 2>&1; then apo_transient_read_delay; else sleep 10; fi
    done
    apo_parse_data_file "$output_file" APO_WORKER_DATA
    APO_NETWORK_WATCHDOG_EVENT_ID=${APO_WORKER_DATA[NETWORK_WATCHDOG_EVENT_ID]:-}
    APO_NETWORK_WATCHDOG_TARGET=${APO_WORKER_DATA[NETWORK_WATCHDOG_TARGET]:-}
    [[ $APO_NETWORK_WATCHDOG_EVENT_ID =~ ^[0-9a-f]{32}$ &&
       $APO_NETWORK_WATCHDOG_TARGET == "$expected_target" &&
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
        apo_profile_install_network_watchdog || return 1
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

apo_profile_cleanup_worker() { apo_remote_root "rm -rf $(apo_sh_quote "$APO_REMOTE_WORK_DIR")" >/dev/null 2>&1 || true; }
