# Compiled-dependency cache groups and the uncached door concerns.
# Usage: ruby check-cache-groups.rb CONCERN-WORKFLOW.yml...
#
# Every concern workflow that handles the compiled-dependency cache (the cargo-target path, or the
# rust-target-cache composite) is held to these rules. They fail closed: a form of concern selection
# the parser cannot read is a failure, not a skip.
#  1. The workflow has exactly the reviewed locate, restore and save steps, and at least the minimum
#     number of designated savers recorded in MINIMUM_SAVERS below (an empty or truncated parse fails).
#  2. A door concern (DOOR_CONCERNS: the OpenSSL door, whose version-string proof cannot detect a
#     tampered restored library, and which is our only independent proof of the vendored OpenSSL) never
#     appears in, and is never covered by a prefix in, the `if` of any compiled-cache step, nor in the
#     group mapping: it always builds from source.
#  3. Every concern is selected by `inputs.concern == 'literal'` or `startsWith(inputs.concern, 'literal')`
#     only; any other mention of inputs.concern in those `if`s fails.
#  4. Every designated saver has a group (a literal mapping, or the fallback group for rust-app-*), and no
#     two savers share a group (rust-app-2 alone owns the fallback).
#  6. The steps of one cache kind select the same concerns: the restore-time strip as the restore, the
#     strip-and-prove as the save.
#  7. The compiled save and strip-and-prove keep their conditions: both carry `cache-hit != 'true'`,
#     the save also the strip-and-prove success, the strip-and-prove also the concern's success.
#  5. Every restoring concern is mapped explicitly or is a rust-app-* concern, and its group has a saver:
#     an unmapped concern never silently joins the fallback group.
require 'yaml'
require_relative 'cache-expression'

DOOR_CONCERNS = %w[rust-tls-openssl].freeze
MINIMUM_SAVERS = { 'linux-validation-concern.yml' => 3, 'macos-validation-concern.yml' => 4, 'windows-validation-concern.yml' => 4 }.freeze
LITERAL = /inputs\.concern == '([^']+)'/
PREFIX = /startsWith\(inputs\.concern, '([^']+)'\)/

