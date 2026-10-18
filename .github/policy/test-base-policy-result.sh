#!/usr/bin/env bash
# The base-policy pass stays on the required status check after it moved to its own workflow: the
# entrypoint's `policy` job needs the call, the call is to the reusable workflow, and the guards
# that decide whether the pass counts keep their rules. Run from the repository root.
#
# Guards, as a pass or a fail by result: fixtures must have passed on every event, the base-policy
# job on a pull request, and the entrypoint requires the whole workflow to have passed. A job that
# was skipped, cancelled or failed is not a job that passed.
set -euo pipefail

entry="${1:-.github/workflows/validate-public-changes.yml}"
reusable="${2:-.github/workflows/base-policy.yml}"
tmp="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/base-policy-result-test.XXXXXX")"
trap 'rm -rf -- "${tmp}"' EXIT

fail() { echo "base-policy result: $*" >&2; exit 1; }

# yaml FILE RUBY-EXPR: evaluate an expression on the parsed workflow and print it.
yaml() { ruby -ryaml -e 'doc = YAML.safe_load(File.read(ARGV[0]), aliases: false); print(eval(ARGV[1]))' "$1" "$2"; }

# step_script FILE JOB STEP: the run script of one named step of one job.
step_script() {
  ruby -ryaml -e '
    doc = YAML.safe_load(File.read(ARGV[0]), aliases: false)
    found = doc.fetch("jobs").fetch(ARGV[1]).fetch("steps").select { |s| s["name"] == ARGV[2] }
    abort "#{ARGV[0]}: expected one step #{ARGV[2].inspect} in #{ARGV[1]}, found #{found.length}" unless found.length == 1
    print found.first.fetch("run")
  ' "$1" "$2" "$3"
}

# run_guard SCRIPT VAR RESULT: run the guard's script with the one result it reads.
run_guard() { env "$2=$3" bash -c "$1" > "${tmp}/out" 2>&1; }

# expect_guard SCRIPT VAR LABEL: success passes; failure, skipped, cancelled and empty each fail.
expect_guard() {
  local script="$1" var="$2" label="$3" result
  run_guard "${script}" "${var}" success || { cat "${tmp}/out" >&2; fail "${label}: a success was refused"; }
  for result in failure skipped cancelled ''; do
    if run_guard "${script}" "${var}" "${result}"; then fail "${label}: the result '${result}' was accepted"; fi
  done
}

fixtures_guard="$(step_script "${reusable}" base-policy-result 'Require the base-policy fixtures job to have passed')"
base_guard="$(step_script "${reusable}" base-policy-result 'Require the base-policy job to have passed')"
entry_guard="$(step_script "${entry}" policy 'Require the base-policy workflow to have passed')"
expect_guard "${fixtures_guard}" FIXTURES_RESULT 'the fixtures guard'
expect_guard "${base_guard}" BASE_RESULT 'the base-policy guard'
expect_guard "${entry_guard}" BASE_PASS_RESULT 'the entrypoint guard'

# Two reviewed layouts of the entrypoint (transitional, see check-strict-structure.rb): the one `policy`
# job, or the thin aggregate `policy` beside four shard jobs that run this pull request's own checks. In
# the aggregate layout one more guard reads all four shard results, and each must be the only thing
# standing between a non-success result and a pass.
shards=(policy-evidence policy-fixtures policy-mutations policy-structure)
sharded="$(yaml "${entry}" 'doc["jobs"].keys.any? { |k| %w[policy-evidence policy-fixtures policy-mutations policy-structure].include?(k) }')"
if [[ "${sharded}" == true ]]; then
  shards_guard="$(step_script "${entry}" policy 'Require every policy check shard to have passed')"
  vars=(POLICY_EVIDENCE_RESULT POLICY_FIXTURES_RESULT POLICY_MUTATIONS_RESULT POLICY_STRUCTURE_RESULT)
  all_ok() { env "${vars[0]}=success" "${vars[1]}=success" "${vars[2]}=success" "${vars[3]}=success" bash -c "${shards_guard}" > "${tmp}/out" 2>&1; }
  all_ok || { cat "${tmp}/out" >&2; fail 'the shards guard refused four successes'; }
  for v in "${vars[@]}"; do
    for result in failure skipped cancelled ''; do
      args=(); for w in "${vars[@]}"; do if [[ "${w}" == "${v}" ]]; then args+=("${w}=${result}"); else args+=("${w}=success"); fi; done
      if env "${args[@]}" bash -c "${shards_guard}" > "${tmp}/out" 2>&1; then fail "the shards guard accepted ${v}='${result}'"; fi
    done
  done
fi

