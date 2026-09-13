#!/usr/bin/env python3
"""Explicit, stable-only operator import; the default checks metadata only.

Never run from CI. No key is created or read, and no cloud service is contacted,
without --apply. Private values stay in memory except a temporary 0600 file
required by Apple's notarytool. This tool never submits a release.
"""

from __future__ import annotations

import argparse
import asyncio
import base64
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from datetime import datetime, timezone
import importlib
import json
import logging
import os
from pathlib import Path
import platform
import re
import stat
import sys
import tempfile
from typing import Any, Protocol, cast
import uuid

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, ed25519
from cryptography.hazmat.primitives.serialization import pkcs12
from cryptography.x509.oid import NameOID

ACCOUNT = "660601648321"
REGION = "il-central-1"
SECRET_ARN = (
    f"arn:aws:secretsmanager:{REGION}:{ACCOUNT}:secret:"
    "mokaid/desktop/stable/macos-signing-8pPQkT"
)
ISSUER = "0f85a409-d9b6-48e8-a7fd-bca7c471b9de"
IDENTITY = "Developer ID Application: Yapio (4KH7528725)"
CERT_SHA256 = "c38e12abd12b6c4ab0904f096f036e63596a25527de6123d4d7a2778420ece46"
NOTARY_FIELDS = frozenset({"notary_key_p8", "notary_key_id", "notary_issuer"})
SEED_FIELD = "update_ed25519_seed"
MAX_KEY_BYTES = 16384
Document = dict[str, Any]


class CredentialError(Exception):
    """Fixed, non-sensitive operator message; never wrap remote error text."""


def require(condition: object, message: str) -> None:
    """Fail closed without including the inspected value in an exception."""
    if not condition:
        raise CredentialError(message)


class SecretsClient(Protocol):
    """Only the existing-secret operations required for conditional promotion."""

    def describe_secret(self, **kwargs: object) -> Document: ...
    def get_secret_value(self, **kwargs: object) -> Document: ...
    def put_secret_value(self, **kwargs: object) -> Document: ...
    def update_secret_version_stage(self, **kwargs: object) -> Document: ...


@dataclass(frozen=True, repr=False)
class Snapshot:
    """Sensitive versioned document; its repr deliberately contains no fields."""

    version: str
    document: Document


def inspect_key_path(path: Path) -> os.stat_result:
    """Check only metadata, not contents, of the owner's single private file.

    Args:
        path: Explicit absolute user-supplied .p8 path.

    Returns:
        Metadata used to detect replacement between validation and reading.
    """
    require(path.is_absolute() and path.suffix == ".p8", "Use an absolute .p8 path.")
    metadata = path.lstat()
    require(
        stat.S_ISREG(metadata.st_mode)
        and metadata.st_uid == os.getuid()
        and stat.S_IMODE(metadata.st_mode) == 0o600
        and metadata.st_nlink == 1,
        "Key must be an owned, regular, single-link 0600 file, not a symlink.",
    )
    require(
        64 <= metadata.st_size <= MAX_KEY_BYTES, "Unexpected private-key file size."
    )
    return metadata


def file_identity(metadata: os.stat_result) -> tuple[int, ...]:
    """Compare identity and content metadata without read-induced access time."""
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_uid,
        metadata.st_nlink,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def read_key(path: Path) -> bytes:
    """Read a non-replaced private file and validate unencrypted P-256 PKCS8."""
    before = inspect_key_path(path)
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        opened = os.fstat(stream.fileno())
        require(
            file_identity(opened) == file_identity(before),
            "Private-key file changed; inspect and retry.",
        )
        payload = stream.read(MAX_KEY_BYTES + 1)
        require(
            file_identity(os.fstat(stream.fileno())) == file_identity(opened),
            "Private-key file changed during reading.",
        )
    require(
        len(payload) <= MAX_KEY_BYTES
        and re.fullmatch(
            rb"-----BEGIN PRIVATE KEY-----\r?\n[A-Za-z0-9+/=\r\n]+"
            rb"-----END PRIVATE KEY-----\r?\n?",
            payload,
        ),
        "Expected one unencrypted PKCS8 PEM key, without additional content.",
    )
    try:
        key = serialization.load_pem_private_key(payload, password=None)
    except (ValueError, TypeError):
        raise CredentialError("Private-key parsing failed.") from None
    require(
        isinstance(key, ec.EllipticCurvePrivateKey)
        and isinstance(key.curve, ec.SECP256R1),
        "Notarization requires the approved P-256 API key.",
    )
    return payload


