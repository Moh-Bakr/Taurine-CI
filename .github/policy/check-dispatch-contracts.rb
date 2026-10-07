#!/usr/bin/env ruby
# Bind workflow_dispatch declarations and trusted identity proofs to the reviewed contract.
require 'json'
require 'yaml'

ROOT = ARGV[0] || '.'
EXPECTED_WORKFLOWS = %w[
  .github/workflows/android-validation.yml
  .github/workflows/ios-validation.yml
  .github/workflows/linux-validation.yml
  .github/workflows/live-proofs.yml
  .github/workflows/macos-validation.yml
  .github/workflows/orchestrate-validation.yml
  .github/workflows/windows-validation.yml
].freeze
PREFLIGHT = {
  '.github/workflows/android-validation.yml' => 'plan',
  '.github/workflows/ios-validation.yml' => 'plan',
  '.github/workflows/linux-validation.yml' => 'validate-input',
  '.github/workflows/live-proofs.yml' => 'plan',
  '.github/workflows/macos-validation.yml' => 'plan',
  '.github/workflows/orchestrate-validation.yml' => 'validate-input',
  '.github/workflows/windows-validation.yml' => 'validate-input'
}.freeze
EXPECTED_RUN_NAME = 'Taurine validation ${{ inputs.source_sha }} ${{ inputs.dispatch_key }}'
SHA40 = { 'type' => 'string', 'required' => true, 'format' => 'sha40', 'digest_include' => true }.freeze
DISPATCH_KEY = { 'type' => 'string', 'required' => true, 'format' => 'sha256', 'digest_include' => false }.freeze
BOOLEAN_FALSE = { 'type' => 'boolean', 'required' => false, 'default' => false, 'digest_include' => true }.freeze
EXPECTED_INPUTS = {
  '.github/workflows/linux-validation.yml' => {
    'source_sha' => SHA40, 'dispatch_key' => DISPATCH_KEY,
    'profile' => { 'type' => 'choice', 'required' => false, 'default' => 'full', 'options' => %w[full quick], 'digest_include' => true },
    'visual' => BOOLEAN_FALSE, 'gitleaks_history' => BOOLEAN_FALSE,
    'base_sha' => { 'type' => 'string', 'required' => false, 'default' => '', 'format' => 'optional-sha40', 'digest_include' => true }
  },
  '.github/workflows/macos-validation.yml' => {
    'source_sha' => SHA40, 'dispatch_key' => DISPATCH_KEY, 'rust' => BOOLEAN_FALSE,
    'flavor' => { 'type' => 'choice', 'required' => false, 'default' => 'prod', 'options' => %w[prod dev uat], 'digest_include' => true }
  },
  '.github/workflows/windows-validation.yml' => {
    'source_sha' => SHA40, 'dispatch_key' => DISPATCH_KEY, 'rust' => BOOLEAN_FALSE,
    'windows_image' => { 'type' => 'choice', 'required' => false, 'default' => 'windows-2022', 'options' => %w[windows-2022 windows-2025], 'digest_include' => true }
  },
  '.github/workflows/android-validation.yml' => { 'source_sha' => SHA40, 'dispatch_key' => DISPATCH_KEY, 'rust' => BOOLEAN_FALSE },
  '.github/workflows/ios-validation.yml' => { 'source_sha' => SHA40, 'dispatch_key' => DISPATCH_KEY, 'rust' => BOOLEAN_FALSE },
  '.github/workflows/orchestrate-validation.yml' => { 'source_sha' => SHA40, 'dispatch_key' => DISPATCH_KEY },
  '.github/workflows/live-proofs.yml' => {
    'engine' => { 'type' => 'string', 'required' => true, 'format' => 'engine-selection',
                  'options' => %w[doris starrocks db2 informix rocketmq iris postgres mysql mssql pgtls bastion], 'digest_include' => true },
    'source_sha' => SHA40, 'dispatch_key' => DISPATCH_KEY
  }
}.freeze
SOURCE_SHA_RUN = <<~'SH'.freeze
  set -euo pipefail
  if [[ ! "${REQUESTED_SOURCE_SHA}" =~ ^[0-9a-fA-F]{40}$ ]]; then
    echo 'source_sha must be a full 40-character hexadecimal commit SHA' >&2
    exit 1
  fi
