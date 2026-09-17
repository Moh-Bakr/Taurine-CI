# Taurine CI

This public repository contains the workflow orchestration and policy for
building and validating the private Taurine application.

The Taurine source repository remains private. This repository must never
contain Taurine source code, source snapshots, proprietary fixtures, private
configuration, credentials, signing material, or source-derived public
artifacts.

Trusted workflows may obtain a short-lived, read-only checkout through the
approved authorization broker. Public pull requests and forks must remain
secretless and must not receive private-source access.

The production architecture and rollout checklist are maintained with the
private project documentation. Changes to workflow identity, permissions,
authentication, artifact handling, or release behavior require security
review.
