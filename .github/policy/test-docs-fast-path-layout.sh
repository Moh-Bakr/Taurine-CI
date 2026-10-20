#!/usr/bin/env bash
# The classified layout of the policy gate (docs-fast-path-shape.rb): a `classify` job in front of everything,
# a short `policy-docs` job for a documentation-only change, the base pass and the four shards skipped by
# exactly one condition, and a `policy` aggregate that accepts exactly the two outcomes the classification
# allows. This test proves the checkers accept that layout and refuse each way of weakening it, and runs both
# aggregate guards over their whole truth table. The fixture is the real entrypoint when it is already the
# classified layout, and otherwise the real entrypoint made into it (DocsFastPathShape.synthesize), so the
# same test holds before and after the workflow changes. Run from the repository root.
set -euo pipefail

root="${PWD}"
policy_dir="${root}/.github/policy"
tmp="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/docs-fast-layout-test.XXXXXX")"
trap 'rm -rf -- "${tmp}"' EXIT
entry=.github/workflows/validate-public-changes.yml
fail() { echo "docs fast path layout: $*" >&2; exit 1; }

# The fixture, as parsed YAML written back out (the checkers parse it; formatting is not under test here).
ruby -ryaml -r"${policy_dir}/docs-fast-path-shape.rb" -e '
  doc = YAML.safe_load(File.read(ARGV[0]), aliases: false)
  doc = DocsFastPathShape.synthesize(doc) unless DocsFastPathShape.classified?(doc.fetch("jobs"))
  File.write(ARGV[1], YAML.dump(doc))
' "${root}/${entry}" "${tmp}/entry.yml"

# check FILE: the three checkers on a tree whose entrypoint is FILE; non-zero when any refuses it.
check() {
  rm -rf "${tmp}/tree"; mkdir -p "${tmp}/tree/.github/workflows"
  cp -R "${policy_dir}" "${tmp}/tree/.github/policy"
  cp "${root}/.github/workflows/base-policy.yml" "${tmp}/tree/.github/workflows/"
  cp "$1" "${tmp}/tree/${entry}"
  ( cd "${tmp}/tree" && ruby .github/policy/check-strict-structure.rb && ruby .github/policy/check-policy-steps.rb && ruby .github/policy/check-policy-steps.rb --exact && bash .github/policy/test-base-policy-result.sh ) > "${tmp}/out" 2>&1
}
check "${tmp}/entry.yml" || { cat "${tmp}/out" >&2; fail 'the classified layout was refused'; }
echo 'accepted  the classified layout'

# mutate LABEL RUBY: the fixture edited by RUBY (it sees `d`, the workflow hash, and `shape`) must be refused.
mutate() {
  EXPR="$2" ruby -ryaml -r"${policy_dir}/docs-fast-path-shape.rb" -e 'd = YAML.safe_load(File.read(ARGV[0]), aliases: false); shape = DocsFastPathShape; eval(ENV["EXPR"]); File.write(ARGV[1], YAML.dump(d))' "${tmp}/entry.yml" "${tmp}/mut.yml"
  if check "${tmp}/mut.yml"; then fail "NOT refused: $1"; fi
  echo "refused   $1"
}
J="d['jobs']"
CS="d['jobs']['classify']['steps']"

