#!/usr/bin/env python3
"""Small independent HTTP/1 peer for legal shared-corpus differentials."""

from __future__ import annotations

import argparse
import json
import socket
import time
from pathlib import Path


RESPONSES = {
    "fixed-200": (
        b"HTTP/1.1 200 OK\r\nContent-Length: 17\r\n"
        b"X-Corpus-Value: alpha\r\nX-Corpus-Value: beta\r\n"
        b"Connection: close\r\n\r\ncorpus-fixed-body"
    ),
    "status-204": (
        b"HTTP/1.1 204 No Content\r\nX-Corpus-Value: empty\r\n"
        b"Connection: close\r\n\r\n"
    ),
    "zero-200": (
        b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n"
        b"X-Corpus-Value: zero\r\nConnection: close\r\n\r\n"
    ),
    "informational-final": (
        b"HTTP/1.1 103 Early Hints\r\nX-Corpus-Ignored: hint\r\n\r\n"
        b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\n"
        b"X-Corpus-Value: final\r\nConnection: close\r\n\r\nfinal"
    ),
    "lost-final-response": None,
}

LOGICAL_RESPONSES = {
    "fixed-200": (200, b"corpus-fixed-body", (("x-corpus-value", "alpha"), ("x-corpus-value", "beta"))),
    "status-204": (204, b"", (("x-corpus-value", "empty"),)),
    "zero-200": (200, b"", (("x-corpus-value", "zero"),)),
    "informational-final": (200, b"final", (("x-corpus-value", "final"),)),
}


def receive_request(connection: socket.socket) -> bytes:
    data = bytearray()
    while b"\r\n\r\n" not in data:
        chunk = connection.recv(4096)
        if not chunk:
            break
        data.extend(chunk)
    head_end = data.find(b"\r\n\r\n")
    if head_end < 0:
        return bytes(data)
    content_length = 0
    for field in data[:head_end].split(b"\r\n")[1:]:
        name, separator, value = field.partition(b":")
        if separator and name.strip().lower() == b"content-length":
            content_length = int(value.strip())
    complete_length = head_end + 4 + content_length
    while len(data) < complete_length:
        chunk = connection.recv(min(4096, complete_length - len(data)))
        if not chunk:
            break
        data.extend(chunk)
    return bytes(data)


def request_record(request: bytes) -> dict[str, str]:
    head, separator, body = request.partition(b"\r\n\r\n")
    lines = head.split(b"\r\n") if head else []
    fields: dict[bytes, bytes] = {}
    for field in lines[1:]:
        name, colon, value = field.partition(b":")
        if colon:
            fields[name.strip().lower()] = value.strip()
    return {
        "request": lines[0].decode("latin-1") if lines else "",
        "if_none_match": fields.get(b"if-none-match", b"").decode("latin-1"),
        "body_hex": body.hex() if separator else "",
    }


def serve_lost_h1(connection: socket.socket) -> dict[str, str]:
    primer = request_record(receive_request(connection))
    if primer["request"] != "GET /prime HTTP/1.1":
        raise RuntimeError(f"unexpected stale primer: {primer!r}")
    connection.sendall(
        b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
    )
    return request_record(receive_request(connection))


def serve_h2(connection: socket.socket, fixture: str) -> dict[str, str]:
    from h2.config import H2Configuration
    from h2.connection import H2Connection
    from h2.events import DataReceived, RequestReceived, StreamEnded
    from h2.settings import SettingCodes

    protocol = H2Connection(config=H2Configuration(client_side=False, header_encoding="utf-8"))
    #  hyper-h2 still defaults to the old client-only ENABLE_PUSH setting on
    #  server connections. RFC 9113 forbids a server from sending it.
    del protocol.local_settings[SettingCodes.ENABLE_PUSH]
    protocol.initiate_connection()
    connection.sendall(protocol.data_to_send())
    request_line: str | None = None
    request_fields: dict[str, str] = {}
    request_body = bytearray()
    final_stream_id: int | None = None
    connection.settimeout(5.0)
    while True:
        data = connection.recv(65_535)
        if not data:
            if request_line is None:
                raise RuntimeError("H2 client closed before sending a request")
            return {
                "request": request_line,
                "if_none_match": request_fields.get("if-none-match", ""),
                "body_hex": request_body.hex(),
            }
        for event in protocol.receive_data(data):
            if isinstance(event, RequestReceived):
                fields = dict(event.headers)
                if (
                    fixture == "lost-final-response"
                    and fields.get(":method") == "GET"
                ):
                    protocol.send_headers(
                        event.stream_id,
                        ((":status", "200"), ("content-length", "0")),
                        end_stream=True,
                    )
                else:
                    request_fields = fields
                    request_line = f"{fields.get(':method', '')} {fields.get(':path', '')} HTTP/2"
                    final_stream_id = event.stream_id
                if fixture != "lost-final-response":
                    status, body, response_fields = LOGICAL_RESPONSES[fixture]
                    if fixture == "informational-final":
                        protocol.send_headers(event.stream_id, ((":status", "103"), ("x-corpus-ignored", "hint")))
                    headers = [(":status", str(status)), *response_fields]
                    if status != 204:
                        headers.append(("content-length", str(len(body))))
                    protocol.send_headers(event.stream_id, headers, end_stream=not body)
                    if body:
                        protocol.send_data(event.stream_id, body, end_stream=True)
            elif isinstance(event, DataReceived):
                if event.stream_id == final_stream_id:
                    request_body.extend(event.data)
                protocol.acknowledge_received_data(
                    event.flow_controlled_length, event.stream_id
                )
            if (
                isinstance(event, StreamEnded)
                and fixture == "lost-final-response"
                and event.stream_id == final_stream_id
            ):
                return {
                    "request": request_line or "",
                    "if_none_match": request_fields.get("if-none-match", ""),
                    "body_hex": request_body.hex(),
                }
        outbound = protocol.data_to_send()
        if outbound:
            connection.sendall(outbound)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("fixture", choices=sorted(RESPONSES))
    parser.add_argument("--protocol", choices=("h1", "h2"), required=True)
    parser.add_argument("--count", type=int, required=True)
    parser.add_argument("--port-file", type=Path, required=True)
    parser.add_argument("--log-file", type=Path, required=True)
    parser.add_argument("--linger", type=float, default=0.0)
    arguments = parser.parse_args()

    with socket.socket() as listener:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        arguments.port_file.write_text(str(listener.getsockname()[1]), encoding="ascii")
        with arguments.log_file.open("w", encoding="utf-8") as log:
            sequence = 0

            def serve_one() -> None:
                nonlocal sequence
                connection, address = listener.accept()
                with connection:
                    if arguments.protocol == "h1":
                        if arguments.fixture == "lost-final-response":
                            record = serve_lost_h1(connection)
                        else:
                            request = receive_request(connection)
                            record = request_record(request)
                            response = RESPONSES[arguments.fixture]
                            if response is not None:
                                connection.sendall(response)
                    else:
                        record = serve_h2(connection, arguments.fixture)
                    print(
                        json.dumps(
                            {"sequence": sequence, "peer": address[0], **record}
                        ),
                        file=log,
                        flush=True,
                    )
                sequence += 1

            while sequence < arguments.count:
                serve_one()
            if arguments.linger > 0.0:
                deadline = time.monotonic() + arguments.linger
                while True:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0.0:
                        break
                    listener.settimeout(remaining)
                    try:
                        serve_one()
                    except TimeoutError:
                        break


if __name__ == "__main__":
    main()
