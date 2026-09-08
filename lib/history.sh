#!/usr/bin/env bash
# Retained-run failure evidence for bounded automatic tuning.
#
# State files are the only authority.  The failures ledger is derived output
# for a person to inspect; it is never read to make a tuning decision.

declare -ag APO_HISTORY_RECORDS=()
declare -ag APO_HISTORY_RAW_PAIRS=()
declare -ag APO_HISTORY_LEDGER_RECORDS=()
declare -Ag APO_HISTORY_SEEN_RECORDS=()
declare -Ag APO_HISTORY_SEEN_PAIRS=()
declare -Ag APO_HISTORY_SEEN_LEDGER_RECORDS=()

APO_HISTORY_CPU_FAILURE_BOUNDARY=''
APO_HISTORY_GPU_FAILURE_BOUNDARY=''
APO_HISTORY_PAIR_FRONTIERS=''
APO_HISTORY_PROVENANCE=''
APO_HISTORY_LEDGER_FILE=''
APO_HISTORY_SCANNED_STATES=0
APO_HISTORY_ACCEPTED_STATES=0
APO_HISTORY_EVIDENCE_COUNT=0
APO_HISTORY_SCAN_ERROR=''
APO_HISTORY_PLAN_ANNOUNCED=0
APO_HISTORY_CPU_APPROACH_START=''
APO_HISTORY_GPU_APPROACH_START=''
APO_HISTORY_CPU_REVERSE_SEARCH=0
APO_HISTORY_GPU_REVERSE_SEARCH=0
APO_HISTORY_CPU_RETAINED_CAP=''
APO_HISTORY_GPU_RETAINED_CAP=''
APO_HISTORY_CPU_EXPLICIT_MAX_OVERRIDE=0
APO_HISTORY_GPU_EXPLICIT_MAX_OVERRIDE=0
APO_HISTORY_PLAN_WARNING=''

apo_history_reset() {
    APO_HISTORY_CPU_FAILURE_BOUNDARY=''
    APO_HISTORY_GPU_FAILURE_BOUNDARY=''
    APO_HISTORY_PAIR_FRONTIERS=''
    APO_HISTORY_PROVENANCE=''
    APO_HISTORY_LEDGER_FILE=''
    APO_HISTORY_SCANNED_STATES=0
    APO_HISTORY_ACCEPTED_STATES=0
    APO_HISTORY_EVIDENCE_COUNT=0
    APO_HISTORY_SCAN_ERROR=''
    APO_HISTORY_CPU_APPROACH_START=''
    APO_HISTORY_GPU_APPROACH_START=''
    APO_HISTORY_CPU_REVERSE_SEARCH=0
    APO_HISTORY_GPU_REVERSE_SEARCH=0
    APO_HISTORY_CPU_RETAINED_CAP=''
    APO_HISTORY_GPU_RETAINED_CAP=''
    APO_HISTORY_CPU_EXPLICIT_MAX_OVERRIDE=0
    APO_HISTORY_GPU_EXPLICIT_MAX_OVERRIDE=0
    APO_HISTORY_PLAN_WARNING=''
    APO_HISTORY_RECORDS=()
    APO_HISTORY_RAW_PAIRS=()
    APO_HISTORY_LEDGER_RECORDS=()
    APO_HISTORY_SEEN_RECORDS=()
    APO_HISTORY_SEEN_PAIRS=()
    APO_HISTORY_SEEN_LEDGER_RECORDS=()
}

# Strict data-only loader.  In addition to never sourcing state, this rejects
# duplicate keys, extra columns, and non-canonical base64 encodings.  Those
# checks are intentionally stronger than the ordinary partial metadata loader:
# retained state is about to constrain a new run.
apo_history_load_state_strict() {
    local source_file=$1 output_name=$2 line state_key encoded_value decoded_value canonical
    local -n output_state=$output_name
    local -A seen_keys=()

    [[ -f $source_file && ! -L $source_file && -r $source_file ]] || return 1
    output_state=()
    apo_state_decode_policy_init
    while IFS= read -r line || [[ -n $line ]]; do
        [[ -n $line ]] || continue
        [[ $line == *$'\t'* ]] || return 1
        state_key=${line%%$'\t'*}
        encoded_value=${line#*$'\t'}
        [[ $encoded_value != *$'\t'* ]] || return 1
        apo_state_valid_key "$state_key" || return 1
        [[ ! -v seen_keys[$state_key] ]] || return 1
        [[ $encoded_value =~ ^([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$ ]] || return 1
        decoded_value=$(apo_state_decode "$encoded_value") || return 1
        canonical=$(apo_state_encode "$decoded_value") || return 1
        [[ $canonical == "$encoded_value" ]] || return 1
        seen_keys[$state_key]=1
        # The nameref resolves to an associative array, not an indexed array.
        # shellcheck disable=SC2004
        output_state[$state_key]=$decoded_value
    done < "$source_file"
    (( ${#output_state[@]} > 0 ))
}

# Canonically decode only explicitly requested fields.  This is a screening
# loader, not an authority for evidence: a state that survives the metadata and
# committed-evidence screens is still loaded in full by
# apo_history_load_state_strict().  Ignoring unrequested payload here lets a
# provably unrelated audit remain irrelevant even when one of its unrelated
# fields is damaged, while duplicate or malformed screening fields still fail
# closed.
apo_history_load_screen_fields() {
    local source_file=$1 output_name=$2 line state_key encoded_value decoded_value canonical requested_key
    # The caller supplies an associative array name.
    # shellcheck disable=SC2178
    local -n output_state=$output_name
    local -A requested_keys=() seen_keys=()
    shift 2

    [[ -f $source_file && ! -L $source_file && -r $source_file ]] || return 1
    output_state=()
    for requested_key in "$@"; do
        apo_state_valid_key "$requested_key" || return 1
        requested_keys[$requested_key]=1
    done
    apo_state_decode_policy_init
    while IFS= read -r line || [[ -n $line ]]; do
        [[ -n $line ]] || continue
        if [[ $line != *$'\t'* ]]; then
            apo_state_valid_key "$line" || continue
            [[ ! -v requested_keys[$line] ]] || return 1
            continue
        fi
        state_key=${line%%$'\t'*}
        apo_state_valid_key "$state_key" || continue
        [[ -v requested_keys[$state_key] ]] || continue
        encoded_value=${line#*$'\t'}
        [[ $encoded_value != *$'\t'* ]] || return 1
        [[ ! -v seen_keys[$state_key] ]] || return 1
        [[ $encoded_value =~ ^([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$ ]] || return 1
        decoded_value=$(apo_state_decode "$encoded_value") || return 1
        canonical=$(apo_state_encode "$decoded_value") || return 1
        [[ $canonical == "$encoded_value" ]] || return 1
        seen_keys[$state_key]=1
        # The nameref resolves to an associative array, not an indexed array.
        # shellcheck disable=SC2004
        output_state[$state_key]=$decoded_value
    done < "$source_file"
}

apo_history_state_value() {
    local map_name=$1 state_key=$2 fallback=${3-}
    local -n state_map=$map_name
    if [[ -v state_map[$state_key] ]]; then
        printf '%s' "${state_map[$state_key]}"
    else
        printf '%s' "$fallback"
    fi
}

# This hook deliberately validates in the caller's subshell.  Tests may replace
# it with a fixture validator; production requires the complete automatic-resume
# validator and refuses to consume evidence when that validator is unavailable.
apo_history_validate_loaded_state() {
    declare -F apo_restore_context_from_state >/dev/null 2>&1 || return 1
    declare -F apo_validate_auto_resume_state >/dev/null 2>&1 || return 1
    APO_STATE_VALIDATION_READ_ONLY=1
    APO_COMMAND=resume
    APO_PUBLIC_COMMAND=overclock
    apo_restore_context_from_state >/dev/null 2>&1 || return 1
    apo_validate_auto_resume_state >/dev/null 2>&1
}

apo_history_expected_discovery_value() {
    local state_key=$1
    if declare -p APO_DISCOVERY >/dev/null 2>&1; then
        case $state_key in
            DISC_MODEL) printf '%s' "${APO_DISCOVERY[MODEL]:-}" ;;
            DISC_COMPATIBLE) printf '%s' "${APO_DISCOVERY[COMPATIBLE]:-}" ;;
            DISC_ARCH) printf '%s' "${APO_DISCOVERY[ARCH]:-}" ;;
        esac
    fi
}

apo_history_encode_field() {
    apo_state_encode "$1"
}

apo_history_decode_field() {
    local encoded=$1 decoded canonical
    [[ $encoded =~ ^([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$ ]] || return 1
    decoded=$(apo_state_decode "$encoded") || return 1
    canonical=$(apo_state_encode "$decoded") || return 1
    [[ $canonical == "$encoded" ]] || return 1
    printf '%s' "$decoded"
}

apo_history_validate_failure_class() {
    case $1 in
        PREFLIGHT_FAILURE|HARNESS_FAILURE|BOOT_FAILURE|STABILITY_FAILURE|RECOVERY_FAILURE|APPLY_FAILURE) return 0 ;;
        *) return 1 ;;
    esac
}

apo_history_validate_failure_domain() {
    case $1 in CPU|GPU|PAIR|NONE) return 0 ;; *) return 1 ;; esac
}

apo_history_emit_ledger() {
    local timestamp=$1 run_id=$2 cpu=$3 gpu=$4 class=$5 domain=$6 source=$7 reason=$8 basename=$9
    local encoded_source encoded_reason
    encoded_source=$(apo_history_encode_field "$source") || return 1
    encoded_reason=$(apo_history_encode_field "$reason") || return 1
    printf 'LEDGER|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "$timestamp" "$run_id" "$cpu" "$gpu" "$class" "$domain" \
        "$encoded_source" "$encoded_reason" "$basename"
}

apo_history_emit_legacy_ledger() {
    local run_id=$1 basename=$2 cpu=$3 gpu=$4 domain=$5 source=$6
    local timestamp reason
    timestamp=$(apo_state_get UPDATED_AT "$(apo_state_get CREATED_AT unknown)")
    reason="Retained clock-boundary evidence recorded by $source."
    apo_history_emit_ledger "$timestamp" "$run_id" "$cpu" "$gpu" STABILITY_FAILURE "$domain" "$source" "$reason" "$basename"
}

apo_history_loaded_state_is_compatible() {
    local expected_profile=$1 expected_gpu_key=$2 expected_test_voltage=$3
    local expected_baseline_cpu=$4 expected_baseline_gpu=$5 expected_baseline_voltage=$6
    local expected_model=$7 expected_compatible=$8 expected_arch=$9
    local actual expected state_key

    for state_key in PROFILE GPU_KEY TEST_VOLTAGE AUTO_BASELINE_CPU AUTO_BASELINE_GPU AUTO_BASELINE_VOLTAGE \
        DISC_MODEL DISC_COMPATIBLE DISC_ARCH; do
        case $state_key in
            PROFILE) expected=$expected_profile ;;
            GPU_KEY) expected=$expected_gpu_key ;;
            TEST_VOLTAGE) expected=$expected_test_voltage ;;
            AUTO_BASELINE_CPU) expected=$expected_baseline_cpu ;;
            AUTO_BASELINE_GPU) expected=$expected_baseline_gpu ;;
            AUTO_BASELINE_VOLTAGE) expected=$expected_baseline_voltage ;;
            DISC_MODEL) expected=$expected_model ;;
            DISC_COMPATIBLE) expected=$expected_compatible ;;
            DISC_ARCH) expected=$expected_arch ;;
        esac
        [[ -n $expected ]] || continue
        actual=$(apo_state_get "$state_key" '')
        [[ $actual == "$expected" ]] || return 1
    done
}

apo_history_emit_cpu() {
    local value=$1 run_id=$2 source=$3 basename=$4
    apo_is_uint "$value" && (( value >= 100 && value <= 10000 )) || return 1
    printf 'CPU|%s|%s|%s|%s\n' "$value" "$run_id" "$source" "$basename"
}

apo_history_emit_gpu() {
    local value=$1 run_id=$2 source=$3 basename=$4
    apo_is_uint "$value" && (( value >= 100 && value <= 10000 )) || return 1
    printf 'GPU|%s|%s|%s|%s\n' "$value" "$run_id" "$source" "$basename"
}

