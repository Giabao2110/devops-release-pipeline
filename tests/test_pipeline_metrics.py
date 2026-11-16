import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import pipeline_metrics as pm  # noqa: E402

FIX = Path(__file__).parent / "fixtures"


class PercentileTest(unittest.TestCase):
    def test_nearest_rank(self):
        self.assertEqual(pm.percentile([10, 20, 30, 40, 50, 60, 70, 80, 90, 100], 90), 90)
        self.assertEqual(pm.percentile([5], 50), 5)
        self.assertIsNone(pm.percentile([], 50))


class BuildsTest(unittest.TestCase):
    def test_summary_counts_failures_and_sizes(self):
        s = pm.summarize_builds([
            {"target": "linux-amd64", "status": "success", "duration_seconds": 20, "size_bytes": 2048, "sha256": "a" * 64},
            {"target": "linux-arm64", "status": "success", "duration_seconds": 30, "size_bytes": 1024, "sha256": "b" * 64},
            {"target": "windows-amd64", "status": "failure", "duration_seconds": 10, "size_bytes": 0},
        ])
        self.assertEqual((s["targets"], s["succeeded"], s["failed"]), (3, 2, 1))
        self.assertAlmostEqual(s["failure_rate"], 0.3333)
        self.assertEqual(s["total_artifact_bytes"], 3072)
        self.assertEqual(s["build_seconds"]["max"], 30)
        self.assertIn("| linux-amd64 | success | 20 | 2 |", pm.builds_markdown(s))


class JobsTest(unittest.TestCase):
    def test_skips_running_jobs_and_finds_failures(self):
        s = pm.summarize_jobs(json.loads((FIX / "jobs.json").read_text()))
        self.assertEqual(s["jobs"], 3)            # metrics job still in progress
        self.assertEqual(s["failed_jobs"], ["deploy-kind"])
        self.assertEqual(s["wall_clock_seconds"], 300.0)
        self.assertEqual(s["job_seconds"]["max"], 180.0)


class RunsTest(unittest.TestCase):
    def test_failure_rate_excludes_cancelled(self):
        s = pm.summarize_runs(json.loads((FIX / "runs.json").read_text()))
        ci = s["workflows"]["ci"]
        self.assertEqual(ci["runs"], 5)
        self.assertEqual(ci["cancelled"], 1)
        self.assertEqual(ci["failed"], 1)
        self.assertEqual(ci["failure_rate"], 0.25)
        self.assertEqual(ci["duration_seconds"]["p90"], 400.0)

    def test_accepts_api_shape(self):
        payload = {"workflow_runs": [{"name": "release", "status": "completed", "conclusion": "success",
                                      "run_started_at": "2026-11-16T00:00:00Z", "updated_at": "2026-11-16T00:02:00Z"}]}
        self.assertEqual(pm.summarize_runs(payload)["workflows"]["release"]["duration_seconds"]["mean"], 120.0)


class DeploysTest(unittest.TestCase):
    def test_rollback_rate_and_prom_output(self):
        events = pm.load_jsonl(FIX / "deploy-events.jsonl")
        s = pm.summarize_deploys(events)
        self.assertEqual(s["deployments"], 4)
        self.assertEqual(s["by_result"], {"success": 3, "rolled_back": 1, "rollback_failed": 0})
        self.assertEqual(s["rollback_rate"], 0.25)
        prom = pm.deploys_prom(s)
        self.assertIn('release_deployments_total{result="rolled_back"} 1', prom)
        self.assertIn("release_last_deploy_success 1", prom)
        self.assertIn("# TYPE release_deployments_total counter", prom)

    def test_bad_line_reports_location(self):
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / "e.jsonl"
            f.write_text('{"result":"success"}\nnot-json\n')
            with self.assertRaises(SystemExit) as ctx:
                pm.load_jsonl(f)
            self.assertIn("e.jsonl:2", str(ctx.exception))

    def test_cli_writes_markdown(self):
        with tempfile.TemporaryDirectory() as d:
            md = Path(d) / "summary.md"
            rc = pm.main(["deploys", "--input", str(FIX / "deploy-events.jsonl"), "--markdown", str(md)])
            self.assertEqual(rc, 0)
            self.assertIn("rollback rate 25.0%", md.read_text())


if __name__ == "__main__":
    unittest.main()
