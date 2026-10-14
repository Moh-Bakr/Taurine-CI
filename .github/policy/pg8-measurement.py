#!/usr/bin/env python3
"""Strict parsers for the fixed PG8 measurement workflow; emits no source output."""
import json
import math
import os
import re
import stat
import sys
from pathlib import Path
from urllib.parse import unquote_to_bytes, urlsplit

TARGET = "dbx_pg8_performance_live"
PACKAGE = "taurine-db-conformance"
TEST = "dbx_pg8_performance_probe"
MARKER = "TAURINE_DBX_PG8_RESULT"
MAX_CARGO_JSON_CHARS = 64 * 1024 * 1024
MAX_PROBE_OUTPUT_CHARS = 1024 * 1024
MAX_RSS_OUTPUT_CHARS = 64 * 1024
SEMVER = r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
EXPLICIT_PACKAGE_ID = re.compile(r"(?:^|#)" + re.escape(PACKAGE) + r"(?:@|:)[0-9][0-9A-Za-z.+-]*\Z")


def package_id_matches(package_id):
    if not isinstance(package_id, str) or not package_id.isascii():
        return False
    # Preserve Cargo's explicit-name package IDs, but validate path package IDs
    # structurally: Cargo may omit the name from a path URL's version fragment.
    try:
        parsed = urlsplit(package_id)
        if parsed.scheme != "path+file":
            return bool(EXPLICIT_PACKAGE_ID.search(package_id))
        if parsed.query or parsed.username is not None or parsed.password is not None or parsed.port is not None:
            return False
        if parsed.hostname not in (None, "localhost"):
            return False
        raw_path = parsed.path
        if not raw_path.startswith("/") or raw_path.endswith("/") or re.search(r"%(?![0-9A-Fa-f]{2})", raw_path):
            return False
        decoded_path = unquote_to_bytes(raw_path).decode("utf-8", errors="strict")
        if "\\" in decoded_path or "\x00" in decoded_path or any(part in {".", ".."} for part in decoded_path.split("/")):
            return False
        if decoded_path.rsplit("/", 1)[-1] != PACKAGE:
            return False
        fragment = parsed.fragment
        return bool(re.fullmatch(SEMVER, fragment) or
                    re.fullmatch(re.escape(PACKAGE) + r"(?:@|:)" + SEMVER, fragment))
    except (UnicodeDecodeError, ValueError):
        return False


def read_bounded(stream, limit):
    value = stream.read(limit + 1)
    if len(value) > limit:
        raise ValueError("input exceeds the fixed parser size limit")
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return value


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
        if not isinstance(obj, dict):
            continue
        if obj.get("reason") != "compiler-artifact":
            continue
        target = obj.get("target")
        package_id = obj.get("package_id", "")
        kinds = target.get("kind") if isinstance(target, dict) else None
        if not isinstance(target, dict) or target.get("name") != TARGET or not isinstance(kinds, list) or "test" not in kinds:
            continue
        if not isinstance(package_id, str):
            continue
        if not package_id_matches(package_id):
            continue
        executable = obj.get("executable")
        if not isinstance(executable, str) or not executable:
            continue
        hits.append(contained_executable(executable, target_dir))
    if len(hits) != 1:
        raise ValueError("expected exactly one trusted probe executable")
    return hits[0]


def parse_probe(stdout, mode, exit_code):
    if mode not in {"paired", "legacy", "dbx"}:
        raise ValueError("unknown fixed probe mode")
    if len(stdout) > MAX_PROBE_OUTPUT_CHARS:
        raise ValueError("probe output exceeds the fixed parser size limit")
    if exit_code != 0:
        raise ValueError("probe process failed")
    if re.search(r"(?m)^test .+ \.\.\. (?:ignored|skipped)(?: .*)?$", stdout, re.I) or "SKIPPED" in stdout:
        raise ValueError("probe was skipped or ignored")
    summaries = re.findall(r"(?m)^test result: (.+)$", stdout)
    if len(summaries) != 1:
        raise ValueError("missing or duplicate test summary")
    summary = summaries[0]
    if not re.fullmatch(r"ok\. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in [0-9]+(?:\.[0-9]+)?s", summary):
        raise ValueError("probe must execute exactly one passing test")
    known_test_prefix = f"test {TEST} ... "
    markers = []
    for line in stdout.splitlines():
        if MARKER not in line:
            continue
        if line.startswith(MARKER + " "):
            markers.append(line[len(MARKER) + 1:])
        elif line.startswith(known_test_prefix + MARKER + " "):
            markers.append(line[len(known_test_prefix) + len(MARKER) + 1:])
        else:
            raise ValueError("result marker has an unexpected output prefix")
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
        if fields.get("max_ratio") != "1.1000":
            raise ValueError("paired result does not carry the fixed regression budget")
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
    if len(stdout) > MAX_RSS_OUTPUT_CHARS:
        raise ValueError("RSS output exceeds the fixed parser size limit")
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
        print(select_artifact(read_bounded(sys.stdin.buffer, MAX_CARGO_JSON_CHARS).splitlines(), argv[2]))
    elif command == "release":
        print(validate_release_executable(argv[2], argv[3]))
    elif command == "probe":
        print(json.dumps(parse_probe(read_bounded(sys.stdin.buffer, MAX_PROBE_OUTPUT_CHARS), argv[2], int(argv[3])), sort_keys=True))
    elif command == "rss":
        print(parse_rss(read_bounded(sys.stdin.buffer, MAX_RSS_OUTPUT_CHARS), int(argv[2])))
    else:
        raise ValueError("unknown fixed parser command")


if __name__ == "__main__":
    try:
        main(sys.argv)
    except (ValueError, OSError, IndexError) as exc:
        # Never echo parser exceptions: filesystem and JSON errors may contain
        # paths supplied by the private source checkout.
        print("PG8 measurement validation failed (invalid fixed input)", file=sys.stderr)
        sys.exit(1)
