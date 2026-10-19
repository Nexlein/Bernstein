# Bernstein Roadmap

Work is tracked as GitHub issues, grouped into 4 epics: [Registry & pipeline](https://github.com/Nexlein/Bernstein/issues/43), [K8s manifests](https://github.com/Nexlein/Bernstein/issues/44), [Zero-downtime & resilience](https://github.com/Nexlein/Bernstein/issues/45), [Docs & defense](https://github.com/Nexlein/Bernstein/issues/46). Start from the lowest open P0 issue; dependencies are set as "blocked by".

Graded (see `doc/subject/SUBJECT.md`): build → push to private registry → deploy to K8s; Poll + Result public; evaluator can redeploy from scratch; zero-error update; justified choices; technical mastery.

## Done

Local compose stack (smoke-tested), CI, Dependabot, Epitech mirror, non-root images, SIGTERM drain in Result, websocket client.

## Decisions (issue #8)

Fill in when decided, one line of justification each.

- Cloud / K8s: **Azure AKS** (`bernstein-aks` in `spaincentral`, 2 × `Standard_B2s_v2` nodes — 2 vCPU / 8 GiB RAM each) — covered by Epitech Azure credits; 2 nodes is the minimum to survive `kubectl drain` and ensure zero-downtime rollouts within the 6 vCPU regional student quota (see [`doc/setup/cluster-decisions.md`](doc/setup/cluster-decisions.md)).
- Private registry: **Azure Container Registry** (`bernsteinacrmaeva`, `Basic` SKU in `francecentral`) — attached directly to AKS via managed identity (`--attach-acr`), avoiding static `imagePullSecrets`.
- Manifests: _Kustomize (`k8s/`) suggested_
- Public access: _ingress-nginx suggested (one IP, host routing, WebSocket for Result)_
- Image tags: _git SHA (a rollout only triggers when the tag changes)_