def validate_certificate(document: Document) -> None:
    """Verify the already-provisioned exact identity; never export or replace it."""
    require(
        document.get("developer_id_identity") == IDENTITY
        and document.get("developer_id_certificate_sha256") == CERT_SHA256,
        "The approved certificate must already be provisioned in this secret.",
    )
    try:
        payload = base64.b64decode(document["developer_id_p12"], validate=True)
        password = document["p12_password"]
        require(
            isinstance(password, str) and len(password) >= 32,
            "Invalid certificate password.",
        )
        require(0 < len(payload) <= 49152, "Invalid encrypted certificate size.")
        key, certificate, _ = pkcs12.load_key_and_certificates(
            payload, password.encode()
        )
    except Exception:
        raise CredentialError(
            "Existing encrypted identity validation failed."
        ) from None
    require(
        key is not None and certificate is not None, "Existing identity is incomplete."
    )
    assert key is not None and certificate is not None
    names = certificate.subject.get_attributes_for_oid(NameOID.COMMON_NAME)
    now = datetime.now(timezone.utc)
    require(
        certificate.fingerprint(hashes.SHA256()).hex() == CERT_SHA256
        and len(names) == 1
        and names[0].value == IDENTITY
        and certificate.not_valid_before_utc <= now < certificate.not_valid_after_utc
        and key.public_key().public_bytes(
            serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo
        )
        == certificate.public_key().public_bytes(
            serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo
        ),
        "Existing identity does not match the valid approved certificate.",
    )


def read_current(client: SecretsClient) -> Snapshot:
    """Read only the pinned existing ARN and its current immutable version."""
    description = client.describe_secret(SecretId=SECRET_ARN)
    require(
        description.get("ARN") == SECRET_ARN and not description.get("DeletedDate"),
        "Stable signing secret is missing, mismatched or pending deletion.",
    )
    value = client.get_secret_value(SecretId=SECRET_ARN, VersionStage="AWSCURRENT")
    require(value.get("ARN") == SECRET_ARN, "Secret value ARN does not match.")
    try:
        document = json.loads(value["SecretString"])
    except Exception:
        raise CredentialError("Signing secret is not valid JSON.") from None
    require(isinstance(document, dict), "Signing secret must be a JSON object.")
    version = value.get("VersionId")
    require(isinstance(version, str) and version, "Current secret version is missing.")
    validate_certificate(document)
    return Snapshot(cast(str, version), document)


def promote(client: SecretsClient, before: Snapshot, updated: Document) -> None:
    """Preserve every prior field and CAS AWSCURRENT, then verify exact contents.

    A failed CAS can leave an encrypted, non-current pending version. Never
    retry with a new payload or move a different current version automatically.
    """
    require(
        all(k in updated and updated[k] == v for k, v in before.document.items()),
        "Existing values cannot be overwritten.",
    )
    serialized = json.dumps(
        updated, sort_keys=True, separators=(",", ":"), allow_nan=False
    )
    require(
        len(serialized.encode()) <= 65536, "Updated secret exceeds the AWS size limit."
    )
    latest = read_current(client)
    require(
        latest.version == before.version and latest.document == before.document,
        "Secret changed concurrently; no update was written. Inspect and retry.",
    )
    token = str(uuid.uuid4())
    pending = "mokaid-credentials-" + token
    response = client.put_secret_value(
        SecretId=SECRET_ARN,
        ClientRequestToken=token,
        SecretString=serialized,
        VersionStages=[pending],
    )
    require(
        response.get("ARN") == SECRET_ARN and response.get("VersionId") == token,
        "Pending secret version was not verified.",
    )
    client.update_secret_version_stage(
        SecretId=SECRET_ARN,
        VersionStage="AWSCURRENT",
        MoveToVersionId=token,
        RemoveFromVersionId=before.version,
    )
    client.update_secret_version_stage(
        SecretId=SECRET_ARN,
        VersionStage=pending,
        RemoveFromVersionId=token,
    )
    current = read_current(client)
    require(
        current.version == token and current.document == updated,
        "Written version was not verified as current; inspect version metadata before retrying.",
    )


