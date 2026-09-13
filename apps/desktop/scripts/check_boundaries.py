#!/usr/bin/env python3
"""Read-only architectural checks for the desktop's C++/QML/CMake boundaries.

Run from any directory: python3 apps/desktop/scripts/check_boundaries.py
The standard library is sufficient; no Qt SDK or build is needed.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
import re
import sys


@dataclass(frozen=True, order=True)
class Violation:
    path: str
    line: int
    message: str


TARGET_MODULES = {
    "mokaid_core": "core",
    "mokaid_engine": "engine",
    "mokaid_renderer": "renderer",
    "mokaid_viewport": "bridge",
    "mokaid_network": "network",
    "mokaid_storage": "storage",
    "mokaid_platform": "platform",
    "mokaid_application": "application",
    "mokaid_features": "application",
    "mokaid_preview": "preview",
    "mokaid_presentation": "presentation",
}
ALLOWED = {
    "core": {"core"},
    "engine": {"engine", "core"},
    "renderer": {"renderer", "engine", "core"},
    "bridge": {"bridge", "renderer", "engine", "core"},
    "network": {"network", "core"},
    "storage": {"storage", "core"},
    "platform": {"platform", "core"},
    "application": {"application", "network", "storage", "platform", "core"},
    "preview": {"preview", "application", "core", "platform"},
    "presentation": {"presentation", "application", "bridge", "preview", "core"},
}
TEXT_SUFFIXES = {".cpp", ".hpp", ".h", ".mm", ".qml", ".cmake"}
SKIP = {"build", "out", "node_modules", ".git", "__pycache__"}
INCLUDE = re.compile(r"^\s*#\s*(?:include|import)\s*[<\"]([^>\"]+)[>\"]", re.M)


def uncomment(text: str) -> str:
    """Preserve line numbers while removing C/C++ comments."""
    return re.sub(
        r"/\*[\s\S]*?\*/|//[^\n]*",
        lambda match: "\n" * match.group().count("\n"),
        text,
    )


def inspect_file(path: Path, root: Path) -> list[Violation]:
    relative = path.relative_to(root)
    module = relative.parts[0] if len(relative.parts) > 1 else "app"
    text = path.read_text(encoding="utf-8")
    code = uncomment(text)
    if path.name == "CMakeLists.txt" or path.suffix == ".cmake":
        code = re.sub(r"(?m)^\s*#[^\n]*", "", code)
    violations: list[Violation] = []

    def report(offset: int, message: str) -> None:
        violations.append(Violation(str(relative), code.count("\n", 0, offset) + 1, message))

    for match in INCLUDE.finditer(code):
        header = match.group(1)
        is_qt = bool(re.match(r"(?:Qt|Q[A-Z])", header))
        is_native_gpu = bool(re.search(r"(?:^|/)(?:Metal|d3d\d*|dxgi\d*|vulkan|windows)(?:/|\.|$)", header, re.I))
        if module in {"core", "engine"} and (is_qt or is_native_gpu):
            report(match.start(), f"{module} must remain independent of Qt, OS and graphics APIs: {header}")
        if module == "renderer" and is_qt:
            report(match.start(), f"native renderer must not depend on Qt: {header}")
        if re.search(r"(?:^|/)private/|_p\.h$|qrhi", header, re.I):
            report(match.start(), f"private Qt/QRhi headers are not part of the supported boundary: {header}")
        dependency = re.match(r"mokaid/([^/]+)/", header)
        if dependency and module in ALLOWED:
            target = dependency.group(1)
            if target in ALLOWED and target not in ALLOWED[module]:
                report(match.start(), f"{module} cannot include higher-level {target}")
        if header.startswith(".") and module in ALLOWED:
            try:
                target = (path.parent / header).resolve().relative_to(root).parts[0]
            except ValueError:
                target = ""
            if target in ALLOWED and target not in ALLOWED[module]:
                report(match.start(), f"{module} cannot include higher-level {target} through a relative path")

    if path.name == "CMakeLists.txt" or path.suffix == ".cmake":
        for match in re.finditer(r"target_link_libraries\s*\(([\s\S]*?)\)", code, re.I):
            tokens = re.findall(r"[A-Za-z0-9_:]+", match.group(1))
            if not tokens:
                continue
            for token in tokens[1:]:
                target = TARGET_MODULES.get(token)
                if target and module in ALLOWED and target not in ALLOWED[module]:
                    report(match.start(), f"{module} cannot link higher-level {target} ({token})")
                if module in {"core", "engine", "renderer"} and token.startswith("Qt6::"):
                    report(match.start(), f"{module} cannot link Qt ({token})")
                if token in {"Qt6::GuiPrivate", "Qt6::QuickPrivate"}:
                    report(match.start(), "private Qt CMake targets are forbidden")
    if path.suffix == ".qml" and module == "presentation":
        for match in re.finditer(r"\b(?:XMLHttpRequest|fetch)\s*\(", code):
            report(match.start(), "presentation QML must call a view-model, not perform network requests")
    return violations


def check(root: Path) -> list[Violation]:
    root = root.resolve()
    findings: list[Violation] = []
    for path in root.rglob("*"):
        if not path.is_file() or set(path.relative_to(root).parts) & SKIP:
            continue
        if path.suffix in TEXT_SUFFIXES or path.name == "CMakeLists.txt":
            findings.extend(inspect_file(path, root))
    return sorted(findings)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    if not args.root.is_dir():
        parser.error("--root must name the desktop source directory")
    findings = check(args.root.resolve())
    for finding in findings:
        print(f"{finding.path}:{finding.line}: {finding.message}", file=sys.stderr)
    if findings:
        print(f"{len(findings)} dependency boundary violation(s)", file=sys.stderr)
        return 1
    print("Desktop dependency boundaries passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
