#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

fail() {
    printf 'test_reset: %s\n' "$1" >&2
    exit 1
}

TEST_ROOT=$(mktemp -d)
FAKE_BIN="$TEST_ROOT/fake-bin"
FAKE_HOME="$TEST_ROOT/home"
OUTPUT_DIR="$FAKE_HOME/overclock-results"
SSH_LOG="$TEST_ROOT/ssh-calls"
PROCESS_LOG="$TEST_ROOT/process-manager-calls"
mkdir -p "$FAKE_BIN" "$OUTPUT_DIR"
: > "$SSH_LOG"
: > "$PROCESS_LOG"
trap '[[ -z ${SENTINEL_PID:-} ]] || kill "$SENTINEL_PID" >/dev/null 2>&1 || true; rm -rf "$TEST_ROOT"' EXIT

printf '#!/usr/bin/env bash\nprintf "ssh\\n" >> "$APO_RESET_TEST_SSH_LOG"\nexit 99\n' > "$FAKE_BIN/ssh"
chmod 755 "$FAKE_BIN/ssh"
for command_name in tmux byobu pkill killall; do
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$(basename "$0")" >> "$APO_RESET_TEST_PROCESS_LOG"\nexit 97\n' > "$FAKE_BIN/$command_name"
    chmod 755 "$FAKE_BIN/$command_name"
done

CLI_OUTPUT=''
CLI_RC=0
run_cli() {
    : > "$SSH_LOG"
    : > "$PROCESS_LOG"
    set +e
    # The production reset command deliberately keeps monitoring an
    # unreachable target. This fixture's SSH binary is permanently failing,
    # so give only the synthetic process a short outer deadline; otherwise a
    # successful persistent-recovery implementation would make the unit test
    # wait forever.
    CLI_OUTPUT=$(env HOME="$FAKE_HOME" PATH="$FAKE_BIN:$PATH" \
        APO_RESET_TEST_SSH_LOG="$SSH_LOG" APO_RESET_TEST_PROCESS_LOG="$PROCESS_LOG" \
        timeout --signal=TERM --kill-after=1s 10s "$ROOT/autopioverclock" "$@" 2>&1)
    CLI_RC=$?
    set -e
}

# Explicit `run reset` continues to mean a target literally named "reset".
# The ordinary public reset syntax is now command-first.
MISSING_CONFIG="$TEST_ROOT/does-not-exist.conf"
run_cli run reset --config "$MISSING_CONFIG"
(( CLI_RC != 0 )) || fail '`run reset` unexpectedly succeeded'
[[ $CLI_OUTPUT == *"Cannot read configuration file: $MISSING_CONFIG"* ]] ||
    fail '`run reset` no longer treats reset as the run target'
[[ ! -s $SSH_LOG ]] || fail '`run reset` reached SSH before its local fixture failure'

run_cli reset fixture-target
(( CLI_RC != 0 )) || fail 'fake-transport command-first reset unexpectedly succeeded'
[[ -s $SSH_LOG ]] || fail 'command-first reset did not reach reset transport dispatch'

# The removed postfix form is rejected locally with the supported spelling.
run_cli fixture-target reset
(( CLI_RC != 0 )) || fail 'removed TARGET reset order unexpectedly succeeded'
[[ $CLI_OUTPUT == *'Use: autopioverclock reset TARGET.'* ]] || fail 'removed TARGET reset order did not show the supported spelling'
[[ ! -s $SSH_LOG ]] || fail 'removed TARGET reset order reached SSH'

# Reset is explicit and noninteractive. Tuning, saved-run selection, ordinary
# confirmation, and report-only flags must be rejected before any SSH call.
assert_reset_option_rejected() {
    local label=$1
    shift
    run_cli reset fixture-target "$@"
    (( CLI_RC != 0 )) || fail "reset accepted $label"
    [[ ! -s $SSH_LOG ]] || fail "reset reached SSH after accepting $label"
    [[ $CLI_OUTPUT == *reset* || $CLI_OUTPUT == *Reset* ]] || fail "reset rejection for $label did not identify reset semantics"
}

assert_reset_option_rejected --yes --yes
assert_reset_option_rejected --run-id --run-id fixture-run
assert_reset_option_rejected --config --config "$MISSING_CONFIG"
assert_reset_option_rejected --mode --mode auto
assert_reset_option_rejected --install-missing --install-missing
assert_reset_option_rejected --dry-run --dry-run
assert_reset_option_rejected --qualification-hours --qualification-hours 3
assert_reset_option_rejected --final-hours --final-hours 6
assert_reset_option_rejected --no-max-fan --no-max-fan
assert_reset_option_rejected --redact --redact
assert_reset_option_rejected --reset --reset
assert_reset_option_rejected 'duplicate --freshtuning' --freshtuning --freshtuning
assert_reset_option_rejected '-f without --freshtuning' -f
assert_reset_option_rejected 'duplicate -f' --freshtuning -f -f

# Transport and artifact selectors remain available without changing reset's
# stock policy. A readable identity fixture prevents a local option failure.
IDENTITY_FILE="$TEST_ROOT/identity"
printf 'fixture identity\n' > "$IDENTITY_FILE"
run_cli reset fixture-target --output-dir "$TEST_ROOT/custom-output" --ssh-port 2222 --identity-file "$IDENTITY_FILE"
(( CLI_RC != 0 )) || fail 'fake-transport reset with plumbing selectors unexpectedly succeeded'
[[ $CLI_OUTPUT != *'is not valid with reset TARGET'* ]] ||
    fail 'reset rejected an approved transport or artifact selector'
[[ -s $SSH_LOG ]] || fail 'reset with approved selectors did not reach transport dispatch'

run_cli reset fixture-target --freshtuning
(( CLI_RC != 0 )) || fail 'fake-transport fresh-tuning reset unexpectedly succeeded'
[[ $CLI_OUTPUT != *'is not valid with reset TARGET'* ]] || fail 'reset rejected --freshtuning'
[[ -s $SSH_LOG ]] || fail 'fresh-tuning reset did not reach transport dispatch'

run_cli reset fixture-target --freshtuning -f
(( CLI_RC != 0 )) || fail 'fake-transport destructive fresh-tuning reset unexpectedly succeeded'
[[ $CLI_OUTPUT != *'is not valid with reset TARGET'* ]] || fail 'reset rejected --freshtuning -f'
[[ -s $SSH_LOG ]] || fail 'destructive fresh-tuning reset did not reach transport dispatch'

