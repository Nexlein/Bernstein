# ADR 0005: Image tags from the git commit SHA

**Status:** Accepted · **Date:** 2026-10-19 · **Issues:** #8, #12, #36, #106

## Decision

Each app's image is tagged with the short SHA of the last commit that changed its folder, `poll-application/<app>` (`git log -1 --format=%h -- poll-application/<app>`): `<registry>/poll:<sha>`. When that folder has uncommitted changes, the tag is `<sha>-dirty-<date-time>`. `scripts/deploy.sh` builds and pushes only the tags the registry does not have yet, and writes the 3 tags into the manifests through Kustomize `images` ([ADR 0017](0017-deploy-script.md)). `TAG` (the 3 apps) or `POLL_TAG`, `WORKER_TAG`, `RESULT_TAG` (one app) deploy an existing tag instead; it is never built.

## Why

- A new tag changes the Pod template, so Kubernetes starts a rolling update. Re-pushing the same tag does not.
- **Fact:** Kubernetes advises against `:latest` in production: it makes it hard to know which version runs and to roll back. ([Kubernetes docs: Images](https://kubernetes.io/docs/concepts/containers/images/))
- Every running pod points to an exact commit: easy to trace, and to roll back with `kubectl rollout undo`.
- No manual version bump: the tag is derived from git.
- **The `-dirty` suffix:** at the defense, the evaluator changes a source file and redeploys, maybe without committing. With the bare SHA, the tag would not change, so nothing would roll out. A date-time suffix makes every uncommitted change a new tag.
- **One tag per app (#106):** with one tag for the 3 apps (the SHA of `HEAD`), changing Poll's title also rebuilt and rolled Result and the worker, and a commit touching only the docs rolled all three. Now an app whose code did not change keeps its tag: nothing is rebuilt or pushed for it, and `kubectl apply` leaves it `unchanged`. Measured on AKS: a Poll change rebuilt and rolled Poll only, the script took 34 s instead of 52 s, 0 errors.
- **Which version runs?** `kubectl -n bernstein get deploy -o wide`, column `IMAGES`: each tag is the commit of that app's code (`git show <tag>`), or that commit plus local changes for a `-dirty` tag.

## Trade-offs

- A SHA says nothing about the size of the change, unlike semver.
- A `-dirty` tag points to code that is in no commit: it cannot be traced back exactly. Fine for a live test; real releases come from commits.
- Registry tags are mutable, so a SHA tag could in theory be overwritten. A digest (`@sha256:...`) is fully immutable but unreadable.

- **The 3 apps have different tags:** a version of the app is 3 SHAs. Rolling the 3 back at once needs their 3 tags, or `TAG=` for a tag they share (the images built before #106).
- **The tag follows the app's folder only.** A change elsewhere that alters an image would get no new tag. None today: each Dockerfile builds from its own folder only.
- Switching to this scheme rebuilt and rolled the 3 apps once, under their new tags.

## Alternatives rejected

- **`latest`:** no rollout on re-push, no rollback, no traceability.
- **Semver (`v1.2.3`):** needs a manual release step; useful for a public product, not for continuous deploys.
- **The folder's tree hash** (`git rev-parse HEAD:poll-application/poll`): changes exactly when the content changes, but points to no commit, so `git show` on the tag gives nothing. The folder's last commit is as precise and readable.
- **One shared tag, and skip the apps whose image did not change:** needs to compare image digests after each build, so every app is still built each time.
- **Digest only:** safest, but the manifests become hard to read. Possible later hardening step.
