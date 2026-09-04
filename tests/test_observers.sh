#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
APO_ROOT=$ROOT
source "$ROOT/lib/common.sh"
source "$ROOT/lib/state.sh"
source "$ROOT/lib/logging.sh"
source "$ROOT/lib/ssh.sh"
source "$ROOT/lib/classify.sh"
source "$ROOT/lib/report.sh"

TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT
APO_OUTPUT_DIR=$TEMP_DIR
APO_TARGET_SLUG=fixture-target
APO_RAW_TARGET=fixture-target
APO_REMOTE_TARGET="$(id -un)@fixture-target"
APO_TARGET_HOST=fixture-target
APO_MODE_REQUESTED=auto
APO_COMMAND=status
APO_REDACT=0
APO_VERSION=fixture

fixture_hash=$(printf 'a%.0s' {1..64})
apo_init_artifacts
apo_state_initialize
TUNING_STATE=$APO_STATE_FILE
TUNING_RUN=$APO_RUN_ID
apo_state_set ORIGIN_COMMAND overclock
apo_state_set PROFILE debian
apo_state_set MODE_EFFECTIVE graphical
apo_state_set STATUS PASS
apo_state_set PHASE COMPLETE
apo_state_set SUBPHASE APPLIED
apo_state_set FINAL_STAGE COMPLETE
apo_state_set VALIDATION_SCHEMA "$APO_CURRENT_VALIDATION_SCHEMA"
apo_state_set VALIDATED 1
apo_state_set VALIDATION_DURATION_S 86400
apo_state_set APPLY_STATUS APPLIED
apo_state_set PERMANENT_HASH "$fixture_hash"
apo_state_set APPLY_EXPECTED_HASH "$fixture_hash"
apo_state_set FINAL_CPU 3100
apo_state_set FINAL_GPU 1175
apo_state_set RECOMMENDED_CPU 3100
apo_state_set RECOMMENDED_GPU 1175
apo_state_set PASSED_CPUS 3000,3100
apo_state_set PASSED_GPUS 1150,1175
apo_state_set CPU_FAILURE_BOUNDARY 3125
apo_state_set GPU_FAILURE_BOUNDARY 1200
apo_state_set CPU_QUALIFICATION_STATUS PASS
apo_state_set CPU_QUALIFICATION_TARGET 3100
apo_state_set CPU_QUALIFIED_CLOCK 3100
apo_state_set GPU_QUALIFICATION_STATUS PASS
apo_state_set GPU_QUALIFICATION_CPU 3100
apo_state_set GPU_QUALIFICATION_TARGET 1175
apo_state_set GPU_QUALIFIED_CPU 3100
apo_state_set GPU_QUALIFIED_CLOCK 1175
apo_state_set CFG_SELECTION_POLICY refined-max-25
apo_state_set CFG_SWEEP_DOMAIN all
apo_state_set CFG_QUALIFICATION_DURATION_S 7200
apo_state_set CFG_FINAL_DURATION_S 86400
apo_state_set RUN_MAX_TEMP 61.2
apo_state_save

# A later reset/restore/prepare audit must not hide the newest actual tuning
# story selected by the summary command.
apo_init_artifacts
apo_state_initialize
apo_state_set ORIGIN_COMMAND reset
apo_state_set STATUS PASS
apo_state_set PHASE COMPLETE
apo_state_set SUBPHASE STOCK_VERIFIED
apo_state_save
[[ $(apo_find_latest_tuning_state_file) == "$TUNING_STATE" ]]

# A state whose sanitized filename collides with this target must never become
# its summary or retained-validation evidence.
COLLISION_STATE="$TEMP_DIR/${APO_TARGET_SLUG}-collision.state"
cp "$TUNING_STATE" "$COLLISION_STATE"
collision_target=$(printf '%s' 'different-user@different-host' | base64 | tr -d '\n')
awk -F '\t' -v replacement="$collision_target" 'BEGIN {OFS="\t"} $1 == "REMOTE_TARGET" {$2=replacement} {print}' \
    "$COLLISION_STATE" > "$COLLISION_STATE.tmp"
mv "$COLLISION_STATE.tmp" "$COLLISION_STATE"
touch "$COLLISION_STATE"
[[ $(apo_find_latest_tuning_state_file) == "$TUNING_STATE" ]]