# A failed reset attempt may add its own audit artifacts, but it must not
# delete or truncate any prior run. It also must not signal unrelated jobs or
# invoke a terminal/session manager.
printf 'preserved log bytes\n' > "$OUTPUT_DIR/fixture-target-old.log"
printf 'preserved state bytes\n' > "$OUTPUT_DIR/fixture-target-old.state"
printf 'preserved candidate bytes\n' > "$OUTPUT_DIR/fixture-target-old-candidate.log"
OLD_LOG_HASH=$(sha256sum "$OUTPUT_DIR/fixture-target-old.log" | awk 'NR == 1 {print $1}')
OLD_STATE_HASH=$(sha256sum "$OUTPUT_DIR/fixture-target-old.state" | awk 'NR == 1 {print $1}')
OLD_CANDIDATE_HASH=$(sha256sum "$OUTPUT_DIR/fixture-target-old-candidate.log" | awk 'NR == 1 {print $1}')
sleep 30 &
SENTINEL_PID=$!
run_cli reset fixture-target
kill -0 "$SENTINEL_PID" 2>/dev/null || fail 'reset terminated an unrelated local process'
[[ ! -s $PROCESS_LOG ]] || fail 'reset invoked a Byobu/tmux or process-wide kill command'
[[ -f $OUTPUT_DIR/fixture-target-old.log && -f $OUTPUT_DIR/fixture-target-old.state && -f $OUTPUT_DIR/fixture-target-old-candidate.log ]] ||
    fail 'reset deleted a prior artifact'
[[ $(sha256sum "$OUTPUT_DIR/fixture-target-old.log" | awk 'NR == 1 {print $1}') == "$OLD_LOG_HASH" ]] || fail 'reset rewrote a prior log'
[[ $(sha256sum "$OUTPUT_DIR/fixture-target-old.state" | awk 'NR == 1 {print $1}') == "$OLD_STATE_HASH" ]] || fail 'reset rewrote prior state'
[[ $(sha256sum "$OUTPUT_DIR/fixture-target-old-candidate.log" | awk 'NR == 1 {print $1}') == "$OLD_CANDIDATE_HASH" ]] || fail 'reset rewrote a prior candidate log'
kill "$SENTINEL_PID" >/dev/null 2>&1 || true
wait "$SENTINEL_PID" 2>/dev/null || true
SENTINEL_PID=''

# Public/controller contract: command-first help, verified-stock completion, worker
# data binding, and no terminal/session-process management.
grep -Fq 'autopioverclock reset TARGET [--freshtuning [-f]]' "$ROOT/autopioverclock" || fail 'usage does not document fresh-tuning reset syntax'
if grep -Fq 'autopioverclock TARGET reset' "$ROOT/autopioverclock"; then
    fail 'usage still documents the removed postfix reset syntax'
fi
grep -Rqs 'STOCK_VERIFIED' "$ROOT/autopioverclock" "$ROOT/lib" "$ROOT/profiles" || fail 'controller lacks the verified-stock completion checkpoint'
grep -Rqs 'RESET_BACKUP' "$ROOT/autopioverclock" "$ROOT/lib" "$ROOT/profiles" || fail 'controller does not persist/report the reset backup'
grep -Rqs 'reset-stock' "$ROOT/autopioverclock" "$ROOT/lib" "$ROOT/profiles" || fail 'controller does not dispatch stock reset'
grep -Rqs 'verify-stock-reset' "$ROOT/autopioverclock" "$ROOT/lib" "$ROOT/profiles" || fail 'controller does not dispatch post-reboot stock verification'
grep -Rqs 'reboot-stock-reset' "$ROOT/autopioverclock" "$ROOT/lib" "$ROOT/profiles" || fail 'controller does not dispatch the stock-reset reboot'
if grep -RInE -- '(byobu|pkill|killall|tmux[[:space:]]+(attach|detach|kill|new|rename|respawn|send|set|split|swap|move|link|unlink)[[:alnum:]_-]*)' "$ROOT/autopioverclock" "$ROOT/lib" "$ROOT/profiles"; then
    fail 'controller contains forbidden terminal/session or process-wide management'
fi
grep -Fq 'Existing run files are retained unless' "$ROOT/lib/logging.sh" || fail 'artifact-retention invariant is missing'

# Worker contract: reset and post-reboot verification exist on both platforms,
# publish hash/backup evidence, preserve disabled source lines, and use the
# platform persistent backup root.
for worker_file in "$ROOT/workers/debian-worker.sh" "$ROOT/workers/batocera-worker.sh"; do
    grep -q 'reset-stock)' "$worker_file" || fail "$(basename "$worker_file") lacks reset-stock dispatch"
    grep -q 'reboot-stock-reset)' "$worker_file" || fail "$(basename "$worker_file") lacks reboot-stock-reset dispatch"
    grep -q 'verify-stock-reset)' "$worker_file" || fail "$(basename "$worker_file") lacks verify-stock-reset dispatch"
    grep -Eq 'verify-stock-reset\).*run_with_mutation_lock' "$worker_file" || fail "$(basename "$worker_file") does not serialize final stock verification"
    for marker in RESET_BACKUP RESET_OLD_HASH RESET_NEW_HASH RESET_DISABLED_KEYS; do
        grep -q "$marker" "$worker_file" || fail "$(basename "$worker_file") lacks $marker evidence"
    done
    grep -q 'disabled_keys=none' "$worker_file" || fail "$(basename "$worker_file") lacks idempotent stock evidence"
    grep -Fq '# AUTOPIOVERCLOCK-STOCK-DISABLED' "$worker_file" || fail "$(basename "$worker_file") does not preserve disabled tuning lines"
    verify_stock_body=$(sed -n '/^cmd_verify_stock_reset()/,/^}/p' "$worker_file")
    [[ $verify_stock_body == *watchdog_health_ready* ]] || fail "$(basename "$worker_file") stock verification omits the watchdog chain"
done
grep -Fq '/var/lib/autopioverclock/backups' "$ROOT/workers/debian-worker.sh" || fail 'Debian reset backup is not persistent'
grep -Fq '/userdata/system/autopioverclock/backups' "$ROOT/workers/batocera-worker.sh" || fail 'Batocera reset backup is not persistent'
batocera_verify_body=$(sed -n '/^cmd_verify_stock_reset()/,/^}/p' "$ROOT/workers/batocera-worker.sh")
[[ $batocera_verify_body == *'boot_mount_has_option ro'* ]] || fail 'Batocera stock verification does not prove /boot read-only'

