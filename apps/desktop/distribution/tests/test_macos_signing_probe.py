"""Offline signing-probe regression tests; no owner credentials or Apple calls."""

from __future__ import annotations

import importlib
import argparse
import asyncio
import json
import os
from pathlib import Path
import plistlib
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock, Mock, patch

sys.path.insert(0, str(Path(__file__).parents[1]))


class ProbeContextTests(unittest.TestCase):
    def module(self):
        return importlib.import_module("macos_signing_probe")

    def environment(self):
        sha = "a" * 40
        return {
            "GITHUB_ACTIONS": "true",
            "GITHUB_EVENT_NAME": "workflow_dispatch",
            "GITHUB_REPOSITORY": "Yapio-Ltd/mokaid",
            "GITHUB_REF": "refs/heads/main",
            "GITHUB_REF_PROTECTED": "true",
            "GITHUB_SHA": sha,
            "GITHUB_WORKFLOW_SHA": sha,
            "PROBE_SOURCE_SHA": sha,
            "GITHUB_WORKFLOW_REF": "Yapio-Ltd/mokaid/.github/workflows/desktop-macos-signing-probe.yml@refs/heads/main",
            "GITHUB_RUN_ID": "123456",
            "GITHUB_RUN_ATTEMPT": "1",
            "RUNNER_ENVIRONMENT": "github-hosted",
        }

    def test_dispatch_is_bound_to_exact_reviewed_main_and_workflow(self):
        probe = self.module()
        with patch.dict(os.environ, self.environment(), clear=True):
            result = probe.context("0.1.0")
        self.assertEqual(result["sourceCommit"], "a" * 40)
        self.assertEqual(result["purpose"], "private-macos-signing-probe")
        self.assertEqual(result["channel"], "stable")
        # main currently has no branch ruleset; authorization is an exact SHA
        # plus the existing required environment approval, not a made-up ruleset.
        with patch.dict(
            os.environ,
            {**self.environment(), "GITHUB_REF_PROTECTED": "false"},
            clear=True,
        ):
            self.assertEqual(probe.context("0.1.0")["sourceCommit"], "a" * 40)

    def test_other_events_refs_repositories_sha_and_versions_fail_closed(self):
        probe = self.module()
        changes = {
            "GITHUB_EVENT_NAME": "pull_request",
            "GITHUB_REF": "refs/tags/desktop-v0.1.0",
            "GITHUB_REPOSITORY": "attacker/mokaid",
            "GITHUB_WORKFLOW_SHA": "b" * 40,
            "PROBE_SOURCE_SHA": "b" * 40,
            "GITHUB_WORKFLOW_REF": "Yapio-Ltd/mokaid/.github/workflows/other.yml@refs/heads/main",
            "GITHUB_RUN_ID": "../123",
            "GITHUB_RUN_ATTEMPT": "0",
            "RUNNER_ENVIRONMENT": "self-hosted",
            "GITHUB_ACTIONS": "false",
        }
        for key, value in changes.items():
            with self.subTest(key=key), patch.dict(
                os.environ, {**self.environment(), key: value}, clear=True
            ):
                with self.assertRaises(probe.ProbeError):
                    probe.context("0.1.0")
        for version in ("0.1.0-beta.1", "../0.1.0", "01.0.0", "", "0.1.0;echo bad"):
            with self.subTest(version=version), patch.dict(
                os.environ, self.environment(), clear=True
            ):
                with self.assertRaises(probe.ProbeError):
                    probe.context(version)

    def test_probe_build_does_not_forge_a_release_tag(self):
        probe = self.module()
        import ci

        with patch.dict(os.environ, self.environment(), clear=True), patch.object(
            probe, "context", wraps=probe.context
        ) as checked:
            self.assertEqual(
                ci.probe_configuration("0.1.0"), ("0.1.0", "stable", "0.1.0")
            )
            checked.assert_called_once_with("0.1.0")
            self.assertNotIn("GITHUB_REF_NAME", os.environ)

    def test_runner_captures_output_removes_credentials_and_rejects_payload_execution(
        self,
    ):
        probe = self.module()
        runner = probe.CommandRunner()
        with patch.dict(
            os.environ,
            {
                "AWS_SECRET_ACCESS_KEY": "test-secret",
                "ACTIONS_ID_TOKEN_REQUEST_TOKEN": "test-token",
                "DYLD_INSERT_LIBRARIES": "/bad",
            },
        ), patch.object(
            probe, "execute", new=AsyncMock(return_value=(0, b"ok", b"private stderr"))
        ) as execute:
            self.assertEqual(
                runner("codesign", "--verify", "/tmp/fixture", capture=True), "ok"
            )
            environment = execute.call_args.args[1]
            self.assertFalse(
                any(
                    k in environment
                    for k in (
                        "AWS_SECRET_ACCESS_KEY",
                        "ACTIONS_ID_TOKEN_REQUEST_TOKEN",
                        "DYLD_INSERT_LIBRARIES",
                    )
                )
            )
            self.assertEqual(execute.call_args.args[0][0], "/usr/bin/codesign")
            for executable in (
                "/tmp/Mokaid.app/Contents/MacOS/Mokaid",
                "/bad/codesign",
                "bash",
                "aws",
                "curl",
            ):
                with self.subTest(executable=executable), self.assertRaises(
                    probe.ProbeError
                ):
                    runner(executable)

    def test_notary_requires_accepted_json_and_records_only_public_submission_identity(
        self,
    ):
        probe = self.module()
        runner = probe.CommandRunner()
        identifier = "12345678-1234-1234-1234-123456789abc"
        payload = json.dumps(
            {
                "id": identifier,
                "status": "Accepted",
                "message": "IGNORED PRIVATE DETAILS",
            }
        ).encode()
        with patch.object(
            probe, "execute", new=AsyncMock(return_value=(0, payload, b""))
        ):
            self.assertEqual(runner("xcrun", "notarytool", "submit", "fixture.dmg"), "")
        self.assertEqual(runner.submissions, [identifier])
        for code, value in (
            (1, payload),
            (0, b"not-json"),
            (0, b'{"status":"Invalid"}'),
            (0, b'{"status":"In Progress"}'),
            (0, b'{"status":"Accepted","id":"not-a-uuid"}'),
        ):
            with self.subTest(value=value), patch.object(
                probe,
                "execute",
                new=AsyncMock(return_value=(code, value, b"DO NOT PRINT")),
            ):
                with self.assertRaises(probe.ProbeError) as error:
                    runner("xcrun", "notarytool", "submit", "fixture.dmg")
                self.assertNotIn("DO NOT PRINT", str(error.exception))

    def test_command_timeout_reaps_process_group_and_suppresses_remote_output(self):
        probe = self.module()
        process = Mock(pid=999999, returncode=None)
        process.stdout.read = AsyncMock(side_effect=asyncio.TimeoutError)
        process.stderr.read = AsyncMock(return_value=b"")
        process.wait = AsyncMock(return_value=9)
        with patch.object(
            probe.asyncio, "create_subprocess_exec", new=AsyncMock(return_value=process)
        ), patch.object(probe.os, "killpg", create=True) as kill, patch.object(
            probe.signal, "SIGKILL", 9, create=True
        ):
            with self.assertRaises(probe.ProbeError):
                asyncio.run(probe.execute(["/usr/bin/codesign"], {}, 1))
        kill.assert_called_once()
        process.wait.assert_awaited_once()

    def test_no_execute_mode_does_not_read_credentials_restore_or_contact_apple(self):
        probe = self.module()
        with patch.dict(os.environ, self.environment(), clear=True), patch.object(
            probe, "read_credentials"
        ) as read, patch.object(probe, "restore_stage") as restore:
            result = probe.sign(argparse.Namespace(version="0.1.0", execute=False))
        self.assertEqual(result["status"], "planned")
        self.assertFalse(result["published"])
        read.assert_not_called()
        restore.assert_not_called()

    def test_bundle_rejects_missing_webengine_sparkle_wrong_version_key_and_development(
        self,
    ):
        probe = self.module()
        with tempfile.TemporaryDirectory() as folder:
            stage = Path(folder)
            app = stage / "Mokaid.app"
            resources = app / "Contents/Resources"
            resources.mkdir(parents=True)
            info = {
                "CFBundleVersion": "0.1.0",
                "CFBundleIdentifier": "com.mokaid.desktop",
                "SUPublicEDKey": "public-fixture",
                "CFBundleExecutable": "Mokaid",
            }
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
            with patch.object(probe, "packaging_module") as packaging:
                packaging.return_value.require_release_stage = Mock()
                packaging.return_value.validate_assets = Mock()
                with self.assertRaises(probe.ProbeError):
                    probe.inspect_bundle(stage, "0.1.0", "public-fixture")

    def test_signing_uses_ephemeral_stage_and_cannot_emit_release_evidence(self):
        probe = self.module()
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
        import base64

        seed = b"1" * 32
        key = Ed25519PrivateKey.from_private_bytes(seed)
        public = base64.b64encode(key.public_key().public_bytes_raw()).decode()
        package = Mock()
        runner = Mock(
            submissions=[
                "12345678-1234-1234-1234-123456789abc",
                "12345678-1234-1234-1234-123456789abd",
            ]
        )
        runner.return_value = "unchanged keychain list"
        roots = []

        def restore(args, stage):
            stage.mkdir()
            (stage / "Mokaid.app").mkdir()
            roots.append(stage.parent)

        def package_macos(args, secret):
            artifact = args.output / "private.dmg"
            artifact.write_bytes(b"synthetic DMG fixture")
            return artifact

        package.package_macos.side_effect = package_macos
        args = argparse.Namespace(
            version="0.1.0", execute=True, manifest_sha256="b" * 64
        )
        with patch.dict(
            os.environ,
            {**self.environment(), "MOKAID_UPDATE_PUBLIC_KEY": public},
            clear=True,
        ), patch.object(probe.platform, "system", return_value="Darwin"), patch.object(
            probe,
            "read_credentials",
            return_value={"update_ed25519_seed": base64.b64encode(seed).decode()},
        ), patch.object(
            probe, "restore_stage", side_effect=restore
        ), patch.object(
            probe, "inspect_bundle", return_value={"frameworks": ["QtCore", "Sparkle"]}
        ), patch.object(
            probe, "verify_signed_bundle"
        ), patch.object(
            probe, "packaging_module", return_value=package
        ), patch.object(
            probe, "CommandRunner", return_value=runner
        ), patch.object(
            probe, "verify_checkout"
        ):
            result = probe.sign(args)
        self.assertEqual(result["status"], "verified")
        self.assertFalse(result["published"])
        self.assertFalse(result["productExecuted"])
        self.assertTrue(result["temporaryFilesRemoved"])
        self.assertTrue(result["updateKeyVerified"])
        self.assertFalse(any(path.exists() for path in roots))
        self.assertNotIn("evidenceSignature", result)
        self.assertNotIn("edSignature", result)
        package.write_evidence.assert_not_called()
        package.package.assert_not_called()

    def test_failed_package_removes_temp_and_does_not_return_success(self):
        probe = self.module()
        roots = []

        def restore(args, stage):
            stage.mkdir()
            roots.append(stage.parent)

        package = Mock()
        package.package_macos.side_effect = RuntimeError("SENSITIVE APPLE ERROR")
        runner = Mock(return_value="unchanged")
        args = argparse.Namespace(
            version="0.1.0", execute=True, manifest_sha256="b" * 64
        )
        with patch.dict(
            os.environ,
            {**self.environment(), "MOKAID_UPDATE_PUBLIC_KEY": "fixture"},
            clear=True,
        ), patch.object(probe.platform, "system", return_value="Darwin"), patch.object(
            probe, "read_credentials", return_value={}
        ), patch.object(
            probe, "restore_stage", side_effect=restore
        ), patch.object(
            probe, "inspect_bundle", return_value={}
        ), patch.object(
            probe, "packaging_module", return_value=package
        ), patch.object(
            probe, "CommandRunner", return_value=runner
        ), patch.object(
            probe, "verify_checkout"
        ):
            with self.assertRaises(probe.ProbeError) as error:
                probe.sign(args)
        self.assertNotIn("SENSITIVE", str(error.exception))
        self.assertFalse(any(path.exists() for path in roots))

    def test_read_credentials_uses_only_explicit_temporary_role_and_pinned_secret(self):
        probe = self.module()
        region, account = probe.credentials.REGION, probe.credentials.ACCOUNT
        session = Mock()
        sts, secrets = Mock(), Mock()
        sts.get_caller_identity.return_value = {
            "Account": account,
            "Arn": f"arn:aws:sts::{account}:assumed-role/{probe.ROLE}/desktop-probe-123456",
        }
        session.client.side_effect = [sts, secrets]
        boto = Mock()
        boto.Session.return_value = session
        real_import = importlib.import_module

        def imported(name, *args):
            return boto if name == "boto3" else real_import(name, *args)

        document = {
            key: "SYNTHETIC-NOT-REAL"
            for key in (
                "developer_id_p12",
                "p12_password",
                "developer_id_identity",
                "developer_id_certificate_sha256",
                "notary_key_p8",
                "update_ed25519_seed",
            )
        }
        document.update(
            notary_issuer=probe.credentials.ISSUER, notary_key_id="FAKEKEY1234"
        )
        env = {
            **self.environment(),
            "AWS_REGION": region,
            "AWS_ACCESS_KEY_ID": "SYNTHETIC",
            "AWS_SECRET_ACCESS_KEY": "SYNTHETIC",
            "AWS_SESSION_TOKEN": "SYNTHETIC",
            "MOKAID_SIGNING_SECRET_ARN": probe.credentials.SECRET_ARN,
            "MOKAID_UPDATE_PUBLIC_KEY": "test-public-key",
            "AWS_ENDPOINT_URL": "https://attacker.invalid",
        }
        with patch.dict(os.environ, env, clear=True), patch.object(
            probe.importlib, "import_module", side_effect=imported
        ), patch.object(
            probe.stage_archive, "public_key", return_value="test-public-key"
        ), patch.object(
            probe.credentials,
            "read_current",
            return_value=SimpleNamespace(document=document),
        ) as read:
            self.assertEqual(probe.read_credentials(), document)
            read.assert_called_once_with(secrets)
        self.assertEqual(
            [call.args[0] for call in session.client.call_args_list],
            ["sts", "secretsmanager"],
        )
        self.assertEqual(
            [call.kwargs["endpoint_url"] for call in session.client.call_args_list],
            [
                f"https://sts.{region}.amazonaws.com",
                f"https://secretsmanager.{region}.amazonaws.com",
            ],
        )
        self.assertEqual(
            boto.Session.call_args.kwargs["aws_session_token"], "SYNTHETIC"
        )
        secrets.put_secret_value.assert_not_called()

    def test_missing_or_out_of_scope_signing_configuration_never_contacts_aws(self):
        probe = self.module()
        cases = [
            ({}, "secret"),
            ({"MOKAID_SIGNING_SECRET_ARN": "arn:wrong"}, "secret"),
            ({"MOKAID_SIGNING_SECRET_ARN": probe.credentials.SECRET_ARN}, "OIDC"),
        ]
        for extra, message in cases:
            with self.subTest(extra=extra), patch.dict(
                os.environ, extra, clear=True
            ), patch.object(probe.importlib, "import_module") as imported:
                with self.assertRaisesRegex(probe.ProbeError, message):
                    probe.read_credentials()
                imported.assert_not_called()

    def test_checkout_rejects_moved_main_and_lookup_errors(self):
        probe = self.module()
        with patch.object(
            probe.subprocess,
            "run",
            return_value=SimpleNamespace(stdout="a" * 40 + "\n" + "a" * 40 + "\n"),
        ):
            probe.verify_checkout({"sourceCommit": "a" * 40})
        for output in ("a" * 40 + "\n" + "b" * 40 + "\n", ""):
            with patch.object(
                probe.subprocess, "run", return_value=SimpleNamespace(stdout=output)
            ), self.assertRaises(probe.ProbeError):
                probe.verify_checkout({"sourceCommit": "a" * 40})
        with patch.object(
            probe.subprocess, "run", side_effect=OSError("private path")
        ), self.assertRaises(probe.ProbeError):
            probe.verify_checkout({"sourceCommit": "a" * 40})

    def test_restore_includes_every_exact_provenance_field(self):
        probe = self.module()
        with patch.dict(
            os.environ,
            {**self.environment(), "MOKAID_UPDATE_PUBLIC_KEY": "key-fixture"},
            clear=True,
        ), patch.object(probe.stage_archive, "restore") as restore:
            probe.restore_stage(
                argparse.Namespace(
                    version="0.1.0", input=Path("unsigned"), manifest_sha256="b" * 64
                ),
                Path("ephemeral/stage"),
            )
        args = restore.call_args.args[0]
        self.assertEqual(
            (args.commit, args.tooling_sha, args.run_id, args.run_attempt),
            ("a" * 40, "a" * 40, "123456", "1"),
        )
        self.assertEqual(
            (args.manifest_sha256, args.platform, args.channel, args.public_key),
            ("b" * 64, "macos-arm64", "stable", "key-fixture"),
        )

    def test_real_archive_corruption_stops_before_secret_read(self):
        probe = self.module()
        with tempfile.TemporaryDirectory() as folder:
            args = argparse.Namespace(
                version="0.1.0",
                execute=True,
                input=Path(folder),
                manifest_sha256="b" * 64,
            )
            with patch.dict(
                os.environ,
                {
                    **self.environment(),
                    "MOKAID_UPDATE_PUBLIC_KEY": probe.stage_archive.public_key(
                        "stable"
                    ),
                },
                clear=True,
            ), patch.object(
                probe.platform, "system", return_value="Darwin"
            ), patch.object(
                probe, "verify_checkout"
            ), patch.object(
                probe, "CommandRunner", return_value=Mock(return_value="unchanged")
            ), patch.object(
                probe, "read_credentials"
            ) as read:
                with self.assertRaises(probe.ProbeError):
                    probe.sign(args)
            read.assert_not_called()

    def test_complete_fixture_checks_exact_framework_versions_and_required_content(
        self,
    ):
        probe = self.module()
        pins = json.loads((probe.HERE / "dependencies.json").read_text())
        with tempfile.TemporaryDirectory() as folder:
            stage = Path(folder)
            app = stage / "Mokaid.app"
            for item in (
                "Contents/Resources/shaders",
                "Contents/MacOS",
                "Contents/Frameworks",
                "Contents/Frameworks/QtWebEngineProcess.app",
                "Contents/Frameworks/Downloader.xpc",
                "Contents/Frameworks/Installer.xpc",
            ):
                (app / item).mkdir(parents=True, exist_ok=True)
            (app / "Contents/Resources/shaders/office.metallib").write_bytes(b"TEST")
            (app / "Contents/MacOS/Mokaid").write_bytes(b"TEST")
            info = {
                "CFBundleVersion": "0.1.0",
                "CFBundleIdentifier": "com.mokaid.desktop",
                "SUPublicEDKey": "fixture",
                "CFBundleExecutable": "Mokaid",
            }
            plist = app / "Contents/Info.plist"
            plist.write_bytes(plistlib.dumps(info))
            for name in probe.FRAMEWORKS:
                framework = app / "Contents/Frameworks" / f"{name}.framework"
                (framework / "Resources").mkdir(parents=True)
                (framework / name).write_bytes(b"TEST")
                (framework / "Resources/Info.plist").write_bytes(
                    plistlib.dumps(
                        {
                            "CFBundleVersion": pins["qt"],
                            "CFBundleShortVersionString": pins["sparkle"]["version"],
                        }
                    )
                )
            with patch.object(
                probe, "packaging_module", return_value=Mock()
            ) as package:
                result = probe.inspect_bundle(stage, "0.1.0", "fixture")
                self.assertEqual(result["frameworks"], list(probe.FRAMEWORKS))
                package.return_value.validate_assets.assert_called_with(
                    app / "Contents/Resources/assets"
                )
                for key in (
                    "CFBundleVersion",
                    "CFBundleIdentifier",
                    "SUPublicEDKey",
                    "CFBundleExecutable",
                ):
                    plist.write_bytes(plistlib.dumps({**info, key: "wrong"}))
                    with self.subTest(key=key), self.assertRaises(probe.ProbeError):
                        probe.inspect_bundle(stage, "0.1.0", "fixture")
                plist.write_bytes(plistlib.dumps(info))
                framework = (
                    app / "Contents/Frameworks/QtCore.framework/Resources/Info.plist"
                )
                framework.write_bytes(plistlib.dumps({"CFBundleVersion": "6.11.1"}))
                with self.assertRaises(probe.ProbeError):
                    probe.inspect_bundle(stage, "0.1.0", "fixture")

    def test_signed_verification_pins_certificate_architecture_and_no_host_sdk_links(
        self,
    ):
        probe = self.module()
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            app = root / "stage/Mokaid.app"
            app.mkdir(parents=True)
            (app / "native").write_bytes(next(iter(probe.MACHO_MAGIC)) + b"fixture")
            (app / "data").write_bytes(b"fixture")
            (root / "public-certificate-0").write_bytes(b"PUBLIC-FIXTURE")
            runner = Mock(
                side_effect=lambda *args, **kwargs: (
                    "arm64 x86_64"
                    if args[0] == "lipo"
                    else (
                        "binary:\n\t@rpath/QtCore.framework/QtCore (compatibility version 6.0.0)\n"
                        if args[0] == "otool"
                        else ""
                    )
                )
            )
            cert = Mock()
            cert.fingerprint.return_value = bytes.fromhex(probe.credentials.CERT_SHA256)
            with patch.object(
                probe.x509, "load_der_x509_certificate", return_value=cert
            ):
                probe.verify_signed_bundle(
                    root / "stage", root / "package.dmg", runner, root
                )
                cert.fingerprint.return_value = bytes(32)
                with self.assertRaises(probe.ProbeError):
                    probe.verify_signed_bundle(
                        root / "stage", root / "package.dmg", runner, root
                    )
                cert.fingerprint.return_value = bytes.fromhex(
                    probe.credentials.CERT_SHA256
                )
                for architecture, dependency in (
                    ("x86_64", "@rpath/QtCore"),
                    ("arm64", "/Users/builder/Qt/lib.dylib"),
                ):
                    runner.side_effect = lambda *args, **kwargs: (
                        architecture
                        if args[0] == "lipo"
                        else "binary:\n\t" + dependency if args[0] == "otool" else ""
                    )
                    with self.subTest(architecture=architecture), self.assertRaises(
                        probe.ProbeError
                    ):
                        probe.verify_signed_bundle(
                            root / "stage", root / "package.dmg", runner, root
                        )

    def test_execute_success_and_oversized_output_are_bounded(self):
        probe = self.module()
        process = Mock(pid=999999, returncode=0)
        process.stdout.read = AsyncMock(side_effect=[b"ok", b""])
        process.stderr.read = AsyncMock(side_effect=[b"stderr", b""])
        process.wait = AsyncMock(return_value=0)
        with patch.object(
            probe.asyncio, "create_subprocess_exec", new=AsyncMock(return_value=process)
        ):
            self.assertEqual(
                asyncio.run(probe.execute(["fixture"], {}, 1)), (0, b"ok", b"stderr")
            )
            process.stdout.read = AsyncMock(side_effect=[b"x" * 65536] * 65 + [b""])
            process.stderr.read = AsyncMock(return_value=b"")
            with patch.object(probe.os, "killpg", create=True), patch.object(
                probe.signal, "SIGKILL", 9, create=True
            ), self.assertRaises(probe.ProbeError):
                asyncio.run(probe.execute(["fixture"], {}, 1))

    def test_cli_has_no_publish_or_artifact_output_option(self):
        probe = self.module()
        args = probe.parser().parse_args(
            [
                "sign",
                "--version",
                "0.1.0",
                "--input",
                "unsigned",
                "--manifest-sha256",
                "b" * 64,
            ]
        )
        self.assertFalse(args.execute)
        self.assertFalse(hasattr(args, "output"))
        with patch.dict(os.environ, {}, clear=True), patch.object(
            probe, "read_credentials"
        ) as read, patch.object(
            probe.sys, "argv", ["probe", "metadata", "--version", "0.1.0"]
        ), patch.object(
            probe.sys, "stderr"
        ):
            self.assertEqual(probe.main(), 1)
        read.assert_not_called()

    def test_packager_is_an_isolated_copy_of_reviewed_source(self):
        probe = self.module()
        import release

        first, second = probe.packaging_module(), probe.packaging_module()
        self.assertIsNot(first, second)
        self.assertTrue(callable(first.package_macos))
        first.run = Mock()
        self.assertIsNot(first.run, second.run)
        self.assertIsNot(first.run, release.run)
        with patch.object(
            probe.importlib.util, "spec_from_file_location", return_value=None
        ), self.assertRaises(probe.ProbeError):
            probe.packaging_module()

    def test_cli_metadata_and_preflight_emit_only_public_constructed_facts(self):
        probe = self.module()
        with tempfile.TemporaryDirectory() as folder:
            output, summary = Path(folder) / "output", Path(folder) / "summary"
            env = {
                **self.environment(),
                "GITHUB_OUTPUT": str(output),
                "GITHUB_STEP_SUMMARY": str(summary),
                "MOKAID_UPDATE_PUBLIC_KEY": "public-fixture",
            }
            for command in ("metadata", "verify-stage", "sign"):
                arguments = ["probe", command, "--version", "0.1.0"]
                if command != "metadata":
                    arguments += ["--input", "unsigned", "--manifest-sha256", "b" * 64]
                with self.subTest(command=command), patch.dict(
                    os.environ, env, clear=True
                ), patch.object(probe.sys, "argv", arguments), patch.object(
                    probe, "verify_checkout"
                ), patch.object(
                    probe.stage_archive, "public_key", return_value="public-fixture"
                ), patch.object(
                    probe, "restore_stage"
                ), patch.object(
                    probe, "inspect_bundle", return_value={"qtVersion": "6.11.2"}
                ), patch.object(
                    probe, "read_credentials"
                ) as read, patch(
                    "builtins.print"
                ) as printed:
                    self.assertEqual(probe.main(), 0)
                    value = json.loads(printed.call_args.args[0])
                    self.assertEqual(
                        value["schema"], "com.mokaid.private-signing-probe"
                    )
                    self.assertNotIn("evidenceSignature", value)
                    read.assert_not_called()
            self.assertIn("public_key=public-fixture", output.read_text())
            self.assertIn("not release acceptance", summary.read_text())

    def test_gone_child_process_is_already_reaped_after_timeout(self):
        probe = self.module()
        process = Mock(pid=999999, returncode=None)
        process.stdout.read = AsyncMock(side_effect=asyncio.TimeoutError)
        process.stderr.read = AsyncMock(return_value=b"")
        process.wait = AsyncMock(return_value=-9)
        with patch.object(
            probe.asyncio, "create_subprocess_exec", new=AsyncMock(return_value=process)
        ), patch.object(
            probe.os, "killpg", side_effect=ProcessLookupError, create=True
        ), patch.object(
            probe.signal, "SIGKILL", 9, create=True
        ):
            with self.assertRaises(probe.ProbeError):
                asyncio.run(probe.execute(["fixture"], {}, 1))
        process.wait.assert_awaited_once()

    @unittest.skipUnless(
        os.name == "posix", "Real Mac signing process-group termination requires POSIX"
    )
    def test_real_subprocess_common_output_budget_stops_and_reaps_without_waiting_for_timeout(
        self,
    ):
        probe = self.module()
        real_create = asyncio.create_subprocess_exec
        processes = []

        async def created(*args, **kwargs):
            process = await real_create(*args, **kwargs)
            processes.append(process)
            return process

        # Each stream individually is below 4 MiB, but their sum exceeds it.
        source = "import os,time; os.write(1,b'x'*(3*1024**2)); os.write(2,b'y'*(3*1024**2)); time.sleep(20)"
        started = time.monotonic()
        with patch.object(
            probe.asyncio, "create_subprocess_exec", side_effect=created
        ), self.assertRaises(probe.ProbeError) as failure:
            asyncio.run(
                probe.execute(
                    [sys.executable, "-c", source], {"PATH": "/usr/bin:/bin"}, 10
                )
            )
        self.assertLess(
            time.monotonic() - started,
            5,
            "Output limit must interrupt the writer before its timeout",
        )
        self.assertNotIn("xxx", str(failure.exception))
        self.assertEqual(len(processes), 1)
        self.assertIsNotNone(processes[0].returncode)
        with self.assertRaises(ProcessLookupError):
            os.kill(processes[0].pid, 0)


if __name__ == "__main__":
    unittest.main()
