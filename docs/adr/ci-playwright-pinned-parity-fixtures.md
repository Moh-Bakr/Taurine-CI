# ADR: Pinned Playwright parity fixtures remain shadow-only

## Status

Prepared for hosted review. This ADR does not enable a workflow, selector, producer, or admission decision.

## Decision

Keep deterministic test-owned fixtures for Playwright list/run parity separate from source-project tests. The current public producer adapters pin desktop Playwright `1.62.0` and mobile `1.62.1`; the synthetic manifest copies the exact integrity values from the fixed adapter. Vitest remains unsupported until its own pinned discovery/execution parity is proven.

The all-pass fixture covers nested describe groups, parameterized titles, a file-suite title that differs from its full file path in the static JSON regression, and repeated test titles across `smoke` and `critical` projects. Separate fixtures cover duplicate normalized identity, an expected failure with matching attempts, an intentional unexpected pass, a flaky retry, a skip, and a reporter callback exception. Expected outcomes are recorded independently so a negative outcome cannot be counted as an all-pass parity run.

## Future hosted protocol proposal

The future hosted job must first validate the source SHA, source app lockfile/config, adapter version and protected package integrity. It should copy only the reviewed fixture files into a private mode-0700 synthetic directory under the selected app root; this lets Node resolve that app's pinned `@playwright/test` without adding or changing source-project tests. Use a fixed config and a fixed project invocation per adapter/project. Do not accept a source-controlled command, grep, project list, shell fragment, or arbitrary reporter argument.

For each all-pass project, run one independent list phase using the control-owned list reporter and one execution phase using Playwright's JSON reporter. Compare exact normalized `(runner, config, tier, platform, project, file, title)` identity sets, not counts alone. Keep both raw reports, IDs, absolute paths, and full runner output inside the private temporary directory; publish only fixed counts, outcome classes, exact source SHA, and a fixed pass/fail result. Require nonempty complete discovery and execution, no duplicate IDs, exact result cardinality, both command exits, and no skips/flakes/unexpected outcomes for the all-pass phase.

Run the negative fixture phases separately and require the exact fixed classification: duplicate identity rejects, matching `test.fail()` remains a passing expected outcome, unexpected pass/flaky/skipped outcomes block, and reporter callback failure without a successful completion marker blocks. These phases demonstrate fail-closed behavior; they do not add their cases to the clean all-pass count.

The runner process must have a deadline that includes draining stdout and stderr, a fixed output cap, a private environment, and process-group termination on timeout/cancellation. The wrapper must validate and reconstruct only the approved result schema before publishing counts. A shared runner UID can still modify same-UID temporary files; therefore this producer remains `shadow_valid_unverified_producer` until protected hosted evidence and an independently reviewed trust boundary exist.

## Current limits

The fixture validator only checks static files and expected-case/outcome metadata. No real Playwright, browser, source test, or Vitest process has run for this artifact. The pinned runner's actual JSON shape and list/run parity remain a hosted proof requirement. No workflow, feature catalog, selection rule, or admission consumer is changed here.
