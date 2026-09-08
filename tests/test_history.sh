#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
APO_ROOT=$ROOT
source "$ROOT/lib/common.sh"
source "$ROOT/lib/state.sh"
source "$ROOT/lib/candidates.sh"
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
    local fixture_mode
    fixture_mode=$(apo_state_get TEST_VALID 0)
    if [[ $(apo_state_get APP_VERSION '') == 0.1.0-alpha.48 ]]; then
        [[ $fixture_mode == 1 ]] || return 1
        # The production scanner sets this only inside its screening subshell.
        # shellcheck disable=SC2031
        [[ ${APO_HISTORY_LEGACY_START_AT_SEMANTICS:-0} == 1 ]] || return 1
        APO_SELECTION_POLICY=$(apo_state_get CFG_SELECTION_POLICY)
        APO_SWEEP_DOMAIN=$(apo_state_get CFG_SWEEP_DOMAIN all)
        APO_NORMAL_CPU=$(apo_state_get NORMAL_CPU)
        APO_NORMAL_GPU=$(apo_state_get NORMAL_GPU)
        APO_AUTO_BASELINE_CPU=$(apo_state_get AUTO_BASELINE_CPU)
        APO_AUTO_BASELINE_GPU=$(apo_state_get AUTO_BASELINE_GPU)
        APO_CPU_MIN=$(apo_state_get CFG_CPU_START_AT '')
        APO_GPU_MIN=$(apo_state_get CFG_GPU_START_AT '')
        [[ -z $APO_CPU_MIN || $APO_CPU_MIN =~ ^[0-9]+$ ]] || return 1
        [[ -z $APO_GPU_MIN || $APO_GPU_MIN =~ ^[0-9]+$ ]] || return 1
        [[ $(apo_refined_domain_floor CPU) == "$APO_AUTO_BASELINE_CPU" ]]
        [[ $(apo_refined_domain_floor GPU) == "$APO_AUTO_BASELINE_GPU" ]]
        return
    fi
    [[ $fixture_mode == 1 ]]
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
old_schema_file="$APO_OUTPUT_DIR/${APO_TARGET_SLUG}-old-schema.state"
schema_seven_file="$APO_OUTPUT_DIR/${APO_TARGET_SLUG}-schema-seven.state"
schema_missing_file="$APO_OUTPUT_DIR/${APO_TARGET_SLUG}-schema-missing.state"
write_state "$old_schema_file" \
    FORMAT_VERSION 1 RUN_SCHEMA 9 RUN_ID old-schema \
    REMOTE_TARGET "$APO_REMOTE_TARGET" TARGET_SLUG "$APO_TARGET_SLUG" ORIGIN_COMMAND overclock \
    CPU_FAILURE_BOUNDARY 2400
# Real pre-current archives can lack metadata that did not exist when they were
# written.  Their schema excludes them before current FORMAT_VERSION and
# automatic-run fields are required, even if an old field resembles boundary
# evidence.
write_state "$schema_seven_file" \
    RUN_SCHEMA 7 RUN_ID schema-seven REMOTE_TARGET "$APO_REMOTE_TARGET" \
    CPU_FAILURE_BOUNDARY 2500
write_state "$schema_missing_file" \
    RUN_ID schema-missing REMOTE_TARGET "$APO_REMOTE_TARGET" \
    CPU_FAILURE_BOUNDARY 2600
old_schema_hash_before=$(sha256sum "$old_schema_file" | awk '{print $1}')
schema_seven_hash_before=$(sha256sum "$schema_seven_file" | awk '{print $1}')
schema_missing_hash_before=$(sha256sum "$schema_missing_file" | awk '{print $1}')
write_state "$APO_OUTPUT_DIR/${APO_TARGET_SLUG}-incompatible.state" \
    FORMAT_VERSION 1 RUN_SCHEMA "$APO_CURRENT_RUN_SCHEMA" RUN_ID incompatible \
    REMOTE_TARGET "$APO_REMOTE_TARGET" TARGET_SLUG "$APO_TARGET_SLUG" \
    ORIGIN_COMMAND overclock READ_ONLY_RUN 0 CFG_AUTO_GENERATED_CANDIDATES 1 \
    CFG_SELECTION_POLICY refined-max-25 PROFILE different TEST_VALID 1 CPU_FAILURE_BOUNDARY 2500

