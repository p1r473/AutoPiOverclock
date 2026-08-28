#!/usr/bin/env bash
# Strict data-only configuration. Configuration files are parsed, never sourced.

declare -Ag APO_CFG=()
declare -ag APO_CPU_CANDIDATES=()
declare -ag APO_GPU_CANDIDATES=()
readonly APO_CPU_CLOCK_MIN_MHZ=600
readonly APO_CPU_CLOCK_MAX_MHZ=4000
readonly APO_GPU_CLOCK_MIN_MHZ=200
readonly APO_GPU_CLOCK_MAX_MHZ=3000
readonly APO_AUTO_CPU_STEP_MHZ=100
readonly APO_AUTO_CPU_MAX_MHZ=3200
readonly APO_AUTO_GPU_STEP_MHZ=50
readonly APO_AUTO_GPU_MAX_MHZ=1200
readonly APO_AUTO_REFINE_STEP_MHZ=25
readonly APO_AUTO_CPU_GUARD_MHZ=50
readonly APO_AUTO_GPU_GUARD_MHZ=25
readonly APO_PI5_STOCK_CPU_MHZ=2400
readonly APO_PI5_STOCK_VOLTAGE_UV=0
APO_AUTO_CANDIDATES_PENDING=0
APO_AUTO_GENERATED_CANDIDATES=0
readonly -a APO_ALLOWED_CONFIG_KEYS=(
    cpu_candidates_mhz gpu_candidates_mhz voltage_delta_uv
    candidate_duration_seconds final_duration_seconds max_temp_c telemetry_interval_seconds
    conservative_backoff_steps candidate_boots final_boots
    required_services frontend_process audio_sink_pattern
)

apo_config_internal_key() {
    case $1 in
        cpu_candidates_mhz) printf 'CPU_CANDIDATES' ;;
        gpu_candidates_mhz) printf 'GPU_CANDIDATES' ;;
        voltage_delta_uv) printf 'VOLTAGE_DELTA_UV' ;;
        candidate_duration_seconds) printf 'CANDIDATE_DURATION_S' ;;
        final_duration_seconds) printf 'FINAL_DURATION_S' ;;
        max_temp_c) printf 'MAX_TEMP_C' ;;
        telemetry_interval_seconds) printf 'TELEMETRY_INTERVAL_S' ;;
        conservative_backoff_steps) printf 'BACKOFF_STEPS' ;;
        candidate_boots) printf 'CANDIDATE_BOOTS' ;;
        final_boots) printf 'FINAL_BOOTS' ;;
        required_services) printf 'REQUIRED_SERVICES' ;;
        frontend_process) printf 'REQUIRED_PROCESSES' ;;
        audio_sink_pattern) printf 'AUDIO_SINK_MATCH' ;;
        *) return 1 ;;
    esac
}

apo_config_defaults() {
    APO_CFG=()
    APO_AUTO_CANDIDATES_PENDING=0
    APO_AUTO_GENERATED_CANDIDATES=0
    APO_CFG[CPU_CANDIDATES]=''
    APO_CFG[GPU_CANDIDATES]=''
    APO_CFG[VOLTAGE_DELTA_UV]='existing'
    APO_CFG[CANDIDATE_DURATION_S]=600
    APO_CFG[FINAL_DURATION_S]=28800
    APO_CFG[MAX_TEMP_C]=75
    APO_CFG[TELEMETRY_INTERVAL_S]=5
    APO_CFG[BACKOFF_STEPS]=1
    APO_CFG[CANDIDATE_BOOTS]=2
    APO_CFG[FINAL_BOOTS]=3
    APO_CFG[REQUIRED_PROCESSES]=''
    APO_CFG[REQUIRED_SERVICES]=''
    APO_CFG[AUDIO_SINK_MATCH]=''
    # Internal compatibility values, not accepted public configuration keys.
    APO_CFG[EXTRA_PING_TARGET]=''
    APO_CFG[HEALTH_HOOK]=''
}

apo_config_stock_auto_baseline_ready() {
    local cpu_mhz=$1 gpu_mhz=$2 voltage_uv=$3 provenance=${4:-missing} evidence=${5:-missing}
    [[ $provenance == verified-default && $evidence == none &&
       $cpu_mhz == "$APO_PI5_STOCK_CPU_MHZ" &&
       ( $gpu_mhz == 800 || $gpu_mhz == 960 ) &&
       $voltage_uv == "$APO_PI5_STOCK_VOLTAGE_UV" ]]
}

