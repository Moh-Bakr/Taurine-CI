#!/usr/bin/env ruby
# Fixed synthetic Playwright parity harness. Shadow-only: it reports fixture
# reconciliation, never source-suite coverage or an admission decision.
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'pathname'
require 'rbconfig'
require 'tmpdir'

class ParityError < StandardError
  attr_reader :code

  def initialize(code)
    @code = code
    super(code)
  end
end

def reject!(code)
  raise ParityError, code
end

ROOT = File.expand_path('../..', __dir__).freeze
EXPECTED_PATH = File.join(ROOT, '.github/policy/fixtures/playwright-case-parity/expected-cases.json').freeze
REPORTER_PATH = File.join(ROOT, '.github/policy/playwright-case-list-reporter.cjs').freeze
FIXTURE_DIR = File.dirname(EXPECTED_PATH).freeze
MAX_INPUT_BYTES = 1 * 1024 * 1024
MAX_REPORT_BYTES = 4 * 1024 * 1024
MAX_CASES = 64
OUTPUT_LIMIT = 1 * 1024 * 1024
PROCESS_TIMEOUT = 120
RUNNER_BINDINGS = {
  'playwright-desktop' => {
    'app' => 'taurine-desktop', 'config' => 'desktop-playwright-projects', 'version' => '1.62.0',
    'packages' => {
      'node_modules/@playwright/test' => 'sha512-9zOJ6ZQRAena31MpOH9VSzIz8Ou3YJ/wtY/eQm5T2uhfhG7/U3COrMS8xOtUrZrp9OgdmzEnIYODye3nY1VqzA==',
      'node_modules/playwright' => 'sha512-Z14dG305dgaLu6foB1TXQagFiW8JfSUIUaUuPaKQ6NtBPKF1P/qXcqfh6c6K/icPqdy37JmjbiBXf6JNg6Sylw==',
      'node_modules/playwright-core' => 'sha512-nsNRyq0r2zsG8AcRHWknc9QRA5XCueC7gWMrs+Gx2tlZn9hcl8zudfh00lhJPY1DE7NmZ6bDsT9g2yey8mXljA=='
    }
  },
  'playwright-mobile' => {
    'app' => 'taurine-mobile', 'config' => 'mobile-playwright-projects', 'version' => '1.62.1',
    'packages' => {
      'node_modules/@playwright/test' => 'sha512-DTcUc8qii+cpHvtOwggMtBRMjKZHXYWdw8syRYu2vtzuq4Wxphqq4NfCs5Zt44L6mA8rfDfj+PHnxFc/FeK6mQ==',
      'node_modules/playwright' => 'sha512-0M+L3LAD8/nm554LOla9Ayx0j0tmFZ0FBcoQ7F1VuVHpM/XpiC8RcDzBQB8W5+hA8L22THxELzeF+2WcUzvcLg==',
      'node_modules/playwright-core' => 'sha512-wPYSwEBJY9GHraISXqyqtx0na0LpO3XEX7jNDhntbex7tzUS7kLnZsOlFruFJB4Hi/rhDMjXGqHewDZ68nYZVw=='
    }
  }
}.freeze
EXPECTED_SCOPES = [
  ['playwright-desktop', 'desktop-playwright-projects', 'smoke', 'feedback', 'taurine-desktop/.case-evidence-fixtures/all-pass.spec.cjs'],
  ['playwright-desktop', 'desktop-playwright-projects', 'critical', 'feedback', 'taurine-desktop/.case-evidence-fixtures/all-pass.spec.cjs'],
  ['playwright-mobile', 'mobile-playwright-projects', 'smoke', 'smoke', 'taurine-mobile/.case-evidence-fixtures/all-pass.spec.cjs'],
  ['playwright-mobile', 'mobile-playwright-projects', 'critical', 'critical', 'taurine-mobile/.case-evidence-fixtures/all-pass.spec.cjs']
].freeze
FIXTURE_FILES = %w[
  all-pass.config.cjs all-pass.spec.cjs
  duplicate-identity.config.cjs duplicate-identity.spec.cjs
  outcomes.config.cjs outcomes.spec.cjs flaky.config.cjs flaky.spec.cjs
  callback-failure-reporter.cjs
].freeze
ERROR_CLASSES = %w[
  arguments_invalid control_checkout_dirty control_identity_invalid fixture_binding_invalid
  fixture_duplicate_missing fixture_outcome_mismatch fixture_scope_mismatch lock_binding_invalid
  node_runtime_invalid parity_blocked private_output_invalid process_output_limit process_timeout
  report_file_invalid report_invalid report_path_invalid report_permissions_invalid report_shape_invalid runner_failed runner_version_mismatch source_checkout_dirty
  source_identity_invalid source_path_invalid source_sha_mismatch expected_sha_invalid control_sha_mismatch tool_binding_invalid
].sort.freeze

