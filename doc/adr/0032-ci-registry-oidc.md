# ADR 0032: CI logs in to the registry with Azure OIDC

**Status:** Accepted · **Date:** 2026-10-28 · **Issues:** #13

## Decision

The CI job "Registry Login (Azure OIDC)" logs in to our registry with no password stored in GitHub. The Entra app `bernstein-github-ci` has the role `AcrPush` on the registry only, and 2 federated credentials: `repo:Nexlein@183351649/Bernstein@1418620429:ref:refs/heads/main` (pushes to `main`) and `repo:Nexlein@183351649/Bernstein@1418620429:pull_request` (pull requests). The job asks GitHub for an OIDC token (`id-token: write`), exchanges it through `azure/login@v3`, then runs `az acr login`. The 4 GitHub secrets it reads are identifiers: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `ACR_NAME`. It does not push yet: building and pushing on `main` is #12. Setup: [cluster-setup.md §8](../setup/cluster-setup.md#8-build-push-and-deploy).

## Why

- **Nothing to leak or rotate:** a password in GitHub works anywhere until someone revokes it. Here Entra ID only accepts a token that GitHub signed for this repository and branch, and it expires with the job.
- **Bound to this repository, not to its name:** the subject holds the account and repository IDs (`Nexlein@183351649/Bernstein@1418620429`). If the repository were deleted or renamed, a new one with the same name would get other IDs, and no access. Our first setup used `repo:Nexlein/Bernstein:…`, and the login failed with `AADSTS700213` until the subjects were fixed.
- **Fact:** repositories created after 2026-07-15 use an immutable subject format, with the owner ID and the repository ID; older ones keep the name-only format unless they opt in. ([GitHub Docs: OIDC reference](https://docs.github.com/en/actions/reference/security/oidc))
- **Fact:** with OIDC, the cloud provider issues a short-lived access token valid for a single job, which then expires. ([GitHub Docs: OpenID Connect](https://docs.github.com/en/actions/concepts/security/openid-connect))
- **Least privilege:** `AcrPush` on the registry only, with no right on the cluster or the resource group. A stolen token could push an image, not deploy it, and only for a few hours.
- **Fact:** the token `az acr login` uses is valid for 3 hours. ([Microsoft Learn: registry authentication](https://learn.microsoft.com/en-us/azure/container-registry/container-registry-authentication))
- **The pull request proves the login before the merge:** the `pull_request` credential lets the job run on a PR, so a broken setup shows up in review, not after the merge to `main`.
- **Clear failure:** the first step lists the missing secrets and points to the setup guide, instead of an `azure/login` error.

## Trade-offs

- **A PR branch gets push rights:** a workflow changed in a pull request could push an image, even under a tag `scripts/deploy.sh` would later find and reuse instead of building, as registry tags can be overwritten. We accept it: only the 2 of us can push branches to this repository, and fork PRs never get the token (below).
- **Fact:** except `GITHUB_TOKEN`, secrets are not passed to a workflow triggered from a fork. ([GitHub Docs: using secrets](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets)) The job's `if:` skips fork PRs, forks and the Epitech mirror, the same guard as `mirror.yml`, so they do not fail on a login they cannot do.
- **Setup needs the subscription owner:** the role assignment needs `Owner` or `User Access Administrator`; Maeva did it once. A new repository, or a job with an `environment:` (subject `environment:<name>`), needs a new federated credential.
- `ACR_NAME` is not a secret; it sits with the others so the job reads one place.

## Alternatives rejected

- **Service principal with a password (`ACR_USERNAME` / `ACR_PASSWORD`):** the old setup guide's option. A long-lived secret in GitHub, valid outside the CI, to rotate by hand before it expires.
- **Registry admin user:** one account with push and pull on the whole registry, shared by everyone. **Fact:** designed for a single user, mainly for testing. ([Microsoft Learn: registry authentication](https://learn.microsoft.com/en-us/azure/container-registry/container-registry-authentication))
- **Repository-scoped registry token:** finer scope than `AcrPush`, but still a password stored in GitHub. ([Microsoft Learn: token-based repository permissions](https://learn.microsoft.com/en-us/azure/container-registry/container-registry-token-based-repository-permissions))
- **Login on `main` only:** fewer runs with push rights, but a wrong secret or credential would only show after the merge.
