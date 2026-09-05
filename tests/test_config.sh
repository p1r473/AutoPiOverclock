#!/usr/bin/env bash
# Fixtures intentionally reuse controller globals inside isolated subshells.
# shellcheck disable=SC2030,SC2031
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
APO_ROOT=$ROOT
source "$ROOT/lib/common.sh"
source "$ROOT/lib/config.sh"
source "$ROOT/lib/state.sh"
source "$ROOT/lib/detect.sh"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT
apo_summary_line() { printf '%s\n' "$*" >> "$APO_SUMMARY_FILE"; }

cat > "$TEMP_DIR/valid.conf" <<'CONF'
cpu_candidates_mhz=2700,2800,2900
gpu_candidates_mhz="800,850,900"
voltage_delta_uv=existing
candidate_duration_seconds=600
final_duration_seconds=28800
max_temp_c=75
telemetry_interval_seconds=7
conservative_backoff_steps=1
candidate_boots=4
final_boots=5
required_services=service_one,service-two
frontend_process=daemon_one
audio_sink_pattern=USB Audio
CONF
apo_config_defaults
apo_config_read_file "$TEMP_DIR/valid.conf"
apo_config_validate
[[ ${APO_ALLOWED_CONFIG_KEYS[*]} == 'cpu_candidates_mhz gpu_candidates_mhz voltage_delta_uv candidate_duration_seconds final_duration_seconds max_temp_c telemetry_interval_seconds conservative_backoff_steps candidate_boots final_boots required_services frontend_process audio_sink_pattern' ]]
[[ ${APO_CPU_CANDIDATES[*]} == '2700 2800 2900' ]]
[[ ${APO_GPU_CANDIDATES[*]} == '800 850 900' ]]
[[ ${APO_CFG[TELEMETRY_INTERVAL_S]} == 7 ]]
[[ ${APO_CFG[CANDIDATE_BOOTS]} == 4 ]]
[[ ${APO_CFG[FINAL_BOOTS]} == 5 ]]
[[ ${APO_CFG[REQUIRED_PROCESSES]} == daemon_one ]]
[[ ${APO_CFG[REQUIRED_SERVICES]} == 'service_one,service-two' ]]
[[ ${APO_CFG[AUDIO_SINK_MATCH]} == 'USB Audio' ]]

apo_write_effective_config "$TEMP_DIR/effective.conf"
grep -Fxq 'cpu_candidates_mhz=2700,2800,2900' "$TEMP_DIR/effective.conf"
grep -Fxq 'telemetry_interval_seconds=7' "$TEMP_DIR/effective.conf"
grep -Fxq 'frontend_process=daemon_one' "$TEMP_DIR/effective.conf"
if grep -Eq '^(CPU_CANDIDATES|REQUIRED_PROCESSES|EXTRA_PING_TARGET|HEALTH_HOOK)=' "$TEMP_DIR/effective.conf"; then
    echo 'an internal configuration key leaked into the public effective config' >&2
    exit 1
fi
apo_config_defaults
apo_config_read_file "$TEMP_DIR/effective.conf"
[[ ${APO_CFG[AUDIO_SINK_MATCH]} == 'USB Audio' ]]

for template in "$ROOT/examples/debian-headless.conf" "$ROOT/examples/batocera-graphical.conf"; do
    apo_config_defaults
    apo_config_read_file "$template"
    apo_config_validate
    [[ -z ${APO_CFG[CPU_CANDIDATES]} ]]
    [[ -z ${APO_CFG[GPU_CANDIDATES]} ]]
    [[ ${APO_CFG[VOLTAGE_DELTA_UV]} == existing ]]
done

printf 'STDIN_MUST_REMAIN_UNREAD\n' > "$TEMP_DIR/auto-stdin"
exec 9< "$TEMP_DIR/auto-stdin"
APO_COMMAND=run
APO_DRY_RUN=0
APO_CONFIG_FILE=''
APO_MODE_REQUESTED=auto
apo_config_load_for_new_run <&9
(( APO_AUTO_CANDIDATES_PENDING == 1 ))
(( APO_AUTO_GENERATED_CANDIDATES == 1 ))
[[ -z ${APO_CFG[CPU_CANDIDATES]} && -z ${APO_CFG[GPU_CANDIDATES]} ]]

resolve_discovered_auto_plan() {
    local profile=$1 normal_cpu=$2 normal_gpu=$3 normal_voltage=$4 provenance=${5:-verified-default} evidence=${6:-none}
    APO_MODE_EFFECTIVE=headless
    APO_PROFILE=$profile
    APO_DISCOVERY=(
        [BOOT_CONFIG]=/boot/config.txt
        [TRYBOOT_CONFIG]=/boot/tryboot.txt
        [TRYBOOT_EXISTS]=0
        [TRYBOOT_TYPE]=absent
        [TRYBOOT_HASH]=unavailable
        [BOOT_MOUNT]=/boot
        [GPU_KEY]=v3d_freq
        [NORMAL_CPU]="$normal_cpu"
        [NORMAL_GPU]="$normal_gpu"
        [NORMAL_VOLTAGE]="$normal_voltage"
        [PERMANENT_TUNING_PROVENANCE]="$provenance"
        [PERMANENT_TUNING_EVIDENCE]="$evidence"
        [PERMANENT_HASH]=$(printf 'b%.0s' {1..64})
    )
    apo_context_from_discovery
}

