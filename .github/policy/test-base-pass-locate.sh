#!/usr/bin/env bash
# The tests that run the base-pass step find it in whichever public policy workflow holds it, and
# only when exactly one does. Run from the repository root.
set -euo pipefail

root="${PWD}"
tmp="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/base-pass-locate-test.XXXXXX")"
trap 'rm -rf -- "${tmp}"' EXIT
step="Run the base commit's policy against this pull request"

# A tree holding only what the helper reads: the policy scripts and the two workflow slots.
tree() {
  rm -rf "${tmp}/t"; mkdir -p "${tmp}/t/.github/workflows"
  cp -R "${root}/.github/policy" "${tmp}/t/.github/policy"
}
workflow_with_step() {
  printf '%s\n' 'on: workflow_call' 'permissions: {}' 'jobs:' '  one:' '    runs-on: ubuntu-24.04' '    steps:' \
    "      - name: ${1}" '        run: "true"'
}
locate() { (cd "${tmp}/t" && bash -c 'source .github/policy/base-pass-workflow.sh && locate_base_pass_workflow "$1"' _ "${step}" 2> "${tmp}/err"); }
expect_found() {
  local want="$1" got
  got="$(locate)" || { echo "base-pass locate: ${2}: the step was not found" >&2; cat "${tmp}/err" >&2; exit 1; }
  [[ "${got}" == "${want}" ]] || { echo "base-pass locate: ${2}: found ${got}, wanted ${want}" >&2; exit 1; }
}
expect_refused() {
  if locate > /dev/null; then echo "base-pass locate: ${1}: a bad layout was accepted" >&2; exit 1; fi
  grep -q 'expected exactly one' "${tmp}/err" || { echo "base-pass locate: ${1}: refused for another reason" >&2; cat "${tmp}/err" >&2; exit 1; }
}
entry=.github/workflows/validate-public-changes.yml
reusable=.github/workflows/base-policy.yml

tree; workflow_with_step "${step}" > "${tmp}/t/${entry}"
expect_found "${entry}" 'the step in the entrypoint only'

tree; workflow_with_step "${step}" > "${tmp}/t/${reusable}"; workflow_with_step 'Another step' > "${tmp}/t/${entry}"
expect_found "${reusable}" 'the step in the reusable workflow only'

tree; workflow_with_step "${step}" > "${tmp}/t/${reusable}"; workflow_with_step "${step}" > "${tmp}/t/${entry}"
expect_refused 'the step in both workflows'

tree; workflow_with_step 'Another step' > "${tmp}/t/${entry}"
expect_refused 'the step in neither'

tree; { workflow_with_step "${step}"; printf '%s\n' "      - name: ${step}" '        run: "true"'; } > "${tmp}/t/${entry}"
expect_refused 'the step twice in one workflow'

echo 'base-pass locate: the step is found in the entrypoint or the reusable workflow, and only when exactly one holds it'
