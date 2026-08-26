#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
APO_ROOT=$ROOT
source "$ROOT/lib/common.sh"
source "$ROOT/lib/classify.sh"
FIXTURES="$ROOT/tests/fixtures"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

apo_classify_output "$FIXTURES/debian-pass.log" pass
[[ $APO_LAST_CLASS == PASS ]]
[[ $APO_LAST_RESULT_STRUCTURED == 1 ]]
apo_classify_output "$FIXTURES/batocera-canvas-failure.log" gpu
[[ $APO_LAST_CLASS == HARNESS_FAILURE ]]
[[ $APO_LAST_RESULT_STRUCTURED == 0 ]]
printf 'APO_RESULT_CLASS=HARNESS_FAILURE\nAPO_RESULT_REASON_B64=%s\n' \
    "$(printf '%s' 'structured harness fixture' | base64 | tr -d '\n')" > "$TEMP_DIR/structured-harness.log"
apo_classify_output "$TEMP_DIR/structured-harness.log" gpu
[[ $APO_LAST_CLASS == HARNESS_FAILURE ]]
[[ $APO_LAST_REASON == 'structured harness fixture' ]]
[[ $APO_LAST_RESULT_STRUCTURED == 1 ]]
apo_classify_output "$FIXTURES/undervoltage.log" power
[[ $APO_LAST_CLASS == STABILITY_FAILURE ]]
apo_classify_output "$FIXTURES/ext4-error.log" storage
[[ $APO_LAST_CLASS == STABILITY_FAILURE ]]
while IFS= read -r kernel_signature; do
    printf '%s\n' "$kernel_signature" > "$TEMP_DIR/kernel-fatal-single.log"
    apo_classify_output "$TEMP_DIR/kernel-fatal-single.log" kernel
    [[ $APO_LAST_CLASS == STABILITY_FAILURE ]]
done < "$FIXTURES/kernel-fatal-signatures.log"
printf '%s\n' 'kernel: rcu: Hierarchical RCU implementation.' > "$TEMP_DIR/kernel-benign-rcu.log"
apo_classify_output "$TEMP_DIR/kernel-benign-rcu.log" kernel
[[ $APO_LAST_CLASS == HARNESS_FAILURE ]]
apo_classify_output "$FIXTURES/black-null-display.log" display
[[ $APO_LAST_CLASS == BOOT_FAILURE ]]
apo_classify_output "$FIXTURES/missing-audio.log" audio
[[ $APO_LAST_CLASS == BOOT_FAILURE ]]
printf '%s\n' 'Timeout, server fixture not responding.' > "$TEMP_DIR/ssh-timeout.log"
apo_classify_output "$TEMP_DIR/ssh-timeout.log" stress
[[ $APO_LAST_CLASS == HARNESS_FAILURE ]]
[[ $APO_LAST_REASON == 'The worker failed without a structured result.' ]]
[[ $APO_LAST_RESULT_STRUCTURED == 0 ]]
printf 'test_classify: PASS\n'
