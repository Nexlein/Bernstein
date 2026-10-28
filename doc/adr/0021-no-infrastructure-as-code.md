# ADR 0021: No Infrastructure as Code for the cluster and the registry

**Status:** Accepted · **Date:** 2026-10-27 · **Issues:** #40

## Decision

The resource group, the ACR registry and the AKS cluster are created with the `az` commands of the [setup guide](../setup/cluster-setup.md), with variables for the names. No Terraform or Bicep.

## Why

- **The subject gives the evaluator a ready cluster:** they must deploy the app on "a cluster on the same platform" ([subject](../subject/SUBJECT.md)). Creating the infrastructure is not part of what is delivered or graded; our setup guide covers it for whoever needs a cluster.
- **Three resources, created once:** a resource group, a registry, a cluster. The commands are short and documented, and an evaluator with a cluster only needs one of them (attach the registry).
- **Fewer tools:** Terraform would add a binary and a state file to store and share between us. **Fact:** Terraform must store state about the managed infrastructure. ([Terraform docs: State](https://developer.hashicorp.com/terraform/language/state))
- The student subscription made the cluster creation a matter of trial and error (regions, VM families, quotas, [ADR 0001](0001-aks-cluster.md)). The working values are in the setup guide.

## Trade-offs

- **No preview and no drift detection:** nothing shows what a change would do before applying it, and a change made in the portal goes unnoticed. **Fact:** Bicep's what-if operation previews changes and needs no state file, since Azure stores the state. ([Microsoft Learn: What is Bicep?](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/overview))
- Recreating the infrastructure is a sequence of commands to run in order, not one declarative file.
- The cluster settings that matter for security (API server access, local accounts, [ADR 0023](0023-security-posture.md)) live in Azure only, not in git.

## Alternatives rejected

- **Bicep:** native to Azure, no state file, `what-if` previews. The best fit if we did it; one more language for three resources created once.
- **Terraform:** works on every cloud, `plan` previews; needs its binary and a shared state (a storage account, with locking).
- **Pulumi, ARM JSON templates:** same idea, with a general-purpose language or a verbose JSON syntax.

## Revisit if

We need several environments (staging, production), or the infrastructure is rebuilt often.
