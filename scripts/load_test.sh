#!/usr/bin/env bash
# Generate traffic through the Service so dashboards have data.
# Usage: scripts/load_test.sh [seconds] [requests_per_second]
set -euo pipefail
secs="${1:-60}"; rps="${2:-10}"
NS="${NAMESPACE:-release-demo}"; PORT="${LOAD_PORT:-18090}"
kubectl -n "$NS" port-forward svc/release-demo "$PORT:80" >/dev/null 2>&1 &
pf=$!; trap 'kill $pf 2>/dev/null || true' EXIT
sleep 2
end=$(( $(date +%s) + secs )); n=0; errors=0
while (( $(date +%s) < end )); do
  for _ in $(seq 1 "$rps"); do
    code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/work" || echo 000)
    n=$((n+1)); [[ "$code" == 2* ]] || errors=$((errors+1))
  done
  sleep 1
done
echo "sent $n requests, $errors non-2xx"
