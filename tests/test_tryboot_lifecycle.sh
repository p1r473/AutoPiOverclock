#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

fail() {
    printf 'test_tryboot_lifecycle: %s\n' "$*" >&2
    exit 1
}

# Both remote workers must classify the path itself. In particular, -e alone
# is insufficient because it follows symlinks and misses dangling symlinks.
# Only a regular file is hashed; all other evidence is deliberately literal.
for worker_name in debian batocera; do
    WORKER="$ROOT/workers/${worker_name}-worker.sh" CASE_ROOT="$TEMP_DIR/discovery-$worker_name" bash -c '
        set -Eeuo pipefail
        mkdir -p "$CASE_ROOT"
        printf "[all]\narm_freq=2400\nv3d_freq=960\n" > "$CASE_ROOT/config.txt"
        APO_WORKER_LIBRARY_ONLY=1 source "$WORKER"
        declare -F inspect_tryboot_path >/dev/null || {
            printf "%s does not expose inspect_tryboot_path\n" "$WORKER" >&2
            exit 1
        }

        clear_fixture_path() {
            if [[ -L $CASE_ROOT/tryboot.txt || -f $CASE_ROOT/tryboot.txt || -p $CASE_ROOT/tryboot.txt ]]; then
                rm -f -- "$CASE_ROOT/tryboot.txt"
            elif [[ -d $CASE_ROOT/tryboot.txt ]]; then
                rmdir -- "$CASE_ROOT/tryboot.txt"
            fi
        }

        assert_evidence() {
            local wanted_exists=$1 wanted_type=$2 wanted_hash=$3
            local actual_exists=unset actual_type=unset actual_hash=unset
            inspect_tryboot_path "$CASE_ROOT/tryboot.txt" actual_exists actual_type actual_hash
            [[ $actual_exists == "$wanted_exists" ]] || {
                printf "exists: expected %s, got %s\n" "$wanted_exists" "$actual_exists" >&2
                exit 1
            }
            [[ $actual_type == "$wanted_type" ]] || {
                printf "type: expected %s, got %s\n" "$wanted_type" "$actual_type" >&2
                exit 1
            }
            [[ $actual_hash == "$wanted_hash" ]] || {
                printf "hash: expected %s, got %s\n" "$wanted_hash" "$actual_hash" >&2
                exit 1
            }
        }

        clear_fixture_path
        assert_evidence 0 absent unavailable

        printf "owned candidate evidence\n" > "$CASE_ROOT/tryboot.txt"
        expected_hash=$(sha256sum "$CASE_ROOT/tryboot.txt" | awk "{print \$1}")
        assert_evidence 1 regular "$expected_hash"

        : > "$CASE_ROOT/tryboot.txt"
        expected_hash=$(sha256sum "$CASE_ROOT/tryboot.txt" | awk "{print \$1}")
        [[ $expected_hash =~ ^[0-9a-f]{64}$ ]]
        assert_evidence 1 regular "$expected_hash"

        clear_fixture_path
        ln -s -- "$CASE_ROOT/config.txt" "$CASE_ROOT/tryboot.txt"
        assert_evidence 1 symlink unavailable

        clear_fixture_path
        ln -s -- "$CASE_ROOT/does-not-exist" "$CASE_ROOT/tryboot.txt"
        assert_evidence 1 symlink unavailable

        clear_fixture_path
        mkdir "$CASE_ROOT/tryboot.txt"
        assert_evidence 1 directory unavailable

        clear_fixture_path
        mkfifo "$CASE_ROOT/tryboot.txt"
        assert_evidence 1 other unavailable
        clear_fixture_path
    '
done

# Every mutating worker command is serialized by one target-side lock. Prove
# that a held lock excludes a second owner and is released on success, command
# failure, and an abrupt EXIT from the protected command.
for worker_name in debian batocera; do
    WORKER="$ROOT/workers/${worker_name}-worker.sh" CASE_ROOT="$TEMP_DIR/mutation-lock-$worker_name" WORKER_NAME="$worker_name" bash -c '
        set -Eeuo pipefail
        mkdir -p "$CASE_ROOT"
        APO_WORKER_LIBRARY_ONLY=1 source "$WORKER"
        MUTATION_LOCK_DIR="$CASE_ROOT/target-mutation.lock"
        nested_rejected=0
        nested_command() { printf "nested command must not run\n" >&2; return 99; }
        locked_success() {
            [[ -d $MUTATION_LOCK_DIR && ! -L $MUTATION_LOCK_DIR ]]
            [[ $(<"$MUTATION_LOCK_DIR/owner") == first-owner ]]
            if run_with_mutation_lock second-owner RECOVERY_FAILURE nested_command > "$CASE_ROOT/nested.out"; then
                printf "%s worker admitted a concurrent mutation\n" "$WORKER_NAME" >&2
                return 1
            fi
            nested_rejected=1
        }
        run_with_mutation_lock first-owner RECOVERY_FAILURE locked_success
        [[ $nested_rejected == 1 ]]
        grep -q "APO_RESULT_CLASS=RECOVERY_FAILURE" "$CASE_ROOT/nested.out"
        [[ ! -e $MUTATION_LOCK_DIR && ! -L $MUTATION_LOCK_DIR ]]
        [[ $MUTATION_LOCK_HELD == 0 && -z $MUTATION_LOCK_OWNER ]]

        locked_failure() { return 7; }
        if run_with_mutation_lock failure-owner RECOVERY_FAILURE locked_failure; then
            printf "%s worker suppressed a locked command failure\n" "$WORKER_NAME" >&2
            exit 1
        else
            locked_rc=$?
        fi
        [[ $locked_rc == 7 ]]
        [[ ! -e $MUTATION_LOCK_DIR && ! -L $MUTATION_LOCK_DIR ]]

        set +e
        (
            locked_exit() { exit 9; }
            run_with_mutation_lock exit-owner RECOVERY_FAILURE locked_exit
        )
        exit_rc=$?
        set -e
        [[ $exit_rc == 9 ]]
        [[ ! -e $MUTATION_LOCK_DIR && ! -L $MUTATION_LOCK_DIR ]]

        reboot_dispatched=0
        cmd_reboot_normal() {
            [[ -d $MUTATION_LOCK_DIR && ! -L $MUTATION_LOCK_DIR ]]
            [[ $(<"$MUTATION_LOCK_DIR/owner") == reboot-* ]]
            reboot_dispatched=1
        }
        main reboot-normal
        [[ $reboot_dispatched == 1 ]]
        [[ ! -e $MUTATION_LOCK_DIR && ! -L $MUTATION_LOCK_DIR ]]

        mkdir -- "$MUTATION_LOCK_DIR"
        printf "foreign-owner\n" > "$MUTATION_LOCK_DIR/owner"
        if run_with_mutation_lock blocked-owner RECOVERY_FAILURE nested_command > "$CASE_ROOT/blocked.out"; then
            printf "%s worker claimed a foreign mutation lock\n" "$WORKER_NAME" >&2
            exit 1
        fi
        [[ $(<"$MUTATION_LOCK_DIR/owner") == foreign-owner ]]
        grep -q "APO_RESULT_CLASS=RECOVERY_FAILURE" "$CASE_ROOT/blocked.out"
        rm -f -- "$MUTATION_LOCK_DIR/owner"
        rmdir -- "$MUTATION_LOCK_DIR"

        # Batocera must retain the lock when restoring /boot read-only fails.
        # Once a later cleanup verifies RO, that exact owner can release it.
        if [[ $WORKER_NAME == batocera ]]; then
            ro_restore_allowed=0
            : > "$CASE_ROOT/ro-attempts"
            sync() { return 0; }
            remount_boot_ro() {
                printf "attempt\n" >> "$CASE_ROOT/ro-attempts"
                (( ro_restore_allowed == 1 ))
            }
            locked_ro_failure() {
                apply_install_traps
                APO_APPLY_BOOT_RW=1
                apply_remount_boot_ro
            }
            if run_with_mutation_lock rw-owner APPLY_FAILURE locked_ro_failure > "$CASE_ROOT/ro-failure.out"; then
                printf "Batocera accepted a failed read-only restoration\n" >&2
                exit 1
            fi
            [[ $APO_APPLY_BOOT_RW == 1 && $MUTATION_LOCK_HELD == 1 ]]
            [[ -d $MUTATION_LOCK_DIR && ! -L $MUTATION_LOCK_DIR ]]
            [[ $(<"$MUTATION_LOCK_DIR/owner") == rw-owner ]]
            [[ $(wc -l < "$CASE_ROOT/ro-attempts") == 1 ]]

            ro_restore_allowed=1
            apply_exit_cleanup
            [[ $APO_APPLY_BOOT_RW == 0 && $MUTATION_LOCK_HELD == 0 ]]
            [[ ! -e $MUTATION_LOCK_DIR && ! -L $MUTATION_LOCK_DIR ]]
            [[ $(wc -l < "$CASE_ROOT/ro-attempts") == 2 ]]
            apply_clear_traps

            # A failed durability sync is still a command failure, but it must
            # never prevent the RO remount attempt. Verified RO clears the RW
            # state and permits the wrapper to release its exact lock owner.
            sync_calls=0
            : > "$CASE_ROOT/sync-fail-ro-attempts"
            sync() { sync_calls=$((sync_calls + 1)); return 1; }
            remount_boot_ro() { printf "attempt\n" >> "$CASE_ROOT/sync-fail-ro-attempts"; return 0; }
            locked_sync_failure() {
                apply_install_traps
                APO_APPLY_BOOT_RW=1
                if ! apply_remount_boot_ro; then
                    emit_result APPLY_FAILURE "Fixture durability sync failed before verified RO restoration."
                    return 1
                fi
            }
            if run_with_mutation_lock sync-fail-owner APPLY_FAILURE locked_sync_failure > "$CASE_ROOT/sync-fail.out"; then
                printf "Batocera suppressed a pre-remount sync failure\n" >&2
                exit 1
            fi
            grep -q "APO_RESULT_CLASS=APPLY_FAILURE" "$CASE_ROOT/sync-fail.out"
            [[ $sync_calls == 1 ]]
            [[ $(wc -l < "$CASE_ROOT/sync-fail-ro-attempts") == 1 ]]
            [[ $APO_APPLY_BOOT_RW == 0 && $MUTATION_LOCK_HELD == 0 ]]
            [[ ! -e $MUTATION_LOCK_DIR && ! -L $MUTATION_LOCK_DIR ]]

            # The EXIT cleanup follows the same rule: release after verified
            # RO even when sync failed, while preserving the nonzero result at
            # the original mutation boundary.
            sync_calls=0
            : > "$CASE_ROOT/exit-sync-fail-ro-attempts"
            remount_boot_ro() { printf "attempt\n" >> "$CASE_ROOT/exit-sync-fail-ro-attempts"; return 0; }
            mutation_lock_acquire exit-sync-owner
            apply_install_traps
            APO_APPLY_BOOT_RW=1
            apply_exit_cleanup
            [[ $sync_calls == 1 ]]
            [[ $(wc -l < "$CASE_ROOT/exit-sync-fail-ro-attempts") == 1 ]]
            [[ $APO_APPLY_BOOT_RW == 0 && $MUTATION_LOCK_HELD == 0 ]]
            [[ ! -e $MUTATION_LOCK_DIR && ! -L $MUTATION_LOCK_DIR ]]
            apply_clear_traps
        fi
    '
