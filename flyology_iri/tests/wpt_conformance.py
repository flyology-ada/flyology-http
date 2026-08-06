#!/usr/bin/env python3
"""Compare flyology_iri URL results with Ada's pinned WPT data."""

import json
import os
from pathlib import Path
import subprocess
import sys


def encoded(value: str) -> str:
    return value.encode("utf-8", "surrogatepass").hex()


COMPONENTS = (
    "href", "protocol", "username", "password", "host", "hostname", "port",
    "pathname", "search", "hash",
)


def run_case(cli: Path, case: dict) -> tuple[bool, dict[str, str]]:
    base = case.get("base")
    command = [str(cli), encoded(case["input"]), "-" if base is None else encoded(base)]
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    line = result.stdout.rstrip("\n")
    if line.startswith("FAIL"):
        return False, {}
    if not line.startswith("OK\t"):
        return False, {"href": f"<bad-cli-output:{line!r}>"}
    fields = line.split("\t")[1:]
    if len(fields) != len(COMPONENTS):
        return False, {"href": f"<bad-cli-field-count:{len(fields)}>"}
    values = [bytes.fromhex(field).decode("utf-8", "surrogatepass")
              for field in fields]
    return True, dict(zip(COMPONENTS, values))


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: wpt_conformance.py URL_CLI ADA_URL_ROOT", file=sys.stderr)
        return 2
    cli = Path(sys.argv[1])
    wpt = Path(sys.argv[2]) / "tests" / "wpt"
    cases: list[tuple[str, int, dict]] = []
    for filename in ("urltestdata.json", "ada_extra_urltestdata.json"):
        for index, item in enumerate(json.loads((wpt / filename).read_text())):
            if isinstance(item, dict):
                cases.append((filename, index, item))

    matched = 0
    mismatches: list[str] = []
    for filename, index, case in cases:
        success, actual = run_case(cli, case)
        expected_success = not case.get("failure", False)
        wrong_components = [
            name for name in COMPONENTS
            if name in case and actual.get(name) != case[name]
        ] if success else []
        if success == expected_success and not wrong_components:
            matched += 1
            continue
        expected_text = "FAIL" if not expected_success else repr(case.get("href", ""))
        actual_text = "FAIL" if not success else repr(actual.get("href", ""))
        detail = ""
        if wrong_components:
            detail = " components=" + ",".join(
                f"{name}:{actual.get(name)!r}!={case[name]!r}"
                for name in wrong_components
            )
        mismatches.append(
            f"{filename}:{index}: input={case['input']!r} base={case.get('base')!r} "
            f"expected={expected_text} actual={actual_text}{detail}"
        )

    for mismatch in mismatches[:40]:
        print(mismatch)
    print(f"WPT URL conformance: {matched}/{len(cases)} "
          f"({matched * 100.0 / len(cases):.1f}%), mismatches={len(mismatches)}")
    return 0 if not mismatches else 1


if __name__ == "__main__":
    raise SystemExit(main())