apo_config_require_stock_auto_baseline() {
    local cpu_mhz=$1 gpu_mhz=$2 voltage_uv=$3 provenance=${4:-missing} evidence=${5:-missing}
    if [[ $provenance != verified-default || $evidence != none ]]; then
        if [[ ${APO_PUBLIC_COMMAND:-} == overclock ]]; then
            apo_die "The target is not at a clean stock boot configuration. Run autopioverclock reset ${APO_RAW_TARGET}, then run autopioverclock overclock ${APO_RAW_TARGET}. Audit details: ${provenance:-missing}; evidence: ${evidence:-missing}." "$APO_EXIT_PREFLIGHT"
        fi
        apo_die "Configuration-free auto mode requires proof that one protected permanent root-config snapshot contains no explicit clock or voltage control and no unbound include directive: audit=${provenance:-missing}, evidence=${evidence:-missing}; discovered CPU=${cpu_mhz}MHz, V3D=${gpu_mhz}MHz, voltage-delta=${voltage_uv}uV. Remove or separately preserve and review arm_boost, force_turbo, initial_turbo, core_freq_fixed, every *_freq or *_freq_min assignment, every over_voltage* assignment, and any include directive, then reboot normally and repeat prepare. AutoPiOverclock will not rewrite permanent clocks to manufacture a baseline." "$APO_EXIT_PREFLIGHT"
    fi
    apo_config_stock_auto_baseline_ready "$cpu_mhz" "$gpu_mhz" "$voltage_uv" "$provenance" "$evidence" && return 0
    if [[ ${APO_PUBLIC_COMMAND:-} == overclock ]]; then
        apo_die "The target is not running stock Raspberry Pi 5 clocks (CPU=${cpu_mhz}MHz, V3D=${gpu_mhz}MHz, voltage-delta=${voltage_uv}uV). Run autopioverclock reset ${APO_RAW_TARGET}, then run autopioverclock overclock ${APO_RAW_TARGET}." "$APO_EXIT_PREFLIGHT"
    fi
    apo_die "Configuration-free auto mode requires a verified stock Raspberry Pi 5 baseline before testing any overclock: discovered CPU=${cpu_mhz}MHz, V3D=${gpu_mhz}MHz, voltage-delta=${voltage_uv}uV; expected CPU=${APO_PI5_STOCK_CPU_MHZ}MHz, V3D=800MHz or 960MHz according to the active firmware generation, and voltage-delta=${APO_PI5_STOCK_VOLTAGE_UV}uV. Restore and review the permanent boot configuration, reboot normally, and repeat prepare. AutoPiOverclock will not rewrite permanent clocks to manufacture a baseline." "$APO_EXIT_PREFLIGHT"
}

apo_config_auto_ladder() {
    local baseline=$1 step=$2 maximum=$3 minimum=${4:-0} candidate ladder=''
    [[ $baseline =~ ^(0|[1-9][0-9]{0,8})$ && $step =~ ^[1-9][0-9]{0,3}$ && $maximum =~ ^[1-9][0-9]{0,3}$ && $minimum =~ ^(0|[1-9][0-9]{0,3})$ ]] || return 1
    (( step <= APO_CPU_CLOCK_MAX_MHZ && maximum <= APO_CPU_CLOCK_MAX_MHZ && minimum <= maximum )) || return 1
    if (( baseline >= maximum )); then
        return 0
    fi
    candidate=$(( ((baseline / step) + 1) * step ))
    if (( candidate < minimum )); then
        candidate=$(( ((minimum + step - 1) / step) * step ))
    fi
    while (( candidate <= maximum )); do
        ladder=$(apo_append_csv "$ladder" "$candidate")
        candidate=$((candidate + step))
    done
    printf '%s' "$ladder"
}

