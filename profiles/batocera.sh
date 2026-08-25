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
        "${APO_ROOT}/tools/build-batocera-bundle.sh" "$bundle_dir" || return 1
    fi
    apo_profile_batocera_bundle_ready "$bundle_file" || return 1
    apo_event dependencies INFO '' 'Uploading portable glmark2 bundle to Batocera persistent storage'
    apo_remote_upload_root "$bundle_file" "$remote_bundle" || return 1
    remote_command=$(apo_profile_batocera_bundle_install_command "$remote_bundle") || return 1
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
