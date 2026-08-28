#!/usr/bin/env bash
# The fixture intentionally isolates repeated sourced-controller evaluations in subshells.
# shellcheck disable=SC2030,SC2031
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

parse_fixture() {
    local expected_command=$1 expected_origin=$2 expected_public=$3
    shift 3
    (
        export APO_CLI_LIBRARY_ONLY=1
        # shellcheck source=../autopioverclock
        source "$ROOT/autopioverclock"
        apo_parse_cli "$@"
        [[ $APO_COMMAND == "$expected_command" ]]
        [[ $APO_ORIGIN_COMMAND == "$expected_origin" ]]
        [[ $APO_PUBLIC_COMMAND == "$expected_public" ]]
        [[ $APO_REMOTE_TARGET == "$(id -un)@tron" ]]
    )
}

parse_fixture prepare prepare prepare prepare tron
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli prepare tron
    [[ $APO_INSTALL_MISSING == 1 ]]
    [[ $APO_REPAIR_WATCHDOGS == 1 ]]
    [[ $APO_AUTO_PREPARE == 1 ]]
    [[ $APO_AUTO_APPLY == 0 ]]
)

parse_fixture run overclock overclock overclock tron
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock tron --edge-cpu-24h
    [[ $APO_COMMAND == run ]]
    [[ $APO_AUTO_APPLY == 1 ]]
    [[ $APO_ASSUME_YES == 1 ]]
    [[ $APO_EDGE_CPU_24H == 1 ]]
    [[ $APO_MAX_FAN == 1 ]]
    [[ $APO_MODE_REQUESTED == auto ]]
    [[ -z $APO_CONFIG_FILE ]]
)
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock tron --no-max-fan
    [[ $APO_COMMAND == run ]]
    [[ $APO_MAX_FAN == 0 && $APO_MAX_FAN_OPTION_SEEN == 1 ]]
)
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli run tron --no-max-fan --yes
    [[ $APO_COMMAND == run && $APO_MAX_FAN == 0 ]]
)

parse_fixture run test test test tron --cpu 3100 --gpu 1150 --minutes 90
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli test tron --cpu 3100 --gpu 1150 --minutes 90 --no-max-fan
    [[ $APO_COMMAND == run && $APO_ORIGIN_COMMAND == test && $APO_PUBLIC_COMMAND == test ]]
    [[ $APO_MANUAL_TEST == 1 && $APO_MANUAL_CPU == 3100 && $APO_MANUAL_GPU == 1150 ]]
    [[ $APO_MANUAL_MINUTES == 90 && $APO_MANUAL_DURATION_S == 5400 ]]
    [[ $APO_ASSUME_YES == 1 && $APO_AUTO_APPLY == 0 && $APO_MAX_FAN == 0 ]]
)

parse_fixture reset reset reset reset tron
parse_fixture reset reset '' tron reset

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

CONTINUATION_OUTPUT="$TEMP_DIR/continuation-output"
mkdir -p "$CONTINUATION_OUTPUT"
CONTINUATION_RUN=20260827-010203-abcdef0123456789
CONTINUATION_STATE="$CONTINUATION_OUTPUT/tron-${CONTINUATION_RUN}.state"
write_state_fixture "$CONTINUATION_STATE" \
    FORMAT_VERSION 1 RUN_SCHEMA 8 RUN_ID "$CONTINUATION_RUN" \
    REMOTE_TARGET "$(id -un)@tron" ORIGIN_COMMAND overclock \
    STATUS INTERRUPTED PHASE CPU_SWEEP APPLY_STATUS NOT_APPLIED CFG_MAX_FAN 1
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
)
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
grep -Fq 'Finish it first, then repeat overclock TARGET --edge-cpu-24h' "$TEMP_DIR/active-edge-change.err"
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

# Repeating the one public command also adopts the exact recovered schema-7
# final-stress boundary produced by alpha.20. It does not silently adopt an
# arbitrary failed run.
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

