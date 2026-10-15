#!/usr/bin/env ruby
# frozen_string_literal: true

# Control-plane structure check.
#
# GitHub's `workflows` ruleset rule is Enterprise-only, so the ruleset "Protect CI control plane"
# can only require the status check "Validate workflow policy". That check proves each workflow
# is well-formed; this one proves the SHAPE of the control plane did not change unreviewed. The
# reviewed shape is the committed manifest .github/policy/control-plane-manifest.rb:
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
# The manifest is the frozen CONTROL_PLANE_MANIFEST constant below, ordinary reviewed Ruby in
# this script (no data file, no read-back). `ruby check-structure.rb --print` prints the current
# structure as a Ruby literal to paste over it after a reviewed change. Run from the repository
# root; an optional first argument names another root (fixtures).
require 'json'
require 'yaml'

print_mode = ARGV.delete('--print')
root = ARGV.first || '.'
FORBIDDEN_TRIGGERS = %w[pull_request_target workflow_run].freeze

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
     "jobs" => ["plan", "result", "select", "timings", "validate", "validate-input"]},
   ".github/workflows/live-proof-arm.yml" =>
    {"tier" => "protected-reusable", "triggers" => ["workflow_call"], "jobs" => ["prove"]},
   ".github/workflows/live-proofs.yml" =>
    {"tier" => "protected-dispatch",
     "triggers" => ["workflow_dispatch"],
     "jobs" => ["plan", "prove", "timings"]},
   ".github/workflows/macos-validation.yml" =>
    {"tier" => "protected-source",
     "triggers" => ["workflow_dispatch"],
     "jobs" => ["plan", "result", "timings", "validate"]},
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
    {"tier" => "policy",
     "triggers" => ["pull_request", "push", "workflow_dispatch"],
     "jobs" => ["base-policy", "base-policy-fixtures", "policy"]},
   ".github/workflows/weekly-validation.yml" =>
    {"tier" => "public",
     "triggers" => ["schedule", "workflow_dispatch"],
     "jobs" => ["dispatch", "resolve", "tool-freshness"]},
   ".github/workflows/windows-validation-concern.yml" =>
    {"tier" => "protected-reusable", "triggers" => ["workflow_call"], "jobs" => ["validate"]},
   ".github/workflows/windows-validation.yml" =>
    {"tier" => "protected-dispatch",
     "triggers" => ["workflow_dispatch"],
     "jobs" => ["plan", "result", "timings", "validate", "validate-input", "validate-rust"]}},
 "actions" =>
  [".github/actions/android-emulator-tests/action.yml",
   ".github/actions/android-sdk-setup/action.yml",
   ".github/actions/concern-report/action.yml",
   ".github/actions/drop-root/action.yml",
   ".github/actions/egress-audit/action.yml",
   ".github/actions/egress-block/action.yml",
   ".github/actions/environment-preflight/action.yml",
   ".github/actions/ios-project-init/action.yml",
   ".github/actions/ios-simulator-tests/action.yml",
   ".github/actions/linux-concern-e2e/action.yml",
   ".github/actions/linux-concern-js/action.yml",
   ".github/actions/linux-concern-rust/action.yml",
   ".github/actions/linux-test-identities/action.yml",
   ".github/actions/live-build/action.yml",
   ".github/actions/live-run/action.yml",
   ".github/actions/live-start-ibm/action.yml",
   ".github/actions/live-start-iris/action.yml",
   ".github/actions/live-start-mpp/action.yml",
   ".github/actions/live-start-pg/action.yml",
   ".github/actions/live-start-rocketmq/action.yml",
   ".github/actions/live-start-sql/action.yml",
   ".github/actions/live-summary/action.yml",
   ".github/actions/macos-concern-js/action.yml",
   ".github/actions/macos-concern-rust/action.yml",
   ".github/actions/mobile-report/action.yml",
   ".github/actions/node-setup/action.yml",
   ".github/actions/pg8-measurement/action.yml",
   ".github/actions/root-setup/action.yml",
   ".github/actions/run-result/action.yml",
   ".github/actions/rust-lint-enforce/action.yml",
   ".github/actions/rust-target-cache/action.yml",
   ".github/actions/rust-toolchain/action.yml",
   ".github/actions/sanitize/action.yml",
   ".github/actions/scan-concern/action.yml",
   ".github/actions/select-concerns/action.yml",
   ".github/actions/source-checkout/action.yml",
   ".github/actions/timings/action.yml",
   ".github/actions/vendor-fetch/action.yml",
   ".github/actions/verify-cargo-cache/action.yml",
   ".github/actions/windows-concern-rust/action.yml"]}.freeze

