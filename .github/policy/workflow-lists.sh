#!/usr/bin/env bash
# The explicit trust tiers of the public CI repository (sourced, not run).

# Keep workflow entrypoints directly under .github/workflows: GitHub
# does not discover nested workflow files. The explicit trust-tier
# lists separate the public policy gate from source-bearing jobs and
# make adding a new protected lane an auditable policy change.
public_policy_workflow=".github/workflows/validate-public-changes.yml"
protected_source_workflows=(
  ".github/workflows/source-read.yml"
  ".github/workflows/linux-validation-concern.yml"
  # Reusable and source-bearing: selects concerns from the private diff.
  ".github/workflows/select-concerns.yml"
  ".github/workflows/macos-validation.yml"
  ".github/workflows/windows-validation-concern.yml"
  ".github/workflows/android-validation.yml"
  ".github/workflows/ios-validation.yml"
  ".github/workflows/orchestrate-validation.yml"
  # Second private source: Moh-Bakr/keeldock-cloud rather than Taurine.
  ".github/workflows/keeldock-validation-concern.yml"
  # One arm of the env-gated live database proofs: a reusable workflow called by
  # the live-proofs dispatcher. It checks out the exact private SHA, runs one
  # engine's conformance suite against its documented single-node Docker server
  # and publishes only a sanitized summary (check titles and counts, never data
  # values).
  ".github/workflows/live-proof-arm.yml"
)
reusable_protected_workflows=(
  ".github/workflows/windows-validation-concern.yml"
  ".github/workflows/linux-validation-concern.yml"
  ".github/workflows/select-concerns.yml"
  ".github/workflows/keeldock-validation-concern.yml"
  ".github/workflows/live-proof-arm.yml"
)
protected_dispatch_workflows=(
  ".github/workflows/windows-validation.yml"
  ".github/workflows/linux-validation.yml"
  ".github/workflows/keeldock-validation.yml"
  # Dispatch-only: validates the engine selection and fans out to live-proof-arm.yml.
  ".github/workflows/live-proofs.yml"
)