# The conditions that decide when each guard runs are expressions, so they are compared as text.
# Arrays, not a hash: Hash#inspect prints differently across Ruby versions, and the runner's is not mine.
[[ "$(yaml "${reusable}" 'doc["jobs"]["base-policy-result"]["steps"].map { |s| [s["name"], s["if"]] }.inspect')" \
  == '[["Require the base-policy fixtures job to have passed", "${{ always() }}"], ["Require the base-policy job to have passed", "${{ always() && github.event_name == '"'"'pull_request'"'"' }}"]]' ]] \
  || fail 'the guards no longer run when they should: fixtures on every event, base-policy on a pull request'
[[ "$(yaml "${entry}" 'doc["jobs"]["policy"]["steps"].find { |s| s["name"] == "Require the base-policy workflow to have passed" }["if"]')" == '${{ always() }}' ]] \
  || fail 'the entrypoint guard does not always run'

# The chain that keeps the base pass on the required check.
[[ "$(yaml "${entry}" 'doc["jobs"]["base-pass"]["uses"]')" == ./.github/workflows/base-policy.yml ]] \
  || fail 'the entrypoint does not call the reusable base-policy workflow'
# The aggregate layout needs the base-policy call and all four shards, and nothing else; the single-job
# layout needs the base-policy call alone.
if [[ "${sharded}" == true ]]; then
  [[ "$(yaml "${entry}" 'doc["jobs"]["policy"]["needs"].inspect')" == '["base-pass", "policy-evidence", "policy-fixtures", "policy-mutations", "policy-structure"]' ]] \
    || fail 'the policy aggregate does not need exactly the base-policy call and the four policy shards'
else
  [[ "$(yaml "${entry}" 'doc["jobs"]["policy"]["needs"].inspect')" == '["base-pass"]' ]] \
    || fail 'the policy job does not need exactly the base-policy call'
fi
[[ "$(yaml "${entry}" 'doc["jobs"]["policy"]["if"]')" == '${{ always() }}' ]] \
  || fail 'the policy job does not always run, so a failed base pass could skip it'
# The guard is the policy job's FIRST step: before the checkout and before any step that runs this
# pull request's scripts, which can export BASH_ENV, PATH or RUBYOPT through GITHUB_ENV and
# GITHUB_PATH and so change how a later step behaves, the guard included.
[[ "$(yaml "${entry}" 'doc["jobs"]["policy"]["steps"].first["name"]')" == 'Require the base-policy workflow to have passed' ]] \
  || fail 'the entrypoint guard is not the first step of the policy job'
# The guard step carries only these keys, with this shell and this env: `shell: true {0}` would run the
# script as an argument to `true`, and an env of BASE_PASS_RESULT: success would read a constant, either
# way the guard passes whatever the base pass did.
[[ "$(yaml "${entry}" 'doc["jobs"]["policy"]["steps"].first.keys.sort.inspect')" == '["env", "if", "name", "run", "shell"]' ]] \
  || fail 'the entrypoint guard step has keys other than name, if, shell, env and run'
[[ "$(yaml "${entry}" 'doc["jobs"]["policy"]["steps"].first["shell"]')" == bash ]] \
  || fail 'the entrypoint guard step does not use exactly shell: bash'
[[ "$(yaml "${entry}" 'doc["jobs"]["policy"]["steps"].first["env"].to_a.inspect')" == '[["BASE_PASS_RESULT", "${{ needs.base-pass.result }}"]]' ]] \
  || fail 'the entrypoint guard step env is not exactly BASE_PASS_RESULT: needs.base-pass.result'
