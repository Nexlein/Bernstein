# Deploy Bernstein

How to deploy the voting app on your own AKS cluster and private registry, from a fresh clone. Why each choice was made: [`doc/adr/`](doc/adr/README.md). Last followed end to end from a fresh clone of the Epitech mirror: 2026-10-28 (#100).

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
- **Kubernetes 1.31 or later** on the cluster. The manifests use the `preStop` sleep action, on by default since 1.30 ([PodLifecycleSleepAction](https://kubernetes.io/docs/reference/command-line-tools-reference/feature-gates/#PodLifecycleSleepAction)), and `matchLabelKeys` in the pod anti-affinity, on by default since 1.31 ([MatchLabelKeysInPodAffinity](https://kubernetes.io/docs/reference/command-line-tools-reference/feature-gates/#MatchLabelKeysInPodAffinity)). AKS offered 1.31 to 1.37 on 2026-10-28 (`az aks get-versions -l <location> -o table`); we test on 1.36.
- A **network policy engine** on the cluster, so that `k8s/network-policies.yaml` is enforced. Without one, the policies are accepted and ignored: the app works, but any pod can reach Redis and PostgreSQL ([ADR 0025](doc/adr/0025-network-policies.md)). Check it, this must not print `none`:

  ```bash
  az aks show -g <resource-group> -n <cluster> --query networkProfile.networkPolicy -o tsv
  ```

  `none`: [enable Cilium](doc/setup/cluster-setup.md#already-have-a-cluster-enable-the-network-policy-engine) (the nodes are reimaged). `scripts/deploy.sh` also prints a `WARNING` when it finds no policy engine (Cilium, Calico or Azure NPM) in the cluster.

## 2. Credentials

The subject keeps the cloud credentials and `POSTGRES_PASSWORD` out of the delivery, and asks us to say where to set them ([subject](doc/subject/SUBJECT.md)). Each one lives here:

| Credential                           | Where it lives                             | How to set it                                                                                                                       |
| ------------------------------------ | ------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------- |
| Azure account                        | your `az` session                          | `az login`, then `az account set --subscription <name>` if you have several                                                         |
| Cluster access                       | `~/.kube/config`                           | `az aks get-credentials -g <resource-group> -n <cluster>`                                                                           |
| Push to the registry                 | short-lived Docker token                   | `scripts/deploy.sh` runs `az acr login`. Your account needs `AcrPush` on the registry, or Contributor / Owner on its resource group |
| Pull from the registry               | the cluster's kubelet identity (`AcrPull`) | `--attach-acr`. [Check it](#check-the-pull-permission)                                                                              |
| Database passwords, `REDIS_PASSWORD` | `k8s/secrets.env` (gitignored)             | [see below](#app-secrets-k8ssecretsenv)                                                                                             |

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

| Key                  | Required | Effect                                                                           |
| -------------------- | -------- | -------------------------------------------------------------------------------- |
| `POSTGRES_PASSWORD`  | yes      | Password of the PostgreSQL `postgres` superuser (the database itself, backups)   |
| `RESULT_DB_PASSWORD` | yes      | Password of `result_reader`, the user Result connects with (may only read votes) |
| `WORKER_DB_PASSWORD` | yes      | Password of `worker_writer`, the user the worker connects with (may write votes) |
| `REDIS_PASSWORD`     | no       | Empty = Redis runs without authentication                                        |

Any values work, for example from `openssl rand -hex 24`. Everyone deploying to the same cluster must use the same values ([ADR 0023](doc/adr/0023-security-posture.md)).

- The file is gitignored. On deploy, Kustomize turns it into the `app-secrets` Secret ([ADR 0006](doc/adr/0006-secrets-secretgenerator.md)).
- `scripts/deploy.sh` stops before changing anything if the file is missing or one of the 3 database passwords is empty.
- **Set `POSTGRES_PASSWORD` before the first deploy.** PostgreSQL only reads it when it creates the database on an empty disk ([postgres image docs](https://hub.docker.com/_/postgres)). Changing it later in `secrets.env` does not change the password of the existing database. The two app passwords can change at any time: every `scripts/deploy.sh` applies them (`k8s/users.sh`).

## 3. Deploy

```bash
REGISTRY=<name>.azurecr.io scripts/deploy.sh
```

In order, the script:

1. checks the prerequisites above, and stops before changing anything if one is missing;
2. tags each image with the short SHA of the last commit that changed its folder, `poll-application/<app>` (`<sha>-dirty-<date-time>` if that folder has uncommitted changes);
3. builds for `linux/amd64` and pushes the images your registry does not have yet: an app whose code did not change keeps its tag and is not rebuilt;
4. applies `k8s/` with those images, through a generated overlay in `.deploy/`, and waits for every rollout. Once PostgreSQL is ready, it creates or updates the database users of Result and the worker (`k8s/users.sh`);
5. waits for the public IPs and prints the URLs of Poll and Result.

Measured from a fresh clone of the Epitech mirror: 2 min 11 s for the first run (base images pulled, 3 images built and pushed, disk and public IPs created); the next ones build and roll only the apps whose code changed. Options: `scripts/deploy.sh --help`. Do not run `kubectl apply -k k8s/` by hand: the manifests name no registry, so the app pods would end in `ImagePullBackOff` ([ADR 0017](doc/adr/0017-deploy-script.md)).

### Check the deployment

```bash
kubectl -n bernstein get pods              # 7 pods READY: 2 poll, 2 result, worker, redis, postgres-0
kubectl -n bernstein get svc poll result   # EXTERNAL-IP of Poll and Result
kubectl -n bernstein get deploy -o wide    # IMAGES: the tag each app runs
```

Open the Poll URL and vote, then open the Result URL: the count updates live. The votes, from the command line:

```bash
kubectl -n bernstein exec postgres-0 -- psql -U postgres -d postgres -c "SELECT vote, COUNT(*) FROM votes GROUP BY vote"
```

**After `az aks stop` / `az aks start`:** the two public IPs of our cluster stayed the same across every restart (observed, not promised by Microsoft's docs). Read them again with `kubectl -n bernstein get svc poll result`. If `kubectl` cannot reach the cluster, run `az aks get-credentials` again first: the API server IP may change ([ADR 0001](doc/adr/0001-aks-cluster.md)).

## 4. Update the app with zero downtime

The graded test: change the code and redeploy while the app is being requested.

First check your own connection, with nothing deploying. This must end with `PASS: no failed request.`:

```bash
DURATION=60 tests/zero-downtime.sh
```

If it fails, the network between your machine and Azure drops connections, and the graded run would fail for that reason: use another connection ([troubleshooting](#7-troubleshooting)). The `--from both` option below also tells such errors apart.

1. Change something visible, for example the `<h3>` title in `poll-application/poll/templates/index.html`. No commit needed: uncommitted changes give Poll a `-dirty` tag, so a rollout of Poll only; Result and the worker keep their tag and stay `unchanged`. Leave the vote option labels alone: Result has them hardcoded ([ADR 0011](doc/adr/0011-poll-deployment.md)).
2. Redeploy under the zero-downtime test:

   ```bash
   REGISTRY=<name>.azurecr.io tests/zero-downtime.sh --from both -- scripts/deploy.sh
   ```

   It requests Poll and Result continuously while the script builds, pushes and rolls out, then prints every error, or `PASS: no failed request.` ([ADR 0016](doc/adr/0016-zero-downtime-test.md)).

   `--from both` sends the same requests from your machine and from a pod inside the cluster, with one summary line for each: `poll` and `result` from your machine, `poll@cluster` and `result@cluster` from the pod. An error only on the lines from your machine comes from the network between you and Azure, not from the rollout. The pod (image `curlimages/curl`, from Docker Hub) runs in its own namespace, `zero-downtime`, and is deleted at the end, also after Ctrl-C. The empty namespace stays: `kubectl delete namespace zero-downtime` removes it.

   `kubectl` prints `statefulset.apps/postgres configured` and the PodDisruptionBudgets `configured` on every run, even when nothing changed for them. PostgreSQL is not restarted: its start time stays the same and `kubectl diff` shows no difference.

3. Optional, in a second terminal: `kubectl -n bernstein get pods -w` shows the pods replaced one at a time.
4. Reload the Poll page: the new title shows, and "Processed by container ID" names the pod that answered.

Measured on AKS: only Poll rebuilt and rolled, the script took 34 s (52 s when the 3 apps rolled), 0 errors in 1363 requests from the client and 3080 from inside the cluster ([ADR 0017](doc/adr/0017-deploy-script.md)). Run the test from a machine whose connection is not busy: a big push (first deploy, all layers new) or another download slows down the test's own requests ([troubleshooting](#7-troubleshooting)).

### Update Redis or PostgreSQL

Their images are pinned by version and digest in `k8s/redis.yaml`, `k8s/postgres.yaml` and `docker-compose.yml`: a new node pulls the same image, and a version changes only through a commit ([ADR 0007](doc/adr/0007-postgres-statefulset.md)). Dependabot opens a pull request when a newer minor or patch version is out. By hand, read the digest of the new tag, then put `<tag>@<digest>` in the manifest and in `docker-compose.yml`:

```bash
docker buildx imagetools inspect postgres:<new tag> | grep -m1 Digest
REGISTRY=<name>.azurecr.io tests/zero-downtime.sh --from both -- scripts/deploy.sh
```

Redis rolls with no error for Poll. PostgreSQL has a single pod, so it restarts: Result is down meanwhile (49 s measured), and the votes wait in Redis ([ADR 0009](doc/adr/0009-redis-queue.md)). Never move PostgreSQL to another major version (18 to 19) this way: its data needs `pg_upgrade` first.

## 5. Roll back

Both ways are rolling updates, with zero downtime.

- **Quick, until the next deploy:** one app back to its previous version. The next `scripts/deploy.sh` applies the current code again.

  ```bash
  kubectl -n bernstein rollout history deploy/poll   # the revisions
  kubectl -n bernstein rollout undo deploy/poll      # back to the previous one
  ```

- **From the registry:** redeploy a known-good tag of one app. Nothing is built: the image is already in the registry, and the other apps keep their tag. A later `scripts/deploy.sh` without it deploys the code as it is again: fix or revert the code too.

  ```bash
  kubectl -n bernstein get deploy -o wide                                    # the tag each app runs now
  az acr repository show-tags --name <name> --repository poll --orderby time_desc -o table
  REGISTRY=<name>.azurecr.io POLL_TAG=<good tag> scripts/deploy.sh          # WORKER_TAG, RESULT_TAG for the others
  ```

  `TAG=<tag>` sets the same tag for the 3 apps, for a tag they all have.

Measured on AKS under `tests/zero-downtime.sh`: `rollout undo` 0 errors in 820 requests, `TAG=<sha>` 0 errors in 1017, `POLL_TAG=<older tag>` (only Poll rolled, 31 s) 0 errors in 1270 requests from the client and 2865 from inside the cluster.

A given tag (`TAG`, `POLL_TAG`…) is never built: the script first checks that it exists in the registry, so a mistyped tag stops it before anything is applied.

### When an update fails

A new version that never gets Ready (missing image, crash at start, a dependency it cannot reach) does not take the app down. With `maxUnavailable: 0`, an old pod stops only after a new one is Ready: the old pods keep serving, and the broken pod gets no traffic. After 2 minutes without progress (`progressDeadlineSeconds: 120`), the rollout is marked failed and `scripts/deploy.sh` stops with:

```text
error: deployment "poll" exceeded its progress deadline
ERROR: rollout not finished: deployment/poll. The previous pods keep serving.
  Why:       kubectl -n bernstein get pods, then describe the new pod (DEPLOY.md, Debug a broken pod)
  Roll back: kubectl -n bernstein rollout undo deployment/poll
         or: REGISTRY=<name>.azurecr.io POLL_TAG=<good tag> scripts/deploy.sh
```

Nothing is rolled back by itself: find the cause ([debug a broken pod](#debug-a-broken-pod)), then fix the code and redeploy, or roll back as above. The broken pod stays until then.

`rollout undo` prints `Warning: resource deployments/poll was previously managed with 'kubectl apply'`. Harmless here: the next `scripts/deploy.sh` applies the full manifests again.

Measured on AKS, with a probe inside the cluster requesting Poll and Result in a loop (`wget`, a pause of 0.1 s): 0 errors in each case.

- Image tag that does not exist: the new pod stays in `ImagePullBackOff`.
- Container that exits at start: `CrashLoopBackOff`.
- Poll that cannot reach Redis: `Running` but never Ready (`0/1`).
- That broken Poll deployed with `scripts/deploy.sh`: failed after 2 minutes with the message above. `TAG=<previous tag>` then rolled Poll back in about 16 s.

The external `tests/zero-downtime.sh` run at the same time logged 0.3 to 1.2 % timeouts, the level of our home connection with nothing deploying ([troubleshooting](#7-troubleshooting)).

## 6. Stop or delete (cost)

Stop the nodes when nobody uses the app. Everything is kept. Measured on our subscription ([ADR 0001](doc/adr/0001-aks-cluster.md#cost)): **0.47 € a day stopped**, plus **about 0.2 € per hour running** (the nodes and their OS disks). Stopped, the 3 public IPs (0.32 € a day), the registry (0.15 €) and the PostgreSQL disk are still billed; the load balancer is free within the Azure for Students offer.

```bash
az aks stop  -g <resource-group> -n <cluster>   # nodes off, compute not billed
az aks start -g <resource-group> -n <cluster>   # nodes on: the app starts again by itself
```

### After `az aks start`

The first node to be ready gets every pod: after each start we checked (5 out of 5, last on 2026-10-28), all 7 pods ran on one node. The anti-affinity places pods but never moves them ([ADR 0013](doc/adr/0013-pod-anti-affinity.md)), so losing or draining that node would take Poll and Result down together. Check the `NODE` column, then restart Poll and Result to spread them:

```bash
kubectl -n bernstein get pods -l 'app.kubernetes.io/name in (poll,result)' -o wide
tests/zero-downtime.sh --from both -- sh -c 'kubectl -n bernstein rollout restart deploy/poll deploy/result && kubectl -n bernstein rollout status deploy/poll && kubectl -n bernstein rollout status deploy/result'
```

Measured on 2026-10-28: before, the 2 Poll and 2 Result pods on one node; after, one of each per node, with 0 errors in 1280 requests from the client and 2765 from inside the cluster.

Delete the app only, and keep the cluster and the registry:

```bash
kubectl delete namespace bernstein
```

It saves little (the 2 public IPs of Poll and Result, 0.21 € a day), and **it deletes the votes:** the PostgreSQL disk goes with its PVC (`reclaimPolicy: Delete`, [ADR 0007](doc/adr/0007-postgres-statefulset.md)). The next deploy starts with an empty database, and gets new public IPs: deleting the Services released the old ones (seen in #39).

Delete everything, after the defense:

```bash
az group delete --name <resource-group> --yes   # every resource in the group: cluster, registry, disks, IPs
```

Nothing is billed afterwards: the cluster's node resource group (`MC_…`) is deleted with the cluster.

## 7. Troubleshooting

| Symptom                                                                                                                                                | Likely cause                                                                                                                                                     | Fix                                                                                                                                                                                                                                                                                                            |
| ------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ImagePullBackOff` on poll, worker or result                                                                                                           | the cluster cannot pull from the registry, or `kubectl apply -k k8s/` was run by hand                                                                            | [check the pull permission](#check-the-pull-permission); deploy with `scripts/deploy.sh`                                                                                                                                                                                                                       |
| `EXTERNAL-IP` stays `<pending>`                                                                                                                        | Azure is still creating the public IP                                                                                                                            | wait 1 to 2 minutes (the script waits up to 5)                                                                                                                                                                                                                                                                 |
| worker restarts, Result not ready; `kubectl -n bernstein logs deploy/worker` says `password authentication failed` or `password is an empty string`    | a database password is empty, or `POSTGRES_PASSWORD` differs from the one the database was created with, or `scripts/deploy.sh` stopped before syncing the users | put that password back in `k8s/secrets.env` and redeploy ([app secrets](#app-secrets-k8ssecretsenv))                                                                                                                                                                                                           |
| `kubectl` cannot reach the cluster after a restart (`i/o timeout`)                                                                                     | right after `az aks start` the API server can need a minute, or its IP changed                                                                                   | wait a minute and retry; if it still fails: `az aks get-credentials -g <resource-group> -n <cluster> --overwrite-existing`                                                                                                                                                                                     |
| `scripts/deploy.sh` stops with `ERROR: ...`, or `ERROR: step "<step>" failed ... line <n>: <command>`                                                  | a prerequisite is missing, or a command failed in that step                                                                                                      | the message names the fix, or the command that failed: its own output is just above                                                                                                                                                                                                                            |
| `scripts/deploy.sh` stops with `exceeded its progress deadline`                                                                                        | the new version never gets Ready: missing image, crash at start, a dependency it cannot reach. The old pods keep serving                                         | find the cause ([debug a broken pod](#debug-a-broken-pod)), then fix and redeploy, or roll back ([when an update fails](#when-an-update-fails))                                                                                                                                                                |
| `tests/zero-downtime.sh` shows timeouts (`curl exit 28`) on Poll and Result, also in a `DURATION=60 tests/zero-downtime.sh` run with nothing deploying | the network between your machine and Azure drops or delays connections: a busy upload, a weak home connection                                                    | rerun from another connection, and read the `@cluster` lines of a `--from both` run: they do not cross your network. Measured from a home connection at rest: 0.2 to 1.6 % connect timeouts, while a probe inside the cluster saw 0 errors in 11 500 requests ([ADR 0016](doc/adr/0016-zero-downtime-test.md)) |
| Votes fail with HTTP 500, `kubectl -n bernstein logs deploy/poll` shows `OutOfMemoryError`                                                             | the Redis queue is full (100 MB): the worker or PostgreSQL has been down for a while                                                                             | bring the worker and PostgreSQL back: the queue drains and votes work again ([ADR 0018](doc/adr/0018-resource-requests-and-limits.md))                                                                                                                                                                         |
| A pod you added cannot reach Redis, PostgreSQL or the internet (timeouts)                                                                              | `k8s/network-policies.yaml` denies every flow it does not list                                                                                                   | add an allow rule for the new flow ([ADR 0025](doc/adr/0025-network-policies.md))                                                                                                                                                                                                                              |

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

Tested on AKS: a dump of 6195 votes, restored into a scratch database, gave the same rows and the same checksum. On the live database (2026-10-28): 25 votes, then a restore of a dump taken at 20, gave exactly those 20. `psql` prints one `set_config` line: that is expected.

A dump taken before the app users existed (#109) restores the table without their rights: run `scripts/deploy.sh` after it, which grants them again.
