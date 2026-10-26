# ADR 0003: Manifests with Kustomize

**Status:** Accepted · **Date:** 2026-10-19 · **Issues:** #8, #14, #33, #34

## Decision

Plain Kubernetes YAML in `k8s/`, assembled by `k8s/kustomization.yaml`, deployed with `kubectl apply -k k8s/`.

**File layout** (flat folder, no shared patches):

- One file per app for its workload and its Service: `poll.yaml`, `result.yaml`, `worker.yaml`, `redis.yaml`, `postgres.yaml`.
- One file per kind for the policies added on top of the apps: `pdb.yaml`, then `hpa.yaml` (#33) and `network-policies.yaml` (#34).
- Each manifest states its settings in full, even when another manifest repeats them.

## Why

- **Fact:** Kustomize is built into `kubectl` since 1.14 (`kubectl apply -k <dir>`, preview with `kubectl kustomize <dir>`). ([Kubernetes docs: Kustomize](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/)) The evaluator needs no extra tool.
- The manifests stay readable YAML with no template language, easy to explain line by line.
- **Fact:** the `images` field rewrites image names and tags without editing the Deployments. ([Kustomize reference: images](https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/images/)) The pipeline sets the git SHA there ([ADR 0005](0005-image-tags-git-sha.md)).
- **Fact:** `configMapGenerator` and `secretGenerator` add a content hash to the generated name, so a config change triggers a rollout. ([Kubernetes docs: Kustomize](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/))
- **Explicit over DRY:** Poll and Result are almost the same file: 96 of Result's 99 YAML lines (comments aside) also appear in `poll.yaml`, with the app name changed. They differ only where the apps differ: grace period (45 s vs 30 s), the secret they read, and `/tmp`, uid and threads for Poll. If those lines were shared, `poll.yaml` would no longer show `maxUnavailable: 0`, the setting the zero-downtime test depends on. Drift between the copies is left to a CI check instead (#72, open).
- **Policies by kind:** a PDB, an HPA or a NetworkPolicy is a separate concern from the workload (availability, scaling, network). One file per kind keeps each concern in one place, and each ticket adds one file.

## Trade-offs

- No release history or `rollback` command like Helm. We use `kubectl rollout undo` per Deployment.
- Less powerful than a template engine for many environments. We have one environment.
- A setting repeated in several files (for example the rollout strategy) must be changed in each of them.

## Alternatives rejected

- **Helm:** useful to publish an app for others. For our single deployment, it adds a binary and Go templates for no real gain.
- **Raw `kubectl apply -f`:** works, but the image tag would have to be edited with `sed` in every file.
- **Shared patches or a Kustomize component** for the settings Deployments have in common: no repetition, but the reader must merge files in their head to know what runs, and explain the patch mechanism at the defense.
- **A folder per app** (`k8s/poll/` with its own `kustomization.yaml`): twice the files for 5 apps. Folders, and base/overlays, pay off with several environments; we have one.
- **Terraform Kubernetes provider:** mixes infrastructure and app deploys in one state file; heavier to learn and to hand over.
