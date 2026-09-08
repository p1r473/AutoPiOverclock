#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2030,SC2031,SC2153
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

write_state_fixture() {
    local destination=$1 key value
    shift
    : > "$destination"
    while (( $# > 0 )); do
        key=$1
        value=$2
        shift 2
        printf '%s\t%s\n' "$key" "$(printf '%s' "$value" | base64 | tr -d '\n')" >> "$destination"
    done
}

set_stock_discovery_fixture() {
    APO_MODE_EFFECTIVE=headless
    APO_PROFILE=debian
    APO_DISCOVERY=(
        [BOOT_CONFIG]=/boot/firmware/config.txt
        [TRYBOOT_CONFIG]=/boot/firmware/tryboot.txt
        [TRYBOOT_EXISTS]=0
        [TRYBOOT_TYPE]=absent
        [TRYBOOT_HASH]=unavailable
        [BOOT_MOUNT]=/boot/firmware
        [GPU_KEY]=v3d_freq
        [NORMAL_CPU]=2400
        [NORMAL_GPU]=960
        [NORMAL_VOLTAGE]=0
        [PERMANENT_TUNING_PROVENANCE]=verified-default
        [PERMANENT_TUNING_EVIDENCE]=none
        [PERMANENT_HASH]=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    )
}

# Explicit resume of a saved public overclock must restore the original
# unattended reconnect and automatic-apply policy before any remote work.
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    APO_STATE=()
    apo_state_set ORIGIN_COMMAND overclock
    APO_PUBLIC_COMMAND=resume
    APO_AUTO_APPLY=0
    APO_PERSISTENT_SSH_RECOVERY=0
    apo_restore_saved_command_policy
    [[ $APO_PUBLIC_COMMAND == overclock ]]
    [[ $APO_AUTO_APPLY == 1 ]]
    [[ $APO_PERSISTENT_SSH_RECOVERY == 1 ]]
)
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    APO_STATE=()
    apo_state_set ORIGIN_COMMAND run
    APO_PUBLIC_COMMAND=''
    APO_AUTO_APPLY=0
    APO_PERSISTENT_SSH_RECOVERY=0
    apo_restore_saved_command_policy
    [[ -z $APO_PUBLIC_COMMAND ]]
    [[ $APO_AUTO_APPLY == 0 ]]
    [[ $APO_PERSISTENT_SSH_RECOVERY == 1 ]]
)
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    APO_PUBLIC_COMMAND=overclock
    APO_MUTATING_COMMAND=1
    APO_PERSISTENT_SSH_RECOVERY=1
    APO_BOOT_TIMEOUT=300
    APO_REMOTE_TARGET=root@tron
    PREPARE_ACTIONS=()
    apo_wait_for_ssh() { PREPARE_ACTIONS+=("wait:$1:$2"); }
    apo_ssh_preflight() { PREPARE_ACTIONS+=(preflight); }
    apo_deploy_worker() { PREPARE_ACTIONS+=(deploy); }
    apo_prepare_remote_for_saved_run
    [[ ${PREPARE_ACTIONS[*]} == 'wait:300:resume-connect preflight deploy' ]]
)

CONTINUATION_OUTPUT="$TEMP_DIR/continuation-output"
mkdir -p "$CONTINUATION_OUTPUT"
CONTINUATION_RUN=20260827-010203-abcdef0123456789
CONTINUATION_STATE="$CONTINUATION_OUTPUT/tron-${CONTINUATION_RUN}.state"
write_state_fixture "$CONTINUATION_STATE" \
    FORMAT_VERSION 1 RUN_SCHEMA 10 RUN_ID "$CONTINUATION_RUN" \
    REMOTE_TARGET "$(id -un)@tron" ORIGIN_COMMAND overclock \
    CFG_AUTO_GENERATED_CANDIDATES 1 CFG_SWEEP_DOMAIN all \
    CFG_CPU_MAX 3075 CFG_GPU_MAX 1175 CFG_CPU_MAX_REQUESTED '' CFG_GPU_MAX_REQUESTED '' CFG_USE_HISTORY 1 \
    STATUS INTERRUPTED PHASE CPU_SWEEP APPLY_STATUS NOT_APPLIED CFG_MAX_FAN 1 \
    CFG_QUALIFICATION_DURATION_S 10800 CFG_FINAL_DURATION_S 21600 \
    CFG_EDGE_DURATION_S 86400 CFG_DURATION_POLICY custom
ln -s "$(basename "$CONTINUATION_STATE")" "$CONTINUATION_OUTPUT/tron-latest.state"

# Plain overclock is always a fresh operation. Retained state is history input,
# never permission to replace the requested duration, bounds, or cooling plan.
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock tron --final-hours 100
    APO_OUTPUT_DIR=$CONTINUATION_OUTPUT
    apo_public_overclock_select_source
    [[ $APO_COMMAND == run ]]
    [[ -z $APO_SELECTED_RUN_ID && -z ${APO_STATE_FILE:-} && ${#APO_STATE[@]} == 0 ]]
    [[ $APO_AUTO_APPLY == 1 ]]
    [[ $APO_USE_HISTORY == 1 && $APO_FINAL_DURATION_S == 360000 ]]
)

# Exercise the complete fresh public planning path: CLI parsing and source
# selection preserve the requested duration, discovery invokes one history
# scan, and retained failures generate short near-ceiling ladders.
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock pi@hostname --final-hours 100
    APO_OUTPUT_DIR=$CONTINUATION_OUTPUT
    apo_public_overclock_select_source
    history_refresh_calls=0
    apo_history_refresh() {
        history_refresh_calls=$((history_refresh_calls + 1))
        APO_HISTORY_CPU_FAILURE_BOUNDARY=3100
        APO_HISTORY_GPU_FAILURE_BOUNDARY=1200
        APO_HISTORY_PAIR_FRONTIERS=''
        APO_HISTORY_PROVENANCE='CPU|3100|old-cpu-run|fixture|cpu.state,GPU|1200|old-gpu-run|fixture|gpu.state'
        APO_HISTORY_LEDGER_FILE="$TEMP_DIR/integration-failures.txt"
        APO_HISTORY_SCANNED_STATES=2
        APO_HISTORY_ACCEPTED_STATES=2
        APO_HISTORY_EVIDENCE_COUNT=2
    }
    apo_info() { :; }
    apo_summary_line() { :; }
    apo_config_load_for_new_run
    set_stock_discovery_fixture
    apo_context_from_discovery
    [[ $history_refresh_calls == 1 ]]
    [[ $APO_FINAL_DURATION_S == 360000 && ${APO_CFG[FINAL_DURATION_S]} == 360000 ]]
    [[ $APO_CPU_MIN == 2975 && $APO_CPU_MAX == 3075 ]]
    [[ $APO_GPU_MIN == 1125 && $APO_GPU_MAX == 1175 ]]
    [[ ${APO_CFG[CPU_CANDIDATES]} == 2975,3075 ]]
    [[ ${APO_CFG[GPU_CANDIDATES]} == 1125,1175 ]]
    [[ $(apo_state_get CFG_USE_HISTORY '') == 1 ]]
    [[ $(apo_state_get CFG_CPU_MIN_SOURCE '') == history ]]
    [[ $(apo_state_get CFG_GPU_MIN_SOURCE '') == history ]]
)

# --no-history follows the same fresh public path but performs no retained-state
# scan and rebuilds both complete automatic ladders from the stock baseline.
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock pi@hostname --no-history --final-hours 100
    APO_OUTPUT_DIR=$CONTINUATION_OUTPUT
    apo_public_overclock_select_source
    history_refresh_calls=0
    apo_history_refresh() {
        history_refresh_calls=$((history_refresh_calls + 1))
        return 99
    }
    apo_info() { :; }
    apo_summary_line() { :; }
    apo_config_load_for_new_run
    set_stock_discovery_fixture
    apo_context_from_discovery
    [[ $history_refresh_calls == 0 ]]
    [[ $APO_FINAL_DURATION_S == 360000 && ${APO_CFG[FINAL_DURATION_S]} == 360000 ]]
    [[ -z $APO_CPU_MIN && $APO_CPU_MAX == 3200 ]]
    [[ -z $APO_GPU_MIN && $APO_GPU_MAX == 1200 ]]
    [[ ${APO_CFG[CPU_CANDIDATES]} == 2500,2600,2700,2800,2900,3000,3100,3200 ]]
    [[ ${APO_CFG[GPU_CANDIDATES]} == 1000,1050,1100,1150,1200 ]]
    [[ $(apo_state_get CFG_USE_HISTORY '') == 0 ]]
    [[ $(apo_state_get CFG_CPU_MIN_SOURCE '') == automatic-baseline ]]
    [[ $(apo_state_get CFG_GPU_MIN_SOURCE '') == automatic-baseline ]]
)

