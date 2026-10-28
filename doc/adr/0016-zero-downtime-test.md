# ADR 0016: Zero-downtime test with a curl loop

**Status:** Accepted · **Date:** 2026-10-27 · **Issues:** #29, #30, #74, #107

## Decision

`tests/zero-downtime.sh` sends `GET /` to Poll and Result in parallel loops (2 per app by default, a new `curl` and TCP connection per request, 5 s timeout) and fails on any error: a non-2xx status or a `curl` failure (connection refused or reset, timeout). It runs for a fixed time, or wraps the update command (`-- <command>`) and keeps requesting 15 s after it ends. It prints each error as it happens, then requests, errors and latency (p50, p99, max) per app, and exits 1 on any error.

`--from cluster` sends the same requests from a pod (`curlimages/curl`) in its own namespace, `zero-downtime`, to the `poll` and `result` Services. `--from both` runs both at once, with one summary line per app and source (`poll`, `poll@cluster`…). The script deletes the pod at the end.

## Why

- The subject grades the update by requesting the app continuously: any error fails it ([subject](../subject/SUBJECT.md)). The script does what the evaluator will do, and gives a yes/no answer.
- Only `curl` and bash (3.2+, the macOS default): nothing to install on the evaluator's machine or in CI.
- A new connection per request is the hard case: each request goes through the Azure Load Balancer and kube-proxy to a pod, so a pod still listed while it stops would show as an error.
- Both apps at once: a rollout of one must not disturb the other.
- **`-- <command>` mode:** the same script serves the defense live update (#38), the AKS checks (#30) and CI on kind (#74): every PR runs it, with `--from cluster`, during a rollout of Poll and Result and during the drain of a worker ([ADR 0031](0031-ci-kind-e2e.md)). The 15 s after the command cover old pods still stopping: `kubectl rollout status` returns while they run their `preStop` sleep and drain ([ADR 0012](0012-graceful-shutdown.md)).
- A check before the test fails fast if an app is already down, so the rollout is not blamed for it.
- `GET` only: a `POST` would add fake votes, visible on Result during the defense.
- **Requests from inside the cluster (#107):** a weak client network fails the test even at rest (Trade-offs). The pod's requests do not cross it: if they pass while the local ones fail, every request reached a pod and was served. `--from both` splits a failure live, in front of the evaluator.
- **Same measure in the pod:** the same `curl` options and output line as the local loop, so the same summary and exit codes. curl rather than busybox `wget`, which gives neither the status code nor the latency.
- **Its own namespace:** our NetworkPolicies deny any client inside `bernstein` ([ADR 0025](0025-network-policies.md)). The namespace enforces the `restricted` Pod Security Standard like ours, and the pod complies: non-root, seccomp, no capabilities, read-only root filesystem ([ADR 0027](0027-pod-security-standards.md)).
- **No pod left behind:** the script's exit trap deletes it, also after Ctrl-C. If the script is killed outright, `activeDeadlineSeconds: 3600` stops the pod after 1 h.
- **Checked both ways:**
  - Local Docker Compose, no update: 0 errors.
  - Local, `docker compose restart poll` (no rolling update there): 26 Poll errors (18 connections refused, 8 resets), exit 1. The script does catch an outage.
  - **AKS, `kubectl rollout restart` of Poll and Result:** 0 errors in 975 requests with 2 loops per app, and 0 errors in 1996 requests with 4 loops. p99 under 0.42 s.
  - **AKS, `--from both` (#107):**
    - Same rollout restart: 0 errors in 994 requests from here and 2375 from the pod. p99 0.11 s from here, 0.03 s from the pod.
    - Poll scaled to 0 for 8 s: errors on both sides (81 from here, 137 from the pod, `connection reset`), printed live, exit 1. Result untouched: 0 errors.
    - A wrong `NAMESPACE`: `http://poll.nope/ answers 000. Nothing to measure.`, exit 2.
    - Ctrl-C (`SIGINT` to the process group) while the pod was created, while it started, and while it requested: the script stopped within 0.7 s each time and no pod was left.

## Trade-offs

- The WebSocket of Result is not tested: its connection is cut when its pod stops, and socket.io reconnects ([ADR 0008](0008-result-deployment.md)). `curl` only sees the page.
- Browsers reuse connections (keep-alive); the script opens a new one per request. A reused connection to a stopping pod is not tested.
- **The test machine's connection is part of the measurement.** A busy one (a big image push, a system update downloading) slowed requests until some timed out, on Poll and Result at the same seconds, while only one app was updating. Seen twice on our machine; the rerun on an idle connection passed. Errors on both apps at once point to the client, not the rollout.
- **A weak connection fails even at rest.** On 2026-10-28, with nothing deploying, runs from a home connection had 0.2 to 1.6 % connect timeouts (`curl exit 28` after 2 s), not aligned between the apps; 1 in 467 connections to `1.1.1.1` failed at the same time. A probe inside the cluster (busybox `wget` on the Services, every 0.1 s) saw 0 errors in 11 500 requests over the same runs and rollouts. So the test runs once without a command first, and must pass before the graded run (`DEPLOY.md` section 4). The graded run uses `--from both`.
- **The requests from the pod skip the Azure Load Balancer:** they go to the Services' cluster IPs. They prove the pods and the endpoints, not the public path. The graded proof stays the requests from here; the `@cluster` lines explain their errors.
- `--from cluster` needs `kubectl` and nodes that can pull from Docker Hub, like the `postgres` and `redis` images. The empty `zero-downtime` namespace stays after the test.
- Modest load (about 12 requests per second per app with 2 loops, on AKS): it proves that no request fails during an update, not how much load the apps take.

## Alternatives rejected

- **hey / vegeta / k6:** more load and richer reports, but one more tool for the evaluator and CI to install. Load is not what is graded.
- **A `while curl` one-liner typed at the defense:** no summary, no exit code, easy to get wrong live.
- **busybox `wget` in the pod:** no status code or latency to report, unlike the local loop.
- **`kubectl run --rm -i` attached to the pod:** its output and Ctrl-C would mix with the local loops; a detached pod and `kubectl logs` keep the two apart.
- **Only watching `kubectl rollout status` or the available replicas:** proves that Kubernetes kept pods available, not that no request failed while endpoints changed ([ADR 0012](0012-graceful-shutdown.md)).
