#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TEST_ROOT=$(mktemp -d "${ROOT}/.test-complete.XXXXXX")
trap 'rm -rf -- "$TEST_ROOT"' EXIT

write_managed_config() {
    local destination=$1
    cat > "$destination" <<'EOF'
# User header stays exactly here
dtparam=fan_temp=65000
# AUTOPIOVERCLOCK-STOCK-DISABLED arm_freq=2400
# AUTOPIOVERCLOCK-STOCK-DISABLED gpu_freq=950

# BEGIN AUTOPIOVERCLOCK MANAGED CLOCKS
# Run: selected-run
[all]
over_voltage_delta=0
arm_freq=3050
v3d_freq=1200
# AUTOPIOVERCLOCK CANDIDATE COOLING: PI PWM FAN 100 PERCENT
dtparam=fan_temp0=0
dtparam=fan_temp0_speed=255
dtparam=fan_temp1_speed=255
dtparam=fan_temp2_speed=255
dtparam=fan_temp3_speed=255
# END AUTOPIOVERCLOCK MANAGED CLOCKS

# User fan settings stay
dtparam=fan_temp=60000
dtparam=fan_temp_speed=180
# AUTOPIOVERCLOCK TRYBOOT COMPLETE: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
}

write_expected_config() {
    local destination=$1
    cat > "$destination" <<'EOF'
# User header stays exactly here
[all]
dtparam=fan_temp=65000

over_voltage_delta=0
arm_freq=3050
v3d_freq=1200

# User fan settings stay
dtparam=fan_temp=60000
dtparam=fan_temp_speed=180
EOF
}

write_tron_managed_config() {
    local destination=$1
    cat > "$destination" <<'EOF'
arm_64bit=1
kernel=boot/linux
initramfs boot/initrd.lz4
dtoverlay=vc4-kms-v3d,cma-512

dtparam=krnbt=on
[Overclock]

[all]
# Stable Tron overclock validated under combined CPU and GPU load
# AUTOPIOVERCLOCK-STOCK-DISABLED over_voltage_delta=50000
temp_limit=80

[all]

[all]
# BEGIN AUTOPIOVERCLOCK MANAGED WATCHDOG
[all]
kernel_watchdog_timeout=180
# END AUTOPIOVERCLOCK MANAGED WATCHDOG

[all]
# BEGIN AUTOPIOVERCLOCK MANAGED CLOCKS
# Run: selected-run
[all]
arm_freq=2900
v3d_freq=1125
# END AUTOPIOVERCLOCK MANAGED CLOCKS
EOF
}

write_monkeebutt_managed_config() {
    local destination=$1
    cat > "$destination" <<'EOF'
# For more options and information see
# http://rptl.io/configtxt
dtparam=i2c_arm=on
dtparam=audio=on
arm_64bit=1
disable_overscan=1

[all]
usb_max_current_enable=1
dtparam=watchdog=on
dtparam=fan_temp0=50000
dtparam=fan_temp0_speed=75
kernel_watchdog_timeout=60

[all]

# BEGIN AUTOPIOVERCLOCK MANAGED CLOCKS
# Run: selected-run
[all]
arm_freq=3050
v3d_freq=1200
# END AUTOPIOVERCLOCK MANAGED CLOCKS
EOF
}

write_conditional_managed_config() {
    local destination=$1
    cat > "$destination" <<'EOF'
# A real conditional section must remain conditional.
[Overclock]
# An empty label is not a meaningful section.
[pi5]
dtparam=pciex1
[all]
dtparam=audio=on

# BEGIN AUTOPIOVERCLOCK MANAGED CLOCKS
# Run: selected-run
[all]
over_voltage_delta=0
arm_freq=3050
v3d_freq=1200
# END AUTOPIOVERCLOCK MANAGED CLOCKS
EOF
}

write_state_field() {
    local destination=$1 key=$2 value=${3-}
    {
        printf '%s\t' "$key"
        printf '%s' "$value" | base64 | tr -d '\n'
        printf '\n'
    } >> "$destination"
}

write_retained_state() {
    local destination=$1 run_id=$2 status=$3 remote_status=${4-__OMIT__}
    : > "$destination"
    write_state_field "$destination" FORMAT_VERSION 1
    write_state_field "$destination" RUN_ID "$run_id"
    write_state_field "$destination" TARGET_SLUG tron
    write_state_field "$destination" REMOTE_TARGET pi@tron
    write_state_field "$destination" STATUS "$status"
    if [[ $remote_status != __OMIT__ ]]; then
        write_state_field "$destination" REMOTE_STRESS_STATUS "$remote_status"
    fi
}

