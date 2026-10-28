# ADR 0008: Result with 2 fixed replicas and a hardened container

**Status:** Accepted · **Date:** 2026-10-20 · **Issues:** #23

## Decision

`k8s/result.yaml` is a `Deployment` with 2 replicas and the baseline rollout (`maxSurge: 1`, `maxUnavailable: 0`, `minReadySeconds: 5`). Liveness on `/healthz`, readiness on `/readyz`. The container runs as uid 1000 with a read-only root filesystem and no Linux capabilities. Its image is the bare name `result`; `scripts/deploy.sh` sets registry and tag ([ADR 0017](0017-deploy-script.md)). No HPA.

## Why

- **2 replicas:** the Service spreads users over both, and a rollout or a drained node always leaves one pod serving.
- **Fact:** with `maxUnavailable: 0`, a rollout never goes below the desired number of available pods; `maxSurge: 1` adds the new pod first; `minReadySeconds` counts a new pod as available only after it stayed Ready that long. ([Kubernetes docs: Rolling update Deployment](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#rolling-update-deployment))
- **Probes match the app:** `/healthz` only says the process is alive, so the liveness probe never restarts Result because of the database. `/readyz` runs `SELECT 1` on PostgreSQL: a pod that lost the database gets no traffic until it is back. The process itself does exit when it loses the database (see Trade-offs).
- **No HPA, on purpose:** each pod runs one `SELECT ... GROUP BY` per second and broadcasts it to its WebSocket clients, so load barely grows with viewers. WebSocket connections stay on the pod they opened on, so a pod added by an HPA would only get new visitors. Poll gets the HPA instead (#33).
- **Port 80 as non-root:** **Fact:** `net.ipv4.ip_unprivileged_port_start` is a "safe" sysctl, allowed by default since Kubernetes 1.22; setting it to `0` lets any user bind ports below 1024 in the pod's network namespace. ([Kubernetes docs: sysctls](https://kubernetes.io/docs/tasks/administer-cluster/sysctl-cluster/#safe-and-unsafe-sysctls)) Some runtimes already do this; declaring it makes the pod behave the same on any cluster.
- **Hardening:** no privilege escalation, all capabilities dropped, read-only root filesystem. Result writes nothing to disk, so a compromised process cannot drop files in the container.
- **Image set at deploy time:** the evaluator passes their registry to `scripts/deploy.sh`, which also sets the git SHA tag ([ADR 0005](0005-image-tags-git-sha.md), [ADR 0017](0017-deploy-script.md)). No manifest edit.

## Trade-offs

- If PostgreSQL is down, both pods fail readiness and leave the Service: the page is unreachable instead of showing stale counts. Acceptable: without the database there is nothing to show, and Poll keeps working.
- **Result restarts each time PostgreSQL restarts.** The provided `server.js` calls `process.exit(1)` when its database connection fails (`client.on('error')`) or a query fails, then waits for the database on its next start (`async.retry`, up to 1000 tries 1 s apart). Measured on AKS (#96), by deleting `postgres-0`:
  - Both Result pods stopped 1 s later: `Exit Code: 1`, last log line `Db connection error: error: terminating connection due to administrator command`.
  - PostgreSQL moved to the other node and was back in 27 s; Result was unavailable 38 s (probe inside the cluster) to 43 s (until both pods were Ready). The new containers started at once, but their first connection only succeeded 11 s after PostgreSQL was Ready, with no `Waiting for db` line: the attempt stayed pending instead of failing. Cause not established.
  - PostgreSQL restarted on the same node in 8 s; Result was Ready again 13 s after the deletion.
  - **Fact:** the kubelet restarts a crashed container with an exponential back-off (10 s, 20 s, 40 s, …) capped at 5 minutes, and resets it after 10 minutes of running. ([Kubernetes docs: Pod lifecycle](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#container-restarts)) Seen in the second test: the restart waited 12 s, 5 s after PostgreSQL was already back. Several PostgreSQL restarts within a few minutes can keep Result down longer than PostgreSQL itself.
- Open WebSocket connections are cut when their pod stops during a rollout. socket.io reconnects by itself, and the client only uses the WebSocket transport, so no sticky sessions are needed.
- `envFrom: app-config` also injects `REDIS_HOST`, unused by Result. Harmless, and simpler than listing each key.

## Alternatives rejected

- **1 replica:** any rollout or node drain would cut the page.
- **HPA:** see Why.
- **Readiness on `/healthz` too:** pods would keep getting traffic while unable to answer with data.
- **Reconnect instead of exiting** (a `pg.Pool` that retries): no restart and no back-off, but our own code inside the provided app, for no visible gain: Result is unready anyway while PostgreSQL is down. Revisit if PostgreSQL restarts often.
