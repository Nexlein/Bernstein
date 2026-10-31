# Bernstein — Subject (v2, condensed)

Source: [`bernstein-project.pdf`](bernstein-project.pdf). This file only restates what the PDF says, except the [grading rubric](#grading-rubric-mid-term-report), taken from the mid-term defense report. App details (ports, probes, env vars, versions) are in [`poll-application/README.md`](../../poll-application/README.md), not in the PDF.

## The app

Poll (Flask) pushes votes to a Redis queue. Worker (Java) consumes the queue and stores votes in PostgreSQL. Result (Node.js) reads PostgreSQL and displays results. Source code and Dockerfiles are supplied.

## Goal

A complete deployment process, from source code to a Kubernetes cluster. In order:

1. Build the application images.
2. Push them to a **private** Docker registry.
3. Deploy to a Kubernetes cluster.

After deployment, **Poll and Result must both be reachable from the outside world.** How you implement it, including extra tools, is up to you.

## Delivery

All scripts and files needed to deploy, **except** the cloud credentials/API keys and the `POSTGRES_PASSWORD` secret. You must still document how and where to set them.

An evaluator with a ready Kubernetes cluster on the same platform must be able to clone the repo, set the credentials, and launch the deployment from scratch by themselves.

## Cloud

"Highly recommended" to use Kubernetes-as-a-Service (AKS, EKS, GKE, DigitalOcean; also the GitHub Student Pack). Epitech students have Azure credits. Don't waste them: cost management is part of the job.

## Evaluation (defense only)

1. **Initial deployment**: from a fresh cluster, using your delivered resources. The evaluator votes on Poll and sees the result on Result. You may look up the external IPs and hand them over.
2. **No-downtime update**: the source of one app is changed and redeployed. Continuously requesting the app must not produce any error.
3. **Technical choices justification**: every decision, or decision not to act, is discussed. "A deployment that works is not enough": resilient, scalable and easy to operate matter. Read the tools' documentation.
4. **Technical mastery**: questions like "what happens if we `kubectl drain` this node?" or "how would we limit Redis's CPU?".

## Grading rubric (mid-term report)

Not in the PDF: the criteria of the mid-term defense report, the same grid as the final defense. 32 points. Our answer to each criterion, with the command to show: [cheatsheet, la grille](../defense/cheatsheet.md#la-grille-15-critères-32-points).

| Criterion                                            | Points |
| ---------------------------------------------------- | -----: |
| Initial deployment - App working                     |      4 |
| Initial deployment - Persistent data                 |      2 |
| Initial deployment - Private Docker registry         |      1 |
| Redeployment - No-downtime update                    |      2 |
| Justification - Probes                               |      2 |
| Justification - Restart policies                     |      1 |
| Justification - Resource limits                      |      2 |
| Justification - Exposed ports                        |      1 |
| Justification - Load balancers                       |      4 |
| Justification - Affinity policies                    |      2 |
| Justification - Number of nodes                      |      1 |
| Justification - Repository cleanliness and structure |      1 |
| Justification - Documentation                        |      2 |
| Justification - Auto-scaling                         |      6 |
| Justification - Replicas                             |      1 |
