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
APO_SWEEP_DOMAIN=all
APO_SELECTION_POLICY=refined-max-25
APO_CPU_CANDIDATES=()
APO_GPU_CANDIDATES=()
apo_state_set PHASE PREPARE
apo_state_set SUBPHASE INITIAL
[[ $(apo_progress_estimate_remaining_tests) == 23 ]]

# A one-domain continuation never budgets a sweep or qualification for the
# held applied domain. It still budgets one combined final validation.
APO_SWEEP_DOMAIN=cpu
apo_state_set CFG_SWEEP_DOMAIN cpu
apo_state_set CFG_SELECTION_POLICY refined-max-25
[[ $(apo_progress_estimate_remaining_tests) == 13 ]]
APO_SWEEP_DOMAIN=gpu
apo_state_set CFG_SWEEP_DOMAIN gpu
[[ $(apo_progress_estimate_remaining_tests) == 11 ]]
APO_SWEEP_DOMAIN=all
apo_state_set CFG_SWEEP_DOMAIN all
[[ $(apo_progress_qualification_cost) == 7560 ]]
[[ $(apo_progress_final_full_cost 28800) == 29280 ]]
APO_QUALIFICATION_DURATION_S=3600
[[ $(apo_progress_qualification_cost) == 3960 ]]
APO_QUALIFICATION_DURATION_S=$APO_DEFAULT_QUALIFICATION_DURATION_S
[[ $(apo_progress_format_duration 45) == 45s ]]
[[ $(apo_progress_format_duration 452) == 7m32s ]]
[[ $(apo_progress_format_duration 22320) == 6h12m ]]
[[ $(apo_progress_format_duration 90000) == 1d01h00m ]]

# The default edge-first policy budgets one long test, not edge plus floor.
# A floor workload is added dynamically only after a safe edge rejection.
APO_CFG[FINAL_DURATION_S]=86400
APO_EDGE_DURATION_S=86400
APO_EDGE_CPU_24H=1
APO_EDGE_ORDER=edge-first
[[ $(apo_progress_initial_final_sequence_cost) == 86880 ]]
[[ $(apo_progress_future_validation_tests) == 1 ]]
apo_state_set PHASE FINAL_VALIDATION
apo_state_set FINAL_STAGE ''
apo_state_set EDGE_CPU_STATUS NOT_REQUESTED
[[ $(apo_progress_estimate_remaining_tests) == 1 ]]
[[ $(apo_progress_final_remaining 0) == 86880 ]]
apo_state_set EDGE_CPU_STATUS REJECTED
[[ $(apo_progress_final_remaining 0) == 86880 ]]
APO_EDGE_ORDER=floor-first
apo_state_set EDGE_CPU_STATUS NOT_REQUESTED
[[ $(apo_progress_initial_final_sequence_cost) == 173760 ]]
[[ $(apo_progress_future_validation_tests) == 2 ]]
APO_EDGE_CPU_24H=0
APO_EDGE_ORDER=floor-first
APO_CFG[FINAL_DURATION_S]=28800

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
COLUMNS=300
progress_file=$(mktemp)
APO_PROGRESS_LINE_ACTIVE=0
apo_progress_render 150 600 2> "$progress_file"
progress_line=$(< "$progress_file")
[[ $progress_line == *monkeebutt* ]]
[[ $progress_line == *'current 7m30s left'* ]]
[[ $progress_line == *'tests ~1 left'* ]]
[[ $progress_line == *'CPU: 3100MHz | GPU: 1150MHz'* ]]
[[ $progress_line == *'64.2C max=65.0C'* ]]
[[ $progress_line == *'throttled=0x0'* ]]
[[ $progress_line == *'fan=pwm:255,rpm:5200'* ]]
[[ $progress_line == *'manual-cpu-3100 gpu-1150'* ]]

COLUMNS=200
APO_PROGRESS_LINE_ACTIVE=0
apo_progress_render 150 600 2> "$progress_file"
medium_line=$(< "$progress_file")
[[ $medium_line == *'CPU: 3100 | GPU: 1150'* ]]
[[ $medium_line != *'fan='* ]]

