#!/usr/bin/env bash
# Independent fixture subshells intentionally reuse controller variable names.
# shellcheck disable=SC2030,SC2031
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
APO_ROOT=$ROOT
source "$ROOT/lib/common.sh"
source "$ROOT/lib/state.sh"
source "$ROOT/lib/recovery.sh"
apo_state_load "$ROOT/tests/fixtures/interrupted-tryboot.state"
[[ $(apo_state_get STATUS) == INTERRUPTED ]]
[[ $(apo_state_get TRYBOOT_EXPECTED) == 1 ]]
[[ $(apo_state_get PHASE) == GPU_SMOKE ]]

apo_state_save() { :; }
apo_event() { :; }
apo_ensure_worker_for_boot() { return 0; }
apo_post_reboot_handshake() {
    APO_REBOOT_HANDSHAKE_STAGE='wait'
    APO_REBOOT_BOOT_ID=$(apo_wait_for_new_boot "$1" "$2" || true)
    [[ -n $APO_REBOOT_BOOT_ID && $APO_REBOOT_BOOT_ID != "$1" ]] || return 1
    APO_REBOOT_HANDSHAKE_STAGE='complete'
}

reset_recovery_fixture() {
    APO_STATE=()
    apo_state_set TRYBOOT_EXPECTED 0
    apo_state_set CURRENT_CPU ''
    apo_state_set CURRENT_GPU ''
    apo_state_set LAST_BOOT_ID ''
    apo_state_set NORMAL_BOOT_ID ''
    apo_state_set CANDIDATE_BOOT_ID ''
    apo_state_set TRANSIENT_RETRY_CONTEXT ''
    apo_state_set TRANSIENT_RETRY_COUNT 0
    APO_BOOT_TIMEOUT=300
    APO_BOOT_SETTLE_SECONDS=0
    APO_NORMAL_CPU=2400
    APO_NORMAL_GPU=800
    APO_NORMAL_VOLTAGE=0
    APO_TEST_VOLTAGE=0
    APO_BOOT_CONFIG=/boot/config.txt
    APO_TRYBOOT_CONFIG=/boot/tryboot.txt
    APO_PERMANENT_CONFIG_HASH=$(printf 'd%.0s' {1..64})
    APO_RUN_ID=interrupted-fixture
    APO_REMOTE_WORKER=/tmp/fixture-worker
    APO_LAST_CLASS=''
    APO_LAST_REASON=''
    APO_RECOVERY_IN_PROGRESS=0
    APO_RECOVERY_UNEXPECTED_CANDIDATE_REBOOT=0
    APO_RECOVERY_UNEXPECTED_REBOOT_FROM=''
    APO_RECOVERY_UNEXPECTED_REBOOT_TO=''
}

# The exit handler is the last recovery boundary after a signal or an error
# inside recovery itself. Its traps are already disabled, so an in-progress
# flag must not suppress the one final bounded attempt for staged/live tryboot.
# Extract only the function to exercise the real controller implementation
# without dispatching main.
eval "$(sed -n '/^apo_cleanup_handler()/,/^}/p' "$ROOT/autopioverclock")"
apo_remote_tryboot_flag_once() { apo_remote_tryboot_flag; }
EXIT_RECOVERY_MARKER=$(mktemp)
set +e
(
    reset_recovery_fixture
    APO_HAVE_REMOTE_CONTEXT=1
    APO_MUTATING_COMMAND=1
    APO_WORKER_DEPLOYED=0
    # The handler is intentionally isolated in this subshell.
    # shellcheck disable=SC2030
    APO_RECOVERY_IN_PROGRESS=1
    APO_STATE_FILE=''
    APO_JSONL_FILE=''
    apo_state_set TRYBOOT_EXPECTED 1
    apo_state_set TRYBOOT_FILE_MAY_EXIST 1
    apo_state_set TRYBOOT_OWNED_HASH "$(printf 'a%.0s' {1..64})"
    apo_state_set TRYBOOT_RESERVATION_HASH "$(printf 'b%.0s' {1..64})"
    apo_state_set TRYBOOT_OWNERSHIP_TOKEN "$(printf 'c%.0s' {1..64})"
    apo_state_set TRYBOOT_QUARANTINE_PATH "/boot/.autopioverclock-remove-$(printf 'c%.0s' {1..64})"
    apo_remote_tryboot_flag() { printf 00000001; }
    apo_warn_plain() { :; }
    apo_recover_normal() {
        [[ $1 == exit-trap-recovery && $APO_RECOVERY_IN_PROGRESS == 1 ]]
        printf 'called\n' > "$EXIT_RECOVERY_MARKER"
    }
    set +e
    (exit 143)
    apo_cleanup_handler
)

EXIT_HANDLER_RC=$?
set -e
[[ $EXIT_HANDLER_RC == 143 ]]
[[ $(<"$EXIT_RECOVERY_MARKER") == called ]]
rm -f -- "$EXIT_RECOVERY_MARKER"

# A candidate that was observed on a distinct tryboot boot and then vanished
# during its boot/health handoff is a boot boundary only after recovery proves
# a later clear normal boot, exact ownership cleanup, and normal health.
(
    reset_recovery_fixture
    apo_state_set TRYBOOT_EXPECTED 1
    apo_state_set LAST_BOOT_ID candidate-boot-handoff
    apo_state_set CANDIDATE_BOOT_ID candidate-boot-handoff
    apo_state_set CANDIDATE_STAGE STRESS_BOOT
    apo_wait_for_ssh() { return 0; }
    apo_remote_boot_id() { printf candidate-boot-normal; }
    apo_remote_tryboot_flag() { printf 00000000; }
    apo_remote_worker() { return 1; }
    apo_health_check() { return 0; }
    apo_recover_observed_phase_failure boot-handoff-recovery HARNESS_FAILURE 'The worker failed without a structured result.' 1 candidate-boot BOOT_FAILURE 'candidate boot or required boot health'
    [[ $APO_RECOVERY_UNEXPECTED_CANDIDATE_REBOOT == 1 ]]
    [[ $APO_LAST_CLASS == BOOT_FAILURE ]]
    [[ $APO_LAST_REASON == *'during candidate boot or required boot health'* ]]
    [[ $APO_LAST_REASON == *'candidate-boot-handoff to verified normal boot candidate-boot-normal'* ]]
)

