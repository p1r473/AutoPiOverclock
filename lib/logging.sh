#!/usr/bin/env bash
# Flat controller-side artifacts. Existing run files are never deleted.

apo_safe_mkdir() {
    local directory=$1
    mkdir -p -- "$directory"
    chmod 700 "$directory" 2>/dev/null || true
}

apo_init_artifacts() {
    local base_id suffix=0
    apo_safe_mkdir "$APO_OUTPUT_DIR"
    APO_OUTPUT_DIR=$(cd -- "$APO_OUTPUT_DIR" && pwd -P)
    base_id=$(apo_new_run_id) || apo_die 'Could not create a random collision-resistant run ID.' "$APO_EXIT_INTERNAL"
    APO_RUN_ID=$base_id
    while [[ -e ${APO_OUTPUT_DIR}/${APO_TARGET_SLUG}-${APO_RUN_ID}.state ]]; do
        suffix=$((suffix + 1))
        APO_RUN_ID=$(printf '%s-%02d' "$base_id" "$suffix")
    done
    APO_RUN_PREFIX="${APO_OUTPUT_DIR}/${APO_TARGET_SLUG}-${APO_RUN_ID}"
    APO_LOG_FILE="${APO_RUN_PREFIX}.log"
    APO_CSV_FILE="${APO_RUN_PREFIX}.csv"
    APO_JSONL_FILE="${APO_RUN_PREFIX}.jsonl"
    APO_JSON_FILE="${APO_RUN_PREFIX}.json"
    APO_SUMMARY_FILE="${APO_RUN_PREFIX}-summary.txt"
    APO_STATE_FILE="${APO_RUN_PREFIX}.state"
    APO_EFFECTIVE_CONFIG_FILE="${APO_RUN_PREFIX}.conf"
    APO_DISCOVERY_FILE="${APO_RUN_PREFIX}-discovery.txt"
    : > "$APO_LOG_FILE"
    printf 'timestamp,phase,severity,classification,message\n' > "$APO_CSV_FILE"
    : > "$APO_JSONL_FILE"
    : > "$APO_SUMMARY_FILE"
    : > "$APO_DISCOVERY_FILE"
    chmod 600 "$APO_LOG_FILE" "$APO_CSV_FILE" "$APO_JSONL_FILE" "$APO_SUMMARY_FILE" "$APO_DISCOVERY_FILE"
    ln -sfn -- "$(basename "$APO_LOG_FILE")" "${APO_OUTPUT_DIR}/${APO_TARGET_SLUG}-latest.log"
    ln -sfn -- "$(basename "$APO_SUMMARY_FILE")" "${APO_OUTPUT_DIR}/${APO_TARGET_SLUG}-latest-summary.txt"
    ln -sfn -- "$(basename "$APO_STATE_FILE")" "${APO_OUTPUT_DIR}/${APO_TARGET_SLUG}-latest.state"
    ln -sfn -- "$(basename "$APO_JSON_FILE")" "${APO_OUTPUT_DIR}/${APO_TARGET_SLUG}-latest.json"
    export APO_RUN_ID APO_RUN_PREFIX APO_LOG_FILE APO_CSV_FILE APO_JSONL_FILE APO_JSON_FILE APO_SUMMARY_FILE APO_STATE_FILE APO_EFFECTIVE_CONFIG_FILE APO_DISCOVERY_FILE
}

apo_attach_artifacts_from_state() {
    APO_RUN_ID=$(apo_state_get RUN_ID)
    APO_RUN_PREFIX="$(dirname "$APO_STATE_FILE")/$(basename "${APO_STATE_FILE%.state}")"
    APO_OUTPUT_DIR=$(dirname "$APO_STATE_FILE")
    # Artifact destinations are properties of the verified state pathname, not
    # authority carried inside an editable state value. Reconstruct every path
    # so a corrupt or imported state cannot make the controller touch or
    # overwrite an unrelated file.
    APO_LOG_FILE="${APO_RUN_PREFIX}.log"
    APO_CSV_FILE="${APO_RUN_PREFIX}.csv"
    APO_JSONL_FILE="${APO_RUN_PREFIX}.jsonl"
    APO_JSON_FILE="${APO_RUN_PREFIX}.json"
    APO_SUMMARY_FILE="${APO_RUN_PREFIX}-summary.txt"
    APO_EFFECTIVE_CONFIG_FILE="${APO_RUN_PREFIX}.conf"
    APO_DISCOVERY_FILE="${APO_RUN_PREFIX}-discovery.txt"
    # Observers must not create or timestamp run artifacts. Mutating saved-run
    # commands retain the historical repair behavior for missing core files.
    case ${APO_COMMAND:-} in
        status|report) ;;
        *) touch -- "$APO_LOG_FILE" "$APO_CSV_FILE" "$APO_JSONL_FILE" "$APO_SUMMARY_FILE" ;;
    esac
}

