#!/usr/bin/env bash
# Behavioural fixtures for the two steps that hold the private-source token: the
# source-checkout composite's verify-and-revoke step and the weekly resolver. Each reviewed script is extracted and run against stub `curl`, `git`
# and `date` on PATH, which record every call. On every path (success, a failed checkout, an
# identity mismatch, a SHA mismatch, an unreachable SHA, a failed revoke) the step must call
# DELETE /installation/token with the source token, call exactly the reviewed endpoints in order,
# write only the reviewed outputs, and fail unless every check passed; main must refuse a SHA
# with no protected ancestry. A grep cannot prove any of this: an early `exit 0`, a re-pointed
# endpoint or a disabled refusal keeps every string in place. Run from the repository root.
set -euo pipefail

dir="$(mktemp -d)"
trap 'rm -rf "${dir}"' EXIT
api=https://api.invalid
token=fixture-source-token-0123456789
sha=0123456789abcdef0123456789abcdef01234567
other=fedcba9876543210fedcba9876543210fedcba98

fail() { echo "revoke fixture failed (${target:-setup}): $*" >&2; [[ -f "${dir}/stdout" ]] && cat "${dir}/stdout" >&2; exit 1; }

mkdir -p "${dir}/bin"
cat > "${dir}/bin/curl" <<'STUB'
#!/usr/bin/env bash
method=GET url='' auth=''
while (( $# )); do
  case "$1" in
    -X) method="$2"; shift ;;
    -H) [[ "$2" == Authorization:* ]] && auth="$2"; shift ;;
    --retry|--retry-delay|--retry-max-time|--output|-o|--write-out|-w) shift ;;
    http*) url="$1" ;;
  esac
  shift
done
printf '%s %s|%s\n' "${method}" "${url}" "${auth}" >> "${FAKE_LOG}"
case "${method} ${url}" in
  "DELETE ${GITHUB_API_URL}/installation/token") exit "${FAKE_REVOKE_RC:-0}" ;;
  "GET ${GITHUB_API_URL}/repos/"*"/commits?"*) printf '[{"sha":"%s"}]\n' "${FAKE_BASE_SHA}" ;;
  "GET ${GITHUB_API_URL}/repos/"*/contents/*) printf '[[package]]\nname = "openssl-src"\nversion = "300.5.0+3.5.0"\n' ;;
  "GET ${GITHUB_API_URL}/repos/"*/commits/*)
    [[ "${FAKE_COMMIT:-ok}" == fail ]] && exit 22
    printf '{"sha":"%s"}\n' "${FAKE_API_SHA}" ;;
  "GET ${GITHUB_API_URL}/repos/"*/compare/*)
    branch="${url##*/compare/}"; branch="${branch%%...*}"
    var="FAKE_COMPARE_${branch}"; status="${!var:-diverged}"
    [[ "${status}" == fail ]] && exit 22
    printf '{"status":"%s"}\n' "${status}" ;;
  "GET ${GITHUB_API_URL}/repositories/"*|"GET ${GITHUB_API_URL}/repos/"*)
    [[ "${FAKE_IDENTITY:-ok}" == fail ]] && exit 22
    printf '{"id":%s,"owner":{"login":"%s"},"name":"%s"}\n' "${FAKE_ID}" "${FAKE_OWNER}" "${FAKE_NAME}" ;;
  *) exit 22 ;;
esac
STUB
cat > "${dir}/bin/git" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" rev-parse "*) [[ -n "${FAKE_HEAD:-}" ]] || exit 128; printf '%s\n' "${FAKE_HEAD}" ;;
  *) exit 0 ;;
esac
STUB
# GNU date's -d is not on every machine that runs the policy; the resolver's one use is pinned.
cat > "${dir}/bin/date" <<'STUB'
#!/usr/bin/env bash
case " $* " in *" -d "*) printf '2026-09-29T00:00:00Z\n' ;; *) exec /bin/date "$@" ;; esac
STUB
chmod +x "${dir}/bin/curl" "${dir}/bin/git" "${dir}/bin/date"

