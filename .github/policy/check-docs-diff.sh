#!/usr/bin/env bash
# The docs-only fast path's whitespace check: `git diff --check` over what the pull request adds.
#
# The checkout is the pull request's merge commit with one commit of history, so HEAD^1 is the base
# the pull request merges into and HEAD^2 its head; the diff between HEAD^1 and HEAD is exactly the
# change under review. Anything else (a checkout that is not such a merge commit, a failing git) is
# a failure and not a pass: the fast path never decides on a diff it could not read. Run from the
# repository root (the policy-docs job does).
set -euo pipefail

fail() { echo "::error::docs diff: $*" >&2; exit 1; }

git rev-parse --verify --quiet 'HEAD^{commit}' > /dev/null || fail 'there is no commit to check'
git rev-parse --verify --quiet 'HEAD^1^{commit}' > /dev/null || fail 'HEAD has no first parent: the base the change merges into is not in the checkout'
git rev-parse --verify --quiet 'HEAD^2^{commit}' > /dev/null || fail 'HEAD is not a merge commit of a pull request head'
if git rev-parse --verify --quiet 'HEAD^3^{commit}' > /dev/null; then fail 'HEAD has more than two parents'; fi

if ! git diff --check 'HEAD^1' HEAD; then
  fail 'git diff --check found a whitespace error or a conflict marker in the change'
fi
echo 'docs diff: the change has no whitespace error or conflict marker'
