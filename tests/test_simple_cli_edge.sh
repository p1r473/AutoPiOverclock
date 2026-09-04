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

# Removed public edge flags must not start a new edge run. Retained applied
# results remain readable and a flag-free invocation keeps existing behavior.
APPLIED_FLOOR_RUN=20260827-010203-2222222222222222
APPLIED_FLOOR_STATE="$CONTINUATION_OUTPUT/tron-${APPLIED_FLOOR_RUN}.state"
write_state_fixture "$APPLIED_FLOOR_STATE" \
    FORMAT_VERSION 1 RUN_SCHEMA 9 RUN_ID "$APPLIED_FLOOR_RUN" \
    REMOTE_TARGET "$(id -un)@tron" ORIGIN_COMMAND overclock READ_ONLY_RUN 0 \
    CFG_AUTO_GENERATED_CANDIDATES 1 CFG_EDGE_CPU_24H 0 CFG_FINAL_DURATION_S 28800 CFG_DURATION_POLICY default \
    STATUS PASS PHASE COMPLETE FINAL_STAGE COMPLETE \
    VALIDATED 1 VALIDATION_SCHEMA 8 VALIDATION_DURATION_S 28800 \
    APPLY_STATUS APPLIED EDGE_CPU_STATUS NOT_REQUESTED FLOOR_VALIDATED 0 POST_FLOOR_EDGE 0 \
    TRYBOOT_EXPECTED 0 TRYBOOT_FILE_MAY_EXIST 0 MODE_EFFECTIVE headless REQUIRE_GPU_STRESS 1 \
    FINAL_CPU 3100 FINAL_GPU 1150 RECOMMENDED_CPU 3100 RECOMMENDED_GPU 1150 \
    FINAL_TARGET_CPU 3100 FINAL_TARGET_GPU 1150 NORMAL_CPU 3100 NORMAL_GPU 1150 \
    PERMANENT_HASH aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
ln -sfn "$(basename "$APPLIED_FLOOR_STATE")" "$CONTINUATION_OUTPUT/tron-latest.state"
if (
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock tron --edge-cpu-24h
    APO_OUTPUT_DIR=$CONTINUATION_OUTPUT
    apo_public_overclock_select_continuation
) 2>"$TEMP_DIR/removed-edge-alias.err"; then
    echo 'removed --edge-cpu-24h was accepted by overclock' >&2
    exit 1
fi
grep -Fq 'Unknown option: --edge-cpu-24h' "$TEMP_DIR/removed-edge-alias.err"
if (
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock tron --edge-cpu-24h --no-max-fan
    APO_OUTPUT_DIR=$CONTINUATION_OUTPUT
    apo_public_overclock_select_continuation
) >/dev/null 2>&1; then
    echo 'removed --edge-cpu-24h was accepted with --no-max-fan' >&2
    exit 1
fi
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock tron
    APO_OUTPUT_DIR=$CONTINUATION_OUTPUT
    apo_public_overclock_select_continuation
    [[ $APO_COMMAND == resume ]]
    [[ $APO_SELECTED_RUN_ID == "$APPLIED_FLOOR_RUN" ]]
)

# The removed custom edge-duration spelling is rejected too.
CUSTOM_FLOOR_RUN=20260827-010203-4444444444444444
CUSTOM_FLOOR_STATE="$CONTINUATION_OUTPUT/tron-${CUSTOM_FLOOR_RUN}.state"
write_state_fixture "$CUSTOM_FLOOR_STATE" \
    FORMAT_VERSION 1 RUN_SCHEMA 10 RUN_ID "$CUSTOM_FLOOR_RUN" \
    REMOTE_TARGET "$(id -un)@tron" ORIGIN_COMMAND overclock READ_ONLY_RUN 0 \
    CFG_AUTO_GENERATED_CANDIDATES 1 CFG_EDGE_CPU_24H 0 CFG_FINAL_DURATION_S 28800 CFG_DURATION_POLICY default \
    CFG_QUALIFICATION_DURATION_S 3600 CFG_FINAL_DURATION_S 14400 \
    CFG_EDGE_DURATION_S 86400 CFG_DURATION_POLICY custom \
    STATUS PASS PHASE COMPLETE FINAL_STAGE COMPLETE \
    VALIDATED 1 VALIDATION_SCHEMA 8 VALIDATION_DURATION_S 14400 \
    APPLY_STATUS APPLIED EDGE_CPU_STATUS NOT_REQUESTED FLOOR_VALIDATED 0 POST_FLOOR_EDGE 0 \
    TRYBOOT_EXPECTED 0 TRYBOOT_FILE_MAY_EXIST 0 MODE_EFFECTIVE headless REQUIRE_GPU_STRESS 1 \
    FINAL_CPU 3050 FINAL_GPU 1125 RECOMMENDED_CPU 3050 RECOMMENDED_GPU 1125 \
    FINAL_TARGET_CPU 3050 FINAL_TARGET_GPU 1125 NORMAL_CPU 3050 NORMAL_GPU 1125 \
    PERMANENT_HASH cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
ln -sfn "$(basename "$CUSTOM_FLOOR_STATE")" "$CONTINUATION_OUTPUT/tron-latest.state"
if (
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock tron --edge-hours 12
    APO_OUTPUT_DIR=$CONTINUATION_OUTPUT
    apo_public_overclock_select_continuation
) >/dev/null 2>&1; then
    echo 'removed --edge-hours was accepted by overclock' >&2
    exit 1
fi

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
grep -Fq 'Unknown option: --edge-cpu-24h' "$TEMP_DIR/ineligible-edge.err"

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
