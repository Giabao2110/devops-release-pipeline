# Case study: canary deploys with automatic rollback (internship work)

> **Context and confidentiality.** This describes work I did as a Software
> Engineer Intern at Bubobot (from July 2026). It is written in prose from my
> own notes. **No company code, logs, hostnames, IP addresses, tokens or
> internal identifiers are included, and the company's repositories are not
> public.** Numbers are left out unless I could check them myself. The
> [lab in this repository](../README.md) is a separate personal project that
> re-creates the same ideas on Kubernetes.

## Problem

An application package had to be updated on several Linux staging instances.
The team wanted a release path that:

- catches a broken package before it reaches every instance,
- puts an instance back on the previous version by itself when the new version
  fails its checks after installation,
- gives the CI system as little access to the servers as possible.

## What I built

I wrote the installation scripts (Bash) and the GitHub Actions workflow around
them. AI coding assistants helped during development and review. The work went
through pull requests reviewed by the team.

1. **Test before touching servers.** The workflow tests the package first. The
   install script can be re-run safely, and the service runs as a dedicated
   non-root user.
2. **Canary first.** One instance is updated before the rest. The rollout
   continues only if that instance passes its post-install health check.
3. **Health check, then automatic rollback.** After installing on an instance,
   the script checks the service's health endpoint. If the check fails, it
   restores the previous version on that instance and the rollout stops.
4. **Least privilege on the delivery path.**
   - SSH access for the workflow is limited to the specific commands it needs.
   - Tokens are read-only.
   - Workflows need an approval gate before they run.
   - After a merge, a coordinator triggers the workflow at exactly the merged
     commit, and only for allowlisted targets.

## What happened on the first real run

The first run **stopped at the canary**. The canary install failed because the
image was missing `useradd`, which the install script needs to create the
non-root service user. Because the canary
failed its check, the problem never reached the other instances. I traced the
failure to the missing package, fixed the image and re-ran the workflow. The
second run passed, and the health endpoint returned HTTP 200 over HTTPS on
staging.

That failure was the most useful part of the project: it showed that the canary
and the health gate do their job. A broken release was contained on one
instance instead of every instance.

## Related work in the same period

- **Monitoring:** I configured Prometheus exporters (pull model, firewall open only
  to the monitoring host), alert rules checked with `promtool`, Grafana, and
  Alertmanager notifications to Discord, for staging and production. I also
  added a post-deployment step that flags monitoring targets that fail to load
  after a config change.
- **Backup/restore:** I built Go/React backup and restore flows for Docker-based
  instances with separate daily and manual retention. Recovery was verified on staging by
  restoring after data changes and comparing checksums and application health.

## How the lab maps to this

| Internship (VMs, Bash) | This lab (Kubernetes) |
|---|---|
| Canary on one instance first | `maxSurge: 1`, `maxUnavailable: 0`: one new pod must become Ready before old pods go away |
| Post-install health check | readiness/liveness probes + `scripts/smoke_test.sh` through the Service |
| Restore previous version on failure | `kubectl rollout undo` + re-verify the old version (`scripts/deploy.sh`) |
| Approval gate, restricted tokens | GitHub Actions `permissions:` per job, OIDC for signing and AWS (no stored keys) |
| Alerting on failures | `DeploymentRolledBack` and `RollbackRateHigh` alert rules with promtool tests |

## What I would do next time

- Record every deployment attempt (version, result, duration) from day one, so
  rollback rate and deploy time can be tracked as metrics, as the lab does with
  `deploy-events.jsonl`.
- Pin and test the build image itself, so a missing package such as `useradd` is
  caught in CI before the first deployment.
