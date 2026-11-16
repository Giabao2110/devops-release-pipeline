#!/usr/bin/env bash
# Smoke test through the Kubernetes Service.
# Usage: scripts/smoke_test.sh [expected_version]
# Checks /healthz, /readyz, /metrics and (optionally) that /version matches.
set -euo pipefail
NS="${NAMESPACE:-release-demo}"
SVC="${SERVICE:-release-demo}"
PORT="${SMOKE_PORT:-$(( 20000 + RANDOM % 10000 ))}"
expected="${1:-}"

kubectl -n "$NS" port-forward "svc/$SVC" "$PORT:80" >/dev/null 2>&1 &
pf=$!
trap 'kill $pf 2>/dev/null || true' EXIT

base="http://127.0.0.1:$PORT"
for _ in $(seq 1 30); do
  curl -fsS -o /dev/null "$base/healthz" 2>/dev/null && break
  sleep 1
done

fail() { echo "SMOKE FAIL: $*" >&2; exit 1; }
check() { # path expected_code
  local code; code=$(curl -s -o /dev/null -w '%{http_code}' "$base$1" || true)
  [[ "$code" == "$2" ]] || fail "GET $1 returned $code, want $2"
  echo "  ok  GET $1 -> $code"
}

echo "smoke test via svc/$SVC (port $PORT)"
check /healthz 200
check /readyz 200
curl -fsS "$base/metrics" | grep -q '^app_build_info' || fail "/metrics missing app_build_info"
echo "  ok  /metrics exposes app_build_info"
got=$(curl -fsS "$base/version" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')
if [[ -n "$expected" && "$got" != "$expected" ]]; then
  fail "/version is '$got', want '$expected'"
fi
echo "  ok  /version -> $got"
echo "SMOKE PASS"
