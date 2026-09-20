#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TEMP_DIR=$(mktemp -d)
trap 'test_rc=$?; rm -rf "$TEMP_DIR"; exit "$test_rc"' EXIT

FAKE_SYSTEMCTL=$TEMP_DIR/systemctl
SYSTEMCTL_LOG=$TEMP_DIR/systemctl.log
cat >"$FAKE_SYSTEMCTL" <<'APO_FAKE_SYSTEMCTL'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
if [[ $* == 'is-active --quiet watchdog.service' ]]; then exit 3; fi
exit 0
APO_FAKE_SYSTEMCTL
chmod 755 "$FAKE_SYSTEMCTL"
: >"$SYSTEMCTL_LOG"

export SYSTEMCTL_LOG
export APO_CONTROLLER_WATCHDOG_ROOT=$TEMP_DIR/live
export APO_CONTROLLER_WATCHDOG_CONFIG=$TEMP_DIR/live/watchdog.conf
export APO_CONTROLLER_WATCHDOG_LEASE_ROOT=$TEMP_DIR/live/leases
export APO_CONTROLLER_WATCHDOG_RELEASE_ROOT=$TEMP_DIR/live/released
export APO_CONTROLLER_WATCHDOG_PROVIDER_FILE=$TEMP_DIR/live/provider.conf
export APO_CONTROLLER_WATCHDOG_KEEPER=$TEMP_DIR/live/keeper.py
export APO_CONTROLLER_WATCHDOG_SERVICE=$TEMP_DIR/live/controller.service
export APO_CONTROLLER_WATCHDOG_LOCK_FILE=$TEMP_DIR/controller.lock
export APO_CONTROLLER_WATCHDOG_SYSTEMCTL=$FAKE_SYSTEMCTL
export APO_CONTROLLER_WATCHDOG_IP=$(command -v true)
export APO_CONTROLLER_WATCHDOG_PING=$(command -v true)
export APO_CONTROLLER_WATCHDOG_MANAGER_LIBRARY_ONLY=1

# shellcheck source=/dev/null
source "$ROOT/assets/debian/manage_controller_watchdog.sh"
acquire_lock() { :; }
native_watchdog_target() { return 1; }
default_gateway() { printf 192.0.2.1; }
service_ready() { return 0; }

KEEPER_SOURCE=$ROOT/assets/debian/network_watchdog_keeper.py
SERVICE_SOURCE=$ROOT/assets/debian/autopioverclock-controller-network-watchdog.service
RESULT=$TEMP_DIR/result

# A symlinked state root must be rejected before the privileged manager
# follows it or writes any managed file through it.
FOREIGN_ROOT=$TEMP_DIR/foreign-root
mkdir "$FOREIGN_ROOT"
ln -s "$FOREIGN_ROOT" "$APO_CONTROLLER_WATCHDOG_ROOT"
if cmd_ensure "$KEEPER_SOURCE" "$SERVICE_SOURCE" run-symlink >"$RESULT"; then
    printf 'controller manager accepted a symlinked state root\n' >&2
    exit 1
fi
[[ -z $(find "$FOREIGN_ROOT" -mindepth 1 -print -quit) ]]
rm "$APO_CONTROLLER_WATCHDOG_ROOT"

cmd_ensure "$KEEPER_SOURCE" "$SERVICE_SOURCE" run-a >"$RESULT"
grep -Fqx 'APO_RESULT_CLASS=PASS' "$RESULT"
grep -Fqx 'STARTUP_GRACE_SECONDS=60' "$LIVE_CONFIG"
grep -Fqx 'FAILURE_WINDOW_SECONDS=60' "$LIVE_CONFIG"
grep -Fqx 'MAX_REBOOTS=0' "$LIVE_CONFIG"
[[ -f $LIVE_KEEPER && -f $LIVE_SERVICE && -f $LEASE_ROOT/run-a.lease ]]
# Exercise create_lease without a dynamically scoped caller variable. Its path
# must be derived from its own positional argument, not an outer run_id value.
unset run_id 2>/dev/null || true
create_lease run-direct
[[ -f $LEASE_ROOT/run-direct.lease ]]
rm -- "$LEASE_ROOT/run-direct.lease"
cmd_ensure "$KEEPER_SOURCE" "$SERVICE_SOURCE" run-b >"$RESULT"
[[ $(active_lease_count) == 2 ]]
cmd_release "$KEEPER_SOURCE" "$SERVICE_SOURCE" run-a >"$RESULT"
[[ -f $LIVE_KEEPER && -f $LIVE_SERVICE && $(active_lease_count) == 1 ]]
cmd_release "$KEEPER_SOURCE" "$SERVICE_SOURCE" run-b >"$RESULT"
[[ ! -e $LIVE_KEEPER && ! -e $LIVE_SERVICE && ! -e $LIVE_CONFIG && ! -e $PROVIDER_FILE ]]
[[ -f $RELEASE_ROOT/run-a.released && -f $RELEASE_ROOT/run-b.released ]]

# A changed live file blocks final cleanup. Restoring the exact managed bytes
# lets the checkpointed release finish without deleting anything foreign.
cmd_ensure "$KEEPER_SOURCE" "$SERVICE_SOURCE" run-tamper >"$RESULT"
printf '\n# foreign change\n' >>"$LIVE_KEEPER"
if cmd_release "$KEEPER_SOURCE" "$SERVICE_SOURCE" run-tamper >"$RESULT"; then
    printf 'controller watchdog cleanup accepted a changed live keeper\n' >&2
    exit 1
