# ADR 0013: Spread Poll and Result over the nodes with preferred anti-affinity

**Status:** Accepted · **Date:** 2026-10-26 · **Issues:** #32, #97

## Decision

Poll and Result have a `podAntiAffinity` rule, `preferredDuringSchedulingIgnoredDuringExecution`, weight 100, `topologyKey: kubernetes.io/hostname`, with `matchLabelKeys: ['pod-template-hash']`. The scheduler tries to put the 2 replicas of each app (of the same version) on different nodes.

## Why

- Observed before this rule: both Result pods often landed on the same node. Losing or draining that node took the page down despite 2 replicas.
- **Fact:** with `topologyKey: kubernetes.io/hostname`, each node is its own topology domain: the rule means "avoid a node that already runs a pod with this label". ([Kubernetes docs: Inter-pod affinity and anti-affinity](https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/#inter-pod-affinity-and-anti-affinity))
- **`matchLabelKeys: ['pod-template-hash']`:** observed on AKS without it, a rollout put both new Poll pods and both new Result pods on one node. During a rollout the old pods, on both nodes, carry the same `app.kubernetes.io/name` label and count for the rule, so no node looks free and the preference does nothing. **Fact:** `matchLabelKeys` adds the incoming pod's value of each listed label to the selector. ([Kubernetes docs: matchLabelKeys](https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/#matchlabelkeys)) The Deployment sets `pod-template-hash` per version, so only pods of the same version count.
- **Preferred, not required:** with `maxSurge: 1`, a rollout briefly runs 3 pods on 2 nodes. A `required` rule would leave the 3rd pod `Pending` and block the rollout. The preferred rule only scores nodes, so the surge pod still schedules.

## Trade-offs

- "Preferred" is not a guarantee: if one node is full or down, both replicas can end up on the other.
- **Fact:** `IgnoredDuringExecution`: the rule only applies at scheduling; running pods are not moved. ([Kubernetes docs: Inter-pod affinity and anti-affinity](https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/#inter-pod-affinity-and-anti-affinity)) After a node comes back, the spread returns at the next rollout or restart, not by itself.
- **After every `az aks start`, all pods run on one node.** The first node to be ready gets them all: seen 5 times out of 5 checked, all 7 pods on one node. A `rollout restart` of Poll and Result spreads them again, one of each per node, with 0 errors (`DEPLOY.md`, After `az aks start`). Until then, losing or draining that node takes Poll and Result down together.
- Redis, PostgreSQL and the worker have 1 replica each: losing their node stops them wherever they run ([ADR 0007](0007-postgres-statefulset.md), [ADR 0009](0009-redis-queue.md)). The spread protects the Poll and Result pods themselves, on a drain or a pod failure.

## Alternatives rejected

- **`requiredDuringScheduling…`:** strict spread, but blocks rollouts on 2 nodes and leaves a replica `Pending` when one node is down.
- **`topologySpreadConstraints` (`maxSkew: 1`, `whenUnsatisfiable: ScheduleAnyway`):** same result here, more flexible for many nodes or zones. Anti-affinity is simpler to read for 2 replicas on 2 nodes.
- **Descheduler, to move the pods back by itself:** its anti-affinity strategy only reads the `required` terms ([`GetPodAntiAffinityTerms`](https://github.com/kubernetes-sigs/descheduler/blob/master/pkg/utils/predicates.go)), so it ignores our preferred rule; its spread strategy would need `topologySpreadConstraints`. One more component with the right to evict pods anywhere, for a case that only follows a manual `az aks start` and one command fixes.
- **`topologySpreadConstraints` with `whenUnsatisfiable: DoNotSchedule`:** a strict spread, so like `required` it risks `Pending` pods when one of our 2 nodes is drained or down. Not tested, and not a change to make one week before the defense.
- **Spreading over zones:** our nodes have no availability zones ([ADR 0007](0007-postgres-statefulset.md)).