done

# Controller evidence must be internally consistent. An explicit dry-run may
# report a collision, while mutating prepare and overclock refuse every kind of
# pre-existing path.
(
    APO_ROOT=$ROOT
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    source "$ROOT/lib/detect.sh"
    apo_config_defaults
    APO_MODE_EFFECTIVE=headless

    context_with_evidence() {
        local exists=$1 type=$2 hash=$3 command_name=$4 dry_run=${5:-0}
        APO_COMMAND=$command_name
        APO_DRY_RUN=$dry_run
        APO_DISCOVERY=(
            [BOOT_CONFIG]=/boot/config.txt
            [TRYBOOT_CONFIG]=/boot/tryboot.txt
            [TRYBOOT_EXISTS]="$exists"
            [TRYBOOT_TYPE]="$type"
            [TRYBOOT_HASH]="$hash"
            [BOOT_MOUNT]=/boot
            [GPU_KEY]=v3d_freq
            [NORMAL_CPU]=2400
            [NORMAL_GPU]=960
            [NORMAL_VOLTAGE]=0
            [PERMANENT_HASH]=$(printf 'b%.0s' {1..64})
        )
        apo_context_from_discovery
    }

    valid_hash=$(printf 'a%.0s' {1..64})
    context_with_evidence 0 absent unavailable prepare >/dev/null
    context_with_evidence 1 regular "$valid_hash" prepare 1 >/dev/null
    context_with_evidence 1 symlink unavailable prepare 1 >/dev/null
    context_with_evidence 1 directory unavailable prepare 1 >/dev/null
    context_with_evidence 1 other unavailable prepare 1 >/dev/null

    for type in regular symlink directory other; do
        hash=unavailable
        [[ $type == regular ]] && hash=$valid_hash
        if (context_with_evidence 1 "$type" "$hash" run) >/dev/null 2>&1; then
            fail "live run accepted pre-existing tryboot type $type"
        fi
        if (context_with_evidence 1 "$type" "$hash" prepare) >/dev/null 2>&1; then
            fail "mutating prepare accepted pre-existing tryboot type $type"
        fi
    done

    malformed_cases=(
        '0 regular aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        '0 absent aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        '1 absent unavailable'
        '1 regular unavailable'
        '1 symlink aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        '1 unknown unavailable'
    )
    for malformed in "${malformed_cases[@]}"; do
        read -r exists type hash <<< "$malformed"
        if (context_with_evidence "$exists" "$type" "$hash" prepare 1) >/dev/null 2>&1; then
            fail "controller accepted inconsistent tryboot evidence: $malformed"
        fi
    done

    APO_CPU_CANDIDATES=(2400)
    if (context_with_evidence 0 absent unavailable prepare) >/dev/null 2>&1; then
        fail 'controller accepted a CPU candidate at the discovered normal clock'
    fi
    APO_CPU_CANDIDATES=(2500)
    context_with_evidence 0 absent unavailable prepare >/dev/null
    APO_CPU_CANDIDATES=()
    APO_GPU_CANDIDATES=(960)
    if (context_with_evidence 0 absent unavailable prepare) >/dev/null 2>&1; then
        fail 'controller accepted a GPU candidate at the discovered normal clock'
    fi
    APO_GPU_CANDIDATES=(970)
    context_with_evidence 0 absent unavailable prepare >/dev/null
    APO_GPU_CANDIDATES=()
)

