#!/usr/bin/env bash
# Fixtures for the docs-only classifier (classify-docs-change.rb): real git repositories with a base
# commit, a pull request branch and the merge commit the workflow checks out, and one verdict per case.
# Only a pull request whose every changed path is a plain documentation file, outside the exclusion
# list, as an ordinary added, modified or deleted regular file, is `true`; every doubt is `false`.
# Run from the repository root.
set -euo pipefail

root="${PWD}"
classifier="${root}/.github/policy/classify-docs-change.rb"
[[ -f "${classifier}" ]] || { echo "docs classifier: ${classifier} is missing" >&2; exit 1; }
tmp="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/docs-classifier-test.XXXXXX")"
trap 'rm -rf -- "${tmp}"' EXIT
fail() { echo "docs classifier: $*" >&2; exit 1; }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
G=(git -c user.name=t -c user.email=t@localhost -c commit.gpgsign=false -c init.defaultBranch=main -c protocol.file.allow=always)

# new_repo [with-plans]: ${tmp}/r holding a base commit on main.
new_repo() {
  rm -rf "${tmp}/r"; mkdir -p "${tmp}/r"
  ( cd "${tmp}/r"
    "${G[@]}" init -q .
    mkdir -p docs .github/policy src
    echo a > docs/a.md; echo b > docs/untrusted-readonly-cache.md; echo c > docs/how-ci-works.md
    echo p > .github/policy/x.sh; echo s > src/code.rs; echo n > NOTES.md
    [[ "${1:-}" != with-plans ]] || { mkdir -p plans; echo p > plans/p.md; }
    "${G[@]}" add -A; "${G[@]}" commit -q -m base )
}
# open_pr: branch `pr` from main; the caller edits and `pr_commit`s, then `merge` builds the merge commit.
open_pr() { ( cd "${tmp}/r" && "${G[@]}" checkout -q -b pr ); }
pr_commit() { ( cd "${tmp}/r" && "${G[@]}" add -A && "${G[@]}" commit -q --allow-empty -m change ); }
# merge: main gets a merge commit of pr (as github.sha is), and BASE/HEAD/MERGE are set.
merge() {
  ( cd "${tmp}/r"
    "${G[@]}" checkout -q main
    "${G[@]}" checkout -q -b merged main
    "${G[@]}" merge -q --no-ff -m merge pr )
  BASE="$(git -C "${tmp}/r" rev-parse main)"
  HEAD_="$(git -C "${tmp}/r" rev-parse pr)"
  MERGE="$(git -C "${tmp}/r" rev-parse merged)"
}
# verdict [EVENT]: run the classifier the way the workflow does and print the docs_only value.
verdict() {
  : > "${tmp}/output"
  env -i PATH="${PATH}" HOME="${tmp}" GITHUB_OUTPUT="${tmp}/output" EVENT_NAME="${1-pull_request}" \
    BASE_SHA="${BASE}" HEAD_SHA="${HEAD_}" MERGE_SHA="${MERGE}" \
    ruby --disable-gems "${classifier}" --repo "${tmp}/r" 2> "${tmp}/err" || fail "the classifier exited non-zero: $(cat "${tmp}/err")"
  [[ "$(wc -l < "${tmp}/output" | tr -d ' ')" == 1 ]] || fail "expected exactly one output line, got: $(cat "${tmp}/output")"
  sed -n 's/^docs_only=//p' "${tmp}/output"
}
expect() { # LABEL true|false [EVENT]
  local got; got="$(verdict "${3-pull_request}")"
  [[ "${got}" == "$2" ]] || fail "$1: expected docs_only=$2, got '${got}' ($(cat "${tmp}/err"))"
  echo "docs_only=$2  $1"
}
edit() { ( cd "${tmp}/r" && eval "$1" ); }

new_repo; open_pr; edit 'echo more >> docs/a.md'; pr_commit; merge
expect 'one document edited' true

new_repo; open_pr; edit 'echo n >> NOTES.md; mkdir -p docs/guides/deep && echo g > docs/guides/deep/g-1.md; rm docs/how-ci-works.md'; pr_commit; merge
expect 'top-level, nested, added and deleted documents' true

