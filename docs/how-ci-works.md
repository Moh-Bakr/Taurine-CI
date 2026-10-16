# How the hosted CI works

This repository (`Moh-Bakr/Taurine-CI`) is public. It is the control plane that validates the private
Taurine source repository on free hosted runners. It contains workflows, small composite
actions and one concern table, and never any product source. Keel Dock's CI lives in `Keeldock/keeldock-ci`, not here.

## The two-repo model

| Repository | Visibility | Holds |
| --- | --- | --- |
| `Moh-Bakr/Taurine-CI` | public | Workflows, composite actions, `.github/ci-matrix.json`, the policy workflow |
| `Moh-Bakr/Taurine` | private | The product source. This is the only private source this control plane reads. Keel Dock's CI lives in `Keeldock/keeldock-ci`. |

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
   must match `^[0-9a-fA-F]{40}$`. A run from `untrusted` must also be running main's tip, or
   an ancestor of it with no `.github/` change on main since, or it stops here.
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

Every App token mint (the composite's and the weekly resolver's) is an
exact allow-list of `with:` keys and values: `client-id` or `app-id`, `private-key`, `owner`,
`repositories`, `permission-contents: read` and `skip-token-revoke: true`, nothing else. Every
call of `source-checkout` passes the reviewed App settings and its workflow's
`SOURCE_REPOSITORY_*` constants, which must be the Taurine repository's; no expression may read a
whole `secrets`, `vars` or `github` context (`check-universal.rb` rules 7 and 8).

Strings prove little about a script, so the steps that hold the token are also run as behaviour.
`test-revoke.sh` extracts the composite's verify-and-revoke step and the weekly resolver, and
runs each against stub `curl`, `git` and `date` that record
every call. On every path (success, failed checkout, identity id/owner/name mismatch, SHA
mismatch, unreachable SHA, failed revoke) each must call exactly the reviewed endpoints, in
order, ending in `DELETE /installation/token` with the source token, write only the reviewed
outputs, and fail unless every check passed; on `main` a SHA with no protected ancestry must be
refused, and the ancestry question is always asked there. `test-mutations.sh` applies each
weakening an independent review found (an early `exit 0`, a re-pointed endpoint, a dropped
`needs:`, an extra mint permission, `toJSON(secrets)`, an unconditional `keep-docker` and more)
to a copy of the tree and requires the policy to reject every one.

## Root before project code

Revoking the source token is not enough on its own. The App private key that mints it
(`SOURCE_READER_PRIVATE_KEY`) is a job secret, and the runner keeps job secrets in memory for
the whole job. A hosted Linux or macOS runner also gives every step passwordless `sudo`, and
root can read any process's memory. So, before this change, project code (an npm or cargo build
script, a test) could in principle have read the key as root (finding H2).

The fix is to take root away before project code runs, not to test whether memory can be read.
Every source-bearing job does three things, in this order, straight after the token is revoked:

1. **Privileged setup** (`.github/actions/root-setup`, plus the live-proof
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
release) still work, because they install into directories the job user owns.
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
  `xcodebuild` and `setup-node` still work afterwards.
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
- **Docker-kept jobs** (the live-proof `bastion` arm): Docker access is root-equivalent, so project code could remove the
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
| `untrusted` | Any SHA, typically a feature or plan branch tip. Must be main's tip, or an ancestor of it (an older, previously reviewed main commit) with no `.github/` change on main since; a run from an `untrusted` that is ahead of main, has diverged from it, or is behind a later `.github/` change stops before any token is minted. | Never saves a cache (every save requires `github.ref == 'refs/heads/main'`), and on Linux and Windows its jobs run with `cache-mode: read` (see [Cache grants](#cache-grants-cache-mode)). |

### Cache grants (`cache-mode`)

GitHub's job-level `cache-mode` (`read`, `write`, `write-only`, `none`) is enforced by the cache token a
runner receives: a spike (`docs/untrusted-readonly-cache.md`, section 7a-result) showed that a direct write with
the runtime token is declined under `read` and `none`, so project code cannot write a scope its job was
not granted. The policy (`check-cache-mode.rb`) therefore holds these grants:

- every dispatch workflow declares workflow-level `cache-mode: none`; a job
  that caches or calls a reusable workflow declares its own value; `write-only` and any expression are
  refused (GitHub rejects the `github` context there); a called workflow never sets it, so it inherits its
  caller's grant and cannot widen it;
- on Linux, macOS and Windows each saving caller is split into `validate-main` (`cache-mode: write`, only on
  `main`) and `validate-untrusted` (`cache-mode: read`, only on `untrusted`), so a run from `untrusted`
  can never write any cache scope. No untrusted restore exists yet: that is a later stage, behind a
  measured baseline and the owner's decision, and the "never restores" statements below stay true;
