# ADR 0019: PostgreSQL backup: manual dump, no automation, no failover

**Status:** Accepted · **Date:** 2026-10-27 · **Issues:** #35

## Decision

No automated backup and no standby database. A backup is a manual `pg_dump` from the pod to the operator's machine, documented and tested in [`DEPLOY.md`](../../DEPLOY.md#8-back-up-and-restore-the-votes). PostgreSQL stays 1 replica on an Azure Disk ([ADR 0007](0007-postgres-statefulset.md)).

## Why

- The data is demo votes: losing them costs nothing, and the subject grades the deployment, not data retention.
- **Fact:** `pg_dump` exports a consistent copy of a database while it is in use; `--clean --if-exists` adds the commands to drop each object before recreating it. ([PostgreSQL docs: pg_dump](https://www.postgresql.org/docs/current/app-pgdump.html)) One SQL file restores into a fresh or an existing database.
- **Tested on AKS:** 6195 votes dumped (90 KB), restored into a scratch database: same row count and same checksum as the live table.
- What already survives without a backup: pod restarts, node drains, `az aks stop` / `start`, since the disk is kept ([ADR 0007](0007-postgres-statefulset.md)). What does not: `kubectl delete namespace bernstein`, `az group delete`, a lost disk.

## Trade-offs

- Nothing is saved unless someone runs the dump. A lost disk loses every vote since the last one.
- No failover: while PostgreSQL moves during a drain of its node, Result is down (39 s measured, [ADR 0014](0014-pod-disruption-budgets.md)).

## What we would do in production (not done)

- **Scheduled dumps:** a Kubernetes `CronJob` running `pg_dump` to Azure Blob Storage. Simple; the data since the last run is lost.
- **Disk snapshots:** `VolumeSnapshot` objects through the Azure Disk CSI driver. ([Microsoft Learn: Azure Disk CSI driver](https://learn.microsoft.com/en-us/azure/aks/azure-disk-csi))
- **Failover and point-in-time recovery:** an operator such as [CloudNativePG](https://cloudnative-pg.io/): a primary with standbys, continuous archiving of the write-ahead log to object storage, automatic failover.
- **Managed database:** Azure Database for PostgreSQL, with automatic backups and point-in-time restore. ([Microsoft Learn: Backup and restore](https://learn.microsoft.com/en-us/azure/postgresql/flexible-server/concepts-backup-restore)) Rejected in [ADR 0007](0007-postgres-statefulset.md) for cost and evaluator setup.

## Revisit if

The votes become data someone needs to keep.
