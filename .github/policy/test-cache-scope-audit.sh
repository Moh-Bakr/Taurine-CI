#!/usr/bin/env bash
# Behavioural fixtures for the cache-scope-audit composite (docs/untrusted-readonly-cache.md,
# section 3.3). The reviewed step is extracted and run against a stub `curl` that answers the cache
# listing. It must ask this repository's cache API for exactly the untrusted ref with the job
# token, pass only on a readable answer whose total is exactly zero, and refuse a non-empty scope
# (of any key), an unreadable or non-numeric answer, a failed request, any other status, and any
# ref but untrusted. It must never print a cache key. Run from the repository root.
set -euo pipefail

composite=.github/actions/cache-scope-audit/action.yml
step='Refuse any entry in the untrusted cache scope'
dir="$(mktemp -d)"
trap 'rm -rf "${dir}"' EXIT
api=https://api.invalid

fail() { echo "cache-scope-audit fixture failed: $*" >&2; [[ -f "${dir}/stdout" ]] && cat "${dir}/stdout" >&2; exit 1; }

ruby .github/policy/extract-step.rb "${composite}" "${step}" run > "${dir}/step.sh"
printf '%s' '{"${{ inputs.github-token }}":"fixture-job-token","${{ inputs.phase }}":"before"}' > "${dir}/map.json"
step_env=()
while IFS= read -r line; do step_env+=("${line}"); done < <(ruby .github/policy/extract-step.rb "${composite}" "${step}" env "${dir}/map.json")
(( ${#step_env[@]} > 0 )) || fail 'the step environment could not be read'

mkdir -p "${dir}/bin"
cat > "${dir}/bin/curl" <<'STUB'
#!/usr/bin/env bash
url='' out='' auth=''
while (( $# )); do
  case "$1" in
    --output|-o) out="$2"; shift ;;
    -H) case "$2" in Authorization:*) auth="$2" ;; esac; shift ;;
    --retry|--retry-delay|--retry-max-time|--write-out|-w) shift ;;
    http*) url="$1" ;;
  esac
  shift
done
printf '%s\t%s\n' "${url}" "${auth}" >> "${FAKE_LOG}"
[[ -n "${out}" ]] && printf '%s' "${FAKE_BODY}" > "${out}"
printf '%s' "${FAKE_CODE}"
exit "${FAKE_RC:-0}"
STUB
chmod +x "${dir}/bin/curl"

run() { # extra env assignments
  rm -rf "${dir}/runner"; mkdir -p "${dir}/runner"; : > "${dir}/calls"
  set +e
  env "${step_env[@]}" PATH="${dir}/bin:${PATH}" GITHUB_API_URL="${api}" GITHUB_REPOSITORY=Moh-Bakr/Taurine-CI GITHUB_REF=refs/heads/untrusted \
    RUNNER_TEMP="${dir}/runner" FAKE_LOG="${dir}/calls" FAKE_CODE=200 FAKE_BODY='{"total_count":0,"actions_caches":[]}' "$@" \
    bash --noprofile --norc -eo pipefail "${dir}/step.sh" > "${dir}/stdout" 2>&1
  rc=$?
  set -e
}
expect_pass() { [[ "${rc}" -eq 0 ]] || fail "$1: should pass, exited ${rc}"; }
expect_refused() { [[ "${rc}" -ne 0 ]] || fail "$1: should be refused but passed"; }

run
expect_pass 'an empty untrusted scope'
[[ "$(wc -l < "${dir}/calls" | tr -d ' ')" == 1 ]] || fail 'exactly one request is expected'
grep -qF "${api}/repos/Moh-Bakr/Taurine-CI/actions/caches?ref=refs/heads/untrusted&per_page=1" "${dir}/calls" || fail 'it must list this repository'"'"'s untrusted cache scope'
grep -qF 'Bearer fixture-job-token' "${dir}/calls" || fail 'it must use the job token'
grep -qF 'untrusted cache scope: empty' "${dir}/stdout" || fail 'it must say the scope is empty'

run FAKE_BODY='{"total_count":1,"actions_caches":[{"id":1,"key":"cargo-target-v1-secretish-key"}]}'
expect_refused 'one entry'
grep -qF 'holds 1 entries' "${dir}/stdout" || fail 'it must report the count'
grep -qF 'secretish' "${dir}/stdout" && fail 'it must never print a cache key'
run FAKE_BODY='{"total_count":7,"actions_caches":[]}'
expect_refused 'several entries'
run FAKE_BODY='{"actions_caches":[]}'
expect_refused 'no total_count'
run FAKE_BODY='{"total_count":"0"}'
expect_refused 'a string total'
run FAKE_BODY='not json'
expect_refused 'unparsable output'
run FAKE_CODE=403
expect_refused 'a 403'
run FAKE_CODE=404
expect_refused 'a 404'
run FAKE_CODE=500
expect_refused 'a 500'
run FAKE_RC=22 FAKE_CODE=000
expect_refused 'a failed request'
run GITHUB_REF=refs/heads/main
expect_refused 'the main ref'
[[ ! -s "${dir}/calls" ]] || fail 'a wrong ref must be refused before any request'
echo 'cache-scope-audit fixtures: only a readable, empty untrusted scope passes; entries, bad answers, other statuses and other refs are refused'
