#!/usr/bin/env ruby
# frozen_string_literal: true

# Every document the policy reads is on the docs-only fast path's exclusion list.
#
# A pull request that changes documentation only runs a short policy job (docs/how-ci-works.md,
# "Docs-only fast path"). That skips every check that could open a document, so a document some
# check or workflow reads must never be classified as docs-only: it is listed in
# docs-fast-path-exclusions.rb (EXCLUDED_DOCS), which the classifier reads from the base commit.
#
# This check greps the tree for every way a script, test, action or workflow can name a document, and
# fails when one is not accounted for. A line outside a comment counts as a reference when, after the
# excluded documents' own paths are taken out of it, it still
#   - names an existing document (the file name of any docs/**/*.md or top-level *.md file), or
#   - names the docs directory as a path (see TOKEN): docs/ or a quoted 'docs' or "docs", or /docs ending a word.
# Each reference line must then be pinned, with its exact text, in NAMED_NOT_READ of the exclusion
# list, where a reviewer decided it is a message, a description or a synthetic fixture. So adding a
# reader of any other document fails here until the document is excluded (it is read) or the line is
# pinned (it is not), and that decision is reviewed with the change. Comment lines are skipped: a
# comment reads nothing. A pin whose line is gone is only a warning, so a cleanup is never blocked.
#
# The files that hold the list and the classifier name documents by design and are not scanned:
# docs-fast-path-exclusions.rb, classify-docs-change.rb, this file and the three tests of them
# (test-docs-reads.sh, test-classify-docs-change.sh and test-docs-diff.sh). None of them opens a
# document of this repository; their fixtures build their own temporary trees.
#
# The list is read from THIS script's directory, so under the base pass main's list judges a pull
# request's tree. Run from the repository root; an optional argument names another root (fixtures).
require_relative 'docs-fast-path-exclusions'

root = ARGV.first || '.'
OWN_FILES = %w[
  docs-fast-path-exclusions.rb
  classify-docs-change.rb
  check-docs-reads.rb
  test-docs-reads.sh
  test-classify-docs-change.sh
  test-docs-diff.sh
].freeze
# The docs directory as a path component: docs/ not glued to a longer name, a quoted 'docs' or "docs", or /docs
# ending a word (before a quote, a space, a bracket, a brace or the end of the line). A message that merely
# begins with the word, like "docs diff: ...", is not a path.
TOKEN = %r~(?<![A-Za-z0-9_.-])docs/|["']docs["']|/docs(?:["'\s)\]}]|$)~

excluded = DocsFastPathExclusions::EXCLUDED_DOCS
pins = DocsFastPathExclusions::NAMED_NOT_READ
problems = []

# The list itself must be exact and plain.
plain = %r{\A(?:docs/(?:[A-Za-z0-9][A-Za-z0-9._-]*/)*[A-Za-z0-9][A-Za-z0-9._-]*|[A-Za-z0-9][A-Za-z0-9._-]*)\.md\z}
problems << 'EXCLUDED_DOCS is empty: it must at least name the spike-record document' if excluded.empty?
excluded.each { |d| problems << "EXCLUDED_DOCS: #{d.inspect} is not a plain documentation path" unless d.match?(plain) }
problems << 'EXCLUDED_DOCS must be sorted and have no repeat' unless excluded == excluded.sort.uniq
problems << 'EXCLUDED_DOCS must be lower-case' unless excluded.all? { |d| d == d.downcase }
excluded.each { |d| problems << "EXCLUDED_DOCS: #{d} is not in the tree (a stale entry, or a document that moved)" unless File.file?(File.join(root, d)) }
pins.each do |file, lines|
  problems << "NAMED_NOT_READ: #{file} is not a file under .github/" unless file.start_with?('.github/')
  problems << "NAMED_NOT_READ: #{file} pins a line twice" unless lines == lines.uniq
end

documents = (Dir.glob(File.join(root, 'docs/**/*.md')) + Dir.glob(File.join(root, '*.md'))).map { |f| File.basename(f) }.uniq.sort
excluded_text = excluded.flat_map { |d| [d, File.basename(d)] }.sort_by { |s| -s.length }
excluded_re = Regexp.union(excluded_text)

seen_pins = Hash.new { |h, k| h[k] = [] }
files = Dir.glob(File.join(root, '.github/**/*'), File::FNM_DOTMATCH).select { |f| File.file?(f) }.sort
files.each do |path|
  rel = path.delete_prefix("#{root.chomp('/')}/")
  next if rel.start_with?('.github/policy/') && OWN_FILES.include?(File.basename(rel))

  text = File.read(path, encoding: 'UTF-8', invalid: :replace, undef: :replace)
  text.each_line.with_index(1) do |line, number|
    stripped = line.strip
    next if stripped.start_with?('#')

    rest = line.gsub(excluded_re, '')
    named = documents.reject { |d| excluded_text.include?(d) }.select { |d| rest.include?(d) }
    next unless rest.match?(TOKEN) || !named.empty?

    if (pins[rel] || []).include?(stripped)
      seen_pins[rel] << stripped
    else
      what = named.empty? ? 'the docs directory' : named.join(', ')
      problems << "#{rel}:#{number}: names #{what} outside a comment, and the line is neither a read of an excluded document nor pinned as not a read: " \
                  "if it reads a document, add the document to EXCLUDED_DOCS in .github/policy/docs-fast-path-exclusions.rb; " \
                  "if it is a message, a description or a fixture, pin the exact line in NAMED_NOT_READ there (#{stripped[0, 100].inspect})"
    end
  end
end

pins.each do |file, lines|
  (lines - seen_pins[file]).each do |line|
    puts "::warning title=docs reads::NAMED_NOT_READ pins a line that is gone from #{file}: #{line[0, 80].inspect}"
  end
end

if problems.empty?
  puts "docs reads: #{files.size} files scanned; #{excluded.size} excluded document(s), #{pins.values.sum(&:size)} reviewed non-read line(s), no unaccounted reference"
else
  problems.uniq.each { |p| warn p }
  exit 1
end