apo_log() {
    local severity=$1
    shift
    local message=$* rendered
    rendered="$(date '+%F %T') [${severity}] ${message}"
    if declare -F apo_progress_before_output >/dev/null 2>&1; then apo_progress_before_output; fi
    printf '%s\n' "$rendered" | tee -a "$APO_LOG_FILE" >&2
    if declare -F apo_progress_after_output >/dev/null 2>&1; then apo_progress_after_output; fi
}

apo_info() { apo_log INFO "$*"; }
apo_warn() { apo_log WARN "$*"; }
apo_error() { apo_log ERROR "$*"; }

apo_csv_escape() {
    local value=${1-}
    value=${value//\"/\"\"}
    printf '"%s"' "$value"
}

apo_event() {
    local phase=$1 severity=$2 classification=${3-} message=${4-} timestamp
    timestamp=$(apo_now_iso)
    printf '%s,%s,%s,%s,%s\n' \
        "$(apo_csv_escape "$timestamp")" "$(apo_csv_escape "$phase")" "$(apo_csv_escape "$severity")" \
        "$(apo_csv_escape "$classification")" "$(apo_csv_escape "$message")" >> "$APO_CSV_FILE"
    printf '{"timestamp":"%s","phase":"%s","severity":"%s","classification":"%s","message":"%s"}\n' \
        "$(apo_json_escape "$timestamp")" "$(apo_json_escape "$phase")" "$(apo_json_escape "$severity")" \
        "$(apo_json_escape "$classification")" "$(apo_json_escape "$message")" >> "$APO_JSONL_FILE"
    apo_log "$severity" "${phase}${classification:+ [$classification]}: $message"
}

apo_summary_line() { printf '%s\n' "$*" >> "$APO_SUMMARY_FILE"; }

apo_candidate_log_file() {
    local label=$1 base_file candidate_file suffix=0
    base_file="${APO_RUN_PREFIX}-$(apo_slugify "$label").log"
    candidate_file=$base_file
    while [[ -e $candidate_file ]]; do
        suffix=$((suffix + 1))
        candidate_file=$(printf '%s-retry-%02d.log' "${base_file%.log}" "$suffix")
    done
    printf '%s' "$candidate_file"
}

apo_finalize_json() {
    [[ -f ${APO_JSONL_FILE:-} ]] || return 0
    {
        printf '[\n'
        awk 'NR>1{print ","} {printf "  %s", $0} END{if(NR>0) print ""}' "$APO_JSONL_FILE"
        printf ']\n'
    } | apo_atomic_write "$APO_JSON_FILE"
}

apo_find_state_file() {
    local requested_run_id=${1-} candidate_file link_target
    if [[ -n $requested_run_id ]]; then
        candidate_file="${APO_OUTPUT_DIR}/${APO_TARGET_SLUG}-${requested_run_id}.state"
        [[ -f $candidate_file ]] || return 1
    else
        candidate_file="${APO_OUTPUT_DIR}/${APO_TARGET_SLUG}-latest.state"
        [[ -e $candidate_file ]] || return 1
        if [[ -L $candidate_file ]]; then
            link_target=$(readlink "$candidate_file" 2>/dev/null) || return 1
            [[ $link_target != */* && -n $link_target ]] || return 1
            candidate_file="${APO_OUTPUT_DIR}/${link_target}"
        fi
        [[ -f $candidate_file ]] || return 1
    fi
    printf '%s' "$candidate_file"
}