def within?(path, root)
  root_real = File.realpath(root)
  path_real = File.realpath(path)
  path_real == root_real || path_real.start_with?(root_real.end_with?(File::SEPARATOR) ? root_real : "#{root_real}#{File::SEPARATOR}")
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
  reject!('node_runtime_invalid')
end

# Keep this process-group, output-cap, and drain-deadline implementation aligned
# with run_bounded in playwright-case-evidence-producer.rb. The existing producer
# is a top-level CLI, so it cannot be required as a library without changing its
# execution semantics; this fixed fixture harness uses the same reviewed boundary.
def run_bounded(argv, chdir:, env:, timeout: PROCESS_TIMEOUT, capture_stdout: false)
  stdout_value = +''
  byte_counts = [0, 0]
  overflow = false
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  child_pid = nil
  completed = false
  status = nil
  Open3.popen3(env, *argv, chdir: chdir, pgroup: true, unsetenv_others: true) do |stdin, stdout, stderr, waiter|
    child_pid = waiter.pid
    stdin.close
    readers = [stdout, stderr].each_with_index.map do |stream, index|
      Thread.new do
        loop do
          chunk = stream.readpartial(16 * 1024)
          byte_counts[index] += chunk.bytesize
          overflow = true if byte_counts[index] > OUTPUT_LIMIT
          stdout_value << chunk if index.zero? && capture_stdout && stdout_value.bytesize < OUTPUT_LIMIT
          break if overflow
        rescue EOFError, IOError
          break
        end
      end
    end
    deadline = started + timeout
    stop_group = lambda do
      Process.kill('TERM', -waiter.pid) rescue nil
      sleep 0.1
      Process.kill('KILL', -waiter.pid) rescue nil
      readers.each(&:kill)
    end
    loop do
      break if waiter.join(0.05)
      if overflow
        stop_group.call
        reject!('process_output_limit')
      end
      next if Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline

      stop_group.call
      reject!('process_timeout')
    end
    until readers.none?(&:alive?)
      if overflow
        stop_group.call
        reject!('process_output_limit')
      end
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        stop_group.call
        reject!('process_timeout')
      end
      readers.each { |reader| reader.join(0.05) }
    end
    reject!('process_output_limit') if overflow || byte_counts.any? { |count| count > OUTPUT_LIMIT }
    status = waiter.value.exitstatus
    completed = true
  end
  [status, stdout_value]
rescue Errno::ENOENT
  reject!('runner_failed')
ensure
  if child_pid && !completed
    Process.kill('TERM', -child_pid) rescue nil
    sleep 0.1
    Process.kill('KILL', -child_pid) rescue nil
  end
end

def git_tool
  tool = resolve_executable('git', ENV.fetch('PATH', ''))
  reject!('source_identity_invalid') if within?(tool, ROOT)
  tool
end

def git_call(tool, *arguments, chdir: ROOT, timeout: 15, capture: true)
  env = { 'PATH' => [File.dirname(tool), '/usr/bin', '/bin'].uniq.join(File::PATH_SEPARATOR),
    'HOME' => Dir.tmpdir, 'GIT_CONFIG_NOSYSTEM' => '1', 'GIT_CONFIG_GLOBAL' => File::NULL,
    'GIT_TERMINAL_PROMPT' => '0' }
  run_bounded([tool, *arguments], chdir: chdir, env: env, timeout: timeout, capture_stdout: capture)
end

def git_head(tool, root, error_code)
  status, output = git_call(tool, '-C', root, 'rev-parse', '--verify', 'HEAD')
  reject!(error_code) unless status == 0 && output.strip.match?(/\A[0-9a-f]{40}\z/)
  output.strip
end

def git_file(tool, root, sha, relative, error_code)
  status, bytes = git_call(tool, '-C', root, 'show', "#{sha}:#{relative}", timeout: 20)
  reject!(error_code) unless status == 0
  bytes
end

def require_clean!(tool, root, error_code)
  status, output = git_call(tool, '-C', root, 'status', '--porcelain=v1', '--untracked-files=all', timeout: 30)
  reject!(error_code) unless status == 0 && output.empty?
end

