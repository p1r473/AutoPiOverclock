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

# The live worker-stream consumer must run in the controller shell. Otherwise
# progress-line and telemetry updates disappear with a pipeline subshell while
# the terminal itself remains changed, which can stack a later progress paint.
APO_LOG_FILE="$TEMP_DIR/controller.log"
APO_REMOTE_WORKER=/tmp/fixture-worker
APO_PIPELINE_STATE=before
lastpipe_before=$(shopt -p lastpipe || true)
apo_candidate_log_file() { printf '%s' "$TEMP_DIR/worker.log"; }
apo_remote_worker() {
    printf 'APO_RESULT_CLASS=PASS\nAPO_RESULT_REASON_B64=%s\n' \
        "$(printf '%s' 'pipeline fixture passed' | base64 | tr -d '\n')"
}
apo_progress_capture_worker_stream() {
    local output_file=$1 line
    while IFS= read -r line || [[ -n $line ]]; do printf '%s\n' "$line" >> "$output_file"; done
    APO_PIPELINE_STATE=preserved
}
apo_progress_record_worker_result() { :; }
apo_state_set() { :; }
apo_state_save() { :; }
apo_event() { :; }
apo_run_worker_capture pipeline-fixture stress
[[ $APO_PIPELINE_STATE == preserved ]]
[[ $(shopt -p lastpipe || true) == "$lastpipe_before" ]]

# Safe read-only worker gates retry repeatedly on the same boot. Long stress
# and mutation commands are never replayed by this transport layer.
APO_TRANSIENT_WORKER_ATTEMPTS=5
APO_WORKER_BOOT_ID=01234567-89ab-cdef-0123-456789abcdef
WORKER_ATTEMPT_FILE="$TEMP_DIR/worker-attempts"
: > "$WORKER_ATTEMPT_FILE"
apo_remote_boot_id() { printf '%s' "$APO_WORKER_BOOT_ID"; }
apo_transient_read_delay() { :; }
apo_remote_worker() {
    printf x >> "$WORKER_ATTEMPT_FILE"
    if (( $(wc -c < "$WORKER_ATTEMPT_FILE") < 5 )); then return 255; fi
    printf 'APO_RESULT_CLASS=PASS\nAPO_RESULT_REASON_B64=%s\n' \
        "$(printf '%s' 'safe worker retry passed' | base64 | tr -d '\n')"
}
apo_run_worker_capture retryable-health health
[[ $(wc -c < "$WORKER_ATTEMPT_FILE") == 5 ]]
[[ $APO_LAST_CLASS == PASS ]]

: > "$WORKER_ATTEMPT_FILE"
apo_remote_worker() { printf x >> "$WORKER_ATTEMPT_FILE"; return 255; }
if apo_run_worker_capture no-stress-replay stress; then
    echo 'long stress command was replayed/accepted by the same-boot read layer' >&2
    exit 1
fi
[[ $(wc -c < "$WORKER_ATTEMPT_FILE") == 1 ]]

: > "$WORKER_ATTEMPT_FILE"
if apo_run_worker_capture no-mutation-replay prepare-candidate; then
    echo 'candidate mutation was replayed/accepted by the safe read layer' >&2
    exit 1
fi
[[ $(wc -c < "$WORKER_ATTEMPT_FILE") == 1 ]]
printf 'test_classify: PASS\n'
