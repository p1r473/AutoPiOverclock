#!/usr/bin/env bash
# Common controller-side helpers for AutoPiOverclock.

APO_NAME='AutoPiOverclock'
APO_VERSION=$(<"${APO_ROOT}/VERSION")

readonly APO_EXIT_OK=0
readonly APO_EXIT_USAGE=2
readonly APO_EXIT_PREFLIGHT=20
readonly APO_EXIT_HARNESS=21
readonly APO_EXIT_BOOT=22
readonly APO_EXIT_STABILITY=23
readonly APO_EXIT_RECOVERY=24
readonly APO_EXIT_APPLY=25
readonly APO_EXIT_INTERNAL=70
readonly APO_MIN_TUNING_DURATION_S=3600
readonly APO_MAX_TUNING_DURATION_S=604800
readonly APO_DEFAULT_QUALIFICATION_DURATION_S=7200
readonly APO_DEFAULT_FINAL_DURATION_S=172800
readonly APO_DEFAULT_EDGE_DURATION_S=86400
# Runs created before the 48-hour default recorded either the former 24-hour
# or older eight-hour final as policy=default. Keep both historical labels
# verifiable without treating new requests for those durations as current
# defaults.
readonly APO_PREVIOUS_DEFAULT_FINAL_DURATION_S=86400
readonly APO_LEGACY_DEFAULT_FINAL_DURATION_S=28800
# Retained as a source-compatible name for older fixture/support code. New
# automatic runs use the immutable per-run APO_QUALIFICATION_DURATION_S value.
readonly APO_DOMAIN_QUALIFICATION_DURATION_S=$APO_DEFAULT_QUALIFICATION_DURATION_S
readonly APO_MIN_FINAL_DURATION_S=$APO_MIN_TUNING_DURATION_S

APO_QUALIFICATION_DURATION_S=${APO_QUALIFICATION_DURATION_S:-$APO_DEFAULT_QUALIFICATION_DURATION_S}
APO_FINAL_DURATION_S=${APO_FINAL_DURATION_S:-$APO_DEFAULT_FINAL_DURATION_S}
APO_EDGE_DURATION_S=${APO_EDGE_DURATION_S:-$APO_DEFAULT_EDGE_DURATION_S}
APO_EDGE_ORDER=${APO_EDGE_ORDER:-floor-first}

APO_FATAL_MESSAGE=''
APO_FATAL_EXIT_CODE=''

apo_die() {
    local message=${1:-'Unspecified error'}
    local exit_code=${2:-$APO_EXIT_INTERNAL}
    APO_FATAL_MESSAGE=$message
    APO_FATAL_EXIT_CODE=$exit_code
    printf 'ERROR: %s\n' "$message" >&2
    exit "$exit_code"
}

apo_info_plain() { printf 'INFO: %s\n' "$*" >&2; }
apo_warn_plain() { printf 'WARNING: %s\n' "$*" >&2; }

apo_is_redacted_observer() {
    [[ ${APO_REDACT:-0} == 1 ]] || return 1
    case ${APO_COMMAND:-} in status|summary|report) return 0 ;; *) return 1 ;; esac
}

