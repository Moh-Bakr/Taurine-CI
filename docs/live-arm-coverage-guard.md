# Live-arm coverage drift guard

`.github/policy/check-live-arm-coverage.rb` fails the public policy check when the roster block
declared in `live-proofs.yml`, or the live-proofs dispatch-contract options in `ci-matrix.json`,
stop matching one explicit required set, or when a roster entry carries a key outside a reviewed
list. It is defence in depth for a boundary that other checks already pin; it is not the only guard.

## What is required

The live roster has **12 arms**: `doris`, `starrocks`, `db2`, `informix`, `rocketmq`, `iris`,
`postgres`, `mysql`, `mssql`, `pgtls`, `tls-legacy` and `bastion`. All 12 are required.
`all` expands to the whole roster and full admission requires every arm, including `tls-legacy`.
There is no baseline subset, no waivable arm and no applicability profile.

The Dbx-route live proof, formerly the `pg-dbx` arm, is the last suite of the `postgres` arm (same
pinned PostgreSQL 17 image and same conformance crate, so one runner and one cold build serve both).
It keeps its own evidence row, `taurine-db-conformance [dbx_pg_live,dbx_shadow_pg]`, with the same
name and the same pass/FAIL rules, and any failing or skipped suite fails the arm. The guard pins
that row (see below). `engine=pg-dbx` is no longer accepted: the dispatch contract does not list it
and the planning step refuses it with a pointer to `postgres`.

## What the guard checks

It reads two files of this repository as text and JSON, never private source:

1. The JSON roster block that the plan job in `.github/workflows/live-proofs.yml` declares equals the
   required set: nothing missing, nothing extra, no duplicate arm.
2. The `engine` options of the `live-proofs.yml` dispatch contract in `.github/ci-matrix.json` equal
   the required set.
3. The `postgres` entry carries the suite row `taurine-db-conformance dbx_pg_live,dbx_shadow_pg`
   exactly once. Removing the row, dropping either test target, narrowing it with a test-name
   filter or repeating it gives `missing_evidence_row`.
4. Each roster entry carries only the reviewed keys (`engine`, `target`, `filter`, `report`, `blurb`,
   `suites`, `cargo_features`). A key such as `required`, `optional`, `skip`, `if` or `enabled` is
   refused until this check is reviewed to allow it.

The result is one JSON line: a status, the three counts, the public arm IDs that are `missing` or
`unrequired` (filled only when two arm lists were compared), and a fixed-vocabulary `reason` that
names the file and the cause, for example `live-proofs.yml: no roster marker`, `ci-matrix.json:
symlink`, or `live-proofs.yml: key 'optional' in arm 'mysql'`. It exits 0 only for `ok`; every other
status exits 1: `roster_mismatch`, `contract_mismatch`, `duplicate_arm`, `unknown_roster_key`,
`missing_evidence_row`, `invalid_input` and `unsafe_input`. An input failure carries empty `missing`
and `unrequired` lists, so a reformatted or unreadable file is never reported as twelve missing arms.

Inputs are read fail-closed: a file must be a regular file, not a symlink, within a size limit and
valid UTF-8; JSON is bounded in nesting and rejects duplicate keys; the repository root may not be a
symlink; the roster block must occur exactly once.

## What the guard does not see

It parses the workflow as text. It does not run or interpret it, so it cannot tell how the declared
roster is used afterwards. These all leave the guard reporting `ok`:

- a second, decoy copy of the roster block in a disabled job, with the real step written differently;
- a filter applied to the roster after it is written (for example a `jq` expression dropping an arm);
- an `exclude:` or `include:` on the `prove` job's matrix, or a job-level condition, that stops an
  arm from running.

`test-live-roster.sh` runs the real plan step and catches the first two. **Nothing currently pins the
`prove` job's matrix shape, so a matrix `exclude:` is an open gap on `main`, not covered by this
guard.** A follow-up change should pin that shape (only the arm list from the plan output, no
`include`/`exclude`, no job condition beyond the protected-ref check). The guard also cannot see the
admission requirement itself, which lives in the coordinator's dispatch and verification rules: here
`all` is the roster, so the guard asserts the roster, not the coordinator's behaviour.

## Relationship to the existing checks

`test-live-roster.sh` already runs the real plan step and pins the 13 roster keys and the `all`
expansion against the contract, `check-dispatch-contracts.rb` already pins the contract options to the
12 arms, and the protected call input check in `live-proof-arm.yml` already enforces a key allowlist at
run time. Most of this guard is therefore redundant by design. What it adds is:

- a static, policy-time allowlist of roster entry keys, with an explicit duplicate-arm status;
- a single explicit required set (`REQUIRED_ARMS`) that is asserted against both files, and whose base
  commit copy runs against every pull request, because the base policy runs every `check-*.rb`.

It does not touch admission, dispatch identity, result aggregation, the concern table or any platform
workflow, and it adds no new required result.

## Changing the roster

Adding or removing an arm is a reviewed policy change. The required set is the `REQUIRED_ARMS`
constant in the guard, and the base commit's copy of the guard runs against every pull request, so a
change that edits the roster and the guard together is rejected by the base guard and lands in two
steps, like the existing contract check (see "Changing the policy" in `how-ci-works.md`).

- **Adding an arm is staged as a superset only.** The first change registers the new arm and requires
  it everywhere at once (roster, contract, guard constant); each intermediate state accepts the current
  set or the current set plus the named new arm, never a subset of it. Do not write "accept either
  set" logic that tolerates a smaller roster.
- **Removing or renaming an arm is a coverage reduction** and needs its own owner decision first.
  The `pg-dbx` arm was merged into `postgres` as a timing change (the proof and its evidence row
  are unchanged and pinned by the guard), not as a coverage reduction.

## Considered and rejected: a `pg-dbx` exclusion profile

An earlier prototype of this work proposed a separate applicability profile that required only the
other baseline arms and treated `pg-dbx` as not applicable to a source that lacked Stage 2 proof. The
owner rejected it permanently: a profile that admits a source with no `pg-dbx` proof is a coverage
hole, and there is no present case for it. `all` stays the full registered roster, which includes
the Dbx-route proof (now the pinned `dbx_pg_live,dbx_shadow_pg` row of the `postgres` arm). Do not reintroduce a profile, flag or source-supplied mapping that waives an arm. The
prototype's source-marker diagnostic was removed with it; it remains in git history.

Registered proof readiness is not an execution PASS, and a missing Dbx-route (`dbx_pg_live,dbx_shadow_pg`) Stage 2 result stays a
failed full run.
