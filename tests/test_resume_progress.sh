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
    [FINAL_DURATION_S]=86400
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
apo_recover_preserving_failure() { RECOVERY_FORCE_REBOOT=${4:-0}; APO_LAST_CLASS=$2; APO_LAST_REASON=$3; return 0; }
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

# Tron regression: a saved candidate boot may have exhausted its old audio-only
# retry budget before alpha.47. Once the same boot gate succeeds under the new
# advisory inferred-audio policy, that exact durable retry counter is cleared.
apo_state_set TRANSIENT_RETRY_CONTEXT cpu-2950_gpu-1200-boot-1
apo_state_set TRANSIENT_RETRY_COUNT 5
apo_candidate_boot_or_preserve_failure 2950 1200 cpu-2950_gpu-1200-boot-1 cpu-2950_gpu-1200-boot-1-recovery
[[ -z $(apo_state_get TRANSIENT_RETRY_CONTEXT '') ]]
[[ $(apo_state_get TRANSIENT_RETRY_COUNT) == 0 ]]
ACTIONS=()

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
# a silicon stability boundary, while same-boot transport loss receives only
# bounded complete-gate retries and remains harness uncertainty if exhausted.
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
    APO_LAST_CLASS=$2
    APO_LAST_REASON=$3
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
[[ $APO_LAST_REASON == *'The worker failed without a structured result.'* ]]
[[ $APO_LAST_REASON == *'exhausted 5 bounded retries'* ]]
[[ $RECOVERY_STRESS_SCOPE == candidate ]]

# A structured harness failure is retried only after normal recovery. Prove
# that several consecutive failures do not terminate an unattended run and
# that a later complete gate clears its durable retry counter.
ACTIONS=()
APO_STATE=()
apo_state_set CANDIDATE_LABEL cpu-3000_gpu-800
apo_state_set CANDIDATE_CPU 3000
apo_state_set CANDIDATE_GPU 800
apo_state_set CANDIDATE_STAGE STRESS
apo_state_set TRYBOOT_EXPECTED 1
apo_state_set CURRENT_CPU 3000
apo_state_set CURRENT_GPU 800
STRUCTURED_STRESS_ATTEMPTS=0
apo_run_stress() {
    STRUCTURED_STRESS_ATTEMPTS=$((STRUCTURED_STRESS_ATTEMPTS + 1))
    if (( STRUCTURED_STRESS_ATTEMPTS <= 3 )); then
        APO_LAST_CLASS=HARNESS_FAILURE
        APO_LAST_REASON='CPU stress exited early with rc=0.'
        APO_LAST_RESULT_STRUCTURED=1
        return 1
    fi
    ACTIONS+=("stress:$1:$3")
    APO_LAST_RESULT_STRUCTURED=1
}
apo_recover_preserving_failure() {
    APO_LAST_CLASS=$2
    APO_LAST_REASON=$3
    APO_RECOVERY_UNEXPECTED_CANDIDATE_REBOOT=0
    apo_state_set TRYBOOT_EXPECTED 0
    apo_state_set CURRENT_CPU ''
    apo_state_set CURRENT_GPU ''
}
apo_test_candidate 3000 800 cpu-3000_gpu-800 combined
[[ $STRUCTURED_STRESS_ATTEMPTS == 4 ]]
[[ $(apo_state_get CANDIDATE_STAGE) == COMPLETE ]]
[[ $(apo_state_get TRANSIENT_RETRY_COUNT 0) == 0 ]]
[[ -z $(apo_state_get TRANSIENT_RETRY_CONTEXT '') ]]

# The exact alpha.38 post-stress hash-read failure follows the same complete
# recovery/retry path. It is not a 3150 MHz boundary, and several consecutive
# controller read losses do not end the unattended sweep.
ACTIONS=()
APO_STATE=()
apo_state_set CANDIDATE_LABEL cpu-refine-3150_gpu-960
apo_state_set CANDIDATE_CPU 3150
apo_state_set CANDIDATE_GPU 960
apo_state_set CANDIDATE_STAGE STRESS
apo_state_set TRYBOOT_EXPECTED 1
apo_state_set CURRENT_CPU 3150
apo_state_set CURRENT_GPU 960
HASH_STRESS_ATTEMPTS=0
apo_run_stress() {
    HASH_STRESS_ATTEMPTS=$((HASH_STRESS_ATTEMPTS + 1))
    if (( HASH_STRESS_ATTEMPTS <= 3 )); then
        APO_LAST_CLASS=RECOVERY_FAILURE
        APO_LAST_REASON='Permanent config hash is unavailable in cpu-refine-3150_gpu-960-candidate-post-stress; the target did not return readable hash evidence.'
        APO_LAST_RESULT_STRUCTURED=1
        return 1
    fi
    ACTIONS+=("stress:$1:$3")
    APO_LAST_RESULT_STRUCTURED=1
}
apo_recover_preserving_failure() {
    APO_RECOVERY_UNEXPECTED_CANDIDATE_REBOOT=0
    apo_state_set TRYBOOT_EXPECTED 0
    apo_state_set CURRENT_CPU ''
    apo_state_set CURRENT_GPU ''
    if apo_transient_hash_read_failure_is_retryable "$2" "$3"; then
        APO_LAST_CLASS=HARNESS_FAILURE
        APO_LAST_REASON="complete normal recovery re-proved the exact hash and health: $3"
    else
        APO_LAST_CLASS=$2
        APO_LAST_REASON=$3
    fi
}
apo_test_candidate 3150 960 cpu-refine-3150_gpu-960 combined
[[ $HASH_STRESS_ATTEMPTS == 4 ]]
[[ $(apo_state_get CANDIDATE_STAGE) == COMPLETE ]]
[[ $(apo_state_get TRANSIENT_RETRY_COUNT 0) == 0 ]]
[[ -z $(apo_state_get TRANSIENT_RETRY_CONTEXT '') ]]

# Restore the general success fixtures used by the remaining resume tests.
apo_run_stress() { ACTIONS+=("stress:$1:$3"); }
apo_recover_preserving_failure() { APO_LAST_CLASS=$2; APO_LAST_REASON=$3; return 0; }

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
apo_state_complete 2900 850 "$APO_DEFAULT_FINAL_DURATION_S"
[[ $SAVE_COUNT == 1 ]]
[[ $(apo_state_get FINAL_CPU) == 2900 && $(apo_state_get FINAL_GPU) == 850 ]]
[[ $(apo_state_get VALIDATED) == 1 && $(apo_state_get STATUS) == PASS ]]

# Optional edge mode checkpoints the completed production floor, then uses the
# immutable custom edge duration for the next 25 MHz CPU step.
APO_STATE=()
ACTIONS=()
STRESS_DURATIONS=()
seed_valid_guarded_auto_floor_plan
APO_CFG[FINAL_DURATION_S]=14400
APO_FINAL_DURATION_S=14400
APO_QUALIFICATION_DURATION_S=3600
APO_EDGE_DURATION_S=43200
APO_DURATION_POLICY=custom
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
apo_state_set VALIDATION_DURATION_S 14400
apo_state_set EDGE_CPU_STATUS NOT_REQUESTED
apo_state_set VALIDATED 0
apo_final_validation
[[ $(apo_state_get FLOOR_CPU) == 3000 && $(apo_state_get FLOOR_GPU) == 900 ]]
[[ $(apo_state_get FLOOR_VALIDATED) == 1 ]]
[[ $(apo_state_get EDGE_CPU_TARGET) == 3025 ]]
[[ $(apo_state_get EDGE_CPU_STATUS) == PASS ]]
[[ $(apo_state_get FINAL_CPU) == 3025 && $(apo_state_get FINAL_GPU) == 900 ]]
[[ $(apo_state_get FLOOR_DURATION_S) == 14400 ]]
[[ $(apo_state_get VALIDATION_DURATION_S) == 43200 ]]
[[ " ${STRESS_DURATIONS[*]} " == *' 43200 '* ]]
apo_state_set FINAL_CPU 3200
if apo_validate_auto_resume_state; then
    echo 'edge completion with final clocks outside its validated target was accepted' >&2
    exit 1
fi
[[ $(apo_state_get FAILURE_CLASS) == HARNESS_FAILURE ]]

APO_CFG[FINAL_DURATION_S]=$APO_DEFAULT_FINAL_DURATION_S
APO_FINAL_DURATION_S=$APO_DEFAULT_FINAL_DURATION_S
APO_QUALIFICATION_DURATION_S=$APO_DEFAULT_QUALIFICATION_DURATION_S
APO_EDGE_DURATION_S=$APO_DEFAULT_EDGE_DURATION_S
APO_DURATION_POLICY=default

# A legacy floor-first edge stability failure retains the already validated
# floor. A failed experiment must not erase that complete result.
APO_STATE=()
ACTIONS=()
seed_valid_guarded_auto_floor_plan
apo_state_set RECOMMENDED_CPU 3000
apo_state_set RECOMMENDED_GPU 900
apo_state_set FINAL_TARGET_CPU 3000
apo_state_set FINAL_TARGET_GPU 900
apo_state_set FINAL_STAGE VERIFY
apo_state_set VALIDATION_DURATION_S "$APO_DEFAULT_FINAL_DURATION_S"
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
[[ $(apo_state_get VALIDATION_DURATION_S) == "$APO_DEFAULT_FINAL_DURATION_S" ]]

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
# full saved-duration CPU qualification, and remains valid when GPU search begins.
APO_STATE=()
ACTIONS=()
seed_valid_guarded_auto_floor_plan
APO_QUALIFICATION_DURATION_S=3600
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
[[ " ${ACTIONS[*]} " == *' qualify:cpu:3000/800:3600 '* ]]
[[ " ${ACTIONS[*]} " == *' qualify:cpu:2950/800:3600 '* ]]
apo_state_set PHASE GPU_SWEEP
apo_state_set SUBPHASE READY
apo_validate_auto_resume_state
APO_QUALIFICATION_DURATION_S=$APO_DEFAULT_QUALIFICATION_DURATION_S

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
[[ " ${ACTIONS[*]} " == *' qualify:cpu:2950/875:7200 '* ]]
[[ " ${ACTIONS[*]} " == *' qualify:gpu:2950/875:7200 '* ]]
apo_validate_auto_resume_state

