#!/usr/bin/env bash
# TTY-only whole-workflow progress. Estimates deliberately re-plan as boundaries
# and refinement work become known; retained artifacts always keep raw telemetry.

readonly APO_PROGRESS_BOOT_ESTIMATE_S=60
readonly APO_PROGRESS_PREPARE_ESTIMATE_S=180
readonly APO_PROGRESS_APPLY_ESTIMATE_S=120
readonly APO_PROGRESS_BAR_WIDTH=20
readonly APO_PROGRESS_WIDE_MIN_COLUMNS=260
readonly APO_PROGRESS_RIGHT_MARGIN=8

APO_PROGRESS_SESSION_EPOCH=0
APO_PROGRESS_SESSION_BASE_S=0
APO_PROGRESS_LINE_ACTIVE=0
APO_PROGRESS_LINE_WIDTH=0
APO_PROGRESS_SHUTTING_DOWN=0
APO_PROGRESS_LAST_TEMP=''
APO_PROGRESS_LAST_CPU=''
APO_PROGRESS_LAST_GPU=''
APO_PROGRESS_LAST_THROTTLE=''
APO_PROGRESS_LAST_FAN=''
APO_PROGRESS_RUN_MAX_TEMP=''
APO_PROGRESS_STRESS_ELAPSED=0
APO_PROGRESS_STRESS_DURATION=0

apo_progress_available() {
    (( ${APO_PROGRESS_SHUTTING_DOWN:-0} == 0 )) || return 1
    case ${APO_COMMAND:-} in run|resume|post-floor-edge) ;; *) return 1 ;; esac
    [[ ${APO_PROGRESS_FORCE:-0} == 1 ]] && return 0
    [[ -t 1 && -t 2 && ${TERM:-dumb} != dumb ]]
}

apo_progress_now_epoch() { date +%s; }

apo_progress_start_session() {
    APO_PROGRESS_SHUTTING_DOWN=0
    case ${APO_COMMAND:-} in
        run|resume|post-floor-edge) ;;
        *) APO_PROGRESS_SESSION_BASE_S=0; APO_PROGRESS_SESSION_EPOCH=0; return 0 ;;
    esac
    APO_PROGRESS_SESSION_BASE_S=$(apo_state_get PROGRESS_ACTIVE_SECONDS 0)
    [[ $APO_PROGRESS_SESSION_BASE_S =~ ^[0-9]+$ ]] || APO_PROGRESS_SESSION_BASE_S=0
    APO_PROGRESS_RUN_MAX_TEMP=$(apo_state_get RUN_MAX_TEMP '')
    APO_PROGRESS_SESSION_EPOCH=$(apo_progress_now_epoch)
}

apo_progress_active_seconds() {
    local now
    if (( APO_PROGRESS_SESSION_EPOCH <= 0 )); then
        printf '%s' "${APO_PROGRESS_SESSION_BASE_S:-0}"
        return
    fi
    now=$(apo_progress_now_epoch)
    printf '%s' "$((APO_PROGRESS_SESSION_BASE_S + now - APO_PROGRESS_SESSION_EPOCH))"
}

apo_progress_checkpoint_state() {
    (( APO_PROGRESS_SESSION_EPOCH > 0 )) || return 0
    [[ -n ${APO_STATE_FILE:-} ]] || return 0
    apo_state_set PROGRESS_ACTIVE_SECONDS "$(apo_progress_active_seconds)"
}

apo_progress_format_duration() {
    local total=${1:-0} days hours minutes seconds
    [[ $total =~ ^[0-9]+$ ]] || total=0
    days=$((total / 86400))
    hours=$(((total % 86400) / 3600))
    minutes=$(((total % 3600) / 60))
    seconds=$((total % 60))
    if (( days > 0 )); then printf '%dd%02dh%02dm' "$days" "$hours" "$minutes"
    elif (( hours > 0 )); then printf '%dh%02dm' "$hours" "$minutes"
    elif (( minutes > 0 )); then printf '%dm%02ds' "$minutes" "$seconds"
    else printf '%ds' "$seconds"; fi
}

apo_progress_csv_count() {
    local value=${1:-} item count=0
    local -a values=()
    [[ -n $value ]] || { printf 0; return; }
    IFS=',' read -r -a values <<< "$value"
    for item in "${values[@]}"; do [[ -n $item ]] && count=$((count + 1)); done
    printf '%s' "$count"
}

apo_progress_candidate_cost() {
    local duration=${APO_CFG[CANDIDATE_DURATION_S]:-600} boots=${APO_CFG[CANDIDATE_BOOTS]:-2}
    printf '%s' "$((duration + ((boots * 2 + 2) * APO_PROGRESS_BOOT_ESTIMATE_S)))"
}

