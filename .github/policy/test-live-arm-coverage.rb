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
    base = { 'engine' => arm, 'report' => true, 'blurb' => 'fixture' }
    rows = G::REQUIRED_SUITE_ROWS[arm]
    rows ? base.merge('suites' => ['taurine-db-postgres live_catalog'] + rows) : base
  end

  def write_tree(roster: G::REQUIRED_ARMS.map { |arm| entry(arm) }, options: G::REQUIRED_ARMS,
                 matrix_text: nil, workflow_text: nil)
    FileUtils.rm_rf(@root)
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

  def test_required_set_is_the_full_twelve_arm_roster
    assert_equal 12, G::REQUIRED_ARMS.length
    assert_equal G::REQUIRED_ARMS.uniq, G::REQUIRED_ARMS
    refute_includes G::REQUIRED_ARMS, 'pg-dbx' # merged into the postgres arm
    assert_includes G::REQUIRED_ARMS, 'postgres'
    assert_includes G::REQUIRED_ARMS, 'tls-legacy'
    refute G.const_defined?(:BASELINE_ENGINES), 'no waivable subset may exist'
  end

  def test_the_real_repository_passes
    report = G.evaluate(REPO_ROOT)
    assert_equal 'ok', report['status'], report.inspect
    assert_equal [12, 12, 12], report.values_at('required_count', 'registered_count', 'contract_count')
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

  DBX_ROW = 'taurine-db-conformance dbx_pg_live,dbx_shadow_pg'.freeze

  def postgres_with(suites)
    G::REQUIRED_ARMS.map { |a| a == 'postgres' ? entry(a).merge('suites' => suites) : entry(a) }
  end

  def test_the_postgres_arm_must_carry_the_dbx_evidence_row
    assert_equal [DBX_ROW], G::REQUIRED_SUITE_ROWS['postgres']
    # Mutation: the whole row removed (the merged-away arm's evidence disappears).
    write_tree(roster: postgres_with(['taurine-db-postgres live_catalog']))
    report = G.evaluate(@root)
    assert_equal 'missing_evidence_row', report['status']
    assert_includes report['reason'], DBX_ROW
    # Mutation: no suites at all, or a suites key that is not a list.
    write_tree(roster: G::REQUIRED_ARMS.map { |a| a == 'postgres' ? entry(a).tap { |e| e.delete('suites') } : entry(a) })
    assert_equal 'missing_evidence_row', status
    write_tree(roster: postgres_with('not a list'))
    assert_equal 'missing_evidence_row', status
    # Control: the real shape passes.
    write_tree(roster: postgres_with(['taurine-db-postgres live_catalog', DBX_ROW]))
    assert_equal 'ok', status
  end

  def test_dropping_either_dbx_target_or_making_it_optional_is_refused
    [
      'taurine-db-conformance dbx_pg_live',                       # shadow row dropped
      'taurine-db-conformance dbx_shadow_pg',                     # live row dropped
      'taurine-db-conformance dbx_pg_live,dbx_shadow_pg dbx_x',   # narrowed by a name filter
      'taurine-db-conformance dbx_shadow_pg,dbx_pg_live'          # renamed row
    ].each do |row|
      write_tree(roster: postgres_with(['taurine-db-postgres live_catalog', row]))
      assert_equal 'missing_evidence_row', status, row
    end
    # A duplicated row is refused too: the row is counted exactly once.
    write_tree(roster: postgres_with([DBX_ROW, DBX_ROW]))
    assert_equal 'missing_evidence_row', status
    # An entry flag that makes the dbx part optional is already an unknown key.
    roster = postgres_with([DBX_ROW])
    roster[G::REQUIRED_ARMS.index('postgres')]['optional'] = true
    write_tree(roster: roster)
    assert_equal 'unknown_roster_key', status
  end

  def test_pg_dbx_is_no_longer_a_dispatchable_arm
    write_tree(roster: G::REQUIRED_ARMS.map { |a| entry(a) } + [entry('pg-dbx')])
    assert_equal 'roster_mismatch', status
    write_tree(options: G::REQUIRED_ARMS + ['pg-dbx'])
    assert_equal 'contract_mismatch', status
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
    write_tree(roster: (G::REQUIRED_ARMS + ['mysql']).map { |a| entry(a) })
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
    ['PG-DBX', 'pg_dbx', '', '-pg', "mysql\n", 7, nil].each do |bad|
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

    write_tree(roster: (G::REQUIRED_ARMS - ['mysql']).map { |a| entry(a) })
    out, _err, status = run_guard(@root)
    assert_equal 1, status.exitstatus
    report = JSON.parse(out)
    assert_equal 'roster_mismatch', report['status']
    assert_equal ['mysql'], report['missing']

    out, _err, status = run_guard(@root, 'extra')
    assert_equal 1, status.exitstatus
    assert_equal 'invalid_input', JSON.parse(out)['status']
  end

  def test_the_report_exposes_only_fixed_fields_and_no_paths
    out, _err, _status = run_guard(@root)
    assert_equal %w[status required_count registered_count contract_count missing unrequired reason].sort,
                 JSON.parse(out).keys.sort
    refute_includes out, @tmp
    FileUtils.rm(File.join(@root, G::MATRIX_PATH))
    out, _err, _status = run_guard(@root)
    refute_includes out, @tmp
  end

  # Input failures must not read as coverage loss: empty arm lists and a reason that names the file
  # and the cause. Every one of them still fails closed.
  def assert_input_failure(expected_status, expected_reason)
    report = G.evaluate(@root)
    assert_equal expected_status, report['status'], report.inspect
    assert_equal expected_reason, report['reason']
    assert_empty report['missing'], 'an input failure must not list arms as missing'
    assert_empty report['unrequired']
    assert_equal 0, report['registered_count']
    assert_equal 0, report['contract_count']
  end

  def test_input_failures_name_the_file_and_the_cause_without_listing_arms_as_missing
    write_tree(workflow_text: "jobs: {}\n")
    assert_input_failure 'invalid_input', 'live-proofs.yml: no roster marker'

    block = "cat > \"${RUNNER_TEMP}/roster.json\" <<'TCI_LIVE_ROSTER'\n[]\nTCI_LIVE_ROSTER\n"
    write_tree(workflow_text: block + block)
    assert_input_failure 'invalid_input', 'live-proofs.yml: more than one roster marker'

    write_tree(workflow_text: "cat > \"${RUNNER_TEMP}/roster.json\" <<'TCI_LIVE_ROSTER'\n[]\n")
    assert_input_failure 'invalid_input', 'live-proofs.yml: roster block is not terminated'

    write_tree(workflow_text: "cat > \"${RUNNER_TEMP}/roster.json\" <<'TCI_LIVE_ROSTER'\n{\nTCI_LIVE_ROSTER\n")
    assert_input_failure 'invalid_input', 'live-proofs.yml: malformed JSON'

    write_tree(workflow_text: "cat > \"${RUNNER_TEMP}/roster.json\" <<'TCI_LIVE_ROSTER'\n{}\nTCI_LIVE_ROSTER\n")
    assert_input_failure 'invalid_input', 'live-proofs.yml: roster is not a list of objects'

    write_tree(workflow_text: "cat > \"${RUNNER_TEMP}/roster.json\" <<'TCI_LIVE_ROSTER'\n[{\"engine\":\"PG\"}]\nTCI_LIVE_ROSTER\n")
    assert_input_failure 'invalid_input', 'live-proofs.yml: roster entry without a valid engine id'

    write_tree(matrix_text: '{"dispatch_contracts":{"workflows":{}}}')
    assert_input_failure 'invalid_input', 'ci-matrix.json: no live-proofs engine options'

    write_tree(matrix_text: '{')
    assert_input_failure 'invalid_input', 'ci-matrix.json: malformed JSON'

    write_tree(matrix_text: ('[' * 40) + (']' * 40))
    assert_input_failure 'invalid_input', 'ci-matrix.json: JSON nested too deeply'

    write_tree(matrix_text: '{"a":1,"a":2}')
    assert_match(/\Aci-matrix\.json: (duplicate JSON key|malformed JSON)\z/, G.evaluate(@root)['reason'])
    assert_equal 'invalid_input', status
  end

  def test_unsafe_input_failures_name_the_file_and_the_cause
    write_tree(matrix_text: ' ' * (G::MAX_MATRIX_BYTES + 1))
    assert_input_failure 'unsafe_input', 'ci-matrix.json: too large'

    write_tree(workflow_text: ' ' * (G::MAX_WORKFLOW_BYTES + 1))
    assert_input_failure 'unsafe_input', 'live-proofs.yml: too large'

    write_tree
    File.binwrite(File.join(@root, G::MATRIX_PATH), "{\"a\":\"\xff\"}")
    assert_input_failure 'unsafe_input', 'ci-matrix.json: not valid UTF-8'

    FileUtils.rm(File.join(@root, G::MATRIX_PATH))
    assert_input_failure 'unsafe_input', 'ci-matrix.json: unreadable'

    write_tree
    real = File.join(@tmp, 'real-workflow.yml')
    FileUtils.mv(File.join(@root, G::WORKFLOW_PATH), real)
    File.symlink(real, File.join(@root, G::WORKFLOW_PATH))
    assert_input_failure 'unsafe_input', 'live-proofs.yml: symlink'

    write_tree
    File.delete(File.join(@root, G::MATRIX_PATH))
    Dir.mkdir(File.join(@root, G::MATRIX_PATH))
    assert_input_failure 'unsafe_input', 'ci-matrix.json: not a regular file'

    link = File.join(@tmp, 'root-link')
    File.symlink(@root, link)
    report = G.evaluate(link)
    assert_equal ['unsafe_input', 'repository root: symlink'], report.values_at('status', 'reason')
    report = G.evaluate(File.join(@tmp, 'absent'))
    assert_equal ['unsafe_input', 'repository root: unreadable'], report.values_at('status', 'reason')
    File.write(File.join(@tmp, 'plain-file'), '')
    report = G.evaluate(File.join(@tmp, 'plain-file'))
    assert_equal ['unsafe_input', 'repository root: not a directory'], report.values_at('status', 'reason')
  end

  def test_unknown_roster_key_names_the_key_and_the_arm
    roster = G::REQUIRED_ARMS.map { |a| entry(a) }
    roster[7] = roster[7].merge('optional' => true)
    write_tree(roster: roster)
    report = G.evaluate(@root)
    assert_equal 'unknown_roster_key', report['status']
    assert_equal "live-proofs.yml: key 'optional' in arm 'mysql'", report['reason']
    assert_equal [12, 12], report.values_at('registered_count', 'contract_count')

    roster[7] = entry('mysql').merge("bad key\n::error::" => 1)
    write_tree(roster: roster)
    assert_equal "live-proofs.yml: key '(unprintable)' in arm 'mysql'", G.evaluate(@root)['reason']
  end

  def test_comparison_failures_still_list_the_arms_and_say_where
    write_tree(roster: (G::REQUIRED_ARMS - ['mysql']).map { |a| entry(a) })
    report = G.evaluate(@root)
    assert_equal ['roster_mismatch', ['mysql'], 'live-proofs.yml: roster differs from the required set'],
                 report.values_at('status', 'missing', 'reason')

    write_tree(options: G::REQUIRED_ARMS - ['tls-legacy'])
    report = G.evaluate(@root)
    assert_equal ['contract_mismatch', ['tls-legacy'], 'ci-matrix.json: engine options differ from the required set'],
                 report.values_at('status', 'missing', 'reason')

    write_tree(roster: (G::REQUIRED_ARMS + ['mysql']).map { |a| entry(a) })
    assert_equal 'live-proofs.yml: repeated arm mysql', G.evaluate(@root)['reason']
  end

  def test_the_cli_reports_a_usage_error_with_a_reason
    out, _err, status = run_guard(@root, 'extra')
    assert_equal 1, status.exitstatus
    report = JSON.parse(out)
    assert_equal 'usage: at most one repository root argument', report['reason']
    assert_empty report['missing']
  end
end