apo_history_emit_pair() {
    local cpu=$1 gpu=$2 run_id=$3 source=$4 basename=$5
    apo_is_uint "$cpu" && apo_is_uint "$gpu" &&
        (( cpu >= 100 && cpu <= 10000 && gpu >= 100 && gpu <= 10000 )) || return 1
    printf 'PAIR|%s/%s|%s|%s|%s\n' "$cpu" "$gpu" "$run_id" "$source" "$basename"
}

apo_history_emit_cpu_fact() {
    local value=$1 run_id=$2 source=$3 basename=$4
    apo_history_emit_cpu "$value" "$run_id" "$source" "$basename" || return 1
    apo_history_emit_legacy_ledger "$run_id" "$basename" "$value" - CPU "$source"
}

apo_history_emit_gpu_fact() {
    local value=$1 run_id=$2 source=$3 basename=$4
    apo_history_emit_gpu "$value" "$run_id" "$source" "$basename" || return 1
    apo_history_emit_legacy_ledger "$run_id" "$basename" - "$value" GPU "$source"
}

apo_history_emit_pair_fact() {
    local cpu=$1 gpu=$2 run_id=$3 source=$4 basename=$5
    apo_history_emit_pair "$cpu" "$gpu" "$run_id" "$source" "$basename" || return 1
    apo_history_emit_legacy_ledger "$run_id" "$basename" "$cpu" "$gpu" PAIR "$source"
}

# Durable per-failure audit records use a versioned, newline-separated grammar:
# v1|timestamp|run|cpu-or--|gpu-or--|class|domain|b64(source)|b64(reason)
# The complete state file is base64 data already; the inner encoding keeps a
# free-form reason from changing record boundaries.
apo_history_record_failure_event() {
    local domain=$1 cpu=$2 gpu=$3 class=$4 reason=$5 source=$6
    local timestamp run_id encoded_source encoded_reason history record

    apo_history_validate_failure_domain "$domain" || return 1
    apo_history_validate_failure_class "$class" || return 1
    case $domain in
        CPU) apo_is_uint "$cpu" || return 1; [[ -z $gpu || $gpu == - ]] && gpu=- ;;
        GPU) apo_is_uint "$gpu" || return 1; [[ -z $cpu || $cpu == - ]] && cpu=- ;;
        PAIR) apo_is_uint "$cpu" && apo_is_uint "$gpu" || return 1 ;;
        NONE)
            [[ -z $cpu || $cpu == - ]] && cpu=-
            [[ -z $gpu || $gpu == - ]] && gpu=-
            ;;
    esac
    [[ $cpu == - ]] || { apo_is_uint "$cpu" && (( cpu >= 100 && cpu <= 10000 )); } || return 1
    [[ $gpu == - ]] || { apo_is_uint "$gpu" && (( gpu >= 100 && gpu <= 10000 )); } || return 1
    [[ -n $reason && -n $source && $source != *$'\n'* && $source != *$'\r'* ]] || return 1
    run_id=$(apo_state_get RUN_ID "${APO_RUN_ID:-}")
    apo_is_safe_run_id "$run_id" || return 1
    timestamp=$(apo_now_iso) || return 1
    encoded_source=$(apo_history_encode_field "$source") || return 1
    encoded_reason=$(apo_history_encode_field "$reason") || return 1
    record="v1|$timestamp|$run_id|$cpu|$gpu|$class|$domain|$encoded_source|$encoded_reason"
    history=$(apo_state_get HISTORY_FAILURE_EVENTS '')
    [[ -z $history ]] || history+=$'\n'
    history+=$record
    apo_state_set HISTORY_FAILURE_EVENTS "$history"
}

apo_history_emit_failure_events() {
    local expected_run=$1 basename=$2 history line version timestamp run_id cpu gpu class domain
    local encoded_source encoded_reason extra source reason
    history=$(apo_state_get HISTORY_FAILURE_EVENTS '')
    [[ -n $history ]] || return 0
    while IFS= read -r line || [[ -n $line ]]; do
        [[ -n $line ]] || return 1
        version=''; timestamp=''; run_id=''; cpu=''; gpu=''; class=''; domain=''
        encoded_source=''; encoded_reason=''; extra=''
        IFS='|' read -r version timestamp run_id cpu gpu class domain encoded_source encoded_reason extra <<< "$line"
        [[ $version == v1 && -z $extra ]] || return 1
        [[ $timestamp =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(Z|[+-][0-9]{4})$ ]] || return 1
        [[ $run_id == "$expected_run" ]] || return 1
        apo_history_validate_failure_class "$class" || return 1
        apo_history_validate_failure_domain "$domain" || return 1
        source=$(apo_history_decode_field "$encoded_source") || return 1
        reason=$(apo_history_decode_field "$encoded_reason") || return 1
        [[ -n $source && -n $reason && $source != *$'\n'* && $source != *$'\r'* ]] || return 1
        [[ $cpu == - ]] || { apo_is_uint "$cpu" && (( cpu >= 100 && cpu <= 10000 )); } || return 1
        [[ $gpu == - ]] || { apo_is_uint "$gpu" && (( gpu >= 100 && gpu <= 10000 )); } || return 1
        case $domain in
            CPU) [[ $cpu != - ]] || return 1 ;;
            GPU) [[ $gpu != - ]] || return 1 ;;
            PAIR) [[ $cpu != - && $gpu != - ]] || return 1 ;;
        esac
        apo_history_emit_ledger "$timestamp" "$run_id" "$cpu" "$gpu" "$class" "$domain" "$source" "$reason" "$basename" || return 1
        case $class:$domain in
            BOOT_FAILURE:CPU|STABILITY_FAILURE:CPU)
                apo_history_emit_cpu "$cpu" "$run_id" HISTORY_FAILURE_EVENT "$basename" || return 1
                ;;
            BOOT_FAILURE:GPU|STABILITY_FAILURE:GPU)
                apo_history_emit_gpu "$gpu" "$run_id" HISTORY_FAILURE_EVENT "$basename" || return 1
                ;;
            BOOT_FAILURE:PAIR|STABILITY_FAILURE:PAIR)
                apo_history_emit_pair "$cpu" "$gpu" "$run_id" HISTORY_FAILURE_EVENT "$basename" || return 1
                ;;
        esac
    done <<< "$history"
}

apo_history_validate_isolation_stage() {
    case $1 in NONE|PLANNED|CPU_TRIAL|GPU_TRIAL|PAIR_TRIAL|DONE) return 0 ;; *) return 1 ;; esac
}

apo_history_emit_isolation_history() {
    local expected_run=$1 basename=$2 history line version timestamp run_id from_stage from_cpu from_gpu
    local to_stage to_cpu to_gpu class domain encoded_reason extra reason source cpu gpu ledger_domain
    history=$(apo_state_get HISTORY_ISOLATION_HISTORY '')
    [[ -n $history ]] || return 0
    while IFS= read -r line || [[ -n $line ]]; do
        [[ -n $line ]] || return 1
        version=''; timestamp=''; run_id=''; from_stage=''; from_cpu=''; from_gpu=''
        to_stage=''; to_cpu=''; to_gpu=''; class=''; domain=''; encoded_reason=''; extra=''
        IFS='|' read -r version timestamp run_id from_stage from_cpu from_gpu to_stage to_cpu to_gpu class domain encoded_reason extra <<< "$line"
        [[ $version == v1 && -z $extra ]] || return 1
        [[ $timestamp =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(Z|[+-][0-9]{4})$ ]] || return 1
        [[ $run_id == "$expected_run" ]] || return 1
        apo_history_validate_isolation_stage "$from_stage" || return 1
        apo_history_validate_isolation_stage "$to_stage" || return 1
        case $class in PASS|BOOT_FAILURE|STABILITY_FAILURE|HARNESS_FAILURE|RECOVERY_FAILURE) ;; *) return 1 ;; esac
        case $domain in CPU|GPU|PAIR|AMBIGUOUS|NONE) ;; *) return 1 ;; esac
        for cpu in "$from_cpu" "$to_cpu"; do
            [[ $cpu == - ]] || { apo_is_uint "$cpu" && (( cpu >= 100 && cpu <= 10000 )); } || return 1
        done
        for gpu in "$from_gpu" "$to_gpu"; do
            [[ $gpu == - ]] || { apo_is_uint "$gpu" && (( gpu >= 100 && gpu <= 10000 )); } || return 1
        done
        reason=$(apo_history_decode_field "$encoded_reason") || return 1
        [[ -n $reason ]] || return 1
        source="HISTORY_ISOLATION_${from_stage}_TO_${to_stage}"
        if [[ $class == BOOT_FAILURE || $class == STABILITY_FAILURE ]]; then
            case $domain in
                CPU)
                    [[ $from_cpu != - ]] || return 1
                    apo_history_emit_cpu "$from_cpu" "$run_id" "$source" "$basename" || return 1
                    ;;
                GPU)
                    [[ $from_gpu != - ]] || return 1
                    apo_history_emit_gpu "$from_gpu" "$run_id" "$source" "$basename" || return 1
                    ;;
                PAIR|AMBIGUOUS)
                    [[ $from_cpu != - && $from_gpu != - ]] || return 1
                    apo_history_emit_pair "$from_cpu" "$from_gpu" "$run_id" "$source" "$basename" || return 1
                    ;;
            esac
            case $domain in AMBIGUOUS) ledger_domain=PAIR ;; *) ledger_domain=$domain ;; esac
            apo_history_emit_ledger "$timestamp" "$run_id" "$from_cpu" "$from_gpu" "$class" "$ledger_domain" "$source" "$reason" "$basename" || return 1
        fi
    done <<< "$history"
}