# Exercise the file-only worker helpers directly on both implementations. No
# boot filesystem or privileged target operation is touched by these fixtures.
for worker_file in "$ROOT/workers/debian-worker.sh" "$ROOT/workers/batocera-worker.sh"; do
    (
        export APO_WORKER_LIBRARY_ONLY=1
        # shellcheck disable=SC1090
        source "$worker_file"
        helper_root="$TEST_ROOT/helpers-$(basename "$worker_file" .sh)"
        mkdir -p "$helper_root"
        source_config="$helper_root/config.txt"
        rendered_config="$helper_root/rendered.txt"
        printf '%s\n' \
            '[pi4]' \
            'dtoverlay=vc4-kms-v3d' \
            'kernel_watchdog_timeout=60' \
            'arm_freq=3000' \
            'v3d_freq_min = 600' \
            'over_voltage_delta=50000' \
            '# arm_freq=already-commented' \
            "$CLOCK_MARKER_BEGIN" \
            '# Run: old-managed-run' \
            '[all]' \
            'over_voltage_delta=10000' \
            'arm_freq=2800' \
            'v3d_freq=900' \
            "$CLOCK_MARKER_END" \
            'dtparam=audio=on' > "$source_config"
        reset_stock_validate_config "$source_config" || fail "$(basename "$worker_file") rejected a regular reset fixture"
        reset_stock_render_config "$source_config" "$rendered_config" || fail "$(basename "$worker_file") could not render stock config"
        grep -Fqx 'dtoverlay=vc4-kms-v3d' "$rendered_config" || fail "$(basename "$worker_file") dropped an unrelated config line"
        grep -Fqx 'kernel_watchdog_timeout=60' "$rendered_config" || fail "$(basename "$worker_file") changed the native watchdog timeout"
        grep -Fqx '# AUTOPIOVERCLOCK-STOCK-DISABLED arm_freq=3000' "$rendered_config" || fail "$(basename "$worker_file") did not preserve arm_freq"
        grep -Fqx '# AUTOPIOVERCLOCK-STOCK-DISABLED v3d_freq_min = 600' "$rendered_config" || fail "$(basename "$worker_file") did not preserve v3d_freq_min"
        grep -Fqx '# AUTOPIOVERCLOCK-STOCK-DISABLED over_voltage_delta=50000' "$rendered_config" || fail "$(basename "$worker_file") did not preserve voltage"
        grep -Fqx '# arm_freq=already-commented' "$rendered_config" || fail "$(basename "$worker_file") changed an existing comment"
        if grep -Fq "$CLOCK_MARKER_BEGIN" "$rendered_config" || grep -Fq "$CLOCK_MARKER_END" "$rendered_config"; then
            fail "$(basename "$worker_file") retained an old managed clock block"
        fi
        awk '
            /^\[[^]]+\]$/ {section=$0}
            $0=="dtparam=audio=on" {found=1; if (section!="[all]") exit 1}
            END {if (!found) exit 1}
        ' "$rendered_config" || fail "$(basename "$worker_file") changed section scope after removing a managed block"

        stock_config="$helper_root/already-stock.txt"
        stock_rendered="$helper_root/already-stock-rendered.txt"
        printf '%s\n' 'dtoverlay=vc4-kms-v3d' '# no explicit clock or voltage overrides' > "$stock_config"
        reset_stock_validate_config "$stock_config" || fail "$(basename "$worker_file") rejected an already-stock fixture"
        reset_stock_render_config "$stock_config" "$stock_rendered" || fail "$(basename "$worker_file") could not render an already-stock config"
        cmp "$stock_config" "$stock_rendered" || fail "$(basename "$worker_file") changed an already-stock config"

        default_voltage_managed="$helper_root/default-voltage-managed.txt"
        default_voltage_rendered="$helper_root/default-voltage-rendered.txt"
        printf '%s\n' \
            'dtparam=audio=on' \
            "$CLOCK_MARKER_BEGIN" \
            '# Run: default-voltage-run' \
            '[all]' \
            'arm_freq=3000' \
            'gpu_freq=1100' \
            "$CLOCK_MARKER_END" > "$default_voltage_managed"
        reset_stock_validate_config "$default_voltage_managed" || fail "$(basename "$worker_file") rejected a managed block with implicit default voltage"
        reset_stock_render_config "$default_voltage_managed" "$default_voltage_rendered" || fail "$(basename "$worker_file") could not remove a managed block with implicit default voltage"
        grep -Fqx 'dtparam=audio=on' "$default_voltage_rendered" || fail "$(basename "$worker_file") dropped unrelated content around an implicit-voltage block"
        if grep -Fq "$CLOCK_MARKER_BEGIN" "$default_voltage_rendered" || grep -Fq 'arm_freq=3000' "$default_voltage_rendered"; then
            fail "$(basename "$worker_file") retained an implicit-voltage managed block"
        fi

        printf 'include extras.txt\n' > "$helper_root/include.txt"
        if reset_stock_validate_config "$helper_root/include.txt"; then
            fail "$(basename "$worker_file") accepted an unbound include"
        fi
        [[ ${RESET_STOCK_LAST_REASON,,} == *include* ]] || fail "$(basename "$worker_file") include rejection lacked a reason"

        printf '%s\n' "$CLOCK_MARKER_BEGIN" 'arm_freq=3000' > "$helper_root/malformed.txt"
        if reset_stock_validate_config "$helper_root/malformed.txt"; then
            fail "$(basename "$worker_file") accepted malformed managed markers"
        fi
        printf '%s\n' \
            "$CLOCK_MARKER_BEGIN" \
            '# Run: malformed-content-run' \
            '[all]' \
            'over_voltage_delta=50000' \
            'arm_freq=3000' \
            'dtoverlay=unrelated-user-setting' \
            "$CLOCK_MARKER_END" > "$helper_root/malformed-content.txt"
        if reset_stock_validate_config "$helper_root/malformed-content.txt"; then
            fail "$(basename "$worker_file") accepted unknown content inside a managed clock block"
        fi

        ln -s "$source_config" "$helper_root/config-link.txt"
        if reset_stock_validate_config "$helper_root/config-link.txt"; then
            fail "$(basename "$worker_file") accepted a config symlink"
        fi

        source_hash=$(sha256sum "$source_config" | awk 'NR == 1 {print $1}')
        backup_file="$helper_root/config-backup.txt"
        reset_stock_backup_verified "$source_config" "$backup_file" "$source_hash" || fail "$(basename "$worker_file") could not create a verified backup"
        cmp "$source_config" "$backup_file" || fail "$(basename "$worker_file") backup bytes differ"
        if reset_stock_backup_verified "$source_config" "$backup_file" "$source_hash"; then
            fail "$(basename "$worker_file") overwrote an existing backup"
        fi

        install_destination="$helper_root/install-destination.txt"
        cp -- "$source_config" "$install_destination"
        rendered_hash=$(sha256sum "$rendered_config" | awk 'NR == 1 {print $1}')
        reset_stock_replace_verified "$rendered_config" "$install_destination" "$rendered_hash" "$source_hash" helper-install ||
            fail "$(basename "$worker_file") could not perform a boundary-checked reset replacement"
        cmp "$rendered_config" "$install_destination" || fail "$(basename "$worker_file") reset replacement bytes differ"

        raced_destination="$helper_root/raced-destination.txt"
        cp -- "$source_config" "$raced_destination"
        printf 'external-change\n' >> "$raced_destination"
        raced_hash=$(sha256sum "$raced_destination" | awk 'NR == 1 {print $1}')
        if reset_stock_replace_verified "$rendered_config" "$raced_destination" "$rendered_hash" "$source_hash" helper-race; then
            fail "$(basename "$worker_file") overwrote a destination that changed before the replacement boundary"
        fi
        [[ $(sha256sum "$raced_destination" | awk 'NR == 1 {print $1}') == "$raced_hash" ]] ||
            fail "$(basename "$worker_file") changed unknown raced destination content"

        printf 'foreign tryboot bytes\n' > "$helper_root/foreign-tryboot.txt"
        if reset_stock_tryboot_kind "$helper_root/foreign-tryboot.txt" >/dev/null 2>&1; then
            fail "$(basename "$worker_file") accepted foreign tryboot content"
        fi

        candidate_owner=$(printf 'd%.0s' {1..64})
        candidate_tryboot="$helper_root/candidate-with-max-fan.txt"
        render_tryboot_config "$stock_config" "$candidate_tryboot" 2900 1000 v3d_freq 0 candidate-fan-run "$candidate_owner"
        [[ $(reset_stock_tryboot_kind "$candidate_tryboot" "$candidate_owner") == complete ]] ||
            fail "$(basename "$worker_file") did not recognize the new max-fan tryboot format"
        sed 's/dtparam=fan_temp2_speed=255/dtparam=fan_temp2_speed=254/' "$candidate_tryboot" > "$helper_root/tampered-candidate.txt"
        if reset_stock_tryboot_kind "$helper_root/tampered-candidate.txt" "$candidate_owner" >/dev/null 2>&1; then
            fail "$(basename "$worker_file") accepted a tampered candidate fan override"
        fi

        normal_fan_owner=$(printf 'e%.0s' {1..64})
        normal_fan_tryboot="$helper_root/candidate-with-normal-fan.txt"
        render_tryboot_reservation normal-fan-run "$normal_fan_owner" > "$normal_fan_tryboot"
        printf '\n%s\n# Run: normal-fan-run\n[all]\nover_voltage_delta=0\narm_freq=2800\nv3d_freq=1000\n%s\n# AUTOPIOVERCLOCK TRYBOOT COMPLETE: %s\n' \
            "$CLOCK_MARKER_BEGIN" "$CLOCK_MARKER_END" "$normal_fan_owner" >> "$normal_fan_tryboot"
        [[ $(reset_stock_tryboot_kind "$normal_fan_tryboot" "$normal_fan_owner") == complete ]] ||
            fail "$(basename "$worker_file") did not recognize current normal-fan tryboot evidence"

        reset_owner=$(printf 'c%.0s' {1..64})
        stranded_quarantine="$helper_root/.autopioverclock-stock-reset-old-reset-run-$reset_owner"
        render_tryboot_reservation old-candidate-run "$reset_owner" > "$stranded_quarantine"
        reset_stock_scan_tryboot "$source_config" || fail "$(basename "$worker_file") could not recover a structurally owned interrupted-reset quarantine"
        [[ $RESET_STOCK_TRYBOOT_PATH == "$stranded_quarantine" && $RESET_STOCK_TRYBOOT_KIND == reservation ]] ||
            fail "$(basename "$worker_file") did not bind the interrupted-reset quarantine to its ownership evidence"
        rm -f -- "$stranded_quarantine"
    )