# A later edge request reuses a retained, applied ordinary floor instead of
# rediscovering the tuned host or repeating its eight-hour endurance phase.
# Headless is a first-class retained mode for this path.
APPLIED_FLOOR_RUN=20260827-010203-2222222222222222
APPLIED_FLOOR_STATE="$CONTINUATION_OUTPUT/tron-${APPLIED_FLOOR_RUN}.state"
write_state_fixture "$APPLIED_FLOOR_STATE" \
    FORMAT_VERSION 1 RUN_SCHEMA 8 RUN_ID "$APPLIED_FLOOR_RUN" \
    REMOTE_TARGET "$(id -un)@tron" ORIGIN_COMMAND overclock READ_ONLY_RUN 0 \
    CFG_AUTO_GENERATED_CANDIDATES 1 CFG_EDGE_CPU_24H 0 \
    STATUS PASS PHASE COMPLETE FINAL_STAGE COMPLETE \
    VALIDATED 1 VALIDATION_SCHEMA 7 VALIDATION_DURATION_S 28800 \
    APPLY_STATUS APPLIED EDGE_CPU_STATUS NOT_REQUESTED FLOOR_VALIDATED 0 POST_FLOOR_EDGE 0 \
    TRYBOOT_EXPECTED 0 TRYBOOT_FILE_MAY_EXIST 0 MODE_EFFECTIVE headless REQUIRE_GPU_STRESS 1 \
    FINAL_CPU 3100 FINAL_GPU 1150 RECOMMENDED_CPU 3100 RECOMMENDED_GPU 1150 \
    FINAL_TARGET_CPU 3100 FINAL_TARGET_GPU 1150 NORMAL_CPU 3100 NORMAL_GPU 1150 \
    PERMANENT_HASH aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
ln -sfn "$(basename "$APPLIED_FLOOR_STATE")" "$CONTINUATION_OUTPUT/tron-latest.state"
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock tron --edge-cpu-24h
    APO_OUTPUT_DIR=$CONTINUATION_OUTPUT
    apo_public_overclock_select_continuation
    [[ $APO_COMMAND == post-floor-edge ]]
    [[ $APO_POST_FLOOR_EDGE_SOURCE_STATE == "$APPLIED_FLOOR_STATE" ]]
    [[ $APO_EDGE_CPU_24H == 1 ]]
    [[ $APO_POST_FLOOR_EDGE_MAX_FAN == 1 ]]
    [[ $(apo_state_get MODE_EFFECTIVE) == headless ]]
)
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock tron --edge-cpu-24h --no-max-fan
    APO_OUTPUT_DIR=$CONTINUATION_OUTPUT
    apo_public_overclock_select_continuation
    [[ $APO_COMMAND == post-floor-edge ]]
    [[ $APO_POST_FLOOR_EDGE_MAX_FAN == 0 ]]
)
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock tron
    APO_OUTPUT_DIR=$CONTINUATION_OUTPUT
    apo_public_overclock_select_continuation
    [[ $APO_COMMAND == resume ]]
    [[ $APO_SELECTED_RUN_ID == "$APPLIED_FLOOR_RUN" ]]
)

INELIGIBLE_FLOOR_RUN=20260827-010203-3333333333333333
INELIGIBLE_FLOOR_STATE="$CONTINUATION_OUTPUT/tron-${INELIGIBLE_FLOOR_RUN}.state"
write_state_fixture "$INELIGIBLE_FLOOR_STATE" \
    FORMAT_VERSION 1 RUN_SCHEMA 8 RUN_ID "$INELIGIBLE_FLOOR_RUN" \
    REMOTE_TARGET "$(id -un)@tron" ORIGIN_COMMAND overclock READ_ONLY_RUN 0 \
    CFG_AUTO_GENERATED_CANDIDATES 1 CFG_EDGE_CPU_24H 0 \
    STATUS PASS PHASE COMPLETE FINAL_STAGE COMPLETE \
    VALIDATED 1 VALIDATION_SCHEMA 7 VALIDATION_DURATION_S 3600 \
    APPLY_STATUS APPLIED EDGE_CPU_STATUS NOT_REQUESTED FLOOR_VALIDATED 0 POST_FLOOR_EDGE 0 \
    TRYBOOT_EXPECTED 0 TRYBOOT_FILE_MAY_EXIST 0 MODE_EFFECTIVE headless REQUIRE_GPU_STRESS 1 \
    FINAL_CPU 3100 FINAL_GPU 1150 RECOMMENDED_CPU 3100 RECOMMENDED_GPU 1150 \
    FINAL_TARGET_CPU 3100 FINAL_TARGET_GPU 1150 NORMAL_CPU 3100 NORMAL_GPU 1150 \
    PERMANENT_HASH bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
