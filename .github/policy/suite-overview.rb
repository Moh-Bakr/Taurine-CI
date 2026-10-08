#!/usr/bin/env ruby
# Aggregate the sanitized suite-evidence projections into one per-feature
# coverage overview for the run summary.
#
# Input: the run's evidence projections (one JSON object per concern job,
# exported from the concern workflow's job outputs), via stdin ("-" or no
# second argument) or a file path. Each projection must already be the
# validator's sanitized output: this script re-checks the exact reviewed field
# sets and refuses anything else, then merges shard projections of the same
# coverage group, so a regression tier's four shards report one row per
# feature. Output is Markdown on stdout using only reviewed values: suite and
# feature IDs, counts, fixed status classes, digests and SHAs.
#
# Exit 1 on any malformed projection, identity mismatch across projections of
# one run, or an unexpected group binding - never on a failed or skipped suite,
# which is evidence like any other.
require 'digest'
require 'json'

class OverviewError < StandardError; end

def reject_overview!(code)
  raise OverviewError, code
end

TOP_KEYS = %w[
  schema_version phase source_sha control_sha manifest_digest catalog_digest selection_digest
  collection_digest collection_complete coverage_requirement_id runner_id config_id tier platform
  selection_mode selected_suite_ids active_suite_ids absent_suite_ids status suites
].sort.freeze
ROW_KEYS = %w[
  id discovered_count owned_count executed_count compiled_count ignored_count quarantined_count env_skipped_count status error_class
].sort.freeze
STATUSES = %w[passed failed blocked not_selected absent].freeze
COUNT_KEYS = %w[discovered_count owned_count executed_count compiled_count ignored_count quarantined_count env_skipped_count].freeze

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

def parse_projection(text)
  reject_overview!('projection') unless text.is_a?(String) && text.match?(/\A[ -~\n\r\t]*\z/)
  projection = JSON.parse(text)
  reject_overview!('projection') unless projection.is_a?(Hash) && projection.keys.sort == TOP_KEYS &&
                                        projection['schema_version'] == 1 && projection['phase'] == 'execution' &&
                                        STATUSES.include?(projection['status'])
  rows = projection['suites']
  reject_overview!('projection') unless rows.is_a?(Array) && rows.all? do |row|
    row.is_a?(Hash) && row.keys.sort == ROW_KEYS && STATUSES.include?(row['status']) &&
      COUNT_KEYS.all? { |key| row[key].is_a?(Integer) && row[key] >= 0 }
  end
  projection
end

# Merge the shard projections of one coverage group into one view. Counts sum;
# the suite status takes the worst observed shard (a suite that failed in the
# shard that ran it is failed, not absent because another shard saw nothing).
def merge_group(projections)
  merged = {}
  projections.each do |projection|
    merged[:selection_mode] ||= projection['selection_mode']
    reject_overview!('identity') unless merged[:selection_mode] == projection['selection_mode']
    merged[:source_sha] ||= projection['source_sha']
    merged[:control_sha] ||= projection['control_sha']
    merged[:catalog_digest] ||= projection['catalog_digest']
    merged[:manifest_digest] ||= projection['manifest_digest']
    merged[:selection_digest] ||= projection['selection_digest']
    %i[source_sha control_sha catalog_digest manifest_digest selection_digest].each do |key|
      reject_overview!('identity') unless merged[key] == projection[key.to_s]
    end
    merged[:selected] = ((merged[:selected] || []) + projection['selected_suite_ids']).uniq.sort
    merged[:runner_id] ||= projection['runner_id']
    merged[:config_id] ||= projection['config_id']
    merged[:tier] ||= projection['tier']
    merged[:platform] ||= projection['platform']
    merged[:collections] = (merged[:collections] || 0) + 1
    merged[:groups] = ((merged[:groups] || []) + [projection['coverage_requirement_id']]).uniq
    projection['suites'].each do |row|
      entry = merged[row['id']] ||= {
        'discovered_count' => 0, 'owned_count' => 0, 'executed_count' => 0, 'compiled_count' => 0,
        'ignored_count' => 0, 'quarantined_count' => 0, 'env_skipped_count' => 0,
        'statuses' => [], 'shards' => 0
      }
      COUNT_KEYS.each { |key| entry[key] += row[key] }
      entry['statuses'] << row['status'] unless entry['statuses'].include?(row['status'])
      entry['shards'] += 1
    end
  end
  merged
