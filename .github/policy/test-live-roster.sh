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
  (keys | sort) == (["doris", "starrocks", "db2", "informix", "rocketmq", "iris", "postgres", "pg-dbx", "mysql", "mssql", "pgtls", "bastion"] | sort) and
  (."pg-dbx".suites == ["taurine-db-conformance dbx_pg_live,dbx_shadow_pg"]) and
  (all(.[]; (.engine | type) == "string" and (.report | type) == "boolean" and (.blurb | type) == "string"))
' <<< "${roster}" >/dev/null
jq -e --argjson selected "${arms}" '
  $selected == ["doris", "starrocks", "db2", "informix", "rocketmq", "iris", "postgres", "pg-dbx", "mysql", "mssql", "pgtls", "bastion"]
' <<< "${roster}" >/dev/null
contract_arms="$(jq -c '.dispatch_contracts.workflows[".github/workflows/live-proofs.yml"].inputs.engine.options' .github/ci-matrix.json)"
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

echo 'live roster: extracted plan script parses all 12 arms and rejects invalid JSON'