def validate_manifest!(tool, expected)
  reject!('fixture_binding_invalid') unless File.file?(EXPECTED_PATH) && File.size(EXPECTED_PATH) <= MAX_INPUT_BYTES
  relative = '.github/policy/fixtures/playwright-case-parity/expected-cases.json'
  bytes = File.binread(EXPECTED_PATH)
  reject!('fixture_binding_invalid') unless bytes == git_file(tool, ROOT, expected, relative, 'fixture_binding_invalid')
  data = JSON.parse(bytes)
  reject!('fixture_binding_invalid') unless data.is_a?(Hash) && data['schema_version'] == 1
  bindings = data.fetch('runner_bindings')
  reject!('fixture_binding_invalid') unless bindings.is_a?(Array) && bindings.length == RUNNER_BINDINGS.length
  bindings.each do |binding|
    configured = RUNNER_BINDINGS[binding['runner_id']]
    reject!('fixture_binding_invalid') unless configured && binding.keys.sort == %w[config_id packages runner_id version].sort &&
      binding['config_id'] == configured['config'] && binding['version'] == configured['version'] &&
      binding['packages'] == configured['packages']
  end
  scopes = data.fetch('all_pass').fetch('scopes')
  actual_scopes = scopes.map do |scope|
    reject!('fixture_scope_mismatch') unless scope.is_a?(Hash) &&
      scope.keys.sort == %w[app_file config_id file_suite_title project runner_id tier].sort &&
      scope['file_suite_title'] == File.basename(scope['app_file'].to_s)
    [scope['runner_id'], scope['config_id'], scope['project'], scope['tier'], scope['app_file']]
  end
  reject!('fixture_scope_mismatch') unless actual_scopes == EXPECTED_SCOPES
  cases = data.fetch('all_pass').fetch('cases')
  reject!('fixture_binding_invalid') unless cases.is_a?(Array) && cases.length == 3 &&
    cases.all? { |entry| entry.is_a?(Hash) && entry.keys.sort == %w[describe title].sort &&
      entry['describe'].is_a?(Array) && entry['describe'].length == 2 && entry['title'].is_a?(String) }
  reject!('fixture_binding_invalid') unless data['all_pass']['file'] == 'all-pass.spec.cjs' &&
    data['all_pass']['config'] == 'all-pass.config.cjs' && data['all_pass']['platform'] == 'linux' &&
    data['all_pass']['expected_outcome'] == 'passed'
  duplicate = data.fetch('duplicate_identity')
  expected_duplicate = {
    'config' => 'duplicate-identity.config.cjs', 'file' => 'duplicate-identity.spec.cjs', 'project' => 'smoke',
    'paths' => [
      { 'describe' => ['duplicate group'], 'title' => 'part > leaf' },
      { 'describe' => ['duplicate group > part'], 'title' => 'leaf' }
    ], 'expected_normalized_title' => 'duplicate group > part > leaf',
    'expected_disposition' => 'duplicate_case_identity', 'expected_phase' => 'control_identity_normalization'
  }
  reject!('fixture_binding_invalid') unless duplicate == expected_duplicate
  outcomes = data.fetch('outcomes')
  expected_outcome_configs = [
    { 'config' => 'outcomes.config.cjs', 'file' => 'outcomes.spec.cjs', 'project' => 'smoke', 'retries' => 0,
      'cases' => [
        { 'describe' => ['outcome group'], 'title' => 'expected failure', 'expected_status' => 'failed', 'attempts' => ['failed'], 'aggregate' => 'expected', 'disposition' => 'passed' },
        { 'describe' => ['outcome group'], 'title' => 'unexpected pass', 'expected_status' => 'failed', 'attempts' => ['passed'], 'aggregate' => 'unexpected', 'disposition' => 'blocked' },
        { 'describe' => ['outcome group'], 'title' => 'intentional skip', 'expected_status' => 'skipped', 'attempts' => [], 'aggregate' => 'skipped', 'disposition' => 'blocked' }
      ] },
    { 'config' => 'flaky.config.cjs', 'file' => 'flaky.spec.cjs', 'project' => 'smoke', 'retries' => 1,
      'cases' => [
        { 'describe' => ['flaky group'], 'title' => 'flaky retry', 'expected_status' => 'passed', 'attempts' => %w[failed passed], 'aggregate' => 'flaky', 'disposition' => 'blocked' }
      ] }
  ]
  reject!('fixture_binding_invalid') unless outcomes == expected_outcome_configs
  callback = data.fetch('callback_failure')
  reject!('fixture_binding_invalid') unless callback == { 'reporter' => 'callback-failure-reporter.cjs', 'callback' => 'onBegin',
    'expected_completion_marker' => 'absent', 'expected_disposition' => 'blocked' }
  data
rescue JSON::ParserError, KeyError, TypeError, SystemCallError
  reject!('fixture_binding_invalid')
end

