#!/usr/bin/env python3
"""Prepare/explicitly provision the exact approved Mac certificate in AWS.

Default: read-only inspection. --apply requires separately approved execution.
No secret is written to disk, passed in argv/environment, or printed. This tool
does not create update keys, notarization credentials, IAM policies or releases.
"""
from __future__ import annotations

import argparse
import base64
from datetime import datetime, timezone
import json
import logging
import os
from pathlib import Path
import platform
import re
import secrets
import subprocess
import sys
import tempfile
import uuid

ACCOUNT = "660601648321"
REGION = "il-central-1"
IDENTITY = "Developer ID Application: Yapio (4KH7528725)"
CERT_SHA256 = "c38e12abd12b6c4ab0904f096f036e63596a25527de6123d4d7a2778420ece46"
CERT_FIELDS = frozenset({"developer_id_p12", "p12_password", "developer_id_identity"})
RELEASE_FIELDS = CERT_FIELDS | {"developer_id_certificate_sha256", "update_ed25519_seed", "notary_key_p8", "notary_key_id", "notary_issuer"}
HERE = Path(__file__).resolve().parent


class ProvisionError(Exception):
    """Contains only fixed, non-sensitive messages safe for operator output."""


def require(condition: object, message: str) -> None:
    if not condition:
        raise ProvisionError(message)


def secret_name(channel: str) -> str:
    require(channel in ("stable", "beta"), "Select an explicit stable or beta channel.")
    return f"mokaid/desktop/{channel}/macos-signing"


def missing_fields(document: dict) -> list[str]:
    return sorted(name for name in RELEASE_FIELDS
                  if not isinstance(document.get(name), str) or not document[name])


def validate_certificate(certificate) -> None:
    from cryptography.hazmat.primitives import hashes
    from cryptography.x509.oid import NameOID
    require(certificate.fingerprint(hashes.SHA256()).hex() == CERT_SHA256,
            "Certificate does not match the exact approved SHA256 fingerprint.")
    names = certificate.subject.get_attributes_for_oid(NameOID.COMMON_NAME)
    require(len(names) == 1 and names[0].value == IDENTITY, "Certificate identity does not match.")
    now = datetime.now(timezone.utc)
    require(certificate.not_valid_before_utc <= now < certificate.not_valid_after_utc,
            "The approved certificate is not currently valid.")


def validate_pkcs12(payload: bytes, password: str):
    from cryptography.hazmat.primitives.serialization import pkcs12, Encoding, PublicFormat
    require(isinstance(password, str) and len(password) >= 32, "Invalid encrypted-certificate password.")
    require(isinstance(payload, bytes) and 0 < len(payload) <= 49152, "Invalid encrypted-certificate size.")
    try:
        key, certificate, chain = pkcs12.load_key_and_certificates(payload, password.encode())
    except Exception:
        raise ProvisionError("Encrypted identity validation failed.") from None
    require(key is not None and certificate is not None, "Encrypted identity must include a private key and certificate.")
    validate_certificate(certificate)
    require(key.public_key().public_bytes(Encoding.DER, PublicFormat.SubjectPublicKeyInfo) ==
            certificate.public_key().public_bytes(Encoding.DER, PublicFormat.SubjectPublicKeyInfo),
            "Certificate and private key do not match.")
    return key, certificate, chain


def protect_export(payload: bytes, password: str) -> bytes:
    # Security.framework may export a legacy PKCS#12 encoding. Store an explicit
    # PBES2 AES-256/SHA256 representation, not the old transport cipher.
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.serialization import pkcs12, PrivateFormat
    key, certificate, chain = validate_pkcs12(payload, password)
    encryption = (PrivateFormat.PKCS12.encryption_builder().kdf_rounds(200_000)
                  .key_cert_algorithm(pkcs12.PBES.PBESv2SHA256AndAES256CBC)
                  .hmac_hash(hashes.SHA256()).build(password.encode()))
    protected = pkcs12.serialize_key_and_certificates(IDENTITY.encode(), key, certificate, chain, encryption)
    validate_pkcs12(protected, password)
    return protected


