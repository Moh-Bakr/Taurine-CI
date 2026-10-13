#!/usr/bin/env bash
# Synthetic-only fixtures for the standalone case-evidence structural contract.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/case-evidence-contract.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
mkdir -p "${work}/source/taurine-desktop/tests/unit"
touch "${work}/source/taurine-desktop/tests/unit/api.test.ts"

write_vitest() {
  ruby -rjson -rdigest -e '
    dir, root = ARGV
    source="a"*40; control="b"*40; manifest="c"*64; catalog="d"*64
    runner="vitest-desktop"; config="desktop-vitest-default"; tier="default"; platform="linux"
    ids=["desktop.vitest.default.api"]
    selection=Digest::SHA256.hexdigest(JSON.generate(ids))
    file=File.join(root,"taurine-desktop/tests/unit/api.test.ts")
    cases=["lists requests", "sends headers"]
    discovery_report=cases.map { |name| {"file"=>file,"name"=>"api suite > #{name}"} }
    execution_report={"numTotalTests"=>2,"numPassedTests"=>2,"numFailedTests"=>0,"numPendingTests"=>0,
      "testResults"=>[{"name"=>file,"assertionResults"=>cases.map { |name| {"ancestorTitles"=>["api suite"],"title"=>name,"status"=>"passed"} }}]}
    case_ids=cases.map do |name|
      identity=[runner,config,tier,platform,"","taurine-desktop/tests/unit/api.test.ts","","","api suite > #{name}"]
      Digest::SHA256.hexdigest(JSON.generate(identity))
    end
    expected={"schema_version"=>1,"source_sha"=>source,"control_sha"=>control,"manifest_digest"=>manifest,
      "catalog_digest"=>catalog,"selection_digest"=>selection,"selection_mode"=>"full","selected_suite_ids"=>ids,
      "runner_id"=>runner,"config_id"=>config,"tier"=>tier,"platform"=>platform,"project"=>nil,
      "tool_version"=>"3.2.1","repo_root"=>root}
    common={"schema_version"=>1,"source_sha"=>source,"control_sha"=>control,"manifest_digest"=>manifest,
      "catalog_digest"=>catalog,"selection_digest"=>selection,"collection_complete"=>true,"runner_id"=>runner,
      "config_id"=>config,"tier"=>tier,"platform"=>platform,"producer_version"=>"case-evidence-producer/1",
      "tool_version"=>"3.2.1","producer_status"=>"complete"}
    discovery=common.merge("phase"=>"discovery","command_id"=>"vitest.desktop.list.v1","report"=>discovery_report)
    discovery["collection_digest"]=Digest::SHA256.hexdigest(JSON.generate(discovery_report))
    execution=common.merge("phase"=>"execution","command_id"=>"vitest.desktop.run.v1","report"=>execution_report,
      "selected_suite_ids"=>ids,"discovered_case_ids"=>case_ids)
    execution["collection_digest"]=Digest::SHA256.hexdigest(JSON.generate(execution_report))
    {"expected.json"=>expected,"discovery.json"=>discovery,"execution.json"=>execution}.each do |name,value|
      File.write(File.join(dir,name),JSON.generate(value))
    end
  ' "${work}" "${work}/source"
}