apo_state_load "$TUNING_STATE"
APO_STATE_FILE=$TUNING_STATE
APO_STATUS_CONTROLLER_STATE=IDLE

# Exercise the complete transient-worker capture path without contacting a
# network target. The fake transport consumes the worker sent on stdin and
# returns the same structured wire format as a live target.
STATUS_BIN="$TEMP_DIR/status-bin"
mkdir -p "$STATUS_BIN"
cat > "$STATUS_BIN/ssh" <<'FAKE_SSH'
#!/usr/bin/env bash
emit_data() {
    printf 'APO_DATA\t%s\t%s\n' "$1" "$(printf '%s' "$2" | base64 | tr -d '\n')"
}
if [[ $* == *status-snapshot* ]]; then
    cat >/dev/null
    emit_data PROFILE debian
    emit_data CONFIG_CPU 3100
    emit_data CONFIG_GPU 1175
    emit_data MEASURED_CPU 3099
    emit_data MEASURED_GPU 1175
    emit_data PERMANENT_HASH "$FIXTURE_HASH"
    emit_data PERMANENT_TUNING_PROVENANCE explicit-override
    emit_data PERMANENT_TUNING_EVIDENCE arm_freq,v3d_freq
    emit_data TRYBOOT_EXISTS 0
    emit_data TRYBOOT_TYPE absent
    emit_data TRYBOOT_HASH unavailable
    emit_data TRYBOOT_FLAG 00000000
    emit_data THROTTLED throttled=0x0
    emit_data RECENT_THROTTLED throttled=0x0
    emit_data TEMP 52.4
    emit_data BOOT_ID 11111111-2222-3333-4444-555555555555
    emit_data UPTIME_SECONDS 90061
    printf 'APO_RESULT_CLASS=PASS\n'
    printf 'APO_RESULT_REASON_B64=TGl2ZSBjbG9jay9jb25maWcgc25hcHNob3QgY29tcGxldGVkLg==\n'
else
    printf 'debian\t0\tyes\n'
fi
FAKE_SSH
chmod 755 "$STATUS_BIN/ssh"
PATH="$STATUS_BIN:$PATH" FIXTURE_HASH="$fixture_hash" apo_status_capture_live
[[ $APO_STATUS_LIVE_STATE == AVAILABLE ]]
[[ ${APO_STATUS_LIVE[CONFIG_CPU]} == 3100 && ${APO_STATUS_LIVE[CONFIG_GPU]} == 1175 ]]
apo_status_find_validated_match
[[ $APO_STATUS_VALIDATED_RUN_ID == "$TUNING_RUN" ]]
apo_status_evaluate
[[ $APO_STATUS_VERDICT == 'OVERCLOCKED / VALIDATED' ]]
[[ $APO_STATUS_TRYBOOT == CLEAR ]]
[[ $APO_STATUS_HEALTH == GOOD ]]

state_hash_before=$(sha256sum "$TUNING_STATE" | awk 'NR == 1 {print $1}')
status_output=$(apo_print_status)
summary_output=$(apo_print_summary)
[[ $(sha256sum "$TUNING_STATE" | awk 'NR == 1 {print $1}') == "$state_hash_before" ]]
grep -Fq 'Verdict:        OVERCLOCKED / VALIDATED' <<< "$status_output"
grep -Fq 'Active clocks:  CPU 3100 MHz / GPU 1175 MHz' <<< "$status_output"
grep -Fq 'Measured now:   CPU 3099 MHz / GPU 1175 MHz' <<< "$status_output"
grep -Fq 'Quick health:   GOOD' <<< "$status_output"
grep -Fq 'Tryboot:        CLEAR' <<< "$status_output"
grep -Fq 'CPU passes=3000,3100, boundary=3125 MHz' <<< "$summary_output"
grep -Fq 'GPU passes=1150,1175, boundary=1200 MHz' <<< "$summary_output"
grep -Fq 'qualification=2h per domain; final=24h uninterrupted' <<< "$summary_output"
grep -Fq 'validated=1, duration=24h, clocks=CPU 3100 / GPU 1175 MHz' <<< "$summary_output"

