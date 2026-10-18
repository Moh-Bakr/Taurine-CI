# Compiled-dependency cache groups and the uncached door concerns.
# Usage: ruby check-cache-groups.rb WORKFLOW.yml...  (every workflow: one without an allowlist entry may
# not carry a compiled-cache step at all)
#
# Every workflow that handles the compiled-dependency cache (the cargo-target path, or the
# rust-target-cache composite) is held to these rules. They fail closed: a form of concern selection
# the parser cannot read is a failure, not a skip.
#  1. The workflow has exactly the reviewed locate, restore and save steps, and exactly the
#     designated savers of the reviewed save set in CONCERNS below (an empty or truncated parse fails).
#  2. A positive allowlist, per operating system (CONCERNS below), is the only set of concerns that may
#     appear in a compiled-cache step's `if` or in the group mapping: the exact restore set (locate,
#     restore, restore-time strip) and the exact save set (save, strip-and-prove). Anything else, the
#     OpenSSL door (rust-tls-openssl: its version-string proof cannot detect a tampered restored library
#     and it is our only independent proof of the vendored OpenSSL) included, always builds from source.
#     A new concern is cached only by editing the allowlist here, in review.
#  3. Every compiled-cache step carries exactly one concern selector conjunct, an optionally parenthesised
#     `||` list of `inputs.concern == 'literal'` / `startsWith(inputs.concern, 'literal')` (lower-case
#     literals, the exact lower-case spelling `inputs.concern`). Any other mention of the inputs context
#     in those steps (`inputs['concern']`, `inputs.CONCERN`, `startswith`, `!=`, a negation, an `||` with
#     anything but selectors) fails; a step with no selector fails, as it would select every concern.
#     Literals are compared after downcasing because Actions string comparison is case-insensitive.
#     A compiled-cache step in a workflow that has no allowlist entry fails.
#  3b. Cache steps are identified positively: every step whose `uses` starts (any case) with actions/cache,
#     or that uses rust-target-cache, is a compiled-cache step, whatever its path, unless it is exactly the
#     reviewed crate-sources restore or save (pinned by path, key, restore-keys, `if` and keys). A workflow
#     file with more than one YAML document is refused.
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

# Reviewed allowlist: the exact selector tokens of the restore side and of the save side, per workflow.
# 'prefix:x' is startsWith(inputs.concern, 'x'); a bare name is inputs.concern == 'name'.
CONCERNS = {
  'linux-validation-concern.yml' => {
    restore: %w[prefix:rust-app- rust-db rust-packaging],
    save: %w[rust-app-2 rust-db rust-packaging]
  },
  'macos-validation-concern.yml' => {
    restore: %w[prefix:rust-app- rust-db rust-domain rust-packaging],
    save: %w[rust-app-2 rust-db rust-domain rust-packaging]
  },
  'windows-validation-concern.yml' => {
    restore: %w[prefix:rust-app- rust-db rust-domain rust-packaging],
    save: %w[rust-app-2 rust-db rust-domain rust-packaging]
  }
}.freeze
# The reviewed crate-sources steps (lockfile-verified archives only, never compiled output), pinned by
# exact path set, key and `if` per workflow. Every other cache step is a compiled-cache step.
SOURCES_PATH = "${{ steps.cargo-home.outputs.dir }}/registry/cache"
SOURCES_KEY = "cargo-sources-v3-${{ runner.os }}-${{ hashFiles('src/Cargo.lock', 'src/taurine-backend/*/Cargo.lock', 'src/taurine-backend/vendor/*/Cargo.lock', 'src/vendor/*/Cargo.lock') }}"
SOURCES_RESTORE_KEYS = "cargo-sources-v3-${{ runner.os }}-"
SAVE_KEY = '${{ steps.cargo-sources.outputs.cache-primary-key }}'
PV = "github.ref == 'refs/heads/main' && steps.verified-source.outputs.protected-ancestor == 'true'"
SOURCES = {
  'linux-validation-concern.yml' => {
    restore: "${{ #{PV} && (inputs.concern == 'taurine-cli' || startsWith(inputs.concern, 'rust-') || inputs.concern == 'scan-security') }}",
    save: "${{ github.ref == 'refs/heads/main' && (inputs.concern == 'taurine-cli' || startsWith(inputs.concern, 'rust-') || inputs.concern == 'scan-security') && steps.verified-source.outputs.protected-ancestor == 'true' && steps.cargo-sources.outputs.cache-hit != 'true' }}"
  },
  'macos-validation-concern.yml' => {
    restore: "${{ #{PV} && startsWith(inputs.concern, 'rust-') }}",
    save: "${{ github.ref == 'refs/heads/main' && startsWith(inputs.concern, 'rust-') && steps.verified-source.outputs.protected-ancestor == 'true' && steps.cargo-sources.outputs.cache-hit != 'true' }}"
  },
  'windows-validation-concern.yml' => {
    restore: "${{ #{PV} && startsWith(inputs.concern, 'rust-') }}",
    save: "${{ github.ref == 'refs/heads/main' && startsWith(inputs.concern, 'rust-') && steps.verified-source.outputs.protected-ancestor == 'true' && steps.cargo-sources.outputs.cache-hit != 'true' }}"
  }
}.freeze

