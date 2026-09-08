#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
APO_ROOT=$ROOT
source "$ROOT/lib/common.sh"
source "$ROOT/lib/config.sh"
source "$ROOT/lib/state.sh"
source "$ROOT/lib/history.sh"
source "$ROOT/lib/candidates.sh"

SAVE_COUNT=0
APO_CFG=([FINAL_DURATION_S]=172800 [BACKOFF_STEPS]=0 [VOLTAGE_DELTA_UV]=existing)
APO_SELECTION_POLICY=refined-max-25
APO_SWEEP_DOMAIN=all
APO_AUTO_GENERATED_CANDIDATES=1
APO_AUTO_BASELINE_CPU=2400
APO_AUTO_BASELINE_GPU=960
APO_NORMAL_CPU=2400
APO_NORMAL_GPU=960
APO_FINAL_DURATION_S=172800
APO_QUALIFICATION_DURATION_S=7200
APO_CPU_MAX=3200
APO_GPU_MAX=1200

apo_state_save() { SAVE_COUNT=$((SAVE_COUNT + 1)); }
apo_state_phase() {
    apo_state_set PHASE "$1"
    apo_state_set SUBPHASE "$2"
    apo_state_set STATUS "$3"
    apo_state_save
}
apo_summary_line() { :; }
apo_event() { :; }
apo_class_is_edge_failure() { [[ $1 == BOOT_FAILURE || $1 == STABILITY_FAILURE ]]; }

seed_plan() {
    APO_STATE=()
    SAVE_COUNT=0
    apo_state_set RUN_ID history-scheduler
    apo_state_set HISTORY_ISOLATION_STAGE PLANNED
    apo_state_set HISTORY_PAIR_FRONTIERS 3100/1200
    apo_state_set HISTORY_ISOLATION_ANCHOR_CPU 3100
    apo_state_set HISTORY_ISOLATION_ANCHOR_GPU 1200
    apo_state_set HISTORY_CPU_TRIAL_CPU 3075
    apo_state_set HISTORY_CPU_TRIAL_GPU 1200
    apo_state_set HISTORY_GPU_TRIAL_CPU 3100
    apo_state_set HISTORY_GPU_TRIAL_GPU 1175
    apo_state_set HISTORY_PAIR_TRIAL_CPU 3075
    apo_state_set HISTORY_PAIR_TRIAL_GPU 1175
    apo_state_set HISTORY_BASE_CPU_QUALIFIED_CLOCK ''
    apo_state_set HISTORY_CPU_TRIAL_QUALIFIED_CLOCK ''
    apo_state_set HISTORY_ISOLATION_HANDOFF_CPU ''
    apo_state_set HISTORY_ISOLATION_HANDOFF_GPU ''
    apo_state_set HISTORY_ISOLATION_HISTORY ''
    apo_state_set HISTORY_FAILURE_EVENTS ''
    apo_state_set FINAL_BACKOFF_COUNT 0
    apo_state_set FINAL_BACKOFF_CPU ''
    apo_state_set FINAL_BACKOFF_GPU ''
    apo_state_set FINAL_BACKOFF_HISTORY ''
    apo_state_set FINAL_BACKOFF_LAST_STAGE ''
    apo_state_set FINAL_BACKOFF_LAST_CLASS ''
    apo_state_set FINAL_BACKOFF_LAST_REASON ''
    apo_state_set FINAL_BACKOFF_ANCHOR_CPU ''
    apo_state_set FINAL_BACKOFF_ANCHOR_GPU ''
    apo_state_set FINAL_BACKOFF_TRIAL ''
    apo_state_set FINAL_BACKOFF_ANCHOR_CPU_QUALIFIED_CLOCK ''
    apo_state_set SAFE_CPU 3100
    apo_state_set SAFE_GPU 1200
    apo_state_set CPU_QUALIFICATION_STATUS PASS
    apo_state_set CPU_QUALIFICATION_TARGET 3100
    apo_state_set CPU_QUALIFIED_CLOCK 3100
    apo_state_set CPU_QUALIFICATION_HISTORY ''
    apo_state_set CPU_QUALIFICATION_LAST_CLASS ''
    apo_state_set CPU_QUALIFICATION_LAST_REASON ''
    apo_state_set GPU_QUALIFICATION_STATUS PASS
    apo_state_set GPU_QUALIFICATION_CPU 3075
    apo_state_set GPU_QUALIFICATION_TARGET 1200
    apo_state_set GPU_QUALIFIED_CPU 3075
    apo_state_set GPU_QUALIFIED_CLOCK 1200
    apo_state_set RECOMMENDED_CPU 3100
    apo_state_set RECOMMENDED_GPU ''
    apo_state_set FINAL_TARGET_CPU ''
    apo_state_set FINAL_TARGET_GPU ''
    apo_state_set FINAL_STAGE ''
    apo_state_set FINAL_CPU ''
    apo_state_set FINAL_GPU ''
    apo_state_set VALIDATION_DURATION_S ''
    apo_state_set VALIDATION_SCHEMA ''
    apo_state_set VALIDATED 0
    apo_state_set TRYBOOT_EXPECTED 0
    apo_state_set TRYBOOT_FILE_MAY_EXIST 0
    apo_state_set TRYBOOT_OWNED_HASH ''
    apo_state_set TRYBOOT_RESERVATION_HASH ''
    apo_state_set TRYBOOT_OWNERSHIP_TOKEN ''
    apo_state_set TRYBOOT_QUARANTINE_PATH ''
    apo_state_set EDGE_CPU_STATUS NOT_REQUESTED
    apo_state_set FLOOR_VALIDATED 0
}

