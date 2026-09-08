#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
APO_ROOT=$ROOT
APO_COMMAND=run
source "$ROOT/lib/common.sh"
source "$ROOT/lib/config.sh"
source "$ROOT/lib/state.sh"
source "$ROOT/lib/progress.sh"

# Width fixtures must not inherit the invoking developer's real Byobu/tmux
# session. Individual tmux cases install their own deterministic stub below.
unset TMUX TMUX_PANE

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
APO_NORMAL_CPU=2400
APO_NORMAL_GPU=960
APO_AUTO_BASELINE_CPU=2400
APO_AUTO_BASELINE_GPU=960
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
APO_EDGE_ORDER='edge-first'
[[ $(apo_progress_initial_final_sequence_cost) == 86880 ]]
[[ $(apo_progress_future_validation_tests) == 1 ]]
apo_state_set PHASE FINAL_VALIDATION
apo_state_set FINAL_STAGE ''
apo_state_set EDGE_CPU_STATUS NOT_REQUESTED
[[ $(apo_progress_estimate_remaining_tests) == 1 ]]
[[ $(apo_progress_final_remaining 0) == 86880 ]]
apo_state_set EDGE_CPU_STATUS REJECTED
[[ $(apo_progress_final_remaining 0) == 86880 ]]
APO_EDGE_ORDER='floor-first'
apo_state_set EDGE_CPU_STATUS NOT_REQUESTED
[[ $(apo_progress_initial_final_sequence_cost) == 173760 ]]
[[ $(apo_progress_future_validation_tests) == 2 ]]
APO_EDGE_CPU_24H=0
APO_EDGE_ORDER='floor-first'
APO_CFG[FINAL_DURATION_S]=28800

# Adaptive reverse-search progress reserves the remaining coarse descent until
# the first pass, then counts only the persisted fine-resolution suffix.
(
    APO_STATE=()
    APO_AUTO_GENERATED_CANDIDATES=1
    APO_SELECTION_POLICY=adaptive-refined-v1
    APO_NORMAL_CPU=2400
    APO_NORMAL_GPU=960
    APO_CPU_MIN=3000
    APO_GPU_MIN=1100
    APO_CPU_CANDIDATES=(3175)
    APO_GPU_CANDIDATES=(1187)
    apo_state_set CFG_SWEEP_DOMAIN all
    apo_state_set CFG_SELECTION_POLICY adaptive-refined-v1
    apo_state_set CFG_CPU_SEARCH_DIRECTION descending
    apo_state_set CFG_CPU_RESOLUTION_MHZ 25
    apo_state_set CPU_FAILURE_BOUNDARY 3175
    apo_state_set CPU_REVERSE_PASS ''
    apo_state_set CPU_REFINE_CANDIDATES ''
    apo_state_set CPU_REFINE_INDEX 0
    apo_state_set CPU_REFINE_COMPLETE 0
    [[ $(apo_progress_domain_remaining_count CPU CURRENT) == 5 ]]
    apo_state_set CPU_REVERSE_PASS 3075
    apo_state_set CPU_REFINE_CANDIDATES 3100,3125,3150
    apo_state_set CPU_REFINE_INDEX 1
    [[ $(apo_progress_domain_remaining_count CPU CURRENT) == 2 ]]

    apo_state_set CFG_GPU_SEARCH_DIRECTION descending
    apo_state_set CFG_GPU_RESOLUTION_MHZ 10
    apo_state_set GPU_FAILURE_BOUNDARY 1187
    apo_state_set GPU_REVERSE_PASS ''
    apo_state_set GPU_REFINE_CANDIDATES ''
    apo_state_set GPU_REFINE_INDEX 0
    apo_state_set GPU_REFINE_COMPLETE 0
    [[ $(apo_progress_domain_remaining_count GPU CURRENT) == 6 ]]
    apo_state_set GPU_REVERSE_PASS 1137
    apo_state_set GPU_REFINE_CANDIDATES 1147,1157,1167,1177
    apo_state_set GPU_REFINE_INDEX 2
    [[ $(apo_progress_domain_remaining_count GPU CURRENT) == 2 ]]
)

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
[[ $(apo_progress_terminal_columns 2>/dev/null) == 90 ]]
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
[[ $(apo_progress_terminal_columns 2>/dev/null) == 123 ]]

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

