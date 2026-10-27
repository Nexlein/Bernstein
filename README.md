# Bernstein — Orchestrate Your Own Symphony of Containers

[![CI Pipeline](https://github.com/Nexlein/Bernstein/actions/workflows/ci.yml/badge.svg)](https://github.com/Nexlein/Bernstein/actions/workflows/ci.yml)
[![Epitech Mirror](https://github.com/Nexlein/Bernstein/actions/workflows/mirror.yml/badge.svg)](https://github.com/Nexlein/Bernstein/actions/workflows/mirror.yml)

> **Epitech Tek3 DevOps Project**  
> Complete Kubernetes orchestration of a distributed microservices voting application (_Poll_, _Redis_, _Worker_, _PostgreSQL_, _Result_) with private registry pipeline, strict zero-downtime updates, and production best practices.

---

## Deploy on Kubernetes (quick start)

Requires `kubectl`, the Azure CLI, and an AKS cluster attached to your private registry (`az aks update --attach-acr <registry>`). Cluster and registry setup: [`doc/setup/cluster-setup.md`](doc/setup/cluster-setup.md).

```bash
cp k8s/secrets.env.example k8s/secrets.env    # then set POSTGRES_PASSWORD
kubectl apply -k k8s/
kubectl -n bernstein get pods -w              # wait until every pod is Ready
kubectl -n bernstein get svc poll result      # EXTERNAL-IP of Poll and Result
```

The images are taken from the registry and tag set in the `images` field of [`k8s/kustomization.yaml`](k8s/kustomization.yaml). A one-command build, push and deploy to your own registry, and the full deployment guide, are in progress (issues #36, #37, #38).

---

## Application Architecture

```mermaid
flowchart TD
    subgraph External["External World (Internet)"]
        UserVote["Voter (Browser)"]
        UserResult["Viewer (Browser)"]
    end

    subgraph IngressLayer["Public Services (Azure Load Balancer, one public IP each)"]
        PollIngress["poll Service\n(type: LoadBalancer, :80)"]
        ResultIngress["result Service\n(type: LoadBalancer, :80, WebSocket)"]
    end

    subgraph WebTier["Front-End Workloads (Replicas >= 2)"]
        PollPods["Poll Pods (Flask / Python 3.14)\n• Port: 80\n• Liveness: GET /healthz\n• Readiness: GET /readyz (Redis PING)"]
        ResultPods["Result Pods (Node.js 24 / Express / Socket.IO)\n• Port: 80\n• Liveness: GET /healthz\n• Readiness: GET /readyz (Postgres SELECT 1)"]
    end

    subgraph InternalServices["Cluster Internal Services (ClusterIP)"]
        RedisSvc["redis:6379\n(ClusterIP)"]
        PostgresSvc["postgres:5432\n(ClusterIP)"]
    end

    subgraph BackingTier["Back-End & Storage Tier"]
        RedisPod["Redis 8.x Pod\n• In-memory list: 'votes'\n• Protected by requirepass (optional)"]
        PostgresPod["PostgreSQL 18 Pod\n• Persistent DB: 'votes' table\n• Init: schema.sql"]
        PostgresPVC[("PersistentVolumeClaim (PVC)\n/var/lib/postgresql")]
    end

    subgraph ProcessingTier["Background Worker Workload"]
        WorkerPod["Worker Pod (Java 25 / Maven)\n• Port: 80 (Health probes only)\n• Liveness: GET /healthz\n• Readiness: GET /readyz (Redis & DB check)\n• BLPOP from Redis -> UPSERT to Postgres"]
    end

    %% External routing
    UserVote --> PollIngress --> PollPods
    UserResult --> ResultIngress --> ResultPods

    %% Internal communication
    PollPods -- "RPUSH votes JSON" --> RedisSvc --> RedisPod
    WorkerPod -- "BLPOP votes" --> RedisSvc
    WorkerPod -- "UPSERT into votes table" --> PostgresSvc --> PostgresPod
    ResultPods -- "SELECT vote tally" --> PostgresSvc
    PostgresPod --- PostgresPVC
```

---

## Local Development

Run the 5 services locally with Docker Compose, install the Git hooks and use the repo commands: [`CONTRIBUTING.md`](CONTRIBUTING.md).

---

## Kubernetes Secrets

The repository holds no password. Before deploying, create `k8s/secrets.env` from the template and fill it in:

```bash
cp k8s/secrets.env.example k8s/secrets.env
```

| Key                 | Required | Effect                                     |
| ------------------- | -------- | ------------------------------------------ |
| `POSTGRES_PASSWORD` | yes      | Password of the PostgreSQL `postgres` user |
| `REDIS_PASSWORD`    | no       | Empty = Redis runs without authentication  |

`k8s/secrets.env` is gitignored. `kubectl apply -k k8s/` turns it into the `app-secrets` Secret and fails if the file is missing. Registry access needs no secret: AKS pulls from ACR through `--attach-acr` (see [ADR 0002](doc/adr/0002-acr-registry.md)).

---

## Roadmap & Decisions

Work is tracked as GitHub issues, grouped into 4 epics: [Registry & pipeline](https://github.com/Nexlein/Bernstein/issues/43), [K8s manifests](https://github.com/Nexlein/Bernstein/issues/44), [Zero-downtime & resilience](https://github.com/Nexlein/Bernstein/issues/45), [Docs & defense](https://github.com/Nexlein/Bernstein/issues/46). Start from the lowest open issue; dependencies are set as "blocked by".

Technical choices, one Architecture Decision Record (ADR) each, with pros, cons and rejected alternatives: [`doc/adr/`](doc/adr/README.md).

Step-by-step AKS cluster & ACR registry setup guide: [`doc/setup/cluster-setup.md`](doc/setup/cluster-setup.md).

---

## Project Structure

```
├── .claude/              # Agent settings and the generated code map
├── .github/              # CI, Epitech mirror, Dependabot, PR template
├── .husky/               # Pre-commit hook (regenerates the code map)
├── doc/                  # ADRs, cluster setup guide, defense study guide, subject
├── k8s/                  # Kustomize manifests (kubectl apply -k k8s/)
├── poll-application/     # Provided source code and Dockerfiles: Poll, Result, Worker
├── scripts/              # Code map generator
├── tests/                # Zero-downtime test
├── docker-compose.yml    # Local 5-service stack, also used by CI
├── CONTRIBUTING.md       # Local development and repo commands
└── CLAUDE.md             # Agent instructions and project rules
```

---

## Key Requirements & Defense Guardrails

- **Zero-Downtime Rolling Updates**: User-facing services (`poll`, `result`) must maintain 100% availability during rolling deployments (`maxUnavailable: 0`, `readinessProbe` enabled, replicas $\ge 2$).
- **Secret Isolation**: Sensitive credentials (`POSTGRES_PASSWORD`, cloud tokens) are never committed to Git and are configured via a Kubernetes Secret generated from `k8s/secrets.env` (template: `k8s/secrets.env.example`).
- **High Availability & Persistence**: PostgreSQL data is mounted on a `PersistentVolumeClaim` (PVC), and all pods specify CPU/Memory resource requests and limits.
