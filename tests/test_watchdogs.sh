#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TEMP_DIR=$(mktemp -d)
trap 'test_rc=$?; rm -rf "$TEMP_DIR"; exit "$test_rc"' EXIT

for WORKER_NAME in debian batocera; do
    WORKER_FILE="$ROOT/workers/${WORKER_NAME}-worker.sh"
    WORKER="$WORKER_FILE" TEST_ROOT="$TEMP_DIR/$WORKER_NAME" bash -c '
        set -Eeuo pipefail
        export APO_WORKER_LIBRARY_ONLY=1
        source "$WORKER"

        mkdir -p "$TEST_ROOT/proc/321/fd" "$TEST_ROOT/proc/654/fd"
        : > "$TEST_ROOT/watchdog0"
        printf "generic-watchdog\n" > "$TEST_ROOT/proc/321/comm"
        printf "unrelated\n" > "$TEST_ROOT/proc/654/comm"
        ln -s "$TEST_ROOT/watchdog0" "$TEST_ROOT/proc/321/fd/7"
        ln -s "$TEST_ROOT/unrelated" "$TEST_ROOT/proc/654/fd/8"

        owner=$(watchdog_userspace_owner "$TEST_ROOT/watchdog0" "$TEST_ROOT/proc")
        [[ $owner == "pid=321;comm=generic-watchdog;fd=7" ]]
        if watchdog_userspace_owner "$TEST_ROOT/watchdog0" "$TEST_ROOT/empty-proc" >/dev/null 2>&1; then exit 1; fi

        mkdir -p "$TEST_ROOT/sys/class/watchdog/watchdog0"
        printf "console=serial0 root=/dev/mmcblk0p2 watchdog.open_timeout=45 quiet\n" > "$TEST_ROOT/cmdline"
        printf "45\n" > "$TEST_ROOT/sys/class/watchdog/watchdog0/timeout"
        [[ $(watchdog_kernel_open_timeout "$TEST_ROOT/cmdline") == 45 ]]
        [[ $(watchdog_runtime_timeout "$TEST_ROOT/watchdog0" "$TEST_ROOT/sys") == 45 ]]
        printf "kernel_watchdog_timeout=60 quiet\n" > "$TEST_ROOT/cmdline"
        [[ -z $(watchdog_kernel_open_timeout "$TEST_ROOT/cmdline") ]]
        printf "watchdog.open_timeout=bogus\n" > "$TEST_ROOT/cmdline"
        [[ $(watchdog_kernel_open_timeout "$TEST_ROOT/cmdline") == bogus ]]

        watchdog_boot_timeout() { printf 30; }
        watchdog_kernel_open_timeout() { printf 60; }
        watchdog_device_path() { printf "%s" "$TEST_ROOT/watchdog0"; }
        watchdog_runtime_timeout() { printf 30; }
        watchdog_userspace_owner() { printf "pid=321;comm=generic-watchdog;fd=7"; }
        watchdog_health_ready /boot/config.txt
        [[ $WATCHDOG_LAST_BOOT_TIMEOUT == 30 ]]
        [[ $WATCHDOG_LAST_KERNEL_TIMEOUT == 60 ]]
        [[ $WATCHDOG_LAST_DEVICE == "$TEST_ROOT/watchdog0" ]]
        [[ $WATCHDOG_LAST_RUNTIME_TIMEOUT == 30 ]]
        [[ -n $WATCHDOG_LAST_OWNER ]]

        watchdog_boot_timeout() { printf 0; }
        if watchdog_health_ready /boot/config.txt; then exit 1; fi
        [[ $WATCHDOG_LAST_REASON == EEPROM* ]]
        watchdog_boot_timeout() { printf 30; }
        watchdog_kernel_open_timeout() { printf 0; }
        if watchdog_health_ready /boot/config.txt; then exit 1; fi
        [[ $WATCHDOG_LAST_REASON == "The active kernel command line"* ]]
        watchdog_kernel_open_timeout() { printf 60; }
        watchdog_device_path() { return 1; }
        if watchdog_health_ready /boot/config.txt; then exit 1; fi
        [[ $WATCHDOG_LAST_REASON == "No watchdog character device is present." ]]
        watchdog_device_path() { printf "%s" "$TEST_ROOT/watchdog0"; }
        watchdog_runtime_timeout() { printf 0; }
        if watchdog_health_ready /boot/config.txt; then exit 1; fi
        [[ $WATCHDOG_LAST_REASON == "The active watchdog device has no positive runtime timeout"* ]]
        watchdog_runtime_timeout() { printf 30; }
        watchdog_userspace_owner() { return 1; }
        if watchdog_health_ready /boot/config.txt; then exit 1; fi
        [[ $WATCHDOG_LAST_REASON == "No userspace process owns "* ]]
    '
done

