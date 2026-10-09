#!/usr/bin/env bash
# Synthetic-only checks for the trusted suite-evidence collector: discovery,
# ownership matching, compiled/executed/skipped accounting and sanitised output.
set -euo pipefail

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/suite-collector-test.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
matrix="$(pwd)/.github/ci-matrix.json"
repo_root="${work}/src"
report="${work}/report.json"
raw="${work}/raw-proof.json"
projection="${work}/projection.json"
source_sha=1111111111111111111111111111111111111111
control_sha=2222222222222222222222222222222222222222
selection_digest="$(printf '5%.0s' $(seq 64))"

# A synthetic private ownership manifest for the reviewed desktop suites: each
# feature suite owns its feature tree, integration owns the integration tree.
# Patterns are the reviewed contract; the manifest itself never leaves the
# synthetic repo root.
write_manifest() {
  mkdir -p "${repo_root}/scripts/ci"
  ruby -rjson -e '
    matrix = JSON.parse(File.read(ARGV.fetch(0)))
    group = matrix["suite_catalog"]["coverage_requirements"].find { |row| row["id"] == "desktop-vitest-default-linux" }
    manifest = { "schema_version" => 1, "suites" => {} }
    group["candidate_suite_ids"].each do |id|
      feature = id.split(".").last
      manifest["suites"][id] = { "include" => ["taurine-desktop/src/features/#{feature}/**"] }
    end
    pw = matrix["suite_catalog"]["coverage_requirements"].find { |row| row["id"] == "desktop-playwright-feedback-linux" }
    pw["candidate_suite_ids"].each do |id|
      feature = id.split(".").last
      manifest["suites"][id] = { "include" => ["taurine-desktop/tests/e2e/#{feature}/**"] }
    end
    File.write(ARGV.fetch(1), JSON.generate(manifest))
  ' "${matrix}" "${repo_root}/scripts/ci/suite-ownership.json"
}

manifest_digest() {
  ruby -rdigest -rjson -e '
    sort = lambda { |v| v.is_a?(Hash) ? v.keys.sort.to_h { |k| [k, sort.call(v.fetch(k))] } : v.is_a?(Array) ? v.map { |x| sort.call(x) } : v }
    puts Digest::SHA256.hexdigest(JSON.generate(sort.call(JSON.parse(File.read(ARGV.fetch(0)))), ascii_only: true))
  ' "${repo_root}/scripts/ci/suite-ownership.json"
}

group_ids() {
  jq -c --arg id "$1" '.suite_catalog.coverage_requirements[] | select(.id==$id) | .candidate_suite_ids' "${matrix}"
}

run_collector() {
  local concern="$1"
  env \
    "CI_EXPECTED_SOURCE_SHA=${source_sha}" \
    "CI_EXPECTED_CONTROL_SHA=${control_sha}" \
    "CI_EXPECTED_MANIFEST_DIGEST=${expected_manifest_digest}" \
    "CI_EXPECTED_CATALOG_DIGEST=${catalog_digest}" \
    "CI_EXPECTED_SELECTION_DIGEST=${selection_digest}" \
    "CI_EXPECTED_SELECTION_MODE=${expected_mode:-full}" \
    "CI_EXPECTED_SELECTED_SUITE_IDS=${expected_selected_ids}" \
    "CI_PLATFORM=linux" \
    "CI_MATRIX_PATH=${matrix}" \
    ruby .github/policy/collect-suite-evidence.rb "${concern}" "${repo_root}" "${report}" "${raw}" "${projection}"
}

expect_reject() {
  local label="$1" output status
  set +e
  output="$(run_collector "$2" 2>&1)"
  status=$?
  set -e
  [[ "${status}" -ne 0 && "${output}" == *"suite evidence: rejected"* && "${output}" != *SYNTHETIC-PRIVATE* ]] || {
    echo "${label}: collector accepted invalid evidence or echoed unreviewed content" >&2
    exit 1
  }
}

catalog_digest="$(ruby -rdigest -rjson -e '
  sort = lambda { |v| v.is_a?(Hash) ? v.keys.sort.to_h { |k| [k, sort.call(v.fetch(k))] } : v.is_a?(Array) ? v.map { |x| sort.call(x) } : v }
  catalog = JSON.parse(File.read(ARGV.fetch(0))).fetch("suite_catalog")
  puts Digest::SHA256.hexdigest(JSON.generate(sort.call(catalog), ascii_only: true))