fi
[[ -f $LIVE_KEEPER && -f $LEASE_ROOT/run-tamper.releasing ]]
install -m 755 "$KEEPER_SOURCE" "$LIVE_KEEPER"
cmd_release "$KEEPER_SOURCE" "$SERVICE_SOURCE" run-tamper >"$RESULT"
[[ -f $RELEASE_ROOT/run-tamper.released && ! -e $LIVE_KEEPER ]]

# A native Debian watcher may replace the exact project companion while any
# number of leases remain. The native service itself is never disabled,
# stopped, edited, or removed.
NATIVE_SENTINEL=$TEMP_DIR/native-watchdog.conf
printf 'ping = 192.0.2.1\nrepair-binary = /opt/custom-repair\nrepair-timeout = 17\n' >"$NATIVE_SENTINEL"
cmd_ensure "$KEEPER_SOURCE" "$SERVICE_SOURCE" run-migrate-a >"$RESULT"
native_watchdog_target() { printf 192.0.2.1; }
cmd_ensure "$KEEPER_SOURCE" "$SERVICE_SOURCE" run-migrate-b >"$RESULT"
load_provider
[[ $PROVIDER_MODE == native-debian && $(active_lease_count) == 2 ]]
[[ ! -e $LIVE_KEEPER && ! -e $LIVE_SERVICE && ! -e $LIVE_CONFIG ]]
grep -Fqx 'ping = 192.0.2.1' "$NATIVE_SENTINEL"
grep -Fqx 'repair-binary = /opt/custom-repair' "$NATIVE_SENTINEL"
grep -Fqx 'repair-timeout = 17' "$NATIVE_SENTINEL"
if grep -Eq '^(disable|stop) watchdog\.service$' "$SYSTEMCTL_LOG"; then
    printf 'controller manager attempted to change native watchdog.service\n' >&2
    exit 1
fi
cmd_release "$KEEPER_SOURCE" "$SERVICE_SOURCE" run-migrate-a >"$RESULT"
cmd_release "$KEEPER_SOURCE" "$SERVICE_SOURCE" run-migrate-b >"$RESULT"
[[ -f $NATIVE_SENTINEL && ! -e $PROVIDER_FILE ]]

# Migration to a native provider refuses to remove a companion whose saved
# hashes no longer match its live files.
native_watchdog_target() { return 1; }
cmd_ensure "$KEEPER_SOURCE" "$SERVICE_SOURCE" run-migration-tamper >"$RESULT"
printf '\n# changed before migration\n' >>"$LIVE_SERVICE"
native_watchdog_target() { printf 192.0.2.1; }
if cmd_ensure "$KEEPER_SOURCE" "$SERVICE_SOURCE" run-migration-second >"$RESULT"; then
    printf 'controller migration removed a changed companion\n' >&2
    exit 1
fi
[[ -f $LIVE_SERVICE && -f $LEASE_ROOT/run-migration-tamper.lease ]]

APO_ROOT=$ROOT APO_CLI_LIBRARY_ONLY=1 CONTROLLER_TEST_ROOT=$TEMP_DIR bash -c '
    set -Eeuo pipefail
    source "$APO_ROOT/autopioverclock"
    APO_OUTPUT_DIR=$CONTROLLER_TEST_ROOT/controller-state
    APO_TARGET_SLUG=fixture-target
    APO_RAW_TARGET=fixture-target
    APO_REMOTE_TARGET="$(id -un)@fixture-target"
    APO_TARGET_HOST=fixture-target
    APO_MODE_REQUESTED=auto
    APO_DRY_RUN=0
    mkdir -p "$APO_OUTPUT_DIR"
    apo_init_artifacts
    apo_state_initialize

    apo_controller_watchdog_manager_capture() {
        local action=$1 output_file=$3 provider target count reason
        if [[ $action == ensure ]]; then
            provider=standalone
            target=192.0.2.1
            count=1
            reason="controller ready"
        else
            provider=absent
            target=""
            count=0
            reason="controller released"
        fi
        {
            printf "APO_DATA\tCONTROLLER_WATCHDOG_PROVIDER\t%s\n" "$(printf %s "$provider" | base64 | tr -d "\n")"
            printf "APO_DATA\tCONTROLLER_WATCHDOG_TARGET\t%s\n" "$(printf %s "$target" | base64 | tr -d "\n")"
            printf "APO_DATA\tCONTROLLER_WATCHDOG_LEASE_COUNT\t%s\n" "$(printf %s "$count" | base64 | tr -d "\n")"
            printf "APO_RESULT_CLASS=PASS\n"
            printf "APO_RESULT_REASON_B64=%s\n" "$(printf %s "$reason" | base64 | tr -d "\n")"
        } >"$output_file"
        apo_classify_output "$output_file" controller-watchdog
    }

    apo_controller_watchdog_ensure_for_run
    [[ $(apo_state_get CONTROLLER_WATCHDOG_LEASE_ID) == "$APO_RUN_ID" ]]
    [[ $(apo_state_get CONTROLLER_WATCHDOG_LEASED) == 1 ]]
    [[ $(apo_state_get CONTROLLER_WATCHDOG_STATUS) == READY ]]
    [[ $(apo_state_get CONTROLLER_WATCHDOG_PROVIDER) == standalone ]]
    apo_controller_watchdog_release_for_run
    [[ $(apo_state_get CONTROLLER_WATCHDOG_LEASED) == 0 ]]
    [[ $(apo_state_get CONTROLLER_WATCHDOG_STATUS) == RELEASED ]]
    edge_lease=$(apo_controller_watchdog_new_lease_id post-floor-edge)
    final_lease=$(apo_controller_watchdog_new_lease_id post-floor-final)
    apo_is_safe_run_id "$edge_lease"
    apo_is_safe_run_id "$final_lease"
    [[ $edge_lease != "$final_lease" ]]
'

printf 'test_controller_watchdog: PASS\n'
