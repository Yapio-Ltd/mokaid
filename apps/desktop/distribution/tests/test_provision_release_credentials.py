"""Synthetic credentials and fake Apple/AWS only; never read operator keys."""

from __future__ import annotations

import argparse
import asyncio
import base64
import copy
from datetime import datetime, timedelta, timezone
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
from typing import Any
import unittest
from unittest.mock import AsyncMock, Mock, patch

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, ed25519
from cryptography.hazmat.primitives.serialization import pkcs12
from cryptography.x509.oid import NameOID

SPEC = importlib.util.spec_from_file_location(
    "provision_release_credentials",
    Path(__file__).parents[1] / "provision_release_credentials.py",
)
assert SPEC and SPEC.loader
credentials = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = credentials
SPEC.loader.exec_module(credentials)
TEST_KEY_ID = "TESTKEY1234"


class FakeSecrets:
    """Model conditional AWS staging, including three distinct writer races."""

    def __init__(self, document: dict[str, Any]) -> None:
        self.document = copy.deepcopy(document)
        self.arn = credentials.SECRET_ARN
        self.version = "original-version"
        self.reads = 0
        self.writes: list[dict[str, Any]] = []
        self.pending: dict[str, dict[str, Any]] = {}
        self.race = ""
        self.deleted = False
        self.bad_put = False
        self.raw_json: str | None = None

    def describe_secret(self, **kwargs: object) -> dict[str, Any]:
        assert kwargs == {"SecretId": credentials.SECRET_ARN}
        return {"ARN": self.arn, "DeletedDate": self.deleted}

    def get_secret_value(self, **kwargs: object) -> dict[str, Any]:
        assert kwargs == {
            "SecretId": credentials.SECRET_ARN,
            "VersionStage": "AWSCURRENT",
        }
        self.reads += 1
        if self.race == "before" and self.reads > 1:
            self.version = "concurrent-before"
        if self.race == "after" and self.writes:
            self.version = "concurrent-after"
        return {
            "ARN": self.arn,
            "VersionId": self.version,
            "SecretString": (
                self.raw_json
                if self.raw_json is not None
                else json.dumps(self.document)
            ),
        }

    def put_secret_value(self, **kwargs: Any) -> dict[str, Any]:
        assert "AWSCURRENT" not in kwargs["VersionStages"]
        self.writes.append(kwargs)
        self.pending[kwargs["ClientRequestToken"]] = json.loads(kwargs["SecretString"])
        return {
            "ARN": self.arn,
            "VersionId": "wrong" if self.bad_put else kwargs["ClientRequestToken"],
        }

    def update_secret_version_stage(self, **kwargs: Any) -> dict[str, Any]:
        self.writes.append(kwargs)
        if kwargs["VersionStage"] == "AWSCURRENT":
            if self.race == "during":
                self.version = "concurrent-during"
            if kwargs["RemoveFromVersionId"] != self.version:
                raise RuntimeError(
                    "SIMULATED AWS CONFLICT WITH SENSITIVE ERROR CONTENT"
                )
            self.version = kwargs["MoveToVersionId"]
            self.document = self.pending[self.version]
        return {}


