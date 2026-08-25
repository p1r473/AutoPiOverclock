#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
FIXTURES="$ROOT/tests/fixtures"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# A newly booted target can accept SSH before its configured application stack
# is ready.  Both profiles must retry the whole readiness probe instead of
# failing on the first process, service, audio, or graphical miss.
APO_WORKER_LIBRARY_ONLY=1 WORKER="$ROOT/workers/debian-worker.sh" AUDIO_ATTEMPTS_FILE="$TEMP_DIR/debian-audio-attempts" bash -c '
    set -Eeuo pipefail
    source "$WORKER"
    printf "0\n" > "$AUDIO_ATTEMPTS_FILE"
    check_required_processes() { :; }
    check_required_services() { :; }
    audio_inspect() {
        local attempts
        read -r attempts < "$AUDIO_ATTEMPTS_FILE"
        attempts=$((attempts + 1))
        printf "%s\n" "$attempts" > "$AUDIO_ATTEMPTS_FILE"
        if (( attempts >= 3 )); then printf "fixture-audio\n"; else printf "starting\n"; fi
    }
    sleep() { :; }
    wait_application_health headless "" fixture-process fixture-service fixture-audio ""
    [[ $(<"$AUDIO_ATTEMPTS_FILE") == 3 ]]
'

# A Debian graphical target can have a healthy DRM display without running a
# desktop audio server.  Preserve audio when discovery captured it, but do not
# misclassify a display-only graphical baseline as a failed display harness.
APO_WORKER_LIBRARY_ONLY=1 WORKER="$ROOT/workers/debian-worker.sh" bash -c '
    set -Eeuo pipefail
    source "$WORKER"
    check_required_processes() { :; }
    check_required_services() { :; }
    check_display() { :; }
    audio_identity() { return 1; }
    application_health_ready graphical fixture-display "" "" "" ""
    [[ -z ${APPLICATION_READINESS_LAST_FAILURE:-} ]]
    if application_health_ready graphical fixture-display "" "" "" fixture-audio; then exit 1; fi
    [[ $APPLICATION_READINESS_LAST_FAILURE == audio-unavailable ]]
'

APO_WORKER_LIBRARY_ONLY=1 WORKER="$ROOT/workers/batocera-worker.sh" bash -c '
    set -Eeuo pipefail
    source "$WORKER"
    service_attempts=0
    graphical_checks=0
    check_required_processes() { :; }
    check_required_services() {
        service_attempts=$((service_attempts + 1))
        (( service_attempts >= 3 ))
    }
    batocera_environment() { :; }
    wpctl() { printf "fixture-audio\n"; }
    timeout() { shift; "$@"; }
    audio_identity() { printf "fixture-baseline-audio"; }
    check_graphical() { graphical_checks=$((graphical_checks + 1)); return 0; }
    sleep() { :; }
    wait_application_health graphical fixture-display fixture-frontend fixture-watchdog fixture-audio fixture-baseline-audio
    [[ $service_attempts == 3 ]]
    [[ $graphical_checks == 1 ]]
'

for worker_name in debian batocera; do
    if [[ $worker_name == debian ]]; then expected_deadline=60; else expected_deadline=180; fi
    APO_WORKER_LIBRARY_ONLY=1 WORKER="$ROOT/workers/${worker_name}-worker.sh" EXPECTED_DEADLINE=$expected_deadline bash -c '
        set -Eeuo pipefail
        source "$WORKER"
        application_health_ready() { return 1; }
        sleep() { SECONDS=$((SECONDS + $1)); }
        started=$SECONDS
        if wait_application_health headless "" "" "" "" ""; then exit 1; fi
        [[ $((SECONDS - started)) == "$EXPECTED_DEADLINE" ]]
        [[ -z ${APPLICATION_READINESS_DEADLINE+x} ]]
    '
    grep -Fq 'gpu_key=v3d_freq' "$ROOT/workers/${worker_name}-worker.sh"
    if grep -Eq 'normal_cpu=.*2400|normal_gpu=.*800' "$ROOT/workers/${worker_name}-worker.sh"; then
        echo "$worker_name worker still contains a hardcoded normal clock fallback" >&2
        exit 1
    fi
done

cat > "$TEMP_DIR/config.txt" <<'CONF'
# Preserve this comment
[all]
dtparam=audio=on
# BEGIN AUTOPIOVERCLOCK MANAGED CLOCKS
# old block
arm_freq=9999
# END AUTOPIOVERCLOCK MANAGED CLOCKS
# Preserve trailing comment
CONF

APO_WORKER_LIBRARY_ONLY=1 source "$ROOT/workers/debian-worker.sh"

# grep -q can close this help pipe after the first match.  With pipefail that
# turns the producer's expected SIGPIPE into a false "GPU unavailable" result.
# Keep enough trailing help text to exercise that failure mode, and require an
# exact --gpu option rather than accepting a longer option with the same prefix.
mkdir -p "$TEMP_DIR/stress-ng-bin"
cat > "$TEMP_DIR/stress-ng-bin/stress-ng" <<'STRESS_NG'
#!/usr/bin/env bash
set -e
[[ ${1-} == --help ]] || exit 1
printf '      %s N  start N GPU workers\n' "${MOCK_STRESS_NG_OPTION:---gpu}"
for ((line = 0; line < 20000; line++)); do
    printf '      --fixture-option-%05d N  trailing help text for pipe coverage\n' "$line"
done
STRESS_NG
chmod 700 "$TEMP_DIR/stress-ng-bin/stress-ng"
ORIGINAL_PATH=$PATH
PATH="$TEMP_DIR/stress-ng-bin:$PATH"
export MOCK_STRESS_NG_OPTION=--gpu
stress_ng_has_gpu
export MOCK_STRESS_NG_OPTION=--gpu-ops
if stress_ng_has_gpu; then
    echo 'stress-ng GPU detection accepted --gpu-ops as the --gpu stressor' >&2
    exit 1
fi
unset MOCK_STRESS_NG_OPTION
PATH=$ORIGINAL_PATH

throttle_clean_relative throttled=0x50000 throttled=0x50000
if throttle_clean_relative throttled=0x50001 throttled=0x50000; then exit 1; fi
if throttle_clean_relative throttled=0xD0000 throttled=0x50000; then exit 1; fi
render_clock_config "$TEMP_DIR/config.txt" "$TEMP_DIR/rendered.txt" 2900 900 gpu_freq 50000 fixture-run
[[ $(grep -c '^# BEGIN AUTOPIOVERCLOCK MANAGED CLOCKS$' "$TEMP_DIR/rendered.txt") -eq 1 ]]
grep -q '^# Preserve this comment$' "$TEMP_DIR/rendered.txt"
grep -q '^# Preserve trailing comment$' "$TEMP_DIR/rendered.txt"
grep -q '^arm_freq=2900$' "$TEMP_DIR/rendered.txt"
grep -q '^gpu_freq=900$' "$TEMP_DIR/rendered.txt"

