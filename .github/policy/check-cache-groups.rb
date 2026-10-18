# Compiled-dependency cache groups (docs/untrusted-readonly-cache.md, 7.1 follow-up).
# Usage: ruby check-cache-groups.rb CONCERN-WORKFLOW.yml...
#
# Every concern workflow that saves the compiled-dependency cache keys it by a group named in the
# locate step. A cache entry is first-writer-wins, so two different builds saving into one group would
# let whichever ran first decide what the other restores. Rules, for each workflow that has a save step:
#  1. the group of every designated saver (a concern named in the save step's if) is known: a literal
#     mapping in the locate step's group expression, or the one fallback group;
#  2. no two savers share a group, except rust-app-2, the one designated saver of the rust-app shards,
#     which owns the fallback group alone;
#  3. every concern that restores has a saver in its group.
require 'yaml'

failures = []
ARGV.each do |path|
  doc = YAML.safe_load(File.read(path, encoding: 'UTF-8'), aliases: false) || {}
  steps = (doc['jobs'] || {}).values.flat_map { |job| job.is_a?(Hash) ? Array(job['steps']) : [] }.select { |s| s.is_a?(Hash) }
  save = steps.find { |s| s['uses'].to_s.start_with?('actions/cache/save@') && s.dig('with', 'path').to_s.include?('cargo-target') }
  locate = steps.find { |s| s['uses'].to_s == './.github/actions/rust-target-cache' && s.dig('with', 'mode') == 'locate' }
  restore = steps.find { |s| s['uses'].to_s.start_with?('actions/cache/restore@') && s.dig('with', 'path').to_s.include?('cargo-target') }
  next unless save
  unless locate && restore
    failures << "#{path}: a compiled-dependency save needs its locate and restore steps"
    next
  end
  expr = locate.dig('with', 'group').to_s
  mapping = expr.scan(/\(inputs\.concern == '([^']+)' && '([^']+)'\)/).to_h
  fallback = expr[/\|\| '([^']+)' \}\}\z/, 1]
  failures << "#{path}: the locate group expression needs a fallback group" if fallback.nil?
  group_of = lambda { |concern| mapping[concern] || fallback }
  savers = save['if'].to_s.scan(/inputs\.concern == '([^']+)'/).flatten
  failures << "#{path}: the save step names no designated saver" if savers.empty?
  seen = {}
  savers.each do |concern|
    group = group_of.call(concern)
    if seen.key?(group)
      failures << "#{path}: #{concern} and #{seen[group]} both save group #{group}: one designated saver per group"
    end
    seen[group] = concern
  end
  failures << "#{path}: rust-app-2 must be the designated saver of the fallback group" if fallback && seen[fallback] && seen[fallback] != 'rust-app-2'
  restorers = restore['if'].to_s.scan(/inputs\.concern == '([^']+)'/).flatten
  restorers << 'rust-app-1' << 'rust-app-2' if restore['if'].to_s.include?("startsWith(inputs.concern, 'rust-app-')")
  restorers.uniq.each do |concern|
    failures << "#{path}: #{concern} restores group #{group_of.call(concern)}, which no concern saves" unless seen.key?(group_of.call(concern))
  end
end
if failures.empty?
  puts "compiled cache groups: #{ARGV.size} concern workflows checked"
else
  warn failures.uniq.join("\n")
  exit 1
end
