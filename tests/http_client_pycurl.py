#!/usr/bin/env python3
"""Run one normalized easy/multi PycURL observation for the shared corpus."""

from __future__ import annotations

import argparse
import io


def final_header_block(raw_lines: list[bytes]) -> tuple[list[tuple[str, str]], list[tuple[str, str]]]:
    blocks: list[list[tuple[str, str]]] = []
    current: list[tuple[str, str]] | None = None
    trailing: list[tuple[str, str]] = []
    for raw in raw_lines:
        line = raw.rstrip(b"\r\n")
        if line.startswith(b"HTTP/"):
            if current is not None:
                blocks.append(current)
            current = []
        elif not line:
            if current is not None:
                blocks.append(current)
                current = None
        elif b":" in line:
            name, value = line.split(b":", 1)
            field = (name.decode("latin-1").lower(), value.strip().decode("latin-1"))
            if current is None:
                trailing.append(field)
            else:
                current.append(field)
    if current is not None:
        blocks.append(current)
    return (blocks[-1] if blocks else []), trailing


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("style", choices=("easy", "multi"))
    parser.add_argument("protocol", choices=("h1", "h2", "h3"))
    parser.add_argument("url")
    arguments = parser.parse_args()

    import pycurl

    content = io.BytesIO()
    header_lines: list[bytes] = []
    handle = pycurl.Curl()
    handle.setopt(pycurl.URL, arguments.url)
    handle.setopt(pycurl.NOSIGNAL, 1)
    handle.setopt(pycurl.FOLLOWLOCATION, 0)
    handle.setopt(pycurl.CONNECTTIMEOUT_MS, 3_000)
    handle.setopt(pycurl.TIMEOUT_MS, 3_000)
    handle.setopt(pycurl.WRITEFUNCTION, content.write)
    handle.setopt(pycurl.HEADERFUNCTION, header_lines.append)
    versions = {
        "h1": pycurl.CURL_HTTP_VERSION_1_1,
        "h2": pycurl.CURL_HTTP_VERSION_2_PRIOR_KNOWLEDGE,
        "h3": pycurl.CURL_HTTP_VERSION_3ONLY,
    }
    handle.setopt(pycurl.HTTP_VERSION, versions[arguments.protocol])

    if arguments.style == "easy":
        handle.perform()
    else:
        multi = pycurl.CurlMulti()
        multi.add_handle(handle)
        running = 1
        while running:
            while True:
                result, running = multi.perform()
                if result != pycurl.E_CALL_MULTI_PERFORM:
                    break
            if running:
                multi.select(0.1)
        while True:
            remaining, successful, failed = multi.info_read()
            if failed:
                _, code, detail = failed[0]
                raise RuntimeError(f"PycURL multi transfer failed ({code}): {detail}")
            if not remaining:
                break
        multi.remove_handle(handle)
        multi.close()

    protocol_values = {
        pycurl.CURL_HTTP_VERSION_1_0: "h1",
        pycurl.CURL_HTTP_VERSION_1_1: "h1",
        pycurl.CURL_HTTP_VERSION_2_0: "h2",
        pycurl.CURL_HTTP_VERSION_3: "h3",
    }
    headers, trailers = final_header_block(header_lines)
    print(f"status={int(handle.getinfo(pycurl.RESPONSE_CODE))}")
    print(f"protocol={protocol_values[handle.getinfo(pycurl.INFO_HTTP_VERSION)]}")
    print(f"body_hex={content.getvalue().hex()}")
    for name, value in headers:
        if name.startswith("x-corpus-"):
            print(f"header={name}:{value}")
    for name, value in trailers:
        if name.startswith("x-corpus-"):
            print(f"trailer={name}:{value}")
    handle.close()


if __name__ == "__main__":
    main()
