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

CONTINUATION_OUTPUT="$TEMP_DIR/continuation-output"
mkdir -p "$CONTINUATION_OUTPUT"

# A later edge request reuses a retained, applied ordinary floor instead of
# rediscovering the tuned host or repeating its eight-hour endurance phase.
# Headless is a first-class retained mode for this path.
APPLIED_FLOOR_RUN=20260827-010203-2222222222222222
APPLIED_FLOOR_STATE="$CONTINUATION_OUTPUT/tron-${APPLIED_FLOOR_RUN}.state"
write_state_fixture "$APPLIED_FLOOR_STATE" \
    FORMAT_VERSION 1 RUN_SCHEMA 9 RUN_ID "$APPLIED_FLOOR_RUN" \
    REMOTE_TARGET "$(id -un)@tron" ORIGIN_COMMAND overclock READ_ONLY_RUN 0 \
    CFG_AUTO_GENERATED_CANDIDATES 1 CFG_EDGE_CPU_24H 0 \
    STATUS PASS PHASE COMPLETE FINAL_STAGE COMPLETE \
    VALIDATED 1 VALIDATION_SCHEMA 8 VALIDATION_DURATION_S 28800 \
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
    FORMAT_VERSION 1 RUN_SCHEMA 9 RUN_ID "$INELIGIBLE_FLOOR_RUN" \
    REMOTE_TARGET "$(id -un)@tron" ORIGIN_COMMAND overclock READ_ONLY_RUN 0 \
    CFG_AUTO_GENERATED_CANDIDATES 1 CFG_EDGE_CPU_24H 0 \
    STATUS PASS PHASE COMPLETE FINAL_STAGE COMPLETE \
    VALIDATED 1 VALIDATION_SCHEMA 8 VALIDATION_DURATION_S 3600 \
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
