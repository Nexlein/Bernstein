# Guide d'étude Kubernetes (préparation soutenance)

Support de révision : ce que le déploiement (`scripts/deploy.sh`, qui applique `k8s/`) crée, comment les pièces s'emboîtent, et l'explication de **chaque ligne** des fichiers de `k8s/`. Les justifications des choix (pourquoi ceci plutôt que cela) sont dans les [ADR](../adr/README.md) (un fichier par choix) ; ce guide explique le **comment**.

Pour répondre vite en soutenance (drain, pod tué, limites, autoscaling, sauvegarde, réseau, sécurité des pods) : l'[antisèche](cheatsheet.md), avec les commandes à montrer en direct.

Méthode conseillée : lire une partie, puis fermer le guide et réexpliquer le fichier à voix haute, ligne par ligne. Chaque partie se termine par des questions probables en soutenance.

Avancement :

| Partie   | Fichier                           | État |
| -------- | --------------------------------- | ---- |
| 0        | Vocabulaire                       | fait |
| 1        | Ce qui est créé dans le cluster   | fait |
| 2        | `kustomization.yaml`              | fait |
| 3        | `namespace.yaml`                  | fait |
| 4        | `postgres.yaml` (+ `schema.sql`)  | fait |
| 5        | `redis.yaml`                      | fait |
| 6        | `worker.yaml`                     | fait |
| 7        | `poll.yaml`                       | fait |
| 8        | `result.yaml`                     | fait |
| 8 bis    | `pdb.yaml`                        | fait |
| 8 ter    | `network-policies.yaml`           | fait |
| 8 quater | `hpa.yaml`                        | fait |
| 9        | Scénarios (rollout, drain, panne) | fait |

---

## 0. Vocabulaire

| Terme                                   | En une phrase                                                                                                                 | Chez nous                                                    |
| --------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------ |
| **Cluster**                             | L'ensemble des machines pilotées par Kubernetes.                                                                              | `bernstein-aks` (AKS)                                        |
| **Nœud** (node)                         | Une machine (VM) du cluster, qui fait tourner des pods.                                                                       | 2 VM `Standard_B2s_v2`                                       |
| **Pod**                                 | La plus petite unité lancée : un ou plusieurs conteneurs qui partagent une IP. Jetable : remplacé, jamais réparé.             | 7 pods                                                       |
| **Contrôleur**                          | Objet qui crée et surveille des pods pour atteindre un état désiré (boucle de réconciliation).                                | Deployment, StatefulSet                                      |
| **Deployment**                          | Contrôleur pour des pods interchangeables, sans données propres. Gère les rolling updates.                                    | poll, result, worker, redis                                  |
| **ReplicaSet**                          | Créé par un Deployment, un par version du template. C'est lui qui maintient le nombre de pods.                                | 1 par version de chaque Deployment                           |
| **StatefulSet**                         | Contrôleur pour des pods avec identité stable (`postgres-0`) et disque propre.                                                | postgres                                                     |
| **Service**                             | Adresse stable (nom DNS + IP virtuelle) qui répartit le trafic entre les pods qui portent un label.                           | `postgres`, `redis` (internes), `poll`, `result` (publics)   |
| **ConfigMap**                           | Réglages non secrets (clé/valeur ou fichiers), lus par les pods.                                                              | `app-config`, `postgres-init`                                |
| **Secret**                              | Comme un ConfigMap, pour les mots de passe. Encodé en base64, **pas chiffré**.                                                | `app-secrets`                                                |
| **PVC**                                 | PersistentVolumeClaim : une demande de disque (« je veux 1 Gi »).                                                             | `data-postgres-0`                                            |
| **PV**                                  | PersistentVolume : le disque réel qui répond à la demande (ici un disque Azure créé automatiquement).                         | 1 disque Azure de 1 Gi                                       |
| **Namespace**                           | Un espace isolé dans le cluster, comme un dossier pour les objets.                                                            | `bernstein`                                                  |
| **Probe**                               | Test de santé lancé régulièrement par le kubelet : liveness (redémarrer ?), readiness (envoyer du trafic ?).                  | `/healthz`, `/readyz`, `pg_isready`, `redis-cli`             |
| **PodDisruptionBudget**                 | Règle « jamais moins de N pods disponibles » que `kubectl drain` et les mises à jour de nœuds doivent respecter.              | `poll`, `result` (`minAvailable: 1`)                         |
| **Anti-affinity**                       | Règle de placement : « évite un nœud qui a déjà un pod comme moi ».                                                           | Poll et Result : 1 pod par nœud                              |
| **preStop**                             | Action lancée juste avant l'arrêt d'un conteneur, avant le `SIGTERM`.                                                         | `sleep` de 5 s sur Poll et Result                            |
| **kubelet**                             | L'agent Kubernetes sur chaque nœud : lance les conteneurs et exécute les probes.                                              | 1 par nœud, géré par AKS                                     |
| **ClusterIP / NodePort / LoadBalancer** | Les 3 types de Service, emboîtés : adresse interne ; + un port sur chaque nœud ; + une IP publique du cloud devant les nœuds. | `ClusterIP` : postgres, redis. `LoadBalancer` : poll, result |
| **kube-proxy**                          | Composant sur chaque nœud qui programme le réseau : il envoie le trafic d'un Service vers l'un de ses pods ready.             | 1 par nœud, géré par AKS                                     |
| **Kustomize**                           | Outil intégré à `kubectl` qui assemble les YAML et leur applique des transformations.                                         | `k8s/kustomization.yaml`                                     |

---

## 1. Ce qui est créé dans le cluster

### Ce qu'on écrit (23 objets)

`kubectl kustomize k8s/` produit exactement ces objets :

| Type                    | Nom                    | Vient de                | Rôle                                                          |
| ----------------------- | ---------------------- | ----------------------- | ------------------------------------------------------------- |
| Namespace               | `bernstein`            | `namespace.yaml`        | Le « dossier » qui contient tout le reste                     |
| ConfigMap               | `app-config-<hash>`    | `kustomization.yaml`    | Adresses et noms (Redis, Postgres)                            |
| ConfigMap               | `postgres-init-<hash>` | `kustomization.yaml`    | Le fichier `schema.sql`                                       |
| Secret                  | `app-secrets-<hash>`   | `kustomization.yaml`    | Les mots de passe (`secrets.env`)                             |
| Service                 | `postgres`             | `postgres.yaml`         | Adresse interne de la base                                    |
| Service                 | `redis`                | `redis.yaml`            | Adresse interne de la file                                    |
| Service                 | `poll`                 | `poll.yaml`             | **IP publique** de la page de vote                            |
| Service                 | `result`               | `result.yaml`           | **IP publique** de la page des résultats                      |
| PodDisruptionBudget     | `poll`, `result`       | `pdb.yaml`              | Au moins 1 pod de chaque toujours disponible pendant un drain |
| NetworkPolicy           | 7 (voir partie 8 ter)  | `network-policies.yaml` | Tout fermé, puis seulement les flux de l'app                  |
| HorizontalPodAutoscaler | `poll`                 | `hpa.yaml`              | Poll entre 2 et 6 pods selon le CPU                           |
| StatefulSet             | `postgres`             | `postgres.yaml`         | La base, avec son disque                                      |
| Deployment              | `redis`                | `redis.yaml`            | La file de votes                                              |
| Deployment              | `worker`               | `worker.yaml`           | Redis → Postgres                                              |
| Deployment              | `poll`                 | `poll.yaml`             | Page de vote                                                  |
| Deployment              | `result`               | `result.yaml`           | Page des résultats                                            |

### Ce que Kubernetes crée tout seul à partir de ça

On n'écrit pas ces objets : les contrôleurs les fabriquent.

```
Deployment poll ──► ReplicaSet poll-<hash-version> ──► Pod poll-<hash>-xxxxx   (×2)
Deployment result ─► ReplicaSet result-<…>        ──► Pod result-<…>        (×2)
Deployment worker ─► ReplicaSet worker-<…>        ──► Pod worker-<…>        (×1)
Deployment redis ──► ReplicaSet redis-<…>         ──► Pod redis-<…>         (×1)
StatefulSet postgres ──────────────────────────────► Pod postgres-0          (×1)
                     └─► PVC data-postgres-0 ──► PV pvc-<uuid> ──► disque Azure 1 Gi
Service postgres / redis / poll / result ──► EndpointSlice (la liste des IP des pods « ready »)
Service poll / result (LoadBalancer) ──► dans Azure : 1 IP publique + 1 règle sur le load balancer du cluster
```

Total : **7 pods** au repos (2 poll, 2 result, 1 worker, 1 redis, 1 postgres), jusqu'à 11 quand le HPA monte Poll à 6.

