# ADR 0018: Resource requests and limits

**Status:** Accepted · **Date:** 2026-10-27 · **Issues:** #35

## Decision

Every container declares CPU and memory requests and limits (our baseline rule). Limits are 2 to 6 times the requests, so every pod is in the `Burstable` QoS class. Redis also caps its own memory under its limit: `--maxmemory 100mb --maxmemory-policy noeviction`.

| Container    | CPU request → limit | Memory request → limit | Measured idle | Measured under load |
| ------------ | ------------------- | ---------------------- | ------------- | ------------------- |
| poll (× 2)   | 50m → 300m          | 96Mi → 256Mi           | 2m, 85Mi      | 100m, 88Mi          |
| result (× 2) | 50m → 300m          | 96Mi → 256Mi           | 2m, 24Mi      | 19m, 33Mi           |
| worker       | 100m → 500m         | 192Mi → 384Mi          | 3m, 43Mi      | 18m, 53Mi           |
| redis        | 50m → 250m          | 64Mi → 128Mi           | 5m, 3Mi       | 19m, 3Mi            |
| postgres     | 100m → 500m         | 256Mi → 512Mi          | 5m, 29Mi      | 17m, 29Mi           |

Measured with `kubectl top pods` on AKS on 2026-10-27. Load: 2 minutes of `GET` on both apps (about 24 per second each) plus 4 vote loops (4439 votes in 120 s, about 37 per second). Every request answered, every vote stored, queue back to 0.

## Why

- **Requests are what the scheduler reserves; limits are the ceiling.** **Fact:** above its CPU limit a container is throttled; above its memory limit it can be killed (`OOMKilled`). ([Kubernetes docs: Resource management for pods and containers](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/))
- **Everything fits on one node, which a drain needs.** A node gives pods 1900m CPU and about 5.6 GiB (`allocatable`). Both nodes together request 1712m and 2.4 GiB, `kube-system` included (measured with `kubectl describe nodes`).
- **Poll** uses the most CPU (100m under load: Python renders the page on every request) and about its memory request (88Mi for 2 Gunicorn processes). The 300m limit leaves 3 times the measured peak. The HPA (#33) will scale on CPU relative to the request.
- **Result** uses less than requested (33Mi) but keeps Poll's values: Node.js memory grows with open WebSocket connections, and identical values keep the two manifests aligned ([ADR 0003](0003-kustomize.md)).
- **Worker (JVM), measured in the pod:** the JVM reads the container limit (`memory.max` = 384Mi) and picks a **126 MiB maximum heap** and the **Serial GC** (it sees 1 CPU from the 500m limit). The rest of the limit covers metaspace, code cache, threads and client buffers. On a rollout, the new worker was Ready 5 s after its container started: the CPU limit does not slow the JVM start much.
- **Postgres** uses 29Mi with a small table, but reserves a 128MB cache (`shared_buffers`, default, measured with `SHOW shared_buffers`) that fills as data is read, and allows 100 connections. The request covers the full cache.
- **"How would we limit Redis's CPU?"** It already is: `limits.cpu: 250m`, throttled above. Redis runs commands on one main thread anyway.
- **Redis `maxmemory 100mb` with `noeviction`.** Without it, a queue that keeps growing (worker or PostgreSQL down for long) reaches the 128Mi limit: Redis is OOMKilled, every queued vote is lost, and Poll is unready while it restarts. **Fact:** with `noeviction`, new values are not saved once the limit is reached. ([Redis docs: Key eviction](https://redis.io/docs/latest/develop/reference/eviction/)) **Tested on AKS** with a full Redis:
  - the write is refused (`OOM command not allowed`), and Poll answers 500 to a vote (it logs `OutOfMemoryError`);
  - the page and `/readyz` still answer 200;
  - reads and pops still work, so the worker can empty the queue.
  - 100mb leaves 28 MiB under the limit for Redis's own overhead.
- **Redis rollout with the new arguments, tested under load:** 0 errors on `GET`, and all 1755 votes sent during the switch were stored.

## Trade-offs

- Result, worker and Postgres request more than they use today: capacity reserved for nothing. Acceptable while one node still holds everything.
- **Fact:** under node memory pressure, `Burstable` pods are evicted before `Guaranteed` ones. ([Kubernetes docs: Pod QoS classes](https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/)) `Guaranteed` would need requests equal to limits: 2 to 6 times more reserved.
- A CPU limit can throttle a short burst (a JVM start) even on an idle node. The measured peaks stay far under the limits.
- With Redis full, new votes fail with a 500 instead of waiting. That only happens after a long worker or PostgreSQL outage.
- Measured on a demo load. A real launch needs a load test at the expected traffic.

## Alternatives rejected

- **No CPU limits, only requests:** avoids throttling, and many teams do it. But our baseline requires limits, and they bound a runaway process on a 2-vCPU node.
- **`Guaranteed` QoS (requests = limits):** best protection from eviction, at the cost of reserving the limits.
- **A Redis eviction policy (`allkeys-lru`, …):** would silently delete queued votes.
- **`-Xmx` for the worker:** the JVM already sizes its heap from the limit, and a fixed `-Xmx` must be kept in sync with the limit by hand, in the provided Dockerfile.
- **VerticalPodAutoscaler:** recommends values from real usage. One more component for 5 containers we can measure ourselves.
