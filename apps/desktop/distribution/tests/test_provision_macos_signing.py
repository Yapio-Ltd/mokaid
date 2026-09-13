from __future__ import annotations

import base64
from datetime import datetime, timedelta, timezone
import importlib.util
import json
from pathlib import Path
import subprocess
import types
import unittest
from unittest.mock import Mock, patch

SPEC = importlib.util.spec_from_file_location("provision_macos_signing", Path(__file__).parents[1] / "provision_macos_signing.py")
provisioning = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(provisioning)


class NotFound(Exception):
    pass


class FakeSecrets:
    exceptions = types.SimpleNamespace(ResourceNotFoundException=NotFound)

    def __init__(self, document=None):
        self.document = document
        self.arn = f"arn:aws:secretsmanager:{provisioning.REGION}:{provisioning.ACCOUNT}:secret:mokaid/desktop/beta/macos-signing-Ab12Cd"
        self.version = "old-version"
        self.writes = []
        self.pending = {}
        self.reads = 0
        self.race_on_read = False
        self.race_on_promotion = False
        self.race_after_write = False

    def describe_secret(self, **kwargs):
        if self.document is None:
            raise NotFound()
        return {"ARN": self.arn}

    def get_secret_value(self, **kwargs):
        self.reads += 1
        if self.race_on_read and self.reads > 1:
            self.version = "concurrent-version"
        if self.race_after_write and self.writes:
            self.version = "later-concurrent-version"
        return {"SecretString": json.dumps(self.document), "VersionId": self.version}

    def create_secret(self, **kwargs):
        if self.document is not None:
            raise RuntimeError("Concurrent secret creator")
        self.writes.append(("create", kwargs))
        self.document = json.loads(kwargs["SecretString"])
        self.version = kwargs["ClientRequestToken"]
        return {"ARN": self.arn}

    def put_secret_value(self, **kwargs):
        self.writes.append(("put", kwargs))
        self.pending[kwargs["ClientRequestToken"]] = json.loads(kwargs["SecretString"])

    def update_secret_version_stage(self, **kwargs):
        self.writes.append(("stage", kwargs))
        if kwargs["VersionStage"] == "AWSCURRENT":
            if self.race_on_promotion:
                self.version = "concurrent-version"
            if kwargs["RemoveFromVersionId"] != self.version:
                raise RuntimeError("AWS conditional stage move refused")
            self.version = kwargs["MoveToVersionId"]
            self.document = self.pending[self.version]


class ProvisionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from cryptography import x509
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import ec
        from cryptography.x509.oid import NameOID
        cls.key = ec.generate_private_key(ec.SECP256R1())
        subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, provisioning.IDENTITY)])
        now = datetime.now(timezone.utc)
        cls.certificate = (x509.CertificateBuilder().subject_name(subject).issuer_name(subject)
                           .public_key(cls.key.public_key()).serial_number(1)
                           .not_valid_before(now - timedelta(days=1)).not_valid_after(now + timedelta(days=1))
                           .sign(cls.key, hashes.SHA256()))
        cls.fingerprint = cls.certificate.fingerprint(hashes.SHA256()).hex()

    def setUp(self):
        # Synthetic, in-memory certificate. The shipping pin is never replaced.
        fingerprint = patch.object(provisioning, "CERT_SHA256", self.fingerprint)
        fingerprint.start()
        self.addCleanup(fingerprint.stop)

    def export_fixture(self, password):
        from cryptography.hazmat.primitives.serialization import pkcs12, BestAvailableEncryption
        return pkcs12.serialize_key_and_certificates(b"UNIT TEST ONLY", self.key, self.certificate, None,
                                                      BestAvailableEncryption(password.encode()))

    def certificate_document(self):
        password = "UNIT TEST ONLY NOT A REAL PASSWORD" * 2
        return {"developer_id_identity": provisioning.IDENTITY, "p12_password": password,
                "developer_id_p12": base64.b64encode(self.export_fixture(password)).decode()}

    def test_default_plan_never_exports_or_writes(self):
        client, exporter = FakeSecrets(), Mock()
        outcome = provisioning.provision(client, "beta", apply=False, exporter=exporter)
        self.assertEqual(outcome["status"], "planned")
        self.assertEqual(set(outcome["missingReleaseFields"]), provisioning.RELEASE_FIELDS)
        self.assertEqual(client.writes, [])
        exporter.assert_not_called()

    def test_create_exports_one_identity_without_fabricating_missing_keys(self):
        client, exporter = FakeSecrets(), Mock(side_effect=self.export_fixture)
        outcome = provisioning.provision(client, "beta", apply=True, exporter=exporter)
        exporter.assert_called_once()
        self.assertEqual(len(exporter.call_args.args[0]), 64)
        self.assertEqual([kind for kind, _ in client.writes], ["create"])
        self.assertEqual(outcome["status"], "provisioned")
        self.assertEqual(set(outcome["missingReleaseFields"]), provisioning.RELEASE_FIELDS - provisioning.CERT_FIELDS - {"developer_id_certificate_sha256"})
        self.assertNotIn("update_ed25519_seed", client.document)
        self.assertNotIn("notary_key_p8", client.document)
        self.assertNotIn(client.document["p12_password"], json.dumps(outcome))
        self.assertNotIn(client.document["developer_id_p12"], json.dumps(outcome))
        provisioning.validate_pkcs12(base64.b64decode(client.document["developer_id_p12"]), client.document["p12_password"])

    def test_existing_exact_identity_is_idempotent_without_export(self):
        client, exporter = FakeSecrets(self.certificate_document()), Mock()
        outcome = provisioning.provision(client, "beta", apply=True, exporter=exporter)
        self.assertEqual(outcome["status"], "unchanged")
        self.assertEqual(client.writes, [])
        exporter.assert_not_called()

    def test_preserves_other_credentials_and_promotes_conditionally(self):
        document = {"notary_key_p8": "SYNTHETIC KEY", "update_ed25519_seed": "SYNTHETIC SEED", "custom": {"keep": True}}
        client = FakeSecrets(document.copy())
        provisioning.provision(client, "beta", apply=True, exporter=self.export_fixture)
        for field, value in document.items():
            self.assertEqual(client.document[field], value)
        self.assertEqual([kind for kind, _ in client.writes], ["put", "stage", "stage"])
        put = client.writes[0][1]
        self.assertNotIn("AWSCURRENT", put["VersionStages"])
        move = client.writes[1][1]
        self.assertEqual(move["RemoveFromVersionId"], "old-version")
        self.assertEqual(move["MoveToVersionId"], put["ClientRequestToken"])

    def test_concurrent_update_after_export_is_not_overwritten(self):
        client = FakeSecrets({"notary_key_id": "EXISTING"})
        client.race_on_read = True
        with self.assertRaisesRegex(provisioning.ProvisionError, "concurrently"):
            provisioning.provision(client, "beta", apply=True, exporter=self.export_fixture)
        self.assertEqual(client.writes, [])

    def test_race_during_stage_move_never_changes_current_document(self):
        original = {"notary_key_id": "EXISTING"}
        client = FakeSecrets(original.copy())
        client.race_on_promotion = True
        with self.assertRaises(RuntimeError):
            provisioning.provision(client, "beta", apply=True, exporter=self.export_fixture)
        self.assertEqual(client.document, original)
        self.assertEqual([kind for kind, _ in client.writes], ["put", "stage"])

    def test_post_write_reread_requires_our_exact_current_version(self):
        client = FakeSecrets({"notary_key_id": "EXISTING"})
        client.race_after_write = True
        with self.assertRaisesRegex(provisioning.ProvisionError, "not verified as current"):
            provisioning.provision(client, "beta", apply=True, exporter=self.export_fixture)

    def test_partial_existing_certificate_is_not_overwritten(self):
        client, exporter = FakeSecrets({"developer_id_identity": provisioning.IDENTITY}), Mock()
        with self.assertRaisesRegex(provisioning.ProvisionError, "incomplete"):
            provisioning.provision(client, "beta", apply=True, exporter=exporter)
        exporter.assert_not_called()
        self.assertEqual(client.writes, [])

    def test_wrong_aws_destination_is_rejected(self):
        client = FakeSecrets({})
        client.arn = client.arn.replace(provisioning.ACCOUNT, "123456789012")
        with self.assertRaisesRegex(provisioning.ProvisionError, "ARN"):
            provisioning.provision(client, "beta", apply=False, exporter=Mock())

    def test_wrong_certificate_fingerprint_is_rejected(self):
        password = "SYNTHETIC PASSWORD ONLY" * 3
        with patch.object(provisioning, "CERT_SHA256", "a" * 64):
            with self.assertRaisesRegex(provisioning.ProvisionError, "fingerprint"):
                provisioning.validate_pkcs12(self.export_fixture(password), password)

    def test_invalid_p12_errors_never_include_payload_or_password(self):
        sentinel = "NEVER DISCLOSE THIS TEST VALUE" * 2
        with self.assertRaises(provisioning.ProvisionError) as failure:
            provisioning.validate_pkcs12(sentinel.encode(), sentinel)
        self.assertNotIn(sentinel, str(failure.exception))

    def test_helper_keeps_password_out_of_argv_and_environment(self):
        sentinel = "SYNTHETIC PASSWORD" * 4
        request = {"certificate_sha256": provisioning.CERT_SHA256, "passphrase": sentinel}
        with patch.object(provisioning.subprocess, "run", return_value=types.SimpleNamespace(returncode=0, stdout=b"encrypted")) as command:
            result = provisioning.helper_call(Path("/private/tmp/test-helper"), "export", request)
        self.assertEqual(result, b"encrypted")
        self.assertEqual(command.call_args.args[0], ["/private/tmp/test-helper", "export"])
        self.assertEqual(json.loads(command.call_args.kwargs["input"]), request)
        self.assertNotIn(sentinel, str(command.call_args.kwargs["env"]))
        self.assertTrue(command.call_args.kwargs["capture_output"])

    def test_helper_failure_discards_sensitive_stdout_stderr_and_exception(self):
        sentinel = "SENSITIVE TEST OUTPUT"
        with patch.object(provisioning.subprocess, "run", return_value=types.SimpleNamespace(returncode=1, stdout=sentinel.encode(), stderr=sentinel.encode())):
            with self.assertRaises(provisioning.ProvisionError) as failure:
                provisioning.helper_call(Path("/private/tmp/test-helper"), "export", {})
        self.assertNotIn(sentinel, str(failure.exception))
        with patch.object(provisioning.subprocess, "run", side_effect=subprocess.TimeoutExpired(sentinel, 120)):
            with self.assertRaises(provisioning.ProvisionError) as failure:
                provisioning.helper_call(Path("/private/tmp/test-helper"), "export", {})
        self.assertNotIn(sentinel, str(failure.exception))

    def test_blank_release_fields_remain_reported_missing(self):
        self.assertIn("notary_key_id", provisioning.missing_fields({"notary_key_id": ""}))

    def test_native_export_targets_single_identity_and_never_exports_keychain(self):
        source = (provisioning.HERE / "macos/export_identity.m").read_text()
        self.assertIn("SecItemExport(identity, kSecFormatPKCS12", source)
        self.assertIn("SecIdentityCreateWithCertificate(NULL, selected, &identity)", source)
        self.assertIn("isatty(STDIN_FILENO) || isatty(STDOUT_FILENO)", source)
        self.assertNotIn("SecItemExport(found", source)
        self.assertNotIn("kSecClassKey", source)
        self.assertNotIn("kSecClassIdentity", source)


if __name__ == "__main__":
    unittest.main()