# Only explicit resume selects saved progress; omitting --run-id selects latest.
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli resume tron
    APO_OUTPUT_DIR=$CONTINUATION_OUTPUT
    apo_public_overclock_select_source
    [[ $APO_COMMAND == resume && -z $APO_SELECTED_RUN_ID ]]
    [[ $(apo_find_state_file '') == "$CONTINUATION_STATE" ]]
)

# A different duration or fan policy describes a new run and is accepted.
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock tron --final-hours 8
    APO_OUTPUT_DIR=$CONTINUATION_OUTPUT
    apo_public_overclock_select_source
    [[ $APO_COMMAND == run && $APO_FINAL_DURATION_S == 28800 ]]
)
if (
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock tron --edge-cpu-24h
    APO_OUTPUT_DIR=$CONTINUATION_OUTPUT
    apo_public_overclock_select_source
) 2>"$TEMP_DIR/active-edge-change.err"; then
    echo 'an active ordinary run accepted a late immutable edge-plan change' >&2
    exit 1
fi
grep -Fq 'Unknown option: --edge-cpu-24h' "$TEMP_DIR/active-edge-change.err"
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock tron --no-max-fan
    APO_OUTPUT_DIR=$CONTINUATION_OUTPUT
    apo_public_overclock_select_source
    [[ $APO_COMMAND == run && $APO_MAX_FAN == 0 ]]
)

# A completed reset owns the latest-state pointer and forces a fresh all-domain
# overclock. An older interrupted run remains historical evidence but is never
# silently resumed across the reset boundary.
RESET_SHADOW_OUTPUT="$TEMP_DIR/reset-shadow-output"
mkdir -p "$RESET_SHADOW_OUTPUT"
RESET_SHADOW_OLD_RUN=20260906-010000-aaaaaaaaaaaaaaaa
RESET_SHADOW_OLD_STATE="$RESET_SHADOW_OUTPUT/tron-${RESET_SHADOW_OLD_RUN}.state"
write_state_fixture "$RESET_SHADOW_OLD_STATE" \
    FORMAT_VERSION 1 RUN_SCHEMA 10 RUN_ID "$RESET_SHADOW_OLD_RUN" \
    REMOTE_TARGET "$(id -un)@tron" ORIGIN_COMMAND overclock READ_ONLY_RUN 0 \
    CFG_AUTO_GENERATED_CANDIDATES 1 CFG_SWEEP_DOMAIN all CFG_USE_HISTORY 1 \
    STATUS INTERRUPTED PHASE CPU_SWEEP APPLY_STATUS NOT_APPLIED
RESET_SHADOW_RESET_RUN=20260906-020000-bbbbbbbbbbbbbbbb
RESET_SHADOW_RESET_STATE="$RESET_SHADOW_OUTPUT/tron-${RESET_SHADOW_RESET_RUN}.state"
write_state_fixture "$RESET_SHADOW_RESET_STATE" \
    FORMAT_VERSION 1 RUN_SCHEMA 10 RUN_ID "$RESET_SHADOW_RESET_RUN" \
    REMOTE_TARGET "$(id -un)@tron" ORIGIN_COMMAND reset READ_ONLY_RUN 0 \
    STATUS PASS PHASE COMPLETE SUBPHASE STOCK_VERIFIED
ln -s "$(basename "$RESET_SHADOW_RESET_STATE")" "$RESET_SHADOW_OUTPUT/tron-latest.state"
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock tron
    APO_OUTPUT_DIR=$RESET_SHADOW_OUTPUT
    apo_public_overclock_select_source
    [[ $APO_COMMAND == run ]]
    [[ -z $APO_SELECTED_RUN_ID && -z ${APO_STATE_FILE:-} && ${#APO_STATE[@]} == 0 ]]
)

# An explicit checkpoint restart may replace an untouched long-duration plan.
# The saved state supplies clocks; the command supplies only checkpoint/time.
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli resume tron --run-id "$CONTINUATION_RUN" --restart-from cpu-qualification --qualification-hours 2 --final-hours 24
    APO_OUTPUT_DIR=$CONTINUATION_OUTPUT
    apo_state_load "$CONTINUATION_STATE"
    APO_RESTART_QUALIFICATION_DURATION_S=$APO_QUALIFICATION_DURATION_S
    APO_RESTART_FINAL_DURATION_S=$APO_FINAL_DURATION_S
    APO_RESTART_EDGE_DURATION_S=$APO_EDGE_DURATION_S
    apo_restart_merge_unspecified_saved_durations
    [[ $APO_COMMAND == resume && $APO_SELECTED_RUN_ID == "$CONTINUATION_RUN" ]]
    [[ $APO_RESTART_FROM == cpu-qualification ]]
    [[ $APO_RESTART_QUALIFICATION_DURATION_S == 7200 && $APO_RESTART_FINAL_DURATION_S == 86400 ]]
    [[ $APO_RESTART_EDGE_DURATION_S == 86400 ]]
)
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli resume tron --run-id "$CONTINUATION_RUN" --restart-from cpu-qualification --final-hours 24
    APO_OUTPUT_DIR=$CONTINUATION_OUTPUT
    apo_state_load "$CONTINUATION_STATE"
    APO_RESTART_QUALIFICATION_DURATION_S=$APO_QUALIFICATION_DURATION_S
    APO_RESTART_FINAL_DURATION_S=$APO_FINAL_DURATION_S
    APO_RESTART_EDGE_DURATION_S=$APO_EDGE_DURATION_S
    apo_restart_merge_unspecified_saved_durations
    [[ $APO_RESTART_QUALIFICATION_DURATION_S == 10800 ]]
    [[ $APO_RESTART_FINAL_DURATION_S == 86400 ]]
    [[ $APO_RESTART_EDGE_DURATION_S == 86400 ]]
)