# The production definition was sourced above; focused fixture overrides appear
# later in this file for planner-only cases.
# shellcheck disable=SC2218
apo_history_refresh
[[ $APO_HISTORY_SCANNED_STATES == 10 ]]
[[ $APO_HISTORY_ACCEPTED_STATES == 4 ]]
[[ $APO_HISTORY_CPU_FAILURE_BOUNDARY == 2900 ]]
[[ $APO_HISTORY_GPU_FAILURE_BOUNDARY == 1150 ]]
[[ $APO_HISTORY_PAIR_FRONTIERS == '2975/1200,3000/1175' ]]
[[ $APO_HISTORY_EVIDENCE_COUNT == 11 ]]
[[ -f $old_schema_file && ! -L $old_schema_file ]]
[[ -f $schema_seven_file && ! -L $schema_seven_file ]]
[[ -f $schema_missing_file && ! -L $schema_missing_file ]]
[[ $(sha256sum "$old_schema_file" | awk '{print $1}') == "$old_schema_hash_before" ]]
[[ $(sha256sum "$schema_seven_file" | awk '{print $1}') == "$schema_seven_hash_before" ]]
[[ $(sha256sum "$schema_missing_file" | awk '{print $1}') == "$schema_missing_hash_before" ]]
[[ $APO_HISTORY_PROVENANCE == *'CPU|3000|run-b|CPU_FAILURE_BOUNDARY|'* ]]
[[ $APO_HISTORY_PROVENANCE == *'PAIR|2975/1200|run-c|FINAL_BACKOFF_TRIAL_CPU|'* ]]
[[ $APO_HISTORY_PROVENANCE != *'999'* ]]
[[ -f $APO_HISTORY_LEDGER_FILE && ! -L $APO_HISTORY_LEDGER_FILE ]]
grep -Fq 'Authority: validated .state files only; this ledger is derived output and never read as input.' "$APO_HISTORY_LEDGER_FILE"
grep -Fq 'Clear CPU failed boundary: 2900' "$APO_HISTORY_LEDGER_FILE"
grep -Fq 'Ambiguous failed-pair frontier: 2975/1200,3000/1175' "$APO_HISTORY_LEDGER_FILE"
grep -Fq '2026-09-07T03:00:00-0400 | run-d | 2900 | 1150 | STABILITY_FAILURE | CPU | Recovered exact CPU failure.' "$APO_HISTORY_LEDGER_FILE"
if grep -Fq '2026-09-07T03:05:00-0400 | run-d | 2850 | 1150 | STABILITY_FAILURE | PAIR | Recovered ambiguous pair failure.' "$APO_HISTORY_LEDGER_FILE"; then
    printf 'derived isolation journal was incorrectly reused as retained planning authority\n' >&2
    exit 1
fi

# Exact alpha.48/schema-10 automatic state shape: START_AT was a candidate
# seed, not a hard lower bound.  A later 3075 MHz backoff is therefore valid,
# and both its clear 3175 CPU boundary and ambiguous 3100/1200 pair remain
# usable retained evidence.  This compatibility is history-screening-only.
APO_OUTPUT_DIR=$TMP/legacy-alpha48
mkdir -p -- "$APO_OUTPUT_DIR"
write_auto_state alpha48-valid \
    APP_VERSION 0.1.0-alpha.48 \
    CFG_SWEEP_DOMAIN all CFG_CPU_START_AT 3100 CFG_GPU_START_AT 1150 \
    NORMAL_CPU 2400 NORMAL_GPU 960 AUTO_BASELINE_CPU 2400 AUTO_BASELINE_GPU 960 \
    CPU_FAILURE_BOUNDARY 3175 \
    FINAL_BACKOFF_HISTORY 'TRIAL_CPU:3100/1200>3075/1200' \
    FINAL_BACKOFF_CPU 3075 FINAL_BACKOFF_GPU 1200
apo_history_scan_retained_states
[[ $APO_HISTORY_SCANNED_STATES == 1 && $APO_HISTORY_ACCEPTED_STATES == 1 ]]
[[ $APO_HISTORY_CPU_FAILURE_BOUNDARY == 3175 ]]
[[ $APO_HISTORY_PAIR_FRONTIERS == 3100/1200 ]]
[[ $APO_HISTORY_PROVENANCE == *'CPU|3175|alpha48-valid|CPU_FAILURE_BOUNDARY|'* ]]
[[ $APO_HISTORY_PROVENANCE == *'PAIR|3100/1200|alpha48-valid|FINAL_BACKOFF_TRIAL_CPU|'* ]]

# The adapter recognizes a legacy shape; it does not waive strict validation.
# A malformed seed in the same alpha.48/schema-10 shape remains fatal.
APO_OUTPUT_DIR=$TMP/legacy-alpha48-malformed
mkdir -p -- "$APO_OUTPUT_DIR"
write_auto_state alpha48-malformed \
    APP_VERSION 0.1.0-alpha.48 \
    CFG_SWEEP_DOMAIN all CFG_CPU_START_AT not-a-clock CFG_GPU_START_AT 1150 \
    NORMAL_CPU 2400 NORMAL_GPU 960 AUTO_BASELINE_CPU 2400 AUTO_BASELINE_GPU 960 \
    CPU_FAILURE_BOUNDARY 3175
if apo_history_scan_retained_states; then
    printf 'malformed alpha.48 START_AT history was accepted\n' >&2
    exit 1
