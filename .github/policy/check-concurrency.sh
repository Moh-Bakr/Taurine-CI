#!/usr/bin/env bash
# Concurrency rule for source-bearing workflows.
#
# GitHub keeps only ONE pending run per concurrency group: a newer run in the same group
# replaces the older pending one, even with cancel-in-progress: false. A shared per-SHA group
# therefore let one lane's dispatch silently cancel another lane's queued validation. The rule:
# a workflow either has no top-level concurrency block, or its group contains github.run_id
# (so it is unique per run), and cancel-in-progress is false or absent.
# Usage: check-concurrency.sh [workflow files...]; with none, every protected workflow.
set -euo pipefail
policy="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$#" -gt 0 ]]; then
  files=("$@")
else
  # shellcheck source=workflow-lists.sh
  source "${policy}/workflow-lists.sh"
  files=("${protected_source_workflows[@]}" "${protected_dispatch_workflows[@]}" .github/workflows/weekly-validation.yml)
fi
status=0
for file in "${files[@]}"; do
  [[ -f "${file}" ]] || continue
  block="$(awk '/^concurrency:/ {on=1; next} on && /^[^[:space:]#]/ {on=0} on {print}' "${file}")"
  [[ -n "${block}" ]] || continue
  if ! grep -E '^[[:space:]]+group:' <<<"${block}" | grep -q 'github\.run_id'; then
    echo "The concurrency group of a source-bearing workflow must contain github.run_id (a shared group lets a later dispatch cancel a pending run): ${file}" >&2
    status=1
  fi
  if grep -qE '^[[:space:]]+cancel-in-progress:[[:space:]]*([Tt]rue|\$\{\{)' <<<"${block}"; then
    echo "cancel-in-progress must be false or absent in a source-bearing workflow: ${file}" >&2
    status=1
  fi
done
(( status == 0 )) && echo "concurrency: every source-bearing workflow has a per-run group or none"
exit "${status}"
