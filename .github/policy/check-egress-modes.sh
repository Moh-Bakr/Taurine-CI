#!/usr/bin/env bash
# Egress mode per Linux concern (ci-matrix.json, `egress`): block enforces the reviewed
# allow-list (the egress-audit composite's enforce phase, through egress-block); audit only records.
#
# Every Linux concern names its mode. Block is the rule for a concern whose project code runs
# without Docker on the runner itself; audit is an exception, and an exception must carry its
# reason in `egress_audit_reason` (JSON has no comments, so the reason field is the comment).
# A concern switched back to audit without that reason fails here.
# Usage: check-egress-modes.sh [ci-matrix.json]. Run from the repository root.
set -euo pipefail
matrix="${1:-.github/ci-matrix.json}"
ruby - "${matrix}" <<'RUBY'
require 'json'
linux = JSON.parse(File.read(ARGV[0]))['concerns']['linux']
problems = []
counts = Hash.new(0)
linux.each do |name, spec|
  mode = spec['egress']
  reason = spec['egress_audit_reason']
  case mode
  when 'block'
    counts['block'] += 1
    problems << "#{name}: egress_audit_reason is set but the mode is block; remove it" unless reason.nil?
  when 'audit'
    counts['audit'] += 1
    unless reason.is_a?(String) && reason.strip.length >= 20
      problems << "#{name}: egress is audit without an egress_audit_reason (a Linux concern without Docker blocks unless the exception is explained)"
    end
  else
    problems << "#{name}: egress must be \"block\" or \"audit\" (found #{mode.inspect})"
  end
end
unless problems.empty?
  warn problems.join("\n")
  exit 1
end
puts "egress modes: #{counts['block']} Linux concerns block, #{counts['audit']} audit (each with a recorded reason)"
RUBY
