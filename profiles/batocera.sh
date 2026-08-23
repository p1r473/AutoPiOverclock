#!/usr/bin/env bash
# Batocera/Buildroot profile.

APO_PROFILE=batocera
APO_LOCAL_WORKER="${APO_ROOT}/workers/batocera-worker.sh"
APO_REMOTE_WORK_DIR="/userdata/system/autopioverclock/runs/${APO_RUN_ID}"
APO_REMOTE_WORKER="${APO_REMOTE_WORK_DIR}/worker.sh"
APO_BOOT_TIMEOUT=300
APO_BOOT_SETTLE_SECONDS=8

apo_profile_dependencies_ready() {
    [[ ${APO_DISCOVERY[CPU_STRESS_AVAILABLE]:-0} == 1 ]] || return 1
    (( APO_REQUIRE_GPU_STRESS == 0 )) || [[ ${APO_DISCOVERY[GPU_STRESS_AVAILABLE]:-0} == 1 ]]
}

apo_profile_install_dependencies() {
    (( APO_REQUIRE_GPU_STRESS == 1 )) || return 0
    local bundle_dir="${APO_ROOT}/dist"
    local bundle_file="${bundle_dir}/autopioverclock-batocera-glmark2.tar.gz"
    local remote_bundle='/userdata/system/autopioverclock/cache/autopioverclock-batocera-glmark2.tar.gz'
    mkdir -p "$bundle_dir"
    if [[ ! -f $bundle_file ]]; then
        apo_event dependencies INFO '' 'Building portable ARM64 glmark2 bundle from Debian packages'
        "${APO_ROOT}/tools/build-batocera-bundle.sh" "$bundle_dir" || return 1
    fi
    apo_event dependencies INFO '' 'Uploading portable glmark2 bundle to Batocera persistent storage'
    apo_remote_upload_root "$bundle_file" "$remote_bundle"
    apo_remote_root "rm -rf /userdata/system/autopioverclock/glmark2.new; mkdir -p /userdata/system/autopioverclock/glmark2.new; tar -xzf $(apo_sh_quote "$remote_bundle") -C /userdata/system/autopioverclock/glmark2.new; cd /userdata/system/autopioverclock/glmark2.new; sha256sum -c MANIFEST.sha256; test -x usr/bin/glmark2-es2-drm; test -d usr/share/glmark2; cd /; rm -rf /userdata/system/autopioverclock/glmark2; mv /userdata/system/autopioverclock/glmark2.new /userdata/system/autopioverclock/glmark2; sync"
}

apo_profile_watchdogs_ready() {
    local boot_timeout=${APO_DISCOVERY[BOOT_WATCHDOG_TIMEOUT]:-0}
    local kernel_timeout=${APO_DISCOVERY[KERNEL_WATCHDOG_TIMEOUT]:-0}
    local watchdog_device=${APO_DISCOVERY[WATCHDOG_DEVICE]:-}
    local watchdog_runtime_timeout=${APO_DISCOVERY[WATCHDOG_RUNTIME_TIMEOUT]:-0}
    local watchdog_owner=${APO_DISCOVERY[WATCHDOG_OWNER]:-}
    apo_is_uint "$boot_timeout" && (( boot_timeout > 0 )) || return 1
    apo_is_uint "$kernel_timeout" && (( kernel_timeout > 0 )) || return 1
    apo_is_uint "$watchdog_runtime_timeout" && (( watchdog_runtime_timeout > 0 )) || return 1
    [[ -n $watchdog_device && -n $watchdog_owner ]]
}

apo_profile_watchdog_description() {
    printf 'EEPROM=%s kernel-handoff=%s watchdog-device=%s runtime-timeout=%s owner=%s' \
        "${APO_DISCOVERY[BOOT_WATCHDOG_TIMEOUT]:-missing}" "${APO_DISCOVERY[KERNEL_WATCHDOG_TIMEOUT]:-missing}" "${APO_DISCOVERY[WATCHDOG_DEVICE]:-missing}" \
        "${APO_DISCOVERY[WATCHDOG_RUNTIME_TIMEOUT]:-missing}" \
        "${APO_DISCOVERY[WATCHDOG_OWNER]:-missing}"
}

apo_profile_repair_watchdogs() {
    apo_event watchdog-repair ERROR PREFLIGHT_FAILURE 'Batocera runtime-watchdog ownership is installation-specific; automatic replacement is intentionally refused.'
    return 1
}

apo_profile_cleanup_worker() { apo_remote_root "rm -rf $(apo_sh_quote "$APO_REMOTE_WORK_DIR")" >/dev/null 2>&1 || true; }
