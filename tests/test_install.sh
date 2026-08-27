#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TEMP_DIR=$(mktemp -d)
CACHE_DIR="$ROOT/assets/batocera/__pycache__"
CACHE_CREATED=0
cleanup() {
    rm -rf "$TEMP_DIR"
    if (( CACHE_CREATED == 1 )); then
        rmdir -- "$CACHE_DIR" 2>/dev/null || true
    fi
}
trap cleanup EXIT

if [[ ! -e $CACHE_DIR ]]; then
    mkdir -- "$CACHE_DIR"
    CACHE_CREATED=1
fi

make -C "$ROOT" install DESTDIR="$TEMP_DIR" PREFIX=/usr/local >/dev/null
INSTALLED="$TEMP_DIR/usr/local/bin/autopioverclock"
INSTALLED_ASSETS="$TEMP_DIR/usr/local/lib/autopioverclock/assets/batocera"
[[ -L $INSTALLED ]]
[[ $("$INSTALLED" --version) == "$(<"$ROOT/VERSION")" ]]
[[ -x $TEMP_DIR/usr/local/lib/autopioverclock/autopioverclock ]]
[[ -x $TEMP_DIR/usr/local/lib/autopioverclock/workers/debian-worker.sh ]]
[[ -x $TEMP_DIR/usr/local/lib/autopioverclock/tools/build-batocera-bundle.sh ]]
[[ -x $INSTALLED_ASSETS/AutoPiOverclockWatchdog ]]
[[ -x $INSTALLED_ASSETS/install_watchdog.sh ]]
[[ -x $INSTALLED_ASSETS/watchdog_keeper.py ]]
[[ ! -e $INSTALLED_ASSETS/__pycache__ ]]

printf 'test_install: PASS\n'