DEBIAN_PERMANENT_HASH=$(sha256sum "$TEMP_DIR/config.txt" | awk '{print $1}')
DEBIAN_OWNERSHIP_TOKEN=$(printf '1%.0s' {1..64})
DEBIAN_QUARANTINE="$TEMP_DIR/.autopioverclock-remove-$DEBIAN_OWNERSHIP_TOKEN"
render_tryboot_config "$TEMP_DIR/config.txt" "$TEMP_DIR/tryboot.txt" 2900 900 v3d_freq 25000 cleanup-fixture "$DEBIAN_OWNERSHIP_TOKEN"
DEBIAN_TRYBOOT_HASH=$(sha256sum "$TEMP_DIR/tryboot.txt" | awk '{print $1}')
DEBIAN_RESERVATION_HASH=$(render_tryboot_reservation cleanup-fixture "$DEBIAN_OWNERSHIP_TOKEN" | sha256sum | awk '{print $1}')
cmd_clear_tryboot "$TEMP_DIR/config.txt" "$TEMP_DIR/tryboot.txt" "$DEBIAN_QUARANTINE" "$DEBIAN_PERMANENT_HASH" "$DEBIAN_TRYBOOT_HASH" "$DEBIAN_RESERVATION_HASH" cleanup-fixture "$DEBIAN_OWNERSHIP_TOKEN" >/dev/null
[[ ! -e $TEMP_DIR/tryboot.txt ]]
printf 'foreign tryboot content\n' > "$TEMP_DIR/tryboot.txt"
DEBIAN_FOREIGN_HASH=$(sha256sum "$TEMP_DIR/tryboot.txt" | awk '{print $1}')
DEBIAN_FOREIGN_RESERVATION_HASH=$(render_tryboot_reservation cleanup-fixture "$DEBIAN_OWNERSHIP_TOKEN" | sha256sum | awk '{print $1}')
if cmd_clear_tryboot "$TEMP_DIR/config.txt" "$TEMP_DIR/tryboot.txt" "$DEBIAN_QUARANTINE" "$DEBIAN_PERMANENT_HASH" "$DEBIAN_FOREIGN_HASH" "$DEBIAN_FOREIGN_RESERVATION_HASH" cleanup-fixture "$DEBIAN_OWNERSHIP_TOKEN" >/dev/null; then
    echo 'foreign tryboot content was removed as though it belonged to the run' >&2
    exit 1
fi
[[ -e $TEMP_DIR/tryboot.txt ]]

mkdir -p "$TEMP_DIR/debian-drm/card1-HDMI-A-1"
printf 'connected\n' > "$TEMP_DIR/debian-drm/card1-HDMI-A-1/status"
printf 'disabled\n' > "$TEMP_DIR/debian-drm/card1-HDMI-A-1/enabled"
printf '1920x1080\n' > "$TEMP_DIR/debian-drm/card1-HDMI-A-1/modes"
display_hardware_present "$TEMP_DIR/debian-drm"
if connected_display_baseline "$TEMP_DIR/debian-drm" >/dev/null; then exit 1; fi
printf 'enabled\n' > "$TEMP_DIR/debian-drm/card1-HDMI-A-1/enabled"
[[ $(connected_display_baseline "$TEMP_DIR/debian-drm") == 'connector=card1-HDMI-A-1;mode=1920x1080;enabled=enabled' ]]
printf 'disconnected\n' > "$TEMP_DIR/debian-drm/card1-HDMI-A-1/status"
if display_hardware_present "$TEMP_DIR/debian-drm"; then exit 1; fi

(
    printf '[pi4]\narm_freq=9999\n' > "$TEMP_DIR/inactive-config.txt"
    vcgencmd() {
        [[ $1 == get_config ]] || return 1
        [[ ${2:-} == arm_freq ]] && printf 'arm_freq=2400\n'
    }
    [[ $(active_config_value arm_freq) == 2400 ]]
    [[ $(discovered_config_value arm_freq "$TEMP_DIR/inactive-config.txt") == 2400 ]]
    vcgencmd() { :; }
    [[ -z $(active_config_value arm_freq) ]]
    [[ -z $(discovered_config_value arm_freq "$TEMP_DIR/inactive-config.txt") ]]
)
mkdir -p "$TEMP_DIR/debian-audio-bin"
printf '#!/bin/sh\nprintf '\''    node.name = "alsa_output.debian-fixture"\\n'\''\n' > "$TEMP_DIR/debian-audio-bin/wpctl"
chmod 755 "$TEMP_DIR/debian-audio-bin/wpctl"
[[ $(PATH="$TEMP_DIR/debian-audio-bin:$PATH" audio_identity) == alsa_output.debian-fixture ]]
printf '#!/bin/sh\nprintf '\''id 42, type PipeWire:Interface:Node/3\\n  * node.name = "alsa_output.debian-starred-fixture"\\n'\''\n' > "$TEMP_DIR/debian-audio-bin/wpctl"
[[ $(PATH="$TEMP_DIR/debian-audio-bin:$PATH" audio_identity) == alsa_output.debian-starred-fixture ]]

set +e
DEBIAN_USB_OUTPUT=$("$ROOT/workers/debian-worker.sh" classify-kernel-log "$FIXTURES/root-usb-reset.log" /dev/sda2 2>&1)
DEBIAN_USB_RC=$?
set -e
[[ $DEBIAN_USB_RC -ne 0 && $DEBIAN_USB_OUTPUT == *'APO_RESULT_CLASS=STABILITY_FAILURE'* ]]
set +e
MMC_OUTPUT=$("$ROOT/workers/debian-worker.sh" classify-kernel-log "$FIXTURES/root-usb-reset.log" /dev/mmcblk0p2 2>&1)
MMC_RC=$?
set -e
[[ $MMC_RC -ne 0 && $MMC_OUTPUT == *'APO_RESULT_CLASS=STABILITY_FAILURE'* ]]

set +e
BATOCERA_MMC_OUTPUT=$("$ROOT/workers/batocera-worker.sh" classify-kernel-log "$FIXTURES/root-usb-reset.log" /dev/mmcblk0p2 2>&1)
BATOCERA_MMC_RC=$?
set -e
[[ $BATOCERA_MMC_RC -ne 0 && $BATOCERA_MMC_OUTPUT == *'APO_RESULT_CLASS=STABILITY_FAILURE'* ]]

set +e
EXT4_OUTPUT=$("$ROOT/workers/batocera-worker.sh" classify-kernel-log "$FIXTURES/ext4-error.log" /dev/sda2 2>&1)
EXT4_RC=$?
set -e
[[ $EXT4_RC -ne 0 && $EXT4_OUTPUT == *'APO_RESULT_CLASS=STABILITY_FAILURE'* ]]

APO_WORKER_LIBRARY_ONLY=1 source "$ROOT/workers/batocera-worker.sh"
throttle_clean_relative throttled=0x50000 throttled=0x50000
if throttle_clean_relative throttled=0x50001 throttled=0x50000; then exit 1; fi

