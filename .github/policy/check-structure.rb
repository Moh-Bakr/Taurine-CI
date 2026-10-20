#!/usr/bin/env ruby
# frozen_string_literal: true

# Control-plane structure check.
#
# GitHub's `workflows` ruleset rule is Enterprise-only, so the ruleset "Protect CI control plane"
# can only require the status check "Validate workflow policy". That check proves each workflow
# is well-formed; this one proves the SHAPE of the control plane did not change unreviewed. The
# reviewed shape is the frozen CONTROL_PLANE_MANIFEST constant below (ordinary reviewed Ruby: no
# data file, no read-back):
#
#   - every workflow file, with its trust tier, its triggers and its job ids;
#   - every local composite action;
#   - the required status check (workflow, job id, job name).
#
# The tree must match the manifest exactly, in both directions, so each of these fails until the
# manifest is edited in the same pull request (where review sees it):
#
#   - a workflow or composite deleted, renamed or added;
#   - a job added, removed or renamed (a renamed or removed "Validate workflow policy" job would
#     silently drop the required check, so that job's name is pinned separately);
#   - a trigger added or removed (widening to pull_request_target or workflow_run is refused
#     outright, whatever the manifest says);
#   - a trust tier that disagrees with workflow-lists.sh.
#
# Changing the shape in two steps. A pull request carries its own policy and is also judged by
# its base's copy (docs/how-ci-works.md, "Changing the policy"), so an exact manifest alone would
# deadlock every structural change: tree plus manifest fails the base's copy, manifest alone fails
# the PR's own. A manifest entry may therefore be an ARRAY of exact alternatives; the first is the
# final shape and the rest are transitional:
#
#   step A: a pull request adds the new shape as the first alternative and keeps the old one as
#           the second (the tree is unchanged, so it matches the old shape);
#   step B: a pull request changes the tree and deletes the old alternative (the base's copy,
#           from step A, accepts the new tree through its alternative).
#
# An alternative is an exact shape (tier, triggers, jobs) or 'absent' for a workflow, and
# 'present' or 'absent' for a composite. No wildcards, patterns or supersets: anything but the
# exact keys and plain names is refused when the manifest is validated, the forbidden-trigger
# denial and the required-check pin apply to every alternative, and the tree must match one of
# them. When it matches only the final one while others remain, the run prints a warning
# annotation: the base pass (main's copy, step A's manifest) judges step B's tree in exactly that
# state, so there it can only warn or the transition it exists to allow would deadlock. The policy
# job runs the pull request's OWN copy with --strict, where the same state is an error: step B must
# have removed its transitional alternatives, so a transition cannot linger.
#
# YAML 1.1 reads a bare `on` key as true, so the `on` and `true` keys are unioned, a file with
# both is refused, and so is any duplicate mapping key (a Psych AST walk), which the loader
# would otherwise resolve silently to the last value.
#
# Not covered: `if: ${{ false }}` or `continue-on-error` on the required job drops the check just
# like a rename does, and a pull request that edits the constant and the tree together passes
# this check. The controls for those are review, or an Enterprise-only ruleset-required workflow.
#
# `ruby check-structure.rb --strict` is the policy job's own-copy run (see above).
# `ruby check-structure.rb --print` prints the current structure as a Ruby literal to paste over
# the constant after a reviewed change. Run from the repository root; an optional first argument
# names another root (fixtures).
require 'json'
require 'yaml'
require_relative 'yaml-guard'

print_mode = ARGV.delete('--print')
json_actual = ARGV.delete('--json-actual')
json_manifest = ARGV.delete('--json-manifest')
strict = ARGV.delete('--strict')
root = ARGV.first || '.'
FORBIDDEN_TRIGGERS = %w[pull_request_target workflow_run].freeze
TIERS = %w[policy policy-reusable protected-source protected-reusable protected-dispatch public].freeze
REQUIRED_WORKFLOW = '.github/workflows/validate-public-changes.yml'
problems = []
warnings = []