# A retained legacy edge run does not hijack a new public overclock operation.
EDGE_CONTINUATION_OUTPUT="$TEMP_DIR/edge-continuation-output"
mkdir -p "$EDGE_CONTINUATION_OUTPUT"
EDGE_CONTINUATION_RUN=20260827-010203-1111111111111111
EDGE_CONTINUATION_STATE="$EDGE_CONTINUATION_OUTPUT/tron-${EDGE_CONTINUATION_RUN}.state"
write_state_fixture "$EDGE_CONTINUATION_STATE" \
    FORMAT_VERSION 1 RUN_SCHEMA 10 RUN_ID "$EDGE_CONTINUATION_RUN" \
    REMOTE_TARGET "$(id -un)@tron" ORIGIN_COMMAND overclock \
    STATUS INTERRUPTED PHASE FINAL_VALIDATION APPLY_STATUS NOT_APPLIED CFG_MAX_FAN 1 \
    CFG_EDGE_CPU_24H 1 CFG_QUALIFICATION_DURATION_S 7200 CFG_FINAL_DURATION_S 28800 \
    CFG_EDGE_DURATION_S 43200 CFG_DURATION_POLICY custom
ln -s "$(basename "$EDGE_CONTINUATION_STATE")" "$EDGE_CONTINUATION_OUTPUT/tron-latest.state"
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock tron
    APO_OUTPUT_DIR=$EDGE_CONTINUATION_OUTPUT
    apo_public_overclock_select_source
    [[ $APO_COMMAND == run && $APO_EDGE_CPU_24H == 0 ]]
    [[ -z $APO_SELECTED_RUN_ID && -z ${APO_STATE_FILE:-} ]]
)
if (
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock tron --edge-cpu-24h
    APO_OUTPUT_DIR=$EDGE_CONTINUATION_OUTPUT
    apo_public_overclock_select_source
) 2>"$TEMP_DIR/edge-alias-duration-change.err"; then
    echo 'the literal 24-hour compatibility flag silently continued a 12-hour edge run' >&2
    exit 1
fi
grep -Fq 'Unknown option: --edge-cpu-24h' "$TEMP_DIR/edge-alias-duration-change.err"

# A domain-only run starts a new linked run only from a complete, applied,
# current-schema automatic result with clear tryboot ownership and stock lineage.
DOMAIN_SOURCE_OUTPUT="$TEMP_DIR/domain-source-output"
mkdir -p "$DOMAIN_SOURCE_OUTPUT"
DOMAIN_SOURCE_RUN=20260903-120000-0123456789abcdef
DOMAIN_SOURCE_STATE="$DOMAIN_SOURCE_OUTPUT/tron-${DOMAIN_SOURCE_RUN}.state"
write_state_fixture "$DOMAIN_SOURCE_STATE" \
    FORMAT_VERSION 1 RUN_SCHEMA 10 RUN_ID "$DOMAIN_SOURCE_RUN" \
    REMOTE_TARGET "$(id -un)@tron" ORIGIN_COMMAND overclock READ_ONLY_RUN 0 \
    PROFILE batocera BOOT_CONFIG /boot/config.txt TRYBOOT_CONFIG /boot/tryboot.txt GPU_KEY v3d_freq \
    CFG_AUTO_GENERATED_CANDIDATES 1 CFG_SWEEP_DOMAIN all \
    STATUS PASS PHASE COMPLETE FINAL_STAGE COMPLETE VALIDATED 1 VALIDATION_SCHEMA 8 \
    APPLY_STATUS APPLIED FINAL_CPU 2950 FINAL_GPU 1125 RECOMMENDED_CPU 2950 RECOMMENDED_GPU 1125 \
    FINAL_TARGET_CPU 2950 FINAL_TARGET_GPU 1125 NORMAL_CPU 2950 NORMAL_GPU 1125 \
    NORMAL_VOLTAGE 0 TEST_VOLTAGE 0 PERMANENT_HASH bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    APPLY_EXPECTED_HASH bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    AUTO_BASELINE_CPU 2400 AUTO_BASELINE_GPU 960 AUTO_BASELINE_VOLTAGE 0 \
    AUTO_BASELINE_PROVENANCE verified-default AUTO_BASELINE_EVIDENCE none \
    TRYBOOT_EXPECTED 0 TRYBOOT_FILE_MAY_EXIST 0 TRYBOOT_OWNED_HASH '' \
    TRYBOOT_RESERVATION_HASH '' TRYBOOT_OWNERSHIP_TOKEN '' TRYBOOT_QUARANTINE_PATH ''