# Ordered history is safety evidence, not a free-form recommendation override.
apo_state_set FINAL_BACKOFF_HISTORY 'CPU:3000>2975'
if apo_validate_auto_resume_state; then
    echo 'malformed final backoff history was accepted' >&2
    exit 1
fi
[[ $(apo_state_get FAILURE_CLASS) == HARNESS_FAILURE ]]

# A safely recovered failure in a linked longer-final run is not terminal. The
# ambiguous pair is reduced by both production guards, both qualifications are
# reset, and the requested 24-hour duration becomes one fresh edge-first plan.
APO_STATE=()
ACTIONS=()
seed_valid_guarded_auto_floor_plan
APO_EDGE_CPU_24H=0
APO_EDGE_ORDER=floor-first
APO_EDGE_DURATION_S=43200
APO_FINAL_DURATION_S=86400
APO_CFG[FINAL_DURATION_S]=86400
APO_DURATION_POLICY=custom
apo_state_set RUN_SCHEMA "$APO_CURRENT_RUN_SCHEMA"
apo_state_set RUN_ID 20260831-131319-1111111111111111
apo_state_set ORIGIN_COMMAND overclock
apo_state_set CFG_AUTO_GENERATED_CANDIDATES 1
apo_state_set CFG_EDGE_CPU_24H 0
apo_state_set CFG_EDGE_ORDER floor-first
apo_state_set CFG_QUALIFICATION_DURATION_S "$APO_QUALIFICATION_DURATION_S"
apo_state_set CFG_FINAL_DURATION_S 86400
apo_state_set CFG_EDGE_DURATION_S 43200
apo_state_set CFG_DURATION_POLICY custom
apo_state_set POST_FLOOR_FINAL 1
apo_state_set POST_FLOOR_FINAL_STAGE VALIDATING
apo_state_set SOURCE_FINAL_RUN_ID 20260829-223837-2222222222222222
apo_state_set SOURCE_FINAL_PERMANENT_HASH aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
apo_state_set SOURCE_FINAL_VALIDATION_DURATION_S 28800
apo_state_set SOURCE_FINAL_APPLY_BACKUP /var/lib/autopioverclock/backups/source-before-apply.txt
apo_state_set APPLY_STATUS NOT_APPLIED
apo_state_set STATUS RUNNING
apo_state_set PHASE FINAL_VALIDATION
apo_state_set RECOMMENDED_CPU 3000
apo_state_set RECOMMENDED_GPU 900
apo_state_set FINAL_TARGET_CPU 3000
apo_state_set FINAL_TARGET_GPU 900
apo_state_set FINAL_STAGE ENDURANCE
apo_state_set STATUS FAILED
apo_state_set POST_FLOOR_FINAL_STAGE FAILED
apo_state_set FAILURE_CLASS STABILITY_FAILURE
apo_state_set FAILURE_REASON 'linked longer final rebooted autonomously'
apo_validate_auto_resume_state
apo_final_saved_failure_is_retryable "$APO_CURRENT_RUN_SCHEMA"
apo_state_set STATUS RUNNING
apo_state_set POST_FLOOR_FINAL_STAGE VALIDATING
apo_state_set FAILURE_CLASS ''
apo_state_set FAILURE_REASON ''
if apo_final_record_failure post-floor-final-fixture STABILITY_FAILURE 'linked longer final rebooted autonomously'; then
    echo 'linked longer-final stability failure was incorrectly treated as complete' >&2
    exit 1
else
    [[ $? == 2 ]]
fi
[[ $(apo_state_get POST_FLOOR_FINAL_STAGE) == BACKOFF_TUNING ]]
[[ $(apo_state_get APP_VERSION) == "$APO_VERSION" ]]
[[ $(apo_state_get STATUS) == RUNNING && $(apo_state_get PHASE) == CPU_QUALIFICATION ]]
[[ $(apo_state_get RECOMMENDED_CPU) == 2950 && $(apo_state_get RECOMMENDED_GPU) == 875 ]]
[[ $(apo_state_get FINAL_BACKOFF_HISTORY) == 'PAIR:3000/900>2950/875' ]]
[[ $(apo_state_get CPU_QUALIFICATION_STATUS) == NOT_STARTED ]]
[[ $(apo_state_get GPU_QUALIFICATION_STATUS) == NOT_STARTED ]]
[[ $APO_EDGE_CPU_24H == 1 && $APO_EDGE_ORDER == edge-first ]]
[[ $APO_EDGE_DURATION_S == 86400 ]]
[[ $(apo_state_get CFG_EDGE_CPU_24H) == 1 && $(apo_state_get CFG_EDGE_ORDER) == edge-first ]]
[[ $(apo_state_get CFG_EDGE_DURATION_S) == 86400 && $(apo_state_get CFG_FINAL_DURATION_S) == 86400 ]]
apo_validate_auto_resume_state

# A recovered schema-7 domain-specific final-stress failure is upgraded in
# place and immediately backed off without repeating the failed clock.
APO_CFG[FINAL_DURATION_S]=$APO_LEGACY_DEFAULT_FINAL_DURATION_S
APO_FINAL_DURATION_S=$APO_LEGACY_DEFAULT_FINAL_DURATION_S
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
APO_CFG[FINAL_DURATION_S]=$APO_DEFAULT_FINAL_DURATION_S
APO_FINAL_DURATION_S=$APO_DEFAULT_FINAL_DURATION_S

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
    apo_state_set VALIDATION_DURATION_S "$APO_DEFAULT_FINAL_DURATION_S"
    apo_validate_auto_resume_state
done

# A running edge checkpoint cannot jump to VERIFY without a completed 24-hour
# endurance checkpoint.
APO_STATE=()
seed_valid_guarded_auto_floor_plan
apo_state_set FLOOR_CPU 3000
apo_state_set FLOOR_GPU 900
apo_state_set FLOOR_DURATION_S "$APO_DEFAULT_FINAL_DURATION_S"
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
apo_state_set FLOOR_DURATION_S "$APO_DEFAULT_FINAL_DURATION_S"
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
apo_state_set FLOOR_DURATION_S "$APO_DEFAULT_FINAL_DURATION_S"
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
apo_final_record_failure edge-watchdog-recovery HARNESS_FAILURE 'The worker failed without a structured result.' stress 0
[[ $EDGE_RECOVERY_REBOOTS == 0 ]]
[[ $APO_RECOVERY_UNEXPECTED_CANDIDATE_REBOOT == 1 ]]
[[ $APO_RECOVERY_UNEXPECTED_REBOOT_FROM == edge-candidate-boot ]]
[[ $APO_RECOVERY_UNEXPECTED_REBOOT_TO == edge-watchdog-normal-boot ]]
[[ $(apo_state_get STATUS) == PASS && $(apo_state_get PHASE) == COMPLETE ]]
[[ $(apo_state_get EDGE_CPU_STATUS) == REJECTED ]]
[[ $(apo_state_get EDGE_CPU_FAILURE_CLASS) == STABILITY_FAILURE ]]
[[ $(apo_state_get FINAL_CPU) == 3000 && $(apo_state_get FINAL_GPU) == 900 ]]
[[ $(apo_state_get VALIDATION_DURATION_S) == "$APO_DEFAULT_FINAL_DURATION_S" ]]
APO_RECOVERY_UNEXPECTED_CANDIDATE_REBOOT=0
# Restore the lightweight boundaries expected by the remaining state-only
# assertions in this script.
apo_return_normal() {
    ACTIONS+=("normal:$1")
    apo_state_set TRYBOOT_EXPECTED 0
    apo_state_set CURRENT_CPU ''
    apo_state_set CURRENT_GPU ''
}
apo_recover_preserving_failure() { APO_LAST_CLASS=$2; APO_LAST_REASON=$3; return 0; }

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
apo_state_set VALIDATION_DURATION_S "$APO_DEFAULT_FINAL_DURATION_S"
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
apo_state_set FLOOR_DURATION_S "$APO_DEFAULT_FINAL_DURATION_S"
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

# New public runs spend the single long validation on the +25 MHz edge first.
# A passing edge is the final 24-hour result; the guarded floor is not also run.
APO_STATE=()
ACTIONS=()
seed_valid_guarded_auto_floor_plan
APO_EDGE_ORDER=edge-first
APO_EDGE_CPU_24H=1
APO_CFG[FINAL_DURATION_S]=$APO_DEFAULT_FINAL_DURATION_S
APO_FINAL_DURATION_S=$APO_DEFAULT_FINAL_DURATION_S
APO_EDGE_DURATION_S=$APO_DEFAULT_EDGE_DURATION_S
apo_state_set RECOMMENDED_CPU 3000
apo_state_set RECOMMENDED_GPU 900
apo_state_set FINAL_TARGET_CPU 3000
apo_state_set FINAL_TARGET_GPU 900
apo_state_set FINAL_STAGE ''
apo_state_set STATUS RUNNING
apo_state_set PHASE FINAL_VALIDATION
apo_state_set VALIDATED 0
apo_boot_candidate() {
    ACTIONS+=("boot:$1/$2:$3")
    apo_state_set TRYBOOT_EXPECTED 1
    apo_state_set CURRENT_CPU "$1"
    apo_state_set CURRENT_GPU "$2"
}
apo_final_validation
[[ $(apo_state_get EDGE_CPU_STATUS) == PASS ]]
[[ $(apo_state_get FLOOR_VALIDATED) == 0 ]]
[[ $(apo_state_get FINAL_CPU) == 3025 && $(apo_state_get FINAL_GPU) == 900 ]]
[[ $(apo_state_get VALIDATION_DURATION_S) == "$APO_DEFAULT_EDGE_DURATION_S" ]]
[[ $(printf '%s\n' "${ACTIONS[@]}" | grep -c '^stress:combined:86400:final-endurance$') == 1 ]]