# The reviewed shape of the control plane. Change it only in a reviewed pull request.
CONTROL_PLANE_MANIFEST = {"required_check" =>
  {"workflow" => ".github/workflows/validate-public-changes.yml",
   "job" => "policy",
   "name" => "Validate workflow policy"},
 "workflows" =>
  {".github/workflows/android-validation.yml" =>
    {"tier" => "protected-source",
     "triggers" => ["workflow_dispatch"],
     "jobs" => ["plan", "result", "timings", "validate"]},
   ".github/workflows/base-policy.yml" =>
    {"tier" => "policy-reusable",
     "triggers" => ["workflow_call"],
     "jobs" => ["base-policy", "base-policy-fixtures", "base-policy-result"]},
   ".github/workflows/cache-prune.yml" =>
    {"tier" => "public", "triggers" => ["schedule", "workflow_dispatch"], "jobs" => ["prune"]},
   ".github/workflows/ios-validation.yml" =>
    {"tier" => "protected-source",
     "triggers" => ["workflow_dispatch"],
     "jobs" => ["plan", "result", "timings", "validate"]},
   ".github/workflows/linux-validation-concern.yml" =>
    {"tier" => "protected-reusable", "triggers" => ["workflow_call"], "jobs" => ["validate"]},
   ".github/workflows/linux-validation.yml" =>
    {"tier" => "protected-dispatch",
     "triggers" => ["workflow_dispatch"],
     "jobs" =>
      ["cache-audit",
       "cache-audit-after",
       "result",
       "select",
       "timings",
       "validate-input",
       "validate-long-main",
       "validate-long-untrusted",
       "validate-main",
       "validate-untrusted"]},
   ".github/workflows/live-proof-arm.yml" =>
    {"tier" => "protected-reusable", "triggers" => ["workflow_call"], "jobs" => ["prove"]},
   ".github/workflows/live-proofs.yml" =>
    {"tier" => "protected-dispatch",
     "triggers" => ["workflow_dispatch"],
     "jobs" => ["plan", "prove", "timings"]},
   ".github/workflows/macos-validation-concern.yml" =>
    {"tier" => "protected-reusable", "triggers" => ["workflow_call"], "jobs" => ["validate"]},
   ".github/workflows/macos-validation.yml" =>
    {"tier" => "protected-source",
     "triggers" => ["workflow_dispatch"],
     "jobs" =>
      ["cache-audit",
       "cache-audit-after",
       "plan",
       "result",
       "timings",
       "validate-long-main",
       "validate-long-untrusted",
       "validate-main",
       "validate-untrusted"]},
   ".github/workflows/orchestrate-validation.yml" =>
    {"tier" => "protected-source",
     "triggers" => ["workflow_dispatch"],
     "jobs" => ["result", "timings", "validate", "validate-input"]},
   ".github/workflows/pg8-measurement-arm.yml" =>
    {"tier" => "protected-reusable",
     "triggers" => ["workflow_call"],
     "jobs" => ["measure", "preflight"]},
   ".github/workflows/pg8-measurement.yml" =>
    {"tier" => "protected-dispatch",
     "triggers" => ["workflow_dispatch"],
     "jobs" => ["measure", "plan"]},
   ".github/workflows/scorecard.yml" =>
    {"tier" => "public",
     "triggers" => ["schedule", "workflow_dispatch"],
     "jobs" => ["scorecard"]},
   ".github/workflows/select-concerns.yml" =>
    {"tier" => "protected-reusable", "triggers" => ["workflow_call"], "jobs" => ["select"]},
   ".github/workflows/source-read.yml" =>
    {"tier" => "protected-source",
     "triggers" => ["workflow_dispatch"],
     "jobs" => ["source-read", "validate-input"]},
   ".github/workflows/validate-public-changes.yml" =>
    [{"tier" => "policy",
      "triggers" => ["pull_request", "push", "workflow_dispatch"],
      "jobs" => ["base-pass", "classify", "policy", "policy-docs", "policy-evidence", "policy-fixtures", "policy-mutations", "policy-structure"]},
     {"tier" => "policy",
      "triggers" => ["pull_request", "push", "workflow_dispatch"],
      "jobs" => ["base-pass", "policy", "policy-evidence", "policy-fixtures", "policy-mutations", "policy-structure"]}],
   ".github/workflows/weekly-validation.yml" =>
    {"tier" => "public",
     "triggers" => ["schedule", "workflow_dispatch"],
     "jobs" => ["dispatch", "resolve", "tool-freshness"]},
   ".github/workflows/windows-validation-concern.yml" =>
    {"tier" => "protected-reusable", "triggers" => ["workflow_call"], "jobs" => ["validate"]},
   ".github/workflows/windows-validation.yml" =>
    {"tier" => "protected-dispatch",
     "triggers" => ["workflow_dispatch"],
     "jobs" =>
      ["cache-audit",
       "cache-audit-after",
       "result",
       "timings",
       "validate-input",
       "validate-main",
       "validate-rust-long-main",
       "validate-rust-long-untrusted",
       "validate-rust-main",
       "validate-rust-untrusted",
       "validate-untrusted"]}},
 "actions" =>
  {".github/actions/android-emulator-tests/action.yml" => "present",
   ".github/actions/android-sdk-setup/action.yml" => "present",
   ".github/actions/cache-scope-audit/action.yml" => "present",
   ".github/actions/concern-report/action.yml" => "present",
   ".github/actions/drop-root/action.yml" => "present",
   ".github/actions/egress-audit/action.yml" => "present",
   ".github/actions/egress-block/action.yml" => "present",
   ".github/actions/environment-preflight/action.yml" => "present",
   ".github/actions/ios-project-init/action.yml" => "present",
   ".github/actions/ios-simulator-tests/action.yml" => "present",
   ".github/actions/linux-concern-e2e/action.yml" => "present",
   ".github/actions/linux-concern-js/action.yml" => "present",
   ".github/actions/linux-concern-rust/action.yml" => "present",
   ".github/actions/linux-test-identities/action.yml" => "present",
   ".github/actions/live-build/action.yml" => "present",
   ".github/actions/live-run/action.yml" => "present",
   ".github/actions/live-start-ibm/action.yml" => "present",
   ".github/actions/live-start-iris/action.yml" => "present",
   ".github/actions/live-start-mpp/action.yml" => "present",
   ".github/actions/live-start-pg/action.yml" => "present",
   ".github/actions/live-start-rocketmq/action.yml" => "present",
   ".github/actions/live-start-sql/action.yml" => "present",
   ".github/actions/live-summary/action.yml" => "present",
   ".github/actions/macos-concern-js/action.yml" => "present",
   ".github/actions/macos-concern-rust/action.yml" => "present",
   ".github/actions/mobile-report/action.yml" => "present",
   ".github/actions/node-setup/action.yml" => "present",
   ".github/actions/pg8-measurement/action.yml" => "present",
   ".github/actions/root-setup/action.yml" => "present",
   ".github/actions/run-result/action.yml" => "present",
   ".github/actions/rust-lint-enforce/action.yml" => "present",
   ".github/actions/rust-target-cache/action.yml" => "present",
   ".github/actions/rust-toolchain/action.yml" => "present",
   ".github/actions/sanitize/action.yml" => "present",
   ".github/actions/scan-concern/action.yml" => "present",
   ".github/actions/select-concerns/action.yml" => "present",
   ".github/actions/shell-artefact/action.yml" => "present",
   ".github/actions/shell-config/action.yml" => "present",
   ".github/actions/source-checkout/action.yml" => "present",
   ".github/actions/timings/action.yml" => "present",
   ".github/actions/vendor-fetch/action.yml" => "present",
   ".github/actions/verify-cargo-cache/action.yml" => "present",
   ".github/actions/windows-concern-rust/action.yml" => "present"}}.freeze

