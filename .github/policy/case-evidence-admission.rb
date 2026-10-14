#!/usr/bin/env ruby
# Trusted case-evidence producer for the admission path.
#
# This is the activation of the case-evidence contract: it runs inside the
# protected Linux concern job, after the exact source checkout, after the
# source token is revoked and after root is dropped, and it reconciles the
# cases the pinned Playwright runner *discovers* against the cases the concern
# actually *executed*.
#
# It does not run the suite a second time. The reviewed concern command already
# wrote a Playwright JSON execution report to RUNNER_TEMP; this producer adds
# only the discovery half -- one `--list` per project, which starts no browser
# and no web server -- and hands both halves to the unchanged structural
# validator in case-evidence-contract.rb.
#
# Nothing here is selection: no suite is skipped, filtered or sharded on the
# strength of this result, and the full concern matrix stays mandatory. The
# contract's clean status is still `shadow_valid_unverified_producer`, because
# a producer cannot attest its own honesty. What activation changes is that a
# reconciliation *failure* now fails the concern instead of being reported as
# shadow data: a case that was discovered and not executed, a case that was
# executed and never discovered, a duplicate identity, an empty suite, or a
# case belonging to no expected project all block.
#
# Every command, project, tier and path below is fixed in this file. Nothing is
# taken from the source checkout except the pinned runner version (read from
# the app lockfile at the verified source SHA) and the reports themselves.
#
# Usage:
#   ruby case-evidence-admission.rb <concern> <source-root> <execution-report> <work-dir>
#
# Required environment, all produced by the pre-project-code suite-contract step:
#   CI_EXPECTED_SOURCE_SHA, CI_EXPECTED_CONTROL_SHA, CI_EXPECTED_MANIFEST_DIGEST,
#   CI_EXPECTED_CATALOG_DIGEST, CI_EXPECTED_SELECTION_MODE,
#   CI_EXPECTED_SELECTED_SUITE_IDS, CI_PLATFORM
#
# Exit 0 only when every project reconciled exactly. Any other outcome exits 1
# with a fixed error class. Stdout carries only suite-level aggregates.
require 'digest'
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require_relative 'case-evidence-contract'

class AdmissionError < StandardError
  attr_reader :code

  def initialize(code)
    @code = code
    super(code)
  end
end

def block!(code)
  raise AdmissionError, code
end

CONTROL_ROOT = File.expand_path('../..', __dir__).freeze
CONTRACT = File.join(__dir__, 'case-evidence-contract.rb').freeze
REPORTER_RELATIVE = '.github/policy/case-evidence-assets/playwright-case-list-reporter.cjs'.freeze
REPORTER = File.join(CONTROL_ROOT, REPORTER_RELATIVE).freeze
MATRIX_RELATIVE = '.github/ci-matrix.json'.freeze
MANIFEST_RELATIVE = 'scripts/ci/suite-ownership.json'.freeze
MAX_INPUT_BYTES = 8 * 1024 * 1024
MAX_REPORT_BYTES = 64 * 1024 * 1024
MAX_LOCK_BYTES = 8 * 1024 * 1024
OUTPUT_LIMIT = 1 * 1024 * 1024
LIST_TIMEOUT = 300

# The fixed concern-to-scope table. A concern that is not named here is not
# reconciled, and the caller is expected not to invoke this producer for it.
#
# The four `e2e-regression-*` concerns are deliberately absent. 1.62.0 does
# apply `--shard` to `--list`, so a shard job could reconcile its own quarter
# against its own listing. That is a weaker claim than this gate makes
# elsewhere: nothing inside one shard job can show that the four shards
# together ran the whole project. Rather than have one result stand for two
# different claims, those concerns are refused and reported as unreconciled.
SCOPES = {
  'e2e-critical' => { 'app' => 'taurine-desktop', 'runner_id' => 'playwright-desktop',
    'config_id' => 'desktop-playwright-projects', 'tier' => 'feedback',
    'projects' => %w[smoke critical shell-browser] },
  'e2e-a11y' => { 'app' => 'taurine-desktop', 'runner_id' => 'playwright-desktop',
    'config_id' => 'desktop-playwright-projects', 'tier' => 'a11y', 'projects' => %w[a11y] },
  'e2e-visual' => { 'app' => 'taurine-desktop', 'runner_id' => 'playwright-desktop',
    'config_id' => 'desktop-playwright-projects', 'tier' => 'visual', 'projects' => %w[visual] }
}.freeze

