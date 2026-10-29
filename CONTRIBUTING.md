# Contributing

Local development of Bernstein: run the 5 services with Docker Compose, the repo tooling, and the [tests](#tests). Kubernetes deployment: [`README.md`](README.md).

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

Check the probes and a vote: [Tests, local stack](#local-stack-docker-compose).

## 4. Tear Down

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

## Tests

We test **our Kubernetes deployment, not the provided application code.** The subject supplies Poll, the worker and Result with their source and Dockerfiles, and grades the deployment: build, private registry, cluster, public access, updates with no error. So every check treats the apps as black boxes, through their HTTP endpoints, probes and votes. The apps come with no tests, and we add none to code we did not write.

Every pull request runs the CI checks (`.github/workflows/ci.yml`). The AKS checks are run by hand on our cluster; their results are below, with the ADR that holds the details.

### What is tested where

| Check                                                          | Where                    | Proves                                                                                                                                            | Does not prove                                                                 |
| -------------------------------------------------------------- | ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| [Formatting and repository](#formatting-and-repository-checks) | CI, local                | Files formatted, codemap up to date, shell scripts clean for shellcheck, Compose file valid, `k8s/schema.sql` equal to the app's                  | That anything runs                                                             |
| [Image builds](#image-builds)                                  | CI, local                | The 3 Dockerfiles build                                                                                                                           | That the images start                                                          |
| [Vulnerability scan](#vulnerability-scan)                      | CI, local                | No fixable `CRITICAL` vulnerability in the 5 images, apart from the accepted ones                                                                 | Anything on `HIGH` or unfixed ones; images already deployed are not rescanned  |
| [Local stack](#local-stack-docker-compose)                     | CI, local                | The 5 services start, their probes answer, a vote reaches PostgreSQL                                                                              | Anything about Kubernetes                                                      |
| [Manifests](#manifests-build-and-schema)                       | CI, local                | `k8s/` renders, and every object matches the Kubernetes 1.36.4 and 1.31 schemas                                                                   | That the values are right, or that the pods start                              |
| [Baseline rules](#baseline-rules-checked-in-ci)                | CI, local                | Our rules: resources, non-root, rollout strategy, 2+ pods, probes, PDBs, public Services                                                          | That the probes pass, or that a rollout has no error                           |
| [kind](#end-to-end-test-on-kind)                               | CI, local                | `k8s/` deploys on Kubernetes 1.36.4 with its NetworkPolicies enforced, a vote goes through, 0 errors during a rollout and during a drain          | Azure: load balancer, disk, Cilium; a drain of PostgreSQL's node               |
| [Registry login and publish](#registry-login-oidc)             | CI, this repository only | CI logs in to our registry with OIDC, no stored password; on `main`, after the tests, the new images are pushed with the tags `deploy.sh` deploys | Skipped in forks, fork PRs and the Epitech mirror; publishes nothing from a PR |
| [Zero downtime on AKS](#zero-downtime-on-aks)                  | AKS, by hand             | The graded test: 0 errors while an update rolls out, through the public IPs and from inside the cluster                                           | Drains and PostgreSQL restarts (next row)                                      |
| [Manual checks on AKS](#manual-checks-on-aks)                  | AKS, by hand             | Drains, PostgreSQL restarts, public ports, database rights, NetworkPolicies, Pod Security                                                         | They were measured once: run them again after a change that touches them       |

### Formatting and repository checks

The CI job "Code Style & Config Validation", which also runs the [manifest checks](#manifests-build-and-schema). Locally:

```bash
npm run format:check
npm run codemap && git diff --exit-code .claude/codemap.md
git ls-files -z '*.sh' | xargs -0 -r shellcheck
docker compose config --quiet
diff poll-application/schema.sql k8s/schema.sql
```

### Image builds

The CI job "Build Container Images" builds Poll, the worker and Result, without pushing them. Locally, all 3 with `docker compose build`, or one:

```bash
docker build -t bernstein-poll:test poll-application/poll
```

### Vulnerability scan

The CI job "Image Vulnerability Scan" scans our 3 images, PostgreSQL and Redis with [Trivy](https://trivy.dev/) 0.76.1. It fails on a `CRITICAL` vulnerability that has a fix, unless `.trivyignore.yaml` accepts it with a reason; the counts and the full list are in the job summary ([ADR 0033](doc/adr/0033-ci-image-scan.md)). The same scan of one local image:

```bash
trivy image --scanners vuln --severity HIGH,CRITICAL --ignorefile .trivyignore.yaml poll:latest
```

When it fails: update the base image or the dependency. If no fixed image exists yet, or the vulnerable code never runs in our pods, add an entry to `.trivyignore.yaml` with a `statement`, and an `expired_at` date when a fix is coming.

### Local stack (Docker Compose)

The CI job "Full Stack Integration & Probe Verification" starts the 5 services with Compose, checks the probes of Poll and Result, casts a vote and finds it in PostgreSQL. The same by hand, with the stack of [section 3](#3-launch-local-multi-service-stack) running:

```bash
curl http://localhost:5000/healthz   # Poll: 200 OK
curl http://localhost:5000/readyz    # Poll: 200 OK if Redis is up
curl http://localhost:5001/healthz   # Result: 200 OK
curl http://localhost:5001/readyz    # Result: 200 OK if PostgreSQL is up
curl -X POST -d vote=a http://localhost:5000/
docker compose exec -T postgres psql -U postgres -d postgres -tAc 'SELECT count(*) FROM votes'   # 1 or more
```

### Manifests: build and schema

Two steps of "Code Style & Config Validation". The first renders `k8s/` as `kubectl apply -k` would. The second checks every rendered object with kubeconform `-strict`, unknown fields refused, against Kubernetes 1.36.4 (our AKS) and 1.31.0 (the minimum `DEPLOY.md` asks for) ([ADR 0029](doc/adr/0029-manifest-schema-validation.md)). Locally, with `k8s/secrets.env` and [kubeconform](https://github.com/yannh/kubeconform) v0.8.0:

```bash
kubectl kustomize k8s/ > /dev/null
kubectl kustomize k8s/ | kubeconform -strict -summary -kubernetes-version 1.36.4 -
```

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

### End-to-end test on kind

The CI job "K8s on kind (deploy and vote)" deploys `k8s/` on a throwaway kind cluster, casts a vote, then runs `tests/zero-downtime.sh --from cluster` during a rollout of Poll and Result and during a drain of a worker; any failed request fails it ([ADR 0031](doc/adr/0031-ci-kind-e2e.md)). To run the same cluster locally (needs Docker and [kind](https://kind.sigs.k8s.io/) v0.33.0):

```bash
kind create cluster --name bernstein --config tests/kind.yaml --image kindest/node:v1.36.4
kind delete cluster --name bernstein
```

Then follow the steps of the `kind-e2e` job in `.github/workflows/ci.yml`: build the 3 images as `poll:ci`, `worker:ci` and `result:ci`, `kind load docker-image` them, and apply the overlay.

### Registry login (OIDC)

The CI job "Registry Login (Azure OIDC)" checks that the 4 Azure secrets exist, logs in to Azure with a short-lived OIDC token from GitHub, then to our registry with `az acr login` ([ADR 0032](doc/adr/0032-ci-registry-oidc.md)). It runs only in this repository, on a push or a PR from one of its branches, and cannot run locally: the token comes from GitHub. Setup, and what `AADSTS700213` means: [cluster setup, section 8](doc/setup/cluster-setup.md#8-build-push-and-deploy).

On a push to `main`, once this login and the tests have passed, the job "Publish Images (main)" runs `scripts/deploy.sh --push-only`: it builds and pushes the apps whose tag is not in the registry yet, and deploys nothing ([ADR 0034](doc/adr/0034-ci-publish-images.md)). The same locally, logged in with `az login`:

```bash
REGISTRY=<name>.azurecr.io scripts/deploy.sh --push-only
```

### Zero downtime on AKS

`tests/zero-downtime.sh` requests Poll and Result in loops, a new connection per request with a 5 s timeout, while a command updates them, and fails on any error ([ADR 0016](doc/adr/0016-zero-downtime-test.md)). `--from cluster` sends the requests from a pod in the cluster, `--from both` from your machine and that pod; `--help` for the rest. The update of the defense ([`DEPLOY.md` part 4](DEPLOY.md#4-update-the-app-with-zero-downtime)), and a restart of Poll and Result:

```bash
REGISTRY=<name>.azurecr.io tests/zero-downtime.sh --from both -- scripts/deploy.sh
tests/zero-downtime.sh --from both -- sh -c 'kubectl -n bernstein rollout restart deploy/poll deploy/result && kubectl -n bernstein rollout status deploy/poll deploy/result'
```

Measured on AKS:

- `rollout restart` of Poll and Result: 0 errors in 975 requests (2 loops per app) and in 1996 (4 loops); with `--from both`, 0 in 994 from the machine and 2375 from the pod ([ADR 0016](doc/adr/0016-zero-downtime-test.md)).
- `scripts/deploy.sh` rolling a new Poll: 0 errors in 1363 requests from the machine and 3080 from the pod ([ADR 0017](doc/adr/0017-deploy-script.md)).
- Rollbacks (`rollout undo`, an older `TAG` or `POLL_TAG`) and broken updates (missing tag, crash at start, Redis unreachable): 0 errors ([`DEPLOY.md` part 5](DEPLOY.md#5-roll-back)).

### Manual checks on AKS

Run on `bernstein-aks` under continuous requests, once each.

| Check                                                                | Result                                                                                                                                 | Details                                                                                                |
| -------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `kubectl drain` of the node with one Poll, one Result and the worker | 0 errors in 2221 requests                                                                                                              | [ADR 0014](doc/adr/0014-pod-disruption-budgets.md)                                                     |
| `kubectl drain` of the node that also runs PostgreSQL and Redis      | 0 errors (Result: 546 requests, 1315 from inside the cluster), PostgreSQL back in 27 s. Before Result reconnected: 47 failed over 39 s | [ADR 0014](doc/adr/0014-pod-disruption-budgets.md), [ADR 0007](doc/adr/0007-postgres-statefulset.md)   |
| `kubectl delete pod postgres-0`                                      | Back in 11 s, 0 errors on Result. Before Result reconnected: down 13 s (same node) to 43 s (other node)                                | [ADR 0008](doc/adr/0008-result-deployment.md)                                                          |
| The worker after a PostgreSQL restart, no vote sent                  | Restarted by its liveness probe, `1/1` again at 66 s                                                                                   | [ADR 0010](doc/adr/0010-worker-deployment.md), [guide](doc/defense/k8s-study-guide.md#les-probes-http) |
| Public IPs, from the internet                                        | Port 80 answers; 22, 443, 5432 and 6379 are closed                                                                                     | [ADR 0023](doc/adr/0023-security-posture.md)                                                           |
| Database rights, from a Result pod                                   | `INSERT` and `DELETE`: `permission denied for table votes`; `DROP TABLE`: `must be owner of table votes`                               | [ADR 0023](doc/adr/0023-security-posture.md)                                                           |
| NetworkPolicies, from a Poll pod                                     | Reaches Redis, not PostgreSQL or the internet                                                                                          | [ADR 0023](doc/adr/0023-security-posture.md), [ADR 0025](doc/adr/0025-network-policies.md)             |
| A pod with `runAsUser: 0`                                            | Refused: `violates PodSecurity "restricted:latest"`                                                                                    | [ADR 0027](doc/adr/0027-pod-security-standards.md)                                                     |
| Spreading the pods after `az aks start`                              | One Poll and one Result per node, 0 errors in 1280 requests from the machine and 2765 from the pod                                     | [`DEPLOY.md`, After `az aks start`](DEPLOY.md#after-az-aks-start)                                      |
