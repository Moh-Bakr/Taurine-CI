#!/usr/bin/env bash
# Exercise the real live-proof planning step and reject malformed roster JSON.
set -euo pipefail

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/live-roster-test.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
workflow=.github/workflows/live-proofs.yml
source_sha=1111111111111111111111111111111111111111

ruby .github/policy/extract-step.rb "${workflow}" \
  'Validate the dispatch input and select the arms' run > "${work}/plan.sh"
# macOS ships Bash 3.2, which lacks the workflow's final diagnostic-only
# lowercase expansion. Leave the hosted Bash 5 script untouched.
if (( BASH_VERSINFO[0] < 4 )); then
  ruby -e '
    path = ARGV.fetch(0)
    script = File.read(path)
    old = %q|${REQUESTED_SOURCE_SHA,,}|
    abort "live roster fixture: diagnostic expansion missing" unless script.scan(old).length == 1
    File.write(path, script.sub(old, %q|${REQUESTED_SOURCE_SHA}|))
  ' "${work}/plan.sh"
fi
RUNNER_TEMP="${work}" GITHUB_OUTPUT="${work}/output" \
  REQUESTED_ENGINE=all REQUESTED_SOURCE_SHA="${source_sha}" \
  bash "${work}/plan.sh" > "${work}/stdout"

roster="$(sed -n 's/^roster=//p' "${work}/output")"
arms="$(sed -n 's/^arms=//p' "${work}/output")"
[[ -n "${roster}" && -n "${arms}" ]] || {
  echo 'live roster fixture: planning step omitted roster or arms' >&2
  exit 1
}
jq -e '
  type == "object" and
  (keys | sort) == (["doris", "starrocks", "db2", "informix", "rocketmq", "iris", "postgres", "pg-dbx", "mysql", "mssql", "pgtls", "tls-legacy", "bastion"] | sort) and
  (."pg-dbx".suites == ["taurine-db-conformance dbx_pg_live,dbx_shadow_pg"]) and
  (.pgtls.suites == ["taurine-db-postgres live_tls", "taurine-db-conformance dbx_pg_tls_live dbx_tls_", "taurine-db-conformance dbx_pg_mtls_live dbx_pg_mtls_"]) and
  (.pgtls.cargo_features == ["taurine-db-dbx/dbx-pg", "taurine-db-dbx/legacy-tls"]) and
  (."tls-legacy".suites == ["taurine-db-conformance dbx_pg_tls_live legacy"]) and
  (."tls-legacy".cargo_features == ["taurine-db-dbx/legacy-tls"]) and
  (all(.[]; (.engine | type) == "string" and (.report | type) == "boolean" and (.blurb | type) == "string"))
' <<< "${roster}" >/dev/null
jq -e --argjson selected "${arms}" '
  $selected == ["doris", "starrocks", "db2", "informix", "rocketmq", "iris", "postgres", "pg-dbx", "mysql", "mssql", "pgtls", "tls-legacy", "bastion"]
' <<< "${roster}" >/dev/null
contract_arms="$(jq -c '.dispatch_contracts.workflows[".github/workflows/live-proofs.yml"].inputs.engine.options' .github/ci-matrix.json)"
[[ "${contract_arms}" == "${arms}" ]] || {
  echo 'live roster fixture: dispatch identity contract differs from the executed arm roster' >&2
  exit 1
}

# Exercise the reusable arm's exact configuration gate. Only the legacy arm
# may request the fixed OpenSSL feature and exact target/filter; pgtls must
# carry the ordinary DBX TLS target. No arbitrary Cargo features or test names
# are accepted from the arm config.
arm_validation=.github/workflows/live-proof-arm.yml
ruby .github/policy/extract-step.rb "${arm_validation}" \
  'Validate protected call input' run > "${work}/arm-validation.sh"
if (( BASH_VERSINFO[0] < 4 )); then
  ruby -e 'path=ARGV.fetch(0); text=File.read(path); old=%q|${REQUESTED_SOURCE_SHA,,}|; abort unless text.scan(old).length == 1; File.write(path,text.sub(old,%q|${REQUESTED_SOURCE_SHA}|))' "${work}/arm-validation.sh"