# The exact runner this gate was proven against. A lockfile bump is not a
# silent upgrade: the recorded parity evidence, and the report shape every
# identity derivation depends on, are specific to this version, so a different
# one blocks until it has been proven and reviewed. Integrity values are the
# reviewed pins carried by the shadow producer and the parity manifest.
PINNED_RUNNER = {
  'version' => '1.62.0',
  'packages' => {
    'node_modules/@playwright/test' => 'sha512-9zOJ6ZQRAena31MpOH9VSzIz8Ou3YJ/wtY/eQm5T2uhfhG7/U3COrMS8xOtUrZrp9OgdmzEnIYODye3nY1VqzA==',
    'node_modules/playwright' => 'sha512-Z14dG305dgaLu6foB1TXQagFiW8JfSUIUaUuPaKQ6NtBPKF1P/qXcqfh6c6K/icPqdy37JmjbiBXf6JNg6Sylw==',
    'node_modules/playwright-core' => 'sha512-nsNRyq0r2zsG8AcRHWknc9QRA5XCueC7gWMrs+Gx2tlZn9hcl8zudfh00lhJPY1DE7NmZ6bDsT9g2yey8mXljA=='
  }
}.freeze

# Validator classes this producer may repeat verbatim. Anything else is
# reported as contract_rejected rather than echoed.
# The sanitized counts this producer republishes. retried_pass and skipped are
# shown in their own right: a reader of the public summary can see that a case
# needed the retry its project permits, or that the suite skipped it, without
# either being counted as a pass.
REPORTED_COUNTS = %w[discovered executed passed retried_pass skipped].freeze

CONTRACT_ERROR_CLASSES = %w[
  case_collection_empty discovery_execution_mismatch duplicate_case_identity
  report_count_mismatch report_project_mismatch report_shape_invalid report_status_mismatch
  reporter_errors_present selection_mismatch
].freeze

ERROR_CLASSES = (CONTRACT_ERROR_CLASSES + %w[
  catalog_binding_invalid config_binding_invalid control_checkout_invalid control_sha_mismatch
  git_untrusted manifest_absent manifest_binding_invalid project_executed_nothing
  reporter_binding_invalid runner_version_unpinned
  source_checkout_dirty source_sha_mismatch suite_scope_mismatch
  arguments_invalid concern_unsupported contract_rejected discovery_failed
  execution_report_invalid identity_env_invalid lock_binding_invalid node_runtime_invalid
  partition_incomplete process_output_limit process_timeout project_unexpected
  reporter_failed report_path_invalid source_path_invalid stats_mismatch tool_binding_invalid
  work_dir_invalid
]).sort.freeze

def within?(path, root)
  root_real = File.realpath(root)
  path_real = File.realpath(path)
  path_real == root_real || path_real.start_with?("#{root_real}#{File::SEPARATOR}")
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
  block!('node_runtime_invalid')
end

# Same process-group, output-cap and drain-deadline boundary as the reviewed
# producers: one deadline covers the child and its pipes, and the whole group
# is terminated before this method returns.
def run_bounded(argv, chdir:, env:, timeout: LIST_TIMEOUT)
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
        block!('process_output_limit')
      end
      next if Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline

      stop_group.call
      block!('process_timeout')
    end
    until readers.none?(&:alive?)
      if overflow
        stop_group.call
        block!('process_output_limit')
      end
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        stop_group.call
        block!('process_timeout')
      end
      readers.each { |reader| reader.join(0.05) }
    end
    block!('process_output_limit') if overflow || byte_counts.any? { |count| count > OUTPUT_LIMIT }
    status = waiter.value.exitstatus
    completed = true
  end
  status
rescue Errno::ENOENT
  block!('discovery_failed')
ensure
  if child_pid && !completed
    Process.kill('TERM', -child_pid) rescue nil
    sleep 0.1
    Process.kill('KILL', -child_pid) rescue nil
  end
end

