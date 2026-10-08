#!/usr/bin/env bash
# Synthetic-only checks for the suite-selection dispatch plumbing: the shadow
# review word in the concern contract, the honest not-collected state when the
# collector produces no projection, the shadow summary rendering, and the
# dispatcher's fail-closed selection-review step - each fixture runs the
# reviewed workflow script itself (extract-step), never a copy.
set -euo pipefail

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/suite-dispatch-review-test.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
matrix="$(pwd)/.github/ci-matrix.json"
source_root="${work}/src"
summary="${work}/summary.md"
output="${work}/output.txt"
runner_temp="${work}/runner-temp"
mkdir -p "${source_root}/src/scripts/ci" "${runner_temp}/test-ids"
source_sha=1111111111111111111111111111111111111111
control_sha=2222222222222222222222222222222222222222

catalog_digest="$(ruby -rdigest -rjson -e '
  sort = lambda { |v| v.is_a?(Hash) ? v.keys.sort.to_h { |k| [k, sort.call(v.fetch(k))] } : v.is_a?(Array) ? v.map { |x| sort.call(x) } : v }
  puts Digest::SHA256.hexdigest(JSON.generate(sort.call(JSON.parse(File.read(ARGV.fetch(0))).fetch("suite_catalog")), ascii_only: true))
' "${matrix}")"

# A synthetic private ownership manifest for the reviewed desktop vitest group:
# each feature suite owns its feature tree. The manifest never leaves the
# synthetic source root, exactly as on a runner.
group_candidates="$(jq -c '.suite_catalog.coverage_requirements[] | select(.id=="desktop-vitest-default-linux") | .candidate_suite_ids' "${matrix}")"
ruby -rjson -e '
  candidates = JSON.parse(ARGV.fetch(0))
  manifest = { "schema_version" => 1, "suites" => {} }
  candidates.each do |id|
    feature = id.split(".").last
    manifest["suites"][id] = { "include" => ["taurine-desktop/src/features/#{feature}/**"] }
  end
  File.write(ARGV.fetch(1), JSON.generate(manifest))
' "${group_candidates}" "${source_root}/src/scripts/ci/suite-ownership.json"
manifest_digest="$(ruby -rdigest -rjson -e '
  sort = lambda { |v| v.is_a?(Hash) ? v.keys.sort.to_h { |k| [k, sort.call(v.fetch(k))] } : v.is_a?(Array) ? v.map { |x| sort.call(x) } : v }
  puts Digest::SHA256.hexdigest(JSON.generate(sort.call(JSON.parse(File.read(ARGV.fetch(0)))), ascii_only: true))
' "${source_root}/src/scripts/ci/suite-ownership.json")"

# A clean vitest runner report over two feature suites.
report="${runner_temp}/test-ids/desktop-shard-1.json"
ruby -rjson -e '
  cases = { "taurine-desktop/src/features/rest/api.test.ts" => 2,
            "taurine-desktop/src/features/notes/store.test.ts" => 1 }
  test_results = cases.map do |path, count|
    { "name" => path,
      "assertionResults" => Array.new(count) { { "status" => "passed" } } }
  end
  File.write(ARGV.fetch(0), JSON.generate({ "numTotalTests" => cases.values.sum, "testResults" => test_results }))
' "${report}"

run_step() {
  # run_step <workflow> <step name> <env map file> [working dir]
  ruby .github/policy/extract-step.rb "$1" "$2" run > "${work}/step.sh"
  ruby .github/policy/extract-step.rb "$1" "$2" env "$3" > "${work}/step.env"
  set +e
  step_envs=()
  while IFS= read -r step_env_line; do step_envs+=("${step_env_line}"); done < "${work}/step.env"
  ( cd "${4:-$(pwd)}" && env "${step_envs[@]}" \
      RUNNER_TEMP="${runner_temp}" GITHUB_STEP_SUMMARY="${summary}" \
      GITHUB_OUTPUT="${output}" GITHUB_WORKSPACE="${source_root}" \
      bash "${work}/step.sh" ) 2> "${work}/stderr.txt"
  local status=$?
  set -e
  cat "${work}/stderr.txt" >&2
  return "${status}"
}

