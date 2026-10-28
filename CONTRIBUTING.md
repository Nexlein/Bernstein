# Contributing

Local development of Bernstein: run the 5 services with Docker Compose, and the repo tooling. Kubernetes deployment: [`README.md`](README.md).

## 1. Prerequisites

- Docker & Docker Compose (v2+)
- Node.js (v22+)

## 2. Team Setup & Git Hooks

Install root development tools (Husky pre-commit hooks and Prettier):

```bash
npm install
```

_Note: Git hooks will automatically bind upon running `npm install` via Husky._

## 3. Launch Local Multi-Service Stack

Run the entire 5-tier voting stack locally:

```bash
# Start all containers in the background with health checks
docker compose up -d

# Check live logs
docker compose logs -f
```

Optional: Compose sets `POSTGRES_PASSWORD=postgres` by default. To change it, run `cp .env.example .env` (gitignored) and edit `.env`.

- **Poll Web UI**: [http://localhost:5000](http://localhost:5000)
- **Result Web UI**: [http://localhost:5001](http://localhost:5001)

## 4. Verify Health Probes

```bash
# Poll probes
curl http://localhost:5000/healthz   # 200 OK
curl http://localhost:5000/readyz    # 200 OK if Redis is up

# Result probes
curl http://localhost:5001/healthz   # 200 OK
curl http://localhost:5001/readyz    # 200 OK if PostgreSQL is up
```

## 5. Tear Down

```bash
docker compose down -v
```

## Development & CI/CD Commands

| Command                                                                               | Action                                                                                                                                                              |
| ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `npm run codemap`                                                                     | Regenerates `.claude/codemap.md` (services, routes, env vars, file tree).                                                                                           |
| `npm run format:check`                                                                | Checks code and markdown formatting across the entire repo.                                                                                                         |
| `npm run format`                                                                      | Automatically formats all code, manifests, and documentation with Prettier.                                                                                         |
| `docker compose config`                                                               | Validates local Docker Compose file syntax.                                                                                                                         |
| `tests/zero-downtime.sh -- <command>`                                                 | Requests Poll and Result while `<command>` updates them; fails on any error. `--from both` also requests them from a pod in the cluster. `--help` for usage.        |
| `kubectl kustomize k8s/ \| kubeconform -strict -summary -kubernetes-version 1.36.4 -` | Validates every rendered object against the Kubernetes schema, as CI does (needs [kubeconform](https://github.com/yannh/kubeconform) v0.8.0 and `k8s/secrets.env`). |

### Baseline rules checked in CI

`scripts/check-baseline.mjs` fails the pull request when the rendered manifests break one of these rules ([ADR 0030](doc/adr/0030-baseline-rules-check.md)):

1. Every container has `requests` and `limits`, for CPU and memory.
2. Every container runs non-root (`runAsNonRoot: true`) with `allowPrivilegeEscalation: false`.
3. Every Deployment rolls with `maxSurge: 1`, `maxUnavailable: 0` and `minReadySeconds: 5`.
4. Poll and Result keep 2+ pods: `replicas >= 2`, or an HPA with `minReplicas >= 2` and no `replicas` in the Deployment.
5. Poll and Result have readiness and liveness probes, a `preStop` hook and a PodDisruptionBudget.
6. Only the `poll` and `result` Services are `LoadBalancer`; the others are `ClusterIP`.

Run it locally as CI does (needs `k8s/secrets.env`). Without `yq`, the Python line does the same conversion:

```bash
kubectl kustomize k8s/ | yq ea -o=json '[.]' | node scripts/check-baseline.mjs
kubectl kustomize k8s/ | python3 -c 'import sys,yaml,json; json.dump(list(yaml.safe_load_all(sys.stdin)), sys.stdout)' | node scripts/check-baseline.mjs
```
