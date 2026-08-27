#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

make -C "$ROOT" install DESTDIR="$TEMP_DIR" PREFIX=/usr/local >/dev/null
INSTALLED="$TEMP_DIR/usr/local/bin/autopioverclock"
[[ -L $INSTALLED ]]
[[ $("$INSTALLED" --version) == "$(<"$ROOT/VERSION")" ]]
[[ -x $TEMP_DIR/usr/local/lib/autopioverclock/autopioverclock ]]
[[ -x $TEMP_DIR/usr/local/lib/autopioverclock/workers/debian-worker.sh ]]
[[ -x $TEMP_DIR/usr/local/lib/autopioverclock/tools/build-batocera-bundle.sh ]]
[[ -x $TEMP_DIR/usr/local/lib/autopioverclock/assets/batocera/install_watchdog.sh ]]

printf 'test_install: PASS\n'
