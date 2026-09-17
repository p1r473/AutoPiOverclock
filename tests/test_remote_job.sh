#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
APO_ROOT=$ROOT
source "$ROOT/lib/common.sh"
source "$ROOT/lib/state.sh"
# Controller fixtures provide their own checkpoint stubs. Keep the pure Bash
# codec while preventing an unrelated real checkpoint attempt with no state file.
unset -f apo_state_save_try

if [[ ! -r /proc/sys/kernel/random/boot_id ]] || ! command -v setsid >/dev/null 2>&1 ||
   ! command -v timeout >/dev/null 2>&1 || ! timeout --help 2>&1 | grep -Eq '(^|[[:space:]])-k([,[:space:]]|$)'; then
    printf 'test_remote_job: SKIP (requires Linux boot IDs, setsid, and a timeout implementation with -k)\n'
    exit 0
fi

TEMP_DIR=$(mktemp -d)
test_failure_trace() {
    local command_rc=$1 source_line=$2 failed_command=$3
    trap - ERR
    printf 'test_remote_job: FAIL rc=%s line=%s command=%q\n' "$command_rc" "$source_line" "$failed_command" >&2
    return "$command_rc"
}
cleanup() {
    local pid
    for pid_file in "$TEMP_DIR"/run/jobs/*/supervisor.pid; do
        [[ -f $pid_file ]] || continue
        pid=$(sed -n '1p' "$pid_file" 2>/dev/null || true)
        [[ $pid =~ ^[1-9][0-9]*$ && $pid != "$$" ]] && kill "$pid" 2>/dev/null || true
    done
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT
trap 'test_failure_trace "$?" "$LINENO" "$BASH_COMMAND"' ERR

WORKER=$TEMP_DIR/worker.sh
cat >"$WORKER" <<'WORKER'
#!/usr/bin/env bash
set -u
[[ ${1:-} == stress ]] || exit 2
case ${2:-} in
    pass)
        sleep "${3:-1}"
        printf 'APO_RESULT_CLASS=PASS\n'
        printf 'APO_RESULT_REASON_B64=ZGV0YWNoZWQgam9iIHBhc3NlZA==\n'
        ;;
    deadline)
        sleep "${3:-10}"
        ;;
    *) exit 2 ;;
esac
WORKER
chmod 700 "$WORKER"

HELPER=$ROOT/tools/remote-stress-job.sh
if grep -Eq '^[[:space:]]*set[[:space:]]+[+-]e([[:space:]]|$)' "$HELPER"; then
    echo 'target job helper still mutates its global error mode' >&2
    exit 1
fi
BOOT_ID=$(< /proc/sys/kernel/random/boot_id)
TOKEN=$(printf 'a%.0s' {1..64})
SPEC=$(printf 'b%.0s' {1..64})
JOB_ID=job-${TOKEN:0:32}
RUN_ROOT=$TEMP_DIR/run
APO_TEST_CAPTURE_RC=0
capture_command_output() {
    local output_name=$1 captured_output=''
    shift
    if captured_output=$("$@"); then APO_TEST_CAPTURE_RC=0; else APO_TEST_CAPTURE_RC=$?; fi
    printf -v "$output_name" '%s' "$captured_output"
    return 0
}

# The long-lived follow coprocess must become the transport itself. If a Bash
# wrapper remains above it, controller shutdown can kill the wrapper and orphan
# its SSH child while the target job remains active.
(
    # shellcheck source=lib/ssh.sh
    source "$ROOT/lib/ssh.sh"
    # shellcheck source=lib/remote_job.sh
    source "$ROOT/lib/remote_job.sh"
    TEST_SLEEP=$(type -P sleep)
    TEST_SLEEP_REAL=$(readlink -f -- "$TEST_SLEEP")
    APO_REMOTE_JOB_HELPER=/tmp/autopioverclock-test-remote-job
    apo_remote_root() { "$TEST_SLEEP" 300; }
    apo_remote_root_exec() { exec "$TEST_SLEEP" 300; }
    coproc APO_REMOTE_JOB_FOLLOW_COPROC { apo_remote_job_follow_command fixture; }
    APO_REMOTE_JOB_FOLLOW_PID=${APO_REMOTE_JOB_FOLLOW_COPROC_PID:-}
    APO_REMOTE_JOB_FOLLOW_FD=${APO_REMOTE_JOB_FOLLOW_COPROC[0]:-}
    APO_REMOTE_JOB_FOLLOW_INPUT_FD=${APO_REMOTE_JOB_FOLLOW_COPROC[1]:-}
    FOLLOW_EXEC_READY=0
    for _ in {1..50}; do
        if [[ -r /proc/${APO_REMOTE_JOB_FOLLOW_PID}/exe &&
              $(readlink -f -- "/proc/${APO_REMOTE_JOB_FOLLOW_PID}/exe") == "$TEST_SLEEP_REAL" ]]; then
            FOLLOW_EXEC_READY=1
            break
        fi
        sleep 0.02
    done
    [[ $FOLLOW_EXEC_READY == 1 ]]
    [[ -z $(pgrep -P "$APO_REMOTE_JOB_FOLLOW_PID" 2>/dev/null || true) ]]
    FOLLOW_EXEC_PID=$APO_REMOTE_JOB_FOLLOW_PID
    apo_remote_job_follow_transport_cleanup
    ! kill -0 "$FOLLOW_EXEC_PID" 2>/dev/null
)

START_OUTPUT=''
capture_command_output START_OUTPUT "$HELPER" start "$RUN_ROOT" "$JOB_ID" "$TOKEN" "$SPEC" "$BOOT_ID" 1 "$WORKER" pass 1
[[ $START_OUTPUT =~ ^APO_JOB_STARTED$'\t'(RUNNING|COMPLETE)$'\t'[0-9]+$ ]]
[[ $APO_TEST_CAPTURE_RC == 0 ]]
grep -Eq '^START_MONOTONIC_SECONDS=[0-9]+$' "$RUN_ROOT/jobs/$JOB_ID/manifest"
capture_command_output FOLLOW_OUTPUT "$HELPER" follow "$RUN_ROOT" "$JOB_ID" "$TOKEN" "$SPEC"
grep -q '^APO_JOB_COMPLETE' <<<"$FOLLOW_OUTPUT"
[[ $APO_TEST_CAPTURE_RC == 0 ]]
capture_command_output FETCHED "$HELPER" fetch "$RUN_ROOT" "$JOB_ID" "$TOKEN" "$SPEC"
grep -q '^APO_RESULT_CLASS=PASS$' <<<"$FETCHED"
[[ $APO_TEST_CAPTURE_RC == 0 ]]

capture_command_output START_AGAIN "$HELPER" start "$RUN_ROOT" "$JOB_ID" "$TOKEN" "$SPEC" "$BOOT_ID" 1 "$WORKER" pass 1
grep -Eq $'^APO_JOB_STARTED\tCOMPLETE\t[0-9]+$' <<<"$START_AGAIN"
[[ $APO_TEST_CAPTURE_RC == 0 ]]

# The target supervisor must retain valid size and hash output even if the
# observed utility status is contradictory, then persist failure-only evidence.
REAL_WC=$(command -v wc)
REAL_SHA256SUM=$(command -v sha256sum)
MOCK_BIN=$TEMP_DIR/mock-bin
mkdir "$MOCK_BIN"
cat >"$MOCK_BIN/wc" <<'MOCK_WC'
#!/usr/bin/env bash
"$APO_TEST_REAL_WC" "$@"
exit 23
MOCK_WC
cat >"$MOCK_BIN/sha256sum" <<'MOCK_SHA'
#!/usr/bin/env bash
"$APO_TEST_REAL_SHA256SUM" "$@"
exit 23
MOCK_SHA
chmod 700 "$MOCK_BIN/wc" "$MOCK_BIN/sha256sum"
STATUS_TOKEN=$(printf '9%.0s' {1..64})
STATUS_SPEC=$(printf '8%.0s' {1..64})
STATUS_JOB=job-${STATUS_TOKEN:0:32}
APO_TEST_REAL_WC=$REAL_WC APO_TEST_REAL_SHA256SUM=$REAL_SHA256SUM PATH="$MOCK_BIN:$PATH" \
    capture_command_output STATUS_START "$HELPER" start "$RUN_ROOT" "$STATUS_JOB" "$STATUS_TOKEN" \
        "$STATUS_SPEC" "$BOOT_ID" 1 "$WORKER" pass 1
[[ $STATUS_START =~ ^APO_JOB_STARTED$'\t'(RUNNING|COMPLETE)$'\t'[0-9]+$ ]]
[[ $APO_TEST_CAPTURE_RC == 0 ]]
capture_command_output STATUS_FOLLOW "$HELPER" follow "$RUN_ROOT" "$STATUS_JOB" "$STATUS_TOKEN" "$STATUS_SPEC"
grep -q '^APO_JOB_COMPLETE' <<<"$STATUS_FOLLOW"
[[ $APO_TEST_CAPTURE_RC == 0 ]]
grep -Fq 'target-job-child-status: operation=complete-size rc=23 output_valid=1 reconciled=1' \
    "$RUN_ROOT/jobs/$STATUS_JOB/child-status.log"
grep -Fq 'target-job-child-status: operation=complete-sha256 rc=23 output_valid=1 reconciled=1' \
    "$RUN_ROOT/jobs/$STATUS_JOB/child-status.log"

# A loaded target can take longer than one second to establish the detached
# supervisor. The launcher must wait at low frequency for owned evidence.
REAL_SETSID=$(command -v setsid)
SLOW_BIN=$TEMP_DIR/slow-bin
mkdir "$SLOW_BIN"
cat >"$SLOW_BIN/setsid" <<'MOCK_SETSID'
#!/usr/bin/env bash
sleep 3
exec "$APO_TEST_REAL_SETSID" "$@"
MOCK_SETSID
chmod 700 "$SLOW_BIN/setsid"
SLOW_TOKEN=$(printf '7%.0s' {1..64})
SLOW_SPEC=$(printf '6%.0s' {1..64})
SLOW_JOB=job-${SLOW_TOKEN:0:32}
APO_TEST_REAL_SETSID=$REAL_SETSID PATH="$SLOW_BIN:$PATH" \
    capture_command_output SLOW_START "$HELPER" start "$RUN_ROOT" "$SLOW_JOB" "$SLOW_TOKEN" \
        "$SLOW_SPEC" "$BOOT_ID" 1 "$WORKER" pass 1
[[ $SLOW_START =~ ^APO_JOB_STARTED$'\t'(RUNNING|COMPLETE)$'\t'[0-9]+$ ]]
[[ $APO_TEST_CAPTURE_RC == 0 ]]
capture_command_output SLOW_FOLLOW "$HELPER" follow "$RUN_ROOT" "$SLOW_JOB" "$SLOW_TOKEN" "$SLOW_SPEC"
grep -q '^APO_JOB_COMPLETE' <<<"$SLOW_FOLLOW"
[[ $APO_TEST_CAPTURE_RC == 0 ]]
OTHER_WORKER=$TEMP_DIR/other-worker.sh
cp -- "$WORKER" "$OTHER_WORKER"
chmod 700 "$OTHER_WORKER"
if DIFFERENT_WORKER_OUTPUT=$("$HELPER" start "$RUN_ROOT" "$JOB_ID" "$TOKEN" "$SPEC" "$BOOT_ID" 1 "$OTHER_WORKER" pass 1); then
    echo 'detached job accepted a different worker path for existing ownership' >&2
    exit 1
fi
grep -q $'^APO_JOB_ERROR\texisting job worker path does not match$' <<<"$DIFFERENT_WORKER_OUTPUT"
BAD_TOKEN=$(printf 'c%.0s' {1..64})
if "$HELPER" inspect "$RUN_ROOT" "$JOB_ID" "$BAD_TOKEN" "$SPEC" >/dev/null 2>&1; then
    echo 'detached job accepted the wrong ownership token' >&2
    exit 1
fi

DEADLINE_TOKEN=$(printf 'd%.0s' {1..64})
DEADLINE_SPEC=$(printf 'e%.0s' {1..64})
DEADLINE_JOB=job-${DEADLINE_TOKEN:0:32}
APO_JOB_HARD_GRACE_SECONDS=1 "$HELPER" start "$RUN_ROOT" "$DEADLINE_JOB" "$DEADLINE_TOKEN" \
    "$DEADLINE_SPEC" "$BOOT_ID" 1 "$WORKER" deadline 10 >/dev/null
capture_command_output DEADLINE_FOLLOW "$HELPER" follow "$RUN_ROOT" "$DEADLINE_JOB" "$DEADLINE_TOKEN" "$DEADLINE_SPEC"
grep -q $'^APO_JOB_COMPLETE\t124\t' <<<"$DEADLINE_FOLLOW"
capture_command_output DEADLINE_RESULT "$HELPER" fetch "$RUN_ROOT" "$DEADLINE_JOB" "$DEADLINE_TOKEN" "$DEADLINE_SPEC"
grep -q '^APO_RESULT_CLASS=HARNESS_FAILURE$' <<<"$DEADLINE_RESULT"
grep -q '^APO_RESULT_REASON_B64=' <<<"$DEADLINE_RESULT"

STALE_TOKEN=$(printf 'f%.0s' {1..64})
STALE_SPEC=$(printf '1%.0s' {1..64})
STALE_JOB=job-${STALE_TOKEN:0:32}
STALE_DIR=$RUN_ROOT/jobs/$STALE_JOB
mkdir -p "$STALE_DIR"
cat >"$STALE_DIR/manifest" <<EOF
FORMAT=1
JOB_ID=$STALE_JOB
TOKEN=$STALE_TOKEN
SPEC_HASH=$STALE_SPEC
SOURCE_BOOT_ID=$BOOT_ID
START_EPOCH=$(date +%s)
DURATION=60
WORKER=$WORKER
EOF
printf '%s\n' "$$" >"$STALE_DIR/supervisor.pid"
capture_command_output STALE_INSPECT "$HELPER" inspect "$RUN_ROOT" "$STALE_JOB" "$STALE_TOKEN" "$STALE_SPEC"
[[ $STALE_INSPECT == APO_JOB_INSPECT$'\t'ORPHANED$'\t'* ]]

grep -Fq 'coproc APO_REMOTE_JOB_FOLLOW_COPROC' "$ROOT/lib/remote_job.sh"
grep -Fq 'apo_remote_job_follow_stream <&"$follow_fd"' "$ROOT/lib/remote_job.sh"
if grep -Eq 'apo_remote_job_(command|follow_command) follow .*\|[[:space:]]*apo_remote_job_follow_stream' \
    "$ROOT/lib/remote_job.sh"; then
    echo 'the detached-job parser still runs inside the long-lived producer pipeline' >&2
    exit 1
fi

# Valid child output is authoritative when the observed child status is
# contradictory. Both operations still reject malformed output.
(
    source "$ROOT/lib/remote_job.sh"
    # Each child-status fixture intentionally owns a subshell-local log.
    # shellcheck disable=SC2030
    APO_LOG_FILE=$TEMP_DIR/token-child-status.log
    EXPECTED_TOKEN=$(printf 'a%.0s' {1..64})
    od() { printf '%s\n' "$EXPECTED_TOKEN"; return 23; }
    observed_token=$(apo_remote_job_token)
    [[ $observed_token == "$EXPECTED_TOKEN" ]]
    grep -Fq 'remote-job-child-status: operation=token-od rc=23 output_valid=1 reconciled=1' "$APO_LOG_FILE"
)
(
    source "$ROOT/lib/remote_job.sh"
    # Each child-status fixture intentionally owns a subshell-local log.
    # shellcheck disable=SC2030
    APO_LOG_FILE=$TEMP_DIR/hash-child-status.log
    EXPECTED_HASH=$(printf 'b%.0s' {1..64})
    sha256sum() { printf '%s  %s\n' "$EXPECTED_HASH" "${*: -1}"; return 23; }
    observed_hash=$(apo_remote_job_spec_hash fixture-phase stress combined 60)
    [[ $observed_hash == "$EXPECTED_HASH" ]]
    grep -Fq 'remote-job-child-status: operation=spec-sha256 rc=23 output_valid=1 reconciled=1' "$APO_LOG_FILE"
)

# The follow transport runs for the complete target stress duration. It must
# drop its inherited copy of the controller lock while the parent controller
# keeps the authoritative lock open.
# shellcheck disable=SC2030
(
    source "$ROOT/lib/remote_job.sh"
    LOCK_FILE=$TEMP_DIR/controller-lock
    exec {APO_LOCK_FD}>"$LOCK_FILE"
    flock -n "$APO_LOCK_FD"
    TEST_LOCK_FD=$APO_LOCK_FD
    CONTROLLER_TEST_PID=$BASHPID
    APO_REMOTE_JOB_HELPER=/tmp/remote-stress-job.sh
    apo_remote_job_command() {
        if [[ -e /proc/$BASHPID/fd/$TEST_LOCK_FD ]]; then
            printf 'inherited\n'
        else
            printf 'closed\n'
        fi
        return 23
    }
    apo_remote_job_follow_stream() { IFS= read -r lock_observation; }
    lastpipe_before=$(shopt -p lastpipe || true)
    follow_fds_before=(/proc/$BASHPID/fd/*)
    lock_observation=''
    FOLLOW_STDERR_FILE=$TEMP_DIR/follow-stderr.log
    {
        apo_remote_job_follow_capture /tmp/run job-00000000000000000000000000000000 \
            "$(printf '0%.0s' {1..64})" "$(printf '1%.0s' {1..64})"
        printf 'follow-stderr-preserved\n' >&2
    } 2>"$FOLLOW_STDERR_FILE"
    grep -Fxq 'follow-stderr-preserved' "$FOLLOW_STDERR_FILE"
    [[ $lock_observation == closed ]]
    [[ $APO_REMOTE_JOB_FOLLOW_TRANSPORT_RC == 23 ]]
    [[ -z $APO_REMOTE_JOB_FOLLOW_PID && -z $APO_REMOTE_JOB_FOLLOW_FD && -z $APO_REMOTE_JOB_FOLLOW_INPUT_FD ]]
    follow_fds_after=(/proc/$BASHPID/fd/*)
    [[ ${#follow_fds_after[@]} == "${#follow_fds_before[@]}" ]]
    [[ $(shopt -p lastpipe || true) == "$lastpipe_before" ]]
    [[ -e /proc/$CONTROLLER_TEST_PID/fd/$TEST_LOCK_FD ]]
    if (
        exec {probe_fd}>"$LOCK_FILE"
        flock -n "$probe_fd"
    ); then
        echo 'follow transport released the parent controller lock' >&2
        exit 1
    fi
    exec {APO_LOCK_FD}>&-
)

# Exit recovery closes and terminates a live controller-side follow transport.
# It must not wait for the observer's original lifetime.
(
    source "$ROOT/lib/remote_job.sh"
    TEST_SLEEP=$(type -P sleep)
    apo_remote_job_command() { exec "$TEST_SLEEP" 60; }
    coproc APO_REMOTE_JOB_FOLLOW_COPROC {
        apo_remote_job_follow_command fixture
    }
    APO_REMOTE_JOB_FOLLOW_PID=${APO_REMOTE_JOB_FOLLOW_COPROC_PID:-}
    APO_REMOTE_JOB_FOLLOW_FD=${APO_REMOTE_JOB_FOLLOW_COPROC[0]:-}
    APO_REMOTE_JOB_FOLLOW_INPUT_FD=${APO_REMOTE_JOB_FOLLOW_COPROC[1]:-}
    cleanup_started=$SECONDS
    apo_remote_job_follow_transport_cleanup
    (( SECONDS - cleanup_started < 5 ))
    [[ -z $APO_REMOTE_JOB_FOLLOW_PID && -z $APO_REMOTE_JOB_FOLLOW_FD && -z $APO_REMOTE_JOB_FOLLOW_INPUT_FD ]]
)

# The controller globals are intentionally isolated inside this fixture.
# shellcheck disable=SC2030
(
    declare -A TEST_STATE=()
    source "$ROOT/lib/remote_job.sh"
    CONTROLLER_OUTPUT=$TEMP_DIR/controller-output.log
    APO_LOG_FILE=$TEMP_DIR/controller-child-status.log
    START_COUNT_FILE=$TEMP_DIR/controller-start-count
    FOLLOW_COUNT_FILE=$TEMP_DIR/controller-follow-count
    printf '0\n' >"$START_COUNT_FILE"
    printf '0\n' >"$FOLLOW_COUNT_FILE"
    TEST_TOKEN=$(printf '2%.0s' {1..64})
    TEST_JOB=job-${TEST_TOKEN:0:32}
    TEST_BOOT=12345678-1234-1234-1234-123456789abc
    TEST_PHASE=controller-reconnect
    TEST_SPEC=$(apo_remote_job_spec_hash "$TEST_PHASE" stress 2500 1)
    TEST_STATE[REMOTE_STRESS_STATUS]=RUNNING
    TEST_STATE[REMOTE_STRESS_JOB_ID]=$TEST_JOB
    TEST_STATE[REMOTE_STRESS_TOKEN]=$TEST_TOKEN
    TEST_STATE[REMOTE_STRESS_SPEC_HASH]=$TEST_SPEC
    TEST_STATE[REMOTE_STRESS_SOURCE_BOOT_ID]=$TEST_BOOT
    TEST_STATE[REMOTE_STRESS_PHASE]=$TEST_PHASE
    TEST_STATE[REMOTE_STRESS_DURATION_S]=1
    TEST_STATE[REMOTE_STRESS_START_EPOCH]=''
    TEST_STATE[REMOTE_STRESS_LAST_SEEN_EPOCH]=''
    APO_REMOTE_WORK_DIR=/tmp/controller-reconnect
    APO_REMOTE_WORKER=/tmp/controller-reconnect/worker.sh
    APO_REMOTE_JOB_HELPER=/tmp/controller-reconnect/remote-stress-job.sh
    APO_TRANSIENT_WORKER_ATTEMPTS=5

    apo_state_get() { printf '%s' "${TEST_STATE[$1]:-${2-}}"; }
    apo_state_set() {
        # State-key validation uses BASH_REMATCH in production. Deliberately
        # clobber it so callers must copy protocol captures before state writes.
        [[ $1 =~ ^[A-Z][A-Z0-9_]*$ ]]
        TEST_STATE[$1]=$2
    }
    apo_state_save() { :; }
    apo_remote_boot_id_once() { printf '%s' "$TEST_BOOT"; }
    apo_recovery_wait_event() { :; }
    apo_transient_read_delay() { :; }
    apo_progress_render() { :; }
    apo_progress_line_is_telemetry() { return 1; }
    apo_validate_remote_job_state
    apo_remote_job_command() {
        local operation=$1 count
        if [[ $operation == start ]]; then
            count=$(<"$START_COUNT_FILE")
            count=$((count + 1))
            printf '%s\n' "$count" >"$START_COUNT_FILE"
            if (( count < 3 )); then
                printf 'simulated SSH launch disconnect\n' >&2
                return 255
            fi
            printf 'APO_JOB_STARTED\tRUNNING\t100\n'
            if (( count == 3 )); then return 23; fi
            return 0
        fi
        count=$(<"$FOLLOW_COUNT_FILE")
        count=$((count + 1))
        printf '%s\n' "$count" >"$FOLLOW_COUNT_FILE"
        if (( count == 1 )); then
            printf 'APO_JOB_HEARTBEAT\tRUNNING\t100\t100\t1\t%s\t0\t\n' "$TEST_BOOT"
            printf 'APO_JOB_HEART'
            printf 'simulated SSH follow disconnect\n' >&2
            return 255
        fi
        printf 'APO_JOB_HEARTBEAT\tCOMPLETE\t101\t100\t1\t%s\t0\t\n' "$TEST_BOOT"
        printf 'APO_JOB_COMPLETE\t0\t0\t%s\t101\t%s\n' "$(printf '3%.0s' {1..64})" "$TEST_BOOT"
    }
    apo_remote_job_fetch_complete() {
        printf 'APO_RESULT_CLASS=PASS\n' >"$1"
        APO_REMOTE_STRESS_RC=0
        apo_remote_job_clear_state
    }

    apo_run_remote_stress_capture "$TEST_PHASE" stress "$CONTROLLER_OUTPUT" 2500 1
    [[ $(<"$START_COUNT_FILE") == 4 ]]
    [[ $(<"$FOLLOW_COUNT_FILE") == 2 ]]
    [[ ${TEST_STATE[REMOTE_STRESS_STATUS]} == IDLE ]]
    grep -Fq 'remote-job-child-status: operation=detached-start rc=23 output_valid=1 reconciled=1' "$APO_LOG_FILE"
)

# Only a workload telemetry sample can populate confirmed elapsed time. A
# target-side heartbeat without that sample still proves liveness, not work.
(
    declare -A TEST_STATE=()
    source "$ROOT/lib/remote_job.sh"
    TEST_BOOT=12345678-1234-1234-1234-123456789abc
    TEST_STATE[REMOTE_STRESS_SOURCE_BOOT_ID]=$TEST_BOOT
    TEST_STATE[REMOTE_STRESS_DURATION_S]=100
    TEST_STATE['REMOTE_STRESS_PHASE']='telemetry-credit'
    TEST_STATE[REMOTE_STRESS_SPEC_HASH]=$(printf '9%.0s' {1..64})

    apo_state_get() { printf '%s' "${TEST_STATE[$1]:-${2-}}"; }
    apo_state_set() { TEST_STATE[$1]=$2; }
    apo_state_save() { :; }
    apo_decode_b64() { printf '%s' "$1" | base64 -d; }
    apo_progress_line_is_telemetry() { return 0; }
    apo_progress_parse_telemetry_line() { :; }
    apo_progress_render() { :; }

    TELEMETRY=$(printf 'fixture temp=40C arm=2500MHz v3d=960MHz expected=2500/960 throttled=0x0 elapsed=35/100s' | base64 | tr -d '\n')
    apo_remote_job_follow_stream <<<"$(printf 'APO_JOB_HEARTBEAT\tRUNNING\t1035\t1000\t100\t%s\t0\t%s' "$TEST_BOOT" "$TELEMETRY")"
    [[ ${TEST_STATE[REMOTE_STRESS_CONFIRMED_ELAPSED_S]} == 35 ]]
    [[ ${TEST_STATE[REMOTE_STRESS_CONFIRMED_SAMPLES]} == 1035:35 ]]
    [[ ${TEST_STATE[REMOTE_STRESS_LAST_SEEN_EPOCH]} == 1035 ]]

    # A repeated heartbeat keeps the first observation time for the unchanged
    # elapsed value while still advancing the independent liveness timestamp.
    apo_remote_job_follow_stream <<<"$(printf 'APO_JOB_HEARTBEAT\tRUNNING\t1036\t1000\t100\t%s\t0\t%s' "$TEST_BOOT" "$TELEMETRY")"
    [[ ${TEST_STATE[REMOTE_STRESS_CONFIRMED_SAMPLES]} == 1035:35 ]]
    [[ ${TEST_STATE[REMOTE_STRESS_LAST_SEEN_EPOCH]} == 1036 ]]
)

# Telemetry history retains enough one-second observations for both supported
# watchdog proof windows, then drops only the oldest entries at its hard bound.
(
    declare -A TEST_STATE=()
    source "$ROOT/lib/remote_job.sh"
    TEST_STATE[REMOTE_STRESS_CONFIRMED_ELAPSED_S]=''
    TEST_STATE[REMOTE_STRESS_CONFIRMED_SAMPLES]=''
    apo_state_get() { printf '%s' "${TEST_STATE[$1]:-${2-}}"; }
    apo_state_set() { TEST_STATE[$1]=$2; }
    HISTORY_FIXTURE=''
    for (( sample=1; sample<=APO_REMOTE_JOB_CONFIRMED_SAMPLE_LIMIT; sample++ )); do
        [[ -z $HISTORY_FIXTURE ]] || HISTORY_FIXTURE+=','
        HISTORY_FIXTURE+="$((1000 + sample)):$sample"
    done
    TEST_STATE[REMOTE_STRESS_CONFIRMED_ELAPSED_S]=$APO_REMOTE_JOB_CONFIRMED_SAMPLE_LIMIT
    TEST_STATE[REMOTE_STRESS_CONFIRMED_SAMPLES]=$HISTORY_FIXTURE
    apo_remote_job_record_confirmed_sample 1513 513 1000
    IFS=',' read -r -a RETAINED_SAMPLES <<<"${TEST_STATE[REMOTE_STRESS_CONFIRMED_SAMPLES]}"
    [[ ${#RETAINED_SAMPLES[@]} == "$APO_REMOTE_JOB_CONFIRMED_SAMPLE_LIMIT" ]]
    [[ ${RETAINED_SAMPLES[0]} == 1002:2 ]]
    [[ ${RETAINED_SAMPLES[-1]} == 1513:513 ]]
)

# A strictly proved network-watchdog reboot may retain only stress time already
# reported by the target heartbeat. The next detached segment runs exactly the
# uncredited remainder while ownership stays bound to the original full gate.
# The controller globals are intentionally isolated inside this fixture.
# shellcheck disable=SC2030
(
    declare -A TEST_STATE=()
    source "$ROOT/lib/remote_job.sh"
    TEST_PHASE=network-credit
    TEST_SPEC=$(apo_remote_job_spec_hash "$TEST_PHASE" stress combined 100)
    TEST_EVENT=$(printf '4%.0s' {1..32})
    TEST_BOOT=12345678-1234-1234-1234-123456789abc
    TEST_STATE[REMOTE_STRESS_STATUS]=RUNNING
    TEST_STATE[REMOTE_STRESS_SPEC_HASH]=$TEST_SPEC
    TEST_STATE[REMOTE_STRESS_PHASE]=$TEST_PHASE
    TEST_STATE[REMOTE_STRESS_DURATION_S]=100
    TEST_STATE[REMOTE_STRESS_SEGMENT_DURATION_S]=100
    TEST_STATE[REMOTE_STRESS_START_EPOCH]=1000
    TEST_STATE[REMOTE_STRESS_LAST_SEEN_EPOCH]=1060
    TEST_STATE[REMOTE_STRESS_CONFIRMED_ELAPSED_S]=60
    TEST_STATE[REMOTE_STRESS_CONFIRMED_SAMPLES]=1060:60
    TEST_STATE[REMOTE_STRESS_CREDIT_CONTEXT]=''
    TEST_STATE[REMOTE_STRESS_CREDIT_SECONDS]=0
    TEST_STATE[REMOTE_STRESS_CREDIT_DURATION_S]=''
    TEST_STATE[REMOTE_STRESS_CREDIT_EVENT_ID]=''

    apo_state_get() { printf '%s' "${TEST_STATE[$1]:-${2-}}"; }
    apo_state_set() { TEST_STATE[$1]=$2; }
    apo_state_save() { :; }

    apo_remote_job_record_network_credit "$TEST_PHASE" "$TEST_EVENT" 1080
    [[ ${TEST_STATE[REMOTE_STRESS_CREDIT_SECONDS]} == 60 ]]
    [[ ${TEST_STATE[REMOTE_STRESS_CREDIT_DURATION_S]} == 100 ]]
    [[ ${TEST_STATE[REMOTE_STRESS_CREDIT_CONTEXT]} == "$TEST_PHASE:$TEST_SPEC" ]]
    [[ $APO_REMOTE_STRESS_CREDIT_REMAINING == 40 ]]

    # A second proved event accumulates only the newly reported work from the
    # shorter remainder segment.
    TEST_EVENT_2=$(printf '7%.0s' {1..32})
    TEST_STATE[REMOTE_STRESS_SEGMENT_DURATION_S]=40
    TEST_STATE[REMOTE_STRESS_START_EPOCH]=2000
    TEST_STATE[REMOTE_STRESS_LAST_SEEN_EPOCH]=2020
    TEST_STATE[REMOTE_STRESS_CONFIRMED_ELAPSED_S]=20
    TEST_STATE[REMOTE_STRESS_CONFIRMED_SAMPLES]=2020:20
    apo_remote_job_record_network_credit "$TEST_PHASE" "$TEST_EVENT_2" 2030
    [[ ${TEST_STATE[REMOTE_STRESS_CREDIT_SECONDS]} == 80 ]]
    [[ ${TEST_STATE[REMOTE_STRESS_CREDIT_EVENT_ID]} == "$TEST_EVENT_2" ]]
    [[ $APO_REMOTE_STRESS_CREDIT_REMAINING == 20 ]]

    # Rebuild the first-event fixture for the launch/remainder assertions.
    TEST_STATE[REMOTE_STRESS_SEGMENT_DURATION_S]=100
    TEST_STATE[REMOTE_STRESS_START_EPOCH]=1000
    TEST_STATE[REMOTE_STRESS_LAST_SEEN_EPOCH]=1060
    TEST_STATE[REMOTE_STRESS_CONFIRMED_ELAPSED_S]=60
    TEST_STATE[REMOTE_STRESS_CONFIRMED_SAMPLES]=1060:60
    apo_remote_stress_credit_clear
    apo_remote_job_record_network_credit "$TEST_PHASE" "$TEST_EVENT" 1080

    apo_remote_job_clear_state
    [[ ${TEST_STATE[REMOTE_STRESS_STATUS]} == IDLE ]]
    [[ ${TEST_STATE[REMOTE_STRESS_CREDIT_SECONDS]} == 60 ]]

    CAPTURED_START=$TEMP_DIR/network-credit-start
    CONTROLLER_OUTPUT=$TEMP_DIR/network-credit-output
    TEST_STATE[REMOTE_STRESS_STATUS]=IDLE
    APO_REMOTE_WORK_DIR=/tmp/network-credit
    APO_REMOTE_WORKER=/tmp/network-credit/worker.sh
    APO_REMOTE_JOB_HELPER=/tmp/network-credit/remote-stress-job.sh
    apo_remote_job_token() { printf '5%.0s' {1..64}; }
    apo_remote_boot_id() { printf '%s' "$TEST_BOOT"; }
    apo_remote_boot_id_once() { printf '%s' "$TEST_BOOT"; }
    apo_recovery_wait_event() { :; }
    apo_progress_render() { :; }
    apo_progress_line_is_telemetry() { return 1; }
    apo_remote_job_command() {
        local operation=$1
        if [[ $operation == start ]]; then
            printf '%s\n' "$@" > "$CAPTURED_START"
            printf 'APO_JOB_STARTED\tRUNNING\t2000\n'
            return 0
        fi
        printf 'APO_JOB_HEARTBEAT\tCOMPLETE\t2040\t2000\t40\t%s\t0\t\n' "$TEST_BOOT"
        printf 'APO_JOB_COMPLETE\t0\t0\t%s\t2040\t%s\n' "$(printf '6%.0s' {1..64})" "$TEST_BOOT"
    }
    apo_remote_job_fetch_complete() {
        printf 'APO_RESULT_CLASS=PASS\n' > "$1"
        APO_REMOTE_STRESS_RC=0
        apo_remote_job_clear_state
        apo_remote_stress_credit_clear
    }

    apo_run_remote_stress_capture "$TEST_PHASE" stress "$CONTROLLER_OUTPUT" combined 100
    mapfile -t START_ARGUMENTS < "$CAPTURED_START"
    [[ ${START_ARGUMENTS[6]} == 40 ]]
    [[ ${START_ARGUMENTS[8]} == combined ]]
    [[ ${START_ARGUMENTS[9]} == 40 ]]
    [[ ${TEST_STATE[REMOTE_STRESS_CREDIT_SECONDS]} == 0 ]]
)

# A reboot without complete watchdog proof earns no new segment time, but it
# cannot revoke a prior proof-bound checkpoint for the identical stress gate.
(
    declare -A TEST_STATE=()
    source "$ROOT/lib/remote_job.sh"
    TEST_PHASE=unattributed-credit-retention
    TEST_SPEC=$(apo_remote_job_spec_hash "$TEST_PHASE" stress combined 100)
    TEST_EVENT=$(printf '9%.0s' {1..32})
    TEST_OUTPUT=$TEMP_DIR/unattributed-credit-retention-output
    TEST_STATE[REMOTE_STRESS_SPEC_HASH]=$TEST_SPEC
    TEST_STATE[REMOTE_STRESS_DURATION_S]=100
    TEST_STATE[REMOTE_STRESS_CREDIT_CONTEXT]="$TEST_PHASE:$TEST_SPEC"
    TEST_STATE[REMOTE_STRESS_CREDIT_SECONDS]=60
    TEST_STATE[REMOTE_STRESS_CREDIT_DURATION_S]=100
    TEST_STATE[REMOTE_STRESS_CREDIT_EVENT_ID]=$TEST_EVENT
    TEST_STATE[UNATTRIBUTED_REBOOT_REPLAY_CONTEXT]=''
    TEST_STATE[UNATTRIBUTED_REBOOT_REPLAY_COUNT]=0

    apo_state_get() { printf '%s' "${TEST_STATE[$1]:-${2-}}"; }
    apo_state_set() { TEST_STATE[$1]=$2; }
    apo_state_save() { :; }
    apo_redeploy_worker_for_boot() { return 0; }
    apo_profile_prove_network_watchdog_reboot() { return 1; }

    if apo_remote_job_classify_reboot "$TEST_PHASE" "$TEST_OUTPUT" old-boot new-boot; then
        echo 'unattributed reboot unexpectedly classified as success' >&2
        exit 1
    fi
    [[ ${TEST_STATE[REMOTE_STRESS_CREDIT_SECONDS]} == 60 ]]
    [[ ${TEST_STATE[REMOTE_STRESS_CREDIT_CONTEXT]} == "$TEST_PHASE:$TEST_SPEC" ]]
    [[ ${TEST_STATE[UNATTRIBUTED_REBOOT_REPLAY_COUNT]} == 1 ]]
    RETAINED_REASON_B64=$(awk -F= '/^APO_RESULT_REASON_B64=/{sub(/^[^=]*=/, ""); print; exit}' "$TEST_OUTPUT")
    apo_state_decode "$RETAINED_REASON_B64" RETAINED_REASON
    [[ $RETAINED_REASON == '[UNATTRIBUTED_REBOOT_REPLAY] '* ]]
    [[ $RETAINED_REASON == *'earlier 60s proof-bound checkpoint remains valid'* ]]
    [[ $RETAINED_REASON == *'40s remains at the same clocks'* ]]

    # Mismatched saved credit is not carried into another gate.
    TEST_STATE[UNATTRIBUTED_REBOOT_REPLAY_CONTEXT]=''
    TEST_STATE[UNATTRIBUTED_REBOOT_REPLAY_COUNT]=0
    TEST_STATE[REMOTE_STRESS_CREDIT_CONTEXT]='different-gate:different-spec'
    TEST_STATE[REMOTE_STRESS_CREDIT_SECONDS]=60
    TEST_STATE[REMOTE_STRESS_CREDIT_DURATION_S]=100
    TEST_STATE[REMOTE_STRESS_CREDIT_EVENT_ID]=$TEST_EVENT
    TEST_OUTPUT_INVALID=$TEMP_DIR/unattributed-credit-invalid-output
    if apo_remote_job_classify_reboot "$TEST_PHASE" "$TEST_OUTPUT_INVALID" old-boot new-boot; then
        echo 'unattributed reboot with invalid credit unexpectedly classified as success' >&2
        exit 1
    fi
    [[ ${TEST_STATE[REMOTE_STRESS_CREDIT_SECONDS]} == 0 ]]
    [[ -z ${TEST_STATE[REMOTE_STRESS_CREDIT_CONTEXT]} ]]
)

# Wall-clock heartbeat time alone is never stress credit. The target must have
# emitted a matching workload elapsed sample before the proved reboot request.
(
    declare -A TEST_STATE=()
    source "$ROOT/lib/remote_job.sh"
    TEST_PHASE=no-unproved-credit
    TEST_SPEC=$(apo_remote_job_spec_hash "$TEST_PHASE" stress combined 100)
    TEST_EVENT=$(printf '8%.0s' {1..32})
    TEST_STATE[REMOTE_STRESS_STATUS]=RUNNING
    TEST_STATE[REMOTE_STRESS_SPEC_HASH]=$TEST_SPEC
    TEST_STATE[REMOTE_STRESS_PHASE]=$TEST_PHASE
    TEST_STATE[REMOTE_STRESS_DURATION_S]=100
    TEST_STATE[REMOTE_STRESS_SEGMENT_DURATION_S]=100
    TEST_STATE[REMOTE_STRESS_START_EPOCH]=1000
    TEST_STATE[REMOTE_STRESS_LAST_SEEN_EPOCH]=1060
    TEST_STATE[REMOTE_STRESS_CONFIRMED_ELAPSED_S]=''
    TEST_STATE[REMOTE_STRESS_CREDIT_CONTEXT]=''
    TEST_STATE[REMOTE_STRESS_CREDIT_SECONDS]=0
    TEST_STATE[REMOTE_STRESS_CREDIT_DURATION_S]=''
    TEST_STATE[REMOTE_STRESS_CREDIT_EVENT_ID]=''

    apo_state_get() { printf '%s' "${TEST_STATE[$1]:-${2-}}"; }
    apo_state_set() { TEST_STATE[$1]=$2; }

    apo_remote_job_record_network_credit "$TEST_PHASE" "$TEST_EVENT" 1080
    [[ ${TEST_STATE[REMOTE_STRESS_CREDIT_SECONDS]} == 0 ]]
    [[ -z ${TEST_STATE[REMOTE_STRESS_CREDIT_CONTEXT]} ]]

    # Alpha.68 retained only the latest workload sample. If its heartbeat was
    # observed after the watchdog request, subtract the entire later interval
    # and retain only the conservative pre-request lower bound.
    TEST_STATE[REMOTE_STRESS_LAST_SEEN_EPOCH]=1090
    TEST_STATE[REMOTE_STRESS_CONFIRMED_ELAPSED_S]=60
    apo_remote_job_record_network_credit "$TEST_PHASE" "$TEST_EVENT" 1080
    [[ ${TEST_STATE[REMOTE_STRESS_CREDIT_SECONDS]} == 50 ]]
    [[ $APO_REMOTE_STRESS_CREDIT_REMAINING == 50 ]]

    # Explicit history does not interpolate a sample observed only after the
    # request because its exact timestamp is already known.
    apo_remote_stress_credit_clear
    TEST_STATE[REMOTE_STRESS_CONFIRMED_SAMPLES]=1090:60
    apo_remote_job_record_network_credit "$TEST_PHASE" "$TEST_EVENT" 1080
    [[ ${TEST_STATE[REMOTE_STRESS_CREDIT_SECONDS]} == 0 ]]

    # The last heartbeat may arrive after the watchdog request while carrying
    # an unchanged telemetry sample first observed before that request. Credit
    # the sample timestamp, not the later liveness heartbeat timestamp.
    TEST_STATE[REMOTE_STRESS_CONFIRMED_SAMPLES]=1060:60
    apo_remote_job_record_network_credit "$TEST_PHASE" "$TEST_EVENT" 1080
    [[ ${TEST_STATE[REMOTE_STRESS_CREDIT_SECONDS]} == 60 ]]

    # If stress telemetry advances during watchdog starvation, retain the
    # newest sample at or before the request and reject only later samples.
    apo_remote_stress_credit_clear
    TEST_STATE[REMOTE_STRESS_LAST_SEEN_EPOCH]=1090
    TEST_STATE[REMOTE_STRESS_CONFIRMED_ELAPSED_S]=90
    TEST_STATE[REMOTE_STRESS_CONFIRMED_SAMPLES]=1060:60,1075:75,1090:90
    apo_remote_job_record_network_credit "$TEST_PHASE" "$TEST_EVENT" 1080
    [[ ${TEST_STATE[REMOTE_STRESS_CREDIT_SECONDS]} == 75 ]]

    # Corrupt or non-monotonic saved history fails closed instead of granting
    # credit from a value whose observation time cannot be proved.
    apo_remote_stress_credit_clear
    TEST_STATE[REMOTE_STRESS_CONFIRMED_SAMPLES]=1060:60,1075:55
    apo_remote_job_record_network_credit "$TEST_PHASE" "$TEST_EVENT" 1080
    [[ ${TEST_STATE[REMOTE_STRESS_CREDIT_SECONDS]} == 0 ]]
    [[ -z ${TEST_STATE[REMOTE_STRESS_CREDIT_CONTEXT]} ]]

    # A request timestamp before the saved job start cannot earn legacy
    # credit, even when the later heartbeat contains elapsed telemetry.
    TEST_STATE[REMOTE_STRESS_CONFIRMED_SAMPLES]=''
    TEST_STATE[REMOTE_STRESS_START_EPOCH]=1085
    TEST_STATE[REMOTE_STRESS_LAST_SEEN_EPOCH]=1090
    TEST_STATE[REMOTE_STRESS_CONFIRMED_ELAPSED_S]=60
    apo_remote_job_record_network_credit "$TEST_PHASE" "$TEST_EVENT" 1080
    [[ ${TEST_STATE[REMOTE_STRESS_CREDIT_SECONDS]} == 0 ]]
)

# Periodic progress checkpoints are advisory once exact target-job ownership
# is durable. Failures are rate-limited to one attempt per minute, leave the
# target job alone, and report recovery after a later successful checkpoint.
(
    source "$ROOT/lib/remote_job.sh"
    SAVE_CALLS=0
    EVENTS=()
    APO_STATE_SAVE_ERROR='simulated checkpoint failure'
    apo_state_save_try() {
        SAVE_CALLS=$((SAVE_CALLS + 1))
        (( SAVE_CALLS >= 3 ))
    }
    apo_recovery_wait_event() { EVENTS+=("$1:$2:$3"); }
    apo_remote_job_checkpoint_heartbeat 100
    [[ $SAVE_CALLS == 1 && $APO_REMOTE_JOB_CHECKPOINT_FAILURES == 1 ]]
    apo_remote_job_checkpoint_heartbeat 159
    [[ $SAVE_CALLS == 1 ]]
    apo_remote_job_checkpoint_heartbeat 160
    [[ $SAVE_CALLS == 2 && $APO_REMOTE_JOB_CHECKPOINT_FAILURES == 2 ]]
    apo_remote_job_checkpoint_heartbeat 220
    [[ $SAVE_CALLS == 3 && $APO_REMOTE_JOB_CHECKPOINT_FAILURES == 0 ]]
    [[ ${#EVENTS[@]} == 3 ]]
    [[ ${EVENTS[0]} == WARN:detached-stress-checkpoint:*'remains active'* ]]
    [[ ${EVENTS[1]} == WARN:detached-stress-checkpoint:*'retry after another 60 seconds'* ]]
    [[ ${EVENTS[2]} == INFO:detached-stress-checkpoint-recovered:*'remained active throughout'* ]]
)

printf 'test_remote_job: PASS\n'