# Exercise the production Batocera mount-option parser directly.  The target's
# awk rejects builtin function names as assignment targets, so this helper must
# not depend on the previously broken `for(index=...)` program.
cat > "$TEMP_DIR/batocera-mounts-ro" <<'MOUNTS'
overlay / overlay rw,relatime 0 0
/dev/sda1 /boot vfat ro,relatime,fmask=0022,errors=remount-ro 0 0
MOUNTS
cat > "$TEMP_DIR/batocera-mounts-rw" <<'MOUNTS'
overlay / overlay rw,relatime 0 0
/dev/sda1 /boot vfat rw,relatime,fmask=0022,errors=remount-ro 0 0
MOUNTS
awk() { return 97; }
boot_mount_has_option ro "$TEMP_DIR/batocera-mounts-ro"
if boot_mount_has_option rw "$TEMP_DIR/batocera-mounts-ro"; then exit 1; fi
boot_mount_has_option rw "$TEMP_DIR/batocera-mounts-rw"
if boot_mount_has_option ro "$TEMP_DIR/batocera-mounts-rw"; then exit 1; fi
if boot_mount_has_option invalid "$TEMP_DIR/batocera-mounts-rw"; then exit 1; fi
if boot_mount_has_option rw "$TEMP_DIR/missing-mounts"; then exit 1; fi
unset -f awk

# A forced graphical-session recovery reboot rechecks every safety invariant
# inside the target mutation lock immediately before rebooting.  Ordinary
# tryboot recovery keeps the existing argument-free reboot behavior.
(
    EXPECTED_HASH=$(printf 'a%.0s' {1..64})
    CURRENT_HASH=$EXPECTED_HASH
    TRYBOOT_CLEAR=1
    BOOT_RO=1
    REBOOT_CALLS=0
    VERIFIED_REBOOT_CALLS=0
    vcgencmd() { :; }
    sync() { :; }
    reboot() { REBOOT_CALLS=$((REBOOT_CALLS + 1)); }
    verified_normal_reboot_now() { VERIFIED_REBOOT_CALLS=$((VERIFIED_REBOOT_CALLS + 1)); return 1; }
    apply_tryboot_clear() { (( TRYBOOT_CLEAR == 1 )); }
    boot_mount_has_option() { [[ $1 == ro && $BOOT_RO == 1 ]]; }
    sha256sum() { printf '%s  /boot/config.txt\n' "$CURRENT_HASH"; }

    if cmd_reboot_normal "$EXPECTED_HASH" >/dev/null; then exit 1; fi
    [[ $VERIFIED_REBOOT_CALLS == 1 && $REBOOT_CALLS == 0 ]]

    REBOOT_CALLS=0
    VERIFIED_REBOOT_CALLS=0
    TRYBOOT_CLEAR=0
    BOOT_RO=0
    CURRENT_HASH=not-the-expected-hash
    cmd_reboot_normal
    [[ $REBOOT_CALLS == 1 && $VERIFIED_REBOOT_CALLS == 0 ]]

    REBOOT_CALLS=0
    if cmd_reboot_normal malformed-hash >/dev/null; then exit 1; fi
    [[ $REBOOT_CALLS == 0 && $VERIFIED_REBOOT_CALLS == 0 ]]

    TRYBOOT_CLEAR=0
    BOOT_RO=1
    CURRENT_HASH=$EXPECTED_HASH
    if cmd_reboot_normal "$EXPECTED_HASH" >/dev/null; then exit 1; fi
    [[ $REBOOT_CALLS == 0 && $VERIFIED_REBOOT_CALLS == 0 ]]

    TRYBOOT_CLEAR=1
    BOOT_RO=0
    if cmd_reboot_normal "$EXPECTED_HASH" >/dev/null; then exit 1; fi
    [[ $REBOOT_CALLS == 0 && $VERIFIED_REBOOT_CALLS == 0 ]]

    BOOT_RO=1
    CURRENT_HASH=$(printf 'b%.0s' {1..64})
    if cmd_reboot_normal "$EXPECTED_HASH" >/dev/null; then exit 1; fi
    [[ $REBOOT_CALLS == 0 && $VERIFIED_REBOOT_CALLS == 0 ]]
)

