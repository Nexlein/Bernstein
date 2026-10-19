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
