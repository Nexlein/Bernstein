# ADR 0011: Poll with 2 replicas, read-only root filesystem and in-memory `/tmp`

**Status:** Accepted · **Date:** 2026-10-20 · **Issues:** #22

## Decision

`k8s/poll.yaml` is a `Deployment` with 2 replicas and the baseline rollout (`maxSurge: 1`, `maxUnavailable: 0`, `minReadySeconds: 5`). Liveness on `/healthz`, readiness on `/readyz`. Runs as uid 10001 with `net.ipv4.ip_unprivileged_port_start=0`, a read-only root filesystem, an in-memory `emptyDir` at `/tmp` with `HOME=/tmp`, and all capabilities dropped. Image is the bare name `poll`; `scripts/deploy.sh` sets registry and tag ([ADR 0017](0017-deploy-script.md)). Gunicorn threads: [ADR 0015](0015-poll-gunicorn-threads.md).

## Why

- **2 replicas:** traffic is spread over both pods, and a rollout or a single-node maintenance always leaves one serving.
- **Stateless:** the voter identity (`voter_id`) is a browser cookie, and each `POST /` pushes the vote straight to Redis (`RPUSH votes`). Any replica serves any request, no sticky sessions.
- **Probes match the dependency:** `/healthz` only checks that Gunicorn/Flask answers, so a Redis restart does not trigger a restart loop. `/readyz` pings Redis: a pod that cannot reach it leaves the Service endpoints until it is back.
- **Read-only root with a writable `/tmp`:** **Fact:** Gunicorn creates a heartbeat file (`wgunicorn-*`) per worker in `/tmp` ([Gunicorn FAQ: Worker heartbeat](https://docs.gunicorn.org/en/stable/faq.html#how-do-i-avoid-blocking-os-fchmod-calls)) and, since Gunicorn 25, a control socket in `$HOME/.gunicorn/gunicorn.ctl` ([Gunicorn docs: Control socket](https://docs.gunicorn.org/en/stable/settings.html#control-socket)). The `emptyDir` at `/tmp` and `HOME=/tmp` let it create both while `/app` and the rest stay read-only.
- **`medium: Memory` (tmpfs, capped at 16Mi):** the same FAQ warns that heartbeat updates on a disk-backed `/tmp` can block workers, and a default `emptyDir` lives on the node's disk. Its content counts toward the memory limit; it only holds a few empty files and a socket.
- **Hardening and port 80 as non-root:** uid 10001 (from `poll/Dockerfile`), `allowPrivilegeEscalation: false`, all capabilities dropped, and the safe sysctl to bind port 80 (see [ADR 0008](0008-result-deployment.md)).

## Trade-offs

- If Redis is down, both pods fail `/readyz` and leave the Service ([ADR 0009](0009-redis-queue.md)).
- `envFrom: app-config` also injects `POSTGRES_*`, unused by Poll. Harmless, and the config stays the same for every workload.

## Alternatives rejected

- **1 replica:** a rollout or node drain would drop requests.
- **`readOnlyRootFilesystem: false`:** simpler for Gunicorn's files, but leaves the app filesystem writable if compromised.
- **`OPTION_A..D` in `app-config`:** the defaults (`Ansible`, `Chef`, `Puppet`, `SaltStack`) are in `app.py` and hardcoded in Result's `index.html`. Overriding them only for Poll would make the two apps show different labels.
