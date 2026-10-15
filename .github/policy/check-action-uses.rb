#!/usr/bin/env ruby
# frozen_string_literal: true

# Action references: every `uses` is a full commit SHA and an exact reviewed reference.
#
# Reads the PARSED YAML, not its text. A grep for `uses:` misses every other spelling YAML and so
# GitHub accepts: a quoted or escaped key, a flow mapping (`{uses: x}`, `steps: [{uses: x}]`), the
# value on the next line, a space before the colon, a complex key (`? uses`). For each file given
# it collects `jobs.<id>.uses`, `jobs.<id>.steps[*].uses` and a composite's `runs.steps[*].uses`,
# and holds every one to:
#
#   - remote actions: a full 40-character commit SHA, never a tag or branch;
#   - every reference, local actions and reusable workflows included: an exact entry of the
#     reviewed allow-list in action-allowlist.rb (one line per entry).
#
# It fails on a load error, an alias (aliases are refused), a duplicate mapping key (the shared
# AST walk in yaml-guard.rb, which the loader would resolve silently to the last value), a
# non-mapping job or step, and a `uses` value that is not a string. As a tripwire it also counts the
# lines of the file that look like a `uses` key and fails if the walk found fewer references, so
# a disagreement between this parser and GitHub's fails closed.
#
# The same walk refuses a container image that is not pinned by an `@sha256:<64 hex>` digest:
# `jobs.<id>.container` (a string or a mapping with `image`) and `jobs.<id>.services.<name>.image`.
# An expression is accepted only as exact reviewed text (action-allowlist.rb) or exactly
# `${{ fromJSON('<one JSON literal>') }}` with the literal's image pinned; any other expression is
# refused, since it can fall back to an unpinned image through vars, env, inputs, matrix or needs.
#
# The tripwire fails closed, so it has false positives by design: any non-comment line that holds
# the text `uses:` (a trailing comment, a `run:` script, a description) counts as a line that looks
# like a `uses` key, and the file fails when the walk found fewer references than such lines. Fix a
# false positive by rewording the text, not by weakening the guard.
#
# Usage: ruby check-action-uses.rb [FILE...]
#   With files, checks exactly those. With none, walks the tree itself (every .yml and .yaml under
#   .github/workflows and .github/actions, the set check-workflows.sh checks) from the repository
#   root. It exits 1 on any finding, and also when it checked no file at all: it never exits 0
#   having checked nothing.
require 'json'
require 'yaml'
require_relative 'yaml-guard'
require_relative 'action-allowlist'