# Emit only failure facts represented by committed, replay-validated fields.
# Global terminal STATUS/FAILURE_* values are intentionally not interpreted:
# they cannot, by themselves, attribute a clock-domain boundary.
apo_history_emit_loaded_evidence() {
    local run_id=$1 basename=$2 selection_policy boundary history entry domain from_value to_value extra
    local from_cpu from_gpu pair_extra edge_status edge_class edge_target
    local -a entries=()

    boundary=$(apo_state_get CPU_FAILURE_BOUNDARY '')
    [[ -z $boundary ]] || apo_history_emit_cpu_fact "$boundary" "$run_id" CPU_FAILURE_BOUNDARY "$basename" || return 1
    boundary=$(apo_state_get GPU_FAILURE_BOUNDARY '')
    [[ -z $boundary ]] || apo_history_emit_gpu_fact "$boundary" "$run_id" GPU_FAILURE_BOUNDARY "$basename" || return 1

    history=$(apo_state_get CPU_QUALIFICATION_HISTORY '')
    if [[ -n $history ]]; then
        IFS=',' read -r -a entries <<< "$history"
        for entry in "${entries[@]}"; do
            domain=''; from_value=''; to_value=''; extra=''
            IFS=':>' read -r domain from_value to_value extra <<< "$entry"
            [[ $domain == CPU && $from_value =~ ^[0-9]+$ && $to_value =~ ^[0-9]+$ &&
               -z $extra && $from_value -gt $to_value ]] || return 1
            apo_history_emit_cpu_fact "$from_value" "$run_id" CPU_QUALIFICATION_HISTORY "$basename" || return 1
        done
    fi

    history=$(apo_state_get FINAL_BACKOFF_HISTORY '')
    selection_policy=$(apo_state_get CFG_SELECTION_POLICY guarded-v1)
    # Schema-10 evidence may use either the original fixed-order policy name
    # or the adaptive scheduler introduced for new runs.  Both policies commit
    # the same domain-attributed FINAL_BACKOFF_HISTORY record shapes.
    if [[ $selection_policy == adaptive-refined-v1 ]]; then
        selection_policy=refined-max-25
    fi
    if [[ -n $history ]]; then
        IFS=',' read -r -a entries <<< "$history"
        for entry in "${entries[@]}"; do
            domain=''; from_value=''; to_value=''; extra=''
            IFS=':>' read -r domain from_value to_value extra <<< "$entry"
            [[ -n $domain && -n $from_value && -n $to_value && -z $extra ]] || return 1
            case $selection_policy:$domain in
                refined-max-25:QUAL_CPU|refined-max-25:DOMAIN_CPU|refined-max-25:EXACT_CPU)
                    from_cpu=''; from_gpu=''; pair_extra=''
                    IFS='/' read -r from_cpu from_gpu pair_extra <<< "$from_value"
                    [[ $from_cpu =~ ^[0-9]+$ && $from_gpu =~ ^[0-9]+$ && -z $pair_extra ]] || return 1
                    apo_history_emit_cpu_fact "$from_cpu" "$run_id" "FINAL_BACKOFF_$domain" "$basename" || return 1
                    ;;
                refined-max-25:QUAL_GPU|refined-max-25:DOMAIN_GPU|refined-max-25:EXACT_GPU)
                    from_cpu=''; from_gpu=''; pair_extra=''
                    IFS='/' read -r from_cpu from_gpu pair_extra <<< "$from_value"
                    [[ $from_cpu =~ ^[0-9]+$ && $from_gpu =~ ^[0-9]+$ && -z $pair_extra ]] || return 1
                    apo_history_emit_gpu_fact "$from_gpu" "$run_id" "FINAL_BACKOFF_$domain" "$basename" || return 1
                    ;;
                refined-max-25:TRIAL_CPU|refined-max-25:TRIAL_GPU|refined-max-25:TRIAL_PAIR)
                    from_cpu=''; from_gpu=''; pair_extra=''
                    IFS='/' read -r from_cpu from_gpu pair_extra <<< "$from_value"
                    [[ $from_cpu =~ ^[0-9]+$ && $from_gpu =~ ^[0-9]+$ && -z $pair_extra ]] || return 1
                    apo_history_emit_pair_fact "$from_cpu" "$from_gpu" "$run_id" "FINAL_BACKOFF_$domain" "$basename" || return 1
                    ;;
                guarded-v1:CPU)
                    apo_history_emit_cpu_fact "$from_value" "$run_id" FINAL_BACKOFF_CPU "$basename" || return 1
                    ;;
                guarded-v1:GPU)
                    apo_history_emit_gpu_fact "$from_value" "$run_id" FINAL_BACKOFF_GPU "$basename" || return 1
                    ;;
                guarded-v1:PAIR)
                    from_cpu=''; from_gpu=''; pair_extra=''
                    IFS='/' read -r from_cpu from_gpu pair_extra <<< "$from_value"
                    [[ $from_cpu =~ ^[0-9]+$ && $from_gpu =~ ^[0-9]+$ && -z $pair_extra ]] || return 1
                    apo_history_emit_pair_fact "$from_cpu" "$from_gpu" "$run_id" FINAL_BACKOFF_PAIR "$basename" || return 1
                    ;;
                *) return 1 ;;
            esac
        done
    fi

    edge_status=$(apo_state_get EDGE_CPU_STATUS NOT_REQUESTED)
    edge_class=$(apo_state_get EDGE_CPU_FAILURE_CLASS '')
    edge_target=$(apo_state_get EDGE_CPU_TARGET '')
    if [[ $edge_status == REJECTED ]]; then
        case $edge_class in BOOT_FAILURE|STABILITY_FAILURE) ;; *) return 1 ;; esac
        apo_history_emit_cpu_fact "$edge_target" "$run_id" EDGE_CPU_REJECTED "$basename" || return 1
    fi

    apo_history_emit_failure_events "$run_id" "$basename" || return 1
    # HISTORY_ISOLATION_HISTORY is an explanatory transition journal.  The
    # same committed failures are recorded in HISTORY_FAILURE_EVENTS and/or
    # replay-validated backoff fields.  Do not promote the journal itself to
    # future clock-boundary authority.
}

# Run all parsing, restore, validation, compatibility checks, and extraction in
# a subshell so a retained file cannot alter the new run's controller state.
apo_history_screen_validate_emit_file() (
    local source_file=$1 basename run_id origin schema read_only auto_generated edge_status edge_class
    local post_floor_final post_floor_final_stage
    local expected_profile=${APO_PROFILE:-} expected_gpu_key=${APO_GPU_KEY:-}
    local expected_test_voltage=${APO_TEST_VOLTAGE:-}
    local expected_baseline_cpu expected_baseline_gpu expected_baseline_voltage
    local expected_model expected_compatible expected_arch state_key
    local -A schema_fields=() metadata=() evidence=() loaded_state=()

    expected_model=$(apo_history_expected_discovery_value DISC_MODEL)
    expected_compatible=$(apo_history_expected_discovery_value DISC_COMPATIBLE)
    expected_arch=$(apo_history_expected_discovery_value DISC_ARCH)
    case ${APO_SWEEP_DOMAIN:-all} in
        all)
            expected_baseline_cpu=${APO_NORMAL_CPU:-}
            expected_baseline_gpu=${APO_NORMAL_GPU:-}
            expected_baseline_voltage=${APO_NORMAL_VOLTAGE:-}
            ;;
        cpu|gpu)
            expected_baseline_cpu=${APO_SOURCE_AUTO_BASELINE_CPU:-}
            expected_baseline_gpu=${APO_SOURCE_AUTO_BASELINE_GPU:-}
            expected_baseline_voltage=${APO_SOURCE_AUTO_BASELINE_VOLTAGE:-}
            ;;
    esac

    # Schema compatibility is the first and cheapest screen.  Retained files
    # from an older controller may predate FORMAT_VERSION or other metadata
    # required by the current strict validator.  They are preserved but ignored;
    # only a current-schema state can constrain a new plan or fail the scan.
    apo_history_load_screen_fields "$source_file" schema_fields RUN_SCHEMA || return 1
    schema=$(apo_history_state_value schema_fields RUN_SCHEMA '')
    [[ $schema == "$APO_CURRENT_RUN_SCHEMA" ]] || return 3

    # Now prove whether this current-schema file can belong to the current
    # automatic history domain.  Do not make an unrelated
    # reset/prepare/test/restore audit pass a full tuning-state validator merely
    # because it shares the target's artifact namespace.
    apo_history_load_screen_fields "$source_file" metadata \
        FORMAT_VERSION RUN_SCHEMA RUN_ID REMOTE_TARGET TARGET_SLUG ORIGIN_COMMAND \
        READ_ONLY_RUN CFG_AUTO_GENERATED_CANDIDATES POST_FLOOR_FINAL \
        POST_FLOOR_FINAL_STAGE || return 1
    [[ $(apo_history_state_value metadata FORMAT_VERSION '') == 1 ]] || {
        [[ -n $(apo_history_state_value metadata FORMAT_VERSION '') ]] && return 3
        return 1
    }
    [[ $(apo_history_state_value metadata REMOTE_TARGET '') == "${APO_REMOTE_TARGET:-}" ]] || {
        [[ -n $(apo_history_state_value metadata REMOTE_TARGET '') ]] && return 3
        return 1
    }

    origin=$(apo_history_state_value metadata ORIGIN_COMMAND '')
    case $origin in
        reset|prepare|test|restore) return 3 ;;
        overclock) ;;
        *) return 1 ;;
    esac
    [[ $(apo_history_state_value metadata RUN_SCHEMA '') == "$APO_CURRENT_RUN_SCHEMA" ]] || return 1
    read_only=$(apo_history_state_value metadata READ_ONLY_RUN '')
    case $read_only in 0) ;; 1) return 3 ;; *) return 1 ;; esac
    auto_generated=$(apo_history_state_value metadata CFG_AUTO_GENERATED_CANDIDATES '')
    case $auto_generated in 1) ;; 0) return 3 ;; *) return 1 ;; esac

    # A linked longer-final run is deliberately saved around its verified
    # apply rollback, before inherited final markers are normalized.  It is
    # resumable controller state, not a completed source of new clock-boundary
    # evidence.  The original source run remains available, so ignore only
    # these exact transitions during a fresh history scan.
    post_floor_final=$(apo_history_state_value metadata POST_FLOOR_FINAL 0)
    post_floor_final_stage=$(apo_history_state_value metadata POST_FLOOR_FINAL_STAGE '')
    if [[ $post_floor_final == 1 ]]; then
        case $post_floor_final_stage in
            ROLLBACK_PENDING|ROLLBACK_COMPLETE) return 3 ;;
        esac
    fi

    # Only fields that record a committed failure/backoff result make an
    # automatic state a history authority.  Imported HISTORY_* plan snapshots
    # deliberately do not count, otherwise merely consuming old history would
    # manufacture a new retained evidence source.  EDGE_CPU_TARGET alone is
    # likewise scheduling state, not a rejected boundary.
    apo_history_load_screen_fields "$source_file" evidence \
        CPU_FAILURE_BOUNDARY GPU_FAILURE_BOUNDARY CPU_QUALIFICATION_HISTORY \
        FINAL_BACKOFF_HISTORY EDGE_CPU_STATUS EDGE_CPU_FAILURE_CLASS EDGE_CPU_TARGET \
        HISTORY_FAILURE_EVENTS || return 1
    edge_status=$(apo_history_state_value evidence EDGE_CPU_STATUS NOT_REQUESTED)
    edge_class=$(apo_history_state_value evidence EDGE_CPU_FAILURE_CLASS '')
    if [[ -z $(apo_history_state_value evidence CPU_FAILURE_BOUNDARY '') &&
          -z $(apo_history_state_value evidence GPU_FAILURE_BOUNDARY '') &&
          -z $(apo_history_state_value evidence CPU_QUALIFICATION_HISTORY '') &&
          -z $(apo_history_state_value evidence FINAL_BACKOFF_HISTORY '') &&
          -z $(apo_history_state_value evidence HISTORY_FAILURE_EVENTS '') &&
          $edge_status != REJECTED && -z $edge_class ]]; then
        return 3
    fi

    # Evidence-bearing states remain fully fail-closed.  The complete strict
    # loader and resume validator below reject damage anywhere in the state,
    # not only in the screening fields.
    apo_history_load_state_strict "$source_file" loaded_state || return 1

    run_id=$(apo_history_state_value loaded_state RUN_ID '')
    basename=${source_file##*/}
    apo_is_safe_run_id "$run_id" || return 1
    [[ $basename == "${APO_TARGET_SLUG}-${run_id}.state" ]] || return 1
    [[ $(apo_history_state_value loaded_state TARGET_SLUG '') == "$APO_TARGET_SLUG" ]] || return 1

    APO_STATE=()
    # Both arrays are associative; ShellCheck otherwise treats their keys as
    # arithmetic expressions.
    # shellcheck disable=SC2004
    for state_key in "${!loaded_state[@]}"; do APO_STATE[$state_key]=${loaded_state[$state_key]}; done
    # This assignment is intentionally isolated by the surrounding subshell.
    # shellcheck disable=SC2030
    APO_STATE_FILE=$source_file
    apo_history_validate_loaded_state || return 1
    apo_history_loaded_state_is_compatible \
        "$expected_profile" "$expected_gpu_key" "$expected_test_voltage" \
        "$expected_baseline_cpu" "$expected_baseline_gpu" "$expected_baseline_voltage" \
        "$expected_model" "$expected_compatible" "$expected_arch" || return 3

    printf 'ACCEPT|||%s|%s\n' "$run_id" "$basename"
    apo_history_emit_loaded_evidence "$run_id" "$basename"
)

apo_history_record() {
    local kind=$1 value=$2 run_id=$3 source=$4 basename=$5 record pair cpu gpu
    record="$kind|$value|$run_id|$source|$basename"
    if [[ ! -v APO_HISTORY_SEEN_RECORDS[$record] ]]; then
        APO_HISTORY_SEEN_RECORDS[$record]=1
        APO_HISTORY_RECORDS+=("$record")
        APO_HISTORY_EVIDENCE_COUNT=$((APO_HISTORY_EVIDENCE_COUNT + 1))
    fi
    case $kind in
        CPU)
            if [[ -z $APO_HISTORY_CPU_FAILURE_BOUNDARY || $value -lt APO_HISTORY_CPU_FAILURE_BOUNDARY ]]; then
                APO_HISTORY_CPU_FAILURE_BOUNDARY=$value
            fi
            ;;
        GPU)
            if [[ -z $APO_HISTORY_GPU_FAILURE_BOUNDARY || $value -lt APO_HISTORY_GPU_FAILURE_BOUNDARY ]]; then
                APO_HISTORY_GPU_FAILURE_BOUNDARY=$value
            fi
            ;;
        PAIR)
            pair=$value
            IFS='/' read -r cpu gpu <<< "$pair"
            [[ $cpu =~ ^[0-9]+$ && $gpu =~ ^[0-9]+$ ]] || return 1
            if [[ ! -v APO_HISTORY_SEEN_PAIRS[$pair] ]]; then
                APO_HISTORY_SEEN_PAIRS[$pair]=1
                APO_HISTORY_RAW_PAIRS+=("$pair")
            fi
            ;;
        *) return 1 ;;
    esac
}