write_env_map() {
  # write_env_map <concern> <manifest present> <group id> <shadow ids json>
  jq -n \
    --arg root "${source_root}" \
    --arg sha "${control_sha}" \
    --arg concern "$1" \
    --arg source "${source_sha}" \
    --arg present "$2" \
    --arg group "$3" \
    --arg manifest "${manifest_digest}" \
    --arg catalog "${catalog_digest}" \
    --arg selected "${group_candidates}" \
    --arg shadow "$4" \
    '{
      "${{ github.workspace }}": $root,
      "${{ github.sha }}": $sha,
      "${{ inputs.concern }}": $concern,
      "${{ inputs.source_sha }}": $source,
      "${{ steps.suite-contract.outputs.manifest_present }}": $present,
      "${{ steps.suite-contract.outputs.coverage_requirement_id }}": $group,
      "${{ steps.suite-contract.outputs.manifest_digest }}": $manifest,
      "${{ steps.suite-contract.outputs.catalog_digest }}": $catalog,
      "${{ steps.suite-contract.outputs.selection_digest }}": "5fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
      "${{ steps.suite-contract.outputs.selection_mode }}": "full",
      "${{ steps.suite-contract.outputs.selected_suite_ids }}": $selected,
      "${{ steps.suite-contract.outputs.shadow_selected_suite_ids }}": $shadow
    }' > "${work}/env-map.json"
}

# ---------------------------------------------------------------------------
# 1. The concern contract under a shadow review: the evidence contract stays
#    the full set (a shadow round's projection is identical to a full round's)
#    and the would-be selection leaves only through the shadow output.
contract_env() {
  env -u CI_SUITE_SELECTION CI_SUITE_SELECTION="$1" ruby .github/policy/suite-contract.rb \
    "${matrix}" desktop-shard-1 "${source_root}"
}
shadow_payload="$(jq -c --argjson selected "$(jq -c '.[0:3]' <<<"${group_candidates}")" \
  '{review:"shadow", selection_mode:"partial", selected_suite_ids:$selected, selection_digest:"'"$(printf 'a%.0s' $(seq 64))"'"}')"
shadow_contract="$(contract_env "${shadow_payload}")"
plain_contract="$(contract_env '')"
grep -q '^selection_mode=full$' <<<"${shadow_contract}"
grep -qF "selected_suite_ids=${group_candidates}" <<<"${shadow_contract}"
[[ "$(grep '^shadow_selected_suite_ids=' <<<"${shadow_contract}" | cut -d= -f2-)" == "$(jq -c '.[0:3] | sort' <<<"${group_candidates}")" ]]
[[ "$(grep '^selection_digest=' <<<"${shadow_contract}" | cut -d= -f2-)" == "$(grep '^selection_digest=' <<<"${plain_contract}" | cut -d= -f2-)" ]]
# A plain partial contract (the future enforce path) is unchanged: partial mode,
# the supplied subset, the digest of the request itself.
partial_contract="$(contract_env '{"selection_mode":"partial","selected_suite_ids":'"$(jq -c '.[0:2]' <<<"${group_candidates}")"'}')"
grep -q '^selection_mode=partial$' <<<"${partial_contract}"
# An unreviewed review word is an error, never a contract.
if contract_env '{"review":"enforce","selection_mode":"partial","selected_suite_ids":[]}' >/dev/null 2>&1; then
  echo 'contract: accepted an unreviewed dispatch review mode' >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. D3: the collector's "no runner report" state exits 0 without a projection,
#    and the reviewed evidence step must record that honestly instead of
#    failing at the wrap. Pre-fix, this exact invocation died in jq --rawfile.
: > "${summary}"
write_env_map desktop-shard-1 true desktop-vitest-default-linux ''
rm -f "${report}" "${runner_temp}/suite-evidence.json" "${runner_temp}/suite-evidence-export.json"
run_step .github/workflows/linux-validation-concern.yml 'Collect the sanitized suite evidence' "${work}/env-map.json"
[[ -s "${summary}" ]] || { echo 'no-report path: the step summary is empty' >&2; exit 1; }
grep -q 'suite evidence: not collected (the concern produced no runner report)' "${summary}"
[[ ! -f "${runner_temp}/suite-evidence-export.json" ]] || {
  echo 'no-report path: an export was produced without a projection' >&2
  exit 1
}

# 3. A real report renders the overview, the projection and - only with a
#    shadow payload - the shadow comparison line.
: > "${summary}"
write_env_map desktop-shard-1 true desktop-vitest-default-linux ''
ruby -rjson -e '
  cases = { "taurine-desktop/src/features/rest/api.test.ts" => 2,
            "taurine-desktop/src/features/notes/store.test.ts" => 1 }
  test_results = cases.map do |path, count|
    { "name" => path, "assertionResults" => Array.new(count) { { "status" => "passed" } } }
  end
  File.write(ARGV.fetch(0), JSON.generate({ "numTotalTests" => cases.values.sum, "testResults" => test_results }))
' "${report}"
run_step .github/workflows/linux-validation-concern.yml 'Collect the sanitized suite evidence' "${work}/env-map.json"
grep -q '## Feature-suite overview' "${summary}"
grep -q 'Sanitized evidence projection' "${summary}"
grep -q 'Suite selection review (shadow)' "${summary}" && {
  echo 'the shadow line rendered without a shadow payload' >&2
  exit 1
}

