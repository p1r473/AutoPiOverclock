#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2030,SC2031
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

parse_fixture() {
    local expected_command=$1 expected_origin=$2 expected_public=$3
    shift 3
    (
        export APO_CLI_LIBRARY_ONLY=1
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
    [[ $APO_AUTO_PREPARE == 1 ]]
    [[ $APO_AUTO_APPLY == 0 ]]
)

parse_fixture run overclock overclock overclock tron

# Every operation uses an explicit command.  A bare target is not an undocumented
# alias for the advanced run interface.
if (
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli tron
) >/dev/null 2>&1; then
    echo 'a bare TARGET was accepted as an implicit advanced run' >&2
    exit 1
fi
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock tron
    [[ $APO_FINAL_DURATION_S == 172800 ]]
    [[ $APO_SELECTION_POLICY == adaptive-refined-v1 ]]
    [[ $APO_CPU_RESOLUTION_MHZ == 25 && $APO_GPU_RESOLUTION_MHZ == 25 ]]
    [[ $APO_CPU_SEARCH_DIRECTION == forward && $APO_GPU_SEARCH_DIRECTION == forward ]]
)
for resolution in 1 5 25 50 100; do
    (
        export APO_CLI_LIBRARY_ONLY=1
        source "$ROOT/autopioverclock"
        apo_parse_cli overclock tron --cpu-resolution "$resolution" --gpu-resolution "$resolution"
        [[ $APO_CPU_RESOLUTION_MHZ == "$resolution" && $APO_GPU_RESOLUTION_MHZ == "$resolution" ]]
        [[ $APO_CPU_RESOLUTION_OPTION_SEEN == 1 && $APO_GPU_RESOLUTION_OPTION_SEEN == 1 ]]
        [[ $APO_CPU_SEARCH_DIRECTION == forward && $APO_GPU_SEARCH_DIRECTION == forward ]]
    )
done
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock tron --cpu-min 3003 --cpu-max 3173 --gpu-min 1102 --gpu-max 1187 --cpu-resolution 5 --gpu-resolution 1
    [[ $APO_COMMAND == run ]]
    [[ $APO_AUTO_APPLY == 1 ]]
    [[ $APO_ASSUME_YES == 1 ]]
    [[ $APO_EDGE_CPU_24H == 0 ]]
    [[ $APO_SWEEP_DOMAIN == all ]]
    [[ $APO_CPU_MIN == 3003 && $APO_CPU_MAX == 3173 ]]
    [[ $APO_GPU_MIN == 1102 && $APO_GPU_MAX == 1187 ]]
    [[ $APO_CPU_MAX_REQUESTED == 3173 && $APO_GPU_MAX_REQUESTED == 1187 ]]
    [[ $APO_CPU_RESOLUTION_MHZ == 5 && $APO_GPU_RESOLUTION_MHZ == 1 ]]
    [[ $APO_CPU_SEARCH_DIRECTION == descending && $APO_GPU_SEARCH_DIRECTION == descending ]]
    [[ $APO_USE_HISTORY == 1 && $APO_HISTORY_OPTION_SEEN == 0 ]]
    [[ $APO_MAX_FAN == 1 ]]
    [[ $APO_MODE_REQUESTED == auto ]]
    [[ -z $APO_CONFIG_FILE ]]
)
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock tron --qualification-hours 3 --final-hours 6
    [[ $APO_QUALIFICATION_DURATION_S == 10800 ]]
    [[ $APO_FINAL_DURATION_S == 21600 ]]
    [[ $APO_EDGE_CPU_24H == 0 ]]
    [[ $APO_QUALIFICATION_HOURS_OPTION_SEEN == 1 && $APO_FINAL_HOURS_OPTION_SEEN == 1 ]]
)
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock tron --cpu-only --cpu-min 3150 --cpu-max 3175 --cpu-resolution 5
    [[ $APO_SWEEP_DOMAIN == cpu && $APO_CPU_MIN == 3150 && $APO_CPU_MAX == 3175 && -z $APO_GPU_MIN && -z $APO_GPU_MAX ]]
    [[ $APO_CPU_RESOLUTION_MHZ == 5 && $APO_GPU_RESOLUTION_MHZ == 25 ]]
    [[ $APO_CPU_SEARCH_DIRECTION == descending && $APO_GPU_SEARCH_DIRECTION == forward ]]
)
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock tron --gpu-only --gpu-min 1150 --gpu-max 1175 --gpu-resolution 1
    [[ $APO_SWEEP_DOMAIN == gpu && $APO_GPU_MIN == 1150 && $APO_GPU_MAX == 1175 && -z $APO_CPU_MIN && -z $APO_CPU_MAX ]]
    [[ $APO_CPU_RESOLUTION_MHZ == 25 && $APO_GPU_RESOLUTION_MHZ == 1 ]]
    [[ $APO_CPU_SEARCH_DIRECTION == forward && $APO_GPU_SEARCH_DIRECTION == descending ]]
)
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock tron --no-history
    [[ $APO_USE_HISTORY == 0 && $APO_HISTORY_OPTION_SEEN == 1 ]]
)
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli resume tron --restart-from cpu-qualification --qualification-hours 2 --final-hours 24
    [[ $APO_COMMAND == resume && $APO_RESTART_FROM == cpu-qualification ]]
    [[ $APO_RESTART_FROM_OPTION_SEEN == 1 ]]
    [[ $APO_QUALIFICATION_DURATION_S == 7200 && $APO_FINAL_DURATION_S == 86400 ]]
)
for removed_edge_args in '--edge-hours 24' '--edge-cpu-24h'; do
    if (
        export APO_CLI_LIBRARY_ONLY=1
        source "$ROOT/autopioverclock"
        # Fixed fixture tokens contain no shell metacharacters.
        # shellcheck disable=SC2086
        apo_parse_cli resume tron $removed_edge_args
    ) >/dev/null 2>&1; then
        echo "resume accepted removed edge options: $removed_edge_args" >&2
        exit 1
    fi
