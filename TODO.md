# Bernstein Project Roadmap & Checklist

> **Objective:** End-to-end Kubernetes orchestration of the Poll application with zero-downtime updates, high availability, and defense readiness.

---

## Phase 1: Local Development & Verification

- [x] Create local orchestration test setup (`docker-compose.yml`):
  - [x] Redis 8.x service with healthcheck
  - [x] PostgreSQL service with automatic `schema.sql` loading and healthcheck
  - [x] Worker connected to Redis & PostgreSQL
  - [x] Poll web app connected to Redis
  - [x] Result web app connected to PostgreSQL
- [x] Base CI/CD Pipelines:
  - [x] Dependabot configuration (`.github/dependabot.yml` covering npm, pip, maven, docker, github-actions)
  - [x] Prettier format checking (`npm run format:check`) and `.prettierrc`
  - [x] Epitech mirror workflow (`.github/workflows/mirror.yml`)
  - [x] GitHub Actions CI workflow (`.github/workflows/ci.yml` with format check, codemap freshness, container builds, and integration tests)
- [ ] Verify container builds for each microservice:
  - [ ] `poll-application/poll/Dockerfile` (Python 3.14 Flask)
  - [ ] `poll-application/worker/Dockerfile` (Java 25 Maven multi-stage)
  - [ ] `poll-application/result/Dockerfile` (Node.js 24 Express/Socket.IO)
- [ ] Validate end-to-end functionality live:
  - [ ] Cast votes on Poll (`:5000`)
  - [ ] Verify `votes` list pop in Redis
  - [ ] Verify Worker upserts vote into PostgreSQL `votes` table
  - [ ] Verify real-time score refresh on Result (`:5001`)
- [ ] Validate healthcheck endpoints (`/healthz` and `/readyz`) across all 3 services.

---

## Phase 2: Container Registry & CI/CD Pipeline

- [ ] Set up private Docker container registry (e.g. Azure Container Registry ACR / Docker Hub private repo).
- [ ] Implement build & tag automation script/workflow.
- [ ] Push versioned images (`poll:v1.0.0`, `worker:v1.0.0`, `result:v1.0.0`) to private registry.
- [ ] Create Kubernetes `imagePullSecret` to pull images securely from private registry.

---

## Phase 3: Kubernetes Manifests & Infrastructure

- [ ] Structure Kubernetes manifests (clean modular `k8s/` or `helm/` layout):
  - [ ] Namespaces and RBAC configuration.
  - [ ] `ConfigMaps` for non-sensitive service configs (`REDIS_HOST`, `POSTGRES_DB`, etc.).
  - [ ] `Secrets` management (template for `POSTGRES_PASSWORD`, `REDIS_PASSWORD`, registry credentials).
- [ ] Database & Storage Tier:
  - [ ] PostgreSQL 18 Deployment / StatefulSet with `PersistentVolumeClaim` (PVC) for `/var/lib/postgresql`.
  - [ ] Database schema initialization job / init container for `schema.sql`.
  - [ ] Internal `ClusterIP` Service for PostgreSQL (`port: 5432`).
  - [ ] Redis 8.x Deployment + Internal `ClusterIP` Service (`port: 6379`).
- [ ] Microservices Workloads:
  - [ ] `poll` Deployment (replicas >= 2, resource requests/limits, liveness/readiness probes).
  - [ ] `worker` Deployment (resource requests/limits, probes).
  - [ ] `result` Deployment (replicas >= 2, resource requests/limits, liveness/readiness probes).
- [ ] Networking & External Ingress:
  - [ ] Expose `poll` and `result` to the outside world via Ingress or LoadBalancer Services.
  - [ ] Keep internal components (`redis`, `postgres`, `worker`) isolated inside cluster.

---

## Phase 4: Zero-Downtime Deployment & Resilience

- [ ] Configure `RollingUpdate` parameters (`maxSurge: 1`, `maxUnavailable: 0`).
- [ ] Configure `minReadySeconds` and proper `readinessProbe` timings.
- [ ] Configure `terminationGracePeriodSeconds` and preStop hooks if needed.
- [ ] Create automated zero-downtime test script (`scripts/test-zero-downtime.sh`):
  - Continuously fires HTTP requests while updating the deployment image.
  - Verifies zero 5xx errors or dropped connections during rollout.
- [ ] Test node disruption resilience (e.g., `kubectl drain` behavior, `PodDisruptionBudget`).

---

## Phase 5: Documentation & Evaluator Runbook

- [ ] Write evaluator deployment runbook (`DEPLOY.md` or `README.md`):
  - Prerequisites (kubectl, cloud cluster access).
  - Secret & credentials configuration steps.
  - One-command deployment launch.
  - Verification commands to get external IPs and test app.
- [ ] Defense Preparation:
  - Justification document for architectural and technical choices.
  - Cheatsheet for live questions (node drain, Redis memory limits, HPA, failover).
