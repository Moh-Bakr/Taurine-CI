# Public policy runtime

PR #355's automatic run `39077036309`, candidate
`8ca61df297d4bdb1f27199e992e96b37e765e16a`, exhausted the policy job's
25-minute limit. Its base-policy jobs succeeded. The policy job ran from
23:20:27 to 23:45:39 UTC on 2026-10-17; GitHub reported that the maximum
execution time of 25 minutes had been exceeded. This was not a manual cancel.
The mutation step had consumed 1,131 seconds; later checks were skipped and
provide no evidence. The preceding checks consumed about 381 seconds.

The log measured `check-workflows.sh` at 16.59 seconds and `test-policy.sh`
at 49.94 seconds. The last three classifier mutations each took about 66
seconds because every mutation executes the policy afresh. A local invocation
profile found 63 Action-reference checker startups, 43 composite checker
startups and 54 expression parser startups in one workflow check.

The runtime repair shares interpreter startup, never a policy verdict:

- The workflow check passes the same NUL-delimited `find` inventory, with the
  same order and explicit arguments, to one Action-reference checker. Its
  existing per-file checks still run. An empty inventory fails.
- Composite text/cache guards still inspect every file. One Ruby process then
  runs the original structural checks independently for every argument,
  resetting document and failure state per file. A bad or unreadable file
  fails the batch, including after a valid file or the source-checkout special
  case. An empty argument list fails.
- A protected-main condition is parsed once for both required conjuncts, and
  a restore condition once for its two possible gate shapes. All membership
  tests use the same complete parser output. Invalid syntax still fails before
  any conjunct can satisfy a guard. No result persists between calls or files.

No mutation, original falsifier, fixture, required job or containment guard is
removed. Mutation text-not-found failures and checker attribution remain in
place. The job keeps its 25-minute bound; the four old-base literal fixture
anchors stay intact. There is no new timeout, cache, source access, token,
runner, permission or artifact capability. All eight wave-1 trust paths remain
unchanged. The base pass still replaces the entire policy directory with the
base commit's scripts, so it receives no optimization or altered visibility.

`test-policy-batching.sh` checks duplicates, ordering, literal spaces/glob
characters in filenames, a failure first/middle/last, malformed and missing
files, empty arguments, the special-case file followed by another file, and
missing/invalid/OR-weakened conjuncts with positive controls. The full mutation
corpus and independent review remain required; local timings do not establish
that the hosted job fits its bound or admit the change.
