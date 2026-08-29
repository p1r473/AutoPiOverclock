#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

if grep -RInE --exclude-dir=.git --exclude='test_public_safety.sh' '192\.168\.|private-lab-(host|user|service)' "$ROOT"; then
    echo 'private lab identifiers found in public repository' >&2
    exit 1
fi
if grep -RInE --exclude-dir=.git --exclude='test_public_safety.sh' -- 'ProxyJump|find .* -delete|root@192\.' "$ROOT"; then
    echo 'forbidden transport or destructive pattern found' >&2
    exit 1
fi
if grep -RInE --include='*.sh' -- '(^|[[:space:]])path=' "$ROOT"; then
    echo 'lowercase zsh-special variable path was assigned' >&2
    exit 1
fi
grep -q 'command ssh' "$ROOT/lib/ssh.sh"
grep -q -- '-F /dev/null' "$ROOT/lib/ssh.sh"
grep -q 'StrictHostKeyChecking=accept-new' "$ROOT/lib/ssh.sh"
grep -q 'raspbian|debian|ubuntu' "$ROOT/lib/detect.sh"
if grep -q 'ID_LIKE' "$ROOT/lib/detect.sh"; then
    echo 'generic Debian-derived operating systems were accepted through ID_LIKE' >&2
    exit 1
fi
if env APO_ROOT="$ROOT" APO_RUN_ID=safe-fixture-run bash -c \
    'source "$APO_ROOT/lib/common.sh"; source "$APO_ROOT/lib/detect.sh"; apo_load_profile "../../untrusted"' >/dev/null 2>&1; then
    echo 'an untrusted saved profile path was accepted' >&2
    exit 1
fi
for unsafe_run_id in . ..; do
    if env APO_ROOT="$ROOT" APO_RUN_ID="$unsafe_run_id" bash -c \
        'source "$APO_ROOT/lib/common.sh"; source "$APO_ROOT/lib/detect.sh"; apo_load_profile batocera' >/dev/null 2>&1; then
        echo "Batocera profile accepted a special worker-directory run ID: $unsafe_run_id" >&2
        exit 1
    fi
done
grep -q 'case $APO_COMMAND in status|report) return 0' "$ROOT/autopioverclock"
grep -q 'smoke_duration=20' "$ROOT/lib/candidates.sh"
grep -q 'GPU_SMOKE' "$ROOT/lib/candidates.sh"
grep -q 'Existing run files are never deleted' "$ROOT/lib/logging.sh"
if grep -RIn --include='*-worker.sh' 'io_pid=\$(start_io_activity' "$ROOT/workers"; then
    echo 'filesystem exerciser was launched through blocking command substitution' >&2
    exit 1
fi
grep -q 'Requested CPU clock' "$ROOT/workers/debian-worker.sh"
grep -q 'Requested GPU clock' "$ROOT/workers/batocera-worker.sh"
grep -q 'hard_deadline' "$ROOT/workers/debian-worker.sh"
grep -q 'hard_deadline' "$ROOT/workers/batocera-worker.sh"
grep -q '^terminate_child()' "$ROOT/workers/debian-worker.sh"
grep -q '^terminate_child()' "$ROOT/workers/batocera-worker.sh"
if "$ROOT/autopioverclock" resume example-host --dry-run >/dev/null 2>&1; then
    echo 'resume incorrectly accepted --dry-run' >&2
    exit 1
fi
if "$ROOT/autopioverclock" -h >/dev/null 2>&1; then
    echo 'unapproved -h public alias was accepted' >&2
    exit 1
fi
approved_options=$(printf '%s\n' \
    --cpu --edge-cpu-24h --edge-hours --final-hours --gpu --help --identity-file --minutes --no-max-fan \
    --output-dir --qualification-hours --ssh-port --version | LC_ALL=C sort)
documented_options=$(awk '/^Common options:/{capture=1; next} /^Advanced options:/{capture=0} capture' "$ROOT/autopioverclock" |
    grep -oE -- '--[a-z][a-z0-9-]*' | LC_ALL=C sort -u)
