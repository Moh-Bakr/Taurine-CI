#!/usr/bin/env bash
# Exercise the canonical dispatch identity with synthetic public inputs only.
set -euo pipefail

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/dispatch-identity-test.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
matrix="$(jq -c . .github/ci-matrix.json)"
source_sha=1111111111111111111111111111111111111111
control_sha=2222222222222222222222222222222222222222
workflow=.github/workflows/linux-validation.yml
base_env=(
  "CI_DISPATCH_CONTRACT_JSON=${matrix}"
  "CI_WORKFLOW_PATH=${workflow}"
  "CI_SOURCE_SHA=${source_sha}"
  CI_CONTROL_REPOSITORY=Moh-Bakr/Taurine-CI
  "CI_CONTROL_SHA=${control_sha}"
  CI_CONTROL_REF=refs/heads/main
)

generate() {
  env "${base_env[@]}" "CI_NORMALIZED_INPUTS=$1" CI_GENERATE_ONLY=true \
    ruby .github/policy/dispatch-identity.rb
}

generate_with_matrix() {
  local supplied_matrix="$1" normalized="$2"
  env "CI_DISPATCH_CONTRACT_JSON=${supplied_matrix}" \
    "CI_WORKFLOW_PATH=${workflow}" "CI_SOURCE_SHA=${source_sha}" \
    CI_CONTROL_REPOSITORY=Moh-Bakr/Taurine-CI "CI_CONTROL_SHA=${control_sha}" \
    CI_CONTROL_REF=refs/heads/main "CI_NORMALIZED_INPUTS=${normalized}" CI_GENERATE_ONLY=true \
    ruby .github/policy/dispatch-identity.rb
}

validate() {
  env "${base_env[@]}" "CI_NORMALIZED_INPUTS=$1" "CI_DISPATCH_KEY=$2" \
    ruby .github/policy/dispatch-identity.rb
}

defaults_key="$(generate "$(jq -cn --arg sha "${source_sha}" '{source_sha:$sha}')")"
explicit_key="$(generate "$(jq -cn --arg sha "${source_sha}" '{source_sha:$sha,profile:"full",visual:false,gitleaks_history:false,base_sha:""}')")"
[[ "${defaults_key}" =~ ^[0-9a-f]{64}$ && "${defaults_key}" == "${explicit_key}" ]] || {
  echo 'dispatch identity did not normalize omitted optional defaults consistently' >&2
  exit 1
}

valid_output="$(validate "$(jq -cn --arg sha "${source_sha}" '{source_sha:$sha}')" "${defaults_key}")"
[[ "${valid_output}" == CI_DISPATCH_IDENTITY=* ]] || {
  echo 'dispatch identity proof was not emitted for a valid key' >&2
  exit 1
}
ruby -rdigest -rjson -e '
  proof = JSON.parse(ARGV.fetch(0).sub(/\ACI_DISPATCH_IDENTITY=/, ""))
  identity = proof.fetch("identity")
  abort "wrong synthetic source echo" unless identity.fetch("source_sha") == ARGV.fetch(1)
  abort "wrong control SHA" unless identity.fetch("control_sha") == ARGV.fetch(2)
  sort_json = lambda { |value| value.is_a?(Hash) ? value.keys.sort.to_h { |key| [key, sort_json.call(value.fetch(key))] } : value.is_a?(Array) ? value.map { |item| sort_json.call(item) } : value }
  expected_catalog = Digest::SHA256.hexdigest(JSON.generate(sort_json.call(JSON.parse(ARGV.fetch(3)).fetch("suite_catalog")), ascii_only: true))
  abort "suite catalog digest missing or incorrect" unless identity.fetch("suite_catalog_digest") == expected_catalog
  abort "defaults missing from proof" unless identity.fetch("inputs") == {
    "base_sha" => "", "gitleaks_history" => false, "only" => "", "profile" => "full",
    "source_sha" => ARGV.fetch(1), "suite_selection" => "", "visual" => false
  }
' "${valid_output}" "${source_sha}" "${control_sha}" "${matrix}"

normalized_defaults="$(jq -cn --arg sha "${source_sha}" '{source_sha:$sha}')"
sorted_matrix="$(jq -S -c . .github/ci-matrix.json)"
sorted_key="$(generate_with_matrix "${sorted_matrix}" "${normalized_defaults}")"
[[ "${sorted_key}" == "${defaults_key}" ]] || {
  echo 'object-key formatting changed the canonical suite catalog identity' >&2
  exit 1
}
changed_catalog="$(jq -c '.suite_catalog.suites[0].concerns += ["synthetic-review"]' .github/ci-matrix.json)"
changed_catalog_key="$(generate_with_matrix "${changed_catalog}" "${normalized_defaults}")"
[[ "${changed_catalog_key}" != "${defaults_key}" ]] || {
  echo 'suite catalog edits did not change the dispatch identity' >&2
  exit 1
}
reordered_catalog="$(jq -c '.suite_catalog.suites |= reverse' .github/ci-matrix.json)"
reordered_catalog_key="$(generate_with_matrix "${reordered_catalog}" "${normalized_defaults}")"
[[ "${reordered_catalog_key}" != "${defaults_key}" ]] || {
  echo 'suite catalog array order was not preserved in the dispatch identity' >&2
  exit 1
}

