#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TEMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEMP_DIR"' EXIT

export APO_CLI_LIBRARY_ONLY=1
source "$ROOT/autopioverclock"

# An exact test may revalidate the protected applied pair. Underclocks remain
# outside the public exact-test contract.
APO_NORMAL_CPU=2900
APO_NORMAL_GPU=1125
APO_MANUAL_CPU=2900
APO_MANUAL_GPU=1125
apo_validate_manual_test_clocks
if (
    APO_MANUAL_CPU=2875
    apo_validate_manual_test_clocks
) 2>"$TEMP_DIR/underclock.err"; then
    echo 'manual test accepted a CPU clock below the protected normal clock' >&2
    exit 1
fi
grep -Fq 'below the protected normal clock' "$TEMP_DIR/underclock.err"

# The final result box must remain rectangular for the real Tron result and
# must write the identical plain-text result into the summary.
APO_REMOTE_TARGET=tron
APO_SUMMARY_FILE="$TEMP_DIR/summary.txt"
: > "$APO_SUMMARY_FILE"
APO_STATE=()
apo_state_set FINAL_CPU 2900
apo_state_set FINAL_GPU 1125
apo_state_set NORMAL_VOLTAGE 0
apo_state_set VALIDATION_DURATION_S 360000
box=$(apo_print_validated_result_box)
box=${box#$'\n'}
mapfile -t box_lines <<< "$box"
[[ ${#box_lines[@]} == 9 ]]
box_width=${#box_lines[0]}
for line in "${box_lines[@]}"; do
    [[ ${#line} == "$box_width" ]] || {
        printf 'validated-result box is not rectangular: expected %s columns, got %s\n' "$box_width" "${#line}" >&2
        exit 1
    }
done
[[ ${box_lines[0]} == +--*--+ ]]
[[ ${box_lines[1]} == *'AUTOPIOVERCLOCK VALIDATED RESULT'* ]]
[[ ${box_lines[3]} == *'Target: tron'* ]]
[[ ${box_lines[4]} == *'CPU: 2900 MHz'* ]]
[[ ${box_lines[5]} == *'GPU/V3D: 1125 MHz'* ]]
[[ ${box_lines[6]} == *'Voltage delta: 0 uV'* ]]
[[ ${box_lines[7]} == *'Validated at final clocks: 100h 00m 00s (360000 seconds)'* ]]
[[ $(<"$APO_SUMMARY_FILE") == "$box" ]]

printf 'test_simple_cli_output: PASS\n'