# If the same candidate boot is still alive, transport loss is not rewritten
# as a clock boundary. It receives five bounded automatic gate retries instead
# of immediately terminating or looping forever.
(
    reset_recovery_fixture
    apo_state_set TRYBOOT_EXPECTED 1
    apo_state_set LAST_BOOT_ID same-boot-handoff
    apo_state_set CANDIDATE_BOOT_ID same-boot-handoff
    apo_state_set CANDIDATE_STAGE STRESS_BOOT
    CURRENT_BOOT_ID=same-boot-handoff
    apo_wait_for_ssh() { return 0; }
    apo_remote_boot_id() { printf '%s' "$CURRENT_BOOT_ID"; }
    apo_remote_tryboot_flag() { [[ $CURRENT_BOOT_ID == same-boot-handoff ]] && printf 00000001 || printf 00000000; }
    apo_remote_worker() { CURRENT_BOOT_ID=same-boot-normal; }
    apo_wait_for_new_boot() { printf '%s' "$CURRENT_BOOT_ID"; }
    apo_health_check() { return 0; }
    apo_recover_observed_phase_failure same-boot-handoff-recovery HARNESS_FAILURE 'The worker failed without a structured result.' 1 candidate-boot BOOT_FAILURE 'candidate boot or required boot health'
    [[ $APO_RECOVERY_UNEXPECTED_CANDIDATE_REBOOT == 0 ]]
    [[ $APO_LAST_CLASS == HARNESS_FAILURE ]]
    for retry_number in 1 2 3 4 5; do
        apo_transient_phase_retry_schedule candidate-handoff "$APO_LAST_CLASS" "$APO_LAST_REASON" 1
        [[ $(apo_state_get TRANSIENT_RETRY_COUNT) == "$retry_number" ]]
    done
    if apo_transient_phase_retry_schedule candidate-handoff "$APO_LAST_CLASS" "$APO_LAST_REASON" 1; then
        echo 'automatic transport retry exceeded its bounded limit' >&2
        exit 1
    fi
    [[ $(apo_state_get TRANSIENT_RETRY_COUNT) == 5 ]]
)

# An already-normal target uses the complete profile timeout and records its
# current boot ID instead of leaving stale candidate/recovery state behind.
reset_recovery_fixture
WAIT_TIMEOUT=''
apo_wait_for_ssh() { WAIT_TIMEOUT=$1; return 0; }
apo_remote_tryboot_flag() { printf 00000000; }
apo_remote_boot_id() { printf already-normal-boot; }
apo_health_check() { APO_LAST_CLASS=PASS; APO_LAST_REASON='normal health passed'; return 0; }
# The sourced implementation is intentionally replaced by fixtures later.
# shellcheck disable=SC2218
apo_return_normal already-normal-fixture
[[ $WAIT_TIMEOUT == 300 ]]
[[ $(apo_state_get NORMAL_BOOT_ID) == already-normal-boot ]]
[[ $(apo_state_get LAST_BOOT_ID) == already-normal-boot ]]
[[ $(apo_state_get TRYBOOT_EXPECTED) == 0 ]]
# The earlier handler fixture intentionally ran in a subshell.
# shellcheck disable=SC2031
[[ $APO_RECOVERY_IN_PROGRESS == 0 ]]
[[ $APO_RECOVERY_UNEXPECTED_CANDIDATE_REBOOT == 0 ]]

# Observation is an explicit, fail-closed recovery scope rather than a boolean
# that a future caller could accidentally enable outside a stress checkpoint.
(
    reset_recovery_fixture
    WAIT_FOR_SSH_CALLS=0
    apo_wait_for_ssh() { WAIT_FOR_SSH_CALLS=$((WAIT_FOR_SSH_CALLS + 1)); }
    if apo_return_normal malformed-stress-scope 0 unexpected; then
        echo 'malformed stress-reboot scope was accepted' >&2
        exit 1
    fi
    [[ $WAIT_FOR_SSH_CALLS == 0 ]]
    [[ $APO_LAST_CLASS == RECOVERY_FAILURE ]]
)
(
    reset_recovery_fixture
    APO_PROFILE=batocera
    APO_MODE_EFFECTIVE=graphical
    WAIT_FOR_SSH_CALLS=0
    apo_wait_for_ssh() { WAIT_FOR_SSH_CALLS=$((WAIT_FOR_SSH_CALLS + 1)); }
    if apo_return_normal forced-observation-conflict 1 candidate; then
        echo 'forced reboot and stress-reboot observation were combined' >&2
        exit 1
    fi
    [[ $WAIT_FOR_SSH_CALLS == 0 ]]
    [[ $APO_LAST_CLASS == RECOVERY_FAILURE ]]
)

# If recovery's first observation finds that the saved candidate boot already
# changed to a clear normal boot, expose that uncommanded reboot as evidence.
# The caller decides whether the original stress failure is eligible for
# promotion; recovery itself remains classification-neutral.
(
    reset_recovery_fixture
    apo_state_set TRYBOOT_EXPECTED 1
    apo_state_set LAST_BOOT_ID candidate-stress-boot
    apo_state_set CANDIDATE_BOOT_ID candidate-stress-boot
    apo_state_set CANDIDATE_STAGE STRESS
    apo_state_set CURRENT_CPU 3200
    apo_state_set CURRENT_GPU 960
    REBOOT_NORMAL_CALLS=0
    apo_wait_for_ssh() { return 0; }
    apo_remote_boot_id() { printf watchdog-normal-boot; }
    apo_remote_tryboot_flag() { printf 00000000; }
    apo_remote_worker() { REBOOT_NORMAL_CALLS=$((REBOOT_NORMAL_CALLS + 1)); }
    apo_health_check() { return 0; }
    apo_recover_stress_failure unexpected-candidate-reboot-fixture HARNESS_FAILURE 'The worker failed without a structured result.' 0 candidate
    [[ $REBOOT_NORMAL_CALLS == 0 ]]
    [[ $APO_RECOVERY_UNEXPECTED_CANDIDATE_REBOOT == 1 ]]
    [[ $APO_RECOVERY_UNEXPECTED_REBOOT_FROM == candidate-stress-boot ]]
    [[ $APO_RECOVERY_UNEXPECTED_REBOOT_TO == watchdog-normal-boot ]]
    [[ $(apo_state_get NORMAL_BOOT_ID) == watchdog-normal-boot ]]
    [[ $APO_LAST_CLASS == STABILITY_FAILURE ]]
    [[ $APO_LAST_REASON == *'rebooted unexpectedly from boot candidate-stress-boot to verified normal boot watchdog-normal-boot'* ]]
)

# Even the same autonomous reboot proof cannot turn a worker-emitted,
# structured harness diagnosis into silicon evidence.
(
    reset_recovery_fixture
    apo_state_set TRYBOOT_EXPECTED 1
    apo_state_set LAST_BOOT_ID structured-candidate-boot
    apo_state_set CANDIDATE_BOOT_ID structured-candidate-boot
    apo_state_set CANDIDATE_STAGE STRESS
    REBOOT_NORMAL_CALLS=0
    apo_wait_for_ssh() { return 0; }
    apo_remote_boot_id() { printf structured-normal-boot; }
    apo_remote_tryboot_flag() { printf 00000000; }
    apo_remote_worker() { REBOOT_NORMAL_CALLS=$((REBOOT_NORMAL_CALLS + 1)); }
    apo_health_check() { return 0; }
    apo_recover_stress_failure structured-harness-reboot-fixture HARNESS_FAILURE 'The worker failed without a structured result.' 1 candidate
    [[ $REBOOT_NORMAL_CALLS == 0 ]]
    [[ $APO_RECOVERY_UNEXPECTED_CANDIDATE_REBOOT == 1 ]]
    [[ $APO_LAST_CLASS == HARNESS_FAILURE ]]
    [[ $APO_LAST_REASON == 'The worker failed without a structured result.' ]]
)

