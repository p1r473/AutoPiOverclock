#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
APO_ROOT=$ROOT
source "$ROOT/lib/common.sh"
source "$ROOT/lib/config.sh"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

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