end

def merged_status(statuses)
  %w[failed blocked not_selected].each { |status| return status if statuses.include?(status) }
  statuses.include?('passed') ? 'passed' : 'absent'
end

begin
  matrix_path, evidence_input = ARGV
  reject_overview!('arguments') unless matrix_path
  matrix = JSON.parse(File.read(matrix_path))
  catalog = matrix.fetch('suite_catalog')
  suites = catalog.fetch('suites').to_h { |row| [row.fetch('id'), row] }
  requirements = catalog.fetch('coverage_requirements').to_h { |row| [row.fetch('id'), row] }

  raw = evidence_input.to_s.empty? || evidence_input == '-' ? $stdin.read : File.read(evidence_input)
  exported = JSON.parse(raw)
  reject_overview!('evidence') unless exported.is_a?(Hash)
  projections = exported.values.filter_map { |value| value && !value.to_s.empty? ? parse_projection(value) : nil }
  reject_overview!('evidence') unless projections.length == exported.values.count { |value| value && !value.to_s.empty? }

  puts '## Feature-suite overview'
  puts
  if projections.empty?
    puts 'No suite evidence was collected for this run: the concerns that ran are not yet bound to a reviewed coverage group, or the ownership manifest was absent at the validated SHA.'
    exit 0
  end

  by_group = projections.group_by { |projection| projection['coverage_requirement_id'] }
  first = projections.first
  puts "- Source SHA: `#{first['source_sha']}`"
  puts "- Control plane: `#{first['control_sha']}`"
  puts
  by_group.keys.sort.each do |group_id|
    requirement = requirements.fetch(group_id) { reject_overview!('group') }
    merged = merge_group(by_group[group_id])
    # Every exported projection of the group binds the same reviewed definition.
    reject_overview!('group') unless merged[:groups] == [group_id] && merged[:runner_id] == requirement['runner'] &&
                                     merged[:config_id] == requirement['config'] && merged[:tier] == requirement['tier'] &&
                                     merged[:platform] && requirement['platforms'].include?(merged[:platform])
    unknown = merged.keys.select { |key| key.is_a?(String) } - requirement.fetch('candidate_suite_ids')
    reject_overview!('suite') unless unknown.empty?
    selected = merged[:selected] || []
    selection = merged[:selection_mode] == 'partial' ? "partial (#{selected.length}/#{requirement['candidate_suite_ids'].length} suites)" : 'full'
    puts "### #{group_id}"
    puts
    puts "- Runner: `#{merged[:runner_id]}` / `#{merged[:config_id]}`; tier `#{merged[:tier]}`; #{merged[:collections]} collected shard(s); selection: #{selection}."
    puts
    puts '| Feature | Suites | Executed | Compiled | Env-skipped | Ignored | Quarantined | Status |'
    puts '| --- | --- | --- | --- | --- | --- | --- | --- |'
    requirement.fetch('feature_ids').sort.each do |feature|
      rows = merged.keys.select { |key| key.is_a?(String) && suites.fetch(key) { reject_overview!('suite') }['feature'] == feature }
      counts = COUNT_KEYS.to_h { |key| [key, rows.sum { |id| merged[id][key] }] }
      statuses = rows.flat_map { |id| merged[id]['statuses'] }
      status = rows.empty? ? 'not_selected' : merged_status(statuses)
      if rows.empty?
        puts "| #{feature} | 0 | - | - | - | - | - | #{status} |"
      else
        puts "| #{feature} | #{rows.length} | #{counts['executed_count']} | #{counts['compiled_count']} | #{counts['env_skipped_count']} | #{counts['ignored_count']} | #{counts['quarantined_count']} | #{status} |"
      end
    end
    puts
  end
rescue OverviewError => error
  warn "suite overview: rejected (#{error.message})"
  exit 1
rescue JSON::ParserError, KeyError, TypeError, NoMethodError, SystemCallError, ArgumentError
  warn 'suite overview: rejected (unexpected)'
  exit 1
end