# An unstructured worker failure with a different reason also remains its
# original classification even when the reboot proof itself is complete.
(
    reset_recovery_fixture
    apo_state_set TRYBOOT_EXPECTED 1
    apo_state_set LAST_BOOT_ID reason-candidate-boot
    apo_state_set CANDIDATE_BOOT_ID reason-candidate-boot
    apo_state_set CANDIDATE_STAGE STRESS
    apo_wait_for_ssh() { return 0; }
    apo_remote_boot_id() { printf reason-normal-boot; }
    apo_remote_tryboot_flag() { printf 00000000; }
    apo_remote_worker() { return 1; }
    apo_health_check() { return 0; }
    apo_recover_stress_failure different-reason-reboot-fixture HARNESS_FAILURE 'different unstructured harness reason' 0 candidate
    [[ $APO_RECOVERY_UNEXPECTED_CANDIDATE_REBOOT == 1 ]]
    [[ $APO_LAST_CLASS == HARNESS_FAILURE ]]
    [[ $APO_LAST_REASON == 'different unstructured harness reason' ]]
)

# The narrow promotion is class-specific; an otherwise identical non-harness
# diagnosis is not rewritten by this fallback-only recovery rule.
(
    reset_recovery_fixture
    apo_state_set TRYBOOT_EXPECTED 1
    apo_state_set LAST_BOOT_ID class-candidate-boot
    apo_state_set CANDIDATE_BOOT_ID class-candidate-boot
    apo_state_set CANDIDATE_STAGE STRESS
    apo_wait_for_ssh() { return 0; }
    apo_remote_boot_id() { printf class-normal-boot; }
    apo_remote_tryboot_flag() { printf 00000000; }
    apo_remote_worker() { return 1; }
    apo_health_check() { return 0; }
    apo_recover_stress_failure different-class-reboot-fixture BOOT_FAILURE 'The worker failed without a structured result.' 0 candidate
    [[ $APO_RECOVERY_UNEXPECTED_CANDIDATE_REBOOT == 1 ]]
    [[ $APO_LAST_CLASS == BOOT_FAILURE ]]
)

# A same-boot SSH interruption does not become a silicon boundary. Recovery
# must issue the normal reboot itself, and the original harness uncertainty is
# preserved even though the target subsequently recovers.
(
    reset_recovery_fixture
    apo_state_set TRYBOOT_EXPECTED 1
    apo_state_set LAST_BOOT_ID candidate-stress-boot
    apo_state_set CANDIDATE_BOOT_ID candidate-stress-boot
    apo_state_set CANDIDATE_STAGE STRESS
    CURRENT_BOOT_ID=candidate-stress-boot
    REBOOT_NORMAL_CALLS=0
    apo_wait_for_ssh() { return 0; }
    apo_remote_boot_id() { printf '%s' "$CURRENT_BOOT_ID"; }
    apo_remote_tryboot_flag() { [[ $CURRENT_BOOT_ID == candidate-stress-boot ]] && printf 00000001 || printf 00000000; }
    apo_remote_worker() { REBOOT_NORMAL_CALLS=$((REBOOT_NORMAL_CALLS + 1)); CURRENT_BOOT_ID=controller-normal-boot; }
    apo_wait_for_new_boot() { printf '%s' "$CURRENT_BOOT_ID"; }
    apo_health_check() { return 0; }
    apo_recover_stress_failure same-boot-transport-fixture HARNESS_FAILURE 'The worker failed without a structured result.' 0 candidate
    [[ $REBOOT_NORMAL_CALLS == 1 ]]
    [[ $APO_RECOVERY_UNEXPECTED_CANDIDATE_REBOOT == 0 ]]
    [[ $APO_LAST_CLASS == HARNESS_FAILURE ]]
    [[ $APO_LAST_REASON == 'The worker failed without a structured result.' ]]
)

# Exact boot IDs and a clear normal boot are not enough by themselves. Missing
# saved stage, tryboot expectation, or candidate-boot identity must fail closed
# as transport uncertainty rather than becoming a clock-stability boundary.
for missing_proof in active-stage tryboot-expectation pending-boot-id changed-boot-id clear-tryboot candidate-boot-id; do
    (
        reset_recovery_fixture
        apo_state_set TRYBOOT_EXPECTED 1
        apo_state_set LAST_BOOT_ID candidate-proof-boot
        apo_state_set CANDIDATE_BOOT_ID candidate-proof-boot
        apo_state_set CANDIDATE_STAGE STRESS
        CURRENT_BOOT_ID=proof-normal-boot
        TRYBOOT_FLAG=00000000
        case $missing_proof in
            active-stage) apo_state_set CANDIDATE_STAGE POST_STRESS_HEALTH ;;
            tryboot-expectation) apo_state_set TRYBOOT_EXPECTED 0 ;;
            pending-boot-id) apo_state_set LAST_BOOT_ID '' ;;
            changed-boot-id) CURRENT_BOOT_ID=candidate-proof-boot ;;
            clear-tryboot) TRYBOOT_FLAG=00000001 ;;
            candidate-boot-id) apo_state_set CANDIDATE_BOOT_ID different-candidate-boot ;;
        esac
        REBOOT_NORMAL_CALLS=0
        apo_wait_for_ssh() { return 0; }
        apo_remote_boot_id() { printf '%s' "$CURRENT_BOOT_ID"; }
        apo_remote_tryboot_flag() { printf '%s' "$TRYBOOT_FLAG"; }
        apo_remote_worker() {
            REBOOT_NORMAL_CALLS=$((REBOOT_NORMAL_CALLS + 1))
            CURRENT_BOOT_ID=controller-normal-boot
            TRYBOOT_FLAG=00000000
        }
        apo_wait_for_new_boot() { printf '%s' "$CURRENT_BOOT_ID"; }
        apo_health_check() { return 0; }
        apo_recover_stress_failure "missing-${missing_proof}-fixture" HARNESS_FAILURE 'The worker failed without a structured result.' 0 candidate
        case $missing_proof in
            pending-boot-id|changed-boot-id|clear-tryboot) [[ $REBOOT_NORMAL_CALLS == 1 ]] ;;
            *) [[ $REBOOT_NORMAL_CALLS == 0 ]] ;;
        esac
        [[ $APO_RECOVERY_UNEXPECTED_CANDIDATE_REBOOT == 0 ]]
        [[ $APO_LAST_CLASS == HARNESS_FAILURE ]]
        [[ $APO_LAST_REASON == 'The worker failed without a structured result.' ]]
    )
done

