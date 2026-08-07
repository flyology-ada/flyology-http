#!/usr/bin/env python3
"""Independent hyper-h2 peer for the Flyology HTTP/2 server."""

import argparse
import socket
import ssl
import time

import h2.config
import h2.connection
import h2.events


class Peer:
    def __init__(self, port: int, tls: bool, certificate: str) -> None:
        raw = socket.create_connection(("127.0.0.1", port), timeout=10.0)
        if tls:
            context = ssl.create_default_context(cafile=certificate)
            context.check_hostname = True
            context.set_alpn_protocols(["h2", "http/1.1"])
            self.socket = context.wrap_socket(raw, server_hostname="localhost")
            assert self.socket.selected_alpn_protocol() == "h2"
        else:
            self.socket = raw
        self.socket.settimeout(10.0)
        self.connection = h2.connection.H2Connection(
            config=h2.config.H2Configuration(
                client_side=True,
                header_encoding="utf-8",
                validate_outbound_headers=False,
                normalize_outbound_headers=False,
            )
        )
        self.headers: dict[int, list[tuple[str, str]]] = {}
        self.bodies: dict[int, bytearray] = {}
        self.ended: set[int] = set()
        self.reset: set[int] = set()
        self.connection.initiate_connection()
        self.flush()

    def flush(self) -> None:
        data = self.connection.data_to_send()
        if data:
            self.socket.sendall(data)

    def request(self, method: str, path: str, end_stream: bool = True) -> int:
        stream_id = self.connection.get_next_available_stream_id()
        self.connection.send_headers(
            stream_id,
            [
                (":method", method),
                (":scheme", "https" if isinstance(self.socket, ssl.SSLSocket) else "http"),
                (":authority", "localhost"),
                (":path", path),
            ],
            end_stream=end_stream,
        )
        self.flush()
        return stream_id

    def send_pseudo_headers(self, headers: list[tuple[str, str]]) -> int:
        """Send a field section verbatim, bypassing the request template."""
        stream_id = self.connection.get_next_available_stream_id()
        self.connection.send_headers(stream_id, headers, end_stream=True)
        self.flush()
        return stream_id

    def pump(self) -> None:
        payload = self.socket.recv(65535)
        if not payload:
            raise AssertionError("server closed before streams completed")
        for event in self.connection.receive_data(payload):
            if isinstance(event, h2.events.ResponseReceived):
                self.headers[event.stream_id] = list(event.headers)
            elif isinstance(event, h2.events.DataReceived):
                self.bodies.setdefault(event.stream_id, bytearray()).extend(event.data)
                self.connection.acknowledge_received_data(
                    event.flow_controlled_length, event.stream_id
                )
            elif isinstance(event, h2.events.StreamEnded):
                self.ended.add(event.stream_id)
            elif isinstance(event, h2.events.StreamReset):
                self.reset.add(event.stream_id)
        self.flush()

    def wait(self, *stream_ids: int) -> None:
        deadline = time.monotonic() + 10.0
        while not all(stream_id in self.ended for stream_id in stream_ids):
            if time.monotonic() >= deadline:
                raise AssertionError(f"timed out waiting for streams {stream_ids}")
            self.pump()

    def wait_settled(self, stream_id: int) -> None:
        """Wait until a stream is either answered or reset."""
        deadline = time.monotonic() + 10.0
        while stream_id not in self.reset and stream_id not in self.ended:
            if time.monotonic() >= deadline:
                raise AssertionError(f"timed out waiting for {stream_id}")
            self.pump()

    def wait_reset(self, stream_id: int) -> None:
        deadline = time.monotonic() + 10.0
        while stream_id not in self.reset:
            if time.monotonic() >= deadline:
                raise AssertionError(f"timed out waiting for reset {stream_id}")
            self.pump()

    def expect_connection_error(self, wire: bytes, error_code: int) -> None:
        self.socket.sendall(wire)
        deadline = time.monotonic() + 10.0
        while time.monotonic() < deadline:
            try:
                payload = self.socket.recv(65535)
            except ConnectionResetError as error:
                raise AssertionError(
                    "server reset TCP before delivering GOAWAY"
                ) from error
            if not payload:
                break
            for event in self.connection.receive_data(payload):
                if isinstance(event, h2.events.ConnectionTerminated):
                    assert event.error_code == error_code
                    return
        raise AssertionError(
            f"server did not deliver GOAWAY error code {error_code}"
        )

    def upload(self, path: str, body: bytes) -> int:
        stream_id = self.request("POST", path, end_stream=False)
        offset = 0
        while offset < len(body):
            available = min(
                self.connection.local_flow_control_window(stream_id),
                self.connection.max_outbound_frame_size,
                len(body) - offset,
            )
            if available <= 0:
                self.pump()
                continue
            final = offset + available == len(body)
            self.connection.send_data(
                stream_id,
                body[offset : offset + available],
                end_stream=final,
            )
            offset += available
            self.flush()
        self.wait(stream_id)
        return stream_id

    def close(self) -> None:
        self.connection.close_connection()
        self.flush()
        self.socket.close()