fi
[[ $APO_HISTORY_SCAN_ERROR == *'alpha48-malformed.state'* ]]
[[ -z $APO_HISTORY_CPU_FAILURE_BOUNDARY$APO_HISTORY_PAIR_FRONTIERS ]]

# Return to the primary fixture directory for the remaining scanner tests.
APO_OUTPUT_DIR=$TMP/good
# The production definition was sourced above; a planner-only fixture override
# appears later in this file.
# shellcheck disable=SC2218
apo_history_refresh

# Adaptive plans retain the established refined history record grammar.  Test
# that mapping in isolation so the legacy refined-max-25 scanner fixtures and
# their aggregate evidence counts above remain unchanged.
(
    APO_STATE=()
    apo_state_set CFG_SELECTION_POLICY adaptive-refined-v1
    apo_state_set FINAL_BACKOFF_HISTORY \
        'EXACT_CPU:3100/1175>3095/1175,EXACT_GPU:3095/1175>3095/1170,TRIAL_PAIR:3095/1170>3090/1169'
    adaptive_evidence=$(apo_history_emit_loaded_evidence adaptive-run adaptive.state)
    grep -Fxq 'CPU|3100|adaptive-run|FINAL_BACKOFF_EXACT_CPU|adaptive.state' <<< "$adaptive_evidence"
    grep -Fxq 'GPU|1175|adaptive-run|FINAL_BACKOFF_EXACT_GPU|adaptive.state' <<< "$adaptive_evidence"
    grep -Fxq 'PAIR|3095/1170|adaptive-run|FINAL_BACKOFF_TRIAL_PAIR|adaptive.state' <<< "$adaptive_evidence"
)

# A fresh plan still rescans authoritative states, but unchanged derived
# evidence must not replace or retimestamp the human-readable ledger.
scanned_states_before=$APO_HISTORY_SCANNED_STATES
write_state "$APO_OUTPUT_DIR/${APO_TARGET_SLUG}-later-reset.state" \
    FORMAT_VERSION 1 RUN_SCHEMA "$APO_CURRENT_RUN_SCHEMA" RUN_ID later-reset \
    REMOTE_TARGET "$APO_REMOTE_TARGET" TARGET_SLUG "$APO_TARGET_SLUG" ORIGIN_COMMAND reset
sed -i '2cGenerated: 2000-01-01T00:00:00+0000' "$APO_HISTORY_LEDGER_FILE"
touch -t 200001010000.00 "$APO_HISTORY_LEDGER_FILE"
ledger_hash_before=$(sha256sum "$APO_HISTORY_LEDGER_FILE" | awk '{print $1}')
ledger_inode_before=$(stat -c '%i' "$APO_HISTORY_LEDGER_FILE")
ledger_mtime_before=$(stat -c '%y' "$APO_HISTORY_LEDGER_FILE")
# shellcheck disable=SC2218
apo_history_refresh
[[ $APO_HISTORY_SCANNED_STATES == $((scanned_states_before + 1)) ]]
[[ $(sha256sum "$APO_HISTORY_LEDGER_FILE" | awk '{print $1}') == "$ledger_hash_before" ]]
[[ $(stat -c '%i' "$APO_HISTORY_LEDGER_FILE") == "$ledger_inode_before" ]]
[[ $(stat -c '%y' "$APO_HISTORY_LEDGER_FILE") == "$ledger_mtime_before" ]]
grep -Fxq 'Generated: 2000-01-01T00:00:00+0000' "$APO_HISTORY_LEDGER_FILE"

# The human file cannot authorize anything and is replaced from state.
printf 'CPU failed at 1 MHz\n' > "$APO_HISTORY_LEDGER_FILE"
# shellcheck disable=SC2218
apo_history_refresh
[[ $APO_HISTORY_CPU_FAILURE_BOUNDARY == 2900 ]]
if grep -Fq '1 MHz' "$APO_HISTORY_LEDGER_FILE"; then
    printf 'ledger text was incorrectly trusted as history input\n' >&2
    exit 1
fi

# New authoritative failure evidence refreshes an existing ledger, while a
# missing ledger is recreated from the complete retained-state scan.
touch -t 200001010000.00 "$APO_HISTORY_LEDGER_FILE"
ledger_inode_before=$(stat -c '%i' "$APO_HISTORY_LEDGER_FILE")
ledger_mtime_before=$(stat -c '%y' "$APO_HISTORY_LEDGER_FILE")
write_auto_state run-e STATUS FAILED PHASE CPU_SWEEP FAILURE_CLASS STABILITY_FAILURE CPU_FAILURE_BOUNDARY 2875
# shellcheck disable=SC2218
apo_history_refresh
[[ $APO_HISTORY_CPU_FAILURE_BOUNDARY == 2875 ]]
[[ $(stat -c '%i' "$APO_HISTORY_LEDGER_FILE") != "$ledger_inode_before" ]]
[[ $(stat -c '%y' "$APO_HISTORY_LEDGER_FILE") != "$ledger_mtime_before" ]]
if grep -Fxq 'Generated: 2000-01-01T00:00:00+0000' "$APO_HISTORY_LEDGER_FILE"; then
    printf 'changed history retained the previous ledger generation timestamp\n' >&2
    exit 1
