# ADR 0031: Deploy the manifests on a kind cluster in CI

**Status:** Accepted · **Date:** 2026-10-28 · **Issues:** #73, #74

## Decision

Every pull request runs the CI job "K8s on kind (deploy and vote)". It builds the 3 images, creates a kind cluster (kind v0.33.0, node image `kindest/node:v1.36.4` pinned by digest, 1 control plane and 2 workers from `tests/kind.yaml`), loads the images into it, and applies `k8s/` through the same kind of overlay `scripts/deploy.sh` writes, with throwaway passwords. It waits for every workload, then casts a vote through Poll and checks that it reaches PostgreSQL and that Result is ready. Then it runs `tests/zero-downtime.sh --from cluster` twice, and fails on any error (#74): during a `rollout restart` of Poll and Result, and during a `kubectl drain` of the worker that does not run PostgreSQL. The cluster lives on the GitHub runner for the length of the job.

## Why

- The manifests only ran when we deployed to AKS by hand. Schema validation ([ADR 0029](0029-manifest-schema-validation.md)) and our rules ([ADR 0030](0030-baseline-rules-check.md)) prove they are well formed, not that the pods start, pass their probes, reach each other through the NetworkPolicies and store a vote.
- **The same Kubernetes version as our AKS** (1.36.4), on a cluster that starts empty each time, like the evaluator's.
- **Fact:** since v0.24.0, kind enforces NetworkPolicies out of the box (kube-network-policies). ([kind v0.24.0 release](https://github.com/kubernetes-sigs/kind/releases/tag/v0.24.0)) Our default-deny policies are applied, not ignored.
- **2 workers:** the anti-affinity has two nodes to spread Poll and Result over, and one can be drained.
- **The graded test on every PR (#74):** first run, 0 errors in 1519 requests during the rollout, and 0 errors in 1002 during the drain (worker, Poll and Result evicted). The requests come from a pod in the cluster ([ADR 0016](0016-zero-downtime-test.md)): a port-forward reaches one pod, the very pod a rollout replaces. The whole job took 3 min 36 s.
- **Free and nothing to stop:** the cluster runs on the runner, with no Azure credits; the Docker Compose job stays for the quick app check.

## Trade-offs

- **kind is not AKS:** no Azure load balancer, Azure Disk or Cilium. The `LoadBalancer` Services get no IP, so the job reaches Poll and Result through `kubectl port-forward`; the PostgreSQL volume uses kind's local storage. The public path and the disk are still only tested on AKS.
- **The drained node is never PostgreSQL's:** on kind, its volume is a directory of its node (`local-path`), so the pod could not move. On AKS the Azure Disk follows it; that case is only measured there (Result down 39 s, [guide 9.5](../defense/k8s-study-guide.md#95-kubectl-drain-dun-nœud-question-classique)).
- **The drain evicts only our pods** (`--pod-selector`): kind's CoreDNS has no PodDisruptionBudget, and the test's own pod has no controller, which a plain drain refuses.
- The job builds the 3 images again, reading the build job's cache, and adds a few minutes to each pull request.
- kind and its action are new tools, pinned to a version; Dependabot updates the action, the kind version is a manual edit.

## Alternatives rejected

- **Deploy each pull request to our AKS:** real Azure behaviour, but CI would need our cloud credentials (#13), the cluster would have to run all the time, and two PRs would collide in the same namespace.
- **minikube or k3d in CI:** both work; kind was designed to test Kubernetes itself, pins the exact node version by image, and enforces NetworkPolicies without an extra CNI.
- **`cloud_provider: true` in the kind action (cloud-provider-kind):** gives the Services a load balancer IP, one more component to start; port-forward is enough for one vote.
