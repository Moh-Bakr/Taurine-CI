#!/usr/bin/env ruby
# frozen_string_literal: true

# Decides whether a pull request changes documentation only (the docs-only fast path of
# validate-public-changes.yml; docs/how-ci-works.md, "Docs-only fast path").
#
# The `classify` job runs THIS file from the BASE commit's checkout, never from the pull request's,
# so a pull request cannot alter its own classification. It prints `docs_only=true` or
# `docs_only=false` (to $GITHUB_OUTPUT when set, else to standard output) and always exits 0 on a
# verdict: every doubt is `false`, which runs the full policy.
#
# Inputs, from the environment (never from arguments the pull request chooses):
#   EVENT_NAME  the workflow's event; anything but pull_request is false
#   BASE_SHA    github.event.pull_request.base.sha
#   HEAD_SHA    github.event.pull_request.head.sha
#   MERGE_SHA   github.sha, the merge commit the other jobs check out
# and the checkout to read as `--repo DIR` (a clone with full history, no working-tree content is
# executed, and git runs with a scrubbed environment, no external diff and no text conversion).
#
# docs_only is true only when EVERY changed path between BASE_SHA and MERGE_SHA is
#   - docs/**/*.md, a top-level *.md, or plans/**/*.md (the last only while the base has a plans/
#     directory), written with plain path segments (a letter or digit first, then letters, digits,
#     dot, underscore, dash), and
#   - not listed in docs-fast-path-exclusions.rb (a document the policy reads), and
#   - an ordinary text file: added, modified or deleted as a regular non-executable file (mode
#     100644), never renamed, copied, type-changed, a symlink, a submodule or a mode change, and
#     never binary.
# An empty change, more than MAX_PATHS paths, a merge commit that is not BASE_SHA's merge with
# HEAD_SHA, an unknown commit or any git failure is false.
require 'open3'

require_relative 'docs-fast-path-exclusions'

MAX_PATHS = 2000
REGULAR = '100644'
ZERO = '000000'
SEGMENT = '[A-Za-z0-9][A-Za-z0-9._-]*'
SHA = /\A[0-9a-f]{40}\z/.freeze
GIT_ENV = {
  'GIT_CONFIG_NOSYSTEM' => '1',
  'GIT_CONFIG_GLOBAL' => '/dev/null',
  'GIT_TERMINAL_PROMPT' => '0',
  'GIT_OPTIONAL_LOCKS' => '0',
  'LC_ALL' => 'C'
}.freeze

# A reason string is a doubt; nil is none. Kept out of `docs_only` so each test can name its case.
class Doubt < StandardError; end

def git(repo, *args)
  out, err, status = Open3.capture3(GIT_ENV, 'git', '-C', repo, '-c', 'core.fsmonitor=false', '-c', 'core.hooksPath=/dev/null', *args)
  raise Doubt, "git #{args.first} failed: #{err.lines.first.to_s.strip}" unless status.success?

  out
end