# Git is resolved outside both checkouts, so neither the source nor the control
# tree can supply the binary that verifies it. Same rule as the reviewed shadow
# producer in playwright-case-evidence-producer.rb.
def git_tool
  tool = resolve_executable('git', ENV.fetch('PATH', ''))
  block!('git_untrusted') if within?(tool, CONTROL_ROOT)
  tool
end

def git_env(tool)
  { 'PATH' => [File.dirname(tool), '/usr/bin', '/bin'].uniq.join(File::PATH_SEPARATOR), 'HOME' => Dir.tmpdir,
    'GIT_CONFIG_NOSYSTEM' => '1', 'GIT_CONFIG_GLOBAL' => File::NULL, 'GIT_TERMINAL_PROMPT' => '0' }
end

def git_capture(tool, root, arguments, code, timeout: 30)
  stdout, _stderr, status = Open3.capture3(git_env(tool), tool, '-C', root, *arguments, unsetenv_others: true)
  block!(code) unless status.exitstatus.zero?
  stdout
rescue SystemCallError
  block!(code)
end

def git_head!(tool, root, code)
  head = git_capture(tool, root, ['rev-parse', '--verify', 'HEAD'], code).strip
  block!(code) unless head.match?(/\A[0-9a-f]{40}\z/)
  head
end

def git_file!(tool, root, revision, relative, code)
  git_capture(tool, root, ['show', "#{revision}:#{relative}"], code)
end

def require_clean!(tool, root, code)
  block!(code) unless git_capture(tool, root, ['status', '--porcelain=v1', '--untracked-files=all'], code).empty?
end

def tracked_bytes!(tool, root, revision, relative, code)
  path = File.join(root, relative)
  block!(code) unless File.file?(path) && File.size(path) <= MAX_INPUT_BYTES && within?(path, root)
  bytes = File.binread(path)
  block!(code) unless bytes == git_file!(tool, root, revision, relative, code)
  bytes
end

def sha40!(name)
  value = ENV[name]
  block!('identity_env_invalid') unless value.is_a?(String) && value.match?(/\A[0-9a-f]{40}\z/)
  value
end

def sha256!(name)
  value = ENV[name]
  block!('identity_env_invalid') unless value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/)
  value
end

def selected_suite_ids!
  value = JSON.parse(ENV.fetch('CI_EXPECTED_SELECTED_SUITE_IDS', ''))
  block!('identity_env_invalid') unless value.is_a?(Array) && !value.empty? && value.uniq == value &&
    value.all? { |id| id.is_a?(String) && id.match?(/\A[a-z0-9.-]+\z/) }
  value
rescue JSON::ParserError
  block!('identity_env_invalid')
end

# The runner is pinned, not merely read. The lockfile is compared byte for byte
# against the source commit under test, each of the three packages must carry
# the reviewed version and integrity, and the package actually installed in the
# app must be that same version. A lockfile bump therefore blocks with
# runner_version_unpinned instead of quietly running this gate against a report
# shape nothing has proven.
def pinned_tool_version!(tool, app_root, source_root, source_sha, app)
  lock_bytes = tracked_bytes!(tool, source_root, source_sha, "#{app}/package-lock.json", 'lock_binding_invalid')
  lock = JSON.parse(lock_bytes)
  packages = lock.fetch('packages')
  PINNED_RUNNER.fetch('packages').each do |name, integrity|
    entry = packages.fetch(name)
    block!('runner_version_unpinned') unless entry['version'] == PINNED_RUNNER.fetch('version') &&
      entry['integrity'] == integrity
    installed = File.join(app_root, name, 'package.json')
    block!('tool_binding_invalid') unless File.file?(installed) && within?(installed, File.join(app_root, 'node_modules'))
    block!('tool_binding_invalid') unless JSON.parse(File.binread(installed))['version'] == PINNED_RUNNER.fetch('version')
  end
  PINNED_RUNNER.fetch('version')
rescue JSON::ParserError, KeyError, SystemCallError
  block!('lock_binding_invalid')
end

def sort_json(value)
  case value
  when Hash then value.keys.sort.each_with_object({}) { |key, result| result[key] = sort_json(value.fetch(key)) }
  when Array then value.map { |item| sort_json(item) }
  else value
  end
end

