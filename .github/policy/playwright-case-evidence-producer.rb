#!/usr/bin/env ruby
# Fixed, local-only Playwright evidence producer. This script is not wired into
# CI and its result remains unverified shadow evidence.
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'pathname'
require 'rbconfig'
require 'tmpdir'

class ProducerError < StandardError
  attr_reader :code

  def initialize(code)
    @code = code
    super(code)
  end
end

def reject!(code)
  raise ProducerError, code
end

ROOT = File.expand_path('../..', __dir__).freeze
REPORTER = File.join(__dir__, 'playwright-case-list-reporter.cjs').freeze
CONTRACT = File.join(__dir__, 'case-evidence-contract.rb').freeze
MAX_INPUT_BYTES = 1 * 1024 * 1024
MAX_REPORT_BYTES = 64 * 1024 * 1024
MAX_CASES = 250_000
TIMEOUT_SECONDS = 2 * 60 * 60
OUTPUT_LIMIT = 8 * 1024 * 1024
CONTRACT_RESULT_COUNTS = %w[
  discovered executed passed failed flaky skipped ignored quarantined env_skipped
].sort.freeze
CONTRACT_ERROR_CLASSES = %w[
  adapter_unsupported arguments_invalid case_collection_empty case_count_limit case_file_invalid invalid_input
  case_file_outside_root case_project_invalid case_status_invalid case_title_invalid collection_incomplete
  command_mismatch discovery_binding_invalid discovery_execution_mismatch duplicate_case_identity
  expected_shape_invalid expected_status_invalid identity_invalid identity_mismatch input_size_limit
  producer_failed producer_version_mismatch project_scope_mismatch report_count_mismatch report_digest_invalid
  report_project_mismatch report_shape_invalid report_status_mismatch reporter_errors_present
  schema_version_unsupported selection_invalid selection_mismatch tier_mismatch tool_version_mismatch
].sort.freeze
EXPECTED_KEYS = %w[
  schema_version source_sha control_sha manifest_digest catalog_digest selection_digest selection_mode
  selected_suite_ids runner_id config_id tier platform project tool_version repo_root
].sort.freeze
APP_CONFIG = {
  'playwright-desktop' => {
    'app' => 'taurine-desktop', 'config' => 'desktop-playwright-projects', 'version' => '1.62.0',
    'packages' => {
      'node_modules/@playwright/test' => 'sha512-9zOJ6ZQRAena31MpOH9VSzIz8Ou3YJ/wtY/eQm5T2uhfhG7/U3COrMS8xOtUrZrp9OgdmzEnIYODye3nY1VqzA==',
      'node_modules/playwright' => 'sha512-Z14dG305dgaLu6foB1TXQagFiW8JfSUIUaUuPaKQ6NtBPKF1P/qXcqfh6c6K/icPqdy37JmjbiBXf6JNg6Sylw==',
      'node_modules/playwright-core' => 'sha512-nsNRyq0r2zsG8AcRHWknc9QRA5XCueC7gWMrs+Gx2tlZn9hcl8zudfh00lhJPY1DE7NmZ6bDsT9g2yey8mXljA=='
    },
    'tiers' => {
      'smoke' => 'feedback', 'critical' => 'feedback', 'shell-browser' => 'feedback',
      'regression' => 'regression', 'bench' => 'benchmark', 'a11y' => 'a11y', 'visual' => 'visual'
    }
  },
  'playwright-mobile' => {
    'app' => 'taurine-mobile', 'config' => 'mobile-playwright-projects', 'version' => '1.62.1',
    'packages' => {
      'node_modules/@playwright/test' => 'sha512-DTcUc8qii+cpHvtOwggMtBRMjKZHXYWdw8syRYu2vtzuq4Wxphqq4NfCs5Zt44L6mA8rfDfj+PHnxFc/FeK6mQ==',
      'node_modules/playwright' => 'sha512-0M+L3LAD8/nm554LOla9Ayx0j0tmFZ0FBcoQ7F1VuVHpM/XpiC8RcDzBQB8W5+hA8L22THxELzeF+2WcUzvcLg==',
      'node_modules/playwright-core' => 'sha512-wPYSwEBJY9GHraISXqyqtx0na0LpO3XEX7jNDhntbex7tzUS7kLnZsOlFruFJB4Hi/rhDMjXGqHewDZ68nYZVw=='
    },
    'tiers' => { 'smoke' => 'smoke', 'critical' => 'critical', 'regression' => 'regression' }
  }
}.freeze

