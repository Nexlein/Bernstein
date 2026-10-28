#!/usr/bin/env bash
# Zero-downtime test: requests Poll and Result continuously and fails on any error.
# Written for bash 3.2+ (macOS default) and curl; no other tool needed.
# `--from cluster` also needs kubectl: the requests then come from a pod.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: tests/zero-downtime.sh [--from here|cluster|both] [POLL_URL RESULT_URL] [-- COMMAND...]

Sends GET requests to Poll and Result in parallel loops, prints every error as it
happens, then a summary per app. An error is a non-2xx status or a curl failure
(connection refused or reset, timeout).

  Without COMMAND  runs for DURATION seconds: start the update from another terminal.
  With COMMAND     starts the requests, runs COMMAND (a rollout, a deploy script),
                   keeps requesting SETTLE seconds after it ends, then stops.
                   COMMAND must wait for the rollout: `kubectl rollout restart`
                   alone returns at once, so add `kubectl rollout status`.
  Without URLs     uses the EXTERNAL-IP of the poll and result Services (kubectl).
                   The URLs only apply to the requests from here.

  --from here      default: the requests leave this machine, through its network
                   and the public load balancer.
  --from cluster   the same requests from a pod (curl image) in the namespace
                   zero-downtime, to the poll and result Services: no client
                   network in the way. The pod is deleted at the end.
  --from both      both at once, with one summary line per app and source: an
                   error seen only from here comes from the network or the load
                   balancer, not from the pods.

Examples:
  tests/zero-downtime.sh
  tests/zero-downtime.sh --from both -- scripts/deploy.sh
  tests/zero-downtime.sh -- sh -c 'kubectl -n bernstein rollout restart deploy/poll deploy/result &&
    kubectl -n bernstein rollout status deploy/poll deploy/result'
  tests/zero-downtime.sh http://localhost:5000/ http://localhost:5001/

Environment: DURATION=120  SETTLE=15  CONCURRENCY=2 (loops per app)  TIMEOUT=5 (seconds
per request)  NAMESPACE=bernstein  CURL_IMAGE=curlimages/curl:8.23.0 (--from cluster)

Exit code: 0 no error (and COMMAND succeeded), 1 errors or COMMAND failed,
2 bad usage, an app not answering before the test, or the test pod not starting.
EOF
}

DURATION=${DURATION:-120}
SETTLE=${SETTLE:-15}
CONCURRENCY=${CONCURRENCY:-2}
TIMEOUT=${TIMEOUT:-5}
NAMESPACE=${NAMESPACE:-bernstein}
CURL_IMAGE=${CURL_IMAGE:-curlimages/curl:8.23.0}
# Not `bernstein`: its NetworkPolicies deny every flow they do not list, a test client included.
PROBE_NAMESPACE=zero-downtime
for setting in DURATION SETTLE CONCURRENCY TIMEOUT; do
  case ${!setting} in
    '' | *[!0-9]*)
      echo "$setting must be a whole number, got '${!setting}'." >&2
      exit 2
      ;;
  esac
done
if [ "$CONCURRENCY" -lt 1 ]; then
  echo "CONCURRENCY must be at least 1." >&2
  exit 2
fi

from=here
urls=()
cmd=()
while [ $# -gt 0 ]; do
  case $1 in
    -h | --help)
      usage
      exit 0
      ;;
    --from)
      [ $# -ge 2 ] || {
        usage >&2
        exit 2
      }
      from=$2
      shift 2
      ;;
    --from=*)
      from=${1#--from=}
      shift
      ;;
    --)
      shift
      cmd=("$@")
      break
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      urls+=("$1")
      shift
      ;;
  esac
done
case $from in
  here | cluster | both) ;;
  *)
    echo "--from must be here, cluster or both, got '$from'." >&2
    exit 2
    ;;
esac

# Public URL of a LoadBalancer Service (IP on Azure, hostname on some other clouds).
service_url() {
  local host
  host=$(kubectl -n "$NAMESPACE" get service "$1" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null) || true
  if [ -z "$host" ]; then
    echo "No EXTERNAL-IP for Service $1 in namespace $NAMESPACE. Pass the two URLs as arguments." >&2
    exit 2
  fi
  echo "http://$host/"
}

case ${#urls[@]} in
  0)
    if [ "$from" != cluster ]; then
      poll_url=$(service_url poll)
      result_url=$(service_url result)
    fi
    ;;
  2)
    poll_url=${urls[0]}
    result_url=${urls[1]}
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

# Human-readable cause of a failed request: HTTP status, or curl's exit code.
describe() {
  case $2 in
    0) echo "HTTP $1" ;;
    7) echo "connection refused (curl exit 7)" ;;
    28) echo "timeout after ${TIMEOUT}s (curl exit 28)" ;;
    52) echo "empty reply (curl exit 52)" ;;
    56) echo "connection reset (curl exit 56)" ;;
    *) echo "curl exit $2" ;;
  esac
}

