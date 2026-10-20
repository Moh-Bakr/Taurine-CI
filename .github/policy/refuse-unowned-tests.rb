#!/usr/bin/env ruby
# frozen_string_literal: true

# Fail-fast suite-ownership check for one concern job.
#
# The trusted evidence collector refuses a test with no suite owner (`ownership_unowned`), but it runs
# at the END of a concern job, after the whole build and test run, so a candidate that adds or renames
# a test file without regenerating the ownership manifest is found 25 to 60 minutes late. This script
# runs the same ownership rule on DATA ONLY at the START of the job, in the seconds after the token is
# revoked and root is dropped and before any dependency install or project command:
#
#   - it reads the generated ownership manifest (scripts/ci/suite-ownership.json) as JSON and the
#     tracked file list from `git ls-files` (names only; no test file is opened, parsed or run, and no
#     project script, config, hook or package manager is executed);
#   - every tracked unit or end-to-end test file (a *.test.* or *.spec.* source) must match at least one
#     suite's `include` glob, with exactly the collector's glob semantics (`**` crosses directories,
#     `*` stays within a segment, everything else is literal);
#   - a test file that matches nothing is unowned: the job fails here, within seconds.
#
# Scope, stated plainly. A tracked file list has no base commit, so an "added or renamed" file cannot be
# told from an existing one; the check therefore covers every tracked test file, which is a superset (an
# added or renamed file that the manifest does not cover is unowned, whatever its history). The trees
# that are not in the Linux suites' runners are exempt by reviewed prefix (EXEMPT_PREFIXES below, each
# with its reason); everything else in the repository is in scope, so a new test area fails closed.
# This is an early warning, not the proof: the collector's end-of-job check (which also detects overlap
# between two suites and uses the runner's own discovery) is unchanged and still decides the verdict.
#
# Output. Only fixed words and counts leave this script: the number of test files checked, the number
# without an owner and a reason class. No path, pattern or source text is ever printed. To list the
# files, run the private ownership audit locally.
#
# Usage: ruby refuse-unowned-tests.rb <repo-root>
# Exit 0: every test file is owned. A source with no ownership manifest is refused (reason manifest_missing).
# Exit 1: a test file has no owner, or the manifest is unreadable (fail closed).
require 'json'
require 'open3'

MANIFEST_PATH = 'scripts/ci/suite-ownership.json'
MAX_MANIFEST_BYTES = 4 * 1024 * 1024
MAX_TRACKED_FILES = 200_000
TEST_FILE = /\.(?:test|spec)\.(?:ts|tsx|mts|cts|js|jsx|mjs|cjs)\z/
# Trees whose tests no Linux feature suite runs, so the manifest does not list them:
#   skills/                    the orchestrate skill's own node:test suite (orchestrate-validation.yml)
#   vendor/                    vendored upstream sources, never project tests
#   taurine-mobile/tests/e2e/  the mobile journeys, which run on the mobile platform lanes
EXEMPT_PREFIXES = %w[skills/ vendor/ taurine-mobile/tests/e2e/].freeze

class OwnershipError < StandardError; end

def reject!(code)
  raise OwnershipError, code
end

