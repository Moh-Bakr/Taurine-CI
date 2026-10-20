#!/usr/bin/env ruby
# frozen_string_literal: true

# Step coverage of the policy gate. A step the pull request deletes, or turns into `echo ok`, passes
# every other check, because those verify the jobs around the steps and not the steps. This check
# pins them: the policy steps of validate-public-changes.yml (every step with a `run`, apart from the
# two aggregate guards that test-base-policy-result.sh pins) must be exactly the reviewed table below.
#
#   - the set of step names equals the table, with no step missing, added or repeated;
#   - each step's `run` and `env` equal the pinned values, and it carries no other key than name,
#     shell: bash, env and run (no `if`, `continue-on-error`, `working-directory`);
#   - each step sits in the job the layout requires: `policy` while the entrypoint is the single job,
#     and the pinned shard (first column) once it is sharded, where `policy` itself holds no
#     such step;
#   - a `uses` step may only be the pinned checkout with exactly its pinned `with` keys.
#
# Two modes, because this check is judged from two sides. A pull request carries its own copy, and main's
# copy judges the pull request's tree in the base pass; a table that had to match exactly on both sides
# would deadlock every later change (main's table lacks the new row, the PR's tree lacks nothing).
#   - Default (superset, what the base pass runs): every table row must be present exactly as pinned, but
#     a step NOT in the table is allowed when it is a plain, shape-checked extra: keys exactly name,
#     shell: bash, run (no env); a unique name that is no table row, guard or the required
#     check's name; a `run` of one line `bash|ruby|python3 .github/policy/<file>` with no arguments, so no
#     `|| true`, `;`, `&&`, `$(` or heredoc; in a shard (or `policy` in the single-job layout), never in
#     the aggregate; naming an existing script whose extension matches its interpreter; and after the
#     last pinned step of its job. The order of the pinned steps within a job is deliberately NOT enforced:
#     pinning it would recreate the add-or-change deadlock for any legitimate reorder. Removing or changing a pinned step stays
#     refused.
#   - `--exact` (the policy step of this workflow): the table is this tree's own and must match exactly,
#     extras refused, so a pull request that adds a step must add its row in the same change.
# Two reviewed layouts of the workflow (docs-fast-path-shape.rb): the sharded one, and the classified one, where
# a first job `classify` and a short job `policy-docs` are added, the base pass and the four shards wait for
# `classify` and are skipped on a documentation-only change, and the two aggregate guards read the
# classification. The classified layout's jobs, gates and guards are pinned exactly in that file; this check
# applies them whenever any trace of the fast path is present, so a half-made layout fails, and it requires
# them when DocsFastPathShape::REQUIRED says the sharded layout is gone.
# Rows are JSON: [shard, step name, run, env]. Run from the repository root.
require 'json'
require 'yaml'
require_relative 'docs-fast-path-shape'
require_relative 'yaml-guard'

exact = ARGV.delete('--exact')
WORKFLOW = '.github/workflows/validate-public-changes.yml'
EXTRA_RUN = %r{\A(bash|ruby|python3) \.github/policy/[A-Za-z0-9._-]+\z}
REQUIRED_NAME = 'Validate workflow policy'
CHECKOUT_USES = 'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1'
CHECKOUT_WITH = { 'fetch-depth' => 1, 'persist-credentials' => false }.freeze
# The two aggregate guards, pinned exactly (they are not table rows: they live in the aggregate, in this
# position, and nowhere else). The second exists only in the sharded layout.
GUARD_PINS = JSON.parse(<<~'GUARDS_JSON')
  [{"name":"Require the base-policy workflow to have passed","if":"${{ always() }}","shell":"bash","env":{"BASE_PASS_RESULT":"${{ needs.base-pass.result }}"},"run":"set -euo pipefail\nif [[ \"${BASE_PASS_RESULT}\" != 'success' ]]; then\n  echo \"::error::the base-policy workflow did not pass (result: ${BASE_PASS_RESULT})\"\n  exit 1\nfi\necho 'base policy: the base-policy workflow passed'\n"},{"name":"Require every policy check shard to have passed","if":"${{ always() }}","shell":"bash","env":{"POLICY_EVIDENCE_RESULT":"${{ needs.policy-evidence.result }}","POLICY_FIXTURES_RESULT":"${{ needs.policy-fixtures.result }}","POLICY_MUTATIONS_RESULT":"${{ needs.policy-mutations.result }}","POLICY_STRUCTURE_RESULT":"${{ needs.policy-structure.result }}"},"run":"set -euo pipefail\nfailed=0\nfor pair in \"evidence:${POLICY_EVIDENCE_RESULT}\" \"fixtures:${POLICY_FIXTURES_RESULT}\" \"mutations:${POLICY_MUTATIONS_RESULT}\" \"structure:${POLICY_STRUCTURE_RESULT}\"; do\n  if [[ \"${pair#*:}\" != 'success' ]]; then\n    echo \"::error::the policy ${pair%%:*} shard did not pass (result: ${pair#*:})\"\n    failed=1\n  fi\ndone\n[[ \"${failed}\" -eq 0 ]] || exit 1\necho 'policy checks: every policy shard passed'\n"}]
