# ADR 0034: CI publishes main's images with `deploy.sh --push-only`

**Status:** Accepted · **Date:** 2026-10-29 · **Issues:** #12

## Decision

On every push to `main`, the CI job "Publish Images (main)" runs `scripts/deploy.sh --push-only`, once the registry login and the tests (Docker Compose, kind, image scan) have passed. The script computes each app's tag ([ADR 0005](0005-image-tags-git-sha.md)), logs in to our registry with the CI's OIDC identity ([ADR 0032](0032-ci-registry-oidc.md)), and builds and pushes only the images the registry does not have yet. It stops before any `kubectl`: CI never deploys.

## Why

- **One way to compute the tags:** CI pushes exactly the images `scripts/deploy.sh` would deploy. After a merge, our next deploy finds them and builds nothing: faster, and no upload from the machine that runs the zero-downtime test, which once caused 2 timeouts ([ADR 0017](0017-deploy-script.md)).
- **Only tested code is published:** the job `needs` the tests on `main`; a failed test or a fixable `CRITICAL` vulnerability stops it.
- **Nothing rebuilt for nothing:** an app whose folder did not change keeps its tag, so it is neither rebuilt nor pushed again.
- **The existence check asks the registry itself:** with `--push-only`, the script logs in first, then runs `docker manifest inspect`, which only needs the pull right that `AcrPush` includes. `az acr repository show`, used by a local deploy, might need more; if it failed, the script would rebuild and overwrite tags already deployed. Checked against our registry, with `kubectl` removed from the `PATH`: login, the 3 images "already in the registry", exit 0; a missing given tag stops with its error.
- **`fetch-depth: 0`:** a shallow clone holds only the last commit, so `git log -- poll-application/<app>` would find no tag for an app it did not change.

## Trade-offs

- **Our registry only:** the evaluator builds and pushes to their own registry with `scripts/deploy.sh`; CI would need their credentials.
- **Rebuilt, not reused:** the publish job builds the changed apps again, without the test jobs' cache: a few minutes when an app changed, nothing otherwise.
- **After the slowest test:** the images land in the registry once the kind job is done, about 4 minutes after the merge.
- A newer push to `main` cancels the running pipeline (`cancel-in-progress`); the next run pushes whatever is still missing, since the check is by tag.

## Alternatives rejected

- **Build and push in YAML (`docker/build-push-action` with `push: true`):** could reuse the build cache, but computes the tags a second time; a mismatch would push images `deploy.sh` never deploys ([ADR 0017](0017-deploy-script.md), "Revisit if").
- **Push from every pull request:** unreviewed code in the registry, and images of branches that are never merged.
- **Deploy from CI on `main`:** needs cluster credentials in GitHub, and our cluster is stopped most of the time ([ADR 0017](0017-deploy-script.md), [ADR 0020](0020-no-gitops.md)).
- **`az acr build` (build in Azure):** ACR Tasks, one more billed service.
