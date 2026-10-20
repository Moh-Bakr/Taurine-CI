#!/usr/bin/env bash
# Fixtures for check-docs-reads.rb: the checker accepts this tree, accepts a read of an excluded document,
# a comment and a pinned message, and refuses every other way of naming a document or the docs directory
# outside the exclusion list, and every malformed list. Run from the repository root.
set -euo pipefail

root="${PWD}"
policy="${root}/.github/policy"
tmp="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/docs-reads-test.XXXXXX")"
trap 'rm -rf -- "${tmp}"' EXIT
fail() { echo "docs reads: $*" >&2; exit 1; }

# A synthetic tree: three documents, the spike record excluded by the real list, one script.
# fresh [LIST-EDIT-RUBY]: ${tmp}/t/{docs,.github} and a private copy of the checker and (edited) list in ${tmp}/p.
fresh() {
  rm -rf "${tmp}/t" "${tmp}/p"; mkdir -p "${tmp}/t/docs" "${tmp}/t/.github/policy" "${tmp}/t/.github/workflows" "${tmp}/p"
  echo a > "${tmp}/t/docs/other.md"; echo b > "${tmp}/t/docs/untrusted-readonly-cache.md"; echo c > "${tmp}/t/docs/guide.md"
  printf '#!/usr/bin/env bash\necho hello\n' > "${tmp}/t/.github/policy/check-x.sh"
  cp "${policy}/check-docs-reads.rb" "${tmp}/p/"
  if [[ -n "${1:-}" ]]; then
    EXPR="$1" ruby -e 's = File.read(ARGV[0]); eval(ENV["EXPR"]); File.write(ARGV[1], s)' "${policy}/docs-fast-path-exclusions.rb" "${tmp}/p/docs-fast-path-exclusions.rb"
  else
    cp "${policy}/docs-fast-path-exclusions.rb" "${tmp}/p/"
  fi
}
# add_line FILE TEXT: append a line to a file of the synthetic tree.
add_line() { mkdir -p "$(dirname "${tmp}/t/$1")"; printf '%s\n' "$2" >> "${tmp}/t/$1"; }
run() { ruby "${tmp}/p/check-docs-reads.rb" "${tmp}/t" > "${tmp}/out" 2>&1; }
expect_accept() { run || { cat "${tmp}/out" >&2; fail "refused, expected accepted: $1"; }; echo "accepted  $1"; }
expect_reject() { if run; then fail "NOT refused: $1"; fi; grep -qF -- "$2" "${tmp}/out" || { cat "${tmp}/out" >&2; fail "refused for another reason: $1 (wanted: $2)"; }; echo "refused   $1"; }

# The real tree, with the real list.
ruby "${policy}/check-docs-reads.rb" "${root}" > "${tmp}/out" 2>&1 || { cat "${tmp}/out" >&2; fail 'this tree has a document reference its own list does not account for'; }
echo 'accepted  this tree'

fresh; expect_accept 'a synthetic tree with no reference'
fresh; add_line .github/policy/check-x.sh 'cat docs/untrusted-readonly-cache.md'
expect_accept 'a read of the excluded document by path'
fresh; add_line .github/policy/check-x.sh 'cp docs/untrusted-readonly-cache.md "${d}/docs/"'
expect_reject 'a read of the excluded document that also names the directory' 'the docs directory'
fresh; add_line .github/policy/check-x.sh 'cat "${root}/untrusted-readonly-cache.md" > /dev/null'
expect_accept 'a read of the excluded document by name'
fresh; add_line .github/policy/check-x.sh '# docs/other.md is read here, in a comment'
expect_accept 'a comment that names a document'

# Each way to read a document that is not excluded.
reads=(
  'cat docs/other.md'
  'cat "${root}/docs/other.md"'
  'grep -q x docs/guide.md'
  "ruby -e 'File.read(\"docs/other.md\")'"
  "File.read(File.join(root, 'docs', 'other.md'))"
  "File.open('other.md')"
  "Dir.glob('docs/*.md').each { |f| puts f }"
  'for f in "${root}"/docs/*.md; do :; done'
  'cp -R "${root}/docs" "${tmp}/"'
  'sed -n 1p "docs/guide.md"'
  'bash -c "cat ./docs/other.md"'
  'cat docs/*.md'
  'ls docs/'
  'cat docs/not-yet-there.md'
)
for text in "${reads[@]}"; do
  fresh; add_line .github/policy/check-x.sh "${text}"
  expect_reject "a script line: ${text}" 'neither a read of an excluded document nor pinned'
