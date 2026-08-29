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
grep -Fq 'Finish it first, then repeat overclock TARGET with --edge-hours HOURS' "$TEMP_DIR/active-edge-change.err"
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

# The compatibility flag has literal 24-hour semantics. It cannot silently
# continue a custom-duration edge run as though the user had requested 12h.
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
grep -Fq -- '--edge-cpu-24h means exactly 24 hours' "$TEMP_DIR/edge-alias-duration-change.err"

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
