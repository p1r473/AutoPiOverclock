#!/usr/bin/env bash
# Independent fixture subshells intentionally reuse controller variable names.
# shellcheck disable=SC2030,SC2031
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
APO_ROOT=$ROOT
source "$ROOT/lib/common.sh"
source "$ROOT/lib/ssh.sh"

[[ $APO_TRANSIENT_READ_ATTEMPTS == 30 ]]
[[ $APO_TRANSIENT_READ_DELAY_SECONDS == 10 ]]
[[ $APO_PREFLIGHT_SSH_TIMEOUT_SECONDS == 300 ]]

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

# Restore the production stdin wrapper after the string-capture fixture above.
source "$ROOT/lib/ssh.sh"

UPLOAD_TEST_ROOT=$(mktemp -d)
UPLOAD_SOURCE="$UPLOAD_TEST_ROOT/source worker.sh"
UPLOAD_REMOTE_DIRECTORY="$UPLOAD_TEST_ROOT/remote.dir_name-1"
UPLOAD_REMOTE_FILE="$UPLOAD_REMOTE_DIRECTORY/worker-name_1.0.sh"
UPLOAD_EXECUTION_MODE=exact
UPLOAD_WRAPPER=''
trap 'rm -f "$UPLOAD_FIXTURE"; rm -rf "$UPLOAD_TEST_ROOT"' EXIT
printf 'worker bytes with spaces\nand multiple lines\n' > "$UPLOAD_SOURCE"

apo_ssh_exec_stdin() {
    local wrapper=$1
    UPLOAD_WRAPPER=$wrapper
    if [[ $UPLOAD_EXECUTION_MODE == corrupt ]]; then
        printf 'corrupted worker bytes\n' | bash -c "$wrapper"
    else
        bash -c "$wrapper"
    fi
}

APO_REMOTE_IS_ROOT=1
apo_remote_upload_root "$UPLOAD_SOURCE" "$UPLOAD_REMOTE_FILE"
cmp "$UPLOAD_SOURCE" "$UPLOAD_REMOTE_FILE"
[[ $(sha256sum "$UPLOAD_SOURCE" | awk 'NR == 1 {print $1}') == "$(sha256sum "$UPLOAD_REMOTE_FILE" | awk 'NR == 1 {print $1}')" ]]
if [[ $(uname -s) != MINGW* && $(uname -s) != MSYS* ]]; then
    [[ $(stat -c '%a' "$UPLOAD_REMOTE_FILE") == 700 ]]
fi
[[ $UPLOAD_WRAPPER == /bin/bash\ -c\ * ]]
if compgen -G "$UPLOAD_REMOTE_FILE.upload.*" >/dev/null; then
    echo 'temporary upload file remained after successful root upload' >&2
    exit 1
fi

FAKE_BIN="$UPLOAD_TEST_ROOT/fake-bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/sudo" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${1-} == -n ]]
shift
exec "$@"
EOF
chmod 700 "$FAKE_BIN/sudo"
PATH="$FAKE_BIN:$PATH"
APO_REMOTE_IS_ROOT=0
rm -f -- "$UPLOAD_REMOTE_FILE"
apo_remote_upload_root "$UPLOAD_SOURCE" "$UPLOAD_REMOTE_FILE"
cmp "$UPLOAD_SOURCE" "$UPLOAD_REMOTE_FILE"
if [[ $(uname -s) != MINGW* && $(uname -s) != MSYS* ]]; then
    [[ $(stat -c '%a' "$UPLOAD_REMOTE_FILE") == 700 ]]
fi
[[ $UPLOAD_WRAPPER == sudo\ -n\ /bin/bash\ -c\ * ]]

rm -f -- "$UPLOAD_REMOTE_FILE"
UPLOAD_EXECUTION_MODE=corrupt
APO_TRANSIENT_READ_ATTEMPTS=3
APO_TRANSIENT_READ_DELAY_SECONDS=0
if apo_remote_upload_root "$UPLOAD_SOURCE" "$UPLOAD_REMOTE_FILE" 2>"$UPLOAD_TEST_ROOT/corrupt.err"; then
    echo 'corrupted upload stream was accepted' >&2
    exit 1
