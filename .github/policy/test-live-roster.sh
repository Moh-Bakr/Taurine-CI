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
contract_arms="$(jq -c '.dispatch_contracts.workflows[".github/workflows/live-proofs.yml"].inputs.engine.options' .github/ci-matrix.json)"
old12='["doris","starrocks","db2","informix","rocketmq","iris","postgres","pg-dbx","mysql","mssql","pgtls","bastion"]'
new13='["doris","starrocks","db2","informix","rocketmq","iris","postgres","pg-dbx","mysql","mssql","pgtls","tls-legacy","bastion"]'
if [[ "${contract_arms}" != "${old12}" && "${contract_arms}" != "${new13}" ]]; then
  echo 'live roster fixture: dispatch contract is neither the complete approved old12 nor new13' >&2
  exit 1
fi
jq -e --argjson expected "${contract_arms}" --argjson selected "${arms}" '
  type == "object" and
  (keys | sort) == ($expected | sort) and
  $selected == $expected and
  (."pg-dbx".suites == ["taurine-db-conformance dbx_pg_live,dbx_shadow_pg"]) and
  (all(.[]; (.engine | type) == "string" and (.report | type) == "boolean" and (.blurb | type) == "string")) and
  (if has("tls-legacy") then
     .pgtls.suites == ["taurine-db-postgres live_tls", "taurine-db-conformance dbx_pg_tls_live dbx_tls_", "taurine-db-conformance dbx_pg_mtls_live dbx_pg_mtls_"] and
     .pgtls.cargo_features == ["taurine-db-dbx/dbx-pg", "taurine-db-dbx/legacy-tls"] and
     ."tls-legacy".report == false and
     ."tls-legacy".suites == ["taurine-db-conformance dbx_pg_tls_live legacy"] and
     ."tls-legacy".cargo_features == ["taurine-db-dbx/legacy-tls"]
   else
     .pgtls.suites == ["taurine-db-postgres live_tls"] and
     ((.pgtls | has("cargo_features")) | not)
   end)
' <<< "${roster}" >/dev/null
[[ "${contract_arms}" == "${arms}" ]] || {
  echo 'live roster fixture: dispatch identity contract differs from the executed arm roster' >&2
  exit 1
}

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

# Stage 1 keeps the active plan at old12, while this synthetic planner fixture
# proves the exact complete 13-arm roster and legacy contract before Stage 2 changes
# the dispatcher. When run later over the Stage 2 tree, use its real 13-arm plan
# directly so this fixture never injects a duplicate arm.
expected13='["doris","starrocks","db2","informix","rocketmq","iris","postgres","pg-dbx","mysql","mssql","pgtls","tls-legacy","bastion"]'
plan13="${work}/plan.sh"
if [[ "${contract_arms}" == "${old12}" ]]; then
  ruby -e '
    path = ARGV.fetch(0)
    script = File.read(path)
    pattern = /(\n[ \t]*)\{"engine": "bastion"/
    row = %q|{"engine": "tls-legacy", "report": false, "suites": ["taurine-db-conformance dbx_pg_tls_live legacy"], "cargo_features": ["taurine-db-dbx/legacy-tls"], "blurb": "synthetic compatibility fixture"}|
    abort "live roster fixture: bastion roster entry missing" unless script.scan(pattern).length == 1
    pgtls_pattern = /\{"engine": "pgtls", "report": false,\n[ \t]*"suites": \["taurine-db-postgres live_tls"\],\n[ \t]*"blurb": "[^"]*"\}/
    pgtls = %q|{"engine": "pgtls", "report": false, "suites": ["taurine-db-postgres live_tls", "taurine-db-conformance dbx_pg_tls_live dbx_tls_", "taurine-db-conformance dbx_pg_mtls_live dbx_pg_mtls_"], "cargo_features": ["taurine-db-dbx/dbx-pg", "taurine-db-dbx/legacy-tls"], "blurb": "synthetic Stage 2 proof contract"}|
    abort "live roster fixture: old pgtls entry missing" unless script.scan(pgtls_pattern).length == 1
    script = script.sub(pgtls_pattern, pgtls)
    File.write(ARGV.fetch(1), script.sub(pattern) { "#{Regexp.last_match(1)}#{row},#{Regexp.last_match(1)}{\"engine\": \"bastion\"" })
  ' "${work}/plan.sh" "${work}/plan-13.sh"
  plan13="${work}/plan-13.sh"
fi
RUNNER_TEMP="${work}" GITHUB_OUTPUT="${work}/output-13" \
  REQUESTED_ENGINE=all REQUESTED_SOURCE_SHA="${source_sha}" \
  bash "${plan13}" > "${work}/stdout-13"
roster13="$(sed -n 's/^roster=//p' "${work}/output-13")"
arms13="$(sed -n 's/^arms=//p' "${work}/output-13")"
[[ "${arms13}" == "${expected13}" ]] || { echo 'live roster fixture: full plan did not select exact new13' >&2; exit 1; }
jq -e --argjson expected "${expected13}" '
  .pgtls.suites == ["taurine-db-postgres live_tls", "taurine-db-conformance dbx_pg_tls_live dbx_tls_", "taurine-db-conformance dbx_pg_mtls_live dbx_pg_mtls_"] and
  .pgtls.cargo_features == ["taurine-db-dbx/dbx-pg", "taurine-db-dbx/legacy-tls"] and
  ."tls-legacy".report == false and
  ."tls-legacy".suites == ["taurine-db-conformance dbx_pg_tls_live legacy"] and
  ."tls-legacy".cargo_features == ["taurine-db-dbx/legacy-tls"] and
  (keys | sort) == ($expected | sort)
' <<< "${roster13}" >/dev/null || {
  echo 'live roster fixture: new13 roster changed its exact targets/features or complete membership' >&2; exit 1;
}

echo 'live roster: active plan is exact old12 or new13; exact new13 selection and legacy contract; invalid JSON rejected'