write_playwright() {
  ruby -rjson -rdigest -e '
    dir, root = ARGV
    source="e"*40; control="f"*40; manifest="1"*64; catalog="2"*64
    runner="playwright-desktop"; config="desktop-playwright-projects"; tier="feedback"; platform="linux"; project="smoke"
    ids=["desktop.playwright.feedback.api"]
    selection=Digest::SHA256.hexdigest(JSON.generate(ids))
    file="tests/e2e/api.spec.ts"
    discovery_report={"suites"=>[{"file"=>file,"specs"=>[{"title"=>"loads API","file"=>file,
      "tests"=>[{"projectName"=>project,"status"=>"discovered","results"=>[]}]}]}]}
    execution_report={"suites"=>[{"file"=>file,"specs"=>[{"title"=>"loads API","file"=>file,
      "tests"=>[{"projectName"=>project,"status"=>"expected","results"=>[{"status"=>"passed"}]}]}]}]}
    identity=[runner,config,tier,platform,project,"taurine-desktop/#{file}","","","loads API"]
    case_id=Digest::SHA256.hexdigest(JSON.generate(identity))
    expected={"schema_version"=>1,"source_sha"=>source,"control_sha"=>control,"manifest_digest"=>manifest,
      "catalog_digest"=>catalog,"selection_digest"=>selection,"selection_mode"=>"full","selected_suite_ids"=>ids,
      "runner_id"=>runner,"config_id"=>config,"tier"=>tier,"platform"=>platform,"project"=>project,
      "tool_version"=>"1.62.0","repo_root"=>root}
    common={"schema_version"=>1,"source_sha"=>source,"control_sha"=>control,"manifest_digest"=>manifest,
      "catalog_digest"=>catalog,"selection_digest"=>selection,"collection_complete"=>true,"runner_id"=>runner,
      "config_id"=>config,"tier"=>tier,"platform"=>platform,"producer_version"=>"case-evidence-producer/1",
      "tool_version"=>"1.62.0","producer_status"=>"complete"}
    discovery=common.merge("phase"=>"discovery","command_id"=>"playwright.desktop.list.smoke.v1","report"=>discovery_report)
    discovery["collection_digest"]=Digest::SHA256.hexdigest(JSON.generate(discovery_report))
    execution=common.merge("phase"=>"execution","command_id"=>"playwright.desktop.run.smoke.v1","report"=>execution_report,
      "selected_suite_ids"=>ids,"discovered_case_ids"=>[case_id])
    execution["collection_digest"]=Digest::SHA256.hexdigest(JSON.generate(execution_report))
    {"expected.json"=>expected,"discovery.json"=>discovery,"execution.json"=>execution}.each do |name,value|
      File.write(File.join(dir,name),JSON.generate(value))
    end
  ' "${work}" "${work}/source"
}

run_contract() {
  ruby "${root}/.github/policy/case-evidence-contract.rb" \
    "${work}/expected.json" "${work}/discovery.json" "${work}/execution.json"
}

expect_error() {
  local expected_error="$1" output status
  set +e
  output="$(run_contract)"
  status=$?
  set -e
  [[ "${status}" -ne 0 ]] || { echo "${expected_error}: invalid evidence accepted" >&2; exit 1; }
  jq -e --arg error "${expected_error}" '.status == "shadow_blocked" and .error_class == $error' <<<"${output}" >/dev/null || {
    echo "${expected_error}: wrong sanitized rejection" >&2; exit 1;
  }
  ! grep -Eq 'api suite|lists requests|api\.test\.ts|"case_id"|[a-f0-9]{64}' <<<"${output}" || {
    echo "${expected_error}: raw identity or digest leaked" >&2; exit 1;
  }
}

write_vitest
positive="$(run_contract)"
jq -e '.status == "shadow_valid_unverified_producer" and .counts == {"discovered":2,"executed":2,"passed":2,"failed":0,"flaky":0,"skipped":0,"ignored":0,"quarantined":0,"env_skipped":0}' <<<"${positive}" >/dev/null
! grep -Eq 'api suite|lists requests|api\.test\.ts|"case_id"|[a-f0-9]{64}' <<<"${positive}" || {
  echo 'valid result leaked a title, path, case ID or digest' >&2; exit 1;
}

mutate() {
  ruby -rjson -e '
    path, field, value = ARGV
    data=JSON.parse(File.read(path))
    data[field]=JSON.parse(value)
    File.write(path,JSON.generate(data))
  ' "$1" "$2" "$3"
}

write_vitest; mutate "${work}/discovery.json" schema_version 99; expect_error schema_version_unsupported
write_vitest; mutate "${work}/discovery.json" producer_status '"failed"'; expect_error producer_failed
write_vitest; mutate "${work}/discovery.json" collection_complete false; expect_error collection_incomplete
write_vitest; mutate "${work}/discovery.json" source_sha '"9999999999999999999999999999999999999999"'; expect_error identity_mismatch
write_vitest; mutate "${work}/discovery.json" command_id '"vitest.mobile.list.v1"'; expect_error command_mismatch
write_vitest; mutate "${work}/execution.json" tool_version '"9.9.9"'; expect_error tool_version_mismatch
write_vitest; mutate "${work}/execution.json" discovered_case_ids '["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]'; expect_error discovery_execution_mismatch
write_vitest; mutate "${work}/discovery.json" producer_version '"case-evidence-producer/999"'; expect_error producer_version_mismatch
write_vitest; mutate "${work}/execution.json" catalog_digest '"9999999999999999999999999999999999999999999999999999999999999999"'; expect_error identity_mismatch