apo_history_record_ledger() {
    local timestamp=$1 run_id=$2 cpu=$3 gpu=$4 class=$5 domain=$6
    local encoded_source=$7 encoded_reason=$8 basename=$9 record
    [[ $timestamp =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(Z|[+-][0-9]{4})$ || $timestamp == unknown ]] || return 1
    apo_is_safe_run_id "$run_id" || return 1
    [[ $cpu == - ]] || apo_is_uint "$cpu" || return 1
    [[ $gpu == - ]] || apo_is_uint "$gpu" || return 1
    apo_history_validate_failure_class "$class" || return 1
    apo_history_validate_failure_domain "$domain" || return 1
    apo_history_decode_field "$encoded_source" >/dev/null || return 1
    apo_history_decode_field "$encoded_reason" >/dev/null || return 1
    [[ -n $basename ]] || return 1
    record="$timestamp|$run_id|$cpu|$gpu|$class|$domain|$encoded_source|$encoded_reason|$basename"
    if [[ ! -v APO_HISTORY_SEEN_LEDGER_RECORDS[$record] ]]; then
        APO_HISTORY_SEEN_LEDGER_RECORDS[$record]=1
        APO_HISTORY_LEDGER_RECORDS+=("$record")
    fi
}

apo_history_finalize_frontiers() {
    local candidate other candidate_cpu candidate_gpu other_cpu other_gpu dominated insert_at current
    local -a frontier=() sorted=()

    for candidate in "${APO_HISTORY_RAW_PAIRS[@]}"; do
        IFS='/' read -r candidate_cpu candidate_gpu <<< "$candidate"
        dominated=0
        for other in "${APO_HISTORY_RAW_PAIRS[@]}"; do
            [[ $other != "$candidate" ]] || continue
            IFS='/' read -r other_cpu other_gpu <<< "$other"
            if (( other_cpu <= candidate_cpu && other_gpu <= candidate_gpu &&
                  (other_cpu < candidate_cpu || other_gpu < candidate_gpu) )); then
                dominated=1
                break
            fi
        done
        (( dominated == 0 )) && frontier+=("$candidate")
    done

    for candidate in "${frontier[@]}"; do
        IFS='/' read -r candidate_cpu candidate_gpu <<< "$candidate"
        insert_at=${#sorted[@]}
        for (( current=0; current<${#sorted[@]}; current++ )); do
            IFS='/' read -r other_cpu other_gpu <<< "${sorted[$current]}"
            if (( candidate_cpu < other_cpu || (candidate_cpu == other_cpu && candidate_gpu < other_gpu) )); then
                insert_at=$current
                break
            fi
        done
        sorted=("${sorted[@]:0:insert_at}" "$candidate" "${sorted[@]:insert_at}")
    done

    APO_HISTORY_PAIR_FRONTIERS=''
    for candidate in "${sorted[@]}"; do
        if [[ -n $APO_HISTORY_PAIR_FRONTIERS ]]; then
            APO_HISTORY_PAIR_FRONTIERS+=",$candidate"
        else
            APO_HISTORY_PAIR_FRONTIERS=$candidate
        fi
    done

    APO_HISTORY_PROVENANCE=''
    for current in "${APO_HISTORY_RECORDS[@]}"; do
        if [[ -n $APO_HISTORY_PROVENANCE ]]; then
            APO_HISTORY_PROVENANCE+=$'\n'
        fi
        APO_HISTORY_PROVENANCE+=$current
    done
}

apo_history_domain_resolution_mhz() {
    local resolution
    case $1 in
        CPU) resolution=${APO_CPU_RESOLUTION_MHZ:-${APO_AUTO_REFINE_STEP_MHZ:-25}} ;;
        GPU) resolution=${APO_GPU_RESOLUTION_MHZ:-${APO_AUTO_REFINE_STEP_MHZ:-25}} ;;
        *) return 1 ;;
    esac
    apo_is_uint "$resolution" && (( resolution > 0 )) || return 1
    printf '%s' "$resolution"
}

apo_history_domain_candidate_floor_mhz() {
    local floor
    case $1 in
        CPU)
            floor=${APO_CPU_MIN:-$(( ${APO_NORMAL_CPU:-0} + 1 ))}
            ;;
        GPU)
            floor=${APO_GPU_MIN:-$(( ${APO_NORMAL_GPU:-0} + 1 ))}
            ;;
        *) return 1 ;;
    esac
    apo_is_uint "$floor" || return 1
    printf '%s' "$floor"
}

apo_history_clamp_candidate_floor() {
    local domain=$1 candidate=$2 floor
    apo_is_uint "$candidate" || return 1
    floor=$(apo_history_domain_candidate_floor_mhz "$domain") || return 1
    (( candidate < floor )) && candidate=$floor
    printf '%s' "$candidate"
}

apo_history_failure_exclusive_cap() {
    local domain=$1 boundary=$2 resolution=$3 candidate floor
    apo_is_uint "$boundary" && apo_is_uint "$resolution" && (( resolution > 0 )) || return 1
    floor=$(apo_history_domain_candidate_floor_mhz "$domain") || return 1
    candidate=$floor
    if (( boundary > resolution )); then
        candidate=$((boundary - resolution))
    fi
    apo_history_clamp_candidate_floor "$domain" "$candidate"
}

apo_history_resolve_scalar_caps() {
    local requested_cpu=$1 requested_gpu=$2 cap resolution
    APO_HISTORY_EFFECTIVE_CPU_MAX=$requested_cpu
    APO_HISTORY_EFFECTIVE_GPU_MAX=$requested_gpu
    APO_HISTORY_CPU_RETAINED_CAP=''
    APO_HISTORY_GPU_RETAINED_CAP=''
    [[ -z $requested_cpu ]] || apo_is_uint "$requested_cpu" || return 1
    [[ -z $requested_gpu ]] || apo_is_uint "$requested_gpu" || return 1
    if [[ -n $APO_HISTORY_EFFECTIVE_CPU_MAX && -n $APO_HISTORY_CPU_FAILURE_BOUNDARY ]]; then
        resolution=$(apo_history_domain_resolution_mhz CPU) || return 1
        cap=$(apo_history_failure_exclusive_cap CPU "$APO_HISTORY_CPU_FAILURE_BOUNDARY" "$resolution") || return 1
        if (( cap >= APO_HISTORY_CPU_FAILURE_BOUNDARY && ${APO_CPU_MAX_OPTION_SEEN:-0} == 0 )); then
            return 1
        fi
        APO_HISTORY_CPU_RETAINED_CAP=$cap
        if (( ${APO_CPU_MAX_OPTION_SEEN:-0} == 0 )) &&
           [[ -z $APO_HISTORY_EFFECTIVE_CPU_MAX || $cap -lt APO_HISTORY_EFFECTIVE_CPU_MAX ]]; then
            APO_HISTORY_EFFECTIVE_CPU_MAX=$cap
        fi
    fi
    if [[ -n $APO_HISTORY_EFFECTIVE_GPU_MAX && -n $APO_HISTORY_GPU_FAILURE_BOUNDARY ]]; then
        resolution=$(apo_history_domain_resolution_mhz GPU) || return 1
        cap=$(apo_history_failure_exclusive_cap GPU "$APO_HISTORY_GPU_FAILURE_BOUNDARY" "$resolution") || return 1
        if (( cap >= APO_HISTORY_GPU_FAILURE_BOUNDARY && ${APO_GPU_MAX_OPTION_SEEN:-0} == 0 )); then
            return 1
        fi
        APO_HISTORY_GPU_RETAINED_CAP=$cap
        if (( ${APO_GPU_MAX_OPTION_SEEN:-0} == 0 )) &&
           [[ -z $APO_HISTORY_EFFECTIVE_GPU_MAX || $cap -lt APO_HISTORY_EFFECTIVE_GPU_MAX ]]; then
            APO_HISTORY_EFFECTIVE_GPU_MAX=$cap
        fi
    fi
}

apo_history_append_plan_warning() {
    local warning=$1
    [[ -n $warning ]] || return 1
    if [[ -n $APO_HISTORY_PLAN_WARNING ]]; then
        APO_HISTORY_PLAN_WARNING+=" $warning"
    else
        APO_HISTORY_PLAN_WARNING=$warning
    fi
    return 0
}

apo_history_finalize_ceiling_warnings() {
    local effective_cpu=$1 effective_gpu=$2
    APO_HISTORY_CPU_EXPLICIT_MAX_OVERRIDE=0
    APO_HISTORY_GPU_EXPLICIT_MAX_OVERRIDE=0
    APO_HISTORY_PLAN_WARNING=''

    if (( ${APO_CPU_MAX_OPTION_SEEN:-0} == 1 )) &&
       [[ $effective_cpu =~ ^[0-9]+$ && $APO_HISTORY_CPU_RETAINED_CAP =~ ^[0-9]+$ ]] &&
       (( effective_cpu > APO_HISTORY_CPU_RETAINED_CAP )); then
        APO_HISTORY_CPU_EXPLICIT_MAX_OVERRIDE=1
        apo_history_append_plan_warning "Explicit --cpu-max ${effective_cpu} MHz exceeds the retained CPU ceiling ${APO_HISTORY_CPU_RETAINED_CAP} MHz; the explicit value is the reverse-search starting ceiling."
    fi
    if (( ${APO_GPU_MAX_OPTION_SEEN:-0} == 1 )) &&
       [[ $effective_gpu =~ ^[0-9]+$ && $APO_HISTORY_GPU_RETAINED_CAP =~ ^[0-9]+$ ]] &&
       (( effective_gpu > APO_HISTORY_GPU_RETAINED_CAP )); then
        APO_HISTORY_GPU_EXPLICIT_MAX_OVERRIDE=1
        apo_history_append_plan_warning "Explicit --gpu-max ${effective_gpu} MHz exceeds the retained GPU ceiling ${APO_HISTORY_GPU_RETAINED_CAP} MHz; the explicit value is the reverse-search starting ceiling."
    fi
    return 0
}

apo_history_derive_approach_start() {
    local maximum=$1 normal=$2 coarse_step=$3
    apo_is_uint "$maximum" && apo_is_uint "$normal" && apo_is_uint "$coarse_step" || return 1
    (( maximum > normal )) || return 0
    printf '%s' "$maximum"
}

