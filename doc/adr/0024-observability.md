# ADR 0024: Observability with kubectl, no centralized monitoring

**Status:** Accepted · **Date:** 2026-10-27 · **Issues:** #78

## Decision

We watch and debug the app with what Kubernetes and AKS already give: probes, events, logs, `kubectl top`, plus `tests/zero-downtime.sh` from outside. No Container Insights, no managed Prometheus or Grafana, no alerting. Debugging steps: [`DEPLOY.md`, Debug a broken pod](../../DEPLOY.md#debug-a-broken-pod).

## What we have

| Question                      | Command                                                                    | What it shows                                                                       |
| ----------------------------- | -------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| Is it healthy?                | `kubectl -n bernstein get pods -o wide`                                    | `READY` (readiness probe passes), `RESTARTS` (crashes, liveness failures), the node |
| What happened?                | `kubectl -n bernstein get events --sort-by=.lastTimestamp`, `describe pod` | scheduling, image pulls, probe failures, kills                                      |
| What did the app say?         | `kubectl -n bernstein logs <pod>`, with `--previous` after a restart       | stdout and stderr of the current and the previous container                         |
| Is it short of CPU or memory? | `kubectl -n bernstein top pods --containers`, `kubectl top nodes`          | usage right now (metrics-server runs in `kube-system`)                              |
| Do users see errors?          | `tests/zero-downtime.sh`                                                   | HTTP status and latency, from a client ([ADR 0016](0016-zero-downtime-test.md))     |

The probes are the health model: liveness on `/healthz` (the process answers), readiness on `/readyz` (its dependency is reachable). See [ADR 0008](0008-result-deployment.md), [ADR 0010](0010-worker-deployment.md), [ADR 0011](0011-poll-deployment.md).

## Why no centralized monitoring

- **Cost:**
  - **Fact:** Container Insights charges for the ingestion and the retention of the data it collects. ([Microsoft Learn: Monitoring cost for Container insights](https://learn.microsoft.com/en-us/azure/azure-monitor/containers/container-insights-cost))
  - **Fact:** Azure Managed Grafana is billed per hour and per active user; only the first 30 days of one new instance are free. ([Azure: Managed Grafana pricing](https://azure.microsoft.com/en-us/pricing/details/managed-grafana/))
- **Capacity:** **Fact:** enabling Prometheus metrics and Container Insights installs a containerized Azure Monitor agent in the cluster. ([Microsoft Learn: Enable monitoring for AKS](https://learn.microsoft.com/en-us/azure/azure-monitor/containers/kubernetes-monitoring-enable)) More pods, on nodes whose requests are already close to the one-node capacity a drain needs ([ADR 0018](0018-resource-requests-and-limits.md)).
- A demo watched live during the defense: every health question can be answered on the spot with the commands above.

## Trade-offs (known gaps)

- **No alerting:** nobody is told when the app breaks. We only see it by looking.
- **Logs do not outlive the pod.** **Fact:** the kubelet keeps one terminated container with its logs; an evicted pod loses its logs; Kubernetes has no storage for log data. ([Kubernetes docs: Logging architecture](https://kubernetes.io/docs/concepts/cluster-administration/logging/)) A crash two restarts ago, or a deleted pod, leaves nothing to read.
- **No history:** `kubectl top` shows the current minute, not last night.
- **No application metrics:** the provided apps expose health endpoints only. The vote rate or the queue length must be read by hand (`redis-cli LLEN votes`, a SQL count).

## What production would add

- Managed Prometheus with Grafana dashboards (nodes, pods, the Redis queue through an exporter), and alert rules: a pod not ready for 5 minutes, repeated restarts, a rise in 5xx.
- Container Insights for the logs, with the container log table on the cheaper Basic logs plan ([same cost page](https://learn.microsoft.com/en-us/azure/azure-monitor/containers/container-insights-cost)).
- An availability test from outside on both public URLs.

## Alternatives rejected

- **Container Insights now:** searchable logs that survive pods, at a cost and with an agent on each node, for an app nobody depends on.
- **Self-hosted Prometheus and Grafana** (for example the kube-prometheus-stack Helm chart): free software, but several more pods and a disk for the metrics on our 2 nodes, to install and keep up to date.

## Revisit if

Real users depend on the app, or we commit to an availability target.
