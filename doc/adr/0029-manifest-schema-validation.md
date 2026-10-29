# ADR 0029: Validate the manifests against the Kubernetes schema in CI

**Status:** Accepted · **Date:** 2026-10-28 · **Issues:** #71

## Decision

CI validates every object rendered by `kubectl kustomize k8s/` with kubeconform v0.8.0 in `-strict` mode, against the schema of Kubernetes 1.36.4 (our AKS version) and 1.31.0 (the minimum `DEPLOY.md` asks for). An unknown or invalid field fails the pull request. The release is pinned and its checksum verified.

## Why

- The existing step only proves that the manifests **build**. A misspelled or misplaced field still passed, and only failed on the cluster at deploy time.
- **Checked:** on a copy of `k8s/`, `matchLabelKey` instead of `matchLabelKeys` fails with `additional properties 'matchLabelKey' not allowed`, and `readinesProbe` with `additional properties 'readinesProbe' not allowed`. The real manifests pass: 23 objects valid, on both versions, for `main` and for the open PR stack.
- **Fact:** kubeconform validates manifests against JSON schemas generated from the Kubernetes OpenAPI, and `-strict` refuses properties the schema does not define. ([kubeconform](https://github.com/yannh/kubeconform)) No cluster needed: the step takes seconds.
- **1.31.0 too:** proves the minimum version in the prerequisites, at no extra cost.

## Trade-offs

- **The schemas are downloaded from GitHub on each run** (the `kubernetes-json-schema` repository): a GitHub outage fails the step.
- **Structure only.** A valid field with a wrong value (a label that matches nothing, a too-low limit) passes. Our own rules (replicas, rollout strategy, probes, resources) are #72; real behaviour on a cluster is #73.
- Dependabot does not see a version in a `run` step: bumping kubeconform is a manual edit of the version and the checksum.

## Alternatives rejected

- **kubeval:** **Fact:** no longer maintained; its README points to kubeconform. ([kubeval](https://github.com/instrumenta/kubeval))
- **`kubectl apply --dry-run=server --validate=strict`:** the exact check, by the API server itself, but it needs a cluster in CI. Done since with kind, which also deploys the manifests ([ADR 0031](0031-ci-kind-e2e.md)); kubeconform stays, as the fast check that runs first.
- **`kubectl apply --dry-run=client`:** client-side validation also needs a server for the OpenAPI schema.
