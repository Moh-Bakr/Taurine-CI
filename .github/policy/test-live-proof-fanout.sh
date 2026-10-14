#!/usr/bin/env bash
# Prove the live-proof fan-out check rejects every way of dropping an arm after the roster.
set -euo pipefail

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/live-proof-fanout-test.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
dispatcher=.github/workflows/live-proofs.yml
arm=.github/workflows/live-proof-arm.yml

reset_fixture() {
  rm -rf "${work}/tree"
  mkdir -p "${work}/tree/.github"
  cp -R .github/workflows "${work}/tree/.github/workflows"
}

# Apply one Ruby edit to the parsed workflow (bound as `d`) and write it back.
mutate() {
  local file="$1" edit="$2"
  ruby -ryaml -e '
    path = ARGV.fetch(0)
    d = YAML.safe_load_file(path, aliases: false)
    eval(ARGV.fetch(1))
    File.write(path, YAML.dump(d))
  ' "${work}/tree/${file}" "${edit}"
}

expect_policy_rejects() {
  local label="$1" expected="$2" output status
  set +e
  output="$(ruby .github/policy/check-live-proof-fanout.rb "${work}/tree" 2>&1)"
  status=$?
  set -e
  [[ "${status}" -ne 0 ]] || { echo "${label}: weakened fixture passed the live-proof fan-out policy" >&2; exit 1; }
  [[ "${output}" == *"${expected}"* ]] || { echo "${label}: rejected for the wrong reason: ${output}" >&2; exit 1; }
}

reject() {
  local label="$1" file="$2" expected="$3" edit="$4"
  reset_fixture
  mutate "${file}" "${edit}"
  expect_policy_rejects "${label}" "${expected}"
}

# The real tree, and a parse-and-dump round trip of it, pass.
reset_fixture
ruby .github/policy/check-live-proof-fanout.rb "${work}/tree" >/dev/null
mutate "${dispatcher}" ''
mutate "${arm}" ''
ruby .github/policy/check-live-proof-fanout.rb "${work}/tree" >/dev/null

prove='d["jobs"]["prove"]'
matrix="${prove}[\"strategy\"][\"matrix\"]"
reject 'prove matrix excludes pg-dbx' "${dispatcher}" 'jobs.prove differs' "${matrix}[\"exclude\"] = [{\"arm\" => \"pg-dbx\"}]"
reject 'prove matrix includes an extra arm' "${dispatcher}" 'jobs.prove differs' "${matrix}[\"include\"] = [{\"arm\" => \"extra\"}]"
reject 'prove matrix from a literal list' "${dispatcher}" 'jobs.prove differs' "${matrix}[\"arm\"] = \"\${{ fromJSON('[\\\"doris\\\"]') }}\""
reject 'prove matrix with a second axis' "${dispatcher}" 'jobs.prove differs' "${matrix}[\"shard\"] = [1]"
reject 'prove fail-fast' "${dispatcher}" 'reviewed fan-out in strategy' "${prove}[\"strategy\"][\"fail-fast\"] = true"
reject 'prove job condition weakened' "${dispatcher}" 'reviewed fan-out in if' "${prove}[\"if\"] = \"always()\""
reject 'prove job condition skips an arm' "${dispatcher}" 'reviewed fan-out in if' "${prove}[\"if\"] += \" && inputs.engine != 'pg-dbx'\""
reject 'prove engine pinned' "${dispatcher}" 'reviewed fan-out in with' "${prove}[\"with\"][\"engine\"] = \"doris\""
reject 'prove config swapped' "${dispatcher}" 'reviewed fan-out in with' "${prove}[\"with\"][\"config\"] = \"\${{ needs.plan.outputs.roster }}\""
reject 'prove tolerated' "${dispatcher}" 'reviewed fan-out in continue-on-error' "${prove}[\"continue-on-error\"] = true"
reject 'prove calls another workflow' "${dispatcher}" 'reviewed fan-out in uses' "${prove}[\"uses\"] = \"./.github/workflows/other.yml\""
reject 'prove job removed' "${dispatcher}" 'jobs.prove differs' 'd["jobs"].delete("prove")'

