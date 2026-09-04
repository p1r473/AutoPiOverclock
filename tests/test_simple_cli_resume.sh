#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2030,SC2031
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
    STATUS INTERRUPTED PHASE CPU_SWEEP APPLY_STATUS NOT_APPLIED CFG_MAX_FAN 1 \
    CFG_QUALIFICATION_DURATION_S 10800 CFG_FINAL_DURATION_S 21600 \
    CFG_EDGE_DURATION_S 86400 CFG_DURATION_POLICY custom
ln -s "$(basename "$CONTINUATION_STATE")" "$CONTINUATION_OUTPUT/tron-latest.state"
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock tron
    APO_OUTPUT_DIR=$CONTINUATION_OUTPUT
    apo_public_overclock_select_continuation
    [[ $APO_COMMAND == resume ]]
    [[ $APO_SELECTED_RUN_ID == "$CONTINUATION_RUN" ]]
    [[ $APO_AUTO_APPLY == 1 ]]
    [[ $APO_QUALIFICATION_DURATION_S == 10800 && $APO_FINAL_DURATION_S == 21600 && $APO_EDGE_DURATION_S == 86400 ]]
)
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock tron --qualification-hours 3 --final-hours 6
    APO_OUTPUT_DIR=$CONTINUATION_OUTPUT
    apo_public_overclock_select_continuation
    [[ $APO_COMMAND == resume && $APO_SELECTED_RUN_ID == "$CONTINUATION_RUN" ]]
)
if (
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock tron --final-hours 8
    APO_OUTPUT_DIR=$CONTINUATION_OUTPUT
    apo_public_overclock_select_continuation
) 2>"$TEMP_DIR/active-duration-change.err"; then
    echo 'an active run accepted a different final duration' >&2
    exit 1
fi
grep -Fq 'final duration cannot change during continuation' "$TEMP_DIR/active-duration-change.err"
if (
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock tron --edge-cpu-24h
    APO_OUTPUT_DIR=$CONTINUATION_OUTPUT
    apo_public_overclock_select_continuation
) 2>"$TEMP_DIR/active-edge-change.err"; then
    echo 'an active ordinary run accepted a late immutable edge-plan change' >&2
    exit 1
fi
grep -Fq 'Unknown option: --edge-cpu-24h' "$TEMP_DIR/active-edge-change.err"
if (
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock tron --no-max-fan
    APO_OUTPUT_DIR=$CONTINUATION_OUTPUT
    apo_public_overclock_select_continuation
) 2>"$TEMP_DIR/active-fan-change.err"; then
    echo 'an active run accepted a mid-run cooling-policy change' >&2
    exit 1
fi
grep -Fq 'cooling policy cannot change during continuation' "$TEMP_DIR/active-fan-change.err"

# An explicit checkpoint restart may replace an untouched long-duration plan.
# The saved state supplies clocks; the command supplies only checkpoint/time.
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock tron --restart-from cpu-qualification --qualification-hours 2 --final-hours 24
    APO_OUTPUT_DIR=$CONTINUATION_OUTPUT
    apo_public_overclock_select_continuation
    [[ $APO_COMMAND == resume && $APO_SELECTED_RUN_ID == "$CONTINUATION_RUN" ]]
    [[ $APO_RESTART_PENDING == 1 && $APO_RESTART_FROM == cpu-qualification ]]
    [[ $APO_RESTART_QUALIFICATION_DURATION_S == 7200 ]]
    [[ $APO_RESTART_FINAL_DURATION_S == 86400 && $APO_RESTART_EDGE_DURATION_S == 86400 ]]
    [[ $APO_EDGE_CPU_24H == 0 && $APO_EDGE_ORDER == floor-first ]]
)
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock tron --restart-from cpu-qualification --final-hours 24
    APO_OUTPUT_DIR=$CONTINUATION_OUTPUT
    apo_public_overclock_select_continuation
    [[ $APO_RESTART_QUALIFICATION_DURATION_S == 10800 ]]
    [[ $APO_RESTART_FINAL_DURATION_S == 86400 ]]
    [[ $APO_RESTART_EDGE_DURATION_S == 86400 ]]
)

