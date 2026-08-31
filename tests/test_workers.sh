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

# Debian graphical health always requires the automatically discovered audio
# baseline. A missing baseline is a harness defect; a captured output that
# disappears is a boot-health failure.
APO_WORKER_LIBRARY_ONLY=1 WORKER="$ROOT/workers/debian-worker.sh" bash -c '
    set -Eeuo pipefail
    source "$WORKER"
    check_required_processes() { :; }
    check_required_services() { :; }
    check_display() { :; }
    audio_identity() { return 1; }
    if application_health_ready graphical fixture-display "" "" "" ""; then exit 1; fi
    [[ $APPLICATION_READINESS_LAST_FAILURE == audio-baseline-missing ]]
    if application_health_ready graphical fixture-display "" "" "" fixture-audio; then exit 1; fi
    [[ $APPLICATION_READINESS_LAST_FAILURE == audio-unavailable ]]
'

# A Debian/Raspberry Pi OS target with no connector and no audio stack is a
# valid headless host. Its health gate must not call either graphical probe.
APO_WORKER_LIBRARY_ONLY=1 WORKER="$ROOT/workers/debian-worker.sh" bash -c '
    set -Eeuo pipefail
    source "$WORKER"
    check_required_processes() { :; }
    check_required_services() { :; }
    check_display() { echo display-probe-was-called >&2; return 1; }
    audio_identity() { echo audio-probe-was-called >&2; return 1; }
    application_health_ready headless "" "" "" "" ""
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

# The default temporary overclock boot carries a Pi 5 PWM fan override at 255;
# the explicit opt-out retains the ordinary curve. The permanent renderer never
# adopts the test-only policy. When Linux exposes the official pwm-fan hwmon
# device, the worker proves maximum PWM and a live tachometer under that policy.
for worker_name in debian batocera; do
    APO_WORKER_LIBRARY_ONLY=1 WORKER="$ROOT/workers/${worker_name}-worker.sh" FAN_TEST_ROOT="$TEMP_DIR/fan-$worker_name" bash -c '
        set -Eeuo pipefail
        source "$WORKER"
        mkdir -p "$FAN_TEST_ROOT/hwmon/hwmon0"
        printf "[all]\ndtparam=audio=on\ndtparam=fan_temp0=50000\ndtparam=fan_temp0_hyst=5000\ndtparam=fan_temp0_speed=75\ndtparam=fan_temp1=60000\ndtparam=fan_temp1_hyst=5000\ndtparam=fan_temp1_speed=128\ndtparam=fan_temp2=67500\ndtparam=fan_temp2_hyst=5000\ndtparam=fan_temp2_speed=192\ndtparam=fan_temp3=75000\ndtparam=fan_temp3_hyst=5000\ndtparam=fan_temp3_speed=255\n" > "$FAN_TEST_ROOT/config.txt"
        source_hash=$(sha256sum "$FAN_TEST_ROOT/config.txt" | awk "NR == 1 {print \$1}")
        token=$(printf "a%.0s" {1..64})
        render_tryboot_config "$FAN_TEST_ROOT/config.txt" "$FAN_TEST_ROOT/tryboot.txt" 2900 1000 v3d_freq 0 fan-fixture "$token"
        for expected_line in \
            "$CANDIDATE_FAN_COMMENT" \
            "dtparam=fan_temp0=0" \
            "dtparam=fan_temp0_speed=255" \
            "dtparam=fan_temp1_speed=255" \
            "dtparam=fan_temp2_speed=255" \
            "dtparam=fan_temp3_speed=255"; do
            grep -Fqx -- "$expected_line" "$FAN_TEST_ROOT/tryboot.txt"
        done
        render_clock_config "$FAN_TEST_ROOT/config.txt" "$FAN_TEST_ROOT/permanent.txt" 2900 1000 v3d_freq 0 fan-fixture
        ! grep -Fq -- "$CANDIDATE_FAN_COMMENT" "$FAN_TEST_ROOT/permanent.txt"
        ! grep -Fq "dtparam=fan_temp0=0" "$FAN_TEST_ROOT/permanent.txt"
        for preserved_line in \
            "dtparam=fan_temp0=50000" "dtparam=fan_temp0_speed=75" \
            "dtparam=fan_temp1_speed=128" "dtparam=fan_temp2_speed=192" \
            "dtparam=fan_temp3_speed=255"; do
            [[ $(grep -Fxc -- "$preserved_line" "$FAN_TEST_ROOT/permanent.txt") == 1 ]]
            grep -Fqx -- "$preserved_line" "$FAN_TEST_ROOT/tryboot.txt"
        done
        [[ $(grep -Fxc "dtparam=fan_temp3_speed=255" "$FAN_TEST_ROOT/tryboot.txt") == 2 ]]
        [[ $(sha256sum "$FAN_TEST_ROOT/config.txt" | awk "NR == 1 {print \$1}") == "$source_hash" ]]

        render_tryboot_config "$FAN_TEST_ROOT/config.txt" "$FAN_TEST_ROOT/tryboot-normal-fan.txt" 2900 1000 v3d_freq 0 fan-opt-out "$token" normal
        ! grep -Fq -- "$CANDIDATE_FAN_COMMENT" "$FAN_TEST_ROOT/tryboot-normal-fan.txt"
        ! grep -Fq "dtparam=fan_temp0=0" "$FAN_TEST_ROOT/tryboot-normal-fan.txt"
        [[ $(grep -Fxc "dtparam=fan_temp0_speed=75" "$FAN_TEST_ROOT/tryboot-normal-fan.txt") == 1 ]]
        if render_tryboot_config "$FAN_TEST_ROOT/config.txt" "$FAN_TEST_ROOT/invalid.txt" 2900 1000 v3d_freq 0 fan-invalid "$token" invalid; then exit 1; fi

        printf "pwmfan\n" > "$FAN_TEST_ROOT/hwmon/hwmon0/name"
        printf "255\n" > "$FAN_TEST_ROOT/hwmon/hwmon0/pwm1"
        printf "4100\n" > "$FAN_TEST_ROOT/hwmon/hwmon0/fan1_input"
        candidate_fan_max_ready "$FAN_TEST_ROOT/hwmon"
        [[ $FAN_PWM_LAST_COUNT == 1 && $FAN_PWM_LAST_STATUS == *pwm=255:rpm=4100* ]]

        printf "128\n" > "$FAN_TEST_ROOT/hwmon/hwmon0/pwm1"
        if candidate_fan_max_ready "$FAN_TEST_ROOT/hwmon"; then exit 1; fi
        [[ $FAN_PWM_LAST_REASON == *"not at the required maximum"* ]]

        fan_retry_count=0
        sleep() {
            fan_retry_count=$((fan_retry_count + 1))
            printf "255\n" > "$FAN_TEST_ROOT/hwmon/hwmon0/pwm1"
            printf "4100\n" > "$FAN_TEST_ROOT/hwmon/hwmon0/fan1_input"
            SECONDS=$((SECONDS + 1))
        }
        candidate_fan_max_wait 2 "$FAN_TEST_ROOT/hwmon"
        [[ $fan_retry_count == 1 && $FAN_PWM_LAST_STATUS == *pwm=255:rpm=4100* ]]

        printf "255\n" > "$FAN_TEST_ROOT/hwmon/hwmon0/pwm1"
        printf "0\n" > "$FAN_TEST_ROOT/hwmon/hwmon0/fan1_input"
        if candidate_fan_max_ready "$FAN_TEST_ROOT/hwmon"; then exit 1; fi
        [[ $FAN_PWM_LAST_REASON == *"zero RPM"* ]]

        rm -rf "$FAN_TEST_ROOT/hwmon/hwmon0"
        candidate_fan_max_ready "$FAN_TEST_ROOT/hwmon"
        [[ $FAN_PWM_LAST_COUNT == 0 && $FAN_PWM_LAST_STATUS == not-detected ]]
    '