finalize_discovered_fixture() {
    local fixture_name=$1
    APO_STATE=()
    APO_STATE_FILE="$TEMP_DIR/${fixture_name}.state"
    APO_EFFECTIVE_CONFIG_FILE="$TEMP_DIR/${fixture_name}.conf"
    APO_SUMMARY_FILE="$TEMP_DIR/${fixture_name}.summary"
    : > "$APO_SUMMARY_FILE"
    apo_state_set FORMAT_VERSION 1
    apo_finalize_discovered_config
}

resolve_discovered_auto_plan debian 2400 960 0 <&9
if ! IFS= read -r unread_auto_input <&9; then
    echo 'auto candidate resolution consumed stdin' >&2
    exit 1
fi
exec 9<&-
[[ $unread_auto_input == STDIN_MUST_REMAIN_UNREAD ]]
[[ ${APO_CFG[CPU_CANDIDATES]} == '2500,2600,2700,2800,2900,3000,3100,3200' ]]
[[ ${APO_CFG[GPU_CANDIDATES]} == '1000,1050,1100,1150,1200' ]]
[[ ${APO_CPU_CANDIDATES[*]} == '2500 2600 2700 2800 2900 3000 3100 3200' ]]
[[ ${APO_GPU_CANDIDATES[*]} == '1000 1050 1100 1150 1200' ]]
[[ ${APO_CFG[BACKOFF_STEPS]} == 0 ]]
DEBIAN_AUTO_PLAN="${APO_CFG[CPU_CANDIDATES]}|${APO_CFG[GPU_CANDIDATES]}"
finalize_discovered_fixture debian-auto
(( APO_NEED_GPU == 1 && APO_REQUIRE_GPU_STRESS == 1 ))
grep -Fxq 'CPU candidates: 2500,2600,2700,2800,2900,3000,3100,3200' "$APO_SUMMARY_FILE"
grep -Fxq 'GPU candidates: 1000,1050,1100,1150,1200' "$APO_SUMMARY_FILE"
APO_STATE=()
apo_state_load "$TEMP_DIR/debian-auto.state"
[[ ${APO_STATE[CFG_CPU_CANDIDATES]} == '2500,2600,2700,2800,2900,3000,3100,3200' ]]
[[ ${APO_STATE[CFG_GPU_CANDIDATES]} == '1000,1050,1100,1150,1200' ]]
[[ ${APO_STATE[CFG_AUTO_GENERATED_CANDIDATES]} == 1 ]]
[[ ${APO_STATE[CFG_EDGE_CPU_24H]} == 0 ]]
[[ ${APO_STATE[CFG_EDGE_ORDER]} == floor-first ]]
[[ ${APO_STATE[CFG_QUALIFICATION_DURATION_S]} == 7200 ]]
[[ ${APO_STATE[CFG_FINAL_DURATION_S]} == 172800 ]]
[[ ${APO_STATE[CFG_EDGE_DURATION_S]} == 86400 ]]
[[ ${APO_STATE[CFG_DURATION_POLICY]} == default ]]
[[ ${APO_STATE[CFG_MAX_FAN]} == 1 ]]
grep -Fq '# candidate_max_fan=enabled' "$TEMP_DIR/debian-auto.conf"
grep -Fxq 'cpu_candidates_mhz=2500,2600,2700,2800,2900,3000,3100,3200' "$TEMP_DIR/debian-auto.conf"
grep -Fxq 'gpu_candidates_mhz=1000,1050,1100,1150,1200' "$TEMP_DIR/debian-auto.conf"
APO_COMMAND=run
APO_DRY_RUN=0
APO_CONFIG_FILE=''
APO_MODE_REQUESTED=auto
apo_config_load_for_new_run
resolve_discovered_auto_plan debian 2400 960 0
[[ "${APO_CFG[CPU_CANDIDATES]}|${APO_CFG[GPU_CANDIDATES]}" == "$DEBIAN_AUTO_PLAN" ]]

(
    APO_COMMAND=run
    APO_DRY_RUN=0
    APO_CONFIG_FILE=''
    APO_MODE_REQUESTED=auto
    APO_EDGE_CPU_24H=1
    APO_MAX_FAN=0
    apo_config_load_for_new_run
    resolve_discovered_auto_plan debian 2400 960 0
    [[ ${APO_CFG[FINAL_DURATION_S]} == 172800 ]]
    finalize_discovered_fixture debian-edge-auto
    APO_STATE=()
    apo_state_load "$TEMP_DIR/debian-edge-auto.state"
    [[ ${APO_STATE[CFG_EDGE_CPU_24H]} == 1 ]]
    [[ ${APO_STATE[CFG_MAX_FAN]} == 0 ]]
    grep -Fq '# candidate_max_fan=disabled' "$TEMP_DIR/debian-edge-auto.conf"
    grep -Fq '# automatic_domain_qualification_seconds=7200' "$TEMP_DIR/debian-edge-auto.conf"
    grep -Fq '# legacy_automatic_edge_seconds=86400' "$TEMP_DIR/debian-edge-auto.conf"
    grep -Fq '# automatic_duration_policy=default' "$TEMP_DIR/debian-edge-auto.conf"
    apo_config_restore_from_state
    [[ $APO_MAX_FAN == 0 ]]
)
(
    APO_COMMAND=run
    APO_PUBLIC_COMMAND=overclock
    APO_DRY_RUN=0
    APO_CONFIG_FILE=''
    APO_MODE_REQUESTED=auto
    # These plan overrides are intentionally isolated to this fixture.
    # shellcheck disable=SC2030
    APO_QUALIFICATION_DURATION_S=10800
    # shellcheck disable=SC2030
    APO_FINAL_DURATION_S=21600
    # shellcheck disable=SC2030
    APO_EDGE_DURATION_S=43200
    APO_EDGE_CPU_24H=1
    apo_config_load_for_new_run
    resolve_discovered_auto_plan debian 2400 960 0
    finalize_discovered_fixture debian-custom-durations
    APO_STATE=()
    apo_state_load "$TEMP_DIR/debian-custom-durations.state"
    [[ ${APO_STATE[CFG_QUALIFICATION_DURATION_S]} == 10800 ]]
    [[ ${APO_STATE[CFG_FINAL_DURATION_S]} == 21600 ]]
    [[ ${APO_STATE[CFG_EDGE_DURATION_S]} == 43200 ]]
    [[ ${APO_STATE[CFG_DURATION_POLICY]} == custom ]]
)

