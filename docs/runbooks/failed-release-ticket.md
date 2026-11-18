# LAB-001 — Failed rollout after deployment

**Simulation only.** All times, roles and messages below are examples; this is a blank drill record, with no measured outage or actual support SLA.

- **Impact:** New lab revision cannot become ready. The prior pods are expected to continue serving. External users and actual customer impact: none in this isolated lab.
- **Priority / owner:** P2 (simulated release blocked), lab operator. Raise to simulated P1 if the prior release no longer serves and recovery smoke fails.
- **T+0 detection:** Record UTC, checkout SHA, attempted version, rollout status and probe events.
- **By T+5 min acknowledgment:** “We detected a failed deployment in the lab. We have paused the release and are checking the previous version.”
- **By T+10 min update:** Report observed readiness, whether rollback ran, and the next update time. Repeat every 10 minutes while open.
- **Escalation:** Immediately hand off to the lab maintainer if rollback fails, exit is unexpected, image/config differs or recovery smoke fails. If unresolved at T+15 min, hand off with sanitized events, revision history and last known good image/version.
- **Closure evidence (fill from actual run):** checkout SHA ___; initial smoke ___; rollout failure reason ___; exit ___; prior/recovered image reference and runtime IDs ___; failure flag cleared ___; recovery smoke including version ___; UTC recovery timestamp ___.
- **Closure message (send only after checks pass):** “The lab is serving the previous version again. Health and version checks passed. The failed release remains paused while we investigate the readiness failure.”
