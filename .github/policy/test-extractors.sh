#!/usr/bin/env bash
# Test the failure-detail extractors against fixtures
#
# The shared sanitize library's detail extractors, run over fixtures: a Tauri version
# mismatch pair is listed, a panic keeps only a fixed `code=` token (never other message
# text), and a Playwright JSON report yields failing spec names and screenshot-mismatch
# counts without any message body.
# Run from the repository root (the policy workflow does).
set -euo pipefail
dir="${RUNNER_TEMP}/extractor-fixtures"
mkdir -p "${dir}"
awk "/cat > .*sanitize.sh.* <<'TCI_SANITIZE_LIBRARY'/{on=1; next} /^        TCI_SANITIZE_LIBRARY/{on=0} on" .github/actions/sanitize/action.yml | sed -E 's/^        //' > "${dir}/lib.sh"
[[ -s "${dir}/lib.sh" ]] || { echo 'the sanitize library was not found' >&2; exit 1; }
printf 'Error Found version mismatched Tauri packages:\r\n  tauri-plugin-dialog (v2.4.1) : @tauri-apps/plugin-dialog (v2.3.0)\r\n' > "${dir}/tauri.log"
printf "thread 'a::b' panicked at tests/x.rs:4:9:\ndbx_children failed: code=not_connected secret=hunter2\n" > "${dir}/panic.log"
printf '{"suites":[{"specs":[{"title":"t","file":"e2e/a.spec.ts","line":3,"tests":[{"projectName":"visual","status":"unexpected","results":[{"error":{"message":"Screenshot comparison failed:\\n  1234 pixels (ratio 0.02) are different. SECRETTEXT"}}]},{"projectName":"critical","status":"unexpected","results":[{"error":{"message":"Error: expect(locator).toHaveText(expected)\\nLocator: getByRole(heading)\\nExpected string: Welcome\\nReceived string: Loading"}}]}]}]}]}' > "${dir}/pw.json"
bash -c '
  set -euo pipefail
  source "$1/lib.sh"
  tauri_version_mismatch "$1/tauri.log" | grep -qF "tauri-plugin-dialog (v2.4.1) : @tauri-apps/plugin-dialog (v2.3.0)"
  out="$(panic_summary "$1/panic.log")"
  grep -qF "code=not_connected" <<<"${out}"
  if grep -q "hunter2" <<<"${out}"; then exit 1; fi
  out="$(playwright_json_failures "$1/pw.json")"
  grep -qF "e2e/a.spec.ts:3" <<<"${out}"
  grep -qF "1 screenshot mismatch" <<<"${out}"
  grep -qF "1234 pixels differ" <<<"${out}"
  grep -qF "Locator: getByRole(heading)" <<<"${out}"
  grep -qF "Received string: Loading" <<<"${out}"
  if grep -q "SECRETTEXT" <<<"${out}"; then exit 1; fi
' _ "${dir}"
# Compiler diagnostics: an error[Ennnn] is its code and location, never its message.
awk "/cat > .*report.sh.* <<'TCI_REPORT_LIBRARY'/{on=1; next} /^        TCI_REPORT_LIBRARY/{on=0} on" .github/actions/concern-report/action.yml | sed -E 's/^        //' > "${dir}/report.sh"
printf 'error[E0599]: no method named `secret_thing` found\n  --> taurine-core/src/lib.rs:12:5\nerror: unused variable: `private_var`\n  --> taurine-core/src/x.rs:3:9\n' > "${dir}/cargo.log"
bash -c '
  set -euo pipefail
  source "$1/lib.sh"
  source "$1/report.sh"
  out="$(cargo_detail "$1/cargo.log" 2>&1)"
  grep -qF "error[E0599]" <<<"${out}"
  grep -qF "taurine-core/src/lib.rs:12:5" <<<"${out}"
  if grep -qE "secret_thing|private_var" <<<"${out}"; then echo "an error message leaked" >&2; exit 1; fi
  out="$(cargo_test_detail "$1/cargo.log" 2>&1)"
  if grep -qE "secret_thing|private_var" <<<"${out}"; then echo "an error message leaked (test detail)" >&2; exit 1; fi
' _ "${dir}"
printf 'FATAL ERROR: Reached heap limit Allocation failed - JavaScript heap out of memory\nsecretmessage\n' > "${dir}/node.log"
bash -c '
  set -euo pipefail
  source "$1/lib.sh"
  source "$1/report.sh"
  out="$(node_crash_class "$1/node.log")"
  grep -qF "node failure class: heap out of memory" <<<"${out}"
  if grep -q secretmessage <<<"${out}"; then exit 1; fi