apo_progress_qualification_cost() {
    local boots=${APO_CFG[CANDIDATE_BOOTS]:-2}
    printf '%s' "$((${APO_QUALIFICATION_DURATION_S:-$APO_DEFAULT_QUALIFICATION_DURATION_S} + (boots * 2 + 2) * APO_PROGRESS_BOOT_ESTIMATE_S))"
}

apo_progress_domain_remaining_count() {
    local domain=$1 phase=${2:-} index boundary refine_csv refine_index refine_complete guard_verified coarse_count remaining=0
    local candidates_name
    case $domain in
        CPU)
            candidates_name=APO_CPU_CANDIDATES
            index=$(apo_state_get CPU_INDEX 0)
            boundary=$(apo_state_get CPU_FAILURE_BOUNDARY '')
            refine_csv=$(apo_state_get CPU_REFINE_CANDIDATES '')
            refine_index=$(apo_state_get CPU_REFINE_INDEX 0)
            refine_complete=$(apo_state_get CPU_REFINE_COMPLETE 0)
            guard_verified=$(apo_state_get CPU_GUARD_VERIFIED 0)
            ;;
        GPU)
            candidates_name=APO_GPU_CANDIDATES
            index=$(apo_state_get GPU_INDEX 0)
            boundary=$(apo_state_get GPU_FAILURE_BOUNDARY '')
            refine_csv=$(apo_state_get GPU_REFINE_CANDIDATES '')
            refine_index=$(apo_state_get GPU_REFINE_INDEX 0)
            refine_complete=$(apo_state_get GPU_REFINE_COMPLETE 0)
            guard_verified=$(apo_state_get GPU_GUARD_VERIFIED 0)
            ;;
        *) printf 0; return ;;
    esac
    local -n candidates=$candidates_name
    [[ $index =~ ^[0-9]+$ ]] || index=0
    coarse_count=${#candidates[@]}
    if (( coarse_count == 0 && ${APO_AUTO_GENERATED_CANDIDATES:-0} == 1 )) && [[ $phase == BEFORE ]]; then
        case $domain in
            CPU) coarse_count=$(((APO_AUTO_CPU_MAX_MHZ - 2500) / APO_AUTO_CPU_STEP_MHZ + 1)) ;;
            GPU) coarse_count=$(((APO_AUTO_GPU_MAX_MHZ - 850) / APO_AUTO_GPU_STEP_MHZ + 1)) ;;
        esac
    fi
    if [[ -z $boundary ]] && (( index < coarse_count )); then remaining=$((remaining + coarse_count - index)); fi
    if (( ${APO_AUTO_GENERATED_CANDIDATES:-0} == 1 )); then
        if [[ $refine_complete != 1 ]]; then
            if [[ -n $refine_csv ]]; then
                coarse_count=$(apo_progress_csv_count "$refine_csv")
                [[ $refine_index =~ ^[0-9]+$ ]] || refine_index=0
                (( refine_index < coarse_count )) && remaining=$((remaining + coarse_count - refine_index))
            elif [[ -n $boundary ]]; then
                # A 100 MHz coarse gap can introduce at most three 25 MHz tests.
                remaining=$((remaining + 3))
            elif [[ $phase == BEFORE || $phase == CURRENT ]]; then
                # Until the sweep proves its ceiling or boundary, reserve the
                # maximum possible refinement work and remove it dynamically.
                remaining=$((remaining + 3))
            fi
        fi
        [[ $guard_verified == 1 ]] || remaining=$((remaining + 1))
    fi
    printf '%s' "$remaining"
}

apo_progress_final_full_cost() {
    local endurance=$1 final_boots=${APO_CFG[FINAL_BOOTS]:-3}
    printf '%s' "$((endurance + (final_boots * 2 + 2) * APO_PROGRESS_BOOT_ESTIMATE_S))"
}

