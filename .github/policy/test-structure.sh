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

# --strict is the policy job's OWN-copy mode, so it is exercised only on a synthetic tree built here:
# the base pass runs this very script against the pull request's real tree, where a step-B tree
# matches only the final shape while main's manifest still lists the transitional alternative, and
# --strict would (correctly) refuse that. The helpers refuse any root that is not marked synthetic,
# so no strict case can ever run on the real tree.
make_synth() { # builds the synthetic tree ${dir}/s and the check copy ${dir}/v/synth.rb whose manifest matches it
  rm -rf "${dir:?}/s" "${dir:?}/v"; mkdir -p "${dir}/s/.github/workflows" "${dir}/s/.github/policy" "${dir}/v"
  cp "${src}/.github/workflows/validate-public-changes.yml" "${src}/.github/workflows/cache-prune.yml" "${dir}/s/.github/workflows/"
  cp "${src}/.github/policy/workflow-lists.sh" "${dir}/s/.github/policy/"
  : > "${dir}/s/.synthetic"
}
synth_runner() { # [PRUNE_JSON]: the check copy's manifest becomes the synthetic tree's structure, optionally with its cache-prune entry replaced
  cp "${check}" "${dir}/v/synth.rb"; cp "${check%/*}/yaml-guard.rb" "${dir}/v/"
  ruby "${check}" --json-actual "${dir}/s" > "${dir}/v/actual.json"
  # The literal is built from JSON with inspect, not read from --print, whose formatting differs between Ruby versions.
  PRUNE="${1:-}" ruby -rjson -e 's = File.read(ARGV[0]); m = JSON.parse(File.read(ARGV[1])); m["workflows"][".github/workflows/cache-prune.yml"] = JSON.parse(ENV["PRUNE"]) unless ENV["PRUNE"].to_s.empty?; re = /^CONTROL_PLANE_MANIFEST = \{.*?\}\.freeze$/m; abort("manifest not found") unless s.match?(re); File.write(ARGV[0], s.sub(re) { "CONTROL_PLANE_MANIFEST = #{m.inspect}.freeze" })' "${dir}/v/synth.rb" "${dir}/v/actual.json"
}
strict_root() { [[ -f "${dir}/s/.synthetic" && ! -e "${dir}/s/.github/policy/check-structure.rb" ]] || { echo 'a --strict case must run on the synthetic tree only' >&2; exit 1; }; }
expect_strict_reject() { # LABEL MESSAGE
  local out; strict_root
  if out="$(ruby "${dir}/v/synth.rb" --strict "${dir}/s" 2>&1)"; then echo "NOT rejected under --strict: $1" >&2; exit 1; fi
  grep -qF -- "$2" <<<"${out}" || { echo "rejected $1 for the wrong reason ($2):" >&2; echo "${out}" >&2; exit 1; }
  echo "rejected  $1"
}
expect_strict_accept() { # LABEL
  local out; strict_root
  out="$(ruby "${dir}/v/synth.rb" --strict "${dir}/s" 2>&1)" || { echo "rejected under --strict, expected accepted: $1" >&2; echo "${out}" >&2; exit 1; }
  echo "accepted  $1"
}

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
prune_old_json='{"tier":"public","triggers":["schedule","workflow_dispatch"],"jobs":["prune"]}'
prune_new_json='{"tier":"public","triggers":["push","schedule","workflow_dispatch"],"jobs":["prune"]}'
# --strict (the policy job's own copy) turns the lingering-alternative warning into an error, so step B
# must have deleted its transitional alternatives; step A (tree on a non-final shape) is unaffected.
make_synth; swap_s() { OLD="$1" NEW="$2" ruby -e 's = File.read(ARGV[0]); i = s.index(ENV["OLD"]) or abort("text not found"); s[i, ENV["OLD"].length] = ENV["NEW"]; File.write(ARGV[0], s)' "${dir}/s/.github/workflows/cache-prune.yml"; }
swap_s 'workflow_dispatch:' 'workflow_dispatch:
  push:'
