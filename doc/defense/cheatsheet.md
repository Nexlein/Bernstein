# Antisèche soutenance : les questions en direct

Une question, la réponse en 2-3 lignes, la commande à montrer. Les explications sont dans les ADR et le [guide d'étude](k8s-study-guide.md) : ouvrir le lien si l'évaluateur creuse, ne pas réciter.

Avant la soutenance : `kubectl config current-context` doit afficher `bernstein-aks`. Garder un terminal avec `kubectl -n bernstein get pods -o wide -w` ouvert. Pour prouver qu'il n'y a pas d'erreur pendant une action, la lancer sous le test de requêtes continues : `tests/zero-downtime.sh -- <commande>` ([ADR 0016](../adr/0016-zero-downtime-test.md)).

## 1. « Que se passe-t-il si on fait `kubectl drain` sur ce nœud ? »

Le nœud passe en `cordon`, ses pods sont évincés et recréés sur l'autre nœud. Poll et Result tiennent : 1 pod par nœud (anti-affinity) et un PDB `minAvailable: 1`. Mesuré : **0 erreur** sur 2221 requêtes. Limite : si le nœud porte `postgres-0`, Result échoue le temps que le disque change de nœud (**47 échecs sur 39 s**).

```bash
kubectl -n bernstein get pods -o wide   # quel pod sur quel nœud ; pour la démo, prendre le nœud sans postgres-0
tests/zero-downtime.sh -- kubectl drain <nœud> --ignore-daemonsets --delete-emptydir-data
kubectl uncordon <nœud>                 # le nœud reçoit de nouveau des pods (les anciens ne reviennent pas)
```

**Avant la démo, vérifier la répartition.** Après `az aks start` (ou un pod tué), les pods d'une app peuvent être sur le même nœud : l'anti-affinity n'est que préférée. Vu le 27/10 : les 7 pods sur un seul nœud après un `start`. Pour répartir Poll et Result (mesuré : 0 erreur sur 1205 requêtes) :

```bash
tests/zero-downtime.sh -- sh -c 'kubectl -n bernstein rollout restart deploy/poll deploy/result && kubectl -n bernstein rollout status deploy/poll deploy/result'
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

Pour changer : `resources` dans `k8s/redis.yaml`, puis redéployer sans rebuild (`REGISTRY=<nom>.azurecr.io TAG=<tag actuel> scripts/deploy.sh`). C'est un rolling update de Redis ; mesuré sous charge : 0 erreur, et les 1755 votes envoyés pendant la bascule sont enregistrés. Détails : [ADR 0018](../adr/0018-resource-requests-and-limits.md).

## 4. « Comment autoscaler Poll ? »

Pas en place aujourd'hui (#33). Ce serait un HorizontalPodAutoscaler sur le CPU : metrics-server tourne déjà dans AKS. Le pourcentage se calcule sur `requests.cpu` (50m pour Poll ; 100m mesurés sous charge, donc 200 %). La vraie limite est la place sur les nœuds : les requests font déjà 1662m, presque un nœud entier (1900m). Au-delà, il faut un 3e nœud (cluster autoscaler ; 3 nœuds au maximum avec le quota de 6 vCPU). **Non mesuré** : pas de test de charge avec un HPA.

```bash
kubectl -n bernstein autoscale deploy/poll --min=2 --max=4 --cpu=70% --dry-run=server -o yaml   # l'objet, sans le créer
kubectl -n bernstein scale deploy/poll --replicas=4   # à la main ; le prochain deploy remet 2
```

Détails : [guide 9.7](k8s-study-guide.md#97-monter-en-charge-scale), [ADR 0018](../adr/0018-resource-requests-and-limits.md).

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

Deux façons, toutes deux en rolling update. Rapide : `rollout undo` remet le ReplicaSet précédent, gardé avec 0 pod ; le prochain deploy l'écrase. Durable : redéployer un tag connu, rien n'est reconstruit. Mesuré : 0 erreur sur 820 requêtes (`undo`), 0 sur 1017 (`TAG=`).

```bash
kubectl -n bernstein rollout history deploy/poll
tests/zero-downtime.sh -- sh -c 'kubectl -n bernstein rollout undo deploy/poll && kubectl -n bernstein rollout status deploy/poll'
REGISTRY=<nom>.azurecr.io TAG=<bon tag> scripts/deploy.sh
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

Seuls le worker et Result, sur le port 5432. Tout le namespace est fermé, en entrée et en sortie, puis chaque flux de l'app est ouvert : DNS, internet vers poll et result (port 80), poll vers redis, worker vers redis et postgres, result vers postgres. Cilium applique les règles. Mesuré : depuis un pod Poll, Redis répond ; Postgres et internet partent en timeout.

```bash
kubectl -n bernstein get networkpolicy
kubectl -n bernstein exec deploy/poll -- python -c "import socket; socket.create_connection(('redis', 6379), 3); print('redis ok')"
kubectl -n bernstein exec deploy/poll -- python -c "import socket; socket.create_connection(('postgres', 5432), 3)"   # TimeoutError
```

Détails : [ADR 0025](../adr/0025-network-policies.md), [guide 8 ter](k8s-study-guide.md#8-ter-k8snetwork-policiesyaml-ligne-par-ligne).
