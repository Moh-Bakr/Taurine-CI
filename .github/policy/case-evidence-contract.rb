#!/usr/bin/env ruby
# Standalone structural contract for private case-level discovery/execution evidence.
# This does not execute a runner or attest that a producer actually ran a command.
require 'digest'
require 'json'
require 'pathname'

class ContractError < StandardError
  attr_reader :code

  def initialize(code)
    @code = code
    super(code)
  end
end

def reject!(code)
  raise ContractError, code
end

PRODUCER_VERSION = 'case-evidence-producer/1'.freeze
SHA40 = /\A[0-9a-f]{40}\z/
SHA256 = /\A[0-9a-f]{64}\z/
MAX_EVIDENCE_BYTES = 64 * 1024 * 1024
MAX_CASES = 250_000
PLATFORMS = %w[linux macos windows android ios].freeze
DISCOVERY_KEYS = %w[
  schema_version phase source_sha control_sha manifest_digest catalog_digest selection_digest
  collection_complete collection_digest runner_id config_id tier platform report producer_version
  command_id tool_version producer_status
].sort.freeze
EXECUTION_KEYS = (DISCOVERY_KEYS + %w[selected_suite_ids discovered_case_ids]).sort.freeze
EXPECTED_KEYS = %w[
  schema_version source_sha control_sha manifest_digest catalog_digest selection_digest selection_mode
  selected_suite_ids runner_id config_id tier platform project tool_version repo_root
].sort.freeze

# These identifiers name fixed future invocations. No command string or argument
# can be supplied by the source repository or by an evidence envelope.
ADAPTERS = {
  ['vitest-desktop', 'desktop-vitest-default'] => {
    'tier' => 'default', 'tool' => 'vitest', 'discovery' => 'vitest.desktop.list.v1',
    'execution' => 'vitest.desktop.run.v1', 'projects' => []
  },
  ['vitest-mobile', 'mobile-vitest-default'] => {
    'tier' => 'default', 'tool' => 'vitest', 'discovery' => 'vitest.mobile.list.v1',
    'execution' => 'vitest.mobile.run.v1', 'projects' => []
  },
  ['vitest-shared', 'shared-vitest-default'] => {
    'tier' => 'default', 'tool' => 'vitest', 'discovery' => 'vitest.shared.list.v1',
    'execution' => 'vitest.shared.run.v1', 'projects' => []
  },
  ['playwright-desktop', 'desktop-playwright-projects'] => {
    'tool' => 'playwright', 'discovery_prefix' => 'playwright.desktop.list.',
    'execution_prefix' => 'playwright.desktop.run.',
    'projects_by_tier' => {
      'feedback' => %w[smoke critical shell-browser], 'regression' => %w[regression],
      'benchmark' => %w[bench], 'a11y' => %w[a11y], 'visual' => %w[visual]
    }
  },
  ['playwright-mobile', 'mobile-playwright-projects'] => {
    'tool' => 'playwright', 'discovery_prefix' => 'playwright.mobile.list.',
    'execution_prefix' => 'playwright.mobile.run.',
    'projects_by_tier' => {
      'smoke' => %w[smoke], 'critical' => %w[critical], 'regression' => %w[regression]
    }
  }
}.freeze

def exact_keys!(value, keys, code)
  reject!(code) unless value.is_a?(Hash) && value.keys.sort == keys
end

def json_digest(value)
  Digest::SHA256.hexdigest(JSON.generate(value))
end

def canonical_selected_digest(ids)
  json_digest(ids.sort)
end

def safe_relative_file(value, repo_root)
  reject!('case_file_invalid') unless value.is_a?(String) && !value.empty? && value.bytesize <= 4096
  if Pathname.new(value).absolute?
    root = File.expand_path(repo_root)
    absolute = File.expand_path(value)
    prefix = root.end_with?(File::SEPARATOR) ? root : "#{root}#{File::SEPARATOR}"
    reject!('case_file_outside_root') unless absolute.start_with?(prefix)
    value = absolute.delete_prefix(prefix)
  end
  path = value.tr('\\', '/')
  reject!('case_file_invalid') if path.start_with?('/') || path.split('/').any? { |part| part.empty? || part == '.' || part == '..' }
  reject!('case_file_invalid') if path.split('/').include?('node_modules') || path.include?("\0")
  path
