#!/usr/bin/env python3
"""Private GitHub OIDC package proof, never a release or an acceptance record.

Only the explicit ``sign --execute`` command may read the approved signing secret
or submit the ephemeral application to Apple. No command publishes artifacts.
"""

from __future__ import annotations

import argparse
import asyncio
import base64
from collections.abc import Callable
import hashlib
import importlib
import importlib.util
import json
import logging
import os
from pathlib import Path
import platform
import plistlib
import re
import signal
import subprocess
import sys
import tempfile
from typing import Any, Protocol, cast

from cryptography import x509
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

import provision_release_credentials as credentials
import stage_archive

REPOSITORY = "Yapio-Ltd/mokaid"
WORKFLOW = ".github/workflows/desktop-macos-signing-probe.yml"
PURPOSE = "private-macos-signing-probe"
HERE = Path(__file__).resolve().parent
TEAM = "4KH7528725"
ROLE = "mokaid-desktop-signing-stable"
REQUIREMENT = (
    'anchor apple generic and certificate leaf[subject.OU] = "4KH7528725" '
    "and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
)
FRAMEWORKS = (
    "QtCore",
    "QtGui",
    "QtQml",
    "QtQuick",
    "QtNetwork",
    "QtWebEngineCore",
    "QtWebEngineQuick",
    "QtTaskTree",
    "Sparkle",
)
MACHO_MAGIC = {
    b"\xcf\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf",
    b"\xca\xfe\xba\xbe",
    b"\xca\xfe\xba\xbf",
}


class ProbeError(Exception):
    """A fixed non-sensitive refusal; remote error bodies must never be printed."""


def require(condition: object, message: str) -> None:
    """Fail without embedding inspected values in an error message."""
    if not condition:
        raise ProbeError(message)


