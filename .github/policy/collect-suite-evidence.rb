#!/usr/bin/env ruby
# Trusted suite-evidence collector for one concern job.
#
# Produces the suite proof the sanitized validator accepts, from sources the
# control plane itself reviewed: the public catalog, the runner reports the
# reviewed concern commands were told to write, and the private ownership
# manifest checked out at the exact SHA. It never trusts a private script's
# claims about counts: every count is derived here, on the runner, from the
# reporter's own machine-readable output. Only reviewed fields (suite IDs,
# counts, fixed status and error classes, digests, SHAs) leave this script;
# report entries, paths, patterns and titles stay in RUNNER_TEMP.
#
# Usage:
#   ruby collect-suite-evidence.rb <concern> <repo-root> <report-path> <raw-proof-path> <projection-path>
#
# Required environment (produced by the pre-project-code suite-contract step):
#   CI_EXPECTED_SOURCE_SHA, CI_EXPECTED_CONTROL_SHA, CI_EXPECTED_MANIFEST_DIGEST,
#   CI_EXPECTED_CATALOG_DIGEST, CI_EXPECTED_SELECTION_DIGEST,
#   CI_EXPECTED_SELECTION_MODE, CI_EXPECTED_COVERAGE_REQUIREMENT_ID,
#   CI_EXPECTED_SELECTED_SUITE_IDS, CI_PLATFORM
# plus the validator's own CI_EXPECTED_* contract, which this script inherits.
#
# Exit codes: 0 = a validated projection was written (any status, including
# blocked); 1 = no valid evidence could be produced (fail closed); the caller
# decides whether that fails the job.
require 'digest'
require 'json'

class CollectionError < StandardError; end

def reject_collection!(code)
  raise CollectionError, code
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

# Glob with reviewable semantics: `**` crosses directory separators, `*` stays
# within one segment, everything else is literal. No character classes, no
# brace expansion.
def glob_regex(glob)
  source = glob.split('**', -1).map do |segment|
    segment.gsub('*', '[^/]*').gsub('.', '\.')
  end.join('.*')
  Regexp.new("\\A#{source}\\z")
end

def matches_include?(patterns, relative_path)
  patterns.any? do |glob|
    raise CollectionError, 'manifest_glob' unless glob.is_a?(String) && !glob.empty? && glob.ascii_only?
    regex = glob_regex(glob)
    regex.match?(relative_path)
  end
end

# Report entry paths are normalized to be relative to the source root before
# matching: absolute runner paths lose the repo-root prefix, backslashes become
# slashes, and a leading ./ is dropped. Nothing else is rewritten.
def normalize_entry_path(path, repo_root)
  reject_collection!('report_path') unless path.is_a?(String) && !path.empty?
  normalized = path.tr('\\', '/')
  prefix = "#{repo_root.chomp('/')}/"
  normalized = normalized.delete_prefix(prefix) if normalized.start_with?(prefix)
  normalized = normalized.delete_prefix('./')
  reject_collection!('report_path') if normalized.start_with?('/')
  normalized
end

# The vitest JSON reporter (jest-compatible): testResults[].name is the test
# file path, assertionResults[].status one of passed/failed/skipped/pending/
# todo/disabled. The reporter's own totals must agree with the parsed entries
# before anything is counted.
def parse_vitest_report(report)
  reject_collection!('report_shape') unless report.is_a?(Hash) && report['testResults'].is_a?(Array)
  entries = []
  report['testResults'].each do |result|
    reject_collection!('report_shape') unless result.is_a?(Hash)
    path = result['name']
    assertions = result['assertionResults']
    reject_collection!('report_shape') unless path.is_a?(String) && assertions.is_a?(Array)
    assertions.each do |assertion|
      reject_collection!('report_shape') unless assertion.is_a?(Hash)
      status = assertion['status']
      reject_collection!('report_case_status') unless %w[passed failed skipped pending todo disabled].include?(status)
      entries << { 'path' => path, 'status' => status }
    end
  end
  total = report['numTotalTests']
  reject_collection!('report_totals') unless total.is_a?(Integer) && total == entries.length
  entries