# load FILE STEP WANT_ENV_JSON MAP_JSON: extracts the step, checks its env is exactly the
# reviewed map (a new input is unreviewed), and resolves the environment it runs with.
load() {
  local file="$1" name="$2" want="$3" got line
  workflow="${file}" step="${name}"
  ruby .github/policy/extract-step.rb "${file}" "${name}" run > "${dir}/step.sh"
  got="$(ruby -ryaml -rjson -e 'd = YAML.safe_load(File.read(ARGV[0])); s = (d.dig("runs", "steps") || d["jobs"].values.flat_map { |j| j["steps"] || [] }).find { |x| x["name"] == ARGV[1] }; puts JSON.generate(s["env"] || {})' "${file}" "${name}")"
  [[ "${got}" == "${want}" ]] || fail "the step's env is not the reviewed map: ${got}"
  printf '%s' "$4" > "${dir}/map.json"
  step_env=()
  while IFS= read -r line; do step_env+=("${line}"); done < <(ruby .github/policy/extract-step.rb "${file}" "${name}" env "${dir}/map.json")
}
# revoke_run REF [KEY=VALUE ...]: runs the step as GitHub does (bash -e -o pipefail).
revoke_run() {
  local ref="$1"; shift
  rm -rf "${dir}/runner"; mkdir -p "${dir}/runner/_runner_file_commands"
  output="${dir}/runner/_runner_file_commands/set_output_fixture"
  printf 'stale=output\n' > "${output}"
  : > "${dir}/calls"
  set +e
  env "${step_env[@]}" PATH="${dir}/bin:${PATH}" GITHUB_REF="${ref}" GITHUB_API_URL="${api}" \
    RUNNER_TEMP="${dir}/runner" GITHUB_OUTPUT="${output}" GITHUB_STEP_SUMMARY="${dir}/runner/summary" FAKE_LOG="${dir}/calls" \
    FAKE_ID="${repo_id}" FAKE_OWNER="${owner}" FAKE_NAME="${name}" FAKE_HEAD="${sha}" FAKE_API_SHA="${sha}" FAKE_BASE_SHA="${other}" \
    "$@" bash --noprofile --norc -eo pipefail "${dir}/step.sh" > "${dir}/stdout" 2>&1
  rc=$?
  set -e
}
# expect LABEL RC(0|fail) OUTPUT(exact text, or - to skip) CALL...: the exit status, the output
# file and the exact call sequence; the revoke must carry the source token, and the token never
# reaches a log.
expect() {
  local label="$1" want_rc="$2" want_output="$3"; shift 3
  if [[ "${want_rc}" == 0 ]]; then
    [[ "${rc}" -eq 0 ]] || fail "${label}: should pass, exited ${rc}"
  else
    [[ "${rc}" -ne 0 ]] || fail "${label}: should fail, passed"
  fi
  local want; want="$(printf '%s\n' "$@")"
  [[ "$(cut -d'|' -f1 "${dir}/calls")" == "${want}" ]] \
    || fail "${label}: calls were
$(cut -d'|' -f1 "${dir}/calls")
wanted
${want}"
  if grep -q '^DELETE ' "${dir}/calls"; then
    [[ "$(grep '^DELETE ' "${dir}/calls" | cut -d'|' -f2)" == "Authorization: Bearer ${token}" ]] || fail "${label}: the revoke did not carry the source token"
  fi
  if [[ "${want_output}" != - ]]; then
    [[ "$(cat "${output}")" == "${want_output}" ]] || fail "${label}: output was '$(cat "${output}")', wanted '${want_output}'"
  fi
  if grep -qF "${token}" "${dir}/stdout"; then fail "${label}: the token reached the log"; fi
  return 0
}
compare_call() { printf 'GET %s/repos/%s/%s/compare/%s...%s?per_page=1' "${api}" "${owner}" "${name}" "$1" "${sha}"; }