# Schema 9 had fixed 2h/24h qualification and edge semantics. Migration binds
# those defaults explicitly without changing its saved final duration.
APO_STATE=()
APO_STATE_FILE="$TEMP_DIR/schema-9-duration-migration.state"
apo_state_set FORMAT_VERSION 1
apo_state_set RUN_SCHEMA 9
apo_state_set CFG_FINAL_DURATION_S 43200
apo_config_restore_from_state
apo_config_migrate_duration_schema_9
[[ $(apo_state_get RUN_SCHEMA) == "$APO_CURRENT_RUN_SCHEMA" ]]
[[ $(apo_state_get CFG_QUALIFICATION_DURATION_S) == 7200 ]]
[[ $(apo_state_get CFG_FINAL_DURATION_S) == 43200 ]]
[[ $(apo_state_get CFG_EDGE_DURATION_S) == 86400 ]]
[[ $(apo_state_get CFG_DURATION_POLICY) == custom ]]

# Retained 24-hour runs marked with the old default policy stay valid after
# new automatic runs adopt the 48-hour default.
apo_config_saved_duration_policy_matches 7200 86400 86400 default
[[ $(apo_config_duration_policy 7200 86400 86400) == custom ]]

# A crash before PREPARE persisted its plan remains inspectable and reaches the
# dedicated safe-resume refusal. Once tuning has begun, the same missing plan
# is corrupt current-schema state and must fail closed.
(
    APO_STATE=()
    apo_state_set RUN_SCHEMA "$APO_CURRENT_RUN_SCHEMA"
    apo_state_set ORIGIN_COMMAND overclock
    apo_state_set PHASE PREPARE
    apo_config_restore_from_state
    # The custom-plan fixture above intentionally ran in another subshell.
    # shellcheck disable=SC2031
    [[ $APO_QUALIFICATION_DURATION_S == "$APO_DEFAULT_QUALIFICATION_DURATION_S" ]]
    # shellcheck disable=SC2031
    [[ $APO_FINAL_DURATION_S == "$APO_DEFAULT_FINAL_DURATION_S" ]]
    # shellcheck disable=SC2031
    [[ $APO_EDGE_DURATION_S == "$APO_DEFAULT_EDGE_DURATION_S" ]]
)
if (
    APO_STATE=()
    apo_state_set RUN_SCHEMA "$APO_CURRENT_RUN_SCHEMA"
    apo_state_set ORIGIN_COMMAND overclock
    apo_state_set PHASE CPU_SWEEP
    apo_config_restore_from_state
) >/dev/null 2>&1; then
    echo 'current-schema tuning state without an immutable duration plan was accepted' >&2
    exit 1
fi

# States created before the fan-policy key default safely to maximum cooling.
APO_MAX_FAN=0
(
    APO_STATE=()
    apo_config_restore_from_state
    [[ $APO_MAX_FAN == 1 ]]
)

source "$ROOT/lib/health.sh"
APO_STATE=()
apo_state_set TRYBOOT_EXPECTED 1
APO_MAX_FAN=1
[[ $(apo_current_fan_policy) == candidate-max ]]
APO_MAX_FAN=0
[[ $(apo_current_fan_policy) == normal ]]
apo_state_set TRYBOOT_EXPECTED 0
APO_MAX_FAN=1
[[ $(apo_current_fan_policy) == normal ]]

APO_COMMAND=run
APO_DRY_RUN=0
APO_CONFIG_FILE=''
APO_MODE_REQUESTED=auto
apo_config_load_for_new_run
resolve_discovered_auto_plan batocera 2400 800 0
[[ ${APO_CFG[CPU_CANDIDATES]} == '2500,2600,2700,2800,2900,3000,3100,3200' ]]
[[ ${APO_CFG[GPU_CANDIDATES]} == '850,900,950,1000,1050,1100,1150,1200' ]]
[[ ${APO_CPU_CANDIDATES[*]} == '2500 2600 2700 2800 2900 3000 3100 3200' ]]
[[ ${APO_GPU_CANDIDATES[*]} == '850 900 950 1000 1050 1100 1150 1200' ]]
BATOCERA_AUTO_PLAN="${APO_CFG[CPU_CANDIDATES]}|${APO_CFG[GPU_CANDIDATES]}"
finalize_discovered_fixture batocera-auto
(( APO_NEED_GPU == 1 && APO_REQUIRE_GPU_STRESS == 1 ))
APO_STATE=()
apo_state_load "$TEMP_DIR/batocera-auto.state"
[[ ${APO_STATE[CFG_CPU_CANDIDATES]} == '2500,2600,2700,2800,2900,3000,3100,3200' ]]
[[ ${APO_STATE[CFG_GPU_CANDIDATES]} == '850,900,950,1000,1050,1100,1150,1200' ]]
grep -Fxq 'cpu_candidates_mhz=2500,2600,2700,2800,2900,3000,3100,3200' "$TEMP_DIR/batocera-auto.conf"
grep -Fxq 'gpu_candidates_mhz=850,900,950,1000,1050,1100,1150,1200' "$TEMP_DIR/batocera-auto.conf"
APO_COMMAND=run
APO_DRY_RUN=0
APO_CONFIG_FILE=''
APO_MODE_REQUESTED=auto
apo_config_load_for_new_run
resolve_discovered_auto_plan batocera 2400 800 0
[[ "${APO_CFG[CPU_CANDIDATES]}|${APO_CFG[GPU_CANDIDATES]}" == "$BATOCERA_AUTO_PLAN" ]]

