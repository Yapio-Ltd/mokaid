#!/usr/bin/env python3
"""Owner-invoked real Developer ID import/signing probe, never a release.

Default is a network-free plan. --run reads only the approved stable AWS secret,
signs a tiny locally compiled program in an ephemeral keychain, verifies it and
removes all disposable files. It never submits notarization or uses timestamps.
"""

from __future__ import annotations

import argparse
import asyncio
from collections.abc import Callable
import importlib
import json
import logging
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
from typing import Any, Protocol, cast

from cryptography import x509
from cryptography.hazmat.primitives import hashes
from cryptography.x509.oid import NameOID

import provision_release_credentials as credentials

TEAM = "4KH7528725"
SHA1 = "cc0832274b40ae88af44a9ab414c92554ded5a01"
IDENTIFIER = "com.mokaid.desktop.signing-probe"
SOURCE = (
    b'#include <stdio.h>\nint main(void) { puts("Mokaid signing probe"); return 0; }\n'
)
REQUIREMENT = (
    'anchor apple generic and certificate leaf[subject.OU] = "4KH7528725" '
    "and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
)
Command = Callable[..., subprocess.CompletedProcess[bytes]]


class ReleaseBoundary(Protocol):
    """Use the production CI importer without invoking its release workflow."""

    def create_signing_keychain(
        self, directory: Path, secret: dict[str, str]
    ) -> tuple[Path, str]: ...


def command(
    args: list[str], *, phase: str, payload: bytes | None = None
) -> subprocess.CompletedProcess[bytes]:
    """Capture all child output; only a fixed step label can reach the operator."""
    environment = {k: os.environ[k] for k in ("HOME", "TMPDIR") if k in os.environ}
    environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    try:
        result = subprocess.run(
            args,
            input=payload,
            capture_output=True,
            check=False,
            timeout=120,
            env=environment,
        )
    except (OSError, subprocess.SubprocessError):
        raise credentials.CredentialError(
            f"Signing probe step failed: {phase}."
        ) from None
    credentials.require(result.returncode == 0, f"Signing probe step failed: {phase}.")
    return result