done

assert_non_resume_rejects_restart() {
    local command=$1 stderr_file
    shift
    stderr_file="${TMPDIR:-/tmp}/autopioverclock-restart-${command}-$$.err"
    if (
        export APO_CLI_LIBRARY_ONLY=1
        source "$ROOT/autopioverclock"
        apo_parse_cli "$command" tron "$@" --restart-from current
    ) >/dev/null 2>"$stderr_file"; then
        echo "$command accepted --restart-from even though only resume may restart a checkpoint" >&2
        rm -f -- "$stderr_file"
        exit 1
    fi
    grep -Fq -- '--restart-from is valid only with resume TARGET.' "$stderr_file"
    rm -f -- "$stderr_file"
}

# Checkpoint restart is exclusively resume syntax.  Exercise every other
# target command so a future command-specific parser branch cannot admit it.
assert_non_resume_rejects_restart prepare
assert_non_resume_rejects_restart overclock
assert_non_resume_rejects_restart test --cpu 3100 --gpu 1150 --final-hours 48
assert_non_resume_rejects_restart reset
assert_non_resume_rejects_restart run
assert_non_resume_rejects_restart status
assert_non_resume_rejects_restart summary
assert_non_resume_rejects_restart recover
assert_non_resume_rejects_restart restore
assert_non_resume_rejects_restart apply
assert_non_resume_rejects_restart report

if (
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli resume tron --restart-from gpu-sweep
) >/dev/null 2>&1; then
    echo 'resume accepted an unsupported restart checkpoint' >&2
    exit 1
fi
for invalid_duration_args in \
    '--qualification-hours 0' \
    '--final-hours 596524' \
    '--final-hours 18446744073709551617' \
    '--final-hours 000100' \
    '--edge-hours 1.5' \
    '--edge-hours 12 --edge-cpu-24h'; do
    if (
        export APO_CLI_LIBRARY_ONLY=1
        source "$ROOT/autopioverclock"
        # Fixed fixture tokens contain no shell metacharacters.
        # shellcheck disable=SC2086
        apo_parse_cli overclock tron $invalid_duration_args
    ) >/dev/null 2>&1; then
        echo "overclock accepted invalid duration options: $invalid_duration_args" >&2
        exit 1
    fi
done
for invalid_domain_args in \
    '--cpu-only --gpu-only' \
    '--cpu-min 3100 --cpu-max 3075' \
    '--gpu-min 1175 --gpu-max 1150' \
    '--cpu-resolution 0' \
    '--gpu-resolution 0' \
    '--cpu-resolution 1001' \
    '--gpu-resolution 1001' \
    '--cpu-resolution 5.5' \
    '--gpu-resolution nope' \
    '--cpu-resolution 5 --cpu-resolution 25' \
    '--gpu-resolution 5 --gpu-resolution 25' \
    '--cpu-only --gpu-min 1150' \
    '--cpu-only --gpu-max 1175' \
    '--cpu-only --gpu-resolution 5' \
    '--gpu-only --cpu-min 3000' \
    '--gpu-only --cpu-max 3175' \
    '--gpu-only --cpu-resolution 5' \
    '--cpu-start-at 3000' \
    '--gpu-start-at 1150' \
    '--restart-from current' \
    '--restart-from cpu-qualification' \
    '--restart-from gpu-qualification' \
    '--restart-from final' \
    '--cpu-only --restart-from final' \
    '--edge-cpu-24h' \
    '--edge-hours 24'; do
    if (
        export APO_CLI_LIBRARY_ONLY=1
        source "$ROOT/autopioverclock"
        # Fixed fixture tokens contain no shell metacharacters.
        # shellcheck disable=SC2086
        apo_parse_cli overclock tron $invalid_domain_args
    ) >/dev/null 2>&1; then
        echo "overclock accepted an invalid domain/legacy-edge plan: $invalid_domain_args" >&2
        exit 1
    fi
done
if (
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli prepare tron --cpu-min 3000
) >/dev/null 2>&1; then
    echo 'prepare accepted an overclock clock-bound option' >&2
    exit 1
