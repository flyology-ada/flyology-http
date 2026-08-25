#!/usr/bin/env python3
"""Validate and query the protocol/API-neutral HTTP client scenario corpus."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re


PROTOCOLS = {"h1", "h2", "h3"}
API_STYLES = {"sync-head", "composable-buffer", "composable-sink", "established-child"}
DIFFERENTIALS = {"pycurl-easy", "pycurl-multi", "aioquic-peer"}
SOURCE_KINDS = {"standard", "upstream-suite", "oracle-model", "project-contract"}
PRE_ADMISSION = {"pre-admission-rejected"}
NON_SUCCESS_BUFFER_EFFECTS = {"zero", "unchanged"}
EXECUTION_MODELS = {"native", "lightweight"}


def load(path: Path) -> dict:
    with path.open(encoding="utf-8") as stream:
        return json.load(stream)


def validate(document: dict, corpus_path: Path | None = None) -> None:
    assert document["schema"] == 2
    source_catalog = document["sources"]
    sources = set(source_catalog)
    for identifier, source in source_catalog.items():
        assert source["kind"] in SOURCE_KINDS, identifier
        assert source["title"].strip(), identifier
        if source["kind"] == "project-contract":
            assert set(source) == {"kind", "title", "path"}, identifier
            assert source["path"] and ".." not in Path(source["path"]).parts, identifier
        else:
            assert set(source) == {"kind", "title", "url"}, identifier
            assert source["url"].startswith("https://"), identifier
            if source["kind"] == "standard":
                assert source["url"].startswith("https://www.rfc-editor.org/"), identifier
    cases = document["cases"]
    assert len(cases) >= 67, "the maintained client corpus must not shrink below 67 vectors"
    identifiers = [case["id"] for case in cases]
    assert len(identifiers) == len(set(identifiers)), "duplicate case id"
    assert {"complete-fixed", "blocked-source-early-final", "malformed-stream-isolation", "lost-final-response"} <= set(identifiers)

    covered_protocols: set[str] = set()
    covered_styles: set[str] = set()
    differential_cases = 0
    referenced_payloads: set[Path] = set()
    for case in cases:
        protocols = set(case["protocols"])
        styles = set(case["api_styles"])
        expect = case["expect"]
        assert protocols and protocols <= PROTOCOLS, case["id"]
        assert styles and styles <= API_STYLES, case["id"]
        covered_protocols |= protocols
        covered_styles |= styles
        differential = case.get("differential")
        payloads = case.get("payloads", {})
        assert set(payloads) <= protocols, case["id"]
        for protocol, payload in payloads.items():
            assert set(payload) == {"path", "sha256"}, case["id"]
            relative = Path(payload["path"])
            assert not relative.is_absolute() and ".." not in relative.parts, case["id"]
            assert relative.suffix == ".bin", case["id"]
            assert relative not in referenced_payloads, (case["id"], relative)
            referenced_payloads.add(relative)
            assert re.fullmatch(r"[0-9a-f]{64}", payload["sha256"]), case["id"]
            if corpus_path is not None:
                binary_path = corpus_path.parent / relative
                data = binary_path.read_bytes()
                assert hashlib.sha256(data).hexdigest() == payload["sha256"], case["id"]
                mirror_path = binary_path.with_suffix(".hex")
                assert bytes.fromhex(mirror_path.read_text(encoding="ascii")) == data, case["id"]
        if differential is not None:
            differential_cases += 1
            assert differential, case["id"]
            covered_differential_protocols: set[str] = set()
            for group in differential:
                assert set(group) == {"implementations", "protocols"}, case["id"]
                implementations = set(group["implementations"])
                group_protocols = set(group["protocols"])
                assert implementations and implementations <= DIFFERENTIALS, case["id"]
                assert group_protocols and group_protocols <= protocols, case["id"]
                if "aioquic-peer" in implementations:
                    assert implementations == {"aioquic-peer"}, case["id"]
                    assert group_protocols == {"h3"}, case["id"]
                else:
                    assert implementations == {"pycurl-easy", "pycurl-multi"}, case["id"]
                    assert group_protocols == {"h1", "h2"}, case["id"]
                assert not (covered_differential_protocols & group_protocols), case["id"]
                covered_differential_protocols |= group_protocols
            assert expect["kind"] == "response-complete", case["id"]
        assert case["provenance"], case["id"]
        for citation in case["provenance"]:
            source_id, separator, locator = citation.partition(":")
            assert source_id in sources, (case["id"], citation)
            source_kind = source_catalog[source_id]["kind"]
            if source_kind in {"standard", "upstream-suite", "oracle-model"}:
                assert separator and locator.strip(), (case["id"], citation)
        if expect["kind"] in PRE_ADMISSION:
            assert expect["certainty"] == "not-admitted", case["id"]
        if expect["kind"] == "response-complete":
            assert expect["certainty"] == "response-observed", case["id"]
        if "composable-buffer" in styles and expect["kind"] != "response-complete":
            assert expect["body_effect"] in NON_SUCCESS_BUFFER_EFFECTS, case["id"]
        if "required_length" in expect:
            required = expect["required_length"]
            assert set(required) == {"known", "bytes"}, case["id"]
            assert isinstance(required["known"], bool), case["id"]
            assert isinstance(required["bytes"], int), case["id"]
            assert required["bytes"] >= 0, case["id"]
            assert required["known"] or required["bytes"] == 0, case["id"]
        if expect.get("automatic_replay") is False:
            assert expect["kind"] != "response-complete", case["id"]

    assert covered_protocols == PROTOCOLS
    assert covered_styles == API_STYLES
    assert differential_cases >= 4
    assert len(referenced_payloads) >= 20, "the byte-exact fixture corpus must not shrink below 20 payloads"
    if corpus_path is not None:
        fixture_root = corpus_path.parent / "fixtures"
        binary_files = {
            path.relative_to(corpus_path.parent)
            for path in fixture_root.glob("*.bin")
        }
        mirror_files = {
            path.with_suffix(".bin").relative_to(corpus_path.parent)
            for path in fixture_root.glob("*.hex")
        }
        assert binary_files == referenced_payloads, "unreferenced or missing .bin fixture"
        assert mirror_files == referenced_payloads, "unreferenced or missing .hex fixture mirror"


def validate_execution(document: dict, execution: dict, repository: Path) -> None:
    assert execution["schema"] == 1
    assert execution["default_status"] == "evidence-only"
    cases = {case["id"]: case for case in document["cases"]}
    covered: set[tuple[str, str, str]] = set()
    for group in execution["executed"]:
        assert set(group) == {
            "cases", "protocols", "api_styles", "models", "runner"
        }, group
        identifiers = set(group["cases"])
        protocols = set(group["protocols"])
        styles = set(group["api_styles"])
        models = set(group["models"])
        assert identifiers and identifiers <= set(cases), group
        assert protocols and protocols <= PROTOCOLS, group
        assert styles and styles <= API_STYLES, group
        assert models and models <= EXECUTION_MODELS, group
        runners = group["runner"].split(";")
        assert runners and all(runners), group
        for runner in runners:
            path = Path(runner)
            assert not path.is_absolute() and ".." not in path.parts, group
            assert (repository / path).is_file(), runner
        for identifier in identifiers:
            case = cases[identifier]
            assert protocols <= set(case["protocols"]), group
            assert styles <= set(case["api_styles"]), group
            for protocol in protocols:
                for style in styles:
                    key = (identifier, protocol, style)
                    assert key not in covered, ("duplicate execution claim", key)
                    covered.add(key)

    #  These consumer-critical tuples may never silently fall back to the
    #  evidence-only default. They are the publication ambiguity, ownership,
    #  and composition boundary for Object Storage and Flyology.DB.
    for identifier, styles in {
        "lost-final-response": {"sync-head", "composable-buffer"},
        "stale-after-handoff-no-replay": {"sync-head", "composable-buffer"},
        "parent-continue-after": {"established-child"},
        "abandonment-drain": {"composable-buffer"},
        "cancel-after-admission": {"composable-buffer"},
        "blocked-source-early-final": {"composable-buffer"},
    }.items():
        for protocol in PROTOCOLS:
            for style in styles:
                assert (identifier, protocol, style) in covered, (
                    "required execution tuple is only evidence", identifier,
                    protocol, style
                )

    all_tuples = {
        (case["id"], protocol, style)
        for case in document["cases"]
        for protocol in case["protocols"]
        for style in case["api_styles"]
    }
    assert covered <= all_tuples
    execution["summary"] = {
        "executed": len(covered),
        "evidence_only": len(all_tuples - covered),
        "total": len(all_tuples),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("corpus", type=Path)
    parser.add_argument("--protocol", choices=sorted(PROTOCOLS))
    parser.add_argument("--api", choices=sorted(API_STYLES))
    parser.add_argument("--execution", type=Path)
    arguments = parser.parse_args()
    document = load(arguments.corpus)
    validate(document, arguments.corpus)
    if arguments.execution is not None:
        execution = load(arguments.execution)
        validate_execution(document, execution, arguments.corpus.parents[2])
    for case in document["cases"]:
        if arguments.protocol and arguments.protocol not in case["protocols"]:
            continue
        if arguments.api and arguments.api not in case["api_styles"]:
            continue
        print(case["id"])


if __name__ == "__main__":
    main()