def helper_call(helper: Path, operation: str, request: dict | None = None) -> bytes:
    require(operation in ("inspect", "export"), "Invalid identity-helper operation.")
    environment = {key: os.environ[key] for key in ("HOME", "TMPDIR") if key in os.environ}
    environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    try:
        result = subprocess.run([str(helper), operation],
                                input=json.dumps(request).encode() if request is not None else b"",
                                capture_output=True, timeout=120, check=False, env=environment)
    except (OSError, subprocess.SubprocessError):
        raise ProvisionError("Identity helper could not complete; no credential details are logged.") from None
    require(result.returncode == 0, "Identity helper refused or failed; no credential details are logged.")
    require(0 < len(result.stdout) <= 65536, "Identity helper returned an invalid payload size.")
    return result.stdout


def build_helper(directory: Path) -> Path:
    require(platform.system() == "Darwin", "Identity provisioning requires the owner's macOS Keychain.")
    output = directory / "export_identity"
    try:
        result = subprocess.run(["/usr/bin/xcrun", "clang", "-fobjc-arc", "-Wall", "-Wextra", "-Werror",
                                 "-mmacosx-version-min=13.0", "-framework", "Foundation", "-framework", "Security",
                                 str(HERE / "macos/export_identity.m"), "-o", str(output)],
                                capture_output=True, check=False, timeout=120)
    except (OSError, subprocess.SubprocessError):
        raise ProvisionError("Cannot compile the reviewed identity helper.") from None
    require(result.returncode == 0, "Cannot compile the reviewed identity helper.")
    return output


def inspect_identity(helper: Path) -> None:
    from cryptography import x509
    try:
        public = json.loads(helper_call(helper, "inspect"))
        certificate = x509.load_der_x509_certificate(base64.b64decode(public["certificate_der"], validate=True))
    except Exception:
        raise ProvisionError("Public certificate inspection failed.") from None
    validate_certificate(certificate)


def read_current(client, channel: str) -> tuple[str | None, str | None, dict]:
    name = secret_name(channel)
    try:
        description = client.describe_secret(SecretId=name)
    except client.exceptions.ResourceNotFoundException:
        return None, None, {}
    arn = description.get("ARN", "")
    require(re.fullmatch(rf"arn:aws:secretsmanager:{REGION}:{ACCOUNT}:secret:{re.escape(name)}-[A-Za-z0-9]{{6}}", arn),
            "Secret ARN does not match the approved account, region and channel.")
    require(not description.get("DeletedDate"), "The signing secret is pending deletion.")
    try:
        value = client.get_secret_value(SecretId=arn, VersionStage="AWSCURRENT")
    except client.exceptions.ResourceNotFoundException:
        raise ProvisionError("Existing secret has no current version; repair it explicitly before provisioning.") from None
    try:
        document = json.loads(value["SecretString"])
    except Exception:
        raise ProvisionError("Existing signing secret is not a valid JSON document.") from None
    require(isinstance(document, dict), "Existing signing secret must be an object.")
    require(value.get("VersionId"), "Existing signing secret lacks a version identifier.")
    return arn, value["VersionId"], document


def already_provisioned(document: dict) -> bool:
    present = CERT_FIELDS & document.keys()
    if not present:
        return False
    require(present == CERT_FIELDS, "Existing certificate fields are incomplete; refusing to overwrite them.")
    require(document["developer_id_identity"] == IDENTITY, "A different signing identity is already configured.")
    try:
        payload = base64.b64decode(document["developer_id_p12"], validate=True)
    except Exception:
        raise ProvisionError("Existing encrypted identity is invalid.") from None
    validate_pkcs12(payload, document["p12_password"])
    return True


