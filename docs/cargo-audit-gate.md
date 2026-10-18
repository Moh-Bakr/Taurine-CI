# Unsound advisory enforcement

The Linux `contracts` concern invokes the checksum-verified cargo-audit v0.22.2
release directly, with `audit --deny unsound --file <lock>` for each discovered
`Cargo.lock`. Vulnerabilities and unsound advisories fail the concern; unmaintained
warnings retain their existing warning-only behavior. The binary path and deny
arguments are control-owned literals. No source-selected executable or additional
argument string is accepted.

The sweep retains its filesystem discovery, including ignored and untracked locks,
excluding only `target` and `node_modules`. It continues after a scanner failure
and returns failure after scanning the remaining locks. An unsuccessful scanner
installation fails the sub-step without attempting a missing binary.

The private root `.cargo/audit.toml` remains the reviewed advisory baseline.
`--deny unsound` does **not** override ignored advisory IDs. This wrapper change
alone does not close RUSTSEC-2026-0097: both private suppressions must be removed
and every production dependency graph repaired by the source integration owner.

All scanner execution remains inside the protected `run_deferred cargo-audit`
reporter, after source checkout and token revocation. Raw output stays in the
runner's temporary log; successful output is withheld and failures use the existing
advisory-detail filter. No source artifact or new dispatch/source input is added.
Any private hosted regression must also execute through protected capture; a direct
Python invocation can disclose private paths or source lines in a traceback.

## Public regression coverage

Run `bash .github/policy/test-cargo-audit.sh` from this public repository. It uses
only synthetic lock paths and a scanner stub at the pinned release's expected
location. It extracts the actual composite sweep and uses the actual sanitizer
and concern-reporting libraries. It never downloads a scanner, reads private code,
or runs Cargo, application tests or a native build.

The fixtures check exact argv (including a lock path containing shell metacharacters),
the fixed scanner path despite environment/PATH decoys, ignored/untracked discovery,
continued scanning after failures, scanner/install errors, warning-only success,
and fail-closed concern aggregation. Output checks cover both logs and summaries:
raw private-shaped paths, source excerpts, crate names and tokens stay withheld.
Two falsifiers require the same unsound-failure assertion to reject a removed deny
flag and a stub that makes an unsound report nonfatal even with the flag present.
The finding-sensitive stub accepts only explicit `affected0097` and `repaired0097`
lock classifications. An unknown classification fails while later locks still run;
reclassifying both affected fixtures as repaired passes the same scanner path.

These are wrapper/policy simulations, not proof of scanner authenticity or advisory
closure. The unchanged protected installer supplies checksum verification. Actual
affected and repaired dependency scans, private regression failure sanitization,
independent security review and exact-SHA hosted admission remain separate gates.

## All-locks helper (additive to the per-lock sweep)

After the per-lock sweep, the `contracts` concern also runs the private source's reviewed
`scripts/audit-all-locks.sh` as `cargo-audit-all-locks`. The sweep stays the public floor: it is
owned here and always applies `--deny unsound`, so a private helper that exits 0 cannot lower its
verdict. The helper adds what only the source can supply: the generated vendor locks, refusal of a
target or severity filter in `.cargo/audit.toml`, and lock-byte tamper detection. The ignore lists
it reads (`.cargo/audit.toml`, `deny.toml`) remain the single private record.

- **Where it runs:** after token revocation and `drop-root`, like every project command, with a
  cleared environment, the pinned scanner passed explicitly as `CARGO_AUDIT_BIN`, no arguments and
  a 6-minute limit. The `contracts` job timeout is 30 minutes (`ci-matrix.json`); the helper is
  capped so the deferred summary is still written, and the job timeout is unchanged. The advisory database is fetched as the sweep fetches it; no cache is added
  and none is restored on `untrusted`.
- **Fail closed:** a symlink or non-regular file at the helper path fails on every ref. A missing
  helper fails when the checked-out SHA is on `develop`, `uat` or `main` (the source-checkout
  `protected-ancestor` answer, passed as `require-all-locks-audit`); on any other SHA it prints a
  fixed-shape transition notice and the sweep alone decides. An exit 0 without a clean
  `N lockfile(s) audited, 0 failed.` line (N at least 1) is a failure.
- **Published:** at most 50 advisory IDs, matched leniently (the helper indents, cargo-audit pads
  labels) and re-emitted canonically as `ID: RUSTSEC-YYYY-NNNN`, plus the count line (at most four
  digits per number). The helper's output file is never printed, uploaded or cat-ed.
- **Fixtures:** `bash .github/policy/test-all-locks-audit.sh` (stub helper, four falsifiers) and
  mutation cases 12 in `test-mutations.sh`.

- **Fail-closed values:** only the exact string `false` relaxes `require-all-locks-audit`, and
  likewise `fmt-fail` / `fail` in `rust-lint-enforce`; an empty or other value enforces.
- **Network egress (accepted for now):** the `contracts` concern runs with `egress: "audit"`, so the
  helper, and any `vendor-openvpn3.sh fetch` it triggers when generated vendor locks are missing,
  have unrestricted network. That is no worse than the npm sub-steps in the same step. Follow-up:
  move `contracts` to block-mode egress, or give the helper a provisioned-vendor / no-fetch path.
- **rustfmt is a hygiene gate:** `.rustfmt.toml` is source-controlled, so the source can opt crates
  out of formatting. The gate catches accidents, not a hostile source.

Rollout order: this change must merge only after the private source has the helper on `develop`.
