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

# Apply one Ruby edit to the raw text of a workflow (bound as `t`; the edit evaluates to the new text).
mutate_text() {
  local file="$1" edit="$2"
  ruby -e '
    path = ARGV.fetch(0)
    t = File.binread(path).force_encoding("UTF-8")
    t = eval(ARGV.fetch(1))
    File.binwrite(path, t)
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

reject_text() {
  local label="$1" file="$2" expected="$3" edit="$4"
  reset_fixture
  mutate_text "${file}" "${edit}"
  expect_policy_rejects "${label}" "${expected}"
}

# The real tree, and a parse-and-dump round trip of it, pass.
reset_fixture
ruby .github/policy/check-live-proof-fanout.rb "${work}/tree" >/dev/null
mutate "${dispatcher}" ''
mutate "${arm}" ''
ruby .github/policy/check-live-proof-fanout.rb "${work}/tree" >/dev/null

prove='d["jobs"]["prove"]'
# The reviewed explicit cache-mode none is accepted; any other grant is not.
reset_fixture
mutate "${dispatcher}" "${prove}[\"cache-mode\"] = \"none\""
ruby .github/policy/check-live-proof-fanout.rb "${work}/tree" >/dev/null
reject 'prove job granted cache-mode write' "${dispatcher}" 'jobs.prove differs from the reviewed fan-out in cache-mode' "${prove}[\"cache-mode\"] = \"write\""
reject 'prove job granted cache-mode read' "${dispatcher}" 'jobs.prove differs from the reviewed fan-out in cache-mode' "${prove}[\"cache-mode\"] = \"read\""
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
reject 'select step renamed (the tested step is no longer present)' "${dispatcher}" 'the select step must be named' "${select_step}[\"name\"] = \"Select the arms\""
reject 'select step skipped' "${dispatcher}" 'may not set if or continue-on-error' "${select_step}[\"if\"] = \"false\""
reject 'select step tolerated' "${dispatcher}" 'may not set if or continue-on-error' "${select_step}[\"continue-on-error\"] = true"
reject 'select step engine hard-coded' "${dispatcher}" 'select step env must be exactly' "${select_step}[\"env\"][\"REQUESTED_ENGINE\"] = \"doris\""
reject 'select step extra env' "${dispatcher}" 'select step env must be exactly' "${select_step}[\"env\"][\"GITHUB_RUN_ID\"] = \"0\""
reject 'select step shell changed' "${dispatcher}" 'shell: bash' "${select_step}[\"shell\"] = \"sh\""
reject 'select step id duplicated' "${dispatcher}" 'exactly one step with id select' "${plan}[\"steps\"] << Marshal.load(Marshal.dump(${select_step})).merge(\"name\" => \"Decoy\")"

arm_prove='d["jobs"]["prove"]'
arm_step() { printf '%s["steps"].find { |s| s["name"] == "%s" }' "${arm_prove}" "$1"; }
validate="Validate protected call input"
build="Build the engine's proof test binary"
run="Run the engine's live proof"
differs() { printf 'step "%s" differs from the reviewed definition' "$1"; }
reject 'arm job skips pg-dbx' "${arm}" 'jobs.prove differs from the reviewed job in if' "${arm_prove}[\"if\"] += \" && inputs.engine != 'pg-dbx'\""
reject 'arm job tolerated' "${arm}" 'jobs.prove differs from the reviewed job in continue-on-error' "${arm_prove}[\"continue-on-error\"] = true"
reject 'arm job gets a matrix' "${arm}" 'jobs.prove differs from the reviewed job in strategy' "${arm_prove}[\"strategy\"] = {\"matrix\" => {\"x\" => [1]}}"
reject 'arm job gets an env override' "${arm}" 'jobs.prove differs from the reviewed job in env' "${arm_prove}[\"env\"] = {\"RUNNER_TEMP\" => \"/tmp/elsewhere\"}"
reject 'arm job timeout shortened' "${arm}" 'jobs.prove differs from the reviewed job in timeout-minutes' "${arm_prove}[\"timeout-minutes\"] = 1"
reject 'arm job defaults changed' "${arm}" 'jobs.prove differs from the reviewed job in defaults' "${arm_prove}[\"defaults\"][\"run\"][\"working-directory\"] = \"elsewhere\""
reject 'arm workflow env overrides RUNNER_TEMP' "${arm}" 'the workflow env must be exactly' 'd["env"]["RUNNER_TEMP"] = "/tmp/elsewhere"'
reject 'arm workflow gains a job' "${arm}" 'exactly one job, prove' 'd["jobs"]["extra"] = {"runs-on" => "ubuntu-24.04", "steps" => []}'

# Each pinned step: removed, duplicated, conditional, tolerated, and every way of emptying its body.
for name in "${validate}" "${build}" "${run}"; do
  reject "arm step removed: ${name}" "${arm}" "expected exactly one step named \"${name}\", found 0" "${arm_prove}[\"steps\"].reject! { |s| s[\"name\"] == \"${name}\" }"
  reject "arm step duplicated: ${name}" "${arm}" "expected exactly one step named \"${name}\", found 2" "${arm_prove}[\"steps\"] << Marshal.load(Marshal.dump($(arm_step "${name}")))"
  reject "arm step skipped: ${name}" "${arm}" "$(differs "${name}")" "$(arm_step "${name}")[\"if\"] = \"false\""
  reject "arm step skips pg-dbx: ${name}" "${arm}" "$(differs "${name}")" "$(arm_step "${name}")[\"if\"] = \"\${{ inputs.engine != 'pg-dbx' }}\""
  reject "arm step tolerated: ${name}" "${arm}" "$(differs "${name}")" "$(arm_step "${name}")[\"continue-on-error\"] = true"
  reject "arm step env override of RUNNER_TEMP: ${name}" "${arm}" "$(differs "${name}")" "$(arm_step "${name}")[\"env\"] = {\"RUNNER_TEMP\" => \"/tmp/elsewhere\"}"
  reject "arm step gains an id: ${name}" "${arm}" "$(differs "${name}")" "$(arm_step "${name}")[\"id\"] = \"x\""
  reject "arm step gains a working directory: ${name}" "${arm}" "$(differs "${name}")" "$(arm_step "${name}")[\"working-directory\"] = \"/tmp\""
done
for name in "${build}" "${run}"; do
  reject "arm step body replaced by true: ${name}" "${arm}" "$(differs "${name}")" "s = $(arm_step "${name}"); s.delete(\"uses\"); s[\"shell\"] = \"bash\"; s[\"run\"] = \"true\""
  reject "arm step action swapped: ${name}" "${arm}" "$(differs "${name}")" "$(arm_step "${name}")[\"uses\"] = \"./.github/actions/timings\""
  reject "arm step gains inputs: ${name}" "${arm}" "$(differs "${name}")" "$(arm_step "${name}")[\"with\"] = {\"x\" => \"1\"}"
done
reject 'arm validation replaced by true' "${arm}" "$(differs "${validate}")" "s = $(arm_step "${validate}"); s[\"run\"] = \"true\""
reject 'arm validation exits early for pg-dbx' "${arm}" "$(differs "${validate}")" "s = $(arm_step "${validate}"); s[\"run\"] = \"[[ \\\"\\\${REQUESTED_ENGINE}\\\" != pg-dbx ]] || exit 0\\n\" + s[\"run\"]"
reject 'arm validation input changed' "${arm}" "$(differs "${validate}")" "$(arm_step "${validate}")[\"env\"][\"ARM_CONFIG\"] = \"{}\""
reject 'arm validation shell changed' "${arm}" "$(differs "${validate}")" "$(arm_step "${validate}")[\"shell\"] = \"sh\""
reject 'arm validation action swapped in' "${arm}" "$(differs "${validate}")" "s = $(arm_step "${validate}"); s[\"uses\"] = \"./.github/actions/timings\""
reject 'arm steps out of order' "${arm}" 'must run in that order' "${arm_prove}[\"steps\"].insert(${arm_prove}[\"steps\"].index($(arm_step "${build}")), ${arm_prove}[\"steps\"].delete($(arm_step "${run}")))"

# C1: the plan job's own condition, which prove needs.
reject 'plan job skipped' "${dispatcher}" 'jobs.plan.if must be exactly the protected-ref condition' "${plan}[\"if\"] = \"false\""
reject 'plan job drops pg-dbx dispatches' "${dispatcher}" 'jobs.plan.if must be exactly the protected-ref condition' "${plan}[\"if\"] += \" && !contains(inputs.engine, 'pg-dbx')\""
reject 'plan job condition removed' "${dispatcher}" 'jobs.plan.if must be exactly the protected-ref condition' "${plan}.delete(\"if\")"
reject 'plan job gains a strategy' "${dispatcher}" 'jobs.plan may only set' "${plan}[\"strategy\"] = {\"matrix\" => {\"x\" => [1]}}"
reject 'plan job gains an env' "${dispatcher}" 'jobs.plan may only set' "${plan}[\"env\"] = {\"BASH_ENV\" => \"/tmp/x\"}"
reject 'plan roster output is a literal' "${dispatcher}" 'jobs.plan.outputs' "${plan}[\"outputs\"][\"roster\"] = '[]'"
reject 'plan roster output from another step' "${dispatcher}" 'jobs.plan.outputs' "${plan}[\"outputs\"][\"roster\"] = \"\${{ steps.pick.outputs.roster }}\""
reject 'plan gains an output' "${dispatcher}" 'jobs.plan.outputs' "${plan}[\"outputs\"][\"extra\"] = \"1\""

# F5: ambiguous YAML is refused, not read as its last key.
reject_text 'duplicate prove job key' "${dispatcher}" 'repeats a YAML mapping key' 't.sub(/^  prove:\n/, "  prove:\n    if: false\n  prove:\n")'
reject_text 'duplicate matrix key' "${dispatcher}" 'repeats a YAML mapping key' 't.sub(/^    strategy:\n/, "    strategy:\n      matrix:\n        arm: [doris]\n    strategy:\n")'
reject_text 'duplicate uses key on the run step' "${arm}" 'repeats a YAML mapping key' 't.sub(/^(        uses: \.\/\.github\/actions\/live-run).*\n/) { "#{$1}\n        uses: .\/.github\/actions\/timings\n" }'
reject_text 'yaml anchor' "${dispatcher}" 'uses a YAML anchor' 't.sub(/^  prove:\n/, "  prove: &p\n")'

# F6: a workflow file that is missing, a symlink, the wrong type, too large, not UTF-8, not YAML or
# not a mapping is refused with its cause, and never followed.
reset_fixture
rm "${work}/tree/${dispatcher}"
expect_policy_rejects 'missing dispatcher' "${dispatcher}: workflow YAML is missing"
reset_fixture
printf 'jobs: [\n' > "${work}/tree/${arm}"
expect_policy_rejects 'unparsable arm workflow' "${arm}: workflow YAML is not valid YAML"
reset_fixture
mv "${work}/tree/${dispatcher}" "${work}/real-dispatcher.yml"
ln -s "${work}/real-dispatcher.yml" "${work}/tree/${dispatcher}"
expect_policy_rejects 'symlinked dispatcher' "${dispatcher}: workflow YAML is a symlink"
reset_fixture
rm "${work}/tree/${arm}"
mkdir "${work}/tree/${arm}"
expect_policy_rejects 'directory instead of arm workflow' "${arm}: workflow YAML is not a regular file"
reset_fixture
ruby -e 'File.write(ARGV[0], "# " + "x" * 600_000 + "\n")' "${work}/tree/${arm}"
expect_policy_rejects 'oversized arm workflow' "${arm}: workflow YAML is too large"
reset_fixture
printf 'jobs: {}\n# \377\n' > "${work}/tree/${dispatcher}"
expect_policy_rejects 'non-UTF-8 dispatcher' "${dispatcher}: workflow YAML is not valid UTF-8"
reset_fixture
printf -- '- a\n- b\n' > "${work}/tree/${arm}"
expect_policy_rejects 'list instead of a mapping' "${arm}: workflow YAML is not a YAML mapping"

echo 'live-proof fan-out fixtures: every arm-dropping mutation is rejected'