def json_digest(value)
  Digest::SHA256.hexdigest(JSON.generate(value))
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

def canonical_digest(value)
  Digest::SHA256.hexdigest(JSON.generate(sort_json(value), ascii_only: true))
end

def within?(path, root)
  root = File.realpath(root)
  path = File.realpath(path)
  path == root || path.start_with?(root.end_with?(File::SEPARATOR) ? root : "#{root}#{File::SEPARATOR}")
rescue SystemCallError
  false
end

def resolve_executable(name, path_value)
  path_value.to_s.split(File::PATH_SEPARATOR).each do |directory|
    candidate = File.join(directory, name)
    return File.realpath(candidate) if File.file?(candidate) && File.executable?(candidate)
  rescue SystemCallError
    next
  end
  reject!('runtime_unavailable')
end

def run_bounded(argv, chdir:, env:, timeout: TIMEOUT_SECONDS, capture_stdout: false)
  stdout_value = +''
  bytes = [0, 0]
  overflow = false
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  status = nil
  child_pid = nil
  completed = false
  Open3.popen3(env, *argv, chdir: chdir, pgroup: true, unsetenv_others: true) do |stdin, stdout, stderr, waiter|
    child_pid = waiter.pid
    stdin.close
    readers = [stdout, stderr].each_with_index.map do |stream, index|
      Thread.new do
        loop do
          chunk = stream.readpartial(16 * 1024)
          bytes[index] += chunk.bytesize
          overflow = true if bytes[index] > OUTPUT_LIMIT
          stdout_value << chunk if index.zero? && capture_stdout && stdout_value.bytesize < OUTPUT_LIMIT
          break if overflow
        rescue EOFError, IOError
          break
        end
      end
    end
    deadline = started + timeout
    stop_owned_group = lambda do
      Process.kill('TERM', -waiter.pid) rescue nil
      Process.kill('KILL', -waiter.pid) rescue nil
      readers.each(&:kill)
    end
    loop do
      break if waiter.join(0.05)
      if overflow
        stop_owned_group.call
        reject!('process_output_limit')
      end
      next if Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline

      stop_owned_group.call
      reject!('process_timeout')
    end
    until readers.none?(&:alive?)
      if overflow
        stop_owned_group.call
        reject!('process_output_limit')
      end
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        stop_owned_group.call
        reject!('process_timeout')
      end
      readers.each { |reader| reader.join(0.05) }
    end
    reject!('process_output_limit') if overflow || bytes.any? { |count| count > OUTPUT_LIMIT }
    status = waiter.value.exitstatus
    completed = true
  end
  [status, stdout_value]
rescue Errno::ENOENT
  reject!('runner_unavailable')
ensure
  if child_pid && !completed
    Process.kill('TERM', -child_pid) rescue nil
    sleep 0.2
    Process.kill('KILL', -child_pid) rescue nil
  end
end

def validate_contract_result!(exit_status, result)
  reject!('validator_failed') unless result.is_a?(Hash) && result['schema_version'] == 1
  case result['status']
  when 'shadow_valid_unverified_producer'
    reject!('validator_failed') unless exit_status == 0 && result.keys.sort == %w[counts schema_version status]
    counts = validate_contract_counts!(result['counts'])
    reject!('validator_failed') unless counts['failed'].zero? && counts['flaky'].zero? &&
      counts['skipped'].zero? && counts['ignored'].zero? && counts['quarantined'].zero? &&
      counts['env_skipped'].zero? && counts['passed'] == counts['executed']
    { 'schema_version' => 1, 'status' => 'shadow_valid_unverified_producer', 'counts' => counts }
  when 'shadow_blocked'
    if result.keys.sort == %w[counts schema_version status]
      reject!('validator_failed') unless exit_status == 1
      counts = validate_contract_counts!(result['counts'])
      reject!('validator_failed') if counts['failed'].zero? && counts['flaky'].zero? &&
        counts['skipped'].zero? && counts['ignored'].zero? && counts['quarantined'].zero? &&
        counts['env_skipped'].zero?
      { 'schema_version' => 1, 'status' => 'shadow_blocked', 'counts' => counts }
    elsif result.keys.sort == %w[error_class schema_version status]
      reject!('validator_failed') unless exit_status == 1 && CONTRACT_ERROR_CLASSES.include?(result['error_class'])
      { 'schema_version' => 1, 'status' => 'shadow_blocked', 'error_class' => result['error_class'] }
    else
      reject!('validator_failed')
    end
  else
    reject!('validator_failed')
  end
