#!/usr/bin/env bash
# Fixtures for check-wave-c-wiring.rb on synthetic trees (it reads four workflow files and four script names, so
# a synthetic tree is enough and the result does not depend on the tree this runs in): the Wave C shape with
# everything wired passes; each of the four wiring steps removed, made conditional, tolerated or reordered is
# refused; a missing script is refused; the reviewed Linux concern env and defaults must be exact; a tree without the
# Wave C shape is refused (the shape is no longer transitional). Run from the repository root.
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
env:
  SOURCE_REPOSITORY_ID: '1330267721'
  SOURCE_REPOSITORY_OWNER: Moh-Bakr
  SOURCE_REPOSITORY_NAME: Taurine
jobs:
  validate:
    defaults:
      run:
        working-directory: src
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
good_tree t; edit t "${concern}" 'refuse-unowned-tests.rb "${GITHUB_WORKSPACE}/src"' 'refuse-unowned-tests.rb "${GITHUB_WORKSPACE}/src" || true'; expect 'the early step made best-effort' t 1 'exactly the reviewed command'
good_tree t; edit t "${concern}" 'ruby .github/policy/refuse-unowned-tests.rb' 'echo ruby .github/policy/refuse-unowned-tests.rb'; expect 'the early step only echoed' t 1 'exactly the reviewed command'
good_tree t; edit t "${concern}" $'        shell: bash\n        run: |\n          set -euo pipefail\n          ruby' $'        shell: sh\n        run: |\n          set -euo pipefail\n          ruby'; expect 'the early step under another shell' t 1 'must use shell: bash'
good_tree t; edit t "${concern}" $'        shell: bash\n        run: |\n          set -euo pipefail\n          ruby' $'        shell: bash\n        env:\n          X: y\n        run: |\n          set -euo pipefail\n          ruby'; expect 'the early step with an env key' t 1 'keys beyond name, shell, working-directory and run'
good_tree t; edit t "${concern}" $'        shell: bash\n        run: |' $'        shell: bash\n        continue-on-error: true\n        run: |'; expect 'the early step tolerated' t 1 'conditional or tolerated'
good_tree t; edit t "${concern}" $'        shell: bash\n        run: |' $'        shell: bash\n        if: always()\n        run: |'; expect 'the early step conditional' t 1 'conditional or tolerated'
good_tree t; edit t "${concern}" $'      - uses: ./.github/actions/drop-root\n' ''; edit t "${concern}" $'      - name: Refuse' $'      - uses: ./.github/actions/drop-root\n      - name: Refuse'; ruby -e 'f=ARGV[0]; t=File.read(f); a=t.index("      - uses: ./.github/actions/source-checkout\n"); t.slice!(a, "      - uses: ./.github/actions/source-checkout\n".length); t << "      - uses: ./.github/actions/source-checkout\n"; File.write(f,t)' "${work}/t/${concern}"; expect 'the early step before the checkout' t 1 'must follow the source checkout'
good_tree t; edit t "${concern}" $'      - uses: ./.github/actions/drop-root\n' ''; expect 'no root drop before the early step' t 1 'must follow the source checkout and the root drop'
# The reviewed Linux concern environment: the workflow env, the job env and the job defaults are pinned.
good_tree t; edit t "${concern}" $'  SOURCE_REPOSITORY_NAME: Taurine\n' $'  SOURCE_REPOSITORY_NAME: Taurine\n  BASH_ENV: src/evil.sh\n'; expect 'a variable added to the workflow env' t 1 'workflow env must be exactly'
good_tree t; edit t "${concern}" $'  SOURCE_REPOSITORY_NAME: Taurine\n' $'  SOURCE_REPOSITORY_NAME: Other\n'; expect 'a workflow env value changed' t 1 'workflow env must be exactly'
good_tree t; edit t "${concern}" $'  SOURCE_REPOSITORY_OWNER: Moh-Bakr\n' ''; expect 'a workflow env variable removed' t 1 'workflow env must be exactly'
good_tree t; edit t "${concern}" $'env:\n  SOURCE_REPOSITORY_ID' $'defaults:\n  run:\n    shell: sh\nenv:\n  SOURCE_REPOSITORY_ID'; expect 'workflow-level defaults added' t 1 'no workflow-level defaults'
good_tree t; edit t "${concern}" $'  validate:\n' $'  validate:\n    env:\n      PATH: src/bin\n'; expect 'a job env added to validate' t 1 'no env of its own'
good_tree t; edit t "${concern}" $'  validate:\n' $'  validate:\n    env: {}\n'; expect 'an empty job env key on validate' t 1 'no env of its own'
good_tree t; edit t "${concern}" $'        working-directory: src\n' $'        working-directory: .\n'; expect 'the default working directory changed' t 1 'defaults must be exactly'
good_tree t; edit t "${concern}" $'        working-directory: src\n' $'        working-directory: src\n        shell: sh\n'; expect 'a default shell added' t 1 'defaults must be exactly'
good_tree t; edit t "${concern}" $'    defaults:\n      run:\n        working-directory: src\n' ''; expect 'the job defaults removed' t 1 'defaults must be exactly'
# a tree that lost the Wave C shape is refused, whatever else it holds
good_tree t; edit t .github/workflows/linux-validation.yml 'jobs:' $'jobs:\n  plan: {}'; expect 'a plan job beside the long-pole jobs is not the Wave C shape' t 1 'no longer has the Wave C shape'
good_tree t; edit t .github/workflows/linux-validation.yml '  validate-long-main: {}' ''; expect 'no long-pole job is not the Wave C shape' t 1 'no longer has the Wave C shape'
echo 'wave C wiring: a tree missing any of its four wiring steps, with a changed concern env or defaults, or without the Wave C shape is refused'