end

# The Playwright JSON reporter: a nested suites tree whose leaf specs carry the
# file and one tests[] entry per configured project. Each test's status is
# expected/unexpected/flaky/skipped; flaky means it passed only on retry, which
# is quarantine evidence, never a clean pass.
def parse_playwright_report(report)
  reject_collection!('report_shape') unless report.is_a?(Hash) && report['suites'].is_a?(Array)
  entries = []
  walk = lambda do |suite, project|
    reject_collection!('report_shape') unless suite.is_a?(Hash)
    project = suite['projectName'] if project.nil? && suite['projectName'].is_a?(String)
    if suite['specs'].is_a?(Array)
      suite['specs'].each do |spec|
        reject_collection!('report_shape') unless spec.is_a?(Hash) && spec['tests'].is_a?(Array)
        file = spec['file'] || suite['file']
        reject_collection!('report_shape') unless file.is_a?(String)
        spec['tests'].each do |test|
          reject_collection!('report_shape') unless test.is_a?(Hash)
          status = test['status']
          name = test['projectName'] || test['projectId'] || project
          reject_collection!('report_case_status') unless %w[expected unexpected flaky skipped].include?(status)
          entries << { 'path' => file, 'status' => status, 'project' => name.is_a?(String) ? name : '' }
        end
      end
    end
    (suite['suites'] || []).each { |child| walk.call(child, project) }
  end
  report['suites'].each { |suite| walk.call(suite, nil) }
  entries
end

# Reviewed runner adapters. A coverage group whose runner has no adapter here
# cannot produce evidence: the collector refuses rather than guessing.
# The Playwright reporter writes spec files relative to the app directory the
# reviewed composite runs it from (linux-concern-e2e `cd taurine-desktop`), so
# the adapter normalizes them to repo-relative paths, the same terms every
# manifest pattern is written in.
ADAPTERS = {
  'vitest-desktop' => method(:parse_vitest_report),
  'vitest-mobile' => method(:parse_vitest_report),
  'vitest-shared' => method(:parse_vitest_report),
  'playwright-desktop' => method(:parse_playwright_report)
}.freeze
ADAPTER_PATH_PREFIXES = {
  'playwright-desktop' => 'taurine-desktop/'
}.freeze

# Reporter case status -> reviewed evidence count bucket. Executed counts both
# passed and failed cases: running and failing is execution; ignored is a
# statically excluded case; env_skipped a runtime skip; quarantined a flaky
# pass on retry.
CASE_BUCKETS = {
  'passed' => 'executed_count', 'expected' => 'executed_count',
  'failed' => 'executed_count', 'unexpected' => 'executed_count',
  'skipped' => 'env_skipped_count', 'pending' => 'env_skipped_count',
  'todo' => 'ignored_count', 'disabled' => 'ignored_count',
  'flaky' => 'quarantined_count'
}.freeze

def blank_counts
  { 'discovered_count' => 0, 'owned_count' => 0, 'executed_count' => 0,
    'ignored_count' => 0, 'quarantined_count' => 0, 'env_skipped_count' => 0,
    'compiled_count' => 0 }
end