mkdir -p "$TEMP_DIR/fake-bin"
printf '#!/bin/sh\nprintf '\''    node.name = "alsa_output.usb-fixture"\\n'\''\n' > "$TEMP_DIR/fake-bin/wpctl"
chmod 755 "$TEMP_DIR/fake-bin/wpctl"
[[ $(PATH="$TEMP_DIR/fake-bin:$PATH" audio_identity) == alsa_output.usb-fixture ]]
printf '#!/bin/sh\nprintf '\''id 42, type PipeWire:Interface:Node/3\\n  * node.name = "alsa_output.usb-starred-fixture"\\n'\''\n' > "$TEMP_DIR/fake-bin/wpctl"
[[ $(PATH="$TEMP_DIR/fake-bin:$PATH" audio_identity) == alsa_output.usb-starred-fixture ]]
mkdir -p "$TEMP_DIR/drm/card1-HDMI-A-1"
printf 'connected\n' > "$TEMP_DIR/drm/card1-HDMI-A-1/status"
display_hardware_present "$TEMP_DIR/drm"
printf 'disconnected\n' > "$TEMP_DIR/drm/card1-HDMI-A-1/status"
if display_hardware_present "$TEMP_DIR/drm"; then exit 1; fi
printf '    GL_RENDERER: V3D 7.1\nglmark2 Score: 42\n' > "$TEMP_DIR/v3d-pass.log"
printf '    GL_RENDERER: llvmpipe (LLVM 19)\nglmark2 Score: 42\n' > "$TEMP_DIR/software-renderer.log"
printf 'EGL initialization failed: undefined symbol\n' > "$TEMP_DIR/egl-failure.log"
printf '    GL_RENDERER: V3D 7.1\nglmark2 Score: 42\nopenvt: Couldn'\''t deallocate console 1\n' > "$TEMP_DIR/openvt-failure.log"
gpu_output_has_v3d_renderer "$TEMP_DIR/v3d-pass.log"
gpu_output_has_positive_score "$TEMP_DIR/v3d-pass.log"
if gpu_output_has_v3d_renderer "$TEMP_DIR/software-renderer.log"; then exit 1; fi
gpu_output_has_harness_error "$TEMP_DIR/egl-failure.log"
gpu_output_has_harness_error "$TEMP_DIR/openvt-failure.log"
[[ $(gpu_early_exit_class 0 "$TEMP_DIR/v3d-pass.log") == HARNESS_FAILURE ]]
[[ $(gpu_early_exit_class 1 "$TEMP_DIR/v3d-pass.log") == STABILITY_FAILURE ]]
[[ $(gpu_early_exit_class 1 "$TEMP_DIR/egl-failure.log") == HARNESS_FAILURE ]]
[[ $(gpu_early_exit_class 8 "$TEMP_DIR/openvt-failure.log") == HARNESS_FAILURE ]]
SWAY_OUTPUTS='[{"name":"HDMI-A-1","active":false},{"name":"HDMI-A-2","active":true}]'
[[ $(sway_first_active_connector "$SWAY_OUTPUTS") == HDMI-A-2 ]]
sway_connector_is_active "$SWAY_OUTPUTS" HDMI-A-2
if sway_connector_is_active "$SWAY_OUTPUTS" HDMI-A-1; then exit 1; fi
if sway_connector_is_active 'not-json' HDMI-A-2; then exit 1; fi
(
    stress_frontend_stopped=1
    stress_frontend_restore_attempted=0
    stress_frontend_baseline='connector=HDMI-A-2;mode=1920x1080.60000;frontend=emulationstation'
    frontend_started=0
    check_graphical() { return 1; }
    start_frontend() { frontend_started=1; }
    wait_graphical_baseline() { [[ $1 == "$stress_frontend_baseline" ]]; }
    restore_frontend_baseline
    [[ $frontend_started == 1 && $stress_frontend_stopped == 0 ]]
)
(
    stress_frontend_stopped=1
    stress_frontend_restore_attempted=0
    stress_frontend_baseline='connector=HDMI-A-2;mode=1920x1080.60000;frontend=emulationstation'
    frontend_waits=0
    check_graphical() { return 1; }
    start_frontend() { return 1; }
    wait_graphical_baseline() { frontend_waits=$((frontend_waits + 1)); return 1; }
    if restore_frontend_baseline; then exit 1; fi
    [[ $stress_frontend_stopped == 1 ]]
    if cleanup_stress; then exit 1; fi
    [[ $frontend_waits == 1 ]]
)
(
    stress_frontend_stopped=1
    stress_frontend_restore_attempted=0
    stress_frontend_baseline='connector=HDMI-A-2;mode=1920x1080.60000;frontend=emulationstation'
    frontend_waits=0
    check_graphical() { return 1; }
    start_frontend() { :; }
    wait_graphical_baseline() { frontend_waits=$((frontend_waits + 1)); return 0; }
    cleanup_stress
    [[ $frontend_waits == 1 && $stress_frontend_stopped == 0 ]]
)
(
    stress_audio_baseline=fixture-audio
    check_graphical() { :; }
    audio_identity() { printf fixture-audio; }
    frontend_baseline_ready fixture-display
    audio_identity() { return 1; }
    if frontend_baseline_ready fixture-display; then
        echo 'Batocera frontend recovery accepted a missing saved audio sink' >&2
        exit 1
    fi
)
(
    stress_frontend_stopped=1
    stress_frontend_restore_attempted=0
    stress_frontend_baseline=fixture-display
    stress_audio_baseline=fixture-audio
    frontend_started=0
    check_graphical() { :; }
    audio_identity() { return 1; }
    start_frontend() { frontend_started=$((frontend_started + 1)); }
    sleep() { :; }
    if restore_frontend_baseline; then
        echo 'Batocera frontend restore accepted a display without its saved audio sink' >&2
        exit 1
    fi
    [[ $frontend_started == 1 && $stress_frontend_restore_attempted == 1 && $stress_frontend_stopped == 1 ]]
)
set +e
FRONTEND_RECOVERY_OUTPUT=$(
    (
        find_glmark_binary() { printf /bin/true; }
        find_glmark_data() { printf '%s' "$TEMP_DIR"; }
        find_glmark_library_dirs() { :; }
        gpu_stack_probe() { printf 'render_node=/dev/dri/renderD128;driver=v3d'; }
        stop_frontend() { return 1; }
        restore_frontend_baseline() { return 1; }
        cmd_stress gpu 20 75 graphical 'connector=HDMI-A-2;mode=1920x1080.60000;frontend=emulationstation' 0 2400 800 throttled=0x0
    ) 2>&1
)
FRONTEND_RECOVERY_RC=$?
set -e
[[ $FRONTEND_RECOVERY_RC -ne 0 ]]
[[ $FRONTEND_RECOVERY_OUTPUT == *'APO_RESULT_CLASS=RECOVERY_FAILURE'* ]]

# Exercise the real cmd_stress failure/return path and its still-armed EXIT
# trap. A failed explicit restore must be remembered before process exit so
# cleanup_stress cannot start a second 180-second frontend wait.
PROCESS_RESTORE_WAITS="$TEMP_DIR/process-restore-waits"
printf '0\n' > "$PROCESS_RESTORE_WAITS"
set +e
PROCESS_RESTORE_OUTPUT=$(APO_WORKER_LIBRARY_ONLY=1 WORKER="$ROOT/workers/batocera-worker.sh" \
    RESTORE_WAITS_FILE="$PROCESS_RESTORE_WAITS" FIXTURE_DATA_DIR="$TEMP_DIR" bash -c '
    set -u -o pipefail
    source "$WORKER"
    current_temp() { printf 50; }
    current_throttle() { printf "throttled=0x0"; }
    clock_mhz() { case $1 in arm) printf 2400 ;; *) printf 800 ;; esac; }
    kernel_log() { :; }
    kernel_error_lines() { :; }
    find_glmark_binary() { printf /bin/true; }
    find_glmark_data() { printf "%s" "$FIXTURE_DATA_DIR"; }
    find_glmark_library_dirs() { :; }
    gpu_stack_probe() { printf "render_node=/dev/dri/renderD128;driver=v3d"; }
    write_glmark_launcher() { : > "$1"; }
    stop_frontend() { return 0; }
    frontend_baseline_ready() { return 1; }
    activate_stress_previous_vt() { return 0; }
    start_frontend() { return 0; }
    wait_graphical_baseline() {
        local completed
        read -r completed < "$RESTORE_WAITS_FILE"
        printf "%s\n" "$((completed + 1))" > "$RESTORE_WAITS_FILE"
        return 1
    }
    launch_gpu_test() {
        local launcher_file=$1 output_file=$2 mode=$3
        stress_gpu_uses_openvt=0
        stress_gpu_previous_vt=
        (
            command /bin/sleep 0.1
            printf "openvt: Couldn'\''t deallocate console 1\n" >> "$output_file"
            exit 8
        ) &
        stress_gpu_pid=$!
    }
    sleep() { command /bin/sleep 0.15; SECONDS=$((SECONDS + $1)); }
    set +e
    cmd_stress gpu 20 75 graphical fixture-display 0 2400 800 throttled=0x0 60 fixture-audio
    stress_rc=$?
    exit "$stress_rc"
' 2>&1)
PROCESS_RESTORE_RC=$?
set -e
[[ $PROCESS_RESTORE_RC -ne 0 ]]
[[ $(<"$PROCESS_RESTORE_WAITS") == 1 ]]
[[ $PROCESS_RESTORE_OUTPUT == *'APO_RESULT_CLASS=RECOVERY_FAILURE'* ]]
PROCESS_RESTORE_REASON_B64=$(awk -F= '/^APO_RESULT_REASON_B64=/{sub(/^[^=]*=/, ""); print; exit}' <<< "$PROCESS_RESTORE_OUTPUT")
PROCESS_RESTORE_REASON=$(printf '%s' "$PROCESS_RESTORE_REASON_B64" | base64 --decode)
[[ $PROCESS_RESTORE_REASON == *'Original HARNESS_FAILURE: GPU stress exited early with rc=8.'* ]]
[[ $PROCESS_RESTORE_REASON == *'Batocera frontend restart did not restore the saved graphical baseline.'* ]]

