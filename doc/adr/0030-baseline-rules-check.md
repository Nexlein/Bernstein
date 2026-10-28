# ADR 0030: Check our baseline rules in CI with a small script

**Status:** Accepted · **Date:** 2026-10-28 · **Issues:** #72

## Decision

A CI job renders `k8s/` with `kubectl kustomize`, converts it to JSON with `yq`, and runs `scripts/check-baseline.mjs` (Node, no dependency). The script checks 6 rules from `CLAUDE.md` and fails the pull request with one line per broken rule, naming the object:

1. every container of every Deployment and StatefulSet has `requests` and `limits`, for CPU and memory;
2. every container runs with `runAsNonRoot: true` (pod or container level) and `allowPrivilegeEscalation: false`;
3. every Deployment has `RollingUpdate` with `maxSurge: 1`, `maxUnavailable: 0`, and `minReadySeconds: 5`;
4. Poll and Result keep 2+ pods: `replicas >= 2`, or, when an HPA targets the Deployment, `minReplicas >= 2` and no `replicas` in the Deployment ([ADR 0026](0026-poll-hpa.md));
5. Poll and Result have a readiness probe, a liveness probe, a `preStop` hook, and a PodDisruptionBudget that selects their pods;
6. only the `poll` and `result` Services are `LoadBalancer`; every other Service is `ClusterIP`.

## Why

- These rules hold the graded zero-downtime update and the security answers of the defense. Until now only reviews kept them; a new manifest could drop one silently.
- **Checked:** the real manifests pass (`main` and the open PR stack: 5 workloads, 23 objects). 13 broken copies each fail with the expected line, for example `FAIL Deployment/result: maxUnavailable is 1, not 0 (rule 3)`, `FAIL HorizontalPodAutoscaler/poll: minReplicas is 1, below 2 (rule 4)`, `FAIL Service/postgres: type is LoadBalancer, not ClusterIP (rule 6)`.
- **No new tool:** `yq` ships with GitHub's Ubuntu runner image, and Node already runs `scripts/codemap.mjs`. The rules are ours (exact values, which apps are public), so a generic linter would need custom checks anyway.
- **Its own CI job:** it runs in parallel with the others, and its failure reads "K8s Baseline Rules" in the checks list.

## Trade-offs

- A new rule means a few lines of JavaScript, reviewed like any code.
- The rules name `poll` and `result`. A third public app would need the script changed too.
- Locally, `yq` may be missing: `CONTRIBUTING.md` gives a Python one-liner that does the same conversion.

## Alternatives rejected

- **kube-linter, Polaris, Kyverno CLI or conftest (OPA):** good generic checks (resources, non-root), but none knows our exact values or our two public apps without writing custom policies in their own language, and each is a new tool to install and pin.
- **A shell script with `yq` and `jq` only:** works, but nested loops over containers and clear messages are harder to read and test in shell.
- **Admission policies in the cluster** (`ValidatingAdmissionPolicy`): they would block a bad `kubectl apply`, but only at deploy time, on the evaluator's cluster too. CI catches it before the merge.
