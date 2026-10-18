#!/usr/bin/env bash
# The sharded layout of the policy gate: `policy` is the required check and holds only two guards, and
# this pull request's own policy runs in four shard jobs beside the base pass. This test proves the
# checkers (test-base-policy-result.sh, check-strict-structure.rb, check-policy-steps.rb) accept that
# layout and refuse each way of weakening it, including a shard that borrows the required check's name
# and a step that is dropped, rewritten or moved to another shard. While the entrypoint is still the
# single-job layout the fixture is derived from it; once it has the shards it is used as it stands.
# Run from the repository root.
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

# check FILE: all three checkers, run on a tree whose entrypoint is FILE; non-zero when any refuses it.
check() {
  rm -rf "${tmp}/tree"; mkdir -p "${tmp}/tree/.github/workflows"
  cp -R "${root}/.github/policy" "${tmp}/tree/.github/policy"
  cp "${root}/.github/workflows/base-policy.yml" "${tmp}/tree/.github/workflows/"
  cp "$1" "${tmp}/tree/${entry}"
  ( cd "${tmp}/tree" && bash .github/policy/test-base-policy-result.sh && ruby .github/policy/check-strict-structure.rb && ruby .github/policy/check-policy-steps.rb ) > "${tmp}/out" 2>&1
}
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

# mutate_yaml LABEL RUBY: the parsed fixture edited by RUBY (it sees `d`, the workflow hash) must be refused.
mutate_yaml() {
  EXPR="$2" ruby -ryaml -e 'd = YAML.safe_load(File.read(ARGV[0]), aliases: false); eval(ENV["EXPR"]); File.write(ARGV[1], YAML.dump(d))' "${tmp}/entry.yml" "${tmp}/mut.yml"
  if check "${tmp}/mut.yml"; then fail "NOT refused: $1"; fi
  echo "refused   $1"
}
REQ='Validate workflow policy'
for shard in policy-structure policy-fixtures policy-evidence policy-mutations; do
  mutate_yaml "${shard} named like the required check" "d['jobs']['${shard}']['name'] = '${REQ}'"
  mutate_yaml "${shard} renamed" "d['jobs']['${shard}']['name'] += ' x'"
  mutate_yaml "${shard} given a strategy" "d['jobs']['${shard}']['strategy'] = { 'matrix' => { 'a' => [1] } }"
  mutate_yaml "${shard} given a concurrency group" "d['jobs']['${shard}']['concurrency'] = { 'group' => 'x' }"
  mutate_yaml "${shard} given a cache-mode" "d['jobs']['${shard}']['cache-mode'] = 'write'"
  mutate_yaml "${shard} given more permissions" "d['jobs']['${shard}']['permissions']['actions'] = 'write'"
  mutate_yaml "${shard} given write permission" "d['jobs']['${shard}']['permissions'] = { 'contents' => 'write' }"
  mutate_yaml "${shard} checks out another repository" "d['jobs']['${shard}']['steps'][0]['with']['repository'] = 'someone/else'"
  mutate_yaml "${shard} checks out with a token" "d['jobs']['${shard}']['steps'][0]['with']['token'] = 'x'"
done
mutate_yaml 'an extra job named like the required check' "d['jobs']['extra'] = { 'name' => '${REQ}', 'runs-on' => 'ubuntu-24.04', 'steps' => [{ 'run' => 'true', 'shell' => 'bash' }] }"
mutate_yaml 'the base-pass call named like the required check' "d['jobs']['base-pass']['name'] = '${REQ}'"
mutate_yaml 'an extra, unnamed job' "d['jobs']['extra'] = { 'runs-on' => 'ubuntu-24.04', 'steps' => [{ 'run' => 'true', 'shell' => 'bash' }] }"
mutate_yaml 'the aggregate given contents: read' "d['jobs']['policy']['permissions'] = { 'contents' => 'read' }"
mutate_yaml 'the aggregate given a strategy' "d['jobs']['policy']['strategy'] = { 'matrix' => { 'a' => [1] } }"
# Step coverage: dropped, rewritten, conditional, re-environmented and moved steps.
mutate_yaml 'the check-repository step deleted' "d['jobs']['policy-structure']['steps'].reject! { |st| st['name'] == 'Reject private-source and credential material' }"
mutate_yaml 'the mutation suite turned into echo ok' "d['jobs']['policy-mutations']['steps'].each { |st| st['run'] = 'echo ok' if st['run'].to_s.include?('test-mutations.sh') }"
mutate_yaml 'a fixture step weakened with || true' "d['jobs']['policy-fixtures']['steps'].each { |st| st['run'] = st['run'].to_s.strip + ' || true' if st['name'] == 'Test the sanitizer expressions against path and token fixtures' }"
mutate_yaml 'a step given an env that steers it' "d['jobs']['policy-evidence']['steps'].each { |st| (st['env'] ||= {})['RUBYOPT'] = '-e0' if st['run'] }"
mutate_yaml 'a step made conditional' "d['jobs']['policy-fixtures']['steps'].each { |st| st['if'] = '\${{ false }}' if st['name'] == 'Test the weekly openssl-src patch cadence' }"
mutate_yaml 'a step duplicated' "d['jobs']['policy-fixtures']['steps'] << d['jobs']['policy-fixtures']['steps'][1]"
mutate_yaml 'a step added that is not in the table' "d['jobs']['policy-fixtures']['steps'] << { 'name' => 'Extra', 'shell' => 'bash', 'run' => 'true' }"
mutate_yaml 'the mutation suite moved to the fixtures shard' "m = d['jobs']['policy-mutations']['steps'].pop; d['jobs']['policy-fixtures']['steps'] << m"
mutate_yaml 'the evidence step moved to the structure shard' "m = d['jobs']['policy-evidence']['steps'].pop; d['jobs']['policy-structure']['steps'] << m"
mutate_yaml 'a step moved into the aggregate' "m = d['jobs']['policy-fixtures']['steps'].pop; d['jobs']['policy']['steps'] << m"

echo 'policy aggregate: the aggregate layout is accepted and each weakening of it is refused'