# Final and optional-edge stress use a separate saved-stage proof. The real
# recovery implementation accepts only one of the three active final stress
# checkpoints and rejects a post-stress stage even when every boot predicate
# otherwise matches.
(
    reset_recovery_fixture
    apo_state_set TRYBOOT_EXPECTED 1
    apo_state_set LAST_BOOT_ID final-edge-stress-boot
    apo_state_set CANDIDATE_BOOT_ID final-edge-stress-boot
    apo_state_set PHASE FINAL_VALIDATION
    apo_state_set FINAL_STAGE ENDURANCE
    apo_wait_for_ssh() { return 0; }
    apo_remote_boot_id() { printf final-edge-normal-boot; }
    apo_remote_tryboot_flag() { printf 00000000; }
    apo_remote_worker() { return 1; }
    apo_health_check() { return 0; }
    apo_recover_stress_failure final-edge-reboot-fixture HARNESS_FAILURE 'The worker failed without a structured result.' 0 final
    [[ $APO_RECOVERY_UNEXPECTED_CANDIDATE_REBOOT == 1 ]]
    [[ $APO_LAST_CLASS == STABILITY_FAILURE ]]
)
for missing_final_proof in active-phase active-stage; do
    (
        reset_recovery_fixture
        apo_state_set TRYBOOT_EXPECTED 1
        apo_state_set LAST_BOOT_ID final-post-stress-boot
        apo_state_set CANDIDATE_BOOT_ID final-post-stress-boot
        apo_state_set PHASE FINAL_VALIDATION
        apo_state_set FINAL_STAGE ENDURANCE
        case $missing_final_proof in
            active-phase) apo_state_set PHASE CPU_SWEEP ;;
            active-stage) apo_state_set FINAL_STAGE RETURN_NORMAL ;;
        esac
        apo_wait_for_ssh() { return 0; }
        apo_remote_boot_id() { printf final-post-stress-normal-boot; }
        apo_remote_tryboot_flag() { printf 00000000; }
        apo_remote_worker() { return 1; }
        apo_health_check() { return 0; }
        apo_recover_stress_failure "final-missing-${missing_final_proof}-fixture" HARNESS_FAILURE 'The worker failed without a structured result.' 0 final
        [[ $APO_RECOVERY_UNEXPECTED_CANDIDATE_REBOOT == 0 ]]
        [[ $APO_LAST_CLASS == HARNESS_FAILURE ]]
    )
done

# A Batocera graphical recovery failure at already-normal clocks may request
# exactly one plain reboot, but only after proving that no tryboot ownership is
# active and the permanent config still has its saved hash.
(
    reset_recovery_fixture
    APO_PROFILE=batocera
    APO_MODE_EFFECTIVE=graphical
    CURRENT_BOOT_ID=forced-session-before
    REBOOT_NORMAL_CALLS=0
    HASH_CHECKS=''
    HEALTH_CALLS=0
    apo_wait_for_ssh() { return 0; }
    apo_remote_boot_id() { printf '%s' "$CURRENT_BOOT_ID"; }
    apo_remote_tryboot_flag() { printf 00000000; }
    apo_verify_permanent_hash() { HASH_CHECKS+="$1 "; return 0; }
    apo_remote_worker() {
        [[ $2 == reboot-normal ]]
        [[ ${3:-} == "$APO_PERMANENT_CONFIG_HASH" ]]
        REBOOT_NORMAL_CALLS=$((REBOOT_NORMAL_CALLS + 1))
        CURRENT_BOOT_ID=forced-session-after
    }
    apo_wait_for_new_boot() {
        [[ $1 == forced-session-before && $2 == 300 ]] || return 1
        printf forced-session-after
    }
    apo_health_check() { HEALTH_CALLS=$((HEALTH_CALLS + 1)); return 0; }
    apo_return_normal forced-session-recovery 1
    [[ $REBOOT_NORMAL_CALLS == 1 ]]
    [[ $HASH_CHECKS == 'forced-session-recovery-pre-forced-reboot forced-session-recovery-post-forced-reboot ' ]]
    [[ $HEALTH_CALLS == 1 ]]
    [[ $(apo_state_get NORMAL_BOOT_ID) == forced-session-after ]]
    [[ $(apo_state_get TRYBOOT_EXPECTED) == 0 ]]
)