[[ $documented_options == "$approved_options" ]] || {
    printf 'primary CLI options differ from the simple-workflow whitelist\nexpected:\n%s\nactual:\n%s\n' "$approved_options" "$documented_options" >&2
    exit 1
}
grep -Fq 'SHELLCHECK_SHALLOW_FILES := tests/test_simple_cli_parse.sh tests/test_simple_cli_resume.sh tests/test_simple_cli_edge.sh tests/test_simple_cli_manual.sh' "$ROOT/Makefile"
if grep -Eq '^[[:space:]]*external-sources=true' "$ROOT/.shellcheckrc"; then
    echo 'the global ShellCheck config defeats the bounded CLI-fixture lint policy' >&2
    exit 1
fi
for advanced_option in --config --dry-run --install-missing --mode --redact --repair-watchdogs --run-id --yes; do
    grep -Fq -- "$advanced_option" "$ROOT/docs/cli.md" || {
        echo "advanced option is implemented but missing from docs/cli.md: $advanced_option" >&2
        exit 1
    }
done
if grep -RIn --include='*.sh' 'apo_wait_for_new_boot' "$ROOT/lib" "$ROOT/profiles" | grep -v 'lib/detect.sh' | grep -v 'lib/ssh.sh'; then
    echo 'a production reboot path bypasses the shared worker-redeployment handshake' >&2
    exit 1
fi
if "$ROOT/autopioverclock" prepare example-host --edge-cpu-24h --config fixture.conf >/dev/null 2>&1; then
    echo '--edge-cpu-24h accepted an explicit configuration' >&2
    exit 1
fi

while IFS= read -r script_file; do bash -n "$script_file"; done < <(find "$ROOT" -type f \( -name '*.sh' -o -name autopioverclock \) -not -path '*/.git/*' | LC_ALL=C sort)
for required in README.md LICENSE SECURITY.md CONTRIBUTING.md CHANGELOG.md .github/workflows/ci.yml tools/build-batocera-bundle.sh; do [[ -f "$ROOT/$required" ]]; done
grep -q 'git -C "$ROOT" archive' "$ROOT/tools/package.sh"
grep -q 'status --porcelain --untracked-files=normal' "$ROOT/tools/package.sh"
grep -q "trap 'exit 143' TERM" "$ROOT/autopioverclock"
grep -q '^/dist export-ignore$' "$ROOT/.gitattributes"
for fixture in debian-pass.log batocera-canvas-failure.log undervoltage.log root-usb-reset.log ext4-error.log kernel-fatal-signatures.log black-null-display.log missing-audio.log interrupted-tryboot.state; do
    [[ -f "$ROOT/tests/fixtures/$fixture" ]]
done
for worker_file in "$ROOT/workers/debian-worker.sh" "$ROOT/workers/batocera-worker.sh"; do
    grep -q 'emit_data TRYBOOT_HASH' "$worker_file"
    grep -q 'emit_data TRYBOOT_RESERVATION_HASH' "$worker_file"
    grep -q 'emit_data TRYBOOT_QUARANTINE' "$worker_file"
    grep -q 'set -o noclobber' "$worker_file"
    grep -q 'installed_hash.*expected_tryboot_hash' "$worker_file"
    grep -q 'emit_data TRYBOOT_EXISTS' "$worker_file"
    grep -q 'emit_data TRYBOOT_TYPE' "$worker_file"
    grep -q 'plan-candidate) cmd_plan_candidate' "$worker_file"
    grep -q 'verify-tryboot) cmd_verify_tryboot' "$worker_file"
    grep -q 'clear-tryboot).*cmd_clear_tryboot' "$worker_file"
    grep -q 'mv -n -- "$tryboot_config" "$quarantine_path"' "$worker_file"
    grep -q '^run_with_mutation_lock()' "$worker_file"
    grep -q 'prepare-candidate) run_with_mutation_lock' "$worker_file"
    grep -q 'trigger-tryboot) run_with_mutation_lock' "$worker_file"
    grep -q 'reboot-normal) run_with_mutation_lock' "$worker_file"
    if grep -Eq 'mv[[:space:]]+-f.*(tryboot_config|quarantine_path)' "$worker_file"; then
        echo 'tryboot lifecycle contains a force-overwrite move' >&2
        exit 1
    fi
    grep -q 'active_cpu=$(active_config_value arm_freq)' "$worker_file"
    if grep -q 'active_cpu=$(active_config_value arm_freq "$boot_config")' "$worker_file"; then
        echo 'active clock health fell back to raw conditional config text' >&2
        exit 1
    fi
    if grep -q 'sync "$tryboot_config".*|| true' "$worker_file"; then
        echo 'tryboot durability sync failure was suppressed' >&2
        exit 1
    fi