end

def validate_contract_counts!(counts)
  reject!('validator_failed') unless counts.is_a?(Hash) && counts.keys.sort == CONTRACT_RESULT_COUNTS &&
    counts.values.all? { |count| count.is_a?(Integer) && count.between?(0, MAX_CASES) } &&
    counts['discovered'] == counts['executed'] && counts['executed'].positive? &&
    %w[passed failed flaky skipped ignored quarantined env_skipped].sum { |key| counts.fetch(key) } == counts['executed']
  CONTRACT_RESULT_COUNTS.to_h { |key| [key, counts.fetch(key)] }
end

def checked_file(path, root, max_bytes)
  reject!('report_file_invalid') unless within?(path, root)
  stat = File.lstat(path)
  reject!('report_file_invalid') unless stat.file? && (stat.mode & 0o077).zero? && stat.size <= max_bytes
  JSON.parse(File.binread(path))
rescue JSON::ParserError, SystemCallError
  reject!('report_invalid')
end

def write_private_json(path, value)
  flags = File::WRONLY | File::CREAT | File::EXCL
  File.open(path, flags, 0o600) { |file| file.write(JSON.generate(value)); file.flush; file.fsync }
rescue SystemCallError
  reject!('private_output_failed')
end

def project_report_ids(report, runner, config, tier, platform, project, repo_root)
  reject!('report_shape_invalid') unless report.is_a?(Hash) && report.keys.sort == %w[errors suites] &&
    report['errors'].is_a?(Array) && report['errors'].empty? && report['suites'].is_a?(Array)
  ids = []
  walk = lambda do |suites, ancestors|
    suites.each do |suite|
      reject!('report_shape_invalid') unless suite.is_a?(Hash) && suite.keys.sort == %w[file specs] &&
        suite['file'].is_a?(String) && suite['file'].bytesize <= 4096 && !suite['file'].include?("\0") &&
        suite['specs'].is_a?(Array)
      file = suite['file']
      chain = ancestors
      specs = suite.fetch('specs', [])
      reject!('report_shape_invalid') unless specs.is_a?(Array)
      specs.each do |spec|
        reject!('report_shape_invalid') unless spec.is_a?(Hash) && spec.keys.sort == %w[file tests title] &&
          spec['title'].is_a?(String) && !spec['title'].empty? && spec['title'].bytesize <= 8192 && !spec['title'].include?("\0") &&
          spec['file'].is_a?(String) && spec['file'].bytesize <= 4096
        tests = spec.fetch('tests', [])
        reject!('report_shape_invalid') unless tests.is_a?(Array)
        tests.each do |test|
          reject!('report_shape_invalid') unless test.is_a?(Hash) && test.keys.sort == %w[projectName results status] &&
            test['projectName'] == project && test['status'] == 'discovered' && test['results'] == []
          case_file = spec['file'] || file
          reject!('report_shape_invalid') unless case_file.is_a?(String)
          if Pathname.new(case_file).absolute?
            reject!('report_path_invalid') unless File.expand_path(case_file).start_with?(File.expand_path(repo_root) + File::SEPARATOR)
            relative = Pathname.new(File.expand_path(case_file)).relative_path_from(Pathname.new(File.expand_path(repo_root))).to_s
          else
            relative = case_file
            relative = File.join(runner == 'playwright-desktop' ? 'taurine-desktop' : 'taurine-mobile', relative) unless relative.start_with?(runner == 'playwright-desktop' ? 'taurine-desktop/' : 'taurine-mobile/')
          end
          reject!('report_path_invalid') unless relative.start_with?(runner == 'playwright-desktop' ? 'taurine-desktop/' : 'taurine-mobile/')
          title = (chain + [spec['title']]).join(' > ')
          ids << json_digest([runner, config, tier, platform, project, relative, '', '', title])
          reject!('case_count_limit') if ids.length > MAX_CASES
        end
      end
    end
  end
  walk.call(report['suites'], [])
  reject!('case_collection_empty') if ids.empty?
  reject!('duplicate_case_identity') unless ids.uniq == ids
  ids
