# Antisèche soutenance : les questions en direct

D'abord la grille de notation (G1 à G15), puis les questions en direct (1 à 16). Une question, la réponse en 2-3 lignes, la commande à montrer. Les explications sont dans les ADR et le [guide d'étude](k8s-study-guide.md) : ouvrir le lien si l'évaluateur creuse, ne pas réciter.

Avant la soutenance : `kubectl config current-context` doit afficher `bernstein-aks`. Garder un terminal avec `kubectl -n bernstein get pods -o wide -w` ouvert. Pour prouver qu'il n'y a pas d'erreur pendant une action, la lancer sous le test de requêtes continues : `tests/zero-downtime.sh --from both -- <commande>` ([ADR 0016](../adr/0016-zero-downtime-test.md)). Les lignes `@cluster` viennent d'un pod dans le cluster : elles ne dépendent pas du réseau de la salle. Juste avant, `DURATION=60 tests/zero-downtime.sh`, sans rien déployer, doit afficher `PASS`. Sinon c'est la connexion de la machine, pas le cluster (mesuré : jusqu'à 1,6 % de timeouts au repos depuis une connexion domestique) : changer de connexion.

## 0. Le jour J, dans l'ordre

**2 ou 3 jours avant** : mettre à jour l'image des nœuds, pour qu'aucune mise à jour ne soit en attente le jour J. Mesuré le 31/10 : 1,3 % d'échecs sur Poll et 0,25 % sur Result : Poll pendant 7 s, le temps que Redis change de nœud, et les 2 apps quelques secondes de timeouts quand un nœud redémarre. Les scores de Result se figent environ 30 s. À faire hors démo ([mise en place, partie 5](../setup/cluster-setup.md#5-create-the-aks-cluster-5-10-min)).

**15 minutes avant**, depuis le dossier du repo, sur `main` à jour :

```bash
az aks start -g bernstein-rg -n bernstein-aks                                   # 5 à 10 min
az aks get-credentials -g bernstein-rg -n bernstein-aks --overwrite-existing     # l'IP de l'API peut changer
REGISTRY=bernsteinacrmaeva.azurecr.io scripts/deploy.sh                         # remet la version de main, affiche les URL
tests/zero-downtime.sh --from both -- sh -c 'kubectl -n bernstein rollout restart deploy/poll deploy/result && kubectl -n bernstein rollout status deploy/poll && kubectl -n bernstein rollout status deploy/result'
kubectl -n bernstein get pods -o wide                                           # 7 pods 1/1, un Poll et un Result par nœud
DURATION=60 tests/zero-downtime.sh                                              # PASS, sinon changer de connexion
```

