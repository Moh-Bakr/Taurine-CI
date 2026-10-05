# How the hosted CI works

This repository (`Moh-Bakr/Taurine-CI`) is public. It is the control plane that validates two
private source repositories on free hosted runners. It contains workflows, small composite
actions and one concern table, and never any product source.

## The two-repo model

| Repository | Visibility | Holds |
| --- | --- | --- |
| `Moh-Bakr/Taurine-CI` | public | Workflows, composite actions, `.github/ci-matrix.json`, the policy workflow |
| `Moh-Bakr/Taurine` | private | The product source. Second private source: `Moh-Bakr/keeldock-cloud` (Keel Dock lane) |

Every validation is a manual `workflow_dispatch` (plus the weekly schedule) on `main` of this
repository, given the exact 40-character SHA of the private commit to test. Nothing runs on
pull requests or pushes with source access. Source never lands in this repository, and the
policy workflow rejects tracked source, credential and starter-document paths; the only tracked
files are workflows, composite actions (`action.yml`), the policy scripts, the concern and tool tables, and
flat `docs/*.md` guides such as this one.

## Token lifecycle

The `.github/actions/source-checkout` composite is the only way source-bearing jobs read the
private repository. Jobs that use it run in the `source-read` environment, which holds the
source-reader GitHub App (`SOURCE_READER_APP_ID` variable, `SOURCE_READER_PRIVATE_KEY` secret).

1. **Guard.** The repository must be this one, the ref must be `refs/heads/main`, and the SHA
   must match `^[0-9a-fA-F]{40}$`.
2. **Mint.** `actions/create-github-app-token` issues a short-lived token scoped to the one
   private repository with `contents: read` only. Its own end-of-job revoke is disabled
   (`skip-token-revoke`) because step 4 revokes explicitly.
3. **Exact-SHA checkout.** The requested commit is checked out into `src/` with
   `persist-credentials: false`, no submodules and no LFS.
4. **Verify and revoke (`if: always()`).** The step confirms the repository ID, owner and name,
   that `HEAD` equals the requested SHA, and that the API resolves that SHA, then calls
   `DELETE /installation/token`, clears git credentials and empties step-output files. Any
   failure fails the job before project code can run.

The policy workflow parses every source-read job and fails if a package manager, compiler or
project script runs before the revoking step, or if that step is not under `always()`. Mobile,
Linux and Windows concerns therefore only install dependencies, run `npm ci`, `cargo` or
`xcodebuild` after the token is dead.

## Per-platform concerns

