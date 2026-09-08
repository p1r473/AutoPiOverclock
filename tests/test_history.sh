#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
APO_ROOT=$ROOT
source "$ROOT/lib/common.sh"
source "$ROOT/lib/state.sh"
source "$ROOT/lib/history.sh"

TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT

APO_OUTPUT_DIR=$TMP/good
APO_TARGET_SLUG=pi-one
APO_REMOTE_TARGET=pi@pi-one
APO_PROFILE=pi5
mkdir -p -- "$APO_OUTPUT_DIR"

# Windows Git Bash cannot fsync its synthetic /tmp.  Production keeps the
# durability calls; this focused controller-side fixture tests atomic content.
sync() { :; }

# A compact fixture hook proves that the scanner invokes validation inside its
# isolated load path.  Production uses the full automatic-resume validator.
apo_history_validate_loaded_state() {
    [[ $(apo_state_get TEST_VALID 0) == 1 ]]
}

write_state() {
    local destination=$1 key value
    shift
    : > "$destination"
    while (( $# > 0 )); do
        key=$1
        value=$2
        shift 2
        printf '%s\t%s\n' "$key" "$(apo_state_encode "$value")" >> "$destination"
    done
}

write_auto_state() {
    local run_id=$1
    shift
    write_state "$APO_OUTPUT_DIR/${APO_TARGET_SLUG}-${run_id}.state" \
        FORMAT_VERSION 1 RUN_SCHEMA "$APO_CURRENT_RUN_SCHEMA" RUN_ID "$run_id" \
        CREATED_AT 2026-09-07T01:00:00-0400 UPDATED_AT 2026-09-07T02:00:00-0400 \
        REMOTE_TARGET "$APO_REMOTE_TARGET" TARGET_SLUG "$APO_TARGET_SLUG" \
        ORIGIN_COMMAND overclock READ_ONLY_RUN 0 CFG_AUTO_GENERATED_CANDIDATES 1 \
        CFG_SELECTION_POLICY refined-max-25 PROFILE pi5 TEST_VALID 1 "$@"
}

# Persisted structured evidence remains useful even when the run itself was
# interrupted; no terminal STATUS or candidate tuple is treated as evidence.
write_auto_state run-a \
    STATUS RUNNING PHASE FINAL TRYBOOT_EXPECTED 1 \
    CPU_FAILURE_BOUNDARY 3100 GPU_FAILURE_BOUNDARY 1200 \
    CPU_QUALIFICATION_HISTORY 'CPU:3075>3050' \
    FINAL_BACKOFF_HISTORY 'QUAL_CPU:3050/1175>3025/1175,TRIAL_CPU:3025/1175>3000/1175,TRIAL_GPU:3000/1175>3025/1150'

write_auto_state run-b \
    STATUS FAILED FAILURE_CLASS STABILITY_FAILURE CANDIDATE_CPU 999 CANDIDATE_GPU 999 \
    CPU_FAILURE_BOUNDARY 3000 GPU_FAILURE_BOUNDARY 1175 \
    FINAL_BACKOFF_HISTORY 'EXACT_GPU:2975/1150>2975/1125'

write_auto_state run-c \
    STATUS RUNNING \
    FINAL_BACKOFF_HISTORY 'TRIAL_CPU:2975/1200>2950/1200'

event_reason=$(apo_state_encode 'Recovered exact CPU failure.')
event_source=$(apo_state_encode final-endurance)
ambiguous_reason=$(apo_state_encode 'Recovered ambiguous pair failure.')
write_auto_state run-d \
    STATUS RUNNING \
    HISTORY_FAILURE_EVENTS "v1|2026-09-07T03:00:00-0400|run-d|2900|1150|STABILITY_FAILURE|CPU|${event_source}|${event_reason}" \
    HISTORY_ISOLATION_HISTORY "v1|2026-09-07T03:05:00-0400|run-d|CPU_TRIAL|2850|1150|GPU_TRIAL|2900|1125|STABILITY_FAILURE|AMBIGUOUS|${ambiguous_reason}"

# These are exact filename candidates but not authoritative history inputs.
write_state "$APO_OUTPUT_DIR/${APO_TARGET_SLUG}-test-run.state" \
    FORMAT_VERSION 1 RUN_SCHEMA "$APO_CURRENT_RUN_SCHEMA" RUN_ID test-run \
    REMOTE_TARGET "$APO_REMOTE_TARGET" TARGET_SLUG "$APO_TARGET_SLUG" ORIGIN_COMMAND test
write_state "$APO_OUTPUT_DIR/${APO_TARGET_SLUG}-other-target.state" \
    FORMAT_VERSION 1 RUN_SCHEMA "$APO_CURRENT_RUN_SCHEMA" RUN_ID other-target \
    REMOTE_TARGET 'pi@different-host' TARGET_SLUG "$APO_TARGET_SLUG" ORIGIN_COMMAND overclock
write_state "$APO_OUTPUT_DIR/${APO_TARGET_SLUG}-old-schema.state" \
    FORMAT_VERSION 1 RUN_SCHEMA 9 RUN_ID old-schema \
    REMOTE_TARGET "$APO_REMOTE_TARGET" TARGET_SLUG "$APO_TARGET_SLUG" ORIGIN_COMMAND overclock
write_state "$APO_OUTPUT_DIR/${APO_TARGET_SLUG}-incompatible.state" \
    FORMAT_VERSION 1 RUN_SCHEMA "$APO_CURRENT_RUN_SCHEMA" RUN_ID incompatible \
    REMOTE_TARGET "$APO_REMOTE_TARGET" TARGET_SLUG "$APO_TARGET_SLUG" \
    ORIGIN_COMMAND overclock READ_ONLY_RUN 0 CFG_AUTO_GENERATED_CANDIDATES 1 \
    CFG_SELECTION_POLICY refined-max-25 PROFILE different TEST_VALID 1 CPU_FAILURE_BOUNDARY 2500

# The production definition was sourced above; focused fixture overrides appear
# later in this file for planner-only cases.
# shellcheck disable=SC2218
apo_history_refresh
[[ $APO_HISTORY_ACCEPTED_STATES == 4 ]]
[[ $APO_HISTORY_CPU_FAILURE_BOUNDARY == 2900 ]]
[[ $APO_HISTORY_GPU_FAILURE_BOUNDARY == 1150 ]]
[[ $APO_HISTORY_PAIR_FRONTIERS == '2850/1150' ]]
[[ $APO_HISTORY_EVIDENCE_COUNT == 12 ]]
[[ $APO_HISTORY_PROVENANCE == *'CPU|3000|run-b|CPU_FAILURE_BOUNDARY|'* ]]
[[ $APO_HISTORY_PROVENANCE == *'PAIR|2975/1200|run-c|FINAL_BACKOFF_TRIAL_CPU|'* ]]
[[ $APO_HISTORY_PROVENANCE != *'999'* ]]
[[ -f $APO_HISTORY_LEDGER_FILE && ! -L $APO_HISTORY_LEDGER_FILE ]]
grep -Fq 'Authority: validated .state files only; this ledger is rebuilt and never read as input.' "$APO_HISTORY_LEDGER_FILE"
grep -Fq 'Clear CPU failed boundary: 2900' "$APO_HISTORY_LEDGER_FILE"
grep -Fq 'Ambiguous failed-pair frontier: 2850/1150' "$APO_HISTORY_LEDGER_FILE"
grep -Fq '2026-09-07T03:00:00-0400 | run-d | 2900 | 1150 | STABILITY_FAILURE | CPU | Recovered exact CPU failure.' "$APO_HISTORY_LEDGER_FILE"
grep -Fq '2026-09-07T03:05:00-0400 | run-d | 2850 | 1150 | STABILITY_FAILURE | PAIR | Recovered ambiguous pair failure.' "$APO_HISTORY_LEDGER_FILE"

# The human file cannot authorize anything and is replaced from state.
printf 'CPU failed at 1 MHz\n' > "$APO_HISTORY_LEDGER_FILE"
# shellcheck disable=SC2218
apo_history_refresh
[[ $APO_HISTORY_CPU_FAILURE_BOUNDARY == 2900 ]]
if grep -Fq '1 MHz' "$APO_HISTORY_LEDGER_FILE"; then
    printf 'ledger text was incorrectly trusted as history input\n' >&2
    exit 1
fi

# A validator-rejected exact current-schema state fails the entire scan.
APO_OUTPUT_DIR=$TMP/rejected
mkdir -p -- "$APO_OUTPUT_DIR"
write_state "$APO_OUTPUT_DIR/${APO_TARGET_SLUG}-rejected.state" \
    FORMAT_VERSION 1 RUN_SCHEMA "$APO_CURRENT_RUN_SCHEMA" RUN_ID rejected \
    REMOTE_TARGET "$APO_REMOTE_TARGET" TARGET_SLUG "$APO_TARGET_SLUG" \
    ORIGIN_COMMAND overclock READ_ONLY_RUN 0 CFG_AUTO_GENERATED_CANDIDATES 1 \
    CFG_SELECTION_POLICY refined-max-25 PROFILE pi5 TEST_VALID 0 CPU_FAILURE_BOUNDARY 2800
if apo_history_scan_retained_states; then
    printf 'expected validator-rejected history to fail closed\n' >&2
    exit 1
fi
[[ $APO_HISTORY_SCAN_ERROR == *'rejected.state'* ]]
[[ -z $APO_HISTORY_CPU_FAILURE_BOUNDARY ]]

# An abandoned automatic run that never left PREPARE has no committed failure
# evidence.  A later reset plus fresh default-history overclock must be able to
# screen past it instead of feeding the incomplete state to resume validation.
# Unrelated audit commands are also ignored before their unrelated damaged
# payload is decoded.
APO_OUTPUT_DIR=$TMP/early-and-audits
mkdir -p -- "$APO_OUTPUT_DIR"
write_auto_state abandoned-prepare \
    STATUS PREPARING PHASE PREPARE TEST_VALID 0
for irrelevant_origin in reset prepare test; do
    write_state "$APO_OUTPUT_DIR/${APO_TARGET_SLUG}-${irrelevant_origin}-audit.state" \
        FORMAT_VERSION 1 RUN_SCHEMA "$APO_CURRENT_RUN_SCHEMA" RUN_ID "${irrelevant_origin}-audit" \
        REMOTE_TARGET "$APO_REMOTE_TARGET" TARGET_SLUG "$APO_TARGET_SLUG" \
        ORIGIN_COMMAND "$irrelevant_origin" READ_ONLY_RUN 0 CFG_AUTO_GENERATED_CANDIDATES 0
    printf 'DAMAGED_UNRELATED\t%%%s\n' "$irrelevant_origin" >> \
        "$APO_OUTPUT_DIR/${APO_TARGET_SLUG}-${irrelevant_origin}-audit.state"
done
apo_history_scan_retained_states
[[ $APO_HISTORY_SCANNED_STATES == 4 ]]
[[ $APO_HISTORY_ACCEPTED_STATES == 0 && $APO_HISTORY_EVIDENCE_COUNT == 0 ]]
[[ -z $APO_HISTORY_CPU_FAILURE_BOUNDARY$APO_HISTORY_GPU_FAILURE_BOUNDARY$APO_HISTORY_PAIR_FRONTIERS ]]

# Imported planning snapshots alone are not committed evidence.  Consuming
# retained history must not manufacture a new source that recursively
# propagates the same boundary into future runs.
APO_OUTPUT_DIR=$TMP/imported-only
mkdir -p -- "$APO_OUTPUT_DIR"
write_auto_state imported-only \
    STATUS RUNNING PHASE CPU_SWEEP TEST_VALID 0 \
    HISTORY_CPU_FAILURE_BOUNDARY 3000 HISTORY_GPU_FAILURE_BOUNDARY 1175 \
    HISTORY_PAIR_FRONTIERS 2975/1150 HISTORY_PROVENANCE inherited
apo_history_scan_retained_states
[[ $APO_HISTORY_SCANNED_STATES == 1 ]]
[[ $APO_HISTORY_ACCEPTED_STATES == 0 && $APO_HISTORY_EVIDENCE_COUNT == 0 ]]
[[ -z $APO_HISTORY_CPU_FAILURE_BOUNDARY$APO_HISTORY_GPU_FAILURE_BOUNDARY$APO_HISTORY_PAIR_FRONTIERS ]]

# Once a state contains committed evidence, damage anywhere in its payload is
# authoritative uncertainty and the complete strict loader must fail closed.
APO_OUTPUT_DIR=$TMP/evidence-damaged
mkdir -p -- "$APO_OUTPUT_DIR"
write_auto_state evidence-damaged \
    STATUS FAILED PHASE CPU_SWEEP TEST_VALID 1 CPU_FAILURE_BOUNDARY 3000
printf 'DAMAGED_UNRELATED\t%%%s\n' payload >> \
    "$APO_OUTPUT_DIR/${APO_TARGET_SLUG}-evidence-damaged.state"
if apo_history_scan_retained_states; then
    printf 'expected damaged evidence-bearing history to fail closed\n' >&2
    exit 1
fi
[[ $APO_HISTORY_SCAN_ERROR == *'evidence-damaged.state'* ]]
[[ -z $APO_HISTORY_CPU_FAILURE_BOUNDARY ]]

# Duplicate keys are rejected before validation instead of last-value-wins.
APO_OUTPUT_DIR=$TMP/duplicate
mkdir -p -- "$APO_OUTPUT_DIR"
write_auto_state duplicate CPU_FAILURE_BOUNDARY 3000
printf 'CPU_FAILURE_BOUNDARY\t%s\n' "$(apo_state_encode 3200)" >> "$APO_OUTPUT_DIR/${APO_TARGET_SLUG}-duplicate.state"
if apo_history_scan_retained_states; then
    printf 'expected duplicate-key history to fail closed\n' >&2
    exit 1
fi
[[ $APO_HISTORY_SCAN_ERROR == *'duplicate.state'* ]]

# The just-created state is never treated as retained history, even if it is
# incomplete while discovery is still filling it in.
APO_OUTPUT_DIR=$TMP/current
mkdir -p -- "$APO_OUTPUT_DIR"
write_state "$APO_OUTPUT_DIR/${APO_TARGET_SLUG}-current.state" \
    FORMAT_VERSION 1 RUN_SCHEMA "$APO_CURRENT_RUN_SCHEMA" RUN_ID current \
    REMOTE_TARGET "$APO_REMOTE_TARGET" TARGET_SLUG "$APO_TARGET_SLUG" \
    ORIGIN_COMMAND overclock READ_ONLY_RUN 0 CFG_AUTO_GENERATED_CANDIDATES 1 TEST_VALID 0
APO_STATE_FILE="$APO_OUTPUT_DIR/${APO_TARGET_SLUG}-current.state"
apo_history_scan_retained_states
[[ $APO_HISTORY_SCANNED_STATES == 0 ]]
unset APO_STATE_FILE

# Event recording is state-only and durable on the caller's next ordinary
# state save; free-form reasons cannot alter the record grammar.
APO_STATE=()
apo_state_set RUN_ID event-run
apo_history_record_failure_event PAIR 3000 1200 STABILITY_FAILURE $'line one\nline two | still data' final-endurance
event_history=$(apo_state_get HISTORY_FAILURE_EVENTS '')
[[ $event_history == v1\|*\|event-run\|3000\|1200\|STABILITY_FAILURE\|PAIR\|* ]]
[[ $event_history != *'line one'* ]]
if apo_history_record_failure_event CPU - - STABILITY_FAILURE bad invalid; then
    printf 'invalid failure event was accepted\n' >&2
    exit 1
fi

# Exclusive scalar ceilings are one 25 MHz step below the lowest clear
# failure, while an explicit tighter maximum remains authoritative.
APO_HISTORY_CPU_FAILURE_BOUNDARY=3100
APO_HISTORY_GPU_FAILURE_BOUNDARY=1200
apo_history_resolve_scalar_caps 3200 1150
[[ $APO_HISTORY_EFFECTIVE_CPU_MAX == 3075 ]]
[[ $APO_HISTORY_EFFECTIVE_GPU_MAX == 1150 ]]

# The ambiguous frontier forbids its northeast quadrant, not either scalar
# domain independently.
APO_HISTORY_PAIR_FRONTIERS='3000/1200,3100/1150'
apo_history_pair_is_forbidden 3100 1200
if apo_history_pair_is_forbidden 2975 1200; then
    printf 'pair below the ambiguous CPU coordinate was incorrectly forbidden\n' >&2
    exit 1
fi

# Plan validation accepts old schema-10 states with no history fields and a
# valid one-domain-at-a-time plan, but rejects a trial inside the frontier.
APO_STATE=()
apo_history_validate_plan_state
apo_state_set HISTORY_ISOLATION_STAGE PLANNED
apo_state_set HISTORY_PAIR_FRONTIERS '3000/1200'
apo_state_set HISTORY_ISOLATION_ANCHOR_CPU 3000
apo_state_set HISTORY_ISOLATION_ANCHOR_GPU 1200
apo_state_set HISTORY_CPU_TRIAL_CPU 2975
apo_state_set HISTORY_CPU_TRIAL_GPU 1200
apo_state_set HISTORY_GPU_TRIAL_CPU 3000
apo_state_set HISTORY_GPU_TRIAL_GPU 1175
apo_state_set HISTORY_PAIR_TRIAL_CPU 2975
apo_state_set HISTORY_PAIR_TRIAL_GPU 1175
apo_history_validate_plan_state
apo_state_set HISTORY_CPU_TRIAL_CPU 3000
if apo_history_validate_plan_state; then
    printf 'history plan accepted a forbidden CPU trial\n' >&2
    exit 1
fi

# Fresh planning keeps requested maxima separate, applies clear ceilings, and
# materializes an ambiguous-pair isolation plan before ladder generation.
refresh_calls=0
history_announcements=()
apo_info() { history_announcements+=("$1"); }
apo_summary_line() { :; }
apo_history_refresh() {
    refresh_calls=$((refresh_calls + 1))
    APO_HISTORY_CPU_FAILURE_BOUNDARY=''
    APO_HISTORY_GPU_FAILURE_BOUNDARY=''
    APO_HISTORY_PAIR_FRONTIERS='3100/1200'
    APO_HISTORY_PROVENANCE='PAIR|3100/1200|old-run|fixture|pi-one-old-run.state'
    APO_HISTORY_LEDGER_FILE="$TMP/planner-failures.txt"
    APO_HISTORY_SCANNED_STATES=1
    APO_HISTORY_ACCEPTED_STATES=1
    APO_HISTORY_EVIDENCE_COUNT=1
}
APO_STATE=()
APO_ORIGIN_COMMAND=overclock
APO_PUBLIC_COMMAND=overclock
APO_COMMAND=run
APO_AUTO_GENERATED_CANDIDATES=1
APO_SWEEP_DOMAIN=all
APO_USE_HISTORY=1
APO_AUTO_CPU_MAX_MHZ=3200
APO_AUTO_GPU_MAX_MHZ=1200
APO_CPU_MAX=''
APO_GPU_MAX=''
APO_CPU_MIN=''
APO_GPU_MIN=''
apo_history_resolve_new_overclock_plan
[[ $refresh_calls == 1 ]]
[[ -z $APO_CPU_MAX_REQUESTED && -z $APO_GPU_MAX_REQUESTED ]]
[[ $APO_CPU_MAX == 3200 && $APO_GPU_MAX == 1200 ]]
[[ $(apo_state_get HISTORY_ISOLATION_STAGE '') == PLANNED ]]
[[ $(apo_state_get HISTORY_CPU_TRIAL_CPU '') == 3075 ]]
[[ $(apo_state_get HISTORY_GPU_TRIAL_GPU '') == 1175 ]]
[[ $(apo_state_get HISTORY_PAIR_TRIAL_CPU '') == 3075 ]]
[[ $(apo_state_get HISTORY_PAIR_TRIAL_GPU '') == 1175 ]]
[[ ${#history_announcements[@]} == 1 ]]
[[ ${history_announcements[0]} == *'Retained-history plan: requested CPU max=3200 MHz, effective CPU max=3200 MHz; requested GPU max=1200 MHz, effective GPU max=1200 MHz'* ]]
# Discovery may be repeated after dependency/watchdog reconciliation.  The
# effective cap must not become the next call's requested cap.
apo_history_resolve_new_overclock_plan
[[ $refresh_calls == 2 ]]
[[ -z $APO_CPU_MAX_REQUESTED && -z $APO_GPU_MAX_REQUESTED ]]
[[ $APO_CPU_MAX == 3200 && $APO_GPU_MAX == 1200 ]]
[[ $(apo_state_get HISTORY_CPU_TRIAL_CPU '') == 3075 ]]
[[ $(apo_state_get HISTORY_GPU_TRIAL_GPU '') == 1175 ]]
[[ ${#history_announcements[@]} == 1 ]]

# Explicit opt-out is the only path that skips the scan and leaves a clean
# NONE plan while retaining explicit maxima.
APO_STATE=()
APO_USE_HISTORY=0
APO_HISTORY_PLAN_ANNOUNCED=0
history_announcements=()
unset APO_CPU_MAX_REQUESTED APO_GPU_MAX_REQUESTED
APO_CPU_MAX=3150
APO_GPU_MAX=1175
apo_history_resolve_new_overclock_plan
[[ $refresh_calls == 2 ]]
[[ $APO_CPU_MAX_REQUESTED == 3150 && $APO_GPU_MAX_REQUESTED == 1175 ]]
[[ $APO_CPU_MAX == 3150 && $APO_GPU_MAX == 1175 ]]
[[ $(apo_state_get HISTORY_ISOLATION_STAGE '') == NONE ]]
[[ ${#history_announcements[@]} == 1 ]]
[[ ${history_announcements[0]} == 'Retained history disabled for this new run: requested CPU max=3150 MHz, effective CPU max=3150 MHz; requested GPU max=1175 MHz, effective GPU max=1175 MHz.' ]]
apo_history_resolve_new_overclock_plan
[[ $refresh_calls == 2 ]]
[[ $APO_CPU_MAX_REQUESTED == 3150 && $APO_GPU_MAX_REQUESTED == 1175 ]]
[[ $APO_CPU_MAX == 3150 && $APO_GPU_MAX == 1175 ]]
[[ ${#history_announcements[@]} == 1 ]]

# A clear failure cap is also idempotent: a second discovery pass must derive
# 3075 again from the retained 3100 failure, not mistake 3075 for the user's
# originally requested maximum.
apo_history_refresh() {
    refresh_calls=$((refresh_calls + 1))
    APO_HISTORY_CPU_FAILURE_BOUNDARY=3100
    APO_HISTORY_GPU_FAILURE_BOUNDARY=''
    APO_HISTORY_PAIR_FRONTIERS=''
    APO_HISTORY_PROVENANCE='CPU|3100|old-run|fixture|pi-one-old-run.state'
    APO_HISTORY_LEDGER_FILE="$TMP/clear-boundary-failures.txt"
    APO_HISTORY_SCANNED_STATES=1
    APO_HISTORY_ACCEPTED_STATES=1
    APO_HISTORY_EVIDENCE_COUNT=1
}
APO_STATE=()
APO_USE_HISTORY=1
APO_HISTORY_PLAN_ANNOUNCED=0
history_announcements=()
unset APO_CPU_MAX_REQUESTED APO_GPU_MAX_REQUESTED
APO_CPU_MAX=''
APO_GPU_MAX=''
apo_history_resolve_new_overclock_plan
[[ $refresh_calls == 3 ]]
[[ -z $APO_CPU_MAX_REQUESTED && -z $APO_GPU_MAX_REQUESTED ]]
[[ $APO_CPU_MAX == 3075 && $APO_GPU_MAX == 1200 ]]
[[ ${#history_announcements[@]} == 1 ]]
[[ ${history_announcements[0]} == *'Retained-history plan: requested CPU max=3200 MHz, effective CPU max=3075 MHz; requested GPU max=1200 MHz, effective GPU max=1200 MHz'* ]]
[[ ${history_announcements[0]} == *'clear failed boundaries CPU=3100, GPU=none'* ]]
apo_history_resolve_new_overclock_plan
[[ $refresh_calls == 4 ]]
[[ -z $APO_CPU_MAX_REQUESTED && -z $APO_GPU_MAX_REQUESTED ]]
[[ $APO_CPU_MAX == 3075 && $APO_GPU_MAX == 1200 ]]
[[ ${#history_announcements[@]} == 1 ]]

# Neither an explicit resume nor the continuation selected by repeating the
# public overclock command may rescan or alter its already persisted plan.
APO_HISTORY_PLAN_ANNOUNCED=0
history_announcements=()
APO_COMMAND=resume
APO_PUBLIC_COMMAND=''
apo_history_resolve_new_overclock_plan
[[ $refresh_calls == 4 ]]
[[ ${#history_announcements[@]} == 0 && $APO_HISTORY_PLAN_ANNOUNCED == 0 ]]
APO_PUBLIC_COMMAND=overclock
apo_history_resolve_new_overclock_plan
[[ $refresh_calls == 4 ]]
[[ ${#history_announcements[@]} == 0 && $APO_HISTORY_PLAN_ANNOUNCED == 0 ]]

# One-domain plans name the inactive domain without appending a bogus unit.
APO_HISTORY_PLAN_ANNOUNCED=0
history_announcements=()
APO_COMMAND=run
APO_SWEEP_DOMAIN=gpu
APO_USE_HISTORY=0
unset APO_CPU_MAX_REQUESTED APO_GPU_MAX_REQUESTED
APO_CPU_MAX=''
APO_GPU_MAX=1175
apo_history_resolve_new_overclock_plan
[[ ${#history_announcements[@]} == 1 ]]
[[ ${history_announcements[0]} == *'requested CPU max=not swept, effective CPU max=not swept; requested GPU max=1175 MHz, effective GPU max=1175 MHz'* ]]
[[ ${history_announcements[0]} != *'not-swept MHz'* ]]

printf 'history tests passed\n'