# The same canonical digest suite-contract.rb computes, so recomputing here
# either reproduces the value that step published or blocks.
def canonical_digest(value)
  Digest::SHA256.hexdigest(JSON.generate(sort_json(value), ascii_only: true))
end

def private_json!(path, root, limit)
  block!('report_path_invalid') unless File.exist?(path) && within?(path, root)
  stat = File.lstat(path)
  block!('report_path_invalid') unless stat.file? && (stat.mode & 0o077).zero? && stat.size <= limit
  JSON.parse(File.binread(path))
rescue JSON::ParserError, SystemCallError
  block!('report_path_invalid')
end

def create_private_file(path)
  File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.close }
rescue SystemCallError
  block!('work_dir_invalid')
end

def write_private_json(path, value)
  File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
    file.write(JSON.generate(value))
    file.flush
    file.fsync
  end
rescue SystemCallError
  block!('work_dir_invalid')
end

def child_env(node, work, report: nil, completion: nil)
  env = { 'PATH' => [File.dirname(node), '/usr/bin', '/bin'].uniq.join(File::PATH_SEPARATOR),
    'HOME' => File.join(work, 'home'), 'TMPDIR' => work, 'CI' => 'true' }
  env['TAURINE_CASE_EVIDENCE_REPORT_PATH'] = report if report
  env['TAURINE_CASE_EVIDENCE_COMPLETION_PATH'] = completion if completion
  browsers = ENV['PLAYWRIGHT_BROWSERS_PATH']
  if browsers.is_a?(String) && File.directory?(browsers) && File.basename(browsers) == 'ms-playwright'
    env['PLAYWRIGHT_BROWSERS_PATH'] = browsers
  end
  env
end

# Keep only the tests of one project, preserving the suite nesting so the title
# chain the validator rebuilds is the one the runner reported. Suites and specs
# left with nothing are dropped. `stats` is deliberately not carried into a
# partition -- it counts the whole concern -- and is reconciled separately
# against the union of the partitions.
def partition(node, project)
  specs = node.fetch('specs', []).map do |spec|
    block!('execution_report_invalid') unless spec.is_a?(Hash) && spec['tests'].is_a?(Array)
    tests = spec['tests'].select do |test|
      block!('execution_report_invalid') unless test.is_a?(Hash) && test['projectName'].is_a?(String)
      test['projectName'] == project
    end
    tests.empty? ? nil : spec.merge('tests' => tests)
  end.compact
  children = node.fetch('suites', []).map do |child|
    block!('execution_report_invalid') unless child.is_a?(Hash)
    partition(child, project)
  end.compact
  return nil if specs.empty? && children.empty?

  result = node.reject { |key, _| %w[specs suites].include?(key) }
  result['specs'] = specs unless specs.empty?
  result['suites'] = children unless children.empty?
  result
end

def project_names(node, seen)
  node.fetch('specs', []).each do |spec|
    block!('execution_report_invalid') unless spec.is_a?(Hash) && spec['tests'].is_a?(Array)
    spec['tests'].each do |test|
      block!('execution_report_invalid') unless test.is_a?(Hash) && test['projectName'].is_a?(String)
      seen << test['projectName']
    end
  end
  node.fetch('suites', []).each do |child|
    block!('execution_report_invalid') unless child.is_a?(Hash)
    project_names(child, seen)
  end
  seen
end

def envelope(expected, phase, report, command_id, discovered_ids: nil)
  base = {
    'schema_version' => 1, 'phase' => phase,
    'source_sha' => expected.fetch('source_sha'), 'control_sha' => expected.fetch('control_sha'),
    'manifest_digest' => expected.fetch('manifest_digest'), 'catalog_digest' => expected.fetch('catalog_digest'),
    'selection_digest' => expected.fetch('selection_digest'), 'collection_complete' => true,
    'collection_digest' => json_digest(report), 'runner_id' => expected.fetch('runner_id'),
    'config_id' => expected.fetch('config_id'), 'tier' => expected.fetch('tier'),
    'platform' => expected.fetch('platform'), 'report' => report,
    'producer_version' => PRODUCER_VERSION, 'command_id' => command_id,
    'tool_version' => expected.fetch('tool_version'), 'producer_status' => 'complete'
  }
  return base if phase == 'discovery'

  base.merge('selected_suite_ids' => expected.fetch('selected_suite_ids'), 'discovered_case_ids' => discovered_ids)
