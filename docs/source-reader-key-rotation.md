# Rotating the source-reader App key

Every source-bearing job in this repository mints its short-lived checkout token from one
credential: the private key of the source-reader GitHub App, stored as the Actions secret
`SOURCE_READER_PRIVATE_KEY` (a repository secret until the move below is done, then a secret of the
`source-read` environment). The App's client ID is the `SOURCE_READER_APP_ID` variable. The
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
2. **Update the secret.** Update it where it currently lives. If the key has been moved (see
   "Move the key into the `source-read` environment"), that is Settings, Environments,
   `source-read`, Environment secrets; otherwise Settings, Secrets and variables, Actions,
   Repository secrets. Choose **Update** and paste the full contents of the new `.pem` file. The
   command line equivalent is below; run it yourself so the key never passes through an agent
   or a shell history:

   ```bash
   # environment secret (after the move)
   gh secret set SOURCE_READER_PRIVATE_KEY --env source-read --repo Moh-Bakr/Taurine-CI < path/to/new-key.pem
   # repository secret (before the move)
   gh secret set SOURCE_READER_PRIVATE_KEY --repo Moh-Bakr/Taurine-CI < path/to/new-key.pem
   ```

   The best moment to do the move is the next rotation: generate the new key, add it as the
   environment secret (step A below), and delete the repository secret once verified.
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

- **Move the key into the `source-read` environment.** As a repository secret, the key can be
  read by any workflow run in this repository except fork pull requests, and by any branch an
  owner pushes. An environment secret is released only to jobs that enter `source-read`, and
  that environment is already limited to protected branches. The workflows are ready: every job
  that reads `secrets.SOURCE_READER_PRIVATE_KEY` declares `environment: source-read` and reads it
  itself, and no dispatcher passes it through `secrets:` (the policy enforces both, in
  `check-universal.rb`). A job in the environment reads the environment secret, or the
  repository secret if there is no environment one, so the workflows work before and after the
  move. GitHub cannot copy a secret, so you paste the key yourself:
  - **A.** In `Moh-Bakr/Taurine-CI`, go to Settings, Environments, `source-read`, Environment
    secrets, **Add environment secret**. Name it `SOURCE_READER_PRIVATE_KEY` and paste the same
    PEM (or the new key, when you do this during a rotation).
  - **B.** Verify: dispatch `source-read.yml` from `main` and from `untrusted` (see "Verifying a
    rotation") and require both to succeed.
  - **C.** Go to Settings, Secrets and variables, Actions, Repository secrets, and delete
    `SOURCE_READER_PRIVATE_KEY`. Verify once more with a `source-read.yml` dispatch from `main`.
- **Restrict deployment branches to `main` only.** Today `source-read` allows "protected
  branches". A custom deployment-branch rule of `main` removes any other protected branch from
  the trusted set. The protected workflows already refuse any ref other than `refs/heads/main`.
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
