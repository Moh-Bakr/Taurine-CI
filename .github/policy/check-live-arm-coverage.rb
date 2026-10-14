#!/usr/bin/env ruby
# Live-arm coverage drift guard. Every registered live-proof arm must be a required arm, and every
# required arm must be registered, so coverage cannot shrink by registering an arm and forgetting to
# require it, or by dropping one. It reads only this repository's own control-plane files, never
# private source, and gives no source input any say over the required set.
#
#   ruby .github/policy/check-live-arm-coverage.rb [repository-root]
#
# Exit 0 only when the status is `ok`; every other outcome exits 1.

require 'json'
require 'pathname'

module LiveArmCoverage
  class InvalidInput < StandardError; end
  class UnsafeInput < StandardError; end

  class DuplicateKeyHash < Hash
    def []=(key, value)
      raise InvalidInput if key?(key)

      super
    end
  end

  # The complete required set. There is no waivable subset: `all` requires every registered arm,
  # including `pg-dbx` (Dbx-route live proof) and `tls-legacy`. Changing this list is a reviewed
  # policy change, and the base commit's copy of this check runs against the pull request.
  REQUIRED_ARMS = %w[
    doris starrocks db2 informix rocketmq iris postgres pg-dbx mysql mssql pgtls tls-legacy bastion
  ].freeze

  WORKFLOW_PATH = '.github/workflows/live-proofs.yml'.freeze
  MATRIX_PATH = '.github/ci-matrix.json'.freeze
  ROSTER_BEGIN = %r{\A\s*cat > "\$\{RUNNER_TEMP\}/roster\.json" <<'TCI_LIVE_ROSTER'\s*\z}
  ROSTER_END = 'TCI_LIVE_ROSTER'.freeze
  # A roster entry may carry only these keys, so no entry can hold a flag that makes its arm
  # optional, skipped or waivable without this check being reviewed first.
  ENTRY_KEYS = %w[engine target filter report blurb suites cargo_features].freeze
  ARM_ID = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/

  MAX_WORKFLOW_BYTES = 512 * 1024
  MAX_MATRIX_BYTES = 512 * 1024
  MAX_ROSTER_BYTES = 64 * 1024
  MAX_NESTING = 16
  EXIT_FAIL = 1

  module_function

  def read_regular_file(root, relative, limit)
    path = File.join(root, relative)
    stat = File.lstat(path)
    raise UnsafeInput unless stat.file? && !stat.symlink? && stat.size <= limit

    bytes = File.binread(path, limit + 1)
    raise UnsafeInput if bytes.bytesize > limit

    text = bytes.force_encoding(Encoding::UTF_8)
    raise UnsafeInput unless text.valid_encoding?

    text
  rescue SystemCallError, IOError
    raise UnsafeInput
  end

  def parse_json(text)
    JSON.parse(text, object_class: DuplicateKeyHash, max_nesting: MAX_NESTING, allow_nan: false,
                     allow_duplicate_key: false)
  rescue JSON::ParserError, EncodingError, ArgumentError
    raise InvalidInput
  end

  def repository_root(path)
    stat = File.lstat(path)
    raise UnsafeInput unless stat.directory? && !stat.symlink?

    File.realpath(path)
  rescue SystemCallError
    raise UnsafeInput
  end

  # The roster is the single JSON heredoc the plan job writes; its text is the executed roster.
  def roster_entries(workflow_text)
    lines = workflow_text.lines
    begins = lines.each_index.select { |i| lines[i].match?(ROSTER_BEGIN) }
    raise InvalidInput unless begins.length == 1

    start = begins.first + 1
    finish = lines.each_index.select { |i| i >= start && lines[i].strip == ROSTER_END }.first
    raise InvalidInput unless finish

    body = lines[start...finish].join
    raise InvalidInput if body.bytesize > MAX_ROSTER_BYTES

    entries = parse_json(body)
    raise InvalidInput unless entries.is_a?(Array) && entries.all? { |entry| entry.is_a?(Hash) }

    entries
  end

  def unknown_keys?(entries)
    entries.any? { |entry| !(entry.keys - ENTRY_KEYS).empty? }
  end

  def registered_arms(entries)
    arms = entries.map { |entry| entry['engine'] }
    raise InvalidInput unless arms.all? { |arm| arm.is_a?(String) && arm.match?(ARM_ID) }

    arms
  end

  def contract_arms(matrix)
    options = matrix.dig('dispatch_contracts', 'workflows', WORKFLOW_PATH, 'inputs', 'engine', 'options')
    raise InvalidInput unless options.is_a?(Array) && options.all? { |arm| arm.is_a?(String) }

    options
  rescue NoMethodError, TypeError
    raise InvalidInput
  end

  def report(status, registered: [], contract: [], subject: registered)
    {
      'status' => status,
      'required_count' => REQUIRED_ARMS.length,
      'registered_count' => registered.length,
      'contract_count' => contract.length,
      'missing' => REQUIRED_ARMS - subject,
      'unrequired' => subject.uniq - REQUIRED_ARMS
    }
  end

  def evaluate(root)
    real = repository_root(root)
    entries = roster_entries(read_regular_file(real, WORKFLOW_PATH, MAX_WORKFLOW_BYTES))
    registered = registered_arms(entries)
    contract = contract_arms(parse_json(read_regular_file(real, MATRIX_PATH, MAX_MATRIX_BYTES)))

    return report('unknown_roster_key', registered: registered, contract: contract) if unknown_keys?(entries)
    return report('duplicate_arm', registered: registered, contract: contract) unless registered.uniq == registered
    return report('roster_mismatch', registered: registered, contract: contract) unless registered.sort == REQUIRED_ARMS.sort
    return report('contract_mismatch', registered: registered, contract: contract, subject: contract) unless contract.sort == REQUIRED_ARMS.sort

    report('ok', registered: registered, contract: contract)
  rescue UnsafeInput
    report('unsafe_input')
  rescue InvalidInput
    report('invalid_input')
  end

  def cli(argv)
    return report('invalid_input') unless argv.length <= 1

    evaluate(argv.first || '.')
  rescue StandardError
    report('invalid_input')
  end
end

if $PROGRAM_NAME == __FILE__
  result = LiveArmCoverage.cli(ARGV)
  puts JSON.generate(result)
  exit(result['status'] == 'ok' ? 0 : LiveArmCoverage::EXIT_FAIL)
end