done

# Controller-only orchestration fixture: prove the reset is standalone,
# noninteractive, binds required worker metadata, reboots, verifies, and ends
# in the exact stock-verified state with a preservation/backup PASS event.
# shellcheck disable=SC2030,SC2031
(
    # shellcheck source=lib/reset.sh
    source "$ROOT/lib/reset.sh"
    declare -Ag APO_STATE=()
    declare -Ag APO_DISCOVERY=(
        [PROFILE]=debian
        [BOOT_CONFIG]=/boot/firmware/config.txt
        [TRYBOOT_CONFIG]=/boot/firmware/tryboot.txt
        [BOOT_MOUNT]=/boot/firmware
        [GPU_KEY]=v3d_freq
        [NORMAL_CPU]=3000
        [NORMAL_GPU]=900
        [NORMAL_VOLTAGE]=50000
        [PERMANENT_HASH]=$(printf 'a%.0s' {1..64})
        [STORAGE_LAYOUT]='root=/dev/mmcblk0p2;boot=/dev/mmcblk0p1'
        [MODEL]='Raspberry Pi 5 Model B'
        [COMPATIBLE]='raspberrypi,5-model-b,brcm,bcm2712'
        [ARCH]=aarch64
        [OS_ID]=debian
        [OS_VERSION]=13
        [TRYBOOT_EXISTS]=0
        [TRYBOOT_TYPE]=absent
        [TRYBOOT_HASH]=unavailable
        [ROOT_SOURCE]=/dev/mmcblk0p2
        [BOOT_SOURCE]=/dev/mmcblk0p1
        [NETWORK_WATCHDOG_KIND]=debian-watchdog-observer
        [NETWORK_WATCHDOG_INSTALL_RUN_ID]=older-fixture-run
        [NETWORK_WATCHDOG_INSTALL_BACKUP]=/var/lib/autopioverclock/backups/network-watchdog-observer-fixture
    )
    declare -Ag APO_WORKER_DATA=()
    declare -ag RESET_ACTIONS=() RESET_EVENTS=()
    APO_VERSION=fixture
    APO_RUN_ID=reset-fixture-run
    APO_REMOTE_TARGET=root@fixture-target
    APO_REMOTE_WORKER=/tmp/reset-worker
    APO_BOOT_TIMEOUT=30
    APO_BOOT_SETTLE_SECONDS=0
    APO_LAST_WORKER_LOG=''
    RESET_BACKUP_FIXTURE=/var/lib/autopioverclock/backups/config-reset-fixture.txt
    RESET_TRYBOOT_BACKUP_FIXTURE=/var/lib/autopioverclock/backups/tryboot-reset-fixture.txt
    RESET_OLD_HASH_FIXTURE=$(printf 'a%.0s' {1..64})
    RESET_NEW_HASH_FIXTURE=$(printf 'b%.0s' {1..64})

    apo_state_set() { APO_STATE[$1]=${2-}; }
    apo_state_get() { printf '%s' "${APO_STATE[$1]:-${2-}}"; }
    apo_state_save() { RESET_ACTIONS+=(state-save); }
    apo_state_initialize() { :; }
    apo_init_artifacts() { RESET_ACTIONS+=(init-artifacts); }
    apo_store_artifact_state() { RESET_ACTIONS+=(store-artifacts); }
    apo_summary_line() { :; }
    apo_event() { RESET_EVENTS+=("$1|$2|${3-}|${4-}"); }
    apo_ssh_preflight() { RESET_ACTIONS+=(ssh-preflight); }
    apo_probe_profile() { printf debian; }
    apo_load_profile() { RESET_ACTIONS+=("load-profile:$1"); }
    apo_deploy_worker() { RESET_ACTIONS+=(deploy-worker); }
    apo_discovery_capture() { RESET_ACTIONS+=(discovery); }
    apo_validate_pi5() { RESET_ACTIONS+=(validate-pi5); }
    apo_profile_cleanup_discovered_watchdog() {
        RESET_ACTIONS+=(cleanup-discovered-watchdog)
        APO_DISCOVERY[NETWORK_WATCHDOG_KIND]=''
        APO_DISCOVERY[NETWORK_WATCHDOG_INSTALL_RUN_ID]=''
        APO_DISCOVERY[NETWORK_WATCHDOG_INSTALL_BACKUP]=''
    }
    apo_profile_watchdogs_ready() { RESET_ACTIONS+=(watchdog-ready); }
    apo_profile_watchdog_description() { printf fixture-watchdog-ready; }
    action_index() {
        local wanted=$1 index
        for index in "${!RESET_ACTIONS[@]}"; do
            [[ ${RESET_ACTIONS[$index]} == "$wanted" ]] && { printf "%s" "$index"; return 0; }
        done
        return 1
    }
    apo_remote_boot_id() { printf boot-before; }
    apo_post_reboot_handshake() { [[ $1 == boot-before && $2 == 30 && $3 == stock-reset ]]; RESET_ACTIONS+=(post-reboot-handshake); APO_REBOOT_BOOT_ID=boot-after; APO_REBOOT_HANDSHAKE_STAGE='complete'; }
    apo_remote_worker() { RESET_ACTIONS+=("remote-worker:$2"); return 0; }
    apo_run_worker_capture() { RESET_ACTIONS+=("worker:$2"); APO_LAST_WORKER_LOG=$1; return 0; }
    apo_parse_data_file() {
        case $APO_LAST_WORKER_LOG in
            reset-stock)
                APO_WORKER_DATA=(
                    [RESET_BACKUP]="$RESET_BACKUP_FIXTURE"
                    [RESET_TRYBOOT_BACKUP]="$RESET_TRYBOOT_BACKUP_FIXTURE"
                    [RESET_OLD_HASH]="$RESET_OLD_HASH_FIXTURE"
                    [RESET_NEW_HASH]="$RESET_NEW_HASH_FIXTURE"
                    [RESET_DISABLED_KEYS]='arm_freq,v3d_freq,over_voltage_delta'
                )
                ;;
            verify-stock-reset)
                APO_WORKER_DATA=(
                    [RESET_NEW_HASH]="$RESET_NEW_HASH_FIXTURE"
                    [RESET_ACTIVE_CPU]=2400
                    [RESET_ACTIVE_GPU]=960
                    [RESET_ACTIVE_VOLTAGE]=0
                )
                ;;
        esac
    }
    apo_confirm_ordinary() { fail 'reset invoked an ordinary prompt'; }
    apo_confirm_exact() { fail 'reset invoked an exact prompt'; }
    apo_class_exit_code() { printf 1; }
    apo_die() { fail "unexpected reset abort: $1"; }
    sleep() { :; }

    apo_reset_stock
    [[ ${APO_STATE[STATUS]} == PASS ]] || fail 'reset fixture did not finish PASS'
    [[ ${APO_STATE[PHASE]} == COMPLETE ]] || fail 'reset fixture did not finish COMPLETE'
    [[ ${APO_STATE[SUBPHASE]} == STOCK_VERIFIED ]] || fail 'reset fixture did not finish STOCK_VERIFIED'
    [[ ${APO_STATE[FAILURE_CLASS]} == '' && ${APO_STATE[FAILURE_REASON]} == '' ]] || fail 'reset fixture retained failure evidence'
    [[ ${APO_STATE[RESET_BACKUP]} == "$RESET_BACKUP_FIXTURE" ]] || fail 'reset fixture did not persist its backup path'
    [[ ${APO_STATE[RESET_TRYBOOT_BACKUP]} == "$RESET_TRYBOOT_BACKUP_FIXTURE" ]] || fail 'reset fixture did not persist its managed-tryboot backup path'
    [[ ${APO_STATE[RESET_OLD_HASH]} == "$RESET_OLD_HASH_FIXTURE" && ${APO_STATE[RESET_NEW_HASH]} == "$RESET_NEW_HASH_FIXTURE" ]] || fail 'reset fixture did not bind old/new hashes'
    [[ ${APO_STATE[RESET_RETIRE_RESUMABLE]} == 1 && ${APO_STATE[RESET_RETIRE_CUTOFF_RUN_ID]} == "$APO_RUN_ID" ]] ||
        fail 'reset fixture did not persist the resumable-run retirement boundary'
    [[ ${APO_STATE[NORMAL_CPU]} == 2400 && ${APO_STATE[NORMAL_GPU]} == 960 && ${APO_STATE[NORMAL_VOLTAGE]} == 0 ]] || fail 'reset fixture retained stale pre-reset clocks'
    [[ " ${RESET_ACTIONS[*]} " == *' worker:reset-stock '* ]] || fail 'reset fixture skipped reset-stock'
    [[ " ${RESET_ACTIONS[*]} " == *' cleanup-discovered-watchdog '* ]] || fail 'reset fixture skipped the discovered run-owned watchdog cleanup'
    CLEANUP_INDEX=$(action_index cleanup-discovered-watchdog) || fail 'reset did not record the watchdog cleanup ordering point'
    WATCHDOG_INDEX=$(action_index watchdog-ready) || fail 'reset did not record the watchdog readiness ordering point'
    RESET_WORKER_INDEX=$(action_index worker:reset-stock) || fail 'reset did not record the permanent-config mutation ordering point'
    (( CLEANUP_INDEX < RESET_WORKER_INDEX )) || fail 'reset mutated the permanent config before cleaning the discovered run-owned watchdog'
    (( WATCHDOG_INDEX < RESET_WORKER_INDEX )) || fail 'reset mutated the permanent config before proving the hardware watchdog ready'
    [[ " ${RESET_ACTIONS[*]} " == *' remote-worker:reboot-stock-reset '* ]] || fail 'reset fixture skipped permanent reboot'
    [[ " ${RESET_ACTIONS[*]} " == *' post-reboot-handshake '* ]] || fail 'reset fixture skipped post-reboot worker restoration'
    [[ ${APO_STATE[LAST_BOOT_ID]} == boot-after && ${APO_STATE[NORMAL_BOOT_ID]} == boot-after ]] || fail 'reset fixture skipped changed-boot proof'
    [[ " ${RESET_ACTIONS[*]} " == *' worker:verify-stock-reset '* ]] || fail 'reset fixture skipped post-reboot stock verification'
    FINAL_RESET_EVENT=${RESET_EVENTS[-1]}
    [[ $FINAL_RESET_EVENT == reset\|PASS\|* ]] || fail 'reset fixture did not emit a final reset PASS event'
    [[ ${FINAL_RESET_EVENT,,} == *verified*stock* ]] || fail 'reset PASS event did not state verified stock defaults'
    [[ $FINAL_RESET_EVENT == *"$RESET_BACKUP_FIXTURE"* ]] || fail 'reset PASS event did not report its backup path'
    [[ ${FINAL_RESET_EVENT,,} == *preserv* && ${FINAL_RESET_EVENT,,} == *log* && ${FINAL_RESET_EVENT,,} == *saved*run* ]] ||
        fail 'reset PASS event did not state that logs/saved runs were preserved'
    [[ ${FINAL_RESET_EVENT,,} == *no*longer*resumable* ]] ||
        fail 'reset PASS event did not state that earlier tuning checkpoints were retired'
    [[ " ${RESET_EVENTS[*]} " == *' reset-resume-retirement|INFO|'* ]] ||
        fail 'reset fixture did not record the resumable-run retirement event'
)

