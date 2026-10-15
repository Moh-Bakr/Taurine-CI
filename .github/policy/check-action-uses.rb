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
# Usage: ruby check-action-uses.rb FILE...   (exit 1 on the first file with a finding)
require 'yaml'
require_relative 'yaml-guard'
require_relative 'action-allowlist'

PINNED = %r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}\z}
# A line that looks like a `uses` key: the word, optional quotes and spaces, a colon. Comment-only
# lines are ignored; a flow mapping can hold several on one line.
LOOKS_LIKE_USES = /uses["']?\s*:/

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

failed = false
ARGV.each do |path|
  findings = check_file(path)
  next if findings.empty?

  failed = true
  findings.each { |f| warn "#{path}: #{f}" }
end
exit(failed ? 1 : 0)
