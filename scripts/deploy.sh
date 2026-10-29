#!/usr/bin/env bash
# One-command delivery: build the app images the registry does not have yet, push them
# to a private registry, deploy k8s/ with those images and wait until everything is ready.
# Written for bash 3.2+ (macOS default).

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: REGISTRY=<name>.azurecr.io scripts/deploy.sh [--push-only]

Builds poll, worker and result when REGISTRY does not have their tag yet, pushes
them, deploys k8s/ to the current kubectl cluster with those images, waits for
the rollouts, then prints the public URLs of Poll and Result. Run it again after
a code change: only the apps whose code changed roll out (zero downtime).

--push-only stops after the push: no cluster, no k8s/secrets.env needed. CI runs
it on every push to main, so the registry already holds the images to deploy.

Before the first run:
  cp k8s/secrets.env.example k8s/secrets.env   # then set the 3 database passwords
  az login && az aks get-credentials -g <resource-group> -n <cluster>
  The cluster must be allowed to pull from REGISTRY (az aks update --attach-acr).

Image tags, one per app: the short SHA of the last commit that changed
poll-application/<app>, plus "-dirty-<date>" when that folder has uncommitted
changes. A code change gives its app a new tag and a rollout; the other apps
keep their tag and are left unchanged.

Environment:
  REGISTRY   required. ACR login server (<name>.azurecr.io) or any registry you
             already ran `docker login` for.
  TAG        deploy this existing tag for the 3 apps instead of building.
  POLL_TAG, WORKER_TAG, RESULT_TAG
             deploy this existing tag for one app (e.g. a known-good tag to roll
             back). It wins over TAG. A given tag is never built: it must exist.
  PLATFORM   image platform, default linux/amd64 (the AKS nodes).

Exit code: 0 deployed (or pushed), 1 a build, push or deploy step failed, 2 missing
prerequisite.
EOF
}

PUSH_ONLY=0
case ${1:-} in
  -h | --help)
    usage
    exit 0
    ;;
  --push-only) PUSH_ONLY=1 ;;
  '') ;;
  *)
    usage >&2
    exit 2
    ;;
esac

APPS="poll worker result"
NAMESPACE=bernstein
PLATFORM=${PLATFORM:-linux/amd64}
REGISTRY=${REGISTRY:-}
REGISTRY=${REGISTRY%/}

die() {
  echo "ERROR: $*" >&2
  exit 2
}

step() {
  current_step="$*"
  echo
  echo "==> $*"
}

# set -e stops the script on any failed command, even one with no `|| die` and no message.
# Name the step and the command instead. Only the main shell reports, so a failure inside $(...)
# prints one line, not two.
current_step="checks"
on_error() {
  [ "$BASH_SUBSHELL" -eq 0 ] || return 0
  echo >&2
  echo "ERROR: step \"$current_step\" failed (exit $1) at scripts/deploy.sh line $2: $3" >&2
}
set -E
trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

cd "$(dirname "$0")/.."

# --- Checks that need no cluster -------------------------------------------------
[ -n "$REGISTRY" ] || die "REGISTRY is not set. Example: REGISTRY=myregistry.azurecr.io scripts/deploy.sh"
case $REGISTRY in
  *://*) die "REGISTRY is a host name, without http:// or https:// ($REGISTRY)." ;;
esac
tools="git docker"
[ "$PUSH_ONLY" -eq 1 ] || tools="$tools kubectl"
for tool in $tools; do
  command -v "$tool" >/dev/null || die "$tool is not installed."
done
case $REGISTRY in
  *.azurecr.io) command -v az >/dev/null || die "az (Azure CLI) is not installed; it logs in to $REGISTRY." ;;
esac
if [ "$PUSH_ONLY" -eq 0 ]; then
  [ -f k8s/secrets.env ] ||
    die "k8s/secrets.env is missing. Run: cp k8s/secrets.env.example k8s/secrets.env, then set the passwords."
  for secret in POSTGRES_PASSWORD RESULT_DB_PASSWORD WORKER_DB_PASSWORD; do
    grep -Eq "^$secret=.+" k8s/secrets.env ||
      die "$secret is empty in k8s/secrets.env (see k8s/secrets.env.example)."
  done
fi

