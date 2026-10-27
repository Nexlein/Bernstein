# ADR 0008: Result with 2 fixed replicas and a hardened container

**Status:** Accepted · **Date:** 2026-10-20 · **Issues:** #23

## Decision

`k8s/result.yaml` is a `Deployment` with 2 replicas and the baseline rollout (`maxSurge: 1`, `maxUnavailable: 0`, `minReadySeconds: 5`). Liveness on `/healthz`, readiness on `/readyz`. The container runs as uid 1000 with a read-only root filesystem and no Linux capabilities. Its image is the bare name `result`; `scripts/deploy.sh` sets registry and tag ([ADR 0017](0017-deploy-script.md)). No HPA.

## Why

- **2 replicas:** the Service spreads users over both, and a rollout or a drained node always leaves one pod serving.
- **Fact:** with `maxUnavailable: 0`, a rollout never goes below the desired number of available pods; `maxSurge: 1` adds the new pod first; `minReadySeconds` counts a new pod as available only after it stayed Ready that long. ([Kubernetes docs: Rolling update Deployment](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#rolling-update-deployment))
- **Probes match the app:** `/healthz` only says the process is alive, so a database outage does not cause a restart loop. `/readyz` runs `SELECT 1` on PostgreSQL: a pod that lost the database gets no traffic until it is back.
- **No HPA, on purpose:** each pod runs one `SELECT ... GROUP BY` per second and broadcasts it to its WebSocket clients, so load barely grows with viewers. WebSocket connections stay on the pod they opened on, so a pod added by an HPA would only get new visitors. Poll gets the HPA instead (#33).
- **Port 80 as non-root:** **Fact:** `net.ipv4.ip_unprivileged_port_start` is a "safe" sysctl, allowed by default since Kubernetes 1.22; setting it to `0` lets any user bind ports below 1024 in the pod's network namespace. ([Kubernetes docs: sysctls](https://kubernetes.io/docs/tasks/administer-cluster/sysctl-cluster/#safe-and-unsafe-sysctls)) Some runtimes already do this; declaring it makes the pod behave the same on any cluster.
- **Hardening:** no privilege escalation, all capabilities dropped, read-only root filesystem. Result writes nothing to disk, so a compromised process cannot drop files in the container.
- **Image set at deploy time:** the evaluator passes their registry to `scripts/deploy.sh`, which also sets the git SHA tag ([ADR 0005](0005-image-tags-git-sha.md), [ADR 0017](0017-deploy-script.md)). No manifest edit.

## Trade-offs

- If PostgreSQL is down, both pods fail readiness and leave the Service: the page is unreachable instead of showing stale counts. Acceptable: without the database there is nothing to show, and Poll keeps working.
- Open WebSocket connections are cut when their pod stops during a rollout. socket.io reconnects by itself, and the client only uses the WebSocket transport, so no sticky sessions are needed.
- `envFrom: app-config` also injects `REDIS_HOST`, unused by Result. Harmless, and simpler than listing each key.

## Alternatives rejected

- **1 replica:** any rollout or node drain would cut the page.
- **HPA:** see Why.
- **Readiness on `/healthz` too:** pods would keep getting traffic while unable to answer with data.