new_repo; open_pr; edit 'echo more >> docs/a.md; echo x >> .github/policy/x.sh'; pr_commit; merge
expect 'a document plus one .github file' false

new_repo; open_pr; edit 'echo more >> docs/untrusted-readonly-cache.md'; pr_commit; merge
expect 'the document the policy reads' false
new_repo; open_pr; edit 'echo more >> docs/a.md; rm docs/untrusted-readonly-cache.md'; pr_commit; merge
expect 'the excluded document deleted beside another' false
# Built with git plumbing, not a working tree: on a case-insensitive file system the second name is the first file.
new_repo
( cd "${tmp}/r"
  blob="$(echo q | git hash-object -w --stdin)"
  export GIT_INDEX_FILE="${tmp}/case-index"
  git read-tree main; git update-index --add --cacheinfo "100644,${blob},docs/Untrusted-Readonly-Cache.md"
  tree="$(git write-tree)"; main_sha="$(git rev-parse main)"
  pr_sha="$("${G[@]}" commit-tree "${tree}" -p "${main_sha}" -m pr)"
  merge_sha="$("${G[@]}" commit-tree "${tree}" -p "${main_sha}" -p "${pr_sha}" -m merge)"
  printf '%s %s %s\n' "${main_sha}" "${pr_sha}" "${merge_sha}" > "${tmp}/case-shas" )
read -r BASE HEAD_ MERGE < "${tmp}/case-shas"
expect 'the excluded document under another case' false

new_repo; open_pr; edit 'echo more >> src/code.rs'; pr_commit; merge
expect 'a source file' false
new_repo; open_pr; edit 'echo more >> .github/policy/x.sh'; pr_commit; merge
expect 'a policy script alone' false
new_repo; open_pr; edit 'mkdir -p .github/workflows && echo y > .github/workflows/w.yml'; pr_commit; merge
expect 'a workflow alone' false
new_repo; open_pr; edit 'echo m > .github/README.md'; pr_commit; merge
expect 'a markdown file under .github' false
new_repo; open_pr; edit 'echo m > src/notes.md'; pr_commit; merge
expect 'a markdown file under another directory' false
new_repo; open_pr; edit 'echo m > docs/a.txt'; pr_commit; merge
expect 'a non-markdown file under docs' false
new_repo; open_pr; edit 'echo m > docs/UP.MD'; pr_commit; merge
expect 'an upper-case extension' false
new_repo; open_pr; edit 'echo m > "docs/a b.md"'; pr_commit; merge
expect 'a path with a space' false
new_repo; open_pr; edit 'echo m > docs/.hidden.md'; pr_commit; merge
expect 'a hidden document' false
new_repo; open_pr; edit 'echo m > "docs/line
feed.md"'; pr_commit; merge
expect 'a path with a newline' false
new_repo; open_pr; edit 'echo m > docs/é.md'; pr_commit; merge
expect 'a path with a non-ASCII letter' false

new_repo; open_pr; edit 'rm src/code.rs'; pr_commit; merge
expect 'a code file deleted' false

new_repo; open_pr; edit 'git mv docs/a.md src/a.md'; pr_commit; merge
expect 'a rename out of docs into a code path' false
new_repo; open_pr; edit 'git mv src/code.rs docs/code.md'; pr_commit; merge
expect 'a rename out of a code path into docs' false
new_repo; open_pr; edit 'git mv docs/a.md docs/renamed.md'; pr_commit; merge
expect 'a rename inside docs' true

new_repo; open_pr; edit 'ln -s ../src/code.rs docs/link.md'; pr_commit; merge
expect 'an added symlink named like a document' false
new_repo; open_pr; edit 'rm docs/a.md && ln -s ../src/code.rs docs/a.md'; pr_commit; merge
expect 'a document replaced by a symlink' false
new_repo; open_pr; edit 'git update-index --add --cacheinfo 160000,1234567890abcdef1234567890abcdef12345678,docs/sub.md'; pr_commit; merge
expect 'a submodule entry named like a document' false
new_repo; open_pr; edit 'chmod +x docs/a.md'; pr_commit; merge
expect 'a mode change' false
new_repo; open_pr; edit 'echo e > docs/exec.md; chmod +x docs/exec.md'; pr_commit; merge
expect 'an added executable document' false
new_repo; open_pr; edit "printf 'a\\000b\\n' > docs/bin.md"; pr_commit; merge
expect 'a binary document' false