done

# Configuration-free auto mode may accept 800/960 MHz V3D only when the
# permanent config proves that those values came from firmware defaults. Both
# workers must report every explicit clock/voltage directive in the protected
# root config instead of inferring provenance from the active numeric value
# alone. Includes fail closed until every included file is bound to the
# permanent-config integrity checks.
mkdir -p "$TEMP_DIR/tuning-audit/nested"
for worker_name in debian batocera; do
    APO_WORKER_LIBRARY_ONLY=1 WORKER="$ROOT/workers/${worker_name}-worker.sh" AUDIT_DIR="$TEMP_DIR/tuning-audit" bash -c '
        set -Eeuo pipefail
        source "$WORKER"
        cat > "$AUDIT_DIR/config.txt" <<"CONF"
# arm_freq=3100
[all]
dtparam=audio=on
CONF
        audit_permanent_tuning_config "$AUDIT_DIR/config.txt"
        [[ $PERMANENT_TUNING_PROVENANCE == verified-default ]]
        [[ $PERMANENT_TUNING_EVIDENCE == none ]]
        [[ $PERMANENT_TUNING_CONFIG_HASH == "$(sha256sum "$AUDIT_DIR/config.txt" | awk "NR == 1 {print \$1}")" ]]

        for tuning_key in \
            arm_boost force_turbo initial_turbo core_freq_fixed \
            arm_freq cpu_freq gpu_freq core_freq h264_freq isp_freq v3d_freq hevc_freq sdram_freq \
            arm_freq_min cpu_freq_min gpu_freq_min core_freq_min h264_freq_min isp_freq_min v3d_freq_min hevc_freq_min sdram_freq_min \
            over_voltage over_voltage_min over_voltage_delta over_voltage_sdram over_voltage_sdram_c over_voltage_sdram_i over_voltage_sdram_p \
            future_domain_freq future_domain_freq_min over_voltage_future; do
            printf "[all]\n%s=0\n" "$tuning_key" > "$AUDIT_DIR/config.txt"
            audit_permanent_tuning_config "$AUDIT_DIR/config.txt"
            [[ $PERMANENT_TUNING_PROVENANCE == explicit-override ]]
            [[ $PERMANENT_TUNING_EVIDENCE == "$tuning_key" ]]
        done

        printf "[all]\nARM_FREQ=2400\n" > "$AUDIT_DIR/config.txt"
        audit_permanent_tuning_config "$AUDIT_DIR/config.txt"
        [[ $PERMANENT_TUNING_PROVENANCE == explicit-override ]]
        [[ $PERMANENT_TUNING_EVIDENCE == arm_freq ]]

        printf "[all]\ngpu_freq=950\n" > "$AUDIT_DIR/nested/extra.txt"
        printf "include nested/extra.txt\n" > "$AUDIT_DIR/config.txt"
        audit_permanent_tuning_config "$AUDIT_DIR/config.txt"
        [[ $PERMANENT_TUNING_PROVENANCE == ambiguous ]]
        [[ $PERMANENT_TUNING_EVIDENCE == include-not-bound-to-permanent-hash ]]

        printf "include missing.txt\n" > "$AUDIT_DIR/config.txt"
        audit_permanent_tuning_config "$AUDIT_DIR/config.txt"
        [[ $PERMANENT_TUNING_PROVENANCE == ambiguous ]]
        [[ $PERMANENT_TUNING_EVIDENCE == include-not-bound-to-permanent-hash ]]

        # The provenance result and protected hash must describe one stable
        # root-config snapshot. Deterministic hash changes avoid a racy test.
        printf "[all]\ndtparam=audio=on\n" > "$AUDIT_DIR/config.txt"
        printf "0\n" > "$AUDIT_DIR/hash-call-count"
        permanent_config_snapshot_hash() {
            local call_count
            call_count=$(cat "$AUDIT_DIR/hash-call-count")
            call_count=$((call_count + 1))
            printf "%s\n" "$call_count" > "$AUDIT_DIR/hash-call-count"
            if (( call_count == 1 )); then
                printf "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            else
                printf "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
            fi
        }
        audit_permanent_tuning_config "$AUDIT_DIR/config.txt"
        [[ $PERMANENT_TUNING_PROVENANCE == ambiguous ]]
        [[ $PERMANENT_TUNING_EVIDENCE == permanent-config-changed-during-audit ]]
        [[ -z $PERMANENT_TUNING_CONFIG_HASH ]]
    '
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
unset APO_WORKER_LIBRARY_ONLY

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
[[ -z ${MOCK_STRESS_NG_SECOND_OPTION:-} ]] || printf '      %s PATH  select a GPU device\n' "$MOCK_STRESS_NG_SECOND_OPTION"
for ((line = 0; line < 20000; line++)); do
    printf '      --fixture-option-%05d N  trailing help text for pipe coverage\n' "$line"