apo_progress_final_remaining() {
    local elapsed=${1:-0} stage edge_status endurance final_boots remaining=0 boot_number normal_number
    final_boots=${APO_CFG[FINAL_BOOTS]:-3}
    stage=$(apo_state_get FINAL_STAGE PRE_STRESS_BOOT)
    edge_status=$(apo_state_get EDGE_CPU_STATUS NOT_REQUESTED)
    endurance=${APO_CFG[FINAL_DURATION_S]:-$APO_DEFAULT_FINAL_DURATION_S}
    [[ $edge_status == RUNNING ]] && endurance=${APO_EDGE_DURATION_S:-$APO_DEFAULT_EDGE_DURATION_S}
    case $stage in
        ''|PRE_STRESS_BOOT)
            remaining=$(apo_progress_final_full_cost "$endurance")
            ;;
        ENDURANCE)
            remaining=$((endurance - elapsed + (final_boots * 2 + 1) * APO_PROGRESS_BOOT_ESTIMATE_S))
            ;;
        RETURN_NORMAL)
            remaining=$(((final_boots * 2 + 1) * APO_PROGRESS_BOOT_ESTIMATE_S))
            ;;
        BOOT_*)
            if [[ $stage =~ ^BOOT_([1-9][0-9]*)$ ]]; then
                boot_number=$((10#${BASH_REMATCH[1]}))
                remaining=$(((final_boots - boot_number + 1) * 2 * APO_PROGRESS_BOOT_ESTIMATE_S))
            fi
            ;;
        NORMAL_*)
            if [[ $stage =~ ^NORMAL_([1-9][0-9]*)$ ]]; then
                normal_number=$((10#${BASH_REMATCH[1]}))
                remaining=$((APO_PROGRESS_BOOT_ESTIMATE_S + (final_boots - normal_number) * 2 * APO_PROGRESS_BOOT_ESTIMATE_S))
            fi
            ;;
        VERIFY) remaining=$APO_PROGRESS_BOOT_ESTIMATE_S ;;
        COMPLETE) remaining=0 ;;
        *) remaining=$(apo_progress_final_full_cost "$endurance") ;;
    esac
    (( remaining < 0 )) && remaining=0
    if [[ $edge_status == NOT_REQUESTED && ${APO_EDGE_CPU_24H:-0} == 1 ]]; then
        remaining=$((remaining + $(apo_progress_final_full_cost "${APO_EDGE_DURATION_S:-$APO_DEFAULT_EDGE_DURATION_S}")))
    fi
    printf '%s' "$remaining"
}

apo_progress_future_validation_tests() {
    local tests=1
    (( ${APO_EDGE_CPU_24H:-0} == 1 )) && tests=$((tests + 1))
    printf '%s' "$tests"
}

apo_progress_estimate_remaining_tests() {
    local phase subphase count=0 edge_status
    phase=$(apo_state_get PHASE PREPARE)
    subphase=$(apo_state_get SUBPHASE '')
    case $phase in
        PREPARE|PREPARED|TRYBOOT_PROOF)
            if (( ${APO_MANUAL_TEST:-0} == 1 )); then count=2
            else
                count=$(apo_progress_domain_remaining_count CPU BEFORE)
                (( ${APO_AUTO_GENERATED_CANDIDATES:-0} == 1 )) && count=$((count + 1))
                if (( ${APO_NEED_GPU:-0} == 1 || ${APO_AUTO_GENERATED_CANDIDATES:-0} == 1 )); then count=$((count + $(apo_progress_domain_remaining_count GPU BEFORE))); fi
                (( ${APO_AUTO_GENERATED_CANDIDATES:-0} == 1 && ( ${APO_NEED_GPU:-0} == 1 || ${APO_AUTO_GENERATED_CANDIDATES:-0} == 1 ) )) && count=$((count + 1))
                count=$((count + $(apo_progress_future_validation_tests)))
            fi
            ;;
        GPU_SMOKE)
            count=1
            if (( ${APO_MANUAL_TEST:-0} == 1 )); then count=$((count + 1))
            else
                count=$((count + $(apo_progress_domain_remaining_count CPU BEFORE)))
                (( ${APO_AUTO_GENERATED_CANDIDATES:-0} == 1 )) && count=$((count + 1))
                if (( ${APO_NEED_GPU:-0} == 1 )); then count=$((count + $(apo_progress_domain_remaining_count GPU BEFORE))); fi
                (( ${APO_AUTO_GENERATED_CANDIDATES:-0} == 1 && ${APO_NEED_GPU:-0} == 1 )) && count=$((count + 1))
                count=$((count + $(apo_progress_future_validation_tests)))
            fi
            ;;
        CPU_SWEEP)
            count=$(apo_progress_domain_remaining_count CPU CURRENT)
            (( ${APO_AUTO_GENERATED_CANDIDATES:-0} == 1 )) && count=$((count + 1))
            if (( ${APO_NEED_GPU:-0} == 1 )); then count=$((count + $(apo_progress_domain_remaining_count GPU BEFORE))); fi
            (( ${APO_AUTO_GENERATED_CANDIDATES:-0} == 1 && ${APO_NEED_GPU:-0} == 1 )) && count=$((count + 1))
            count=$((count + $(apo_progress_future_validation_tests)))
            ;;
        CPU_QUALIFICATION)
            count=1
            if (( ${APO_NEED_GPU:-0} == 1 )); then
                if [[ $(apo_state_get GPU_GUARD_VERIFIED 0) != 1 ]]; then count=$((count + $(apo_progress_domain_remaining_count GPU BEFORE))); fi
                count=$((count + 1))
            fi
            count=$((count + $(apo_progress_future_validation_tests)))
            ;;
        GPU_SWEEP)
            count=$(apo_progress_domain_remaining_count GPU CURRENT)
            (( ${APO_AUTO_GENERATED_CANDIDATES:-0} == 1 )) && count=$((count + 1))
            count=$((count + $(apo_progress_future_validation_tests)))
            ;;
        SELECTION)
            if [[ $subphase == CPU && ${APO_AUTO_GENERATED_CANDIDATES:-0} == 1 ]]; then
                count=$((count + 1))
                if (( ${APO_NEED_GPU:-0} == 1 )); then
                    count=$((count + $(apo_progress_domain_remaining_count GPU BEFORE) + 1))
                fi
            elif (( ${APO_AUTO_GENERATED_CANDIDATES:-0} == 1 && ${APO_REQUIRE_GPU_STRESS:-0} == 1 )); then
                count=$((count + 1))
            fi
            count=$((count + $(apo_progress_future_validation_tests)))
            ;;
        GPU_QUALIFICATION)
            count=$((1 + $(apo_progress_future_validation_tests)))
            ;;
        FINAL_VALIDATION)
            edge_status=$(apo_state_get EDGE_CPU_STATUS NOT_REQUESTED)
            case $edge_status in
                RUNNING) count=1 ;;
                NOT_REQUESTED)
                    count=1
                    (( ${APO_EDGE_CPU_24H:-0} == 1 )) && count=2
                    ;;
                *) count=$([[ $(apo_state_get FINAL_STAGE '') == COMPLETE ]] && printf 0 || printf 1) ;;
            esac
            ;;
        MANUAL_TEST) count=1 ;;
        COMPLETE) count=0 ;;
        *) return 1 ;;
    esac
    printf '%s' "$count"
}

