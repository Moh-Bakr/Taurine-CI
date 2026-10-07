#!/usr/bin/env ruby
# Verify and publish only a canonical dispatch identity from the trusted pre-source job.
require 'digest'
require 'json'

class DispatchIdentityError < StandardError
  attr_reader :code

  def initialize(code)
    @code = code
  end
end

def reject_identity(code)
  raise DispatchIdentityError, code
end

def sort_json(value)
  case value
  when Hash
    value.keys.sort.each_with_object({}) { |key, result| result[key] = sort_json(value.fetch(key)) }
  when Array
    value.map { |item| sort_json(item) }
  else
    value
  end
end

def valid_sha?(value, length)
  value.is_a?(String) && value.match?(/\A[0-9a-f]{#{length}}\z/)
end

def canonical_inputs(declared_inputs, supplied)
  reject_identity('inputs_invalid') unless supplied.is_a?(Hash)
  digest_inputs = declared_inputs.select { |_name, spec| spec['digest_include'] == true }
  accepted = declared_inputs.keys - ['dispatch_key']
  reject_identity('inputs_invalid') unless (supplied.keys - accepted).empty?

  normalized = {}
  digest_inputs.keys.sort.each do |name|
    spec = declared_inputs.fetch(name)
    unless supplied.key?(name)
      reject_identity('inputs_invalid') if spec['required'] == true || !spec.key?('default')
      value = spec.fetch('default')
    else
      value = supplied.fetch(name)
    end
    case spec.fetch('type')
    when 'boolean'
      reject_identity('inputs_invalid') unless value == true || value == false
    when 'string', 'choice'
      reject_identity('inputs_invalid') unless value.is_a?(String) && value.ascii_only?
      options = spec['options']
      reject_identity('inputs_invalid') if options && spec['format'] != 'engine-selection' && !options.include?(value)
      case spec['format']
      when 'engine-selection'
        requested = value.gsub(/[[:space:]]/, '')
        if requested == 'all'
          # "all" and the explicit complete roster execute the same engines, so their
          # dispatch identities must also be identical (otherwise duplicate full runs
          # can be manufactured by changing only the spelling).
          value = options.join(',')
        else
          selected = requested.split(',', -1)
          reject_identity('inputs_invalid') if selected.empty? || selected.any?(&:empty?)
          reject_identity('inputs_invalid') unless (selected - options).empty?
          reject_identity('inputs_invalid') unless selected.uniq == selected
          value = options.select { |engine| selected.include?(engine) }.join(',')
        end
      when 'sha40'
        value = value.downcase
        reject_identity('inputs_invalid') unless valid_sha?(value, 40)
      when 'optional-sha40'
        value = value.downcase unless value.empty?
        reject_identity('inputs_invalid') unless value.empty? || valid_sha?(value, 40)
      end
    else
      reject_identity('schema_invalid')
    end
    normalized[name] = value
  end
  normalized
end

begin
  table_json = ENV['CI_DISPATCH_CONTRACT_JSON']
  table_json = nil if table_json.to_s.empty?
  table = JSON.parse(table_json || File.read('.github/ci-matrix.json'))
  if table.is_a?(Hash) && !table.key?('dispatch_contracts') && table.key?('workflows')
    table = { 'dispatch_contracts' => table }
  end
  reject_identity('contract_invalid') unless table.is_a?(Hash) && table['dispatch_contracts'].is_a?(Hash)
  contract = table.fetch('dispatch_contracts')
  path = ENV.fetch('CI_WORKFLOW_PATH')
  workflows = contract['workflows']
  reject_identity('contract_invalid') unless workflows.is_a?(Hash)
  reject_identity('workflow_invalid') unless workflows.key?(path)
  workflow = workflows.fetch(path)
  declared_inputs = workflow.is_a?(Hash) ? workflow['inputs'] : nil
  reject_identity('schema_invalid') unless declared_inputs.is_a?(Hash)

  control_repository = ENV.fetch('CI_CONTROL_REPOSITORY')
  control_sha = ENV.fetch('CI_CONTROL_SHA').downcase
  control_ref = ENV.fetch('CI_CONTROL_REF')
  source_sha = ENV.fetch('CI_SOURCE_SHA').downcase
  generate_only = ENV['CI_GENERATE_ONLY'] == 'true'
  dispatch_key = ENV['CI_DISPATCH_KEY'] unless generate_only
  reject_identity('context_invalid') unless control_repository == contract.fetch('control_repository') &&
    valid_sha?(control_sha, 40) && contract.fetch('control_refs').include?(control_ref) && valid_sha?(source_sha, 40)
  reject_identity('key_invalid') unless generate_only || valid_sha?(dispatch_key, 64)

  inputs = JSON.parse(ENV.fetch('CI_NORMALIZED_INPUTS'))
  normalized_inputs = canonical_inputs(declared_inputs, inputs)
  reject_identity('source_mismatch') unless normalized_inputs['source_sha'] == source_sha

  identity = {
    'schema_version' => contract.fetch('version'),
    'source_repository' => contract.fetch('source_repository'),
    'source_sha' => source_sha,
    'control_repository' => contract.fetch('control_repository'),
    'control_sha' => control_sha,
    'control_ref' => control_ref,
    'workflow_path' => path,
    'inputs' => normalized_inputs
  }
  canonical = JSON.generate(sort_json(identity), ascii_only: true)
  digest = Digest::SHA256.hexdigest(canonical)
  if generate_only
    puts digest
    exit 0
  end
  reject_identity('key_mismatch') unless digest == dispatch_key

  proof = {
    'schema_version' => 1,
    'dispatch_key' => digest,
    'identity_sha256' => digest,
    'identity' => sort_json(identity)
  }
  proof_json = JSON.generate(sort_json(proof), ascii_only: true)
  puts "CI_DISPATCH_IDENTITY=#{proof_json}"
  if (output = ENV['GITHUB_OUTPUT'])
    File.open(output, 'a') do |file|
      file.puts "dispatch_key=#{digest}"
      file.puts "identity_json=#{JSON.generate(sort_json(identity), ascii_only: true)}"
    end
  end
rescue DispatchIdentityError => error
  STDERR.puts "CI_DISPATCH_IDENTITY_ERROR=#{error.code}"
  exit 1
rescue StandardError
  STDERR.puts 'CI_DISPATCH_IDENTITY_ERROR=contract_invalid'
  exit 1
end
