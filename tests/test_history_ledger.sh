#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TEST_ROOT=$(mktemp -d "${ROOT}/.test-history-ledger.XXXXXX")
trap 'rm -rf -- "$TEST_ROOT"' EXIT

APO_ROOT=$ROOT
source "$ROOT/lib/common.sh"
source "$ROOT/lib/state.sh"
source "$ROOT/lib/candidates.sh"
source "$ROOT/lib/history.sh"

APO_TARGET_SLUG=tron
APO_REMOTE_TARGET=pi@tron
APO_PROFILE=debian
APO_GPU_KEY=v3d_freq
APO_TEST_VOLTAGE=0
APO_NORMAL_CPU=3050
APO_NORMAL_GPU=1125
APO_NORMAL_VOLTAGE=0
APO_BOOT_CONFIG=/boot/firmware/config.txt
APO_TRYBOOT_CONFIG=/boot/firmware/tryboot.txt
APO_OUTPUT_DIR="$TEST_ROOT/targets/tron/runs"
APO_HISTORY_DIR="$TEST_ROOT/targets/tron/history"
APO_SWEEP_DOMAIN=all
declare -Ag APO_DISCOVERY=(
    [MODEL]='Raspberry Pi 5 Model B'
    [COMPATIBLE]='raspberrypi,5-model-b'
    [ARCH]=aarch64
)
mkdir -p -- "$APO_OUTPUT_DIR"

source_b64=$(apo_history_encode_field final-endurance)
cpu_reason_b64=$(apo_history_encode_field 'CPU failed above the completed floor.')
gpu_reason_b64=$(apo_history_encode_field 'GPU failed above the completed floor.')
pair_reason_b64=$(apo_history_encode_field 'The combined pair failed.')
harness_reason_b64=$(apo_history_encode_field 'A controller transport failed without clock evidence.')

apo_history_reset
apo_history_record_ledger 2026-09-20T01:00:00-0400 cpu-run 3125 1125 BOOT_FAILURE CPU \
    "$source_b64" "$cpu_reason_b64" tron-cpu-run.state
apo_history_record CPU 3125 cpu-run final-endurance tron-cpu-run.state
apo_history_record_ledger 2026-09-20T01:05:00-0400 gpu-run 3050 1200 STABILITY_FAILURE GPU \
    "$source_b64" "$gpu_reason_b64" tron-gpu-run.state
apo_history_record GPU 1200 gpu-run final-endurance tron-gpu-run.state
apo_history_record_ledger 2026-09-20T01:10:00-0400 pair-run 3100 1175 STABILITY_FAILURE PAIR \
    "$source_b64" "$pair_reason_b64" tron-pair-run.state
apo_history_record PAIR 3100/1175 pair-run final-endurance tron-pair-run.state
apo_history_record_ledger 2026-09-20T01:15:00-0400 harness-run 3050 1125 HARNESS_FAILURE NONE \
    "$source_b64" "$harness_reason_b64" tron-harness-run.state
apo_history_finalize_frontiers

APO_HISTORY_RENDER_BASELINE_CPU=3050
APO_HISTORY_RENDER_BASELINE_GPU=1125
APO_HISTORY_RENDER_BASELINE_VOLTAGE=0
APO_HISTORY_SEALED_RUN_ID=completed-run
APO_HISTORY_SEALED_CPU=3050
APO_HISTORY_SEALED_GPU=1125
APO_HISTORY_SEALED_VOLTAGE=0
APO_HISTORY_SEALED_HASH=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
APO_HISTORY_SEALED_RUN_SCHEMA=$APO_CURRENT_RUN_SCHEMA
APO_HISTORY_SEALED_VALIDATION_SCHEMA=$APO_CURRENT_VALIDATION_SCHEMA
apo_history_rebuild_ledger
ledger=$APO_HISTORY_LEDGER_FILE
[[ $ledger == "$APO_HISTORY_DIR/failures.txt" ]]
[[ -f $ledger && ! -L $ledger ]]
grep -Fq 'CPU failed above the completed floor.' "$ledger"
grep -Fq 'A controller transport failed without clock evidence.' "$ledger"

# A completing run still carries its original stock baseline in APO_NORMAL_*.
# Its immediate sealed-ledger verification must use the verified final tuple.
APO_NORMAL_CPU=2400
APO_NORMAL_GPU=960
if apo_history_load_machine_ledger "$ledger" 0; then
    printf 'sealed ledger accepted the original stock baseline as the completed floor\n' >&2
    exit 1
fi
APO_HISTORY_SCAN_BASELINE_CPU=3050
APO_HISTORY_SCAN_BASELINE_GPU=1125
APO_HISTORY_SCAN_BASELINE_VOLTAGE=0
apo_history_load_machine_ledger "$ledger" 0
[[ $APO_HISTORY_SEALED_RUN_ID == completed-run ]]
[[ $APO_HISTORY_SEALED_CPU == 3050 ]]
[[ $APO_HISTORY_SEALED_GPU == 1125 ]]
APO_HISTORY_SCAN_BASELINE_CPU=''
APO_HISTORY_SCAN_BASELINE_GPU=''
APO_HISTORY_SCAN_BASELINE_VOLTAGE=''
APO_NORMAL_CPU=3050
APO_NORMAL_GPU=1125

