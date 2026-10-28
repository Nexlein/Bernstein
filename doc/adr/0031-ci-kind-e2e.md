# ADR 0031: Deploy the manifests on a kind cluster in CI

**Status:** Accepted · **Date:** 2026-10-28 · **Issues:** #73

## Decision

Every pull request runs the CI job "K8s on kind (deploy and vote)". It builds the 3 images, creates a kind cluster (kind v0.33.0, node image `kindest/node:v1.36.4` pinned by digest, 1 control plane and 2 workers from `tests/kind.yaml`), loads the images into it, and applies `k8s/` through the same kind of overlay `scripts/deploy.sh` writes, with throwaway passwords. It waits for every workload, then casts a vote through Poll and checks that it reaches PostgreSQL and that Result is ready. The cluster lives on the GitHub runner for the length of the job.

## Why

- The manifests only ran when we deployed to AKS by hand. Schema validation ([ADR 0029](0029-manifest-schema-validation.md)) and our rules ([ADR 0030](0030-baseline-rules-check.md)) prove they are well formed, not that the pods start, pass their probes, reach each other through the NetworkPolicies and store a vote.
- **The same Kubernetes version as our AKS** (1.36.4), on a cluster that starts empty each time, like the evaluator's.
- **Fact:** since v0.24.0, kind enforces NetworkPolicies out of the box (kube-network-policies). ([kind v0.24.0 release](https://github.com/kubernetes-sigs/kind/releases/tag/v0.24.0)) Our default-deny policies are applied, not ignored.
- **2 workers:** the anti-affinity has two nodes to spread Poll and Result over, and #74 can drain one.
- **Free and nothing to stop:** the cluster runs on the runner, with no Azure credits; the Docker Compose job stays for the quick app check.

## Trade-offs

- **kind is not AKS:** no Azure load balancer, Azure Disk or Cilium. The `LoadBalancer` Services get no IP, so the job reaches Poll and Result through `kubectl port-forward`; the PostgreSQL volume uses kind's local storage. The public path and the disk are still only tested on AKS.
- The job builds the 3 images again, reading the build job's cache, and adds a few minutes to each pull request.
- kind and its action are new tools, pinned to a version; Dependabot updates the action, the kind version is a manual edit.

## Alternatives rejected

- **Deploy each pull request to our AKS:** real Azure behaviour, but CI would need our cloud credentials (#13), the cluster would have to run all the time, and two PRs would collide in the same namespace.
- **minikube or k3d in CI:** both work; kind was designed to test Kubernetes itself, pins the exact node version by image, and enforces NetworkPolicies without an extra CNI.
- **`cloud_provider: true` in the kind action (cloud-provider-kind):** gives the Services a load balancer IP, one more component to start; port-forward is enough for one vote.
