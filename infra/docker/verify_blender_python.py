"""Fail the image build if Blender retains a stale direct or vendored package."""

from email.parser import Parser
import importlib
import json
from pathlib import Path
import re
import sysconfig


EXPECTED = {
    "setuptools": "80.10.2",
    "urllib3": "2.8.0",
    "jaraco-context": "6.1.0",
    "wheel": "0.46.3",
}


def verify_inventory(site_packages: Path) -> dict[str, str]:
    found = set()
    # Recurse into setuptools/_vendor: a top-level upgrade can otherwise hide
    # an older private copy that remains executable and vulnerable.
    for path in site_packages.rglob("*.dist-info/METADATA"):
        metadata = Parser().parsestr(path.read_text())
        name = re.sub(r"[-_.]+", "-", metadata.get("Name", "")).lower()
        if name in EXPECTED:
            if metadata.get("Version") != EXPECTED[name]:
                raise RuntimeError(f"Unexpected {name} version in {path}")
            found.add(name)
    missing = EXPECTED.keys() - found
    if missing:
        raise RuntimeError("Missing package metadata: " + ", ".join(sorted(missing)))
    return dict(EXPECTED)


def main() -> None:
    site_packages = Path(sysconfig.get_path("purelib")).resolve()
    inventory = verify_inventory(site_packages)
    for name in ("setuptools", "urllib3", "wheel", "jaraco.context"):
        module = importlib.import_module(name)
        source = Path(module.__file__).resolve()
        parent = site_packages / "setuptools" / "_vendor" if name in ("wheel", "jaraco.context") else site_packages
        if not source.is_relative_to(parent):
            raise RuntimeError(f"Unexpected import location for {name}")
        if name != "jaraco.context" and module.__version__ != EXPECTED[name]:
            raise RuntimeError(f"Imported {name} version does not match metadata")
    print("Verified Blender Python packages: " + json.dumps(inventory, sort_keys=True))


if __name__ == "__main__":
    main()
