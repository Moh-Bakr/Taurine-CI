#!/usr/bin/env ruby

require 'json'
require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require_relative 'check-live-arm-coverage'

class LiveArmCoverageTest < Minitest::Test
  G = LiveArmCoverage
  REPO_ROOT = File.expand_path('../..', __dir__)
  GUARD = File.join(__dir__, 'check-live-arm-coverage.rb')

  def setup
    @tmp = Dir.mktmpdir('live-arm-coverage-')
    @root = File.join(@tmp, 'tree')
    write_tree
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def entry(arm)
    { 'engine' => arm, 'report' => true, 'blurb' => 'fixture' }
  end

  def write_tree(roster: G::REQUIRED_ARMS.map { |arm| entry(arm) }, options: G::REQUIRED_ARMS,
                 matrix_text: nil, workflow_text: nil)
    FileUtils.mkdir_p(File.join(@root, '.github/workflows'))
    body = JSON.pretty_generate(roster).lines.map { |line| "          #{line}" }.join
    workflow = workflow_text || <<~YAML
      jobs:
        plan:
          steps:
            - run: |
                cat > "${RUNNER_TEMP}/roster.json" <<'TCI_LIVE_ROSTER'
      #{body}
                TCI_LIVE_ROSTER
    YAML
    File.write(File.join(@root, G::WORKFLOW_PATH), workflow)
    matrix = matrix_text || JSON.generate(
      'dispatch_contracts' => { 'workflows' => { G::WORKFLOW_PATH => { 'inputs' => { 'engine' => {
        'options' => options
      } } } } }
    )
    File.write(File.join(@root, G::MATRIX_PATH), matrix)
  end

  def status
    G.evaluate(@root)['status']
  end

  def test_required_set_is_the_full_thirteen_arm_roster
    assert_equal 13, G::REQUIRED_ARMS.length
    assert_equal G::REQUIRED_ARMS.uniq, G::REQUIRED_ARMS
    assert_includes G::REQUIRED_ARMS, 'pg-dbx'
    assert_includes G::REQUIRED_ARMS, 'tls-legacy'
    refute G.const_defined?(:BASELINE_ENGINES), 'no waivable subset may exist'
  end

  def test_the_real_repository_passes
    report = G.evaluate(REPO_ROOT)
    assert_equal 'ok', report['status'], report.inspect
    assert_equal [13, 13, 13], report.values_at('required_count', 'registered_count', 'contract_count')
    assert_empty report['missing']
    assert_empty report['unrequired']
  end

  def test_a_complete_fixture_passes
    assert_equal 'ok', status
  end

  def test_removing_any_single_arm_from_the_roster_is_refused
    G::REQUIRED_ARMS.each do |arm|
      write_tree(roster: (G::REQUIRED_ARMS - [arm]).map { |a| entry(a) })
      report = G.evaluate(@root)
      assert_equal 'roster_mismatch', report['status'], arm
      assert_equal [arm], report['missing']
    end
  end

  def test_removing_any_single_arm_from_the_dispatch_contract_is_refused
    G::REQUIRED_ARMS.each do |arm|
      write_tree(options: G::REQUIRED_ARMS - [arm])
      report = G.evaluate(@root)
      assert_equal 'contract_mismatch', report['status'], arm
      assert_equal [arm], report['missing']
    end
  end

  def test_a_registered_but_unrequired_arm_is_refused
    write_tree(roster: (G::REQUIRED_ARMS + ['newarm']).map { |a| entry(a) })
    report = G.evaluate(@root)
    assert_equal 'roster_mismatch', report['status']
    assert_equal ['newarm'], report['unrequired']
  end

  def test_an_extra_contract_option_is_refused
    write_tree(options: G::REQUIRED_ARMS + ['newarm'])
    report = G.evaluate(@root)
    assert_equal 'contract_mismatch', report['status']
    assert_equal ['newarm'], report['unrequired']
  end

  def test_the_stale_twelve_arm_roster_is_refused_in_both_places
    twelve = G::REQUIRED_ARMS - ['tls-legacy']
    write_tree(roster: twelve.map { |a| entry(a) })
    assert_equal 'roster_mismatch', status
    write_tree(options: twelve)
    assert_equal 'contract_mismatch', status
  end

  def test_a_duplicate_arm_entry_is_refused_even_when_the_set_matches
    write_tree(roster: (G::REQUIRED_ARMS + ['pg-dbx']).map { |a| entry(a) })
    assert_equal 'duplicate_arm', status
  end

  def test_an_entry_key_that_could_waive_an_arm_is_refused
    %w[required optional skip waive continue-on-error if enabled].each do |key|
      roster = G::REQUIRED_ARMS.map { |a| entry(a) }
      roster[7] = roster[7].merge(key => false)
      write_tree(roster: roster)
      assert_equal 'unknown_roster_key', status, key
    end
  end

  def test_the_order_of_arms_does_not_matter_but_the_set_does
    write_tree(roster: G::REQUIRED_ARMS.reverse.map { |a| entry(a) }, options: G::REQUIRED_ARMS.reverse)
    assert_equal 'ok', status
  end

  def test_a_malformed_arm_identifier_is_invalid_input
    ['PG-DBX', 'pg_dbx', '', '-pg', "pg-dbx\n", 7, nil].each do |bad|
      roster = G::REQUIRED_ARMS.map { |a| entry(a) }
      roster[7]['engine'] = bad
      write_tree(roster: roster)
      assert_equal 'invalid_input', status, bad.inspect
    end
  end

  def test_duplicate_json_keys_are_rejected
    roster = JSON.generate(G::REQUIRED_ARMS.map { |a| entry(a) }).sub('"report":true', '"report":true,"report":false')
    write_tree(workflow_text: <<~YAML)
      cat > "${RUNNER_TEMP}/roster.json" <<'TCI_LIVE_ROSTER'
      #{roster}
      TCI_LIVE_ROSTER
    YAML
    assert_equal 'invalid_input', status

    write_tree(matrix_text: '{"dispatch_contracts":{},"dispatch_contracts":{}}')
    assert_equal 'invalid_input', status
  end

  def test_a_missing_or_repeated_roster_block_is_invalid_input
    write_tree(workflow_text: "jobs: {}\n")
    assert_equal 'invalid_input', status

    block = "cat > \"${RUNNER_TEMP}/roster.json\" <<'TCI_LIVE_ROSTER'\n[]\nTCI_LIVE_ROSTER\n"
    write_tree(workflow_text: block + block)
    assert_equal 'invalid_input', status

    write_tree(workflow_text: "cat > \"${RUNNER_TEMP}/roster.json\" <<'TCI_LIVE_ROSTER'\n[]\n")
    assert_equal 'invalid_input', status
  end

  def test_a_roster_that_is_not_a_list_of_objects_is_invalid_input
    write_tree(workflow_text: "cat > \"${RUNNER_TEMP}/roster.json\" <<'TCI_LIVE_ROSTER'\n{}\nTCI_LIVE_ROSTER\n")
    assert_equal 'invalid_input', status
    write_tree(workflow_text: "cat > \"${RUNNER_TEMP}/roster.json\" <<'TCI_LIVE_ROSTER'\n[1]\nTCI_LIVE_ROSTER\n")
    assert_equal 'invalid_input', status
  end

  def test_a_missing_contract_path_is_invalid_input
    write_tree(matrix_text: '{"dispatch_contracts":{"workflows":{}}}')
    assert_equal 'invalid_input', status
    write_tree(matrix_text: '[]')
    assert_equal 'invalid_input', status
  end

  def test_excess_nesting_is_rejected
    write_tree(matrix_text: ('[' * 40) + (']' * 40))
    assert_equal 'invalid_input', status
  end

  def test_oversized_inputs_are_refused
    write_tree(matrix_text: ' ' * (G::MAX_MATRIX_BYTES + 1))
    assert_equal 'unsafe_input', status
    write_tree(workflow_text: ' ' * (G::MAX_WORKFLOW_BYTES + 1))
    assert_equal 'unsafe_input', status
  end

  def test_symlinked_inputs_and_roots_are_refused
    write_tree
    real = File.join(@tmp, 'real-matrix.json')
    FileUtils.mv(File.join(@root, G::MATRIX_PATH), real)
    File.symlink(real, File.join(@root, G::MATRIX_PATH))
    assert_equal 'unsafe_input', status

    write_tree
    link = File.join(@tmp, 'root-link')
    File.symlink(@root, link)
    assert_equal 'unsafe_input', G.evaluate(link)['status']
  end

  def test_missing_files_and_roots_are_refused
    FileUtils.rm(File.join(@root, G::MATRIX_PATH))
    assert_equal 'unsafe_input', status
    assert_equal 'unsafe_input', G.evaluate(File.join(@tmp, 'absent'))['status']
  end

  def test_invalid_utf8_is_refused
    File.binwrite(File.join(@root, G::MATRIX_PATH), "{\"a\":\"\xff\"}")
    assert_equal 'unsafe_input', status
  end

  def run_guard(*args)
    Open3.capture3(RbConfig.ruby, GUARD, *args)
  end

  def test_the_cli_exits_zero_only_for_ok
    out, _err, status = run_guard(@root)
    assert_equal 0, status.exitstatus
    assert_equal 'ok', JSON.parse(out)['status']

    write_tree(roster: (G::REQUIRED_ARMS - ['pg-dbx']).map { |a| entry(a) })
    out, _err, status = run_guard(@root)
    assert_equal 1, status.exitstatus
    report = JSON.parse(out)
    assert_equal 'roster_mismatch', report['status']
    assert_equal ['pg-dbx'], report['missing']

    out, _err, status = run_guard(@root, 'extra')
    assert_equal 1, status.exitstatus
    assert_equal 'invalid_input', JSON.parse(out)['status']
  end

  def test_the_report_exposes_only_fixed_fields_and_no_paths
    out, _err, _status = run_guard(@root)
    assert_equal %w[status required_count registered_count contract_count missing unrequired].sort,
                 JSON.parse(out).keys.sort
    refute_includes out, @tmp
  end
end
