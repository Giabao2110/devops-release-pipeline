# Incident: Grafana OOMKilled at start-up (found while building this lab)

This one was not planned. While I was taking the dashboard screenshot, Grafana
stopped answering. Raw output:
[`../evidence/raw-14-troubleshoot-grafana-oom.log`](../evidence/raw-14-troubleshoot-grafana-oom.log).

## Symptom

```
$ curl http://127.0.0.1:3000/api/health
curl: (52) Empty reply from server

$ kubectl -n monitoring get pods
grafana-65bf85f48d-5n8xz   0/1   OOMKilled   4 (2m33s ago)   9m19s
```

## Diagnosis

```
$ kubectl -n monitoring describe pod -l app=grafana
    Last State:     Terminated
      Reason:       OOMKilled
      Exit Code:    137          # 128 + 9 (SIGKILL from the kernel OOM killer)
    Limits:
      memory:  256Mi
```

The container hit its 256 MiB memory limit, and that happened about 17 seconds
after each start. The previous container's logs show what it was doing at the time:

```
$ kubectl -n monitoring logs deploy/grafana --previous
logger=plugin.backgroundinstaller msg="Installing plugins" plugins="[{ID:jaeger ...} {ID:cloudwatch ...} ...]"
logger=plugin.installer msg="Updating plugin" pluginId=cloudwatch from=12.11.2 to=12.11.3
```

Grafana 13 downloads and updates a set of bundled plugins in the background at
start-up. Together with normal start-up work, that went over 256 MiB. I had
copied the limit from older examples.

## Fix

In [`deploy/monitoring/grafana/deployment.yaml`](../../deploy/monitoring/grafana/deployment.yaml):

- `GF_PLUGINS_PREINSTALL_DISABLED=true` and
  `GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES=false`. The lab only needs the built-in
  Prometheus data source, and an air-gapped cluster could not download plugins anyway.
- Memory request 96 MiB to 192 MiB, limit 256 MiB to 512 MiB.

```
$ kubectl apply -k deploy/monitoring
$ kubectl -n monitoring get pods -l app=grafana      # 45 s after rollout
grafana-6f4d57557d-4jcrh   1/1   Running   0   87s
```

## Takeaways

- `OOMKilled` / exit 137 means the memory limit was hit, not that the application failed. Check
  `Last State`, not just the current state.
- Limits should come from observed usage (`kubectl top`, or
  `container_memory_working_set_bytes` in Prometheus), not from copied examples.
- Features that reach out to the internet at start-up (plugin installs, update checks) affect
  both memory use and reproducibility. Turn them off when you do not need them.
