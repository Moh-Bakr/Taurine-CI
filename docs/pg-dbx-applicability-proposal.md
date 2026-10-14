# PostgreSQL DBX applicability proposal

**Status: prototype only; not adopted.** This document proposes how a reviewed applicability
decision could be represented. It does not change the deployed live-proof roster, dispatch
identity, required results, or admission policy.

## Deployed behavior observed

The public control plane currently registers 12 live-proof arms. Its canonical `all` selection
expands to those 12 arms, and full admission requires all live arms. `pg-dbx` is one of them.
The latest `all=12` attempt was red because the private source snapshot did not provide the
Stage 2 proof expected by that arm. A missing or failed arm remains a failed full run. The local
diagnostic described here cannot revise that result.

### Draft applicability catalog

The proposal catalog is fixed data in the standalone diagnostic and is repeated here for review.
It distinguishes:

- **Registered:** the 12 names the deployed dispatcher knows.
- **Current requirement:** all 12 remain required by deployed full admission, including
  `pg-dbx`.
- **Non-waivable baseline:** the other 11 arms that any future ADE applicability profile must
  continue to require.
- **Applicability decision:** `pg-dbx` is registered and its current disposition requires an
  explicit owner decision. This proposal does not declare it not applicable.
- **Readiness:** the local diagnostic may report only whether fixed evidence markers are absent,
  partial, present as recognizable candidates, or invalid. It cannot report test execution, a test
  result, or admission.

```json
{
  "schema_version": 1,
  "proposal_state": "not_adopted",
  "registered_engine_ids": [
    "doris", "starrocks", "db2", "informix", "rocketmq", "iris",
    "postgres", "pg-dbx", "mysql", "mssql", "pgtls", "bastion"
  ],
  "baseline_non_waivable_engine_ids": [
    "doris", "starrocks", "db2", "informix", "rocketmq", "iris",
    "postgres", "mysql", "mssql", "pgtls", "bastion"
  ],
  "deployed_behavior": {
    "all_options_count": 12,
    "all_expands_to_registered": true,
    "current_full_admission_requires_all_live_arms": true
  },
  "pg_dbx": {
    "engine_id": "pg-dbx",
    "registration": "registered",
    "current_admission_requirement": "required",
    "proposed_applicability_requirement": "owner_decision_required",
    "readiness": "invalid_evidence",
    "candidate_suite_ids": ["dbx_pg_live", "dbx_shadow_pg"]
  }
}
```

The proposed suite IDs for `pg-dbx` are fixed as `dbx_pg_live` and `dbx_shadow_pg`. The local
probe accepts only the `pg-dbx` engine and these suite IDs. It accepts no runner commands, filters,
skip lists, or source-defined coverage requirements. A local versioned manifest maps a fixed set
of evidence categories to relative paths in the source checkout. The manifest is an untrusted
location map: even when every category is recognized, the only possible positive result is
`candidates_present`. The source-specific mapping is kept out of this proposal artifact.

## Current source evidence

The source snapshot reviewed for this prototype has **0 of 5** recognizable candidate markers.
Its diagnostic reports `invalid_evidence`: two present files did not match the fixed recognizers,
and three mapped markers were absent. This result describes the probe's recognition only; it does
not claim the underlying files are malformed or the product is failing. The public proposal omits
private source paths, file contents, source-specific implementation inventory, and the private
source revision. Detailed mapping data is kept in a local-only manifest outside tracked files.

The result means those proof artifacts are unavailable in that source snapshot. It does not mean
the DBX adapter failed to execute, that the Postgres legacy arm covers it, or that `pg-dbx` is
not applicable. The diagnostic does not compile Cargo manifests or run tests.

## Smallest adoption path after an explicit owner decision

If the owner decides `pg-dbx` is not applicable to the current ADE source snapshot, record the
scope, source boundary, reason, owner, and revisit trigger. Then review and implement all of the
following as one policy change:

1. Add a versioned applicability identity and catalog digest to dispatch identity and sanitized
   run summaries. The selected profile must be explicit and bound to the exact source SHA.
2. Preserve the existing `all` option and its 12-arm expansion. A separate reviewed profile may
   describe an ADE-specific applicability set; source manifests cannot select or remove arms.
3. Keep all 11 baseline arms required in that profile. Mark `pg-dbx` with the reviewed owner
   disposition and keep it registered for explicit future proof runs.
4. Update dispatch contracts, roster validation, result aggregation, fixtures, and policy checks
   together. Full admission for the new profile is possible only when its approved catalog
   identity matches and every required baseline arm passes on the same requested source SHA.
5. Keep the 12-arm `all` admission unchanged. A missing, failed, skipped, or stale `pg-dbx` result
   under `all` remains red; the new profile cannot relabel that run.

This disposition would leave Stage 2 DBX live proof and shadow comparison uncovered for that
ADE source snapshot. It would not establish Stage 2 parity, PG2 live proof, PG3 shadow parity, or
readiness to flip the PostgreSQL route. The legacy Postgres arm is not a substitute for those
DBX-route proofs. The disposition must be revisited when the adapter, feature wiring, and proof
suites land or when the source scope changes.

## Diagnostic contract

Run the prototype with a reviewed local marker manifest and source-root path. It reads only the
manifest and listed regular files; it does not execute source or invoke Cargo. It rejects unsafe
paths, symlinks, malformed or oversized inputs, unknown engines, and catalog drift. Source files
are classified only by fixed filename checks and bounded text-shape recognizers. In particular,
the Cargo manifest checks are regex-based heuristics, not TOML parsing or semantic validation.
They can identify recognizable candidates only; they cannot establish a valid build, suite
registration, or executable proof. Output is a small JSON record with fixed statuses and counts
only, including separate observed and invalid marker counts. The fixed execution field is
`not_run`; the fixed admission field is `not_evaluated`. The command exits with a nonzero
diagnostic-only code for every report so a shell cannot treat candidate presence as a passing
gate.

`candidates_present` means that all five mapped categories matched their fixed recognizers. It is
not a PASS, a readiness attestation, or an input to any deployed workflow. Present but
unrecognizable evidence reports `invalid_evidence`; it cannot be mistaken for absent Stage 2
proof. `unavailable_stage2_proof`, `partial_or_inconsistent`, `invalid_manifest`,
`catalog_mismatch`, `unknown_engine`, `roster_mismatch`, and `invalid_evidence` fail closed. No
workflow consumes this prototype.