# A safely recovered edge rejection does not mark the untested floor PASS. It
# starts one fresh 24-hour guarded-floor validation and completes only after it.
APO_STATE=()
ACTIONS=()
seed_valid_guarded_auto_floor_plan
APO_EDGE_ORDER=edge-first
APO_EDGE_CPU_24H=1
apo_state_set RECOMMENDED_CPU 3000
apo_state_set RECOMMENDED_GPU 900
apo_state_set FINAL_TARGET_CPU 3000
apo_state_set FINAL_TARGET_GPU 900
apo_state_set FINAL_STAGE ''
apo_state_set STATUS RUNNING
apo_state_set PHASE FINAL_VALIDATION
apo_state_set VALIDATED 0
apo_boot_candidate() {
    ACTIONS+=("boot:$1/$2:$3")
    if (( $1 == 3025 )); then
        APO_LAST_CLASS=STABILITY_FAILURE
        APO_LAST_REASON='edge-first fixture failed'
        return 1
    fi
    apo_state_set TRYBOOT_EXPECTED 1
    apo_state_set CURRENT_CPU "$1"
    apo_state_set CURRENT_GPU "$2"
}
if apo_final_validation; then
    echo 'edge-first rejection incorrectly completed before floor validation' >&2
    exit 1
else
    [[ $? == 2 ]]
fi
[[ $(apo_state_get EDGE_CPU_STATUS) == REJECTED ]]
[[ $(apo_state_get FLOOR_VALIDATED) == 0 ]]
[[ $(apo_state_get STATUS) == RUNNING && $(apo_state_get FINAL_STAGE) == '' ]]
apo_boot_candidate() {
    ACTIONS+=("boot:$1/$2:$3")
    apo_state_set TRYBOOT_EXPECTED 1
    apo_state_set CURRENT_CPU "$1"
    apo_state_set CURRENT_GPU "$2"
}
apo_final_validation
[[ $(apo_state_get EDGE_CPU_STATUS) == REJECTED ]]
[[ $(apo_state_get FLOOR_VALIDATED) == 1 ]]
[[ $(apo_state_get FINAL_CPU) == 3000 && $(apo_state_get FINAL_GPU) == 900 ]]
[[ $(apo_state_get VALIDATION_DURATION_S) == "$APO_DEFAULT_FINAL_DURATION_S" ]]
[[ $(printf '%s\n' "${ACTIONS[@]}" | grep -c '^stress:combined:86400:final-endurance$') == 1 ]]

# If the freshly tested guarded floor also proves unstable after an edge
# rejection, automatic tuning still backs off safely. The old edge disposition
# remains in the immutable event log while the reduced pair gets a new final
# sequence and fresh clock identities.
APO_STATE=()
seed_valid_guarded_auto_floor_plan
APO_EDGE_ORDER=edge-first
APO_EDGE_CPU_24H=1
apo_state_set RECOMMENDED_CPU 3000
apo_state_set RECOMMENDED_GPU 900
apo_state_set FINAL_TARGET_CPU 3000
apo_state_set FINAL_TARGET_GPU 900
apo_state_set FINAL_STAGE ENDURANCE
apo_state_set FLOOR_CPU 3000
apo_state_set FLOOR_GPU 900
apo_state_set FLOOR_DURATION_S ''
apo_state_set FLOOR_VALIDATION_SCHEMA ''
apo_state_set FLOOR_VALIDATED 0
apo_state_set EDGE_CPU_TARGET 3025
apo_state_set EDGE_CPU_STATUS REJECTED
apo_state_set EDGE_CPU_FAILURE_CLASS STABILITY_FAILURE
apo_state_set EDGE_CPU_FAILURE_REASON 'edge fixture failed first'
apo_state_set TRYBOOT_EXPECTED 0
apo_state_set TRYBOOT_FILE_MAY_EXIST 0
apo_state_set TRYBOOT_OWNED_HASH ''
apo_state_set TRYBOOT_RESERVATION_HASH ''
apo_state_set TRYBOOT_OWNERSHIP_TOKEN ''
apo_state_set TRYBOOT_QUARANTINE_PATH ''
apo_final_schedule_stress_backoff ENDURANCE STABILITY_FAILURE 'floor fixture also failed'
[[ $(apo_state_get FINAL_BACKOFF_COUNT) == 1 ]]
[[ $(apo_state_get FINAL_BACKOFF_CPU) == 2950 ]]
[[ $(apo_state_get FINAL_BACKOFF_GPU) == 875 ]]
[[ $(apo_state_get PHASE) == CPU_QUALIFICATION ]]
[[ $(apo_state_get EDGE_CPU_STATUS) == NOT_REQUESTED ]]
[[ -z $(apo_state_get FLOOR_CPU '') && -z $(apo_state_get EDGE_CPU_TARGET '') ]]

# Checkpoint restarts take clocks from retained state and durations from the
# command request; they never encode host-specific clocks in controller code.
APO_STATE=()
seed_valid_guarded_auto_floor_plan
APO_EDGE_ORDER=floor-first
apo_state_set RUN_SCHEMA "$APO_CURRENT_RUN_SCHEMA"
apo_state_set ORIGIN_COMMAND overclock
apo_state_set CFG_AUTO_GENERATED_CANDIDATES 1
apo_state_set APPLY_STATUS NOT_APPLIED
apo_state_set POST_FLOOR_EDGE 0
apo_state_set POST_FLOOR_FINAL 0
apo_state_set PHASE CPU_QUALIFICATION
apo_state_set STATUS INTERRUPTED
apo_state_set CPU_QUALIFICATION_STATUS RUNNING
apo_state_set CPU_QUALIFICATION_TARGET 3000
apo_state_set CPU_QUALIFIED_CLOCK ''
APO_RESTART_QUALIFICATION_DURATION_S=10800
APO_RESTART_FINAL_DURATION_S=86400
APO_RESTART_EDGE_DURATION_S=43200
apo_restart_active_automatic_state cpu-qualification
[[ $(apo_state_get PHASE) == CPU_QUALIFICATION ]]
[[ $(apo_state_get CPU_QUALIFICATION_STATUS) == NOT_STARTED ]]
[[ $(apo_state_get CPU_QUALIFICATION_TARGET) == 3000 ]]
[[ $(apo_state_get CFG_QUALIFICATION_DURATION_S) == 10800 ]]
[[ $(apo_state_get CFG_FINAL_DURATION_S) == 86400 ]]
[[ $(apo_state_get CFG_EDGE_DURATION_S) == 43200 ]]
[[ $(apo_state_get CFG_EDGE_ORDER) == edge-first ]]

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

# The refined-max policy reaches the highest clock that actually passed the
# canonical 25 MHz refinement ladder. It does not subtract a hidden guard.
APO_STATE=()
APO_SELECTION_POLICY=refined-max-25
APO_SWEEP_DOMAIN=all
APO_AUTO_GENERATED_CANDIDATES=1
APO_EDGE_CPU_24H=0
APO_NORMAL_CPU=2400
APO_NORMAL_GPU=960
APO_NORMAL_VOLTAGE=0
APO_TEST_VOLTAGE=0
APO_AUTO_BASELINE_CPU=2400
APO_AUTO_BASELINE_GPU=960
APO_AUTO_BASELINE_VOLTAGE=0
APO_AUTO_BASELINE_PROVENANCE='verified-default'
APO_AUTO_BASELINE_EVIDENCE=none
APO_CPU_START_AT=''
APO_GPU_START_AT=''
APO_CPU_CANDIDATES=(2500 2600 2700 2800 2900 3000 3100 3200)
APO_GPU_CANDIDATES=(1000 1050 1100 1150 1200)
APO_CFG[CPU_CANDIDATES]=2500,2600,2700,2800,2900,3000,3100,3200
APO_CFG[GPU_CANDIDATES]=1000,1050,1100,1150,1200
APO_CFG[BACKOFF_STEPS]=0
APO_CFG[VOLTAGE_DELTA_UV]=existing
apo_state_set CFG_SELECTION_POLICY refined-max-25
apo_state_set CFG_SWEEP_DOMAIN all
apo_state_set CPU_INDEX 7
apo_state_set PASSED_CPUS 2500,2600,2700,2800,2900,3000,3100,3125,3150,3175
apo_state_set CPU_FAILURE_BOUNDARY 3200
apo_state_set CPU_REFINE_CANDIDATES 3125,3150,3175
apo_state_set CPU_REFINE_INDEX 3
apo_state_set CPU_REFINE_COMPLETE 1
apo_state_set CPU_GUARD_TARGET 3175
apo_state_set CPU_GUARD_VERIFIED 1
apo_state_set SAFE_CPU 3175
apo_state_set GPU_INDEX 4
apo_state_set PASSED_GPUS 1000,1050,1100,1150,1175
apo_state_set GPU_FAILURE_BOUNDARY 1200
apo_state_set GPU_REFINE_CANDIDATES 1175
apo_state_set GPU_REFINE_INDEX 1
apo_state_set GPU_REFINE_COMPLETE 1
apo_state_set GPU_GUARD_TARGET 1175
apo_state_set GPU_GUARD_VERIFIED 1
apo_state_set SAFE_GPU 1175
apo_state_set CPU_QUALIFICATION_STATUS PASS
apo_state_set CPU_QUALIFICATION_TARGET 3175
apo_state_set CPU_QUALIFIED_CLOCK 3175
apo_state_set GPU_QUALIFICATION_STATUS PASS
apo_state_set GPU_QUALIFICATION_CPU 3175
apo_state_set GPU_QUALIFICATION_TARGET 1175
apo_state_set GPU_QUALIFIED_CPU 3175
apo_state_set GPU_QUALIFIED_CLOCK 1175
apo_state_set RECOMMENDED_CPU 3175
apo_state_set RECOMMENDED_GPU 1175
apo_state_set FINAL_TARGET_CPU 3175
apo_state_set FINAL_TARGET_GPU 1175
apo_state_set FINAL_BACKOFF_COUNT 0
apo_state_set EDGE_CPU_STATUS NOT_REQUESTED
apo_state_set FLOOR_VALIDATED 0
apo_state_set PHASE FINAL_VALIDATION
apo_state_set FINAL_STAGE ''
apo_state_set STATUS RUNNING
apo_state_set APPLY_STATUS NOT_APPLIED
apo_state_set RECOVERY_WAIT_STATUS IDLE
apo_state_set RECOVERY_WAIT_CONTEXT ''
apo_state_set RECOVERY_WAIT_STARTED_AT ''
apo_state_set RECOVERY_WAIT_TIMEOUTS 0
apo_validate_auto_resume_state

