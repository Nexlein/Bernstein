# ADR 0026: HorizontalPodAutoscaler on Poll, 2 to 6 pods at 70 % CPU

**Status:** Accepted · **Date:** 2026-10-27 · **Issues:** #33

## Decision

`k8s/hpa.yaml` scales `deploy/poll` between 2 and 6 pods, to keep their average CPU at 70 % of the request (35m of 50m). Default behaviour: scale up at once, scale down after 5 minutes. `k8s/poll.yaml` no longer sets `replicas`. Result keeps 2 fixed pods ([ADR 0008](0008-result-deployment.md)).

## Why

- **Poll is the page that takes the votes**, and its CPU grows with traffic: Python renders the page on every request (100m per pod under load, [ADR 0018](0018-resource-requests-and-limits.md)). Result barely grows with viewers ([ADR 0008](0008-result-deployment.md)).
- **How it computes:** **Fact:** the utilization is a percentage of the containers' CPU request; the controller runs every 15 seconds, computes `desiredReplicas = ceil(currentReplicas × currentMetricValue / desiredMetricValue)`, and skips the change within a 0.1 tolerance. ([Kubernetes docs: Horizontal Pod Autoscaling](https://kubernetes.io/docs/concepts/workloads/autoscaling/horizontal-pod-autoscale/)) metrics-server, which provides the CPU, runs on AKS by default ([ADR 0024](0024-observability.md)).
- **Min 2:** the same floor as before, for rollouts and drains ([ADR 0011](0011-poll-deployment.md), [ADR 0014](0014-pod-disruption-budgets.md)).
- **Max 6, sized on the drain:** a drained node sends all its pods to the other one. After a drain, the remaining node held 1352m of requests out of 1900m; 4 more Poll pods add 200m, so 1552m still fits. Memory: 4 × 96Mi more, far from the 5.6 GiB.
- **70 %:** room for a spike during the minute the metrics need to show it, without adding pods at idle (Poll uses about 2m at rest).
- **Default behaviour kept.** **Fact:** no stabilization window for scaling up (at most 4 pods or 100 % more every 15 s); a 300-second window for scaling down. ([same page](https://kubernetes.io/docs/concepts/workloads/autoscaling/horizontal-pod-autoscale/)) The slow scale-down avoids removing pods during a short pause in the traffic.
- **No `replicas` in the Deployment.** **Fact:** with an HPA, the docs recommend removing `spec.replicas` from the manifest, or every `kubectl apply` scales back to that value. Removing it from an existing Deployment drops it once to 1 pod (the default), unless `kubectl apply edit-last-applied` removes it first. ([same page](https://kubernetes.io/docs/concepts/workloads/autoscaling/horizontal-pod-autoscale/)) We ran that command on `bernstein-aks` before deploying: `deployment.apps/poll unchanged`, 2 pods kept. An evaluator's fresh cluster has nothing to migrate.

## Measured on AKS (2026-10-27)

Load: 4 busybox pods looping `wget` on the `poll` Service, from another namespace (our NetworkPolicies block a client inside `bernstein`, [ADR 0025](0025-network-policies.md)). Errors counted by an in-cluster probe requesting the Poll and Result Services every 0.1 s, because the test machine's connection was degraded that day.

| Time     | Event                                                                   |
| -------- | ----------------------------------------------------------------------- |
| 18:23:10 | load starts                                                             |
| 18:24:39 | HPA reads 263 % (metrics take about 1.5 minutes to show the load)       |
| 18:24:54 | 2 → 4 pods                                                              |
| 18:25:10 | 4 → 6 pods; each uses 75 to 83m, the HPA stays at the max (112-166 %)   |
| 18:26:16 | drain of the node without PostgreSQL: 3 Poll pods evicted at once, 35 s |
| 18:27:25 | load stops                                                              |
| 18:29:40 | HPA reads 6 %                                                           |
| 18:33:40 | 6 → 5 pods                                                              |
| 18:34:41 | 5 → 2 pods, 7 minutes after the load stopped                            |

- **0 errors in 13 000 probe requests** over the whole run: scale up, drain at 6 pods, scale down.
- The drain at 6 pods left no pod `Pending`: everything fit on one node.
- Each scale-down came 5 minutes after the HPA's recommendation dropped: the window keeps the highest recommendation of the last 5 minutes.

## Trade-offs

- **Pods, not nodes:** the 2 nodes have a fixed CPU. At 6 pods our load still asked for more (166 %), and more pods would only share the same CPU. Adding nodes is the cluster autoscaler's job (below).
- **Reaction time:** about 1.5 minutes from the start of a load to the first new pod. A sudden spike hits 2 pods first.
- **Scale-down takes 5 minutes or more**, by design.
- A manual `kubectl scale deploy/poll` is overridden by the HPA at its next run.
- With 6 pods, the PDB (`minAvailable: 1`) lets a drain evict all but one at once. No outage, but less capacity until the replacements are Ready ([ADR 0014](0014-pod-disruption-budgets.md)).

## Alternatives rejected

- **Cluster autoscaler** (`--enable-cluster-autoscaler --min-count 2 --max-count 3`): would add the third node our 6 vCPU quota allows. More cost, and it only helps once the pods no longer fit, which our max of 6 avoids.
- **Scale on requests per second or the Redis queue length** (custom metrics, KEDA): closer to the real load, but needs a metrics pipeline we do not run ([ADR 0024](0024-observability.md)).
- **A higher target (80-90 %):** fewer pods, but less margin during the 1.5 minutes before the HPA reacts.
- **More fixed replicas:** pays for capacity at idle.
- **HPA on Result:** see [ADR 0008](0008-result-deployment.md).

## Revisit if

Real traffic shows Poll at its max for long, or the cluster gets more nodes.
