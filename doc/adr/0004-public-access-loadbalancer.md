# ADR 0004: Public access with one LoadBalancer Service per app

**Status:** Accepted · **Date:** 2026-10-19 · **Issues:** #8, #24, #25, #26

## Decision

`poll` and `result` each get a `Service` of type `LoadBalancer`. Redis, PostgreSQL and the worker stay internal (`ClusterIP` or no Service). No Ingress controller. `externalTrafficPolicy` keeps its default, `Cluster`.

## Why

- **Fact:** the subject asks for both pages to be "accessible from the outside world" and lets us give the evaluator "the external IP addresses". ([subject PDF](../subject/bernstein-project.pdf)) Two IPs match this directly.
- **Fact:** AKS uses the Standard Azure Load Balancer by default. Each `LoadBalancer` Service gets its own public frontend IP, shown under `EXTERNAL-IP` in `kubectl get service`. ([Microsoft Learn: Standard Load Balancer in AKS](https://learn.microsoft.com/en-us/azure/aks/load-balancer-standard))
- Nothing to install: no Helm chart, no CRDs, no controller to patch. One less component that can fail during the zero-downtime test.
- **Fact:** Azure Load Balancer works at layer 4. ([Microsoft Learn: Standard Load Balancer in AKS](https://learn.microsoft.com/en-us/azure/aks/load-balancer-standard)) It forwards TCP as is, so the WebSocket of Result works with no extra config.

## Trade-offs

- Two public IPs instead of one. Each Standard public IP is billed per hour ([Azure: IP address pricing](https://azure.microsoft.com/pricing/details/ip-addresses/)); small next to the nodes.
- No host or path routing, no TLS termination. Not required by the subject.
- The two public IPs stayed the same across every `az aks stop` / `az aks start` of our cluster (observed several times; Microsoft's docs promise nothing about it). The evaluator can be given the IPs once. **Fact:** when the Service is deleted, its load balancer and its IP address are deleted with it, as we saw in #39 after deleting the namespace. ([Microsoft Learn: Use a static IP with a load balancer](https://learn.microsoft.com/en-us/azure/aks/static-ip)) A static IP would survive that.
- **`externalTrafficPolicy: Cluster`:** every node accepts the traffic and kube-proxy forwards it to a ready pod, possibly on the other node (one extra hop). The app sees a node IP, not the visitor's. **Fact:** `Local` keeps the client IP but only sends traffic to nodes that run a ready pod of the Service. ([Kubernetes docs: Preserving the client source IP](https://kubernetes.io/docs/tasks/access-application-cluster/create-external-load-balancer/#preserving-the-client-source-ip)) With `Local`, a node whose pods are being replaced keeps getting traffic until the Azure health probe notices: a rollout risk that buys nothing, since the apps do not use the client IP.
- Zero downtime still depends on us: during a rollout, a terminating pod can get traffic until its endpoint is removed everywhere. **Fact:** endpoint removal and `SIGTERM` happen in parallel. ([Kubernetes docs: Pod termination](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#pod-termination)) Handled by readiness probes, `maxUnavailable: 0` and a `preStop` sleep ([ADR 0012](0012-graceful-shutdown.md)).

## Alternatives rejected

- **ingress-nginx:** **Fact:** retired upstream; best-effort maintenance ended in March 2026, with no releases or security fixes after that. ([Kubernetes blog: Ingress NGINX retirement](https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/)) We do not ship an unmaintained edge component.
- **AKS application routing add-on (managed NGINX):** **Fact:** supported by Microsoft only until November 2026, with critical security patches only. ([AKS blog, 2025-11-13](https://blog.aks.azure.com/2025/11/13/ingress-nginx-update)) That is around our defense date.
- **AKS application routing with Gateway API:** the official successor; it deploys an Istio control plane for Gateway API resources. ([Microsoft Learn](https://learn.microsoft.com/en-us/azure/aks/app-routing-gateway-api)) One IP and a modern API, but an extra managed component to enable and explain. Possible bonus.
- **Gateway API with Envoy Gateway or Traefik:** same idea, self-installed (CRDs plus a controller via Helm). More steps for the evaluator.
- **Application Gateway for Containers:** Azure-managed layer 7, but a separate paid resource and more setup.
- **NodePort:** exposes node IPs on high ports and breaks when nodes are replaced.

## Revisit if

We want a single IP, a domain name or HTTPS.
