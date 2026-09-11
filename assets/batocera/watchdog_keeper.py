#!/usr/bin/env python3
"""Project-owned Batocera hardware/network watchdog keeper."""

from __future__ import annotations

import array
import fcntl
import hashlib
import ipaddress
import os
from pathlib import Path
import secrets
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import uuid


WDIOC_SETTIMEOUT = 0xC0045706
MANAGED_MARKER = "AUTOPIOVERCLOCK MANAGED BATOCERA WATCHDOG"
EVENT_MARKER = "AUTOPIOVERCLOCK NETWORK WATCHDOG EVENT V1"
SERVICE_PATH = Path("/userdata/system/services/AutoPiOverclockWatchdog")
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
        self.config_path = config_path
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
        self.pending_path = self.root / "pending-network-reboot"
        self.event_path = self.root / "last-network-reboot"
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
        self.atomic_write(self.history_path, "".join(f"{value}\n" for value in values))

    def atomic_write(self, path: Path, content: str) -> None:
        temporary_path: Path | None = None
        try:
            with tempfile.NamedTemporaryFile(
                mode="w",
                encoding="ascii",
                dir=self.root,
                prefix=f".{path.name}.",
                delete=False,
            ) as handle:
                temporary_path = Path(handle.name)
                handle.write(content)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary_path, path)
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

    @staticmethod
    def file_sha256(path: Path) -> str:
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            while chunk := handle.read(1_048_576):
                digest.update(chunk)
        return digest.hexdigest()

    def event_content(
        self, event_id: str, source_boot_id: str, failure_epoch: int, request_epoch: int,
    ) -> str:
        return (
            f"# {EVENT_MARKER}\n"
            "FORMAT=1\n"
            f"EVENT_ID={event_id}\n"
            f"SOURCE_BOOT_ID={source_boot_id}\n"
            f"TARGET={self.target}\n"
            f"FAILURE_STARTED_EPOCH={failure_epoch}\n"
            f"REBOOT_REQUESTED_EPOCH={request_epoch}\n"
            f"CONFIG_SHA256={self.file_sha256(self.config_path)}\n"
            f"KEEPER_SHA256={self.file_sha256(Path(__file__))}\n"
            f"SERVICE_SHA256={self.file_sha256(SERVICE_PATH)}\n"
            "REASON=TARGET_UNREACHABLE\n"
        )

    def write_network_reboot_event(self, now_epoch: int, failure_started: float) -> str:
        source_boot_id = Path("/proc/sys/kernel/random/boot_id").read_text(encoding="ascii").strip()
        if str(uuid.UUID(source_boot_id)) != source_boot_id.lower():
            raise RuntimeError("current boot ID is malformed")
        event_id = secrets.token_hex(16)
        failure_started_epoch = now_epoch - max(0, int(time.monotonic() - failure_started))
        self.atomic_write(
            self.pending_path,
            self.event_content(event_id, source_boot_id, failure_started_epoch, now_epoch),
        )
        self.log(
            "network_reboot_prepared "
            f"event_id={event_id} source_boot_id={source_boot_id} "
            f"target={self.target} requested_epoch={now_epoch}"
        )
        return event_id

    def reconcile_pending_event(self) -> None:
        if not self.pending_path.exists():
            return
        if self.pending_path.is_symlink() or not self.pending_path.is_file():
            self.log("pending network reboot evidence is not a regular file; attribution disabled")
            return
        try:
            values: dict[str, str] = {}
            marker_count = 0
            allowed = {
                "FORMAT", "EVENT_ID", "SOURCE_BOOT_ID", "TARGET",
                "FAILURE_STARTED_EPOCH", "REBOOT_REQUESTED_EPOCH",
                "CONFIG_SHA256", "KEEPER_SHA256", "SERVICE_SHA256", "REASON",
            }
            for raw_line in self.pending_path.read_text(encoding="ascii").splitlines():
                if raw_line == f"# {EVENT_MARKER}":
                    marker_count += 1
                    continue
                if not raw_line:
                    continue
                if raw_line.startswith("#") or "=" not in raw_line:
                    raise ValueError("event contains unsupported content")
                key, value = raw_line.split("=", 1)
                if key not in allowed or key in values or not value:
                    raise ValueError("event contains an unknown, duplicate, or empty key")
                values[key] = value
            if marker_count != 1 or values.get("FORMAT") != "1" or set(values) != allowed:
                raise ValueError("event ownership is malformed")
            source_boot_id = values["SOURCE_BOOT_ID"]
            event_id = values["EVENT_ID"]
            request_epoch = values["REBOOT_REQUESTED_EPOCH"]
            current_boot_id = Path("/proc/sys/kernel/random/boot_id").read_text(encoding="ascii").strip()
            if str(uuid.UUID(source_boot_id)) != source_boot_id.lower():
                raise ValueError("event source boot ID is malformed")
            if len(event_id) != 32 or any(character not in "0123456789abcdef" for character in event_id):
                raise ValueError("event ID is malformed")
            if values["TARGET"] != self.target or not request_epoch.isdigit():
                raise ValueError("event target or timestamp is malformed")
            failure_epoch = values["FAILURE_STARTED_EPOCH"]
            if not failure_epoch.isdigit() or int(failure_epoch, 10) > int(request_epoch, 10):
                raise ValueError("event failure window is malformed")
            hashes = {
                "CONFIG_SHA256": self.file_sha256(self.config_path),
                "KEEPER_SHA256": self.file_sha256(Path(__file__)),
                "SERVICE_SHA256": self.file_sha256(SERVICE_PATH),
            }
            for key, actual_hash in hashes.items():
                value = values[key]
                if len(value) != 64 or any(character not in "0123456789abcdef" for character in value):
                    raise ValueError("event asset hash is malformed")
                if value != actual_hash:
                    raise ValueError("event asset hash no longer matches")
            if values["REASON"] != "TARGET_UNREACHABLE":
                raise ValueError("event reason is malformed")
            if source_boot_id == current_boot_id:
                self.pending_path.unlink()
                self.log("discarded same-boot pending network reboot evidence; attribution disabled")
                return
            now_epoch = int(time.time())
            uptime_seconds = int(float(Path("/proc/uptime").read_text(encoding="ascii").split()[0]))
            boot_epoch = now_epoch - uptime_seconds
            requested = int(request_epoch, 10)
            if requested < boot_epoch - 120 or requested > boot_epoch + 120:
                self.pending_path.unlink()
                self.log("discarded stale pending network reboot evidence; attribution disabled")
                return
            os.replace(self.pending_path, self.event_path)
            directory_fd = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
            self.log(
                "network_reboot_accepted "
                f"event_id={event_id} source_boot_id={source_boot_id} "
                f"target={self.target} requested_epoch={request_epoch} current_boot_id={current_boot_id}"
            )
        except (KeyError, OSError, UnicodeError, ValueError) as error:
            self.log(f"pending network reboot evidence could not be reconciled: {error}")

    def starve_for_reboot(self, event_id: str | None = None) -> bool:
        if event_id is None:
            self.log("keeper failure requires hardware recovery; stopping watchdog feeds")
            while not self.stop_requested:
                time.sleep(self.feed_interval)
            return True
        else:
            self.log(
                "network_reboot_committed "
                f"event_id={event_id} target={self.target} method=hardware-watchdog-starvation"
            )
        deadline = time.monotonic() + max(60, self.device_timeout * 3)
        while not self.stop_requested and time.monotonic() < deadline:
            time.sleep(self.feed_interval)
        if self.stop_requested:
            return True
        try:
            self.pending_path.unlink()
        except FileNotFoundError:
            pass
        except OSError as error:
            try:
                self.atomic_write(
                    self.pending_path,
                    "# AUTOPIOVERCLOCK REJECTED NETWORK REBOOT EVIDENCE\nFORMAT=REJECTED\n",
                )
                self.log(
                    "hardware watchdog did not reset the target; pending attribution "
                    f"could not be removed but was invalidated: {error}"
                )
            except OSError as invalidate_error:
                self.log(
                    "hardware watchdog did not reset the target and pending attribution "
                    f"could not be withdrawn or invalidated: {error}; {invalidate_error}; "
                    "feeds will continue until service stop"
                )
            self.feed_with_recovery_suppressed()
            return True
        self.log(
            "hardware watchdog did not reset the target within its bounded window; "
            "pending attribution was withdrawn and feeds resumed"
        )
        self.feed()
        return False

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
        self.root.mkdir(parents=True, exist_ok=True)
        self.reconcile_pending_event()
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
                        self.log(f"network target {self.target} is reachable; failure window cleared")
                    failure_started = None
                    suppression_logged = False
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
                            event_id = self.write_network_reboot_event(now_epoch, failure_started)
                            if self.starve_for_reboot(event_id):
                                return
                            failure_started = time.monotonic()
                next_check = now_mono + self.check_interval
            self.feed()
            time.sleep(self.feed_interval)

    def close_cleanly(self) -> None:
        try:
            self.pending_path.unlink()
            self.log("pending network reboot evidence removed after an explicit service stop")
        except FileNotFoundError:
            pass
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