fi
grep -Fq 'Clear CPU failed boundary: 2875' "$APO_HISTORY_LEDGER_FILE"
grep -Fq 'run-e' "$APO_HISTORY_LEDGER_FILE"
rm -f -- "$APO_HISTORY_LEDGER_FILE"
# shellcheck disable=SC2218
apo_history_refresh
[[ -f $APO_HISTORY_LEDGER_FILE && ! -L $APO_HISTORY_LEDGER_FILE ]]
grep -Fq 'Clear CPU failed boundary: 2875' "$APO_HISTORY_LEDGER_FILE"

# A generated audit path is never allowed to traverse or replace a symlink,
# directory, FIFO, or symlinked destination directory. Comparison errors also
# preserve the existing regular ledger instead of guessing that it changed.
ledger_safety_dir=$TMP/ledger-safety
mkdir -p -- "$ledger_safety_dir/real-parent"
printf 'keep-target\n' > "$ledger_safety_dir/target.txt"
ln -s target.txt "$ledger_safety_dir/file-link.txt"
ln -s missing.txt "$ledger_safety_dir/broken-link.txt"
mkdir "$ledger_safety_dir/directory.txt"
ln -s directory.txt "$ledger_safety_dir/directory-link.txt"
ln -s real-parent "$ledger_safety_dir/linked-parent"
mkfifo "$ledger_safety_dir/fifo.txt"
for refused_ledger in file-link.txt broken-link.txt directory.txt directory-link.txt fifo.txt; do
    if apo_history_rebuild_ledger "$ledger_safety_dir/$refused_ledger"; then
        printf 'unsafe ledger destination was accepted: %s\n' "$refused_ledger" >&2
        exit 1
    fi
done
if apo_history_rebuild_ledger "$ledger_safety_dir/linked-parent/failures.txt"; then
    printf 'symlinked ledger destination directory was accepted\n' >&2
    exit 1
fi
[[ -L $ledger_safety_dir/file-link.txt && $(<"$ledger_safety_dir/target.txt") == keep-target ]]
[[ -L $ledger_safety_dir/broken-link.txt && ! -e $ledger_safety_dir/broken-link.txt ]]
[[ -d $ledger_safety_dir/directory.txt && -L $ledger_safety_dir/directory-link.txt ]]
[[ -p $ledger_safety_dir/fifo.txt && ! -e $ledger_safety_dir/real-parent/failures.txt ]]

comparison_ledger=$ledger_safety_dir/comparison.txt
apo_history_rebuild_ledger "$comparison_ledger"
comparison_hash_before=$(sha256sum "$comparison_ledger" | awk '{print $1}')
comparison_inode_before=$(stat -c '%i' "$comparison_ledger")
cmp() { return 2; }
if apo_history_rebuild_ledger "$comparison_ledger"; then
    printf 'ledger comparison error was accepted as changed evidence\n' >&2
    exit 1
fi
unset -f cmp
[[ $(sha256sum "$comparison_ledger" | awk '{print $1}') == "$comparison_hash_before" ]]
[[ $(stat -c '%i' "$comparison_ledger") == "$comparison_inode_before" ]]

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

# A linked longer-final child saved before verified apply rollback remains
# resumable, but is not itself a fresh history authority.  Its source run owns
# the retained evidence until the child reaches an evidence-bearing stage.
APO_OUTPUT_DIR=$TMP/rollback-transition
mkdir -p -- "$APO_OUTPUT_DIR"
for transition_stage in ROLLBACK_PENDING ROLLBACK_COMPLETE; do
    run_id=$(printf '%s' "$transition_stage" | tr '[:upper:]_' '[:lower:]-')
    write_auto_state "$run_id" \
        POST_FLOOR_FINAL 1 POST_FLOOR_FINAL_STAGE "$transition_stage" \
        HISTORY_FAILURE_EVENTS "v1|2026-09-07T03:00:00-0400|${run_id}|3000|1200|STABILITY_FAILURE|PAIR|${event_source}|${ambiguous_reason}"
done
apo_history_scan_retained_states
[[ $APO_HISTORY_SCANNED_STATES == 2 ]]
[[ $APO_HISTORY_ACCEPTED_STATES == 0 ]]
[[ -z $APO_HISTORY_SCAN_ERROR ]]

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
APO_NORMAL_CPU=2400
APO_NORMAL_GPU=960
APO_HISTORY_CPU_FAILURE_BOUNDARY=3100
APO_HISTORY_GPU_FAILURE_BOUNDARY=1200
apo_history_resolve_scalar_caps 3200 1150
[[ $APO_HISTORY_EFFECTIVE_CPU_MAX == 3075 ]]
[[ $APO_HISTORY_EFFECTIVE_GPU_MAX == 1150 ]]

