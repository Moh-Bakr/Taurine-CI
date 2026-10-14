#!/usr/bin/env ruby
# Pin the live-proof fan-out from the plan job's roster to one arm run per selected arm.
#
# test-live-roster.sh proves what the plan step selects; this check proves that selection is what
# runs. Without it, an `exclude` or `include` on the prove matrix, a literal `arms` output, a
# hard-coded REQUESTED_ENGINE, or a skipped build or run step in the arm workflow would drop an arm
# while every roster check stays green. The fan-out is pinned exactly: changing it is a reviewed
# policy change that lands in two steps (docs/how-ci-works.md, "Changing the policy").
#
#   ruby .github/policy/check-live-proof-fanout.rb [repository-root]
require 'yaml'

ROOT = ARGV[0] || '.'
DISPATCHER = '.github/workflows/live-proofs.yml'.freeze
ARM_WORKFLOW = '.github/workflows/live-proof-arm.yml'.freeze
PROTECTED_REF = "github.repository == 'Moh-Bakr/Taurine-CI' && " \
                "(github.ref == 'refs/heads/main' || github.ref == 'refs/heads/untrusted')".freeze
SELECT_STEP_NAME = 'Validate the dispatch input and select the arms'.freeze
PLAN_OUTPUTS = {
  'arms' => '${{ steps.select.outputs.arms }}',
  'roster' => '${{ steps.select.outputs.roster }}'
}.freeze
SELECT_ENV = {
  'REQUESTED_ENGINE' => '${{ inputs.engine }}',
  'REQUESTED_SOURCE_SHA' => '${{ inputs.source_sha }}'
}.freeze
# The whole prove job: one arm-workflow call per selected arm, nothing filtered, nothing tolerated.
PROVE_JOB = {
  'permissions' => { 'contents' => 'read' },
  'if' => PROTECTED_REF,
  'needs' => ['plan'],
  'strategy' => {
    'fail-fast' => false,
    'matrix' => { 'arm' => '${{ fromJSON(needs.plan.outputs.arms) }}' }
  },
  'uses' => './.github/workflows/live-proof-arm.yml',
  'secrets' => { 'SOURCE_READER_PRIVATE_KEY' => '${{ secrets.SOURCE_READER_PRIVATE_KEY }}' },
  'with' => {
    'source_sha' => '${{ inputs.source_sha }}',
    'engine' => '${{ matrix.arm }}',
    'config' => '${{ toJSON(fromJSON(needs.plan.outputs.roster)[matrix.arm]) }}'
  }
}.freeze
# Arm-workflow steps that every arm must execute: none may be conditional or tolerated.
UNCONDITIONAL_ARM_STEPS = [
  'Validate protected call input',
  "Build the engine's proof test binary",
  "Run the engine's live proof"
].freeze

def load_yaml(path)
  YAML.safe_load(File.read(File.join(ROOT, path)), aliases: false)
rescue StandardError
  nil
end

failures = []
dispatcher = load_yaml(DISPATCHER)
arm_workflow = load_yaml(ARM_WORKFLOW)
failures << "#{DISPATCHER}: workflow YAML is missing or invalid" unless dispatcher.is_a?(Hash)
failures << "#{ARM_WORKFLOW}: workflow YAML is missing or invalid" unless arm_workflow.is_a?(Hash)

if dispatcher.is_a?(Hash)
  jobs = dispatcher['jobs'].is_a?(Hash) ? dispatcher['jobs'] : {}
  plan = jobs['plan'].is_a?(Hash) ? jobs['plan'] : {}
  if plan['outputs'] != PLAN_OUTPUTS
    failures << "#{DISPATCHER}: jobs.plan.outputs must be exactly arms and roster from steps.select, " \
                'so the prove matrix runs the arms the plan step selected'
  end
  failures << "#{DISPATCHER}: jobs.plan may not set continue-on-error" if plan.key?('continue-on-error')
  steps = plan['steps'].is_a?(Array) ? plan['steps'] : []
  selects = steps.select { |step| step.is_a?(Hash) && step['id'] == 'select' }
  if selects.length != 1
    failures << "#{DISPATCHER}: jobs.plan must have exactly one step with id select"
  else
    select = selects.first
    unless select['name'] == SELECT_STEP_NAME
      failures << "#{DISPATCHER}: the select step must be named #{SELECT_STEP_NAME.inspect}, " \
                  'the step test-live-roster.sh executes'
    end
    if select.key?('if') || select.key?('continue-on-error')
      failures << "#{DISPATCHER}: the select step may not set if or continue-on-error"
    end
    failures << "#{DISPATCHER}: the select step must run with shell: bash" unless select['shell'] == 'bash'
    unless select['env'] == SELECT_ENV
      failures << "#{DISPATCHER}: the select step env must be exactly REQUESTED_ENGINE and " \
                  'REQUESTED_SOURCE_SHA from the dispatch inputs'
    end
  end
  if jobs['prove'] != PROVE_JOB
    actual = jobs['prove'].is_a?(Hash) ? jobs['prove'] : {}
    differing = (PROVE_JOB.keys | actual.keys).reject { |key| PROVE_JOB[key] == actual[key] }
    failures << "#{DISPATCHER}: jobs.prove differs from the reviewed fan-out in #{differing.sort.join(', ')}; " \
                'the matrix must be exactly the plan arms, with no include, exclude or filter'
  end
end

if arm_workflow.is_a?(Hash)
  arm_jobs = arm_workflow['jobs'].is_a?(Hash) ? arm_workflow['jobs'] : {}
  failures << "#{ARM_WORKFLOW}: must have exactly one job, prove" unless arm_jobs.keys == ['prove']
  arm_prove = arm_jobs['prove'].is_a?(Hash) ? arm_jobs['prove'] : {}
  failures << "#{ARM_WORKFLOW}: jobs.prove must run only under the protected-ref condition" unless arm_prove['if'] == PROTECTED_REF
  %w[continue-on-error strategy].each do |key|
    failures << "#{ARM_WORKFLOW}: jobs.prove may not set #{key}" if arm_prove.key?(key)
  end
  arm_steps = arm_prove['steps'].is_a?(Array) ? arm_prove['steps'] : []
  UNCONDITIONAL_ARM_STEPS.each do |name|
    matches = arm_steps.select { |step| step.is_a?(Hash) && step['name'] == name }
    if matches.length != 1
      failures << "#{ARM_WORKFLOW}: expected exactly one step named #{name.inspect}"
    elsif matches.first.key?('if') || matches.first.key?('continue-on-error')
      failures << "#{ARM_WORKFLOW}: step #{name.inspect} must run for every arm, without if or continue-on-error"
    end
  end
end

if failures.empty?
  puts 'live-proof fan-out: every selected arm runs the arm workflow, unfiltered'
else
  failures.each { |failure| warn failure }
  exit 1
end