apo_progress_future_tuning_cost() {
    local from_phase=$1 candidate_cost qualification_cost cpu_count=0 gpu_count=0 remaining=0
    candidate_cost=$(apo_progress_candidate_cost)
    qualification_cost=$(apo_progress_qualification_cost)
    (( ${APO_AUTO_GENERATED_CANDIDATES:-0} == 1 )) || qualification_cost=0
    case $from_phase in
        CPU)
            cpu_count=$(apo_progress_domain_remaining_count CPU BEFORE)
            remaining=$((remaining + cpu_count * candidate_cost + qualification_cost))
            ;;
    esac
    if (( ${APO_NEED_GPU:-0} == 1 || ${APO_AUTO_GENERATED_CANDIDATES:-0} == 1 )) && [[ $from_phase != FINAL ]]; then
        gpu_count=$(apo_progress_domain_remaining_count GPU BEFORE)
        remaining=$((remaining + gpu_count * candidate_cost + qualification_cost))
    fi
    remaining=$((remaining + $(apo_progress_final_full_cost "${APO_CFG[FINAL_DURATION_S]:-$APO_DEFAULT_FINAL_DURATION_S}")))
    if (( ${APO_EDGE_CPU_24H:-0} == 1 )); then
        remaining=$((remaining + $(apo_progress_final_full_cost "${APO_EDGE_DURATION_S:-$APO_DEFAULT_EDGE_DURATION_S}")))
    fi
    printf '%s' "$remaining"
}

