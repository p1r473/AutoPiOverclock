#!/usr/bin/env python3
"""Record durable reboot proof from an existing Debian watchdog daemon."""

# AUTOPIOVERCLOCK MANAGED DEBIAN NETWORK WATCHDOG OBSERVER

from __future__ import annotations

import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid


CONFIG_PATH = Path("/var/lib/autopioverclock/network-watchdog/observer.conf")
OBSERVER_PATH = Path("/usr/local/lib/autopioverclock/network-watchdog-observer.py")
SERVICE_PATH = Path("/etc/systemd/system/autopioverclock-network-watchdog-observer.service")
CONFIG_MARKER = "AUTOPIOVERCLOCK MANAGED DEBIAN NETWORK WATCHDOG OBSERVER"
EVENT_MARKER = "AUTOPIOVERCLOCK NETWORK WATCHDOG EVENT V1"
ALLOWED_KEYS = {
    "FORMAT",
    "PROVIDER",
    "INSTALL_RUN_ID",
    "TARGET",
    "NATIVE_SERVICE",
    "NATIVE_CONFIG_PATH",
    "NATIVE_BINARY_PATH",
    "REPAIR_BINARY_PATH",
    "REPAIR_TIMEOUT_SECONDS",
    "RETRY_TIMEOUT_SECONDS",
    "WATCHDOG_TIMEOUT_SECONDS",
    "EVIDENCE_WINDOW_SECONDS",
    "OBSERVER_SHA256",
    "SERVICE_SHA256",
}


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1_048_576):
            digest.update(chunk)
    return digest.hexdigest()


