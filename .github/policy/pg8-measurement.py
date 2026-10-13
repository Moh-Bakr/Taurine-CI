#!/usr/bin/env python3
"""Strict parsers for the fixed PG8 measurement workflow; emits no source output."""
import json
import math
import os
import re
import stat
import sys
from pathlib import Path

TARGET = "dbx_pg8_performance_live"
PACKAGE = "taurine-db-conformance"
TEST = "dbx_pg8_performance_probe"
MARKER = "TAURINE_DBX_PG8_RESULT"


def contained_executable(path, target_dir):
    candidate = Path(path)
    root = Path(target_dir).resolve(strict=True)
    resolved = candidate.resolve(strict=True)
    if not resolved.is_relative_to(root):
        raise ValueError("artifact path is outside the owned target directory")
    info = resolved.stat()
    if not stat.S_ISREG(info.st_mode) or not os.access(resolved, os.X_OK):
        raise ValueError("artifact is not a regular executable file")
    return str(resolved)


def select_artifact(lines, target_dir):
    hits = []
    for line in lines:
        try:
            obj = json.loads(line)
        except (TypeError, json.JSONDecodeError):
            continue
        if obj.get("reason") != "compiler-artifact":
            continue
        target = obj.get("target")
        package_id = obj.get("package_id", "")
        if not isinstance(target, dict) or target.get("name") != TARGET or "test" not in target.get("kind", []):
            continue
        if not re.search(r"(?:^|#)" + re.escape(PACKAGE) + r"(?:@|$)", package_id):
            continue
        executable = obj.get("executable")
        if not isinstance(executable, str) or not executable:
            continue
        hits.append(contained_executable(executable, target_dir))
    if len(hits) != 1:
        raise ValueError("expected exactly one trusted probe executable")
    return hits[0]


def parse_probe(stdout, mode, exit_code):
    if exit_code != 0:
        raise ValueError("probe process failed")
    if re.search(r"(?m)^test .+ \.\.\. (?:ignored|skipped)(?: .*)?$", stdout, re.I) or "SKIPPED" in stdout:
        raise ValueError("probe was skipped or ignored")
    summaries = re.findall(r"(?m)^test result: (.+)$", stdout)
    if len(summaries) != 1:
        raise ValueError("missing or duplicate test summary")
    summary = summaries[0]
    if not re.search(r"\b1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out\b", summary):
        raise ValueError("probe must execute exactly one passing test")
    markers = re.findall(r"(?m)^TAURINE_DBX_PG8_RESULT ([^\r\n]+)$", stdout)
    if len(markers) != 1:
        raise ValueError("missing or duplicate result marker")
    fields = {}
    for token in markers[0].split():
        if "=" not in token:
            raise ValueError("malformed result marker")
        key, value = token.split("=", 1)
        if key in fields:
            raise ValueError("duplicate result field")
        fields[key] = value
    if fields.get("mode") != mode or fields.get("warmups") != "5" or fields.get("samples") != "30":
        raise ValueError("mode or sample counts differ from the fixed protocol")
    if mode == "paired":
        expected = {"order", "connect_legacy_p50_us", "connect_dbx_p50_us", "connect_ratio_p50",
                    "first_row_legacy_p50_us", "first_row_dbx_p50_us", "first_row_ratio_p50", "max_ratio", "passed"}
        if set(fields) != expected | {"mode", "warmups", "samples"} or fields.get("order") != "alternating" or fields.get("passed") != "true":
            raise ValueError("paired result fields or verdict are invalid")
        for key in expected - {"order", "passed"}:
            value = fields[key]
            if not re.fullmatch(r"(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)", value):
                raise ValueError("measurement is not a finite nonnegative decimal")
            number = float(value)
            if not math.isfinite(number) or number < 0:
                raise ValueError("measurement is not finite and nonnegative")
        if float(fields["connect_ratio_p50"]) > 1.1 or float(fields["first_row_ratio_p50"]) > 1.1 or float(fields["max_ratio"]) > 1.1:
            raise ValueError("paired regression exceeds the fixed 1.10 budget")
    elif set(fields) != {"mode", "warmups", "samples", "result"} or fields.get("result") != "complete":
        raise ValueError("single-engine result fields are invalid")
    return fields


def parse_rss(stdout, exit_code):
    if exit_code != 0:
        raise ValueError("timed probe process failed")
    values = re.findall(r"(?m)^\s*Maximum resident set size \(kbytes\):\s*([0-9]+)\s*$", stdout)
    if len(values) != 1 or int(values[0]) <= 0:
        raise ValueError("missing or invalid direct-process RSS")
    return int(values[0])


def validate_release_executable(path, target_dir):
    resolved = Path(contained_executable(path, target_dir))
    with resolved.open("rb") as handle:
        header = handle.read(20)
    if len(header) < 20 or header[:4] != b"\x7fELF" or header[4] != 2 or header[5] != 1 or int.from_bytes(header[18:20], "little") != 62:
        raise ValueError("release artifact is not the fixed x86_64 Linux ELF executable")
    return str(resolved)


def main(argv):
    command = argv[1]
    if command == "artifact":
        print(select_artifact(sys.stdin, argv[2]))
    elif command == "release":
        print(validate_release_executable(argv[2], argv[3]))
    elif command == "probe":
        print(json.dumps(parse_probe(sys.stdin.read(), argv[2], int(argv[3])), sort_keys=True))
    elif command == "rss":
        print(parse_rss(sys.stdin.read(), int(argv[2])))
    else:
        raise ValueError("unknown fixed parser command")


if __name__ == "__main__":
    try:
        main(sys.argv)
    except (ValueError, OSError, IndexError) as exc:
        print("PG8 measurement validation failed: " + str(exc), file=sys.stderr)
        sys.exit(1)