# Adaptive retained caps use each domain's configured resolution rather than
# silently falling back to the legacy 25 MHz refinement step.
APO_CPU_RESOLUTION_MHZ=5
APO_GPU_RESOLUTION_MHZ=1
apo_history_resolve_scalar_caps 3200 1200
[[ $APO_HISTORY_EFFECTIVE_CPU_MAX == 3095 ]]
[[ $APO_HISTORY_EFFECTIVE_GPU_MAX == 1199 ]]
[[ $APO_HISTORY_CPU_RETAINED_CAP == 3095 && $APO_HISTORY_GPU_RETAINED_CAP == 1199 ]]

# A user-selected resolution larger than a low retained boundary clamps at the
# first legal overclock rather than producing a negative arithmetic candidate.
APO_CPU_RESOLUTION_MHZ=1000
APO_GPU_RESOLUTION_MHZ=1000
APO_HISTORY_CPU_FAILURE_BOUNDARY=2500
APO_HISTORY_GPU_FAILURE_BOUNDARY=975
APO_CPU_MAX_OPTION_SEEN=0
APO_GPU_MAX_OPTION_SEEN=0
apo_history_resolve_scalar_caps 3200 1200
[[ $APO_HISTORY_EFFECTIVE_CPU_MAX == 2401 ]]
[[ $APO_HISTORY_EFFECTIVE_GPU_MAX == 961 ]]
APO_CPU_RESOLUTION_MHZ=25
APO_GPU_RESOLUTION_MHZ=25

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
apo_state_set CFG_CPU_MAX_EFFECTIVE 3200
apo_state_set CFG_GPU_MAX_EFFECTIVE 1200
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

# Every saved isolation clock is bounded by the effective maxima that produced
# the plan, and the pair branch must combine the exact two one-domain trials
# rather than silently jumping deeper.
apo_state_set HISTORY_CPU_TRIAL_CPU 2975
apo_state_set CFG_CPU_MAX_EFFECTIVE 2999
if apo_history_validate_plan_state; then
    printf 'history plan accepted an anchor above its persisted effective CPU maximum\n' >&2
    exit 1
