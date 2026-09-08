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

apo_domain_resolution_mhz() {
    case $1 in
        CPU) printf '%s' "${APO_CPU_RESOLUTION_MHZ:-$APO_AUTO_REFINE_STEP_MHZ}" ;;
        GPU) printf '%s' "${APO_GPU_RESOLUTION_MHZ:-$APO_AUTO_REFINE_STEP_MHZ}" ;;
        *) return 1 ;;
    esac
}

apo_domain_coarse_step_mhz() {
    local domain=$1 resolution coarse
    resolution=$(apo_domain_resolution_mhz "$domain") || return 1
    case $domain in
        CPU) coarse=$APO_AUTO_CPU_STEP_MHZ ;;
        GPU) coarse=$APO_AUTO_GPU_STEP_MHZ ;;
        *) return 1 ;;
    esac
    (( resolution > coarse )) && coarse=$resolution
    printf '%s' "$coarse"
}
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
    APO_CFG[FINAL_DURATION_S]=$APO_DEFAULT_FINAL_DURATION_S
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

apo_config_duration_policy() {
    local qualification_duration=$1 final_duration=$2 edge_duration=$3
    if [[ $qualification_duration == "$APO_DEFAULT_QUALIFICATION_DURATION_S" &&
          $final_duration == "$APO_DEFAULT_FINAL_DURATION_S" &&
          $edge_duration == "$APO_DEFAULT_EDGE_DURATION_S" ]]; then
        printf default
    else
        printf custom
    fi
}

apo_config_saved_duration_policy_matches() {
    local qualification_duration=$1 final_duration=$2 edge_duration=$3 saved_policy=$4 expected_policy
    expected_policy=$(apo_config_duration_policy "$qualification_duration" "$final_duration" "$edge_duration")
    [[ $saved_policy == "$expected_policy" ]] && return 0
    [[ $saved_policy == default &&
       $qualification_duration == "$APO_DEFAULT_QUALIFICATION_DURATION_S" &&
       ( $final_duration == "$APO_PREVIOUS_DEFAULT_FINAL_DURATION_S" ||
         $final_duration == "$APO_LEGACY_DEFAULT_FINAL_DURATION_S" ) &&
       $edge_duration == "$APO_DEFAULT_EDGE_DURATION_S" ]]
}

apo_config_validate_duration_plan() {
    local expected_policy
    apo_validate_uint_range "${APO_QUALIFICATION_DURATION_S:-}" "$APO_MIN_TUNING_DURATION_S" "$APO_MAX_TUNING_DURATION_S" ||
        apo_die "Saved qualification duration must be ${APO_MIN_TUNING_DURATION_S}-${APO_MAX_TUNING_DURATION_S} seconds." "$APO_EXIT_INTERNAL"
    apo_validate_uint_range "${APO_CFG[FINAL_DURATION_S]:-}" "$APO_MIN_TUNING_DURATION_S" "$APO_MAX_TUNING_DURATION_S" ||
        apo_die "Saved final duration must be ${APO_MIN_TUNING_DURATION_S}-${APO_MAX_TUNING_DURATION_S} seconds." "$APO_EXIT_INTERNAL"
    apo_validate_uint_range "${APO_EDGE_DURATION_S:-}" "$APO_MIN_TUNING_DURATION_S" "$APO_MAX_TUNING_DURATION_S" ||
        apo_die "Saved edge duration must be ${APO_MIN_TUNING_DURATION_S}-${APO_MAX_TUNING_DURATION_S} seconds." "$APO_EXIT_INTERNAL"
    expected_policy=$(apo_config_duration_policy "$APO_QUALIFICATION_DURATION_S" "${APO_CFG[FINAL_DURATION_S]}" "$APO_EDGE_DURATION_S")
    apo_config_saved_duration_policy_matches "$APO_QUALIFICATION_DURATION_S" "${APO_CFG[FINAL_DURATION_S]}" \
        "$APO_EDGE_DURATION_S" "${APO_DURATION_POLICY:-$expected_policy}" ||
        apo_die 'Saved duration policy does not match its qualification/final/edge durations.' "$APO_EXIT_INTERNAL"
    APO_DURATION_POLICY=${APO_DURATION_POLICY:-$expected_policy}
}

apo_config_migrate_duration_schema_9() {
    [[ $(apo_state_get RUN_SCHEMA '') == 9 ]] || return 1
    # Schema 9 always used fixed two-hour qualifications and a fixed 24-hour
    # edge. Its saved final_duration_seconds remains authoritative.
    [[ $APO_QUALIFICATION_DURATION_S == "$APO_DEFAULT_QUALIFICATION_DURATION_S" &&
       $APO_EDGE_DURATION_S == "$APO_DEFAULT_EDGE_DURATION_S" ]] || return 1
    apo_config_validate_duration_plan
    apo_state_set CFG_QUALIFICATION_DURATION_S "$APO_QUALIFICATION_DURATION_S"
    apo_state_set CFG_EDGE_DURATION_S "$APO_EDGE_DURATION_S"
    apo_state_set CFG_DURATION_POLICY "$APO_DURATION_POLICY"
    apo_state_set RUN_SCHEMA "$APO_CURRENT_RUN_SCHEMA"
    apo_state_set APP_VERSION "$APO_VERSION"
    apo_state_save
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
    local baseline=$1 step=$2 maximum=$3 minimum=${4:-0} candidate last=0 ladder=''
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
        last=$candidate
        candidate=$((candidate + step))
    done
    # An explicit maximum is inclusive even when it falls between coarse-ladder
    # positions. That keeps a bounded run from silently stopping below its
    # requested endpoint.
    if (( maximum > baseline && last < maximum )); then
        ladder=$(apo_append_csv "$ladder" "$maximum")
    fi
    printf '%s' "$ladder"
}

