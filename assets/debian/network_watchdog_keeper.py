#!/usr/bin/env python3
"""AutoPiOverclock Debian network-liveness companion.

This process never opens or feeds a hardware watchdog. systemd remains the
hardware-watchdog owner. The companion only requests a normal reboot after a
bounded, persistent network-loss decision and writes strict attribution proof.
"""

from __future__ import annotations

import hashlib
import ipaddress
import os
from pathlib import Path
import secrets
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid

MANAGED_MARKER = "AUTOPIOVERCLOCK MANAGED DEBIAN NETWORK WATCHDOG"
EVENT_MARKER = "AUTOPIOVERCLOCK NETWORK WATCHDOG EVENT V1"
KEEPER_PATH = Path("/usr/local/lib/autopioverclock/network-watchdog-keeper.py")
SERVICE_PATH = Path("/etc/systemd/system/autopioverclock-network-watchdog.service")
ALLOWED_KEYS = {
    "TARGET",
    "PING_TIMEOUT_SECONDS",
    "CHECK_INTERVAL_SECONDS",
    "STARTUP_GRACE_SECONDS",
    "FAILURE_WINDOW_SECONDS",
    "MAX_REBOOTS",
    "REBOOT_WINDOW_SECONDS",
}


def read_config(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    marker_count = 0
    for raw_line in path.read_text(encoding="ascii").splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if line == f"# {MANAGED_MARKER}":
            marker_count += 1
            continue
        if line.startswith("#") or "=" not in line:
            raise ValueError("configuration contains unsupported content")
        key, value = line.split("=", 1)
        if key not in ALLOWED_KEYS or key in values or not value:
            raise ValueError("configuration contains an unknown, duplicate, or empty key")
        values[key] = value
    if marker_count != 1 or set(values) != ALLOWED_KEYS:
        raise ValueError("configuration ownership or required keys are invalid")
    ipaddress.IPv4Address(values["TARGET"])
    limits = {
        "PING_TIMEOUT_SECONDS": (1, 30),
        "CHECK_INTERVAL_SECONDS": (1, 300),
        "STARTUP_GRACE_SECONDS": (30, 3600),
        "FAILURE_WINDOW_SECONDS": (30, 3600),
        "MAX_REBOOTS": (1, 10),
        "REBOOT_WINDOW_SECONDS": (300, 86400),
    }
    for key, (minimum, maximum) in limits.items():
        value = int(values[key], 10)
        if not minimum <= value <= maximum:
            raise ValueError(f"{key} is outside its safe range")
    return values


class Keeper:
    def __init__(self, config_path: Path) -> None:
        config = read_config(config_path)
        self.config_path = config_path
        self.target = config["TARGET"]
        self.ping_timeout = int(config["PING_TIMEOUT_SECONDS"])
        self.check_interval = int(config["CHECK_INTERVAL_SECONDS"])
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
        self.reboot_committed = False
        self.ping_binary = shutil.which("ping")
        self.systemctl_binary = shutil.which("systemctl")
        if not self.ping_binary or not self.systemctl_binary:
            raise RuntimeError("ping or systemctl is unavailable")

    @staticmethod
    def file_sha256(path: Path) -> str:
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            while chunk := handle.read(1_048_576):
                digest.update(chunk)
        return digest.hexdigest()

    def atomic_write(self, path: Path, content: str) -> None:
        temporary_path: Path | None = None
        try:
            with tempfile.NamedTemporaryFile(
                mode="w", encoding="ascii", dir=self.root,
                prefix=f".{path.name}.", delete=False,
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

    def log(self, message: str) -> None:
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

    def ping(self) -> bool:
        try:
            result = subprocess.run(
                [self.ping_binary, "-c", "1", "-W", str(self.ping_timeout), self.target],
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL, timeout=self.ping_timeout + 3, check=False,
            )
        except (OSError, subprocess.SubprocessError):
            return False
        return result.returncode == 0

    def recent_reboots(self, now: int) -> list[int]:
        try:
            lines = self.history_path.read_text(encoding="ascii").splitlines()
        except FileNotFoundError:
            return []
        values: list[int] = []
        for line in lines:
            if line.isdigit():
                timestamp = int(line, 10)
                if timestamp > now or now - timestamp <= self.reboot_window:
                    values.append(timestamp)
        return values

    def write_history(self, values: list[int]) -> None:
        self.atomic_write(self.history_path, "".join(f"{value}\n" for value in values))

    def reboot_allowed(self, now: int) -> bool:
        history = self.recent_reboots(now)
        if len(history) >= self.max_reboots:
            return False
        history.append(now)
        try:
            self.write_history(history)
        except OSError as error:
            self.log(f"could not persist reboot-loop evidence; reboot suppressed: {error}")
            return False
        return True

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
            f"KEEPER_SHA256={self.file_sha256(KEEPER_PATH)}\n"
            f"SERVICE_SHA256={self.file_sha256(SERVICE_PATH)}\n"
            "REASON=TARGET_UNREACHABLE\n"
        )

    def reconcile_pending_event(self) -> None:
        if not self.pending_path.exists():
            return
        if self.pending_path.is_symlink() or not self.pending_path.is_file():
            self.log("pending network reboot evidence is not a regular file; attribution disabled")
            return
        try:
            values: dict[str, str] = {}
            marker_count = 0
            for raw_line in self.pending_path.read_text(encoding="ascii").splitlines():
                if raw_line == f"# {EVENT_MARKER}":
                    marker_count += 1
                    continue
                if not raw_line:
                    continue
                if raw_line.startswith("#") or "=" not in raw_line:
                    raise ValueError("event contains unsupported content")
                key, value = raw_line.split("=", 1)
                if key not in {
                    "FORMAT", "EVENT_ID", "SOURCE_BOOT_ID", "TARGET",
                    "FAILURE_STARTED_EPOCH", "REBOOT_REQUESTED_EPOCH",
                    "CONFIG_SHA256", "KEEPER_SHA256", "SERVICE_SHA256", "REASON",
                } or key in values or not value:
                    raise ValueError("event contains an unknown, duplicate, or empty key")
                values[key] = value
            source_boot_id = values["SOURCE_BOOT_ID"]
            event_id = values["EVENT_ID"]
            target = values["TARGET"]
            request_epoch = values["REBOOT_REQUESTED_EPOCH"]
            current_boot_id = Path("/proc/sys/kernel/random/boot_id").read_text(encoding="ascii").strip()
            if marker_count != 1 or values.get("FORMAT") != "1" or len(values) != 10:
                raise ValueError("event ownership is malformed")
            if str(uuid.UUID(source_boot_id)) != source_boot_id.lower():
                raise ValueError("event source boot ID is malformed")
            if len(event_id) != 32 or any(character not in "0123456789abcdef" for character in event_id):
                raise ValueError("event ID is malformed")
            if target != self.target or not request_epoch.isdigit():
                raise ValueError("event target or timestamp is malformed")
            failure_epoch = values["FAILURE_STARTED_EPOCH"]
            if not failure_epoch.isdigit() or int(failure_epoch, 10) > int(request_epoch, 10):
                raise ValueError("event failure window is malformed")
            for key in ("CONFIG_SHA256", "KEEPER_SHA256", "SERVICE_SHA256"):
                value = values[key]
                if len(value) != 64 or any(character not in "0123456789abcdef" for character in value):
                    raise ValueError("event asset hash is malformed")
            if values["CONFIG_SHA256"] != self.file_sha256(self.config_path):
                raise ValueError("event config hash no longer matches")
            if values["KEEPER_SHA256"] != self.file_sha256(KEEPER_PATH):
                raise ValueError("event keeper hash no longer matches")
            if values["SERVICE_SHA256"] != self.file_sha256(SERVICE_PATH):
                raise ValueError("event service hash no longer matches")
            if values["REASON"] != "TARGET_UNREACHABLE":
                raise ValueError("event reason is malformed")
            if source_boot_id == current_boot_id:
                self.pending_path.unlink()
                self.log(
                    "discarded same-boot pending network reboot evidence; "
                    "no reboot attribution was accepted"
                )
                return
            now_epoch = int(time.time())
            uptime_seconds = int(float(Path("/proc/uptime").read_text(encoding="ascii").split()[0]))
            boot_epoch = now_epoch - uptime_seconds
            requested = int(request_epoch, 10)
            if requested < boot_epoch - 300 or requested > boot_epoch + 120:
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
                f"target={target} requested_epoch={request_epoch} current_boot_id={current_boot_id}"
            )
        except (KeyError, OSError, UnicodeError, ValueError) as error:
            self.log(f"pending network reboot evidence could not be reconciled: {error}")

    def discard_uncommitted_stop(self) -> None:
        if not self.pending_path.exists():
            return
        try:
            if self.reboot_committed:
                return
            self.pending_path.unlink()
            self.log("network reboot evidence removed after a non-shutdown service stop")
        except OSError as error:
            self.log(f"could not remove uncommitted reboot evidence: {error}")

    def wait_for_committed_reboot(self) -> bool:
        deadline = time.monotonic() + 300
        while not self.stop_requested and time.monotonic() < deadline:
            time.sleep(1)
        if self.stop_requested:
            return True
        self.reboot_committed = False
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
                    "stalled network reboot evidence could not be removed but was "
                    f"invalidated: {error}"
                )
            except OSError as invalidate_error:
                self.log(
                    "could not withdraw or invalidate stalled network reboot evidence: "
                    f"{error}; {invalidate_error}"
                )
            return False
        self.log(
            "network reboot did not begin within 300 seconds; "
            "pending attribution was withdrawn"
        )
        return False

    def request_reboot(self, failure_started: float) -> bool:
        source_boot_id = Path("/proc/sys/kernel/random/boot_id").read_text(encoding="ascii").strip()
        if str(uuid.UUID(source_boot_id)) != source_boot_id.lower():
            raise RuntimeError("current boot ID is malformed")
        event_id = secrets.token_hex(16)
        prepared_epoch = int(time.time())
        failure_epoch = prepared_epoch - max(0, int(time.monotonic() - failure_started))
        self.atomic_write(
            self.pending_path,
            self.event_content(event_id, source_boot_id, failure_epoch, prepared_epoch),
        )
        self.log(
            "network_reboot_prepared "
            f"event_id={event_id} source_boot_id={source_boot_id} "
            f"target={self.target} prepared_epoch={prepared_epoch}"
        )
        result = subprocess.run(
            [self.systemctl_binary, "--no-block", "reboot"],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, timeout=30, check=False,
        )
        if result.returncode != 0:
            self.log(f"network reboot request was rejected with rc={result.returncode}")
            try:
                self.pending_path.unlink()
            except FileNotFoundError:
                pass
            return False
        accepted_epoch = int(time.time())
        self.atomic_write(
            self.pending_path,
            self.event_content(event_id, source_boot_id, failure_epoch, accepted_epoch),
        )
        self.log(
            "network_reboot_committed "
            f"event_id={event_id} source_boot_id={source_boot_id} "
            f"target={self.target} requested_epoch={accepted_epoch} method=systemctl-reboot"
        )
        self.reboot_committed = True
        return True

    def run(self) -> None:
        self.root.mkdir(parents=True, exist_ok=True)
        self.reconcile_pending_event()
        started = time.monotonic()
        next_check = started + self.startup_grace
        failure_started: float | None = None
        suppression_logged = False
        self.log(f"started target={self.target} hardware_watchdog_owner=systemd")
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
                        if not self.reboot_allowed(now_epoch):
                            if not suppression_logged:
                                self.log("network remains unavailable after the bounded reboot limit; reboot suppressed")
                                suppression_logged = True
                        elif self.request_reboot(failure_started):
                            if self.wait_for_committed_reboot():
                                return
                            failure_started = time.monotonic()
                next_check = now_mono + self.check_interval
            time.sleep(1)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: network_watchdog_keeper.py CONFIG", file=sys.stderr)
        return 2
    keeper = Keeper(Path(sys.argv[1]))
    signal.signal(signal.SIGTERM, keeper.request_stop)
    signal.signal(signal.SIGINT, keeper.request_stop)
    signal.signal(signal.SIGHUP, keeper.request_stop)
    try:
        keeper.run()
    except Exception as error:
        keeper.log(f"keeper failure without reboot attribution: {error}")
        return 1
    finally:
        if keeper.stop_requested:
            keeper.discard_uncommitted_stop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
