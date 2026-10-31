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
  --network-plugin azure --network-plugin-mode overlay --network-dataplane cilium \
  --attach-acr "$ACR" --no-ssh-key
```

| Option                                                        | Why                                                                                                                                                                    |
| ------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--location spaincentral`                                     | `francecentral` only allows `v7` SKUs on Azure for Students, which have `0` vCPU quota; `spaincentral` allows `Bsv2`                                                   |
| `--node-count 2`                                              | Spreads the 2 poll/result replicas across nodes; fits within the 6 regional / 10 family vCPU quota (`2 × 2 = 4` vCPUs)                                                 |
| `--node-vm-size b2s_v2`                                       | 2 vCPU / 8 GB RAM (`Standard Bsv2 Family` has 10 vCPU quota in `spaincentral` on the student subscription)                                                             |
| `--network-plugin-mode overlay`, `--network-dataplane cilium` | Azure CNI Overlay with Cilium, which enforces the NetworkPolicies ([ADR 0025](../adr/0025-network-policies.md)). Ours was created without Cilium, then updated (below) |
| `--attach-acr`                                                | Grants the cluster pull access to the ACR (no `imagePullSecret` needed)                                                                                                |
| `--no-ssh-key`                                                | No SSH needed on nodes; avoids the `~/.ssh/id_rsa` parsing error                                                                                                       |

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

### Already have a cluster? Enable the network policy engine

`az aks show -g "$RG" -n "$AKS" --query networkProfile.networkPolicy -o tsv` prints `none`: the NetworkPolicies of `k8s/` would be ignored. Switch an Azure CNI cluster to Cilium:

```bash
az aks update --resource-group "$RG" --name "$AKS" --network-dataplane cilium --network-policy cilium
```

Both options are needed: with `--network-dataplane cilium` alone, AKS answers `Cilium dataplane requires network policy cilium`. The nodes are reimaged one at a time, like an upgrade, and the policies are enforced once all of them are done. Microsoft documents no way back to the previous dataplane ([ADR 0025](../adr/0025-network-policies.md)). Measured on ours: about 12 minutes, Result down twice for about 40 s and Poll once, while Redis and PostgreSQL moved.

### Control when AKS updates the nodes

With the `NodeImage` node OS channel (the default), AKS reimages the nodes with each new weekly node image, at a time it chooses, unless a maintenance window is set. A reimage moves Redis and PostgreSQL. Measured on 2026-10-31 (2 nodes, under `tests/zero-downtime.sh`): 1.3 % of Poll's requests and 0.25 % of Result's failed: Poll for 7 s while Redis moved, both apps for a few seconds of timeouts when a node restarted. The Result scores froze about 30 s ([ADR 0008](../adr/0008-result-deployment.md), [ADR 0023](../adr/0023-security-posture.md)). Allow node image updates (`aksManagedNodeOSUpgradeSchedule`) and AKS releases (`default`) only on Sunday from 03:00 to 07:00, Paris time:

```bash
az aks maintenanceconfiguration add -g "$RG" --cluster-name "$AKS" --name aksManagedNodeOSUpgradeSchedule \
  --schedule-type Weekly --day-of-week Sunday --interval-weeks 1 --duration 4 --utc-offset +01:00 --start-time 03:00
az aks maintenanceconfiguration add -g "$RG" --cluster-name "$AKS" --name default \
  --schedule-type Weekly --day-of-week Sunday --duration 4 --utc-offset +01:00 --start-time 03:00
az aks maintenanceconfiguration list -g "$RG" --cluster-name "$AKS" -o table
```

`default` refuses `--interval-weeks` (it is always weekly). It works on a stopped cluster. A stopped cluster runs no maintenance, so the nodes are only updated when we ask:

```bash
az aks nodepool get-upgrades -g "$RG" --cluster-name "$AKS" --nodepool-name nodepool1 --query latestNodeImageVersion -o tsv
az aks nodepool show -g "$RG" --cluster-name "$AKS" -n nodepool1 --query nodeImageVersion -o tsv
# Different? A few days before the defense, under tests/zero-downtime.sh (PostgreSQL moves: the Result scores freeze about 30 s):
az aks nodepool upgrade -g "$RG" --cluster-name "$AKS" -n nodepool1 --node-image-only
```

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

### (Optional) Log GitHub CI in to the registry (OIDC)