fi
legacy_config="$(jq -c '."tls-legacy"' <<< "${roster}")"
pgtls_config="$(jq -c '.pgtls' <<< "${roster}")"
validate_arm() {
  local engine="$1" config="$2" expected="$3" label="$4"
  local status=0
  RUNNER_TEMP="${work}" GITHUB_REPOSITORY=Moh-Bakr/Taurine-CI GITHUB_REF=refs/heads/main \
    REQUESTED_ENGINE="${engine}" REQUESTED_SOURCE_SHA="${source_sha}" ARM_CONFIG="${config}" \
    bash "${work}/arm-validation.sh" > "${work}/arm-validation.out" 2> "${work}/arm-validation.err" || status=$?
  if [[ "${expected}" == pass && "${status}" -ne 0 ]]; then
    echo "live roster fixture: valid ${label} arm was rejected" >&2
    exit 1
  fi
  if [[ "${expected}" == reject && "${status}" -eq 0 ]]; then
    echo "live roster fixture: malformed ${label} arm was accepted" >&2
    exit 1
  fi
}
while IFS= read -r engine; do
  config="$(jq -c --arg engine "${engine}" '.[$engine]' <<< "${roster}")"
  validate_arm "${engine}" "${config}" pass "${engine}"
done < <(jq -r 'keys[]' <<< "${roster}")
validate_arm tls-legacy "$(jq -c '. + {cargo_features:["unreviewed/feature"]}' <<< "${legacy_config}")" reject 'unreviewed feature'
validate_arm tls-legacy "$(jq -c 'del(.cargo_features)' <<< "${legacy_config}")" reject 'missing legacy feature'
validate_arm tls-legacy "$(jq -c '.suites=["taurine-db-conformance dbx_pg_tls_live dbx_tls_"]' <<< "${legacy_config}")" reject 'ordinary target in legacy arm'
validate_arm pgtls "$(jq -c '.suites=["taurine-db-postgres live_tls"]' <<< "${pgtls_config}")" reject 'missing ordinary DBX TLS target'
validate_arm pgtls "$(jq -c '. + {cargo_features:["unreviewed/feature"]}' <<< "${pgtls_config}")" reject 'unreviewed mTLS feature'
validate_arm pgtls "$(jq -c '.suites |= .[0:2]' <<< "${pgtls_config}")" reject 'missing mTLS target'
validate_arm tls-legacy "$(jq -c '. + {cargo_command:"echo untrusted"}' <<< "${legacy_config}")" reject 'unreviewed project command'

# Run the actual live-build/live-run shell steps with a fake cargo executable
# and a synthetic target file. This proves the fixed feature and exact test
# filters reach Cargo while never invoking a source build or test binary.
mkdir -p "${work}/runner" "${work}/fake-source/taurine-backend/taurine-db-conformance/tests" "${work}/fakebin"
mkdir -p "${work}/fake-source/.github/policy"
cp .github/policy/build-failure-category.rb "${work}/fake-source/.github/policy/build-failure-category.rb"
printf '// synthetic target marker\n' > "${work}/fake-source/taurine-backend/taurine-db-conformance/tests/dbx_pg_tls_live.rs"
printf '// synthetic target marker\n' > "${work}/fake-source/taurine-backend/taurine-db-conformance/tests/dbx_pg_mtls_live.rs"
cat > "${work}/fakebin/cargo" <<'FAKE_CARGO'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_CARGO_LOG}"
if [[ "$*" == *--no-run* ]]; then
  if [[ "${FAKE_CARGO_MODE:-}" == compiler-heavy ]]; then
    printf 'error[E0046]: private message SECRET_COMPILER_MESSAGE\n  --> /private/var/runner/SECRET_PATH/src/private.rs:9:7\n'
    for index in $(seq 1 80); do printf 'warning: PRIVATE_WARNING_%s SECRET_WARNING_VALUE\n' "${index}"; done
    exit 101
  fi
  if [[ "${FAKE_CARGO_MODE:-}" == compiler-nocode ]]; then
    printf 'error: private compiler failure SECRET_NONCODE_MESSAGE /home/runner/work/private/src/lib.rs:4:2\n'
    exit 101
  fi
  if [[ "${FAKE_CARGO_MODE:-}" == compiler-empty ]]; then
    printf 'cargo process failed before diagnostics SECRET_EMPTY_MESSAGE /home/runner/work/private/src/lib.rs\n'
    exit 2
  fi
  echo 'Finished synthetic proof binary build'
  exit 0