async def validate_notary(payload: bytes, key_id: str) -> None:
    """Run only read-only history, discard all output and remove the temporary key."""
    require(
        platform.system() == "Darwin", "Notary validation requires trusted macOS tools."
    )
    environment = {k: os.environ[k] for k in ("HOME", "TMPDIR") if k in os.environ}
    environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    with tempfile.TemporaryDirectory(prefix="mokaid-notary-auth-") as directory:
        path = Path(directory) / "AuthKey.p8"
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(payload)
        process = await asyncio.create_subprocess_exec(
            "/usr/bin/xcrun",
            "notarytool",
            "history",
            "--key",
            str(path),
            "--key-id",
            key_id,
            "--issuer",
            ISSUER,
            "--output-format",
            "json",
            "--no-progress",
            stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
            env=environment,
        )
        try:
            code = await asyncio.wait_for(process.wait(), timeout=120)
        except (TimeoutError, asyncio.CancelledError):
            if process.returncode is None:
                process.kill()
            await process.wait()
            raise CredentialError(
                "Notary authentication timed out or was cancelled; nothing was uploaded."
            ) from None
        require(
            code == 0,
            "Notary authentication failed; no upload or secret update was performed.",
        )


def update_public_key(seed: object) -> str:
    """Validate a canonical base64 seed and return only its public counterpart."""
    try:
        require(
            isinstance(seed, str), "Invalid existing update key; refusing replacement."
        )
        raw = base64.b64decode(cast(str, seed), validate=True)
        require(
            len(raw) == 32 and base64.b64encode(raw).decode() == seed,
            "Invalid existing update key; refusing replacement.",
        )
        key = ed25519.Ed25519PrivateKey.from_private_bytes(raw)
        return base64.b64encode(key.public_key().public_bytes_raw()).decode()
    except Exception:
        raise CredentialError(
            "Invalid existing update key; refusing replacement."
        ) from None


async def apply_notary(
    client: SecretsClient,
    path: Path,
    key_id: str,
    validator: Callable[[bytes, str], Awaitable[None]] = validate_notary,
) -> Document:
    """Import the exact approved P8 only after successful Apple authentication."""
    before = await asyncio.to_thread(read_current, client)
    payload = await asyncio.to_thread(read_key, path)
    values = {
        "notary_key_p8": payload.decode("ascii"),
        "notary_key_id": key_id,
        "notary_issuer": ISSUER,
    }
    present = NOTARY_FIELDS.intersection(before.document)
    require(
        not present
        or (
            present == NOTARY_FIELDS
            and all(before.document[k] == v for k, v in values.items())
        ),
        "Different or partial notarization credentials already exist; refusing overwrite.",
    )
    await validator(payload, key_id)
    if not present:
        await asyncio.to_thread(promote, client, before, {**before.document, **values})
    else:
        current = await asyncio.to_thread(read_current, client)
        require(
            current == before,
            "Secret changed during authentication; inspect and retry.",
        )
    return {
        "status": "unchanged" if present else "provisioned",
        "secretArn": SECRET_ARN,
        "keyId": key_id,
        "issuer": ISSUER,
        "notaryHistoryAuthenticated": True,
        "releaseUploaded": False,
    }