# Duplicate normalized identities are refused before count aggregation.
write_vitest
ruby -rjson -rdigest -e 'p=ARGV.fetch(0); d=JSON.parse(File.read(p)); r=d["report"]; r[1]["name"]=r[0]["name"]; d["collection_digest"]=Digest::SHA256.hexdigest(JSON.generate(r)); File.write(p,JSON.generate(d))' "${work}/discovery.json"
expect_error duplicate_case_identity

# A one-case execution cannot omit another discovered case, even when its
# self-reported discovery IDs and reporter totals are internally consistent.
write_vitest
ruby -rjson -rdigest -e 'p=ARGV.fetch(0); d=JSON.parse(File.read(p)); r=d["report"]; r["testResults"][0]["assertionResults"].pop; r["numTotalTests"]=1; r["numPassedTests"]=1; d["discovered_case_ids"].pop; d["collection_digest"]=Digest::SHA256.hexdigest(JSON.generate(r)); File.write(p,JSON.generate(d))' "${work}/execution.json"
expect_error discovery_execution_mismatch

# The report digest binds the structured report; inconsistent reporter totals fail closed.
write_vitest
ruby -rjson -rdigest -e 'p=ARGV.fetch(0); d=JSON.parse(File.read(p)); d["report"]["numTotalTests"]=99; d["collection_digest"]=Digest::SHA256.hexdigest(JSON.generate(d["report"])); File.write(p,JSON.generate(d))' "${work}/execution.json"
expect_error report_count_mismatch
write_vitest; mutate "${work}/execution.json" collection_digest '"0000000000000000000000000000000000000000000000000000000000000000"'; expect_error report_digest_invalid

# Empty discovery cannot be made valid by asserting collection_complete=true.
write_vitest
ruby -rjson -rdigest -e 'p=ARGV.fetch(0); d=JSON.parse(File.read(p)); d["report"]=[]; d["collection_digest"]=Digest::SHA256.hexdigest(JSON.generate(d["report"])); File.write(p,JSON.generate(d))' "${work}/discovery.json"
expect_error case_collection_empty

# A correctly collected failed test is sanitized blocked evidence, never a pass.
write_vitest
ruby -rjson -rdigest -e 'p=ARGV.fetch(0); d=JSON.parse(File.read(p)); r=d["report"]; r["numPassedTests"]=1; r["numFailedTests"]=1; r["testResults"][0]["assertionResults"][1]["status"]="failed"; d["collection_digest"]=Digest::SHA256.hexdigest(JSON.generate(r)); File.write(p,JSON.generate(d))' "${work}/execution.json"
blocked="$(run_contract)"
jq -e '.status == "shadow_blocked" and .counts.failed == 1 and .counts.passed == 1' <<<"${blocked}" >/dev/null
! grep -Eq 'api suite|lists requests|api\.test\.ts|"case_id"|[a-f0-9]{64}' <<<"${blocked}" || {
  echo 'blocked result leaked a raw identity' >&2; exit 1;
}

# Playwright project scope is fixed by the allowlist and identity includes project.
write_playwright
pw="$(run_contract)"
jq -e '.status == "shadow_valid_unverified_producer" and .counts.discovered == 1 and .counts.passed == 1' <<<"${pw}" >/dev/null
! grep -Eq 'loads API|api\.spec\.ts|"case_id"|[a-f0-9]{64}' <<<"${pw}" || {
  echo 'Playwright result leaked a raw identity' >&2; exit 1;
}
write_playwright; mutate "${work}/execution.json" command_id '"playwright.desktop.run.visual.v1"'; expect_error command_mismatch

echo 'case evidence contract: schema, bindings, exact identity sets, status counts and sanitization fixtures passed'
