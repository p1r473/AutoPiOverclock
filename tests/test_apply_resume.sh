#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
APO_ROOT=$ROOT
source "$ROOT/lib/common.sh"
source "$ROOT/lib/state.sh"
source "$ROOT/lib/apply.sh"
ORIGINAL_APO_APPLY_RESTORE_OLD_CONFIG=$(declare -f apo_apply_restore_old_config)

OLD_HASH=$(printf '1%.0s' {1..64})
NEW_HASH=$(printf '2%.0s' {1..64})
UNKNOWN_HASH=$(printf '3%.0s' {1..64})

apo_apply_valid_hash "$OLD_HASH"
if apo_apply_valid_hash short; then
    echo 'an invalid apply hash was accepted' >&2
    exit 1
fi
[[ $(apo_apply_hash_disposition "$OLD_HASH" "$OLD_HASH" "$NEW_HASH") == OLD ]]
[[ $(apo_apply_hash_disposition "$NEW_HASH" "$OLD_HASH" "$NEW_HASH") == EXPECTED ]]
[[ $(apo_apply_hash_disposition "$UNKNOWN_HASH" "$OLD_HASH" "$NEW_HASH") == UNKNOWN ]]
APO_PROFILE=debian
[[ $(apo_apply_backup_path fixture-run) == /var/lib/autopioverclock/backups/config-fixture-run-before-apply.txt ]]
APO_PROFILE=batocera
[[ $(apo_apply_backup_path fixture-run) == /userdata/system/autopioverclock/backups/config-fixture-run-before-apply.txt ]]

apo_state_save() { :; }
apo_event() { :; }
apo_summary_line() { :; }
apo_warn() { :; }

reset_apply_fixture() {
    APO_STATE=()
    APO_PROFILE=debian
    APO_RUN_ID=fixture-run
    APO_TRYBOOT_CONFIG=/boot/tryboot.txt
    APO_PERMANENT_CONFIG_HASH=$OLD_HASH
    APO_NORMAL_CPU=2400
    APO_NORMAL_GPU=800
    APO_NORMAL_VOLTAGE=0
    APO_GPU_KEY=v3d_freq
    APO_BOOT_TIMEOUT=30
    APO_BOOT_SETTLE_SECONDS=0
    APO_REMOTE_WORKER=/tmp/fixture-worker
    apo_state_set RUN_SCHEMA "$APO_CURRENT_RUN_SCHEMA"
    apo_state_set TRYBOOT_EXPECTED 0
    apo_state_set TRYBOOT_FILE_MAY_EXIST 0
    apo_state_set TRYBOOT_OWNED_HASH ''
    apo_state_set TRYBOOT_RESERVATION_HASH ''
    apo_state_set TRYBOOT_OWNERSHIP_TOKEN ''
    apo_state_set TRYBOOT_QUARANTINE_PATH ''
    apo_state_set APPLY_STATUS APPLYING
    apo_state_set APPLY_OLD_HASH "$OLD_HASH"
    apo_state_set APPLY_EXPECTED_HASH "$NEW_HASH"
    apo_state_set APPLY_BACKUP /var/lib/autopioverclock/backups/config-fixture-run-before-apply.txt
    apo_state_set APPLY_RECOVERY_ACTION ''
    apo_state_set APPLY_FAILURE_REASON ''
    apo_state_set FINAL_CPU 3000
    apo_state_set FINAL_GPU 900
    apo_state_set TEST_VOLTAGE 50000
    ROUTE=''
    CURRENT_HASH=$OLD_HASH
    SSH_READY=1
    LIVE_TRYBOOT_FLAG=00000000
    TRYBOOT_PATH_STATE=absent
}

apo_wait_for_ssh() { (( SSH_READY == 1 )); }
apo_post_reboot_handshake() {
    APO_REBOOT_HANDSHAKE_STAGE='wait'
    APO_REBOOT_BOOT_ID=$(apo_wait_for_new_boot "$1" "$2" || true)
    [[ -n $APO_REBOOT_BOOT_ID ]] || return 1
    APO_REBOOT_HANDSHAKE_STAGE='complete'
}
apo_current_permanent_hash() { printf '%s' "$CURRENT_HASH"; }
apo_remote_tryboot_flag() {
    [[ $LIVE_TRYBOOT_FLAG != unreadable ]] || return 1
    printf '%s' "$LIVE_TRYBOOT_FLAG"
}
apo_remote_root() {
    local command_text=$1 expected_command
    expected_command="if [ -e $(apo_sh_quote "$APO_TRYBOOT_CONFIG") ] || [ -L $(apo_sh_quote "$APO_TRYBOOT_CONFIG") ]; then printf present; else printf absent; fi"
    [[ $command_text == "$expected_command" ]] || return 97
    case $TRYBOOT_PATH_STATE in
        absent|present) printf '%s' "$TRYBOOT_PATH_STATE" ;;
        unreadable) return 1 ;;
        *) return 98 ;;
    esac
}
apo_apply_verify_old_config() { ROUTE="OLD:$2"; apo_state_set APPLY_STATUS "$2"; return 0; }
apo_apply_validate_expected_config() { ROUTE=EXPECTED; apo_state_set APPLY_STATUS APPLIED; return 0; }
apo_apply_restore_old_config() { ROUTE=ROLLBACK; apo_state_set APPLY_STATUS ROLLED_BACK; return 0; }

