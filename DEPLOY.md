# Deploy Bernstein

How to deploy the voting app on your own AKS cluster and private registry, from a fresh clone. Why each choice was made: [`doc/adr/`](doc/adr/README.md).

1. [Prerequisites](#1-prerequisites): tools, and an AKS cluster attached to a private ACR registry.
2. [Credentials](#2-credentials): where each credential lives. None of them goes into git.
3. [Deploy](#3-deploy): `REGISTRY=<name>.azurecr.io scripts/deploy.sh`.

## 1. Prerequisites

### Tools

Run the commands from Linux, macOS, or WSL2 on Windows: `scripts/deploy.sh` is a bash script.

| Tool             | Used for                                         | Tested with         |
| ---------------- | ------------------------------------------------ | ------------------- |
| `git`            | clone, image tag (commit SHA)                    | 2.53                |
| Docker           | build and push the images                        | 29.8                |
| `kubectl`        | deploy to the cluster                            | 1.37 (cluster 1.36) |
| Azure CLI (`az`) | log in to Azure, to the cluster, to the registry | 2.91                |

Install steps: [setup guide, prerequisites](doc/setup/cluster-setup.md#0-prerequisites).

### Azure resources

- An Azure subscription, with `az login` done.
- An **AKS cluster** and a **private ACR registry**, with the cluster allowed to pull from the registry (`--attach-acr`):
  - you have a cluster but no registry: [create the registry](doc/setup/cluster-setup.md#4-create-the-private-registry-acr), then [attach it to your cluster](doc/setup/cluster-setup.md#already-have-a-cluster-attach-the-registry);
  - you have neither: follow the [setup guide](doc/setup/cluster-setup.md) from step 1.
- Attaching needs the **Owner** role (or equivalent) on the subscription, because it creates a role assignment ([ADR 0002](doc/adr/0002-acr-registry.md)).

## 2. Credentials

The subject keeps the cloud credentials and `POSTGRES_PASSWORD` out of the delivery, and asks us to say where to set them ([subject](doc/subject/SUBJECT.md)). Each one lives here:

| Credential                            | Where it lives                             | How to set it                                                                                                                       |
| ------------------------------------- | ------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------- |
| Azure account                         | your `az` session                          | `az login`, then `az account set --subscription <name>` if you have several                                                         |
| Cluster access                        | `~/.kube/config`                           | `az aks get-credentials -g <resource-group> -n <cluster>`                                                                           |
| Push to the registry                  | short-lived Docker token                   | `scripts/deploy.sh` runs `az acr login`. Your account needs `AcrPush` on the registry, or Contributor / Owner on its resource group |
| Pull from the registry | the cluster's kubelet identity (`AcrPull`) | `--attach-acr`. Check it: [setup guide, step 6](doc/setup/cluster-setup.md#6-connect-kubectl-to-the-cluster) |
| `POSTGRES_PASSWORD`, `REDIS_PASSWORD` | `k8s/secrets.env` (gitignored)             | [see below](#app-secrets-k8ssecretsenv)                                                                                             |

There is no `imagePullSecret` and no registry password anywhere: the cluster pulls through its attached identity ([ADR 0002](doc/adr/0002-acr-registry.md)).

### App secrets: `k8s/secrets.env`

```bash
cp k8s/secrets.env.example k8s/secrets.env
```

Then edit `k8s/secrets.env`: one `KEY=value` per line, no quotes, no spaces around `=`.

| Key                 | Required | Effect                                     |
| ------------------- | -------- | ------------------------------------------ |
| `POSTGRES_PASSWORD` | yes      | Password of the PostgreSQL `postgres` user |
| `REDIS_PASSWORD`    | no       | Empty = Redis runs without authentication  |

- The file is gitignored. On deploy, Kustomize turns it into the `app-secrets` Secret ([ADR 0006](doc/adr/0006-secrets-secretgenerator.md)).
- `scripts/deploy.sh` stops before changing anything if the file is missing or `POSTGRES_PASSWORD` is empty.
- **Set the password before the first deploy.** PostgreSQL only reads it when it creates the database on an empty disk ([postgres image docs](https://hub.docker.com/_/postgres)). Changing it later in `secrets.env` does not change the password of the existing database, and the apps would be refused.

## 3. Deploy

```bash
REGISTRY=<name>.azurecr.io scripts/deploy.sh
```

It builds the 3 images, pushes them to your registry, deploys `k8s/`, waits until everything is ready and prints the public URLs of Poll and Result. Options: `scripts/deploy.sh --help`. Step-by-step checks, the live update, rollback and cleanup: in progress (#38).
