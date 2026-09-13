#!/usr/bin/env python3
"""Cross-platform build orchestration; all workflow inputs are validated here."""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
from release import HERE, REPO, check_version, require, required_env, run, validate_assets

DESKTOP = HERE.parent


def metal_options() -> list[str]:
    available = subprocess.run(["xcrun", "-sdk", "macosx", "metal", "--version"],
                               capture_output=True, text=True, check=False)
    if available.returncode == 0:
        return []
    # Newer Xcode runners download Metal separately. Use its reported identifier
    # rather than hardcoding a cryptex path or a developer-machine toolchain.
    run("xcodebuild", "-downloadComponent", "MetalToolchain")
    component = json.loads(run("xcodebuild", "-showComponent", "MetalToolchain", "-json", capture=True))
    identifier = component.get("toolchainIdentifier", "")
    require(component.get("status") == "installed" and identifier.startswith("com.apple.dt.toolchain.Metal."),
            "Xcode did not register an installed Metal compiler toolchain")
    run("xcrun", "--toolchain", identifier, "-sdk", "macosx", "metal", "--version")
    return [f"-DMOKAID_METAL_TOOLCHAIN={identifier}"]


def configuration() -> tuple[str, str, str]:
    tag = required_env("GITHUB_REF_NAME")
    require(tag.startswith("desktop-v"), "Release must originate from a desktop-v tag")
    version = tag.removeprefix("desktop-v")
    channel = "beta" if "-beta." in version else "stable"
    check_version(version, channel)
    return version, channel, version.split("-")[0]


def configure(args: argparse.Namespace) -> None:
    release = args.release
    version, channel, numeric = configuration() if release else ("0.1.0", "stable", "0.1.0")
    preset = "macos-release" if platform.system() == "Darwin" else "windows-release"
    target = "macos-arm64" if platform.system() == "Darwin" else "windows-x64"
    run(sys.executable, DESKTOP / "scripts/check_boundaries.py")
    run(sys.executable, "-m", "unittest", "discover", "-s", DESKTOP / "scripts/tests", "-v")
    cook_assets()
    run("conan", "profile", "detect", "--force")
    run("conan", "install", DESKTOP, "--lockfile", DESKTOP / "conan.lock",
        "--output-folder", DESKTOP / "build/conan", "-s", "build_type=Release",
        "-s", "compiler.cppstd=20", "--build=missing")
    sdk_folder = Path(required_env("RUNNER_TEMP")) / "mokaid-updater-sdk"
    sdk = run(sys.executable, HERE / "release.py", "sdk", "--platform", target,
              "--output", sdk_folder, capture=True).strip().splitlines()[-1]
    compiler_options = []
    if target == "macos-arm64":
        compiler_options.extend(metal_options())
    if target == "windows-x64":
        dxc_folder = Path(required_env("RUNNER_TEMP")) / "mokaid-dxc-sdk"
        dxc = run(sys.executable, HERE / "release.py", "sdk", "--platform", "dxc",
                  "--output", dxc_folder, capture=True).strip().splitlines()[-1]
        compiler_options.append(f"-DMOKAID_DXC={Path(dxc) / 'bin/x64/dxc.exe'}")
    if release:
        key = required_env("MOKAID_UPDATE_PUBLIC_KEY")
    else:
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
        from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
        import base64
        key = base64.b64encode(Ed25519PrivateKey.generate().public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)).decode()
    run("cmake", "--preset", preset, f"-DMOKAID_VERSION={numeric}", f"-DMOKAID_RELEASE_VERSION={version}",
        f"-DPython3_EXECUTABLE={sys.executable}",
        f"-DMOKAID_RELEASE_CHANNEL={channel}", f"-DMOKAID_BETA={'ON' if channel == 'beta' else 'OFF'}",
        "-DMOKAID_ENABLE_UPDATES=ON", f"-DMOKAID_UPDATE_PUBLIC_KEY={key}", f"-DMOKAID_UPDATER_SDK={sdk}",
        "-DCMAKE_TOOLCHAIN_FILE=" + str(DESKTOP / "build/conan/build/Release/generators/conan_toolchain.cmake"),
        *compiler_options,
        cwd=DESKTOP)
    data = {"preset": preset, "platform": target, "sdk": sdk, "version": version, "channel": channel}
    (DESKTOP / "build/ci.json").write_text(json.dumps(data))
    run("cmake", "--build", "--preset", preset, "--parallel", "3", cwd=DESKTOP)
    tests = json.loads(run("ctest", "--test-dir", DESKTOP / f"build/{preset}", "--show-only=json-v1", capture=True))
    require(any(test.get("name") == "desktop.real_assets" for test in tests.get("tests", [])),
            "CI must register the real cooked-asset test before running CTest")
    run("ctest", "--test-dir", DESKTOP / f"build/{preset}", "--output-on-failure")


