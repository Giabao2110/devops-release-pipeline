# Drill 1: CrashLoopBackOff from a bad configuration

**Setup:** [`manifests/crashloop.yaml`](manifests/crashloop.yaml) deploys the
app with `FAIL_MODE=crash`, standing in for a release that exits on start (bad
config value, missing secret, failed migration).
Raw output: [`../evidence/raw-05-troubleshoot-crashloop.log`](../evidence/raw-05-troubleshoot-crashloop.log).

## Symptom

```
$ kubectl -n lab-crashloop get pods
NAME                     READY   STATUS             RESTARTS      AGE
broken-cd98f97c5-p4kpq   0/1     CrashLoopBackOff   2 (27s ago)   59s
```

`CrashLoopBackOff` is not an error by itself. It means the container keeps
exiting, so the kubelet restarts it with a growing delay (10 s, 20 s, 40 s, up to 5 min).

## Diagnosis, step by step

1. **How did the container end?** `kubectl describe pod`, section *Last State*:

   ```
   Last State:     Terminated
     Reason:       Error
     Exit Code:    1
     Started:      ... 14:53:59    Finished: ... 14:54:00
   ```

   - Exit code 1 after one second points to the application refusing to start.
   - `OOMKilled` / 137 would mean the memory limit was hit (see drill 3).
   - Exit code 0 would mean the process finished normally.
   - `ImagePullBackOff` would be a different problem entirely.

2. **Why did it exit?** The current container may already be restarting, so read the
   logs of the *previous* one:

   ```
   $ kubectl -n lab-crashloop logs deploy/broken --previous
   {"level":"ERROR","msg":"FAIL_MODE=crash: exiting on purpose to simulate a broken release"}
   ```

3. **What changed?** Compare the pod spec with the last good version, with
   `kubectl rollout history deploy/broken --revision=N` or by diffing the
   manifests in git. Here the culprit is the `FAIL_MODE` env var.

## Fix

```
$ kubectl -n lab-crashloop set env deploy/broken FAIL_MODE-
$ kubectl -n lab-crashloop rollout status deploy/broken
deployment "broken" successfully rolled out
```

In a real pipeline the immediate fix is `kubectl rollout undo` (what
`scripts/deploy.sh` does automatically; see
[`raw-12-deploy-crash-rollback.log`](../evidence/raw-12-deploy-crash-rollback.log)).
The permanent fix is correcting the configuration in git.

## Why users were not affected in the pipeline version

In `deploy/k8s/base/deployment.yaml` the rolling update uses `maxUnavailable: 0`
and a readiness probe. The crashing pod never becomes Ready, so the two old pods
keep serving. The load test sent 496 requests during that drill and none failed.
