# ADR 0001: Kubernetes cluster on AKS

**Status:** Accepted · **Date:** 2026-10-19 · **Issues:** #8, #9

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

## Alternatives rejected

- **1 node:** half the VM cost, but any drain or VM reboot is a full outage: evicted pods have nowhere to go.
- **3+ nodes:** 50 %+ more credits, and it hits the 6-vCPU regional student quota (3 × 2 = 6) with no gain for 5 services.
- **GKE / EKS:** good managed offers, but no Epitech credits. EKS bills the control plane per hour. ([AWS: EKS pricing](https://aws.amazon.com/eks/pricing/))
- **DigitalOcean (GitHub Student Pack):** simple and cheap, but the credit is limited and every evaluator needs a second cloud account.
- **Self-managed (k3s, kubeadm on VMs, minikube):** we would operate the control plane ourselves, and a local cluster is not reachable from the outside world. The subject "highly recommends" Kubernetes-as-a-Service.

## Revisit if

The Azure credits run out before the defense.