: > "${summary}"
shadow_ids="$(jq -c '.[0:3]' <<<"${group_candidates}")"
write_env_map desktop-shard-1 true desktop-vitest-default-linux "${shadow_ids}"
run_step .github/workflows/linux-validation-concern.yml 'Collect the sanitized suite evidence' "${work}/env-map.json"
grep -q 'Suite selection review (shadow)' "${summary}"
grep -q "would have run 3 of 18 suites" "${summary}"
# The sanitized projection itself never carries the shadow payload.
projection_block="$(sed -n '/```json/,/```/p' "${summary}" | sed '1d;$d')"
if grep -q 'shadow' <<<"${projection_block}"; then
  echo 'the sanitized projection carries the shadow payload' >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 4. The dispatcher's selection-review step: fail-closed fallback, complete-set
#    no-op, and the shadow payload map for a genuine partial request.
graph_digest="$(ruby -rdigest -rjson -e '
  sort = lambda { |v| v.is_a?(Hash) ? v.keys.sort.to_h { |k| [k, sort.call(v.fetch(k))] } : v.is_a?(Array) ? v.map { |x| sort.call(x) } : v }
  puts Digest::SHA256.hexdigest(JSON.generate(sort.call(JSON.parse(File.read(ARGV.fetch(0))).fetch("feature_graph")), ascii_only: true))
' "${matrix}")"
plan_env() { jq -n --arg request "$1" '{ "${{ inputs.suite_selection }}": $request }' > "${work}/plan-env.json"; }

: > "${summary}"; : > "${output}"
plan_env "$(printf 'not json at all')"
run_step .github/workflows/linux-validation.yml 'Compute the suite selection review' "${work}/plan-env.json"
[[ "$(grep '^suite_reviews=' "${output}" | cut -d= -f2-)" == '{}' ]] || {
  echo 'a malformed request did not fall back to the complete set' >&2
  exit 1
}
grep -q 'The selection request was rejected' "${summary}"

: > "${summary}"; : > "${output}"
plan_env "$(jq -cn --arg d "${catalog_digest}" --arg g "${graph_digest}" \
  '{selection_mode:"partial", changed_feature_ids:["rest"], base_sha:("2" * 40), base_valid:false, unknown_paths:false, shared_surface:false, expected_catalog_digest:$d, expected_feature_graph_digest:$g, review:"shadow"}')"
run_step .github/workflows/linux-validation.yml 'Compute the suite selection review' "${work}/plan-env.json"
[[ "$(grep '^suite_reviews=' "${output}" | cut -d= -f2-)" == '{}' ]] || {
  echo 'a fail-closed request still produced shadow payloads' >&2
  exit 1
}

: > "${summary}"; : > "${output}"
plan_env "$(jq -cn --arg d "${catalog_digest}" --arg g "${graph_digest}" \
  '{selection_mode:"partial", changed_feature_ids:["rest"], base_sha:("2" * 40), base_valid:true, unknown_paths:false, shared_surface:false, expected_catalog_digest:$d, expected_feature_graph_digest:$g, review:"shadow"}')"
run_step .github/workflows/linux-validation.yml 'Compute the suite selection review' "${work}/plan-env.json"
reviews="$(grep '^suite_reviews=' "${output}" | cut -d= -f2-)"
# Every concern bound to a supported group receives exactly one payload; the
# unbound concerns receive none.
expected_concerns="$(jq -r '[.suite_catalog.coverage_requirements[] | select(.availability == "supported") | .concerns[]] | unique | sort | join("\n")' "${matrix}")"
[[ "$(jq -r 'keys | sort | join("\n")' <<<"${reviews}")" == "${expected_concerns}" ]]
[[ "$(jq -r '.["rust-app-1"] // "absent"' <<<"${reviews}")" == "absent" ]]
# The desktop payloads carry the rest closure only, marked shadow.
vitest_selected="$(jq -r '.["desktop-shard-1"].selected_suite_ids | join(" ")' <<<"${reviews}")"
[[ "${vitest_selected}" == *"desktop.vitest.default.rest"* && "${vitest_selected}" == *"desktop.vitest.default.automation"* &&
   "${vitest_selected}" != *"desktop.vitest.default.notes"* ]]
jq -e '.["desktop-shard-1"] | .review == "shadow" and .selection_mode == "partial" and (.selection_digest | test("^[0-9a-f]{64}$"))' <<<"${reviews}" >/dev/null
# The same payload goes to both shards of the group.
[[ "$(jq -r '.["desktop-shard-1"].selected_suite_ids' <<<"${reviews}")" == "$(jq -r '.["desktop-shard-2"].selected_suite_ids' <<<"${reviews}")" ]]
grep -q 'Suite selection review (shadow' "${summary}"
grep -q 'desktop-vitest-default-linux' "${summary}"

echo 'suite dispatch review: shadow contract, honest not-collected, shadow rendering and fail-closed plan step passed'