| Workflow | Concerns |
| --- | --- |
| `linux-validation.yml` (dispatcher) and `linux-validation-concern.yml` | The 23 concerns in `ci-matrix.json`: contracts, frontend-build-budget, desktop-quality, desktop-shard-1/2, mobile-quality, taurine-cli, rust-domain, rust-db, rust-net, rust-app-1/2, rust-dbx, rust-packaging, rust-tls-openssl, e2e-critical, e2e-a11y, e2e-regression-1..4, scan-security, and opt-in e2e-visual |
| `macos-validation.yml` | desktop-shard-1/2, desktop-quality, mobile, bundle-budget, orchestrate-skill; with `rust=true` also rust-domain, rust-db, rust-net, rust-ovpn, rust-app, rust-packaging, rust-tls-openssl |
| `windows-validation.yml` and `windows-validation-concern.yml` | The same app concerns plus contracts; Rust concerns with `rust=true`; `windows_image` selects `windows-2022` (default) or `windows-2025` |
| `android-validation.yml` | android-native (debug build for aarch64); android-rust with `rust=true` (compile-only mobile test targets, not executed) |
| `ios-validation.yml` | ios-native (unsigned simulator build); ios-rust with `rust=true` (compile-only) |
| `orchestrate-validation.yml` | dashboard, release-verification |
| `keeldock-validation.yml` and `keeldock-validation-concern.yml` | build-format, structural, unit and contracts-publish-smoke on Linux, macOS and Windows; Linux-only db-containers and supply-chain; opt-in apphost-cold-start |
| `source-read.yml` | Reads an exact private SHA, a smoke test of the access path |
| `live-proofs.yml` (dispatcher) and `live-proof-arm.yml` | One arm per database engine; see [The live proofs](#the-live-proofs) |

Android uses `ubuntu-24.04` with a pinned command-line tools archive (SHA-256 verified), SDK
platform 36, build-tools 36.0.0 and NDK 27.2.12479018. iOS uses `macos-15`, the runner's Xcode
toolchain for libclang, and a pinned, checksum-verified XcodeGen archive. Both install JavaScript
dependencies through the `node-setup` composite (`npm ci --include=optional --ignore-scripts`,
then `scripts/vendor-openvpn3.sh fetch`, which verifies the vendored sources against pinned checksums).

## How the files are split

No workflow or composite is over 400 lines (the policy warns above 400 and fails above 800). Files are
split by responsibility: a workflow keeps everything that must run before project code (input
validation, the token mint, the exact-SHA checkout and the revoke) plus the job wiring, and the work
that runs after the revoke lives in composites under `.github/actions/`.

| Area | Workflow (entry point) | Composites it calls |
| --- | --- | --- |
| Shared | every protected workflow | `source-checkout` (mint, exact checkout, verify, revoke), `sanitize`, `timings`, `node-setup`, `rust-toolchain`, `vendor-fetch`, `verify-cargo-cache`, `concern-report`, `run-result` |
| Linux | `linux-validation.yml` calls `linux-validation-concern.yml`; `select-concerns.yml` plans | `linux-concern-js`, `linux-concern-e2e`, `linux-concern-rust`, `scan-concern`, `select-concerns`, `linux-test-identities` |
| macOS | `macos-validation.yml` | `macos-concern-js`, `macos-concern-rust` |
| Windows | `windows-validation.yml` calls `windows-validation-concern.yml` | `windows-concern-rust` |
| Android | `android-validation.yml` | `android-sdk-setup`, `mobile-report` |
| iOS | `ios-validation.yml` | `ios-project-init`, `mobile-report` |
| Keel Dock | `keeldock-validation.yml` calls `keeldock-validation-concern.yml` | `keeldock-restore`, `keeldock-build-format`, `keeldock-test-suites`, `keeldock-supply-chain`, `keeldock-apphost`, `keeldock-contracts-publish`, `keeldock-summary`, `keeldock-proof`, `keeldock-nuget-verify` |
| Live proofs | `live-proofs.yml` calls `live-proof-arm.yml` once per arm | `live-build`, `live-run`, `live-summary`, `live-start-mpp`, `live-start-ibm`, `live-start-rocketmq`, `live-start-iris`, `live-start-pg`, `live-start-sql` |
| Policy | `validate-public-changes.yml` | the scripts under `.github/policy/` |

Two conventions apply across all of them. Private source is checked out into `src/` and the
composites run from there, so the control plane's own composites stay available after the checkout;
the Keel Dock concern follows the same layout (its own mint and checks stay inline in the workflow, as
its policy requires). A step that must run whatever happens, such as the revoke, the summary and the
duration report, is conditioned on `always()` in the workflow, never inside a composite alone.

Every `uses:` reference, including each local workflow and composite, is on an allow-list in
`.github/policy/check-actions.sh`; adding a file means adding its exact reference there, in the same pull
request, and a reviewer sees the addition.

## ci-matrix.json and change-aware selection

`.github/ci-matrix.json` is the one concern table for Linux. Each concern has a `timeout`
(minutes) and one or more of: `always`, `paths`, `rust_packages` or `rust_package_glob`,
`full_only` (dropped by the quick profile) and `opt_in` (the dispatch input that enables it).
Top-level `rules` list build-wide paths (`full_if_any_changed`) and `docs_only` paths.

The Linux dispatcher reads the table; the `plan` job builds the concern list, and the
`select-concerns` composite narrows it when a `base_sha` is supplied. It runs after checkout
with history and the token already revoked, diffs `base_sha` to `source_sha`, and selects:

- **full** when there is no `base_sha`, `base_sha` is not an ancestor, a build-wide path changed
  (lockfiles, toolchain files, `vendor.lock`, `.github/**`, scanner config), any changed path
  matches no rule, or more than `max_changed_files_before_full` files changed;
- **partial** otherwise: the concerns whose `paths` match, plus the concerns whose Rust crates
  are reached by a reverse walk of path dependencies, plus the `always` ones. A docs-only diff
  selects only the `always` concerns. `excluded_trees` stop a tree from selecting concerns it
  does not affect.

A requested opt-in concern always joins a partial selection and its absence fails the Result.
Only Linux uses `base_sha`; the other platforms always run their whole list.

## Dispatch inputs

| Input | Where | Effect |
| --- | --- | --- |
| `source_sha` | every workflow | Exact private commit to validate |
| `profile` (`full` or `quick`) | Linux | `quick` drops `full_only` concerns (rust-app, rust-db, rust-dbx, scan-security, a11y, regression e2e) and gives PASS (partial) |
| `visual` | Linux | Adds the Playwright `e2e-visual` tier; leave off until baselines for Linux exist |
| `base_sha` | Linux | Enables change-aware selection (a partial run) |
| `rust` | macOS, Windows, Android, iOS | Schedules the slow Rust concerns; without it they are reported as not requested |
| `apphost` | Keel Dock | Adds the experimental Aspire apphost-cold-start concern |
| `engine` | live-proofs | One engine, a comma-separated list of engines, or `all` |
| `windows_image` | Windows | `windows-2022` (default) or `windows-2025` |
| `vulnerability_gate` | Keel Dock | `none` (warn-only), `high` or `critical`: the severity that fails supply-chain |

## The Result verdict

Each dispatcher ends with a `Result` job using the `run-result` composite. It lists every
concern the workflow can run, reads each one's conclusion from the run's job list and writes:

- **PASS (full)**: every possible concern ran and succeeded. This is the only verdict that
  admits a merge.
- **PASS (partial)**: everything that ran succeeded, but some concerns were not selected
  (quick profile, `base_sha`, or `rust=false`). They are shown as "not selected", never as
  passed. A partial verdict does not admit a merge.
- **FAIL**: a concern that ran did not succeed, no concern ran, or a required opt-in concern did
  not run.

Always confirm the summary names the exact 40-character SHA you requested before attributing a
result to a commit. A `Timings` job beside it tabulates durations against committed baselines and
warns, without failing, when a job is more than 25% and two minutes slower.

## The weekly run and drift

`weekly-validation.yml` runs Monday 05:23 UTC, deliberately off the top of the hour because GitHub delays or drops scheduled runs at :00 (or manually, with `dry_run`). If Monday's run is missing, dispatch it by hand on `main`. It resolves the
private `develop` tip with a source-reader token it revokes immediately, then dispatches
`linux-validation` (full), the same Linux run with `base_sha` set to the develop tip from seven
days earlier, and `macos-validation` and `windows-validation` with `rust=true` (plus a non-gating
`windows-2025` run). Android and iOS
are not part of the weekly run; dispatch them by hand. The base_sha run is the drift check:
a concern that fails in the full run but is "not selected" in the selective run reveals a gap
in the `ci-matrix.json` rules. The summary also reports how far the locked `openssl-src` is
behind the newest 300.5.x release.

## The live proofs

`live-proofs.yml` runs each selected database engine's env-gated conformance suite against its real
single-node Docker server at an exact private SHA (Postgres, MySQL, SQL Server, Db2, Informix, Doris,
StarRocks, RocketMQ, IRIS, plus the Postgres TLS and bastion proofs). These runs find driver defects
that the offline suites cannot.

It is split three ways:

- **The dispatcher** (`live-proofs.yml`) validates the dispatch input, holds the arm roster (one JSON
  definition per arm) and calls the arm workflow once per selected arm. It passes only the source-reader
  key, by name, and tabulates arm durations against a committed baseline.
- **The arm workflow** (`live-proof-arm.yml`, reusable and protected) runs in the `source-read`
  environment, performs the exact-SHA checkout and revoke through `source-checkout`, then builds,
  starts the server, runs the suite and publishes the summary.
- **The `live-*` composites** hold the per-engine server start-up (image digest pins, ports, readiness),
  the cargo build, the run and the summary.

Each selection has its own concurrency group, runs are never cancelled, and only check titles and counts
are published.

## Sanitising: no artifacts, no source in logs

Source-bearing output is public, so it is treated as hostile:

- No artifacts, no source-bearing caches. Composites may not use `actions/upload-artifact`,
  `download-artifact` or caches; the only reviewed cache is for verified third-party crate sources.
- Commands run through `run_quiet` (or the mobile `mobile_run`): output stays in a runner-local
  log and only a fixed one-line classification, the exit status and allow-listed detail are printed.
- The `sanitize` composite installs the shared library: it strips ANSI codes, workspace and
  absolute paths, registry checkouts and token shapes, and drops source excerpts. Detail is
  limited to shapes that carry no source text: Rust error codes with `file:line`, test names,
  counts, advisory IDs and package versions, never message text, values or symbols.
- Failure reasons come from fixed classifiers (`cargo_test_reason`, `js_reason`,
  `mobile_reason`), not from the output itself.
- The policy workflow runs the sanitizer expressions against path and token fixtures and fails if
  any leaks.
- Workflows declare `permissions: {}` and grant per job; every Action is pinned to a full
  commit SHA on the policy allow-list; protected concurrency groups set `cancel-in-progress:
  false` so a cancel cannot skip token revocation.

## How to add a concern

1. **Linux:** add the entry to `.github/ci-matrix.json` with a `timeout` and its `paths` or
   Rust packages (`full_only` or `opt_in` as needed). Handle its name in
   `linux-validation-concern.yml` (or the `linux-concern-*` composite it calls), and add a baseline to the `timings` step of
   `linux-validation.yml` if wanted. The policy fails if the table, the handler or the baselines
   disagree.
2. **macOS, Windows, Android, iOS:** add it to the `plan` job's matrix (behind its input if opt-in),
   to the `case` that runs it, and to the Result job's `expected-concerns`; add a timeout and a
   baseline.
3. Run every command through the reporting helpers, install dependencies after the token revoke
   and pin any tool you download by version and SHA-256.
4. Open a pull request. The `Validate public CI policy` check is required before the squash merge.
5. After merge, dispatch the workflow once from `main` against a private SHA and confirm the
   Result lists the new concern.
