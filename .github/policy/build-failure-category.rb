#!/usr/bin/env ruby
# Emit fixed, non-authoritative build-failure diagnostics. Never print input text.
require 'json'

MAX_INPUT_BYTES = 1_048_576
MAX_LINES = 4_096
CATEGORIES = %w[linkerfailed package-or-feature-selection missingtarget dependency-resolution process-signal other].freeze
DISPOSITIONS = %w[input-limit malformed ambiguous no-match helper-unavailable classified].freeze
TARGETS = %w[dbx_pg_tls_live dbx_pg_mtls_live dbx_pg8_performance_live pg8-uat-release selected-live-proof-target].freeze
MATCH_CATEGORIES = %w[linkerfailed package-or-feature-selection missingtarget dependency-resolution].freeze

# The optional disposition is diagnostic metadata only. The category line and its
# values stay identical for callers using the original three-argument interface.
def emit(category, count, target, disposition = nil, matches = nil)
  category = 'other' unless CATEGORIES.include?(category)
  count = [[count.to_i, 1].max, 999].min
  target = 'selected-live-proof-target' unless TARGETS.include?(target)
  puts "build-failure: category=#{category} count=#{count} target=#{target}"
  puts "build-failure-disposition: value=#{disposition}" if DISPOSITIONS.include?(disposition)
  if matches.is_a?(Array)
    safe_matches = MATCH_CATEGORIES.select { |name| matches.include?(name) }
    puts "build-failure-matches: values=#{safe_matches.empty? ? 'none' : safe_matches.join(',')}"
  end
end

def category_for(text)
  rules = {
    'linkerfailed' => [
      /(?:linker|linking with|link command).{0,120}(?:failed|failure)/i,
      /undefined reference to/i, /collect2: error/i, /(?:^|\s)ld(?:\.lld)?: error:/i,
      /unable to find library/i, /link\.exe.{0,80}(?:failed|error)/i
    ],
    'package-or-feature-selection' => [
      /no matching package named/i, /package .{0,120}(?:does not contain|does not have|not found)/i,
      /feature .{0,120}(?:not found|does not exist|unknown|not available)/i,
      /package id specification .{0,120}did not match/i, /selected package .{0,120}does not match/i
    ],
    'missingtarget' => [
      /no (?:test|bin|example|bench|lib)?\s*target named/i,
      /(?:test|bin|example|bench|lib) target .{0,100}(?:not found|does not exist)/i,
      /could not find.{0,80}target/i
    ],
    'dependency-resolution' => [
      /failed to select a version/i, /failed to get .{0,120}(?:dependency|package|source)/i,
      /failed to (?:download|fetch|resolve|query).{0,160}(?:crate|package|dependency|registry|source)/i,
      /unable to update.{0,120}(?:registry|source|package)/i, /version solving failed/i,
      /dependency resolution failed/i, /could not resolve.{0,100}dependency/i
    ]
  }
  matched = MATCH_CATEGORIES.select { |name| rules.fetch(name).any? { |pattern| text.match?(pattern) } }
  if matched.length > 1
    ['other', 'ambiguous', matched]
  elsif matched.length == 1
    [matched.first, 'classified', matched]
  else
    ['other', 'no-match', matched]
  end
end

begin
  format, target, status_text, mode = ARGV
  disposition_mode = mode == '--disposition' && ARGV.length == 4
  valid_arity = ARGV.length == 3 || disposition_mode
  unless valid_arity && %w[text json].include?(format) && TARGETS.include?(target) && status_text&.match?(/\A[1-9][0-9]{0,2}\z/) && status_text.to_i <= 255
    emit('other', 1, target, disposition_mode ? 'malformed' : nil, disposition_mode ? [] : nil)
    exit 0
  end
  status = status_text.to_i
  input = STDIN.read(MAX_INPUT_BYTES + 1)
  if input.bytesize > MAX_INPUT_BYTES || input.lines.length > MAX_LINES
    emit('other', 1, target, disposition_mode ? 'input-limit' : nil, disposition_mode ? [] : nil)
    exit 0
  end
  if status >= 128
    emit('process-signal', 1, target, disposition_mode ? 'classified' : nil, disposition_mode ? [] : nil)
    exit 0
  end

  malformed_json = false
  malformed_shape = false
  text = if format == 'json'
    messages = input.lines.map do |line|
      begin
        record = JSON.parse(line)
      rescue JSON::ParserError
        if line.lstrip.start_with?('{')
          malformed_json = true
          next ''
        end
        next line
      end
      unless record.is_a?(Hash)
        malformed_shape = true
        next ''
      end
      next '' unless record['reason'] == 'compiler-message'
      message = record.dig('message', 'message')
      rendered = record.dig('message', 'rendered')
      raise JSON::ParserError unless message.nil? || message.is_a?(String)
      raise JSON::ParserError unless rendered.nil? || rendered.is_a?(String)
      malformed_shape = true if message.nil? && rendered.nil?
      [message, rendered].compact.join("\n")
    end
    messages.join("\n")
  else
    input
  end

  category, disposition, matched = if malformed_json
    ['other', 'malformed', []]
  else
    category_for(text)
  end
  disposition = 'malformed' if malformed_shape
  error_lines = text.lines.count { |line| line.match?(/\berror(?:\[E[0-9]{4}\])?:/i) }
  emit(category, error_lines.zero? ? 1 : error_lines, target, disposition_mode ? disposition : nil, disposition_mode ? matched : nil)
rescue StandardError
  emit('other', 1, TARGETS.include?(target) ? target : 'selected-live-proof-target', disposition_mode ? 'malformed' : nil, disposition_mode ? [] : nil)
end
