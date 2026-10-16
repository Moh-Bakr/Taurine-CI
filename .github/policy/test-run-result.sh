#!/usr/bin/env bash
# Exercise the run-result action's explicit selection contract using synthetic job API data.
set -euo pipefail
work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/run-result-test.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
mkdir -p "${work}/bin"

ruby -ryaml -e 'action = YAML.safe_load(File.read(".github/actions/run-result/action.yml"), aliases: false); run = action["runs"]["steps"][0]["run"]; File.write(ARGV.fetch(0), run)' "${work}/run.sh"
cat > "${work}/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat "${JOBS_JSON}"
SH
chmod +x "${work}/bin/gh"

run_result() {
  local mode="$1" expected="$2" jobs="$3" base="${4:-}" required="${5:-[]}" source="${6:-0123456789012345678901234567890123456789}" output status
  printf '%s\n' "${jobs}" > "${work}/jobs.json"
  : > "${work}/summary.md"
  output="$(PATH="${work}/bin:${PATH}" GH_TOKEN=test JOBS_JSON="${work}/jobs.json" \
    GITHUB_REPOSITORY=example/control GITHUB_RUN_ID=42 GITHUB_STEP_SUMMARY="${work}/summary.md" \
    LABEL=Fixture EXPECTED="${expected}" REQUIRED="${required}" \
    NAME_PATTERN='^Fixture (?<concern>.+)$' REQUESTED_SOURCE_SHA="${source}" \
    BASE_SHA="${base}" SELECTION_MODE="${mode}" BLOCKING_FAILURES="${BLOCKING_FAILURES:-0}" bash "${work}/run.sh" 2>&1)" && status=0 || status=$?
  printf '%s\n%s' "${status}" "${output}"
}

all_success='{"jobs":[{"name":"Fixture alpha","conclusion":"success"}]}'
partial_all="$(run_result partial '["alpha"]' "${all_success}")"
[[ "${partial_all}" == *$'\nFixture: PASS (partial)'* ]] || { echo 'partial selection was promoted to full' >&2; exit 1; }
full_all="$(run_result full '["alpha"]' "${all_success}")"
[[ "${full_all}" == *$'\nFixture: PASS (full)'* ]] || { echo 'full mode did not pass a complete expected set' >&2; exit 1; }
full_missing="$(run_result full '["alpha","beta"]' "${all_success}")"
[[ "${full_missing}" == 1$'\n'* ]] || { echo 'full mode accepted a missing expected concern' >&2; exit 1; }
partial_base="$(run_result full '["alpha"]' "${all_success}" 0123456789012345678901234567890123456789)"
[[ "${partial_base}" == 1$'\n'* ]] || { echo 'full mode accepted a base-SHA dispatch' >&2; exit 1; }
failed_job='{"jobs":[{"name":"Fixture alpha","conclusion":"failure"}]}'
partial_failed="$(run_result partial '["alpha"]' "${failed_job}")"
[[ "${partial_failed}" == 1$'\n'* ]] || { echo 'partial mode accepted a failed concern' >&2; exit 1; }
# A failed untrusted cache scope audit never prints a passing verdict, in either mode.
blocked="$(BLOCKING_FAILURES=1 run_result full '["alpha"]' "${all_success}")"
[[ "${blocked}" == 1$'\n'* && "${blocked}" == *'FAIL (the untrusted cache scope audit failed)'* && "${blocked}" != *'PASS'* ]] || { echo 'a failed audit printed or allowed a passing verdict' >&2; exit 1; }
grep -qF 'untrusted cache scope audit | FAILED' "${work}/summary.md" || { echo 'a failed audit is not in the summary table' >&2; exit 1; }
blocked_partial="$(BLOCKING_FAILURES=2 run_result partial '["alpha"]' "${all_success}")"
[[ "${blocked_partial}" == 1$'\n'* && "${blocked_partial}" != *'PASS'* ]] || { echo 'a failed audit passed in partial mode' >&2; exit 1; }
clean="$(BLOCKING_FAILURES=0 run_result full '["alpha"]' "${all_success}")"
[[ "${clean}" == *$'\nFixture: PASS (full)'* ]] || { echo 'a zero blocking count must not change the verdict' >&2; exit 1; }
for bad in x -1 1.5 ' 1'; do
  invalid="$(BLOCKING_FAILURES="${bad}" run_result full '["alpha"]' "${all_success}")"
  [[ "${invalid}" == 1$'\n'* && "${invalid}" == *'invalid blocking-failures count'* ]] || { echo "an invalid blocking count '${bad}' was accepted" >&2; exit 1; }
