#!/usr/bin/env bash
# The explicit trust tiers of the public CI repository (sourced, not run).

# Keep workflow entrypoints directly under .github/workflows: GitHub
# does not discover nested workflow files. The explicit trust-tier
# lists separate the public policy gate from source-bearing jobs and
# make adding a new protected lane an auditable policy change.
public_policy_workflow=".github/workflows/validate-public-changes.yml"
# The reusable half of the public policy gate. The base-policy pass is meant to move out of the
# entrypoint into this workflow, which the entrypoint calls and whose result its policy job still
# requires. Named here, ahead of the file, so the checks that govern a public workflow already know
# it before the move lands: a pull request is judged by the base commit's checks.
public_policy_reusable_workflow=".github/workflows/base-policy.yml"
protected_source_workflows=(
  ".github/workflows/source-read.yml"
  ".github/workflows/linux-validation-concern.yml"
  # Reusable and source-bearing: selects concerns from the private diff.
  ".github/workflows/select-concerns.yml"
  ".github/workflows/macos-validation.yml"
  # The macOS split (#336): the reusable concern workflow is named here, ahead of the file, like
  # base-policy.yml, so the base commit's checks already know its tier when the split lands.
  ".github/workflows/macos-validation-concern.yml"
  ".github/workflows/windows-validation-concern.yml"
  # The macOS matrix job becomes this reusable workflow (docs/untrusted-readonly-cache.md, section 6).
  ".github/workflows/macos-validation-concern.yml"
  ".github/workflows/android-validation.yml"
  ".github/workflows/ios-validation.yml"
  ".github/workflows/orchestrate-validation.yml"
  # One arm of the env-gated live database proofs: a reusable workflow called by
  # the live-proofs dispatcher. It checks out the exact private SHA, runs one
  # engine's conformance suite against its documented single-node Docker server
  # and publishes only a sanitized summary (check titles and counts, never data
  # values).
  ".github/workflows/live-proof-arm.yml"
  # The standalone DBX PG8 measurement arm shares the same source-read rules.
  ".github/workflows/pg8-measurement-arm.yml"
)
reusable_protected_workflows=(
  ".github/workflows/macos-validation-concern.yml"
  ".github/workflows/windows-validation-concern.yml"
  ".github/workflows/macos-validation-concern.yml"
  ".github/workflows/linux-validation-concern.yml"
  ".github/workflows/select-concerns.yml"
  ".github/workflows/live-proof-arm.yml"
  ".github/workflows/pg8-measurement-arm.yml"
)
protected_dispatch_workflows=(
  ".github/workflows/windows-validation.yml"
  # macOS is classified by shape (see classify_workflow): while its matrix job is inline it holds the
  # source-read environment and is checked as a source workflow; once the job moves to the reusable
  # concern workflow it has none and is checked as a dispatcher, exactly like Windows.
  ".github/workflows/macos-validation.yml"
  ".github/workflows/linux-validation.yml"
  # Dispatch-only: validates the engine selection and fans out to live-proof-arm.yml.
  ".github/workflows/live-proofs.yml"
  # Dispatch-only: binds a PG8 measurement request and fans out to its protected arm.
  ".github/workflows/pg8-measurement.yml"
)

# classify_workflow FILE: prints `source` (check_protected_source) or `dispatcher` (check_dispatcher).
# A workflow in protected_source_workflows is a source workflow, except one that is also listed in
# protected_dispatch_workflows and carries no source access in its PARSED structure (classify-workflow.rb:
# no environment, no source-checkout or App-token step, no secret or variable reference outside a
# reusable call's own secrets map): that is a pure dispatcher whose source jobs live in a reusable
# concern workflow. Indentation never decides it. Any other protected source workflow stays a source
# workflow, so check_protected_source still refuses it.
workflow_lists_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
classify_workflow() {
  local file="$1" candidate in_source=0 in_dispatch=0
  for candidate in "${protected_source_workflows[@]}"; do
    [[ "${file}" == "${candidate}" || "${file}" == "./${candidate}" ]] && in_source=1
  done
  for candidate in "${protected_dispatch_workflows[@]}"; do
    [[ "${file}" == "${candidate}" || "${file}" == "./${candidate}" ]] && in_dispatch=1
  done
  if (( in_source )) && ! { (( in_dispatch )) && [[ "$(ruby "${workflow_lists_dir}/classify-workflow.rb" "${file}")" == dispatcher ]]; }; then
    echo source
  else
    echo dispatcher
  fi
}
