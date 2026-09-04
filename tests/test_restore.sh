#!/usr/bin/env bash
# shellcheck disable=SC1090
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

fail() {
    printf 'test_restore: %s\n' "$1" >&2
    exit 1
}

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export APO_ROOT=$ROOT
export APO_CLI_LIBRARY_ONLY=1
source "$ROOT/autopioverclock"

APO_OUTPUT_DIR=$TEST_ROOT
APO_TARGET_SLUG=fixture
APO_REMOTE_TARGET=tester@fixture
APO_SELECTED_RUN_ID=''
SOURCE_RUN=20260904-010203-aabbccddeeff0011
SOURCE_STATE="$TEST_ROOT/fixture-${SOURCE_RUN}.state"
SOURCE_CONFIG="${SOURCE_STATE%.state}-apply-proposed-config.txt"

cat > "$SOURCE_CONFIG" <<CONFIG
[all]
dtparam=watchdog=on
# BEGIN AUTOPIOVERCLOCK MANAGED CLOCKS
# Run: $SOURCE_RUN
[all]
arm_freq=3100
v3d_freq=1175
# END AUTOPIOVERCLOCK MANAGED CLOCKS
CONFIG
SOURCE_HASH=$(sha256sum "$SOURCE_CONFIG" | awk 'NR == 1 {print $1}')

APO_RUN_ID=$SOURCE_RUN
APO_STATE_FILE=$SOURCE_STATE
APO_RAW_TARGET=fixture
APO_TARGET_HOST=fixture
APO_ORIGIN_COMMAND=overclock
APO_DRY_RUN=0
apo_config_defaults
APO_AUTO_GENERATED_CANDIDATES=1
APO_SWEEP_DOMAIN=all
APO_SELECTION_POLICY=refined-max-25
APO_QUALIFICATION_DURATION_S=$APO_DEFAULT_QUALIFICATION_DURATION_S
APO_FINAL_DURATION_S=$APO_DEFAULT_FINAL_DURATION_S
APO_EDGE_DURATION_S=$APO_DEFAULT_EDGE_DURATION_S
APO_DURATION_POLICY=$(apo_config_duration_policy "$APO_QUALIFICATION_DURATION_S" "$APO_FINAL_DURATION_S" "$APO_EDGE_DURATION_S")
apo_state_initialize
apo_config_store_in_state
apo_state_set STATUS PASS
apo_state_set PHASE COMPLETE
apo_state_set FINAL_STAGE COMPLETE
apo_state_set VALIDATED 1
apo_state_set VALIDATION_SCHEMA "$APO_CURRENT_VALIDATION_SCHEMA"
apo_state_set VALIDATION_DURATION_S "$APO_DEFAULT_FINAL_DURATION_S"
apo_state_set APPLY_STATUS APPLIED
apo_state_set APPLY_EXPECTED_HASH "$SOURCE_HASH"
apo_state_set PERMANENT_HASH "$SOURCE_HASH"
apo_state_set PROFILE debian
apo_state_set MODE_EFFECTIVE headless
apo_state_set BOOT_CONFIG /boot/firmware/config.txt
apo_state_set TRYBOOT_CONFIG /boot/firmware/tryboot.txt
apo_state_set BOOT_MOUNT /boot/firmware
apo_state_set GPU_KEY v3d_freq
apo_state_set NORMAL_CPU 3100
apo_state_set NORMAL_GPU 1175
apo_state_set NORMAL_VOLTAGE 0
apo_state_set TEST_VOLTAGE 0
apo_state_set RECOMMENDED_CPU 3100
apo_state_set RECOMMENDED_GPU 1175
apo_state_set FINAL_CPU 3100
apo_state_set FINAL_GPU 1175
apo_state_set FINAL_TARGET_CPU 3100
apo_state_set FINAL_TARGET_GPU 1175
apo_state_set AUTO_BASELINE_CPU 2400
apo_state_set AUTO_BASELINE_GPU 960
apo_state_set AUTO_BASELINE_VOLTAGE 0
apo_state_set AUTO_BASELINE_PROVENANCE verified-default
apo_state_set AUTO_BASELINE_EVIDENCE none
apo_state_set THROTTLE_BASELINE throttled=0x0
apo_state_set THROTTLE_RUNTIME_BASELINE throttled=0x0
apo_state_set THROTTLE_RECENT_SUPPORTED 1
apo_state_save

# Newer unrelated and restore audit states must not hide the newest eligible
# validated/applied source.
for audit_run in 20260904-020000-bbbbbbbbbbbbbbbb 20260904-030000-cccccccccccccccc; do
    APO_RUN_ID=$audit_run
    APO_STATE_FILE="$TEST_ROOT/fixture-${audit_run}.state"
    if [[ $audit_run == *020000* ]]; then
        APO_ORIGIN_COMMAND=prepare
    else
        APO_ORIGIN_COMMAND=restore
    fi
    apo_state_initialize
    apo_state_set STATUS PASS
    apo_state_set PHASE COMPLETE
    apo_state_save
done

APO_SELECTED_RUN_ID=''
apo_restore_select_source
[[ $APO_RESTORE_SOURCE_RUN_ID == "$SOURCE_RUN" ]] || fail 'automatic source selection did not skip newer ineligible audits'
[[ $APO_RESTORE_SOURCE_HASH == "$SOURCE_HASH" ]] || fail 'selected source hash was not bound to its artifact'
[[ $APO_RESTORE_SOURCE_CPU == 3100 && $APO_RESTORE_SOURCE_GPU == 1175 ]] || fail 'selected source clocks were not retained'

# Explicit selection is supported, while artifact corruption and a missing
# validated source both fail before any target operation can begin.
APO_SELECTED_RUN_ID=$SOURCE_RUN
apo_restore_select_source
printf '\n# changed\n' >> "$SOURCE_CONFIG"
if (APO_SELECTED_RUN_ID=$SOURCE_RUN; apo_restore_select_source) >/dev/null 2>&1; then
    fail 'restore accepted a retained config artifact whose hash changed'
fi
rm -f -- "$SOURCE_STATE" "$SOURCE_CONFIG"
if (APO_SELECTED_RUN_ID=''; apo_restore_select_source) >/dev/null 2>&1; then
    fail 'restore accepted prepare/restore audits without a validated applied source'
fi

grep -Fq 'apply-permanent "$remote_proposed" "$current_hash" "$expected_hash" "$APO_RUN_ID"' "$ROOT/lib/restore.sh" ||
    fail 'restore does not use the hash-bound permanent-config worker'
grep -Fq 'apo_reconcile_interrupted_apply' "$ROOT/lib/restore.sh" ||
    fail 'restore lacks apply reconciliation/rollback'
grep -Fq 'apo_apply_force_normal_boot_and_health' "$ROOT/lib/restore.sh" ||
    fail 'restore lacks fresh normal-reboot health verification'
grep -Fq 'APO_STORAGE_LAYOUT == "$APO_RESTORE_SOURCE_STORAGE_LAYOUT"' "$ROOT/lib/restore.sh" ||
    fail 'restore does not bind the retained result to the live storage layout'
grep -Fq "ORIGIN_COMMAND '') == restore" "$ROOT/autopioverclock" ||
    fail 'saved restore audits are not rejected by tuning-state commands'

for worker_file in "$ROOT/workers/debian-worker.sh" "$ROOT/workers/batocera-worker.sh"; do
    grep -q 'apply-permanent).*run_with_mutation_lock' "$worker_file" ||
        fail "$(basename "$worker_file") does not serialize restore's permanent-config worker"
done

printf 'test_restore: PASS\n'
