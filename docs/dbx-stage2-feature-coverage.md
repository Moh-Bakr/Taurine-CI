# DBX Stage2 feature coverage and source admission

The existing Linux, macOS and Windows `rust-db` concerns keep their complete
`taurine-db*` package invocation and ordinary doctests. The conformance package
already enables the engine's ordinary `dbx-pg` feature in that combined invocation.

When the exact source registers `taurine-db-dbx` in the selected Cargo package set,
two additional **fixed, mandatory** cases run in the same concern:

- The adapter with `legacy-tls`, including its normal doctest companion.
- The engine's `dbx_route_dial` integration target with
  `dbx-pg,engine-override,taurine-db-dbx/legacy-tls`. Only this target invocation
  suppresses its incompatible `cargo test --doc` companion.

The commands come from the public runner. Private project metadata does not supply
commands, feature names or target names. Missing features/packages/targets fail the
required step; no test execution uses nextest's explicit `--no-tests=fail`. Missing
the pinned nextest runner or the source's CI profile fails required coverage. The
build splitter removes the run-only no-tests option, keeping the same package,
feature and integration-target selection. Ordinary Cargo fallback stays available
for the older baseline, but cannot manufacture required Stage2 test evidence.

Source that predates Stage2 explicitly reports **uncovered / not executed** for
these feature cases. Its existing baseline invocation remains supported. This
does not remove the mandatory live Dbx-route proof (the `dbx_pg_live,dbx_shadow_pg` suite of the `postgres` arm), credit legacy tests as Dbx tests,
or turn an old source with missing Dbx targets into an all-12 PASS.

## Required admission record

The coordinator records the final reviewed feature-bearing DBX source SHA in the
admission ledger. On each applicable platform's own full-source job, it requires:

1. The full requested private source SHA echo equals that approved SHA.
2. The registered-adapter required state and both feature test labels are present.
3. Their builds/tests succeed with nonempty execution; ordinary baseline and
   doctest requirements also succeed.
4. The separate full live all-12 and the remaining parity/security gates pass on
   that same approved source. No absent-state report satisfies DBX admission.

Older ADE platform/visual evidence stays attributed to its older exact SHA. After
DBX/ADE integration changes the source, the coordinator obtains the required full
gate for that resulting SHA. Neither older evidence nor a surgical partial visual
run replaces the final source-bound full admission gate.

This change creates no new concern, opt-in input, dispatch identity exception,
queue, TLS door, live roster exemption or source-controlled coverage command.
Root independently reviews the frozen control delta and owns publication/rollout.
