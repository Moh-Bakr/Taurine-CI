# ADR: Pinned Playwright parity fixtures remain shadow-only

## Status

The fixtures and the fixture-only harness remain shadow-only and prove nothing about the real suites. The separate case-evidence contract they belong to **is** now activated in the Linux browser concerns; see `case-evidence-contract.md`. This ADR still enables no selector and no admission decision.

## Decision

Keep deterministic test-owned fixtures for Playwright list/run parity separate from source-project tests. The current public producer adapters pin desktop Playwright `1.62.0` and mobile `1.62.1`; the synthetic manifest copies the exact integrity values from the fixed adapter. Vitest remains unsupported until its own pinned discovery/execution parity is proven.

The all-pass fixture covers nested describe groups, parameterized titles, a file-suite title that differs from its full file path in the static JSON regression, and adapter-specific project/tier/file scopes. Separate fixtures cover a joined-title collision, an expected failure with matching attempts, an intentional unexpected pass, a flaky retry, a skip, and a reporter callback exception. The collision uses distinct valid title paths that normalize to the same joined title. Until hosted parity is proven, the runner may reject collection before the control can classify that identity collision; either result remains fail-closed. Expected outcomes are recorded independently so a negative outcome cannot be counted as an all-pass parity run. Retry-sensitive expected failure, unexpected pass, and skip cases use a zero-retry config; the flaky case has its own one-retry config.

For the all-pass scopes, desktop `smoke` and `critical` use the desktop feedback tier and desktop fixture path. Mobile `smoke` uses the mobile smoke tier and mobile path; mobile `critical` uses the mobile critical tier and mobile path. The manifest records each `(runner, config, project, tier, app file)` tuple explicitly.

## Local shadow harness

`.github/policy/playwright-pinned-parity-producer.rb` is a separate fixture-only harness. It accepts only the source checkout path; it accepts no runner, project, command, filter, or arbitrary argument list. Before starting any project child, it compares the observed control and source checkout heads to externally supplied full 40-character `TAURINE_PARITY_EXPECTED_CONTROL_SHA` and `TAURINE_PARITY_EXPECTED_SOURCE_SHA` bindings. It then verifies both checkouts are clean, reads only the fixed expected-case manifest, and checks each app lockfile and installed package version against the hardcoded desktop `1.62.0` and mobile `1.62.1` integrity bindings.

For all-pass cases it runs exactly four scopes: desktop `smoke` and `critical` at feedback tier, and mobile `smoke` at smoke tier and `critical` at critical tier. For each scope it copies only the fixed config/spec into a mode-0700 temporary directory below that app root, runs a fixed list command with the control reporter, then runs the same config/project with Playwright JSON output. It reconciles the exact three-case identity set and expected attempts. Negative outcome parsing requires exactly three distinct expected titles and complete status/attempt data; duplicate-identity requires exactly two prescribed discovery rows with a real normalized identity collision; the callback-failure reporter must emit its fixed private sentinel before the wrapper treats the callback check as observed. These negative checks run separately and never increase the positive case count. Raw reports, titles, IDs, paths, and runner output stay in mode-0700/0600 temporary locations; stdout contains only fixed aggregate counts or a fixed error class.

The harness copies the reviewed process-group timeout, pipe-drain deadline, and output-cap behavior from the existing case evidence producer. Its synthetic subprocess test uses a fake executable, fake source/control repositories, and fabricated reports only. It does not launch Playwright, npm, a browser, or private app tests. The source-clean check is performed before creating the private fixture directory; that directory is removed on exit.

## Hosted boundary and limits

The path problem this paragraph used to describe is resolved without touching the rule. `.github/policy/` still permits only flat `.sh` and `.rb`; the reporter and the fixtures are no longer tracked files at all. They live in `.github/policy/case-evidence-assets.rb` and are materialised into the private mode-0700 staging directories at run time, so the public repository tracks no JavaScript or JSON and no path exception was reviewed or granted. The producers bound each fixture to the control commit with `git show` on its path; they now bind the asset module the same way, so the staged bytes are still pinned to the verified control commit. The static validator and both fake-runner harnesses are invoked explicitly by `validate-public-changes.yml`. The public workflow and feature-selection/admission path are unchanged.

A hosted proof must run only on a protected control revision and exact source SHA. It must preserve the current source-read ordering: preflight, exact checkout and identity verification, token revocation before project commands, then root removal before dependency setup or tests. It must use the same fixed fixture-only commands, check child exit and completion markers, cap output and report sizes, include pipe draining in its deadline, and publish aggregate counts only. It must not run app project tests as a substitute for these fixtures.

Even a successful hosted run cannot prove its own producer against same-UID modification of the reports, temporary files, or process environment. Its result must remain `shadow_fixture_parity_unverified`; it cannot attest source coverage, producer completeness, selection, or admission. Vitest remains unsupported until a separate real pinned list/run parity proof exists.

## Current limits

The fixture validator checks static files and metadata. The fake-process harness checks its own fixed wrapper contract, but no real Playwright, browser, source test, or Vitest process has run for this artifact. Actual pinned runner JSON shape and list/run parity remain hosted proof requirements. No workflow, feature catalog, selection rule, or admission consumer is changed here.
