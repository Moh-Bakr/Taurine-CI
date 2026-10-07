#!/usr/bin/env ruby
# Validate and re-emit the sanitized result of a trusted public suite collector.
# Raw test identities and runner reports never belong in the public projection.
require 'json'
require 'digest'

class SuiteEvidenceError < StandardError; end

TOP_KEYS = %w[
  schema_version phase source_sha control_sha manifest_digest catalog_digest selection_digest
  collection_digest collection_complete coverage_requirement_id runner_id config_id tier platform
  selection_mode selected_suite_ids active_suite_ids absent_suite_ids status suites
].sort.freeze
ROW_KEYS = %w[
  id discovered_count owned_count executed_count compiled_count ignored_count quarantined_count env_skipped_count status error_class
].sort.freeze
ERROR_CLASSES = %w[
  none collection_incomplete ownership_mismatch filter_mismatch execution_mismatch
  ignored_cases quarantined_cases environment_skip compiled_only test_failure api_mismatch runner_mismatch
].freeze
STATUSES = %w[passed failed blocked not_selected absent].freeze
TOP_STATUSES = %w[passed failed blocked].freeze
MAX_CASES = 1_000_000
SHA1 = /\A[0-9a-f]{40}\z/
SHA256 = /\A[0-9a-f]{64}\z/

def reject_unless(condition)
  raise SuiteEvidenceError unless condition
end

def canonical_ids(value, known)
  reject_unless(value.is_a?(Array) && value.all? { |id| id.is_a?(String) && known.include?(id) })
  reject_unless(value.uniq == value)
  value
end

def expected_from_env(name, pattern)
  value = ENV.fetch(name)
  reject_unless(value.match?(pattern))
  value
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