Le `rollout restart` sous le test ré-étale Poll et Result : après un `az aks start`, tous les pods sont sur le premier nœud prêt, et la démo du drain couperait ([`DEPLOY.md`, After `az aks start`](../../DEPLOY.md#after-az-aks-start)). Garder ouverts : `kubectl -n bernstein get pods -o wide -w`, et les 2 URL.

**Si l'évaluateur veut voir le déploiement depuis zéro** : vider le namespace (91 s mesurées ; les votes, le disque Postgres et les IP publiques partent avec), puis redéployer (55 s mesurées, les images sont déjà dans le registry). Donner les 2 nouvelles IP affichées à la fin.

```bash
kubectl delete namespace bernstein
REGISTRY=bernsteinacrmaeva.azurecr.io scripts/deploy.sh
```

**La mise à jour notée** : changer un fichier visible, par exemple le `<h3>` de `poll-application/poll/templates/index.html`, sans commit, puis `REGISTRY=bernsteinacrmaeva.azurecr.io tests/zero-downtime.sh --from both -- scripts/deploy.sh`. Mesuré depuis un clone du miroir : 1 min 17 s, 0 erreur sur 6260 requêtes ([`DEPLOY.md` partie 4](../../DEPLOY.md#4-update-the-app-with-zero-downtime)).

**Après** : `az aks stop -g bernstein-rg -n bernstein-aks`. Sinon, l'arrêt de nuit s'en charge à 23:00 ([ADR 0035](../adr/0035-nightly-stop.md)).

## La grille (15 critères, 32 points)

Le rapport de mi-parcours note ces 15 critères, et la soutenance finale reprend la même grille ([`SUBJECT.md`](../subject/SUBJECT.md#grading-rubric-mid-term-report)). Pour chacun : la réponse en quelques phrases, puis la commande à montrer. Les questions 1 à 16 plus bas détaillent ; celles marquées « hors grille » ne servent que si l'évaluateur creuse.

| Critère                                     | Points | Réponse                                                      |
| ------------------------------------------- | -----: | ------------------------------------------------------------ |
| Déploiement initial : l'app marche          |      4 | [G1](#g1-déploiement-initial--lapp-marche-4-points)          |
| Déploiement initial : registry Docker privé |      1 | [G2](#g2-déploiement-initial--registry-privé-1-point)        |
| Déploiement initial : données persistantes  |      2 | [G3](#g3-déploiement-initial--données-persistantes-2-points) |
| Redéploiement : mise à jour sans coupure    |      2 | [G4](#g4-redéploiement--mise-à-jour-sans-coupure-2-points)   |
| Auto-scaling                                |  **6** | [G5](#g5-auto-scaling-6-points)                              |
| Load balancers                              |  **4** | [G6](#g6-load-balancers-4-points)                            |
| Probes                                      |      2 | [G7](#g7-probes-2-points)                                    |
| Limites de ressources                       |      2 | [G8](#g8-limites-de-ressources-2-points)                     |
| Politiques d'affinité                       |      2 | [G9](#g9-politiques-daffinité-2-points)                      |
| Réplicas                                    |      1 | [G10](#g10-réplicas-1-point)                                 |
| Nombre de nœuds                             |      1 | [G11](#g11-nombre-de-nœuds-1-point)                          |
| Ports exposés                               |      1 | [G12](#g12-ports-exposés-1-point)                            |
| Restart policies                            |      1 | [G13](#g13-restart-policies-1-point)                         |
| Propreté et structure du dépôt              |      1 | [G14](#g14-propreté-et-structure-du-dépôt-1-point)           |
| Documentation                               |      2 | [G15](#g15-documentation-2-points)                           |

### G1. Déploiement initial : l'app marche (4 points)

L'évaluateur clone le dépôt, copie `k8s/secrets.env.example` en `k8s/secrets.env` et y met les 3 mots de passe de la base, se connecte à Azure, puis lance une seule commande. Le script construit les 3 images, les pousse dans son registry, déploie `k8s/` et affiche les 2 URL. Il vote sur Poll et voit le score bouger sur Result. Mesuré depuis un clone du miroir Epitech : 55 s sur un namespace vide, les images étant déjà dans le registry.

```bash
REGISTRY=<nom>.azurecr.io scripts/deploy.sh
kubectl -n bernstein get pods,svc   # 7 pods 1/1, 2 EXTERNAL-IP
```

Détails : section 0, [`DEPLOY.md`](../../DEPLOY.md), [ADR 0017](../adr/0017-deploy-script.md).

### G2. Déploiement initial : registry privé (1 point)

Azure Container Registry, offre Basic : elle n'a pas de pull anonyme, donc le registry est privé. Le cluster y est rattaché (`az aks update --attach-acr`) : l'identité des nœuds reçoit le rôle `AcrPull`. Il n'y a donc aucun `imagePullSecret` ni mot de passe dans le dépôt. On pousse après `az acr login` ; la CI se connecte sans secret, par OIDC (Q14).

```bash
az acr repository show-tags -n bernsteinacrmaeva --repository poll -o table   # nos tags git
curl -s -o /dev/null -w '%{http_code}\n' https://bernsteinacrmaeva.azurecr.io/v2/poll/tags/list   # 401 : refusé sans authentification
```

Détails : [ADR 0002](../adr/0002-acr-registry.md).

### G3. Déploiement initial : données persistantes (2 points)

Postgres est un StatefulSet. Ses données sont sur un PVC, `data-postgres-0` (1 Gi, un disque Azure). Le pod peut mourir : le StatefulSet le recrée avec le même nom et le même disque. Supprimer le StatefulSet ne supprime pas non plus le PVC (rétention `Retain` par défaut). Mesuré le 31/10 : `postgres-0` supprimé, recréé sur l'autre nœud en 29 s, votes intacts, 0 erreur sur Result. Redis, lui, est en mémoire : seuls les votes pas encore traités par le worker sont perdus s'il plante.

```bash
kubectl -n bernstein get pvc
kubectl -n bernstein exec postgres-0 -- psql -U postgres -d postgres -c 'SELECT vote, COUNT(*) FROM votes GROUP BY vote'
tests/zero-downtime.sh -- kubectl -n bernstein delete pod postgres-0
# relancer le SELECT : mêmes nombres
```

Détails : Q5, [ADR 0007](../adr/0007-postgres-statefulset.md).

### G4. Redéploiement : mise à jour sans coupure (2 points)

Le nouveau tag git change le template des pods, donc le Deployment crée un nouveau ReplicaSet. `maxSurge: 1` démarre un pod en plus. Il n'entre dans le Service qu'une fois sa readiness probe passée, et ne compte qu'après 5 s ready (`minReadySeconds`). `maxUnavailable: 0` : un ancien pod ne s'arrête qu'ensuite. À l'arrêt, le pod sort du Service, attend 5 s (`preStop`, le temps que chaque nœud arrête de lui envoyer du trafic), puis reçoit `SIGTERM` et finit ses requêtes en cours. Mesuré : 0 erreur sur 6260 requêtes depuis un clone du miroir, 0 sur 5875 le 31/10.

```bash
REGISTRY=bernsteinacrmaeva.azurecr.io tests/zero-downtime.sh --from both -- scripts/deploy.sh
```

Détails : section 0, Q7, Q11, [ADR 0012](../adr/0012-graceful-shutdown.md), [ADR 0016](../adr/0016-zero-downtime-test.md), [guide 9.2](k8s-study-guide.md#92-mise-à-jour-dune-image-le-test--on-change-le-code-).

### G5. Auto-scaling (6 points)

Un HPA sur Poll : de 2 à 6 pods, cible 70 % de la request CPU (35m sur 50m). metrics-server mesure le CPU ; le HPA recalcule toutes les 15 s (`ceil(pods × CPU actuel / cible)`). Il monte tout de suite et ne descend qu'après 5 minutes sans besoin. Mesuré : 2 → 6 pods en 2 minutes sous charge, retour à 2 environ 7 minutes après, 0 erreur sur 13 000 requêtes, drain compris.

Ce qu'on n'autoscale pas, et pourquoi :

- **Result** : chaque pod fait 1 requête par seconde à la base, quel que soit le nombre de visiteurs. Et ses WebSockets restent sur le pod où elles se sont ouvertes : un pod ajouté n'aurait que les nouveaux visiteurs.
- **Le worker** : un seul pod vide la file en quelques millisecondes par vote. Scaler sur la longueur de la file demanderait KEDA et des métriques qu'on n'a pas.
- **Redis et Postgres** : un seul pod, par conception (G10).
- **Les nœuds** (pas de cluster autoscaler) : 6 pods Poll tiennent sur un seul nœud même après un drain. Notre quota étudiant permet au plus un 3e nœud, qui coûterait plus sans régler les pods uniques de Redis et Postgres.

```bash
kubectl -n bernstein get hpa poll -w
```

Démo de charge : Q4. Détails : [ADR 0026](../adr/0026-poll-hpa.md), [guide 8 quater](k8s-study-guide.md#8-quater-k8shpayaml-ligne-par-ligne).

### G6. Load balancers (4 points)

Il y a deux niveaux de répartition.

1. **Internet → cluster** : Poll et Result ont chacun un Service `LoadBalancer`. AKS crée pour chacun une IP publique et une règle sur le Load Balancer Standard d'Azure. Il travaille en couche 4 (TCP), donc la WebSocket de Result passe sans réglage. Il répartit les connexions sur les nœuds, qui la reçoivent sur un NodePort, et une sonde de santé écarte les nœuds qui ne répondent plus.
2. **Nœud → pod** : le Service envoie chaque connexion à l'un des pods **ready** de l'app. Sur notre cluster, c'est Cilium qui le fait, en eBPF : il n'y a pas de `kube-proxy`.

`externalTrafficPolicy: Cluster` (le défaut) : n'importe quel nœud accepte le trafic, au prix d'un saut possible vers l'autre nœud et de l'IP du visiteur perdue. `Local` garderait l'IP, mais n'enverrait qu'aux nœuds qui ont un pod de l'app.

**Pas d'Ingress** : le sujet demande 2 apps joignables, et 2 IP y répondent directement, sans contrôleur de plus à installer ni à garder en vie pendant le test. En contrepartie : 2 IP facturées, pas de routage par chemin ni de TLS ([ADR 0022](../adr/0022-no-https.md)).

Mesuré le 31/10, pendant la mise à jour des nœuds : quelques secondes de timeouts quand un nœud redémarre. Notre hypothèse : le Load Balancer lui envoie encore des connexions jusqu'à ce que sa sonde le déclare mort.

```bash
kubectl -n bernstein get svc                          # 2 LoadBalancer avec IP publique, 2 ClusterIP
kubectl -n bernstein get endpointslices -l kubernetes.io/service-name=poll   # les IP des pods ready derrière poll
```

Détails : [ADR 0004](../adr/0004-public-access-loadbalancer.md), [guide 7](k8s-study-guide.md#le-service-public-loadbalancer).

### G7. Probes (2 points)

- **Liveness** : « le process est-il vivant ? ». Si elle échoue, le kubelet redémarre le conteneur.
- **Readiness** : « peut-il servir ? ». Si elle échoue, le pod sort du Service, sans redémarrer.
- **Poll et Result** : liveness sur `/healthz`, readiness sur `/readyz`.
  - La readiness de Poll vérifie Redis (`PING`). Celle de Result vérifie que la base a répondu au moins une fois.
  - Leur liveness ne dépend jamais d'une dépendance : une panne de Redis ou de Postgres ne doit pas redémarrer les 2 pods pour rien.
- **Le worker** a sa liveness sur `/readyz` : une connexion Postgres morte le bloquait sans le tuer, et la liveness le relance.
- **Redis et Postgres** : `redis-cli ping` et `pg_isready`.
- **Timings** : readiness toutes les 5 s, sortie du Service après 2 échecs (10 s au plus) ; liveness toutes les 10 s, redémarrage après 3 échecs.

Détails : Q6, [ADR 0008](../adr/0008-result-deployment.md), [ADR 0010](../adr/0010-worker-deployment.md), [ADR 0011](../adr/0011-poll-deployment.md).

### G8. Limites de ressources (2 points)

Chaque conteneur a des `requests` et des `limits`, mesurées sous charge.

- **Requests** : ce que le scheduler réserve sur un nœud pour y placer le pod. C'est aussi la base du pourcentage du HPA.
- **Limite CPU** : au-delà, le conteneur est **freiné** (throttling), jamais tué.
- **Limite mémoire** : au-delà, il est **tué** (`OOMKilled`).
- **Redis** : 50m / 64Mi demandés, 250m / 128Mi au plus, et `maxmemory 100mb` : plein, il refuse les nouveaux votes au lieu de se faire tuer.
- **Le dimensionnement** : tout tient sur un seul nœud, ce dont un drain a besoin.

Détails : Q3, [ADR 0018](../adr/0018-resource-requests-and-limits.md).

### G9. Politiques d'affinité (2 points)

Poll et Result ont une **anti-affinity _preferred_** par nœud (`topologyKey: kubernetes.io/hostname`) : un pod par nœud, pour qu'un drain ou une panne de nœud en laisse toujours un qui sert.

- **Preferred et pas required** : avec 2 nœuds, le pod de surge d'un rollout (le 3e) doit pouvoir se placer quelque part. _Required_ bloquerait rollouts et drains.
- **`matchLabelKeys: pod-template-hash`** : seuls les pods de la même version comptent, donc les anciens pods d'un rollout ne gênent pas le placement des nouveaux.
- **Limite** : l'affinité ne joue qu'au placement et ne déplace jamais un pod. Après `az aks start`, tout est sur un nœud, et on ré-étale avec `rollout restart` (section 0).
- **Pas de node affinity** : nos 2 nœuds sont identiques.

```bash
kubectl -n bernstein get pods -o wide   # un Poll et un Result par nœud
```

Détails : Q1, [ADR 0013](../adr/0013-pod-anti-affinity.md).

### G10. Réplicas (1 point)

| App      | Réplicas | Pourquoi                                                                                                   |
| -------- | -------- | ---------------------------------------------------------------------------------------------------------- |
| Poll     | 2 à 6    | 2 au minimum, pour qu'un rollout ou un drain laisse toujours un pod qui sert ; le HPA monte jusqu'à 6 (G5) |
| Result   | 2        | même minimum ; pas d'HPA (G5)                                                                              |
| Worker   | 1        | vide la file en millisecondes ; 2 marcheraient (`BLPOP` atomique), mais doubleraient la mémoire de la JVM  |
| Redis    | 1        | file en mémoire : 2 pods seraient 2 files séparées, la réplication demanderait Sentinel                    |
| Postgres | 1        | répliquer demande un opérateur (CloudNativePG) ; on garde 1 pod, son disque, et on explique la limite      |

Les PDB (`minAvailable: 1`) protègent Poll et Result pendant un drain. Détails : [ADR 0007](../adr/0007-postgres-statefulset.md) à [ADR 0011](../adr/0011-poll-deployment.md), [ADR 0014](../adr/0014-pod-disruption-budgets.md).

### G11. Nombre de nœuds (1 point)

2 nœuds `Standard_B2s_v2` (2 vCPU, 8 Gio chacun).

- **2, c'est le minimum** pour survivre à un drain ou à la perte d'une VM sans coupure : un pod Poll et un pod Result de chaque côté.
- **Tout tient sur un seul nœud pendant un drain** : mesuré, 1352m de requests CPU sur 1900m disponibles.
- **Pourquoi pas 3** : le quota de l'abonnement étudiant est de 6 vCPU, donc au plus 3 nœuds. Ça coûterait plus, et Redis et Postgres resteraient à un seul pod.
- **Le coût** : environ 0,2 € par heure allumé, 0,47 € par jour éteint.

Détails : Q13, [ADR 0001](../adr/0001-aks-cluster.md).

### G12. Ports exposés (1 point)

- **Seul le port 80 de Poll et de Result est public**, par le Load Balancer.
- **Redis (6379) et Postgres (5432)** sont en `ClusterIP`, injoignables de l'extérieur. Les NetworkPolicies limitent en plus qui leur parle : Poll et le worker vers Redis, le worker et Result vers Postgres.
- **Le worker** écoute sur 80 seulement pour ses probes, sans Service.
- **`containerPort`** ne fait que documenter et nommer le port (`http`), réutilisé par le Service.
- **Le port 80 sans root** : les apps tournent sans root et écoutent quand même sur 80, grâce au sysctl `net.ipv4.ip_unprivileged_port_start=0`.
- **Les NodePorts** (`3xxxx`) existent sur les nœuds, mais les nœuds n'ont pas d'IP publique.
- **Mesuré depuis internet** : 80 répond ; 22, 443, 5432 et 6379 sont fermés.

```bash
kubectl -n bernstein get svc
kubectl -n bernstein get networkpolicy
```

Détails : Q9, [ADR 0004](../adr/0004-public-access-loadbalancer.md), [ADR 0023](../adr/0023-security-posture.md), [ADR 0025](../adr/0025-network-policies.md).

### G13. Restart policies (1 point)

Tous les pods gardent la politique par défaut, `restartPolicy: Always` : c'est d'ailleurs la seule acceptée dans un Deployment. `OnFailure` et `Never` sont pour les Jobs, dont la tâche se termine ; nos 5 apps tournent en continu.

- **Un conteneur qui s'arrête** est relancé dans son pod par le kubelet : `RESTARTS` augmente. Le délai entre deux essais double à chaque fois (10 s, 20 s, 40 s… jusqu'à 5 minutes, c'est le `CrashLoopBackOff`), et revient à zéro après 10 minutes sans problème.
- **Un pod qui disparaît** (supprimé, évincé) est remplacé par son ReplicaSet ou son StatefulSet.
- **La liveness complète la politique** : un process bloqué ne s'arrête pas tout seul ; elle le tue, puis `Always` le relance.
- **Vu le 31/10** : après la suppression de `postgres-0`, le worker a redémarré une fois et a repris les votes.

Détails : [ADR 0037](../adr/0037-restart-policy.md), [guide 9.4](k8s-study-guide.md#94-un-pod-plante-ou-est-supprimé).

### G14. Propreté et structure du dépôt (1 point)

Un dossier par rôle :

- `poll-application/` : le code fourni et ses Dockerfiles ;
- `k8s/` : un fichier par app, plus un par type de règle (PDB, HPA, NetworkPolicies) ;
- `scripts/` : le déploiement ;
- `tests/` : le test sans coupure ;
- `doc/` : les ADR, la mise en place du cluster, la soutenance, le sujet.

Les mots de passe ne sont jamais commités (`k8s/secrets.env` est ignoré par git, seul `.example` l'est). Commits conventionnels, une PR par ticket, et la CI vérifie le format et les manifests sur chaque PR.

```bash
git log --oneline | head
```

Détails : l'arborescence du [`README.md`](../../README.md), [`CONTRIBUTING.md`](../../CONTRIBUTING.md).

### G15. Documentation (2 points)

- [`README.md`](../../README.md) : ce que fait le projet, le schéma, et le démarrage rapide en quelques commandes.
- [`DEPLOY.md`](../../DEPLOY.md) : le guide de l'opérateur (déployer, mettre à jour, revenir en arrière, arrêter, dépanner).
- [`doc/setup/cluster-setup.md`](../setup/cluster-setup.md) : créer le cluster et le registry à partir de rien.
- [`doc/adr/`](../adr/README.md) : 36 décisions, chacune avec ses raisons, ses limites, ses alternatives rejetées, et un index par question.

Chaque fait tiré d'une doc a sa source, et chaque chiffre a été mesuré sur notre cluster.

## 1. « Que se passe-t-il si on fait `kubectl drain` sur ce nœud ? »

Le nœud passe en `cordon`, ses pods sont évincés et recréés sur l'autre nœud. Poll et Result tiennent : 1 pod par nœud (anti-affinity) et un PDB `minAvailable: 1`. Mesuré : **0 erreur** sur 2221 requêtes. Même le nœud de `postgres-0` donne **0 erreur** (mesuré le 29/10) : seuls les scores de Result se figent 27 s, le temps que le disque change de nœud. Avant notre correctif de Result, ce cas faisait 47 échecs sur 39 s ([Q8](#8--et-si-redis-postgres-ou-le-worker-tombe--)).

```bash
kubectl -n bernstein get pods -o wide   # quel pod sur quel nœud ; pour la démo, prendre le nœud sans postgres-0
tests/zero-downtime.sh -- kubectl drain <nœud> --ignore-daemonsets --delete-emptydir-data
kubectl uncordon <nœud>                 # le nœud reçoit de nouveau des pods (les anciens ne reviennent pas)
```

**Avant la démo, vérifier la répartition.** Après `az aks start` (ou un pod tué), les pods d'une app peuvent être sur le même nœud : l'anti-affinity n'est que préférée. Vu après chaque `start` (27/10 et 28/10) : les 7 pods sur un seul nœud. Pour vérifier, puis répartir Poll et Result (mesuré : 0 erreur sur 1205 requêtes, puis sur 1280 depuis la machine et 2765 depuis le cluster) :

```bash
kubectl -n bernstein get pods -l 'app.kubernetes.io/name in (poll,result)' -o wide
tests/zero-downtime.sh --from both -- sh -c 'kubectl -n bernstein rollout restart deploy/poll deploy/result && kubectl -n bernstein rollout status deploy/poll deploy/result'
```

Détails : [ADR 0014](../adr/0014-pod-disruption-budgets.md), [ADR 0013](../adr/0013-pod-anti-affinity.md), [guide 9.5](k8s-study-guide.md#95-kubectl-drain-dun-nœud-question-classique).

## 2. « On tue un pod, que se passe-t-il ? »

Son contrôleur en recrée un : le ReplicaSet, ou le StatefulSet pour `postgres-0`, qui revient avec le même nom et le même disque. Le pod supprimé sort du Service, attend 5 s (`preStop`), puis reçoit `SIGTERM` : aucune requête coupée. Mesuré : 1 pod Poll et 1 pod Result supprimés, **0 erreur** sur 556 requêtes, remplaçants prêts en moins de 25 s. Exception : Redis n'a qu'un pod, donc Poll est non ready ~4 s et les votes en file sont perdus.

```bash
tests/zero-downtime.sh -- kubectl -n bernstein delete pod <pod poll ou result>
```

Un conteneur qui plante (process qui s'arrête) est redémarré dans le même pod : `RESTARTS` augmente, puis `CrashLoopBackOff` s'il plante en boucle. Détails : [guide 9.4](k8s-study-guide.md#94-un-pod-plante-ou-est-supprimé), [ADR 0012](../adr/0012-graceful-shutdown.md).

## 3. « Comment limiter le CPU (ou la mémoire) de Redis ? »

C'est déjà fait : `requests` 50m / 64Mi, `limits` 250m / 128Mi. Au-dessus de 250m, Redis est ralenti (throttling), pas tué ; au-dessus de 128Mi, il est tué (`OOMKilled`). Pour ne jamais y arriver, Redis plafonne sa mémoire à 100 Mo (`--maxmemory 100mb --maxmemory-policy noeviction`) : file pleine, les nouveaux votes sont refusés (HTTP 500), rien n'est effacé.

```bash
kubectl -n bernstein get deploy redis -o jsonpath='{.spec.template.spec.containers[0].resources}'; echo
kubectl -n bernstein top pod -l app.kubernetes.io/name=redis
```

Pour changer : `resources` dans `k8s/redis.yaml`, puis `REGISTRY=<nom>.azurecr.io scripts/deploy.sh` (rien n'est reconstruit : le code n'a pas changé). C'est un rolling update de Redis ; mesuré sous charge : 0 erreur, et les 1755 votes envoyés pendant la bascule sont enregistrés. Détails : [ADR 0018](../adr/0018-resource-requests-and-limits.md).

## 4. « Comment autoscaler Poll ? »

C'est en place : un HPA sur le CPU, **2 à 6 pods**, cible 70 % de la request (35m sur 50m). metrics-server fournit le CPU. Montée immédiate, descente après 5 minutes. Mesuré : 2 → 6 pods en 2 minutes sous charge, retour à 2 environ 7 minutes après, **0 erreur sur 13 000 requêtes**. Au-delà de 6, il faudrait un 3e nœud (cluster autoscaler) : les 2 nœuds ont un CPU fixe.

```bash
kubectl -n bernstein get hpa poll -w   # TARGETS (CPU / cible) et REPLICAS en direct
kubectl -n bernstein top pods -l app.kubernetes.io/name=poll
```

Charge pour la démo, depuis un autre namespace (nos NetworkPolicies bloquent un client dans `bernstein`) :

```bash
kubectl create namespace load-test
kubectl -n load-test create deployment load --image=busybox:1.37 --replicas=4 -- sh -c 'while true; do wget -q -O /dev/null http://poll.bernstein/ || sleep 1; done'
kubectl delete namespace load-test   # fin de la charge ; Poll revient à 2 environ 5 minutes plus tard
```

Détails : [ADR 0026](../adr/0026-poll-hpa.md), [guide 8 quater](k8s-study-guide.md#8-quater-k8shpayaml-ligne-par-ligne).

## 5. « Sauvegarde et failover de la base ? »

Sauvegarde : un `pg_dump` manuel vers la machine de l'opérateur, sans automatisation. Restauration testée : 6195 votes, même nombre de lignes et même checksum. Failover : aucun, 1 seul replica. Si le pod meurt, le StatefulSet le recrée avec le même disque (données gardées), mais les scores de Result se figent entre-temps (27 s pendant un drain), sans erreur : la page charge toujours. En production : un opérateur comme CloudNativePG (primaire + standbys, bascule automatique) ou Azure Database for PostgreSQL (sauvegardes automatiques, restauration à un instant donné).

```bash
kubectl -n bernstein exec postgres-0 -- pg_dump -U postgres -d postgres --clean --if-exists > ~/votes-backup.sql
```

Détails : [ADR 0019](../adr/0019-postgres-backup.md), [ADR 0007](../adr/0007-postgres-statefulset.md), [`DEPLOY.md` partie 8](../../DEPLOY.md#8-back-up-and-restore-the-votes).

## 6. « Comment savez-vous que l'app va bien ? Et si un pod casse ? »

Les probes : liveness sur `/healthz` (le process répond), readiness sur `/readyz` (sa dépendance répond). Pas de monitoring centralisé ni d'alerte (coût, et un agent de plus sur des nœuds déjà pleins) : on regarde avec `kubectl`. Pod cassé : lire son `STATUS`, puis `describe` (les events), puis `logs`. Après un rollout ou un pod tué, quelques `Readiness probe failed` sur les pods qui démarrent ou s'arrêtent sont normaux.

```bash
kubectl -n bernstein get pods -o wide                      # READY, RESTARTS, nœud
kubectl -n bernstein get events --sort-by=.lastTimestamp   # probes en échec, redémarrages
kubectl -n bernstein logs <pod> --previous                 # le run qui a planté
kubectl -n bernstein top pods
```

Détails : [ADR 0024](../adr/0024-observability.md), [`DEPLOY.md`, Debug a broken pod](../../DEPLOY.md#debug-a-broken-pod).

## 7. « Comment revenir en arrière ? »

Deux façons, toutes deux en rolling update. Rapide : `rollout undo` remet le ReplicaSet précédent, gardé avec 0 pod ; le prochain deploy l'écrase. Depuis le registry : redéployer un tag connu d'une app (`POLL_TAG=`), rien n'est reconstruit et les autres apps gardent leur tag. Mesuré : 0 erreur sur 820 requêtes (`undo`), 0 sur 1017 (`TAG=`), 0 sur 1270 depuis la machine et 2865 depuis le cluster (`POLL_TAG=`, seul Poll redémarre).

```bash
kubectl -n bernstein rollout history deploy/poll
tests/zero-downtime.sh -- sh -c 'kubectl -n bernstein rollout undo deploy/poll && kubectl -n bernstein rollout status deploy/poll'
kubectl -n bernstein get deploy -o wide                            # le tag de chaque app
REGISTRY=<nom>.azurecr.io POLL_TAG=<bon tag> scripts/deploy.sh
```

Détails : [`DEPLOY.md` partie 5](../../DEPLOY.md#5-roll-back), [ADR 0005](../adr/0005-image-tags-git-sha.md).

## 8. « Et si Redis, Postgres ou le worker tombe ? »

- **Redis :** Poll non ready (page indisponible), le worker redémarre et attend. Result marche, scores figés. Les votes en file sont perdus.
- **Postgres :** Poll marche, les votes s'empilent dans Redis (100 Mo au plus). Result reste en ligne : la page charge, les scores se figent, et il réessaie toutes les 6 s (5 s de délai, puis 1 s de pause). Le worker devient non ready. Mesuré : 0 erreur sur Result, Postgres revenu en 11 s (même nœud) ou 27 s (autre nœud). Avant notre correctif du code fourni, `server.js` s'arrêtait (`process.exit(1)`) et Result tombait 13 à 43 s ([ADR 0008](../adr/0008-result-deployment.md)). Au retour, le worker repart seul en ~1 min : aucun vote perdu.
- **Worker :** tout marche, les scores sont figés jusqu'à son retour, puis la file se vide.

Démo, worker arrêté puis relancé :

```bash
kubectl -n bernstein scale deploy/worker --replicas=0
# voter sur la page Poll, puis :
kubectl -n bernstein exec deploy/redis -- redis-cli LLEN votes   # les votes attendent (3 dans notre test)
kubectl -n bernstein scale deploy/worker --replicas=1            # la file retombe à 0, Result se met à jour
```

Détails : [guide 9.6](k8s-study-guide.md#96-une-dépendance-tombe), [ADR 0009](../adr/0009-redis-queue.md).

## 9. « Qui peut parler à Postgres ? »

Seuls le worker et Result, sur le port 5432, chacun avec son utilisateur : `result_reader` peut seulement lire les votes, `worker_writer` lire, ajouter et modifier. Aucun ne connaît le mot de passe du superutilisateur `postgres`. Mesuré : depuis Result, `INSERT` et `DELETE` donnent `permission denied for table votes`. Tout le namespace est fermé, en entrée et en sortie, puis chaque flux de l'app est ouvert : DNS, internet vers poll et result (port 80), poll vers redis, worker vers redis et postgres, result vers postgres. Cilium applique les règles. Mesuré : depuis un pod Poll, Redis répond ; Postgres et internet partent en timeout.

```bash
kubectl -n bernstein get networkpolicy
kubectl -n bernstein exec deploy/poll -- python -c "import socket; socket.create_connection(('redis', 6379), 3); print('redis ok')"
kubectl -n bernstein exec deploy/poll -- python -c "import socket; socket.create_connection(('postgres', 5432), 3)"   # TimeoutError
kubectl -n bernstein exec postgres-0 -- psql -U postgres -c '\dp votes'   # result_reader=r, worker_writer=arw
```

Détails : [ADR 0025](../adr/0025-network-policies.md), [guide 8 ter](k8s-study-guide.md#8-ter-k8snetwork-policiesyaml-ligne-par-ligne).

## 10. « Comment empêchez-vous un pod de tourner en root ? »

Le namespace impose le niveau `restricted` des Pod Security Standards (label `pod-security.kubernetes.io/enforce: restricted`) : l'API server refuse tout pod root, avec élévation de privilèges, avec des capabilities en plus (sauf `NET_BIND_SERVICE`) ou sans profil seccomp. Nos 5 pods respectent ces règles. Ils n'ont en plus ni jeton d'API ni système de fichiers inscriptible. Mesuré : un pod `runAsUser: 0` est refusé, avec la liste des règles violées.

```bash
kubectl -n bernstein run root-test --image=busybox:1.37 --restart=Never -- sleep 5
# Error from server (Forbidden): pods "root-test" is forbidden: violates PodSecurity "restricted:latest": ...
kubectl -n bernstein debug <pod> -it --image=busybox:1.37 --profile=restricted   # le debug passe, avec ce profil
```

Détails : [ADR 0027](../adr/0027-pod-security-standards.md), [guide partie 3](k8s-study-guide.md#3-k8snamespaceyaml-ligne-par-ligne).

## 11. « Et si la nouvelle version ne démarre pas ? »

Rien ne coupe. Avec `maxUnavailable: 0`, un ancien pod ne s'arrête qu'une fois un nouveau ready : le nouveau ne l'est jamais, donc les 2 anciens servent toujours. Après 2 min sans progrès (`progressDeadlineSeconds: 120`), le rollout passe en échec ; `deploy.sh` s'arrête et affiche les commandes de retour arrière. Pas de rollback automatique : rien ne presse, on lit d'abord la cause. Mesuré : tag inexistant, crash au démarrage, Redis injoignable : 0 erreur dans le cluster.

```bash
kubectl -n bernstein get pods                      # le nouveau : ImagePullBackOff, CrashLoopBackOff ou 0/1
kubectl -n bernstein describe pod <nouveau pod>    # la cause, dans Events
kubectl -n bernstein rollout undo deploy/poll      # retour à la version précédente
```

Détails : [guide 9.2 bis](k8s-study-guide.md#92-bis-une-mise-à-jour-cassée-la-nouvelle-version-ne-démarre-pas), [`DEPLOY.md`, When an update fails](../../DEPLOY.md#when-an-update-fails).

## 12. « Et si le réseau de la salle fait échouer le test ? »

On lance le test avec `--from both` : les mêmes requêtes partent de la machine et d'un pod dans le cluster, avec un résumé par source. Le pod ne traverse pas le réseau de la salle. Erreurs seulement sur `poll` et `result` : c'est le réseau ou le load balancer Azure. Erreurs aussi sur `poll@cluster` : c'est le cluster. Mesuré pendant un `rollout restart` : 0 erreur sur 994 requêtes depuis la machine et sur 2375 depuis le pod.

```bash
tests/zero-downtime.sh --from both -- sh -c 'kubectl -n bernstein rollout restart deploy/poll deploy/result && kubectl -n bernstein rollout status deploy/poll deploy/result'
```

Détails : [ADR 0016](../adr/0016-zero-downtime-test.md), [`DEPLOY.md` partie 4](../../DEPLOY.md#4-update-the-app-with-zero-downtime).

## 13. « Combien ça coûte, et comment limitez-vous ? »

Mesuré dans Cost Management : 5,66 € du 19 au 28 octobre, sur un crédit étudiant de 88 €. Arrêté, le cluster coûte 0,47 € par jour : les 3 IP publiques (0,32 €), le registry (0,15 €) et le disque Postgres. Allumé, on ajoute environ 0,2 € par heure pour les 2 nœuds et leurs disques OS. Le plan Free d'AKS ne facture pas le control plane, et le load balancer est gratuit dans l'offre étudiante. On arrête donc le cluster dès qu'on ne s'en sert pas, et un workflow GitHub Actions l'arrête chaque soir à 23:00 s'il tourne encore ([ADR 0035](../adr/0035-nightly-stop.md)). Prévision jusqu'à la soutenance : environ 12 € au total, 14 % du crédit.

```bash
az aks stop -g bernstein-rg -n bernstein-aks
az aks show -g bernstein-rg -n bernstein-aks --query powerState.code -o tsv   # Stopped
```

Détails : [ADR 0001, Cost](../adr/0001-aks-cluster.md#cost), [`DEPLOY.md` partie 6](../../DEPLOY.md#6-stop-or-delete-cost).

## 14. « Comment la CI se connecte au registry privé, sans secret ? » (hors grille)

Par OIDC, sans aucun mot de passe dans GitHub. Pour chaque job, GitHub signe un token qui dit « dépôt `Nexlein/Bernstein`, branche `main` » (ou « pull request »), avec les ID du compte et du dépôt : un nouveau dépôt du même nom n'aurait pas les mêmes ID, donc aucun accès. Entra ID lui fait confiance grâce à une federated credential de l'app `bernstein-github-ci`, et rend un token Azure qui expire avec le job. Cette app n'a que deux rôles : `AcrPush` sur le registry, et sur le cluster un rôle custom qui ne peut que le lire et l'arrêter, pour l'arrêt de nuit. Elle ne peut ni déployer, ni modifier, ni supprimer quoi que ce soit. Les 4 secrets GitHub ne sont que des identifiants (client, tenant, subscription, nom du registry) : volés, ils ne donnent accès à rien. Un fork ou le miroir Epitech ne reçoit ni les secrets ni le token, donc le job y est sauté. Sur `main`, une fois les tests passés, la même connexion sert à pousser les nouvelles images, avec les tags que `deploy.sh` déploie ([ADR 0034](../adr/0034-ci-publish-images.md)) : après un merge, le déploiement ne reconstruit rien.

```bash
az ad app federated-credential list --id <AZURE_CLIENT_ID> --query '[].subject'   # repo:Nexlein@183351649/Bernstein@1418620429:… main et pull_request
```

Détails : [ADR 0032](../adr/0032-ci-registry-oidc.md), [mise en place](../setup/cluster-setup.md#8-build-push-and-deploy).

## 15. « Vos images ont-elles des failles connues ? » (hors grille)

La CI scanne les 5 images avec Trivy à chaque push et chaque PR : nos 3 images, plus Postgres et Redis au digest qu'on déploie. Elle échoue sur une faille `CRITICAL` qui a un correctif, puisqu'il suffit alors de monter de version. Les `HIGH` et les `CRITICAL` sans correctif sont seulement affichées dans le résumé du job : les bloquer laisserait la CI rouge sans rien à corriger. Premier scan : aucune faille bloquante dans nos images ni dans Redis. Postgres en a 3, et la dernière image officielle est déjà la nôtre. On les accepte dans `.trivyignore.yaml`, chacune avec sa raison : 2 dans `gosu`, qui ne tourne que si le conteneur démarre en root (le nôtre tourne en UID 70), et 1 qui expire le 30 novembre, le temps que l'image officielle soit reconstruite. On utilise le binaire Trivy vérifié par checksum, pas l'action GitHub : ses tags ont été piratés en mars 2026.

```bash
trivy image --severity CRITICAL --ignore-unfixed --ignorefile .trivyignore.yaml postgres:18.6-alpine
```

Détails : [ADR 0033](../adr/0033-ci-image-scan.md), [ADR 0023](../adr/0023-security-posture.md).

## 16. « Comment savez-vous que ça marche ? » (hors grille)

On teste notre déploiement, pas le code fourni : l'app arrive sans tests, et c'est le déploiement qui est noté. Chaque PR passe 7 vérifications en CI. Les plus parlantes : la stack Compose avec un vote de bout en bout, et un vrai cluster Kubernetes 1.36.4 (kind) où l'on déploie `k8s/`, vote, puis fait un rollout et un drain sous `tests/zero-downtime.sh`, avec 0 erreur exigée. Sur AKS, on a mesuré à la main ce que kind ne couvre pas : 0 erreur sur 975 et 1996 requêtes pendant un rollout, 0 sur 2221 pendant un drain. Les coupures mesurées venaient de Postgres, qui n'a qu'un réplica : Result tombait 39 s quand on drainait le nœud de Postgres. On a corrigé Result pour qu'il se reconnecte au lieu de s'arrêter : le même drain donne maintenant 0 erreur. Chaque test dit aussi ce qu'il ne prouve pas.

Détails : [`CONTRIBUTING.md`, Tests](../../CONTRIBUTING.md#tests), [ADR 0031](../adr/0031-ci-kind-e2e.md).
