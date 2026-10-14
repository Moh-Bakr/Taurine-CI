#!/usr/bin/env ruby

require 'json'
require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require_relative 'pg-dbx-applicability'

class PgDbxApplicabilityTest < Minitest::Test
  P = PgDbxApplicability
  MARKER_PATHS = {
    'live_suite' => 'suites/dbx_pg_live.rs',
    'shadow_suite' => 'suites/dbx_shadow_pg.rs',
    'adapter_manifest' => 'adapter/Cargo.toml',
    'engine_feature' => 'engine/Cargo.toml',
    'conformance_wiring' => 'conformance/Cargo.toml'
  }.freeze

  def setup
    @tmp = Dir.mktmpdir('pg-dbx-applicability-')
    @root = File.join(@tmp, 'source')
    FileUtils.mkdir_p(@root)
    @manifest = File.join(@tmp, 'manifest.json')
    @catalog = File.join(@tmp, 'catalog.json')
    File.write(@catalog, JSON.generate(JSON.parse(P::DEFAULT_CATALOG_JSON)))
    write_manifest
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def write_manifest(overrides = {})
    manifest = {
      'schema_version' => 1,
      'engine' => 'pg-dbx',
      'suite_ids' => P::PG_DBX_SUITES,
      'markers' => P::MARKER_IDS.map do |id|
        { 'id' => id, 'path' => MARKER_PATHS.fetch(id) }
      end
    }.merge(overrides)
    File.write(@manifest, JSON.generate(manifest))
  end

  def write_marker(id, content = '')
    relative = MARKER_PATHS.fetch(id)
    write_marker_at(relative, content)
  end

  def write_marker_at(relative, content)
    path = File.join(@root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, content)
  end

  def complete_markers
    write_marker('live_suite', '# live suite fixture')
    write_marker('shadow_suite', '# shadow suite fixture')
    write_marker('adapter_manifest', "[package]\nname = \"taurine-db-dbx\"\n")
    write_marker('engine_feature', "[features]\ndbx-pg = [\"taurine-db-dbx\"]\n")
    write_marker('conformance_wiring', "[dev-dependencies]\ntaurine-db-engine = { path = \"../engine\", features = [\"dbx-pg\"] }\ntaurine-db-dbx = { path = \"../adapter\" }\n")
  end

  def evaluate
    P.evaluate(source_root: @root, manifest_path: @manifest, catalog_path: @catalog)
  end

  def test_embedded_catalog_is_valid_and_matches_proposal_contract
    catalog = JSON.parse(P::DEFAULT_CATALOG_JSON)
    proposal = File.read(File.expand_path('../../docs/pg-dbx-applicability-proposal.md', __dir__))
    catalog_block = proposal.match(/```json\n(.*?)\n```/m)

    refute_nil catalog_block
    assert_equal catalog, JSON.parse(catalog_block[1])
    assert_equal 12, catalog.fetch('registered_engine_ids').length
    assert_equal 11, catalog.fetch('baseline_non_waivable_engine_ids').length
    assert_equal 'owner_decision_required', catalog.dig('pg_dbx', 'proposed_applicability_requirement')
  end

  def test_missing_markers_report_unavailable_without_execution_or_admission
    result = evaluate

    assert_equal 'unavailable_stage2_proof', result['status']
    assert_equal 0, result['markers_observed']
    assert_equal 0, result['markers_invalid']
    assert_equal 5, result['markers_required']
    assert_equal 'not_run', result['execution_result']
    assert_equal 'not_evaluated', result['admission_result']
    refute result.key?('pass')
  end

  def test_partial_markers_fail_closed
    write_marker('live_suite', '# live suite fixture')
    write_marker('adapter_manifest', "[package]\nname = \"taurine-db-dbx\"\n")

    result = evaluate

    assert_equal 'partial_or_inconsistent', result['status']
    assert_equal 2, result['markers_observed']
    assert_equal 0, result['markers_invalid']
    assert_equal 'not_run', result['execution_result']
    assert_equal 'not_evaluated', result['admission_result']
  end

  def test_all_markers_report_candidates_only
    complete_markers

    result = evaluate

    assert_equal 'candidates_present', result['status']
    assert_equal 5, result['markers_observed']
    assert_equal 0, result['markers_invalid']
    assert_equal 'not_run', result['execution_result']
    assert_equal 'not_evaluated', result['admission_result']
    refute result.key?('pass')
    refute_includes P.render(result), @tmp
  end

  def test_present_but_malformed_markers_are_invalid_not_unavailable
    malformed_paths = MARKER_PATHS.merge(
      'live_suite' => 'suites/live-suite-wrong-name.rs',
      'shadow_suite' => 'suites/shadow-suite-wrong-name.rs'
    )
    manifest = JSON.parse(File.read(@manifest))
    manifest['markers'].each do |marker|
      marker['path'] = malformed_paths.fetch(marker['id'])
    end
    File.write(@manifest, JSON.generate(manifest))

    write_marker_at(malformed_paths.fetch('live_suite'), '# present, wrong marker name')
    write_marker_at(malformed_paths.fetch('shadow_suite'), '# present, wrong marker name')
    write_marker('adapter_manifest', "[package]\nname = \"wrong-package\"\n")
    write_marker('engine_feature', "[features]\n\xFF".b)
    write_marker('conformance_wiring', "[dev-dependencies]\n")

    result = evaluate

    assert_equal 'invalid_evidence', result['status']
    assert_equal 0, result['markers_observed']
    assert_equal 5, result['markers_invalid']
    refute_includes P.render(result), @tmp
    refute_includes P.render(result), 'wrong-package'
  end

  def test_one_present_corrupt_manifest_is_not_reported_as_absence
    write_marker('adapter_manifest', "[package]\nname = \"wrong-package\"\n")

    result = evaluate

    assert_equal 'invalid_evidence', result['status']
    assert_equal 0, result['markers_observed']
    assert_equal 1, result['markers_invalid']
  end

  def test_malformed_and_oversized_manifests_are_rejected_without_details
    File.write(@manifest, '{"schema_version":')
    malformed = evaluate
    assert_equal 'invalid_manifest', malformed['status']

    File.write(@manifest, ' ' * (P::MAX_MANIFEST_BYTES + 1))
    oversized = evaluate
    assert_equal 'invalid_manifest', oversized['status']
    refute_includes P.render(oversized), @tmp
  end

  def test_unknown_engine_is_rejected
    write_manifest('engine' => 'unknown-engine')

    result = evaluate

    assert_equal 'unknown_engine', result['status']
    assert_equal 'not_run', result['execution_result']
    refute_includes P.render(result), 'unknown-engine'
  end

  def test_wrong_suite_roster_is_rejected
    write_manifest('suite_ids' => ['dbx_pg_live'])

    assert_equal 'roster_mismatch', evaluate['status']
  end

  def test_known_but_unsupported_engine_is_rejected
    write_manifest('engine' => 'postgres')

    result = evaluate

    assert_equal 'unsupported_engine', result['status']
    refute_includes P.render(result), 'postgres'
  end

  def test_manifest_cannot_supply_commands_or_skip_selectors
    write_manifest('commands' => ['cargo test'], 'skip_suites' => ['dbx_shadow_pg'])

    assert_equal 'invalid_manifest', evaluate['status']
  end

  def test_baseline_or_roster_catalog_mismatch_is_rejected
    catalog = JSON.parse(File.read(@catalog))
    catalog['baseline_non_waivable_engine_ids'].pop
    File.write(@catalog, JSON.generate(catalog))

    result = evaluate

    assert_equal 'catalog_mismatch', result['status']
    assert_equal 0, result['markers_observed']

    File.write(@catalog, JSON.generate(JSON.parse(P::DEFAULT_CATALOG_JSON)))
    catalog = JSON.parse(File.read(@catalog))
    catalog['registered_engine_ids'].delete('pg-dbx')
    File.write(@catalog, JSON.generate(catalog))

    assert_equal 'catalog_mismatch', evaluate['status']
  end

  def test_duplicate_json_keys_are_rejected
    File.write(@manifest, '{"schema_version":1,"schema_version":1}')

    assert_equal 'invalid_manifest', evaluate['status']
  end

  def test_symlinked_marker_directory_is_rejected
    external = File.join(@tmp, 'outside')
    FileUtils.mkdir_p(external)
    File.write(File.join(external, 'dbx_pg_live.rs'), '# outside')
    File.symlink(external, File.join(@root, 'suites'))

    result = evaluate

    assert_equal 'invalid_evidence', result['status']
    refute_includes P.render(result), @tmp
  end

  def test_symlinked_marker_file_is_rejected
    outside = File.join(@tmp, 'outside.rs')
    File.write(outside, '# outside')
    link = File.join(@root, 'suites')
    FileUtils.mkdir_p(link)
    File.symlink(outside, File.join(link, 'dbx_pg_live.rs'))

    assert_equal 'invalid_evidence', evaluate['status']
  end

  def test_parent_traversal_is_rejected
    paths = MARKER_PATHS.transform_values { |path| path }
    paths['live_suite'] = '../outside/dbx_pg_live.rs'
    manifest = JSON.parse(File.read(@manifest))
    manifest['markers'].each { |marker| marker['path'] = paths.fetch(marker['id']) }
    File.write(@manifest, JSON.generate(manifest))

    assert_equal 'invalid_manifest', evaluate['status']
  end

  def test_catalog_does_not_allow_readiness_to_become_execution_pass
    catalog = JSON.parse(File.read(@catalog))
    catalog['pg_dbx']['readiness'] = 'pass'
    File.write(@catalog, JSON.generate(catalog))
    complete_markers

    result = evaluate

    assert_equal 'catalog_mismatch', result['status']
    assert_equal 'not_run', result['execution_result']
    assert_equal 'not_evaluated', result['admission_result']
  end

  def test_output_schema_is_fixed_and_contains_only_statuses_and_counts
    complete_markers
    result = evaluate

    assert_equal P::OUTPUT_KEYS, result.keys
    assert_equal 12, result['registered_count']
    assert_equal 12, result['current_required_count']
    assert_equal 11, result['baseline_count']
    refute_includes P.render(result), @root
    refute_includes P.render(result), 'Cargo.toml'
  end

  def test_cli_exit_code_cannot_be_used_as_a_passing_gate
    script = File.expand_path('pg-dbx-applicability.rb', __dir__)
    stdout, _stderr, process = Open3.capture3(
      RbConfig.ruby, script, '--source-root', @root, '--manifest', @manifest, '--catalog', @catalog
    )

    assert_equal P::CLI_EXIT_NON_GATE, process.exitstatus
    assert_equal 'unavailable_stage2_proof', JSON.parse(stdout)['status']
  end
end