end

def validate_expected!(expected)
  reject!('expected_shape_invalid') unless expected.is_a?(Hash) && expected.keys.sort == EXPECTED_KEYS
  reject!('schema_version_unsupported') unless expected['schema_version'] == 1
  adapter = APP_CONFIG[expected['runner_id']]
  reject!('adapter_unsupported') unless adapter && expected['config_id'] == adapter['config']
  reject!('tier_mismatch') unless adapter['tiers'][expected['project']] == expected['tier']
  reject!('tool_version_mismatch') unless expected['tool_version'] == adapter['version']
  %w[source_sha control_sha].each { |key| reject!('identity_invalid') unless expected[key].is_a?(String) && expected[key].match?(/\A[0-9a-f]{40}\z/) }
  %w[manifest_digest catalog_digest selection_digest].each { |key| reject!('identity_invalid') unless expected[key].is_a?(String) && expected[key].match?(/\A[0-9a-f]{64}\z/) }
  reject!('identity_invalid') unless expected['selection_mode'] == 'full' &&
    %w[linux macos].include?(expected['platform'])
  reject!('identity_invalid') unless expected['selected_suite_ids'].is_a?(Array) &&
    !expected['selected_suite_ids'].empty? && expected['selected_suite_ids'].uniq == expected['selected_suite_ids'] &&
    expected['selected_suite_ids'].all? { |id| id.is_a?(String) && id.match?(/\A[a-z0-9.-]+\z/) }
  reject!('identity_invalid') unless json_digest(expected['selected_suite_ids'].sort) == expected['selection_digest']
  reject!('identity_invalid') unless expected['repo_root'].is_a?(String) && File.directory?(expected['repo_root']) &&
    expected['project'].is_a?(String)
  suite_prefix = "#{adapter.fetch('app').delete_prefix('taurine-')}.playwright.#{expected['tier']}."
  reject!('selection_mismatch') unless expected['selected_suite_ids'].all? { |id| id.start_with?(suite_prefix) }
  adapter
end

def validate_trusted_scope!(expected, adapter, source_root)
  matrix_path = File.join(ROOT, '.github/ci-matrix.json')
  reject!('catalog_binding_invalid') unless File.file?(matrix_path) && File.size(matrix_path) <= MAX_INPUT_BYTES
  matrix_bytes = File.binread(matrix_path)
  reject!('catalog_binding_invalid') unless matrix_bytes == git_file_at(ROOT, expected['control_sha'], '.github/ci-matrix.json')
  matrix = JSON.parse(matrix_bytes)
  catalog = matrix.fetch('suite_catalog')
  reject!('catalog_binding_invalid') unless canonical_digest(catalog) == expected['catalog_digest']

  manifest_relative = 'scripts/ci/suite-ownership.json'
  manifest_path = File.join(source_root, manifest_relative)
  reject!('manifest_binding_invalid') unless File.file?(manifest_path) && File.size(manifest_path) <= MAX_INPUT_BYTES &&
    within?(manifest_path, source_root)
  manifest_bytes = File.binread(manifest_path)
  reject!('manifest_binding_invalid') unless manifest_bytes == git_file_at(source_root, expected['source_sha'], manifest_relative)
  reject!('manifest_binding_invalid') unless canonical_digest(JSON.parse(manifest_bytes)) == expected['manifest_digest']

  suites = catalog.fetch('suites')
  reject!('catalog_binding_invalid') unless suites.is_a?(Array)
  by_id = suites.select { |row| row.is_a?(Hash) }.to_h { |row| [row['id'], row] }
  groups = catalog.fetch('coverage_requirements')
  reject!('catalog_binding_invalid') unless groups.is_a?(Array)
  matching_groups = groups.select do |group|
    group.is_a?(Hash) && group['runner'] == expected['runner_id'] && group['config'] == expected['config_id'] &&
      group['tier'] == expected['tier'] && group['platforms'].is_a?(Array) && group['platforms'].include?(expected['platform']) &&
      group['projects'].is_a?(Array) && group['projects'].include?(expected['project'])
  end
  reject!('selection_mismatch') unless matching_groups.length == 1 &&
    matching_groups.first['candidate_suite_ids'].is_a?(Array) &&
    matching_groups.first['candidate_suite_ids'].sort == expected['selected_suite_ids'].sort
  expected['selected_suite_ids'].each do |id|
    row = by_id[id]
    reject!('selection_mismatch') unless row.is_a?(Hash) && row['status'] == 'candidate' &&
      row['runner'] == expected['runner_id'] && row['config'] == expected['config_id'] &&
      row['tier'] == expected['tier'] && row['platforms'].is_a?(Array) && row['platforms'].include?(expected['platform']) &&
      row['projects'].is_a?(Array) && row['projects'].include?(expected['project'])
  end