À retenir : un **Service ne pointe jamais vers un pod précis**. Il pointe vers un **label** (`app.kubernetes.io/name: postgres`). Kubernetes tient à jour la liste des IP des pods qui portent ce label **et** qui sont ready (l'EndpointSlice).

### L'ordre de démarrage

Kubernetes n'a **pas** d'ordre de démarrage : tout est créé en même temps. Ça marche quand même pour 2 raisons :

1. Les apps **réessaient** en boucle. Le worker affiche `Waiting for db` jusqu'à ce que Postgres réponde, et Result fait `async.retry` 1000 fois.
2. Les **readiness probes** retiennent le trafic tant qu'un pod n'a pas ses dépendances.

### Questions probables

- _« Combien de pods tournent, et qui les a créés ? »_ 7. On n'en a écrit aucun : ce sont les Deployments (via leurs ReplicaSets) et le StatefulSet qui les créent.
- _« Comment Poll trouve-t-il Redis ? »_ Par le nom DNS `redis`, celui du Service, dans le même namespace. La valeur vient de `REDIS_HOST=redis` dans `app-config`.
- _« Comment l'évaluateur accède-t-il aux pages ? »_ Par les 2 IP publiques des Services `poll` et `result`, visibles dans la colonne `EXTERNAL-IP` de `kubectl -n bernstein get svc`.
- _« Qui crée le disque de Postgres ? »_ Le StatefulSet crée la PVC à partir de `volumeClaimTemplates`, puis AKS crée un disque Azure pour la satisfaire (provisionnement dynamique, classe `default`).

---

## 2. `k8s/kustomization.yaml`, ligne par ligne

C'est le **point d'entrée** des manifests. `kubectl apply -k <dossier>` lit le `kustomization.yaml`, assemble les fichiers, applique les transformations et envoie le résultat au cluster. Pour l'app, on ne le lance pas directement sur `k8s/` : `scripts/deploy.sh` l'applique à travers un overlay qui ajoute les images (voir « Les images »). `kubectl kustomize k8s/` montre le résultat sans rien envoyer.

### En-tête

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
```

« Ce fichier est une recette Kustomize. » Ce sont 2 lignes obligatoires, toujours identiques. Ce n'est pas un objet envoyé au cluster : c'est lu par `kubectl` uniquement.

### Le namespace

```yaml
namespace: bernstein
```

Ajoute `metadata.namespace: bernstein` à **chaque** objet « namespacé » (tout sauf le Namespace lui-même). On ne l'écrit donc dans aucun autre fichier, et on ne peut pas l'oublier.

### Les labels communs

```yaml
labels:
  - pairs:
      app.kubernetes.io/part-of: bernstein
```

Colle le label `app.kubernetes.io/part-of: bernstein` sur tous les objets. Ça sert à filtrer : `kubectl get all -A -l app.kubernetes.io/part-of=bernstein`.

On utilise `labels` et **pas** l'ancien `commonLabels`, qui ajoutait aussi le label dans les **selectors**. Or le selector d'un Deployment est **immuable** : changer un label commun ferait échouer `kubectl apply` et forcerait à supprimer puis recréer le Deployment, donc une coupure.

### La liste des fichiers

```yaml
resources:
  - namespace.yaml
  - postgres.yaml
  - redis.yaml
  - result.yaml
  - worker.yaml
  - poll.yaml
```

Les fichiers à assembler. L'ordre n'a pas d'importance pour le résultat : `kubectl` crée de toute façon les Namespaces avant le reste.

### Les images

Il n'y a **pas** de bloc `images` dans `k8s/kustomization.yaml`. Les manifests écrivent l'image avec un nom **générique** (`image: poll`, `worker`, `result`). C'est `scripts/deploy.sh` qui pose le registry et le tag au moment du déploiement, dans un overlay qu'il génère à chaque fois (`.deploy/kustomization.yaml`, gitignoré) :

```yaml
resources:
  - ../k8s
images:
  - name: result
    newName: <registry>/result
    newTag: 878cebc
```

- `resources: ../k8s` : l'overlay reprend tout `k8s/` tel quel.
- `name` : le nom générique à chercher dans les manifests.
- `newName` : l'adresse réelle, construite à partir de `REGISTRY`, le registry de celui qui déploie.
- `newTag` : le SHA court du commit, ou `<sha>-dirty-<date>` si `poll-application/` a des modifications non commitées. **Changer le tag change le Pod template, donc déclenche un rolling update.**

Pourquoi un overlay généré : l'évaluateur ne peut pas tirer les images depuis notre registry, et le script ne modifie aucun fichier suivi par git ([ADR 0017](../adr/0017-deploy-script.md)). **Conséquence** : `kubectl apply -k k8s/` seul déploie des images sans registry, qui finissent en `ImagePullBackOff`. On déploie toujours avec le script.

`postgres` et `redis` ne sont pas concernés : ils utilisent des images publiques (`postgres:18-alpine`, `redis:8-alpine`) écrites directement dans leur manifest.

### Les ConfigMaps générés

```yaml
configMapGenerator:
  - name: app-config
    literals:
      - REDIS_HOST=redis
      - POSTGRES_HOST=postgres
      - POSTGRES_PORT=5432
      - POSTGRES_DB=postgres
      - POSTGRES_USER=postgres
```

Crée un ConfigMap à partir de paires `CLÉ=valeur` :

- `REDIS_HOST=redis` et `POSTGRES_HOST=postgres` sont les **noms des Services**, donc des noms DNS.
- `POSTGRES_PORT=5432` : le port standard de PostgreSQL. Dans le ConfigMap, il devient la chaîne `"5432"`, car les valeurs d'un ConfigMap sont toujours du texte.
- `POSTGRES_DB` et `POSTGRES_USER` : la base et l'utilisateur. Postgres les lit au premier démarrage pour les créer, et worker et result les lisent pour s'y connecter.

```yaml
- name: postgres-init
  files:
    - schema.sql
```

Crée un **second** ConfigMap, dont le contenu est un **fichier entier** : la clé est `schema.sql`, la valeur est le texte SQL. Monté comme un volume dans Postgres, il devient le fichier `/docker-entrypoint-initdb.d/schema.sql`.

`k8s/schema.sql` est une **copie** de `poll-application/schema.sql`, car Kustomize refuse de lire un fichier hors de `k8s/` (règle de sécurité, même via un lien symbolique). La CI vérifie que les 2 fichiers sont identiques.

**Le hash** : Kustomize nomme réellement l'objet `app-config-kck4c4gbmk`. Le suffixe est calculé à partir du contenu, et toutes les références (`configMapRef: name: app-config`) sont réécrites avec ce nom. Quand une valeur change, le nom change, donc le Pod template des Deployments change, donc **rolling update automatique**. Avec un nom fixe, les pods garderaient les anciennes valeurs jusqu'à un redémarrage manuel.

### Le Secret généré

```yaml
secretGenerator:
  - name: app-secrets
    envs:
      - secrets.env
```

Lit `k8s/secrets.env` (format `CLÉ=valeur`, une par ligne) et crée le Secret `app-secrets-<hash>`, avec le même principe de hash que les ConfigMaps.

- `secrets.env` est **gitignoré** : seul le modèle vide `secrets.env.example` est dans git.
- **S'il manque, la commande échoue** (`no such file or directory`) avant de créer quoi que ce soit. Impossible de déployer sans mots de passe.
- Le Secret obtenu est en **base64**, ce qui n'est **pas** du chiffrement : quiconque a le droit de lire les Secrets du namespace peut lire le mot de passe.

### Questions probables

- _« Que se passe-t-il si je change `POSTGRES_PORT` ? »_ Le hash d'`app-config` change, et les Deployments qui l'utilisent (poll, worker, result) font un rolling update. Postgres aussi : c'est un StatefulSet qui lit `app-config`, donc il redémarre.
- _« Pourquoi pas de mot de passe dans le ConfigMap ? »_ Un ConfigMap n'a aucune protection particulière. Les mots de passe vont dans un Secret, que les droits RBAC peuvent restreindre séparément.
- _« Comment l'évaluateur met-il son registry ? »_ Il le passe au script : `REGISTRY=<nom>.azurecr.io scripts/deploy.sh`. Aucun fichier à modifier.
- _« Pourquoi `labels` et pas `commonLabels` ? »_ Pour ne pas modifier les selectors, qui sont immuables sur un Deployment.

---

## 3. `k8s/namespace.yaml`, ligne par ligne

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: bernstein
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/audit: restricted
```

- `apiVersion: v1` : le groupe d'API « core » de Kubernetes, celui des objets de base (Pod, Service, ConfigMap, Secret, Namespace).
- `kind: Namespace` : le type d'objet.
- `metadata.name: bernstein` : son nom. Il n'a pas de `namespace` lui-même, puisque c'est un objet de niveau cluster.
- Les 3 labels `pod-security.kubernetes.io/*` : le **Pod Security Admission**, intégré à l'API server. Le niveau `restricted` impose à chaque pod : pas de root, pas d'élévation de privilèges, toutes les capabilities retirées, un profil seccomp, et seulement certains types de volumes ([ADR 0027](../adr/0027-pod-security-standards.md)).
  - `enforce` : un pod qui viole la règle est **refusé**.
  - `warn` : `kubectl apply` affiche un avertissement, y compris pour un Deployment dont le modèle de pod viole la règle (le Deployment est accepté, ses pods seront refusés).
  - `audit` : la violation est notée dans le journal d'audit de l'API.

Le namespace sépare notre application des composants système (`kube-system`…) et permet de tout supprimer d'un coup. Attention : supprimer le namespace supprime **aussi la PVC, donc le disque et les votes** (la classe de stockage `default` d'AKS a `reclaimPolicy: Delete`).

### Questions probables

- _« À quoi sert le namespace ? »_ Isoler et regrouper : `kubectl get pods -n bernstein` ne montre que nos pods. Les NetworkPolicies (partie 8 ter), le niveau de sécurité des pods et les quotas s'appliquent aussi par namespace.
- _« Comment empêchez-vous un pod root ? »_ Le label `enforce: restricted`. Mesuré : `kubectl -n bernstein run` d'un pod `runAsUser: 0` répond `pods "root-test" is forbidden: violates PodSecurity "restricted:latest"`, avec la liste des règles violées.
- _« `kubectl delete -k k8s/` garde-t-il les votes ? »_ Non : il supprime le namespace, donc la PVC et le disque. Supprimer seulement le pod ou le StatefulSet, en revanche, garde les données.

---

## 4. `k8s/postgres.yaml`, ligne par ligne

Le fichier contient **2 objets** séparés par `---` : un Service et un StatefulSet. `---` est le séparateur de documents YAML : un fichier peut contenir plusieurs objets.

### Objet 1 : le Service

```yaml
apiVersion: v1
kind: Service
metadata:
  name: postgres
  labels:
    app.kubernetes.io/name: postgres
```

- `apiVersion: v1` : les Services font partie de l'API « core ».
- `metadata.name: postgres` : ce nom devient le **nom DNS** `postgres` dans le namespace (en entier : `postgres.bernstein.svc.cluster.local`). C'est la valeur de `POSTGRES_HOST`.
- `labels` : une étiquette sur le Service lui-même, pour le retrouver. Elle ne sert pas au routage.

```yaml
spec:
  type: ClusterIP
```

`ClusterIP` : le Service reçoit une **IP virtuelle interne** (par exemple `10.0.119.113`), joignable **uniquement depuis le cluster**. Pas d'IP publique : la base n'est pas exposée sur Internet. C'est la valeur par défaut, écrite pour être explicite.

```yaml
selector:
  app.kubernetes.io/name: postgres
```

**Le cœur du Service** : il envoie le trafic vers les pods qui portent ce label **et** qui sont ready. Si le pod n'est pas ready, le Service n'a plus de destination et les connexions échouent.

```yaml
ports:
  - name: postgres
    port: 5432
    targetPort: postgres
```

- `port: 5432` : le port **du Service**, celui que les clients appellent (`postgres:5432`).
- `targetPort: postgres` : le port **du conteneur** vers lequel transférer. On utilise son **nom** (`postgres`, défini dans le conteneur) plutôt que le numéro : si le port du conteneur change un jour, il n'y a qu'un endroit à modifier.
- `name` : un nom pour ce port. Il est obligatoire seulement s'il y a plusieurs ports, mais c'est une bonne habitude.

### Objet 2 : le StatefulSet, l'en-tête

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  labels:
    app.kubernetes.io/name: postgres
spec:
  serviceName: postgres
  replicas: 1
```

- `apps/v1` : le groupe d'API des contrôleurs (Deployment, StatefulSet, DaemonSet).
- `serviceName: postgres` : le Service associé au StatefulSet. Il sert normalement à donner un nom DNS à **chaque** pod (`postgres-0.postgres`). Avec 1 replica, on n'en a pas besoin, et notre Service classique suffit.
- `replicas: 1` : un seul pod, `postgres-0`. Postgres ne se réplique pas en ajoutant des pods : 2 pods seraient 2 bases indépendantes.

### Le selector et le template

```yaml
selector:
  matchLabels:
    app.kubernetes.io/name: postgres
template:
  metadata:
    labels:
      app.kubernetes.io/name: postgres
```

- `selector.matchLabels` : comment le StatefulSet reconnaît **ses** pods. Il est **immuable** après création.
- `template` : le **modèle** de pod. Tout ce qui est en dessous décrit le pod à créer.
- `template.metadata.labels` : les labels posés sur le pod. Ils **doivent** correspondre au selector, sinon Kubernetes refuse l'objet. C'est aussi ce label que vise le Service.

Ce trio `selector` / `template.labels` / `Service.selector` revient dans **tous** nos manifests.

### La sécurité du pod

```yaml
spec:
  automountServiceAccountToken: false
  securityContext:
    seccompProfile:
      type: RuntimeDefault
    runAsUser: 70
    runAsGroup: 70
    runAsNonRoot: true
    fsGroup: 70
