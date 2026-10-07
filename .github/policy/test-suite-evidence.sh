#!/usr/bin/env bash
# Synthetic-only checks for the sanitized, catalog-bound suite proof boundary.
set -euo pipefail

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/suite-evidence-test.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
proof="${work}/proof.json"
safe="${work}/safe.json"
source_sha=1111111111111111111111111111111111111111
control_sha=2222222222222222222222222222222222222222
manifest_digest=3333333333333333333333333333333333333333333333333333333333333333
catalog_digest="$(ruby -rdigest -rjson -e '
  sort = lambda { |v| v.is_a?(Hash) ? v.keys.sort.to_h { |k| [k, sort.call(v.fetch(k))] } : v.is_a?(Array) ? v.map { |x| sort.call(x) } : v }
  catalog = JSON.parse(File.read(ARGV.fetch(0))).fetch("suite_catalog")
  puts Digest::SHA256.hexdigest(JSON.generate(sort.call(catalog), ascii_only: true))
' .github/ci-matrix.json)"
selection_digest=5555555555555555555555555555555555555555555555555555555555555555
collection_digest=6666666666666666666666666666666666666666666666666666666666666666
coverage_id=desktop-vitest-default-linux
matrix=.github/ci-matrix.json

write_full_pass() {
  ruby -rjson -e '
    matrix = JSON.parse(File.read(ARGV.fetch(0)))
    group = matrix.fetch("suite_catalog").fetch("coverage_requirements").find { |row| row.fetch("id") == ARGV.fetch(1) }
    ids = group.fetch("candidate_suite_ids")
    proof = {
      "schema_version" => 1, "phase" => "execution",
      "source_sha" => ARGV.fetch(2), "control_sha" => ARGV.fetch(3),
      "manifest_digest" => ARGV.fetch(4), "catalog_digest" => ARGV.fetch(5),
      "selection_digest" => ARGV.fetch(6), "collection_digest" => ARGV.fetch(7),
      "collection_complete" => true, "coverage_requirement_id" => group.fetch("id"),
      "runner_id" => group.fetch("runner"), "config_id" => group.fetch("config"),
      "tier" => group.fetch("tier"), "platform" => group.fetch("platforms").fetch(0),
      "selection_mode" => "full", "selected_suite_ids" => ids,
      "active_suite_ids" => ids, "absent_suite_ids" => [], "status" => "passed",
      "suites" => ids.map { |id| { "id" => id, "discovered_count" => 1, "owned_count" => 1,
        "executed_count" => 1, "compiled_count" => 0, "ignored_count" => 0, "quarantined_count" => 0,
        "env_skipped_count" => 0, "status" => "passed", "error_class" => "none" } }
    }
    File.write(ARGV.fetch(8), JSON.generate(proof))
  ' "${matrix}" "${coverage_id}" "${source_sha}" "${control_sha}" \
    "${manifest_digest}" "${catalog_digest}" "${selection_digest}" "${collection_digest}" "${proof}"
}

run_validator() {
  env \
    "CI_EXPECTED_SOURCE_SHA=${source_sha}" \
    "CI_EXPECTED_CONTROL_SHA=${control_sha}" \
    "CI_EXPECTED_MANIFEST_DIGEST=${manifest_digest}" \
    "CI_EXPECTED_CATALOG_DIGEST=${catalog_digest}" \
    "CI_EXPECTED_SELECTION_DIGEST=${selection_digest}" \
    "CI_EXPECTED_COLLECTION_DIGEST=${collection_digest}" \
    CI_EXPECTED_COLLECTION_COMPLETE=true \
    "CI_EXPECTED_SELECTION_MODE=${expected_mode:-full}" \
    "CI_EXPECTED_COVERAGE_REQUIREMENT_ID=${coverage_id}" \
    CI_EXPECTED_PLATFORM=linux \
    "CI_EXPECTED_SELECTED_SUITE_IDS=${expected_selected_ids}" \
    ruby .github/policy/validate-suite-evidence.rb "${matrix}" "${proof}" "${safe}"
}

expect_reject() {
  local label="$1" output status
  set +e
  output="$(run_validator 2>&1)"
  status=$?
  set -e
  [[ "${status}" -ne 0 && "${output}" == 'suite evidence: rejected invalid or incomplete projection' && "${output}" != *'SYNTHETIC-PRIVATE'* ]] || {
    echo "${label}: invalid evidence passed or an unreviewed value was echoed" >&2
    exit 1
  }
}

write_full_pass
expected_mode=full
expected_selected_ids="$(jq -c --arg id "${coverage_id}" '.suite_catalog.coverage_requirements[] | select(.id==$id) | .candidate_suite_ids' "${matrix}")"
run_validator >/dev/null
jq -e --arg digest "${catalog_digest}" '.catalog_digest == $digest and .status == "passed" and all(.suites[]; (keys | sort) == ["compiled_count","discovered_count","env_skipped_count","error_class","executed_count","id","ignored_count","owned_count","quarantined_count","status"])' "${safe}" >/dev/null

# A complete collection may resolve a candidate as absent, but the group still needs
# at least one selected, executed, active suite to report a pass.
write_full_pass
ruby -rjson -e '
  p=ARGV.fetch(0); d=JSON.parse(File.read(p)); id=d.fetch("selected_suite_ids").first
  d["active_suite_ids"].delete(id); d["absent_suite_ids"] << id
  row=d.fetch("suites").find { |x| x.fetch("id") == id }
  %w[discovered_count owned_count executed_count ignored_count quarantined_count env_skipped_count].each { |key| row[key]=0 }
  row["status"]="absent"
  File.write(p,JSON.generate(d))
