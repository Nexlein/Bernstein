# ADR 0020: No GitOps controller

**Status:** Accepted · **Date:** 2026-10-27 · **Issues:** #40

## Decision

No Argo CD or Flux in the cluster. Deployments are pushed from the operator's machine with `scripts/deploy.sh` ([ADR 0017](0017-deploy-script.md)), which runs `kubectl apply` once per deploy.

## Why

- **What GitOps is:** a controller in the cluster pulls the desired state from a git repository and keeps reconciling the cluster to it. **Fact:** on AKS, Flux v2 is offered as the `microsoft.flux` cluster extension; its `fluxConfigurations` "sync your Git repository sources to the cluster and reconcile the cluster to the desired state". ([Microsoft Learn: GitOps with Flux v2](https://learn.microsoft.com/en-us/azure/azure-arc/kubernetes/tutorial-use-gitops-flux2)) [Argo CD](https://argo-cd.readthedocs.io/en/stable/) works the same way.
- **The subject's test is a push:** the evaluator clones the repo, sets their credentials and launches the deployment themselves. With GitOps, they would first install a controller, then point it to a repository they can write to (a fork), with its credentials. One more component and one more step for no graded gain.
- **Capacity:** a controller is several more pods. The requests of both nodes already add up to 1662m CPU, close to the 1900m that one node offers and that a drain needs ([ADR 0018](0018-resource-requests-and-limits.md)).
- `kubectl apply` is idempotent, and our manifests in git stay the single source of truth: what runs is what the last deploy applied.

## Trade-offs

- **No drift correction:** a manual `kubectl edit` or `scale` stays until the next deploy. Only the next `scripts/deploy.sh` puts the cluster back to what git says.
- **No deploy history in the cluster:** the history is git, plus the Deployments' `rollout history`.
- Deploying needs cluster credentials on the operator's machine. A GitOps controller would pull, so no credentials would leave the cluster.

## Alternatives rejected

- **Flux (AKS extension) or Argo CD:** continuous reconciliation, drift correction, and a pull model with no cluster credentials outside. The right choice for a team and several environments; over-built for one environment deployed by an evaluator.
- **Deploy from CI on every push to `main`:** a middle ground, but it needs the evaluator's cluster credentials in GitHub ([ADR 0017](0017-deploy-script.md)).

## Revisit if

The app gets several environments, or several people deploy it.
