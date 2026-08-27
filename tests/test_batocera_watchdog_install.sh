#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

export APO_WATCHDOG_INSTALLER_LIBRARY_ONLY=1
# shellcheck source=../assets/batocera/install_watchdog.sh
source "$ROOT/assets/batocera/install_watchdog.sh"

cat > "$TEMP_DIR/config.txt" <<'EOF'
[all]
dtparam=watchdog
kernel_watchdog_timeout=0
dtoverlay=vc4-kms-v3d
EOF
render_boot_config "$TEMP_DIR/config.txt" "$TEMP_DIR/config.rendered"
grep -Fqx '# AUTOPIOVERCLOCK-WATCHDOG-DISABLED kernel_watchdog_timeout=0' "$TEMP_DIR/config.rendered"
[[ $(grep -c '^kernel_watchdog_timeout=180$' "$TEMP_DIR/config.rendered") == 1 ]]
grep -Fqx 'dtparam=watchdog' "$TEMP_DIR/config.rendered"
grep -Fqx 'dtoverlay=vc4-kms-v3d' "$TEMP_DIR/config.rendered"
render_boot_config "$TEMP_DIR/config.rendered" "$TEMP_DIR/config.rendered-again"
cmp "$TEMP_DIR/config.rendered" "$TEMP_DIR/config.rendered-again"

printf '%s\n' "$WATCHDOG_BLOCK_BEGIN" 'kernel_watchdog_timeout=180' > "$TEMP_DIR/config.malformed"
if render_boot_config "$TEMP_DIR/config.malformed" "$TEMP_DIR/config.should-not-render"; then
    echo 'malformed watchdog block was accepted' >&2
    exit 1
fi

printf '%s\n' 'console=serial0 rootwait watchdog.open_timeout=75 quiet' > "$TEMP_DIR/cmdline.txt"
render_cmdline "$TEMP_DIR/cmdline.txt" "$TEMP_DIR/cmdline.rendered"
[[ $(grep -o 'watchdog.open_timeout=' "$TEMP_DIR/cmdline.rendered" | wc -l) == 1 ]]
grep -Fq 'watchdog.open_timeout=180' "$TEMP_DIR/cmdline.rendered"
! grep -Fq 'watchdog.open_timeout=75' "$TEMP_DIR/cmdline.rendered"
render_cmdline "$TEMP_DIR/cmdline.rendered" "$TEMP_DIR/cmdline.rendered-again"
cmp "$TEMP_DIR/cmdline.rendered" "$TEMP_DIR/cmdline.rendered-again"

cat > "$TEMP_DIR/batocera.conf" <<'EOF'
system.hostname=fixture
system.services=audio_service reverse_lookup_fix
EOF
render_batocera_config "$TEMP_DIR/batocera.conf" "$TEMP_DIR/batocera.rendered"
grep -Fqx 'system.hostname=fixture' "$TEMP_DIR/batocera.rendered"
grep -Fqx 'system.services=audio_service reverse_lookup_fix AutoPiOverclockWatchdog' "$TEMP_DIR/batocera.rendered"
[[ $(grep -c '^[[:space:]]*system[.]services[[:space:]]*=' "$TEMP_DIR/batocera.rendered") == 1 ]]

render_batocera_config "$TEMP_DIR/batocera.rendered" "$TEMP_DIR/batocera.rendered-again"
[[ $(grep -o 'AutoPiOverclockWatchdog' "$TEMP_DIR/batocera.rendered-again" | wc -l) == 1 ]]
cmp "$TEMP_DIR/batocera.rendered" "$TEMP_DIR/batocera.rendered-again"

printf '%s\n' "$SERVICE_BLOCK_END" > "$TEMP_DIR/batocera.malformed"
if render_batocera_config "$TEMP_DIR/batocera.malformed" "$TEMP_DIR/batocera.should-not-render"; then
    echo 'malformed managed service block was accepted' >&2
    exit 1
fi

render_keeper_config "$TEMP_DIR/watchdog.conf" 10.42.0.1
grep -Fqx 'TARGET=10.42.0.1' "$TEMP_DIR/watchdog.conf"
grep -Fqx 'STARTUP_GRACE_SECONDS=180' "$TEMP_DIR/watchdog.conf"
grep -Fqx 'MAX_REBOOTS=3' "$TEMP_DIR/watchdog.conf"
grep -Fqx 'REBOOT_WINDOW_SECONDS=1800' "$TEMP_DIR/watchdog.conf"

python3 - "$ROOT/assets/batocera/watchdog_keeper.py" <<'PY'
import importlib.util
from pathlib import Path
import sys
import tempfile
from unittest import mock

source_path = Path(sys.argv[1])
source = source_path.read_text(encoding="utf-8")
compile(source, sys.argv[1], "exec")
spec = importlib.util.spec_from_file_location("apo_watchdog_keeper", source_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    config = root / "watchdog.conf"
    config.write_text(
        "# AUTOPIOVERCLOCK MANAGED BATOCERA WATCHDOG\n"
        "TARGET=10.42.0.1\n"
        "DEVICE_TIMEOUT_SECONDS=15\n"
        "FEED_INTERVAL_SECONDS=5\n"
        "CHECK_INTERVAL_SECONDS=10\n"
        "PING_TIMEOUT_SECONDS=2\n"
        "STARTUP_GRACE_SECONDS=180\n"
        "FAILURE_WINDOW_SECONDS=180\n"
        "MAX_REBOOTS=3\n"
        "REBOOT_WINDOW_SECONDS=1800\n",
        encoding="ascii",
    )
    with mock.patch.object(module.shutil, "which", return_value="/bin/ping"):
        keeper = module.Keeper(config)
    keeper.history_path.write_text("2000\n", encoding="ascii")
    assert keeper.recent_reboots(1000) == [2000]
    assert keeper.recovery_reboot_allowed(1000)
    assert keeper.recovery_reboot_allowed(1000)
    assert not keeper.recovery_reboot_allowed(1000)
PY
sh -n "$ROOT/assets/batocera/AutoPiOverclockWatchdog"

printf 'test_batocera_watchdog_install: PASS\n'
