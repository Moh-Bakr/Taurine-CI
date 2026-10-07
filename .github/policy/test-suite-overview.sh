#!/usr/bin/env bash
# Synthetic-only checks for the aggregate feature-suite overview: shard
# merging, feature rows, reviewed-field enforcement and honest empty state.
set -euo pipefail

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/suite-overview-test.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
matrix="$(pwd)/.github/ci-matrix.json"

# One sanitized vitest projection per shard and two regression-shard
# projections of the Playwright group, exported under the run's
# evidence_<concern> names. The spec argument maps suite id to
# "executed:env_skipped"; suites without a spec are absent shard-local rows.
projection() {
  ruby -rjson -e '
    matrix = JSON.parse(File.read(ARGV.fetch(0)))
    group_id, specs = ARGV.fetch(1), JSON.parse(ARGV.fetch(2))
    group = matrix["suite_catalog"]["coverage_requirements"].find { |row| row["id"] == group_id }
    rows = group["candidate_suite_ids"].map do |id|
      base = { "id" => id, "discovered_count" => 0, "owned_count" => 0, "executed_count" => 0,
               "compiled_count" => 0, "ignored_count" => 0, "quarantined_count" => 0,
               "env_skipped_count" => 0, "status" => "absent", "error_class" => "none" }
      spec = specs[id]
      next base unless spec
      executed, env_skipped = spec.split(":").map(&:to_i)
      if env_skipped > 0
        base.merge("discovered_count" => 1, "owned_count" => 1, "env_skipped_count" => env_skipped,
                   "status" => "blocked", "error_class" => "environment_skip")
      else
        base.merge("discovered_count" => executed, "owned_count" => executed, "executed_count" => executed,
                   "status" => "passed", "error_class" => "none")
      end
    end
    projection = {
      "schema_version" => 1, "phase" => "execution",
      "source_sha" => "1111111111111111111111111111111111111111",
      "control_sha" => "2222222222222222222222222222222222222222",
      "manifest_digest" => "3" * 64, "catalog_digest" => "4" * 64,
      "selection_digest" => "5" * 64, "collection_digest" => "6" * 64,
      "collection_complete" => true, "coverage_requirement_id" => group_id,
      "runner_id" => group["runner"], "config_id" => group["config"], "tier" => group["tier"],
      "platform" => "linux", "selection_mode" => "full",
      "selected_suite_ids" => group["candidate_suite_ids"],
      "active_suite_ids" => rows.select { |r| r["owned_count"] > 0 }.map { |r| r["id"] },
      "absent_suite_ids" => rows.select { |r| r["owned_count"] == 0 }.map { |r| r["id"] },
      "status" => rows.any? { |r| r["status"] == "blocked" } ? "blocked" : "passed",
      "suites" => rows
    }
    print JSON.generate(projection)
  ' "${matrix}" "$1" "$2"
}

evidence="$(jq -cn \
  --arg shard1 "$(projection desktop-vitest-default-linux '{"desktop.vitest.default.rest":"2:0","desktop.vitest.default.notes":"2:0"}')" \
  --arg shard2 "$(projection desktop-vitest-default-linux '{"desktop.vitest.default.git":"1:0"}')" \
  --arg regression1 "$(projection desktop-playwright-regression-linux '{"desktop.playwright.regression.rest":"1:0"}')" \
  --arg regression2 "$(projection desktop-playwright-regression-linux '{"desktop.playwright.regression.rest":"1:0"}')" \
  '{"evidence_desktop-shard-1": $shard1, "evidence_desktop-shard-2": $shard2,
    "evidence_e2e-regression-1": $regression1, "evidence_e2e-regression-2": $regression2,
    "evidence_empty": ""}')"

overview="$(printf '%s' "${evidence}" | ruby .github/policy/suite-overview.rb "${matrix}" -)"
[[ "${overview}" == *"## Feature-suite overview"* ]] || {
  echo 'overview: heading missing' >&2
  exit 1
}
# The two vitest shards merge into one desktop group section; the two
# regression shards merge into the Playwright group section.
[[ "$(grep -c '^### ' <<<"${overview}")" -eq 2 ]] || {
  echo 'overview: expected exactly two coverage-group sections' >&2
  exit 1
}
vitest_section="$(sed -n '/^### desktop-vitest-default-linux/,$p' <<<"${overview}")"
rest_row="$(grep '^| rest |' <<<"${vitest_section}" | head -1)"
[[ "${rest_row}" == *"| 1 | 2 | 0 | 0 | 0 | 0 | passed |"* ]] || {
  echo "overview: rest feature row wrong: ${rest_row}" >&2
  exit 1
}
git_row="$(grep '^| git |' <<<"${vitest_section}" | head -1)"
[[ "${git_row}" == *"| 1 | 1 | 0 | 0 | 0 | 0 | passed |"* ]] || {
  echo "overview: git feature row wrong: ${git_row}" >&2
  exit 1
}
[[ "$(grep -c '2 collected shard(s)' <<<"${overview}")" -eq 2 ]] || {
  echo 'overview: shard projections were not merged' >&2
  exit 1
}

# An unreviewed field anywhere in a projection is refused.
tampered="$(jq -c '.["evidence_desktop-shard-1"] |= (fromjson | .raw_report_excerpt = "SYNTHETIC-PRIVATE" | tojson)' <<<"${evidence}")"
if printf '%s' "${tampered}" | ruby .github/policy/suite-overview.rb "${matrix}" - >/dev/null 2>&1; then
  echo 'overview: accepted a projection with an unreviewed field' >&2
  exit 1
fi

# Projections of one run that disagree on the source SHA are refused.
conflicting="$(jq -c '.["evidence_desktop-shard-2"] |= (fromjson | .source_sha = "1111111111111111111111111111111111111112" | tojson)' <<<"${evidence}")"
if printf '%s' "${conflicting}" | ruby .github/policy/suite-overview.rb "${matrix}" - >/dev/null 2>&1; then
  echo 'overview: accepted conflicting source identities' >&2
  exit 1
fi

# No projections at all renders the honest empty state and succeeds.
empty_overview="$(printf '{}' | ruby .github/policy/suite-overview.rb "${matrix}" -)"
[[ "${empty_overview}" == *"No suite evidence was collected"* ]] || {
  echo 'overview: empty run did not render the honest no-evidence state' >&2
  exit 1
}

echo 'suite overview: shard merge, feature rows, reviewed fields and empty state passed'
