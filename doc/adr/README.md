# Architecture Decision Records

One short file per technical choice: what we decided, why, what it costs and what we rejected. Written for us, to answer defense questions fast: find the question below, open the ADR, read the Decision and Why.

- Lines marked **Fact:** link their source. Everything else is our own reasoning, to defend at the review.
- New decision: copy [`0000-template.md`](0000-template.md), take the next number, add a row here.
- A decision changes (a new measurement, a clarified limit): edit its ADR. A decision is reversed: write a new ADR and mark the old one `Superseded by ADR NNNN`.

Line-by-line explanation of the manifests (in French): [`../defense/k8s-study-guide.md`](../defense/k8s-study-guide.md). Cluster and registry setup: [`../setup/cluster-setup.md`](../setup/cluster-setup.md).

## Index

| ADR                                        | Topic             | Decision                                                                     | Questions it answers                                                                      |
| ------------------------------------------ | ----------------- | ---------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| [0001](0001-aks-cluster.md)                | Cluster           | AKS Free tier, 2 × `Standard_B2s_v2` nodes in `spaincentral`                 | Why AKS? Why 2 nodes? Why this VM size and region? How do we save credits?                |
| [0002](0002-acr-registry.md)               | Registry          | ACR Basic, attached to AKS: no pull secret                                   | Is the registry private? How does the cluster pull images? Why not Docker Hub?            |
| [0003](0003-kustomize.md)                  | Manifests         | Kustomize, flat `k8s/`: one file per app, one per policy kind                | Why not Helm? How is the image tag set? Why not factor the repeated YAML?                 |
| [0004](0004-public-access-loadbalancer.md) | Public access     | One `LoadBalancer` Service each for Poll and Result, no Ingress              | Why no Ingress? How does traffic reach a pod? Why `externalTrafficPolicy: Cluster`?       |
| [0005](0005-image-tags-git-sha.md)         | Image tags        | Short git commit SHA                                                         | Why not `latest`? How do we know which version runs?                                      |
| [0006](0006-secrets-secretgenerator.md)    | Secrets           | `secretGenerator` from the gitignored `k8s/secrets.env`                      | Where does the evaluator set the password? Is a Secret encrypted? Why not Sealed Secrets? |
| [0007](0007-postgres-statefulset.md)       | PostgreSQL        | `StatefulSet`, 1 replica, 1 GiB Azure Disk, `ClusterIP`                      | Do votes survive a restart? What happens on a drain? How is the schema created?           |
| [0008](0008-result-deployment.md)          | Result            | `Deployment`, 2 replicas, no HPA, read-only root filesystem                  | Why no HPA? What if PostgreSQL is down? What happens to WebSockets during a rollout?      |
| [0009](0009-redis-queue.md)                | Redis             | `Deployment`, 1 replica, in memory only, `ClusterIP`                         | Why not 2 replicas? Why no persistence? Can votes be lost?                                |
| [0010](0010-worker-deployment.md)          | Worker            | `Deployment`, 1 replica, no Service, liveness on `/readyz`                   | Why no Service? Two workers during a rollout? Why liveness on `/readyz`?                  |
| [0011](0011-poll-deployment.md)            | Poll              | `Deployment`, 2 replicas, read-only root filesystem, in-memory `/tmp`        | Why an `emptyDir` on `/tmp`? Sticky sessions? What if Redis is down?                      |
| [0012](0012-graceful-shutdown.md)          | Shutdown          | `preStop` sleep 5 s; grace period 45 s (Poll), 30 s (Result)                 | Why sleep before `SIGTERM`? How are the grace periods sized?                              |
| [0013](0013-pod-anti-affinity.md)          | Spreading         | Preferred pod anti-affinity per node, counting only pods of the same version | Why preferred and not required? What does `matchLabelKeys` fix?                           |
| [0014](0014-pod-disruption-budgets.md)     | Disruption budget | `minAvailable: 1` on Poll and Result                                         | What happens on `kubectl drain`? Why no PDB on PostgreSQL or Redis?                       |
| [0015](0015-poll-gunicorn-threads.md)      | Poll workers      | `GUNICORN_CMD_ARGS="--threads 4"`                                            | Why did Poll time out? Why threads and not more workers?                                  |

## By file

| File                                  | ADRs                                                                                                                                                                                     |
| ------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Azure resources (cluster, registry)   | [0001](0001-aks-cluster.md), [0002](0002-acr-registry.md)                                                                                                                                |
| `k8s/kustomization.yaml`              | [0003](0003-kustomize.md), [0005](0005-image-tags-git-sha.md), [0006](0006-secrets-secretgenerator.md)                                                                                   |
| `k8s/secrets.env.example`             | [0006](0006-secrets-secretgenerator.md)                                                                                                                                                  |
| `k8s/postgres.yaml`, `k8s/schema.sql` | [0007](0007-postgres-statefulset.md)                                                                                                                                                     |
| `k8s/redis.yaml`                      | [0009](0009-redis-queue.md)                                                                                                                                                              |
| `k8s/worker.yaml`                     | [0010](0010-worker-deployment.md)                                                                                                                                                        |
| `k8s/poll.yaml`                       | [0004](0004-public-access-loadbalancer.md), [0011](0011-poll-deployment.md), [0012](0012-graceful-shutdown.md), [0013](0013-pod-anti-affinity.md), [0015](0015-poll-gunicorn-threads.md) |
| `k8s/result.yaml`                     | [0004](0004-public-access-loadbalancer.md), [0008](0008-result-deployment.md), [0012](0012-graceful-shutdown.md), [0013](0013-pod-anti-affinity.md)                                      |
| `k8s/pdb.yaml`                        | [0014](0014-pod-disruption-budgets.md)                                                                                                                                                   |

## Known limits

What breaks, and where we explain why we accept it:

- **PostgreSQL has 1 replica.** Draining its node made Result fail 47 requests over 39 s while the disk moved. Only a replicated database would fix it. [0007](0007-postgres-statefulset.md), [0014](0014-pod-disruption-budgets.md)
- **Redis has 1 replica, in memory.** A Redis restart (about 4 s) makes Poll unready; votes still queued in Redis are lost if it crashes. [0009](0009-redis-queue.md)
- **The worker has no `SIGTERM` hook.** A vote popped in the sub-millisecond window before its upsert is lost if the pod stops then. [0010](0010-worker-deployment.md)
- **Free tier and B-series nodes.** No API server SLA, and a long load test can use up the CPU credits. [0001](0001-aks-cluster.md)