# Fails fast if an app is already down: the rollout must not be blamed for it.
if [ "$from" != cluster ]; then
  for target in "poll $poll_url" "result $result_url"; do
    app=${target%% *}
    url=${target#* }
    code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time "$TIMEOUT" "$url") || true
    case $code in
      2[0-9][0-9]) ;;
      *)
        echo "$app ($url) answers $code before the test starts. Nothing to measure." >&2
        exit 2
        ;;
    esac
  done
fi

dir=$(mktemp -d "${TMPDIR:-/tmp}/zero-downtime.XXXXXX")
stop_file="$dir/stop"
interrupted=0
pod=""
follower=""
cleanup() {
  touch "$stop_file"
  [ -z "$follower" ] || kill "$follower" 2>/dev/null || true
  if [ -n "$pod" ]; then
    kubectl -n "$PROBE_NAMESPACE" delete pod "$pod" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
}
trap 'interrupted=1' INT TERM
trap cleanup EXIT

# --- Requests from a pod (--from cluster|both) ---------------------------------------
# The same loop as worker() below, in POSIX sh for the curl image. "READY" once both
# Services answer, then one line per request: "app@cluster epoch http_code time_total curl_exit".
# shellcheck disable=SC2016 # expanded by the pod's shell, not here
pod_script='
poll=$1 result=$2 concurrency=$3 timeout=$4
for url in "$poll" "$result"; do
  code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 --max-time "$timeout" "$url")
  case $code in 2??) ;; *) echo "NOT_READY $url answers $code"; exit 1 ;; esac
done
echo READY
loop() {
  while :; do
    rc=0
    out=$(curl -s -o /dev/null -w "%{http_code} %{time_total}" --connect-timeout 2 --max-time "$timeout" "$2") || rc=$?
    echo "$1@cluster $(date +%s) ${out:-000 0} $rc"
    sleep 0.05
  done
}
i=1
while [ "$i" -le "$concurrency" ]; do
  loop poll "$poll" &
  loop result "$result" &
  i=$((i + 1))
done
wait
'

start_pod() {
  command -v kubectl >/dev/null || {
    echo "--from $from needs kubectl." >&2
    exit 2
  }
  pod=zero-downtime-$(date +%Y%m%d%H%M%S)
  # The namespace enforces the "restricted" Pod Security Standard, like ours; the pod complies.
  # activeDeadlineSeconds: if this script is killed before its cleanup, the pod stops after 1 h.
  if ! kubectl apply -f - >/dev/null <<EOF; then
apiVersion: v1
kind: Namespace
metadata:
  name: $PROBE_NAMESPACE
  labels:
    pod-security.kubernetes.io/enforce: restricted
---
apiVersion: v1
kind: Pod
metadata:
  name: $pod
  namespace: $PROBE_NAMESPACE
  labels:
    app.kubernetes.io/name: zero-downtime
spec:
  restartPolicy: Never
  activeDeadlineSeconds: 3600
  terminationGracePeriodSeconds: 1
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 100
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: curl
      image: $CURL_IMAGE
      command:
        - sh
        - -c
        - |
$(printf '%s\n' "$pod_script" | sed 's/^/          /')
        - sh
      args:
        - 'http://poll.$NAMESPACE/'
        - 'http://result.$NAMESPACE/'
        - '$CONCURRENCY'
        - '$TIMEOUT'
      resources:
        requests:
          cpu: 100m
          memory: 32Mi
        limits:
          cpu: 500m
          memory: 64Mi
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ['ALL']
EOF
    echo "Cannot create the test pod in namespace $PROBE_NAMESPACE (see above)." >&2
    exit 2
  fi

  # Image pull and the pod's own check of both Services: up to 2 minutes.
  local i=0 first
  while :; do
    first=$(kubectl -n "$PROBE_NAMESPACE" logs "$pod" 2>/dev/null | head -1) || true
    case $first in
      READY) break ;;
      NOT_READY*)
        echo "From the cluster: ${first#NOT_READY }. Nothing to measure." >&2
        exit 2
        ;;
    esac
    [ "$interrupted" -eq 0 ] || exit 2
    i=$((i + 1))
    if [ "$i" -gt 120 ]; then
      echo "Test pod $PROBE_NAMESPACE/$pod not ready after ${i}s:" >&2
      kubectl -n "$PROBE_NAMESPACE" get pod "$pod" >&2 || true
      exit 2
    fi
    sleep 1 || true
  done

  # Prints the pod's errors as they happen; the counts come from its full log at the end.
  kubectl -n "$PROBE_NAMESPACE" logs -f "$pod" 2>/dev/null |
    while read -r app _ code _ rc; do
      case "$app:$rc:$code" in
        *@cluster:0:2[0-9][0-9]) ;;
        *@cluster:*) echo "$(date +%H:%M:%S) $app ERROR $(describe "$code" "$rc")" >&2 ;;
      esac
    done &
  follower=$!
}

