#!/usr/bin/env python3
"""Structurally diff Everywhere vs openclicky context-stash captures.

Usage:
    diff-fixture.py <fixture-id>

Reads:
    fixtures/<fixture-id>-everywhere.json
    fixtures/<fixture-id>-openclicky.json

The two files are the on-disk stash format produced by
ContextStashWriter.FormatForHook: a mix of header lines with a bracketed
prefix followed by a final `[<brand>-ctx-json] {json}` line.

The diff:
- Rewrites `[openclicky-*]` prefixes on the openclicky side to
  `[everywhere-*]` so brand names never trigger a divergence.
- Strips fields that are inherently environment-specific:
  `captured_at_utc`, `process_id`.
- Reports missing fields, extra fields, and value differences.
- Reports line-count differences for the repeated envelope lines
  (`ctx-link`, `ctx-annotation`).

Exit code: 0 pass, 1 fail.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


PREFIX_RE = re.compile(r"^\[(everywhere|openclicky)-([a-z-]+)\](.*)$")
KV_TOKEN_RE = re.compile(r'(\w+)=("(?:[^"\\]|\\.)*"|\S+)')

# Field names on the JSON envelope we ignore when comparing values.
IGNORED_JSON_FIELDS = {"captured_at_utc", "process_id"}

# KV keys on the header lines that carry environment noise.
IGNORED_HEADER_KEYS = {"pid"}

SCRIPT_DIR = Path(__file__).resolve().parent
FIXTURES_DIR = SCRIPT_DIR / "fixtures"


def usage() -> None:
    print(__doc__)


def load(path: Path) -> str:
    if not path.exists():
        raise SystemExit(f"error: missing capture file {path}")
    return path.read_text(encoding="utf-8")


def rebrand(text: str) -> str:
    """Rewrite [openclicky-*] prefixes into [everywhere-*] for comparison."""
    return re.sub(r"\[openclicky-", "[everywhere-", text)


def parse(text: str) -> dict:
    """Group lines by prefix. The `-ctx-json` line is JSON-decoded."""
    result: dict = {
        "header": None,
        "links": [],
        "annotations": [],
        "hint": None,
        "discover": None,
        "json": None,
        "unknown": [],
    }
    for raw_line in text.splitlines():
        line = raw_line.rstrip("\n")
        if not line.strip():
            continue
        match = PREFIX_RE.match(line)
        if not match:
            result["unknown"].append(line)
            continue
        _brand, kind, rest = match.groups()
        payload = rest.strip()
        if kind == "ctx":
            result["header"] = parse_kv(payload)
        elif kind == "ctx-link":
            result["links"].append(parse_indexed_kv(payload))
        elif kind == "ctx-annotation":
            result["annotations"].append(parse_indexed_kv(payload))
        elif kind == "hint":
            result["hint"] = payload
        elif kind == "discover":
            result["discover"] = payload
        elif kind == "ctx-json":
            result["json"] = json.loads(payload)
        else:
            result["unknown"].append(line)
    return result


def parse_kv(payload: str) -> dict:
    """Parse `k=v k="quoted v"` into a dict, dropping ignored keys."""
    out: dict = {}
    for m in KV_TOKEN_RE.finditer(payload):
        key, value = m.group(1), m.group(2)
        if key in IGNORED_HEADER_KEYS:
            continue
        if value.startswith('"') and value.endswith('"'):
            value = value[1:-1]
        out[key] = value
    return out


def parse_indexed_kv(payload: str) -> dict:
    """Same as parse_kv but strips a leading `#<n>` positional marker."""
    payload = payload.lstrip()
    if payload.startswith("#"):
        # Drop everything up to the first whitespace.
        parts = payload.split(None, 1)
        payload = parts[1] if len(parts) > 1 else ""
    return parse_kv(payload)


def normalise_json(obj):
    """Recursively strip IGNORED_JSON_FIELDS."""
    if isinstance(obj, dict):
        return {
            k: normalise_json(v)
            for k, v in obj.items()
            if k not in IGNORED_JSON_FIELDS
        }
    if isinstance(obj, list):
        return [normalise_json(x) for x in obj]
    return obj


def diff_dicts(
    label: str, a: dict | None, b: dict | None, issues: list[str]
) -> None:
    a = a or {}
    b = b or {}
    keys = set(a) | set(b)
    for k in sorted(keys):
        if k not in a:
            issues.append(f"{label}: extra field in openclicky: {k}={b[k]!r}")
        elif k not in b:
            issues.append(f"{label}: missing field in openclicky: {k}={a[k]!r}")
        elif a[k] != b[k]:
            issues.append(
                f"{label}: value diff field={k} everywhere={a[k]!r} openclicky={b[k]!r}"
            )


def diff_lists(
    label: str, a: list[dict], b: list[dict], issues: list[str]
) -> None:
    if len(a) != len(b):
        issues.append(
            f"{label}: line count diff everywhere={len(a)} openclicky={len(b)}"
        )
    for i, (row_a, row_b) in enumerate(zip(a, b)):
        diff_dicts(f"{label}#{i}", row_a, row_b, issues)


def diff_json(a, b, path: str, issues: list[str]) -> None:
    if type(a) is not type(b):
        issues.append(f"json {path}: type diff everywhere={type(a).__name__} openclicky={type(b).__name__}")
        return
    if isinstance(a, dict):
        keys = set(a) | set(b)
        for k in sorted(keys):
            child_path = f"{path}.{k}" if path else k
            if k not in a:
                issues.append(f"json {child_path}: extra in openclicky: {b[k]!r}")
            elif k not in b:
                issues.append(f"json {child_path}: missing in openclicky: {a[k]!r}")
            else:
                diff_json(a[k], b[k], child_path, issues)
    elif isinstance(a, list):
        if len(a) != len(b):
            issues.append(f"json {path}: length diff everywhere={len(a)} openclicky={len(b)}")
        for i, (x, y) in enumerate(zip(a, b)):
            diff_json(x, y, f"{path}[{i}]", issues)
    else:
        if a != b:
            issues.append(f"json {path}: value diff everywhere={a!r} openclicky={b!r}")


def main(argv: list[str]) -> int:
    if len(argv) != 2 or argv[1] in ("-h", "--help"):
        usage()
        return 0 if argv[1:] and argv[1] in ("-h", "--help") else 2

    fixture = argv[1]
    ev_path = FIXTURES_DIR / f"{fixture}-everywhere.json"
    oc_path = FIXTURES_DIR / f"{fixture}-openclicky.json"

    ev_raw = load(ev_path)
    oc_raw = rebrand(load(oc_path))

    ev = parse(ev_raw)
    oc = parse(oc_raw)

    issues: list[str] = []

    diff_dicts("header", ev["header"], oc["header"], issues)
    diff_lists("links", ev["links"], oc["links"], issues)
    diff_lists("annotations", ev["annotations"], oc["annotations"], issues)

    for key in ("hint", "discover"):
        if bool(ev[key]) != bool(oc[key]):
            issues.append(f"{key}: presence diff everywhere={bool(ev[key])} openclicky={bool(oc[key])}")

    ev_json = normalise_json(ev["json"] or {})
    oc_json = normalise_json(oc["json"] or {})
    diff_json(ev_json, oc_json, "", issues)

    for line in ev["unknown"]:
        issues.append(f"everywhere: unknown line {line!r}")
    for line in oc["unknown"]:
        issues.append(f"openclicky: unknown line {line!r}")

    if issues:
        for line in issues:
            print(line)
        print(f"FAIL: {len(issues)} issue(s) for fixture {fixture}")
        return 1

    print(f"PASS: fixture {fixture} matches")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
