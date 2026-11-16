# Verification evidence

Raw command output from running the lab on 16 Nov 2026. Environment: Windows 11
laptop, Docker Desktop 29.5 (WSL2), kind v0.33.0 (Kubernetes v1.37.0), Go
1.26.4, Python 3.14, Terraform 1.17.2, promtool built from source. Local paths
were replaced with `<repo>`; nothing else was edited. Image versions such as
`1.0.0`–`1.3.0` are local test builds (`COMMIT=local0N`), not releases.

| # | What | Command (short) | Result | Log |
|---|---|---|---|---|
| 0 | kind cluster | `kind create cluster --config deploy/kind/cluster.yaml` | Ready after 13 s (node image pull took ~2 min) | [raw-kind-create.log](raw-kind-create.log) |
| 0 | image build | `docker build ... -t release-demo:1.0.0 .` | 15 MB, `User=65532:65532` | [raw-docker-build.log](raw-docker-build.log) |
| 1 | first install | `scripts/bootstrap.sh release-demo:1.0.0 1.0.0` | rolled out, SMOKE PASS | [raw-01-bootstrap.log](raw-01-bootstrap.log) |
| 2 | normal deploy | `scripts/deploy.sh release-demo:1.1.0 1.1.0` | success in 4 s | [raw-02-deploy-good.log](raw-02-deploy-good.log) |
| 3 | bad release, probes fail | `deploy.sh ... 1.2.0 --fail-mode unhealthy` | timeout 60 s → `rollout undo` → 1.1.0 re-verified, exit 3 | [raw-03-deploy-bad-rollback.log](raw-03-deploy-bad-rollback.log) |
| 4 | revision history | `kubectl rollout history` | revision 2 re-numbered to 4 after undo | [raw-04-rollout-history.log](raw-04-rollout-history.log) |
| 5 | CrashLoopBackOff drill | describe / `logs --previous` / fix | exit code 1, env fixed, Running | [raw-05-troubleshoot-crashloop.log](raw-05-troubleshoot-crashloop.log) |
| 6 | selector mismatch drill | endpointslices / selector / patch | no endpoints → 2 endpoints, SMOKE PASS | [raw-06-troubleshoot-selector.log](raw-06-troubleshoot-selector.log) |
| 7 | monitoring stack | `scripts/monitoring_up.sh` | Prometheus, Pushgateway, Grafana rolled out | [raw-07-monitoring-up.log](raw-07-monitoring-up.log) |
| 8 | Terraform | `init`, `fmt -check`, `validate` | valid | [raw-08-terraform-validate.log](raw-08-terraform-validate.log) |
| 9 | Terraform offline plan | `plan -var-file=offline.tfvars -refresh=false` | `Plan: 26 to add`; never applied | [raw-09-terraform-plan.log](raw-09-terraform-plan.log) |
| 10 | deploy with metrics push | `PUSHGATEWAY_URL=... deploy.sh ... 1.2.0` | deploy ok; **push failed (HTTP 400)**: Python wrote CRLF on Windows; fixed in `pipeline_metrics.py`, re-pushed (200) | [raw-10-deploy-fixed-with-metrics.log](raw-10-deploy-fixed-with-metrics.log) |
| 11 | load during drill 12 | `scripts/load_test.sh 150 8` | 496 requests, 0 non-2xx | [raw-11-load-test.log](raw-11-load-test.log) |
| 12 | bad release under load | `deploy.sh ... 1.3.0 --fail-mode crash` | CrashLoopBackOff → rollback to 1.2.0, metrics pushed, exit 3 | [raw-12-deploy-crash-rollback.log](raw-12-deploy-crash-rollback.log) |
| 13 | Prometheus API | targets / queries / alerts | 4 targets up; rollback rate 0.5; `DeploymentRolledBack` and `RollbackRateHigh` firing | [raw-13-prometheus-checks.log](raw-13-prometheus-checks.log) |
| 14 | Grafana OOMKill (unplanned) | describe / logs / fix | exit 137 at 256Mi → plugin preinstall off, 512Mi, stable | [raw-14-troubleshoot-grafana-oom.log](raw-14-troubleshoot-grafana-oom.log) |
| 15 | error-rate alert | `kubectl set env ERROR_RATE=0.2` + 7 min load | 243/1264 requests failed; `ReleaseDemoHighErrorRate` firing (value 0.16); reverted with `rollout undo`, SMOKE PASS | [raw-15-error-rate-alert.log](raw-15-error-rate-alert.log) |
| 16 | build matrix (local) | `scripts/package.sh` × 4 | first run 3/4 (no `zip` in Git Bash) → fallback fixed → 4/4, `sha256sum -c` OK | [raw-16-build-matrix-local.log](raw-16-build-matrix-local.log) |

Unit tests and static checks (not logged to files, re-run any time):

```text
$ (cd app && go vet ./... && go test -count=1 -cover ./...)
ok   github.com/Giabao2110/devops-release-pipeline/app   coverage: 78.2% of statements
$ python -m unittest discover -s tests
Ran 8 tests ... OK
$ docker run --rm -v "$PWD/scripts:/mnt" -w /mnt koalaman/shellcheck:stable *.sh
(no findings)
$ promtool check rules deploy/monitoring/prometheus/alerts.yml
SUCCESS: 5 rules found
$ promtool test rules deploy/monitoring/prometheus/alerts_test.yml
SUCCESS
```

## Not verified locally

- **GitHub Actions** (`ci.yml`): GHCR push, cosign keyless signing and verification, the
  multi-arch buildx image, the job-timing/failure-rate report and the release job
  need GitHub's OIDC and runners. The result of the first runs is recorded below
  once the repository is pushed.
- **HPA scaling:** metrics-server is not installed in kind, so the HPA shows `<unknown>`.
- **AWS:** nothing was applied; only `validate` and an offline `plan`.

## CI runs

_Not run yet at the time of writing._
