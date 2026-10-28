# ADR 0009: Redis queue in memory, single replica

**Status:** Accepted · **Date:** 2026-10-20 · **Issues:** #20, #35

## Decision

`k8s/redis.yaml` runs `redis:8-alpine` as a `Deployment` with 1 replica and no PVC, behind a `ClusterIP` Service `redis` on port 6379. Persistence off (`--save '' --appendonly no`). Memory capped at `--maxmemory 100mb` with `noeviction` ([ADR 0018](0018-resource-requests-and-limits.md)). `--requirepass "$REDIS_PASSWORD"` is added when `REDIS_PASSWORD` is set in `app-secrets`; empty means no authentication. Runs as the image's `redis` user (uid 999, gid 1000), all capabilities dropped. Baseline rollout (`maxSurge: 1`, `maxUnavailable: 0`, `minReadySeconds: 5`).

## Why

- **Transient buffer, not the source of truth:** Poll pushes votes with `RPUSH`, the worker pops them right away with `BLPOP` and upserts them into PostgreSQL, the only durable store ([ADR 0007](0007-postgres-statefulset.md)). No second Azure Disk to pay for and manage.
- **Fast rescheduling on a drain:** no disk to detach and re-attach (up to a minute or two for an Azure Disk), so the pod starts on the other node in seconds.
- **`ClusterIP` only:** no public IP; reachable through the `redis` DNS name set in `REDIS_HOST`.
- **Optional password, probes that work either way:** **Fact:** `redis-cli` reads the password from `REDISCLI_AUTH`, which avoids `-a` on the command line. ([Redis docs: redis-cli](https://redis.io/docs/latest/develop/tools/cli/)) Both probes run `REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli ping | grep -q PONG`, which works with or without a password. The server still gets it as `--requirepass`, visible in `ps` inside the pod; anyone with that access can read the pod's environment anyway.
- **In memory only:** no snapshot or append-only file, so Redis never forks to save (each fork would duplicate its memory under a 128Mi limit) and writes nothing to the container filesystem. A file there would be lost on restart anyway.
- **Hardening:** `runAsUser: 999`, `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]`.

## Trade-offs

- **Votes can be lost:** if Redis crashes or is rescheduled while votes sit in the list (for instance while PostgreSQL or the worker is down), those votes are lost. Under normal operation the worker drains the queue in milliseconds.
- **When the queue is full** (100 MB, after a long worker or PostgreSQL outage), Redis refuses new votes and Poll answers 500, instead of Redis being OOMKilled with every queued vote ([ADR 0018](0018-resource-requests-and-limits.md)).
- **Single point of failure for Poll:** Poll's `/readyz` pings Redis, so while Redis is down every Poll pod is unready and the page is unreachable (Result keeps working). A Redis restart takes about 4 s (measured on AKS). Rollouts avoid the gap (the new pod is Ready before the old one stops); a node drain does not.
- **During a Redis rollout**, both pods briefly sit behind the Service: Poll may push to the new pod while the worker still pops from the old one. Nothing is lost: when the old pod stops, the worker's connection fails, it exits, restarts and reconnects to the new pod, which holds those votes.

## Alternatives rejected

- **2+ replicas of a plain Deployment:** each pod is an independent Redis. The Service would spread `RPUSH` and `BLPOP` over unrelated queues and strand votes.
- **StatefulSet + PVC (`--appendonly yes`):** keeps queued votes across restarts, but adds disk latency on every vote, a second Azure Disk to bill, and slow re-attachment on a drain.
- **Redis Sentinel / Redis Cluster (Bitnami Helm chart):** real failover, but at least 3 stateful pods and a lot of operations for a small buffer.