plan='d["jobs"]["plan"]'
select_step="${plan}[\"steps\"].find { |s| s[\"id\"] == \"select\" }"
reject 'plan arms output is a literal' "${dispatcher}" 'jobs.plan.outputs' "${plan}[\"outputs\"][\"arms\"] = '[\"doris\"]'"
reject 'plan outputs from another step' "${dispatcher}" 'jobs.plan.outputs' "${plan}[\"outputs\"][\"arms\"] = \"\${{ steps.pick.outputs.arms }}\""
reject 'plan tolerated' "${dispatcher}" 'jobs.plan may not set continue-on-error' "${plan}[\"continue-on-error\"] = true"
reject 'select step renamed (a decoy keeps the tested name)' "${dispatcher}" 'the select step must be named' "${select_step}[\"name\"] = \"Select the arms\""
reject 'select step skipped' "${dispatcher}" 'may not set if or continue-on-error' "${select_step}[\"if\"] = \"false\""
reject 'select step tolerated' "${dispatcher}" 'may not set if or continue-on-error' "${select_step}[\"continue-on-error\"] = true"
reject 'select step engine hard-coded' "${dispatcher}" 'select step env must be exactly' "${select_step}[\"env\"][\"REQUESTED_ENGINE\"] = \"doris\""
reject 'select step extra env' "${dispatcher}" 'select step env must be exactly' "${select_step}[\"env\"][\"GITHUB_RUN_ID\"] = \"0\""
reject 'select step shell changed' "${dispatcher}" 'shell: bash' "${select_step}[\"shell\"] = \"sh\""
reject 'select step id duplicated' "${dispatcher}" 'exactly one step with id select' "${plan}[\"steps\"] << Marshal.load(Marshal.dump(${select_step})).merge(\"name\" => \"Decoy\")"

arm_prove='d["jobs"]["prove"]'
arm_step() { printf '%s["steps"].find { |s| s["name"] == "%s" }' "${arm_prove}" "$1"; }
reject 'arm job skips pg-dbx' "${arm}" 'protected-ref condition' "${arm_prove}[\"if\"] += \" && inputs.engine != 'pg-dbx'\""
reject 'arm job tolerated' "${arm}" 'may not set continue-on-error' "${arm_prove}[\"continue-on-error\"] = true"
reject 'arm job gets a matrix' "${arm}" 'may not set strategy' "${arm_prove}[\"strategy\"] = {\"matrix\" => {\"x\" => [1]}}"
reject 'arm workflow gains a job' "${arm}" 'exactly one job, prove' 'd["jobs"]["extra"] = {"runs-on" => "ubuntu-24.04", "steps" => []}'
reject 'arm run step skips pg-dbx' "${arm}" "Run the engine's live proof" "$(arm_step "Run the engine's live proof")[\"if\"] = \"\${{ inputs.engine != 'pg-dbx' }}\""
reject 'arm run step tolerated' "${arm}" "Run the engine's live proof" "$(arm_step "Run the engine's live proof")[\"continue-on-error\"] = true"
reject 'arm build step skipped' "${arm}" "Build the engine's proof test binary" "$(arm_step "Build the engine's proof test binary")[\"if\"] = \"false\""
reject 'arm input validation skipped' "${arm}" 'Validate protected call input' "$(arm_step 'Validate protected call input')[\"if\"] = \"false\""
reject 'arm run step removed' "${arm}" "expected exactly one step named \"Run the engine's live proof\"" "${arm_prove}[\"steps\"].reject! { |s| s[\"name\"] == \"Run the engine's live proof\" }"
reject 'arm run step duplicated' "${arm}" "expected exactly one step named \"Run the engine's live proof\"" "${arm_prove}[\"steps\"] << Marshal.load(Marshal.dump($(arm_step "Run the engine's live proof")))"

# Missing or unparsable workflows fail closed.
reset_fixture
rm "${work}/tree/${dispatcher}"
expect_policy_rejects 'missing dispatcher' "${dispatcher}: workflow YAML is missing or invalid"
reset_fixture
printf 'jobs: [\n' > "${work}/tree/${arm}"
expect_policy_rejects 'unparsable arm workflow' "${arm}: workflow YAML is missing or invalid"

echo 'live-proof fan-out fixtures: every arm-dropping mutation is rejected'