# The classify job: present, first, exact; it runs the classifier from the base commit, read-only.
mutate 'the classify job removed' "${J}.delete('classify')"
mutate 'the classify job moved out of first place' "c = ${J}.delete('classify'); d['jobs'] = ${J}.merge('classify' => c)"
mutate 'the classifier read from the pull request instead of the base' "${CS}[2]['run'] = ${CS}[2]['run'].sub('base-policy/.github/policy/classify', 'pr/.github/policy/classify')"
mutate 'the classifier read from the pull request checkout path' "${CS}[0]['with']['path'] = 'pr'; ${CS}[1]['with']['path'] = 'base-policy'"
mutate 'the base-policy checkout taken at the pull request head' "${CS}[0]['with']['ref'] = '\${{ github.event.pull_request.head.sha }}'"
mutate 'the base-policy checkout taken at a moving ref' "${CS}[0]['with']['ref'] = 'main'"
mutate 'the base-policy checkout left at the default ref' "${CS}[0]['with'].delete('ref')"
mutate 'the base-policy checkout keeps its credentials' "${CS}[0]['with']['persist-credentials'] = true"
mutate 'the merge checkout keeps its credentials' "${CS}[1]['with']['persist-credentials'] = true"
mutate 'the merge checkout loses its history' "${CS}[1]['with']['fetch-depth'] = 1"
mutate 'the merge checkout of another repository' "${CS}[1]['with']['repository'] = 'someone/else'"
mutate 'the classify job given write permission' "${J}['classify']['permissions'] = { 'contents' => 'write' }"
mutate 'the classify job given a token scope' "${J}['classify']['permissions']['pull-requests'] = 'write'"
mutate 'the classify job given a condition' "${J}['classify']['if'] = \"github.event_name == 'pull_request'\""
mutate 'the classify job tolerating failure' "${J}['classify']['continue-on-error'] = true"
mutate 'the classify job on another runner' "${J}['classify']['runs-on'] = 'self-hosted'"
mutate 'the classify job given a long timeout' "${J}['classify']['timeout-minutes'] = 60"
mutate 'the classify job in a container' "${J}['classify']['container'] = 'mcr.example/runner@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'"
mutate 'the classify output made a constant' "${J}['classify']['outputs']['docs_only'] = 'true'"
mutate 'the classify output read from another step' "${J}['classify']['outputs']['docs_only'] = '\${{ steps.other.outputs.docs_only }}'"
mutate 'the classify step tolerating failure' "${CS}[2]['continue-on-error'] = true"
mutate 'the classify step given a steering env' "${CS}[2]['env']['RUBYOPT'] = '-e0'"
mutate 'the classify step reading the base from the pull request body' "${CS}[2]['env']['BASE_SHA'] = '\${{ github.event.pull_request.title }}'"
mutate 'the classify step read the head from the title' "${CS}[2]['env']['HEAD_SHA'] = '\${{ github.event.pull_request.title }}'"
mutate 'the classifier step run with || true' "${CS}[2]['run'] = ${CS}[2]['run'].sub('--repo pr', '--repo pr || true')"
mutate 'the classifier step run with the missing-script fallback answering true' "${CS}[2]['run'] = ${CS}[2]['run'].sub(\"echo 'docs_only=false'\", \"echo 'docs_only=true'\")"
mutate 'the classifier step dropped' "${CS}.pop"
mutate 'the classifier given a step before the checkouts' "${CS}.unshift({ 'name' => 'Early', 'shell' => 'bash', 'run' => 'echo early' })"

# The short job for a documentation-only change.
mutate 'the policy-docs job removed' "${J}.delete('policy-docs')"
mutate 'the policy-docs job run on every change' "${J}['policy-docs']['if'] = '\${{ always() }}'"
mutate 'the policy-docs job run when classify says false' "${J}['policy-docs']['if'] = shape::GATE_IF"
mutate 'the policy-docs job no longer needs classify' "${J}['policy-docs'].delete('needs')"
mutate 'the policy-docs job given a long timeout' "${J}['policy-docs']['timeout-minutes'] = 60"
mutate 'the policy-docs job tolerating failure' "${J}['policy-docs']['continue-on-error'] = true"
mutate 'the policy-docs repository check turned into true' "${J}['policy-docs']['steps'][1]['run'] = 'true'"
mutate 'the policy-docs repository check tolerating failure' "${J}['policy-docs']['steps'][1]['continue-on-error'] = true"
mutate 'the policy-docs whitespace check dropped' "${J}['policy-docs']['steps'].pop"
mutate 'the policy-docs checkout keeps its credentials' "${J}['policy-docs']['steps'][0]['with']['persist-credentials'] = true"
mutate 'the policy-docs job given a policy step beside the two' "${J}['policy-docs']['steps'] << { 'name' => 'Extra', 'shell' => 'bash', 'run' => 'bash .github/policy/check-sizes.sh' }"