# One request loop. Logs "app epoch http_code time_total curl_exit" per request.
# Each request is a new curl, so a new TCP connection: the case where a stopping pod shows.
worker() {
  local app=$1 url=$2 log=$3 out rc code
  while [ ! -e "$stop_file" ]; do
    rc=0
    out=$(curl -s -o /dev/null -w '%{http_code} %{time_total}' \
      --connect-timeout 2 --max-time "$TIMEOUT" "$url") || rc=$?
    code=${out%% *}
    echo "$app $(date +%s) ${out:-000 0} $rc" >>"$log"
    case "$rc:$code" in
      0:2[0-9][0-9]) ;;
      *) echo "$(date +%H:%M:%S) $app ERROR $(describe "$code" "$rc")" >&2 ;;
    esac
    sleep 0.05
  done
}

apps=""
if [ "$from" != here ]; then
  start_pod
  apps="poll@cluster result@cluster"
  echo "Requesting Poll and Result from the cluster (pod $PROBE_NAMESPACE/$pod), $CONCURRENCY loops each."
fi

pids=()
if [ "$from" != cluster ]; then
  i=1
  while [ "$i" -le "$CONCURRENCY" ]; do
    worker poll "$poll_url" "$dir/poll.$i.log" &
    pids+=($!)
    worker result "$result_url" "$dir/result.$i.log" &
    pids+=($!)
    i=$((i + 1))
  done
  apps="poll result $apps"
  echo "Requesting Poll ($poll_url) and Result ($result_url), $CONCURRENCY loops each."
fi
echo "Ctrl-C stops early."

cmd_rc=0
if [ ${#cmd[@]} -gt 0 ]; then
  echo "Running: ${cmd[*]}"
  "${cmd[@]}" || cmd_rc=$?
  echo "Command exited with $cmd_rc. Requesting ${SETTLE}s more for pods still stopping."
  end=$((SECONDS + SETTLE))
else
  end=$((SECONDS + DURATION))
fi
while [ "$SECONDS" -lt "$end" ] && [ "$interrupted" -eq 0 ]; do
  sleep 1 || true
done

touch "$stop_file"
[ ${#pids[@]} -eq 0 ] || wait "${pids[@]}" || true
: >"$dir/cluster.log"
if [ -n "$pod" ]; then
  # Requests after this point are not counted, as for the local loops.
  stop_epoch=$(date +%s)
  kubectl -n "$PROBE_NAMESPACE" logs "$pod" 2>/dev/null |
    awk -v s="$stop_epoch" '$1 ~ /@cluster$/ && NF == 5 && $2 <= s' >"$dir/cluster.log" || true
  cleanup
  pod=""
fi
# cluster.log always exists, so the pattern always matches (the output file is created after).
sort -k2,2n "$dir"/*.log >"$dir/requests.log"

# Prints one summary line for an app; returns 1 if it had errors.
report() {
  local app=$1 counts total errors
  counts=$(awk -v a="$app" '$1 == a { n++; if ($5 != 0 || $3 !~ /^2[0-9][0-9]$/) e++ }
    END { print n + 0, e + 0 }' "$dir/requests.log")
  total=${counts% *}
  errors=${counts#* }
  awk -v a="$app" '$1 == a && $5 == 0 && $3 ~ /^2[0-9][0-9]$/ { print $4 }' "$dir/requests.log" |
    sort -n |
    awk -v app="$app" -v total="$total" -v errors="$errors" '
      function pct(p,  i) { i = int(p * NR); if (i < p * NR) i++; if (i < 1) i = 1; return v[i] }
      { v[NR] = $1 }
      END {
        printf "%-14s requests=%d errors=%d (%.2f %%)", app, total, errors, total ? 100 * errors / total : 0
        if (NR) printf "  latency p50=%.3fs p99=%.3fs max=%.3fs", pct(0.5), pct(0.99), v[NR]
        printf "\n"
      }'
  # No request at all is a failure too (the pod's log could not be read, for one).
  [ "$errors" -eq 0 ] && [ "$total" -gt 0 ]
}

echo
failed=0
for app in $apps; do
  report "$app" || failed=1
done
echo "Full log: $dir/requests.log (app, epoch, HTTP status, seconds, curl exit)"

if [ "$cmd_rc" -ne 0 ]; then
  echo "FAIL: the command exited with $cmd_rc."
  exit 1
fi
if [ "$failed" -ne 0 ]; then
  echo "FAIL: some requests failed."
  exit 1
fi
echo "PASS: no failed request."