expect_auto_stock_rejection() {
    local fixture_name=$1 cpu_mhz=$2 gpu_mhz=$3 voltage_uv=$4 provenance=${5:-verified-default} evidence=${6:-none}
    local output_file="$TEMP_DIR/reject-${fixture_name}.out" status
    set +e
    (
        APO_COMMAND=run
        APO_DRY_RUN=0
        APO_CONFIG_FILE=''
        APO_MODE_REQUESTED=auto
        apo_config_load_for_new_run
        resolve_discovered_auto_plan debian "$cpu_mhz" "$gpu_mhz" "$voltage_uv" "$provenance" "$evidence"
    ) >"$output_file" 2>&1
    status=$?
    set -e
    if (( status != APO_EXIT_PREFLIGHT )); then
        echo "automatic stock rejection returned $status for $fixture_name, expected $APO_EXIT_PREFLIGHT" >&2
        cat "$output_file" >&2
        exit 1
    fi
    grep -Fq "discovered CPU=${cpu_mhz}MHz, V3D=${gpu_mhz}MHz, voltage-delta=${voltage_uv}uV" "$output_file"
    grep -Fq 'AutoPiOverclock will not rewrite permanent clocks to manufacture a baseline.' "$output_file"
    ! grep -q '3100,3200' "$output_file"
}

(
    APO_COMMAND=prepare
    APO_DRY_RUN=0
    APO_CONFIG_FILE=''
    APO_MODE_REQUESTED=auto
    APO_EDGE_CPU_24H=0
    apo_config_load_for_new_run
    [[ $APO_AUTO_GENERATED_CANDIDATES == 0 ]]
    [[ $APO_AUTO_CANDIDATES_PENDING == 0 ]]
    [[ -z ${APO_CFG[CPU_CANDIDATES]} && -z ${APO_CFG[GPU_CANDIDATES]} ]]
    apo_config_stock_auto_baseline_ready 2400 960 0 verified-default none
    ! apo_config_stock_auto_baseline_ready 3000 960 0 explicit-override arm_freq
)
expect_auto_stock_rejection existing-overclock 3000 800 50000
expect_auto_stock_rejection cpu-overclock 3000 800 0
expect_auto_stock_rejection gpu-overclock 2400 950 0
expect_auto_stock_rejection voltage-overclock 2400 800 50000
expect_auto_stock_rejection underclock 2300 800 0
expect_auto_stock_rejection explicit-stock-values 2400 960 0 explicit-override arm_freq,v3d_freq
expect_auto_stock_rejection ambiguous-provenance 2400 800 0 ambiguous unreadable-config-or-include
expect_auto_stock_rejection missing-provenance 2400 800 0 missing missing
expect_auto_stock_rejection inconsistent-provenance 2400 800 0 verified-default arm_freq

[[ $(apo_config_auto_ladder 3150 100 3200 600) == 3200 ]]
[[ $(apo_config_auto_ladder 1190 50 1200 200) == 1200 ]]
[[ $(apo_config_auto_ladder_from_exact 2975 100 3200 600) == '2975,3075,3175,3200' ]]
[[ $(apo_config_auto_ladder_from_exact 1150 50 1200 200) == '1150,1200' ]]

[[ $(apo_config_auto_ladder 500 100 3200 600) == 600,*3200 ]]
[[ $(apo_config_auto_ladder 100 50 1200 200) == 200,*1200 ]]

[[ -z $(apo_config_auto_ladder 5000 100 3200 600) ]]
[[ $(apo_config_auto_ladder 800 50 1200 200) == '850,900,950,1000,1050,1100,1150,1200' ]]

set +e
timeout 5 env APO_ROOT="$ROOT" bash -c 'source "$APO_ROOT/lib/common.sh"; source "$APO_ROOT/lib/config.sh"; apo_config_auto_ladder 999999999999999999999999 100 3200' >"$TEMP_DIR/huge-ladder.out" 2>&1
huge_ladder_status=$?
set -e
if (( huge_ladder_status != 1 )); then
    echo "automatic ladder returned the wrong status for an oversized baseline (expected 1, got $huge_ladder_status)" >&2
    cat "$TEMP_DIR/huge-ladder.out" >&2
    exit 1
fi