assert_fresh_apply_refused() {
    local label=$1 expected_reason=$2 output status
    apo_state_set APPLY_STATUS NOT_APPLIED
    apo_state_set VALIDATED 1
    apo_state_set VALIDATION_SCHEMA "$APO_CURRENT_VALIDATION_SCHEMA"
    apo_state_set STATUS PASS
    apo_state_set PHASE COMPLETE
    apo_state_set CFG_FINAL_DURATION_S "$APO_MIN_FINAL_DURATION_S"
    apo_state_set VALIDATION_DURATION_S "$APO_MIN_FINAL_DURATION_S"
    set +e
    output=$(apo_apply_recommendation 2>&1)
    status=$?
    set -e
    if (( status != APO_EXIT_APPLY )); then
        echo "$label: fresh apply exited $status instead of $APO_EXIT_APPLY" >&2
        exit 1
    fi
    if [[ $output != *"$expected_reason"* ]]; then
        printf '%s: fresh apply did not report the expected gate:\n%s\n' "$label" "$output" >&2
        exit 1
    fi
}

assert_reconcile_refused() {
    local label=$1 expected_reason=$2 failure_reason
    if apo_reconcile_interrupted_apply; then
        echo "$label: interrupted apply reconciliation was incorrectly accepted" >&2
        exit 1
    fi
    failure_reason=$(apo_state_get APPLY_FAILURE_REASON '')
    [[ $(apo_state_get APPLY_STATUS '') == APPLYING ]]
    [[ $ROUTE == '' ]]
    if [[ $failure_reason != *"$expected_reason"* ]]; then
        printf '%s: reconciliation did not report the expected gate:\n%s\n' "$label" "$failure_reason" >&2
        exit 1
    fi
}

assert_worker_locked_apply_dispatch() {
    local worker_file=$1 output
    output=$(
        APO_WORKER_LIBRARY_ONLY=1
        # shellcheck disable=SC1090
        source "$worker_file"
        run_with_mutation_lock() {
            local argument
            printf 'LOCK'
            for argument in "$@"; do printf '|%s' "$argument"; done
            printf '\n'
        }
        main apply-permanent /tmp/proposed-config "$OLD_HASH" "$NEW_HASH" fixture-run
        main restore-backup /tmp/backup-config "$OLD_HASH" "$NEW_HASH"
    )
    grep -Fqx "LOCK|apply-fixture-run|APPLY_FAILURE|cmd_apply_permanent|/tmp/proposed-config|$OLD_HASH|$NEW_HASH|fixture-run" <<< "$output"
    grep -Fqx "LOCK|restore-$OLD_HASH|APPLY_FAILURE|cmd_restore_backup|/tmp/backup-config|$OLD_HASH|$NEW_HASH" <<< "$output"
}

assert_worker_tryboot_detector() {
    local worker_file=$1 fixture_dir worker_status=0
    fixture_dir=$(mktemp -d)
    printf 'fixture config\n' > "$fixture_dir/config.txt"
    (
        APO_WORKER_LIBRARY_ONLY=1
        # shellcheck disable=SC1090
        source "$worker_file"
        od() { printf '%s\n' "$MOCK_TRYBOOT_FLAG"; }

        MOCK_TRYBOOT_FLAG=' 00 00 00 00'
        apply_tryboot_clear "$fixture_dir/config.txt" || {
            echo "${worker_file##*/}: clean tryboot evidence was rejected" >&2
            exit 1
        }

        MOCK_TRYBOOT_FLAG=' 00 00 00 01'
        if apply_tryboot_clear "$fixture_dir/config.txt"; then
            echo "${worker_file##*/}: live tryboot evidence was accepted" >&2
            exit 1
        fi

        MOCK_TRYBOOT_FLAG=' 00 00 00 00'
        printf 'staged candidate\n' > "$fixture_dir/tryboot.txt"
        if apply_tryboot_clear "$fixture_dir/config.txt"; then
            echo "${worker_file##*/}: staged tryboot evidence was accepted" >&2
            exit 1
        fi
        rm -f -- "$fixture_dir/tryboot.txt"

        printf 'quarantined candidate\n' > "$fixture_dir/.autopioverclock-remove-fixture"
        if apply_tryboot_clear "$fixture_dir/config.txt"; then
            echo "${worker_file##*/}: quarantined tryboot evidence was accepted" >&2
            exit 1
        fi
    ) || worker_status=$?
    rm -f -- "$fixture_dir/config.txt" "$fixture_dir/tryboot.txt" "$fixture_dir/.autopioverclock-remove-fixture"
    rmdir -- "$fixture_dir"
    (( worker_status == 0 )) || exit "$worker_status"
}