def read_yaml(path)
  YAML.safe_load(File.read(path, encoding: 'UTF-8'), aliases: false) || {}
end

# The tier arrays in workflow-lists.sh, read as text (the file is bash).
def tier_lists(root)
  text = File.read(File.join(root, '.github/policy/workflow-lists.sh'), encoding: 'UTF-8')
  arrays = {}
  text.scan(/^(\w+)=\(\n(.*?)^\)/m) do |name, body|
    arrays[name] = body.lines.reject { |l| l.strip.start_with?('#') }.flat_map { |l| l.scan(/"([^"]+)"/).flatten }
  end
  [arrays, text[/^public_policy_workflow="([^"]+)"/, 1], text[/^public_policy_reusable_workflow="([^"]+)"/, 1]]
end

# The `on` and `true` keys unioned: a trigger behind the other spelling still counts.
def triggers_of(doc)
  [doc['on'], doc[true]].flat_map do |on|
    case on
    when Hash then on.keys.map(&:to_s)
    when Array then on.map(&:to_s)
    when nil then []
    else [on.to_s]
    end
  end.uniq.sort
end

def tier_of(rel, lists, policy, policy_reusable)
  if rel == policy then 'policy'
  elsif rel == policy_reusable then 'policy-reusable'
  elsif lists['reusable_protected_workflows'].to_a.include?(rel) then 'protected-reusable'
  elsif lists['protected_source_workflows'].to_a.include?(rel) then 'protected-source'
  elsif lists['protected_dispatch_workflows'].to_a.include?(rel) then 'protected-dispatch'
  else 'public'
  end