# A user-selected maximum or compatible retained failure turns each affected
# domain into a reverse search.  The first candidate is the effective ceiling
# itself.  APO_CPU_MIN and APO_GPU_MIN remain exclusively user-selected lower
# exhaustion bounds; the reverse scheduler consumes the separate
# approach-start fields below.
apo_history_apply_approach_starts() {
    local domain=$1 effective_cpu=$2 effective_gpu=$3 cpu_start='' gpu_start=''
    local normal_cpu=${APO_NORMAL_CPU:-} normal_gpu=${APO_NORMAL_GPU:-}
    local cpu_min_source=automatic-baseline gpu_min_source=automatic-baseline
    local cpu_reverse_relevant=0 gpu_reverse_relevant=0
    APO_HISTORY_CPU_APPROACH_START=''
    APO_HISTORY_GPU_APPROACH_START=''
    APO_HISTORY_CPU_REVERSE_SEARCH=0
    APO_HISTORY_GPU_REVERSE_SEARCH=0

    if (( ${APO_CPU_MAX_OPTION_SEEN:-0} == 1 )); then
        cpu_reverse_relevant=1
    elif (( APO_HISTORY_ACCEPTED_STATES > 0 )) &&
         [[ -n $APO_HISTORY_CPU_RETAINED_CAP ]]; then
        cpu_reverse_relevant=1
    fi
    if (( ${APO_GPU_MAX_OPTION_SEEN:-0} == 1 )); then
        gpu_reverse_relevant=1
    elif (( APO_HISTORY_ACCEPTED_STATES > 0 )) &&
         [[ -n $APO_HISTORY_GPU_RETAINED_CAP ]]; then
        gpu_reverse_relevant=1
    fi
    if [[ $domain == gpu ]]; then
        APO_CPU_MIN=''
        cpu_reverse_relevant=0
    elif [[ $domain == cpu ]]; then
        APO_GPU_MIN=''
        gpu_reverse_relevant=0
    fi

    if [[ $domain != gpu ]] && (( cpu_reverse_relevant == 1 )); then
        apo_is_uint "$normal_cpu" || return 1
        cpu_start=$(apo_history_derive_approach_start "$effective_cpu" "$normal_cpu" "$APO_AUTO_CPU_STEP_MHZ") || return 1
        if [[ -n $cpu_start ]]; then
            APO_HISTORY_CPU_APPROACH_START=$cpu_start
            APO_HISTORY_CPU_REVERSE_SEARCH=1
        fi
    fi
    if [[ $domain != cpu ]] && (( gpu_reverse_relevant == 1 )); then
        apo_is_uint "$normal_gpu" || return 1
        gpu_start=$(apo_history_derive_approach_start "$effective_gpu" "$normal_gpu" "$APO_AUTO_GPU_STEP_MHZ") || return 1
        if [[ -n $gpu_start ]]; then
            APO_HISTORY_GPU_APPROACH_START=$gpu_start
            APO_HISTORY_GPU_REVERSE_SEARCH=1
        fi
    fi

    if (( ${APO_CPU_MIN_OPTION_SEEN:-0} == 1 )); then
        cpu_min_source=cli
    fi
    if (( ${APO_GPU_MIN_OPTION_SEEN:-0} == 1 )); then
        gpu_min_source=cli
    fi
    apo_state_set CFG_CPU_MIN_SOURCE "$cpu_min_source"
    apo_state_set CFG_GPU_MIN_SOURCE "$gpu_min_source"
    apo_state_set HISTORY_CPU_APPROACH_START "$APO_HISTORY_CPU_APPROACH_START"
    apo_state_set HISTORY_GPU_APPROACH_START "$APO_HISTORY_GPU_APPROACH_START"
    apo_state_set HISTORY_CPU_REVERSE_SEARCH "$APO_HISTORY_CPU_REVERSE_SEARCH"
    apo_state_set HISTORY_GPU_REVERSE_SEARCH "$APO_HISTORY_GPU_REVERSE_SEARCH"
}

apo_history_pair_is_forbidden() {
    local cpu=$1 gpu=$2 frontiers=${3:-$APO_HISTORY_PAIR_FRONTIERS} pair failed_cpu failed_gpu extra
    apo_is_uint "$cpu" && apo_is_uint "$gpu" || return 2
    [[ -n $frontiers ]] || return 1
    local -a pairs=()
    IFS=',' read -r -a pairs <<< "$frontiers"
    for pair in "${pairs[@]}"; do
        failed_cpu=''; failed_gpu=''; extra=''
        IFS='/' read -r failed_cpu failed_gpu extra <<< "$pair"
        [[ $failed_cpu =~ ^[0-9]+$ && $failed_gpu =~ ^[0-9]+$ && -z $extra ]] || return 2
        if (( cpu >= failed_cpu && gpu >= failed_gpu )); then
            return 0
        fi
    done
    return 1
}

apo_history_validate_plan_pair() {
    local label=$1 cpu=$2 gpu=$3 frontiers=$4
    if ! apo_is_uint "$cpu" || ! apo_is_uint "$gpu"; then
        APO_HISTORY_VALIDATION_REASON="$label must contain numeric CPU and GPU clocks."
        APO_HISTORY_ERROR=$APO_HISTORY_VALIDATION_REASON
        return 1
    fi
    if apo_history_pair_is_forbidden "$cpu" "$gpu" "$frontiers"; then
        APO_HISTORY_VALIDATION_REASON="$label enters a retained ambiguous failed-pair frontier."
        APO_HISTORY_ERROR=$APO_HISTORY_VALIDATION_REASON
        return 1
    else
        case $? in 1) ;; *)
            APO_HISTORY_VALIDATION_REASON='The retained ambiguous failed-pair frontier is malformed.'
            APO_HISTORY_ERROR=$APO_HISTORY_VALIDATION_REASON
            return 1
            ;;
        esac
    fi
}

# Validate the independently persisted history-isolation scheduler plan.  This
# is safe for alpha.49 schema-10 states: absent fields mean NONE/no plan.
apo_history_validate_plan_state() {
    local stage frontiers anchor_cpu anchor_gpu cpu_trial_cpu cpu_trial_gpu
    local gpu_trial_cpu gpu_trial_gpu pair_trial_cpu pair_trial_gpu handoff_cpu handoff_gpu cpu_floor gpu_floor
    local cpu_max gpu_max base_cpu handoff_valid=0
    APO_HISTORY_VALIDATION_REASON=''
    APO_HISTORY_ERROR=''
    stage=$(apo_state_get HISTORY_ISOLATION_STAGE NONE)
    apo_history_validate_isolation_stage "$stage" || {
        APO_HISTORY_VALIDATION_REASON="Unknown history isolation stage: $stage"
        APO_HISTORY_ERROR=$APO_HISTORY_VALIDATION_REASON
        return 1
    }
    [[ $stage != NONE ]] || return 0

    frontiers=$(apo_state_get HISTORY_PAIR_FRONTIERS '')
    anchor_cpu=$(apo_state_get HISTORY_ISOLATION_ANCHOR_CPU '')
    anchor_gpu=$(apo_state_get HISTORY_ISOLATION_ANCHOR_GPU '')
    cpu_trial_cpu=$(apo_state_get HISTORY_CPU_TRIAL_CPU '')
    cpu_trial_gpu=$(apo_state_get HISTORY_CPU_TRIAL_GPU '')
    gpu_trial_cpu=$(apo_state_get HISTORY_GPU_TRIAL_CPU '')
    gpu_trial_gpu=$(apo_state_get HISTORY_GPU_TRIAL_GPU '')
    pair_trial_cpu=$(apo_state_get HISTORY_PAIR_TRIAL_CPU '')
    pair_trial_gpu=$(apo_state_get HISTORY_PAIR_TRIAL_GPU '')
    handoff_cpu=$(apo_state_get HISTORY_ISOLATION_HANDOFF_CPU '')
    handoff_gpu=$(apo_state_get HISTORY_ISOLATION_HANDOFF_GPU '')
    cpu_floor=$(apo_history_domain_candidate_floor_mhz CPU) || return 1
    gpu_floor=$(apo_history_domain_candidate_floor_mhz GPU) || return 1
    cpu_max=$(apo_state_get CFG_CPU_MAX_EFFECTIVE '')
    gpu_max=$(apo_state_get CFG_GPU_MAX_EFFECTIVE '')
    base_cpu=$(apo_state_get HISTORY_BASE_CPU_QUALIFIED_CLOCK '')

    apo_is_uint "$cpu_max" && apo_is_uint "$gpu_max" &&
        (( cpu_max >= cpu_floor && gpu_max >= gpu_floor )) || {
        APO_HISTORY_VALIDATION_REASON='History isolation has no valid effective maximum pair.'
        APO_HISTORY_ERROR=$APO_HISTORY_VALIDATION_REASON
        return 1
    }
    apo_is_uint "$anchor_cpu" && apo_is_uint "$anchor_gpu" || {
        APO_HISTORY_VALIDATION_REASON='History isolation has no numeric anchor pair.'
        APO_HISTORY_ERROR=$APO_HISTORY_VALIDATION_REASON
        return 1
    }
    apo_history_validate_plan_pair 'CPU trial' "$cpu_trial_cpu" "$cpu_trial_gpu" "$frontiers" || return 1
    apo_history_validate_plan_pair 'GPU trial' "$gpu_trial_cpu" "$gpu_trial_gpu" "$frontiers" || return 1
    apo_history_validate_plan_pair 'pair trial' "$pair_trial_cpu" "$pair_trial_gpu" "$frontiers" || return 1
    if (( anchor_cpu < cpu_floor || anchor_gpu < gpu_floor ||
          cpu_trial_cpu < cpu_floor || cpu_trial_gpu < gpu_floor ||
          gpu_trial_cpu < cpu_floor || gpu_trial_gpu < gpu_floor ||
          pair_trial_cpu < cpu_floor || pair_trial_gpu < gpu_floor )); then
        APO_HISTORY_VALIDATION_REASON='History isolation contains a clock below its protected or user-requested floor.'
        APO_HISTORY_ERROR=$APO_HISTORY_VALIDATION_REASON
        return 1
    fi
    if (( anchor_cpu > cpu_max || anchor_gpu > gpu_max ||
          cpu_trial_cpu > cpu_max || cpu_trial_gpu > gpu_max ||
          gpu_trial_cpu > cpu_max || gpu_trial_gpu > gpu_max ||
          pair_trial_cpu > cpu_max || pair_trial_gpu > gpu_max )); then
        APO_HISTORY_VALIDATION_REASON='History isolation contains a clock above its persisted effective maximum.'
        APO_HISTORY_ERROR=$APO_HISTORY_VALIDATION_REASON
        return 1
    fi
    if (( cpu_trial_cpu >= anchor_cpu || cpu_trial_gpu != anchor_gpu )); then
        APO_HISTORY_VALIDATION_REASON='CPU trial must lower only CPU from the isolation anchor.'
        APO_HISTORY_ERROR=$APO_HISTORY_VALIDATION_REASON
        return 1
    fi
    if (( gpu_trial_cpu != anchor_cpu || gpu_trial_gpu >= anchor_gpu )); then
        APO_HISTORY_VALIDATION_REASON='GPU trial must lower only GPU from the isolation anchor.'
        APO_HISTORY_ERROR=$APO_HISTORY_VALIDATION_REASON
        return 1
    fi
    if (( pair_trial_cpu != cpu_trial_cpu || pair_trial_gpu != gpu_trial_gpu )); then
        APO_HISTORY_VALIDATION_REASON='Pair trial must combine the exact CPU-only and GPU-only trial reductions.'
        APO_HISTORY_ERROR=$APO_HISTORY_VALIDATION_REASON
        return 1
    fi
    if [[ $stage == DONE ]]; then
        if ! apo_is_uint "$handoff_cpu" || ! apo_is_uint "$handoff_gpu"; then
            APO_HISTORY_VALIDATION_REASON='History isolation handoff must contain numeric CPU and GPU clocks.'
            APO_HISTORY_ERROR=$APO_HISTORY_VALIDATION_REASON
            return 1
        fi
        if (( handoff_cpu < cpu_floor || handoff_gpu < gpu_floor )); then
            APO_HISTORY_VALIDATION_REASON='History isolation handoff crosses a protected or user-requested floor.'
            APO_HISTORY_ERROR=$APO_HISTORY_VALIDATION_REASON
            return 1
        fi
        if (( handoff_cpu > cpu_max || handoff_gpu > gpu_max )); then
            APO_HISTORY_VALIDATION_REASON='History isolation handoff exceeds its persisted effective maximum.'
            APO_HISTORY_ERROR=$APO_HISTORY_VALIDATION_REASON
            return 1
        fi
        if (( ( handoff_cpu == anchor_cpu && handoff_gpu == anchor_gpu ) ||
              ( handoff_cpu == cpu_trial_cpu && handoff_gpu == cpu_trial_gpu ) ||
              ( handoff_cpu == gpu_trial_cpu && handoff_gpu == gpu_trial_gpu ) ||
              ( handoff_cpu == pair_trial_cpu && handoff_gpu == pair_trial_gpu ) )); then
            handoff_valid=1
        elif apo_is_uint "$base_cpu" && (( handoff_cpu == base_cpu && handoff_gpu <= gpu_trial_gpu )); then
            # When a fresh GPU sweep itself drops below the retained ambiguous
            # quadrant, the scheduler restores the freshly-qualified CPU and
            # hands off that exact newly-proved GPU clock.
            handoff_valid=1
        fi
        (( handoff_valid == 1 )) || {
            APO_HISTORY_VALIDATION_REASON='History isolation handoff is not one of its planned or freshly-qualified trial pairs.'
            APO_HISTORY_ERROR=$APO_HISTORY_VALIDATION_REASON
            return 1
        }
    elif [[ -n $handoff_cpu || -n $handoff_gpu ]]; then
        APO_HISTORY_VALIDATION_REASON='History isolation handoff clocks are present before the plan is complete.'
        APO_HISTORY_ERROR=$APO_HISTORY_VALIDATION_REASON
        return 1
    fi
}

