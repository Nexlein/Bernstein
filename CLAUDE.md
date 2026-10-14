# Bernstein — Kubernetes Orchestration

Epitech Tek3 DevOps project: Build, containerize, and orchestrate a multi-service voting application (_Poll_, _Redis_, _Worker_, _PostgreSQL_, _Result_) on a Kubernetes cluster with private image registry, automated deployment pipeline, and strict zero-downtime rolling updates.

---

## Start Here (Token Saver)

- `.claude/codemap.md`: Generated map of services (image, port, routes, env vars) and the file tree. Read this first before searching or reading source files.
- `TODO.md`: Full implementation roadmap and checklist from local verification to defense readiness.
- `doc/subject/SUBJECT.md`: Official project requirements, grading rubric, defense protocol, and technical mastery questions.

---

## Architecture

Diagram: `README.md`. Flow: poll -RPUSH-> redis -BLPOP-> worker -UPSERT-> postgres <-SELECT- result.

---

## Microservices Quick Reference

| Service      | Language / Image                 | Internal Port      | Public?       | Health Probes         | Key Environment Variables                                                                                             |
| ------------ | -------------------------------- | ------------------ | ------------- | --------------------- | --------------------------------------------------------------------------------------------------------------------- |
| **poll**     | Python 3.14 (`poll/Dockerfile`)  | `80`               | **Yes**       | `/healthz`, `/readyz` | `REDIS_HOST`, `REDIS_PASSWORD`, `OPTION_{A,B,C,D}`                                                                    |
| **redis**    | Redis 8.x (`redis:8-alpine`)     | `6379`             | No (Internal) | `redis-cli ping`      | `requirepass` (optional)                                                                                              |
| **worker**   | Java 25 (`worker/Dockerfile`)    | `80` (health only) | No (Internal) | `/healthz`, `/readyz` | `REDIS_HOST`, `REDIS_PASSWORD`, `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD` |
| **postgres** | PostgreSQL 18 (`postgres:18`)    | `5432`             | No (Internal) | `pg_isready`          | `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD`                                                                   |
| **result**   | Node.js 24 (`result/Dockerfile`) | `80`               | **Yes**       | `/healthz`, `/readyz` | `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD`                                 |

---

## Command Cheatsheet

### Project & Team Automation

- `npm install`: Installs Husky and automatically registers git pre-commit hooks on any clone.
- `npm run codemap`: Regenerates `.claude/codemap.md` (runs automatically before every git commit via `.husky/pre-commit`).

### Local Docker & Image Builds

- `docker build -t poll:latest poll-application/poll/`
- `docker build -t worker:latest poll-application/worker/`
- `docker build -t result:latest poll-application/result/`
- `docker compose up -d` (starts full local 5-service test stack)
- `docker compose down -v` (stops local stack and cleans volumes)

### Kubernetes Operations

- Inspect cluster: `kubectl get pods,svc,pvc,ingress -o wide`
- Watch rollout: `kubectl rollout status deployment/<deployment-name>`
- View logs: `kubectl logs -f deployment/<deployment-name>`
- Apply manifests: `kubectl apply -f k8s/`
- Test node drain (defense scenario): `kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data`

---

## Strict Rules & Guardrails

### 1. Zero-Downtime Rolling Updates (Mandatory for Defense)

- Both `Poll` and `Result` must remain 100% responsive without returning any 5xx error or connection drop while an image update rolls out.
- Every deployment manifest **must** define:
  ```yaml
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  minReadySeconds: 5
  ```
- Replicas for `poll` and `result` must be at least `2`.
- `readinessProbe` and `livenessProbe` must target the application's native endpoints (`/healthz` and `/readyz`).

### 2. Secret Separation & Reproducibility (Mandatory)

- **NEVER** commit plain-text passwords, private registry tokens, or cloud API keys to git.
- Provide clear templates/instructions (e.g. `secret.example.yaml` or `.env.example`) specifying where and how the evaluator must supply:
  1. `POSTGRES_PASSWORD` (and optional `REDIS_PASSWORD`).
  2. Cloud credentials / registry pull secret.
- An evaluator with a fresh Kubernetes cluster must be able to clone the repo, fill in their secrets, run the deployment command, and have the app running without manual intervention.

### 3. Production Best Practices

- Every pod container must declare `resources.requests` and `resources.limits` (CPU and Memory).
- PostgreSQL data must be bound to a `PersistentVolumeClaim` (PVC) so database data survives pod restarts.
- Security: run containers as non-root where possible, and keep database/queue services completely isolated on the internal cluster network (`ClusterIP`).

### 4. Git Flow & Code Map

- Conventional commits: `feat(k8s): ...`, `fix(worker): ...`, `docs: ...`, `chore: ...`.
- Never manually edit `.claude/codemap.md` — let the pre-commit hook or `npm run codemap` generate it.