fi
[[ ! -e $UPLOAD_REMOTE_FILE ]]
if compgen -G "$UPLOAD_REMOTE_FILE.upload.*" >/dev/null; then
    echo 'temporary upload file remained after failed hash verification' >&2
    exit 1
fi
if grep -q 'unbound variable' "$UPLOAD_TEST_ROOT/corrupt.err"; then
    echo 'upload wrapper still failed with an unbound variable' >&2
    exit 1
fi
rm -rf -- "$UPLOAD_TEST_ROOT"

# Safe scalar, exact-file, boot-ID, and tryboot reads all survive many
# consecutive transport failures. Failed exact-file attempts never leak their
# partial bytes into the accepted output.
(
    APO_TRANSIENT_READ_ATTEMPTS=30
    APO_TRANSIENT_READ_DELAY_SECONDS=0
    SSH_ATTEMPT_FILE=$(mktemp)
    READ_RESULT=$(mktemp)
    trap 'rm -f "$SSH_ATTEMPT_FILE" "$READ_RESULT"' EXIT
    apo_ssh_exec() {
        printf x >> "$SSH_ATTEMPT_FILE"
        (( $(wc -c < "$SSH_ATTEMPT_FILE") == 30 )) || return 255
        printf ready
    }
    apo_ssh_read 'printf ready' > "$READ_RESULT"
    [[ $(cat "$READ_RESULT") == ready ]]
    [[ $(wc -c < "$SSH_ATTEMPT_FILE") == 30 ]]
)
(
    APO_TRANSIENT_READ_ATTEMPTS=30
    APO_TRANSIENT_READ_DELAY_SECONDS=0
    READ_ATTEMPTS=0
    READ_OUTPUT=$(mktemp)
    EXPECTED_OUTPUT=$(mktemp)
    trap 'rm -f "$READ_OUTPUT" "$EXPECTED_OUTPUT"' EXIT
    printf 'complete\n\n' > "$EXPECTED_OUTPUT"
    apo_ssh_exec() {
        READ_ATTEMPTS=$((READ_ATTEMPTS + 1))
        if (( READ_ATTEMPTS < 30 )); then printf 'partial'; return 255; fi
        printf 'complete\n\n'
    }
    apo_ssh_read_file "$READ_OUTPUT" 'fixture-read'
    cmp "$EXPECTED_OUTPUT" "$READ_OUTPUT"
    [[ $READ_ATTEMPTS == 30 ]]
)
(
    APO_TRANSIENT_READ_ATTEMPTS=30
    APO_TRANSIENT_READ_DELAY_SECONDS=0
    BOOT_READ_FILE=$(mktemp)
    BOOT_RESULT=$(mktemp)
    trap 'rm -f "$BOOT_READ_FILE" "$BOOT_RESULT"' EXIT
    apo_ssh_exec() {
        printf x >> "$BOOT_READ_FILE"
        (( $(wc -c < "$BOOT_READ_FILE") == 30 )) || return 255
        printf '01234567-89ab-cdef-0123-456789abcdef\n'
    }
    apo_remote_boot_id > "$BOOT_RESULT"
    [[ $(cat "$BOOT_RESULT") == 01234567-89ab-cdef-0123-456789abcdef ]]
    [[ $(wc -c < "$BOOT_READ_FILE") == 30 ]]
)
(
    APO_TRANSIENT_READ_ATTEMPTS=30
    APO_TRANSIENT_READ_DELAY_SECONDS=0
    TRYBOOT_READ_FILE=$(mktemp)
    TRYBOOT_RESULT=$(mktemp)
    trap 'rm -f "$TRYBOOT_READ_FILE" "$TRYBOOT_RESULT"' EXIT
    apo_ssh_exec() {
        printf x >> "$TRYBOOT_READ_FILE"
        (( $(wc -c < "$TRYBOOT_READ_FILE") == 30 )) || return 255
        printf '00000000'
    }
    apo_remote_tryboot_flag > "$TRYBOOT_RESULT"
    [[ $(cat "$TRYBOOT_RESULT") == 00000000 ]]
    [[ $(wc -c < "$TRYBOOT_READ_FILE") == 30 ]]
)