SH
LINUX_SOURCE_SHA_RUN = <<~'SH'.freeze
  set -euo pipefail
  if [[ ! "${REQUESTED_SOURCE_SHA}" =~ ^[0-9a-fA-F]{40}$ ]]; then
    echo 'source_sha must be a full 40-character hexadecimal commit SHA' >&2
    exit 1
  fi
  if [[ -n "${REQUESTED_BASE_SHA}" && ! "${REQUESTED_BASE_SHA}" =~ ^[0-9a-fA-F]{40}$ ]]; then
    echo 'base_sha must be empty or a full 40-character hexadecimal commit SHA' >&2
    exit 1
  fi
SH
SOURCE_SHA_STEPS = {
  '.github/workflows/linux-validation.yml' => {
    'name' => 'Validate exact source SHA', 'shell' => 'bash',
    'env' => { 'REQUESTED_SOURCE_SHA' => '${{ inputs.source_sha }}', 'REQUESTED_BASE_SHA' => '${{ inputs.base_sha }}' },
    'run' => LINUX_SOURCE_SHA_RUN
  },
  '.github/workflows/windows-validation.yml' => {
    'name' => 'Validate exact source SHA', 'shell' => 'bash',
    'env' => { 'REQUESTED_SOURCE_SHA' => '${{ inputs.source_sha }}' },
    'run' => SOURCE_SHA_RUN
  }
}.freeze
failures = []

def load_yaml(path)
  YAML.safe_load(File.read(path), aliases: false)
rescue StandardError
  nil
end

matrix = begin
  JSON.parse(File.read(File.join(ROOT, '.github/ci-matrix.json')))
rescue StandardError
  failures << '.github/ci-matrix.json: dispatch contract JSON is invalid'
  {}
end
contract = matrix['dispatch_contracts']
unless contract.is_a?(Hash) && contract['version'] == 1 &&
       contract['source_repository'] == 'Moh-Bakr/Taurine' &&
       contract['control_repository'] == 'Moh-Bakr/Taurine-CI' &&
       contract['control_refs'] == %w[refs/heads/main refs/heads/untrusted]
  failures << '.github/ci-matrix.json: dispatch identity constants are not the reviewed version-1 values'
  contract = {}
end
workflows = contract['workflows'] || {}
failures << '.github/ci-matrix.json: dispatch workflow set differs from the reviewed protected entrypoints' unless workflows.keys.sort == EXPECTED_WORKFLOWS.sort
EXPECTED_INPUTS.each do |path, expected_inputs|
  failures << ".github/ci-matrix.json: #{path} input contract differs from the reviewed schema" unless workflows.dig(path, 'inputs') == expected_inputs
end