# A signal/EXIT cleanup can arrive at any point in a restore attempt. Exercise
# every externally blocking stage and require the entry marker to prevent a
# nested second restore even before VT activation, service start, or waiting.
for REENTRANT_STAGE in probe activate start wait; do
    REENTRANT_RESTORE_CALLS="$TEMP_DIR/reentrant-restore-calls-$REENTRANT_STAGE"
    REENTRANT_TRIGGERED="$TEMP_DIR/reentrant-triggered-$REENTRANT_STAGE"
    printf '0\n' > "$REENTRANT_RESTORE_CALLS"
    printf '0\n' > "$REENTRANT_TRIGGERED"
    (
        stress_frontend_stopped=1
        stress_frontend_restore_attempted=0
        stress_frontend_baseline=fixture-display
        stress_audio_baseline=fixture-audio
        stress_cpu_pid=
        stress_gpu_pid=
        stress_io_pid=
        stress_io_file=
        stress_work_dir=
        reenter_cleanup_once() {
            local triggered
            read -r triggered < "$REENTRANT_TRIGGERED"
            if (( triggered == 0 )); then
                printf '1\n' > "$REENTRANT_TRIGGERED"
                cleanup_stress || true
            fi
        }
        frontend_baseline_ready() {
            local calls
            read -r calls < "$REENTRANT_RESTORE_CALLS"
            printf '%s\n' "$((calls + 1))" > "$REENTRANT_RESTORE_CALLS"
            [[ $REENTRANT_STAGE == probe ]] && reenter_cleanup_once
            return 1
        }
        activate_stress_previous_vt() {
            [[ $REENTRANT_STAGE == activate ]] && reenter_cleanup_once
            return 0
        }
        start_frontend() {
            [[ $REENTRANT_STAGE == start ]] && reenter_cleanup_once
            return 0
        }
        wait_graphical_baseline() {
            [[ $REENTRANT_STAGE == wait ]] && reenter_cleanup_once
            return 1
        }
        if restore_frontend_baseline; then
            echo "reentrant frontend restore unexpectedly passed at $REENTRANT_STAGE" >&2
            exit 1
        fi
        [[ $(<"$REENTRANT_RESTORE_CALLS") == 1 ]]
        [[ $(<"$REENTRANT_TRIGGERED") == 1 ]]
        [[ $stress_frontend_restore_attempted == 1 && $stress_frontend_stopped == 1 ]]
    )
done

for WORKER_NAME in debian batocera; do
    WORKER_FILE="$ROOT/workers/${WORKER_NAME}-worker.sh"
    set +e
    TELEMETRY_OUTPUT=$(APO_WORKER_LIBRARY_ONLY=1 WORKER="$WORKER_FILE" bash -c '
        source "$WORKER"
        cmd_stress cpu 20 75 headless "" 0 2400 800 throttled=0x0 61
    ' 2>&1)
    TELEMETRY_RC=$?
    set -e
    [[ $TELEMETRY_RC -ne 0 ]]
    [[ $TELEMETRY_OUTPUT == *'APO_RESULT_CLASS=HARNESS_FAILURE'* ]]
    TELEMETRY_REASON_B64=$(awk -F= '/^APO_RESULT_REASON_B64=/{sub(/^[^=]*=/, ""); print; exit}' <<< "$TELEMETRY_OUTPUT")
    TELEMETRY_REASON=$(printf '%s' "$TELEMETRY_REASON_B64" | base64 --decode)
    [[ $TELEMETRY_REASON == 'Telemetry interval must be an integer from 1 to 60 seconds.' ]]
done

# The controller forwards the saved, validated cadence and graphical audio
# baseline rather than leaving either target profile on hard-coded values.
(
    APO_ROOT=$ROOT
    source "$ROOT/lib/common.sh"
    declare -Ag APO_CFG=([MAX_TEMP_C]=75 [TELEMETRY_INTERVAL_S]=7)
    APO_MODE_EFFECTIVE=headless
    APO_DISPLAY_BASELINE=''
    APO_AUDIO_BASELINE=fixture-audio
    APO_THROTTLE_RUNTIME_BASELINE=throttled=0x0
    APO_NORMAL_CPU=2400
    APO_NORMAL_GPU=800
    CAPTURED_WORKER_ARGS=()
    apo_state_get() {
        case $1 in
            CURRENT_CPU) printf 3000 ;;
            CURRENT_GPU) printf 900 ;;
            *) printf '%s' "${2:-}" ;;
        esac
    }
    apo_run_worker_capture() { CAPTURED_WORKER_ARGS=("$@"); }
    source "$ROOT/lib/health.sh"
    apo_verify_permanent_hash() { :; }
    apo_run_stress combined 20 telemetry-forwarding 0
    [[ ${CAPTURED_WORKER_ARGS[1]} == stress ]]
    [[ ${CAPTURED_WORKER_ARGS[8]} == 3000 ]]
    [[ ${CAPTURED_WORKER_ARGS[9]} == 900 ]]
    [[ ${CAPTURED_WORKER_ARGS[11]} == 7 ]]
    [[ ${CAPTURED_WORKER_ARGS[12]} == fixture-audio ]]
)

# Workload supervision is intentionally independent of the configured
# telemetry cadence.  A 60-second cadence must not let a clean, early
# Batocera GPU exit hide past the 20-second smoke-test deadline.
set +e
BATOCERA_EARLY_GPU_OUTPUT=$(APO_WORKER_LIBRARY_ONLY=1 WORKER="$ROOT/workers/batocera-worker.sh" bash -c '
    set -u -o pipefail
    source "$WORKER"
    current_temp() { printf 50; }
    current_throttle() { printf "throttled=0x0"; }
    clock_mhz() { case $1 in arm) printf 2400 ;; *) printf 800 ;; esac; }
    kernel_log() { :; }
    kernel_error_lines() { :; }
    find_glmark_binary() { printf /bin/true; }
    find_glmark_data() { printf /tmp; }
    find_glmark_library_dirs() { :; }
    gpu_stack_probe() { printf "render_node=/dev/dri/renderD128;driver=v3d"; }
    write_glmark_launcher() { : > "$1"; }
    launch_gpu_test() {
        local launcher_file=$1 output_file=$2 mode=$3
        (command /bin/sleep 0.5; printf "    GL_RENDERER: V3D 7.1\nglmark2 Score: 42\n" >> "$output_file") &
        stress_gpu_pid=$!
    }
    sleep() { command /bin/sleep 0.7; SECONDS=$((SECONDS + $1)); }
    cmd_stress gpu 20 75 headless "" 0 2400 800 throttled=0x0 60