end

def discover!(node, cli, app_root, work, project, reporter)
  report_path = File.join(work, "discovery-#{project}.json")
  marker_path = File.join(work, "completion-#{project}.json")
  create_private_file(report_path)
  create_private_file(marker_path)
  argv = [node, cli, 'test', '--config', 'playwright.config.ts', '--list', '--project', project,
    '--reporter', reporter]
  status = run_bounded(argv, chdir: app_root, env: child_env(node, work, report: report_path, completion: marker_path))
  block!('discovery_failed') unless status == 0
  marker = private_json!(marker_path, work, 4096)
  block!('reporter_failed') unless marker.is_a?(Hash) && marker.keys.sort == %w[count error_class schema_version status] &&
    marker['schema_version'] == 1 && marker['status'] == 'complete' && marker['error_class'].nil? &&
    marker['count'].is_a?(Integer) && marker['count'].positive?
  [private_json!(report_path, work, MAX_REPORT_BYTES), marker.fetch('count')]
end

# The contract is re-run as its own process so it parses both envelopes from
# disk and derives every identity again, independently of the values this
# producer computed.
def reconcile!(expected_path, discovery_path, execution_path)
  ruby = File.join(RbConfig::CONFIG.fetch('bindir'), RbConfig::CONFIG.fetch('ruby_install_name'))
  stdout, _stderr, status = Open3.capture3(ruby, CONTRACT, expected_path, discovery_path, execution_path,
    unsetenv_others: true)
  result = JSON.parse(stdout)
  return result if status.exitstatus.zero? && result['status'] == 'shadow_valid_unverified_producer'

  # Surface the validator's own class. A case discovered but never executed, a
  # duplicate identity and an empty suite are different findings, and folding
  # them into one `contract_rejected` left a public reader unable to tell a
  # parity failure from anything else.
  reported = result['error_class']
  block!(CONTRACT_ERROR_CLASSES.include?(reported) ? reported : 'contract_rejected')
rescue JSON::ParserError, SystemCallError
  block!('contract_rejected')
end

def emit(status:, concern:, projects: [], counts: {}, error_class: nil)
  if status == 'ok'
    { 'schema_version' => 1, 'status' => 'case_evidence_reconciled', 'concern' => concern,
      'projects' => projects, 'counts' => counts }
  else
    fixed = ERROR_CLASSES.include?(error_class) ? error_class : 'contract_rejected'
    { 'schema_version' => 1, 'status' => 'case_evidence_blocked', 'concern' => concern, 'error_class' => fixed }
  end
end