# Scan every exact regular TARGET-RUN_ID.state file in the retained output
# directory.  Old schemas and unrelated commands are ignored.  A malformed or
# validator-rejected current-schema auto-overclock state for this exact target
# fails closed instead of silently authorizing a higher clock.
apo_history_scan_retained_states() {
    local source_file output status line kind value run_id evidence_source basename extra
    local timestamp cpu gpu class domain encoded_source encoded_reason field10 field11
    local had_nullglob=0
    local -a source_files=()

    apo_history_reset
    [[ -n ${APO_OUTPUT_DIR:-} && -n ${APO_TARGET_SLUG:-} && -n ${APO_REMOTE_TARGET:-} ]] || {
        APO_HISTORY_SCAN_ERROR='History scan requires output directory and exact parsed target identity.'
        return 1
    }
    [[ -d $APO_OUTPUT_DIR ]] || return 0

    shopt -q nullglob && had_nullglob=1
    shopt -s nullglob
    source_files=("$APO_OUTPUT_DIR/${APO_TARGET_SLUG}-"*.state)
    (( had_nullglob == 1 )) || shopt -u nullglob

    for source_file in "${source_files[@]}"; do
        [[ -f $source_file && ! -L $source_file ]] || continue
        # The validator's APO_STATE_FILE assignment is isolated in its own
        # subshell; this is the caller's new-run state path.
        # shellcheck disable=SC2031
        if [[ -n ${APO_STATE_FILE:-} && $source_file -ef $APO_STATE_FILE ]]; then
            continue
        fi
        APO_HISTORY_SCANNED_STATES=$((APO_HISTORY_SCANNED_STATES + 1))
        output=''
        if output=$(apo_history_screen_validate_emit_file "$source_file"); then
            :
        else
            status=$?
            if (( status == 3 )); then continue; fi
            APO_HISTORY_SCAN_ERROR="Retained state failed strict history validation: ${source_file##*/}"
            apo_history_reset
            APO_HISTORY_SCAN_ERROR="Retained state failed strict history validation: ${source_file##*/}"
            return 1
        fi
        while IFS='|' read -r kind value run_id evidence_source basename extra timestamp cpu gpu class domain encoded_source encoded_reason field10 field11; do
            [[ -n $kind ]] || continue
            if [[ $kind == ACCEPT ]]; then
                [[ -z $value$run_id$extra$timestamp$cpu$gpu$class$domain$encoded_source$encoded_reason$field10$field11 && -n $evidence_source && -n $basename ]] || {
                    APO_HISTORY_SCAN_ERROR="Retained state emitted malformed acceptance evidence: ${source_file##*/}"
                    return 1
                }
                APO_HISTORY_ACCEPTED_STATES=$((APO_HISTORY_ACCEPTED_STATES + 1))
                continue
            fi
            if [[ $kind == LEDGER ]]; then
                # LEDGER|timestamp|run|cpu|gpu|class|domain|b64(source)|b64(reason)|basename
                [[ -n $value && -n $run_id && -n $evidence_source && -n $basename && -n $extra && -n $timestamp && -n $cpu && -n $gpu && -n $class && -z $domain$encoded_source$encoded_reason$field10$field11 ]] || {
                    APO_HISTORY_SCAN_ERROR="Retained state emitted malformed ledger evidence: ${source_file##*/}"
                    return 1
                }
                apo_history_record_ledger "$value" "$run_id" "$evidence_source" "$basename" "$extra" "$timestamp" "$cpu" "$gpu" "$class" || {
                    APO_HISTORY_SCAN_ERROR="Retained state emitted invalid ledger evidence: ${source_file##*/}"
                    return 1
                }
                continue
            fi
            [[ -z $extra$timestamp$cpu$gpu$class$domain$encoded_source$encoded_reason$field10$field11 ]] || {
                APO_HISTORY_SCAN_ERROR="Retained state emitted malformed history evidence: ${source_file##*/}"
                return 1
            }
            case $kind in CPU|GPU|PAIR) ;; *)
                APO_HISTORY_SCAN_ERROR="Retained state emitted unknown history evidence: ${source_file##*/}"
                return 1
                ;;
            esac
            apo_history_record "$kind" "$value" "$run_id" "$evidence_source" "$basename" || {
                APO_HISTORY_SCAN_ERROR="Retained state emitted invalid history evidence: ${source_file##*/}"
                return 1
            }
        done <<< "$output"
    done
    apo_history_finalize_frontiers
}

apo_history_generated_timestamp_is_valid() {
    local timestamp=${1-}
    [[ $timestamp =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{4}$ ]]
}

