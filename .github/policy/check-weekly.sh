#!/usr/bin/env bash
# The scheduled resolver trust tier (sourced).

check_weekly_resolver() {
  local workflow="$1" dispatched

  # Scheduled SHA resolver: a separate, narrower trust tier. It is the only
  # workflow allowed a `schedule` trigger together with the source-read
  # environment, because it never touches project code: it mints the same
  # reviewed read-only contents token, asks the GitHub API which commit the
  # private `develop` branch points at, revokes the token, and then
  # dispatches the protected validation workflows (which keep every
  # protection of their own) with that SHA using the run's own token. So
  # instead of the dispatch-only rules above, this tier is held to: no
  # checkout of any repository, no project command, no cache or artifact,
  # only the reviewed secret and variable, an explicit revoke, and exactly
  # two permissions (contents: read on the resolver, actions: write on the
  # dispatcher, which holds no secret and no environment).
  if [[ "$workflow" == ".github/workflows/weekly-validation.yml" ]]; then
    if ! grep -qE '^[[:space:]]+schedule:[[:space:]]*$' "$workflow" || ! grep -qE '^[[:space:]]+workflow_dispatch:[[:space:]]*$' "$workflow"; then
      echo "The scheduled resolver must declare schedule and workflow_dispatch: $workflow" >&2
      exit 1
    fi
    if grep -nE '^[[:space:]]+(pull_request|pull_request_target|push|workflow_run|repository_dispatch|workflow_call):' "$workflow"; then
      echo "The scheduled resolver has an unapproved trigger: $workflow" >&2
      exit 1
    fi
    if ! grep -qE '^permissions:[[:space:]]*\{\}[[:space:]]*$' "$workflow"; then
      echo "The scheduled resolver must deny permissions by default at the top level: $workflow" >&2
      exit 1
    fi
    if grep -nE '^      [a-z-]+:[[:space:]]+(read|write)[[:space:]]*$' "$workflow" | grep -vE ':      (contents:[[:space:]]+read|actions:[[:space:]]+write)[[:space:]]*$'; then
      echo "The scheduled resolver may only use contents: read and actions: write: $workflow" >&2
      exit 1
    fi
    if grep -nE 'actions/(checkout|cache|upload-artifact|download-artifact)|id-token:[[:space:]]*write|secrets\[[^]]+\]|^[[:space:]]+repository:' "$workflow"; then
      echo "The scheduled resolver must not check out code, cache, upload artifacts or index secrets: $workflow" >&2
      exit 1
    fi
    if grep -nE '(^|[^A-Za-z-])(npm|npx|pnpm|yarn|cargo|rustc|dotnet|xcodebuild|gradle|gradlew|make|pip|docker)[[:space:]]' "$workflow" | grep -vE '^[0-9]+:[[:space:]]*#'; then
      echo "The scheduled resolver must run no project command: $workflow" >&2
      exit 1
    fi
    if ! grep -qE '^    environment:[[:space:]]+source-read[[:space:]]*$' "$workflow" \
      || ! grep -qE 'SOURCE_REPOSITORY_ID:[[:space:]]*['"'"']?[0-9]{7,}['"'"']?[[:space:]]*$' "$workflow" \
      || ! grep -qE 'permission-contents:[[:space:]]*read' "$workflow" \
      || ! grep -qE 'skip-token-revoke:[[:space:]]*true' "$workflow" \
      || ! grep -qE 'installation/token' "$workflow"; then
      echo "The scheduled resolver must use the source-read environment, a pinned repository ID, a contents-read token and explicit revocation: $workflow" >&2
      exit 1
    fi
    if [[ "$(grep -oE 'secrets\.[A-Za-z0-9_]+' "$workflow" | sort -u)" != "secrets.SOURCE_READER_PRIVATE_KEY" ]] \
      || [[ "$(grep -oE 'vars\.[A-Za-z0-9_]+' "$workflow" | sort -u)" != "vars.SOURCE_READER_APP_ID" ]]; then
      echo "The scheduled resolver references an unapproved secret or variable: $workflow" >&2
      exit 1
    fi
    while IFS= read -r dispatched; do
      case "$dispatched" in
        linux-validation.yml|macos-validation.yml|windows-validation.yml|android-validation.yml|ios-validation.yml) ;;
        *)
          echo "The scheduled resolver may only dispatch the protected validation workflows, not: $dispatched" >&2
          exit 1
          ;;
      esac
    done < <(grep -oE 'gh workflow run [^[:space:]]+' "$workflow" | awk '{print $4}')
    check_revocation_order "$workflow" || { echo "Token revocation ordering violated: $workflow" >&2; exit 1; }
    return 0
  fi

}