# The docs patterns. plans/ counts only when the base commit has that directory.
def doc_patterns(repo, base)
  patterns = [%r{\Adocs/(?:#{SEGMENT}/)*#{SEGMENT}\.md\z}, /\A#{SEGMENT}\.md\z/]
  has_plans = !git(repo, 'ls-tree', '--name-only', base, 'plans').strip.empty?
  patterns << %r{\Aplans/(?:#{SEGMENT}/)*#{SEGMENT}\.md\z} if has_plans
  patterns
end

# [[status, old_mode, new_mode, path], ...] for base..merge, renames and copies not detected so a
# rename is a delete plus an add, and each side is judged as its own path.
def raw_changes(repo, base, merge)
  out = git(repo, 'diff', '--raw', '-z', '--no-renames', '--no-ext-diff', '--no-textconv', '--no-abbrev', base, merge)
  fields = out.split("\0", -1)
  fields.pop if fields.last == ''
  raise Doubt, 'the raw diff is malformed' unless fields.size.even?

  fields.each_slice(2).map do |meta, path|
    m = meta.match(/\A:(\d{6}) (\d{6}) [0-9a-f]{40} [0-9a-f]{40} ([A-Z])\z/)
    raise Doubt, 'a raw diff record is malformed' unless m

    [m[3], m[1], m[2], path]
  end
end

# The paths git reports as binary (numstat prints `-` for both counts).
def binary_paths(repo, base, merge)
  out = git(repo, 'diff', '--numstat', '-z', '--no-renames', '--no-ext-diff', '--no-textconv', base, merge)
  out.split("\0", -1).reject(&:empty?).filter_map do |record|
    m = record.match(/\A(-|\d+)\t(-|\d+)\t(.*)\z/m)
    raise Doubt, 'a numstat record is malformed' unless m

    m[3] if m[1] == '-' || m[2] == '-'
  end
end

# The verdict: [true, reason] or [false, reason].
def classify(env, repo)
  return [false, "the event is #{env['EVENT_NAME'].to_s.inspect}, not a pull request"] unless env['EVENT_NAME'] == 'pull_request'

  base, head, merge = env.values_at('BASE_SHA', 'HEAD_SHA', 'MERGE_SHA')
  return [false, 'a commit id is missing or not a full SHA'] unless [base, head, merge].all? { |s| s.to_s.match?(SHA) }

  raise Doubt, 'the checkout is not a directory' unless File.directory?(repo)

  [base, merge].each { |sha| git(repo, 'cat-file', '-e', "#{sha}^{commit}") }
  parents = git(repo, 'rev-list', '--parents', '-n', '1', merge).split
  raise Doubt, 'the merge commit is not a two-parent merge' unless parents.size == 3 && parents.first == merge
  raise Doubt, 'the merge commit does not merge the pull request head' unless parents.last == head

  changes = raw_changes(repo, base, merge)
  return [false, 'no changed path'] if changes.empty?
  return [false, "more than #{MAX_PATHS} changed paths"] if changes.size > MAX_PATHS

  patterns = doc_patterns(repo, base)
  excluded = DocsFastPathExclusions::EXCLUDED_DOCS.map(&:downcase)
  binaries = binary_paths(repo, base, merge)
  changes.each do |status, old_mode, new_mode, path|
    return [false, "#{path.inspect}: status #{status} (only added, modified or deleted)"] unless %w[A M D].include?(status)

    modes_ok = case status
               when 'A' then old_mode == ZERO && new_mode == REGULAR
               when 'M' then old_mode == REGULAR && new_mode == REGULAR
               else old_mode == REGULAR && new_mode == ZERO
               end
    return [false, "#{path.inspect}: not a regular non-executable file (modes #{old_mode} to #{new_mode})"] unless modes_ok
    return [false, "#{path.inspect}: not a plain documentation path"] unless path.bytesize <= 240 && patterns.any? { |re| re.match?(path) }
    return [false, "#{path.inspect}: a document the policy reads"] if excluded.include?(path.downcase)
    return [false, "#{path.inspect}: binary"] if binaries.include?(path)
  end
  [true, "#{changes.size} documentation path(s)"]
end

def publish(verdict, reason)
  line = "docs_only=#{verdict}"
  target = ENV['GITHUB_OUTPUT'].to_s
  if target.empty?
    puts line
  else
    File.open(target, 'a') { |f| f.puts(line) }
  end
  warn "docs-only classification: #{verdict} (#{reason})"
end

if $PROGRAM_NAME == __FILE__
  repo = nil
  args = ARGV.dup
  repo = args.shift(2).last if args.first == '--repo'
  if repo.nil? || !args.empty?
    warn 'usage: classify-docs-change.rb --repo DIR'
    exit 2
  end
  begin
    verdict, reason = classify(ENV, repo)
  rescue StandardError => e
    verdict = false
    reason = "doubt: #{e.message}"
  end
  publish(verdict, reason)
end
