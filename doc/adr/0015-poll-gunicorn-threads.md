# ADR 0015: Gunicorn threads for Poll

**Status:** Accepted · **Date:** 2026-10-26 · **Issues:** #30

## Decision

`k8s/poll.yaml` sets `GUNICORN_CMD_ARGS="--threads 4"`. The image's command (`gunicorn --workers 2 …`) is unchanged: Gunicorn now runs 2 worker processes with 4 threads each (`gthread` worker) instead of 2 single-threaded `sync` workers.

## Why

Measured on AKS:

- With the image defaults, about **3.5 % of requests to Poll timed out** (3 s, no response), with or without a rollout, through the public IP and from inside the cluster alike. p99 latency was 1.4 s. Result (Node.js) had 0 errors under the same load.
- A Poll pod hit directly sometimes took ~4.5 s on `/readyz`, while DNS and Redis connections, timed alone inside the pod, were always fast. Requests were waiting for a free worker: each `sync` worker handles one connection at a time, so 2 stalled connections leave the pod unable to answer.
- **Fact:** Gunicorn's sync workers assume a buffering proxy in front of them; without one, slow or idle clients tie them up, and threaded or async workers are recommended. ([Gunicorn docs: Choosing a worker type](https://docs.gunicorn.org/en/stable/design.html#choosing-a-worker-type)) Our clients (browsers, the Azure Load Balancer) reach Gunicorn directly.
- After the change: **0 errors in 656 requests** over 90 s through the public IP, p99 0.17 s.
- **Fact:** Gunicorn reads `GUNICORN_CMD_ARGS` as extra settings; command-line arguments still win, so `--workers 2` from the image stays. ([Gunicorn docs: Configuration overview](https://docs.gunicorn.org/en/stable/configure.html))

## Trade-offs

- Threads share one Python process per worker: a CPU-bound request would be limited by the GIL. Poll's requests are I/O-bound (render a template, one `RPUSH`).
- We did not identify which client leaves connections idle (likely the TCP health probes of the Azure Load Balancer). Threads fix the symptom whatever the source.

## Alternatives rejected

- **More sync workers (`--workers 8`):** also works, but each worker is a full Python process (more memory per pod) for the same effect.
- **Changing the Dockerfile or `app.py`:** the application is provided by the subject; configuring it from the manifest keeps it untouched.