# Complete can remove the entire runs directory. The durable machine section
# alone must reconstruct the planning boundaries and retain audit-only records.
rm -rf -- "$APO_OUTPUT_DIR"
APO_HISTORY_RENDER_BASELINE_CPU=''
APO_HISTORY_RENDER_BASELINE_GPU=''
APO_HISTORY_RENDER_BASELINE_VOLTAGE=''
apo_history_scan_retained_states
[[ $APO_HISTORY_SCANNED_STATES == 0 ]]
[[ $APO_HISTORY_ACCEPTED_STATES == 0 ]]
[[ $APO_HISTORY_MACHINE_RECORDS == 4 ]]
[[ $APO_HISTORY_CPU_FAILURE_BOUNDARY == 3125 ]]
[[ $APO_HISTORY_GPU_FAILURE_BOUNDARY == 1200 ]]
[[ $APO_HISTORY_PAIR_FRONTIERS == 3100/1175 ]]
[[ $APO_HISTORY_EVIDENCE_COUNT == 3 ]]

# A matching live completed result adopts the sealed ledger as its protected
# floor. A hash mismatch fails closed and does not silently fall back to stock.
APO_COMMAND=run
APO_AUTO_GENERATED_CANDIDATES=1
APO_SWEEP_DOMAIN=all
APO_PERMANENT_TUNING_PROVENANCE='verified-applied'
APO_PERMANENT_TUNING_EVIDENCE=applied-run
APO_PERMANENT_CONFIG_HASH=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
apo_history_adopt_completed_baseline
[[ $APO_HISTORY_COMPLETED_BASELINE_ADOPTED == 1 ]]
[[ $APO_PERMANENT_TUNING_PROVENANCE == verified-completed-ledger ]]
[[ $APO_PERMANENT_TUNING_EVIDENCE == failure-ledger-v1:* ]]
APO_PERMANENT_CONFIG_HASH=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
if apo_history_adopt_completed_baseline; then
    printf 'completed floor adoption accepted a live hash mismatch\n' >&2
    exit 1
else
    adoption_rc=$?
fi
[[ $adoption_rc == 2 ]]
[[ $APO_HISTORY_SCAN_ERROR == *'hash does not match'* ]]
APO_PERMANENT_CONFIG_HASH=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

# The loader is strict about identity, structure, canonical encoding, unique
# metadata, and data after the machine section.
APO_REMOTE_TARGET=pi@other
if apo_history_load_machine_ledger "$ledger" 1; then
    printf 'machine ledger accepted the wrong target identity\n' >&2
    exit 1
fi
APO_REMOTE_TARGET=pi@tron

trailing="$TEST_ROOT/trailing.txt"
cp -- "$ledger" "$trailing"
printf 'unexpected trailing data\n' >> "$trailing"
if apo_history_load_machine_ledger "$trailing" 1; then
    printf 'machine ledger accepted trailing data\n' >&2
    exit 1
fi

duplicate_meta="$TEST_ROOT/duplicate-meta.txt"
awk '{print; if (!done && $1 == "META") {print; done=1}}' "$ledger" > "$duplicate_meta"
if apo_history_load_machine_ledger "$duplicate_meta" 1; then
    printf 'machine ledger accepted duplicate metadata\n' >&2
    exit 1
fi

bad_base64="$TEST_ROOT/bad-base64.txt"
awk 'BEGIN{OFS="\t"} $1 == "META" && !done {$3="%%%"; done=1} {print}' "$ledger" > "$bad_base64"
if apo_history_load_machine_ledger "$bad_base64" 1; then
    printf 'machine ledger accepted malformed base64\n' >&2
    exit 1
fi

legacy="$TEST_ROOT/legacy.txt"
printf 'AutoPiOverclock retained failure ledger\nGenerated: 2026-09-20T01:00:00-0400\n' > "$legacy"
if apo_history_load_machine_ledger "$legacy" 1; then
    printf 'human-only ledger was accepted as machine history\n' >&2
    exit 1
else
    legacy_rc=$?
fi
[[ $legacy_rc == 3 ]]

# A failed render cannot replace the previously validated durable ledger.
ledger_hash_before=$(sha256sum "$ledger" | awk 'NR == 1 {print $1}')
APO_HISTORY_RENDER_BASELINE_CPU=3050
APO_HISTORY_RENDER_BASELINE_GPU=''
APO_HISTORY_RENDER_BASELINE_VOLTAGE=0
if apo_history_rebuild_ledger; then
    printf 'ledger rebuild accepted a partial baseline tuple\n' >&2
    exit 1
fi
[[ $(sha256sum "$ledger" | awk 'NR == 1 {print $1}') == "$ledger_hash_before" ]]

printf 'history ledger tests passed\n'