set +e
timeout 5 env APO_ROOT="$ROOT" bash -c '
    source "$APO_ROOT/lib/common.sh"
    source "$APO_ROOT/lib/config.sh"
    source "$APO_ROOT/lib/detect.sh"
    apo_config_defaults
    APO_COMMAND=prepare
    APO_DRY_RUN=0
    APO_MODE_EFFECTIVE=headless
    APO_DISCOVERY=(
        [BOOT_CONFIG]=/boot/config.txt
        [TRYBOOT_CONFIG]=/boot/tryboot.txt
        [TRYBOOT_EXISTS]=0
        [TRYBOOT_TYPE]=absent
        [TRYBOOT_HASH]=unavailable
        [BOOT_MOUNT]=/boot
        [GPU_KEY]=v3d_freq
        [NORMAL_CPU]=999999999999999999999999
        [NORMAL_GPU]=800
        [NORMAL_VOLTAGE]=0
        [PERMANENT_HASH]=$(printf "b%.0s" {1..64})
    )
    apo_context_from_discovery
' >"$TEMP_DIR/huge-context.out" 2>&1
huge_context_status=$?
set -e
if (( huge_context_status != APO_EXIT_PREFLIGHT )); then
    echo "discovery returned the wrong status for an oversized normal CPU clock (expected $APO_EXIT_PREFLIGHT, got $huge_context_status)" >&2
    cat "$TEMP_DIR/huge-context.out" >&2
    exit 1
fi

[[ -z $(apo_config_auto_ladder 3200 100 3200 600) ]]
[[ $(apo_config_auto_ladder 1100 50 1200 200) == '1150,1200' ]]
[[ -z $(apo_config_auto_ladder 1200 50 1200 200) ]]

(
    APO_COMMAND=run
    APO_PUBLIC_COMMAND=overclock
    APO_DRY_RUN=0
    APO_CONFIG_FILE=''
    APO_MODE_REQUESTED=auto
    APO_SWEEP_DOMAIN=all
    APO_CPU_START_AT=3000
    APO_GPU_START_AT=1150
    apo_config_load_for_new_run
    resolve_discovered_auto_plan debian 2400 960 0
    [[ ${APO_CFG[CPU_CANDIDATES]} == '3000,3100,3200' ]]
    [[ ${APO_CFG[GPU_CANDIDATES]} == '1150,1200' ]]
)

(
    APO_COMMAND=run
    APO_PUBLIC_COMMAND=overclock
    APO_DRY_RUN=0
    APO_CONFIG_FILE=''
    APO_MODE_REQUESTED=auto
    APO_SWEEP_DOMAIN=gpu
    APO_CPU_START_AT=''
    APO_GPU_START_AT=1150
    APO_SOURCE_APPLIED_RUN_ID=20260903-120000-0123456789abcdef
    APO_SOURCE_APPLIED_PERMANENT_HASH=$(printf 'b%.0s' {1..64})
    APO_SOURCE_APPLIED_CPU=3100
    APO_SOURCE_APPLIED_GPU=1125
    APO_SOURCE_APPLIED_VOLTAGE=0
    APO_SOURCE_AUTO_BASELINE_CPU=2400
    APO_SOURCE_AUTO_BASELINE_GPU=960
    APO_SOURCE_AUTO_BASELINE_VOLTAGE=0
    APO_SOURCE_AUTO_BASELINE_PROVENANCE=verified-default
    APO_SOURCE_AUTO_BASELINE_EVIDENCE=none
    APO_SOURCE_APPLIED_PROFILE=debian
    APO_SOURCE_APPLIED_BOOT_CONFIG=/boot/config.txt
    APO_SOURCE_APPLIED_TRYBOOT_CONFIG=/boot/tryboot.txt
    APO_SOURCE_APPLIED_GPU_KEY=v3d_freq
    apo_config_load_for_new_run
    resolve_discovered_auto_plan debian 3100 1125 0 explicit-override arm_freq,v3d_freq
    [[ -z ${APO_CFG[CPU_CANDIDATES]} ]]
    [[ ${APO_CFG[GPU_CANDIDATES]} == '1150,1200' ]]
    [[ ${APO_GPU_CANDIDATES[*]} == '1150 1200' ]]
    finalize_discovered_fixture gpu-only-applied
    apo_store_discovery_state
    (( APO_REQUIRE_GPU_STRESS == 1 ))
    APO_STATE=()
    apo_state_load "$TEMP_DIR/gpu-only-applied.state"
    [[ ${APO_STATE[CFG_SWEEP_DOMAIN]} == gpu ]]
    [[ ${APO_STATE[CFG_SELECTION_POLICY]} == refined-max-25 ]]
    [[ ${APO_STATE[CFG_GPU_START_AT]} == 1150 && -z ${APO_STATE[CFG_CPU_START_AT]} ]]
    [[ ${APO_STATE[SOURCE_APPLIED_RUN_ID]} == 20260903-120000-0123456789abcdef ]]
    [[ ${APO_STATE[SOURCE_APPLIED_CPU]} == 3100 && ${APO_STATE[SOURCE_APPLIED_GPU]} == 1125 ]]
    [[ ${APO_STATE[SOURCE_APPLIED_LIVE_HASH]} == "${APO_STATE[SOURCE_APPLIED_PERMANENT_HASH]}" ]]
    [[ ${APO_STATE[SOURCE_APPLIED_HASH_RELATION]} == exact ]]
    [[ ${APO_STATE[SOURCE_APPLIED_HASH_EVIDENCE]} == live-hash-equals-retained-applied-hash ]]
    [[ ${APO_STATE[AUTO_BASELINE_CPU]} == 2400 && ${APO_STATE[AUTO_BASELINE_GPU]} == 960 ]]
    [[ ${APO_STATE[SOURCE_APPLIED_PROFILE]} == debian ]]
    [[ ${APO_STATE[SOURCE_APPLIED_BOOT_CONFIG]} == /boot/config.txt ]]
    [[ ${APO_STATE[SOURCE_APPLIED_TRYBOOT_CONFIG]} == /boot/tryboot.txt ]]
    [[ ${APO_STATE[SOURCE_APPLIED_GPU_KEY]} == v3d_freq ]]
    [[ ${APO_STATE[SOURCE_AUTO_BASELINE_CPU]} == 2400 && ${APO_STATE[SOURCE_AUTO_BASELINE_GPU]} == 960 ]]
    [[ ${APO_STATE[SOURCE_AUTO_BASELINE_VOLTAGE]} == 0 ]]
    [[ ${APO_STATE[SOURCE_AUTO_BASELINE_PROVENANCE]} == verified-default ]]
    [[ ${APO_STATE[SOURCE_AUTO_BASELINE_EVIDENCE]} == none ]]
    APO_SOURCE_APPLIED_PROFILE=''
    APO_SOURCE_APPLIED_BOOT_CONFIG=''
    APO_SOURCE_APPLIED_TRYBOOT_CONFIG=''
    APO_SOURCE_APPLIED_GPU_KEY=''
    APO_SOURCE_APPLIED_LIVE_HASH=''
    APO_SOURCE_APPLIED_HASH_RELATION=''
    APO_SOURCE_APPLIED_HASH_EVIDENCE=''
    APO_SOURCE_AUTO_BASELINE_CPU=''
    APO_SOURCE_AUTO_BASELINE_GPU=''
    APO_SOURCE_AUTO_BASELINE_VOLTAGE=''
    APO_SOURCE_AUTO_BASELINE_PROVENANCE=''
    APO_SOURCE_AUTO_BASELINE_EVIDENCE=''
    apo_config_restore_from_state
    [[ $APO_SOURCE_APPLIED_PROFILE == debian && $APO_SOURCE_APPLIED_GPU_KEY == v3d_freq ]]
    [[ $APO_SOURCE_APPLIED_BOOT_CONFIG == /boot/config.txt && $APO_SOURCE_APPLIED_TRYBOOT_CONFIG == /boot/tryboot.txt ]]
    [[ $APO_SOURCE_APPLIED_LIVE_HASH == "$APO_SOURCE_APPLIED_PERMANENT_HASH" ]]
    [[ $APO_SOURCE_APPLIED_HASH_RELATION == exact && $APO_SOURCE_APPLIED_HASH_EVIDENCE == live-hash-equals-retained-applied-hash ]]
    [[ $APO_SOURCE_AUTO_BASELINE_CPU == 2400 && $APO_SOURCE_AUTO_BASELINE_GPU == 960 && $APO_SOURCE_AUTO_BASELINE_VOLTAGE == 0 ]]
    [[ $APO_SOURCE_AUTO_BASELINE_PROVENANCE == verified-default && $APO_SOURCE_AUTO_BASELINE_EVIDENCE == none ]]
)
if (
    APO_STATE=()
    apo_state_load "$TEMP_DIR/gpu-only-applied.state"
    unset 'APO_STATE[SOURCE_APPLIED_GPU_KEY]'
    apo_config_restore_from_state
) >/dev/null 2>&1; then
    echo 'domain-only state missing an exact applied-source binding field was accepted' >&2
    exit 1
