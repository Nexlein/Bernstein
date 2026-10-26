# Technical Decisions

Why the deployment is built the way it is. Each section gives the choice, its pros and cons, the alternatives we looked at and why we did not take them.

Convention: lines marked **Fact** are backed by the linked source. Everything else is our own reasoning, to be defended at the review.

Summary:

| Topic         | Choice                                                                                  |
| ------------- | --------------------------------------------------------------------------------------- |
| Cloud / K8s   | Azure Kubernetes Service (AKS), Free tier (`spaincentral`, 2 × `Standard_B2s_v2` nodes) |
| Registry      | Azure Container Registry (ACR), Basic SKU (`bernsteinacrmaeva`, `francecentral`)        |
| Manifests     | Kustomize (`k8s/`, `kubectl apply -k`)                                                  |
| Public access | One `Service` of type `LoadBalancer` each for Poll and Result                           |
| Image tags    | Git commit SHA                                                                          |
| Secrets       | Kustomize `secretGenerator` from a gitignored `k8s/secrets.env`                         |
| Database      | PostgreSQL `StatefulSet` (1 replica) on an Azure Disk PVC, `ClusterIP` Service          |
| Result        | `Deployment`, 2 fixed replicas, no HPA, non-root with a read-only root filesystem       |
| Queue         | Redis `Deployment` (1 replica), in-memory only, `ClusterIP` Service                     |
| Worker        | `Deployment` (1 replica), no Service, probes check Redis and PostgreSQL                 |
| Poll          | `Deployment`, 2 replicas, read-only root filesystem with an in-memory `/tmp`            |

Step-by-step setup and lifecycle commands: [`doc/setup/cluster-setup.md`](setup/cluster-setup.md).

---

## 1. Cloud / Kubernetes: AKS

**Choice:** AKS (`bernstein-aks`), Free tier, in `spaincentral`, with **2 `Standard_B2s_v2` nodes** (2 vCPUs, 8 GiB RAM per node; 4 vCPUs, 16 GiB total). Stopped when not in use.

**Pros**

