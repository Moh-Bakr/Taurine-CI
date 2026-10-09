#!/usr/bin/env bash
# Check the concern table against the dispatcher
#
# The concern table (.github/ci-matrix.json) drives the Linux dispatcher's matrix and
# the selector; the result check lists the concerns it expects. They must be the same
# set, so a concern added to one cannot be silently missing from the verdict.
# Run from the repository root (the policy workflow does).
set -euo pipefail
ruby <<'RUBY'
require 'json'
require 'yaml'
table = JSON.parse(File.read('.github/ci-matrix.json'))['concerns']['linux'].keys.sort
wf = YAML.safe_load(File.read('.github/workflows/linux-validation.yml'), aliases: false)
step = wf['jobs']['result']['steps'].find { |st| st['uses'].to_s == './.github/actions/run-result' }
# The Result job expects exactly what the plan job computed from the table (every
# non-opt-in concern, plus an opt-in one when its input is true), never a second,
# hand-kept list that could drift from the table.
unless step['with']['expected-concerns'].to_s == '$' + '{{ needs.plan.outputs.expected }}' && wf['jobs']['result']['needs'].include?('plan')
  warn 'The Linux Result job must take its expected concerns from the plan job output'
  exit 1
end
unless step['with']['required-concerns'].to_s == '$' + '{{ toJSON(fromJSON(needs.select.outputs.matrix || needs.plan.outputs.matrix || \'{"concern":[]}\').concern) }}' && wf['jobs']['result']['needs'].include?('select')
  warn 'The Linux Result job must require every concern in the selected matrix to run'
  exit 1
end
opt_in = JSON.parse(File.read('.github/ci-matrix.json'))['concerns']['linux'].select { |_, sp| sp.key?('opt_in') }
opt_in.each do |name, sp|
  known = (wf['on'] || wf[true])['workflow_dispatch']['inputs'].key?(sp['opt_in'])
  warn "#{name}: opt_in names an input (#{sp['opt_in']}) the Linux dispatcher does not declare" unless known
  exit 1 unless known
end
# Stale-concern lint: every concern has a timeout; the concern workflow handles it
# (by name, or by the scan-/e2e- prefix groups); every baseline key names a real
# concern. A concern added to one place and forgotten in another fails here.
full = JSON.parse(File.read('.github/ci-matrix.json'))['concerns']['linux']
# The concern bodies live in the linux-concern-* composites (one per family).
concern_text = ([ '.github/workflows/linux-validation-concern.yml' ] + Dir.glob('.github/actions/linux-concern-*/action.yml')).map { |f| File.read(f, encoding: 'UTF-8') }.join("\n")
problems = []
full.each do |name, spec|
  problems << "#{name}: no integer timeout in ci-matrix.json" unless spec['timeout'].is_a?(Integer)
  handled = name.start_with?('scan-', 'e2e-') || concern_text.match?(/(?<![A-Za-z0-9-])#{Regexp.escape(name)}(?![A-Za-z0-9-])/)
  problems << "#{name}: not handled by linux-validation-concern.yml or a linux-concern-* action" unless handled
end
timing = wf['jobs']['timings']['steps'].find { |st| st['uses'].to_s == './.github/actions/timings' }
JSON.parse(timing['with']['baseline-seconds']).each_key do |name|
  problems << "baseline for #{name}: no such concern in ci-matrix.json" unless full.key?(name)
end
unless problems.empty?
  warn problems.join("\n")
  exit 1
end
puts "concern table: #{table.length} Linux concerns (#{opt_in.length} opt-in) match the plan and the result check"
mode_by_workflow = {
  '.github/workflows/linux-validation.yml' => "${{ inputs.profile == 'full' && inputs.base_sha == '' && 'full' || 'partial' }}",
  '.github/workflows/macos-validation.yml' => "${{ inputs.rust && 'full' || 'partial' }}",
  '.github/workflows/windows-validation.yml' => "${{ inputs.rust && 'full' || 'partial' }}",
  '.github/workflows/android-validation.yml' => "${{ inputs.rust && 'full' || 'partial' }}",
  '.github/workflows/ios-validation.yml' => "${{ inputs.rust && 'full' || 'partial' }}",
  '.github/workflows/orchestrate-validation.yml' => 'full'
}
required_by_workflow = {
  '.github/workflows/linux-validation.yml' => "${{ toJSON(fromJSON(needs.select.outputs.matrix || needs.plan.outputs.matrix || '{\"concern\":[]}').concern) }}",
  '.github/workflows/macos-validation.yml' => "${{ toJSON(fromJSON(needs.plan.outputs.matrix || '{\"concern\":[]}').concern) }}",
  '.github/workflows/windows-validation.yml' => "${{ inputs.rust && '[\"desktop-shard-1\",\"desktop-shard-2\",\"desktop-quality\",\"mobile\",\"contracts\",\"bundle-budget\",\"rust-domain\",\"rust-db\",\"rust-net\",\"rust-ovpn\",\"rust-app-1\",\"rust-app-2\",\"rust-packaging\",\"rust-tls-openssl\"]' || '[\"desktop-shard-1\",\"desktop-shard-2\",\"desktop-quality\",\"mobile\",\"contracts\",\"bundle-budget\"]' }}",
  '.github/workflows/android-validation.yml' => "${{ toJSON(fromJSON(needs.plan.outputs.matrix || '{\"concern\":[]}').concern) }}",
  '.github/workflows/ios-validation.yml' => "${{ toJSON(fromJSON(needs.plan.outputs.matrix || '{\"concern\":[]}').concern) }}"
}
needs_by_workflow = {
  '.github/workflows/linux-validation.yml' => %w[plan select],
  '.github/workflows/macos-validation.yml' => %w[plan],
  '.github/workflows/android-validation.yml' => %w[plan],
  '.github/workflows/ios-validation.yml' => %w[plan]
}
mode_by_workflow.each do |path, expected_mode|
  parsed = YAML.safe_load(File.read(path), aliases: false)
  callers = parsed.fetch('jobs').values.flat_map { |job| job['steps'] || [] }.select { |step| step['uses'].to_s == './.github/actions/run-result' }
  unless callers.length == 1 && callers.first.fetch('with', {})['selection-mode'] == expected_mode
    warn "#{path}: run-result must use its reviewed explicit selection mode"
    exit 1
  end
  expected_required = required_by_workflow[path]
  if expected_required && callers.first.fetch('with', {})['required-concerns'] != expected_required
    warn "#{path}: partial mode must require every concern in its selected matrix"
    exit 1
  end
  required_needs = needs_by_workflow[path] || []
  unless (required_needs - Array(parsed.fetch('jobs').fetch('result')['needs'])).empty?
    warn "#{path}: Result must depend on the jobs that supply its selected concern list"
    exit 1
  end
end
puts 'run-result callers: all dispatchers declare their reviewed full/partial contract'
RUBY
# Each Linux concern's egress mode (block, or audit with its recorded reason).
bash .github/policy/check-egress-modes.sh