fi

# A domain-only run may adopt a live applied config whose byte hash changed
# only because full-line comments/blank lines changed. It may also accept the
# removal of the exact project-written zero-voltage line from the verified
# managed clock block. Any active drift or malformed marker still fails closed.
DOMAIN_SOURCE_RUN=20260903-120000-aabbccddeeff0011
DOMAIN_SOURCE_STATE="$TEMP_DIR/domain-source-${DOMAIN_SOURCE_RUN}.state"
DOMAIN_SOURCE_ARTIFACT="${DOMAIN_SOURCE_STATE%.state}-apply-proposed-config.txt"
: > "$DOMAIN_SOURCE_STATE"
cat > "$DOMAIN_SOURCE_ARTIFACT" <<CONF
# Original user explanation
[all]
dtparam=audio=on

# BEGIN AUTOPIOVERCLOCK MANAGED CLOCKS
# Run: $DOMAIN_SOURCE_RUN
[all]
over_voltage_delta=0
arm_freq=3100
v3d_freq=1125
# END AUTOPIOVERCLOCK MANAGED CLOCKS
# Original tail
CONF
DOMAIN_SOURCE_HASH=$(sha256sum "$DOMAIN_SOURCE_ARTIFACT" | awk 'NR == 1 {print $1}')

run_domain_source_reconcile_fixture() {
    local live_file=$1 fixture_name=$2
    APO_DOMAIN_SOURCE_STATE=$DOMAIN_SOURCE_STATE
    APO_RUN_PREFIX="$TEMP_DIR/reconcile-$fixture_name"
    APO_BOOT_CONFIG=/boot/config.txt
    APO_SOURCE_APPLIED_RUN_ID=$DOMAIN_SOURCE_RUN
    APO_SOURCE_APPLIED_PERMANENT_HASH=$DOMAIN_SOURCE_HASH
    APO_SOURCE_APPLIED_CPU=3100
    APO_SOURCE_APPLIED_GPU=1125
    APO_SOURCE_APPLIED_VOLTAGE=0
    APO_SOURCE_APPLIED_GPU_KEY=v3d_freq
    APO_NORMAL_VOLTAGE=0
    APO_PERMANENT_CONFIG_HASH=$(sha256sum "$live_file" | awk 'NR == 1 {print $1}')
    DOMAIN_LIVE_FILE=$live_file
    apo_remote_root_read_file() { cp "$DOMAIN_LIVE_FILE" "$1"; }
    apo_reconcile_domain_sweep_source_hash
}