fi
if [[ "$*" != *dbx_pg_tls_live* && "$*" != *dbx_pg_mtls_live* ]]; then
  printf 'test result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out\n'
  exit 0
fi
if [[ "$*" == *dbx_pg_mtls_live* && "${FAKE_CARGO_MODE:-pass2}" == pass8 ]]; then
  printf 'test result: ok. 8 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out\n'
  exit 0
fi
case "${FAKE_CARGO_MODE:-pass2}" in
  pass8) printf 'test result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out\n' ;;
  pass2) printf 'test result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out\n' ;;
  filtered2) printf 'test result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; 2 filtered out\n' ;;
  pass1) printf 'test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out\n' ;;
  pass0) printf 'test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out\n' ;;
  ignored) printf 'test result: ok. 1 passed; 0 failed; 1 ignored; 0 measured; 0 filtered out\n' ;;
  filtered) printf 'test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 1 filtered out\n' ;;
  skipped) printf 'SKIPPED: required fixture was not executed\ntest result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out\n' ;;
  failed) printf 'test result: FAILED. 1 passed; 1 failed; 0 ignored; 0 measured; 0 filtered out\n'; exit 1 ;;
  *) echo 'unknown fake cargo mode' >&2; exit 2 ;;
esac
FAKE_CARGO
chmod +x "${work}/fakebin/cargo"
ruby .github/policy/extract-step.rb .github/actions/live-build/action.yml \
  "Build the engine's proof test binary" run > "${work}/build.sh"
ruby .github/policy/extract-step.rb .github/actions/live-run/action.yml \
  "Run the engine's live proof" run > "${work}/run.sh"
ruby .github/policy/extract-step.rb .github/actions/live-start-pg/action.yml \
  'Start the postgres, pgtls, tls-legacy, bastion server and wait for readiness' run > "${work}/start-pg.sh"
bash -n "${work}/build.sh" "${work}/run.sh" "${work}/start-pg.sh"
for required in TAURINE_TEST_DBX_MTLS_REQUIRED TAURINE_TEST_PG_MTLS_SERVER_CA TAURINE_TEST_PG_MTLS_CLIENT_CERT TAURINE_TEST_PG_MTLS_CLIENT_KEY TAURINE_TEST_PG_MTLS_UNTRUSTED_CERT TAURINE_TEST_PG_MTLS_UNTRUSTED_KEY; do
  grep -Fq "${required}" "${work}/start-pg.sh" || { echo "live roster fixture: pgtls does not export ${required}" >&2; exit 1; }
