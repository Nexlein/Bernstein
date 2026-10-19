# AKS Cluster + ACR Registry Setup

Step-by-step guide to recreate the Bernstein Azure infrastructure from scratch.

> Commands are written for **fish** (`set VAR (cmd)`). In bash, use `VAR=$(cmd)` instead.

## Created resources

| Resource         | Name                | Details                                    |
| ---------------- | ------------------- | ------------------------------------------ |
| Resource group   | `bernstein-rg`      | Region `francecentral`                     |
| Private registry | `bernsteinacrmaeva` | ACR, `Basic` SKU                           |
| K8s cluster      | `bernstein-aks`     | 2 nodes `standard_d2als_v7` (2 vCPU, 4 GB) |

---

## 0. Prerequisites

### Install Azure CLI

If `apt update` fails because a repository changed its `Codename` (e.g. the Epitech PPA):

```fish
sudo apt-get update --allow-releaseinfo-change
```

Then:

```fish
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
az version
```

Alternative without apt: `sudo apt install pipx && pipx install azure-cli && pipx ensurepath`.

### Install kubectl

```fish
sudo snap install kubectl --classic
```

(or `az aks install-cli`)

---

## 1. Log in to Azure

```fish
az login                     # or: az login --use-device-code
az account show -o table     # should show "Azure for Students"
```

If you have several subscriptions:

```fish
az account list -o table
az account set --subscription "Azure for Students"
```

## 2. Register resource providers (once per subscription)

```fish
az provider register --namespace Microsoft.ContainerService
az provider register --namespace Microsoft.ContainerRegistry
```

## 3. Create the resource group

Logical container for all project resources (lets you delete everything at once).

```fish
az group create --name bernstein-rg --location francecentral
```

## 4. Create the private registry (ACR)

The name must be globally unique, lowercase letters and digits only.

```fish
az acr create --resource-group bernstein-rg --name bernsteinacrmaeva --sku Basic
```

## 5. Create the AKS cluster (~5-10 min)

```fish
az aks create --resource-group bernstein-rg --name bernstein-aks --node-count 2 --node-vm-size standard_d2als_v7 --attach-acr bernsteinacrmaeva --no-ssh-key
```

| Option                    | Why                                                                         |
| ------------------------- | --------------------------------------------------------------------------- |
| `--node-count 2`          | Spreads the 2 poll/result replicas across nodes; fits within a 4 vCPU quota |
| `--node-vm-size d2als_v7` | Smallest size allowed on the student subscription in `francecentral`        |
| `--attach-acr`            | Grants the cluster pull access to the ACR (no `imagePullSecret` needed)     |
| `--no-ssh-key`            | No SSH needed on nodes; avoids the `~/.ssh/id_rsa` parsing error            |

Track progress:

```fish
az aks show -g bernstein-rg -n bernstein-aks --query provisioningState -o tsv   # Creating -> Succeeded
```

## 6. Connect kubectl to the cluster

```fish
az aks get-credentials --resource-group bernstein-rg --name bernstein-aks
kubectl get nodes          # 2 nodes "Ready"
kubectl get nodes -w       # live watch (Ctrl+C to quit)
```

`get-credentials` writes the config to `~/.kube/config`.

---

## 7. Give access to your teammate

`Contributor` role on the resource group (ACR + AKS access):

```fish
set RG_ID (az group show --name bernstein-rg --query id -o tsv)
az role assignment create --assignee firstname.lastname@epitech.eu --role Contributor --scope $RG_ID
```

`kubectl` access to the cluster:

```fish
set AKS_ID (az aks show -g bernstein-rg -n bernstein-aks --query id -o tsv)
az role assignment create --assignee firstname.lastname@epitech.eu --role "Azure Kubernetes Service Cluster User Role" --scope $AKS_ID
```

On the teammate's side:

```fish
az login
az account set --subscription "<owner's subscription>"
az acr login --name bernsteinacrmaeva
az aks get-credentials -g bernstein-rg -n bernstein-aks
```

> If `--assignee` returns "user not found": invite the teammate as a guest (Azure portal → Microsoft Entra ID → Users → Invite external user).

---

## 8. Build & push images to the ACR

Tag = short git SHA: a K8s rollout only triggers when the tag changes, and you always know which commit is running.

```fish
az acr login --name bernsteinacrmaeva
set TAG (git rev-parse --short HEAD)
set REG bernsteinacrmaeva.azurecr.io
for svc in poll result worker
    docker build -t $REG/$svc:$TAG poll-application/$svc
    docker push $REG/$svc:$TAG
end
az acr repository list --name bernsteinacrmaeva -o table
az acr repository show-tags --name bernsteinacrmaeva --repository poll -o table
```

### (Optional) Push from GitHub CI

Create a service principal limited to pushing:

```fish
set ACR_ID (az acr show --name bernsteinacrmaeva --query id -o tsv)
az ad sp create-for-rbac --name bernstein-ci --role AcrPush --scopes $ACR_ID
```

Add in GitHub → Settings → Secrets and variables → Actions:

- `ACR_LOGIN_SERVER` = `bernsteinacrmaeva.azurecr.io`
- `ACR_USERNAME` = `appId`
- `ACR_PASSWORD` = `password`

> Never commit these values.

---

## 9. Cost management

```fish
az aks stop  --resource-group bernstein-rg --name bernstein-aks   # shut down the nodes
az aks start --resource-group bernstein-rg --name bernstein-aks   # start them again
az group delete --name bernstein-rg --yes                         # delete EVERYTHING (end of project)
```

---

## Troubleshooting

| Error                                                             | Cause / Fix                                                                                    |
| ----------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| `az: command not found`                                           | Install aborted by `apt update` → `sudo apt-get update --allow-releaseinfo-change`, then rerun |
| `Valid PEM but no BEGIN/END delimiters for a private key`         | `--generate-ssh-keys` can't read the existing key → use `--no-ssh-key`                         |
| `The VM size of Standard_B2s is not allowed in your subscription` | Size not allowed → pick one from the returned list (`standard_d2als_v7`)                       |
| vCPU quota error                                                  | Student subscription ≈ 4 vCPU/region → `--node-count 1`                                        |
| `kubectl: command not found`                                      | `sudo snap install kubectl --classic`                                                          |
| `kubectl get nodes` → `No resources found`                        | Cluster still `Creating`, wait for `Succeeded`                                                 |

Check your quota:

```fish
az vm list-usage --location francecentral -o table | grep -i "total regional"
```
