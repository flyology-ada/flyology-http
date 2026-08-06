#!/usr/bin/env python3
"""Deterministic TCP fault proxy for HTTP/2 qualification campaigns."""

from __future__ import annotations

import argparse
import json
import socket
import struct
import threading
import time
from pathlib import Path
from typing import BinaryIO


class Recorder:
    def __init__(self, output: BinaryIO) -> None:
        self.output = output
        self.lock = threading.Lock()

    def write(self, event: str, **values: object) -> None:
        with self.lock:
            self.output.write(
                (json.dumps({"event": event, **values}, sort_keys=True) + "\n").encode()
            )
            self.output.flush()


def reset(channel: socket.socket) -> None:
    try:
        channel.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
    except OSError:
        pass
    try:
        channel.close()
    except OSError:
        pass


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--upstream-host", default="127.0.0.1")
    parser.add_argument("--upstream-port", type=int, required=True)
    parser.add_argument("--port-file", type=Path, required=True)
    parser.add_argument("--log-file", type=Path, required=True)
    parser.add_argument("--chunk-size", type=int, default=65_535)
    parser.add_argument("--delay-ms", type=float, default=0.0)
    parser.add_argument("--reset-after-server-bytes", type=int, default=0)
    arguments = parser.parse_args()
    if arguments.chunk_size <= 0 or arguments.delay_ms < 0:
        parser.error("chunk-size must be positive and delay-ms nonnegative")

    with arguments.log_file.open("wb") as output:
        recorder = Recorder(output)
        with socket.create_server(("127.0.0.1", 0)) as listener:
            arguments.port_file.write_text(
                str(listener.getsockname()[1]), encoding="ascii"
            )
            client, _ = listener.accept()
            upstream = socket.create_connection(
                (arguments.upstream_host, arguments.upstream_port)
            )
            recorder.write("connected")
            stopped = threading.Event()

            def pump(
                source: socket.socket,
                destination: socket.socket,
                direction: str,
            ) -> None:
                transferred = 0
                try:
                    while not stopped.is_set():
                        data = source.recv(65_535)
                        if not data:
                            try:
                                destination.shutdown(socket.SHUT_WR)
                            except OSError:
                                pass
                            break
                        if (
                            direction == "server-to-client"
                            and arguments.reset_after_server_bytes > 0
                            and transferred + len(data)
                            >= arguments.reset_after_server_bytes
                        ):
                            allowed = arguments.reset_after_server_bytes - transferred
                            if allowed > 0:
                                destination.sendall(data[:allowed])
                                transferred += allowed
                            recorder.write(
                                "reset", direction=direction, bytes=transferred
                            )
                            stopped.set()
                            reset(client)
                            reset(upstream)
                            return
                        for offset in range(0, len(data), arguments.chunk_size):
                            destination.sendall(
                                data[offset : offset + arguments.chunk_size]
                            )
                            if arguments.delay_ms:
                                time.sleep(arguments.delay_ms / 1000.0)
                        transferred += len(data)
                except (ConnectionError, OSError) as error:
                    if not stopped.is_set():
                        recorder.write(
                            "transport-error", direction=direction, detail=str(error)
                        )
                        stopped.set()
                finally:
                    recorder.write("finished", direction=direction, bytes=transferred)

            client_to_server = threading.Thread(
                target=pump,
                args=(client, upstream, "client-to-server"),
                daemon=True,
            )
            server_to_client = threading.Thread(
                target=pump,
                args=(upstream, client, "server-to-client"),
                daemon=True,
            )
            client_to_server.start()
            server_to_client.start()
            client_to_server.join()
            server_to_client.join()
            reset(client)
            reset(upstream)


if __name__ == "__main__":
    main()