done
STRESS_NG
chmod 700 "$TEMP_DIR/stress-ng-bin/stress-ng"
ORIGINAL_PATH=$PATH
PATH="$TEMP_DIR/stress-ng-bin:$PATH"
export MOCK_STRESS_NG_OPTION=--gpu
stress_ng_has_gpu
export MOCK_STRESS_NG_SECOND_OPTION=--gpu-devnode
stress_ng_has_gpu_devnode
export MOCK_STRESS_NG_SECOND_OPTION=--gpu-devnode-ops
if stress_ng_has_gpu_devnode; then
    echo 'stress-ng GPU-device detection accepted --gpu-devnode-ops as --gpu-devnode' >&2
    exit 1
fi
export MOCK_STRESS_NG_OPTION=--gpu-ops
if stress_ng_has_gpu; then
    echo 'stress-ng GPU detection accepted --gpu-ops as the --gpu stressor' >&2
    exit 1
fi
unset MOCK_STRESS_NG_OPTION MOCK_STRESS_NG_SECOND_OPTION
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

# Render-node numbering is not stable across kernels or attached GPUs. Headless
# Debian must identify the V3D node from sysfs instead of assuming renderD128.
mkdir -p "$TEMP_DIR/debian-dri" \
    "$TEMP_DIR/debian-drm-class/renderD128/device" \
    "$TEMP_DIR/debian-drm-class/renderD129/device"
: > "$TEMP_DIR/debian-dri/renderD128"
: > "$TEMP_DIR/debian-dri/renderD129"
printf 'DRIVER=virtio_gpu\n' > "$TEMP_DIR/debian-drm-class/renderD128/device/uevent"
printf 'DRIVER=v3d\n' > "$TEMP_DIR/debian-drm-class/renderD129/device/uevent"
[[ $(v3d_render_node "$TEMP_DIR/debian-dri" "$TEMP_DIR/debian-drm-class") == "$TEMP_DIR/debian-dri/renderD129" ]]
PATH="$TEMP_DIR/stress-ng-bin:$PATH"
export MOCK_STRESS_NG_OPTION=--gpu MOCK_STRESS_NG_SECOND_OPTION=--gpu-devnode
[[ $(stress_ng_gpu_strategy "$TEMP_DIR/debian-dri/renderD129" "$TEMP_DIR/debian-dri") == explicit-v3d-device ]]
unset MOCK_STRESS_NG_SECOND_OPTION
if stress_ng_gpu_strategy "$TEMP_DIR/debian-dri/renderD129" "$TEMP_DIR/debian-dri" >/dev/null; then
    echo 'stress-ng without device selection accepted an ambiguous multi-render-node host' >&2
    exit 1
fi
rm -f "$TEMP_DIR/debian-dri/renderD128"
[[ $(stress_ng_gpu_strategy "$TEMP_DIR/debian-dri/renderD129" "$TEMP_DIR/debian-dri") == single-v3d-default ]]
unset MOCK_STRESS_NG_OPTION
PATH=$ORIGINAL_PATH
rm -f "$TEMP_DIR/debian-drm-class/renderD129/device/uevent"
if v3d_render_node "$TEMP_DIR/debian-dri" "$TEMP_DIR/debian-drm-class" >/dev/null; then
    echo 'Debian V3D render-node discovery accepted a non-V3D node' >&2
    exit 1
fi

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

