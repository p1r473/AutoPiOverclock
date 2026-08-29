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

MANUAL_RUN=20260827-010205-abcdef0123456789
MANUAL_STATE="$CONTINUATION_OUTPUT/tron-${MANUAL_RUN}.state"
write_state_fixture "$MANUAL_STATE" \
    FORMAT_VERSION 1 RUN_SCHEMA 9 RUN_ID "$MANUAL_RUN" \
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
