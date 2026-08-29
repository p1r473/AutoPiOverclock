#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
APO_ROOT=$ROOT
APO_COMMAND=run
source "$ROOT/lib/common.sh"
source "$ROOT/lib/config.sh"
source "$ROOT/lib/state.sh"
source "$ROOT/lib/progress.sh"

APO_STATE=()
APO_CFG=(
    [CANDIDATE_DURATION_S]=600
    [CANDIDATE_BOOTS]=2
    [FINAL_DURATION_S]=28800
    [FINAL_BOOTS]=3
)
APO_AUTO_GENERATED_CANDIDATES=1
APO_AUTO_CANDIDATES_PENDING=1
APO_NEED_GPU=0
APO_REQUIRE_GPU_STRESS=1
APO_EDGE_CPU_24H=0
APO_MANUAL_TEST=0
APO_CPU_CANDIDATES=()
APO_GPU_CANDIDATES=()
apo_state_set PHASE PREPARE
apo_state_set SUBPHASE INITIAL
[[ $(apo_progress_estimate_remaining_tests) == 27 ]]
[[ $(apo_progress_qualification_cost) == 7560 ]]
[[ $(apo_progress_final_full_cost 28800) == 29280 ]]
[[ $(apo_progress_format_duration 45) == 45s ]]
[[ $(apo_progress_format_duration 452) == 7m32s ]]
[[ $(apo_progress_format_duration 22320) == 6h12m ]]
[[ $(apo_progress_format_duration 90000) == 1d01h00m ]]

APO_AUTO_GENERATED_CANDIDATES=0
APO_AUTO_CANDIDATES_PENDING=0
APO_MANUAL_TEST=1
APO_MANUAL_DURATION_S=600
APO_CFG[CPU_CANDIDATES]=3100
APO_CFG[GPU_CANDIDATES]=1150
APO_CPU_CANDIDATES=(3100)
APO_GPU_CANDIDATES=(1150)
APO_NEED_GPU=1
apo_state_set PHASE MANUAL_TEST
apo_state_set SUBPHASE manual-cpu-3100_gpu-1150
apo_state_set PROGRESS_STRESS_LABEL manual-cpu-3100_gpu-1150-candidate
apo_state_set RUN_MAX_TEMP 65.0
APO_PROGRESS_RUN_MAX_TEMP=65.0
[[ $(apo_progress_estimate_remaining_tests) == 1 ]]

telemetry='2026-08-28 12:00:00 temp=64.2C arm=3100MHz v3d=1150MHz expected=3100/1150 throttled=0x0 fan=pwm:255,rpm:5200 elapsed=150/600s'
apo_progress_line_is_telemetry "$telemetry"
apo_progress_parse_telemetry_line "$telemetry"
[[ $APO_PROGRESS_LAST_TEMP == 64.2 ]]
[[ $APO_PROGRESS_LAST_CPU == 3100 && $APO_PROGRESS_LAST_GPU == 1150 ]]
[[ $APO_PROGRESS_LAST_THROTTLE == throttled=0x0 ]]
[[ $APO_PROGRESS_LAST_FAN == pwm:255,rpm:5200 ]]
[[ $APO_PROGRESS_STRESS_ELAPSED == 150 && $APO_PROGRESS_STRESS_DURATION == 600 ]]

APO_RAW_TARGET=monkeebutt
APO_PROGRESS_FORCE=1
APO_PROGRESS_SESSION_BASE_S=300
APO_PROGRESS_SESSION_EPOCH=$(date +%s)
COLUMNS=240
progress_line=$(apo_progress_render 150 600 2>&1)
[[ $progress_line == *monkeebutt* ]]
[[ $progress_line == *'current 7m30s left'* ]]
[[ $progress_line == *'tests ~1 left'* ]]
[[ $progress_line == *'3100/1150MHz'* ]]
[[ $progress_line == *'64.2C max=65.0C'* ]]
[[ $progress_line == *'throttled=0x0'* ]]
[[ $progress_line == *'fan=pwm:255,rpm:5200'* ]]
[[ $progress_line == *'manual-cpu-3100 gpu-1150'* ]]

COLUMNS=60
compact_line=$(apo_progress_render 150 600 2>&1)
(( ${#compact_line} <= 61 ))
[[ $compact_line != *$'\n'* ]]

# Signal/exit cleanup clears the active line once and disables every later
# logging callback from repainting it during potentially long normal recovery.
SHUTDOWN_OUTPUT=$(mktemp)
APO_PROGRESS_LINE_ACTIVE=1
APO_PROGRESS_LINE_WIDTH=240
APO_PROGRESS_SHUTTING_DOWN=0
{
    apo_progress_begin_shutdown
    apo_progress_after_output
} 2> "$SHUTDOWN_OUTPUT"
[[ $APO_PROGRESS_SHUTTING_DOWN == 1 ]]
[[ $APO_PROGRESS_LINE_ACTIVE == 0 && $APO_PROGRESS_LINE_WIDTH == 0 ]]
if grep -Fq monkeebutt "$SHUTDOWN_OUTPUT"; then
    echo 'shutdown logging repainted the progress line' >&2
    exit 1
fi
rm -f "$SHUTDOWN_OUTPUT"

if apo_progress_line_is_telemetry 'ordinary worker output without elapsed'; then
    echo 'ordinary worker output was mistaken for progress telemetry' >&2
    exit 1
fi

printf 'test_progress: PASS\n'