# The skip conditions of the heavy half: exactly one condition, on exactly these jobs.
for job in base-pass policy-evidence policy-fixtures policy-mutations policy-structure; do
  mutate "${job} no longer gated" "${J}['${job}'].delete('if')"
  mutate "${job} always run" "${J}['${job}']['if'] = '\${{ always() }}'"
  mutate "${job} gated by the opposite condition" "${J}['${job}']['if'] = shape::DOCS_IF"
  mutate "${job} gated by a looser condition" "${J}['${job}']['if'] = \"needs.classify.outputs.docs_only != 'yes'\""
  mutate "${job} no longer waits for classify" "${J}['${job}'].delete('needs')"
  mutate "${job} waits for another job as well" "${J}['${job}']['needs'] = ['classify', 'policy-docs']"
done
mutate 'a shard given continue-on-error' "${J}['policy-fixtures']['continue-on-error'] = true"

# The aggregate: needs everything, and its two guards are exact.
for job in base-pass classify policy-docs policy-evidence policy-fixtures policy-mutations policy-structure; do
  mutate "the aggregate no longer needs ${job}" "${J}['policy']['needs'].delete('${job}')"
done
mutate 'the aggregate loses its checkout-free steps (a third step added)' "${J}['policy']['steps'] << { 'name' => 'Extra', 'shell' => 'bash', 'run' => 'true' }"
mutate 'the aggregate guards swapped' "${J}['policy']['steps'].reverse!"
mutate 'a guard that passes a skipped shard when docs_only is false' "g = ${J}['policy']['steps'][1]; g['run'] = g['run'].sub('false) expected=success; docs_expected=skipped ;;', 'false) expected=\${POLICY_FIXTURES_RESULT}; docs_expected=skipped ;;')"
mutate 'a guard that passes a skipped base pass when docs_only is false' "g = ${J}['policy']['steps'][0]; g['run'] = g['run'].sub('false) expected=success;', 'false) expected=\${BASE_PASS_RESULT};')"
mutate 'a guard that accepts a failed shard beside a skipped one' "g = ${J}['policy']['steps'][1]; g['run'] = g['run'].sub('!= \"\${expected}\"', '== \"failure\"')"
mutate 'a guard that ignores a failed classification' "g = ${J}['policy']['steps'][0]; g['run'] = g['run'].sub(\"!= 'success'\", \"== 'never'\")"
mutate 'a guard that ignores the classification altogether' "g = ${J}['policy']['steps'][1]; g['env'].delete('CLASSIFY_RESULT'); g['run'] = \"set -euo pipefail\\nexpected=success; docs_expected=skipped\\n\" + g['run'].split(\"esac\\n\", 2).last"
mutate 'a guard reading the classification as a constant' "${J}['policy']['steps'][0]['env']['DOCS_ONLY'] = 'false'"
mutate 'a guard reading the classify result as a constant' "${J}['policy']['steps'][1]['env']['CLASSIFY_RESULT'] = 'success'"
mutate 'the shards guard no longer reads the policy-docs result' "${J}['policy']['steps'][1]['env'].delete('POLICY_DOCS_RESULT')"
mutate 'the shards guard reading the policy-docs result of another job' "${J}['policy']['steps'][1]['env']['POLICY_DOCS_RESULT'] = '\${{ needs.policy-fixtures.result }}'"
mutate 'a guard that never fails' "g = ${J}['policy']['steps'][1]; g['run'] = g['run'].sub('[[ \"\${failed}\" -eq 0 ]] || exit 1', 'true')"
mutate 'a guard that always passes' "${J}['policy']['steps'][0]['run'] = \"echo ok\\n\""
mutate 'a guard made conditional' "${J}['policy']['steps'][0]['if'] = \"github.event_name == 'push'\""
mutate 'a guard run as an argument to true' "${J}['policy']['steps'][1]['shell'] = 'true {0}'"
mutate 'the aggregate given a condition other than always' "${J}['policy']['if'] = 'needs.classify.outputs.docs_only != \"true\"'"
mutate 'the aggregate given a checkout' "${J}['policy']['steps'].unshift({ 'name' => 'Check out', 'uses' => shape::CHECKOUT + '' })"
# The sharded layout with the gates left behind is neither reviewed layout.
mutate 'both fast-path jobs removed but the gates left in place' "${J}.delete('classify'); ${J}.delete('policy-docs'); ${J}['policy']['steps'] = [${J}['policy']['steps'][0]]"