# A fresh proof above the historical CPU trial starts a new, exact CPU trial;
# no historical pass is borrowed.
seed_plan
if apo_history_after_cpu_qualification; then
    printf 'expected fresh CPU qualification to schedule a lower trial\n' >&2
    exit 1
else
    rc=$?
fi
[[ $rc == 2 ]]
[[ $(apo_state_get HISTORY_ISOLATION_STAGE '') == CPU_TRIAL ]]
[[ $(apo_state_get HISTORY_BASE_CPU_QUALIFIED_CLOCK '') == 3100 ]]
[[ $(apo_state_get CPU_QUALIFICATION_TARGET '') == 3075 ]]
[[ -z $(apo_state_get CPU_QUALIFIED_CLOCK '') ]]
[[ -z $(apo_state_get FINAL_BACKOFF_HISTORY '') ]]
apo_history_validate_plan_state

# If the fresh CPU search already lands at/below the precomputed trial, the
# forbidden quadrant is already avoided and the plan closes without failure.
seed_plan
apo_state_set SAFE_CPU 3075
apo_state_set RECOMMENDED_CPU 3075
apo_state_set CPU_QUALIFICATION_TARGET 3075
apo_state_set CPU_QUALIFIED_CLOCK 3075
apo_history_after_cpu_qualification
[[ $(apo_state_get HISTORY_ISOLATION_STAGE '') == NONE ]]
[[ $(apo_state_get HISTORY_ISOLATION_HISTORY '') == *'|PLANNED|3075|960|NONE|3075|960|PASS|CPU|'* ]]

# A current-run exact CPU qualification backoff supersedes the ambiguous plan
# and must not strand resume merely because the original trial changed.
seed_plan
apo_state_set HISTORY_ISOLATION_STAGE CPU_TRIAL
apo_state_set HISTORY_BASE_CPU_QUALIFIED_CLOCK 3100
apo_state_set CPU_QUALIFICATION_TARGET 3050
apo_state_set CPU_QUALIFIED_CLOCK 3050
apo_state_set CPU_QUALIFICATION_HISTORY 'CPU:3075>3050'
apo_history_after_cpu_qualification
[[ $(apo_state_get HISTORY_ISOLATION_STAGE '') == NONE ]]
[[ $(apo_state_get CPU_QUALIFICATION_HISTORY '') == 'CPU:3075>3050' ]]

# The same exact-current-run rule applies if the both-lowered branch discovers
# that its planned CPU is still too high during qualification.
seed_plan
apo_state_set HISTORY_ISOLATION_STAGE PAIR_TRIAL
apo_state_set HISTORY_BASE_CPU_QUALIFIED_CLOCK 3100
apo_state_set RECOMMENDED_CPU 3050
apo_state_set RECOMMENDED_GPU 1175
apo_state_set CPU_QUALIFICATION_TARGET 3050
apo_state_set CPU_QUALIFIED_CLOCK 3050
apo_state_set CPU_QUALIFICATION_HISTORY 'CPU:3075>3050'
apo_history_after_cpu_qualification
[[ $(apo_state_get HISTORY_ISOLATION_STAGE '') == NONE ]]
[[ $(apo_state_get HISTORY_ISOLATION_HISTORY '') == *'|PAIR_TRIAL|3075|1175|NONE|3050|1175|PASS|CPU|'* ]]

seed_active_trial() {
    seed_plan
    apo_state_set HISTORY_ISOLATION_STAGE CPU_TRIAL
    apo_state_set HISTORY_BASE_CPU_QUALIFIED_CLOCK 3100
    apo_state_set HISTORY_CPU_TRIAL_QUALIFIED_CLOCK 3075
    apo_state_set CPU_QUALIFICATION_TARGET 3075
    apo_state_set CPU_QUALIFIED_CLOCK 3075
    apo_state_set RECOMMENDED_CPU 3075
    apo_state_set RECOMMENDED_GPU 1200
    apo_state_set FINAL_TARGET_CPU 3075
    apo_state_set FINAL_TARGET_GPU 1200
    apo_state_set FINAL_STAGE ENDURANCE
    apo_state_set FINAL_CPU 3075
    apo_state_set FINAL_GPU 1200
    apo_state_set VALIDATION_DURATION_S 172800
    apo_state_set VALIDATED 1
}