# The dangerous force flag is rejected again at the recovery API boundary, so
# a future caller cannot accidentally send Batocera-only guard arguments to a
# Debian worker or force a reboot in Batocera headless mode.
for forced_profile_mode in debian:graphical batocera:headless; do
    (
        reset_recovery_fixture
        APO_PROFILE=${forced_profile_mode%%:*}
        APO_MODE_EFFECTIVE=${forced_profile_mode#*:}
        WAIT_FOR_SSH_CALLS=0
        REBOOT_NORMAL_CALLS=0
        apo_wait_for_ssh() { WAIT_FOR_SSH_CALLS=$((WAIT_FOR_SSH_CALLS + 1)); }
        apo_remote_worker() { REBOOT_NORMAL_CALLS=$((REBOOT_NORMAL_CALLS + 1)); }
        if apo_return_normal forced-profile-refused 1; then
            echo "forced normal reboot was accepted for $forced_profile_mode" >&2
            exit 1
        fi
        [[ $WAIT_FOR_SSH_CALLS == 0 && $REBOOT_NORMAL_CALLS == 0 ]]
        [[ $APO_LAST_CLASS == RECOVERY_FAILURE ]]
        # The recovery function and assertion intentionally share this subshell.
        # shellcheck disable=SC2031
        [[ $APO_RECOVERY_IN_PROGRESS == 0 ]]
    )
done

# Any uncertainty about the permanent config, saved tryboot ownership, or live
# tryboot flag refuses that optional reboot before it can mutate target state.
(
    reset_recovery_fixture
    APO_PROFILE=batocera
    APO_MODE_EFFECTIVE=graphical
    REBOOT_NORMAL_CALLS=0
    apo_wait_for_ssh() { return 0; }
    apo_remote_boot_id() { printf forced-refused-before; }
    apo_remote_tryboot_flag() { printf 00000000; }
    apo_verify_permanent_hash() {
        APO_LAST_CLASS=RECOVERY_FAILURE
        APO_LAST_REASON='fixture permanent hash mismatch'
        return 1
    }
    apo_remote_worker() { REBOOT_NORMAL_CALLS=$((REBOOT_NORMAL_CALLS + 1)); }
    if apo_return_normal forced-hash-refused 1; then
        echo 'forced normal reboot ignored a permanent-config hash mismatch' >&2
        exit 1
    fi
    [[ $REBOOT_NORMAL_CALLS == 0 ]]
    [[ $APO_LAST_REASON == 'fixture permanent hash mismatch' ]]
    # shellcheck disable=SC2031
    [[ $APO_RECOVERY_IN_PROGRESS == 0 ]]
)
(
    reset_recovery_fixture
    APO_PROFILE=batocera
    APO_MODE_EFFECTIVE=graphical
    apo_state_set TRYBOOT_FILE_MAY_EXIST 1
    REBOOT_NORMAL_CALLS=0
    HASH_CHECKS=0
    apo_wait_for_ssh() { return 0; }
    apo_remote_boot_id() { printf forced-owned-before; }
    apo_remote_tryboot_flag() { printf 00000000; }
    apo_verify_permanent_hash() { HASH_CHECKS=$((HASH_CHECKS + 1)); return 0; }
    apo_remote_worker() { REBOOT_NORMAL_CALLS=$((REBOOT_NORMAL_CALLS + 1)); }
    if apo_return_normal forced-owned-refused 1; then
        echo 'forced normal reboot ignored saved tryboot ownership state' >&2
        exit 1
    fi
    [[ $REBOOT_NORMAL_CALLS == 0 && $HASH_CHECKS == 0 ]]
    # shellcheck disable=SC2031
    [[ $APO_RECOVERY_IN_PROGRESS == 0 ]]
)
(
    reset_recovery_fixture
    APO_PROFILE=batocera
    APO_MODE_EFFECTIVE=graphical
    REBOOT_NORMAL_CALLS=0
    HASH_CHECKS=0
    apo_wait_for_ssh() { return 0; }
    apo_remote_boot_id() { printf forced-flag-before; }
    apo_remote_tryboot_flag() { :; }
    apo_verify_permanent_hash() { HASH_CHECKS=$((HASH_CHECKS + 1)); return 0; }
    apo_remote_worker() { REBOOT_NORMAL_CALLS=$((REBOOT_NORMAL_CALLS + 1)); }
    if apo_return_normal forced-flag-refused 1; then
        echo 'forced normal reboot ignored an unreadable live tryboot flag' >&2
        exit 1
    fi
    [[ $REBOOT_NORMAL_CALLS == 0 && $HASH_CHECKS == 0 ]]
    # shellcheck disable=SC2031
    [[ $APO_RECOVERY_IN_PROGRESS == 0 ]]
)

# The permanent hash is checked again after the new boot and before normal
# graphical health can be accepted.
(
    reset_recovery_fixture
    APO_PROFILE=batocera
    # shellcheck disable=SC2030
    APO_MODE_EFFECTIVE=graphical
    CURRENT_BOOT_ID=forced-post-hash-before
    REBOOT_NORMAL_CALLS=0
    HASH_CHECKS=0
    HEALTH_CALLS=0
    apo_wait_for_ssh() { return 0; }
    apo_remote_boot_id() { printf '%s' "$CURRENT_BOOT_ID"; }
    apo_remote_tryboot_flag() { printf 00000000; }
    apo_verify_permanent_hash() {
        HASH_CHECKS=$((HASH_CHECKS + 1))
        if (( HASH_CHECKS == 2 )); then
            APO_LAST_CLASS=RECOVERY_FAILURE
            APO_LAST_REASON='fixture post-reboot permanent hash mismatch'
            return 1
        fi
    }
    apo_remote_worker() {
        [[ $2 == reboot-normal ]]
        REBOOT_NORMAL_CALLS=$((REBOOT_NORMAL_CALLS + 1))
        CURRENT_BOOT_ID=forced-post-hash-after
    }
    apo_wait_for_new_boot() { printf forced-post-hash-after; }
    apo_health_check() { HEALTH_CALLS=$((HEALTH_CALLS + 1)); return 0; }
    if apo_return_normal forced-post-hash-refused 1; then
        echo 'forced normal reboot accepted a post-reboot permanent hash mismatch' >&2
        exit 1
    fi
    [[ $REBOOT_NORMAL_CALLS == 1 && $HASH_CHECKS == 2 && $HEALTH_CALLS == 0 ]]
    [[ $APO_LAST_REASON == 'fixture post-reboot permanent hash mismatch' ]]
    [[ $(apo_state_get NORMAL_BOOT_ID '') == '' ]]
    [[ $(apo_state_get TRYBOOT_EXPECTED) == 0 ]]
    # shellcheck disable=SC2031
    [[ $APO_RECOVERY_IN_PROGRESS == 0 ]]
)

# Once a separate normal boot and clear flag are proven, remove the exactly
# owned latent file before the full health gate so a health failure cannot
# strand a candidate for a later unrelated reboot.
(
    reset_recovery_fixture
    apo_state_set TRYBOOT_FILE_MAY_EXIST 1
    apo_state_set TRYBOOT_OWNED_HASH "$(printf 'a%.0s' {1..64})"
    apo_state_set TRYBOOT_RESERVATION_HASH "$(printf 'b%.0s' {1..64})"
    ACTIONS=''
    apo_wait_for_ssh() { return 0; }
    apo_remote_tryboot_flag() { printf 00000000; }
    apo_remote_boot_id() { printf cleanup-order-normal; }
    apo_clear_managed_tryboot() { ACTIONS+="clear "; apo_state_set TRYBOOT_FILE_MAY_EXIST 0; }
    apo_health_check() { ACTIONS+="health "; return 0; }
    apo_return_normal cleanup-order-fixture
    [[ $ACTIONS == 'clear health ' ]]
    [[ $(apo_state_get TRYBOOT_FILE_MAY_EXIST) == 0 ]]
)

# If the controller exits after recording tryboot intent but before the target
# leaves the old boot, recovery must force a plain reboot. Merely seeing a
# currently-clear tryboot flag would race the already-triggered reboot.
reset_recovery_fixture
apo_state_set TRYBOOT_EXPECTED 1
apo_state_set LAST_BOOT_ID pre-trigger-boot
REBOOT_NORMAL_CALLS=0
CURRENT_BOOT_ID=pre-trigger-boot
apo_wait_for_ssh() { return 0; }
apo_remote_boot_id() { printf '%s' "$CURRENT_BOOT_ID"; }
apo_remote_tryboot_flag() { printf 00000000; }
apo_remote_worker() {
    [[ $2 == reboot-normal ]]
    REBOOT_NORMAL_CALLS=$((REBOOT_NORMAL_CALLS + 1))
    CURRENT_BOOT_ID=forced-normal-boot
}
apo_wait_for_new_boot() {
    [[ $1 == pre-trigger-boot && $2 == 300 ]] || return 1
    [[ $CURRENT_BOOT_ID == forced-normal-boot ]] || return 1
    printf forced-normal-boot
}
apo_health_check() { APO_LAST_CLASS=PASS; APO_LAST_REASON='forced normal health passed'; }
# shellcheck disable=SC2218
apo_return_normal trigger-exit-race-fixture
[[ $REBOOT_NORMAL_CALLS == 1 ]]
[[ $(apo_state_get NORMAL_BOOT_ID) == forced-normal-boot ]]
[[ $(apo_state_get TRYBOOT_EXPECTED) == 0 ]]

# The third permitted reboot is still inspected and accepted when it is the
# one that finally returns the target to a verified normal boot.
reset_recovery_fixture
apo_state_set TRYBOOT_EXPECTED 1
apo_state_set LAST_BOOT_ID boot-0
REBOOT_NORMAL_CALLS=0
CURRENT_BOOT_ID=boot-0
apo_wait_for_ssh() { return 0; }
apo_remote_boot_id() { printf '%s' "$CURRENT_BOOT_ID"; }
apo_remote_tryboot_flag() {
    if (( REBOOT_NORMAL_CALLS < 3 )); then printf 00000001; else printf 00000000; fi
}
apo_remote_worker() {
    [[ $2 == reboot-normal ]]
    REBOOT_NORMAL_CALLS=$((REBOOT_NORMAL_CALLS + 1))
    CURRENT_BOOT_ID="boot-$REBOOT_NORMAL_CALLS"
}
apo_wait_for_new_boot() {
    [[ $2 == 300 && $CURRENT_BOOT_ID != "$1" ]] || return 1
    printf '%s' "$CURRENT_BOOT_ID"
}
apo_health_check() { APO_LAST_CLASS=PASS; APO_LAST_REASON='third reboot health passed'; }
# shellcheck disable=SC2218
apo_return_normal third-reboot-fixture
[[ $REBOOT_NORMAL_CALLS == 3 ]]
[[ $(apo_state_get NORMAL_BOOT_ID) == boot-3 ]]
[[ $(apo_state_get TRYBOOT_EXPECTED) == 0 ]]

# A candidate that automatically falls back to normal records the recovered
# boot ID and clears only the state that is now known to be normal.
reset_recovery_fixture
FIXTURE_TRYBOOT_HASH=$(printf 'e%.0s' {1..64})
FIXTURE_OWNERSHIP_TOKEN=$(printf 'f%.0s' {1..64})
apo_prepare_candidate() {
    apo_state_set TRYBOOT_OWNED_HASH "$FIXTURE_TRYBOOT_HASH"
    apo_state_set TRYBOOT_OWNERSHIP_TOKEN "$FIXTURE_OWNERSHIP_TOKEN"
}
apo_run_worker_capture() {
    [[ $2 == verify-tryboot ]]
    [[ $3 == "$APO_BOOT_CONFIG" && $4 == "$APO_TRYBOOT_CONFIG" ]]
    [[ $5 == "$APO_PERMANENT_CONFIG_HASH" && $6 == "$FIXTURE_TRYBOOT_HASH" ]]
    [[ $7 == "$APO_RUN_ID" && $8 == "$FIXTURE_OWNERSHIP_TOKEN" ]]
}
apo_remote_boot_id() { printf pre-candidate-boot; }
apo_remote_worker() { return 0; }
apo_wait_for_new_boot() {
    [[ $1 == pre-candidate-boot && $2 == 300 ]] || return 1
    printf auto-recovered-normal-boot
}
apo_remote_tryboot_flag() { printf 00000000; }
if apo_boot_candidate 3000 900 auto-recovery-fixture; then
    echo 'auto-recovered candidate was incorrectly accepted' >&2
    exit 1
fi
[[ $APO_LAST_CLASS == BOOT_FAILURE ]]
[[ $(apo_state_get NORMAL_BOOT_ID) == auto-recovered-normal-boot ]]
[[ $(apo_state_get LAST_BOOT_ID) == auto-recovered-normal-boot ]]
[[ $(apo_state_get CANDIDATE_BOOT_ID) == '' ]]
[[ $(apo_state_get TRYBOOT_EXPECTED) == 0 ]]
[[ $(apo_state_get CURRENT_CPU) == '' ]]
[[ $(apo_state_get CURRENT_GPU) == '' ]]

# An unreadable post-reboot flag is not assumed to mean automatic recovery;
# TRYBOOT_EXPECTED remains set so the controller exit trap will retry recovery.
reset_recovery_fixture
apo_remote_tryboot_flag() { :; }
if apo_boot_candidate 3000 900 unknown-tryboot-fixture; then
    echo 'candidate with unknown tryboot state was incorrectly accepted' >&2
    exit 1
fi
[[ $APO_LAST_CLASS == BOOT_FAILURE ]]
[[ $(apo_state_get TRYBOOT_EXPECTED) == 1 ]]
[[ $(apo_state_get NORMAL_BOOT_ID) == '' ]]

# Successful recovery restores the original candidate failure classification.
RECOVERY_FORCE_REBOOT=''
apo_return_normal() { RECOVERY_FORCE_REBOOT=${2:-0}; return 0; }
apo_recover_preserving_failure recovery-ok STABILITY_FAILURE 'candidate became unstable' 1
[[ $RECOVERY_FORCE_REBOOT == 1 ]]
[[ $APO_LAST_CLASS == STABILITY_FAILURE ]]
[[ $APO_LAST_REASON == 'candidate became unstable' ]]

# Failed recovery is promoted, while retaining both the original failure and
# the recovery/hash evidence in the resulting reason.
apo_return_normal() {
    APO_LAST_CLASS=RECOVERY_FAILURE
    APO_LAST_REASON='Permanent config hash changed during normal recovery.'
    return 1
}
if apo_recover_preserving_failure recovery-failed BOOT_FAILURE 'candidate never reached health'; then
    echo 'failed normal recovery was incorrectly suppressed' >&2
    exit 1
fi
[[ $APO_LAST_CLASS == RECOVERY_FAILURE ]]
[[ $APO_LAST_REASON == *'Original BOOT_FAILURE: candidate never reached health'* ]]
[[ $APO_LAST_REASON == *'Permanent config hash changed during normal recovery.'* ]]

if apo_recover_stress_failure stress-recovery-failed HARNESS_FAILURE 'The worker failed without a structured result.' 0 candidate; then
    echo 'failed stress recovery was incorrectly promoted to a stability boundary' >&2
    exit 1
fi
[[ $APO_LAST_CLASS == RECOVERY_FAILURE ]]
[[ $APO_LAST_REASON == *'Original HARNESS_FAILURE: The worker failed without a structured result.'* ]]
[[ $APO_LAST_REASON == *'Permanent config hash changed during normal recovery.'* ]]

apo_record_failure_after_recovery recorded-recovery-failure STABILITY_FAILURE 'stress worker failed'
[[ $(apo_state_get STATUS) == FAILED ]]
[[ $(apo_state_get FAILURE_CLASS) == RECOVERY_FAILURE ]]
[[ $(apo_state_get FAILURE_REASON) == *'Original STABILITY_FAILURE: stress worker failed'* ]]
[[ $(apo_state_get FAILURE_REASON) == *'Permanent config hash changed during normal recovery.'* ]]

if grep -Eq 'apo_return_normal.*\|\|[[:space:]]*true' "$ROOT/lib/recovery.sh" "$ROOT/lib/candidates.sh"; then
    echo 'a failed return-to-normal is still explicitly suppressed' >&2
    exit 1
fi

# A checkpoint interrupted before discovery has no profile context. It remains
# inspectable through status/summary/report, while resume refuses before any
# SSH action. Status now includes a live read-only probe, so this local fixture
# supplies a deterministic unavailable transport instead of touching DNS.
PARTIAL_DIR=$(mktemp -d)
trap 'rm -rf "$PARTIAL_DIR"' EXIT
PARTIAL_BIN="$PARTIAL_DIR/bin"
mkdir -p "$PARTIAL_BIN"
printf '#!/usr/bin/env bash\nexit 255\n' > "$PARTIAL_BIN/ssh"
chmod 755 "$PARTIAL_BIN/ssh"
PARTIAL_STATE="$PARTIAL_DIR/example-host-partial.state"
ROOT="$ROOT" PARTIAL_STATE="$PARTIAL_STATE" PARTIAL_DIR="$PARTIAL_DIR" STORED_TARGET="$(id -un)@example-host" bash -c '
    set -Eeuo pipefail
    APO_ROOT=$ROOT
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/state.sh"
    APO_STATE=()
    APO_STATE_FILE=$PARTIAL_STATE
    apo_state_set FORMAT_VERSION 1
    apo_state_set RUN_SCHEMA "$APO_CURRENT_RUN_SCHEMA"
    apo_state_set RUN_ID partial
    apo_state_set REMOTE_TARGET "$STORED_TARGET"
    apo_state_set TARGET_SLUG example-host
    apo_state_set OUTPUT_DIR "$PARTIAL_DIR"
    apo_state_set PROFILE ""
    apo_state_set STATUS PREPARING
    apo_state_set PHASE PREPARE
    apo_state_set SUBPHASE INITIAL
    apo_state_save
'
STATUS_OUTPUT=$(PATH="$PARTIAL_BIN:$PATH" APO_STATUS_CAPTURE_ATTEMPTS=1 APO_STATUS_CAPTURE_DELAY_SECONDS=0 \
    "$ROOT/autopioverclock" status example-host --output-dir "$PARTIAL_DIR" --run-id partial)
[[ $STATUS_OUTPUT == *'Phase:          PREPARE'* ]]
SUMMARY_OUTPUT=$(PATH="$PARTIAL_BIN:$PATH" APO_STATUS_CAPTURE_ATTEMPTS=1 APO_STATUS_CAPTURE_DELAY_SECONDS=0 \
    "$ROOT/autopioverclock" summary example-host --output-dir "$PARTIAL_DIR" --run-id partial)
[[ $SUMMARY_OUTPUT == *'Run story'* ]]
"$ROOT/autopioverclock" report example-host --output-dir "$PARTIAL_DIR" --run-id partial >/dev/null
[[ -s $PARTIAL_DIR/example-host-partial-report.txt ]]
if "$ROOT/autopioverclock" resume example-host --output-dir "$PARTIAL_DIR" --run-id partial >"$PARTIAL_DIR/resume.out" 2>&1; then
    echo 'profile-less PREPARE checkpoint was incorrectly resumed' >&2
    exit 1
fi
grep -q 'interrupted before target discovery' "$PARTIAL_DIR/resume.out"

# A PREPARE checkpoint with a complete pre-repair profile and planned hashes is
# inspectable, but resume must refuse it before SSH instead of adopting a
# possibly staged watchdog config as the permanent baseline.
REPAIR_STATE="$PARTIAL_DIR/example-host-repair.state"
ROOT="$ROOT" REPAIR_STATE="$REPAIR_STATE" PARTIAL_DIR="$PARTIAL_DIR" STORED_TARGET="$(id -un)@example-host" bash -c '
    set -Eeuo pipefail
    APO_ROOT=$ROOT
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/state.sh"
    APO_STATE=()
    APO_STATE_FILE=$REPAIR_STATE
    apo_state_set FORMAT_VERSION 1
    apo_state_set RUN_SCHEMA "$APO_CURRENT_RUN_SCHEMA"
    apo_state_set RUN_ID repair
    apo_state_set REMOTE_TARGET "$STORED_TARGET"
    apo_state_set TARGET_SLUG example-host
    apo_state_set OUTPUT_DIR "$PARTIAL_DIR"
    apo_state_set ORIGIN_COMMAND run
    apo_state_set READ_ONLY_RUN 0
    apo_state_set PROFILE debian
    apo_state_set MODE_REQUESTED headless
    apo_state_set MODE_EFFECTIVE headless
    apo_state_set AUTO_BASELINE_CPU ""
    apo_state_set AUTO_BASELINE_GPU ""
    apo_state_set AUTO_BASELINE_VOLTAGE ""
    apo_state_set AUTO_BASELINE_PROVENANCE ""
    apo_state_set AUTO_BASELINE_EVIDENCE ""
    apo_state_set STATUS PREPARING
    apo_state_set PHASE PREPARE
    apo_state_set SUBPHASE WATCHDOG_REPAIR_MUTATING
    apo_state_set WATCHDOG_REPAIR_STATUS MUTATING
    apo_state_set WATCHDOG_REPAIR_OLD_HASH aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    apo_state_set WATCHDOG_REPAIR_EXPECTED_HASH bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    apo_state_save
'
if "$ROOT/autopioverclock" resume example-host --output-dir "$PARTIAL_DIR" --run-id repair >"$PARTIAL_DIR/repair-resume.out" 2>&1; then
    echo 'interrupted watchdog PREPARE checkpoint was incorrectly resumed' >&2
    exit 1
fi
grep -q 'Resume refuses to adopt any preflight config change as a new baseline' "$PARTIAL_DIR/repair-resume.out"
grep -q 'expected hash: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' "$PARTIAL_DIR/repair-resume.out"

# A failed SSH transport is not evidence that config.txt changed.  Keep hash
# mismatch, unavailable, and malformed evidence distinct so stress recovery can
# preserve its primary worker failure while re-verifying the hash after SSH
# returns.
(
    APO_PERMANENT_HASH_READ_ATTEMPTS=3
    APO_PERMANENT_HASH_READ_DELAY_SECONDS=0
    source "$ROOT/lib/health.sh"
    # shellcheck disable=SC2030
    APO_BOOT_CONFIG=/boot/config.txt
    # shellcheck disable=SC2030
    APO_PERMANENT_CONFIG_HASH=$(printf 'a%.0s' {1..64})
    REMOTE_HASH=$APO_PERMANENT_CONFIG_HASH
    apo_remote_root() { printf '%s  /boot/config.txt\n' "$REMOTE_HASH"; }
    apo_verify_permanent_hash hash-match

    REMOTE_HASH=$(printf 'b%.0s' {1..64})
    set +e
    apo_verify_permanent_hash hash-mismatch
    HASH_RC=$?
    set -e
    [[ $HASH_RC == 1 && $APO_LAST_CLASS == RECOVERY_FAILURE ]]
    [[ $APO_LAST_REASON == *"$APO_PERMANENT_CONFIG_HASH -> $REMOTE_HASH"* ]]

    apo_remote_root() { return 255; }
    set +e
    apo_verify_permanent_hash hash-offline
    HASH_RC=$?
    set -e
    [[ $HASH_RC == 2 && $APO_LAST_CLASS == RECOVERY_FAILURE ]]
    [[ $APO_LAST_REASON == *'is unavailable in hash-offline'* ]]
    [[ $APO_LAST_REASON != *'hash changed'* ]]

    apo_remote_root() { printf 'not-a-hash  /boot/config.txt\n'; }
    set +e
    apo_verify_permanent_hash hash-malformed
    HASH_RC=$?
    set -e
    [[ $HASH_RC == 2 && $APO_LAST_REASON == *'malformed hash evidence'* ]]

    # The public policy gives even an isolated protected-hash read thirty
    # chances across its production multi-minute window.
    APO_PERMANENT_HASH_READ_ATTEMPTS=30
    APO_PERMANENT_HASH_READ_DELAY_SECONDS=0
    HASH_ATTEMPT_FILE=$(mktemp)
    trap 'rm -f "$HASH_ATTEMPT_FILE"' EXIT
    : > "$HASH_ATTEMPT_FILE"
    apo_remote_root() {
        printf x >> "$HASH_ATTEMPT_FILE"
        (( $(wc -c < "$HASH_ATTEMPT_FILE") == 30 )) || return 255
        printf '%s  /boot/config.txt\n' "$APO_PERMANENT_CONFIG_HASH"
    }
    apo_verify_permanent_hash hash-thirtieth-attempt
    [[ $(wc -c < "$HASH_ATTEMPT_FILE") == 30 ]]

    : > "$HASH_ATTEMPT_FILE"
    apo_remote_root() {
        printf x >> "$HASH_ATTEMPT_FILE"
        printf '%s  /boot/config.txt\n' "$(printf 'b%.0s' {1..64})"
    }
    set +e
    apo_verify_permanent_hash hash-immediate-mismatch
    HASH_RC=$?
    set -e
    [[ $HASH_RC == 1 ]]
    [[ $(wc -c < "$HASH_ATTEMPT_FILE") == 1 ]]
)

# Once complete stock recovery proves health, the exact controller-only hash
# read failure that ended alpha.38 is normalized to a retryable harness gate.
# A failed recheck remains RECOVERY_FAILURE and is never retried away.
(
    APO_PERMANENT_HASH_READ_ATTEMPTS=3
    APO_PERMANENT_HASH_READ_DELAY_SECONDS=0
    source "$ROOT/lib/health.sh"
    APO_RECOVERY_UNEXPECTED_CANDIDATE_REBOOT=0
    apo_return_normal() { APO_RECOVERY_UNEXPECTED_CANDIDATE_REBOOT=0; return 0; }
    apo_verify_permanent_hash() { return 0; }
    old_hash_reason='Permanent config hash is unavailable in cpu-refine-3150_gpu-960-candidate-post-stress; the target did not return readable hash evidence.'
    apo_recover_preserving_failure recovered-hash-read RECOVERY_FAILURE "$old_hash_reason"
    [[ $APO_LAST_CLASS == HARNESS_FAILURE ]]
    [[ $APO_LAST_REASON == *'complete normal recovery re-proved the exact hash and health'* ]]

    apo_verify_permanent_hash() {
        APO_LAST_CLASS=RECOVERY_FAILURE
        APO_LAST_REASON='hash recheck fixture remained unreadable'
        return 2
    }
    if apo_recover_preserving_failure failed-hash-read RECOVERY_FAILURE "$old_hash_reason"; then
        echo 'failed protected-hash recheck was incorrectly normalized' >&2
        exit 1
    fi
    [[ $APO_LAST_CLASS == RECOVERY_FAILURE ]]
    [[ $APO_LAST_REASON == *'hash recheck fixture remained unreadable'* ]]
)

run_stress_hash_fixture() (
    local worker_class=$1 worker_reason=$2 worker_rc=$3 post_hash_rc=$4
    declare -Ag APO_CFG=([MAX_TEMP_C]=75 [TELEMETRY_INTERVAL_S]=5)
    APO_MODE_EFFECTIVE=graphical
    APO_DISPLAY_BASELINE=fixture-display
    APO_THROTTLE_RUNTIME_BASELINE=throttled=0x0
    APO_AUDIO_BASELINE=fixture-audio
    APO_NORMAL_CPU=2400
    APO_NORMAL_GPU=800
    VERIFY_CALLS=0
    apo_state_get() { printf '%s' "${2:-}"; }
    apo_run_worker_capture() {
        APO_LAST_CLASS=$worker_class
        APO_LAST_REASON=$worker_reason
        return "$worker_rc"
    }
    source "$ROOT/lib/health.sh"
    apo_verify_permanent_hash() {
        VERIFY_CALLS=$((VERIFY_CALLS + 1))
        (( VERIFY_CALLS == 1 )) && return 0
        case $post_hash_rc in
            0) return 0 ;;
            1) APO_LAST_CLASS=RECOVERY_FAILURE; APO_LAST_REASON='verified fixture hash mismatch'; return 1 ;;
            2) APO_LAST_CLASS=RECOVERY_FAILURE; APO_LAST_REASON='fixture hash unavailable'; return 2 ;;
        esac
    }
    set +e
    apo_run_stress gpu 20 stress-hash-fixture 0
    STRESS_RC=$?
    set -e
    printf '%s\t%s\t%s\t%s\n' "$STRESS_RC" "$APO_LAST_CLASS" "$APO_LAST_REASON" "$VERIFY_CALLS"
)

