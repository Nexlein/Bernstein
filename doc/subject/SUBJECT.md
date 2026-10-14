# Bernstein — Orchestrate Your Own Symphony of Containers

> **Document Type:** Epitech Tek3 Project Subject (Version 2)  
> **Original File:** [`doc/subject/bernstein-project.pdf`](bernstein-project.pdf)  
> **Key Focus:** Kubernetes Orchestration, Cloud Infrastructure, CI/CD / Deployment Automation, Zero-Downtime Deployment, High Availability & Best Practices.

---

## 1. Project Overview & Metaphor

Leonard Bernstein was an acclaimed composer, pianist, and conductor (notably conducting _West Side Story_ and Hector Berlioz's _Symphonie fantastique_). In musical orchestration, pieces of music are arranged so an orchestra can play them together in harmony.

In this project, the student acts as the "Leonard Bernstein of containers," orchestrating a multi-tier microservices application using **Kubernetes** to achieve scalable, automated, and reliable operations.

---

## 2. Application Architecture (The Poll Application)

The application to deploy is a voting application composed of **5 constituent elements**:

### Component Breakdown

```
[ Front End ]
Poll (Flask / Python)        Result (Node.js / Express / Socket.IO)
      |                                ^
      v (RPUSH votes)                  | (SELECT)
    Redis (Queue)                      |
      ^                                |
      | (BLPOP votes)                  |
Worker (Java) ------------------> PostgreSQL 18 (votes table)
              (UPSERT)
[ Back End ]
```

1. **Poll**:
   - **Tech Stack:** Python (Flask, Gunicorn, Python 3.14).
   - **Role:** Web front-end that gathers votes from users and pushes them as JSON messages into a Redis list named `votes`.
   - **Exposure:** Front-end exposed to the outside world.
   - **Port:** `80`.
   - **Healthchecks:**
     - Liveness: `GET /healthz`
     - Readiness: `GET /readyz` (returns `200` if Redis responds to `PING`, `503` otherwise).
   - **Environment Variables:**
     - `REDIS_HOST` (Required)
     - `REDIS_PASSWORD` (Optional, defaults to none)
     - `OPTION_A` (Optional, default: `Ansible`)
     - `OPTION_B` (Optional, default: `Chef`)
     - `OPTION_C` (Optional, default: `Puppet`)
     - `OPTION_D` (Optional, default: `SaltStack`)

2. **Redis Queue**:
   - **Tech Stack:** Redis 8.x.
   - **Role:** In-memory queue storing incoming votes in the `votes` list awaiting consumption by Worker.
   - **Auth:** Can be secured with `requirepass`.
   - **Exposure:** Back-end internal service.

3. **Worker**:
   - **Tech Stack:** Java 25 (Multi-stage Maven build).
   - **Role:** Background service consuming votes from Redis (`BLPOP votes`) and persisting / upserting them into PostgreSQL (`votes` table).
   - **Exposure:** Back-end service (no external application traffic).
   - **Port:** `80` (health endpoints only).
   - **Healthchecks:**
     - Liveness: `GET /healthz`
     - Readiness: `GET /readyz` (returns `200` if Redis answers `PING` **and** PostgreSQL connection is valid, `503` otherwise).
   - **Environment Variables:**
     - `REDIS_HOST` (Required)
     - `REDIS_PASSWORD` (Optional, defaults to none)
     - `POSTGRES_HOST` (Required)
     - `POSTGRES_PORT` (Required)
     - `POSTGRES_DB` (Required)
     - `POSTGRES_USER` (Required)
     - `POSTGRES_PASSWORD` (Required)

4. **PostgreSQL Database**:
   - **Tech Stack:** PostgreSQL 18.
   - **Role:** Relational database storing votes persistently.
   - **Schema:** Requires `schema.sql` to be applied prior to worker/result operation:
     ```sql
     CREATE TABLE IF NOT EXISTS votes (
       id VARCHAR(255) NOT NULL UNIQUE,
       vote VARCHAR(255) NOT NULL
     );
     ```
   - **Exposure:** Back-end internal service with persistent storage.

5. **Result**:
   - **Tech Stack:** Node.js 24 (Express + Socket.IO).
   - **Role:** Web front-end that reads vote tallies from PostgreSQL and pushes real-time updates to connected browsers via WebSockets.
   - **Exposure:** Front-end exposed to the outside world.
   - **Port:** `80`.
   - **Healthchecks:**
     - Liveness: `GET /healthz`
     - Readiness: `GET /readyz` (returns `200` if PostgreSQL answers `SELECT 1`, `503` otherwise).
   - **Environment Variables:**
     - `POSTGRES_HOST` (Required)
     - `POSTGRES_PORT` (Required)
     - `POSTGRES_DB` (Required)
     - `POSTGRES_USER` (Required)
     - `POSTGRES_PASSWORD` (Required)

---

## 3. Goals & Requirements

The primary objective is to implement an end-to-end deployment pipeline/process for the Poll application, going from raw source code to a live Kubernetes cluster.

### Required Deployment Sequence

In order:

1. **Build** the various application container images (`poll`, `worker`, `result`).
2. **Push** the built images to a **private Docker registry**.
3. **Deploy** the entire application stack onto a **Kubernetes cluster**.

### Accessibility Requirements

- Following deployment, **both** `Poll` and `Result` web pages must be reachable from the outside world (public internet / external IPs or domains).
- The internal components (`Redis`, `PostgreSQL`, `Worker`) must remain secured within the cluster network.

### Supplementary Tools & Freedom of Implementation

- Choice of tooling is entirely open:
  - CI/CD systems (GitHub Actions, GitLab CI, etc.)
  - Infrastructure / Kubernetes management (Helm charts, Kustomize, plain manifests, Terraform, Ansible, ArgoCD, etc.)
  - Private registry solutions (Azure ACR, AWS ECR, GCP GCR/Artifact Registry, Docker Hub private repo, self-hosted harbor, etc.)

---

## 4. Delivery & Repository Guidelines

### Final Expected Delivery

The repository must contain the complete set of manifests, scripts, configuration, and documentation needed to deploy the application, **EXCEPT FOR**:

- Cloud platform credentials and API keys.
- The `POSTGRES_PASSWORD` secret (and sensitive Redis secrets).

### Crucial Requirement: Documentation

- You **MUST** document clearly in the repository:
  - How and where to configure platform credentials and secrets.
  - Step-by-step instructions to reproduce the deployment from scratch.
- **Reproducibility Test:** An evaluator equipped with a fresh, ready-to-use Kubernetes cluster on the chosen cloud platform must be able to:
  1. Clone your repository.
  2. Set their credentials/secrets following your documentation.
  3. Run your deployment command/script.
  4. Have the whole system functioning without any manual hacking.

---

## 5. Cloud Platform Recommendations

- It is **strongly recommended** to use a managed **Kubernetes-as-a-Service (KaaS)** offering rather than setting up a local multi-node cluster with a local private registry.
- Supported / Suggested Platforms:
  - Azure Kubernetes Service (AKS) — _Epitech students have Azure credits available._
  - Amazon Elastic Kubernetes Service (EKS).
  - Google Kubernetes Engine (GKE).
  - DigitalOcean Kubernetes (DOKS).
  - Student offers via [GitHub Student Developer Pack](https://education.github.com/pack).
- **Cost Management Warning:** Do not waste cloud credits. Remember to shut down / delete idle clusters or load balancers when not in use.

---

## 6. Evaluation & Defense Protocol

The project is evaluated 100% via an interactive oral defense covering 4 pillars:

### Pillar 1: Initial Deployment (Fresh Cluster)

- Starting from a fresh cluster, execute the deployment process using the submitted code/scripts.
- Demonstrate that the application is fully functional:
  - Provide external IP addresses / URLs to the evaluator.
  - The evaluator casts a vote on the `Poll` UI.
  - The result immediately updates and displays on the `Result` UI.

### Pillar 2: Zero-Downtime Rolling Update (No-Downtime Update)

- After the initial deployment is proven healthy:
  - A source code modification will be made to one of the microservices (e.g. text change in Poll or Result).
  - Redeploy the updated application to the cluster.
- **Requirement:** Must demonstrate **zero downtime**.
  - Continuous requests sent to the service (e.g., via a looping curl / HTTP load test) must **not return any error (no 5xx or connection drops)** while the rolling update occurs.
  - Proper configuration of Kubernetes readiness probes, rolling update strategies (`maxSurge`, `maxUnavailable`), termination grace periods, and pod anti-affinity or replicas.

### Pillar 3: Technical Choices Justification & Best Practices

- Discuss in detail why certain design choices were made (and why alternatives were rejected).
- Justify:
  - Cluster architecture and sizing.
  - Manifest management (Helm, Kustomize, standard manifests).
  - Ingress controller vs LoadBalancer Services.
  - Secrets and ConfigMaps management.
  - Storage: PersistentVolumes, PersistentVolumeClaims, StorageClasses for PostgreSQL (and Redis if persistence is desired).
  - Security (NetworkPolicies, RunAsNonRoot, ServiceAccounts, RBAC).
  - High availability, resilience, scalability (HPA, resource requests/limits).
- _"Having a deployment that works is not enough! Far from it! Making it resilient, scalable, and easy to operate is extremely important."_

### Pillar 4: Technical Mastery (Live Scenarios & Questions)

The student must demonstrate deep theoretical and operational knowledge of Kubernetes and the deployed stack. Be prepared to answer questions such as:

- _"What will happen if we do X?"_
  - Example: _"What will happen if we use `kubectl drain` on this node?"_
  - Example: _"What happens if a pod crashes or is killed abruptly?"_
- _"How would we do X?"_
  - Example: _"How would we limit the processing power / memory of Redis?"_
  - Example: _"How would we autoscale the poll service under heavy traffic?"_
  - Example: _"How do we handle database backups or failover?"_

---

## 7. Key Architecture & Kubernetes Checklist for Implementation

To ace this project and defense, the following Kubernetes features should be designed and documented:

| Area                       | Key Considerations & Kubernetes Resources                                                                                                                                                 |
| -------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Packaging & CI/CD**      | Multi-stage Docker builds, image tagging (`v1.0.0`, git sha), push to private registry using imagePullSecrets.                                                                            |
| **Workloads**              | `Deployment` for stateless services (`poll`, `result`, `worker`). `StatefulSet` or `Deployment` with PVC for stateful services (`postgres`, `redis`).                                     |
| **Configuration**          | `ConfigMap` for non-sensitive env vars (`REDIS_HOST`, `POSTGRES_DB`, etc.). `Secret` for `POSTGRES_PASSWORD`, `REDIS_PASSWORD`.                                                           |
| **Storage & State**        | `PersistentVolumeClaim` (PVC) for PostgreSQL data directory (`/var/lib/postgresql/data`).                                                                                                 |
| **Networking**             | Internal `ClusterIP` services for `redis`, `postgres`, `worker`. `LoadBalancer` or `Ingress` (with NGINX/Traefik) for `poll` and `result`.                                                |
| **Health & Zero-Downtime** | `livenessProbe` and `readinessProbe` configured on all services using `/healthz` and `/readyz`. RollingUpdate strategy with proper `minReadySeconds` and `terminationGracePeriodSeconds`. |
| **Resource Management**    | `resources.requests` and `resources.limits` (CPU/Memory) specified on every container.                                                                                                    |
| **Resilience & HA**        | Multiple replicas (`replicas: >= 2`) for web tier, pod disruption budgets (`PodDisruptionBudget`), pod anti-affinity.                                                                     |
