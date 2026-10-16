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
  ".github/workflows/linux-validation-concern.yml"
  ".github/workflows/select-concerns.yml"
  ".github/workflows/live-proof-arm.yml"
  ".github/workflows/pg8-measurement-arm.yml"
)
protected_dispatch_workflows=(
  ".github/workflows/windows-validation.yml"
  ".github/workflows/linux-validation.yml"
  # Dispatch-only: validates the engine selection and fans out to live-proof-arm.yml.
  ".github/workflows/live-proofs.yml"
  # Dispatch-only: binds a PG8 measurement request and fans out to its protected arm.
  ".github/workflows/pg8-measurement.yml"
)