```

Le `securityContext` au niveau **pod** s'applique à tous ses conteneurs.

- `automountServiceAccountToken: false` : par défaut, Kubernetes monte dans chaque conteneur un jeton pour appeler son API (`/var/run/secrets/kubernetes.io/serviceaccount`). Aucune de nos apps n'appelle l'API : sans jeton, un attaquant dans le conteneur n'a rien à essayer.
- `seccompProfile: RuntimeDefault` : le filtre d'appels système par défaut du runtime (containerd) bloque les appels dangereux et rarement utiles. Exigé par le niveau `restricted` (partie 3). Vérifié : `Seccomp: 2` (filtre actif) dans `/proc/1/status`.

Ces deux réglages sont les mêmes dans les 5 fichiers (`postgres`, `redis`, `worker`, `poll`, `result`) : les parties suivantes ne les répètent pas.

- `runAsUser: 70` / `runAsGroup: 70` : les processus tournent avec l'uid et le gid 70, ceux de l'utilisateur `postgres` dans l'image Alpine (vérifié avec `id postgres` dans l'image).
- `runAsNonRoot: true` : Kubernetes **refuse** de démarrer le conteneur s'il tournerait en root (uid 0). C'est un garde-fou.
- `fsGroup: 70` : les volumes montés appartiennent au groupe 70. Sans ça, le disque Azure tout neuf appartiendrait à root, et Postgres (uid 70) ne pourrait pas y écrire.

### Le conteneur

```yaml
containers:
  - name: postgres
    image: postgres:18-alpine
    ports:
      - name: postgres
        containerPort: 5432
```

- `containers` : une liste, car un pod peut avoir plusieurs conteneurs. Ici, un seul.
- `image: postgres:18-alpine` : l'image officielle, en version Alpine (plus légère). C'est la même que dans `docker-compose.yml`. Pas de passage par `images` dans la kustomization : c'est une image publique.
- `containerPort: 5432` : **documente** le port écouté et lui donne un nom (`postgres`), réutilisé par `targetPort` du Service. Ça n'ouvre et ne ferme aucun port : Postgres écoute sur 5432 de toute façon.

### Les variables d'environnement

```yaml
env:
  - name: POSTGRES_DB
    valueFrom:
      configMapKeyRef:
        name: app-config
        key: POSTGRES_DB
```

`env` déclare une variable une par une. `valueFrom.configMapKeyRef` va lire **une clé** d'un ConfigMap. Kustomize remplace `app-config` par `app-config-<hash>`. Même chose pour `POSTGRES_USER`.

```yaml
- name: POSTGRES_PASSWORD
  valueFrom:
    secretKeyRef:
      name: app-secrets
      key: POSTGRES_PASSWORD
```

Même principe, mais depuis le **Secret**. Kubernetes décode le base64, et le conteneur reçoit le mot de passe en clair dans sa variable.

Au **premier** démarrage, l'image `postgres` lit ces 3 variables pour créer l'utilisateur, son mot de passe et la base. Aux démarrages suivants, elle ne les relit pas : la base existe déjà.

On utilise `env` (clé par clé) plutôt que `envFrom` (tout le ConfigMap) pour ne donner à Postgres **que** ce dont il a besoin. En particulier, pas `REDIS_PASSWORD`.

### Les probes

```yaml
readinessProbe:
  exec:
    command: ['sh', '-c', 'pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"']
  periodSeconds: 5
  timeoutSeconds: 3
```

- `exec` : lance une commande **dans** le conteneur. Code de sortie `0` = succès.
- `pg_isready` : outil fourni par Postgres, qui répond « accepting connections » quand la base accepte les connexions.
- `sh -c '…'` : nécessaire pour que `$POSTGRES_USER` soit remplacé par sa valeur. Sans shell, `exec` passerait le texte `$POSTGRES_USER` tel quel.
- `periodSeconds: 5` : tester toutes les 5 s. `timeoutSeconds: 3` : sans réponse en 3 s, c'est un échec.
- Valeurs par défaut non écrites : `failureThreshold: 3` (3 échecs avant « pas prêt »), `successThreshold: 1`, `initialDelaySeconds: 0`.

```yaml
livenessProbe:
  exec:
    command: ['sh', '-c', 'pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"']
  initialDelaySeconds: 30
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 6
```

Même test, mais réglé **large** : on attend 30 s après le démarrage, puis il faut 6 échecs à 10 s d'intervalle, soit environ 1 minute. Tuer une base qui démarre lentement ou qui est chargée ferait plus de mal que de bien.

### Les ressources

```yaml
resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: 500m
    memory: 512Mi
```

- `requests` : ce que le scheduler **réserve** sur un nœud pour placer le pod. `100m` = 100 millicores = 0,1 CPU.
- `limits` : le **plafond**. Au-delà de 512 Mi de mémoire, le conteneur est tué (`OOMKilled`). Au-delà de 0,5 CPU, il est **ralenti** (throttling), pas tué.
- `Mi` = mébioctet (1024 × 1024 octets).
- **Mesuré** : 29 Mi et 5m au repos, 17m sous charge. La request de 256 Mi paraît large, mais Postgres réserve un cache de 128 Mo (`shared_buffers`, vérifié avec `SHOW shared_buffers`) qui se remplit à mesure qu'il lit des données ([ADR 0018](../adr/0018-resource-requests-and-limits.md)).

### La sécurité du conteneur

```yaml
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: ['ALL']
```

- `allowPrivilegeEscalation: false` : un processus ne peut pas gagner plus de droits que son parent (par exemple via un binaire `setuid`).
- `capabilities.drop: ['ALL']` : retire tous les « super-pouvoirs » Linux (changer de propriétaire d'un fichier, ouvrir un port bas…). Comme Postgres tourne directement en uid 70, il n'en a besoin d'aucun. Vérifié sur AKS : `CapEff: 0000000000000000`. _(Ajouté par la PR #61.)_

- `readOnlyRootFilesystem: true` : le système de fichiers de l'image est en lecture seule. Postgres écrit ses données sur le disque (PVC), son socket et son fichier de verrou dans `/var/run/postgresql`, et des fichiers temporaires dans `/tmp` : ces deux dossiers sont des `emptyDir` (ci-dessous).

### Les volumes

```yaml
volumeMounts:
  - name: data
    mountPath: /var/lib/postgresql
  - name: init
    mountPath: /docker-entrypoint-initdb.d
    readOnly: true
  - name: run
    mountPath: /var/run/postgresql
  - name: tmp
    mountPath: /tmp
```

`volumeMounts` dit **où** monter chaque volume dans le conteneur :

- `data` sur `/var/lib/postgresql` : le disque persistant. L'image range ses fichiers dans le sous-dossier `18/docker`.
- `init` sur `/docker-entrypoint-initdb.d` : le ConfigMap `postgres-init` apparaît comme un dossier, qui contient `schema.sql`. `readOnly` : Postgres peut le lire, pas le modifier.
- `run` et `tmp` : les deux seuls dossiers où Postgres écrit hors du disque, puisque le reste est en lecture seule.

```yaml
volumes:
  - name: init
    configMap:
      name: postgres-init
  - name: run
    emptyDir:
      medium: Memory
      sizeLimit: 1Mi
  - name: tmp
    emptyDir:
      sizeLimit: 64Mi
```

`volumes` dit **ce que sont** les volumes du pod. Ici, `init` est un ConfigMap (Kustomize ajoute le hash au nom). `run` est en mémoire (tmpfs) : un socket et un fichier de verrou de quelques octets. `tmp` est sur le disque du nœud, limité à 64 Mi. Les deux sont vides à chaque démarrage du pod. `data` n'est pas déclaré ici : il vient du `volumeClaimTemplates` juste en dessous.

### Le modèle de disque

```yaml
volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: ['ReadWriteOnce']
      resources:
        requests:
          storage: 1Gi
```

- `volumeClaimTemplates` : propre au StatefulSet. Pour chaque pod, il crée **une PVC** nommée `<nom>-<pod>`, donc `data-postgres-0`. Si le pod est recréé, il retrouve **la même PVC**, donc le même disque.
- `name: data` : relie ce disque au `volumeMount` du même nom.
- `ReadWriteOnce` : le disque ne peut être monté en écriture que par **un seul nœud** à la fois. C'est le cas d'un disque Azure.
- `storage: 1Gi` : la taille demandée. Pas de `storageClassName` : c'est la classe par défaut d'AKS (`default`, un disque Azure SSD) qui s'applique.

### Ce qui se passe au démarrage

1. Le StatefulSet crée la PVC `data-postgres-0`, puis AKS crée le disque Azure.
2. Le pod `postgres-0` démarre sur un nœud, et le disque y est rattaché.
3. **Disque vide** : `initdb` crée la base avec les 3 variables, puis exécute `schema.sql` (création de la table `votes`).
4. **Disque déjà rempli** : « Skipping initialization », et la base repart avec ses données.
5. `pg_isready` répond, le pod devient ready, et le Service `postgres` route vers lui.

### Questions probables

- _« Pourquoi un StatefulSet et pas un Deployment ? »_ Pour une identité stable et un disque attaché à ce pod précis. Un StatefulSet arrête aussi l'ancien pod avant de créer le nouveau, ce qui est indispensable avec un disque `ReadWriteOnce`.
- _« Que se passe-t-il si je supprime le pod ? »_ Il est recréé sous le même nom, avec le même disque : les votes restent (testé).
- _« Et si on draine son nœud ? »_ Le pod s'arrête, le disque Azure est détaché puis rattaché à l'autre nœud (1 à 2 minutes), et Postgres repart. Pendant ce temps, Result n'est plus ready et le worker attend. Les votes s'accumulent dans Redis.
- _« Pourquoi `fsGroup` ? »_ Pour que le disque neuf, créé avec root comme propriétaire, soit accessible en écriture à l'uid 70.
- _« Différence entre `port` et `targetPort` ? »_ `port` est celui du Service, que les clients appellent. `targetPort` est celui du conteneur, où le trafic arrive.

---

## 5. `k8s/redis.yaml`, ligne par ligne

Même structure que Postgres (Service + contrôleur), mais avec un **Deployment** et **sans disque**. Les lignes déjà vues dans la partie 4 ne sont pas répétées.

### Le Service

```yaml
kind: Service
metadata:
  name: redis
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: redis
  ports:
    - name: redis
      port: 6379
      targetPort: redis
```

Identique au Service Postgres, sur le port standard de Redis, `6379`. Le nom `redis` est la valeur de `REDIS_HOST`.

### Le Deployment et sa stratégie de mise à jour

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
spec:
  replicas: 1
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  minReadySeconds: 5
  progressDeadlineSeconds: 120
```

