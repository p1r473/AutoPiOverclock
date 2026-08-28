#!/usr/bin/env bash
# Raspberry Pi OS, Debian, and Ubuntu Pi-layout profile.

APO_PROFILE=debian
APO_LOCAL_WORKER="${APO_ROOT}/workers/debian-worker.sh"
APO_REMOTE_WORK_DIR="/tmp/autopioverclock-${APO_RUN_ID}"
APO_REMOTE_WORKER="${APO_REMOTE_WORK_DIR}/worker.sh"
APO_BOOT_TIMEOUT=240
APO_BOOT_SETTLE_SECONDS=15

apo_profile_dependencies_ready() {
    [[ ${APO_DISCOVERY[CPU_STRESS_AVAILABLE]:-0} == 1 ]] || return 1
    (( APO_REQUIRE_GPU_STRESS == 0 )) || [[ ${APO_DISCOVERY[GPU_STRESS_AVAILABLE]:-0} == 1 ]]
}

apo_profile_install_dependencies() {
    apo_event dependencies INFO '' 'Installing Debian stress dependency: stress-ng'
    apo_remote_root 'export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get install -y --no-install-recommends stress-ng'
}

apo_profile_watchdogs_ready() {
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

apo_profile_watchdog_description() {
    printf 'EEPROM=%s kernel-handoff=%s systemd=%s device=%s runtime-timeout=%s owner=%s' \
        "${APO_DISCOVERY[BOOT_WATCHDOG_TIMEOUT]:-missing}" "${APO_DISCOVERY[KERNEL_WATCHDOG_TIMEOUT]:-missing}" \
        "${APO_DISCOVERY[RUNTIME_WATCHDOG]:-missing}" "${APO_DISCOVERY[WATCHDOG_DEVICE]:-missing}" \
        "${APO_DISCOVERY[WATCHDOG_RUNTIME_TIMEOUT]:-missing}" \
        "${APO_DISCOVERY[WATCHDOG_OWNER]:-missing}"
}

apo_profile_repair_watchdogs() {
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
    new_boot_id=$(apo_wait_for_new_boot "$old_boot_id" "$APO_BOOT_TIMEOUT" || true)
    [[ -n $new_boot_id ]] || return 1
    apo_state_set WATCHDOG_REPAIR_STATUS REBOOTED
    apo_state_set LAST_BOOT_ID "$new_boot_id"
    apo_state_set NORMAL_BOOT_ID "$new_boot_id"
    apo_state_save
    sleep "$APO_BOOT_SETTLE_SECONDS"
}

apo_profile_cleanup_worker() { apo_remote_root "rm -rf $(apo_sh_quote "$APO_REMOTE_WORK_DIR")" >/dev/null 2>&1 || true; }