' 2>&1)
BATOCERA_EARLY_GPU_RC=$?
set -e
[[ $BATOCERA_EARLY_GPU_RC -ne 0 ]]
[[ $BATOCERA_EARLY_GPU_OUTPUT == *'APO_RESULT_CLASS=HARNESS_FAILURE'* ]]
BATOCERA_EARLY_GPU_REASON_B64=$(awk -F= '/^APO_RESULT_REASON_B64=/{sub(/^[^=]*=/, ""); print; exit}' <<< "$BATOCERA_EARLY_GPU_OUTPUT")
[[ $(printf '%s' "$BATOCERA_EARLY_GPU_REASON_B64" | base64 --decode) == 'GPU stress exited early with rc=0.' ]]

# Debian must classify a sole clean CPU worker before the aggregate all-dead
# branch; the previous ordering silently accepted this case.
set +e
DEBIAN_EARLY_CPU_OUTPUT=$(APO_WORKER_LIBRARY_ONLY=1 WORKER="$ROOT/workers/debian-worker.sh" bash -c '
    set -u -o pipefail
    source "$WORKER"
    current_temp() { printf 50; }
    current_throttle() { printf "throttled=0x0"; }
    clock_mhz() { case $1 in arm) printf 2400 ;; *) printf 800 ;; esac; }
    kernel_log() { :; }
    kernel_error_lines() { :; }
    stress-ng() { command /bin/sleep 0.5; printf "early clean output\n"; }
    sleep() { command /bin/sleep 0.7; SECONDS=$((SECONDS + $1)); }
    cmd_stress cpu 20 75 headless "" 0 2400 800 throttled=0x0 60
' 2>&1)
DEBIAN_EARLY_CPU_RC=$?
set -e
[[ $DEBIAN_EARLY_CPU_RC -ne 0 ]]
[[ $DEBIAN_EARLY_CPU_OUTPUT == *'APO_RESULT_CLASS=HARNESS_FAILURE'* ]]
DEBIAN_EARLY_CPU_REASON_B64=$(awk -F= '/^APO_RESULT_REASON_B64=/{sub(/^[^=]*=/, ""); print; exit}' <<< "$DEBIAN_EARLY_CPU_OUTPUT")
[[ $(printf '%s' "$DEBIAN_EARLY_CPU_REASON_B64" | base64 --decode) == 'CPU stress exited early with rc=0.' ]]

# A poll that wakes after the hard deadline fails closed even when the child
# died between polls; its completion time cannot be proven to precede the
# deadline.  Exercise the same invariant in both workers.
for WORKER_NAME in debian batocera; do
    set +e
    DEADLINE_OUTPUT=$(APO_WORKER_LIBRARY_ONLY=1 WORKER="$ROOT/workers/${WORKER_NAME}-worker.sh" bash -c '
        set -u -o pipefail
        source "$WORKER"
        current_temp() { printf 50; }
        current_throttle() { printf "throttled=0x0"; }
        clock_mhz() { case $1 in arm) printf 2400 ;; *) printf 800 ;; esac; }
        kernel_log() { :; }
        kernel_error_lines() { :; }
        openssl() { command /bin/sleep 0.5; printf "late output\n"; }
        stress-ng() { command /bin/sleep 0.5; printf "late output\n"; }
        sleep() { command /bin/sleep 0.7; SECONDS=$((SECONDS + 100)); }
        cmd_stress cpu 20 75 headless "" 0 2400 800 throttled=0x0 60
    ' 2>&1)
    DEADLINE_RC=$?
    set -e
    [[ $DEADLINE_RC -ne 0 ]]
    [[ $DEADLINE_OUTPUT == *'APO_RESULT_CLASS=HARNESS_FAILURE'* ]]
    DEADLINE_REASON_B64=$(awk -F= '/^APO_RESULT_REASON_B64=/{sub(/^[^=]*=/, ""); print; exit}' <<< "$DEADLINE_OUTPUT")
    [[ $(printf '%s' "$DEADLINE_REASON_B64" | base64 --decode) == 'Stress workers exceeded the requested 20s duration plus a 60s shutdown grace period.' ]]
done

# Completion forces a final telemetry sample even when the configured cadence
# has not elapsed since the initial sample.
FINAL_SAMPLE_FILE="$TEMP_DIR/final-telemetry-samples"
: > "$FINAL_SAMPLE_FILE"
APO_WORKER_LIBRARY_ONLY=1 WORKER="$ROOT/workers/debian-worker.sh" SAMPLE_FILE="$FINAL_SAMPLE_FILE" bash -c '
    set -u -o pipefail
    source "$WORKER"
    current_temp() { printf "sample\n" >> "$SAMPLE_FILE"; printf 50; }
    current_throttle() { printf "throttled=0x0"; }
    clock_mhz() { case $1 in arm) printf 2400 ;; *) printf 800 ;; esac; }
    kernel_log() { :; }
    kernel_error_lines() { :; }
    stress-ng() { command /bin/sleep 0.5; printf "completed output\n"; }
    sleep() { command /bin/sleep 0.7; SECONDS=$((SECONDS + 20)); }
    cmd_stress cpu 20 75 headless "" 0 2400 800 throttled=0x0 60
' >/dev/null 2>&1
[[ $(wc -l < "$FINAL_SAMPLE_FILE") -eq 2 ]]

