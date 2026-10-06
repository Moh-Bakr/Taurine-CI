#!/usr/bin/env bash
# Behavioural fixtures for the environment-preflight composite, which every workflow that
# enters source-read on dispatch runs first (check-universal.rb rule 6). The reviewed step is
# extracted from the composite and run against a stub `curl` that answers the environment read
# and the deployment-branch-policy read. It must ask exactly for this repository's source-read
# environment and its branch policies, and pass only when the environment uses custom branch
# policies that are exactly the branches main and untrusted. "Protected branches only" is
# refused: for environments GitHub counts only classic branch protection rules as protected, not
# rulesets, so with rulesets it lets every branch deploy. A 404 (with the setup message), any
# other status, a failed request, a wildcard, a tag policy, a third branch and a missing branch
# are refused. Run from the repository root.
set -euo pipefail

workflow=.github/actions/environment-preflight/action.yml
step='Verify the source-read deployment branches'
dir="$(mktemp -d)"
trap 'rm -rf "${dir}"' EXIT
api=https://api.invalid

fail() { echo "pre-flight fixture failed: $*" >&2; [[ -f "${dir}/stdout" ]] && cat "${dir}/stdout" >&2; exit 1; }

ruby .github/policy/extract-step.rb "${workflow}" "${step}" run > "${dir}/step.sh"
printf '%s' '{"${{ inputs.github-token }}":"fixture-job-token"}' > "${dir}/map.json"
step_env=()
while IFS= read -r line; do step_env+=("${line}"); done < <(ruby .github/policy/extract-step.rb "${workflow}" "${step}" env "${dir}/map.json")
(( ${#step_env[@]} > 0 )) || fail 'the step environment could not be read'

mkdir -p "${dir}/bin"
cat > "${dir}/bin/curl" <<'STUB'
#!/usr/bin/env bash
url='' out=''
while (( $# )); do
  case "$1" in
    --output|-o) out="$2"; shift ;;
    -H|--retry|--retry-delay|--retry-max-time|--write-out|-w) shift ;;
    http*) url="$1" ;;
  esac
  shift
done
printf '%s\n' "${url}" >> "${FAKE_LOG}"
case "${url}" in
  */deployment-branch-policies*) code="${FAKE_POLICIES_CODE}" body="${FAKE_POLICIES}" rc="${FAKE_POLICIES_RC:-0}" ;;
  *) code="${FAKE_CODE}" body="${FAKE_BODY}" rc="${FAKE_RC:-0}" ;;
esac
[[ -n "${out}" ]] && printf '%s' "${body}" > "${out}"
printf '%s' "${code}"
exit "${rc}"
STUB
chmod +x "${dir}/bin/curl"

environment_body() { printf '{"name":"source-read","deployment_branch_policy":%s}' "$1"; }
custom='{"protected_branches":false,"custom_branch_policies":true}'
policies() { # type:name ...
  local items='' entry
  for entry in "$@"; do items+="${items:+,}{\"id\":1,\"name\":\"${entry#*:}\",\"type\":\"${entry%%:*}\"}"; done
  printf '{"total_count":%s,"branch_policies":[%s]}' "$#" "${items}"
}
preflight_run() {
  rm -rf "${dir}/runner"; mkdir -p "${dir}/runner"; : > "${dir}/calls"
  set +e
  env "${step_env[@]}" PATH="${dir}/bin:${PATH}" GITHUB_API_URL="${api}" GITHUB_REPOSITORY=Moh-Bakr/Taurine-CI \
    RUNNER_TEMP="${dir}/runner" GITHUB_STEP_SUMMARY="${dir}/runner/summary" FAKE_LOG="${dir}/calls" \
    FAKE_CODE=200 FAKE_BODY="$(environment_body "${custom}")" \
    FAKE_POLICIES_CODE=200 FAKE_POLICIES="$(policies branch:main branch:untrusted)" "$@" \
    bash --noprofile --norc -eo pipefail "${dir}/step.sh" > "${dir}/stdout" 2>&1
  rc=$?
  set -e
}
expect_pass() { [[ "${rc}" -eq 0 ]] || fail "$1: should pass, exited ${rc}"; }
expect_refused() {
  [[ "${rc}" -ne 0 ]] || fail "$1: should be refused, passed"
  [[ -z "${2:-}" ]] || grep -qF -- "$2" "${dir}/stdout" || fail "$1: the refusal does not say '$2'"
}
environment_url="${api}/repos/Moh-Bakr/Taurine-CI/environments/source-read"