# --- Image tags ----------------------------------------------------------------------
# One tag per app: the last commit that changed its folder. An app whose code did not
# change keeps its tag, so `kubectl apply` leaves it unchanged: no rebuild, no rollout.
# Bash 3.2 has no associative arrays: tag_<app> and given_<app> are set by name.
upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }
stamp=$(date +%Y%m%d%H%M%S)
images=""
for app in $APPS; do
  override=$(upper "$app")_TAG
  tag=${!override:-${TAG:-}}
  given=1
  if [ -z "$tag" ]; then
    given=0
    tag=$(git log -1 --format=%h -- "poll-application/$app" 2>/dev/null) || true
    [ -n "$tag" ] || die "Not a git clone: cannot derive the image tag of $app. Set TAG or $override."
    if [ -n "$(git status --porcelain -- "poll-application/$app")" ]; then
      tag="$tag-dirty-$stamp"
    fi
  fi
  printf -v "tag_$app" '%s' "$tag"
  printf -v "given_$app" '%s' "$given"
  images="$images $app:$tag"
done

# Render and cluster checks: skipped by --push-only, which touches no cluster.
if [ "$PUSH_ONLY" -eq 0 ]; then
  # --- Manifests: k8s/ as is, with the registry and tag set by a generated overlay -----
  # Kustomize refuses absolute paths in resources, so the overlay sits next to k8s/.
  step "Rendering k8s/ with images from $REGISTRY:$images"
  mkdir -p .deploy
  {
    echo "# Generated by scripts/deploy.sh on every run. Not tracked by git."
    echo "apiVersion: kustomize.config.k8s.io/v1beta1"
    echo "kind: Kustomization"
    echo "resources:"
    echo "  - ../k8s"
    echo "images:"
    # Quoted: a short SHA made only of digits (9167948) would otherwise be read as a YAML number.
    for app in $APPS; do
      tag=tag_$app
      printf '  - name: %s\n    newName: "%s/%s"\n    newTag: "%s"\n' "$app" "$REGISTRY" "$app" "${!tag}"
    done
  } >.deploy/kustomization.yaml
  kubectl kustomize .deploy >/dev/null || die "kubectl kustomize .deploy failed (see above)."

  # --- Checks that need the cluster ----------------------------------------------------
  kubectl version --request-timeout=10s >/dev/null 2>&1 ||
    die "kubectl cannot reach a cluster. Run: az aks get-credentials -g <resource-group> -n <cluster>"

  # Without a NetworkPolicy engine, the API server accepts k8s/network-policies.yaml and nothing
  # enforces it (ADR 0025). The app still works: a warning, repeated at the end.
  policy_warning=""
  engines=$(kubectl get daemonsets --all-namespaces -o name 2>/dev/null) || engines="?"
  case $engines in
    "?") policy_warning="could not list the DaemonSets to check for a NetworkPolicy engine." ;;
    *daemonset.apps/cilium* | *daemonset.apps/calico-node* | *daemonset.apps/azure-npm*) ;;
    *) policy_warning="no NetworkPolicy engine found (Cilium, Calico or Azure NPM): k8s/network-policies.yaml is accepted but not enforced, so any pod can reach Redis and PostgreSQL. Enable one: doc/setup/cluster-setup.md, \"Enable the network policy engine\"." ;;
  esac
  [ -z "$policy_warning" ] || echo "WARNING: $policy_warning" >&2
fi

# --- Build and push only the images the registry does not have ---------------------
login_registry() {
  case $REGISTRY in
    *.azurecr.io)
      step "Logging in to $REGISTRY"
      az acr login --name "${REGISTRY%%.*}" ||
        die "Login to $REGISTRY failed. Run az login, and check you may push to it (AcrPush role)."
      ;;
    *) echo "Registry is not an ACR: using your existing docker login for $REGISTRY." ;;
  esac
}
# --push-only (CI) logs in first and asks the registry itself, which needs only the pull right:
# `az acr repository show` may need more than the AcrPush role of the CI identity.
[ "$PUSH_ONLY" -eq 0 ] || login_registry
image_exists() {
  case $PUSH_ONLY:$REGISTRY in
    0:*.azurecr.io) az acr repository show --name "${REGISTRY%%.*}" --image "$1:$2" -o none 2>/dev/null ;;
    *) docker manifest inspect "$REGISTRY/$1:$2" >/dev/null 2>&1 ;;
  esac
}
to_build=""
for app in $APPS; do
  tag=tag_$app
  given=given_$app
  if image_exists "$app" "${!tag}"; then
    echo "$REGISTRY/$app:${!tag} is already in the registry: not rebuilt."
  elif [ "${!given}" -eq 1 ]; then
    # A mistyped tag would leave the new pods in ImagePullBackOff: stop before applying anything.
    case $REGISTRY in
      *.azurecr.io) die "$REGISTRY/$app:${!tag} not found. List the tags: az acr repository show-tags --name ${REGISTRY%%.*} --repository $app --orderby time_desc -o table" ;;
      *) die "$REGISTRY/$app:${!tag} not found in the registry." ;;
    esac
  else
    to_build="$to_build $app"
  fi
