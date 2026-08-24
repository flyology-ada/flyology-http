#!/usr/bin/env python3
"""Minimal aioquic HTTP/3 oracle for the Ada interoperability client."""

import argparse
import asyncio
import json
import socket
from pathlib import Path
from cryptography import x509
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from aioquic.asyncio import QuicConnectionProtocol, serve
from aioquic.h3.connection import H3_ALPN, H3Connection
from aioquic.h3.events import DataReceived, HeadersReceived
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.events import ProtocolNegotiated, QuicEvent
from aioquic.tls import CipherSuite


CERTIFICATE_DER = bytes.fromhex(
    "3082013c3081efa0030201020214434e3e3873a520217edf913fba03f4"
    "ea17411e64300506032b657030143112301006035504030c096c6f6361"
    "6c686f7374301e170d3236303830373230323830385a170d3336303830"
    "343230323830385a30143112301006035504030c096c6f63616c686f73"
    "74302a300506032b65700321006380a1de85cdd187a3134d096ff12e8b"
    "1e47aa4c94cff3c4144bad3ee5f81eaea3533051301d0603551d0e0416"
    "0414d3dd952a2ff44a35af38d9249d71a454ced348ce301f0603551d23"
    "041830168014d3dd952a2ff44a35af38d9249d71a454ced348ce300f060"
    "3551d130101ff040530030101ff300506032b657003410024075a33b818"
    "be62a4f328b79bd8f79febe7d3710fb44ba7a7b2d8e12bc3d1e4056d5"
    "c20fba04e183430175b62ed1a107eb518dfaacf11045fa0e5a6feba2c0f"
)
PRIVATE_KEY = bytes.fromhex(
    "f491306c81165ffd97822f3ef58de8918779314457f5501e42d3f68504cd3aa8"
)


class OracleProtocol(QuicConnectionProtocol):
    corpus_mode = False
    lost_response_mode = False
    malformed_response_mode: str | None = None
    request_log: Path | None = None

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.http = None
        self.requests = {}
        self.completed = set()

    def finish_lost_request(self, stream_id: int) -> None:
        if stream_id in self.completed:
            return
        self.completed.add(stream_id)
        request = self.requests.get(stream_id, {"headers": [], "body": bytearray()})
        fields = dict(request["headers"])
        record = {
            "request": (
                fields.get(b":method", b"").decode("latin-1")
                + " "
                + fields.get(b":path", b"").decode("latin-1")
                + " HTTP/3"
            ),
            "if_none_match": fields.get(b"if-none-match", b"").decode(
                "latin-1"
            ),
            "body_hex": bytes(request["body"]).hex(),
        }
        if self.request_log is not None:
            with self.request_log.open("a", encoding="utf-8") as log:
                print(json.dumps(record), file=log, flush=True)
        self.close(error_code=0, reason_phrase="lost final response")

    def quic_event_received(self, event: QuicEvent) -> None:
        if isinstance(event, ProtocolNegotiated):
            self.http = H3Connection(self._quic)
        if self.http is None:
            return
        for http_event in self.http.handle_event(event):
            if isinstance(http_event, HeadersReceived):
                if self.malformed_response_mode is not None:
                    fields = dict(http_event.headers)
                    if fields.get(b":path") == b"/invalid":
                        malformed = {
                            "pseudo-after-field": [
                                (b"x-regular", b"1"),
                                (b":status", b"200"),
                            ],
                            "connection-specific-field": [
                                (b":status", b"200"),
                                (b"connection", b"close"),
                            ],
                            "status-101": [(b":status", b"101")],
                        }[self.malformed_response_mode]
                        self.http.send_headers(
                            http_event.stream_id, malformed, end_stream=True
                        )
                    else:
                        self.http.send_headers(
                            http_event.stream_id,
                            [(b":status", b"200"),
                             (b"content-length", b"5")],
                        )
                        self.http.send_data(
                            http_event.stream_id, b"hello", end_stream=True
                        )
                    self.transmit()
                    continue
                if self.lost_response_mode:
                    fields = dict(http_event.headers)
                    if fields.get(b":method") == b"GET":
                        self.http.send_headers(
                            http_event.stream_id,
                            [(b":status", b"200"),
                             (b"content-length", b"0")],
                            end_stream=True,
                        )
                        self.transmit()
                        continue
                    self.requests[http_event.stream_id] = {
                        "headers": http_event.headers,
                        "body": bytearray(),
                    }
                    if http_event.stream_ended:
                        self.finish_lost_request(http_event.stream_id)
                    continue
                body = b"corpus-fixed-body" if self.corpus_mode else b"hello"
                fields = [
                    (b":status", b"200"),
                    (b"content-length", str(len(body)).encode("ascii")),
                ]
                if self.corpus_mode:
                    fields.extend(
                        [
                            (b"x-corpus-value", b"alpha"),
                            (b"x-corpus-value", b"beta"),
                        ]
                    )
                self.http.send_headers(
                    http_event.stream_id,
                    fields,
                )
                self.http.send_data(
                    http_event.stream_id, body, end_stream=True
                )
                self.transmit()
            elif isinstance(http_event, DataReceived) and self.lost_response_mode:
                request = self.requests.setdefault(
                    http_event.stream_id, {"headers": [], "body": bytearray()}
                )
                request["body"].extend(http_event.data)
                if http_event.stream_ended:
                    self.finish_lost_request(http_event.stream_id)


async def main(
    port: int,
    receive_buffer: int,
    corpus: bool,
    lost_response: bool,
    malformed_response: str | None,
    request_log: Path | None,
) -> None:
    configuration = QuicConfiguration(
        alpn_protocols=H3_ALPN,
        cipher_suites=[CipherSuite.AES_128_GCM_SHA256],
        is_client=False,
        max_datagram_size=1200,
    )
    configuration.certificate = x509.load_der_x509_certificate(CERTIFICATE_DER)
    configuration.private_key = Ed25519PrivateKey.from_private_bytes(PRIVATE_KEY)
    OracleProtocol.corpus_mode = corpus
    OracleProtocol.lost_response_mode = lost_response
    OracleProtocol.malformed_response_mode = malformed_response
    OracleProtocol.request_log = request_log
    if request_log is not None:
        request_log.write_text("", encoding="utf-8")
    server = await serve(
        "127.0.0.1", port,
        configuration=configuration,
        create_protocol=OracleProtocol,
        retry=False,
    )
    server_socket = server._transport.get_extra_info("socket")
    server_socket.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, receive_buffer)
    actual_receive_buffer = server_socket.getsockopt(
        socket.SOL_SOCKET, socket.SO_RCVBUF
    )
    actual_port = server_socket.getsockname()[1]
    print(
        f"aioquic HTTP/3 oracle listening on 127.0.0.1:{actual_port} "
        f"receive_buffer={actual_receive_buffer}",
        flush=True,
    )
    try:
        await asyncio.Future()
    finally:
        server.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=4433)
    parser.add_argument("--receive-buffer", type=int, default=4 * 1024 * 1024)
    parser.add_argument("--corpus", action="store_true")
    parser.add_argument("--lost-response", action="store_true")
    parser.add_argument(
        "--malformed-response",
        choices=("pseudo-after-field", "connection-specific-field", "status-101"),
    )
    parser.add_argument("--log-file", type=Path)
    arguments = parser.parse_args()
    asyncio.run(
        main(
            arguments.port,
            arguments.receive_buffer,
            arguments.corpus,
            arguments.lost_response,
            arguments.malformed_response,
            arguments.log_file,
        )
    )