' "${matrix}")"
write_manifest
expected_manifest_digest="$(manifest_digest)"
expected_mode=full
expected_selected_ids="$(group_ids desktop-vitest-default-linux)"

# A clean full pass over two feature suites: counts derived from the runner's
# own report, every other candidate honestly absent.
mkdir -p "${repo_root}/taurine-desktop/src/features/rest" "${repo_root}/taurine-desktop/src/features/notes"
echo 'SYNTHETIC-PRIVATE-DO-NOT-ECHO' > "${repo_root}/taurine-desktop/src/features/rest/source.ts"
ruby -rjson -e '
  root = ARGV.fetch(1)
  entries = lambda { |file, statuses|
    { "name" => "#{root}/taurine-desktop/#{file}", "status" => statuses.values.all? { |s| s == "passed" } ? "passed" : "failed",
      "assertionResults" => statuses.map { |title, status| { "title" => title, "fullName" => "SYNTHETIC-PRIVATE-DO-NOT-ECHO #{title}", "status" => status } } }
  }
  report = {
    "numTotalTests" => 4, "numPassedTests" => 4, "numFailedTests" => 0,
    "testResults" => [
      entries.call("src/features/rest/api.test.ts", { "creates a request" => "passed", "sends headers" => "passed" }),
      entries.call("src/features/notes/editor.test.ts", { "opens a note" => "passed", "saves a note" => "passed" })
    ]
  }
  File.write(ARGV.fetch(0), JSON.generate(report))
' "${report}" "${repo_root}"
run_collector desktop-shard-1 >/dev/null
jq -e --arg sha "${source_sha}" --arg digest "${expected_manifest_digest}" '
  .source_sha == $sha and .status == "passed" and .selection_mode == "full" and
  .manifest_digest == $digest and
  ([.suites[] | select(.status == "passed") | .executed_count] | all(. == 2)) and
  ([.suites[] | select(.status == "absent") | .id] | length == 16)' "${projection}" >/dev/null
# No private content may cross the projection boundary.
! grep -q 'SYNTHETIC-PRIVATE\|source\.ts\|api\.test\.ts' "${projection}" || {
  echo 'collector projection leaked private content' >&2
  exit 1
}
# The collection digest is re-derivable from the projection itself.
ruby -rdigest -rjson -e '
  sort = lambda { |v| v.is_a?(Hash) ? v.keys.sort.to_h { |k| [k, sort.call(v.fetch(k))] } : v.is_a?(Array) ? v.map { |x| sort.call(x) } : v }
  projection = JSON.parse(File.read(ARGV.fetch(0)))
  collection = { "coverage_requirement_id" => projection.fetch("coverage_requirement_id"), "platform" => projection.fetch("platform"), "suites" => projection.fetch("suites") }
  abort "collection digest not re-derivable" unless Digest::SHA256.hexdigest(JSON.generate(sort.call(collection), ascii_only: true)) == projection.fetch("collection_digest")
' "${projection}"

# A failed case marks its suite failed and the group failed.
ruby -rjson -e '
  d=JSON.parse(File.read(ARGV.fetch(0)))
  d["numPassedTests"]=3; d["numFailedTests"]=1
  r=d["testResults"][0]
  r["status"]="failed"
  r["assertionResults"][1]["status"]="failed"
  File.write(ARGV.fetch(0),JSON.generate(d))
' "${report}" "${repo_root}"
run_collector desktop-shard-1 >/dev/null
jq -e '.status == "failed" and ([.suites[] | select(.id == "desktop.vitest.default.rest")][0].status == "failed") and ([.suites[] | select(.id == "desktop.vitest.default.rest")][0].error_class == "test_failure")' "${projection}" >/dev/null

# A runtime skip is environment-skip evidence, never a pass.
ruby -rjson -e '
  d=JSON.parse(File.read(ARGV.fetch(0)))
  d["numPassedTests"]=1; d["numFailedTests"]=0; d["numPendingTests"]=1
  r=d["testResults"][0]
  r["status"]="passed"
  r["assertionResults"][1]={"title"=>"needs a device","fullName"=>"x","status"=>"skipped"}
  File.write(ARGV.fetch(0),JSON.generate(d))
