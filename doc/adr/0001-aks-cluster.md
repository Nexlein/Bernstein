# ADR 0001: Kubernetes cluster on AKS

**Status:** Accepted · **Date:** 2026-10-19 · **Issues:** #8, #9, #102

## Decision

AKS cluster `bernstein-aks`, Free tier, in `spaincentral`, with **2 `Standard_B2s_v2` nodes** (2 vCPUs and 8 GiB RAM each; 4 vCPUs and 16 GiB in total). Stopped when not in use.

## Why

- Epitech students get Azure credits, and the subject points to them. No personal card or extra budget.
- **Fact:** the Free tier has free cluster management; only the consumed resources (nodes, disks, IPs) are billed. It is meant for dev/test and clusters under 10 nodes. ([Microsoft Learn: AKS pricing tiers](https://learn.microsoft.com/en-us/azure/aks/free-standard-pricing-tiers))
- **2 nodes** is the minimum to survive a `kubectl drain` (a defense topic) or a VM failure without an outage. The 2 replicas of Poll and Result can sit on different VMs ([ADR 0013](0013-pod-anti-affinity.md)), and there is room for the extra `maxSurge: 1` pod during rollouts.
- **Fact:** `Standard_B2s_v2` has 2 vCPUs and 8 GiB on burstable B-series hardware: it earns CPU credits when idle and bursts during rollouts. ([Microsoft Learn: Bsv2-series sizes](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/general-purpose/bsv2-series)) 16 GiB fits `kube-system`, the JVM worker, PostgreSQL, Redis and the replicated Poll and Result pods, with requests and limits set.
- **Region:** on Azure for Students, `francecentral` only exposes `v7` VM families (`StandardDalsv7Family`) with a quota of 0 vCPUs. `spaincentral` grants 10 vCPUs for `Standard Bsv2`, and 6 regional vCPUs in total: our 2 × 2 = 4 fit.
- **Fact:** `az aks stop` / `az aks start` stop and restart the cluster. Compute is not billed while stopped, and all objects except standalone pods are kept. ([Microsoft Learn: Stop and start an AKS cluster](https://learn.microsoft.com/en-us/azure/aks/start-stop-cluster))
- Same cloud as the registry, so image pulls need no secret ([ADR 0002](0002-acr-registry.md)).

## Trade-offs

- **Fact:** the Free tier has no financially backed uptime SLA for the API server. ([Microsoft Learn: AKS pricing tiers](https://learn.microsoft.com/en-us/azure/aks/free-standard-pricing-tiers)) Fine for a school project: running workloads are not affected by API server hiccups.
- Ties the delivery to Azure. The subject accepts it: the evaluator uses a cluster "on the same platform".
- **Fact:** after a stop/start, the API server IP may change. ([Microsoft Learn: Stop and start an AKS cluster](https://learn.microsoft.com/en-us/azure/aks/start-stop-cluster)) Run `az aks get-credentials` again after a restart.
- **Fact:** B-series VMs run at a CPU baseline below 100 % and only go above it while they have CPU credits left. ([Microsoft Learn: Bsv2-series sizes](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/general-purpose/bsv2-series)) A long load test can drain the credits and throttle the nodes. We watch this during the rollout test (#30).

## Cost

**Estimate, 2026-10-28:** Azure list prices in EUR ([Azure Retail Prices API](https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices)) for what we run. Not yet the bill: our accounts read the costs of `bernstein-rg` only, and the VMs, disks, IPs and load balancer are billed in the cluster's node resource group (`MC_…`).

| Resource                                                                                  | List price         | Per day, running | Per day, stopped |
| ----------------------------------------------------------------------------------------- | ------------------ | ---------------- | ---------------- |
| 2 nodes `Standard_B2s_v2`, `spaincentral`                                                 | 0.0803 €/h each    | 3.85 €           | 0                |
| 2 node OS disks, Premium SSD P10 (128 GiB, the AKS default for 1 to 7 vCPUs)              | 19.08 €/month each | 1.25 €           | 0, most likely   |
| PostgreSQL disk: 1 GiB on `managed-csi` (Standard SSD), billed as the smallest tier, E1   | 0.26 €/month       | 0.01 €           | 0.01 €           |
| 3 Standard public IPs: Poll, Result, and the nodes' outbound IP                           | 0.0044 €/h each    | 0.32 €           | 0.32 €           |
| Standard Load Balancer: 3 rules (Poll, Result, outbound), the first 5 billed as one block | 0.022 €/h          | 0.53 €           | 0.53 €           |
| Container Registry Basic, `francecentral`                                                 | 0.1466 €/day       | 0.15 €           | 0.15 €           |
| **Total**                                                                                 |                    | **about 6.1 €**  | **about 1.0 €**  |

- **Sources:** the default OS disk tier and the `managed-csi` class: [Microsoft Learn: AKS storage concepts](https://learn.microsoft.com/en-us/azure/aks/concepts-storage). The 3 outbound and service IPs: `az aks show` and our 2 `LoadBalancer` Services ([ADR 0004](0004-public-access-loadbalancer.md)). Data transfer is left out: a few MB per test.
- **Stopped:** "most likely" because each `az aks start` gives new nodes (new names, empty image cache), so the OS disks seem to go with the old ones; Microsoft only writes that compute is not billed. The IPs, the load balancer rules, the PostgreSQL disk and the registry stay, so they keep billing: about 1.0 € a day, 2.3 € if the OS disks stay too.
- **Spent so far, estimated:** about **11 €** from 2026-10-19 to 2026-10-28. The cluster ran 10.9 hours in total, from the `start` and `stop` events of the activity log (2.3 € of nodes and OS disks); the IPs, load balancer and registry billed the whole 9 days (about 9 €). The 1.32 € estimated for the registry matches what Azure shows for `bernstein-rg`: **1.26 €**, the only cost our accounts can read.
- **Credit:** **Fact:** Azure for Students gives a $100 credit for 12 months; once it is used, the subscription's products are disabled. ([Azure for Students](https://azure.microsoft.com/en-us/free/students/)) At about 1 € a day stopped, plus about 0.21 € per hour running, reaching the defense (about 2026-11-04) adds about 9 €: 7 days, 10 hours of them running. About 20 € in total, if the credit served nothing else.
- Stopping the cluster when idle divides the daily cost by 6. What stays billed (IPs and load balancer, 0.85 € a day) now costs more than the hours of use: deleting the namespace would save 2 IPs and 2 rules, but loses the votes and the IPs.

## Alternatives rejected

- **1 node:** half the VM cost, but any drain or VM reboot is a full outage: evicted pods have nowhere to go.
- **3+ nodes:** 50 %+ more credits, and it hits the 6-vCPU regional student quota (3 × 2 = 6) with no gain for 5 services.
- **GKE / EKS:** good managed offers, but no Epitech credits. EKS bills the control plane per hour. ([AWS: EKS pricing](https://aws.amazon.com/eks/pricing/))
- **DigitalOcean (GitHub Student Pack):** simple and cheap, but the credit is limited and every evaluator needs a second cloud account.
- **Self-managed (k3s, kubeadm on VMs, minikube):** we would operate the control plane ourselves, and a local cluster is not reachable from the outside world. The subject "highly recommends" Kubernetes-as-a-Service.

## Revisit if

- The Azure credits run out before the defense. The subscription owner sees the balance in the Azure Education Hub.
- The real costs of the `MC_…` group (a `Cost Management Reader` role on the subscription, or the portal's Cost analysis) differ from the estimate above: replace it.
