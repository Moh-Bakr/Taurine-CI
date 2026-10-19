#!/usr/bin/env bash
# Fixtures for check-wave-c-wiring.rb on synthetic trees (it reads four workflow files and four script names, so
# a synthetic tree is enough and the result does not depend on the tree this runs in): the Wave C shape with
# everything wired passes; each of the four wiring steps removed, made conditional, tolerated or reordered is
# refused; a missing script is refused; a tree without the Wave C shape is skipped. Run from the repository root.
set -euo pipefail
check="${PWD}/.github/policy/check-wave-c-wiring.rb"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

good_tree() { # good_tree NAME: a synthetic Wave C tree at ${work}/NAME
  local t="${work}/$1"
  rm -rf "${t}"; mkdir -p "${t}/.github/workflows" "${t}/.github/policy"
  for s in test-timings-table.sh test-rust-app-shards.sh test-suite-ownership-check.sh refuse-unowned-tests.rb; do : > "${t}/.github/policy/${s}"; done
  cat > "${t}/.github/workflows/linux-validation.yml" <<'Y'
jobs:
  validate-input: {}
  validate-long-main: {}
  validate-long-untrusted: {}
  validate-main: {}
Y
  cat > "${t}/.github/workflows/validate-public-changes.yml" <<'Y'
jobs:
  policy:
    steps:
      - name: Test the Timings table
        shell: bash
        run: bash .github/policy/test-timings-table.sh
      - name: Prove the shards
        shell: bash
        run: bash .github/policy/test-rust-app-shards.sh
      - name: Test the ownership check
        shell: bash
        run: bash .github/policy/test-suite-ownership-check.sh
Y
  cat > "${t}/.github/workflows/linux-validation-concern.yml" <<'Y'
jobs:
  validate:
    steps:
      - uses: ./.github/actions/source-checkout
      - uses: ./.github/actions/drop-root
      - name: Refuse test files with no suite owner before any build
        shell: bash
        run: |
          set -euo pipefail
          ruby .github/policy/refuse-unowned-tests.rb "${GITHUB_WORKSPACE}/src"
Y
}
expect() { # expect LABEL NAME rc [text]
  local out rc=0
  out="$(cd "${work}/$2" && ruby "${check}" 2>&1)" || rc=$?
  [[ "${rc}" == "$3" ]] || { echo "wave C wiring case '$1': exit ${rc}, wanted $3: ${out}" >&2; exit 1; }
  [[ -z "${4:-}" ]] || grep -qF -- "$4" <<<"${out}" || { echo "wave C wiring case '$1': output lacks '$4': ${out}" >&2; exit 1; }
}
edit() { # edit NAME FILE OLD NEW
  OLD="$3" NEW="$4" ruby -e 't = File.read(ARGV[0]); i = t.index(ENV["OLD"]) or abort("fixture text not found: #{ENV["OLD"][0, 50]}"); t[i, ENV["OLD"].length] = ENV["NEW"]; File.write(ARGV[0], t)' "${work}/$1/$2"
}
policy=.github/workflows/validate-public-changes.yml
concern=.github/workflows/linux-validation-concern.yml

good_tree t; expect 'all wired' t 0 'all present'
for script in test-timings-table.sh test-rust-app-shards.sh test-suite-ownership-check.sh; do
  good_tree t; edit t "${policy}" "run: bash .github/policy/${script}" 'run: "true"'; expect "policy step for ${script} dropped" t 1 "no longer runs ${script}"
  good_tree t; edit t "${policy}" "run: bash .github/policy/${script}" "run: bash .github/policy/${script} || true"; expect "policy step for ${script} made best-effort" t 1 "no longer runs ${script}"
  good_tree t; rm "${work}/t/.github/policy/${script}"; expect "${script} missing" t 1 "${script} is missing"
done
good_tree t; edit t "${policy}" $'        shell: bash\n        run: bash .github/policy/test-timings-table.sh' $'        shell: bash\n        if: false\n        run: bash .github/policy/test-timings-table.sh'; expect 'a policy step with a condition' t 1 'no longer runs test-timings-table.sh'
good_tree t; edit t "${concern}" 'ruby .github/policy/refuse-unowned-tests.rb' 'true'; expect 'the early step dropped' t 1 'no longer runs refuse-unowned-tests.rb'
good_tree t; edit t "${concern}" $'        shell: bash\n        run: |' $'        shell: bash\n        continue-on-error: true\n        run: |'; expect 'the early step tolerated' t 1 'conditional or tolerated'
good_tree t; edit t "${concern}" $'        shell: bash\n        run: |' $'        shell: bash\n        if: always()\n        run: |'; expect 'the early step conditional' t 1 'conditional or tolerated'
good_tree t; edit t "${concern}" $'      - uses: ./.github/actions/drop-root\n' ''; edit t "${concern}" $'      - name: Refuse' $'      - uses: ./.github/actions/drop-root\n      - name: Refuse'; ruby -e 'f=ARGV[0]; t=File.read(f); a=t.index("      - uses: ./.github/actions/source-checkout\n"); t.slice!(a, "      - uses: ./.github/actions/source-checkout\n".length); t << "      - uses: ./.github/actions/source-checkout\n"; File.write(f,t)' "${work}/t/${concern}"; expect 'the early step before the checkout' t 1 'must follow the source checkout'
good_tree t; edit t "${concern}" $'      - uses: ./.github/actions/drop-root\n' ''; expect 'no root drop before the early step' t 1 'must follow the source checkout and the root drop'
# a tree that is not in the Wave C shape is skipped, whatever else it holds
good_tree t; edit t .github/workflows/linux-validation.yml 'jobs:' $'jobs:\n  plan: {}'; expect 'a plan job beside the long-pole jobs is not the Wave C shape' t 0 'skipped'
good_tree t; edit t .github/workflows/linux-validation.yml '  validate-long-main: {}' ''; expect 'no long-pole job is not the Wave C shape' t 0 'skipped'
echo 'wave C wiring: a Wave C tree missing any of its four wiring steps is refused; any other tree is skipped'