# A graphical Debian target without a running desktop audio server falls back
# to the complete stable ALSA playback inventory instead of skipping audio or
# guessing one device.
DEBIAN_ASOUND="$TEMP_DIR/debian-asound"
mkdir -p "$DEBIAN_ASOUND/card0/pcm0p" "$DEBIAN_ASOUND/card2/pcm1p"
printf 'vc4hdmi0\n' > "$DEBIAN_ASOUND/card0/id"
cat > "$DEBIAN_ASOUND/card0/pcm0p/info" <<'ALSA_INFO'
card: 0
device: 0
id: MAI PCM i2s-hifi-0
name: vc4-hdmi-0
ALSA_INFO
printf 'USBAudio\n' > "$DEBIAN_ASOUND/card2/id"
cat > "$DEBIAN_ASOUND/card2/pcm1p/info" <<'ALSA_INFO'
card: 2
device: 1
id: USB Audio
name: USB Playback
ALSA_INFO
(
    audio_inspect() { return 1; }
    expected_audio='alsa:card=USBAudio;device=pcm1p;id=USB Audio;name=USB Playback|alsa:card=vc4hdmi0;device=pcm0p;id=MAI PCM i2s-hifi-0;name=vc4-hdmi-0'
    [[ $(audio_identity "$DEBIAN_ASOUND") == "$expected_audio" ]]
)

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

assert_worker_kernel_failure() {
    local worker=$1 fixture=$2 output rc
    set +e
    output=$("$worker" classify-kernel-log "$fixture" 2>&1)
    rc=$?
    set -e
    [[ $rc -ne 0 && $output == *'APO_RESULT_CLASS=STABILITY_FAILURE'* ]]
}

KERNEL_SIGNATURE_FIXTURE="$TEMP_DIR/kernel-fatal-single.log"
while IFS= read -r kernel_signature; do
    printf '%s\n' "$kernel_signature" > "$KERNEL_SIGNATURE_FIXTURE"
    assert_worker_kernel_failure "$ROOT/workers/debian-worker.sh" "$KERNEL_SIGNATURE_FIXTURE"
    assert_worker_kernel_failure "$ROOT/workers/batocera-worker.sh" "$KERNEL_SIGNATURE_FIXTURE"
done < "$FIXTURES/kernel-fatal-signatures.log"

printf '%s\n' 'kernel: rcu: Hierarchical RCU implementation.' > "$TEMP_DIR/kernel-benign-rcu.log"
for worker in "$ROOT/workers/debian-worker.sh" "$ROOT/workers/batocera-worker.sh"; do
    KERNEL_BENIGN_OUTPUT=$("$worker" classify-kernel-log "$TEMP_DIR/kernel-benign-rcu.log" 2>&1)
    [[ $KERNEL_BENIGN_OUTPUT == *'APO_RESULT_CLASS=PASS'* ]]
done

APO_WORKER_LIBRARY_ONLY=1 source "$ROOT/workers/batocera-worker.sh"
unset APO_WORKER_LIBRARY_ONLY
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
    # shellcheck disable=SC2032
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
printf 'Wayland connection failed: compositor unavailable\n' > "$TEMP_DIR/wayland-failure.log"
gpu_output_has_v3d_renderer "$TEMP_DIR/v3d-pass.log"
gpu_output_has_positive_score "$TEMP_DIR/v3d-pass.log"
if gpu_output_has_v3d_renderer "$TEMP_DIR/software-renderer.log"; then exit 1; fi
gpu_output_has_harness_error "$TEMP_DIR/egl-failure.log"
gpu_output_has_harness_error "$TEMP_DIR/wayland-failure.log"
[[ $(gpu_early_exit_class 0 "$TEMP_DIR/v3d-pass.log") == HARNESS_FAILURE ]]
[[ $(gpu_early_exit_class 1 "$TEMP_DIR/v3d-pass.log") == STABILITY_FAILURE ]]
[[ $(gpu_early_exit_class 1 "$TEMP_DIR/egl-failure.log") == HARNESS_FAILURE ]]
SWAY_OUTPUTS='[{"name":"HDMI-A-1","active":false},{"name":"HDMI-A-2","active":true}]'
[[ $(sway_first_active_connector "$SWAY_OUTPUTS") == HDMI-A-2 ]]
sway_connector_is_active "$SWAY_OUTPUTS" HDMI-A-2
if sway_connector_is_active "$SWAY_OUTPUTS" HDMI-A-1; then exit 1; fi
if sway_connector_is_active 'not-json' HDMI-A-2; then exit 1; fi

