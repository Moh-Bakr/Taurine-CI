# Design: read-only cache restore on `untrusted` runs

Status: **design; Stage 1 is merged. Stage 2 (this pull request) adds the four reviewed read-only
untrusted restores to `linux-validation-concern.yml` (rust-db and the Linux rust-app shards), behind a caller flag
(`untrusted_readonly_cache`) that stays `false` until the dispatch-path enforcement spike of
section 7c is recorded green in this file. With the flag false no untrusted restore runs.** Implementation needs (1) an independent adversarial security review and (2) the
owner's explicit sign-off, because it changes a stated security rule (see
[section 9](#9-rules-that-change-and-the-owners-approval)).

Reviewed against `origin/main` at `fef1b8c`. Output of this document is guidance for review, not an
approval: every claim about GitHub behaviour below must be re-confirmed by the spike in
[section 7](#7-measuring-the-gain-and-proving-the-platform-claims) before anything is built.

## 1. Summary and recommendation

Today a run from the `untrusted` ref restores and saves nothing, so every feature-branch Rust
concern compiles cold (15 to 40 minutes). Protected `main` runs save two reviewed caches
(`cargo-sources-v3-*`, the verified `.crate` archives, and `cargo-target-v1-*`, the stripped
compiled third-party dependencies) and restore them.

Recommendation, in order of preference:

1. **Platform-enforced read-only (`cache-mode: read`) on every `untrusted` source-bearing job,
   plus a restore-only step for the two reviewed caches.** GitHub documents a `cache-mode` job key
   whose values are `read`, `write`, `write-only` and `none`, enforced with scoped cache tokens.
   If it behaves as documented, an `untrusted` job cannot write *any* cache entry, even by
   calling the cache service directly with the runtime token. That removes the one thing the
   current design concedes (project code can write its own ref's scope) and makes shadowing of
   main's entries impossible by construction rather than by policy. It also closes today's
   untrusted-scope churn (an untrusted run can fill the 10 GB repository quota and evict main's
   entries).
2. **Detection in depth:** a no-source audit that fails closed if the `untrusted` scope ever holds
   a cache entry (before the run, and again after it).
3. **Staged rollout:** a spike that proves the platform claims, then both caches together
   only if it passes (neither cache is "safe by re-hash", see item 4), on Linux only, one
   concern first. Every restore is conditional on the spike-verified `cache-mode: read`.
4. **If the spike cannot prove that `cache-mode: read` is enforced against direct writes, ship NO
   untrusted restore at all, sources cache included.** Without platform enforcement a
   branch-scoped entry can shadow main's (section 3.3) and the restoring run would extract an
   attacker-chosen archive. *Correction (review finding B1):* an earlier draft said the Cargo
   source cache would stay safe because each restored `.crate` is re-hashed. That is false. The
   cache action's tar extraction (`actions/toolkit` `tar.ts`: `tar -xf … -P -C $GITHUB_WORKSPACE`)
   uses absolute paths and never checks archive members against the declared `path:`. A planted
   archive can therefore write anywhere the job user can: `~/.cargo/config.toml` (a
   `rustc-wrapper`), `~/.cargo/bin`, `registry/src/**` (with `.cargo-ok`), or the checked-out
   source tree. `verify-cargo-cache` only hashes `registry/cache/*.crate`, so none of that is
   seen. The re-hash protects crate *contents* inside `registry/cache`, not the extraction.

Expected benefit is large only when a feature branch does not change `Cargo.lock` or any
`Cargo.toml` (the compiled-cache key hashes both, section 4.2). That is measured, not assumed.

## 2. How GitHub Actions cache scoping works for an `untrusted` dispatch

Sources: GitHub Docs, "Dependency caching reference" (sections *Restrictions for accessing a
cache*, *Cache key matching*, *Cache access for low-trust workflow triggers*, *Controlling cache
access with `cache-mode`*, *Usage limits and eviction policy*) and "Workflow syntax for GitHub
Actions" (`cache-mode`, `jobs.<job_id>.cache-mode`); `actions/cache` `restore` README.
*Note: these were read through a summarising fetch tool, not verified verbatim; quote-check
them against the live pages in the review.*

- **Scope is the ref.** A run can restore caches "created in either the current branch or the
  default branch (usually `main`)". A pull request can additionally restore its base branch's.
  Runs cannot restore caches of child or sibling branches. For a `workflow_dispatch` on
  `refs/heads/untrusted` the readable scopes are therefore exactly two: **`refs/heads/untrusted`
  and `refs/heads/main`** (main is the repository's default branch).
- **Lookup order.** The action tries `key`, then prefix matches, then each `restore-keys` entry,
  **in the current branch first**, and only if there is no hit "retries the same steps on the
  default branch". The documented example orders `feature` exact key, `feature` prefixes, then
  `main` exact key, `main` prefixes. So an entry in the current branch's scope **wins over main's
  for the same key**. This is the shadowing mechanism in section 3.3.
- **Writes.** A run writes to its own ref's scope. Only `push`, `workflow_dispatch`,
  `repository_dispatch`, `delete`, `registry_package`, `page_build` and `schedule` may create or
  overwrite entries in the *default branch's* scope; a `workflow_dispatch` on `untrusted` is a
  trusted trigger, so by default it **can write the `untrusted` scope** (and, absent `cache-mode`,
  nothing stops its project code doing so with the runtime token). It cannot write main's scope:
  its token is bound to its own ref. Entries are first-writer-wins per key and version within a
  scope.
- **`cache-mode`.** Workflow-level and job-level key; `read` = restore only, `write` = restore
  and save, `write-only`, `none`. Default is trigger-based (`write` for trusted triggers such as
  `workflow_dispatch`). Documented enforcement: "scoped cache tokens, so a job cannot restore or
  save caches beyond the mode it is granted"; a blocked save is a logged warning, not a failure.
  **Unverified by the docs, to be proven by the spike:** whether expressions are allowed in the
  value, how a caller's `cache-mode` interacts with a reusable workflow's, and whether step code
  calling the cache service directly is actually refused.
- **Eviction.** Entries not accessed for 7 days are removed; repository limit 10 GB by default,
  least recently accessed first.
- **`actions/cache/restore`** has no post step and never saves. Outputs: `cache-hit` (exact match
  only), `cache-primary-key`, `cache-matched-key`.

## 3. Threat model

Trust assumptions already in force (docs/how-ci-works.md, accepted risks a, b, d): the dispatcher
is the owner (only people with write access can dispatch); source-repository writers and their
dependencies are trusted for confidentiality but not to falsify their own run; project code runs
as the job user after the token is revoked and root is dropped; **project code can read the
runner's runtime token and talk to the cache service directly**; Windows keeps administrator;
every cache entry in this public repository is readable by any run of any workflow in it.

### 3.1 Poisoning: can an untrusted run write into a scope that main reads?

Required property: **no**, ever. Three independent layers:

1. *Platform:* an `untrusted` run's runtime token is bound to `refs/heads/untrusted`; it cannot
   address main's scope. (This is the existing ref-isolation premise, unchanged.)
2. *Workflow:* no `actions/cache/save` is ever reachable when `github.ref != main` (existing gate,
   kept; policy hardened in section 5).
3. *New:* `cache-mode: read` on every `untrusted` source-bearing job, so even project code with
   the token cannot write the `untrusted` scope. This is not needed for main's safety (main never
   reads `untrusted`), it is what makes section 3.3 hold.

Main's scope is still writable by *protected-ancestry project code on main* (accepted today).
This design widens who **consumes** such an entry (untrusted runs too), not who can write it.

### 3.2 Disclosure: what main's Rust caches hold, and does restoring them expose anything new?

Contents, after the existing strip-and-prove (`rust-target-cache` composite):

- `cargo-sources-v3-*`: the `.crate` archives of third-party dependencies (`registry/cache` only).
  Public crates.io code; re-hashed against the private `Cargo.lock` on restore.
- `cargo-target-v1-*`: `debug/deps`, `debug/build`, `debug/.fingerprint` of **third-party crates
  only**: `.rlib`/`.rmeta`, build-script compiled binaries and their `out/` outputs for
  third-party build scripts, fingerprints. Workspace, path and vendored crates, and every
  third-party crate depending on one, are stripped; the proof fails the save if a workspace crate
  name, a reference to the private checkout path, a symlink or an executable in `deps/` remains.
  Open questions for the reviewer: the proof's executable check is limited to `deps/`; third-party
  `build/*/build-script-build` binaries remain by design, and debug info embeds public registry
  and sysroot paths only.
- What is *inferable*: the set of third-party crates and versions of the private lockfile (entry
  names), which docs deliberately keep unpublished ("the dependency inventory of the private
  lockfile is not published"), and the key fragments (lock and manifest hashes), which `locate`
  already prints in main's public logs.

New exposure from restoring into an `untrusted` run: **none that the run could not already
obtain.** The run's code already holds the private `Cargo.lock` (it is the SHA under test) and
can read main's scope directly with the runtime token today (accepted residual risk b says the
same of an approved fork PR). The only public channel is the run's sanitised log, and egress is
audited or blocked. The design therefore requires: the restore steps print only the fixed
summary lines the composite already prints (counts and MiB, never entry names), and a
restored entry is never listed. What changes is convenience, not capability.

### 3.3 Integrity: how does the restoring run know the entry came from main?

Naively it does not. The failure mode:

- Run N (any SHA, `untrusted`) plants a `cargo-target-v1-...` entry under the exact key the next
  run will compute (the key is a pure function of runner image, toolchain, ISO week and the
  lock/manifests hashes of the SHA under test, all of which the planting code can compute).
- Run M on `untrusted` looks in its own scope first, finds the planted entry, and restores it in
  preference to main's. `cargo` never re-verifies a compiled `.rlib`, so the planted artefact
  is trusted as built; the cache action also extracts with absolute paths.
- `restore-keys` would make it worse (a newer branch-scoped prefix match beats main's exact
  key), which is why the compiled cache has none and must keep none.

Consequences are bounded: main never reads `untrusted`; run M is post-revoke, post-drop-root, same
user as project code, so extraction gains no privilege that project code of M lacked; what is lost
is the integrity of M's *result* (a tainted green) and isolation between SHAs on `untrusted`.
That is still unacceptable for a verification system, so:

- **Primary control: `cache-mode: read` (1).** With no write possible, the `untrusted` scope holds
  no new entries and every hit is main's. This is a property of the platform, not of our YAML.
- **One-off purge before enabling:** the owner deletes all existing entries of
  `refs/heads/untrusted` (`gh cache delete --all --ref refs/heads/untrusted`), because past
  untrusted runs may have written entries; an exact-key shadow could pre-exist.
- **Scope audit (fail-closed detection, independent of the platform claim):** a no-source job
  with `permissions: actions: read` (the same grant `environment-preflight` already uses) lists
  `GET /repos/{owner}/{repo}/actions/caches?ref=refs/heads/untrusted` and requires **zero
  entries of any key** (review C4: lookup prefix-matches, so a longer key can shadow a shorter
  one; filtering on a `cargo-` prefix would miss it). The scope is expected to be empty
  because nothing may write it. It runs (a) before any source-bearing job, so a polluted scope
  refuses the restore (the run proceeds cold or stops, owner's choice, default stop), and (b) in
  the result job after all concerns, so a planting attempt is reported. The audit is a
  detector, not a lock: concurrent concerns of one run, or a concurrent run, can plant between
  (a) and the restore (time-of-check to time-of-use). Hence (1) is the control and the audit is
  evidence.
- **Exact keys only on the untrusted restores, both caches.** No `restore-keys` (existing rule for
  the compiled cache, kept and mutation-tested). The Cargo source cache's `restore-keys` prefix
  stays on the *main* restore only; the untrusted source restore uses the exact key. The
  re-hash of `.crate` files is not a defence against a hostile archive (B1 above): it checks
  one directory after extraction already happened.
- **Provenance record:** the audit records, in the job summary, the id and `created_at` of the
  main-scope entry (`?ref=refs/heads/main&key=<computed key>`) so a reviewer can tie a run to
  the entry a protected run saved.
- Rejected: an HMAC or secret in the key (project code in the restoring job sees the same key,
  so it can plant under it); a published digest checked after restore (nowhere trustworthy to
  publish it without a new write path or `id-token`/attestation permissions, both forbidden by
  policy); seeding the `untrusted` scope from a protected run (that is an `untrusted`-ref save).

### 3.4 Interaction with token revocation and drop-root ordering

The restore must come **after** the source token is revoked **and after `drop-root` has run and
verified**, never before. The cache action extracts as the job user with absolute paths; before
the revoke that user's process tree could still reach the App token, and before drop-root it has
passwordless `sudo` and root-owned write paths. Note the current reviewed `PRE_DROP_USES` list in
`.github/policy/drop-root-order.rb` *permits* `actions/cache/restore` between revoke and
drop-root. For `untrusted` that must become a prohibition (section 5, P3). Existing restore steps
already sit after `drop-root` in `linux-validation-concern.yml` (restore at the Cargo-home and
target steps follows the "Remove root before project code" step); the design keeps that and makes
policy enforce it. The restore needs only the runtime token, never the App token, so it adds no
use of a credential the revoke is meant to kill. On Windows (administrator cannot be dropped,
accepted risk a) and in Docker-kept concerns the extraction runs with the same privileges as
project code, no more; Linux first for that reason.

### 3.5 Interaction with the freshness gate and the dispatch identity

- The `untrusted` freshness gate (`source-checkout`: tip of main, or an ancestor with no
  `.github/` change on main since) guarantees the workflows, composites and **cache step
  definitions that run are the reviewed `main` ones**, and that the key schema
  (`cargo-target-v1`, `cargo-sources-v3`) is the one main saves under. A stale `untrusted` with an
  older key schema simply misses. `untrusted` is admin-only and fast-forward-only, so nobody can
  add a `save` there without the owner syncing it from reviewed `main`.
- The dispatch key binds the private SHA, the control-plane SHA and ref, and the complete
  inputs. Cache keys are deliberately **not** derived from dispatch inputs, and the restore is
  not conditional on any free-text input: `concern` selects a fixed table entry, the group and
  feature label are constants in the workflow, so a dispatcher cannot steer which key is read.
- The restore gate for `untrusted` is `github.ref == 'refs/heads/untrusted'` (exact top-level
  term). It deliberately does **not** depend on `protected-ancestor`, which is false there.
  Restore on `main` keeps both existing terms.

### 3.6 Fork pull requests

Accepted risk (b): a fork pull request that a maintainer approves can read main's caches. That
depends entirely on the repository's approval policy for external contributors ("Require approval
for all external contributors" must stay on), a setting outside this design. This design does not
widen it, but it must not be read as removing it.

## 4. Mechanism

### 4.1 Jobs and steps (Linux first)

`linux-validation-concern.yml` is reached from `linux-validation.yml` through a reusable call
(`validate`). Changes, all behind owner sign-off:

1. **Caller jobs.** Because `cache-mode` is a static job key and its expression support is
   unproven, prefer two caller jobs over one expression: `validate-main` (`if: github.ref ==
   'refs/heads/main'`, `cache-mode: write`) and `validate-untrusted` (`if: github.ref ==
   'refs/heads/untrusted'`, `cache-mode: read`), calling the same reusable workflow with the same
   `with:`/`secrets:`. The result and timing jobs `needs` both (the skipped one counts as
   skipped). If the spike proves an expression such as
   `cache-mode: ${{ github.ref == 'refs/heads/main' && 'write' || 'read' }}` is accepted and
   enforced, use one job; the policy rule is the same.
   **The caller split is required for every workflow whose main runs save a cache, not Linux
   only (review C6).** On `origin/main` the macOS and Windows validation jobs serve both refs and
   save on main, so `macos-validation.yml` and `windows-validation.yml` (which calls
   `windows-validation-concern.yml`) get the same `validate-main` (`cache-mode: write`, main-gated)
   and `validate-untrusted` (`cache-mode: read`) pair as Linux, with the results and timing jobs
   depending on both. Alternatively all three use the expression form, but only if spike item 4
   proves it is accepted and enforced. Stage 1 must not merge with any workflow whose main run
   saves a cache and whose job has no main-gated `write` caller, or main's saves would be
   silently downgraded to `read` and the caches would stop refreshing. A positive fixture (below)
   proves the main save steps remain on all three operating systems.
   **Every workflow with a `workflow_dispatch` trigger** (review C3: `linux`, `macos`, `windows`,
   `android`, `ios`, `orchestrate`, `live-proofs`, `pg8-measurement`, `source-read`,
   `weekly-validation`, `cache-prune`, `scorecard`, `validate-public-changes` where it applies)
   sets workflow-level `cache-mode: none`, and every job that needs more declares its own
   explicit value (`read` for the untrusted caller, `write` only on the main-gated caller,
   `none` otherwise). No job may rely on the trigger-based default, which is `write` for
   `workflow_dispatch`. **Called (reusable) workflows such as `linux-validation-concern.yml` must
   not set `cache-mode` at all**, so they inherit the caller's grant and a called workflow can
   never widen it. This removes the untrusted write path everywhere, not just where we restore.
   `cache-prune.yml` is the one workflow that legitimately deletes caches; it needs its own
   review of what `cache-mode` and `actions: write` mean for it, and stays `main`-only.
2. **Second restore step per cache, `untrusted` only.** In the concern workflow, beside each
   existing main restore, add `Restore compiled third-party dependencies (untrusted, read-only)`
   and `Restore cached third-party crate sources (untrusted, read-only)`:
   - `uses: actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0` (the one
     already allow-listed pin; no new Action);
   - `if:` with exact top-level terms `github.ref == 'refs/heads/untrusted'` and the existing
     concern-selector parenthesised group; no `||` at top level;
   - same `path:` lines, same `key:` expression as main (`steps.cargo-target.outputs.key`,
     `cargo-sources-v3-...hashFiles(...)`), **no `restore-keys` on the compiled cache**, no
     `fail-on-cache-miss`, `lookup-only` or `enableCrossOsArchive`;
   - separate steps, not one step with `main || untrusted`, so the policy can audit each gate
     against a different rule and so the `||` ban in `cond_top_terms` is untouched.
3. **Keep the existing helpers on the restore path** with the untrusted gate added as a separate
   step each: `Strip workspace crates from the restored dependency cache` (mode `restored`) after
   the compiled restore, and `Verify restored crate archives against Cargo.lock` (already
   ungated, runs for every Rust concern). Their `cache-hit` input becomes
   `steps.<main>.outputs.cache-hit || steps.<untrusted>.outputs.cache-hit`.
4. **No save, no strip-and-prove, no completion step on `untrusted`.** Their gates stay
   `main` plus `protected-ancestor`.
5. **Audit job** `cache-scope-audit` (new composite, no source, no environment, no secret,
   `permissions: actions: read`), before `validate-untrusted` (`needs:`) and again in the result
   path (section 3.3).

### 4.2 Keys, and why the hit rate may be modest

- Compiled cache key (from `rust-target-cache` `locate`): `cargo-target-v1-<OS>-<arch>-<image>-
  <group>-<features>-rustc<ver>-<toolchain hash>-<ISO week>-lock<hash>-manifests<hash>-env<hash>`.
  `manifests` hashes **every `Cargo.toml`** plus `.cargo/config*` and toolchain files, so a
  feature branch that edits any manifest (a version bump, a new feature flag) misses and compiles
  cold, exactly as today. The ISO week rotates the key every Monday, so the first protected
  save of a week is needed before untrusted runs hit; keys are saved only by a protected main
  run of `rust-app-2`, `rust-db` or `rust-packaging` on a miss.
- Source cache key: `cargo-sources-v3-<OS>-<hash of the lock files>` with an OS-wide prefix
  fallback; the prefix fallback is safe because of the post-restore re-hash.
- Keys stay exact and unchanged, so main and `untrusted` compute the same key from the same
  inputs. A later, separately reviewed improvement could key on the resolved dependency set
  instead of all manifests to lift the hit rate; that is a different change with its own review
  and is **out of scope** here.

### 4.3 Order inside the job (enforced by policy)

The real order on `main` today (`linux-validation-concern.yml`) is: checkout and revoke,
`root-setup`, egress, **`drop-root` and its verification**, sanitisers, then the Node install
(`node-setup`, which runs `npm ci` and so runs project install scripts for non-Rust concerns),
Rust toolchain and vendored fetch, the Cargo-home locate step, **the Cargo source restore (line
~292), then the crate verification, then the completion and save steps (~325 to 341)**, then the
compiled-cache locate, restore and strip, and only then the Rust concern. Two consequences:
the restore is *not* the first thing after `drop-root`, and for any concern that also installs
Node packages, project code (install scripts) has already run as the job user before the restore
begins. That is acceptable only because of `cache-mode: read`: with no write possible, nothing
that earlier project code did can have planted the entry that this step restores. Without that
guarantee the ordering would be a problem, which is a further reason section 1 item 4 refuses
the restore. Policy enforces: no restore before `drop-root`; and the untrusted restore steps
appear in a reviewed position relative to the locate and strip steps (P3).

### 4.4 `cache-prune.yml` stays main-only (review C7)

`cache-prune.yml` deletes cache entries with `gh cache delete` under `actions: write`, a grant
that `cache-mode` does not govern (it limits restore and save, not deletion through the REST API).
**Decision: it stays `main`-only and gains no untrusted path.** Enforcement today: its only
triggers are `schedule` and `workflow_dispatch`; its single job has
`if: github.repository == 'Moh-Bakr/Taurine-CI' && github.ref == 'refs/heads/main'`, so a dispatch
from `untrusted` (or any ref) skips the job; it has no environment, no secrets, no source
checkout and runs no project code. New policy check P7 (below) makes that gate, the absence of a
source-read environment and the absence of `actions: write` on any other workflow permanent. It
also matters for this design for a second reason: it is the only legitimate way an entry leaves
`refs/heads/main`'s scope other than eviction, and the audit in section 3.3 depends on nobody
else being able to delete or rewrite scopes.

### 4.5 Door concerns are never cached

The OpenSSL door concern (`rust-tls-openssl`) is never in any compiled-dependency cache group, on any
operating system. `check-cache-groups.rb` enforces this with a positive allowlist, not a denylist: per
operating system, `CONCERNS` lists the exact concerns that may restore (locate, restore, restore-time
strip) and save (save, strip-and-prove) the compiled cache, and no compiled-cache step may select anything
else. Every compiled-cache step must carry exactly one selector made only of lower-case
`inputs.concern == 'x'` and `startsWith(inputs.concern, 'x')` terms joined by `||`; a step with no
selector (which would select every concern, the door included), another spelling of the context
(`inputs['concern']`, `inputs.CONCERN`, `startswith`), a negation or an `||` with anything else is
refused. Actions string comparison is case-insensitive, so no spelling variant is accepted. A
compiled-cache step in any workflow without an allowlist entry fails the check, so the guard does not
depend on a workflow's file name. Caching a new concern is a reviewed edit to `CONCERNS`.

The door's proof (`taurine-tls-openssl/src/policy.rs`) compares version strings, so a restored, tampered
static library that reports the locked patch would pass it, and the concern is our one independent proof
that the vendored OpenSSL is the locked build. The measured saving (about one to two minutes, off the
critical path) does not justify weakening that. It always builds OpenSSL from source. The crate-sources
cache is a different cache: it holds only lockfile-verified crate archives (including `openssl-src`), never
the compiled door.

### 4.6 The rust-app shards, and compiled OpenSSL never restored untrusted

The untrusted restores cover `rust-db` and the three Linux `rust-app-K` shards (the DuckDB-heavy concern),
through one reviewed concern term, `(inputs.concern == 'rust-db' || startsWith(inputs.concern, 'rust-app-'))`,
pinned as a whole conjunct by `check-cache-mode.rb`, `check-cache-groups.rb` and `drop-root-order.rb`. It never
names `rust-packaging` (cached on main, not restored untrusted), the door concern or any wider prefix. The key is
the very key main's protected save wrote: every shard computes the same `rust-app` group key with the `locate`
step (same OS, image, `rust-app` group, `test-default+check-openvpn` feature label, rustc, week, lock, manifests
and environment hashes), and `rust-app-2` alone saves it on main, so an untrusted shard restores an exact hit
whenever the source has not changed `Cargo.lock`, a `Cargo.toml` or a cargo config.

At the time of writing the rust-app build graph holds no OpenSSL (`cargo tree -p taurine-app -p taurine-desktop
-p taurine-mobile -i openssl-sys` finds no package; the door is reachable only behind `taurine-db-dbx`'s
`legacy-tls` feature, which no rust-app package enables). That is a fact about today's manifests, not a guarantee, and
`rust-db` already builds `taurine-db-dbx/legacy-tls` in its tests, so its saved entry can hold `openssl-sys` and
`openssl-src` output. The untrusted restore therefore never relies on the entry being clean: the restore-time strip
that follows every untrusted compiled restore passes `deny-door: 'true'` to the `rust-target-cache` composite, which
also classifies the OpenSSL door crates (`taurine-tls-openssl`, `openssl`, `openssl-sys`, `openssl-src`,
`openssl-macros`, `tokio-openssl`, `postgres-openssl`, `native-tls` and the banned `aws-lc-*` crates) as strip roots,
removes them and every crate built on one, and fails the step if any entry named for one remains. The main-scope
restore is unchanged (it keeps what main saved). `drop-root-order.rb` and `check-cache-mode.rb` refuse an untrusted
compiled restore whose strip is missing, moved, not directly after the restore, or without `deny-door: 'true'`, and
the whole composite is pinned by content hash.

## 5. Policy changes (so a later edit cannot silently add `save` to `untrusted`)

All in `.github/policy/`. Per "Changing the policy" in `docs/how-ci-works.md` these land in two
pull requests: first the permissive-and-stricter-beside-it rules, then the workflow change that
relies on them (the base-commit pass would otherwise reject the workflow change).

- **P1 `check-cache-policy.sh`: gates by kind.** Add `cache_gated_untrusted_restore()` requiring
  exact top-level `github.ref == 'refs/heads/untrusted'`. Kinds `save`, `completion`,
  `strip-and-prove` (mode `save`) must satisfy `cache_gated_to_protected_main` and **must not
  contain the string `untrusted` anywhere in their `if:`**. Kind `restore` and mode `restored`
  must satisfy exactly one of the two gates (not both, not neither, no `||`). Reject any cache
  step with no `if:` (existing fixture `cargo source restore with no condition` extends to the
  compiled cache).
- **P1b, fail closed (review of the policy half).** The untrusted restore gate relaxes the cache
  policy, and what makes it safe is enforced only for the workflows in `ENFORCED_WORKFLOWS`, so a
  cache step gated to the untrusted ref is accepted only when its workflow, and every workflow that
  calls it, is already enforced (always-on rule in `check-cache-mode.rb`); otherwise a job with no
  `cache-mode` keeps the default write grant and its untrusted restore could be shadowed. Cache uses
  are classified structurally (save, restore, and the plain `actions/cache`, looking through local
  composites), and duplicate or disguised `cache-mode` keys are refused.
- **P2 `cache-mode` rules, over EVERY workflow file with a `workflow_dispatch` trigger** (not only
  the source-bearing ones; `cache-prune`, `scorecard` and `weekly-validation` included).
  (a) Workflow-level `cache-mode: none` is required. (b) Every job declares an explicit
  `cache-mode`, and its value is one of `read`, `none`, or `write` on a job whose `if:` has the
  exact top-level term `github.ref == 'refs/heads/main'`. (c) `write-only`, a workflow-level
  `write` or `read`, and any expression other than a reviewed one are rejected. (d) **A called
  workflow (`on: workflow_call`, e.g. `linux-validation-concern.yml`) must not contain
  `cache-mode` anywhere**, so it inherits the caller's grant. (e) Every job that calls a reusable
  workflow carries an explicit `cache-mode`. (f) Two-deep reusable nesting (a called workflow that itself calls a local reusable workflow, A
  to B to C) is unsupported and fails closed, because the cache uses of C would escape the caller
  classification. `check-actions.sh` needs no new Action pin (the restore pin is already allowed).
- **P3 ordering (`drop-root-order.rb` or a new `cache-order.rb`).** Remove `cache/restore` from
  `PRE_DROP_USES`; require every `actions/cache/restore` step to follow the `drop-root` step in
  its job; require no `actions/cache/*` step between revoke and drop-root.
- **P4 audit permissions.** The permission allow-list gains exactly `actions: read` for the two
  audit jobs and nowhere else on a source-bearing job; the audit composite's `GITHUB_TOKEN`
  reads only the caches listing (a stub-`curl` behaviour test in the style of `test-revoke.sh`:
  correct endpoint and `ref`, fails closed on a non-empty list, on an API error and on unparsable
  output).
- **P5 documentation consistency.** A check that `docs/how-ci-works.md` no longer says
  "untrusted never restores" once the rule changes, to stop the doc and the policy drifting
  (a grep-level check, as `check-repository.sh` already does for other claims).
- **P7 `actions: write` and `cache-prune`.** `actions: write` (or `write-all`) may appear only in
  `cache-prune.yml` (the prune job: exact top-level terms `github.repository ==
  'Moh-Bakr/Taurine-CI'` and `github.ref == 'refs/heads/main'`, no `environment:`, no local
  composite, no secret) and in the weekly resolver's main-gated dispatch job
  (`weekly-validation.yml`, which dispatches the protected validations). *Correction to an earlier
  draft, which named `cache-prune.yml` alone: the weekly dispatch job legitimately needs it.* Any
  other workflow gaining `actions: write` fails, because it can delete cache entries, which
  `cache-mode` does not govern.
- **P8 lint support for `cache-mode` (prerequisite, found while building the spike).** The
  pinned `actionlint` 1.7.12 (`.github/tool-pins.json`, `.github/policy/lint.sh`) rejects
  `cache-mode` as an unknown job key (`unexpected key "cache-mode" for "job" section`), so every
  workflow carrying it would fail `lint.sh`. Policy PR 1 must therefore either move to an
  actionlint release that knows the key (new version, SHA-256 and `tool-pins.json` entry changed
  together, reviewed by a person, as the pins file requires) or add an explicit, narrowly scoped
  ignore for exactly that message, with a fixture proving any other unknown key is still
  rejected. An ignore must never be a blanket suppression of `syntax-check`.
- **P6 composite rule.** Composites still may not touch caches (`lib.sh` rule at line 34 stays);
  the audit composite uses `curl`, not `actions/cache`.

### Fixtures (`test-policy.sh`, `cache_expect_fail` style; each must fail with its own message)

1. untrusted restore with no `github.ref == 'refs/heads/untrusted'` term;
2. untrusted gate re-opened with `|| true`;
3. untrusted gate inside an always-true alternative (`(… || true) && …`) and negated (`!(…)`);
4. untrusted restore with `restore-keys` on the compiled cache;
5. untrusted restore with `fail-on-cache-miss`, `lookup-only` or `enableCrossOsArchive`;
6. a `save` step whose `if:` contains `untrusted`, or has the untrusted gate instead of main;
7. a `save` step with no `if:`;
8. a strip-and-prove or completion step with the untrusted gate;
9. a restore with both gates, and with neither;
10. a path line outside the reviewed three (extends the existing one to the untrusted step);
11. `cache-mode: write` / `write-only` on a job not gated to main; workflow-level `write` or a
    missing workflow-level `none`; a job with no explicit `cache-mode`; a missing `cache-mode`
    on a job that calls a reusable workflow; `cache-mode` present inside a `workflow_call`
    workflow; `cache-mode: read` replaced by an unreviewed expression; each repeated for
    `cache-prune.yml`, `scorecard.yml` and `weekly-validation.yml`;
12. a restore step placed before the `drop-root` step, and between revoke and drop-root;
13. the audit job granted more than `actions: read`, or running with a source environment;
14. positive fixtures: the reviewed tree passes with the untrusted restore present, **and the main
    save steps (`actions/cache/save`, main-gated, `cache-mode: write` caller) are present and
    accepted for Linux, macOS and Windows** (review C6), with a mutation that removes the
    main-gated `write` caller from each of the three and must be rejected;
15. `cache-prune.yml` with the `github.ref == 'refs/heads/main'` term removed or inside `||`;
    with `environment: source-read` added; with `actions: write` added to another workflow
    (scorecard, weekly, a validation workflow); with a composite that touches source (review C7).

### Mutations (`test-mutations.sh`: apply to a copy of the tree, policy must reject every one)

1. change the untrusted restore to `actions/cache/save`;
2. add a `save` step guarded by `github.ref == 'refs/heads/untrusted'`;
3. drop `cache-mode: read` from `validate-untrusted`;
4. flip `validate-untrusted` to `cache-mode: write`;
5. move the untrusted restore above the `drop-root` call;
6. add `restore-keys: cargo-target-` to the untrusted compiled restore;
7. weaken the main save gate by removing `github.ref == 'refs/heads/main'` while leaving the
   untrusted restore in place (the *combined* mutation the base-commit pass exists for);
8. swap the audit's `ref=refs/heads/untrusted` for `refs/heads/main` (a behaviour mutation).

## 6. Rollout stages (each needs review before the next)

- **Stage 0 (no repository change): platform spike**, section 7.
- **Stage 1:** policy PR 1 (rules and fixtures, permissive beside the old), then workflow PR 2:
  explicit `cache-mode` everywhere (a change that is useful on its own, since it closes the
  untrusted write path even with no restore) and the audit.
- **Stage 2:** untrusted restore of both caches, on one concern (`rust-db`, own group, saves
  itself on main), only if the spike passed; measurement gate, then the other Linux Rust
  concerns. There is no sources-only stage: the source cache is not safe without enforcement.
- **Precondition for Stage 2 (found in review of the workflow half): the macOS split comes first. Done:
  `macos-validation.yml` now calls the reusable `macos-validation-concern.yml` through the same
  validate-main / validate-untrusted pair, and is in `ENFORCED_WORKFLOWS`.**
  Before the split, an inline macOS job would have kept the default write grant on `untrusted`; with
  it, macOS is enforced like Linux and Windows, so a concurrent macOS job can no longer plant a
  shadow entry between Linux's before-audit and its restore. The policy keeps two rules for this
  (both in `check-cache-mode.rb`): rule M refuses any untrusted-gated cache step while a workflow that
  can run on the untrusted ref is outside `ENFORCED_WORKFLOWS` (nothing today), and rule N, the
  standing refusal, refuses every cache restore that is not main-only, whether it is gated to the
  untrusted ref or to neither ref, because untrusted restores await the owner's Stage 2 decision. The
  audits also reach
  the verdict: the Result job needs both and passes `run-result` a blocking count, so a failed audit
  can never print PASS.
- **Stage 3 (separate decision):** macOS, then Windows (administrator cannot be dropped;
  stricter review).

**Stage 1 sequencing, as found while implementing it.** Three facts shape the two pull requests:
(1) the base-commit policy pass runs the *base* `lint.sh` against the pull request's tree, and
actionlint 1.7.12 (the latest release) rejects `cache-mode`, so the lint ignore must merge before
any workflow carries the key; (2) the staged rules (workflow-level `none`, explicit job values, the
caller split) are inert until a workflow name is added to `ENFORCED_WORKFLOWS` in `.github/policy/check-cache-mode.rb`,
which the workflow pull request does in the same change as its edits; (3) `macos-validation.yml`
runs its matrix `validate` job inline and saves caches in it, so the caller split cannot be a
second `uses:` job there: that job must first become a reusable workflow
(`macos-validation-concern.yml`, like Windows and Linux), a refactor large enough to be its own
reviewed change. Until the macOS split exists the policy refuses an untrusted restore on macOS
(no `cache-mode: read` half to carry it), and macOS `untrusted` runs keep today's default grant.

Kill switch: revert the second restore steps; no other state to undo (the audit and `cache-mode`
are inert extras).

## 7. Measuring the gain and proving the platform claims

### 7a. Spike before any build (owner's go-ahead needed for each dispatch)

A scratch workflow with **no secrets, no environment and no private source**, as in the earlier
drop-root feasibility probe, run from a throwaway branch and removed afterwards, must show, on
`ubuntu-24.04`:

1. a job with `cache-mode: read` restores an existing default-branch entry (a harmless seeded
   entry, not a real cache) and the restore reports a hit;
2. the same job calling the cache service **directly with the runtime token** to create an entry
   is refused (not merely the `save` action warning). This is the claim everything rests on.
   *Test construction (review C5):* `ACTIONS_RUNTIME_TOKEN` is not present in `run:` steps, so a
   shell `curl` test would pass vacuously. The attempt must run from a JavaScript Action or
   `actions/github-script` step (where the runtime token is exposed), call the cache service's
   entry-reservation endpoint, and the probe must first show it *can* read the token and *can*
   write in a `write` job (item 3), otherwise "refused" proves nothing. Record the value of
   `ACTIONS_CACHE_MODE` (or whatever variable the runner exposes for the granted mode) in each
   job, and the exact response of the refused call;
3. the same direct write succeeds with `cache-mode: write` (so the test can fail) and in a job
   with no key on a `workflow_dispatch` (documenting today's default);
4. whether an expression in `cache-mode` is accepted, and how a caller job's value interacts
   with a reusable workflow that sets its own;
5. an entry written from the throwaway branch under the same key as the seeded main entry
   **shadows** it on the next run of that branch (confirms 2 and the lookup order, and shows the
   attack the control prevents).

If (2) fails, section 1 item 4 applies. Record results in the review, not in the public repository.

### 7a-result. Spike outcome (run 2026-10-15, branch `cache-mode-spike`, since deleted)

Trigger `push` on a non-default ref (trusted, like `workflow_dispatch`); no secret, no source.
Final runs: `38746264008` (verdicts), `38746489504` (shadowing), `38746690385` (main visibility).

- A `run:` step has no `ACTIONS_RUNTIME_TOKEN`; the JavaScript step has it. `ACTIONS_CACHE_MODE`
  is exposed and equals the granted mode (`write`, `read`, `none`; a job with no key got `write`).
- The runtime token's `ac` claim carries the grant: `write` is `{own ref: 3, main: 1}`, `read` is
  `{own ref: 1, main: 1}`, `none` has no `ac` claim at all. Enforcement is in the token.
- **Direct reservation (`CreateCacheEntry`):** `write` and the no-key default: HTTP 200 `ok=true`.
  `read` and `none`: HTTP 200 `ok=false`, no code or message. That is not the strict
  401/403/`permission_denied` shape, so it was classed `declined`, and was shown to be a real
  refusal by two corroborations: the same keys were then reservable under `write`
  (`recheck-job`, so not a duplicate-key result), and the official actions report
  `cache write denied: token has no writable scopes` (save under `read`) and
  `cache read denied: token has no readable scopes` (restore under `none`, HTTP 403). The save
  action under `read` created nothing.
- Own-scope restore under `read` works; a restore under `none` misses with a 403.
- **Main's real entry is restorable under `read`** (exact public key and the same path string
  main uses; a different path string changes the cache version and misses, which is why an
  earlier probe missed).
- **Shadowing confirmed:** an entry written in the branch scope under main's exact key and path
  was the one restored, not main's. The attack in section 3.3 is real; `cache-mode: read` is what
  prevents it, and the post-purge audit is its detector.
- **Item 4a, expressions: rejected.** `cache-mode: ${{ github.ref == ... }}` fails workflow
  validation (`Unrecognized named-value: 'github'`). The caller split of section 4.1 is therefore
  mandatory, not optional.
- **Item 4b, reusable workflows:** a called job that requests `write` under a `read` caller is
  rejected at startup (`The nested job ... is requesting 'write', but is only allowed 'read'`),
  so a called workflow cannot widen its caller (this supports P2(d)); a called job with no key
  inherits `read` and is declined.
- Residual wording to keep honest: the cache service's refusal of a direct write under `read` is
  an `ok=false` answer plus a token with no write scope, not an HTTP error code, so the audit
  and the policy must not depend on the response shape.

### 7c. Stage 2 enforcement spike (dispatch path, the real shape)

Section 7a-result proved the platform claims on a `push` trigger with a flat job. Stage 2 relies on the
shape it will actually have, which has not been proved: a `workflow_dispatch` run, a **matrix** of caller
jobs with `permissions: contents: read` and `cache-mode: read` that call a **reusable workflow** whose
job enters an **environment** and receives a **passed secret**, the cache token reachable by **hostile
code that ran earlier in the job** (through `LD_PRELOAD` set in `GITHUB_ENV`), and both cache service
protocols (the legacy v1 REST service and the v2 Twirp service). Until the result is recorded, the Stage 2
flag stays `false`, and the policy refuses `true` unless the record is already merged on the base (see the
gate below).

Amendment from the spike-2 result: v1: service retired, not applicable. The legacy v1 REST cache service is
no longer served, so the v1 clauses of the protocol list above and of green condition 2 below are not
applicable; the v2 Twirp service is the only protocol the probes can and must exercise. This amends the
protocol list only. It is not the record line of the gate below and does not change the flag, which stays
`false`.

Why the production restores cannot all come first. The two sources restores (and their verifiers) now run
directly after the shared composites and the suite-contract step, before the toolchain, the Node install
and the vendored-source fetch. The compiled-dependency restore cannot: its key contains `rustc -vV`, the
lockfile and manifest hashes and the cargo environment, so the locate step needs the installed toolchain.
The policy therefore allows exactly these steps ahead of an untrusted restore: the shared composites,
`rust-toolchain`, the `rust-target-cache` locate and restored modes, the verifiers, other restores, and the
`suite-contract` and Cargo-home steps (control-plane scripts that read the source as data; the policy pins
their whole bodies, shell, working directory and environment, so an id alone admits nothing). The vendored
fetch (`scripts/vendor-openvpn3.sh`, a source script) and the Node install (`npm ci`) run after every
restore. `rust-toolchain` accepts a source `rust-toolchain.toml` or `rust-toolchain` only when every line is a
plain form (the `[toolchain]` header, `channel` and `profile` strings, `components` and `targets` string
arrays, comments; or, for the legacy file, one channel name). Any other key or spelling, `path` quoted,
dotted or in an inline table included, is refused, so `rustc` cannot be a source-controlled binary when
locate runs it. Only the files in the checkout root are read, which is where rustup resolves from. Two consequences are accepted and recorded: the sources key now hashes the
lock files before the vendored fetch (a fetched vendored crate that ships its own Cargo.lock is no longer
in the key, and its archives are re-downloaded because the re-hash does not find them in a lock), and the
key schema is unchanged.

Not pinned, by decision: the composites in the pre-restore set (`sanitize`, `concern-report`,
`shell-artefact`, `rust-toolchain`, `rust-target-cache`, `verify-cargo-cache`; `drop-root-order.rb`,
`PRE_RESTORE_COMPOSITES`) are admitted by name only, and their `action.yml` content is not pinned
(pinning a hash of each would break on every unrelated edit and on the sibling cache PRs). Any change to
one of them must therefore be reviewed for source-controlled execution before the untrusted restore:
none may run a project script, read a source file as code, or honour an environment value the source can
set. This is a review duty, not a mechanical guard.

Scratch workflow, **no private source**, on a throwaway branch `cache-mode-spike-2` (never merged,
deleted afterwards), two files. It needs a throwaway repository secret and environment, both removed
afterwards. Pin `actions/github-script` to the SHA in `.github/policy/action-allowlist.rb`.

`.github/workflows/spike2.yml`

```yaml
name: cache-mode spike 2
on:
  workflow_dispatch:
    inputs:
      halves:
        description: both (write twin, then read half) or read-only
        required: true
        default: both
        type: choice
        options: [both, read-only]
permissions: {}
cache-mode: none
jobs:
  plan:
    runs-on: ubuntu-24.04
    cache-mode: none
    outputs:
      matrix: ${{ steps.m.outputs.matrix }}
    steps:
      - id: m
        run: echo 'matrix={"include":[{"concern":"a"},{"concern":"b"}]}' >> "${GITHUB_OUTPUT}"
  write-twin:
    if: ${{ inputs.halves == 'both' }}
    needs: plan
    permissions:
      contents: read
    cache-mode: write
    strategy:
      fail-fast: false
      matrix: ${{ fromJSON(needs.plan.outputs.matrix) }}
    uses: ./.github/workflows/spike2-called.yml
    secrets:
      DUMMY: ${{ secrets.SPIKE_DUMMY }}
    with:
      mode: write
      concern: ${{ matrix.concern }}
  read-half:
    if: ${{ !failure() && !cancelled() }}
    needs: [plan, write-twin]
    permissions:
      contents: read
    cache-mode: read
    strategy:
      fail-fast: false
      matrix: ${{ fromJSON(needs.plan.outputs.matrix) }}
    uses: ./.github/workflows/spike2-called.yml
    secrets:
      DUMMY: ${{ secrets.SPIKE_DUMMY }}
    with:
      mode: read
      concern: ${{ matrix.concern }}
```

`.github/workflows/spike2-called.yml`

```yaml
name: cache-mode spike 2 called
on:
  workflow_call:
    inputs:
      mode: { required: true, type: string }
      concern: { required: true, type: string }
    secrets:
      DUMMY: { required: false }
permissions: {}
jobs:
  probe:
    environment: spike-env
    runs-on: ubuntu-24.04
    name: probe ${{ inputs.mode }} ${{ inputs.concern }}
    steps:
      # Hostile code that runs BEFORE the restore: a preloaded library that copies the cache token out of
      # any process that has it (the node process of every later action) into a file, set through the
      # environment file exactly as source-controlled code could.
      - name: Hostile pre-restore step (LD_PRELOAD through GITHUB_ENV)
        run: |
          set -euo pipefail
          mkdir -p "${RUNNER_TEMP}/hostile"
          cat > "${RUNNER_TEMP}/hostile/h.c" <<'EOF'
          #include <stdio.h>
          #include <stdlib.h>
          #include <string.h>
          __attribute__((constructor)) static void h(void) {
            const char *t = getenv("ACTIONS_RUNTIME_TOKEN");
            if (!t || !*t) return;
            const char *dir = getenv("HOSTILE_DIR");
            if (!dir) return;
            char path[512]; snprintf(path, sizeof path, "%s/stolen.txt", dir);
            FILE *f = fopen(path, "w"); if (!f) return;
            fprintf(f, "%s\n%s\n%s\n", t, getenv("ACTIONS_RESULTS_URL") ? getenv("ACTIONS_RESULTS_URL") : "", getenv("ACTIONS_CACHE_URL") ? getenv("ACTIONS_CACHE_URL") : "");
            fclose(f);
          }
          EOF
          gcc -shared -fPIC -o "${RUNNER_TEMP}/hostile/h.so" "${RUNNER_TEMP}/hostile/h.c"
          { echo "HOSTILE_DIR=${RUNNER_TEMP}/hostile"; echo "LD_PRELOAD=${RUNNER_TEMP}/hostile/h.so"; } >> "${GITHUB_ENV}"
          echo "DUMMY secret present: ${{ secrets.DUMMY != '' }}"
      - name: Seed a harmless file
        run: mkdir -p "${RUNNER_TEMP}/seed" && echo spike > "${RUNNER_TEMP}/seed/f"
      - name: Restore the seeded entry (must hit in run 2 of the branch that wrote it)
        id: r
        uses: actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0
        with:
          path: ${{ runner.temp }}/seed
          key: spike2-seed-${{ github.ref_name }}-${{ inputs.concern }}
      - name: Probe both cache protocols with the runtime token (and the stolen copy)
        uses: actions/github-script@<the allow-listed pin>
        with:
          script: |
            const fs = require('fs');
            const own = process.env.ACTIONS_RUNTIME_TOKEN;
            let stolen = '';
            try { stolen = fs.readFileSync(`${process.env.RUNNER_TEMP}/hostile/stolen.txt`, 'utf8').split('\n')[0]; } catch (e) {}
            core.info(`probe mode=${{ inputs.mode }} concern=${{ inputs.concern }} ACTIONS_CACHE_MODE=${process.env.ACTIONS_CACHE_MODE} own-token=${own ? 'present' : 'ABSENT'} stolen-token=${stolen ? 'captured' : 'NOT captured'}`);
            core.info(`ac claim=${JSON.stringify(JSON.parse(Buffer.from(own.split('.')[1], 'base64url').toString()).ac)}`);
            for (const [label, token] of [['own', own], ['stolen', stolen]]) {
              if (!token) continue;
              const key = `spike2-direct-${{ inputs.mode }}-${{ inputs.concern }}-${label}-${Date.now()}`;
              const v2 = await fetch(`${process.env.ACTIONS_RESULTS_URL}twirp/github.actions.results.api.v1.CacheService/CreateCacheEntry`, { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` }, body: JSON.stringify({ key, version: 'v1' }) });
              core.info(`v2 ${label} reservation http=${v2.status} body=${await v2.text()}`);
              const v1 = await fetch(`${process.env.ACTIONS_CACHE_URL}_apis/artifactcache/caches`, { method: 'POST', headers: { 'Content-Type': 'application/json', Accept: 'application/json;api-version=6.0-preview.1', Authorization: `Bearer ${token}` }, body: JSON.stringify({ key: key + '-v1', version: 'v1' }) });
              core.info(`v1 ${label} reservation http=${v1.status} body=${await v1.text()}`);
            }
      - name: Save the seed (write half only, on a miss)
        if: ${{ inputs.mode == 'write' && steps.r.outputs.cache-hit != 'true' }}
        uses: actions/cache/save@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0
        with:
          path: ${{ runner.temp }}/seed
          key: spike2-seed-${{ github.ref_name }}-${{ inputs.concern }}
      - name: Attempt a save under the granted mode (must create nothing under read)
        uses: actions/cache/save@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0
        with:
          path: ${{ runner.temp }}/seed
          key: spike2-save-attempt-${{ inputs.mode }}-${{ inputs.concern }}-${{ github.run_id }}-${{ github.run_attempt }}