async def apply_update_key(client: SecretsClient) -> Document:
    """Generate a seed only when absent; idempotently expose only the public key."""
    before = await asyncio.to_thread(read_current, client)
    present = SEED_FIELD in before.document
    seed = before.document.get(SEED_FIELD)
    if not present:
        seed = base64.b64encode(
            ed25519.Ed25519PrivateKey.generate().private_bytes_raw()
        ).decode()
    public = update_public_key(seed)
    if not present:
        await asyncio.to_thread(
            promote, client, before, {**before.document, SEED_FIELD: seed}
        )
    else:
        current = await asyncio.to_thread(read_current, client)
        require(
            current == before,
            "Secret changed while reading its update key; inspect and retry.",
        )
    return {
        "status": "unchanged" if present else "provisioned",
        "secretArn": SECRET_ARN,
        "channel": "stable",
        "updatePublicKey": public,
    }


def aws_client(profile: str) -> SecretsClient:
    """Allow only the approved account and official regional AWS endpoints."""
    boto3 = importlib.import_module("boto3")
    config = importlib.import_module("botocore.config").Config(
        connect_timeout=10,
        read_timeout=30,
        retries={"mode": "standard", "max_attempts": 3},
    )
    session = boto3.Session(profile_name=profile, region_name=REGION)
    sts = session.client("sts", config=config)
    client = session.client("secretsmanager", config=config)
    require(
        sts.meta.endpoint_url == f"https://sts.{REGION}.amazonaws.com"
        and client.meta.endpoint_url
        == f"https://secretsmanager.{REGION}.amazonaws.com",
        "Custom AWS endpoints are not permitted.",
    )
    require(
        sts.get_caller_identity().get("Account") == ACCOUNT,
        "AWS account is not approved.",
    )
    return cast(SecretsClient, client)


async def execute(args: argparse.Namespace) -> Document:
    """Keep metadata planning entirely outside credential and network operations."""
    if args.action == "notary":
        require(
            re.fullmatch(r"[A-Z0-9]{10,64}", args.key_id)
            and args.key_path.name == f"AuthKey_{args.key_id}.p8"
            and args.issuer == ISSUER,
            "Use the designated AuthKey_<ID>.p8 file, its explicit key ID and the approved Team issuer.",
        )
        await asyncio.to_thread(inspect_key_path, args.key_path)
        if args.verify_notary:
            payload = await asyncio.to_thread(read_key, args.key_path)
            await validate_notary(payload, args.key_id)
            return {
                "status": "authenticated",
                "keyId": args.key_id,
                "issuer": ISSUER,
                "notaryHistoryAuthenticated": True,
                "awsContacted": False,
                "releaseUploaded": False,
            }
    if not args.apply:
        return {
            "status": "metadata-validated",
            "action": args.action,
            "secretArn": SECRET_ARN,
            "privateKeyRead": False,
            "networkContacted": False,
            "credentialsGenerated": False,
        }
    client = await asyncio.to_thread(aws_client, args.profile)
    if args.action == "notary":
        return await apply_notary(client, args.key_path, args.key_id)
    return await apply_update_key(client)


def main(argv: list[str] | None = None) -> int:
    """Parse public metadata and emit only an allowlisted result or fixed error."""
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest="action", required=True)
    notary = actions.add_parser("notary", help="Import the owner's approved Team key")
    notary.add_argument("--key-path", type=Path, required=True)
    notary.add_argument("--key-id", required=True)
    notary.add_argument("--issuer", required=True)
    update = actions.add_parser(
        "generate-update-key", help="Create stable Ed25519 seed only if absent"
    )
    for command in (notary, update):
        command.add_argument("--profile", default="mokaid")
        modes = command.add_mutually_exclusive_group()
        modes.add_argument("--apply", action="store_true")
        if command is notary:
            modes.add_argument(
                "--verify-notary",
                action="store_true",
                help="Read the designated P8 and check Apple history only; never contact AWS",
            )
    args = parser.parse_args(argv)
    try:
        import resource

        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        logging.disable(logging.CRITICAL)
        print(json.dumps(asyncio.run(execute(args)), sort_keys=True))
        return 0
    except CredentialError as error:
        print(f"Credential provisioning refused: {error}", file=sys.stderr)
    except (Exception, KeyboardInterrupt):
        print(
            "Credential operation failed; no details are logged. Inspect AWS version metadata before retrying.",
            file=sys.stderr,
        )
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