done
fresh; add_line .github/workflows/w.yml '        run: cat docs/other.md'
expect_reject 'a workflow step that reads a document' 'names other.md'
fresh; add_line .github/actions/a/action.yml '        run: cat docs/guide.md'
expect_reject 'a composite action that reads a document' 'names guide.md'
fresh; add_line .github/policy/test-y.rb "puts File.read('docs/guide.md')"
expect_reject 'a Ruby test that reads a document' 'names guide.md'
fresh; add_line .github/policy/check-x.sh "echo 'see docs/guide.md'"
expect_reject 'a message that names a document (needs a pin)' 'names guide.md'
fresh; add_line .github/other.json '      "docs/**",'
expect_reject 'a glob over the docs directory' 'the docs directory'

# A pinned line is accepted, only that exact line; a stale pin is a warning.
fresh 's = s.sub("NAMED_NOT_READ = {\n", "NAMED_NOT_READ = {\n    \".github/policy/check-x.sh\" => [\"echo '"'"'see docs/guide.md'"'"'\"],\n")'
add_line .github/policy/check-x.sh "echo 'see docs/guide.md'"
expect_accept 'a pinned message line'
add_line .github/policy/check-x.sh "echo 'see docs/guide.md and more'"
expect_reject 'a line that only resembles a pinned one' 'names guide.md'
fresh 's = s.sub("NAMED_NOT_READ = {\n", "NAMED_NOT_READ = {\n    \".github/policy/check-x.sh\" => [\"echo '"'"'gone'"'"' docs/guide.md\"],\n")'
expect_accept 'a stale pin only warns'
grep -q 'a line that is gone' "${tmp}/out" || grep -q 'is gone from' "${tmp}/out" || fail 'a stale pin was not reported'
fresh 's = s.sub("NAMED_NOT_READ = {\n", "NAMED_NOT_READ = {\n    \".github/policy/other.sh\" => [\"echo docs/guide.md\"],\n")'
add_line .github/policy/check-x.sh 'echo docs/guide.md'
expect_reject 'a pin for another file does not cover this one' 'names guide.md'

# The list: a read document missing from it, and every malformed list.
fresh 's = s.sub("docs/untrusted-readonly-cache.md\n", "docs/other.md\n")'
add_line .github/policy/check-x.sh 'cat "${root}/untrusted-readonly-cache.md"'
expect_reject 'the read document removed from the list' 'names untrusted-readonly-cache.md'
fresh 's = s.sub("docs/untrusted-readonly-cache.md\n", "")'
expect_reject 'an empty list' 'EXCLUDED_DOCS is empty'
fresh 's = s.sub("docs/untrusted-readonly-cache.md\n", "docs/guide.md\ndocs/untrusted-readonly-cache.md\n")'
expect_accept 'a list with a second existing document'
fresh 's = s.sub("docs/untrusted-readonly-cache.md\n", "docs/missing.md\ndocs/untrusted-readonly-cache.md\n")'
expect_reject 'a list entry that is not in the tree' 'is not in the tree'
fresh 's = s.sub("docs/untrusted-readonly-cache.md\n", "docs/guide.md\ndocs/guide.md\ndocs/untrusted-readonly-cache.md\n")'
expect_reject 'a repeated list entry' 'sorted and have no repeat'
fresh 's = s.sub("docs/untrusted-readonly-cache.md\n", "docs/*.md\ndocs/untrusted-readonly-cache.md\n")'
expect_reject 'a wildcard list entry' 'not a plain documentation path'
fresh 's = s.sub("docs/untrusted-readonly-cache.md\n", "docs/Untrusted-Readonly-Cache.md\n")'
expect_reject 'an upper-case list entry' 'must be lower-case'

echo 'docs reads: every document the policy names is excluded or reviewed as not read, and every other reference is refused'