# A checkpoint restart for the refined policy changes only the requested
# qualification/final durations. It must not resurrect the removed edge pass.
apo_state_set RUN_SCHEMA "$APO_CURRENT_RUN_SCHEMA"
apo_state_set ORIGIN_COMMAND overclock
apo_state_set CFG_AUTO_GENERATED_CANDIDATES 1
apo_state_set APPLY_STATUS NOT_APPLIED
apo_state_set POST_FLOOR_EDGE 0
apo_state_set POST_FLOOR_FINAL 0
apo_state_set PHASE CPU_QUALIFICATION
apo_state_set STATUS INTERRUPTED
APO_RESTART_QUALIFICATION_DURATION_S=10800
APO_RESTART_FINAL_DURATION_S=86400
APO_RESTART_EDGE_DURATION_S=43200
apo_restart_active_automatic_state current
[[ $APO_EDGE_CPU_24H == 0 && $APO_EDGE_ORDER == floor-first ]]
[[ $APO_EDGE_DURATION_S == 86400 ]]
[[ $(apo_state_get CFG_EDGE_CPU_24H) == 0 && $(apo_state_get CFG_EDGE_ORDER) == floor-first ]]
[[ $(apo_state_get CFG_EDGE_DURATION_S) == 86400 && $(apo_state_get CFG_FINAL_DURATION_S) == 86400 ]]

# Exercise the production sweep/refinement implementation directly. CPU uses
# 100 MHz coarse steps and GPU uses 50 MHz; both refine the last gap by 25 MHz
# and select the exact highest pass.
APO_VALIDATE_AUTO_RESUME_STATE_SAVED=$(declare -f apo_validate_auto_resume_state)
apo_validate_auto_resume_state() { :; }
apo_test_candidate() {
    local cpu=$1 gpu=$2
    if (( cpu == 2600 || cpu == 2575 || gpu == 1050 )); then
        APO_LAST_CLASS=STABILITY_FAILURE
        APO_LAST_REASON='fixture boundary'
        return 1
    fi
}
APO_STATE=()
APO_SELECTION_POLICY=refined-max-25
APO_SWEEP_DOMAIN=all
APO_AUTO_GENERATED_CANDIDATES=1
APO_NORMAL_CPU=2400
APO_NORMAL_GPU=960
APO_AUTO_BASELINE_CPU=2400
APO_AUTO_BASELINE_GPU=960
APO_CPU_CANDIDATES=(2500 2600)
APO_GPU_CANDIDATES=(1000 1050)
apo_sweep_cpu
[[ $(apo_state_get CPU_FAILURE_BOUNDARY) == 2575 ]]
[[ $(apo_state_get PASSED_CPUS) == 2500,2525,2550 ]]
[[ $(apo_state_get SAFE_CPU) == 2550 && $(apo_state_get CPU_GUARD_TARGET) == 2550 ]]
apo_state_set CPU_QUALIFICATION_STATUS PASS
apo_state_set CPU_QUALIFIED_CLOCK 2550
apo_sweep_gpu
[[ $(apo_state_get GPU_FAILURE_BOUNDARY) == 1050 ]]
[[ $(apo_state_get PASSED_GPUS) == 1000,1025 ]]
[[ $(apo_state_get SAFE_GPU) == 1025 && $(apo_state_get GPU_GUARD_TARGET) == 1025 ]]

# Reaching the configured ceiling without a failure selects that exact tested
# ceiling; it does not manufacture a boundary or subtract a safety step.
apo_test_candidate() { :; }
APO_STATE=()
APO_SELECTION_POLICY=refined-max-25
APO_SWEEP_DOMAIN=all
APO_AUTO_GENERATED_CANDIDATES=1
APO_NORMAL_CPU=2400
APO_NORMAL_GPU=960
APO_AUTO_BASELINE_CPU=2400
APO_AUTO_BASELINE_GPU=960
APO_CPU_CANDIDATES=(2500 2600)
apo_sweep_cpu
[[ $(apo_state_get PASSED_CPUS) == 2500,2600 ]]
[[ -z $(apo_state_get CPU_FAILURE_BOUNDARY '') ]]
[[ $(apo_state_get SAFE_CPU) == 2600 && $(apo_state_get CPU_GUARD_TARGET) == 2600 ]]
eval "$APO_VALIDATE_AUTO_RESUME_STATE_SAVED"
unset APO_VALIDATE_AUTO_RESUME_STATE_SAVED

seed_valid_refined_auto_floor_plan() {
    seed_valid_guarded_auto_floor_plan
    APO_SELECTION_POLICY=refined-max-25
    APO_SWEEP_DOMAIN=all
    APO_EDGE_CPU_24H=0
    APO_EDGE_ORDER=floor-first
    APO_CPU_START_AT=''
    APO_GPU_START_AT=''
    APO_CFG[FINAL_DURATION_S]=86400
    apo_state_set CFG_SELECTION_POLICY refined-max-25
    apo_state_set CFG_SWEEP_DOMAIN all
    apo_state_set CPU_GUARD_TARGET 3025
    apo_state_set SAFE_CPU 3025
    apo_state_set CPU_QUALIFICATION_STATUS PASS
    apo_state_set CPU_QUALIFICATION_TARGET 3025
    apo_state_set CPU_QUALIFIED_CLOCK 3025
    apo_state_set GPU_QUALIFICATION_STATUS PASS
    apo_state_set GPU_QUALIFICATION_CPU 3025
    apo_state_set GPU_QUALIFICATION_TARGET 900
    apo_state_set GPU_QUALIFIED_CPU 3025
    apo_state_set GPU_QUALIFIED_CLOCK 900
    apo_state_set RECOMMENDED_CPU 3025
    apo_state_set RECOMMENDED_GPU 900
    apo_state_set FINAL_TARGET_CPU 3025
    apo_state_set FINAL_TARGET_GPU 900
    apo_state_set FINAL_STAGE ENDURANCE
    apo_state_set PHASE FINAL_VALIDATION
    apo_state_set STATUS RUNNING
    apo_state_set EDGE_CPU_STATUS NOT_REQUESTED
    apo_state_set FLOOR_VALIDATED 0
}

mark_refined_current_pair_ready_for_final() {
    local cpu gpu phase trial
    cpu=$(apo_state_get RECOMMENDED_CPU)
    gpu=$(apo_state_get RECOMMENDED_GPU)
    phase=$(apo_state_get PHASE)
    trial=$(apo_state_get FINAL_BACKOFF_TRIAL '')
    case $phase in
        CPU_QUALIFICATION)
            apo_state_set CPU_QUALIFICATION_STATUS PASS
            apo_state_set CPU_QUALIFICATION_TARGET "$cpu"
            apo_state_set CPU_QUALIFIED_CLOCK "$cpu"
            if [[ $trial == PAIR ]]; then
                apo_state_set GPU_QUALIFICATION_STATUS PASS
                apo_state_set GPU_QUALIFICATION_CPU "$cpu"
                apo_state_set GPU_QUALIFICATION_TARGET "$gpu"
                apo_state_set GPU_QUALIFIED_CPU "$cpu"
                apo_state_set GPU_QUALIFIED_CLOCK "$gpu"
            fi
            ;;
        GPU_QUALIFICATION)
            apo_state_set GPU_QUALIFICATION_STATUS PASS
            apo_state_set GPU_QUALIFICATION_CPU "$cpu"
            apo_state_set GPU_QUALIFICATION_TARGET "$gpu"
            apo_state_set GPU_QUALIFIED_CPU "$cpu"
            apo_state_set GPU_QUALIFIED_CLOCK "$gpu"
            ;;
        *)
            echo "cannot qualify refined trial from phase $phase" >&2
            exit 1
            ;;
    esac
    apo_state_set FINAL_TARGET_CPU "$cpu"
    apo_state_set FINAL_TARGET_GPU "$gpu"
    apo_state_set FINAL_STAGE ENDURANCE
    apo_state_set PHASE FINAL_VALIDATION
    apo_validate_auto_resume_state
}

advance_refined_ambiguous_sequence_to_pair() {
    apo_final_schedule_stress_backoff ENDURANCE STABILITY_FAILURE 'ambiguous anchor failure'
    mark_refined_current_pair_ready_for_final
    apo_final_schedule_stress_backoff ENDURANCE STABILITY_FAILURE 'CPU isolation final failed'
    mark_refined_current_pair_ready_for_final
    apo_final_schedule_stress_backoff ENDURANCE STABILITY_FAILURE 'GPU isolation final failed'
    mark_refined_current_pair_ready_for_final
}

# CPU isolation must lower only CPU while actually exercising the held GPU at
# the saved pair. Using the normal/stock GPU here would not test the ambiguous
# final failure that selected this isolation trial.
APO_STATE=()
seed_valid_refined_auto_floor_plan
apo_final_schedule_stress_backoff ENDURANCE STABILITY_FAILURE 'ambiguous held-GPU fixture'
APO_TEST_CANDIDATE_SAVED=$(declare -f apo_test_candidate)
QUALIFIED_PAIR=''
apo_test_candidate() { QUALIFIED_PAIR="$1/$2"; }
apo_qualify_cpu
[[ $QUALIFIED_PAIR == 3000/900 ]]
[[ $(apo_state_get RECOMMENDED_CPU) == 3000 && $(apo_state_get RECOMMENDED_GPU) == 900 ]]
[[ $(apo_state_get CPU_QUALIFICATION_STATUS) == PASS ]]
apo_validate_auto_resume_state
eval "$APO_TEST_CANDIDATE_SAVED"
unset APO_TEST_CANDIDATE_SAVED

