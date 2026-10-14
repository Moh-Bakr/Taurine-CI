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
{
  printf '%s\n' 'Compiling PRIVATE-CRATE v1.2.3 (/Users/PRIVATE/source)' '    Finished `test` profile [unoptimized + debuginfo]'
  cat "${tmp}/linker.jsonl"
} >"${tmp}/mixed-progress.jsonl"
expect json dbx_pg8_performance_live 101 "${tmp}/mixed-progress.jsonl" 'build-failure: category=linkerfailed count=1 target=dbx_pg8_performance_live'
printf '%s\n' 'error: no test target named PRIVATE-TARGET' >"${tmp}/plain-target.log"
expect json dbx_pg8_performance_live 101 "${tmp}/plain-target.log" 'build-failure: category=missingtarget count=1 target=dbx_pg8_performance_live'
cat >"${tmp}/mixed.jsonl" <<'JSONL'
{"reason":"compiler-message","message":{"message":"linker command failed SECRET"}}
{"reason":"compiler-message","message":{"message":"no test target named PRIVATE"}}
JSONL
expect json dbx_pg8_performance_live 101 "${tmp}/mixed.jsonl" 'build-failure: category=other count=1 target=dbx_pg8_performance_live'
printf '%s\n' '{not-json PRIVATE}' >"${tmp}/malformed.jsonl"
expect json dbx_pg8_performance_live 101 "${tmp}/malformed.jsonl" 'build-failure: category=other count=1 target=dbx_pg8_performance_live'
expect text dbx_pg8_performance_live 999 "${tmp}/linker.log" 'build-failure: category=other count=1 target=dbx_pg8_performance_live'
printf '%s\n' 'error: linking with cc failed PRIVATE path' >"${tmp}/release.log"
expect text pg8-uat-release 101 "${tmp}/release.log" 'build-failure: category=linkerfailed count=1 target=pg8-uat-release'
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

# If the classifier file or Ruby runtime is unavailable, only the fixed fallback is emitted.
mkdir -p "${tmp}/live-nohelper-workspace" "${tmp}/broken-ruby-bin"
cat >"${tmp}/broken-ruby-bin/ruby" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' 'PRIVATE-RUBY-ERROR /Users/PRIVATE/path' >&2
exit 1
STUB
chmod +x "${tmp}/broken-ruby-bin/ruby"
for helper_case in missing broken; do
  test_path="${tmp}/bin:${PATH}"
  workspace="${tmp}/live-nohelper-workspace"
  if [[ "${helper_case}" == broken ]]; then
    workspace="${root}"
    test_path="${tmp}/broken-ruby-bin:${tmp}/bin:${PATH}"
  fi
  if PATH="${test_path}" GITHUB_WORKSPACE="${workspace}" RUNNER_TEMP="${tmp}/live-temp" bash "${tmp}/live.sh" >"${tmp}/live-${helper_case}-helper.out" 2>&1; then
    echo "live-build ${helper_case}-helper fixture unexpectedly passed" >&2
    exit 1
  fi
  grep -qF 'build-failure: category=other count=1 target=selected-live-proof-target' "${tmp}/live-${helper_case}-helper.out"
  ! grep -Eq 'LoadError|cannot load such file|PRIVATE-RUBY-ERROR|/Users/PRIVATE' "${tmp}/live-${helper_case}-helper.out"
done

# Exercise the actual PGTLS multi-suite path with stub target files. Cargo succeeds twice, then
# fails only the fixed mTLS suite; the emitted target label must be the fixed mTLS target.
mkdir -p "${tmp}/pgtls-workspace/.github/policy" "${tmp}/pgtls-temp" "${tmp}/pgtls-bin"
mkdir -p "${tmp}/pgtls-src/taurine-backend/taurine-db-conformance/tests"
cp "${classifier}" "${tmp}/pgtls-workspace/.github/policy/build-failure-category.rb"
printf '%s\n' 'synthetic target-presence fixture' >"${tmp}/pgtls-src/taurine-backend/taurine-db-conformance/tests/dbx_pg_tls_live.rs"
printf '%s\n' 'synthetic target-presence fixture' >"${tmp}/pgtls-src/taurine-backend/taurine-db-conformance/tests/dbx_pg_mtls_live.rs"
cat >"${tmp}/pgtls-temp/live-arm.json" <<'JSON'
{"engine":"pgtls","cargo_features":["taurine-db-dbx/dbx-pg","taurine-db-dbx/legacy-tls"],"suites":["taurine-db-postgres live_tls","taurine-db-conformance dbx_pg_tls_live dbx_tls_","taurine-db-conformance dbx_pg_mtls_live dbx_pg_mtls_"]}
JSON
cat >"${tmp}/pgtls-bin/cargo" <<'STUB'
#!/usr/bin/env bash
count=0
[[ ! -f "${FAKE_CARGO_COUNT}" ]] || read -r count <"${FAKE_CARGO_COUNT}"
count=$((count + 1))
printf '%s\n' "${count}" >"${FAKE_CARGO_COUNT}"
printf '%s\n' "$*" >>"${FAKE_CARGO_ARGS}"
if (( count == 3 )); then
  printf '%s\n' 'error: linking with `cc` failed: PRIVATE-MTLS-SENTINEL ghp_abcdefghijklmnopqrstuvwxyz0123456789' >&2
  exit 101