' "${proof}"
run_validator >/dev/null

# A partial projection can pass locally, while preserving full discovery and never
# claiming the unselected candidates ran.
write_full_pass
partial_ids="$(jq -cn --arg id "$(jq -r '.suite_catalog.coverage_requirements[] | select(.id=="'"${coverage_id}"'") | .candidate_suite_ids[0]' "${matrix}")" '[$id]')"
absent_id="$(jq -r --arg id "${coverage_id}" '.suite_catalog.coverage_requirements[] | select(.id==$id) | .candidate_suite_ids[1]' "${matrix}")"
ruby -rjson -e '
  p=ARGV.fetch(0); d=JSON.parse(File.read(p)); selected=JSON.parse(ARGV.fetch(1)); absent=ARGV.fetch(2); d["selection_mode"]="partial"; d["selected_suite_ids"]=selected
  d.fetch("suites").each do |row|
    if row.fetch("id") == absent
      d["active_suite_ids"].delete(absent); d["absent_suite_ids"] << absent
      %w[discovered_count owned_count executed_count ignored_count quarantined_count env_skipped_count].each { |key| row[key]=0 }
      row["status"]="absent"
      next
    end
    next if selected.include?(row.fetch("id"))
    row["executed_count"]=0; row["ignored_count"]=0; row["quarantined_count"]=0; row["env_skipped_count"]=0
    row["status"]="not_selected"
  end
  File.write(p,JSON.generate(d))
' "${proof}" "${partial_ids}" "${absent_id}"
expected_mode=partial
expected_selected_ids="${partial_ids}"
run_validator >/dev/null

# A compile-only selection is honest blocked evidence: every owned case compiled,
# none executed, and the group cannot pass on it.
expected_mode=full
expected_selected_ids="$(jq -c --arg id "${coverage_id}" '.suite_catalog.coverage_requirements[] | select(.id==$id) | .candidate_suite_ids' "${matrix}")"
write_full_pass
ruby -rjson -e '
  p=ARGV.fetch(0); d=JSON.parse(File.read(p)); d["status"]="blocked"
  row=d.fetch("suites").first
  row["executed_count"]=0; row["compiled_count"]=row.fetch("owned_count"); row["status"]="blocked"; row["error_class"]="compiled_only"
  File.write(p,JSON.generate(d))
' "${proof}"
run_validator >/dev/null

expected_mode=full
write_full_pass
expected_selected_ids="$(jq -c --arg id "${coverage_id}" '.suite_catalog.coverage_requirements[] | select(.id==$id) | .candidate_suite_ids' "${matrix}")"

ruby -rjson -e 'p=ARGV.fetch(0); d=JSON.parse(File.read(p)); d["source_sha"]="1111111111111111111111111111111111111112"; File.write(p,JSON.generate(d))' "${proof}"
expect_reject 'wrong source SHA'

write_full_pass
ruby -rjson -e 'p=ARGV.fetch(0); d=JSON.parse(File.read(p)); d["raw_report_excerpt"]="SYNTHETIC-PRIVATE-DO-NOT-ECHO"; File.write(p,JSON.generate(d))' "${proof}"
expect_reject 'extra raw report field'

write_full_pass
ruby -rjson -e 'p=ARGV.fetch(0); d=JSON.parse(File.read(p)); d["suites"][0]["executed_count"]=0; File.write(p,JSON.generate(d))' "${proof}"
expect_reject 'zero execution labeled passed'

write_full_pass
ruby -rjson -e 'p=ARGV.fetch(0); d=JSON.parse(File.read(p)); d["suites"][0]["quarantined_count"]=1; File.write(p,JSON.generate(d))' "${proof}"
expect_reject 'selected quarantined case labeled passed'

write_full_pass
ruby -rjson -e 'p=ARGV.fetch(0); d=JSON.parse(File.read(p)); d["active_suite_ids"]=[]; d["absent_suite_ids"]=d["selected_suite_ids"]; d["suites"].each { |r| %w[discovered_count owned_count executed_count ignored_count quarantined_count env_skipped_count].each { |k| r[k]=0 }; r["status"]="absent" }; File.write(p,JSON.generate(d))' "${proof}"
expect_reject 'zero-execution group labeled passed'

write_full_pass
ruby -rjson -e 'p=ARGV.fetch(0); d=JSON.parse(File.read(p)); d["suites"][0]["error_class"]="SYNTHETIC-PRIVATE-DO-NOT-ECHO"; File.write(p,JSON.generate(d))' "${proof}"
expect_reject 'unreviewed error class'

write_full_pass
ruby -rjson -e 'p=ARGV.fetch(0); d=JSON.parse(File.read(p)); r=d["suites"][0]; r["executed_count"]=0; r["compiled_count"]=1; r["status"]="passed"; File.write(p,JSON.generate(d))' "${proof}"
expect_reject 'compiled target labeled passed'

write_full_pass
ruby -rjson -e 'p=ARGV.fetch(0); d=JSON.parse(File.read(p)); r=d["suites"][0]; r["executed_count"]=1; r["compiled_count"]=1; r["status"]="blocked"; r["error_class"]="compiled_only"; d["status"]="blocked"; File.write(p,JSON.generate(d))' "${proof}"
expect_reject 'compiled-only row with an executed case'

echo 'suite evidence: full/partial, absence, identity and sanitization fixtures passed'