- an untrusted run first passes the `cache-audit` job (`cache-scope-audit` composite: no source, no
  environment, no secret, `actions: read`), which fails unless the `untrusted` cache scope holds no entry
  at all, and `cache-audit-after` repeats it after the run to report a planting attempt. The owner purges
  the scope once before the first run: `gh cache delete --all --ref refs/heads/untrusted -R
  Moh-Bakr/Taurine-CI` (always with `--ref`: without it the command deletes every cache, main's included);
- `actions: write` is held to `cache-prune.yml` (main-only, no source) and the weekly dispatch job.

Residuals, stated plainly. macOS joined the split when its matrix job became the reusable
`macos-validation-concern.yml` (called by `macos-validation.yml` as `validate-main` and
`validate-untrusted`, like Linux and Windows). The policy refuses any untrusted cache restore while any
workflow that can run on `untrusted` is not enforced, so no restore can precede a complete split. A failed
audit also fails the Result verdict on every platform that has the split. On Windows administrator rights cannot be dropped, so any future untrusted restore
there would extract as an administrator: it is out of scope until it has its own review. The audit is a
detector, not a lock: `cache-mode: read` is the control.

### Dispatching feature-branch validation

Protected dispatches require `dispatch_key`. It binds the exact private source SHA to the full
public control-plane SHA/ref, workflow path and complete default-normalized workflow inputs.
It also binds the SHA-256 digest of canonical JSON for the public `suite_catalog` in
`.github/ci-matrix.json` (object keys sorted recursively, array order preserved). A catalog
change therefore invalidates a key even when all dispatch inputs are unchanged. The weekly
resolver fetches the complete matrix and calculator from its exact control SHA and uses the
same digest calculation without checking out a repository.
The trusted input-validation job recomputes the key before any job can read private source; a
missing or stale key fails closed. The weekly resolver uses the same calculator and contract
fetched at its exact public `github.sha`, without checking out a repository.

Choose exactly one control-plane ref for a dispatch. For a protected private source SHA reachable
from `develop`, `uat` or `main`, calculate the key from a clean public checkout at the current
`main` tip:

```bash
set -euo pipefail
git fetch origin main
CONTROL_SHA="$(git rev-parse origin/main)"
test "$(git rev-parse HEAD)" = "${CONTROL_SHA}"
git diff --quiet "${CONTROL_SHA}" -- .github/ci-matrix.json .github/policy/dispatch-identity.rb
SOURCE_SHA='<full private commit SHA>'
# For --ref main, SOURCE_SHA must be reachable from the protected develop/uat/main branches.
DISPATCH_KEY="$(
  CI_WORKFLOW_PATH=.github/workflows/linux-validation.yml \
  CI_SOURCE_SHA="${SOURCE_SHA}" \
  CI_CONTROL_REPOSITORY=Moh-Bakr/Taurine-CI \
  CI_CONTROL_SHA="${CONTROL_SHA}" \
  CI_CONTROL_REF=refs/heads/main \
  CI_DISPATCH_CONTRACT_JSON='' \
  CI_NORMALIZED_INPUTS="$(jq -cn --arg source "${SOURCE_SHA}" '{source_sha:$source}')" \
  CI_GENERATE_ONLY=true ruby .github/policy/dispatch-identity.rb
 )"
gh workflow run linux-validation.yml --repo Moh-Bakr/Taurine-CI --ref main \
  -f "source_sha=${SOURCE_SHA}" -f "dispatch_key=${DISPATCH_KEY}"
```

For a feature or plan source SHA, use public `untrusted` instead. It accepts source SHAs that are
not on a protected private branch. This is the alternative to the protected `main` dispatch, not
an additional dispatch:

```bash
set -euo pipefail
git fetch origin untrusted
CONTROL_SHA="$(git rev-parse origin/untrusted)"
test "$(git rev-parse HEAD)" = "${CONTROL_SHA}"
git diff --quiet "${CONTROL_SHA}" -- .github/ci-matrix.json .github/policy/dispatch-identity.rb
SOURCE_SHA='<full private commit SHA>'
DISPATCH_KEY="$(
  CI_WORKFLOW_PATH=.github/workflows/linux-validation.yml \
  CI_SOURCE_SHA="${SOURCE_SHA}" \
  CI_CONTROL_REPOSITORY=Moh-Bakr/Taurine-CI \
  CI_CONTROL_SHA="${CONTROL_SHA}" \
  CI_CONTROL_REF=refs/heads/untrusted \
  CI_DISPATCH_CONTRACT_JSON='' \
  CI_NORMALIZED_INPUTS="$(jq -cn --arg source "${SOURCE_SHA}" '{source_sha:$source}')" \
  CI_GENERATE_ONLY=true ruby .github/policy/dispatch-identity.rb
 )"
gh workflow run linux-validation.yml --repo Moh-Bakr/Taurine-CI --ref untrusted \
  -f "source_sha=${SOURCE_SHA}" -f "dispatch_key=${DISPATCH_KEY}"
```

The helper fills only reviewed optional defaults from `dispatch_contracts` in
`.github/ci-matrix.json`; it rejects unknown fields, choices and live-engine selections, and
requires the version-1 public suite catalog to calculate its digest.
For another workflow, use that workflow's exact input map from the same contract, including the
source SHA. A `main` key is valid only with `CI_CONTROL_REF=refs/heads/main`; an `untrusted`
key is valid only with `CI_CONTROL_REF=refs/heads/untrusted`. If the selected public ref moves
before dispatch, fetch it again and recalculate from its exact new tip. Never reuse a key after
changing an input, source SHA or control revision.

The key check is a checkout-time preflight in the workflow that contains this contract. This
feature branch is not deployed on `main` until the coordinator integrates it; existing main-ref
dispatches do not require the key while `main` is still on its prior workflow revision.

Protected tips (`develop`, `uat`, `main`, and the weekly run) keep dispatching from `main`.

### Duplicate dispatches

The coordinator's ledger is the primary dispatch discipline, and each dispatcher's trusted
pre-source job now enforces it a second time: straight after the identity proof it lists this
workflow's queued and in-progress runs and refuses to start when another run's title carries the
same dispatch key - the key binds the exact source SHA, control-plane revision and normalized
inputs, so a title match is the same validation already waiting or running. The guard stops the
NEW run before any token is minted; it never cancels or evicts the existing one (the two runs
share nothing and the concurrency rules are unchanged), and if the run list cannot be read it
fails closed instead of dispatching blind. Completed duplicates are allowed: re-running a
finished validation is normal, and the coordinator's ledger reconciles attempts.

### Feature-suite evidence, selection and overview

`.github/ci-matrix.json` carries two reviewed contracts beside the concern table:

- **`suite_catalog`** - the reviewed candidate suites (id, feature, tier, runner, config,
  platforms, concerns) and the coverage requirements that bind each runner/config/tier/platform
  to its features and candidate suites. The catalog's canonical JSON digest is part of every
  dispatch identity, so a catalog edit invalidates outstanding dispatch keys.
- **`feature_graph`** - the derived feature-consumption graph. An edge `from -> to` selects
  `to`'s suites when `from` changes - the reversal of the private reviewed dependency model's
  `depends_on` - plus the cross-feature tier rule that every source-bearing feature selects
  `integration`, whose own consumers (the composition and CLI tiers) join every partial
  selection accordingly. The graph is a derived artifact, regenerated never hand-edited: the
  private reviewed model's generator emits it beside the suite-ownership manifest, digest-bound
  to the same catalog digest, and a cross-model fixture proves every edge's direction against
  the model; this repo's policy pins the reviewed derivation table (a graph edit that does not
  match it is an unreviewed contract change), and the graph's canonical JSON digest is part of
  every dispatch identity, so a regeneration invalidates outstanding dispatch keys.
  `select-suites.rb` computes the exact selection per
  coverage requirement from a selection request the source-side classifier produces, and fails
  closed to the complete set when the base is invalid or missing, any changed path matched no
  reviewed rule, a shared surface changed (fixtures, aliases, setup, composition roots,
  lockfiles, toolchains, CI or selector inputs), the request's catalog or graph digests do not
  match the bound identity, the mode is full, a requested feature ID does not exist in the
  reviewed catalog and graph, or a partial request names no changed feature and carries no
  broadening reason (`unknown_feature` and `selection_empty` are errors, never a silent
  reduction). A
  partial selection is feedback and never admits a merge; the graph over-approximates by
  design, and unknown edges must broaden, never narrow, a selection. Partial mode never
  reduces a dispatched round: the evidence validator requires not-selected suites to report zero
  executed cases, which holds only once a concern's runner command itself filters to the
  selected suite IDs - until that runner-side filtering exists, full remains the only
  complete mode, and wiring any reduction (enforce) is gated on the derivation fixture above.

What dispatch does wire today is the shadow review. The Linux dispatcher accepts the
classifier's request as an identity-bound `suite_selection` input (mutually exclusive with
`base_sha`: one selection mechanism per dispatch), runs `select-suites.rb` over it in its
plan job, and carries the per-group result to the bound concern workflows. Two rules keep
that plumbing honest. First, fail-closed: a request the selector rejects - malformed, an
unknown feature ID, an unreviewed review mode - dispatches the complete set, with the fixed
rejection code recorded in the run summary; a selection bug must never look like a
reduction. Second, shadow only: the complete matrix still runs, and each bound concern
reports in its own summary which suites a partial selection would have run beside the
projection it collected under the full set. Shadow rounds are how a selection earns trust
against full rounds; letting it reduce a round waits for the runner-side filtering above.

Each concern job then accounts for what actually ran. A pre-project-code step (after the token
revoke, before any dependency installation) snapshots the suite contract: the catalog digest
from this control-plane revision and the SHA-256 of the private ownership manifest at
`scripts/ci/suite-ownership.json` in the checked-out source. That manifest is generated from
the private reviewed catalog and records the canonical catalog digest it was derived from.
Staleness is enforced on the private side, where the manifest generator's check mode runs in
the private test lanes: a catalog or test-layout change that has not been regenerated into
the manifest fails those lanes, so a manifest a dispatch checks out is fresh by construction.
This control plane never sees the private catalog and cannot re-derive that comparison; it
binds the manifest found at the exact source SHA, and the recorded digest documents what the
manifest was derived from. The manifest's digest here is the canonical-JSON digest of the
derived file, a different value from the private audit's raw-byte digest of the reviewed
catalog - the two bind different files with different hashing and are never cross-compared.
After the concern ran, the trusted collector (`collect-suite-evidence.rb`) derives every count from the runner report the reviewed
concern command wrote (vitest or Playwright JSON in `RUNNER_TEMP/test-ids/`), joins each
executed case to exactly one primary suite through the manifest's reviewed patterns, and fails
closed on unowned or multiply-owned cases, report/total mismatches, a project outside the
group's scope, or anything it cannot parse. It never trusts a private script's counts. The raw
proof and the manifest stay in `RUNNER_TEMP`; only the validator's sanitized projection leaves
the runner: suite IDs, counts (discovered, owned, executed, compiled, ignored, quarantined,
environment-skipped), fixed status and error classes, digests and SHAs. Compiled targets are
evidence of compilation, never execution: a compile-only selection is `blocked`
(`compiled_only`) and cannot merge. Each concern job renders a per-feature table for its
coverage group in the run summary beside the sanitized projection, and the run-level aggregate
overview (selected versus full, executed versus compiled versus skipped) is assembled from the
coordinator's ledger with `suite-overview.rb`: GitHub provides no artifact-free transport from
matrix legs to a sibling job. The generator refuses anything that is not the validator's
reviewed shape and reports honestly when no evidence was collected. Existing concern coverage stays authoritative: the evidence pipeline
observes, it does not yet narrow what a concern executes.

### Keeping untrusted in sync with main (manual, by design)