apo_config_auto_ladder_from_exact() {
    local start=$1 step=$2 maximum=$3 minimum=${4:-0} candidate last=0 ladder=''
    [[ $start =~ ^[1-9][0-9]{0,3}$ && $step =~ ^[1-9][0-9]{0,3}$ &&
       $maximum =~ ^[1-9][0-9]{0,3}$ && $minimum =~ ^(0|[1-9][0-9]{0,3})$ ]] || return 1
    (( start >= minimum && start <= maximum && step <= APO_CPU_CLOCK_MAX_MHZ && minimum <= maximum )) || return 1
    candidate=$start
    while (( candidate <= maximum )); do
        ladder=$(apo_append_csv "$ladder" "$candidate")
        last=$candidate
        candidate=$((candidate + step))
    done
    # A user-selected start need not align with the coarse 100/50 MHz ladder.
    # Always test the documented ceiling instead of silently leaving a shorter
    # untested gap at the top of the selected domain.
    if (( last < maximum )); then
        ladder=$(apo_append_csv "$ladder" "$maximum")
    fi
    printf '%s' "$ladder"
}

apo_config_resolve_auto_candidates() {
    local normal_cpu=$1 normal_gpu=$2 normal_voltage=$3 provenance=${4:-missing} evidence=${5:-missing}
    local sweep_domain=${APO_SWEEP_DOMAIN:-all} cpu_min=${APO_CPU_MIN:-} gpu_min=${APO_GPU_MIN:-}
    local cpu_max=${APO_CPU_MAX:-$APO_AUTO_CPU_MAX_MHZ} gpu_max=${APO_GPU_MAX:-$APO_AUTO_GPU_MAX_MHZ}
    local cpu_step gpu_step
    cpu_step=$(apo_domain_coarse_step_mhz CPU) || apo_die 'Could not derive the automatic CPU coarse step.' "$APO_EXIT_INTERNAL"
    gpu_step=$(apo_domain_coarse_step_mhz GPU) || apo_die 'Could not derive the automatic GPU coarse step.' "$APO_EXIT_INTERNAL"
    if (( APO_AUTO_GENERATED_CANDIDATES == 1 )); then
        if [[ $sweep_domain == all ]]; then
            apo_config_require_stock_auto_baseline "$normal_cpu" "$normal_gpu" "$normal_voltage" "$provenance" "$evidence"
        else
            [[ $sweep_domain == cpu || $sweep_domain == gpu ]] ||
                apo_die 'Automatic sweep domain is malformed.' "$APO_EXIT_INTERNAL"
            [[ ${APO_SOURCE_APPLIED_RUN_ID:-} != '' && ${APO_SOURCE_APPLIED_PERMANENT_HASH:-} =~ ^[0-9a-f]{64}$ ]] ||
                apo_die 'Domain-only automatic tuning is missing its retained applied-source binding.' "$APO_EXIT_INTERNAL"
        fi
    fi
    (( APO_AUTO_CANDIDATES_PENDING == 1 )) || return 0
    if [[ $sweep_domain != gpu ]]; then
        apo_validate_uint_range "$cpu_max" "$APO_CPU_CLOCK_MIN_MHZ" "$APO_AUTO_CPU_MAX_MHZ" ||
            apo_die 'The requested automatic CPU maximum is malformed.' "$APO_EXIT_USAGE"
        (( cpu_max > normal_cpu )) ||
            apo_die "--cpu-max must be above the protected current CPU clock (${normal_cpu} MHz)." "$APO_EXIT_USAGE"
        if [[ -n $cpu_min ]]; then
            apo_validate_uint_range "$cpu_min" "$APO_CPU_CLOCK_MIN_MHZ" "$cpu_max" ||
                apo_die 'The requested automatic CPU minimum is malformed or exceeds its maximum.' "$APO_EXIT_USAGE"
            (( cpu_min > normal_cpu )) ||
                apo_die "--cpu-min must be above the protected current CPU clock (${normal_cpu} MHz)." "$APO_EXIT_USAGE"
        fi
        if [[ ${APO_CPU_SEARCH_DIRECTION:-forward} == descending ]]; then
            APO_CFG[CPU_CANDIDATES]=$cpu_max
        elif [[ -n $cpu_min ]]; then
            APO_CFG[CPU_CANDIDATES]=$(apo_config_auto_ladder_from_exact "$cpu_min" "$cpu_step" "$cpu_max" "$APO_CPU_CLOCK_MIN_MHZ") ||
                apo_die 'Could not derive automatic CPU candidates from --cpu-min/--cpu-max.' "$APO_EXIT_INTERNAL"
        else
            APO_CFG[CPU_CANDIDATES]=$(apo_config_auto_ladder "$normal_cpu" "$cpu_step" "$cpu_max" "$APO_CPU_CLOCK_MIN_MHZ") ||
                apo_die 'Could not derive automatic CPU candidates from the discovered baseline.' "$APO_EXIT_INTERNAL"
        fi
    else
        APO_CFG[CPU_CANDIDATES]=''
    fi
    if [[ $sweep_domain != cpu ]]; then
        apo_validate_uint_range "$gpu_max" "$APO_GPU_CLOCK_MIN_MHZ" "$APO_AUTO_GPU_MAX_MHZ" ||
            apo_die 'The requested automatic GPU maximum is malformed.' "$APO_EXIT_USAGE"
        (( gpu_max > normal_gpu )) ||
            apo_die "--gpu-max must be above the protected current GPU/V3D clock (${normal_gpu} MHz)." "$APO_EXIT_USAGE"
        if [[ -n $gpu_min ]]; then
            apo_validate_uint_range "$gpu_min" "$APO_GPU_CLOCK_MIN_MHZ" "$gpu_max" ||
                apo_die 'The requested automatic GPU minimum is malformed or exceeds its maximum.' "$APO_EXIT_USAGE"
            (( gpu_min > normal_gpu )) ||
                apo_die "--gpu-min must be above the protected current GPU/V3D clock (${normal_gpu} MHz)." "$APO_EXIT_USAGE"
        fi
        if [[ ${APO_GPU_SEARCH_DIRECTION:-forward} == descending ]]; then
            APO_CFG[GPU_CANDIDATES]=$gpu_max
        elif [[ -n $gpu_min ]]; then
            APO_CFG[GPU_CANDIDATES]=$(apo_config_auto_ladder_from_exact "$gpu_min" "$gpu_step" "$gpu_max" "$APO_GPU_CLOCK_MIN_MHZ") ||
                apo_die 'Could not derive automatic GPU/V3D candidates from --gpu-min/--gpu-max.' "$APO_EXIT_INTERNAL"
        else
            APO_CFG[GPU_CANDIDATES]=$(apo_config_auto_ladder "$normal_gpu" "$gpu_step" "$gpu_max" "$APO_GPU_CLOCK_MIN_MHZ") ||
                apo_die 'Could not derive automatic GPU/V3D candidates from the discovered baseline.' "$APO_EXIT_INTERNAL"
        fi
    else
        APO_CFG[GPU_CANDIDATES]=''
    fi
    # Automatic refinement and its explicit MHz guard replace list-index backoff.
    APO_CFG[BACKOFF_STEPS]=0
    APO_AUTO_CANDIDATES_PENDING=0
    apo_config_validate
    if [[ ${APO_COMMAND:-prepare} == run && ${APO_DRY_RUN:-0} == 0 && -z ${APO_CFG[CPU_CANDIDATES]} && -z ${APO_CFG[GPU_CANDIDATES]} ]]; then
        case $sweep_domain in
            cpu) apo_die "The protected current CPU clock is already at or above the requested ceiling (${cpu_max} MHz)." "$APO_EXIT_USAGE" ;;
            gpu) apo_die "The protected current GPU/V3D clock is already at or above the requested ceiling (${gpu_max} MHz)." "$APO_EXIT_USAGE" ;;
            *) apo_die "The discovered CPU and GPU clocks are already at or above the requested ceilings (${cpu_max}/${gpu_max} MHz). Supply higher bounds or an explicit --config plan." "$APO_EXIT_USAGE" ;;
        esac
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
    local candidate_duration_max=86400
    if (( ${APO_MANUAL_TEST:-0} == 1 )); then
        candidate_duration_max=$APO_MAX_TUNING_DURATION_S
    fi
    apo_parse_ordered_int_list "${APO_CFG[CPU_CANDIDATES]}" APO_CPU_CANDIDATES "$APO_CPU_CLOCK_MIN_MHZ" "$APO_CPU_CLOCK_MAX_MHZ" cpu_candidates_mhz
    apo_parse_ordered_int_list "${APO_CFG[GPU_CANDIDATES]}" APO_GPU_CANDIDATES "$APO_GPU_CLOCK_MIN_MHZ" "$APO_GPU_CLOCK_MAX_MHZ" gpu_candidates_mhz
    apo_validate_uint_range "${APO_CFG[CANDIDATE_DURATION_S]}" 10 "$candidate_duration_max" ||
        apo_die "candidate_duration_seconds must be 10-${candidate_duration_max}." "$APO_EXIT_USAGE"
    apo_validate_uint_range "${APO_CFG[FINAL_DURATION_S]}" "$APO_MIN_TUNING_DURATION_S" "$APO_MAX_TUNING_DURATION_S" ||
        apo_die "final_duration_seconds must be ${APO_MIN_TUNING_DURATION_S}-${APO_MAX_TUNING_DURATION_S}." "$APO_EXIT_USAGE"
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
    APO_SELECTION_POLICY=adaptive-refined-v1
    if (( ${APO_MANUAL_TEST:-0} == 1 )); then
        APO_CFG[CPU_CANDIDATES]=$APO_MANUAL_CPU
        APO_CFG[GPU_CANDIDATES]=$APO_MANUAL_GPU
        APO_CFG[CANDIDATE_DURATION_S]=$APO_MANUAL_DURATION_S
        APO_CFG[BACKOFF_STEPS]=0
    else
        [[ -z ${APO_CONFIG_FILE:-} ]] || apo_config_read_file "$APO_CONFIG_FILE"
    fi
    if [[ ${APO_PUBLIC_COMMAND:-} == overclock ]]; then
        APO_CFG[FINAL_DURATION_S]=$APO_FINAL_DURATION_S
    fi
    if [[ ${APO_COMMAND:-prepare} == run && -z ${APO_CONFIG_FILE:-} && ${APO_MODE_REQUESTED:-auto} == auto && -z ${APO_CFG[CPU_CANDIDATES]} && -z ${APO_CFG[GPU_CANDIDATES]} ]]; then
        APO_AUTO_CANDIDATES_PENDING=1
        APO_AUTO_GENERATED_CANDIDATES=1
    fi
    if (( ${APO_EDGE_CPU_24H:-0} == 1 )); then
        (( APO_AUTO_GENERATED_CANDIDATES == 1 )) ||
            apo_die 'Retained edge-validation state requires configuration-free automatic candidates.' "$APO_EXIT_USAGE"
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
    APO_FINAL_DURATION_S=${APO_CFG[FINAL_DURATION_S]}
    APO_DURATION_POLICY=$(apo_config_duration_policy "$APO_QUALIFICATION_DURATION_S" "$APO_FINAL_DURATION_S" "$APO_EDGE_DURATION_S")
    apo_config_validate
    apo_config_validate_duration_plan
}