PINNED = %r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}\z}
# A line that looks like a `uses` key: the word, optional quotes and spaces, a colon. Comment-only
# lines are ignored; a flow mapping can hold several on one line.
LOOKS_LIKE_USES = /uses["']?\s*:/
DIGEST = /@sha256:[0-9a-f]{64}\z/

# Every reference in a parsed document, or a finding for a shape this check cannot read.
def references(doc, findings)
  refs = []
  take = lambda do |where, mapping|
    unless mapping.is_a?(Hash)
      findings << "#{where} is not a mapping"
      return
    end
    return unless mapping.key?('uses')

    value = mapping['uses']
    if value.is_a?(String) && !value.strip.empty?
      refs << value
    else
      findings << "#{where}: uses is not a non-empty string (#{value.inspect})"
    end
  end
  steps_of = lambda do |where, steps|
    case steps
    when nil then nil
    when Array then steps.each_with_index { |step, i| take.call("#{where}.steps[#{i}]", step) }
    else findings << "#{where}.steps is not a list"
    end
  end
  # Both shapes are read whatever the file is called: a composite's runs.steps and a workflow's jobs.
  runs = doc['runs']
  steps_of.call('runs', runs['steps']) if runs.is_a?(Hash)
  jobs = doc['jobs']
  if jobs.is_a?(Hash)
    jobs.each do |id, job|
      take.call("jobs.#{id}", job)
      steps_of.call("jobs.#{id}", job['steps']) if job.is_a?(Hash)
    end
  end
  refs
end

# An image reference must carry a digest. An expression is accepted only as exact reviewed text
# (CONTAINER_EXPRESSION_ALLOWLIST) or exactly `${{ fromJSON('<one JSON literal>') }}` whose image is
# pinned; any other expression can fall back to an unpinned image and is refused.
FROM_JSON_ONLY = /\A\$\{\{\s*fromJSON\('([^']*)'\)\s*\}\}\z/

def image_findings(where, value, findings)
  unless value.is_a?(String) && !value.strip.empty?
    findings << "#{where}: the image is not a non-empty string (#{value.inspect})"
    return
  end
  image = value
  if value.include?('${{')
    return if CONTAINER_EXPRESSION_ALLOWLIST.include?(value)

    literal = value[FROM_JSON_ONLY, 1]
    parsed = begin
      literal && JSON.parse(literal)
    rescue JSON::ParserError
      nil
    end
    image = parsed['image'] if parsed.is_a?(Hash) && parsed['image'].is_a?(String)
    if image.equal?(value)
      findings << "#{where}: the image expression is not exactly ${{ fromJSON('<one JSON literal with an image>') }} and not on the reviewed list: #{value}"
      return
    end
  end
  findings << "Every container image must be pinned by an @sha256:<64 hex> digest (#{where}): #{image}" unless image.match?(DIGEST)
end

def container_findings(doc, findings)
  jobs = doc['jobs']
  return unless jobs.is_a?(Hash)

  jobs.each do |id, job|
    next unless job.is_a?(Hash)

    if job.key?('container')
      c = job['container']
      c.is_a?(Hash) ? image_findings("jobs.#{id}.container.image", c['image'], findings) : image_findings("jobs.#{id}.container", c, findings)
    end
    next unless job.key?('services')

    services = job['services']
    unless services.is_a?(Hash)
      findings << "jobs.#{id}.services is not a mapping"
      next
    end
    services.each do |name, svc|
      if svc.is_a?(Hash) then image_findings("jobs.#{id}.services.#{name}.image", svc['image'], findings)
      else findings << "jobs.#{id}.services.#{name} is not a mapping"
      end
    end
  end
end

def check_file(path)
  findings = YamlGuard.yaml_duplicates(path)
  text = File.read(path, encoding: 'UTF-8')
  begin
    doc = YAML.safe_load(text, aliases: false)
  rescue Psych::Exception => e
    return findings + ["cannot be loaded (#{e.class}); aliases are refused"]
  end
  return findings if doc.nil?
  return findings + ['the document is not a mapping'] unless doc.is_a?(Hash)

  refs = references(doc, findings)
  container_findings(doc, findings)
  looking = text.lines.reject { |l| l.lstrip.start_with?('#') }.sum { |l| l.scan(LOOKS_LIKE_USES).size }
  findings << "#{looking} line(s) look like a uses key but the walk found #{refs.size}: the parser and the text disagree" if looking > refs.size
  refs.each do |ref|
    if !ref.start_with?('./') && !ref.match?(PINNED)
      findings << "Every Action reference must use a full 40-character commit SHA: #{ref}"
    elsif !ACTION_ALLOWLIST.include?(ref)
      findings << "Unreviewed or mutable Action reference: #{ref}"
    end
  end
  findings
end

files = ARGV.dup
# The same set as check-workflows.sh's find: regular files only, hidden ones included.
files = Dir.glob('.github/{workflows,actions}/**/*.{yml,yaml}', File::FNM_DOTMATCH).select { |f| File.file?(f) && !File.symlink?(f) }.sort if files.empty?
if files.empty?
  warn 'no workflow or composite file to check: run from the repository root, or name the files'
  exit 1
end

failed = false
files.each do |path|
  findings = check_file(path)
  next if findings.empty?

  failed = true
  findings.each { |f| warn "#{path}: #{f}" }
end
puts "action references: #{files.size} file(s) checked" unless failed
exit(failed ? 1 : 0)