# The dispatch identity also binds the conservative feature dependency graph:
# proof check plus key change under a graph edit, and refusal without it.
ruby -rdigest -rjson -e '
  proof = JSON.parse(ARGV.fetch(0).sub(/\ACI_DISPATCH_IDENTITY=/, ""))
  sort_json = lambda { |value| value.is_a?(Hash) ? value.keys.sort.to_h { |key| [key, sort_json.call(value.fetch(key))] } : value.is_a?(Array) ? value.map { |item| sort_json.call(item) } : value }
  expected = Digest::SHA256.hexdigest(JSON.generate(sort_json.call(JSON.parse(ARGV.fetch(1)).fetch("feature_graph")), ascii_only: true))
  abort "feature graph digest missing or incorrect" unless proof.fetch("identity").fetch("feature_graph_digest") == expected
' "${valid_output}" "${matrix}"
changed_graph="$(jq -c '.feature_graph.dependency_edges[0].to = "synthetic-review-consumer"' .github/ci-matrix.json)"
changed_graph_key="$(generate_with_matrix "${changed_graph}" "${normalized_defaults}")"
[[ "${changed_graph_key}" != "${defaults_key}" ]] || {
  echo 'feature dependency graph edits did not change the dispatch identity' >&2
  exit 1
}
graphless="$(jq -c 'del(.feature_graph)' .github/ci-matrix.json)"
if generate_with_matrix "${graphless}" "${normalized_defaults}" >/dev/null 2>&1; then
  echo 'a matrix without the feature dependency graph produced an identity' >&2
  exit 1
fi

# The workflow's pinned environment deliberately supplies an empty override, so the trusted
# checker must load only the committed policy contract in its working tree.
real_env=(
  "CI_WORKFLOW_PATH=${workflow}"
  "CI_SOURCE_SHA=${source_sha}"
  CI_CONTROL_REPOSITORY=Moh-Bakr/Taurine-CI
  "CI_CONTROL_SHA=${control_sha}"
  CI_CONTROL_REF=refs/heads/main
  CI_DISPATCH_CONTRACT_JSON=''
  CI_GENERATE_ONLY=true
  "CI_NORMALIZED_INPUTS=$(jq -cn --arg sha "${source_sha}" '{source_sha:$sha}')"
)
real_key="$(env "${real_env[@]}" ruby .github/policy/dispatch-identity.rb)"
[[ "${real_key}" == "${defaults_key}" ]] || {
  echo 'dispatch identity did not load the committed contract when the pinned override was empty' >&2
  exit 1
}
real_env[6]=CI_GENERATE_ONLY=false
real_env+=("CI_DISPATCH_KEY=${real_key}")
real_output="$(env "${real_env[@]}" ruby .github/policy/dispatch-identity.rb)"
[[ "${real_output}" == CI_DISPATCH_IDENTITY=* ]] || {
  echo 'dispatch identity failed with the exact pinned workflow environment' >&2
  exit 1
}

expect_reject() {
  local label="$1" expected="$2" output status
  shift 2
  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e
  [[ "${status}" -ne 0 && "${output}" == "CI_DISPATCH_IDENTITY_ERROR=${expected}" ]] || {
    echo "${label}: invalid dispatch identity was not rejected with a fixed error class" >&2
    exit 1
  }
}

expect_reject 'mismatched key' key_mismatch \
  env "${base_env[@]}" "CI_NORMALIZED_INPUTS=$(jq -cn --arg sha "${source_sha}" '{source_sha:$sha}')" \
  CI_DISPATCH_KEY="$(printf '0%.0s' {1..64})" ruby .github/policy/dispatch-identity.rb

expect_reject 'source mismatch' source_mismatch \
  env "${base_env[@]}" CI_SOURCE_SHA=3333333333333333333333333333333333333333 \
  "CI_NORMALIZED_INPUTS=$(jq -cn --arg sha "${source_sha}" '{source_sha:$sha}')" \
  CI_DISPATCH_KEY="${defaults_key}" ruby .github/policy/dispatch-identity.rb

expect_reject 'control repository mismatch' context_invalid \
  env "${base_env[@]}" CI_CONTROL_REPOSITORY=Unreviewed/Repository \
  "CI_NORMALIZED_INPUTS=$(jq -cn --arg sha "${source_sha}" '{source_sha:$sha}')" \
  CI_DISPATCH_KEY="${defaults_key}" ruby .github/policy/dispatch-identity.rb

expect_reject 'control ref mismatch' context_invalid \
  env "${base_env[@]}" CI_CONTROL_REF=refs/heads/feature \
  "CI_NORMALIZED_INPUTS=$(jq -cn --arg sha "${source_sha}" '{source_sha:$sha}')" \
  CI_DISPATCH_KEY="${defaults_key}" ruby .github/policy/dispatch-identity.rb