done
grep -Fq 'ssl_min_protocol_version=TLSv1 -c ssl_max_protocol_version=TLSv1' "${work}/start-pg.sh" || {
  if ! grep -Fq 'tls10)' .github/policy/pgtls-postgres-entrypoint.sh || ! grep -Fq 'ssl_max_protocol_version=TLSv1' .github/policy/pgtls-postgres-entrypoint.sh; then
    echo 'live roster fixture: TLS10 endpoint is not pinned to TLS 1.0 only' >&2; exit 1;
  fi
}
grep -Fq '[[ "${got}" == "TLSv1" && -z "${refused}" ]] && tls10_ok=1' "${work}/start-pg.sh" || {
  echo 'live roster fixture: TLS10 readiness does not require a TLSv1 handshake' >&2; exit 1;
}
run_fake_actions() {
  local engine="$1" config="$2" label="$3" mode="$4" expected="$5"
  local runner="${work}/runner-${label}" log="${work}/cargo-${label}.log" command_status=0
  mkdir -p "${runner}"
  printf '%s\n' "${config}" > "${runner}/live-arm.json"
  jq -r '(.suites // [])[]' "${runner}/live-arm.json" > "${runner}/suites.txt"
  : > "${log}"
  (
    set -e
    cd "${work}/fake-source"
    RUNNER_TEMP="${runner}" GITHUB_WORKSPACE="${work}/fake-source" FAKE_CARGO_LOG="${log}" FAKE_CARGO_MODE="${mode}" PATH="${work}/fakebin:${PATH}" bash "${work}/build.sh"
    RUNNER_TEMP="${runner}" FAKE_CARGO_LOG="${log}" FAKE_CARGO_MODE="${mode}" PATH="${work}/fakebin:${PATH}" bash "${work}/run.sh"
  ) > "${work}/fake-${label}.out" 2> "${work}/fake-${label}.err" || command_status=$?
  if [[ "${expected}" == pass && "${command_status}" -ne 0 ]]; then
    echo "live roster fixture: fake live actions unexpectedly failed for ${engine}/${mode}" >&2
    cat "${work}/fake-${label}.err" >&2
    exit 1
  elif [[ "${expected}" == reject && "${command_status}" -eq 0 ]]; then
    echo "live roster fixture: fake live actions accepted incomplete ${engine}/${mode} evidence" >&2
    exit 1
  fi
}
run_fake_actions pgtls "${pgtls_config}" pgtls pass8 pass
grep -Fq -- '-p taurine-db-conformance --test dbx_pg_tls_live dbx_tls_ -- --nocapture' "${work}/cargo-pgtls.log" || {
  echo 'live roster fixture: pgtls did not pass the exact ordinary DBX filter to cargo' >&2; exit 1;
}
grep -Fq 'taurine-db-conformance [dbx_pg_tls_live] dbx_tls_ passed=2 skipped=0' "${work}/runner-pgtls/suite-results.txt" || {
  echo 'live roster fixture: ordinary DBX TLS suite did not produce the required two executed tests' >&2; exit 1;
}
grep -Fq -- '-p taurine-db-conformance --features taurine-db-dbx/dbx-pg --features taurine-db-dbx/legacy-tls --test dbx_pg_mtls_live dbx_pg_mtls_ -- --nocapture' "${work}/cargo-pgtls.log" || {
  echo 'live roster fixture: pgtls did not scope both fixed mTLS features and filter to the mTLS target' >&2; exit 1;
}
if grep -F -- '-p taurine-db-conformance --features taurine-db-dbx/dbx-pg --features taurine-db-dbx/legacy-tls --test dbx_pg_tls_live' "${work}/cargo-pgtls.log" >/dev/null; then
  echo 'live roster fixture: mTLS-only features leaked to the ordinary TLS suite' >&2; exit 1;
fi
grep -Fq 'taurine-db-conformance [dbx_pg_mtls_live] dbx_pg_mtls_ passed=8 skipped=0' "${work}/runner-pgtls/suite-results.txt" || {
  echo 'live roster fixture: mTLS suite did not produce the required eight executed cases' >&2; exit 1;
}
run_fake_actions tls-legacy "${legacy_config}" tls-legacy pass2 pass
run_fake_actions tls-legacy "${legacy_config}" compiler-heavy compiler-heavy reject
grep -Fq 'proof-build: compiler diagnostics target=dbx_pg_tls_live codes=E0046=1' "${work}/fake-compiler-heavy.err" || {
  echo 'live roster fixture: an early Rust compiler code was hidden by warning-heavy output' >&2; exit 1;
}
grep -Fq 'build-failure: category=other count=1 target=dbx_pg_tls_live' "${work}/fake-compiler-heavy.err" || {
  echo 'live roster fixture: compiler-heavy failure omitted its protected category summary' >&2; exit 1;
}
if grep -E 'LoadError|cannot load such file' "${work}/fake-compiler-heavy.err" >/dev/null; then
  echo 'live roster fixture: protected classifier helper was unavailable in the fake workspace' >&2; exit 1;
fi
if grep -E 'SECRET_|PRIVATE_WARNING_|/private/var|/home/runner/work' "${work}/fake-compiler-heavy.err" >/dev/null; then
  echo 'live roster fixture: compiler diagnostic summary leaked a private message, path, or warning' >&2; exit 1;
fi
run_fake_actions tls-legacy "${legacy_config}" compiler-nocode compiler-nocode reject
grep -Fq 'proof-build: compiler diagnostics target=dbx_pg_tls_live code=unclassified count=1' "${work}/fake-compiler-nocode.err" || {
  echo 'live roster fixture: code-less compiler error was not classified as unclassified' >&2; exit 1;
}
grep -Fq 'build-failure: category=other count=1 target=dbx_pg_tls_live' "${work}/fake-compiler-nocode.err" || {
  echo 'live roster fixture: code-less compiler failure omitted its protected category summary' >&2; exit 1;
}
if grep -E 'LoadError|cannot load such file' "${work}/fake-compiler-nocode.err" >/dev/null; then
  echo 'live roster fixture: protected classifier helper was unavailable for the code-less case' >&2; exit 1;
