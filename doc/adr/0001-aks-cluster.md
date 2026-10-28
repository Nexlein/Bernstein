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

**Measured** in Azure Cost Management, on the subscription (read-only role `Cost Management Reader`): **5.66 €** from 2026-10-19, when the cluster was created, to 2026-10-28 08:00 UTC (the data lags a few hours).

| Meter                                                                        | Cost   | Usage            | Billed while stopped                    |
| ---------------------------------------------------------------------------- | ------ | ---------------- | --------------------------------------- |
| 3 Standard public IPs: Poll, Result, and the nodes' outbound IP              | 2.50 € | 568 IP-hours     | yes, 0.32 € a day                       |
| Container Registry Basic                                                     | 1.29 € | 8.8 days         | yes, 0.15 € a day                       |
| 2 nodes `Standard_B2s_v2`                                                    | 1.01 € | 12.6 VM-hours    | no                                      |
| 2 node OS disks, Premium SSD P10 (128 GiB, the AKS default for 1 to 7 vCPUs) | 0.78 € | about 30 hours   | no: deleted with the nodes on each stop |
| PostgreSQL disk: 1 GiB on `managed-csi` (Standard SSD), billed as tier E1    | 0.07 € | the whole period | yes, 0.01 € a day                       |
| Standard Load Balancer: rules and data processed                             | 0 €    | 209 h, 8 GB      | free (see below)                        |
| Data transfer, and an IP of a first cluster attempt in `francecentral`       | 0.01 € |                  |                                         |

- **Per day:** stopped, **0.47 €** (2026-10-22 to 2026-10-25, all four days the same: IPs 0.32, registry 0.15, PostgreSQL disk 0.01). Running adds the nodes and their OS disks, **about 0.2 € per hour**: 0.18 over the whole period, 0.24 on 2026-10-27. A full day running would cost about 5 €.
- **The load balancer is free here:** its rules ran 209 hours at 0 €, and the subscription overview counts them among the student offer's free services (750 hours a month). The PostgreSQL disk and the OS disks follow list prices: P10 19.08 € and E1 0.26 € a month, nodes 0.0803 € an hour ([Azure Retail Prices API](https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices); [Microsoft Learn: AKS storage concepts](https://learn.microsoft.com/en-us/azure/aks/concepts-storage) for the default disks).
- **Stopping works:** no node or OS disk cost on the stopped days. What stays is mostly the 3 public IPs, two thirds of the stopped cost. Deleting the namespace would free 2 of them (0.21 € a day) but loses the votes and the IPs: not worth it.
- **Credit:** **Fact:** Azure for Students gives a $100 credit for 12 months; once it is used, the subscription's products are disabled. ([Azure for Students](https://azure.microsoft.com/en-us/free/students/)) Our Education Hub shows **88 €**, valid until 2027-10-19. It still shows 88 € available and 0 € of October costs: it lags behind Cost Management. The portal forecasts 7.45 € for October.
- **Until the defense** (about 2026-11-04): 7 more days, stopped except about 10 hours, add about 6 €. About **12 € in total, 14 % of the credit.**

## Alternatives rejected

- **1 node:** half the VM cost, but any drain or VM reboot is a full outage: evicted pods have nowhere to go.
- **3+ nodes:** 50 %+ more credits, and it hits the 6-vCPU regional student quota (3 × 2 = 6) with no gain for 5 services.
- **GKE / EKS:** good managed offers, but no Epitech credits. EKS bills the control plane per hour. ([AWS: EKS pricing](https://aws.amazon.com/eks/pricing/))
- **DigitalOcean (GitHub Student Pack):** simple and cheap, but the credit is limited and every evaluator needs a second cloud account.
- **Self-managed (k3s, kubeadm on VMs, minikube):** we would operate the control plane ourselves, and a local cluster is not reachable from the outside world. The subject "highly recommends" Kubernetes-as-a-Service.

## Revisit if

- The Azure credits run out before the defense. The subscription owner sees the balance in the Azure Education Hub.
- A cost appears that the table does not explain: Cost Management, Cost analysis, on the subscription, grouped by meter.