end

def status_for(value, kind, phase)
  if phase == 'discovery'
    reject!('case_status_invalid') unless value == 'discovered'
    return value
  end
  allowed = %w[passed failed flaky skipped ignored quarantined env_skipped]
  return value if allowed.include?(value)
  if kind == 'vitest'
    return 'passed' if value == 'passed'
    return 'failed' if value == 'failed'
    return 'skipped' if %w[skipped pending todo disabled].include?(value)
  elsif kind == 'playwright'
    return 'passed' if value == 'expected' || value == 'passed'
    return 'failed' if %w[unexpected timedOut interrupted failed].include?(value)
    return 'flaky' if value == 'flaky'
    return 'skipped' if %w[skipped].include?(value)
  end
  reject!('case_status_invalid')
end

def expected_playwright_attempt_status(value)
  reject!('expected_status_invalid') unless %w[passed failed timedOut skipped interrupted].include?(value)
  return 'passed' if value == 'passed'
  return 'skipped' if value == 'skipped'

  'failed'
end

def case_record(runner, config, tier, platform, project, file, title, status, kind, phase, repo_root)
  reject!('case_title_invalid') unless title.is_a?(String) && !title.empty? && title.bytesize <= 8192 && !title.include?("\0")
  reject!('case_project_invalid') unless project.nil? || (project.is_a?(String) && !project.empty? && project.bytesize <= 256)
  relative_file = safe_relative_file(file, repo_root)
  identity = [runner, config, tier, platform, project || '', relative_file, '', '', title]
  { 'case_id' => json_digest(identity), 'status' => status_for(status, kind, phase) }
end

def vitest_cases(report, phase, runner, config, tier, platform, repo_root)
  if phase == 'discovery'
    reject!('report_shape_invalid') unless report.is_a?(Array)
    report.map do |entry|
      reject!('report_shape_invalid') unless entry.is_a?(Hash) && entry['file'].is_a?(String) && entry['name'].is_a?(String)
      case_record(runner, config, tier, platform, entry['projectName'], entry['file'], entry['name'],
        'discovered', 'vitest', phase, repo_root)
    end
  else
    reject!('report_shape_invalid') unless report.is_a?(Hash) && report['testResults'].is_a?(Array)
    cases = report['testResults'].flat_map do |file_result|
      reject!('report_shape_invalid') unless file_result.is_a?(Hash) && file_result['name'].is_a?(String) && file_result['assertionResults'].is_a?(Array)
      file_result['assertionResults'].map do |assertion|
        reject!('report_shape_invalid') unless assertion.is_a?(Hash) && assertion['title'].is_a?(String)
        ancestors = assertion['ancestorTitles'].is_a?(Array) ? assertion['ancestorTitles'] : []
        reject!('report_shape_invalid') unless ancestors.all? { |item| item.is_a?(String) }
        title = (ancestors + [assertion['title']]).reject(&:empty?).join(' > ')
        case_record(runner, config, tier, platform, file_result['projectName'], file_result['name'], title,
          assertion['status'], 'vitest', phase, repo_root)
      end
    end
    reject!('report_count_mismatch') unless report['numTotalTests'].is_a?(Integer) && report['numTotalTests'] == cases.length
    counts = cases.map { |item| item['status'] }.tally
    reject!('report_count_mismatch') unless report['numPassedTests'].is_a?(Integer) && report['numPassedTests'] == counts.fetch('passed', 0)
    reject!('report_count_mismatch') unless report['numFailedTests'].is_a?(Integer) && report['numFailedTests'] == counts.fetch('failed', 0)
    pending = counts.fetch('skipped', 0)
    reject!('report_count_mismatch') unless report['numPendingTests'].is_a?(Integer) && report['numPendingTests'] == pending
    cases
  end
end