rescue JSON::ParserError, KeyError, SystemCallError
  reject!('trusted_scope_invalid')
end

def git_head(path)
  git = resolve_executable('git', ENV.fetch('PATH', ''))
  reject!('git_untrusted') if within?(git, path) || within?(git, ROOT)
  env = { 'PATH' => File.dirname(git), 'HOME' => Dir.tmpdir, 'GIT_CONFIG_NOSYSTEM' => '1',
    'GIT_CONFIG_GLOBAL' => File::NULL, 'GIT_TERMINAL_PROMPT' => '0' }
  status, output = run_bounded([git, '-C', path, 'rev-parse', '--verify', 'HEAD'], chdir: ROOT, env: env, timeout: 15, capture_stdout: true)
  reject!('identity_mismatch') unless status == 0 && output.strip.match?(/\A[0-9a-f]{40}\z/)
  output.strip
end

def git_file_at(path, revision, relative)
  git = resolve_executable('git', ENV.fetch('PATH', ''))
  reject!('git_untrusted') if within?(git, path) || within?(git, ROOT)
  env = { 'PATH' => File.dirname(git), 'HOME' => Dir.tmpdir, 'GIT_CONFIG_NOSYSTEM' => '1',
    'GIT_CONFIG_GLOBAL' => File::NULL, 'GIT_TERMINAL_PROMPT' => '0' }
  status, output = run_bounded([git, '-C', path, 'show', "#{revision}:#{relative}"],
    chdir: ROOT, env: env, timeout: 15, capture_stdout: true)
  reject!('source_file_mismatch') unless status == 0
  output
end

def require_clean_checkout!(path)
  git = resolve_executable('git', ENV.fetch('PATH', ''))
  reject!('git_untrusted') if within?(git, path) || within?(git, ROOT)
  env = { 'PATH' => File.dirname(git), 'HOME' => Dir.tmpdir, 'GIT_CONFIG_NOSYSTEM' => '1',
    'GIT_CONFIG_GLOBAL' => File::NULL, 'GIT_TERMINAL_PROMPT' => '0' }
  status, output = run_bounded([git, '-C', path, 'status', '--porcelain=v1', '--untracked-files=all'],
    chdir: ROOT, env: env, timeout: 30, capture_stdout: true)
  reject!('source_checkout_dirty') unless status == 0 && output.empty?
end

def check_lock!(source_root, source_sha, app_root, adapter)
  relative_lock = "#{adapter.fetch('app')}/package-lock.json"
  lock_path = File.join(app_root, 'package-lock.json')
  reject!('lock_binding_invalid') unless File.file?(lock_path) && File.size(lock_path) <= MAX_INPUT_BYTES
  lock_bytes = File.binread(lock_path)
  reject!('lock_binding_invalid') unless lock_bytes == git_file_at(source_root, source_sha, relative_lock)
  lock = JSON.parse(lock_bytes)
  packages = lock.fetch('packages')
  adapter.fetch('packages').each do |name, integrity|
    entry = packages.fetch(name)
    reject!('lock_binding_invalid') unless entry['version'] == adapter['version'] && entry['integrity'] == integrity
    package_json_path = File.join(app_root, name, 'package.json')
    reject!('tool_binding_invalid') unless within?(package_json_path, File.join(app_root, 'node_modules'))
    package = JSON.parse(File.binread(package_json_path))
    reject!('tool_binding_invalid') unless package['version'] == adapter['version']
  end
  cli = File.join(app_root, 'node_modules/playwright/cli.js')
  reject!('tool_binding_invalid') unless within?(cli, File.join(app_root, 'node_modules'))
  cli
rescue JSON::ParserError, KeyError, SystemCallError
  reject!('lock_binding_invalid')
end

