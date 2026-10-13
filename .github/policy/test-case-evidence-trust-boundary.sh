#!/usr/bin/env bash
# Synthetic-only trust-boundary regression. No runner or producer is executed.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/case-evidence-trust.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
mkdir -p "${work}/source/taurine-desktop/tests/unit"
touch "${work}/source/taurine-desktop/tests/unit/synthetic.spec.ts"

# Mint a completely self-consistent but entirely forged pair of reports. Every
# producer claim and digest is controlled by this fixture, not a test runner.
ruby -rjson -rdigest -e '
  dir, repo = ARGV
  sha = ->(value) { Digest::SHA256.hexdigest(JSON.generate(value)) }
  runner, config, tier, platform = "vitest-desktop", "desktop-vitest-default", "default", "linux"
  suite_ids = ["desktop.vitest.default.api"]
  file = File.join(repo, "taurine-desktop/tests/unit/synthetic.spec.ts")
  title = "FORGED PRIVATE TITLE SENTINEL"
  report = [{"file" => file, "name" => title}]
  execution_report = {"numTotalTests" => 1, "numPassedTests" => 1, "numFailedTests" => 0,
    "numPendingTests" => 0, "testResults" => [{"name" => file, "assertionResults" =>
      [{"ancestorTitles" => [], "title" => title, "status" => "passed"}]}]}
  identity = [runner, config, tier, platform, "", "taurine-desktop/tests/unit/synthetic.spec.ts", "", "", title]
  case_id = sha.call(identity)
  common = {"schema_version" => 1, "source_sha" => "a" * 40, "control_sha" => "b" * 40,
    "manifest_digest" => "c" * 64, "catalog_digest" => "d" * 64, "selection_digest" => sha.call(suite_ids),
    "collection_complete" => true, "runner_id" => runner, "config_id" => config, "tier" => tier,
    "platform" => platform, "producer_version" => "case-evidence-producer/1", "tool_version" => "3.2.1",
    "producer_status" => "complete"}
  discovery = common.merge("phase" => "discovery", "command_id" => "vitest.desktop.list.v1", "report" => report)
  discovery["collection_digest"] = sha.call(report)
  execution = common.merge("phase" => "execution", "command_id" => "vitest.desktop.run.v1",
    "report" => execution_report, "selected_suite_ids" => suite_ids, "discovered_case_ids" => [case_id])
  execution["collection_digest"] = sha.call(execution_report)
  expected = {"schema_version" => 1, "source_sha" => common["source_sha"], "control_sha" => common["control_sha"],
    "manifest_digest" => common["manifest_digest"], "catalog_digest" => common["catalog_digest"],
    "selection_digest" => common["selection_digest"], "selection_mode" => "full", "selected_suite_ids" => suite_ids,
    "runner_id" => runner, "config_id" => config, "tier" => tier, "platform" => platform, "project" => nil,
    "tool_version" => "3.2.1", "repo_root" => repo}
  {"expected.json" => expected, "discovery.json" => discovery, "execution.json" => execution}.each do |name, value|
    File.write(File.join(dir, name), JSON.generate(value))
  end
' "${work}" "${work}/source"

run_contract() {
  ruby "${root}/.github/policy/case-evidence-contract.rb" \
    "${work}/expected.json" "${work}/discovery.json" "${work}/execution.json"
}

assert_unverified() {
  local output="$1"
  jq -e '.status == "shadow_valid_unverified_producer" and .counts == {"discovered":1,"executed":1,"passed":1,"failed":0,"flaky":0,"skipped":0,"ignored":0,"quarantined":0,"env_skipped":0}' <<<"${output}" >/dev/null
  ! grep -Eq 'FORGED PRIVATE TITLE SENTINEL|synthetic\.spec\.ts|[a-f0-9]{64}' <<<"${output}" || {
    echo 'trust boundary emitted private title, path, or digest' >&2; exit 1;
  }
  jq -e 'has("admitted") == false and has("producer_trusted") == false and has("pass") == false and has("full") == false' <<<"${output}" >/dev/null
}

forged="$(run_contract)"
assert_unverified "${forged}"

# Even after recomputing the execution digest and ID list, an extra execution
# case cannot be reconciled against the independently supplied discovery set.
ruby -rjson -rdigest -e '
  path = ARGV.fetch(0); value = JSON.parse(File.read(path)); report = value.fetch("report")
  report["testResults"][0]["assertionResults"] << {"ancestorTitles" => [], "title" => "EXTRA FORGED CASE", "status" => "passed"}
  report["numTotalTests"] = 2; report["numPassedTests"] = 2
  id = Digest::SHA256.hexdigest(JSON.generate(["vitest-desktop", "desktop-vitest-default", "default", "linux", "", "taurine-desktop/tests/unit/synthetic.spec.ts", "", "", "EXTRA FORGED CASE"]))
  value["discovered_case_ids"] << id
  value["collection_digest"] = Digest::SHA256.hexdigest(JSON.generate(report))
  File.write(path, JSON.generate(value))
' "${work}/execution.json"
set +e
extra="$(run_contract)"; extra_status=$?
set -e
[[ "${extra_status}" -ne 0 ]] || { echo 'extra forged execution case was accepted' >&2; exit 1; }
jq -e '.status == "shadow_blocked" and .error_class == "discovery_execution_mismatch"' <<<"${extra}" >/dev/null
! grep -Eq 'EXTRA FORGED CASE|FORGED PRIVATE TITLE SENTINEL|synthetic\.spec\.ts|[a-f0-9]{64}' <<<"${extra}" || {
  echo 'blocked result emitted private identity data' >&2; exit 1;
}

echo 'trust boundary: self-consistent forged claims remain unverified; extra execution case blocks'
