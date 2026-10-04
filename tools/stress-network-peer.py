#!/usr/bin/env python3
"""Authenticated LAN traffic companion for final endurance."""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import hmac
import ipaddress
import os
import signal
import socket
import socketserver
import struct
import tempfile
import threading
import time


MAGIC = b"APO1"
HEADER = struct.Struct("!4s32sQI")
DIGEST_SIZE = hashlib.sha256().digest_size
MAX_PAYLOAD = 65536


def normalized_ip(value: str) -> ipaddress._BaseAddress:
    address = ipaddress.ip_address(value)
    if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped:
        return address.ipv4_mapped
    return address


def exact_receive(sock: socket.socket, size: int) -> bytes:
    chunks: list[bytes] = []
    remaining = size
    while remaining:
        chunk = sock.recv(remaining)
        if not chunk:
            raise ConnectionError("connection closed before the authenticated frame completed")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def make_payload(token: bytes, sequence: int, size: int) -> bytes:
    seed = hashlib.sha256(token + sequence.to_bytes(8, "big")).digest()
    return (seed * ((size + len(seed) - 1) // len(seed)))[:size]


def make_frame(token: bytes, sequence: int, payload: bytes) -> bytes:
    key_id = hashlib.sha256(token).digest()
    header = HEADER.pack(MAGIC, key_id, sequence, len(payload))
    content = header + payload
    return content + hmac.new(token, content, hashlib.sha256).digest()


def validate_frame(frame: bytes, expected_token: bytes) -> tuple[int, bytes]:
    if len(frame) < HEADER.size + DIGEST_SIZE:
        raise ValueError("authenticated frame is truncated")
    magic, key_id, sequence, payload_size = HEADER.unpack(frame[: HEADER.size])
    expected_key_id = hashlib.sha256(expected_token).digest()
    if magic != MAGIC or not hmac.compare_digest(key_id, expected_key_id) or payload_size > MAX_PAYLOAD:
        raise ValueError("authenticated frame header is invalid")
    expected_size = HEADER.size + payload_size + DIGEST_SIZE
    if len(frame) != expected_size:
        raise ValueError("authenticated frame size is invalid")
    content = frame[:-DIGEST_SIZE]
    supplied_digest = frame[-DIGEST_SIZE:]
    if not hmac.compare_digest(hmac.new(expected_token, content, hashlib.sha256).digest(), supplied_digest):
        raise ValueError("authenticated frame digest is invalid")
    return sequence, frame[HEADER.size:-DIGEST_SIZE]


class PeerState:
    def __init__(self, token: bytes, client_ip: str, marker: str) -> None:
        self.token = token
        self.client_ip = normalized_ip(client_ip)
        self.marker = marker
        self.count = 0
        self.lock = threading.Lock()

    def accepts(self, source_ip: str) -> bool:
        try:
            return normalized_ip(source_ip) == self.client_ip
        except ValueError:
            return False

    def record(self) -> None:
        with self.lock:
            self.count += 1
            marker_dir = os.path.dirname(self.marker)
            os.makedirs(marker_dir, mode=0o700, exist_ok=True)
            descriptor, temporary = tempfile.mkstemp(prefix=".network.", dir=marker_dir)
            try:
                with os.fdopen(descriptor, "w", encoding="ascii") as stream:
                    stream.write(f"{self.count} {int(time.time())}\n")
                    stream.flush()
                    os.fsync(stream.fileno())
                os.chmod(temporary, 0o600)
                os.replace(temporary, self.marker)
            finally:
                try:
                    os.unlink(temporary)
                except FileNotFoundError:
                    pass


class ThreadedTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True


class ThreadedUDPServer(socketserver.ThreadingMixIn, socketserver.UDPServer):
    allow_reuse_address = True
    daemon_threads = True


class TCPHandler(socketserver.BaseRequestHandler):
    def handle(self) -> None:
        state: PeerState = self.server.peer_state
        if not state.accepts(self.client_address[0]):
            return
        self.request.settimeout(5.0)
        header = exact_receive(self.request, HEADER.size)
        _, _, _, payload_size = HEADER.unpack(header)
        if payload_size > MAX_PAYLOAD:
            return
        remainder = exact_receive(self.request, payload_size + DIGEST_SIZE)
        frame = header + remainder
        validate_frame(frame, state.token)
        state.record()
        self.request.sendall(frame)


class UDPHandler(socketserver.BaseRequestHandler):
    def handle(self) -> None:
        state: PeerState = self.server.peer_state
        frame, udp_socket = self.request
        if not state.accepts(self.client_address[0]):
            return
        validate_frame(frame, state.token)
        state.record()
        udp_socket.sendto(frame, self.client_address)


def server_class(base: type[socketserver.BaseServer], bind_ip: str) -> type[socketserver.BaseServer]:
    if normalized_ip(bind_ip).version == 6:
        return type(f"IPv6{base.__name__}", (base,), {"address_family": socket.AF_INET6})
    return base


def run_server(args: argparse.Namespace) -> int:
    token = bytes.fromhex(args.token)
    state = PeerState(token, args.client_ip, args.marker)
    tcp_class = server_class(ThreadedTCPServer, args.bind)
    udp_class = server_class(ThreadedUDPServer, args.bind)
    tcp_server = tcp_class((args.bind, args.port), TCPHandler)
    udp_server = udp_class((args.bind, args.port), UDPHandler)
    tcp_server.peer_state = state
    udp_server.peer_state = state
    stopped = threading.Event()

    def stop(_signum: int, _frame: object) -> None:
        stopped.set()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    tcp_thread = threading.Thread(target=tcp_server.serve_forever, daemon=True)
    udp_thread = threading.Thread(target=udp_server.serve_forever, daemon=True)
    tcp_thread.start()
    udp_thread.start()
    print(
        f"NETWORK_SERVER_READY bind={args.bind} port={args.port} client={args.client_ip}",
        flush=True,
    )
    stopped.wait()
    tcp_server.shutdown()
    udp_server.shutdown()
    tcp_server.server_close()
    udp_server.server_close()
    print(f"NETWORK_SERVER_STOP messages={state.count}", flush=True)
    return 0


def resolved_address(host: str, port: int, socket_type: int) -> tuple[int, tuple[object, ...]]:
    addresses = socket.getaddrinfo(host, port, type=socket_type)
    if not addresses:
        raise OSError("target name did not resolve")
    family, _, _, _, address = addresses[0]
    return family, address


def tcp_exchange(host: str, port: int, token: bytes, sequence: int, timeout: float) -> int:
    payload = make_payload(token, sequence, 8192)
    frame = make_frame(token, sequence, payload)
    family, address = resolved_address(host, port, socket.SOCK_STREAM)
    with socket.socket(family, socket.SOCK_STREAM) as stream:
        stream.settimeout(timeout)
        stream.connect(address)
        stream.sendall(frame)
        echoed = exact_receive(stream, len(frame))
    echoed_sequence, echoed_payload = validate_frame(echoed, token)
    if echoed_sequence != sequence or echoed_payload != payload:
        raise ValueError("TCP echo did not match the sent workload")
    return len(frame) * 2


def udp_exchanges(host: str, port: int, token: bytes, first_sequence: int, timeout: float) -> int:
    family, address = resolved_address(host, port, socket.SOCK_DGRAM)
    transferred = 0
    with socket.socket(family, socket.SOCK_DGRAM) as datagram:
        datagram.settimeout(timeout)
        for offset in range(32):
            sequence = first_sequence + offset
            payload = make_payload(token, sequence, 512)
            frame = make_frame(token, sequence, payload)
            datagram.sendto(frame, address)
            echoed, source = datagram.recvfrom(len(frame) + 1)
            if normalized_ip(source[0]) != normalized_ip(str(address[0])):
                raise ValueError("UDP echo came from an unexpected address")
            echoed_sequence, echoed_payload = validate_frame(echoed, token)
            if echoed_sequence != sequence or echoed_payload != payload:
                raise ValueError("UDP echo did not match the sent workload")
            transferred += len(frame) * 2
    return transferred


def run_client(args: argparse.Namespace) -> int:
    token = bytes.fromhex(args.token)
    sequence_base = time.monotonic_ns() & ((1 << 63) - 1)
    deadline = time.monotonic() + args.connect_wait
    last_error: Exception | None = None
    while time.monotonic() < deadline:
        try:
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
                futures = [
                    executor.submit(
                        tcp_exchange,
                        args.host,
                        args.port,
                        token,
                        sequence_base + index,
                        args.timeout,
                    )
                    for index in range(8)
                ]
                tcp_bytes = sum(future.result() for future in futures)
            udp_bytes = udp_exchanges(
                args.host,
                args.port,
                token,
                sequence_base + 1000,
                args.timeout,
            )
            print(
                f"NETWORK_BURST_PASS tcp_connections=8 udp_datagrams=32 bytes={tcp_bytes + udp_bytes}",
                flush=True,
            )
            return 0
        except (ConnectionError, OSError, TimeoutError, ValueError) as error:
            last_error = error
            time.sleep(0.25)
    raise SystemExit(f"network burst failed: {last_error or 'peer unavailable'}")


def token_type(value: str) -> str:
    if len(value) != 64:
        raise argparse.ArgumentTypeError("token must contain 64 hexadecimal characters")
    try:
        bytes.fromhex(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("token must be hexadecimal") from error
    return value.lower()


def port_type(value: str) -> int:
    port = int(value)
    if port < 1024 or port > 65535:
        raise argparse.ArgumentTypeError("port must be from 1024 through 65535")
    return port


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    commands = root.add_subparsers(dest="command", required=True)
    server = commands.add_parser("server")
    server.add_argument("--bind", required=True)
    server.add_argument("--client-ip", required=True)
    server.add_argument("--port", required=True, type=port_type)
    server.add_argument("--token", required=True, type=token_type)
    server.add_argument("--marker", required=True)
    server.set_defaults(handler=run_server)
    client = commands.add_parser("client")
    client.add_argument("--host", required=True)
    client.add_argument("--port", required=True, type=port_type)
    client.add_argument("--token", required=True, type=token_type)
    client.add_argument("--timeout", type=float, default=2.0)
    client.add_argument("--connect-wait", type=float, default=8.0)
    client.set_defaults(handler=run_client)
    return root


def main() -> int:
    args = parser().parse_args()
    return args.handler(args)


if __name__ == "__main__":
    raise SystemExit(main())