done
duplicate_jobs='{"jobs":[{"name":"Fixture alpha","conclusion":"success"},{"name":"Fixture alpha","conclusion":"failure"}]}'
duplicate="$(run_result partial '["alpha"]' "${duplicate_jobs}")"
[[ "${duplicate}" == 1$'\n'*'run-result rejected duplicate matching jobs'* ]] || { echo 'duplicate concern jobs were silently collapsed' >&2; exit 1; }
unexpected_job='{"jobs":[{"name":"Fixture alpha","conclusion":"success"},{"name":"Fixture beta","conclusion":"success"}]}'
unexpected="$(run_result partial '["alpha"]' "${unexpected_job}")"
[[ "${unexpected}" == 1$'\n'*'run-result rejected an unexpected matching job'* ]] || { echo 'unexpected matching job was accepted' >&2; exit 1; }
required_skipped='{"jobs":[{"name":"Fixture alpha","conclusion":"skipped"}]}'
required="$(run_result partial '["alpha"]' "${required_skipped}" '' '["alpha"]')"
[[ "${required}" == 1$'\n'* ]] || { echo 'required skipped concern was accepted' >&2; exit 1; }
queued_job='{"jobs":[{"name":"Fixture alpha","conclusion":null}]}'
queued="$(run_result partial '["alpha"]' "${queued_job}")"
[[ "${queued}" == 1$'\n'* ]] || { echo 'queued job was accepted as complete' >&2; exit 1; }
canceled_job='{"jobs":[{"name":"Fixture alpha","conclusion":"cancelled"}]}'
canceled="$(run_result partial '["alpha"]' "${canceled_job}")"
[[ "${canceled}" == 1$'\n'* ]] || { echo 'cancelled job was accepted' >&2; exit 1; }
zero_jobs='{"jobs":[]}'
zero="$(run_result partial '["alpha"]' "${zero_jobs}")"
[[ "${zero}" == 1$'\n'* ]] || { echo 'zero-job result was accepted' >&2; exit 1; }
malformed="$(run_result partial 'not-json' "${all_success}")"
[[ "${malformed}" == 1$'\n'*'run-result rejected invalid concern contract'* ]] || { echo 'malformed concern input was accepted' >&2; exit 1; }
unknown_required="$(run_result partial '["alpha"]' "${all_success}" '' '["beta"]')"
[[ "${unknown_required}" == 1$'\n'*'run-result rejected invalid concern contract'* ]] || { echo 'required concern outside the expected set was accepted' >&2; exit 1; }
empty_expected="$(run_result partial '[]' "${zero_jobs}")"
[[ "${empty_expected}" == 1$'\n'*'run-result rejected invalid concern contract'* ]] || { echo 'empty expected concern set was accepted' >&2; exit 1; }
unknown_mode="$(run_result auto '["alpha"]' "${all_success}")"
[[ "${unknown_mode}" == 1$'\n'*'run-result rejected invalid selection mode'* ]] || { echo 'unknown selection mode was accepted' >&2; exit 1; }
bad_source="$(run_result full '["alpha"]' "${all_success}" '' '[]' shortsha)"
[[ "${bad_source}" == 1$'\n'*'run-result rejected invalid source identity'* ]] || { echo 'short source SHA was accepted' >&2; exit 1; }
echo 'run-result: explicit full/partial selection fixtures passed'