def status(headers: list[tuple[str, str]]) -> str:
    return dict(headers)[":status"]


def run(port: int, tls: bool, certificate: str) -> None:
    peer = Peer(port, tls, certificate)

    first = peer.request("GET", "/first")
    second = peer.request("GET", "/second")
    peer.wait(first, second)
    assert status(peer.headers[first]) == "200"
    assert status(peer.headers[second]) == "200"
    assert bytes(peer.bodies[first]) == b"/first"
    assert bytes(peer.bodies[second]) == b"/second"
    assert dict(peer.headers[first])["x-protocol"] == "h2"

    malformed = peer.connection.get_next_available_stream_id()
    peer.connection.send_headers(
        malformed,
        [
            (":method", "GET"),
            (":scheme", "https" if tls else "http"),
            (":authority", "localhost"),
        ],
        end_stream=True,
    )
    peer.flush()
    peer.wait_reset(malformed)
    healthy = peer.request("GET", "/basic")
    peer.wait(healthy)
    assert status(peer.headers[healthy]) == "200"
    assert bytes(peer.bodies[healthy]) == b"/basic"

    # Pseudo-header values are not field values as far as HPACK is concerned,
    # so nothing on the wire keeps CR LF out of them. :authority is spliced
    # into the header block the application layer re-parses as CRLF-delimited
    # lines, :path becomes the target handed to the log sink, and asterisk
    # form is legal only for OPTIONS. Each has to be a stream error, and the
    # connection has to survive it.
    scheme = "https" if tls else "http"
    for injected in (
        [
            (":method", "GET"),
            (":scheme", scheme),
            (":authority", "localhost\r\nTransfer-Encoding: chunked"),
            (":path", "/basic"),
        ],
        [
            (":method", "GET"),
            (":scheme", scheme),
            (":authority", "localhost"),
            (":path", "/basic\r\nforged-log-line"),
        ],
        [
            (":method", "GET"),
            (":scheme", scheme),
            (":authority", "localhost"),
            (":path", "*"),
        ],
    ):
        spliced = peer.send_pseudo_headers(injected)
        peer.wait_settled(spliced)
        assert spliced in peer.reset and spliced not in peer.headers, (
            f"server answered an unvalidated field section {injected} "
            f"with {peer.headers.get(spliced)}"
        )

    survivor = peer.request("GET", "/basic")
    peer.wait(survivor)
    assert status(peer.headers[survivor]) == "200"

    large = peer.request("GET", "/large")
    peer.wait(large)
    assert status(peer.headers[large]) == "200"
    assert len(peer.bodies[large]) == 128 * 1024

    head = peer.request("HEAD", "/basic")
    peer.wait(head)
    assert status(peer.headers[head]) == "200"
    assert bytes(peer.bodies.get(head, b"")) == b""
    assert dict(peer.headers[head])["content-length"] == str(len("/basic"))

    # Consume the full connection receive window across streams that are reset
    # before their handlers read the retained bytes. A server that forgets to
    # return connection credit here cannot start the following upload.
    for amount in (16384, 16384, 16384, 16383):
        abandoned = peer.request("POST", "/reset", end_stream=False)
        peer.connection.send_data(abandoned, b"r" * amount, end_stream=False)
        peer.connection.reset_stream(abandoned)
    peer.flush()

    echoed = peer.upload("/echo", b"e" * (96 * 1024))
    assert status(peer.headers[echoed]) == "200"
    assert bytes(peer.bodies[echoed]) == b"e" * (96 * 1024)

    #  Invalid PING length is a connection FRAME_SIZE_ERROR. Include the full
    #  malformed payload and require GOAWAY to be observable before TCP close;
    #  Linux otherwise exposes unread payload at close as ECONNRESET.
    malformed_ping = b"\x00\x00\x07\x06\x00\x00\x00\x00\x00" + b"x" * 7
    peer.expect_connection_error(malformed_ping, error_code=6)
    peer.socket.close()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--tls", action="store_true")
    parser.add_argument("--certificate", required=True)
    arguments = parser.parse_args()
    run(arguments.port, arguments.tls, arguments.certificate)


if __name__ == "__main__":
    main()