end

def actual_structure(root, problems)
  lists, policy, policy_reusable = tier_lists(root)
  workflows = {}
  Dir.glob(File.join(root, '.github/workflows/*.{yml,yaml}')).sort.each do |file|
    rel = file.delete_prefix("#{root}/")
    YamlGuard.yaml_duplicates(file).each { |d| problems << "#{rel}: #{d}" }
    doc = read_yaml(file)
    problems << "#{rel}: both the `on` key and a bare on (true) key are present" if doc.key?('on') && doc.key?(true)
    workflows[rel] = { 'tier' => tier_of(rel, lists, policy, policy_reusable), 'triggers' => triggers_of(doc), 'jobs' => (doc['jobs'] || {}).keys.sort }
  end
  actions = {}
  Dir.glob(File.join(root, '.github/actions/*/action.{yml,yaml}')).sort.each do |f|
    rel = f.delete_prefix("#{root}/")
    YamlGuard.yaml_duplicates(f).each { |d| problems << "#{rel}: #{d}" }
    actions[rel] = 'present'
  end
  { 'workflows' => workflows, 'actions' => actions }
end

# An entry is one alternative or an array of them; always an array.
def alternatives(entry)
  entry.is_a?(Array) ? entry : [entry]
end

def validate_shape(rel, alt, problems)
  plain = /\A[A-Za-z0-9_.-]+\z/
  unless alt.is_a?(Hash) && alt.keys.sort == %w[jobs tier triggers]
    problems << "#{rel}: an alternative must be 'absent' or exactly tier, triggers and jobs: #{alt.inspect}"
    return
  end
  problems << "#{rel}: unknown tier #{alt['tier'].inspect}" unless TIERS.include?(alt['tier'])
  %w[triggers jobs].each do |field|
    names = alt[field]
    ok = names.is_a?(Array) && names.all? { |n| n.is_a?(String) && n.match?(plain) } && names == names.sort && names.uniq == names
    problems << "#{rel}: #{field} must be a sorted list of exact plain names (no wildcard or pattern): #{names.inspect}" unless ok
  end
  (Array(alt['triggers']) & FORBIDDEN_TRIGGERS).each { |t| problems << "#{rel}: an alternative lists the forbidden trigger #{t}" }
end

# The manifest must itself be exact and plain: known keys, plain names, no wildcard, no forbidden
# trigger in any alternative, the required check present in every alternative.
def validate_manifest(manifest, problems)
  extra = manifest.keys - %w[required_check workflows actions]
  problems << "the manifest has unknown keys: #{extra.inspect}" unless extra.empty?
  (manifest['workflows'] || {}).each do |rel, entry|
    problems << "#{rel}: a manifest workflow path must be an exact .github/workflows/<name>.yml" unless rel.match?(%r{\A\.github/workflows/[A-Za-z0-9_.-]+\.ya?ml\z})
    alts = alternatives(entry)
    problems << "#{rel}: the manifest entry has no alternatives" if alts.empty?
    problems << "#{rel}: the manifest entry repeats an alternative" unless alts.uniq.size == alts.size
    alts.each { |alt| validate_shape(rel, alt, problems) unless alt == 'absent' }
  end
  (manifest['actions'] || {}).each do |rel, entry|
    problems << "#{rel}: a manifest action path must be an exact .github/actions/<name>/action.yml" unless rel.match?(%r{\A\.github/actions/[A-Za-z0-9_-]+/action\.ya?ml\z})
    alternatives(entry).each { |s| problems << "#{rel}: an action state must be 'present' or 'absent'" unless %w[present absent].include?(s) }
  end
  validate_required_check(manifest, problems)
end

