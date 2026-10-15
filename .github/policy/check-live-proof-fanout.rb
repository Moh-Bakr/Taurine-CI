#!/usr/bin/env ruby
# Pin the live-proof fan-out from the plan job's roster to one arm run per selected arm.
#
# test-live-roster.sh proves what the plan step selects; this check proves that selection is what
# runs. Without it, an `exclude` or `include` on the prove matrix, a literal `arms` output, a
# skipped plan job, a hard-coded REQUESTED_ENGINE, or a skipped, replaced or re-targeted build or
# run step in the arm workflow would drop an arm, or make it pass without proving anything, while
# every roster check stays green. The fan-out is pinned exactly: changing it is a reviewed policy
# change that lands in two steps (docs/how-ci-works.md, "Changing the policy").
#
# The workflows are read as text and YAML, never executed. Each failure names the file and the
# cause; a file that is missing, a symlink, too large, not UTF-8, not YAML, ambiguous (duplicate
# keys, anchors, aliases) or not a mapping is refused, not followed.
#
#   ruby .github/policy/check-live-proof-fanout.rb [repository-root]
require 'digest'
require 'yaml'

ROOT = ARGV[0] || '.'
DISPATCHER = '.github/workflows/live-proofs.yml'.freeze
ARM_WORKFLOW = '.github/workflows/live-proof-arm.yml'.freeze
MAX_WORKFLOW_BYTES = 512 * 1024
PROTECTED_REF = "github.repository == 'Moh-Bakr/Taurine-CI' && " \
                "(github.ref == 'refs/heads/main' || github.ref == 'refs/heads/untrusted')".freeze
SELECT_STEP_NAME = 'Validate the dispatch input and select the arms'.freeze
PLAN_OUTPUTS = {
  'arms' => '${{ steps.select.outputs.arms }}',
  'roster' => '${{ steps.select.outputs.roster }}'
}.freeze
# The plan job's own keys, apart from its steps. Its `if` is the protected-ref condition and nothing
# else: prove needs plan, so a plan that is skipped or conditional skips every arm.
PLAN_JOB_KEYS = %w[permissions if name runs-on timeout-minutes outputs steps].freeze
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
# The arm workflow's workflow-level environment and its job, apart from the steps.
ARM_WORKFLOW_ENV = {
  'SOURCE_REPOSITORY_ID' => '1330267721',
  'SOURCE_REPOSITORY_OWNER' => 'Moh-Bakr',
  'SOURCE_REPOSITORY_NAME' => 'Taurine'
}.freeze
ARM_JOB = {
  'permissions' => { 'contents' => 'read' },
  'if' => PROTECTED_REF,
  'name' => 'Live proof — ${{ inputs.engine }}',
  'environment' => 'source-read',
  'runs-on' => 'ubuntu-24.04',
  'timeout-minutes' => '${{ inputs.timeout_minutes }}',
  'defaults' => { 'run' => { 'working-directory' => 'src' } }
}.freeze
# Arm-workflow steps that every arm must execute exactly as reviewed: no condition, no tolerance, no
# swapped action, no environment, shell, directory or input. In this order.
VALIDATION_STEP_NAME = 'Validate protected call input'.freeze
VALIDATION_STEP = {
  'name' => VALIDATION_STEP_NAME,
  'shell' => 'bash',
  'working-directory' => '${{ github.workspace }}',
  'env' => {
    'REQUESTED_ENGINE' => '${{ inputs.engine }}',
    'REQUESTED_SOURCE_SHA' => '${{ inputs.source_sha }}',
    'ARM_CONFIG' => '${{ inputs.config }}'
  }
}.freeze
# SHA-256 of the validation step's `run` script. Recompute after a reviewed change with:
#   ruby .github/policy/extract-step.rb .github/workflows/live-proof-arm.yml \
#     'Validate protected call input' run | shasum -a 256
VALIDATION_RUN_SHA256 = '7094ebffcb51aff4bcc4dbe191d1af4a64f8a3b587a30e6244cac6c35eb1be4c'.freeze
BUILD_STEP = { 'name' => "Build the engine's proof test binary", 'uses' => './.github/actions/live-build' }.freeze
RUN_STEP = { 'name' => "Run the engine's live proof", 'uses' => './.github/actions/live-run' }.freeze
PINNED_ARM_STEPS = [VALIDATION_STEP, BUILD_STEP, RUN_STEP].freeze

class Refused < StandardError; end

# Mapping keys are checked for duplicates, and anchors and aliases refused, before the document is
# loaded: the loader would otherwise keep only the last of two equal keys.
def reject_ambiguous(node)
  raise Refused, 'uses a YAML alias' if node.is_a?(Psych::Nodes::Alias)
  raise Refused, 'uses a YAML anchor' if node.respond_to?(:anchor) && node.anchor

  if node.is_a?(Psych::Nodes::Mapping)
    keys = node.children.each_slice(2).map { |key, _| key.respond_to?(:value) ? key.value : nil }.compact
    raise Refused, 'repeats a YAML mapping key' unless keys.uniq.length == keys.length
  end
  (node.children || []).each { |child| reject_ambiguous(child) }
end