problems = []

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
  policy = text[/^public_policy_workflow="([^"]+)"/, 1]
  [arrays, policy]
end

def triggers_of(doc)
  on = doc.key?('on') ? doc['on'] : doc[true]
  case on
  when Hash then on.keys.map(&:to_s)
  when Array then on.map(&:to_s)
  when nil then []
  else [on.to_s]
  end.sort
end

def actual_structure(root)
  lists, policy = tier_lists(root)
  workflows = {}
  Dir.glob(File.join(root, '.github/workflows/*.{yml,yaml}')).sort.each do |file|
    rel = file.delete_prefix("#{root}/")
    doc = read_yaml(file)
    tier =
      if rel == policy then 'policy'
      elsif lists['reusable_protected_workflows'].to_a.include?(rel) then 'protected-reusable'
      elsif lists['protected_source_workflows'].to_a.include?(rel) then 'protected-source'
      elsif lists['protected_dispatch_workflows'].to_a.include?(rel) then 'protected-dispatch'
      else 'public'
      end
    workflows[rel] = { 'tier' => tier, 'triggers' => triggers_of(doc), 'jobs' => (doc['jobs'] || {}).keys.sort }
  end
  actions = Dir.glob(File.join(root, '.github/actions/*/action.{yml,yaml}')).sort.map { |f| f.delete_prefix("#{root}/") }
  { 'workflows' => workflows, 'actions' => actions }
end

actual = actual_structure(root)

if print_mode
  require 'pp'
  puts 'CONTROL_PLANE_MANIFEST = ' + PP.pp({ 'required_check' => CONTROL_PLANE_MANIFEST['required_check'] }.merge(actual), +'', 98).rstrip + '.freeze'
  exit 0
end

manifest = CONTROL_PLANE_MANIFEST

# Hard denials, independent of the manifest.
actual['workflows'].each do |rel, spec|
  (spec['triggers'] & FORBIDDEN_TRIGGERS).each { |t| problems << "#{rel}: the trigger #{t} is never allowed" }
end

# The required status check must still exist under its pinned name.
req = manifest['required_check'] || {}
if req.values_at('workflow', 'job', 'name').any?(&:nil?)
  problems << 'the manifest must pin the required check (workflow, job, name)'
else
  doc = File.file?(File.join(root, req['workflow'])) ? read_yaml(File.join(root, req['workflow'])) : nil
  job = doc && (doc['jobs'] || {})[req['job']]
  if job.nil?
    problems << "the required check job #{req['job']} is missing from #{req['workflow']}: the required status check would be dropped"
  elsif job['name'] != req['name']
    problems << "the required check job #{req['job']} is named #{job['name'].inspect}, not #{req['name'].inspect}: the required status check would be dropped"
  end
  problems << "the required check must come from the policy tier workflow, not #{req['workflow']}" unless req['workflow'] == '.github/workflows/validate-public-changes.yml'
end

# Workflows: the tree and the manifest must agree exactly.
reviewed = manifest['workflows'] || {}
(actual['workflows'].keys - reviewed.keys).each { |rel| problems << "#{rel}: a workflow with no manifest entry (new or renamed); add it to control-plane-manifest.rb in a reviewed change" }
(reviewed.keys - actual['workflows'].keys).each { |rel| problems << "#{rel}: in the manifest but missing from the tree (deleted or renamed)" }
(actual['workflows'].keys & reviewed.keys).each do |rel|
  a = actual['workflows'][rel]
  m = reviewed[rel]
  %w[tier triggers jobs].each do |field|
    problems << "#{rel}: #{field} changed (reviewed #{m[field].inspect}, now #{a[field].inspect})" unless m[field] == a[field]
  end
end

# Composite actions.
reviewed_actions = manifest['actions'] || []
(actual['actions'] - reviewed_actions).each { |a| problems << "#{a}: a composite action with no manifest entry" }
(reviewed_actions - actual['actions']).each { |a| problems << "#{a}: in the manifest but missing from the tree" }

if problems.empty?
  puts "control-plane structure: #{actual['workflows'].size} workflows and #{actual['actions'].size} composites match the reviewed manifest"
else
  problems.each { |p| warn p }
  exit 1
end