STRESS_HASH_RESULT=$(run_stress_hash_fixture HARNESS_FAILURE 'worker SSH transport failed' 1 2)
[[ $STRESS_HASH_RESULT == $'1\tHARNESS_FAILURE\tworker SSH transport failed\t2' ]]
STRESS_HASH_RESULT=$(run_stress_hash_fixture RECOVERY_FAILURE 'frontend restore failed' 1 2)
[[ $STRESS_HASH_RESULT == $'1\tRECOVERY_FAILURE\tfrontend restore failed\t2' ]]
STRESS_HASH_RESULT=$(run_stress_hash_fixture STABILITY_FAILURE 'worker found a kernel fault' 1 0)
[[ $STRESS_HASH_RESULT == $'1\tSTABILITY_FAILURE\tworker found a kernel fault\t2' ]]
STRESS_HASH_RESULT=$(run_stress_hash_fixture HARNESS_FAILURE 'worker SSH transport failed' 1 1)
[[ $STRESS_HASH_RESULT == $'1\tRECOVERY_FAILURE\tverified fixture hash mismatch\t2' ]]
STRESS_HASH_RESULT=$(run_stress_hash_fixture PASS 'worker passed' 0 2)
[[ $STRESS_HASH_RESULT == $'1\tRECOVERY_FAILURE\tfixture hash unavailable\t2' ]]
STRESS_HASH_RESULT=$(run_stress_hash_fixture PASS 'worker passed' 0 1)
[[ $STRESS_HASH_RESULT == $'1\tRECOVERY_FAILURE\tverified fixture hash mismatch\t2' ]]

printf 'test_interrupted_state: PASS\n'
