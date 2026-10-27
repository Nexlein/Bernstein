# ADR 0010: Worker as a single-replica background consumer

**Status:** Accepted · **Date:** 2026-10-20 · **Issues:** #21, #63

## Decision

`k8s/worker.yaml` runs the worker as a `Deployment` with 1 replica and no Service. Baseline rollout (`maxSurge: 1`, `maxUnavailable: 0`, `minReadySeconds: 5`). Both probes call `GET /readyz` on port 80. Runs as uid 10001 with `net.ipv4.ip_unprivileged_port_start=0`, a read-only root filesystem and all capabilities dropped. Image is the bare name `worker`; `scripts/deploy.sh` sets registry and tag ([ADR 0017](0017-deploy-script.md)).

## Why

- **1 replica is enough and saves RAM:** the worker runs on a Java 25 JVM (`eclipse-temurin:25-jre`), heavier than Python or Node.js (`requests: 192Mi`, `limits: 384Mi`). Each vote is one `BLPOP` and one single-row upsert. Tested on AKS: a vote pushed to Redis is in PostgreSQL within a second.
- **Safe rollout overlap:** the new pod must pass `/readyz` for 5 s before the old one stops, so two workers briefly consume the queue. **Fact:** `BLPOP` is atomic and gives each popped element to a single client ([Redis docs: BLPOP](https://redis.io/docs/latest/commands/blpop/)), and `INSERT ... ON CONFLICT (id) DO UPDATE` is idempotent: no vote is counted twice.
- **No Service:** nothing connects to the worker; it only opens outbound connections to `redis:6379` and `postgres:5432`. Only the kubelet reaches port 80 on the pod IP, for the probes.
- **`/readyz` checks both dependencies:** Redis `PING` and `dbConn.isValid(2)` on PostgreSQL. A new pod only replaces the old one once both are connected.
- **Liveness also on `/readyz`, unlike Poll and Result (#63):** observed on AKS, after a PostgreSQL restart the worker stayed `0/1` as long as no vote arrived. Its JDBC connection was dead, `Worker.java` only notices on write, and `/healthz` kept answering 200. With liveness on `/readyz` (`initialDelaySeconds: 30`, `periodSeconds: 10`, `failureThreshold: 6`), the kubelet restarts it after about a minute and it reconnects. Harmless: no Service, no users, and a vote popped mid-failure is pushed back with `LPUSH` before exit. Poll and Result keep liveness on `/healthz`: restarting them during an outage would cut their users for nothing.
- **Hardening:** `runAsUser: 10001` (the `app` user of `worker/Dockerfile`), `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `capabilities.drop: ["ALL"]`.

## Trade-offs

- **Pause on crash or drain:** vote processing stops for a few seconds until the new pod starts. No vote is lost: they wait in Redis.
- **Restarts during a long outage:** a PostgreSQL or Redis outage longer than about a minute makes the worker restart repeatedly (back-off up to 5 min). The `RESTARTS` counter grows: expected, not a bug.
- **No `SIGTERM` hook in `Worker.java`:** a failed upsert (`SQLException`) pushes the vote back with `LPUSH`. But a `SIGTERM` in the sub-millisecond window between `BLPOP` and `executeUpdate()` loses that one vote. Most of the time the worker is idle inside `BLPOP`, with nothing popped.
- **Order not guaranteed during the overlap:** a voter who changes their vote twice within a few milliseconds could see the older vote committed last. Only during the few seconds of a worker rollout; they can vote again.

## Alternatives rejected

- **2+ replicas all the time:** safe thanks to atomic `BLPOP` and idempotent upserts, but doubles JVM memory (~400 MiB) on our 2 student nodes for a queue one pod drains in milliseconds.
- **A `ClusterIP` Service:** nothing calls the worker over HTTP.
