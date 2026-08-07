#!/usr/bin/env python3
"""Compare Flyology's bounded Huffman decoder with python-hyper/hpack."""

from __future__ import annotations

import argparse
import random
import subprocess

from hpack.huffman import HuffmanEncoder
from hpack.huffman_constants import REQUEST_CODES, REQUEST_CODES_LENGTH


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("decoder", help="path to the Ada differential decoder")
    parser.add_argument("--cases", type=int, default=1_000)
    arguments = parser.parse_args()

    randomizer = random.Random(0x9204)
    encoder = HuffmanEncoder(REQUEST_CODES, REQUEST_CODES_LENGTH)
    encoded_cases: list[str] = []
    expected_cases: list[str] = []
    for case in range(arguments.cases):
        length = case % 128 + 1 if case < 128 else randomizer.randrange(1, 129)
        value = bytes(randomizer.randrange(256) for _ in range(length))
        encoded_cases.append(encoder.encode(value).hex())
        expected_cases.append(value.hex())

    malformed = ("00", "ffffffff")
    completed = subprocess.run(
        [arguments.decoder],
        input="\n".join((*encoded_cases, *malformed)) + "\n",
        capture_output=True,
        text=True,
        check=True,
    )
    actual_cases = completed.stdout.splitlines()
    expected_cases.extend("ERROR" for _ in malformed)
    if len(actual_cases) != len(expected_cases):
        raise AssertionError(
            f"expected {len(expected_cases)} responses, received {len(actual_cases)}"
        )
    for case, (actual, expected) in enumerate(zip(actual_cases, expected_cases)):
        if actual != expected:
            raise AssertionError(
                f"case {case}: expected {expected!r}, received {actual!r}"
            )

    print(f"Header Huffman differential suite passed ({arguments.cases} cases)")


if __name__ == "__main__":
    main()
