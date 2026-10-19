# AKS Cluster + ACR Registry Setup

Step-by-step guide to recreate the Bernstein Azure infrastructure from scratch.

## Created resources

| Resource         | Name                | Details                                                         |
| ---------------- | ------------------- | --------------------------------------------------------------- |
| Resource group   | `bernstein-rg`      | Region `francecentral`                                          |
| Private registry | `bernsteinacrmaeva` | ACR, `Basic` SKU (`francecentral`)                              |
| K8s cluster      | `bernstein-aks`     | Region `spaincentral`, 2 nodes `standard_b2s_v2` (2 vCPU, 8 GB) |

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
az group create --name bernstein-rg --location francecentral
```

## 4. Create the private registry (ACR)

The name must be globally unique, lowercase letters and digits only.

```bash
az acr create --resource-group bernstein-rg --name bernsteinacrmaeva --sku Basic
```

## 5. Create the AKS cluster (~5-10 min)

```bash
az aks create --resource-group bernstein-rg --name bernstein-aks --location spaincentral --node-count 2 --node-vm-size standard_b2s_v2 --attach-acr bernsteinacrmaeva --no-ssh-key
```

If the cluster already exists, do not rerun `create` with the same name. Either continue with step 6, or inspect/update the existing cluster with:

```bash
az aks show --resource-group bernstein-rg --name bernstein-aks -o table
az aks update --resource-group bernstein-rg --name bernstein-aks
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
az aks show -g bernstein-rg -n bernstein-aks --query provisioningState -o tsv   # Creating -> Succeeded
```

## 6. Connect kubectl to the cluster

```bash
az aks get-credentials --resource-group bernstein-rg --name bernstein-aks --overwrite-existing
kubectl get nodes          # 2 nodes "Ready"
kubectl get nodes -w       # live watch (Ctrl+C to quit)
```

`get-credentials` writes the config to `~/.kube/config`.

---

## 7. Give access to your teammate

`Contributor` role on the resource group. It covers ACR push/pull and `az aks get-credentials` (`kubectl` access), so no other role is needed:

```bash
RG_ID=$(az group show --name bernstein-rg --query id -o tsv)
az role assignment create --assignee firstname.lastname@epitech.eu --role Contributor --scope "$RG_ID"
```

For `kubectl` access only, without `Contributor`, assign `Azure Kubernetes Service Cluster User Role` on the cluster instead.

On the teammate's side:

```bash
az login
az account set --subscription "<owner's subscription>"
az acr login --name bernsteinacrmaeva
az aks get-credentials -g bernstein-rg -n bernstein-aks
```

> If `--assignee` returns "user not found": invite the teammate as a guest (Azure portal → Microsoft Entra ID → Users → Invite external user).

---

## 8. Build & push images to the ACR

Tag = short git SHA: a K8s rollout only triggers when the tag changes, and you always know which commit is running.

```bash
az acr login --name bernsteinacrmaeva
TAG=$(git rev-parse --short HEAD)
REG=bernsteinacrmaeva.azurecr.io
for svc in poll result worker; do
    docker build -t "$REG/$svc:$TAG" "poll-application/$svc"
    docker push "$REG/$svc:$TAG"
done
az acr repository list --name bernsteinacrmaeva -o table
az acr repository show-tags --name bernsteinacrmaeva --repository poll -o table
```

Verify the cluster can pull from the private ACR (via `--attach-acr`, no `imagePullSecret` needed):

```bash
kubectl run test-pull --image="$REG/poll:$TAG" --restart=Never
kubectl get pod test-pull
kubectl describe pod test-pull | grep -E "Pulling|Pulled|Started"
kubectl delete pod test-pull
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

## 9. Cost management

```bash
az aks stop  --resource-group bernstein-rg --name bernstein-aks   # shut down the nodes
az aks start --resource-group bernstein-rg --name bernstein-aks   # start them again
az group delete --name bernstein-rg --yes                         # delete EVERYTHING (end of project)
```

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
az vm list-usage --location spaincentral -o table | awk '$NF > 0 && /vCPU/'
```
