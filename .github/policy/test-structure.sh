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
  runner=''
  rm -rf "${dir}/t"; mkdir -p "${dir}/t"
  cp -R "${src}/.github" "${dir}/t/"
}
# expect_reject LABEL MESSAGE: the check must fail and print MESSAGE.
expect_reject() {
  local out
  if out="$(ruby "${runner:-${check}}" "${dir}/t" 2>&1)"; then
    echo "NOT rejected: $1" >&2; exit 1
  fi
  if ! grep -qF -- "$2" <<<"${out}"; then
    echo "rejected $1, but not for the expected reason ($2):" >&2; echo "${out}" >&2; exit 1
  fi
  echo "rejected  $1"
}
# variant OLD NEW: a copy of the check whose manifest text has OLD replaced by NEW (the manifest is
# a constant in the script, so a manifest case is a script variant). Sets runner to the copy.
variant() {
  mkdir -p "${dir}/v"; cp "${check}" "${dir}/v/variant.rb"; cp "${check%/*}/yaml-guard.rb" "${dir}/v/"
  OLD="$1" NEW="$2" ruby -e 's = File.read(ARGV[0]); i = s.index(ENV["OLD"]) or abort("manifest text not found: #{ENV["OLD"][0, 60]}"); s[i, ENV["OLD"].length] = ENV["NEW"]; File.write(ARGV[0], s)' "${dir}/v/variant.rb"
  runner="${dir}/v/variant.rb"
}
# expect_accept LABEL [MESSAGE]: the (variant) check passes, optionally printing MESSAGE.
expect_accept() {
  local out
  out="$(ruby "${runner:-${check}}" "${dir}/t" 2>&1)" || { echo "rejected, expected accepted: $1" >&2; echo "${out}" >&2; exit 1; }
  if [[ -n "${2:-}" ]] && ! grep -qF -- "$2" <<<"${out}"; then echo "accepted $1 without '$2':" >&2; echo "${out}" >&2; exit 1; fi
  echo "accepted  $1"
}
swap() { # FILE OLD NEW (relative to the fixture tree)
  OLD="$2" NEW="$3" ruby -e 's = File.read(ARGV[0]); i = s.index(ENV["OLD"]) or abort("text not found: #{ENV["OLD"][0, 60]}"); s[i, ENV["OLD"].length] = ENV["NEW"]; File.write(ARGV[0], s)' "${dir}/t/$1"
}

fresh
ruby "${check}" "${dir}/t" >/dev/null || { echo 'the reviewed tree fails its own structure check' >&2; exit 1; }
echo 'accepted  the reviewed tree'

# The constant equals the structure of the tree (compared as JSON; the Ruby literal's formatting
# differs between Ruby versions, so --print is for humans only).
actual_json="$(ruby "${check}" --json-actual "${dir}/t")"
[[ "${actual_json}" == '{"required_check"'* && "${actual_json}" == "$(ruby "${check}" --json-manifest "${dir}/t")" ]] \
  || { echo 'CONTROL_PLANE_MANIFEST differs from the structure of the tree' >&2; exit 1; }
echo 'accepted  the manifest equals the tree structure'

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

fresh; swap "${public}" '  base-pass:
' '  base-pass-moved:
'
expect_reject 'another job renamed in the policy workflow' 'jobs changed'

fresh; mv "${dir}/t/.github/workflows/base-policy.yml" "${dir}/t/.github/workflows/base-policy-moved.yml"
expect_reject 'the reusable base-policy workflow renamed' 'in the manifest but missing from the tree'

fresh; swap .github/policy/workflow-lists.sh 'public_policy_reusable_workflow=".github/workflows/base-policy.yml"' 'public_policy_reusable_workflow=".github/workflows/elsewhere.yml"'
expect_reject 'the reusable base-policy workflow dropped from its tier' 'tier changed'

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

# --- Changing the shape in two steps (alternatives) ---
prune_old='{"tier" => "public", "triggers" => ["schedule", "workflow_dispatch"], "jobs" => ["prune"]}'
prune_new='{"tier" => "public", "triggers" => ["push", "schedule", "workflow_dispatch"], "jobs" => ["prune"]}'
pub='".github/workflows/validate-public-changes.yml" =>'