fi
if grep -E 'SECRET_|/home/runner/work' "${work}/fake-compiler-nocode.err" >/dev/null; then
  echo 'live roster fixture: code-less diagnostic leaked private content' >&2; exit 1;
fi
run_fake_actions tls-legacy "${legacy_config}" compiler-empty compiler-empty reject
grep -Fq 'proof-build: compiler diagnostics target=dbx_pg_tls_live code=unclassified count=0' "${work}/fake-compiler-empty.err" || {
  echo 'live roster fixture: failure without compiler diagnostics was not visibly unclassified' >&2; exit 1;
}
grep -Fq 'build-failure: category=other count=1 target=dbx_pg_tls_live' "${work}/fake-compiler-empty.err" || {
  echo 'live roster fixture: empty compiler failure omitted its protected category summary' >&2; exit 1;
}
if grep -E 'LoadError|cannot load such file' "${work}/fake-compiler-empty.err" >/dev/null; then
  echo 'live roster fixture: protected classifier helper was unavailable for the empty case' >&2; exit 1;
fi
if grep -E 'SECRET_|/home/runner/work' "${work}/fake-compiler-empty.err" >/dev/null; then
  echo 'live roster fixture: noncompiler failure leaked private content' >&2; exit 1;
fi
grep -Fq -- '-p taurine-db-conformance --features taurine-db-dbx/legacy-tls --test dbx_pg_tls_live legacy -- --nocapture' "${work}/cargo-tls-legacy.log" || {
  echo 'live roster fixture: tls-legacy did not pass the fixed feature and filter to cargo' >&2; exit 1;
}
grep -Fq 'taurine-db-conformance [dbx_pg_tls_live] legacy passed=2 skipped=0' "${work}/runner-tls-legacy/suite-results.txt" || {
  echo 'live roster fixture: legacy DBX TLS suite did not produce the required two executed tests' >&2; exit 1;
}
run_fake_actions tls-legacy "${legacy_config}" filtered-legacy filtered2 pass
for suite in pgtls tls-legacy; do
  if [[ "${suite}" == pgtls ]]; then config="${pgtls_config}"; else config="${legacy_config}"; fi
  for mode in pass0 pass1 ignored filtered skipped failed; do
    run_fake_actions "${suite}" "${config}" "negative-${suite}-${mode}" "${mode}" reject
  done
done

# Reproduce the regression in the extracted step: a shell comment inside the
# heredoc is literal data, not a JSON comment, and must make planning fail.
ruby -e '
  path = ARGV.fetch(0)
  script = File.read(path)
  needle = %q|{"engine": "pg-dbx"|
  abort "live roster fixture: pg-dbx entry missing" unless script.scan(needle).length == 1
  File.write(ARGV.fetch(1), script.sub(needle, "# invalid JSON before pg-dbx\n            #{needle}"))
' "${work}/plan.sh" "${work}/invalid.sh"
if RUNNER_TEMP="${work}" GITHUB_OUTPUT="${work}/invalid-output" \
  REQUESTED_ENGINE=all REQUESTED_SOURCE_SHA="${source_sha}" \
  bash "${work}/invalid.sh" > "${work}/invalid-stdout" 2> "${work}/invalid-stderr"; then
  echo 'live roster fixture: invalid JSON was accepted' >&2
  exit 1
fi
grep -q 'parse error' "${work}/invalid-stderr" || {
  echo 'live roster fixture: invalid planning script failed for an unexpected reason' >&2
  exit 1
}

echo 'live roster: extracted plan selects all 13 arms; arm schema binds exact DBX TLS tests and feature'
if [[ "${LIVE_ROSTER_HOST_PREFIX_CHILD:-}" != 1 ]]; then
  hosted_temp="${work}/hosted-prefix/home/runner/work/_temp"
  mkdir -p "${hosted_temp}"
  if ! RUNNER_TEMP="${hosted_temp}" LIVE_ROSTER_HOST_PREFIX_CHILD=1 bash "${BASH_SOURCE[0]}" >"${work}/hosted-prefix.out" 2>"${work}/hosted-prefix.err"; then
    echo 'live roster fixture: hosted-style /home/runner/work/_temp prefix failed' >&2
    exit 1
  fi
  echo 'live roster fixture: hosted-style /home/runner/work/_temp prefix passed'
fi
