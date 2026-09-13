from __future__ import annotations
import argparse
import base64
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET
import io
import plistlib

SPEC = importlib.util.spec_from_file_location("mokaid_release", Path(__file__).parents[1] / "release.py")
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class StorageError(Exception):
    def __init__(self, status=404):
        self.response = {"ResponseMetadata": {"HTTPStatusCode": status}}


class FakeStorage:
    exceptions = types.SimpleNamespace(ClientError=StorageError)
    def __init__(self):
        self.items = {}
        self.writes = []
        self.fail_on = None
    def head_object(self, *, Bucket, Key):
        if Key not in self.items:
            raise StorageError()
        entry = self.items[Key]
        return {"ContentLength": len(entry["Body"]), "Metadata": entry.get("Metadata", {})}
    def get_object(self, *, Bucket, Key):
        if Key not in self.items:
            raise StorageError()
        return {"Body": io.BytesIO(self.items[Key]["Body"])}
    def put_object(self, **kwargs):
        key = kwargs["Key"]
        if key == self.fail_on:
            raise StorageError(503)
        if kwargs.get("IfNoneMatch") == "*" and key in self.items:
            raise StorageError(412)
        self.writes.append(key)
        self.items[key] = kwargs


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
        from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat, PrivateFormat, NoEncryption
        self.key = Ed25519PrivateKey.generate()
        self.public = base64.b64encode(self.key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)).decode()
        self.seed = base64.b64encode(self.key.private_bytes(Encoding.Raw, PrivateFormat.Raw, NoEncryption())).decode()
        self.env = patch.dict(os.environ, {"MOKAID_UPDATE_PUBLIC_KEY": self.public, "GITHUB_SHA": "a" * 40}, clear=True)
        self.env.start()
        self.addCleanup(self.env.stop)
        self.temp = tempfile.TemporaryDirectory(prefix="mokaid-release-test-")
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)

    def artifact(self, target="macos-arm64", version="1.2.3", channel="stable"):
        artifact = self.folder / f"Mokaid-{version}-{target}{release.PLATFORMS[target][0]}"
        artifact.write_bytes(b"TEST FIXTURE, not an installable application\x00\x01")
        args = argparse.Namespace(output=self.folder, version=version, channel=channel, platform=target)
        release.write_evidence(args, artifact, {"update_ed25519_seed": self.seed})
        return artifact

    def test_unsigned_release_fails_before_any_package_tool(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(release, "run") as command:
            with self.assertRaisesRegex(ValueError, "MOKAID_UPDATE_PUBLIC_KEY"):
                release.package(argparse.Namespace(version="1.2.3", channel="stable", platform="macos-arm64"))
            command.assert_not_called()

    def test_mac_certificate_fields_are_required(self):
        with self.assertRaisesRegex(ValueError, "developer_id_p12"):
            release.check_secret({"update_ed25519_seed": self.seed}, "macos-arm64")

    def test_wrong_private_key_rejected(self):
        with self.assertRaisesRegex(ValueError, "does not match"):
            release.check_secret({"update_ed25519_seed": base64.b64encode(b"0" * 32).decode()}, "windows-x64")

    def test_valid_update_key_is_accepted(self):
        release.check_secret({"update_ed25519_seed": self.seed}, "windows-x64")

    def test_version_channel_identity_is_strict(self):
        for version, channel in [("1.0.0-beta.1", "stable"), ("1.0.0", "beta"), ("1.0.0;echo hi", "stable"), ("../1.0.0", "stable"), ("01.0.0", "stable")]:
            with self.subTest(version=version), self.assertRaises(ValueError):
                release.check_version(version, channel)
        release.check_version("1.0.0", "stable")
        release.check_version("1.0.0-beta.1", "beta")

    def test_valid_signed_payload_verifies(self):
        self.artifact()
        evidence = release.verify_evidence(self.folder, "macos-arm64", "1.2.3", "stable")
        self.assertTrue(evidence["notarized"])

    def test_archive_tampering_is_rejected(self):
        artifact = self.artifact()
        artifact.write_bytes(b"tampered")
        with self.assertRaisesRegex(ValueError, "checksum/size"):
            release.verify_evidence(self.folder, "macos-arm64", "1.2.3", "stable")

    def test_rehashed_tampering_still_fails_signature(self):
        from cryptography.exceptions import InvalidSignature
        artifact = self.artifact()
        artifact.write_bytes(b"tampered")
        evidence = json.loads((self.folder / "macos-arm64.json").read_text())
        evidence.update(sha256=release.sha256(artifact), size=artifact.stat().st_size)
        (self.folder / "macos-arm64.json").write_text(json.dumps(evidence))
        with self.assertRaises(InvalidSignature):
            release.verify_evidence(self.folder, "macos-arm64", "1.2.3", "stable")

    def test_evidence_cannot_traverse_artifact_directory(self):
        self.artifact()
        evidence = json.loads((self.folder / "macos-arm64.json").read_text())
        evidence["file"] = "../../private.key"
        (self.folder / "macos-arm64.json").write_text(json.dumps(evidence))
        with self.assertRaisesRegex(ValueError, "file name"):
            release.verify_evidence(self.folder, "macos-arm64", "1.2.3", "stable")

    def test_notarization_is_required_for_mac(self):
        self.artifact()
        path = self.folder / "macos-arm64.json"
        evidence = json.loads(path.read_text())
        evidence["notarized"] = False
        path.write_text(json.dumps(evidence))
        with self.assertRaisesRegex(ValueError, "Notarization"):
            release.verify_evidence(self.folder, "macos-arm64", "1.2.3", "stable")

    def test_appcast_carries_exact_signed_payload_and_compatibility(self):
        self.artifact("windows-x64")
        evidence = release.verify_evidence(self.folder, "windows-x64", "1.2.3", "stable")
        xml = ET.fromstring(release.make_feed(evidence, "Sun, 13 Sep 2026 11:00:00 +0000"))
        enclosure = xml.find("channel/item/enclosure")
        self.assertEqual(enclosure.attrib[f"{{{release.SPARKLE}}}edSignature"], evidence["edSignature"])
        self.assertEqual(enclosure.attrib["url"], "https://downloads.mokaid.com/releases/1.2.3/Mokaid-1.2.3-windows-x64.exe")
        self.assertEqual(xml.find(f"channel/item/{{{release.SPARKLE}}}minimumSystemVersion").text, "10.0.22000")

    def test_website_manifest_is_not_published_if_a_platform_is_missing(self):
        self.artifact()
        fake_boto = types.SimpleNamespace(client=unittest.mock.Mock())
        args = argparse.Namespace(artifacts=self.folder, version="1.2.3", channel="stable")
        with patch.dict(sys.modules, {"boto3": fake_boto}), self.assertRaises(FileNotFoundError):
            release.promote(args)
        fake_boto.client.assert_not_called()

    def test_icons_preserve_brand_source_and_native_formats(self):
        from PIL import Image
        release.icons(self.folder)
        with Image.open(self.folder / "Mokaid.ico") as icon:
            self.assertTrue({(16, 16), (32, 32), (256, 256)}.issubset(icon.ico.sizes()))
        with Image.open(self.folder / "Mokaid.icns") as icon:
            self.assertEqual(icon.format, "ICNS")
            self.assertEqual(icon.size, (1024, 1024))

    def test_cli_missing_signing_configuration_exits_without_output_artifact(self):
        environment = dict(os.environ)
        environment.pop("MOKAID_UPDATE_PUBLIC_KEY", None)
        outcome = subprocess.run([sys.executable, str(Path(__file__).parents[1] / "release.py"), "package",
            "--version", "1.2.3", "--platform", "macos-arm64", "--stage", str(self.folder / "stage"),
            "--output", str(self.folder / "output")], env=environment, capture_output=True, text=True)
        self.assertEqual(outcome.returncode, 1)
        self.assertIn("MOKAID_UPDATE_PUBLIC_KEY", outcome.stderr)
        self.assertFalse((self.folder / "output").exists())

    def promote(self, storage, version="1.2.3"):
        fake_boto = types.SimpleNamespace(client=lambda service: storage)
        args = argparse.Namespace(artifacts=self.folder, version=version, channel="stable", readiness=self.acceptance(version))
        with patch.dict(sys.modules, {"boto3": fake_boto}), patch.dict(os.environ, {"MOKAID_DOWNLOADS_BUCKET": "test-only"}):
            release.promote(args)

    def acceptance(self, version="1.2.3"):
        record = self.folder / "approval" / f"{version}.json"
        record.parent.mkdir(exist_ok=True)
        record.write_text(json.dumps({"schemaVersion": 1, "version": version, "channel": "stable",
            "sourceCommit": "a" * 40, "approvedBy": "Unit-test fixture only", "approvedAt": "2025-01-01T00:00:00Z",
            "artifacts": {target: json.loads((self.folder / f"{target}.json").read_text())["sha256"] for target in release.PLATFORMS},
            "checks": [{"id": check, "status": "passed", "evidence": f"https://example.invalid/fixture/{check}"}
                       for check in sorted(release.READINESS_CHECKS)]}))
        return record

    def test_missing_acceptance_blocks_before_any_cloud_access(self):
        self.artifact()
        self.artifact("windows-x64")
        fake_boto = types.SimpleNamespace(client=unittest.mock.Mock())
        args = argparse.Namespace(artifacts=self.folder, version="1.2.3", channel="stable", readiness=self.folder / "missing.json")
        with patch.dict(sys.modules, {"boto3": fake_boto}), self.assertRaisesRegex(ValueError, "acceptance record"):
            release.promote(args)
        fake_boto.client.assert_not_called()

    def test_acceptance_requires_every_real_check_to_pass(self):
        self.artifact()
        self.artifact("windows-x64")
        for mutation in ("not_run", "missing", "duplicate", "no_evidence", "credentials"):
            with self.subTest(mutation=mutation):
                path = self.acceptance()
                accepted = json.loads(path.read_text())
                if mutation == "missing": accepted["checks"].pop()
                elif mutation == "duplicate": accepted["checks"][-1] = accepted["checks"][0]
                elif mutation == "no_evidence": accepted["checks"][0]["evidence"] = ""
                elif mutation == "credentials": accepted["checks"][0]["evidence"] = "https://token:secret@example.invalid/test"
                else: accepted["checks"][0]["status"] = "not_run"
                path.write_text(json.dumps(accepted))
                with self.assertRaises(ValueError):
                    release.validate_readiness(self.folder, "1.2.3", "stable", path)

    def test_acceptance_is_bound_to_exact_candidate_bytes_and_commit(self):
        self.artifact()
        self.artifact("windows-x64")
        for mutation in ("sourceCommit", "artifacts", "approvedAt", "approvedBy"):
            with self.subTest(mutation=mutation):
                path = self.acceptance()
                accepted = json.loads(path.read_text())
                accepted[mutation] = {"sourceCommit": "b" * 40, "artifacts": {}, "approvedAt": "2999-01-01T00:00:00Z", "approvedBy": ""}[mutation]
                path.write_text(json.dumps(accepted))
                with self.assertRaises(ValueError):
                    release.validate_readiness(self.folder, "1.2.3", "stable", path)

    def test_committed_acceptance_template_cannot_approve_a_release(self):
        self.artifact()
        self.artifact("windows-x64")
        with self.assertRaises(ValueError):
            release.validate_readiness(self.folder, "1.2.3", "stable", release.HERE / "acceptance/template.json")

    def test_complete_artifacts_are_published_before_feeds_and_manifest_last(self):
        self.artifact()
        self.artifact("windows-x64")
        storage = FakeStorage()
        self.promote(storage)
        self.assertEqual(storage.writes[-3:], ["stable/macos-arm64.xml", "stable/windows-x64.xml", "stable/release.json"])
        self.assertTrue(all(key.startswith("releases/1.2.3/") for key in storage.writes[:-3]))
        for key in storage.writes[:-3]:
            self.assertEqual(storage.items[key]["IfNoneMatch"], "*")

    def test_failed_artifact_upload_does_not_advance_any_feed(self):
        self.artifact()
        self.artifact("windows-x64")
        storage = FakeStorage()
        storage.fail_on = "releases/1.2.3/Mokaid-1.2.3-windows-x64.exe"
        with self.assertRaises(StorageError):
            self.promote(storage)
        self.assertFalse(any(key.startswith("stable/") for key in storage.writes))

    def test_existing_immutable_artifact_cannot_be_overwritten(self):
        artifact = self.artifact()
        self.artifact("windows-x64")
        storage = FakeStorage()
        storage.items[f"releases/1.2.3/{artifact.name}"] = {"Body": b"old", "Metadata": {"sha256": "0" * 64}}
        with self.assertRaisesRegex(ValueError, "different bytes"):
            self.promote(storage)
        self.assertEqual(storage.writes, [])

    def test_accidental_feed_downgrade_is_rejected(self):
        self.artifact()
        self.artifact("windows-x64")
        storage = FakeStorage()
        storage.items["stable/release.json"] = {"Body": json.dumps({"version": "1.2.4"}).encode()}
        with self.assertRaisesRegex(ValueError, "backwards"):
            self.promote(storage)
        self.assertEqual(storage.writes, [])

    def test_signing_evidence_cannot_be_forged_for_a_different_source_commit(self):
        from cryptography.exceptions import InvalidSignature
        self.artifact()
        path = self.folder / "macos-arm64.json"
        metadata = json.loads(path.read_text())
        metadata["sourceCommit"] = "b" * 40
        path.write_text(json.dumps(metadata))
        with self.assertRaises(InvalidSignature):
            release.verify_evidence(self.folder, "macos-arm64", "1.2.3", "stable")

    def test_windows_crt_is_app_local_for_main_and_webengine_processes(self):
        stage = self.folder / "stage"
        helper = stage / "helpers"
        helper.mkdir(parents=True)
        (stage / "Mokaid.exe").write_bytes(b"test executable")
        (helper / "QtWebEngineProcess.exe").write_bytes(b"test helper")
        redist = self.folder / "redist"
        crt = redist / "x64/Microsoft.VC143.CRT"
        crt.mkdir(parents=True)
        for name in ("msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll", "msvcp140_2.dll"):
            (crt / name).write_bytes(name.encode())
        release.copy_windows_crt(stage, redist)
        for destination in (stage, helper):
            for original in crt.iterdir():
                self.assertEqual((destination / original.name).read_bytes(), original.read_bytes())
        self.assertEqual(list(stage.rglob("vc_redist*.exe")), [])

    def test_windows_crt_missing_x64_release_libraries_fails(self):
        with self.assertRaisesRegex(ValueError, "VC143.CRT"):
            release.copy_windows_crt(self.folder, self.folder / "missing")

    def test_valid_third_party_signatures_are_preserved_byte_for_byte(self):
        stage = self.folder / "stage"
        stage.mkdir()
        dll = stage / "vcruntime140.dll"
        dll.write_bytes(b"vendor signed bytes")
        with patch.object(release, "run", return_value="Valid\n") as command:
            release.sign_windows_runtime(stage)
        self.assertEqual(command.call_count, 1)
        self.assertIn(release.HERE / "windows/signature-status.ps1", command.call_args.args)
        self.assertEqual(dll.read_bytes(), b"vendor signed bytes")

    def test_own_and_unsigned_runtime_binaries_are_signed(self):
        stage = self.folder / "stage"
        stage.mkdir()
        (stage / "Mokaid.exe").write_bytes(b"own")
        (stage / "Qt6Core.dll").write_bytes(b"unsigned vendor")
        with patch.object(release, "run", side_effect=["Valid", "", "NotSigned", ""]) as command:
            release.sign_windows_runtime(stage)
        signing = [call for call in command.call_args_list if release.HERE / "windows/sign.ps1" in call.args]
        self.assertEqual([call.args[-1].name for call in signing], ["Mokaid.exe", "Qt6Core.dll"])

    def test_invalid_signatures_are_not_laundered_by_resigning(self):
        for status in ("HashMismatch", "NotTrusted", "UnknownError", "NotSupportedFileFormat", ""):
            for owned in (True, False):
                with self.subTest(status=status, owned=owned), self.assertRaisesRegex(ValueError, "invalid Authenticode"):
                    release.windows_signing_action(status, owned=owned)

    def test_public_packaging_rejects_a_development_stage(self):
        (self.folder / "distribution-stage.json").write_text(json.dumps({
            "schemaVersion": 1, "platform": "macos-arm64", "updatesEnabled": False}))
        with self.assertRaisesRegex(ValueError, "Development previews"):
            release.require_release_stage(self.folder, "macos-arm64")
        (self.folder / "distribution-stage.json").write_text(json.dumps({
            "schemaVersion": 1, "platform": "macos-arm64", "updatesEnabled": True, "developmentBuild": True}))
        with self.assertRaisesRegex(ValueError, "non-development"):
            release.require_release_stage(self.folder, "macos-arm64")

    def test_local_preview_never_requests_a_signing_secret_or_creates_evidence(self):
        stage = self.folder / "stage"
        app = stage / "Mokaid.app"
        (app / "Contents").mkdir(parents=True)
        (stage / "distribution-stage.json").write_text(json.dumps({
            "schemaVersion": 1, "platform": "macos-arm64", "updatesEnabled": False, "developmentBuild": True}))
        with (app / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleShortVersionString": "1.2.3", "SUEnableAutomaticChecks": False,
                          "CFBundleIdentifier": "com.mokaid.desktop.development", "CFBundleName": "Mokaid Development"}, stream)
        args = argparse.Namespace(stage=stage, output=self.folder / "preview")
        with patch.object(release.platform, "system", return_value="Darwin"), patch.object(release, "run") as command, \
             patch.object(release, "signing_secret") as secret, patch.object(release, "write_evidence") as evidence:
            artifact = release.preview_macos(args)
        secret.assert_not_called()
        evidence.assert_not_called()
        self.assertEqual(artifact.name, "Mokaid-1.2.3-development-macos-arm64.dmg")
        self.assertFalse(any("notarytool" in call.args or "security" in call.args for call in command.call_args_list))
        self.assertEqual(command.call_args.args[0], "hdiutil")
        self.assertEqual(list(args.output.glob("*.json")), [])

    def test_preview_rejects_stable_and_beta_namespaces_even_when_updates_are_disabled(self):
        stage = self.folder / "stage"
        app = stage / "Mokaid.app"
        (app / "Contents").mkdir(parents=True)
        args = argparse.Namespace(stage=stage, output=self.folder / "preview")
        with patch.object(release.platform, "system", return_value="Darwin"), patch.object(release, "run") as command:
            for namespace in ("com.mokaid.desktop", "com.mokaid.desktop.beta"):
                for declared in (False, True):
                    with self.subTest(namespace=namespace, declared=declared):
                        (stage / "distribution-stage.json").write_text(json.dumps({
                            "schemaVersion": 1, "platform": "macos-arm64", "updatesEnabled": False, "developmentBuild": declared}))
                        with (app / "Contents/Info.plist").open("wb") as stream:
                            plistlib.dump({"CFBundleShortVersionString": "1.2.3", "SUEnableAutomaticChecks": False,
                                          "CFBundleIdentifier": namespace, "CFBundleName": "Mokaid"}, stream)
                        with self.assertRaisesRegex(ValueError, "identity"):
                            release.preview_macos(args)
            command.assert_not_called()

    def test_development_identity_must_be_explicit_in_the_cmake_cache(self):
        (self.folder / "CMakeCache.txt").write_text("MOKAID_DEVELOPMENT:BOOL=ON\n")
        self.assertTrue(release.cmake_boolean(self.folder, "MOKAID_DEVELOPMENT"))
        (self.folder / "CMakeCache.txt").write_text("MOKAID_DEVELOPMENT:BOOL=OFF\n")
        self.assertFalse(release.cmake_boolean(self.folder, "MOKAID_DEVELOPMENT"))
        (self.folder / "CMakeCache.txt").write_text("MOKAID_ENABLE_UPDATES:BOOL=OFF\n")
        with self.assertRaisesRegex(ValueError, "MOKAID_DEVELOPMENT"):
            release.cmake_boolean(self.folder, "MOKAID_DEVELOPMENT")

    def test_macos_deploys_only_required_native_plugins_and_still_scans_qml(self):
        with patch.object(Path, "is_file", return_value=True), patch.object(release.shutil, "copy2"), \
             patch.object(release, "run", return_value="") as command:
            release.deploy_macos_runtime(self.folder / "Mokaid.app", self.folder / "sdk/bin", self.folder / "qml")
        arguments = command.call_args.args
        self.assertIn("-no-plugins", arguments)
        self.assertIn(f"-qmldir={(self.folder / 'qml').resolve()}", arguments)
        selected = [str(value) for value in arguments if str(value).startswith("-executable=")]
        self.assertEqual(len(selected), 9)
        self.assertTrue(any("libqsqlite.dylib" in value for value in selected))
        self.assertFalse(any("sqlpsql" in value or "sqlodbc" in value or "nmea" in value for value in selected))

    def test_macos_deployment_error_text_fails_even_when_qt_exits_zero(self):
        with patch.object(Path, "is_file", return_value=True), patch.object(release.shutil, "copy2"), \
             patch.object(release, "run", return_value="ERROR: Cannot resolve rpath\n"):
            with self.assertRaisesRegex(ValueError, "despite its exit status"):
                release.deploy_macos_runtime(self.folder / "Mokaid.app", self.folder / "sdk/bin", self.folder / "qml")

    def test_cmake_stage_reads_real_updater_configuration(self):
        (self.folder / "CMakeCache.txt").write_text("MOKAID_ENABLE_UPDATES:BOOL=OFF\n")
        self.assertFalse(release.cmake_updates_enabled(self.folder))
        (self.folder / "CMakeCache.txt").write_text("MOKAID_ENABLE_UPDATES:BOOL=ON\n")
        self.assertTrue(release.cmake_updates_enabled(self.folder))
        (self.folder / "CMakeCache.txt").write_text("UNRELATED:BOOL=ON\n")
        with self.assertRaisesRegex(ValueError, "must declare"):
            release.cmake_updates_enabled(self.folder)

    def test_cooked_asset_validation_requires_all_avatars_and_navigation(self):
        keys = ["office", "avatar_male", "avatar_female", "avatar_corporate", "avatar_developer",
                "avatar_design", "avatar_finance", "avatar_research", "avatar_legal"]
        manifest = {"format": 3, "assets": [], "navigation": {"file": "office.mokaidnav"}}
        for name in keys:
            path = self.folder / f"{name}.mokaidasset"
            path.write_bytes(b"fixture")
            manifest["assets"].append({"id": name, "file": path.name, "sha256": release.sha256(path)})
        navigation = self.folder / "office.mokaidnav"
        navigation.write_bytes(b"navigation fixture")
        manifest["navigation"]["sha256"] = release.sha256(navigation)
        (self.folder / "manifest.json").write_text(json.dumps(manifest))
        release.validate_assets(self.folder)
        navigation.write_bytes(b"tampered navigation")
        with self.assertRaisesRegex(ValueError, "navigation checksum"):
            release.validate_assets(self.folder)


if __name__ == "__main__":
    unittest.main()