failures = []
ARGV.each do |path|
  base = File.basename(path)
  doc = YAML.safe_load(File.read(path, encoding: 'UTF-8'), aliases: false) || {}
  steps = (doc['jobs'] || {}).values.flat_map { |job| job.is_a?(Hash) ? Array(job['steps']) : [] }.select { |s| s.is_a?(Hash) }
  compiled = steps.select do |s|
    uses = s['uses'].to_s
    (uses.start_with?('actions/cache/') && s.dig('with', 'path').to_s.include?('cargo-target')) || uses == './.github/actions/rust-target-cache'
  end
  save = compiled.find { |s| s['uses'].to_s.start_with?('actions/cache/save@') }
  locate = compiled.find { |s| s['uses'].to_s == './.github/actions/rust-target-cache' && s.dig('with', 'mode') == 'locate' }
  restore = compiled.find { |s| s['uses'].to_s.start_with?('actions/cache/restore@') }
  if compiled.empty? && MINIMUM_SAVERS.key?(base)
    failures << "#{path}: no compiled-dependency cache steps were found (an empty parse proves nothing)"
    next
  end
  next if compiled.empty?
  unless save && locate && restore
    failures << "#{path}: the compiled-dependency cache needs its locate, restore and save steps"
    next
  end

  # Rule 3 and 2: read every concern selector in every compiled step, failing closed on the unreadable.
  compiled.each do |step|
    conds = [step['if'].to_s, step.dig('with', 'group').to_s].reject(&:empty?)
    conds.each do |text|
      literals = text.scan(LITERAL).flatten
      prefixes = text.scan(PREFIX).flatten
      rest = text.gsub(LITERAL, '').gsub(PREFIX, '')
      failures << "#{path}: step #{step['name'].inspect} selects concerns in a form this check cannot read (#{rest.scan(/[^\n]*inputs\.concern[^\n]*/).first.to_s.strip[0, 80]})" if rest.include?('inputs.concern')
      DOOR_CONCERNS.each do |door|
        failures << "#{path}: step #{step['name'].inspect} names the door concern #{door}, which is never cached" if literals.include?(door)
        failures << "#{path}: step #{step['name'].inspect} has the prefix #{prefixes.find { |p| door.start_with?(p) }.inspect}, which covers the door concern #{door}" if prefixes.any? { |p| door.start_with?(p) }
      end
    end
  end

  # Rules 6 and 7.
  tokens = lambda do |step|
    text = step['if'].to_s
    text.scan(LITERAL).flatten.sort + text.scan(PREFIX).flatten.map { |p| "prefix:#{p}" }.sort
  end
  strip_restored = compiled.find { |s| s['uses'].to_s == './.github/actions/rust-target-cache' && s.dig('with', 'mode') == 'restored' }
  strip_save = compiled.find { |s| s['uses'].to_s == './.github/actions/rust-target-cache' && s.dig('with', 'mode') == 'save' }
  if strip_restored.nil? || strip_save.nil?
    failures << "#{path}: the compiled cache needs its restore-time strip and its strip-and-prove steps"
  else
    failures << "#{path}: the restore-time strip selects different concerns than the restore (#{tokens.call(strip_restored).inspect} against #{tokens.call(restore).inspect})" unless tokens.call(strip_restored) == tokens.call(restore)
    failures << "#{path}: the strip-and-prove selects different concerns than the save (#{tokens.call(strip_save).inspect} against #{tokens.call(save).inspect})" unless tokens.call(strip_save) == tokens.call(save)
    save_terms = CacheExpression.top_terms(save['if'].to_s) || []
    prove_terms = CacheExpression.top_terms(strip_save['if'].to_s) || []
    miss = "steps.cargo-target-cache.outputs.cache-hit != 'true'"
    failures << "#{path}: the compiled save needs the exact top-level term #{miss}" unless save_terms.include?(miss)
    failures << "#{path}: the compiled save needs the exact top-level term steps.cargo-target-strip.outcome == 'success'" unless save_terms.include?("steps.cargo-target-strip.outcome == 'success'")
    failures << "#{path}: the strip-and-prove needs the exact top-level term #{miss}" unless prove_terms.include?(miss)
    failures << "#{path}: the strip-and-prove needs a top-level term requiring the concern step's success" unless prove_terms.any? { |t| t.match?(/\Asteps\.concern-[a-z]+\.outcome == 'success'\z/) }
  end

  expr = locate.dig('with', 'group').to_s
  mapping = expr.scan(/\(inputs\.concern == '([^']+)' && '([^']+)'\)/).to_h
  fallback = expr[/\|\| '([^']+)' \}\}\z/, 1]
  failures << "#{path}: the locate group expression needs a fallback group" if fallback.nil?
  group_of = lambda do |concern|
    return mapping[concern] if mapping.key?(concern)
    return fallback if concern.start_with?('rust-app-')
    nil
  end
  savers = save['if'].to_s.scan(LITERAL).flatten
  minimum = MINIMUM_SAVERS[base]
  failures << "#{path}: #{savers.length} designated savers, fewer than the reviewed minimum #{minimum}" if minimum && savers.length < minimum
  failures << "#{path}: the save step names no designated saver" if savers.empty?
  seen = {}
  savers.each do |concern|
    group = group_of.call(concern)
    if group.nil?
      failures << "#{path}: saver #{concern} has no explicit group and is not a rust-app-* concern"
      next
    end
    failures << "#{path}: #{concern} and #{seen[group]} both save group #{group}: one designated saver per group" if seen.key?(group)
    seen[group] = concern
  end
  failures << "#{path}: rust-app-2 must be the designated saver of the fallback group" if fallback && seen[fallback] && seen[fallback] != 'rust-app-2'
  restorers = restore['if'].to_s.scan(LITERAL).flatten
  restorers.concat(%w[rust-app-1 rust-app-2]) if restore['if'].to_s.include?("startsWith(inputs.concern, 'rust-app-')")
  restorers.uniq.each do |concern|
    group = group_of.call(concern)
    if group.nil?
      failures << "#{path}: #{concern} restores but has no explicit group (an unmapped concern must not join the fallback group)"
    elsif !seen.key?(group)
      failures << "#{path}: #{concern} restores group #{group}, which no concern saves"
    end
  end
end
if failures.empty?
  puts "compiled cache groups: #{ARGV.size} concern workflows checked"
else
  warn failures.uniq.join("\n")
  exit 1
end