preflight_run
expect_pass 'custom branch policies, exactly main and untrusted'
[[ "$(cat "${dir}/calls")" == "${environment_url}
${environment_url}/deployment-branch-policies?per_page=100" ]] || fail "the pre-flight read
$(cat "${dir}/calls")
not exactly the environment and its branch policies"
preflight_run FAKE_POLICIES="$(policies branch:untrusted branch:main)"
expect_pass 'the two branches in either order'

preflight_run FAKE_CODE=404 FAKE_BODY='{"message":"Not Found"}'
expect_refused 'a missing environment (404)' 'does not exist'
for code in 401 403 500 502; do
  preflight_run FAKE_CODE="${code}" FAKE_BODY='{}'
  expect_refused "environment HTTP ${code}" "could not be read (HTTP ${code})"
done
preflight_run FAKE_CODE=000 FAKE_RC=7 FAKE_BODY=''
expect_refused 'a failed environment request' 'could not be read (HTTP 000)'
# "Protected branches only" is now refused: rulesets do not count as protected branches.
preflight_run FAKE_BODY="$(environment_body '{"protected_branches":true,"custom_branch_policies":false}')"
expect_refused 'protected branches only' 'rulesets do not count as protected branches'
for branch_policy in null '{"protected_branches":true,"custom_branch_policies":true}' \
  '{"protected_branches":false,"custom_branch_policies":false}' '{}'; do
  preflight_run FAKE_BODY="$(environment_body "${branch_policy}")"
  expect_refused "branch policy ${branch_policy}" 'exactly main and untrusted'
done
preflight_run FAKE_BODY='not json'
expect_refused 'an unreadable environment'

for code in 403 404 500; do
  preflight_run FAKE_POLICIES_CODE="${code}" FAKE_POLICIES='{}'
  expect_refused "branch policies HTTP ${code}" "branch policies could not be read (HTTP ${code})"
done
preflight_run FAKE_POLICIES_CODE=000 FAKE_POLICIES_RC=7 FAKE_POLICIES=''
expect_refused 'a failed branch-policy request' 'branch policies could not be read (HTTP 000)'
for set in 'branch:main' 'branch:untrusted' 'branch:*' 'branch:main branch:*' 'branch:main branch:untrusted branch:feature' \
  'branch:main branch:untrusted tag:v*' 'branch:main tag:untrusted' 'branch:main branch:untrusted/*' 'branch:main branch:main'; do
  # shellcheck disable=SC2086
  preflight_run FAKE_POLICIES="$(policies ${set})"
  expect_refused "branch policies ${set}" 'exactly the branches main and untrusted'
done
preflight_run FAKE_POLICIES='{"total_count":3,"branch_policies":[{"name":"main","type":"branch"},{"name":"untrusted","type":"branch"}]}'
expect_refused 'a truncated policy list' 'exactly the branches main and untrusted'
preflight_run FAKE_POLICIES='{"total_count":2,"branch_policies":[{"name":"main"},{"name":"untrusted"}]}'
expect_refused 'policies without a type' 'exactly the branches main and untrusted'
preflight_run FAKE_POLICIES='not json'
expect_refused 'unreadable branch policies' 'exactly the branches main and untrusted'

echo 'pre-flight fixtures: only custom branch policies of exactly main and untrusted pass; protected-branches-only, wildcards, tags, other branches, 404s, other statuses and failed requests are refused'