apo_config_store_in_state() {
    local config_key internal_key
    for config_key in "${APO_ALLOWED_CONFIG_KEYS[@]}"; do
        internal_key=$(apo_config_internal_key "$config_key")
        apo_state_set "CFG_${internal_key}" "${APO_CFG[$internal_key]}"
    done
    apo_state_set CFG_AUTO_GENERATED_CANDIDATES "$APO_AUTO_GENERATED_CANDIDATES"
    apo_state_set CFG_SWEEP_DOMAIN "${APO_SWEEP_DOMAIN:-all}"
    apo_state_set CFG_SELECTION_POLICY "${APO_SELECTION_POLICY:-adaptive-refined-v1}"
    apo_state_set CFG_CPU_MIN "${APO_CPU_MIN:-}"
    apo_state_set CFG_GPU_MIN "${APO_GPU_MIN:-}"
    apo_state_set CFG_CPU_MAX "${APO_CPU_MAX:-}"
    apo_state_set CFG_GPU_MAX "${APO_GPU_MAX:-}"
    apo_state_set CFG_CPU_MAX_REQUESTED "${APO_CPU_MAX_REQUESTED:-}"
    apo_state_set CFG_GPU_MAX_REQUESTED "${APO_GPU_MAX_REQUESTED:-}"
    apo_state_set CFG_CPU_RESOLUTION_MHZ "${APO_CPU_RESOLUTION_MHZ:-$APO_AUTO_REFINE_STEP_MHZ}"
    apo_state_set CFG_GPU_RESOLUTION_MHZ "${APO_GPU_RESOLUTION_MHZ:-$APO_AUTO_REFINE_STEP_MHZ}"
    apo_state_set CFG_CPU_SEARCH_DIRECTION "${APO_CPU_SEARCH_DIRECTION:-forward}"
    apo_state_set CFG_GPU_SEARCH_DIRECTION "${APO_GPU_SEARCH_DIRECTION:-forward}"
    apo_state_set CFG_USE_HISTORY "${APO_USE_HISTORY:-1}"
    apo_state_set CFG_EDGE_CPU_24H "${APO_EDGE_CPU_24H:-0}"
    apo_state_set CFG_EDGE_ORDER "${APO_EDGE_ORDER:-floor-first}"
    apo_state_set CFG_QUALIFICATION_DURATION_S "$APO_QUALIFICATION_DURATION_S"
    apo_state_set CFG_EDGE_DURATION_S "$APO_EDGE_DURATION_S"
    apo_state_set CFG_DURATION_POLICY "$APO_DURATION_POLICY"
    apo_state_set CFG_MAX_FAN "${APO_MAX_FAN:-1}"
    apo_state_set CFG_MANUAL_TEST "${APO_MANUAL_TEST:-0}"
    apo_state_set CFG_MANUAL_CPU "${APO_MANUAL_CPU:-}"
    apo_state_set CFG_MANUAL_GPU "${APO_MANUAL_GPU:-}"
    apo_state_set CFG_MANUAL_MINUTES "${APO_MANUAL_MINUTES:-}"
    apo_state_set CFG_MANUAL_DURATION_S "${APO_MANUAL_DURATION_S:-}"
}