# A temporary-watchdog cleanup failure must stop reset before any permanent
# clock mutation. A stock/permanent watchdog has no installation run ID and is
# therefore a strict no-op in this cleanup phase.
CLEANUP_FAILURE_AUDIT="$TEST_ROOT/reset-watchdog-cleanup-failure"
set +e
APO_ROOT="$ROOT" CLEANUP_FAILURE_AUDIT="$CLEANUP_FAILURE_AUDIT" bash -c '
    set -Eeuo pipefail
    source "$APO_ROOT/lib/reset.sh"
    declare -Ag APO_STATE=() APO_DISCOVERY=(
        [NETWORK_WATCHDOG_INSTALL_RUN_ID]=older-run
    )
    APO_EXIT_RECOVERY=24
    APO_LAST_REASON=
    apo_state_set() { APO_STATE[$1]=${2-}; }
    apo_state_save() { printf "state:%s\n" "${APO_STATE[RESET_STATUS]:-}" >> "$CLEANUP_FAILURE_AUDIT"; }
    apo_event() { printf "event:%s\n" "$1" >> "$CLEANUP_FAILURE_AUDIT"; }
    apo_profile_cleanup_discovered_watchdog() {
        printf "cleanup\n" >> "$CLEANUP_FAILURE_AUDIT"
        APO_LAST_REASON="fixture ownership mismatch"
        return 1
    }
    apo_die() {
        printf "die:%s\n" "$1" >> "$CLEANUP_FAILURE_AUDIT"
        exit "$2"
    }
    apo_reset_cleanup_owned_watchdog
    printf "clock-mutation\n" >> "$CLEANUP_FAILURE_AUDIT"