# The endurance IO companion is polled every second as an independent safety
# workload rather than only when temperature/clock telemetry is due.
set +e
DEBIAN_IO_OUTPUT=$(APO_WORKER_LIBRARY_ONLY=1 WORKER="$ROOT/workers/debian-worker.sh" bash -c '
    set -u -o pipefail
    source "$WORKER"
    current_temp() { printf 50; }
    current_throttle() { printf "throttled=0x0"; }
    clock_mhz() { case $1 in arm) printf 2400 ;; *) printf 800 ;; esac; }
    kernel_log() { :; }
    kernel_error_lines() { :; }
    stress-ng() { command /bin/sleep 2; printf "cpu output\n"; }
    start_io_activity() { (command /bin/sleep 0.5; exit 7) & stress_io_pid=$!; }
    terminate_child() { kill -TERM "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }
    sleep() { command /bin/sleep 0.7; SECONDS=$((SECONDS + $1)); }
    cmd_stress cpu 20 75 headless "" 1 2400 800 throttled=0x0 60
' 2>&1)
DEBIAN_IO_RC=$?
set -e
[[ $DEBIAN_IO_RC -ne 0 ]]
[[ $DEBIAN_IO_OUTPUT == *'APO_RESULT_CLASS=STABILITY_FAILURE'* ]]
DEBIAN_IO_REASON_B64=$(awk -F= '/^APO_RESULT_REASON_B64=/{sub(/^[^=]*=/, ""); print; exit}' <<< "$DEBIAN_IO_OUTPUT")
[[ $(printf '%s' "$DEBIAN_IO_REASON_B64" | base64 --decode) == 'Filesystem activity failed during load with rc=7.' ]]

(
    BOOT_TEST_DIR="$TEMP_DIR/boot-test"
    mkdir -p "$BOOT_TEST_DIR"
    printf '[all]\narm_freq=2400\nv3d_freq=800\n' > "$BOOT_TEST_DIR/config.txt"
    BOOT_TEST_HASH=$(sha256sum "$BOOT_TEST_DIR/config.txt" | awk '{print $1}')
    BOOT_TEST_TOKEN=$(printf '2%.0s' {1..64})
    BOOT_TEST_QUARANTINE="$BOOT_TEST_DIR/.autopioverclock-remove-$BOOT_TEST_TOKEN"
    tryboot_path_allowed() { return 0; }
    boot_mount_has_option() { [[ $1 == ro ]]; }
    reset_recent_throttle() { :; }
    remount_boot_rw() { printf 'rw\n' >> "$BOOT_TEST_DIR/remounts"; return 0; }
    remount_boot_ro() { printf 'ro\n' >> "$BOOT_TEST_DIR/remounts"; return 0; }
    render_tryboot_config "$BOOT_TEST_DIR/config.txt" "$BOOT_TEST_DIR/planned.txt" 2900 900 v3d_freq 50000 fixture-run "$BOOT_TEST_TOKEN"
    BOOT_TEST_PLANNED_HASH=$(sha256sum "$BOOT_TEST_DIR/planned.txt" | awk '{print $1}')
    BOOT_TEST_RESERVATION_HASH=$(render_tryboot_reservation fixture-run "$BOOT_TEST_TOKEN" | sha256sum | awk '{print $1}')
    rm -f -- "$BOOT_TEST_DIR/planned.txt"
    cmd_prepare_candidate "$BOOT_TEST_DIR/config.txt" "$BOOT_TEST_DIR/tryboot.txt" v3d_freq 2900 900 50000 "$BOOT_TEST_HASH" fixture-run "$BOOT_TEST_PLANNED_HASH" "$BOOT_TEST_RESERVATION_HASH" "$BOOT_TEST_TOKEN" "$BOOT_TEST_QUARANTINE" >/dev/null
    BOOT_TEST_TRYBOOT_HASH=$(sha256sum "$BOOT_TEST_DIR/tryboot.txt" | awk '{print $1}')
    [[ $BOOT_TEST_TRYBOOT_HASH == "$BOOT_TEST_PLANNED_HASH" ]]
    grep -q '^arm_freq=2900$' "$BOOT_TEST_DIR/tryboot.txt"
    grep -q '^v3d_freq=900$' "$BOOT_TEST_DIR/tryboot.txt"
    [[ $(paste -sd, "$BOOT_TEST_DIR/remounts") == rw,ro ]]
    [[ $APO_APPLY_BOOT_RW == 0 ]]
    if find "$BOOT_TEST_DIR" -maxdepth 1 -name '.autopioverclock-tryboot.*' | grep -q .; then exit 1; fi
    cmd_verify_tryboot "$BOOT_TEST_DIR/config.txt" "$BOOT_TEST_DIR/tryboot.txt" "$BOOT_TEST_HASH" "$BOOT_TEST_TRYBOOT_HASH" fixture-run "$BOOT_TEST_TOKEN" >/dev/null
    if cmd_verify_tryboot "$BOOT_TEST_DIR/config.txt" "$BOOT_TEST_DIR/tryboot.txt" "$BOOT_TEST_HASH" "$BOOT_TEST_TRYBOOT_HASH" fixture-run "$(printf '3%.0s' {1..64})" >/dev/null 2>&1; then exit 1; fi
    cmd_clear_tryboot "$BOOT_TEST_DIR/config.txt" "$BOOT_TEST_DIR/tryboot.txt" "$BOOT_TEST_QUARANTINE" "$BOOT_TEST_HASH" "$BOOT_TEST_TRYBOOT_HASH" "$BOOT_TEST_RESERVATION_HASH" fixture-run "$BOOT_TEST_TOKEN" >/dev/null
    [[ ! -e $BOOT_TEST_DIR/tryboot.txt ]]
    [[ $(paste -sd, "$BOOT_TEST_DIR/remounts") == rw,ro,rw,ro ]]
    [[ $APO_APPLY_BOOT_RW == 0 ]]
)
write_glmark_launcher "$TEMP_DIR/graphical.sh" 20 /opt/glmark /opt/data /opt/lib graphical
write_glmark_launcher "$TEMP_DIR/headless.sh" 20 /opt/glmark /opt/data /opt/lib headless
bash -n "$TEMP_DIR/graphical.sh"
bash -n "$TEMP_DIR/headless.sh"
grep -q -- '--fullscreen' "$TEMP_DIR/graphical.sh"
if grep -q -- '--off-screen' "$TEMP_DIR/graphical.sh"; then exit 1; fi
grep -q -- '--off-screen' "$TEMP_DIR/headless.sh"
grep -q 'GPU_STRATEGY=graphical-drm' "$TEMP_DIR/graphical.sh"

# A graphical DRM launch must ask openvt for a free VT.  Forcing the already
# active VT with -c/-f makes kbd openvt try to deallocate that active console
# after -w/-s and return rc=8.  openvt also replaces the child's stdio with the
# VT, so the child must explicitly reopen the retained GPU log.
mkdir -p "$TEMP_DIR/openvt-bin"
cat > "$TEMP_DIR/openvt-bin/openvt" <<'OPENVT'
#!/usr/bin/env bash
set -u
if [[ ${1-} == --help ]]; then
    if [[ ${OPENVT_HELP_MODE:-full} == full ]]; then
        printf 'Usage: openvt [-w] [-s] [-f]\n'
    else
        printf 'Usage: openvt [-w]\n'
    fi
    exit 0
fi
printf '%s\n' "$@" > "$OPENVT_CALLS"
for openvt_arg in "$@"; do
    if [[ $openvt_arg == -c ]]; then
        printf "openvt: Couldn't deallocate console 1\n" >&2
        exit 8
    fi
done
while (( $# > 0 )) && [[ $1 != -- ]]; do shift; done
(( $# > 0 )) || exit 64
shift
(( $# > 0 )) || exit 64
# Simulate openvt attaching the command's inherited stdio to the VT.  The
# launcher's inner wrapper must still place its renderer evidence in the log.
"$@" >/dev/null 2>&1
OPENVT
cat > "$TEMP_DIR/openvt-bin/chvt" <<'CHVT'
#!/bin/sh
if [ -n "${CHVT_CALLS:-}" ]; then printf '%s\n' "$@" >> "$CHVT_CALLS"; fi
exit 0
CHVT
cat > "$TEMP_DIR/openvt-launcher.sh" <<'LAUNCHER'
#!/usr/bin/env bash
printf 'GPU_STRATEGY=graphical-drm\n'
printf '    GL_RENDERER: V3D 7.1\n'
printf 'glmark2 Score: 42\n'
exit "${GPU_FIXTURE_RC:-0}"
LAUNCHER
chmod 755 "$TEMP_DIR/openvt-bin/openvt" "$TEMP_DIR/openvt-bin/chvt" "$TEMP_DIR/openvt-launcher.sh"
printf 'tty7\n' > "$TEMP_DIR/active-tty"
printf 'tty-not-a-number\n' > "$TEMP_DIR/malformed-active-tty"
(
    export PATH="$TEMP_DIR/openvt-bin:$PATH"
    export OPENVT_CALLS="$TEMP_DIR/openvt-calls"
    export CHVT_CALLS="$TEMP_DIR/chvt-calls"
    export OPENVT_HELP_MODE=full
    export GPU_FIXTURE_RC=0
    : > "$OPENVT_CALLS"
    : > "$CHVT_CALLS"
    launch_gpu_test "$TEMP_DIR/openvt-launcher.sh" "$TEMP_DIR/openvt-gpu.log" graphical "$TEMP_DIR/active-tty"
    wait "$stress_gpu_pid"
    grep -Fqx -- '-w' "$OPENVT_CALLS"
    grep -Fqx -- '-s' "$OPENVT_CALLS"
    grep -Fqx -- '--' "$OPENVT_CALLS"
    if grep -Fqx -- '-c' "$OPENVT_CALLS"; then exit 1; fi
    if grep -Fqx -- '-f' "$OPENVT_CALLS"; then exit 1; fi
    grep -q '^GPU_VT=auto previous=7$' "$TEMP_DIR/openvt-gpu.log"
    [[ $stress_gpu_uses_openvt == 1 && $stress_gpu_previous_vt == 7 ]]
    [[ ! -s $CHVT_CALLS ]]
    gpu_output_has_v3d_renderer "$TEMP_DIR/openvt-gpu.log"
    gpu_output_has_positive_score "$TEMP_DIR/openvt-gpu.log"

    export GPU_FIXTURE_RC=23
    set +e
    launch_gpu_test "$TEMP_DIR/openvt-launcher.sh" "$TEMP_DIR/openvt-gpu-fail.log" graphical "$TEMP_DIR/active-tty"
    wait "$stress_gpu_pid"
    openvt_rc=$?
    set -e
    [[ $openvt_rc -eq 23 ]]
    gpu_output_has_v3d_renderer "$TEMP_DIR/openvt-gpu-fail.log"

    export OPENVT_HELP_MODE=wait-only
    export GPU_FIXTURE_RC=0
    : > "$OPENVT_CALLS"
    : > "$CHVT_CALLS"
    launch_gpu_test "$TEMP_DIR/openvt-launcher.sh" "$TEMP_DIR/direct-gpu.log" graphical "$TEMP_DIR/active-tty"
    wait "$stress_gpu_pid"
    [[ ! -s $OPENVT_CALLS ]]
    [[ $(<"$CHVT_CALLS") == 7 ]]
    grep -q '^GPU_VT=7 direct=1$' "$TEMP_DIR/direct-gpu.log"
    gpu_output_has_v3d_renderer "$TEMP_DIR/direct-gpu.log"

    # An unreadable or malformed active-VT probe must never guess tty1 or
    # enter openvt -s.  The direct launcher remains available and retains its
    # output, while both VT-recovery state fields remain explicitly clear.
    export OPENVT_HELP_MODE=full
    for active_fixture in "$TEMP_DIR/missing-active-tty" "$TEMP_DIR/malformed-active-tty"; do
        : > "$OPENVT_CALLS"
        : > "$CHVT_CALLS"
        output_suffix=${active_fixture##*/}
        launch_gpu_test "$TEMP_DIR/openvt-launcher.sh" "$TEMP_DIR/unknown-${output_suffix}.log" graphical "$active_fixture"
        wait "$stress_gpu_pid"
        [[ ! -s $OPENVT_CALLS && ! -s $CHVT_CALLS ]]
        [[ $stress_gpu_uses_openvt == 0 && -z $stress_gpu_previous_vt ]]
        grep -q '^GPU_VT=unknown direct=1$' "$TEMP_DIR/unknown-${output_suffix}.log"
        gpu_output_has_v3d_renderer "$TEMP_DIR/unknown-${output_suffix}.log"
        gpu_output_has_positive_score "$TEMP_DIR/unknown-${output_suffix}.log"
    done
)

# When openvt owns the temporary VT, terminate only its workload descendants
# first. The openvt parent must be allowed to exit and switch back naturally;
# restoring the previous VT is the final step.
VT_TERMINATE_LOG="$TEMP_DIR/vt-terminate.log"
(
    : > "$VT_TERMINATE_LOG"
    stress_gpu_uses_openvt=1
    stress_gpu_previous_vt=1
    process_tree_pids() {
        [[ $1 == 100 ]]
        printf '102\n101\n100\n'
    }
    terminate_child() {
        printf 'unexpected-generic-terminate:%s\n' "$1" >> "$VT_TERMINATE_LOG"
        return 1
    }
    kill() { printf 'kill:%s\n' "$*" >> "$VT_TERMINATE_LOG"; }
    process_is_running() { return 1; }
    wait() { printf 'wait:%s\n' "$1" >> "$VT_TERMINATE_LOG"; }
    activate_stress_previous_vt() {
        printf 'activate:%s\n' "$stress_gpu_previous_vt" >> "$VT_TERMINATE_LOG"
    }
    terminate_gpu_child 100
    [[ $(paste -sd, "$VT_TERMINATE_LOG") == 'kill:-TERM 102 101,wait:100,activate:1' ]]
)

for WORKER_NAME in debian batocera; do
    WORKER_FILE="$ROOT/workers/${WORKER_NAME}-worker.sh"
    WORKER="$WORKER_FILE" bash -lc '
        set -Eeuo pipefail
        export APO_WORKER_LIBRARY_ONLY=1
        source "$WORKER"
        fake_proc=$(mktemp -d)
        mkdir -p "$fake_proc"/{100,101,102,103}/task/{100,101,102,103}
        printf "101 102\n" > "$fake_proc/100/task/100/children"
        printf "103\n" > "$fake_proc/101/task/101/children"
        : > "$fake_proc/102/task/102/children"
        : > "$fake_proc/103/task/103/children"
        [[ $(process_tree_pids 100 "$fake_proc" | paste -sd, -) == 103,101,102,100 ]]
        rm -rf "$fake_proc"

        set +e
        signal_output=$(
            terminate_child() { printf "terminated=%s\n" "$1"; }
            stress_cpu_pid=201
            stress_gpu_pid=202
            stress_io_pid=203
            stress_work_dir=
            stress_io_file=
            stress_frontend_stopped=0
            stress_signal_cleanup 143
            printf "resumed\n"
        )
        signal_rc=$?
        set -e
        [[ $signal_rc -eq 143 ]]
        [[ $(grep -c "^terminated=" <<< "$signal_output") -eq 3 ]]
        [[ $signal_output != *resumed* ]]

        sleep 300 & child=$!
        start=$SECONDS
        terminate_child "$child"
        elapsed=$((SECONDS-start))
        if kill -0 "$child" 2>/dev/null; then exit 1; fi
        (( elapsed <= 12 ))
    '
done
printf 'test_workers: PASS\n'
