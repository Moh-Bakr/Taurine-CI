#!/usr/bin/env bash
# The workflow-structure policy: reviewed Actions, trust tiers, token revocation order,
# cache, secrets and dispatcher rules. Run from the repository root.
set -euo pipefail

policy=.github/policy
source "${policy}/workflow-lists.sh"
source "${policy}/lib.sh"
source "${policy}/check-actions.sh"
source "${policy}/check-weekly.sh"
source "${policy}/check-cache-policy.sh"
source "${policy}/check-keeldock.sh"
source "${policy}/check-protected.sh"
source "${policy}/check-dispatchers.sh"

# Never cancel a source-bearing run: cancellation can interrupt the step that
# revokes the short-lived source token. Every protected workflow, reusable or
# not, that declares a concurrency group must say cancel-in-progress: false, and
# every non-reusable protected workflow must declare one (a missing group would
# let overlapping dispatches race on the same SHA).
for guarded in "${protected_source_workflows[@]}" "${protected_dispatch_workflows[@]}" .github/workflows/weekly-validation.yml; do
  if grep -qE '^  cancel-in-progress:[[:space:]]*(true|\$\{\{)' "$guarded"; then
    echo "A protected workflow must set cancel-in-progress: false: $guarded" >&2
    exit 1
  fi
  reusable_only=0
  for reusable_workflow in "${reusable_protected_workflows[@]}"; do
    [[ "$guarded" == "$reusable_workflow" ]] && reusable_only=1
  done
  if (( ! reusable_only )) && ! grep -qE '^  cancel-in-progress:[[:space:]]*false[[:space:]]*$' "$guarded"; then
    echo "A protected workflow must declare cancel-in-progress: false: $guarded" >&2
    exit 1
  fi
done

# Windows is intentionally app-only. The full skill verifier is
# required in the protected Ubuntu lane, while macOS retains a
# cross-platform smoke check; it must not be reintroduced as a
# Windows concern that duplicates native process fixtures.
if grep -nE '^[[:space:]]*-[[:space:]]*orchestrate-skill[[:space:]]*$|^[[:space:]]*orchestrate-skill\)' \
  .github/workflows/windows-validation.yml \
  .github/workflows/windows-validation-concern.yml; then
  echo 'Windows validation must remain app-only; orchestrate-skill is covered by Ubuntu/macOS workflows.' >&2
  exit 1
fi
# The macOS smoke body lives in the macos-concern-js composite.
for skill_workflow in \
  .github/workflows/orchestrate-validation.yml \
  .github/actions/macos-concern-js/action.yml; do
  if ! grep -q 'skills/orchestrate/scripts/verify.mjs --json' "${skill_workflow}"; then
    echo "Required orchestrate skill coverage is missing from ${skill_workflow}." >&2
    exit 1
  fi
done


while IFS= read -r -d '' workflow; do
  check_action_references "$workflow"

  if [[ "$workflow" == .github/actions/*/action.yml ]]; then
    check_composite_action "$workflow" || { echo "Composite action policy violated: $workflow" >&2; exit 1; }
    continue
  fi

  if [[ "$workflow" == ".github/workflows/weekly-validation.yml" ]]; then
    check_weekly_resolver "$workflow"
    continue
  fi

  protected_source=0
  for protected_workflow in "${protected_source_workflows[@]}"; do
    if [[ "$workflow" == "$protected_workflow" || "$workflow" == "./$protected_workflow" ]]; then
      protected_source=1
      break
    fi
  done


  if (( protected_source )); then
    check_protected_source "$workflow"
  else
    check_dispatcher "$workflow"
  fi
done < <(find .github/workflows .github/actions -type f \( -name '*.yml' -o -name '*.yaml' \) -print0 2>/dev/null)

if find . -type f -not -path './.git' -not -path './.git/*' -not -path './.github/workflows/*' -not -path './.github/actions/*/action.yml' -not -path './.github/policy/*' -not -path './.github/ci-matrix.json' -not -path './.github/dependabot.yml' -not -path './.github/tool-pins.json' -not -path './.github/egress-allowlist.txt' -not \( -path './docs/*.md' -not -path './docs/*/*' \) -not -name '.gitignore' -print -quit | grep -q .; then
  echo "Only workflow files (and an optional .gitignore) may be tracked at this bootstrap phase." >&2
  exit 1
fi
