#!/usr/bin/env bash
# Fixture tests for the control-plane structure check (check-structure.rb): the reviewed tree
# passes, and each structural change that must not slip through unreviewed is rejected with its
# own message while the manifest constant stays as reviewed. Run from the repository root.
set -euo pipefail

src="${PWD}"
dir="$(mktemp -d)"
trap 'rm -rf "${dir}"' EXIT
check="${src}/.github/policy/check-structure.rb"
public=.github/workflows/validate-public-changes.yml

fresh() {
  rm -rf "${dir}/t"; mkdir -p "${dir}/t"
  cp -R "${src}/.github" "${dir}/t/"
}
# expect_reject LABEL MESSAGE: the check must fail and print MESSAGE.
expect_reject() {
  local out
  if out="$(ruby "${check}" "${dir}/t" 2>&1)"; then
    echo "NOT rejected: $1" >&2; exit 1
  fi
  if ! grep -qF -- "$2" <<<"${out}"; then
    echo "rejected $1, but not for the expected reason ($2):" >&2; echo "${out}" >&2; exit 1
  fi
  echo "rejected  $1"
}
swap() { # FILE OLD NEW (relative to the fixture tree)
  OLD="$2" NEW="$3" ruby -e 's = File.read(ARGV[0]); i = s.index(ENV["OLD"]) or abort("text not found: #{ENV["OLD"][0, 60]}"); s[i, ENV["OLD"].length] = ENV["NEW"]; File.write(ARGV[0], s)' "${dir}/t/$1"
}

fresh
ruby "${check}" "${dir}/t" >/dev/null || { echo 'the reviewed tree fails its own structure check' >&2; exit 1; }
echo 'accepted  the reviewed tree'

# --print reproduces the constant in the script (the manifest is not stale or hand-drifted).
ruby "${check}" --print "${dir}/t" | diff -q - <(sed -n '/^CONTROL_PLANE_MANIFEST/,/\.freeze$/p' "${check}") >/dev/null \
  || { echo 'CONTROL_PLANE_MANIFEST differs from `check-structure.rb --print`' >&2; exit 1; }
echo 'accepted  the manifest equals the printed structure'

fresh; rm "${dir}/t/.github/workflows/cache-prune.yml"
expect_reject 'a workflow deleted' 'in the manifest but missing from the tree'

fresh; mv "${dir}/t/.github/workflows/cache-prune.yml" "${dir}/t/.github/workflows/cache-prune-renamed.yml"
expect_reject 'a workflow renamed (new name has no entry)' 'a workflow with no manifest entry'

fresh; cp "${dir}/t/.github/workflows/cache-prune.yml" "${dir}/t/.github/workflows/extra.yml"
expect_reject 'a new workflow without an owner entry' 'extra.yml: a workflow with no manifest entry'

fresh; rm "${dir}/t/.github/actions/timings/action.yml"
expect_reject 'a composite action removed' 'in the manifest but missing from the tree'

fresh; mkdir "${dir}/t/.github/actions/novel"; cp "${dir}/t/.github/actions/timings/action.yml" "${dir}/t/.github/actions/novel/action.yml"
expect_reject 'a new composite action without an entry' 'a composite action with no manifest entry'

fresh; swap "${public}" '  policy:
' '  policy-renamed:
'
expect_reject 'the required job id renamed' 'would be dropped'

fresh; swap "${public}" '    name: Validate workflow policy' '    name: Validate workflow policy (renamed)'
expect_reject 'the required check renamed' 'not "Validate workflow policy"'

fresh; swap "${public}" '  base-policy:
' '  base-policy-moved:
'
expect_reject 'another job renamed in the policy workflow' 'jobs changed'

fresh; swap .github/workflows/cache-prune.yml 'workflow_dispatch:' 'workflow_dispatch:
  push:'
expect_reject 'a trigger added' 'triggers changed'

fresh; swap .github/workflows/cache-prune.yml 'workflow_dispatch:' 'pull_request_target:'
expect_reject 'a trigger widened to pull_request_target' 'pull_request_target is never allowed'

fresh; swap .github/workflows/cache-prune.yml 'workflow_dispatch:' 'workflow_run:
    workflows: [x]'
expect_reject 'a trigger widened to workflow_run' 'workflow_run is never allowed'

fresh; swap .github/policy/workflow-lists.sh '  ".github/workflows/ios-validation.yml"
' ''
expect_reject 'a protected workflow dropped from its trust tier' 'tier changed'

echo 'structure tests: every unreviewed control-plane change is rejected'
