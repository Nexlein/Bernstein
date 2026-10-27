# ADR 0027: Pod Security Standards, `restricted` enforced on the namespace

**Status:** Accepted · **Date:** 2026-10-27 · **Issues:** #76

## Decision

The `bernstein` namespace has the labels `pod-security.kubernetes.io/enforce`, `warn` and `audit` set to `restricted` (no version pinned, so `latest`). Every pod sets `seccompProfile: RuntimeDefault` and `automountServiceAccountToken: false`. Redis and PostgreSQL also get a read-only root filesystem, like the 3 apps.

## Why

- **The cluster refuses a bad pod by itself**, instead of relying on review. Our pods were already non-root, without privilege escalation and with every capability dropped ([ADR 0023](0023-security-posture.md)); nothing stopped a future manifest, or a `kubectl run`, from doing otherwise.
- **What `restricted` enforces.** **Fact:** everything from `baseline` (no privileged or host access, only a list of safe sysctls, which includes `net.ipv4.ip_unprivileged_port_start`), plus: only `configMap`, `csi`, `downwardAPI`, `emptyDir`, `ephemeral`, `persistentVolumeClaim`, `projected` and `secret` volumes; `allowPrivilegeEscalation: false`; `runAsNonRoot: true` and a non-zero `runAsUser`; a `RuntimeDefault` or `Localhost` seccomp profile; all capabilities dropped, only `NET_BIND_SERVICE` added back. ([Kubernetes docs: Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)) The only rule we missed was seccomp. `fsGroup`, `readOnlyRootFilesystem` and the service account token are not part of the standard.
- **`warn` and `audit` too.** **Fact:** `enforce` rejects the pods; `warn` and `audit` only warn the user and annotate the audit log. Both apply to workload objects such as Deployments, while `enforce` applies only to the resulting pods. ([Kubernetes docs: Pod Security Admission](https://kubernetes.io/docs/concepts/security/pod-security-admission/)) So `kubectl apply` of a bad Deployment prints the reason at once, instead of the pods silently failing to start.
- **No service account token:** none of our apps calls the Kubernetes API, so a compromised container gets no credential to try.
- **Read-only root filesystem for Redis and PostgreSQL:** ADR 0023 left it to this ticket. Redis writes nothing (`--save ''`, `--appendonly no`). PostgreSQL writes its data on the PVC, its socket and lock file in `/var/run/postgresql` and temporary files in `/tmp`: two `emptyDir` volumes cover them.
- **Tested on AKS** (2026-10-27):
  - Before: `kubectl label ns bernstein pod-security.kubernetes.io/enforce=restricted --dry-run=server` warned that all 7 pods violated `restricted`, on `seccompProfile` only.
  - After the deploy: the same dry-run gives no warning. In each of the 5 containers: `Seccomp: 2` (filter active) in `/proc/1/status`, no `/var/run/secrets/kubernetes.io/serviceaccount`, `touch /probe-rofs` fails with `Read-only file system`, non-zero uid. The pods with the sysctl (Poll, Result, worker) and with `fsGroup` (Redis, PostgreSQL) all started.
  - A pod with `runAsUser: 0` is refused: `pods "root-test" is forbidden: violates PodSecurity "restricted:latest": ... runAsUser=0 (pod must not set runAsUser=0) ...`. A plain `kubectl run` is refused too. A non-compliant Deployment, with `--dry-run=server`, is accepted with `Warning: would violate PodSecurity "restricted:latest"`.
  - A vote went from Poll to PostgreSQL; `rollout restart` of Poll and Result: 0 errors.

## Trade-offs

- A pod template that breaks a rule fails at the **ReplicaSet**, not at `kubectl apply`: the Deployment is accepted, its pods are refused (`kubectl -n bernstein get events` shows why). The `warn` label prints the reason at apply time.
- **Debugging inside the namespace follows the rules too.** `kubectl debug` with its default profile is refused (it adds `SYS_PTRACE`); `kubectl debug <pod> --image=busybox:1.37 --profile=restricted` works. A throwaway test pod goes in another namespace.
- **Applying this change restarted PostgreSQL** (its pod template changed): Result failed for 30 to 40 s, as for any PostgreSQL change ([ADR 0007](0007-postgres-statefulset.md)). Poll: 0 errors.
- **No version pinned:** a Kubernetes upgrade that tightens `restricted` applies at once. Our pods follow the current rules with no exception, so the risk is low; pinning `enforce-version` would delay new rules until we change the label.
- PSS does not cover everything: resource limits, network flows, image origin or a read-only filesystem are other controls ([ADR 0018](0018-resource-requests-and-limits.md), [ADR 0025](0025-network-policies.md), #77).

## Alternatives rejected

- **`baseline`:** blocks host access and privileged pods only; it would still accept a pod running as root.
- **A policy engine (Kyverno, Gatekeeper, Azure Policy for AKS):** custom rules (registry allowlist, mandatory limits), but more pods, more to learn, and Azure Policy needs an add-on. Pod Security Admission is built into the API server.
- **`automountServiceAccountToken: false` on the `default` ServiceAccount** instead of each pod: one line, but outside our manifests (the ServiceAccount is created by Kubernetes) and invisible when reading a Deployment.

## Revisit if

A pod needs the Kubernetes API (give it its own ServiceAccount), or a component cannot meet `restricted` (give it its own namespace, not an exception here).