cache_uses = ->(step) { step['uses'].to_s.strip.downcase.start_with?('actions/cache') }
target_cache_uses = ->(step) { step['uses'].to_s.downcase.include?('rust-target-cache') }
path_set = ->(step) { step.dig('with', 'path').to_s.lines.map(&:strip).reject(&:empty?) }
crate_sources = lambda do |step, base|
  pin = SOURCES[base]
  return false if pin.nil? || !step.is_a?(Hash)
  uses = step['uses'].to_s
  w = step['with'].is_a?(Hash) ? step['with'] : {}
  if uses.start_with?('actions/cache/restore@') && step['id'] == 'cargo-sources'
    step['if'].to_s == pin[:restore] && path_set.call(step) == [SOURCES_PATH] && w['key'] == SOURCES_KEY &&
      w['restore-keys'].to_s.strip == SOURCES_RESTORE_KEYS && (w.keys - %w[path key restore-keys]).empty?
  elsif uses.start_with?('actions/cache/save@')
    step['if'].to_s == pin[:save] && path_set.call(step) == [SOURCES_PATH] && w['key'] == SAVE_KEY && (w.keys - %w[path key]).empty?
  else
    false
  end
end

LOOKBEHIND = '(?<![\w.\[\]])'
LITERAL = /#{LOOKBEHIND}inputs\.concern == '([a-z0-9-]+)'/
PREFIX = /#{LOOKBEHIND}startsWith\(inputs\.concern, '([a-z0-9-]+)'\)/
SELECTOR = /#{LITERAL.source}|#{PREFIX.source}/

# The selector tokens of an `if` (or nil with a failure message). The text, minus the single selector
# conjunct, must not mention the inputs context at all (any case, any spelling).
read_selector = lambda do |text|
  inner = text.strip
  inner = inner[3...-2].strip if inner.start_with?('${{') && inner.end_with?('}}')
  terms = CacheExpression.top_terms(text)
  terms = [inner] if terms.nil? && inner.match?(/\A[^\n]*\z/) # a root `||` is one term; it must still be a pure selector list
  pure = lambda do |term|
    t = term.strip
    x = t.gsub(SELECTOR, 'X')
    x.match?(/\A\(\s*X(\s*\|\|\s*X)*\s*\)\z/) || x.match?(/\A\s*X(\s*\|\|\s*X)*\s*\z/) ? t : nil
  end
  picked = terms.map { |term| [term, pure.call(term)] }.select { |_, sel| sel }
  return [nil, 'no concern selector conjunct that is a plain list of lower-case inputs.concern selectors (an unselected compiled-cache step selects every concern)'] if picked.empty?
  return [nil, 'more than one concern selector conjunct'] if picked.length > 1
  rest = (terms - [picked.first.first]).join(' ')
  return [nil, "mentions the inputs context outside the concern selector (#{rest[/[^\n]*inputs[^\n]*/i].to_s.strip[0, 80]})"] if rest.match?(/inputs/i)
  sel = picked.first.last
  tokens = sel.scan(SELECTOR).map { |lit, pre| pre ? "prefix:#{pre}" : lit }
  [tokens.sort, nil]