# Candidate planning is read-only and independently reproducible. It must bind
# both hashes and the quarantine path to a valid random ownership token.
for worker_name in debian batocera; do
    WORKER="$ROOT/workers/${worker_name}-worker.sh" CASE_ROOT="$TEMP_DIR/plan-$worker_name" WORKER_NAME="$worker_name" bash -c '
        set -Eeuo pipefail
        mkdir -p "$CASE_ROOT"
        printf "[all]\narm_freq=2400\nv3d_freq=960\n" > "$CASE_ROOT/config.txt"
        permanent_hash=$(sha256sum "$CASE_ROOT/config.txt" | awk "{print \$1}")
        ownership_token=$(printf "1%.0s" {1..64})
        APO_WORKER_LIBRARY_ONLY=1 source "$WORKER"
        tryboot_path_allowed() { return 0; }
        output=$(cmd_plan_candidate "$CASE_ROOT/config.txt" "$CASE_ROOT/tryboot.txt" v3d_freq 2500 970 0 "$permanent_hash" fixture-run "$ownership_token")
        [[ $output == *"APO_RESULT_CLASS=PASS"* ]]
        decode_data() {
            local wanted=$1 encoded
            encoded=$(awk -F "\t" -v wanted="$wanted" "\$1 == \"APO_DATA\" && \$2 == wanted {print \$3; exit}" <<< "$output")
            printf "%s" "$encoded" | base64 --decode
        }
        planned_hash=$(decode_data TRYBOOT_HASH)
        reservation_hash=$(decode_data TRYBOOT_RESERVATION_HASH)
        quarantine_path=$(decode_data TRYBOOT_QUARANTINE)
        [[ $planned_hash =~ ^[0-9a-f]{64}$ ]]
        [[ $reservation_hash =~ ^[0-9a-f]{64}$ ]]
        [[ $quarantine_path == "$CASE_ROOT/.autopioverclock-remove-$ownership_token" ]]
        render_tryboot_config "$CASE_ROOT/config.txt" "$CASE_ROOT/expected.txt" 2500 970 v3d_freq 0 fixture-run "$ownership_token"
        [[ $(sha256sum "$CASE_ROOT/expected.txt" | awk "{print \$1}") == "$planned_hash" ]]
        [[ $(render_tryboot_reservation fixture-run "$ownership_token" | sha256sum | awk "{print \$1}") == "$reservation_hash" ]]
        [[ ! -e $CASE_ROOT/tryboot.txt && ! -L $CASE_ROOT/tryboot.txt ]]
        [[ ! -e $quarantine_path && ! -L $quarantine_path ]]
        [[ $(sha256sum "$CASE_ROOT/config.txt" | awk "{print \$1}") == "$permanent_hash" ]]

        bad_hash=$(printf "f%.0s" {1..64})
        if cmd_plan_candidate "$CASE_ROOT/config.txt" "$CASE_ROOT/tryboot.txt" v3d_freq 2500 970 0 "$bad_hash" fixture-run "$ownership_token" >/dev/null 2>&1; then
            printf "%s planned a candidate against the wrong permanent hash\n" "$WORKER_NAME" >&2
            exit 1
        fi
        if cmd_plan_candidate "$CASE_ROOT/config.txt" "$CASE_ROOT/tryboot.txt" v3d_freq 2500 970 0 "$permanent_hash" fixture-run short-token >/dev/null 2>&1; then
            printf "%s accepted a malformed ownership token\n" "$WORKER_NAME" >&2
            exit 1
        fi
        printf "foreign quarantine\n" > "$quarantine_path"
        quarantine_hash=$(sha256sum "$quarantine_path" | awk "{print \$1}")
        if cmd_plan_candidate "$CASE_ROOT/config.txt" "$CASE_ROOT/tryboot.txt" v3d_freq 2500 970 0 "$permanent_hash" fixture-run "$ownership_token" >/dev/null 2>&1; then
            printf "%s planned through an occupied token quarantine\n" "$WORKER_NAME" >&2
            exit 1
        fi
        [[ $(sha256sum "$quarantine_path" | awk "{print \$1}") == "$quarantine_hash" ]]
        [[ ! -e $CASE_ROOT/tryboot.txt && ! -L $CASE_ROOT/tryboot.txt ]]
        [[ $(sha256sum "$CASE_ROOT/config.txt" | awk "{print \$1}") == "$permanent_hash" ]]
    '
done

