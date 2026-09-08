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

LONG_MANUAL_RUN=20260905-010205-fedcba9876543210
LONG_MANUAL_STATE="$CONTINUATION_OUTPUT/tron-${LONG_MANUAL_RUN}.state"
write_state_fixture "$LONG_MANUAL_STATE" \
    FORMAT_VERSION 1 RUN_SCHEMA 10 RUN_ID "$LONG_MANUAL_RUN" \
    REMOTE_TARGET "$(id -un)@tron" ORIGIN_COMMAND test \
    STATUS INTERRUPTED PHASE MANUAL_TEST APPLY_STATUS NOT_APPLIED \
    CFG_MANUAL_TEST 1 CFG_MANUAL_CPU 3100 CFG_MANUAL_GPU 1150 CFG_MANUAL_MINUTES 2880 \
    CFG_MANUAL_DURATION_S 172800 CFG_MAX_FAN 1
ln -sfn "$(basename "$LONG_MANUAL_STATE")" "$CONTINUATION_OUTPUT/tron-latest.state"
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli test tron --cpu 3100 --gpu 1150 --final-hours 48
    APO_OUTPUT_DIR=$CONTINUATION_OUTPUT
    apo_public_test_select_continuation
    [[ $APO_COMMAND == resume && $APO_SELECTED_RUN_ID == "$LONG_MANUAL_RUN" ]]
    [[ $APO_MANUAL_MINUTES == 2880 && $APO_MANUAL_DURATION_S == 172800 ]]
)
# Canonical duration matching lets an interrupted one-hour test continue with
# either supported spelling without weakening the immutable duration check.
write_state_fixture "$LONG_MANUAL_STATE" \
    FORMAT_VERSION 1 RUN_SCHEMA 10 RUN_ID "$LONG_MANUAL_RUN" \
    REMOTE_TARGET "$(id -un)@tron" ORIGIN_COMMAND test \
    STATUS INTERRUPTED PHASE MANUAL_TEST APPLY_STATUS NOT_APPLIED \
    CFG_MANUAL_TEST 1 CFG_MANUAL_CPU 3100 CFG_MANUAL_GPU 1150 CFG_MANUAL_MINUTES 60 \
    CFG_MANUAL_DURATION_S 3600 CFG_MAX_FAN 1
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli test tron --cpu 3100 --gpu 1150 --minutes 60
    APO_OUTPUT_DIR=$CONTINUATION_OUTPUT
    apo_public_test_select_continuation
    [[ $APO_COMMAND == resume && $APO_SELECTED_RUN_ID == "$LONG_MANUAL_RUN" ]]
)
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli test tron --cpu 3100 --gpu 1150 --final-hours 1
    APO_OUTPUT_DIR=$CONTINUATION_OUTPUT
    apo_public_test_select_continuation
    [[ $APO_COMMAND == resume && $APO_SELECTED_RUN_ID == "$LONG_MANUAL_RUN" ]]
)
# Direct resume may restate the saved exact-test duration, but it must compare
# against the manual duration rather than the unrelated automatic final default.
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli resume tron --final-hours 1
    apo_state_load "$LONG_MANUAL_STATE"
    apo_resume_require_matching_duration_options
)
if (
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli resume tron --final-hours 2
    apo_state_load "$LONG_MANUAL_STATE"
    apo_resume_require_matching_duration_options
) 2>"$TEMP_DIR/manual-resume-duration-change.err"; then
    echo 'direct resume accepted a changed exact-test duration' >&2
    exit 1
fi
grep -Fq 'exact-pair test duration cannot change' "$TEMP_DIR/manual-resume-duration-change.err"
if (
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli resume tron --qualification-hours 1
    apo_state_load "$LONG_MANUAL_STATE"
    apo_resume_require_matching_duration_options
) 2>"$TEMP_DIR/manual-resume-qualification.err"; then
    echo 'direct resume accepted an automatic qualification duration for an exact test' >&2
    exit 1
