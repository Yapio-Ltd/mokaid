#!/usr/bin/env python3
"""Native desktop packaging and immutable release promotion.

This tool never prints secret values and runs child processes without a shell.
Publishing is an explicit subcommand, reserved for protected release workflows.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from datetime import datetime, timezone
from urllib.request import urlopen
from urllib.parse import urlparse
import xml.etree.ElementTree as ET
import zipfile

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
BASE_URL = "https://downloads.mokaid.com"
RELEASE_RE = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-beta\.([1-9]\d*))?$")
PLATFORMS = {"macos-arm64": (".dmg", "application/x-apple-diskimage", "13.0"),
             "windows-x64": (".exe", "application/octet-stream", "10.0.22000")}
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)
READINESS_CHECKS = frozenset({
    "client-17-screen-parity", "admin-15-screen-parity", "office-avatar-visual-parity",
    "auth-isolation-reconnection", "html-sandbox-recovery-accessibility",
    "macos-clean-install-signed-upgrade", "windows-clean-install-signed-upgrade",
    "update-failure-recovery", "mac-m1-8gb-performance", "intel-iris-xe-16gb-performance",
    "nvidia-performance", "dependency-and-asset-licenses",
})


def require(condition: object, message: str) -> None:
    if not condition:
        raise ValueError(message)


def run(*args: object, capture: bool = False, **kwargs: object) -> str:
    result = subprocess.run([str(a) for a in args], check=True, text=True,
                            stdout=subprocess.PIPE if capture else None, **kwargs)
    return result.stdout or ""


def sha256(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def check_version(value: str, channel: str) -> None:
    require(RELEASE_RE.fullmatch(value), "Version must be SemVer X.Y.Z or X.Y.Z-beta.N")
    require(("-beta." in value) == (channel == "beta"), "Version and build channel disagree")


def build_version(version: str) -> str:
    # CFBundleVersion supports the development suffix bN; stable builds retain
    # their three-component numeric version. Feeds use the exact bundle value.
    return version.replace("-beta.", "b")


def evidence_bytes(metadata: dict) -> bytes:
    signed_fields = {key: value for key, value in metadata.items() if key != "evidenceSignature"}
    return b"MOKAID-RELEASE-EVIDENCE\x00" + json.dumps(signed_fields, sort_keys=True, separators=(",", ":")).encode()


def required_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    require(value, f"Missing required release configuration: {name}")
    return value


def public_key() -> bytes:
    key = base64.b64decode(required_env("MOKAID_UPDATE_PUBLIC_KEY"), validate=True)
    require(len(key) == 32, "The update public key must decode to 32 bytes")
    return key


def signing_secret() -> dict[str, str]:
    # AWS credentials come from GitHub OIDC. Secret values never enter GITHUB_ENV,
    # step outputs, artifacts or persisted Terraform state.
    import boto3
    response = boto3.client("secretsmanager").get_secret_value(
        SecretId=required_env("MOKAID_SIGNING_SECRET_ARN"))
    secret = json.loads(response["SecretString"])
    require(isinstance(secret, dict), "Signing secret must contain a JSON object")
    return secret


def check_secret(secret: dict[str, str], target: str) -> None:
    names = ["update_ed25519_seed"]
    if target == "macos-arm64":
        names += ["developer_id_p12", "p12_password", "developer_id_identity", "developer_id_certificate_sha256",
                  "notary_key_p8", "notary_key_id", "notary_issuer"]
    for name in names:
        require(isinstance(secret.get(name), str) and secret[name], f"Signing secret is missing field: {name}")
    seed = base64.b64decode(secret["update_ed25519_seed"], validate=True)
    require(len(seed) == 32, "Update signing secret must be a base64 Ed25519 32-byte seed")
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
    derived = Ed25519PrivateKey.from_private_bytes(seed).public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    require(derived == public_key(), "Update signing secret does not match compiled public key")


def icons(output: Path) -> None:
    from PIL import Image
    output.mkdir(parents=True, exist_ok=True)
    with Image.open(REPO / "apps/web/public/branding/logo-with-bg.png") as source:
        rgba = source.convert("RGBA")
        require(rgba.width >= 1024 and rgba.width == rgba.height, "Logo must be square and at least 1024px")
        rgba.save(output / "Mokaid.ico", sizes=[(s, s) for s in (16, 20, 24, 32, 40, 48, 64, 128, 256)])
        rgba.resize((1024, 1024), Image.Resampling.LANCZOS).save(output / "Mokaid.icns")


def fetch_sdk(target: str, output: Path) -> None:
    key = "dxc" if target == "dxc" else "sparkle" if target == "macos-arm64" else "winsparkle"
    dependency = json.loads((HERE / "dependencies.json").read_text())[key]
    require(not output.exists(), "Updater SDK destination must not already exist")
    with tempfile.TemporaryDirectory(prefix="mokaid-sdk-") as folder:
        archive = Path(folder) / Path(dependency["url"]).name
        with urlopen(dependency["url"], timeout=120) as source, archive.open("wb") as destination:
            shutil.copyfileobj(source, destination)
        require(sha256(archive) == dependency["sha256"], "Updater SDK checksum mismatch")
        output.mkdir(parents=True, exist_ok=False)
        if archive.suffix == ".zip":
            with zipfile.ZipFile(archive) as bundle:
                for entry in bundle.infolist():
                    require((output / entry.filename).resolve().is_relative_to(output.resolve()), "Unsafe ZIP member")
                bundle.extractall(output)
            # WinSparkle releases include one top-level directory.
            if key == "dxc":
                require((output / "bin/x64/dxc.exe").is_file(), "Cannot locate DXC compiler")
                sdk_root = output
            else:
                candidates = list(output.rglob("winsparkle.h"))
                require(len(candidates) == 1, "Cannot locate WinSparkle SDK header")
                sdk_root = candidates[0].parent.parent
        else:
            with tarfile.open(archive) as bundle:
                bundle.extractall(output, filter="data")
            # The archive also contains a test app with its own embedded copy;
            # only the top-level distributable SDK is a valid build dependency.
            require((output / "Sparkle.framework").is_dir(), "Cannot locate top-level Sparkle framework")
            sdk_root = output
    print(sdk_root.resolve())


def validate_assets(assets: Path) -> None:
    required = {"office", "avatar_male", "avatar_female", "avatar_corporate", "avatar_developer",
                "avatar_design", "avatar_finance", "avatar_research", "avatar_legal",
                "avatar_byte", "avatar_nyx", "avatar_moss"}
    require(assets.is_dir(), "Cooked asset directory does not exist")
    manifest = json.loads((assets / "manifest.json").read_text())
    require(manifest.get("format") == 4, "Unsupported cooked asset format: recook with the current v4 cooker")
    records = manifest.get("assets", [])
    require({item.get("id") for item in records} == required and len(records) == len(required),
            "Cooked assets must include the office and every catalog avatar")
    for item in records:
        require(item.get("file") == f"{item['id']}.mokaidasset", "Unexpected cooked asset path")
        require(sha256(assets / item["file"]) == item.get("sha256"), f"Cooked asset checksum mismatch: {item['id']}")
    navigation = manifest.get("navigation", {})
    require(navigation.get("file") == "office.mokaidnav", "Office navigation is missing")
    require(sha256(assets / "office.mokaidnav") == navigation.get("sha256"), "Office navigation checksum mismatch")


def cmake_boolean(build: Path, name: str) -> bool:
    cache = (build / "CMakeCache.txt").read_text()
    match = re.search(rf"^{re.escape(name)}:BOOL=(ON|OFF)$", cache, re.MULTILINE)
    require(match, f"CMake build must declare {name} as ON or OFF")
    return match[1] == "ON"


def cmake_updates_enabled(build: Path) -> bool:
    return cmake_boolean(build, "MOKAID_ENABLE_UPDATES")


def copy_windows_crt(stage: Path, redist: Path) -> None:
    # App-local release CRTs keep per-user installation independent of an
    # elevated vc_redist installer. Windows 11 supplies the system UCRT itself.
    crt = redist / "x64/Microsoft.VC143.CRT"
    required = {"msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll"}
    dlls = sorted(crt.glob("*.dll"))
    require(required.issubset({path.name.lower() for path in dlls}),
            "VCToolsRedistDir must contain the release x64 Microsoft.VC143.CRT DLLs")
    # WebEngine's helper must resolve its CRT from its own executable directory,
    # even if a future Qt deployment relocates it below the main app directory.
    destinations = {stage, *(path.parent for path in stage.rglob("*.exe"))}
    for source in dlls:
        for destination in destinations:
            shutil.copy2(source, destination / source.name)


def deploy_macos_runtime(app: Path, qt_bin: Path, qml: Path) -> None:
    # Qt's default plugin sweep includes unrelated database/GPS drivers whose
    # dependencies live on the SDK builder's machine. Keep the app's native
    # plugin set explicit; the official QML scanner still deploys QML plugins.
    plugins = (
        "platforms/libqcocoa.dylib", "sqldrivers/libqsqlite.dylib",
        "imageformats/libqjpeg.dylib", "imageformats/libqgif.dylib",
        "imageformats/libqico.dylib", "imageformats/libqsvg.dylib",
        "iconengines/libqsvgicon.dylib", "tls/libqsecuretransportbackend.dylib",
        "networkinformation/libqapplenetworkinformation.dylib",
    )
    executables = []
    for relative in plugins:
        source = qt_bin.parent / "plugins" / relative
        require(source.is_file(), f"Required native Qt plugin is missing: {relative}")
        destination = app / "Contents/PlugIns" / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
        executables.append(f"-executable={destination}")
    output = run(qt_bin / "macdeployqt", app, f"-qmldir={qml.resolve()}",
                 "-always-overwrite", "-no-strip", "-no-plugins", *executables,
                 capture=True, stderr=subprocess.STDOUT)
    require(not re.search(r"^ERROR:", output, re.MULTILINE),
            "Qt runtime deployment reported errors despite its exit status:\n" + output)
    if output.strip():
        print(output)


def stage_runtime(args: argparse.Namespace) -> None:
    stage = args.stage.resolve()
    require(not stage.exists(), "Stage directory already exists; use a new staging directory")
    validate_assets(args.assets)
    updates = cmake_updates_enabled(args.build)
    development = cmake_boolean(args.build, "MOKAID_DEVELOPMENT")
    require(not (development and updates), "Development builds must disable release updates")
    require(not updates or args.sdk is not None, "Enabled updates require the verified updater SDK")
    run("cmake", "--install", args.build, "--prefix", stage, "--config", "Release")
    if args.platform == "macos-arm64":
        app = stage / "Mokaid.app"
        require(app.is_dir(), "CMake installation did not produce Mokaid.app")
        shader_source = stage / "shaders"
        require((shader_source / "office.metallib").is_file(), "Compiled Metal shader library is missing")
        shutil.copytree(shader_source, app / "Contents/Resources/shaders")
        frameworks = app / "Contents/Frameworks"
        frameworks.mkdir(parents=True, exist_ok=True)
        if updates:
            shutil.copytree(args.sdk / "Sparkle.framework", frameworks / "Sparkle.framework", symlinks=True)
        deploy_macos_runtime(app, args.qt_bin, args.qml)
        destination = app / "Contents/Resources/assets"
        require(any(app.rglob("QtWebEngineProcess.app")), "QtWebEngine helper missing from bundle")
    else:
        exe = stage / "Mokaid.exe"
        require(exe.is_file(), "CMake installation did not produce Mokaid.exe")
        run(args.qt_bin / "windeployqt.exe", "--release", "--no-compiler-runtime", "--qmldir", args.qml,
            "--dir", stage, exe)
        if updates:
            dlls = list(args.sdk.glob("x64/Release/WinSparkle.dll"))
            require(len(dlls) == 1, "Verified WinSparkle x64 DLL missing")
            shutil.copy2(dlls[0], stage / "WinSparkle.dll")
        require(any(stage.rglob("QtWebEngineProcess.exe")), "QtWebEngine helper missing from package")
        require(all((stage / "shaders" / name).is_file() for name in (
                    "office.vs.dxil", "office.ps.dxil", "office.post.vs.dxil",
                    "bloomDownsample.ps.dxil", "bloomBlur.ps.dxil", "officeComposite.ps.dxil")),
                "Compiled DirectX shaders are missing")
        require(not any(stage.rglob("vc_redist*.exe")), "Per-user packages must use app-local CRT DLLs")
        copy_windows_crt(stage, Path(required_env("VCToolsRedistDir")))
        destination = stage / "assets"
    shutil.copytree(args.assets, destination, dirs_exist_ok=True)
    notices = app / "Contents/Resources/THIRD_PARTY_NOTICES.md" if args.platform == "macos-arm64" else stage / "THIRD_PARTY_NOTICES.md"
    shutil.copy2(HERE / "THIRD_PARTY_NOTICES.md", notices)
    (stage / "distribution-stage.json").write_text(json.dumps({"schemaVersion": 1,
        "platform": args.platform, "updatesEnabled": updates, "developmentBuild": development}, indent=2) + "\n")


def require_release_stage(stage: Path, target: str) -> None:
    config = json.loads((stage / "distribution-stage.json").read_text())
    require(config.get("schemaVersion") == 1 and config.get("platform") == target,
            "The staged runtime does not match the release platform")
    require(config.get("updatesEnabled") is True, "Development previews cannot be signed as public releases")
    require(config.get("developmentBuild") is False, "Public releases require a non-development application identity")


def windows_signing_action(status: str, *, owned: bool) -> str:
    if status == "Valid":
        return "sign" if owned else "preserve"
    require(status == "NotSigned", f"Refusing to replace an invalid Authenticode signature: {status}")
    return "sign"


def sign_windows_runtime(stage: Path) -> None:
    for path in sorted(stage.rglob("*")):
        if path.suffix.lower() not in (".dll", ".exe") or not path.is_file():
            continue
        status = run("pwsh", "-NoProfile", "-File", HERE / "windows/signature-status.ps1",
                     "-File", path, capture=True).strip()
        owned = path == stage / "Mokaid.exe"
        if windows_signing_action(status, owned=owned) == "sign":
            run("pwsh", "-NoProfile", "-File", HERE / "windows/sign.ps1", "-File", path)


def write_evidence(args: argparse.Namespace, artifact: Path, secret: dict[str, str]) -> None:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    signer = Ed25519PrivateKey.from_private_bytes(base64.b64decode(secret["update_ed25519_seed"], validate=True))
    # Sparkle / WinSparkle Ed25519 uses the raw archive bytes (not its SHA256).
    signature = base64.b64encode(signer.sign(artifact.read_bytes())).decode("ascii")
    metadata = {
        "schemaVersion": 1, "version": args.version, "buildVersion": build_version(args.version), "channel": args.channel,
        "platform": args.platform, "file": artifact.name, "size": artifact.stat().st_size,
        "sha256": sha256(artifact), "edSignature": signature,
        "osSignatureVerified": True, "notarized": args.platform == "macos-arm64",
        "publicKey": base64.b64encode(public_key()).decode("ascii"),
        "sourceCommit": required_env("GITHUB_SHA"), "tag": f"desktop-v{args.version}",
    }
    metadata["evidenceSignature"] = base64.b64encode(signer.sign(evidence_bytes(metadata))).decode("ascii")
    (args.output / f"{args.platform}.json").write_text(json.dumps(metadata, indent=2) + "\n")


def create_signing_keychain(directory: Path, secret: dict[str, str]) -> tuple[Path, str]:
    """No keychain/P12 password in argv, environment or filesystem."""
    keychain = directory / "signing.keychain-db"
    helper = directory / "import_identity"
    fingerprint = secret.get("developer_id_certificate_sha256", "")
    require(re.fullmatch(r"[0-9a-f]{64}", fingerprint), "Signing certificate requires its exact SHA256 fingerprint")
    require(secret.get("developer_id_identity", "").startswith("Developer ID Application:"),
            "Expected a Developer ID Application signing identity")
    run("/usr/bin/xcrun", "clang", "-fobjc-arc", "-Wall", "-Wextra", "-Werror",
        "-mmacosx-version-min=13.0", "-framework", "Foundation", "-framework", "Security",
        HERE / "macos/import_identity.m", "-o", helper, capture=True)
    request = {"keychain_path": str(keychain), "keychain_password": base64.b64encode(os.urandom(48)).decode(),
               "p12": secret["developer_id_p12"], "p12_password": secret["p12_password"],
               "certificate_sha256": fingerprint}
    environment = {key: os.environ[key] for key in ("HOME", "TMPDIR") if key in os.environ}
    environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    # Capture all helper output and use fixed errors. It sees no signing AWS
    # credentials or attacker-controlled DYLD configuration in its environment.
    try:
        result = subprocess.run([str(helper)], input=json.dumps(request).encode(),
                                capture_output=True, check=False, timeout=120, env=environment)
    except (OSError, subprocess.SubprocessError):
        raise ValueError("Temporary signing keychain helper failed") from None
    require(result.returncode == 0, "Temporary signing keychain import failed")
    try:
        outcome = json.loads(result.stdout)
        identity = outcome["codesign_identity"]
    except Exception:
        raise ValueError("Temporary signing keychain returned invalid public metadata") from None
    require(outcome.get("certificate_sha256") == fingerprint and outcome.get("codesign_acl_verified") is True and re.fullmatch(r"[0-9a-f]{40}", identity),
            "Imported signing identity fingerprint mismatch")
    require(keychain.is_file(), "Temporary signing keychain was not created")
    return keychain, identity


def package_macos(args: argparse.Namespace, secret: dict[str, str]) -> Path:
    require(platform.system() == "Darwin", "macOS signing requires a macOS runner")
    app = args.stage.resolve() / "Mokaid.app"
    require_release_stage(args.stage, "macos-arm64")
    require(app.is_dir(), "Missing deployed application bundle")
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    require(info.get("SUPublicEDKey") == required_env("MOKAID_UPDATE_PUBLIC_KEY"), "Bundle update key mismatch")
    require(info.get("CFBundleVersion") == build_version(args.version), "Bundle version does not match the release tag")
    require(info.get("CFBundleIdentifier") == ("com.mokaid.desktop.beta" if args.channel == "beta" else "com.mokaid.desktop"), "Bundle identity/channel mismatch")
    with tempfile.TemporaryDirectory(prefix="mokaid-sign-") as temp:
        directory = Path(temp)
        keychain, notary = directory / "signing.keychain-db", directory / "notary.p8"
        notary.write_text(secret["notary_key_p8"])
        os.chmod(notary, 0o600)
        try:
            keychain, identity = create_signing_keychain(directory, secret)
            # Sign innermost Mach-O objects, then framework/XPC/app envelopes.
            macho_magic = {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"}
            objects = []
            for path in app.rglob("*"):
                if path.is_file() and not path.is_symlink():
                    with path.open("rb") as stream:
                        if stream.read(4) in macho_magic:
                            objects.append(path)
            envelopes = [p for p in app.rglob("*") if p.is_dir() and not p.is_symlink()
                         and p.suffix in (".framework", ".xpc", ".app")]
            for path in sorted(objects, key=lambda p: len(p.parts), reverse=True) + sorted(envelopes, key=lambda p: len(p.parts), reverse=True) + [app]:
                command = ["codesign", "--force", "--timestamp", "--options", "runtime", "--sign", identity, "--keychain", keychain]
                if "QtWebEngineProcess" in str(path) or path == app:
                    command += ["--entitlements", HERE / "macos/entitlements.plist"]
                elif path != app:
                    command += ["--preserve-metadata=entitlements"]
                run(*command, path)
            run("codesign", "--verify", "--deep", "--strict", app)
            archive = directory / "Mokaid.zip"
            run("ditto", "-c", "-k", "--keepParent", app, archive)
            run("xcrun", "notarytool", "submit", archive, "--key", notary, "--key-id", secret["notary_key_id"],
                "--issuer", secret["notary_issuer"], "--wait", "--output-format", "json")
            run("xcrun", "stapler", "staple", app)
            run("spctl", "--assess", "--type", "execute", "--verbose=2", app)
            image_root = directory / "image"
            image_root.mkdir()
            # Separate Finder names avoid a beta install overwriting stable.
            image_name = "Mokaid Beta.app" if args.channel == "beta" else app.name
            shutil.copytree(app, image_root / image_name, symlinks=True)
            (image_root / "Applications").symlink_to("/Applications", target_is_directory=True)
            artifact = args.output / f"Mokaid-{args.version}-macos-arm64.dmg"
            run("hdiutil", "create", "-volname", "Mokaid", "-srcfolder", image_root, "-format", "UDZO", artifact)
            run("codesign", "--timestamp", "--sign", identity, "--keychain", keychain, artifact)
            run("xcrun", "notarytool", "submit", artifact, "--key", notary, "--key-id", secret["notary_key_id"],
                "--issuer", secret["notary_issuer"], "--wait", "--output-format", "json")
            run("xcrun", "stapler", "staple", artifact)
            run("xcrun", "stapler", "validate", artifact)
            run("codesign", "--verify", "--strict", artifact)
            return artifact
        finally:
            if keychain.exists():
                run("security", "delete-keychain", keychain, capture=True)


def package_windows(args: argparse.Namespace) -> Path:
    require(platform.system() == "Windows", "Windows signing requires a Windows runner")
    for name in ("MOKAID_AZURE_SIGNING_ENDPOINT", "MOKAID_AZURE_SIGNING_ACCOUNT", "MOKAID_AZURE_CERTIFICATE_PROFILE"):
        required_env(name)
    stage = args.stage.resolve()
    require_release_stage(stage, "windows-x64")
    require((stage / "Mokaid.exe").is_file(), "Missing deployed executable")
    sign_windows_runtime(stage)
    name = f"Mokaid-{args.version}-windows-x64"
    product = "Mokaid Beta" if args.channel == "beta" else "Mokaid"
    bundle_id = "com.mokaid.desktop.beta" if args.channel == "beta" else "com.mokaid.desktop"
    icon_folder = args.output / "icons"
    icons(icon_folder)
    sign_command = f'pwsh -NoProfile -File $q{HERE / "windows/sign.ps1"}$q -File $f'
    iscc = os.environ.get("ISCC_PATH", r"C:\Program Files (x86)\Inno Setup 6\ISCC.exe")
    run(iscc, f"/DProductName={product}", f"/DBundleId={bundle_id}", f"/DVersion={args.version}",
        f"/DStageDir={stage}", f"/DOutputDir={args.output.resolve()}", f"/DOutputName={name}",
        f"/DIconPath={icon_folder.resolve() / 'Mokaid.ico'}", f"/DLicensePath={HERE / 'THIRD_PARTY_NOTICES.md'}",
        f"/Sazure={sign_command}", HERE / "windows/Mokaid.iss")
    artifact = args.output / f"{name}.exe"
    require(artifact.is_file(), "Inno Setup did not produce the installer")
    # Inno invokes the same callback for both uninstaller and outer installer.
    run("pwsh", "-NoProfile", "-File", HERE / "windows/verify.ps1", "-File", artifact)
    return artifact


def preview_macos(args: argparse.Namespace) -> Path:
    """Create a local development DMG; never emit evidence or update feeds."""
    require(platform.system() == "Darwin", "Development DMGs require a macOS host")
    stage = args.stage.resolve()
    config = json.loads((stage / "distribution-stage.json").read_text())
    require(config.get("platform") == "macos-arm64" and config.get("updatesEnabled") is False,
            "Development preview requires a macOS build with updates disabled")
    require(config.get("developmentBuild") is True,
            "Development preview requires a compiled MOKAID_DEVELOPMENT=ON identity")
    source_app = stage / "Mokaid.app"
    require(source_app.is_dir(), "Missing deployed development application")
    with (source_app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    version = info["CFBundleShortVersionString"]
    require(RELEASE_RE.fullmatch(version), "Development build has an invalid version")
    require(not info.get("SUEnableAutomaticChecks"), "Development bundle must disable automatic updates")
    require(info.get("CFBundleIdentifier") == "com.mokaid.desktop.development"
            and info.get("CFBundleName") == "Mokaid Development",
            "Development bundle identity must match the compiled development session namespace")
    args.output.mkdir(parents=True, exist_ok=True)
    artifact = args.output.resolve() / f"Mokaid-{version}-development-macos-arm64.dmg"
    require(not artifact.exists(), "Development DMG already exists; choose another output directory")
    with tempfile.TemporaryDirectory(prefix="mokaid-preview-") as directory:
        image_root = Path(directory) / "image"
        image_root.mkdir()
        app = image_root / "Mokaid Development.app"
        shutil.copytree(source_app, app, symlinks=True)
        # Ad-hoc signatures allow a locally built ARM64 bundle to run. They are
        # explicitly not Developer ID signatures or proof of notarization.
        run("codesign", "--force", "--deep", "--sign", "-", "--timestamp=none", app)
        run("codesign", "--verify", "--deep", "--strict", app)
        (image_root / "Applications").symlink_to("/Applications", target_is_directory=True)
        (image_root / "DEVELOPMENT-PREVIEW.txt").write_text(
            "Mokaid development preview\n\nThis local build is not notarized or signed with Developer ID.\n"
            "Automatic updates are disabled. This is not a public release.\n")
        run("hdiutil", "create", "-volname", "Mokaid Development", "-srcfolder", image_root,
            "-format", "UDZO", artifact)
    print(artifact)
    return artifact


def package(args: argparse.Namespace) -> None:
    check_version(args.version, args.channel)
    public_key()
    secret = signing_secret()
    check_secret(secret, args.platform)
    args.output.mkdir(parents=True, exist_ok=True)
    artifact = package_macos(args, secret) if args.platform == "macos-arm64" else package_windows(args)
    write_evidence(args, artifact, secret)


def verify_evidence(directory: Path, target: str, version: str, channel: str) -> dict:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
    metadata = json.loads((directory / f"{target}.json").read_text())
    require(metadata.get("schemaVersion") == 1, "Unsupported release evidence schema")
    require(metadata.get("version") == version and metadata.get("channel") == channel, "Release version/channel mismatch")
    require(metadata.get("platform") == target, "Release platform mismatch")
    require(metadata.get("osSignatureVerified") is True, "OS signature evidence is missing")
    require(target != "macos-arm64" or metadata.get("notarized") is True, "Notarization evidence missing")
    name = f"Mokaid-{version}-{target}{PLATFORMS[target][0]}"
    require(metadata.get("file") == name, "Unexpected release file name")
    artifact = directory / name
    require(artifact.stat().st_size == metadata.get("size") and sha256(artifact) == metadata.get("sha256"), "Artifact checksum/size mismatch")
    require(metadata.get("publicKey") == required_env("MOKAID_UPDATE_PUBLIC_KEY"), "Evidence public key mismatch")
    verifier = Ed25519PublicKey.from_public_bytes(public_key())
    require(isinstance(metadata.get("evidenceSignature"), str), "Authenticated signing evidence is missing")
    verifier.verify(base64.b64decode(metadata["evidenceSignature"], validate=True), evidence_bytes(metadata))
    verifier.verify(base64.b64decode(metadata["edSignature"], validate=True), artifact.read_bytes())
    require(metadata.get("buildVersion") == build_version(version), "Bundle version evidence mismatch")
    require(re.fullmatch(r"[0-9a-f]{40}", metadata.get("sourceCommit", "")), "Evidence has no valid source commit")
    return metadata


def make_feed(metadata: dict, published: str) -> bytes:
    target = metadata["platform"]
    root = ET.Element("rss", version="2.0")
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = f"Mokaid {metadata['channel']} {target}"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"Mokaid {metadata['version']}"
    ET.SubElement(item, "pubDate").text = published
    ET.SubElement(item, f"{{{SPARKLE}}}releaseNotesLink").text = f"https://github.com/Yapio-Ltd/mokaid/releases/tag/desktop-v{metadata['version']}"
    ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = PLATFORMS[target][2]
    ET.SubElement(item, "enclosure", {
        "url": f"{BASE_URL}/releases/{metadata['version']}/{metadata['file']}",
        "length": str(metadata["size"]), "type": PLATFORMS[target][1],
        f"{{{SPARKLE}}}version": metadata["buildVersion"],
        f"{{{SPARKLE}}}shortVersionString": metadata["version"],
        f"{{{SPARKLE}}}edSignature": metadata["edSignature"],
        f"{{{SPARKLE}}}os": "macos" if target == "macos-arm64" else "windows",
    })
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)


def validate_readiness(directory: Path, version: str, channel: str, record: Path | None = None) -> list[dict]:
    """Require reviewed acceptance evidence for these exact signed candidate bytes.

    This validates the record, not the truth of the tests. Protected-branch review
    and the release environment's human approval remain mandatory trust boundaries.
    """
    check_version(version, channel)
    metadata = [verify_evidence(directory, target, version, channel) for target in PLATFORMS]
    require(len({item["sourceCommit"] for item in metadata}) == 1, "Platform builds came from different source commits")
    path = record if record is not None else HERE / "acceptance" / f"{version}.json"
    require(path.is_file(), "Public release blocked: reviewed acceptance record for this version is missing")
    accepted = json.loads(path.read_text())
    require(isinstance(accepted, dict), "Acceptance record must be a structured object")
    require(accepted.get("schemaVersion") == 1 and accepted.get("version") == version
            and accepted.get("channel") == channel, "Acceptance record version/channel mismatch")
    require(accepted.get("sourceCommit") == metadata[0]["sourceCommit"], "Acceptance record targets another source commit")
    require(accepted.get("artifacts") == {item["platform"]: item["sha256"] for item in metadata},
            "Acceptance record does not cover the exact signed installers")
    require(isinstance(accepted.get("approvedBy"), str) and len(accepted["approvedBy"].strip()) >= 3,
            "Acceptance record needs an accountable release reviewer")
    stamp = accepted.get("approvedAt", "")
    require(isinstance(stamp, str), "Acceptance approval timestamp is required")
    approved = datetime.fromisoformat(stamp.replace("Z", "+00:00"))
    require(approved.tzinfo is not None and approved <= datetime.now(timezone.utc),
            "Acceptance approval timestamp must be in the past with an explicit time zone")
    checks = accepted.get("checks", [])
    require(isinstance(checks, list) and all(isinstance(check, dict) for check in checks),
            "Acceptance checks must be structured records")
    require({check.get("id") for check in checks} == READINESS_CHECKS and len(checks) == len(READINESS_CHECKS),
            "Acceptance record must cover every required product, security and hardware check exactly once")
    for check in checks:
        require(check.get("status") == "passed", f"Public release blocked: {check['id']} has not passed")
        require(isinstance(check.get("evidence"), str), f"Acceptance check {check['id']} needs an evidence reference")
        evidence = urlparse(check.get("evidence", ""))
        require(evidence.scheme == "https" and bool(evidence.hostname) and not evidence.username and not evidence.password,
                f"Acceptance check {check['id']} needs an HTTPS evidence reference without credentials")
    return metadata


def promote(args: argparse.Namespace) -> None:
    # Acceptance is checked before obtaining a cloud client or writing anything.
    metadata = validate_readiness(args.artifacts, args.version, args.channel, getattr(args, "readiness", None))
    import boto3
    from email.utils import format_datetime
    s3 = boto3.client("s3")
    bucket = required_env("MOKAID_DOWNLOADS_BUCKET")
    try:
        previous = json.loads(s3.get_object(Bucket=bucket, Key=f"{args.channel}/release.json")["Body"].read())
    except s3.exceptions.ClientError as error:
        if error.response["ResponseMetadata"]["HTTPStatusCode"] != 404:
            raise
    else:
        check_version(previous["version"], args.channel)
        previous_parts = tuple(int(v or 0) for v in RELEASE_RE.fullmatch(previous["version"]).groups())
        next_parts = tuple(int(v or 0) for v in RELEASE_RE.fullmatch(args.version).groups())
        require(next_parts >= previous_parts, "Refusing to move the public update feed backwards")
    published = datetime.now(timezone.utc)
    # Immutable paths are uploaded only if absent. Existing content must match;
    # promotion cannot replace a release under a published version number.
    for path in sorted(args.artifacts.iterdir()):
        if not path.is_file():
            continue
        key = f"releases/{args.version}/{path.name}"
        digest = sha256(path)
        try:
            existing = s3.head_object(Bucket=bucket, Key=key)
        except s3.exceptions.ClientError as error:
            if error.response["ResponseMetadata"]["HTTPStatusCode"] != 404:
                raise
            s3.put_object(Bucket=bucket, Key=key, Body=path.read_bytes(),
                          ContentType="application/json" if path.suffix == ".json" else "application/octet-stream",
                          CacheControl="public,max-age=31536000,immutable", Metadata={"sha256": digest}, IfNoneMatch="*")
        else:
            require(existing.get("Metadata", {}).get("sha256") == digest, f"Immutable artifact already exists with different bytes: {path.name}")
        remote = s3.head_object(Bucket=bucket, Key=key)
        require(remote["ContentLength"] == path.stat().st_size and remote["Metadata"]["sha256"] == digest, "S3 verification failed")
    # Only advance feeds after BOTH signed platform payloads are available.
    downloads = {}
    for item in metadata:
        target = item["platform"]
        s3.put_object(Bucket=bucket, Key=f"{args.channel}/{target}.xml", Body=make_feed(item, format_datetime(published)),
                      ContentType="application/rss+xml", CacheControl="public,max-age=60,must-revalidate")
        downloads[target] = {"url": f"{BASE_URL}/releases/{args.version}/{item['file']}",
                             "sha256": item["sha256"], "size": item["size"], "minimumOS": PLATFORMS[target][2]}
    manifest = {"schemaVersion": 1, "version": args.version, "channel": args.channel,
                "publishedAt": published.isoformat(), "downloads": downloads,
                "releaseNotesUrl": f"https://github.com/Yapio-Ltd/mokaid/releases/tag/desktop-v{args.version}"}
    s3.put_object(Bucket=bucket, Key=f"{args.channel}/release.json", Body=json.dumps(manifest).encode(),
                  ContentType="application/json", CacheControl="public,max-age=60,must-revalidate")
    distribution = os.environ.get("MOKAID_DOWNLOADS_DISTRIBUTION_ID")
    if distribution:
        boto3.client("cloudfront").create_invalidation(DistributionId=distribution,
            InvalidationBatch={"Paths": {"Quantity": 1, "Items": [f"/{args.channel}/*"]},
                               "CallerReference": f"desktop-{args.version}-{published.timestamp()}"})


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    commands = result.add_subparsers(dest="command", required=True)
    icon_parser = commands.add_parser("icons")
    icon_parser.add_argument("--output", required=True, type=Path)
    sdk_parser = commands.add_parser("sdk")
    sdk_parser.add_argument("--platform", choices=[*PLATFORMS, "dxc"], required=True)
    sdk_parser.add_argument("--output", required=True, type=Path)
    stage_parser = commands.add_parser("stage")
    stage_parser.add_argument("--platform", choices=PLATFORMS, required=True)
    for name in ("build", "stage", "assets", "qt-bin", "qml"):
        stage_parser.add_argument(f"--{name}", required=True, type=Path)
    stage_parser.add_argument("--sdk", type=Path)
    preview_parser = commands.add_parser("preview-macos")
    preview_parser.add_argument("--stage", type=Path, required=True)
    preview_parser.add_argument("--output", type=Path, required=True)
    for command in ("package", "verify", "promote"):
        sub = commands.add_parser(command)
        sub.add_argument("--version", required=True)
        sub.add_argument("--channel", choices=("stable", "beta"), default="stable")
        if command == "package":
            sub.add_argument("--platform", choices=PLATFORMS, required=True)
            sub.add_argument("--stage", required=True, type=Path)
            sub.add_argument("--output", required=True, type=Path)
        else:
            sub.add_argument("--artifacts", required=True, type=Path)
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        if args.command == "icons": icons(args.output)
        elif args.command == "sdk": fetch_sdk(args.platform, args.output)
        elif args.command == "stage": stage_runtime(args)
        elif args.command == "preview-macos": preview_macos(args)
        elif args.command == "package": package(args)
        elif args.command == "promote": promote(args)
        elif args.command == "verify":
            check_version(args.version, args.channel)
            for target in PLATFORMS:
                verify_evidence(args.artifacts, target, args.version, args.channel)
            print("Both release payloads match their verified Ed25519 signatures and SHA256 evidence.")
        return 0
    except (ValueError, OSError, subprocess.CalledProcessError) as failure:
        # Never format subprocess exceptions or replay captured tool output.
        print(f"Release failed: {failure}" if isinstance(failure, ValueError) else "Release failed: a required tool or file operation failed.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