' _ "${dir}"
# Dependency names are never published: every scanner detail function prints a name hash (8 hex of
# the SHA-256), lint codes and advisory ids, and a known package name must not appear in its output.
cat > "${dir}/deny.jsonl" <<'JSONL'
{"type":"diagnostic","fields":{"code":"rejected","severity":"error","message":"secretcrate-xyz is under a denied licence","graphs":[{"Krate":{"name":"secretcrate-xyz","version":"1.2.3"}}]}}
{"type":"diagnostic","fields":{"code":"duplicate","severity":"warning","message":"found 2 duplicate entries for crate dupcrate-abc","graphs":[{"Krate":{"name":"dupcrate-abc","version":"1.0.0"}}]}}
{"type":"diagnostic","fields":{"code":"vulnerability","severity":"error","message":"Marvin attack in secretcrate-xyz","advisory":{"id":"RUSTSEC-2099-0001","package":"secretcrate-xyz","title":"Title naming secretcrate-xyz"},"graphs":[{"Krate":{"name":"secretcrate-xyz","version":"1.2.3"}}]}}
JSONL
printf 'Analyzing dependencies of crates in this directory...\ncargo-machete found the following unused dependencies in this directory:\nsome-crate -- ./taurine-core/Cargo.toml:\n\tsecretdep-xyz\ntaurine-core/Cargo.toml\n' > "${dir}/machete.out"
printf 'taurine-app/Cargo.toml\ntaurine-core/Cargo.toml\n' > "${dir}/manifests.txt"
printf '%s' '{"vulnerabilities":{"secretpkg-xyz":{"severity":"high","via":[{"url":"https://github.com/advisories/GHSA-aaaa-bbbb-cccc","title":"secretpkg-xyz is vulnerable"}]},"lowpkg":{"severity":"low","via":[]}}}' > "${dir}/npm.json"
printf 'Crate:     secretcrate-xyz\nVersion:   1.2.3\nTitle:     Flaw in secretcrate-xyz\nID:        RUSTSEC-2099-0001\nSeverity:  7.5 (high)\nerror: 1 vulnerability found!\n' > "${dir}/audit.out"
bash -c '
  set -euo pipefail
  source "$1/lib.sh"
  source "$1/report.sh"
  want="$(printf "%s" secretcrate-xyz | sha256sum | cut -c1-8)"
  [[ "$(name_hash secretcrate-xyz)" == "${want}" ]]
  out="$(deny_policy_detail "$1/deny.jsonl")"
  grep -qF "error rejected ${want}" <<<"${out}"
  if grep -qE "secretcrate|dupcrate" <<<"${out}"; then echo "a crate name leaked (deny policy)" >&2; exit 1; fi
  out="$(deny_advisory_detail "$1/deny.jsonl")"
  grep -qF "RUSTSEC-2099-0001" <<<"${out}"
  if grep -qE "secretcrate|Marvin|Title" <<<"${out}"; then echo "a crate name or title leaked (deny advisory)" >&2; exit 1; fi
  out="$(machete_detail "$1/machete.out" "$1/manifests.txt")"
  grep -qF "manifest #2 $(printf "%s" secretdep-xyz | sha256sum | cut -c1-8)" <<<"${out}"
  if grep -qE "secretdep|some-crate|taurine-core" <<<"${out}"; then echo "a dependency name or path leaked (machete)" >&2; exit 1; fi
  out="$(npm_audit_detail "$1/npm.json")"
  grep -qF "$(printf "%s" secretpkg-xyz | sha256sum | cut -c1-8) high GHSA-aaaa-bbbb-cccc" <<<"${out}"
  if grep -qE "secretpkg|lowpkg" <<<"${out}"; then echo "a package name leaked (npm audit)" >&2; exit 1; fi
  out="$(cargo_audit_detail "$1/audit.out" 2>&1)"
  grep -qF "RUSTSEC-2099-0001" <<<"${out}"
  if grep -qE "secretcrate|Flaw|1\.2\.3" <<<"${out}"; then echo "a crate name leaked (cargo audit)" >&2; exit 1; fi
' _ "${dir}"
echo 'failure-detail extractor fixtures: ok'