synth_runner "[${prune_new_json}, ${prune_old_json}]"
expect_strict_reject 'strict: step B left its transitional alternative behind' 'transitional alternative(s) remain'
synth_runner
expect_strict_accept 'strict: step B with the alternative deleted'
make_synth; synth_runner "[${prune_new_json}, ${prune_old_json}]"
expect_strict_accept 'strict: step A (tree still on the transitional shape)'
# The strict helpers refuse a root that is not the synthetic tree, so no strict case can run on the real tree.
fresh; mkdir -p "${dir}/s"; rm -f "${dir}/s/.synthetic"
if (strict_root) 2>/dev/null; then echo 'strict_root accepted a tree that is not synthetic' >&2; exit 1; fi
echo 'refused   a --strict case on a tree that is not the synthetic one'
# A job added that is in neither alternative (linux-validation.yml, whatever its alternatives are).
fresh; swap .github/workflows/linux-validation.yml '
jobs:
' '
jobs:
  surprise:
    runs-on: ubuntu-24.04
    steps:
      - run: echo
'
expect_reject 'a job added that is in neither alternative' 'linux-validation.yml'
# A tree that matches neither shape, and a changed field outside both.
fresh; swap .github/workflows/cache-prune.yml 'workflow_dispatch:' 'workflow_dispatch:
  pull_request:'
variant "${prune_old}" "[${prune_new}, ${prune_old}]"
expect_reject 'a tree matching neither alternative' 'matches none of the 2 reviewed shapes'
# A tree holding the job sets of BOTH alternatives (final jobs plus the old ones) matches neither shape:
# each alternative is matched exactly, never as a union. The same case kills a union-matcher mutant.
alt_a='{"tier" => "public", "triggers" => ["schedule", "workflow_dispatch"], "jobs" => ["p1", "prune"]}'
alt_b='{"tier" => "public", "triggers" => ["schedule", "workflow_dispatch"], "jobs" => ["p2", "prune"]}'
fresh; swap .github/workflows/cache-prune.yml '
jobs:
' '
jobs:
  p1:
    runs-on: ubuntu-24.04
    steps:
      - run: echo
  p2:
    runs-on: ubuntu-24.04
    steps:
      - run: echo
'
variant "${prune_old}" "[${alt_a}, ${alt_b}]"
expect_reject 'a tree holding the job sets of both alternatives' 'matches none of the 2 reviewed shapes'
OLD='hit = alts.index(state)' NEW="hit = alts.index(state) || (state.is_a?(Hash) && state['jobs'].all? { |j| alts.any? { |a| a.is_a?(Hash) && a['jobs'].include?(j) } } ? 0 : nil)" \
  ruby -e 's = File.read(ARGV[0]); i = s.index(ENV["OLD"]) or abort("mutation text not found"); s[i, ENV["OLD"].length] = ENV["NEW"]; File.write(ARGV[0], s)' "${runner}"
if ruby "${runner}" "${dir}/t" >/dev/null 2>&1; then echo 'bites     a union matcher accepts that tree, so the fixture kills it'; else echo 'MUTANT SURVIVED: the union matcher still refuses the both-alternatives tree' >&2; exit 1; fi
# Absent as a transitional alternative: a deleted workflow, then a new one.
fresh; rm "${dir}/t/.github/workflows/cache-prune.yml"
variant "\".github/workflows/cache-prune.yml\" =>
    ${prune_old}" "\".github/workflows/cache-prune.yml\" =>
    [\"absent\", ${prune_old}]"
expect_accept 'step A of a deletion: the workflow may be absent'

# A composite may be listed as present-or-absent while it is added or removed (step A).
cr='".github/actions/concern-report/action.yml" => "present"'
fresh; variant "${cr}" '".github/actions/concern-report/action.yml" => ["present", "absent"]'
expect_accept 'a composite listed present-or-absent, present'
rm -r "${dir}/t/.github/actions/concern-report"
expect_accept 'a composite listed present-or-absent, absent'
fresh; variant "${cr}" '".github/actions/concern-report/action.yml" => ["present", "absent"]'
mkdir -p "${dir}/t/.github/actions/unlisted"; printf 'name: x\n' > "${dir}/t/.github/actions/unlisted/action.yml"
expect_reject 'an unlisted composite beside a present-or-absent entry' 'a composite action with no manifest entry'

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
