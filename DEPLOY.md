# Deploy Bernstein

How to deploy the voting app on your own AKS cluster and private registry, from a fresh clone. Why each choice was made: [`doc/adr/`](doc/adr/README.md). Last followed end to end from a fresh clone: 2026-10-27 (#39).

0. [Get the code](#0-get-the-code).
1. [Prerequisites](#1-prerequisites): tools, and an AKS cluster attached to a private ACR registry.
2. [Credentials](#2-credentials): where each credential lives. None of them goes into git.
3. [Deploy](#3-deploy): `REGISTRY=<name>.azurecr.io scripts/deploy.sh`, then check it works.
4. [Update with zero downtime](#4-update-the-app-with-zero-downtime): the graded test.
5. [Roll back](#5-roll-back).
6. [Stop or delete](#6-stop-or-delete-cost): cost.
7. [Troubleshooting](#7-troubleshooting).
8. [Back up and restore the votes](#8-back-up-and-restore-the-votes).

## 0. Get the code

```bash
git clone <repository-url> bernstein
cd bernstein
```

Run every command of this guide from this folder, the repository root. With Docker Desktop on Linux, clone inside your home folder: by default Docker cannot read other folders such as `/tmp`, and the build fails with `unable to prepare context: path ... not found`.

## 1. Prerequisites

### Tools

Run the commands from Linux, macOS, or WSL2 on Windows: `scripts/deploy.sh` is a bash script.

| Tool             | Used for                                                      | Tested with         |
| ---------------- | ------------------------------------------------------------- | ------------------- |
| `git`            | clone, image tag (commit SHA)                                 | 2.53                |
| Docker           | build and push the images (the Docker daemon must be running) | 29.8                |
| `kubectl`        | deploy to the cluster                                         | 1.37 (cluster 1.36) |
| Azure CLI (`az`) | log in to Azure, to the cluster, to the registry              | 2.91                |

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
| Pull from the registry                | the cluster's kubelet identity (`AcrPull`) | `--attach-acr`. [Check it](#check-the-pull-permission)                                                                              |
| `POSTGRES_PASSWORD`, `REDIS_PASSWORD` | `k8s/secrets.env` (gitignored)             | [see below](#app-secrets-k8ssecretsenv)                                                                                             |

There is no `imagePullSecret` and no registry password anywhere: the cluster pulls through its attached identity ([ADR 0002](doc/adr/0002-acr-registry.md)).

### Check the pull permission

The cluster's kubelet identity must hold `AcrPull` on the registry. This prints `AcrPull`:

```bash
KUBELET_ID=$(az aks show -g <resource-group> -n <cluster> --query identityProfile.kubeletidentity.objectId -o tsv)
az role assignment list --assignee "$KUBELET_ID" --scope "$(az acr show -n <name> --query id -o tsv)" \
  --query "[].roleDefinitionName" -o tsv
```

Nothing printed: [attach the registry](doc/setup/cluster-setup.md#already-have-a-cluster-attach-the-registry).

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

In order, the script:

1. checks the prerequisites above, and stops before changing anything if one is missing;
2. tags the images with the short git SHA (`<sha>-dirty-<date-time>` if `poll-application/` has uncommitted changes);
3. builds `poll`, `worker` and `result` for `linux/amd64` and pushes them to your registry;
4. applies `k8s/` with those images, through a generated overlay in `.deploy/`, and waits for every rollout;
5. waits for the public IPs and prints the URLs of Poll and Result.

The first run takes a few minutes (builds, first push, disk, public IPs); the next ones about a minute. Options: `scripts/deploy.sh --help`. Do not run `kubectl apply -k k8s/` by hand: the manifests name no registry, so the app pods would end in `ImagePullBackOff` ([ADR 0017](doc/adr/0017-deploy-script.md)).

### Check the deployment

```bash
kubectl -n bernstein get pods              # 7 pods READY: 2 poll, 2 result, worker, redis, postgres-0
kubectl -n bernstein get svc poll result   # EXTERNAL-IP of Poll and Result
```

Open the Poll URL and vote, then open the Result URL: the count updates live. The votes, from the command line:

```bash
kubectl -n bernstein exec postgres-0 -- psql -U postgres -d postgres -c "SELECT vote, COUNT(*) FROM votes GROUP BY vote"
```

**After `az aks stop` / `az aks start`:** the two public IPs of our cluster stayed the same across every restart (observed, not promised by Microsoft's docs). Read them again with `kubectl -n bernstein get svc poll result`. If `kubectl` cannot reach the cluster, run `az aks get-credentials` again first: the API server IP may change ([ADR 0001](doc/adr/0001-aks-cluster.md)).

## 4. Update the app with zero downtime

The graded test: change the code and redeploy while the app is being requested.

1. Change something visible, for example the `<h3>` title in `poll-application/poll/templates/index.html`. No commit needed: uncommitted changes get a `-dirty` tag, so a new rollout. Leave the vote option labels alone: Result has them hardcoded ([ADR 0011](doc/adr/0011-poll-deployment.md)).
2. Redeploy under the zero-downtime test:

   ```bash
   REGISTRY=<name>.azurecr.io tests/zero-downtime.sh -- scripts/deploy.sh
   ```

   It requests Poll and Result continuously while the script builds, pushes and rolls out, then prints every error, or `PASS: no failed request.` ([ADR 0016](doc/adr/0016-zero-downtime-test.md)).

3. Optional, in a second terminal: `kubectl -n bernstein get pods -w` shows the pods replaced one at a time.
4. Reload the Poll page: the new title shows, and "Processed by container ID" names the pod that answered.

Measured on AKS: live in 52 s, 0 errors in 1225 requests ([ADR 0017](doc/adr/0017-deploy-script.md)). Run the test from a machine whose connection is not busy: a big push (first deploy, all layers new) or another download slows down the test's own requests ([troubleshooting](#7-troubleshooting)).

## 5. Roll back

Both ways are rolling updates, with zero downtime.

- **Quick, until the next deploy:** one app back to its previous version. The next `scripts/deploy.sh` applies the current code again.

  ```bash
  kubectl -n bernstein rollout history deploy/poll   # the revisions
  kubectl -n bernstein rollout undo deploy/poll      # back to the previous one
  ```

- **Lasting:** redeploy a known-good tag. Nothing is built: the images are already in the registry.

  ```bash
  az acr repository show-tags --name <name> --repository poll --orderby time_desc -o table
  REGISTRY=<name>.azurecr.io TAG=<good tag> scripts/deploy.sh
  ```

Measured on AKS under `tests/zero-downtime.sh`: `rollout undo` 0 errors in 820 requests, `TAG=<sha>` 0 errors in 1017.

## 6. Stop or delete (cost)

Stop the nodes when nobody uses the app. Everything is kept; the disk, the public IPs and the registry are still billed.

```bash
az aks stop  -g <resource-group> -n <cluster>   # nodes off, compute not billed
az aks start -g <resource-group> -n <cluster>   # nodes on: the app starts again by itself
```

Delete the app only, and keep the cluster and the registry:

```bash
kubectl delete namespace bernstein
```

**This deletes the votes:** the PostgreSQL disk goes with its PVC (`reclaimPolicy: Delete`, [ADR 0007](doc/adr/0007-postgres-statefulset.md)). The next deploy starts with an empty database, and gets new public IPs: deleting the Services released the old ones (seen in #39).

Delete everything, after the defense:

```bash
az group delete --name <resource-group> --yes   # every resource in the group: cluster, registry, disks, IPs
```

## 7. Troubleshooting

| Symptom                                                                                                                                             | Likely cause                                                                          | Fix                                                                                                                                    |
| --------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `ImagePullBackOff` on poll, worker or result                                                                                                        | the cluster cannot pull from the registry, or `kubectl apply -k k8s/` was run by hand | [check the pull permission](#check-the-pull-permission); deploy with `scripts/deploy.sh`                                               |
| `EXTERNAL-IP` stays `<pending>`                                                                                                                     | Azure is still creating the public IP                                                 | wait 1 to 2 minutes (the script waits up to 5)                                                                                         |
| worker restarts, Result not ready; `kubectl -n bernstein logs deploy/worker` says `password authentication failed` or `password is an empty string` | `POSTGRES_PASSWORD` is empty, or differs from the one the database was created with   | put that password back in `k8s/secrets.env` and redeploy ([app secrets](#app-secrets-k8ssecretsenv))                                   |
| `kubectl` cannot reach the cluster after a restart (`i/o timeout`)                                                                                  | right after `az aks start` the API server can need a minute, or its IP changed        | wait a minute and retry; if it still fails: `az aks get-credentials -g <resource-group> -n <cluster> --overwrite-existing`             |
| `scripts/deploy.sh` stops with `ERROR: ...`                                                                                                         | a prerequisite is missing                                                             | the message names it and the command to fix it                                                                                         |
| `tests/zero-downtime.sh` shows timeouts on Poll **and** Result at the same seconds                                                                  | the test machine's own connection is busy (a big push, a system update downloading)   | rerun from an idle connection or another machine. A real rollout problem only hits the app being updated                               |
| Votes fail with HTTP 500, `kubectl -n bernstein logs deploy/poll` shows `OutOfMemoryError`                                                          | the Redis queue is full (100 MB): the worker or PostgreSQL has been down for a while  | bring the worker and PostgreSQL back: the queue drains and votes work again ([ADR 0018](doc/adr/0018-resource-requests-and-limits.md)) |

### Debug a broken pod

Start with the pods and the recent events, then follow the pod's `STATUS` below. Each case was reproduced on AKS with throwaway pods; the quoted lines are what the commands printed. Why there is no monitoring tool beyond these commands: [ADR 0024](doc/adr/0024-observability.md).

```bash
kubectl -n bernstein get pods -o wide                      # STATUS, READY, RESTARTS, node
kubectl -n bernstein get events --sort-by=.lastTimestamp   # newest last: pulls, probe failures, back-offs
kubectl -n bernstein describe pod <pod>                    # the pod's state, last state and events
```

**`Pending`, no node.** The scheduler found no node with room for it. The events of `describe pod` say why, for example `0/2 nodes are available: 2 Insufficient cpu.`: the pod's requests do not fit in what is left on any node. `kubectl describe nodes` shows each node's "Allocated resources". Lower the requests or add a node ([ADR 0018](doc/adr/0018-resource-requests-and-limits.md) for our sizing).

**`CrashLoopBackOff` or `Error`, `RESTARTS` going up.** The container starts, then exits. Read what it printed:

```bash
kubectl -n bernstein logs <pod>              # while it waits to restart: the run that just crashed
kubectl -n bernstein logs <pod> --previous   # once it runs again: the run that crashed
```

While the pod waits (`Error`, `CrashLoopBackOff`), `--previous` fails with `unable to retrieve container logs`: the crashed run is still the current one. Only the last crashed run is kept. Then look at `Last State` in `describe pod`:

- `Reason: Error`, `Exit Code: 1` (or another code): the app exited by itself; its logs say why.
- `Reason: OOMKilled`, `Exit Code: 137`: the container went over its memory limit and was killed. Raise `resources.limits.memory` in `k8s/<app>.yaml`, or find what uses the memory.

**`Running` but `READY 0/1`.** The process runs, but its readiness probe fails, so its Service sends it no traffic. The events of `describe pod` show the probe answer; in our test, a pod without `/readyz`:

```text
Readiness probe failed: HTTP probe failed with statuscode: 404
```

Our apps answer `503` when their dependency does not respond: Redis for Poll, PostgreSQL for Result, both for the worker ([app README](poll-application/README.md)). Check that dependency next: `kubectl -n bernstein get pods`, then `kubectl -n bernstein logs deploy/redis` or `kubectl -n bernstein logs postgres-0`. A `404` from one of our apps means a wrong probe path in `k8s/<app>.yaml`.

**`ImagePullBackOff`:** see the first row of the table above.

## 8. Back up and restore the votes

There is no automatic backup ([ADR 0019](doc/adr/0019-postgres-backup.md)). Dump the database to your machine, outside the repository:

```bash
kubectl -n bernstein exec postgres-0 -- pg_dump -U postgres -d postgres --clean --if-exists > ~/votes-backup.sql
```

Restore it. This replaces the `votes` table with the content of the dump:

```bash
kubectl -n bernstein exec -i postgres-0 -- psql -q -U postgres -d postgres < ~/votes-backup.sql
```

Tested on AKS: a dump of 6195 votes, restored into a scratch database, gave the same rows and the same checksum.
