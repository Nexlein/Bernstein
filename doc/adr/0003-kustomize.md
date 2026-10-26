# ADR 0003: Manifests with Kustomize

**Status:** Accepted · **Date:** 2026-10-19 · **Issues:** #8, #14

## Decision

Plain Kubernetes YAML in `k8s/`, assembled by `k8s/kustomization.yaml`, deployed with `kubectl apply -k k8s/`.

## Why

- **Fact:** Kustomize is built into `kubectl` since 1.14 (`kubectl apply -k <dir>`, preview with `kubectl kustomize <dir>`). ([Kubernetes docs: Kustomize](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/)) The evaluator needs no extra tool.
- The manifests stay readable YAML with no template language, easy to explain line by line.
- **Fact:** the `images` field rewrites image names and tags without editing the Deployments. ([Kustomize reference: images](https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/images/)) The pipeline sets the git SHA there ([ADR 0005](0005-image-tags-git-sha.md)).
- **Fact:** `configMapGenerator` and `secretGenerator` add a content hash to the generated name, so a config change triggers a rollout. ([Kubernetes docs: Kustomize](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/))

## Trade-offs

- No release history or `rollback` command like Helm. We use `kubectl rollout undo` per Deployment.
- Less powerful than a template engine for many environments. We have one environment.

## Alternatives rejected

- **Helm:** useful to publish an app for others. For our single deployment, it adds a binary and Go templates for no real gain.
- **Raw `kubectl apply -f`:** works, but the image tag would have to be edited with `sed` in every file.
- **Terraform Kubernetes provider:** mixes infrastructure and app deploys in one state file; heavier to learn and to hand over.