fi
grep -Fq -- '--qualification-hours is not valid' "$TEMP_DIR/manual-resume-qualification.err"
ln -sfn "$(basename "$MANUAL_STATE")" "$CONTINUATION_OUTPUT/tron-latest.state"
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
grep -Fq 'Repeat the same clocks and duration' "$TEMP_DIR/manual-plan-change.err"
if "$ROOT/autopioverclock" apply tron --output-dir "$CONTINUATION_OUTPUT" --run-id "$MANUAL_RUN" 2>"$TEMP_DIR/manual-apply.err"; then
    echo 'a manual stability result was accepted for permanent apply' >&2
    exit 1
fi
if ! grep -Fq 'can never be permanently applied' "$TEMP_DIR/manual-apply.err"; then
    echo 'manual apply rejection did not explain that the evidence is non-applicable:' >&2
    cat "$TEMP_DIR/manual-apply.err" >&2
    exit 1
fi

for missing_target_command in prepare overclock test reset run resume status recover restore apply report; do
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
    '--cpu 3100 --gpu 1150 --minutes 35791381' \
    '--cpu 3100 --gpu 1150 --minutes 18446744073709551617' \
    '--cpu 3100 --gpu 1150 --minutes 000060' \
    '--cpu 3100 --gpu 1150 --final-hours 0' \
    '--cpu 3100 --gpu 1150 --final-hours 596524' \
    '--cpu 3100 --gpu 1150 --final-hours 1.5' \
    '--cpu 3100 --gpu 1150 --minutes 60 --final-hours 1'; do
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
    echo 'prepare accepted the overclock-only edge-duration compatibility flag' >&2
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

for advanced_command in run resume status summary recover restore apply report; do
    grep -Eq "^[[:space:]]+${advanced_command}[[:space:]]" <<< "$help_output"
done

for retained_option in --config --mode --run-id --install-missing --repair-watchdogs --dry-run --yes --redact --no-max-fan --no-history --cpu --gpu --minutes --qualification-hours --final-hours --restart-from --cpu-only --gpu-only --cpu-min --cpu-max --gpu-min --gpu-max --cpu-resolution --gpu-resolution; do
    grep -Fq -- "$retained_option" <<< "$help_output"
done
if grep -Fq -- '--cpu-start-at' <<< "$help_output"; then
    echo 'removed --cpu-start-at alias is still present in help output' >&2
    exit 1
fi
if grep -Fq -- '--gpu-start-at' <<< "$help_output"; then
    echo 'removed --gpu-start-at alias is still present in help output' >&2
    exit 1
fi

for documented_command in prepare overclock test reset run resume status summary recover restore apply report; do
    documented_pattern=$(printf '| `%s TARGET' "$documented_command")
    grep -Fq "$documented_pattern" "$ROOT/README.md"
done

# The public README is the concise command reference, so every accepted public
# option must remain discoverable there even when several share one table row.
for documented_option in --config --mode --run-id --install-missing --repair-watchdogs --dry-run --yes --redact --no-max-fan --no-history --cpu --gpu --minutes --qualification-hours --final-hours --restart-from --cpu-only --gpu-only --cpu-min --cpu-max --gpu-min --gpu-max --cpu-resolution --gpu-resolution --help --version; do
    grep -Fq -- "$documented_option" "$ROOT/README.md"
done

for normal_command in prepare overclock reset; do
    documented_pattern=$(printf '| `%s TARGET' "$normal_command")
    grep -Fq "$documented_pattern" "$ROOT/docs/cli.md"
done

grep -Fq 'The controller and target must be different machines.' "$ROOT/README.md"
for required_heading in \
    '## Supported targets' \
    '## Current validation status' \
    '## How automatic overclocking works' \
    '## Commands' \
    '## What every candidate must prove' \
    '## Recovery and resume' \
    '## Results'; do
    grep -Fq "$required_heading" "$ROOT/README.md"
