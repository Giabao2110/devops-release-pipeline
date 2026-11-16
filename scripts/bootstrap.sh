#!/usr/bin/env bash
# First install of the app into a cluster (revision 1), then smoke test.
# Usage: scripts/bootstrap.sh <image> <version>
set -euo pipefail
image="${1:?image}"; version="${2:?version}"
root="$(cd "$(dirname "$0")/.." && pwd)"
NS="${NAMESPACE:-release-demo}"
kubectl kustomize "$root/deploy/k8s/overlays/kind" \
  | sed "s#image: release-demo:dev#image: ${image}#" \
  | kubectl apply -f -
kubectl -n "$NS" annotate deploy release-demo kubernetes.io/change-cause="bootstrap ${version} (${image})" --overwrite
kubectl -n "$NS" rollout status deploy/release-demo --timeout="${ROLLOUT_TIMEOUT:-120s}"
"$root/scripts/smoke_test.sh" "$version"
