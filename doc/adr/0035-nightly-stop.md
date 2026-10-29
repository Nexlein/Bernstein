# ADR 0035: Stop the cluster every night from GitHub Actions

**Status:** Accepted · **Date:** 2026-10-29 · **Issues:** #110

## Decision

The workflow `.github/workflows/nightly-stop.yml` runs every day at 23:00, Paris time (`cron: '0 23 * * *'`, `timezone: Europe/Paris`), and on demand (`workflow_dispatch`). It logs in with the CI's OIDC identity ([ADR 0032](0032-ci-registry-oidc.md)), reads the cluster's power state, and does nothing if it is `Stopped`. Otherwise it runs `az aks stop --no-wait`, then `az aks wait` until the cluster is `Stopped` and `Succeeded`. For this, the CI app has a custom role, `Bernstein AKS Stopper`, assigned on `bernstein-aks` only, with 2 actions: `Microsoft.ContainerService/managedClusters/read` and `.../stop/action`.

## Why

- **A forgotten cluster costs the night:** running adds about 0.2 € an hour to the 0.47 € a day of a stopped cluster ([ADR 0001](0001-aks-cluster.md#cost)). Until now it only stopped when one of us ran `az aks stop`; the subject makes cost management part of the job.
- **Fact:** `az aks stop` keeps every object but standalone pods, and compute is not billed while the cluster is stopped. ([Microsoft Learn: Stop and start an AKS cluster](https://learn.microsoft.com/en-us/azure/aks/start-stop-cluster))
- **The smallest right that works:** the built-in "Azure Kubernetes Service Contributor Role" grants `Microsoft.ContainerService/managedClusters/*`, which includes deleting the cluster. The custom role can only read it and stop it, not start, change or delete it. Assigning it needed the subscription owner (Maeva).
- **`--no-wait`, then `az aks wait`:** following the stop operation itself reads an operation status under the subscription (`Microsoft.ContainerService/locations/operations/read`), outside the cluster the role is assigned on. `az aks wait` only reads the cluster.
- **Fact:** a schedule can set an IANA time zone, so 23:00 stays 23:00 in Paris across daylight saving time; scheduled workflows run on the latest commit of the default branch. ([GitHub Docs: events that trigger workflows](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule))
- **Nothing new to run or pay:** the same OIDC identity and secrets as the registry login; the `main` federated credential already covers `schedule` and `workflow_dispatch` runs.

## Trade-offs

- **It stops the cluster even if we work at 23:00:** `az aks start` brings it back in a few minutes. After a start, every pod may land on the first node ready ([DEPLOY.md, After `az aks start`](../../DEPLOY.md#after-az-aks-start)).
- **Fact:** the schedule can be delayed when GitHub Actions is loaded, and in a public repository, scheduled workflows are disabled after 60 days with no activity. (Same page.) A late run still stops the cluster, and the defense is a week away.
- **A workflow changed in a pull request could stop the cluster:** the PR credential belongs to the same app. Only the 2 of us can push branches here ([ADR 0032](0032-ci-registry-oidc.md)).
- **Our cluster only:** the names `bernstein-rg` and `bernstein-aks` are written in the workflow, and the job only runs in this repository. The evaluator's cluster is theirs to manage.
- **To disable after the defense (#42):** the cluster will be deleted; a nightly run would then fail on a missing cluster.

## Alternatives rejected

- **Azure Automation runbook or Logic App on a schedule:** runs in Azure even if GitHub is down, but one more Azure resource with its own identity and role, outside the repository and harder to show.
- **A cron job on one of our laptops:** only runs when that laptop is on.
- **The built-in AKS Contributor role:** works with no custom role, but could delete the cluster.
- **Also start the cluster every morning:** we do not work every day; a start nobody asked for costs about 0.2 € an hour.
