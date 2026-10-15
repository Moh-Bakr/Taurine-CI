#!/usr/bin/env ruby
# frozen_string_literal: true

# Control-plane structure check.
#
# GitHub's `workflows` ruleset rule is Enterprise-only, so the ruleset "Protect CI control plane"
# can only require the status check "Validate workflow policy". That check proves each workflow
# is well-formed; this one proves the SHAPE of the control plane did not change unreviewed. The
# reviewed shape is the committed manifest .github/policy/control-plane.json:
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
# The manifest lives under .github/policy/ so the existing "only reviewed paths are tracked"
# rule admits it. `ruby check-structure.rb --print` prints the current structure as manifest
# JSON, to regenerate the file after a reviewed change. Run from the repository root; an
# optional first argument names another root (fixtures).
require 'json'
require 'yaml'

print_mode = ARGV.delete('--print')
root = ARGV.first || '.'
manifest_path = File.join(root, '.github/policy/control-plane.json')
FORBIDDEN_TRIGGERS = %w[pull_request_target workflow_run].freeze
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
  required = { 'workflow' => '.github/workflows/validate-public-changes.yml', 'job' => 'policy', 'name' => 'Validate workflow policy' }
  puts JSON.pretty_generate({ 'required_check' => required }.merge(actual))
  exit 0
end

unless File.file?(manifest_path)
  warn "the control-plane manifest is missing: #{manifest_path}"
  exit 1
end
manifest = JSON.parse(File.read(manifest_path, encoding: 'UTF-8'))

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
(actual['workflows'].keys - reviewed.keys).each { |rel| problems << "#{rel}: a workflow with no manifest entry (new or renamed); add it to control-plane.json in a reviewed change" }
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
