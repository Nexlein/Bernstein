# Cluster Sizing & Architecture Decisions

This document justifies the technical and cost-management choices made for the Bernstein managed Kubernetes cluster (`bernstein-aks`), addressing the requirements in [`SUBJECT.md`](../subject/SUBJECT.md) and [`TODO.md`](../../TODO.md).

---

## Summary of Provisioned Cluster

| Parameter           | Value                             | Specification                                       |
| ------------------- | --------------------------------- | --------------------------------------------------- |
| **Cloud Provider**  | Microsoft Azure (AKS)             | Managed Kubernetes (`v1.36.4`), free control plane  |
| **Region**          | `spaincentral`                    | EU region with active `Standard Bsv2` student quota |
| **Node Count**      | `2` nodes                         | `aks-nodepool1` Virtual Machine Scale Set (VMSS)    |
| **Node Size (SKU)** | `Standard_B2s_v2`                 | 2 vCPUs, 8 GiB RAM per node (4 vCPUs, 16 GiB total) |
| **Registry Auth**   | Managed Identity (`--attach-acr`) | Keyless `AcrPull` role bound to `bernsteinacrmaeva` |

---

## 1. Managed Kubernetes Platform & Region (`AKS` in `spaincentral`)

- **Why Azure AKS**: Covered by Epitech's **Azure for Students** credits ($100 free tier). AKS provides a free managed control plane (`kube-apiserver`, `etcd`, `kube-scheduler`, `kube-controller-manager`), meaning credits are only consumed by the worker VMs, their OS disks, and the public load balancer IP.
- **Why `spaincentral` (while the Resource Group & ACR are in `francecentral`)**: On Azure for Students subscriptions, `francecentral` currently restricts VM creation to `v7` SKUs (`StandardDalsv7Family`), which have a `0` vCPU quota by default. `spaincentral` provides a **10 vCPU quota** for the `Standard Bsv2` family and a **6 vCPU total regional quota** while keeping low latency within Western Europe.

---

## 2. Why 2 Nodes? (`--node-count 2`)

Choosing **2 worker nodes** is the deliberate sweet spot between **high availability** (graded during the defense) and **cost control**:

1. **Surviving Node Maintenance & Failure (`kubectl drain`)**:
   - A key defense evaluation scenario is draining a node (`kubectl drain <node> --ignore-daemonsets --delete-emptydir-data`).
   - With a **single node**, draining or rebooting the VM evicts all pods with nowhere to reschedule them, causing a **100% service outage**.
   - With **2 nodes**, Kubernetes reschedules evicted workloads onto the remaining healthy node, and multi-replica services (`poll` and `result`) continue serving traffic with **zero downtime**.

2. **True High Availability via Pod Anti-Affinity**:
   - Both `poll` and `result` run with `replicas: 2` and `podAntiAffinity` (`preferredDuringSchedulingIgnoredDuringExecution`).
   - Having 2 nodes guarantees that each replica runs on a separate physical VM (`vmss000000` and `vmss000001`), eliminating any single point of failure at the compute layer.

3. **Headroom for Zero-Downtime Rolling Updates**:
   - Our deployments enforce `maxUnavailable: 0` and `maxSurge: 1`. During a rollout, Kubernetes spins up a 3rd pod before terminating an old one, requiring temporary extra CPU and memory scheduling capacity across the cluster.

4. **Cost & Quota Efficiency**:
   - `2` is the strict minimum node count required for multi-node resilience. A 3-node cluster would increase VM credit burn by **+50%** and meet the `6 vCPU` regional student quota ceiling (`3 × 2 = 6` vCPUs), leaving zero margin.

---

## 3. Why `Standard_B2s_v2`? (2 vCPU, 8 GiB RAM per node)

1. **Workload Footprint Breakdown**:
   - **System Overhead (`kube-system` + `ingress-nginx`)**: Azure CNI, CoreDNS, metrics-server, kube-proxy, CSI drivers, and the NGINX Ingress controller reserve roughly `~400m` CPU and `~1.2 GiB` RAM per node.
   - **Application Stack**:
     - `worker` runs on the JVM (`eclipse-temurin:25-jre`), which requires higher baseline memory (`256Mi–512Mi`).
     - `postgres:18-alpine` and `redis:8-alpine` require stable memory allocations to avoid OOMKills under load.
     - `poll` (2 replicas, Python/Gunicorn) and `result` (2 replicas, Node.js) plus `maxSurge` pods during rolling updates.
   - With **8 GiB RAM and 2 vCPUs per node** (**16 GiB RAM and 4 vCPUs cluster-wide**), all system daemons, backing databases, and replicated microservices fit comfortably with `resources.requests` and `resources.limits` enforced, preventing `Insufficient cpu` or `Insufficient memory` scheduling failures.

2. **Burstable B-Series Cost Optimization**:
   - `Standard_B2s_v2` belongs to Azure's burstable B-series: it accrues CPU credits while idle (which is 95% of the time for a student/demo cluster) and bursts up to 100% vCPU during image rollouts or load tests, making it one of the most cost-effective VM sizes available on Azure.

---

## 4. Credit Conservation: Stopping & Deleting the Cluster

Because compute VMs are billed per minute while running, **the cluster must be stopped whenever we are not actively deploying or testing**.

### Pause the cluster between work sessions (Recommended)

Stopping an AKS cluster deallocates both `Standard_B2s_v2` worker VMs (reducing compute cost to **$0**) while preserving the control plane state, ACR integration, and configuration:

```bash
# Stop the cluster (saves compute credits)
az aks stop --resource-group bernstein-rg --name bernstein-aks

# Verify the cluster is Stopped
az aks show --resource-group bernstein-rg --name bernstein-aks --query powerState.code -o tsv

# Start the cluster again when resuming work (~2-3 min)
az aks start --resource-group bernstein-rg --name bernstein-aks
```

### Delete the cluster (or full resource group) at the end of the project

To completely eliminate all charges (including managed disks, public IPs, and the ACR registry) once the defense is over:

```bash
# Option A: Delete only the AKS cluster (keeps the ACR registry and its images)
az aks delete --resource-group bernstein-rg --name bernstein-aks --yes --no-wait

# Option B: Delete the entire resource group (AKS + ACR + Disks + Public IPs)
az group delete --name bernstein-rg --yes --no-wait
```
