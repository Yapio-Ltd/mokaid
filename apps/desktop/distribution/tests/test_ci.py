from __future__ import annotations
import argparse
import json
import os
import re
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1]))
import ci


class CiTests(unittest.TestCase):
    def test_production_rollout_state_is_explicit_non_secret_and_keeps_acm_enabled(self):
        source = (ci.DESKTOP.parents[1] / "infra/terraform/environments/prod/desktop.auto.tfvars").read_text()
        entries = {}
        for line in source.splitlines():
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            match = re.fullmatch(r"(desktop_downloads_enabled|desktop_downloads_external_dns_ready)\s*=\s*(true|false)", line.strip())
            self.assertIsNotNone(match, "The tracked rollout file must contain only the two non-secret boolean switches")
            self.assertNotIn(match[1], entries)
            entries[match[1]] = match[2]
        self.assertEqual(entries.get("desktop_downloads_enabled"), "true", "The provisioned ACM certificate must remain enabled in default production plans")
        self.assertIn("desktop_downloads_external_dns_ready", entries)

    def test_existing_metal_compiler_does_not_download_a_component(self):
        with patch.object(ci.subprocess, "run", return_value=SimpleNamespace(returncode=0)), patch.object(ci, "run") as run:
            self.assertEqual(ci.metal_options(), [])
        run.assert_not_called()

    def test_downloaded_metal_uses_reported_toolchain_identifier(self):
        identifier = "com.apple.dt.toolchain.Metal.test-fixture"
        def output(*args, **kwargs):
            return json.dumps({"status": "installed", "toolchainIdentifier": identifier}) if "-showComponent" in args else ""
        with patch.object(ci.subprocess, "run", return_value=SimpleNamespace(returncode=1)), patch.object(ci, "run", side_effect=output) as run:
            self.assertEqual(ci.metal_options(), [f"-DMOKAID_METAL_TOOLCHAIN={identifier}"])
            run.assert_any_call("xcodebuild", "-downloadComponent", "MetalToolchain")
            run.assert_any_call("xcrun", "--toolchain", identifier, "-sdk", "macosx", "metal", "--version")

    def test_unregistered_metal_component_fails_closed(self):
        with patch.object(ci.subprocess, "run", return_value=SimpleNamespace(returncode=1)), patch.object(ci, "run", return_value='{"status":"missing"}'):
            with self.assertRaisesRegex(ValueError, "register"):
                ci.metal_options()

    def test_assets_are_cooked_before_cmake_and_real_asset_test_is_required(self):
        for registered in (True, False):
            with self.subTest(registered=registered), tempfile.TemporaryDirectory(prefix="mokaid-ci-test-") as temp:
                desktop = Path(temp)
                (desktop / "build").mkdir()
                events = []
                def command(*args, **kwargs):
                    events.append(args)
                    if "sdk" in args: return str(desktop / "sdk")
                    if "--show-only=json-v1" in args:
                        return json.dumps({"tests": [{"name": "desktop.real_assets"}] if registered else []})
                    return ""
                with patch.object(ci, "DESKTOP", desktop), patch.object(ci.platform, "system", return_value="Darwin"), \
                     patch.object(ci, "cook_assets", side_effect=lambda: events.append(("cook-fixture",))), \
                     patch.object(ci, "metal_options", return_value=[]), patch.object(ci, "run", side_effect=command), \
                     patch.dict(os.environ, {"RUNNER_TEMP": temp}):
                    if registered:
                        ci.configure(argparse.Namespace(release=False))
                    else:
                        with self.assertRaisesRegex(ValueError, "real cooked-asset test"):
                            ci.configure(argparse.Namespace(release=False))
                cooked = events.index(("cook-fixture",))
                configured = next(i for i, event in enumerate(events) if event[:2] == ("cmake", "--preset"))
                self.assertLess(cooked, configured)
                ran_tests = any(event[0] == "ctest" and "--output-on-failure" in event for event in events)
                self.assertEqual(ran_tests, registered)

    def test_staging_reuses_tested_assets_without_running_the_cooker(self):
        with tempfile.TemporaryDirectory(prefix="mokaid-ci-test-") as temp:
            desktop = Path(temp)
            (desktop / "build").mkdir()
            (desktop / "build/ci.json").write_text(json.dumps({"platform": "macos-arm64", "preset": "macos-release", "sdk": "/test-sdk"}))
            with patch.object(ci, "DESKTOP", desktop), patch.object(ci, "validate_assets") as validate, \
                 patch.object(ci, "run") as run, patch.dict(os.environ, {"QT_ROOT_DIR": "/test-qt"}):
                ci.stage()
                validate.assert_called_once_with(desktop / "build/assets")
                self.assertEqual(run.call_count, 1)
                self.assertIn("stage", run.call_args.args)


if __name__ == "__main__":
    unittest.main()