# SSH/reboot waits use elapsed wall time, including time spent inside a failed
# connection attempt.  A nominal 10-second timeout must not become four
# 8-second ConnectTimeout attempts plus sleeps.
(
    SECONDS=0
    SSH_ATTEMPTS=0
    apo_ssh_exec() { SSH_ATTEMPTS=$((SSH_ATTEMPTS + 1)); SECONDS=$((SECONDS + 8)); return 1; }
    sleep() { SECONDS=$((SECONDS + $1)); }
    if apo_wait_for_ssh 10; then
        echo 'unreachable SSH fixture unexpectedly succeeded' >&2
        exit 1
    fi
    [[ $SSH_ATTEMPTS == 1 ]]
)
(
    BOOT_ID_ATTEMPT_FILE=$(mktemp)
    trap 'rm -f "$BOOT_ID_ATTEMPT_FILE"' EXIT
    SECONDS=0
    apo_remote_boot_id_once() { printf x >> "$BOOT_ID_ATTEMPT_FILE"; command /bin/sleep 2; return 1; }
    if apo_wait_for_new_boot old-boot 4; then
        echo 'missing reboot fixture unexpectedly succeeded' >&2
        exit 1
    fi
    [[ $(wc -c < "$BOOT_ID_ATTEMPT_FILE") == 1 ]]
)

# Every unattended mutating/recovery command keeps observing after its ordinary
# timeout, without issuing another reboot. A returned host is handed back to
# the normal boot/ownership reconciliation path.
APO_STATE_FILE=''
APO_LOG_FILE=''
(
    SECONDS=0
    APO_PUBLIC_COMMAND=overclock
    APO_MUTATING_COMMAND=1
    APO_PERSISTENT_SSH_RECOVERY=1
    RECOVERY_NOTICE_FILE=$(mktemp)
    trap 'rm -f "$RECOVERY_NOTICE_FILE"' EXIT
    SSH_ATTEMPTS=0
    apo_ssh_exec() {
        SSH_ATTEMPTS=$((SSH_ATTEMPTS + 1))
        (( SSH_ATTEMPTS >= 7 ))
    }
    sleep() { SECONDS=$((SECONDS + $1)); }
    apo_wait_for_ssh 1 unattended-recovery-fixture 2> "$RECOVERY_NOTICE_FILE"
    [[ $SSH_ATTEMPTS == 7 ]]
    [[ $(wc -l < "$RECOVERY_NOTICE_FILE") == 2 ]]
    grep -Fxq 'WARNING: The target has not returned to SSH after 1s. The unattended operation remains in safe read-only monitoring and will reconcile the boot automatically when SSH returns; Ctrl-C leaves saved work resumable.' "$RECOVERY_NOTICE_FILE"
    grep -Fxq 'WARNING: SSH returned after extended recovery monitoring; reconciling boot identity, tryboot ownership, normal clocks, and health before continuing.' "$RECOVERY_NOTICE_FILE"
)
(
    SECONDS=0
    APO_PUBLIC_COMMAND=resume
    APO_MUTATING_COMMAND=1
    APO_PERSISTENT_SSH_RECOVERY=1
    SSH_ATTEMPTS=0
    RECOVERY_NOTICE_FILE=$(mktemp)
    trap 'rm -f "$RECOVERY_NOTICE_FILE"' EXIT
    apo_ssh_exec() {
        SSH_ATTEMPTS=$((SSH_ATTEMPTS + 1))
        (( SSH_ATTEMPTS >= 7 ))
    }
    sleep() { SECONDS=$((SECONDS + $1)); }
    apo_wait_for_ssh 1 persistent-resume-fixture 2> "$RECOVERY_NOTICE_FILE"
    [[ $SSH_ATTEMPTS == 7 ]]
    [[ $(wc -l < "$RECOVERY_NOTICE_FILE") == 2 ]]
)
(
    SECONDS=0
    APO_PUBLIC_COMMAND=overclock
    APO_MUTATING_COMMAND=1
    APO_PERSISTENT_SSH_RECOVERY=1
    BOOT_ATTEMPT_FILE=$(mktemp)
    RECOVERY_NOTICE_FILE=$(mktemp)
    trap 'rm -f "$BOOT_ATTEMPT_FILE" "$RECOVERY_NOTICE_FILE"' EXIT
    apo_remote_boot_id_once() {
        printf x >> "$BOOT_ATTEMPT_FILE"
        (( $(wc -c < "$BOOT_ATTEMPT_FILE") >= 7 )) && printf new-boot || return 1
    }
    sleep() { SECONDS=$((SECONDS + $1)); }
    returned_boot=$(apo_wait_for_new_boot old-boot 1 unattended-boot-fixture 2> "$RECOVERY_NOTICE_FILE")
    [[ $returned_boot == new-boot ]]
    [[ $(wc -c < "$BOOT_ATTEMPT_FILE") == 7 ]]
    [[ $(wc -l < "$RECOVERY_NOTICE_FILE") == 2 ]]
    grep -Fxq 'WARNING: The target has not returned to SSH after 1s. The unattended operation remains in safe read-only monitoring and will reconcile the boot automatically when SSH returns; Ctrl-C leaves saved work resumable.' "$RECOVERY_NOTICE_FILE"
    grep -Fxq 'WARNING: SSH returned after extended recovery monitoring; reconciling boot identity, tryboot ownership, normal clocks, and health before continuing.' "$RECOVERY_NOTICE_FILE"
)
(
    SECONDS=0
    APO_PUBLIC_COMMAND=overclock
    APO_MUTATING_COMMAND=1
    APO_PERSISTENT_SSH_RECOVERY=1
    BOOT_ATTEMPT_FILE=$(mktemp)
    RECOVERY_NOTICE_FILE=$(mktemp)
    trap 'rm -f "$BOOT_ATTEMPT_FILE" "$RECOVERY_NOTICE_FILE"' EXIT
    apo_remote_boot_id_once() {
        printf x >> "$BOOT_ATTEMPT_FILE"
        case $(wc -c < "$BOOT_ATTEMPT_FILE") in
            1) printf old-boot ;;
            7) printf new-boot ;;
            *) return 1 ;;
        esac
    }
    sleep() { SECONDS=$((SECONDS + $1)); }
    returned_boot=$(apo_wait_for_new_boot old-boot 4 slow-shutdown-fixture 2> "$RECOVERY_NOTICE_FILE")
    [[ $returned_boot == new-boot ]]
    [[ $(wc -c < "$BOOT_ATTEMPT_FILE") == 7 ]]
    [[ $(wc -l < "$RECOVERY_NOTICE_FILE") == 2 ]]
)

