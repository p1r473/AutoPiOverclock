#!/usr/bin/env bash
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
    APO_COMMAND=prepare
    APO_DRY_RUN=0
    APO_CONFIG_FILE=''
    APO_MODE_REQUESTED=auto
    APO_EDGE_CPU_24H=1
    apo_config_load_for_new_run
    resolve_discovered_auto_plan debian 2400 960 0
    [[ ${APO_CFG[FINAL_DURATION_S]} == 28800 ]]
    finalize_discovered_fixture debian-edge-auto
    APO_STATE=()
    apo_state_load "$TEMP_DIR/debian-edge-auto.state"
    [[ ${APO_STATE[CFG_EDGE_CPU_24H]} == 1 ]]
)

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
        APO_COMMAND=prepare
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
if (apo_config_defaults; APO_CFG[FINAL_DURATION_S]=28799; apo_config_validate) >/dev/null 2>&1; then
    echo 'sub-eight-hour final validation was accepted' >&2
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
