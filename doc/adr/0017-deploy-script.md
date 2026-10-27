# ADR 0017: One-command deploy script with a generated overlay

**Status:** Accepted · **Date:** 2026-10-27 · **Issues:** #36, #38

## Decision

`REGISTRY=<name>.azurecr.io scripts/deploy.sh` is the whole delivery process. It checks the prerequisites, builds `poll`, `worker` and `result` for `linux/amd64`, tags them ([ADR 0005](0005-image-tags-git-sha.md)), and pushes them (`az acr login` for an ACR). It then writes a Kustomize overlay in `.deploy/` (gitignored) that points `k8s/` at those images, applies it, waits for the 5 rollouts and prints the public URLs.

`k8s/kustomization.yaml` holds no registry and no tag: the manifests keep the bare names. `TAG=<existing tag>` skips the build and deploys that tag (rollback).

## Why

- **Fact:** the subject asks for a process that builds the images, pushes them to a private registry and deploys them, launched from scratch by the evaluator with their own credentials. ([subject](../subject/SUBJECT.md)) One command does the three, in that order.
- **Same command for the first deploy and the graded update:** change the code, run it again. New tag, so a rolling update. `tests/zero-downtime.sh -- scripts/deploy.sh` proves the update has no errors ([ADR 0016](0016-zero-downtime-test.md)).
- **No registry in the base:** the evaluator cannot pull from our registry, so a default pointing there would end in `ImagePullBackOff`. With bare names, the registry always comes from the person deploying.
- **Generated overlay, not an edit of `k8s/kustomization.yaml`:** no tracked file changes on a deploy, so no registry or tag ends up in a commit by mistake. `.deploy/kustomization.yaml` shows what was applied.
- **Tested with kubectl 1.37:** an overlay's `images` entry matches the image name as the base renders it, and Kustomize refuses absolute paths in `resources`. Hence a neutral base, and `.deploy/` next to `k8s/` with `../k8s`.
- **`--platform linux/amd64`:** the AKS nodes are amd64. Built on an Apple Silicon Mac without it, the images would be arm64 and fail to start.
- **Fails before changing anything** when `REGISTRY`, a tool, `k8s/secrets.env`, `POSTGRES_PASSWORD` or the cluster is missing, and prints the command to fix it. It renders the manifests before the builds, so a manifest error shows in seconds.
- **"Done" means reachable:** it waits for every rollout and for both public IPs.
- Only `bash` (3.2+), `git`, `docker`, `kubectl` and `az`: the tools the process needs anyway.
- **Tested on AKS** with `tests/zero-downtime.sh -- scripts/deploy.sh`:
  - First deploy over the `f880145` images: 0 errors during the rollout (1048 requests).
  - Uncommitted change in Poll (`-dirty` tag), the defense scenario: live in 52 s, 0 errors in 1225 requests.
  - Rollback with `TAG=<sha>` (no build): 0 errors in 986 requests.
  - A vote cast afterwards reached PostgreSQL.

## Trade-offs

- `kubectl apply -k k8s/` alone no longer gives a working app: the app images have no registry. The kustomization comment and the README say so.
- The build runs locally: Docker is needed, and on an Apple Silicon Mac the amd64 build runs under emulation, slower (the Java worker most of all).
- Every run rebuilds and rolls the 3 apps, even if one changed (one shared tag, [ADR 0005](0005-image-tags-git-sha.md)). Docker's layer cache keeps unchanged builds fast, and the rollouts have zero downtime.
- `kubectl apply` does not delete an object removed from `k8s/`. Not an issue while we only add or change objects.
- Automatic login for ACR only: another registry needs `docker login` first.
- **Test from another machine when the push is big.** On the first deploy (3 images, all layers new), the upload saturated our connection: the zero-downtime test, run on the same machine, logged 2 timeouts during the push, 90 s before the apply, and none during the rollout. A code change only pushes its changed layer, so the defense scenario ran clean from the same machine.

## Alternatives rejected

- **`kustomize edit set image`:** rewrites the tracked `kustomization.yaml` on every run (the registry and tag end up in commits), and needs the standalone `kustomize` binary.
- **`sed` on the manifests or the rendered YAML:** fragile text replacement.
- **Makefile (`make deploy`):** one more tool and syntax around the same shell logic (checks, loops, messages).
- **`az acr build` (build in Azure):** no local Docker and native amd64, but it adds ACR Tasks, one more Azure service to enable and pay on the evaluator's subscription. Not tried.
- **Deploy from CI on push:** CI will build and push (#12), but deploying from it needs the evaluator's cluster credentials in GitHub. The evaluator deploys from their own machine.
- **Helm:** see [ADR 0003](0003-kustomize.md).

## Revisit if

CI (#12) needs the same build and push: share that part of the script instead of copying it.
