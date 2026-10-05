#!/usr/bin/env bash
# Check the tool pin list and Dependabot coverage
#
# Pinned tools and update coverage. Every tool installed from a release is listed with
# its pin in .github/tool-pins.json (the weekly run warns when one is behind); the
# pin must be present in the file that installs it, so the list cannot drift. Dependabot
# must cover both the workflows and every composite action directory.
# Run from the repository root (the policy workflow does).
set -euo pipefail
jq -e '.tools | length > 0' .github/tool-pins.json >/dev/null
while IFS='|' read -r name current file; do
  if [[ ! -f "${file}" ]] || ! grep -qF -- "${current}" "${file}"; then
    echo "tool-pins.json pins ${name} ${current}, which ${file} does not contain" >&2
    exit 1
  fi
done < <(jq -r '.tools[] | [.name, .current, .file] | join("|")' .github/tool-pins.json)
grep -qE '^[[:space:]]*- /$' .github/dependabot.yml || { echo 'dependabot.yml does not cover the workflows directory' >&2; exit 1; }
grep -qF -- '/.github/actions/*' .github/dependabot.yml || { echo 'dependabot.yml does not cover the composite actions' >&2; exit 1; }
for dir in .github/actions/*/; do
  [[ -f "${dir}action.yml" ]] || { echo "${dir} has no action.yml" >&2; exit 1; }
done
echo "tool pins and Dependabot coverage: ok"