# A retained legacy edge run remains resumable when the user supplies no
# removed edge option; the saved internal plan remains authoritative.
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
    apo_public_overclock_select_continuation
    [[ $APO_COMMAND == resume && $APO_EDGE_CPU_24H == 1 && $APO_EDGE_DURATION_S == 43200 ]]
)
if (
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock tron --edge-cpu-24h
    APO_OUTPUT_DIR=$EDGE_CONTINUATION_OUTPUT
    apo_public_overclock_select_continuation
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
    apo_parse_cli overclock tron --gpu-only --gpu-start-at 1150
    APO_OUTPUT_DIR=$DOMAIN_SOURCE_OUTPUT
    apo_public_overclock_select_continuation
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
    ln -s "$(basename "$PREPARE_STATE")" "$PREPARE_SOURCE_OUTPUT/tron-latest.state"
    (
        export APO_CLI_LIBRARY_ONLY=1
        source "$ROOT/autopioverclock"
        apo_parse_cli overclock tron --gpu-only --gpu-start-at 1150
        APO_OUTPUT_DIR=$PREPARE_SOURCE_OUTPUT
        apo_public_overclock_select_continuation
        [[ $APO_COMMAND == run && $APO_SWEEP_DOMAIN == gpu ]]
        [[ $APO_DOMAIN_SOURCE_STATE == "$PREPARE_SOURCE_OUTPUT/$(basename "$DOMAIN_SOURCE_STATE")" ]]
        [[ $APO_SOURCE_APPLIED_RUN_ID == "$DOMAIN_SOURCE_RUN" ]]
        [[ $APO_SOURCE_APPLIED_CPU == 2950 && $APO_SOURCE_APPLIED_GPU == 1125 ]]
    )
done

# Repeating an interrupted one-domain command resumes that exact run even when
# a later successful prepare audit owns the latest link. The prepare audit must
# prove the same permanent hash, live tuple, profile, and boot paths.
PREPARE_REPEAT_OUTPUT="$TEMP_DIR/domain-repeat-after-prepare"
mkdir -p "$PREPARE_REPEAT_OUTPUT"
cp "$DOMAIN_SOURCE_STATE" "$PREPARE_REPEAT_OUTPUT/$(basename "$DOMAIN_SOURCE_STATE")"
DOMAIN_REPEAT_RUN=20260904-140000-0011223344556677
DOMAIN_REPEAT_STATE="$PREPARE_REPEAT_OUTPUT/tron-${DOMAIN_REPEAT_RUN}.state"
write_state_fixture "$DOMAIN_REPEAT_STATE" \
    FORMAT_VERSION 1 RUN_SCHEMA 10 RUN_ID "$DOMAIN_REPEAT_RUN" \
    REMOTE_TARGET "$(id -un)@tron" ORIGIN_COMMAND overclock READ_ONLY_RUN 0 \
    PROFILE batocera BOOT_CONFIG /boot/config.txt TRYBOOT_CONFIG /boot/tryboot.txt GPU_KEY v3d_freq \
    CFG_AUTO_GENERATED_CANDIDATES 1 CFG_SWEEP_DOMAIN gpu CFG_CPU_START_AT '' CFG_GPU_START_AT 1150 \
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
    apo_parse_cli overclock tron --gpu-only --gpu-start-at 1150
    APO_OUTPUT_DIR=$PREPARE_REPEAT_OUTPUT
    apo_public_overclock_select_continuation
    [[ $APO_COMMAND == resume && $APO_SELECTED_RUN_ID == "$DOMAIN_REPEAT_RUN" ]]
    [[ $APO_SWEEP_DOMAIN == gpu && $APO_GPU_START_AT == 1150 ]]
    [[ $APO_QUALIFICATION_DURATION_S == 7200 && $APO_FINAL_DURATION_S == 86400 ]]
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
    apo_parse_cli overclock tron --gpu-only --gpu-start-at 1150
    APO_OUTPUT_DIR=$PREPARE_MISMATCH_OUTPUT
    apo_public_overclock_select_continuation
) >"$TEMP_DIR/domain-prepare-path-mismatch.out" 2>&1; then
    echo 'a latest prepare audit selected an applied source across different boot paths' >&2
    exit 1
