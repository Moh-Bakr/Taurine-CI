# Rotating the source-reader App key

Every source-bearing job in this repository mints its short-lived checkout token from one
credential: the private key of the source-reader GitHub App, stored only as the `source-read`
**environment** secret `SOURCE_READER_PRIVATE_KEY` (the repository has no repository-level secrets). The App's client ID is the `SOURCE_READER_APP_ID` variable. The
App is installed on the private source repositories (`Moh-Bakr/Taurine` and
`Moh-Bakr/keeldock-cloud`) with contents read only.

The key is available to a job before the token is revoked, and that job later runs private
project code with sudo. A hostile dependency could therefore copy the key out of the runner, so
rotating the key regularly limits how long a stolen key stays useful. This runbook is for the
repository owner. Every step happens in GitHub settings, and no workflow or agent changes them.

## When to rotate

- **Every 90 days.** The current key was stored on 2026-09-17, so it is next due by 2026-12-16.
  Record each rotation date at the end of this file.
- **Straight away after any suspected exposure.** Suspected exposure includes:
  - an egress-audit summary that shows a destination nobody can explain;
  - a compromised or yanked dependency that ran in a source-bearing job;
  - key material appearing in a log, summary, issue or chat;
  - a lost or shared device that held the downloaded `.pem`;
  - a collaborator who had admin access leaving.

  For a suspected exposure, delete the old key first (step 5) and then generate the new one.
  CI fails closed in the gap, which is the intended result.

## Rotation steps (owner, in GitHub settings)

A GitHub App can hold more than one private key at once, so the new key can be proved before
the old one is deleted. Validation does not need to stop.

1. **Generate a new key.** Go to GitHub, then Settings, Developer settings, GitHub Apps, the
   source-reader App, and finally Private keys. Choose **Generate a private key**. The browser
   downloads a `.pem` file. Note the fingerprint GitHub shows next to the new key.
2. **Update the environment secret.** In `Moh-Bakr/Taurine-CI`, go to Settings, Environments,
   `source-read`, then the environment secret `SOURCE_READER_PRIVATE_KEY`, and choose **Update**.
   Paste the full contents of the new `.pem` file. If you prefer the command line, run this
   yourself so the key never passes through an agent or a shell history:

   ```bash
   gh secret set SOURCE_READER_PRIVATE_KEY --env source-read --repo Moh-Bakr/Taurine-CI < path/to/new-key.pem
   ```

   Do not use `gh secret set` without `--env`: that creates a repository secret, which source-bearing
   jobs do not read, so the old key would stay active. Confirm the environment secret was updated
   (the `updated_at` timestamp changes):

   ```bash
   gh api repos/Moh-Bakr/Taurine-CI/environments/source-read/secrets \
     -q '.secrets[] | {name, updated_at}'
   ```

   Also confirm no repository secret of that name exists:
   `gh api repos/Moh-Bakr/Taurine-CI/actions/secrets -q '.secrets[].name'` must not list it.
3. **Verify with the new key** (next section). Wait for that to pass before going on to step 4.
4. **Destroy the local copy.** Securely delete the downloaded `.pem` from the device. Nothing
   needs it once it is in the secret.
5. **Revoke the old key.** On the App's Private keys list, delete every key except the one
   whose fingerprint you noted in step 1. A deleted key cannot mint tokens again.
6. **Verify again.** This shows that only the new key is in use.
7. **Record it.** Add the date to the log below in a docs-only pull request.

## Verifying a rotation

Dispatch the cheapest protected workflow that reads each private repository, from `main`:

```bash
# Taurine: the access-path smoke test (about a minute).
sha="$(gh api repos/Moh-Bakr/Taurine/commits/develop -q .sha)"
gh workflow run source-read.yml --repo Moh-Bakr/Taurine-CI --ref main -f source_sha="${sha}"

# Keel Dock uses the same App. Its full dispatch is the only entry point.
kd="$(gh api repos/Moh-Bakr/keeldock-cloud/commits/main -q .sha)"
gh workflow run keeldock-validation.yml --repo Moh-Bakr/Taurine-CI --ref main -f source_sha="${kd}"
```

A rotation is verified only when all of the following hold:

- the run's conclusion is `success`;
- the step **Verify identity, exact checkout, and revoke source token** succeeded in every job;
- the requested SHA in the run inputs and summary equals the full 40-character SHA you
  dispatched.

A failure at the mint step usually means the pasted key is truncated or comes from another
App. Re-paste it. Do not delete the old key until a run passes.

Never cancel a source-bearing run while you wait. Cancelling can interrupt the step that
revokes the token.

## Optional hardening (owner decisions)

None of these is required by the runbook. Each one trades convenience for a stronger boundary.

- **Where the key lives.** `SOURCE_READER_PRIVATE_KEY` is an environment secret of
  `source-read` (there is no repository-level copy). It is released only to jobs that enter
  `source-read`, and that environment is limited to exactly the branches `main` and `untrusted`.
  When rotating, update the secret under Settings → Environments → `source-read` (step 2); do not
  create a repository secret.
- **Keep the deployment rule at exactly `main` and `untrusted`** ("Selected branches and tags",
  two branch rules). Not "Protected branches only": rulesets do not count as protected branches
  for environments, so that setting admits every branch, and the pre-flight refuses it.
  `untrusted` must stay able to enter `source-read` so feature-branch SHAs can be validated
  without touching main's caches (ref isolation). Restricting the rule to `main` alone would
  break that.
- **Add required reviewers to `source-read`.** Every source-bearing run would then wait for an
  approval in the Actions UI before any job enters the environment. One approval releases all the
  jobs waiting at that moment. This guards against a workflow merged by mistake reading the key,
  but it adds a manual step to every dispatch, including the weekly schedule. Turn on **prevent
  self-review** only once a second trusted account exists. Until then, adding yourself is a
  deliberate pause, not two-person control.
- **Shorten the cadence** to 30 days if the egress audit is ever moved off, or if a
  supply-chain incident affects a dependency the private build uses.

## Rotation log

| Date | Reason | Verified by (run IDs) |
| --- | --- | --- |
| 2026-09-17 | Initial key stored | Not applicable |
