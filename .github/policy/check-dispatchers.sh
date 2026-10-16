#!/usr/bin/env bash
# Protected dispatchers and every other public workflow (sourced).

check_dispatcher() {
  local workflow="$1" protected_dispatch dispatch_workflow calls

  protected_dispatch=0
  for dispatch_workflow in "${protected_dispatch_workflows[@]}"; do
    if [[ "$workflow" == "$dispatch_workflow" || "$workflow" == "./$dispatch_workflow" ]]; then
      protected_dispatch=1
      break
    fi
  done
  if (( ! protected_dispatch )); then
    if [[ "$workflow" == "$public_policy_reusable_workflow" || "$workflow" == "./$public_policy_reusable_workflow" ]]; then
      # The reusable half of the public policy gate. It is called, so workflow_call is its one
      # trigger; every other trigger, artifact or cache path, OIDC grant, secret and environment
      # (an environment is where secrets and approval gates attach) stays refused, and it declares
      # no secrets of its own (the entrypoint passes it none).
      if ! grep -qE '^on:[[:space:]]*$' "$workflow" || ! grep -qE '^[[:space:]]+workflow_call:' "$workflow"; then
        echo "The reusable public policy workflow must be triggered by workflow_call: $workflow" >&2
        exit 1
      fi
      if grep -nE '^[[:space:]]+(pull_request|pull_request_target|push|schedule|workflow_dispatch|workflow_run|repository_dispatch):|actions/(upload|download)-artifact|actions/cache|id-token:[[:space:]]*write|secrets\.|^[[:space:]]+secrets:|^[[:space:]]+environment:' "$workflow"; then
        echo "Unsafe trigger, artifact/cache path, OIDC grant, secret or environment in the reusable public policy workflow: $workflow" >&2
        exit 1
      fi
      return 0
    fi
    if [[ "$workflow" != "$public_policy_workflow" && "$workflow" != "./$public_policy_workflow" ]] && \
      grep -nE 'pull_request_target:|workflow_run:|workflow_call:|actions/(upload|download)-artifact|actions/cache|id-token:[[:space:]]*write|secrets\.' "$workflow"; then
      echo "Unsafe trigger, artifact/cache path, OIDC grant, or Actions secret found in public policy workflows: $workflow" >&2
      exit 1
    fi
    # The cache prune: no checkout or other action, no environment, and no permission but
    # actions: write (listing and deleting cache entries).
    if [[ "$workflow" == *.github/workflows/cache-prune.yml ]]; then
      if grep -nE '^[[:space:]]+(-[[:space:]]+)?uses:|^[[:space:]]+environment:' "$workflow" \
        || grep -nE '^[[:space:]]+[a-z-]+:[[:space:]]+(read|write)[[:space:]]*$' "$workflow" | grep -vE ':[[:space:]]+actions:[[:space:]]+write[[:space:]]*$'; then
        echo "The cache prune may use no action, no environment and only actions: write: $workflow" >&2
        exit 1
      fi
    fi
    return 0
  fi
  if ! grep -qE '^on:[[:space:]]*$' "$workflow" || ! grep -qE '^[[:space:]]+workflow_dispatch:[[:space:]]*$' "$workflow"; then
    echo "The protected dispatcher must be workflow_dispatch-only: $workflow" >&2
    exit 1
  fi
  if grep -nE '^[[:space:]]+(pull_request|pull_request_target|push|schedule|workflow_run|repository_dispatch|workflow_call):' "$workflow"; then
    echo "The protected dispatcher has an unapproved trigger: $workflow" >&2
    exit 1
  fi
  # Trigger, source SHA, secrets and environment rules, read from the parsed workflow so that
  # re-indenting a job cannot hide it from a line-anchored grep (dispatcher-structure.rb).
  ruby "$(dirname "${BASH_SOURCE[0]}")/dispatcher-structure.rb" "$workflow" || exit 1
  if [[ "$workflow" == ".github/workflows/windows-validation.yml" ]] && ! grep -qE 'uses:[[:space:]]+\./\.github/workflows/windows-validation-concern\.yml' "$workflow"; then
    echo "The protected Windows dispatcher must call the reviewed concern workflow: $workflow" >&2
    exit 1
  fi
  if [[ "$workflow" == ".github/workflows/macos-validation.yml" ]] && ! grep -qE 'uses:[[:space:]]+\./\.github/workflows/macos-validation-concern\.yml' "$workflow"; then
    echo "The protected macOS dispatcher must call the reviewed concern workflow: $workflow" >&2
    exit 1
  fi
  if [[ "$workflow" == ".github/workflows/linux-validation.yml" ]] && ! grep -qE 'uses:[[:space:]]+\./\.github/workflows/linux-validation-concern\.yml' "$workflow"; then
    echo "The protected Linux dispatcher must call the reviewed concern workflow: $workflow" >&2
    exit 1
  fi
}