' >/dev/null 2>&1
CLEANUP_FAILURE_RC=$?
set -e
(( CLEANUP_FAILURE_RC == 24 )) || fail 'watchdog cleanup failure returned the wrong reset status'
grep -Fqx cleanup "$CLEANUP_FAILURE_AUDIT" || fail 'watchdog cleanup failure fixture did not attempt cleanup'
grep -Fq 'No clock reset was attempted.' "$CLEANUP_FAILURE_AUDIT" || fail 'watchdog cleanup failure did not report the clock-mutation boundary'
if grep -Fqx clock-mutation "$CLEANUP_FAILURE_AUDIT"; then
    fail 'reset continued to a clock mutation after watchdog cleanup failed'
fi

APO_ROOT="$ROOT" bash -c '
    set -Eeuo pipefail
    source "$APO_ROOT/lib/reset.sh"
    declare -Ag APO_DISCOVERY=([NETWORK_WATCHDOG_INSTALL_RUN_ID]="")
    apo_profile_cleanup_discovered_watchdog() { exit 91; }
    apo_reset_cleanup_owned_watchdog
' || fail 'reset attempted to remove a stock or permanent watchdog without a run-owned provider'

MISSING_OWNER_AUDIT="$TEST_ROOT/reset-watchdog-missing-owner"
set +e
APO_ROOT="$ROOT" MISSING_OWNER_AUDIT="$MISSING_OWNER_AUDIT" bash -c '
    set -Eeuo pipefail
    source "$APO_ROOT/lib/reset.sh"
    declare -Ag APO_DISCOVERY=(
        [NETWORK_WATCHDOG_KIND]=debian-watchdog-observer
        [NETWORK_WATCHDOG_INSTALL_RUN_ID]=""
    )
    APO_EXIT_RECOVERY=24
    apo_die() {
        printf "%s\n" "$1" > "$MISSING_OWNER_AUDIT"
        exit "$2"
    }
    apo_profile_cleanup_discovered_watchdog() { exit 91; }
    apo_reset_cleanup_owned_watchdog
    printf "clock-mutation\n" >> "$MISSING_OWNER_AUDIT"
' >/dev/null 2>&1
MISSING_OWNER_RC=$?
set -e
(( MISSING_OWNER_RC == 24 )) || fail 'temporary watchdog without an installing run ID returned the wrong reset status'
grep -Fq 'without its installing run ID' "$MISSING_OWNER_AUDIT" || fail 'temporary watchdog without an installing run ID did not fail closed'
if grep -Fqx clock-mutation "$MISSING_OWNER_AUDIT"; then
    fail 'reset continued after finding a temporary watchdog without an installing run ID'
fi

WATCHDOG_NOT_READY_AUDIT="$TEST_ROOT/reset-watchdog-not-ready"
set +e
APO_ROOT="$ROOT" WATCHDOG_NOT_READY_AUDIT="$WATCHDOG_NOT_READY_AUDIT" bash -c '
    set -Eeuo pipefail
    source "$APO_ROOT/lib/reset.sh"
    APO_EXIT_RECOVERY=24
    apo_profile_watchdogs_ready() { return 1; }
    apo_profile_watchdog_description() { printf fixture-not-ready; }
    apo_die() {
        printf "%s\n" "$1" > "$WATCHDOG_NOT_READY_AUDIT"
        exit "$2"
    }
    apo_reset_verify_watchdog_ready
    printf "clock-mutation\n" >> "$WATCHDOG_NOT_READY_AUDIT"
' >/dev/null 2>&1
WATCHDOG_NOT_READY_RC=$?
set -e
(( WATCHDOG_NOT_READY_RC == 24 )) || fail 'unready stock watchdog returned the wrong reset status'
grep -Fq 'fixture-not-ready' "$WATCHDOG_NOT_READY_AUDIT" || fail 'unready stock watchdog did not report its profile state'
grep -Fq 'No clock reset was attempted.' "$WATCHDOG_NOT_READY_AUDIT" || fail 'unready stock watchdog did not report the clock-mutation boundary'
if grep -Fqx clock-mutation "$WATCHDOG_NOT_READY_AUDIT"; then
    fail 'reset continued after the stock hardware watchdog failed its pre-mutation proof'
