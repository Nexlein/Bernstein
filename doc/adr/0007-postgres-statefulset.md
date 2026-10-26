# ADR 0007: PostgreSQL as a StatefulSet on a persistent disk

**Status:** Accepted · **Date:** 2026-10-20 · **Issues:** #18, #19

## Decision

`k8s/postgres.yaml` runs `postgres:18-alpine` as a `StatefulSet` with 1 replica. Data lives on a 1 GiB `PersistentVolumeClaim` (AKS default storage class: an Azure Disk) mounted at `/var/lib/postgresql`. A `ClusterIP` Service `postgres` makes it reachable inside the cluster only. The container runs as the image's `postgres` user (uid 70). `schema.sql` comes from the `postgres-init` ConfigMap.

## Why

- **Fact:** a StatefulSet gives each pod a stable identity and its own PVC from `volumeClaimTemplates`. The PVC is kept when the pod is deleted or rescheduled, and the new pod mounts the same volume. ([Kubernetes docs: StatefulSets](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/)) Votes survive a pod restart, a node drain or a `kubectl rollout restart`.
- **Fact:** deleting or scaling down a StatefulSet does not delete its PVCs by default (`persistentVolumeClaimRetentionPolicy` is `Retain`). ([Kubernetes docs: PVC retention](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/#persistentvolumeclaim-retention)) **Careful:** `kubectl delete -k k8s/` also deletes the `bernstein` namespace, hence the PVC, and the AKS `default` storage class has `reclaimPolicy: Delete`: the disk goes with it.
- `ClusterIP` only: no public IP. Pods reach it through the `postgres` DNS name set in `POSTGRES_HOST`.
- Non-root (uid 70, `fsGroup: 70` so the disk is writable), `allowPrivilegeEscalation: false`, all capabilities dropped. Running as uid 70 from the start, the entrypoint never needs `chown` or `setuid`.
- Same image as `docker-compose.yml`: what CI tests is what runs on the cluster.
- **Schema:** `schema.sql` is mounted into `/docker-entrypoint-initdb.d`. **Fact:** the image runs the `*.sql` files there on its first start, when the data directory is empty. ([postgres image docs: Initialization scripts](https://hub.docker.com/_/postgres)) A fresh deploy gets the `votes` table with no manual step. The script uses `CREATE TABLE IF NOT EXISTS`, so a rerun cannot fail.

## Trade-offs

- **1 replica: PostgreSQL is not highly available.** On a node drain, the pod restarts on the other node while the Azure Disk detaches and re-attaches (up to a minute or two). Meanwhile the worker and Result cannot reach the database; Poll keeps accepting votes, which wait in Redis. Measured on AKS: Result failed 47 requests over 39 s ([ADR 0014](0014-pod-disruption-budgets.md)). Real replication (primary plus standbys, e.g. the CloudNativePG operator) is a lot of machinery for a demo app.
- **Fact:** an Azure Disk is `ReadWriteOnce` and zonal: attached to one node at a time, in its zone. ([Microsoft Learn: Azure Disk CSI driver](https://learn.microsoft.com/en-us/azure/aks/azure-disk-csi)) Fine for 1 replica; our 2 nodes have no zones (zone `0`), so the pod can move to either node.
- 1 GiB is enough for the votes table. Azure bills managed disks by size tier, so the smallest tier is billed anyway.
- The init script only runs on an empty data directory. An older database or a later schema change is not touched: apply it by hand with `kubectl -n bernstein exec -i postgres-0 -- psql -U postgres -d postgres < k8s/schema.sql`. Acceptable: one table that does not change, and the evaluator starts from a fresh cluster.
- Kustomize refuses files outside `k8s/` (even through a symlink), so `k8s/schema.sql` is a copy of `poll-application/schema.sql`. A CI step fails if they differ.

## Alternatives rejected

- **Deployment + standalone PVC:** works for 1 replica, but a rolling update could start a second pod that tries to mount the same `ReadWriteOnce` disk and gets stuck. A StatefulSet stops the old pod before starting the new one.
- **Azure Database for PostgreSQL (managed):** backups and HA out of the box, but it burns credits all the time (not as easy to stop as the cluster), and the evaluator would need one too. The subject asks to deploy the app on the cluster.
- **`emptyDir` or no volume:** every pod restart would wipe the votes.
- **Schema through a `Job`, a `postStart` hook or an `initContainer` in worker/result:** each re-applies the schema on every deploy or start, so it also covers existing databases. But each adds a moving part (a Job is immutable and must be renamed to run again; a failing `postStart` kills the container; an `initContainer` ties the apps to the schema) for a one-table schema that never changes.