apo_config_state_requires_duration_plan() {
    local origin phase
    [[ $(apo_state_get RUN_SCHEMA '') == "$APO_CURRENT_RUN_SCHEMA" ]] || return 1
    origin=$(apo_state_get ORIGIN_COMMAND '')
    phase=$(apo_state_get PHASE '')
    [[ $origin == run || $origin == overclock || $origin == test ]] || return 1
    # A crash during initial PREPARE can precede plan persistence. Keep that
    # checkpoint inspectable and let resume's dedicated PREPARE refusal explain
    # why it cannot continue. Every later tuning checkpoint must carry the
    # immutable plan and still fails closed if any duration field is missing.
    [[ -n $phase && $phase != PREPARE ]]
}

apo_config_restore_from_state() {
    local config_key internal_key
    apo_config_defaults
    for config_key in "${APO_ALLOWED_CONFIG_KEYS[@]}"; do
        internal_key=$(apo_config_internal_key "$config_key")
        APO_CFG[$internal_key]=$(apo_state_get "CFG_${internal_key}" "${APO_CFG[$internal_key]}")
    done
    if apo_config_state_requires_duration_plan; then
        [[ -v APO_STATE[CFG_QUALIFICATION_DURATION_S] && -v APO_STATE[CFG_FINAL_DURATION_S] &&
           -v APO_STATE[CFG_EDGE_DURATION_S] && -v APO_STATE[CFG_DURATION_POLICY] ]] ||
            apo_die 'Current-schema state is missing its immutable duration plan.' "$APO_EXIT_INTERNAL"
    fi
    APO_AUTO_GENERATED_CANDIDATES=$(apo_state_get CFG_AUTO_GENERATED_CANDIDATES 0)
    [[ $APO_AUTO_GENERATED_CANDIDATES == 0 || $APO_AUTO_GENERATED_CANDIDATES == 1 ]] ||
        apo_die 'Saved automatic-candidate marker is malformed.' "$APO_EXIT_INTERNAL"
    APO_SWEEP_DOMAIN=$(apo_state_get CFG_SWEEP_DOMAIN all)
    [[ $APO_SWEEP_DOMAIN == all || $APO_SWEEP_DOMAIN == cpu || $APO_SWEEP_DOMAIN == gpu ]] ||
        apo_die 'Saved sweep-domain plan is malformed.' "$APO_EXIT_INTERNAL"
    APO_SELECTION_POLICY=$(apo_state_get CFG_SELECTION_POLICY guarded-v1)
    [[ $APO_SELECTION_POLICY == guarded-v1 || $APO_SELECTION_POLICY == refined-max-25 || $APO_SELECTION_POLICY == adaptive-refined-v1 ]] ||
        apo_die 'Saved automatic selection policy is malformed.' "$APO_EXIT_INTERNAL"
    if [[ $APO_SELECTION_POLICY == adaptive-refined-v1 && $APO_AUTO_GENERATED_CANDIDATES == 1 ]] &&
       apo_config_state_requires_duration_plan; then
        [[ -v APO_STATE[CFG_CPU_RESOLUTION_MHZ] && -v APO_STATE[CFG_GPU_RESOLUTION_MHZ] &&
           -v APO_STATE[CFG_CPU_SEARCH_DIRECTION] && -v APO_STATE[CFG_GPU_SEARCH_DIRECTION] ]] ||
            apo_die 'Saved adaptive search state is missing its immutable per-domain resolution or direction.' "$APO_EXIT_INTERNAL"
    fi
    APO_CPU_MIN=$(apo_state_get CFG_CPU_MIN "$(apo_state_get CFG_CPU_START_AT '')")
    APO_GPU_MIN=$(apo_state_get CFG_GPU_MIN "$(apo_state_get CFG_GPU_START_AT '')")
    APO_CPU_MAX=$(apo_state_get CFG_CPU_MAX '')
    APO_GPU_MAX=$(apo_state_get CFG_GPU_MAX '')
    APO_CPU_MAX_REQUESTED=$(apo_state_get CFG_CPU_MAX_REQUESTED "$APO_CPU_MAX")
    APO_GPU_MAX_REQUESTED=$(apo_state_get CFG_GPU_MAX_REQUESTED "$APO_GPU_MAX")
    APO_CPU_RESOLUTION_MHZ=$(apo_state_get CFG_CPU_RESOLUTION_MHZ "$APO_AUTO_REFINE_STEP_MHZ")
    APO_GPU_RESOLUTION_MHZ=$(apo_state_get CFG_GPU_RESOLUTION_MHZ "$APO_AUTO_REFINE_STEP_MHZ")
    APO_CPU_SEARCH_DIRECTION=$(apo_state_get CFG_CPU_SEARCH_DIRECTION forward)
    APO_GPU_SEARCH_DIRECTION=$(apo_state_get CFG_GPU_SEARCH_DIRECTION forward)
    APO_USE_HISTORY=$(apo_state_get CFG_USE_HISTORY 0)
    [[ -z $APO_CPU_MIN ]] || apo_validate_uint_range "$APO_CPU_MIN" "$APO_CPU_CLOCK_MIN_MHZ" "$APO_AUTO_CPU_MAX_MHZ" ||
        apo_die 'Saved CPU minimum is malformed.' "$APO_EXIT_INTERNAL"
    [[ -z $APO_CPU_MAX ]] || apo_validate_uint_range "$APO_CPU_MAX" "$APO_CPU_CLOCK_MIN_MHZ" "$APO_AUTO_CPU_MAX_MHZ" ||
        apo_die 'Saved CPU maximum is malformed.' "$APO_EXIT_INTERNAL"
    [[ -z $APO_GPU_MIN ]] || apo_validate_uint_range "$APO_GPU_MIN" "$APO_GPU_CLOCK_MIN_MHZ" "$APO_AUTO_GPU_MAX_MHZ" ||
        apo_die 'Saved GPU minimum is malformed.' "$APO_EXIT_INTERNAL"
    [[ -z $APO_GPU_MAX ]] || apo_validate_uint_range "$APO_GPU_MAX" "$APO_GPU_CLOCK_MIN_MHZ" "$APO_AUTO_GPU_MAX_MHZ" ||
        apo_die 'Saved GPU maximum is malformed.' "$APO_EXIT_INTERNAL"
    [[ -z $APO_CPU_MAX_REQUESTED ]] || apo_validate_uint_range "$APO_CPU_MAX_REQUESTED" "$APO_CPU_CLOCK_MIN_MHZ" "$APO_AUTO_CPU_MAX_MHZ" ||
        apo_die 'Saved requested CPU maximum is malformed.' "$APO_EXIT_INTERNAL"
    [[ -z $APO_GPU_MAX_REQUESTED ]] || apo_validate_uint_range "$APO_GPU_MAX_REQUESTED" "$APO_GPU_CLOCK_MIN_MHZ" "$APO_AUTO_GPU_MAX_MHZ" ||
        apo_die 'Saved requested GPU maximum is malformed.' "$APO_EXIT_INTERNAL"
    apo_validate_uint_range "$APO_CPU_RESOLUTION_MHZ" 1 1000 ||
        apo_die 'Saved CPU resolution is malformed.' "$APO_EXIT_INTERNAL"
    apo_validate_uint_range "$APO_GPU_RESOLUTION_MHZ" 1 1000 ||
        apo_die 'Saved GPU resolution is malformed.' "$APO_EXIT_INTERNAL"
    [[ $APO_CPU_SEARCH_DIRECTION == forward || $APO_CPU_SEARCH_DIRECTION == descending ]] ||
        apo_die 'Saved CPU search direction is malformed.' "$APO_EXIT_INTERNAL"
    [[ $APO_GPU_SEARCH_DIRECTION == forward || $APO_GPU_SEARCH_DIRECTION == descending ]] ||
        apo_die 'Saved GPU search direction is malformed.' "$APO_EXIT_INTERNAL"
    [[ -z $APO_CPU_MIN || -z $APO_CPU_MAX ]] || (( 10#$APO_CPU_MIN <= 10#$APO_CPU_MAX )) ||
        apo_die 'Saved CPU minimum exceeds its maximum.' "$APO_EXIT_INTERNAL"
    [[ -z $APO_GPU_MIN || -z $APO_GPU_MAX ]] || (( 10#$APO_GPU_MIN <= 10#$APO_GPU_MAX )) ||
        apo_die 'Saved GPU minimum exceeds its maximum.' "$APO_EXIT_INTERNAL"
    [[ -z $APO_CPU_MAX_REQUESTED || -z $APO_CPU_MAX ]] || (( 10#$APO_CPU_MAX <= 10#$APO_CPU_MAX_REQUESTED )) ||
        apo_die 'Saved effective CPU maximum exceeds the user-requested maximum.' "$APO_EXIT_INTERNAL"
    [[ -z $APO_GPU_MAX_REQUESTED || -z $APO_GPU_MAX ]] || (( 10#$APO_GPU_MAX <= 10#$APO_GPU_MAX_REQUESTED )) ||
        apo_die 'Saved effective GPU maximum exceeds the user-requested maximum.' "$APO_EXIT_INTERNAL"
    [[ $APO_USE_HISTORY == 0 || $APO_USE_HISTORY == 1 ]] ||
        apo_die 'Saved history policy is malformed.' "$APO_EXIT_INTERNAL"
    [[ $APO_SWEEP_DOMAIN != cpu || ( -z $APO_GPU_MIN && -z $APO_GPU_MAX ) ]] ||
        apo_die 'Saved CPU-only plan contains GPU bounds.' "$APO_EXIT_INTERNAL"
    [[ $APO_SWEEP_DOMAIN != gpu || ( -z $APO_CPU_MIN && -z $APO_CPU_MAX ) ]] ||
        apo_die 'Saved GPU-only plan contains CPU bounds.' "$APO_EXIT_INTERNAL"
    APO_SOURCE_APPLIED_RUN_ID=$(apo_state_get SOURCE_APPLIED_RUN_ID '')
    APO_SOURCE_APPLIED_PERMANENT_HASH=$(apo_state_get SOURCE_APPLIED_PERMANENT_HASH '')
    APO_SOURCE_APPLIED_LIVE_HASH=$(apo_state_get SOURCE_APPLIED_LIVE_HASH '')
    APO_SOURCE_APPLIED_HASH_RELATION=$(apo_state_get SOURCE_APPLIED_HASH_RELATION '')
    APO_SOURCE_APPLIED_HASH_EVIDENCE=$(apo_state_get SOURCE_APPLIED_HASH_EVIDENCE '')
    APO_SOURCE_APPLIED_CPU=$(apo_state_get SOURCE_APPLIED_CPU '')
    APO_SOURCE_APPLIED_GPU=$(apo_state_get SOURCE_APPLIED_GPU '')
    APO_SOURCE_APPLIED_VOLTAGE=$(apo_state_get SOURCE_APPLIED_VOLTAGE '')
    APO_SOURCE_APPLIED_PROFILE=$(apo_state_get SOURCE_APPLIED_PROFILE '')
    APO_SOURCE_APPLIED_BOOT_CONFIG=$(apo_state_get SOURCE_APPLIED_BOOT_CONFIG '')
    APO_SOURCE_APPLIED_TRYBOOT_CONFIG=$(apo_state_get SOURCE_APPLIED_TRYBOOT_CONFIG '')
    APO_SOURCE_APPLIED_GPU_KEY=$(apo_state_get SOURCE_APPLIED_GPU_KEY '')
    APO_SOURCE_AUTO_BASELINE_CPU=$(apo_state_get SOURCE_AUTO_BASELINE_CPU '')
    APO_SOURCE_AUTO_BASELINE_GPU=$(apo_state_get SOURCE_AUTO_BASELINE_GPU '')
    APO_SOURCE_AUTO_BASELINE_VOLTAGE=$(apo_state_get SOURCE_AUTO_BASELINE_VOLTAGE '')
    APO_SOURCE_AUTO_BASELINE_PROVENANCE=$(apo_state_get SOURCE_AUTO_BASELINE_PROVENANCE '')
    APO_SOURCE_AUTO_BASELINE_EVIDENCE=$(apo_state_get SOURCE_AUTO_BASELINE_EVIDENCE '')
    if [[ $APO_SWEEP_DOMAIN != all ]]; then
        apo_is_safe_run_id "$APO_SOURCE_APPLIED_RUN_ID" || apo_die 'Saved domain-only plan has an invalid applied source run ID.' "$APO_EXIT_INTERNAL"
        [[ $APO_SOURCE_APPLIED_PERMANENT_HASH =~ ^[0-9a-f]{64}$ ]] ||
            apo_die 'Saved domain-only plan has an invalid applied source hash.' "$APO_EXIT_INTERNAL"
        apo_validate_uint_range "$APO_SOURCE_APPLIED_CPU" "$APO_CPU_CLOCK_MIN_MHZ" "$APO_CPU_CLOCK_MAX_MHZ" ||
            apo_die 'Saved domain-only plan has an invalid applied CPU clock.' "$APO_EXIT_INTERNAL"
        apo_validate_uint_range "$APO_SOURCE_APPLIED_GPU" "$APO_GPU_CLOCK_MIN_MHZ" "$APO_GPU_CLOCK_MAX_MHZ" ||
            apo_die 'Saved domain-only plan has an invalid applied GPU clock.' "$APO_EXIT_INTERNAL"
        apo_is_int "$APO_SOURCE_APPLIED_VOLTAGE" ||
            apo_die 'Saved domain-only plan has an invalid applied voltage delta.' "$APO_EXIT_INTERNAL"
        [[ $APO_SOURCE_APPLIED_PROFILE == debian || $APO_SOURCE_APPLIED_PROFILE == batocera ]] ||
            apo_die 'Saved domain-only plan has an invalid applied source profile.' "$APO_EXIT_INTERNAL"
        [[ $APO_SOURCE_APPLIED_BOOT_CONFIG == /* && $APO_SOURCE_APPLIED_TRYBOOT_CONFIG == /* ]] ||
            apo_die 'Saved domain-only plan has invalid applied source boot paths.' "$APO_EXIT_INTERNAL"
        [[ $APO_SOURCE_APPLIED_GPU_KEY == gpu_freq || $APO_SOURCE_APPLIED_GPU_KEY == v3d_freq ]] ||
            apo_die 'Saved domain-only plan has an invalid applied source GPU key.' "$APO_EXIT_INTERNAL"
        apo_config_stock_auto_baseline_ready "$APO_SOURCE_AUTO_BASELINE_CPU" "$APO_SOURCE_AUTO_BASELINE_GPU" \
            "$APO_SOURCE_AUTO_BASELINE_VOLTAGE" "$APO_SOURCE_AUTO_BASELINE_PROVENANCE" \
            "$APO_SOURCE_AUTO_BASELINE_EVIDENCE" ||
            apo_die 'Saved domain-only plan has invalid stock-baseline lineage.' "$APO_EXIT_INTERNAL"
        if [[ $(apo_state_get PHASE '') != PREPARE ]]; then
            [[ $APO_SOURCE_APPLIED_LIVE_HASH =~ ^[0-9a-f]{64}$ ]] ||
                apo_die 'Saved domain-only plan has an invalid adopted live-config hash.' "$APO_EXIT_INTERNAL"
            case $APO_SOURCE_APPLIED_HASH_RELATION in
                exact)
                    [[ $APO_SOURCE_APPLIED_HASH_EVIDENCE == live-hash-equals-retained-applied-hash &&
                       $APO_SOURCE_APPLIED_LIVE_HASH == "$APO_SOURCE_APPLIED_PERMANENT_HASH" ]] ||
                        apo_die 'Saved exact applied-source hash relation is inconsistent.' "$APO_EXIT_INTERNAL"
                    ;;
                comment-only)
                    [[ $APO_SOURCE_APPLIED_HASH_EVIDENCE == source-artifact-hash-and-managed-block-verified-active-lines-identical &&
                       $APO_SOURCE_APPLIED_LIVE_HASH != "$APO_SOURCE_APPLIED_PERMANENT_HASH" ]] ||
                        apo_die 'Saved comment-only applied-source hash relation is inconsistent.' "$APO_EXIT_INTERNAL"
                    ;;
                comment-only-project-zero-removed)
                    [[ $APO_SOURCE_APPLIED_HASH_EVIDENCE == source-artifact-hash-and-managed-block-verified-active-lines-identical-after-project-zero-removal &&
                       $APO_SOURCE_APPLIED_LIVE_HASH != "$APO_SOURCE_APPLIED_PERMANENT_HASH" &&
                       $APO_SOURCE_APPLIED_VOLTAGE == 0 ]] ||
                        apo_die 'Saved project-zero-removal source relation is inconsistent.' "$APO_EXIT_INTERNAL"
                    ;;
                *) apo_die 'Saved domain-only plan has a malformed applied-source hash relation.' "$APO_EXIT_INTERNAL" ;;
            esac
            if [[ $(apo_state_get APPLY_STATUS NOT_APPLIED) != APPLIED ]]; then
                [[ $APO_SOURCE_APPLIED_LIVE_HASH == "$(apo_state_get PERMANENT_HASH '')" ]] ||
                    apo_die 'Saved domain-only plan is no longer bound to its adopted live permanent-config hash.' "$APO_EXIT_INTERNAL"
            fi
        fi
    fi
    APO_EDGE_CPU_24H=$(apo_state_get CFG_EDGE_CPU_24H 0)
    [[ $APO_EDGE_CPU_24H == 0 || $APO_EDGE_CPU_24H == 1 ]] ||
        apo_die 'Saved edge-CPU marker is malformed.' "$APO_EXIT_INTERNAL"
    APO_EDGE_ORDER=$(apo_state_get CFG_EDGE_ORDER floor-first)
    [[ $APO_EDGE_ORDER == floor-first || $APO_EDGE_ORDER == edge-first ]] ||
        apo_die 'Saved edge-order policy is malformed.' "$APO_EXIT_INTERNAL"
    APO_QUALIFICATION_DURATION_S=$(apo_state_get CFG_QUALIFICATION_DURATION_S "$APO_DEFAULT_QUALIFICATION_DURATION_S")
    APO_EDGE_DURATION_S=$(apo_state_get CFG_EDGE_DURATION_S "$APO_DEFAULT_EDGE_DURATION_S")
    APO_FINAL_DURATION_S=${APO_CFG[FINAL_DURATION_S]}
    APO_DURATION_POLICY=$(apo_state_get CFG_DURATION_POLICY "$(apo_config_duration_policy "$APO_QUALIFICATION_DURATION_S" "$APO_FINAL_DURATION_S" "$APO_EDGE_DURATION_S")")
    APO_MAX_FAN=$(apo_state_get CFG_MAX_FAN 1)
    [[ $APO_MAX_FAN == 0 || $APO_MAX_FAN == 1 ]] ||
        apo_die 'Saved maximum-fan policy is malformed.' "$APO_EXIT_INTERNAL"
    APO_MANUAL_TEST=$(apo_state_get CFG_MANUAL_TEST "$(apo_state_get MANUAL_TEST 0)")
    [[ $APO_MANUAL_TEST == 0 || $APO_MANUAL_TEST == 1 ]] ||
        apo_die 'Saved manual-test marker is malformed.' "$APO_EXIT_INTERNAL"
    APO_MANUAL_CPU=$(apo_state_get CFG_MANUAL_CPU "$(apo_state_get MANUAL_CPU '')")
    APO_MANUAL_GPU=$(apo_state_get CFG_MANUAL_GPU "$(apo_state_get MANUAL_GPU '')")
    APO_MANUAL_MINUTES=$(apo_state_get CFG_MANUAL_MINUTES "$(apo_state_get MANUAL_MINUTES '')")
    APO_MANUAL_DURATION_S=$(apo_state_get CFG_MANUAL_DURATION_S "$(apo_state_get MANUAL_DURATION_S '')")
    if (( APO_MANUAL_TEST == 1 )); then
        apo_validate_uint_range "$APO_MANUAL_CPU" "$APO_CPU_CLOCK_MIN_MHZ" "$APO_CPU_CLOCK_MAX_MHZ" ||
            apo_die 'Saved manual CPU clock is malformed.' "$APO_EXIT_INTERNAL"
        apo_validate_uint_range "$APO_MANUAL_GPU" "$APO_GPU_CLOCK_MIN_MHZ" "$APO_GPU_CLOCK_MAX_MHZ" ||
            apo_die 'Saved manual GPU clock is malformed.' "$APO_EXIT_INTERNAL"
        apo_validate_uint_range "$APO_MANUAL_MINUTES" 1 "$((APO_MAX_TUNING_DURATION_S / 60))" ||
            apo_die 'Saved manual duration is malformed.' "$APO_EXIT_INTERNAL"
        apo_validate_uint_range "$APO_MANUAL_DURATION_S" 60 "$APO_MAX_TUNING_DURATION_S" ||
            apo_die 'Saved manual duration seconds are malformed.' "$APO_EXIT_INTERNAL"
        [[ $APO_MANUAL_DURATION_S == $((APO_MANUAL_MINUTES * 60)) ]] ||
            apo_die 'Saved manual duration fields disagree.' "$APO_EXIT_INTERNAL"
    fi
    apo_config_validate
    apo_config_validate_duration_plan
}

apo_write_effective_config() {
    local destination=$1 config_key internal_key
    {
        printf '# AutoPiOverclock effective configuration for run %s\n' "${APO_RUN_ID:-unknown}"
        printf '# candidate_max_fan=%s (controller policy; use --no-max-fan to opt out on a new run)\n' \
            "$([[ ${APO_MAX_FAN:-1} == 1 ]] && printf enabled || printf disabled)"
        if (( ${APO_AUTO_GENERATED_CANDIDATES:-0} == 1 )); then
            printf '# automatic_sweep_domain=%s\n' "${APO_SWEEP_DOMAIN:-all}"
            printf '# automatic_selection_policy=%s\n' "${APO_SELECTION_POLICY:-adaptive-refined-v1}"
            printf '# automatic_cpu_min_mhz=%s\n' "${APO_CPU_MIN:-auto}"
            printf '# automatic_cpu_requested_max_mhz=%s\n' "${APO_CPU_MAX_REQUESTED:-auto}"
            printf '# automatic_cpu_max_mhz=%s\n' "${APO_CPU_MAX:-$APO_AUTO_CPU_MAX_MHZ}"
            printf '# automatic_gpu_min_mhz=%s\n' "${APO_GPU_MIN:-auto}"
            printf '# automatic_gpu_requested_max_mhz=%s\n' "${APO_GPU_MAX_REQUESTED:-auto}"
            printf '# automatic_gpu_max_mhz=%s\n' "${APO_GPU_MAX:-$APO_AUTO_GPU_MAX_MHZ}"
            printf '# automatic_cpu_resolution_mhz=%s\n' "${APO_CPU_RESOLUTION_MHZ:-$APO_AUTO_REFINE_STEP_MHZ}"
            printf '# automatic_gpu_resolution_mhz=%s\n' "${APO_GPU_RESOLUTION_MHZ:-$APO_AUTO_REFINE_STEP_MHZ}"
            printf '# automatic_cpu_search_direction=%s\n' "${APO_CPU_SEARCH_DIRECTION:-forward}"
            printf '# automatic_gpu_search_direction=%s\n' "${APO_GPU_SEARCH_DIRECTION:-forward}"
            printf '# automatic_use_history=%s\n' "${APO_USE_HISTORY:-1}"
            printf '# automatic_domain_qualification_seconds=%s\n' "$APO_QUALIFICATION_DURATION_S"
            if (( ${APO_EDGE_CPU_24H:-0} == 1 )); then
                printf '# legacy_automatic_edge_seconds=%s\n' "$APO_EDGE_DURATION_S"
            fi
            printf '# automatic_duration_policy=%s\n' "$APO_DURATION_POLICY"
            printf '# automatic_final_workload=combined CPU/GPU/I/O\n'
        fi
        if (( ${APO_MANUAL_TEST:-0} == 1 )); then
            printf '# manual_stability_test=CPU:%sMHz GPU:%sMHz duration:%ss; never eligible for permanent apply\n' \
                "$APO_MANUAL_CPU" "$APO_MANUAL_GPU" "$APO_MANUAL_DURATION_S"
        fi
        for config_key in "${APO_ALLOWED_CONFIG_KEYS[@]}"; do
            internal_key=$(apo_config_internal_key "$config_key")
            printf '%s=%s\n' "$config_key" "${APO_CFG[$internal_key]}"
        done
    } | apo_atomic_write "$destination"
}