cat > "$TEMP_DIR/domain-live-comments.txt" <<CONF
# Rewritten user explanation

[all]
dtparam=audio=on
# Another harmless comment
# BEGIN AUTOPIOVERCLOCK MANAGED CLOCKS
# Run: $DOMAIN_SOURCE_RUN
[all]
over_voltage_delta=0
arm_freq=3100
v3d_freq=1125
# END AUTOPIOVERCLOCK MANAGED CLOCKS
CONF
(
    run_domain_source_reconcile_fixture "$TEMP_DIR/domain-live-comments.txt" comments
    [[ $APO_SOURCE_APPLIED_HASH_RELATION == comment-only ]]
    [[ $APO_SOURCE_APPLIED_LIVE_HASH == "$APO_PERMANENT_CONFIG_HASH" ]]
    [[ $APO_SOURCE_APPLIED_HASH_EVIDENCE == source-artifact-hash-and-managed-block-verified-active-lines-identical ]]
)

cat > "$TEMP_DIR/domain-live-zero-removed.txt" <<CONF
[all]
dtparam=audio=on
# BEGIN AUTOPIOVERCLOCK MANAGED CLOCKS
# Run: $DOMAIN_SOURCE_RUN
[all]
arm_freq=3100
v3d_freq=1125
# END AUTOPIOVERCLOCK MANAGED CLOCKS
# over_voltage_delta=0 was project-written and intentionally omitted
CONF
(
    run_domain_source_reconcile_fixture "$TEMP_DIR/domain-live-zero-removed.txt" zero-removed
    [[ $APO_SOURCE_APPLIED_HASH_RELATION == comment-only-project-zero-removed ]]
    [[ $APO_SOURCE_APPLIED_HASH_EVIDENCE == source-artifact-hash-and-managed-block-verified-active-lines-identical-after-project-zero-removal ]]
)

cat > "$TEMP_DIR/domain-live-active-drift.txt" <<CONF
[all]
dtparam=audio=off
# BEGIN AUTOPIOVERCLOCK MANAGED CLOCKS
# Run: $DOMAIN_SOURCE_RUN
[all]
over_voltage_delta=0
arm_freq=3100
v3d_freq=1125
# END AUTOPIOVERCLOCK MANAGED CLOCKS
CONF
if (run_domain_source_reconcile_fixture "$TEMP_DIR/domain-live-active-drift.txt" active-drift) >"$TEMP_DIR/domain-active-drift.out" 2>&1; then
    echo 'domain-only source reconciliation accepted active config drift' >&2
    exit 1
fi
grep -Fq 'active drift beyond a strictly verified comment-only change' "$TEMP_DIR/domain-active-drift.out"

sed 's/# BEGIN AUTOPIOVERCLOCK MANAGED CLOCKS/# BEGIN AUTOPIOVERCLOCK MANAGED CLOCKS BROKEN/' \
    "$TEMP_DIR/domain-live-comments.txt" > "$TEMP_DIR/domain-live-malformed-marker.txt"
if (run_domain_source_reconcile_fixture "$TEMP_DIR/domain-live-malformed-marker.txt" malformed-marker) >"$TEMP_DIR/domain-malformed-marker.out" 2>&1; then
    echo 'domain-only source reconciliation accepted malformed managed markers' >&2
    exit 1
fi
grep -Fq 'malformed or mismatched AutoPiOverclock clock markers' "$TEMP_DIR/domain-malformed-marker.out"

# Exact hashes retain the historical fast path and do not require an artifact
# read, but still persist the exact relation used by resume validation.
(
    APO_SOURCE_APPLIED_PERMANENT_HASH=$DOMAIN_SOURCE_HASH
    APO_PERMANENT_CONFIG_HASH=$DOMAIN_SOURCE_HASH
    APO_SOURCE_APPLIED_LIVE_HASH=''
    APO_SOURCE_APPLIED_HASH_RELATION=''
    APO_SOURCE_APPLIED_HASH_EVIDENCE=''
    apo_remote_root_read_file() { return 99; }
    apo_reconcile_domain_sweep_source_hash
    [[ $APO_SOURCE_APPLIED_LIVE_HASH == "$DOMAIN_SOURCE_HASH" ]]
    [[ $APO_SOURCE_APPLIED_HASH_RELATION == exact ]]
    [[ $APO_SOURCE_APPLIED_HASH_EVIDENCE == live-hash-equals-retained-applied-hash ]]
)

