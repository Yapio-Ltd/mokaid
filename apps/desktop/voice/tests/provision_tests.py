#!/usr/bin/env python3
import importlib.util
import io
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest

source = Path(__file__).resolve().parents[1] / "provision.py"
spec = importlib.util.spec_from_file_location("voice_provision", source)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class ProvisionTests(unittest.TestCase):
    def test_every_remote_asset_has_sha256(self):
        for url, checksum in [module.WHISPER_SOURCE, module.WHISPER_MODEL, module.KOKORO_MODEL, *module.LICENSES.values()]:
            self.assertTrue(url.startswith("https://"))
            self.assertEqual(len(checksum), 64)
            int(checksum, 16)
        for filename, checksum in module.SHERPA.values():
            self.assertIn("1.13.8", filename)
            self.assertEqual(len(checksum), 64)

    def test_cache_is_verified_before_reuse(self):
        with tempfile.TemporaryDirectory() as temp:
            cache = Path(temp)
            fixture = cache / "fixture"
            fixture.write_bytes(b"test-model")
            digest = module.sha256(fixture)
            fixture.rename(cache / digest)
            self.assertEqual(module.download(("https://invalid.example/no-network-expected", digest), cache), cache / digest)

    def test_tar_traversal_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            archive = root / "bad.tar"
            with tarfile.open(archive, "w") as tar:
                member = tarfile.TarInfo("../../escape")
                member.size = 4
                tar.addfile(member, io.BytesIO(b"evil"))
            with self.assertRaises(tarfile.FilterError):
                module.extract(archive, root / "extract")
            self.assertFalse((root.parent / "escape").exists())

    def test_external_symlink_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            archive = root / "bad.tar"
            with tarfile.open(archive, "w") as tar:
                member = tarfile.TarInfo("root/link")
                member.type = tarfile.SYMTYPE
                member.linkname = "/etc/passwd"
                tar.addfile(member)
            with self.assertRaises(tarfile.FilterError):
                module.extract(archive, root / "extract")

if __name__ == "__main__": unittest.main()
