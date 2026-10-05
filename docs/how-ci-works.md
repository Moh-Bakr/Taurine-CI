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

0. **Environment pre-flight.** Before any job enters `source-read`, a job with no environment
   and no secret runs the `environment-preflight` composite: the environment must use custom
   deployment branch policies that are exactly the branches `main` and `untrusted`, or the run
   stops (see [Repository settings](#repository-settings-the-owner-applies-once) for why
   "Protected branches only" is refused). The scheduled weekly resolver, which runs only from
   `main`, relies on the lanes it dispatches for this check.
1. **Guard.** The repository must be this one, the ref must be `refs/heads/main` or
   `refs/heads/untrusted` (see [Ref isolation](#ref-isolation-main-and-untrusted)), and the SHA
   must match `^[0-9a-fA-F]{40}$`. A run from `untrusted` must also be running exactly main's
   tip, or it stops here.
2. **Mint.** `actions/create-github-app-token` issues a short-lived token scoped to the one
   private repository with `contents: read` only. Its own end-of-job revoke is disabled
   (`skip-token-revoke`) because step 4 revokes explicitly.
3. **Exact-SHA checkout.** The requested commit is checked out into `src/` with
   `persist-credentials: false`, no submodules and no LFS.
4. **Verify and revoke (`if: always()`).** The step confirms the repository ID, owner and name,
   that `HEAD` equals the requested SHA, and that the API resolves that SHA, then calls
   `DELETE /installation/token`, clears git credentials and empties step-output files. Any
   failure fails the job before project code can run. On `main` the step also refuses, after
   the revoke and before project code, any SHA that is not on `develop`, `uat` or `main` of the
   source repository.

The policy workflow parses every source-read job and fails if a package manager, compiler or
project script runs before the revoking step, or if that step is not under `always()`. Mobile,
Linux and Windows concerns therefore only install dependencies, run `npm ci`, `cargo` or
`xcodebuild` after the token is dead.

## Root before project code

Revoking the source token is not enough on its own. The App private key that mints it
(`SOURCE_READER_PRIVATE_KEY`) is a job secret, and the runner keeps job secrets in memory for
the whole job. A hosted Linux or macOS runner also gives every step passwordless `sudo`, and
root can read any process's memory. So, before this change, project code (an npm or cargo build
script, a test) could in principle have read the key as root (finding H2).

The fix is to take root away before project code runs, not to test whether memory can be read.
Every source-bearing job does three things, in this order, straight after the token is revoked:

1. **Privileged setup** (`.github/actions/root-setup`, plus the live-proof and Keel Dock
   container start-up). Everything that needs root happens here: the Ubuntu archive packages a
   concern links against, the scratch-disk target directory, Playwright's Chromium host
   libraries (a fixed list, so the locked Playwright CLI no longer runs `--with-deps` as root),
   the KVM device rule for the Android emulator, the macOS disk reclaim and Xcode selection,
   the Semgrep container scan, and the database containers. None of it runs project code.
2. **Drop root** (`.github/actions/drop-root`). It replaces the sudoers policy with one that
   lets only root use `sudo` (this removes the job user's `NOPASSWD` rule, and on macOS the
   `%admin NOPASSWD` rule too), makes the Docker socket root-only, makes `/usr/local/bin`
   root-owned (it is on root's default `PATH` and the images leave it writable by the job
   user), and on macOS turns developer mode off and takes the job user out of the `admin` and
   `_developer` groups.
3. **Verify, fail-closed.** A separate step checks that `sudo -n true` is refused, that the job
   user is not root, that Docker is closed (unless the concern keeps it, below), that
   `/usr/local/bin` is not writable, and that the job cannot attach a debugger to the runner
   (Linux: `kernel.yama.ptrace_scope` is at least 1; macOS: developer mode is off). Any failure
   stops the job before project code. The job summary has a "Root before project code" block
   showing the result.

The policy workflow enforces the order (`.github/policy/drop-root-order.rb`): every
source-read job calls `drop-root` exactly once, after the revoke; only reviewed root-needing
steps may sit between the two; and no step after it may call `sudo`, or Docker unless that job
keeps Docker. A composite called after `drop-root` may not contain `sudo` (the egress audit's
best-effort `sudo -n` fallbacks are the one exception).

The feasibility probe (a scratch workflow with no secrets, no environment and no private
source, run on 2026-10-05 and then deleted) showed, on `ubuntu-24.04`, `ubuntu-latest`,
`macos-15` and `macos-latest`, that a later step gets `sudo: a password is required` from
`sudo -n true` once the sudoers files are replaced. Removing the user from the `docker` group
does **not** work on its own, because running processes keep the group they started with;
making the socket root-only does. Later `uses:` actions (`setup-node` with an uncached
release, `setup-dotnet`) still work, because they install into directories the job user owns.
Containers started before the drop keep running and stay reachable on their published ports.

### Residual risk, per operating system

**Linux (`ubuntu-24.04`).** Passwordless `sudo` and the Docker socket are gone before project
code. What remains:

- The job user is the same user as the runner process. With `kernel.yama.ptrace_scope=1` it
  cannot attach a debugger to the runner or read its memory, but it can still read the
  runner's `/proc/<pid>/environ` and the environment of Actions it starts. That is how the
  runtime token for the Actions cache can be read, which is why caches stay off until unprotected
  SHAs run from a separate ref (see the cache notes below).
- Processes started as root before the drop keep running as root with fixed commands: the
  egress-audit recorders. The job user cannot signal them, so they run until the runner is
  discarded.
- Live-proof database containers start before the drop. Some run the source's own lab init
  scripts inside the container (Postgres, MySQL and SQL Server seeds, the TLS entrypoint), one
  builds the bastion image from the source's Dockerfile, and the SQL Server init uses the host
  network. None of these containers can see host processes. Db2 and Informix run privileged
  but from digest-pinned vendor images with no source mounted.
- **The live-proof `bastion` arm keeps Docker**: its tunnel test asks `docker inspect` for the
  lab postgres container's network address, which only the bastion can route to. Every other
  live-proof arm closes Docker. `sudo` is removed in all of them.
- **Keel Dock `db-containers` and `apphost-cold-start` keep Docker**, because their project
  code starts containers itself (Testcontainers, the Aspire AppHost). Docker access is
  root-equivalent, so in those two concerns project code can still reach root through Docker.
  `sudo` is still removed. The job summary says "Docker: kept open" for these.
- **The opt-in `e2e-visual` tier** runs inside a job container as root, and GitHub mounts the
  host Docker socket into job containers. Root cannot be removed there. The summary records it;
  leave the tier off unless the run needs it.
- A kernel privilege-escalation bug would bypass all of this. That is outside what the
  workflow can control.

**macOS (`macos-15`).** Passwordless `sudo` is gone, including the `%admin NOPASSWD` rule in
`/etc/sudoers`. Developer mode is off, so the job cannot attach a debugger to the runner
without an authorisation it can no longer grant itself. What remains:

- The job user is out of `admin` and `_developer`, but it is still the same user as the
  runner process. Reading the runner's memory would need either root or a debugger
  authorisation; neither is available to the job any more. This was not tested by trying to
  read memory, by design: the probe only proved that `sudo`, developer mode and the group
  memberships are gone, and that the iOS simulator, Homebrew installs, a throwaway keychain,
  `xcodebuild`, `setup-node` and `setup-dotnet` still work afterwards.
- An authorisation prompt (for example `osascript ... with administrator privileges`) cannot
  be answered on a headless runner; the probe showed it simply waits.
- The job user still owns Homebrew (`/opt/homebrew`) and its own home directory. No root
  service runs anything from them during a job (the image's one root launch daemon that names
  a job-writable path, `change_hostname.plist`, runs only at boot; its script in
  `/usr/local/bin` is now root-owned).
- The root half of the disk reclaim (removing the other Xcode installs and the simulator
  runtimes) is started before the drop as one `sudo bash -c`, with its whole script in memory,
  and keeps running as root after it. It reads no file the job user can write.

**Windows (`windows-2022`, `windows-2025`).** Root cannot be dropped: the hosted job user is
an administrator, and there is no supported way to demote it within a job. Project code can
therefore read the runner's memory, and with it the App private key. The mitigations are the
ones that applied before: the token is minted, used and revoked before any project code (the
same `source-checkout` order, enforced by the policy), the App can only read the two source
repositories, and the key can be rotated (`docs/source-reader-key-rotation.md`). The job
summary records the residual risk on every Windows job.

## Egress: audit and block

Every source-bearing job runs the `egress-audit` composite: `start` straight after the source
checkout, `report` last. It records DNS answers and new outbound connections (Linux:
`resolvectl monitor` and an iptables LOG chain; macOS: `tcpdump`; Windows: the DNS Client
event log) and publishes only names on the reviewed allow-list (`.github/egress-allowlist.txt`);
any other name appears as `unlisted:<12-hex SHA-256 prefix>`.

**Block mode (Linux).** The composite takes `mode: audit|block`. A Linux concern's mode comes
from `ci-matrix.json` (`egress`). In block mode the composite's `enforce` phase, which runs
after `root-setup` and immediately before `drop-root`, calls the `egress-block` composite:

- a filtering resolver (dnsmasq, `dnsmasq-base` pinned from the runner's Ubuntu archive, as its
  own system user) forwards only names on the allow-list (scopes `all` and `linux`) to the
  runner's Azure DNS and answers NXDOMAIN for everything else, so an unlisted name never leaves
  the runner, not even as a DNS query;
- every address it returns for an allowed name goes into an nftables set, and the output chain
  drops by default: loopback, established flows, root's own traffic, the resolver's upstream
  queries, the Azure wire server and metadata endpoints, the Docker bridges and that set are
  accepted, everything else is logged and dropped;
- a NAT rule sends every DNS packet not sent by the resolver (systemd-resolved's upstream
  queries, or anything asking a public resolver directly) to the filtering resolver;
- a self-test proves an allowed name resolves and is reachable, an unlisted public name does
  not resolve, a direct query to a public resolver is filtered, and a literal unlisted address
  is unreachable.

It fails closed: if a package will not install, the configuration does not parse or the
self-test fails, the job fails; it never falls back to audit. It is installed while root is
still available and project code never gets root, so project code cannot undo it. A refused
name or dropped connection does not fail the job by itself (the job fails only if the build
does); the report lists them (hashed unless allow-listed) with counts, under "Egress (block
mode)".

The policy (`check-egress-modes.sh`, with fixtures in `test-policy.sh`) requires every Linux
concern to name its mode, and an `audit` concern to carry `egress_audit_reason`: a concern
cannot be switched back to audit without a written exception.

Kept in audit, and why:

- **Linux `e2e-visual`**: it runs inside a job container as root with the host Docker socket,
  so a host firewall cannot bind it.
- **Docker-kept jobs** (the live-proof `bastion` arm, Keel Dock `db-containers` and
  `apphost-cold-start`): Docker access is root-equivalent, so project code could remove the
  firewall; blocking there would be a claim the job cannot keep.
- **macOS**: `tcpdump` records only. A `pf` anchor with a filtering resolver is technically
  possible before `drop-root`, but macOS background services (software update, OCSP, Xcode
  services) query a long, changing tail of Apple and Akamai names (over a hundred unidentified
  hashes per run), so it stays in audit until that tail is identified.
- **Windows**: the job user is an administrator and cannot be demoted, so any firewall rule is
  removable by project code.

Residual risk in block mode: an allowed name's addresses are often shared CDN or cloud-storage
front ends (Fastly, Akamai, Azure Front Door, Azure Storage), so a client that connects to an
allowed address with another host name in TLS SNI reaches whatever else that front end serves;
a subdomain of an allowed name is forwarded to that operator's own DNS; and root processes
(the runner's platform agents) are not filtered. The allow-list keeps wildcards to
operator-owned names for this reason.

## Ref isolation: main and untrusted

The Actions cache is scoped by ref. A run on `main` reads and writes main's cache scope; a run
on another branch writes only that branch's scope, and main never reads it. Project code can
write a cache entry directly with the runner's runtime token (finding H1), so the only safe
place for unreviewed code is a ref whose cache main never reads. Hence two refs:

| Ref | Runs | Caches |
| --- | --- | --- |
| `main` | Only SHAs on `develop`, `uat` or `main` of the source repository (protected ancestry). Anything else is refused, fail-closed, after the token is revoked and before project code, with a message saying to use `untrusted`. | The only ref that may restore or save caches. |
| `untrusted` | Any SHA, typically a feature or plan branch tip. Must be main's tip or an ancestor of it (an older, previously reviewed main commit); a run from an `untrusted` that is ahead of main or has diverged from it stops before any token is minted. | Never saves a cache (every save requires `github.ref == 'refs/heads/main'`). |

### Dispatching feature-branch validation

Use `--ref untrusted`; everything else is unchanged:

```bash
sha=$(gh api repos/Moh-Bakr/Taurine/commits/<branch> -q .sha)
gh workflow run linux-validation.yml --repo Moh-Bakr/Taurine-CI --ref untrusted -f source_sha="$sha"
gh workflow run macos-validation.yml --repo Moh-Bakr/Taurine-CI --ref untrusted -f source_sha="$sha" -f rust=true
```

Protected tips (`develop`, `uat`, `main`, and the weekly run) keep dispatching from `main`.

### Keeping untrusted in sync with main (manual, by design)

`untrusted` runs with the `source-read` environment, so whoever can change it can change code
that receives the App private key. A workflow that fast-forwards it would need `contents:
write` and a bypass of untrusted's push restriction, which adds a second writer to a ref that
holds the key. The safer option is to keep the owner as the only writer and sync by hand after
each merge to main. The guard compares the run's commit with main through the compare API
(`main...<sha>`) before any token is minted: `identical` (main's tip) and `behind` (an ancestor
of main's tip) are accepted, `ahead` and `diverged` are refused. This is safe because `untrusted`
is protected by ruleset 24500573 (no deletion, no force-push, updated only by the admin role) and
the admin only ever fast-forwards it from main, so every commit it can point at was once main's
reviewed tip. A merge to main therefore no longer blocks feature-branch runs while `untrusted`
waits for its sync; a run from a behind `untrusted` still passes, prints a warning in the step
summary saying how many commits behind it is, and names the sync command. Only the admin role may
update `untrusted`, and the ruleset blocks non-fast-forward updates, so the sync is an admin
fast-forward push:

```bash
git fetch origin && git push origin origin/main:refs/heads/untrusted
gh api repos/Moh-Bakr/Taurine-CI/compare/main...untrusted -q '[.status, .ahead_by, .behind_by] | @tsv'   # identical 0 0 once synced
```

### Repository settings the owner applies (once)

These must be in place **before** the ref-isolation pull request merges; otherwise every
feature-branch validation fails (main refuses it, and `untrusted` cannot reach the secret).

1. **Protect `untrusted`.** Settings → Rules → Rulesets → New branch ruleset. Name it
   `untrusted`, enforcement Active, target branch `untrusted` (include by name). Turn on
   "Restrict deletions", "Block force pushes" and "Restrict updates", with only the Repository
   admin role in the bypass list (no GitHub Actions, no apps). Applied 2026-10-05 as ruleset
   24500573. Equivalent under Settings → Branches:
   a branch protection rule for `untrusted` with "Restrict who can push" (owner only), force
   pushes and deletions not allowed.
2. **Limit `source-read` to exactly `main` and `untrusted`.** Settings → Environments →
   `source-read` → Deployment branches and tags: **Selected branches and tags**, with exactly two
   branch rules, `main` and `untrusted` (no wildcard, no tag rule). Not "Protected branches
   only": for environments GitHub counts only classic branch protection rules as protected, not
   rulesets, and this repository protects its branches with rulesets, so that setting lets every
   branch deploy (a probe proved an unprotected scratch branch could enter `source-read`). Every
   workflow that enters `source-read` on dispatch first runs the `environment-preflight`
   composite in a job with no environment and no secret: it refuses the run unless the
   environment uses custom branch policies that are exactly `main` and `untrusted`
   (`check-universal.rb` rule 6 requires the job, `test-preflight.sh` proves the refusals).
3. **Check both:**

   ```bash
   gh api repos/Moh-Bakr/Taurine-CI/environments/source-read -q .deployment_branch_policy
                                                    # expect protected_branches: false, custom_branch_policies: true
   gh api repos/Moh-Bakr/Taurine-CI/environments/source-read/deployment-branch-policies \
     -q '.branch_policies[] | "\(.type) \(.name)"'            # expect branch main, branch untrusted
   gh api repos/Moh-Bakr/Taurine-CI/branches/untrusted -q .protected     # expect true
   gh api repos/Moh-Bakr/Taurine-CI/rules/branches/untrusted \
     -q '.[].type'                                             # expect deletion, non_fast_forward, update
   gh api repos/Moh-Bakr/Taurine-CI/rulesets -q '.[] | [.id, .name, .enforcement] | @tsv'
   ```

   With branch protection instead of a ruleset, check it with
   `gh api repos/Moh-Bakr/Taurine-CI/branches/untrusted/protection`.

## Per-platform concerns

| Workflow | Concerns |
| --- | --- |
| `linux-validation.yml` (dispatcher) and `linux-validation-concern.yml` | The 23 concerns in `ci-matrix.json`: contracts, frontend-build-budget, desktop-quality, desktop-shard-1/2, mobile-quality, taurine-cli, rust-domain, rust-db, rust-net, rust-app-1/2, rust-dbx, rust-packaging, rust-tls-openssl, e2e-critical, e2e-a11y, e2e-regression-1..4, scan-security, and the opt-in e2e-visual and scan-history |
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

The policy warns on any workflow or composite above 400 lines and fails above 800. Every file is under
400 except the `concern-report` composite, which is one cohesive reporting library and is kept whole. Files are
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
| `gitleaks_history` | Linux | Adds the opt-in `scan-history` concern: gitleaks over the full git history of `source_sha` (full clone for that concern only), two passes (the source's own `.gitleaks.toml`, and default rules with no allow-list). Report only, never enforcing; publishes counts, rule ids and commit short SHAs, never values, paths or contents |
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
  `download-artifact` or caches.
- The reviewed caches (the compiled third-party dependency cache `rust-target-cache`, the Cargo
  third-party crate source cache and Keel Dock's NuGet package cache) run **only on `main`, and
  only for a protected source SHA**. A cache entry is only as trustworthy as whoever could write
  it, and writing needs nothing more than the runner's runtime token, which project code can
  read. The cache action also unpacks with absolute paths, so a planted entry could overwrite
  files outside the folder it claims to hold. Ref isolation (above) is what makes the caches
  safe again: feature-branch SHAs run from `untrusted`, whose cache scope `main` never reads, and
  `main` refuses any SHA without protected ancestry, so only protected code can write main's
  entries. `setup-node`'s built-in package-manager cache stays off
  (`package-manager-cache: false`).
- Every restore, save and helper step of those caches carries both top-level terms,
  `github.ref == 'refs/heads/main'` and `steps.verified-source.outputs.protected-ancestor ==
  'true'`. The cache policy (`check-cache-policy.sh`) fails if either is missing or an `||`
  reopens the gate, and its fixtures prove each case is rejected. Runs from `untrusted` never
  restore or save a cache, so they download crates and compile dependencies every time.
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