def playwright_cases(report, phase, runner, config, tier, platform, repo_root, expected_project)
  reject!('report_shape_invalid') unless report.is_a?(Hash) && report['suites'].is_a?(Array)
  if report.key?('errors')
    reject!('report_shape_invalid') unless report['errors'].is_a?(Array)
    report['errors'].each do |error|
      reject!('report_shape_invalid') unless error.is_a?(Hash) && error['message'].is_a?(String) && !error['message'].empty?
      reject!('report_shape_invalid') if error.key?('stack') && !error['stack'].is_a?(String)
    end
    reject!('reporter_errors_present') unless report['errors'].empty?
  end
  if report.key?('stats')
    stats = report['stats']
    reject!('report_shape_invalid') unless stats.is_a?(Hash)
    if phase == 'execution'
      status_counts = %w[expected skipped unexpected flaky]
      reject!('report_count_mismatch') unless status_counts.all? { |key| stats[key].is_a?(Integer) && stats[key] >= 0 }
    end
  end
  cases = []
  outcomes = []
  walk = lambda do |suites, inherited_file, ancestors|
    suites.each do |suite|
      reject!('report_shape_invalid') unless suite.is_a?(Hash)
      file = suite['file'].is_a?(String) ? suite['file'] : inherited_file
      chain = suite['file'] ? ancestors : ancestors + (suite['title'].is_a?(String) && !suite['title'].empty? ? [suite['title']] : [])
      specs = suite.fetch('specs', [])
      reject!('report_shape_invalid') unless specs.is_a?(Array)
      specs.each do |spec|
        reject!('report_shape_invalid') unless spec.is_a?(Hash) && spec['title'].is_a?(String)
        tests = spec.fetch('tests', [])
        reject!('report_shape_invalid') unless tests.is_a?(Array)
        tests.each do |test|
          reject!('report_shape_invalid') unless test.is_a?(Hash) && test['projectName'].is_a?(String)
          reject!('report_project_mismatch') unless test['projectName'] == expected_project
          results = test.fetch('results', [])
          reject!('report_shape_invalid') unless results.is_a?(Array)
          if phase == 'execution'
            reject!('report_shape_invalid') unless test['status'].is_a?(String)
            results.each do |result|
              reject!('report_shape_invalid') unless result.is_a?(Hash) && result['status'].is_a?(String)
              status_for(result['status'], 'playwright', phase)
            end
            expected_status = expected_playwright_attempt_status(test.fetch('expectedStatus', 'passed'))
            status = status_for(test['status'], 'playwright', phase)
            reject!('report_shape_invalid') if results.empty? && status != 'skipped'
            attempt_statuses = results.map { |result| status_for(result['status'], 'playwright', phase) }
            if status == 'flaky'
              reject!('report_status_mismatch') if expected_status == 'skipped'
              reject!('report_status_mismatch') unless attempt_statuses.length > 1 &&
                attempt_statuses.last == expected_status && attempt_statuses[0...-1].any? { |attempt| attempt != expected_status }
            end
            if status == 'passed'
              reject!('report_status_mismatch') if expected_status == 'skipped'
              reject!('report_status_mismatch') unless attempt_statuses.all? { |attempt| attempt == expected_status }
            elsif status == 'skipped'
              reject!('report_status_mismatch') unless expected_status == 'skipped'
              reject!('report_status_mismatch') unless attempt_statuses.all? { |attempt| attempt == 'skipped' }
            end
          else
            status = 'discovered'
          end
          title = (chain + [spec['title']]).join(' > ')
          case_file = spec['file'] || file
          app_root = runner == 'playwright-desktop' ? 'taurine-desktop/' : 'taurine-mobile/'
          case_file = "#{app_root}#{case_file}" unless Pathname.new(case_file).absolute? || case_file.start_with?(app_root)
          cases << case_record(runner, config, tier, platform, test['projectName'], case_file,
            title, status, 'playwright', phase, repo_root)
          outcomes << status if phase == 'execution'
        end
      end
      children = suite.fetch('suites', [])
      reject!('report_shape_invalid') unless children.is_a?(Array)
      walk.call(children, file, chain)
    end
  end
  walk.call(report['suites'], nil, [])
  if phase == 'execution' && report['stats'].is_a?(Hash) && %w[expected skipped unexpected flaky].all? { |key| report['stats'].key?(key) }
    counts = outcomes.tally
    expected = {
      'expected' => counts.fetch('passed', 0), 'skipped' => counts.fetch('skipped', 0),
      'unexpected' => counts.fetch('failed', 0), 'flaky' => counts.fetch('flaky', 0)
    }
    reject!('report_count_mismatch') unless expected.all? { |key, value| report['stats'][key] == value }
  end
  cases
