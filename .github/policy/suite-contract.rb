#!/usr/bin/env ruby
# Compute the trusted suite-contract expectations for one concern job.
#
# Runs in the concern job after the exact-SHA checkout and token revocation but
# BEFORE any dependency installation or project command. It re-reads the public
# catalog from the control-plane checkout, recomputes its canonical digest,
# reads the private ownership manifest if the reviewed path exists, and turns
# the dispatcher's selection into the per-group expected values the evidence
# collector must match. Everything it prints is either a fixed value or a
# digest; no path, pattern or source text is ever echoed.
#
# The evidence collector is a separate, later step. Project code runs between
# the two, so the collector must recompute the same values and match them
# against these outputs: a manifest or catalog tampered in between fails the
# match instead of silently attesting the tampered state.
require 'digest'
require 'json'

MANIFEST_PATH = 'scripts/ci/suite-ownership.json'.freeze

class SuiteContractError < StandardError; end

def reject_contract!(code)
  raise SuiteContractError, code
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

def read_json(path)
  JSON.parse(File.read(path))
rescue SystemCallError, JSON::ParserError
  nil
end

begin
  matrix_path, concern, repo_root = ARGV
  reject_contract!('arguments') unless matrix_path && concern && repo_root && concern.match?(/\A[a-z0-9][a-z0-9-]{0,63}\z/)
  matrix = read_json(matrix_path)
  reject_contract!('catalog') unless matrix.is_a?(Hash) && matrix.fetch('suite_catalog', {}).is_a?(Hash)
  catalog = matrix.fetch('suite_catalog')
  catalog_digest = canonical_digest(catalog)

  manifest_path = File.join(repo_root, MANIFEST_PATH)
  manifest = File.file?(manifest_path) ? read_json(manifest_path) : nil
  manifest_present = manifest.is_a?(Hash)
  # Canonical-JSON digest of the ownership manifest. Distinct by definition
  # from the private audit's raw-byte digest over the private reviewed catalog;
  # the two attest different files with different hashing and must never be
  # cross-compared.
  manifest_digest = manifest_present ? canonical_digest(manifest) : ''

  selection_text = ENV['CI_SUITE_SELECTION'].to_s
  reject_contract!('selection') unless selection_text.empty? || selection_text.match?(/\A[ -~]+\z/)
  selection = selection_text.empty? ? {} : begin
    JSON.parse(selection_text)
  rescue JSON::ParserError, SystemCallError
    reject_contract!('selection')
  end
  reject_contract!('selection') unless selection.is_a?(Hash)
  mode = selection.fetch('selection_mode', 'full')
  reject_contract!('selection') unless %w[full partial].include?(mode)
  # The dispatch review mode travels inside the selection. `shadow` is the only
  # reviewed value today: the complete set runs and the selection is reported,
  # so anything else is refused rather than guessed at.
  review = selection.fetch('review', nil)
  reject_contract!('selection') unless review.nil? || review == 'shadow'
  supplied_ids = selection.fetch('selected_suite_ids', [])
  reject_contract!('selection') unless supplied_ids.is_a?(Array) &&
                                       supplied_ids.all? { |id| id.is_a?(String) && id.match?(/\A[a-z][a-z0-9.-]{1,127}\z/) } &&
                                       supplied_ids.uniq == supplied_ids

  groups = catalog.fetch('coverage_requirements').select do |row|
    row.is_a?(Hash) && row['availability'] == 'supported' && row['concerns'].is_a?(Array) && row['concerns'].include?(concern)
  end
  # A concern the reviewed catalog does not bind to exactly one supported
  # coverage group has no feature-suite evidence to collect. That is the
  # reviewed state today for the Rust, scan, build and quality concerns; one
  # ambiguity (two groups) would be a catalog bug and fails closed.
  if groups.length.zero?
    puts "catalog_digest=#{catalog_digest}"
    puts 'manifest_present=false'
    puts 'manifest_digest='
    puts 'coverage_requirement_id='
    puts 'selection_mode='
    puts 'selected_suite_ids=[]'
    puts 'selection_digest='
    exit 0
  end
  reject_contract!('group') unless groups.length == 1
  group = groups.first
  candidates = group.fetch('candidate_suite_ids')
  reject_contract!('group') unless candidates.is_a?(Array) && !candidates.empty? &&
                                   candidates.all? { |id| id.is_a?(String) } && candidates.uniq == candidates

  selected = case mode
             when 'full'
               reject_contract!('selection') unless supplied_ids.empty? || supplied_ids.sort == candidates.sort
               candidates
             else
               selected = candidates.select { |id| supplied_ids.include?(id) }
               reject_contract!('selection') unless selected.uniq.length == supplied_ids.length
               selected
             end

  # A shadow review reports what a partial selection would run while the
  # complete set actually executes, so the evidence contract stays the full
  # set: the projection collected under a shadow round is identical to a full
  # round's, and the would-be selection leaves only through the shadow output
  # below, into the job's summary - never into the sanitized projection.
  shadow_selected = review == 'shadow' ? selected : nil
  if review == 'shadow'
    mode = 'full'
    selected = candidates
  end

  puts "catalog_digest=#{catalog_digest}"
  puts "manifest_present=#{manifest_present}"
  puts "manifest_digest=#{manifest_digest}"
  puts "coverage_requirement_id=#{group.fetch('id')}"
  puts "selection_mode=#{mode}"
  puts "selected_suite_ids=#{JSON.generate(selected)}"
  puts "shadow_selected_suite_ids=#{JSON.generate(shadow_selected.sort)}" unless shadow_selected.nil?
  puts "selection_digest=#{if selection_text.empty? || shadow_selected
                             canonical_digest('mode' => 'full', 'selected_suite_ids' => candidates)
                           else
                             canonical_digest(selection)
                           end}"
rescue SuiteContractError => error
  warn "suite contract: rejected (#{error.message})"
  exit 1
rescue StandardError
  warn 'suite contract: rejected (unexpected)'
  exit 1
end