def cook_assets() -> None:
    asset_dir = DESKTOP / "build/assets"
    cooker = DESKTOP / "tools/asset-cooker"
    npm = "npm.cmd" if platform.system() == "Windows" else "npm"
    run(npm, "ci", "--ignore-scripts", cwd=cooker)
    run(npm, "test", cwd=cooker)
    run("node", cooker / "cook.mjs", asset_dir)
    validate_assets(asset_dir)


def stage() -> None:
    config = json.loads((DESKTOP / "build/ci.json").read_text())
    asset_dir = DESKTOP / "build/assets"
    # Reuse the exact cooked bytes covered by the configured native tests.
    validate_assets(asset_dir)
    qt_root = Path(required_env("QT_ROOT_DIR"))
    stage = DESKTOP / "build/stage"
    run(sys.executable, HERE / "release.py", "stage", "--platform", config["platform"],
        "--build", DESKTOP / f"build/{config['preset']}", "--stage", stage,
        "--assets", asset_dir, "--sdk", config["sdk"], "--qt-bin", qt_root / "bin",
        "--qml", DESKTOP / "presentation")


def package() -> None:
    config = json.loads((DESKTOP / "build/ci.json").read_text())
    run(sys.executable, HERE / "release.py", "package", "--platform", config["platform"],
        "--version", config["version"], "--channel", config["channel"],
        "--stage", DESKTOP / "build/stage", "--output", DESKTOP / "build/release")


def sbom() -> None:
    import hashlib
    from datetime import datetime, timezone
    config = json.loads((DESKTOP / "build/ci.json").read_text())
    stage = DESKTOP / "build/stage"
    from release import sha256
    files = [{"fileName": "./" + p.relative_to(stage).as_posix(),
              "SPDXID": "SPDXRef-File-" + hashlib.sha256(p.relative_to(stage).as_posix().encode()).hexdigest()[:24],
              "checksums": [{"algorithm": "SHA256", "checksumValue": sha256(p)}],
              "licenseConcluded": "NOASSERTION", "copyrightText": "NOASSERTION"}
             for p in sorted(stage.rglob("*")) if p.is_file() and not p.is_symlink()]
    document = {"spdxVersion": "SPDX-2.3", "dataLicense": "CC0-1.0", "SPDXID": "SPDXRef-DOCUMENT",
                "name": f"Mokaid {config['version']} {config['platform']}",
                "documentNamespace": f"https://mokaid.com/spdx/{config['version']}/{config['platform']}/{required_env('GITHUB_SHA')}",
                "creationInfo": {"created": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "creators": ["Tool: mokaid-desktop-ci"]},
                "files": files, "packages": [],
                "comment": "File inventory of the deployed bundle; license review and upstream package manifests accompany the release."}
    output = DESKTOP / f"build/release/{config['platform']}.spdx.json"
    output.parent.mkdir(exist_ok=True, parents=True)
    output.write_text(json.dumps(document, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("configure-build-test", "cook-assets", "stage", "package", "sbom", "metadata"))
    parser.add_argument("--release", action="store_true")
    args = parser.parse_args()
    if args.command == "configure-build-test": configure(args)
    elif args.command == "cook-assets": cook_assets()
    elif args.command == "stage": stage()
    elif args.command == "package": package()
    elif args.command == "sbom": sbom()
    else:
        version, channel, _ = configuration()
        with Path(required_env("GITHUB_OUTPUT")).open("a") as out:
            out.write(f"version={version}\nchannel={channel}\n")
