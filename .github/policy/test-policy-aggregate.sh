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

# Extra policy steps. Main's copy of the steps check (superset mode, what the base pass runs) must accept
# a pull request that adds one compliant step and refuse every non-compliant extra, and the exact mode (this
# tree's own table) must refuse any extra. steps_check FILE [FLAG] runs the checker on a tree holding FILE.
steps_check() {
  check_tree "$1"
  ( cd "${tmp}/tree" && ruby .github/policy/check-policy-steps.rb ${2:+"$2"} ) > "${tmp}/out" 2>&1
}
check_tree() {
  rm -rf "${tmp}/tree"; mkdir -p "${tmp}/tree/.github/workflows"
  cp -R "${root}/.github/policy" "${tmp}/tree/.github/policy"
  cp "$1" "${tmp}/tree/${entry}"
  # The scripts the extra-step cases name exist (an extra must name a real script).
  : > "${tmp}/tree/.github/policy/check-new-rule.sh"; : > "${tmp}/tree/.github/policy/check-new-rule.rb"; : > "${tmp}/tree/.github/policy/x.sh"
}
# yaml_variant EXPR: the fixture edited by EXPR (it sees `d`), written to mut.yml.
yaml_variant() {
  EXPR="$1" ruby -ryaml -e 'd = YAML.safe_load(File.read(ARGV[0]), aliases: false); eval(ENV["EXPR"]); File.write(ARGV[1], YAML.dump(d))' "${tmp}/entry.yml" "${tmp}/mut.yml"
}
EXTRA="{ 'name' => 'Check a new policy rule', 'shell' => 'bash', 'run' => 'bash .github/policy/check-new-rule.sh' }"
expect_extra() { # LABEL accept|refuse EXPR [FLAG]
  yaml_variant "$3"
  if steps_check "${tmp}/mut.yml" "${4:-}"; then
    [[ "$2" == accept ]] || fail "NOT refused: $1"
  else
    [[ "$2" == refuse ]] || { cat "${tmp}/out" >&2; fail "refused, expected accepted: $1"; }
  fi
  if [[ "$2" == accept ]]; then echo "accepted  $1"; else echo "refused   $1"; fi
}
expect_extra 'a compliant extra at the end of a shard (superset mode)' accept "d['jobs']['policy-fixtures']['steps'] << ${EXTRA}"
expect_extra 'an extra with an env' refuse "d['jobs']['policy-fixtures']['steps'] << ${EXTRA}.merge('env' => { 'X' => 'y' })"
expect_extra 'an extra with an env that sets BASH_ENV' refuse "d['jobs']['policy-fixtures']['steps'] << ${EXTRA}.merge('env' => { 'BASH_ENV' => '/tmp/x' })"
expect_extra 'an extra with an env that reads a secret' refuse "d['jobs']['policy-fixtures']['steps'] << ${EXTRA}.merge('env' => { 'T' => '\${{ secrets.X }}' })"
expect_extra 'an extra with an empty env' refuse "d['jobs']['policy-fixtures']['steps'] << ${EXTRA}.merge('env' => {})"
expect_extra 'an extra naming a script that does not exist' refuse "d['jobs']['policy-fixtures']['steps'] << ${EXTRA}.merge('run' => 'bash .github/policy/missing-script.sh')"
expect_extra 'an extra running ruby -e' refuse "d['jobs']['policy-fixtures']['steps'] << ${EXTRA}.merge('run' => 'ruby .github/policy/-e')"
expect_extra 'an extra with a .. path' refuse "d['jobs']['policy-fixtures']['steps'] << ${EXTRA}.merge('run' => 'bash .github/policy/../x.sh')"
expect_extra 'an extra running python3 on a .rb file' refuse "d['jobs']['policy-fixtures']['steps'] << ${EXTRA}.merge('run' => 'python3 .github/policy/check-new-rule.rb')"
expect_extra 'an extra running bash on a .rb file' refuse "d['jobs']['policy-fixtures']['steps'] << ${EXTRA}.merge('run' => 'bash .github/policy/check-new-rule.rb')"
expect_extra 'an extra running ruby on a .sh file' refuse "d['jobs']['policy-fixtures']['steps'] << ${EXTRA}.merge('run' => 'ruby .github/policy/check-new-rule.sh')"
GUARD1='Require the base-policy workflow to have passed'
expect_extra 'a duplicate guard name in a shard' refuse "d['jobs']['policy-fixtures']['steps'] << { 'name' => '${GUARD1}', 'shell' => 'bash', 'run' => 'bash .github/policy/x.sh' }"
expect_extra 'a duplicate of the whole guard in the aggregate' refuse "d['jobs']['policy']['steps'] << d['jobs']['policy']['steps'][0].dup"
expect_extra 'a guard with a modified run' refuse "d['jobs']['policy']['steps'][0]['run'] = \"echo ok\\n\""
expect_extra 'the shards guard with a modified run' refuse "d['jobs']['policy']['steps'][1]['run'] = \"true\\n\""
expect_extra 'a guard with an added key' refuse "d['jobs']['policy']['steps'][0]['continue-on-error'] = true"
expect_extra 'a guard moved into a shard' refuse "g = d['jobs']['policy']['steps'].shift; d['jobs']['policy-structure']['steps'].unshift(g)"
expect_extra 'the guards swapped' refuse "d['jobs']['policy']['steps'].reverse!"
expect_extra 'a compliant extra at the end of the evidence shard (superset mode)' accept "d['jobs']['policy-evidence']['steps'] << ${EXTRA}.merge('run' => 'ruby .github/policy/check-new-rule.rb')"
expect_extra 'the same extra in exact mode (its row is missing)' refuse "d['jobs']['policy-fixtures']['steps'] << ${EXTRA}" --exact
expect_extra 'an extra with || true' refuse "d['jobs']['policy-fixtures']['steps'] << ${EXTRA}.merge('run' => 'bash .github/policy/x.sh || true')"
expect_extra 'an extra with a semicolon' refuse "d['jobs']['policy-fixtures']['steps'] << ${EXTRA}.merge('run' => 'bash .github/policy/x.sh; true')"
expect_extra 'an extra with && ' refuse "d['jobs']['policy-fixtures']['steps'] << ${EXTRA}.merge('run' => 'bash .github/policy/x.sh && true')"
expect_extra 'an extra with command substitution' refuse "d['jobs']['policy-fixtures']['steps'] << ${EXTRA}.merge('run' => 'bash .github/policy/\$(true).sh')"
expect_extra 'an extra with an argument' refuse "d['jobs']['policy-fixtures']['steps'] << ${EXTRA}.merge('run' => 'bash .github/policy/x.sh arg')"
expect_extra 'an extra with a second line' refuse "d['jobs']['policy-fixtures']['steps'] << ${EXTRA}.merge('run' => \"bash .github/policy/x.sh\\ntrue\")"
expect_extra 'an extra running a script outside the policy directory' refuse "d['jobs']['policy-fixtures']['steps'] << ${EXTRA}.merge('run' => 'bash scripts/x.sh')"
expect_extra 'an extra with if' refuse "d['jobs']['policy-fixtures']['steps'] << ${EXTRA}.merge('if' => '\${{ false }}')"
expect_extra 'an extra with continue-on-error' refuse "d['jobs']['policy-fixtures']['steps'] << ${EXTRA}.merge('continue-on-error' => true)"
expect_extra 'an extra with uses' refuse "d['jobs']['policy-fixtures']['steps'] << { 'name' => 'Other action', 'uses' => 'actions/cache@0000000000000000000000000000000000000000' }"
expect_extra 'an extra with an id' refuse "d['jobs']['policy-fixtures']['steps'] << ${EXTRA}.merge('id' => 'x')"
expect_extra 'an extra with a working-directory' refuse "d['jobs']['policy-fixtures']['steps'] << ${EXTRA}.merge('working-directory' => '/tmp')"
expect_extra 'an extra with a timeout' refuse "d['jobs']['policy-fixtures']['steps'] << ${EXTRA}.merge('timeout-minutes' => 1)"
expect_extra 'an extra with another shell' refuse "d['jobs']['policy-fixtures']['steps'] << ${EXTRA}.merge('shell' => 'bash --noprofile {0}')"
expect_extra 'an extra named like a table row' refuse "d['jobs']['policy-fixtures']['steps'] << ${EXTRA}.merge('name' => 'Test the weekly openssl-src patch cadence')"
expect_extra 'an extra named like a guard' refuse "d['jobs']['policy-fixtures']['steps'] << ${EXTRA}.merge('name' => 'Require every policy check shard to have passed')"
expect_extra 'an extra named like the required check' refuse "d['jobs']['policy-fixtures']['steps'] << ${EXTRA}.merge('name' => 'Validate workflow policy')"
expect_extra 'two extras with one name' refuse "d['jobs']['policy-fixtures']['steps'] << ${EXTRA} << ${EXTRA}"
expect_extra 'an extra before a pinned step' refuse "d['jobs']['policy-fixtures']['steps'].insert(1, ${EXTRA})"
expect_extra 'an extra in the aggregate' refuse "d['jobs']['policy']['steps'] << ${EXTRA}"
expect_extra 'an extra with a pinned row removed' refuse "d['jobs']['policy-fixtures']['steps'] << ${EXTRA}; d['jobs']['policy-structure']['steps'].reject! { |st| st['name'] == 'Reject private-source and credential material' }"
expect_extra 'an extra with a pinned run modified' refuse "d['jobs']['policy-fixtures']['steps'] << ${EXTRA}; d['jobs']['policy-mutations']['steps'].each { |st| st['run'] = 'echo ok' if st['run'].to_s.include?('test-mutations.sh') }"
expect_extra 'an extra with a pinned step moved' refuse "d['jobs']['policy-fixtures']['steps'] << ${EXTRA}; m = d['jobs']['policy-mutations']['steps'].pop; d['jobs']['policy-fixtures']['steps'].unshift(m)"
# The cases above are main's copy of the checker judging a pull request tree that adds one step: accepted in
# superset mode although the table (main's) has no row for it, which is what the base pass runs, so adding a
# policy step no longer deadlocks; and a pinned row removed, modified or moved while an extra is present is refused.
# An empty table and a duplicate key.
cp "${root}/.github/policy/check-policy-steps.rb" "${tmp}/empty-table.rb"
ruby -e 's = File.read(ARGV[0]); File.write(ARGV[0], s[0, s.index("__END__\n") + 8])' "${tmp}/empty-table.rb"
check_tree "${tmp}/entry.yml"; cp "${tmp}/empty-table.rb" "${tmp}/tree/.github/policy/check-policy-steps.rb"
if ( cd "${tmp}/tree" && ruby .github/policy/check-policy-steps.rb ) > "${tmp}/out" 2>&1; then fail 'NOT refused: an empty step table'; fi
echo 'refused   an empty step table'
ruby -e 's = File.read(ARGV[0]); s.sub!("        run: bash .github/policy/check-repository.sh\n", "        run: bash .github/policy/check-repository.sh\n        run: true\n") or abort "no run line"; File.write(ARGV[1], s)' "${tmp}/entry.yml" "${tmp}/mut.yml"
if steps_check "${tmp}/mut.yml"; then fail 'NOT refused: a duplicate run key'; fi
grep -q 'appears twice' "${tmp}/out" || fail 'the duplicate run key was refused for another reason'
echo 'refused   a duplicate run key'
# An empty workflow (no policy steps) aborts.
printf 'jobs: {}\n' > "${tmp}/mut.yml"
if steps_check "${tmp}/mut.yml"; then fail 'NOT refused: a workflow with no policy steps'; fi
echo 'refused   a workflow with no policy steps'

echo 'policy aggregate: the aggregate layout is accepted and each weakening of it is refused'
