#!/usr/bin/env python3
"""Project-owned Batocera hardware/network watchdog keeper."""

from __future__ import annotations

import array
import fcntl
import ipaddress
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time


WDIOC_SETTIMEOUT = 0xC0045706
MANAGED_MARKER = "AUTOPIOVERCLOCK MANAGED BATOCERA WATCHDOG"
ALLOWED_KEYS = {
    "TARGET",
    "DEVICE_TIMEOUT_SECONDS",
    "FEED_INTERVAL_SECONDS",
    "CHECK_INTERVAL_SECONDS",
    "PING_TIMEOUT_SECONDS",
    "STARTUP_GRACE_SECONDS",
    "FAILURE_WINDOW_SECONDS",
    "MAX_REBOOTS",
    "REBOOT_WINDOW_SECONDS",
}


def read_config(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    text = path.read_text(encoding="ascii")
    if MANAGED_MARKER not in text:
        raise ValueError("watchdog config lacks the project ownership marker")
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        key, separator, value = line.partition("=")
        if not separator or key not in ALLOWED_KEYS or key in values:
            raise ValueError(f"invalid watchdog config line: {raw_line!r}")
        values[key] = value
    if set(values) != ALLOWED_KEYS:
        raise ValueError("watchdog config is incomplete")
    ipaddress.IPv4Address(values["TARGET"])
    for key in ALLOWED_KEYS - {"TARGET"}:
        number = int(values[key], 10)
        if number <= 0 or number > 86400:
            raise ValueError(f"invalid positive watchdog value for {key}")
    if int(values["FEED_INTERVAL_SECONDS"]) >= int(values["DEVICE_TIMEOUT_SECONDS"]):
        raise ValueError("feed interval must be shorter than device timeout")
    return values


class Keeper:
    def __init__(self, config_path: Path) -> None:
        config = read_config(config_path)
        self.target = config["TARGET"]
        self.device_timeout = int(config["DEVICE_TIMEOUT_SECONDS"])
        self.feed_interval = int(config["FEED_INTERVAL_SECONDS"])
        self.check_interval = int(config["CHECK_INTERVAL_SECONDS"])
        self.ping_timeout = int(config["PING_TIMEOUT_SECONDS"])
        self.startup_grace = int(config["STARTUP_GRACE_SECONDS"])
        self.failure_window = int(config["FAILURE_WINDOW_SECONDS"])
        self.max_reboots = int(config["MAX_REBOOTS"])
        self.reboot_window = int(config["REBOOT_WINDOW_SECONDS"])
        self.root = config_path.parent
        self.log_path = self.root / "watchdog.log"
        self.history_path = self.root / "network-reboot-history"
        self.stop_requested = False
        self.fd = -1
        self.ping_binary = shutil.which("ping")
        if not self.ping_binary:
            raise RuntimeError("ping is unavailable")

    def log(self, message: str) -> None:
        self.root.mkdir(parents=True, exist_ok=True)
        if self.log_path.exists() and self.log_path.stat().st_size > 1_048_576:
            rotated = self.log_path.with_suffix(".log.1")
            try:
                rotated.unlink()
            except FileNotFoundError:
                pass
            self.log_path.replace(rotated)
        timestamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        with self.log_path.open("a", encoding="utf-8") as handle:
            handle.write(f"{timestamp} {message}\n")
            handle.flush()
            os.fsync(handle.fileno())

    def request_stop(self, _signum: int, _frame: object) -> None:
        self.stop_requested = True

    def open_watchdog(self) -> None:
        device = None
        for candidate in (Path("/dev/watchdog0"), Path("/dev/watchdog")):
            try:
                if stat.S_ISCHR(candidate.stat().st_mode):
                    device = candidate
                    break
            except FileNotFoundError:
                continue
        if device is None:
            raise RuntimeError("no watchdog character device is present")
        self.fd = os.open(device, os.O_WRONLY | os.O_CLOEXEC)
        timeout_value = array.array("i", [self.device_timeout])
        fcntl.ioctl(self.fd, WDIOC_SETTIMEOUT, timeout_value, True)
        if timeout_value[0] <= 0 or self.feed_interval >= timeout_value[0]:
            raise RuntimeError("watchdog driver rejected the safe runtime timeout")
        self.device_timeout = int(timeout_value[0])
        self.log(f"armed {device} timeout={self.device_timeout}s target={self.target}")

    def feed(self) -> None:
        os.write(self.fd, b"\0")

    def ping(self) -> bool:
        try:
            result = subprocess.run(
                [self.ping_binary, "-c", "1", "-W", str(self.ping_timeout), self.target],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=self.ping_timeout + 3,
                check=False,
            )
        except (OSError, subprocess.SubprocessError):
            return False
        return result.returncode == 0

    def recent_reboots(self, now: int) -> list[int]:
        values: list[int] = []
        try:
            lines = self.history_path.read_text(encoding="ascii").splitlines()
        except FileNotFoundError:
            return values
        for line in lines:
            if line.isdigit():
                timestamp = int(line, 10)
                if timestamp > now or now - timestamp <= self.reboot_window:
                    values.append(timestamp)
        return values

    def write_history(self, values: list[int]) -> None:
        temporary_path: Path | None = None
        try:
            with tempfile.NamedTemporaryFile(
                mode="w",
                encoding="ascii",
                dir=self.root,
                prefix=f".{self.history_path.name}.",
                delete=False,
            ) as handle:
                temporary_path = Path(handle.name)
                for value in values:
                    handle.write(f"{value}\n")
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary_path, self.history_path)
            temporary_path = None
        finally:
            if temporary_path is not None:
                try:
                    temporary_path.unlink()
                except FileNotFoundError:
                    pass
        directory_fd = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)

    def clear_history(self) -> None:
        try:
            self.history_path.unlink()
        except FileNotFoundError:
            return

    def starve_for_reboot(self) -> None:
        self.log("network failure window expired; stopping watchdog feeds for hardware recovery")
        while not self.stop_requested:
            time.sleep(self.feed_interval)

    def recovery_reboot_allowed(self, now: int) -> bool:
        history = self.recent_reboots(now)
        if len(history) >= self.max_reboots:
            return False
        history.append(now)
        try:
            self.write_history(history)
        except OSError as error:
            self.log(f"could not persist reboot-loop evidence; recovery reboot suppressed: {error}")
            return False
        return True

    def feed_with_recovery_suppressed(self) -> None:
        while not self.stop_requested:
            self.feed()
            time.sleep(self.feed_interval)

    def run(self) -> None:
        self.open_watchdog()
        started = time.monotonic()
        next_check = started + self.startup_grace
        failure_started: float | None = None
        suppression_logged = False
        while not self.stop_requested:
            now_mono = time.monotonic()
            if now_mono >= next_check:
                if self.ping():
                    if failure_started is not None or suppression_logged:
                        self.log(f"network target {self.target} is reachable; reboot suppression history cleared")
                    failure_started = None
                    suppression_logged = False
                    self.clear_history()
                else:
                    if failure_started is None:
                        failure_started = now_mono
                        self.log(f"network target {self.target} is unreachable; starting failure window")
                    if now_mono - failure_started >= self.failure_window:
                        now_epoch = int(time.time())
                        if not self.recovery_reboot_allowed(now_epoch):
                            if not suppression_logged:
                                self.log("network remains unavailable after the bounded reboot limit; continuing feeds to prevent a reboot loop")
                                suppression_logged = True
                        else:
                            self.starve_for_reboot()
                            return
                next_check = now_mono + self.check_interval
            self.feed()
            time.sleep(self.feed_interval)

    def close_cleanly(self) -> None:
        if self.fd < 0:
            return
        try:
            os.write(self.fd, b"V")
        finally:
            os.close(self.fd)
            self.fd = -1
        self.log("watchdog disarmed after an explicit service stop")


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: watchdog_keeper.py CONFIG", file=sys.stderr)
        return 2
    keeper = Keeper(Path(sys.argv[1]))
    signal.signal(signal.SIGTERM, keeper.request_stop)
    signal.signal(signal.SIGINT, keeper.request_stop)
    signal.signal(signal.SIGHUP, keeper.request_stop)
    try:
        keeper.run()
    except Exception as error:  # fail toward hardware recovery once armed
        keeper.log(f"keeper failure: {error}")
        if keeper.fd >= 0:
            now_epoch = int(time.time())
            if keeper.recovery_reboot_allowed(now_epoch):
                keeper.starve_for_reboot()
            else:
                keeper.log("keeper recovery reboot suppressed by the persistent loop limit")
                keeper.feed_with_recovery_suppressed()
        return 1
    finally:
        if keeper.stop_requested:
            keeper.close_cleanly()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
