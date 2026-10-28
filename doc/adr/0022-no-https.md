# ADR 0022: No HTTPS

**Status:** Accepted · **Date:** 2026-10-27 · **Issues:** #40

## Decision

Poll and Result are served over plain HTTP on port 80 of their public IPs. No TLS, no domain name.

## Why

- **Not asked:** the subject requires both apps to be reachable from the outside world and lets us hand over the external IP addresses ([subject](../subject/SUBJECT.md)).
- **HTTPS needs a name:** a public certificate is issued for a domain name, not for a bare IP. **Fact:** on AKS, the annotation `service.beta.kubernetes.io/azure-dns-label-name` gives a `LoadBalancer` Service a name under `<location>.cloudapp.azure.com`. ([Microsoft Learn: Use a static IP with a load balancer](https://learn.microsoft.com/en-us/azure/aks/static-ip))
- **And a component to terminate TLS:** our Azure Load Balancer works at layer 4 and forwards TCP as is ([ADR 0004](0004-public-access-loadbalancer.md)). TLS would need an Ingress controller or a Gateway, plus [cert-manager](https://cert-manager.io/docs/) to get and renew [Let's Encrypt](https://letsencrypt.org/how-it-works/) certificates: the components ADR 0004 chose not to run.
- The page carries no credential. A vote is a letter, and the voter identity is a random cookie.

## Trade-offs

- **Traffic in clear:** the votes and the `voter_id` cookie travel unencrypted. Someone on the network path can read them, or change a vote.
- Browsers mark the pages as "Not secure".
- The WebSocket of Result is plain `ws://`.

## Alternatives rejected

- **DNS label + an Ingress or a Gateway + cert-manager with Let's Encrypt:** the standard way, free certificates renewed automatically; three more pieces to install and explain, for an unrequested feature.
- **AKS application routing add-on with certificates from Azure Key Vault:** managed, but adds a Key Vault and the add-on ([ADR 0004](0004-public-access-loadbalancer.md) on its support timeline).
- **Self-signed certificate in the apps:** every browser would warn, and the provided apps would need changes.

## Revisit if

Real users vote, or the page ever shows or collects anything personal.
