#!/usr/bin/env ruby
# frozen_string_literal: true

# Where check-structure.rb --strict runs, and nowhere else.
#
# --strict turns the "final shape while a transitional alternative remains" warning into an error.
# That is right for the policy job's own copy of the policy, where step B has already deleted its
# alternatives, and wrong anywhere the base pass reaches: the base pass runs main's scripts against
# the pull request's real tree, where a step-B tree matches only the final shape while main's
# manifest still lists the transitional one. So:
#
#   1. The policy job of validate-public-changes.yml must have ONE dedicated step whose `run` is exactly
#      `ruby .github/policy/check-structure.rb --strict`, whose keys are exactly name, shell and run,
#      whose shell is exactly `bash` (the default `bash -e {0}`), and the job's `if` must be exactly
#      ${{ always() }} with no job `continue-on-error`. So there is no `exit 0`, `set +e`, `|| true`,
#      heredoc, uncalled function or trap to dodge it, no `if`, `env` or `working-directory` to steer
#      it, and a pull request cannot drop or soften it and still pass main's copy of this check.
#   2. No other script under .github/policy runs --strict on a real tree. check-structure.rb defines
#      it and this file names it; test-structure.sh may use it only on its synthetic tree (a line
#      that names synth.rb or the synthetic marker). Any other non-comment line that could run it with
#      `--strict` is refused.
#
# Run from the repository root.
require 'yaml'

problems = []
workflow = '.github/workflows/validate-public-changes.yml'
doc = YAML.safe_load(File.read(workflow, encoding: 'UTF-8'), aliases: false)
job = (doc['jobs'] || {})['policy'] || {}
strict_line = 'ruby .github/policy/check-structure.rb --strict'
steps = (job['steps'] || []).select { |st| st['run'].to_s.lines.any? { |l| l.include?('check-structure.rb') && l.include?('--strict') } }
if steps.size != 1
  problems << "the policy job must have exactly one step that runs check-structure.rb --strict (found #{steps.size})"
else
  step = steps.first
  problems << "the strict step's run must be exactly: #{strict_line} (got #{step['run'].inspect})" unless step['run'].to_s.strip == strict_line && step['run'].to_s.lines.size == 1
  problems << "the strict step must use shell: bash (got #{step['shell'].inspect})" unless step['shell'] == 'bash'
  extra = step.keys - %w[name shell run]
  problems << "the strict step may only have name, shell and run (found #{extra.inspect})" unless extra.empty?
end
problems << 'the policy job may not carry continue-on-error' if job.key?('continue-on-error')
problems << "the policy job's if must be exactly ${{ always() }}" unless job['if'].to_s.strip == '${{ always() }}'

# Not covered: a pull request can neuter the strict block inside its own check-structure.rb, and an
# earlier step of the policy job (which runs the pull request's own scripts) could export BASH_ENV
# through GITHUB_ENV. Main's base pass cannot see either; review holds them.
allowed = %w[check-structure.rb check-strict-structure.rb test-mutations.sh]
Dir.glob('.github/policy/*.{sh,rb}').sort.each do |file|
  base = File.basename(file)
  next if allowed.include?(base)

  File.read(file, encoding: 'UTF-8').lines.each_with_index do |line, i|
    next unless line.include?('--strict')
    next if line.lstrip.start_with?('#')
    # Only a line that could run it counts: a message that names the flag is a string, not an invocation.
    next unless line.match?(/ruby|\$\{check\}|\$\{runner|check-structure/)
    next if base == 'test-structure.sh' && (line.include?('synth.rb') || line.include?('synthetic'))

    problems << "#{file}:#{i + 1}: --strict outside the policy job and the synthetic tree: #{line.strip[0, 120]}"
  end
end

if problems.empty?
  puts 'strict structure: the policy job runs check-structure.rb --strict as a plain step, and no policy script runs it on a real tree'
else
  problems.each { |p| warn p }
  exit 1
end
