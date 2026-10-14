#!/usr/bin/env bash
# Exercise the actual report-library helpers with synthetic package/runner failures.
# No private checkout, Cargo build, source test execution, or network access.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "${fixture}"' EXIT
awk '
  /cat > .*report\.sh.*TCI_REPORT_LIBRARY/ { inside=1; next }
  inside && /^        TCI_REPORT_LIBRARY$/ { exit }
  inside { sub(/^        /, ""); print }
' "${root}/.github/actions/concern-report/action.yml" > "${fixture}/report.sh"
# shellcheck source=/dev/null
source "${fixture}/report.sh"
mkdir -p "${fixture}/bin" "${fixture}/source/.config"
printf '#!/usr/bin/env bash\nexit 0\n' > "${fixture}/bin/cargo-nextest"
chmod +x "${fixture}/bin/cargo-nextest"
export PATH="${fixture}/bin:${PATH}"
export RUNNER_TEMP="${fixture}" GITHUB_STEP_SUMMARY="${fixture}/summary"
touch "${fixture}/source/.config/nextest.toml"
cd "${fixture}/source"
calls="${fixture}/calls"
path_calls="${fixture}/path-calls"
simulation=''
# The real run_deferred/build splitter executes only this synthetic command stand-in.
run_quiet() {
  local label="$1"; shift
  printf '%s|' "${label}" >> "${calls}"
  printf '%s ' "$@" >> "${calls}"
  printf '\n' >> "${calls}"
  printf '%s|%s\n' "${label}" "${PATH}" >> "${path_calls}"
  case "${simulation}" in
    missing-feature) [[ " $* " != *' --features=legacy-tls '* ]] || return 42 ;;
    missing-target) [[ " $* " != *' --test=dbx_route_dial '* ]] || return 42 ;;
    no-tests)
      if [[ " $* " == *' nextest run '* && " $* " != *' --no-run '* ]]; then
        [[ " $* " != *' --no-tests=fail '* ]] || return 4
      fi
      ;;
  esac
  return 0
}
cargo_test_reason() { printf '%s\n' 'synthetic required-case failure'; }
reset_case() {
  : > "${calls}"; : > "${path_calls}"; : > "${GITHUB_STEP_SUMMARY}"
  deferred_results=(); deferred_failed=0; deferred_timing=''; simulation=''
}
reset_case
dbx_registered_feature_tests --package=taurine-db-engine --package=taurine-db-conformance
[[ ! -s "${calls}" && "${deferred_failed}" -eq 0 ]]
grep -qF 'uncovered / not executed' "${GITHUB_STEP_SUMMARY}"
grep -qF 'live pg-dbx remains required' "${GITHUB_STEP_SUMMARY}"
reset_case
dbx_registered_feature_tests --package=taurine-db-dbx-shadow
[[ ! -s "${calls}" ]]

reset_case
dbx_registered_feature_tests --package=taurine-db-engine --package=taurine-db-dbx
[[ "${deferred_failed}" -eq 0 ]]
grep -qE '^rust-db-dbx-legacy-tls-tests\|.*--no-tests=fail .*--package=taurine-db-dbx --features=legacy-tls ' "${calls}"
grep -qE '^rust-db-dbx-legacy-tls-doctests\|cargo test .*--doc .*--package=taurine-db-dbx --features=legacy-tls ' "${calls}"
grep -qE '^rust-db-engine-dbx-route-tests\|.*--no-tests=fail .*--package=taurine-db-engine --features=dbx-pg,engine-override,taurine-db-dbx/legacy-tls --test=dbx_route_dial ' "${calls}"
! grep -qF 'rust-db-engine-dbx-route-doctests|' "${calls}"
! grep -E -- '-build\|.*--no-tests' "${calls}"
grep -qE '^rust-db-engine-dbx-route-build\|.*--features=dbx-pg,engine-override,taurine-db-dbx/legacy-tls --test=dbx_route_dial ' "${calls}"
# Scope restores ordinary tests/doctests and does not impose the new feature flags.
rust_tests rust-db-tests --package=taurine-db-engine
grep -qF 'rust-db-doctests|cargo test ' "${calls}"
! grep -E -- '^rust-db-tests\|.*--no-tests|^rust-db-tests\|.*--features=' "${calls}"
[[ -z "${NEXTEST_DOCTESTS:-}" && -z "${NEXTEST_REQUIRE_TESTS:-}" ]]