fi

# Public prepare reuses the same protected reset transaction when a first-time
# target has explicit permanent tuning. Clean stock and completed-ledger
# baselines must remain no-op paths.
# shellcheck disable=SC2030,SC2031
(
    APO_ROOT=$ROOT
    # shellcheck source=lib/common.sh
    source "$ROOT/lib/common.sh"
    # shellcheck source=lib/config.sh
    source "$ROOT/lib/config.sh"
    # shellcheck source=lib/detect.sh
    source "$ROOT/lib/detect.sh"
    # shellcheck source=lib/reset.sh
    source "$ROOT/lib/reset.sh"
    declare -Ag APO_STATE=() APO_WORKER_DATA=() APO_DISCOVERY=() APO_CFG=([VOLTAGE_DELTA_UV]=0)
    declare -ag PREPARE_ACTIONS=() PREPARE_EVENTS=()
    PREPARE_OLD_HASH=$(printf 'a%.0s' {1..64})
    PREPARE_NEW_HASH=$(printf 'b%.0s' {1..64})
    PREPARE_LEDGER_HASH=$(printf 'c%.0s' {1..64})
    PREPARE_BACKUP=/var/lib/autopioverclock/backups/config-prepare-fixture.txt
    APO_AUTO_PREPARE=1
    APO_DRY_RUN=0
    APO_PROFILE=debian
    APO_RUN_ID=prepare-fixture-run
    APO_BOOT_CONFIG=/boot/firmware/config.txt
    APO_TRYBOOT_CONFIG=/boot/firmware/tryboot.txt
    APO_GPU_KEY=v3d_freq
    APO_NORMAL_CPU=2400
    APO_NORMAL_GPU=960
    APO_NORMAL_VOLTAGE=50000
    APO_PERMANENT_TUNING_PROVENANCE=explicit-override
    APO_PERMANENT_TUNING_EVIDENCE=over_voltage_delta,arm_freq
    APO_PERMANENT_CONFIG_HASH=$PREPARE_OLD_HASH
    APO_REMOTE_WORKER=/tmp/prepare-worker
    APO_BOOT_TIMEOUT=30
    APO_BOOT_SETTLE_SECONDS=0
    APO_LAST_CLASS=PASS
    APO_LAST_REASON='fixture pass'
    APO_LAST_WORKER_LOG=''
    APO_DISCOVERY_FILE="$TEST_ROOT/prepare-dry-discovery.txt"

    apo_state_set() { APO_STATE[$1]=${2-}; }
    apo_state_get() { printf '%s' "${APO_STATE[$1]:-${2-}}"; }
    apo_state_save() { PREPARE_ACTIONS+=(state-save); }
    apo_event() { PREPARE_EVENTS+=("$1|$2|${3-}|${4-}"); }
    apo_summary_line() { :; }
    apo_remote_boot_id() { printf prepare-boot-before; }
    apo_post_reboot_handshake() {
        [[ $1 == prepare-boot-before && $2 == 30 && $3 == prepare-stock-normalization ]]
        PREPARE_ACTIONS+=(post-reboot-handshake)
        APO_REBOOT_BOOT_ID=prepare-boot-after
        APO_REBOOT_HANDSHAKE_STAGE=complete
    }
    apo_remote_worker() { PREPARE_ACTIONS+=("remote-worker:$2"); return 0; }
    apo_run_worker_capture() {
        PREPARE_ACTIONS+=("worker:$2")
        APO_LAST_WORKER_LOG=$2
        APO_LAST_CLASS=PASS
        APO_LAST_REASON='fixture pass'
        return 0
    }
    apo_parse_data_file() {
        case $APO_LAST_WORKER_LOG in
            reset-stock)
                APO_WORKER_DATA=(
                    [RESET_BACKUP]="$PREPARE_BACKUP"
                    [RESET_TRYBOOT_BACKUP]=''
                    [RESET_OLD_HASH]="$PREPARE_OLD_HASH"
                    [RESET_NEW_HASH]="$PREPARE_NEW_HASH"
                    [RESET_DISABLED_KEYS]='over_voltage_delta,arm_freq'
                )
                ;;
            verify-stock-reset)
                APO_WORKER_DATA=(
                    [RESET_NEW_HASH]="$PREPARE_NEW_HASH"
                    [RESET_ACTIVE_CPU]=2400
                    [RESET_ACTIVE_GPU]=960
                    [RESET_ACTIVE_VOLTAGE]=0
                )
                ;;
        esac
    }
    apo_class_exit_code() { printf 1; }
    apo_die() { fail "unexpected prepare normalization abort: $1"; }
    sleep() { :; }

    apo_prepare_stock_baseline
    [[ ${APO_STATE[PREPARE_BASELINE_STATUS]} == VERIFIED ]] || fail 'prepare normalization did not finish VERIFIED'
    [[ ${APO_STATE[PREPARE_BASELINE_OLD_HASH]} == "$PREPARE_OLD_HASH" && ${APO_STATE[PREPARE_BASELINE_NEW_HASH]} == "$PREPARE_NEW_HASH" ]] ||
        fail 'prepare normalization did not bind its old/new hashes'
    [[ ${APO_STATE[PREPARE_BASELINE_BACKUP]} == "$PREPARE_BACKUP" ]] || fail 'prepare normalization did not retain its backup path'
    [[ ${APO_STATE[PREPARE_BASELINE_DISABLED_KEYS]} == over_voltage_delta,arm_freq ]] || fail 'prepare normalization did not retain its disabled keys'
    [[ ${APO_STATE[PREPARE_BASELINE_OLD_BOOT_ID]} == prepare-boot-before && ${APO_STATE[PREPARE_BASELINE_NEW_BOOT_ID]} == prepare-boot-after ]] ||
        fail 'prepare normalization did not prove a changed boot ID'
    [[ " ${PREPARE_ACTIONS[*]} " == *' worker:reset-stock '* && " ${PREPARE_ACTIONS[*]} " == *' worker:verify-stock-reset '* ]] ||
        fail 'prepare normalization skipped reset or verification workers'
    [[ " ${PREPARE_ACTIONS[*]} " == *' remote-worker:reboot-stock-reset '* ]] || fail 'prepare normalization skipped its stock reboot'
    [[ ${PREPARE_EVENTS[-1]} == prepare-stock-normalization\|PASS\|* ]] || fail 'prepare normalization did not emit PASS'

    PREPARE_ACTIONS=()
    APO_STATE=()
    APO_NORMAL_VOLTAGE=0
    APO_PERMANENT_TUNING_PROVENANCE=verified-default
    APO_PERMANENT_TUNING_EVIDENCE=none
    APO_PERMANENT_CONFIG_HASH=$PREPARE_NEW_HASH
    apo_prepare_stock_baseline
    [[ ${APO_STATE[PREPARE_BASELINE_STATUS]} == NOT_NEEDED ]] || fail 'clean-stock prepare did not select NOT_NEEDED'
    [[ " ${PREPARE_ACTIONS[*]} " != *' worker:'* && " ${PREPARE_ACTIONS[*]} " != *' remote-worker:'* ]] || fail 'clean-stock prepare mutated the target'

    PREPARE_ACTIONS=()
    APO_STATE=()
    APO_NORMAL_CPU=3050
    APO_NORMAL_GPU=1200
    APO_NORMAL_VOLTAGE=0
    APO_PERMANENT_TUNING_PROVENANCE=verified-completed-ledger
    APO_PERMANENT_TUNING_EVIDENCE="history-ledger-v3:$PREPARE_LEDGER_HASH"
    apo_prepare_stock_baseline
    [[ ${APO_STATE[PREPARE_BASELINE_STATUS]} == NOT_NEEDED ]] || fail 'completed-ledger prepare did not select NOT_NEEDED'
    [[ " ${PREPARE_ACTIONS[*]} " != *' worker:'* && " ${PREPARE_ACTIONS[*]} " != *' remote-worker:'* ]] || fail 'completed-ledger prepare reset the applied baseline'

    PREPARE_ACTIONS=()
    APO_STATE=()
    APO_DRY_RUN=1
    APO_PERMANENT_TUNING_PROVENANCE=explicit-override
    APO_PERMANENT_TUNING_EVIDENCE=over_voltage_delta,arm_freq
    apo_prepare_stock_baseline
    [[ ${#APO_STATE[@]} == 0 && ${#PREPARE_ACTIONS[@]} == 0 ]] || fail 'dry-run prepare normalization changed state or invoked a worker'

    PREPARE_ACTIONS=()
    APO_STATE=()
    APO_PROFILE=''
    apo_ssh_preflight() { PREPARE_ACTIONS+=(read:ssh-preflight); }
    apo_probe_profile() { printf debian; }
    apo_load_profile() { PREPARE_ACTIONS+=(read:profile); }
    apo_deploy_worker() { PREPARE_ACTIONS+=(mutation:deploy-worker); }
    apo_normalize_initial_boot() { PREPARE_ACTIONS+=(read:initial-boot); }
    apo_refresh_preparation_discovery() {
        PREPARE_ACTIONS+=(read:discovery)
        APO_MODE_EFFECTIVE=headless
        APO_BOOT_CONFIG=/boot/firmware/config.txt
        APO_TRYBOOT_CONFIG=/boot/firmware/tryboot.txt
        APO_INITIAL_TRYBOOT_EXISTS=0
        APO_INITIAL_TRYBOOT_TYPE=absent
        APO_INITIAL_TRYBOOT_HASH=unavailable
        APO_GPU_KEY=v3d_freq
        APO_NORMAL_CPU=2400
        APO_NORMAL_GPU=960
        APO_NORMAL_VOLTAGE=50000
        APO_PERMANENT_TUNING_PROVENANCE=explicit-override
        APO_PERMANENT_TUNING_EVIDENCE=over_voltage_delta,arm_freq
        APO_THROTTLE_BASELINE=throttled=0x0
        APO_THROTTLE_RECENT_SUPPORTED=1
        APO_PERMANENT_CONFIG_HASH=$PREPARE_OLD_HASH
        APO_STORAGE_LAYOUT='root=/dev/mmcblk0p2;boot=/dev/mmcblk0p1'
        APO_DISPLAY_BASELINE=''
        APO_AUDIO_BASELINE=''
        APO_TEST_VOLTAGE=0
        APO_REQUIRE_GPU_STRESS=0
    }
    apo_validate_preparation_runtime() { PREPARE_ACTIONS+=(read:runtime); }
    apo_dependency_preflight() { PREPARE_ACTIONS+=(read:dependencies); }
    apo_watchdog_preflight() { PREPARE_ACTIONS+=(read:watchdog); }
    apo_store_discovery_state() { PREPARE_ACTIONS+=(local:discovery-state); }
    apo_dependency_description() { printf fixture; }

    apo_prepare_target
    [[ ${APO_STATE[PREPARE_BASELINE_STATUS]} == WOULD_NORMALIZE ]] || fail 'public prepare dry-run did not report WOULD_NORMALIZE'
    [[ " ${PREPARE_ACTIONS[*]} " != *' mutation:'* ]] || fail 'public prepare dry-run reached a target mutation path'
    [[ " ${PREPARE_ACTIONS[*]} " == *' read:dependencies '* && " ${PREPARE_ACTIONS[*]} " == *' read:watchdog '* ]] ||
        fail 'public prepare dry-run skipped prerequisite inspection'
)

PREPARE_FAILURE_AUDIT="$TEST_ROOT/prepare-failure-audit"
set +e
APO_ROOT="$ROOT" PREPARE_FAILURE_AUDIT="$PREPARE_FAILURE_AUDIT" bash -c '
    set -Eeuo pipefail
    source "$APO_ROOT/lib/common.sh"
    source "$APO_ROOT/lib/reset.sh"
    declare -Ag APO_STATE=(
        [PREPARE_BASELINE_STATUS]=VERIFYING
        [PREPARE_BASELINE_BACKUP]=/var/lib/autopioverclock/backups/config-prepare-failure.txt
    )
    APO_AUTO_PREPARE=1
    apo_state_set() { APO_STATE[$1]=${2-}; }
    apo_state_get() { printf "%s" "${APO_STATE[$1]:-${2-}}"; }
    apo_state_save() {
        printf "%s|%s|%s\n" \
            "${APO_STATE[PREPARE_BASELINE_STATUS]:-}" \
            "${APO_STATE[PREPARE_BASELINE_FAILURE_CLASS]:-}" \
            "${APO_STATE[PREPARE_BASELINE_FAILURE_REASON]:-}" > "$PREPARE_FAILURE_AUDIT"
    }
    apo_reset_validation_fail "Post-reset verification fixture failed." RECOVERY_FAILURE "$APO_EXIT_RECOVERY"
' >/dev/null 2>&1
PREPARE_FAILURE_RC=$?
set -e
(( PREPARE_FAILURE_RC == 24 )) || fail 'prepare normalization validation failure returned the wrong status'
grep -Fqx 'FAILED|RECOVERY_FAILURE|Post-reset verification fixture failed. Backup: /var/lib/autopioverclock/backups/config-prepare-failure.txt.' "$PREPARE_FAILURE_AUDIT" ||
    fail 'prepare normalization validation failure was not durably classified with its backup path'

grep -Fq "ORIGIN_COMMAND '') == reset" "$ROOT/autopioverclock" || fail 'saved reset audits are not rejected by tuning-state commands'

printf 'test_reset: PASS\n'
