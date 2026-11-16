#!/usr/bin/env bash
# Deploy a new image to Kubernetes with an automatic rollback gate.
#
# Usage: scripts/deploy.sh <image> <version> [--fail-mode unhealthy]
#
#  1. patch the Deployment (image + version label + change-cause) -> new ReplicaSet
#  2. wait for the rolling update (readiness probes gate every new pod)
#  3. run the smoke test against the Service and check /version
#  4. on any failure: `kubectl rollout undo`, wait, and smoke-test the old version
#  5. append an event to $EVENTS_FILE and, if PUSHGATEWAY_URL is set, push
#     deployment/rollback counters for Prometheus/Grafana
#
# Exit codes: 0 deployed, 3 failed but rolled back, 4 rollback failed (page someone).
set -euo pipefail

image="${1:?image}"; version="${2:?version}"; shift 2
fail_mode=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fail-mode) fail_mode="${2:?}"; shift 2 ;;
    *) echo "unknown arg $1" >&2; exit 2 ;;
  esac
done

NS="${NAMESPACE:-release-demo}"
DEPLOY="${DEPLOYMENT:-release-demo}"
TIMEOUT="${ROLLOUT_TIMEOUT:-90s}"
ENVIRONMENT="${ENVIRONMENT:-kind}"
here="$(cd "$(dirname "$0")" && pwd)"
EVENTS_FILE="${EVENTS_FILE:-$here/../.state/deploy-events.jsonl}"
mkdir -p "$(dirname "$EVENTS_FILE")"

if command -v python3 >/dev/null 2>&1 && python3 -c '' >/dev/null 2>&1; then PY=python3; else PY=python; fi
log() { printf '[deploy %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

start=$(date +%s)
prev_image=$(kubectl -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.spec.template.spec.containers[0].image}')
prev_rev=$(kubectl -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}')
log "current: $prev_image (revision $prev_rev) -> target: $image ($version)${fail_mode:+ [FAIL_MODE=$fail_mode]}"

patch=$(cat <<JSON
{"metadata":{"annotations":{"kubernetes.io/change-cause":"deploy ${version} (${image})"}},
 "spec":{"template":{"metadata":{"labels":{"app.kubernetes.io/version":"${version//+/_}"}},
  "spec":{"containers":[{"name":"app","image":"${image}",
   "env":[{"name":"FAIL_MODE","value":"${fail_mode}"}]}]}}}}
JSON
)
kubectl -n "$NS" patch deploy "$DEPLOY" --type strategic -p "$patch"

reason=""
if ! kubectl -n "$NS" rollout status "deploy/$DEPLOY" --timeout="$TIMEOUT"; then
  reason="rollout did not become ready within $TIMEOUT"
elif ! "$here/smoke_test.sh" "$version"; then
  reason="smoke test failed"
fi

result="success"
if [[ -n "$reason" ]]; then
  log "DEPLOY FAILED: $reason"
  log "diagnostics (newest pods):"
  kubectl -n "$NS" get pods -l app.kubernetes.io/name="$DEPLOY" -o wide || true
  kubectl -n "$NS" get events --sort-by=.lastTimestamp 2>/dev/null | tail -n 8 || true
  if [[ -z "$prev_rev" ]]; then
    log "no previous revision to roll back to"; result="rollback_failed"
  else
    log "rolling back to previous revision"
    kubectl -n "$NS" rollout undo "deploy/$DEPLOY"
    if kubectl -n "$NS" rollout status "deploy/$DEPLOY" --timeout="$TIMEOUT" && "$here/smoke_test.sh"; then
      result="rolled_back"
      log "rollback complete; serving $(kubectl -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.spec.template.spec.containers[0].image}')"
    else
      result="rollback_failed"
    fi
  fi
fi

duration=$(( $(date +%s) - start ))
printf '{"ts":"%s","environment":"%s","version":"%s","image":"%s","from_image":"%s","result":"%s","reason":"%s","duration_seconds":%d}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ENVIRONMENT" "$version" "$image" "$prev_image" "$result" "$reason" "$duration" >> "$EVENTS_FILE"
log "result=$result duration=${duration}s (event appended to ${EVENTS_FILE##*/})"

if [[ -n "${PUSHGATEWAY_URL:-}" ]]; then
  if "$PY" "$here/pipeline_metrics.py" deploys --input "$EVENTS_FILE" --prom \
      | curl -fsS --data-binary @- "$PUSHGATEWAY_URL/metrics/job/release_pipeline/environment/$ENVIRONMENT"; then
    log "pushed deploy metrics to $PUSHGATEWAY_URL"
  else
    log "WARN: could not push metrics to $PUSHGATEWAY_URL"
  fi
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### Deploy ${version} -> ${ENVIRONMENT}: \`${result}\`"
    echo "- image: \`${image}\` (from \`${prev_image}\`)"
    echo "- duration: ${duration}s${reason:+ — reason: ${reason}}"
  } >> "$GITHUB_STEP_SUMMARY"
fi

case "$result" in
  success) exit 0 ;;
  rolled_back) exit 3 ;;
  *) exit 4 ;;
esac