# Exercise the exact PATH-scoped invocation extracted from the Windows rust-db action.
# The shared helper above expands it into the real fixed build, test and legacy doctest
# commands; run_quiet records the environment while standing in for Cargo.
windows_db_call="$(ruby -ryaml -e 'w=YAML.safe_load(File.read(ARGV[0]),aliases:false); run=w.fetch("runs").fetch("steps").map { |s| s["run"].to_s }.join("\n"); branch=run[/^\s*rust-db\)(.*?)^\s*;;/m,1] or abort "missing rust-db"; call=branch.lines.find { |line| line.include?("PATH=\"${dbx_feature_path}\" dbx_registered_feature_tests") } or abort "missing PATH-scoped call"; print call.strip' "${root}/.github/actions/windows-concern-rust/action.yml")"
[[ "${windows_db_call}" == 'PATH="${dbx_feature_path}" dbx_registered_feature_tests "${db_packages[@]}"' ]]
reset_case
original_path="${PATH}"
dbx_feature_path="/c/Strawberry/perl/bin:/c/Program Files/NASM:${PATH}"
db_packages=(--package=taurine-db-engine --package=taurine-db-dbx)
eval "${windows_db_call}"
[[ "${PATH}" == "${original_path}" && "${deferred_failed}" -eq 0 ]]
for label in rust-db-dbx-legacy-tls-build rust-db-dbx-legacy-tls-tests rust-db-dbx-legacy-tls-doctests rust-db-engine-dbx-route-build rust-db-engine-dbx-route-tests; do
  grep -F "${label}|/c/Strawberry/perl/bin:/c/Program Files/NASM:${original_path}" "${path_calls}" >/dev/null || { echo "${label}: fixed Windows PATH was not inherited" >&2; exit 1; }
done
# The preceding ordinary database tests use the original PATH; no feature flags leak.
reset_case
rust_tests rust-db-tests --package=taurine-db-engine
[[ "${PATH}" == "${original_path}" ]]
grep -F "rust-db-tests|${original_path}" "${path_calls}" >/dev/null
grep -F "rust-db-doctests|${original_path}" "${path_calls}" >/dev/null
! grep -E -- '^rust-db-tests\|.*--no-tests|^rust-db-tests\|.*--features=' "${calls}"
# A required feature failure remains a failure and the caller's PATH is still restored.
reset_case
simulation=missing-target
eval "${windows_db_call}"
[[ "${PATH}" == "${original_path}" && "${deferred_failed}" -eq 1 ]]
if (finish_deferred) >/dev/null 2>&1; then
  echo 'feature failure unexpectedly passed aggregation' >&2; exit 1
fi
grep -F 'rust-db-engine-dbx-route-build|' "${calls}" >/dev/null

for failure in missing-feature missing-target no-tests; do
  reset_case; simulation="${failure}"
  dbx_registered_feature_tests --package=taurine-db-dbx
  [[ "${deferred_failed}" -eq 1 ]] || { echo "${failure}: required coverage did not fail closed" >&2; exit 1; }
  if (finish_deferred) >/dev/null 2>&1; then
    echo "${failure}: aggregate accepted missing required coverage" >&2; exit 1
  fi
done
reset_case
mv .config/nextest.toml .config/nextest.toml-held
dbx_registered_feature_tests --package=taurine-db-dbx
[[ "${deferred_failed}" -eq 1 && ! -s "${calls}" ]]
[[ "${#deferred_results[@]}" -eq 2 ]]
mv .config/nextest.toml-held .config/nextest.toml
reset_case
command() {
  if [[ "${1:-}" == -v && "${2:-}" == cargo-nextest ]]; then return 1; fi
  builtin command "$@"
}
dbx_registered_feature_tests --package=taurine-db-dbx
[[ "${deferred_failed}" -eq 1 && ! -s "${calls}" ]]
for os in linux macos windows; do
  ruby -ryaml -e 'w=YAML.safe_load(File.read(ARGV[0]),aliases:false); run=w.fetch("runs").fetch("steps").map { |s| s["run"].to_s }.join("\n"); branch=run[/^\s*rust-db\)(.*?)^\s*;;/m,1] or abort "missing rust-db"; expected="rust_tests rust-db-tests \"${db_packages[@]}\"\n"; abort "baseline invocation removed" unless branch.include?(expected); abort "missing exact registered feature call" unless branch.include?("dbx_registered_feature_tests \"${db_packages[@]}\"")' \
    "${root}/.github/actions/${os}-concern-rust/action.yml"
done
echo 'dbx feature coverage: old source explicitly uncovered; registered required cases, nonempty execution, scoped doctests and failure aggregation verified on synthetic fixtures'