GUARDS_JSON
GUARDS = GUARD_PINS.map { |gd| gd['name'] }.freeze
SHARDS = %w[policy-evidence policy-fixtures policy-mutations policy-structure].freeze

rows = DATA.read.lines.map { |l| JSON.parse(l) }
table = {}
rows.each { |shard, name, run, env| table[name] = { 'shard' => shard, 'run' => run, 'env' => env } }
problems = []
problems << 'the step table repeats a step name' unless table.size == rows.size
abort 'the step table has fewer than 40 rows: an empty or truncated table pins nothing' if rows.size < 40

YamlGuard.yaml_duplicates(WORKFLOW).each { |d| problems << "#{WORKFLOW}: #{d}" }
doc = YAML.safe_load(File.read(WORKFLOW, encoding: 'UTF-8'), aliases: false)
jobs = doc['jobs'] || {}
sharded = SHARDS.any? { |name| jobs.key?(name) }
classified = DocsFastPathShape.classified?(jobs)
guard_pins = classified ? DocsFastPathShape::GUARD_PINS : GUARD_PINS
# The classified layout, pinned exactly; a layout that is neither the sharded nor the classified one fails.
if classified
  shape = DocsFastPathShape
  problems << 'the classified layout needs the sharded layout beneath it (all four shards)' unless SHARDS.all? { |name| jobs.key?(name) }
  problems << 'the classify job differs from the reviewed classify job (docs-fast-path-shape.rb): it must be exact' unless jobs['classify'] == shape::CLASSIFY_JOB
  problems << 'the policy-docs job differs from the reviewed policy-docs job (docs-fast-path-shape.rb): it must be exact' unless jobs['policy-docs'] == shape::POLICY_DOCS_JOB
  problems << "the policy aggregate must need exactly #{shape::AGGREGATE_NEEDS.inspect} (got #{(jobs['policy'] || {})['needs'].inspect})" unless (jobs['policy'] || {})['needs'] == shape::AGGREGATE_NEEDS
  shape::GATED.each do |name|
    job = jobs[name] || {}
    problems << "#{name} must need exactly [classify] (got #{job['needs'].inspect})" unless job['needs'] == ['classify']
    problems << "#{name} must carry if: #{shape::GATE_IF} exactly (got #{job['if'].inspect}), so it is skipped on a documentation-only change and never otherwise" unless job['if'] == shape::GATE_IF
  end
  problems << "the classify job must be the first job of the workflow (found #{jobs.keys.first.inspect})" unless jobs.keys.first == 'classify'
  extra_jobs = jobs.keys - shape::JOB_IDS
  problems << "unexpected job(s) #{extra_jobs.join(', ')} beside the classified layout" unless extra_jobs.empty?
elsif DocsFastPathShape::REQUIRED
  problems << 'the policy workflow must be the classified layout (a classify job, a policy-docs job, gated shards and the classified guards): the sharded layout is no longer reviewed'