def validate(proof, matrix)
  reject_unless(proof.is_a?(Hash) && proof.keys.sort == TOP_KEYS)
  reject_unless(proof['schema_version'] == 1 && proof['phase'] == 'execution')
  expected_source = expected_from_env('CI_EXPECTED_SOURCE_SHA', SHA1)
  expected_control = expected_from_env('CI_EXPECTED_CONTROL_SHA', SHA1)
  expected_manifest = expected_from_env('CI_EXPECTED_MANIFEST_DIGEST', SHA256)
  expected_catalog = expected_from_env('CI_EXPECTED_CATALOG_DIGEST', SHA256)
  expected_selection = expected_from_env('CI_EXPECTED_SELECTION_DIGEST', SHA256)
  expected_collection = expected_from_env('CI_EXPECTED_COLLECTION_DIGEST', SHA256)
  expected_collection_complete = ENV.fetch('CI_EXPECTED_COLLECTION_COMPLETE')
  expected_mode = ENV.fetch('CI_EXPECTED_SELECTION_MODE')
  reject_unless(%w[full partial].include?(expected_mode))
  reject_unless(expected_collection_complete == 'true')
  expected_platform = ENV.fetch('CI_EXPECTED_PLATFORM')
  reject_unless(proof['source_sha'] == expected_source && proof['control_sha'] == expected_control)
  reject_unless(proof['manifest_digest'] == expected_manifest && proof['catalog_digest'] == expected_catalog)
  reject_unless(proof['selection_digest'] == expected_selection && proof['selection_mode'] == expected_mode)
  reject_unless(proof['collection_digest'] == expected_collection)
  reject_unless(proof['collection_complete'] == (expected_collection_complete == 'true'))

  catalog = matrix.fetch('suite_catalog')
  actual_catalog_digest = Digest::SHA256.hexdigest(JSON.generate(sort_json(catalog), ascii_only: true))
  reject_unless(actual_catalog_digest == expected_catalog)
  requirements = catalog.fetch('coverage_requirements')
  suites = catalog.fetch('suites')
  group_id = ENV.fetch('CI_EXPECTED_COVERAGE_REQUIREMENT_ID')
  group = requirements.find { |row| row.is_a?(Hash) && row['id'] == group_id }
  reject_unless(group)
  reject_unless(group['availability'] == 'supported' && group['candidate_suite_ids'].is_a?(Array) && !group['candidate_suite_ids'].empty?)
  %w[coverage_requirement_id runner_id config_id tier].zip(%w[id runner config tier]).each do |proof_key, group_key|
    reject_unless(proof[proof_key] == group[group_key])
  end
  reject_unless(group['platforms'].is_a?(Array) && group['platforms'].include?(expected_platform) &&
                proof['platform'] == expected_platform)

  suite_rows = suites.to_h { |row| [row.fetch('id'), row] }
  candidates = group.fetch('candidate_suite_ids')
  selected_expected = JSON.parse(ENV.fetch('CI_EXPECTED_SELECTED_SUITE_IDS'))
  selected = canonical_ids(proof['selected_suite_ids'], candidates)
  reject_unless(selected == canonical_ids(selected_expected, candidates))
  reject_unless(!selected.empty?)
  reject_unless(expected_mode != 'full' || selected.sort == candidates.sort)

  active = canonical_ids(proof['active_suite_ids'], candidates)
  absent = canonical_ids(proof['absent_suite_ids'], candidates)
  reject_unless((active & absent).empty? && (active + absent).sort == candidates.sort)

  rows = proof['suites']
  reject_unless(rows.is_a?(Array) && rows.length == candidates.length)
  row_ids = rows.map { |row| row.is_a?(Hash) ? row['id'] : nil }
  reject_unless(row_ids.uniq.length == row_ids.length && row_ids.sort == candidates.sort)
  rows.each do |row|
    reject_unless(row.is_a?(Hash) && row.keys.sort == ROW_KEYS)
    id = row['id']
    reject_unless(suite_rows.key?(id) && candidates.include?(id))
    counts = %w[discovered_count owned_count executed_count compiled_count ignored_count quarantined_count env_skipped_count].to_h do |key|
      value = row[key]
      reject_unless(value.is_a?(Integer) && value >= 0 && value <= MAX_CASES)
      [key, value]
    end
    reject_unless(counts['owned_count'] <= counts['discovered_count'])
    reject_unless(counts['executed_count'] + counts['compiled_count'] + counts['ignored_count'] +
                  counts['quarantined_count'] + counts['env_skipped_count'] <= counts['owned_count'])
    reject_unless(STATUSES.include?(row['status']) && ERROR_CLASSES.include?(row['error_class']))

    # Compiled targets are evidence of compilation, never of execution: a
    # compile-only selection reports every owned case as compiled with zero
    # executed cases, status blocked. It cannot merge and cannot masquerade
    # as skipped work either.
    if row['error_class'] == 'compiled_only'
      reject_unless(counts['compiled_count'] == counts['owned_count'] && counts['owned_count'].positive?)
      reject_unless(counts['executed_count'].zero? && row['status'] == 'blocked')
      reject_unless(selected.include?(id))
    else
      reject_unless(counts['compiled_count'].zero?)
    end

    if counts['owned_count'].zero?
      reject_unless(absent.include?(id) && counts.values.all?(&:zero?))
      reject_unless(row['status'] == 'absent' && row['error_class'] == 'none')
    else
      reject_unless(active.include?(id))
      reject_unless(row['status'] != 'absent')
    end

    if row['status'] == 'absent'
      reject_unless(absent.include?(id) && counts.values.all?(&:zero?) && row['error_class'] == 'none')
    elsif selected.include?(id)
      reject_unless(%w[passed failed blocked absent].include?(row['status']))
    else
      reject_unless(row['status'] == 'not_selected' &&
                    %w[executed_count ignored_count quarantined_count env_skipped_count].all? { |key| counts[key].zero? } &&
                    row['error_class'] == 'none')
    end

    if row['status'] == 'passed'
      reject_unless(selected.include?(id) && counts['owned_count'].positive? &&
                    counts['executed_count'] == counts['owned_count'] &&
                    counts['ignored_count'].zero? && counts['env_skipped_count'].zero? &&
                    counts['quarantined_count'].zero? &&
                    row['error_class'] == 'none')
    elsif row['status'] == 'failed' || row['status'] == 'blocked'
      reject_unless(selected.include?(id) && row['error_class'] != 'none')
    end
  end

  selected_rows = rows.select { |row| selected.include?(row.fetch('id')) }
  derived_status = if selected_rows.any? { |row| row.fetch('status') == 'failed' }
                     'failed'
                   elsif selected_rows.any? { |row| row.fetch('status') == 'blocked' }
                     'blocked'
                   elsif active.any? && selected_rows.any? { |row| row.fetch('status') == 'passed' } &&
                         selected_rows.all? { |row| %w[passed absent].include?(row.fetch('status')) }
                     'passed'
                   else
                     'blocked'
                   end
  reject_unless(TOP_STATUSES.include?(proof['status']) && proof['status'] == derived_status)

  # Emit only fields whose values were checked against the reviewed catalog or fixed
  # scalar schemas. The collector's raw identities stay in RUNNER_TEMP and are never copied.
  {
    'schema_version' => 1,
    'phase' => 'execution',
    'source_sha' => expected_source,
    'control_sha' => expected_control,
    'manifest_digest' => expected_manifest,
    'catalog_digest' => expected_catalog,
    'selection_digest' => expected_selection,
    'collection_digest' => proof.fetch('collection_digest'),
    'collection_complete' => true,
    'coverage_requirement_id' => group.fetch('id'),
    'runner_id' => group.fetch('runner'),
    'config_id' => group.fetch('config'),
    'tier' => group.fetch('tier'),
    'platform' => proof.fetch('platform'),
    'selection_mode' => expected_mode,
    'selected_suite_ids' => selected,
    'active_suite_ids' => active,
    'absent_suite_ids' => absent,
    'status' => derived_status,
    'suites' => rows.sort_by { |row| row.fetch('id') }
  }
end

begin
  matrix_path, proof_path, output_path = ARGV
  reject_unless(matrix_path && proof_path && output_path)
  matrix = JSON.parse(File.read(matrix_path))
  proof = JSON.parse(File.read(proof_path))
  safe = validate(proof, matrix)
  File.write(output_path, JSON.generate(safe) + "\n", mode: 'w', perm: 0o600)
  puts 'suite evidence: validated sanitized execution projection'
rescue SuiteEvidenceError, JSON::ParserError, KeyError, TypeError, NoMethodError, SystemCallError, ArgumentError
  warn 'suite evidence: rejected invalid or incomplete projection'
  exit 1
end
