#!/usr/bin/env bash
# Synthetic-only checks for the exact suite-selection calculator: exact
# map+graph selection, conservative consumer closure and fail-closed to full.
set -euo pipefail

matrix="$(pwd)/.github/ci-matrix.json"
catalog_digest="$(ruby -rdigest -rjson -e '
  sort = lambda { |v| v.is_a?(Hash) ? v.keys.sort.to_h { |k| [k, sort.call(v.fetch(k))] } : v.is_a?(Array) ? v.map { |x| sort.call(x) } : v }
  puts Digest::SHA256.hexdigest(JSON.generate(sort.call(JSON.parse(File.read(ARGV.fetch(0))).fetch("suite_catalog")), ascii_only: true))
' "${matrix}")"
graph_digest="$(ruby -rdigest -rjson -e '
  sort = lambda { |v| v.is_a?(Hash) ? v.keys.sort.to_h { |k| [k, sort.call(v.fetch(k))] } : v.is_a?(Array) ? v.map { |x| sort.call(x) } : v }
  puts Digest::SHA256.hexdigest(JSON.generate(sort.call(JSON.parse(File.read(ARGV.fetch(0))).fetch("feature_graph")), ascii_only: true))
' "${matrix}")"

select_suites() {
  ruby .github/policy/select-suites.rb "${matrix}" "$1"
}

request() {
  # selection_mode changed_features base_sha base_valid unknown_paths shared_surface [catalog_digest] [graph_digest]
  local mode="$1" features="$2" base="$3" base_valid="$4" unknown="$5" shared="$6"
  jq -cn --arg mode "${mode}" --argjson features "${features}" --arg base "${base}" \
    --argjson base_valid "${base_valid}" --argjson unknown "${unknown}" --argjson shared "${shared}" \
    --arg catalog "${7:-${catalog_digest}}" --arg graph "${8:-${graph_digest}}" \
    '{selection_mode:$mode, changed_feature_ids:$features, base_sha:$base, base_valid:$base_valid,
      unknown_paths:$unknown, shared_surface:$shared, expected_catalog_digest:$catalog,
      expected_feature_graph_digest:$graph}'
}

expect_reject() {
  local label="$1"
  if select_suites "$2" >/dev/null 2>&1; then
    echo "${label}: malformed request produced a selection instead of an error" >&2
    exit 1
  fi
}

# Full mode selects every candidate suite of every supported group.
full="$(select_suites <(request full '[]' '' true false false))"
jq -e '.complete == true and (.reasons | sort) == ["full_requested"] and .selection_mode == "full" and
  ([.groups[] | .selected_suite_ids | length] | all(. > 0))' <<<"${full}" >/dev/null
full_count="$(jq '[.groups[].selected_suite_ids | length] | add' <<<"${full}")"
total_supported="$(jq '[.suite_catalog.coverage_requirements[] | select(.availability == "supported") | .candidate_suite_ids | length] | add' "${matrix}")"
[[ "${full_count}" -eq "${total_supported}" ]] || {
  echo "full mode selected ${full_count} of ${total_supported} candidate suites" >&2
  exit 1
}

# A partial change to one leaf feature selects exactly its owning suites plus
# the conservative consumer closure (rest -> automation, ai -> integration),
# and never marks the result complete.
partial="$(select_suites <(request partial '["rest"]' 2222222222222222222222222222222222222222 true false false))"
jq -e '.complete == false and .reasons == ["feature_closure"] and .selection_mode == "partial"' <<<"${partial}" >/dev/null
for group in $(jq -r '.groups | keys[]' <<<"${partial}"); do
  selected="$(jq -r --arg g "${group}" '.groups[$g].selected_suite_ids | join(" ")' <<<"${partial}")"
  case "${group}" in
    desktop-vitest-default-linux)
      [[ "${selected}" == *"desktop.vitest.default.rest"* && "${selected}" == *"desktop.vitest.default.automation"* &&
         "${selected}" == *"desktop.vitest.default.ai"* && "${selected}" == *"desktop.vitest.default.integration"* &&
         "${selected}" != *"desktop.vitest.default.notes"* ]] || {
        echo "rest closure wrong in ${group}: ${selected}" >&2
        exit 1
      }
      ;;
    desktop-playwright-regression-linux)
      [[ "${selected}" == *"desktop.playwright.regression.rest"* && "${selected}" != *"desktop.playwright.regression.notes"* ]] || {
        echo "rest closure wrong in ${group}: ${selected}" >&2
        exit 1
      }
      ;;
  esac