apo_config_resolve_auto_candidates() {
    local normal_cpu=$1 normal_gpu=$2 normal_voltage=$3 provenance=${4:-missing} evidence=${5:-missing}
    if (( APO_AUTO_GENERATED_CANDIDATES == 1 )); then
        apo_config_require_stock_auto_baseline "$normal_cpu" "$normal_gpu" "$normal_voltage" "$provenance" "$evidence"
    fi
    (( APO_AUTO_CANDIDATES_PENDING == 1 )) || return 0
    APO_CFG[CPU_CANDIDATES]=$(apo_config_auto_ladder "$normal_cpu" "$APO_AUTO_CPU_STEP_MHZ" "$APO_AUTO_CPU_MAX_MHZ" "$APO_CPU_CLOCK_MIN_MHZ") ||
        apo_die 'Could not derive automatic CPU candidates from the discovered baseline.' "$APO_EXIT_INTERNAL"
    APO_CFG[GPU_CANDIDATES]=$(apo_config_auto_ladder "$normal_gpu" "$APO_AUTO_GPU_STEP_MHZ" "$APO_AUTO_GPU_MAX_MHZ" "$APO_GPU_CLOCK_MIN_MHZ") ||
        apo_die 'Could not derive automatic GPU/V3D candidates from the discovered baseline.' "$APO_EXIT_INTERNAL"
    # Automatic refinement and its explicit MHz guard replace list-index backoff.
    APO_CFG[BACKOFF_STEPS]=0
    APO_AUTO_CANDIDATES_PENDING=0
    apo_config_validate
    if [[ ${APO_COMMAND:-prepare} == run && ${APO_DRY_RUN:-0} == 0 && -z ${APO_CFG[CPU_CANDIDATES]} && -z ${APO_CFG[GPU_CANDIDATES]} ]]; then
        apo_die "The discovered CPU and GPU clocks are already at or above the automatic ceilings (${APO_AUTO_CPU_MAX_MHZ}/${APO_AUTO_GPU_MAX_MHZ} MHz). Supply an explicit --config plan." "$APO_EXIT_USAGE"
    fi
}

apo_config_key_allowed() {
    local candidate_key=$1 allowed_key
    for allowed_key in "${APO_ALLOWED_CONFIG_KEYS[@]}"; do
        [[ $candidate_key == "$allowed_key" ]] && return 0
    done
    return 1
}