done
if (
    APO_ROOT=$ROOT
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/config.sh"
    source "$ROOT/lib/detect.sh"
    apo_config_defaults
    # This rejection fixture is intentionally isolated.
    # shellcheck disable=SC2030
    APO_COMMAND=run
    # shellcheck disable=SC2030
    APO_DRY_RUN=0
    APO_MODE_EFFECTIVE=headless
    APO_DISCOVERY=(
        [BOOT_CONFIG]=/boot/config.txt
        [TRYBOOT_CONFIG]=/boot/tryboot.txt
        [TRYBOOT_EXISTS]=1
        [TRYBOOT_TYPE]=regular
        [TRYBOOT_HASH]=$(printf 'a%.0s' {1..64})
        [BOOT_MOUNT]=/boot
        [GPU_KEY]=v3d_freq
        [NORMAL_CPU]=2400
        [NORMAL_GPU]=960
        [NORMAL_VOLTAGE]=0
        [PERMANENT_HASH]=$(printf 'b%.0s' {1..64})
    )
    apo_context_from_discovery
) >/dev/null 2>&1; then
    echo 'live run accepted a pre-existing tryboot file' >&2
    exit 1
fi

graphical_audio_context() {
    local profile=$1 audio_baseline=$2 audio_match=$3
    local APO_COMMAND=prepare APO_DRY_RUN=0
    (
        APO_ROOT=$ROOT
        source "$ROOT/lib/common.sh"
        source "$ROOT/lib/config.sh"
        source "$ROOT/lib/detect.sh"
        apo_config_defaults
        APO_PROFILE=$profile
        APO_MODE_EFFECTIVE=graphical
        APO_CFG[AUDIO_SINK_MATCH]=$audio_match
        APO_DISCOVERY=(
            [BOOT_CONFIG]=/boot/config.txt
            [TRYBOOT_CONFIG]=/boot/tryboot.txt
            [TRYBOOT_EXISTS]=0
            [TRYBOOT_TYPE]=absent
            [TRYBOOT_HASH]=unavailable
            [BOOT_MOUNT]=/boot
            [GPU_KEY]=v3d_freq
            [NORMAL_CPU]=2400
            [NORMAL_GPU]=960
            [NORMAL_VOLTAGE]=0
            [PERMANENT_HASH]=$(printf 'b%.0s' {1..64})
            [DISPLAY_BASELINE]='connector=card1-HDMI-A-1;mode=1280x800;enabled=enabled'
            [AUDIO_BASELINE]="$audio_baseline"
        )
        apo_context_from_discovery
    )
}

graphical_audio_context debian fixture-audio '' >/dev/null
if graphical_audio_context debian '' '' >/dev/null 2>&1; then
    echo 'Debian graphical mode accepted a missing automatic audio baseline' >&2
    exit 1
fi
if graphical_audio_context batocera '' '' >/dev/null 2>&1; then
    echo 'Batocera graphical mode accepted a missing audio baseline' >&2
    exit 1
fi
if grep -Fq 'skip default-sink identity checks' "$ROOT/lib/detect.sh"; then
    echo 'Debian graphical preparation still documents skipped audio validation' >&2
    exit 1
fi
(
    APO_ROOT=$ROOT
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/detect.sh"
    APO_MODE_REQUESTED=auto
    APO_DISCOVERY=([DISPLAY_PRESENT]=0 [DISPLAY_CONNECTED]=0 [AUDIO_BASELINE]='')
    apo_choose_mode
    [[ $APO_MODE_EFFECTIVE == headless ]]
)
printf 'test_public_safety: PASS\n'