' "${report}" "${repo_root}"
run_collector desktop-shard-1 >/dev/null
jq -e '.status == "blocked" and ([.suites[] | select(.id == "desktop.vitest.default.rest")][0].status == "blocked") and ([.suites[] | select(.id == "desktop.vitest.default.rest")][0].env_skipped_count == 1)' "${projection}" >/dev/null

# A runner report that covers nothing cannot attest a pass.
ruby -rjson -e 'd=JSON.parse(File.read(ARGV.fetch(0))); d["numTotalTests"]=0; d["numPassedTests"]=0; d["testResults"]=[]; File.write(ARGV.fetch(0),JSON.generate(d))' "${report}"
expect_reject 'zero-discovery full run' desktop-shard-1

# A report total that disagrees with the parsed cases is a broken collection.
ruby -rjson -e '
  d=JSON.parse(File.read(ARGV.fetch(0)))
  d["numTotalTests"]=99; d["numPassedTests"]=2
  r=ARGV.fetch(1)
  d["testResults"]=[{"name"=>"#{r}/taurine-desktop/src/features/rest/api.test.ts","status"=>"passed",
    "assertionResults"=>[{"title"=>"a","fullName"=>"x","status"=>"passed"},{"title"=>"b","fullName"=>"x","status"=>"passed"}]}]
  File.write(ARGV.fetch(0),JSON.generate(d))
' "${report}" "${repo_root}"
expect_reject 'report totals mismatch' desktop-shard-1

# An executed case no reviewed suite owns fails closed without publishing it.
ruby -rjson -e '
  d=JSON.parse(File.read(ARGV.fetch(0)))
  d["numTotalTests"]=3
  r=ARGV.fetch(1)
  d["testResults"] << {"name"=>"#{r}/taurine-desktop/src/features/unknown/orphan.test.ts","status"=>"passed",
    "assertionResults"=>[{"title"=>"c","fullName"=>"x","status"=>"passed"}]}
  File.write(ARGV.fetch(0),JSON.generate(d))
' "${report}" "${repo_root}"
expect_reject 'unowned test case' desktop-shard-1

# A case two suites claim is an ownership overlap, not an attribution choice.
ruby -rjson -e '
  d=JSON.parse(File.read(ARGV.fetch(0)))
  r=ARGV.fetch(1)
  d["testResults"][1]={"name"=>"#{r}/taurine-desktop/src/features/notes/editor.test.ts","status"=>"passed",
    "assertionResults"=>[{"title"=>"d","fullName"=>"x","status"=>"passed"}]}
  File.write(ARGV.fetch(0),JSON.generate(d))
' "${report}" "${repo_root}"
ruby -rjson -e '
  path=ARGV.fetch(0)
  m=JSON.parse(File.read(path))
  m["suites"]["desktop.vitest.default.rest"]["include"] << "taurine-desktop/src/features/notes/**"
  File.write(path,JSON.generate(m))
' "${repo_root}/scripts/ci/suite-ownership.json"
expected_manifest_digest="$(manifest_digest)"
expect_reject 'overlapping suite ownership' desktop-shard-1

# A manifest edited after the trusted pre-code step is refused: the evidence
# would otherwise attest an unreviewed ownership mapping.
write_manifest
expected_manifest_digest="3333333333333333333333333333333333333333333333333333333333333333"
expect_reject 'stale manifest digest' desktop-shard-1
expected_manifest_digest="$(manifest_digest)"

# Without a runner report the collector records that no evidence exists, and
# nothing is written.
rm -f "${report}" "${projection}"
set +e
output="$(run_collector desktop-shard-1 2>&1)"
status=$?
set -e
[[ "${status}" -eq 0 && "${output}" == *"not collected"* && ! -f "${projection}" ]] || {
  echo 'missing report: collector did not report absence honestly' >&2
  exit 1
}

