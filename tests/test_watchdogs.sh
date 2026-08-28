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
        printf "0:0\n" > "$TEST_ROOT/sys/class/watchdog/watchdog0/dev"
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

APO_WORKER_LIBRARY_ONLY=1 TEST_ROOT="$TEMP_DIR" WORKER="$ROOT/workers/batocera-worker.sh" bash -c '
    set -Eeuo pipefail
    source "$WORKER"

    must_fail() {
        if "$@" >/dev/null 2>&1; then
            printf "unexpected success: %s\n" "$1" >&2
            return 1
        fi
    }

    DEVICE="$TEST_ROOT/watchdog0"
    SYS_ROOT="$TEST_ROOT/pidfd-sys"
    OWNER="pid=321;comm=generic-watchdog;fd=7"
    CALL_LOG="$TEST_ROOT/pidfd-calls"
    mkdir -p "$SYS_ROOT/class/watchdog/watchdog0"
    : > "$DEVICE"
    : > "$CALL_LOG"
    printf "0:0\n" > "$SYS_ROOT/class/watchdog/watchdog0/dev"

    EXPECTED_FIELDS=$(printf "321\t7\tgeneric-watchdog")
    [[ $(watchdog_owner_pid_fd "$OWNER") == "$EXPECTED_FIELDS" ]]

    watchdog_runtime_timeout_pidfd() {
        printf "unexpected\n" >> "$CALL_LOG"
        return 1
    }
    watchdog_userspace_owner() { printf "%s" "$OWNER"; }
    printf "45\n" > "$SYS_ROOT/class/watchdog/watchdog0/timeout"
    [[ $(watchdog_runtime_timeout_effective "$DEVICE" "$OWNER" "$SYS_ROOT") == 45 ]]
    [[ ! -s $CALL_LOG ]]

    rm -f "$SYS_ROOT/class/watchdog/watchdog0/timeout"
    watchdog_runtime_timeout_pidfd() {
        if [[ $1 == "$DEVICE" && $2 == 321 && $3 == 7 && $4 == generic-watchdog ]]; then
            printf "called\n" >> "$CALL_LOG"
            printf 15
        else
            return 1
        fi
    }
    [[ $(watchdog_runtime_timeout_effective "$DEVICE" "$OWNER" "$SYS_ROOT") == 15 ]]
    [[ $(wc -l < "$CALL_LOG") == 1 ]]

    : > "$CALL_LOG"
    printf "0\n" > "$SYS_ROOT/class/watchdog/watchdog0/timeout"
    must_fail watchdog_runtime_timeout_effective "$DEVICE" "$OWNER" "$SYS_ROOT"
    [[ ! -s $CALL_LOG ]]
    for malformed_timeout in bogus "1 5"; do
        printf "%s\n" "$malformed_timeout" > "$SYS_ROOT/class/watchdog/watchdog0/timeout"
        must_fail watchdog_runtime_timeout_effective "$DEVICE" "$OWNER" "$SYS_ROOT"
        [[ ! -s $CALL_LOG ]]
    done
    printf "15\n16\n" > "$SYS_ROOT/class/watchdog/watchdog0/timeout"
    must_fail watchdog_runtime_timeout_effective "$DEVICE" "$OWNER" "$SYS_ROOT"
    [[ ! -s $CALL_LOG ]]
    printf "15\n" > "$SYS_ROOT/class/watchdog/watchdog0/timeout"
    cat() {
        if [[ ${*: -1} == "$SYS_ROOT/class/watchdog/watchdog0/timeout" ]]; then return 1; fi
        command cat "$@"
    }
    must_fail watchdog_runtime_timeout_effective "$DEVICE" "$OWNER" "$SYS_ROOT"
    [[ ! -s $CALL_LOG ]]
    unset -f cat
    rm -f "$SYS_ROOT/class/watchdog/watchdog0/timeout"
    mkdir "$SYS_ROOT/class/watchdog/watchdog0/timeout"
    must_fail watchdog_runtime_timeout_effective "$DEVICE" "$OWNER" "$SYS_ROOT"
    [[ ! -s $CALL_LOG ]]
    rmdir "$SYS_ROOT/class/watchdog/watchdog0/timeout"
    ln -s "$SYS_ROOT/missing-timeout" "$SYS_ROOT/class/watchdog/watchdog0/timeout"
    must_fail watchdog_runtime_timeout_effective "$DEVICE" "$OWNER" "$SYS_ROOT"
    [[ ! -s $CALL_LOG ]]
    rm -f "$SYS_ROOT/class/watchdog/watchdog0/timeout"

    watchdog_runtime_timeout_pidfd() {
        printf "called\n" >> "$CALL_LOG"
        printf 15
    }
    BAD_NEWLINE_OWNER=$(printf "pid=321;comm=generic\nwatchdog;fd=7")
    BAD_OWNERS=(
        ""
        "pid=0;comm=watchdog;fd=3"
        "pid=0321;comm=watchdog;fd=3"
        "pid=99999999999;comm=watchdog;fd=3"
        "pid=321;comm=;fd=3"
        "pid=321;comm=../watchdog;fd=3"
        "pid=321;comm=watchdog;fd=-1"
        "pid=321;comm=watchdog;fd=03"
        "pid=321;comm=watchdog;fd=99999999999"
        "pid=321;comm=watchdog;fd=3;extra=1"
        "$BAD_NEWLINE_OWNER"
    )
    for bad_owner in "${BAD_OWNERS[@]}"; do
        : > "$CALL_LOG"
        must_fail watchdog_runtime_timeout_effective "$DEVICE" "$bad_owner" "$SYS_ROOT"
        [[ ! -s $CALL_LOG ]]
    done

    PIDFD_MODE=zero
    watchdog_runtime_timeout_pidfd() {
        case $PIDFD_MODE in
            zero) printf 0 ;;
            whitespace) printf " 15" ;;
            garbage) printf bogus ;;
            multiline) printf "15\n16" ;;
            failure) return 1 ;;
            valid) printf 15 ;;
            *) return 1 ;;
        esac
    }
    for PIDFD_MODE in zero whitespace garbage multiline failure; do
        must_fail watchdog_runtime_timeout_effective "$DEVICE" "$OWNER" "$SYS_ROOT"
    done

    PIDFD_MODE=valid
    OWNER_MODE=changed
    watchdog_userspace_owner() {
        case $OWNER_MODE in
            stable) printf "%s" "$OWNER" ;;
            changed) printf "pid=322;comm=generic-watchdog;fd=7" ;;
            vanished) return 1 ;;
            *) return 1 ;;
        esac
    }
    must_fail watchdog_runtime_timeout_effective "$DEVICE" "$OWNER" "$SYS_ROOT"
    OWNER_MODE=vanished
    must_fail watchdog_runtime_timeout_effective "$DEVICE" "$OWNER" "$SYS_ROOT"
    OWNER_MODE=stable
    [[ $(watchdog_runtime_timeout_effective "$DEVICE" "$OWNER" "$SYS_ROOT") == 15 ]]

    watchdog_boot_timeout() { printf 30; }
    watchdog_kernel_open_timeout() { printf 60; }
    watchdog_device_path() { printf "%s" "$DEVICE"; }
    OWNER_MODE=vanished
    : > "$CALL_LOG"
    watchdog_runtime_timeout_effective() {
        printf "called\n" >> "$CALL_LOG"
        printf 15
    }
    must_fail watchdog_health_ready /boot/config.txt
    [[ $WATCHDOG_LAST_REASON == "No userspace process owns "* ]]
    [[ ! -s $CALL_LOG ]]

    OWNER_MODE=stable
    watchdog_runtime_timeout_effective() { printf 0; }
    must_fail watchdog_health_ready /boot/config.txt
    [[ $WATCHDOG_LAST_REASON == "The active watchdog device has no positive runtime timeout"* ]]
    watchdog_runtime_timeout_effective() { printf 15; }
    watchdog_health_ready /boot/config.txt
    [[ $WATCHDOG_LAST_RUNTIME_TIMEOUT == 15 ]]
    [[ $WATCHDOG_LAST_OWNER == "$OWNER" ]]
