#!/usr/bin/env python3
"""File the drafted issue bodies under review/filing/ on GitHub.

Usage:
  file_issues.py --dry-run            # validate and print what would be filed
  file_issues.py --file               # create the issues, in ORDER, and write ISSUES.md
  file_issues.py --resolve            # second pass: replace remaining placeholders in
                                      # already-filed issues and in the local documents

Each body file has a header:
  Title: ...
  Labels: bug[, documentation]
  Refs: ID, ID | none
followed by a blank line and the markdown body. Cross-references are written as
{{ISSUE:<ID>}} and are replaced with the issue URL when known. ORDER lists the
filing sequence; referenced issues are filed before the issues that cite them
where possible, and the --resolve pass patches the rest with `gh issue edit`.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

REPO = "flyology-ada/flyology-http"
HERE = Path(__file__).resolve().parent
REVIEW = HERE.parent
ROOT = REVIEW.parent
MAPPING = REVIEW / "ISSUES.json"
ISSUES_MD = REVIEW / "ISSUES.md"

# Filing order. review/filing/ORDER.txt lists one finding id per line, in the
# sequence the issues are created: an issue that is cross-referenced is filed
# before the issue citing it wherever the dependency allows, and --resolve
# patches the rest. Blank lines and lines starting with # are ignored.
AREAS = [
    "H1-SERVER", "ROUTING-MW", "H2", "H3-QPACK", "QUIC-TRANSPORT", "QUIC-TLS",
    "H1-CLIENT", "CLIENT-POOL", "WEBSOCKET", "SSE", "IRI", "LIFETIME",
]
ORDER_FILE = HERE / "ORDER.txt"


def load_order() -> list[str]:
    if ORDER_FILE.exists():
        order = [line.strip() for line in ORDER_FILE.read_text().splitlines()]
        return [line for line in order if line and not line.startswith("#")]
    # Fall back to every drafted body, grouped by AREAS then numerically.
    found = []
    for path in HERE.glob("*.md"):
        if path.name == "STYLE.md":
            continue
        found.append(path.stem)

    def key(fid: str) -> tuple[int, int, str]:
        for index, area in enumerate(AREAS):
            if fid.startswith(area + "-"):
                tail = fid[len(area) + 1:]
                digits = re.match(r"[0-9]+", tail)
                return (index, int(digits.group(0)) if digits else 0, tail)
        return (len(AREAS), 0, fid)

    return sorted(found, key=key)


ORDER = load_order()
VALID_LABELS = {"bug", "documentation"}
SEVERITY_LABELS = {"P0", "P1", "P2"}
TALLY = REVIEW / "TALLY.json"


def load_severities() -> dict[str, str]:
    """Finding id to P0/P1/P2, read from the verification tally.

    The severity label is applied at filing time rather than written into each
    body's Labels line, so it cannot drift from the verdict the verification
    pass recorded.
    """
    if not TALLY.exists():
        return {}
    out = {}
    for row in json.loads(TALLY.read_text()):
        if row.get("severity") in SEVERITY_LABELS:
            out.setdefault(row["id"], row["severity"])
    return out


SEVERITY = load_severities()
PLACEHOLDER = re.compile(r"\{\{ISSUE:([A-Z0-9-]+-[0-9]+[a-z]?)\}\}")
INTERNAL_ID = re.compile(
    r"\b(H1-CLIENT|H1-SERVER|ROUTING-MW|CLIENT-POOL|H2|H3-QPACK|QUIC-TRANSPORT|"
    r"QUIC-TLS|WEBSOCKET|SSE|IRI|LIFETIME)-[0-9]+[a-z]?\b")
# Words that must never reach a public issue. Domain words this repository
# legitimately uses stay out of this list: "audit" names real test files
# (tests/http_server_audit.adb), and AGENTS.md is the rule reference issues are
# required to cite.
FORBIDDEN = re.compile(
    r"(?i)(?<![.\w])("
    r"claude|opus|fable|sonnet|anthropic|"
    r"reviewer agent|verifier agent|discovery agent|subagent|"
    r"prior audit|previous audit|earlier audit|FINDGINGS|"
    r"scratchpad|FINDINGS\.md|review/|\.claude|"
    r"tests/repros|repro_[a-z0-9_]+|Repro_Support|run-all\.sh"
    r")\b"
)
REQUIRED_SECTIONS = ["## Summary", "## Problem", "## What should happen",
                     "## Suggested treatment", "## Severity"]


def parse(path: Path) -> dict:
    text = path.read_text()
    head, _, body = text.partition("\n\n")
    fields = {}
    for line in head.splitlines():
        key, _, value = line.partition(":")
        fields[key.strip()] = value.strip()
    return {"id": path.stem, "title": fields.get("Title", ""),
            "labels": fields.get("Labels", ""), "refs": fields.get("Refs", ""),
            "body": body.strip() + "\n", "path": path}


def validate(item: dict, known: set[str]) -> list[str]:
    problems = []
    if not item["title"] or len(item["title"]) > 130:
        problems.append("title missing or over 130 characters")
    if item["title"].endswith("."):
        problems.append("title ends with a period")
    labels = {l.strip() for l in item["labels"].split(",") if l.strip()}
    if not labels or not labels <= (VALID_LABELS | SEVERITY_LABELS):
        problems.append(f"labels invalid: {item['labels']!r}")
    if item["id"] not in SEVERITY and not (labels & SEVERITY_LABELS):
        problems.append("no severity in the tally and none declared in Labels")
    body = item["body"]
    for section in REQUIRED_SECTIONS:
        if section not in body:
            problems.append(f"missing section {section}")
    if "## What happens now" not in body and "## Failure scenario" not in body:
        problems.append("missing What happens now / Failure scenario")
    if "Commit `f078732`" not in body:
        problems.append("Problem section does not start with the commit")
    for m in INTERNAL_ID.finditer(item["title"] + "\n" + PLACEHOLDER.sub("", body)):
        problems.append(f"internal id leaked: {m.group(0)}")
    for m in FORBIDDEN.finditer(item["title"] + "\n" + body):
        problems.append(f"forbidden word: {m.group(0)}")
    for m in PLACEHOLDER.finditer(body):
        if m.group(1) not in known:
            problems.append(f"placeholder to unknown finding {m.group(1)}")
    if "—" in body or "—" in item["title"]:
        problems.append("em-dash present")
    return problems


def load_mapping() -> dict:
    if MAPPING.exists():
        return json.loads(MAPPING.read_text())
    return {}


def save_mapping(mapping: dict) -> None:
    MAPPING.write_text(json.dumps(mapping, indent=2, sort_keys=True) + "\n")
    lines = ["# Filed issues", "",
             f"Repository: https://github.com/{REPO}. Filed from review commit f078732.", "",
             "| Finding | Severity | Issue | Title |",
             "| --- | --- | --- | --- |"]
    for fid in ORDER:
        if fid in mapping:
            entry = mapping[fid]
            sev = entry.get("severity") or SEVERITY.get(fid, "")
            lines.append(f"| {fid} | {sev} | [#{entry['number']}]({entry['url']}) "
                         f"| {entry['title']} |")
    ISSUES_MD.write_text("\n".join(lines) + "\n")


def substitute(body: str, mapping: dict) -> tuple[str, list[str]]:
    unresolved = []

    def repl(m: re.Match) -> str:
        fid = m.group(1)
        if fid in mapping:
            return mapping[fid]["url"]
        unresolved.append(fid)
        return m.group(0)

    return PLACEHOLDER.sub(repl, body), unresolved


def gh(*args: str) -> str:
    """Run gh, retrying on secondary rate limits or transient failures."""
    import time
    for attempt in range(1, 4):
        result = subprocess.run(["gh", *args], capture_output=True, text=True)
        if result.returncode == 0:
            return result.stdout.strip()
        print(f"gh attempt {attempt} failed: {result.stderr.strip()[:300]}", file=sys.stderr)
        time.sleep(90 if "rate limit" in result.stderr.lower() else 20)
    raise RuntimeError("gh failed three times: " + " ".join(args[:3]))


def main() -> int:
    ap = argparse.ArgumentParser()
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--dry-run", action="store_true")
    mode.add_argument("--file", action="store_true")
    mode.add_argument("--resolve", action="store_true")
    ap.add_argument("--only", nargs="*", help="restrict to these finding ids")
    args = ap.parse_args()

    items = {}
    missing = []
    for fid in ORDER:
        path = HERE / f"{fid}.md"
        if path.exists():
            items[fid] = parse(path)
        else:
            missing.append(fid)
    known = set(ORDER)
    failures = 0
    for fid, item in items.items():
        problems = validate(item, known)
        if problems:
            failures += 1
            print(f"INVALID {fid}: " + "; ".join(problems))
    print(f"{len(items)} bodies present, {len(missing)} missing: {' '.join(missing) or 'none'}; "
          f"{failures} invalid")
    if args.dry_run:
        for fid in ORDER:
            if fid in items:
                item = items[fid]
                sev = SEVERITY.get(fid, "?")
                print(f"  {fid:<18} {sev}  [{item['labels']}] {item['title']}")
        return 1 if failures or missing else 0
    if failures or missing:
        print("refusing to file with invalid or missing bodies", file=sys.stderr)
        return 1

    mapping = load_mapping()
    selected = [f for f in ORDER if (not args.only or f in args.only)]

    if args.file:
        for fid in selected:
            if fid in mapping:
                print(f"skip {fid}: already filed as #{mapping[fid]['number']}")
                continue
            item = items[fid]
            body, unresolved = substitute(item["body"], mapping)
            if unresolved:
                # Forward reference: file with a neutral phrase, patch in --resolve.
                body = PLACEHOLDER.sub("(see the related issue filed with this one)", body)
            labels = [l.strip() for l in item["labels"].split(",") if l.strip()]
            severity = SEVERITY.get(fid)
            if severity and severity not in labels:
                labels.append(severity)
            cmd = ["issue", "create", "--repo", REPO, "--title", item["title"],
                   "--body", body]
            for label in labels:
                cmd += ["--label", label]
            url = gh(*cmd)
            number = int(url.rstrip("/").rsplit("/", 1)[1])
            mapping[fid] = {"number": number, "url": url, "title": item["title"],
                            "severity": severity, "labels": labels,
                            "unresolved": unresolved}
            save_mapping(mapping)
            print(f"filed {fid} -> #{number} {url}", flush=True)
            import time
            time.sleep(6)
        return 0

    if args.resolve:
        # Patch forward references inside filed issues.
        for fid, entry in mapping.items():
            if entry.get("unresolved"):
                item = items[fid]
                body, unresolved = substitute(item["body"], mapping)
                if unresolved:
                    print(f"{fid}: still unresolved {unresolved}")
                    continue
                gh("issue", "edit", "--repo", REPO, str(entry["number"]), "--body", body)
                entry["unresolved"] = []
                print(f"patched #{entry['number']} ({fid})")
        save_mapping(mapping)
        # Substitute in the local documents.
        for doc in (REVIEW / "TRIAGE_FOR_CODEX.md",):
            text = doc.read_text()
            numbers = [mapping[f]["number"] for f in ORDER if f in mapping]
            if numbers:
                text = text.replace("{{ISSUE_RANGE}}", f"#{min(numbers)}–#{max(numbers)}")
            text = PLACEHOLDER.sub(lambda m: f"#{mapping[m.group(1)]['number']}"
                                   if m.group(1) in mapping else m.group(0), text)
            doc.write_text(text)
            print(f"substituted in {doc.name}")
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