(
    APO_COMMAND=run
    APO_PUBLIC_COMMAND=overclock
    APO_DRY_RUN=0
    APO_CONFIG_FILE=''
    APO_MODE_REQUESTED=auto
    APO_SWEEP_DOMAIN=cpu
    APO_CPU_START_AT=3000
    APO_GPU_START_AT=''
    APO_SOURCE_APPLIED_RUN_ID=20260903-120000-fedcba9876543210
    APO_SOURCE_APPLIED_PERMANENT_HASH=$(printf 'b%.0s' {1..64})
    APO_SOURCE_APPLIED_CPU=2900
    APO_SOURCE_APPLIED_GPU=1175
    APO_SOURCE_APPLIED_VOLTAGE=0
    APO_SOURCE_AUTO_BASELINE_CPU=2400
    APO_SOURCE_AUTO_BASELINE_GPU=960
    APO_SOURCE_AUTO_BASELINE_VOLTAGE=0
    APO_SOURCE_AUTO_BASELINE_PROVENANCE=verified-default
    APO_SOURCE_AUTO_BASELINE_EVIDENCE=none
    APO_SOURCE_APPLIED_PROFILE=debian
    APO_SOURCE_APPLIED_BOOT_CONFIG=/boot/config.txt
    APO_SOURCE_APPLIED_TRYBOOT_CONFIG=/boot/tryboot.txt
    APO_SOURCE_APPLIED_GPU_KEY=v3d_freq
    apo_config_load_for_new_run
    resolve_discovered_auto_plan debian 2900 1175 0 explicit-override arm_freq,v3d_freq
    [[ ${APO_CFG[CPU_CANDIDATES]} == '3000,3100,3200' ]]
    [[ -z ${APO_CFG[GPU_CANDIDATES]} ]]
)

(
    APO_STATE=()
    apo_state_set CFG_SELECTION_POLICY refined-max-25
    apo_state_set CFG_SWEEP_DOMAIN all
    apo_config_restore_from_state
    [[ $APO_SELECTION_POLICY == refined-max-25 && $APO_SWEEP_DOMAIN == all ]]
)
if (
    APO_STATE=()
    apo_state_set CFG_SELECTION_POLICY refined-max-25
    apo_state_set CFG_SWEEP_DOMAIN all
    apo_state_set CFG_CPU_START_AT 3010
    apo_config_restore_from_state
) >/dev/null 2>&1; then
    echo 'saved CPU starting clock not aligned to 25 MHz was accepted' >&2
    exit 1
fi
if (
    APO_STATE=()
    apo_state_set CFG_SELECTION_POLICY refined-max-25
    apo_state_set CFG_SWEEP_DOMAIN all
    apo_state_set CFG_GPU_START_AT 1160
    apo_config_restore_from_state
) >/dev/null 2>&1; then
    echo 'saved GPU starting clock not aligned to 25 MHz was accepted' >&2
    exit 1
fi
(
    APO_STATE=()
    apo_config_restore_from_state
    [[ $APO_SELECTION_POLICY == guarded-v1 && $APO_SWEEP_DOMAIN == all ]]
)

APO_COMMAND=run
APO_MODE_REQUESTED=auto
APO_CONFIG_FILE="$TEMP_DIR/valid.conf"
apo_config_load_for_new_run
resolve_discovered_auto_plan debian 500 100 0 explicit-override arm_freq,gpu_freq
[[ ${APO_CFG[CPU_CANDIDATES]} == '2700,2800,2900' ]]
[[ ${APO_CFG[GPU_CANDIDATES]} == '800,850,900' ]]

MARKER="$TEMP_DIR/should-not-exist"
cat > "$TEMP_DIR/data-only.conf" <<CONF
audio_sink_pattern=\$(touch $MARKER)
CONF
apo_config_defaults
apo_config_read_file "$TEMP_DIR/data-only.conf"
[[ ! -e $MARKER ]]

if (apo_config_defaults; printf 'UNKNOWN_KEY=value\n' > "$TEMP_DIR/bad.conf"; apo_config_read_file "$TEMP_DIR/bad.conf") >/dev/null 2>&1; then
    echo 'unknown configuration key was accepted' >&2
    exit 1
fi
for removed_key in CPU_CANDIDATES REQUIRED_PROCESSES EXTRA_PING_TARGET HEALTH_HOOK; do
    if (apo_config_defaults; printf '%s=value\n' "$removed_key" > "$TEMP_DIR/removed.conf"; apo_config_read_file "$TEMP_DIR/removed.conf") >/dev/null 2>&1; then
        echo "removed or uppercase configuration key was accepted: $removed_key" >&2
        exit 1
    fi
done
if (apo_config_defaults; APO_CFG[CPU_CANDIDATES]='2900,2800'; apo_config_validate) >/dev/null 2>&1; then
    echo 'descending candidate list was accepted' >&2
    exit 1
fi
if (apo_config_defaults; APO_CFG[FINAL_DURATION_S]=3599; apo_config_validate) >/dev/null 2>&1; then
    echo 'sub-one-hour final validation was accepted' >&2
    exit 1
fi
if (apo_config_defaults; APO_CFG[TELEMETRY_INTERVAL_S]=0; apo_config_validate) >/dev/null 2>&1; then
    echo 'zero telemetry interval was accepted' >&2
    exit 1
fi
if (apo_config_defaults; APO_CFG[CANDIDATE_BOOTS]=1; apo_config_validate) >/dev/null 2>&1; then
    echo 'fewer than two candidate boots was accepted' >&2
    exit 1
fi
if (apo_config_defaults; APO_CFG[FINAL_BOOTS]=2; apo_config_validate) >/dev/null 2>&1; then
    echo 'fewer than three final boots was accepted' >&2
    exit 1
fi
if (
    APO_COMMAND=run
    APO_CONFIG_FILE=''
    APO_MODE_REQUESTED=graphical
    apo_config_guided_candidates() {
        APO_CFG[CPU_CANDIDATES]=''
        APO_CFG[GPU_CANDIDATES]=''
    }
    apo_config_load_for_new_run
) >/dev/null 2>&1; then
    echo 'guided run accepted two blank candidate responses' >&2
    exit 1
fi
printf 'test_config: PASS\n'