def run_probe(
    secret: dict[str, Any], importer: ReleaseBoundary, runner: Command = command
) -> dict[str, object]:
    """Sign only our known fixture, pin its certificate and verify safe cleanup.

    Args:
        secret: Approved stable secret, read and validated in process memory.
        importer: The unchanged production release keychain importer.
        runner: Capturing command boundary, replaceable only by unit tests.

    Returns:
        Public evidence only, after keychain removal and search-list comparison.
    """
    credentials.require(platform.system() == "Darwin", "This probe requires macOS.")
    credentials.validate_certificate(secret)
    identity_fields = {
        name: cast(str, secret[name])
        for name in (
            "developer_id_p12",
            "p12_password",
            "developer_id_identity",
            "developer_id_certificate_sha256",
        )
    }
    search = ["/usr/bin/security", "list-keychains", "-d", "user"]
    original = runner(search, phase="read original search list").stdout
    with tempfile.TemporaryDirectory(prefix="mokaid-real-signing-probe-") as temporary:
        directory = Path(temporary)
        binary = directory / "Mokaid-signing-probe"
        keychain = directory / "signing.keychain-db"
        try:
            runner(
                [
                    "/usr/bin/xcrun",
                    "clang",
                    "-x",
                    "c",
                    "-",
                    "-o",
                    str(binary),
                    "-Wall",
                    "-Wextra",
                    "-Werror",
                    "-mmacosx-version-min=13.0",
                ],
                phase="compile harmless fixture",
                payload=SOURCE,
            )
            imported, identity = importer.create_signing_keychain(
                directory, identity_fields
            )
            credentials.require(
                imported == keychain and identity == SHA1,
                "Imported identity or keychain path differs from the approved probe.",
            )
            credentials.require(
                runner(search, phase="check importer restored search list").stdout
                == original,
                "Importer did not restore the original keychain search list.",
            )
            runner(
                [
                    "/usr/bin/codesign",
                    "--force",
                    "--timestamp=none",
                    "--options",
                    "runtime",
                    "--identifier",
                    IDENTIFIER,
                    "--sign",
                    identity,
                    "--keychain",
                    str(keychain),
                    str(binary),
                ],
                phase="sign with imported Developer ID",
            )
            runner(
                [
                    "/usr/bin/codesign",
                    "--verify",
                    "--strict",
                    "-R=" + REQUIREMENT,
                    str(binary),
                ],
                phase="verify strict Apple Developer ID requirement",
            )
            shown = runner(
                ["/usr/bin/codesign", "--display", "--verbose=4", str(binary)],
                phase="inspect public signing metadata",
            )
            public_lines = shown.stderr.decode("utf-8", errors="strict").splitlines()
            credentials.require(
                f"TeamIdentifier={TEAM}" in public_lines
                and f"Identifier={IDENTIFIER}" in public_lines,
                "Signed binary team or identifier differs from the approved probe.",
            )
            prefix = directory / "public-certificate-"
            runner(
                [
                    "/usr/bin/codesign",
                    "--display",
                    "--extract-certificates=" + str(prefix),
                    str(binary),
                ],
                phase="extract public signing certificate",
            )
            leaf = x509.load_der_x509_certificate(Path(str(prefix) + "0").read_bytes())
            units = leaf.subject.get_attributes_for_oid(
                NameOID.ORGANIZATIONAL_UNIT_NAME
            )
            credentials.require(
                leaf.fingerprint(hashes.SHA256()).hex() == credentials.CERT_SHA256
                and len(units) == 1
                and units[0].value == TEAM,
                "Signed binary does not contain the exact approved certificate.",
            )
            output = runner([str(binary)], phase="run harmless signed fixture")
            credentials.require(
                output.stdout == b"Mokaid signing probe\n", "Unexpected fixture output."
            )
        finally:
            if keychain.exists():
                runner(
                    ["/usr/bin/security", "delete-keychain", str(keychain)],
                    phase="delete temporary keychain",
                )
            credentials.require(
                not keychain.exists(), "Temporary keychain cleanup was not verified."
            )
            credentials.require(
                runner(search, phase="verify final search list").stdout == original,
                "Final keychain search list changed; inspect before retrying.",
            )
    return {
        "status": "verified",
        "secretArn": credentials.SECRET_ARN,
        "certificateSha256": credentials.CERT_SHA256,
        "teamIdentifier": TEAM,
        "signatureVerified": True,
        "appleDeveloperIdRequirementVerified": True,
        "timestamped": False,
        "notarized": False,
        "releasePublished": False,
        "temporaryKeychainRemoved": True,
        "keychainSearchListUnchanged": True,
    }


async def execute(profile: str, *, run: bool) -> dict[str, object]:
    """Keep private AWS access and execution behind an explicit operator flag."""
    if not run:
        return {
            "status": "planned",
            "secretArn": credentials.SECRET_ARN,
            "networkContacted": False,
            "keychainCreated": False,
            "binarySigned": False,
        }
    credentials.require(platform.system() == "Darwin", "This probe requires macOS.")
    client = await asyncio.to_thread(credentials.aws_client, profile)
    snapshot = await asyncio.to_thread(credentials.read_current, client)
    module = importlib.import_module("release")
    credentials.require(
        Path(module.__file__ or "").resolve()
        == Path(__file__).resolve().with_name("release.py"),
        "Only the reviewed local release importer is allowed.",
    )
    return await asyncio.to_thread(
        run_probe, snapshot.document, cast(ReleaseBoundary, module)
    )


def main(argv: list[str] | None = None) -> int:
    """Print only public evidence or fixed errors; suppress debug logs and dumps."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", default="mokaid")
    parser.add_argument("--run", action="store_true")
    args = parser.parse_args(argv)
    try:
        import resource

        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        logging.disable(logging.CRITICAL)
        print(
            json.dumps(asyncio.run(execute(args.profile, run=args.run)), sort_keys=True)
        )
        return 0
    except credentials.CredentialError as error:
        print(str(error), file=sys.stderr)
    except (Exception, KeyboardInterrupt):
        print(
            "Signing probe failed; private details are not logged. Check temporary-keychain cleanup before retrying.",
            file=sys.stderr,
        )
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