end
seen = Hash.new(0)
extras = []
last_pinned = {}
(%w[policy] + SHARDS).each do |job_name|
  (jobs[job_name] || {}).fetch('steps', []).each_with_index do |st, index|
    if st.key?('uses')
      ok = st['uses'] == CHECKOUT_USES && st['with'] == CHECKOUT_WITH && (st.keys - %w[name uses with]).empty?
      problems << "#{job_name}: step #{st['name'].inspect} uses #{st['uses'].inspect}: only the pinned checkout with exactly #{CHECKOUT_WITH.keys.join(' and ')} is allowed" unless ok
      next
    end
    next if GUARDS.include?(st['name'])

    name = st['name']
    pinned = table[name]
    seen[name] += 1
    if pinned.nil?
      extras << [job_name, st, index]
      next
    end
    last_pinned[job_name] = index
    want_job = sharded ? pinned['shard'] : 'policy'
    problems << "step #{name.inspect} is in #{job_name}, the reviewed layout puts it in #{want_job}" unless job_name == want_job
    problems << "step #{name.inspect}: run differs from the reviewed command" unless st['run'] == pinned['run']
    problems << "step #{name.inspect}: env differs from the reviewed env" unless (st['env'] || {}) == pinned['env']
    extra = st.keys - %w[name shell env run]
    problems << "step #{name.inspect} carries #{extra.inspect}: no conditions, tolerated failures or other keys" unless extra.empty?
    problems << "step #{name.inspect} must use shell: bash" unless st['shell'] == 'bash'
  end
end
# Guards: each exactly once, in the aggregate at its pinned position with its exact pinned shape; the second
# only in the sharded layout. (A second step carrying a guard's name anywhere is a duplicate.)
guard_pins.each_with_index do |pin, pos|
  holders = jobs.flat_map { |jn, j| (j.is_a?(Hash) ? j.fetch('steps', []) : []).each_with_index.select { |st, _| st['name'] == pin['name'] }.map { |st, i| [jn, i, st] } }
  want = pos.zero? || sharded ? 1 : 0
  problems << "guard #{pin['name'].inspect} appears #{holders.size} times, expected #{want}" unless holders.size == want
  holders.each do |jn, i, st|
    problems << "guard #{pin['name'].inspect} is in #{jn} at step #{i}, expected policy at step #{pos}" unless jn == 'policy' && i == pos
    problems << "guard #{pin['name'].inspect} differs from its pinned shape (name, if, shell, env and run are exact)" unless st == pin
  end
end
extra_names = Hash.new(0)
extras.each { |_, st, _| extra_names[st['name']] += 1 }
extras.each do |job_name, st, index|
  name = st['name']
  if exact
    problems << "#{job_name}: step #{name.inspect} is not in the step table: add its row in the same change"
    next
  end
  why = []
  why << 'keys other than exactly name, shell and run (no env: it could carry a secret or steer the shell)' unless st.keys.sort == %w[name run shell]
  why << 'shell is not bash' unless st['shell'] == 'bash'
  why << 'the name is empty, reserved or repeated' if !name.is_a?(String) || name.empty? || GUARDS.include?(name) || name == REQUIRED_NAME || extra_names[name] > 1
  why << 'run is not one plain command of a policy script' unless st['run'].is_a?(String) && st['run'].match?(EXTRA_RUN)
  script = st['run'].to_s[%r{\A\S+ (\.github/policy/\S+)\z}, 1]
  ext = { 'bash' => '.sh', 'ruby' => '.rb', 'python3' => '.py' }[st['run'].to_s.split.first]
  why << "the script #{script.inspect} is missing or does not match its interpreter's extension" unless script && ext && script.end_with?(ext) && !script.include?('..') && !File.basename(script).start_with?('-') && File.file?(script)
  why << 'it is in the aggregate: only a shard or the single job may hold it' if sharded && job_name == 'policy'
  why << 'it comes before a pinned step of its job' if last_pinned[job_name] && index < last_pinned[job_name]
  problems << "#{job_name}: step #{name.inspect} is not in the reviewed step table and is not a compliant extra (#{why.join('; ')})" unless why.empty?
end
abort 'no policy steps found: the workflow is empty or unreadable' if seen.size < 40
(table.keys - seen.keys).each { |n| problems << "reviewed step #{n.inspect} is missing from the policy jobs: its check would not run" }
seen.each { |n, c| problems << "step #{n.inspect} appears #{c} times" if c > 1 }