fi
exit 0
STUB
chmod +x "${tmp}/pgtls-bin/cargo"
if (cd "${tmp}/pgtls-src" && PATH="${tmp}/pgtls-bin:${PATH}" GITHUB_WORKSPACE="${tmp}/pgtls-workspace" RUNNER_TEMP="${tmp}/pgtls-temp" FAKE_CARGO_COUNT="${tmp}/cargo-count" FAKE_CARGO_ARGS="${tmp}/cargo-args" bash "${tmp}/live.sh") >"${tmp}/pgtls.out" 2>&1; then
  echo 'PGTLS mTLS failure fixture unexpectedly passed' >&2
  exit 1
fi
grep -qF 'build-failure: category=linkerfailed count=1 target=dbx_pg_mtls_live' "${tmp}/pgtls.out"
grep -qF -- '--features taurine-db-dbx/dbx-pg --features taurine-db-dbx/legacy-tls --test dbx_pg_mtls_live' "${tmp}/cargo-args"
! grep -Eq 'PRIVATE-MTLS-SENTINEL|ghp_abcdefghijklmnopqrstuvwxyz' "${tmp}/pgtls.out"

# Exercise the extracted Windows rust-db failure reporter. No Rust command runs: fake Cargo
# supplies a private sentinel and the actual protected report library performs classification.
awk "/cat > .*sanitize.sh.* <<'TCI_SANITIZE_LIBRARY'/{on=1; next} /^        TCI_SANITIZE_LIBRARY/{on=0} on" "${root}/.github/actions/sanitize/action.yml" | sed -E 's/^        //' >"${tmp}/sanitize.sh"
awk "/cat > .*report.sh.* <<'TCI_REPORT_LIBRARY'/{on=1; next} /^        TCI_REPORT_LIBRARY/{on=0} on" "${root}/.github/actions/concern-report/action.yml" | sed -E 's/^        //' >"${tmp}/report.sh"
[[ -s "${tmp}/sanitize.sh" && -s "${tmp}/report.sh" ]] || { echo 'the shared report libraries were not found' >&2; exit 1; }
mkdir -p "${tmp}/windows-workspace/.github/policy" "${tmp}/windows-bin" "${tmp}/windows-runner"
cp "${classifier}" "${tmp}/windows-workspace/.github/policy/build-failure-category.rb"
cat >"${tmp}/windows-bin/cargo" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' 'error[E0599]: PRIVATE-WINDOWS-COMPILER-SENTINEL' '  --> C:\Users\Private\src\lib.rs:9:5' >&2
exit "${FAKE_CARGO_STATUS:-101}"
STUB
chmod +x "${tmp}/windows-bin/cargo"
run_windows_report() {
  local os="$1" concern="$2" label="$3" status="$4" runtime="$5" rc test_path="${tmp}/windows-bin"
  local output="${tmp}/windows-${os}-${concern}-${label}-${runtime}.out"
  if [[ "${runtime}" == broken ]]; then test_path="${tmp}/windows-rubyfail-bin:${tmp}/windows-bin"; fi
  set +e
  PATH="${test_path}:${PATH}" RUNNER_TEMP="${tmp}/windows-runner" GITHUB_WORKSPACE="${tmp}/windows-workspace" OS_LABEL="${os}" CONCERN="${concern}" FAKE_CARGO_STATUS="${status}" bash -c '
    set -euo pipefail
    source "$1/sanitize.sh"
    source "$1/report.sh"
    if [[ "$2" == unavailable ]]; then
      command() { [[ "$*" != "-v ruby" ]] && builtin command "$@"; }
    fi
    run_quiet "$3" cargo test --locked --no-run
  ' _ "${tmp}" "${runtime}" "${label}" >"${output}" 2>&1
  rc=$?
  set -e
  [[ "${rc}" -ne 0 ]] || { echo 'Windows report fixture unexpectedly passed' >&2; exit 1; }
  if [[ "${os}:${concern}:${label}:${runtime}" == 'Windows:rust-db:rust-db-build:available' ]]; then
    if [[ "${status}" == 137 ]]; then
      grep -qF 'build-failure: category=process-signal count=1 target=selected-live-proof-target' "${output}"
    else
      grep -qF 'build-failure: category=other count=1 target=selected-live-proof-target' "${output}"
    fi
  elif [[ "${runtime}" != available && "${os}:${concern}:${label}" == 'Windows:rust-db:rust-db-build' ]]; then
    grep -qF 'build-failure: category=other count=1 target=selected-live-proof-target' "${output}"
  else
    ! grep -qF 'build-failure:' "${output}"
  fi
  ! grep -Eq 'PRIVATE-WINDOWS-COMPILER-SENTINEL|Users\\Private|Users/Private' "${output}"
}
run_windows_report Windows rust-db rust-db-build 137 available
run_windows_report Windows rust-db rust-db-build 101 unavailable
mkdir -p "${tmp}/windows-rubyfail-bin"
cat >"${tmp}/windows-rubyfail-bin/ruby" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' 'PRIVATE-RUBY-ERROR /Users/PRIVATE/path' >&2
exit 1
STUB
chmod +x "${tmp}/windows-rubyfail-bin/ruby"
run_windows_report Windows rust-db rust-db-build 101 broken
run_windows_report Linux rust-db rust-db-build 101 available
run_windows_report Windows rust-domain rust-domain-build 101 available
run_windows_report Windows rust-db rust-db-tests 101 available
set +e
PATH="${tmp}/windows-bin:${PATH}" RUNNER_TEMP="${tmp}/windows-runner" GITHUB_WORKSPACE="${tmp}/windows-workspace" OS_LABEL=Windows CONCERN=rust-db FAKE_CARGO_STATUS=0 bash -c '
  set -euo pipefail
  source "$1/sanitize.sh"
  source "$1/report.sh"
  run_quiet rust-db-build cargo test --locked --no-run