# Exact evidence against the held domain during an isolation qualification
# switches immediately to that domain. The unrelated trial reduction is
# restored to the saved anchor and the outer tuning loop is told to dispatch
# the newly scheduled qualification instead of continuing the wrong loop.
APO_STATE=()
seed_valid_refined_auto_floor_plan
apo_final_schedule_stress_backoff ENDURANCE STABILITY_FAILURE 'ambiguous CPU-trial fixture'
APO_TEST_CANDIDATE_SAVED=$(declare -f apo_test_candidate)
apo_test_candidate() {
    APO_LAST_CLASS=BOOT_FAILURE
    APO_LAST_REASON='GPU config mismatch in cpu-isolation: expected 900, found 875.'
    APO_CANDIDATE_FAILURE_DOMAIN=GPU
    return 1
}
qualification_rc=0
apo_qualify_cpu || qualification_rc=$?
[[ $qualification_rc == 2 ]]
[[ $(apo_state_get RECOMMENDED_CPU) == 3025 && $(apo_state_get RECOMMENDED_GPU) == 875 ]]
[[ $(apo_state_get PHASE) == GPU_QUALIFICATION ]]
[[ $(apo_state_get FINAL_BACKOFF_HISTORY) == TRIAL_CPU:3025/900\>3000/900,EXACT_GPU:3000/900\>3025/875 ]]
apo_validate_auto_resume_state
eval "$APO_TEST_CANDIDATE_SAVED"

APO_STATE=()
seed_valid_refined_auto_floor_plan
apo_final_schedule_stress_backoff ENDURANCE STABILITY_FAILURE 'ambiguous CPU-trial fixture'
mark_refined_current_pair_ready_for_final
apo_final_schedule_stress_backoff ENDURANCE STABILITY_FAILURE 'ambiguous GPU-trial fixture'
apo_test_candidate() {
    APO_LAST_CLASS=BOOT_FAILURE
    APO_LAST_REASON='CPU config mismatch in gpu-isolation: expected 3025, found 3000.'
    APO_CANDIDATE_FAILURE_DOMAIN=CPU
    return 1
}
qualification_rc=0
apo_qualify_gpu || qualification_rc=$?
[[ $qualification_rc == 2 ]]
[[ $(apo_state_get RECOMMENDED_CPU) == 3000 && $(apo_state_get RECOMMENDED_GPU) == 900 ]]
[[ $(apo_state_get PHASE) == CPU_QUALIFICATION ]]
[[ $(apo_state_get FINAL_BACKOFF_HISTORY) == TRIAL_CPU:3025/900\>3000/900,TRIAL_GPU:3000/900\>3025/875,EXACT_CPU:3025/875\>3000/900 ]]
apo_validate_auto_resume_state
eval "$APO_TEST_CANDIDATE_SAVED"
unset APO_TEST_CANDIDATE_SAVED

# Initial CPU-qualification backoff is converted into the same pair-bound
# 25 MHz history before GPU qualification/final validation can resume.
APO_STATE=()
seed_valid_refined_auto_floor_plan
apo_state_set CPU_QUALIFICATION_TARGET 3000
apo_state_set CPU_QUALIFIED_CLOCK 3000
apo_state_set CPU_QUALIFICATION_HISTORY 'CPU:3025>3000'
apo_state_set CPU_QUALIFICATION_LAST_CLASS STABILITY_FAILURE
apo_state_set CPU_QUALIFICATION_LAST_REASON 'CPU qualification fixture failure'
apo_state_set GPU_QUALIFICATION_CPU 3000
apo_state_set GPU_QUALIFIED_CPU 3000
apo_state_set RECOMMENDED_CPU 3000
apo_state_set FINAL_TARGET_CPU 3000
apo_materialize_cpu_qualification_backoff
[[ $(apo_state_get FINAL_BACKOFF_HISTORY) == QUAL_CPU:3025/900\>3000/900 ]]
[[ $(apo_state_get FINAL_BACKOFF_CPU) == 3000 && $(apo_state_get FINAL_BACKOFF_GPU) == 900 ]]
apo_validate_auto_resume_state

# Exact structured worker evidence backs only its identified domain down by
# 25 MHz, clears any ambiguous-isolation state, and remains fully resumable.
[[ $(apo_structured_stress_failure_domain 'CPU stress exited early with rc=1.') == CPU ]]
[[ $(apo_structured_stress_failure_domain 'CPU stress returned rc=2.') == CPU ]]
[[ $(apo_structured_stress_failure_domain 'GPU stress exited early with rc=3.') == GPU ]]
[[ $(apo_structured_stress_failure_domain 'GPU stress returned rc=4 after V3D initialization.') == GPU ]]
[[ $(apo_structured_stress_failure_domain 'Stress process returned nonzero (CPU=5 GPU=0).') == CPU ]]
[[ $(apo_structured_stress_failure_domain 'Stress process returned nonzero (CPU=0 GPU=6).') == GPU ]]
[[ $(apo_structured_stress_failure_domain 'Requested CPU clock 3100MHz was never observed within 25MHz under load.') == CPU ]]
[[ $(apo_structured_stress_failure_domain 'Requested GPU clock 1175MHz was never observed within 25MHz under load.') == GPU ]]
[[ $(apo_structured_boot_failure_domain 'CPU config mismatch in final-pre-stress-boot: expected 3100, found 3075.') == CPU ]]
[[ $(apo_structured_boot_failure_domain 'GPU config mismatch in final-pre-stress-boot: expected 1175, found 1150.') == GPU ]]
if apo_structured_boot_failure_domain 'CPU and GPU config mismatch in final-pre-stress-boot: expected 3100/1175, found 2400/960.' >/dev/null; then
    echo 'multi-domain boot mismatch was falsely attributed to one clock domain' >&2
    exit 1
fi
if apo_structured_boot_failure_domain 'Active clocks or voltage changed while application readiness was settling in final-pre-stress-boot.' >/dev/null; then
    echo 'ambiguous post-readiness clock change was falsely attributed to one clock domain' >&2
    exit 1
fi
if apo_structured_stress_failure_domain 'The worker failed without a structured result.' >/dev/null; then
    echo 'unstructured transport loss was falsely attributed to one clock domain' >&2
    exit 1
fi
if apo_structured_stress_failure_domain 'Stress process returned nonzero (CPU=7 GPU=8).' >/dev/null; then
    echo 'multi-domain worker failure was falsely attributed to one clock domain' >&2
    exit 1
fi
if apo_structured_stress_failure_domain 'CPU and GPU stress exited early with rc=7/8.' >/dev/null; then
    echo 'simultaneous worker deaths were falsely attributed to one clock domain' >&2
    exit 1
fi
if apo_structured_stress_failure_domain 'Stress processes returned nonzero (CPU=7 GPU=8).' >/dev/null; then
    echo 'simultaneous Batocera completion failures were falsely attributed to one clock domain' >&2
    exit 1
fi

# A retained pre-alpha.47 structured audio-readiness miss remains a retryable
# harness problem. After normal recovery the controller repeats the complete
# final boot gate and must not enter clock backoff or ambiguous-domain isolation.
APO_STATE=()
seed_valid_refined_auto_floor_plan
apo_state_set FINAL_STAGE PRE_STRESS_BOOT
APO_RECOVER_OBSERVED_PHASE_FAILURE_SAVED=$(declare -f apo_recover_observed_phase_failure)
APO_FINAL_SCHEDULE_STRESS_BACKOFF_SAVED=$(declare -f apo_final_schedule_stress_backoff)
AUDIO_BACKOFF_CALLED=0
apo_recover_observed_phase_failure() {
    APO_LAST_CLASS=$2
    APO_LAST_REASON=$3
    return 0
}
apo_final_schedule_stress_backoff() {
    AUDIO_BACKOFF_CALLED=1
    return 0
}
audio_retry_rc=0
apo_final_record_failure final-audio-recovery HARNESS_FAILURE \
    'The captured audio output changed in final-pre-stress-boot: expected sink-a, found sink-b.' \
    boot 1 1 || audio_retry_rc=$?
[[ $audio_retry_rc == 3 ]]
[[ $AUDIO_BACKOFF_CALLED == 0 ]]
[[ $(apo_state_get TRANSIENT_RETRY_CONTEXT) == final-PRE_STRESS_BOOT-boot ]]
[[ $(apo_state_get TRANSIENT_RETRY_COUNT) == 1 ]]
[[ $(apo_state_get FINAL_BACKOFF_COUNT 0) == 0 ]]
eval "$APO_RECOVER_OBSERVED_PHASE_FAILURE_SAVED"
eval "$APO_FINAL_SCHEDULE_STRESS_BACKOFF_SAVED"
unset APO_RECOVER_OBSERVED_PHASE_FAILURE_SAVED APO_FINAL_SCHEDULE_STRESS_BACKOFF_SAVED

APO_STATE=()
seed_valid_refined_auto_floor_plan
apo_validate_auto_resume_state
apo_final_schedule_stress_backoff ENDURANCE STABILITY_FAILURE 'CPU stress returned rc=1.' CPU
[[ $(apo_state_get FINAL_BACKOFF_HISTORY) == EXACT_CPU:3025/900\>3000/900 ]]
[[ $(apo_state_get RECOMMENDED_CPU) == 3000 && $(apo_state_get RECOMMENDED_GPU) == 900 ]]
[[ -z $(apo_state_get FINAL_BACKOFF_TRIAL '') && -z $(apo_state_get FINAL_BACKOFF_ANCHOR_CPU '') ]]
apo_validate_auto_resume_state
apo_state_set CPU_QUALIFICATION_STATUS PASS
apo_state_set CPU_QUALIFICATION_TARGET 3000
apo_state_set CPU_QUALIFIED_CLOCK 3000
apo_state_set PHASE FINAL_VALIDATION
apo_state_set FINAL_STAGE ENDURANCE
apo_validate_auto_resume_state

apo_final_schedule_stress_backoff ENDURANCE STABILITY_FAILURE 'GPU stress returned rc=2 after V3D initialization.' GPU
[[ $(apo_state_get FINAL_BACKOFF_HISTORY) == EXACT_CPU:3025/900\>3000/900,EXACT_GPU:3000/900\>3000/875 ]]
[[ $(apo_state_get RECOMMENDED_CPU) == 3000 && $(apo_state_get RECOMMENDED_GPU) == 875 ]]
[[ $(apo_state_get CPU_QUALIFICATION_STATUS) == PASS && $(apo_state_get PHASE) == GPU_QUALIFICATION ]]
apo_validate_auto_resume_state