end

def parse_cases(envelope, expected, phase)
  adapter = ADAPTERS[[expected.fetch('runner_id'), expected.fetch('config_id')]]
  reject!('adapter_unsupported') unless adapter
  if adapter['tool'] == 'vitest'
    reject!('tier_mismatch') unless expected['tier'] == adapter.fetch('tier')
    command = phase == 'discovery' ? adapter.fetch('discovery') : adapter.fetch('execution')
    cases = vitest_cases(envelope.fetch('report'), phase, expected.fetch('runner_id'), expected.fetch('config_id'),
      expected.fetch('tier'), expected.fetch('platform'), expected.fetch('repo_root'))
  else
    project = adapter.fetch('projects_by_tier')[expected.fetch('tier')]
    reject!('tier_mismatch') unless project && project.include?(expected.fetch('project'))
    command = "#{phase == 'discovery' ? adapter.fetch('discovery_prefix') : adapter.fetch('execution_prefix')}#{expected.fetch('project')}.v1"
    cases = playwright_cases(envelope.fetch('report'), phase, expected.fetch('runner_id'), expected.fetch('config_id'),
      expected.fetch('tier'), expected.fetch('platform'), expected.fetch('repo_root'), expected.fetch('project'))
  end
  reject!('command_mismatch') unless envelope['command_id'] == command
  reject!('producer_version_mismatch') unless envelope['producer_version'] == PRODUCER_VERSION
  cases
end

def validate_expected(expected)
  exact_keys!(expected, EXPECTED_KEYS, 'expected_shape_invalid')
  reject!('schema_version_unsupported') unless expected['schema_version'] == 1
  reject!('identity_invalid') unless expected['source_sha'].is_a?(String) && expected['source_sha'].match?(SHA40) &&
    expected['control_sha'].is_a?(String) && expected['control_sha'].match?(SHA40) &&
    %w[manifest_digest catalog_digest selection_digest].all? { |key| expected[key].is_a?(String) && expected[key].match?(SHA256) }
  reject!('selection_invalid') unless %w[full shadow].include?(expected['selection_mode']) &&
    expected['selected_suite_ids'].is_a?(Array) && !expected['selected_suite_ids'].empty? &&
    expected['selected_suite_ids'].all? { |id| id.is_a?(String) && id.match?(/\A[a-z0-9.-]+\z/) } &&
    expected['selected_suite_ids'].uniq == expected['selected_suite_ids'] &&
    expected['selection_digest'] == canonical_selected_digest(expected['selected_suite_ids'])
  reject!('identity_invalid') unless expected['runner_id'].is_a?(String) && expected['config_id'].is_a?(String) &&
    expected['tier'].is_a?(String) && PLATFORMS.include?(expected['platform']) && expected['tool_version'].is_a?(String) &&
    expected['tool_version'].match?(/\A\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?\z/) &&
    expected['repo_root'].is_a?(String) && File.directory?(expected['repo_root'])
  adapter = ADAPTERS[[expected['runner_id'], expected['config_id']]]
  reject!('adapter_unsupported') unless adapter
  if adapter['tool'] == 'vitest'
    reject!('tier_mismatch') unless expected['tier'] == adapter.fetch('tier') && expected['project'].nil?
  else
    project_list = adapter.fetch('projects_by_tier')[expected['tier']]
    reject!('tier_mismatch') unless project_list
    reject!('expected_shape_invalid') unless expected['project'].is_a?(String)
    reject!('project_scope_mismatch') unless project_list.include?(expected['project'])
  end
end