done
grep -Fq 'normal forward sweep starts at 2500 MHz and rises in 100 MHz coarse steps' "$ROOT/README.md"
grep -Fq 'the reverse sweep tests that exact ceiling first and descends until it finds a pass' "$ROOT/README.md"
grep -Fq 'forward in 50 MHz coarse steps with no clear GPU ceiling, or downward from a clear retained or explicit ceiling' "$ROOT/README.md"
grep -Fq 'It then refines the proved pass/fail gap at `--cpu-resolution` granularity, 25 MHz by default, to find the highest actual pass.' "$ROOT/README.md"
grep -Fq 'Exact CPU evidence lowers only CPU by `--cpu-resolution`; exact GPU evidence lowers only GPU by `--gpu-resolution`.' "$ROOT/README.md"
grep -Fq 'If the domain is ambiguous, the pair becomes the anchor and a CPU-only reduction is tried first.' "$ROOT/README.md"
grep -Fq 'A required reduction below either hard minimum fails clearly instead of silently changing the requested range.' "$ROOT/README.md"
grep -Fq 'one fresh 48-hour combined CPU/GPU/I/O validation by default' "$ROOT/README.md"
grep -Fq 'test pi@hostname --cpu 3100 --gpu 1150 --final-hours 72' "$ROOT/README.md"
grep -Fq -- '--qualification-hours 3 --final-hours 72' "$ROOT/README.md"
quick_start=$(sed -n '/^## Quick start$/,/^## Supported targets$/p' "$ROOT/README.md")
for install_line in \
    'git clone https://github.com/p1r473/AutoPiOverclock.git' \
    'cd AutoPiOverclock' \
    'make test' \
    'sudo make install' \
    'autopioverclock --version'; do
    grep -Fq "$install_line" <<< "$quick_start"
done
grep -Fq 'It does not connect to, modify, or reboot a target.' <<< "$quick_start"
grep -Fq 'autopioverclock prepare pi@hostname' <<< "$quick_start"
grep -Fq 'autopioverclock overclock pi@hostname' <<< "$quick_start"
if grep -Fq 'autopioverclock reset pi@hostname' <<< "$quick_start"; then
    echo 'README quick start presented reset as an everyday required command' >&2
    exit 1
fi
grep -Fq 'Run every command on the separate Linux controller.' "$ROOT/docs/cli.md"
grep -Fq 'The controller may be any supported Linux computer; it does not need to be a Raspberry Pi.' "$ROOT/docs/cli.md"
grep -Fq 'each adjusted pair restarts the complete requested `--final-hours` duration from zero.' "$ROOT/docs/cli.md"
grep -Fq 'The common reason to use `--restart-from final` is simple:' "$ROOT/README.md"
grep -Fq 'Headless Raspberry Pi OS/Debian requires neither a desktop nor audio hardware' "$ROOT/docs/cli.md"
grep -Fq 'ssh "$TARGET" true' "$ROOT/README.md"

# Public examples stay generic and copyable; private lab hostnames belong only
# in retained artifacts, never in README or reference documentation.
for public_doc in "$ROOT/README.md" "$ROOT"/docs/*.md; do
    if grep -Eiq '(^|[^[:alnum:]_])(tron|monkeebutt|harbormaster)([^[:alnum:]_]|$)|pi@pi-host' "$public_doc"; then
        echo "private or obsolete example target leaked into ${public_doc#"$ROOT"/}" >&2
        exit 1
    fi
done
grep -Fq 'ssh -o BatchMode=yes "$TARGET" true' "$ROOT/README.md"
if grep -Fq 'command ssh' "$ROOT/README.md" || grep -Fq -- '-F /dev/null' "$ROOT/README.md"; then
    echo 'README exposed the implementation-specific SSH invocation' >&2
    exit 1
fi