apo_trim() {
    local value=${1-}
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

apo_now_iso() { date '+%Y-%m-%dT%H:%M:%S%z'; }
apo_new_run_id() {
    local timestamp random_suffix
    timestamp=$(date '+%Y%m%d-%H%M%S') || return 1
    random_suffix=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n') || return 1
    [[ $random_suffix =~ ^[0-9a-f]{16}$ ]] || return 1
    printf '%s-%s' "$timestamp" "$random_suffix"
}

apo_is_uint() { [[ ${1-} =~ ^[0-9]+$ ]]; }
apo_is_int() { [[ ${1-} =~ ^-?[0-9]+$ ]]; }
apo_is_safe_name() { [[ ${1-} =~ ^[A-Za-z0-9_][A-Za-z0-9_.@:+-]*$ ]]; }
apo_is_safe_host() { [[ ${1-} =~ ^[A-Za-z0-9_][A-Za-z0-9_.:-]*$ ]]; }
apo_is_safe_run_id() {
    local run_id=${1-}
    [[ $run_id =~ ^[A-Za-z0-9._-]+$ && $run_id != . && $run_id != .. ]]
}

apo_validate_uint_range() {
    local value=$1 minimum=$2 maximum=$3
    apo_is_uint "$value" && (( value >= minimum && value <= maximum ))
}

apo_throttle_word() {
    local reading=${1-} hex_value
    [[ $reading =~ ^throttled=0x([0-9A-Fa-f]+)$ ]] || return 1
    hex_value=${BASH_REMATCH[1]}
    printf '%u' "$((16#$hex_value))"
}

apo_throttle_reading_valid() { apo_throttle_word "${1-}" >/dev/null; }

apo_throttle_active_bits_clear() {
    local throttle_word
    throttle_word=$(apo_throttle_word "${1-}") || return 1
    (( (throttle_word & 0xffff) == 0 ))
}

apo_throttle_clean_relative() {
    local current_word baseline_word
    current_word=$(apo_throttle_word "${1-}") || return 1
    baseline_word=$(apo_throttle_word "${2-}") || return 1
    (( (current_word & 0xffff) == 0 && (current_word & ~baseline_word) == 0 ))
}

apo_slugify() {
    local value=${1-}
    value=${value##*@}
    value=${value//[^A-Za-z0-9._-]/-}
    while [[ $value == *--* ]]; do value=${value//--/-}; done
    value=${value#-}
    value=${value%-}
    [[ -n $value ]] || value=target
    printf '%s' "$value"
}

apo_sh_quote() {
    local value=${1-}
    value=${value//\'/\'\\\'\'}
    printf "'%s'" "$value"
}

apo_json_escape() {
    local value=${1-}
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/\\r}
    value=${value//$'\t'/\\t}
    printf '%s' "$value"
}

apo_csv_to_array() {
    local csv_value=$1 output_name=$2 item
    local -n output_array=$output_name
    local -a raw_items=()
    output_array=()
    [[ -n $csv_value ]] || return 0
    IFS=',' read -r -a raw_items <<< "$csv_value"
    for item in "${raw_items[@]}"; do
        item=$(apo_trim "$item")
        [[ -n $item ]] && output_array+=("$item")
    done
}

apo_append_csv() {
    local csv_value=$1 item=$2
    if [[ -n $csv_value ]]; then printf '%s,%s' "$csv_value" "$item"; else printf '%s' "$item"; fi
}

apo_select_with_backoff() {
    local csv_value=$1 backoff_steps=$2 baseline_fallback=${3-} selected_index
    local -a values=()
    apo_csv_to_array "$csv_value" values
    (( ${#values[@]} > 0 )) || return 1
    selected_index=$((${#values[@]} - 1 - backoff_steps))
    if (( selected_index < 0 )); then
        if [[ -n $baseline_fallback ]]; then printf '%s' "$baseline_fallback"; return 0; fi
        selected_index=0
    fi
    printf '%s' "${values[$selected_index]}"
}

apo_require_local_commands() {
    local command_name
    for command_name in "$@"; do
        command -v "$command_name" >/dev/null 2>&1 || apo_die "Required controller command not found: $command_name" "$APO_EXIT_PREFLIGHT"
    done
}

apo_atomic_write() {
    local destination=$1 destination_dir temporary_file
    destination_dir=$(dirname -- "$destination")
    mkdir -p -- "$destination_dir"
    temporary_file=$(mktemp "${destination_dir}/.autopioverclock.XXXXXX")
    chmod 600 "$temporary_file"
    cat > "$temporary_file"
    mv -f -- "$temporary_file" "$destination"
}

apo_parse_target() {
    local supplied_target=$1 controller_user remote_user remote_host
    [[ -n $supplied_target ]] || apo_die 'TARGET is required.' "$APO_EXIT_USAGE"
    if [[ $supplied_target == *@* ]]; then
        remote_user=${supplied_target%%@*}
        remote_host=${supplied_target#*@}
    else
        controller_user=$(id -un)
        remote_user=$controller_user
        remote_host=$supplied_target
    fi
    apo_is_safe_name "$remote_user" || apo_die "Unsafe remote username: $remote_user" "$APO_EXIT_USAGE"
    apo_is_safe_host "$remote_host" || apo_die "Unsafe target hostname or address: $remote_host" "$APO_EXIT_USAGE"
    [[ -n $remote_user && -n $remote_host ]] || apo_die 'Invalid TARGET.' "$APO_EXIT_USAGE"
    APO_RAW_TARGET=$supplied_target
    APO_REMOTE_USER=$remote_user
    APO_TARGET_HOST=$remote_host
    APO_REMOTE_TARGET="${remote_user}@${remote_host}"
    APO_TARGET_SLUG=$(apo_slugify "$remote_host")
    export APO_RAW_TARGET APO_REMOTE_USER APO_TARGET_HOST APO_REMOTE_TARGET APO_TARGET_SLUG
}

apo_confirm_exact() {
    local prompt=$1 expected=$2 answer
    [[ -t 0 ]] || return 1
    printf '%s\nType exactly: %s\n> ' "$prompt" "$expected" >&2
    IFS= read -r answer
    [[ $answer == "$expected" ]]
}

apo_confirm_ordinary() {
    local prompt=$1 answer
    if [[ ${APO_ASSUME_YES:-0} == 1 ]]; then return 0; fi
    [[ -t 0 ]] || return 1
    printf '%s [y/N] ' "$prompt" >&2
    IFS= read -r answer
    case $answer in y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}

apo_class_exit_code() {
    case ${1-} in
        PREFLIGHT_FAILURE) printf '%s' "$APO_EXIT_PREFLIGHT" ;;
        HARNESS_FAILURE) printf '%s' "$APO_EXIT_HARNESS" ;;
        BOOT_FAILURE) printf '%s' "$APO_EXIT_BOOT" ;;
        STABILITY_FAILURE) printf '%s' "$APO_EXIT_STABILITY" ;;
        RECOVERY_FAILURE) printf '%s' "$APO_EXIT_RECOVERY" ;;
        APPLY_FAILURE) printf '%s' "$APO_EXIT_APPLY" ;;
        *) printf '%s' "$APO_EXIT_INTERNAL" ;;
    esac
}

apo_exit_code_class() {
    case ${1-} in
        "$APO_EXIT_PREFLIGHT") printf PREFLIGHT_FAILURE ;;
        "$APO_EXIT_HARNESS") printf HARNESS_FAILURE ;;
        "$APO_EXIT_BOOT") printf BOOT_FAILURE ;;
        "$APO_EXIT_STABILITY") printf STABILITY_FAILURE ;;
        "$APO_EXIT_RECOVERY") printf RECOVERY_FAILURE ;;
        "$APO_EXIT_APPLY") printf APPLY_FAILURE ;;
        *) return 1 ;;
    esac
}
