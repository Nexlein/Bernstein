# ADR 0016: Zero-downtime test with a curl loop

**Status:** Accepted · **Date:** 2026-10-27 · **Issues:** #29, #30, #74

## Decision

`tests/zero-downtime.sh` sends `GET /` to Poll and Result in parallel loops (2 per app by default, a new `curl` and TCP connection per request, 5 s timeout) and fails on any error: a non-2xx status or a `curl` failure (connection refused or reset, timeout). It runs for a fixed time, or wraps the update command (`-- <command>`) and keeps requesting 15 s after it ends. It prints each error as it happens, then requests, errors and latency (p50, p99, max) per app, and exits 1 on any error.

## Why

- The subject grades the update by requesting the app continuously: any error fails it ([subject](../subject/SUBJECT.md)). The script does what the evaluator will do, and gives a yes/no answer.
- Only `curl` and bash (3.2+, the macOS default): nothing to install on the evaluator's machine or in CI.
- A new connection per request is the hard case: each request goes through the Azure Load Balancer and kube-proxy to a pod, so a pod still listed while it stops would show as an error.
- Both apps at once: a rollout of one must not disturb the other.
- **`-- <command>` mode:** the same script serves the defense live update (#38), the AKS checks (#30) and CI on kind (#74). The 15 s after the command cover old pods still stopping: `kubectl rollout status` returns while they run their `preStop` sleep and drain ([ADR 0012](0012-graceful-shutdown.md)).
- A check before the test fails fast if an app is already down, so the rollout is not blamed for it.
- `GET` only: a `POST` would add fake votes, visible on Result during the defense.
- **Checked both ways:**
  - Local Docker Compose, no update: 0 errors.
  - Local, `docker compose restart poll` (no rolling update there): 26 Poll errors (18 connections refused, 8 resets), exit 1. The script does catch an outage.
  - **AKS, `kubectl rollout restart` of Poll and Result:** 0 errors in 975 requests with 2 loops per app, and 0 errors in 1996 requests with 4 loops. p99 under 0.42 s.

## Trade-offs

- The WebSocket of Result is not tested: its connection is cut when its pod stops, and socket.io reconnects ([ADR 0008](0008-result-deployment.md)). `curl` only sees the page.
- Browsers reuse connections (keep-alive); the script opens a new one per request. A reused connection to a stopping pod is not tested.
- **The test machine's connection is part of the measurement.** A busy one (a big image push, a system update downloading) slowed requests until some timed out, on Poll and Result at the same seconds, while only one app was updating. Seen twice on our machine; the rerun on an idle connection passed. Errors on both apps at once point to the client, not the rollout.
- Modest load (about 12 requests per second per app with 2 loops, on AKS): it proves that no request fails during an update, not how much load the apps take.

## Alternatives rejected

- **hey / vegeta / k6:** more load and richer reports, but one more tool for the evaluator and CI to install. Load is not what is graded.
- **A `while curl` one-liner typed at the defense:** no summary, no exit code, easy to get wrong live.
- **Only watching `kubectl rollout status` or the available replicas:** proves that Kubernetes kept pods available, not that no request failed while endpoints changed ([ADR 0012](0012-graceful-shutdown.md)).
