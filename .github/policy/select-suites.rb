#!/usr/bin/env ruby
# Exact suite-selection calculator over the reviewed catalog and the
# conservative feature dependency graph.
#
# Input (a JSON file, or stdin for "-"):
#   {
#     "selection_mode": "full" | "partial",
#     "changed_feature_ids": ["rest", ...],
#     "base_sha": "" | 40-hex,
#     "base_valid": true|false,          // false: base missing, non-ancestor or unreadable
#     "unknown_paths": true|false,       // true: a changed path matched no reviewed rule
#     "shared_surface": true|false,      // true: fixture, alias, setup, config, lockfile, toolchain,
#                                        //      CI/scanner/selector input or composition root changed
#     "expected_catalog_digest": sha256, // the dispatch identity's bound catalog digest
#     "expected_feature_graph_digest": sha256
#   }
#
# Output (JSON on stdout):
#   { schema_version, selection_mode, complete, reasons[], groups{}, selection_digest }
# with one selected_suite_ids list per supported coverage requirement.
#
# Fail-closed rules: full mode, an invalid base, unknown paths, a shared
# surface, or selector inputs (catalog or graph digests) that do not match the
# reviewed values select the complete set. A malformed request is an error,
# never a reduction. Unselected suites are reported per group so a dispatcher
# can skip them; a partial selection can never contribute a full PASS.
require 'digest'
require 'json'

class SelectionError < StandardError; end

def reject_selection!(code)
  raise SelectionError, code
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

SHA1 = /\A[0-9a-f]{40}\z/.freeze

begin
  matrix_path, request_path = ARGV
  reject_selection!('arguments') unless matrix_path && request_path
  matrix = JSON.parse(File.read(matrix_path))
  catalog = matrix.fetch('suite_catalog')
  graph = matrix.fetch('feature_graph')
  reject_selection!('graph') unless graph.is_a?(Hash) && graph['version'] == 1 &&
                                    graph['dependency_edges'].is_a?(Array)
  graph_digest = canonical_digest(graph)

  request_text = request_path == '-' ? $stdin.read : File.read(request_path)
  request = JSON.parse(request_text)
  reject_selection!('request') unless request.is_a?(Hash) &&
                                      %w[selection_mode base_sha base_valid unknown_paths shared_surface
                                         changed_feature_ids expected_catalog_digest expected_feature_graph_digest]
                                        .all? { |key| request.key?(key) }
  mode = request.fetch('selection_mode')
  reject_selection!('request') unless %w[full partial].include?(mode)
  base_sha = request.fetch('base_sha')
  reject_selection!('request') unless base_sha == '' || (base_sha.is_a?(String) && base_sha.match?(SHA1))
  base_valid = request.fetch('base_valid')
  unknown_paths = request.fetch('unknown_paths')
  shared_surface = request.fetch('shared_surface')
  reject_selection!('request') unless [base_valid, unknown_paths, shared_surface].all? { |value| value == true || value == false }
  changed = request.fetch('changed_feature_ids')
  reject_selection!('request') unless changed.is_a?(Array) && changed.uniq == changed &&
                                     changed.all? { |id| id.is_a?(String) && id.match?(/\A[a-z][a-z0-9-]{0,63}\z/) }
  expected_catalog = request.fetch('expected_catalog_digest')
  expected_graph = request.fetch('expected_feature_graph_digest')
  reject_selection!('request') unless expected_catalog.is_a?(String) && expected_graph.is_a?(String)

  # Selector-input binding: the request must carry exactly the digests the
  # dispatch identity bound. Anything else is a changed selector input.
  reasons = []
  reasons << 'full_requested' if mode == 'full'
  reasons << 'invalid_base' if mode == 'partial' && (base_valid == false || base_sha.empty?)
  reasons << 'unknown_paths' if unknown_paths
  reasons << 'shared_surface' if shared_surface
  reasons << 'selector_inputs_changed' if expected_catalog != canonical_digest(catalog) ||
                                          expected_graph != graph_digest
  complete = reasons.any?

  # Conservative closure: every transitively reachable consumer of a changed
  # feature joins the selection; nothing else is removed.
  selected_features = nil
  unless complete
    consumers = graph.fetch('dependency_edges').each_with_object({}) do |edge, map|
      (map[edge.fetch('from')] ||= []) << edge.fetch('to')
    end
    selected_features = changed.dup
    frontier = changed.dup
    until frontier.empty?
      reachable = (consumers[frontier.shift] || []) - selected_features
      selected_features.concat(reachable)
      frontier.concat(reachable)
    end
    selected_features = selected_features.sort
  end

  suite_features = catalog.fetch('suites').each_with_object({}) do |row, map|
    map[row.fetch('id')] = row.fetch('feature') if row.is_a?(Hash)
  end

  groups = {}
  catalog.fetch('coverage_requirements').each do |requirement|
    reject_selection!('catalog') unless requirement.is_a?(Hash) && requirement['id'].is_a?(String)
    next unless requirement['availability'] == 'supported'
    candidates = requirement.fetch('candidate_suite_ids')
    reject_selection!('catalog') unless candidates.is_a?(Array) && candidates.all? { |id| suite_features.key?(id) }
    selected = complete ? candidates : candidates.select { |id| selected_features.include?(suite_features.fetch(id)) }
    groups[requirement.fetch('id')] = {
      'runner_id' => requirement.fetch('runner'),
      'concerns' => requirement.fetch('concerns'),
      'selected_suite_ids' => selected.sort
    }
  end

  result = {
    'schema_version' => 1,
    'selection_mode' => mode,
    'complete' => complete,
    'reasons' => complete ? reasons.sort : ['feature_closure'],
    'groups' => groups,
    'selection_digest' => ''
  }
  result['selection_digest'] = canonical_digest(
    'mode' => mode, 'reasons' => result['reasons'], 'groups' => groups,
    'catalog_digest' => expected_catalog,
    'feature_graph_digest' => expected_graph
  )
  puts JSON.generate(sort_json(result))
rescue SelectionError => error
  warn "suite selection: rejected (#{error.message})"
  exit 1
rescue JSON::ParserError, KeyError, TypeError, NoMethodError, SystemCallError, ArgumentError
  warn 'suite selection: rejected (unexpected)'
  exit 1
end
