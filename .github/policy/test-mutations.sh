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
set -euo pipefail

src="${PWD}"
dir="$(mktemp -d)"
trap 'rm -rf "${dir}"' EXIT
# Some fixture suites write under RUNNER_TEMP, which only a runner sets.
export RUNNER_TEMP="${RUNNER_TEMP:-${dir}/runner-temp}"
mkdir -p "${RUNNER_TEMP}"
policy_source="${MUTATION_POLICY:-${src}/.github/policy}"
missed=0

# The offline policy, in the order the cheap checks fail first. Prints the first check that
# rejects the tree and returns non-zero; returns zero when every check passes.
offline_policy() {
  local check
  for check in check-universal.rb test-preflight.sh test-cache-scope-audit.sh test-run-result.sh test-revoke.sh check-workflows.sh check-sizes.sh test-policy.sh test-sanitizers.sh test-extractors.sh check-concern-table.sh test-selector.sh check-tools.sh check-egress-allowlist.sh; do
    [[ -f ".github/policy/${check}" ]] || continue
    case "${check}" in
      *.rb) ruby ".github/policy/${check}" >>"${dir}/log" 2>&1 ;;
      *) bash ".github/policy/${check}" >>"${dir}/log" 2>&1 ;;
    esac || { printf '%s' "${check}"; return 1; }
  done
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
verdict() {
  local label="$1" by="$2"
  if [[ -n "${by}" ]]; then
    echo "rejected  ${label}  (by ${by})"
  else
    echo "PASSED    ${label}" >&2
    missed=$((missed + 1))
    [[ -n "${MUTATION_REPORT:-}" ]] || { tail -n 20 "${dir}/log" >&2; exit 1; }
  fi
}
# mutation LABEL FILE OLD NEW [FILE OLD NEW ...]: apply every edit, then expect a rejection.
mutation() {
  local label="$1" by=''; shift
  fresh_tree
  while (( $# )); do swap "$1" "$2" "$3"; shift 3; done
  : > "${dir}/log"
  by="$(cd "${dir}/tree" && offline_policy)" || true
  verdict "${label}" "${by}"
}

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
composite_revoke='        if ! api -X DELETE "${GITHUB_API_URL}/installation/token"; then'
weekly_revoke='          if ! api -X DELETE "${GITHUB_API_URL}/installation/token"; then'

mutation '1. the Linux concern no longer needs the pre-flight job' "${linux}" '    needs: [validate-input, plan, select]' '    needs: [plan, select]'
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
mutation '12. the Linux untrusted half runs without the audit' "${linux}" "needs.validate-input.result == 'success' && needs.plan.result == 'success' && (needs.select.result == 'success' || needs.select.result == 'skipped') && needs.cache-audit.result == 'success' }}" "needs.validate-input.result == 'success' && needs.plan.result == 'success' && (needs.select.result == 'success' || needs.select.result == 'skipped') }}"
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
mutation '13. the Linux result no longer needs the after-audit' "${linux}" '    needs: [plan, validate-main, validate-untrusted, select, cache-audit, cache-audit-after]' '    needs: [plan, validate-main, validate-untrusted, select]'
mutation '13. the Windows result stops passing blocking-failures' "${windows}" "          blocking-failures: " "          selection-note: "
mutation '13. run-result ignores the blocking count' .github/actions/run-result/action.yml '        if [[ "${blocking}" -gt 0 ]]; then
          # A check outside' '        if [[ "${blocking}" == never ]]; then
          # A check outside'

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
mutation '14. the macOS concern called without the split' .github/workflows/macos-validation.yml '    if: github.repository == '"'"'Moh-Bakr/Taurine-CI'"'"' && github.ref == '"'"'refs/heads/untrusted'"'"' && needs.cache-audit.result == '"'"'success'"'"'
    needs: [plan, cache-audit]' '    if: github.repository == '"'"'Moh-Bakr/Taurine-CI'"'"' && github.ref == '"'"'refs/heads/untrusted'"'"'
    needs: [plan]'
# 15. The macOS classification and the dispatcher rules read the parsed structure, not indentation.
mutation '15. classification falls back to an indentation grep' .github/policy/workflow-lists.sh '[[ "$(ruby "${workflow_lists_dir}/classify-workflow.rb" "${file}")" == dispatcher ]]' '! grep -qE '"'"'^    environment:'"'"' "${file}"'
mutation '15. the classifier ignores a job environment' .github/policy/classify-workflow.rb "  source = true if job.key?('environment')" "  source = true if job.key?('environment') && false"
mutation '15. the classifier ignores a source-checkout step' .github/policy/classify-workflow.rb "uses == './.github/actions/source-checkout' || " ''
mutation '15. the dispatcher secrets rule dropped' .github/policy/dispatcher-structure.rb '    unless job['"'"'secrets'"'"'] == KEY' '    unless job['"'"'secrets'"'"'] == KEY || true'
mutation '15. the dispatcher may enter an environment' .github/policy/dispatcher-structure.rb "reusable workflow)\" if job.key?('environment')" "reusable workflow)\" if false"

# 10. Self-editing policy. A pull request quietly exempts the Linux concern from rule 7 in its own
# copy of the policy (the rule's fixtures, which use other files, still pass) and adds a
# toJSON(secrets) read to that concern in the same change: its own policy passes, and the base
# policy (this commit's, which the pull_request run checks out from the base SHA) rejects it.
if [[ -z "${MUTATION_POLICY:-}" ]]; then
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
fi

(( missed == 0 )) || { echo "${missed} mutation(s) passed the policy" >&2; exit 1; }
echo 'mutation tests: every reviewed weakening is rejected by the offline policy'
