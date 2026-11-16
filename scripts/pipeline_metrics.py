#!/usr/bin/env python3
"""Pipeline metrics: build time, failure rate and rollback rate.

Standard library only. Subcommands:

  builds  --input-dir DIR      merge per-target build records (build-*.json)
                               written by the CI build matrix
  jobs    --input FILE         GitHub API response of
                               /repos/{o}/{r}/actions/runs/{id}/jobs
  runs    --input FILE         workflow history: `gh run list --json ...`
                               or the /actions/runs API response
  deploys --input FILE         deploy events (JSON lines) from scripts/deploy.sh

Every subcommand prints a JSON summary. Add --markdown FILE to append a table
(e.g. to $GITHUB_STEP_SUMMARY). `deploys --prom` prints Prometheus text format
for the Pushgateway instead.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from datetime import datetime
from pathlib import Path
from typing import Any, Iterable

FAILED = {"failure", "timed_out", "startup_failure"}


def parse_ts(value: str | None) -> datetime | None:
    if not value:
        return None
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def duration_s(start: str | None, end: str | None) -> float | None:
    s, e = parse_ts(start), parse_ts(end)
    if s is None or e is None:
        return None
    return max(0.0, (e - s).total_seconds())


def percentile(values: list[float], p: float) -> float | None:
    """Nearest-rank percentile (p in 0..100)."""
    if not values:
        return None
    ordered = sorted(values)
    rank = max(1, math.ceil(p / 100 * len(ordered)))
    return ordered[rank - 1]


def stats(values: list[float]) -> dict[str, float | None]:
    if not values:
        return {"mean": None, "p50": None, "p90": None, "max": None}
    return {
        "mean": round(sum(values) / len(values), 1),
        "p50": percentile(values, 50),
        "p90": percentile(values, 90),
        "max": max(values),
    }


def ratio(num: int, den: int) -> float | None:
    return round(num / den, 4) if den else None


# --------------------------------------------------------------------------- builds
def summarize_builds(records: Iterable[dict[str, Any]]) -> dict[str, Any]:
    targets = sorted(records, key=lambda r: r["target"])
    ok = [r for r in targets if r.get("status") == "success"]
    return {
        "targets": len(targets),
        "succeeded": len(ok),
        "failed": len(targets) - len(ok),
        "failure_rate": ratio(len(targets) - len(ok), len(targets)),
        "build_seconds": stats([float(r["duration_seconds"]) for r in targets]),
        "total_artifact_bytes": sum(int(r.get("size_bytes", 0)) for r in ok),
        "per_target": targets,
    }


def builds_markdown(s: dict[str, Any]) -> str:
    lines = [
        "### Build matrix",
        f"{s['succeeded']}/{s['targets']} targets built, failure rate "
        f"{fmt_pct(s['failure_rate'])}, mean build {s['build_seconds']['mean']}s",
        "",
        "| target | status | build (s) | size (KiB) | sha256 |",
        "|---|---|---:|---:|---|",
    ]
    for r in s["per_target"]:
        lines.append(
            f"| {r['target']} | {r['status']} | {r['duration_seconds']} | "
            f"{int(r.get('size_bytes', 0)) // 1024} | `{str(r.get('sha256', ''))[:12]}` |"
        )
    return "\n".join(lines) + "\n"


# --------------------------------------------------------------------------- jobs
def summarize_jobs(payload: dict[str, Any]) -> dict[str, Any]:
    jobs = []
    for j in payload.get("jobs", []):
        if j.get("status") != "completed":
            continue  # e.g. the metrics job itself, still running
        jobs.append({
            "name": j["name"],
            "conclusion": j.get("conclusion"),
            "duration_seconds": duration_s(j.get("started_at"), j.get("completed_at")),
        })
    failed = [j for j in jobs if j["conclusion"] in FAILED]
    starts = [parse_ts(j.get("started_at")) for j in payload.get("jobs", []) if j.get("started_at")]
    ends = [parse_ts(j.get("completed_at")) for j in payload.get("jobs", []) if j.get("completed_at")]
    wall = (max(ends) - min(starts)).total_seconds() if starts and ends else None
    return {
        "jobs": len(jobs),
        "failed": len(failed),
        "failed_jobs": [j["name"] for j in failed],
        "wall_clock_seconds": wall,
        "job_seconds": stats([j["duration_seconds"] for j in jobs if j["duration_seconds"] is not None]),
        "per_job": jobs,
    }


def jobs_markdown(s: dict[str, Any]) -> str:
    lines = [
        "### Pipeline timing (this run)",
        f"{s['jobs']} completed jobs, {s['failed']} failed, wall clock so far "
        f"{s['wall_clock_seconds']}s",
        "",
        "| job | result | duration (s) |",
        "|---|---|---:|",
    ]
    for j in sorted(s["per_job"], key=lambda j: -(j["duration_seconds"] or 0)):
        lines.append(f"| {j['name']} | {j['conclusion']} | {j['duration_seconds']} |")
    return "\n".join(lines) + "\n"


# --------------------------------------------------------------------------- runs
def summarize_runs(payload: Any) -> dict[str, Any]:
    runs = payload.get("workflow_runs", []) if isinstance(payload, dict) else payload
    by_wf: dict[str, list[dict[str, Any]]] = {}
    for r in runs:
        if r.get("status") not in (None, "completed"):
            continue
        name = r.get("workflowName") or r.get("name") or "unknown"
        start = r.get("startedAt") or r.get("run_started_at") or r.get("createdAt") or r.get("created_at")
        end = r.get("updatedAt") or r.get("updated_at")
        by_wf.setdefault(name, []).append({
            "conclusion": r.get("conclusion"),
            "duration_seconds": duration_s(start, end),
        })
    out = {}
    for name, items in sorted(by_wf.items()):
        counted = [i for i in items if i["conclusion"] not in ("cancelled", "skipped")]
        failed = [i for i in counted if i["conclusion"] in FAILED]
        out[name] = {
            "runs": len(items),
            "counted": len(counted),
            "failed": len(failed),
            "cancelled": len(items) - len(counted),
            "failure_rate": ratio(len(failed), len(counted)),
            "duration_seconds": stats([i["duration_seconds"] for i in counted if i["duration_seconds"] is not None]),
        }
    return {"workflows": out}


def runs_markdown(s: dict[str, Any]) -> str:
    lines = [
        "### Workflow history",
        "| workflow | runs | failure rate | mean (s) | p90 (s) |",
        "|---|---:|---:|---:|---:|",
    ]
    for name, w in s["workflows"].items():
        d = w["duration_seconds"]
        lines.append(f"| {name} | {w['runs']} | {fmt_pct(w['failure_rate'])} | {d['mean']} | {d['p90']} |")
    return "\n".join(lines) + "\n"


# --------------------------------------------------------------------------- deploys
RESULTS = ("success", "rolled_back", "rollback_failed")


def load_jsonl(path: Path) -> list[dict[str, Any]]:
    events = []
    for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = line.strip()
        if not line:
            continue
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError as exc:
            raise SystemExit(f"{path}:{n}: invalid JSON line: {exc}") from exc
    return events


def summarize_deploys(events: list[dict[str, Any]]) -> dict[str, Any]:
    counts = {k: 0 for k in RESULTS}
    for e in events:
        counts[e["result"]] = counts.get(e["result"], 0) + 1
    total = len(events)
    last = events[-1] if events else None
    return {
        "deployments": total,
        "by_result": counts,
        "rollback_rate": ratio(total - counts["success"], total),
        "deploy_seconds": stats([float(e["duration_seconds"]) for e in events]),
        "last": last,
    }


def deploys_prom(s: dict[str, Any]) -> str:
    lines = [
        "# HELP release_deployments_total Deployments by outcome (success, rolled_back, rollback_failed).",
        "# TYPE release_deployments_total counter",
    ]
    for k in RESULTS:
        lines.append(f'release_deployments_total{{result="{k}"}} {s["by_result"].get(k, 0)}')
    last = s["last"]
    if last:
        ts = parse_ts(last["ts"]).timestamp()
        lines += [
            "# HELP release_last_deploy_timestamp_seconds Unix time of the last deployment attempt.",
            "# TYPE release_last_deploy_timestamp_seconds gauge",
            f"release_last_deploy_timestamp_seconds {ts:.0f}",
            "# HELP release_last_deploy_duration_seconds Duration of the last deployment attempt.",
            "# TYPE release_last_deploy_duration_seconds gauge",
            f"release_last_deploy_duration_seconds {last['duration_seconds']}",
            "# HELP release_last_deploy_success 1 if the last deployment succeeded without rollback.",
            "# TYPE release_last_deploy_success gauge",
            f"release_last_deploy_success {1 if last['result'] == 'success' else 0}",
        ]
    return "\n".join(lines) + "\n"


def deploys_markdown(s: dict[str, Any]) -> str:
    b = s["by_result"]
    return (
        "### Deployments\n"
        f"{s['deployments']} deployments: {b['success']} succeeded, {b['rolled_back']} rolled back, "
        f"{b['rollback_failed']} rollback failed; rollback rate {fmt_pct(s['rollback_rate'])}; "
        f"mean deploy {s['deploy_seconds']['mean']}s\n"
    )


# --------------------------------------------------------------------------- cli
def fmt_pct(v: float | None) -> str:
    return "n/a" if v is None else f"{v * 100:.1f}%"


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    for name in ("builds", "jobs", "runs", "deploys"):
        sp = sub.add_parser(name)
        if name == "builds":
            sp.add_argument("--input-dir", required=True, type=Path)
        else:
            sp.add_argument("--input", required=True, type=Path)
        sp.add_argument("--markdown", type=Path, help="append a Markdown summary to this file")
        sp.add_argument("--output", type=Path, help="write the JSON summary to this file")
        if name == "deploys":
            sp.add_argument("--prom", action="store_true", help="print Prometheus text format")
    a = p.parse_args(argv)

    if a.cmd == "builds":
        records = [json.loads(f.read_text(encoding="utf-8")) for f in sorted(a.input_dir.rglob("build-*.json"))]
        if not records:
            print(f"no build-*.json under {a.input_dir}", file=sys.stderr)
            return 1
        summary, md = summarize_builds(records), builds_markdown
    elif a.cmd == "jobs":
        summary, md = summarize_jobs(json.loads(a.input.read_text(encoding="utf-8"))), jobs_markdown
    elif a.cmd == "runs":
        summary, md = summarize_runs(json.loads(a.input.read_text(encoding="utf-8"))), runs_markdown
    else:
        summary, md = summarize_deploys(load_jsonl(a.input)), deploys_markdown
        if a.prom:
            # The Pushgateway rejects CRLF; force "\n" even on Windows.
            sys.stdout.buffer.write(deploys_prom(summary).encode("utf-8"))
            sys.stdout.flush()
            return 0

    text = json.dumps(summary, indent=2, default=str)
    if a.output:
        a.output.write_text(text + "\n", encoding="utf-8")
    if a.markdown:
        with a.markdown.open("a", encoding="utf-8") as fh:
            fh.write(md(summary) + "\n")
    print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
