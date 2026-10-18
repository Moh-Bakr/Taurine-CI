#!/usr/bin/env bash
# The aggregate layout of the policy gate: `policy` is the required check and holds only two guards,
# `policy-checks` runs this pull request's own policy beside the base pass. This test proves the
# result checker (test-base-policy-result.sh) accepts that layout and refuses each way of weakening
# it. While the entrypoint is still the single-job layout the fixture is derived from it; once the
# entrypoint has `policy-checks` it is used as it stands. Run from the repository root.
set -euo pipefail

root="${PWD}"
tmp="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/policy-aggregate-test.XXXXXX")"
trap 'rm -rf -- "${tmp}"' EXIT
entry=.github/workflows/validate-public-changes.yml
fail() { echo "policy aggregate: $*" >&2; exit 1; }

# The fixture: the real entrypoint, or the single-job entrypoint sharded by shard-policy-entry.rb.
if grep -q '^  policy-structure:$' "${root}/${entry}"; then
  cp "${root}/${entry}" "${tmp}/entry.yml"
else
  ruby "${root}/.github/policy/shard-policy-entry.rb" "${root}/${entry}" > "${tmp}/entry.yml"
fi

check() { bash "${root}/.github/policy/test-base-policy-result.sh" "$1" > "${tmp}/out" 2>&1; }
check "${tmp}/entry.yml" || { cat "${tmp}/out" >&2; fail 'the aggregate layout was refused'; }
echo 'accepted  the aggregate layout'

# mutate LABEL OLD NEW: the fixture with the first OLD replaced by NEW must be refused.
mutate() {
  OLD="$2" NEW="$3" ruby -e 's = File.read(ARGV[0]); i = s.index(ENV["OLD"]) or abort("mutation text not found: #{ENV["OLD"][0, 70]}"); s[i, ENV["OLD"].length] = ENV["NEW"]; File.write(ARGV[1], s)' "${tmp}/entry.yml" "${tmp}/mut.yml"
  if check "${tmp}/mut.yml"; then fail "NOT refused: $1"; fi
  echo "refused   $1"
}
NEEDS='    needs: [base-pass, policy-evidence, policy-fixtures, policy-mutations, policy-structure]'
mutate 'the aggregate no longer needs the mutations shard' "${NEEDS}" '    needs: [base-pass, policy-evidence, policy-fixtures, policy-structure]'
mutate 'the aggregate no longer needs the evidence shard' "${NEEDS}" '    needs: [base-pass, policy-fixtures, policy-mutations, policy-structure]'
mutate 'the aggregate no longer needs the fixtures shard' "${NEEDS}" '    needs: [base-pass, policy-evidence, policy-mutations, policy-structure]'
mutate 'the aggregate no longer needs the structure shard' "${NEEDS}" '    needs: [base-pass, policy-evidence, policy-fixtures, policy-mutations]'
mutate 'the aggregate no longer needs the base pass' "${NEEDS}" '    needs: [policy-evidence, policy-fixtures, policy-mutations, policy-structure]'
mutate 'the aggregate needs a further job' "${NEEDS}" '    needs: [base-pass, policy-evidence, policy-fixtures, policy-mutations, policy-structure, policy]'
mutate 'a shard job dropped (its steps gone)' '  policy-mutations:
' '  policy-mutations-renamed:
'
mutate 'the shards guard removed' '      - name: Require every policy check shard to have passed' "      - name: Something else
        shell: bash
        run: 'true'
      - name: Require every policy check shard to have passed (renamed)"
mutate 'the shards guard reads a constant for one shard' '          POLICY_MUTATIONS_RESULT: ${{ needs.policy-mutations.result }}' '          POLICY_MUTATIONS_RESULT: success'
mutate 'the shards guard reads another shard result' '          POLICY_MUTATIONS_RESULT: ${{ needs.policy-mutations.result }}' '          POLICY_MUTATIONS_RESULT: ${{ needs.policy-fixtures.result }}'
mutate 'the shards guard ignores one result' 'for pair in "evidence:${POLICY_EVIDENCE_RESULT}" ' 'for pair in '
mutate 'the shards guard accepts any result' "if [[ \"\${pair#*:}\" != 'success' ]]; then" "if [[ \"\${pair#*:}\" == 'failure' ]]; then"
mutate 'the shards guard never fails' '          [[ "${failed}" -eq 0 ]] || exit 1' '          true'
mutate 'the shards guard made conditional' "      - name: Require every policy check shard to have passed
        if: \${{ always() }}" "      - name: Require every policy check shard to have passed
        if: \${{ github.event_name == 'push' }}"
mutate 'the shards guard run as an argument to true' "        shell: bash
        env:
          POLICY_EVIDENCE_RESULT" "        shell: true {0}
        env:
          POLICY_EVIDENCE_RESULT"
mutate 'a checkout step added to the aggregate' '    steps:
      # FIRST, before the checkout' '    steps:
      - name: Check out public policy repository
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      # FIRST, before the checkout'
mutate 'a script step added to the aggregate' '      - name: Require every policy check shard to have passed' "      - name: Run the policy here
        shell: bash
        run: bash .github/policy/check-repository.sh
      - name: Require every policy check shard to have passed"
for shard in policy-structure policy-fixtures policy-evidence policy-mutations; do
  mutate "${shard} waits for the base pass again" "  ${shard}:
    permissions:
      contents: read
" "  ${shard}:
    needs: [base-pass]
    permissions:
      contents: read
"
  mutate "${shard} made conditional" "  ${shard}:
    permissions:
      contents: read
" "  ${shard}:
    if: \${{ github.event_name == 'push' }}
    permissions:
      contents: read
"
  mutate "${shard} tolerates failure" "  ${shard}:
    permissions:
      contents: read
" "  ${shard}:
    continue-on-error: true
    permissions:
      contents: read
"
  mutate "${shard} in a container" "  ${shard}:
    permissions:
      contents: read
" "  ${shard}:
    container: mcr.example/runner@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    permissions:
      contents: read
"
  mutate "${shard} on a self-hosted runner" "  ${shard}:
    permissions:
      contents: read
    name: $(ruby -ryaml -e 'puts YAML.load_file(ARGV[0])["jobs"][ARGV[1]]["name"]' "${tmp}/entry.yml" "${shard}")
    runs-on: ubuntu-24.04" "  ${shard}:
    permissions:
      contents: read
    name: $(ruby -ryaml -e 'puts YAML.load_file(ARGV[0])["jobs"][ARGV[1]]["name"]' "${tmp}/entry.yml" "${shard}")
    runs-on: self-hosted"
done
mutate 'a policy-structure step tolerates failure' '      - name: Reject private-source and credential material
' '      - name: Reject private-source and credential material
        continue-on-error: true
'
mutate 'a policy-fixtures step made conditional' '      - name: Test the environment pre-flight against stub endpoints
' '      - name: Test the environment pre-flight against stub endpoints
        if: ${{ false }}
'
mutate 'a shard loses its own checkout' '    name: Policy mutations
    runs-on: ubuntu-24.04
    timeout-minutes: 25
    steps:
      - name: Check out public policy repository
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1' '    name: Policy mutations
    runs-on: ubuntu-24.04
    timeout-minutes: 25
    steps:
      - name: Check out public policy repository
        run: echo skipped'

echo 'policy aggregate: the aggregate layout is accepted and each weakening of it is refused'