def child_environment(node, work, browser_cache:, report_path: nil, marker_path: nil, json_path: nil)
  environment = {
    'PATH' => [File.dirname(node), '/usr/bin', '/bin'].uniq.join(File::PATH_SEPARATOR),
    'HOME' => File.join(work, 'home'), 'TMPDIR' => work, 'CI' => 'true'
  }
  environment['PLAYWRIGHT_BROWSERS_PATH'] = browser_cache if browser_cache
  environment['TAURINE_CASE_EVIDENCE_REPORT_PATH'] = report_path if report_path
  environment['TAURINE_CASE_EVIDENCE_COMPLETION_PATH'] = marker_path if marker_path
  environment['PLAYWRIGHT_JSON_OUTPUT_NAME'] = json_path if json_path
  environment
end

def envelope(expected, phase, report, command_id, complete:, selected_ids: nil, discovered_ids: nil)
  common = {
    'schema_version' => 1, 'phase' => phase, 'source_sha' => expected['source_sha'],
    'control_sha' => expected['control_sha'], 'manifest_digest' => expected['manifest_digest'],
    'catalog_digest' => expected['catalog_digest'], 'selection_digest' => expected['selection_digest'],
    'collection_complete' => complete, 'collection_digest' => json_digest(report),
    'runner_id' => expected['runner_id'], 'config_id' => expected['config_id'], 'tier' => expected['tier'],
    'platform' => expected['platform'], 'report' => report, 'producer_version' => 'case-evidence-producer/1',
    'command_id' => command_id, 'tool_version' => expected['tool_version'],
    'producer_status' => complete ? 'complete' : 'failed'
  }
  if phase == 'execution'
    common['selected_suite_ids'] = selected_ids
    common['discovered_case_ids'] = discovered_ids
  end
  common
end

def sanitized_block(code)
  puts JSON.generate({ 'schema_version' => 1, 'status' => 'shadow_blocked', 'error_class' => code })
end

Signal.trap('TERM') { raise ProducerError, 'producer_cancelled' }
Signal.trap('INT') { raise ProducerError, 'producer_cancelled' }

