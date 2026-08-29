#!/usr/bin/env bash
# This fixture calls production functions sourced below, then intentionally
# redefines selected functions for later isolated scenarios.
# shellcheck disable=SC2218
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
APO_ROOT=$ROOT
source "$ROOT/lib/common.sh"
source "$ROOT/lib/config.sh"
source "$ROOT/lib/state.sh"
source "$ROOT/lib/recovery.sh"

APO_CFG=(
    [CANDIDATE_DURATION_S]=60
    [FINAL_DURATION_S]=28800
    [BACKOFF_STEPS]=1
    [CANDIDATE_BOOTS]=4
    [FINAL_BOOTS]=5
)
APO_NORMAL_CPU=2400
APO_NORMAL_GPU=800
APO_NORMAL_VOLTAGE=0
APO_AUTO_BASELINE_CPU=''
APO_AUTO_BASELINE_GPU=''
APO_AUTO_BASELINE_VOLTAGE=''
APO_AUTO_BASELINE_PROVENANCE=''
APO_AUTO_BASELINE_EVIDENCE=''
APO_TEST_VOLTAGE=50000
APO_GPU_KEY=v3d_freq
APO_REQUIRE_GPU_STRESS=1
APO_NEED_GPU=1
APO_LAST_CLASS=''
APO_LAST_REASON=''
APO_AUTO_GENERATED_CANDIDATES=0
APO_EDGE_CPU_24H=0
APO_STATE=()
ACTIONS=()
SAVE_COUNT=0
RECOVERY_FORCE_REBOOT=''

apo_state_save() { SAVE_COUNT=$((SAVE_COUNT + 1)); }
apo_event() { :; }
apo_summary_line() { :; }
apo_state_fail() { apo_state_set STATUS FAILED; apo_state_set FAILURE_CLASS "$1"; apo_state_set FAILURE_REASON "$2"; apo_state_save; }
apo_boot_candidate() {
    ACTIONS+=("boot:$3")
    apo_state_set TRYBOOT_EXPECTED 1
    apo_state_set CURRENT_CPU "$1"
    apo_state_set CURRENT_GPU "$2"
}
apo_return_normal() {
    ACTIONS+=("normal:$1")
    apo_state_set TRYBOOT_EXPECTED 0
    apo_state_set CURRENT_CPU ''
    apo_state_set CURRENT_GPU ''
}
apo_run_stress() { ACTIONS+=("stress:$1:$3"); }
apo_health_check() { ACTIONS+=("health:$4"); }
apo_verify_permanent_hash() { ACTIONS+=("hash:$1"); }
apo_recover_preserving_failure() { return 0; }
apo_record_failure_after_recovery() { RECOVERY_FORCE_REBOOT=${4:-0}; apo_state_fail "$2" "$3"; }
apo_class_is_edge_failure() { [[ $1 == BOOT_FAILURE || $1 == STABILITY_FAILURE ]]; }

source "$ROOT/lib/candidates.sh"

seed_valid_guarded_auto_floor_plan() {
    APO_AUTO_GENERATED_CANDIDATES=1
    APO_EDGE_CPU_24H=1
    APO_NORMAL_CPU=2400
    APO_NORMAL_GPU=800
    APO_NORMAL_VOLTAGE=0
    APO_TEST_VOLTAGE=0
    APO_AUTO_BASELINE_CPU=2400
    APO_AUTO_BASELINE_GPU=800
    APO_AUTO_BASELINE_VOLTAGE=0
    APO_AUTO_BASELINE_PROVENANCE='verified-default'
    APO_AUTO_BASELINE_EVIDENCE=none
    APO_CPU_CANDIDATES=(2500 2600 2700 2800 2900 3000 3100 3200)
    APO_GPU_CANDIDATES=(850 900 950 1000 1050 1100 1150 1200)
    APO_CFG[CPU_CANDIDATES]='2500,2600,2700,2800,2900,3000,3100,3200'
    APO_CFG[GPU_CANDIDATES]='850,900,950,1000,1050,1100,1150,1200'
    APO_CFG[BACKOFF_STEPS]=0
    APO_CFG[VOLTAGE_DELTA_UV]=existing
    apo_state_set CPU_INDEX 6
    apo_state_set PASSED_CPUS 2500,2600,2700,2800,2900,3000,3025
    apo_state_set CPU_FAILURE_BOUNDARY 3050
    apo_state_set CPU_REFINE_CANDIDATES 3025
    apo_state_set CPU_REFINE_INDEX 1
    apo_state_set CPU_REFINE_COMPLETE 1
    apo_state_set CPU_GUARD_TARGET 3000
    apo_state_set CPU_GUARD_VERIFIED 1
    apo_state_set SAFE_CPU 3000
    apo_state_set GPU_INDEX 2
    apo_state_set PASSED_GPUS 850,900
    apo_state_set GPU_FAILURE_BOUNDARY 925
    apo_state_set GPU_REFINE_CANDIDATES ''
    apo_state_set GPU_REFINE_INDEX 0
    apo_state_set GPU_REFINE_COMPLETE 1
    apo_state_set GPU_GUARD_TARGET 900
    apo_state_set GPU_GUARD_VERIFIED 1
    apo_state_set SAFE_GPU 900
    apo_state_set CPU_QUALIFICATION_STATUS PASS
    apo_state_set CPU_QUALIFICATION_TARGET 3000
    apo_state_set CPU_QUALIFIED_CLOCK 3000
    apo_state_set CPU_QUALIFICATION_HISTORY ''
    apo_state_set CPU_QUALIFICATION_LAST_CLASS ''
    apo_state_set CPU_QUALIFICATION_LAST_REASON ''
    apo_state_set GPU_QUALIFICATION_STATUS PASS
    apo_state_set GPU_QUALIFICATION_CPU 3000
    apo_state_set GPU_QUALIFICATION_TARGET 900
    apo_state_set GPU_QUALIFIED_CPU 3000
    apo_state_set GPU_QUALIFIED_CLOCK 900
    apo_state_set RECOVERY_WAIT_STATUS IDLE
    apo_state_set RECOVERY_WAIT_CONTEXT ''
    apo_state_set RECOVERY_WAIT_STARTED_AT ''
    apo_state_set RECOVERY_WAIT_TIMEOUTS 0
    apo_final_initialize_backoff_state
}

