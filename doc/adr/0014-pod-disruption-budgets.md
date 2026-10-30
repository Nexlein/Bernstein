# ADR 0014: PodDisruptionBudgets for Poll and Result

**Status:** Accepted · **Date:** 2026-10-26 · **Issues:** #31

## Decision

`k8s/pdb.yaml` defines a `PodDisruptionBudget` with `minAvailable: 1` for Poll and one for Result. Redis, PostgreSQL and the worker have none.

## Why

- **Fact:** `kubectl drain` evicts pods through the Eviction API, which refuses an eviction that would break a PDB; `drain` retries until it is allowed. ([Kubernetes docs: Safely drain a node](https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/)) With `minAvailable: 1`, a drain only removes a Poll or Result pod while another one is available: the page never drops to zero pods.
- `maxUnavailable: 0` only applies to rollouts, not to evictions. The PDB covers the rest: drains, node image upgrades and AKS cluster upgrades, which also evict.
- Works with the anti-affinity ([ADR 0013](0013-pod-anti-affinity.md)): with replicas on different nodes, a drain evicts at most one pod per app, and the PDB is satisfied at once.

## Trade-offs

- **Fact:** a PDB only protects against **voluntary** disruptions; a node crash or an OOMKill is not stopped. ([Kubernetes docs: Disruptions](https://kubernetes.io/docs/concepts/workloads/pods/disruptions/))
- **Measured on AKS, continuous requests to both public IPs:**
  - Draining the node with one Poll, one Result and the worker: **0 errors** (2221 requests, 8 s).
  - Draining the node that also ran **PostgreSQL and Redis**: at first 0 errors on Poll, but **47 failed requests on Result over 39 s**. PostgreSQL has 1 replica: while its disk moved, both Result pods failed `/readyz` and the Service had no endpoint. A PDB cannot help a single replica ([ADR 0007](0007-postgres-statefulset.md)).
  - The same drain once Result kept serving without the database ([ADR 0008](0008-result-deployment.md), 2026-10-29): **0 errors** on both (546 requests on Result, 1315 from inside the cluster). Only the scores froze, 27 s, while PostgreSQL moved.
- If both replicas sit on the drained node (anti-affinity is only preferred), the drain evicts one, waits until its replacement is Ready elsewhere, then evicts the other. Slower, but no outage.

## Alternatives rejected

- **PDB on Redis, PostgreSQL or the worker:** 1 replica each. `minAvailable: 1` would block every drain forever; `maxUnavailable: 1` would allow everything and protect nothing. Their short downtime is documented in [ADR 0007](0007-postgres-statefulset.md), [ADR 0009](0009-redis-queue.md) and [ADR 0010](0010-worker-deployment.md).
- **`maxUnavailable: 1` instead of `minAvailable: 1`:** same effect with 2 replicas. `minAvailable` states the goal ("always one serving") and stays right if replicas are raised by hand or by the HPA (#33).