apo_history_existing_ledger_timestamp() {
    local source_file=$1 file_fd first_line second_line timestamp

    [[ -f $source_file && ! -L $source_file && -r $source_file ]] || return 1
    exec {file_fd}< "$source_file" || return 1
    if ! IFS= read -r first_line <&"$file_fd"; then
        exec {file_fd}<&-
        return 1
    fi
    if ! IFS= read -r second_line <&"$file_fd"; then
        exec {file_fd}<&-
        return 1
    fi
    exec {file_fd}<&-
    [[ $first_line == 'AutoPiOverclock retained failure ledger' ]] || return 1
    [[ $second_line == 'Generated: '* ]] || return 1
    timestamp=${second_line#Generated: }
    apo_history_generated_timestamp_is_valid "$timestamp" || return 1
    printf '%s' "$timestamp"
}

apo_history_render_ledger() {
    local destination=$1 generated_at=$2 record timestamp run_id cpu gpu class domain
    local encoded_source encoded_reason basename source reason

    {
        printf 'AutoPiOverclock retained failure ledger\n'
        printf 'Generated: %s\n' "$generated_at"
        printf 'Target: %s\n' "$APO_REMOTE_TARGET"
        printf 'Authority: validated .state files only; this ledger is derived output and never read as input.\n'
        printf 'Accepted retained auto-overclock states: %s\n' "$APO_HISTORY_ACCEPTED_STATES"
        printf 'Clear CPU failed boundary: %s\n' "${APO_HISTORY_CPU_FAILURE_BOUNDARY:-none}"
        printf 'Clear GPU failed boundary: %s\n' "${APO_HISTORY_GPU_FAILURE_BOUNDARY:-none}"
        printf 'Ambiguous failed-pair frontier: %s\n' "${APO_HISTORY_PAIR_FRONTIERS:-none}"
        printf '\nEvidence:\n'
        if (( ${#APO_HISTORY_LEDGER_RECORDS[@]} == 0 )); then
            printf '  none\n'
        else
            printf '  timestamp | run | cpu_mhz | gpu_mhz | class | domain | reason | source | state\n'
            for record in "${APO_HISTORY_LEDGER_RECORDS[@]}"; do
                IFS='|' read -r timestamp run_id cpu gpu class domain encoded_source encoded_reason basename <<< "$record"
                source=$(apo_history_decode_field "$encoded_source") || return 1
                reason=$(apo_history_decode_field "$encoded_reason") || return 1
                reason=${reason//$'\r'/ }
                reason=${reason//$'\n'/ }
                printf '  %s | %s | %s | %s | %s | %s | %s | %s | %s\n' \
                    "$timestamp" "$run_id" "$cpu" "$gpu" "$class" "$domain" "$reason" "$source" "$basename"
            done
        fi
    } > "$destination"
}

apo_history_rebuild_ledger() {
    local destination destination_dir temporary_file generated_at existing_generated_at candidate_generated_at compare_rc
    destination=${1:-"${APO_OUTPUT_DIR}/${APO_TARGET_SLUG}-failures.txt"}
    destination_dir=$(dirname -- "$destination")
    if [[ -e $destination_dir || -L $destination_dir ]]; then
        [[ -d $destination_dir && ! -L $destination_dir ]] || return 1
    else
        mkdir -p -- "$destination_dir" || return 1
        [[ -d $destination_dir && ! -L $destination_dir ]] || return 1
    fi
    if [[ -e $destination || -L $destination ]]; then
        [[ -f $destination && ! -L $destination && -r $destination ]] || return 1
    fi
    temporary_file=$(mktemp "${destination_dir}/.${APO_TARGET_SLUG}-failures.XXXXXX") || return 1
    chmod 600 "$temporary_file" || { rm -f -- "$temporary_file"; return 1; }
    if ! generated_at=$(apo_now_iso) || ! apo_history_generated_timestamp_is_valid "$generated_at"; then
        rm -f -- "$temporary_file"
        return 1
    fi
    candidate_generated_at=$generated_at
    if [[ -f $destination && ! -L $destination ]] &&
       existing_generated_at=$(apo_history_existing_ledger_timestamp "$destination"); then
        candidate_generated_at=$existing_generated_at
    fi
    if ! apo_history_render_ledger "$temporary_file" "$candidate_generated_at"; then
        rm -f -- "$temporary_file"
        return 1
    fi
    if [[ -f $destination && ! -L $destination ]]; then
        if cmp -s -- "$destination" "$temporary_file"; then
            rm -f -- "$temporary_file"
            APO_HISTORY_LEDGER_FILE=$destination
            return 0
        else
            compare_rc=$?
            if (( compare_rc != 1 )); then
                rm -f -- "$temporary_file"
                return 1
            fi
        fi
        if ! apo_history_render_ledger "$temporary_file" "$generated_at"; then
            rm -f -- "$temporary_file"
            return 1
        fi
    fi
    sync "$temporary_file" || { rm -f -- "$temporary_file"; return 1; }
    [[ -d $destination_dir && ! -L $destination_dir ]] || { rm -f -- "$temporary_file"; return 1; }
    if [[ -e $destination || -L $destination ]]; then
        [[ -f $destination && ! -L $destination && -r $destination ]] || { rm -f -- "$temporary_file"; return 1; }
    fi
    mv -fT -- "$temporary_file" "$destination" || { rm -f -- "$temporary_file"; return 1; }
    sync "$destination" || return 1
    sync "$destination_dir" || return 1
    APO_HISTORY_LEDGER_FILE=$destination
}

apo_history_refresh() {
    apo_history_scan_retained_states || return 1
    apo_history_rebuild_ledger
}

apo_history_clear_plan_state() {
    APO_HISTORY_CPU_APPROACH_START=''
    APO_HISTORY_GPU_APPROACH_START=''
    APO_HISTORY_CPU_REVERSE_SEARCH=0
    APO_HISTORY_GPU_REVERSE_SEARCH=0
    APO_HISTORY_CPU_RETAINED_CAP=''
    APO_HISTORY_GPU_RETAINED_CAP=''
    APO_HISTORY_CPU_EXPLICIT_MAX_OVERRIDE=0
    APO_HISTORY_GPU_EXPLICIT_MAX_OVERRIDE=0
    APO_HISTORY_PLAN_WARNING=''
    apo_state_set HISTORY_CPU_FAILURE_BOUNDARY ''
    apo_state_set HISTORY_GPU_FAILURE_BOUNDARY ''
    apo_state_set HISTORY_PAIR_FRONTIERS ''
    apo_state_set HISTORY_PROVENANCE ''
    apo_state_set HISTORY_LEDGER_FILE ''
    apo_state_set HISTORY_SCANNED_STATES 0
    apo_state_set HISTORY_ACCEPTED_STATES 0
    apo_state_set HISTORY_EVIDENCE_COUNT 0
    apo_state_set HISTORY_CPU_APPROACH_START ''
    apo_state_set HISTORY_GPU_APPROACH_START ''
    apo_state_set HISTORY_CPU_REVERSE_SEARCH 0
    apo_state_set HISTORY_GPU_REVERSE_SEARCH 0
    apo_state_set HISTORY_CPU_RETAINED_CAP ''
    apo_state_set HISTORY_GPU_RETAINED_CAP ''
    apo_state_set HISTORY_CPU_EXPLICIT_MAX_OVERRIDE 0
    apo_state_set HISTORY_GPU_EXPLICIT_MAX_OVERRIDE 0
    apo_state_set HISTORY_PLAN_WARNING ''
    apo_state_set HISTORY_ISOLATION_STAGE NONE
    apo_state_set HISTORY_ISOLATION_ANCHOR_CPU ''
    apo_state_set HISTORY_ISOLATION_ANCHOR_GPU ''
    apo_state_set HISTORY_CPU_TRIAL_CPU ''
    apo_state_set HISTORY_CPU_TRIAL_GPU ''
    apo_state_set HISTORY_GPU_TRIAL_CPU ''
    apo_state_set HISTORY_GPU_TRIAL_GPU ''
    apo_state_set HISTORY_PAIR_TRIAL_CPU ''
    apo_state_set HISTORY_PAIR_TRIAL_GPU ''
    apo_state_set HISTORY_BASE_CPU_QUALIFIED_CLOCK ''
    apo_state_set HISTORY_CPU_TRIAL_QUALIFIED_CLOCK ''
    apo_state_set HISTORY_ISOLATION_HANDOFF_CPU ''
    apo_state_set HISTORY_ISOLATION_HANDOFF_GPU ''
}

apo_history_snapshot_scan_state() {
    apo_state_set HISTORY_CPU_FAILURE_BOUNDARY "$APO_HISTORY_CPU_FAILURE_BOUNDARY"
    apo_state_set HISTORY_GPU_FAILURE_BOUNDARY "$APO_HISTORY_GPU_FAILURE_BOUNDARY"
    apo_state_set HISTORY_PAIR_FRONTIERS "$APO_HISTORY_PAIR_FRONTIERS"
    apo_state_set HISTORY_PROVENANCE "$APO_HISTORY_PROVENANCE"
    apo_state_set HISTORY_LEDGER_FILE "$APO_HISTORY_LEDGER_FILE"
    apo_state_set HISTORY_SCANNED_STATES "$APO_HISTORY_SCANNED_STATES"
    apo_state_set HISTORY_ACCEPTED_STATES "$APO_HISTORY_ACCEPTED_STATES"
    apo_state_set HISTORY_EVIDENCE_COUNT "$APO_HISTORY_EVIDENCE_COUNT"
}

apo_history_set_validation_error() {
    APO_HISTORY_VALIDATION_REASON=$1
    APO_HISTORY_SCAN_ERROR=${APO_HISTORY_SCAN_ERROR:-$1}
    return 1
}

apo_history_announce_resolved_plan() {
    local use_history=$1 requested_cpu requested_gpu cpu_cap gpu_cap cpu_boundary gpu_boundary pair_frontier line
    local requested_cpu_display requested_gpu_display cpu_cap_display gpu_cap_display
    local cpu_start_display gpu_start_display cpu_floor gpu_floor cpu_direction gpu_direction
    local cpu_resolution gpu_resolution cpu_coarse gpu_coarse warning
    (( APO_HISTORY_PLAN_ANNOUNCED == 0 )) || return 0
    case ${APO_SWEEP_DOMAIN:-all} in
        all)
            requested_cpu=${APO_CPU_MAX_REQUESTED:-${APO_AUTO_CPU_MAX_MHZ:-unset}}
            requested_gpu=${APO_GPU_MAX_REQUESTED:-${APO_AUTO_GPU_MAX_MHZ:-unset}}
            ;;
        cpu)
            requested_cpu=${APO_CPU_MAX_REQUESTED:-${APO_AUTO_CPU_MAX_MHZ:-unset}}
            requested_gpu=not-swept
            ;;
        gpu)
            requested_cpu=not-swept
            requested_gpu=${APO_GPU_MAX_REQUESTED:-${APO_AUTO_GPU_MAX_MHZ:-unset}}
            ;;
        *)
            requested_cpu='unset'
            requested_gpu='unset'
            ;;
    esac
    cpu_cap=${APO_CPU_MAX:-not-swept}
    gpu_cap=${APO_GPU_MAX:-not-swept}
    if [[ $requested_cpu == not-swept ]]; then requested_cpu_display='not swept'; else requested_cpu_display="${requested_cpu} MHz"; fi
    if [[ $requested_gpu == not-swept ]]; then requested_gpu_display='not swept'; else requested_gpu_display="${requested_gpu} MHz"; fi
    if [[ $cpu_cap == not-swept ]]; then cpu_cap_display='not swept'; else cpu_cap_display="${cpu_cap} MHz"; fi
    if [[ $gpu_cap == not-swept ]]; then gpu_cap_display='not swept'; else gpu_cap_display="${gpu_cap} MHz"; fi
    cpu_boundary=${APO_HISTORY_CPU_FAILURE_BOUNDARY:-none}
    gpu_boundary=${APO_HISTORY_GPU_FAILURE_BOUNDARY:-none}
    pair_frontier=${APO_HISTORY_PAIR_FRONTIERS:-none}
    cpu_resolution=$(apo_history_domain_resolution_mhz CPU) || return 1
    gpu_resolution=$(apo_history_domain_resolution_mhz GPU) || return 1
    cpu_coarse=${APO_AUTO_CPU_STEP_MHZ:-100}
    gpu_coarse=${APO_AUTO_GPU_STEP_MHZ:-50}
    (( cpu_resolution > cpu_coarse )) && cpu_coarse=$cpu_resolution
    (( gpu_resolution > gpu_coarse )) && gpu_coarse=$gpu_resolution
    cpu_direction=${APO_CPU_SEARCH_DIRECTION:-forward}
    gpu_direction=${APO_GPU_SEARCH_DIRECTION:-forward}
    cpu_floor=${APO_CPU_MIN:-${APO_NORMAL_CPU:-automatic baseline}}
    gpu_floor=${APO_GPU_MIN:-${APO_NORMAL_GPU:-automatic baseline}}
    if [[ ${APO_SWEEP_DOMAIN:-all} == gpu ]]; then
        cpu_start_display='not swept'
    else
        if [[ $cpu_direction == descending ]]; then
            cpu_start_display="${APO_HISTORY_CPU_APPROACH_START:-$cpu_cap} MHz exact ceiling first"
        else
            cpu_start_display='forward baseline ladder'
        fi
    fi
    if [[ ${APO_SWEEP_DOMAIN:-all} == cpu ]]; then
        gpu_start_display='not swept'
    else
        if [[ $gpu_direction == descending ]]; then
            gpu_start_display="${APO_HISTORY_GPU_APPROACH_START:-$gpu_cap} MHz exact ceiling first"
        else
            gpu_start_display='forward baseline ladder'
        fi
    fi
    if (( use_history == 1 )); then
        line="History ceilings: CPU=${cpu_cap_display} (requested ${requested_cpu_display}); GPU=${gpu_cap_display} (requested ${requested_gpu_display}). Retained failures: clear CPU=${cpu_boundary}, clear GPU=${gpu_boundary}, ambiguous pairs=${pair_frontier}; accepted states=${APO_HISTORY_ACCEPTED_STATES}; ledger=${APO_HISTORY_LEDGER_FILE:-unavailable}"
    else
        line="History disabled for this new run. Ceilings: CPU=${cpu_cap_display} (requested ${requested_cpu_display}); GPU=${gpu_cap_display} (requested ${requested_gpu_display})."
    fi
    if declare -F apo_info >/dev/null 2>&1; then
        apo_info "$line"
    else
        printf '%s\n' "$line"
    fi
    if declare -F apo_summary_line >/dev/null 2>&1; then
        apo_summary_line "$line"
    fi
    if [[ ${APO_SWEEP_DOMAIN:-all} != gpu ]]; then
        line="CPU search: ${cpu_direction}; start=${cpu_start_display}; floor=${cpu_floor} MHz; coarse step=${cpu_coarse} MHz; final resolution=${cpu_resolution} MHz."
        if declare -F apo_info >/dev/null 2>&1; then apo_info "$line"; else printf '%s\n' "$line"; fi
        if declare -F apo_summary_line >/dev/null 2>&1; then apo_summary_line "$line"; fi
    fi
    if [[ ${APO_SWEEP_DOMAIN:-all} != cpu ]]; then
        line="GPU search: ${gpu_direction}; start=${gpu_start_display}; floor=${gpu_floor} MHz; coarse step=${gpu_coarse} MHz; final resolution=${gpu_resolution} MHz."
        if declare -F apo_info >/dev/null 2>&1; then apo_info "$line"; else printf '%s\n' "$line"; fi
        if declare -F apo_summary_line >/dev/null 2>&1; then apo_summary_line "$line"; fi
    fi
    line="Final validation: every accepted pair must complete the full ${APO_FINAL_DURATION_S:-unknown}s duration; any clock backoff restarts that timer from zero."
    if declare -F apo_info >/dev/null 2>&1; then apo_info "$line"; else printf '%s\n' "$line"; fi
    if declare -F apo_summary_line >/dev/null 2>&1; then apo_summary_line "$line"; fi
    warning=${APO_HISTORY_PLAN_WARNING:-}
    if [[ -n $warning ]]; then
        if declare -F apo_warn >/dev/null 2>&1; then apo_warn "$warning"; else printf 'WARNING: %s\n' "$warning"; fi
        if declare -F apo_summary_line >/dev/null 2>&1; then apo_summary_line "WARNING: $warning"; fi
    fi
    APO_HISTORY_PLAN_ANNOUNCED=1
}

# Resolve a fresh public automatic run once, before candidate ladders are
# generated. Requested caps remain separately available while APO_CPU_MAX and
# APO_GPU_MAX become the effective starting ceilings. Retained caps constrain
# defaults; an explicit CLI maximum remains authoritative and emits metadata
# that lets the public caller warn before reverse search begins.
apo_history_resolve_new_overclock_plan() {
    local domain=${APO_SWEEP_DOMAIN:-all} use_history=${APO_USE_HISTORY:-1}
    local requested_cpu requested_gpu effective_cpu effective_gpu pair failed_cpu failed_gpu extra cap
    local cpu_trial gpu_trial pair_cpu pair_gpu cpu_resolution gpu_resolution
    local -a frontiers=()

    [[ ${APO_ORIGIN_COMMAND:-${APO_PUBLIC_COMMAND:-}} == overclock && ${APO_COMMAND:-} == run && ${APO_AUTO_GENERATED_CANDIDATES:-0} == 1 ]] || return 0
    [[ $use_history == 0 || $use_history == 1 ]] || {
        apo_history_set_validation_error 'The retained-history policy must be 0 or 1.'
        return 1
    }
    if [[ -v APO_CPU_MAX_REQUESTED ]]; then
        requested_cpu=$APO_CPU_MAX_REQUESTED
    else
        requested_cpu=${APO_CPU_MAX:-}
    fi
    if [[ -v APO_GPU_MAX_REQUESTED ]]; then
        requested_gpu=$APO_GPU_MAX_REQUESTED
    else
        requested_gpu=${APO_GPU_MAX:-}
    fi
    APO_CPU_MAX_REQUESTED=$requested_cpu
    APO_GPU_MAX_REQUESTED=$requested_gpu
    apo_state_set CFG_CPU_MAX_REQUESTED "$requested_cpu"
    apo_state_set CFG_GPU_MAX_REQUESTED "$requested_gpu"
    apo_state_set CFG_USE_HISTORY "$use_history"
    apo_history_clear_plan_state

    case $domain in
        all)
            effective_cpu=${requested_cpu:-$APO_AUTO_CPU_MAX_MHZ}
            effective_gpu=${requested_gpu:-$APO_AUTO_GPU_MAX_MHZ}
            ;;
        cpu)
            effective_cpu=${requested_cpu:-$APO_AUTO_CPU_MAX_MHZ}
            effective_gpu=''
            ;;
        gpu)
            effective_cpu=''
            effective_gpu=${requested_gpu:-$APO_AUTO_GPU_MAX_MHZ}
            ;;
        *) apo_history_set_validation_error "Unknown automatic sweep domain: $domain"; return 1 ;;
    esac
    [[ -z $effective_cpu ]] || apo_is_uint "$effective_cpu" || {
        apo_history_set_validation_error 'The requested CPU maximum is malformed.'
        return 1
    }
    [[ -z $effective_gpu ]] || apo_is_uint "$effective_gpu" || {
        apo_history_set_validation_error 'The requested GPU maximum is malformed.'
        return 1
    }
    if [[ $domain != gpu && -n ${APO_CPU_MIN:-} ]] && (( APO_CPU_MIN <= APO_NORMAL_CPU )); then
        apo_history_set_validation_error "--cpu-min must be above the protected current CPU clock (${APO_NORMAL_CPU} MHz)."
        return 1
    fi
    if [[ $domain != cpu && -n ${APO_GPU_MIN:-} ]] && (( APO_GPU_MIN <= APO_NORMAL_GPU )); then
        apo_history_set_validation_error "--gpu-min must be above the protected current GPU/V3D clock (${APO_NORMAL_GPU} MHz)."
        return 1
    fi

    if (( use_history == 0 )); then
        if (( ${APO_CPU_MIN_OPTION_SEEN:-0} == 0 )); then APO_CPU_MIN=''; fi
        if (( ${APO_GPU_MIN_OPTION_SEEN:-0} == 0 )); then APO_GPU_MIN=''; fi
        APO_CPU_MAX=$effective_cpu
        APO_GPU_MAX=$effective_gpu
        (( ${APO_CPU_MAX_OPTION_SEEN:-0} == 0 )) || APO_CPU_SEARCH_DIRECTION=descending
        (( ${APO_GPU_MAX_OPTION_SEEN:-0} == 0 )) || APO_GPU_SEARCH_DIRECTION=descending
        apo_state_set CFG_CPU_MIN_SOURCE "$([[ ${APO_CPU_MIN_OPTION_SEEN:-0} == 1 ]] && printf cli || printf automatic-baseline)"
        apo_state_set CFG_GPU_MIN_SOURCE "$([[ ${APO_GPU_MIN_OPTION_SEEN:-0} == 1 ]] && printf cli || printf automatic-baseline)"
        apo_state_set CFG_CPU_MAX_EFFECTIVE "$effective_cpu"
        apo_state_set CFG_GPU_MAX_EFFECTIVE "$effective_gpu"
        apo_history_announce_resolved_plan 0
        return 0
    fi

    apo_history_refresh || return 1
    apo_history_snapshot_scan_state
    apo_history_resolve_scalar_caps "$effective_cpu" "$effective_gpu" || {
        apo_history_set_validation_error 'A retained clear failure boundary cannot produce a safe exclusive ceiling.'
        return 1
    }
    effective_cpu=$APO_HISTORY_EFFECTIVE_CPU_MAX
    effective_gpu=$APO_HISTORY_EFFECTIVE_GPU_MAX
    cpu_resolution=$(apo_history_domain_resolution_mhz CPU) || {
        apo_history_set_validation_error 'The CPU resolution is malformed.'
        return 1
    }
    gpu_resolution=$(apo_history_domain_resolution_mhz GPU) || {
        apo_history_set_validation_error 'The GPU resolution is malformed.'
        return 1
    }

    if [[ $domain == cpu && -n $APO_HISTORY_PAIR_FRONTIERS ]]; then
        IFS=',' read -r -a frontiers <<< "$APO_HISTORY_PAIR_FRONTIERS"
        for pair in "${frontiers[@]}"; do
            IFS='/' read -r failed_cpu failed_gpu extra <<< "$pair"
            [[ -z $extra ]] || {
                apo_history_set_validation_error 'A retained ambiguous pair frontier is malformed.'
                return 1
            }
            if (( APO_NORMAL_GPU >= failed_gpu )); then
                cap=$(apo_history_failure_exclusive_cap CPU "$failed_cpu" "$cpu_resolution") || return 1
                if (( cap >= failed_cpu && ${APO_CPU_MAX_OPTION_SEEN:-0} == 0 )); then
                    apo_history_set_validation_error 'A retained CPU failure is at or below the requested hard minimum, so no safe exclusive CPU ceiling exists.'
                    return 1
                fi
                if [[ -z $APO_HISTORY_CPU_RETAINED_CAP ]] || (( cap < APO_HISTORY_CPU_RETAINED_CAP )); then
                    APO_HISTORY_CPU_RETAINED_CAP=$cap
                fi
                if (( ${APO_CPU_MAX_OPTION_SEEN:-0} == 0 && cap < effective_cpu )); then
                    effective_cpu=$cap
                fi
            fi
        done
    elif [[ $domain == gpu && -n $APO_HISTORY_PAIR_FRONTIERS ]]; then
        IFS=',' read -r -a frontiers <<< "$APO_HISTORY_PAIR_FRONTIERS"
        for pair in "${frontiers[@]}"; do
            IFS='/' read -r failed_cpu failed_gpu extra <<< "$pair"
            [[ -z $extra ]] || {
                apo_history_set_validation_error 'A retained ambiguous pair frontier is malformed.'
                return 1
            }
            if (( APO_NORMAL_CPU >= failed_cpu )); then
                cap=$(apo_history_failure_exclusive_cap GPU "$failed_gpu" "$gpu_resolution") || return 1
                if (( cap >= failed_gpu && ${APO_GPU_MAX_OPTION_SEEN:-0} == 0 )); then
                    apo_history_set_validation_error 'A retained GPU failure is at or below the requested hard minimum, so no safe exclusive GPU ceiling exists.'
                    return 1
                fi
                if [[ -z $APO_HISTORY_GPU_RETAINED_CAP ]] || (( cap < APO_HISTORY_GPU_RETAINED_CAP )); then
                    APO_HISTORY_GPU_RETAINED_CAP=$cap
                fi
                if (( ${APO_GPU_MAX_OPTION_SEEN:-0} == 0 && cap < effective_gpu )); then
                    effective_gpu=$cap
                fi
            fi
        done
    fi

    apo_history_finalize_ceiling_warnings "$effective_cpu" "$effective_gpu" || {
        apo_history_set_validation_error 'Could not resolve retained-history ceiling warnings.'
        return 1
    }
    apo_state_set HISTORY_CPU_RETAINED_CAP "$APO_HISTORY_CPU_RETAINED_CAP"
    apo_state_set HISTORY_GPU_RETAINED_CAP "$APO_HISTORY_GPU_RETAINED_CAP"
    apo_state_set HISTORY_CPU_EXPLICIT_MAX_OVERRIDE "$APO_HISTORY_CPU_EXPLICIT_MAX_OVERRIDE"
    apo_state_set HISTORY_GPU_EXPLICIT_MAX_OVERRIDE "$APO_HISTORY_GPU_EXPLICIT_MAX_OVERRIDE"
    apo_state_set HISTORY_PLAN_WARNING "$APO_HISTORY_PLAN_WARNING"

    [[ -z ${APO_CPU_MIN:-} || -z $effective_cpu || ${APO_CPU_MIN} -le $effective_cpu ]] || {
        apo_history_set_validation_error "--cpu-min exceeds the retained-history CPU ceiling (${effective_cpu} MHz); use a lower minimum or explicitly pass --no-history."
        return 1
    }
    [[ -z ${APO_GPU_MIN:-} || -z $effective_gpu || ${APO_GPU_MIN} -le $effective_gpu ]] || {
        apo_history_set_validation_error "--gpu-min exceeds the retained-history GPU ceiling (${effective_gpu} MHz); use a lower minimum or explicitly pass --no-history."
        return 1
    }

    APO_CPU_MAX=$effective_cpu
    APO_GPU_MAX=$effective_gpu
    apo_state_set CFG_CPU_MAX_EFFECTIVE "$effective_cpu"
    apo_state_set CFG_GPU_MAX_EFFECTIVE "$effective_gpu"

    # Full-domain runs preserve an ambiguous pair as a pair constraint.  Only
    # when the requested/effective anchor enters its northeast quadrant do we
    # schedule CPU-only, GPU-only, then both-lowered isolation branches.
    if [[ $domain == all && -n $APO_HISTORY_PAIR_FRONTIERS ]] &&
        apo_history_pair_is_forbidden "$effective_cpu" "$effective_gpu"; then
        cpu_trial=$effective_cpu
        gpu_trial=$effective_gpu
        IFS=',' read -r -a frontiers <<< "$APO_HISTORY_PAIR_FRONTIERS"
        for pair in "${frontiers[@]}"; do
            IFS='/' read -r failed_cpu failed_gpu extra <<< "$pair"
            [[ -z $extra ]] || {
                apo_history_set_validation_error 'A retained ambiguous pair frontier is malformed.'
                return 1
            }
            if (( effective_gpu >= failed_gpu )); then
                cap=$(apo_history_failure_exclusive_cap CPU "$failed_cpu" "$cpu_resolution") || return 1
                (( cap < cpu_trial )) && cpu_trial=$cap
            fi
            if (( effective_cpu >= failed_cpu )); then
                cap=$(apo_history_failure_exclusive_cap GPU "$failed_gpu" "$gpu_resolution") || return 1
                (( cap < gpu_trial )) && gpu_trial=$cap
            fi
        done
        pair_cpu=$cpu_trial
        pair_gpu=$gpu_trial
        [[ -z ${APO_CPU_MIN:-} || $cpu_trial -ge ${APO_CPU_MIN} ]] || {
            apo_history_set_validation_error "Retained ambiguous-pair isolation requires CPU=${cpu_trial} MHz below --cpu-min; lower the minimum or explicitly pass --no-history."
            return 1
        }
        [[ -z ${APO_GPU_MIN:-} || $gpu_trial -ge ${APO_GPU_MIN} ]] || {
            apo_history_set_validation_error "Retained ambiguous-pair isolation requires GPU=${gpu_trial} MHz below --gpu-min; lower the minimum or explicitly pass --no-history."
            return 1
        }
        for pair in "$cpu_trial/$effective_gpu" "$effective_cpu/$gpu_trial" "$pair_cpu/$pair_gpu"; do
            IFS='/' read -r failed_cpu failed_gpu <<< "$pair"
            if apo_history_pair_is_forbidden "$failed_cpu" "$failed_gpu"; then
                apo_history_set_validation_error 'Could not derive an isolation trial outside every retained ambiguous failed-pair frontier.'
                return 1
            else
                case $? in
                    1) ;;
                    *)
                        apo_history_set_validation_error 'A retained ambiguous pair frontier is malformed.'
                        return 1
                        ;;
                esac
            fi
        done
        apo_state_set HISTORY_ISOLATION_STAGE PLANNED
        apo_state_set HISTORY_ISOLATION_ANCHOR_CPU "$effective_cpu"
        apo_state_set HISTORY_ISOLATION_ANCHOR_GPU "$effective_gpu"
        apo_state_set HISTORY_CPU_TRIAL_CPU "$cpu_trial"
        apo_state_set HISTORY_CPU_TRIAL_GPU "$effective_gpu"
        apo_state_set HISTORY_GPU_TRIAL_CPU "$effective_cpu"
        apo_state_set HISTORY_GPU_TRIAL_GPU "$gpu_trial"
        apo_state_set HISTORY_PAIR_TRIAL_CPU "$pair_cpu"
        apo_state_set HISTORY_PAIR_TRIAL_GPU "$pair_gpu"
        apo_history_validate_plan_state || return 1
    fi
    apo_history_apply_approach_starts "$domain" "$effective_cpu" "$effective_gpu" || {
        apo_history_set_validation_error 'Could not derive safe retained-history candidate starting points.'
        return 1
    }
    (( APO_HISTORY_CPU_REVERSE_SEARCH == 0 )) || APO_CPU_SEARCH_DIRECTION=descending
    (( APO_HISTORY_GPU_REVERSE_SEARCH == 0 )) || APO_GPU_SEARCH_DIRECTION=descending
    apo_history_announce_resolved_plan 1
}