done

if [ -n "$to_build" ]; then
  [ "$PUSH_ONLY" -eq 1 ] || login_registry
  for app in $to_build; do
    tag=tag_$app
    step "Building $REGISTRY/$app:${!tag} ($PLATFORM)"
    docker build --platform "$PLATFORM" -t "$REGISTRY/$app:${!tag}" "poll-application/$app"
  done
  for app in $to_build; do
    tag=tag_$app
    step "Pushing $REGISTRY/$app:${!tag}"
    docker push --quiet "$REGISTRY/$app:${!tag}"
  done
fi

if [ "$PUSH_ONLY" -eq 1 ]; then
  echo
  echo "In $REGISTRY:$images (built and pushed now:${to_build:- none})."
  exit 0
fi

# --- Deploy and wait -----------------------------------------------------------------
step "Applying the manifests"
kubectl apply -k .deploy

step "Waiting for the rollouts"
# A Deployment whose new pods never get Ready fails after progressDeadlineSeconds (2 min).
# Its old pods keep serving: nothing is rolled back automatically, the operator decides.
failed=""
kubectl -n "$NAMESPACE" rollout status --timeout=5m statefulset/postgres || failed=" statefulset/postgres"
if [ -z "$failed" ]; then
  # The app users (k8s/users.sh): the image creates them in a new database; this run adds them
  # to an existing one and applies a password changed in secrets.env. Idempotent.
  echo "Syncing the PostgreSQL users of Result and the worker."
  kubectl -n "$NAMESPACE" exec postgres-0 -c postgres -- sh /docker-entrypoint-initdb.d/users.sh || {
    echo "ERROR: k8s/users.sh failed in postgres-0 (see above). Result and the worker cannot log in." >&2
    exit 1
  }
fi
for resource in deployment/redis deployment/worker deployment/poll deployment/result; do
  kubectl -n "$NAMESPACE" rollout status --timeout=5m "$resource" || failed="$failed $resource"
done
if [ -n "$failed" ]; then
  echo >&2
  echo "ERROR: rollout not finished:$failed. The previous pods keep serving." >&2
  echo "  Why:       kubectl -n $NAMESPACE get pods, then describe the new pod (DEPLOY.md, Debug a broken pod)" >&2
  for resource in $failed; do
    echo "  Roll back: kubectl -n $NAMESPACE rollout undo $resource" >&2
    case $resource in
      deployment/poll | deployment/worker | deployment/result)
        echo "         or: REGISTRY=$REGISTRY $(upper "${resource#deployment/}")_TAG=<good tag> scripts/deploy.sh" >&2
        ;;
    esac
  done
  exit 1
fi

# A new LoadBalancer Service takes a minute or two to get its public IP.
step "Waiting for the public IPs"
ip_of() {
  kubectl -n "$NAMESPACE" get service "$1" -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
}
i=0
until [ -n "$(ip_of poll)" ] && [ -n "$(ip_of result)" ]; do
  i=$((i + 1))
  [ "$i" -le 60 ] || {
    echo "No public IP after 5 minutes. Check: kubectl -n $NAMESPACE get service poll result" >&2
    exit 1
  }
  sleep 5
done

echo
echo "Deployed$images."
echo "  Poll:   http://$(ip_of poll)/"
echo "  Result: http://$(ip_of result)/"
if [ -n "$policy_warning" ]; then
  echo >&2
  echo "WARNING: $policy_warning" >&2
fi
