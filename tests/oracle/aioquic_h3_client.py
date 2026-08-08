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
        get_stream_id = protocol._quic.get_next_available_stream_id()
        protocol.http.send_headers(
            get_stream_id,
            [
                (b":method", b"GET"),
                (b":scheme", b"https"),
                (b":authority", b"localhost"),
                (b":path", b"/hello"),
            ],
            end_stream=True,
        )
        post_stream_id = protocol._quic.get_next_available_stream_id()
        protocol.http.send_headers(
            post_stream_id,
            [
                (b":method", b"POST"),
                (b":scheme", b"https"),
                (b":authority", b"localhost"),
                (b":path", b"/echo"),
                (b"content-length", b"7"),
                (b"x-oracle", b"aioquic"),
            ],
            end_stream=False,
        )
        protocol.http.send_data(post_stream_id, b"payload", end_stream=True)
        protocol.transmit()

        expected = {
            get_stream_id: (b"200", b"hello"),
            post_stream_id: (b"201", b"echo:payload"),
        }
        statuses = {}
        response_headers = {}
        bodies = {stream_id: bytearray() for stream_id in expected}
        ended = set()
        while len(ended) != len(expected):
            event = await asyncio.wait_for(protocol.events.get(), timeout=3.0)
            if isinstance(event, HeadersReceived) and event.stream_id in expected:
                for name, value in event.headers:
                    if name == b":status":
                        statuses[event.stream_id] = value
                    else:
                        response_headers.setdefault(event.stream_id, {})[name] = value
                if event.stream_ended:
                    ended.add(event.stream_id)
            elif isinstance(event, DataReceived) and event.stream_id in expected:
                bodies[event.stream_id].extend(event.data)
                if event.stream_ended:
                    ended.add(event.stream_id)
        for stream_id, (expected_status, expected_body) in expected.items():
            if statuses.get(stream_id) != expected_status or bytes(
                bodies[stream_id]
            ) != expected_body:
                raise RuntimeError(
                    "unexpected Ada HTTP/3 response: "
                    f"stream={stream_id} status={statuses.get(stream_id)!r} "
                    f"body={bodies[stream_id]!r}"
                )
        if response_headers.get(post_stream_id, {}).get(b"x-echo") != b"accepted":
            raise RuntimeError("Ada HTTP/3 response omitted the X-Echo header")
        print("aioquic client interoperated with the Ada HTTP/3 server")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=4434)
    arguments = parser.parse_args()
    asyncio.run(main(arguments.port))