' _ "${tmp}" >"${tmp}/windows-success.out" 2>&1
windows_success_status=$?
set -e
[[ "${windows_success_status}" -eq 0 ]] || { echo 'Windows success fixture unexpectedly failed' >&2; exit 1; }
! grep -qF 'build-failure:' "${tmp}/windows-success.out"
! grep -qE 'PRIVATE-WINDOWS-COMPILER-SENTINEL|PRIVATE-RUBY-ERROR|Users\\Private|Users/Private' "${tmp}/windows-success.out"
echo 'Windows rust-db compile-category fixtures: passed failure-only guard, fixed fallback, actual rc, and privacy checks'

# Exercise the actual PG8 failure branch with a real owned RUNNER_TEMP fallback.
mkdir -p "${tmp}/src" "${tmp}/pg8-temp" "${tmp}/pg8-bin" "${tmp}/.github/policy"
cp "${classifier}" "${tmp}/.github/policy/build-failure-category.rb"
ruby "${root}/.github/policy/extract-step.rb" "${pg8_action}" 'Run fixed PG8 probe and UAT release comparisons' run >"${tmp}/pg8.sh"
bash -n "${tmp}/pg8.sh"
cat >"${tmp}/pg8-bin/cargo" <<'STUB'
#!/usr/bin/env bash
[[ -z "${GITHUB_OUTPUT:-}" ]] || exit 97
printf '%s\n' "${CARGO_TARGET_DIR}" >"${FAKE_TARGET_CAPTURE}"
printf '%s\n' '{"reason":"compiler-message","message":{"message":"error: failed to select a version for PRIVATE-CRATE","rendered":"PRIVATE raw message"}}' >&2
exit 101
STUB
chmod +x "${tmp}/pg8-bin/cargo"
if PATH="${tmp}/pg8-bin:${PATH}" GITHUB_WORKSPACE="${tmp}" RUNNER_TEMP="${tmp}/pg8-temp" SOURCE_PATH=src GITHUB_RUN_ID=24680 GITHUB_RUN_ATTEMPT=1 GITHUB_OUTPUT="${tmp}/pg8-output-1" FAKE_TARGET_CAPTURE="${tmp}/target.capture" bash "${tmp}/pg8.sh" >"${tmp}/pg8.out" 2>&1; then
  echo 'PG8 action fixture unexpectedly passed' >&2
  exit 1