COLUMNS=60
APO_PROGRESS_LINE_ACTIVE=0
apo_progress_render 150 600 2> "$progress_file"
compact_line=$(< "$progress_file")
# Every paint replaces only the current logical row and parks at column one.
# It does not reserve another row or depend on vertical cursor movement.
progress_control=$'\033[?7l\033[1G\033[2K'
progress_restore=$'\033[1G\033[?7h'
[[ $compact_line == "$progress_control"*"$progress_restore" ]]
compact_payload=${compact_line#"$progress_control"}
compact_payload=${compact_payload%"$progress_restore"}
(( ${#compact_payload} <= COLUMNS - APO_PROGRESS_RIGHT_MARGIN ))
[[ $compact_line != *$'\r'* ]]
[[ $compact_line != *$'\n'* ]]
[[ $compact_line != *$'\033[1A'* ]]
[[ $compact_line != *$'\033[1B'* ]]

# A tmux pane can retain a wide logical PTY while a phone attaches with a much
# narrower client viewport. The renderer must use the smallest attached client
# width without changing tmux state or changing the non-tmux fallback.
tmux() {
    case ${1:-} in
        display-message) printf '$fixture-session\n' ;;
        list-clients) printf '%s\n' "${APO_TEST_TMUX_CLIENT_WIDTHS:-}" ;;
        *) return 1 ;;
    esac
}
TMUX=fixture-socket
TMUX_PANE=%7
COLUMNS=300
APO_TEST_TMUX_CLIENT_WIDTHS=$'320\n90'
[[ $(apo_progress_tmux_min_client_columns) == 90 ]]
[[ $(apo_progress_terminal_columns) == 90 ]]
APO_PROGRESS_LINE_ACTIVE=0
apo_progress_render 150 600 2> "$progress_file"
tmux_client_line=$(< "$progress_file")
tmux_client_payload=${tmux_client_line#"$progress_control"}
tmux_client_payload=${tmux_client_payload%"$progress_restore"}
(( ${#tmux_client_payload} <= 90 - APO_PROGRESS_RIGHT_MARGIN ))
[[ $tmux_client_line != *$'\n'* ]]
[[ $tmux_client_line != *$'\r'* ]]
[[ $tmux_client_line != *$'\033[1A'* ]]
[[ $tmux_client_line != *$'\033[1B'* ]]
unset TMUX TMUX_PANE APO_TEST_TMUX_CLIENT_WIDTHS
unset -f tmux
COLUMNS=123
[[ $(apo_progress_terminal_columns) == 123 ]]

# A pane width large enough to select the old verbose layout, but small enough
# to make that content brush the right edge, now chooses the medium layout.
APO_PROGRESS_LINE_ACTIVE=0
COLUMNS=240
apo_progress_render 150 600 2> "$progress_file"
edge_width_output=$(< "$progress_file")
[[ $edge_width_output == *'CPU: 3100 | GPU: 1150'* ]]
[[ $edge_width_output != *'fan='* ]]

# Reproduce the reported Byobu failure shape: paint on a narrow phone viewport,
# expand to a wide client, then narrow it again while the same row stays active.
# All three updates must remain horizontal, newline-free current-row repaints.
APO_PROGRESS_LINE_ACTIVE=0
repaint_file=$(mktemp)
{
    COLUMNS=60
    apo_progress_render 150 600
    COLUMNS=300
    apo_progress_render 240 600
    COLUMNS=60
    apo_progress_render 300 600
} 2> "$repaint_file"
repaint_output=$(< "$repaint_file")
[[ $repaint_output == *'CPU: 3100MHz | GPU: 1150MHz'* ]]
[[ $(grep -oF $'\033[?7l' <<< "$repaint_output" | wc -l) == 3 ]]
[[ $(grep -oF $'\033[?7h' <<< "$repaint_output" | wc -l) == 3 ]]
[[ $(grep -oF $'\033[2K' <<< "$repaint_output" | wc -l) == 3 ]]
[[ $(grep -oF $'\033[1G' <<< "$repaint_output" | wc -l) == 6 ]]
[[ $repaint_output != *$'\n'* ]]
[[ $repaint_output != *$'\r'* ]]
[[ $repaint_output != *$'\033[1A'* ]]
[[ $repaint_output != *$'\033[1B'* ]]

# Clearing for ordinary output advances the terminal only for that output's
# real newline, then the progress renderer takes over the new current row.
APO_PROGRESS_LINE_ACTIVE=0
stream_file=$(mktemp)
{
    COLUMNS=60
    apo_progress_render 150 600
    apo_progress_clear_line
    printf 'ordinary worker output\n' >&2
    COLUMNS=300
    apo_progress_render 240 600
} 2> "$stream_file"
stream_output=$(< "$stream_file")
stream_without_newline=${stream_output//$'\n'/}
(( ${#stream_output} - ${#stream_without_newline} == 1 ))
[[ $stream_output == *'ordinary worker output'* ]]
[[ $stream_output == *'CPU: 3100MHz | GPU: 1150MHz'* ]]
[[ $stream_output != *$'\r'* ]]
[[ $stream_output != *$'\033[1A'* ]]
[[ $stream_output != *$'\033[1B'* ]]

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
shutdown_bytes=$(wc -c < "$SHUTDOWN_OUTPUT")
progress_clear=$'\033[?7l\033[1G\033[2K\033[1G\033[?7h'
(( shutdown_bytes == ${#progress_clear} ))
rm -f "$SHUTDOWN_OUTPUT" "$progress_file" "$repaint_file" "$stream_file"

if apo_progress_line_is_telemetry 'ordinary worker output without elapsed'; then
    echo 'ordinary worker output was mistaken for progress telemetry' >&2
    exit 1
fi

printf 'test_progress: PASS\n'