ln -s "$(basename "$DOMAIN_SOURCE_STATE")" "$DOMAIN_SOURCE_OUTPUT/tron-latest.state"
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock tron --gpu-only --gpu-min 1150
    APO_OUTPUT_DIR=$DOMAIN_SOURCE_OUTPUT
    apo_public_overclock_select_source
    [[ $APO_COMMAND == run && $APO_SWEEP_DOMAIN == gpu ]]
    [[ $APO_DOMAIN_SOURCE_STATE == "$DOMAIN_SOURCE_STATE" ||
       $APO_DOMAIN_SOURCE_STATE == "$DOMAIN_SOURCE_OUTPUT/tron-latest.state" ]]
    [[ $APO_SOURCE_APPLIED_RUN_ID == "$DOMAIN_SOURCE_RUN" ]]
    [[ $APO_SOURCE_APPLIED_CPU == 2950 && $APO_SOURCE_APPLIED_GPU == 1125 ]]
    [[ $APO_SOURCE_APPLIED_PERMANENT_HASH == bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ]]
    [[ -z ${APO_STATE_FILE:-} && ${#APO_STATE[@]} == 0 ]]
)

# A later successful prepare audit must not hide the retained applied source
# merely because the user removed comments from the live permanent config. The
# selector binds the matching platform/clock tuple; discovery later performs
# the strict source-artifact/live-config comparison before any mutation.
for cleanup_case in comment-only project-zero-removed; do
    PREPARE_SOURCE_OUTPUT="$TEMP_DIR/domain-source-after-prepare-$cleanup_case"
    mkdir -p "$PREPARE_SOURCE_OUTPUT"
    cp "$DOMAIN_SOURCE_STATE" "$PREPARE_SOURCE_OUTPUT/$(basename "$DOMAIN_SOURCE_STATE")"
    case $cleanup_case in
        comment-only)
            PREPARE_RUN=20260904-120001-abcdef0123456789
            prepare_hash=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
            ;;
        project-zero-removed)
            PREPARE_RUN=20260904-120002-abcdef0123456789
            prepare_hash=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
            ;;
    esac
    PREPARE_STATE="$PREPARE_SOURCE_OUTPUT/tron-${PREPARE_RUN}.state"
    write_state_fixture "$PREPARE_STATE" \
        FORMAT_VERSION 1 RUN_SCHEMA 10 RUN_ID "$PREPARE_RUN" \
        REMOTE_TARGET "$(id -un)@tron" ORIGIN_COMMAND prepare READ_ONLY_RUN 1 \
        PROFILE batocera BOOT_CONFIG /boot/config.txt TRYBOOT_CONFIG /boot/tryboot.txt GPU_KEY v3d_freq \
        STATUS PASS PHASE COMPLETE NORMAL_CPU 2950 NORMAL_GPU 1125 NORMAL_VOLTAGE 0 \
        PERMANENT_HASH "$prepare_hash"

    # Retained artifact directories can contain many unrelated audits. Their
    # unneeded payloads must not be decoded merely to find the matching applied
    # source. These deliberately malformed, irrelevant values prove that the
    # metadata screen skips them while the selected source still receives a
    # complete strict load below.
    for distractor_index in {01..40}; do
        distractor_state="$PREPARE_SOURCE_OUTPUT/tron-20260904-13${distractor_index}00-deadbeef${distractor_index}00.state"
        write_state_fixture "$distractor_state" \
            FORMAT_VERSION 1 RUN_SCHEMA 10 RUN_ID "20260904-13${distractor_index}00-deadbeef${distractor_index}00" \
            REMOTE_TARGET "$(id -un)@tron" ORIGIN_COMMAND reset READ_ONLY_RUN 0 \
            STATUS PASS PHASE COMPLETE
        printf 'IRRELEVANT_BROKEN_VALUE\t%%%s\n' "$distractor_index" >> "$distractor_state"
    done
    ln -s "$(basename "$PREPARE_STATE")" "$PREPARE_SOURCE_OUTPUT/tron-latest.state"
    (
        export APO_CLI_LIBRARY_ONLY=1
        source "$ROOT/autopioverclock"
        apo_parse_cli overclock tron --gpu-only --gpu-min 1150
        APO_OUTPUT_DIR=$PREPARE_SOURCE_OUTPUT
        apo_public_overclock_select_source
        [[ $APO_COMMAND == run && $APO_SWEEP_DOMAIN == gpu ]]
        [[ $APO_DOMAIN_SOURCE_STATE == "$PREPARE_SOURCE_OUTPUT/$(basename "$DOMAIN_SOURCE_STATE")" ]]
        [[ $APO_SOURCE_APPLIED_RUN_ID == "$DOMAIN_SOURCE_RUN" ]]
        [[ $APO_SOURCE_APPLIED_CPU == 2950 && $APO_SOURCE_APPLIED_GPU == 1125 ]]
    )
done

# A successful restore audit is bound to its exact validated source run and
# hash.  A newer applied result with the same clocks but different bytes must
# not replace that lineage merely because it sorts later in the directory.
RESTORE_SOURCE_OUTPUT="$TEMP_DIR/domain-source-after-restore"
mkdir -p "$RESTORE_SOURCE_OUTPUT"
cp "$DOMAIN_SOURCE_STATE" "$RESTORE_SOURCE_OUTPUT/$(basename "$DOMAIN_SOURCE_STATE")"
RESTORE_DISTRACTOR_RUN=20260903-130000-1122334455667788
RESTORE_DISTRACTOR_STATE="$RESTORE_SOURCE_OUTPUT/tron-${RESTORE_DISTRACTOR_RUN}.state"
write_state_fixture "$RESTORE_DISTRACTOR_STATE" \
    FORMAT_VERSION 1 RUN_SCHEMA 10 RUN_ID "$RESTORE_DISTRACTOR_RUN" \
    REMOTE_TARGET "$(id -un)@tron" ORIGIN_COMMAND overclock READ_ONLY_RUN 0 \
    PROFILE batocera BOOT_CONFIG /boot/config.txt TRYBOOT_CONFIG /boot/tryboot.txt GPU_KEY v3d_freq \
    CFG_AUTO_GENERATED_CANDIDATES 1 CFG_SWEEP_DOMAIN all \
    STATUS PASS PHASE COMPLETE FINAL_STAGE COMPLETE VALIDATED 1 VALIDATION_SCHEMA 8 \
    APPLY_STATUS APPLIED FINAL_CPU 2950 FINAL_GPU 1125 RECOMMENDED_CPU 2950 RECOMMENDED_GPU 1125 \
    FINAL_TARGET_CPU 2950 FINAL_TARGET_GPU 1125 NORMAL_CPU 2950 NORMAL_GPU 1125 \
    NORMAL_VOLTAGE 0 TEST_VOLTAGE 0 PERMANENT_HASH aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    APPLY_EXPECTED_HASH aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    AUTO_BASELINE_CPU 2400 AUTO_BASELINE_GPU 960 AUTO_BASELINE_VOLTAGE 0 \
    AUTO_BASELINE_PROVENANCE verified-default AUTO_BASELINE_EVIDENCE none \
    TRYBOOT_EXPECTED 0 TRYBOOT_FILE_MAY_EXIST 0 TRYBOOT_OWNED_HASH '' \
    TRYBOOT_RESERVATION_HASH '' TRYBOOT_OWNERSHIP_TOKEN '' TRYBOOT_QUARANTINE_PATH ''
RESTORE_AUDIT_RUN=20260904-120003-aabbccddeeff0011
RESTORE_AUDIT_STATE="$RESTORE_SOURCE_OUTPUT/tron-${RESTORE_AUDIT_RUN}.state"
write_state_fixture "$RESTORE_AUDIT_STATE" \
    FORMAT_VERSION 1 RUN_SCHEMA 10 RUN_ID "$RESTORE_AUDIT_RUN" \
    REMOTE_TARGET "$(id -un)@tron" ORIGIN_COMMAND restore READ_ONLY_RUN 0 \
    PROFILE batocera BOOT_CONFIG /boot/config.txt TRYBOOT_CONFIG /boot/tryboot.txt GPU_KEY v3d_freq \
    STATUS PASS PHASE COMPLETE NORMAL_CPU 2950 NORMAL_GPU 1125 NORMAL_VOLTAGE 0 \
    PERMANENT_HASH bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    RESTORE_SOURCE_RUN_ID "$DOMAIN_SOURCE_RUN" \
    RESTORE_SOURCE_HASH bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
