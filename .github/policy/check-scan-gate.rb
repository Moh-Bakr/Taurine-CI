#!/usr/bin/env ruby
# frozen_string_literal: true
# The security scan gate: both scan concerns are in the full Linux set, the four scanners stay
# enforcing and required in `scan-security`, and the Rust lint job keeps its enforcing steps.
# Run from the repository root (check-workflows.sh does).
require 'json'
require 'yaml'

problems = []
table = JSON.parse(File.read('.github/ci-matrix.json')).dig('concerns', 'linux')
%w[scan-security scan-lint].each do |name|
  spec = table[name]
  if spec.nil?
    problems << "ci-matrix.json: #{name} is missing from the full Linux set"
    next
  end
  problems << "ci-matrix.json: #{name} must not be opt-in" if spec.key?('opt_in')
  problems << "ci-matrix.json: #{name} must be full_only and always selected" unless spec['full_only'] == true && spec['always'] == true
end

concern = YAML.safe_load(File.read('.github/workflows/linux-validation-concern.yml'), aliases: false)
steps = concern.dig('jobs').values.flat_map { |j| j['steps'] || [] }
scan_steps = steps.select { |s| s['uses'].to_s == './.github/actions/scan-concern' }
by_scanner = scan_steps.group_by { |s| s.dig('with', 'scanner') }
{ 'all' => "inputs.concern == 'scan-security'", 'clippy' => "inputs.concern == 'scan-lint'" }.each do |scanner, cond|
  found = by_scanner[scanner] || []
  problems << "linux-validation-concern.yml: expected exactly one scan-concern step with scanner: #{scanner}" unless found.length == 1
  found.each do |s|
    problems << "linux-validation-concern.yml: the scanner: #{scanner} step must run only for #{cond}" unless s['if'].to_s.strip == cond
    problems << "linux-validation-concern.yml: the scanner: #{scanner} step must not continue on error" if s.key?('continue-on-error')
  end
end
enforce = steps.select { |s| s['uses'].to_s == './.github/actions/rust-lint-enforce' }
problems << 'linux-validation-concern.yml: expected exactly one rust-lint-enforce step' unless enforce.length == 1
enforce.each do |s|
  problems << 'linux-validation-concern.yml: rust-lint-enforce must run for scan-lint' unless s['if'].to_s.include?("inputs.concern == 'scan-lint'")
  fail_input = (s['with'] || {})['fail']
  problems << 'linux-validation-concern.yml: rust-lint-enforce must not be made report-only' unless fail_input.nil? || fail_input.to_s == 'true'
  problems << 'linux-validation-concern.yml: rust-lint-enforce must not continue on error' if s.key?('continue-on-error')
end

action = YAML.safe_load(File.read('.github/actions/scan-concern/action.yml'), aliases: false)
asteps = action.dig('runs', 'steps')
{ 'scan-gitleaks' => 'gitleaks', 'scan-npm' => 'npm-audit', 'scan-semgrep' => 'semgrep', 'scan-deny' => 'deny' }.each do |id, tag|
  s = asteps.find { |x| x['id'] == id }
  if s.nil?
    problems << "scan-concern: the #{id} scanner step is missing"
    next
  end
  problems << "scan-concern: #{id} must run for scanner: all" unless s['if'].to_s.include?("inputs.scanner == 'all'") && s['if'].to_s.include?("inputs.scanner == '#{tag}'")
end
clippy = asteps.find { |x| x['id'] == 'scan-clippy' }
problems << "scan-concern: the clippy scanner must run only for scanner: clippy" unless clippy && clippy['if'].to_s.strip == "${{ inputs.scanner == 'clippy' }}"
report = asteps.find { |x| x['name'].to_s.start_with?('Report every scanner') }
if report.nil?
  problems << 'scan-concern: the scanner report step is missing'
else
  problems << 'scan-concern: the report step must run always for scanner: all' unless report['if'].to_s.strip == "${{ always() && inputs.scanner == 'all' }}"
  %w[gitleaks npm-audit semgrep cargo-deny].each do |n|
    problems << "scan-concern: the report loop no longer fails on #{n}" unless report['run'].to_s.include?("\"#{n}|")
  end
  %w[GITLEAKS NPM SEMGREP DENY].each do |v|
    problems << "scan-concern: report env #{v}_OUTCOME is missing" unless (report['env'] || {}).key?("#{v}_OUTCOME")
  end
  problems << 'scan-concern: the report step must fail when any scanner did not succeed' unless report['run'].to_s.include?('if [[ "${outcome}" != success ]]; then failed=1; fi') && report['run'].to_s.rstrip.end_with?('[[ "${failed}" -eq 0 ]]')
end

unless problems.empty?
  warn problems.join("\n")
  exit 1
end
puts 'scan gate: scan-security and scan-lint are in the full set; the four scanners and the lint enforcement stay enforcing'
