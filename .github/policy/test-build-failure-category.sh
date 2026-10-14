#!/usr/bin/env bash
# Adversarial and action-callsite fixtures for sanitized build-failure classification.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
classifier="${root}/.github/policy/build-failure-category.rb"
live_action="${root}/.github/actions/live-build/action.yml"
pg8_action="${root}/.github/actions/pg8-measurement/action.yml"

classify() { ruby "${classifier}" "$1" "$2" "$3" <"$4"; }
expect() {
  local format="$1" target="$2" status="$3" input="$4" wanted="$5" output
  output="$(classify "${format}" "${target}" "${status}" "${input}")"
  [[ "${output}" == "${wanted}" ]] || { echo 'build category fixture mismatch' >&2; exit 1; }
  if grep -Eq 'PRIVATE|SECRET|/Users/|/home/|token|raw message|ghp_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+' <<<"${output}"; then
    echo 'private diagnostic fixture text was emitted' >&2
    exit 1
  fi
}

printf '%s\n' 'error: linking with `cc` failed: PRIVATE linker detail ghp_abcdefghijklmnopqrstuvwxyz0123456789 /Users/alice/private.rs' 'PRIVATE raw message' >"${tmp}/linker.log"
printf '%s\n' 'error: package PRIVATE-CRATE does not have feature SECRET-FEATURE github_pat_11PRIVATE_token' >"${tmp}/package.log"
printf '%s\n' 'error: no matching package named PRIVATE-CRATE found in source' >"${tmp}/package-missing.log"
printf '%s\n' 'error: feature PRIVATE-FEATURE is not available for package' >"${tmp}/feature-missing.log"
printf '%s\n' 'error: no test target named PRIVATE-TARGET /home/runner/private/path' >"${tmp}/target.log"
printf '%s\n' 'error: failed to select a version for SECRET-CRATE token=PRIVATE' >"${tmp}/dependency.log"
printf '%s\n' 'PRIVATE non-diagnostic source text' >"${tmp}/unknown.log"
expect text dbx_pg_tls_live 101 "${tmp}/linker.log" 'build-failure: category=linkerfailed count=1 target=dbx_pg_tls_live'
expect text dbx_pg_tls_live 101 "${tmp}/package.log" 'build-failure: category=package-or-feature-selection count=1 target=dbx_pg_tls_live'
expect text dbx_pg_tls_live 101 "${tmp}/package-missing.log" 'build-failure: category=package-or-feature-selection count=1 target=dbx_pg_tls_live'
expect text dbx_pg_tls_live 101 "${tmp}/feature-missing.log" 'build-failure: category=package-or-feature-selection count=1 target=dbx_pg_tls_live'
expect text dbx_pg_tls_live 101 "${tmp}/target.log" 'build-failure: category=missingtarget count=1 target=dbx_pg_tls_live'
expect text dbx_pg_tls_live 101 "${tmp}/dependency.log" 'build-failure: category=dependency-resolution count=1 target=dbx_pg_tls_live'
expect text dbx_pg_tls_live 137 "${tmp}/unknown.log" 'build-failure: category=process-signal count=1 target=dbx_pg_tls_live'
expect text dbx_pg_tls_live 101 "${tmp}/unknown.log" 'build-failure: category=other count=1 target=dbx_pg_tls_live'

cat >"${tmp}/linker.jsonl" <<'JSONL'
{"reason":"compiler-message","message":{"message":"linker command failed PRIVATE SECRET ghp_abcdefghijklmnopqrstuvwxyz0123456789","rendered":"error: linking failed at /Users/PRIVATE/path"}}
JSONL
expect json dbx_pg8_performance_live 101 "${tmp}/linker.jsonl" 'build-failure: category=linkerfailed count=1 target=dbx_pg8_performance_live'
cat >"${tmp}/mixed.jsonl" <<'JSONL'
{"reason":"compiler-message","message":{"message":"linker command failed SECRET"}}
{"reason":"compiler-message","message":{"message":"no test target named PRIVATE"}}
JSONL
expect json dbx_pg8_performance_live 101 "${tmp}/mixed.jsonl" 'build-failure: category=other count=1 target=dbx_pg8_performance_live'
printf '%s\n' '{not-json PRIVATE}' >"${tmp}/malformed.jsonl"
expect json dbx_pg8_performance_live 101 "${tmp}/malformed.jsonl" 'build-failure: category=other count=1 target=dbx_pg8_performance_live'
printf '%s\n' '{"reason":"compiler-message","message":{"message":"error: PRIVATE raw message"}}' >"${tmp}/oversize.jsonl"
truncate -s 1048577 "${tmp}/oversize.jsonl"
expect json dbx_pg8_performance_live 101 "${tmp}/oversize.jsonl" 'build-failure: category=other count=1 target=dbx_pg8_performance_live'