ln -s "$(basename "$RESTORE_AUDIT_STATE")" "$RESTORE_SOURCE_OUTPUT/tron-latest.state"
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock tron --gpu-only --gpu-min 1150
    APO_OUTPUT_DIR=$RESTORE_SOURCE_OUTPUT
    apo_public_overclock_select_source
    [[ $APO_COMMAND == run && -z $APO_SELECTED_RUN_ID ]]
    [[ $APO_SOURCE_APPLIED_RUN_ID == "$DOMAIN_SOURCE_RUN" ]]
    [[ $APO_SOURCE_APPLIED_PERMANENT_HASH == bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ]]
)

# A prepare audit whose bytes match neither of two otherwise compatible applied
# configurations is ambiguous and must not guess which one is active.
PREPARE_AMBIGUOUS_OUTPUT="$TEMP_DIR/domain-source-after-ambiguous-prepare"
mkdir -p "$PREPARE_AMBIGUOUS_OUTPUT"
cp "$DOMAIN_SOURCE_STATE" "$PREPARE_AMBIGUOUS_OUTPUT/$(basename "$DOMAIN_SOURCE_STATE")"
cp "$RESTORE_DISTRACTOR_STATE" "$PREPARE_AMBIGUOUS_OUTPUT/$(basename "$RESTORE_DISTRACTOR_STATE")"
PREPARE_AMBIGUOUS_RUN=20260904-120004-bbccddeeff001122
PREPARE_AMBIGUOUS_STATE="$PREPARE_AMBIGUOUS_OUTPUT/tron-${PREPARE_AMBIGUOUS_RUN}.state"
write_state_fixture "$PREPARE_AMBIGUOUS_STATE" \
    FORMAT_VERSION 1 RUN_SCHEMA 10 RUN_ID "$PREPARE_AMBIGUOUS_RUN" \
    REMOTE_TARGET "$(id -un)@tron" ORIGIN_COMMAND prepare READ_ONLY_RUN 1 \
    PROFILE batocera BOOT_CONFIG /boot/config.txt TRYBOOT_CONFIG /boot/tryboot.txt GPU_KEY v3d_freq \
    STATUS PASS PHASE COMPLETE NORMAL_CPU 2950 NORMAL_GPU 1125 NORMAL_VOLTAGE 0 \
    PERMANENT_HASH cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
ln -s "$(basename "$PREPARE_AMBIGUOUS_STATE")" "$PREPARE_AMBIGUOUS_OUTPUT/tron-latest.state"
if (
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock tron --gpu-only --gpu-min 1150
    APO_OUTPUT_DIR=$PREPARE_AMBIGUOUS_OUTPUT
    apo_public_overclock_select_source
) >"$TEMP_DIR/domain-prepare-ambiguous.out" 2>&1; then
    echo 'an ambiguous prepare audit silently selected one of two different applied configs' >&2
    exit 1
fi
grep -Fq 'matches multiple applied configurations with different hashes' "$TEMP_DIR/domain-prepare-ambiguous.out"

# A fresh one-domain command behind a prepare audit selects the independently
# eligible APPLIED source, never the interrupted one-domain run. Explicit
# resume remains the only continuation path.
PREPARE_REPEAT_OUTPUT="$TEMP_DIR/domain-repeat-after-prepare"
mkdir -p "$PREPARE_REPEAT_OUTPUT"
cp "$DOMAIN_SOURCE_STATE" "$PREPARE_REPEAT_OUTPUT/$(basename "$DOMAIN_SOURCE_STATE")"
DOMAIN_REPEAT_RUN=20260904-140000-0011223344556677
DOMAIN_REPEAT_STATE="$PREPARE_REPEAT_OUTPUT/tron-${DOMAIN_REPEAT_RUN}.state"
write_state_fixture "$DOMAIN_REPEAT_STATE" \
    FORMAT_VERSION 1 RUN_SCHEMA 10 RUN_ID "$DOMAIN_REPEAT_RUN" \
    REMOTE_TARGET "$(id -un)@tron" ORIGIN_COMMAND overclock READ_ONLY_RUN 0 \
    PROFILE batocera BOOT_CONFIG /boot/config.txt TRYBOOT_CONFIG /boot/tryboot.txt GPU_KEY v3d_freq \
    CFG_AUTO_GENERATED_CANDIDATES 1 CFG_SWEEP_DOMAIN gpu CFG_CPU_MIN '' CFG_GPU_MIN 1150 CFG_CPU_MAX '' CFG_GPU_MAX '' CFG_USE_HISTORY 1 \
    CFG_MAX_FAN 1 CFG_EDGE_CPU_24H 0 CFG_EDGE_ORDER floor-first \
    CFG_QUALIFICATION_DURATION_S 7200 CFG_FINAL_DURATION_S 86400 \
    CFG_EDGE_DURATION_S 86400 CFG_DURATION_POLICY default \
    STATUS INTERRUPTED PHASE GPU_SWEEP APPLY_STATUS NOT_APPLIED \
    NORMAL_CPU 2950 NORMAL_GPU 1125 NORMAL_VOLTAGE 0 \
    PERMANENT_HASH ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
PREPARE_REPEAT_RUN=20260904-150000-8899aabbccddeeff
PREPARE_REPEAT_STATE="$PREPARE_REPEAT_OUTPUT/tron-${PREPARE_REPEAT_RUN}.state"
write_state_fixture "$PREPARE_REPEAT_STATE" \
    FORMAT_VERSION 1 RUN_SCHEMA 10 RUN_ID "$PREPARE_REPEAT_RUN" \
    REMOTE_TARGET "$(id -un)@tron" ORIGIN_COMMAND prepare READ_ONLY_RUN 1 \
    PROFILE batocera BOOT_CONFIG /boot/config.txt TRYBOOT_CONFIG /boot/tryboot.txt GPU_KEY v3d_freq \
    STATUS PASS PHASE COMPLETE NORMAL_CPU 2950 NORMAL_GPU 1125 NORMAL_VOLTAGE 0 \
    PERMANENT_HASH ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
ln -s "$(basename "$PREPARE_REPEAT_STATE")" "$PREPARE_REPEAT_OUTPUT/tron-latest.state"
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock tron --gpu-only --gpu-min 1150
    APO_OUTPUT_DIR=$PREPARE_REPEAT_OUTPUT
    apo_public_overclock_select_source
    [[ $APO_COMMAND == run && -z $APO_SELECTED_RUN_ID ]]
    [[ $APO_SOURCE_APPLIED_RUN_ID == "$DOMAIN_SOURCE_RUN" ]]
    [[ $APO_SWEEP_DOMAIN == gpu && $APO_GPU_MIN == 1150 ]]
    [[ $APO_QUALIFICATION_DURATION_S == 7200 && $APO_FINAL_DURATION_S == 172800 ]]
)

