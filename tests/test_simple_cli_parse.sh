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
    [[ $APO_REPAIR_WATCHDOGS == 1 ]]
    [[ $APO_AUTO_PREPARE == 1 ]]
    [[ $APO_AUTO_APPLY == 0 ]]
)

parse_fixture run overclock overclock overclock tron
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock tron --cpu-start-at 3000 --gpu-start-at 1150
    [[ $APO_COMMAND == run ]]
    [[ $APO_AUTO_APPLY == 1 ]]
    [[ $APO_ASSUME_YES == 1 ]]
    [[ $APO_EDGE_CPU_24H == 0 ]]
    [[ $APO_SWEEP_DOMAIN == all ]]
    [[ $APO_CPU_START_AT == 3000 && $APO_GPU_START_AT == 1150 ]]
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
    apo_parse_cli overclock tron --cpu-only --cpu-start-at 3150
    [[ $APO_SWEEP_DOMAIN == cpu && $APO_CPU_START_AT == 3150 && -z $APO_GPU_START_AT ]]
)
(
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli overclock tron --gpu-only --gpu-start-at 1150
    [[ $APO_SWEEP_DOMAIN == gpu && $APO_GPU_START_AT == 1150 && -z $APO_CPU_START_AT ]]
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
    '--final-hours 169' \
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
    '--cpu-start-at 3010' \
    '--gpu-start-at 1160' \
    '--cpu-only --gpu-start-at 1150' \
    '--gpu-only --cpu-start-at 3000' \
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
    apo_parse_cli prepare tron --cpu-start-at 3000
) >/dev/null 2>&1; then
    echo 'prepare accepted an overclock starting-clock option' >&2
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

parse_fixture reset reset reset reset tron
if (
    export APO_CLI_LIBRARY_ONLY=1
    source "$ROOT/autopioverclock"
    apo_parse_cli tron reset
) >/dev/null 2>&1; then
    echo 'removed TARGET reset order was accepted by the parser' >&2
    exit 1
fi
