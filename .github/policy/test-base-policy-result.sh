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
[[ "$(yaml "${entry}" 'doc["jobs"]["policy"]["needs"].inspect')" == '["base-pass"]' ]] \
  || fail 'the policy job does not need exactly the base-policy call'
[[ "$(yaml "${entry}" 'doc["jobs"]["policy"]["if"]')" == '${{ always() }}' ]] \
  || fail 'the policy job does not always run, so a failed base pass could skip it'
[[ "$(yaml "${reusable}" 'doc["jobs"]["base-policy-result"]["needs"].inspect')" == '["base-policy-fixtures", "base-policy"]' ]] \
  || fail 'the result job does not need both base-policy jobs'
[[ "$(yaml "${reusable}" 'doc["jobs"]["base-policy-result"]["if"]')" == '${{ always() }}' ]] \
  || fail 'the result job does not always run'
[[ "$(yaml "${reusable}" 'doc["jobs"]["base-policy"]["if"]')" == "github.event_name == 'pull_request'" ]] \
  || fail 'the base-policy job is not restricted to a pull request'

echo 'base-policy result: the guards pass only on success, and the policy job needs the call that needs both jobs'
