# AKS Cluster + ACR Registry Setup

Step-by-step guide to create the Azure resources Bernstein runs on: a resource group, a private registry and an AKS cluster. Once they exist, deploy the app with [`DEPLOY.md`](../../DEPLOY.md).

## Names

Set these variables once per shell; every command below uses them. The values are ours, as an example: replace them with your own.

```bash
RG=bernstein-rg             # resource group
LOCATION=francecentral      # region of the resource group
ACR=bernsteinacrmaeva       # registry name: globally unique, lowercase letters and digits only
AKS=bernstein-aks           # cluster name
AKS_LOCATION=spaincentral   # region of the cluster (see step 5), and of the registry
```

---

## 0. Prerequisites

### Install Azure CLI

If `apt update` fails because a repository changed its `Codename` (e.g. the Epitech PPA):

```bash
sudo apt-get update --allow-releaseinfo-change
```

Then:

```bash
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
az version
```

Alternative without apt: `sudo apt install pipx && pipx install azure-cli && pipx ensurepath`.

### Install kubectl

```bash
sudo snap install kubectl --classic
```

(or `az aks install-cli`)

---

## 1. Log in to Azure

```bash
az login                     # or: az login --use-device-code
az account show -o table     # should show "Azure for Students"
```

If you have several subscriptions:

```bash
az account list -o table
az account set --subscription "Azure for Students"
```

## 2. Register resource providers (once per subscription)

```bash
az provider register --namespace Microsoft.ContainerService
az provider register --namespace Microsoft.ContainerRegistry
```

## 3. Create the resource group

Logical container for all project resources (lets you delete everything at once).

```bash
az group create --name "$RG" --location "$LOCATION"
```

## 4. Create the private registry (ACR)

The name must be globally unique, lowercase letters and digits only.

```bash
az acr create --resource-group "$RG" --name "$ACR" --sku Basic --location "$AKS_LOCATION"
```

Put the registry in the cluster's region: `az aks check-acr` warns that a registry in another region "may result in slow image pulls and extra cost". Ours predates this advice: it sits in `francecentral`, the cluster in `spaincentral`.

## 5. Create the AKS cluster (~5-10 min)

```bash
az aks create --resource-group "$RG" --name "$AKS" --location "$AKS_LOCATION" --node-count 2 --node-vm-size standard_b2s_v2 \
  --attach-acr "$ACR" --no-ssh-key
```

| Option                    | Why                                                                                                                    |
| ------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `--location spaincentral` | `francecentral` only allows `v7` SKUs on Azure for Students, which have `0` vCPU quota; `spaincentral` allows `Bsv2`   |
| `--node-count 2`          | Spreads the 2 poll/result replicas across nodes; fits within the 6 regional / 10 family vCPU quota (`2 × 2 = 4` vCPUs) |
| `--node-vm-size b2s_v2`   | 2 vCPU / 8 GB RAM (`Standard Bsv2 Family` has 10 vCPU quota in `spaincentral` on the student subscription)             |
| `--attach-acr`            | Grants the cluster pull access to the ACR (no `imagePullSecret` needed)                                                |
| `--no-ssh-key`            | No SSH needed on nodes; avoids the `~/.ssh/id_rsa` parsing error                                                       |

Track progress:

```bash
az aks show -g "$RG" -n "$AKS" --query provisioningState -o tsv   # Creating -> Succeeded
```

### Already have a cluster? Attach the registry

Do not rerun `az aks create` on an existing cluster. Give it pull access to the registry instead, then continue with step 6:

```bash
az aks show --resource-group "$RG" --name "$AKS" -o table
az aks update --resource-group "$RG" --name "$AKS" --attach-acr "$ACR"
```

Attaching needs the Owner role (or equivalent) on the subscription, because it creates a role assignment ([ADR 0002](../adr/0002-acr-registry.md)).

## 6. Connect kubectl to the cluster

```bash
az aks get-credentials --resource-group "$RG" --name "$AKS" --overwrite-existing
kubectl get nodes          # 2 nodes "Ready"
kubectl get nodes -w       # live watch (Ctrl+C to quit)
```