# The source-checkout verify-and-revoke step: branches develop, uat, main are
# asked in order until one holds the SHA.
verify_scenarios() {
  local identity commit revoke d u m
  identity="GET ${api}/repositories/${repo_id}"
  commit="GET ${api}/repos/${owner}/${name}/commits/${sha}"
  revoke="DELETE ${api}/installation/token"
  d="$(compare_call develop)" u="$(compare_call uat)" m="$(compare_call main)"

  revoke_run refs/heads/main FAKE_COMPARE_develop=identical
  expect 'main, SHA on develop' 0 protected-ancestor=true "${identity}" "${commit}" "${d}" "${revoke}"
  revoke_run refs/heads/main FAKE_COMPARE_main=behind
  expect 'main, SHA behind main' 0 protected-ancestor=true "${identity}" "${commit}" "${d}" "${u}" "${m}" "${revoke}"
  revoke_run refs/heads/main FAKE_COMPARE_uat=identical REQUESTED_SOURCE_SHA="$(printf '%s' "${sha}" | tr '[:lower:]' '[:upper:]')"
  expect 'main, upper-case SHA on uat' 0 protected-ancestor=true "${identity}" "${commit}" "${d}" "${u}" "${revoke}"
  for unreachable in diverged ahead fail; do
    revoke_run refs/heads/main FAKE_COMPARE_develop="${unreachable}" FAKE_COMPARE_uat="${unreachable}" FAKE_COMPARE_main="${unreachable}"
    expect "main refuses an unreachable SHA (${unreachable})" fail protected-ancestor=false "${identity}" "${commit}" "${d}" "${u}" "${m}" "${revoke}"
    grep -qF 'so main refuses it' "${dir}/stdout" || fail "main, ${unreachable}: no refusal message"
    revoke_run refs/heads/untrusted FAKE_COMPARE_develop="${unreachable}" FAKE_COMPARE_uat="${unreachable}" FAKE_COMPARE_main="${unreachable}"
    expect "untrusted runs an unreachable SHA (${unreachable}) without protected ancestry" 0 protected-ancestor=false "${identity}" "${commit}" "${d}" "${u}" "${m}" "${revoke}"
  done
  for ref in refs/heads/main refs/heads/untrusted; do
    revoke_run "${ref}" FAKE_HEAD=
    expect "${ref}: checkout failed" fail protected-ancestor=false "${identity}" "${commit}" "${revoke}"
    revoke_run "${ref}" FAKE_HEAD="${other}"
    expect "${ref}: checked-out SHA mismatch" fail protected-ancestor=false "${identity}" "${commit}" "${revoke}"
    revoke_run "${ref}" FAKE_API_SHA="${other}"
    expect "${ref}: API SHA mismatch" fail protected-ancestor=false "${identity}" "${commit}" "${revoke}"
    revoke_run "${ref}" FAKE_COMMIT=fail
    expect "${ref}: SHA not in the repository" fail protected-ancestor=false "${identity}" "${commit}" "${revoke}"
    revoke_run "${ref}" FAKE_IDENTITY=fail
    expect "${ref}: identity unreadable" fail protected-ancestor=false "${identity}" "${commit}" "${revoke}"
    revoke_run "${ref}" FAKE_ID=1
    expect "${ref}: identity id mismatch" fail protected-ancestor=false "${identity}" "${commit}" "${revoke}"
    revoke_run "${ref}" FAKE_OWNER=someone-else
    expect "${ref}: identity owner mismatch" fail protected-ancestor=false "${identity}" "${commit}" "${revoke}"
    revoke_run "${ref}" FAKE_NAME=other-repo
    expect "${ref}: identity name mismatch" fail protected-ancestor=false "${identity}" "${commit}" "${revoke}"
    revoke_run "${ref}" FAKE_REVOKE_RC=22 FAKE_COMPARE_develop=identical
    expect "${ref}: revoke failed" fail - "${identity}" "${commit}" "${d}" "${revoke}"
  done
  revoke_run refs/heads/main SOURCE_TOKEN=
  expect 'no token minted' fail -
}

