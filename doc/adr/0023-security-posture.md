# ADR 0023: Security posture and known limits

**Status:** Accepted · **Date:** 2026-10-27 · **Issues:** #40, #34, #76, #77, #109

## Decision

We harden what runs in the cluster, and keep the cluster-level defaults of a student AKS cluster. Each limit below was checked on `bernstein-aks` on 2026-10-27, with what production would do instead.

## What we do

- **Only Poll and Result are public, on port 80.** Checked inside the cluster: 2 `LoadBalancer` Services (poll and result, port 80), no `NodePort`, everything else `ClusterIP`. Checked from the internet: both public IPs answer on 80; 22, 443, 5432 (PostgreSQL) and 6379 (Redis) are closed. Redis and PostgreSQL only have a `ClusterIP` Service ([ADR 0007](0007-postgres-statefulset.md), [ADR 0009](0009-redis-queue.md)), and the worker has none ([ADR 0010](0010-worker-deployment.md)).
- **Containers:** all 5 run as non-root, with no privilege escalation, every Linux capability dropped, the runtime's default seccomp profile, no service account token and a read-only root filesystem ([ADR 0008](0008-result-deployment.md), [ADR 0010](0010-worker-deployment.md), [ADR 0011](0011-poll-deployment.md), [ADR 0027](0027-pod-security-standards.md)). The namespace enforces the `restricted` Pod Security Standard, so the API server refuses a pod that does not ([ADR 0027](0027-pod-security-standards.md)).
- **Secrets:** no password in git; the Secret is built from a gitignored file ([ADR 0006](0006-secrets-secretgenerator.md)). The registry is private and the cluster pulls through its managed identity, with no pull secret ([ADR 0002](0002-acr-registry.md)).
- **Database users (#109):** Result connects as `result_reader`, which may only `SELECT` the votes; the worker as `worker_writer`, which may `SELECT`, `INSERT` and `UPDATE` them. **Fact:** `INSERT ... ON CONFLICT` needs `SELECT` on the columns it reads, so the worker's upsert needs it too. ([PostgreSQL docs: INSERT](https://www.postgresql.org/docs/18/sql-insert.html)) Neither app knows the password of the `postgres` superuser, which stays for the database itself and the backups. `k8s/users.sh` creates both users when the database is first created, and `scripts/deploy.sh` runs it again on every deploy: an existing database gets them, and a password changed in `secrets.env` is applied. Checked on AKS: from a Result pod, `INSERT` and `DELETE` answer `permission denied for table votes` and `DROP TABLE` `must be owner of table votes`; `worker_writer` cannot delete, truncate, drop or create a table; votes still go from Poll to Result.
- **Network:** default deny in the namespace, in and out; only the app's flows are allowed, enforced by Cilium ([ADR 0025](0025-network-policies.md)). Checked: a Poll pod reaches Redis, but not PostgreSQL or the internet.
- **Resources:** every container has CPU and memory limits, so one runaway container cannot starve a node ([ADR 0018](0018-resource-requests-and-limits.md)).

## Known limits

| Limit                                                                                             | Checked with                                                          | Production would                                      |
| ------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------- | ----------------------------------------------------- |
| The Kubernetes API server is public, with no authorized IP ranges (authentication still required) | `az aks show --query apiServerAccessProfile`: `null`                  | authorized IP ranges, or a private cluster            |
| Local accounts enabled, no Microsoft Entra ID integration (Kubernetes RBAC only)                  | `disableLocalAccounts: false`, `aadProfile: null`, `enableRbac: true` | Entra ID with Azure RBAC, local accounts disabled     |
| Secrets are only base64 in the API; no KMS encryption layer                                       | `securityProfile.azureKeyVaultKms: null`                              | KMS encryption with keys in Azure Key Vault           |
| No vulnerability scan of the images                                                               | no scan step in CI                                                    | a scan in CI that fails on critical issues (#77)      |
| No automatic Kubernetes upgrade (node OS images are updated automatically)                        | `upgradeChannel: null`, `nodeOsUpgradeChannel: NodeImage`             | the `patch` upgrade channel with a maintenance window |
| HTTP only                                                                                         | [ADR 0022](0022-no-https.md)                                          | HTTPS                                                 |

The facts behind the table:

- **Fact:** AKS gives the API server a public IP address by default; authorized IP ranges limit which addresses may reach it. ([Microsoft Learn: API server authorized IP ranges](https://learn.microsoft.com/en-us/azure/aks/api-server-authorized-ip-ranges)) Everyone else still needs valid credentials.
- **Fact:** local accounts are enabled by default, and even with Entra ID integration the `--admin` access "still exists as a non-auditable backdoor option". ([Microsoft Learn: Manage local accounts](https://learn.microsoft.com/en-us/azure/aks/local-accounts))
- **Fact:** Azure Storage always encrypts etcd data at rest (256-bit AES). KMS is an optional extra layer that encrypts Secrets before they are written to etcd, with keys in Key Vault. ([Microsoft Learn: Data encryption at rest concepts for AKS](https://learn.microsoft.com/en-us/azure/aks/kms-data-encryption-concepts)) Through the API, anyone allowed to read Secrets in the namespace reads them in clear ([ADR 0006](0006-secrets-secretgenerator.md)).

## Trade-offs

- Cluster-level hardening needs the Owner role and changes how everyone connects: an IP allowlist breaks when a home IP changes or for an evaluator at an unknown address; Entra ID needs an admin group and accounts for each person.
- **3 database passwords instead of 1**, all required in `secrets.env` (`scripts/deploy.sh` checks them). Everyone who deploys to the same cluster must use the same values: a different one is applied on the next deploy, and the other teammates' apps would be refused.
- **Moving an existing database to these users restarted PostgreSQL once** (its Secret gained 2 keys): Result was down 36 s while Poll had 0 errors, measured under `tests/zero-downtime.sh`. A one-time step; a new cluster gets the users at first start.
- The local Docker Compose stack still connects as `postgres`: it is for development only.
- The NetworkPolicies filter by pod labels, inside the cluster only: the public port 80 of Poll and Result stays open to everyone ([ADR 0004](0004-public-access-loadbalancer.md)).

## Alternatives rejected (for now)

- **Keep the `postgres` superuser for the apps, as a known limit:** one password less, but a compromised Result could drop the table or read any database.
- **One database per app:** the two apps share the same `votes` table, so they need the same database.
- **A Kubernetes Job to create the users:** one more object to wait for and clean up. The image's init directory covers a new database, and one `kubectl exec` from the deploy script covers the rest.
- **Private cluster:** no public API at all, but `kubectl` would need a VPN or a jump box, and the evaluator could not reach it.
- **Authorized IP ranges now:** cheap to enable, but our IPs change and the evaluator's is unknown: easy to lock someone out on the defense day.
- **Entra ID + Azure RBAC, local accounts disabled:** the right setup for a team. It needs Entra groups and an account for the evaluator.

## Revisit if

The cluster holds real data, or more people than the two of us administer it.
