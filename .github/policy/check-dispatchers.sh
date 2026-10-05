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
    if [[ "$workflow" != "$public_policy_workflow" && "$workflow" != "./$public_policy_workflow" ]] && \
      grep -nE 'pull_request_target:|workflow_run:|workflow_call:|actions/(upload|download)-artifact|actions/cache|id-token:[[:space:]]*write|secrets\.' "$workflow"; then
      echo "Unsafe trigger, artifact/cache path, OIDC grant, or Actions secret found in public policy workflows: $workflow" >&2
      exit 1
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
  if ! grep -qE '^[[:space:]]+source_sha:' "$workflow" || ! grep -qE '\^\[0-9a-fA-F\]\{40\}' "$workflow"; then
    echo "The protected dispatcher must require a full source SHA: $workflow" >&2
    exit 1
  fi
  # Every protected dispatcher passes exactly one secret, the source-reader App key,
  # by name, to each workflow it calls; none inherits secrets. KeelDock's dedicated
  # environment may name its key differently (a reviewed set) and names its
  # environment once.
  if grep -qE '^[[:space:]]+secrets:[[:space:]]+inherit' "$workflow"; then
    echo "A protected dispatcher must not inherit secrets: $workflow" >&2
    exit 1
  fi
  calls="$(grep -cE '^    uses:' "$workflow")"
  if [[ "$(grep -cE '^      [A-Z_]+:[[:space:]]+\$\{\{ secrets\.' "$workflow")" != "${calls}" ]]; then
    echo "Every workflow a protected dispatcher calls must receive exactly one secret, the App private key: $workflow" >&2
    exit 1
  fi
  if [[ "$workflow" == ".github/workflows/keeldock-validation.yml" ]]; then
    if ! grep -qE '^      SOURCE_READER_PRIVATE_KEY:[[:space:]]+\$\{\{ secrets\.(SOURCE_READER_PRIVATE_KEY|KEELDOCK_SOURCE_READER_PRIVATE_KEY) \}\}[[:space:]]*$' "$workflow"; then
      echo "The KeelDock dispatcher must pass exactly the App private key, by a reviewed name: $workflow" >&2
      exit 1
    fi
    if [[ "$(grep -cE '^[[:space:]]+environment:[[:space:]]+(source-read|keeldock-source-read)[[:space:]]*(#.*)?$' "$workflow")" != 1 ]]; then
      echo "The KeelDock dispatcher must name its environment once, as source-read or keeldock-source-read: $workflow" >&2
      exit 1
    fi
  elif [[ "$(grep -cE '^      SOURCE_READER_PRIVATE_KEY:[[:space:]]+\$\{\{ secrets\.SOURCE_READER_PRIVATE_KEY \}\}[[:space:]]*$' "$workflow")" != "${calls}" ]]; then
    echo "The protected dispatcher must pass secrets.SOURCE_READER_PRIVATE_KEY by name to each called workflow: $workflow" >&2
    exit 1
  fi
  if [[ "$workflow" == ".github/workflows/windows-validation.yml" ]] && ! grep -qE 'uses:[[:space:]]+\./\.github/workflows/windows-validation-concern\.yml' "$workflow"; then
    echo "The protected Windows dispatcher must call the reviewed concern workflow: $workflow" >&2
    exit 1
  fi
  if [[ "$workflow" == ".github/workflows/keeldock-validation.yml" ]] && ! grep -qE 'uses:[[:space:]]+\./\.github/workflows/keeldock-validation-concern\.yml' "$workflow"; then
    echo "The protected KeelDock dispatcher must call the reviewed concern workflow: $workflow" >&2
    exit 1
  fi
  if [[ "$workflow" == ".github/workflows/linux-validation.yml" ]] && ! grep -qE 'uses:[[:space:]]+\./\.github/workflows/linux-validation-concern\.yml' "$workflow"; then
    echo "The protected Linux dispatcher must call the reviewed concern workflow: $workflow" >&2
    exit 1
  fi
}