```

Setup, run and clean up (the coordinator runs these; the lane never dispatches):

```
R=Moh-Bakr/Taurine-CI
# 0. check https://www.githubstatus.com/api/v2/incidents/unresolved.json first
git switch -c cache-mode-spike-2 origin/main
# add the two files above, commit, then:
git push origin cache-mode-spike-2
git push origin cache-mode-spike-2:cache-mode-spike-2b          # a second ref, same files
gh secret set SPIKE_DUMMY --body spike-dummy -R $R                # a dummy value, deleted afterwards
gh api -X PUT repos/$R/environments/spike-env                     # an environment with no secrets or rules
# 1. seed and read from the same branch, twice (the second run must hit):
gh workflow run spike2.yml -R $R --ref cache-mode-spike-2 -f halves=both
gh workflow run spike2.yml -R $R --ref cache-mode-spike-2 -f halves=both
# 2. read-half only, from a different ref than the seed writer (it cannot see the seed; it must still write nothing):
gh workflow run spike2.yml -R $R --ref cache-mode-spike-2b -f halves=read-only
# 3. after each run ends, read the job logs once, then list what each ref holds:
gh cache list -R $R --ref refs/heads/cache-mode-spike-2  --json key,ref,createdAt
gh cache list -R $R --ref refs/heads/cache-mode-spike-2b --json key,ref,createdAt
# 4. clean up:
gh cache delete --all --ref refs/heads/cache-mode-spike-2 -R $R; gh cache delete --all --ref refs/heads/cache-mode-spike-2b -R $R
git push origin :cache-mode-spike-2 :cache-mode-spike-2b; gh secret delete SPIKE_DUMMY -R $R; gh api -X DELETE repos/$R/environments/spike-env
```

Green means all of the following, read from the logs and the cache lists:

1. In every `read` probe: `ACTIONS_CACHE_MODE=read`, own token present, and the `ac` claim carries no write scope for the own ref; in every `write` probe the claim does.
2. In every `read` probe the v2 reservation reports `ok:false` and the v1 `POST /_apis/artifactcache/caches` is refused (a non-2xx status, or a body that reserves nothing), for the own token and for the token captured by the hostile `LD_PRELOAD` (the capture must show `stolen-token=captured`, otherwise the hostile step proves nothing and the run is not green).
3. In every `write` probe the same reservations succeed (so the test can fail).
4. The read half's `actions/cache/save` under `read` creates nothing: after the runs, `gh cache list --ref refs/heads/cache-mode-spike-2` shows the seed keys and the `spike2-save-attempt-write-*` keys and **no** `spike2-save-attempt-read-*` key, and the listing for `cache-mode-spike-2b` is empty.
5. In run 2 on `cache-mode-spike-2`, the read half's restore reports `cache-hit: true` for its seed key (a restore through the reusable workflow, under the matrix, the environment and the passed secret).
6. In the run on `cache-mode-spike-2b` (a different ref than the seed writer) the restore misses, the reservations are refused, and nothing is created.

Any other result keeps the flag `false`. The record is merged **before** the flip:

1. Pull request A adds this exact line to this file, on its own line, with the run ids and the reviewer, and nothing else that affects the flag: `Stage 2 enforcement spike result: GREEN run <run id> reviewed by <name> on <YYYY-MM-DD>`. It merges.
2. Pull request B, opened after A has merged, sets `untrusted_readonly_cache: true` on `validate-untrusted` in `linux-validation.yml` and changes neither the record nor the policy. The policy (`check-cache-mode.rb`, `spike_gate`) refuses the flip unless the record is already on the base side, which the base-policy pass reads from the base checkout at `RUNNER_TEMP/base-policy`, and refuses it if the same diff adds or alters the record. Because the checker that judges B is main's, B cannot weaken the gate.

Also before the flip: the owner runs `gh cache delete --all --ref refs/heads/untrusted` (section 3.3), and a
protected `main` run of `rust-db` has saved the week's key. `.github/CODEOWNERS` names the owner for the
workflows, composites, policy and this file; it takes effect only when "Require review from Code Owners"
is on in the `main` branch protection, an owner action in the repository settings; until then it names
owners but binds nobody. Only the base-policy pass gates the record: it is the one run whose checker comes
from `main` and reads the record from the base checkout, so a pull request's own pass is never the gate and
the gate cannot be weakened by the pull request it judges. The flip is therefore not protected by a green
own-policy run alone, and the record's reviewer line is an assertion a person made, not a machine proof.

### 7b. Gain on one concern (`rust-db`), only after Stage 1 is merged and reviewed

- `ci-speed.md` forbids dispatching the same workflow twice on one source SHA, so the plan uses
  **distinct source SHAs that share the same `Cargo.lock` and `Cargo.toml` set** (for example three
  consecutive feature-branch tips that change only source files; the compiled-cache key is then
  identical). If distinct SHAs with identical manifests are not available, ask the owner for a
  *recorded exception* before any repeat dispatch; do not repeat silently.
- Baseline: three `--ref untrusted` dispatches of `linux-validation.yml`, one per distinct SHA
  above, concern `rust-db`, cold (today's behaviour), before the workflow change is merged;
  read per-step durations and totals from the `timings` composite and the run summary (no new
  instrumentation).
- Treatment: three dispatches of three further distinct, manifest-identical SHAs after the change
  is merged and a protected `main` run has saved the key they compute. Differences in source
  size between SHAs are a confounder: record the Rust step's changed-crate count and compare
  dependency-compile time, not only wall time.
- Metrics: restore step time and size; `cache-hit`; the Rust step's duration; concern wall time;
  median of three each. Gate for widening: median wall-time reduction of at least 30 percent on a
  hit, **and** zero entries in `refs/heads/untrusted` (audit output), **and** clean console and
  network of the audit job. Also record the hit rate over the next ten real feature-branch runs,
  because section 4.2 predicts misses on manifest-touching branches.
- Free hosted runners are noisy; do not conclude from one run.

## 8. Residual risks (honest list)

1. **The core claim is unproven until the spike.** If `cache-mode: read` does not stop direct
   writes, shadowing is possible and the compiled cache must not be restored on `untrusted`.
2. **Main's scope can still be written by protected-ancestry project code** (existing accepted
   model). A tainted main entry now also reaches untrusted runs, which means feature branches can
   inherit a tainted green. Same writers as today; broader consumption.
3. **Compiled artefacts are never re-verified** by `cargo`. Integrity of a hit equals integrity of
   main's scope at save time. The ISO-week key bounds an entry's life to about a week.
4. **Absolute-path extraction** by the cache action happens as the job user. After drop-root on
   Linux this adds no privilege; on Windows and Docker-kept jobs it equals project-code privilege.
5. **Disclosure** is unchanged in capability (the run could already read main's scope) but a
   restored entry reveals dependency names and versions to the branch code and to anyone who can
   read main's caches. The reviewer should confirm the dependency inventory is not considered more
   sensitive than the lockfile the branch code already holds.
6. **The scope audit is TOCTOU-limited** and a blocked save under `cache-mode` is only a warning,
   so silent failure of a planting attempt is possible; the post-run audit reports it, it does
   not prevent it.
7. **Platform dependency.** `cache-mode` is a GitHub feature outside this repository's control; its
   semantics could change. The policy pins our use of it but not GitHub's behaviour; the spike
   should be re-run when GitHub announces changes (add to the quarterly review).
8. **Hit rate and staleness.** Weekly key rotation and manifest hashing mean many branches still
   compile cold; the gain is not guaranteed.
9. **Cache quota.** Under `read`, untrusted runs stop consuming the 10 GB quota (benefit), but a
   protected run that saves a very large entry can still evict others; unchanged.
10. **Fork pull requests** (accepted risk b) can read main's caches only while the repository's
    approval policy for external contributors ("Require approval for all external contributors")
    stays on; unchanged by this design, and entirely dependent on that setting.
11. **Windows cannot drop administrator**, so "root removal before project commands" does not
    hold there. Any untrusted restore on Windows is a separate decision and is out of scope.
12. **Absolute-path extraction is real, not theoretical** (B1): a hostile archive can write
    `~/.cargo/config.toml`, `~/.cargo/bin`, `registry/src/**` or the source tree. The sole
    control is that no hostile archive can exist in a scope the run reads.

## 9. Rules that change, and the owner's approval

**Yes, owner approval is required.** Every statement below changes, in the same set of
pull requests, and each is conditional on the spike having verified `cache-mode: read`.

Private repository (`Moh-Bakr/Taurine`):

1. `CLAUDE.md` (CI section): *"Caches exist only on `main` for protected SHAs; `untrusted` runs
   never save or restore one."* Proposed: *"Caches are written only on `main` for protected SHAs.
   `untrusted` runs may restore the two reviewed caches read-only, only under a job-level
   `cache-mode: read` that the platform spike verified; they never save."*
2. `.claude/rules/verification.md` (line ~132): *"Caches: main-only, protected SHAs only; none on
   `untrusted`."* Proposed: *"Caches: written on `main` for protected SHAs only; `untrusted`
   restores read-only under verified `cache-mode: read`, never saves."*
3. `.claude/rules/security-and-data.md` ("Independent review of security-boundary changes"):
   *"Preserve protected-only cache use and token revocation before project commands."* Proposed:
   *"Preserve protected-only cache writes (main, protected ancestry only); `untrusted` may only
   restore, read-only, under spike-verified `cache-mode: read`, and any restore is conditional on
   that verification; preserve token revocation and, on Linux and macOS, root removal before
   project commands (Windows cannot drop administrator, so this is stated per platform)."*
4. `.claude/rules/ci-feature-suites.md` (lines ~56 and ~88): "the existing cache trust
   restrictions" and "retain the existing reviewed cache restrictions" must be re-read against
   the new wording and edited to point at it, since "existing" would otherwise hide the change.
5. `.claude/rules/ci-speed.md`: no wording conflict found, but its "never dispatch the same
   workflow twice on one source SHA" rule shapes the measurement plan (section 7b).

This repository (`Moh-Bakr/Taurine-CI`), same pull request as the workflow change:

6. `docs/how-ci-works.md`: the ref-isolation table ("Never saves a cache" stays true, but
   "The only ref that may restore or save caches" for `main` becomes untrue); the Sanitising
   bullets ("Runs from `untrusted` never restore or save a cache"); the "Residual risk, per
   operating system" Linux paragraph; accepted risk (b) (add the approval-policy dependency).
7. Header comments in `rust-target-cache/action.yml`, `linux-validation-concern.yml` and
   `linux-validation.yml` ("caches are first-writer-wins"), and the cache blocks of the policy
   comments in `check-cache-policy.sh`.
8. Policy: P1 to P8 are themselves policy changes, reviewed as such, landing in two PRs.

The proposed wording is also the checklist for the reviewer: a rule missing from this list that
still says "never restore" is a defect in this design.

Nothing in this document is to be treated as that approval.

## 10. What is deliberately not done here

No workflow, composite action or policy file is changed; no run is dispatched; PRs #308 and #313
and the private batch integration are untouched; no code is written. Sizes, step names and line
references above come from reading `origin/main` at `fef1b8c` and may drift.

**Placement caveat for whoever pushes this file.** `.github/policy/check-repository.sh` allows only
flat `docs/[a-z0-9-]+\.md` guides, so the earlier path `docs/design/untrusted-readonly-cache.md` would have been rejected
by the policy workflow if pushed. It has now been renamed to the flat
`docs/untrusted-readonly-cache.md`. Committed locally only.