fi
grep -Fq 'latest prepare audit does not match any retained applied result' "$TEMP_DIR/domain-prepare-path-mismatch.out"

if (
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock tron --cpu-only
    APO_OUTPUT_DIR=$TEMP_DIR/no-domain-source-output
    mkdir -p "$APO_OUTPUT_DIR"
    apo_public_overclock_select_continuation
) >/dev/null 2>&1; then
    echo 'CPU-only tuning started without a retained applied source' >&2
    exit 1
fi

# A completed, applied historical 8-hour floor with a safely rejected edge can
# start one linked fresh 24-hour floor validation. The source clocks and exact
# stock rollback backup come from retained evidence, never from CLI values.
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
    apo_parse_cli overclock monkeebutt --restart-from final --final-hours 24
    APO_OUTPUT_DIR=$FINAL_EXTENSION_OUTPUT
    apo_public_overclock_select_continuation
    [[ $APO_COMMAND == post-floor-final ]]
    [[ $APO_POST_FLOOR_FINAL_SOURCE_STATE == "$FINAL_EXTENSION_STATE" ]]
    [[ $APO_POST_FLOOR_FINAL_DURATION_S == 86400 ]]
    [[ $(apo_state_get FINAL_CPU) == 3100 && $(apo_state_get FINAL_GPU) == 1175 ]]
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

# Repeating the public command adopts an exact recovered schema-7
# final-stress boundary, not an arbitrary failed run.
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
    apo_public_overclock_select_continuation
    [[ $APO_COMMAND == resume ]]
    [[ $APO_SELECTED_RUN_ID == "$FAILED_FINAL_RUN" ]]
)

# A current saved sweep checkpoint matching Tron's recovered unstructured
# boot/health handoff is selected by the simple command and retried in place.
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
    apo_public_overclock_select_continuation
    [[ $APO_COMMAND == resume ]]
    [[ $APO_SELECTED_RUN_ID == "$FAILED_BOOT_HANDOFF_RUN" ]]
)

# The exact clean early-exit state produced by the 24-hour supervisor race is
# safe to adopt after its already-recorded complete normal recovery.
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
    apo_public_overclock_select_continuation
    [[ $APO_COMMAND == resume ]]
    [[ $APO_SELECTED_RUN_ID == "$FAILED_CLEAN_EARLY_RUN" ]]
)

# The exact alpha.38 failure occurred after a successful candidate workload and
# normal recovery when one controller-side permanent-hash read returned no
# evidence. The simple command must select that checkpoint for re-proof/retry.
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
    apo_public_overclock_select_continuation
    [[ $APO_COMMAND == resume ]]
    [[ $APO_SELECTED_RUN_ID == "$FAILED_HASH_READ_RUN" ]]
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
    apo_public_overclock_select_continuation
    [[ $APO_COMMAND == run ]]
    [[ -z $APO_SELECTED_RUN_ID ]]
)

# A current-schema automatic run whose combined endurance rebooted and then
# proved complete normal recovery is adopted for conservative paired backoff.
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
    apo_public_overclock_select_continuation
    [[ $APO_COMMAND == resume ]]
    [[ $APO_SELECTED_RUN_ID == "$FAILED_ENDURANCE_RUN" ]]
)

# A recovered schema-7 combined failure is also selected: the current schema migrates it
# through the conservative paired backoff and fresh domain qualifications.
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
    apo_public_overclock_select_continuation
    [[ $APO_COMMAND == resume ]]
    [[ $APO_SELECTED_RUN_ID == "$FAILED_LEGACY_ENDURANCE_RUN" ]]
)