apo_config_read_file() {
    local config_file=$1 line key internal_key value line_number=0
    [[ -r $config_file ]] || apo_die "Cannot read configuration file: $config_file" "$APO_EXIT_USAGE"
    while IFS= read -r line || [[ -n $line ]]; do
        line_number=$((line_number + 1))
        line=${line%$'\r'}
        line=$(apo_trim "$line")
        [[ -z $line || $line == \#* ]] && continue
        [[ $line == *=* ]] || apo_die "$config_file:$line_number: expected KEY=VALUE" "$APO_EXIT_USAGE"
        key=$(apo_trim "${line%%=*}")
        value=$(apo_trim "${line#*=}")
        apo_config_key_allowed "$key" || apo_die "$config_file:$line_number: unknown key $key" "$APO_EXIT_USAGE"
        internal_key=$(apo_config_internal_key "$key") || apo_die "$config_file:$line_number: unknown key $key" "$APO_EXIT_USAGE"
        if (( ${#value} >= 2 )); then
            if [[ $value == \"*\" || $value == \'*\' ]]; then value=${value:1:${#value}-2}; fi
        fi
        [[ $value != *$'\n'* && $value != *$'\r'* ]] || apo_die "$config_file:$line_number: multiline values are not allowed" "$APO_EXIT_USAGE"
        APO_CFG[$internal_key]=$value
    done < "$config_file"
}

apo_parse_ordered_int_list() {
    local csv_value=$1 output_name=$2 minimum=$3 maximum=$4 label=$5 item previous=-1
    local -n output_array=$output_name
    local -a raw_items=()
    output_array=()
    [[ -n $csv_value ]] || return 0
    IFS=',' read -r -a raw_items <<< "$csv_value"
    for item in "${raw_items[@]}"; do
        item=$(apo_trim "$item")
        apo_is_uint "$item" || apo_die "$label contains a non-integer value: $item" "$APO_EXIT_USAGE"
        (( item >= minimum && item <= maximum )) || apo_die "$label value $item is outside $minimum-$maximum" "$APO_EXIT_USAGE"
        (( item > previous )) || apo_die "$label must be strictly increasing with no duplicates" "$APO_EXIT_USAGE"
        output_array+=("$item")
        previous=$item
    done
}

apo_validate_name_list() {
    local config_key=$1 public_key=$2 item
    local -a items=()
    apo_csv_to_array "${APO_CFG[$config_key]}" items
    for item in "${items[@]}"; do
        apo_is_safe_name "$item" || apo_die "$public_key contains an unsafe name: $item" "$APO_EXIT_USAGE"
    done
}

apo_config_validate() {
    apo_parse_ordered_int_list "${APO_CFG[CPU_CANDIDATES]}" APO_CPU_CANDIDATES "$APO_CPU_CLOCK_MIN_MHZ" "$APO_CPU_CLOCK_MAX_MHZ" cpu_candidates_mhz
    apo_parse_ordered_int_list "${APO_CFG[GPU_CANDIDATES]}" APO_GPU_CANDIDATES "$APO_GPU_CLOCK_MIN_MHZ" "$APO_GPU_CLOCK_MAX_MHZ" gpu_candidates_mhz
    apo_validate_uint_range "${APO_CFG[CANDIDATE_DURATION_S]}" 10 86400 || apo_die 'candidate_duration_seconds must be 10-86400.' "$APO_EXIT_USAGE"
    apo_validate_uint_range "${APO_CFG[FINAL_DURATION_S]}" "$APO_MIN_FINAL_DURATION_S" 604800 || apo_die 'final_duration_seconds must be 28800-604800; final validation requires at least eight hours.' "$APO_EXIT_USAGE"
    apo_validate_uint_range "${APO_CFG[MAX_TEMP_C]}" 40 95 || apo_die 'max_temp_c must be 40-95.' "$APO_EXIT_USAGE"
    apo_validate_uint_range "${APO_CFG[TELEMETRY_INTERVAL_S]}" 1 60 || apo_die 'telemetry_interval_seconds must be 1-60.' "$APO_EXIT_USAGE"
    apo_validate_uint_range "${APO_CFG[BACKOFF_STEPS]}" 0 10 || apo_die 'conservative_backoff_steps must be 0-10.' "$APO_EXIT_USAGE"
    apo_validate_uint_range "${APO_CFG[CANDIDATE_BOOTS]}" 2 10 || apo_die 'candidate_boots must be 2-10.' "$APO_EXIT_USAGE"
    apo_validate_uint_range "${APO_CFG[FINAL_BOOTS]}" 3 10 || apo_die 'final_boots must be 3-10.' "$APO_EXIT_USAGE"
    if [[ ${APO_CFG[VOLTAGE_DELTA_UV]} != existing ]]; then
        apo_is_int "${APO_CFG[VOLTAGE_DELTA_UV]}" || apo_die 'voltage_delta_uv must be existing or an integer.' "$APO_EXIT_USAGE"
        (( APO_CFG[VOLTAGE_DELTA_UV] >= 0 && APO_CFG[VOLTAGE_DELTA_UV] <= 100000 )) || apo_die 'voltage_delta_uv must be 0-100000.' "$APO_EXIT_USAGE"
    fi
    if [[ -n ${APO_CFG[REQUIRED_PROCESSES]} ]]; then
        apo_is_safe_name "${APO_CFG[REQUIRED_PROCESSES]}" || apo_die 'frontend_process contains an unsafe name.' "$APO_EXIT_USAGE"
    fi
    apo_validate_name_list REQUIRED_SERVICES required_services
    if [[ -n ${APO_CFG[AUDIO_SINK_MATCH]} ]]; then
        [[ ${APO_CFG[AUDIO_SINK_MATCH]} =~ ^[A-Za-z0-9_.:@/+[:space:]-]+$ ]] || apo_die 'audio_sink_pattern contains unsafe characters.' "$APO_EXIT_USAGE"
    fi
}

apo_config_guided_candidates() {
    local answer
    [[ -t 0 ]] || return 1
    printf 'CPU candidates in increasing MHz order (comma-separated; blank to skip): ' >&2
    IFS= read -r answer
    APO_CFG[CPU_CANDIDATES]=$(apo_trim "$answer")
    printf 'GPU/V3D candidates in increasing MHz order (comma-separated; blank to skip): ' >&2
    IFS= read -r answer
    APO_CFG[GPU_CANDIDATES]=$(apo_trim "$answer")
}

apo_config_load_for_new_run() {
    apo_config_defaults
    [[ -z ${APO_CONFIG_FILE:-} ]] || apo_config_read_file "$APO_CONFIG_FILE"
    if [[ ${APO_COMMAND:-prepare} == run && -z ${APO_CONFIG_FILE:-} && ${APO_MODE_REQUESTED:-auto} == auto && -z ${APO_CFG[CPU_CANDIDATES]} && -z ${APO_CFG[GPU_CANDIDATES]} ]]; then
        APO_AUTO_CANDIDATES_PENDING=1
        APO_AUTO_GENERATED_CANDIDATES=1
    fi
    if (( ${APO_EDGE_CPU_24H:-0} == 1 )); then
        (( APO_AUTO_GENERATED_CANDIDATES == 1 )) ||
            apo_die '--edge-cpu-24h requires configuration-free automatic candidates.' "$APO_EXIT_USAGE"
    fi
    if [[ ${APO_COMMAND:-prepare} == run && -z ${APO_CFG[CPU_CANDIDATES]} && -z ${APO_CFG[GPU_CANDIDATES]} ]]; then
        if (( APO_AUTO_CANDIDATES_PENDING == 1 )); then
            : # Discovery will resolve a bounded, baseline-relative plan without reading stdin.
        elif [[ -z ${APO_CONFIG_FILE:-} ]]; then
            apo_config_guided_candidates || apo_die 'A run needs cpu_candidates_mhz and/or gpu_candidates_mhz. Supply --config when noninteractive.' "$APO_EXIT_USAGE"
            [[ -n ${APO_CFG[CPU_CANDIDATES]} || -n ${APO_CFG[GPU_CANDIDATES]} ]] ||
                apo_die 'A run needs at least one fresh CPU or GPU/V3D overclock candidate; use prepare when no tuning candidate is ready.' "$APO_EXIT_USAGE"
        else
            apo_die 'The configuration skips both CPU and GPU tuning; use prepare instead of run.' "$APO_EXIT_USAGE"
        fi
    fi
    apo_config_validate
}

apo_config_store_in_state() {
    local config_key internal_key
    for config_key in "${APO_ALLOWED_CONFIG_KEYS[@]}"; do
        internal_key=$(apo_config_internal_key "$config_key")
        apo_state_set "CFG_${internal_key}" "${APO_CFG[$internal_key]}"
    done
    apo_state_set CFG_AUTO_GENERATED_CANDIDATES "$APO_AUTO_GENERATED_CANDIDATES"
    apo_state_set CFG_EDGE_CPU_24H "${APO_EDGE_CPU_24H:-0}"
    apo_state_set CFG_MAX_FAN "${APO_MAX_FAN:-1}"
}

apo_config_restore_from_state() {
    local config_key internal_key
    apo_config_defaults
    for config_key in "${APO_ALLOWED_CONFIG_KEYS[@]}"; do
        internal_key=$(apo_config_internal_key "$config_key")
        APO_CFG[$internal_key]=$(apo_state_get "CFG_${internal_key}" "${APO_CFG[$internal_key]}")
    done
    APO_AUTO_GENERATED_CANDIDATES=$(apo_state_get CFG_AUTO_GENERATED_CANDIDATES 0)
    [[ $APO_AUTO_GENERATED_CANDIDATES == 0 || $APO_AUTO_GENERATED_CANDIDATES == 1 ]] ||
        apo_die 'Saved automatic-candidate marker is malformed.' "$APO_EXIT_INTERNAL"
    APO_EDGE_CPU_24H=$(apo_state_get CFG_EDGE_CPU_24H 0)
    [[ $APO_EDGE_CPU_24H == 0 || $APO_EDGE_CPU_24H == 1 ]] ||
        apo_die 'Saved edge-CPU marker is malformed.' "$APO_EXIT_INTERNAL"
    APO_MAX_FAN=$(apo_state_get CFG_MAX_FAN 1)
    [[ $APO_MAX_FAN == 0 || $APO_MAX_FAN == 1 ]] ||
        apo_die 'Saved maximum-fan policy is malformed.' "$APO_EXIT_INTERNAL"
    apo_config_validate
}

apo_write_effective_config() {
    local destination=$1 config_key internal_key
    {
        printf '# AutoPiOverclock effective configuration for run %s\n' "${APO_RUN_ID:-unknown}"
        printf '# candidate_max_fan=%s (controller policy; use --no-max-fan to opt out on a new run)\n' \
            "$([[ ${APO_MAX_FAN:-1} == 1 ]] && printf enabled || printf disabled)"
        for config_key in "${APO_ALLOWED_CONFIG_KEYS[@]}"; do
            internal_key=$(apo_config_internal_key "$config_key")
            printf '%s=%s\n' "$config_key" "${APO_CFG[$internal_key]}"
        done
    } | apo_atomic_write "$destination"
}