# The aggregate layout: `policy` holds exactly the two guards and no other step (no checkout, no script of
# this pull request, nothing that could export BASH_ENV, PATH or RUBYOPT); the shards guard reads exactly
# the four shard results; and each shard stands beside the base pass: it needs no job (a dependency on the
# base pass would put the two back in sequence), runs on the plain runner and holds its own checkout.
if [[ "${sharded}" == true ]]; then
  [[ "$(yaml "${entry}" 'doc["jobs"]["policy"]["steps"].map { |s| s["name"] }.inspect')" \
    == '["Require the base-policy workflow to have passed", "Require every policy check shard to have passed"]' ]] \
    || fail 'the policy aggregate holds a step other than its two guards, or they are renamed or reordered'
  [[ "$(yaml "${entry}" 'doc["jobs"]["policy"]["steps"][1].keys.sort.inspect')" == '["env", "if", "name", "run", "shell"]' ]] \
    || fail 'the shards guard step has keys other than name, if, shell, env and run'
  [[ "$(yaml "${entry}" 'doc["jobs"]["policy"]["steps"][1]["shell"]')" == bash ]] \
    || fail 'the shards guard step does not use exactly shell: bash'
  [[ "$(yaml "${entry}" 'doc["jobs"]["policy"]["steps"][1]["if"]')" == '${{ always() }}' ]] \
    || fail 'the shards guard step does not always run'
  [[ "$(yaml "${entry}" 'doc["jobs"]["policy"]["steps"][1]["env"].to_a.inspect')" \
    == '[["POLICY_EVIDENCE_RESULT", "${{ needs.policy-evidence.result }}"], ["POLICY_FIXTURES_RESULT", "${{ needs.policy-fixtures.result }}"], ["POLICY_MUTATIONS_RESULT", "${{ needs.policy-mutations.result }}"], ["POLICY_STRUCTURE_RESULT", "${{ needs.policy-structure.result }}"]]' ]] \
    || fail 'the shards guard step env is not exactly the four needs.<shard>.result values'
  for shard in "${shards[@]}"; do
    [[ "$(yaml "${entry}" "doc[\"jobs\"][\"${shard}\"].key?(\"needs\")")" == false ]] \
      || fail "${shard} needs another job, so it no longer runs beside the base pass"
    [[ "$(yaml "${entry}" "doc[\"jobs\"][\"${shard}\"][\"runs-on\"]")" == ubuntu-24.04 ]] \
      || fail "${shard} does not run on exactly ubuntu-24.04"
    [[ "$(yaml "${entry}" "doc[\"jobs\"][\"${shard}\"][\"steps\"].first[\"uses\"].to_s.start_with?(\"actions/checkout@\")")" == true ]] \
      || fail "${shard} does not start with its own checkout"
  done
fi
[[ "$(yaml "${reusable}" 'doc["jobs"]["base-policy-result"]["needs"].inspect')" == '["base-policy-fixtures", "base-policy"]' ]] \
  || fail 'the result job does not need both base-policy jobs'
[[ "$(yaml "${reusable}" 'doc["jobs"]["base-policy-result"]["if"]')" == '${{ always() }}' ]] \
  || fail 'the result job does not always run'
[[ "$(yaml "${reusable}" 'doc["jobs"]["base-policy"]["if"]')" == "github.event_name == 'pull_request'" ]] \
  || fail 'the base-policy job is not restricted to a pull request'

# The step text being in a file proves nothing about it RUNNING. The base pass must not be skippable
# and its failure must count: no job on the chain may be conditional, tolerate failure or wait on an
# environment, and no step of the two jobs that do the work may be conditional or tolerate failure.
# The guards' own `if` lines are compared above.
# unsafe_keys FILE JOB JOB-KEYS STEP-KEYS: the listed keys present on the job, or on any of its steps.
unsafe_keys() {
  ruby -ryaml -e '
    doc = YAML.safe_load(File.read(ARGV[0]), aliases: false)
    job = doc.fetch("jobs").fetch(ARGV[1]) { abort "#{ARGV[0]}: no job #{ARGV[1]}" }
    found = ARGV[2].split(",").select { |k| job.key?(k) }.map { |k| "job #{k}" }
    (job["steps"] || []).each { |st| ARGV[3].split(",").each { |k| found << "step #{st["name"].inspect} #{k}" if st.key?(k) } }
    print found.join("; ")
  ' "$@"
}
no_unsafe() {
  local got
  got="$(unsafe_keys "$@")"
  [[ -z "${got}" ]] || fail "the base pass could be skipped or its failure ignored (${2}: ${got})"
}
no_unsafe "${entry}" base-pass 'if,continue-on-error,environment,secrets' ''
# The guard's job runs on the plain hosted runner and in no container or service: a digest-pinned image can
# carry ENV BASH_ENV or RUBYOPT, or a ruby of its own, that changes how the guard behaves, and another
# runner label changes what runs it.
no_unsafe "${entry}" policy 'continue-on-error,environment,container,services' 'continue-on-error'
if [[ "${sharded}" == true ]]; then
  for shard in "${shards[@]}"; do
    no_unsafe "${entry}" "${shard}" 'if,continue-on-error,environment,container,services,env,defaults' 'if,continue-on-error'
  done
fi
[[ "$(yaml "${entry}" 'doc["jobs"]["policy"]["runs-on"]')" == ubuntu-24.04 ]] \
  || fail 'the policy job does not run on exactly ubuntu-24.04'
no_unsafe "${reusable}" base-policy 'continue-on-error,environment' 'if,continue-on-error'
no_unsafe "${reusable}" base-policy-fixtures 'if,continue-on-error,environment' 'if,continue-on-error'
no_unsafe "${reusable}" base-policy-result 'continue-on-error,environment' 'continue-on-error'
[[ "$(yaml "${reusable}" 'doc["jobs"]["base-policy"]["steps"].count { |s| s["name"] == "Run the base commit'"'"'s policy against this pull request" }')" == 1 ]] \
  || fail 'the base-policy job does not hold exactly one base-pass step'

echo 'base-policy result: the guards pass only on success, and the required check needs the call that needs both jobs (and, in the sharded layout, the four policy shards beside it)'
