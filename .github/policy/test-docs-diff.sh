#!/usr/bin/env bash
# Fixtures for docs-whitespace-diff.sh: a clean documentation change passes, and a whitespace error, a conflict
# marker and every checkout that is not a pull request merge commit fail. Run from the repository root.
set -euo pipefail

root="${PWD}"
script="${root}/.github/policy/docs-whitespace-diff.sh"
tmp="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/docs-diff-test.XXXXXX")"
trap 'rm -rf -- "${tmp}"' EXIT
fail() { echo "docs diff: $*" >&2; exit 1; }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
G=(git -c user.name=t -c user.email=t@localhost -c commit.gpgsign=false -c init.defaultBranch=main)

# merge_with CONTENT: a repository whose merge commit adds docs/new.md holding CONTENT (printf format).
merge_with() {
  rm -rf "${tmp}/r"; mkdir -p "${tmp}/r"
  ( cd "${tmp}/r"
    "${G[@]}" init -q .; mkdir docs; echo a > docs/a.md; "${G[@]}" add -A; "${G[@]}" commit -q -m base
    "${G[@]}" checkout -q -b pr; printf "$1" > docs/new.md; "${G[@]}" add -A; "${G[@]}" commit -q -m change
    "${G[@]}" checkout -q main; "${G[@]}" checkout -q -b merged; "${G[@]}" merge -q --no-ff -m merge pr )
}
run() { ( cd "${tmp}/r" && bash "${script}" ) > "${tmp}/out" 2>&1; }
expect_pass() { run || { cat "${tmp}/out" >&2; fail "refused, expected accepted: $1"; }; echo "accepted  $1"; }
expect_fail() { if run; then fail "NOT refused: $1"; fi; grep -qF -- "$2" "${tmp}/out" || { cat "${tmp}/out" >&2; fail "refused for another reason: $1 (wanted: $2)"; }; echo "refused   $1"; }

merge_with 'a clean line\n'
expect_pass 'a clean documentation change'
merge_with 'trailing space \n'
expect_fail 'a trailing space' 'whitespace error'
merge_with 'text\n<<<<<<< ours\nmine\n=======\ntheirs\n>>>>>>> theirs\n'
expect_fail 'a conflict marker' 'whitespace error'
merge_with 'a clean line\n'
( cd "${tmp}/r" && "${G[@]}" checkout -q pr )
expect_fail 'a checkout of the pull request head (no merge)' 'not a merge commit'
( cd "${tmp}/r" && "${G[@]}" checkout -q --orphan lone && "${G[@]}" commit -q --allow-empty -m lone )
expect_fail 'a root commit' 'no first parent'
rm -rf "${tmp}/r"; mkdir "${tmp}/r"
expect_fail 'a directory that is not a repository' 'no commit to check'
echo 'docs diff: a clean pull request merge commit passes, and nothing else does'