fi
grep -qF 'build-failure: category=dependency-resolution count=1 target=dbx_pg8_performance_live' "${tmp}/pg8.out"
! grep -Eq 'PRIVATE-CRATE|PRIVATE raw message' "${tmp}/pg8.out"
pg8_temp_real="$(cd "${tmp}/pg8-temp" && pwd -P)"
pg8_output_value() { sed -n "s/^$2=//p" "$1"; }
[[ "$(cat "${tmp}/target.capture")" == "${pg8_temp_real}/pg8-measurement-24680-1/probe" ]]
[[ -d "${tmp}/pg8-temp/pg8-measurement-24680-1/product-off" && -d "${tmp}/pg8-temp/pg8-measurement-24680-1/product-on" ]]
grep -qF "target_root=${pg8_temp_real}/pg8-measurement-24680-1" "${tmp}/pg8-output-1"
grep -qF 'summary_dir=' "${tmp}/pg8-output-1"
pg8_build_log_1="$(pg8_output_value "${tmp}/pg8-output-1" build_log)"
[[ "${pg8_build_log_1}" == "${pg8_temp_real}/pg8-probe-build-24680-1-"*.log ]]
for helper_case in missing broken; do
  pg8_workspace="${tmp}/pg8-nohelper-workspace"
  test_path="${tmp}/pg8-bin:${PATH}"
  mkdir -p "${pg8_workspace}/src"
  if [[ "${helper_case}" == broken ]]; then
    pg8_workspace="${tmp}"
    test_path="${tmp}/broken-ruby-bin:${tmp}/pg8-bin:${PATH}"
  fi
  helper_attempt=3
  [[ "${helper_case}" != broken ]] || helper_attempt=4
  if PATH="${test_path}" GITHUB_WORKSPACE="${pg8_workspace}" RUNNER_TEMP="${tmp}/pg8-temp" SOURCE_PATH=src GITHUB_RUN_ID=24680 GITHUB_RUN_ATTEMPT="${helper_attempt}" GITHUB_OUTPUT="${tmp}/pg8-output-${helper_attempt}" FAKE_TARGET_CAPTURE="${tmp}/target.capture" bash "${tmp}/pg8.sh" >"${tmp}/pg8-${helper_case}-helper.out" 2>&1; then
    echo "PG8 ${helper_case}-helper fixture unexpectedly passed" >&2
    exit 1
  fi
  grep -qF 'build-failure: category=other count=1 target=dbx_pg8_performance_live' "${tmp}/pg8-${helper_case}-helper.out"
  ! grep -Eq 'LoadError|cannot load such file|PRIVATE-RUBY-ERROR|/Users/PRIVATE' "${tmp}/pg8-${helper_case}-helper.out"
done

# The source path and temp path are validated before Cargo can run. A source symlink,
# a temp directory inside the checkout, and an attacker-controlled source path all fail.
mkdir -p "${tmp}/pg8-outside-source" "${tmp}/pg8-symlink-workspace" "${tmp}/pg8-symlink-workspace/.github/policy"
cp "${classifier}" "${tmp}/pg8-symlink-workspace/.github/policy/build-failure-category.rb"
ln -s "${tmp}/pg8-outside-source" "${tmp}/pg8-symlink-workspace/src"
for invalid_case in symlink-source inside-source-temp source-path; do
  workspace="${tmp}"
  runner_temp="${tmp}/pg8-temp"
  source_path=src
  if [[ "${invalid_case}" == symlink-source ]]; then workspace="${tmp}/pg8-symlink-workspace"; fi
  if [[ "${invalid_case}" == inside-source-temp ]]; then runner_temp="${tmp}/src/runner-temp"; mkdir -p "${runner_temp}"; fi
  if [[ "${invalid_case}" == source-path ]]; then source_path=../outside; fi
  if PATH="${tmp}/pg8-bin:${PATH}" GITHUB_WORKSPACE="${workspace}" RUNNER_TEMP="${runner_temp}" SOURCE_PATH="${source_path}" GITHUB_RUN_ID=24680 GITHUB_RUN_ATTEMPT=5 GITHUB_OUTPUT="${tmp}/pg8-output-invalid-${invalid_case}" FAKE_TARGET_CAPTURE="${tmp}/should-not-run" bash "${tmp}/pg8.sh" >"${tmp}/pg8-${invalid_case}.out" 2>&1; then
    echo "PG8 ${invalid_case} path fixture unexpectedly passed" >&2; exit 1
  fi
  [[ ! -e "${tmp}/should-not-run" ]]
  ! grep -Eq '/Users/|/home/|PRIVATE|SECRET' "${tmp}/pg8-${invalid_case}.out"
