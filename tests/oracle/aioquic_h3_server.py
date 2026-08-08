#!/usr/bin/env python3
"""Minimal aioquic HTTP/3 oracle for the Ada interoperability client."""

import argparse
import asyncio
from cryptography import x509
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from aioquic.asyncio import QuicConnectionProtocol, serve
from aioquic.h3.connection import H3_ALPN, H3Connection
from aioquic.h3.events import HeadersReceived
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
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.http = None

    def quic_event_received(self, event: QuicEvent) -> None:
        if isinstance(event, ProtocolNegotiated):
            self.http = H3Connection(self._quic)
        if self.http is None:
            return
        for http_event in self.http.handle_event(event):
            if isinstance(http_event, HeadersReceived):
                self.http.send_headers(
                    http_event.stream_id,
                    [(b":status", b"200"), (b"content-length", b"5")],
                )
                self.http.send_data(
                    http_event.stream_id, b"hello", end_stream=True
                )
                self.transmit()


async def main(port: int) -> None:
    configuration = QuicConfiguration(
        alpn_protocols=H3_ALPN,
        cipher_suites=[CipherSuite.AES_128_GCM_SHA256],
        is_client=False,
        max_datagram_size=1200,
    )
    configuration.certificate = x509.load_der_x509_certificate(CERTIFICATE_DER)
    configuration.private_key = Ed25519PrivateKey.from_private_bytes(PRIVATE_KEY)
    server = await serve(
        "127.0.0.1", port,
        configuration=configuration,
        create_protocol=OracleProtocol,
        retry=False,
    )
    print(f"aioquic HTTP/3 oracle listening on 127.0.0.1:{port}", flush=True)
    try:
        await asyncio.Future()
    finally:
        server.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=4433)
    arguments = parser.parse_args()
    asyncio.run(main(arguments.port))