# [document, nil] or [nil, reason]. The cause is named; the file is never followed through a symlink.
def load_workflow(path)
  full = File.join(ROOT, path)
  stat = File.lstat(full)
  return [nil, 'is a symlink'] if stat.symlink?
  return [nil, 'is not a regular file'] unless stat.file?
  return [nil, 'is too large'] if stat.size > MAX_WORKFLOW_BYTES

  text = File.binread(full, MAX_WORKFLOW_BYTES + 1)
  return [nil, 'is too large'] if text.bytesize > MAX_WORKFLOW_BYTES

  text.force_encoding(Encoding::UTF_8)
  return [nil, 'is not valid UTF-8'] unless text.valid_encoding?

  reject_ambiguous(Psych.parse_stream(text))
  document = YAML.safe_load(text, permitted_classes: [], aliases: false)
  document.is_a?(Hash) ? [document, nil] : [nil, 'is not a YAML mapping']
rescue Errno::ENOENT
  [nil, 'is missing']
rescue Refused => e
  [nil, e.message]
rescue Psych::Exception
  [nil, 'is not valid YAML']
rescue SystemCallError, IOError
  [nil, 'is unreadable']
end

def step_named(steps, name)
  steps.select { |step| step.is_a?(Hash) && step['name'] == name }
end

failures = []
dispatcher, dispatcher_problem = load_workflow(DISPATCHER)
arm_workflow, arm_problem = load_workflow(ARM_WORKFLOW)
failures << "#{DISPATCHER}: workflow YAML #{dispatcher_problem}" if dispatcher_problem
failures << "#{ARM_WORKFLOW}: workflow YAML #{arm_problem}" if arm_problem

if dispatcher
  jobs = dispatcher['jobs'].is_a?(Hash) ? dispatcher['jobs'] : {}
  plan = jobs['plan'].is_a?(Hash) ? jobs['plan'] : {}
  failures << "#{DISPATCHER}: jobs.plan.if must be exactly the protected-ref condition, because prove needs plan" unless plan['if'] == PROTECTED_REF
  unless (plan.keys - PLAN_JOB_KEYS).empty?
    failures << "#{DISPATCHER}: jobs.plan may only set #{PLAN_JOB_KEYS.join(', ')}; found #{(plan.keys - PLAN_JOB_KEYS).sort.join(', ')}"
  end
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
  # The one reviewed addition is an explicit `cache-mode: none`: the arm workflow only proves against
  # live engines and never caches, so its caller states the least grant (docs/untrusted-readonly-cache.md,
  # section 4.1). Any other value, or any other extra key, still differs.
  prove = jobs['prove']
  prove = prove.reject { |key, _| key == 'cache-mode' } if prove.is_a?(Hash) && prove['cache-mode'] == 'none'
  if prove != PROVE_JOB
    actual = prove.is_a?(Hash) ? prove : {}
    differing = (PROVE_JOB.keys | actual.keys).reject { |key| PROVE_JOB[key] == actual[key] }
    failures << "#{DISPATCHER}: jobs.prove differs from the reviewed fan-out in #{differing.sort.join(', ')}; " \
                'the matrix must be exactly the plan arms, with no include, exclude or filter'
  end
end

if arm_workflow
  unless arm_workflow['env'] == ARM_WORKFLOW_ENV
    failures << "#{ARM_WORKFLOW}: the workflow env must be exactly the reviewed source repository identity"
  end
  arm_jobs = arm_workflow['jobs'].is_a?(Hash) ? arm_workflow['jobs'] : {}
  failures << "#{ARM_WORKFLOW}: must have exactly one job, prove" unless arm_jobs.keys == ['prove']
  arm_prove = arm_jobs['prove'].is_a?(Hash) ? arm_jobs['prove'] : {}
  job_without_steps = arm_prove.reject { |key, _| key == 'steps' }
  unless job_without_steps == ARM_JOB
    differing = (ARM_JOB.keys | job_without_steps.keys).reject { |key| ARM_JOB[key] == job_without_steps[key] }
    failures << "#{ARM_WORKFLOW}: jobs.prove differs from the reviewed job in #{differing.sort.join(', ')}; " \
                'it must run for every arm under the protected-ref condition, untolerated and unfiltered'
  end
  arm_steps = arm_prove['steps'].is_a?(Array) ? arm_prove['steps'] : []
  positions = PINNED_ARM_STEPS.map do |pinned|
    matches = step_named(arm_steps, pinned['name'])
    if matches.length != 1
      failures << "#{ARM_WORKFLOW}: expected exactly one step named #{pinned['name'].inspect}, found #{matches.length}"
      next nil
    end
    step = matches.first
    unless step.reject { |key, _| key == 'run' } == pinned.reject { |key, _| key == 'run' } &&
           (pinned['name'] == VALIDATION_STEP_NAME ? Digest::SHA256.hexdigest(step['run'].to_s) == VALIDATION_RUN_SHA256 : !step.key?('run'))
      failures << "#{ARM_WORKFLOW}: step #{pinned['name'].inspect} differs from the reviewed definition " \
                  '(action, run script, environment, inputs, shell, directory, if and continue-on-error are all pinned)'
    end
    arm_steps.index(step)
  end
  if positions.all? && positions != positions.sort
    failures << "#{ARM_WORKFLOW}: the validation, build and run steps must run in that order"
  end
end

if failures.empty?
  puts 'live-proof fan-out: every selected arm runs the arm workflow, unfiltered'
else
  failures.each { |failure| warn failure }
  exit 1
end
