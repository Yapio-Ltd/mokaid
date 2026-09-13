from __future__ import annotations

import base64
from datetime import datetime, timedelta, timezone
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

SPEC = importlib.util.spec_from_file_location("keychain_release", Path(__file__).parents[1] / "release.py")
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class KeychainUnitTests(unittest.TestCase):
    def test_no_password_in_child_argv_or_environment(self):
        secret = {"developer_id_identity": "Developer ID Application: Synthetic Test", "developer_id_p12": "SYNTHETIC_P12",
                  "p12_password": "SYNTHETIC_PASSWORD_NEVER_PRINT", "developer_id_certificate_sha256": "a" * 64}
        with tempfile.TemporaryDirectory(prefix="mokaid-keychain-unit-") as directory:
            keychain = Path(directory) / "signing.keychain-db"
            keychain.touch() # Only a test fixture; native helper is mocked.
            outcome = types.SimpleNamespace(returncode=0, stdout=json.dumps({"certificate_sha256": "a" * 64, "codesign_acl_verified": True,
                                                                            "codesign_identity": "b" * 40}).encode())
            with patch.object(release, "run") as compile_helper, patch.object(release.subprocess, "run", return_value=outcome) as command:
                actual, identity = release.create_signing_keychain(Path(directory), secret)
            self.assertEqual(actual, keychain)
            self.assertEqual(identity, "b" * 40)
            self.assertEqual(len(command.call_args.args[0]), 1)
            request = json.loads(command.call_args.kwargs["input"])
            self.assertEqual(request["p12_password"], secret["p12_password"])
            self.assertGreaterEqual(len(request["keychain_password"]), 43)
            self.assertNotIn(secret["p12_password"], str(command.call_args.args))
            self.assertNotIn(secret["p12_password"], str(command.call_args.kwargs["env"]))
            self.assertNotIn(secret["p12_password"], str(compile_helper.call_args))

    def test_import_failure_does_not_echo_helper_secret_output(self):
        secret = {"developer_id_identity": "Developer ID Application: Synthetic Test", "developer_id_p12": "SECRET_P12",
                  "p12_password": "SECRET_PASSWORD", "developer_id_certificate_sha256": "a" * 64}
        with tempfile.TemporaryDirectory(prefix="mokaid-keychain-unit-") as directory:
            outcome = types.SimpleNamespace(returncode=1, stdout=b"SECRET_PASSWORD", stderr=b"SECRET_P12")
            with patch.object(release, "run"), patch.object(release.subprocess, "run", return_value=outcome):
                with self.assertRaises(ValueError) as failure:
                    release.create_signing_keychain(Path(directory), secret)
            self.assertNotIn("SECRET", str(failure.exception))

    def test_release_source_has_no_password_bearing_security_cli(self):
        source = (release.HERE / "release.py").read_text()
        for command in ("create-keychain", "unlock-keychain", "set-key-partition-list"):
            self.assertNotIn(f'run("security", "{command}"', source)
        self.assertNotIn('run("security", "import"', source)
        helper = (release.HERE / "macos/import_identity.m").read_text()
        self.assertIn('SecTrustedApplicationCreateFromPath("/usr/bin/codesign"', helper)
        self.assertIn('SecPKCS12Import', helper)
        self.assertNotIn('SecKeychainItemSetAccessWithPassword', helper) # No private API.


@unittest.skipUnless(sys.platform == "darwin" and os.environ.get("MOKAID_RUN_KEYCHAIN_TESTS") == "1",
                     "Explicit opt-in required for a disposable synthetic macOS keychain")
class KeychainIntegrationTests(unittest.TestCase):
    def test_aes256_synthetic_roundtrip_and_verified_restricted_acl(self):
        from cryptography import x509
        from cryptography.hazmat.primitives import hashes
        from cryptography.hazmat.primitives.asymmetric import rsa
        from cryptography.hazmat.primitives.serialization import pkcs12, PrivateFormat
        from cryptography.x509.oid import NameOID, ExtendedKeyUsageOID
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        name = "Developer ID Application: Mokaid Synthetic CI Test"
        subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, name)])
        now = datetime.now(timezone.utc)
        certificate = (x509.CertificateBuilder().subject_name(subject).issuer_name(subject).public_key(key.public_key())
                       .serial_number(x509.random_serial_number()).not_valid_before(now - timedelta(minutes=1))
                       .not_valid_after(now + timedelta(hours=1))
                       .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
                       .add_extension(x509.KeyUsage(True, False, False, False, False, False, False, None, None), critical=True)
                       .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.CODE_SIGNING]), critical=False)
                       .sign(key, hashes.SHA256()))
        password = base64.b64encode(os.urandom(48)).decode()
        encryption = (PrivateFormat.PKCS12.encryption_builder().kdf_rounds(200_000)
                      .key_cert_algorithm(pkcs12.PBES.PBESv2SHA256AndAES256CBC)
                      .hmac_hash(hashes.SHA256()).build(password.encode()))
        payload = pkcs12.serialize_key_and_certificates(name.encode(), key, certificate, None, encryption)
        secret = {"developer_id_identity": name, "developer_id_p12": base64.b64encode(payload).decode(),
                  "p12_password": password, "developer_id_certificate_sha256": certificate.fingerprint(hashes.SHA256()).hex()}
        original = subprocess.run(["/usr/bin/security", "list-keychains", "-d", "user"], capture_output=True, check=True).stdout
        with tempfile.TemporaryDirectory(prefix="mokaid-synthetic-keychain-") as directory:
            root = Path(directory)
            keychain = root / "signing.keychain-db"
            try:
                imported, identity = release.create_signing_keychain(root, secret)
                self.assertEqual(imported, keychain)
                self.assertEqual(identity, certificate.fingerprint(hashes.SHA1()).hex())
                after = subprocess.run(["/usr/bin/security", "list-keychains", "-d", "user"], capture_output=True, check=True).stdout
                self.assertEqual(after, original)
                # A synthetic self-signed certificate is intentionally NOT a
                # trusted Developer ID. Do not change the user's trust store to
                # force codesign acceptance. The helper verifies its signing ACL
                # using Security.framework and rejects any allow-all application.
                diagnostic = subprocess.run(["/usr/bin/security", "find-identity", "-p", "codesigning", str(keychain)],
                                            capture_output=True, check=True, timeout=30)
                self.assertIn(identity.upper().encode(), diagnostic.stdout)
                self.assertIn(b"CSSMERR_TP_NOT_TRUSTED", diagnostic.stdout)
            finally:
                if keychain.exists():
                    subprocess.run(["/usr/bin/security", "delete-keychain", str(keychain)], capture_output=True, check=True)
        final = subprocess.run(["/usr/bin/security", "list-keychains", "-d", "user"], capture_output=True, check=True).stdout
        self.assertEqual(final, original)


if __name__ == "__main__":
    unittest.main()