# Only a Batocera graphical smoke failure that explicitly reports failed
# session recovery requests the guarded normal-config reboot path.
apo_run_stress() { APO_LAST_CLASS=RECOVERY_FAILURE; APO_LAST_REASON='frontend did not recover'; return 1; }
APO_PROFILE=batocera
APO_MODE_EFFECTIVE=graphical
RECOVERY_FORCE_REBOOT=''
if apo_gpu_harness_smoke; then exit 1; fi
[[ $RECOVERY_FORCE_REBOOT == 1 ]]

APO_STATE=()
APO_PROFILE=debian
APO_MODE_EFFECTIVE=graphical
RECOVERY_FORCE_REBOOT=''
if apo_gpu_harness_smoke; then exit 1; fi
[[ $RECOVERY_FORCE_REBOOT == 0 ]]

APO_STATE=()
APO_PROFILE=batocera
APO_MODE_EFFECTIVE=graphical
apo_run_stress() { APO_LAST_CLASS=HARNESS_FAILURE; APO_LAST_REASON='launcher failed safely'; return 1; }
RECOVERY_FORCE_REBOOT=''
if apo_gpu_harness_smoke; then exit 1; fi
[[ $RECOVERY_FORCE_REBOOT == 0 ]]

# Restore the general success fixture used by the resume tests below.
APO_STATE=()
apo_run_stress() { ACTIONS+=("stress:$1:$3"); }

# Resume a candidate after its second of four configured boot cycles. Earlier
# boot gates must not be replayed; only cycles 2-4 and later gates run.
apo_state_set CANDIDATE_LABEL cpu-3000_gpu-800
apo_state_set CANDIDATE_CPU 3000
apo_state_set CANDIDATE_GPU 800
apo_state_set CANDIDATE_STAGE NORMAL_2
apo_state_set TRYBOOT_EXPECTED 0
apo_test_candidate 3000 800 cpu-3000_gpu-800 combined
[[ ${ACTIONS[*]} == 'normal:cpu-3000_gpu-800-normal-2 boot:cpu-3000_gpu-800-boot-3 normal:cpu-3000_gpu-800-normal-3 boot:cpu-3000_gpu-800-boot-4 normal:cpu-3000_gpu-800-normal-4 boot:cpu-3000_gpu-800-stress-boot stress:combined:cpu-3000_gpu-800-candidate health:cpu-3000_gpu-800-post-stress normal:cpu-3000_gpu-800-final-normal' ]]
[[ $(apo_state_get CANDIDATE_STAGE) == COMPLETE ]]

# A missing stress trailer is promoted only when normal recovery proves that
# the saved candidate boot rebooted before the controller requested it. This is
# a silicon stability boundary, while same-boot transport loss remains fatal
# harness uncertainty.
APO_STATE=()
apo_state_set CANDIDATE_LABEL cpu-3200_gpu-800
apo_state_set CANDIDATE_CPU 3200
apo_state_set CANDIDATE_GPU 800
apo_state_set CANDIDATE_STAGE STRESS
apo_state_set TRYBOOT_EXPECTED 1
apo_state_set CURRENT_CPU 3200
apo_state_set CURRENT_GPU 800
apo_run_stress() {
    APO_LAST_CLASS=HARNESS_FAILURE
    APO_LAST_REASON='The worker failed without a structured result.'
    APO_LAST_RESULT_STRUCTURED=0
    return 1
}
RECOVERY_UNEXPECTED_FIXTURE=1
RECOVERY_STRESS_SCOPE=''
apo_recover_preserving_failure() {
    RECOVERY_STRESS_SCOPE=${5:-none}
    APO_RECOVERY_UNEXPECTED_CANDIDATE_REBOOT=$RECOVERY_UNEXPECTED_FIXTURE
    if (( RECOVERY_UNEXPECTED_FIXTURE == 1 )); then
        APO_RECOVERY_UNEXPECTED_REBOOT_FROM='candidate-stress-boot'
        APO_RECOVERY_UNEXPECTED_REBOOT_TO=watchdog-normal-boot
    else
        APO_RECOVERY_UNEXPECTED_REBOOT_FROM=''
        APO_RECOVERY_UNEXPECTED_REBOOT_TO=''
    fi
}
if apo_test_candidate 3200 800 cpu-3200_gpu-800 combined; then
    echo 'unexpected candidate reboot was incorrectly accepted' >&2
    exit 1
fi
[[ $APO_LAST_CLASS == STABILITY_FAILURE ]]
[[ $APO_LAST_REASON == *'rebooted unexpectedly from boot candidate-stress-boot to verified normal boot watchdog-normal-boot'* ]]
[[ $RECOVERY_STRESS_SCOPE == candidate ]]

RECOVERY_UNEXPECTED_FIXTURE=0
if apo_test_candidate 3200 800 cpu-3200_gpu-800 combined; then
    echo 'same-boot stress transport loss was incorrectly accepted' >&2
    exit 1
fi
[[ $APO_LAST_CLASS == HARNESS_FAILURE ]]
[[ $APO_LAST_REASON == 'The worker failed without a structured result.' ]]
[[ $RECOVERY_STRESS_SCOPE == candidate ]]

# Restore the general success fixtures used by the remaining resume tests.
apo_run_stress() { ACTIONS+=("stress:$1:$3"); }
apo_recover_preserving_failure() { return 0; }

# Resume final validation at post-stress boot 2 of five. Endurance and boot 1
# are already checkpointed and must not run again.
ACTIONS=()
APO_STATE=()
apo_state_set RECOMMENDED_CPU 3000
apo_state_set RECOMMENDED_GPU 900
apo_state_set FINAL_TARGET_CPU 3000
apo_state_set FINAL_TARGET_GPU 900
apo_state_set FINAL_STAGE BOOT_2
apo_state_set VALIDATED 0
apo_final_validation
[[ ${ACTIONS[*]} == 'boot:final-post-stress-boot-2 normal:final-post-stress-normal-2 boot:final-post-stress-boot-3 normal:final-post-stress-normal-3 boot:final-post-stress-boot-4 normal:final-post-stress-normal-4 boot:final-post-stress-boot-5 normal:final-post-stress-normal-5 hash:final-completion' ]]
[[ $(apo_state_get STATUS) == PASS ]]
[[ $(apo_state_get PHASE) == COMPLETE ]]
[[ $(apo_state_get FINAL_CPU) == 3000 ]]
[[ $(apo_state_get FINAL_GPU) == 900 ]]
[[ $(apo_state_get VALIDATED) == 1 ]]
[[ $(apo_state_get VALIDATION_SCHEMA) == "$APO_CURRENT_VALIDATION_SCHEMA" ]]

