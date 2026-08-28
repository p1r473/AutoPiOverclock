#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

for fixture in \
    test_simple_cli_parse.sh \
    test_simple_cli_resume.sh \
    test_simple_cli_edge.sh \
    test_simple_cli_manual.sh; do
    "$ROOT/tests/$fixture"
done

printf 'test_simple_cli: PASS\n'