ln -sfn "$(basename "$INELIGIBLE_FLOOR_STATE")" "$CONTINUATION_OUTPUT/tron-latest.state"
if (
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock tron --edge-cpu-24h
    APO_OUTPUT_DIR=$CONTINUATION_OUTPUT
    apo_public_overclock_select_continuation
) 2>"$TEMP_DIR/ineligible-edge.err"; then
    echo 'an ineligible applied floor silently ignored a later edge request' >&2
    exit 1
fi
grep -Fq 'Later --edge-cpu-24h requires a retained' "$TEMP_DIR/ineligible-edge.err"

PREPARE_RUN=20260827-010204-abcdef0123456789
PREPARE_STATE="$CONTINUATION_OUTPUT/tron-${PREPARE_RUN}.state"
write_state_fixture "$PREPARE_STATE" \
    FORMAT_VERSION 1 RUN_SCHEMA 7 RUN_ID "$PREPARE_RUN" \
    REMOTE_TARGET "$(id -un)@tron" ORIGIN_COMMAND prepare \
    STATUS PASS PHASE COMPLETE APPLY_STATUS NOT_APPLIED
ln -sfn "$(basename "$PREPARE_STATE")" "$CONTINUATION_OUTPUT/tron-latest.state"
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock tron
    APO_OUTPUT_DIR=$CONTINUATION_OUTPUT
    apo_public_overclock_select_continuation
    [[ $APO_COMMAND == run ]]
    [[ -z $APO_SELECTED_RUN_ID ]]
    [[ -z ${APO_STATE_FILE:-} ]]
)

MANUAL_RUN=20260827-010205-abcdef0123456789
MANUAL_STATE="$CONTINUATION_OUTPUT/tron-${MANUAL_RUN}.state"
write_state_fixture "$MANUAL_STATE" \
    FORMAT_VERSION 1 RUN_SCHEMA 8 RUN_ID "$MANUAL_RUN" \
    REMOTE_TARGET "$(id -un)@tron" ORIGIN_COMMAND test \
    STATUS INTERRUPTED PHASE MANUAL_TEST APPLY_STATUS NOT_APPLIED \
    CFG_MANUAL_TEST 1 CFG_MANUAL_CPU 3100 CFG_MANUAL_GPU 1150 CFG_MANUAL_MINUTES 90 \
    CFG_MANUAL_DURATION_S 5400 CFG_MAX_FAN 1
ln -sfn "$(basename "$MANUAL_STATE")" "$CONTINUATION_OUTPUT/tron-latest.state"
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli test tron --cpu 3100 --gpu 1150 --minutes 90
    APO_OUTPUT_DIR=$CONTINUATION_OUTPUT
    apo_public_test_select_continuation
    [[ $APO_COMMAND == resume && $APO_SELECTED_RUN_ID == "$MANUAL_RUN" ]]
    [[ $APO_MANUAL_TEST == 1 && $APO_MAX_FAN == 1 ]]
)
if (
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli test tron --cpu 3125 --gpu 1150 --minutes 90
    APO_OUTPUT_DIR=$CONTINUATION_OUTPUT
    apo_public_test_select_continuation
) 2>"$TEMP_DIR/manual-plan-change.err"; then
    echo 'an interrupted manual test accepted different clocks' >&2
    exit 1
fi
grep -Fq 'Repeat that exact test command' "$TEMP_DIR/manual-plan-change.err"
if "$ROOT/autopioverclock" apply tron --output-dir "$CONTINUATION_OUTPUT" --run-id "$MANUAL_RUN" 2>"$TEMP_DIR/manual-apply.err"; then
    echo 'a manual stability result was accepted for permanent apply' >&2
    exit 1
fi
grep -Fq 'can never be permanently applied' "$TEMP_DIR/manual-apply.err"

for missing_target_command in prepare overclock test reset run resume status recover apply report; do
    if "$ROOT/autopioverclock" "$missing_target_command" >/dev/null 2>&1; then
        echo "$missing_target_command accepted a missing target" >&2
        exit 1
    fi
