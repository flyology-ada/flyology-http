#!/usr/bin/env python3
"""Compare Flyology's stateful HPACK decoder with python-hyper/hpack."""

from __future__ import annotations

import argparse
import random
import subprocess

from hpack import Encoder


STATUSES = ("200", "204", "206", "304", "400", "404", "500")
NAMES = ("cache-control", "content-type", "etag", "location", "server", "x-test")
WORDS = ("alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "")


def expected_line(headers: list[tuple[str, str]]) -> str:
    status = headers[0][1]
    fields = "".join(f"|{name}={value}" for name, value in headers[1:])
    return f"OK| {status}{fields}"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("oracle", help="path to the Ada differential decoder")
    parser.add_argument("--cases", type=int, default=500)
    arguments = parser.parse_args()

    randomizer = random.Random(0x7541)
    encoder = Encoder()
    process = subprocess.Popen(
        [arguments.oracle],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    assert process.stdin is not None
    assert process.stdout is not None
    try:
        for case in range(arguments.cases):
            if case == arguments.cases // 3:
                encoder.header_table_size = 512
            elif case == 2 * arguments.cases // 3:
                encoder.header_table_size = 4096
            headers = [(":status", randomizer.choice(STATUSES))]
            for _ in range(randomizer.randint(0, 5)):
                headers.append(
                    (randomizer.choice(NAMES), randomizer.choice(WORDS))
                )
            encoded = encoder.encode(headers, huffman=bool(case % 2))
            process.stdin.write(encoded.hex() + "\n")
            process.stdin.flush()
            actual = process.stdout.readline().rstrip("\n")
            expected = expected_line(headers)
            if actual != expected:
                raise AssertionError(
                    f"case {case}: expected {expected!r}, received {actual!r}"
                )

        #  Indexed zero and a literal uppercase field are invalid to the Ada
        #  decoder even though they test different HPACK/HTTP boundaries.
        for malformed in ("80", "0001580131"):
            process.stdin.write(malformed + "\n")
            process.stdin.flush()
            actual = process.stdout.readline().rstrip("\n")
            if actual != "ERROR":
                raise AssertionError(f"malformed {malformed} was accepted: {actual}")
    finally:
        process.stdin.close()
        return_code = process.wait(timeout=5)
        if return_code != 0:
            raise RuntimeError(f"Ada oracle exited with {return_code}")

    print(f"HTTP/2 HPACK differential suite passed ({arguments.cases} cases)")


if __name__ == "__main__":
    main()