PLAN_CONFIG="$TEMP_DIR/plan-config.txt"
printf '[all]\narm_freq=2400\n' > "$PLAN_CONFIG"
PLAN_OUTPUT=$(APO_WORKER_LIBRARY_ONLY=1 WORKER="$ROOT/workers/debian-worker.sh" PLAN_CONFIG="$PLAN_CONFIG" bash -c '
    set -Eeuo pipefail
    source "$WORKER"
    find_boot_config() { printf "%s" "$PLAN_CONFIG"; }
    cmd_plan_watchdog_repair 60
')
[[ $PLAN_OUTPUT == *'APO_RESULT_CLASS=PASS'* ]]
[[ $PLAN_OUTPUT == *$'APO_DATA\tWATCHDOG_REPAIR_OLD_HASH\t'* ]]
[[ $PLAN_OUTPUT == *$'APO_DATA\tWATCHDOG_REPAIR_EXPECTED_HASH\t'* ]]

for PROFILE_NAME in debian batocera; do
    PROFILE_PATH="$ROOT/profiles/${PROFILE_NAME}.sh"
    PROFILE="$PROFILE_PATH" REPO_ROOT="$ROOT" bash -c '
        set -Eeuo pipefail
        APO_ROOT=$REPO_ROOT
        APO_RUN_ID=fixture
        APO_NEED_GPU=0
        declare -A APO_DISCOVERY=(
            [BOOT_WATCHDOG_TIMEOUT]=30
            [KERNEL_WATCHDOG_TIMEOUT]=60
            [RUNTIME_WATCHDOG]=60s
            [WATCHDOG_DEVICE]=/dev/watchdog0
            [WATCHDOG_RUNTIME_TIMEOUT]=30
            [WATCHDOG_OWNER]="pid=1;comm=watchdog;fd=7"
        )
        apo_is_uint() { [[ ${1-} =~ ^[0-9]+$ ]]; }
        source "$PROFILE"
        apo_profile_watchdogs_ready
        APO_DISCOVERY[WATCHDOG_RUNTIME_TIMEOUT]=0
        if apo_profile_watchdogs_ready; then exit 1; fi
        APO_DISCOVERY[WATCHDOG_RUNTIME_TIMEOUT]=30
        APO_DISCOVERY[WATCHDOG_OWNER]=
        if apo_profile_watchdogs_ready; then exit 1; fi
    '
done

FAKE_BIN="$TEMP_DIR/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/wpctl" <<'FAKE_WPCTL'
#!/usr/bin/env bash
[[ ${HOME:-} == /userdata/system ]]
[[ ${DISPLAY:-} == :0.0 ]]
[[ ${XDG_RUNTIME_DIR:-} == /run ]]
[[ ${PIPEWIRE_RUNTIME_DIR:-} == /run ]]
printf 'fixture-audio-sink\n'
FAKE_WPCTL
chmod 700 "$FAKE_BIN/wpctl"

BATOCERA_OUTPUT=$(APO_WORKER_LIBRARY_ONLY=1 TEST_ROOT="$TEMP_DIR" WORKER="$ROOT/workers/batocera-worker.sh" PATH="$FAKE_BIN:$PATH" bash -c '
    set -u -o pipefail
    source "$WORKER"
    PERSISTENT_ROOT="$TEST_ROOT/persistent"
    sha256sum() { printf "fixture-hash  %s\n" "$1"; }
    active_config_value() {
        case $1 in arm_freq) printf 2400 ;; v3d_freq) printf 800 ;; over_voltage_delta) printf 0 ;; esac
    }
    watchdog_health_ready() {
        WATCHDOG_LAST_BOOT_TIMEOUT=30
        WATCHDOG_LAST_KERNEL_TIMEOUT=60
        WATCHDOG_LAST_DEVICE=/dev/watchdog0
        WATCHDOG_LAST_RUNTIME_TIMEOUT=30
        WATCHDOG_LAST_OWNER="pid=1;comm=watchdog;fd=7"
    }
    current_throttle() { printf throttled=0x0; }
    current_temp() { printf 40; }
    kernel_error_lines() { :; }
    cmd_health 2400 800 v3d_freq 0 75 headless "" "" "" fixture-audio-sink "" "" fixture-hash audio-fixture throttled=0x0
' 2>&1)
[[ $BATOCERA_OUTPUT == *'APO_RESULT_CLASS=PASS'* ]]

grep -q 'WATCHDOG_RUNTIME_TIMEOUT' "$ROOT/lib/detect.sh"
grep -q 'atomic_replace_verified.*watchdog-config-install' "$ROOT/workers/debian-worker.sh"
grep -q 'expected_old_hash=.*expected_new_hash=' "$ROOT/workers/debian-worker.sh"
grep -q 'WATCHDOG_REPAIR_STATUS PLANNED' "$ROOT/profiles/debian.sh"
EEPROM_APPLY_LINE=$(grep -n 'rpi-eeprom-config --apply.*new_eeprom' "$ROOT/workers/debian-worker.sh" | tail -1 | cut -d: -f1)
NO_ROLLBACK_LINE=$(grep -n '^[[:space:]]*committed=1$' "$ROOT/workers/debian-worker.sh" | tail -1 | cut -d: -f1)
REPAIR_PASS_LINE=$(grep -n "emit_result PASS 'Watchdog remediation was staged" "$ROOT/workers/debian-worker.sh" | tail -1 | cut -d: -f1)
[[ $NO_ROLLBACK_LINE =~ ^[0-9]+$ && $EEPROM_APPLY_LINE =~ ^[0-9]+$ && $REPAIR_PASS_LINE =~ ^[0-9]+$ ]]
[[ $NO_ROLLBACK_LINE -lt $EEPROM_APPLY_LINE && $EEPROM_APPLY_LINE -lt $REPAIR_PASS_LINE ]]
grep -q 'failed after the no-rollback boundary' "$ROOT/workers/debian-worker.sh"

printf 'test_watchdogs: PASS\n'