def read_config(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    marker_count = 0
    for raw_line in path.read_text(encoding="ascii").splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if line == f"# {CONFIG_MARKER}":
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
    if values["FORMAT"] != "1" or values["PROVIDER"] != "debian-watchdog-observer":
        raise ValueError("configuration format or provider is invalid")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", values["INSTALL_RUN_ID"]):
        raise ValueError("installation run ID is malformed")
    ipaddress.IPv4Address(values["TARGET"])
    if not re.fullmatch(r"[A-Za-z0-9_.@-]+[.]service", values["NATIVE_SERVICE"]):
        raise ValueError("native service name is malformed")
    for key in ("NATIVE_CONFIG_PATH", "NATIVE_BINARY_PATH"):
        if not values[key].startswith("/"):
            raise ValueError(f"{key} is not absolute")
    repair_path = values["REPAIR_BINARY_PATH"]
    if repair_path != "absent" and not repair_path.startswith("/"):
        raise ValueError("repair binary path is not absolute")
    for key in (
        "REPAIR_TIMEOUT_SECONDS",
        "RETRY_TIMEOUT_SECONDS",
        "WATCHDOG_TIMEOUT_SECONDS",
        "EVIDENCE_WINDOW_SECONDS",
    ):
        number = int(values[key], 10)
        if number < 0 or number > 86_400:
            raise ValueError(f"{key} is outside its safe range")
    if int(values["EVIDENCE_WINDOW_SECONDS"], 10) < 300:
        raise ValueError("evidence window is too short")
    for key in ("OBSERVER_SHA256", "SERVICE_SHA256"):
        if not re.fullmatch(r"[0-9a-f]{64}", values[key]):
            raise ValueError(f"{key} is malformed")
    return values


class Observer:
    def __init__(self, config_path: Path) -> None:
        self.config_path = config_path
        self.config = read_config(config_path)
        self.target = self.config["TARGET"]
        self.root = config_path.parent
        self.log_path = self.root / "watchdog.log"
        self.pending_path = self.root / "pending-network-reboot"
        self.event_path = self.root / "last-network-reboot"
        self.stop_requested = False
        self.failure_started_epoch: int | None = None
        self.retry_timed_out_epoch: int | None = None
        self.current_event_id: str | None = None
        self.journalctl = shutil.which("journalctl")
        if not self.journalctl:
            raise RuntimeError("journalctl is unavailable")
        self.verify_project_assets()

    def request_stop(self, _signum: int, _frame: object) -> None:
        self.stop_requested = True

    def verify_project_assets(self) -> None:
        checks = (
            (OBSERVER_PATH, self.config["OBSERVER_SHA256"]),
            (SERVICE_PATH, self.config["SERVICE_SHA256"]),
        )
        for path, expected_hash in checks:
            if path.is_symlink() or not path.is_file() or file_sha256(path) != expected_hash:
                raise RuntimeError(f"project-owned watchdog asset changed: {path}")

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

    def event_content(
        self, event_id: str, source_boot_id: str, failure_epoch: int, action_epoch: int,
    ) -> str:
        return (
            f"# {EVENT_MARKER}\n"
            "FORMAT=1\n"
            f"EVENT_ID={event_id}\n"
            f"SOURCE_BOOT_ID={source_boot_id}\n"
            f"TARGET={self.target}\n"
            f"FAILURE_STARTED_EPOCH={failure_epoch}\n"
            f"REBOOT_REQUESTED_EPOCH={action_epoch}\n"
            f"CONFIG_SHA256={file_sha256(self.config_path)}\n"
            f"KEEPER_SHA256={file_sha256(OBSERVER_PATH)}\n"
            f"SERVICE_SHA256={file_sha256(SERVICE_PATH)}\n"
            "REASON=TARGET_UNREACHABLE\n"
        )

    @staticmethod
    def boot_id() -> str:
        value = Path("/proc/sys/kernel/random/boot_id").read_text(encoding="ascii").strip().lower()
        if str(uuid.UUID(value)) != value:
            raise RuntimeError("current boot ID is malformed")
        return value

    def parse_event(self, path: Path) -> dict[str, str]:
        allowed = {
            "FORMAT",
            "EVENT_ID",
            "SOURCE_BOOT_ID",
            "TARGET",
            "FAILURE_STARTED_EPOCH",
            "REBOOT_REQUESTED_EPOCH",
            "CONFIG_SHA256",
            "KEEPER_SHA256",
            "SERVICE_SHA256",
            "REASON",
        }
        values: dict[str, str] = {}
        marker_count = 0
        for raw_line in path.read_text(encoding="ascii").splitlines():
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
        if marker_count != 1 or set(values) != allowed or values["FORMAT"] != "1":
            raise ValueError("event ownership is malformed")
        return values

    def prepare_event(self, epoch: int) -> None:
        if self.pending_path.exists():
            try:
                self.current_event_id = self.parse_event(self.pending_path)["EVENT_ID"]
            except (KeyError, OSError, UnicodeError, ValueError):
                self.current_event_id = None
            return
        source_boot_id = self.boot_id()
        failure_epoch = self.failure_started_epoch or epoch
        event_id = secrets.token_hex(16)
        self.atomic_write(
            self.pending_path,
            self.event_content(event_id, source_boot_id, min(failure_epoch, epoch), epoch),
        )
        self.current_event_id = event_id
        self.log(
            "network_reboot_prepared "
            f"event_id={event_id} source_boot_id={source_boot_id} "
            f"target={self.target} prepared_epoch={epoch} method=debian-watchdog-journal"
        )

    def commit_event(self, epoch: int, outcome: str) -> None:
        if not self.pending_path.exists():
            self.prepare_event(epoch)
        try:
            values = self.parse_event(self.pending_path)
            event_id = values["EVENT_ID"]
            source_boot_id = values["SOURCE_BOOT_ID"]
            requested_epoch = values["REBOOT_REQUESTED_EPOCH"]
        except (KeyError, OSError, UnicodeError, ValueError) as error:
            self.log(f"native watchdog action could not be bound to pending evidence: {error}")
            return
        self.current_event_id = event_id
        self.log(
            "network_reboot_committed "
            f"event_id={event_id} source_boot_id={source_boot_id} target={self.target} "
            f"requested_epoch={requested_epoch} method=debian-watchdog-journal outcome={outcome}"
        )

    def reconcile_pending_event(self) -> None:
        if not self.pending_path.exists():
            return
        if self.pending_path.is_symlink() or not self.pending_path.is_file():
            self.log("pending network reboot evidence is not a regular file; attribution disabled")
            return
        try:
            values = self.parse_event(self.pending_path)
            source_boot_id = values["SOURCE_BOOT_ID"].lower()
            event_id = values["EVENT_ID"]
            action_epoch = int(values["REBOOT_REQUESTED_EPOCH"], 10)
            failure_epoch = int(values["FAILURE_STARTED_EPOCH"], 10)
            current_boot_id = self.boot_id()
            if str(uuid.UUID(source_boot_id)) != source_boot_id:
                raise ValueError("event source boot ID is malformed")
            if not re.fullmatch(r"[0-9a-f]{32}", event_id):
                raise ValueError("event ID is malformed")
            if values["TARGET"] != self.target or values["REASON"] != "TARGET_UNREACHABLE":
                raise ValueError("event target or reason is malformed")
            if failure_epoch > action_epoch:
                raise ValueError("event failure window is malformed")
            if values["CONFIG_SHA256"] != file_sha256(self.config_path):
                raise ValueError("event config hash no longer matches")
            if values["KEEPER_SHA256"] != file_sha256(OBSERVER_PATH):
                raise ValueError("event observer hash no longer matches")
            if values["SERVICE_SHA256"] != file_sha256(SERVICE_PATH):
                raise ValueError("event service hash no longer matches")
            now_epoch = int(time.time())
            window = int(self.config["EVIDENCE_WINDOW_SECONDS"], 10)
            if source_boot_id == current_boot_id:
                if now_epoch - action_epoch > window:
                    self.pending_path.unlink()
                    self.log("discarded expired same-boot native-watchdog evidence")
                    self.current_event_id = None
                    self.failure_started_epoch = None
                    self.retry_timed_out_epoch = None
                return
            uptime_seconds = int(float(Path("/proc/uptime").read_text(encoding="ascii").split()[0]))
            boot_epoch = now_epoch - uptime_seconds
            if action_epoch < boot_epoch - window or action_epoch > boot_epoch + 120:
                self.pending_path.unlink()
                self.log("discarded stale pending native-watchdog evidence; attribution disabled")
                return
            os.replace(self.pending_path, self.event_path)
            directory_fd = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
            self.log(
                "network_reboot_committed "
                f"event_id={event_id} source_boot_id={source_boot_id} target={self.target} "
                f"requested_epoch={action_epoch} method=debian-watchdog-journal outcome=new-boot"
            )
            self.log(
                "network_reboot_accepted "
                f"event_id={event_id} source_boot_id={source_boot_id} "
                f"target={self.target} requested_epoch={action_epoch} current_boot_id={current_boot_id}"
            )
        except (KeyError, OSError, UnicodeError, ValueError) as error:
            self.log(f"pending native-watchdog evidence could not be reconciled: {error}")

    def failure_context_active(self, epoch: int) -> bool:
        if self.failure_started_epoch is None or epoch < self.failure_started_epoch:
            return False
        window = int(self.config["EVIDENCE_WINDOW_SECONDS"], 10)
        if epoch - self.failure_started_epoch <= window:
            return True
        self.failure_started_epoch = None
        self.retry_timed_out_epoch = None
        self.current_event_id = None
        if self.pending_path.exists():
            try:
                values = self.parse_event(self.pending_path)
                if values["SOURCE_BOOT_ID"].lower() == self.boot_id():
                    self.pending_path.unlink()
                    self.log("discarded expired same-boot native-watchdog evidence")
            except (KeyError, OSError, UnicodeError, ValueError) as error:
                self.log(f"expired native-watchdog evidence could not be cleared: {error}")
        return False

    def clear_failure_context(self) -> None:
        self.failure_started_epoch = None
        self.retry_timed_out_epoch = None
        self.current_event_id = None
        if not self.pending_path.exists():
            return
        try:
            values = self.parse_event(self.pending_path)
            if values["SOURCE_BOOT_ID"].lower() == self.boot_id():
                self.pending_path.unlink()
                self.log("network target recovered; same-boot pending evidence was withdrawn")
        except (KeyError, OSError, UnicodeError, ValueError) as error:
            self.log(f"recovered network evidence could not be cleared: {error}")

    def handle_message(self, message: str, epoch: int) -> None:
        ping_match = re.fullmatch(r"no response from ping \(target: ([0-9.]+)\)", message)
        if ping_match:
            if ping_match.group(1) == self.target:
                if self.failure_started_epoch is None:
                    self.failure_started_epoch = epoch
                self.log(f"native_ping_failure target={self.target} epoch={epoch}")
            return
        recovery_match = re.fullmatch(r"got answer from target ([0-9.]+)", message)
        if recovery_match and recovery_match.group(1) == self.target:
            self.clear_failure_context()
            return
        if not self.failure_context_active(epoch):
            return
        retry_match = re.fullmatch(
            r"Retry timed-out at ([0-9]+) seconds for (.+)", message,
        )
        if retry_match:
            if retry_match.group(2) == self.target:
                self.retry_timed_out_epoch = epoch
                self.log(
                    f"native_retry_timeout target={self.target} "
                    f"seconds={retry_match.group(1)} epoch={epoch}"
                )
            return
        repair_return = re.fullmatch(r"repair binary .+ returned ([0-9]+) = .+", message)
        if repair_return:
            result = int(repair_return.group(1), 10)
            self.log(f"native_repair_return result={result} epoch={epoch}")
            if result == 0:
                self.failure_started_epoch = None
                self.retry_timed_out_epoch = None
                self.current_event_id = None
                self.log("native repair succeeded; reboot attribution context cleared")
            return
        if message.startswith("Repair count exceeded "):
            self.log(f"native_repair_count_exceeded epoch={epoch}")
            return
        shutdown_match = re.fullmatch(
            r"shutting down the system because of error ([0-9]+) = '([^']+)'",
            message,
        )
        if shutdown_match and self.retry_timed_out_epoch is not None:
            action_window = max(30, int(self.config["REPAIR_TIMEOUT_SECONDS"], 10) + 30)
            reason = shutdown_match.group(2).lower()
            network_reason = (
                "network is unreachable" in reason
                or "no route to host" in reason
                or "host is unreachable" in reason
                or "connection timed out" in reason
            )
            if not network_reason or epoch - self.retry_timed_out_epoch > action_window:
                self.log(
                    "ignored native watchdog shutdown without a recent, matching "
                    f"network decision: error={shutdown_match.group(1)} reason={reason!r}"
                )
                return
            self.prepare_event(epoch)
            self.commit_event(epoch, f"native-shutdown-{shutdown_match.group(1)}")

    def run(self) -> None:
        self.root.mkdir(parents=True, exist_ok=True)
        self.reconcile_pending_event()
        self.log(
            f"started provider=debian-watchdog-observer target={self.target} "
            f"native_service={self.config['NATIVE_SERVICE']} "
            f"native_config={self.config['NATIVE_CONFIG_PATH']}"
        )
        process = subprocess.Popen(
            [
                self.journalctl,
                "--follow",
                "--lines=0",
                "--output=json",
                f"--unit={self.config['NATIVE_SERVICE']}",
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        try:
            assert process.stdout is not None
            while not self.stop_requested:
                ready, _, _ = select.select([process.stdout], [], [], 1.0)
                if not ready:
                    if process.poll() is not None:
                        raise RuntimeError(f"journal follower exited with rc={process.returncode}")
                    self.failure_context_active(int(time.time()))
                    self.reconcile_pending_event()
                    continue
                line = process.stdout.readline()
                if not line:
                    if process.poll() is not None:
                        raise RuntimeError(f"journal follower exited with rc={process.returncode}")
                    continue
                try:
                    record = json.loads(line)
                    message = record.get("MESSAGE")
                    realtime = record.get("__REALTIME_TIMESTAMP")
                    boot_id = str(record.get("_BOOT_ID", "")).lower()
                    if not isinstance(message, str) or not str(realtime).isdigit():
                        continue
                    if boot_id and boot_id != self.boot_id().replace("-", ""):
                        continue
                    self.handle_message(message, int(str(realtime), 10) // 1_000_000)
                except (OSError, ValueError) as error:
                    self.log(f"ignored malformed watchdog journal record: {error}")
                self.reconcile_pending_event()
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()


def main() -> int:
    try:
        observer = Observer(CONFIG_PATH)
    except Exception as error:
        print(f"AutoPiOverclock watchdog observer startup failed: {error}", file=sys.stderr, flush=True)
        return 1
    signal.signal(signal.SIGTERM, observer.request_stop)
    signal.signal(signal.SIGINT, observer.request_stop)
    signal.signal(signal.SIGHUP, observer.request_stop)
    try:
        observer.run()
    except Exception as error:
        observer.log(f"observer failure without reboot attribution: {error}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