end

failures = []
ARGV.each do |path|
  base = File.basename(path)
  text = File.read(path, encoding: 'UTF-8')
  documents = YAML.parse_stream(text).children.length
  if documents != 1
    failures << "#{path}: #{documents} YAML documents (a workflow file must hold exactly one; only the first is read by the checks)"
    next
  end
  doc = YAML.safe_load(text, aliases: false) || {}
  steps = (doc['jobs'] || {}).values.flat_map { |job| job.is_a?(Hash) ? Array(job['steps']) : [] }.select { |s| s.is_a?(Hash) }
  # Positive identification: every cache step is a compiled-cache step unless it is exactly a reviewed
  # crate-sources step; a path pattern decides nothing (aliased paths cannot hide a step).
  compiled = steps.select { |s| (cache_uses.call(s) || target_cache_uses.call(s)) && !crate_sources.call(s, base) }
  allow = CONCERNS[base]
  if allow.nil?
    failures << "#{path}: compiled-dependency cache steps in a workflow with no reviewed concern allowlist (add it to CONCERNS in check-cache-groups.rb, in review)" unless compiled.empty?
    next
  end
  kind = lambda do |s|
    u = s['uses'].to_s
    return :save if u.start_with?('actions/cache/save@')
    return :restore if u.start_with?('actions/cache/restore@')
    return "composite-#{s.dig('with', 'mode')}".to_sym if u == './.github/actions/rust-target-cache'
    :other
  end
  kinds = compiled.map(&kind)
  expected_kinds = %i[composite-locate restore composite-restored composite-save save].sort
  unless kinds.sort == expected_kinds
    failures << "#{path}: the cache steps other than the reviewed crate-sources pair must be exactly one each of locate, restore, restore-time strip, strip-and-prove and save (found #{kinds.inspect})"
    next
  end
  save = compiled.find { |s| kind.call(s) == :save }
  locate = compiled.find { |s| kind.call(s) == :'composite-locate' }
  restore = compiled.find { |s| kind.call(s) == :restore }
  if compiled.empty?
    failures << "#{path}: no compiled-dependency cache steps were found (an empty parse proves nothing)"
    next
  end
  unless save && locate && restore
    failures << "#{path}: the compiled-dependency cache needs its locate, restore and save steps"
    next
  end

  # Rules 2 and 3: every compiled step carries one readable selector, and the selectors are the exact
  # reviewed set of its side. The group mapping may name only reviewed restore concerns.
  selectors = {}
  compiled.each do |step|
    tokens, problem = read_selector.call(step['if'].to_s)
    if problem
      failures << "#{path}: step #{step['name'].inspect}: #{problem}"
      next
    end
    selectors[step] = tokens
    side = kind.call(step) == :save || kind.call(step) == :'composite-save' ? :save : :restore
    expected = allow[side].sort
    failures << "#{path}: step #{step['name'].inspect} selects #{tokens.inspect}, not the reviewed #{side} set #{expected.inspect}" unless tokens == expected
    group_text = step.dig('with', 'group').to_s
    next if group_text.empty?

    rest = group_text.gsub(/\(#{LITERAL.source} && '[^']+'\)/, '')
    failures << "#{path}: step #{step['name'].inspect}: the group expression mentions the inputs context in a form this check cannot read" if rest.match?(/inputs/i)
    group_text.scan(/\(#{LITERAL.source} && '[^']+'\)/).flatten.each do |name|
      failures << "#{path}: the group mapping names #{name}, which is not a reviewed cached concern" unless allow[:restore].include?(name)
    end
  end

  # Rules 6 and 7.
  tokens = ->(step) { selectors[step] || [] }
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
  puts "compiled cache groups: #{ARGV.size} workflows checked"
else
  warn failures.uniq.join("\n")
  exit 1
end