def app_binding!(tool, source_root, source_sha, runner_id)
  binding = RUNNER_BINDINGS.fetch(runner_id)
  app_root = File.realpath(File.join(source_root, binding.fetch('app')))
  reject!('source_path_invalid') unless within?(app_root, source_root)
  relative_lock = "#{binding.fetch('app')}/package-lock.json"
  lock_path = File.join(app_root, 'package-lock.json')
  reject!('lock_binding_invalid') unless File.file?(lock_path) && File.size(lock_path) <= MAX_INPUT_BYTES
  lock_bytes = File.binread(lock_path)
  reject!('lock_binding_invalid') unless lock_bytes == git_file(tool, source_root, source_sha, relative_lock, 'lock_binding_invalid')
  lock = JSON.parse(lock_bytes)
  binding.fetch('packages').each do |package_path, integrity|
    package = lock.fetch('packages').fetch(package_path)
    reject!('lock_binding_invalid') unless package['version'] == binding['version'] && package['integrity'] == integrity
    package_json_path = File.join(app_root, package_path, 'package.json')
    modules_root = File.join(app_root, 'node_modules')
    reject!('tool_binding_invalid') unless within?(package_json_path, modules_root)
    installed = JSON.parse(File.binread(package_json_path))
    reject!('tool_binding_invalid') unless installed['version'] == binding['version']
  end
  cli = File.join(app_root, 'node_modules/playwright/cli.js')
  reject!('tool_binding_invalid') unless File.file?(cli) && within?(cli, File.join(app_root, 'node_modules'))
  [binding, app_root, File.realpath(cli)]
rescue JSON::ParserError, KeyError, SystemCallError
  reject!('lock_binding_invalid')
end

def child_env(node, work, report: nil, completion: nil, json: nil)
  env = { 'PATH' => [File.dirname(node), '/usr/bin', '/bin'].uniq.join(File::PATH_SEPARATOR),
    'HOME' => File.join(work, 'home'), 'TMPDIR' => work, 'CI' => 'true' }
  env['TAURINE_CASE_EVIDENCE_REPORT_PATH'] = report if report
  env['TAURINE_CASE_EVIDENCE_COMPLETION_PATH'] = completion if completion
  env['PLAYWRIGHT_JSON_OUTPUT_NAME'] = json if json
  env
end

def expected_sha!(name, error_code)
  value = ENV[name]
  reject!('expected_sha_invalid') unless value.is_a?(String) && value.match?(/\A[0-9a-f]{40}\z/)
  reject!(error_code) unless value == yield
end

def private_path!(path, root, max_bytes)
  reject!('report_path_invalid') unless path && File.exist?(path) && within?(path, root)
  stat = File.lstat(path)
  reject!('report_file_invalid') unless stat.file?
  reject!('report_permissions_invalid') unless (stat.mode & 0o077).zero?
  reject!('report_file_invalid') unless stat.size <= max_bytes
  JSON.parse(File.binread(path))
rescue JSON::ParserError, SystemCallError
  reject!('report_invalid')
end

def create_private_output(path)
  File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.close }
rescue SystemCallError
  reject!('private_output_invalid')
end