'

python3 - "$ROOT/workers/batocera-worker.sh" <<'APO_PIDFD_COMPILE'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
start = "<<'APO_WATCHDOG_PIDFD_PY'\n"
end = "\nAPO_WATCHDOG_PIDFD_PY\n"
assert text.count(start) == 1
assert text.count(end) == 1
body = text.split(start, 1)[1].split(end, 1)[0]
compile(body, "<watchdog-pidfd>", "exec")
assert body.count("fcntl.ioctl(") == 1
assert "WDIOC_GETTIMEOUT = 0x80045707" in body
assert "SYS_PIDFD_OPEN = 434" in body
assert "SYS_PIDFD_GETFD = 438" in body
for forbidden in ("WDIOC_SETTIMEOUT", "WDIOC_KEEPALIVE", "WDIOC_SETOPTIONS", "os.open(", "os.write("):
    assert forbidden not in body
APO_PIDFD_COMPILE

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

set +e
WATCHDOG_CONTROLLER_OUTPUT=$(APO_ROOT="$ROOT" bash -c '
    set -Eeuo pipefail
    source "$APO_ROOT/lib/common.sh"
    source "$APO_ROOT/lib/detect.sh"

    APO_DRY_RUN=0
    APO_REPAIR_WATCHDOGS=1
    APO_RAW_TARGET=fixture
    APO_LAST_CLASS=
    APO_LAST_REASON=

    apo_summary_line() { :; }
    apo_store_discovery_state() { :; }
    apo_reset_throttle_history() { :; }
    apo_profile_watchdogs_ready() { return 1; }
    apo_profile_watchdog_description() { printf fixture; }
    apo_profile_repair_watchdogs() {
        APO_LAST_CLASS=RECOVERY_FAILURE
        APO_LAST_REASON="structured watchdog recovery fixture"
        return 1
    }

    apo_watchdog_preflight
' 2>&1)
WATCHDOG_CONTROLLER_RC=$?
set -e
[[ $WATCHDOG_CONTROLLER_RC -eq 24 ]]
[[ $WATCHDOG_CONTROLLER_OUTPUT == *'structured watchdog recovery fixture'* ]]

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
