# ADR 0008: Result with 2 fixed replicas and a hardened container

**Status:** Accepted · **Date:** 2026-10-20, database outages 2026-10-29 · **Issues:** #23

## Decision

`k8s/result.yaml` is a `Deployment` with 2 replicas and the baseline rollout (`maxSurge: 1`, `maxUnavailable: 0`, `minReadySeconds: 5`). Liveness on `/healthz`, readiness on `/readyz`. The container runs as uid 1000 with a read-only root filesystem and no Linux capabilities. Its image is the bare name `result`; `scripts/deploy.sh` sets registry and tag ([ADR 0017](0017-deploy-script.md)). No HPA.

Since 2026-10-29 (PR #134), `server.js` survives a database outage: a connection pool retries every second instead of exiting, and `/readyz` answers 200 once the database has answered since the start.

## Why

- **2 replicas:** the Service spreads users over both, and a rollout or a drained node always leaves one pod serving.
- **Fact:** with `maxUnavailable: 0`, a rollout never goes below the desired number of available pods; `maxSurge: 1` adds the new pod first; `minReadySeconds` counts a new pod as available only after it stayed Ready that long. ([Kubernetes docs: Rolling update Deployment](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#rolling-update-deployment))
- **Probes match the app:** `/healthz` only says the process is alive, so the liveness probe never restarts Result because of the database. `/readyz` says the pod reached the database once: a new pod with a wrong password or host never becomes Ready, so its rollout stops and the old pods keep serving ([ADR 0017](0017-deploy-script.md)). A later outage keeps the pod in the Service: the page (`views/index.html`) is a static file and loads without the database.
- **Reconnect instead of exiting:** the provided `server.js` called `process.exit(1)` when its connection broke or a query failed, and its `/readyz` ran `SELECT 1`. Each PostgreSQL restart or move took the page down: 47 failed requests over 39 s while draining PostgreSQL's node ([ADR 0014](0014-pod-disruption-budgets.md)), 49 s during an image update of PostgreSQL ([ADR 0007](0007-postgres-statefulset.md)). It was the only failure we measured on Result. Now a `pg.Pool` opens a new connection when one breaks; a failed query is logged (`Waiting for db: …`) and retried 1 s later. `connectionTimeoutMillis` and `query_timeout` (5 s) stop a connection to a node that died from hanging until TCP gives up.
- **No HPA, on purpose:** each pod runs one `SELECT ... GROUP BY` per second and broadcasts it to its WebSocket clients, so load barely grows with viewers. WebSocket connections stay on the pod they opened on, so a pod added by an HPA would only get new visitors. Poll gets the HPA instead (#33).
- **Port 80 as non-root:** **Fact:** `net.ipv4.ip_unprivileged_port_start` is a "safe" sysctl, allowed by default since Kubernetes 1.22; setting it to `0` lets any user bind ports below 1024 in the pod's network namespace. ([Kubernetes docs: sysctls](https://kubernetes.io/docs/tasks/administer-cluster/sysctl-cluster/#safe-and-unsafe-sysctls)) Some runtimes already do this; declaring it makes the pod behave the same on any cluster.
- **Hardening:** no privilege escalation, all capabilities dropped, read-only root filesystem. Result writes nothing to disk, so a compromised process cannot drop files in the container.
- **Image set at deploy time:** the evaluator passes their registry to `scripts/deploy.sh`, which also sets the git SHA tag ([ADR 0005](0005-image-tags-git-sha.md), [ADR 0017](0017-deploy-script.md)). No manifest edit.

## Trade-offs

- **While PostgreSQL is away, the page loads but the scores freeze**, until the database answers again. The votes wait in Redis meanwhile ([ADR 0009](0009-redis-queue.md)). Measured on AKS on 2026-10-29 (`result:8c00f45`), under `tests/zero-downtime.sh --from both`:
  - Draining the node with PostgreSQL, Redis, the worker, one Poll and one Result pod: **0 errors** on Result (546 requests from outside, 1315 from inside the cluster) and on Poll. PostgreSQL was back on the other node in 27 s. Before: 47 failed requests over 39 s.
  - Deleting `postgres-0`: back on the same node in 11 s, **0 errors** on Result (369 and 866 requests). Before (#96): Result was Ready again 13 s after the deletion, or unavailable 38 to 43 s when PostgreSQL changed node.
  - Both Result pods kept `RESTARTS 0`. Their logs show `Db connection error: error: terminating connection due to administrator command`, then `Waiting for db: Connection terminated due to connection timeout` every 6 s (5 s timeout, 1 s pause) until PostgreSQL was back.
- **A pod started while PostgreSQL is down stays unready** until the database answers. A rollout of Result during a database outage waits, the old pods keep serving, and `deploy.sh` reports it failed after 2 minutes ([ADR 0017](0017-deploy-script.md)).
- **Our code inside the provided app:** `server.js` gains 26 lines and loses 45 (comments included), and its `async` dependency is gone. Kept small on purpose: no new dependency, no manifest change.
- Open WebSocket connections are cut when their pod stops during a rollout. socket.io reconnects by itself, and the client only uses the WebSocket transport, so no sticky sessions are needed.
- `envFrom: app-config` also injects `REDIS_HOST`, unused by Result. Harmless, and simpler than listing each key.

## Alternatives rejected

- **1 replica:** any rollout or node drain would cut the page.
- **HPA:** see Why.
- **Readiness on `/healthz` too:** a new pod with a wrong password would become Ready and replace the old ones, showing scores stuck at zero.
- **Keep the provided code** (exit on any database error, `/readyz` on `SELECT 1`): rejected on 2026-10-29 after the measurements above. Each PostgreSQL restart restarted both Result pods. **Fact:** the kubelet restarts a crashed container with an exponential back-off (10 s, 20 s, 40 s, …) capped at 5 minutes, and resets it after 10 minutes of running. ([Kubernetes docs: Pod lifecycle](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#container-restarts)) Several PostgreSQL restarts within a few minutes could keep Result down longer than PostgreSQL itself.
- **Reconnect, but keep `/readyz` on `SELECT 1`:** no more restarts, but both pods would still leave the Service while PostgreSQL is away, and the page would fail instead of showing the last scores.
- **A replicated PostgreSQL:** would also keep the scores moving, for much more machinery ([ADR 0007](0007-postgres-statefulset.md)).