expect_reject 'malformed input JSON' contract_invalid \
  env "${base_env[@]}" CI_NORMALIZED_INPUTS='not-json' \
  CI_DISPATCH_KEY="${defaults_key}" ruby .github/policy/dispatch-identity.rb

expect_reject 'unreviewed workflow' workflow_invalid \
  env "${base_env[@]}" CI_WORKFLOW_PATH=.github/workflows/untrusted.yml \
  "CI_NORMALIZED_INPUTS=$(jq -cn --arg sha "${source_sha}" '{source_sha:$sha}')" \
  CI_DISPATCH_KEY="${defaults_key}" ruby .github/policy/dispatch-identity.rb

sentinel='PUBLIC-SYNTHETIC-DO-NOT-ECHO'
expect_reject 'unknown input' inputs_invalid \
  env "${base_env[@]}" "CI_NORMALIZED_INPUTS=$(jq -cn --arg sha "${source_sha}" --arg leak "${sentinel}" '{source_sha:$sha,unexpected:$leak}')" \
  CI_DISPATCH_KEY="${defaults_key}" ruby .github/policy/dispatch-identity.rb

engine_workflow=.github/workflows/live-proofs.yml
engine_base=(
  "CI_DISPATCH_CONTRACT_JSON=${matrix}"
  "CI_WORKFLOW_PATH=${engine_workflow}"
  "CI_SOURCE_SHA=${source_sha}"
  CI_CONTROL_REPOSITORY=Moh-Bakr/Taurine-CI
  "CI_CONTROL_SHA=${control_sha}"
  CI_CONTROL_REF=refs/heads/main
)
engine_key="$(env "${engine_base[@]}" "CI_NORMALIZED_INPUTS=$(jq -cn --arg sha "${source_sha}" '{source_sha:$sha,engine:"postgres, doris"}')" CI_GENERATE_ONLY=true ruby .github/policy/dispatch-identity.rb)"
engine_all_key="$(env "${engine_base[@]}" "CI_NORMALIZED_INPUTS=$(jq -cn --arg sha "${source_sha}" '{source_sha:$sha,engine:"all"}')" CI_GENERATE_ONLY=true ruby .github/policy/dispatch-identity.rb)"
engine_roster="$(jq -r '.dispatch_contracts.workflows[".github/workflows/live-proofs.yml"].inputs.engine.options | join(",")' .github/ci-matrix.json)"
engine_roster_key="$(env "${engine_base[@]}" "CI_NORMALIZED_INPUTS=$(jq -cn --arg sha "${source_sha}" --arg engines "${engine_roster}" '{source_sha:$sha,engine:$engines}')" CI_GENERATE_ONLY=true ruby .github/policy/dispatch-identity.rb)"
[[ "${engine_all_key}" == "${engine_roster_key}" ]] || {
  echo 'all engines and the explicit complete roster produced different dispatch identities' >&2
  exit 1
}
engine_output="$(env "${engine_base[@]}" "CI_NORMALIZED_INPUTS=$(jq -cn --arg sha "${source_sha}" '{source_sha:$sha,engine:"postgres, doris"}')" "CI_DISPATCH_KEY=${engine_key}" ruby .github/policy/dispatch-identity.rb)"
[[ "${engine_output}" == *'"engine":"doris,postgres"'* ]] || {
  echo 'engine selection was not canonicalized to the reviewed roster order' >&2
  exit 1
}
set +e
bad_engine_output="$(env "${engine_base[@]}" "CI_NORMALIZED_INPUTS=$(jq -cn --arg sha "${source_sha}" --arg leak "${sentinel}" '{source_sha:$sha,engine:$leak}')" CI_GENERATE_ONLY=true ruby .github/policy/dispatch-identity.rb 2>&1)"
bad_engine_status=$?
set -e
[[ "${bad_engine_status}" -ne 0 && "${bad_engine_output}" == 'CI_DISPATCH_IDENTITY_ERROR=inputs_invalid' && "${bad_engine_output}" != *"${sentinel}"* ]] || {
  echo 'unreviewed engine value was not rejected without echoing the value' >&2
  exit 1
}
set +e
duplicate_engine_output="$(env "${engine_base[@]}" "CI_NORMALIZED_INPUTS=$(jq -cn --arg sha "${source_sha}" '{source_sha:$sha,engine:"postgres,postgres"}')" CI_GENERATE_ONLY=true ruby .github/policy/dispatch-identity.rb 2>&1)"
duplicate_engine_status=$?
set -e
[[ "${duplicate_engine_status}" -ne 0 && "${duplicate_engine_output}" == 'CI_DISPATCH_IDENTITY_ERROR=inputs_invalid' ]] || {
  echo 'duplicate engine selections were not rejected' >&2
  exit 1
}

echo 'dispatch identity: canonical defaults, typed inputs, source/control binding and fixed errors passed'
