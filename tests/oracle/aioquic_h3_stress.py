#!/usr/bin/env python3
"""Bounded hostile-input and concurrency stress against the Ada H3 server."""

import argparse
import asyncio
import random
import socket
import ssl
import time

from aioquic.asyncio import QuicConnectionProtocol, connect
from aioquic.h3.connection import H3_ALPN, H3Connection
from aioquic.h3.events import DataReceived, HeadersReceived
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.events import ConnectionTerminated, ProtocolNegotiated, QuicEvent
from aioquic.tls import CipherSuite


class StressProtocol(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.http = None
        self.events = asyncio.Queue()

    def quic_event_received(self, event: QuicEvent) -> None:
        if isinstance(event, ProtocolNegotiated):
            self.http = H3Connection(self._quic)
        if isinstance(event, ConnectionTerminated):
            self.events.put_nowait(event)
        if self.http is not None:
            for item in self.http.handle_event(event):
                self.events.put_nowait(item)


def configuration() -> QuicConfiguration:
    return QuicConfiguration(
        alpn_protocols=H3_ALPN,
        cipher_suites=[CipherSuite.AES_128_GCM_SHA256],
        is_client=True,
        max_datagram_size=1200,
        server_name="localhost",
        verify_mode=ssl.CERT_NONE,
    )


async def request_connection(port: int, requests: int, timeout: float):
    started = {}
    bodies = {}
    statuses = {}
    latencies = []
    async with connect(
        "127.0.0.1",
        port,
        configuration=configuration(),
        create_protocol=StressProtocol,
    ) as protocol:
        await asyncio.wait_for(protocol.wait_connected(), timeout=timeout)
        for _ in range(requests):
            stream_id = protocol._quic.get_next_available_stream_id()
            started[stream_id] = time.perf_counter()
            bodies[stream_id] = bytearray()
            protocol.http.send_headers(
                stream_id,
                [
                    (b":method", b"GET"),
                    (b":scheme", b"https"),
                    (b":authority", b"localhost"),
                    (b":path", b"/"),
                ],
                end_stream=True,
            )
            protocol.transmit()

        ended = set()
        while len(ended) != requests:
            try:
                event = await asyncio.wait_for(protocol.events.get(), timeout=timeout)
            except asyncio.TimeoutError as error:
                raise RuntimeError(
                    f"response timeout: ended={len(ended)}/{requests}"
                ) from error
            if isinstance(event, ConnectionTerminated):
                raise RuntimeError(
                    f"connection closed early: code={event.error_code} "
                    f"ended={len(ended)}/{requests}"
                )
            if isinstance(event, HeadersReceived) and event.stream_id in started:
                for name, value in event.headers:
                    if name == b":status":
                        statuses[event.stream_id] = value
                if event.stream_ended:
                    ended.add(event.stream_id)
                    latencies.append(time.perf_counter() - started[event.stream_id])
            elif isinstance(event, DataReceived) and event.stream_id in started:
                bodies[event.stream_id].extend(event.data)
                if event.stream_ended:
                    ended.add(event.stream_id)
                    latencies.append(time.perf_counter() - started[event.stream_id])

        for stream_id in started:
            if statuses.get(stream_id) != b"200" or bytes(bodies[stream_id]) != b"h3spec":
                raise RuntimeError(
                    f"bad response stream={stream_id} "
                    f"status={statuses.get(stream_id)!r} body={bytes(bodies[stream_id])!r}"
                )
    return latencies


async def load_case(port: int, connections: int, concurrency: int, requests: int):
    semaphore = asyncio.Semaphore(concurrency)
    failures = []

    async def run_one(index: int):
        async with semaphore:
            try:
                return await request_connection(port, requests, 5.0)
            except Exception as error:  # Report every peer-visible failure.
                failures.append((index, type(error).__name__, str(error)))
                return []

    before = time.perf_counter()
    groups = await asyncio.gather(*(run_one(index) for index in range(connections)))
    elapsed = time.perf_counter() - before
    latencies = sorted(value for group in groups for value in group)

    def percentile(fraction: float) -> float:
        if not latencies:
            return 0.0
        return latencies[min(len(latencies) - 1, int(len(latencies) * fraction))]

    print(
        "LOAD "
        f"connections={connections} concurrency={concurrency} streams={requests} "
        f"ok={len(latencies)}/{connections * requests} failures={len(failures)} "
        f"wall={elapsed:.3f}s rate={len(latencies) / elapsed:.1f}/s "
        f"p50={percentile(0.50) * 1000:.1f}ms "
        f"p95={percentile(0.95) * 1000:.1f}ms "
        f"max={(latencies[-1] if latencies else 0) * 1000:.1f}ms",
        flush=True,
    )
    if failures:
        raise RuntimeError(f"legitimate load failures: {failures[:5]}")


async def malformed_connection(port: int, payload: bytes):
    async with connect(
        "127.0.0.1",
        port,
        configuration=configuration(),
        create_protocol=StressProtocol,
    ) as protocol:
        await asyncio.wait_for(protocol.wait_connected(), timeout=3.0)
        stream_id = protocol._quic.get_next_available_stream_id()
        protocol._quic.send_stream_data(stream_id, payload, end_stream=True)
        protocol.transmit()
        try:
            event = await asyncio.wait_for(protocol.events.get(), timeout=0.1)
            return "closed" if isinstance(event, ConnectionTerminated) else "event"
        except asyncio.TimeoutError:
            return "quiet"


async def malformed_case(port: int, cases: int, seed: int):
    rng = random.Random(seed)
    corpus = [
        b"", b"\x00", b"\x01\x00", b"\x04\x00", b"\x05\x00",
        b"\x09\x00", b"\x04\x40\x00", b"\x01\x40\x00",
        b"\xff\xff\xff\xff\xff\xff\xff\xff", b"\x01\x02\x00\x00",
    ]
    outcomes = {"closed": 0, "event": 0, "quiet": 0, "rejected": 0}
    before = time.perf_counter()
    for index in range(cases):
        value = bytearray(corpus[index % len(corpus)])
        for _ in range(rng.randrange(1, 9)):
            if value and rng.randrange(3):
                value[rng.randrange(len(value))] ^= 1 << rng.randrange(8)
            elif len(value) < 256:
                value.insert(rng.randrange(len(value) + 1), rng.randrange(256))
        try:
            outcomes[await malformed_connection(port, bytes(value))] += 1
        except Exception:
            outcomes["rejected"] += 1
    elapsed = time.perf_counter() - before
    print(
        f"MALFORMED cases={cases} seed={seed:#x} wall={elapsed:.3f}s "
        f"outcomes={outcomes}",
        flush=True,
    )


def udp_noise(port: int, cases: int, seed: int):
    rng = random.Random(seed)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    before = time.perf_counter()
    for index in range(cases):
        size = 1350 if index % 5 == 0 else rng.randrange(1, 1351)
        sock.sendto(rng.randbytes(size), ("127.0.0.1", port))
    sock.close()
    elapsed = time.perf_counter() - before
    print(
        f"UDP_NOISE datagrams={cases} bytes<=1350 wall={elapsed:.3f}s "
        f"rate={cases / elapsed:.1f}/s",
        flush=True,
    )


async def main(
    port: int, noise: int, malformed: int, seed: int, peak_concurrency: int
):
    udp_noise(port, noise, seed)
    await asyncio.sleep(0.1)
    await load_case(port, 1, 1, 1)
    await malformed_case(port, malformed, seed)
    await load_case(port, 1, 1, 1)
    for connections, concurrency in ((16, 1), (32, 4), (64, 8), (128, 8)):
        await load_case(port, connections, concurrency, 5)
    await load_case(port, peak_concurrency, peak_concurrency, 1)
    await load_case(port, 1, 1, 1)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=4438)
    parser.add_argument("--noise", type=int, default=10000)
    parser.add_argument("--malformed", type=int, default=64)
    parser.add_argument("--seed", type=lambda value: int(value, 0), default=0x9114)
    parser.add_argument("--peak-concurrency", type=int, default=256)
    args = parser.parse_args()
    asyncio.run(
        main(
            args.port,
            args.noise,
            args.malformed,
            args.seed,
            args.peak_concurrency,
        )
    )