fi
if (
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli prepare tron --no-history
) >/dev/null 2>&1; then
    echo 'prepare accepted the overclock history opt-out' >&2
    exit 1
fi
if (
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli prepare tron --cpu-resolution 5
) >/dev/null 2>&1; then
    echo 'prepare accepted an overclock resolution option' >&2
    exit 1
fi
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock tron --no-max-fan
    [[ $APO_COMMAND == run ]]
    [[ $APO_MAX_FAN == 0 && $APO_MAX_FAN_OPTION_SEEN == 1 ]]
)
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli run tron --no-max-fan --yes
    [[ $APO_COMMAND == run && $APO_MAX_FAN == 0 ]]
)

assert_cli_rejects() {
    local description=$1
    shift
    if (
        export APO_CLI_LIBRARY_ONLY=1
        source "$ROOT/autopioverclock"
        apo_parse_cli "$@"
    ) >/dev/null 2>&1; then
        echo "$description" >&2
        exit 1
    fi
}

# Keep the documented accepted-by contract exact: prepare already grants its
# own prerequisite permissions, new runs do not select old IDs, and --yes is
# meaningful only for the advanced run confirmation.
assert_cli_rejects 'prepare accepted redundant --install-missing' prepare tron --install-missing
assert_cli_rejects 'removed --repair-watchdogs option was accepted' prepare tron --repair-watchdogs
assert_cli_rejects 'prepare accepted irrelevant --yes' prepare tron --yes
assert_cli_rejects 'advanced run accepted a saved --run-id' run tron --run-id 20260901-195530-ad946cde6c24975f
assert_cli_rejects 'public overclock accepted irrelevant --yes' overclock tron --yes
assert_cli_rejects 'exact-pair test accepted irrelevant --yes' test tron --cpu 3100 --gpu 1150 --final-hours 48 --yes
assert_cli_rejects 'resume accepted irrelevant --yes' resume tron --yes
assert_cli_rejects 'status accepted irrelevant --yes' status tron --yes
assert_cli_rejects 'standalone apply accepted --yes despite typed confirmation' apply tron --yes

parse_fixture run test test test tron --cpu 3100 --gpu 1150 --minutes 90
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli test tron --cpu 3100 --gpu 1150 --minutes 90 --no-max-fan
    [[ $APO_COMMAND == run && $APO_ORIGIN_COMMAND == test && $APO_PUBLIC_COMMAND == test ]]
    [[ $APO_MANUAL_TEST == 1 && $APO_MANUAL_CPU == 3100 && $APO_MANUAL_GPU == 1150 ]]
    [[ $APO_MANUAL_MINUTES == 90 && $APO_MANUAL_DURATION_S == 5400 ]]
    [[ $APO_ASSUME_YES == 1 && $APO_AUTO_APPLY == 0 && $APO_MAX_FAN == 0 ]]
)
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli test tron --cpu 3100 --gpu 1150 --final-hours 48
    [[ $APO_COMMAND == run && $APO_ORIGIN_COMMAND == test && $APO_PUBLIC_COMMAND == test ]]
    [[ $APO_MANUAL_MINUTES == 2880 && $APO_MANUAL_DURATION_S == 172800 ]]
    [[ $APO_FINAL_HOURS_OPTION_SEEN == 1 && $APO_AUTO_APPLY == 0 ]]
)
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli test tron --cpu 3100 --gpu 1150 --final-hours 168
    [[ $APO_MANUAL_MINUTES == 10080 && $APO_MANUAL_DURATION_S == 604800 ]]
)
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli test tron --cpu 3100 --gpu 1150 --final-hours 596523
    [[ $APO_MANUAL_MINUTES == 35791380 && $APO_MANUAL_DURATION_S == 2147482800 ]]
)
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli test tron --cpu 3100 --gpu 1150 --minutes 35791380
    [[ $APO_MANUAL_MINUTES == 35791380 && $APO_MANUAL_DURATION_S == 2147482800 ]]
)

parse_fixture reset reset reset reset tron
parse_fixture restore restore '' restore tron
parse_fixture status status '' status tron
parse_fixture summary summary '' summary tron
parse_fixture report report '' report tron
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli restore tron --run-id 20260901-195530-ad946cde6c24975f
    [[ $APO_COMMAND == restore && $APO_ORIGIN_COMMAND == restore ]]
    [[ $APO_SELECTED_RUN_ID == 20260901-195530-ad946cde6c24975f ]]
)
for invalid_restore_args in '--yes' '--dry-run' '--no-max-fan' '--qualification-hours 2' '--gpu-only'; do
    if (
        export APO_CLI_LIBRARY_ONLY=1
        source "$ROOT/autopioverclock"
        # Fixed fixture tokens contain no shell metacharacters.
        # shellcheck disable=SC2086
        apo_parse_cli restore tron $invalid_restore_args
    ) >/dev/null 2>&1; then
        echo "restore accepted invalid options: $invalid_restore_args" >&2
        exit 1
    fi
done
if (
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli tron reset
) >/dev/null 2>&1; then
    echo 'removed TARGET reset order was accepted by the parser' >&2
    exit 1
fi
