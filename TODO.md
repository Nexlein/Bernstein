# Bernstein Roadmap

Graded (see `doc/subject/SUBJECT.md`): build → push to private registry → deploy to K8s; Poll + Result public; evaluator can redeploy from scratch; zero-error update; justified choices; technical mastery.

## Decisions (fill in before Phase 2)

- [ ] Cloud / K8s: _AKS suggested (Epitech Azure credits)_
- [ ] Private registry: _ACR suggested_
- [ ] Manifests: _Kustomize (`k8s/`) suggested_
- [ ] Public access: _ingress-nginx suggested (one IP, host routing, WebSocket for Result)_
- [ ] Image tags: git SHA (a rollout only triggers when the tag changes)

## Phase 1: Local + repo setup (done)

- [x] `docker-compose.yml` 5-service stack, smoke-tested (vote → Postgres, probes, non-root, PG 18)
- [x] CI (format, codemap freshness, builds, integration vote test), Dependabot, Epitech mirror
- [x] Non-root images, SIGTERM drain in Result, websocket client

## Phase 2: Registry + deploy pipeline

- [ ] Create private registry, `imagePullSecret` template
- [ ] CI job: build + push images tagged with git SHA

## Phase 3: Kubernetes manifests (`k8s/`)

- [ ] Namespace, ConfigMap, Secret template (`POSTGRES_PASSWORD`, `REDIS_PASSWORD`, registry)
- [ ] Postgres (StatefulSet + PVC at `/var/lib/postgresql`, `schema.sql` init), Redis, ClusterIP only
- [ ] poll / result (replicas ≥ 2), worker: requests/limits, probes `/healthz` `/readyz`, runAsNonRoot (+ sysctl `net.ipv4.ip_unprivileged_port_start=0` for port 80)
- [ ] Public exposure for Poll and Result (ingress or LB)

## Phase 4: Zero-downtime + resilience

- [ ] RollingUpdate `maxSurge: 1`, `maxUnavailable: 0`, `minReadySeconds: 5`, preStop sleep, `terminationGracePeriodSeconds`
- [ ] `scripts/test-zero-downtime.sh`: curl loop during `set image`, fail on any non-2xx
- [ ] Optional, for justification: PDB, anti-affinity, HPA, NetworkPolicies

## Phase 5: Docs + defense

- [ ] `DEPLOY.md`: prerequisites, where to set credentials/`POSTGRES_PASSWORD`, one deploy command, verification
- [ ] Defense notes: justify each choice; cheatsheet (drain, pod kill, limit Redis, autoscale poll, DB backup/failover)
