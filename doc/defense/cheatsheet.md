# Antisèche soutenance : les questions en direct

Une question, la réponse en 2-3 lignes, la commande à montrer. Les explications sont dans les ADR et le [guide d'étude](k8s-study-guide.md) : ouvrir le lien si l'évaluateur creuse, ne pas réciter.

Avant la soutenance : `kubectl config current-context` doit afficher `bernstein-aks`. Garder un terminal avec `kubectl -n bernstein get pods -o wide -w` ouvert. Pour prouver qu'il n'y a pas d'erreur pendant une action, la lancer sous le test de requêtes continues : `tests/zero-downtime.sh --from both -- <commande>` ([ADR 0016](../adr/0016-zero-downtime-test.md)). Les lignes `@cluster` viennent d'un pod dans le cluster : elles ne dépendent pas du réseau de la salle. Juste avant, `DURATION=60 tests/zero-downtime.sh`, sans rien déployer, doit afficher `PASS`. Sinon c'est la connexion de la machine, pas le cluster (mesuré : jusqu'à 1,6 % de timeouts au repos depuis une connexion domestique) : changer de connexion.

## 1. « Que se passe-t-il si on fait `kubectl drain` sur ce nœud ? »

Le nœud passe en `cordon`, ses pods sont évincés et recréés sur l'autre nœud. Poll et Result tiennent : 1 pod par nœud (anti-affinity) et un PDB `minAvailable: 1`. Mesuré : **0 erreur** sur 2221 requêtes. Limite : si le nœud porte `postgres-0`, Result échoue le temps que le disque change de nœud (**47 échecs sur 39 s**).

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

Sauvegarde : un `pg_dump` manuel vers la machine de l'opérateur, sans automatisation. Restauration testée : 6195 votes, même nombre de lignes et même checksum. Failover : aucun, 1 seul replica. Si le pod meurt, le StatefulSet le recrée avec le même disque (données gardées), mais Result est indisponible entre-temps (39 s pendant un drain). En production : un opérateur comme CloudNativePG (primaire + standbys, bascule automatique) ou Azure Database for PostgreSQL (sauvegardes automatiques, restauration à un instant donné).

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
- **Postgres :** Poll marche, les votes s'empilent dans Redis (100 Mo au plus). Le worker et Result sont non ready. Au retour, le worker repart seul en ~1 min : aucun vote perdu.
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

Mesuré dans Cost Management : 5,66 € du 19 au 28 octobre, sur un crédit étudiant de 88 €. Arrêté, le cluster coûte 0,47 € par jour : les 3 IP publiques (0,32 €), le registry (0,15 €) et le disque Postgres. Allumé, on ajoute environ 0,2 € par heure pour les 2 nœuds et leurs disques OS. Le plan Free d'AKS ne facture pas le control plane, et le load balancer est gratuit dans l'offre étudiante. On arrête donc le cluster dès qu'on ne s'en sert pas. Prévision jusqu'à la soutenance : environ 12 € au total, 14 % du crédit.

```bash
az aks stop -g bernstein-rg -n bernstein-aks
az aks show -g bernstein-rg -n bernstein-aks --query powerState.code -o tsv   # Stopped
```

Détails : [ADR 0001, Cost](../adr/0001-aks-cluster.md#cost), [`DEPLOY.md` partie 6](../../DEPLOY.md#6-stop-or-delete-cost).
