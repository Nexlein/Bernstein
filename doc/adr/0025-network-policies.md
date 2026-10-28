# ADR 0025: NetworkPolicies, enforced by Cilium

**Status:** Accepted · **Date:** 2026-10-27 · **Issues:** #34

## Decision

`k8s/network-policies.yaml` denies all traffic of the `bernstein` namespace, in and out, then allows only the app's flows: DNS for every pod, internet → poll:80 and result:80, poll → redis:6379, worker → redis:6379 and postgres:5432, result → postgres:5432. `bernstein-aks` enforces them with Cilium (`--network-dataplane cilium --network-policy cilium`).

## Why

- **Least privilege inside the cluster:** before, any pod could reach Redis and PostgreSQL ([ADR 0023](0023-security-posture.md)). A compromised Poll pod could open the database; now it only reaches Redis.
- **The policies need an engine.** **Fact:** by default all pods in an AKS cluster can send and receive traffic without limits; a network policy engine enforces the rules. ([Microsoft Learn: Secure pod traffic with network policies](https://learn.microsoft.com/en-us/azure/aks/use-network-policies)) Our cluster had `networkPolicy: none`: the objects would have been accepted and ignored.
- **Cilium rather than Azure NPM or Calico:**
  - **Fact:** Microsoft recommends Cilium, for its eBPF dataplane and its performance compared to iptables-based engines; Azure NPM is no longer supported on Linux nodes from September 30, 2028. ([same page](https://learn.microsoft.com/en-us/azure/aks/use-network-policies))
  - **Fact:** clusters with the Cilium dataplane do not use `kube-proxy`; Kubernetes NetworkPolicies work without Advanced Container Networking Services, the add-on for flow logs, FQDN and L7 policies. ([Microsoft Learn: Azure CNI Powered by Cilium](https://learn.microsoft.com/en-us/azure/aks/azure-cni-powered-by-cilium))
- **Egress is denied too**, not only ingress: a compromised pod cannot call the internet or other namespaces. DNS is allowed for every pod (UDP and TCP 53 to `kube-dns` in `kube-system`), otherwise no pod resolves `redis` or `postgres`.
- **Ingress on port 80 has no `from`:** the public traffic reaches Poll and Result through the Azure Load Balancer and any node ([ADR 0004](0004-public-access-loadbalancer.md)), so its source is not a fixed range. No `ipBlock` at all: **Fact:** with Cilium, an `ipBlock` cannot select node or pod IPs ([same page](https://learn.microsoft.com/en-us/azure/aks/azure-cni-powered-by-cilium)).
- **The worker has no ingress rule:** it serves only its probes, which the kubelet sends from the node. Observed: the worker stays Ready, with no restart, under the policies.
- **Tested on AKS** (2026-10-27):
  - From a Poll pod: DNS resolves `redis`, `redis:6379` opens, `postgres:5432` and `1.1.1.1:443` time out. Before the policies, all three opened.
  - From a Result pod: `postgres:5432` opens, `redis:6379` times out.
  - From a pod without labels in `bernstein`: DNS works; Redis, PostgreSQL and Poll are blocked. From a pod in another namespace: Redis and PostgreSQL blocked, `poll:80` open (the public port).
  - A vote sent to the public IP reached PostgreSQL; the Result page loads; `kubectl exec` and `port-forward` still work: they go through the API server and the kubelet, not the pod network.
  - Under `tests/zero-downtime.sh`: applying the policies with `scripts/deploy.sh`, 0 errors in 572 requests; `rollout restart` of Poll and Result, 0 in 1014; drain of the node running Redis (not PostgreSQL), 0 in 1481.

## Trade-offs

- **The switch to Cilium cut the app, once.** **Fact:** the update reimages the node pools, and Cilium enforces the policies only after all nodes are reimaged. ([Microsoft Learn: Update Azure CNI IPAM mode and data plane](https://learn.microsoft.com/en-us/azure/aks/update-azure-cni)) Measured under `tests/zero-downtime.sh`: about 12 minutes, through a temporary third node, so 3 drains. Poll failed 225 requests (2.2 %), Result 464 (4.8 %), in three windows:
  - 4 s on both apps, one minute after the start, before any node changed: cause unknown;
  - 39 s on Result, while PostgreSQL moved to another node;
  - 38 s on both, while Redis and PostgreSQL left the temporary node, slowed by image pulls on the fresh nodes (17.7 s for Redis).

  The single replicas of Redis and PostgreSQL cause this, as in any node upgrade ([ADR 0007](0007-postgres-statefulset.md), [ADR 0009](0009-redis-queue.md)). Microsoft documents no way back to the previous dataplane.

- **The evaluator's cluster needs an engine too.** Without one, the policies are ignored and the app still works. `DEPLOY.md` lists the check in its prerequisites.
- **A new app or dependency is blocked by default:** it needs its own allow rule, or its connections time out.
- **Cilium runs without requests or limits.** **Fact:** AKS does not configure CPU or memory limits on the Cilium daemonset. ([same page](https://learn.microsoft.com/en-us/azure/aks/azure-cni-powered-by-cilium)) Measured: 13-15m CPU and 121-131Mi per node for the agent, 1-3m and 27-43Mi for each of the 2 operator pods. The scheduler does not count them. `kube-proxy` is gone, so the CPU requests of both nodes went from 1712m to 1662m ([ADR 0018](0018-resource-requests-and-limits.md)).
- `kubectl exec` (backups, `redis-cli`) and `port-forward` are not filtered: they do not use the pod network.

## Alternatives rejected

- **Azure Network Policy Manager (`--network-policy azure`):** iptables, end of support on Linux in 2028, and Microsoft points to Cilium.
- **Calico (`--network-policy calico`):** works, but AKS supports only the standard `networking.k8s.io` policies with it, and Microsoft recommends Cilium.
- **Ingress-only policies:** simpler, but a compromised pod could still call out anywhere.
- **`CiliumNetworkPolicy`:** finer rules (L7, FQDN), but tied to Cilium, and L7 and FQDN need Advanced Container Networking Services. Standard NetworkPolicies work with any engine.

## Revisit if

The app calls an external service, or we add an Ingress controller, a monitoring agent or any pod that must talk to ours.