The CI job "Registry Login (Azure OIDC)" logs in to the registry with no password stored in GitHub ([ADR 0032](../adr/0032-ci-registry-oidc.md)): GitHub gives the job a short-lived token, and Entra ID trusts it through a federated credential of an app that has `AcrPush` on the registry ([Microsoft Learn: GitHub Actions with OIDC](https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure-openid-connect)). Already done for our repository and registry.

Run by the owner of the subscription: assigning a role needs `Owner` or `User Access Administrator`. `REPO` is the GitHub repository that runs the CI.

```bash
REPO=Nexlein/Bernstein
PREFIX=$(gh api "repos/$REPO" -q '"repo:\(.owner.login)@\(.owner.id)/\(.name)@\(.id)"')   # repo:Nexlein@183351649/Bernstein@1418620429
APP_ID=$(az ad app create --display-name bernstein-github-ci --query appId -o tsv)
az ad sp create --id "$APP_ID"
for cred in "main:ref:refs/heads/main" "pr:pull_request"; do
  az ad app federated-credential create --id "$APP_ID" --parameters "{
    \"name\": \"bernstein-gh-actions-${cred%%:*}\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"$PREFIX:${cred#*:}\",
    \"audiences\": [\"api://AzureADTokenExchange\"]}"
done
az role assignment create --assignee "$APP_ID" --role AcrPush --scope "$(az acr show --name "$ACR" --query id -o tsv)"
```

Then the 4 GitHub secrets (Settings → Secrets and variables → Actions, or `gh`). They are identifiers, not passwords; the job fails with the list of the missing ones:

```bash
gh secret set AZURE_CLIENT_ID --repo "$REPO" --body "$APP_ID"
gh secret set AZURE_TENANT_ID --repo "$REPO" --body "$(az account show --query tenantId -o tsv)"
gh secret set AZURE_SUBSCRIPTION_ID --repo "$REPO" --body "$(az account show --query id -o tsv)"
gh secret set ACR_NAME --repo "$REPO" --body "$ACR"
```

- The subject holds the IDs of the account and the repository: GitHub uses this immutable format for every repository created after 2026-07-15, so a new repository with the same name cannot reuse our credentials ([GitHub Docs: OIDC reference](https://docs.github.com/en/actions/reference/security/oidc)). An older repository keeps `repo:<owner>/<repo>` unless it opts in; `gh api repos/$REPO/actions/oidc/customization/sub` tells which.
- `AADSTS700213: No matching federated identity record found` means the subject does not match: the failed `azure/login` step prints the `subject claim` GitHub sent.
- The 2 subjects cover a push to `main` (also `schedule` and `workflow_dispatch` runs on `main`) and the pull requests. A job with an `environment:` gets the subject `<prefix>:environment:<name>` and would need one more credential.
- In a fork, set `REPO` to the fork, and change the repository name in the job's `if:` in `.github/workflows/ci.yml`, or the job is skipped.

---

## 9. Stop or delete (cost)

Stop the nodes when idle, delete the app or everything after the defense: [`DEPLOY.md`](../../DEPLOY.md#6-stop-or-delete-cost).

### (Optional) Stop the cluster every night from GitHub Actions

The workflow `.github/workflows/nightly-stop.yml` stops the cluster at 23:00, Paris time, when it is still running ([ADR 0035](../adr/0035-nightly-stop.md)). It uses the CI app of [section 8](#optional-log-github-ci-in-to-the-registry-oidc), which needs one more role, limited to reading and stopping the cluster. Run by the owner of the subscription, with `APP_ID` as in section 8:

```bash
cat > aks-stop-role.json <<EOF
{
  "Name": "Bernstein AKS Stopper",
  "Description": "Read and stop the Bernstein AKS cluster: nightly stop from GitHub Actions (#110).",
  "Actions": [
    "Microsoft.ContainerService/managedClusters/read",
    "Microsoft.ContainerService/managedClusters/stop/action"
  ],
  "AssignableScopes": ["$(az group show -n "$RG" --query id -o tsv)"]
}
EOF
az role definition create --role-definition aks-stop-role.json
az role assignment create --assignee "$APP_ID" --role "Bernstein AKS Stopper" --scope "$(az aks show -g "$RG" -n "$AKS" --query id -o tsv)"
```

If the assignment says the role does not exist, Azure has not spread the new role yet: wait a minute or two and run the last line again. Then run the workflow once by hand: `gh workflow run nightly-stop.yml`, with the cluster running; its log ends with the power state `Stopped`. In a fork, change the repository name in the job's `if:`, and the resource group and cluster names in its `env:`.

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