# Extract and execute the actual live-build action with only Cargo replaced by a fixed failing stub.
mkdir -p "${tmp}/bin" "${tmp}/live-temp"
ruby "${root}/.github/policy/extract-step.rb" "${live_action}" "Build the engine's proof test binary" run >"${tmp}/live.sh"
bash -n "${tmp}/live.sh"
cat >"${tmp}/bin/cargo" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' 'error: no test target named PRIVATE-TARGET' 'PRIVATE raw message' >&2
exit "${FAKE_CARGO_STATUS:-101}"
STUB
chmod +x "${tmp}/bin/cargo"
printf '%s\n' '{"engine":"android","target":"fixed-target","cargo_features":[],"suites":[]}' >"${tmp}/live-temp/live-arm.json"
if PATH="${tmp}/bin:${PATH}" GITHUB_WORKSPACE="${root}" RUNNER_TEMP="${tmp}/live-temp" bash "${tmp}/live.sh" >"${tmp}/live.out" 2>&1; then
  echo 'live-build action fixture unexpectedly passed' >&2
  exit 1
fi
grep -qF 'build-failure: category=missingtarget count=1 target=selected-live-proof-target' "${tmp}/live.out"
! grep -Eq 'PRIVATE-TARGET|PRIVATE raw message' "${tmp}/live.out"
if PATH="${tmp}/bin:${PATH}" FAKE_CARGO_STATUS=0 GITHUB_WORKSPACE="${root}" RUNNER_TEMP="${tmp}/live-temp" bash "${tmp}/live.sh" >"${tmp}/live-success.out" 2>&1; then
  :
else
  echo 'live-build success fixture unexpectedly failed' >&2
  exit 1
fi
! grep -qF 'build-failure:' "${tmp}/live-success.out"
if PATH="${tmp}/bin:${PATH}" FAKE_CARGO_STATUS=137 GITHUB_WORKSPACE="${root}" RUNNER_TEMP="${tmp}/live-temp" bash "${tmp}/live.sh" >"${tmp}/live-signal.out" 2>&1; then
  echo 'live-build signal fixture unexpectedly passed' >&2
  exit 1
fi
grep -qF 'build-failure: category=process-signal count=1 target=selected-live-proof-target' "${tmp}/live-signal.out"
! grep -Eq 'PRIVATE-TARGET|PRIVATE raw message' "${tmp}/live-signal.out"

# Exercise the actual PG8 failure branch; fake mkdir avoids touching its fixed /mnt target path.
mkdir -p "${tmp}/src" "${tmp}/pg8-temp" "${tmp}/pg8-bin" "${tmp}/.github/policy"
cp "${classifier}" "${tmp}/.github/policy/build-failure-category.rb"
ruby "${root}/.github/policy/extract-step.rb" "${pg8_action}" 'Run fixed PG8 probe and UAT release comparisons' run >"${tmp}/pg8.sh"
bash -n "${tmp}/pg8.sh"
cat >"${tmp}/pg8-bin/mkdir" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat >"${tmp}/pg8-bin/cargo" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '{"reason":"compiler-message","message":{"message":"error: failed to select a version for PRIVATE-CRATE","rendered":"PRIVATE raw message"}}' >&2
exit 101
STUB
chmod +x "${tmp}/pg8-bin/mkdir" "${tmp}/pg8-bin/cargo"
if PATH="${tmp}/pg8-bin:${PATH}" GITHUB_WORKSPACE="${tmp}" RUNNER_TEMP="${tmp}/pg8-temp" SOURCE_PATH=src bash "${tmp}/pg8.sh" >"${tmp}/pg8.out" 2>&1; then
  echo 'PG8 action fixture unexpectedly passed' >&2
  exit 1
fi
grep -qF 'build-failure: category=dependency-resolution count=1 target=dbx_pg8_performance_live' "${tmp}/pg8.out"
! grep -Eq 'PRIVATE-CRATE|PRIVATE raw message' "${tmp}/pg8.out"
echo 'build-failure category fixtures: classifications, privacy, failure preservation, live-build and PG8 callsites pass'