new_repo; open_pr; pr_commit; merge
expect 'an empty change' false
new_repo; open_pr; edit 'echo more >> docs/a.md'; pr_commit; merge
expect 'a push event' false push
expect 'a dispatch event' false workflow_dispatch
expect 'no event' false ''

# The merge commit must be BASE's merge with HEAD.
new_repo; open_pr; edit 'echo more >> docs/a.md'; pr_commit; merge
saved_merge="${MERGE}"; MERGE="${HEAD_}"
expect 'the head given as the merge commit (one parent)' false
MERGE="${saved_merge}"; HEAD_="${BASE}"
expect 'a head that is not the merge second parent' false
HEAD_="$(git -C "${tmp}/r" rev-parse pr)"; BASE="$(git -C "${tmp}/r" rev-parse pr)"
expect 'a base equal to the head (nothing changed)' false
BASE="0123456789abcdef0123456789abcdef01234567"
expect 'an unknown base commit' false
BASE="abc"
expect 'an abbreviated base commit' false
BASE=""
expect 'an empty base commit' false
BASE="$(git -C "${tmp}/r" rev-parse main)"; MERGE="not-a-sha"
expect 'a malformed merge commit' false
MERGE="${saved_merge}"
expect 'the original verdict restored' true

# The base moved on with code after the pull request was opened: the diff from the event's base shows it.
new_repo; open_pr; edit 'echo more >> docs/a.md'; pr_commit
( cd "${tmp}/r" && "${G[@]}" checkout -q main && echo late >> src/code.rs && "${G[@]}" commit -q -am late )
merge
BASE="$(git -C "${tmp}/r" rev-parse main~1)"
expect 'a base that moved on with code' false
BASE="$(git -C "${tmp}/r" rev-parse main)"
expect 'the same pull request against the moved base' true

# plans/ counts only while the base has it.
new_repo; open_pr; edit 'mkdir -p plans && echo p > plans/new.md'; pr_commit; merge
expect 'plans/ when the base has none' false
new_repo with-plans; open_pr; edit 'mkdir -p plans/sub && echo p > plans/sub/new.md; echo q >> plans/p.md'; pr_commit; merge
expect 'plans/ when the base has it' true

# A failing git, a missing checkout and a hostile attribute never produce a true.
new_repo; open_pr; edit 'echo more >> docs/a.md'; pr_commit; merge
mv "${tmp}/r" "${tmp}/gone"
expect 'a checkout that is not there' false
mv "${tmp}/gone" "${tmp}/r"
printf '%s\n' '*.md diff=evil' > "${tmp}/attrs"
( cd "${tmp}/r" && git config diff.evil.textconv 'sh -c "echo hostile > '"${tmp}"'/ran; cat" --' && git config diff.external "sh -c 'echo hostile > ${tmp}/ran'" )
cp "${tmp}/attrs" "${tmp}/r/.git/info/attributes"
expect 'a repository configured with a textconv and an external diff' true
[[ ! -e "${tmp}/ran" ]] || fail 'a textconv or an external diff command was run'
echo 'docs_only=true  no configured diff command is run'

# Output goes to stdout when GITHUB_OUTPUT is unset, and a bad invocation is refused.
out="$(env -i PATH="${PATH}" EVENT_NAME=push ruby --disable-gems "${classifier}" --repo "${tmp}/r" 2>/dev/null)"
[[ "${out}" == 'docs_only=false' ]] || fail "stdout mode printed '${out}'"
if ruby --disable-gems "${classifier}" > /dev/null 2>&1; then fail 'a run without --repo was accepted'; fi
if ruby --disable-gems "${classifier}" --repo "${tmp}/r" extra > /dev/null 2>&1; then fail 'a stray argument was accepted'; fi

echo 'docs classifier: only plain documentation changes are true, and every doubt is false'
