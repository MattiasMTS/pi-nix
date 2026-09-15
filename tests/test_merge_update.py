import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/merge-update.sh"
MOCK_GH = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
with Path(os.environ["GH_CALL_LOG"]).open("a") as log:
    log.write(json.dumps(args) + "\n")
scenario = os.environ["SCENARIO"]
if args[0] == "api":
    if scenario == "dispatch_failure":
        sys.exit(1)
    print("null" if scenario == "missing_run_id" else "12345")
elif args[:2] == ["run", "watch"]:
    if scenario == "build_failure":
        sys.exit(1)
elif args[:2] == ["run", "view"]:
    print("changed-commit" if scenario == "wrong_build_commit" else "tested-commit")
elif args[:2] == ["pr", "merge"]:
    if scenario == "merge_rejected":
        sys.exit(1)
elif args[:2] == ["workflow", "run"]:
    if scenario == "main_dispatch_failure":
        sys.exit(1)
else:
    sys.exit("Unexpected gh invocation: " + repr(args))
'''


class MergeUpdateTest(unittest.TestCase):
    def run_scenario(self, scenario, script=SCRIPT):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            gh = root / "gh"
            gh.write_text(MOCK_GH)
            gh.chmod(0o755)
            git = root / "git"
            git.write_text('''#!/usr/bin/env python3
import os
import sys
if sys.argv[-1] == "HEAD":
    print("main-commit")
elif os.environ["SCENARIO"] == "missing_latest_tag":
    sys.exit(1)
else:
    print("main-commit" if os.environ["SCENARIO"] == "released_main" else "older-commit")
''')
            git.chmod(0o755)
            log = root / "calls.jsonl"
            result = subprocess.run(
                ["bash", str(script)],
                env={
                    **os.environ,
                    "PATH": f"{root}{os.pathsep}{os.environ['PATH']}",
                    "GH_REPO": "owner/repo",
                    "GH_TOKEN": "test-token",
                    "PR_NUMBER": "42",
                    "HEAD_SHA": "tested-commit",
                    "GH_CALL_LOG": str(log),
                    "SCENARIO": scenario,
                },
                capture_output=True,
                text=True,
                timeout=10,
            )
            calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            return result, calls

    def test_success_builds_branch_merges_tested_commit_then_builds_main(self):
        result, calls = self.run_scenario("success")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls[0][0:2], ["api", "repos/owner/repo/actions/workflows/build.yml/dispatches"])
        self.assertIn("ref=update-pi", calls[0])
        self.assertIn("X-GitHub-Api-Version: 2026-03-10", calls[0])
        self.assertEqual(calls[1], ["run", "watch", "12345", "--exit-status", "--interval", "15"])
        self.assertEqual(calls[2], ["run", "view", "12345", "--json", "headSha", "--jq", ".headSha"])
        self.assertEqual(calls[3], ["pr", "merge", "42", "--squash", "--delete-branch", "--match-head-commit", "tested-commit"])
        self.assertEqual(calls[4], ["workflow", "run", "build.yml", "--ref", "main"])

    def test_dispatch_errors_do_not_watch_or_merge(self):
        for scenario in ["dispatch_failure", "missing_run_id"]:
            with self.subTest(scenario=scenario):
                result, calls = self.run_scenario(scenario)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(len(calls), 1)

    def test_failed_build_leaves_pr_open(self):
        result, calls = self.run_scenario("build_failure")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls[-1][:2], ["run", "watch"])
        self.assertFalse(any(call[:2] == ["pr", "merge"] for call in calls))

    def test_different_built_commit_is_not_merged(self):
        result, calls = self.run_scenario("wrong_build_commit")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expected tested-commit", result.stderr)
        self.assertFalse(any(call[:2] == ["pr", "merge"] for call in calls))

    def test_rejected_merge_does_not_start_main_build(self):
        result, calls = self.run_scenario("merge_rejected")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls[-1][:2], ["pr", "merge"])
        self.assertFalse(any(call[:2] == ["workflow", "run"] for call in calls))

    def test_main_dispatch_failure_is_reported(self):
        result, calls = self.run_scenario("main_dispatch_failure")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls[-1], ["workflow", "run", "build.yml", "--ref", "main"])

    def test_next_updater_run_recovers_failed_main_dispatch(self):
        result, _ = self.run_scenario("main_dispatch_failure")
        self.assertNotEqual(result.returncode, 0)
        result, calls = self.run_scenario("unreleased_main", SCRIPT.with_name("build-main.sh"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [["workflow", "run", "build.yml", "--ref", "main"]])

    def test_missing_latest_tag_starts_main_build(self):
        result, calls = self.run_scenario("missing_latest_tag", SCRIPT.with_name("build-main.sh"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [["workflow", "run", "build.yml", "--ref", "main"]])

    def test_released_main_does_not_rebuild_hourly(self):
        result, calls = self.run_scenario("released_main", SCRIPT.with_name("build-main.sh"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
