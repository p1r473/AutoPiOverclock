#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

parse_fixture() {
    local expected_command=$1 expected_origin=$2 expected_public=$3
    shift 3
    (
        export APO_CLI_LIBRARY_ONLY=1
        # shellcheck source=../autopioverclock
        source "$ROOT/autopioverclock"
        apo_parse_cli "$@"
        [[ $APO_COMMAND == "$expected_command" ]]
        [[ $APO_ORIGIN_COMMAND == "$expected_origin" ]]
        [[ $APO_PUBLIC_COMMAND == "$expected_public" ]]
        [[ $APO_REMOTE_TARGET == "$(id -un)@tron" ]]
    )
}

parse_fixture prepare prepare prepare prepare tron
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli prepare tron
    [[ $APO_INSTALL_MISSING == 1 ]]
    [[ $APO_REPAIR_WATCHDOGS == 1 ]]
    [[ $APO_AUTO_PREPARE == 1 ]]
    [[ $APO_AUTO_APPLY == 0 ]]
)

parse_fixture run overclock overclock overclock tron
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock tron --edge-cpu-24h
    [[ $APO_COMMAND == run ]]
    [[ $APO_AUTO_APPLY == 1 ]]
    [[ $APO_ASSUME_YES == 1 ]]
    [[ $APO_EDGE_CPU_24H == 1 ]]
    [[ $APO_MODE_REQUESTED == auto ]]
    [[ -z $APO_CONFIG_FILE ]]
)

parse_fixture reset reset reset reset tron
parse_fixture reset reset '' tron reset

write_state_fixture() {
    local destination=$1 key value
    shift
    : > "$destination"
    while (( $# > 0 )); do
        key=$1
        value=$2
        shift 2
        printf '%s\t%s\n' "$key" "$(printf '%s' "$value" | base64 | tr -d '\n')" >> "$destination"
    done
}

CONTINUATION_OUTPUT="$TEMP_DIR/continuation-output"
mkdir -p "$CONTINUATION_OUTPUT"
CONTINUATION_RUN=20260827-010203-abcdef0123456789
CONTINUATION_STATE="$CONTINUATION_OUTPUT/tron-${CONTINUATION_RUN}.state"
write_state_fixture "$CONTINUATION_STATE" \
    FORMAT_VERSION 1 RUN_SCHEMA 7 RUN_ID "$CONTINUATION_RUN" \
    REMOTE_TARGET "$(id -un)@tron" ORIGIN_COMMAND overclock \
    STATUS INTERRUPTED PHASE CPU_SWEEP APPLY_STATUS NOT_APPLIED
ln -s "$(basename "$CONTINUATION_STATE")" "$CONTINUATION_OUTPUT/tron-latest.state"
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock tron
    APO_OUTPUT_DIR=$CONTINUATION_OUTPUT
    apo_public_overclock_select_continuation
    [[ $APO_COMMAND == resume ]]
    [[ $APO_SELECTED_RUN_ID == "$CONTINUATION_RUN" ]]
    [[ $APO_AUTO_APPLY == 1 ]]
)

PREPARE_RUN=20260827-010204-abcdef0123456789
PREPARE_STATE="$CONTINUATION_OUTPUT/tron-${PREPARE_RUN}.state"
write_state_fixture "$PREPARE_STATE" \
    FORMAT_VERSION 1 RUN_SCHEMA 7 RUN_ID "$PREPARE_RUN" \
    REMOTE_TARGET "$(id -un)@tron" ORIGIN_COMMAND prepare \
    STATUS PASS PHASE COMPLETE APPLY_STATUS NOT_APPLIED
ln -sfn "$(basename "$PREPARE_STATE")" "$CONTINUATION_OUTPUT/tron-latest.state"
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock tron
    APO_OUTPUT_DIR=$CONTINUATION_OUTPUT
    apo_public_overclock_select_continuation
    [[ $APO_COMMAND == run ]]
    [[ -z $APO_SELECTED_RUN_ID ]]
    [[ -z ${APO_STATE_FILE:-} ]]
)

SAVED_CONFIG="$TEMP_DIR/config"
mkdir -p "$SAVED_CONFIG/autopioverclock"
printf '%s\n' 'root@saved-target' > "$SAVED_CONFIG/autopioverclock/target"
(
    export APO_CLI_LIBRARY_ONLY=1 XDG_CONFIG_HOME=$SAVED_CONFIG
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock
    [[ $APO_RAW_TARGET == root@saved-target ]]
    [[ $APO_REMOTE_TARGET == root@saved-target ]]
)

(
    export APO_CLI_LIBRARY_ONLY=1 XDG_CONFIG_HOME="$TEMP_DIR/saved-by-prepare"
    source "$ROOT/autopioverclock"
    APO_REMOTE_TARGET=root@remembered-target
    apo_save_default_target
    [[ $(<"$XDG_CONFIG_HOME/autopioverclock/target") == root@remembered-target ]]
    [[ $(stat -c '%a' "$XDG_CONFIG_HOME/autopioverclock/target") == 600 ]]
    APO_REMOTE_TARGET=root@different-target
    if apo_save_default_target; then
        echo 'a different prepared target silently replaced the remembered target' >&2
        exit 1
    else
        [[ $? == 2 ]]
    fi
    [[ $(<"$XDG_CONFIG_HOME/autopioverclock/target") == root@remembered-target ]]
)

if XDG_CONFIG_HOME="$SAVED_CONFIG/empty" "$ROOT/autopioverclock" overclock </dev/null >/dev/null 2>&1; then
    echo 'targetless overclock accepted an absent saved target noninteractively' >&2
    exit 1
fi

if "$ROOT/autopioverclock" overclock tron --config fixture.conf >/dev/null 2>&1; then
    echo 'simple overclock accepted an advanced custom plan' >&2
    exit 1
fi
if "$ROOT/autopioverclock" prepare tron --edge-cpu-24h >/dev/null 2>&1; then
    echo 'prepare accepted the optional edge-tuning flag' >&2
    exit 1
fi
if "$ROOT/autopioverclock" prepare tron --config fixture.conf >/dev/null 2>&1; then
    echo 'simple prepare accepted an advanced custom plan' >&2
    exit 1
fi
if "$ROOT/autopioverclock" reset tron --yes >/dev/null 2>&1; then
    echo 'reset accepted an unrelated tuning confirmation flag' >&2
    exit 1
fi

help_output=$("$ROOT/autopioverclock" --help)
for command_line in \
    'autopioverclock prepare [TARGET]' \
    'autopioverclock overclock [TARGET]' \
    'autopioverclock reset [TARGET]'; do
    grep -Fq "$command_line" <<< "$help_output"
done

if grep -Eq -- '--(config|mode|run-id|install-missing|repair-watchdogs|dry-run|yes|redact)[[:space:]]' <<< "$help_output"; then
    echo 'primary help exposed advanced workflow switches' >&2
    exit 1
fi

printf 'test_simple_cli: PASS\n'
