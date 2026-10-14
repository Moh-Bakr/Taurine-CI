#!/usr/bin/env ruby
# Standalone local diagnostic prototype. It is deliberately not wired to a workflow.

require 'json'
require 'pathname'

module PgDbxApplicability
  class InvalidInput < StandardError; end
  class UnsafeEvidence < StandardError; end
  class UnknownEngine < StandardError; end
  class UnsupportedEngine < StandardError; end
  class RosterMismatch < StandardError; end

  class DuplicateKeyHash < Hash
    def []=(key, value)
      raise InvalidInput if key?(key)

      super
    end
  end

  REGISTERED_ENGINES = %w[
    doris starrocks db2 informix rocketmq iris postgres pg-dbx mysql mssql pgtls bastion
  ].freeze
  BASELINE_ENGINES = %w[
    doris starrocks db2 informix rocketmq iris postgres mysql mssql pgtls bastion
  ].freeze
  PG_DBX_SUITES = %w[dbx_pg_live dbx_shadow_pg].freeze
  MARKER_IDS = %w[
    live_suite shadow_suite adapter_manifest engine_feature conformance_wiring
  ].freeze

  MAX_MANIFEST_BYTES = 16 * 1024
  MAX_CATALOG_BYTES = 16 * 1024
  MAX_MARKER_BYTES = 1024 * 1024
  MAX_RELATIVE_PATH_BYTES = 512
  CLI_EXIT_NON_GATE = 3
  DEFAULT_CATALOG_JSON = <<~'JSON'.freeze
    {
      "schema_version": 1,
      "proposal_state": "not_adopted",
      "registered_engine_ids": [
        "doris", "starrocks", "db2", "informix", "rocketmq", "iris",
        "postgres", "pg-dbx", "mysql", "mssql", "pgtls", "bastion"
      ],
      "baseline_non_waivable_engine_ids": [
        "doris", "starrocks", "db2", "informix", "rocketmq", "iris",
        "postgres", "mysql", "mssql", "pgtls", "bastion"
      ],
      "deployed_behavior": {
        "all_options_count": 12,
        "all_expands_to_registered": true,
        "current_full_admission_requires_all_live_arms": true
      },
      "pg_dbx": {
        "engine_id": "pg-dbx",
        "registration": "registered",
        "current_admission_requirement": "required",
        "proposed_applicability_requirement": "owner_decision_required",
        "readiness": "invalid_evidence",
        "candidate_suite_ids": ["dbx_pg_live", "dbx_shadow_pg"]
      }
    }
  JSON

  OUTPUT_KEYS = %w[
    status engine registered_count current_required_count baseline_count markers_observed markers_invalid
    markers_required execution_result admission_result
  ].freeze

  module_function

  def parse_json_file(path, limit)
    stat = File.lstat(path)
    raise InvalidInput unless stat.file? && !stat.symlink? && stat.size <= limit

    bytes = File.binread(path, limit + 1)
    raise InvalidInput if bytes.bytesize > limit

    json = bytes.force_encoding(Encoding::UTF_8)
    raise InvalidInput unless json.valid_encoding?

    JSON.parse(json, object_class: DuplicateKeyHash, max_nesting: 8, allow_nan: false,
                    allow_duplicate_key: false)
  rescue SystemCallError, IOError, JSON::ParserError, EncodingError, ArgumentError
    raise InvalidInput
  end

  def validate_catalog!(catalog)
    expected_keys = %w[
      schema_version proposal_state registered_engine_ids baseline_non_waivable_engine_ids
      deployed_behavior pg_dbx
    ].sort
    raise InvalidInput unless catalog.is_a?(Hash) && catalog.keys.sort == expected_keys
    raise InvalidInput unless catalog['schema_version'] == 1 && catalog['proposal_state'] == 'not_adopted'
    raise InvalidInput unless catalog['registered_engine_ids'] == REGISTERED_ENGINES
    raise InvalidInput unless catalog['baseline_non_waivable_engine_ids'] == BASELINE_ENGINES

    deployed = catalog['deployed_behavior']
    raise InvalidInput unless deployed.is_a?(Hash) && deployed.keys.sort == %w[
      all_expands_to_registered all_options_count current_full_admission_requires_all_live_arms
    ].sort
    raise InvalidInput unless deployed['all_options_count'] == 12 &&
                              deployed['all_expands_to_registered'] == true &&
                              deployed['current_full_admission_requires_all_live_arms'] == true

    pg_dbx = catalog['pg_dbx']
    raise InvalidInput unless pg_dbx.is_a?(Hash) && pg_dbx.keys.sort == %w[
      engine_id registration current_admission_requirement proposed_applicability_requirement
      readiness candidate_suite_ids
    ].sort
    raise InvalidInput unless pg_dbx['engine_id'] == 'pg-dbx' &&
                              pg_dbx['registration'] == 'registered' &&
                              pg_dbx['current_admission_requirement'] == 'required' &&
                              pg_dbx['proposed_applicability_requirement'] == 'owner_decision_required' &&
                              pg_dbx['readiness'] == 'invalid_evidence' &&
                              pg_dbx['candidate_suite_ids'] == PG_DBX_SUITES
  end

  def validate_manifest!(manifest)
    expected_keys = %w[schema_version engine suite_ids markers].sort
    raise InvalidInput unless manifest.is_a?(Hash) && manifest.keys.sort == expected_keys
    raise InvalidInput unless manifest['schema_version'] == 1

    engine = manifest['engine']
    raise UnknownEngine unless engine.is_a?(String) && REGISTERED_ENGINES.include?(engine)
    raise UnsupportedEngine unless engine == 'pg-dbx'
    raise RosterMismatch unless manifest['suite_ids'] == PG_DBX_SUITES

    markers = manifest['markers']
    raise InvalidInput unless markers.is_a?(Array) && markers.length == MARKER_IDS.length
    ids = markers.map do |marker|
      raise InvalidInput unless marker.is_a?(Hash) && marker.keys.sort == %w[id path]
      marker['id']
    end
    raise InvalidInput unless ids == MARKER_IDS

    paths = markers.map { |marker| marker['path'] }
    raise InvalidInput unless paths.all? { |path| safe_relative_path?(path) }
    raise InvalidInput unless paths.uniq == paths

    markers
  end

  def safe_relative_path?(path)
    return false unless path.is_a?(String) && !path.empty? && path.bytesize <= MAX_RELATIVE_PATH_BYTES
    return false unless path.valid_encoding? && !path.include?("\0") && !path.include?('\\')
    return false if Pathname.new(path).absolute?

    parts = path.split('/', -1)
    parts.none?(&:empty?) && parts.none? { |part| part == '.' || part == '..' }
  end

  def marker_valid?(id, relative_path, bytes)
    basename = File.basename(relative_path)
    text = bytes.dup.force_encoding(Encoding::UTF_8)
    return false unless text.valid_encoding?

    case id
    when 'live_suite'
      basename == 'dbx_pg_live.rs'
    when 'shadow_suite'
      basename == 'dbx_shadow_pg.rs'
    when 'adapter_manifest'
      basename == 'Cargo.toml' && package_named?(text, 'taurine-db-dbx')
    when 'engine_feature'
      basename == 'Cargo.toml' && feature_declared?(text, 'dbx-pg')
    when 'conformance_wiring'
      basename == 'Cargo.toml' && conformance_wired?(text)
    else
      false
    end
  end

  def section_body(text, section)
    body = []
    active = false
    text.each_line do |line|
      if (match = line.match(/^\s*\[([^\]]+)\]\s*(?:#.*)?$/))
        active = match[1] == section
      elsif active
        body << line
      end
    end
    body.join
  end

  def package_named?(text, name)
    section_body(text, 'package').match?(/^\s*name\s*=\s*["']#{Regexp.escape(name)}["']\s*(?:#.*)?$/)
  end

  def feature_declared?(text, feature)
    section_body(text, 'features').match?(/^\s*#{Regexp.escape(feature)}\s*=\s*\[[^\]]*\]\s*(?:#.*)?$/)
  end

  def conformance_wired?(text)
    body = section_body(text, 'dev-dependencies')
    body.match?(/^\s*taurine-db-engine\s*=\s*\{[^}]*\}\s*(?:#.*)?$/m) &&
      body.include?('"dbx-pg"') &&
      body.match?(/^\s*taurine-db-dbx\s*=\s*\{[^}]*\}\s*(?:#.*)?$/m)
  end

  def inspect_marker(root, marker)
    current = root
    parts = marker.fetch('path').split('/')
    parts.each_with_index do |part, index|
      current = File.join(current, part)
      begin
        stat = File.lstat(current)
      rescue Errno::ENOENT
        return :missing
      rescue Errno::ENOTDIR
        return :invalid
      end
      raise UnsafeEvidence if stat.symlink?

      if index < parts.length - 1
        return :invalid unless stat.directory?
      else
        return :invalid unless stat.file?
        raise UnsafeEvidence if stat.size > MAX_MARKER_BYTES
      end
    end

    real = File.realpath(current)
    raise UnsafeEvidence unless real.start_with?("#{root}/")

    bytes = File.binread(real, MAX_MARKER_BYTES + 1)
    raise UnsafeEvidence if bytes.bytesize > MAX_MARKER_BYTES

    marker_valid?(marker.fetch('id'), marker.fetch('path'), bytes) ? :candidate : :invalid
  rescue SystemCallError, IOError
    raise UnsafeEvidence
  end

  def source_root_path(path)
    stat = File.lstat(path)
    raise UnsafeEvidence unless stat.directory? && !stat.symlink?

    File.realpath(path)
  rescue SystemCallError
    raise UnsafeEvidence
  end

  def report(status, observed = 0, invalid = 0)
    {
      'status' => status,
      'engine' => 'pg-dbx',
      'registered_count' => 12,
      'current_required_count' => 12,
      'baseline_count' => 11,
      'markers_observed' => observed,
      'markers_invalid' => invalid,
      'markers_required' => MARKER_IDS.length,
      'execution_result' => 'not_run',
      'admission_result' => 'not_evaluated'
    }
  end

  def evaluate(source_root:, manifest_path:, catalog_path: nil)
    begin
      catalog = if catalog_path
                  parse_json_file(catalog_path, MAX_CATALOG_BYTES)
                else
                  JSON.parse(DEFAULT_CATALOG_JSON, object_class: DuplicateKeyHash,
                                                  max_nesting: 8, allow_nan: false,
                                                  allow_duplicate_key: false)
                end
      validate_catalog!(catalog)
    rescue InvalidInput
      return report('catalog_mismatch')
    end

    root = source_root_path(source_root)
    manifest = parse_json_file(manifest_path, MAX_MANIFEST_BYTES)
    markers = validate_manifest!(manifest)

    marker_states = markers.map { |marker| inspect_marker(root, marker) }
    observed = marker_states.count(:candidate)
    invalid = marker_states.count(:invalid)
    status = if observed.zero? && invalid.zero?
               'unavailable_stage2_proof'
             elsif observed == MARKER_IDS.length && invalid.zero?
               'candidates_present'
             elsif invalid.positive?
               'invalid_evidence'
             else
               'partial_or_inconsistent'
             end
    report(status, observed, invalid)
  rescue UnknownEngine
    report('unknown_engine')
  rescue UnsupportedEngine
    report('unsupported_engine')
  rescue RosterMismatch
    report('roster_mismatch')
  rescue UnsafeEvidence
    report('invalid_evidence')
  rescue InvalidInput, SystemCallError, IOError, JSON::ParserError, EncodingError, ArgumentError
    report('invalid_manifest')
  end

  def render(report_hash)
    JSON.generate(report_hash)
  end

  def cli(argv)
    options = {}
    index = 0
    while index < argv.length
      flag = argv[index]
      value = argv[index + 1]
      return report('invalid_input') unless value && !value.start_with?('--')

      key = case flag
            when '--source-root' then :source_root
            when '--manifest' then :manifest_path
            when '--catalog' then :catalog_path
            else return report('invalid_input')
            end
      return report('invalid_input') if options.key?(key)

      options[key] = value
      index += 2
    end
    return report('invalid_input') unless options.key?(:source_root) && options.key?(:manifest_path)

    evaluate(**options)
  rescue StandardError
    report('invalid_input')
  end
end

if $PROGRAM_NAME == __FILE__
  puts PgDbxApplicability.render(PgDbxApplicability.cli(ARGV))
  exit PgDbxApplicability::CLI_EXIT_NON_GATE
end
