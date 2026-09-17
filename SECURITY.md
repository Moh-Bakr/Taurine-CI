# Security policy

## Scope

This repository contains public CI orchestration only. Do not submit private
Taurine source, source snapshots, proprietary test fixtures, internal service
details, credentials, signing keys, or private build outputs.

The public repository must not store a PAT, SSH deploy key, GitHub App private
key, or any reusable credential capable of reading the private Taurine
repository. Source authorization is brokered with GitHub OIDC and short-lived,
repository-scoped grants.

## Reporting

Do not open a public issue for a suspected credential exposure or private-data
disclosure. Immediately stop the affected workflow, preserve the run ID and
commit SHA, revoke or rotate the affected credential, and report the incident
through the project's private security channel.

Until that private channel is documented, contact the Taurine repository
maintainer directly through the private project administration account.

## Workflow safety

Workflow changes require review by the repository owners. Pull-request
workflows must remain secretless and must not use `pull_request_target` to build
untrusted code.
