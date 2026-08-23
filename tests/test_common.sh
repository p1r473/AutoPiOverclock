#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
APO_ROOT=$ROOT
source "$ROOT/lib/common.sh"
source "$ROOT/lib/ssh.sh"

apo_parse_target example-host
[[ $APO_REMOTE_USER == "$(id -un)" ]]
[[ $APO_TARGET_HOST == example-host ]]
[[ $APO_REMOTE_TARGET == "$(id -un)@example-host" ]]

apo_parse_target admin@example-host
[[ $APO_REMOTE_USER == admin && $APO_TARGET_HOST == example-host ]]
[[ $(apo_slugify 'admin@host:name') == host-name ]]
apo_is_safe_run_id 20260823-010000-a1b2c3d4e5f60708
for unsafe_run_id in . ..; do
    if apo_is_safe_run_id "$unsafe_run_id"; then
        echo "special path segment was accepted as a run ID: $unsafe_run_id" >&2
        exit 1
    fi
    if "$ROOT/autopioverclock" status example-host --run-id "$unsafe_run_id" >/dev/null 2>&1; then
        echo "CLI accepted a special path segment as a run ID: $unsafe_run_id" >&2
        exit 1
    fi
done
[[ $(apo_select_with_backoff '2700,2800,2900' 1) == 2800 ]]
[[ $(apo_select_with_backoff '2700' 4) == 2700 ]]
[[ $(apo_select_with_backoff '2700' 1 2400) == 2400 ]]
[[ $(apo_exit_code_class "$APO_EXIT_STABILITY") == STABILITY_FAILURE ]]
apo_throttle_reading_valid throttled=0x50000
apo_throttle_active_bits_clear throttled=0x50000
apo_throttle_clean_relative throttled=0x50000 throttled=0x50000
apo_throttle_clean_relative throttled=0x10000 throttled=0x50000
if apo_throttle_active_bits_clear throttled=0x50001; then echo 'active throttle bits were accepted' >&2; exit 1; fi
if apo_throttle_clean_relative throttled=0xD0000 throttled=0x50000; then echo 'new sticky throttle bits were accepted' >&2; exit 1; fi
if apo_throttle_reading_valid garbage; then echo 'malformed throttle telemetry was accepted' >&2; exit 1; fi

UPLOAD_FIXTURE=$(mktemp)
trap 'rm -f "$UPLOAD_FIXTURE"' EXIT
printf 'verified worker bytes' > "$UPLOAD_FIXTURE"
REMOTE_UPLOAD_COMMAND=''
REMOTE_UPLOAD_BYTES=''
apo_remote_root_stdin() { REMOTE_UPLOAD_COMMAND=$1; REMOTE_UPLOAD_BYTES=$(cat); }
apo_remote_upload_root "$UPLOAD_FIXTURE" /remote/bin/worker.sh
[[ $REMOTE_UPLOAD_BYTES == 'verified worker bytes' ]]
[[ $REMOTE_UPLOAD_COMMAND == *'mktemp "${remote_file}.upload.XXXXXX"'* ]]
[[ $REMOTE_UPLOAD_COMMAND == *'[[ $actual_hash == "$expected_hash" ]]'* ]]
[[ $REMOTE_UPLOAD_COMMAND == *'mv -f -- "$temporary_file" "$remote_file"'* ]]

if (apo_parse_target 'bad user@example-host' >/dev/null 2>&1); then
    echo 'unsafe username was accepted' >&2
    exit 1
fi
printf 'test_common: PASS\n'
