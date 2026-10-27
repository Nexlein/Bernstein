# ADR 0002: Private registry on ACR, attached to AKS

**Status:** Accepted · **Date:** 2026-10-19 · **Issues:** #8, #10, #11, #17

## Decision

Azure Container Registry `bernsteinacrmaeva.azurecr.io`, Basic SKU in `francecentral`, attached to the AKS cluster with `--attach-acr`. No `imagePullSecret` in the manifests.

## Why

- **Fact:** `az aks update --attach-acr <registry>` (or `az aks create --attach-acr`) gives the kubelet managed identity of the cluster the `AcrPull` role on the registry. Nodes then pull with no `imagePullSecret`. ([Microsoft Learn: Integrate ACR with AKS](https://learn.microsoft.com/en-us/azure/aks/cluster-container-registry-integration))
- No registry password in the cluster or in git, which fits our secret-separation rule. Local pushes authenticate with `az login` + `az acr login --name bernsteinacrmaeva` ([setup guide](../setup/cluster-setup.md)).
- **Fact:** the Basic SKU has the same data-plane API as the others, 10 GiB of included storage, and no anonymous pull (Standard and Premium only), so the registry is private by default. ([Microsoft Learn: ACR SKUs](https://learn.microsoft.com/en-us/azure/container-registry/container-registry-skus)) Our 3 images fit easily in 10 GiB.

## Trade-offs

- **Not in the cluster's region:** the registry is in `francecentral`, the cluster in `spaincentral` (moved there for the vCPU quota, [ADR 0001](0001-aks-cluster.md)). `az aks check-acr` warns that this "may result in slow image pulls and extra cost": pulls cross regions. Not worth recreating the registry for a demo; the setup guide now creates it in the cluster's region.
- Basic is billed per day even when idle: small, but not zero. ([Azure: Container Registry pricing](https://azure.microsoft.com/pricing/details/container-registry/))
- The person running `--attach-acr` needs the Owner role (or equivalent) on the subscription. ([Microsoft Learn: Integrate ACR with AKS](https://learn.microsoft.com/en-us/azure/aks/cluster-container-registry-integration))
- **Fact:** no private endpoints or IP rules on Basic (Premium only). ([Microsoft Learn: ACR SKUs](https://learn.microsoft.com/en-us/azure/container-registry/container-registry-skus)) The registry requires authentication but is reachable over the internet.

## Alternatives rejected

- **Docker Hub / GHCR private repositories:** free or cheap, but they need a long-lived token stored as an `imagePullSecret` in the cluster, and a second account for the evaluator.
- **Self-hosted registry (`registry:2` in the cluster):** one more stateful service to run, secure with TLS and back up. No gain.
- **ACR Standard / Premium:** more storage, geo-replication and private link that we do not need.