# An ambiguous failure tries the opposite one-domain reduction and restarts
# the requested final duration from zero.
seed_active_trial
apo_history_schedule_isolation_failure ENDURANCE STABILITY_FAILURE 'Unexpected reboot under combined load.' ''
[[ $(apo_state_get HISTORY_ISOLATION_STAGE '') == GPU_TRIAL ]]
[[ $(apo_state_get RECOMMENDED_CPU '') == 3100 ]]
[[ $(apo_state_get RECOMMENDED_GPU '') == 1175 ]]
[[ $(apo_state_get PHASE '') == GPU_QUALIFICATION ]]
[[ -z $(apo_state_get VALIDATION_DURATION_S '') ]]
[[ -z $(apo_state_get FINAL_CPU '') && -z $(apo_state_get FINAL_GPU '') ]]
[[ -z $(apo_state_get FINAL_BACKOFF_HISTORY '') ]]
[[ $(apo_state_get HISTORY_FAILURE_EVENTS '') == *'|3075|1200|STABILITY_FAILURE|PAIR|'* ]]
apo_history_validate_plan_state

# If the GPU-only alternative also fails ambiguously, lower both domains.
apo_state_set FINAL_TARGET_CPU 3100
apo_state_set FINAL_TARGET_GPU 1175
apo_state_set FINAL_STAGE ENDURANCE
apo_state_set RECOMMENDED_CPU 3100
apo_state_set RECOMMENDED_GPU 1175
apo_history_schedule_isolation_failure ENDURANCE BOOT_FAILURE 'Unexpected reboot in the GPU-lowered branch.' ''
[[ $(apo_state_get HISTORY_ISOLATION_STAGE '') == PAIR_TRIAL ]]
[[ $(apo_state_get RECOMMENDED_CPU '') == 3075 ]]
[[ $(apo_state_get RECOMMENDED_GPU '') == 1175 ]]
[[ $(apo_state_get PHASE '') == CPU_QUALIFICATION ]]
[[ -z $(apo_state_get VALIDATION_DURATION_S '') ]]
[[ -z $(apo_state_get FINAL_BACKOFF_HISTORY '') ]]
apo_history_validate_plan_state

# A third ambiguous failure establishes a replay origin for ordinary 25 MHz
# isolation without inventing earlier current-run FINAL_BACKOFF_HISTORY.
apo_state_set CPU_QUALIFICATION_STATUS PASS
apo_state_set CPU_QUALIFICATION_TARGET 3075
apo_state_set CPU_QUALIFIED_CLOCK 3075
apo_state_set RECOMMENDED_CPU 3075
apo_state_set RECOMMENDED_GPU 1175
apo_state_set FINAL_TARGET_CPU 3075
apo_state_set FINAL_TARGET_GPU 1175
apo_state_set FINAL_STAGE ENDURANCE
if apo_history_schedule_isolation_failure ENDURANCE STABILITY_FAILURE 'Pair trial also rebooted.' ''; then
    printf 'expected pair-trial handoff return code\n' >&2
    exit 1
else
    rc=$?
fi
[[ $rc == 2 ]]
[[ $(apo_state_get HISTORY_ISOLATION_STAGE '') == DONE ]]
[[ $(apo_state_get HISTORY_ISOLATION_HANDOFF_CPU '') == 3075 ]]
[[ $(apo_state_get HISTORY_ISOLATION_HANDOFF_GPU '') == 1175 ]]
[[ -z $(apo_state_get FINAL_BACKOFF_HISTORY '') ]]

# The first ordinary backoff replays from that persisted handoff, not SAFE_*.
apo_state_set FINAL_BACKOFF_COUNT 1
apo_state_set FINAL_BACKOFF_CPU 3050
apo_state_set FINAL_BACKOFF_GPU 1175
apo_state_set FINAL_BACKOFF_HISTORY 'TRIAL_CPU:3075/1175>3050/1175'
apo_state_set FINAL_BACKOFF_LAST_STAGE ENDURANCE
apo_state_set FINAL_BACKOFF_LAST_CLASS STABILITY_FAILURE
apo_state_set FINAL_BACKOFF_LAST_REASON 'Pair trial also rebooted.'
apo_state_set FINAL_BACKOFF_ANCHOR_CPU 3075
apo_state_set FINAL_BACKOFF_ANCHOR_GPU 1175
apo_state_set FINAL_BACKOFF_TRIAL CPU
apo_state_set FINAL_BACKOFF_ANCHOR_CPU_QUALIFIED_CLOCK 3075
apo_refined_validate_final_backoff_state

# Exact domain evidence closes the ambiguous scheduler immediately and hands
# the rejected pair to the domain-specific ordinary backoff path.
seed_active_trial
if apo_history_schedule_isolation_failure ENDURANCE STABILITY_FAILURE 'CPU worker failed.' CPU; then
    printf 'expected exact-domain handoff return code\n' >&2
    exit 1
else
    rc=$?
fi
[[ $rc == 2 ]]
[[ $(apo_state_get HISTORY_ISOLATION_STAGE '') == DONE ]]
[[ $(apo_state_get HISTORY_ISOLATION_HISTORY '') == *'|STABILITY_FAILURE|CPU|'* ]]
[[ -z $(apo_state_get FINAL_BACKOFF_HISTORY '') ]]

printf 'test_history_scheduler: PASS\n'
