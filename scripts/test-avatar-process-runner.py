"""Credential isolation and deadline regression checks; no Blender required."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

RUNNER = Path(__file__).with_name("avatar-process-runner.py")


class ProcessRunnerTest(unittest.TestCase):
    def test_child_only_receives_tool_environment(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "tool.log"
            env = dict(os.environ, DATABASE_URL="private-test-value", MESHY_API_KEY="private-test-key")
            result = subprocess.run([sys.executable, str(RUNNER), "--timeout", "5", "--log", str(log),
                                     "--", sys.executable, "-c", "import os,json; print(json.dumps(dict(os.environ)))"], env=env)
            self.assertEqual(result.returncode, 0)
            child_env = json.loads(log.read_text())
            self.assertNotIn("DATABASE_URL", child_env)
            self.assertNotIn("MESHY_API_KEY", child_env)
            self.assertEqual(child_env["OMP_NUM_THREADS"], "2")
            self.assertNotEqual(child_env["HOME"], os.environ.get("HOME"))

    def test_timeout_terminates_child_and_reports_timeout(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "tool.log"
            started = time.monotonic()
            result = subprocess.run([sys.executable, str(RUNNER), "--timeout", "1", "--log", str(log),
                "--", sys.executable, "-c", "import os,time; print(os.getpid(),flush=True); time.sleep(30)"])
            self.assertEqual(result.returncode, 124)
            self.assertLess(time.monotonic() - started, 8)
            with self.assertRaises(ProcessLookupError):
                os.kill(int(log.read_text().strip()), 0)

    def test_runner_termination_reaps_child(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "tool.log"
            runner = subprocess.Popen([sys.executable, str(RUNNER), "--timeout", "30", "--log", str(log),
                "--", sys.executable, "-c", "import os,time; print(os.getpid(),flush=True); time.sleep(30)"])
            try:
                deadline = time.monotonic() + 5
                while (not log.exists() or not log.read_text().strip()) and time.monotonic() < deadline:
                    time.sleep(.02)
                child_pid = int(log.read_text().strip())
                runner.terminate()
                self.assertEqual(runner.wait(timeout=8), 128 + signal.SIGTERM)
                with self.assertRaises(ProcessLookupError):
                    os.kill(child_pid, 0)
            finally:
                if runner.poll() is None:
                    runner.kill()
                    runner.wait()


if __name__ == "__main__":
    unittest.main()