def validate_required_check(manifest, problems)
  req = manifest['required_check'] || {}
  if req.values_at('workflow', 'job', 'name').any?(&:nil?)
    problems << 'the manifest must pin the required check (workflow, job, name)'
    return
  end
  problems << "the required check must come from #{REQUIRED_WORKFLOW}, not #{req['workflow']}" unless req['workflow'] == REQUIRED_WORKFLOW
  entry = (manifest['workflows'] || {})[req['workflow']]
  if entry.nil?
    problems << "#{req['workflow']} has no manifest entry: the required status check would be dropped"
    return
  end
  alternatives(entry).each do |alt|
    if alt == 'absent'
      problems << "#{req['workflow']}: an alternative lets the required check workflow be absent: the required status check would be dropped"
    elsif alt.is_a?(Hash) && !Array(alt['jobs']).include?(req['job'])
      problems << "#{req['workflow']}: an alternative lacks the required check job #{req['job']}: the required status check would be dropped"
    end
  end
end

# Match one path's state against its alternatives, exactly.
def match_entry(rel, entry, state, problems, warnings, kind)
  alts = alternatives(entry)
  hit = alts.index(state)
  if hit.nil?
    if entry.nil?
      problems << "#{rel}: a #{kind} with no manifest entry (new or renamed); add it to CONTROL_PLANE_MANIFEST in a reviewed change"
    elsif state == 'absent'
      problems << "#{rel}: in the manifest but missing from the tree (deleted or renamed)"
    elsif alts.size == 1 && state.is_a?(Hash) && alts.first.is_a?(Hash)
      %w[tier triggers jobs].each do |field|
        problems << "#{rel}: #{field} changed (reviewed #{alts.first[field].inspect}, now #{state[field].inspect})" unless alts.first[field] == state[field]
      end
    else
      problems << "#{rel}: matches none of the #{alts.size} reviewed shapes (now #{state.inspect})"
    end
  elsif hit.zero? && alts.size > 1
    warnings << "::warning title=control-plane structure::#{rel} matches only the final shape while #{alts.size - 1} transitional alternative(s) remain; remove them in the pull request that changes the tree"
  end
end

manifest = CONTROL_PLANE_MANIFEST
actual = actual_structure(root, problems)

# Both as JSON, so a fixture can compare them without depending on how this Ruby formats a hash.
if json_actual
  puts JSON.generate({ 'required_check' => manifest['required_check'] }.merge(actual))
  exit 0
end
if json_manifest
  puts JSON.generate(manifest)
  exit 0
end
if print_mode
  require 'pp'
  puts "CONTROL_PLANE_MANIFEST = #{PP.pp({ 'required_check' => manifest['required_check'] }.merge(actual), +'', 98).rstrip}.freeze"
  exit 0
end

validate_manifest(manifest, problems)

# Hard denial, independent of the manifest.
actual['workflows'].each do |rel, spec|
  (spec['triggers'] & FORBIDDEN_TRIGGERS).each { |t| problems << "#{rel}: the trigger #{t} is never allowed" }
end

# The required status check must still exist under its pinned name.
req = manifest['required_check'] || {}
unless req.values_at('workflow', 'job', 'name').any?(&:nil?)
  doc = File.file?(File.join(root, req['workflow'].to_s)) ? read_yaml(File.join(root, req['workflow'])) : nil
  job = doc && (doc['jobs'] || {})[req['job']]
  if job.nil?
    problems << "the required check job #{req['job']} is missing from #{req['workflow']}: the required status check would be dropped"
  elsif job['name'] != req['name']
    problems << "the required check job #{req['job']} is named #{job['name'].inspect}, not #{req['name'].inspect}: the required status check would be dropped"
  end
end

reviewed = manifest['workflows'] || {}
(actual['workflows'].keys | reviewed.keys).sort.each do |rel|
  match_entry(rel, reviewed[rel], actual['workflows'][rel] || 'absent', problems, warnings, 'workflow')
end
reviewed_actions = manifest['actions'] || {}
(actual['actions'].keys | reviewed_actions.keys).sort.each do |rel|
  match_entry(rel, reviewed_actions[rel], actual['actions'][rel] || 'absent', problems, warnings, 'composite action')
end

if strict
  warnings.each { |w| problems << w.sub(/\A::warning title=[^:]*::/, '') }
  warnings.clear
end
warnings.each { |w| puts w }
if problems.empty?
  puts "control-plane structure: #{actual['workflows'].size} workflows and #{actual['actions'].size} composites match the reviewed manifest"
else
  problems.uniq.each { |p| warn p }
  exit 1
end
