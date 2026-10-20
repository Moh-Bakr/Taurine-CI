# frozen_string_literal: true

# The reviewed shape of the docs-only fast path inside validate-public-changes.yml (required, not run).
#
# The policy workflow has two reviewed layouts while the fast path lands in two steps (docs/how-ci-works.md,
# "Docs-only fast path" and "Changing the policy"):
#   - the sharded layout: `policy` (the required check) is an aggregate over the base pass and four
#     shards, all unconditional;
#   - the classified layout: a first job, `classify`, decides from the changed paths whether the pull
#     request is documentation only. When it is, `policy-docs` (a few minutes) runs instead of the
#     four shards and the base pass, which are skipped. `policy` accepts exactly two outcomes: classify
#     succeeded and either (docs_only=true) policy-docs succeeded and everything heavy was skipped, or
#     (docs_only=false) everything heavy succeeded and policy-docs was skipped. Any other mix fails.
#
# Every checker that pins the workflow (check-policy-steps.rb, check-strict-structure.rb,
# test-base-policy-result.sh, test-policy-aggregate.sh, test-docs-fast-path-layout.sh) reads the
# classified layout from here, so there is one statement of it. REQUIRED says whether this tree's own
# policy refuses the sharded layout: false while the layout is accepted beside the old one (the
# precursor), true once the workflow has changed and the old layout is gone.
module DocsFastPathShape
  REQUIRED = true

  CHECKOUT = 'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1'
  CHECKOUT_COMMENT = 'v7.0.1'
  SHARDS = %w[policy-evidence policy-fixtures policy-mutations policy-structure].freeze
  # Jobs the heavy half comprises: skipped on a documentation-only change, and never otherwise.
  GATED = (%w[base-pass] + SHARDS).freeze
  GATE_IF = "needs.classify.outputs.docs_only != 'true'"
  DOCS_IF = "needs.classify.outputs.docs_only == 'true'"
  AGGREGATE_NEEDS = %w[base-pass classify policy-docs policy-evidence policy-fixtures policy-mutations policy-structure].freeze
  JOB_IDS = %w[base-pass classify policy policy-docs policy-evidence policy-fixtures policy-mutations policy-structure].freeze

  CLASSIFY_RUN = <<~'RUN'
    set -euo pipefail
    classifier=base-policy/.github/policy/classify-docs-change.rb
    if [[ ! -f "${classifier}" ]]; then
      echo 'docs_only=false' >> "${GITHUB_OUTPUT}"
      echo '::notice title=docs-only fast path::the base commit has no classifier, so the full policy runs'
      exit 0
    fi
    ruby --disable-gems "${classifier}" --repo pr
  RUN

  # The first job. It runs the classifier from the BASE commit's checkout (never from the pull request,
  # so the pull request cannot alter its own classification) over a read-only checkout of the merge commit.
  CLASSIFY_JOB = {
    'permissions' => { 'contents' => 'read' },
    'name' => 'Classify the change',
    'runs-on' => 'ubuntu-24.04',
    'timeout-minutes' => 5,
    'outputs' => { 'docs_only' => '${{ steps.classify.outputs.docs_only }}' },
    'steps' => [
      {
        'name' => "Check out the base commit's policy",
        'uses' => CHECKOUT,
        'with' => {
          'ref' => '${{ github.event.pull_request.base.sha || github.sha }}',
          'path' => 'base-policy',
          'fetch-depth' => 1,
          'persist-credentials' => false
        }
      },
      {
        'name' => 'Check out the merge commit under test',
        'uses' => CHECKOUT,
        'with' => { 'path' => 'pr', 'fetch-depth' => 0, 'persist-credentials' => false }
      },
      {
        'name' => 'Classify the changed paths',
        'id' => 'classify',
        'shell' => 'bash',
        'env' => {
          'EVENT_NAME' => '${{ github.event_name }}',
          'BASE_SHA' => '${{ github.event.pull_request.base.sha }}',
          'HEAD_SHA' => '${{ github.event.pull_request.head.sha }}',
          'MERGE_SHA' => '${{ github.sha }}'
        },
        'run' => CLASSIFY_RUN
      }
    ]
  }.freeze

  # The short job for a documentation-only change.
  POLICY_DOCS_JOB = {
    'permissions' => { 'contents' => 'read' },
    'name' => 'Policy docs-only checks',
    'needs' => ['classify'],
    'if' => DOCS_IF,
    'runs-on' => 'ubuntu-24.04',
    'timeout-minutes' => 5,
    'steps' => [
      {
        'name' => 'Check out public policy repository',
        'uses' => CHECKOUT,
        'with' => { 'fetch-depth' => 2, 'persist-credentials' => false }
      },
      {
        'name' => 'Reject private-source and credential material in a documentation change',
        'shell' => 'bash',
        'run' => 'bash .github/policy/check-repository.sh'
      },
      {
        'name' => 'Check the documentation change for whitespace errors',
        'shell' => 'bash',
        'run' => 'bash .github/policy/check-docs-diff.sh'
      }
    ]
  }.freeze

  # The two aggregate guards of the classified layout, exact. Each is self-contained: it requires the
  # classification to have succeeded and to be exactly true or false, and then the exact results that
  # outcome allows. (The guards sit in this file as heredocs; the workflow's `run` blocks must equal them.)
  CLASSIFY_CHECK = <<~'SH'
    if [[ "${CLASSIFY_RESULT}" != 'success' ]]; then
      echo "::error::the classify job did not pass (result: ${CLASSIFY_RESULT})"
      exit 1
    fi
  SH

  GUARD_BASE_RUN = <<~SH
    set -euo pipefail
    #{CLASSIFY_CHECK.chomp}
    case "${DOCS_ONLY}" in
      true) expected=skipped ;;
      false) expected=success ;;
      *) echo "::error::the classification is neither true nor false (docs_only: '${DOCS_ONLY}')"; exit 1 ;;
    esac
    if [[ "${BASE_PASS_RESULT}" != "${expected}" ]]; then
      echo "::error::the base-policy workflow ended ${BASE_PASS_RESULT}, expected ${expected} (docs_only: ${DOCS_ONLY})"
      exit 1
    fi
    echo "base policy: the base-policy workflow ended ${BASE_PASS_RESULT}, as expected for docs_only=${DOCS_ONLY}"
  SH

  GUARD_SHARDS_RUN = <<~SH
    set -euo pipefail
    #{CLASSIFY_CHECK.chomp}
    case "${DOCS_ONLY}" in
      true) expected=skipped; docs_expected=success ;;
      false) expected=success; docs_expected=skipped ;;
      *) echo "::error::the classification is neither true nor false (docs_only: '${DOCS_ONLY}')"; exit 1 ;;
    esac
    failed=0
    for pair in "evidence:${POLICY_EVIDENCE_RESULT}" "fixtures:${POLICY_FIXTURES_RESULT}" "mutations:${POLICY_MUTATIONS_RESULT}" "structure:${POLICY_STRUCTURE_RESULT}"; do
      if [[ "${pair#*:}" != "${expected}" ]]; then
        echo "::error::the policy ${pair%%:*} shard ended ${pair#*:}, expected ${expected} (docs_only: ${DOCS_ONLY})"
        failed=1
      fi
    done
    if [[ "${POLICY_DOCS_RESULT}" != "${docs_expected}" ]]; then
      echo "::error::the policy docs-only job ended ${POLICY_DOCS_RESULT}, expected ${docs_expected} (docs_only: ${DOCS_ONLY})"
      failed=1
    fi
    [[ "${failed}" -eq 0 ]] || exit 1
    echo "policy checks: every policy job ended as expected for docs_only=${DOCS_ONLY}"
  SH

  GUARD_PINS = [
    {
      'name' => 'Require the base-policy workflow to have passed',
      'if' => '${{ always() }}',
      'shell' => 'bash',
      'env' => {
        'BASE_PASS_RESULT' => '${{ needs.base-pass.result }}',
        'CLASSIFY_RESULT' => '${{ needs.classify.result }}',
        'DOCS_ONLY' => '${{ needs.classify.outputs.docs_only }}'
      },
      'run' => GUARD_BASE_RUN
    },
    {
      'name' => 'Require every policy check shard to have passed',
      'if' => '${{ always() }}',
      'shell' => 'bash',
      'env' => {
        'POLICY_EVIDENCE_RESULT' => '${{ needs.policy-evidence.result }}',
        'POLICY_FIXTURES_RESULT' => '${{ needs.policy-fixtures.result }}',
        'POLICY_MUTATIONS_RESULT' => '${{ needs.policy-mutations.result }}',
        'POLICY_STRUCTURE_RESULT' => '${{ needs.policy-structure.result }}',
        'POLICY_DOCS_RESULT' => '${{ needs.policy-docs.result }}',
        'CLASSIFY_RESULT' => '${{ needs.classify.result }}',
        'DOCS_ONLY' => '${{ needs.classify.outputs.docs_only }}'
      },
      'run' => GUARD_SHARDS_RUN
    }
  ].freeze

  # The sharded layout's jobs as a hash, from the parsed workflow: true when it has any trace of the
  # fast path, so a half-made layout is not mistaken for the sharded one.
  def self.classified?(jobs)
    jobs.key?('classify') || jobs.key?('policy-docs')
  end

  def deep_copy(obj)
    Marshal.load(Marshal.dump(obj))
  end
  module_function :deep_copy

  # The sharded layout's parsed workflow made into the classified one. Used by the fixtures only: the
  # precursor's tree is sharded, and the checkers must accept the classified layout it does not have yet.
  def self.synthesize(doc)
    out = deep_copy(doc)
    jobs = out.fetch('jobs')
    gated = jobs.slice(*GATED)
    gated.each_value do |job|
      job['needs'] = ['classify']
      job['if'] = GATE_IF
    end
    aggregate = jobs.fetch('policy')
    aggregate['needs'] = AGGREGATE_NEEDS.dup
    aggregate['steps'] = deep_copy(GUARD_PINS)
    out['jobs'] = { 'classify' => deep_copy(CLASSIFY_JOB) }.merge(jobs).merge('policy-docs' => deep_copy(POLICY_DOCS_JOB))
    out
  end
end