done
[[ "$(jq '[.groups[].selected_suite_ids | length] | add' <<<"${partial}")" -lt "${full_count}" ]] || {
  echo 'partial selection was not narrower than full' >&2
  exit 1
}

# A transitive consumer closes over intermediate features: import-export
# selects notes, database and, through the graph, ai and integration.
transitive="$(select_suites <(request partial '["import-export"]' 2222222222222222222222222222222222222222 true false false))"
vitest_selected="$(jq -r '.groups["desktop-vitest-default-linux"].selected_suite_ids | join(" ")' <<<"${transitive}")"
[[ "${vitest_selected}" == *"desktop.vitest.default.notes"* && "${vitest_selected}" == *"desktop.vitest.default.database"* &&
   "${vitest_selected}" == *"desktop.vitest.default.ai"* && "${vitest_selected}" == *"desktop.vitest.default.integration"* &&
   "${vitest_selected}" != *"desktop.vitest.default.vault"* ]] || {
  echo "import-export closure wrong: ${vitest_selected}" >&2
  exit 1
}

# Fail closed: unknown paths, an invalid base, a shared surface and changed
# selector inputs each force the complete set with a fixed reason; a missing
# base is refused the same way.
for case_spec in \
  'unknown_paths|[] 2222222222222222222222222222222222222222 true true false|unknown_paths' \
  'invalid_base|[] 2222222222222222222222222222222222222222 false false false|invalid_base' \
  'shared_surface|[] 2222222222222222222222222222222222222222 true false true|shared_surface'; do
  label="${case_spec%%|*}"
  args="${case_spec#*|}"
  args="${args%%|*}"
  expected_reason="${case_spec##*|}"
  result="$(select_suites <(request partial ${args}))"
  jq -e --arg reason "${expected_reason}" '.complete == true and (.reasons | index($reason) != null)' <<<"${result}" >/dev/null
  [[ "$(jq '[.groups[].selected_suite_ids | length] | add' <<<"${result}")" -eq "${full_count}" ]] || {
    echo "${label}: fail-closed result was not the complete set" >&2
    exit 1
  }
done
missing_base="$(select_suites <(request partial '[]' '' true false false))"
jq -e '.complete == true and (.reasons | index("invalid_base") != null)' <<<"${missing_base}" >/dev/null
[[ "$(jq '[.groups[].selected_suite_ids | length] | add' <<<"${missing_base}")" -eq "${full_count}" ]] || {
  echo 'missing base: fail-closed result was not the complete set' >&2
  exit 1
}

stale_catalog="$(select_suites <(request partial '["rest"]' 2222222222222222222222222222222222222222 true false false "$(printf 'a%.0s' $(seq 64))"))"
jq -e '.complete == true and (.reasons | index("selector_inputs_changed") != null)' <<<"${stale_catalog}" >/dev/null
stale_graph="$(select_suites <(request partial '["rest"]' 2222222222222222222222222222222222222222 true false false "${catalog_digest}" "$(printf 'b%.0s' $(seq 64))"))"
jq -e '.complete == true and (.reasons | index("selector_inputs_changed") != null)' <<<"${stale_graph}" >/dev/null

# The selection digest is stable for identical requests and changes when the
# selection changes.
digest_one="$(select_suites <(request partial '["rest"]' 2222222222222222222222222222222222222222 true false false) | jq -r .selection_digest)"
digest_two="$(select_suites <(request partial '["rest"]' 2222222222222222222222222222222222222222 true false false) | jq -r .selection_digest)"
[[ "${digest_one}" == "${digest_two}" && "${digest_one}" =~ ^[0-9a-f]{64}$ ]] || {
  echo 'selection digest was not stable for identical requests' >&2
  exit 1
}
digest_other="$(select_suites <(request partial '["notes"]' 2222222222222222222222222222222222222222 true false false) | jq -r .selection_digest)"
[[ "${digest_other}" != "${digest_one}" ]] || {
  echo 'different selections shared one selection digest' >&2
  exit 1
}

# Malformed requests are errors, never silent reductions.
expect_reject 'missing keys' <(jq -cn '{selection_mode:"partial"}')
expect_reject 'unreviewed mode' <(request partial2 '[]' '' true false false)
expect_reject 'bad feature id' <(request partial '["SYNTHETIC-PRIVATE"]' 2222222222222222222222222222222222222222 true false false)
expect_reject 'bad base sha' <(request partial '[]' 'nope' true false false)
expect_reject 'bad flags' <(request partial '[]' 2222222222222222222222222222222222222222 yes no no 2>/dev/null)

echo 'suite selection: exact closure, conservative fail-closed and digest fixtures passed'
