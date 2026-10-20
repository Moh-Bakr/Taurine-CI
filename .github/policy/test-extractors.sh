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
  if grep -qE "hunter2|a::b|tests/x\.rs" <<<"${out}"; then echo "a panic leaked its test name, path or message" >&2; exit 1; fi
  out="$(playwright_json_failures "$1/pw.json")"
  # Keyed failing-test ids (see test-keyed-test-ids.sh): the spec file, the title, the locator and
  # the expected and received values are never published, with or without a key.
  grep -qF "1 screenshot mismatch" <<<"${out}"
  grep -qF "1234 pixels differ" <<<"${out}"
  if grep -qE "a\.spec|Locator|getByRole|Welcome|Received string|Loading|SECRETTEXT" <<<"${out}"; then echo "a Playwright failure leaked its spec, title or assertion" >&2; exit 1; fi
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
# A failed vcpkg port build publishes a bounded tail (30 lines) of that port's buildtree log, so the real compiler or
# download error is visible, through the same sanitiser: the vcpkg root is shown as <vcpkg>, every other absolute
# path, token and ANSI sequence is scrubbed, and nothing is read outside vcpkg's buildtrees (a path-like port name,
# a symlinked directory or log, or no vcpkg root at all publishes nothing).
vroot="${dir}/vcpkg-root"
mkdir -p "${vroot}/buildtrees/fmt" "${vroot}/buildtrees/zlib"
{
  for i in $(seq 1 40); do echo "line ${i} of the fmt build"; done
  printf '%s\r\n' "${vroot}/buildtrees/fmt/src/format.cc(12): error C2065: 'undeclared_thing': undeclared identifier"
  printf '%s\r\n' "$(printf '%s' "${vroot}" | tr / '\\')\\buildtrees\\fmt\\src\\os.cc(7): error C1083: Cannot open include file"
  printf 'D:\\a\\Taurine\\Taurine\\src\\private\\secret.cc(3): note: PRIVATE_CHECKOUT_MARK\n'
  printf 'download failed for https://example.invalid/x with Bearer abcdef0123456789 and ghp_ABCDEFGHIJKLMNOP\n'
  printf '\033[31mred text\033[0m\n'
} > "${vroot}/buildtrees/fmt/install-x64-windows-static-md-err.log"
echo 'an older log that must lose to the newer one' > "${vroot}/buildtrees/fmt/config-old.log"; touch -t 202001010000 "${vroot}/buildtrees/fmt/config-old.log"
printf 'error: building fmt:x64-windows-static-md failed with: BUILD_FAILED\n' > "${dir}/vcpkg.log"
bash -c '
  set -euo pipefail
  source "$1/lib.sh"
  export VCPKG_INSTALLATION_ROOT="$2"
  out="$(cargo_test_detail "$1/vcpkg.log" 2>&1)"
  grep -qF "BUILD_FAILED" <<<"${out}" || grep -qF "error: building fmt:x64-windows-static-md failed" <<<"${out}"
  grep -qF "vcpkg fmt: last 30 lines of its build log" <<<"${out}"
  grep -qF "undeclared identifier" <<<"${out}"
  grep -qF "<vcpkg>/buildtrees/fmt/src/format.cc(12): error C2065" <<<"${out}"
  grep -qF "Cannot open include file" <<<"${out}"
  if grep -qF "line 1 of the fmt build" <<<"${out}"; then echo "the tail is longer than 30 lines" >&2; exit 1; fi
  grep -qF "red text" <<<"${out}"
  if grep -qE "PRIVATE_CHECKOUT_MARK|secret\.cc|Taurine|abcdef0123456789|ghp_ABCDEFGHIJKLMNOP|older log" <<<"${out}"; then echo "the vcpkg tail leaked a private path, a token or the wrong log" >&2; exit 1; fi
  if grep -q $(printf "\033") <<<"${out}"; then echo "an ANSI sequence survived" >&2; exit 1; fi
  if [[ "$(grep -c "" <<<"${out}")" -gt 40 ]]; then echo "the failure detail is not bounded" >&2; exit 1; fi
  # Nothing is read without a vcpkg root, for a path-like port name, or through a symlink.
  out="$(env -u VCPKG_INSTALLATION_ROOT bash -c "source \"\$1/lib.sh\"; cargo_test_detail \"\$1/vcpkg.log\"" _ "$1" 2>&1)"
  if grep -qF "last 30 lines" <<<"${out}"; then echo "a tail was published without a vcpkg root" >&2; exit 1; fi
  printf "error: building ..:x64-windows failed with: BUILD_FAILED\n" > "$1/dots.log"
  out="$(cargo_test_detail "$1/dots.log" 2>&1)"
  if grep -qF "last 30 lines" <<<"${out}"; then echo "a path-like port name was followed" >&2; exit 1; fi
  ln -s "$1/vcpkg-root/buildtrees/fmt" "$2/buildtrees/linked"
  printf "error: building linked:x64-windows failed with: BUILD_FAILED\n" > "$1/linked.log"
  out="$(cargo_test_detail "$1/linked.log" 2>&1)"
  if grep -qF "last 30 lines" <<<"${out}"; then echo "a symlinked port directory was followed" >&2; exit 1; fi
  printf "secret\n" > "$1/target-secret.log"; ln -s "$1/target-secret.log" "$2/buildtrees/zlib/build-err.log"
  printf "error: building zlib:x64-windows failed with: BUILD_FAILED\n" > "$1/zlib.log"
  out="$(cargo_test_detail "$1/zlib.log" 2>&1)"
  if grep -qE "secret|last 30 lines" <<<"${out}"; then echo "a symlinked log was followed" >&2; exit 1; fi
