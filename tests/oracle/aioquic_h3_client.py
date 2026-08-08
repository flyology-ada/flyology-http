#!/usr/bin/env python3
"""Minimal aioquic client oracle for the Ada HTTP/3 server."""

import argparse
import asyncio
import ssl

from aioquic.asyncio import QuicConnectionProtocol, connect
from aioquic.h3.connection import H3_ALPN, H3Connection
from aioquic.h3.events import DataReceived, HeadersReceived
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.events import ProtocolNegotiated, QuicEvent
from aioquic.tls import CipherSuite


class OracleProtocol(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.http = None
        self.events = asyncio.Queue()

    def quic_event_received(self, event: QuicEvent) -> None:
        if isinstance(event, ProtocolNegotiated):
            self.http = H3Connection(self._quic)
        if self.http is None:
            return
        for http_event in self.http.handle_event(event):
            self.events.put_nowait(http_event)


async def main(port: int) -> None:
    configuration = QuicConfiguration(
        alpn_protocols=H3_ALPN,
        cipher_suites=[CipherSuite.AES_128_GCM_SHA256],
        is_client=True,
        max_datagram_size=1200,
        server_name="localhost",
        verify_mode=ssl.CERT_NONE,
    )
    async with connect(
        "127.0.0.1", port,
        configuration=configuration,
        create_protocol=OracleProtocol,
    ) as protocol:
        await protocol.wait_connected()
        stream_id = protocol._quic.get_next_available_stream_id()
        protocol.http.send_headers(
            stream_id,
            [
                (b":method", b"GET"),
                (b":scheme", b"https"),
                (b":authority", b"localhost"),
                (b":path", b"/hello"),
            ],
            end_stream=True,
        )
        protocol.transmit()

        status = None
        body = bytearray()
        while True:
            event = await asyncio.wait_for(protocol.events.get(), timeout=3.0)
            if isinstance(event, HeadersReceived) and event.stream_id == stream_id:
                for name, value in event.headers:
                    if name == b":status":
                        status = value
            elif isinstance(event, DataReceived) and event.stream_id == stream_id:
                body.extend(event.data)
                if event.stream_ended:
                    break
        if status != b"200" or bytes(body) != b"hello":
            raise RuntimeError(
                f"unexpected Ada HTTP/3 response: status={status!r} body={body!r}"
            )
        print("aioquic client interoperated with the Ada HTTP/3 server")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=4434)
    arguments = parser.parse_args()
    asyncio.run(main(arguments.port))