# Reboots invalidate a Debian worker stored under /tmp. The shared reboot
# handshake must not expose a returned boot until the exact local worker has
# been uploaded again for that boot.
(
    source "$ROOT/lib/detect.sh"
    HANDSHAKE_ROOT=$(mktemp -d)
    trap 'rm -rf "$HANDSHAKE_ROOT"' EXIT
    APO_LOCAL_WORKER="$HANDSHAKE_ROOT/local-worker.sh"
    APO_REMOTE_WORKER=/tmp/autopioverclock-fixture/worker.sh
    printf '#!/usr/bin/env bash\nexit 0\n' > "$APO_LOCAL_WORKER"
    UPLOADS=0
    apo_wait_for_new_boot() {
        [[ $2 == 30 ]]
        case $1 in old-boot) printf new-boot ;; new-boot) printf newer-boot ;; *) return 1 ;; esac
    }
    apo_remote_upload_root() {
        [[ $1 == "$APO_LOCAL_WORKER" && $2 == "$APO_REMOTE_WORKER" ]]
        UPLOADS=$((UPLOADS + 1))
    }
    apo_post_reboot_handshake old-boot 30 candidate-boot
    [[ $APO_REBOOT_BOOT_ID == new-boot ]]
    [[ $APO_REBOOT_OBSERVED_BOOT_ID == new-boot ]]
    [[ $APO_REBOOT_HANDSHAKE_STAGE == complete ]]
    [[ $APO_WORKER_BOOT_ID == new-boot && $UPLOADS == 1 ]]

    apo_remote_upload_root() { return 1; }
    if apo_post_reboot_handshake new-boot 30 normal-recovery; then
        echo 'post-reboot handshake accepted a missing worker deployment' >&2
        exit 1
    fi
    [[ $APO_REBOOT_HANDSHAKE_STAGE == worker ]]
    [[ $APO_REBOOT_OBSERVED_BOOT_ID == newer-boot ]]
    [[ $APO_LAST_CLASS == HARNESS_FAILURE ]]
    [[ $APO_LAST_REASON == *'run-isolated worker could not be redeployed'* ]]
)

