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
# The same walk holds containers and services to the rules at the container block below: images
# pinned by digest as a single token, `options` as exact reviewed text, only the `image` and
# `options` keys, and expressions as exact reviewed text or one fromJSON literal under the same
# rules. The runner puts `options` before the image in `docker create`, so free text there could
# swap the image that runs.
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

# Every reference in a parsed document, or a finding for a shape this check cannot read.
def references(doc, findings)
  refs = []
  take = lambda do |where, mapping|
    unless mapping.is_a?(Hash)
      findings << "#{where} is not a mapping"
      return
    end
    # GitHub reads step and job keys case-insensitively; the checks read them case-sensitively, so a
    # key that is not all lower-case (`Uses`, `With`, `IF`) is refused, in workflows and composites alike.
    mapping.each_key { |k| findings << "#{where}: the key #{k.inspect} is not all lower-case (keys are read case-insensitively by GitHub)" if k.is_a?(String) && k != k.downcase }
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

# A container (or service) is an image plus options, and both reach `docker create`. The runner puts
# the options BEFORE the image (DockerCommandManager.DockerCreate in actions/runner, commit
# 16834edc670a195bbd0aab375201360c47737f8c, src/Runner.Worker/Container: `{ContainerCreateOptions}` is
# added to the argument list before `{ContainerImage}`, and `-p {port}` is not quoted), so any
# positional token in `options` or `ports` would become the image that runs. Therefore:
#   - the only keys are `image` and `options`; ports, volumes, env, credentials and anything else are
#     refused until someone reviews them;
#   - `options` is exact reviewed text (CONTAINER_OPTIONS_ALLOWLIST), never free text;
#   - the image is one token pinned by an `@sha256:<64 hex>` digest, with no whitespace;
#   - an expression is accepted only as exact reviewed text (CONTAINER_EXPRESSION_ALLOWLIST) or exactly
#     `${{ fromJSON('<one JSON literal>') }}`, and the literal gets the same rules (keys image and
#     options only, no duplicate or escaped-duplicate key, case-variant keys refused as unknown).
FROM_JSON_ONLY = /\A\$\{\{\s*fromJSON\('([^']*)'\)\s*\}\}\z/
CONTAINER_KEYS = %w[image options].freeze
# One lowercase token that starts with a letter or digit, so it can never read as a docker flag.
IMAGE_REF = %r{\A[a-z0-9][a-z0-9._/:-]*@sha256:[0-9a-f]{64}\z}
MAX_JSON_DEPTH = 64

# A small strict JSON reader that reports every key an object repeats, after escape decoding (so
# "image" and "\u0069mage" are the same key). Ruby's own JSON parser resolves a duplicate silently to
# the last value, and whether it exposes the repeat depends on its version, so the check cannot rely
# on it. Returns [value, duplicate_keys]; raises JSON::ParserError on anything it cannot read.
class StrictJson
  def self.parse(text)
    reader = new(text)
    value = reader.value
    reader.finish
    [value, reader.duplicates]
  end

  attr_reader :duplicates

  def initialize(text)
    @text = text
    @pos = 0
    @depth = 0
    @duplicates = []
  end

  def finish
    skip
    raise JSON::ParserError, 'trailing text' unless @pos == @text.length
  end

  def value
    skip
    case @text[@pos]
    when '{' then object
    when '"' then string
    else scalar
    end
  end

  private

  def skip
    @pos += 1 while @text[@pos]&.match?(/\s/)
  end

  def object
    @depth += 1
    raise JSON::ParserError, "nesting deeper than #{MAX_JSON_DEPTH}" if @depth > MAX_JSON_DEPTH

    @pos += 1
    result = {}
    skip
    if @text[@pos] == '}'
      @pos += 1
      @depth -= 1
      return result
    end
    loop do
      skip
      raise JSON::ParserError, 'object key expected' unless @text[@pos] == '"'

      key = string
      skip
      raise JSON::ParserError, 'colon expected' unless @text[@pos] == ':'

      @pos += 1
      @duplicates << key if result.key?(key)
      result[key] = value
      skip
      case @text[@pos]
      when ',' then @pos += 1
      when '}' then @pos += 1
                    @depth -= 1
                    return result
      else raise JSON::ParserError, 'comma or brace expected'
      end
    end
  end

  def string
    start = @pos
    @pos += 1
    loop do
      raise JSON::ParserError, 'unterminated string' if @pos >= @text.length

      if @text[@pos] == '\\' then @pos += 2
      elsif @text[@pos] == '"' then @pos += 1
                                    break
      else @pos += 1
      end
    end
    JSON.parse("[#{@text[start...@pos]}]").first
  end

  # Numbers, true, false, null. An array is not accepted in a container literal.
  def scalar
    token = @text[@pos..][/\A(?:-?\d[\d.eE+-]*|true|false|null)/] or raise JSON::ParserError, 'value expected'
    @pos += token.length
    JSON.parse("[#{token}]").first
  end
end

def options_findings(where, options, findings)
  return if options.is_a?(String) && CONTAINER_OPTIONS_ALLOWLIST.include?(options)

  findings << "#{where}: container options must be exact reviewed text (the runner puts them before the image, so a positional token swaps the image): #{options.inspect}"
end

# A mapping with `image` and optionally `options`, however it was written.
def spec_findings(where, spec, findings)
  unless spec.is_a?(Hash)
    findings << "#{where} is not a mapping"
    return
  end
  (spec.keys - CONTAINER_KEYS).each { |k| findings << "#{where}: the key #{k.inspect} is not reviewed (only image and options are)" }
  options_findings("#{where}.options", spec['options'], findings) if spec.key?('options')
  image_findings("#{where}.image", spec['image'], findings, in_mapping: true)
end

def image_findings(where, value, findings, in_mapping: false)
  unless value.is_a?(String) && !value.strip.empty?
    findings << "#{where}: the image is not a non-empty string (#{value.inspect})"
    return
  end
  if value.include?('${{')
    if in_mapping
      findings << "#{where}: an expression is only accepted as the container value itself, not as a mapping's image: #{value[0, 200]}"
      return
    end
    return if CONTAINER_EXPRESSION_ALLOWLIST.include?(value)

    literal = value[FROM_JSON_ONLY, 1]
    reason = nil
    parsed, duplicates = begin
      literal ? StrictJson.parse(literal) : [nil, []]
    rescue JSON::ParserError, SystemStackError => e
      reason = e.message[0, 80]
      [nil, []]
    end
    unless parsed.is_a?(Hash) && parsed['image'].is_a?(String)
      findings << "#{where}: the image expression is not exactly ${{ fromJSON('<one JSON literal with an image>') }} and not on the reviewed list#{reason ? " (#{reason})" : ''}: #{value[0, 200]}"
      return
    end
    duplicates.each { |k| findings << "#{where}: the JSON literal repeats the key #{k.inspect}" }
    (parsed.keys - CONTAINER_KEYS).each { |k| findings << "#{where}: the JSON literal has the key #{k.inspect}, not reviewed (only image and options are)" }
    options_findings("#{where} literal options", parsed['options'], findings) if parsed.key?('options')
    value = parsed['image']
  end
  findings << "Every container image must be pinned by an @sha256:<64 hex> digest, as a single token (#{where}): #{value}" unless value.match?(IMAGE_REF)
end

def container_findings(doc, findings)
  jobs = doc['jobs']
  return unless jobs.is_a?(Hash)

  jobs.each do |id, job|
    next unless job.is_a?(Hash)

    if job.key?('container')
      c = job['container']
      c.is_a?(Hash) ? spec_findings("jobs.#{id}.container", c, findings) : image_findings("jobs.#{id}.container", c, findings)
    end
    next unless job.key?('services')

    services = job['services']
    unless services.is_a?(Hash)
      findings << "jobs.#{id}.services is not a mapping"
      next
    end
    services.each { |name, svc| spec_findings("jobs.#{id}.services.#{name}", svc, findings) }
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