def context(version: str) -> dict[str, Any]:
    """Bind a manual probe to one explicitly reviewed main commit and workflow."""
    required = {
        "GITHUB_ACTIONS": "true",
        "GITHUB_EVENT_NAME": "workflow_dispatch",
        "GITHUB_REPOSITORY": REPOSITORY,
        "GITHUB_REF": "refs/heads/main",
        "GITHUB_WORKFLOW_REF": f"{REPOSITORY}/{WORKFLOW}@refs/heads/main",
        "RUNNER_ENVIRONMENT": "github-hosted",
    }
    require(
        all(os.environ.get(k) == v for k, v in required.items()),
        "Probe requires its reviewed workflow on main and a hosted runner.",
    )
    sha = os.environ.get("GITHUB_SHA", "")
    require(
        re.fullmatch(r"[0-9a-f]{40}", sha)
        and sha
        == os.environ.get("PROBE_SOURCE_SHA")
        == os.environ.get("GITHUB_WORKFLOW_SHA"),
        "Source, workflow and explicitly approved commit must match.",
    )
    require(
        re.fullmatch(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", version),
        "Probe requires a stable numeric version, without creating a release tag.",
    )
    run_id, attempt = os.environ.get("GITHUB_RUN_ID", ""), os.environ.get(
        "GITHUB_RUN_ATTEMPT", ""
    )
    require(
        re.fullmatch(r"[1-9]\d{0,19}", run_id)
        and re.fullmatch(r"[1-9]\d{0,9}", attempt),
        "Invalid probe run identity.",
    )
    return {
        "schema": "com.mokaid.private-signing-probe",
        "schemaVersion": 1,
        "purpose": PURPOSE,
        "sourceCommit": sha,
        "toolingCommit": sha,
        "runId": run_id,
        "runAttempt": attempt,
        "version": version,
        "channel": "stable",
        "platform": "macos-arm64",
    }


class Packager(Protocol):
    """Reuse reviewed packaging without invoking publication/evidence functions."""

    run: Callable[..., str]

    def require_release_stage(self, stage: Path, target: str) -> None: ...
    def validate_assets(self, assets: Path) -> None: ...
    def check_secret(self, secret: dict[str, str], target: str) -> None: ...
    def package_macos(
        self, args: argparse.Namespace, secret: dict[str, str]
    ) -> Path: ...


def packaging_module() -> Packager:
    """Load an isolated copy of the reviewed tool, never code from the archive."""
    spec = importlib.util.spec_from_file_location(
        "mokaid_private_probe_packager", HERE / "release.py"
    )
    require(
        spec is not None and spec.loader is not None, "Reviewed packager unavailable."
    )
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return cast(Packager, module)


async def execute(
    argv: list[str], environment: dict[str, str], timeout: int
) -> tuple[int, bytes, bytes]:
    """Capture bounded command output and reap the whole child group on failure."""
    process = await asyncio.create_subprocess_exec(
        *argv,
        env=environment,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        start_new_session=True,
        limit=65536,
    )
    assert process.stdout is not None and process.stderr is not None
    total = 0

    async def drain(stream: asyncio.StreamReader) -> bytes:
        nonlocal total
        result = bytearray()
        while chunk := await stream.read(65536):
            total += len(chunk)
            require(total <= 4 * 1024**2, "Signing tool returned oversized output.")
            result.extend(chunk)
        return bytes(result)

    async def discard(stream: asyncio.StreamReader) -> None:
        # Only used AFTER killing the writer group: drain finite pipe buffers
        # without accumulating output so asyncio can close/reap its transports.
        while await stream.read(65536):
            pass

    readers = [
        asyncio.create_task(drain(process.stdout)),
        asyncio.create_task(drain(process.stderr)),
    ]
    complete = False
    try:
        async with asyncio.timeout(timeout):
            stdout, stderr = await asyncio.gather(*readers)
            code = await process.wait()
        complete = True
        return code, stdout, stderr
    except (TimeoutError, OSError):
        raise ProbeError(
            "Signing tool failed or timed out; no remote output retained."
        ) from None
    finally:
        if not complete:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            for reader in readers:
                reader.cancel()
            await asyncio.gather(*readers, return_exceptions=True)
            await asyncio.wait_for(
                asyncio.gather(
                    discard(process.stdout),
                    discard(process.stderr),
                    process.wait(),
                    return_exceptions=True,
                ),
                5,
            )


class CommandRunner:
    """System-tools-only boundary; never execute a staged binary or expose secrets."""

    def __init__(self) -> None:
        self.submissions: list[str] = []

    def __call__(self, *args: object, capture: bool = False, **kwargs: object) -> str:
        argv = [str(value) for value in args]
        allowed = {
            name: f"/usr/bin/{name}"
            for name in (
                "codesign",
                "xcrun",
                "security",
                "ditto",
                "hdiutil",
                "lipo",
                "otool",
            )
        }
        allowed["spctl"] = "/usr/sbin/spctl"
        require(
            bool(argv) and set(kwargs) <= {"stderr"}, "Unsupported signing command."
        )
        executable = Path(argv[0]).name
        require(
            executable in allowed and argv[0] in (executable, allowed[executable]),
            "The probe cannot execute artifact code or arbitrary tools.",
        )
        argv[0] = allowed[executable]
        environment = {
            key: os.environ[key]
            for key in ("HOME", "TMPDIR", "DEVELOPER_DIR")
            if key in os.environ
        }
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        submission = executable == "xcrun" and argv[1:3] == ["notarytool", "submit"]
        code, stdout, stderr = asyncio.run(
            execute(argv, environment, 1200 if submission else 180)
        )
        require(
            code == 0,
            "A signature/notarization verification step failed; raw output suppressed.",
        )
        if submission:
            try:
                value = json.loads(stdout)
                require(
                    value.get("status") == "Accepted"
                    and re.fullmatch(
                        r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}",
                        value.get("id", ""),
                    ),
                    "Apple did not confirm an accepted notarization submission.",
                )
            except (ValueError, TypeError, AttributeError):
                raise ProbeError(
                    "Apple returned invalid notarization metadata."
                ) from None
            self.submissions.append(value["id"])
        if capture:
            return (
                stdout + (stderr if kwargs.get("stderr") == subprocess.STDOUT else b"")
            ).decode("utf-8", errors="strict")
        return ""


