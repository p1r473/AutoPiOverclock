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
    (( APO_REQUIRE_GPU_STRESS == 0 )) && return 0
    [[ -n ${APO_DISCOVERY[GLMARK_DATA]:-} ]] || return 1
    case ${APO_MODE_EFFECTIVE:-} in
        graphical) [[ -n ${APO_DISCOVERY[GLMARK_WAYLAND_BINARY]:-} ]] ;;
        headless) [[ -n ${APO_DISCOVERY[GLMARK_DRM_BINARY]:-} ]] ;;
        *) return 1 ;;
    esac
}

apo_profile_batocera_bundle_ready() {
    local bundle_file=$1 bundle_listing='' expected_hash actual_hash
    [[ -f $bundle_file && -f ${bundle_file}.sha256 ]] || return 1
    expected_hash=$(awk 'NR == 1 {print $1}' "${bundle_file}.sha256" 2>/dev/null) || return 1
    [[ $expected_hash =~ ^[0-9a-f]{64}$ ]] || return 1
    actual_hash=$(sha256sum "$bundle_file" 2>/dev/null | awk 'NR == 1 {print $1}') || return 1
    [[ $actual_hash == "$expected_hash" ]] || return 1
    bundle_listing=$(tar -tzf "$bundle_file" 2>/dev/null) || return 1
    grep -Eq '^(\./)?usr/bin/glmark2-es2-drm$' <<< "$bundle_listing" || return 1
    grep -Eq '^(\./)?usr/bin/glmark2-es2-wayland$' <<< "$bundle_listing" || return 1
}

apo_profile_batocera_bundle_install_command() {
    local archive=$1 install_root=${2:-/userdata/system/autopioverclock}
    printf 'set -Eeuo pipefail\numask 077\n' || return 1
    printf 'archive=%s\n' "$(apo_sh_quote "$archive")" || return 1
    printf 'install_root=%s\n' "$(apo_sh_quote "$install_root")" || return 1
    cat <<'APO_BATOCERA_BUNDLE_INSTALL' || return 1
live_dir="${install_root}/glmark2"
new_dir="${install_root}/glmark2.new"
old_dir="${install_root}/glmark2.old"
moved_old=0
activation_started=0
bundle_dir_integrity_valid() {
    local directory=$1
    [[ -d $directory ]] || return 1
    (
        cd "$directory" || return 1
        sha256sum -c MANIFEST.sha256 >/dev/null || return 1
        [[ -x usr/bin/glmark2-es2-drm ]] || return 1
        [[ -d usr/share/glmark2 ]] || return 1
    )
}
bundle_install_cleanup() {
    local exit_code=$?
    trap - EXIT INT TERM HUP
    if (( exit_code != 0 )); then
        if (( activation_started == 1 )); then rm -rf "$live_dir"; fi
        if (( moved_old == 1 )) && { [[ -e $old_dir ]] || [[ -L $old_dir ]]; } &&
           { [[ ! -e $live_dir ]] && [[ ! -L $live_dir ]]; }; then
            mv "$old_dir" "$live_dir" || true
        fi
    fi
    rm -rf "$new_dir"
    exit "$exit_code"
}
trap bundle_install_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
rm -rf "$new_dir"
if [[ -e $old_dir ]] || [[ -L $old_dir ]]; then
    if bundle_dir_integrity_valid "$live_dir"; then
        rm -rf "$old_dir"
    elif bundle_dir_integrity_valid "$old_dir"; then
        rm -rf "$live_dir"
        mv "$old_dir" "$live_dir"
        sync
    else
        printf 'Neither the live nor rollback Batocera bundle passed its manifest.\n' >&2
        exit 1
    fi
fi
mkdir -p "$new_dir"
tar -xzf "$archive" -C "$new_dir"
(
    cd "$new_dir"
    sha256sum -c MANIFEST.sha256
    [[ -x usr/bin/glmark2-es2-drm ]]
    [[ -x usr/bin/glmark2-es2-wayland ]]
    [[ -d usr/share/glmark2 ]]
)
if [[ -e $live_dir ]] || [[ -L $live_dir ]]; then
    moved_old=1
    mv "$live_dir" "$old_dir"
fi
activation_started=1
mv "$new_dir" "$live_dir"
(
    cd "$live_dir"
    sha256sum -c MANIFEST.sha256
    [[ -x usr/bin/glmark2-es2-drm ]]
    [[ -x usr/bin/glmark2-es2-wayland ]]
    [[ -d usr/share/glmark2 ]]
)
sync
trap - EXIT INT TERM HUP
rm -rf "$old_dir" || true
APO_BATOCERA_BUNDLE_INSTALL
}