begin
  concern, repo_root, report_path, raw_path, projection_path = ARGV
  reject_collection!('arguments') unless concern && repo_root && raw_path && projection_path

  matrix_path = ENV.fetch('CI_MATRIX_PATH', '.github/ci-matrix.json')
  matrix = JSON.parse(File.read(matrix_path))
  catalog = matrix.fetch('suite_catalog')

  # Exactly one supported coverage group may bind this concern; the reviewed
  # catalog is the only source of the group's runner, tier, projects and
  # candidate suites.
  groups = catalog.fetch('coverage_requirements').select do |row|
    row.is_a?(Hash) && row['availability'] == 'supported' && row['concerns'].is_a?(Array) && row['concerns'].include?(concern)
  end
  reject_collection!('coverage_group') unless groups.length == 1
  group = groups.first
  runner = group.fetch('runner')
  adapter = ADAPTERS.fetch(runner) { reject_collection!('runner_adapter') }
  candidates = group.fetch('candidate_suite_ids')
  projects = group.fetch('projects')
  platform = ENV.fetch('CI_PLATFORM')
  reject_collection!('platform') unless group.fetch('platforms').include?(platform)

  manifest = JSON.parse(File.read(File.join(repo_root, 'scripts/ci/suite-ownership.json')))
  reject_collection!('manifest_shape') unless manifest.is_a?(Hash) && manifest['suites'].is_a?(Hash)
  # Canonical-JSON digest (see suite-contract.rb): never cross-compare with the
  # private audit's raw-byte digest of ci/feature-suites.json.
  manifest_digest = canonical_digest(manifest)
  ownership = manifest.fetch('suites')

  expected_selected = JSON.parse(ENV.fetch('CI_EXPECTED_SELECTED_SUITE_IDS'))
  reject_collection!('selection') unless expected_selected.is_a?(Array)
  selected = candidates.select { |id| expected_selected.include?(id) }
  mode = ENV.fetch('CI_EXPECTED_SELECTION_MODE')

  # The runner report is the only execution source. Its absence is reported as
  # "not collected" (exit 0, fixed line): the concern's own verdict already
  # covers the failure, and no evidence may be invented for it.
  unless File.file?(report_path)
    warn 'suite evidence: not collected (the concern produced no runner report)'
    exit 0
  end
  report = JSON.parse(File.read(report_path))
  entries = adapter.call(report)
  if (prefix = ADAPTER_PATH_PREFIXES[runner])
    entries.each { |entry| entry['path'] = prefix + entry['path'] }
  end

  rows = candidates.to_h { |id| [id, blank_counts.merge('statuses' => [])] }
  entries.each do |entry|
    relative = normalize_entry_path(entry.fetch('path'), repo_root)
    if projects.any? && entry['project'] && !projects.include?(entry['project'])
      reject_collection!('filter_mismatch')
    end
    owners = candidates.select do |id|
      record = ownership.fetch(id, nil)
      record.is_a?(Hash) && record['include'].is_a?(Array) &&
        matches_include?(record['include'], relative)
    end
    # Every executed case belongs to exactly one primary suite of this group.
    # A case matching nothing is an unowned test (fail closed); a case matching
    # two suites is an ownership overlap (fail closed).
    reject_collection!('ownership_unowned') if owners.empty?
    reject_collection!('ownership_overlap') if owners.length > 1
    row = rows.fetch(owners.first)
    row['discovered_count'] += 1
    row['owned_count'] += 1
    row[CASE_BUCKETS.fetch(entry.fetch('status'))] += 1
    row['statuses'] << entry.fetch('status')
  end

  suite_rows = candidates.map do |id|
    row = rows.fetch(id)
    status, error_class =
      if row['statuses'].include?('failed') || row['statuses'].include?('unexpected')
        ['failed', 'test_failure']
      elsif row['quarantined_count'].positive?
        ['blocked', 'quarantined_cases']
      elsif row['env_skipped_count'].positive?
        ['blocked', 'environment_skip']
      elsif row['ignored_count'].positive?
        ['blocked', 'ignored_cases']
      elsif row['executed_count'].positive?
        ['passed', 'none']
      else
        ['absent', 'none']
      end
    {
      'id' => id, 'discovered_count' => row['discovered_count'],
      'owned_count' => row['owned_count'], 'executed_count' => row['executed_count'],
      'ignored_count' => row['ignored_count'], 'quarantined_count' => row['quarantined_count'],
      'env_skipped_count' => row['env_skipped_count'], 'compiled_count' => 0,
      'status' => status, 'error_class' => error_class
    }
  end

  active = suite_rows.select { |row| row['owned_count'].positive? }.map { |row| row.fetch('id') }
  absent = candidates - active
  selected_rows = suite_rows.select { |row| selected.include?(row.fetch('id')) }
  reject_collection!('selection_empty') if selected_rows.empty?
  status = if selected_rows.any? { |row| row.fetch('status') == 'failed' }
             'failed'
           elsif selected_rows.any? { |row| row.fetch('status') == 'blocked' }
             'blocked'
           elsif selected_rows.all? { |row| %w[passed absent].include?(row.fetch('status')) }
             'passed'
           else
             'blocked'
           end

  # The collection digest is computed over the sorted, reviewed rows exactly as
  # the validator re-emits them, so a verifier can re-derive it from the
  # projection alone.
  collection_digest = canonical_digest(
    'coverage_requirement_id' => group.fetch('id'), 'platform' => platform,
    'suites' => suite_rows.sort_by { |row| row.fetch('id') }
  )

  proof = {
    'schema_version' => 1, 'phase' => 'execution',
    'source_sha' => ENV.fetch('CI_EXPECTED_SOURCE_SHA'),
    'control_sha' => ENV.fetch('CI_EXPECTED_CONTROL_SHA'),
    'manifest_digest' => manifest_digest,
    'catalog_digest' => ENV.fetch('CI_EXPECTED_CATALOG_DIGEST'),
    'selection_digest' => ENV.fetch('CI_EXPECTED_SELECTION_DIGEST'),
    'collection_digest' => collection_digest,
    'collection_complete' => true,
    'coverage_requirement_id' => group.fetch('id'),
    'runner_id' => runner, 'config_id' => group.fetch('config'), 'tier' => group.fetch('tier'),
    'platform' => platform, 'selection_mode' => mode,
    'selected_suite_ids' => selected, 'active_suite_ids' => active.sort,
    'absent_suite_ids' => absent.sort, 'status' => status, 'suites' => suite_rows
  }
  File.write(raw_path, JSON.generate(proof))

  # The validator's identity expectations came from the workflow (computed
  # before any project code ran). The content-derived expectations - the
  # collection digest, the group and platform that were actually collected,
  # and complete-collection status - are this collector's own output, and the
  # validator independently re-derives the catalog digest from the reviewed
  # catalog before accepting anything.
  ENV['CI_EXPECTED_COLLECTION_DIGEST'] = proof.fetch('collection_digest')
  ENV['CI_EXPECTED_COLLECTION_COMPLETE'] = 'true'
  ENV['CI_EXPECTED_PLATFORM'] = platform
  ENV['CI_EXPECTED_COVERAGE_REQUIREMENT_ID'] = group.fetch('id')

  # The validator re-derives the catalog digest and re-checks every field
  # against the reviewed schemas before anything is published.
  validator = File.expand_path('validate-suite-evidence.rb', __dir__)
  ok = system('ruby', validator, matrix_path, raw_path, projection_path)
  reject_collection!('validator') unless ok

  projection = JSON.parse(File.read(projection_path))
  puts "suite evidence: #{group.fetch('id')} #{projection.fetch('status')} " \
       "(#{projection['suites'].count { |row| row['status'] == 'passed' }} passed, " \
       "#{projection['suites'].count { |row| row['status'] == 'failed' }} failed, " \
       "#{projection['suites'].count { |row| row['status'] == 'blocked' }} blocked, " \
       "#{projection['suites'].count { |row| row['status'] == 'absent' }} absent)"
rescue CollectionError => error
  warn "suite evidence: rejected (#{error.message})"
  exit 1
rescue JSON::ParserError, KeyError, TypeError, NoMethodError, SystemCallError, ArgumentError
  warn 'suite evidence: rejected (unexpected)'
  exit 1
end