`untrusted` runs with the `source-read` environment, so whoever can change it can change code
that receives the App private key. A workflow that fast-forwards it would need `contents:
write` and a bypass of untrusted's push restriction, which adds a second writer to a ref that
holds the key. The safer option is to keep the owner as the only writer and sync by hand after
each merge to main. The guard compares the run's commit with main through the compare API
(`main...<sha>`) before any token is minted: `identical` (main's tip) is accepted; `behind` (an
ancestor of main's tip) is accepted only while `compare <sha>...main` lists no `.github/` path
(renames out of it included), because otherwise the run would use workflows, composites or
policy that main has since superseded, perhaps for a security fix; `ahead` and `diverged` are
refused. A file list that cannot be read, or that hits the compare API's 300-file cap, is
refused too. This is safe because `untrusted`
is protected by ruleset 24500573 (no deletion, no force-push, updated only by the admin role) and
the admin only ever fast-forwards it from main, so every commit it can point at was once main's
reviewed tip. A merge to main therefore no longer blocks feature-branch runs while `untrusted`
waits for its sync while only non-`.github/` files changed; such a run passes, prints a warning
in the step summary saying how many commits behind it is, and names the sync command. Once main
changes `.github/`, sync `untrusted` before the next feature-branch dispatch. Only the admin role may
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
| `macos-validation.yml` and `macos-validation-concern.yml` | desktop-shard-1/2, desktop-quality, mobile, bundle-budget, orchestrate-skill; with `rust=true` also rust-domain, rust-db, rust-net, rust-ovpn, rust-app, rust-packaging, rust-tls-openssl |
| `windows-validation.yml` and `windows-validation-concern.yml` | The same app concerns plus contracts; Rust concerns with `rust=true`; `windows_image` selects `windows-2022` (default) or `windows-2025` |
| `android-validation.yml` | android-native (debug build for aarch64); android-rust with `rust=true` (compile-only mobile test targets, not executed) |
| `ios-validation.yml` | ios-native (unsigned simulator build); ios-rust with `rust=true` (compile-only) |
| `orchestrate-validation.yml` | dashboard, release-verification |
| `source-read.yml` | Reads an exact private SHA, a smoke test of the access path |
| `live-proofs.yml` (dispatcher) and `live-proof-arm.yml` | One arm per database engine; see [The live proofs](#the-live-proofs) |

Android uses `ubuntu-24.04` with a pinned command-line tools archive (SHA-256 verified), SDK
platform 36, build-tools 36.0.0 and NDK 27.2.12479018. iOS uses `macos-15`, the runner's Xcode
toolchain for libclang, and a pinned, checksum-verified XcodeGen archive. Both install JavaScript
dependencies through the `node-setup` composite (`npm ci --include=optional --ignore-scripts`,
then `scripts/vendor-openvpn3.sh fetch`, which verifies the vendored sources against pinned checksums).

## How the files are split

The policy warns on any workflow or composite above 400 lines and fails above 800. Every file is under
400 except the `concern-report` and `shell-artefact` composites, each one cohesive library kept whole
(`shell-artefact` installs its build-input half, `shell-config`, as its first step). Files are
split by responsibility: a workflow keeps everything that must run before project code (input
validation, the token mint, the exact-SHA checkout and the revoke) plus the job wiring, and the work
that runs after the revoke lives in composites under `.github/actions/`.

| Area | Workflow (entry point) | Composites it calls |
| --- | --- | --- |
| Shared | every protected workflow | `source-checkout` (mint, exact checkout, verify, revoke), `sanitize`, `timings`, `node-setup`, `rust-toolchain`, `vendor-fetch`, `verify-cargo-cache`, `concern-report`, `run-result` |
| Linux | `linux-validation.yml` calls `linux-validation-concern.yml`; `select-concerns.yml` plans | `linux-concern-js`, `linux-concern-e2e`, `linux-concern-rust`, `scan-concern`, `select-concerns`, `linux-test-identities`, `shell-artefact` |
| macOS | `macos-validation.yml` calls `macos-validation-concern.yml` | `macos-concern-js`, `macos-concern-rust`, `shell-artefact` |
| Windows | `windows-validation.yml` calls `windows-validation-concern.yml` | `windows-concern-rust`, `shell-artefact` |
| Android | `android-validation.yml` | `android-sdk-setup`, `mobile-report`, `shell-artefact`, `android-emulator-tests` |
| iOS | `ios-validation.yml` | `ios-project-init`, `mobile-report`, `shell-artefact`, `ios-simulator-tests` |
| Live proofs | `live-proofs.yml` calls `live-proof-arm.yml` once per arm | `live-build`, `live-run`, `live-summary`, `live-start-mpp`, `live-start-ibm`, `live-start-rocketmq`, `live-start-iris`, `live-start-pg`, `live-start-sql` |
| Policy | `validate-public-changes.yml` | the scripts under `.github/policy/` |

Two conventions apply across all of them. Private source is checked out into `src/` and the
composites run from there, so the control plane's own composites stay available after the checkout;
A step that must run whatever happens, such as the revoke, the summary and the
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

## Runs are never deduplicated or cancelled

Every source-bearing workflow gives each run its own concurrency group (it contains
`github.run_id`) and `cancel-in-progress` is false. GitHub keeps only one *pending* run per
group, so a shared per-SHA group let a later dispatch silently cancel an earlier queued run; that
is why groups are per run. Nothing cancels a run: the duplicate-dispatch guard above stops a NEW
dispatch in its pre-source job when the same identity is already queued or running; two
completed runs of one identity are allowed and reconciled by the coordinator's ledger:

```bash
gh run list -R Moh-Bakr/Taurine-CI --workflow linux-validation.yml --status queued
gh run list -R Moh-Bakr/Taurine-CI --workflow linux-validation.yml --status in_progress
```

Caches are first-writer-wins on an exact key, so concurrent runs racing on a save are harmless.
`.github/policy/check-concurrency.sh` enforces the rule, with fixtures in `test-policy.sh`: a group
without `github.run_id` or a `cancel-in-progress: true` fails the policy. The dispatchers do not
print a duplicate-run notice, because their first job holds no `actions: read` permission.

## Dispatch inputs

| Input | Where | Effect |
| --- | --- | --- |
| `source_sha` | every workflow | Exact private commit to validate |
| `profile` (`full` or `quick`) | Linux | `quick` drops `full_only` concerns (rust-app, rust-db, rust-dbx, scan-security, a11y, regression e2e) and gives PASS (partial) |
| `visual` | Linux | Adds the Playwright `e2e-visual` tier; leave off until baselines for Linux exist |
| `gitleaks_history` | Linux | Adds the opt-in `scan-history` concern: gitleaks over the full git history of `source_sha` (full clone for that concern only), two passes (the source's own `.gitleaks.toml`, and default rules with no allow-list). Report only, never enforcing; publishes counts, rule ids and commit short SHAs, never values, paths or contents |
| `base_sha` | Linux | Enables change-aware selection (a partial run) |
| `only` | Linux, macOS, Windows | Comma-separated concern names for a surgical re-run of exactly those concerns. Every other concern is reported as "not selected", so the verdict is PASS (partial) and the run never admits a merge. On Linux it is mutually exclusive with `base_sha` (refused together); an unknown name, or a Rust concern named while `rust=false` on macOS or Windows, stops the run in the plan job. A Linux opt-in concern named in `only` must also have its own input enabled (`visual`, `gitleaks_history`), or the Result fails because a required concern did not run |
| `suite_selection` | Linux | The reviewed source-side classifier's suite selection request (single-line JSON, identity-bound). The plan job computes the exact selection with `select-suites.rb` and fails closed to the complete set when the selector rejects the request; the carried selection is a shadow review - the complete set runs and each bound concern reports what a partial selection would have run. Mutually exclusive with `base_sha` and `only` |
| `selection-mode` | Internal result input | Each dispatcher supplies the reviewed full/partial decision; it is never inferred from the final job list |
| `rust` | macOS, Windows, Android, iOS | Schedules the slow Rust concerns; without it they are reported as not requested |
| `engine` | live-proofs | One engine, a comma-separated list of engines, or `all` |
| `windows_image` | Windows | `windows-2022` (default) or `windows-2025` |

## The Result verdict

Each dispatcher ends with a `Result` job using the `run-result` composite. It lists every
concern the workflow can run, reads each one's conclusion from the run's job list and writes.
The dispatcher passes an explicit selection mode: Linux is full only for `profile=full` with no
`base_sha`; macOS, Windows, Android and iOS are full only with `rust=true`; Orchestrate is full.
The policy checks these call-site rules so a missing input cannot fall back to a guessed mode.

- **PASS (full)**: the dispatcher explicitly requested full mode, every expected concern ran,
  and each succeeded. This is the only concern-verdict mode that admits a merge.
- **PASS (partial)**: the dispatcher explicitly requested partial mode and every concern that
  ran succeeded. It stays partial even if every concern in its selected plan ran successfully;
  quick profile, `base_sha`, `only`, and `rust=false` are always partial.
- **FAIL**: an expected full-mode concern or a concern selected by a partial plan did not run,
  a concern failed, the run contains duplicate or unexpected matching concern jobs, no concern
  ran, or the selection/source contract is malformed.

Partial runs (quick profile, `base_sha`, `only`, `rust=false`) never admit a merge. Admission is
always a PASS (full) on the exact 40-character source SHA: the full set of concerns, all green.

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
behind the newest 300.5.x release, for the develop, uat and main tips. That patch cadence is a
warning for develop and **fails the run** for a uat or main tip that is behind, off the 300.5
line, or still on 3.5 after OpenSSL 3.5 LTS ends (2030-04-08): the release line ships the
OpenSSL it locks. The release line fails closed: an unresolved tip, a failed root-lock fetch,
a lock without `openssl-src` or an empty crates.io answer is an error, not a pass
(`test-weekly-cadence.sh`).

## The OpenSSL door in the shells

Both shells ship the OpenSSL door (`taurine-tls-openssl`, vendored OpenSSL 3.5 LTS). The
`shell-artefact` composite holds the checks, which publish crate names, versions, byte counts
and the public OpenSSL version string only:

- **CI owns the build's argv.** Every shell build (desktop `rust-packaging`, `android-native`,
  `ios-native`, and the Android/iOS project `init`) runs `npm run --ignore-scripts tauri -- <CI
  arguments>` from the shell directory with every `TAURI_*` and `npm_config_*` variable removed,
  and never a source-chosen `--features` or `--config` (the macOS flavour `--config` is CI's
  closed set). The npm form is needed because the CLI records how it was started as the
  callback of the generated mobile build phases (started as `node <script>`, it records an
  unrunnable `node tauri`); so the shell's `tauri` script must be exactly `tauri`, with no
  `pretauri`/`posttauri` script, no `.npmrc` anywhere in the checkout and no `~/.npmrc` for the
  job user, and npm's user and global config point at empty CI-owned files (the generated
  phases inherit that environment when they call back). The CLI's provenance
  is proven first:
  `node_modules/.bin/tauri` must resolve to that `tauri.js`, and the shell's `package-lock.json`
  entries for `@tauri-apps/cli` and every installed `@tauri-apps/cli-<platform>` must be
  resolved from `https://registry.npmjs.org/` with an `integrity`. The Android bindgen
  environment the source's scripts used to set is set by CI. Tauri's own `beforeBuildCommand`
  (the frontend build) still runs from the checked config, so every refusal below runs again
  after the build.
- **Generated mobile build phases.** The Gradle Rust plugin (`gen/android/buildSrc`) and the
  Xcode "Build Rust Code" phase (`gen/apple`) call back into the CLI with a command recorded at
  `init`. A source-committed copy would hand the Rust build to source-chosen arguments, so CI
  regenerates them: it removes `gen/android/buildSrc` (and the generated `tauri.settings.gradle`)
  and all of `gen/apple` (refused if committed) before its own `init`, and after `init` the
  regenerated callback must exist and call the CLI's `tauri.js` with node, never a package
  manager script beyond that exact `npm run -- tauri` callback. For iOS the regenerated
  `project.yml` is also checked structurally: its only script phase is "Build Rust Code", it
  sets no `OTHER_LDFLAGS`, `FRAMEWORK_SEARCH_PATHS` or `LD_RUNPATH_SEARCH_PATHS`, its
  `LIBRARY_SEARCH_PATHS` are the template's, and its only dependencies are the Rust `libapp.a`
  and SDK frameworks from the template's set plus `SystemConfiguration` (no `carthage`,
  `package`, `bundle` or `target` dependency). The rest of a committed `gen/android` (app sources, manifest, the app and root
  Gradle files, `gradle.properties`) is source build logic like a `build.rs`, and can reach the
  Rust build, for example running cargo with extra `--features`. It is accepted as source build
  logic, and what it builds is judged instead: see **Built graph** below. Its Gradle
  wrapper is checked: the wrapper jar must be Gradle's published wrapper jar for the version
  `distributionUrl` names, `gradlew` and `gradlew.bat` must equal the start scripts pinned for
  that version (Gradle publishes no checksums for them, so the scripts the source committed for
  8.14.3 were pinned by sha256; any other version fails until its scripts are reviewed and
  pinned). **Upgrading Gradle**: review the new version's start scripts (as generated by that
  version's `gradle wrapper`), re-hash `gradlew` and `gradlew.bat`, and pin them in
  `shell-config` in the same change as that version's published wrapper-jar and distribution
  checksums (fetched from `services.gradle.org`); the source then commits the new wrapper, jar,
  scripts and `distributionSha256Sum` together,
  `distributionUrl` an official `https://services.gradle.org/distributions/gradle-<v>-bin.zip`,
  and `distributionSha256Sum` present and equal to Gradle's published checksum for that version
  (both pinned in `shell-config`).
