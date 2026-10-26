#!/usr/bin/env bash
# Zero-downtime test: requests Poll and Result continuously and fails on any error.
# Written for bash 3.2+ (macOS default) and curl; no other tool needed.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: tests/zero-downtime.sh [POLL_URL RESULT_URL] [-- COMMAND...]

Sends GET requests to Poll and Result in parallel loops, prints every error as it
happens, then a summary per app. An error is a non-2xx status or a curl failure
(connection refused or reset, timeout).

  Without COMMAND  runs for DURATION seconds: start the update from another terminal.
  With COMMAND     starts the requests, runs COMMAND (a rollout, a deploy script),
                   keeps requesting SETTLE seconds after it ends, then stops.
                   COMMAND must wait for the rollout: `kubectl rollout restart`
                   alone returns at once, so add `kubectl rollout status`.
  Without URLs     uses the EXTERNAL-IP of the poll and result Services (kubectl).

Examples:
  tests/zero-downtime.sh
  tests/zero-downtime.sh -- sh -c 'kubectl -n bernstein rollout restart deploy/poll deploy/result &&
    kubectl -n bernstein rollout status deploy/poll deploy/result'
  tests/zero-downtime.sh http://localhost:5000/ http://localhost:5001/

Environment: DURATION=120  SETTLE=15  CONCURRENCY=2 (loops per app)  TIMEOUT=5 (seconds
per request)  NAMESPACE=bernstein

Exit code: 0 no error (and COMMAND succeeded), 1 errors or COMMAND failed,
2 bad usage or an app not answering before the test.
EOF
}

DURATION=${DURATION:-120}
SETTLE=${SETTLE:-15}
CONCURRENCY=${CONCURRENCY:-2}
TIMEOUT=${TIMEOUT:-5}
NAMESPACE=${NAMESPACE:-bernstein}
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

urls=()
cmd=()
while [ $# -gt 0 ]; do
  case $1 in
    -h | --help)
      usage
      exit 0
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
    poll_url=$(service_url poll)
    result_url=$(service_url result)
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

dir=$(mktemp -d "${TMPDIR:-/tmp}/zero-downtime.XXXXXX")
stop_file="$dir/stop"
interrupted=0
trap 'interrupted=1' INT TERM
trap 'touch "$stop_file"' EXIT

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

pids=()
i=1
while [ "$i" -le "$CONCURRENCY" ]; do
  worker poll "$poll_url" "$dir/poll.$i.log" &
  pids+=($!)
  worker result "$result_url" "$dir/result.$i.log" &
  pids+=($!)
  i=$((i + 1))
done
echo "Requesting Poll ($poll_url) and Result ($result_url), $CONCURRENCY loops each. Ctrl-C stops early."

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
wait "${pids[@]}" || true
sort -k2,2n "$dir"/poll.*.log "$dir"/result.*.log >"$dir/requests.log"

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
        printf "%-7s requests=%d errors=%d (%.2f %%)", app, total, errors, total ? 100 * errors / total : 0
        if (NR) printf "  latency p50=%.3fs p99=%.3fs max=%.3fs", pct(0.5), pct(0.99), v[NR]
        printf "\n"
      }'
  [ "$errors" -eq 0 ]
}

echo
failed=0
report poll || failed=1
report result || failed=1
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