concern_name = ARGV.fetch(0, '')
begin
  block!('arguments_invalid') unless ARGV.length == 4
  concern, source_argument, execution_argument, work_argument = ARGV
  scope = SCOPES[concern]
  block!('concern_unsupported') unless scope

  source_root = File.realpath(source_argument)
  block!('source_path_invalid') unless File.directory?(source_root) && !within?(source_root, CONTROL_ROOT) &&
    !within?(CONTROL_ROOT, source_root)
  work = File.realpath(work_argument)
  block!('work_dir_invalid') unless File.directory?(work) && !within?(work, source_root) &&
    !within?(work, CONTROL_ROOT) && (File.stat(work).mode & 0o077).zero?
  Dir.mkdir(File.join(work, 'home'), 0o700) unless File.directory?(File.join(work, 'home'))

  app_root = File.realpath(File.join(source_root, scope.fetch('app')))
  block!('source_path_invalid') unless within?(app_root, source_root)
  block!('source_path_invalid') unless File.file?(File.join(app_root, 'playwright.config.ts'))
  cli = File.join(app_root, 'node_modules/playwright/cli.js')
  block!('tool_binding_invalid') unless File.file?(cli) && within?(cli, File.join(app_root, 'node_modules'))
  cli = File.realpath(cli)

  node = resolve_executable('node', ENV.fetch('PATH', ''))
  block!('node_runtime_invalid') if within?(node, CONTROL_ROOT) || within?(node, source_root)

  selected_ids = selected_suite_ids!
  source_sha = sha40!('CI_EXPECTED_SOURCE_SHA')
  control_sha = sha40!('CI_EXPECTED_CONTROL_SHA')

  # The identities this gate runs under are checked against git, not taken on
  # the word of the step that passed them in. Without this the expected file
  # and the envelopes are built from one set of environment values and compared
  # against each other, which proves nothing.
  git = git_tool
  block!('source_sha_mismatch') unless git_head!(git, source_root, 'source_sha_mismatch') == source_sha
  block!('control_sha_mismatch') unless git_head!(git, CONTROL_ROOT, 'control_checkout_invalid') == control_sha
  require_clean!(git, source_root, 'source_checkout_dirty')

  # F4: a missing ownership manifest must not quietly disable this gate. The
  # manifest is source-owned, so deleting it would otherwise skip the step.
  manifest_digest = ENV['CI_EXPECTED_MANIFEST_DIGEST'].to_s
  block!('manifest_absent') if manifest_digest.empty?
  block!('identity_env_invalid') unless manifest_digest.match?(/\A[0-9a-f]{64}\z/)

  matrix_bytes = tracked_bytes!(git, CONTROL_ROOT, control_sha, MATRIX_RELATIVE, 'catalog_binding_invalid')
  catalog = JSON.parse(matrix_bytes).fetch('suite_catalog')
  catalog_digest = sha256!('CI_EXPECTED_CATALOG_DIGEST')
  block!('catalog_binding_invalid') unless canonical_digest(catalog) == catalog_digest

  manifest_bytes = tracked_bytes!(git, source_root, source_sha, MANIFEST_RELATIVE, 'manifest_binding_invalid')
  block!('manifest_binding_invalid') unless canonical_digest(JSON.parse(manifest_bytes)) == manifest_digest

  tracked_bytes!(git, source_root, source_sha, "#{scope.fetch('app')}/playwright.config.ts", 'config_binding_invalid')
  tool_version = pinned_tool_version!(git, app_root, source_root, source_sha, scope.fetch('app'))

  # The selected suites must be the reviewed candidate set of exactly one
  # coverage group for this runner, config, tier, platform and project set.
  suite_prefix = "#{scope.fetch('app').delete_prefix('taurine-')}.playwright.#{scope.fetch('tier')}."
  block!('suite_scope_mismatch') unless selected_ids.all? { |id| id.start_with?(suite_prefix) }
  groups = catalog.fetch('coverage_requirements')
  block!('catalog_binding_invalid') unless groups.is_a?(Array)
  matching = groups.select do |group|
    group.is_a?(Hash) && group['runner'] == scope.fetch('runner_id') && group['config'] == scope.fetch('config_id') &&
      group['tier'] == scope.fetch('tier') && group['platforms'].is_a?(Array) && group['platforms'].include?('linux') &&
      group['projects'].is_a?(Array) && group['projects'].sort == scope.fetch('projects').sort
  end
  block!('suite_scope_mismatch') unless matching.length == 1 &&
    matching.first['candidate_suite_ids'].is_a?(Array) &&
    matching.first['candidate_suite_ids'].sort == selected_ids.sort

  expected_base = {
    'schema_version' => 1,
    'source_sha' => source_sha, 'control_sha' => control_sha,
    'manifest_digest' => manifest_digest, 'catalog_digest' => catalog_digest,
    'selection_digest' => canonical_selected_digest(selected_ids),
    'selection_mode' => ENV['CI_EXPECTED_SELECTION_MODE'], 'selected_suite_ids' => selected_ids,
    'runner_id' => scope.fetch('runner_id'), 'config_id' => scope.fetch('config_id'),
    'tier' => scope.fetch('tier'), 'platform' => ENV['CI_PLATFORM'],
    'tool_version' => tool_version, 'repo_root' => source_root
  }.freeze
  block!('identity_env_invalid') unless %w[full shadow].include?(expected_base['selection_mode']) &&
    expected_base['platform'] == 'linux'

  execution_path = File.realpath(execution_argument)
  block!('execution_report_invalid') unless File.file?(execution_path) && File.size(execution_path) <= MAX_REPORT_BYTES
  execution_report = JSON.parse(File.binread(execution_path))
  block!('execution_report_invalid') unless execution_report.is_a?(Hash) && execution_report['suites'].is_a?(Array) &&
    !execution_report['suites'].empty?

  # Completeness, before any reconciliation: every executed case must belong to
  # one of this concern's reviewed projects, so partitioning cannot quietly
  # drop a case that no project owns.
  observed = execution_report['suites'].each_with_object([]) { |suite, seen| project_names(suite, seen) }
  block!('execution_report_invalid') if observed.empty?
  unexpected = observed.uniq - scope.fetch('projects')
  block!('project_unexpected') unless unexpected.empty?

  # The reporter is loaded by Playwright inside the concern job, so its bytes
  # are bound to the verified control commit like every other asset here --
  # existing on disk is not the same as being the reviewed file.
  tracked_bytes!(git, CONTROL_ROOT, control_sha, REPORTER_RELATIVE, 'reporter_binding_invalid')
  reporter = REPORTER
  totals = Hash.new(0)
  per_project = []

  scope.fetch('projects').each do |project|
    discovery_report, marker_count = discover!(node, cli, app_root, work, project, reporter)
    expected = expected_base.merge('project' => project)
    discovered_cases = playwright_cases(discovery_report, 'discovery', expected.fetch('runner_id'),
      expected.fetch('config_id'), expected.fetch('tier'), expected.fetch('platform'),
      expected.fetch('repo_root'), project)
    block!('reporter_failed') unless discovered_cases.length == marker_count

    partitioned = execution_report['suites'].map { |suite| partition(suite, project) }.compact
    block!('partition_incomplete') if partitioned.empty?
    execution_slice = { 'suites' => partitioned, 'errors' => execution_report.fetch('errors', []) }

    expected_path = File.join(work, "expected-#{project}.json")
    discovery_path = File.join(work, "discovery-envelope-#{project}.json")
    execution_envelope_path = File.join(work, "execution-envelope-#{project}.json")
    write_private_json(expected_path, expected)
    write_private_json(discovery_path, envelope(expected, 'discovery', discovery_report,
      "playwright.desktop.list.#{project}.v1"))
    write_private_json(execution_envelope_path, envelope(expected, 'execution', execution_slice,
      "playwright.desktop.run.#{project}.v1",
      discovered_ids: discovered_cases.map { |item| item.fetch('case_id') }))

    result = reconcile!(expected_path, discovery_path, execution_envelope_path)
    counts = result.fetch('counts')
    # Every case skipped is not a green project. Reconciliation would hold
    # perfectly -- discovery and execution agree on a set that ran nothing --
    # and that is the vacuous pass this gate exists to refuse elsewhere.
    block!('project_executed_nothing') unless counts.fetch('passed') + counts.fetch('retried_pass') > 0
    REPORTED_COUNTS.each { |key| totals[key] += counts.fetch(key) }
    per_project << REPORTED_COUNTS.each_with_object({ 'project' => project }) do |key, row|
      row[key] = counts.fetch(key)
    end
  end

  # The partitions must account for the whole report: the concern's own stats,
  # where the runner supplied them, equal the union of what was reconciled.
  stats = execution_report['stats']
  if stats.is_a?(Hash) && %w[expected skipped unexpected flaky].all? { |key| stats[key].is_a?(Integer) }
    block!('stats_mismatch') unless stats.values_at('expected', 'skipped', 'unexpected', 'flaky').sum == totals['executed']
  end
  block!('partition_incomplete') unless totals['executed'] == totals['discovered']
  # A retried pass and a deliberate skip are reported, never folded into passed.
  block!('partition_incomplete') unless totals['passed'] + totals['retried_pass'] + totals['skipped'] == totals['executed']

  puts JSON.generate(emit(status: 'ok', concern: concern, projects: per_project,
    counts: REPORTED_COUNTS.to_h { |key| [key, totals[key]] }))
rescue AdmissionError => error
  puts JSON.generate(emit(status: 'blocked', concern: concern_name, error_class: error.code))
  exit 1
rescue ContractError => error
  puts JSON.generate(emit(status: 'blocked', concern: concern_name, error_class: 'contract_rejected'))
  exit 1
rescue JSON::ParserError, KeyError, TypeError, SystemCallError, ArgumentError, NoMethodError
  puts JSON.generate(emit(status: 'blocked', concern: concern_name, error_class: 'execution_report_invalid'))
  exit 1
end
