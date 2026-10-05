#!/usr/bin/env bash
# File size limits for workflows and composite actions: more than 800 lines fails, more than
# 400 lines warns. Split by responsibility (composite actions, per-family workflows, policy
# scripts), never by line count alone. Run from the repository root, or pass a root directory.
set -euo pipefail

root="${1:-.}"
soft=400
hard=800

# Files still over the hard limit while their owners split them. Each entry is a ceiling: the
# file may not grow, and the entry is deleted when the split lands.
pending_ceiling() {
  case "$1" in
    .github/workflows/keeldock-validation-concern.yml) echo 800 ;;
    *) echo 0 ;;
  esac
}

failed=0
warned=0
while IFS= read -r -d '' file; do
  rel="${file#"${root}"/}"
  lines="$(wc -l <"${file}" | tr -d ' ')"
  if (( lines > hard )); then
    ceiling="$(pending_ceiling "${rel}")"
    if (( ceiling > 0 && lines <= ceiling )); then
      echo "::warning title=pending split::${rel} has ${lines} lines (over ${hard}); its owner is splitting it, ceiling ${ceiling}"
    else
      echo "${rel} has ${lines} lines: the limit is ${hard}. Split it by responsibility." >&2
      failed=1
    fi
  elif (( lines > soft )); then
    echo "::warning title=large workflow file::${rel} has ${lines} lines (target ${soft}); consider splitting it by responsibility"
    warned=$((warned + 1))
  fi
done < <(find "${root}/.github/workflows" "${root}/.github/actions" -type f \( -name '*.yml' -o -name 'action.yml' \) -print0 2>/dev/null | sort -z)

(( failed == 0 )) || exit 1
echo "file sizes: no file over ${hard} lines (${warned} over ${soft})"