assert_worker_apply_mutation_boundary() {
    local worker_file=$1 fixture_dir uploaded_file backup_file worker_status=0
    fixture_dir=$(mktemp -d)
    uploaded_file="$fixture_dir/proposed-config.txt"
    backup_file="$fixture_dir/backup-config.txt"
    printf 'proposed config\n' > "$uploaded_file"
    printf 'backup config\n' > "$backup_file"
    (
        local destination_hash evidence output status
        APO_WORKER_LIBRARY_ONLY=1
        # shellcheck disable=SC1090
        source "$worker_file"
        MOCK_BOOT_CONFIG="$fixture_dir/config.txt"
        if [[ ${worker_file##*/} == batocera-worker.sh ]]; then
            MOCK_DESTINATION_CONFIG=/boot/config.txt
        else
            MOCK_DESTINATION_CONFIG=$MOCK_BOOT_CONFIG
        fi
        CLEAR_CALLS=0
        EVIDENCE_CASE=''
        OPERATION=apply
        DESTINATION_HASH_MODE=expected
        DESTINATION_HASH_OVERRIDE=''
        DESTINATION_RACE_MARKER="$fixture_dir/destination-raced"
        MUTATION_LOCK_HELD=0
        MUTATION_LOCK_OWNER=''
        APO_APPLY_BOOT_RW=0

        mutation_lock_acquire() {
            [[ $MUTATION_LOCK_HELD == 0 ]] || return 1
            MUTATION_LOCK_HELD=1
            MUTATION_LOCK_OWNER=$1
        }
        mutation_lock_release() {
            MUTATION_LOCK_HELD=0
            MUTATION_LOCK_OWNER=''
        }
        emit_result() { printf 'RESULT|%s|%s\n' "$1" "$2"; }
        find_boot_config() { printf '%s' "$MOCK_BOOT_CONFIG"; }
        apply_tryboot_clear() {
            (( CLEAR_CALLS += 1 ))
            printf 'TRYBOOT_GATE|%s|lock=%s|call=%s\n' "$EVIDENCE_CASE" "$MUTATION_LOCK_HELD" "$CLEAR_CALLS"
            [[ $MUTATION_LOCK_HELD == 1 ]] || return 99
            if [[ $OPERATION == restore ]]; then
                if [[ $EVIDENCE_CASE == destination-race && $CLEAR_CALLS == 2 ]]; then
                    printf 'raced\n' > "$DESTINATION_RACE_MARKER"
                fi
                return 0
            fi
            [[ $EVIDENCE_CASE == race && $CLEAR_CALLS == 1 ]]
        }
        mkdir() { :; }
        chmod() { :; }
        sha256sum() {
            if [[ $1 == "$uploaded_file" ]]; then
                printf '%s  %s\n' "$NEW_HASH" "$1"
            elif [[ $1 == "$backup_file" ]]; then
                printf '%s  %s\n' "$OLD_HASH" "$1"
            elif [[ $1 == "$MOCK_DESTINATION_CONFIG" ]]; then
                if [[ $OPERATION == apply ]]; then
                    printf '%s  %s\n' "$OLD_HASH" "$1"
                elif [[ $DESTINATION_HASH_MODE == override ]]; then
                    printf '%s  %s\n' "$DESTINATION_HASH_OVERRIDE" "$1"
                elif [[ $DESTINATION_HASH_MODE == race && -e $DESTINATION_RACE_MARKER ]]; then
                    printf '%s  %s\n' "$UNKNOWN_HASH" "$1"
                else
                    printf '%s  %s\n' "$NEW_HASH" "$1"
                fi
            else
                printf '%s  %s\n' "$OLD_HASH" "$1"
            fi
        }
        atomic_replace_verified() {
            printf 'REPLACEMENT_REACHED|%s|%s|%s|%s\n' "$@"
            return 0
        }
        apply_install_traps() { :; }
        apply_clear_traps() { :; }
        remount_boot_rw() { return 0; }
        apply_remount_boot_ro() { APO_APPLY_BOOT_RW=0; return 0; }

        for evidence in live staged quarantined; do
            EVIDENCE_CASE=$evidence
            CLEAR_CALLS=0
            set +e
            output=$(run_with_mutation_lock apply-fixture-run APPLY_FAILURE cmd_apply_permanent \
                "$uploaded_file" "$OLD_HASH" "$NEW_HASH" fixture-run 2>&1)
            status=$?
            set -e
            if (( status == 0 )); then
                echo "${worker_file##*/}: $evidence tryboot evidence reached permanent apply" >&2
                exit 1
            fi
            grep -Fq "TRYBOOT_GATE|$evidence|lock=1|call=1" <<< "$output"
            grep -Fq 'Permanent apply requires a normal boot with no live, staged, or quarantined tryboot evidence.' <<< "$output"
            if grep -Fq 'REPLACEMENT_REACHED' <<< "$output"; then
                echo "${worker_file##*/}: $evidence tryboot evidence reached replacement" >&2
                exit 1
            fi
        done

        # Model a race that appears after staging/backup work. The second
        # in-lock tryboot check must fail before atomic replacement is called.
        EVIDENCE_CASE=race
        CLEAR_CALLS=0
        set +e
        output=$(run_with_mutation_lock apply-fixture-run APPLY_FAILURE cmd_apply_permanent \
            "$uploaded_file" "$OLD_HASH" "$NEW_HASH" fixture-run 2>&1)
        status=$?
        set -e
        if (( status == 0 )); then
            echo "${worker_file##*/}: tryboot race was accepted at the mutation boundary" >&2
            exit 1
        fi
        grep -Fq 'TRYBOOT_GATE|race|lock=1|call=1' <<< "$output"
        grep -Fq 'TRYBOOT_GATE|race|lock=1|call=2' <<< "$output"
        grep -Fq 'Tryboot evidence appeared before permanent replacement; refusing to apply.' <<< "$output"
        if grep -Fq 'REPLACEMENT_REACHED' <<< "$output"; then
            echo "${worker_file##*/}: replacement ran after the final tryboot check failed" >&2
            exit 1
        fi

        # Rollback is allowed only when the live destination still has the
        # checkpointed proposed hash. Known-old and unknown destinations both
        # fail closed before any replacement.
        OPERATION=restore
        DESTINATION_HASH_MODE=override
        for destination_hash in "$OLD_HASH" "$UNKNOWN_HASH"; do
            DESTINATION_HASH_OVERRIDE=$destination_hash
            EVIDENCE_CASE="destination-${destination_hash:0:1}"
            CLEAR_CALLS=0
            rm -f -- "$DESTINATION_RACE_MARKER"
            set +e
            output=$(run_with_mutation_lock "restore-$OLD_HASH" APPLY_FAILURE cmd_restore_backup \
                "$backup_file" "$OLD_HASH" "$NEW_HASH" 2>&1)
            status=$?
            set -e
            if (( status == 0 )); then
                echo "${worker_file##*/}: mismatched rollback destination $destination_hash was accepted" >&2
                exit 1
            fi
            grep -Fq "TRYBOOT_GATE|$EVIDENCE_CASE|lock=1|call=1" <<< "$output"
            grep -Fq 'Permanent config does not match the persisted pre-rollback destination hash; refusing restoration.' <<< "$output"
            if grep -Fq 'REPLACEMENT_REACHED' <<< "$output"; then
                echo "${worker_file##*/}: mismatched rollback destination reached replacement" >&2
                exit 1
            fi
        done

        # A destination change after entry validation is caught by a second
        # hash check immediately after the retained final tryboot check.
        DESTINATION_HASH_MODE=race
        DESTINATION_HASH_OVERRIDE=''
        EVIDENCE_CASE='destination-race'
        CLEAR_CALLS=0
        rm -f -- "$DESTINATION_RACE_MARKER"
        set +e
        output=$(run_with_mutation_lock "restore-$OLD_HASH" APPLY_FAILURE cmd_restore_backup \
            "$backup_file" "$OLD_HASH" "$NEW_HASH" 2>&1)
        status=$?
        set -e
        if (( status == 0 )); then
            echo "${worker_file##*/}: pre-replacement rollback destination race was accepted" >&2
            exit 1
        fi
        grep -Fq 'TRYBOOT_GATE|destination-race|lock=1|call=1' <<< "$output"
        grep -Fq 'TRYBOOT_GATE|destination-race|lock=1|call=2' <<< "$output"
        grep -Fq 'Permanent config changed at the rollback mutation boundary; refusing restoration.' <<< "$output"
        if grep -Fq 'REPLACEMENT_REACHED' <<< "$output"; then
            echo "${worker_file##*/}: rollback replacement ran after its destination hash raced" >&2
            exit 1
        fi
    ) || worker_status=$?
    rm -f -- "$uploaded_file" "$backup_file" "$fixture_dir/destination-raced"
    rmdir -- "$fixture_dir"
    (( worker_status == 0 )) || exit "$worker_status"
}

reset_apply_fixture
apo_reconcile_interrupted_apply
[[ $ROUTE == OLD:INTERRUPTED_NO_CHANGE ]]
[[ $(apo_state_get APPLY_STATUS) == INTERRUPTED_NO_CHANGE ]]

# A successful apply updates the live normal clocks without destroying the
# immutable stock evidence used to validate a completed automatic run later.
reset_apply_fixture
apo_state_set AUTO_BASELINE_CPU 2400
apo_state_set AUTO_BASELINE_GPU 800
apo_state_set AUTO_BASELINE_VOLTAGE 0
apo_state_set AUTO_BASELINE_PROVENANCE verified-default
apo_state_set AUTO_BASELINE_EVIDENCE none
apo_apply_mark_applied "$NEW_HASH" 3000 900 0 /tmp/fixture-backup
[[ $(apo_state_get NORMAL_CPU) == 3000 ]]
[[ $(apo_state_get NORMAL_GPU) == 900 ]]
[[ $(apo_state_get AUTO_BASELINE_CPU) == 2400 ]]
[[ $(apo_state_get AUTO_BASELINE_GPU) == 800 ]]
[[ $(apo_state_get AUTO_BASELINE_VOLTAGE) == 0 ]]
[[ $(apo_state_get AUTO_BASELINE_PROVENANCE) == verified-default ]]
[[ $(apo_state_get AUTO_BASELINE_EVIDENCE) == none ]]

reset_apply_fixture
CURRENT_HASH=$NEW_HASH
apo_reconcile_interrupted_apply
[[ $ROUTE == EXPECTED ]]
[[ $(apo_state_get APPLY_STATUS) == APPLIED ]]

reset_apply_fixture
CURRENT_HASH=$NEW_HASH
apo_state_set APPLY_RECOVERY_ACTION ROLLBACK
apo_reconcile_interrupted_apply
[[ $ROUTE == ROLLBACK ]]
[[ $(apo_state_get APPLY_STATUS) == ROLLED_BACK ]]

reset_apply_fixture
CURRENT_HASH=$UNKNOWN_HASH
if apo_reconcile_interrupted_apply; then
    echo 'unknown permanent config was incorrectly accepted' >&2
    exit 1
fi
[[ $ROUTE == '' ]]
[[ $(apo_state_get APPLY_STATUS) == FAILED_NEEDS_MANUAL_RECOVERY ]]
[[ $(apo_state_get APPLY_FAILURE_REASON) == *'matches neither'* ]]

reset_apply_fixture
apo_state_set APPLY_BACKUP /tmp/untrusted-backup
if apo_reconcile_interrupted_apply; then
    echo 'inconsistent interrupted apply plan was incorrectly accepted' >&2
    exit 1
fi
[[ $(apo_state_get APPLY_STATUS) == FAILED_NEEDS_MANUAL_RECOVERY ]]

reset_apply_fixture
SSH_READY=0
if apo_reconcile_interrupted_apply; then
    echo 'unreachable interrupted apply was incorrectly treated as reconciled' >&2
    exit 1
fi
[[ $(apo_state_get APPLY_STATUS) == APPLYING ]]
[[ $(apo_state_get APPLY_FAILURE_REASON) == *'SSH did not become reachable'* ]]

# Both a fresh apply and an interrupted-apply reconciliation must pass the
# same current-schema tryboot-clear gate before inspecting or mutating permanent
# config. Every persisted ownership signal independently keeps that gate shut.
while IFS='|' read -r state_key state_value; do
    [[ -n $state_key ]] || continue
    reset_apply_fixture
    apo_state_set "$state_key" "$state_value"
    assert_fresh_apply_refused "$state_key" 'saved state says tryboot may be active, staged, or quarantined'

    reset_apply_fixture
    apo_state_set "$state_key" "$state_value"
    assert_reconcile_refused "$state_key" 'saved state says tryboot may be active, staged, or quarantined'
done <<CASES
TRYBOOT_EXPECTED|1
TRYBOOT_FILE_MAY_EXIST|1
TRYBOOT_OWNED_HASH|$OLD_HASH
TRYBOOT_RESERVATION_HASH|$NEW_HASH
TRYBOOT_OWNERSHIP_TOKEN|$(printf 'a%.0s' {1..64})
TRYBOOT_QUARANTINE_PATH|/boot/.autopioverclock-tryboot-$(printf 'b%.0s' {1..64}).quarantine
CASES

reset_apply_fixture
LIVE_TRYBOOT_FLAG=00000001
assert_fresh_apply_refused live-tryboot 'requires a verified normal boot; live tryboot state is 00000001'
reset_apply_fixture
LIVE_TRYBOOT_FLAG=00000001
assert_reconcile_refused live-tryboot 'requires a verified normal boot; live tryboot state is 00000001'

for path_state in present unreadable; do
    reset_apply_fixture
    TRYBOOT_PATH_STATE=$path_state
    assert_fresh_apply_refused "$path_state-tryboot-path" 'refused while any tryboot path exists or its absence cannot be verified'
    reset_apply_fixture
    TRYBOOT_PATH_STATE=$path_state
    assert_reconcile_refused "$path_state-tryboot-path" 'refused while any tryboot path exists or its absence cannot be verified'
done

reset_apply_fixture
apo_state_set RUN_SCHEMA 4
assert_fresh_apply_refused old-run-schema 'run created before the current tryboot-ownership safety schema'
reset_apply_fixture
apo_state_set RUN_SCHEMA 4
assert_reconcile_refused old-run-schema 'run created before the current tryboot-ownership safety schema'

# A verification reboot checks the hash before and after boot, proves normal
# boot state, runs health against the candidate hash, and then restores the
# controller's protected hash until the APPLIED state is committed.
reset_apply_fixture
APO_BOOT_CONFIG=/boot/config.txt
APO_GPU_KEY=gpu_freq
APO_PERMANENT_CONFIG_HASH=$OLD_HASH
REBOOT_COMMAND=''
HEALTH_HASH=''
HEALTH_CREATES_TRYBOOT=0
CURRENT_HASH=$NEW_HASH
apo_wait_for_ssh() { return 0; }
apo_remote_boot_id() { printf old-boot-id; }
apo_remote_worker() { REBOOT_COMMAND=$2; return 0; }
apo_wait_for_new_boot() { [[ $1 == old-boot-id && $2 == 30 ]]; printf new-boot-id; }
apo_health_check() {
    HEALTH_HASH=$APO_PERMANENT_CONFIG_HASH
    (( HEALTH_CREATES_TRYBOOT == 0 )) || TRYBOOT_PATH_STATE=present
    return 0
}
apo_apply_force_normal_boot_and_health "$NEW_HASH" 3000 900 50000 apply-fixture
[[ $REBOOT_COMMAND == reboot-normal ]]
[[ $HEALTH_HASH == "$NEW_HASH" ]]
[[ $APO_PERMANENT_CONFIG_HASH == "$OLD_HASH" ]]
[[ $(apo_state_get APPLY_BOOT_ID) == new-boot-id ]]
[[ $(apo_state_get NORMAL_BOOT_ID) == new-boot-id ]]

# A clean health result is not enough if tryboot evidence appears while that
# health gate is running. The controller must recheck before recording success.
reset_apply_fixture
APO_BOOT_CONFIG=/boot/config.txt
APO_GPU_KEY=gpu_freq
APO_PERMANENT_CONFIG_HASH=$OLD_HASH
REBOOT_COMMAND=''
HEALTH_HASH=''
HEALTH_CREATES_TRYBOOT=1
CURRENT_HASH=$NEW_HASH
if apo_apply_force_normal_boot_and_health "$NEW_HASH" 3000 900 50000 apply-health-race; then
    echo 'tryboot evidence appearing during verification health was incorrectly accepted' >&2
    exit 1
fi
[[ $HEALTH_HASH == "$NEW_HASH" ]]
[[ $APO_PERMANENT_CONFIG_HASH == "$OLD_HASH" ]]
[[ $APO_LAST_REASON == *'refused while any tryboot path exists or its absence cannot be verified'* ]]

# Exercise the real controller rollback function after the earlier reconcile
# routing fixtures. It must pass the persisted proposed/destination hash as the
# worker's third rollback argument, and retain the rollback checkpoint when the
# worker catches a destination race.
eval "$ORIGINAL_APO_APPLY_RESTORE_OLD_CONFIG"
declare -ag ROLLBACK_WORKER_ARGS=()
declare -Ag APO_WORKER_DATA=()
ROLLBACK_WORKER_FAILURE=''
apo_run_worker_capture() {
    ROLLBACK_WORKER_ARGS=("$@")
    APO_LAST_WORKER_LOG=/tmp/autopioverclock-rollback-fixture.log
    if [[ -n $ROLLBACK_WORKER_FAILURE ]]; then
        APO_LAST_REASON=$ROLLBACK_WORKER_FAILURE
        return 1
    fi
    CURRENT_HASH=$OLD_HASH
}
apo_parse_data_file() {
    local -n parsed_data=$2
    parsed_data=()
    parsed_data[RESTORED_HASH]=$OLD_HASH
}
reset_apply_fixture
HEALTH_CREATES_TRYBOOT=0
CURRENT_HASH=$NEW_HASH
apo_apply_restore_old_config "$OLD_HASH" /var/lib/autopioverclock/backups/config-fixture-run-before-apply.txt 'fixture rollback'
[[ ${#ROLLBACK_WORKER_ARGS[@]} == 5 ]]
[[ ${ROLLBACK_WORKER_ARGS[0]} == apply-rollback ]]
[[ ${ROLLBACK_WORKER_ARGS[1]} == restore-backup ]]
[[ ${ROLLBACK_WORKER_ARGS[2]} == /var/lib/autopioverclock/backups/config-fixture-run-before-apply.txt ]]
[[ ${ROLLBACK_WORKER_ARGS[3]} == "$OLD_HASH" ]]
[[ ${ROLLBACK_WORKER_ARGS[4]} == "$NEW_HASH" ]]
[[ $(apo_state_get APPLY_STATUS '') == ROLLED_BACK ]]

reset_apply_fixture
apo_state_set APPLY_RECOVERY_ACTION ROLLBACK
HEALTH_CREATES_TRYBOOT=0
CURRENT_HASH=$NEW_HASH
ROLLBACK_WORKER_ARGS=()
ROLLBACK_WORKER_FAILURE='Permanent config changed at the rollback mutation boundary; refusing restoration.'
if apo_reconcile_interrupted_apply; then
    echo 'controller accepted a worker-detected pre-replacement rollback destination race' >&2
    exit 1
fi
[[ ${#ROLLBACK_WORKER_ARGS[@]} == 5 ]]
[[ ${ROLLBACK_WORKER_ARGS[4]} == "$NEW_HASH" ]]
[[ $(apo_state_get APPLY_STATUS '') == APPLYING ]]
[[ $(apo_state_get APPLY_RECOVERY_ACTION '') == ROLLBACK ]]
[[ $(apo_state_get APPLY_FAILURE_REASON '') == *'rollback mutation boundary'* ]]
ROLLBACK_WORKER_FAILURE=''

for worker_file in "$ROOT/workers/debian-worker.sh" "$ROOT/workers/batocera-worker.sh"; do
    grep -q 'expected_old_hash=.*expected_new_hash=' "$worker_file"
    grep -q 'cmd_restore_backup()' "$worker_file"
    grep -q 'Permanent config backup.*persisted pre-apply hash' "$worker_file"
    assert_worker_locked_apply_dispatch "$worker_file"
    assert_worker_tryboot_detector "$worker_file"
    assert_worker_apply_mutation_boundary "$worker_file"
done
grep -q "trap 'apply_signal_cleanup 143' TERM" "$ROOT/workers/batocera-worker.sh"
grep -q 'remount_boot_ro().*boot_mount_has_option ro' "$ROOT/workers/batocera-worker.sh"

# Typed confirmation can leave a real race window. Change the mocked target
# path from absent to present inside confirmation and prove upload/mutation is
# refused by the immediate post-confirmation recheck.
APPLY_CONFIRM_TMP=$(mktemp -d)
reset_apply_fixture
apo_state_set APPLY_STATUS NOT_APPLIED
apo_state_set VALIDATED 1
apo_state_set VALIDATION_SCHEMA "$APO_CURRENT_VALIDATION_SCHEMA"
apo_state_set STATUS PASS
apo_state_set PHASE COMPLETE
apo_state_set CFG_FINAL_DURATION_S "$APO_MIN_FINAL_DURATION_S"
apo_state_set VALIDATION_DURATION_S "$APO_MIN_FINAL_DURATION_S"
APO_BOOT_CONFIG=/boot/config.txt
APO_GPU_KEY=gpu_freq
APO_TEST_VOLTAGE=0
APO_TARGET_SLUG=fixture-target
APO_RUN_PREFIX="$APPLY_CONFIRM_TMP/fixture-run"
APO_REMOTE_WORK_DIR=/tmp/autopioverclock-fixture
APO_PERMANENT_CONFIG_HASH=$OLD_HASH
apo_verify_permanent_hash() { return 0; }
apo_remote_root() {
    local command_text=$1 expected_probe
    expected_probe="if [ -e $(apo_sh_quote "$APO_TRYBOOT_CONFIG") ] || [ -L $(apo_sh_quote "$APO_TRYBOOT_CONFIG") ]; then printf present; else printf absent; fi"
    if [[ $command_text == "$expected_probe" ]]; then
        printf '%s' "$TRYBOOT_PATH_STATE"
    elif [[ $command_text == "cat $(apo_sh_quote "$APO_BOOT_CONFIG")" ]]; then
        printf 'current fixture config\n'
    else
        return 97
    fi
}
apo_remote_worker() {
    [[ $2 == render-permanent ]] || return 98
    printf 'different proposed fixture config\n'
}
apo_confirm_exact() {
    TRYBOOT_PATH_STATE=present
    return 0
}
apo_remote_upload_root() {
    printf 'MUTATION_REACHED\n' >&2
    return 1
}
apo_remote_boot_id() { printf old-boot-id; }
confirmation_output=''
set +e
confirmation_output=$(apo_apply_recommendation 2>&1)
confirmation_status=$?
set -e
if (( confirmation_status != APO_EXIT_APPLY )); then
    printf 'post-confirmation tryboot race exited %s instead of %s:\n%s\n' \
        "$confirmation_status" "$APO_EXIT_APPLY" "$confirmation_output" >&2
    exit 1
fi
[[ $confirmation_output == *'Tryboot state changed while the apply confirmation was pending:'* ]]
[[ $confirmation_output != *MUTATION_REACHED* ]]
rm -f -- "$APPLY_CONFIRM_TMP/fixture-run-apply-proposed-config.txt" \
    "$APPLY_CONFIRM_TMP/fixture-run-apply-current-config.txt" \
    "$APPLY_CONFIRM_TMP/fixture-run-apply.diff"
rmdir -- "$APPLY_CONFIRM_TMP"

# A legacy VALIDATED=1 marker is not enough to unlock permanent apply after
# the safety gates changed; the current validation schema is mandatory.
legacy_output=''
set +e
legacy_output=$(
(
    APO_STATE=()
    APO_TRYBOOT_CONFIG=/boot/tryboot.txt
    LIVE_TRYBOOT_FLAG=00000000
    TRYBOOT_PATH_STATE=absent
    apo_state_set RUN_SCHEMA "$APO_CURRENT_RUN_SCHEMA"
    apo_state_set VALIDATED 1
    apo_state_set STATUS PASS
    apo_state_set PHASE COMPLETE
    apo_state_set VALIDATION_SCHEMA ''
    apo_apply_recommendation
) 2>&1
)
legacy_status=$?
set -e
if (( legacy_status != APO_EXIT_APPLY )); then
    echo 'legacy validation schema was incorrectly accepted for apply' >&2
    exit 1
fi
[[ $legacy_output == *'Only a fully validated run produced by the current safety gates can be applied.'* ]]

short_output=''
set +e
short_output=$(
(
    APO_STATE=()
    APO_TRYBOOT_CONFIG=/boot/tryboot.txt
    LIVE_TRYBOOT_FLAG=00000000
    TRYBOOT_PATH_STATE=absent
    apo_state_set RUN_SCHEMA "$APO_CURRENT_RUN_SCHEMA"
    apo_state_set VALIDATED 1
    apo_state_set STATUS PASS
    apo_state_set PHASE COMPLETE
    apo_state_set VALIDATION_SCHEMA "$APO_CURRENT_VALIDATION_SCHEMA"
    apo_state_set CFG_FINAL_DURATION_S 60
    apo_state_set VALIDATION_DURATION_S 60
    apo_apply_recommendation
) 2>&1
)
short_status=$?
set -e
if (( short_status != APO_EXIT_APPLY )); then
    echo 'sub-one-hour validation was incorrectly accepted for apply' >&2
    exit 1
fi
[[ $short_output == *'Permanent apply requires completed final-endurance evidence for the saved duration plan.'* ]]
grep -q 'apo_apply_force_normal_boot_and_health.*apply-existing-config-health' "$ROOT/lib/apply.sh"

printf 'test_apply_resume: PASS\n'
