# ADR 0036: Pin the CI actions by commit and the app base images by digest

**Status:** Accepted · **Date:** 2026-10-29 · **Issues:** #98, #77

## Decision

Every third-party action in `.github/workflows/` is referenced by its full commit SHA, with the release it matches in a comment (`actions/checkout@3d3c42e… # v7.0.1`). The 4 base images of our Dockerfiles carry their tag and their digest (`python:3.14-slim@sha256:cd89c30…`), like PostgreSQL and Redis in `k8s/` (#98). The workflows also set `permissions: contents: read` for every job; the 2 jobs that log in to Azure add `id-token: write` themselves.

## Why

- **A tag can move, a commit or a digest cannot:** the same reason we use the Trivy binary with a checksum rather than its action ([ADR 0033](0033-ci-image-scan.md)). **Fact:** in March 2026, 76 of the 77 tags of `aquasecurity/trivy-action` were force-pushed to credential-stealing code. ([GHSA-69fq-xp46-6x23](https://github.com/aquasecurity/trivy/security/advisories/GHSA-69fq-xp46-6x23))
- **What our actions can reach:** `azure/login` gets the OIDC token that may push to the registry and stop the cluster ([ADR 0032](0032-ci-registry-oidc.md), [ADR 0035](0035-nightly-stop.md)), and `webfactory/ssh-agent` gets the SSH key that pushes the Epitech repository, our graded delivery.
- **Fact:** GitHub's first advice is a lockfile of the workflow dependencies; for repositories without one, pin each action to a full-length commit SHA. ([GitHub Docs: secure use](https://docs.github.com/en/actions/reference/security/secure-use))
- **The evaluator builds what we tested:** on the defense day, `scripts/deploy.sh` builds from the same base images CI built and scanned, not from whatever the tag points to that day.
- **Read-only token by default:** the repository setting is already read-only (`default_workflow_permissions: read`); writing it in the workflows keeps it so if the setting changes.

## Trade-offs

- **Updates are no longer automatic:** a new base image or action release only arrives through a change in git. Dependabot's `docker` and `github-actions` entries are meant to propose these bumps; a pin it does not update is bumped by hand, with the same commands as here (the digest from the registry, the SHA from the release tag).
- **A digest bump rebuilds the app:** the folder changes, so the app gets a new tag, a rebuild, a scan and a rollout on the next deploy ([ADR 0005](0005-image-tags-git-sha.md)). That is the point: a new base image is a new version.
- Longer lines in the Dockerfiles and workflows; the codemap drops the digest to stay readable.

## Alternatives rejected

- **Tags only (before):** shorter, and updates arrive by themselves, including a hijacked one.
- **Digest only, no tag:** safest to read by a machine, but nobody can tell which version runs.
- **A workflow lockfile:** GitHub's preferred measure, but a newer feature we have not tried; SHA pins give the same guarantee for our 7 actions.