- **Gate S1, door-only** (`android-rust`, `ios-rust` for the mobile graph per target, every
  built Android ABI and the iOS simulator build before and after the build, and every desktop
  `rust-packaging` before and after the build): an older source without `openssl-sys` passes
  as "absent"; otherwise every direct dependent of `openssl-sys`, `openssl`, `tokio-openssl` and
  the door must be inside the door path (`openssl`, `tokio-openssl`, `taurine-tls-openssl`,
  `taurine-db-dbx`), the door must be present and the single resolved `openssl-src` must be
  300.5.x. A resolve error fails. The gate queries the shell crate's manifest default features,
  which is exactly the built set because CI owns the argv and refuses any Tauri config that could
  change it: a shell without `src-tauri`; any Tauri config other than a lower-case `tauri*.json`
  directly in a shell's `src-tauri` (every `tauri*.toml` and `tauri*.json5`, the CLI's platform
  overlays such as `Tauri.linux.toml` included); and a config that sets `build.features`,
  `build.runner`, `bundle.externalBin`, any `files` of deb, rpm, AppImage or macOS, any
  `bundle.macOS.frameworks` (the bundler resolves even a bare name from `~/Library`, `/Library`
  or `/Network/Library/Frameworks`, never `/System`, so it always copies a framework),
  `bundle.iOS.template`, a `bundle.iOS.frameworks` entry outside `{SystemConfiguration}`, the
  installer hooks and templates (WiX `template`, `fragmentPaths` and component/feature/merge
  refs; NSIS `template` and `installerHooks`; deb and rpm maintainer scripts) and
  `bundle.windows.signCommand` (refused for now; release signing will need its own reviewed
  path later).
  `bundle.resources` (array or object form) must be data, by a content allow-list: every
  source, relative to `src-tauri`, must exist and resolve (symlinks included) inside the
  checkout; globs (`*`, `**`, dotfiles included, as Tauri expands them) and directories are
  expanded and every file checked; a pattern that matches nothing fails; and each file must be
  a PNG, JPEG, ICO or ICNS image by magic, or UTF-8 text with no control byte other than tab,
  newline, form feed and carriage return (so `../../THIRD-PARTY-NOTICES` and SVG pass, and
  archives, jar/dex, WASM and any executable fail). `pg8-measurement` still builds through `npm run tauri`;
  no door or artefact verdict reads its output.
- **Built graph**: after each shell build, the graph cargo actually compiled is judged, whatever
  features Gradle code or a build phase passed. Units are identified by identity, not by where
  their sources live: every `.fingerprint/<package>-<hash>` and `deps/<crate>-<hash>.d` of the
  artefact's profile directory (mapped through `cargo metadata --locked --all-features` package
  and target names), plus the paths in the artefact's own dep-info (relative ones resolved
  against the workspace root). `build.dep-info-basedir` in any cargo config and
  `CARGO_BUILD_DEP_INFO_BASEDIR` are refused, and so is a path package whose target sources lie
  outside its own manifest directory. A `--target` build compiles build-dependencies (`openssl-src`)
  for the host, so the host profile `<target>/<profile>/` is read too. Any `.fingerprint` or
  `deps/*.d` entry that is not a
  `<name>-<16 hex>` unit (or the unhashed `<target>.d` cargo writes) or maps to no package fails,
  and the door state sets a floor: with the door in the graph the built set must contain
  `taurine-tls-openssl`, `openssl`, `openssl-sys` and `openssl-src`, without it none of them.
  Edges come from the all-features resolve; `openssl-src` may be a (build) dependency of
  `openssl-sys` only, in the gate and here. Every built crate that depends directly
  on `openssl`, `openssl-sys` or `tokio-openssl` must be on the door path (the S1 parent rules)
  and `native-tls` must not be built. A missing or unparseable dep-info, or one without the
  shell crate, fails. Dep-info read: desktop `<target>/debug/taurine-desktop.d` (Linux, macOS,
  Windows) with `<target>/debug/deps/*.d`; Android `<target>/<triple>/debug/libtaurine_mobile_lib.d`
  per built ABI; iOS `<target>/aarch64-apple-ios-sim/release/libtaurine_mobile_lib.d`; each
  with its own `deps/*.d`. A restored compiled-dependency cache (main, protected SHAs only)
  adds its units to the set, which can only make the check stricter.