# A hash-mismatched fallback is never inferred across a different boot path.
PREPARE_MISMATCH_OUTPUT="$TEMP_DIR/domain-source-after-prepare-path-mismatch"
mkdir -p "$PREPARE_MISMATCH_OUTPUT"
cp "$DOMAIN_SOURCE_STATE" "$PREPARE_MISMATCH_OUTPUT/$(basename "$DOMAIN_SOURCE_STATE")"
PREPARE_MISMATCH_RUN=20260904-130000-fedcba9876543210
PREPARE_MISMATCH_STATE="$PREPARE_MISMATCH_OUTPUT/tron-${PREPARE_MISMATCH_RUN}.state"
write_state_fixture "$PREPARE_MISMATCH_STATE" \
    FORMAT_VERSION 1 RUN_SCHEMA 10 RUN_ID "$PREPARE_MISMATCH_RUN" \
    REMOTE_TARGET "$(id -un)@tron" ORIGIN_COMMAND prepare READ_ONLY_RUN 1 \
    PROFILE batocera BOOT_CONFIG /boot/other-config.txt TRYBOOT_CONFIG /boot/tryboot.txt GPU_KEY v3d_freq \
    STATUS PASS PHASE COMPLETE NORMAL_CPU 2950 NORMAL_GPU 1125 NORMAL_VOLTAGE 0 \
    PERMANENT_HASH eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
ln -s "$(basename "$PREPARE_MISMATCH_STATE")" "$PREPARE_MISMATCH_OUTPUT/tron-latest.state"
if (
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock tron --gpu-only --gpu-min 1150
    APO_OUTPUT_DIR=$PREPARE_MISMATCH_OUTPUT
    apo_public_overclock_select_source
) >"$TEMP_DIR/domain-prepare-path-mismatch.out" 2>&1; then
    echo 'a latest prepare audit selected an applied source across different boot paths' >&2
    exit 1
fi
grep -Fq 'latest host-baseline audit does not match any retained applied result' "$TEMP_DIR/domain-prepare-path-mismatch.out"

if (
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock tron --cpu-only
    APO_OUTPUT_DIR=$TEMP_DIR/no-domain-source-output
    mkdir -p "$APO_OUTPUT_DIR"
    apo_public_overclock_select_source
) >/dev/null 2>&1; then
    echo 'CPU-only tuning started without a retained applied source' >&2
    exit 1
fi

# A checkpoint restart is explicit resume syntax. Main later loads and verifies
# the selected applied state before it creates a linked longer final validation.
FINAL_EXTENSION_OUTPUT="$TEMP_DIR/final-extension-output"
mkdir -p "$FINAL_EXTENSION_OUTPUT"
FINAL_EXTENSION_SOURCE=20260829-223837-7b9716f361ef9804
FINAL_EXTENSION_STATE="$FINAL_EXTENSION_OUTPUT/monkeebutt-${FINAL_EXTENSION_SOURCE}.state"
write_state_fixture "$FINAL_EXTENSION_STATE" \
    FORMAT_VERSION 1 RUN_SCHEMA 10 RUN_ID "$FINAL_EXTENSION_SOURCE" \
    REMOTE_TARGET "$(id -un)@monkeebutt" ORIGIN_COMMAND overclock READ_ONLY_RUN 0 PROFILE debian \
    MODE_EFFECTIVE headless REQUIRE_GPU_STRESS 1 CFG_AUTO_GENERATED_CANDIDATES 1 \
    CFG_EDGE_CPU_24H 1 CFG_EDGE_ORDER floor-first CFG_QUALIFICATION_DURATION_S 7200 \
    CFG_FINAL_DURATION_S 28800 CFG_EDGE_DURATION_S 86400 CFG_DURATION_POLICY default \
    STATUS PASS PHASE COMPLETE FINAL_STAGE COMPLETE VALIDATED 1 VALIDATION_SCHEMA 8 \
    VALIDATION_DURATION_S 28800 APPLY_STATUS APPLIED EDGE_CPU_STATUS REJECTED \
    FLOOR_CPU 3100 FLOOR_GPU 1175 FLOOR_DURATION_S 28800 FLOOR_VALIDATION_SCHEMA 8 FLOOR_VALIDATED 1 \
    FINAL_CPU 3100 FINAL_GPU 1175 RECOMMENDED_CPU 3100 RECOMMENDED_GPU 1175 \
    FINAL_TARGET_CPU 3100 FINAL_TARGET_GPU 1175 NORMAL_CPU 3100 NORMAL_GPU 1175 \
    NORMAL_VOLTAGE 0 TEST_VOLTAGE 0 TRYBOOT_EXPECTED 0 TRYBOOT_FILE_MAY_EXIST 0 \
    APPLY_OLD_HASH aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    APPLY_EXPECTED_HASH bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    PERMANENT_HASH bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    APPLY_BACKUP "/var/lib/autopioverclock/backups/config-${FINAL_EXTENSION_SOURCE}-before-apply.txt"
ln -sfn "$(basename "$FINAL_EXTENSION_STATE")" "$FINAL_EXTENSION_OUTPUT/monkeebutt-latest.state"
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli resume monkeebutt --run-id "$FINAL_EXTENSION_SOURCE" --restart-from final --final-hours 24
    APO_OUTPUT_DIR=$FINAL_EXTENSION_OUTPUT
    apo_public_overclock_select_source
    [[ $APO_COMMAND == resume && $APO_SELECTED_RUN_ID == "$FINAL_EXTENSION_SOURCE" ]]
    [[ $APO_RESTART_FROM == final && $APO_FINAL_DURATION_S == 86400 ]]
)

# A direct resume of the exact linked-run failure reported by hardware performs
# a fresh stock health proof, schedules conservative pair backoff, and returns
# to the tuning loop instead of immediately returning the stability exit code.
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    ACTIONS=()
    APO_AUTO_APPLY=1
    APO_STATE=()
    apo_state_set RUN_SCHEMA "$APO_CURRENT_RUN_SCHEMA"
    apo_state_set RUN_ID 20260831-131319-3333333333333333
    apo_state_set POST_FLOOR_FINAL 1
    apo_state_set POST_FLOOR_FINAL_STAGE FAILED
    apo_state_set SOURCE_FINAL_RUN_ID "$FINAL_EXTENSION_SOURCE"
    apo_state_set SOURCE_FINAL_PERMANENT_HASH aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    apo_state_set SOURCE_FINAL_VALIDATION_DURATION_S 28800
    apo_state_set SOURCE_FINAL_APPLY_BACKUP /var/lib/autopioverclock/backups/source-before-apply.txt
    apo_state_set FINAL_TARGET_CPU 3100
    apo_state_set FINAL_TARGET_GPU 1175
    apo_state_set FINAL_STAGE ENDURANCE
    apo_state_set STATUS FAILED
    apo_state_set PHASE FINAL_VALIDATION
    apo_state_set FAILURE_CLASS STABILITY_FAILURE
    apo_state_set FAILURE_REASON 'verified autonomous combined-endurance reboot'
    apo_state_set APPLY_STATUS NOT_APPLIED
    apo_validate_auto_resume_state() { ACTIONS+=(validate); }
    apo_final_saved_failure_is_retryable() { return 0; }
    apo_prepare_remote_for_saved_run() { ACTIONS+=(prepare); }
    apo_recover_normal() { ACTIONS+=("recover:$1"); }
    apo_post_floor_final_schedule_stress_backoff() {
        ACTIONS+=("backoff:$1:$2")
        apo_state_set POST_FLOOR_FINAL_STAGE BACKOFF_TUNING
        apo_state_set STATUS RUNNING
        apo_state_set PHASE CPU_QUALIFICATION
        apo_state_set FAILURE_CLASS ''
        apo_state_set FAILURE_REASON ''
    }
    apo_run_tuning() {
        ACTIONS+=(tuning)
        apo_state_set STATUS PASS
        apo_state_set PHASE COMPLETE
    }
    apo_finish_public_overclock() {
        ACTIONS+=(finish)
        apo_state_set APPLY_STATUS APPLIED
    }
    apo_state_save() { ACTIONS+=(save); }
    apo_resume_post_floor_final
    [[ " ${ACTIONS[*]} " == *' validate prepare recover:post-floor-final-backoff-recovery backoff:ENDURANCE:STABILITY_FAILURE tuning finish '* ]]
    [[ $(apo_state_get POST_FLOOR_FINAL_STAGE) == COMPLETE ]]
)

