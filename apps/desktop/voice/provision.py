#!/usr/bin/env python3
"""Build-time only: provision pinned native voice engines and local model weights.

No package manager, Python, executable download, or network is needed at runtime.
All archives are SHA256 verified before extraction; bundle manifest verifies the
resulting runtime. The download cache may be reused across CI jobs.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

WHISPER_SOURCE = ("https://github.com/ggml-org/whisper.cpp/archive/refs/tags/v1.9.4.tar.gz", "57e280cee375ab02425b806ad5146b99f6eb9357e3c2b31357c8a6af2e2e44ae")
WHISPER_MODEL = ("https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-q5_1.bin", "422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898")
KOKORO_MODEL = ("https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-int8-multi-lang-v1_0.tar.bz2", "4c3052abaa60943a341f193888cf6abd68787dae6ab8ae5c925a706caa247e4e")
LICENSES = {
    "sherpa-onnx-Apache-2.0.txt": ("https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v1.13.8/LICENSE", "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30"),
    "espeak-ng-GPL-3.0.txt": ("https://raw.githubusercontent.com/espeak-ng/espeak-ng/1.52.0/COPYING", "8ceb4b9ee5adedde47b31e975c1d90c73ad27b6b165a1dcd80c7c545eb65b903"),
    "onnxruntime-MIT.txt": ("https://raw.githubusercontent.com/microsoft/onnxruntime/v1.23.2/LICENSE", "2f07c72751aed99790b8a4869cf2311df85a860b22ded05fa22803587a48922c"),
}
SHERPA_BASE = "https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.8/"
SHERPA = {
    "macos-arm64": ("sherpa-onnx-v1.13.8-osx-arm64-shared.tar.bz2", "b10e5c7e2c30ea03de9c442655d14860d9edc475c6251d58a8f5f06e913a1d56"),
    "macos-x64": ("sherpa-onnx-v1.13.8-osx-x64-shared.tar.bz2", "54aad64acee9d2d596535a6080d6f22602a720af5460e1d50461b1e1b06bee40"),
    "windows-x64": ("sherpa-onnx-v1.13.8-win-x64-shared-MT-Release.tar.bz2", "6dffdc715a4465b989446a6105265d2cb345e7101591a17d35534b6758f6e8df"),
}


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def download(asset: tuple[str, str], cache: Path) -> Path:
    url, expected = asset
    target = cache / expected
    if target.is_file() and sha256(target) == expected:
        return target
    partial = target.with_suffix(".partial")
    try:
        request = urllib.request.Request(url, headers={"User-Agent": "Mokaid-Voice-Build/1"})
        print("Downloading", url, flush=True)
        with urllib.request.urlopen(request, timeout=180) as response, partial.open("wb") as stream:
            shutil.copyfileobj(response, stream)
        if sha256(partial) != expected:
            raise RuntimeError(f"SHA256 mismatch for {url}")
        partial.replace(target)
    finally:
        partial.unlink(missing_ok=True)
    return target


def extract(archive: Path, destination: Path) -> Path:
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive) as package:
        # Python's data filter blocks path traversal, device files and external links.
        package.extractall(destination, filter="data")
    roots = list(destination.iterdir())
    if len(roots) != 1 or not roots[0].is_dir():
        raise RuntimeError("Expected a single archive root")
    return roots[0]


def copy_tree(source: Path, destination: Path) -> None:
    shutil.copytree(source, destination, dirs_exist_ok=True, symlinks=False)


def provision(args: argparse.Namespace) -> None:
    output, cache = args.output.resolve(), args.cache.resolve()
    cache.mkdir(parents=True, exist_ok=True)
    output.parent.mkdir(parents=True, exist_ok=True)
    # A failed provision never leaves an apparently complete runtime.
    with tempfile.TemporaryDirectory(prefix="voice-stage-", dir=output.parent) as temporary:
        stage = Path(temporary)
        runtime = stage / "runtime"
        (runtime / "bin").mkdir(parents=True)
        (runtime / "models").mkdir()
        (runtime / "licenses").mkdir()
        for filename, asset in LICENSES.items():
            shutil.copy2(download(asset, cache), runtime / "licenses" / filename)
        source = extract(download(WHISPER_SOURCE, cache), stage / "whisper-source")
        build = stage / "whisper-build"
        configure = [args.cmake, "-S", str(source), "-B", str(build), "-DCMAKE_BUILD_TYPE=Release", "-DBUILD_SHARED_LIBS=OFF", "-DWHISPER_BUILD_TESTS=OFF", "-DWHISPER_BUILD_EXAMPLES=ON", "-DWHISPER_BUILD_SERVER=OFF", "-DGGML_NATIVE=OFF", "-DGGML_OPENMP=OFF", "-DGGML_BLAS=OFF"]
        if args.ninja:
            configure += ["-G", "Ninja", "-DCMAKE_MAKE_PROGRAM=" + args.ninja]
        if args.platform.startswith("macos"):
            configure += ["-DCMAKE_OSX_DEPLOYMENT_TARGET=13.0", "-DCMAKE_OSX_ARCHITECTURES=" + ("arm64" if args.platform.endswith("arm64") else "x86_64"), "-DGGML_METAL=OFF"]
        else:
            configure += ["-DGGML_CUDA=OFF", "-DGGML_VULKAN=OFF"]
        subprocess.run(configure, check=True)
        subprocess.run([args.cmake, "--build", str(build), "--config", "Release", "--target", "whisper-cli", "-j", "4"], check=True)
        executable = "whisper-cli.exe" if args.platform.startswith("windows") else "whisper-cli"
        candidates = list(build.rglob(executable))
        if not candidates:
            raise RuntimeError("whisper-cli was not built")
        shutil.copy2(candidates[0], runtime / "bin" / executable)
        shutil.copy2(source / "LICENSE", runtime / "licenses" / "whisper-MIT.txt")
        shutil.copy2(download(WHISPER_MODEL, cache), runtime / "models" / "ggml-base-q5_1.bin")
        filename, digest = SHERPA[args.platform]
        sherpa = extract(download((SHERPA_BASE + filename, digest), cache), stage / "sherpa")
        # Retain all dependent runtime libraries, but only the TTS executable.
        copy_tree(sherpa / "lib", runtime / "sherpa" / "lib")
        (runtime / "sherpa" / "bin").mkdir()
        tts = "sherpa-onnx-offline-tts.exe" if args.platform.startswith("windows") else "sherpa-onnx-offline-tts"
        shutil.copy2(sherpa / "bin" / tts, runtime / "sherpa" / "bin" / tts)
        for dll in (sherpa / "bin").glob("*.dll"):
            shutil.copy2(dll, runtime / "sherpa" / "bin" / dll.name)
        for license_file in sherpa.glob("*LICENSE*"):
            if license_file.is_file():
                shutil.copy2(license_file, runtime / "licenses" / ("sherpa-" + license_file.name))
        kokoro = extract(download(KOKORO_MODEL, cache), stage / "kokoro")
        copy_tree(kokoro, runtime / "models" / "kokoro")
        # Official sherpa package is self-relative (@executable_path/../lib).
        manifest = {"schema": 1, "platform": args.platform, "stt": "Whisper base q5_1", "tts": "Kokoro 82M int8 v1.0", "files": {str(path.relative_to(runtime)).replace(os.sep, "/"): sha256(path) for path in sorted(runtime.rglob("*")) if path.is_file() and "models" in path.relative_to(runtime).parts}}
        (runtime / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        # Build output belongs to this script; it contains no user data.
        if output.exists():
            shutil.rmtree(output)
        runtime.replace(output)
    print(f"Local voice runtime ready: {output}", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--platform", choices=SHERPA, required=True)
    parser.add_argument("--cmake", default="cmake")
    parser.add_argument("--ninja", default="")
    provision(parser.parse_args())

if __name__ == "__main__":
    main()