`get-credentials` writes the config to `~/.kube/config`.

Check that the cluster may pull from the registry: its kubelet identity must hold the `AcrPull` role on it.

```bash
KUBELET_ID=$(az aks show -g "$RG" -n "$AKS" --query identityProfile.kubeletidentity.objectId -o tsv)
az role assignment list --assignee "$KUBELET_ID" --scope "$(az acr show -n "$ACR" --query id -o tsv)" \
  --query "[].roleDefinitionName" -o tsv   # AcrPull
```

`az aks check-acr` runs more checks, but with az 2.91 it crashed on our cluster (`KeyError: 'serverVersion'`).

---

## 7. Give access to your teammate

`Contributor` role on the resource group. It covers ACR push/pull and `az aks get-credentials` (`kubectl` access), so no other role is needed:

```bash
RG_ID=$(az group show --name "$RG" --query id -o tsv)
az role assignment create --assignee firstname.lastname@epitech.eu --role Contributor --scope "$RG_ID"
```

For `kubectl` access only, without `Contributor`, assign `Azure Kubernetes Service Cluster User Role` on the cluster instead.

On the teammate's side, with the same variables set:

```bash
az login
az account set --subscription "<owner's subscription>"
az acr login --name "$ACR"
az aks get-credentials -g "$RG" -n "$AKS"
```

> If `--assignee` returns "user not found": invite the teammate as a guest (Azure portal → Microsoft Entra ID → Users → Invite external user).

---

## 8. Build, push and deploy

[`scripts/deploy.sh`](../../scripts/deploy.sh) builds the 3 images, tags them with the git SHA, pushes them to the registry and deploys the app. Credentials and details: [`DEPLOY.md`](../../DEPLOY.md).

```bash
REGISTRY="$ACR.azurecr.io" scripts/deploy.sh
az acr repository list --name "$ACR" -o table                          # what the registry holds
az acr repository show-tags --name "$ACR" --repository poll -o table   # tags of one image
```

### (Optional) Push from GitHub CI

> **To be decided in #13 (OIDC preferred).** The service principal below relies on a long-lived password stored in GitHub. OIDC with a federated credential needs no stored secret ([Microsoft Learn: GitHub Actions with OIDC](https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure-openid-connect)). Kept here as a fallback only.

Create a service principal limited to pushing:

```bash
ACR_ID=$(az acr show --name bernsteinacrmaeva --query id -o tsv)
az ad sp create-for-rbac --name bernstein-ci --role AcrPush --scopes "$ACR_ID"
```

Add in GitHub → Settings → Secrets and variables → Actions:

- `ACR_LOGIN_SERVER` = `bernsteinacrmaeva.azurecr.io`
- `ACR_USERNAME` = `appId`
- `ACR_PASSWORD` = `password`

> Never commit these values.

---

## 9. Stop or delete (cost)

Stop the nodes when idle, delete the app or everything after the defense: [`DEPLOY.md`](../../DEPLOY.md#6-stop-or-delete-cost).

---

## Troubleshooting

| Error                                                             | Cause / Fix                                                                                                   |
| ----------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| `az: command not found`                                           | Install aborted by `apt update` → `sudo apt-get update --allow-releaseinfo-change`, then rerun                |
| `Valid PEM but no BEGIN/END delimiters for a private key`         | `--generate-ssh-keys` can't read the existing key → use `--no-ssh-key`                                        |
| `The VM size of Standard_B2s is not allowed in your subscription` | Size not allowed in region → use `--location spaincentral --node-vm-size standard_b2s_v2`                     |
| `ErrCode_InsufficientVCPUQuota` (`StandardDalsv7Family` = 0)      | `francecentral` only exposes `v7` SKUs with `0` quota on Student subscriptions → deploy AKS in `spaincentral` |
| `kubectl: command not found`                                      | `sudo snap install kubectl --classic`                                                                         |
| `kubectl get nodes` → `No resources found`                        | Cluster still `Creating`, wait for `Succeeded`                                                                |

Check your quota:

```bash
az vm list-usage --location "$AKS_LOCATION" -o table | awk '$NF > 0 && /vCPU/'
```