# Recovered failures remain retained history but never turn a fresh public
# overclock into an implicit resume.
FAILED_FINAL_RUN=20260827-010203-fedcba9876543210
FAILED_FINAL_STATE="$CONTINUATION_OUTPUT/tron-${FAILED_FINAL_RUN}.state"
write_state_fixture "$FAILED_FINAL_STATE" \
    FORMAT_VERSION 1 RUN_SCHEMA 7 RUN_ID "$FAILED_FINAL_RUN" \
    REMOTE_TARGET "$(id -un)@tron" ORIGIN_COMMAND overclock \
    CFG_AUTO_GENERATED_CANDIDATES 1 STATUS FAILED PHASE FINAL_VALIDATION \
    FAILURE_CLASS STABILITY_FAILURE FAILURE_REASON 'verified autonomous GPU stress reboot' \
    FINAL_STAGE GPU_STRESS RECOMMENDED_CPU 3000 RECOMMENDED_GPU 1175 \
    FINAL_TARGET_CPU 3000 FINAL_TARGET_GPU 1175 EDGE_CPU_STATUS NOT_REQUESTED \
    FLOOR_VALIDATED 0 TRYBOOT_EXPECTED 0 TRYBOOT_FILE_MAY_EXIST 0 APPLY_STATUS NOT_APPLIED
ln -sfn "$(basename "$FAILED_FINAL_STATE")" "$CONTINUATION_OUTPUT/tron-latest.state"
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock tron
    APO_OUTPUT_DIR=$CONTINUATION_OUTPUT
    apo_public_overclock_select_source
    [[ $APO_COMMAND == run && -z $APO_SELECTED_RUN_ID ]]
)

# A retryable saved boot/health handoff likewise requires explicit resume.
FAILED_BOOT_HANDOFF_RUN=20260831-200735-4444444444444444
FAILED_BOOT_HANDOFF_STATE="$CONTINUATION_OUTPUT/tron-${FAILED_BOOT_HANDOFF_RUN}.state"
write_state_fixture "$FAILED_BOOT_HANDOFF_STATE" \
    FORMAT_VERSION 1 RUN_SCHEMA 10 RUN_ID "$FAILED_BOOT_HANDOFF_RUN" \
    REMOTE_TARGET "$(id -un)@tron" ORIGIN_COMMAND overclock \
    CFG_AUTO_GENERATED_CANDIDATES 1 CFG_EDGE_CPU_24H 1 \
    CFG_QUALIFICATION_DURATION_S 7200 CFG_FINAL_DURATION_S 86400 \
    CFG_EDGE_DURATION_S 86400 CFG_DURATION_POLICY default \
    STATUS FAILED PHASE CPU_SWEEP \
    FAILURE_CLASS HARNESS_FAILURE FAILURE_REASON 'The worker failed without a structured result.' \
    CANDIDATE_LABEL cpu-3000_gpu-960 CANDIDATE_CPU 3000 CANDIDATE_GPU 960 \
    CANDIDATE_STAGE STRESS_BOOT TRYBOOT_EXPECTED 0 TRYBOOT_FILE_MAY_EXIST 0 \
    APPLY_STATUS NOT_APPLIED TRANSIENT_RETRY_COUNT 0
ln -sfn "$(basename "$FAILED_BOOT_HANDOFF_STATE")" "$CONTINUATION_OUTPUT/tron-latest.state"
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock tron
    APO_OUTPUT_DIR=$CONTINUATION_OUTPUT
    apo_public_overclock_select_source
    [[ $APO_COMMAND == run && -z $APO_SELECTED_RUN_ID ]]
)

# A recovered clean early-exit state remains available to explicit resume only.
FAILED_CLEAN_EARLY_RUN=20260901-125438-5555555555555555
FAILED_CLEAN_EARLY_STATE="$CONTINUATION_OUTPUT/tron-${FAILED_CLEAN_EARLY_RUN}.state"
write_state_fixture "$FAILED_CLEAN_EARLY_STATE" \
    FORMAT_VERSION 1 RUN_SCHEMA 10 RUN_ID "$FAILED_CLEAN_EARLY_RUN" \
    REMOTE_TARGET "$(id -un)@tron" ORIGIN_COMMAND overclock \
    CFG_AUTO_GENERATED_CANDIDATES 1 CFG_EDGE_CPU_24H 1 \
    CFG_QUALIFICATION_DURATION_S 7200 CFG_FINAL_DURATION_S 86400 \
    CFG_EDGE_DURATION_S 86400 CFG_DURATION_POLICY default \
    STATUS FAILED PHASE FINAL_VALIDATION \
    FAILURE_CLASS HARNESS_FAILURE FAILURE_REASON 'CPU stress exited early with rc=0.' \
    FINAL_STAGE ENDURANCE FINAL_TARGET_CPU 3000 FINAL_TARGET_GPU 1150 \
    RECOMMENDED_CPU 2975 RECOMMENDED_GPU 1150 EDGE_CPU_STATUS RUNNING \
    TRYBOOT_EXPECTED 0 TRYBOOT_FILE_MAY_EXIST 0 APPLY_STATUS NOT_APPLIED \
    TRANSIENT_RETRY_COUNT 0
ln -sfn "$(basename "$FAILED_CLEAN_EARLY_STATE")" "$CONTINUATION_OUTPUT/tron-latest.state"
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock tron
    APO_OUTPUT_DIR=$CONTINUATION_OUTPUT
    apo_public_overclock_select_source
    [[ $APO_COMMAND == run && -z $APO_SELECTED_RUN_ID ]]
)