# Candidate preparation is a no-clobber operation. A file that appears before
# staging belongs to somebody else, even when its name is tryboot.txt.
for worker_name in debian batocera; do
    WORKER="$ROOT/workers/${worker_name}-worker.sh" CASE_ROOT="$TEMP_DIR/collision-$worker_name" WORKER_NAME="$worker_name" bash -c '
        set -Eeuo pipefail
        mkdir -p "$CASE_ROOT"
        printf "[all]\narm_freq=2400\nv3d_freq=960\n" > "$CASE_ROOT/config.txt"
        printf "do not replace this file\n" > "$CASE_ROOT/tryboot.txt"
        permanent_hash=$(sha256sum "$CASE_ROOT/config.txt" | awk "{print \$1}")
        original_tryboot_hash=$(sha256sum "$CASE_ROOT/tryboot.txt" | awk "{print \$1}")
        ownership_token=$(printf "2%.0s" {1..64})
        quarantine_path="$CASE_ROOT/.autopioverclock-remove-$ownership_token"
        APO_WORKER_LIBRARY_ONLY=1 source "$WORKER"
        tryboot_path_allowed() { return 0; }
        reset_recent_throttle() { :; }
        mktemp() {
            if [[ ${1:-} == /tmp/autopioverclock-tryboot.XXXXXX ]]; then
                command mktemp "$CASE_ROOT/.autopioverclock-tryboot.XXXXXX"
            else
                command mktemp "$@"
            fi
        }
        plan_file="$CASE_ROOT/planned.txt"
        render_tryboot_config "$CASE_ROOT/config.txt" "$plan_file" 2500 970 v3d_freq 0 collision-run "$ownership_token"
        expected_tryboot_hash=$(sha256sum "$plan_file" | awk "{print \$1}")
        expected_reservation_hash=$(render_tryboot_reservation collision-run "$ownership_token" | sha256sum | awk "{print \$1}")
        rm -f -- "$plan_file"
        : > "$CASE_ROOT/remounts"
        remount_boot_rw() { printf "rw\n" >> "$CASE_ROOT/remounts"; return 0; }
        remount_boot_ro() { printf "ro\n" >> "$CASE_ROOT/remounts"; return 0; }

        if cmd_prepare_candidate "$CASE_ROOT/config.txt" "$CASE_ROOT/tryboot.txt" v3d_freq 2500 970 0 "$permanent_hash" collision-run "$expected_tryboot_hash" "$expected_reservation_hash" "$ownership_token" "$quarantine_path" >/dev/null 2>&1; then
            printf "%s worker overwrote a pre-existing tryboot path\n" "$WORKER_NAME" >&2
            exit 1
        fi
        [[ $(sha256sum "$CASE_ROOT/tryboot.txt" | awk "{print \$1}") == "$original_tryboot_hash" ]]
        [[ $(sha256sum "$CASE_ROOT/config.txt" | awk "{print \$1}") == "$permanent_hash" ]]
        if find "$CASE_ROOT" -maxdepth 1 -name ".autopioverclock-tryboot.*" | grep -q .; then
            printf "%s worker left a staging file after collision\n" "$WORKER_NAME" >&2
            exit 1
        fi
        if [[ $WORKER_NAME == batocera ]]; then
            [[ $APO_APPLY_BOOT_RW == 0 ]]
            rw_count=$(grep -c "^rw$" "$CASE_ROOT/remounts" || true)
            ro_count=$(grep -c "^ro$" "$CASE_ROOT/remounts" || true)
            [[ $rw_count == "$ro_count" ]]
            if (( rw_count > 0 )); then [[ $(tail -1 "$CASE_ROOT/remounts") == ro ]]; fi
        fi

        # Also close the inspect/create race: a foreign path arriving after the
        # initial absence check must win, and the staged candidate must vanish.
        rm -f -- "$CASE_ROOT/tryboot.txt"
        : > "$CASE_ROOT/remounts"
        collision_injected=0
        sync() {
            if [[ ${1:-} == "$CASE_ROOT"/.autopioverclock-tryboot.* && $collision_injected == 0 ]]; then
                printf "race winner\n" > "$CASE_ROOT/tryboot.txt"
                collision_injected=1
            fi
            return 0
        }
        if cmd_prepare_candidate "$CASE_ROOT/config.txt" "$CASE_ROOT/tryboot.txt" v3d_freq 2500 970 0 "$permanent_hash" collision-run "$expected_tryboot_hash" "$expected_reservation_hash" "$ownership_token" "$quarantine_path" >/dev/null 2>&1; then
            printf "%s worker overwrote a tryboot race winner\n" "$WORKER_NAME" >&2
            exit 1
        fi
        [[ $collision_injected == 1 ]]
        [[ $(<"$CASE_ROOT/tryboot.txt") == "race winner" ]]
        [[ $(sha256sum "$CASE_ROOT/config.txt" | awk "{print \$1}") == "$permanent_hash" ]]
        if find "$CASE_ROOT" -maxdepth 1 -name ".autopioverclock-tryboot.*" | grep -q .; then
            printf "%s worker left a staging file after a no-clobber race\n" "$WORKER_NAME" >&2
            exit 1
        fi
        if [[ $WORKER_NAME == batocera ]]; then
            [[ $APO_APPLY_BOOT_RW == 0 ]]
            rw_count=$(grep -c "^rw$" "$CASE_ROOT/remounts" || true)
            ro_count=$(grep -c "^ro$" "$CASE_ROOT/remounts" || true)
            [[ $rw_count == "$ro_count" ]]
            if (( rw_count > 0 )); then [[ $(tail -1 "$CASE_ROOT/remounts") == ro ]]; fi
        fi

        # Replacing the pathname after its authenticated header was synced must
        # fail final ownership verification without touching the replacement.
        rm -f -- "$CASE_ROOT/tryboot.txt"
        : > "$CASE_ROOT/remounts"
        header_replaced=0
        sync() {
            if [[ ${1:-} == /proc/self/fd/* && $header_replaced == 0 ]]; then
                rm -f -- "$CASE_ROOT/tryboot.txt"
                printf "foreign after header sync\n" > "$CASE_ROOT/tryboot.txt"
                header_replaced=1
            fi
            return 0
        }
        if cmd_prepare_candidate "$CASE_ROOT/config.txt" "$CASE_ROOT/tryboot.txt" v3d_freq 2500 970 0 "$permanent_hash" collision-run "$expected_tryboot_hash" "$expected_reservation_hash" "$ownership_token" "$quarantine_path" >/dev/null 2>&1; then
            printf "%s worker accepted a pathname replacement after header sync\n" "$WORKER_NAME" >&2
            exit 1
        fi
        [[ $header_replaced == 1 ]]
        [[ $(<"$CASE_ROOT/tryboot.txt") == "foreign after header sync" ]]
        [[ ! -e $quarantine_path && ! -L $quarantine_path ]]
        if find "$CASE_ROOT" -maxdepth 1 -name ".autopioverclock-tryboot.*" | grep -q .; then
            printf "%s worker left staging data after header replacement\n" "$WORKER_NAME" >&2
            exit 1
        fi
        if [[ $WORKER_NAME == batocera ]]; then
            [[ $APO_APPLY_BOOT_RW == 0 ]]
            rw_count=$(grep -c "^rw$" "$CASE_ROOT/remounts" || true)
            ro_count=$(grep -c "^ro$" "$CASE_ROOT/remounts" || true)
            [[ $rw_count == "$ro_count" ]]
            if (( rw_count > 0 )); then [[ $(tail -1 "$CASE_ROOT/remounts") == ro ]]; fi
        fi
    '
done

# Planning must persist token-bound hashes and quarantine evidence before the
# boot filesystem is touched. Preparation and the immediate pre-trigger verify
# gate must both succeed before trigger-tryboot is dispatched.
for hash_mode in plan-final-missing plan-reservation-missing plan-quarantine-missing plan-quarantine-wrong plan-final-short plan-reservation-uppercase prepare-final-missing prepare-final-mismatch verify-failure; do
    HASH_MODE="$hash_mode" CASE_ROOT="$TEMP_DIR/controller-$hash_mode" REPO_ROOT="$ROOT" bash -c '
        set -Eeuo pipefail
        mkdir -p "$CASE_ROOT"
        APO_ROOT=$REPO_ROOT
        source "$REPO_ROOT/lib/common.sh"
        source "$REPO_ROOT/lib/state.sh"
        source "$REPO_ROOT/lib/classify.sh"
        source "$REPO_ROOT/lib/recovery.sh"
        APO_STATE=()
        apo_state_save() { :; }
        apo_event() { :; }
        APO_BOOT_CONFIG=/boot/config.txt
        APO_TRYBOOT_CONFIG=/boot/tryboot.txt
        APO_GPU_KEY=v3d_freq
        APO_TEST_VOLTAGE=0
        APO_PERMANENT_CONFIG_HASH=$(printf "b%.0s" {1..64})
        APO_RUN_ID=hash-fixture
        APO_REMOTE_WORKER=/tmp/fixture-worker
        APO_BOOT_TIMEOUT=10
        APO_BOOT_SETTLE_SECONDS=0
        APO_MAX_FAN=1
        plan_calls=0
        prepare_calls=0
        verify_calls=0
        trigger_calls=0
        fixture_planned_hash=$(printf "a%.0s" {1..64})
        fixture_reservation_hash=$(printf "c%.0s" {1..64})
        fixture_token_seen=
        fixture_quarantine=
        encode_record() {
            printf "APO_DATA\t%s\t%s\n" "$1" "$(printf "%s" "$2" | base64 | tr -d "\n")"
        }
        apo_run_worker_capture() {
            local worker_command=$2
            APO_LAST_WORKER_LOG="$CASE_ROOT/worker.log"
            : > "$APO_LAST_WORKER_LOG"
            case $worker_command in
                plan-candidate)
                    plan_calls=$((plan_calls + 1))
                    fixture_token_seen=${11}
                    [[ ${12} == candidate-max ]]
                    [[ $fixture_token_seen =~ ^[0-9a-f]{64}$ ]]
                    fixture_quarantine="/boot/.autopioverclock-remove-$fixture_token_seen"
                    case $HASH_MODE in
                        plan-final-missing)
                            encode_record TRYBOOT_RESERVATION_HASH "$fixture_reservation_hash"
                            encode_record TRYBOOT_QUARANTINE "$fixture_quarantine"
                            ;;
                        plan-reservation-missing)
                            encode_record TRYBOOT_HASH "$fixture_planned_hash"
                            encode_record TRYBOOT_QUARANTINE "$fixture_quarantine"
                            ;;
                        plan-quarantine-missing)
                            encode_record TRYBOOT_HASH "$fixture_planned_hash"
                            encode_record TRYBOOT_RESERVATION_HASH "$fixture_reservation_hash"
                            ;;
                        plan-quarantine-wrong)
                            encode_record TRYBOOT_HASH "$fixture_planned_hash"
                            encode_record TRYBOOT_RESERVATION_HASH "$fixture_reservation_hash"
                            encode_record TRYBOOT_QUARANTINE /boot/.autopioverclock-remove-wrong
                            ;;
                        plan-final-short)
                            encode_record TRYBOOT_HASH short
                            encode_record TRYBOOT_RESERVATION_HASH "$fixture_reservation_hash"
                            encode_record TRYBOOT_QUARANTINE "$fixture_quarantine"
                            ;;
                        plan-reservation-uppercase)
                            encode_record TRYBOOT_HASH "$fixture_planned_hash"
                            encode_record TRYBOOT_RESERVATION_HASH "$(printf "C%.0s" {1..64})"
                            encode_record TRYBOOT_QUARANTINE "$fixture_quarantine"
                            ;;
                        *)
                            encode_record TRYBOOT_HASH "$fixture_planned_hash"
                            encode_record TRYBOOT_RESERVATION_HASH "$fixture_reservation_hash"
                            encode_record TRYBOOT_QUARANTINE "$fixture_quarantine"
                            ;;
                    esac > "$APO_LAST_WORKER_LOG"
                    ;;
                prepare-candidate)
                    prepare_calls=$((prepare_calls + 1))
                    [[ ${13} == "$fixture_token_seen" && ${14} == "$fixture_quarantine" ]]
                    [[ ${15} == candidate-max ]]
                    case $HASH_MODE in
                        prepare-final-missing) : ;;
                        prepare-final-mismatch) encode_record TRYBOOT_HASH "$(printf "d%.0s" {1..64})" > "$APO_LAST_WORKER_LOG" ;;
                        *) encode_record TRYBOOT_HASH "$fixture_planned_hash" > "$APO_LAST_WORKER_LOG" ;;
                    esac
                    ;;
                verify-tryboot)
                    verify_calls=$((verify_calls + 1))
                    [[ ${8} == "$fixture_token_seen" ]]
                    if [[ $HASH_MODE == verify-failure ]]; then
                        APO_LAST_CLASS=RECOVERY_FAILURE
                        APO_LAST_REASON="fixture rejected pre-trigger ownership"
                        return 1
                    fi
                    ;;
                *) return 1 ;;
            esac
            return 0
        }
        apo_remote_boot_id() { printf old-boot; }
        apo_remote_worker() { trigger_calls=$((trigger_calls + 1)); }
        if apo_boot_candidate 2500 970 invalid-hash-fixture; then
            printf "candidate with %s hash evidence was accepted\n" "$HASH_MODE" >&2
            exit 1
        fi
        [[ $plan_calls == 1 ]]
        [[ $trigger_calls == 0 ]]
        case $HASH_MODE in
            plan-*)
                [[ $APO_LAST_CLASS == HARNESS_FAILURE ]]
                [[ $prepare_calls == 0 ]]
                [[ $verify_calls == 0 ]]
                [[ $(apo_state_get TRYBOOT_FILE_MAY_EXIST 0) == 0 ]]
                [[ -z $(apo_state_get TRYBOOT_OWNERSHIP_TOKEN "") ]]
                ;;
            prepare-*)
                [[ $APO_LAST_CLASS == RECOVERY_FAILURE ]]
                [[ $prepare_calls == 1 ]]
                [[ $(apo_state_get TRYBOOT_FILE_MAY_EXIST 0) == 1 ]]
                [[ $(apo_state_get TRYBOOT_OWNED_HASH "") == "$fixture_planned_hash" ]]
                [[ $(apo_state_get TRYBOOT_RESERVATION_HASH "") == "$fixture_reservation_hash" ]]
                [[ $(apo_state_get TRYBOOT_OWNERSHIP_TOKEN "") == "$fixture_token_seen" ]]
                [[ $(apo_state_get TRYBOOT_QUARANTINE_PATH "") == "$fixture_quarantine" ]]
                [[ -z $(apo_state_get TRYBOOT_LAST_HASH "") ]]
                [[ $verify_calls == 0 ]]
                ;;
            verify-failure)
                [[ $APO_LAST_CLASS == RECOVERY_FAILURE ]]
                [[ $prepare_calls == 1 && $verify_calls == 1 ]]
                [[ $(apo_state_get TRYBOOT_FILE_MAY_EXIST 0) == 1 ]]
                [[ $(apo_state_get TRYBOOT_OWNERSHIP_TOKEN "") == "$fixture_token_seen" ]]
                ;;
        esac
    '
done

HASH_MODE=valid CASE_ROOT="$TEMP_DIR/controller-valid" REPO_ROOT="$ROOT" bash -c '
    set -Eeuo pipefail
    mkdir -p "$CASE_ROOT"
    APO_ROOT=$REPO_ROOT
    source "$REPO_ROOT/lib/common.sh"
    source "$REPO_ROOT/lib/state.sh"
    source "$REPO_ROOT/lib/classify.sh"
    source "$REPO_ROOT/lib/recovery.sh"
    APO_STATE=()
    apo_state_save() { :; }
    apo_event() { :; }
    APO_BOOT_CONFIG=/boot/config.txt
    APO_TRYBOOT_CONFIG=/boot/tryboot.txt
    APO_GPU_KEY=v3d_freq
    APO_TEST_VOLTAGE=0
    APO_PERMANENT_CONFIG_HASH=$(printf "b%.0s" {1..64})
    APO_RUN_ID=hash-fixture
    APO_REMOTE_WORKER=/tmp/fixture-worker
    APO_BOOT_TIMEOUT=10
    APO_BOOT_SETTLE_SECONDS=0
    APO_MAX_FAN=1
    plan_calls=0
    prepare_calls=0
    verify_calls=0
    trigger_calls=0
    fixture_planned_hash=$(printf "a%.0s" {1..64})
    fixture_reservation_hash=$(printf "c%.0s" {1..64})
    fixture_token_seen=
    fixture_quarantine=
    encode_record() {
        printf "APO_DATA\t%s\t%s\n" "$1" "$(printf "%s" "$2" | base64 | tr -d "\n")"
    }
    apo_run_worker_capture() {
        local worker_command=$2
        APO_LAST_WORKER_LOG="$CASE_ROOT/worker.log"
        case $worker_command in
            plan-candidate)
                plan_calls=$((plan_calls + 1))
                fixture_token_seen=${11}
                [[ ${12} == candidate-max ]]
                fixture_quarantine="/boot/.autopioverclock-remove-$fixture_token_seen"
                {
                    encode_record TRYBOOT_HASH "$fixture_planned_hash"
                    encode_record TRYBOOT_RESERVATION_HASH "$fixture_reservation_hash"
                    encode_record TRYBOOT_QUARANTINE "$fixture_quarantine"
                } > "$APO_LAST_WORKER_LOG"
                ;;
            prepare-candidate)
                prepare_calls=$((prepare_calls + 1))
                [[ ${13} == "$fixture_token_seen" && ${14} == "$fixture_quarantine" ]]
                [[ ${15} == candidate-max ]]
                encode_record TRYBOOT_HASH "$fixture_planned_hash" > "$APO_LAST_WORKER_LOG"
                ;;
            verify-tryboot)
                verify_calls=$((verify_calls + 1))
                [[ ${8} == "$fixture_token_seen" ]]
                : > "$APO_LAST_WORKER_LOG"
                ;;
            *) return 1 ;;
        esac
        return 0
    }
    apo_remote_boot_id() { printf old-boot; }
    apo_remote_worker() {
        [[ $2 == trigger-tryboot ]]
        [[ ${8} == "$fixture_token_seen" ]]
        trigger_calls=$((trigger_calls + 1))
    }
    apo_wait_for_new_boot() { printf candidate-boot; }
    apo_post_reboot_handshake() { APO_REBOOT_HANDSHAKE_STAGE='complete'; APO_REBOOT_BOOT_ID=$(apo_wait_for_new_boot "$1" "$2"); }
    apo_remote_tryboot_flag() { printf 00000001; }
    apo_health_check() { return 0; }
    sleep() { :; }
    apo_boot_candidate 2500 970 valid-hash-fixture
    [[ $plan_calls == 1 ]]
    [[ $prepare_calls == 1 ]]
    [[ $verify_calls == 1 ]]
    [[ $trigger_calls == 1 ]]
    [[ $(apo_state_get TRYBOOT_OWNED_HASH "") == "$fixture_planned_hash" ]]
    [[ $(apo_state_get TRYBOOT_RESERVATION_HASH "") == "$fixture_reservation_hash" ]]
    [[ $(apo_state_get TRYBOOT_OWNERSHIP_TOKEN "") == "$fixture_token_seen" ]]
    [[ $(apo_state_get TRYBOOT_QUARANTINE_PATH "") == "$fixture_quarantine" ]]
    [[ $(apo_state_get TRYBOOT_LAST_HASH "") == "$fixture_planned_hash" ]]
'

# Two independent controller attempts with the same run ID must receive
# distinct ownership tokens and quarantine namespaces.
for attempt in 1 2; do
    CASE_ROOT="$TEMP_DIR/controller-token-$attempt" REPO_ROOT="$ROOT" bash -c '
        set -Eeuo pipefail
        mkdir -p "$CASE_ROOT"
        APO_ROOT=$REPO_ROOT
        source "$REPO_ROOT/lib/common.sh"
        source "$REPO_ROOT/lib/state.sh"
        source "$REPO_ROOT/lib/classify.sh"
        source "$REPO_ROOT/lib/recovery.sh"
        APO_STATE=()
        apo_state_save() { :; }
        apo_event() { :; }
        APO_BOOT_CONFIG=/boot/config.txt
        APO_TRYBOOT_CONFIG=/boot/tryboot.txt
        APO_GPU_KEY=v3d_freq
        APO_TEST_VOLTAGE=0
        APO_PERMANENT_CONFIG_HASH=$(printf "b%.0s" {1..64})
        APO_RUN_ID=same-run-id
        APO_REMOTE_WORKER=/tmp/fixture-worker
        fixture_planned_hash=$(printf "a%.0s" {1..64})
        fixture_reservation_hash=$(printf "c%.0s" {1..64})
        encode_record() { printf "APO_DATA\t%s\t%s\n" "$1" "$(printf "%s" "$2" | base64 | tr -d "\n")"; }
        apo_run_worker_capture() {
            local worker_command=$2 token quarantine
            APO_LAST_WORKER_LOG="$CASE_ROOT/worker.log"
            case $worker_command in
                plan-candidate)
                    token=${11}
                    quarantine="/boot/.autopioverclock-remove-$token"
                    {
                        encode_record TRYBOOT_HASH "$fixture_planned_hash"
                        encode_record TRYBOOT_RESERVATION_HASH "$fixture_reservation_hash"
                        encode_record TRYBOOT_QUARANTINE "$quarantine"
                    } > "$APO_LAST_WORKER_LOG"
                    ;;
                prepare-candidate)
                    encode_record TRYBOOT_HASH "$fixture_planned_hash" > "$APO_LAST_WORKER_LOG"
                    ;;
                *) return 1 ;;
            esac
        }
        apo_prepare_candidate 2500 970 token-isolation
        token=$(apo_state_get TRYBOOT_OWNERSHIP_TOKEN "")
        quarantine=$(apo_state_get TRYBOOT_QUARANTINE_PATH "")
        [[ $token =~ ^[0-9a-f]{64}$ ]]
        [[ $quarantine == "/boot/.autopioverclock-remove-$token" ]]
        printf "%s\n%s\n" "$token" "$quarantine" > "$CASE_ROOT/evidence"
    '
done
[[ $(sed -n '1p' "$TEMP_DIR/controller-token-1/evidence") != $(sed -n '1p' "$TEMP_DIR/controller-token-2/evidence") ]]
[[ $(sed -n '2p' "$TEMP_DIR/controller-token-1/evidence") != $(sed -n '2p' "$TEMP_DIR/controller-token-2/evidence") ]]

# Cleanup is token-isolated and crash-resumable. It quarantines by atomic
# no-clobber rename, revalidates ownership, and preserves every foreign race.
for worker_name in debian batocera; do
    WORKER="$ROOT/workers/${worker_name}-worker.sh" CASE_ROOT="$TEMP_DIR/cleanup-$worker_name" WORKER_NAME="$worker_name" bash -c '
        set -Eeuo pipefail
        mkdir -p "$CASE_ROOT"
        printf "[all]\narm_freq=2400\nv3d_freq=960\n" > "$CASE_ROOT/config.txt"
        permanent_hash=$(sha256sum "$CASE_ROOT/config.txt" | awk "{print \$1}")
        token_a=$(printf "3%.0s" {1..64})
        token_b=$(printf "4%.0s" {1..64})
        tryboot_path="$CASE_ROOT/tryboot.txt"
        quarantine_a="$CASE_ROOT/.autopioverclock-remove-$token_a"
        quarantine_b="$CASE_ROOT/.autopioverclock-remove-$token_b"
        APO_WORKER_LIBRARY_ONLY=1 source "$WORKER"
        tryboot_path_allowed() { return 0; }
        mount_state=ro
        boot_mount_has_option() { [[ $mount_state == "$1" ]]; }
        : > "$CASE_ROOT/remounts"
        mutate_on_rw=0
        sync() { return 0; }
        remount_boot_rw() {
            printf "rw\n" >> "$CASE_ROOT/remounts"
            mount_state=rw
            if (( mutate_on_rw == 1 )); then printf "# changed during remount\n" >> "$tryboot_path"; fi
            return 0
        }
        remount_boot_ro() { printf "ro\n" >> "$CASE_ROOT/remounts"; mount_state=ro; return 0; }

        assert_permanent_unchanged() {
            [[ $(sha256sum "$CASE_ROOT/config.txt" | awk "{print \$1}") == "$permanent_hash" ]]
        }
        assert_batocera_ro() {
            [[ $WORKER_NAME == batocera ]] || return 0
            [[ $APO_APPLY_BOOT_RW == 0 ]]
            local rw_count ro_count
            rw_count=$(grep -c "^rw$" "$CASE_ROOT/remounts" || true)
            ro_count=$(grep -c "^ro$" "$CASE_ROOT/remounts" || true)
            [[ $rw_count == "$ro_count" ]]
            if (( rw_count > 0 )); then [[ $(tail -1 "$CASE_ROOT/remounts") == ro ]]; fi
        }
        render_owned() {
            local run_id=$1 token=$2
            rm -f -- "$tryboot_path" "$quarantine_a" "$quarantine_b" "$CASE_ROOT/owned-displaced"
            render_tryboot_config "$CASE_ROOT/config.txt" "$tryboot_path" 2500 970 v3d_freq 0 "$run_id" "$token"
            owned_candidate_hash=$(sha256sum "$tryboot_path" | awk "{print \$1}")
            owned_reservation_hash=$(render_tryboot_reservation "$run_id" "$token" | sha256sum | awk "{print \$1}")
        }
        render_reservation() {
            local run_id=$1 token=$2 plan_file="$CASE_ROOT/plan.txt"
            rm -f -- "$tryboot_path" "$quarantine_a" "$quarantine_b" "$CASE_ROOT/owned-displaced"
            render_tryboot_config "$CASE_ROOT/config.txt" "$plan_file" 2500 970 v3d_freq 0 "$run_id" "$token"
            owned_candidate_hash=$(sha256sum "$plan_file" | awk "{print \$1}")
            rm -f -- "$plan_file"
            render_tryboot_reservation "$run_id" "$token" > "$tryboot_path"
            owned_reservation_hash=$(sha256sum "$tryboot_path" | awk "{print \$1}")
        }
        expect_preserved_failure() {
            local quarantine_path=$1 expected_hash=$2 expected_reservation_hash=$3 run_id=$4 token=$5 before_hash
            before_hash=$(sha256sum "$tryboot_path" | awk "{print \$1}")
            : > "$CASE_ROOT/remounts"
            if cmd_clear_tryboot "$CASE_ROOT/config.txt" "$tryboot_path" "$quarantine_path" "$permanent_hash" "$expected_hash" "$expected_reservation_hash" "$run_id" "$token" >/dev/null 2>&1; then
                printf "%s cleanup accepted foreign tryboot evidence\n" "$WORKER_NAME" >&2
                exit 1
            fi
            [[ -f $tryboot_path ]]
            [[ $(sha256sum "$tryboot_path" | awk "{print \$1}") == "$before_hash" ]]
            assert_permanent_unchanged
            assert_batocera_ro
        }

        render_owned fixture-run "$token_a"
        cmd_verify_tryboot "$CASE_ROOT/config.txt" "$tryboot_path" "$permanent_hash" "$owned_candidate_hash" fixture-run "$token_a" >/dev/null
        if cmd_verify_tryboot "$CASE_ROOT/config.txt" "$tryboot_path" "$permanent_hash" "$owned_candidate_hash" fixture-run "$token_b" >/dev/null 2>&1; then
            printf "%s pre-trigger verify accepted the same run with another token\n" "$WORKER_NAME" >&2
            exit 1
        fi
        : > "$CASE_ROOT/remounts"
        cmd_clear_tryboot "$CASE_ROOT/config.txt" "$tryboot_path" "$quarantine_a" "$permanent_hash" "$owned_candidate_hash" "$owned_reservation_hash" fixture-run "$token_a" >/dev/null
        [[ ! -e $tryboot_path && ! -L $tryboot_path && ! -e $quarantine_a && ! -L $quarantine_a ]]
        assert_permanent_unchanged
        assert_batocera_ro

        : > "$CASE_ROOT/remounts"
        cmd_clear_tryboot "$CASE_ROOT/config.txt" "$tryboot_path" "$quarantine_a" "$permanent_hash" "$owned_candidate_hash" "$owned_reservation_hash" fixture-run "$token_a" >/dev/null
        [[ ! -e $tryboot_path && ! -L $tryboot_path && ! -e $quarantine_a && ! -L $quarantine_a ]]
        assert_permanent_unchanged
        assert_batocera_ro
        if [[ $WORKER_NAME == batocera && -s $CASE_ROOT/remounts ]]; then
            printf "Batocera remounted /boot for already-absent cleanup\n" >&2
            exit 1
        fi

        # Absence is not sufficient on Batocera: if /boot is unexpectedly RW,
        # cleanup must actively restore and verify RO before reporting PASS.
        if [[ $WORKER_NAME == batocera ]]; then
            mount_state=rw
            : > "$CASE_ROOT/remounts"
            cmd_clear_tryboot "$CASE_ROOT/config.txt" "$tryboot_path" "$quarantine_a" "$permanent_hash" "$owned_candidate_hash" "$owned_reservation_hash" fixture-run "$token_a" > "$CASE_ROOT/absent-rw.out"
            grep -q "APO_RESULT_CLASS=PASS" "$CASE_ROOT/absent-rw.out"
            [[ $(paste -sd, "$CASE_ROOT/remounts") == ro ]]
            [[ $mount_state == ro && $APO_APPLY_BOOT_RW == 0 ]]
            [[ ! -e $tryboot_path && ! -L $tryboot_path && ! -e $quarantine_a && ! -L $quarantine_a ]]
            assert_permanent_unchanged
        fi

        render_reservation fixture-run "$token_a"
        : > "$CASE_ROOT/remounts"
        cmd_clear_tryboot "$CASE_ROOT/config.txt" "$tryboot_path" "$quarantine_a" "$permanent_hash" "$owned_candidate_hash" "$owned_reservation_hash" fixture-run "$token_a" >/dev/null
        [[ ! -e $tryboot_path && ! -L $tryboot_path && ! -e $quarantine_a && ! -L $quarantine_a ]]
        assert_permanent_unchanged
        assert_batocera_ro

        render_reservation fixture-run "$token_a"
        printf "# interrupted body\n" >> "$tryboot_path"
        : > "$CASE_ROOT/remounts"
        cmd_clear_tryboot "$CASE_ROOT/config.txt" "$tryboot_path" "$quarantine_a" "$permanent_hash" "$owned_candidate_hash" "$owned_reservation_hash" fixture-run "$token_a" >/dev/null
        [[ ! -e $tryboot_path && ! -e $quarantine_a ]]
        assert_permanent_unchanged
        assert_batocera_ro

        render_owned fixture-run "$token_a"
        wrong_hash=$(printf "f%.0s" {1..64})
        expect_preserved_failure "$quarantine_a" "$wrong_hash" "$owned_reservation_hash" fixture-run "$token_a"

        render_owned original-run "$token_a"
        expect_preserved_failure "$quarantine_a" "$owned_candidate_hash" "$owned_reservation_hash" different-run "$token_a"

        render_owned fixture-run "$token_a"
        expect_preserved_failure "$quarantine_b" "$owned_candidate_hash" "$owned_reservation_hash" fixture-run "$token_b"

        printf "# Run: fixture-run\narm_freq=2500\n" > "$tryboot_path"
        arbitrary_hash=$(sha256sum "$tryboot_path" | awk "{print \$1}")
        arbitrary_reservation_hash=$(render_tryboot_reservation fixture-run "$token_a" | sha256sum | awk "{print \$1}")
        expect_preserved_failure "$quarantine_a" "$arbitrary_hash" "$arbitrary_reservation_hash" fixture-run "$token_a"

        render_owned fixture-run "$token_a"
        bad_permanent_hash=$(printf "e%.0s" {1..64})
        before_hash=$(sha256sum "$tryboot_path" | awk "{print \$1}")
        : > "$CASE_ROOT/remounts"
        if cmd_clear_tryboot "$CASE_ROOT/config.txt" "$tryboot_path" "$quarantine_a" "$bad_permanent_hash" "$owned_candidate_hash" "$owned_reservation_hash" fixture-run "$token_a" >/dev/null 2>&1; then
            printf "%s cleanup ignored a permanent-config hash mismatch\n" "$WORKER_NAME" >&2
            exit 1
        fi
        [[ $(sha256sum "$tryboot_path" | awk "{print \$1}") == "$before_hash" ]]
        assert_permanent_unchanged
        assert_batocera_ro

        render_owned fixture-run "$token_a"
        cp "$tryboot_path" "$CASE_ROOT/symlink-target.txt"
        rm -f -- "$tryboot_path"
        ln -s -- "$CASE_ROOT/symlink-target.txt" "$tryboot_path"
        : > "$CASE_ROOT/remounts"
        if cmd_clear_tryboot "$CASE_ROOT/config.txt" "$tryboot_path" "$quarantine_a" "$permanent_hash" "$owned_candidate_hash" "$owned_reservation_hash" fixture-run "$token_a" >/dev/null 2>&1; then
            printf "%s cleanup followed and accepted a tryboot symlink\n" "$WORKER_NAME" >&2
            exit 1
        fi
        [[ -L $tryboot_path && -f $CASE_ROOT/symlink-target.txt ]]
        assert_permanent_unchanged
        assert_batocera_ro

        rm -f -- "$tryboot_path" "$CASE_ROOT/symlink-target.txt"
        ln -s -- "$CASE_ROOT/missing-target.txt" "$tryboot_path"
        : > "$CASE_ROOT/remounts"
        if cmd_clear_tryboot "$CASE_ROOT/config.txt" "$tryboot_path" "$quarantine_a" "$permanent_hash" "$owned_candidate_hash" "$owned_reservation_hash" fixture-run "$token_a" >/dev/null 2>&1; then
            printf "%s cleanup treated a dangling symlink as absent\n" "$WORKER_NAME" >&2
            exit 1
        fi
        [[ -L $tryboot_path ]]
        assert_permanent_unchanged
        assert_batocera_ro
        rm -f -- "$tryboot_path"

        if [[ $WORKER_NAME == batocera ]]; then
            render_owned fixture-run "$token_a"
            : > "$CASE_ROOT/remounts"
            mutate_on_rw=1
            if cmd_clear_tryboot "$CASE_ROOT/config.txt" "$tryboot_path" "$quarantine_a" "$permanent_hash" "$owned_candidate_hash" "$owned_reservation_hash" fixture-run "$token_a" >/dev/null 2>&1; then
                printf "Batocera cleanup ignored a post-remount tryboot change\n" >&2
                exit 1
            fi
            mutate_on_rw=0
            [[ -f $tryboot_path && ! -e $quarantine_a ]]
            [[ $(paste -sd, "$CASE_ROOT/remounts") == rw,ro ]]
            assert_permanent_unchanged
            assert_batocera_ro
        fi

        # A controller crash after rename resumes from the token quarantine.
        render_owned fixture-run "$token_a"
        command mv -- "$tryboot_path" "$quarantine_a"
        : > "$CASE_ROOT/remounts"
        cmd_clear_tryboot "$CASE_ROOT/config.txt" "$tryboot_path" "$quarantine_a" "$permanent_hash" "$owned_candidate_hash" "$owned_reservation_hash" fixture-run "$token_a" >/dev/null
        [[ ! -e $tryboot_path && ! -e $quarantine_a ]]
        assert_permanent_unchanged
        assert_batocera_ro

        render_reservation fixture-run "$token_a"
        command mv -- "$tryboot_path" "$quarantine_a"
        : > "$CASE_ROOT/remounts"
        cmd_clear_tryboot "$CASE_ROOT/config.txt" "$tryboot_path" "$quarantine_a" "$permanent_hash" "$owned_candidate_hash" "$owned_reservation_hash" fixture-run "$token_a" >/dev/null
        [[ ! -e $tryboot_path && ! -e $quarantine_a ]]
        assert_batocera_ro

        # A foreign quarantine is never claimed, even with no tryboot path.
        printf "foreign quarantine\n" > "$quarantine_a"
        foreign_quarantine_hash=$(sha256sum "$quarantine_a" | awk "{print \$1}")
        : > "$CASE_ROOT/remounts"
        if cmd_clear_tryboot "$CASE_ROOT/config.txt" "$tryboot_path" "$quarantine_a" "$permanent_hash" "$owned_candidate_hash" "$owned_reservation_hash" fixture-run "$token_a" >/dev/null 2>&1; then
            printf "%s cleanup claimed a foreign quarantine\n" "$WORKER_NAME" >&2
            exit 1
        fi
        [[ $(sha256sum "$quarantine_a" | awk "{print \$1}") == "$foreign_quarantine_hash" ]]
        assert_batocera_ro

        # If another actor occupies quarantine at move time, mv -n must leave
        # both the owned source and foreign destination untouched.
        render_owned fixture-run "$token_a"
        owned_before=$(sha256sum "$tryboot_path" | awk "{print \$1}")
        : > "$CASE_ROOT/remounts"
        if (
            mv() {
                if [[ $1 == -n && $2 == -- ]]; then printf "move-time foreign\n" > "$quarantine_a"; fi
                command mv "$@"
            }
            cmd_clear_tryboot "$CASE_ROOT/config.txt" "$tryboot_path" "$quarantine_a" "$permanent_hash" "$owned_candidate_hash" "$owned_reservation_hash" fixture-run "$token_a" >/dev/null 2>&1
        ); then
            printf "%s cleanup accepted a no-clobber quarantine collision\n" "$WORKER_NAME" >&2
            exit 1
        fi
        [[ $(sha256sum "$tryboot_path" | awk "{print \$1}") == "$owned_before" ]]
        [[ $(<"$quarantine_a") == "move-time foreign" ]]
        assert_permanent_unchanged

        # Replacing the source immediately before rename moves the foreign file
        # into quarantine, where post-rename validation must preserve it.
        render_owned fixture-run "$token_a"
        : > "$CASE_ROOT/remounts"
        if (
            mv() {
                if [[ $1 == -n && $2 == -- ]]; then
                    command mv -- "$tryboot_path" "$CASE_ROOT/owned-displaced"
                    printf "foreign replacement\n" > "$tryboot_path"
                fi
                command mv "$@"
            }
            cmd_clear_tryboot "$CASE_ROOT/config.txt" "$tryboot_path" "$quarantine_a" "$permanent_hash" "$owned_candidate_hash" "$owned_reservation_hash" fixture-run "$token_a" >/dev/null 2>&1
        ); then
            printf "%s cleanup accepted a replaced source after quarantine rename\n" "$WORKER_NAME" >&2
            exit 1
        fi
        [[ -f $CASE_ROOT/owned-displaced ]]
        [[ $(<"$quarantine_a") == "foreign replacement" ]]
        assert_permanent_unchanged

        # A sync failure after rename leaves an owned quarantine that a later
        # cleanup invocation can verify and finish.
        render_owned fixture-run "$token_a"
        : > "$CASE_ROOT/remounts"
        if (
            sync_calls=0
            sync() {
                sync_calls=$((sync_calls + 1))
                (( sync_calls > 1 ))
            }
            cmd_clear_tryboot "$CASE_ROOT/config.txt" "$tryboot_path" "$quarantine_a" "$permanent_hash" "$owned_candidate_hash" "$owned_reservation_hash" fixture-run "$token_a" >/dev/null 2>&1
        ); then
            printf "%s cleanup suppressed a quarantine-rename sync failure\n" "$WORKER_NAME" >&2
            exit 1
        fi
        [[ ! -e $tryboot_path && -f $quarantine_a ]]
        : > "$CASE_ROOT/remounts"
        cmd_clear_tryboot "$CASE_ROOT/config.txt" "$tryboot_path" "$quarantine_a" "$permanent_hash" "$owned_candidate_hash" "$owned_reservation_hash" fixture-run "$token_a" >/dev/null
        [[ ! -e $tryboot_path && ! -e $quarantine_a ]]
        assert_permanent_unchanged
        assert_batocera_ro
    '
done

# Batocera must restore /boot read-only even when staging fails after its RW
# remount. This also proves that no temporary candidate survives the failure.
WORKER="$ROOT/workers/batocera-worker.sh" CASE_ROOT="$TEMP_DIR/batocera-stage-failure" bash -c '
    set -Eeuo pipefail
    mkdir -p "$CASE_ROOT"
    printf "[all]\narm_freq=2400\nv3d_freq=960\n" > "$CASE_ROOT/config.txt"
    permanent_hash=$(sha256sum "$CASE_ROOT/config.txt" | awk "{print \$1}")
    ownership_token=$(printf "5%.0s" {1..64})
    quarantine_path="$CASE_ROOT/.autopioverclock-remove-$ownership_token"
    APO_WORKER_LIBRARY_ONLY=1 source "$WORKER"
    tryboot_path_allowed() { return 0; }
    reset_recent_throttle() { :; }
    render_tryboot_config "$CASE_ROOT/config.txt" "$CASE_ROOT/plan.txt" 2500 970 v3d_freq 0 fixture-run "$ownership_token"
    expected_tryboot_hash=$(sha256sum "$CASE_ROOT/plan.txt" | awk "{print \$1}")
    expected_reservation_hash=$(render_tryboot_reservation fixture-run "$ownership_token" | sha256sum | awk "{print \$1}")
    rm -f -- "$CASE_ROOT/plan.txt"
    render_tryboot_config() { return 1; }
    : > "$CASE_ROOT/remounts"
    remount_boot_rw() { printf "rw\n" >> "$CASE_ROOT/remounts"; return 0; }
    remount_boot_ro() { printf "ro\n" >> "$CASE_ROOT/remounts"; return 0; }
    if cmd_prepare_candidate "$CASE_ROOT/config.txt" "$CASE_ROOT/tryboot.txt" v3d_freq 2500 970 0 "$permanent_hash" fixture-run "$expected_tryboot_hash" "$expected_reservation_hash" "$ownership_token" "$quarantine_path" >/dev/null 2>&1; then
        printf "Batocera staging accepted a render failure\n" >&2
        exit 1
    fi
    [[ $(paste -sd, "$CASE_ROOT/remounts") == rw,ro ]]
    [[ $APO_APPLY_BOOT_RW == 0 ]]
    [[ ! -e $CASE_ROOT/tryboot.txt && ! -L $CASE_ROOT/tryboot.txt ]]
    [[ $(sha256sum "$CASE_ROOT/config.txt" | awk "{print \$1}") == "$permanent_hash" ]]
    if find "$CASE_ROOT" -maxdepth 1 -name ".autopioverclock-tryboot.*" | grep -q .; then exit 1; fi
'

printf 'test_tryboot_lifecycle: PASS\n'
