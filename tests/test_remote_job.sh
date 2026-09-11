#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

if [[ ! -r /proc/sys/kernel/random/boot_id ]] || ! command -v setsid >/dev/null 2>&1 ||
   ! command -v timeout >/dev/null 2>&1 || ! timeout --help 2>&1 | grep -Eq '(^|[[:space:]])-k([,[:space:]]|$)'; then
    printf 'test_remote_job: SKIP (requires Linux boot IDs, setsid, and a timeout implementation with -k)\n'
    exit 0
fi

TEMP_DIR=$(mktemp -d)
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
BOOT_ID=$(< /proc/sys/kernel/random/boot_id)
TOKEN=$(printf 'a%.0s' {1..64})
SPEC=$(printf 'b%.0s' {1..64})
JOB_ID=job-${TOKEN:0:32}
RUN_ROOT=$TEMP_DIR/run

START_OUTPUT=$("$HELPER" start "$RUN_ROOT" "$JOB_ID" "$TOKEN" "$SPEC" "$BOOT_ID" 1 "$WORKER" pass 1)
[[ $START_OUTPUT =~ ^APO_JOB_STARTED$'\t'(RUNNING|COMPLETE)$'\t'[0-9]+$ ]]
grep -Eq '^START_MONOTONIC_SECONDS=[0-9]+$' "$RUN_ROOT/jobs/$JOB_ID/manifest"
FOLLOW_OUTPUT=$("$HELPER" follow "$RUN_ROOT" "$JOB_ID" "$TOKEN" "$SPEC")
grep -q '^APO_JOB_COMPLETE' <<<"$FOLLOW_OUTPUT"
FETCHED=$("$HELPER" fetch "$RUN_ROOT" "$JOB_ID" "$TOKEN" "$SPEC")
grep -q '^APO_RESULT_CLASS=PASS$' <<<"$FETCHED"

START_AGAIN=$("$HELPER" start "$RUN_ROOT" "$JOB_ID" "$TOKEN" "$SPEC" "$BOOT_ID" 1 "$WORKER" pass 1)
grep -Eq $'^APO_JOB_STARTED\tCOMPLETE\t[0-9]+$' <<<"$START_AGAIN"
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
DEADLINE_FOLLOW=$("$HELPER" follow "$RUN_ROOT" "$DEADLINE_JOB" "$DEADLINE_TOKEN" "$DEADLINE_SPEC")
grep -q $'^APO_JOB_COMPLETE\t124\t' <<<"$DEADLINE_FOLLOW"
DEADLINE_RESULT=$("$HELPER" fetch "$RUN_ROOT" "$DEADLINE_JOB" "$DEADLINE_TOKEN" "$DEADLINE_SPEC")
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
STALE_INSPECT=$("$HELPER" inspect "$RUN_ROOT" "$STALE_JOB" "$STALE_TOKEN" "$STALE_SPEC")
[[ $STALE_INSPECT == APO_JOB_INSPECT$'\t'ORPHANED$'\t'* ]]

grep -Fq 'apo_remote_job_command follow "$APO_REMOTE_WORK_DIR" "$job_id" "$token" "$spec_hash" 2>/dev/null |' \
    "$ROOT/lib/remote_job.sh"
if grep -Fq 'apo_remote_job_command follow "$APO_REMOTE_WORK_DIR" "$job_id" "$token" "$spec_hash" 2>&1 |' \
    "$ROOT/lib/remote_job.sh"; then
    echo 'SSH diagnostics are still entering the detached-job protocol parser' >&2
    exit 1
fi

# The controller globals are intentionally isolated inside this fixture.
# shellcheck disable=SC2030
(
    declare -A TEST_STATE=()
    source "$ROOT/lib/remote_job.sh"
    CONTROLLER_OUTPUT=$TEMP_DIR/controller-output.log
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
    apo_state_set() { TEST_STATE[$1]=$2; }
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
    [[ ${TEST_STATE[REMOTE_STRESS_LAST_SEEN_EPOCH]} == 1035 ]]
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
    apo_remote_job_record_network_credit "$TEST_PHASE" "$TEST_EVENT_2" 2030
    [[ ${TEST_STATE[REMOTE_STRESS_CREDIT_SECONDS]} == 80 ]]
    [[ ${TEST_STATE[REMOTE_STRESS_CREDIT_EVENT_ID]} == "$TEST_EVENT_2" ]]
    [[ $APO_REMOTE_STRESS_CREDIT_REMAINING == 20 ]]

    # Rebuild the first-event fixture for the launch/remainder assertions.
    TEST_STATE[REMOTE_STRESS_SEGMENT_DURATION_S]=100
    TEST_STATE[REMOTE_STRESS_START_EPOCH]=1000
    TEST_STATE[REMOTE_STRESS_LAST_SEEN_EPOCH]=1060
    TEST_STATE[REMOTE_STRESS_CONFIRMED_ELAPSED_S]=60
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

    # Even reported workload time is rejected when its controller heartbeat
    # was observed after the target says its watchdog reboot was requested.
    TEST_STATE[REMOTE_STRESS_LAST_SEEN_EPOCH]=1090
    TEST_STATE[REMOTE_STRESS_CONFIRMED_ELAPSED_S]=60
    apo_remote_job_record_network_credit "$TEST_PHASE" "$TEST_EVENT" 1080
    [[ ${TEST_STATE[REMOTE_STRESS_CREDIT_SECONDS]} == 0 ]]
)

printf 'test_remote_job: PASS\n'
