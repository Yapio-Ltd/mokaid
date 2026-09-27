"""The renderer audit must catch stale nested copies, not only top-level pins."""

import importlib.util
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location(
    "verify_blender_python", ROOT / "infra/docker/verify_blender_python.py"
)
security = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(security)


def metadata(root, name, version, *, vendor=False, suffix=""):
    directory = root / "setuptools/_vendor" if vendor else root
    directory = directory / f"{name}-{version}{suffix}.dist-info"
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / "METADATA"
    path.write_text(f"Metadata-Version: 2.1\nName: {name}\nVersion: {version}\n")
    return path


def patched_inventory(root):
    return {
        name: metadata(root, name, version, vendor=name in ("jaraco-context", "wheel"))
        for name, version in security.EXPECTED.items()
    }


def test_accepts_complete_patched_direct_and_vendored_inventory(tmp_path):
    patched_inventory(tmp_path)
    metadata(tmp_path, "unrelated", "1.0.0")
    assert security.verify_inventory(tmp_path) == security.EXPECTED


@pytest.mark.parametrize("name", security.EXPECTED)
def test_rejects_a_stale_copy_even_with_the_patched_version_present(tmp_path, name):
    patched_inventory(tmp_path)
    metadata(tmp_path, name, "0.0.1", vendor=True, suffix="-stale")
    with pytest.raises(RuntimeError, match="Unexpected .* version"):
        security.verify_inventory(tmp_path)


@pytest.mark.parametrize("name", security.EXPECTED)
def test_rejects_missing_metadata_instead_of_hiding_a_distribution(tmp_path, name):
    files = patched_inventory(tmp_path)
    files[name].unlink()
    with pytest.raises(RuntimeError, match="Missing package metadata"):
        security.verify_inventory(tmp_path)


def test_accepts_pypi_normalized_jaraco_distribution_name(tmp_path):
    files = patched_inventory(tmp_path)
    files["jaraco-context"].write_text("Name: jaraco.context\nVersion: 6.1.0\n")
    assert security.verify_inventory(tmp_path)["jaraco-context"] == "6.1.0"