# A manifest glob is plain path characters and `*` and nothing else. Anything outside this set is refused
# before a pattern is built, so no glob text can ever reach a regular expression compiler, an error message
# or a log (an unclosed `[` would otherwise raise an error that quotes the pattern).
GLOB_CHARS = %r{\A[A-Za-z0-9_./*@+-]+\z}

# Glob with the collector's semantics (collect-suite-evidence.rb, glob_regex): `**` crosses directory
# separators, `*` stays within a segment, everything else is literal. Every literal piece goes through
# Regexp.escape, and the collector builds its pattern the same way; test-suite-ownership-check.sh proves
# the two agree on the shapes the manifest uses.
def glob_regex(glob)
  source = glob.split('**', -1).map do |segment|
    segment.split('*', -1).map { |literal| Regexp.escape(literal) }.join('[^/]*')
  end.join('.*')
  Regexp.new("\\A#{source}\\z")
rescue RegexpError
  reject!('manifest_glob')
end

def read_patterns(path)
  reject!('manifest_shape') unless File.size(path) <= MAX_MANIFEST_BYTES
  manifest = JSON.parse(File.read(path))
  reject!('manifest_shape') unless manifest.is_a?(Hash) && manifest['suites'].is_a?(Hash)
  patterns = manifest['suites'].values.flat_map do |record|
    reject!('manifest_shape') unless record.is_a?(Hash) && record['include'].is_a?(Array)
    record['include']
  end
  patterns.each do |glob|
    reject!('manifest_glob') unless glob.is_a?(String) && glob.match?(GLOB_CHARS) && !glob.start_with?('/') && !glob.include?('..')
  end
  patterns.uniq.map { |glob| glob_regex(glob) }
rescue SystemCallError, JSON::ParserError
  reject!('manifest_shape')
end

def tracked_files(root)
  # safe.directory on the command line (a protected scope): the visual tier's job container runs as
  # root over a workspace the runner user owns, and git would otherwise refuse the listing.
  out, status = Open3.capture2('git', '-c', "safe.directory=#{File.expand_path(root)}", '-C', root, 'ls-files', '-z', '--full-name')
  reject!('file_list') unless status.success?
  # Raw bytes, never a decoded string: a file name that is not valid text must be counted or ignored like any
  # other, not crash the matcher (the patterns are ASCII, so they match binary strings).
  files = out.b.split("\0".b)
  reject!('file_list') if files.length > MAX_TRACKED_FILES
  files
end

def in_scope?(path)
  return false unless path.match?(TEST_FILE)
  return false if path.include?('/node_modules/') || path.start_with?('node_modules/')

  EXEMPT_PREFIXES.none? { |prefix| path.start_with?(prefix) }
end

def report(lines, summary_path)
  lines.each { |line| puts line }
  File.open(summary_path, 'a') { |f| f.puts("### Suite ownership (early check)\n\n#{lines.join("\n\n")}\n") } if summary_path && !summary_path.empty?
end

begin
  root = ARGV.first
  reject!('arguments') unless root && File.directory?(root)
  manifest = File.join(root, MANIFEST_PATH)
  summary = ENV['GITHUB_STEP_SUMMARY']
  # lstat, never stat: the manifest must be a plain file in the checkout. A symbolic link (which could
  # point outside it), a directory, a device or a pipe is refused, not followed or read.
  manifest_stat = begin
    File.lstat(manifest)
  rescue SystemCallError
    nil
  end
  # A missing manifest is refused, never skipped: a source that deletes the manifest must not skip the gate.
  reject!('manifest_missing') if manifest_stat.nil?
  reject!('manifest_shape') unless manifest_stat.file?

  patterns = read_patterns(manifest)
  tests = tracked_files(root).select { |path| in_scope?(path) }
  unowned = tests.count { |path| patterns.none? { |regex| regex.match?(path) } }
  if unowned.zero?
    report(["suite ownership: #{tests.length} test file(s) checked, every one has a suite owner"], summary)
    exit 0
  end
  lines = ["suite ownership: refused (reason ownership_unowned): #{unowned} of #{tests.length} test file(s) have no suite owner in the ownership manifest",
           'regenerate the manifest with the private generator or run the private ownership audit locally to list them; no path is printed here']
  report(lines, summary)
  warn lines.first
  exit 1
rescue OwnershipError => e
  line = "suite ownership: refused (reason #{e.message}): the check could not read its data"
  report([line], ENV['GITHUB_STEP_SUMMARY'])
  warn line
  exit 1
rescue StandardError
  # Anything unforeseen. Nothing of the error is printed, not its message, its class or its backtrace: they
  # could carry a path, a pattern or manifest text. Output is always a fixed reason class.
  line = 'suite ownership: refused (reason internal): the check failed unexpectedly'
  report([line], ENV['GITHUB_STEP_SUMMARY'])
  warn line
  exit 1
end
