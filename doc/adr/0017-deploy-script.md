# ADR 0017: One-command deploy script with a generated overlay

**Status:** Accepted · **Date:** 2026-10-27 · **Issues:** #36, #38, #108

## Decision

`REGISTRY=<name>.azurecr.io scripts/deploy.sh` is the whole delivery process. It checks the prerequisites, builds `poll`, `worker` and `result` for `linux/amd64`, tags them ([ADR 0005](0005-image-tags-git-sha.md)), and pushes them (`az acr login` for an ACR). It then writes a Kustomize overlay in `.deploy/` (gitignored) that points `k8s/` at those images, applies it, waits for the 5 rollouts and prints the public URLs.

`k8s/kustomization.yaml` holds no registry and no tag: the manifests keep the bare names. `TAG=<existing tag>` skips the build and deploys that tag (rollback). For an ACR, it first checks that the 3 images exist.

A rollout with no new Ready pod for 2 minutes fails (`progressDeadlineSeconds: 120` on the 4 Deployments). The script then names the failed Deployment, prints the commands to find the cause and to roll back, and exits 1. It rolls nothing back by itself.

## Why

- **Fact:** the subject asks for a process that builds the images, pushes them to a private registry and deploys them, launched from scratch by the evaluator with their own credentials. ([subject](../subject/SUBJECT.md)) One command does the three, in that order.
- **Same command for the first deploy and the graded update:** change the code, run it again. New tag, so a rolling update. `tests/zero-downtime.sh -- scripts/deploy.sh` proves the update has no errors ([ADR 0016](0016-zero-downtime-test.md)).
- **No registry in the base:** the evaluator cannot pull from our registry, so a default pointing there would end in `ImagePullBackOff`. With bare names, the registry always comes from the person deploying.
- **Generated overlay, not an edit of `k8s/kustomization.yaml`:** no tracked file changes on a deploy, so no registry or tag ends up in a commit by mistake. `.deploy/kustomization.yaml` shows what was applied.
- **Tested with kubectl 1.37:** an overlay's `images` entry matches the image name as the base renders it, and Kustomize refuses absolute paths in `resources`. Hence a neutral base, and `.deploy/` next to `k8s/` with `../k8s`.
- **`--platform linux/amd64`:** the AKS nodes are amd64. Built on an Apple Silicon Mac without it, the images would be arm64 and fail to start.
- **Fails before changing anything** when `REGISTRY`, a tool, `k8s/secrets.env`, `POSTGRES_PASSWORD` or the cluster is missing, and prints the command to fix it. It renders the manifests before the builds, so a manifest error shows in seconds.
- **"Done" means reachable:** it waits for every rollout and for both public IPs.
- **A broken update fails in 2 minutes, without downtime.** With `maxUnavailable: 0`, an old pod stops only after a new one is Ready, so a new version that never gets Ready leaves the old pods serving. Kubernetes only reports a stalled rollout: after `progressDeadlineSeconds` it sets `ProgressDeadlineExceeded`, and `kubectl rollout status` exits non-zero. ([Kubernetes, Failed Deployment](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#failed-deployment)) The default deadline is 600 s: the script would wait 10 minutes. Our pods start in 1 to 13 s, plus up to about 20 s of image pull on a fresh node, so 120 s leaves a wide margin.
- **No automatic rollback:** the old pods keep serving, so nothing is urgent. The operator first reads why (`describe` of the new pod), then chooses: fix and redeploy, `rollout undo` of that Deployment, or `TAG=<good tag>` for the 3 apps.
- **The tag check** stops a mistyped `TAG` before anything is applied, instead of new pods stuck in `ImagePullBackOff`.
- Only `bash` (3.2+), `git`, `docker`, `kubectl` and `az`: the tools the process needs anyway.
- **Tested on AKS** with `tests/zero-downtime.sh -- scripts/deploy.sh`:
  - First deploy over the `f880145` images: 0 errors during the rollout (1048 requests).
  - Uncommitted change in Poll (`-dirty` tag), the defense scenario: live in 52 s, 0 errors in 1225 requests.
  - Rollback with `TAG=<sha>` (no build): 0 errors in 986 requests.
  - A vote cast afterwards reached PostgreSQL.
- **Broken updates tested on AKS (#108)**, with a probe inside the cluster requesting Poll and Result in a loop: 0 errors in each case.
  - Poll with an image tag that does not exist (`ImagePullBackOff`), a container that exits at start (`CrashLoopBackOff`), and no reachable Redis (`Running`, never Ready): the 2 old pods kept serving.
  - That last one deployed with the script: `exceeded its progress deadline` after 2 minutes, the message, exit 1. Then `TAG=<previous tag>`: Poll back in about 16 s.
  - `TAG=does-not-exist`: `ERROR: <registry>/poll:does-not-exist not found`, exit 2, nothing applied.

## Trade-offs

- `kubectl apply -k k8s/` alone no longer gives a working app: the app images have no registry. The kustomization comment and the README say so.
- The build runs locally: Docker is needed, and on an Apple Silicon Mac the amd64 build runs under emulation, slower (the Java worker most of all).
- Every run rebuilds and rolls the 3 apps, even if one changed (one shared tag, [ADR 0005](0005-image-tags-git-sha.md)). Docker's layer cache keeps unchanged builds fast, and the rollouts have zero downtime.
- `kubectl apply` does not delete an object removed from `k8s/`. Not an issue while we only add or change objects.
- Automatic login for ACR only: another registry needs `docker login` first. The `TAG` check also runs for an ACR only.
- **A slow but healthy start over 2 minutes is reported as failed.** The rollout still completes when the pod gets Ready: the deadline only reports. Then `kubectl -n bernstein rollout status deploy/<app>` confirms it.
- **The broken pod stays** (`ImagePullBackOff` or `CrashLoopBackOff`) until a rollback or a new deploy. It gets no traffic, but holds its resource requests.
- **The PostgreSQL StatefulSet has no `progressDeadlineSeconds`.** The script's `--timeout=5m` on `rollout status` covers it.
- `rollout undo` prints a warning about the `last-applied-configuration` annotation. Harmless: the next run applies the full manifests.
- **Test from another machine when the push is big.** On the first deploy (3 images, all layers new), the upload saturated our connection: the zero-downtime test, run on the same machine, logged 2 timeouts during the push, 90 s before the apply, and none during the rollout. A code change only pushes its changed layer, so the defense scenario ran clean from the same machine.

## Alternatives rejected

- **`kustomize edit set image`:** rewrites the tracked `kustomization.yaml` on every run (the registry and tag end up in commits), and needs the standalone `kustomize` binary.
- **`sed` on the manifests or the rendered YAML:** fragile text replacement.
- **Makefile (`make deploy`):** one more tool and syntax around the same shell logic (checks, loops, messages).
- **`az acr build` (build in Azure):** no local Docker and native amd64, but it adds ACR Tasks, one more Azure service to enable and pay on the evaluator's subscription. Not tried.
- **Deploy from CI on push:** CI will build and push (#12), but deploying from it needs the evaluator's cluster credentials in GitHub. The evaluator deploys from their own machine.
- **Helm:** see [ADR 0003](0003-kustomize.md).
- **Automatic `rollout undo` when a rollout fails:** it would hide the cause, and it undoes one Deployment while a run changes the 3 apps' tag. The old pods already keep the app up.
- **Argo Rollouts or Flagger (analysis, automatic rollback):** one more controller to install and explain, for a decision the operator takes in one command here ([ADR 0020](0020-no-gitops.md)).

## Revisit if

CI (#12) needs the same build and push: share that part of the script instead of copying it.