target=source-checkout
repo_id=1330267721 owner=Moh-Bakr name=Taurine
load .github/actions/source-checkout/action.yml 'Verify identity, exact checkout, and revoke source token' \
  '{"SOURCE_TOKEN":"${{ steps.mint.outputs.token }}","REQUESTED_SOURCE_SHA":"${{ inputs.source-sha }}","SOURCE_REPOSITORY_ID":"${{ inputs.repository-id }}","SOURCE_REPOSITORY_OWNER":"${{ inputs.repository-owner }}","SOURCE_REPOSITORY_NAME":"${{ inputs.repository-name }}","CHECKOUT_PATH":"${{ inputs.path }}","CHECK_PROTECTED_ANCESTRY":"${{ inputs.check-protected-ancestry }}"}' \
  '{"${{ steps.mint.outputs.token }}":"'"${token}"'","${{ inputs.source-sha }}":"'"${sha}"'","${{ inputs.repository-id }}":"'"${repo_id}"'","${{ inputs.repository-owner }}":"'"${owner}"'","${{ inputs.repository-name }}":"'"${name}"'","${{ inputs.path }}":"src","${{ inputs.check-protected-ancestry }}":"true"}'
verify_scenarios
# The ancestry question is optional on untrusted (no cache), and always asked on main.
revoke_run refs/heads/untrusted CHECK_PROTECTED_ANCESTRY=false FAKE_COMPARE_develop=identical
expect 'untrusted without the ancestry question' 0 protected-ancestor=false "GET ${api}/repositories/${repo_id}" "GET ${api}/repos/${owner}/${name}/commits/${sha}" "DELETE ${api}/installation/token"
revoke_run refs/heads/main CHECK_PROTECTED_ANCESTRY=false FAKE_COMPARE_develop=identical
expect 'main always asks the ancestry question' 0 protected-ancestor=true "GET ${api}/repositories/${repo_id}" "GET ${api}/repos/${owner}/${name}/commits/${sha}" "$(compare_call develop)" "DELETE ${api}/installation/token"

# The weekly resolver: identity, the develop and main tips, last week's develop tip, the three
# lock files, revoke;
# outputs only after every check passed.
target=weekly-resolver
repo_id=1330267721 owner=Moh-Bakr name=Taurine
load .github/workflows/weekly-validation.yml 'Resolve the develop tip and revoke the source token' \
  '{"SOURCE_TOKEN":"${{ steps.source-token.outputs.token }}"}' \
  '{"${{ steps.source-token.outputs.token }}":"'"${token}"'"}'
identity="GET ${api}/repositories/${repo_id}"
tip="GET ${api}/repos/${owner}/${name}/commits/develop"
main_tip="GET ${api}/repos/${owner}/${name}/commits/main"
week="GET ${api}/repos/${owner}/${name}/commits?sha=develop&until=2026-09-29T00:00:00Z&per_page=1"
locks=()
for lock in Cargo.lock taurine-backend/dbx-core/Cargo.lock taurine-backend/dbx-mongo-shell/Cargo.lock; do
  locks+=("GET ${api}/repos/${owner}/${name}/contents/${lock}?ref=${sha}")
done
revoke="DELETE ${api}/installation/token"
revoke_run refs/heads/main
expect 'resolved' 0 "sha=${sha}
base=${other}
main_sha=${sha}
openssl_locked=300.5.0+3.5.0,300.5.0+3.5.0,300.5.0+3.5.0" "${identity}" "${tip}" "${main_tip}" "${week}" "${locks[@]}" "${revoke}"
for bad in FAKE_IDENTITY=fail FAKE_ID=1 FAKE_OWNER=someone-else FAKE_NAME=other-repo; do
  revoke_run refs/heads/main "${bad}"
  expect "identity check (${bad})" fail '' "${identity}" "${revoke}"
done
revoke_run refs/heads/main FAKE_COMMIT=fail
expect 'develop tip unreadable' fail '' "${identity}" "${tip}" "${revoke}"
revoke_run refs/heads/main FAKE_API_SHA=not-a-sha
expect 'develop tip malformed' fail '' "${identity}" "${tip}" "${revoke}"
revoke_run refs/heads/main FAKE_REVOKE_RC=22
expect 'revoke failed' fail '' "${identity}" "${tip}" "${main_tip}" "${week}" "${locks[@]}" "${revoke}"
revoke_run refs/heads/main SOURCE_TOKEN=
expect 'no token minted' fail -
echo 'revoke fixtures: source-checkout and the weekly resolver revoke on every path with the source token, call only the reviewed endpoints, and main refuses an unprotected SHA'