done

# Exercise the prepared-target branch using an extracted-script copy with the fixed mount
# path redirected to a synthetic owned temp directory; never touch the real /mnt mount.
prepared_dir="${tmp}/prepared-mount"
mkdir -m 0700 "${prepared_dir}"
prepared="$(cd "${prepared_dir}" && pwd -P)"
sed "s#/mnt/cargo-target#${prepared}#g" "${tmp}/pg8.sh" >"${tmp}/pg8-prepared.sh"
bash -n "${tmp}/pg8-prepared.sh"
if PATH="${tmp}/pg8-bin:${PATH}" CARGO_TARGET_DIR="${prepared}" GITHUB_WORKSPACE="${tmp}" RUNNER_TEMP="${tmp}/pg8-temp" SOURCE_PATH=src GITHUB_RUN_ID=24680 GITHUB_RUN_ATTEMPT=6 GITHUB_OUTPUT="${tmp}/pg8-output-6" FAKE_TARGET_CAPTURE="${tmp}/prepared.capture" bash "${tmp}/pg8-prepared.sh" >"${tmp}/pg8-prepared.out" 2>&1; then
  echo 'PG8 prepared-target failure fixture unexpectedly passed' >&2; exit 1
fi
[[ "$(cat "${tmp}/prepared.capture")" == "${prepared}/pg8-measurement-24680-6/probe" ]]
[[ -d "${prepared}/pg8-measurement-24680-6/product-off" && -d "${prepared}/pg8-measurement-24680-6/product-on" ]]

# An unwritable prepared candidate and a symlink candidate both fall back to the owned
# runner temp root; neither causes Cargo to write through the rejected candidate.
chmod 0500 "${prepared}"
if PATH="${tmp}/pg8-bin:${PATH}" CARGO_TARGET_DIR="${prepared}" GITHUB_WORKSPACE="${tmp}" RUNNER_TEMP="${tmp}/pg8-temp" SOURCE_PATH=src GITHUB_RUN_ID=24680 GITHUB_RUN_ATTEMPT=7 GITHUB_OUTPUT="${tmp}/pg8-output-7" FAKE_TARGET_CAPTURE="${tmp}/unwritable.capture" bash "${tmp}/pg8-prepared.sh" >"${tmp}/pg8-unwritable.out" 2>&1; then
  echo 'PG8 unwritable-target failure fixture unexpectedly passed' >&2; exit 1
fi
chmod 0700 "${prepared}"
[[ "$(cat "${tmp}/unwritable.capture")" == "${pg8_temp_real}/pg8-measurement-24680-7/probe" ]]
[[ ! -e "${prepared}/pg8-measurement-24680-7" ]]
ln -s "${prepared}" "${tmp}/prepared-link"
sed "s#${prepared}#${tmp}/prepared-link#g" "${tmp}/pg8-prepared.sh" >"${tmp}/pg8-symlink-candidate.sh"
bash -n "${tmp}/pg8-symlink-candidate.sh"
if PATH="${tmp}/pg8-bin:${PATH}" CARGO_TARGET_DIR="${tmp}/prepared-link" GITHUB_WORKSPACE="${tmp}" RUNNER_TEMP="${tmp}/pg8-temp" SOURCE_PATH=src GITHUB_RUN_ID=24680 GITHUB_RUN_ATTEMPT=8 GITHUB_OUTPUT="${tmp}/pg8-output-8" FAKE_TARGET_CAPTURE="${tmp}/symlink-candidate.capture" bash "${tmp}/pg8-symlink-candidate.sh" >"${tmp}/pg8-symlink-candidate.out" 2>&1; then
  echo 'PG8 symlink-target failure fixture unexpectedly passed' >&2; exit 1
