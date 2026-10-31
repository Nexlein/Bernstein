# ADR 0037: Restart policy `Always`, with probes deciding when to restart

**Status:** Accepted · **Date:** 2026-10-31 · **Issues:** none, graded as "Justification - Restart policies"

## Decision

No manifest sets `restartPolicy`: every pod keeps the default, `Always`. A container that stops is restarted in its pod by the kubelet; a pod that is gone (deleted, evicted, its node drained) is replaced by its controller. The liveness probes turn a stuck process into a restart.

## Why

- **Fact:** a Pod's `restartPolicy` is `Always`, `OnFailure` or `Never`, and the default is `Always`. ([Kubernetes docs: Pod lifecycle, Container restarts](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#restart-policy))
- **Fact:** a Deployment's pod template only accepts `restartPolicy: Always`, the default. ([Kubernetes docs: Deployments, Pod Template](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#pod-template)) Our 5 apps are servers or endless loops: any exit, even with code 0, is a failure to repair. PostgreSQL's StatefulSet keeps the same default.
- **Two levels of repair:**
  - the kubelet restarts the container in the same pod, on the same node: the `RESTARTS` column grows;
  - the ReplicaSet or StatefulSet creates a new pod when the pod itself is gone ([guide 9.4](../defense/k8s-study-guide.md#94-un-pod-plante-ou-est-supprimé)).
- **Fact:** the kubelet waits 10 s, 20 s, 40 s, … between restarts, capped at 300 s, and resets the delay after 10 minutes of running. The `ReduceDefaultCrashLoopBackOffDecay` feature gate (1 s up to 60 s) is alpha and off by default since 1.33. ([Kubernetes docs: Pod lifecycle](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#reduced-container-restart-delay))
- **The probes complete the policy.** `Always` only acts when the process exits; a stuck process keeps running. The liveness probe kills it, then `Always` restarts it. Readiness never restarts anything: it only takes the pod out of its Service ([ADR 0008](0008-result-deployment.md), [ADR 0010](0010-worker-deployment.md)).
- **Where we rely on it:**
  - The worker exits when Redis or PostgreSQL drops its connection, then reconnects on its restart ([ADR 0009](0009-redis-queue.md)). Its liveness restarts it when its PostgreSQL connection died without an exit ([ADR 0010](0010-worker-deployment.md)). Seen on AKS on 2026-10-31: after deleting `postgres-0`, the worker had `RESTARTS 1` and kept processing votes.
  - A new version that exits at start goes to `CrashLoopBackOff` and keeps being restarted, while the old pods keep serving ([ADR 0017](0017-deploy-script.md)).

## Trade-offs

- **A container that crashes in a loop is never given up.** It restarts at most every 5 minutes, until a fix or a rollback. It stays visible: `CrashLoopBackOff`, `RESTARTS` growing.
- **The back-off can delay a recovery:** after 3 crashes, the next try waits 40 s, even if the dependency is already back. Result had this problem while it exited on database errors ([ADR 0008](0008-result-deployment.md)).
- **A restart in place keeps the same node.** If the node is the cause (full disk, broken network), the pod stays on it. Only a drain or a node failure moves it.

## Alternatives rejected

- **`OnFailure` or `Never`:** the API refuses them in a Deployment. They are for Jobs, whose task ends. We run no Job: the PostgreSQL backup is a manual `pg_dump` ([ADR 0019](0019-postgres-backup.md)).
- **Exit on every error and let the kubelet restart** (what the provided Result did): a restart loop with back-off instead of a reconnect. Replaced in Result ([ADR 0008](0008-result-deployment.md)). The worker keeps it: no user waits on it, and the votes wait in Redis.
- **Per-container `restartPolicy` and `restartPolicyRules`** (feature gate `ContainerRestartRules`): useful for pods with several containers. Each of our pods has one.
