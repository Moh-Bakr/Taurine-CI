#!/usr/bin/env python3
import importlib.util
import json
import os
import subprocess
import sys
import io
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("pg8", Path(__file__).with_name("pg8-measurement.py"))
pg8 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pg8)

class ContractTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.exe = self.root / "probe"
        self.exe.write_text("#!/bin/sh\nexit 0\n")
        self.exe.chmod(0o755)

    def tearDown(self): self.tmp.cleanup()

    def artifact(self, path=None, package="path+file:///src/taurine-backend/taurine-db-conformance#taurine-db-conformance@1.0.0"):
        return {"reason":"compiler-artifact", "package_id":package,
                "target":{"name":pg8.TARGET,"kind":["test"]}, "executable":str(path or self.exe)}

    def test_single_owned_artifact(self):
        self.assertEqual(pg8.select_artifact([json.dumps(self.artifact())], self.root), str(self.exe.resolve()))

    def test_multiple_and_wrong_target_artifacts_rejected(self):
        with self.assertRaises(ValueError): pg8.select_artifact([json.dumps(self.artifact()),json.dumps(self.artifact())], self.root)
        wrong=self.artifact(); wrong["target"]["kind"]=["bin"]
        with self.assertRaises(ValueError): pg8.select_artifact([json.dumps(wrong)], self.root)

    def test_malformed_artifact_records_are_ignored_without_type_errors(self):
        for record in ("[]", "null", json.dumps({"reason":"compiler-artifact", "target":{"name":pg8.TARGET,"kind":None}, "package_id":[], "executable":str(self.exe)})):
            with self.subTest(record=record), self.assertRaises(ValueError):
                pg8.select_artifact([record], self.root)

    def test_cli_input_bound_counts_bytes(self):
        self.assertEqual(pg8.read_bounded(io.BytesIO("é".encode()), 2), "é")
        with self.assertRaises(ValueError): pg8.read_bounded(io.BytesIO("é".encode()), 1)

    def test_cli_errors_never_echo_source_supplied_paths(self):
        sentinel = str(self.root / "PRIVATE_SENTINEL_ARTIFACT_PATH")
        result = subprocess.run([sys.executable, str(Path(__file__).with_name("pg8-measurement.py")), "release", sentinel, str(self.root)], text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 1)
        self.assertNotIn(sentinel, result.stderr)
        self.assertEqual(result.stderr, "PG8 measurement validation failed (invalid fixed input)\n")

    def test_outside_and_symlink_artifacts_rejected(self):
        outside=Path(self.tmp.name).parent / (self.root.name + "-outside")
        outside.write_text("#!/bin/sh\n"); outside.chmod(0o755)
        try:
            with self.assertRaises(ValueError): pg8.select_artifact([json.dumps(self.artifact(outside))], self.root)
            link=self.root/"escape"; link.symlink_to(outside)
            with self.assertRaises(ValueError): pg8.select_artifact([json.dumps(self.artifact(link))], self.root)
        finally: outside.unlink(missing_ok=True)

    def marker(self, mode="paired", extra=""):
        if mode == "paired":
            return f"{pg8.MARKER} mode=paired warmups=5 samples=30 order=alternating connect_legacy_p50_us=10 connect_dbx_p50_us=10 connect_ratio_p50=1.0000 first_row_legacy_p50_us=10 first_row_dbx_p50_us=10 first_row_ratio_p50=1.0000 max_ratio=1.1000 passed=true{extra}"
        return f"{pg8.MARKER} mode={mode} warmups=5 samples=30 result=complete{extra}"

    def stdout(self, marker=None, counts="1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out"):
        return f"running 1 test\ntest {pg8.TEST} ... ok\n{marker or self.marker()}\ntest result: ok. {counts}\n"

    def test_probe_positive_each_mode(self):
        for mode in ("paired","legacy","dbx"):
            self.assertEqual(pg8.parse_probe(self.stdout(self.marker(mode)), mode, 0)["mode"], mode)

    def test_probe_skips_undercount_nonzero_and_marker_errors_rejected(self):
        cases=[(self.stdout().replace("running 1 test","SKIPPED"),"paired",0),
               (self.stdout(counts="0 passed; 0 failed; 1 ignored; 0 measured; 0 filtered out"),"paired",0),
               (self.stdout()+self.marker()+"\n","paired",0),
               (self.stdout(self.marker().replace("max_ratio=1.1000","max_ratio=NaN")),"paired",0),
               (self.stdout(self.marker().replace("max_ratio=1.1000","max_ratio=1.0900")),"paired",0),
               (self.stdout(self.marker().replace("max_ratio=1.1000","max_ratio=1.1100")),"paired",0),
               (self.stdout(self.marker()+"\n"+self.marker()),"paired",0),
               (self.stdout(self.marker()),"paired",2),
               (self.stdout(self.marker("legacy")),"paired",0)]
        for output,mode,code in cases:
            with self.subTest(output=output[-90:]), self.assertRaises(ValueError): pg8.parse_probe(output,mode,code)
        with self.assertRaises(ValueError): pg8.parse_probe(self.stdout(self.marker("unknown")), "unknown", 0)
        with self.assertRaises(ValueError): pg8.parse_probe("x" * (pg8.MAX_PROBE_OUTPUT_CHARS + 1), "paired", 0)

    def test_release_requires_x86_64_elf_and_owned_path(self):
        elf=self.root/"release"
        elf.write_bytes(b"\x7fELF\x02\x01"+b"\x00"*12+(62).to_bytes(2,"little")+b"\x00"*64)
        elf.chmod(0o755)
        self.assertEqual(pg8.validate_release_executable(elf,self.root),str(elf.resolve()))
        wrong=self.root/"wrong"
        wrong.write_bytes(b"not an executable")
        wrong.chmod(0o755)
        with self.assertRaises(ValueError): pg8.validate_release_executable(wrong,self.root)

    def test_rss_requires_one_direct_successful_measurement(self):
        self.assertEqual(pg8.parse_rss("Maximum resident set size (kbytes): 123\n",0),123)
        for text,code in [("",0),("Maximum resident set size (kbytes): 1\nMaximum resident set size (kbytes): 2\n",0),("Maximum resident set size (kbytes): 0\n",0),("Maximum resident set size (kbytes): 2\n",1)]:
            with self.subTest(text=text,code=code), self.assertRaises(ValueError): pg8.parse_rss(text,code)
        with self.assertRaises(ValueError): pg8.parse_rss("x" * (pg8.MAX_RSS_OUTPUT_CHARS + 1), 0)

if __name__ == "__main__": unittest.main()