class CredentialTests(unittest.TestCase):
    """Exercise the operator boundary without cloud/Keychain access."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.key = ec.generate_private_key(ec.SECP256R1())
        subject = x509.Name(
            [x509.NameAttribute(NameOID.COMMON_NAME, credentials.IDENTITY)]
        )
        now = datetime.now(timezone.utc)
        cert = (
            x509.CertificateBuilder()
            .subject_name(subject)
            .issuer_name(subject)
            .public_key(cls.key.public_key())
            .serial_number(11)
            .not_valid_before(now - timedelta(days=1))
            .not_valid_after(now + timedelta(days=1))
            .sign(cls.key, hashes.SHA256())
        )
        cls.fingerprint = cert.fingerprint(hashes.SHA256()).hex()
        password = "SYNTHETIC FIXTURE NOT AN OPERATOR PASSWORD" * 2
        encrypted = pkcs12.serialize_key_and_certificates(
            b"SYNTHETIC TEST ONLY",
            cls.key,
            cert,
            None,
            serialization.BestAvailableEncryption(password.encode()),
        )
        cls.certificate_document = {
            "developer_id_identity": credentials.IDENTITY,
            "developer_id_certificate_sha256": cls.fingerprint,
            "developer_id_p12": base64.b64encode(encrypted).decode(),
            "p12_password": password,
            "custom": {"must": ["survive", 1, None]},
        }
        cls.pem = cls.key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        )

    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory(prefix="mokaid-credential-unit-")
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / f"AuthKey_{TEST_KEY_ID}.p8"
        self.path.touch(mode=0o600)
        self.path.write_bytes(self.pem)
        pin = patch.object(credentials, "CERT_SHA256", self.fingerprint)
        pin.start()
        self.addCleanup(pin.stop)
        self.client = FakeSecrets(self.certificate_document)

    def arguments(self, **changes: Any) -> argparse.Namespace:
        values = {
            "action": "notary",
            "key_path": self.path,
            "key_id": TEST_KEY_ID,
            "issuer": credentials.ISSUER,
            "apply": False,
            "verify_notary": False,
            "profile": "mokaid",
        }
        return argparse.Namespace(**(values | changes))

    def notary_values(self) -> dict[str, str]:
        return {
            "notary_key_p8": self.pem.decode(),
            "notary_key_id": TEST_KEY_ID,
            "notary_issuer": credentials.ISSUER,
        }

    def test_default_metadata_plan_neither_reads_key_nor_contacts_network(self) -> None:
        with patch.object(credentials, "read_key") as read, patch.object(
            credentials, "aws_client"
        ) as aws, patch.object(credentials, "validate_notary") as apple:
            outcome = asyncio.run(credentials.execute(self.arguments()))
        self.assertEqual(outcome["status"], "metadata-validated")
        read.assert_not_called()
        aws.assert_not_called()
        apple.assert_not_called()

    def test_default_seed_plan_does_not_generate_read_or_contact_aws(self) -> None:
        with patch.object(credentials, "aws_client") as aws, patch.object(
            credentials.ed25519.Ed25519PrivateKey, "generate"
        ) as generate:
            outcome = asyncio.run(
                credentials.execute(self.arguments(action="generate-update-key"))
            )
        self.assertFalse(outcome["credentialsGenerated"])
        aws.assert_not_called()
        generate.assert_not_called()

    def test_verify_notary_mode_contacts_only_apple_and_returns_public_metadata(
        self,
    ) -> None:
        with patch.object(credentials, "aws_client") as aws, patch.object(
            credentials, "validate_notary", new_callable=AsyncMock
        ) as apple:
            outcome = asyncio.run(
                credentials.execute(self.arguments(verify_notary=True))
            )
        apple.assert_awaited_once_with(self.pem, TEST_KEY_ID)
        aws.assert_not_called()
        self.assertFalse(outcome["awsContacted"])
        self.assertFalse(outcome["releaseUploaded"])
        self.assertNotIn(self.pem.decode(), json.dumps(outcome))

    def test_wrong_key_id_filename_or_issuer_is_rejected_before_network(self) -> None:
        for changes in (
            {"key_id": "a"},
            {"key_id": "OTHERKEY123"},
            {"issuer": "wrong-team"},
        ):
            with self.subTest(changes=changes), patch.object(
                credentials, "aws_client"
            ) as aws:
                with self.assertRaises(credentials.CredentialError):
                    asyncio.run(credentials.execute(self.arguments(**changes)))
                aws.assert_not_called()

    def test_path_must_be_private_regular_single_link_and_owned(self) -> None:
        self.path.chmod(0o644)
        with self.assertRaises(credentials.CredentialError):
            credentials.inspect_key_path(self.path)
        self.path.chmod(0o600)
        link = self.path.with_name("link.p8")
        link.symlink_to(self.path)
        with self.assertRaises(credentials.CredentialError):
            credentials.inspect_key_path(link)
        link.unlink()
        os.link(self.path, link)
        with self.assertRaises(credentials.CredentialError):
            credentials.inspect_key_path(self.path)
        link.unlink()
        with patch.object(credentials.os, "getuid", return_value=os.getuid() + 1):
            with self.assertRaises(credentials.CredentialError):
                credentials.inspect_key_path(self.path)
        for candidate in (Path("relative.p8"), self.path.with_suffix(".txt")):
            with self.assertRaises(credentials.CredentialError):
                credentials.inspect_key_path(candidate)
        folder = self.path.with_name("folder.p8")
        folder.mkdir(mode=0o600)
        with self.assertRaises(credentials.CredentialError):
            credentials.inspect_key_path(folder)

    def test_path_size_and_replacement_are_rejected(self) -> None:
        for size in (0, credentials.MAX_KEY_BYTES + 1):
            self.path.write_bytes(b"x" * size)
            with self.assertRaises(credentials.CredentialError):
                credentials.read_key(self.path)
        self.path.write_bytes(self.pem)
        with patch.object(credentials, "file_identity", side_effect=[(1,), (2,)]):
            with self.assertRaisesRegex(credentials.CredentialError, "changed"):
                credentials.read_key(self.path)
        with patch.object(
            credentials, "file_identity", side_effect=[(1,), (1,), (2,), (1,)]
        ):
            with self.assertRaisesRegex(credentials.CredentialError, "during"):
                credentials.read_key(self.path)

    def test_p8_must_be_single_valid_p256_pkcs8(self) -> None:
        self.assertEqual(credentials.read_key(self.path), self.pem)
        wrong = ed25519.Ed25519PrivateKey.generate().private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        )
        wrong_curve = ec.generate_private_key(ec.SECP384R1()).private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        )
        for value in (
            self.pem + self.pem,
            wrong,
            wrong_curve,
            b"-----BEGIN PRIVATE KEY-----\n"
            + b"A" * 64
            + b"\n-----END PRIVATE KEY-----\n",
        ):
            self.path.write_bytes(value)
            with self.assertRaises(credentials.CredentialError):
                credentials.read_key(self.path)

    def test_import_preserves_certificate_and_other_fields_exactly(self) -> None:
        validator = AsyncMock()
        outcome = asyncio.run(
            credentials.apply_notary(self.client, self.path, TEST_KEY_ID, validator)
        )
        validator.assert_awaited_once_with(self.pem, TEST_KEY_ID)
        self.assertEqual(outcome["status"], "provisioned")
        for key, value in self.certificate_document.items():
            self.assertEqual(self.client.document[key], value)
        self.assertNotIn(credentials.SEED_FIELD, self.client.document)
        self.assertEqual(
            self.client.writes[1]["RemoveFromVersionId"], "original-version"
        )
        self.assertEqual(len(self.client.writes), 3)
        self.assertNotIn(self.pem.decode(), json.dumps(outcome))
        self.assertNotIn(self.certificate_document["p12_password"], json.dumps(outcome))

    def test_apple_failure_cannot_write_aws(self) -> None:
        validator = AsyncMock(
            side_effect=credentials.CredentialError("Authentication refused.")
        )
        with self.assertRaises(credentials.CredentialError):
            asyncio.run(
                credentials.apply_notary(self.client, self.path, TEST_KEY_ID, validator)
            )
        self.assertEqual(self.client.writes, [])

    def test_exact_existing_credentials_are_idempotent(self) -> None:
        self.client.document.update(self.notary_values())
        result = asyncio.run(
            credentials.apply_notary(self.client, self.path, TEST_KEY_ID, AsyncMock())
        )
        self.assertEqual(result["status"], "unchanged")
        self.assertEqual(self.client.writes, [])
        self.client.reads = 0
        self.client.race = "before"
        with self.assertRaises(credentials.CredentialError):
            asyncio.run(
                credentials.apply_notary(
                    self.client, self.path, TEST_KEY_ID, AsyncMock()
                )
            )

    def test_different_or_partial_existing_credentials_are_never_overwritten(
        self,
    ) -> None:
        for values in (
            {"notary_key_id": TEST_KEY_ID},
            self.notary_values() | {"notary_key_id": "OTHERKEY123"},
            self.notary_values() | {"notary_key_p8": "another private value"},
        ):
            client = FakeSecrets(self.certificate_document | values)
            validator = AsyncMock()
            with self.assertRaises(credentials.CredentialError):
                asyncio.run(
                    credentials.apply_notary(client, self.path, TEST_KEY_ID, validator)
                )
            validator.assert_not_awaited()
            self.assertEqual(client.writes, [])

    def test_all_three_cas_races_fail_closed(self) -> None:
        for race in ("before", "during", "after"):
            client = FakeSecrets(self.certificate_document)
            client.race = race
            with self.subTest(race=race), self.assertRaises(
                (credentials.CredentialError, RuntimeError)
            ):
                asyncio.run(
                    credentials.apply_notary(
                        client, self.path, TEST_KEY_ID, AsyncMock()
                    )
                )
            if race == "before":
                self.assertEqual(client.writes, [])
            if race == "during":
                self.assertEqual(client.document, self.certificate_document)

    def test_pending_response_corruption_stops_before_promotion(self) -> None:
        self.client.bad_put = True
        with self.assertRaises(credentials.CredentialError):
            asyncio.run(credentials.apply_update_key(self.client))
        self.assertEqual(len(self.client.writes), 1)
        self.assertEqual(self.client.version, "original-version")

    def test_promote_refuses_modified_prior_value_or_oversize_document(self) -> None:
        before = credentials.read_current(self.client)
        for values in (
            before.document | {"p12_password": "other"},
            before.document | {"large": "x" * 65536},
        ):
            with self.assertRaises(credentials.CredentialError):
                credentials.promote(self.client, before, values)
        self.assertEqual(self.client.writes, [])

    def test_seed_generation_is_explicit_preserves_everything_and_outputs_only_public(
        self,
    ) -> None:
        self.client.document.update(self.notary_values())
        result = asyncio.run(credentials.apply_update_key(self.client))
        seed = base64.b64decode(
            self.client.document[credentials.SEED_FIELD], validate=True
        )
        self.assertEqual(len(seed), 32)
        self.assertEqual(
            base64.b64decode(result["updatePublicKey"]),
            ed25519.Ed25519PrivateKey.from_private_bytes(seed)
            .public_key()
            .public_bytes_raw(),
        )
        self.assertEqual(self.client.document["notary_key_p8"], self.pem.decode())
        self.assertNotIn(
            self.client.document[credentials.SEED_FIELD], json.dumps(result)
        )
        self.assertNotIn(self.pem.decode(), json.dumps(result))
        count = len(self.client.writes)
        with patch.object(
            credentials.ed25519.Ed25519PrivateKey, "generate"
        ) as generate:
            repeat = asyncio.run(credentials.apply_update_key(self.client))
        generate.assert_not_called()
        self.assertEqual(repeat["status"], "unchanged")
        self.assertEqual(repeat["updatePublicKey"], result["updatePublicKey"])
        self.assertEqual(len(self.client.writes), count)

    def test_existing_invalid_seed_is_not_replaced(self) -> None:
        for seed in (None, "", "not base64", base64.b64encode(b"short").decode(), 1):
            client = FakeSecrets(
                self.certificate_document | {credentials.SEED_FIELD: seed}
            )
            with patch.object(
                credentials.ed25519.Ed25519PrivateKey, "generate"
            ) as generate:
                with self.assertRaises(credentials.CredentialError):
                    asyncio.run(credentials.apply_update_key(client))
            generate.assert_not_called()
            self.assertEqual(client.writes, [])

    def test_existing_seed_concurrent_change_cannot_report_stale_public_key(
        self,
    ) -> None:
        self.client.document[credentials.SEED_FIELD] = base64.b64encode(
            bytes(range(32))
        ).decode()
        self.client.race = "before"
        with self.assertRaises(credentials.CredentialError):
            asyncio.run(credentials.apply_update_key(self.client))

    def test_existing_certificate_must_be_valid_and_pinned(self) -> None:
        for changes in (
            {"developer_id_identity": "someone else"},
            {"developer_id_certificate_sha256": "0" * 64},
            {"developer_id_p12": "not-base64"},
            {"p12_password": "too short"},
            {"developer_id_p12": base64.b64encode(b"invalid p12").decode()},
        ):
            with self.subTest(changes=list(changes)), self.assertRaises(
                credentials.CredentialError
            ):
                credentials.validate_certificate(self.certificate_document | changes)
        with patch.object(credentials, "CERT_SHA256", "0" * 64):
            with self.assertRaises(credentials.CredentialError):
                credentials.validate_certificate(
                    self.certificate_document
                    | {"developer_id_certificate_sha256": "0" * 64}
                )
        with patch.object(
            credentials.pkcs12,
            "load_key_and_certificates",
            return_value=(None, None, None),
        ):
            with self.assertRaises(credentials.CredentialError):
                credentials.validate_certificate(self.certificate_document)

    def test_secret_arn_deletion_json_and_version_are_validated(self) -> None:
        self.client.arn = "another-arn"
        with self.assertRaises(credentials.CredentialError):
            credentials.read_current(self.client)
        self.client.arn = credentials.SECRET_ARN
        self.client.deleted = True
        with self.assertRaises(credentials.CredentialError):
            credentials.read_current(self.client)
        self.client.deleted = False
        for raw in ("{", "[]"):
            self.client.raw_json = raw
            with self.assertRaises(credentials.CredentialError):
                credentials.read_current(self.client)
        self.client.raw_json = None
        self.client.version = ""
        with self.assertRaises(credentials.CredentialError):
            credentials.read_current(self.client)
        with patch.object(
            self.client, "get_secret_value", return_value={"ARN": "other"}
        ):
            with self.assertRaises(credentials.CredentialError):
                credentials.read_current(self.client)

    def test_aws_account_and_endpoint_guard(self) -> None:
        sts = Mock()
        sts.meta.endpoint_url = f"https://sts.{credentials.REGION}.amazonaws.com"
        sts.get_caller_identity.return_value = {"Account": credentials.ACCOUNT}
        client = Mock()
        client.meta.endpoint_url = (
            f"https://secretsmanager.{credentials.REGION}.amazonaws.com"
        )
        session = Mock()
        session.client.side_effect = lambda name, **_kwargs: (
            sts if name == "sts" else client
        )
        boto = Mock()
        boto.Session.return_value = session
        config = Mock()
        with patch.object(
            credentials.importlib,
            "import_module",
            side_effect=lambda name: boto if name == "boto3" else config,
        ):
            self.assertIs(credentials.aws_client("mokaid"), client)
            sts.get_caller_identity.return_value = {"Account": "111111111111"}
            with self.assertRaises(credentials.CredentialError):
                credentials.aws_client("mokaid")
            sts.get_caller_identity.reset_mock()
            client.meta.endpoint_url = "https://attacker.invalid"
            with self.assertRaises(credentials.CredentialError):
                credentials.aws_client("mokaid")
            sts.get_caller_identity.assert_not_called()

    def test_notary_process_uses_history_only_suppresses_output_and_cleans_private_file(
        self,
    ) -> None:
        paths: list[Path] = []
        process = Mock(returncode=0)
        process.wait = AsyncMock(return_value=0)

        async def spawn(*args: str, **kwargs: Any) -> Mock:
            self.assertEqual(args[:3], ("/usr/bin/xcrun", "notarytool", "history"))
            self.assertNotIn("submit", args)
            path = Path(args[args.index("--key") + 1])
            paths.append(path)
            self.assertEqual(path.read_bytes(), self.pem)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
            self.assertEqual(kwargs["stdout"], asyncio.subprocess.DEVNULL)
            self.assertEqual(kwargs["stderr"], asyncio.subprocess.DEVNULL)
            self.assertNotIn(self.pem.decode(), repr((args, kwargs)))
            self.assertNotIn("AWS_SECRET_ACCESS_KEY", kwargs["env"])
            return process

        with patch.object(
            credentials.platform, "system", return_value="Darwin"
        ), patch.object(
            credentials.asyncio, "create_subprocess_exec", side_effect=spawn
        ):
            asyncio.run(credentials.validate_notary(self.pem, TEST_KEY_ID))
        self.assertTrue(paths)
        self.assertFalse(paths[0].exists())
        self.assertFalse(paths[0].parent.exists())

    def test_notary_failure_timeout_cancel_and_unsupported_platform(self) -> None:
        with patch.object(credentials.platform, "system", return_value="Linux"):
            with self.assertRaises(credentials.CredentialError):
                asyncio.run(credentials.validate_notary(self.pem, TEST_KEY_ID))
        for result in (1, TimeoutError(), asyncio.CancelledError()):
            process = Mock(returncode=None)
            process.wait = AsyncMock(side_effect=[result, 0])
            with patch.object(
                credentials.platform, "system", return_value="Darwin"
            ), patch.object(
                credentials.asyncio, "create_subprocess_exec", return_value=process
            ):
                with self.assertRaises(credentials.CredentialError):
                    asyncio.run(credentials.validate_notary(self.pem, TEST_KEY_ID))
            if not isinstance(result, int):
                process.kill.assert_called_once()

    def test_execute_apply_dispatches_only_requested_action(self) -> None:
        with patch.object(
            credentials, "aws_client", return_value=self.client
        ), patch.object(
            credentials,
            "apply_notary",
            new_callable=AsyncMock,
            return_value={"status": "test"},
        ) as notary:
            self.assertEqual(
                asyncio.run(credentials.execute(self.arguments(apply=True))),
                {"status": "test"},
            )
        notary.assert_awaited_once_with(self.client, self.path, TEST_KEY_ID)
        with patch.object(
            credentials, "aws_client", return_value=self.client
        ), patch.object(
            credentials,
            "apply_update_key",
            new_callable=AsyncMock,
            return_value={"status": "test"},
        ) as update:
            asyncio.run(
                credentials.execute(
                    self.arguments(action="generate-update-key", apply=True)
                )
            )
        update.assert_awaited_once_with(self.client)

    def test_cli_default_and_errors_never_print_sensitive_values(self) -> None:
        with patch("sys.stdout", new_callable=io.StringIO) as output:
            self.assertEqual(credentials.main(["generate-update-key"]), 0)
        self.assertFalse(json.loads(output.getvalue())["networkContacted"])
        for error in (
            RuntimeError(self.pem.decode()),
            credentials.CredentialError("Fixed safe failure."),
            KeyboardInterrupt(),
        ):
            with patch.object(
                credentials, "execute", new_callable=AsyncMock, side_effect=error
            ), patch("sys.stderr", new_callable=io.StringIO) as output:
                self.assertEqual(
                    credentials.main(["generate-update-key", "--apply"]), 2
                )
            self.assertNotIn(self.pem.decode(), output.getvalue())
        with patch("sys.stderr", new_callable=io.StringIO), self.assertRaises(
            SystemExit
        ):
            credentials.main(
                [
                    "notary",
                    "--key-path",
                    str(self.path),
                    "--key-id",
                    TEST_KEY_ID,
                    "--issuer",
                    credentials.ISSUER,
                    "--apply",
                    "--verify-notary",
                ]
            )


if __name__ == "__main__":
    unittest.main()