array_has_value() {
    local needle=$1 item
    shift
    for item in "$@"; do
        [[ $item == "$needle" ]] && return 0
    done
    return 1
}

test_worker_backup_collection() {
    local worker=$1 profile_dir=$2
    local APO_WORKER_LIBRARY_ONLY=1
    export APO_WORKER_LIBRARY_ONLY
    (
        local test_backup_root="${profile_dir}/backups"
        source "$worker"
        complete_backup_root() { printf '%s' "$test_backup_root"; }
        mkdir -p -- "$test_backup_root"

        COMPLETE_CLEANUP_PATHS=()
        complete_collect_backup_paths missing-run
        (( ${#COMPLETE_CLEANUP_PATHS[@]} == 0 ))

        touch -- "$test_backup_root/config-present-run-before-apply.txt"
        COMPLETE_CLEANUP_PATHS=()
        complete_collect_backup_paths present-run
        (( ${#COMPLETE_CLEANUP_PATHS[@]} == 1 ))
        [[ ${COMPLETE_CLEANUP_PATHS[0]} == "$test_backup_root/config-present-run-before-apply.txt" ]]

        ln -s -- missing-target "$test_backup_root/config-unsafe-run-before-apply.txt"
        COMPLETE_CLEANUP_PATHS=()
        if complete_collect_backup_paths unsafe-run; then
            printf 'complete accepted an unsafe backup symlink: %s\n' "$worker" >&2
            return 1
        fi
    )
}

test_worker_renderer() {
    local worker=$1 profile_dir=$2 input expected rendered invalid
    local APO_WORKER_LIBRARY_ONLY=1
    export APO_WORKER_LIBRARY_ONLY
    input="${profile_dir}/config.txt"
    expected="${profile_dir}/expected.txt"
    rendered="${profile_dir}/rendered.txt"
    invalid="${profile_dir}/invalid.txt"
    mkdir -p -- "$profile_dir"
    write_managed_config "$input"
    write_expected_config "$expected"

    (
        source "$worker"
        complete_validate_config "$input" 3050 1200 v3d_freq 0 selected-run
        complete_render_config "$input" "$rendered" 3050 1200 v3d_freq 0
        complete_validate_sealed_config "$rendered" 3050 1200 v3d_freq 0
    )
    cmp -s -- "$expected" "$rendered"
    [[ $(grep -c '^arm_freq=3050$' "$rendered") == 1 ]]
    [[ $(grep -c '^v3d_freq=1200$' "$rendered") == 1 ]]
    [[ $(grep -c '^over_voltage_delta=0$' "$rendered") == 1 ]]
    if grep -Fq 'AUTOPIOVERCLOCK' "$rendered"; then
        printf 'completed config retained project-owned metadata: %s\n' "$worker" >&2
        return 1
    fi
    grep -Fxq '# User header stays exactly here' "$rendered"
    grep -Fxq 'dtparam=fan_temp=65000' "$rendered"
    grep -Fxq 'dtparam=fan_temp=60000' "$rendered"
    grep -Fxq 'dtparam=fan_temp_speed=180' "$rendered"

    cp -- "$input" "$invalid"
    printf 'arm_freq=3100\n' >> "$invalid"
    if (
        source "$worker"
        complete_validate_config "$invalid" 3050 1200 v3d_freq 0 selected-run
    ); then
        printf 'complete accepted an active tuning key outside its managed block: %s\n' "$worker" >&2
        return 1
    fi

    cp -- "$input" "$invalid"
    printf 'include extra.txt\n' >> "$invalid"
    if (
        source "$worker"
        complete_validate_config "$invalid" 3050 1200 v3d_freq 0 selected-run
    ); then
        printf 'complete accepted an active include: %s\n' "$worker" >&2
        return 1
    fi

    cp -- "$rendered" "$invalid"
    printf 'arm_freq=3050\n' >> "$invalid"
    if (
        source "$worker"
        complete_validate_sealed_config "$invalid" 3050 1200 v3d_freq 0
    ); then
        printf 'completed config accepted a duplicate tuning key: %s\n' "$worker" >&2
        return 1
    fi

    if (
        source "$worker"
        complete_validate_config "$input" 3050 1200 v3d_freq 0 wrong-run
    ); then
        printf 'complete accepted a managed block belonging to another run: %s\n' "$worker" >&2
        return 1
    fi
}

test_global_section_regressions() {
    local worker=$1 profile_dir=$2 input rendered canonical_again
    local APO_WORKER_LIBRARY_ONLY=1
    export APO_WORKER_LIBRARY_ONLY
    mkdir -p -- "$profile_dir"

    input="${profile_dir}/tron.txt"
    rendered="${profile_dir}/tron.rendered.txt"
    canonical_again="${profile_dir}/tron.canonical-again.txt"
    write_tron_managed_config "$input"
    (
        source "$worker"
        complete_validate_config "$input" 2900 1125 v3d_freq 0 selected-run
        complete_render_config "$input" "$rendered" 2900 1125 v3d_freq 0
        complete_validate_sealed_config "$rendered" 2900 1125 v3d_freq 0
        canonicalize_global_sections "$rendered" "$canonical_again" 1
    )
    [[ $(grep -c '^\[all\]$' "$rendered") == 1 ]]
    if grep -Fqx '[Overclock]' "$rendered"; then
        echo 'Tron completion retained an empty section label' >&2
        return 1
    fi
    if grep -Fq 'AUTOPIOVERCLOCK MANAGED CLOCKS' "$rendered"; then
        echo 'Tron completion retained managed clock markers' >&2
        return 1
    fi
    grep -Fqx '# BEGIN AUTOPIOVERCLOCK MANAGED WATCHDOG' "$rendered"
    grep -Fqx 'kernel_watchdog_timeout=180' "$rendered"
    grep -Fqx 'arm_freq=2900' "$rendered"
    grep -Fqx 'v3d_freq=1125' "$rendered"
    cmp -s -- "$rendered" "$canonical_again"

    input="${profile_dir}/monkeebutt.txt"
    rendered="${profile_dir}/monkeebutt.rendered.txt"
    write_monkeebutt_managed_config "$input"
    (
        source "$worker"
        complete_validate_config "$input" 3050 1200 v3d_freq 0 selected-run
        complete_render_config "$input" "$rendered" 3050 1200 v3d_freq 0
        complete_validate_sealed_config "$rendered" 3050 1200 v3d_freq 0
    )
    [[ $(grep -c '^\[all\]$' "$rendered") == 1 ]]
    grep -Fqx 'dtparam=fan_temp0=50000' "$rendered"
    grep -Fqx 'kernel_watchdog_timeout=60' "$rendered"
    grep -Fqx 'arm_freq=3050' "$rendered"
    grep -Fqx 'v3d_freq=1200' "$rendered"

    input="${profile_dir}/conditional.txt"
    rendered="${profile_dir}/conditional.rendered.txt"
    write_conditional_managed_config "$input"
    (
        source "$worker"
        complete_validate_config "$input" 3050 1200 v3d_freq 0 selected-run
        complete_render_config "$input" "$rendered" 3050 1200 v3d_freq 0
        complete_validate_sealed_config "$rendered" 3050 1200 v3d_freq 0
    )
    if grep -Fqx '[Overclock]' "$rendered"; then
        echo 'Conditional completion retained an empty section label' >&2
        return 1
    fi
    grep -Fqx '# An empty label is not a meaningful section.' "$rendered"
    grep -Fqx '[pi5]' "$rendered"
    grep -Fqx 'dtparam=pciex1' "$rendered"
    [[ $(grep -c '^\[all\]$' "$rendered") == 1 ]]
}

test_worker_renderer "$ROOT/workers/debian-worker.sh" "$TEST_ROOT/debian"
test_worker_renderer "$ROOT/workers/batocera-worker.sh" "$TEST_ROOT/batocera"
test_global_section_regressions "$ROOT/workers/debian-worker.sh" "$TEST_ROOT/debian-sections"
test_global_section_regressions "$ROOT/workers/batocera-worker.sh" "$TEST_ROOT/batocera-sections"
test_worker_backup_collection "$ROOT/workers/debian-worker.sh" "$TEST_ROOT/debian-backups"
test_worker_backup_collection "$ROOT/workers/batocera-worker.sh" "$TEST_ROOT/batocera-backups"

# The public complete command owns the exclusive target lock before it reaches
# retained-state collection. Stale controller-only RUNNING or PREPARING text is
# therefore safe to show and clean, but durable target stress ownership is not.
# shellcheck disable=SC2030  # These controller globals are intentionally subshell-isolated.
(
    APO_ROOT=$ROOT
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/state.sh"
    source "$ROOT/lib/complete.sh"

    APO_TARGET_SLUG=tron
    APO_REMOTE_TARGET=pi@tron
    APO_RUN_ID=selected-run
    APO_OUTPUT_DIR="$TEST_ROOT/collect-stale"
    mkdir -p -- "$APO_OUTPUT_DIR"
    write_retained_state "$APO_OUTPUT_DIR/tron-stale-run.state" stale-run RUNNING
    write_retained_state "$APO_OUTPUT_DIR/tron-preparing-run.state" preparing-run PREPARING IDLE

    apo_complete_collect_target_runs
    array_has_value stale-run "${APO_COMPLETE_RUN_IDS[@]}"
    array_has_value preparing-run "${APO_COMPLETE_RUN_IDS[@]}"
    array_has_value selected-run "${APO_COMPLETE_RUN_IDS[@]}"
    array_has_value stale-run "${APO_COMPLETE_STALE_CONTROLLER_RUN_IDS[@]}"
    array_has_value preparing-run "${APO_COMPLETE_STALE_CONTROLLER_RUN_IDS[@]}"
)

# shellcheck disable=SC2030  # These controller globals are intentionally subshell-isolated.
if (
    APO_ROOT=$ROOT
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/state.sh"
    source "$ROOT/lib/complete.sh"

    APO_TARGET_SLUG=tron
    APO_REMOTE_TARGET=pi@tron
    APO_RUN_ID=selected-run
    APO_OUTPUT_DIR="$TEST_ROOT/collect-active-target"
    mkdir -p -- "$APO_OUTPUT_DIR"
    write_retained_state "$APO_OUTPUT_DIR/tron-active-run.state" active-run RUNNING RUNNING
    apo_complete_collect_target_runs
) 2>/dev/null; then
    printf 'complete accepted a retained target-side stress job\n' >&2
    exit 1
fi

# Controller cleanup is target scoped. It removes every known artifact for the
# completed target, including public reports, and preserves durable history.
(
    APO_ROOT=$ROOT
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/state.sh"
    source "$ROOT/lib/logging.sh"
    source "$ROOT/lib/history.sh"
    source "$ROOT/lib/complete.sh"

    APO_TARGET_SLUG=tron
    APO_REMOTE_TARGET=pi@tron
    APO_TARGET_STATE_DIR="$TEST_ROOT/controller/targets/tron"
    APO_OUTPUT_DIR="$APO_TARGET_STATE_DIR/runs"
    APO_HISTORY_DIR="$APO_TARGET_STATE_DIR/history"
    APO_COMPLETE_RUN_IDS=(run-a run-b)
    APO_RUN_PREFIX="$APO_OUTPUT_DIR/tron-run-a"
    APO_STATE_FILE="$APO_RUN_PREFIX.state"
    APO_LOG_FILE="$APO_RUN_PREFIX.log"
    APO_CSV_FILE="$APO_RUN_PREFIX.csv"
    APO_JSONL_FILE="$APO_RUN_PREFIX.jsonl"
    APO_JSON_FILE="$APO_RUN_PREFIX.json"
    APO_SUMMARY_FILE="$APO_RUN_PREFIX-summary.txt"
    mkdir -p -- "$APO_OUTPUT_DIR" "$APO_HISTORY_DIR"
    printf 'durable history\n' > "$APO_HISTORY_DIR/failures.txt"
    printf 'lock\n' > "$APO_TARGET_STATE_DIR/.lock"
    touch -- \
        "$APO_RUN_PREFIX.state" "$APO_RUN_PREFIX.log" "$APO_RUN_PREFIX.csv" \
        "$APO_RUN_PREFIX.jsonl" "$APO_RUN_PREFIX.json" "$APO_RUN_PREFIX-summary.txt" \
        "$APO_OUTPUT_DIR/tron-run-b.state" "$APO_OUTPUT_DIR/tron-run-b.log" \
        "$APO_OUTPUT_DIR/autopioverclock-run-a-public-report.txt" \
        "$APO_OUTPUT_DIR/autopioverclock-run-b-public-report.txt"
    ln -s -- tron-run-a.state "$APO_OUTPUT_DIR/tron-latest.state"
    ln -s -- tron-run-a.log "$APO_OUTPUT_DIR/tron-latest.log"
    ln -s -- tron-run-a-summary.txt "$APO_OUTPUT_DIR/tron-latest-summary.txt"
    ln -s -- tron-run-a.json "$APO_OUTPUT_DIR/tron-latest.json"

    apo_event() { :; }
    apo_progress_clear_line() { :; }
    sync() { :; }
    apo_complete_delete_controller_artifacts >/dev/null

    [[ ! -e $APO_OUTPUT_DIR && ! -L $APO_OUTPUT_DIR ]]
    [[ -f $APO_HISTORY_DIR/failures.txt ]]
    [[ $(<"$APO_HISTORY_DIR/failures.txt") == 'durable history' ]]
    [[ -f $APO_TARGET_STATE_DIR/.lock ]]
)

printf 'complete tests passed\n'