# Graphical GPU stress must bind to the live EmulationStation Wayland socket.
# Prefer the frontend process environment, use one unambiguous socket directly
# below /run as a fallback, and reject missing, unsafe, or ambiguous evidence.
WAYLAND_PROC="$TEMP_DIR/wayland-proc"
WAYLAND_RUN="$TEMP_DIR/wayland-run"
mkdir -p "$WAYLAND_PROC/4242" "$WAYLAND_RUN"
printf 'XDG_RUNTIME_DIR=%s\0WAYLAND_DISPLAY=wayland-3\0' "$WAYLAND_RUN" > "$WAYLAND_PROC/4242/environ"
(
    pidof() { [[ $1 == emulationstation ]] && printf '4242\n'; }
    wayland_socket_ready() { [[ $1 == "$WAYLAND_RUN/wayland-3" ]]; }
    [[ $(discover_wayland_session "$WAYLAND_PROC" "$WAYLAND_RUN") == "$WAYLAND_RUN"$'\t''wayland-3' ]]
)
printf 'XDG_RUNTIME_DIR=%s\0' "$WAYLAND_RUN" > "$WAYLAND_PROC/4242/environ"
: > "$WAYLAND_RUN/wayland-4"
(
    pidof() { [[ $1 == emulationstation ]] && printf '4242\n'; }
    wayland_socket_ready() { [[ $1 == "$WAYLAND_RUN/wayland-4" ]]; }
    [[ $(discover_wayland_session "$WAYLAND_PROC" "$WAYLAND_RUN") == "$WAYLAND_RUN"$'\t''wayland-4' ]]
)
: > "$WAYLAND_RUN/wayland-5"
(
    pidof() { [[ $1 == emulationstation ]] && printf '4242\n'; }
    wayland_socket_ready() { return 0; }
    if discover_wayland_session "$WAYLAND_PROC" "$WAYLAND_RUN" >/dev/null; then
        echo 'Batocera Wayland discovery accepted ambiguous fallback sockets' >&2
        exit 1
    fi
)
printf 'XDG_RUNTIME_DIR=/tmp\0WAYLAND_DISPLAY=wayland-9\0' > "$WAYLAND_PROC/4242/environ"
rm -f "$WAYLAND_RUN"/wayland-*
(
    pidof() { [[ $1 == emulationstation ]] && printf '4242\n'; }
    wayland_socket_ready() { return 0; }
    if discover_wayland_session "$WAYLAND_PROC" "$WAYLAND_RUN" >/dev/null; then
        echo 'Batocera Wayland discovery accepted an unsafe runtime directory' >&2
        exit 1
    fi
)
(
    pidof() { return 1; }
    wayland_socket_ready() { return 0; }
    if discover_wayland_session "$WAYLAND_PROC" "$WAYLAND_RUN" >/dev/null; then
        echo 'Batocera Wayland discovery accepted a socket without EmulationStation' >&2
        exit 1
    fi
)

GLMARK_FIXTURE_ROOT="$TEMP_DIR/glmark-fixture"
mkdir -p "$GLMARK_FIXTURE_ROOT/glmark2/usr/bin"
: > "$GLMARK_FIXTURE_ROOT/glmark2/usr/bin/glmark2-es2-wayland"
: > "$GLMARK_FIXTURE_ROOT/glmark2/usr/bin/glmark2-es2-drm"
chmod 755 "$GLMARK_FIXTURE_ROOT/glmark2/usr/bin/glmark2-es2-wayland" "$GLMARK_FIXTURE_ROOT/glmark2/usr/bin/glmark2-es2-drm"
(
    PERSISTENT_ROOT=$GLMARK_FIXTURE_ROOT
    [[ $(find_glmark_binary graphical) == "$GLMARK_FIXTURE_ROOT/glmark2/usr/bin/glmark2-es2-wayland" ]]
    [[ $(find_glmark_binary headless) == "$GLMARK_FIXTURE_ROOT/glmark2/usr/bin/glmark2-es2-drm" ]]
    if find_glmark_binary invalid >/dev/null; then exit 1; fi
)
(
    APO_ROOT=$ROOT
    APO_RUN_ID='fixture-run'
    source "$ROOT/lib/common.sh"
    source "$ROOT/profiles/batocera.sh"
    # shellcheck disable=SC2030
    declare -Ag APO_DISCOVERY=(
        [CPU_STRESS_AVAILABLE]=1 [GLMARK_DATA]=/fixture/data
        [GLMARK_WAYLAND_BINARY]=/fixture/glmark2-es2-wayland [GLMARK_DRM_BINARY]=''
    )
    # shellcheck disable=SC2030
    APO_REQUIRE_GPU_STRESS=1
    # shellcheck disable=SC2030
    APO_MODE_EFFECTIVE=graphical
    apo_profile_dependencies_ready
    APO_MODE_EFFECTIVE=headless
    if apo_profile_dependencies_ready; then
        echo 'Batocera headless dependency preflight accepted only a Wayland backend' >&2
        exit 1
    fi
    APO_DISCOVERY[GLMARK_WAYLAND_BINARY]=''
    APO_DISCOVERY[GLMARK_DRM_BINARY]=/fixture/glmark2-es2-drm
    apo_profile_dependencies_ready
    APO_MODE_EFFECTIVE=graphical
    if apo_profile_dependencies_ready; then
        echo 'Batocera graphical dependency preflight accepted only a DRM backend' >&2
        exit 1
    fi
)