APO_REDACT=1
redacted_summary=$(apo_print_summary)
grep -Fq 'Target:         <redacted>' <<< "$redacted_summary"
if grep -Fq 'fixture-target' <<< "$redacted_summary"; then
    echo 'redacted summary leaked the target name' >&2
    exit 1
fi
APO_REDACT=0

saved_state_file=$APO_STATE_FILE
declare -Ag SAVED_OBSERVER_STATE=()
for state_key in "${!APO_STATE[@]}"; do
    SAVED_OBSERVER_STATE[$state_key]=${APO_STATE[$state_key]}
done
APO_STATE=()
APO_STATE_FILE=''
no_state_summary=$(apo_print_summary)
grep -Fq 'No retained tuning run was found for this target.' <<< "$no_state_summary"
APO_STATE=()
for state_key in "${!SAVED_OBSERVER_STATE[@]}"; do
    APO_STATE[$state_key]=${SAVED_OBSERVER_STATE[$state_key]}
done
APO_STATE_FILE=$saved_state_file

lock_file="$APO_OUTPUT_DIR/.${APO_TARGET_SLUG}.lock"
lock_ready="$TEMP_DIR/lock-ready"
lock_release="$TEMP_DIR/lock-release"
: > "$lock_file"
(
    flock -x 9
    : > "$lock_ready"
    while [[ ! -e $lock_release ]]; do sleep 0.05; done
) 9< "$lock_file" &
lock_holder=$!
for _ in {1..100}; do
    [[ -e $lock_ready ]] && break
    sleep 0.05
done
[[ -e $lock_ready ]]
apo_status_controller_state
[[ $APO_STATUS_CONTROLLER_STATE == ACTIVE ]]
: > "$lock_release"
wait "$lock_holder"
apo_status_controller_state
[[ $APO_STATUS_CONTROLLER_STATE == IDLE ]]

APO_STATUS_CONTROLLER_STATE=ACTIVE
apo_status_evaluate
[[ $APO_STATUS_VERDICT == 'IN PROGRESS' ]]

APO_STATUS_CONTROLLER_STATE=IDLE
APO_STATUS_LIVE[TRYBOOT_FLAG]=00000001
apo_status_evaluate
[[ $APO_STATUS_VERDICT == 'RECOVERY NEEDED' ]]

APO_STATUS_LIVE[TRYBOOT_FLAG]=00000000
APO_STATUS_LIVE[PERMANENT_HASH]=$(printf 'b%.0s' {1..64})
APO_STATUS_VALIDATED_RUN_ID=''
apo_state_set STATUS PASS
apo_state_set TRYBOOT_EXPECTED 0
apo_state_set TRYBOOT_FILE_MAY_EXIST 0
apo_status_evaluate
[[ $APO_STATUS_VERDICT == 'OVERCLOCKED / UNVERIFIED' ]]

APO_STATUS_LIVE[TRYBOOT_FLAG]=unavailable
apo_status_evaluate
[[ $APO_STATUS_VERDICT == 'CONFIG NEEDS REVIEW' ]]
APO_STATUS_LIVE[TRYBOOT_FLAG]=00000000

APO_STATUS_LIVE[PERMANENT_TUNING_PROVENANCE]=verified-default
apo_status_evaluate
[[ $APO_STATUS_VERDICT == 'STOCK / RESET' ]]

apo_state_set STATUS RUNNING
apo_status_evaluate
[[ $APO_STATUS_VERDICT == 'INTERRUPTED / RESUME AVAILABLE' ]]

APO_STATUS_LIVE_STATE=UNAVAILABLE
apo_status_evaluate
[[ $APO_STATUS_VERDICT == 'INTERRUPTED / TARGET UNREACHABLE' ]]

for worker in "$ROOT/workers/debian-worker.sh" "$ROOT/workers/batocera-worker.sh"; do
    grep -Fq 'status-snapshot) cmd_status_snapshot "$@" ;;' "$worker"
    grep -Fq 'emit_data CONFIG_CPU' "$worker"
    grep -Fq 'emit_data CONFIG_GPU' "$worker"
    grep -Fq 'emit_data TRYBOOT_FLAG' "$worker"
done

printf 'test_observers: PASS\n'