# A saved stage beyond the immutable configured count is corrupt state, not a
# reason to silently skip directly into stress or completion.
ACTIONS=()
APO_STATE=()
apo_state_set CANDIDATE_LABEL cpu-3000_gpu-800
apo_state_set CANDIDATE_CPU 3000
apo_state_set CANDIDATE_GPU 800
apo_state_set CANDIDATE_STAGE BOOT_5
if apo_test_candidate 3000 800 cpu-3000_gpu-800 combined; then
    echo 'out-of-range candidate boot stage was accepted' >&2
    exit 1
fi
[[ $APO_LAST_CLASS == HARNESS_FAILURE ]]
[[ $APO_LAST_REASON == *'exceeds configured candidate_boots=4'* ]]
[[ ${#ACTIONS[@]} == 0 ]]

ACTIONS=()
APO_STATE=()
apo_state_set RECOMMENDED_CPU 3000
apo_state_set RECOMMENDED_GPU 900
apo_state_set FINAL_TARGET_CPU 3000
apo_state_set FINAL_TARGET_GPU 900
apo_state_set FINAL_STAGE NORMAL_6
if apo_final_validation; then
    echo 'out-of-range final boot stage was accepted' >&2
    exit 1
fi
[[ $(apo_state_get STATUS) == FAILED ]]
[[ $(apo_state_get FAILURE_REASON) == *'exceeds configured final_boots=5'* ]]
[[ ${#ACTIONS[@]} == 0 ]]

# The final clocks, validation schema, and PASS/COMPLETE markers are one atomic
# state checkpoint rather than two crash-separable writes.
APO_STATE=()
SAVE_COUNT=0
apo_state_complete 2900 850 28800
[[ $SAVE_COUNT == 1 ]]
[[ $(apo_state_get FINAL_CPU) == 2900 && $(apo_state_get FINAL_GPU) == 850 ]]
[[ $(apo_state_get VALIDATED) == 1 && $(apo_state_get STATUS) == PASS ]]

# Optional edge mode first checkpoints the completed production floor, then
# validates the next 25 MHz CPU step with a fixed 24-hour endurance segment.
APO_STATE=()
ACTIONS=()
STRESS_DURATIONS=()
seed_valid_guarded_auto_floor_plan
apo_boot_candidate() {
    ACTIONS+=("boot:$3")
    apo_state_set TRYBOOT_EXPECTED 1
    apo_state_set CURRENT_CPU "$1"
    apo_state_set CURRENT_GPU "$2"
}
apo_run_stress() { ACTIONS+=("stress:$1:$3"); STRESS_DURATIONS+=("$2"); }
apo_state_set RECOMMENDED_CPU 3000
apo_state_set RECOMMENDED_GPU 900
apo_state_set FINAL_TARGET_CPU 3000
apo_state_set FINAL_TARGET_GPU 900
apo_state_set FINAL_STAGE VERIFY
apo_state_set VALIDATION_DURATION_S 28800
apo_state_set EDGE_CPU_STATUS NOT_REQUESTED
apo_state_set VALIDATED 0
apo_final_validation
[[ $(apo_state_get FLOOR_CPU) == 3000 && $(apo_state_get FLOOR_GPU) == 900 ]]
[[ $(apo_state_get FLOOR_VALIDATED) == 1 ]]
[[ $(apo_state_get EDGE_CPU_TARGET) == 3025 ]]
[[ $(apo_state_get EDGE_CPU_STATUS) == PASS ]]
[[ $(apo_state_get FINAL_CPU) == 3025 && $(apo_state_get FINAL_GPU) == 900 ]]
[[ $(apo_state_get VALIDATION_DURATION_S) == 86400 ]]
[[ " ${STRESS_DURATIONS[*]} " == *' 86400 '* ]]
apo_state_set FINAL_CPU 3200
if apo_validate_auto_resume_state; then
    echo 'edge completion with final clocks outside its validated target was accepted' >&2
    exit 1
fi
[[ $(apo_state_get FAILURE_CLASS) == HARNESS_FAILURE ]]

# A genuine edge stability failure retains the already validated floor. A
# failed experiment must not erase the safe eight-hour result.
APO_STATE=()
ACTIONS=()
seed_valid_guarded_auto_floor_plan
apo_state_set RECOMMENDED_CPU 3000
apo_state_set RECOMMENDED_GPU 900
apo_state_set FINAL_TARGET_CPU 3000
apo_state_set FINAL_TARGET_GPU 900
apo_state_set FINAL_STAGE VERIFY
apo_state_set VALIDATION_DURATION_S 28800
apo_state_set EDGE_CPU_STATUS NOT_REQUESTED
apo_state_set VALIDATED 0
apo_boot_candidate() {
    if (( $1 == 3025 )); then
        APO_LAST_CLASS=STABILITY_FAILURE
        APO_LAST_REASON='edge fixture failed'
        return 1
    fi
    apo_state_set TRYBOOT_EXPECTED 1
    apo_state_set CURRENT_CPU "$1"
    apo_state_set CURRENT_GPU "$2"
}
apo_final_validation
[[ $(apo_state_get STATUS) == PASS && $(apo_state_get PHASE) == COMPLETE ]]
[[ $(apo_state_get EDGE_CPU_STATUS) == REJECTED ]]
[[ $(apo_state_get EDGE_CPU_FAILURE_CLASS) == STABILITY_FAILURE ]]
[[ $(apo_state_get FINAL_CPU) == 3000 && $(apo_state_get FINAL_GPU) == 900 ]]
[[ $(apo_state_get FINAL_TARGET_CPU) == 3000 && $(apo_state_get FINAL_TARGET_GPU) == 900 ]]
[[ $(apo_state_get VALIDATED) == 1 ]]
[[ $(apo_state_get VALIDATION_DURATION_S) == 28800 ]]

# A recovered boundary during the isolated two-hour GPU qualification lowers
# only GPU by 25 MHz and repeats that qualification at the lower clock.
APO_STATE=()
ACTIONS=()
seed_valid_guarded_auto_floor_plan
APO_EDGE_CPU_24H=0
apo_state_set RECOMMENDED_CPU 3000
apo_state_set RECOMMENDED_GPU 900
apo_state_set FINAL_TARGET_CPU 3000
apo_state_set FINAL_TARGET_GPU 900
apo_state_set GPU_QUALIFICATION_STATUS NOT_STARTED
apo_state_set GPU_QUALIFICATION_CPU 3000
apo_state_set GPU_QUALIFICATION_TARGET 900
apo_state_set GPU_QUALIFIED_CPU ''
apo_state_set GPU_QUALIFIED_CLOCK ''
apo_state_set PHASE GPU_QUALIFICATION
apo_state_set STATUS RUNNING
GPU_QUALIFICATION_FAILURES=0
apo_test_candidate() {
    ACTIONS+=("qualify:$4:$1/$2:$5")
    if (( GPU_QUALIFICATION_FAILURES == 0 )); then
        GPU_QUALIFICATION_FAILURES=1
        APO_LAST_CLASS=STABILITY_FAILURE
        APO_LAST_REASON='GPU qualification fixture rebooted autonomously'
        return 1
    fi
    APO_LAST_CLASS=PASS
    APO_LAST_REASON='qualification passed'
}
apo_qualify_gpu
[[ $GPU_QUALIFICATION_FAILURES == 1 ]]
[[ $(apo_state_get FINAL_BACKOFF_COUNT) == 1 ]]
[[ $(apo_state_get FINAL_BACKOFF_CPU) == 3000 ]]
[[ $(apo_state_get FINAL_BACKOFF_GPU) == 875 ]]
[[ $(apo_state_get FINAL_BACKOFF_HISTORY) == 'GPU:900>875' ]]
[[ $(apo_state_get FINAL_BACKOFF_LAST_STAGE) == GPU_QUALIFICATION ]]
[[ $(apo_state_get GPU_QUALIFICATION_STATUS) == PASS ]]
[[ $(apo_state_get GPU_QUALIFIED_CPU) == 3000 && $(apo_state_get GPU_QUALIFIED_CLOCK) == 875 ]]
[[ " ${ACTIONS[*]} " == *' qualify:gpu:3000/900:7200 '* ]]
[[ " ${ACTIONS[*]} " == *' qualify:gpu:3000/875:7200 '* ]]
apo_validate_auto_resume_state

# The first CPU qualification happens before a final GPU guard can be bound to
# its backoff history. A recovered failure lowers CPU by 50 MHz, repeats the
# full two-hour CPU qualification, and remains valid when GPU search begins.
APO_STATE=()
ACTIONS=()
seed_valid_guarded_auto_floor_plan
APO_EDGE_CPU_24H=0
apo_state_set GPU_INDEX 0
apo_state_set PASSED_GPUS ''
apo_state_set GPU_FAILURE_BOUNDARY ''
apo_state_set GPU_REFINE_CANDIDATES ''
apo_state_set GPU_REFINE_INDEX 0
apo_state_set GPU_REFINE_COMPLETE 0
apo_state_set GPU_GUARD_TARGET ''
apo_state_set GPU_GUARD_VERIFIED 0
apo_state_set SAFE_GPU ''
apo_state_set CPU_QUALIFICATION_STATUS NOT_STARTED
apo_state_set CPU_QUALIFICATION_TARGET 3000
apo_state_set CPU_QUALIFIED_CLOCK ''
apo_state_set CPU_QUALIFICATION_HISTORY ''
apo_state_set CPU_QUALIFICATION_LAST_CLASS ''
apo_state_set CPU_QUALIFICATION_LAST_REASON ''
apo_state_set GPU_QUALIFICATION_STATUS NOT_STARTED
apo_state_set GPU_QUALIFICATION_CPU ''
apo_state_set GPU_QUALIFICATION_TARGET ''
apo_state_set GPU_QUALIFIED_CPU ''
apo_state_set GPU_QUALIFIED_CLOCK ''
apo_state_set RECOMMENDED_CPU 3000
apo_state_set RECOMMENDED_GPU ''
apo_state_set FINAL_TARGET_CPU ''
apo_state_set FINAL_TARGET_GPU ''
apo_state_set PHASE CPU_QUALIFICATION
apo_state_set SUBPHASE READY
CPU_QUALIFICATION_FAILURES=0
apo_test_candidate() {
    ACTIONS+=("qualify:$4:$1/$2:$5")
    if (( CPU_QUALIFICATION_FAILURES == 0 )); then
        CPU_QUALIFICATION_FAILURES=1
        APO_LAST_CLASS=BOOT_FAILURE
        APO_LAST_REASON='CPU qualification fixture failed its candidate boot'
        return 1
    fi
    APO_LAST_CLASS=PASS
    APO_LAST_REASON='qualification passed'
}
apo_qualify_cpu
[[ $CPU_QUALIFICATION_FAILURES == 1 ]]
[[ $(apo_state_get CPU_QUALIFICATION_STATUS) == PASS ]]
[[ $(apo_state_get CPU_QUALIFIED_CLOCK) == 2950 ]]
[[ $(apo_state_get CPU_QUALIFICATION_HISTORY) == 'CPU:3000>2950' ]]
[[ $(apo_state_get FINAL_BACKOFF_COUNT) == 0 ]]
[[ " ${ACTIONS[*]} " == *' qualify:cpu:3000/800:7200 '* ]]
[[ " ${ACTIONS[*]} " == *' qualify:cpu:2950/800:7200 '* ]]
apo_state_set PHASE GPU_SWEEP
apo_state_set SUBPHASE READY
apo_validate_auto_resume_state

# CPU qualification uses the wider 50 MHz CPU production guard. A proven
# combined-endurance failure cannot identify one domain, so it lowers every
# still-overclocked domain by its guard in one recorded paired step.
APO_STATE=()
seed_valid_guarded_auto_floor_plan
APO_EDGE_CPU_24H=0
apo_state_set RECOMMENDED_CPU 3000
apo_state_set RECOMMENDED_GPU 900
apo_state_set FINAL_TARGET_CPU 3000
apo_state_set FINAL_TARGET_GPU 900
apo_state_set FINAL_STAGE ''
apo_final_schedule_stress_backoff CPU_QUALIFICATION STABILITY_FAILURE 'CPU qualification fixture failed'
[[ $(apo_state_get RECOMMENDED_CPU) == 2950 ]]
[[ $(apo_state_get RECOMMENDED_GPU) == 900 ]]
[[ $(apo_state_get FINAL_BACKOFF_HISTORY) == 'CPU:3000>2950' ]]
apo_validate_auto_resume_state
apo_final_schedule_stress_backoff ENDURANCE BOOT_FAILURE 'combined pair failed during a required boot'
[[ $(apo_state_get RECOMMENDED_CPU) == 2900 ]]
[[ $(apo_state_get RECOMMENDED_GPU) == 875 ]]
[[ $(apo_state_get FINAL_BACKOFF_COUNT) == 2 ]]
[[ $(apo_state_get FINAL_BACKOFF_HISTORY) == 'CPU:3000>2950,PAIR:2950/900>2900/875' ]]
[[ $(apo_state_get FINAL_BACKOFF_LAST_STAGE) == ENDURANCE ]]
apo_validate_auto_resume_state
if apo_final_schedule_stress_backoff CPU_QUALIFICATION HARNESS_FAILURE 'unproved workload'; then
    echo 'final harness failure was incorrectly converted into a clock backoff' >&2
    exit 1
fi

# A live recovered reboot during ordinary combined endurance immediately
# restarts complete validation at the paired backoff, without attributing the
# reboot to CPU or GPU alone.
APO_STATE=()
ACTIONS=()
seed_valid_guarded_auto_floor_plan
APO_EDGE_CPU_24H=0
apo_state_set RECOMMENDED_CPU 3000
apo_state_set RECOMMENDED_GPU 900
apo_state_set FINAL_TARGET_CPU 3000
apo_state_set FINAL_TARGET_GPU 900
apo_state_set FINAL_STAGE ENDURANCE
apo_state_set PHASE FINAL_VALIDATION
apo_state_set STATUS RUNNING
ENDURANCE_FAILURES=0
apo_boot_candidate() {
    ACTIONS+=("boot:$3")
    apo_state_set TRYBOOT_EXPECTED 1
    apo_state_set CURRENT_CPU "$1"
    apo_state_set CURRENT_GPU "$2"
}
apo_recover_stress_failure() {
    ACTIONS+=("recover:$1")
    APO_LAST_CLASS=$2
    APO_LAST_REASON=$3
    apo_return_normal "$1"
}
apo_run_stress() {
    ACTIONS+=("stress:$1:$3")
    if [[ $3 == final-endurance && $ENDURANCE_FAILURES == 0 ]]; then
        ENDURANCE_FAILURES=1
        APO_LAST_CLASS=STABILITY_FAILURE
        APO_LAST_REASON='combined endurance fixture rebooted autonomously'
        APO_LAST_RESULT_STRUCTURED=0
        return 1
    fi
    APO_LAST_RESULT_STRUCTURED=1
}
if apo_final_validation; then
    echo 'combined endurance failure did not request automatic qualification backoff' >&2
    exit 1
else
    [[ $? == 2 ]]
fi
apo_test_candidate() {
    ACTIONS+=("qualify:$4:$1/$2:$5")
    APO_LAST_CLASS=PASS
    APO_LAST_REASON='qualification passed'
}
apo_run_tuning
[[ $ENDURANCE_FAILURES == 1 ]]
[[ $(apo_state_get FINAL_BACKOFF_COUNT) == 1 ]]
[[ $(apo_state_get FINAL_BACKOFF_CPU) == 2950 ]]
[[ $(apo_state_get FINAL_BACKOFF_GPU) == 875 ]]
[[ $(apo_state_get FINAL_BACKOFF_HISTORY) == 'PAIR:3000/900>2950/875' ]]
[[ $(apo_state_get FINAL_BACKOFF_LAST_STAGE) == ENDURANCE ]]
[[ $(apo_state_get FINAL_CPU) == 2950 && $(apo_state_get FINAL_GPU) == 875 ]]
[[ $(apo_state_get STATUS) == PASS && $(apo_state_get PHASE) == COMPLETE ]]
[[ " ${ACTIONS[*]} " == *' recover:final-endurance-recovery '* ]]
[[ " ${ACTIONS[*]} " == *' stress:combined:final-endurance '* ]]
[[ " ${ACTIONS[*]} " != *' final-cpu-only '* ]]
[[ " ${ACTIONS[*]} " != *' final-gpu-only '* ]]
[[ " ${ACTIONS[*]} " == *' qualify:cpu:2950/800:7200 '* ]]
[[ " ${ACTIONS[*]} " == *' qualify:gpu:2950/875:7200 '* ]]
apo_validate_auto_resume_state

# Ordered history is safety evidence, not a free-form recommendation override.
apo_state_set FINAL_BACKOFF_HISTORY 'CPU:3000>2975'
if apo_validate_auto_resume_state; then
    echo 'malformed final backoff history was accepted' >&2
    exit 1
fi
[[ $(apo_state_get FAILURE_CLASS) == HARNESS_FAILURE ]]

# A recovered schema-7 domain-specific final-stress failure is upgraded in
# place and immediately backed off without repeating the failed clock.
APO_STATE=()
seed_valid_guarded_auto_floor_plan
APO_EDGE_CPU_24H=0
apo_state_set RUN_SCHEMA 7
apo_state_set CFG_AUTO_GENERATED_CANDIDATES 1
apo_state_set ORIGIN_COMMAND overclock
apo_state_set STATUS FAILED
apo_state_set PHASE FINAL_VALIDATION
apo_state_set FAILURE_CLASS STABILITY_FAILURE
apo_state_set FAILURE_REASON 'verified autonomous GPU stress reboot'
apo_state_set RECOMMENDED_CPU 3000
apo_state_set RECOMMENDED_GPU 900
apo_state_set FINAL_TARGET_CPU 3000
apo_state_set FINAL_TARGET_GPU 900
apo_state_set FINAL_STAGE GPU_STRESS
apo_state_set TRYBOOT_EXPECTED 0
apo_state_set TRYBOOT_FILE_MAY_EXIST 0
apo_final_migrate_legacy_retry_state 7
[[ $(apo_state_get RUN_SCHEMA) == "$APO_CURRENT_RUN_SCHEMA" ]]
[[ $(apo_state_get FINAL_BACKOFF_COUNT) == 1 ]]
[[ $(apo_state_get RECOMMENDED_GPU) == 875 ]]
[[ $(apo_state_get PHASE) == GPU_QUALIFICATION ]]
[[ $(apo_state_get FAILURE_CLASS) == '' ]]
apo_validate_auto_resume_state

# A recovered schema-7 combined-endurance failure also has enough retained
# domain ambiguity to use the conservative paired backoff: both still-raised
# clocks are lowered and both qualifications restart.
APO_STATE=()
seed_valid_guarded_auto_floor_plan
APO_EDGE_CPU_24H=0
apo_state_set RUN_SCHEMA 7
apo_state_set CFG_AUTO_GENERATED_CANDIDATES 1
apo_state_set ORIGIN_COMMAND overclock
apo_state_set STATUS FAILED
apo_state_set PHASE FINAL_VALIDATION
apo_state_set FAILURE_CLASS STABILITY_FAILURE
apo_state_set FAILURE_REASON 'legacy combined-endurance failure'
apo_state_set RECOMMENDED_CPU 3000
apo_state_set RECOMMENDED_GPU 900
apo_state_set FINAL_TARGET_CPU 3000
apo_state_set FINAL_TARGET_GPU 900
apo_state_set FINAL_STAGE ENDURANCE
apo_state_set TRYBOOT_EXPECTED 0
apo_state_set TRYBOOT_FILE_MAY_EXIST 0
apo_final_migrate_legacy_retry_state 7
[[ $(apo_state_get RUN_SCHEMA) == "$APO_CURRENT_RUN_SCHEMA" ]]
[[ $(apo_state_get FINAL_BACKOFF_COUNT) == 1 ]]
[[ $(apo_state_get FINAL_BACKOFF_HISTORY) == 'PAIR:3000/900>2950/875' ]]
[[ $(apo_state_get RECOMMENDED_CPU) == 2950 && $(apo_state_get RECOMMENDED_GPU) == 875 ]]
[[ $(apo_state_get PHASE) == CPU_QUALIFICATION ]]
apo_validate_auto_resume_state

# An interrupted schema-8 combined-validation checkpoint is not trusted as a
# qualification pass. It keeps its search evidence but restarts with isolated
# CPU qualification under schema 9 before any GPU or combined validation.
APO_STATE=()
seed_valid_guarded_auto_floor_plan
APO_EDGE_CPU_24H=0
apo_state_set RUN_SCHEMA 8
apo_state_set CFG_AUTO_GENERATED_CANDIDATES 1
apo_state_set ORIGIN_COMMAND overclock
apo_state_set STATUS INTERRUPTED
apo_state_set PHASE FINAL_VALIDATION
apo_state_set SUBPHASE ENDURANCE
apo_state_set RECOMMENDED_CPU 3000
apo_state_set RECOMMENDED_GPU 900
apo_state_set FINAL_TARGET_CPU 3000
apo_state_set FINAL_TARGET_GPU 900
apo_state_set FINAL_STAGE ENDURANCE
apo_state_set TRYBOOT_EXPECTED 0
apo_state_set TRYBOOT_FILE_MAY_EXIST 0
apo_migrate_active_automatic_state 8
[[ $(apo_state_get RUN_SCHEMA) == "$APO_CURRENT_RUN_SCHEMA" ]]
[[ $(apo_state_get PHASE) == CPU_QUALIFICATION ]]
[[ $(apo_state_get CPU_QUALIFICATION_STATUS) == NOT_STARTED ]]
[[ $(apo_state_get GPU_QUALIFICATION_STATUS) == NOT_STARTED ]]
[[ $(apo_state_get FINAL_STAGE) == '' ]]
apo_validate_auto_resume_state

# A valid mid-refinement checkpoint is resumable, but malformed clock-bearing
# state is rejected before any candidate action or arithmetic can occur.
APO_STATE=()
ACTIONS=()
seed_valid_guarded_auto_floor_plan
apo_state_set CPU_FAILURE_BOUNDARY 3100
apo_state_set CPU_REFINE_CANDIDATES 3025,3050,3075
apo_state_set CPU_REFINE_INDEX 1
apo_state_set CPU_REFINE_COMPLETE 0
apo_state_set CPU_GUARD_TARGET ''
apo_state_set CPU_GUARD_VERIFIED 0
apo_state_set SAFE_CPU ''
apo_state_set CPU_QUALIFICATION_STATUS NOT_STARTED
apo_state_set CPU_QUALIFICATION_TARGET ''
apo_state_set CPU_QUALIFIED_CLOCK ''
apo_state_set GPU_QUALIFICATION_STATUS NOT_STARTED
apo_state_set GPU_QUALIFICATION_CPU ''
apo_state_set GPU_QUALIFICATION_TARGET ''
apo_state_set GPU_QUALIFIED_CPU ''
apo_state_set GPU_QUALIFIED_CLOCK ''
apo_validate_auto_resume_state
[[ ${#ACTIONS[@]} == 0 ]]

apo_state_set CPU_FAILURE_BOUNDARY 3050
if apo_validate_auto_resume_state; then
    echo 'refinement plan at or above its saved failure boundary was accepted' >&2
    exit 1
fi
[[ $(apo_state_get FAILURE_CLASS) == HARNESS_FAILURE ]]

APO_STATE=()
seed_valid_guarded_auto_floor_plan
apo_state_set CPU_FAILURE_BOUNDARY malformed
if apo_validate_auto_resume_state; then
    echo 'malformed automatic boundary was accepted' >&2
    exit 1
fi
[[ $(apo_state_get STATUS) == FAILED ]]
[[ $(apo_state_get FAILURE_CLASS) == HARNESS_FAILURE ]]
[[ ${#ACTIONS[@]} == 0 ]]

# Single-digit post-endurance boot and normal-recovery checkpoints are valid
# resumable stages when the ordinary eight-hour duration is already recorded.
for resume_stage in BOOT_1 NORMAL_1; do
    APO_STATE=()
    seed_valid_guarded_auto_floor_plan
    APO_EDGE_CPU_24H=0
    apo_state_set RECOMMENDED_CPU 3000
    apo_state_set RECOMMENDED_GPU 900
    apo_state_set FINAL_TARGET_CPU 3000
    apo_state_set FINAL_TARGET_GPU 900
    apo_state_set FINAL_STAGE "$resume_stage"
    apo_state_set VALIDATION_DURATION_S 28800
    apo_validate_auto_resume_state
done

# A running edge checkpoint cannot jump to VERIFY without a completed 24-hour
# endurance checkpoint.
APO_STATE=()
seed_valid_guarded_auto_floor_plan
apo_state_set FLOOR_CPU 3000
apo_state_set FLOOR_GPU 900
apo_state_set FLOOR_DURATION_S 28800
apo_state_set FLOOR_VALIDATION_SCHEMA "$APO_CURRENT_VALIDATION_SCHEMA"
apo_state_set FLOOR_VALIDATED 1
apo_state_set EDGE_CPU_TARGET 3025
apo_state_set EDGE_CPU_STATUS RUNNING
apo_state_set RECOMMENDED_CPU 3025
apo_state_set RECOMMENDED_GPU 900
apo_state_set FINAL_TARGET_CPU 3025
apo_state_set FINAL_TARGET_GPU 900
apo_state_set FINAL_STAGE VERIFY
if apo_validate_auto_resume_state; then
    echo 'edge VERIFY checkpoint without 24-hour duration evidence was accepted' >&2
    exit 1
fi
[[ $(apo_state_get FAILURE_CLASS) == HARNESS_FAILURE ]]

# Stale or incomplete floor evidence cannot be converted into an applyable
# PASS after an edge stability failure.
APO_STATE=()
ACTIONS=()
seed_valid_guarded_auto_floor_plan
apo_state_set FLOOR_CPU 3000
apo_state_set FLOOR_GPU 900
apo_state_set FLOOR_DURATION_S 60
apo_state_set FLOOR_VALIDATION_SCHEMA "$APO_CURRENT_VALIDATION_SCHEMA"
apo_state_set FLOOR_VALIDATED 1
apo_state_set EDGE_CPU_TARGET 3025
apo_state_set EDGE_CPU_STATUS RUNNING
apo_state_set RECOMMENDED_CPU 3025
apo_state_set RECOMMENDED_GPU 900
apo_state_set FINAL_TARGET_CPU 3025
apo_state_set FINAL_TARGET_GPU 900
apo_state_set VALIDATED 0
if apo_final_record_failure stale-floor-recovery STABILITY_FAILURE 'edge fixture failed'; then
    echo 'stale production-floor evidence was retained' >&2
    exit 1
fi
[[ $(apo_state_get STATUS) == FAILED ]]
[[ $(apo_state_get FAILURE_CLASS) == HARNESS_FAILURE ]]
[[ $(apo_state_get VALIDATED) == 0 ]]

# Harness failures do not define a silicon edge and therefore never retain the
# floor as a successful run, even when normal recovery itself succeeds.
APO_STATE=()
seed_valid_guarded_auto_floor_plan
apo_state_set FLOOR_CPU 3000
apo_state_set FLOOR_GPU 900
apo_state_set FLOOR_DURATION_S 28800
apo_state_set FLOOR_VALIDATION_SCHEMA "$APO_CURRENT_VALIDATION_SCHEMA"
apo_state_set FLOOR_VALIDATED 1
apo_state_set EDGE_CPU_TARGET 3025
apo_state_set EDGE_CPU_STATUS RUNNING
apo_state_set RECOMMENDED_CPU 3025
apo_state_set RECOMMENDED_GPU 900
apo_state_set FINAL_TARGET_CPU 3025
apo_state_set FINAL_TARGET_GPU 900
apo_state_set VALIDATED 0
if apo_final_record_failure edge-harness-recovery HARNESS_FAILURE 'edge harness failed'; then
    echo 'edge harness failure incorrectly retained the floor as PASS' >&2
    exit 1
fi
[[ $(apo_state_get STATUS) == FAILED ]]
[[ $(apo_state_get FAILURE_CLASS) == HARNESS_FAILURE ]]
[[ $(apo_state_get VALIDATED) == 0 ]]

# A proven autonomous reboot during optional edge stress is a real stability
# rejection, so the already validated production floor remains the final PASS.
APO_STATE=()
seed_valid_guarded_auto_floor_plan
apo_state_set FLOOR_CPU 3000
apo_state_set FLOOR_GPU 900
apo_state_set FLOOR_DURATION_S 28800
apo_state_set FLOOR_VALIDATION_SCHEMA "$APO_CURRENT_VALIDATION_SCHEMA"
apo_state_set FLOOR_VALIDATED 1
apo_state_set EDGE_CPU_TARGET 3025
apo_state_set EDGE_CPU_STATUS RUNNING
apo_state_set RECOMMENDED_CPU 3025
apo_state_set RECOMMENDED_GPU 900
apo_state_set FINAL_TARGET_CPU 3025
apo_state_set FINAL_TARGET_GPU 900
apo_state_set PHASE FINAL_VALIDATION
apo_state_set FINAL_STAGE ENDURANCE
apo_state_set TRYBOOT_EXPECTED 1
apo_state_set LAST_BOOT_ID edge-candidate-boot
apo_state_set CANDIDATE_BOOT_ID edge-candidate-boot
apo_state_set CURRENT_CPU 3025
apo_state_set CURRENT_GPU 900
apo_state_set VALIDATED 0
APO_BOOT_TIMEOUT=300
APO_BOOT_SETTLE_SECONDS=0
APO_REMOTE_WORKER=/tmp/edge-fixture-worker
EDGE_RECOVERY_REBOOTS=0
# Restore the production recovery path after the lightweight resume fixtures
# above replaced its transport boundary.
source "$ROOT/lib/recovery.sh"
apo_wait_for_ssh() { return 0; }
apo_remote_boot_id() { printf edge-watchdog-normal-boot; }
apo_ensure_worker_for_boot() { return 0; }
apo_remote_tryboot_flag() { printf 00000000; }
apo_remote_worker() { EDGE_RECOVERY_REBOOTS=$((EDGE_RECOVERY_REBOOTS + 1)); }
apo_health_check() { return 0; }
apo_final_record_failure edge-watchdog-recovery HARNESS_FAILURE 'The worker failed without a structured result.' 0
[[ $EDGE_RECOVERY_REBOOTS == 0 ]]
[[ $APO_RECOVERY_UNEXPECTED_CANDIDATE_REBOOT == 1 ]]
[[ $APO_RECOVERY_UNEXPECTED_REBOOT_FROM == edge-candidate-boot ]]
[[ $APO_RECOVERY_UNEXPECTED_REBOOT_TO == edge-watchdog-normal-boot ]]
[[ $(apo_state_get STATUS) == PASS && $(apo_state_get PHASE) == COMPLETE ]]
[[ $(apo_state_get EDGE_CPU_STATUS) == REJECTED ]]
[[ $(apo_state_get EDGE_CPU_FAILURE_CLASS) == STABILITY_FAILURE ]]
[[ $(apo_state_get FINAL_CPU) == 3000 && $(apo_state_get FINAL_GPU) == 900 ]]
[[ $(apo_state_get VALIDATION_DURATION_S) == 28800 ]]
APO_RECOVERY_UNEXPECTED_CANDIDATE_REBOOT=0
# Restore the lightweight boundaries expected by the remaining state-only
# assertions in this script.
apo_return_normal() {
    ACTIONS+=("normal:$1")
    apo_state_set TRYBOOT_EXPECTED 0
    apo_state_set CURRENT_CPU ''
    apo_state_set CURRENT_GPU ''
}
apo_recover_preserving_failure() { return 0; }

# Applying a validated auto result changes the live/permanent normal clocks,
# but the immutable stock baseline must still make the completed state safe to
# reload. The same clock rewrite on an unapplied run is inconsistent.
APO_STATE=()
seed_valid_guarded_auto_floor_plan
APO_EDGE_CPU_24H=0
apo_state_set FLOOR_VALIDATED 0
apo_state_set EDGE_CPU_STATUS NOT_REQUESTED
apo_state_set SAFE_CPU 3000
apo_state_set SAFE_GPU 900
apo_state_set RECOMMENDED_CPU 3000
apo_state_set RECOMMENDED_GPU 900
apo_state_set FINAL_CPU 3000
apo_state_set FINAL_GPU 900
apo_state_set FINAL_TARGET_CPU 3000
apo_state_set FINAL_TARGET_GPU 900
apo_state_set VALIDATED 1
apo_state_set VALIDATION_SCHEMA "$APO_CURRENT_VALIDATION_SCHEMA"
apo_state_set VALIDATION_DURATION_S 28800
apo_state_set STATUS PASS
apo_state_set PHASE COMPLETE
apo_state_set FINAL_STAGE COMPLETE
APO_NORMAL_CPU=3000
APO_NORMAL_GPU=900
APO_NORMAL_VOLTAGE=0
apo_state_set APPLY_STATUS APPLIED
apo_validate_auto_resume_state

apo_state_set APPLY_STATUS NOT_APPLIED
if apo_validate_auto_resume_state; then
    echo 'unapplied auto state accepted applied normal clocks' >&2
    exit 1
fi
[[ $(apo_state_get FAILURE_CLASS) == HARNESS_FAILURE ]]

# A later, separately recorded edge run starts from the already-applied floor,
# retains headless mode, and executes 86,400-second edge endurance directly.
# It never repeats the source run's 28,800-second endurance phase.
APO_STATE=()
ACTIONS=()
seed_valid_guarded_auto_floor_plan
APO_MODE_EFFECTIVE=headless
APO_REQUIRE_GPU_STRESS=1
APO_NORMAL_CPU=3000
APO_NORMAL_GPU=900
APO_NORMAL_VOLTAGE=0
apo_state_set RUN_ID 20260828-010203-3333333333333333
apo_state_set POST_FLOOR_EDGE 1
apo_state_set SOURCE_FLOOR_RUN_ID 20260827-010203-2222222222222222
apo_state_set SOURCE_FLOOR_PERMANENT_HASH aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
apo_state_set PERMANENT_HASH aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
apo_state_set FLOOR_CPU 3000
apo_state_set FLOOR_GPU 900
apo_state_set FLOOR_DURATION_S 28800
apo_state_set FLOOR_VALIDATION_SCHEMA "$APO_CURRENT_VALIDATION_SCHEMA"
apo_state_set FLOOR_VALIDATED 1
apo_state_set EDGE_CPU_TARGET 3025
apo_state_set EDGE_CPU_STATUS RUNNING
apo_state_set RECOMMENDED_CPU 3025
apo_state_set RECOMMENDED_GPU 900
apo_state_set FINAL_TARGET_CPU 3025
apo_state_set FINAL_TARGET_GPU 900
apo_state_set FINAL_STAGE PRE_STRESS_BOOT
apo_state_set STATUS RUNNING
apo_state_set PHASE FINAL_VALIDATION
apo_state_set VALIDATED 0
apo_state_set APPLY_STATUS NOT_APPLIED
apo_boot_candidate() {
    ACTIONS+=("boot:$3")
    apo_state_set TRYBOOT_EXPECTED 1
    apo_state_set CURRENT_CPU "$1"
    apo_state_set CURRENT_GPU "$2"
}
apo_return_normal() {
    ACTIONS+=("normal:$1")
    apo_state_set TRYBOOT_EXPECTED 0
    apo_state_set CURRENT_CPU ''
    apo_state_set CURRENT_GPU ''
}
apo_run_stress() { ACTIONS+=("stress:$1:$2:$3"); }
apo_health_check() { ACTIONS+=("health:$4"); }
apo_verify_permanent_hash() { ACTIONS+=("hash:$1"); }
apo_validate_auto_resume_state
apo_final_validation
[[ $APO_MODE_EFFECTIVE == headless ]]
[[ $(apo_state_get EDGE_CPU_STATUS) == PASS ]]
[[ $(apo_state_get VALIDATION_DURATION_S) == 86400 ]]
[[ " ${ACTIONS[*]} " == *' stress:combined:86400:final-endurance '* ]]
[[ " ${ACTIONS[*]} " != *':28800:'* ]]

# Old automatic states without immutable provenance fail closed; explicit-plan
# states do not inherit the configuration-free stock gate.
APO_STATE=()
APO_NORMAL_CPU=2400
APO_NORMAL_GPU=800
APO_NORMAL_VOLTAGE=0
seed_valid_guarded_auto_floor_plan
APO_AUTO_BASELINE_PROVENANCE=missing
if apo_validate_auto_resume_state; then
    echo 'automatic state without immutable provenance was accepted' >&2
    exit 1
fi
[[ $(apo_state_get FAILURE_CLASS) == HARNESS_FAILURE ]]

# Downgrading only the persisted auto marker cannot reinterpret an automatic
# run as an explicit plan and bypass its stock, refinement, guard, and final
# identity checks.
APO_STATE=()
seed_valid_guarded_auto_floor_plan
APO_AUTO_GENERATED_CANDIDATES=0
APO_EDGE_CPU_24H=0
if apo_validate_auto_resume_state; then
    echo 'automatic state with a downgraded origin marker was accepted as explicit' >&2
    exit 1
fi
[[ $(apo_state_get FAILURE_CLASS) == HARNESS_FAILURE ]]

# A genuine explicit-plan state carries none of the automatic-only evidence.
APO_STATE=()
APO_AUTO_GENERATED_CANDIDATES=0
APO_EDGE_CPU_24H=0
APO_AUTO_BASELINE_CPU=''
APO_AUTO_BASELINE_GPU=''
APO_AUTO_BASELINE_VOLTAGE=''
APO_AUTO_BASELINE_PROVENANCE=''
APO_AUTO_BASELINE_EVIDENCE=''
apo_validate_auto_resume_state

printf 'test_resume_progress: PASS\n'
