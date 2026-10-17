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