# The controller-side cache gate verifies the complete archive before reuse,
# and the generated target installer must preserve the prior live payload if a
# post-activation manifest check fails.
(
    APO_ROOT=$ROOT
    APO_RUN_ID='fixture-run'
    source "$ROOT/lib/common.sh"
    source "$ROOT/profiles/batocera.sh"
    BUNDLE_TEST_ROOT="$TEMP_DIR/bundle-install"
    INSTALL_ROOT="$BUNDLE_TEST_ROOT/target root"
    NEW_SOURCE="$BUNDLE_TEST_ROOT/new-source"
    NEW_ARCHIVE="$BUNDLE_TEST_ROOT/new-bundle.tar.gz"
    INSTALL_SCRIPT="$BUNDLE_TEST_ROOT/install.sh"
    mkdir -p "$BUNDLE_TEST_ROOT"
    make_bundle_fixture() {
        local destination=$1 marker=$2 include_wayland=$3
        mkdir -p "$destination/usr/bin" "$destination/usr/share/glmark2"
        printf '#!/bin/sh\nexit 0\n' > "$destination/usr/bin/glmark2-es2-drm"
        chmod 755 "$destination/usr/bin/glmark2-es2-drm"
        if (( include_wayland == 1 )); then
            printf '#!/bin/sh\nexit 0\n' > "$destination/usr/bin/glmark2-es2-wayland"
            chmod 755 "$destination/usr/bin/glmark2-es2-wayland"
        fi
        printf '%s\n' "$marker" > "$destination/MARKER"
        printf 'fixture-data\n' > "$destination/usr/share/glmark2/fixture.dat"
        (
            cd "$destination"
            # shellcheck disable=SC2033
            find . -type f ! -name MANIFEST.sha256 -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > MANIFEST.sha256
        )
    }
    make_bundle_fixture "$NEW_SOURCE" NEW 1
    tar -C "$NEW_SOURCE" -czf "$NEW_ARCHIVE" .
    sha256sum "$NEW_ARCHIVE" > "${NEW_ARCHIVE}.sha256"
    apo_profile_batocera_bundle_ready "$NEW_ARCHIVE"
    cp "$NEW_ARCHIVE" "$BUNDLE_TEST_ROOT/corrupt.tar.gz"
    cp "${NEW_ARCHIVE}.sha256" "$BUNDLE_TEST_ROOT/corrupt.tar.gz.sha256"
    printf 'corruption\n' >> "$BUNDLE_TEST_ROOT/corrupt.tar.gz"
    if apo_profile_batocera_bundle_ready "$BUNDLE_TEST_ROOT/corrupt.tar.gz"; then
        echo 'Batocera bundle cache accepted a corrupt archive' >&2
        exit 1
    fi

    make_bundle_fixture "$INSTALL_ROOT/glmark2" OLD 0
    apo_profile_batocera_bundle_install_command "$NEW_ARCHIVE" "$INSTALL_ROOT" > "$INSTALL_SCRIPT"
    bash -n "$INSTALL_SCRIPT"
    bash "$INSTALL_SCRIPT"
    [[ $(<"$INSTALL_ROOT/glmark2/MARKER") == NEW ]]
    [[ -x $INSTALL_ROOT/glmark2/usr/bin/glmark2-es2-wayland ]]
    [[ ! -e $INSTALL_ROOT/glmark2.new && ! -e $INSTALL_ROOT/glmark2.old ]]
    (cd "$INSTALL_ROOT/glmark2" && sha256sum -c MANIFEST.sha256 >/dev/null)

    rm -rf "$INSTALL_ROOT"
    make_bundle_fixture "$INSTALL_ROOT/glmark2" OLD 0
    mkdir -p "$BUNDLE_TEST_ROOT/fake-bin"
    APO_TEST_REAL_SHA256SUM=$(command -v sha256sum)
    APO_TEST_SHA_CALLS="$BUNDLE_TEST_ROOT/sha-calls"
    export APO_TEST_REAL_SHA256SUM APO_TEST_SHA_CALLS
    cat > "$BUNDLE_TEST_ROOT/fake-bin/sha256sum" <<'APO_FAKE_SHA256SUM'
#!/usr/bin/env bash
if [[ ${1:-} == -c ]]; then
    call_count=0
    [[ ! -f $APO_TEST_SHA_CALLS ]] || read -r call_count < "$APO_TEST_SHA_CALLS"
    call_count=$((call_count + 1))
    printf '%s\n' "$call_count" > "$APO_TEST_SHA_CALLS"
    (( call_count != 2 )) || exit 93
fi
exec "$APO_TEST_REAL_SHA256SUM" "$@"
APO_FAKE_SHA256SUM
    chmod 755 "$BUNDLE_TEST_ROOT/fake-bin/sha256sum"
    set +e
    PATH="$BUNDLE_TEST_ROOT/fake-bin:$PATH" bash "$INSTALL_SCRIPT" >/dev/null 2>&1
    INSTALL_RC=$?
    set -e
    [[ $INSTALL_RC -ne 0 ]]
    [[ $(<"$INSTALL_ROOT/glmark2/MARKER") == OLD ]]
    [[ ! -e $INSTALL_ROOT/glmark2.new && ! -e $INSTALL_ROOT/glmark2.old ]]
    (cd "$INSTALL_ROOT/glmark2" && sha256sum -c MANIFEST.sha256 >/dev/null)
)

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
    APO_AUDIO_BASELINE='fixture-audio'
    APO_THROTTLE_RUNTIME_BASELINE=throttled=0x0
    APO_NORMAL_CPU=2400
    APO_NORMAL_GPU=800
    CAPTURED_WORKER_ARGS=()
    apo_state_get() {
        case $1 in
            CURRENT_CPU) printf 3000 ;;
            CURRENT_GPU) printf 900 ;;
            TRYBOOT_EXPECTED) printf 1 ;;
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
    [[ ${CAPTURED_WORKER_ARGS[13]} == candidate-max ]]
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