# The truth table of both guards, run as the entrypoint writes them. A guard passes exactly when classify
# succeeded and the classification is true with everything heavy skipped and policy-docs passed, or false with
# everything heavy passed and policy-docs skipped. Nothing else passes.
guard_script() { ruby -ryaml -e 'd = YAML.safe_load(File.read(ARGV[0]), aliases: false); print d["jobs"]["policy"]["steps"].find { |s| s["name"] == ARGV[1] }["run"]' "${tmp}/entry.yml" "$1"; }
base_guard="$(guard_script 'Require the base-policy workflow to have passed')"
shards_guard="$(guard_script 'Require every policy check shard to have passed')"
results=(success failure skipped cancelled '')
classes=(success failure skipped cancelled '')
docs_values=(true false '' TRUE maybe)
ran=0
# expect GUARD-NAME SCRIPT EXPECTED(pass|fail) NAME=VALUE...
expect() {
  local label="$1" script="$2" want="$3"; shift 3
  local got=fail
  if env "$@" bash -c "${script}" > "${tmp}/out" 2>&1; then got=pass; fi
  [[ "${got}" == "${want}" ]] || { cat "${tmp}/out" >&2; fail "${label}: expected ${want}, got ${got} for $*"; }
  ran=$((ran + 1))
}
for c in "${classes[@]}"; do
  for o in "${docs_values[@]}"; do
    for b in "${results[@]}"; do
      want=fail
      if [[ "${c}" == success && ( ( "${o}" == true && "${b}" == skipped ) || ( "${o}" == false && "${b}" == success ) ) ]]; then want=pass; fi
      expect 'the base-pass guard' "${base_guard}" "${want}" "BASE_PASS_RESULT=${b}" "CLASSIFY_RESULT=${c}" "DOCS_ONLY=${o}"
    done
  done
done
# Uniform shard results with every policy-docs result.
for c in "${classes[@]}"; do
  for o in "${docs_values[@]}"; do
    for s in "${results[@]}"; do
      for p in "${results[@]}"; do
        want=fail
        if [[ "${c}" == success && ( ( "${o}" == true && "${s}" == skipped && "${p}" == success ) || ( "${o}" == false && "${s}" == success && "${p}" == skipped ) ) ]]; then want=pass; fi
        expect 'the shards guard (uniform)' "${shards_guard}" "${want}" "CLASSIFY_RESULT=${c}" "DOCS_ONLY=${o}" "POLICY_DOCS_RESULT=${p}" \
          "POLICY_EVIDENCE_RESULT=${s}" "POLICY_FIXTURES_RESULT=${s}" "POLICY_MUTATIONS_RESULT=${s}" "POLICY_STRUCTURE_RESULT=${s}"
      done
    done
  done
done
# One job deviating from the accepted outcome, for each outcome and each result: only the accepted result passes.
shard_vars=(POLICY_EVIDENCE_RESULT POLICY_FIXTURES_RESULT POLICY_MUTATIONS_RESULT POLICY_STRUCTURE_RESULT POLICY_DOCS_RESULT)
for o in true false; do
  if [[ "${o}" == true ]]; then heavy=skipped; docs=success; else heavy=success; docs=skipped; fi
  for odd in "${shard_vars[@]}"; do
    for r in "${results[@]}"; do
      env_args=("CLASSIFY_RESULT=success" "DOCS_ONLY=${o}")
      for v in "${shard_vars[@]}"; do
        val="${heavy}"; [[ "${v}" != POLICY_DOCS_RESULT ]] || val="${docs}"
        if [[ "${v}" == "${odd}" ]]; then val="${r}"; fi
        env_args+=("${v}=${val}")
      done
      accepted="${heavy}"; [[ "${odd}" != POLICY_DOCS_RESULT ]] || accepted="${docs}"
      want=fail; [[ "${r}" != "${accepted}" ]] || want=pass
      expect "the shards guard (${odd}=${r}, docs_only=${o})" "${shards_guard}" "${want}" "${env_args[@]}"
    done
  done
done
echo "accepted  both guards over their truth table (${ran} runs)"

echo 'docs fast path layout: the classified layout is accepted and each weakening of it is refused, and both guards pass only the two allowed outcomes'