- `kind: Deployment` : des pods interchangeables, ce qui convient puisque Redis n'a pas de disque.
- `replicas: 1` : 2 pods Redis seraient **2 files indépendantes**. Le Service répartirait les `RPUSH` et les `BLPOP` entre elles au hasard.
- `strategy` : **comment** remplacer les pods lors d'une mise à jour. C'est la stratégie imposée par notre baseline, présente sur nos 4 Deployments :
  - `RollingUpdate` : remplacer progressivement (l'autre choix, `Recreate`, tue tout puis relance, donc une coupure) ;
  - `maxSurge: 1` : 1 pod de plus que `replicas` est autorisé pendant la mise à jour ;
  - `maxUnavailable: 0` : jamais moins de `replicas` pods disponibles.
- `minReadySeconds: 5` : un nouveau pod doit rester ready **5 s** avant d'être compté comme disponible. Ça évite de valider un pod qui serait ready une seconde, puis planterait.
- `progressDeadlineSeconds: 120` : si aucun nouveau pod ne devient ready pendant **2 min**, le rollout est marqué en échec (défaut : 10 min). Kubernetes ne fait que le signaler ; les anciens pods continuent de servir (partie 9.2 bis).

Pour Redis, ça veut dire : le nouveau pod démarre, devient ready, puis l'ancien s'arrête. Poll ne perd jamais Redis pendant une mise à jour.

Le `selector` et le `template` fonctionnent exactement comme pour Postgres.

### La sécurité

```yaml
securityContext:
  runAsUser: 999
  runAsGroup: 1000
  runAsNonRoot: true
  fsGroup: 1000
```

L'uid 999 et le gid 1000 sont ceux de l'utilisateur `redis` dans l'image Alpine (vérifié avec `id redis`). Plus bas, le conteneur a `allowPrivilegeEscalation: false`, `capabilities.drop: ['ALL']` et `readOnlyRootFilesystem: true` : Redis n'écrit rien sur disque (`--save ''`, `--appendonly no`, ci-dessous), donc aucun `emptyDir` n'est nécessaire.

### La commande de démarrage

```yaml
image: redis:8-alpine
command:
  - sh
  - -c
  - |
    if [ -n "$REDIS_PASSWORD" ]; then
      exec redis-server --save '' --appendonly no --maxmemory 100mb --maxmemory-policy noeviction --requirepass "$REDIS_PASSWORD"
    else
      exec redis-server --save '' --appendonly no --maxmemory 100mb --maxmemory-policy noeviction
    fi
```

- `command` **remplace** la commande de démarrage de l'image.
- `sh -c` + `|` : un petit script shell sur plusieurs lignes. Le `|` en YAML garde les retours à la ligne.
- `if [ -n "$REDIS_PASSWORD" ]` : si un mot de passe est défini (non vide), Redis démarre avec `--requirepass`. Sinon, il démarre sans authentification.
- `--save ''` : désactive les **sauvegardes RDB** périodiques, actives par défaut.
- `--appendonly no` : désactive le **journal AOF**. Redis reste donc purement en mémoire : il n'écrit rien sur disque et ne fait jamais de `fork` pour sauvegarder.
- `--maxmemory 100mb` : Redis plafonne lui-même sa mémoire, sous la limite du conteneur (128 Mi), ce qui laisse 28 Mio pour son propre fonctionnement.
- `--maxmemory-policy noeviction` : une fois plein, Redis **refuse les écritures** au lieu d'effacer des clés. Testé sur AKS : un vote reçoit une erreur 500 de Poll, mais la page et `/readyz` répondent toujours, et le worker peut encore vider la file ([ADR 0018](../adr/0018-resource-requests-and-limits.md)).
- `exec` : le shell **se remplace** par `redis-server`. Redis devient le processus principal (PID 1) et reçoit directement le signal `SIGTERM` quand Kubernetes l'arrête, ce qui permet un arrêt propre.

### Le mot de passe, optionnel

```yaml
env:
  - name: REDIS_PASSWORD
    valueFrom:
      secretKeyRef:
        name: app-secrets
        key: REDIS_PASSWORD
        optional: true
```

`optional: true` : si la clé n'existe pas dans le Secret, le pod démarre quand même, sans la variable. Sans ce réglage, une clé absente empêcherait le pod de démarrer.

### Les probes

```yaml
readinessProbe:
  exec:
    command: ['sh', '-c', 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli ping | grep -q PONG']
```

- `redis-cli ping` : Redis doit répondre `PONG`.
- `REDISCLI_AUTH=…` : `redis-cli` lit le mot de passe depuis cette variable. Si elle est vide, pas d'authentification. Ça marche donc avec ou sans mot de passe, sans le mettre en argument (`-a`).
- `grep -q PONG` : le code de sortie est `0` seulement si la réponse contient `PONG`. Une réponse `NOAUTH` (mauvais mot de passe) fait échouer la probe.

La liveness est le même test, avec `initialDelaySeconds: 10`, `periodSeconds: 10` et `timeoutSeconds: 5`.

### Les ressources

Requests 50m / 64Mi, limits 250m / 128Mi. **Mesuré** : 3 Mi et 5m au repos, 19m sous charge (37 votes par seconde). Sans `maxmemory`, une file qui grossit atteindrait les 128 Mi : le conteneur serait tué (`OOMKilled`) et toute la file perdue. Avec `maxmemory 100mb` et `noeviction`, Redis refuse les nouveaux votes et garde ceux en attente.

### Questions probables

- _« Comment limiter le CPU de Redis ? »_ C'est déjà fait : `limits.cpu: 250m`. Au-delà, Redis est ralenti (throttling), pas tué. De toute façon, il exécute les commandes sur un seul thread principal.
- _« Si Redis redémarre, que perd-on ? »_ Les votes encore dans la file, pas encore traités par le worker. En temps normal, la file est vide en quelques millisecondes. Un pod Redis revient en environ 4 s (mesuré).
- _« Pourquoi pas de disque pour Redis ? »_ C'est un tampon, pas la source de vérité, qui est Postgres. Un disque ajouterait un coût et un rattachement lent lors d'un drain.
- _« Que se passe-t-il pour Poll si Redis tombe ? »_ Le `/readyz` de Poll fait un `ping` sur Redis : les 2 pods Poll deviennent non ready, et la page de vote n'est plus servie. **Redis est un point unique de défaillance pour Poll.**
- _« Pourquoi `exec` dans la commande ? »_ Pour que Redis soit le PID 1 et reçoive le `SIGTERM` directement. Sinon, c'est `sh` qui le recevrait.

---

## 6. `k8s/worker.yaml`, ligne par ligne

Un **Deployment sans Service** : personne n'appelle le worker. Il ouvre lui-même ses connexions vers `redis` et `postgres`.

### En-tête et stratégie

```yaml
kind: Deployment
metadata:
  name: worker
spec:
  replicas: 1
  strategy: … # maxSurge: 1, maxUnavailable: 0
  minReadySeconds: 5
```

- `replicas: 1` : un seul consommateur suffit. Une JVM coûte de la mémoire (192 à 384 Mi).
- Même stratégie que Redis (partie 5) : pendant une mise à jour, **2 workers** tournent brièvement. C'est sans risque de doublon, car `BLPOP` donne chaque vote à un seul client, et l'écriture SQL est un **upsert** (`INSERT … ON CONFLICT (id) DO UPDATE`).

### La sécurité et le port 80

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 10001
  sysctls:
    - name: net.ipv4.ip_unprivileged_port_start
      value: '0'
```

- `runAsUser: 10001` : l'utilisateur `app` créé dans le `Dockerfile` du worker.
- `sysctls` : modifie un réglage du noyau, **uniquement dans le pod**. Sous Linux, seul root peut ouvrir un port inférieur à 1024. Or le worker sert ses probes sur le port **80**. `ip_unprivileged_port_start=0` autorise tout utilisateur à ouvrir n'importe quel port. Kubernetes classe cette sysctl « safe », elle est donc autorisée par défaut depuis la 1.22.
- `value: '0'` est entre guillemets, car une valeur de sysctl doit être une chaîne.

### Le conteneur et son image

```yaml
- name: worker
  image: worker
  ports:
    - name: http
      containerPort: 80
```

- `image: worker` : un nom générique, que `scripts/deploy.sh` remplace par `<registry>/worker:<tag>` (partie 2, « Les images »).
- `ports.name: http` : un nom réutilisé par les probes (`port: http`).

### Les variables

```yaml
envFrom:
  - configMapRef:
      name: app-config
```

`envFrom` : **toutes** les clés d'`app-config` deviennent des variables d'un coup (`REDIS_HOST`, `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_DB`, `POSTGRES_USER`). Le worker a besoin des deux familles.

```yaml
env:
  - name: POSTGRES_PASSWORD
    valueFrom:
      secretKeyRef: { name: app-secrets, key: POSTGRES_PASSWORD }
  - name: REDIS_PASSWORD
    valueFrom:
      secretKeyRef: { name: app-secrets, key: REDIS_PASSWORD, optional: true }
```

Les 2 mots de passe, pris un par un dans le Secret. Celui de Redis est optionnel.

### Les probes HTTP

```yaml
livenessProbe:
  httpGet:
    path: /readyz
    port: http
  initialDelaySeconds: 30
  periodSeconds: 10
  timeoutSeconds: 3
  failureThreshold: 6
readinessProbe:
  httpGet:
    path: /readyz
    port: http
  periodSeconds: 5
  timeoutSeconds: 3
  failureThreshold: 2
```

- `httpGet` : le kubelet fait une requête HTTP sur l'IP du pod. Succès = code entre 200 et 399.
- Les **2 probes** visent `/readyz` : 200 seulement si Redis répond à `PING` **et** si la connexion Postgres est valide (`isValid(2)`). `/healthz` (toujours 200) n'est plus utilisé par le worker.
- **Readiness** (2 × 5 s, soit environ 10 s) : sert à valider une mise à jour.
- **Liveness** : 30 s d'attente au démarrage, puis 6 échecs × 10 s, soit environ **1 minute** sans Redis ou sans Postgres avant un redémarrage.
- Pourquoi c'est différent de Poll et Result (#63) : le worker ne voit qu'une connexion Postgres morte quand il écrit. Avec la liveness sur `/healthz` (toujours 200), il restait `0/1` indéfiniment après un redémarrage de Postgres, jusqu'au vote suivant. Avec `/readyz`, le kubelet le redémarre et il se reconnecte. C'est sans risque : il n'a ni Service ni utilisateurs.

Sans Service, la readiness ne coupe aucun trafic. Elle sert à **valider une mise à jour** : l'ancien worker n'est arrêté que quand le nouveau est connecté aux deux.

**Mesuré sur AKS** : Postgres supprimé, aucun vote envoyé. Postgres revient en 24 s, le worker passe `0/1`, puis il est redémarré par sa liveness et revient `1/1` à 66 s. Pendant une longue panne de la base, il redémarre en boucle (avec un délai croissant) : c'est attendu. Si un vote est en cours au moment de la panne, il est remis dans la file (`LPUSH`) avant l'arrêt : **aucun vote n'est perdu.**

### Ressources et sécurité du conteneur

```yaml
resources:
  requests: { cpu: 100m, memory: 192Mi }
  limits: { cpu: 500m, memory: 384Mi }
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: ['ALL']
```

- La mémoire est plus haute que pour les autres apps, à cause de la **JVM** Java. **Mesuré dans le pod** : la JVM lit la limite du conteneur (384 Mi) et choisit seule un tas maximum de 126 Mio et le ramasse-miettes Serial (elle ne voit qu'1 CPU avec la limite de 500m). Usage réel : 43 Mi au repos, 53 Mi sous charge. Au déploiement, le nouveau worker est prêt 5 s après son démarrage.
- `readOnlyRootFilesystem: true` : tout le système de fichiers du conteneur est en lecture seule. Le worker n'écrit rien sur disque, et un attaquant ne pourrait déposer aucun fichier. Vérifié : `touch /app/x` donne `Read-only file system`.

### Questions probables

- _« Pourquoi pas de Service pour le worker ? »_ Personne ne l'appelle. Il consomme la file de lui-même.
- _« Peut-on avoir 2 workers ? »_ Oui, sans doublon (`BLPOP` atomique + upsert). Mais l'ordre de 2 votes très rapprochés d'un même votant n'est plus garanti.
- _« Que se passe-t-il si Postgres est indisponible ? »_ Les votes restent dans Redis. Si une écriture échoue, le vote est remis dans la file, le worker redémarre et attend la base (`Waiting for db`).
- _« Pourquoi la sysctl ? »_ Pour écouter sur le port 80 sans être root.

---

## 7. `k8s/poll.yaml`, ligne par ligne

Même structure que le worker (partie 6). Seules les **différences** sont détaillées ici.

### Le Service public (LoadBalancer)

En tête du fichier, avant le Deployment, séparé par `---` :

```yaml
apiVersion: v1
kind: Service
metadata:
  name: poll
  labels:
    app.kubernetes.io/name: poll
spec:
  type: LoadBalancer
  selector:
    app.kubernetes.io/name: poll
  ports:
    - name: http
      port: 80
      targetPort: http
```

C'est la même structure que les Services de Postgres et Redis (partie 4). La seule différence est **`type: LoadBalancer`**.

**Les 3 types de Service s'emboîtent** :

```
LoadBalancer  =  NodePort  +  une IP publique (Azure) devant les nœuds
NodePort      =  ClusterIP +  un port ouvert sur chaque nœud (30000-32767)
ClusterIP     =  une adresse interne stable (nom DNS + IP virtuelle)
```

Un Service `LoadBalancer` a donc **aussi** une adresse interne (`poll`, `10.0.223.71`) et un port sur chaque nœud (le `30829` dans `80:30829/TCP`). C'est pour ça qu'un seul objet a fermé 3 tickets (#24 adresse stable, #25 Poll public, #26 Result public).

**Ce qui se passe à la création** :

1. Kubernetes donne au Service une IP interne, puis ouvre un port sur chaque nœud.
2. Le composant Azure d'AKS (cloud controller manager) voit `type: LoadBalancer`. Il réserve une **IP publique**, ajoute une **règle** « IP publique:80 → nœuds:30829 » sur le load balancer Azure du cluster, et une **sonde de santé** sur les nœuds.
3. Il écrit l'IP dans le Service : `EXTERNAL-IP` passe de `<pending>` à l'adresse publique (environ 20 s, mesuré).

**Le trajet d'une requête** :

```
navigateur ── http://<IP publique>:80
   ▼
Load Balancer Azure            ← hors du cluster, choisit un des 2 nœuds
   ▼
nœud A ou B, port 30829        ← NodePort
   ▼
kube-proxy                     ← choisit un pod Poll ready, peut-être sur l'autre nœud
   ▼
pod poll, port 80 → Gunicorn → Flask
```

Le load balancing se fait donc **à 2 niveaux** : Azure répartit entre les **nœuds**, kube-proxy répartit entre les **pods**.

**`externalTrafficPolicy`** : non écrit, donc à sa valeur par défaut, `Cluster`. Chaque nœud accepte le trafic, même s'il n'a pas de pod Poll, et kube-proxy le fait suivre (1 saut de plus possible). L'app voit l'IP d'un nœud, pas celle du visiteur. L'autre valeur, `Local`, garde l'IP du visiteur, mais n'envoie qu'aux nœuds qui ont un pod ready. Pendant une mise à jour, Azure continuerait alors d'envoyer vers un nœud dont les pods partent, jusqu'à ce que sa sonde s'en rende compte. Nos apps n'utilisent pas l'IP du visiteur : `Cluster` est plus sûr ([ADR 0004](../adr/0004-public-access-loadbalancer.md)).

### Pas de `replicas` : c'est le HPA qui décide

```yaml
spec:
  # No `replicas`: the HPA in hpa.yaml sets it (2 to 6). A value here would reset it on every apply.
```

C'est la page que voit l'évaluateur. Le nombre de pods est fixé par le HPA (partie 8 quater) : **2 au repos**, jusqu'à 6 sous charge. Avec au moins 2 pods, il en reste toujours un pendant une mise à jour ou un drain. Chaque vote est une requête courte et sans état (le votant est identifié par un cookie), donc n'importe quel pod peut répondre.

Pourquoi enlever `replicas` du fichier : sinon chaque `kubectl apply` (donc chaque `scripts/deploy.sh`) remettrait 2 pods, même si le HPA en voulait 6.

Avec 2 replicas, la stratégie (`maxSurge: 1`, `maxUnavailable: 0`) donne : 2 pods, puis 3 (un nouveau démarre), puis 2 (un ancien s'arrête), puis 3, puis 2. Il y a **toujours au moins 2 pods** qui servent (mesuré pendant un `rollout restart`).

### Arrêt propre : `preStop` et délai de grâce

```yaml
    spec:
      terminationGracePeriodSeconds: 45
      containers:
        - …
          lifecycle:
            preStop:
              sleep:
                seconds: 5
```

Quand un pod doit s'arrêter (rollout, drain, suppression), Kubernetes fait **deux choses en parallèle** : il le retire des endpoints du Service, et il lance son arrêt. Sans précaution, l'app peut fermer avant que tous les nœuds aient arrêté de lui envoyer du trafic, d'où quelques erreurs.

1. `preStop` → `sleep: 5` : le kubelet **attend 5 s** avant d'envoyer `SIGTERM`. Pendant ce temps, l'app sert normalement, et le retrait des endpoints a le temps de se propager. `sleep` est intégré à Kubernetes : aucun binaire n'est nécessaire dans l'image.
2. Puis `SIGTERM` : Gunicorn termine les requêtes en cours (jusqu'à 30 s par défaut), puis s'arrête.
3. `terminationGracePeriodSeconds: 45` : le délai **total**, compté depuis le début du `preStop`. Au-delà, le kubelet envoie `SIGKILL`. 5 s + 30 s, plus une marge : 45 s.

### Répartition sur les nœuds : anti-affinity

```yaml
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          topologyKey: kubernetes.io/hostname
          matchLabelKeys: ['pod-template-hash']
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: poll
```

- `podAntiAffinity` : « évite les nœuds qui ont déjà un pod qui correspond à `labelSelector` ».
- `topologyKey: kubernetes.io/hostname` : l'unité de répartition est le **nœud** (chaque nœud a un nom d'hôte différent).
- `preferred…` + `weight: 100` : c'est une **préférence**, pas une obligation. Pendant un rollout, le 3e pod (surge) doit pouvoir se placer alors qu'il n'y a que 2 nœuds. Avec `required…`, il resterait `Pending` et bloquerait la mise à jour.
- `IgnoredDuringExecution` : la règle ne s'applique qu'au placement. Un pod déjà lancé n'est jamais déplacé.
- `matchLabelKeys: ['pod-template-hash']` : ne compter que les pods de **la même version**. Sans ça (constaté sur AKS), pendant un rollout, les anciens pods présents sur les 2 nœuds « occupent » les 2 nœuds, la préférence ne sert plus à rien, et les 2 nouveaux pods finissaient sur le même nœud.

### Gunicorn avec des threads

```yaml
- name: GUNICORN_CMD_ARGS
  value: '--threads 4'
```

- L'image lance `gunicorn --workers 2` : 2 workers **synchrones**, qui traitent **une connexion à la fois** chacun.
- **Mesuré sur AKS** : environ **3,5 % des requêtes** vers Poll échouaient (timeout de 3 s), même sans rollout, et via l'IP publique comme depuis l'intérieur du cluster. Une connexion lente ou inactive bloque un worker entier, et 2 suffisent à rendre le pod muet. Result (Node.js, asynchrone) n'avait aucune erreur.
- `GUNICORN_CMD_ARGS` : Gunicorn lit cette variable comme des options en plus. `--threads 4` le fait passer en worker `gthread` : 2 workers × 4 threads = 8 requêtes en parallèle par pod. L'option `--workers 2` de la ligne de commande reste prioritaire. On ne touche ni au Dockerfile ni au code fournis.
- Résultat : **0 erreur sur 656 requêtes**, et la latence p99 passe de 1,4 s à 0,17 s.

### Uniquement Redis

```yaml
envFrom:
  - configMapRef:
      name: app-config
env:
  - name: HOME
    value: /tmp
  - name: REDIS_PASSWORD
    valueFrom:
      secretKeyRef: { name: app-secrets, key: REDIS_PASSWORD, optional: true }
```

- Poll ne parle qu'à Redis : il reçoit aussi les `POSTGRES_*` via `envFrom`, mais ne s'en sert pas.
- `HOME=/tmp` : Gunicorn (le serveur Python) crée un socket de contrôle dans `$HOME/.gunicorn/`. Comme le système de fichiers est en lecture seule, on le fait pointer vers `/tmp`, qui est accessible en écriture (voir plus bas).

### Les probes

Mêmes réglages que le worker, mais `/readyz` vérifie **seulement Redis** (`ping`). Si Redis tombe, les 2 pods Poll sortent du trafic.

### Système de fichiers en lecture seule, avec un `/tmp` en mémoire

```yaml
          securityContext:
            readOnlyRootFilesystem: true
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir:
            medium: Memory
            sizeLimit: 16Mi
```

- Gunicorn a besoin d'écrire dans `/tmp` (un fichier « heartbeat » par worker, et son socket de contrôle).
- `emptyDir` : un dossier vide, créé avec le pod et **détruit avec lui**.
- `medium: Memory` : ce dossier est en **RAM** (un tmpfs), pas sur le disque du nœud. La FAQ de Gunicorn le recommande, car des écritures sur un disque lent peuvent bloquer ses workers. Le contenu compte dans la limite mémoire du conteneur.
- `sizeLimit: 16Mi` : un plafond, largement suffisant pour quelques fichiers vides et un socket.

Résultat : tout le système de fichiers est en lecture seule, **sauf** `/tmp`, en mémoire.

### Questions probables

- _« Qui fait le load balancing ? »_ Deux niveaux : le load balancer Azure entre les nœuds, puis kube-proxy entre les pods ready du Service.
- _« Pourquoi pas d'Ingress ? »_ 2 IP publiques répondent directement au sujet, sans composant à installer. ingress-nginx n'est plus maintenu ([ADR 0004](../adr/0004-public-access-loadbalancer.md)).
- _« Comment savoir quel pod a répondu ? »_ La page affiche `Processed by container ID <nom du pod>`. Une boucle `curl` montre l'alternance entre les 2 pods. Un F5 dans le navigateur peut retomber sur le même pod, car la connexion reste ouverte (keep-alive).
- _« Pourquoi un HPA sur Poll et pas sur Result ? »_ Chaque vote est une requête courte : plus de pods, c'est plus de capacité. Result, lui, garde des WebSockets ouverts (#33, [ADR 0008](../adr/0008-result-deployment.md)).
- _« Pourquoi `/tmp` en mémoire ? »_ Pour garder le système de fichiers en lecture seule tout en laissant Gunicorn écrire ses fichiers, sans dépendre de la vitesse du disque.

---

## 8. `k8s/result.yaml`, ligne par ligne

Même structure que Poll, mais **2 replicas fixes** (pas de HPA), la même stratégie, la sysctl pour le port 80 et le système de fichiers en lecture seule. Différences :

### Le Service public (LoadBalancer)

Même bloc que Poll (partie 7), avec `name: result` et le selector `app.kubernetes.io/name: result`. Azure lui donne une **deuxième IP publique**.

Le load balancer Azure travaille en **couche 4** (TCP) : il fait suivre les connexions telles quelles, sans lire le HTTP. La WebSocket de Result passe donc sans aucun réglage. Vérifié depuis Internet : la requête d'ouverture répond `101 Switching Protocols`, et dans un navigateur, un vote sur Poll fait bouger les scores sans recharger la page.

Un vote peut atteindre un pod Poll et ses scores s'afficher via n'importe quel pod Result : chaque pod Result relit lui-même Postgres chaque seconde.

### Arrêt propre (comme Poll, partie 7) : `preStop` et délai de grâce

```yaml
    spec:
      terminationGracePeriodSeconds: 30
      containers:
        - …
          lifecycle:
            preStop:
              sleep:
                seconds: 5
```

Quand un pod doit s'arrêter (rollout, drain, suppression), Kubernetes fait **deux choses en parallèle** : il le retire des endpoints du Service, et il lance son arrêt. Sans précaution, l'app peut fermer avant que tous les nœuds aient arrêté de lui envoyer du trafic, d'où quelques erreurs.

1. `preStop` → `sleep: 5` : le kubelet **attend 5 s** avant d'envoyer `SIGTERM`. Pendant ce temps, l'app sert normalement, et le retrait des endpoints a le temps de se propager. `sleep` est intégré à Kubernetes : aucun binaire n'est nécessaire dans l'image.
2. Puis `SIGTERM` : Result arrête d'accepter des connexions, termine les requêtes en cours, et s'arrête au plus tard après 10 s (`server.js`).
3. `terminationGracePeriodSeconds: 30` : le délai **total**, compté depuis le début du `preStop`. Au-delà, le kubelet envoie `SIGKILL`. 5 s + 10 s, plus une marge : 30 s.

### Répartition sur les nœuds (comme Poll, partie 7)

```yaml
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          topologyKey: kubernetes.io/hostname
          matchLabelKeys: ['pod-template-hash']
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: result
```

- `podAntiAffinity` : « évite les nœuds qui ont déjà un pod qui correspond à `labelSelector` ».
- `topologyKey: kubernetes.io/hostname` : l'unité de répartition est le **nœud** (chaque nœud a un nom d'hôte différent).
- `preferred…` + `weight: 100` : c'est une **préférence**, pas une obligation. Pendant un rollout, le 3e pod (surge) doit pouvoir se placer alors qu'il n'y a que 2 nœuds. Avec `required…`, il resterait `Pending` et bloquerait la mise à jour.
- `IgnoredDuringExecution` : la règle ne s'applique qu'au placement. Un pod déjà lancé n'est jamais déplacé.
- `matchLabelKeys: ['pod-template-hash']` : ne compter que les pods de **la même version**. Sans ça (constaté sur AKS), pendant un rollout, les anciens pods présents sur les 2 nœuds « occupent » les 2 nœuds, la préférence ne sert plus à rien, et les 2 nouveaux pods finissaient sur le même nœud.

### Uniquement Postgres

```yaml
envFrom:
  - configMapRef:
      name: app-config
env:
  - name: POSTGRES_PASSWORD
    valueFrom:
      secretKeyRef: { name: app-secrets, key: POSTGRES_PASSWORD }
```

Result lit Postgres. Il reçoit `REDIS_HOST` via `envFrom`, sans s'en servir.

### L'utilisateur

```yaml
securityContext:
  runAsNonRoot: true
```

Pas de `runAsUser` : l'image tourne déjà en `USER 1000` (`node`), et `runAsNonRoot` vérifie simplement que ce n'est pas root.

### Les probes

- `/healthz` (liveness) : le process Node répond.
- `/readyz` (readiness) : le process répond **et** Postgres répond à `SELECT 1`. Si Postgres devient injoignable, les 2 pods Result sortent du trafic. La liveness, elle, reste OK : ce n'est **pas** Kubernetes qui les redémarre. En revanche, si la connexion déjà ouverte est coupée (Postgres redémarre), le code de Result fait `process.exit(1)` et le conteneur redémarre de lui-même (vu sur AKS : `RESTARTS 1` sur les 2 pods après un redémarrage de Postgres).

### Pas de volume

Result n'écrit rien, même pas dans `/tmp`. `readOnlyRootFilesystem: true` suffit, sans `emptyDir`.

### Le temps réel (WebSocket)

Le navigateur ouvre une **WebSocket** vers un pod Result, qui lui pousse les scores chaque seconde. Chaque pod interroge Postgres une fois par seconde, quel que soit le nombre de visiteurs.

Pendant une mise à jour, les WebSockets ouvertes sur un pod qui s'arrête sont coupées. Le navigateur (socket.io) se **reconnecte tout seul** à un autre pod. Le client n'utilise que le transport WebSocket, donc pas besoin de « sticky sessions ».

Result gère aussi `SIGTERM` proprement : il arrête d'accepter des connexions, termine les requêtes en cours, et s'arrête au plus tard après 10 s.

### Questions probables

- _« Pourquoi Result n'a pas de HPA ? »_ Sa charge ne grandit presque pas avec les visiteurs (une requête par seconde par pod). Et un nouveau pod ne récupère que les nouveaux visiteurs, puisque les WebSockets existantes restent sur leur pod.
- _« Que voit l'utilisateur pendant une mise à jour de Result ? »_ Sa WebSocket se coupe, puis se reconnecte automatiquement à un pod disponible. Avec `maxUnavailable: 0`, il y en a toujours au moins 2.
- _« Pourquoi pas de `runAsUser` ? »_ L'image définit déjà `USER 1000`. `runAsNonRoot` garantit seulement que ce n'est pas root.

---

## 8 bis. `k8s/pdb.yaml`, ligne par ligne

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: poll
  labels:
    app.kubernetes.io/name: poll
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: poll
```

Le même pour `result`, séparé par `---`.

- `policy/v1` : le groupe d'API des règles de disruption.
- `selector` : les pods concernés, ici les pods Poll.
- `minAvailable: 1` : au moins **1** pod Poll doit rester disponible pendant une **perturbation volontaire**.

**Volontaire** = demandée : `kubectl drain`, mise à jour des nœuds par AKS. `drain` passe par l'API d'éviction, qui **refuse** une éviction qui ferait passer sous `minAvailable`. `drain` réessaie alors toutes les 5 s, jusqu'à ce qu'un remplaçant soit prêt ailleurs.

**Ce que le PDB ne protège pas** : une panne de nœud ou un `OOMKilled`, qui ne sont pas des évictions.

**Pourquoi seulement Poll et Result** : Redis, Postgres et le worker n'ont qu'un replica. `minAvailable: 1` bloquerait **tous** les drains pour toujours (on le voit avec les PDB d'AKS sur `coredns` et `metrics-server` : `Cannot evict pod as it would violate the pod's disruption budget`, puis nouvel essai).

Le PDB est complémentaire de la stratégie `maxUnavailable: 0`, qui ne s'applique **qu'aux rollouts**, pas aux évictions.

### Questions probables

- _« Différence entre `maxUnavailable` (stratégie) et un PDB ? »_ La stratégie protège les **mises à jour** du Deployment. Le PDB protège les **évictions** (drain, mise à jour de nœuds).
- _« Pourquoi pas de PDB sur Postgres ? »_ Avec 1 replica, il bloquerait tous les drains. Sa coupure pendant un drain est assumée et documentée.

---

## 8 ter. `k8s/network-policies.yaml`, ligne par ligne

Une NetworkPolicy est un pare-feu entre pods, écrit avec des **labels** au lieu d'adresses IP. Le fichier contient 7 objets séparés par `---`.

**Prérequis** : un moteur dans le cluster. Sans moteur, l'API accepte les objets et **rien n'est filtré**. Le nôtre est Cilium ([ADR 0025](../adr/0025-network-policies.md)) : un pod `cilium` par nœud applique les règles dans le noyau (eBPF), et remplace `kube-proxy`.

### Tout fermer

```yaml
kind: NetworkPolicy
metadata:
  name: default-deny
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
```

- `podSelector: {}` : **tous** les pods du namespace.
- `policyTypes: [Ingress, Egress]` sans aucune règle : rien n'entre, rien ne sort.

La règle à retenir : les policies **s'additionnent**. Un pod visé par au moins une policy n'accepte que ce qu'une de ses policies autorise. Il n'y a pas de règle « interdire » : on ferme en sélectionnant le pod, on ouvre en ajoutant une règle.

### Le DNS

```yaml
podSelector: {}
policyTypes:
  - Egress
egress:
  - to:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: kube-system
        podSelector:
          matchLabels:
            k8s-app: kube-dns
    ports:
      - port: 53
        protocol: UDP
      - port: 53
        protocol: TCP
```

- Sans elle, `default-deny` bloque aussi le DNS : Poll ne trouverait plus `redis`.
- `namespaceSelector` et `podSelector` dans **le même élément** (un seul tiret) : les pods `kube-dns` **du** namespace `kube-system`. Avec un tiret devant `podSelector`, ce serait un « ou » : tout `kube-system`, ou les pods `kube-dns` de notre namespace.
- UDP **et** TCP : le DNS passe en TCP quand la réponse est grande.

### Poll (Result est pareil, avec Postgres)

```yaml
podSelector:
  matchLabels:
    app.kubernetes.io/name: poll
policyTypes:
  - Ingress
  - Egress
ingress:
  - ports:
      - port: 80
        protocol: TCP
egress:
  - to:
      - podSelector:
          matchLabels:
            app.kubernetes.io/name: redis
    ports:
      - port: 6379
        protocol: TCP
```

- `ingress` sans `from` : le port 80 est ouvert à tous. Le trafic public arrive par le load balancer et par n'importe quel nœud : sa source n'est pas fixe.
- `egress` : seulement vers les pods `redis`, port 6379. Internet et Postgres sont fermés.
- Il faut **les deux côtés** : l'egress de Poll vers Redis, **et** l'ingress de Redis depuis Poll. S'il en manque un, la connexion est bloquée.

### Le worker

Seulement de l'egress, vers Redis et vers Postgres. Pas de règle d'ingress : seul le kubelet l'appelle (ses probes), depuis le nœud, et ce trafic passe. Vérifié : le worker reste ready, sans redémarrage.

### Redis et Postgres

```yaml
podSelector:
  matchLabels:
    app.kubernetes.io/name: redis
policyTypes:
  - Ingress
ingress:
  - from:
      - podSelector:
          matchLabels:
            app.kubernetes.io/name: poll
      - podSelector:
          matchLabels:
            app.kubernetes.io/name: worker
    ports:
      - port: 6379
        protocol: TCP
```

- Deux éléments dans `from` (deux tirets) : poll **ou** worker.
- Pas d'egress listé : `default-deny` s'applique, Redis et Postgres ne peuvent rien appeler. Ils n'en ont pas besoin.
- Postgres : pareil, depuis worker ou result, port 5432.

### Ce qui n'est pas filtré

`kubectl exec`, `logs` et `port-forward` passent par l'API et le kubelet, pas par le réseau des pods : la sauvegarde (`pg_dump` par `exec`) marche toujours.

### Mesuré sur AKS

- Depuis un pod Poll : `redis:6379` ouvert ; `postgres:5432` et `1.1.1.1:443` en timeout. Avant les policies, les trois s'ouvraient.
- Depuis un pod Result : `postgres:5432` ouvert, `redis:6379` en timeout.
- Un pod sans label dans `bernstein` : DNS OK, tout le reste bloqué. Un pod d'un autre namespace : Redis et Postgres bloqués, `poll:80` ouvert.
- Sous `tests/zero-downtime.sh` : mise en place des policies 0 erreur sur 572 ; `rollout restart` 0 sur 1014 ; drain du nœud de Redis 0 sur 1481.
- Le passage du cluster à Cilium (une seule fois) : environ 12 min, 3 drains via un nœud temporaire. Poll 225 échecs, Result 464, pendant que Redis et Postgres changeaient de nœud.

### Questions probables

- _« Comment prouvez-vous que Poll ne peut pas joindre Postgres ? »_ Depuis le pod Poll, une connexion à `postgres:5432` part en timeout, alors que `redis:6379` répond (commande dans l'[antisèche](cheatsheet.md)).
- _« Et si le cluster de l'évaluateur n'a pas de moteur ? »_ Les policies sont acceptées et ignorées : l'app marche, mais rien n'est filtré. `DEPLOY.md` le vérifie dans ses prérequis.
- _« Pourquoi bloquer aussi l'egress ? »_ Un pod compromis ne peut ni appeler internet ni les autres namespaces.
- _« On ajoute un service, que se passe-t-il ? »_ Il est bloqué par défaut : ses connexions partent en timeout jusqu'à ce qu'on ajoute sa règle.

---

## 8 quater. `k8s/hpa.yaml`, ligne par ligne

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: poll
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: poll
  minReplicas: 2
  maxReplicas: 6
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```

- `scaleTargetRef` : l'objet dont le HPA change `replicas`, ici le Deployment `poll`.
- `minReplicas: 2` : jamais moins, pour les rollouts et les drains.
- `maxReplicas: 6` : 4 pods de plus = 200m demandés. Tout tient encore sur un seul nœud pendant un drain (1552m sur 1900m).
- `averageUtilization: 70` : 70 % de la **request** CPU, pas du nœud. La request de Poll est 50m, donc la cible est 35m par pod. Au repos, Poll consomme 2m.

**Le calcul**, toutes les 15 s : `pods voulus = arrondi au-dessus (pods actuels × utilisation mesurée / cible)`. Exemple mesuré : 2 pods à 263 % → 2 × 263 / 70 = 7,5, donc 8, plafonné à 6 (atteint en deux pas : 4, puis 6). Rien ne bouge si l'écart est sous 10 %.

**D'où vient le CPU** : metrics-server, installé par AKS dans `kube-system`. C'est lui que lit `kubectl top`.

**Le comportement par défaut** (rien d'écrit dans le fichier) :

- montée **immédiate** : jusqu'à +4 pods ou +100 % toutes les 15 s ;
- descente après **5 minutes** de recommandation plus basse : une pause courte dans le trafic ne retire pas de pods.

### Mesuré sur AKS

Charge : 4 pods busybox qui bouclent sur le Service `poll`, depuis un autre namespace (depuis `bernstein`, nos NetworkPolicies bloquent).

- Charge lancée à 18:23:10. Le HPA lit 263 % à 18:24:39 (les métriques mettent ~1,5 min). 2 → 4 pods à 18:24:54, 4 → 6 à 18:25:10.
- Drain du nœud sans Postgres avec 6 pods Poll : 3 évincés d'un coup, tout tient sur l'autre nœud.
- Charge arrêtée à 18:27:25. 6 → 5 à 18:33:40, 5 → 2 à 18:34:41 : à chaque fois 5 min après la baisse de la recommandation.
- **0 erreur sur 13 000 requêtes** d'une sonde dans le cluster, pendant toute la séquence.

### Questions probables

- _« Comment autoscalez-vous Poll ? »_ Un HPA sur le CPU, 2 à 6 pods, cible 70 % de la request. Démo : de la charge, puis `kubectl -n bernstein get hpa -w`.
- _« Pourquoi pas de HPA sur Result ? »_ Sa charge ne grandit presque pas avec le nombre de spectateurs (une requête SQL par seconde et par pod), et ses WebSockets restent sur le pod où elles se sont ouvertes ([ADR 0008](../adr/0008-result-deployment.md)).
- _« Pourquoi enlever `replicas` du Deployment ? »_ Sinon chaque `apply` remet 2 pods et se bat avec le HPA.
- _« Que se passe-t-il au-delà de 6 ? »_ Rien : les 2 nœuds ont un CPU fixe. Il faudrait un 3e nœud, donc le cluster autoscaler.

---

## 9. Scénarios : ce qui se passe quand…

Pour chaque scénario : ce que fait Kubernetes, ce que voit l'utilisateur, et ce qui reste à améliorer (avec le ticket). État décrit : `main` actuel, avec Poll et Result exposés par des Services `LoadBalancer` (#24 à #26).

### 9.1 Premier déploiement sur un cluster neuf

```bash
cp k8s/secrets.env.example k8s/secrets.env   # puis remplir POSTGRES_PASSWORD
REGISTRY=<nom>.azurecr.io scripts/deploy.sh  # build, push, déploiement, attente, URL publiques
kubectl -n bernstein get pods -w             # dans un autre terminal, pour suivre le démarrage
```

1. Le script vérifie les prérequis : sans `secrets.env` ou sans mot de passe, il s'arrête avant tout changement. Il construit et pousse les 3 images, puis Kustomize construit les 15 objets (partie 1).
2. Tout est créé **en même temps** : aucun ordre garanti.
3. Postgres attend son disque (quelques dizaines de secondes), puis initialise la base et la table `votes`.
4. Pendant ce temps, le worker affiche `Waiting for db` et Result réessaie : leur readiness est rouge.
5. Dès que Postgres et Redis répondent, tout passe au vert : `7/7` pods `Running` et `1/1` ou `2/2` ready.
6. En parallèle, Azure attribue les 2 IP publiques (environ 20 s). On les donne à l'évaluateur. **Mesuré** : depuis un clone neuf et un namespace vide, l'app est en ligne en 1 min 29 s avec les images déjà en cache dans Docker (#39), et en 2 min 11 s depuis un clone du miroir Epitech, images de base à télécharger (#100) :

```bash
kubectl -n bernstein get svc poll result   # colonne EXTERNAL-IP
```

### 9.2 Mise à jour d'une image (le test « on change le code »)

C'est **le** test noté. Par exemple, on change la couleur dans Poll :

```bash
# après la modification du code, commitée ou non (le tag devient alors <sha>-dirty-<date>)
REGISTRY=<nom>.azurecr.io tests/zero-downtime.sh --from both -- scripts/deploy.sh
```

Le tag change, donc le Pod template change, donc le Deployment crée un **nouveau ReplicaSet**. Avec `replicas: 2`, `maxSurge: 1` et `maxUnavailable: 0` :

```
t0  ancien ReplicaSet : 2 pods (servent)      nouveau : 0
t1  ancien : 2 (servent)                      nouveau : 1 (démarre, pas ready → aucun trafic)
t2  nouveau ready depuis 5 s (minReadySeconds) → compté disponible
t3  ancien : 1 pod reçoit SIGTERM et sort du Service    nouveau : 1 (sert)
t4  nouveau : 2e pod démarre … même cycle …
t5  ancien : 0                                nouveau : 2
```

- Il y a **toujours au moins 2 pods** qui servent (mesuré).
- Pendant le rollout, des rafraîchissements peuvent alterner entre l'ancienne et la nouvelle couleur : les deux versions servent en même temps. C'est normal.
- L'ancien ReplicaSet est **gardé avec 0 pod**. C'est lui qui permet le retour en arrière : `kubectl -n bernstein rollout undo deploy/poll`.

Chaque ancien pod passe d'abord **5 s en `preStop`** : il sort des endpoints tout en servant encore, puis il reçoit `SIGTERM` et termine ses requêtes (parties 7 et 8).

**Mesuré sur AKS** : requêtes en continu (toutes les 50 ms) sur les 2 IP publiques pendant `kubectl rollout restart deploy/poll deploy/result` : **0 erreur sur 2461 requêtes**. Même test avec `tests/zero-downtime.sh` (#29, [ADR 0016](../adr/0016-zero-downtime-test.md)) : 0 erreur sur 975, puis sur 1996 requêtes. Et le scénario complet de la soutenance, une modification non commitée de Poll déployée avec `scripts/deploy.sh` : en ligne en 52 s, **0 erreur sur 1225 requêtes** ([ADR 0017](../adr/0017-deploy-script.md)).

**Piège** : lancer le test depuis la machine qui pousse les images fausse la mesure si le push est gros. Au premier déploiement (3 images neuves), l'upload a saturé la connexion : 2 timeouts pendant le push, aucun pendant le rollout. Une modification de code ne pousse qu'une petite couche, donc pas de souci en soutenance.

**Autre piège, mesuré (#100)** : une connexion domestique faible perd des connexions même sans déploiement (0,2 à 1,6 % de timeouts au repos), alors qu'une sonde dans le cluster ne voyait aucune erreur sur 11 500 requêtes. Toujours lancer d'abord `DURATION=60 tests/zero-downtime.sh` sans rien déployer : il doit passer. Et lancer le test noté avec `--from both` : les mêmes requêtes partent aussi d'un pod dans le cluster (lignes `poll@cluster`, `result@cluster`). Une erreur vue seulement depuis la machine vient du réseau ou du load balancer Azure, pas des pods (#107).

### 9.2 bis Une mise à jour cassée (la nouvelle version ne démarre pas)

Rien ne coupe. Avec `maxUnavailable: 0`, Kubernetes n'arrête un ancien pod qu'une fois un nouveau ready. Le nouveau ne l'est jamais : les 2 anciens pods continuent de servir, et le pod cassé ne reçoit aucun trafic (il n'est pas dans les endpoints du Service).

```
t0       ancien : 2 pods (servent)     nouveau : 1 pod, jamais ready
…        rien ne bouge, le rollout attend
t0+2 min progressDeadlineSeconds dépassé → Progressing=False, reason ProgressDeadlineExceeded
```

Testé sur AKS (#108) avec Poll, et une sonde dans le cluster qui interroge Poll et Result en boucle : **0 erreur** dans les 3 cas.

| Panne                          | Statut du nouveau pod | Pourquoi                                          |
| ------------------------------ | --------------------- | ------------------------------------------------- |
| tag d'image qui n'existe pas   | `ImagePullBackOff`    | le nœud ne trouve pas l'image                     |
| le conteneur sort au démarrage | `CrashLoopBackOff`    | relancé avec un délai croissant (4 fois en 100 s) |
| Poll ne joint pas Redis        | `Running`, `0/1`      | la readiness (`/readyz`) échoue                   |

- **`progressDeadlineSeconds: 120`** : après 2 min sans progrès, Kubernetes marque le rollout en échec. Le défaut est 600 s. Nos pods démarrent en 1 à 13 s, plus ~20 s de pull d'image au pire : 2 min laisse de la marge.
- Kubernetes **ne fait rien d'autre** : il signale, il ne revient pas en arrière ([doc Deployment](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#failed-deployment)). Si le pod finit par devenir ready, le rollout se termine.
- `kubectl rollout status` sort alors en erreur (`exceeded its progress deadline`). `scripts/deploy.sh` s'arrête, nomme le Deployment et affiche les commandes de retour arrière.
- **Pas de rollback automatique dans le script non plus** : les anciens pods servent, rien ne presse. On lit d'abord la cause (`describe` du nouveau pod), puis on choisit : corriger et redéployer, `rollout undo`, ou `TAG=<bon tag>` ([ADR 0017](../adr/0017-deploy-script.md)).
- Avec `TAG=`, le script vérifie d'abord que les 3 images existent dans l'ACR : un tag mal tapé s'arrête avant tout changement.

**Mesuré** : Poll cassé déployé avec `scripts/deploy.sh` : échec après 2 min, avec le message. Puis `TAG=<tag précédent>` : Poll revenu en ~16 s, pod cassé supprimé. 0 erreur dans le cluster.

### 9.3 Changement de config ou de mot de passe

On modifie une valeur dans `app-config` ou dans `secrets.env`, puis on redéploie sans rebuild : `REGISTRY=<nom>.azurecr.io TAG=<tag actuel> scripts/deploy.sh`. Le tag actuel se lit avec `kubectl -n bernstein get deploy poll -o jsonpath='{..image}'`. `kubectl apply -k k8s/` seul remettrait des images sans registry.

- Le **hash** du ConfigMap ou du Secret change, donc son nom change. Les Pod templates qui le référencent changent aussi, et **tous les consommateurs** font un rolling update.
- Pour `app-config` : poll, worker, result, **et postgres** (il lit `POSTGRES_DB` et `POSTGRES_USER`). Postgres a 1 seul pod, donc il est arrêté puis recréé : une coupure courte de la base.
- **Attention au mot de passe Postgres** : il n'est lu qu'à la **création** de la base. Le changer dans `secrets.env` ne change **pas** le mot de passe de la base existante. Les apps enverraient alors le nouveau, et seraient refusées. Il faut aussi le changer dans Postgres (`ALTER USER postgres PASSWORD '…'`).
- Les anciens ConfigMaps et Secrets (avec l'ancien hash) restent dans le cluster. C'est sans effet, mais on peut les supprimer à la main.

### 9.4 Un pod plante ou est supprimé

| Pod supprimé | Qui le recrée          | Délai mesuré                                     | Effet visible                                                                               |
| ------------ | ---------------------- | ------------------------------------------------ | ------------------------------------------------------------------------------------------- |
| 1 pod poll   | ReplicaSet             | quelques s                                       | Aucun : l'autre pod sert                                                                    |
| 1 pod result | ReplicaSet             | quelques s                                       | Les WebSockets de ce pod se reconnectent à l'autre                                          |
| worker       | ReplicaSet             | quelques s                                       | Les votes attendent dans Redis, puis sont traités                                           |
| redis        | ReplicaSet             | ~4 s                                             | **Poll indisponible** pendant ce temps (sa readiness dépend de Redis). Votes en file perdus |
| postgres-0   | StatefulSet (même nom) | secondes à 1 min (plus long s'il change de nœud) | Result indisponible, le worker attend. **Données conservées** (même disque)                 |

Un conteneur qui **plante** (process qui s'arrête) est redémarré sur place par le kubelet, dans le même pod : la colonne `RESTARTS` augmente. S'il plante en boucle, l'attente entre deux redémarrages augmente (`CrashLoopBackOff`, jusqu'à 5 minutes).

### 9.5 `kubectl drain` d'un nœud (question classique)

```bash
kubectl drain <nœud> --ignore-daemonsets --delete-emptydir-data
```

1. Le nœud est marqué « non planifiable » (`cordon`) : plus aucun nouveau pod n'y arrive.
2. Tous ses pods sont **évincés**. Leurs contrôleurs les recréent sur l'autre nœud.
3. Postgres : le disque Azure est détaché du nœud drainé et rattaché à l'autre, ce qui prend 1 à 2 minutes.

Ce qui protège Poll et Result :

- **Anti-affinity** : 1 pod de chaque par nœud, donc un drain n'en évince qu'un par app.
- **PDB** (`minAvailable: 1`) : même si les 2 pods étaient sur le nœud, `drain` attendrait qu'un remplaçant soit prêt ailleurs avant d'évincer le second.
- **`preStop`** : chaque pod évincé sort du trafic avant de s'arrêter.

**Mesuré sur AKS**, avec des requêtes en continu sur les 2 IP publiques :

| Nœud drainé                              | Poll     | Result                        |
| ---------------------------------------- | -------- | ----------------------------- |
| 1 Poll + 1 Result + le worker            | 0 erreur | 0 erreur (2221 requêtes, 8 s) |
| 1 Poll + 1 Result + **Redis + Postgres** | 0 erreur | **47 échecs pendant 39 s**    |

Le 2e cas est la limite connue : Postgres n'a qu'**un** replica. Pendant que son disque Azure change de nœud, les 2 pods Result sont non ready (leur `/readyz` dépend de la base), et le Service n'a plus de destination. Poll, lui, tient : Redis est revenu avant que sa readiness ne bascule. Seule une base répliquée réglerait ce cas ([ADR 0007](../adr/0007-postgres-statefulset.md)).

Pour remettre le nœud en service : `kubectl uncordon <nœud>`. Les pods ne reviennent pas tout seuls dessus : seuls les **nouveaux** pods y seront placés.

### 9.6 Une dépendance tombe

| Composant en panne | Poll                                        | Worker                               | Result                       |
| ------------------ | ------------------------------------------- | ------------------------------------ | ---------------------------- |
| **Redis**          | Non ready, page indisponible                | Erreur, il redémarre et attend Redis | Fonctionne (scores figés)    |
| **Postgres**       | Fonctionne, les votes s'empilent dans Redis | Non ready, attend la base            | Non ready, page indisponible |
| **Worker**         | Fonctionne                                  | —                                    | Fonctionne (scores figés)    |

Après un redémarrage de Postgres, le worker est redémarré par sa liveness et redevient ready en environ 1 minute, sans intervention (partie 6). Aucun vote n'est perdu.

### 9.7 Monter en charge (scale)

Automatique pour Poll : le HPA passe de 2 à 6 pods selon le CPU (partie 8 quater). **Mesuré** : 2 → 6 pods en 2 minutes après le début de la charge, retour à 2 environ 7 minutes après la fin, 0 erreur.

À la main :

```bash
kubectl -n bernstein scale deploy/result --replicas=4
```

- 2 pods de plus sont créés. Le Service les ajoute à la répartition dès qu'ils sont ready.
- **Attention** : le prochain déploiement remet `replicas: 2`, la valeur du fichier. Sur Poll, `scale` ne sert à rien : le HPA reprend la main à son passage suivant (toutes les 15 s).
- Les nœuds : 2 aujourd'hui, fixes. Le HPA ajoute des pods, pas du CPU. Un 3e nœud demanderait le cluster autoscaler (quota étudiant de 6 vCPU, [ADR 0026](../adr/0026-poll-hpa.md)).

### 9.8 Arrêt et redémarrage du cluster (`az aks stop` / `start`)

- `stop` : les VM sont arrêtées (plus de facturation du calcul). Les objets Kubernetes, la PVC et le disque sont **conservés**.
- `start` : les nœuds sont **nouveaux** (noms différents), et tous les pods sont recréés. Postgres retrouve son disque et ses votes.
- L'adresse du serveur API peut changer : il faut refaire `az aks get-credentials`.
- Le disque Azure reste facturé même cluster arrêté (quelques centimes par mois pour 1 Gi).
- **Coût mesuré** (Cost Management, [ADR 0001](../adr/0001-aks-cluster.md#cost)) : **0,47 € par jour arrêté**, plus **environ 0,2 € par heure allumé** (les nœuds et leurs disques OS). Arrêté, restent facturés les 3 IP publiques (0,32 €/jour), le registry (0,15 €) et le disque Postgres. Le load balancer est gratuit dans l'offre étudiante. Les disques OS partent avec les nœuds : aucun coût de disque OS les jours arrêtés.
- Les Services `poll` et `result` existent toujours, et leurs IP publiques sont **conservées** : vérifié à chaque `start` sur notre cluster, sans garantie écrite de Microsoft. Azure les range dans le groupe de ressources du cluster (`MC_…`), où nos comptes n'ont pas le droit de lecture. En revanche, supprimer le namespace libère les IP : le déploiement suivant en reçoit de nouvelles (vu dans #39).

### 9.9 Tout supprimer

```bash
kubectl delete -k k8s/
```

Supprime le namespace, donc **tout**, y compris la PVC. La classe de stockage `default` a `reclaimPolicy: Delete` : le disque Azure est supprimé, et **les votes sont perdus**. Pour garder les données, il faut supprimer les objets un par un, sans la PVC. Les 2 IP publiques sont aussi libérées : un nouveau déploiement en recevra d'autres.

### 9.10 Commandes utiles pendant la soutenance

| Besoin                                      | Commande                                                                         |
| ------------------------------------------- | -------------------------------------------------------------------------------- |
| Voir tous nos objets                        | `kubectl -n bernstein get all`                                                   |
| Les IP publiques de Poll et Result          | `kubectl -n bernstein get svc poll result`                                       |
| Voir sur quel nœud tourne chaque pod        | `kubectl -n bernstein get pods -o wide`                                          |
| Pourquoi un pod ne démarre pas              | `kubectl -n bernstein describe pod <pod>` (section `Events`)                     |
| Logs d'un pod (et du précédent)             | `kubectl -n bernstein logs <pod>` / `--previous`                                 |
| Suivre un rollout                           | `kubectl -n bernstein rollout status deploy/poll`                                |
| Historique et retour arrière                | `kubectl -n bernstein rollout history deploy/poll` / `rollout undo …`            |
| Relancer les pods sans changer l'image      | `kubectl -n bernstein rollout restart deploy/poll`                               |
| Vers quels pods pointe un Service           | `kubectl -n bernstein get endpointslices -l kubernetes.io/service-name=redis`    |
| Voir le rendu sans rien appliquer           | `kubectl kustomize k8s/`                                                         |
| Comparer avec ce qui tourne                 | `kubectl diff -k .deploy`                                                        |
| Consommation CPU et mémoire                 | `kubectl -n bernstein top pods`                                                  |
| Tester un pod sans passer par l'IP publique | `kubectl -n bernstein port-forward deploy/poll 8080:80`                          |
| Ajouter des outils dans un pod (debug)      | `kubectl -n bernstein debug <pod> -it --image=busybox:1.37 --profile=restricted` |

`.deploy/` est l'overlay écrit par le dernier `scripts/deploy.sh`, avec les images de notre registry. `kubectl diff -k k8s/` afficherait une fausse différence sur chaque image : la base ne nomme aucun registry (vérifié sur AKS).
