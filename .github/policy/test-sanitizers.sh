#!/usr/bin/env bash
# Test the sanitizer expressions against path and token fixtures
#
# The sanitizers that scrub private paths from published failure detail are
# inline sed programs in the protected workflows. This step extracts every one
# of them and runs it over fixtures: a path containing a space (the old
# `[^ ]+` rules published everything after the space), a Windows drive path, a
# macOS /private/var path and GitHub token shapes. A program may only claim a
# root it names; every root it names must be scrubbed completely.
# Run from the repository root (the policy workflow does).
set -euo pipefail
fixtures="${RUNNER_TEMP}/sanitizer-fixtures"
mkdir -p "${fixtures}"
printf '%s\n' 'error: failed to read /Users/alice/Secret SPACEDIR/src/lib.rs:1:2 boom' > "${fixtures}/users.txt"
printf '%s\n' 'at /home/runner/work/x/x/My SPACEDIR/y.rs:3 in module' > "${fixtures}/home.txt"
printf '%s\n' 'C:\Users\Jo Bloggs\SPACEDIR\x.rs:3' > "${fixtures}/windows.txt"
printf '%s\n' '/private/var/folders/ab/SPACEDIR dir/T/x trailing' > "${fixtures}/private.txt"
printf '%s\n' 'ghp_abcdefghijklmnopqrstuvwxyz0123456789 ghs_Xyz123abc github_pat_11ABC_def456 Authorization: Bearer abc.DEF-123' > "${fixtures}/tokens.txt"
forbidden='SPACEDIR|alice|Jo Bloggs|Secret|ghp_abc|ghs_Xyz|github_pat_11|abc\.DEF'
sanitizer_files=()
while IFS= read -r -d '' file; do
  sanitizer_files+=("${file}")
done < <(find .github/workflows .github/actions -name '*.yml' -print0)
backslash=$'\\'
count=0
while IFS= read -r expr; do
  [[ -n "${expr}" ]] || continue
  count=$((count + 1))
  checks=()
  [[ "${expr}" == */Users/* ]] && checks+=(users)
  [[ "${expr}" == */home/runner/work/* ]] && checks+=(home)
  [[ "${expr}" == *"${backslash}"* ]] && checks+=(windows)
  [[ "${expr}" == *'s#/private/['* || "${expr}" == *'s#/private/.'* ]] && checks+=(private)
  [[ "${expr}" == *redacted* ]] && checks+=(tokens)
  for name in "${checks[@]}"; do
    if sed -E "${expr}" "${fixtures}/${name}.txt" | grep -qE "${forbidden}"; then
      echo "A sanitizer expression leaks the ${name} fixture: ${expr}" >&2
      exit 1
    fi
  done
done < <(grep -hoE "sed -E 's#[^']*'" "${sanitizer_files[@]}" | cut -c9- | sed 's/.$//' | grep -E 'private-path|private/workspace' | sort -u)
[[ "${count}" -gt 0 ]] || { echo 'No sanitizer expressions were found to test' >&2; exit 1; }
echo "sanitizer fixtures: ${count} expressions checked"
