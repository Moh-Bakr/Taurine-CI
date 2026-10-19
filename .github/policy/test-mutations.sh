#!/usr/bin/env bash
# Mutation tests: each weakening below once passed the policy (an independent review showed it).
# The repository's .github/ and docs/ are copied, one weakening is applied as a literal edit, and
# the offline policy (every check that needs no network) must reject it. The last case proves the
# base-policy pass of validate-public-changes.yml: a pull request that weakens a check and
# exploits it in the same change passes its own copy of the policy, and fails the base's.
# Run from the repository root.
#
# MUTATION_POLICY=<dir> runs every case against another copy of .github/policy (for example an
# older commit's) and MUTATION_REPORT=1 lists each verdict instead of stopping at the first
# mutation that is not rejected.
#
# The cases are independent, so they run in parallel: MUTATION_JOBS=<n> bounds the concurrency
# (default: the CPU count; 1 is strictly sequential). Each case gets its own directory, tree, log
# and RUNNER_TEMP, and shares no mutable state with another. Results print in declaration order,
# never completion order. A case that crashes, is killed or aborts (a stale mutation whose text is
# not found) fails the run loudly, and so does a result count that differs from the declarations.
set -euo pipefail
# Never inherit the skip from the caller's environment: only reject_file sets it, for one call.
unset SKIP_STRUCTURE

src="${PWD}"
root="$(mktemp -d)"
dir="${root}"
jobs_dir="${root}/jobs"
mkdir -p "${jobs_dir}"
# Some fixture suites write under RUNNER_TEMP, which only a runner sets; each case gets its own.
export RUNNER_TEMP="${RUNNER_TEMP:-${root}/runner-temp}"
mkdir -p "${RUNNER_TEMP}"
policy_source="${MUTATION_POLICY:-${src}/.github/policy}"
missed=0
max_jobs="${MUTATION_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}"
[[ "${max_jobs}" =~ ^[1-9][0-9]*$ ]] || { echo "MUTATION_JOBS must be a positive integer, got '${max_jobs}'" >&2; exit 1; }
total=0      # cases declared
next=1       # the next case whose result is printed
live=()      # indexes of running cases
pids=()      # pids[index]: the worker of that case
labels=()    # labels[index]: what the case is called, for failures that print no verdict

