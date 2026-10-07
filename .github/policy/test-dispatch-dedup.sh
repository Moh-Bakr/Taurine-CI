#!/usr/bin/env bash
# Synthetic-only checks for the duplicate-dispatch guard: refuses an existing
# queued or in-progress identity, never evicts it, fails closed when blind.
set -euo pipefail

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/dispatch-dedup-test.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
mkdir -p "${work}/bin"
cat > "${work}/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Synthetic gh: answers from ${STUB_ANSWER}, or fails when ${STUB_FAIL} is set.
set -euo pipefail
if [[ "${STUB_FAIL:-}" == 'true' ]]; then
  echo 'stub gh: unavailable' >&2
  exit 1
fi
printf '%s' "${STUB_ANSWER:-[]}"
STUB
chmod +x "${work}/bin/gh"

source_sha=1111111111111111111111111111111111111111
dispatch_key="$(printf 'a%.0s' $(seq 64))"
other_key="$(printf 'b%.0s' $(seq 64))"
run_url="https://github.com/Moh-Bakr/Taurine-CI/actions/runs/999"

run_guard() {
  env \
    "PATH=${work}/bin:${PATH}" \
    "CI_WORKFLOW_PATH=.github/workflows/linux-validation.yml" \
    "CI_SOURCE_SHA=${source_sha}" \
    "CI_DISPATCH_KEY=${dispatch_key}" \
    CI_RUN_ID=42 \
    GH_REPO=Moh-Bakr/Taurine-CI \
    ruby .github/policy/refuse-duplicate-dispatch.rb
}

runs_json() {
  # each arg: "id|title|url"
  jq -cn '[$ARGS.positional[] | split("|") | {databaseId: (.[0] | tonumber), displayTitle: .[1], url: .[2]}]' --args "$@"
}

expect_refuse() {
  local label="$1" output status
  set +e
  output="$(run_guard 2>&1)"
  status=$?
  set -e
  [[ "${status}" -ne 0 && "${output}" == *"dispatch dedup: "* && "${output}" == *"already exists"* ]] || {
    echo "${label}: guard did not refuse" >&2
    exit 1
  }
}

# A queued run with the same identity is refused, naming it.
STUB_ANSWER="$(runs_json "999|Taurine validation ${source_sha} ${dispatch_key}|${run_url}")" \
  expect_refuse 'queued duplicate'

# An in-progress duplicate is refused the same way; the guard never cancels.
STUB_ANSWER="$(runs_json "1000|Taurine validation ${source_sha} ${dispatch_key}|${run_url}")" \
  expect_refuse 'in-progress duplicate'

# A queued run with the same key but a different source SHA is a different
# identity (a stale key cannot mask a new dispatch), so it is allowed.
STUB_ANSWER="$(runs_json "1001|Taurine validation 3333333333333333333333333333333333333333 ${dispatch_key}|${run_url}")" \
  run_guard >/dev/null

# A completed duplicate does not block a fresh dispatch of the same identity.
STUB_ANSWER='[]' run_guard >/dev/null

# The guard's own run, other identities and malformed titles are skipped.
STUB_ANSWER="$(runs_json \
  "42|Taurine validation ${source_sha} ${dispatch_key}|${run_url}" \
  "1002|Taurine validation ${source_sha} ${other_key}|${run_url}" \
  "1003|a completely unrelated title|${run_url}")" \
  run_guard >/dev/null

# An unreadable run list refuses the dispatch instead of starting blind.
set +e
export STUB_ANSWER='[]' STUB_FAIL=true
output="$(run_guard 2>&1)"
status=$?
unset STUB_ANSWER STUB_FAIL
set -e
[[ "${status}" -ne 0 && "${output}" == *"refusing to dispatch blind"* ]] || {
  echo 'unreadable run list: guard did not fail closed' >&2
  exit 1
}

# Malformed guard inputs are refused.
set +e
output="$(env PATH="${work}/bin:${PATH}" CI_WORKFLOW_PATH=.github/workflows/linux-validation.yml \
  CI_SOURCE_SHA=short CI_DISPATCH_KEY="${dispatch_key}" CI_RUN_ID=42 GH_REPO=Moh-Bakr/Taurine-CI \
  ruby .github/policy/refuse-duplicate-dispatch.rb 2>&1)"
status=$?
set -e
[[ "${status}" -ne 0 && "${output}" == *"guard inputs are malformed"* ]] || {
  echo 'malformed inputs: guard did not fail closed' >&2
  exit 1
}

echo 'dispatch dedup: duplicate refusal, non-eviction and fail-closed fixtures passed'