fi
[[ "$(cat "${tmp}/symlink-candidate.capture")" == "${pg8_temp_real}/pg8-measurement-24680-8/probe" ]]
[[ ! -e "${prepared}/pg8-measurement-24680-8" ]]

# The cleanup step only removes successful allocations from control-step outputs. It leaves
# sibling sentinels untouched; all paths are synthetic directories under this fixture.
ruby "${root}/.github/policy/extract-step.rb" "${pg8_action}" 'Remove private measurement files and build outputs' run >"${tmp}/pg8-cleanup.sh"
bash -n "${tmp}/pg8-cleanup.sh"
mkdir -p "${tmp}/pg8-temp/pg8-measurement-24680-6-summary" "${prepared}/pg8-measurement-24680-6" "${tmp}/pg8-temp/pg8-measurement-24680-6"
printf 'private log\n' >"${tmp}/pg8-temp/pg8-probe-build-24680-1.log"
printf 'sentinel\n' >"${tmp}/pg8-temp/keep-me"
sed "s#/mnt/cargo-target#${prepared}#g" "${tmp}/pg8-cleanup.sh" >"${tmp}/pg8-cleanup-prepared.sh"
RUNNER_TEMP="${tmp}/pg8-temp" GITHUB_RUN_ID=24680 GITHUB_RUN_ATTEMPT=1 PG8_TARGET_ROOT="$(pg8_output_value "${tmp}/pg8-output-1" target_root)" PG8_SUMMARY_DIR="$(pg8_output_value "${tmp}/pg8-output-1" summary_dir)" PG8_BUILD_LOG="${pg8_build_log_1}" bash "${tmp}/pg8-cleanup.sh"
[[ ! -e "${pg8_temp_real}/pg8-measurement-24680-1" && ! -e "${pg8_temp_real}/pg8-probe-build-24680-1.log" && -f "${tmp}/pg8-temp/keep-me" ]]
printf 'summary data\n' >"${tmp}/pg8-temp/pg8-measurement-24680-6-summary/keep"
pg8_build_log_6="$(pg8_output_value "${tmp}/pg8-output-6" build_log)"
printf 'build log\n' >"${pg8_build_log_6}"
RUNNER_TEMP="${tmp}/pg8-temp" GITHUB_RUN_ID=24680 GITHUB_RUN_ATTEMPT=6 PG8_TARGET_ROOT="$(pg8_output_value "${tmp}/pg8-output-6" target_root)" PG8_SUMMARY_DIR="${tmp}/pg8-temp/pg8-measurement-24680-6-summary" PG8_BUILD_LOG="${pg8_build_log_6}" bash "${tmp}/pg8-cleanup-prepared.sh"
[[ ! -e "${prepared}/pg8-measurement-24680-6" && ! -e "${tmp}/pg8-temp/pg8-measurement-24680-6" ]]
[[ ! -e "${tmp}/pg8-temp/pg8-measurement-24680-6-summary" && -f "${tmp}/pg8-temp/keep-me" ]]
[[ ! -e "${pg8_build_log_6}" ]]

# Rejected setup paths publish only directories actually allocated. A pre-existing target
# is never emitted for cleanup; a newly created root is emitted if summary allocation refuses.
mkdir -p "${pg8_temp_real}/pg8-measurement-24680-9"
printf 'target sentinel\n' >"${pg8_temp_real}/pg8-measurement-24680-9/keep"
if PATH="${tmp}/pg8-bin:${PATH}" GITHUB_WORKSPACE="${tmp}" RUNNER_TEMP="${tmp}/pg8-temp" SOURCE_PATH=src GITHUB_RUN_ID=24680 GITHUB_RUN_ATTEMPT=9 GITHUB_OUTPUT="${tmp}/pg8-output-9" FAKE_TARGET_CAPTURE="${tmp}/should-not-run-9" bash "${tmp}/pg8.sh" >"${tmp}/pg8-preexisting-target.out" 2>&1; then
  echo 'PG8 pre-existing target fixture unexpectedly passed' >&2; exit 1
fi
[[ -z "$(pg8_output_value "${tmp}/pg8-output-9" target_root)" && -z "$(pg8_output_value "${tmp}/pg8-output-9" summary_dir)" ]]
RUNNER_TEMP="${tmp}/pg8-temp" GITHUB_RUN_ID=24680 GITHUB_RUN_ATTEMPT=9 PG8_TARGET_ROOT="$(pg8_output_value "${tmp}/pg8-output-9" target_root)" PG8_SUMMARY_DIR="$(pg8_output_value "${tmp}/pg8-output-9" summary_dir)" PG8_BUILD_LOG="$(pg8_output_value "${tmp}/pg8-output-9" build_log)" bash "${tmp}/pg8-cleanup.sh"
[[ -f "${pg8_temp_real}/pg8-measurement-24680-9/keep" ]]

