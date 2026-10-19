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
source "${policy}/check-protected.sh"
source "${policy}/check-dispatchers.sh"

# Never cancel or replace a source-bearing run: cancellation can interrupt the step that revokes
# the short-lived source token, and GitHub replaces a pending run in a shared group. Each run
# needs its own group (github.run_id) or none, and cancel-in-progress false (check-concurrency.sh).
bash "${policy}/check-concurrency.sh" >/dev/null || { bash "${policy}/check-concurrency.sh" >&2 || true; exit 1; }

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


# One invocation checks every file; do not pay Ruby startup once per reference file.
# Keep the exact find inventory, including hidden files and .yaml, and refuse an empty set.
workflow_files=()
while IFS= read -r -d '' workflow; do workflow_files+=("${workflow}"); done < <(find .github/workflows .github/actions -type f \( -name '*.yml' -o -name '*.yaml' \) -print0 2>/dev/null)
(( ${#workflow_files[@]} > 0 )) || { echo 'No workflow or composite file to check.' >&2; exit 1; }
check_action_references "${workflow_files[@]}"
composite_files=()
for workflow in "${workflow_files[@]}"; do
  if [[ "$workflow" == .github/actions/*/action.yml ]]; then
    composite_files+=("${workflow}")
    continue
  fi

  if [[ "$workflow" == ".github/workflows/weekly-validation.yml" ]]; then
    check_weekly_resolver "$workflow"
    continue
  fi

  if [[ "$(classify_workflow "$workflow")" == source ]]; then
    check_protected_source "$workflow"
  else
    check_dispatcher "$workflow"
  fi
done
if (( ${#composite_files[@]} > 0 )); then
  check_composite_action "${composite_files[@]}" || { echo 'Composite action policy violated.' >&2; exit 1; }
fi

# cache-mode (always-on rules, plus the staged ones for ENFORCED_WORKFLOWS in check-cache-mode.rb)
# and the actions: write allow-list (docs/untrusted-readonly-cache.md, P2 and P7).
cache_mode_files=()
while IFS= read -r -d '' file; do cache_mode_files+=("${file}"); done < <(find .github/workflows -type f -name '*.yml' -print0 | sort -z)
ruby "${policy}/check-cache-mode.rb" "${cache_mode_files[@]}"

ruby "${policy}/check-dispatch-contracts.rb"
ruby "${policy}/check-suite-catalog.rb"

if find . -type f -not -path './.git' -not -path './.git/*' -not -path './.github/workflows/*' -not -path './.github/actions/*/action.yml' -not -path './.github/policy/*' -not -path './.github/ci-matrix.json' -not -path './.github/dependabot.yml' -not -path './.github/tool-pins.json' -not -path './.github/egress-allowlist.txt' -not -path './.github/CODEOWNERS' -not \( -path './docs/*.md' -not -path './docs/*/*' \) -not -name '.gitignore' -print -quit | grep -q .; then
  echo "Only workflow files (and an optional .gitignore) may be tracked at this bootstrap phase." >&2
  exit 1
fi