# Step A: the new shape is added as the first alternative; the tree still has the old one.
fresh; variant "${prune_old}" "[${prune_new}, ${prune_old}]"
expect_accept 'step A: the tree matches the transitional (old) alternative'
# Step B as the base's copy (step A's manifest) sees it: the tree changed; accepted, with a warning.
fresh; swap .github/workflows/cache-prune.yml 'workflow_dispatch:' 'workflow_dispatch:
  push:'
variant "${prune_old}" "[${prune_new}, ${prune_old}]"
expect_accept 'step B under the base copy: the new tree matches the first alternative' 'transitional alternative(s) remain'
# Step B under its own copy (the old alternative deleted).
variant "${prune_old}" "${prune_new}"
expect_accept 'step B under its own copy: the new shape alone'
# A tree that matches neither shape, and a changed field outside both.
fresh; swap .github/workflows/cache-prune.yml 'workflow_dispatch:' 'workflow_dispatch:
  pull_request:'
variant "${prune_old}" "[${prune_new}, ${prune_old}]"
expect_reject 'a tree matching neither alternative' 'matches none of the 2 reviewed shapes'
# Absent as a transitional alternative: a deleted workflow, then a new one.
fresh; rm "${dir}/t/.github/workflows/cache-prune.yml"
variant "\".github/workflows/cache-prune.yml\" =>
    ${prune_old}" "\".github/workflows/cache-prune.yml\" =>
    [\"absent\", ${prune_old}]"
expect_accept 'step A of a deletion: the workflow may be absent'

# Wildcards, supersets and unknown keys in the manifest are refused.
fresh; variant "${prune_old}" '{"tier" => "public", "triggers" => ["schedule", "workflow_*"], "jobs" => ["prune"]}'
expect_reject 'a wildcard trigger in the manifest' 'exact plain names'
fresh; variant "${prune_old}" '{"tier" => "public", "triggers" => ["schedule", "workflow_dispatch"], "jobs" => ["prune"], "any_extra" => ["*"]}'
expect_reject 'an extra key (superset rule) in an alternative' 'exactly tier, triggers and jobs'
fresh; variant "${prune_old}" '{"tier" => "public", "triggers" => ["workflow_dispatch", "schedule"], "jobs" => ["prune"]}'
expect_reject 'an unsorted name list (a pattern-like loophole)' 'sorted list of exact plain names'
# The forbidden-trigger denial applies to every alternative, even one the tree does not match.
fresh; variant "${prune_old}" "[${prune_old}, {\"tier\" => \"public\", \"triggers\" => [\"pull_request_target\"], \"jobs\" => [\"prune\"]}]"
expect_reject 'a forbidden trigger in a transitional alternative' 'lists the forbidden trigger pull_request_target'
# The required-check pin applies to every alternative.
pol_old='{"tier" => "policy",
     "triggers" => ["pull_request", "push", "workflow_dispatch"],
     "jobs" => ["base-pass", "policy"]}'
fresh; variant "${pol_old}" "[${pol_old}, {\"tier\" => \"policy\", \"triggers\" => [\"pull_request\", \"push\", \"workflow_dispatch\"], \"jobs\" => [\"base-pass\"]}]"
expect_reject 'an alternative without the required check job' 'lacks the required check job policy'
fresh; variant "${pol_old}" "[${pol_old}, \"absent\"]"
expect_reject 'an alternative that lets the policy workflow be absent' 'required status check would be dropped'

# --- YAML 1.1 spellings and duplicate keys ---
# The quoted "on" beside a bare on (read as true) hides a trigger from a one-key reader.
fresh; printf '\n"on":\n  push:\n' >> "${dir}/t/.github/workflows/cache-prune.yml"
expect_reject 'a quoted "on" next to the bare on key' 'on'

fresh; ruby -e 'f = ARGV[0]; s = File.read(f); File.write(f, s.sub(/^on:\n/, "true:\n  workflow_run:\n    workflows: [x]\n  workflow_dispatch:\n"))' "${dir}/t/.github/workflows/cache-prune.yml"
expect_reject 'a bare true key hiding workflow_run' 'workflow_run is never allowed'
fresh; printf '\njobs:\n  extra:\n    runs-on: ubuntu-24.04\n' >> "${dir}/t/.github/workflows/cache-prune.yml"
expect_reject 'a duplicate jobs key' 'the key "jobs" appears twice'
fresh; printf '\npermissions: {}\n' >> "${dir}/t/.github/workflows/cache-prune.yml"
expect_reject 'a duplicate top-level key (permissions)' 'appears twice'

echo 'structure tests: every unreviewed control-plane change is rejected'