- **The shipped artefact is the judged build**: Android always requires each APK `lib/<abi>/`
  library to equal the judged `<target>/<triple>/debug/libtaurine_mobile_lib.so` after the
  NDK's `llvm-strip --strip-all` of both (a GNU build-id can be chosen at link time, so an equal
  build-id is only an extra check). That AGP's packaged copy matches after the strip is
  unproven until a hosted run confirms it; iOS requires every `libapp.a` in the project's `Externals` to equal the
  judged `libtaurine_mobile_lib.a`; desktop requires the bundled main binary (the `.deb`'s
  `usr/bin`, the `.app`'s executable) to equal `target/debug/<bin>`, or to equal it once both
  are stripped and unsigned. Windows bundles nothing, so the executable judged is the one built.
- **The fixtures in the base-policy pass**: `test-shell-artefact.sh` builds a toy workspace with
  real cargo. The base pass runs every base test with `PATH` fixed to the system directories and
  an empty `HOME`, where rustup's proxies cannot work, so the base-policy job copies the image's
  stable toolchain (`bin/` and `lib/` of its real `cargo` and `rustc`) to `/opt/taurine-ci-rust`,
  owned by root, before root is removed, and the base step passes it as `TCI_REAL_CARGO`. That
  step runs from `RUNNER_TEMP`, outside both checkouts, resolves the sysroot with the image's own
  `~/.cargo/bin/rustup run stable` (`RUSTUP_TOOLCHAIN=stable`, `RUSTUP_HOME`/`CARGO_HOME`
  unset), and refuses a sysroot outside `~/.rustup/toolchains/`, so a `rust-toolchain.toml` in the
  pull request or base tree cannot make rustup run its own `rustc` while sudo is still available.
- **What CI judges, and what it does not**: CI builds and judges the iOS **simulator release**
  artefact and the **desktop debug** artefacts (and the Android debug APK). iOS device builds,
  App Store archives, desktop release installers and any signed or store artefact are built
  outside CI and are not judged by these checks.
- **Door crates fetched afresh and compared after the build**: before each shell build, every
  cached `.crate` and every extracted `registry/src` copy of the four door crates is deleted in
  every registry directory, `cargo fetch --locked` downloads them again, and every resulting
  cached copy must hash to its `Cargo.lock` checksum (at least one per crate). After the build,
  before anything is deleted, each extracted copy cargo built from is compared file by file with
  a fresh extraction of its verified archive (`.cargo-ok` aside); any difference fails.
- **Door crates from crates.io**: `openssl-src`, `openssl-sys`, `openssl` and `tokio-openssl`
  must each have the crates.io registry `source` and a `checksum` (and no `replace`) in the root
  `Cargo.lock`, and resolve in `cargo metadata` to that source with the manifest under
  `CARGO_HOME/registry/src`. A `[patch]` path or git fork, `[replace]`, or a directory/vendored
  source replacement fails.
- **What the gate cannot see.** It is name- and graph-based: it knows `openssl-sys`, `openssl`,
  `tokio-openssl`, `taurine-tls-openssl` and `openssl-src` by name. A renamed or forked crate, a
  `build.rs` that links a library itself, or a libcrypto compiled inside another `-sys` crate is
  invisible to it; the artefact proof below is the backstop. Its `openssl-src` count reads the
  root `Cargo.lock` only, because both shells build from the root workspace (`dbx-core` and
  `dbx-mongo-shell` keep their own locks, which no shell build reads); revisit that if a shell
  ever builds from another lock.
- **No OpenSSL override**: `OPENSSL_NO_VENDOR`, `OPENSSL_DIR`, `OPENSSL_STATIC`,
  `OPENSSL_LIB_DIR` and `OPENSSL_INCLUDE_DIR` (bare or with a `<TARGET>_` prefix) make
  `openssl-sys` skip the vendored build. They are refused in the job environment and in every
  `.cargo/config.toml`/`.cargo/config` cargo can read (nested in the checkout, every parent of
  the shells up to `/`, and `CARGO_HOME`), before each build and in every gate. Names compare
  case-insensitively and config keys after TOML decoding (Python `tomllib`; an unparseable
  config or a missing `tomllib` fails). This is hygiene: the control is the artefact's
  lock-bound version proof below.
- **Door tests on the device**: the emulator (x86_64) and simulator run the door crate's library
  and integration tests through the same runner as the mobile tests, surfacing the fixed
  `door-roots:` line and, when the source has it, the ignored `public_peer` verify-full
  handshake (`door-public-peer:` line; a resolve/connect failure is classified as "public peer
  unreachable from device" and still fails). Only whole lines of the fixed shapes
  `door-roots: (Os|MozillaFallback), N anchors` and `door-public-peer: roots
  (Os|MozillaFallback), N anchors` are published, one per key; any other door line is dropped,
  reported only as `door lines dropped: yes|no`. `lockfile_policy` is excluded on the device (it
  reads the host `Cargo.lock`); the host `rust-tls-openssl` concern covers it. The aarch64
  Android door tests are built and linked compile-only.
- **Artefact linkage** (the desktop executable, plus everything in the Linux `.deb` and the macOS
  `.app`; the whole Android APK, every ABI in `lib/` and every other binary such as `assets/`;
  the whole iOS `.app`, its `Frameworks` included; on Windows, which builds no installer, every
  PE beside the executable in the target directory, the shell's own library judged like the
  executable; a PE in a subdirectory of the target directory is not scanned because nothing CI
  builds ships it: there is no installer, `externalBin` is refused and resources must be text
  or images): the shell's main binary must carry no
  dynamic `libssl`/`libcrypto` dependency (`readelf -d`, `otool -L`, `dumpbin /dependents`),
  and the distinct set of `OpenSSL X.Y.Z` strings in the binary must be empty when the door is
  not in that target's graph, and exactly `OpenSSL 3.5.M` when it is, where `3.5.M` is the
  build metadata of the single locked `openssl-src` 300.5.x. A second copy, another version
  or another patch fails. Every other shipped binary must carry no OpenSSL string and no dynamic
  `libssl`/`libcrypto`. Android judges each built ABI on its own target graph. **Residual:** the
  proof sees only copies whose version text survived linking. A library deliberately built with
  the version string stripped (and with `no-filenames`) evades it: the proof catches accidental
  OpenSSL consumers, not a deliberately disguised one.
- **Same-user tampering (residual)**: the checks call `grep`, `jq`, `cargo` and the binary
  readers through `PATH` after project code has run as the same user, and build scripts can
  write `GITHUB_ENV`/`GITHUB_PATH`, so a hostile build could shadow them. Likewise
  `CARGO_*`, `RUSTFLAGS`, a cargo `rustc-wrapper`, `linker` or link arguments cannot change the
  resolved graph but can link extra code; a `beforeBuildCommand` can edit and restore inputs.
  These are same-user residuals, backstopped by the artefact proof. The gate therefore also runs
  before each build, where no build script has run yet; the post-build artefact proof shares
  the job's trust in its own tools.
- **Scope**: the rule covers native OpenSSL. An OpenSSL compiled to WASM in the frontend, or a
  JVM/JS TLS stack, is outside it; a native BoringSSL in an Android `.so` is caught as an extra
  through its `OpenSSL 1.1.1 (compatible; BoringSSL)` text.
- **Native size budget (advisory)**: a ceiling in the source's `bundle-budget.json`
  (`<app>.native.<abi>` or `<app>.nativeBytes`) is compared when the source sets one. The
  source sets the number it is judged against, so this is evidence, not a security control.
- **Windows toolchain**: every Windows Rust concern sets `OPENSSL_SRC_PERL` to the image's
  Strawberry Perl (fails closed when it is missing) and puts NASM on the job PATH before any
  project code, because the vendored OpenSSL builds wherever taurine-app compiles. Both versions
  are printed in the summary and held to the majors the build is reviewed with: Perl 5, and NASM
  2 when present (a missing NASM is allowed and means OpenSSL builds `no-asm`).
- **Artefact size (known limitation)**: CI reports the with-door artefact sizes only (every
  shell-building concern prints the artefact's byte size and build profile); it does not measure
  the size the door adds (the with/without-door delta). The owner deferred that comparison
  (2026-10-16): the door ships with sizes reported with OpenSSL only. Measuring the delta later
  needs a second full shell build and its own reviewed opt-in dispatch input.

## The live proofs

`live-proofs.yml` runs each selected database engine's env-gated conformance suite against its real
single-node Docker server at an exact private SHA (Postgres, MySQL, SQL Server, Db2, Informix, Doris,
StarRocks, RocketMQ, IRIS, the Postgres and DBX TLS proofs, the legacy-peer DBX TLS proof, and the
bastion proof). These runs find driver defects that the offline suites cannot.

The `pgtls` arm runs the DBX provider's ordinary TLS cases and eight mTLS cases against separate
PostgreSQL services. The mTLS service requires a trusted client certificate and rejects absent,
untrusted, and mismatched client identities. Its `dbx-pg` and `legacy-tls` features apply only to
that exact target. The separate `tls-legacy` arm runs two DBX tests against TLS 1.0-only, TLS
1.1-only, and RSA-key-exchange peers; its two cases must both execute. Fixed target/filter/feature
tuples are validated before project code. Missing targets, selectors, features, incomplete case
counts, or `SKIPPED` output fail the proof. `engine=all` includes all 13 required arms; the existing
12 arms remain required.

It is split three ways:

- **The dispatcher** (`live-proofs.yml`) validates the dispatch input, holds the arm roster (one JSON
  definition per arm) and calls the arm workflow once per selected arm. It passes only the source-reader
  key, by name, and tabulates arm durations against a committed baseline.
- **The arm workflow** (`live-proof-arm.yml`, reusable and protected) runs in the `source-read`
  environment, performs the exact-SHA checkout and revoke through `source-checkout`, then builds,
  starts the server, runs the suite and publishes the summary.
- **The `live-*` composites** hold the per-engine server start-up (image digest pins, ports, readiness),
  the cargo build, the run and the summary.

The policy pins both halves of the fan-out. `test-live-roster.sh` runs the real plan step and checks
which arms it selects; `check-live-proof-fanout.rb` checks that selection is what runs. The plan job's
`arms` and `roster` outputs must come from that step, whose name, inputs and shell are fixed, and its
`if` is exactly the protected-ref condition, because `prove` needs `plan` and a skipped plan skips
every arm. The `prove` job must be exactly one arm-workflow call per selected arm, with no `include`,
`exclude`, extra axis or condition. In the arm workflow, the job and its workflow-level environment
are pinned, and the input validation, build and run steps are pinned in full and in that order: the
action or script, `if`, `continue-on-error`, `env`, `with`, shell and directory of each, so replacing
a body, swapping an action or overriding `RUNNER_TEMP` fails the check. The validation script is
pinned by SHA-256 (the recompute command is in the check). Workflow files are read as text and YAML
and refused, with the cause named, when they are missing, symlinks, too large, not UTF-8, not YAML,
ambiguous (a repeated key, an anchor or an alias) or not a mapping. Changing any of these is a
reviewed policy change that lands in two steps (see "Changing the policy").

Two residuals are known and not closed by this check. Neither makes a bypass possible that a pull
request could not already make, since a pull request controls the workflow YAML itself; each makes it
quieter, and the likely fix is the environment isolation described under "Changing the policy".

- **The select step's environment is not closed.** A plan step before `select` that writes
  `GITHUB_PATH`, or a workflow-level `BASH_ENV`, can change what `select` executes; `test-live-roster.sh`
  runs the extracted select script alone and cannot see either. The steps before `select` are
  composites whose contents this check does not read.
- **An arm can be narrowed between validation and run.** A new step between the pinned validation and
  run steps can rewrite `${RUNNER_TEMP}/live-arm.json`, for example to one suite of a multi-suite arm,
  and the arm still passes with less proved. The pinned order does not forbid a step in between, and
  the contents of the `live-build` and `live-run` composites are not read here either.

Each selection has its own concurrency group, runs are never cancelled, and only check titles and counts
are published.

## Sanitising: no artifacts, no source in logs

Source-bearing output is public, so it is treated as hostile:

- No artifacts, no source-bearing caches. Composites may not use `actions/upload-artifact`,
  `download-artifact` or caches.
- The reviewed caches (the compiled third-party dependency cache `rust-target-cache`, the Cargo
  third-party crate source cache) run **only on `main`, and
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

## Control-plane structure manifest

The ruleset "Protect CI control plane" requires the status check "Validate workflow policy"
because GitHub's `workflows` rule is Enterprise-only. That check proves each workflow is
well-formed, not that the set of workflows is unchanged, so `check-structure.rb` compares the
tree with the reviewed manifest, the frozen `CONTROL_PLANE_MANIFEST` constant in that script
(ordinary reviewed Ruby: no data file, no read-back): every workflow with its trust tier,
triggers and job ids, every local composite, and the required check's workflow, job id and name.
The two must match in both directions, so deleting or renaming a workflow, adding one with no
entry, adding or renaming a job (including the required "Validate workflow policy" job, which
would silently drop the required check), or adding a trigger fails until the constant is edited
in the same pull request, where review sees it. `pull_request_target` and `workflow_run` are
refused outright, whatever the manifest says. A tier must also agree with `workflow-lists.sh`.

### The two-step rule for a structural change

The base pass runs main's copy of `check-structure.rb`, with main's pinned manifest, against the
pull request's tree; a manifest edited inside the pull request changes nothing there. So a pull
request that changes the structure (adds, removes or renames a job, a workflow or a composite, or
changes a trigger) fails the base pass on its own, however correct its own manifest is. The change
lands in two pull requests:

1. **Precursor, to main.** It leaves the tree alone and edits the manifest so each affected entry
   lists both shapes: the new one first (the final shape) and the current one second (transitional).
   A workflow entry becomes an array of exact `{tier, triggers, jobs}` shapes (or `'absent'`); a
   composite entry becomes `['present', 'absent']` or `['absent', 'present']`. Main's policy then
   accepts the tree as it is and the new shape.
2. **The change itself.** It changes the tree and deletes the transitional alternatives in its own
   manifest, so the pull request's own copy passes with the exact final shape, and the base pass
   (main's copy from step 1) accepts the new tree through the alternative.

Alternatives are exact: a job list is spelled out, never a wildcard, a prefix or a superset, and the
manifest is refused when an entry has an unknown key, an unsorted or non-plain name, a forbidden
trigger, or (for the policy workflow) no `policy` job. The forbidden-trigger denial and the
required-check pin apply to every alternative, and a tree that matches none of them is an error, so
an alternative cannot admit more than the two shapes it lists. When the tree matches only the final
shape while alternatives remain, the run prints a warning annotation and does not fail, because the base
copy sees step 2's tree in exactly that state. The policy job runs the pull request's own copy with
`--strict`, where the same state is an error, so step 2 cannot merge with its transitional
alternatives still listed. `--strict` runs there and nowhere else: the base pass runs main's scripts
against the pull request's real tree, where step 2's tree matches only the final shape while main's
manifest still lists the transitional one, so any script it reaches that ran `--strict` on that
tree would block every step 2. `check-strict-structure.rb` therefore requires the policy job to run
`check-structure.rb --strict` as ONE dedicated step: its `run` is exactly
`ruby .github/policy/check-structure.rb --strict`, its keys are only `name`, `shell` and `run`, its
shell is exactly `bash`, and the job's `if` is exactly `${{ always() }}`, so no `exit 0`, `set +e`,
`|| true`, heredoc, uncalled function, trap, `if`, `env` or alternative shell can dodge it. It refuses
`--strict` in any other policy script except on the synthetic tree `test-structure.sh` builds for its
strict fixtures. Residual: a pull request can neuter the strict block inside its own
`check-structure.rb`, and an earlier step of the policy job (which runs the pull request's own
scripts) could export `BASH_ENV` through `GITHUB_ENV`; main's base pass cannot see either, and review
holds them.

Other checks of the same file: the check also unions the `on` and `true` keys (YAML 1.1 reads a
bare `on` as true), refuses a file with both, and refuses any duplicate mapping key. It does not
catch `if: ${{ false }}` or `continue-on-error` on the required job, which drops the check like a
rename; review, or an Enterprise-only ruleset-required workflow, is the control for that.


After a reviewed structural change, run `ruby .github/policy/check-structure.rb --print`, paste
the literal over the constant and read the diff. `test-structure.sh` holds the falsifying
fixtures and `test-mutations.sh` the mutations. This guards against accidental or unreviewed
drift; as with the rest of the policy, a pull request that edits the manifest and the tree together is caught only by review.

## Action reference check

`check-action-uses.rb` holds every `uses` to a full commit SHA (remote actions) and to the exact
reviewed list in `action-allowlist.rb` (one line per entry, so adding a reviewed local action is a
one-line change). It reads the parsed YAML, not its text: it collects `jobs.<id>.uses`,
`jobs.<id>.steps[*].uses` and a composite's `runs.steps[*].uses`, so quoted or escaped keys, flow
mappings, a value on the next line, a space before the colon and a complex key are all read as the
`uses` they are. It refuses aliases, duplicate mapping keys (`yaml-guard.rb`, shared with
`check-structure.rb`), a load error, a non-mapping job or step and a non-string value, and a textual
tripwire fails the file when more lines look like a `uses` key than the walk found.
The same walk holds containers and services to a closed shape. The runner puts a container's
`options` before its image in `docker create` (`DockerCommandManager.DockerCreate` in
`actions/runner`, and `ports` are not quoted either), so a positional token in `options` would
become the image that runs. Therefore the only keys are `image` and `options`; `options` is exact
reviewed text (`CONTAINER_OPTIONS_ALLOWLIST`), never free text; the image is a single token pinned
by `@sha256:<64 hex>`; and an expression is accepted only as the exact reviewed text in
`action-allowlist.rb` or exactly `${{ fromJSON('<one JSON literal>') }}`, where the literal obeys
the same rules and may not repeat a key (even by escape), use a case variant or add a key. Any other
expression can fall back to an unpinned image through `vars`, `env`, `inputs`, `matrix` or `needs`.
A leading `-`, an uppercase letter or a second token in an image is refused (it could read as a docker
flag or another image), `fromJSON` is accepted only as the container value itself and never as a
mapping's `image`, JSON nesting beyond 64 levels is refused, and a YAML merge key (`<<`) is refused
wherever `yaml-guard.rb` walks, because Psych and GitHub may resolve it differently.

Residual: this check sees only the references a workflow or composite itself writes. What a reviewed
remote action, a remote reusable workflow or a docker action does inside (its own nested `uses`,
images and options) is not visible to it; pinning the exact SHA, and the review that put it on the
allow-list, are the controls for that.
Run with
no arguments it walks the tree itself (the same `.yml` and `.yaml` files `check-workflows.sh`
checks) and exits non-zero when it checked no file, so a direct run never passes having checked
nothing. The tripwire fails closed, so any non-comment line holding the text `uses:` (a trailing
comment, a `run:` script, a description) counts and fails the file when the walk found fewer
references than such lines: reword the text rather than weaken the guard.
`test-action-uses.sh` carries the fixtures (the spellings a grep missed, each refused, plus the
container and no-argument cases) and mutates every guard in a copy, failing if a mutant survives.

## Changing the policy

A pull request carries its own `.github/policy/`, so on its own the policy run would let a
change weaken a check and rely on the weakening in one step. On `pull_request`,
`validate-public-changes.yml` therefore runs twice in the same required job: first the pull
request's own policy (so new fixtures run), then the base commit's: it checks out
`github.event.pull_request.base.sha`, puts that commit's `.github/policy/` in place of the pull
request's and runs every base check script against the pull request's tree. A change must pass
both. `test-mutations.sh` proves the second pass catches a pull request that quietly exempts a
file from a rule and breaks it in the same change.

So a legitimate policy change that the old policy would reject (a new reviewed mint, a new local
composite on the Action allow-list, another `keep-docker` expression, a renamed step a fixture
extracts) lands in two pull requests: first make the rule permissive or add the new rule beside
the old one, merge, then land the change that relies on it. The pull request's own copy of
`validate-public-changes.yml` is what runs, so a pull request that edits that file to drop the
base pass is caught only by review: treat any change to `validate-public-changes.yml` or
`.github/policy/` as a policy change and review it as one.

Earlier steps of that job run the pull request's own policy scripts, and any of them can append
to `GITHUB_ENV` or `GITHUB_PATH`. The base pass therefore runs each base script, Ruby and shell
alike, with an allow-listed environment (`env -i`, a fixed `PATH`, a clean `HOME`, only the
`GITHUB_*`/`RUNNER_*` variables it needs, and the token for `lint.sh` alone) and names `ruby` and
`bash` by absolute path, so a planted `RUBYOPT`, `RUBYLIB`, `BASH_ENV` or `PATH` shim cannot turn a
rejection into a pass.

The step's own shell is closed the same way. It declares `shell: /usr/bin/env -u BASH_ENV -u ENV
/bin/bash --noprofile --norc -p -eo pipefail {0}`: the absolute paths cannot be intercepted by a
`PATH` shim, no startup file is read, and privileged mode (`-p`) stops bash importing exported
functions (`BASH_FUNC_*`) and `SHELLOPTS`/`PS4`, which would otherwise run planted code in the step
shell. The script then fixes its own `PATH` before it does anything, so `rm`, `mv`, `cp`, `mkdir` and
`diff` cannot be shimmed, and it fails unless the copied base policy is identical to the base
checkout and it ran exactly as many base scripts as that checkout holds, so a pass cannot mean that
nothing ran. `test-base-policy-env.sh` runs the step as declared, over rejecting fixtures, with each
of those planted, and fails on a step that does not hold.

What the environment scrub alone could not stop is code the pull request contributes that the
base pass itself executes. Several base tests -- `test-base-policy-env.sh` and
`test-base-policy-isolation.sh` among them -- extract steps from the pull request's own copy of
`validate-public-changes.yml` and run them, as the same user, inside the base pass. So
pull-request code does run there, and it could rewrite a later base script on disk or leave a
process behind to act later. The base pass is therefore isolated further:

- **Its own job, in its own workflow.** It runs as `base-policy` in `base-policy.yml`, called by
  the entrypoint, separate from the checks in `policy`, so nothing the pull request's own policy
  scripts export there reaches it. `policy` declares `needs: [base-pass]`, the call, and fails
  unless the whole workflow succeeded. Inside it, `base-policy-result` requires the fixtures job
  to have passed on every event and the base-policy job on a pull request, so a skipped base pass
  fails.
- **No root.** Hosted runners give the job user passwordless sudo. The job runs the same
  `drop-root` composite the source-validation jobs run before project code, then the step
  asserts `sudo -n true` is refused. Without that, pull-request code run by a base test could
  write `/etc/ld.so.preload` or replace ruby.
- **Only root-owned tools.** The base scripts run with `PATH` fixed to `/usr/bin:/bin:/usr/sbin:/sbin`.
  Base tests that need node get a copy installed into `/usr/bin` before `drop-root`, because the
  runner's own node lives in `/usr/local/bin`, which hosted images leave world-writable: on the
  base `PATH`, pull-request code run by one base test could replace it for the next.
- **Pinned to the base commit.** The base checkout's `HEAD` must equal the pull request's base SHA.
  A SHA-256 manifest is built from that commit's git objects -- not from the files on disk -- held
  only in the step's memory, and re-verified before every base script and once after the last.
  A rewritten, added, removed or hidden base file fails the step. The manifest is never written to
  disk, where a base script could rewrite it to match its own edit.
- **Nothing outlives a script.** Each base script runs under a wrapper -- the pinned ruby, calling
  `prctl(PR_SET_CHILD_SUBREAPER)` through Fiddle -- that every orphaned descendant is re-parented
  to instead of init. Double-forking, `setsid` and an `exec` with a cleared environment do not take
  a process out of its reach, and a process cannot leave a subreaper's subtree on its own. When the
  script returns, the wrapper finds every remaining descendant through the `/proc` ppid chains,
  kills it, and repeats until two passes in a row find none (a pass that meets a parent missing
  from the listing rescans); any that was still running fails the script by name. The wrapper
  marks itself not dumpable, and `kernel.yama.ptrace_scope` is raised to at least 1 before
  drop-root and asserted, so nothing a script starts can attach to the wrapper or the step.
  Zombies (exited, not yet reaped) are reaped quietly, unless other threads of one still run. A
  script that kills its own wrapper fails the step through the wrapper's status. An earlier version
  looked for a marker in each process's environment; an `exec` with a new environment drops it.
- **Nothing started for later.** Before drop-root the job user is denied `cron` and `at`, the user systemd manager hosted ubuntu-24.04 runs for it is stopped, and the
  step asserts that neither accepts a job, that nothing accepts connections on the user manager's bus or private socket, and
  that no systemd user manager or message bus process (`systemd`, `(sd-pam)`, `dbus-daemon`, `dbus-broker`,
  `dbus-broker-launch`) of the job user is running outside the step's own ancestry, so nothing outside the job's process
  tree can start work for it later. The same assertions run again before every base script, because a script that
  changed any of them would otherwise be believed by the next; the step logs the unix listeners of the job user and the
  `kernel.yama.ptrace_scope` it found, here and in the root step.
- **No sshd.** Pull-request code that wrote the job user's `authorized_keys` could `ssh localhost`
  and start a process the subreaper never sees. The root step logs the state of `ssh.service` and
  `ssh.socket`, masks them (so socket activation cannot revive them), and logs it again; the step, before every script, refuses any process
  named `sshd`, `sshd-session` or `sshd-auth`, of any uid, and anything accepting connections on
  loopback port 22. The root step masks every `ssh*` and `sshd*` socket unit it finds
  (systemd 256 and later generate `sshd-unix-local.socket` and `sshd-vsock.socket`), taking the names
  from both the unit files and the loaded units because `mask` takes names, not patterns. It then
  fails unless each unit is `inactive`, `failed` or `masked` and no ssh socket or service is active
  (an `ssh@N.service` instance already running would outlive the mask of its socket), so
  `activating` and `reloading` fail too, and so does a unit that appears after the mask. Each of the
  three `systemctl` listings must exit cleanly: one that errors fails the step instead of reading as
  "no more units". Names outside `ssh*` and `sshd*`, such as a distro variant, are not enumerated;
  the per-script check for an `sshd` process and the probe of port 22 are the backstop for those.
  Separately, the process scan fails closed: it must exit cleanly and print its separator, or the
  check fails instead of reading "found nothing". `test-base-policy-root-step.sh` runs both jobs' root steps with
  stand-ins for what needs root, including a mask that leaves the service or the socket running.
  Locking `~/.ssh` was not used instead, because the job user owns its home and
  can replace the directory. A script that starts an sshd of its own is a descendant, so the
  subreaper kills it with the script.
- **Nothing left in HOME.** Every base script gets the same `HOME`, and pull-request code one base
  test runs could leave a gem in `~/.gem` or a module in `~/.node_modules` for the next to load:
  a later check's `require "json"` would run it. `HOME` is deleted and recreated empty before
  every base script, and the step's own pin builder and verifier run ruby with `--disable-gems`.
- **The pull request's tree is pinned too.** Pull-request code an earlier base test runs could
  rewrite what a later one reads -- a workflow file a test extracts steps from, say. Every path
  outside `.github/policy`, with its type, mode and SHA-256, plus `.git/config`, `.git/hooks`,
  `.git/info` (which decide what git runs) and `HEAD`, `refs`, `packed-refs` and the index (what
  git reads), is recorded before the first base script, held in
  memory, and checked before every script. It is read with ruby alone, never by running git, which
  would run whatever an edited `.git/config` told it to.
- **No loader variables.** The step shell unsets `LD_PRELOAD`, `LD_LIBRARY_PATH` and `LD_AUDIT`,
  the allow-list never forwards them, and the step asserts none reaches a base script.

`test-base-policy-isolation.sh` runs the step over fixtures for each: a mismatched checkout; a
rewritten, added, removed and hidden base file; a rewrite by the last script, which only the
final check can see; a base checkout tampered on disk; the same rewrite under poisoned ruby; a
forged manifest on disk; a forged digest function; a base script that leaves a child in its
session, the same while planting a bogus group id, one that daemonises out of it, one that leaves
its session with a cleared environment and keeps writing into the next script's `HOME`, one that
kills its own wrapper, and one that only leaves a zombie; a tracked file changed, a file added and
`.git/config` edited in the pull request's tree; planted loader variables; a json gem and a node module planted in `HOME` for a later script; and an
existing `/usr/bin/node` that is a link or not root's alone.

What this does **not** do, plainly:

- **It hardens the base pass as an honest workflow runs it. It does not defend against a pull
  request that edits the workflow.** Under `pull_request`, the pull request's own copy of these
  files defines every job -- `policy` and the call in the entrypoint; `base-policy`,
  `base-policy-fixtures` and `base-policy-result` in `base-policy.yml`. It can
  delete the pin, change `BASE_SHA` or the checkout `ref:`, add `if: false`, drop `needs`,
  replace the step outright, or empty `base-policy-fixtures` so that the tests of the step stop
  testing it, and no check that this workflow runs can stop that, because the pull request also
  controls which checks run. Until the owner
  decides on a ruleset-required workflow run from the default branch, review of every change to
  this workflow and to `.github/policy/` is the only control for it.
- **Pull-request code runs inside the base pass.** The two test scripts named above execute steps
  taken from the pull request's workflow. Everything listed here limits what that code can do; it
  does not stop it running.
- **The tree is pinned between scripts, not during one.** A script can change the tree while it
  runs and change it back before it returns; only the scripts that come after it are protected.
  The same holds for the base files.
- **Work handed to something outside the job's process tree.** `cron`, `at` and a user systemd
  manager are shut out and re-checked before every script, but any other service that starts
  processes on the job user's behalf would not be seen by the subreaper. None is known on the
  hosted image. The process check is by name from `/proc`, so a manager started under another
  name is missed; the bus and socket checks still catch one that listens where the user manager's
  does. The uid test of the process check reads the real and effective uid from
  `/proc/<pid>/status`; I could not build an input where that differs from the owner of
  `/proc/<pid>` (the directory stays owned by the process's user even when it marks itself
  non-dumpable), so it is not falsifiable by a fixture. Its filter has no container fixture either,
  because that needs a root-owned `systemd`; the hosted runner has one (PID 1), so a green run there
  is its test. The ssh port check is by connection on `127.0.0.1` and `::1`; only the first has a
  fixture, because an IPv6 loopback is not a given in a container.
- **A thread-group leader that exits while its other threads run** shows as a zombie; the wrapper
  counts it as running when more than one task remains, but no fixture can construct one without a
  compiler, so that case is reasoned, not tested. Every descendant, zombie or not, is sent SIGKILL.
- **Shared scratch space.** `/tmp` and `/dev/shm` are shared by every base script, and so are
  the ancestors of the workspace (`/home/runner` among them), where node's bare `require` looks
  for `node_modules`. Nothing in the base pass loads code from `/tmp` or `/dev/shm`; a
  `node_modules` planted above the workspace would be loaded by a later base script's `node`.
  Real `node` use in the base pass is small, and none of it requires a bare module name.
- **Reasoned, not tested.** The second quiet pass: with the unknown-parent rescan, one quiet pass
  cannot miss a live descendant, so a mutant with one pass survives the fixtures. The ptrace
  assertion and the non-dumpable wrapper are shown on the runner and, for the wrapper, by a fixture
  that only falsifies on a kernel without Yama.
- **Linux only.** The wrapper needs `prctl` and `/proc`. The fixtures that run the step say so and
  pass on macOS without exercising anything, and fail under `GITHUB_ACTIONS` if they ever land
  anywhere but Linux.
- **An existing `/usr/bin/node` is trusted if root alone can change it.** A root-owned wrapper
  script that execs a path the job user can write would pass that check. No hosted image ships
  one; the step installs its own copy where none exists.
- **`DYLD_*` forwarding cannot be observed on macOS**, which strips those names under System
  Integrity Protection; on Linux the dynamic loader ignores them.
- **The sudo assertion cannot be exercised off a runner.** It needs passwordless sudo to be present
  to prove it is gone, which a developer machine does not have.

### Where the base-pass step lives

The base-policy jobs are in `.github/workflows/base-policy.yml`, the reusable half of the public
policy gate, which `validate-public-changes.yml` calls with one job (`base-pass`). They moved out
only to keep the entrypoint under the file-size limit; what they do is unchanged. A pull request is
judged by the base commit's checks, so the checks that govern a reusable public workflow had to be
on the base first: `workflow-lists.sh` names the file, `check-dispatchers.sh` accepts it only if its
sole trigger is `workflow_call`, with no other trigger, secret, artifact, cache or OIDC grant, and
`check-actions.sh` allows the entrypoint to call it. The three tests that run the step
(`test-base-policy-env.sh`, `-isolation.sh` and `-sudo.sh`) find it through
`base-pass-workflow.sh`, in whichever of the two files holds it and only when exactly one does
(`test-base-pass-locate.sh`). `test-base-policy-result.sh` holds the rules that keep the base pass on
the required check: the guards pass only on success, and `policy` needs the call that needs both jobs.

## Accepted residual risks

These are known, reviewed and accepted; each is limited by the controls named.

- **(a) The App key is readable by project code on Windows and in Docker-kept concerns.** The
  key is a job secret held in runner memory for the whole job. Windows cannot drop administrator
  rights, and the jobs that keep Docker or root (the bastion live proof, the opt-in
  `e2e-visual` job container) leave a
  root-equivalent path, so project code there can read it. The key is rotated every 90 days
  (`docs/source-reader-key-rotation.md`), and the App is installed on the source repository
  with contents read-only, so a stolen key reads source and nothing else.
- **(b) An approved fork pull request can read main's caches.** Caches written by the base
  branch (the Cargo source and compiled-dependency caches) are readable by pull request
  runs, so a fork pull request a maintainer approves runs code that can ask the cache service
  for main's entries. Fork approval ("Require approval for all external contributors") therefore
  stays mandatory; the caches hold third-party dependencies only, and only `main` runs for a
  protected SHA write them.
- **(c) Hashed package names are a weak control.** Where dependency names are published as short
  SHA-256 prefixes, the set of public package names is small enough that a dictionary attack
  reverses them. The hash keeps names out of casual reading, not out of a determined reader.
- **(d) After the revoke, project code can tamper with later reporting steps.** Project code runs
  as the job user in the same job as the summary, proof and egress steps, so it can change what
  they report. The trust model is that source-repository writers and their dependencies are
  trusted for confidentiality: the controls stop them reaching the token, root and main's
  caches, not falsifying their own run's report. The source of truth for a result is the job
  conclusion.

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
