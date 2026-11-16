#!/usr/bin/env bash
# Install Prometheus + Pushgateway + Grafana into the "monitoring" namespace.
# A random Grafana admin password is generated into a Secret (never committed).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
kubectl apply -f "$root/deploy/monitoring/namespace.yaml"
if ! kubectl -n monitoring get secret grafana-admin >/dev/null 2>&1; then
  pw="$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)"
  kubectl -n monitoring create secret generic grafana-admin --from-literal=password="$pw" >/dev/null
  echo "created Secret monitoring/grafana-admin (read it with: kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.password}' | base64 -d)"
fi
kubectl apply -k "$root/deploy/monitoring"
for d in prometheus pushgateway grafana; do
  kubectl -n monitoring rollout status "deploy/$d" --timeout="${ROLLOUT_TIMEOUT:-300s}"
done
cat <<MSG
Monitoring is up. In separate terminals:
  kubectl -n monitoring port-forward svc/prometheus 9090:9090
  kubectl -n monitoring port-forward svc/grafana 3000:3000
  kubectl -n monitoring port-forward svc/pushgateway 9091:9091   # then: export PUSHGATEWAY_URL=http://127.0.0.1:9091
MSG