apo_progress_estimate_remaining_seconds() {
    local elapsed=${1:-0} duration=${2:-0} phase subphase candidate_cost qualification_cost count remaining=0
    phase=$(apo_state_get PHASE PREPARE)
    subphase=$(apo_state_get SUBPHASE '')
    candidate_cost=$(apo_progress_candidate_cost)
    qualification_cost=$(apo_progress_qualification_cost)
    (( ${APO_AUTO_GENERATED_CANDIDATES:-0} == 1 )) || qualification_cost=0
    case $phase in
        PREPARE|PREPARED)
            if (( ${APO_MANUAL_TEST:-0} == 1 )); then
                remaining=$((APO_PROGRESS_PREPARE_ESTIMATE_S + 2 * APO_PROGRESS_BOOT_ESTIMATE_S + 20 + candidate_cost))
            elif (( ${#APO_CPU_CANDIDATES[@]} > 0 || ${#APO_GPU_CANDIDATES[@]} > 0 || ${APO_AUTO_GENERATED_CANDIDATES:-0} == 1 )); then
                remaining=$((APO_PROGRESS_PREPARE_ESTIMATE_S + $(apo_progress_future_tuning_cost CPU)))
            else
                return 1
            fi
            ;;
        TRYBOOT_PROOF)
            if (( ${APO_MANUAL_TEST:-0} == 1 )); then
                remaining=$((2 * APO_PROGRESS_BOOT_ESTIMATE_S + 20 + $(apo_progress_candidate_cost)))
            else
                remaining=$((2 * APO_PROGRESS_BOOT_ESTIMATE_S + $(apo_progress_future_tuning_cost CPU)))
                (( ${APO_REQUIRE_GPU_STRESS:-0} == 1 )) && remaining=$((remaining + 20))
            fi
            ;;
        GPU_SMOKE)
            remaining=$((20 - elapsed))
            (( remaining < 0 )) && remaining=0
            if (( ${APO_MANUAL_TEST:-0} == 1 )); then remaining=$((remaining + $(apo_progress_candidate_cost)))
            else remaining=$((remaining + $(apo_progress_future_tuning_cost CPU))); fi
            ;;
        CPU_SWEEP)
            count=$(apo_progress_domain_remaining_count CPU CURRENT)
            remaining=$((count * candidate_cost - elapsed))
            (( remaining < 0 )) && remaining=0
            remaining=$((remaining + qualification_cost))
            if (( ${APO_NEED_GPU:-0} == 1 )); then
                count=$(apo_progress_domain_remaining_count GPU BEFORE)
                remaining=$((remaining + count * candidate_cost + qualification_cost))
            fi
            remaining=$((remaining + $(apo_progress_final_full_cost "${APO_CFG[FINAL_DURATION_S]:-$APO_DEFAULT_FINAL_DURATION_S}")))
            (( ${APO_EDGE_CPU_24H:-0} == 1 )) && remaining=$((remaining + $(apo_progress_final_full_cost "${APO_EDGE_DURATION_S:-$APO_DEFAULT_EDGE_DURATION_S}")))
            ;;
        CPU_QUALIFICATION)
            remaining=$((qualification_cost - elapsed))
            (( remaining < 0 )) && remaining=0
            if (( ${APO_NEED_GPU:-0} == 1 )); then
                if [[ $(apo_state_get GPU_GUARD_VERIFIED 0) != 1 ]]; then
                    count=$(apo_progress_domain_remaining_count GPU BEFORE)
                    remaining=$((remaining + count * candidate_cost))
                fi
                remaining=$((remaining + qualification_cost))
            fi
            remaining=$((remaining + $(apo_progress_final_full_cost "${APO_CFG[FINAL_DURATION_S]:-$APO_DEFAULT_FINAL_DURATION_S}")))
            (( ${APO_EDGE_CPU_24H:-0} == 1 )) && remaining=$((remaining + $(apo_progress_final_full_cost "${APO_EDGE_DURATION_S:-$APO_DEFAULT_EDGE_DURATION_S}")))
            ;;
        GPU_SWEEP)
            count=$(apo_progress_domain_remaining_count GPU CURRENT)
            remaining=$((count * candidate_cost - elapsed))
            (( remaining < 0 )) && remaining=0
            remaining=$((remaining + qualification_cost))
            remaining=$((remaining + $(apo_progress_final_full_cost "${APO_CFG[FINAL_DURATION_S]:-$APO_DEFAULT_FINAL_DURATION_S}")))
            (( ${APO_EDGE_CPU_24H:-0} == 1 )) && remaining=$((remaining + $(apo_progress_final_full_cost "${APO_EDGE_DURATION_S:-$APO_DEFAULT_EDGE_DURATION_S}")))
            ;;
        SELECTION)
            if [[ $subphase == CPU ]]; then
                remaining=$qualification_cost
                if (( ${APO_NEED_GPU:-0} == 1 )); then
                    count=$(apo_progress_domain_remaining_count GPU BEFORE)
                    remaining=$((remaining + count * candidate_cost + qualification_cost))
                fi
            elif (( ${APO_REQUIRE_GPU_STRESS:-0} == 1 )); then
                remaining=$qualification_cost
            fi
            remaining=$((remaining + $(apo_progress_final_full_cost "${APO_CFG[FINAL_DURATION_S]:-$APO_DEFAULT_FINAL_DURATION_S}")))
            (( ${APO_EDGE_CPU_24H:-0} == 1 )) && remaining=$((remaining + $(apo_progress_final_full_cost "${APO_EDGE_DURATION_S:-$APO_DEFAULT_EDGE_DURATION_S}")))
            ;;
        GPU_QUALIFICATION)
            remaining=$((qualification_cost - elapsed))
            (( remaining < 0 )) && remaining=0
            remaining=$((remaining + $(apo_progress_final_full_cost "${APO_CFG[FINAL_DURATION_S]:-$APO_DEFAULT_FINAL_DURATION_S}")))
            (( ${APO_EDGE_CPU_24H:-0} == 1 )) && remaining=$((remaining + $(apo_progress_final_full_cost "${APO_EDGE_DURATION_S:-$APO_DEFAULT_EDGE_DURATION_S}")))
            ;;
        FINAL_VALIDATION) remaining=$(apo_progress_final_remaining "$elapsed" "$duration") ;;
        MANUAL_TEST)
            remaining=$((candidate_cost - elapsed))
            (( remaining < 0 )) && remaining=0
            ;;
        COMPLETE)
            if [[ $(apo_state_get ORIGIN_COMMAND '') == overclock && $(apo_state_get APPLY_STATUS NOT_APPLIED) != APPLIED ]]; then
                remaining=$APO_PROGRESS_APPLY_ESTIMATE_S
            else
                remaining=0
            fi
            ;;
        *) return 1 ;;
    esac
    printf '%s' "$remaining"
}