# An idempotent dependency transaction whose SSH result is repeatedly lost is
# reconciled from fresh discovery and retried up to five times. A protected
# config mismatch is a hard stop on the first observation, never something the
# retry loop can erase.
(
    source "$ROOT/lib/detect.sh"
    DEPENDENCY_ATTEMPT_FILE=$(mktemp)
    trap 'rm -f "$DEPENDENCY_ATTEMPT_FILE"' EXIT
    : > "$DEPENDENCY_ATTEMPT_FILE"
    APO_DRY_RUN=0
    APO_INSTALL_MISSING=1
    APO_PREFLIGHT_SSH_TIMEOUT_SECONDS=300
    APO_PERMANENT_CONFIG_HASH=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    APO_THROTTLE_RUNTIME_BASELINE=throttled=0x0
    DEPENDENCIES_READY=0
    apo_profile_dependencies_ready() { (( DEPENDENCIES_READY == 1 )); }
    apo_dependency_description() { printf fixture; }
    apo_reset_throttle_history() { :; }
    apo_profile_install_dependencies() { printf x >> "$DEPENDENCY_ATTEMPT_FILE"; return 255; }
    apo_wait_for_ssh() { :; }
    apo_remote_boot_id() { printf '01234567-89ab-cdef-0123-456789abcdef'; }
    apo_ensure_worker_for_boot() { :; }
    apo_discovery_capture() {
        APO_DISCOVERY[PERMANENT_HASH]=$APO_PERMANENT_CONFIG_HASH
        APO_DISCOVERY[RECENT_THROTTLED]=throttled=0x0
        if (( $(wc -c < "$DEPENDENCY_ATTEMPT_FILE") == 5 )); then DEPENDENCIES_READY=1; fi
    }
    apo_throttle_clean_relative() { :; }
    apo_context_from_discovery() { :; }
    apo_event() { :; }
    apo_summary_line() { :; }
    apo_transient_read_delay() { :; }
    apo_dependency_preflight
    [[ $(wc -c < "$DEPENDENCY_ATTEMPT_FILE") == 5 ]]
    (( DEPENDENCIES_READY == 1 ))
)
DEPENDENCY_MISMATCH_ATTEMPTS=$(mktemp)
trap 'rm -f "$UPLOAD_FIXTURE"; rm -f "$DEPENDENCY_MISMATCH_ATTEMPTS"' EXIT
: > "$DEPENDENCY_MISMATCH_ATTEMPTS"
if (
    source "$ROOT/lib/detect.sh"
    APO_DRY_RUN=0
    APO_INSTALL_MISSING=1
    APO_PREFLIGHT_SSH_TIMEOUT_SECONDS=300
    APO_PERMANENT_CONFIG_HASH=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    APO_THROTTLE_RUNTIME_BASELINE=throttled=0x0
    apo_profile_dependencies_ready() { return 1; }
    apo_dependency_description() { printf fixture; }
    apo_reset_throttle_history() { :; }
    apo_profile_install_dependencies() { printf x >> "$DEPENDENCY_MISMATCH_ATTEMPTS"; }
    apo_wait_for_ssh() { :; }
    apo_remote_boot_id() { printf '01234567-89ab-cdef-0123-456789abcdef'; }
    apo_ensure_worker_for_boot() { :; }
    apo_discovery_capture() {
        APO_DISCOVERY[PERMANENT_HASH]=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
        APO_DISCOVERY[RECENT_THROTTLED]=throttled=0x0
    }
    apo_throttle_clean_relative() { :; }
    apo_context_from_discovery() { :; }
    apo_event() { :; }
    apo_summary_line() { :; }
    apo_transient_read_delay() { :; }
    apo_dependency_preflight
) >/dev/null 2>&1; then
    echo 'dependency retry accepted protected-config drift' >&2
    exit 1
fi
[[ $(wc -c < "$DEPENDENCY_MISMATCH_ATTEMPTS") == 1 ]]

if (apo_parse_target 'bad user@example-host' >/dev/null 2>&1); then
    echo 'unsafe username was accepted' >&2
    exit 1
fi
printf 'test_common: PASS\n'