def stage_files!(stage, files, tool, control_sha)
  files.each do |name|
    reject!('fixture_binding_invalid') unless FIXTURE_FILES.include?(name)
    relative = ".github/policy/fixtures/playwright-case-parity/#{name}"
    source = File.join(FIXTURE_DIR, name)
    expected_bytes = git_file(tool, ROOT, control_sha, relative, 'fixture_binding_invalid')
    reject!('fixture_binding_invalid') unless File.file?(source) && File.binread(source) == expected_bytes
    File.open(File.join(stage, name), File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.write(expected_bytes)
      file.flush
      file.fsync
    end
  end
end

def list_rows(report, marker, runner_id, config, tier, platform, project, app_file, stage)
  reject!('report_shape_invalid') unless report.is_a?(Hash) && report.keys.sort == %w[errors suites].sort &&
    report['errors'] == [] && report['suites'].is_a?(Array)
  reject!('report_shape_invalid') unless marker.is_a?(Hash) && marker.keys.sort == %w[count error_class schema_version status].sort &&
    marker['schema_version'] == 1 && marker['status'] == 'complete' && marker['error_class'].nil? &&
    marker['count'].is_a?(Integer) && marker['count'].between?(1, MAX_CASES)
  rows = []
  report['suites'].each do |suite|
    reject!('report_shape_invalid') unless suite.is_a?(Hash) && suite.keys.sort == %w[file specs].sort &&
      suite['file'].is_a?(String) && suite['specs'].is_a?(Array)
    file = File.realpath(suite['file'])
    reject!('report_shape_invalid') unless within?(file, stage) && File.basename(file) == File.basename(app_file)
    suite['specs'].each do |spec|
      reject!('report_shape_invalid') unless spec.is_a?(Hash) && spec.keys.sort == %w[file tests title].sort &&
        spec['title'].is_a?(String) && !spec['title'].empty? && spec['file'] == suite['file'] &&
        spec['tests'].is_a?(Array) && spec['tests'].length == 1
      test = spec['tests'].first
      reject!('report_shape_invalid') unless test.is_a?(Hash) && test.keys.sort == %w[projectName results status].sort &&
        test['projectName'] == project && test['status'] == 'discovered' && test['results'] == []
      rows << [runner_id, config, tier, platform, project, app_file, '', '', spec['title']]
      reject!('report_shape_invalid') if rows.length > MAX_CASES
    end
  end
  reject!('report_shape_invalid') unless marker['count'] == rows.length && rows.length.positive?
  rows
rescue SystemCallError
  reject!('report_shape_invalid')
end

def expected_positive_rows(data, scope)
  data.fetch('all_pass').fetch('cases').map do |entry|
    title = (entry.fetch('describe') + [entry.fetch('title')]).join(' > ')
    [scope.fetch('runner_id'), scope.fetch('config_id'), scope.fetch('tier'), 'linux', scope.fetch('project'),
      scope.fetch('app_file'), '', '', title]
  end
end

def identity_digests(rows)
  rows.map { |row| Digest::SHA256.hexdigest(JSON.generate(row)) }
end

def walk_execution(suites, inherited_file, ancestors, output)
  reject!('report_shape_invalid') unless suites.is_a?(Array)
  suites.each do |suite|
    reject!('report_shape_invalid') unless suite.is_a?(Hash) && suite['title'].is_a?(String)
    suite_file = suite['file'].is_a?(String) ? suite['file'] : inherited_file
    reject!('report_shape_invalid') unless suite_file
    chain = inherited_file && !suite['title'].empty? ? ancestors + [suite['title']] : ancestors
    specs = suite.fetch('specs', [])
    reject!('report_shape_invalid') unless specs.is_a?(Array)
    specs.each do |spec|
      reject!('report_shape_invalid') unless spec.is_a?(Hash) && spec['title'].is_a?(String) && spec['tests'].is_a?(Array)
      file = spec['file'].is_a?(String) ? spec['file'] : suite_file
      spec['tests'].each do |test|
        reject!('report_shape_invalid') unless test.is_a?(Hash) && test['projectName'].is_a?(String) &&
          test['status'].is_a?(String) && test['expectedStatus'].is_a?(String) && test['results'].is_a?(Array)
        title = (chain + [spec['title']]).join(' > ')
        output << { 'title' => title, 'file' => file, 'project' => test['projectName'],
          'status' => test['status'], 'expected_status' => test['expectedStatus'],
          'attempts' => test['results'].map do |result|
            reject!('report_shape_invalid') unless result.is_a?(Hash) && result['status'].is_a?(String)
            result['status']
          end }
        reject!('report_shape_invalid') if output.length > MAX_CASES
      end
    end
    walk_execution(suite.fetch('suites', []), suite_file, chain, output)
  end
end

def execution_cases(report, stage, expected_file, project)
  reject!('report_shape_invalid') unless report.is_a?(Hash) && report['errors'].is_a?(Array) && report['errors'].empty? &&
    report['stats'].is_a?(Hash) && report['suites'].is_a?(Array)
  stats = report.fetch('stats')
  %w[expected skipped unexpected flaky].each do |key|
    reject!('report_shape_invalid') unless stats[key].is_a?(Integer) && stats[key] >= 0
  end
  raw = []
  walk_execution(report.fetch('suites'), nil, [], raw)
  raw.each do |test|
    reject!('report_shape_invalid') unless test['project'] == project && File.realpath(test['file']) == File.realpath(expected_file)
  end
  counts = raw.map do |test|
    case test['status']
    when 'expected', 'passed' then 'expected'
    when 'unexpected', 'failed', 'timedOut', 'interrupted' then 'unexpected'
    when 'flaky' then 'flaky'
    when 'skipped' then 'skipped'
    else reject!('report_shape_invalid')
    end
  end.tally
  reject!('report_shape_invalid') unless %w[expected skipped unexpected flaky].all? { |key| stats[key] == counts.fetch(key, 0) }
  raw
rescue SystemCallError
  reject!('report_shape_invalid')
end

def list_phase(node, cli, app_root, stage, project, report, completion, config_name: 'all-pass.config.cjs', reporter: REPORTER_PATH)
  create_private_output(report) if reporter == REPORTER_PATH
  create_private_output(completion) if reporter == REPORTER_PATH
  env = child_env(node, File.dirname(report), report: report, completion: completion)
  if File.basename(reporter) == 'callback-failure-reporter.cjs'
    sentinel = File.join(File.dirname(report), 'callback-failure.sentinel')
    create_private_output(sentinel)
    env['TAURINE_PARITY_CALLBACK_SENTINEL'] = sentinel
  end
  argv = [node, cli, 'test', '--config', File.join(stage, config_name), '--list', '--project', project,
    '--reporter', reporter]
  run_bounded(argv, chdir: app_root, env: env)
end

def run_all_pass!(node, cli, app_root, stage, scope, data, work)
  project = scope.fetch('project')
  list_path = File.join(work, 'discovery.json')
  marker_path = File.join(work, 'completion.json')
  status, = list_phase(node, cli, app_root, stage, project, list_path, marker_path)
  reject!('runner_failed') unless status == 0
  marker = private_path!(marker_path, work, 4096)
  report = private_path!(list_path, work, MAX_REPORT_BYTES)
  rows = list_rows(report, marker, scope.fetch('runner_id'), scope.fetch('config_id'), scope.fetch('tier'),
    'linux', project, scope.fetch('app_file'), stage)
  expected = expected_positive_rows(data, scope)
  reject!('report_shape_invalid') unless identity_digests(rows).uniq == identity_digests(rows) &&
    identity_digests(rows).sort == identity_digests(expected).sort

  execution_path = File.join(work, 'execution.json')
  create_private_output(execution_path)
  config = File.join(stage, 'all-pass.config.cjs')
  env = child_env(node, work, json: execution_path)
  run_status, = run_bounded([node, cli, 'test', '--config', config, '--project', project, '--reporter', 'json'],
    chdir: app_root, env: env)
  reject!('runner_failed') unless run_status == 0
  report_json = private_path!(execution_path, work, MAX_REPORT_BYTES)
  cases = execution_cases(report_json, stage, File.join(stage, 'all-pass.spec.cjs'), project)
  expected_by_title = expected.to_h { |row| [row.last, row] }
  exec_rows = cases.map do |test|
    title = test.fetch('title')
    expected_row = expected_by_title[title]
    reject!('report_shape_invalid') unless expected_row && test['expected_status'] == 'passed' &&
      %w[expected passed].include?(test['status']) && !test['attempts'].empty? && test['attempts'].all? { |attempt| attempt == 'passed' }
    expected_row
  end
  reject!('report_shape_invalid') unless identity_digests(exec_rows).sort == identity_digests(rows).sort
  rows.length
end

def run_negative_outcomes!(node, cli, app_root, stage, work)
  config = File.join(stage, 'outcomes.config.cjs')
  list = File.join(work, 'negative-discovery.json')
  marker = File.join(work, 'negative-completion.json')
  create_private_output(list)
  create_private_output(marker)
  env = child_env(node, work, report: list, completion: marker)
  status, = run_bounded([node, cli, 'test', '--config', config, '--list', '--project', 'smoke', '--reporter', REPORTER_PATH],
    chdir: app_root, env: env)
  reject!('runner_failed') unless status == 0
  listed = private_path!(list, work, MAX_REPORT_BYTES)
  sentinel = private_path!(marker, work, 4096)
  # Outcome list identities are fixed by the control-owned fixture. The execution
  # JSON is checked separately and never contributes to the positive pass count.
  list_cases = list_rows(listed, sentinel, 'playwright-desktop', 'desktop-playwright-projects', 'feedback', 'linux',
    'smoke', 'taurine-desktop/.case-evidence-fixtures/outcomes.spec.cjs', stage)
  expected_list_titles = [
    'outcome group > expected failure', 'outcome group > unexpected pass', 'outcome group > intentional skip'
  ].sort
  reject!('report_shape_invalid') unless list_cases.map(&:last).sort == expected_list_titles

  execution_path = File.join(work, 'negative-execution.json')
  create_private_output(execution_path)
  run_env = child_env(node, work, json: execution_path)
  run_status, = run_bounded([node, cli, 'test', '--config', config, '--project', 'smoke', '--reporter', 'json'],
    chdir: app_root, env: run_env)
  report = private_path!(execution_path, work, MAX_REPORT_BYTES)
  cases = execution_cases(report, stage, File.join(stage, 'outcomes.spec.cjs'), 'smoke')
  expected_titles = [
    'outcome group > expected failure', 'outcome group > unexpected pass', 'outcome group > intentional skip'
  ].sort
  reject!('fixture_outcome_mismatch') unless cases.length == 3 && cases.map { |test| test.fetch('title') }.sort == expected_titles &&
    cases.map { |test| test.fetch('title') }.uniq.length == 3
  expected_statuses = cases.to_h { |test| [test.fetch('title'), test] }
  expected_failure = expected_statuses.fetch('outcome group > expected failure')
  unexpected_pass = expected_statuses.fetch('outcome group > unexpected pass')
  skipped = expected_statuses.fetch('outcome group > intentional skip')
  reject!('fixture_outcome_mismatch') unless run_status == 1 && expected_failure['status'] == 'expected' &&
    expected_failure['expected_status'] == 'failed' && expected_failure['attempts'] == ['failed'] &&
    unexpected_pass['status'] == 'unexpected' && unexpected_pass['expected_status'] == 'failed' &&
    unexpected_pass['attempts'] == ['passed'] && skipped['status'] == 'skipped' &&
    skipped['expected_status'] == 'skipped' && skipped['attempts'].all? { |attempt| attempt == 'skipped' }

  flaky_execution = File.join(work, 'flaky-execution.json')
  create_private_output(flaky_execution)
  flaky_env = child_env(node, work, json: flaky_execution)
  flaky_status, = run_bounded([node, cli, 'test', '--config', File.join(stage, 'flaky.config.cjs'), '--project', 'smoke', '--reporter', 'json'],
    chdir: app_root, env: flaky_env)
  flaky_report = private_path!(flaky_execution, work, MAX_REPORT_BYTES)
  flaky_cases = execution_cases(flaky_report, stage, File.join(stage, 'flaky.spec.cjs'), 'smoke')
  reject!('fixture_outcome_mismatch') unless flaky_status == 0 && flaky_cases.length == 1 &&
    flaky_cases.first['title'] == 'flaky group > flaky retry' && flaky_cases.first['status'] == 'flaky' &&
    flaky_cases.first['expected_status'] == 'passed' && flaky_cases.first['attempts'] == %w[failed passed]
  4
end

def run_duplicate_block!(node, cli, app_root, stage, work)
  report = File.join(work, 'duplicate-discovery.json')
  marker = File.join(work, 'duplicate-completion.json')
  status, = list_phase(node, cli, app_root, stage, 'smoke', report, marker, config_name: 'duplicate-identity.config.cjs')
  return false unless status == 0 && File.exist?(report) && File.exist?(marker)

  data = private_path!(report, work, MAX_REPORT_BYTES)
  sentinel = private_path!(marker, work, 4096)
  rows = list_rows(data, sentinel, 'playwright-desktop', 'desktop-playwright-projects', 'feedback', 'linux',
    'smoke', 'taurine-desktop/.case-evidence-fixtures/duplicate-identity.spec.cjs', stage)
  expected_title = 'duplicate group > part > leaf'
  return false unless rows.length == 2 && rows.all? { |row| row[4] == 'smoke' && row[8] == expected_title }
  ids = identity_digests(rows)
  ids.uniq.length < ids.length
end

def run_callback_block!(node, cli, app_root, stage, work)
  report = File.join(work, 'callback-report.json')
  marker = File.join(work, 'callback-completion.json')
  status, = list_phase(node, cli, app_root, stage, 'smoke', report, marker,
    reporter: File.join(stage, 'callback-failure-reporter.cjs'))
  sentinel = File.join(work, 'callback-failure.sentinel')
  return false unless [0, 1].include?(status) && File.exist?(sentinel) && !File.exist?(report) && !File.exist?(marker)
  stat = File.lstat(sentinel)
  stat.file? && (stat.mode & 0o077).zero? && stat.size == 'synthetic-onBegin-failure-v1'.bytesize &&
    File.binread(sentinel) == 'synthetic-onBegin-failure-v1'
rescue SystemCallError
  false
end

def safe_output(status:, positive_scopes: 0, positive_cases: 0, negative_checks: 0, expected_checks: 0, blocked_checks: 0, error_class: nil)
  if status == 'shadow_fixture_parity_unverified'
    { 'schema_version' => 1, 'status' => status,
      'positive' => { 'scopes' => positive_scopes, 'cases' => positive_cases },
      'negative' => { 'checks' => negative_checks, 'expected' => expected_checks, 'blocked' => blocked_checks } }
  else
    fixed_error = ERROR_CLASSES.include?(error_class) ? error_class : 'parity_blocked'
    { 'schema_version' => 1, 'status' => 'shadow_fixture_parity_blocked', 'error_class' => fixed_error }
  end
end

begin
  reject!('arguments_invalid') unless ARGV.length == 1
  source_root = File.realpath(ARGV.fetch(0))
  reject!('source_path_invalid') unless File.directory?(source_root) && !within?(source_root, ROOT) && !within?(ROOT, source_root)
  git = git_tool
  control_sha = git_head(git, ROOT, 'control_identity_invalid')
  source_sha = git_head(git, source_root, 'source_identity_invalid')
  reject!('control_identity_invalid') unless control_sha.match?(/\A[0-9a-f]{40}\z/)
  reject!('source_identity_invalid') unless source_sha.match?(/\A[0-9a-f]{40}\z/)
  expected_sha!('TAURINE_PARITY_EXPECTED_CONTROL_SHA', 'control_sha_mismatch') { control_sha }
  expected_sha!('TAURINE_PARITY_EXPECTED_SOURCE_SHA', 'source_sha_mismatch') { source_sha }
  require_clean!(git, ROOT, 'control_checkout_dirty')
  require_clean!(git, source_root, 'source_checkout_dirty')
  data = validate_manifest!(git, control_sha)
  node = resolve_executable('node', ENV.fetch('PATH', ''))
  reject!('node_runtime_invalid') if within?(node, ROOT) || within?(node, source_root)

  positive_cases = 0
  EXPECTED_SCOPES.each_with_index do |scope_row, index|
    runner, config, project, tier, app_file = scope_row
    scope = data.fetch('all_pass').fetch('scopes').fetch(index)
    reject!('fixture_scope_mismatch') unless [scope['runner_id'], scope['config_id'], scope['project'], scope['tier'], scope['app_file']] == scope_row
    binding, app_root, cli = app_binding!(git, source_root, source_sha, runner)
    version_status, version_output = run_bounded([node, cli, '--version'], chdir: app_root,
      env: { 'PATH' => [File.dirname(node), '/usr/bin', '/bin'].uniq.join(File::PATH_SEPARATOR), 'HOME' => Dir.tmpdir },
      timeout: 30, capture_stdout: true)
    reject!('runner_version_mismatch') unless version_status == 0 &&
      [binding['version'], "Version #{binding['version']}"].include?(version_output.strip)
    Dir.mktmpdir('taurine-parity-', app_root) do |stage|
      File.chmod(0o700, stage)
      stage_files!(stage, %w[all-pass.config.cjs all-pass.spec.cjs], git, control_sha)
      Dir.mktmpdir('taurine-parity-reports-', ENV.fetch('RUNNER_TEMP', Dir.tmpdir)) do |work|
        File.chmod(0o700, work)
        Dir.mkdir(File.join(work, 'home'), 0o700)
        positive_cases += run_all_pass!(node, cli, app_root, stage, scope, data, work)
      end
    end
  end
  reject!('fixture_scope_mismatch') unless positive_cases == 12

  negative_scope = data.fetch('all_pass').fetch('scopes').first
  binding, app_root, cli = app_binding!(git, source_root, source_sha, negative_scope.fetch('runner_id'))
  Dir.mktmpdir('taurine-parity-negative-', app_root) do |stage|
    File.chmod(0o700, stage)
    stage_files!(stage, %w[duplicate-identity.config.cjs duplicate-identity.spec.cjs outcomes.config.cjs outcomes.spec.cjs
      flaky.config.cjs flaky.spec.cjs callback-failure-reporter.cjs], git, control_sha)
    Dir.mktmpdir('taurine-parity-negative-reports-', ENV.fetch('RUNNER_TEMP', Dir.tmpdir)) do |work|
      File.chmod(0o700, work)
      Dir.mkdir(File.join(work, 'home'), 0o700)
      outcome_checks = run_negative_outcomes!(node, cli, app_root, stage, work)
      duplicate_blocked = run_duplicate_block!(node, cli, app_root, stage, work)
      callback_blocked = run_callback_block!(node, cli, app_root, stage, work)
      reject!('fixture_duplicate_missing') unless duplicate_blocked
      reject!('fixture_outcome_mismatch') unless callback_blocked
      puts JSON.generate(safe_output(status: 'shadow_fixture_parity_unverified', positive_scopes: EXPECTED_SCOPES.length,
        positive_cases: positive_cases, negative_checks: outcome_checks + 2, expected_checks: 1, blocked_checks: 5))
    end
  end
rescue ParityError => error
  puts JSON.generate(safe_output(status: 'shadow_fixture_parity_blocked', error_class: error.code))
  exit 1
rescue JSON::ParserError, KeyError, TypeError, SystemCallError, ArgumentError, NoMethodError
  puts JSON.generate(safe_output(status: 'shadow_fixture_parity_blocked', error_class: 'parity_blocked'))
  exit 1
rescue StandardError
  puts JSON.generate(safe_output(status: 'shadow_fixture_parity_blocked', error_class: 'parity_blocked'))
  exit 1
end