' _ "${dir}" "${vroot}"
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
# The compile step of a nextest sub-step must not carry the run-only options, which nextest rejects
# with --no-run (a clap usage error). A fake cargo rejects them as clap does.
mkdir -p "${dir}/fakebin"
cat > "${dir}/fakebin/cargo" <<'FAKE'
#!/bin/bash
if [[ "$2" == nextest ]]; then
  for a in "$@"; do
    case "$a" in
      --status-level|--final-status-level|--partition|--no-fail-fast|--profile) echo "error: unexpected argument $a with --no-run" >&2; exit 2 ;;
    esac
  done
fi
exit 0
FAKE
chmod +x "${dir}/fakebin/cargo"
bash -c '
  set -euo pipefail
  export PATH="$1/fakebin:${PATH}" RUNNER_TEMP="$1" OS_LABEL=Linux CONCERN=rust-x
  source "$1/lib.sh"
  source "$1/report.sh"
  rust_build_command cargo nextest run --locked --profile ci --no-fail-fast --status-level fail --final-status-level fail --partition count:1/2 --package a --package b
  [[ "${rust_build_cmd[*]}" == "cargo nextest run --no-run --locked --package a --package b" ]]
  # The three-way rust-app shards: a hash partition and the empty-partition guard are build-irrelevant too.
  rust_build_command cargo nextest run --locked --profile ci --no-fail-fast --status-level fail --final-status-level fail --partition hash:2/3 --no-tests=fail --package a --package b
  [[ "${rust_build_cmd[*]}" == "cargo nextest run --no-run --locked --package a --package b" ]]
  rust_build_command cargo test --locked --no-fail-fast --package a
  [[ "${rust_build_cmd[*]}" == "cargo test --locked --no-fail-fast --package a --no-run" ]]
  run_deferred rust-a-tests cargo nextest run --locked --profile ci --no-fail-fast --status-level fail --final-status-level fail --partition count:1/2 --package a >/dev/null 2>&1 || true
  [[ "${deferred_results[0]}" == "rust-a-build|passed" ]]
' _ "${dir}"
echo 'failure-detail extractor fixtures: ok'
# Keyed failing-test identities: the extractors publish an HMAC, never a name, path or message.
bash .github/policy/test-keyed-test-ids.sh
