#!/usr/bin/env python3
"""Independent HTTP/2 peer used by the Flyology HTTP client tests.

The peer deliberately uses python-hyper/h2 rather than Flyology's frame or
HPACK implementation.  Each scenario is deterministic and emits a JSON-lines
event log so the Ada integration test can verify wire-level behavior.
"""

from __future__ import annotations

import argparse
import json
import socket
import ssl
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import BinaryIO

from h2.config import H2Configuration
from h2.connection import H2Connection
from h2.errors import ErrorCodes
from h2.events import (
    ConnectionTerminated,
    DataReceived,
    RequestReceived,
    StreamEnded,
    StreamReset,
    WindowUpdated,
)
from h2.settings import SettingCodes


BODY = b"flyology-http2"
FLOW_BODY = bytes(range(256)) * 1024


@dataclass
class PeerState:
    scenario: str
    log: BinaryIO
    request_count: int = 0
    highest_stream_id: int = 0
    refused_once: bool = False
    pending_streams: list[int] = field(default_factory=list)
    flow_stream: int | None = None
    flow_offset: int = 0
    request_bytes: dict[int, int] = field(default_factory=dict)
    request_bodies: dict[int, bytearray] = field(default_factory=dict)
    request_headers: dict[int, dict[str, str]] = field(default_factory=dict)

    def record(self, event: str, **values: object) -> None:
        line = {"event": event, **values}
        self.log.write((json.dumps(line, sort_keys=True) + "\n").encode())
        self.log.flush()


def send_response(connection: H2Connection, stream_id: int, body: bytes = BODY) -> None:
    connection.send_headers(
        stream_id,
        [(":status", "200"), ("content-length", str(len(body))), ("x-peer", "h2")],
        end_stream=not body,
    )
    if body:
        connection.send_data(stream_id, body, end_stream=True)


