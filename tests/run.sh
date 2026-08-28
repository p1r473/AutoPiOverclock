#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TESTS=(
    test_simple_cli.sh
    test_manual_test.sh
    test_progress.sh
    test_install.sh
    test_batocera_watchdog_install.sh
    test_common.sh
    test_config.sh
    test_state_logging.sh
    test_classify.sh
    test_workers.sh
    test_tryboot_lifecycle.sh
    test_watchdogs.sh
    test_selection.sh
    test_resume_progress.sh
    test_interrupted_state.sh
    test_apply_resume.sh
    test_reset.sh
    test_package.sh
    test_public_safety.sh
)
passed=0
for test_script in "${TESTS[@]}"; do
    printf '\n==> %s\n' "$test_script"
    "$ROOT/tests/$test_script"
    passed=$((passed + 1))
done
printf '\nAll %d test scripts passed.\n' "$passed"