workflows.each do |path, spec|
  unless EXPECTED_WORKFLOWS.include?(path) && spec.is_a?(Hash) && spec['inputs'].is_a?(Hash)
    failures << '.github/ci-matrix.json: a dispatch workflow entry has an unreviewed shape'
    next
  end
  doc = load_yaml(File.join(ROOT, path))
  unless doc.is_a?(Hash)
    failures << "#{path}: workflow YAML is invalid"
    next
  end
  triggers = doc['on'] || doc[true] || {}
  dispatch = triggers.is_a?(Hash) ? triggers['workflow_dispatch'] : nil
  actual_inputs = dispatch.is_a?(Hash) ? dispatch['inputs'] : nil
  if !actual_inputs.is_a?(Hash) || actual_inputs.keys.map(&:to_s).sort != spec['inputs'].keys.sort
    failures << "#{path}: workflow_dispatch input names differ from the reviewed identity contract"
    next
  end

  spec['inputs'].each do |name, declared|
    unless declared.is_a?(Hash)
      failures << "#{path}: input #{name} has an invalid contract shape"
      next
    end
    actual = actual_inputs[name] || actual_inputs[name.to_sym]
    options_match = if declared['format'] == 'engine-selection'
                      actual.is_a?(Hash) && !actual.key?('options') && declared['options'].is_a?(Array)
                    else
                      !declared.key?('options') || (actual.is_a?(Hash) && actual['options'] == declared['options'])
                    end
    unless declared.is_a?(Hash) && actual.is_a?(Hash) &&
           actual['type'] == declared['type'] &&
           actual['required'] == declared['required'] &&
           (!declared.key?('default') || actual['default'] == declared['default']) &&
           options_match
      failures << "#{path}: input #{name} differs from the reviewed type/default/options"
    end
  end

  unless doc['run-name'] == EXPECTED_RUN_NAME
    failures << "#{path}: run name must include the full source SHA and dispatch key"
  end
  expected_job = PREFLIGHT.fetch(path)
  jobs = doc['jobs'] || {}
  job = jobs[expected_job]
  steps = job.is_a?(Hash) ? job['steps'] || [] : []
  proofs = []
  steps.each_with_index do |step, index|
    proofs << [step, index] if step.is_a?(Hash) && step['name'] == 'Verify the coordinator dispatch identity'
  end
  unless proofs.length == 1
    failures << "#{path}: exactly one dispatch identity proof must run in #{expected_job}"
    next
  end
  step, index = proofs.first
  digest_inputs = spec['inputs'].select { |_name, input| input['digest_include'] == true }.keys.sort
  fields = digest_inputs.each_with_index.map { |name, position| "\"#{name}\":{#{position}}" }.join(',')
  args = digest_inputs.map { |name| "toJSON(inputs.#{name})" }.join(', ')
  expected_proof = {
    'name' => 'Verify the coordinator dispatch identity',
    'shell' => 'bash',
    'working-directory' => '${{ github.workspace }}',
    'env' => {
      'CI_WORKFLOW_PATH' => path,
      'CI_SOURCE_SHA' => '${{ inputs.source_sha }}',
      'CI_DISPATCH_KEY' => '${{ inputs.dispatch_key }}',
      'CI_NORMALIZED_INPUTS' => "${{ format('{{#{fields}}}', #{args}) }}",
      'CI_DISPATCH_CONTRACT_JSON' => '',
      'CI_GENERATE_ONLY' => 'false',
      'CI_CONTROL_REPOSITORY' => '${{ github.repository }}',
      'CI_CONTROL_SHA' => '${{ github.sha }}',
      'CI_CONTROL_REF' => '${{ github.ref }}'
    },
    'run' => 'ruby .github/policy/dispatch-identity.rb'
  }
  failures << "#{path}: dispatch identity step differs from its fixed trusted command/environment" unless step == expected_proof
  preflight_index = steps.index { |candidate| candidate.is_a?(Hash) && candidate['uses'] == './.github/actions/environment-preflight' }
  failures << "#{path}: identity proof must follow the environment preflight" unless preflight_index && preflight_index < index
  expected_prefix = [
    {
      'name' => 'Check out public control plane',
      'uses' => 'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1',
      'with' => { 'fetch-depth' => 1, 'persist-credentials' => false }
    },
    {
      'name' => 'Verify the source-read deployment branches',
      'uses' => './.github/actions/environment-preflight',
      'with' => { 'github-token' => '${{ github.token }}' }
    }
  ]
  expected_prefix << SOURCE_SHA_STEPS.fetch(path) if SOURCE_SHA_STEPS.key?(path)
  failures << "#{path}: dispatch identity must precede every non-validation action or command" unless steps[0...index] == expected_prefix
end

if failures.empty?
  puts 'dispatch contracts: all protected input schemas and trusted identity proofs match'
else
  failures.each { |failure| warn failure }
  exit 1
end
