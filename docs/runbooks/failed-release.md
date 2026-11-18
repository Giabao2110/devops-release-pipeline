# Failed release and rollback (kind lab)

Use a clean checkout and a disposable cluster. Prerequisites: Linux Bash (or WSL with Docker integration), Docker running Linux containers, kind, kubectl, curl and Python. Run from the repo root. The existing [CI drill](../../.github/workflows/ci.yml) deploys a healthy candidate and then reuses its image with an unhealthy pod configuration. No cloud account is needed.

## Reproduce and collect evidence

Use a new Bash session. Save its output if collecting evidence; record the checkout SHA, UTC timestamps and actual outputs. Review before sharing. Do not include kubeconfig, credentials, environment dumps or real user data.

```bash
set -euo pipefail
git status --short
sha=$(git rev-parse HEAD)
printf 'checkout=%s utc=%s\n' "$sha" "$(date -u +%FT%TZ)"
docker info --format '{{.OSType}}'
kind version

evidence=$(mktemp -d)
export KUBECONFIG="$evidence/kubeconfig"
export EVENTS_FILE="$evidence/deploy-events.jsonl"
export ENVIRONMENT=kind
export NAMESPACE=release-demo SERVICE=release-demo DEPLOYMENT=release-demo
unset PUSHGATEWAY_URL
kind create cluster --name failed-release-drill --config deploy/kind/cluster.yaml
test "$(kubectl config current-context)" = kind-failed-release-drill

docker build -t release-demo:drill-baseline --build-arg VERSION=1.0.0 --build-arg COMMIT="$sha" .
docker build -t release-demo:drill-good --build-arg VERSION=1.1.0 --build-arg COMMIT="$sha" .
kind load docker-image release-demo:drill-baseline release-demo:drill-good --name failed-release-drill
scripts/bootstrap.sh release-demo:drill-baseline 1.0.0
scripts/deploy.sh release-demo:drill-good 1.1.0

image_ref() {
  kubectl -n release-demo get deploy release-demo -o jsonpath='{.spec.template.spec.containers[0].image}'
}
ready_image_ids() {
  kubectl -n release-demo get pods -l app.kubernetes.io/name=release-demo -o json |
    python3 -c 'import json,sys; ids=[c["imageID"] for p in json.load(sys.stdin)["items"] if not p["metadata"].get("deletionTimestamp") for c in p.get("status",{}).get("containerStatuses",[]) if c["name"]=="app" and c["ready"]]; assert len(ids)==2 and all(ids), ids; print("\n".join(sorted(ids)))'
}
before_ref=$(image_ref)
before_ids=$(ready_image_ids)
printf 'before=%s\n%s\n' "$before_ref" "$before_ids"

rc=0
ROLLOUT_TIMEOUT=60s scripts/deploy.sh release-demo:drill-good 1.2.0-bad --fail-mode unhealthy || rc=$?
printf 'deploy_exit=%s utc=%s\n' "$rc" "$(date -u +%FT%TZ)"
test "$rc" -eq 3

after_ref=$(image_ref)
after_ids=$(ready_image_ids)
printf 'after=%s\n%s\n' "$after_ref" "$after_ids"
test "$after_ref" = "$before_ref"
test "$after_ids" = "$before_ids"
test -z "$(kubectl -n release-demo get deploy release-demo -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="FAIL_MODE")].value}')"
scripts/smoke_test.sh 1.1.0
kubectl -n release-demo rollout history deploy/release-demo
tail -n 1 "$EVENTS_FILE"
```

The unhealthy revision should fail readiness and be blocked at rollout status; it need not reach candidate smoke. Use the script's pod/event diagnostics to identify probe failures. Because both revisions reuse the same image, matching runtime image IDs alone cannot prove undo: also require exit 3, the cleared failure setting, rollout history and a fresh smoke with the prior expected version. The image IDs are runtime identifiers, not proof of registry digest pinning. Smoke checks a port-forward to one Service-selected pod; it does not measure user traffic or outage duration.

## Triage, escalate and close

If probes fail, compare the new replica's readiness, events and logs with the previous healthy replica; if rollout is ready but smoke fails, check Service selectors, endpoints and port-forward before attributing the failure to the image. Collect targeted output while the failing pod still exists: `kubectl -n release-demo describe pod <pod>` and `kubectl -n release-demo logs <pod> -c app` (add `--previous` for a restarted container). A removed pod may no longer have accessible logs. Exit 4 or any unexpected exit, mismatch or failed recovery smoke means stop the release and escalate to the lab operator. Check current state and rollout history before attempting anything further; do not undo blindly again.

Use the [simulated ticket](failed-release-ticket.md) for impact, updates and closure. After preserving only reviewed evidence, clean up the dedicated cluster with `kind delete cluster --name failed-release-drill`. Keep the temporary kubeconfig private.