if problems.empty?
  puts "policy steps: #{table.size} reviewed steps present once, exact and in the #{sharded ? 'sharded' : 'single-job'} layout#{exact ? '' : " (#{extras.size} extra step(s) accepted)"}"
else
  problems.uniq.each { |p| warn p }
  exit 1
end

__END__
["policy-structure","Reject private-source and credential material","bash .github/policy/check-repository.sh",{}]
["policy-structure","Lint workflows with pinned actionlint and zizmor","bash .github/policy/lint.sh",{"GH_TOKEN":"${{ github.token }}"}]
["policy-structure","Check the universal workflow rules and the Action references","ruby .github/policy/check-universal.rb\nbash .github/policy/test-structure.sh\nbash .github/policy/test-action-uses.sh\nbash .github/policy/test-policy-batching.sh\n",{}]
["policy-structure","Check the control-plane structure, strictly","ruby .github/policy/check-structure.rb \u002d\u002dstrict",{}]
["policy-structure","Check that every policy step is present, exact and in its job","ruby .github/policy/check-policy-steps.rb --exact",{}]
["policy-structure","Enforce immutable reviewed Actions and safe workflow features","bash .github/policy/check-workflows.sh",{}]
["policy-structure","Check workflow and composite file sizes","bash .github/policy/check-sizes.sh",{}]
["policy-structure","Test the policy rules against fixtures","bash .github/policy/test-policy.sh",{}]
["policy-structure","Test rule N's block-scalar if refusal","bash .github/policy/test-rule-n-if-shape.sh",{}]
["policy-fixtures","Test the environment pre-flight against stub endpoints","bash .github/policy/test-preflight.sh",{}]
["policy-fixtures","Test the untrusted cache scope audit against stub endpoints","bash .github/policy/test-cache-scope-audit.sh",{}]
["policy-fixtures","Test the source-token revoke against stub endpoints","bash .github/policy/test-revoke.sh",{}]
["policy-fixtures","Test the weekly openssl-src patch cadence","bash .github/policy/test-weekly-cadence.sh",{}]
["policy-mutations","Prove each reviewed weakening fails the policy","bash .github/policy/test-mutations.sh",{}]
["policy-fixtures","Test the sanitizer expressions against path and token fixtures","bash .github/policy/test-sanitizers.sh",{}]
["policy-fixtures","Test the OpenSSL door's shell checks","bash .github/policy/test-shell-artefact.sh",{}]
["policy-fixtures","Test the compiled dependency cache strip against hostile outputs","bash .github/policy/test-rust-target-cache.sh",{}]
["policy-fixtures","Test the failure-detail extractors against fixtures","bash .github/policy/test-extractors.sh",{}]
["policy-fixtures","Test the rustfmt enforcement default against a stub cargo","bash .github/policy/test-lint-enforce.sh",{}]
["policy-fixtures","Test the all-locks advisory helper wiring and reporting against a stub","bash .github/policy/test-all-locks-audit.sh",{}]
["policy-fixtures","Test the cargo-deny step's exit-code labels and counts against a stub","bash .github/policy/test-scan-deny.sh",{}]
["policy-fixtures","Test unsound advisory enforcement and protected reporting against a stub","bash .github/policy/test-cargo-audit.sh",{}]
["policy-fixtures","Test that the base-pass step is found in either public policy workflow","bash .github/policy/test-base-pass-locate.sh",{}]
["policy-fixtures","Test that the base pass stays on the required status check","bash .github/policy/test-base-policy-result.sh",{}]
["policy-fixtures","Test that the aggregate policy layout stays fail-closed","bash .github/policy/test-policy-aggregate.sh",{}]
["policy-fixtures","Test sanitized build-failure category classification","bash .github/policy/test-build-failure-category.sh",{}]
["policy-fixtures","Check the concern table against the dispatcher","bash .github/policy/check-concern-table.sh",{}]
["policy-fixtures","Test the concern selector on a synthetic repository","bash .github/policy/test-selector.sh",{}]
["policy-fixtures","Test explicit run-result selection mode","bash .github/policy/test-run-result.sh",{}]
["policy-fixtures","Test the Timings table's queue column and per-ref baselines","bash .github/policy/test-timings-table.sh",{}]
["policy-fixtures","Prove the three-way rust-app split is complete on every platform","bash .github/policy/test-rust-app-shards.sh",{}]
["policy-fixtures","Test the early suite-ownership check on synthetic repositories","bash .github/policy/test-suite-ownership-check.sh",{}]
["policy-fixtures","Require the Wave C policy tests and the early ownership step to stay wired","ruby .github/policy/check-wave-c-wiring.rb",{}]
["policy-fixtures","Test the Wave C wiring check on synthetic trees","bash .github/policy/test-wave-c-wiring.sh",{}]
["policy-fixtures","Test the feature-suite catalog contract","bash .github/policy/test-suite-catalog.sh",{}]
["policy-fixtures","Test the exact suite-selection policy on synthetic changes","bash .github/policy/test-suite-selection.sh",{}]
["policy-fixtures","Test the sanitized feature-suite evidence contract","bash .github/policy/test-suite-evidence.sh",{}]
["policy-fixtures","Test the trusted suite-evidence collector on synthetic reports","bash .github/policy/test-suite-collector.sh",{}]
["policy-fixtures","Test the aggregate feature-suite overview","bash .github/policy/test-suite-overview.sh",{}]
["policy-fixtures","Test the suite-selection dispatch review","bash .github/policy/test-suite-dispatch-review.sh",{}]
["policy-evidence","Test the case-evidence structural contract","bash .github/policy/test-case-evidence-contract.sh",{}]
["policy-evidence","Test the case-evidence trust boundary against forged claims","bash .github/policy/test-case-evidence-trust-boundary.sh",{}]
["policy-evidence","Test the Playwright case-evidence producer against a fake runner","bash .github/policy/test-playwright-case-evidence-producer.sh",{}]
["policy-evidence","Check the case-evidence assets for absolute paths","ruby .github/policy/check-case-evidence-assets.rb",{}]
["policy-evidence","Test the case-evidence asset path guard","bash .github/policy/test-case-evidence-assets.sh",{}]
["policy-evidence","Test the pinned Playwright parity fixtures","ruby .github/policy/test-playwright-case-parity-fixtures.rb",{}]
["policy-evidence","Test the pinned Playwright parity producer against a fake runner","bash .github/policy/test-playwright-pinned-parity-producer.sh",{}]
["policy-evidence","Test the case-evidence admission reconciliation","bash .github/policy/test-case-evidence-admission.sh",{}]
["policy-fixtures","Test canonical dispatch identity and input defaults","bash .github/policy/test-dispatch-identity.sh",{}]
["policy-fixtures","Pin the live-proof fan-out from roster to arm runs","ruby .github/policy/check-live-proof-fanout.rb",{}]
["policy-fixtures","Test the live-proof fan-out pin on arm-dropping fixtures","bash .github/policy/test-live-proof-fanout.sh",{}]
["policy-fixtures","Test live-proof roster selection and JSON validity","bash .github/policy/test-live-roster.sh",{}]
["policy-fixtures","Require every registered live-proof arm","ruby .github/policy/check-live-arm-coverage.rb",{}]
["policy-fixtures","Test the live-arm coverage guard on weakened fixtures","ruby .github/policy/test-live-arm-coverage.rb",{}]
["policy-fixtures","Parse PostgreSQL fixture action shell blocks without executing them","bash .github/policy/test-live-start-pg-shell.sh",{}]
["policy-fixtures","Test control-owned PostgreSQL TLS fixtures without certificates or containers","bash .github/policy/test-pgtls-control-fixtures.sh",{}]
["policy-fixtures","Test registered DBX feature coverage and old-source compatibility","bash .github/policy/test-dbx-feature-coverage.sh",{}]
["policy-fixtures","Test PG8 measurement parsers on adversarial fixtures","python3 .github/policy/test-pg8-measurement.py",{}]
["policy-fixtures","Test the dispatch contract policy against weakened fixtures","bash .github/policy/test-dispatch-contracts.sh",{}]
["policy-fixtures","Check the tool pin list and Dependabot coverage","bash .github/policy/check-tools.sh",{}]
["policy-fixtures","Check the egress allow-list","bash .github/policy/check-egress-allowlist.sh",{}]
["policy-fixtures","Test the duplicate-dispatch guard against synthetic runs","bash .github/policy/test-dispatch-dedup.sh",{}]
