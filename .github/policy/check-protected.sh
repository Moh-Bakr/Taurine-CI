#!/usr/bin/env bash
# Source-bearing workflow checks (sourced).

check_protected_source() {
  local workflow="$1" reusable_protected reusable_workflow uses_source_checkout secret_reference variable_reference

  check_revocation_order "$workflow" || { echo "Token revocation ordering violated: $workflow" >&2; exit 1; }
  reusable_protected=0
  for reusable_workflow in "${reusable_protected_workflows[@]}"; do
    if [[ "$workflow" == "$reusable_workflow" || "$workflow" == "./$reusable_workflow" ]]; then
      reusable_protected=1
      break
    fi
  done
  if (( reusable_protected )); then
    if ! grep -qE '^on:[[:space:]]*$' "$workflow" || ! grep -qE '^[[:space:]]+workflow_call:[[:space:]]*$' "$workflow"; then
      echo "The protected reusable workflow must be workflow_call-only: $workflow" >&2
      exit 1
    fi
    if grep -nE '^[[:space:]]+(pull_request|pull_request_target|push|schedule|workflow_run|repository_dispatch|workflow_dispatch):' "$workflow"; then
      echo "The protected reusable workflow has an unapproved trigger: $workflow" >&2
      exit 1
    fi
  else
    if ! grep -qE '^on:[[:space:]]*$' "$workflow" || ! grep -qE '^[[:space:]]+workflow_dispatch:[[:space:]]*$' "$workflow"; then
      echo "The protected source workflow must be workflow_dispatch-only: $workflow" >&2
      exit 1
    fi
    if grep -nE '^[[:space:]]+(pull_request|pull_request_target|push|schedule|workflow_run|repository_dispatch|workflow_call):' "$workflow"; then
      echo "The source-read workflow has an unapproved trigger: $workflow" >&2
      exit 1
    fi
  fi
  # The KeelDock concern takes its environment as an input so a dedicated environment
  # is a one-line change in its dispatcher; the dispatcher's value is checked below.
  if ! grep -qE '^    environment:[[:space:]]+(source-read|\$\{\{ inputs\.environment \}\})[[:space:]]*$' "$workflow"; then
    echo "The protected source workflow must use the protected source-read environment: $workflow" >&2
    exit 1
  fi
  if ! grep -qE 'SOURCE_REPOSITORY_ID:[[:space:]]*['"'"']?[0-9]{7,}['"'"']?[[:space:]]*$' "$workflow"; then
    echo "The source-read workflow must pin a numeric source repository ID: $workflow" >&2
    exit 1
  fi
  # A job that uses the source-checkout composite gets the SHA validation, the
  # identity check and the revocation from it (and the composite's own
  # structure is enforced in check_composite_action); only a workflow with
  # its own inline checkout must show them in its own text.
  uses_source_checkout=0
  if grep -qE '^[[:space:]]+uses:[[:space:]]+\./\.github/actions/source-checkout([[:space:]]|$)' "$workflow"; then
    uses_source_checkout=1
  fi
  if ! grep -qE '^[[:space:]]+source_sha:' "$workflow" \
    || { (( ! uses_source_checkout )) && ! grep -qE '\^\[0-9a-fA-F\]\{40\}' "$workflow"; }; then
    echo "The source-read workflow must require and validate a full source SHA: $workflow" >&2
    exit 1
  fi
  if ! grep -qE 'SOURCE_READER_PRIVATE_KEY' "$workflow" || ! grep -qE 'SOURCE_READER_APP_ID' "$workflow"; then
    echo "The protected source workflow must use only the reviewed source-reader settings: $workflow" >&2
    exit 1
  fi
  if grep -nE 'id-token:[[:space:]]*write|actions/(upload|download)-artifact|secrets\[[^]]+\]' "$workflow"; then
    echo "The source-read workflow contains an unsafe secret, OIDC, or artifact pattern: $workflow" >&2
    exit 1
  fi
  check_cache_policy "$workflow"
  while IFS= read -r secret_reference; do
    case "$secret_reference" in
      secrets.SOURCE_READER_PRIVATE_KEY) ;;
      '') ;;
      *)
        echo "The source-read workflow references an unapproved secret: $secret_reference" >&2
        exit 1
        ;;
    esac
  done < <(grep -oE 'secrets\.[A-Za-z0-9_]+' "$workflow" | sort -u)
  while IFS= read -r variable_reference; do
    case "$variable_reference" in
      vars.SOURCE_READER_APP_ID) ;;
      '') ;;
      *)
        echo "The source-read workflow references an unapproved variable: $variable_reference" >&2
        exit 1
        ;;
    esac
  done < <(grep -oE 'vars\.[A-Za-z0-9_]+' "$workflow" | sort -u)
  if (( ! uses_source_checkout )) && { ! grep -qE 'skip-token-revoke:[[:space:]]*true' "$workflow" || ! grep -qE 'installation/token' "$workflow"; }; then
    echo "The source-read workflow must explicitly revoke its token before project code: $workflow" >&2
    exit 1
  fi
  check_keeldock_concern "$workflow"
}
