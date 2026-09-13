"""Production dispatch checks; all GitHub CLI execution is mocked."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("dispatch_production", Path(__file__).resolve().parents[1] / "dispatch_production.py")
dispatch = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(dispatch)
COMMIT = "a" * 40


class DispatchTests(unittest.TestCase):
    def setUp(self):
        self.stdout, self.stderr = io.StringIO(), io.StringIO()
        self.enterContext(contextlib.redirect_stdout(self.stdout))
        self.enterContext(contextlib.redirect_stderr(self.stderr))
        self.process = self.enterContext(patch.object(dispatch.subprocess, "run", side_effect=AssertionError("Unmocked external command")))

    def test_dispatch_only_exact_production_workflow_after_ci(self):
        results = [COMMIT, json.dumps([{"status": "completed", "conclusion": "success"}]), COMMIT, ""]
        with patch.object(dispatch, "gh", side_effect=results) as gh:
            dispatch.dispatch(["prod"])
        self.assertEqual(gh.call_count, 4)
        self.assertEqual(gh.call_args_list[-1].args, ("workflow", "run", "deploy.yml", "--repo", "Yapio-Ltd/mokaid",
                                                   "--ref", "prod", "--field", "environment=prod"))
        self.assertIn(COMMIT, gh.call_args_list[1].args)
        self.assertEqual(gh.call_args_list[0].args, gh.call_args_list[2].args)
        self.assertIn("not deployment confirmation", self.stdout.getvalue())
        self.process.assert_not_called()

    def test_old_environment_tag_and_missing_inputs_fail_before_external_calls(self):
        for arguments in ([], ["dev"], ["prod", "latest"], ["prod", COMMIT], ["--ref", "prod"]):
            with self.assertRaisesRegex(dispatch.Failure, "Usage"):
                dispatch.dispatch(arguments)
        self.process.assert_not_called()

    def test_no_successful_exact_push_ci_never_dispatches(self):
        for result in ([], {}, [{"status": "in_progress", "conclusion": "success"}],
                       [{"status": "completed", "conclusion": "failure"}]):
            with patch.object(dispatch, "gh", side_effect=[COMMIT, json.dumps(result)]) as gh:
                with self.assertRaisesRegex(dispatch.Failure, "no successful"):
                    dispatch.dispatch(["prod"])
            self.assertEqual(gh.call_count, 2)

    def test_changed_head_requires_new_ci_not_stale_dispatch(self):
        with patch.object(dispatch, "gh", side_effect=[COMMIT, '[{"status":"completed","conclusion":"success"}]', "b" * 40]) as gh:
            with self.assertRaisesRegex(dispatch.Failure, "head changed"):
                dispatch.dispatch(["prod"])
        self.assertEqual(gh.call_count, 3)

    def test_invalid_head_or_ci_response_never_dispatches(self):
        for results in (["main"], [COMMIT + "\nforged"], [COMMIT, "not json"]):
            with patch.object(dispatch, "gh", side_effect=results):
                with self.assertRaises(dispatch.Failure):
                    dispatch.dispatch(["prod"])

    def test_unconfirmed_dispatch_is_not_automatically_retried(self):
        results = [COMMIT, '[{"status":"completed","conclusion":"success"}]', COMMIT, dispatch.Failure("Lost response")]
        with patch.object(dispatch, "gh", side_effect=results) as gh:
            with self.assertRaisesRegex(dispatch.Failure, "inspect the production workflow before retrying"):
                dispatch.dispatch(["prod"])
        self.assertEqual(gh.call_count, 4)
        self.assertNotIn("Requested production workflow", self.stdout.getvalue())

    def test_gh_is_bounded_fixed_host_and_sensitive_errors_suppressed(self):
        sensitive = "FIXTURE_SECRET_NOT_FOR_LOGGING"
        def external(command, **kwargs):
            self.assertEqual(command, ["gh", "api", "test"])
            self.assertEqual(kwargs["env"]["GH_HOST"], "github.com")
            self.assertEqual(kwargs["env"]["GH_PROMPT_DISABLED"], "1")
            self.assertEqual(kwargs["timeout"], 60)
            return subprocess.CompletedProcess(command, 1, sensitive, sensitive)
        with patch.object(dispatch.subprocess, "run", side_effect=external):
            with self.assertRaises(dispatch.Failure) as error:
                dispatch.gh("api", "test")
        self.assertNotIn(sensitive, str(error.exception) + self.stdout.getvalue() + self.stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
