# Drill 2: Service selector does not match the pods

**Setup:** [`manifests/selector-mismatch.yaml`](manifests/selector-mismatch.yaml)
labels the pods `app.kubernetes.io/name: web`, but the Service selects
`app.kubernetes.io/name: web-app`. That kind of typo slips through review
easily because every object is valid YAML and `kubectl apply` succeeds.
Raw output: [`../evidence/raw-06-troubleshoot-selector.log`](../evidence/raw-06-troubleshoot-selector.log).

## Symptom

The pods look perfectly healthy:

```
$ kubectl -n lab-selector get pods --show-labels
web-5d6d694869-kh4ng   1/1   Running   ...   app.kubernetes.io/name=web,...
web-5d6d694869-zlkt9   1/1   Running   ...   app.kubernetes.io/name=web,...
```

Traffic to the Service goes nowhere, though. `kubectl port-forward svc/web` hung
with no output because there was no pod behind the Service to forward to. In a
cluster you would see connection timeouts or 503s from an ingress.

## Diagnosis

1. **Does the Service have endpoints?** This is the fastest check:

   ```
   $ kubectl -n lab-selector get endpointslices -l kubernetes.io/service-name=web
   NAME        ADDRESSTYPE   PORTS     ENDPOINTS   AGE
   web-z9hv4   IPv4          <unset>   <unset>     101s
   ```

   No endpoints but running pods points to a selector or readiness problem.

2. **Compare the selector with the pod labels:**

   ```
   $ kubectl -n lab-selector get svc web -o jsonpath={.spec.selector}
   {"app.kubernetes.io/name":"web-app"}
   $ kubectl -n lab-selector get pods -l app.kubernetes.io/name=web-app
   No resources found in lab-selector namespace.
   ```

   (If the labels had matched but the pods were not Ready, the addresses would
   show up as not-ready endpoints instead. Then the fix would be the readiness probe.)

## Fix

```
$ kubectl -n lab-selector patch svc web --type merge \
    -p '{"spec":{"selector":{"app.kubernetes.io/name":"web"}}}'
$ kubectl -n lab-selector get endpointslices -l kubernetes.io/service-name=web
web-z9hv4   IPv4   8080   10.244.0.10,10.244.0.11
$ SERVICE=web NAMESPACE=lab-selector scripts/smoke_test.sh
SMOKE PASS
```

## Prevention

- Keep labels in one place (Kustomize `labels`/`commonLabels` or Helm helpers)
  instead of typing them in several files.
- The smoke test goes through the **Service**, not a pod, so this class of bug
  fails the pipeline before anyone else sees it.
