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
echo 'failure-detail extractor fixtures: ok'
