#!/usr/bin/env ruby
# Emit one fixed, non-authoritative build-failure category. Never print input text.
require 'json'

MAX_INPUT_BYTES = 1_048_576
MAX_LINES = 4_096
CATEGORIES = %w[linkerfailed package-or-feature-selection missingtarget dependency-resolution process-signal other].freeze
TARGETS = %w[dbx_pg_tls_live dbx_pg_mtls_live dbx_pg8_performance_live selected-live-proof-target].freeze

def emit(category, count, target)
  category = 'other' unless CATEGORIES.include?(category)
  count = [[count.to_i, 1].max, 999].min
  target = 'selected-live-proof-target' unless TARGETS.include?(target)
  puts "build-failure: category=#{category} count=#{count} target=#{target}"
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
  matched = rules.filter_map { |name, patterns| name if patterns.any? { |pattern| text.match?(pattern) } }
  matched.length == 1 ? matched.first : 'other'
end

begin
  format, target, status_text = ARGV
  unless %w[text json].include?(format) && TARGETS.include?(target) && status_text&.match?(/\A[1-9][0-9]{0,2}\z/)
    emit('other', 1, target)
    exit 0
  end
  status = status_text.to_i
  input = STDIN.read(MAX_INPUT_BYTES + 1)
  if input.bytesize > MAX_INPUT_BYTES || input.lines.length > MAX_LINES
    emit('other', 1, target)
    exit 0
  end
  if status >= 128
    emit('process-signal', 1, target)
    exit 0
  end

  text = if format == 'json'
    messages = input.lines.map do |line|
      record = JSON.parse(line)
      next '' unless record.is_a?(Hash) && record['reason'] == 'compiler-message'
      message = record.dig('message', 'message')
      rendered = record.dig('message', 'rendered')
      raise JSON::ParserError unless message.nil? || message.is_a?(String)
      raise JSON::ParserError unless rendered.nil? || rendered.is_a?(String)
      [message, rendered].compact.join("\n")
    end
    messages.join("\n")
  else
    input
  end
  category = category_for(text)
  error_lines = text.lines.count { |line| line.match?(/\berror(?:\[E[0-9]{4}\])?:/i) }
  emit(category, error_lines.zero? ? 1 : error_lines, target)
rescue StandardError
  emit('other', 1, TARGETS.include?(target) ? target : 'selected-live-proof-target')
end
