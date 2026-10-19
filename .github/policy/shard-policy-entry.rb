#!/usr/bin/env ruby
# frozen_string_literal: true

# Prints the sharded layout of validate-public-changes.yml, derived from the single-job layout:
# `policy` becomes a thin aggregate (two guards, no checkout) and this pull request's own checks move
# into four shard jobs that need no other job and so run beside the base pass. Used by
# test-policy-aggregate.sh to prove the checkers accept that layout and refuse each weakening of it,
# and once to write the reviewed layout itself. Every step of the single job lands in exactly one
# shard (the script aborts otherwise), each with its own checkout. Usage: shard-policy-entry.rb FILE
SHARDS = {
  'policy-structure' => ['Check out public policy repository', "Test rule N's block-scalar if refusal"],
  'policy-mutations' => ['Prove each reviewed weakening fails the policy'],
  'policy-evidence' => [/case-evidence|Playwright/]
}.freeze
TITLES = {
  'policy-structure' => 'Policy structure and lint',
  'policy-fixtures' => 'Policy fixtures and unit tests',
  'policy-evidence' => 'Policy case-evidence tests',
  'policy-mutations' => 'Policy mutations'
}.freeze

s = File.read(ARGV[0])
abort 'already sharded' if s.include?("\n  policy-structure:\n")
i = s.index('      - name: Check out public policy repository') or abort 'no checkout step'
j = s.index("  # The base commit's policy run against this pull request's tree") or abort 'no base-pass job'
checkout = s[i...s.index("\n\n", i) + 1]
body = s[(i + checkout.length)...j].sub(/\A\n+/, '').rstrip
steps = []
cur = []
body.lines.each do |l|
  if l.start_with?('      - name: ')
    carried = []
    carried.unshift(cur.pop) while cur.last&.start_with?('      #')
    steps << cur.join unless cur.empty?
    cur = carried
  end
  cur << l
end
steps << cur.join
steps = steps.map { |t| "      #{t.strip}\n" }
names = steps.map { |t| t[/- name: (.*)$/, 1] }
abort "unnamed step: #{steps[names.index(nil)][0, 200].inspect}" if names.any?(&:nil?)

struct_end = names.index("Test rule N's block-scalar if refusal")
shard_of = lambda do |idx, name|
  if idx <= struct_end then 'policy-structure'
  elsif name == 'Prove each reviewed weakening fails the policy' then 'policy-mutations'
  elsif name.match?(/case-evidence|Playwright/) then 'policy-evidence'
  else 'policy-fixtures'
  end
end
groups = Hash.new { |h, k| h[k] = [] }
steps.each_with_index { |t, idx| groups[shard_of.call(idx, names[idx])] << t }
abort "a shard is empty: #{TITLES.keys - groups.keys}" unless (TITLES.keys - groups.keys).empty?
abort 'step count mismatch' unless groups.values.sum(&:size) == steps.size

agg = <<~'Y'
  jobs:
    # The required status check, and nothing else: an aggregate. It runs no checkout and none of this
    # pull request's scripts, only the two guards below, so the result it reports cannot be changed by
    # anything the pull request carries. It needs the base pass (below) and every policy shard, and
    # fails unless each ended in success; a skipped, cancelled or failed job is not a pass. All of them
    # run at the same time, so the gate costs the longest of them, not their sum.
    policy:
      permissions: {}
      name: Validate workflow policy
      needs: [base-pass, policy-evidence, policy-fixtures, policy-mutations, policy-structure]
      if: ${{ always() }}
      runs-on: ubuntu-24.04
      timeout-minutes: 25
      steps:
        # FIRST, before the checkout and before any step that runs this pull request's scripts, and no
        # such step may follow it in this job: those can append to GITHUB_ENV or GITHUB_PATH (BASH_ENV,
        # PATH, RUBYOPT) and so change how any LATER step's shell behaves, this guard included. The
        # base-policy pass runs in its own workflow (below), so the result it reached cannot be influenced
        # by anything the checks export; this step keeps the required status check honest: it fails when
        # that workflow did not pass. It needs nothing from the repository. test-base-policy-result.sh
        # pins its position.
        - name: Require the base-policy workflow to have passed
          if: ${{ always() }}
          shell: bash
          env:
            BASE_PASS_RESULT: ${{ needs.base-pass.result }}
          run: |
            set -euo pipefail
            if [[ "${BASE_PASS_RESULT}" != 'success' ]]; then
              echo "::error::the base-policy workflow did not pass (result: ${BASE_PASS_RESULT})"
              exit 1
            fi
            echo 'base policy: the base-policy workflow passed'

        # The same rule for this pull request's own policy, which runs in the four shards: every one must
        # have succeeded, so a shard that is skipped, cancelled, failed or dropped from `needs` cannot pass.
        - name: Require every policy check shard to have passed
          if: ${{ always() }}
          shell: bash
          env:
            POLICY_EVIDENCE_RESULT: ${{ needs.policy-evidence.result }}
            POLICY_FIXTURES_RESULT: ${{ needs.policy-fixtures.result }}
            POLICY_MUTATIONS_RESULT: ${{ needs.policy-mutations.result }}
            POLICY_STRUCTURE_RESULT: ${{ needs.policy-structure.result }}
          run: |
            set -euo pipefail
            failed=0
            for pair in "evidence:${POLICY_EVIDENCE_RESULT}" "fixtures:${POLICY_FIXTURES_RESULT}" "mutations:${POLICY_MUTATIONS_RESULT}" "structure:${POLICY_STRUCTURE_RESULT}"; do
              if [[ "${pair#*:}" != 'success' ]]; then
                echo "::error::the policy ${pair%%:*} shard did not pass (result: ${pair#*:})"
                failed=1
              fi
            done
            [[ "${failed}" -eq 0 ]] || exit 1
            echo 'policy checks: every policy shard passed'

Y
out = +''
%w[policy-structure policy-fixtures policy-evidence policy-mutations].each do |name|
  out << "  # #{ {
    'policy-structure' => "This pull request's own policy, shard 1: repository contents, lint, universal and\n  # structure rules.",
    'policy-fixtures' => "Shard 2: fixture and unit tests of the policy scripts, selectors, dispatch contracts and live-proof pins.",
    'policy-evidence' => "Shard 3: the case-evidence contract, producers and Playwright parity tests.",
    'policy-mutations' => "Shard 4: every reviewed weakening applied to a copy of the tree and rejected."
  }[name] }\n  # Needs no other job: it runs beside the base pass and holds no authority;\n  # only `policy` decides the required check.\n"
  out << "  #{name}:\n    permissions:\n      contents: read\n    name: #{TITLES[name]}\n    runs-on: ubuntu-24.04\n    timeout-minutes: 25\n    steps:\n"
  out << checkout.rstrip << "\n\n"
  out << groups[name].join("\n") << "\n"
end
head = s[0...s.index("jobs:\n")]
puts head + agg + out + "\n" + s[j..]