fi
apo_state_set CFG_CPU_MAX_EFFECTIVE 3200
apo_state_set HISTORY_PAIR_TRIAL_CPU 2950
if apo_history_validate_plan_state; then
    printf 'history plan accepted a pair trial deeper than its CPU-only trial\n' >&2
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
APO_AUTO_CPU_STEP_MHZ=100
APO_AUTO_GPU_STEP_MHZ=50
APO_AUTO_REFINE_STEP_MHZ=25
APO_CPU_RESOLUTION_MHZ=5
APO_GPU_RESOLUTION_MHZ=1
APO_CPU_SEARCH_DIRECTION=forward
APO_GPU_SEARCH_DIRECTION=forward
APO_NORMAL_CPU=2400
APO_NORMAL_GPU=960
APO_CPU_MIN_OPTION_SEEN=0
APO_GPU_MIN_OPTION_SEEN=0
APO_CPU_MAX_OPTION_SEEN=0
APO_GPU_MAX_OPTION_SEEN=0
APO_CPU_MAX=''
APO_GPU_MAX=''
APO_CPU_MIN=''
APO_GPU_MIN=''
apo_history_resolve_new_overclock_plan
[[ $refresh_calls == 1 ]]
[[ -z $APO_CPU_MAX_REQUESTED && -z $APO_GPU_MAX_REQUESTED ]]
[[ $APO_CPU_MAX == 3200 && $APO_GPU_MAX == 1200 ]]
[[ $(apo_state_get HISTORY_ISOLATION_STAGE '') == PLANNED ]]
[[ $(apo_state_get HISTORY_CPU_TRIAL_CPU '') == 3095 ]]
[[ $(apo_state_get HISTORY_GPU_TRIAL_GPU '') == 1199 ]]
[[ $(apo_state_get HISTORY_PAIR_TRIAL_CPU '') == 3095 ]]
[[ $(apo_state_get HISTORY_PAIR_TRIAL_GPU '') == 1199 ]]
[[ -z $APO_CPU_MIN && -z $APO_GPU_MIN ]]
[[ $(apo_state_get CFG_CPU_MIN_SOURCE '') == automatic-baseline ]]
[[ $(apo_state_get CFG_GPU_MIN_SOURCE '') == automatic-baseline ]]
[[ $APO_CPU_SEARCH_DIRECTION == forward && $APO_GPU_SEARCH_DIRECTION == forward ]]
[[ -z $(apo_state_get HISTORY_CPU_APPROACH_START '') && -z $(apo_state_get HISTORY_GPU_APPROACH_START '') ]]
[[ $(apo_state_get HISTORY_CPU_REVERSE_SEARCH 1) == 0 && $(apo_state_get HISTORY_GPU_REVERSE_SEARCH 1) == 0 ]]
[[ ${#history_announcements[@]} == 4 ]]
[[ ${history_announcements[0]} == *'History ceilings: CPU=3200 MHz (requested 3200 MHz); GPU=1200 MHz (requested 1200 MHz).'* ]]
[[ ${history_announcements[1]} == 'CPU search: forward; start=forward baseline ladder; floor=2400 MHz; coarse step=100 MHz; final resolution=5 MHz.' ]]
[[ ${history_announcements[2]} == 'GPU search: forward; start=forward baseline ladder; floor=960 MHz; coarse step=50 MHz; final resolution=1 MHz.' ]]
# Discovery may be repeated after dependency/watchdog reconciliation.  The
# effective cap must not become the next call's requested cap.
apo_history_resolve_new_overclock_plan
[[ $refresh_calls == 2 ]]
[[ -z $APO_CPU_MAX_REQUESTED && -z $APO_GPU_MAX_REQUESTED ]]
[[ $APO_CPU_MAX == 3200 && $APO_GPU_MAX == 1200 ]]
[[ $(apo_state_get HISTORY_CPU_TRIAL_CPU '') == 3095 ]]
[[ $(apo_state_get HISTORY_GPU_TRIAL_GPU '') == 1199 ]]
[[ -z $APO_CPU_MIN && -z $APO_GPU_MIN ]]
[[ ${#history_announcements[@]} == 4 ]]

# With no explicit maxima, --no-history skips the scan and keeps the ordinary
# forward baseline ladders.
APO_STATE=()
APO_USE_HISTORY=0
APO_HISTORY_PLAN_ANNOUNCED=0
history_announcements=()
APO_CPU_SEARCH_DIRECTION=forward
APO_GPU_SEARCH_DIRECTION=forward
unset APO_CPU_MAX_REQUESTED APO_GPU_MAX_REQUESTED
APO_CPU_MAX=''
APO_GPU_MAX=''
apo_history_resolve_new_overclock_plan
[[ $refresh_calls == 2 ]]
[[ -z $APO_CPU_MAX_REQUESTED && -z $APO_GPU_MAX_REQUESTED ]]
[[ $APO_CPU_MAX == 3200 && $APO_GPU_MAX == 1200 ]]
[[ -z $APO_CPU_MIN && -z $APO_GPU_MIN ]]
[[ $(apo_state_get HISTORY_ISOLATION_STAGE '') == NONE ]]
[[ $APO_CPU_SEARCH_DIRECTION == forward && $APO_GPU_SEARCH_DIRECTION == forward ]]
[[ $(apo_state_get HISTORY_CPU_REVERSE_SEARCH 1) == 0 && $(apo_state_get HISTORY_GPU_REVERSE_SEARCH 1) == 0 ]]
[[ ${#history_announcements[@]} == 4 ]]
[[ ${history_announcements[0]} == 'History disabled for this new run. Ceilings: CPU=3200 MHz (requested 3200 MHz); GPU=1200 MHz (requested 1200 MHz).' ]]
[[ ${history_announcements[1]} == *'CPU search: forward; start=forward baseline ladder;'* ]]
[[ ${history_announcements[2]} == *'GPU search: forward; start=forward baseline ladder;'* ]]
apo_history_resolve_new_overclock_plan
[[ $refresh_calls == 2 ]]
[[ -z $APO_CPU_MAX_REQUESTED && -z $APO_GPU_MAX_REQUESTED ]]
[[ $APO_CPU_MAX == 3200 && $APO_GPU_MAX == 1200 ]]
[[ ${#history_announcements[@]} == 4 ]]

# --no-history does not cancel an explicit maximum: the exact user ceiling is
# still authoritative and is searched downward after an exact first attempt.
APO_STATE=()
APO_HISTORY_PLAN_ANNOUNCED=0
history_announcements=()
APO_CPU_MAX_OPTION_SEEN=1
APO_GPU_MAX_OPTION_SEEN=1
APO_CPU_SEARCH_DIRECTION=forward
APO_GPU_SEARCH_DIRECTION=forward
unset APO_CPU_MAX_REQUESTED APO_GPU_MAX_REQUESTED
APO_CPU_MAX=3173
APO_GPU_MAX=1187
apo_history_resolve_new_overclock_plan
[[ $refresh_calls == 2 ]]
[[ $APO_CPU_MAX_REQUESTED == 3173 && $APO_GPU_MAX_REQUESTED == 1187 ]]
[[ $APO_CPU_MAX == 3173 && $APO_GPU_MAX == 1187 ]]
[[ $APO_CPU_SEARCH_DIRECTION == descending && $APO_GPU_SEARCH_DIRECTION == descending ]]
[[ ${#history_announcements[@]} == 4 ]]
[[ ${history_announcements[1]} == *'CPU search: descending; start=3173 MHz exact ceiling first;'* ]]
[[ ${history_announcements[2]} == *'GPU search: descending; start=1187 MHz exact ceiling first;'* ]]
APO_CPU_MAX_OPTION_SEEN=0
APO_GPU_MAX_OPTION_SEEN=0

# A clear failure cap is also idempotent: a second discovery pass must derive
# 3095 again from the retained 3100 failure, not mistake 3095 for the user's
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
APO_CPU_SEARCH_DIRECTION=forward
APO_GPU_SEARCH_DIRECTION=forward
unset APO_CPU_MAX_REQUESTED APO_GPU_MAX_REQUESTED
APO_CPU_MAX=''
APO_GPU_MAX=''
apo_history_resolve_new_overclock_plan
[[ $refresh_calls == 3 ]]
[[ -z $APO_CPU_MAX_REQUESTED && -z $APO_GPU_MAX_REQUESTED ]]
[[ $APO_CPU_MAX == 3095 && $APO_GPU_MAX == 1200 ]]
[[ -z $APO_CPU_MIN && -z $APO_GPU_MIN ]]
[[ $(apo_state_get CFG_CPU_MIN_SOURCE '') == automatic-baseline ]]
[[ $(apo_state_get CFG_GPU_MIN_SOURCE '') == automatic-baseline ]]
[[ $APO_CPU_SEARCH_DIRECTION == descending && $APO_GPU_SEARCH_DIRECTION == forward ]]
[[ $(apo_state_get HISTORY_CPU_APPROACH_START '') == 3095 && -z $(apo_state_get HISTORY_GPU_APPROACH_START '') ]]
[[ ${#history_announcements[@]} == 4 ]]
[[ ${history_announcements[0]} == *'History ceilings: CPU=3095 MHz (requested 3200 MHz); GPU=1200 MHz (requested 1200 MHz).'* ]]
[[ ${history_announcements[0]} == *'Retained failures: clear CPU=3100, clear GPU=none'* ]]
[[ ${history_announcements[1]} == *'CPU search: descending; start=3095 MHz exact ceiling first;'* ]]
[[ ${history_announcements[2]} == *'GPU search: forward; start=forward baseline ladder;'* ]]
apo_history_resolve_new_overclock_plan
[[ $refresh_calls == 4 ]]
[[ -z $APO_CPU_MAX_REQUESTED && -z $APO_GPU_MAX_REQUESTED ]]
[[ $APO_CPU_MAX == 3095 && $APO_GPU_MAX == 1200 ]]
[[ -z $APO_CPU_MIN && -z $APO_GPU_MIN ]]
[[ ${#history_announcements[@]} == 4 ]]

# Resume must use its already persisted plan and never rescan retained history,
# even when the saved public-command marker identifies an overclock run.
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

# A history-enabled one-domain run must leave the held domain completely
# unbounded while applying the relevant retained cap and near-ceiling start.
apo_history_refresh() {
    refresh_calls=$((refresh_calls + 1))
    APO_HISTORY_CPU_FAILURE_BOUNDARY=3200
    APO_HISTORY_GPU_FAILURE_BOUNDARY=1200
    APO_HISTORY_PAIR_FRONTIERS=''
    APO_HISTORY_PROVENANCE='CPU|3200|old-run|fixture|cpu.state,GPU|1200|old-run|fixture|gpu.state'
    APO_HISTORY_LEDGER_FILE="$TMP/one-domain-failures.txt"
    APO_HISTORY_SCANNED_STATES=2
    APO_HISTORY_ACCEPTED_STATES=2
    APO_HISTORY_EVIDENCE_COUNT=2
}
APO_COMMAND=run
APO_SWEEP_DOMAIN=gpu
APO_USE_HISTORY=1
APO_HISTORY_PLAN_ANNOUNCED=0
history_announcements=()
APO_CPU_SEARCH_DIRECTION=forward
APO_GPU_SEARCH_DIRECTION=forward
APO_NORMAL_CPU=2950
APO_NORMAL_GPU=1125
unset APO_CPU_MAX_REQUESTED APO_GPU_MAX_REQUESTED
APO_CPU_MIN=2975
APO_GPU_MIN=''
APO_CPU_MAX=''
APO_GPU_MAX=''
apo_history_resolve_new_overclock_plan
[[ $refresh_calls == 5 ]]
[[ -z $APO_CPU_MIN && -z $APO_CPU_MAX ]]
[[ -z $APO_GPU_MIN && $APO_GPU_MAX == 1199 ]]
[[ $(apo_state_get CFG_CPU_MIN_SOURCE '') == automatic-baseline ]]
[[ $(apo_state_get CFG_GPU_MIN_SOURCE '') == automatic-baseline ]]
[[ -z $(apo_state_get CFG_CPU_MAX_EFFECTIVE '') ]]
[[ $(apo_state_get CFG_GPU_MAX_EFFECTIVE '') == 1199 ]]
[[ $APO_CPU_SEARCH_DIRECTION == forward && $APO_GPU_SEARCH_DIRECTION == descending ]]
[[ $(apo_state_get HISTORY_GPU_APPROACH_START '') == 1199 ]]
[[ ${#history_announcements[@]} == 3 ]]
[[ ${history_announcements[0]} == *'CPU=not swept (requested not swept); GPU=1199 MHz (requested 1200 MHz)'* ]]
[[ ${history_announcements[1]} == *'GPU search: descending; start=1199 MHz exact ceiling first;'* ]]

APO_SWEEP_DOMAIN=cpu
APO_HISTORY_PLAN_ANNOUNCED=0
history_announcements=()
APO_CPU_SEARCH_DIRECTION=forward
APO_GPU_SEARCH_DIRECTION=forward
APO_NORMAL_CPU=2950
APO_NORMAL_GPU=1125
unset APO_CPU_MAX_REQUESTED APO_GPU_MAX_REQUESTED
APO_CPU_MIN=''
APO_GPU_MIN=1150
APO_CPU_MAX=''
APO_GPU_MAX=''
apo_history_resolve_new_overclock_plan
[[ $refresh_calls == 6 ]]
[[ -z $APO_CPU_MIN && $APO_CPU_MAX == 3195 ]]
[[ -z $APO_GPU_MIN && -z $APO_GPU_MAX ]]
[[ $(apo_state_get CFG_CPU_MIN_SOURCE '') == automatic-baseline ]]
[[ $(apo_state_get CFG_GPU_MIN_SOURCE '') == automatic-baseline ]]
[[ $(apo_state_get CFG_CPU_MAX_EFFECTIVE '') == 3195 ]]
[[ -z $(apo_state_get CFG_GPU_MAX_EFFECTIVE '') ]]
[[ $APO_CPU_SEARCH_DIRECTION == descending && $APO_GPU_SEARCH_DIRECTION == forward ]]
[[ $(apo_state_get HISTORY_CPU_APPROACH_START '') == 3195 ]]
[[ ${#history_announcements[@]} == 3 ]]
[[ ${history_announcements[0]} == *'CPU=3195 MHz (requested 3200 MHz); GPU=not swept (requested not swept)'* ]]
[[ ${history_announcements[1]} == *'CPU search: descending; start=3195 MHz exact ceiling first;'* ]]

# One-domain plans name the inactive domain without appending a bogus unit.
APO_HISTORY_PLAN_ANNOUNCED=0
history_announcements=()
APO_COMMAND=run
APO_SWEEP_DOMAIN=gpu
APO_USE_HISTORY=0
APO_CPU_SEARCH_DIRECTION=forward
APO_GPU_SEARCH_DIRECTION=forward
unset APO_CPU_MAX_REQUESTED APO_GPU_MAX_REQUESTED
APO_CPU_MAX=''
APO_GPU_MAX=''
apo_history_resolve_new_overclock_plan
[[ $APO_CPU_SEARCH_DIRECTION == forward && $APO_GPU_SEARCH_DIRECTION == forward ]]
[[ ${#history_announcements[@]} == 3 ]]
[[ ${history_announcements[0]} == *'Ceilings: CPU=not swept (requested not swept); GPU=1200 MHz (requested 1200 MHz)'* ]]
[[ ${history_announcements[0]} != *'not-swept MHz'* ]]
[[ ${history_announcements[1]} == *'GPU search: forward; start=forward baseline ladder;'* ]]

# Timestamp generation is explicitly checked even though the production call
# chain suppresses errexit while reporting a failed history plan. A clock-tool
# failure must preserve an existing ledger and leave an absent path absent.
timestamp_failure_existing=$ledger_safety_dir/timestamp-existing.txt
timestamp_failure_missing=$ledger_safety_dir/timestamp-missing.txt
cp -- "$comparison_ledger" "$timestamp_failure_existing"
timestamp_failure_hash=$(sha256sum "$timestamp_failure_existing" | awk '{print $1}')
apo_now_iso() { return 1; }
if apo_history_rebuild_ledger "$timestamp_failure_existing"; then
    printf 'failed timestamp generation was accepted for an existing ledger\n' >&2
    exit 1
fi
[[ $(sha256sum "$timestamp_failure_existing" | awk '{print $1}') == "$timestamp_failure_hash" ]]
if apo_history_rebuild_ledger "$timestamp_failure_missing"; then
    printf 'failed timestamp generation was accepted for a missing ledger\n' >&2
    exit 1
fi
[[ ! -e $timestamp_failure_missing && ! -L $timestamp_failure_missing ]]
if find "$ledger_safety_dir" -maxdepth 1 -type f -name ".${APO_TARGET_SLUG}-failures.*" | grep -q .; then
    printf 'failed timestamp generation left a temporary ledger behind\n' >&2
    exit 1
fi

printf 'history tests passed\n'