# OpenSSL speed applies -seconds independently to every default buffer size.
# Batocera must select one 16 KiB block and elapsed-time accounting so a 600s
# CPU/combined request actually ends after roughly 600 wall-clock seconds.
BATOCERA_OPENSSL_ARGS="$TEMP_DIR/batocera-openssl-args"
APO_WORKER_LIBRARY_ONLY=1 WORKER="$ROOT/workers/batocera-worker.sh" OPENSSL_ARGS="$BATOCERA_OPENSSL_ARGS" bash -c '
    set -u -o pipefail
    source "$WORKER"
    current_temp() { printf 50; }
    current_throttle() { printf "throttled=0x0"; }
    clock_mhz() { case $1 in arm) printf 2400 ;; *) printf 800 ;; esac; }
    kernel_log() { :; }
    kernel_error_lines() { :; }
    nproc() { printf 4; }
    openssl() {
        printf "%s\n" "$@" > "$OPENSSL_ARGS"
        command /bin/sleep 0.5
        printf "openssl single-block output\n"
    }
    sleep() { command /bin/sleep 0.7; SECONDS=$((SECONDS + 600)); }
    cmd_stress cpu 600 75 headless "" 0 2400 800 throttled=0x0 60
' >/dev/null
mapfile -t BATOCERA_OPENSSL_ARGV < "$BATOCERA_OPENSSL_ARGS"
[[ ${BATOCERA_OPENSSL_ARGV[*]} == 'speed -elapsed -seconds 600 -bytes 16384 -multi 4 sha256' ]]

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
FINAL_SAMPLE_OUTPUT=$(APO_WORKER_LIBRARY_ONLY=1 WORKER="$ROOT/workers/debian-worker.sh" SAMPLE_FILE="$FINAL_SAMPLE_FILE" bash -c '
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
' 2>&1)
[[ $(wc -l < "$FINAL_SAMPLE_FILE") -eq 2 ]]
[[ $FINAL_SAMPLE_OUTPUT == *'elapsed=20/20s'* ]]
for elapsed_worker in "$ROOT/workers/debian-worker.sh" "$ROOT/workers/batocera-worker.sh"; do
    grep -Fq 'elapsed=%s/%ss' "$elapsed_worker"
done

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
GPU_BACKEND_BIN="$TEMP_DIR/gpu-backend-bin"
mkdir -p "$GPU_BACKEND_BIN"
for GPU_BACKEND in glmark2-es2-wayland glmark2-es2-drm; do
    sed "s/@BACKEND@/$GPU_BACKEND/" > "$GPU_BACKEND_BIN/$GPU_BACKEND" <<'GLMARK_FIXTURE'
#!/usr/bin/env bash
printf 'BACKEND=@BACKEND@\n'
printf 'RUNTIME=%s\n' "${XDG_RUNTIME_DIR:-}"
printf 'DISPLAY=%s\n' "${WAYLAND_DISPLAY:-}"
printf 'ARGS=%s\n' "$*"
printf '    GL_RENDERER: V3D 7.1\n'
printf 'glmark2 Score: 42\n'
GLMARK_FIXTURE
    chmod 755 "$GPU_BACKEND_BIN/$GPU_BACKEND"
done

write_glmark_launcher "$TEMP_DIR/graphical.sh" 20 "$GPU_BACKEND_BIN/glmark2-es2-wayland" /opt/data /opt/lib graphical "$WAYLAND_RUN" wayland-3
write_glmark_launcher "$TEMP_DIR/headless.sh" 20 "$GPU_BACKEND_BIN/glmark2-es2-drm" /opt/data /opt/lib headless
bash -n "$TEMP_DIR/graphical.sh"
bash -n "$TEMP_DIR/headless.sh"
grep -q '^export XDG_RUNTIME_DIR=' "$TEMP_DIR/graphical.sh"
grep -q '^export WAYLAND_DISPLAY=' "$TEMP_DIR/graphical.sh"
grep -q -- '--off-screen' "$TEMP_DIR/graphical.sh"
grep -q -- '--size=1280x720' "$TEMP_DIR/graphical.sh"
grep -q -- '--off-screen' "$TEMP_DIR/headless.sh"
grep -q -- '--size=640x480' "$TEMP_DIR/headless.sh"
if grep -Eq 'openvt|chvt|S31emulationstation|glmark2-es2-drm' "$TEMP_DIR/graphical.sh"; then exit 1; fi
GRAPHICAL_LAUNCH_OUTPUT=$(bash "$TEMP_DIR/graphical.sh" 2>&1)
[[ $GRAPHICAL_LAUNCH_OUTPUT == *$'GPU_WAYLAND_SOCKET='"$WAYLAND_RUN/wayland-3"$'\n'* ]]
[[ $GRAPHICAL_LAUNCH_OUTPUT == *$'GPU_STRATEGY=graphical-wayland-off-screen\n'* ]]
[[ $GRAPHICAL_LAUNCH_OUTPUT == *$'BACKEND=glmark2-es2-wayland\n'* ]]
[[ $GRAPHICAL_LAUNCH_OUTPUT == *$'RUNTIME='"$WAYLAND_RUN"$'\n'* ]]
[[ $GRAPHICAL_LAUNCH_OUTPUT == *$'DISPLAY=wayland-3\n'* ]]
[[ $GRAPHICAL_LAUNCH_OUTPUT == *'ARGS=--data-path /opt/data --off-screen --size=1280x720 --benchmark shading:duration=20:shading=phong'* ]]
HEADLESS_LAUNCH_OUTPUT=$(WAYLAND_DISPLAY=unsafe bash "$TEMP_DIR/headless.sh" 2>&1)
[[ $HEADLESS_LAUNCH_OUTPUT == *$'GPU_STRATEGY=headless-drm-off-screen\n'* ]]
[[ $HEADLESS_LAUNCH_OUTPUT == *$'BACKEND=glmark2-es2-drm\n'* ]]
[[ $HEADLESS_LAUNCH_OUTPUT == *$'DISPLAY=\n'* ]]
[[ $HEADLESS_LAUNCH_OUTPUT == *'ARGS=--data-path /opt/data --off-screen --size=640x480 --benchmark shading:duration=20:shading=phong'* ]]

# The graphical launcher runs directly through the compositor. These sentinels
# make any regression to frontend service control or VT ownership fail loudly.
FORBIDDEN_GPU_CALLS="$TEMP_DIR/forbidden-gpu-calls"
(
    : > "$FORBIDDEN_GPU_CALLS"
    stop_frontend() { printf 'stop_frontend\n' >> "$FORBIDDEN_GPU_CALLS"; return 99; }
    openvt() { printf 'openvt\n' >> "$FORBIDDEN_GPU_CALLS"; return 99; }
    chvt() { printf 'chvt\n' >> "$FORBIDDEN_GPU_CALLS"; return 99; }
    launch_gpu_test "$TEMP_DIR/graphical.sh" "$TEMP_DIR/graphical-gpu.log" graphical
    wait "$stress_gpu_pid"
    [[ ! -s $FORBIDDEN_GPU_CALLS ]]
    grep -q '^GPU_LAUNCH=wayland-compositor$' "$TEMP_DIR/graphical-gpu.log"
    grep -q '^GPU_WAYLAND_SOCKET=' "$TEMP_DIR/graphical-gpu.log"
    gpu_output_has_v3d_renderer "$TEMP_DIR/graphical-gpu.log"
    gpu_output_has_positive_score "$TEMP_DIR/graphical-gpu.log"

    launch_gpu_test "$TEMP_DIR/headless.sh" "$TEMP_DIR/headless-gpu.log" headless
    wait "$stress_gpu_pid"
    [[ ! -s $FORBIDDEN_GPU_CALLS ]]
    grep -q '^GPU_LAUNCH=headless-drm$' "$TEMP_DIR/headless-gpu.log"
    grep -q '^BACKEND=glmark2-es2-drm$' "$TEMP_DIR/headless-gpu.log"
    gpu_output_has_v3d_renderer "$TEMP_DIR/headless-gpu.log"
    gpu_output_has_positive_score "$TEMP_DIR/headless-gpu.log"
)

set +e
GRAPHICAL_STRESS_OUTPUT=$(
    (
        : > "$FORBIDDEN_GPU_CALLS"
        stop_frontend() { printf 'stop_frontend\n' >> "$FORBIDDEN_GPU_CALLS"; return 99; }
        openvt() { printf 'openvt\n' >> "$FORBIDDEN_GPU_CALLS"; return 99; }
        chvt() { printf 'chvt\n' >> "$FORBIDDEN_GPU_CALLS"; return 99; }
        current_temp() { printf 50; }
        current_throttle() { printf 'throttled=0x0'; }
        clock_mhz() { case $1 in arm) printf 2400 ;; *) printf 800 ;; esac; }
        kernel_log() { :; }
        kernel_error_lines() { :; }
        find_glmark_binary() { [[ $1 == graphical ]] && printf '%s' "$GPU_BACKEND_BIN/glmark2-es2-wayland"; }
        find_glmark_data() { printf /opt/data; }
        find_glmark_library_dirs() { printf /opt/lib; }
        gpu_stack_probe() { printf 'render_node=/dev/dri/renderD128;driver=v3d'; }
        discover_wayland_session() { printf '%s\t%s\n' "$WAYLAND_RUN" wayland-3; }
        cmd_stress gpu 1 75 graphical fixture-display 0 2400 800 throttled=0x0 5 fixture-audio
    ) 2>&1
)
GRAPHICAL_STRESS_RC=$?
set -e
[[ $GRAPHICAL_STRESS_RC -eq 0 ]]
[[ ! -s $FORBIDDEN_GPU_CALLS ]]
[[ $GRAPHICAL_STRESS_OUTPUT == *'APO_RESULT_CLASS=PASS'* ]]
[[ $GRAPHICAL_STRESS_OUTPUT == *'GPU_LAUNCH=wayland-compositor'* ]]
[[ $GRAPHICAL_STRESS_OUTPUT == *'BACKEND=glmark2-es2-wayland'* ]]

set +e
WAYLAND_MISSING_OUTPUT=$(
    (
        find_glmark_binary() { printf '%s' "$GPU_BACKEND_BIN/glmark2-es2-wayland"; }
        find_glmark_data() { printf /opt/data; }
        find_glmark_library_dirs() { :; }
        gpu_stack_probe() { printf 'render_node=/dev/dri/renderD128;driver=v3d'; }
        discover_wayland_session() { return 1; }
        cmd_stress gpu 20 75 graphical fixture-display 0 2400 800 throttled=0x0
    ) 2>&1
)
WAYLAND_MISSING_RC=$?
set -e
[[ $WAYLAND_MISSING_RC -ne 0 ]]
[[ $WAYLAND_MISSING_OUTPUT == *'APO_RESULT_CLASS=HARNESS_FAILURE'* ]]
WAYLAND_MISSING_REASON_B64=$(awk -F= '/^APO_RESULT_REASON_B64=/{sub(/^[^=]*=/, ""); print; exit}' <<< "$WAYLAND_MISSING_OUTPUT")
[[ $(printf '%s' "$WAYLAND_MISSING_REASON_B64" | base64 --decode) == 'The live EmulationStation Wayland socket could not be discovered safely.' ]]

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
