#!/usr/bin/env ruby
# Live-arm coverage drift guard. It checks that the roster block declared in live-proofs.yml and the
# live-proofs dispatch-contract options in ci-matrix.json each equal one explicit required set, and
# that roster entries carry only reviewed keys. It reads those two files as text and JSON, never
# private source, and gives no source input any say over the required set.
#
# It does not execute or interpret the workflow, so it cannot see how the declared roster is used
# afterwards: a filter applied to the roster after it is written, a matrix include/exclude on the
# prove job, or a job condition. Existing checks cover some of those; the prove job's matrix shape
# is not yet pinned (see docs/live-arm-coverage-guard.md).
#
#   ruby .github/policy/check-live-arm-coverage.rb [repository-root]
#
# Exit 0 only when the status is `ok`; every other outcome exits 1.

require 'json'

module LiveArmCoverage
  # Both carry a fixed-vocabulary message that names the file and the cause, never file contents.
  class InvalidInput < StandardError; end
  class UnsafeInput < StandardError; end

  class DuplicateKeyHash < Hash
    def []=(key, value)
      raise KeyError if key?(key)

      super
    end
  end

  # The complete required set. There is no waivable subset: `all` requires every registered arm,
  # including `tls-legacy`. The set has two reviewed shapes while the `pg-dbx` arm is merged into
  # `postgres`; any other roster is refused. Changing either list is a reviewed policy change, and the
  # base commit's copy of this check runs against the pull request.
  #
  # MERGED_ARMS is the end state: the Dbx-route live proof is the `postgres` arm's own evidence row
  # (REQUIRED_SUITE_ROWS), so `pg-dbx` is not an arm. LEGACY_ARMS is the shape before the merge, kept
  # only so the tree that predates it still passes; it goes once nothing registers `pg-dbx`.
  MERGED_ARMS = %w[
    doris starrocks db2 informix rocketmq iris postgres mysql mssql pgtls tls-legacy bastion
  ].freeze
  LEGACY_ARMS = %w[
    doris starrocks db2 informix rocketmq iris postgres pg-dbx mysql mssql pgtls tls-legacy bastion
  ].freeze
  REQUIRED_ARMS = MERGED_ARMS

  # Evidence rows an arm must keep once `pg-dbx` is merged away, each exactly as the roster writes
  # the suite, so the row the arm's summary prints keeps its name. The Dbx-route proof is two test
  # targets in one suite row; dropping either target, narrowing it with a test-name filter, repeating
  # it or removing the row fails here. The legacy shape has its own `pg-dbx` arm instead and is not
  # held to these rows.
  REQUIRED_SUITE_ROWS = {
    'postgres' => ['taurine-db-conformance dbx_pg_live,dbx_shadow_pg']
  }.freeze

  WORKFLOW_PATH = '.github/workflows/live-proofs.yml'.freeze
  MATRIX_PATH = '.github/ci-matrix.json'.freeze
  WORKFLOW_LABEL = 'live-proofs.yml'.freeze
  MATRIX_LABEL = 'ci-matrix.json'.freeze
  ROSTER_BEGIN = %r{\A\s*cat > "\$\{RUNNER_TEMP\}/roster\.json" <<'TCI_LIVE_ROSTER'\s*\z}
  ROSTER_END = 'TCI_LIVE_ROSTER'.freeze
  # A roster entry may carry only these keys, so no entry can hold a flag that makes its arm
  # optional, skipped or waivable without this check being reviewed first.
  ENTRY_KEYS = %w[engine target filter report blurb suites cargo_features].freeze
  ARM_ID = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
  KEY_NAME = /\A[A-Za-z0-9_.-]{1,40}\z/

  MAX_WORKFLOW_BYTES = 512 * 1024
  MAX_MATRIX_BYTES = 512 * 1024
  MAX_ROSTER_BYTES = 64 * 1024
  MAX_NESTING = 16
  EXIT_FAIL = 1

  module_function

  def read_regular_file(root, relative, label, limit)
    path = File.join(root, relative)
    stat = File.lstat(path)
    raise UnsafeInput, "#{label}: symlink" if stat.symlink?
    raise UnsafeInput, "#{label}: not a regular file" unless stat.file?
    raise UnsafeInput, "#{label}: too large" if stat.size > limit

    bytes = File.binread(path, limit + 1)
    raise UnsafeInput, "#{label}: too large" if bytes.bytesize > limit

    text = bytes.force_encoding(Encoding::UTF_8)
    raise UnsafeInput, "#{label}: not valid UTF-8" unless text.valid_encoding?

    text
  rescue SystemCallError, IOError
    raise UnsafeInput, "#{label}: unreadable"
  end

  def parse_json(text, label)
    JSON.parse(text, object_class: DuplicateKeyHash, max_nesting: MAX_NESTING, allow_nan: false,
                     allow_duplicate_key: false)
  rescue KeyError
    raise InvalidInput, "#{label}: duplicate JSON key"
  rescue JSON::NestingError
    raise InvalidInput, "#{label}: JSON nested too deeply"
  rescue JSON::ParserError, EncodingError, ArgumentError
    raise InvalidInput, "#{label}: malformed JSON"
  end

  def repository_root(path)
    stat = File.lstat(path)
    raise UnsafeInput, 'repository root: symlink' if stat.symlink?
    raise UnsafeInput, 'repository root: not a directory' unless stat.directory?

    File.realpath(path)
  rescue SystemCallError
    raise UnsafeInput, 'repository root: unreadable'
  end

  # The roster is the single JSON heredoc the plan job writes. Only its declared text is read.
  def roster_entries(workflow_text)
    lines = workflow_text.lines
    begins = lines.each_index.select { |i| lines[i].match?(ROSTER_BEGIN) }
    raise InvalidInput, "#{WORKFLOW_LABEL}: no roster marker" if begins.empty?
    raise InvalidInput, "#{WORKFLOW_LABEL}: more than one roster marker" unless begins.length == 1

    start = begins.first + 1
    finish = lines.each_index.select { |i| i >= start && lines[i].strip == ROSTER_END }.first
    raise InvalidInput, "#{WORKFLOW_LABEL}: roster block is not terminated" unless finish

    body = lines[start...finish].join
    raise InvalidInput, "#{WORKFLOW_LABEL}: roster block too large" if body.bytesize > MAX_ROSTER_BYTES

    entries = parse_json(body, WORKFLOW_LABEL)
    unless entries.is_a?(Array) && entries.all? { |entry| entry.is_a?(Hash) }
      raise InvalidInput, "#{WORKFLOW_LABEL}: roster is not a list of objects"
    end

    entries
  end

  def registered_arms(entries)
    entries.map do |entry|
      arm = entry['engine']
      raise InvalidInput, "#{WORKFLOW_LABEL}: roster entry without a valid engine id" unless arm.is_a?(String) && arm.match?(ARM_ID)

      arm
    end
  end

  def unknown_key(entries)
    entries.each do |entry|
      key = (entry.keys - ENTRY_KEYS).first
      next unless key

      return [entry['engine'], key.match?(KEY_NAME) ? key : '(unprintable)']
    end
    nil
  end

  # Returns [arm, row] for the first required evidence row an arm no longer carries, else nil.
  def missing_suite_row(entries)
    REQUIRED_SUITE_ROWS.each do |arm, rows|
      entry = entries.find { |e| e['engine'] == arm }
      suites = entry && entry['suites']
      suites = [] unless suites.is_a?(Array)
      rows.each { |row| return [arm, row] unless suites.count(row) == 1 }
    end
    nil
  end

  def contract_arms(matrix)
    options = matrix.dig('dispatch_contracts', 'workflows', WORKFLOW_PATH, 'inputs', 'engine', 'options')
    unless options.is_a?(Array) && options.all? { |arm| arm.is_a?(String) }
      raise InvalidInput, "#{MATRIX_LABEL}: no live-proofs engine options"
    end

    options
  rescue NoMethodError, TypeError
    raise InvalidInput, "#{MATRIX_LABEL}: no live-proofs engine options"
  end

  # The roster decides which reviewed shape applies, and only the presence of `pg-dbx` selects the
  # legacy one: a roster that has dropped it is held to the merged shape, so it cannot shed the arm
  # and its evidence at once. Neither the contract options nor anything else can pick the shape.
  def required_arms_for(registered)
    registered.include?('pg-dbx') ? LEGACY_ARMS : MERGED_ARMS
  end

  # `missing` and `unrequired` are filled only for statuses that compare two arm lists. Input
  # failures carry empty lists and a `reason`, so a malformed file never reads as "12 arms missing".
  def report(status, registered: [], contract: [], subject: nil, reason: '', required: REQUIRED_ARMS)
    diff = !subject.nil?
    {
      'status' => status,
      'required_count' => required.length,
      'registered_count' => registered.length,
      'contract_count' => contract.length,
      'missing' => diff ? required - subject : [],
      'unrequired' => diff ? subject.uniq - required : [],
      'reason' => reason
    }
  end

  def evaluate(root)
    real = repository_root(root)
    entries = roster_entries(read_regular_file(real, WORKFLOW_PATH, WORKFLOW_LABEL, MAX_WORKFLOW_BYTES))
    registered = registered_arms(entries)
    matrix = parse_json(read_regular_file(real, MATRIX_PATH, MATRIX_LABEL, MAX_MATRIX_BYTES), MATRIX_LABEL)
    contract = contract_arms(matrix)
    required = required_arms_for(registered)
    shared = { registered: registered, contract: contract, required: required }

    if (arm, key = unknown_key(entries))
      return report('unknown_roster_key', **shared, reason: "#{WORKFLOW_LABEL}: key '#{key}' in arm '#{arm}'")
    end
    unless registered.uniq == registered
      repeated = registered.group_by(&:itself).select { |_, group| group.length > 1 }.keys.join(', ')
      return report('duplicate_arm', **shared, reason: "#{WORKFLOW_LABEL}: repeated arm #{repeated}")
    end
    unless registered.sort == required.sort
      return report('roster_mismatch', **shared, subject: registered, reason: "#{WORKFLOW_LABEL}: roster differs from the required set")
    end
    unless contract.sort == required.sort
      return report('contract_mismatch', **shared, subject: contract, reason: "#{MATRIX_LABEL}: engine options differ from the required set")
    end

    if required.equal?(MERGED_ARMS) && (arm, row = missing_suite_row(entries))
      return report('missing_evidence_row', **shared, reason: "#{WORKFLOW_LABEL}: arm '#{arm}' lacks the required suite row '#{row}'")
    end

    report('ok', **shared, subject: registered)
  rescue UnsafeInput => e
    report('unsafe_input', reason: e.message)
  rescue InvalidInput => e
    report('invalid_input', reason: e.message)
  end

  def cli(argv)
    return report('invalid_input', reason: 'usage: at most one repository root argument') unless argv.length <= 1

    evaluate(argv.first || '.')
  rescue StandardError
    report('invalid_input', reason: 'internal error')
  end
end

if $PROGRAM_NAME == __FILE__
  result = LiveArmCoverage.cli(ARGV)
  puts JSON.generate(result)
  exit(result['status'] == 'ok' ? 0 : LiveArmCoverage::EXIT_FAIL)
end