# Exact evidence discovered during an isolation trial restores the unrelated
# trial-reduced domain to its anchor. This avoids leaving a proven 25 MHz on
# the table while requalifying only the clock domain that actually failed.
APO_STATE=()
seed_valid_refined_auto_floor_plan
apo_final_schedule_stress_backoff ENDURANCE STABILITY_FAILURE 'ambiguous anchor failure'
mark_refined_current_pair_ready_for_final
apo_final_schedule_stress_backoff ENDURANCE STABILITY_FAILURE 'Requested GPU clock 900MHz was never observed within 25MHz under load.' GPU
[[ $(apo_state_get RECOMMENDED_CPU) == 3025 && $(apo_state_get RECOMMENDED_GPU) == 875 ]]
[[ $(apo_state_get FINAL_BACKOFF_HISTORY) == TRIAL_CPU:3025/900\>3000/900,EXACT_GPU:3000/900\>3025/875 ]]
[[ $(apo_state_get CPU_QUALIFICATION_STATUS) == PASS && $(apo_state_get CPU_QUALIFIED_CLOCK) == 3025 ]]
[[ $(apo_state_get PHASE) == GPU_QUALIFICATION ]]
[[ -z $(apo_state_get FINAL_BACKOFF_TRIAL '') && -z $(apo_state_get FINAL_BACKOFF_ANCHOR_CPU '') ]]
apo_validate_auto_resume_state

APO_STATE=()
seed_valid_refined_auto_floor_plan
apo_final_schedule_stress_backoff ENDURANCE STABILITY_FAILURE 'ambiguous anchor failure'
mark_refined_current_pair_ready_for_final
apo_final_schedule_stress_backoff ENDURANCE STABILITY_FAILURE 'CPU isolation final failed'
mark_refined_current_pair_ready_for_final
apo_final_schedule_stress_backoff ENDURANCE STABILITY_FAILURE 'Requested CPU clock 3025MHz was never observed within 25MHz under load.' CPU
[[ $(apo_state_get RECOMMENDED_CPU) == 3000 && $(apo_state_get RECOMMENDED_GPU) == 900 ]]
[[ $(apo_state_get FINAL_BACKOFF_HISTORY) == TRIAL_CPU:3025/900\>3000/900,TRIAL_GPU:3000/900\>3025/875,EXACT_CPU:3025/875\>3000/900 ]]
[[ $(apo_state_get GPU_QUALIFICATION_STATUS) == PASS && $(apo_state_get GPU_QUALIFIED_CLOCK) == 900 ]]
[[ $(apo_state_get PHASE) == CPU_QUALIFICATION ]]
[[ -z $(apo_state_get FINAL_BACKOFF_TRIAL '') && -z $(apo_state_get FINAL_BACKOFF_ANCHOR_GPU '') ]]
apo_validate_auto_resume_state

# A paired trial follows the same rule. The exact failing clock takes another
# 25 MHz step from the failed pair, while the unrelated clock returns to the
# original anchor before the affected-domain qualification restarts.
APO_STATE=()
seed_valid_refined_auto_floor_plan
advance_refined_ambiguous_sequence_to_pair
apo_final_schedule_stress_backoff ENDURANCE STABILITY_FAILURE 'CPU stress returned rc=9.' CPU
[[ $(apo_state_get RECOMMENDED_CPU) == 2975 && $(apo_state_get RECOMMENDED_GPU) == 900 ]]
[[ $(apo_state_get FINAL_BACKOFF_HISTORY) == TRIAL_CPU:3025/900\>3000/900,TRIAL_GPU:3000/900\>3025/875,TRIAL_PAIR:3025/875\>3000/875,EXACT_CPU:3000/875\>2975/900 ]]
[[ $(apo_state_get GPU_QUALIFICATION_STATUS) == PASS && $(apo_state_get GPU_QUALIFIED_CLOCK) == 900 ]]
[[ $(apo_state_get PHASE) == CPU_QUALIFICATION ]]
apo_validate_auto_resume_state

APO_STATE=()
seed_valid_refined_auto_floor_plan
advance_refined_ambiguous_sequence_to_pair
apo_final_schedule_stress_backoff ENDURANCE STABILITY_FAILURE 'GPU stress returned rc=9 after V3D initialization.' GPU
[[ $(apo_state_get RECOMMENDED_CPU) == 3025 && $(apo_state_get RECOMMENDED_GPU) == 850 ]]
[[ $(apo_state_get FINAL_BACKOFF_HISTORY) == TRIAL_CPU:3025/900\>3000/900,TRIAL_GPU:3000/900\>3025/875,TRIAL_PAIR:3025/875\>3000/875,EXACT_GPU:3000/875\>3025/850 ]]
[[ $(apo_state_get CPU_QUALIFICATION_STATUS) == PASS && $(apo_state_get CPU_QUALIFIED_CLOCK) == 3025 ]]
[[ $(apo_state_get PHASE) == GPU_QUALIFICATION ]]
apo_validate_auto_resume_state

# If the CPU isolation qualification itself proves unstable, that exact CPU
# evidence supersedes the ambiguous anchor: lower CPU another 25 MHz and clear
# every anchor/trial field before resume.
APO_STATE=()
seed_valid_refined_auto_floor_plan
apo_final_schedule_stress_backoff ENDURANCE STABILITY_FAILURE 'ambiguous final fixture'
[[ $(apo_state_get FINAL_BACKOFF_TRIAL) == CPU ]]
apo_cpu_qualification_schedule_backoff STABILITY_FAILURE 'CPU isolation qualification failed'
[[ $(apo_state_get RECOMMENDED_CPU) == 2975 && $(apo_state_get RECOMMENDED_GPU) == 900 ]]
[[ $(apo_state_get FINAL_BACKOFF_HISTORY) == TRIAL_CPU:3025/900\>3000/900,QUAL_CPU:3000/900\>2975/900 ]]
[[ -z $(apo_state_get FINAL_BACKOFF_TRIAL '') && -z $(apo_state_get FINAL_BACKOFF_ANCHOR_CPU '') ]]
[[ -z $(apo_state_get FINAL_BACKOFF_ANCHOR_GPU '') && -z $(apo_state_get FINAL_BACKOFF_ANCHOR_CPU_QUALIFIED_CLOCK '') ]]
apo_validate_auto_resume_state

# A domain-only sweep seeds the untouched clock as inherited and never moves
# it. A final failure lowers only the selected domain by exactly 25 MHz and
# clears all prior final-duration credit.
APO_STATE=()
APO_SELECTION_POLICY=refined-max-25
APO_SWEEP_DOMAIN=gpu
APO_AUTO_GENERATED_CANDIDATES=1
APO_NORMAL_CPU=2950
APO_NORMAL_GPU=1125
APO_FINAL_DURATION_S=86400
apo_refined_seed_inherited_domain
[[ $(apo_state_get CPU_QUALIFICATION_STATUS) == INHERITED ]]
[[ $(apo_state_get SAFE_CPU) == 2950 && $(apo_state_get CPU_QUALIFIED_CLOCK) == 2950 ]]
apo_state_set SAFE_GPU 1175
apo_state_set RECOMMENDED_CPU 2950
apo_state_set RECOMMENDED_GPU 1175
apo_state_set FINAL_TARGET_CPU 2950
apo_state_set FINAL_TARGET_GPU 1175
apo_state_set GPU_QUALIFICATION_STATUS PASS
apo_state_set GPU_QUALIFICATION_CPU 2950
apo_state_set GPU_QUALIFICATION_TARGET 1175
apo_state_set GPU_QUALIFIED_CPU 2950
apo_state_set GPU_QUALIFIED_CLOCK 1175
apo_state_set VALIDATION_DURATION_S 82800
apo_state_set FINAL_STAGE ENDURANCE
apo_state_set TRYBOOT_EXPECTED 0
apo_state_set TRYBOOT_FILE_MAY_EXIST 0
apo_state_set TRYBOOT_OWNED_HASH ''
apo_state_set TRYBOOT_RESERVATION_HASH ''
apo_state_set TRYBOOT_OWNERSHIP_TOKEN ''
apo_state_set TRYBOOT_QUARANTINE_PATH ''
if apo_final_schedule_stress_backoff ENDURANCE STABILITY_FAILURE 'CPU stress returned rc=7.' CPU; then
    echo 'GPU-only run incorrectly changed its inherited CPU after exact CPU evidence' >&2
    exit 1
fi
[[ $(apo_state_get RECOMMENDED_CPU) == 2950 && $(apo_state_get RECOMMENDED_GPU) == 1175 ]]
[[ $(apo_state_get FINAL_BACKOFF_COUNT 0) == 0 ]]
apo_final_schedule_stress_backoff ENDURANCE STABILITY_FAILURE 'late GPU-only final failure'
[[ $(apo_state_get RECOMMENDED_CPU) == 2950 && $(apo_state_get RECOMMENDED_GPU) == 1150 ]]
[[ $(apo_state_get CPU_QUALIFICATION_STATUS) == INHERITED ]]
[[ $(apo_state_get PHASE) == GPU_QUALIFICATION ]]
[[ -z $(apo_state_get VALIDATION_DURATION_S '') && -z $(apo_state_get FINAL_STAGE '') ]]
[[ $(apo_state_get FINAL_BACKOFF_HISTORY) == DOMAIN_GPU:2950/1175\>2950/1150 ]]
apo_refined_validate_final_backoff_state

