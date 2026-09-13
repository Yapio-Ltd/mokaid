from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1]))
import ci


class CiTests(unittest.TestCase):
    def test_qt_installers_pin_the_reviewed_611_windows_layout_fix(self) -> None:
        workflows = ci.DESKTOP.parents[1] / ".github/workflows"
        source = "git+https://github.com/miurahr/aqtinstall.git@7e5a5c3d95cf962cfc2f36c86ffa0d2c07f1a0d4"
        action = (
            "jurplel/install-qt-action/action@d325aaf2a8baeeda41ad0b5d39f84a6af9bcf005"
        )
        for filename, expected in (("desktop-ci.yml", 1), ("desktop-release.yml", 2)):
            with self.subTest(workflow=filename):
                text = (workflows / filename).read_text()
                self.assertEqual(text.count(action), expected)
                self.assertEqual(text.count(f"aqtsource: '{source}'"), expected)
                self.assertEqual(text.count("version: '6.11.2'"), expected)
                self.assertEqual(text.count("py7zrversion: '==1.0.0'"), expected)
                self.assertNotIn("jurplel/install-qt-action@", text)
                self.assertNotIn("host: windows_x86_64", text)

    def test_macos_selects_installed_cpp20_xcode_before_conan_detection(self) -> None:
        for filename in ("desktop-ci.yml", "desktop-release.yml"):
            with self.subTest(workflow=filename):
                text = (
                    ci.DESKTOP.parents[1] / ".github/workflows" / filename
                ).read_text()
                selected = text.index(
                    "DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer"
                )
                self.assertIn('>> "$GITHUB_ENV"', text[selected:])
                self.assertLess(selected, text.index("ci.py configure-build-test"))
                self.assertIn(
                    "test -d /Applications/Xcode_26.3.app/Contents/Developer", text
                )

    def test_cmake_checks_required_standard_library_without_lowering_gates(
        self,
    ) -> None:
        text = (ci.DESKTOP / "CMakeLists.txt").read_text()
        self.assertIn("std::jthread worker", text)
        self.assertIn("std::stop_token token", text)
        self.assertIn("worker.request_stop()", text)
        self.assertIn("if(NOT MOKAID_HAS_CXX20_STOPPABLE_THREADS)", text)
        self.assertIn('message(FATAL_ERROR "Mokaid requires std::jthread', text)
        self.assertLess(
            text.index("MOKAID_HAS_CXX20_STOPPABLE_THREADS"),
            text.index("add_subdirectory(engine)"),
        )
        self.assertIn('set(CMAKE_OSX_DEPLOYMENT_TARGET "13.0"', text)
        self.assertNotIn("_LIBCPP_ENABLE_EXPERIMENTAL", text)

    def test_production_rollout_state_is_explicit_non_secret_and_keeps_acm_enabled(
        self,
    ) -> None:
        source = (
            ci.DESKTOP.parents[1]
            / "infra/terraform/environments/prod/desktop.auto.tfvars"
        ).read_text()
        entries: dict[str, str] = {}
        for line in source.splitlines():
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            match = re.fullmatch(
                r"(desktop_downloads_enabled|desktop_downloads_external_dns_ready|desktop_stable_signing_enabled)\s*=\s*(true|false)",
                line.strip(),
            )
            self.assertIsNotNone(
                match,
                "The tracked rollout file must contain only the three reviewed non-secret boolean switches",
            )
            assert match is not None
            self.assertNotIn(match[1], entries)
            entries[match[1]] = match[2]
        self.assertEqual(
            entries.get("desktop_downloads_enabled"),
            "true",
            "The provisioned ACM certificate must remain enabled in default production plans",
        )
        self.assertIn("desktop_downloads_external_dns_ready", entries)
        self.assertEqual(
            entries.get("desktop_stable_signing_enabled"),
            "true",
            "The approved independent stable signing role must remain enabled",
        )

    def test_existing_metal_compiler_does_not_download_a_component(self) -> None:
        with patch(
            "ci.subprocess.run", return_value=SimpleNamespace(returncode=0)
        ), patch.object(ci, "run") as run:
            self.assertEqual(ci.metal_options(), [])
        run.assert_not_called()

    def test_downloaded_metal_uses_reported_toolchain_identifier(self) -> None:
        identifier = "com.apple.dt.toolchain.Metal.test-fixture"

        def output(*args: object, **kwargs: object) -> str:
            return (
                json.dumps({"status": "installed", "toolchainIdentifier": identifier})
                if "-showComponent" in args
                else ""
            )

        with patch(
            "ci.subprocess.run", return_value=SimpleNamespace(returncode=1)
        ), patch.object(ci, "run", side_effect=output) as run:
            self.assertEqual(
                ci.metal_options(), [f"-DMOKAID_METAL_TOOLCHAIN={identifier}"]
            )
            run.assert_any_call("xcodebuild", "-downloadComponent", "MetalToolchain")
            run.assert_any_call(
                "xcrun",
                "--toolchain",
                identifier,
                "-sdk",
                "macosx",
                "metal",
                "--version",
            )

    def test_unregistered_metal_component_fails_closed(self) -> None:
        with patch(
            "ci.subprocess.run", return_value=SimpleNamespace(returncode=1)
        ), patch.object(
            ci, "run", return_value='{"status":"missing"}'
        ), self.assertRaisesRegex(
            ValueError, "register"
        ):
            ci.metal_options()

    def test_assets_are_cooked_before_cmake_and_real_asset_test_is_required(
        self,
    ) -> None:
        for registered in (True, False):
            with self.subTest(registered=registered):
                self.assert_asset_test_gate(registered)

    def assert_asset_test_gate(self, registered: bool) -> None:
        with tempfile.TemporaryDirectory(prefix="mokaid-ci-test-") as temp:
            desktop = Path(temp)
            (desktop / "build").mkdir()
            events: list[tuple[object, ...]] = []

            def command(*args: object, **kwargs: object) -> str:
                events.append(args)
                if "sdk" in args:
                    return str(desktop / "sdk")
                if "--show-only=json-v1" in args:
                    return json.dumps(
                        {
                            "tests": (
                                [{"name": "desktop.real_assets"}] if registered else []
                            )
                        }
                    )
                return ""

            with patch.object(ci, "DESKTOP", desktop), patch(
                "ci.platform.system", return_value="Darwin"
            ), patch.object(
                ci, "cook_assets", side_effect=lambda: events.append(("cook-fixture",))
            ), patch.object(
                ci, "metal_options", return_value=[]
            ), patch.object(
                ci, "run", side_effect=command
            ), patch.dict(
                os.environ, {"RUNNER_TEMP": temp}
            ):
                if registered:
                    ci.configure(argparse.Namespace(release=False))
                else:
                    with self.assertRaisesRegex(ValueError, "real cooked-asset test"):
                        ci.configure(argparse.Namespace(release=False))
            cooked = events.index(("cook-fixture",))
            configured = next(
                i
                for i, event in enumerate(events)
                if event[:2] == ("cmake", "--preset")
            )
            self.assertLess(cooked, configured)
            ran_tests = any(
                event[0] == "ctest" and "--output-on-failure" in event
                for event in events
            )
            self.assertEqual(ran_tests, registered)

    def test_staging_reuses_tested_assets_without_running_the_cooker(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mokaid-ci-test-") as temp:
            desktop = Path(temp)
            (desktop / "build").mkdir()
            (desktop / "build/ci.json").write_text(
                json.dumps(
                    {
                        "platform": "macos-arm64",
                        "preset": "macos-release",
                        "sdk": "/test-sdk",
                    }
                )
            )
            with patch.object(ci, "DESKTOP", desktop), patch.object(
                ci, "validate_assets"
            ) as validate, patch.object(ci, "run") as run, patch.dict(
                os.environ, {"QT_ROOT_DIR": "/test-qt"}
            ):
                ci.stage()
                validate.assert_called_once_with(desktop / "build/assets")
                self.assertEqual(run.call_count, 1)
                self.assertIn("stage", run.call_args.args)


if __name__ == "__main__":
    unittest.main()
