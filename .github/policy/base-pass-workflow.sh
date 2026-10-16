#!/usr/bin/env bash
# Finds the workflow file that holds the base-pass step (sourced, not run). Run from the repository
# root.
#
# The step is in the public policy entrypoint today and is meant to move to the reusable workflow
# beside it (public_policy_reusable_workflow). The tests that run the step itself must work on either
# layout, because the base commit's copy of them runs against a pull request's tree and the move
# lands in two merges. Exactly one of the two files may hold the step: none means a rename left the
# tests with nothing to test, two means a copy could be tested in place of the one that runs.
base_pass_policy_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=workflow-lists.sh
source "${base_pass_policy_dir}/workflow-lists.sh"

# The two paths are assigned in workflow-lists.sh, sourced above.
# shellcheck disable=SC2154
locate_base_pass_workflow() {
  local step="$1" candidate
  local -a found=()
  for candidate in "${public_policy_reusable_workflow}" "${public_policy_workflow}"; do
    [[ -f "${candidate}" ]] || continue
    if ruby "${base_pass_policy_dir}/extract-step.rb" "${candidate}" "${step}" run > /dev/null 2>&1; then
      found+=("${candidate}")
    fi
  done
  if (( ${#found[@]} != 1 )); then
    echo "base-pass: expected exactly one public policy workflow to hold the step '${step}', found ${#found[@]}" >&2
    return 1
  fi
  printf '%s\n' "${found[0]}"
}
