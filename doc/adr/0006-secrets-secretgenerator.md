# ADR 0006: Secrets from a gitignored file through `secretGenerator`

**Status:** Accepted · **Date:** 2026-10-19 · **Issues:** #16, #17, #109

## Decision

The evaluator copies `k8s/secrets.env.example` to `k8s/secrets.env` and fills in the 3 database passwords: `POSTGRES_PASSWORD`, and since #109 `RESULT_DB_PASSWORD` and `WORKER_DB_PASSWORD`, for the users Result and the worker connect with ([ADR 0023](0023-security-posture.md)). `REDIS_PASSWORD` is optional. `scripts/deploy.sh` stops before changing anything if one of the 3 is empty. A `secretGenerator` in `k8s/kustomization.yaml` turns it into the `app-secrets` Secret on deploy (`scripts/deploy.sh`). The real file is gitignored.

## Why

- **Fact:** the subject excludes `POSTGRES_PASSWORD` and the cloud credentials from the delivery, but asks us to document how and where to set them; the evaluator must clone, set the credentials and deploy alone. ([subject PDF](../subject/bernstein-project.pdf)) Here: one file to fill, then the same single deploy command.
- **Fact:** `secretGenerator` builds a Secret from an env file and appends a content hash to its name, like `configMapGenerator`. ([Kubernetes docs: Managing Secrets using Kustomize](https://kubernetes.io/docs/tasks/configmap-secret/managing-secret-using-kustomize/)) Changing a password rolls the Deployments that use it, with no manual restart.
- If `secrets.env` is missing or `POSTGRES_PASSWORD` is empty, `scripts/deploy.sh` stops before building or creating anything (and `kubectl apply -k` would fail on a missing file anyway). Nothing deploys without its secrets.
- The Secret gets the `bernstein` namespace from the kustomization, so it always lands next to the pods that read it.
- No registry secret: AKS pulls from ACR through `--attach-acr` ([ADR 0002](0002-acr-registry.md)).

## Trade-offs

- **Fact:** a Secret is only base64-encoded, not encrypted, in its manifest; anyone allowed to read Secrets in the namespace can read the password. ([Kubernetes docs: Secrets](https://kubernetes.io/docs/concepts/configuration/secret/)) Access is limited by Azure RBAC on the cluster.
- The password sits in a plain file on the evaluator's machine. Acceptable: it only leaves that machine to go to the cluster.
- Every `kubectl kustomize k8s/` needs a `secrets.env`, even for a dry render. A copy of the template is enough (CI does this).

## Alternatives rejected

- **`secret.example.yaml` applied with `kubectl apply -f`:** two commands in the right order, no rollout on password change, and the manifest had no namespace, so the Secret landed in `default`, out of the pods' reach.
- **`kubectl create secret generic ... --from-literal`:** one-off and imperative; the password ends up in the shell history and the step is easy to forget.
- **Sealed Secrets:** an encrypted Secret can be committed, but the key belongs to the controller of one cluster. A fresh evaluator cluster could not decrypt ours, and it needs an extra tool.
- **Azure Key Vault + Secrets Store CSI driver:** the strongest option for production ([Microsoft Learn](https://learn.microsoft.com/en-us/azure/aks/csi-secrets-store-driver)), but a Key Vault, an identity and an add-on for one password is over-built here.
