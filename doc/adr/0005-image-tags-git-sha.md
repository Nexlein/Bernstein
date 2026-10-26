# ADR 0005: Image tags from the git commit SHA

**Status:** Accepted · **Date:** 2026-10-19 · **Issues:** #8, #12

## Decision

CI tags each image with the short git SHA of the commit (`<registry>/poll:<sha>`). The `images` field of `k8s/kustomization.yaml` writes that tag into the manifests.

## Why

- A new tag changes the Pod template, so Kubernetes starts a rolling update. Re-pushing the same tag does not.
- **Fact:** Kubernetes advises against `:latest` in production: it makes it hard to know which version runs and to roll back. ([Kubernetes docs: Images](https://kubernetes.io/docs/concepts/containers/images/))
- Every running pod points to an exact commit: easy to trace, and to roll back with `kubectl rollout undo`.
- No manual version bump: CI derives the tag.

## Trade-offs

- A SHA says nothing about the size of the change, unlike semver.
- Registry tags are mutable, so a SHA tag could in theory be overwritten. A digest (`@sha256:...`) is fully immutable but unreadable.

## Alternatives rejected

- **`latest`:** no rollout on re-push, no rollback, no traceability.
- **Semver (`v1.2.3`):** needs a manual release step; useful for a public product, not for continuous deploys.
- **Digest only:** safest, but the manifests become hard to read. Possible later hardening step.
