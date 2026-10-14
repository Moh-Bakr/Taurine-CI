# Live-arm coverage drift guard

`.github/policy/check-live-arm-coverage.rb` fails the public policy check when the registered
live-proof arms and the required live-proof arms diverge. It exists to stop coverage shrinking
silently: an arm that is registered but not required, a required arm that is no longer registered, or
a roster entry that can mark an arm optional.

## What is required

The live roster has **13 arms**: `doris`, `starrocks`, `db2`, `informix`, `rocketmq`, `iris`,
`postgres`, `pg-dbx`, `mysql`, `mssql`, `pgtls`, `tls-legacy` and `bastion`. All 13 are required.
`all` expands to the whole roster and full admission requires every arm, including `pg-dbx`, the
Dbx-route live proof, and `tls-legacy`. There is no baseline subset, no waivable arm and no
applicability profile.

## What the guard checks

It reads only this repository's own files, never private source:

1. The roster JSON that the plan job in `.github/workflows/live-proofs.yml` writes (the arms that
   actually run) equals the required set: nothing missing, nothing extra, no duplicate arm.
2. The `engine` options of the `live-proofs.yml` dispatch contract in `.github/ci-matrix.json` (the
   arms a dispatch may name) equal the required set.
3. Each roster entry carries only the reviewed keys (`engine`, `target`, `filter`, `report`, `blurb`,
   `suites`, `cargo_features`). A key such as `required`, `optional`, `skip`, `if` or `enabled` is
   refused until this check is reviewed to allow it.

The report is a small JSON record with fixed fields only: status, counts, and the public arm IDs
that are missing or unrequired. It exits 0 only for `ok`. Every other status exits 1: `roster_mismatch`,
`contract_mismatch`, `duplicate_arm`, `unknown_roster_key`, `invalid_input` and `unsafe_input`.

Inputs are read fail-closed. A file must be a regular file, not a symlink, within a size limit and
valid UTF-8; JSON is bounded in nesting and rejects duplicate keys; the repository root may not be a
symlink; the roster block must occur exactly once.

## Relationship to the existing checks

`check-dispatch-contracts.rb` already pins the contract's `engine` options and `test-live-roster.sh`
already runs the plan step and compares its arms with the contract. This guard adds one independent,
pinned required set that is asserted against both, plus the duplicate-arm and waiver-key refusals.
It does not touch admission, dispatch identity, result aggregation, the concern table or any platform
workflow, and it adds no new required result.

## Changing the roster

Adding or removing an arm is a reviewed policy change. The required set is the `REQUIRED_ARMS`
constant in the guard, and the base commit's copy of the guard runs against every pull request, so a
change that edits the roster and the guard together is rejected by the base guard and lands in two
steps, exactly like the existing contract check (see "Changing the policy" in `how-ci-works.md`).
Shrinking the required set is a coverage reduction and needs its own owner decision.

## Considered and rejected: a `pg-dbx` exclusion profile

An earlier prototype of this work proposed a separate applicability profile that required only the
other baseline arms and treated `pg-dbx` as not applicable to a source that lacked Stage 2 proof. The
owner rejected it permanently: a profile that admits a source with no `pg-dbx` proof is a coverage
hole, and there is no present case for it. `all` stays the full registered roster with `pg-dbx`
required. Do not reintroduce a profile, flag or source-supplied mapping that waives an arm. The
prototype's source-marker diagnostic was removed with it; it remains in git history.

Registered proof readiness is not an execution PASS, and a missing `pg-dbx` Stage 2 result stays a
failed full run.
