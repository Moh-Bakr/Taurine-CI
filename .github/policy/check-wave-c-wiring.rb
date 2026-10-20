#!/usr/bin/env ruby
# frozen_string_literal: true

# Wiring of the Wave C checks. Wave C adds three policy tests to the policy workflow and one early step to the
# Linux concern workflow, and its tests are written to pass until a tree runs them (they land first, in a
# precursor, so the base pass can judge the tree that adds them). That leaves one gap: a tree that has the Wave C
# shape but quietly drops one of those four steps would skip the matching test and pass. This check closes it.
# Once the Wave C shape is present (the Linux dispatcher has no `plan` job and carries the long-pole jobs), all
# four must be there, exactly:
#   - the policy workflow runs test-timings-table.sh, test-rust-app-shards.sh and test-suite-ownership-check.sh,
#     each as a plain `bash .github/policy/<script>` step with only name, shell and run;
#   - the Linux concern workflow runs refuse-unowned-tests.rb as an unconditional, untolerated step, after the
#     source checkout and the root drop;
#   - the scripts themselves exist.
# The Linux concern workflow's reviewed environment is pinned as well, because the early ownership step and every
# step after it run inside it: the workflow `env` is exactly the three source-repository variables, the validate job
# has no `env` of its own, its `defaults.run` is exactly the working directory `src`, and the workflow has no
# `defaults`. A different shell, directory, PATH-shaped variable or injected variable changes what those steps run.
# A tree without the Wave C shape fails: the shape is no longer transitional, so a dispatcher that loses it is a
# regression, not a tree that predates it. Run from the repository root.
require 'yaml'

def load_yaml(path)
  YAML.safe_load(File.read(path, encoding: 'UTF-8'), aliases: false) || {}
end

problems = []
linux = load_yaml('.github/workflows/linux-validation.yml')
jobs = linux['jobs'] || {}
wave_c = !jobs.key?('plan') && jobs.key?('validate-long-main') && jobs.key?('validate-long-untrusted')
problems << 'the Linux dispatcher no longer has the Wave C shape (no plan job; the long-pole jobs validate-long-main and validate-long-untrusted present)' unless wave_c

policy_steps = (load_yaml('.github/workflows/validate-public-changes.yml')['jobs'] || {}).values.flat_map { |job| job.is_a?(Hash) ? (job['steps'] || []) : [] }
%w[test-timings-table.sh test-rust-app-shards.sh test-suite-ownership-check.sh].each do |script|
  problems << "the policy workflow no longer runs #{script}" if policy_steps.none? { |s| s.is_a?(Hash) && s['run'] == "bash .github/policy/#{script}" && s.keys.sort == %w[name run shell] && s['shell'] == 'bash' }
  problems << "#{script} is missing" unless File.file?(".github/policy/#{script}")
end
problems << 'refuse-unowned-tests.rb is missing' unless File.file?('.github/policy/refuse-unowned-tests.rb')

concern_doc = load_yaml('.github/workflows/linux-validation-concern.yml')
validate_job = (concern_doc['jobs'] || {}).fetch('validate', {})
REVIEWED_WORKFLOW_ENV = { 'SOURCE_REPOSITORY_ID' => '1330267721', 'SOURCE_REPOSITORY_OWNER' => 'Moh-Bakr', 'SOURCE_REPOSITORY_NAME' => 'Taurine' }.freeze
REVIEWED_JOB_DEFAULTS = { 'run' => { 'working-directory' => 'src' } }.freeze
problems << "the Linux concern workflow env must be exactly #{REVIEWED_WORKFLOW_ENV.inspect}" unless concern_doc['env'] == REVIEWED_WORKFLOW_ENV
problems << 'the Linux concern workflow must have no workflow-level defaults' if concern_doc.key?('defaults')
problems << 'the Linux concern validate job must have no env of its own' if validate_job.key?('env')
problems << "the Linux concern validate job defaults must be exactly #{REVIEWED_JOB_DEFAULTS.inspect}" unless validate_job['defaults'] == REVIEWED_JOB_DEFAULTS
concern = validate_job['steps'] || []
index = concern.index { |s| s.is_a?(Hash) && s['run'].to_s.include?('ruby .github/policy/refuse-unowned-tests.rb') }
if index.nil?
  problems << 'the Linux concern workflow no longer runs refuse-unowned-tests.rb'
else
  step = concern[index]
  problems << 'the ownership step is conditional or tolerated' if step.key?('if') || step.key?('continue-on-error')
  # The step is the reviewed command and nothing else: a substring match would pass `... || true` or an `echo` prefix.
  reviewed_run = "set -euo pipefail\nruby .github/policy/refuse-unowned-tests.rb \"${GITHUB_WORKSPACE}/src\""
  problems << 'the ownership step must run exactly the reviewed command' unless step['run'].to_s.sub(/\n\z/, '') == reviewed_run
  problems << 'the ownership step must use shell: bash' unless step['shell'] == 'bash'
  extra = step.keys - %w[name shell working-directory run]
  problems << "the ownership step carries keys beyond name, shell, working-directory and run: #{extra.sort.join(', ')}" unless extra.empty?
  problems << 'the ownership step must run in the workspace' if step.key?('working-directory') && step['working-directory'] != '${{ github.workspace }}'
  checkout = concern.index { |s| s.is_a?(Hash) && s['uses'].to_s == './.github/actions/source-checkout' }
  drop = concern.index { |s| s.is_a?(Hash) && s['uses'].to_s == './.github/actions/drop-root' }
  problems << 'the ownership step must follow the source checkout and the root drop' unless checkout && drop && checkout < drop && drop < index
end

if problems.empty?
  puts 'wave C wiring: the three policy tests, the early ownership step and the reviewed concern env and defaults are all present'
else
  problems.each { |p| warn p }
  exit 1
end
