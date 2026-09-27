"""Fast boundary tests; run with Blender --background --python this_file.py."""
import contextlib
import io
import json
from pathlib import Path
import runpy
import struct
import sys
import tempfile
import unittest


MODULE = runpy.run_path(str(Path(__file__).with_name("prepare-custom-avatar.py")))


class PreparationBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="mokaid-preparation-test-")
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "input.glb"
        names = ["Hips"] + sorted(MODULE["REQUIRED"] - {"Hips"})
        self.document = {"asset": {"version": "2.0"}, "meshes": [{}],
                         "nodes": [{"name": name} for name in names],
                         "skins": [{"joints": list(range(len(names)))}]}

    def write(self):
        raw = json.dumps(self.document).encode()
        raw += b" " * (-len(raw) % 4)
        self.path.write_bytes(struct.pack("<4s4I", b"glTF", 2, 20 + len(raw), len(raw), 0x4E4F534A) + raw)

    def test_known_humanoid_passes_boundary_check(self):
        self.write()
        self.assertEqual(len(MODULE["preflight"](self.path)), 64)

    def test_external_resources_are_rejected_before_import(self):
        for uri in ("https://example.test/texture.png", "file:///etc/passwd", "../../private.bin"):
            with self.subTest(uri=uri):
                self.document["images"] = [{"uri": uri}]
                self.write()
                with self.assertRaisesRegex(ValueError, "embed all"):
                    MODULE["preflight"](self.path)

    def test_missing_human_limb_is_rejected(self):
        self.document["nodes"][1]["name"] = "unsupported"
        self.write()
        with self.assertRaisesRegex(ValueError, "standard humanoid"):
            MODULE["preflight"](self.path)

    def test_skin_palette_must_start_at_pelvis(self):
        self.document["skins"][0]["joints"] = self.document["skins"][0]["joints"][::-1]
        self.write()
        with self.assertRaisesRegex(ValueError, "start at its pelvis"):
            MODULE["preflight"](self.path)

    def test_nonfinite_transforms_are_rejected(self):
        self.document["nodes"][0]["translation"] = [0, float("nan"), 0]
        self.write()
        with self.assertRaisesRegex(ValueError, "invalid transforms"):
            MODULE["preflight"](self.path)

    def test_failed_preparation_removes_stale_outputs(self):
        self.document["skins"] = []
        self.write()
        output = Path(self.directory.name) / "output"
        output.mkdir()
        for name in ("model.glb", "portrait.png", "contact-sheet.png"):
            (output / name).write_bytes(b"stale")
        saved = sys.argv
        try:
            sys.argv = ["prepare-custom-avatar.py", "--", "--input", str(self.path), "--output-dir", str(output)]
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as failure:
                MODULE["main"]()
            self.assertEqual(failure.exception.code, 1)
        finally:
            sys.argv = saved
        self.assertEqual(json.loads((output / "manifest.json").read_text())["status"], "failed")
        self.assertFalse((output / "model.glb").exists())
        self.assertFalse((output / "portrait.png").exists())
        self.assertFalse((output / "contact-sheet.png").exists())


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(PreparationBoundaryTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if not result.wasSuccessful():
        raise SystemExit(1)