def verify_checkout(identity: dict[str, Any]) -> None:
    """Fail if main moved before approval or checkout is not the exact reviewed SHA."""
    try:
        result = subprocess.run(
            ["/usr/bin/git", "rev-parse", "HEAD", "origin/main"],
            cwd=HERE,
            capture_output=True,
            check=True,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        raise ProbeError("Cannot verify reviewed checkout metadata.") from None
    require(
        result.stdout.splitlines() == [identity["sourceCommit"]] * 2,
        "Checkout and current main must equal the approved commit.",
    )


def restore_stage(args: argparse.Namespace, stage: Path) -> None:
    """Recheck all archive bytes/paths/links and exact provenance before any secret read."""
    identity = context(args.version)
    stage_archive.restore(
        argparse.Namespace(
            input=args.input,
            stage=stage,
            platform="macos-arm64",
            version=args.version,
            channel="stable",
            commit=identity["sourceCommit"],
            tooling_sha=identity["toolingCommit"],
            run_id=identity["runId"],
            run_attempt=identity["runAttempt"],
            manifest_sha256=args.manifest_sha256,
            public_key=os.environ.get("MOKAID_UPDATE_PUBLIC_KEY"),
            key_file=HERE / "update-public-keys.json",
        )
    )


def inspect_bundle(stage: Path, version: str, public_key: str) -> dict[str, Any]:
    """Check full production runtime presence and versions, never launch it."""
    packaging = packaging_module()
    packaging.require_release_stage(stage, "macos-arm64")
    app = stage / "Mokaid.app"
    with (app / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    require(
        info.get("CFBundleVersion") == version
        and info.get("CFBundleIdentifier") == "com.mokaid.desktop"
        and info.get("SUPublicEDKey") == public_key
        and info.get("CFBundleExecutable") == "Mokaid",
        "Bundle version, identity, executable or public key is incorrect.",
    )
    packaging.validate_assets(app / "Contents/Resources/assets")
    require(
        (app / "Contents/Resources/shaders/office.metallib").is_file(),
        "Native Metal shader is missing.",
    )
    require((app / "Contents/MacOS/Mokaid").is_file(), "Native executable is missing.")
    require(
        any(app.rglob("QtWebEngineProcess.app")), "WebEngine sandbox helper is missing."
    )
    require(
        any(app.rglob("Downloader.xpc")) and any(app.rglob("Installer.xpc")),
        "Sparkle service bundles are missing.",
    )
    dependencies = json.loads((HERE / "dependencies.json").read_text())
    for name in FRAMEWORKS:
        framework = app / "Contents/Frameworks" / f"{name}.framework"
        require((framework / name).is_file(), "Required native framework is missing.")
        with (framework / "Resources/Info.plist").open("rb") as source:
            metadata = plistlib.load(source)
        expected = (
            dependencies["sparkle"]["version"]
            if name == "Sparkle"
            else dependencies["qt"]
        )
        actual = (
            metadata.get("CFBundleShortVersionString")
            if name == "Sparkle"
            else metadata.get("CFBundleVersion")
        )
        require(
            actual == expected,
            "Framework version differs from reviewed dependency pins.",
        )
    return {
        "frameworks": list(FRAMEWORKS),
        "qtVersion": dependencies["qt"],
        "sparkleVersion": dependencies["sparkle"]["version"],
        "metalShaderPresent": True,
        "cookedAssetsVerified": True,
        "webEngineHelperPresent": True,
    }


def read_credentials() -> dict[str, str]:
    """Read only the existing stable secret using this job's exact assumed role."""
    require(
        os.environ.get("MOKAID_SIGNING_SECRET_ARN") == credentials.SECRET_ARN,
        "Only the approved stable Mac signing secret is allowed.",
    )
    require(
        os.environ.get("AWS_REGION") == credentials.REGION
        and all(
            os.environ.get(k)
            for k in ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN")
        ),
        "The protected job must first acquire its temporary OIDC credentials.",
    )
    require(
        os.environ.get("MOKAID_UPDATE_PUBLIC_KEY")
        == stage_archive.public_key("stable"),
        "Signing environment public key differs from reviewed source.",
    )
    # Explicit regional endpoints defeat inherited SDK endpoint overrides; the
    # SDK sees only the credentials just obtained by the protected OIDC step.
    boto3 = importlib.import_module("boto3")
    config_type = importlib.import_module("botocore.config").Config
    session = boto3.Session(
        aws_access_key_id=os.environ["AWS_ACCESS_KEY_ID"],
        aws_secret_access_key=os.environ["AWS_SECRET_ACCESS_KEY"],
        aws_session_token=os.environ["AWS_SESSION_TOKEN"],
        region_name=credentials.REGION,
    )
    config = config_type(
        connect_timeout=10, read_timeout=20, retries={"max_attempts": 1}
    )
    sts = session.client(
        "sts",
        endpoint_url=f"https://sts.{credentials.REGION}.amazonaws.com",
        config=config,
    )
    identity = sts.get_caller_identity()
    expected = f"arn:aws:sts::{credentials.ACCOUNT}:assumed-role/{ROLE}/desktop-probe-{os.environ['GITHUB_RUN_ID']}"
    require(
        identity.get("Account") == credentials.ACCOUNT
        and identity.get("Arn") == expected,
        "OIDC caller is not the approved stable signing-role session.",
    )
    client = session.client(
        "secretsmanager",
        endpoint_url=f"https://secretsmanager.{credentials.REGION}.amazonaws.com",
        config=config,
    )
    snapshot = credentials.read_current(client)
    document = snapshot.document
    require(
        document.get("notary_issuer") == credentials.ISSUER
        and re.fullmatch(r"[A-Z0-9]{10,12}", document.get("notary_key_id", "")),
        "Notarization credentials do not match the approved team.",
    )
    names = (
        "developer_id_p12",
        "p12_password",
        "developer_id_identity",
        "developer_id_certificate_sha256",
        "notary_key_p8",
        "notary_key_id",
        "notary_issuer",
        "update_ed25519_seed",
    )
    require(
        all(isinstance(document.get(k), str) and document[k] for k in names),
        "Signing credentials are incomplete.",
    )
    return {name: cast(str, document[name]) for name in names}


def verify_signed_bundle(
    stage: Path, artifact: Path, runner: CommandRunner, directory: Path
) -> None:
    """Independent strict verification of the same signed bytes, identity and ticket."""
    app = stage / "Mokaid.app"
    runner("codesign", "--verify", "--deep", "--strict", "-R=" + REQUIREMENT, app)
    runner("codesign", "--verify", "--strict", "-R=" + REQUIREMENT, artifact)
    runner("xcrun", "stapler", "validate", app)
    runner("xcrun", "stapler", "validate", artifact)
    prefix = directory / "public-certificate-"
    runner("codesign", "--display", "--extract-certificates=" + str(prefix), app)
    leaf = x509.load_der_x509_certificate(Path(str(prefix) + "0").read_bytes())
    require(
        leaf.fingerprint(hashes.SHA256()).hex() == credentials.CERT_SHA256,
        "Signed bundle does not contain the exact approved certificate.",
    )
    for path in app.rglob("*"):
        if not path.is_file() or path.is_symlink():
            continue
        with path.open("rb") as source:
            native = source.read(4) in MACHO_MAGIC
        if native:
            require(
                "arm64" in runner("lipo", "-archs", path, capture=True).split(),
                "A native component lacks Apple Silicon code.",
            )
            runner("codesign", "--verify", "--strict", "-R=" + REQUIREMENT, path)
            linked = runner(
                "otool", "-arch", "arm64", "-L", path, capture=True
            ).splitlines()[1:]
            require(
                all(
                    line.strip().startswith(
                        (
                            "@rpath/",
                            "@loader_path/",
                            "@executable_path/",
                            "/usr/lib/",
                            "/System/Library/",
                        )
                    )
                    for line in linked
                    if line.strip()
                ),
                "A component still links to the build host or an external SDK.",
            )


def sign(args: argparse.Namespace) -> dict[str, Any]:
    """Sign/notarize only explicit executions, delete all signed bytes before success."""
    result = {
        **context(args.version),
        "status": "planned",
        "published": False,
        "productExecuted": False,
        "acceptanceApproved": False,
    }
    if not args.execute:
        return result
    require(platform.system() == "Darwin", "Real signing requires a macOS runner.")
    verify_checkout(result)
    runner = CommandRunner()
    search_command = ("security", "list-keychains", "-d", "user")
    original = runner(*search_command, capture=True)
    try:
        with tempfile.TemporaryDirectory(
            prefix="mokaid-private-signing-probe-"
        ) as folder:
            directory = Path(folder)
            stage, output = directory / "stage", directory / "package"
            restore_stage(args, stage)
            runtime = inspect_bundle(
                stage, args.version, os.environ["MOKAID_UPDATE_PUBLIC_KEY"]
            )
            # Archive validation completes again before the first AWS read.
            secret = read_credentials()
            packaging = packaging_module()
            packaging.run = runner  # This module instance is private to the probe.
            packaging.check_secret(secret, "macos-arm64")
            output.mkdir(mode=0o700)
            artifact = packaging.package_macos(
                argparse.Namespace(
                    stage=stage,
                    output=output,
                    platform="macos-arm64",
                    version=args.version,
                    channel="stable",
                ),
                secret,
            )
            require(
                len(runner.submissions) == 2 and len(set(runner.submissions)) == 2,
                "Both application and DMG need independent accepted notarizations.",
            )
            verify_signed_bundle(stage, artifact, runner, directory)
            with artifact.open("rb") as stream:
                digest = hashlib.file_digest(stream, "sha256").hexdigest()
            key = Ed25519PrivateKey.from_private_bytes(
                base64.b64decode(secret["update_ed25519_seed"], validate=True)
            )
            proof = b"MOKAID-PRIVATE-SIGNING-PROBE\x00" + bytes.fromhex(digest)
            key.public_key().verify(key.sign(proof), proof)
            result.update(
                status="verified",
                artifactSha256=digest,
                artifactSize=artifact.stat().st_size,
                unsignedManifestSha256=args.manifest_sha256,
                notarizationSubmissionIds=runner.submissions,
                certificateSha256=credentials.CERT_SHA256,
                teamId=TEAM,
                updateKeyVerified=True,
                runtime=runtime,
                osSignatureVerified=True,
                stapled=True,
            )
            secret.clear()
        require(not directory.exists(), "Signed probe files were not removed.")
    except Exception:
        raise ProbeError(
            "Private signing probe failed; no raw credential or tool output retained."
        ) from None
    finally:
        require(
            runner(*search_command, capture=True) == original,
            "Temporary signer changed the keychain search list; operator inspection required.",
        )
    result["temporaryFilesRemoved"] = True
    return result


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    commands = result.add_subparsers(dest="command", required=True)
    for command in ("metadata", "verify-stage", "sign"):
        item = commands.add_parser(command)
        item.add_argument("--version", required=True)
        if command != "metadata":
            item.add_argument("--input", type=Path, required=True)
            item.add_argument("--manifest-sha256", required=True)
        if command == "sign":
            item.add_argument("--execute", action="store_true")
    return result


def main() -> int:
    logging.disable(logging.CRITICAL)
    os.umask(0o077)
    try:
        if os.name == "posix":
            import resource

            resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        args = parser().parse_args()
        result = context(args.version)
        verify_checkout(result)
        if args.command == "metadata":
            key = stage_archive.public_key("stable")
            with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
                output.write(
                    f"commit={result['sourceCommit']}\nversion={args.version}\npublic_key={key}\n"
                )
        elif args.command == "verify-stage":
            with tempfile.TemporaryDirectory(
                prefix="mokaid-probe-preflight-"
            ) as folder:
                stage = Path(folder) / "stage"
                restore_stage(args, stage)
                result["runtime"] = inspect_bundle(
                    stage, args.version, os.environ["MOKAID_UPDATE_PUBLIC_KEY"]
                )
            result["status"] = "unsigned-stage-verified"
        else:
            result = sign(args)
        # Only constructed, schema-separated public facts ever reach CI output.
        rendered = json.dumps(result, sort_keys=True)
        print(rendered)
        if os.environ.get("GITHUB_STEP_SUMMARY"):
            with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a") as output:
                output.write(
                    "\nPrivate macOS signing probe (not release acceptance):\n\n```json\n"
                    + rendered
                    + "\n```\n"
                )
        return 0
    except Exception:
        print(
            "Private signing probe refused or failed. No release was published; inspect the failed phase, not secret contents.",
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