- Epitech students get Azure credits, and the subject points to them. No personal card or extra budget needed.
- **Fact:** The Free tier has free cluster management; only the consumed resources (nodes, disks, IPs) are billed. It is meant for dev/test and clusters under 10 nodes. ([Microsoft Learn: AKS pricing tiers](https://learn.microsoft.com/en-us/azure/aks/free-standard-pricing-tiers))
- **Why 2 nodes (`--node-count 2`):**
  - Minimum node count required to survive a node drain (`kubectl drain`, explicitly listed in the defense topics) or single-VM failure without a service outage.
  - Allows `poll` and `result` (`replicas: 2`) to spread across two distinct physical VMs via `podAntiAffinity`, and provides scheduling headroom for `maxSurge: 1` during zero-downtime rolling updates.
- **Why `Standard_B2s_v2` (2 vCPU, 8 GiB RAM) in `spaincentral`:**
  - **Fact:** `Standard_B2s_v2` provides 2 vCPUs and 8 GiB of memory on burstable B-series hardware, accruing CPU credits when idle and bursting during rollouts. ([Microsoft Learn: Bsv2-series sizes](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/general-purpose/bsv2-series))
  - 8 GiB RAM per node (16 GiB total) comfortably fits `kube-system` daemons, the JVM-based `worker`, `postgres`, `redis`, and replicated `poll`/`result` pods with `resources.requests` and `resources.limits` enforced.
  - On Azure for Students subscriptions, `francecentral` only exposes `v7` VM families (`StandardDalsv7Family`) with a `0` vCPU quota, whereas `spaincentral` grants a 10 vCPU quota for `Standard Bsv2` (and 6 regional vCPUs total, within which `2 × 2 = 4` vCPUs fit).
- **Fact:** A cluster can be stopped with `az aks stop` and started again with `az aks start`. Compute is not billed while stopped and all objects except standalone pods are kept. ([Microsoft Learn: Stop and start an AKS cluster](https://learn.microsoft.com/en-us/azure/aks/start-stop-cluster))
- Same cloud as the registry, so image pulls need no extra secret (see section 2).

**Cons**

- **Fact:** The Free tier has no financially backed uptime SLA for the API server. ([same source](https://learn.microsoft.com/en-us/azure/aks/free-standard-pricing-tiers)) Acceptable for a school project; the running workloads are not affected by API server hiccups.
- Ties the delivery to Azure. The subject accepts this: the evaluator uses a cluster "on the same platform".
- **Fact:** After a stop/start, the API server IP may change. ([same source as stop/start](https://learn.microsoft.com/en-us/azure/aks/start-stop-cluster)) Run `az aks get-credentials` again after a restart.
- **Fact:** B-series VMs are burstable: they run at a CPU baseline below 100% and only go above it while they have CPU credits left. ([Microsoft Learn: Bsv2-series sizes](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/general-purpose/bsv2-series)) A long load test can drain the credits and throttle the nodes. We watch this during the rollout test (#30).

**Alternatives not taken**

- **1 node (`--node-count 1`):** halves VM cost, but any `kubectl drain` or VM reboot causes 100% downtime because evicted pods have nowhere to reschedule.
- **3+ nodes:** burns 50%+ more student credits and hits the 6 vCPU regional student quota ceiling (`3 × 2 = 6` vCPUs) with no extra value for our 5 services.
- **GKE / EKS:** good managed offers, but no Epitech credits. EKS bills the control plane per hour ([AWS: EKS pricing](https://aws.amazon.com/eks/pricing/)).
- **DigitalOcean (GitHub Student Pack):** simple and cheap, but the credit is limited and a second cloud account is needed by every evaluator.
- **Self-managed (k3s, kubeadm on VMs, minikube):** we would operate the control plane ourselves, and a local cluster is not reachable from the outside world. The subject "highly recommends" Kubernetes-as-a-Service.

**Revisit if:** the Azure credits run out before the defense.

---

## 2. Private registry: ACR

**Choice:** ACR (`bernsteinacrmaeva.azurecr.io`), Basic SKU in `francecentral`, attached to the AKS cluster (`--attach-acr`).

**Pros**

- **Fact:** `az aks update --attach-acr <registry>` (or `az aks create --attach-acr`) gives the cluster's kubelet managed identity the `AcrPull` role on the registry. Nodes then pull images with no `imagePullSecret` in the manifests. ([Microsoft Learn: Integrate ACR with AKS](https://learn.microsoft.com/en-us/azure/aks/cluster-container-registry-integration))
- No registry password lives in the cluster or in git: this fits our secret-separation rule. Local pushes authenticate via `az login` + `az acr login --name bernsteinacrmaeva` (see [`doc/setup/cluster-setup.md`](setup/cluster-setup.md)).
- **Fact:** The Basic SKU has the same data-plane API as the other SKUs, 10 GiB of included storage, and no anonymous pull access (Standard and Premium only). So the registry is private by default. ([Microsoft Learn: ACR SKUs](https://learn.microsoft.com/en-us/azure/container-registry/container-registry-skus)) Our 3 images fit easily in 10 GiB.

**Cons**

- Basic is billed per day even when idle (small, but not zero). Pricing: [azure.microsoft.com](https://azure.microsoft.com/pricing/details/container-registry/).
- The person running `--attach-acr` needs the Owner (or equivalent) role on the subscription. ([same source](https://learn.microsoft.com/en-us/azure/aks/cluster-container-registry-integration))
- **Fact:** No private endpoints or IP rules on Basic (Premium only). ([same source](https://learn.microsoft.com/en-us/azure/container-registry/container-registry-skus)) The registry is private (auth required) but reachable over the internet.

**Alternatives not taken**

- **Docker Hub / GHCR private repositories:** free or cheap, but they need a long-lived token stored as an `imagePullSecret` in the cluster, and a second account for the evaluator.
- **Self-hosted registry (`registry:2` in the cluster):** one more stateful service to run, secure with TLS and back up. No gain for the project.
- **ACR Standard / Premium:** more storage, geo-replication and private link we do not need.

---

## 3. Manifests: Kustomize

**Choice:** Plain Kubernetes YAML in `k8s/`, assembled with a `kustomization.yaml`. Deployed with `kubectl apply -k k8s/`.

**Pros**

- **Fact:** Kustomize is built into `kubectl` since 1.14 (`kubectl apply -k <dir>`, preview with `kubectl kustomize <dir>`). ([Kubernetes docs: Kustomize](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/)) The evaluator needs no extra tool.
- The manifests stay readable YAML, with no template language. Easy to explain line by line at the defense.
- **Fact:** The `images` field rewrites image names and tags without editing the Deployments ([Kustomize reference: images](https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/images/)). The pipeline sets the git SHA there. `configMapGenerator` / `secretGenerator` add a content hash to the name, so a config change triggers a rollout ([Kubernetes docs](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/)).

**Cons**

- No release history or `rollback` command like Helm. We use `kubectl rollout undo` per Deployment instead.
- Less powerful than a template engine for many environments. We have one environment, so this does not matter.

**Alternatives not taken**

- **Helm:** a chart is useful to publish an app for others. For our own single deployment, it adds a binary and Go templates for no real gain.
- **Raw `kubectl apply -f`:** works, but the image tag would have to be edited with `sed` in every file. Kustomize does this cleanly.
- **Terraform Kubernetes provider:** mixes infra and app deploys in one state file; heavier to learn and to hand over.

---

## 4. Public access: one LoadBalancer Service per app

**Choice:** `poll` and `result` each get a `Service` of type `LoadBalancer`. Redis, Postgres and Worker stay `ClusterIP` (internal only). No Ingress controller.

**Pros**

- **Fact:** The subject asks for both pages to be "accessible from the outside world" and lets us give the evaluator "the external IP addresses". Two IPs match this directly. ([subject PDF](subject/bernstein-project.pdf))
- **Fact:** AKS uses the Standard Azure Load Balancer by default. Each `LoadBalancer` Service gets its own frontend public IP, shown in `kubectl get service` under `EXTERNAL-IP`. ([Microsoft Learn: Standard Load Balancer in AKS](https://learn.microsoft.com/en-us/azure/aks/load-balancer-standard))
- Nothing to install: no Helm chart, no CRDs, no controller to keep patched. One less component that can fail or break during the zero-downtime test.
- **Fact:** Azure Load Balancer works at layer 4 ([same source](https://learn.microsoft.com/en-us/azure/aks/load-balancer-standard)). It forwards TCP as-is, so Result's WebSocket works with no extra config.

**Cons**

- Two public IPs instead of one. Each Standard public IP is billed per hour ([Azure: IP address pricing](https://azure.microsoft.com/pricing/details/ip-addresses/)). Small compared to the nodes.
- No host/path routing and no TLS termination. Not required by the subject.
- We keep the default `externalTrafficPolicy: Cluster`: every node accepts the traffic and kube-proxy forwards it to a ready pod, possibly on the other node (one extra hop), and the app sees a node IP instead of the visitor's IP. **Fact:** `Local` keeps the client IP but only sends traffic to nodes that run a ready pod of the Service. ([Kubernetes docs: Preserving the client source IP](https://kubernetes.io/docs/tasks/access-application-cluster/create-external-load-balancer/#preserving-the-client-source-ip)) With `Local`, a node whose pods are being replaced keeps receiving traffic until the Azure health probe notices, a risk during rollouts that buys us nothing: the apps do not use the client IP.
- Zero downtime still depends on us: during a rollout, a terminating pod can receive traffic until its endpoint is removed everywhere. We handle this with readiness probes, a `preStop` sleep and `maxUnavailable: 0` (issues #27, #28). **Fact:** endpoint removal and the `SIGTERM` happen in parallel. ([Kubernetes docs: Pod termination](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#pod-termination))

**Alternatives not taken**

- **ingress-nginx:** **Fact:** retired upstream. Best-effort maintenance ended in March 2026, with no more releases or security fixes after that. ([Kubernetes blog: Ingress NGINX retirement](https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/)) We will not ship an unmaintained edge component.
- **AKS application routing add-on (managed NGINX):** **Fact:** Microsoft supports it only until November 2026, with critical security patches only. ([AKS blog, 2025-11-13](https://blog.aks.azure.com/2025/11/13/ingress-nginx-update)) That is around our defense date.
- **AKS application routing with Gateway API:** the official successor; it deploys an Istio control plane for Gateway API resources ([Microsoft Learn](https://learn.microsoft.com/en-us/azure/aks/app-routing-gateway-api)). One IP and modern API, but an extra managed component to enable and explain. Kept as a possible bonus.
- **Gateway API with Envoy Gateway / Traefik:** same idea, self-installed: CRDs plus a controller with Helm. More steps for the evaluator.
- **Application Gateway for Containers:** Azure-managed L7, but a separate paid resource and more setup.
- **NodePort:** exposes node IPs on high ports and breaks when nodes are replaced. Not production-like.

**Revisit if:** we want a single IP, a domain name or HTTPS.

---

## 5. Image tags: git commit SHA

**Choice:** CI tags each image with the short git SHA of the commit (`<registry>/poll:<sha>`). Kustomize writes that tag in the manifests.

**Pros**

- A new tag changes the Pod template, so Kubernetes starts a rolling update. Re-pushing the same tag does not.
- **Fact:** Kubernetes advises against `:latest` in production: it makes it hard to know which version runs and to roll back. ([Kubernetes docs: Images](https://kubernetes.io/docs/concepts/containers/images/))
- Every running pod points to an exact commit: easy to trace and to roll back (`kubectl rollout undo`).
- No manual version bump: CI derives the tag.

**Cons**

- A SHA says nothing about the size of the change, unlike semver.
- Tags are mutable in a registry, so a SHA tag could in theory be overwritten. A digest (`@sha256:...`) is fully immutable but unreadable.

**Alternatives not taken**

- **`latest`:** no rollout on re-push, no rollback, no traceability.
- **Semver (`v1.2.3`):** needs a manual release step; useful for a public product, not for our continuous deploys.
- **Digest only:** safest, but the manifests become hard to read. We may pin digests later as a hardening step.

---

## 6. Secrets: `secretGenerator` from a gitignored file

**Choice:** The evaluator copies `k8s/secrets.env.example` to `k8s/secrets.env` and fills in `POSTGRES_PASSWORD` (and optionally `REDIS_PASSWORD`). A `secretGenerator` in `k8s/kustomization.yaml` turns this file into the `app-secrets` Secret on `kubectl apply -k k8s/`. The real file is gitignored.

**Pros**

- **Fact:** The subject excludes `POSTGRES_PASSWORD` and the cloud credentials from the delivery, but asks us to document how and where to set them. The evaluator must be able to clone, set the credentials and deploy by themselves. ([subject PDF](subject/bernstein-project.pdf)) Here: one file to fill, then the same single deploy command.
- **Fact:** `secretGenerator` builds a Secret from an env file and appends a content hash to its name, like `configMapGenerator`. ([Kubernetes docs: Managing Secrets using Kustomize](https://kubernetes.io/docs/tasks/configmap-secret/managing-secret-using-kustomize/)) Changing a password therefore rolls the Deployments that use it, with no manual restart.
- If `secrets.env` is missing, `kubectl apply -k` fails before anything is created. Nothing can be deployed without its secrets.
- The Secret gets the `bernstein` namespace from the kustomization, so it always lands next to the pods that read it.
- No registry secret: AKS pulls from ACR through `--attach-acr` (section 2).

**Cons**

- **Fact:** A Secret is only base64-encoded, not encrypted, in its manifest; anyone allowed to read Secrets in the namespace can read the password. ([Kubernetes docs: Secrets](https://kubernetes.io/docs/concepts/configuration/secret/)) Access is limited through Azure RBAC on the cluster.
- The password lives in a plain file on the evaluator's machine. Acceptable: it never leaves their machine except to the cluster.
- Every `kubectl kustomize k8s/` needs a `secrets.env`, even for a dry render. A copy of the template is enough for that.

**Alternatives not taken**

- **`secret.example.yaml` applied with `kubectl apply -f`:** two commands that must run in the right order, no rollout on password change, and the manifest had no namespace, so the Secret landed in `default`, out of the pods' reach.
- **`kubectl create secret generic ... --from-literal`:** one-off and imperative; the password ends up in the shell history and the step is easy to forget.
- **Sealed Secrets:** lets an encrypted Secret be committed, but the key belongs to the controller of one cluster. An evaluator's fresh cluster could not decrypt ours, and they would need an extra tool.
- **Azure Key Vault + Secrets Store CSI driver:** the strongest option for production ([Microsoft Learn](https://learn.microsoft.com/en-us/azure/aks/csi-secrets-store-driver)), but it adds a Key Vault, an identity and an add-on for one password. Over-built for this project.

---

## 7. Database: PostgreSQL StatefulSet with a persistent disk

**Choice:** `k8s/postgres.yaml` runs `postgres:18-alpine` as a `StatefulSet` with 1 replica. Its data lives on a 1 GiB `PersistentVolumeClaim` (AKS default storage class, an Azure Disk) mounted at `/var/lib/postgresql`. A `ClusterIP` Service named `postgres` makes it reachable inside the cluster only. The container runs as the image's `postgres` user (uid 70).

**Pros**

- **Fact:** A StatefulSet gives each pod a stable identity and its own PVC from `volumeClaimTemplates`. The PVC is kept when the pod is deleted or rescheduled, and the new pod mounts the same volume. ([Kubernetes docs: StatefulSets](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/)) Votes survive a pod restart, a node drain or a `kubectl rollout restart`.
- **Fact:** By default, deleting or scaling down a StatefulSet does not delete its PVCs (`persistentVolumeClaimRetentionPolicy` defaults to `Retain`). ([same source](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/#persistentvolumeclaim-retention)) Deleting or re-applying the StatefulSet keeps the data. **Careful:** `kubectl delete -k k8s/` also deletes the `bernstein` namespace, hence the PVC, and the AKS `default` storage class has `reclaimPolicy: Delete`, so the disk goes with it.
- `ClusterIP` only: the database has no public IP. Only pods in the cluster reach it, through the `postgres` DNS name used in `POSTGRES_HOST`.
- Non-root (uid 70, `fsGroup: 70` so the disk is writable for that user), with `allowPrivilegeEscalation: false` and all Linux capabilities dropped: running as uid 70 from the start, the entrypoint never needs `chown` or `setuid`.
- Same image as `docker-compose.yml`: what CI tests locally is what runs on the cluster.
- **Schema:** `schema.sql` is mounted from the `postgres-init` ConfigMap into `/docker-entrypoint-initdb.d`. **Fact:** the image runs the `*.sql` files found there on its first start, when the data directory is empty. ([postgres image docs: Initialization scripts](https://hub.docker.com/_/postgres)) A fresh deploy gets the `votes` table with no manual step, exactly like `docker-compose.yml`. The script uses `CREATE TABLE IF NOT EXISTS`, so running it again cannot fail.

**Cons**

- **Single replica: Postgres is not highly available.** If its node is drained, the pod stops and starts again on the other node (the Azure Disk is detached and re-attached, which takes up to a minute or two). During that time the worker and Result cannot reach the database. Poll keeps accepting votes: they wait in Redis and the worker stores them once Postgres is back. Real replication (a primary plus standbys, e.g. with an operator like CloudNativePG) is a lot of machinery for a demo app.
- **Fact:** An Azure Disk is `ReadWriteOnce` and zonal: it can only be attached to one node at a time, in its zone. ([Microsoft Learn: Azure Disk CSI driver](https://learn.microsoft.com/en-us/azure/aks/azure-disk-csi)) Fine for one replica; our 2 nodes have no zones (zone `0`), so the pod can move to either node.
- 1 GiB is enough for the votes table. Azure bills managed disks by size tier, so the smallest tier is billed even if we ask for less.
- The init script only runs on an empty data directory. A database created before the script was mounted, or a later schema change, is not touched: apply it by hand with `kubectl -n bernstein exec -i postgres-0 -- psql -U postgres -d postgres < k8s/schema.sql`. Acceptable: the schema is one table that does not change, and the evaluator starts from a fresh cluster.
- Kustomize refuses files outside `k8s/` (even through a symlink), so `k8s/schema.sql` is a copy of `poll-application/schema.sql`. A CI step fails if the two differ.

**Alternatives not taken**

- **Deployment + a standalone PVC:** works for one replica, but a rolling update could start a second pod that tries to mount the same `ReadWriteOnce` disk and gets stuck. A StatefulSet stops the old pod before starting the new one.
- **Azure Database for PostgreSQL (managed):** backups and HA out of the box, but it costs credits all the time (it cannot be stopped as easily as the cluster), and the evaluator would need to create one too. The subject asks us to deploy the app on the cluster.
- **`emptyDir` or no volume:** every pod restart would wipe the votes.
- **Schema through a `Job`, a `postStart` hook or an `initContainer` in worker/result:** each would re-apply the schema on every deploy or start, which also covers existing databases. But each adds a moving part (a Job is immutable and must be renamed to run again; a failing `postStart` kills the container; an `initContainer` ties the apps to the schema) for a one-table schema that never changes.

---

## 8. Result: 2 fixed replicas, hardened container

**Choice:** `k8s/result.yaml` is a `Deployment` with 2 replicas and the rollout settings of our baseline (`maxSurge: 1`, `maxUnavailable: 0`, `minReadySeconds: 5`). Liveness probes `/healthz`, readiness probes `/readyz`. The container runs as uid 1000 with a read-only root filesystem and no Linux capabilities. Its image is written as the bare name `result`; the `images` field of `kustomization.yaml` sets the registry and the tag.

**Pros**

- **2 replicas:** the `Service` spreads users over both, and a rollout or a drained node always leaves one pod serving.
- **Fact:** with `maxUnavailable: 0`, the Deployment never goes below the desired number of available pods during a rollout; `maxSurge: 1` adds the new pod first. `minReadySeconds` makes a new pod count as available only after it stayed Ready that long. ([Kubernetes docs: Deployments](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#rolling-update-deployment))
- **Probes match the app:** `/healthz` only says the process is alive, so a database outage does not make Kubernetes restart Result in a loop. `/readyz` checks PostgreSQL with `SELECT 1`: a pod that lost the database stops getting traffic until it is back.
- **No HPA on Result, on purpose:** each pod runs one `SELECT ... GROUP BY` per second and broadcasts it to its WebSocket clients, so its load barely grows with viewers. WebSocket connections stay on the pod they opened on, so a pod added by an HPA would only get new visitors. Poll gets the HPA instead (#33).
- **Port 80 as non-root:** **Fact:** `net.ipv4.ip_unprivileged_port_start` is a "safe" sysctl, allowed by default since Kubernetes 1.22, and setting it to `0` lets any user bind ports below 1024 inside the pod's network namespace. ([Kubernetes docs: sysctls](https://kubernetes.io/docs/tasks/administer-cluster/sysctl-cluster/#safe-and-unsafe-sysctls)) Some container runtimes already do this, but declaring it makes the pod work the same on any cluster.
- **Hardening:** no privilege escalation, all capabilities dropped, read-only root filesystem. Result writes nothing to disk, so a compromised process cannot drop files in the container.
- **Image through `images`:** CI only rewrites `newTag` (the git SHA, section 5). An evaluator with their own registry only changes `newName`. No manifest edit.

**Cons**

- If PostgreSQL is down, both pods fail readiness and leave the Service: the Result page is unreachable instead of showing stale counts. Acceptable: without the database it has nothing to show, and Poll keeps working.
- Open WebSocket connections are cut when their pod stops during a rollout. The browser reconnects by itself (socket.io), and the client only uses the WebSocket transport, so no sticky sessions are needed.
- `envFrom: app-config` also injects `REDIS_HOST`, which Result does not use. Harmless, and simpler than listing each key.

**Alternatives not taken**

- **1 replica:** any rollout or node drain would cut the page.
- **HPA:** see above.
- **Readiness on `/healthz` too:** pods would keep getting traffic while they cannot answer with data.

---

## 9. Queue: Redis Deployment (in-memory, single replica)

**Choice:** `k8s/redis.yaml` runs `redis:8-alpine` as a `Deployment` with 1 replica and no PersistentVolumeClaim. A `ClusterIP` Service named `redis` on port `6379` exposes it inside the cluster only. The container runs as the image's `redis` user (uid 999, gid 1000) with all Linux capabilities dropped. Persistence is off (`--save '' --appendonly no`): Redis writes no RDB or AOF file. It starts with `--requirepass "$REDIS_PASSWORD"` when `REDIS_PASSWORD` is set in `app-secrets`, or without authentication when left empty. The Deployment uses the baseline rollout (`maxSurge: 1`, `maxUnavailable: 0`, `minReadySeconds: 5`).

**Pros**

- **Transient buffer, not source of truth:** Poll pushes votes with `RPUSH` and Worker immediately pops them with `BLPOP` to upsert them into PostgreSQL. PostgreSQL is the sole durable store (section 7); keeping Redis as a stateless `Deployment` avoids paying for and managing a second Azure Managed Disk.
- **Fast rescheduling on node drain:** Unlike a `StatefulSet` bound to a `ReadWriteOnce` Azure Disk (which takes up to a minute or two to detach and re-attach across nodes), a diskless `Deployment` pod starts on the surviving node in seconds.
- **`ClusterIP` only:** The queue has no public IP and is only reachable inside the cluster via the `redis` DNS name matching `REDIS_HOST=redis` in `app-config`.
- **Optional password with probes that work either way:** **Fact:** `redis-cli` reads the password from the `REDISCLI_AUTH` environment variable, which avoids passing it with `-a` on the command line. ([Redis docs: redis-cli](https://redis.io/docs/latest/develop/tools/cli/)) Both `readinessProbe` and `livenessProbe` run `REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli ping | grep -q PONG`, which works whether `REDIS_PASSWORD` is empty or set, and keeps the password out of the probe's arguments. The server itself still receives it as `--requirepass`, so it is visible in `ps` inside the pod; anyone with that access can read the pod's environment anyway.
- **In-memory only:** no snapshot or append-only file, so Redis never forks to save to disk (each fork would duplicate its memory under a 128Mi limit) and writes nothing to the container filesystem. A file inside the container would be lost on restart anyway.
- **Hardening:** Non-root (`runAsUser: 999`, `runAsNonRoot: true`), `allowPrivilegeEscalation: false`, and `capabilities.drop: ["ALL"]`.

**Cons**

- **Single replica and in-memory:** If the Redis pod crashes or is rescheduled at the exact moment a vote is sitting in the list (for instance while PostgreSQL or the Worker is down), queued votes not yet flushed to PostgreSQL are lost, and Poll returns `503` on `/readyz` during the few seconds the pod restarts. Acceptable for a voting demo where the Worker drains the queue in milliseconds under normal operation.
- **Single point of failure for Poll:** Poll's `/readyz` pings Redis, so while Redis is down every Poll pod is unready and the Poll page is unreachable (Result keeps working). A Redis pod restart takes about 4 s (measured on AKS). Rollouts avoid the gap: with `maxSurge: 1` / `maxUnavailable: 0`, the new Redis pod is Ready before the old one stops. A node drain still causes that short gap. During a rollout, both Redis pods briefly sit behind the Service: new Poll connections may push to the new pod while the worker still pops from the old one. Nothing is lost: when the old pod stops, the worker's connection fails, it exits, restarts and reconnects to the new pod, which still holds those votes.

**Alternatives not taken**

- **2+ replicas on a plain `Deployment`:** Each pod would run an independent Redis instance with its own memory. The `Service` would round-robin `RPUSH` and `BLPOP` across unrelated queues, stranding votes.
- **`StatefulSet` + PVC (`--appendonly yes`):** Protects in-flight votes across Redis restarts, but adds disk latency on every vote, a second Azure Disk to bill, and slow cross-node disk re-attachment on node drain.
- **Redis Sentinel / Redis Cluster (Bitnami Helm chart):** True high-availability failover, but adds at least 3 stateful pods and significant operational complexity for a lightweight buffer queue.

---

## 10. Worker: single-replica background consumer

**Choice:** `k8s/worker.yaml` runs `worker` as a `Deployment` with 1 replica and no Kubernetes `Service`. It uses the baseline rolling update strategy (`maxSurge: 1`, `maxUnavailable: 0`, `minReadySeconds: 5`), probes `GET /healthz` and `GET /readyz` on port 80, and runs as uid `10001` with `net.ipv4.ip_unprivileged_port_start=0`, a read-only root filesystem, and all capabilities dropped. Its image is resolved through the `images` field of `kustomization.yaml`.

**Pros**

- **1 replica is enough and saves node RAM:** The Worker runs on a Java 25 JVM (`eclipse-temurin:25-jre`), which has a larger memory footprint than Python or Node.js (`requests: 192Mi`, `limits: 384Mi`). Each vote is one `BLPOP` and one single-row upsert, so a single instance keeps up with far more votes than a demo produces (tested on AKS: a vote pushed to Redis is in PostgreSQL within a second).
- **Safe rollout overlap (`maxSurge: 1`, `maxUnavailable: 0`):** During a rolling update, the new Worker pod starts and must pass `/readyz` for `minReadySeconds: 5` before the old pod is terminated, so two workers briefly consume the queue in parallel. **Fact:** `BLPOP` is atomic and delivers each popped element to a single blocked client ([Redis docs: BLPOP](https://redis.io/docs/latest/commands/blpop/)), and the PostgreSQL `INSERT ... ON CONFLICT (id) DO UPDATE` statement is idempotent, so two concurrent workers never duplicate a vote.
- **No `Service` resource:** No user or cluster component connects to the Worker; it only opens outbound TCP connections to `redis:6379` and `postgres:5432`. Only the kubelet reaches port 80 on the pod IP to run `/healthz` and `/readyz` probes. Omitting the `Service` avoids exposing an unused cluster endpoint.
- **Probes match the dual dependency:** `/healthz` answers `200` as soon as the embedded HTTP server starts, so a temporary Redis or PostgreSQL outage does not trigger a restart loop while `connectToRedis` / `connectToDB` retry. `/readyz` pings Redis and runs `dbConn.isValid(2)` on PostgreSQL, so a new pod in a rollout only replaces the old pod once both backing stores are connected.
- **Hardening:** Explicit `runAsUser: 10001` (matching the `app` user in `worker/Dockerfile`), `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, and `capabilities.drop: ["ALL"]`.

**Cons**

- **Brief pause on unexpected pod crash or node drain:** With 1 replica, if the node hosting the Worker is drained or crashes, vote processing pauses for a few seconds until the replacement pod starts. Votes are not lost: Poll keeps pushing them to the Redis list, and the new Worker drains the backlog as soon as it connects.
- **No `SIGTERM` shutdown hook in `Worker.java`:** If `updateVote` fails with a `SQLException`, the worker pushes the vote back to Redis with `LPUSH`. However, if the JVM receives `SIGTERM` during the sub-millisecond window between `BLPOP` returning a vote and `executeUpdate()` committing it, the process exits before the upsert finishes and that single vote is lost (most of the time the worker is idle inside `BLPOP`, where nothing has been popped yet).
- **Order is not guaranteed during the rollout overlap:** while two workers run, a voter who changes their vote twice within a few milliseconds could see the older vote committed last, since each worker upserts independently. Only possible during the few seconds of a worker rollout, and the voter can simply vote again.

**Alternatives not taken**

- **2+ replicas permanently:** Works safely thanks to atomic `BLPOP` and idempotent SQL upserts, but doubles steady-state JVM memory consumption (~400 MiB) on our 2 student nodes for a queue that a single pod drains in milliseconds.
- **Adding a `ClusterIP` Service:** Unnecessary because nothing in the cluster calls the Worker over HTTP.

---

## 11. Poll: 2 replicas, Gunicorn `/tmp` volume and non-root

**Choice:** `k8s/poll.yaml` is a `Deployment` with 2 replicas and the baseline rollout settings (`maxSurge: 1`, `maxUnavailable: 0`, `minReadySeconds: 5`). Liveness probes `/healthz`, readiness probes `/readyz`. The container runs as uid `10001` with `net.ipv4.ip_unprivileged_port_start=0`, a read-only root filesystem, an `emptyDir` volume mounted at `/tmp`, and all Linux capabilities dropped. Its image is written as the bare name `poll`, resolved via `images` in `kustomization.yaml`.

**Pros**

- **2 replicas & zero-downtime rollout:** Spreads incoming HTTP `GET /` and `POST /` vote traffic across two pods and guarantees at least one pod keeps serving during rolling updates (`maxUnavailable: 0`, `maxSurge: 1`, `minReadySeconds: 5`) or single-node maintenance.
- **Stateless voter identity:** Voter identity (`voter_id`) is stored as an HTTP cookie in the browser, and each `POST /` pushes the vote directly to Redis (`RPUSH votes`). Any Poll replica can serve any request without sticky sessions.
- **Probes match the dependency:** `/healthz` only checks that Gunicorn/Flask answers HTTP requests, so a Redis restart does not trigger a container restart loop. `/readyz` pings Redis (`PING`): a pod that cannot reach Redis is removed from Service endpoints until Redis is back.
- **`readOnlyRootFilesystem: true` with an `emptyDir` `/tmp`:** **Fact:** Gunicorn creates a temporary heartbeat file (`wgunicorn-*`) for each worker in `/tmp` ([Gunicorn FAQ: Worker Heartbeat](https://docs.gunicorn.org/en/stable/faq.html#how-do-i-avoid-blocking-os-fchmod-calls)) and, since Gunicorn 25+, a control socket in `$HOME/.gunicorn/gunicorn.ctl` ([Gunicorn docs: Control Socket](https://docs.gunicorn.org/en/stable/settings.html#control-socket)). Mounting an `emptyDir` at `/tmp` and setting `HOME=/tmp` lets Gunicorn create both files while keeping `/app` and the rest of the root filesystem strictly read-only. The `emptyDir` uses `medium: Memory` (a tmpfs, capped at 16Mi): the same FAQ warns that heartbeat updates on a disk-backed `/tmp` can block workers, and a default `emptyDir` lives on the node's disk. Its content counts toward the container's memory limit; it only holds a few empty files and a socket.
- **Hardening & port 80 as non-root:** Runs as uid `10001` (matching `poll/Dockerfile`), `allowPrivilegeEscalation: false`, all capabilities dropped, and uses the safe pod sysctl `net.ipv4.ip_unprivileged_port_start=0` to bind port 80.

**Cons**

- If Redis is down, both Poll pods fail `/readyz` and leave the Service (see section 9 Cons).
- `envFrom: app-config` also injects `POSTGRES_*`, which Poll does not use. Harmless, and keeps configuration uniform across workloads.

**Alternatives not taken**

- **1 replica:** A rollout or node drain would drop user requests.
- **`readOnlyRootFilesystem: false`:** Easier for Gunicorn's `/tmp` files, but leaves the application filesystem writable if compromised.
- **Setting `OPTION_A..D` in `app-config`:** Defaults (`Ansible`, `Chef`, `Puppet`, `SaltStack`) are already defined in `app.py` and hardcoded in Result's `index.html`; overriding them only in Poll's environment would desynchronize Poll and Result labels.