# Monkeebutt regression: a GPU-only 1200 MHz final stability failure may back
# down the last 25 MHz to the retained applied 3100/1175 source. It must not be
# treated as transient or terminal at the floor: GPU qualification and then a
# fresh complete final are still required, with the failure evidence retained.
APO_STATE=()
APO_SELECTION_POLICY=refined-max-25
APO_SWEEP_DOMAIN=gpu
APO_AUTO_GENERATED_CANDIDATES=1
APO_NORMAL_CPU=3100
APO_NORMAL_GPU=1175
APO_AUTO_BASELINE_CPU=3100
APO_AUTO_BASELINE_GPU=1175
APO_FINAL_DURATION_S=86400
apo_state_set SOURCE_APPLIED_CPU 3100
apo_state_set SOURCE_APPLIED_GPU 1175
apo_refined_seed_inherited_domain
apo_state_set SAFE_GPU 1200
apo_state_set RECOMMENDED_CPU 3100
apo_state_set RECOMMENDED_GPU 1200
apo_state_set FINAL_TARGET_CPU 3100
apo_state_set FINAL_TARGET_GPU 1200
apo_state_set GPU_QUALIFICATION_STATUS PASS
apo_state_set GPU_QUALIFICATION_CPU 3100
apo_state_set GPU_QUALIFICATION_TARGET 1200
apo_state_set GPU_QUALIFIED_CPU 3100
apo_state_set GPU_QUALIFIED_CLOCK 1200
apo_state_set VALIDATION_DURATION_S 11689
apo_state_set FINAL_STAGE ENDURANCE
apo_state_set TRYBOOT_EXPECTED 0
apo_state_set TRYBOOT_FILE_MAY_EXIST 0
apo_state_set TRYBOOT_OWNED_HASH ''
apo_state_set TRYBOOT_RESERVATION_HASH ''
apo_state_set TRYBOOT_OWNERSHIP_TOKEN ''
apo_state_set TRYBOOT_QUARANTINE_PATH ''
apo_final_schedule_stress_backoff ENDURANCE STABILITY_FAILURE \
    'A new kernel, power, GPU, USB, storage, or filesystem error appeared during stress.'
[[ $(apo_state_get RECOMMENDED_CPU) == 3100 && $(apo_state_get RECOMMENDED_GPU) == 1175 ]]
[[ $(apo_state_get CPU_QUALIFICATION_STATUS) == INHERITED && $(apo_state_get CPU_QUALIFIED_CLOCK) == 3100 ]]
[[ $(apo_state_get GPU_QUALIFICATION_STATUS) == NOT_STARTED && $(apo_state_get GPU_QUALIFICATION_TARGET) == 1175 ]]
[[ $(apo_state_get PHASE) == GPU_QUALIFICATION ]]
[[ -z $(apo_state_get VALIDATION_DURATION_S '') && -z $(apo_state_get FINAL_STAGE '') ]]
[[ $(apo_state_get FINAL_BACKOFF_COUNT) == 1 ]]
[[ $(apo_state_get FINAL_BACKOFF_HISTORY) == DOMAIN_GPU:3100/1200\>3100/1175 ]]
[[ $(apo_state_get FINAL_BACKOFF_LAST_CLASS) == STABILITY_FAILURE ]]
[[ $(apo_state_get FINAL_BACKOFF_LAST_REASON) == 'A new kernel, power, GPU, USB, storage, or filesystem error appeared during stress.' ]]
apo_refined_validate_final_backoff_state

# The floor fallback is symmetric for CPU-only runs and accepts a recovered
# final BOOT_FAILURE without changing the inherited GPU clock.
APO_STATE=()
APO_SELECTION_POLICY=refined-max-25
APO_SWEEP_DOMAIN=cpu
APO_AUTO_GENERATED_CANDIDATES=1
APO_NORMAL_CPU=3100
APO_NORMAL_GPU=1175
APO_AUTO_BASELINE_CPU=3100
APO_AUTO_BASELINE_GPU=1175
APO_FINAL_DURATION_S=86400
apo_state_set SOURCE_APPLIED_CPU 3100
apo_state_set SOURCE_APPLIED_GPU 1175
apo_refined_seed_inherited_domain
apo_state_set SAFE_CPU 3125
apo_state_set RECOMMENDED_CPU 3125
apo_state_set RECOMMENDED_GPU 1175
apo_state_set FINAL_TARGET_CPU 3125
apo_state_set FINAL_TARGET_GPU 1175
apo_state_set CPU_QUALIFICATION_STATUS PASS
apo_state_set CPU_QUALIFICATION_TARGET 3125
apo_state_set CPU_QUALIFIED_CLOCK 3125
apo_state_set FINAL_STAGE PRE_STRESS_BOOT
apo_state_set TRYBOOT_EXPECTED 0
apo_state_set TRYBOOT_FILE_MAY_EXIST 0
apo_state_set TRYBOOT_OWNED_HASH ''
apo_state_set TRYBOOT_RESERVATION_HASH ''
apo_state_set TRYBOOT_OWNERSHIP_TOKEN ''
apo_state_set TRYBOOT_QUARANTINE_PATH ''
apo_final_schedule_stress_backoff PRE_STRESS_BOOT BOOT_FAILURE 'CPU-only final boot health failed after verified recovery.'
[[ $(apo_state_get RECOMMENDED_CPU) == 3100 && $(apo_state_get RECOMMENDED_GPU) == 1175 ]]
[[ $(apo_state_get GPU_QUALIFICATION_STATUS) == INHERITED && $(apo_state_get GPU_QUALIFIED_CLOCK) == 1175 ]]
[[ $(apo_state_get CPU_QUALIFICATION_STATUS) == NOT_STARTED && $(apo_state_get CPU_QUALIFICATION_TARGET) == 3100 ]]
[[ $(apo_state_get PHASE) == CPU_QUALIFICATION ]]
[[ -z $(apo_state_get VALIDATION_DURATION_S '') && -z $(apo_state_get FINAL_STAGE '') ]]
[[ $(apo_state_get FINAL_BACKOFF_HISTORY) == DOMAIN_CPU:3125/1175\>3100/1175 ]]
[[ $(apo_state_get FINAL_BACKOFF_LAST_CLASS) == BOOT_FAILURE ]]
[[ $(apo_state_get FINAL_BACKOFF_LAST_REASON) == 'CPU-only final boot health failed after verified recovery.' ]]
apo_refined_validate_final_backoff_state

APO_STATE=()
APO_SELECTION_POLICY=refined-max-25
APO_SWEEP_DOMAIN=cpu
APO_AUTO_GENERATED_CANDIDATES=1
APO_NORMAL_CPU=3000
APO_NORMAL_GPU=1175
APO_FINAL_DURATION_S=86400
apo_refined_seed_inherited_domain
apo_state_set SAFE_CPU 3150
apo_state_set RECOMMENDED_CPU 3150
apo_state_set RECOMMENDED_GPU 1175
apo_state_set FINAL_TARGET_CPU 3150
apo_state_set FINAL_TARGET_GPU 1175
apo_state_set CPU_QUALIFICATION_STATUS PASS
apo_state_set CPU_QUALIFICATION_TARGET 3150
apo_state_set CPU_QUALIFIED_CLOCK 3150
apo_state_set FINAL_STAGE ENDURANCE
apo_state_set TRYBOOT_EXPECTED 0
apo_state_set TRYBOOT_FILE_MAY_EXIST 0
apo_state_set TRYBOOT_OWNED_HASH ''
apo_state_set TRYBOOT_RESERVATION_HASH ''
apo_state_set TRYBOOT_OWNERSHIP_TOKEN ''
apo_state_set TRYBOOT_QUARANTINE_PATH ''
if apo_final_schedule_stress_backoff ENDURANCE STABILITY_FAILURE 'GPU stress returned rc=7 after V3D initialization.' GPU; then
    echo 'CPU-only run incorrectly changed its inherited GPU after exact GPU evidence' >&2
    exit 1
fi
[[ $(apo_state_get RECOMMENDED_CPU) == 3150 && $(apo_state_get RECOMMENDED_GPU) == 1175 ]]
[[ $(apo_state_get FINAL_BACKOFF_COUNT 0) == 0 ]]
apo_final_schedule_stress_backoff ENDURANCE STABILITY_FAILURE 'late CPU-only final failure'
[[ $(apo_state_get RECOMMENDED_CPU) == 3125 && $(apo_state_get RECOMMENDED_GPU) == 1175 ]]
[[ $(apo_state_get GPU_QUALIFICATION_STATUS) == INHERITED ]]
[[ $(apo_state_get GPU_QUALIFIED_CLOCK) == 1175 && $(apo_state_get PHASE) == CPU_QUALIFICATION ]]
[[ $(apo_state_get FINAL_BACKOFF_HISTORY) == DOMAIN_CPU:3150/1175\>3125/1175 ]]
apo_refined_validate_final_backoff_state

# A full-mode ambiguous combined-final failure isolates one domain at a time:
# CPU -25, then GPU -25 from the saved anchor, then both -25. If all three
# fresh full-duration trials fail, that lower pair becomes the next anchor and
# the sequence repeats. No partial final duration is retained.
APO_STATE=()
seed_valid_refined_auto_floor_plan
APO_FINAL_DURATION_S=86400
apo_state_set FINAL_STAGE ENDURANCE
apo_state_set TRYBOOT_EXPECTED 0
apo_state_set TRYBOOT_FILE_MAY_EXIST 0
apo_state_set TRYBOOT_OWNED_HASH ''
apo_state_set TRYBOOT_RESERVATION_HASH ''
apo_state_set TRYBOOT_OWNERSHIP_TOKEN ''
apo_state_set TRYBOOT_QUARANTINE_PATH ''
apo_validate_auto_resume_state
apo_state_set VALIDATION_DURATION_S 86399
apo_final_schedule_stress_backoff ENDURANCE STABILITY_FAILURE 'ambiguous anchor failure'
[[ $(apo_state_get RECOMMENDED_CPU) == 3000 && $(apo_state_get RECOMMENDED_GPU) == 900 ]]
[[ $(apo_state_get FINAL_BACKOFF_TRIAL) == CPU && $(apo_state_get FINAL_BACKOFF_ANCHOR_CPU) == 3025 ]]
[[ $(apo_state_get PHASE) == CPU_QUALIFICATION && -z $(apo_state_get VALIDATION_DURATION_S '') ]]
apo_validate_auto_resume_state

