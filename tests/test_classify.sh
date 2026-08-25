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
apo_classify_output "$FIXTURES/batocera-canvas-failure.log" gpu
[[ $APO_LAST_CLASS == HARNESS_FAILURE ]]
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
printf 'test_classify: PASS\n'