# The scheduler. spawn LABEL FUNCTION ARGS...: start a case once a slot is free, and print every
# finished case in declaration order as soon as all the cases before it have finished.
kill_tree() {
  local child
  for child in $(pgrep -P "$1" 2>/dev/null || true); do kill_tree "${child}"; done
  kill "$1" 2>/dev/null || true
}
cleanup() {
  local i
  for i in ${live[@]+"${live[@]}"}; do kill_tree "${pids[${i}]}"; done
  rm -rf "${root}"
}
trap cleanup EXIT
# reap: drop every worker that is gone; a worker that left no result was killed or crashed.
reap() {
  local i keep=()
  for i in ${live[@]+"${live[@]}"}; do
    if kill -0 "${pids[${i}]}" 2>/dev/null; then keep+=("${i}"); continue; fi
    if [[ ! -f "${jobs_dir}/${i}.rc" ]]; then
      echo 'the worker died without reporting a result' >>"${jobs_dir}/${i}.err"
      echo 255 >"${jobs_dir}/${i}.rc"
    fi
  done
  live=(${keep[@]+"${keep[@]}"})
}
wait_one() { wait -n 2>/dev/null || true; reap; }
# flush: print each finished case, in order. A harness failure always stops the run; a policy miss
# (status 3) stops it too unless MUTATION_REPORT is set, which keeps going and counts them.
flush() {
  local rc
  while (( next <= total )) && [[ -f "${jobs_dir}/${next}.rc" ]]; do
    rc="$(cat "${jobs_dir}/${next}.rc")"
    [[ "${rc}" =~ ^[0-9]+$ ]] || rc=255
    cat "${jobs_dir}/${next}.out"; cat "${jobs_dir}/${next}.err" >&2
    rm -rf "${jobs_dir:?}/${next}"
    if (( rc == 3 )); then
      missed=$((missed + 1))
      [[ -n "${MUTATION_REPORT:-}" ]] || exit 1
    elif (( rc != 0 )); then
      echo "mutation harness failure: ${labels[${next}]} (status ${rc})" >&2
      exit 1
    fi
    next=$((next + 1))
  done
}
spawn() {
  local label="$1" idx jd; shift
  while (( ${#live[@]} >= max_jobs )); do wait_one; flush; done
  total=$((total + 1)); idx="${total}"; jd="${jobs_dir}/${idx}"
  labels[idx]="${label}"
  mkdir -p "${jd}"
  (
    set +e
    ( set -e; dir="${jd}"; export RUNNER_TEMP="${jd}/runner-temp"; mkdir -p "${RUNNER_TEMP}"; "$@" ) >"${jd}.out" 2>"${jd}.err"
    echo "$?" >"${jd}.rc.tmp"; mv "${jd}.rc.tmp" "${jd}.rc"
  ) &
  pids[idx]=$!
  live+=("${idx}")
}
# drain: wait for every case, print the rest, and prove that each declared case reported.
drain() {
  while (( ${#live[@]} > 0 )); do wait_one; flush; done
  flush
  local done_count
  done_count="$(find "${jobs_dir}" -maxdepth 1 -name '*.rc' | wc -l | tr -d ' ')"
  if (( next != total + 1 || total == 0 || done_count != total )); then
    echo "mutation harness failure: ${total} case(s) declared, $((next - 1)) reported" >&2
    exit 1
  fi
}

# The offline policy, in the order the cheap checks fail first. Prints the first check that
# rejects the tree and returns non-zero; returns zero when every check passes.
offline_policy() {
  local check
  for check in check-universal.rb check-structure.rb check-strict-structure.rb check-policy-steps.rb test-preflight.sh test-cache-scope-audit.sh test-run-result.sh test-revoke.sh check-workflows.sh check-sizes.sh test-policy.sh test-sanitizers.sh test-extractors.sh check-concern-table.sh test-selector.sh check-tools.sh check-egress-allowlist.sh; do
    [[ -f ".github/policy/${check}" ]] || continue
    # The structure manifest pins the tree's shape, so a case that rewrites a workflow to test another
    # rule (reject_file below) sets SKIP_STRUCTURE; the manifest has its own fixtures in test-structure.sh.
    [[ "${check}" == check-structure.rb && -n "${SKIP_STRUCTURE:-}" ]] && continue
    local rc=0
    case "${check}" in
      *.rb) ruby ".github/policy/${check}" >>"${dir}/log" 2>&1 || rc=$? ;;
      *) bash ".github/policy/${check}" >>"${dir}/log" 2>&1 || rc=$? ;;
    esac
    (( rc == 0 )) && continue
    crashed "${check}" "${rc}"
    printf '%s' "${check}"; return 1
  done
}
# crashed CHECK STATUS: a check killed by a signal or unable to run (status 126 and up) proves
# nothing about the tree, so it must never count as a rejection. Mark the case; verdict and miss
# turn the mark into a harness failure.
crashed() {
  (( $2 >= 126 )) || return 0
  echo "${1} did not run to a verdict (status ${2})" >>"${dir}/crash"
}
# harness_crash: fail this case as a harness failure (status 2) when a check crashed.
harness_crash() {
  [[ -f "${dir}/crash" ]] || return 0
  cat "${dir}/crash" >&2
  return 2
}
# fresh_tree [policy-dir]: a copy of this repository's tree with the given policy (default: the
# policy under test).
fresh_tree() {
  rm -rf "${dir}/tree"; mkdir -p "${dir}/tree"
  cp -R "${src}/.github" "${src}/docs" "${dir}/tree/"
  rm -rf "${dir}/tree/.github/policy"; cp -R "${1:-${policy_source}}" "${dir}/tree/.github/policy"
}
# swap FILE OLD NEW: replace the first occurrence of OLD, failing if it is not there (a stale
# mutation must not pass by testing nothing).
swap() {
  OLD="$2" NEW="$3" ruby -e 's = File.read(ARGV[0]); i = s.index(ENV["OLD"]) or abort("mutation text not found in #{ARGV[0]}: #{ENV["OLD"][0, 80]}"); s[i, ENV["OLD"].length] = ENV["NEW"]; File.write(ARGV[0], s)' "${dir}/tree/$1"
}
# miss LOG-TAIL-MESSAGE: a case the policy did not reject. Status 3 tells the scheduler it is a
# policy miss, which MUTATION_REPORT may continue past, and not a harness failure.
miss() {
  harness_crash
  [[ -n "${MUTATION_REPORT:-}" ]] || tail -n 20 "${dir}/log" >&2
  return 3
}
verdict() {
  local label="$1" by="$2"
  harness_crash
  if [[ -n "${by}" ]]; then
    echo "rejected  ${label}  (by ${by})"
  else
    echo "PASSED    ${label}" >&2
    miss
  fi
}
# mutation LABEL FILE OLD NEW [FILE OLD NEW ...]: apply every edit, then expect a rejection.
_mutation() {
  local label="$1" by=''; shift
  fresh_tree
  while (( $# )); do swap "$1" "$2" "$3"; shift 3; done
  : > "${dir}/log"
  by="$(cd "${dir}/tree" && offline_policy)" || true
  verdict "${label}" "${by}"
}
mutation() { spawn "$1" _mutation "$@"; }

# The unmutated tree must pass, or every rejection below would prove nothing.
fresh_tree; : > "${dir}/log"
if ! (cd "${dir}/tree" && offline_policy >/dev/null); then
  echo 'the unmutated tree fails the offline policy:' >&2; tail -n 20 "${dir}/log" >&2; exit 1
fi

composite=.github/actions/source-checkout/action.yml
weekly=.github/workflows/weekly-validation.yml
linux=.github/workflows/linux-validation.yml
linux_concern=.github/workflows/linux-validation-concern.yml
preflight=.github/actions/environment-preflight/action.yml
public=.github/workflows/validate-public-changes.yml
# The policy job's timeout is a reviewed budget that may change, so the mutations that anchor on the
# job's shape read the current value from the tree instead of pinning it: the first job shaped
# like the anchor (the one swap() edits), and the one guarded by always().
pol_to="$(ruby -e 'm = File.read(ARGV[0]).match(/    runs-on: ubuntu-24\.04\n    timeout-minutes: (\d+)\n    steps:/) or abort("no policy job shape"); puts m[1]' "${src}/${public}")"
pol_to_guarded="$(ruby -e 'm = File.read(ARGV[0]).match(/    if: \$\{\{ always\(\) \}\}\n    runs-on: ubuntu-24\.04\n    timeout-minutes: (\d+)\n/) or abort("no guarded policy job shape"); puts m[1]' "${src}/${public}")"
composite_revoke='        if ! api -X DELETE "${GITHUB_API_URL}/installation/token"; then'
weekly_revoke='          if ! api -X DELETE "${GITHUB_API_URL}/installation/token"; then'

mutation '1. the Linux concern no longer needs the pre-flight job' "${linux}" '    needs: [validate-input, select]' '    needs: [select]'
mutation '1. source-read no longer needs the pre-flight job' .github/workflows/source-read.yml '    needs: validate-input
' ''
mutation '1. the Linux concern runs past a failed pre-flight' "${linux}" "needs.validate-input.result == 'success' &&" ''
mutation '2. exit 0 at the start of the composite verify-and-revoke' "${composite}" '        set +x
        failed=0
' '        set +x
        exit 0
        failed=0
'
mutation '2. exit 0 just before the composite revoke' "${composite}" "${composite_revoke}" "        exit 0
${composite_revoke}"
mutation '2. the composite revoke made best-effort' "${composite}" "          echo 'Source token revocation failed; refusing to execute project code' >&2
          failed=1" "          echo 'Source token revocation failed; refusing to execute project code' >&2"
mutation '2. exit 0 just before the weekly resolver revoke' "${weekly}" "${weekly_revoke}" "          exit 0
${weekly_revoke}"
mutation '3. main refusal disabled in the composite' "${composite}" '        if [[ "${GITHUB_REF}" == refs/heads/main && "${failed}" -eq 0 && "${protected_ancestor}" != true ]]; then' \
  '        if [[ "${GITHUB_REF}" == refs/heads/never && "${failed}" -eq 0 && "${protected_ancestor}" != true ]]; then'
mutation '3. main no longer forced to ask the ancestry question' "${composite}" '        [[ "${GITHUB_REF}" == refs/heads/main ]] && CHECK_PROTECTED_ANCESTRY=true
' ''
mutation '3. protected ancestry assumed in the composite' "${composite}" '        protected_ancestor=false
' '        protected_ancestor=true
'
mutation '4. composite identity read from another endpoint' "${composite}" '"${GITHUB_API_URL}/repositories/${SOURCE_REPOSITORY_ID}"' '"${GITHUB_API_URL}/repos/${SOURCE_REPOSITORY_OWNER}/${SOURCE_REPOSITORY_NAME}"'
mutation '4. composite identity id compared with itself' "${composite}" "\"\$(jq -r '.id' <<<\"\${identity}\")\" != \"\${SOURCE_REPOSITORY_ID}\"" "\"\$(jq -r '.id' <<<\"\${identity}\")\" != \"\$(jq -r '.id' <<<\"\${identity}\")\""
mutation '4. a caller points source-checkout at another repository id' .github/workflows/source-read.yml "  SOURCE_REPOSITORY_ID: '1330267721'" "  SOURCE_REPOSITORY_ID: '1377321992'"
mutation '4. a caller passes a literal repository id' .github/workflows/source-read.yml 'repository-id: ${{ env.SOURCE_REPOSITORY_ID }}' "repository-id: '1377321992'"
mutation '5. an extra permission on the composite mint' "${composite}" '        permission-contents: read
' '        permission-contents: read
        permission-secrets: read
'
mutation '5. an extra permission on the weekly resolver mint' "${weekly}" '          permission-contents: read
' '          permission-contents: read
          permission-members: read
'
mutation '6. toJSON(secrets) in the Linux concern' "${linux_concern}" '      - name: Report concern duration
        if: ${{ always() }}
' '      - name: Report concern duration
        if: ${{ always() }}
        env:
          ALL: ${{ toJSON(secrets) }}
'
mutation '6. toJSON(vars) in the public policy workflow' "${public}" '        run: bash .github/policy/check-repository.sh' '        env:
          ALL: ${{ toJSON(vars) }}
        run: bash .github/policy/check-repository.sh'
mutation '6. a bare secrets context passed by the Linux dispatcher' "${linux}" '      SOURCE_READER_PRIVATE_KEY: ${{ secrets.SOURCE_READER_PRIVATE_KEY }}' '      SOURCE_READER_PRIVATE_KEY: ${{ toJSON(secrets) }}'
mutation '7. an unconditional container-root in the Linux concern' "${linux_concern}" "container-root: \${{ inputs.concern == 'e2e-visual' }}" "container-root: 'true'"
mutation '7. an unconditional keep-docker in the live-proof arm' .github/workflows/live-proof-arm.yml "keep-docker: \${{ inputs.engine == 'bastion' }}" "keep-docker: 'true'"
mutation 'untrusted behind main with a later .github/ change accepted (composite)' "${composite}" '              if [[ "${github_changes}" != 0 ]]; then' '              if [[ "${github_changes}" == never ]]; then'
mutation '9. exit 0 at the start of the environment pre-flight' "${preflight}" '        set -euo pipefail
' '        set -euo pipefail
        exit 0
'
mutation '9. protected branches only accepted' "${preflight}" "!= \$'false\\ttrue' ]]; then" "== never ]]; then"
mutation '9. any branch-policy list accepted' "${preflight}" "!= 'branch:main,branch:untrusted' ]]; then" "== never ]]; then"

# 11. Read-only untrusted cache restore, cache-mode and actions: write (docs/untrusted-readonly-cache.md).
cache_prune=.github/workflows/cache-prune.yml
scorecard=.github/workflows/scorecard.yml
mutation '11. cache-mode write-only on the Linux caller' "${linux}" '    uses: ./.github/workflows/linux-validation-concern.yml  # zizmor: ignore[self-repository]' '    cache-mode: write-only
    uses: ./.github/workflows/linux-validation-concern.yml  # zizmor: ignore[self-repository]'
mutation '11. an ungated cache-mode write on the Linux caller' "${linux}" '    uses: ./.github/workflows/linux-validation-concern.yml  # zizmor: ignore[self-repository]' '    cache-mode: write
    uses: ./.github/workflows/linux-validation-concern.yml  # zizmor: ignore[self-repository]'
mutation '11. a workflow-level cache-mode write in the Linux dispatcher' "${linux}" 'permissions: {}
' 'permissions: {}
cache-mode: write
'
mutation '11. cache-mode inside the called Linux concern' "${linux_concern}" '  validate:
    permissions:
      contents: read
    name: Linux ${{ inputs.concern }}' '  validate:
    cache-mode: read
    permissions:
      contents: read
    name: Linux ${{ inputs.concern }}'
mutation '11. a cache restore between the revoke and root removal' "${linux_concern}" '      - name: Remove root before project code' '      - name: Early cache restore
        uses: actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0
        with:
          path: ${{ runner.temp }}/early
          key: early

      - name: Remove root before project code'
mutation '11. the compiled save gated to untrusted' "${linux_concern}" "      - name: Save compiled third-party dependencies
        if: \${{ github.ref == 'refs/heads/main' &&" "      - name: Save compiled third-party dependencies
        if: \${{ github.ref == 'refs/heads/untrusted' &&"
mutation '11. actions: write on the scorecard job' "${scorecard}" '      actions: read' '      actions: write'
mutation '11. cache-prune no longer main-only' "${cache_prune}" " && github.ref == 'refs/heads/main'" ''
mutation '11. cache-prune given the source-read environment' "${cache_prune}" '    runs-on: ubuntu-24.04
' '    environment: source-read
    runs-on: ubuntu-24.04
'
mutation '11. lint.sh ignores every unknown key' .github/policy/lint.sh "-ignore '^unexpected key \"cache-mode\" for \"(job|workflow)\" section\. '" "-ignore 'unexpected key'"

# 12. The caller split, the audit and the explicit cache grants (docs/untrusted-readonly-cache.md, section 4.1).
windows=.github/workflows/windows-validation.yml
audit=.github/actions/cache-scope-audit/action.yml
mutation '12. the Linux untrusted half loses cache-mode read' "${linux}" '    cache-mode: read
    uses: ./.github/workflows/linux-validation-concern.yml' '    uses: ./.github/workflows/linux-validation-concern.yml'
mutation '12. the Linux untrusted half granted write' "${linux}" '    cache-mode: read
    uses: ./.github/workflows/linux-validation-concern.yml' '    cache-mode: write
    uses: ./.github/workflows/linux-validation-concern.yml'
mutation '12. the Linux long-pole untrusted half runs without the audit' "${linux}" "needs.validate-input.result == 'success' && (needs.select.result == 'success' || needs.select.result == 'skipped') && needs.cache-audit.result == 'success' && join(fromJSON(needs.select.outputs.long_matrix || needs.validate-input.outputs.long_matrix).concern, '') != '' }}" "needs.validate-input.result == 'success' && (needs.select.result == 'success' || needs.select.result == 'skipped') && join(fromJSON(needs.select.outputs.long_matrix || needs.validate-input.outputs.long_matrix).concern, '') != '' }}"
mutation '12. the Linux short untrusted half runs without the audit' "${linux}" "needs.validate-input.result == 'success' && (needs.select.result == 'success' || needs.select.result == 'skipped') && needs.cache-audit.result == 'success' && join(fromJSON(needs.select.outputs.short_matrix || needs.validate-input.outputs.short_matrix).concern, '') != '' }}" "needs.validate-input.result == 'success' && (needs.select.result == 'success' || needs.select.result == 'skipped') && join(fromJSON(needs.select.outputs.short_matrix || needs.validate-input.outputs.short_matrix).concern, '') != '' }}"
mutation '12. the Linux audit no longer limited to untrusted' "${linux}" "    if: \${{ github.repository == 'Moh-Bakr/Taurine-CI' && github.ref == 'refs/heads/untrusted' && needs.validate-input.result == 'success' }}
    needs: [validate-input]" "    if: \${{ github.repository == 'Moh-Bakr/Taurine-CI' && needs.validate-input.result == 'success' }}
    needs: [validate-input]"
mutation '12. the Linux workflow-level none dropped' "${linux}" 'cache-mode: none
' ''
mutation '12. the Windows Rust untrusted half granted write' "${windows}" '    cache-mode: read
    uses: ./.github/workflows/windows-validation-concern.yml' '    cache-mode: write
    uses: ./.github/workflows/windows-validation-concern.yml'
mutation '12. the live-proofs workflow-level none dropped' .github/workflows/live-proofs.yml 'cache-mode: none
' ''
mutation '12. the pg8 arm caller without an explicit none' .github/workflows/pg8-measurement.yml '    cache-mode: none
    uses: ./.github/workflows/pg8-measurement-arm.yml' '    uses: ./.github/workflows/pg8-measurement-arm.yml'
mutation '12. the cache-scope audit accepts a non-empty scope' "${audit}" "if [[ \"\${total}\" != 0 ]]; then" 'if [[ "${total}" == never ]]; then'
mutation '12. the cache-scope audit asks for the main scope' "${audit}" 'ref=refs/heads/untrusted&per_page=1' 'ref=refs/heads/main&per_page=1'
mutation '12. the base-pass job loses its explicit none' .github/workflows/validate-public-changes.yml '    cache-mode: none
    # Kept as ./ : the policy matches this exact form for protected reusable calls.' '    # Kept as ./ : the policy matches this exact form for protected reusable calls.'
mutation '12. the base-pass job granted read' .github/workflows/validate-public-changes.yml '    cache-mode: none
    # Kept as ./ : the policy matches this exact form for protected reusable calls.' '    cache-mode: read
    # Kept as ./ : the policy matches this exact form for protected reusable calls.'
mutation '12. the base-pass job granted write' .github/workflows/validate-public-changes.yml '    cache-mode: none
    # Kept as ./ : the policy matches this exact form for protected reusable calls.' '    cache-mode: write
    # Kept as ./ : the policy matches this exact form for protected reusable calls.'
mutation '12. the base-pass job renamed' .github/workflows/validate-public-changes.yml '
  base-pass:
' '
  base-gate:
'
# 11b. The reviewer's case for the policy half: an untrusted-only restore with no cache-mode anywhere
# must be rejected, because the default grant for a job with no cache-mode is write.
mutation '11. an untrusted-only cargo-source restore while its caller is not enforced' .github/policy/check-cache-mode.rb '  linux-validation.yml
' '' "${linux_concern}" "        if: \${{ github.ref == 'refs/heads/main' && steps.verified-source.outputs.protected-ancestor == 'true' && (inputs.concern == 'taurine-cli' || startsWith(inputs.concern, 'rust-') || inputs.concern == 'scan-security') }}
        uses: actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0" "        if: \${{ github.ref == 'refs/heads/untrusted' && (inputs.concern == 'taurine-cli' || startsWith(inputs.concern, 'rust-') || inputs.concern == 'scan-security') }}
        uses: actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0" "${linux_concern}" '          restore-keys: |
            cargo-sources-v3-${{ runner.os }}-
' ''
mutation '11. a duplicate cache-mode key on the Linux caller' "${linux}" '    uses: ./.github/workflows/linux-validation-concern.yml  # zizmor: ignore[self-repository]' '    cache-mode: read
    cache-mode: write
    uses: ./.github/workflows/linux-validation-concern.yml  # zizmor: ignore[self-repository]'

# 13. The audits reach the verdict, and an untrusted restore waits for macOS (docs/untrusted-readonly-cache.md).
mutation '13. the Linux result no longer needs the after-audit' "${linux}" '    needs: [plan, validate-long-main, validate-long-untrusted, validate-main, validate-untrusted, select, cache-audit, cache-audit-after]' '    needs: [plan, validate-long-main, validate-long-untrusted, validate-main, validate-untrusted, select]'
mutation '13. the Linux after-audit no longer waits for the long-pole untrusted half' "${linux}" '    needs: [cache-audit, validate-long-untrusted, validate-untrusted]' '    needs: [cache-audit, validate-untrusted]'
mutation '13. the Windows result stops passing blocking-failures' "${windows}" "          blocking-failures: " "          selection-note: "
mutation '13. run-result ignores the blocking count' .github/actions/run-result/action.yml '        if [[ "${blocking}" -gt 0 ]]; then
          # A check outside' '        if [[ "${blocking}" == never ]]; then
          # A check outside'
# 11. The reusable half of the public policy gate. The base-policy pass is meant to move into
# .github/workflows/base-policy.yml, called by the entrypoint. The checks must accept that file as a
# plain called workflow and refuse everything that would make it more: another trigger, a secret, or
# the same shape at any other path. Run before the file exists, because a pull request is judged by
# the base commit's checks.
reusable=.github/workflows/base-policy.yml
# The body has exactly the shape the structure manifest pins for this file (workflow_call, jobs
# base-policy, base-policy-fixtures and base-policy-result), so each variant below differs from the
# reviewed file only in the property under test.
reusable_body() {
  local id
  printf '%s\n' 'name: Reusable public policy (fixture)' 'on:' '  workflow_call:' "$@" 'permissions: {}' 'jobs:'
  for id in base-policy base-policy-fixtures base-policy-result; do
    printf '%s\n' "  ${id}:" "    name: ${id}" '    permissions: {}' '    runs-on: ubuntu-24.04' '    steps:' "      - run: 'true'"
  done
}
# with_file LABEL PATH BODY: the tree plus one new file.
with_file() {
  fresh_tree
  mkdir -p "$(dirname "${dir}/tree/$2")"
  printf '%s\n' "$3" > "${dir}/tree/$2"
  : > "${dir}/log"
}
# reject_file LABEL PATH BODY CHECKER: refused, and by CHECKER. The structure check is skipped here so
# it cannot refuse the file for being a different shape and let the rule under test pass vacuously;
# the structure manifest has its own fixtures in test-structure.sh.
_reject_file() {
  local by
  with_file "$1" "$2" "$3"
  by="$(cd "${dir}/tree" && SKIP_STRUCTURE=1 offline_policy)" || true
  if [[ "${by}" != "$4" ]]; then
    echo "WRONG CHECKER  $1  (wanted $4, got '${by}')" >&2
    miss
    return
  fi
  verdict "$1" "${by}"
}
reject_file() { spawn "$1" _reject_file "$@"; }
# accept_file LABEL PATH BODY: accepted by every check, the structure check included.
_accept_file() {
  local label="$1" by
  with_file "$@"
  if by="$(cd "${dir}/tree" && offline_policy)"; then
    echo "accepted  ${label}"
  else
    echo "REFUSED   ${label}  (by ${by})" >&2
    miss
  fi
}
accept_file() { spawn "$1" _accept_file "$@"; }
accept_file '11. the reusable public policy workflow as a plain called workflow' "${reusable}" "$(reusable_body)"
reject_file '11. the same called workflow at a path no tier names' .github/workflows/other-public.yml "$(reusable_body)" check-workflows.sh
reject_file '11. the reusable public policy workflow with a schedule trigger' "${reusable}" "$(reusable_body '  schedule:' "    - cron: '0 0 * * *'")" check-workflows.sh
reject_file '11. the reusable public policy workflow with a pull_request_target trigger' "${reusable}" "$(reusable_body '  pull_request_target:')" check-universal.rb
reject_file '11. the reusable public policy workflow that is not called' "${reusable}" "$(reusable_body | sed 's/workflow_call:/workflow_dispatch:/')" check-workflows.sh
# A trigger on none of the refused lists: only the rule that it be workflow_call refuses this one.
reject_file '11. the reusable public policy workflow triggered by something other than workflow_call' "${reusable}" "$(reusable_body | sed 's/  workflow_call:/  issues:/')" check-workflows.sh
reject_file '11. the reusable public policy workflow declaring a secret' "${reusable}" "$(reusable_body '    secrets:' '      TOKEN:' '        required: false')" check-workflows.sh
reject_file '11. the reusable public policy workflow with a deployment environment' "${reusable}" "$(reusable_body | ruby -e 'print STDIN.read.sub("    name: base-policy\n", "    name: base-policy\n    environment: prod\n")')" check-workflows.sh
reject_file '11. the reusable public policy workflow reading a secret' "${reusable}" "$(reusable_body | sed "s/'true'/'echo \${{ secrets.TOKEN }}'/")" check-workflows.sh
# A workflow calling it is accepted: the call is a reviewed local reusable workflow. The caller is a
# small workflow of its own, so this tests the allow-list and not the size of the entrypoint.
_calling_workflow() {
  local by
  fresh_tree
  printf '%s\n' "$(reusable_body)" > "${dir}/tree/${reusable}"
  # The caller is new, so the fixture tree's manifest also lists it: a tree and its manifest changed
  # together, as a reviewed change does, and every check, the structure one included, accepts it.
  swap .github/policy/check-structure.rb '   ".github/workflows/cache-prune.yml" =>' '   ".github/workflows/call-fixture.yml" => {"tier" => "public", "triggers" => ["workflow_dispatch"], "jobs" => ["call"]},
   ".github/workflows/cache-prune.yml" =>'
  printf '%s\n' 'name: Caller (fixture)' 'on:' '  workflow_dispatch:' 'permissions: {}' 'jobs:' '  call:' '    permissions:' \
  '      contents: read' '    uses: ./.github/workflows/base-policy.yml' > "${dir}/tree/.github/workflows/call-fixture.yml"
  : > "${dir}/log"
  if by="$(cd "${dir}/tree" && offline_policy)"; then
    echo 'accepted  11. a workflow calling the reusable public policy workflow'
  else
    echo "REFUSED   11. a workflow calling the reusable public policy workflow  (by ${by})" >&2
    miss
  fi
}
spawn '11. a workflow calling the reusable public policy workflow' _calling_workflow
mutation '12. the required status check job renamed' "${public}" '    name: Validate workflow policy' '    name: Validate workflow policy (renamed)'
mutation '12. the required status check job id renamed' "${public}" '  policy:
' '  policy-renamed:
'
mutation '12. a protected dispatcher widened to a push trigger' "${linux}" 'on:
  workflow_dispatch:' 'on:
  push:
  workflow_dispatch:'
mutation '12. the policy job no longer runs the structure check with --strict' "${public}" 'check-structure.rb --strict' 'check-structure.rb'
SC='        run: ruby .github/policy/check-structure.rb --strict
'
mutation '13. an exit 0 before the strict command' "${public}" "${SC}" '        run: |
          exit 0
          ruby .github/policy/check-structure.rb --strict
'
mutation '13. set +e before the strict command' "${public}" "${SC}" '        run: |
          set +e
          ruby .github/policy/check-structure.rb --strict
'
mutation '13. the strict command made best-effort' "${public}" "${SC}" '        run: ruby .github/policy/check-structure.rb --strict || true
'
mutation '13. the strict step made if: false' "${public}" "${SC}" '        if: ${{ false }}
        run: ruby .github/policy/check-structure.rb --strict
'
mutation '13. the strict command inside a heredoc' "${public}" "${SC}" "        run: |
          cat <<'EOF'
          ruby .github/policy/check-structure.rb --strict
          EOF
"
mutation '13. the strict command in a function that is never called' "${public}" "${SC}" '        run: |
          strict() { ruby .github/policy/check-structure.rb --strict; }
'
mutation '13. an exit trap before the strict command' "${public}" "${SC}" "        run: |
          trap 'exit 0' EXIT
          ruby .github/policy/check-structure.rb --strict
"
mutation '13. the strict step given another shell invocation (the shell is replaced, not duplicated)' "${public}" '      - name: Check the control-plane structure, strictly
        shell: bash
        run: ruby' '      - name: Check the control-plane structure, strictly
        shell: bash --noprofile --norc {0}
        run: ruby'
mutation '13. the strict step given an env block' "${public}" "${SC}" '        env:
          BASH_ENV: /dev/null
        run: ruby .github/policy/check-structure.rb --strict
'
mutation '13. the strict step made continue-on-error' "${public}" "${SC}" '        continue-on-error: true
        run: ruby .github/policy/check-structure.rb --strict
'
mutation '13. env at the workflow level of the policy workflow (BASH_ENV)' "${public}" 'concurrency:
  group: public-policy-' 'env:
  BASH_ENV: /dev/null

concurrency:
  group: public-policy-'
mutation '13. defaults at the workflow level of the policy workflow' "${public}" 'concurrency:
  group: public-policy-' 'defaults:
  run:
    working-directory: /tmp

concurrency:
  group: public-policy-'
mutation '13. env on the policy job (RUBYOPT)' "${public}" '    name: Validate workflow policy
' '    name: Validate workflow policy
    env:
      RUBYOPT: -e0
'
mutation '13. defaults on the policy job' "${public}" '    name: Validate workflow policy
' '    name: Validate workflow policy
    defaults:
      run:
        working-directory: /tmp
'
mutation '13. a second YAML document appended to a workflow' .github/workflows/cache-prune.yml 'name: Prune stale caches (scheduled)
' 'name: Prune stale caches (scheduled)
---
ignored: true
---
'
mutation '13. a digest-pinned container on the policy job' "${public}" '    name: Validate workflow policy
' '    name: Validate workflow policy
    container: mcr.example/runner@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
'
mutation '13. a service on the policy job' "${public}" '    name: Validate workflow policy
' '    name: Validate workflow policy
    services:
      db:
        image: postgres@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
'
mutation '13. the policy job on a self-hosted runner' "${public}" '    runs-on: ubuntu-24.04
    timeout-minutes: '"${pol_to}"'
    steps:' '    runs-on: self-hosted
    timeout-minutes: '"${pol_to}"'
    steps:'
mutation '13. the policy job on another hosted label' "${public}" '    runs-on: ubuntu-24.04
    timeout-minutes: '"${pol_to}"'
    steps:' '    runs-on: ubuntu-latest
    timeout-minutes: '"${pol_to}"'
    steps:'
mutation '13. a command chained onto an exempt helper line in test-structure.sh' .github/policy/test-structure.sh 'NOT rejected under --strict: $1" >&2; exit 1; fi' 'NOT rejected under --strict: $1" >&2; exit 1; fi; ruby "${check}" --strict "${dir}/t" >/dev/null'
mutation '13. --strict run on the real tree by another policy script (the base pass would run it)' .github/policy/test-policy.sh 'set -euo pipefail
' 'set -euo pipefail
ruby .github/policy/check-structure.rb --strict
'
mutation '13. --strict run on the real tree inside test-structure.sh' .github/policy/test-structure.sh "echo 'accepted  the reviewed tree'" "ruby \"\${check}\" --strict \"\${dir}/t\" >/dev/null
echo 'accepted  the reviewed tree'"
mutation '12. the policy job made conditional' "${public}" '    if: ${{ always() }}
    runs-on: ubuntu-24.04
    timeout-minutes: '"${pol_to_guarded}"'
    steps:' '    if: ${{ github.event_name == '"'"'push'"'"' }}
    runs-on: ubuntu-24.04
    timeout-minutes: '"${pol_to_guarded}"'
    steps:'
mutation '12. the strict structure step made conditional' "${public}" '      - name: Check the control-plane structure, strictly
        shell: bash' "      - name: Check the control-plane structure, strictly
        if: \${{ false }}
        shell: bash"

# 16. Policy step coverage and the required check's name (check-policy-steps.rb, check-strict-structure.rb).
mutation '16. the check-repository policy step deleted' "${public}" '      # Repository contents: no private source, credential material or unexpected path.
      - name: Reject private-source and credential material
        shell: bash
        run: bash .github/policy/check-repository.sh
' ''
mutation '16. the mutation suite replaced by echo ok' "${public}" '        run: bash .github/policy/test-mutations.sh' '        run: echo ok'
mutation '16. a policy step weakened with || true' "${public}" '        run: bash .github/policy/test-sanitizers.sh' '        run: bash .github/policy/test-sanitizers.sh || true'
mutation '16. a policy step given a steering env' "${public}" '      - name: Test the sanitizer expressions against path and token fixtures
        shell: bash' '      - name: Test the sanitizer expressions against path and token fixtures
        shell: bash
        env:
          RUBYOPT: -e0'
mutation '16. a policy step made conditional' "${public}" '      - name: Test the weekly openssl-src patch cadence
        shell: bash' '      - name: Test the weekly openssl-src patch cadence
        if: ${{ false }}
        shell: bash'
mutation '16. a policy step renamed (the table no longer matches)' "${public}" '      - name: Test the weekly openssl-src patch cadence' '      - name: Test the weekly openssl-src patch cadence (renamed)'
mutation '16. a policy step added outside the table' "${public}" '      - name: Test the weekly openssl-src patch cadence' '      - name: Extra step
        shell: bash
        run: "true"
      - name: Test the weekly openssl-src patch cadence'
mutation '16. a policy step duplicated' "${public}" '      - name: Test the weekly openssl-src patch cadence' '      - name: Test the weekly openssl-src patch cadence
        shell: bash
        run: bash .github/policy/test-weekly-cadence.sh
      - name: Test the weekly openssl-src patch cadence'
mutation '16. the policy checkout given a repository override' "${public}" '          fetch-depth: 1
          persist-credentials: false' '          fetch-depth: 1
          repository: someone/else
          persist-credentials: false'
mutation '16. the base-pass call named like the required check' "${public}" '    name: Base policy' '    name: Validate workflow policy'
mutation '16. the policy-steps check dropped from the policy job' "${public}" '        run: ruby .github/policy/check-policy-steps.rb' '        run: "true"'

# mutation_by CHECKER LABEL FILE OLD NEW: like mutation, but the named check alone must refuse the tree.
# test-base-policy-result.sh pins the shape of base-policy.yml, which the reusable-workflow fixtures
# (11.) deliberately replace, so it is not part of offline_policy.
_mutation_by() {
  local checker="$1" label="$2"; shift 2
  fresh_tree
  while (( $# )); do swap "$1" "$2" "$3"; shift 3; done
  : > "${dir}/log"
  local rc=0
  (cd "${dir}/tree" && bash ".github/policy/${checker}" >>"${dir}/log" 2>&1) || rc=$?
  crashed "${checker}" "${rc}"
  if (( rc == 0 )); then
    verdict "${label}" ''
  else
    verdict "${label}" "${checker}"
  fi
}
mutation_by() { spawn "$2" _mutation_by "$@"; }
mutation_by test-base-policy-result.sh '14. a step ahead of the base-policy guard in the policy job' "${public}" '    steps:
      # FIRST, before the checkout' '    steps:
      - name: Early step
        shell: bash
        run: echo early
      # FIRST, before the checkout'
mutation_by test-base-policy-result.sh '14. the base-policy guard moved after the checkout' "${public}" '      - name: Require the base-policy workflow to have passed
        if: ${{ always() }}' '      - name: Check out public policy repository
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          fetch-depth: 1
          persist-credentials: false
      - name: Require the base-policy workflow to have passed
        if: ${{ always() }}'

mutation_by test-base-policy-result.sh '14. a digest-pinned container on the guard job' "${public}" '    name: Validate workflow policy
' '    name: Validate workflow policy
    container: mcr.example/runner@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
'
mutation_by test-base-policy-result.sh '14. a service on the guard job' "${public}" '    name: Validate workflow policy
' '    name: Validate workflow policy
    services:
      db:
        image: postgres@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
'
mutation_by test-base-policy-result.sh '14. the guard job on a self-hosted runner' "${public}" '    runs-on: ubuntu-24.04
    timeout-minutes: '"${pol_to}"'
    steps:' '    runs-on: self-hosted
    timeout-minutes: '"${pol_to}"'
    steps:'

mutation_by test-base-policy-result.sh '14. the guard step run as an argument to true (shell: true {0})' "${public}" '        shell: bash
        env:
          BASE_PASS_RESULT: ${{ needs.base-pass.result }}' '        shell: true {0}
        env:
          BASE_PASS_RESULT: ${{ needs.base-pass.result }}'
mutation_by test-base-policy-result.sh '14. the guard step reading a constant (BASE_PASS_RESULT: success)' "${public}" '          BASE_PASS_RESULT: ${{ needs.base-pass.result }}
        run: |' '          BASE_PASS_RESULT: success
        run: |'
mutation_by test-base-policy-result.sh '14. an extra key on the guard step (working-directory)' "${public}" '        shell: bash
        env:
          BASE_PASS_RESULT: ${{ needs.base-pass.result }}' '        shell: bash
        working-directory: /tmp
        env:
          BASE_PASS_RESULT: ${{ needs.base-pass.result }}'

# 14. An untrusted restore waits for every untrusted-running workflow to be enforced (rule M).
mutation '14. an untrusted cargo-source restore while macOS is not enforced' .github/policy/check-cache-mode.rb '  macos-validation.yml
' '' "${linux_concern}" "        if: \${{ github.ref == 'refs/heads/main' && steps.verified-source.outputs.protected-ancestor == 'true' && (inputs.concern == 'taurine-cli' || startsWith(inputs.concern, 'rust-') || inputs.concern == 'scan-security') }}
        uses: actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0" "        if: \${{ github.ref == 'refs/heads/untrusted' && (inputs.concern == 'taurine-cli' || startsWith(inputs.concern, 'rust-') || inputs.concern == 'scan-security') }}
        uses: actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0" "${linux_concern}" '          restore-keys: |
            cargo-sources-v3-${{ runner.os }}-
' ''
mutation '14. the macOS untrusted half granted write' .github/workflows/macos-validation.yml '    cache-mode: read
    # Kept as ./' '    cache-mode: write
    # Kept as ./'
mutation '14. the macOS concern called without the split' .github/workflows/macos-validation.yml '    if: github.repository == '"'"'Moh-Bakr/Taurine-CI'"'"' && github.ref == '"'"'refs/heads/untrusted'"'"' && needs.cache-audit.result == '"'"'success'"'"' && join(fromJSON(needs.plan.outputs.long_matrix).concern, '"'"''"'"') != '"'"''"'"'
    needs: [plan, cache-audit]' '    if: github.repository == '"'"'Moh-Bakr/Taurine-CI'"'"' && github.ref == '"'"'refs/heads/untrusted'"'"' && join(fromJSON(needs.plan.outputs.long_matrix).concern, '"'"''"'"') != '"'"''"'"'
    needs: [plan]'
# 15. The macOS classification and the dispatcher rules read the parsed structure, not indentation.
mutation '15. classification falls back to an indentation grep' .github/policy/workflow-lists.sh '[[ "$(ruby "${workflow_lists_dir}/classify-workflow.rb" "${file}")" == dispatcher ]]' '! grep -qE '"'"'^    environment:'"'"' "${file}"'
mutation '15. the classifier ignores a job environment' .github/policy/classify-workflow.rb "  source = true if job.key?('environment')" "  source = true if job.key?('environment') && false"
mutation '15. the classifier ignores a source-checkout step' .github/policy/classify-workflow.rb "uses == './.github/actions/source-checkout' || " ''
mutation '15. the dispatcher secrets rule dropped' .github/policy/dispatcher-structure.rb '    unless job['"'"'secrets'"'"'] == KEY' '    unless job['"'"'secrets'"'"'] == KEY || true'
mutation '15. the dispatcher may enter an environment' .github/policy/dispatcher-structure.rb "reusable workflow)\" if job.key?('environment')" "reusable workflow)\" if false"

# 17. No cache restore may run on the untrusted ref (rule N): each of these passed once macOS joined
# ENFORCED_WORKFLOWS, because rule M then refuses nothing.
macos_concern=.github/workflows/macos-validation-concern.yml
mutation '17. an untrusted-gated cargo-source restore, its Cargo.lock check left main-only' "${macos_concern}" "        id: cargo-sources
        if: \${{ github.ref == 'refs/heads/main' && steps.verified-source.outputs.protected-ancestor == 'true' && startsWith(inputs.concern, 'rust-') }}" "        id: cargo-sources
        if: \${{ github.ref == 'refs/heads/untrusted' && steps.verified-source.outputs.protected-ancestor == 'true' && startsWith(inputs.concern, 'rust-') }}"
mutation '17. an untrusted-gated compiled-cache restore, its strip left main-only' "${macos_concern}" "        id: cargo-target-cache
        if: \${{ github.ref == 'refs/heads/main' && " "        id: cargo-target-cache
        if: \${{ github.ref == 'refs/heads/untrusted' && "
mutation '17. a new untrusted restore of node_modules with no verification' "${macos_concern}" "      - name: Restore cached third-party crate sources
" "      - name: Restore node modules
        if: \${{ github.ref == 'refs/heads/untrusted' }}
        uses: actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0
        with:
          path: node_modules
          key: nm

      - name: Restore cached third-party crate sources
"
mutation '17. a restore with no ref gate, reachable on the untrusted ref' "${macos_concern}" "      - name: Restore cached third-party crate sources
        id: cargo-sources
        if: \${{ github.ref == 'refs/heads/main' && steps.verified-source.outputs.protected-ancestor == 'true' && startsWith(inputs.concern, 'rust-') }}
" "      - name: Restore cached third-party crate sources
        id: cargo-sources
"
mutation '17. rule N dropped from the checker' .github/policy/check-cache-mode.rb "      next if requires?(st['if'], MAIN) && !st['if'].to_s.include?('untrusted')" "      next"

# 18. The case-evidence admission in the e2e-visual container (git as root, checkouts owned by the
# runner's uid): its git calls carry an exact safe.directory for the checkout they read.
admission=.github/policy/case-evidence-admission.rb
mutation_by test-case-evidence-admission.sh '18. the admission git calls without safe.directory' "${admission}" "tool, '-c', safe_directory!(root, code), '-C', root," "tool, '-C', root,"
mutation_by test-case-evidence-admission.sh '18. the admission safe.directory widened to every repository' "${admission}" '"safe.directory=#{real}"' '"safe.directory=*"'

# 10. Self-editing policy. A pull request quietly exempts the Linux concern from rule 7 in its own
# copy of the policy (the rule's fixtures, which use other files, still pass) and adds a
# toJSON(secrets) read to that concern in the same change: its own policy passes, and the base
# policy (this commit's, which the pull_request run checks out from the base SHA) rejects it.
_self_editing_policy() {
  local own by
  cp -R "${src}/.github/policy" "${dir}/base-policy"
  fresh_tree
  swap .github/policy/check-universal.rb '  expressions(doc).each do |expr|
' "  expressions(doc).each do |expr|
    next if rel == '${linux_concern}'
"
  swap "${linux_concern}" '      - name: Report concern duration
        if: ${{ always() }}
' '      - name: Report concern duration
        if: ${{ always() }}
        env:
          ALL: ${{ toJSON(secrets) }}
'
  : > "${dir}/log"
  if ! own="$(cd "${dir}/tree" && offline_policy)"; then
    echo "10. the weakened pull request should pass its own policy, but ${own} rejected it" >&2; tail -n 20 "${dir}/log" >&2; exit 1
  fi
  rm -rf "${dir}/tree/.github/policy"; cp -R "${dir}/base-policy" "${dir}/tree/.github/policy"
  : > "${dir}/log"
  by="$(cd "${dir}/tree" && offline_policy)" || true
  verdict '10. a pull request that weakens its own policy (own policy passes; base policy run)' "${by}"
}
if [[ -z "${MUTATION_POLICY:-}" ]]; then
  spawn '10. a pull request that weakens its own policy (own policy passes; base policy run)' _self_editing_policy
fi

# 15. The OpenSSL door allowlist. taurine-mysql-async (the vendored MySQL fork) is a parent of
# tokio-openssl and nothing else; re-widening it to a direct openssl edge, in either the shell list
# or the Python map, must be refused by the shell-artefact fixtures (which are not part of
# offline_policy: they build real toy workspaces and take minutes).
mutation_by test-shell-artefact.sh '15. the MySQL fork allowed a direct openssl edge (shell list)' .github/actions/shell-artefact/action.yml "            openssl) echo 'tokio-openssl taurine-tls-openssl taurine-db-dbx' ;;" "            openssl) echo 'tokio-openssl taurine-tls-openssl taurine-db-dbx taurine-mysql-async' ;;"
mutation_by test-shell-artefact.sh '15. the MySQL fork allowed a direct openssl edge (built-graph map)' .github/actions/shell-artefact/action.yml '"openssl": {"tokio-openssl", "taurine-tls-openssl", "taurine-db-dbx"},' '"openssl": {"tokio-openssl", "taurine-tls-openssl", "taurine-db-dbx", "taurine-mysql-async"},'

# 16. The selector's always path: a duplicated concern and a dropped always-concern are refused.
mutation '16. the selector selects an always concern twice' .github/actions/select-concerns/action.yml "return always, 'partial', 'documentation only'" "return always + [always[0]], 'partial', 'documentation only'"
mutation '16. the selector drops an always concern' .github/actions/select-concerns/action.yml "always = [c for c, s in concerns.items() if s.get('always')]" "always = [c for c, s in concerns.items() if s.get('always') and c != 'contracts' and not c.startswith('zz')]"

drain
(( missed == 0 )) || { echo "${missed} mutation(s) passed the policy" >&2; exit 1; }
echo "mutation tests: every reviewed weakening is rejected by the offline policy (${total} cases, ${max_jobs} job(s))"
