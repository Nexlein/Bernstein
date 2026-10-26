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

| Command                 | Action                                                                      |
| ----------------------- | --------------------------------------------------------------------------- |
| `npm run codemap`       | Regenerates `.claude/codemap.md` (services, routes, env vars, file tree).   |
| `npm run format:check`  | Checks code and markdown formatting across the entire repo.                 |
| `npm run format`        | Automatically formats all code, manifests, and documentation with Prettier. |
| `docker compose config` | Validates local Docker Compose file syntax.                                 |