done

for invalid_test_args in \
    '--cpu 3100 --gpu 1150' \
    '--cpu 3100 --minutes 60' \
    '--gpu 1150 --minutes 60' \
    '--cpu 599 --gpu 1150 --minutes 60' \
    '--cpu 3100 --gpu 1150 --minutes 0' \
    '--cpu 3100 --gpu 1150 --minutes 1441'; do
    # The fixture arguments are fixed numeric tokens without shell metacharacters.
    # shellcheck disable=SC2086
    if "$ROOT/autopioverclock" test tron $invalid_test_args >/dev/null 2>&1; then
        echo "manual test accepted invalid options: $invalid_test_args" >&2
        exit 1
    fi
done
if "$ROOT/autopioverclock" overclock tron --cpu 3100 >/dev/null 2>&1; then
    echo 'overclock accepted a manual-test-only clock option' >&2
    exit 1
fi

if "$ROOT/autopioverclock" overclock tron --config fixture.conf >/dev/null 2>&1; then
    echo 'simple overclock accepted an advanced custom plan' >&2
    exit 1
fi
if "$ROOT/autopioverclock" prepare tron --edge-cpu-24h >/dev/null 2>&1; then
    echo 'prepare accepted the optional edge-tuning flag' >&2
    exit 1
fi
if "$ROOT/autopioverclock" prepare tron --no-max-fan >/dev/null 2>&1; then
    echo 'prepare accepted a tuning-only fan option' >&2
    exit 1
fi
if "$ROOT/autopioverclock" reset tron --no-max-fan >/dev/null 2>&1; then
    echo 'reset accepted a tuning-only fan option' >&2
    exit 1
fi
if "$ROOT/autopioverclock" resume tron --no-max-fan >/dev/null 2>&1; then
    echo 'resume accepted a cooling-policy change outside saved state' >&2
    exit 1
fi
if "$ROOT/autopioverclock" prepare tron --config fixture.conf >/dev/null 2>&1; then
    echo 'simple prepare accepted an advanced custom plan' >&2
    exit 1
fi
if "$ROOT/autopioverclock" reset tron --yes >/dev/null 2>&1; then
    echo 'reset accepted an unrelated tuning confirmation flag' >&2
    exit 1
fi

help_output=$("$ROOT/autopioverclock" --help)
for command_line in \
    'autopioverclock prepare TARGET' \
    'autopioverclock overclock TARGET' \
    'autopioverclock test TARGET' \
    'autopioverclock reset TARGET'; do
    grep -Fq "$command_line" <<< "$help_output"
done

for advanced_command in run resume status recover apply report; do
    grep -Eq "^[[:space:]]+${advanced_command}[[:space:]]" <<< "$help_output"
done

for retained_option in --config --mode --run-id --install-missing --repair-watchdogs --dry-run --yes --redact --no-max-fan --cpu --gpu --minutes; do
    grep -Fq -- "$retained_option" <<< "$help_output"
done

for documented_command in prepare overclock test reset run resume status recover apply report; do
    documented_pattern=$(printf '| `%s TARGET` |' "$documented_command")
    grep -Fq "$documented_pattern" "$ROOT/README.md"
done

for normal_command in prepare overclock reset; do
    documented_pattern=$(printf '| `%s TARGET` |' "$normal_command")
    grep -Fq "$documented_pattern" "$ROOT/docs/cli.md"
done

grep -Fq 'controller and target must be different machines' "$ROOT/README.md"
grep -Fq 'Run every command on the controller/master Pi.' "$ROOT/docs/cli.md"
grep -Fq 'The eight-hour endurance phase is not repeated.' "$ROOT/docs/cli.md"
grep -Fq 'a target with no screen remains fully supported' "$ROOT/docs/cli.md"
grep -Fq 'ssh "$TARGET" true' "$ROOT/README.md"
grep -Fq 'ssh -o BatchMode=yes "$TARGET" true' "$ROOT/README.md"
if grep -Fq 'command ssh' "$ROOT/README.md" || grep -Fq -- '-F /dev/null' "$ROOT/README.md"; then
    echo 'README exposed the implementation-specific SSH invocation' >&2
    exit 1
fi

printf 'test_simple_cli: PASS\n'