apo_progress_status_label() {
    local phase subphase label
    phase=$(apo_state_get PHASE PREPARE)
    subphase=$(apo_state_get SUBPHASE '')
    label=${subphase:-$phase}
    label=${label//_/ }
    printf '%s' "${label,,}"
}

apo_progress_resolve_clock() {
    local domain=$1 value=''
    case $domain in
        cpu)
            value=${APO_PROGRESS_LAST_CPU:-}
            [[ -n $value ]] || value=$(apo_state_get CURRENT_CPU '')
            [[ -n $value ]] || value=$(apo_state_get CANDIDATE_CPU '')
            [[ -n $value ]] || value=$(apo_state_get FINAL_TARGET_CPU '')
            [[ -n $value ]] || value=${APO_NORMAL_CPU:-}
            ;;
        gpu)
            value=${APO_PROGRESS_LAST_GPU:-}
            [[ -n $value ]] || value=$(apo_state_get CURRENT_GPU '')
            [[ -n $value ]] || value=$(apo_state_get CANDIDATE_GPU '')
            [[ -n $value ]] || value=$(apo_state_get FINAL_TARGET_GPU '')
            [[ -n $value ]] || value=${APO_NORMAL_GPU:-}
            ;;
    esac
    printf '%s' "${value:-?}"
}

apo_progress_terminal_columns() {
    local columns=''
    # COLUMNS is only a launch-time snapshot for many non-interactive scripts and
    # becomes stale when an attached pane or mobile client is resized. Query the
    # controlling terminal first so every repaint uses the live pane width.
    if [[ -t 2 ]] && command -v stty >/dev/null 2>&1; then
        read -r _ columns < <(stty size < /dev/tty 2>/dev/null || true) || columns=''
    fi
    [[ $columns =~ ^[0-9]+$ ]] || columns=${COLUMNS:-}
    if [[ ! $columns =~ ^[0-9]+$ ]] && command -v tput >/dev/null 2>&1; then columns=$(tput cols 2>/dev/null || true); fi
    [[ $columns =~ ^[0-9]+$ ]] || columns=120
    (( columns > 1 )) || columns=2
    printf '%s' "$columns"
}