apo_state_set CPU_QUALIFICATION_STATUS PASS
apo_state_set CPU_QUALIFICATION_TARGET 3000
apo_state_set CPU_QUALIFIED_CLOCK 3000
apo_state_set FINAL_TARGET_CPU 3000
apo_state_set FINAL_TARGET_GPU 900
apo_state_set FINAL_STAGE ENDURANCE
apo_state_set PHASE FINAL_VALIDATION
apo_validate_auto_resume_state
apo_state_set VALIDATION_DURATION_S 86399
apo_final_schedule_stress_backoff ENDURANCE STABILITY_FAILURE 'CPU isolation final failed'
[[ $(apo_state_get RECOMMENDED_CPU) == 3025 && $(apo_state_get RECOMMENDED_GPU) == 875 ]]
[[ $(apo_state_get FINAL_BACKOFF_TRIAL) == GPU && $(apo_state_get PHASE) == GPU_QUALIFICATION ]]
[[ -z $(apo_state_get VALIDATION_DURATION_S '') ]]
apo_validate_auto_resume_state

apo_state_set GPU_QUALIFICATION_STATUS PASS
apo_state_set GPU_QUALIFICATION_CPU 3025
apo_state_set GPU_QUALIFICATION_TARGET 875
apo_state_set GPU_QUALIFIED_CPU 3025
apo_state_set GPU_QUALIFIED_CLOCK 875
apo_state_set FINAL_TARGET_CPU 3025
apo_state_set FINAL_TARGET_GPU 875
apo_state_set FINAL_STAGE ENDURANCE
apo_state_set PHASE FINAL_VALIDATION
apo_validate_auto_resume_state
apo_state_set VALIDATION_DURATION_S 86399
apo_final_schedule_stress_backoff ENDURANCE STABILITY_FAILURE 'GPU isolation final failed'
[[ $(apo_state_get RECOMMENDED_CPU) == 3000 && $(apo_state_get RECOMMENDED_GPU) == 875 ]]
[[ $(apo_state_get FINAL_BACKOFF_TRIAL) == PAIR && $(apo_state_get PHASE) == CPU_QUALIFICATION ]]
[[ -z $(apo_state_get VALIDATION_DURATION_S '') ]]
apo_validate_auto_resume_state

apo_state_set CPU_QUALIFICATION_STATUS PASS
apo_state_set CPU_QUALIFICATION_TARGET 3000
apo_state_set CPU_QUALIFIED_CLOCK 3000
apo_state_set GPU_QUALIFICATION_STATUS PASS
apo_state_set GPU_QUALIFICATION_CPU 3000
apo_state_set GPU_QUALIFICATION_TARGET 875
apo_state_set GPU_QUALIFIED_CPU 3000
apo_state_set GPU_QUALIFIED_CLOCK 875
apo_state_set FINAL_TARGET_CPU 3000
apo_state_set FINAL_TARGET_GPU 875
apo_state_set FINAL_STAGE ENDURANCE
apo_state_set PHASE FINAL_VALIDATION
apo_validate_auto_resume_state
apo_state_set VALIDATION_DURATION_S 86399
apo_final_schedule_stress_backoff ENDURANCE STABILITY_FAILURE 'paired final failed'
[[ $(apo_state_get RECOMMENDED_CPU) == 2975 && $(apo_state_get RECOMMENDED_GPU) == 875 ]]
[[ $(apo_state_get FINAL_BACKOFF_TRIAL) == CPU ]]
[[ $(apo_state_get FINAL_BACKOFF_ANCHOR_CPU) == 3000 && $(apo_state_get FINAL_BACKOFF_ANCHOR_GPU) == 875 ]]
[[ -z $(apo_state_get VALIDATION_DURATION_S '') ]]
apo_validate_auto_resume_state

# A longer-final continuation under the refined policy enters the same
# CPU-then-GPU isolation sequence. It must not switch to the legacy edge-first
# state machine after a safely recovered failure.
APO_STATE=()
APO_SELECTION_POLICY=refined-max-25
APO_SWEEP_DOMAIN=all
APO_AUTO_GENERATED_CANDIDATES=1
APO_EDGE_CPU_24H=0
APO_EDGE_ORDER=floor-first
APO_EDGE_DURATION_S=86400
APO_FINAL_DURATION_S=86400
APO_NORMAL_CPU=2400
APO_NORMAL_GPU=960
APO_AUTO_BASELINE_CPU=2400
APO_AUTO_BASELINE_GPU=960
apo_state_set SAFE_CPU 3000
apo_state_set SAFE_GPU 1100
apo_state_set RECOMMENDED_CPU 3000
apo_state_set RECOMMENDED_GPU 1100
apo_state_set FINAL_TARGET_CPU 3000
apo_state_set FINAL_TARGET_GPU 1100
apo_state_set CPU_QUALIFICATION_STATUS PASS
apo_state_set CPU_QUALIFICATION_TARGET 3000
apo_state_set CPU_QUALIFIED_CLOCK 3000
apo_state_set GPU_QUALIFICATION_STATUS PASS
apo_state_set GPU_QUALIFICATION_CPU 3000
apo_state_set GPU_QUALIFICATION_TARGET 1100
apo_state_set GPU_QUALIFIED_CPU 3000
apo_state_set GPU_QUALIFIED_CLOCK 1100
apo_state_set EDGE_CPU_STATUS NOT_REQUESTED
apo_state_set FLOOR_VALIDATED 0
apo_state_set POST_FLOOR_FINAL 1
apo_state_set POST_FLOOR_FINAL_STAGE VALIDATING
apo_state_set TRYBOOT_EXPECTED 0
apo_state_set TRYBOOT_FILE_MAY_EXIST 0
apo_state_set TRYBOOT_OWNED_HASH ''
apo_state_set TRYBOOT_RESERVATION_HASH ''
apo_state_set TRYBOOT_OWNERSHIP_TOKEN ''
apo_state_set TRYBOOT_QUARANTINE_PATH ''
apo_post_floor_final_schedule_stress_backoff ENDURANCE STABILITY_FAILURE 'refined longer-final fixture failure'
[[ $(apo_state_get POST_FLOOR_FINAL_STAGE) == BACKOFF_TUNING ]]
[[ $(apo_state_get FINAL_BACKOFF_TRIAL) == CPU ]]
[[ $(apo_state_get RECOMMENDED_CPU) == 2975 && $(apo_state_get RECOMMENDED_GPU) == 1100 ]]
[[ $APO_EDGE_CPU_24H == 0 && $APO_EDGE_ORDER == floor-first ]]

# If the first requested domain-only candidate fails and 25 MHz refinement has
# no intermediate value to try, the existing applied result is explicitly
# preserved instead of being relabeled as a newly validated result.
APO_STATE=()
APO_SELECTION_POLICY=refined-max-25
APO_SWEEP_DOMAIN=gpu
APO_AUTO_GENERATED_CANDIDATES=1
APO_EDGE_CPU_24H=0
APO_NORMAL_CPU=2950
APO_NORMAL_GPU=1175
APO_NORMAL_VOLTAGE=0
APO_TEST_VOLTAGE=0
APO_AUTO_BASELINE_CPU=2400
APO_AUTO_BASELINE_GPU=960
APO_AUTO_BASELINE_VOLTAGE=0
APO_AUTO_BASELINE_PROVENANCE='verified-default'
APO_AUTO_BASELINE_EVIDENCE=none
APO_CPU_START_AT=''
APO_GPU_START_AT=1200
APO_CPU_CANDIDATES=()
APO_GPU_CANDIDATES=(1200)
APO_CFG[CPU_CANDIDATES]=''
APO_CFG[GPU_CANDIDATES]=1200
APO_CFG[BACKOFF_STEPS]=0
APO_CFG[VOLTAGE_DELTA_UV]=existing
apo_state_set CFG_SELECTION_POLICY refined-max-25
apo_state_set CFG_SWEEP_DOMAIN gpu
apo_state_set SOURCE_APPLIED_RUN_ID 20260901-195530-ad946cde6c24975f
apo_state_set SOURCE_APPLIED_PERMANENT_HASH aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
apo_state_set SOURCE_APPLIED_LIVE_HASH aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
apo_state_set SOURCE_APPLIED_HASH_RELATION exact
apo_state_set SOURCE_APPLIED_HASH_EVIDENCE live-hash-equals-retained-applied-hash
apo_state_set SOURCE_APPLIED_CPU 2950
apo_state_set SOURCE_APPLIED_GPU 1175
apo_state_set SOURCE_APPLIED_VOLTAGE 0
apo_state_set PERMANENT_HASH aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
apo_state_set APPLY_STATUS NOT_APPLIED
apo_refined_seed_inherited_domain
apo_state_set GPU_INDEX 0
apo_state_set PASSED_GPUS ''
apo_state_set GPU_FAILURE_BOUNDARY 1200
apo_state_set GPU_REFINE_CANDIDATES ''
apo_state_set GPU_REFINE_INDEX 0
apo_state_set GPU_REFINE_COMPLETE 1
apo_state_set GPU_GUARD_TARGET 1175
apo_state_set GPU_GUARD_VERIFIED 1
apo_state_set SAFE_GPU 1175
apo_state_set GPU_QUALIFICATION_STATUS NOT_STARTED
apo_state_set GPU_QUALIFICATION_CPU ''
apo_state_set GPU_QUALIFICATION_TARGET ''
apo_state_set GPU_QUALIFIED_CPU ''
apo_state_set GPU_QUALIFIED_CLOCK ''
apo_final_initialize_backoff_state
apo_state_set EDGE_CPU_STATUS NOT_REQUESTED
apo_state_set FLOOR_VALIDATED 0
apo_state_set PHASE SELECTION
apo_state_set SUBPHASE GPU
apo_state_set STATUS RUNNING
apo_state_set RECOVERY_WAIT_STATUS IDLE
apo_state_set RECOVERY_WAIT_CONTEXT ''
apo_state_set RECOVERY_WAIT_STARTED_AT ''
apo_state_set RECOVERY_WAIT_TIMEOUTS 0
if apo_select_conservative_clocks; then
    echo 'domain-only no-improvement result was falsely accepted as a new validation' >&2
    exit 1
fi
[[ $(apo_state_get FAILURE_CLASS) == STABILITY_FAILURE ]]
[[ $(apo_state_get FAILURE_REASON) == *'previously validated applied source remains active and unchanged'* ]]
[[ $(apo_state_get VALIDATED 0) == 0 ]]

printf 'test_resume_progress: PASS\n'
