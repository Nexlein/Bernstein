# ADR 0012: Graceful shutdown with a `preStop` sleep and sized grace periods

**Status:** Accepted · **Date:** 2026-10-26 · **Issues:** #28

## Decision

Poll and Result get `lifecycle.preStop.sleep.seconds: 5`. `terminationGracePeriodSeconds` is 45 for Poll and 30 for Result.

## Why

- **Fact:** when a pod is deleted, Kubernetes removes it from the Service endpoints and starts its shutdown **in parallel**; the `preStop` hook runs first, and `SIGTERM` is only sent once it returns. ([Kubernetes docs: Pod termination](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#pod-termination)) Without a pause, the app could close its socket while kube-proxy on some node still routes new connections to it: errors during a rollout or a drain. The 5 s sleep lets every node drop the pod from its rules while it keeps serving.
- **Fact:** `sleep` is a built-in hook handler: the kubelet waits, no `sleep` binary is needed in the image. ([Kubernetes docs: Container lifecycle hooks](https://kubernetes.io/docs/concepts/containers/container-lifecycle-hooks/#hook-handler-implementations)) Works with our read-only root filesystems.
- **Grace periods sized per app** (counted from the start of `preStop`; after that, `SIGKILL`):
  - Poll: 5 s + Gunicorn's graceful shutdown (`graceful_timeout` defaults to 30 s), so 45 s.
  - Result: 5 s + its own drain on `SIGTERM` (at most 10 s in `server.js`), so 30 s.

## Trade-offs

- Every rollout and drain takes about 5 s longer per pod.
- 5 s is an estimate of endpoint propagation on a 2-node cluster, not a guarantee. The zero-downtime test (#29, #30) is what proves it.

## Alternatives rejected

- **No `preStop`:** relies on endpoint removal winning the race against the app's shutdown. Fine most of the time, not always.
- **`exec: ["sleep", "5"]`:** same effect, but needs a `sleep` binary in every image.
- **A longer sleep (15-30 s):** safer margin, but every rollout of 2 pods lasts much longer, for no measured gain.