apo_progress_render() {
    local elapsed=${1:-${APO_PROGRESS_STRESS_ELAPSED:-0}} duration=${2:-${APO_PROGRESS_STRESS_DURATION:-0}}
    local remaining active percent filled empty bar eta target cpu gpu temp max_temp throttle fan phase columns render_width line
    local wide_line medium_line narrow_line
    local bar_width=$APO_PROGRESS_BAR_WIDTH tests current_remaining='' stress_label
    apo_progress_available || return 0
    active=$(apo_progress_active_seconds)
    if remaining=$(apo_progress_estimate_remaining_seconds "$elapsed" "$duration"); then
        if (( remaining == 0 )); then percent=100
        elif (( active + remaining > 0 )); then percent=$((active * 100 / (active + remaining)))
        else percent=0; fi
        (( percent > 99 && remaining > 0 )) && percent=99
        columns=$(apo_progress_terminal_columns)
        if (( columns < 75 )); then bar_width=8
        elif (( columns < APO_PROGRESS_WIDE_MIN_COLUMNS )); then bar_width=12; fi
        filled=$((percent * bar_width / 100))
        empty=$((bar_width - filled))
        printf -v bar '%*s' "$filled" ''
        bar=${bar// /#}
        printf -v line '%*s' "$empty" ''
        bar+="${line// /-}"
        eta="~$(apo_progress_format_duration "$remaining")"
    else
        percent='--'
        columns=$(apo_progress_terminal_columns)
        if (( columns < 75 )); then bar_width=8
        elif (( columns < APO_PROGRESS_WIDE_MIN_COLUMNS )); then bar_width=12; fi
        printf -v bar '%*s' "$bar_width" ''
        bar=${bar// /-}
        eta='calculating'
    fi
    target=${APO_RAW_TARGET:-$(apo_state_get RAW_TARGET target)}
    cpu=$(apo_progress_resolve_clock cpu)
    gpu=$(apo_progress_resolve_clock gpu)
    temp=${APO_PROGRESS_LAST_TEMP:-$(apo_state_get PROGRESS_LAST_TEMP '?')}
    max_temp=${APO_PROGRESS_RUN_MAX_TEMP:-$(apo_state_get RUN_MAX_TEMP '')}
    throttle=${APO_PROGRESS_LAST_THROTTLE:-$(apo_state_get PROGRESS_LAST_THROTTLE '?')}
    fan=${APO_PROGRESS_LAST_FAN:-$(apo_state_get PROGRESS_LAST_FAN '')}
    phase=$(apo_progress_status_label)
    tests=$(apo_progress_estimate_remaining_tests 2>/dev/null || printf '?')
    stress_label=$(apo_state_get PROGRESS_STRESS_LABEL '')
    if [[ -n $stress_label && $duration =~ ^[0-9]+$ && $elapsed =~ ^[0-9]+$ && $duration -gt 0 ]]; then
        current_remaining=$((duration - elapsed))
        (( current_remaining < 0 )) && current_remaining=0
        current_remaining=$(apo_progress_format_duration "$current_remaining")
    fi
    columns=${columns:-$(apo_progress_terminal_columns)}
    wide_line="$target [$bar] ~${percent}% ETA $eta"
    [[ -z $current_remaining ]] || wide_line+=" | current $current_remaining left"
    wide_line+=" | tests ~$tests left | CPU: ${cpu}MHz | GPU: ${gpu}MHz | ${temp}C"
    [[ -z $max_temp ]] || wide_line+=" max=${max_temp}C"
    wide_line+=" | $phase | $throttle"
    [[ -z $fan ]] || wide_line+=" | fan=$fan"

    medium_line="$target [$bar] ~${percent}% $eta"
    [[ -z $current_remaining ]] || medium_line+=" c:${current_remaining}"
    medium_line+=" | ~$tests tests | CPU: $cpu | GPU: $gpu | ${temp}C | $phase"
    narrow_line="$target [$bar] ~${percent}% $eta | ~$tests tests | $phase"

    # A multiplexed PTY can retain wider pane geometry than a newly attached
    # mobile viewport. Prefer a complete compact layout over truncating the
    # verbose layout against that potentially stale right edge.
    render_width=$((columns - APO_PROGRESS_RIGHT_MARGIN))
    (( render_width > 0 )) || render_width=1
    if (( columns >= APO_PROGRESS_WIDE_MIN_COLUMNS && ${#wide_line} <= render_width )); then
        line=$wide_line
    elif (( columns >= 75 && ${#medium_line} <= render_width )); then
        line=$medium_line
    else
        line=$narrow_line
    fi
    (( ${#line} > render_width )) && line=${line:0:render_width}
    # Disable terminal autowrap only for the atomic repaint. Even if the pty's
    # reported width is wider than the attached viewport, the cursor cannot
    # spill into another row and leave a stale progress line behind.
    printf '\033[?7l\033[1G\033[2K%s\033[?7h' "$line" >&2
    APO_PROGRESS_LINE_ACTIVE=1
    APO_PROGRESS_LINE_WIDTH=${#line}
}

apo_progress_clear_line() {
    (( APO_PROGRESS_LINE_ACTIVE == 1 )) || return 0
    printf '\033[?7l\033[1G\033[2K\033[?7h' >&2
    APO_PROGRESS_LINE_ACTIVE=0
    APO_PROGRESS_LINE_WIDTH=0
}

apo_progress_begin_shutdown() {
    APO_PROGRESS_SHUTTING_DOWN=1
    apo_progress_clear_line
}

apo_progress_before_output() { apo_progress_clear_line; }
apo_progress_after_output() { apo_progress_render; }

apo_progress_line_is_telemetry() {
    [[ $1 == *' temp='*' arm='*' v3d='*' expected='*' elapsed='* ]]
}

apo_progress_parse_telemetry_line() {
    local line=$1
    if [[ $line =~ temp=([^[:space:]]+)C ]]; then
        APO_PROGRESS_LAST_TEMP=${BASH_REMATCH[1]}
        if [[ $APO_PROGRESS_LAST_TEMP =~ ^[0-9]+([.][0-9]+)?$ ]] &&
           { [[ ! $APO_PROGRESS_RUN_MAX_TEMP =~ ^[0-9]+([.][0-9]+)?$ ]] ||
             awk -v old="$APO_PROGRESS_RUN_MAX_TEMP" -v new="$APO_PROGRESS_LAST_TEMP" 'BEGIN { exit !(new > old) }'; }; then
            APO_PROGRESS_RUN_MAX_TEMP=$APO_PROGRESS_LAST_TEMP
        fi
    fi
    if [[ $line =~ arm=([0-9]+)MHz ]]; then APO_PROGRESS_LAST_CPU=${BASH_REMATCH[1]}; fi
    if [[ $line =~ v3d=([0-9]+)MHz ]]; then APO_PROGRESS_LAST_GPU=${BASH_REMATCH[1]}; fi
    if [[ $line =~ (throttled=0x[0-9A-Fa-f]+) ]]; then APO_PROGRESS_LAST_THROTTLE=${BASH_REMATCH[1]}; fi
    if [[ $line =~ fan=([^[:space:]]+) ]]; then APO_PROGRESS_LAST_FAN=${BASH_REMATCH[1]}; fi
    if [[ $line =~ elapsed=([0-9]+)/([0-9]+)s ]]; then
        APO_PROGRESS_STRESS_ELAPSED=${BASH_REMATCH[1]}
        APO_PROGRESS_STRESS_DURATION=${BASH_REMATCH[2]}
    fi
}

apo_progress_handle_worker_line() {
    apo_progress_parse_telemetry_line "$1"
    apo_progress_render "$APO_PROGRESS_STRESS_ELAPSED" "$APO_PROGRESS_STRESS_DURATION"
}

apo_progress_capture_worker_stream() {
    local output_file=$1 line
    while IFS= read -r line || [[ -n $line ]]; do
        printf '%s\n' "$line" >> "$output_file"
        printf '%s\n' "$line" >> "$APO_LOG_FILE"
        if apo_progress_available && apo_progress_line_is_telemetry "$line"; then
            apo_progress_handle_worker_line "$line"
        else
            apo_progress_before_output
            printf '%s\n' "$line"
        fi
    done
}

apo_progress_record_worker_result() {
    local output_file=$1 result_max_temp=${2:-} last_line='' saved_max current_max
    last_line=$(grep -E ' temp=[^[:space:]]+C arm=[0-9]+MHz v3d=[0-9]+MHz .*elapsed=[0-9]+/[0-9]+s' "$output_file" 2>/dev/null | tail -1 || true)
    if [[ -n $last_line ]]; then apo_progress_parse_telemetry_line "$last_line"; fi
    [[ -z $APO_PROGRESS_LAST_TEMP ]] || apo_state_set PROGRESS_LAST_TEMP "$APO_PROGRESS_LAST_TEMP"
    [[ -z $APO_PROGRESS_LAST_CPU ]] || apo_state_set PROGRESS_LAST_CPU "$APO_PROGRESS_LAST_CPU"
    [[ -z $APO_PROGRESS_LAST_GPU ]] || apo_state_set PROGRESS_LAST_GPU "$APO_PROGRESS_LAST_GPU"
    [[ -z $APO_PROGRESS_LAST_THROTTLE ]] || apo_state_set PROGRESS_LAST_THROTTLE "$APO_PROGRESS_LAST_THROTTLE"
    [[ -z $APO_PROGRESS_LAST_FAN ]] || apo_state_set PROGRESS_LAST_FAN "$APO_PROGRESS_LAST_FAN"
    [[ $result_max_temp =~ ^[0-9]+([.][0-9]+)?$ ]] || result_max_temp=$APO_PROGRESS_LAST_TEMP
    if [[ $result_max_temp =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        saved_max=$(apo_state_get RUN_MAX_TEMP '')
        current_max=$result_max_temp
        if [[ $saved_max =~ ^[0-9]+([.][0-9]+)?$ ]] && awk -v old="$saved_max" -v new="$current_max" 'BEGIN { exit !(old > new) }'; then
            current_max=$saved_max
        fi
        apo_state_set RUN_MAX_TEMP "$current_max"
        APO_PROGRESS_RUN_MAX_TEMP=$current_max
    fi
    apo_state_set PROGRESS_STRESS_ELAPSED "${APO_PROGRESS_STRESS_ELAPSED:-0}"
    apo_state_set PROGRESS_STRESS_DURATION "${APO_PROGRESS_STRESS_DURATION:-0}"
}

apo_progress_begin_stress() {
    local duration=$1 label=$2
    APO_PROGRESS_STRESS_ELAPSED=0
    APO_PROGRESS_STRESS_DURATION=$duration
    APO_PROGRESS_RUN_MAX_TEMP=$(apo_state_get RUN_MAX_TEMP '')
    apo_state_set PROGRESS_STRESS_LABEL "$label"
    apo_state_set PROGRESS_STRESS_ELAPSED 0
    apo_state_set PROGRESS_STRESS_DURATION "$duration"
    apo_state_save
    apo_progress_render 0 "$duration"
}

apo_progress_finish_stress() {
    apo_state_set PROGRESS_STRESS_LABEL ''
    apo_state_set PROGRESS_STRESS_ELAPSED 0
    apo_state_set PROGRESS_STRESS_DURATION 0
    APO_PROGRESS_STRESS_ELAPSED=0
    APO_PROGRESS_STRESS_DURATION=0
    apo_state_save
    apo_progress_render
}
