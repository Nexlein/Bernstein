# ADR 0005: Image tags from the git commit SHA

**Status:** Accepted · **Date:** 2026-10-19 · **Issues:** #8, #12, #36

## Decision

Each build tags the images with the short git SHA of the commit (`<registry>/poll:<sha>`): `scripts/deploy.sh` today, CI later (#12). When `poll-application/` has uncommitted changes, the tag is `<sha>-dirty-<date-time>`. The deploy script writes the tag into the manifests through Kustomize `images` ([ADR 0017](0017-deploy-script.md)).

## Why

- A new tag changes the Pod template, so Kubernetes starts a rolling update. Re-pushing the same tag does not.
- **Fact:** Kubernetes advises against `:latest` in production: it makes it hard to know which version runs and to roll back. ([Kubernetes docs: Images](https://kubernetes.io/docs/concepts/containers/images/))
- Every running pod points to an exact commit: easy to trace, and to roll back with `kubectl rollout undo`.
- No manual version bump: the tag is derived from git.
- **The `-dirty` suffix:** at the defense, the evaluator changes a source file and redeploys, maybe without committing. With the bare SHA, the tag would not change, so nothing would roll out. A date-time suffix makes every uncommitted change a new tag.

## Trade-offs

- A SHA says nothing about the size of the change, unlike semver.
- A `-dirty` tag points to code that is in no commit: it cannot be traced back exactly. Fine for a live test; real releases come from commits.
- Registry tags are mutable, so a SHA tag could in theory be overwritten. A digest (`@sha256:...`) is fully immutable but unreadable.

## Alternatives rejected

- **`latest`:** no rollout on re-push, no rollback, no traceability.
- **Semver (`v1.2.3`):** needs a manual release step; useful for a public product, not for continuous deploys.
- **Digest only:** safest, but the manifests become hard to read. Possible later hardening step.
