"""Offline tests of the real signing probe; production keys are never read."""

from __future__ import annotations

import asyncio
from datetime import datetime, timedelta, timezone
import importlib
import io
import json
from pathlib import Path
import subprocess
import sys
from typing import Any
import unittest
from unittest.mock import AsyncMock, Mock, patch

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

sys.path.insert(0, str(Path(__file__).parents[1]))
probe = importlib.import_module("probe_test")


class ProbeTests(unittest.TestCase):
    """Verify successful and interrupted cleanup with injected command boundaries."""

    @classmethod
    def setUpClass(cls) -> None:
        key = ec.generate_private_key(ec.SECP256R1())
        subject = x509.Name(
            [
                x509.NameAttribute(
                    NameOID.COMMON_NAME, "SYNTHETIC PUBLIC CERTIFICATE ONLY"
                ),
                x509.NameAttribute(NameOID.ORGANIZATIONAL_UNIT_NAME, probe.TEAM),
            ]
        )
        now = datetime.now(timezone.utc)
        cert = (
            x509.CertificateBuilder()
            .subject_name(subject)
            .issuer_name(subject)
            .public_key(key.public_key())
            .serial_number(1)
            .not_valid_before(now - timedelta(hours=1))
            .not_valid_after(now + timedelta(hours=1))
            .sign(key, hashes.SHA256())
        )
        cls.der = cert.public_bytes(serialization.Encoding.DER)
        cls.sha256 = cert.fingerprint(hashes.SHA256()).hex()

    def setUp(self) -> None:
        self.secret = {
            "developer_id_p12": "SYNTHETIC SECRET P12",
            "p12_password": "SYNTHETIC SECRET PASSWORD",
            "developer_id_identity": probe.credentials.IDENTITY,
            "developer_id_certificate_sha256": self.sha256,
            "notary_key_p8": "DO NOT PASS TO IMPORTER",
            "update_ed25519_seed": "DO NOT PASS TO IMPORTER",
        }
        self.calls: list[tuple[list[str], dict[str, Any]]] = []
        self.paths: list[Path] = []
        self.fail_phase = ""
        self.wrong_metadata = False
        self.bad_certificate = False
        self.searches = 0
        self.changed_search_at = 0
        self.importer = Mock()
        self.importer.create_signing_keychain.side_effect = self.import_keychain
        for target, name, value in (
            (probe.platform, "system", "Darwin"),
            (probe.credentials, "CERT_SHA256", self.sha256),
        ):
            adjustment = (
                patch.object(target, name, return_value=value)
                if name == "system"
                else patch.object(target, name, value)
            )
            adjustment.start()
            self.addCleanup(adjustment.stop)
        certificate = patch.object(probe.credentials, "validate_certificate")
        certificate.start()
        self.addCleanup(certificate.stop)

    def import_keychain(
        self, directory: Path, fields: dict[str, str]
    ) -> tuple[Path, str]:
        self.assertEqual(
            set(fields),
            {
                "developer_id_p12",
                "p12_password",
                "developer_id_identity",
                "developer_id_certificate_sha256",
            },
        )
        self.assertEqual(directory.stat().st_mode & 0o777, 0o700)
        self.paths.append(directory)
        keychain = directory / "signing.keychain-db"
        keychain.touch(mode=0o600)
        return keychain, probe.SHA1

    def run_command(
        self, args: list[str], **kwargs: Any
    ) -> subprocess.CompletedProcess[bytes]:
        self.calls.append((args, kwargs))
        phase = kwargs["phase"]
        if phase == self.fail_phase:
            raise probe.credentials.CredentialError("Fixed simulated step failure.")
        stdout, stderr = b"", b""
        if args[0] == "/usr/bin/security" and args[1] == "list-keychains":
            self.searches += 1
            stdout = (
                b"changed-list"
                if self.searches == self.changed_search_at
                else b"original-list"
            )
        if phase == "compile harmless fixture":
            self.assertEqual(kwargs["payload"], probe.SOURCE)
            Path(args[args.index("-o") + 1]).touch()
        if phase == "inspect public signing metadata":
            stderr = (
                f"Identifier={probe.IDENTIFIER}\nTeamIdentifier={probe.TEAM}\n"
                if not self.wrong_metadata
                else "wrong"
            ).encode()
        if phase == "extract public signing certificate":
            path = args[2].split("=", 1)[1] + "0"
            Path(path).write_bytes(
                b"invalid certificate" if self.bad_certificate else self.der
            )
        if phase == "run harmless signed fixture":
            stdout = b"Mokaid signing probe\n"
        if phase == "delete temporary keychain":
            Path(args[2]).unlink()
        return subprocess.CompletedProcess(args, 0, stdout, stderr)

    def test_success_pins_keychain_identity_team_and_public_certificate(self) -> None:
        result = probe.run_probe(self.secret, self.importer, self.run_command)
        self.assertEqual(result["status"], "verified")
        self.assertEqual(result["certificateSha256"], self.sha256)
        self.assertFalse(result["timestamped"])
        self.assertFalse(result["notarized"])
        self.assertFalse(result["releasePublished"])
        self.assertTrue(result["temporaryKeychainRemoved"])
        self.assertFalse(self.paths[0].exists())
        sign = next(
            args
            for args, kwargs in self.calls
            if kwargs["phase"] == "sign with imported Developer ID"
        )
        self.assertIn("--timestamp=none", sign)
        self.assertEqual(sign[sign.index("--sign") + 1], probe.SHA1)
        self.assertEqual(
            Path(sign[sign.index("--keychain") + 1]),
            self.paths[0] / "signing.keychain-db",
        )
        verify = next(
            args
            for args, kwargs in self.calls
            if kwargs["phase"] == "verify strict Apple Developer ID requirement"
        )
        self.assertIn("--strict", verify)
        self.assertIn("-R=" + probe.REQUIREMENT, verify)
        self.assertNotIn("notarytool", repr(self.calls))
        self.assertNotIn("SYNTHETIC SECRET", repr(self.calls))
        self.assertNotIn("SYNTHETIC SECRET", json.dumps(result))

    def test_failure_at_every_native_step_still_cleans_keychain_and_directory(
        self,
    ) -> None:
        for phase in (
            "compile harmless fixture",
            "sign with imported Developer ID",
            "verify strict Apple Developer ID requirement",
            "inspect public signing metadata",
            "extract public signing certificate",
            "run harmless signed fixture",
        ):
            self.fail_phase = phase
            with self.subTest(phase=phase), self.assertRaises(
                probe.credentials.CredentialError
            ):
                probe.run_probe(self.secret, self.importer, self.run_command)
            self.assertTrue(all(not path.exists() for path in self.paths))

    def test_wrong_metadata_certificate_or_imported_identity_fails_closed(self) -> None:
        self.wrong_metadata = True
        with self.assertRaises(probe.credentials.CredentialError):
            probe.run_probe(self.secret, self.importer, self.run_command)
        self.wrong_metadata, self.bad_certificate = False, True
        with self.assertRaises(ValueError):
            probe.run_probe(self.secret, self.importer, self.run_command)
        self.bad_certificate = False
        with patch.object(probe.credentials, "CERT_SHA256", "0" * 64):
            with self.assertRaises(probe.credentials.CredentialError):
                probe.run_probe(self.secret, self.importer, self.run_command)
        self.importer.create_signing_keychain.side_effect = lambda directory, fields: (
            directory / "different",
            "wrong",
        )
        with self.assertRaises(probe.credentials.CredentialError):
            probe.run_probe(self.secret, self.importer, self.run_command)
        self.assertTrue(all(not path.exists() for path in self.paths))

    def test_changed_search_list_fails_instead_of_claiming_cleanup(self) -> None:
        for at in (2, 3):
            self.searches, self.changed_search_at = 0, at
            with self.assertRaises(probe.credentials.CredentialError):
                probe.run_probe(self.secret, self.importer, self.run_command)

    def test_failed_delete_cannot_claim_success(self) -> None:
        self.fail_phase = "delete temporary keychain"
        with self.assertRaises(probe.credentials.CredentialError):
            probe.run_probe(self.secret, self.importer, self.run_command)

    def test_child_environment_and_error_output_are_sanitized(self) -> None:
        with patch.object(
            probe.subprocess,
            "run",
            return_value=subprocess.CompletedProcess([], 0, b"public", b""),
        ) as run:
            probe.command(["/usr/bin/true"], phase="test")
        self.assertTrue(run.call_args.kwargs["capture_output"])
        self.assertNotIn("AWS_SECRET_ACCESS_KEY", run.call_args.kwargs["env"])
        self.assertNotIn("DYLD_INSERT_LIBRARIES", run.call_args.kwargs["env"])
        for result in (
            subprocess.CompletedProcess([], 1, b"PRIVATE", b"PRIVATE"),
            OSError("PRIVATE"),
        ):
            with patch.object(
                probe.subprocess,
                "run",
                side_effect=result if isinstance(result, Exception) else None,
                return_value=result,
            ), self.assertRaises(probe.credentials.CredentialError) as error:
                probe.command(["/usr/bin/true"], phase="fixed test label")
            self.assertNotIn("PRIVATE", str(error.exception))

    def test_default_plan_never_contacts_aws_or_imports_identity(self) -> None:
        with patch.object(probe.credentials, "aws_client") as aws, patch.object(
            probe, "run_probe"
        ) as run:
            outcome = asyncio.run(probe.execute("mokaid", run=False))
        self.assertFalse(outcome["networkContacted"])
        aws.assert_not_called()
        run.assert_not_called()

    def test_explicit_run_reuses_only_reviewed_importer_and_pinned_secret_reader(
        self,
    ) -> None:
        module = Mock(__file__=str(Path(probe.__file__).with_name("release.py")))
        snapshot = Mock(document=self.secret)
        with patch.object(
            probe.credentials,
            "aws_client",
            return_value="fake",
        ) as aws, patch.object(
            probe.credentials, "read_current", return_value=snapshot
        ) as read, patch.object(
            probe.importlib, "import_module", return_value=module
        ), patch.object(
            probe, "run_probe", return_value={"status": "fake"}
        ) as run:
            self.assertEqual(
                asyncio.run(probe.execute("mokaid", run=True)), {"status": "fake"}
            )
            aws.assert_called_once_with("mokaid")
            read.assert_called_once_with("fake")
            run.assert_called_once_with(self.secret, module)
            module.__file__ = "/untrusted/release.py"
            with self.assertRaises(probe.credentials.CredentialError):
                asyncio.run(probe.execute("mokaid", run=True))
        with patch.object(probe.platform, "system", return_value="Linux"):
            with self.assertRaises(probe.credentials.CredentialError):
                asyncio.run(probe.execute("mokaid", run=True))

    def test_cli_prints_public_plan_and_fixed_errors_only(self) -> None:
        with patch("sys.stdout", new_callable=io.StringIO) as output:
            self.assertEqual(probe.main([]), 0)
        self.assertEqual(json.loads(output.getvalue())["status"], "planned")
        for error in (
            RuntimeError("PRIVATE"),
            probe.credentials.CredentialError("Fixed safe error"),
        ):
            with patch.object(
                probe, "execute", new_callable=AsyncMock, side_effect=error
            ), patch("sys.stderr", new_callable=io.StringIO) as output:
                self.assertEqual(probe.main(["--run"]), 2)
            self.assertNotIn("PRIVATE", output.getvalue())


if __name__ == "__main__":
    unittest.main()