# Discovery streams raw APO_DATA lines instead of using the ordinary worker
# capture path.  It must clear a run-start progress row before that stream and
# leave repainting to a later logged event, otherwise the first field is
# corrupted on the user's terminal.
source "$ROOT/lib/detect.sh"
APO_DISCOVERY_FILE=$(mktemp)
APO_LOG_FILE=$(mktemp)
APO_WORKER_DEPLOYED=1
APO_REMOTE_WORKER=fixture-worker
apo_transient_read_policy_normalize() { APO_TRANSIENT_READ_ATTEMPTS=1; }
apo_remote_worker() {
    printf 'APO_DATA\tPROFILE\tZGViaWFu\nAPO_RESULT_CLASS=PASS\n'
}
apo_classify_output() {
    APO_LAST_CLASS=PASS
    APO_LAST_RESULT_STRUCTURED=1
}
apo_parse_data_file() { :; }
discovery_stream=$(mktemp)
APO_PROGRESS_SHUTTING_DOWN=0
APO_PROGRESS_LINE_ACTIVE=0
COLUMNS=80
{
    apo_progress_render 150 600
    apo_discovery_capture
} > "$discovery_stream" 2>&1
discovery_bytes=$(< "$discovery_stream")
discovery_after_clear=${discovery_bytes##*"$progress_clear"}
[[ $discovery_after_clear == $'APO_DATA\tPROFILE\tZGViaWFu\nAPO_RESULT_CLASS=PASS' ]]

# Fatal and plain output paths also erase a live progress row before writing,
# so a later preflight refusal or recovery warning cannot recreate the same
# corruption.
fatal_stream=$(mktemp)
set +e
(
    APO_PROGRESS_SHUTTING_DOWN=0
    APO_PROGRESS_LINE_ACTIVE=0
    apo_progress_render 150 600
    apo_die 'fixture refusal' 64
) 2> "$fatal_stream"
fatal_rc=$?
set -e
fatal_bytes=$(< "$fatal_stream")
fatal_after_clear=${fatal_bytes##*"$progress_clear"}
[[ $fatal_rc == 64 ]]
[[ $fatal_after_clear == 'ERROR: fixture refusal' ]]
plain_stream=$(mktemp)
APO_PROGRESS_SHUTTING_DOWN=0
APO_PROGRESS_LINE_ACTIVE=0
{
    apo_progress_render 150 600
    apo_warn_plain 'fixture warning'
} 2> "$plain_stream"
plain_bytes=$(< "$plain_stream")
plain_after_clear=${plain_bytes##*"$progress_clear"}
[[ $plain_after_clear == 'WARNING: fixture warning' ]]

# A worker or dependency upload can emit SSH diagnostics before a structured
# event exists.  The upload boundary must clear the painted row first too.
source "$ROOT/lib/ssh.sh"
upload_source=$(mktemp)
upload_stream=$(mktemp)
printf 'fixture upload\n' > "$upload_source"
APO_TRANSIENT_READ_ATTEMPTS=1
APO_TRANSIENT_READ_DELAY_SECONDS=0
apo_remote_root_stdin() {
    printf 'fixture upload diagnostic\n' >&2
    return 1
}
APO_PROGRESS_SHUTTING_DOWN=0
APO_PROGRESS_LINE_ACTIVE=0
set +e
{
    apo_progress_render 150 600
    apo_remote_upload_root "$upload_source" /tmp/autopioverclock-fixture-upload
} 2> "$upload_stream"
upload_rc=$?
set -e
upload_bytes=$(< "$upload_stream")
upload_after_clear=${upload_bytes##*"$progress_clear"}
[[ $upload_rc == 1 ]]
[[ $upload_after_clear == 'fixture upload diagnostic' ]]
rm -f "$APO_DISCOVERY_FILE" "$APO_LOG_FILE" "$discovery_stream" "$fatal_stream" "$plain_stream" \
    "$upload_source" "$upload_stream"

printf 'test_progress: PASS\n'
