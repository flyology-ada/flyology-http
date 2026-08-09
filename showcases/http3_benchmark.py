#!/usr/bin/env python3
"""Repeatable aioquic load driver for the unified Flyology HTTP route.

This is a benchmark fixture, not an interoperability oracle.  It keeps QUIC
connections open, issues requests in bounded stream batches, and reports the
handshake and request latency distributions separately.
"""

import argparse
import asyncio
import concurrent.futures
import json
import math
import ssl
import statistics
import time

from aioquic.asyncio import QuicConnectionProtocol, connect
from aioquic.h3.connection import H3_ALPN, H3Connection
from aioquic.h3.events import DataReceived, HeadersReceived
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.events import ConnectionTerminated, ProtocolNegotiated, QuicEvent
from aioquic.tls import CipherSuite


class BenchmarkProtocol(QuicConnectionProtocol):
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


async def request_batch(
    protocol, path: str, expected_body: bytes, count: int, timeout: float
):
    started = {}
    bodies = {}
    statuses = {}
    for _ in range(count):
        stream_id = protocol._quic.get_next_available_stream_id()
        started[stream_id] = time.perf_counter()
        bodies[stream_id] = bytearray()
        protocol.http.send_headers(
            stream_id,
            [
                (b":method", b"GET"),
                (b":scheme", b"https"),
                (b":authority", b"localhost"),
                (b":path", path.encode("ascii")),
            ],
            end_stream=True,
        )
    protocol.transmit()

    ended = set()
    latencies = []
    while len(ended) != count:
        event = await asyncio.wait_for(protocol.events.get(), timeout=timeout)
        if isinstance(event, ConnectionTerminated):
            raise RuntimeError(
                f"connection closed early: code={event.error_code} "
                f"ended={len(ended)}/{count}"
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
        if (
            statuses.get(stream_id) != b"200"
            or bytes(bodies[stream_id]) != expected_body
        ):
            raise RuntimeError(
                f"bad response stream={stream_id} status={statuses.get(stream_id)!r} "
                f"body={bytes(bodies[stream_id])!r}"
            )
    return latencies


async def run_connection(
    port: int,
    path: str,
    expected_body: bytes,
    requests: int,
    streams: int,
    timeout: float,
):
    connected_at = time.perf_counter()
    async with connect(
        "127.0.0.1",
        port,
        configuration=configuration(),
        create_protocol=BenchmarkProtocol,
    ) as protocol:
        await asyncio.wait_for(protocol.wait_connected(), timeout=timeout)
        handshake = time.perf_counter() - connected_at
        latencies = []
        remaining = requests
        while remaining:
            count = min(streams, remaining)
            latencies.extend(
                await request_batch(
                    protocol, path, expected_body, count, timeout
                )
            )
            remaining -= count
    return handshake, latencies


def percentile(values, fraction: float) -> float:
    if not values:
        return 0.0
    return values[min(len(values) - 1, math.ceil(len(values) * fraction) - 1)]


async def run_worker(
    port, path, expected_body, requests, connections, streams, timeout
):
    per_connection = [requests // connections] * connections
    for index in range(requests % connections):
        per_connection[index] += 1
    results = await asyncio.gather(
        *(
            run_connection(
                port,
                path,
                expected_body,
                count,
                streams,
                timeout,
            )
            for count in per_connection
            if count
        )
    )
    return results


def run_worker_process(parameters):
    return asyncio.run(run_worker(*parameters))


def distribute(total: int, workers: int):
    values = [total // workers] * workers
    for index in range(total % workers):
        values[index] += 1
    return values


def benchmark(arguments):
    if arguments.response_bytes is None:
        path = arguments.path
        expected_body = b"hello test"
    else:
        if arguments.response_bytes < len(b"hello "):
            raise ValueError("response bytes cannot be smaller than 6")
        name = "x" * (arguments.response_bytes - len(b"hello "))
        path = "/hello/" + name
        expected_body = ("hello " + name).encode("ascii")

    request_counts = distribute(arguments.requests, arguments.workers)
    connection_counts = distribute(arguments.connections, arguments.workers)
    parameters = [
        (
            arguments.port,
            path,
            expected_body,
            request_counts[index],
            connection_counts[index],
            arguments.streams,
            arguments.timeout,
        )
        for index in range(arguments.workers)
    ]

    started = time.perf_counter()
    if arguments.workers == 1:
        worker_results = [run_worker_process(parameters[0])]
    else:
        with concurrent.futures.ProcessPoolExecutor(
            max_workers=arguments.workers
        ) as executor:
            worker_results = list(executor.map(run_worker_process, parameters))
    wall = time.perf_counter() - started
    results = [result for worker in worker_results for result in worker]
    handshakes = sorted(handshake for handshake, _ in results)
    latencies = sorted(value for _, group in results for value in group)
    summary = {
        "protocol": "h3",
        "requests": arguments.requests,
        "workers": arguments.workers,
        "connections": len(results),
        "streams": arguments.streams,
        "connection_reuse": arguments.requests / len(results),
        "wall_s": wall,
        "requests_per_s": len(latencies) / wall,
        "response_bytes": len(expected_body),
        "latency_ms": {
            "mean": statistics.fmean(latencies) * 1000,
            "p50": percentile(latencies, 0.50) * 1000,
            "p95": percentile(latencies, 0.95) * 1000,
            "p99": percentile(latencies, 0.99) * 1000,
            "max": latencies[-1] * 1000,
        },
        "handshake_ms": {
            "mean": statistics.fmean(handshakes) * 1000,
            "p50": percentile(handshakes, 0.50) * 1000,
            "p95": percentile(handshakes, 0.95) * 1000,
            "max": handshakes[-1] * 1000,
        },
    }
    print(json.dumps(summary, sort_keys=True))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=18443)
    parser.add_argument("--path", default="/hello/test")
    parser.add_argument("--response-bytes", type=int)
    parser.add_argument("--requests", type=int, default=10000)
    parser.add_argument("--connections", type=int, default=16)
    parser.add_argument("--streams", type=int, default=1)
    parser.add_argument("--workers", type=int, default=1)
    parser.add_argument("--timeout", type=float, default=10.0)
    arguments = parser.parse_args()
    if (
        arguments.requests < 1
        or arguments.connections < 1
        or arguments.streams < 1
        or arguments.workers < 1
    ):
        parser.error("requests, connections, streams, and workers must be positive")
    if arguments.workers > min(arguments.requests, arguments.connections):
        parser.error("workers cannot exceed requests or connections")
    benchmark(arguments)


if __name__ == "__main__":
    main()