def provision(client, channel: str, *, apply: bool, exporter) -> dict:
    """AWS writes are explicit; tests inject fake clients and in-memory identities."""
    arn, previous, document = read_current(client, channel)
    existing = already_provisioned(document)
    result = {"status": "unchanged" if existing else "planned", "secretName": secret_name(channel),
              "certificateSha256": CERT_SHA256, "missingReleaseFields": missing_fields(document)}
    if arn:
        result["secretArn"] = arn
    if existing or not apply:
        return result
    password = secrets.token_urlsafe(48)
    encrypted = protect_export(exporter(password), password)
    updated = {**document, "developer_id_p12": base64.b64encode(encrypted).decode(),
               "p12_password": password, "developer_id_identity": IDENTITY,
               "developer_id_certificate_sha256": CERT_SHA256}
    serialized = json.dumps(updated, sort_keys=True, separators=(",", ":"))
    require(len(serialized.encode()) <= 65536, "Signing secret exceeds the AWS size limit.")
    # Recheck after the Keychain prompt; do not merge a stale JSON snapshot.
    latest_arn, latest_version, _ = read_current(client, channel)
    require((arn, previous) == (latest_arn, latest_version),
            "Signing secret changed concurrently; no update was written. Inspect and retry.")
    token = str(uuid.uuid4())
    if arn is None:
        # Atomic creation refuses a concurrent creator. The SDK retries use the
        # same ClientRequestToken, never a newly generated payload/token pair.
        response = client.create_secret(Name=secret_name(channel), ClientRequestToken=token,
                                        SecretString=serialized,
                                        Description="Mokaid desktop macOS signing; private values managed outside Terraform",
                                        Tags=[{"Key": "Project", "Value": "mokaid"},
                                              {"Key": "Component", "Value": "desktop-signing"},
                                              {"Key": "Channel", "Value": channel}])
        arn = response["ARN"]
    else:
        # Never move AWSCURRENT implicitly in PutSecretValue: promotion includes
        # the expected old version, so a concurrent update fails instead of losing
        # newly added notarization/update credentials. A failed promotion leaves
        # only an encrypted, non-current pending version for operator recovery.
        pending = "mokaid-provision-" + token
        client.put_secret_value(SecretId=arn, ClientRequestToken=token,
                                SecretString=serialized, VersionStages=[pending])
        client.update_secret_version_stage(SecretId=arn, VersionStage="AWSCURRENT",
                                           MoveToVersionId=token, RemoveFromVersionId=previous)
        client.update_secret_version_stage(SecretId=arn, VersionStage=pending, RemoveFromVersionId=token)
    verified_arn, verified_version, verified_document = read_current(client, channel)
    require(verified_arn == arn and verified_version == token and already_provisioned(verified_document) and
            verified_document.get("developer_id_certificate_sha256") == CERT_SHA256,
            "Written signing secret was not verified as current; inspect version metadata before retrying.")
    result.update(status="provisioned", secretArn=arn,
                  missingReleaseFields=missing_fields(updated))
    return result


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--channel", choices=("stable", "beta"), required=True)
    parser.add_argument("--profile", default="mokaid")
    parser.add_argument("--apply", action="store_true", help="Explicitly export the single identity and write its encrypted secret after approval")
    args = parser.parse_args(argv)
    try:
        import resource
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        # SDK debug logs can include request bodies; never enable them here.
        logging.disable(logging.CRITICAL)
        import boto3
        from botocore.config import Config
        session = boto3.Session(profile_name=args.profile, region_name=REGION)
        settings = Config(connect_timeout=10, read_timeout=30, retries={"mode": "standard", "max_attempts": 3})
        sts = session.client("sts", config=settings)
        client = session.client("secretsmanager", config=settings)
        require(sts.meta.endpoint_url == f"https://sts.{REGION}.amazonaws.com" and
                client.meta.endpoint_url == f"https://secretsmanager.{REGION}.amazonaws.com",
                "Custom AWS endpoints are not permitted for signing credentials.")
        require(sts.get_caller_identity()["Account"] == ACCOUNT, "AWS account does not match the approved account.")
        with tempfile.TemporaryDirectory(prefix="mokaid-identity-helper-") as folder:
            helper = build_helper(Path(folder))
            inspect_identity(helper)
            result = provision(client, args.channel, apply=args.apply,
                               exporter=lambda password: helper_call(helper, "export",
                                   {"certificate_sha256": CERT_SHA256, "passphrase": password}))
        print(json.dumps(result, sort_keys=True)) # Public metadata/field names only.
        return 0
    except ProvisionError as failure:
        print(f"Provisioning blocked: {failure}", file=sys.stderr)
    except Exception:
        # Never stringify SDK errors, exceptions, captured helper output or inputs.
        print("Provisioning failed; secret values are suppressed. Inspect version metadata before retrying an uncertain write.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