apo_profile_install_dependencies() {
    (( APO_REQUIRE_GPU_STRESS == 1 )) || return 0
    local bundle_dir="${APO_ROOT}/dist"
    local bundle_file="${bundle_dir}/autopioverclock-batocera-glmark2.tar.gz"
    local remote_bundle='/userdata/system/autopioverclock/cache/autopioverclock-batocera-glmark2.tar.gz'
    local remote_command=''
    mkdir -p "$bundle_dir" || return 1
    if ! apo_profile_batocera_bundle_ready "$bundle_file"; then
        apo_event dependencies INFO '' 'Building portable ARM64 glmark2 bundle from Debian packages'
        if declare -F apo_progress_before_output >/dev/null 2>&1; then apo_progress_before_output; fi
        "${APO_ROOT}/tools/build-batocera-bundle.sh" "$bundle_dir" || return 1
    fi
    apo_profile_batocera_bundle_ready "$bundle_file" || return 1
    apo_event dependencies INFO '' 'Uploading portable glmark2 bundle to Batocera persistent storage'
    apo_remote_upload_root "$bundle_file" "$remote_bundle" || return 1
    remote_command=$(apo_profile_batocera_bundle_install_command "$remote_bundle") || return 1
    if declare -F apo_progress_before_output >/dev/null 2>&1; then apo_progress_before_output; fi
    apo_remote_root "$remote_command" || return 1
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

apo_profile_network_watchdog_ready() {
    [[ ( ${APO_DISCOVERY[NETWORK_WATCHDOG_KIND]:-} == batocera-hardware-keeper ||
         ${APO_DISCOVERY[NETWORK_WATCHDOG_KIND]:-} == batocera-network-companion ) &&
       ${APO_DISCOVERY[NETWORK_WATCHDOG_SERVICE_ACTIVE]:-0} == 1 &&
       ${APO_DISCOVERY[NETWORK_WATCHDOG_TARGET]:-} =~ ^[0-9]+([.][0-9]+){3}$ &&
       ${APO_DISCOVERY[NETWORK_WATCHDOG_CONFIG_HASH]:-} =~ ^[0-9a-f]{64}$ &&
       ${APO_DISCOVERY[NETWORK_WATCHDOG_KEEPER_HASH]:-} =~ ^[0-9a-f]{64}$ &&
       ${APO_DISCOVERY[NETWORK_WATCHDOG_SERVICE_HASH]:-} =~ ^[0-9a-f]{64}$ ]]
}

apo_profile_watchdog_description() {
    printf 'EEPROM=%s kernel-handoff=%s watchdog-device=%s runtime-timeout=%s owner=%s' \
        "${APO_DISCOVERY[BOOT_WATCHDOG_TIMEOUT]:-missing}" "${APO_DISCOVERY[KERNEL_WATCHDOG_TIMEOUT]:-missing}" "${APO_DISCOVERY[WATCHDOG_DEVICE]:-missing}" \
        "${APO_DISCOVERY[WATCHDOG_RUNTIME_TIMEOUT]:-missing}" \
        "${APO_DISCOVERY[WATCHDOG_OWNER]:-missing}"
}

apo_profile_install_network_watchdog_companion() {
    local local_asset_dir=${APO_ROOT}/assets/batocera remote_asset_dir=${APO_REMOTE_WORK_DIR}/network-watchdog-assets
    local local_installer=$local_asset_dir/install_network_watchdog.sh
    local local_keeper=${APO_ROOT}/assets/debian/network_watchdog_keeper.py
    local local_service=$local_asset_dir/AutoPiOverclockNetworkWatchdog
    local remote_installer=$remote_asset_dir/install_network_watchdog.sh
    local remote_keeper=$remote_asset_dir/network_watchdog_keeper.py
    local remote_service=$remote_asset_dir/AutoPiOverclockNetworkWatchdog
    local target keeper_hash service_hash config_hash platform_old_hash platform_new_hash
    local reported_target reported_config_hash backup_path local_keeper_hash local_service_hash
    [[ -r $local_installer && -r $local_keeper && -r $local_service ]] || {
        APO_LAST_CLASS=PREFLIGHT_FAILURE
        APO_LAST_REASON='The packaged Batocera network-watchdog companion assets are missing.'
        return 1
    }
    apo_remote_upload_root "$local_installer" "$remote_installer" || return 1
    apo_remote_upload_root "$local_keeper" "$remote_keeper" || return 1
    apo_remote_upload_root "$local_service" "$remote_service" || return 1
    apo_run_worker_capture network-watchdog-plan plan-network-watchdog-companion \
        "$remote_installer" "$remote_keeper" "$remote_service" "$APO_RUN_ID" || return 1
    apo_parse_data_file "$APO_LAST_WORKER_LOG" APO_WORKER_DATA
    target=${APO_WORKER_DATA[NETWORK_WATCHDOG_TARGET]:-}
    keeper_hash=${APO_WORKER_DATA[NETWORK_WATCHDOG_KEEPER_HASH]:-}
    service_hash=${APO_WORKER_DATA[NETWORK_WATCHDOG_SERVICE_HASH]:-}
    config_hash=${APO_WORKER_DATA[NETWORK_WATCHDOG_CONFIG_HASH]:-}
    platform_old_hash=${APO_WORKER_DATA[NETWORK_WATCHDOG_BATOCERA_OLD_HASH]:-}
    platform_new_hash=${APO_WORKER_DATA[NETWORK_WATCHDOG_BATOCERA_NEW_HASH]:-}
    local_keeper_hash=$(sha256sum "$local_keeper" | awk 'NR == 1 {print $1}')
    local_service_hash=$(sha256sum "$local_service" | awk 'NR == 1 {print $1}')
    if [[ ! $target =~ ^[0-9]+([.][0-9]+){3}$ || $keeper_hash != "$local_keeper_hash" ||
          $service_hash != "$local_service_hash" || ! $config_hash =~ ^[0-9a-f]{64}$ ||
          ! $platform_old_hash =~ ^[0-9a-f]{64}$ || ! $platform_new_hash =~ ^[0-9a-f]{64}$ ||
          ${APO_WORKER_DATA[NETWORK_WATCHDOG_OLD_KEEPER_HASH]:-} != absent ||
          ${APO_WORKER_DATA[NETWORK_WATCHDOG_OLD_SERVICE_HASH]:-} != absent ||
          ${APO_WORKER_DATA[NETWORK_WATCHDOG_OLD_CONFIG_HASH]:-} != absent ]]; then
        APO_LAST_CLASS=PREFLIGHT_FAILURE
        APO_LAST_REASON='The Batocera network-watchdog installation plan could not be verified.'
        return 1
    fi
    apo_state_set NETWORK_WATCHDOG_INSTALL_KIND batocera-network-companion
    apo_state_set NETWORK_WATCHDOG_INSTALL_TARGET "$target"
    apo_state_set NETWORK_WATCHDOG_INSTALL_CONFIG_HASH "$config_hash"
    apo_state_set NETWORK_WATCHDOG_INSTALL_KEEPER_HASH "$keeper_hash"
    apo_state_set NETWORK_WATCHDOG_INSTALL_SERVICE_HASH "$service_hash"
    apo_state_set NETWORK_WATCHDOG_INSTALL_OLD_KEEPER_HASH absent
    apo_state_set NETWORK_WATCHDOG_INSTALL_OLD_SERVICE_HASH absent
    apo_state_set NETWORK_WATCHDOG_INSTALL_OLD_CONFIG_HASH absent
    apo_state_set NETWORK_WATCHDOG_INSTALL_OLD_SERVICE_ENABLED 0
    apo_state_set NETWORK_WATCHDOG_INSTALL_OLD_SERVICE_ACTIVE 0
    apo_state_set NETWORK_WATCHDOG_INSTALL_PLATFORM_OLD_HASH "$platform_old_hash"
    apo_state_set NETWORK_WATCHDOG_INSTALL_PLATFORM_NEW_HASH "$platform_new_hash"
    apo_state_set NETWORK_WATCHDOG_INSTALL_STATUS PLANNED
    apo_state_save
    apo_state_set MUTATIONS_STARTED 1
    apo_state_set NETWORK_WATCHDOG_INSTALL_STATUS MUTATING
    apo_state_save
    apo_run_worker_capture network-watchdog-install install-network-watchdog-companion \
        "$remote_installer" "$remote_keeper" "$remote_service" "$APO_RUN_ID" "$target" \
        "$keeper_hash" "$service_hash" "$config_hash" "$platform_old_hash" "$platform_new_hash" || return 1
    apo_parse_data_file "$APO_LAST_WORKER_LOG" APO_WORKER_DATA
    reported_target=${APO_WORKER_DATA[NETWORK_WATCHDOG_TARGET]:-}
    reported_config_hash=${APO_WORKER_DATA[NETWORK_WATCHDOG_CONFIG_HASH]:-}
    backup_path=${APO_WORKER_DATA[NETWORK_WATCHDOG_BACKUP]:-}
    [[ $reported_target == "$target" && $reported_config_hash == "$config_hash" && -n $backup_path ]] || {
        APO_LAST_CLASS=PREFLIGHT_FAILURE
        APO_LAST_REASON='The installed Batocera network-watchdog result could not be matched to its plan.'
        apo_state_set NETWORK_WATCHDOG_INSTALL_STATUS RESULT_UNVERIFIED
        apo_state_save
        return 1
    }
    apo_state_set NETWORK_WATCHDOG_INSTALLED_BY_RUN 1
    apo_state_set NETWORK_WATCHDOG_INSTALL_BACKUP "$backup_path"
    apo_state_set NETWORK_WATCHDOG_INSTALL_STATUS INSTALLED
    apo_state_save
}

apo_profile_reconcile_network_watchdog_install() {
    local local_asset_dir=${APO_ROOT}/assets/batocera remote_asset_dir=${APO_REMOTE_WORK_DIR}/network-watchdog-reconcile-assets
    local local_installer=$local_asset_dir/install_network_watchdog.sh
    local local_keeper=${APO_ROOT}/assets/debian/network_watchdog_keeper.py
    local local_service=$local_asset_dir/AutoPiOverclockNetworkWatchdog
    local remote_installer=$remote_asset_dir/install_network_watchdog.sh
    local remote_keeper=$remote_asset_dir/network_watchdog_keeper.py
    local remote_service=$remote_asset_dir/AutoPiOverclockNetworkWatchdog
    local target keeper_hash service_hash config_hash platform_old_hash platform_new_hash live_run=${APO_DISCOVERY[NETWORK_WATCHDOG_INSTALL_RUN_ID]:-}
    local reported_target reported_config_hash backup_path local_keeper_hash local_service_hash
    [[ $(apo_state_get NETWORK_WATCHDOG_INSTALL_KIND '') == batocera-network-companion ]] || return 1
    [[ -z $live_run || $live_run == "$APO_RUN_ID" ]] || {
        APO_LAST_CLASS=RECOVERY_FAILURE
        APO_LAST_REASON='A foreign Batocera network-watchdog installation occupies the protected project paths.'
        return 1
    }
    target=$(apo_state_get NETWORK_WATCHDOG_INSTALL_TARGET '')
    keeper_hash=$(apo_state_get NETWORK_WATCHDOG_INSTALL_KEEPER_HASH '')
    service_hash=$(apo_state_get NETWORK_WATCHDOG_INSTALL_SERVICE_HASH '')
    config_hash=$(apo_state_get NETWORK_WATCHDOG_INSTALL_CONFIG_HASH '')
    platform_old_hash=$(apo_state_get NETWORK_WATCHDOG_INSTALL_PLATFORM_OLD_HASH '')
    platform_new_hash=$(apo_state_get NETWORK_WATCHDOG_INSTALL_PLATFORM_NEW_HASH '')
    [[ -r $local_installer && -r $local_keeper && -r $local_service &&
       $target =~ ^[0-9]+([.][0-9]+){3}$ && $keeper_hash =~ ^[0-9a-f]{64}$ &&
       $service_hash =~ ^[0-9a-f]{64}$ && $config_hash =~ ^[0-9a-f]{64}$ &&
       $platform_old_hash =~ ^[0-9a-f]{64}$ && $platform_new_hash =~ ^[0-9a-f]{64}$ ]] || {
        APO_LAST_CLASS=RECOVERY_FAILURE
        APO_LAST_REASON='The interrupted Batocera network-watchdog checkpoint is incomplete.'
        return 1
    }
    local_keeper_hash=$(sha256sum "$local_keeper" | awk 'NR == 1 {print $1}')
    local_service_hash=$(sha256sum "$local_service" | awk 'NR == 1 {print $1}')
    [[ $keeper_hash == "$local_keeper_hash" && $service_hash == "$local_service_hash" ]] || {
        APO_LAST_CLASS=RECOVERY_FAILURE
        APO_LAST_REASON='The packaged Batocera network-watchdog assets changed after the interrupted installation checkpoint.'
        return 1
    }
    apo_remote_upload_root "$local_installer" "$remote_installer" || return 1
    apo_remote_upload_root "$local_keeper" "$remote_keeper" || return 1
    apo_remote_upload_root "$local_service" "$remote_service" || return 1
    apo_state_set NETWORK_WATCHDOG_INSTALL_STATUS RECONCILING
    apo_state_save
    apo_run_worker_capture network-watchdog-reconcile install-network-watchdog-companion \
        "$remote_installer" "$remote_keeper" "$remote_service" "$APO_RUN_ID" "$target" \
        "$keeper_hash" "$service_hash" "$config_hash" "$platform_old_hash" "$platform_new_hash" || return 1
    apo_parse_data_file "$APO_LAST_WORKER_LOG" APO_WORKER_DATA
    reported_target=${APO_WORKER_DATA[NETWORK_WATCHDOG_TARGET]:-}
    reported_config_hash=${APO_WORKER_DATA[NETWORK_WATCHDOG_CONFIG_HASH]:-}
    backup_path=${APO_WORKER_DATA[NETWORK_WATCHDOG_BACKUP]:-}
    [[ $reported_target == "$target" && $reported_config_hash == "$config_hash" && -n $backup_path ]] || {
        APO_LAST_CLASS=RECOVERY_FAILURE
        APO_LAST_REASON='The reconciled Batocera network-watchdog result could not be matched to its checkpoint.'
        apo_state_set NETWORK_WATCHDOG_INSTALL_STATUS RESULT_UNVERIFIED
        apo_state_save
        return 1
    }
    apo_state_set NETWORK_WATCHDOG_INSTALLED_BY_RUN 1
    apo_state_set NETWORK_WATCHDOG_INSTALL_BACKUP "$backup_path"
    apo_state_set NETWORK_WATCHDOG_INSTALL_STATUS INSTALLED
    apo_state_save
    apo_event network-watchdog-reconcile PASS '' 'Reconciled the interrupted run-owned Batocera network-watchdog installation from hash-bound target evidence.'
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
    APO_NETWORK_WATCHDOG_PROOF_REASON="Project-owned Batocera watchdog evidence proves that liveness target $APO_NETWORK_WATCHDOG_TARGET caused the reboot from boot $old_boot."
}

apo_profile_cleanup_run_watchdog() {
    local installer=${APO_ROOT}/assets/batocera/install_network_watchdog.sh
    local remote_installer=${APO_REMOTE_WORK_DIR}/network-watchdog-cleanup.sh
    [[ $(apo_state_get NETWORK_WATCHDOG_INSTALLED_BY_RUN 0) == 1 ]] || return 0
    [[ $(apo_state_get NETWORK_WATCHDOG_INSTALL_KIND '') == batocera-network-companion ]] || {
        APO_LAST_CLASS=RECOVERY_FAILURE
        APO_LAST_REASON='The run-owned Batocera watchdog provider is malformed.'
        return 1
    }
    apo_remote_upload_root "$installer" "$remote_installer" || return 1
    apo_state_set NETWORK_WATCHDOG_INSTALL_STATUS CLEANING
    apo_state_save
    apo_run_worker_capture network-watchdog-cleanup cleanup-network-watchdog-companion \
        "$remote_installer" "$APO_RUN_ID" \
        "$(apo_state_get NETWORK_WATCHDOG_INSTALL_BACKUP '')" \
        "$(apo_state_get NETWORK_WATCHDOG_INSTALL_CONFIG_HASH '')" \
        "$(apo_state_get NETWORK_WATCHDOG_INSTALL_KEEPER_HASH '')" \
        "$(apo_state_get NETWORK_WATCHDOG_INSTALL_SERVICE_HASH '')" \
        "$(apo_state_get NETWORK_WATCHDOG_INSTALL_PLATFORM_OLD_HASH '')" \
        "$(apo_state_get NETWORK_WATCHDOG_INSTALL_PLATFORM_NEW_HASH '')" || return 1
    apo_state_set NETWORK_WATCHDOG_INSTALLED_BY_RUN 0
    apo_state_set NETWORK_WATCHDOG_INSTALL_STATUS REMOVED
    apo_state_save
    apo_event network-watchdog-cleanup PASS '' 'Removed only the run-owned Batocera network-watchdog companion and retained native watchdogs and durable evidence.'
}

apo_profile_repair_watchdogs() {
    local expected="PREPARE-WATCHDOGS ${APO_TARGET_SLUG}" old_boot_id new_boot_id
    local local_asset_dir="${APO_ROOT}/assets/batocera" remote_asset_dir="${APO_REMOTE_WORK_DIR}/watchdog-assets"
    local local_installer="${local_asset_dir}/install_watchdog.sh" local_keeper="${local_asset_dir}/watchdog_keeper.py"
    local local_service="${local_asset_dir}/AutoPiOverclockWatchdog"
    local remote_installer="${remote_asset_dir}/install_watchdog.sh" remote_keeper="${remote_asset_dir}/watchdog_keeper.py"
    local remote_service="${remote_asset_dir}/AutoPiOverclockWatchdog"
    local old_hash expected_hash target cmdline_old cmdline_new batocera_old batocera_new
    local keeper_hash service_hash keeper_config_hash eeprom_hash eeprom_current_timeout eeprom_timeout eeprom_apply_required
    local repair_hash reported_target backup_file

    [[ -r $local_installer && -r $local_keeper && -r $local_service ]] || {
        apo_event watchdog-repair ERROR PREFLIGHT_FAILURE 'The packaged Batocera watchdog assets are missing.'
        return 1
    }
    apo_remote_upload_root "$local_installer" "$remote_installer" || return 1
    apo_remote_upload_root "$local_keeper" "$remote_keeper" || return 1
    apo_remote_upload_root "$local_service" "$remote_service" || return 1
    apo_run_worker_capture watchdog-repair-plan plan-watchdog-repair \
        "$remote_installer" "$remote_keeper" "$remote_service" "$APO_RUN_ID" || return 1
    apo_parse_data_file "$APO_LAST_WORKER_LOG" APO_WORKER_DATA
    old_hash=${APO_WORKER_DATA[WATCHDOG_REPAIR_OLD_HASH]:-}
    expected_hash=${APO_WORKER_DATA[WATCHDOG_REPAIR_EXPECTED_HASH]:-}
    target=${APO_WORKER_DATA[WATCHDOG_REPAIR_TARGET]:-}
    cmdline_old=${APO_WORKER_DATA[WATCHDOG_REPAIR_CMDLINE_OLD_HASH]:-}
    cmdline_new=${APO_WORKER_DATA[WATCHDOG_REPAIR_CMDLINE_NEW_HASH]:-}
    batocera_old=${APO_WORKER_DATA[WATCHDOG_REPAIR_BATOCERA_OLD_HASH]:-}
    batocera_new=${APO_WORKER_DATA[WATCHDOG_REPAIR_BATOCERA_NEW_HASH]:-}
    keeper_hash=${APO_WORKER_DATA[WATCHDOG_REPAIR_KEEPER_HASH]:-}
    service_hash=${APO_WORKER_DATA[WATCHDOG_REPAIR_SERVICE_HASH]:-}
    keeper_config_hash=${APO_WORKER_DATA[WATCHDOG_REPAIR_KEEPER_CONFIG_HASH]:-}
    eeprom_hash=${APO_WORKER_DATA[WATCHDOG_REPAIR_EEPROM_HASH]:-}
    eeprom_current_timeout=${APO_WORKER_DATA[WATCHDOG_REPAIR_EEPROM_CURRENT_TIMEOUT]:-}
    eeprom_timeout=${APO_WORKER_DATA[WATCHDOG_REPAIR_EEPROM_TIMEOUT]:-}
    eeprom_apply_required=${APO_WORKER_DATA[WATCHDOG_REPAIR_EEPROM_APPLY_REQUIRED]:-}
    if [[ $old_hash != "$APO_PERMANENT_CONFIG_HASH" || ! $expected_hash =~ ^[0-9a-f]{64}$ ||
          ! $cmdline_old =~ ^[0-9a-f]{64}$ || ! $cmdline_new =~ ^[0-9a-f]{64}$ ||
          ! $batocera_old =~ ^[0-9a-f]{64}$ || ! $batocera_new =~ ^[0-9a-f]{64}$ ||
          ! $keeper_hash =~ ^[0-9a-f]{64}$ || ! $service_hash =~ ^[0-9a-f]{64}$ ||
          ! $keeper_config_hash =~ ^[0-9a-f]{64}$ || ! $eeprom_hash =~ ^[0-9a-f]{64}$ || -z $target ]] ||
       ! apo_is_uint "$eeprom_current_timeout" || ! apo_is_uint "$eeprom_timeout" || (( eeprom_timeout == 0 )) ||
       [[ $eeprom_apply_required != 0 && $eeprom_apply_required != 1 ]] ||
       [[ $eeprom_apply_required == 0 && $eeprom_current_timeout != "$eeprom_timeout" ]] ||
       [[ $eeprom_apply_required == 1 && $eeprom_current_timeout != 0 ]]; then
        apo_state_set WATCHDOG_REPAIR_STATUS PLAN_UNVERIFIED
        apo_state_save
        return 1
    fi
    apo_state_set PHASE PREPARE
    apo_state_set SUBPHASE WATCHDOG_REPAIR_PLANNED
    apo_state_set WATCHDOG_REPAIR_STATUS PLANNED
    apo_state_set WATCHDOG_REPAIR_OLD_HASH "$old_hash"
    apo_state_set WATCHDOG_REPAIR_EXPECTED_HASH "$expected_hash"
    apo_state_set WATCHDOG_REPAIR_TARGET "$target"
    apo_state_set WATCHDOG_REPAIR_CMDLINE_OLD_HASH "$cmdline_old"
    apo_state_set WATCHDOG_REPAIR_CMDLINE_NEW_HASH "$cmdline_new"
    apo_state_set WATCHDOG_REPAIR_BATOCERA_OLD_HASH "$batocera_old"
    apo_state_set WATCHDOG_REPAIR_BATOCERA_NEW_HASH "$batocera_new"
    apo_state_set WATCHDOG_REPAIR_KEEPER_HASH "$keeper_hash"
    apo_state_set WATCHDOG_REPAIR_SERVICE_HASH "$service_hash"
    apo_state_set WATCHDOG_REPAIR_KEEPER_CONFIG_HASH "$keeper_config_hash"
    apo_state_set WATCHDOG_REPAIR_EEPROM_HASH "$eeprom_hash"
    apo_state_set WATCHDOG_REPAIR_EEPROM_CURRENT_TIMEOUT "$eeprom_current_timeout"
    apo_state_set WATCHDOG_REPAIR_EEPROM_TIMEOUT "$eeprom_timeout"
    apo_state_set WATCHDOG_REPAIR_EEPROM_APPLY_REQUIRED "$eeprom_apply_required"
    apo_state_save
    if [[ $eeprom_apply_required == 0 ]]; then
        apo_info "The existing positive EEPROM boot-watchdog timeout (${eeprom_timeout}s) is already valid and will be preserved; no EEPROM update will be scheduled."
    else
        apo_info "The EEPROM boot watchdog is disabled; prepare will schedule a ${eeprom_timeout}s timeout and retain the updater diagnostics."
    fi
    if (( ${APO_AUTO_PREPARE:-0} == 1 )); then
        apo_info "The explicit prepare command authorizes the planned Batocera watchdog installation for liveness target $target and its verification reboot."
    else
        apo_confirm_exact "Prepare will install a project-owned Batocera watchdog, preserve verified backups, use $target as its liveness target, bound network-loss recovery to three reboots per 30 minutes, and reboot ${APO_REMOTE_TARGET}." "$expected" || return 1
    fi
    apo_state_set MUTATIONS_STARTED 1
    apo_state_set WATCHDOG_REPAIR_STATUS MUTATING
    apo_state_set SUBPHASE WATCHDOG_REPAIR_MUTATING
    apo_state_save
    apo_run_worker_capture watchdog-repair repair-watchdogs \
        "$remote_installer" "$remote_keeper" "$remote_service" "$APO_RUN_ID" "$target" \
        "$old_hash" "$expected_hash" "$cmdline_old" "$cmdline_new" "$batocera_old" "$batocera_new" \
        "$keeper_hash" "$service_hash" "$keeper_config_hash" "$eeprom_hash" \
        "$eeprom_current_timeout" "$eeprom_timeout" "$eeprom_apply_required" || return 1
    apo_parse_data_file "$APO_LAST_WORKER_LOG" APO_WORKER_DATA
    repair_hash=${APO_WORKER_DATA[WATCHDOG_REPAIR_NEW_HASH]:-}
    reported_target=${APO_WORKER_DATA[WATCHDOG_REPAIR_TARGET]:-}
    backup_file=${APO_WORKER_DATA[WATCHDOG_CONFIG_BACKUP]:-}
    if [[ $repair_hash != "$expected_hash" || $reported_target != "$target" || -z $backup_file ]]; then
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

apo_profile_cleanup_worker() { apo_remote_root "rm -rf $(apo_sh_quote "$APO_REMOTE_WORK_DIR")" >/dev/null 2>&1 || true; }
