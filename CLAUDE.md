# Bernstein — Kubernetes Orchestration

Epitech Tek3 DevOps project: Build, containerize, and orchestrate a multi-service voting application (_Poll_, _Redis_, _Worker_, _PostgreSQL_, _Result_) on a Kubernetes cluster with private image registry, automated deployment pipeline, and strict zero-downtime rolling updates.

---

## Start Here (Token Saver)

@.claude/codemap.md
@doc/subject/SUBJECT.md

- `.claude/codemap.md`: Generated map of services (image, port, routes, env vars) and the file tree. Read this first before searching or reading source files.
- `doc/adr/`: Architecture Decision Records, one file per technical choice, with pros, cons and rejected alternatives. Index and question lookup in `doc/adr/README.md`. Record new decisions there from `0000-template.md`.
- Work tracking: GitHub issues, grouped into 4 epics (links in `README.md`). Start from the lowest open issue.
- `doc/subject/SUBJECT.md`: Condensed official subject (what is graded). The rules below are our own baseline, stricter than the subject.

---

## Architecture

Diagram: `README.md`. Flow: poll -RPUSH-> redis -BLPOP-> worker -UPSERT-> postgres <-SELECT- result.

Stack (justifications in `doc/adr/`): AKS cluster, ACR private registry (attached to AKS), Kustomize manifests in `k8s/`, images tagged with the git SHA. Public access: one `LoadBalancer` Service each for Poll and Result, no Ingress.

---

## Services

Ports, probes, env vars, versions: `.claude/codemap.md` and `poll-application/README.md`.

---

## Commands

- `npm install`: installs Husky hooks + Prettier. `npm run codemap` / `npm run format`: regenerate codemap / format (the pre-commit hook formats staged files with lint-staged, then runs the codemap).
- `docker compose up -d --build` / `docker compose down -v`: local 5-service stack (Poll :5000, Result :5001).

---

## Our Baseline Rules (stricter than the subject)

### 1. Zero-Downtime Rolling Updates (graded: no errors during an update)

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

### 2. Secret Separation & Reproducibility (graded)

- **NEVER** commit plain-text passwords, private registry tokens, or cloud API keys to git.
- Provide clear templates/instructions (e.g. `secret.example.yaml` or `.env.example`) specifying where and how the evaluator must supply:
  1. `POSTGRES_PASSWORD` (and optional `REDIS_PASSWORD`).
  2. Cloud credentials / registry pull secret.
- An evaluator with a fresh Kubernetes cluster must be able to clone the repo, fill in their secrets, run the deployment command, and have the app running without manual intervention.

### 3. Best Practices (justified at defense)

- Every pod container must declare `resources.requests` and `resources.limits` (CPU and Memory).
- PostgreSQL data must be bound to a `PersistentVolumeClaim` (PVC) so database data survives pod restarts.
- Security: run containers as non-root where possible, and keep database/queue services completely isolated on the internal cluster network (`ClusterIP`).

### 4. Git & Code Map

- Conventional commits: `feat(k8s): ...`, `fix(worker): ...`, `docs: ...`, `chore: ...`. No Co-Authored-By lines. Never push without being asked.
- Never manually edit `.claude/codemap.md` — let the pre-commit hook or `npm run codemap` generate it.