# A partial selection accounts only what was selected and ran; unselected
# candidates that produced nothing are absent, never not-executed passes.
expected_mode=partial
expected_selected_ids="$(jq -cn '["desktop.vitest.default.rest"]')"
ruby -rjson -e 'File.write(ARGV.fetch(0), JSON.generate({"numTotalTests" => 0, "numPassedTests" => 0, "testResults" => []}))' "${report}"
ruby -rjson -e '
  d=JSON.parse(File.read(ARGV.fetch(0)))
  d["numTotalTests"]=2; d["numPassedTests"]=2
  r=ARGV.fetch(1)
  d["testResults"]=[{"name"=>"#{r}/taurine-desktop/src/features/rest/api.test.ts","status"=>"passed",
    "assertionResults"=>[{"title"=>"a","fullName"=>"x","status"=>"passed"},{"title"=>"b","fullName"=>"x","status"=>"passed"}]}]
  File.write(ARGV.fetch(0),JSON.generate(d))
' "${report}" "${repo_root}"
run_collector desktop-shard-1 >/dev/null
jq -e '.status == "passed" and .selection_mode == "partial" and
  ([.suites[] | select(.id == "desktop.vitest.default.notes")][0].status == "absent") and
  ([.suites[] | select(.id == "desktop.vitest.default.notes")][0].executed_count == 0)' "${projection}" >/dev/null

# An unselected suite whose cases ran cannot exist: the collector refuses to
# certify execution outside the reviewed selection.
expected_mode=partial
expected_selected_ids="$(jq -cn '["desktop.vitest.default.rest"]')"
ruby -rjson -e '
  d=JSON.parse(File.read(ARGV.fetch(0)))
  d["numTotalTests"]=4
  r=ARGV.fetch(1)
  d["testResults"] << {"name"=>"#{r}/taurine-desktop/src/features/notes/editor.test.ts","status"=>"passed",
    "assertionResults"=>[{"title"=>"e","fullName"=>"x","status"=>"passed"},{"title"=>"f","fullName"=>"x","status"=>"passed"}]}
  File.write(ARGV.fetch(0),JSON.generate(d))
' "${report}" "${repo_root}"
expect_reject 'executed case outside the selection' desktop-shard-1

# The Playwright adapter: projects, files and statuses from the browser report.
expected_mode=full
expected_selected_ids="$(group_ids desktop-playwright-feedback-linux)"
ruby -rjson -e '
  spec = lambda { |file, project, status|
    { "file" => file, "specs" => [ { "title" => "SYNTHETIC-PRIVATE", "tests" => [ { "projectName" => project, "status" => status } ] } ] }
  }
  report = { "config" => {}, "suites" => [
    { "title" => "SYNTHETIC-PRIVATE", "suites" => [
      spec.call("tests/e2e/rest/login.spec.ts", "smoke", "expected"),
      spec.call("tests/e2e/database/query.spec.ts", "critical", "expected") ] } ] }
  File.write(ARGV.fetch(0), JSON.generate(report))
' "${report}" "${repo_root}"
run_collector e2e-critical >/dev/null
jq -e '.status == "passed" and .coverage_requirement_id == "desktop-playwright-feedback-linux" and
  ([.suites[] | select(.status == "passed") | .executed_count] | all(. == 1))' "${projection}" >/dev/null

# A case from a project outside the reviewed group scope is a filter mismatch.
ruby -rjson -e '
  d=JSON.parse(File.read(ARGV.fetch(0)))
  d["suites"][0]["suites"] << { "file" => "tests/e2e/rest/other.spec.ts", "specs" => [ { "title" => "x", "tests" => [ { "projectName" => "bench", "status" => "expected" } ] } ] }
  File.write(ARGV.fetch(0),JSON.generate(d))
' "${report}" "${repo_root}"
expect_reject 'project outside the group scope' e2e-critical

# A group with no collector adapter cannot fabricate evidence.
expected_selected_ids="$(group_ids mobile-playwright-smoke-linux)"
expected_mode=full
mkdir -p "${repo_root}/taurine-mobile/tests/e2e/integration"
ruby -rjson -e 'File.write(ARGV.fetch(0), JSON.generate({"numTotalTests" => 0, "testResults" => []}))' "${report}"
expect_reject 'unadapted runner' mobile-smoke-concern

echo 'suite collector: discovery, ownership, execution and sanitization fixtures passed'