begin
  reject!('arguments_invalid') unless ARGV.length == 1
  reject!('platform_unsupported') if RUBY_PLATFORM.match?(/mswin|mingw|cygwin/i)
  expected_path = File.realpath(ARGV.fetch(0))
  expected_stat = File.stat(expected_path)
  reject!('input_size_limit') unless expected_stat.file? && expected_stat.size <= MAX_INPUT_BYTES
  expected = JSON.parse(File.binread(expected_path))
  adapter = validate_expected!(expected)
  source_root = File.realpath(expected.fetch('repo_root'))
  reject!('identity_invalid') unless expected['repo_root'] == source_root && !within?(expected_path, source_root)
  reject!('identity_mismatch') unless git_head(source_root) == expected['source_sha'] && git_head(ROOT) == expected['control_sha']
  require_clean_checkout!(source_root)
  validate_trusted_scope!(expected, adapter, source_root)
  app_root = File.realpath(File.join(source_root, adapter.fetch('app')))
  config_path = File.join(app_root, 'playwright.config.ts')
  reject!('config_invalid') unless File.file?(config_path) && within?(config_path, app_root)
  config_relative = "#{adapter.fetch('app')}/playwright.config.ts"
  reject!('config_invalid') unless File.binread(config_path) == git_file_at(source_root, expected['source_sha'], config_relative)
  cli = check_lock!(source_root, expected['source_sha'], app_root, adapter)
  node = resolve_executable('node', ENV.fetch('PATH', ''))
  reject!('runtime_untrusted') if within?(node, source_root) || within?(node, ROOT)
  browser_cache = nil
  if ENV['PLAYWRIGHT_BROWSERS_PATH'] && !ENV['PLAYWRIGHT_BROWSERS_PATH'].empty?
    browser_cache = File.realpath(ENV.fetch('PLAYWRIGHT_BROWSERS_PATH'))
    reject!('browser_cache_invalid') unless File.directory?(browser_cache) && File.basename(browser_cache) == 'ms-playwright' &&
      !within?(browser_cache, source_root) && !within?(browser_cache, ROOT)
  end

  Dir.mktmpdir('case-evidence-producer-', ENV.fetch('RUNNER_TEMP', Dir.tmpdir)) do |work|
      File.chmod(0o700, work)
      home = File.join(work, 'home')
      Dir.mkdir(home, 0o700)
      base_env = child_environment(node, work, browser_cache: browser_cache)
      version_status, version_output = run_bounded([node, cli, '--version'], chdir: app_root,
        env: base_env, timeout: 30, capture_stdout: true)
      reject!('tool_version_mismatch') unless version_status == 0 &&
        [adapter['version'], "Version #{adapter['version']}"].include?(version_output.strip)

      project = expected.fetch('project')
      list_report_path = File.join(work, 'discovery.json')
      marker_path = File.join(work, 'completion.json')
      File.open(list_report_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.close }
      File.open(marker_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.close }
      list_env = child_environment(node, work, browser_cache: browser_cache,
        report_path: list_report_path, marker_path: marker_path)
      list_argv = [node, cli, 'test', '--config', 'playwright.config.ts', '--list', '--project', project,
        '--reporter', REPORTER]
      list_status, = run_bounded(list_argv, chdir: app_root, env: list_env)
      reject!('runner_failed') unless list_status == 0
      marker = checked_file(marker_path, work, 4096)
      reject!('reporter_failed') unless marker.is_a?(Hash) && marker.keys.sort == %w[count error_class schema_version status] &&
        marker['schema_version'] == 1 && marker['status'] == 'complete' && marker['error_class'].nil? &&
        marker['count'].is_a?(Integer) && marker['count'] > 0 && marker['count'] <= MAX_CASES
      discovery_report = checked_file(list_report_path, work, MAX_REPORT_BYTES)
      discovered_ids = project_report_ids(discovery_report, expected['runner_id'], expected['config_id'],
        expected['tier'], expected['platform'], project, source_root)
      reject!('report_count_mismatch') unless marker['count'] == discovered_ids.length

      execution_path = File.join(work, 'execution.json')
      File.open(execution_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.close }
      execution_env = child_environment(node, work, browser_cache: browser_cache, json_path: execution_path)
      execution_argv = [node, cli, 'test', '--config', 'playwright.config.ts', '--project', project, '--reporter', 'json']
      execution_status, = run_bounded(execution_argv, chdir: app_root, env: execution_env)
      reject!('runner_failed') unless execution_status == 0
      execution_report = checked_file(execution_path, work, MAX_REPORT_BYTES)

      discovery_command = "playwright.#{adapter.fetch('app') == 'taurine-desktop' ? 'desktop' : 'mobile'}.list.#{project}.v1"
      execution_command = "playwright.#{adapter.fetch('app') == 'taurine-desktop' ? 'desktop' : 'mobile'}.run.#{project}.v1"
      discovery_envelope = envelope(expected, 'discovery', discovery_report, discovery_command,
        complete: true)
      execution_envelope = envelope(expected, 'execution', execution_report, execution_command,
        complete: true, selected_ids: expected.fetch('selected_suite_ids'), discovered_ids: discovered_ids)
      expected_copy = File.join(work, 'expected.json')
      discovery_copy = File.join(work, 'discovery-envelope.json')
      execution_copy = File.join(work, 'execution-envelope.json')
      write_private_json(expected_copy, expected)
      write_private_json(discovery_copy, discovery_envelope)
      write_private_json(execution_copy, execution_envelope)
      validator = RbConfig.ruby
      validator_env = { 'PATH' => [File.dirname(node), '/usr/bin', '/bin'].uniq.join(File::PATH_SEPARATOR),
        'HOME' => home, 'TMPDIR' => work, 'GIT_CONFIG_NOSYSTEM' => '1', 'GIT_CONFIG_GLOBAL' => File::NULL }
      validator_status, result_json = run_bounded([validator, CONTRACT, expected_copy, discovery_copy, execution_copy],
        chdir: ROOT, env: validator_env, timeout: 60, capture_stdout: true)
      result = JSON.parse(result_json)
      safe_result = validate_contract_result!(validator_status, result)
      puts JSON.generate(safe_result)
      exit(validator_status)
  end
rescue ProducerError => error
  sanitized_block(error.code)
  exit 1
rescue JSON::ParserError, KeyError, TypeError, SystemCallError, ArgumentError, NoMethodError
  sanitized_block('producer_input_invalid')
  exit 1
rescue StandardError
  sanitized_block('producer_failed')
  exit 1
end