mkdir -p "${pg8_temp_real}/pg8-measurement-24680-10-summary"
printf 'summary sentinel\n' >"${pg8_temp_real}/pg8-measurement-24680-10-summary/keep"
if PATH="${tmp}/pg8-bin:${PATH}" GITHUB_WORKSPACE="${tmp}" RUNNER_TEMP="${tmp}/pg8-temp" SOURCE_PATH=src GITHUB_RUN_ID=24680 GITHUB_RUN_ATTEMPT=10 GITHUB_OUTPUT="${tmp}/pg8-output-10" FAKE_TARGET_CAPTURE="${tmp}/should-not-run-10" bash "${tmp}/pg8.sh" >"${tmp}/pg8-preexisting-summary.out" 2>&1; then
  echo 'PG8 pre-existing summary fixture unexpectedly passed' >&2; exit 1
fi
[[ "$(pg8_output_value "${tmp}/pg8-output-10" target_root)" == "${pg8_temp_real}/pg8-measurement-24680-10" ]]
[[ -z "$(pg8_output_value "${tmp}/pg8-output-10" summary_dir)" ]]
RUNNER_TEMP="${tmp}/pg8-temp" GITHUB_RUN_ID=24680 GITHUB_RUN_ATTEMPT=10 PG8_TARGET_ROOT="$(pg8_output_value "${tmp}/pg8-output-10" target_root)" PG8_SUMMARY_DIR="$(pg8_output_value "${tmp}/pg8-output-10" summary_dir)" PG8_BUILD_LOG="$(pg8_output_value "${tmp}/pg8-output-10" build_log)" bash "${tmp}/pg8-cleanup.sh"
[[ ! -e "${pg8_temp_real}/pg8-measurement-24680-10" && -f "${pg8_temp_real}/pg8-measurement-24680-10-summary/keep" ]]

# Invalid source/temp setup has no allocated-path outputs, so always cleanup preserves any
# same-run-name sentinels already present under RUNNER_TEMP.
mkdir -p "${pg8_temp_real}/pg8-measurement-24680-11" "${pg8_temp_real}/pg8-measurement-24680-11-summary"
printf 'invalid-path sentinel\n' >"${pg8_temp_real}/pg8-measurement-24680-11/keep"
printf 'invalid-summary sentinel\n' >"${pg8_temp_real}/pg8-measurement-24680-11-summary/keep"
if PATH="${tmp}/pg8-bin:${PATH}" GITHUB_WORKSPACE="${tmp}" RUNNER_TEMP="${tmp}/src/runner-temp" SOURCE_PATH=src GITHUB_RUN_ID=24680 GITHUB_RUN_ATTEMPT=11 GITHUB_OUTPUT="${tmp}/pg8-output-11" FAKE_TARGET_CAPTURE="${tmp}/should-not-run-11" bash "${tmp}/pg8.sh" >"${tmp}/pg8-invalid-temp.out" 2>&1; then
  echo 'PG8 invalid temp fixture unexpectedly passed' >&2; exit 1
fi
[[ -z "$(pg8_output_value "${tmp}/pg8-output-11" target_root)" && -z "$(pg8_output_value "${tmp}/pg8-output-11" summary_dir)" ]]
RUNNER_TEMP="${tmp}/pg8-temp" GITHUB_RUN_ID=24680 GITHUB_RUN_ATTEMPT=11 PG8_TARGET_ROOT="$(pg8_output_value "${tmp}/pg8-output-11" target_root)" PG8_SUMMARY_DIR="$(pg8_output_value "${tmp}/pg8-output-11" summary_dir)" PG8_BUILD_LOG="$(pg8_output_value "${tmp}/pg8-output-11" build_log)" bash "${tmp}/pg8-cleanup.sh"
[[ -f "${pg8_temp_real}/pg8-measurement-24680-11/keep" && -f "${pg8_temp_real}/pg8-measurement-24680-11-summary/keep" ]]
echo 'build-failure category fixtures: classifications, privacy, failure preservation, live-build and PG8 callsites pass'
