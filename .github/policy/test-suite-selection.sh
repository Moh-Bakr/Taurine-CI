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

# A partial change to one feature selects exactly its owning suites plus the
# derived consumer closure: everything the reviewed model consumes from it,
# the integration tier, and the tiers that integrate the tier - and never
# marks the result complete. rest's closure reaches notes, vault, sync, git
# and import-export through the reviewed depends_on projection; organization
# consumes nothing of rest's and stays out.
partial="$(select_suites <(request partial '["rest"]' 2222222222222222222222222222222222222222 true false false))"
jq -e '.complete == false and .reasons == ["feature_closure"] and .selection_mode == "partial"' <<<"${partial}" >/dev/null
for group in $(jq -r '.groups | keys[]' <<<"${partial}"); do
  selected="$(jq -r --arg g "${group}" '.groups[$g].selected_suite_ids | join(" ")' <<<"${partial}")"
  case "${group}" in
    desktop-vitest-default-linux)
      [[ "${selected}" == *"desktop.vitest.default.rest"* && "${selected}" == *"desktop.vitest.default.automation"* &&
         "${selected}" == *"desktop.vitest.default.ai"* && "${selected}" == *"desktop.vitest.default.integration"* &&
         "${selected}" == *"desktop.vitest.default.vault"* && "${selected}" == *"desktop.vitest.default.notes"* &&
         "${selected}" == *"desktop.vitest.default.sync"* && "${selected}" == *"desktop.vitest.default.git"* &&
         "${selected}" == *"desktop.vitest.default.import-export"* &&
         "${selected}" != *"desktop.vitest.default.organization"* &&
         "${selected}" != *"desktop.vitest.default.search-navigation"* ]] || {
        echo "rest closure wrong in ${group}: ${selected}" >&2
        exit 1
      }
      ;;
    desktop-playwright-regression-linux)
      [[ "${selected}" == *"desktop.playwright.regression.rest"* && "${selected}" == *"desktop.playwright.regression.notes"* &&
         "${selected}" != *"desktop.playwright.regression.organization"* ]] || {
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

# A transitive consumer closes over intermediate features: a vault change
# selects its direct consumers (notes, sync), their consumers (git through
# sync, import-export through notes) and the integration tier - while
# features the model does not derive from vault stay out.
transitive="$(select_suites <(request partial '["vault"]' 2222222222222222222222222222222222222222 true false false))"
vitest_selected="$(jq -r '.groups["desktop-vitest-default-linux"].selected_suite_ids | join(" ")' <<<"${transitive}")"
[[ "${vitest_selected}" == *"desktop.vitest.default.notes"* && "${vitest_selected}" == *"desktop.vitest.default.sync"* &&
   "${vitest_selected}" == *"desktop.vitest.default.git"* && "${vitest_selected}" == *"desktop.vitest.default.import-export"* &&
   "${vitest_selected}" == *"desktop.vitest.default.integration"* &&
   "${vitest_selected}" != *"desktop.vitest.default.rest"* && "${vitest_selected}" != *"desktop.vitest.default.ai"* &&
   "${vitest_selected}" != *"desktop.vitest.default.organization"* ]] || {
  echo "vault closure wrong: ${vitest_selected}" >&2
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

# A well-formed feature ID the reviewed catalog and graph do not define is an
# error naming unknown_feature, never a confident reduced selection.
unknown_request="$(mktemp "${RUNNER_TEMP:-/tmp}/unknown-feature.XXXXXX")"
request partial '["not-a-feature"]' 2222222222222222222222222222222222222222 true false false > "${unknown_request}"
expect_reject 'unknown feature id' "${unknown_request}"
unknown_error="$(select_suites "${unknown_request}" 2>&1 1>/dev/null || true)"
[[ "${unknown_error}" == *'unknown_feature'* ]] || {
  echo "unknown feature id failed with an unnamed error: ${unknown_error}" >&2
  exit 1
}

# The empty-set sibling (delta review #2, D8): a well-formed partial request
# that names no changed feature and carries no broadening reason is a named
# error (selection_empty), never a confident all-zero reduction. An empty set
# beside a broadening reason keeps selecting the complete set (proven by the
# fail-closed cases above, which all pass []).
empty_request="$(mktemp "${RUNNER_TEMP:-/tmp}/selection-empty.XXXXXX")"
request partial '[]' 2222222222222222222222222222222222222222 true false false > "${empty_request}"
expect_reject 'empty changed feature set' "${empty_request}"
empty_error="$(select_suites "${empty_request}" 2>&1 1>/dev/null || true)"
[[ "${empty_error}" == *'selection_empty'* ]] || {
  echo "empty changed feature set failed with an unnamed error: ${empty_error}" >&2
  exit 1
}

# The dispatch review mode word travels inside the request. The reviewed value
# `shadow` never changes the selection - the same closure, the same per-group
# sets, the same selection digest - while any other word (including the
# not-yet-wired `enforce`) is an error, so an unsupported mode fails the
# dispatcher back to the complete set instead of reducing anything.
shadow="$(select_suites <(jq -c '. + {review:"shadow"}' <(request partial '["rest"]' 2222222222222222222222222222222222222222 true false false)))"
jq -e '.complete == false and .reasons == ["feature_closure"] and .selection_mode == "partial"' <<<"${shadow}" >/dev/null
[[ "$(jq -r .selection_digest <<<"${shadow}")" == "${digest_one}" ]] || {
  echo 'the shadow review word changed the selection or its digest' >&2
  exit 1
}
for mode in enforce report fully shadowy; do
  expect_reject "unreviewed review mode ${mode}" \
    <(jq -c --arg mode "${mode}" '. + {review:$mode}' <(request partial '["rest"]' 2222222222222222222222222222222222222222 true false false))
done

echo 'suite selection: exact closure, conservative fail-closed and digest fixtures passed'