def soak_body(identifier: str, size: int) -> bytes:
    unit = (identifier + ":").encode()
    return (unit * ((size + len(unit) - 1) // len(unit)))[:size]


def flush_flow_body(connection: H2Connection, state: PeerState) -> None:
    stream_id = state.flow_stream
    if stream_id is None:
        return
    while state.flow_offset < len(FLOW_BODY):
        available = connection.local_flow_control_window(stream_id)
        if available <= 0:
            return
        count = min(
            available,
            connection.max_outbound_frame_size,
            len(FLOW_BODY) - state.flow_offset,
        )
        end_stream = state.flow_offset + count == len(FLOW_BODY)
        connection.send_data(
            stream_id,
            FLOW_BODY[state.flow_offset : state.flow_offset + count],
            end_stream=end_stream,
        )
        state.flow_offset += count
        if end_stream:
            state.record("response", stream=stream_id, bytes=len(FLOW_BODY))
            state.flow_stream = None


def serve_connection(
    channel: socket.socket | ssl.SSLSocket, state: PeerState, cleartext: bool
) -> bool:
    if not cleartext and channel.selected_alpn_protocol() != "h2":
        raise RuntimeError("client did not negotiate h2")

    if state.scenario == "bad-preface":
        state.record(
            "connected", alpn="h2c" if cleartext else channel.selected_alpn_protocol()
        )
        channel.sendall(b"\x00\x00\x08\x06\x00\x00\x00\x00\x00badfirst")
        state.record("bad-preface")
        try:
            channel.recv(65_535)
        except (ConnectionResetError, ssl.SSLError):
            pass
        return False

    connection = H2Connection(
        config=H2Configuration(client_side=False, header_encoding="utf-8")
    )
    # hyper-h2 retains the obsolete RFC 7540 server-side ENABLE_PUSH=0
    # default. RFC 9113 forbids a server from sending this setting.
    del connection.local_settings[SettingCodes.ENABLE_PUSH]
    connection.initiate_connection()
    if state.scenario == "peer-capacity":
        connection.update_settings({SettingCodes.MAX_CONCURRENT_STREAMS: 1})
    channel.sendall(connection.data_to_send())
    state.record(
        "connected", alpn="h2c" if cleartext else channel.selected_alpn_protocol()
    )

    while True:
        try:
            data = channel.recv(65_535)
        except (ConnectionResetError, ssl.SSLError):
            return state.scenario == "soak"
        if not data:
            return state.scenario == "soak"
        events = connection.receive_data(data)
        for event in events:
            if isinstance(event, RequestReceived):
                if (
                    state.scenario == "stream-order"
                    and event.stream_id < state.highest_stream_id
                ):
                    raise RuntimeError("client opened streams out of identifier order")
                state.highest_stream_id = max(state.highest_stream_id, event.stream_id)
                state.request_count += 1
                headers = dict(event.headers)
                if state.scenario == "soak":
                    state.request_headers[event.stream_id] = headers
                    state.request_bodies[event.stream_id] = bytearray()
                state.record(
                    "request",
                    stream=event.stream_id,
                    method=headers.get(":method"),
                    path=headers.get(":path"),
                )
                if state.scenario == "early-final":
                    connection.send_headers(
                        event.stream_id,
                        [(":status", "413"), ("content-length", "0")],
                        end_stream=True,
                    )
                    state.record("early-final", stream=event.stream_id)
            elif isinstance(event, DataReceived):
                state.request_bytes[event.stream_id] = (
                    state.request_bytes.get(event.stream_id, 0) + len(event.data)
                )
                if state.scenario == "soak":
                    body = state.request_bodies[event.stream_id]
                    if len(body) + len(event.data) <= 16 * 1024:
                        body.extend(event.data)
                connection.acknowledge_received_data(
                    event.flow_controlled_length, event.stream_id
                )
            elif isinstance(event, StreamEnded):
                stream_id = event.stream_id
                if state.scenario == "soak":
                    headers = state.request_headers.pop(stream_id)
                    request_body = bytes(state.request_bodies.pop(stream_id))
                    path = headers[":path"]
                    if path == "/cancel":
                        connection.send_headers(
                            stream_id,
                            [(":status", "200"), ("content-length", "8192")],
                        )
                        connection.send_data(stream_id, b"c" * 8192, end_stream=False)
                        state.record("cancel-response", stream=stream_id)
                    elif path == "/echo":
                        send_response(connection, stream_id, request_body)
                        state.record("response", stream=stream_id, bytes=len(request_body))
                    elif path.startswith("/soak/"):
                        size = int(path.removeprefix("/soak/"))
                        body = soak_body(headers["x-soak-id"], size)
                        send_response(connection, stream_id, body)
                        state.record("response", stream=stream_id, bytes=len(body))
                    else:
                        connection.send_headers(
                            stream_id,
                            [(":status", "404"), ("content-length", "0")],
                            end_stream=True,
                        )
                elif state.scenario == "upload":
                    state.record(
                        "request-body",
                        stream=stream_id,
                        bytes=state.request_bytes.get(stream_id, 0),
                    )
                if state.scenario == "early-final":
                    pass
                elif state.scenario == "head-empty-data":
                    connection.send_headers(
                        stream_id,
                        [(":status", "200"), ("content-length", "5368709129")],
                        end_stream=False,
                    )
                    connection.send_data(stream_id, b"", end_stream=True)
                    state.record("head-empty-data", stream=stream_id)
                elif state.scenario == "informational-end":
                    # Literal :status 103, carried in an invalid final
                    # informational HEADERS frame.
                    block = b"\x08\x03\x31\x30\x33"
                    frame = bytes((0, 0, len(block), 1, 5, 0, 0, 0, stream_id))
                    channel.sendall(frame + block)
                    state.record("informational-end", stream=stream_id)
                elif state.scenario == "reset-race" and state.request_count == 1:
                    connection.send_headers(stream_id, [(":status", "200")])
                    connection.send_data(stream_id, b"buffered", end_stream=False)
                    channel.sendall(connection.data_to_send())
                    time.sleep(0.1)
                    connection.send_data(stream_id, b"late", end_stream=True)
                    channel.sendall(connection.data_to_send())
                    state.record("late-data", stream=stream_id)
                elif state.scenario == "flood":
                    unknown = b"\x00\x00\x00\x0f\x00\x00\x00\x00\x00"
                    ping = b"\x00\x00\x08\x06\x00\x00\x00\x00\x00flooding"
                    channel.sendall((unknown + ping) * 4_000)
                    send_response(connection, stream_id)
                    state.record("flood", frames=8_000)
                elif state.scenario == "shutdown-race":
                    connection.send_headers(
                        stream_id,
                        [(":status", "200"), ("content-length", str(len(BODY)))],
                    )
                    connection.send_data(stream_id, b"held", end_stream=False)
                    state.record("shutdown-race", stream=stream_id)
                elif state.scenario == "goaway" and state.request_count == 1:
                    connection.close_connection(
                        error_code=ErrorCodes.NO_ERROR, last_stream_id=0
                    )
                    state.record("goaway", last_stream=0)
                    channel.sendall(connection.data_to_send())
                    return True
                if state.scenario in {
                    "early-final",
                    "head-empty-data",
                    "informational-end",
                    "flood",
                    "shutdown-race",
                    "soak",
                } or (
                    state.scenario == "reset-race" and stream_id == 1
                ):
                    pass
                elif state.scenario == "refused" and not state.refused_once:
                    state.refused_once = True
                    connection.reset_stream(stream_id, ErrorCodes.REFUSED_STREAM)
                    state.record("refused", stream=stream_id)
                elif state.scenario == "refused-post":
                    connection.reset_stream(stream_id, ErrorCodes.REFUSED_STREAM)
                    state.record("refused", stream=stream_id)
                elif state.scenario == "multiplex":
                    state.pending_streams.append(stream_id)
                    if len(state.pending_streams) == 2:
                        first, second = state.pending_streams
                        connection.send_headers(first, [(":status", "200")])
                        connection.send_headers(second, [(":status", "200")])
                        connection.send_data(first, b"first-", end_stream=False)
                        connection.send_data(second, b"second", end_stream=True)
                        connection.send_data(first, b"response", end_stream=True)
                        state.record("multiplex", streams=state.pending_streams)
                elif state.scenario == "flow":
                    connection.send_headers(
                        stream_id,
                        [(":status", "200"), ("content-length", str(len(FLOW_BODY)))],
                    )
                    state.flow_stream = stream_id
                    state.flow_offset = 0
                    flush_flow_body(connection, state)
                else:
                    send_response(connection, stream_id)
                    state.record("response", stream=stream_id, bytes=len(BODY))
            elif isinstance(event, WindowUpdated):
                flush_flow_body(connection, state)
            elif isinstance(event, StreamReset):
                state.request_bodies.pop(event.stream_id, None)
                state.request_headers.pop(event.stream_id, None)
                state.record(
                    "client-reset",
                    stream=event.stream_id,
                    error=int(event.error_code),
                )
            elif isinstance(event, ConnectionTerminated):
                state.record("client-goaway", error=int(event.error_code))
                return state.scenario == "soak"

        outbound = connection.data_to_send()
        if outbound:
            channel.sendall(outbound)

def serve_http1(channel: ssl.SSLSocket, state: PeerState) -> bool:
    state.record("connected", alpn=channel.selected_alpn_protocol())
    request = bytearray()
    while b"\r\n\r\n" not in request:
        data = channel.recv(4096)
        if not data:
            return False
        request.extend(data)
    state.request_count += 1
    state.record("request", protocol="http/1.1")
    body = b"fallback"
    channel.sendall(
        b"HTTP/1.1 200 OK\r\nContent-Length: 8\r\nConnection: close\r\n\r\n"
        + body
    )
    return False


def make_tls_context(
    certificate: Path, private_key: Path, protocols: list[str]
) -> ssl.SSLContext:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(certificate, private_key)
    context.set_alpn_protocols(protocols)
    return context


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "scenario",
        choices=(
            "basic",
            "multiplex",
            "continuation",
            "peer-capacity",
            "stream-order",
            "flow",
            "goaway",
            "refused",
            "prior",
            "fallback",
            "require-failure",
            "upload",
            "refused-post",
            "early-final",
            "head-empty-data",
            "reset-race",
            "zero-read",
            "bad-preface",
            "informational-end",
            "flood",
            "shutdown-race",
            "soak",
        ),
    )
    parser.add_argument("--certificate", type=Path, required=True)
    parser.add_argument("--private-key", type=Path, required=True)
    parser.add_argument("--port-file", type=Path, required=True)
    parser.add_argument("--log-file", type=Path, required=True)
    parser.add_argument("--cleartext", action="store_true")
    arguments = parser.parse_args()

    context = (
        None
        if arguments.cleartext
        else make_tls_context(
            arguments.certificate,
            arguments.private_key,
            ["http/1.1"]
            if arguments.scenario in {"fallback", "require-failure"}
            else ["h2"],
        )
    )
    with arguments.log_file.open("wb") as log:
        state = PeerState(arguments.scenario, log)
        with socket.create_server(("127.0.0.1", 0)) as listener:
            listener.settimeout(15)
            arguments.port_file.write_text(str(listener.getsockname()[1]), encoding="ascii")
            more_connections = True
            while more_connections:
                raw, _ = listener.accept()
                with raw:
                    raw.settimeout(30)
                    if arguments.cleartext:
                        more_connections = serve_connection(raw, state, True)
                    else:
                        assert context is not None
                        with context.wrap_socket(raw, server_side=True) as channel:
                            if arguments.scenario == "fallback":
                                more_connections = serve_http1(channel, state)
                            elif arguments.scenario == "require-failure":
                                state.record(
                                    "connected",
                                    alpn=channel.selected_alpn_protocol(),
                                )
                                try:
                                    channel.recv(1)
                                except (ConnectionResetError, ssl.SSLError):
                                    pass
                                more_connections = False
                            else:
                                more_connections = serve_connection(
                                    channel, state, False
                                )


if __name__ == "__main__":
    main()