def validate_envelope(envelope, expected, phase)
  keys = phase == 'discovery' ? DISCOVERY_KEYS : EXECUTION_KEYS
  exact_keys!(envelope, keys, 'envelope_shape_invalid')
  reject!('schema_version_unsupported') unless envelope['schema_version'] == 1 && envelope['phase'] == phase
  reject!('producer_failed') unless envelope['producer_status'] == 'complete'
  reject!('collection_incomplete') unless envelope['collection_complete'] == true
  %w[source_sha control_sha manifest_digest catalog_digest selection_digest runner_id config_id tier platform].each do |key|
    reject!('identity_mismatch') unless envelope[key] == expected[key]
  end
  reject!('report_digest_invalid') unless envelope['collection_digest'].is_a?(String) && envelope['collection_digest'].match?(SHA256) &&
    envelope['collection_digest'] == json_digest(envelope['report'])
  reject!('tool_version_mismatch') unless envelope['tool_version'] == expected['tool_version']
  cases = parse_cases(envelope, expected, phase)
  reject!('case_count_limit') if cases.length > MAX_CASES
  reject!('case_collection_empty') if cases.empty?
  ids = cases.map { |item| item.fetch('case_id') }
  reject!('duplicate_case_identity') unless ids.uniq == ids
  if phase == 'execution'
    selected = envelope['selected_suite_ids']
    reject!('selection_mismatch') unless selected.is_a?(Array) && selected.uniq == selected && selected.sort == expected['selected_suite_ids'].sort
    discovered = envelope['discovered_case_ids']
    reject!('discovery_binding_invalid') unless discovered.is_a?(Array) && discovered.all? { |id| id.is_a?(String) && id.match?(SHA256) } && discovered.uniq == discovered
    reject!('discovery_execution_mismatch') unless discovered.sort == ids.sort
  end
  cases
end

def sanitize_result(discovery, execution)
  statuses = execution.map { |item| item.fetch('status') }.tally
  clean = statuses.fetch('passed', 0) == execution.length
  {
    'schema_version' => 1,
    # A structurally reconciled report is still shadow evidence: this program
    # cannot attest that the claimed producer invoked the fixed command.
    'status' => clean ? 'shadow_valid_unverified_producer' : 'shadow_blocked',
    'counts' => {
      'discovered' => discovery.length, 'executed' => execution.length,
      'passed' => statuses.fetch('passed', 0), 'failed' => statuses.fetch('failed', 0),
      'flaky' => statuses.fetch('flaky', 0), 'skipped' => statuses.fetch('skipped', 0),
      'ignored' => statuses.fetch('ignored', 0), 'quarantined' => statuses.fetch('quarantined', 0),
      'env_skipped' => statuses.fetch('env_skipped', 0)
    }
  }
end

begin
  expected_path, discovery_path, execution_path = ARGV
  reject!('arguments_invalid') unless expected_path && discovery_path && execution_path && ARGV.length == 3
  [expected_path, discovery_path, execution_path].each do |path|
    reject!('input_size_limit') unless File.file?(path) && File.size(path) <= MAX_EVIDENCE_BYTES
  end
  expected = JSON.parse(File.read(expected_path))
  validate_expected(expected)
  discovery_envelope = JSON.parse(File.read(discovery_path))
  execution_envelope = JSON.parse(File.read(execution_path))
  discovery = validate_envelope(discovery_envelope, expected, 'discovery')
  execution = validate_envelope(execution_envelope, expected, 'execution')
  discovery_ids = discovery.map { |item| item.fetch('case_id') }.sort
  execution_ids = execution.map { |item| item.fetch('case_id') }.sort
  reject!('discovery_execution_mismatch') unless discovery_ids == execution_ids
  result = sanitize_result(discovery, execution)
  puts JSON.generate(result)
  exit 1 if result.fetch('status') == 'shadow_blocked'
rescue ContractError => error
  puts JSON.generate({ 'schema_version' => 1, 'status' => 'shadow_blocked', 'error_class' => error.code })
  exit 1
rescue JSON::ParserError, KeyError, TypeError, SystemCallError, ArgumentError, NoMethodError
  puts JSON.generate({ 'schema_version' => 1, 'status' => 'shadow_blocked', 'error_class' => 'invalid_input' })
  exit 1
end