# A transient permanent-hash read failure also cannot hijack a new operation.
FAILED_HASH_READ_RUN=20260901-182253-6666666666666666
FAILED_HASH_READ_STATE="$CONTINUATION_OUTPUT/monkeebutt-${FAILED_HASH_READ_RUN}.state"
write_state_fixture "$FAILED_HASH_READ_STATE" \
    FORMAT_VERSION 1 RUN_SCHEMA 10 RUN_ID "$FAILED_HASH_READ_RUN" \
    REMOTE_TARGET "$(id -un)@monkeebutt" ORIGIN_COMMAND overclock \
    CFG_AUTO_GENERATED_CANDIDATES 1 CFG_EDGE_CPU_24H 1 \
    CFG_QUALIFICATION_DURATION_S 7200 CFG_FINAL_DURATION_S 86400 \
    CFG_EDGE_DURATION_S 86400 CFG_DURATION_POLICY default \
    STATUS FAILED PHASE CPU_SWEEP \
    FAILURE_CLASS RECOVERY_FAILURE \
    FAILURE_REASON 'Permanent config hash is unavailable in cpu-refine-3150_gpu-960-candidate-post-stress; the target did not return readable hash evidence.' \
    CANDIDATE_LABEL cpu-refine-3150_gpu-960 CANDIDATE_CPU 3150 CANDIDATE_GPU 960 \
    CANDIDATE_STAGE STRESS TRYBOOT_EXPECTED 0 TRYBOOT_FILE_MAY_EXIST 0 \
    APPLY_STATUS NOT_APPLIED TRANSIENT_RETRY_COUNT 0
ln -sfn "$(basename "$FAILED_HASH_READ_STATE")" "$CONTINUATION_OUTPUT/monkeebutt-latest.state"
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock monkeebutt
    APO_OUTPUT_DIR=$CONTINUATION_OUTPUT
    apo_public_overclock_select_source
    [[ $APO_COMMAND == run && -z $APO_SELECTED_RUN_ID ]]
)

apo_failed_harness_run=20260827-010203-1111111111111111
apo_failed_harness_state="$CONTINUATION_OUTPUT/tron-${apo_failed_harness_run}.state"
write_state_fixture "$apo_failed_harness_state" \
    FORMAT_VERSION 1 RUN_SCHEMA 7 RUN_ID "$apo_failed_harness_run" \
    REMOTE_TARGET "$(id -un)@tron" ORIGIN_COMMAND overclock \
    CFG_AUTO_GENERATED_CANDIDATES 1 STATUS FAILED PHASE FINAL_VALIDATION \
    FAILURE_CLASS HARNESS_FAILURE FAILURE_REASON 'same-boot transport loss' \
    FINAL_STAGE GPU_STRESS RECOMMENDED_CPU 3000 RECOMMENDED_GPU 1175 \
    FINAL_TARGET_CPU 3000 FINAL_TARGET_GPU 1175 EDGE_CPU_STATUS NOT_REQUESTED \
    FLOOR_VALIDATED 0 TRYBOOT_EXPECTED 0 TRYBOOT_FILE_MAY_EXIST 0 APPLY_STATUS NOT_APPLIED
ln -sfn "$(basename "$apo_failed_harness_state")" "$CONTINUATION_OUTPUT/tron-latest.state"
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock tron
    APO_OUTPUT_DIR=$CONTINUATION_OUTPUT
    apo_public_overclock_select_source
    [[ $APO_COMMAND == run ]]
    [[ -z $APO_SELECTED_RUN_ID ]]
)

# Current and legacy endurance failures are history inputs for a new run, not
# implicit continuation targets.
FAILED_ENDURANCE_RUN=20260828-205612-2222222222222222
FAILED_ENDURANCE_STATE="$CONTINUATION_OUTPUT/tron-${FAILED_ENDURANCE_RUN}.state"
write_state_fixture "$FAILED_ENDURANCE_STATE" \
    FORMAT_VERSION 1 RUN_SCHEMA 8 RUN_ID "$FAILED_ENDURANCE_RUN" \
    REMOTE_TARGET "$(id -un)@tron" ORIGIN_COMMAND overclock \
    CFG_AUTO_GENERATED_CANDIDATES 1 STATUS FAILED PHASE FINAL_VALIDATION \
    FAILURE_CLASS STABILITY_FAILURE FAILURE_REASON 'verified autonomous combined-endurance reboot' \
    FINAL_STAGE ENDURANCE RECOMMENDED_CPU 3125 RECOMMENDED_GPU 1175 \
    FINAL_TARGET_CPU 3125 FINAL_TARGET_GPU 1175 EDGE_CPU_STATUS NOT_REQUESTED \
    FLOOR_VALIDATED 0 TRYBOOT_EXPECTED 0 TRYBOOT_FILE_MAY_EXIST 0 APPLY_STATUS NOT_APPLIED
ln -sfn "$(basename "$FAILED_ENDURANCE_STATE")" "$CONTINUATION_OUTPUT/tron-latest.state"
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock tron
    APO_OUTPUT_DIR=$CONTINUATION_OUTPUT
    apo_public_overclock_select_source
    [[ $APO_COMMAND == run && -z $APO_SELECTED_RUN_ID ]]
)

# A legacy combined failure also requires an explicit resume to migrate it.
FAILED_LEGACY_ENDURANCE_RUN=20260828-205613-3333333333333333
FAILED_LEGACY_ENDURANCE_STATE="$CONTINUATION_OUTPUT/tron-${FAILED_LEGACY_ENDURANCE_RUN}.state"
write_state_fixture "$FAILED_LEGACY_ENDURANCE_STATE" \
    FORMAT_VERSION 1 RUN_SCHEMA 7 RUN_ID "$FAILED_LEGACY_ENDURANCE_RUN" \
    REMOTE_TARGET "$(id -un)@tron" ORIGIN_COMMAND overclock \
    CFG_AUTO_GENERATED_CANDIDATES 1 STATUS FAILED PHASE FINAL_VALIDATION \
    FAILURE_CLASS STABILITY_FAILURE FAILURE_REASON 'legacy combined-endurance failure' \
    FINAL_STAGE ENDURANCE RECOMMENDED_CPU 3125 RECOMMENDED_GPU 1175 \
    FINAL_TARGET_CPU 3125 FINAL_TARGET_GPU 1175 EDGE_CPU_STATUS NOT_REQUESTED \
    FLOOR_VALIDATED 0 TRYBOOT_EXPECTED 0 TRYBOOT_FILE_MAY_EXIST 0 APPLY_STATUS NOT_APPLIED
ln -sfn "$(basename "$FAILED_LEGACY_ENDURANCE_STATE")" "$CONTINUATION_OUTPUT/tron-latest.state"
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock tron
    APO_OUTPUT_DIR=$CONTINUATION_OUTPUT
    apo_public_overclock_select_source
    [[ $APO_COMMAND == run && -z $APO_SELECTED_RUN_ID ]]
)
