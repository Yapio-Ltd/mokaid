"""The native light generator must not depend on the Windows ANSI code page."""
import json
from pathlib import Path
import runpy
import sys
import tempfile
import unittest
from unittest.mock import patch


GENERATOR = Path(__file__).resolve().parents[2] / "renderer/tools/generate_lighting.py"


class LightingGenerationTests(unittest.TestCase):
    def test_utf8_manifest_and_light_names_survive_cp1252_defaults(self):
        name = "Lampe \u201cR\u00e9union \u05e9\u05dc\u05d5\u05dd\u201d"
        lights = [{"name": name if index == 0 else f"Area.{index:03}",
                   "type": "AREA", "position": {"x": 1, "y": 2, "z": 3},
                   "color": {"r": 1, "g": 0.5, "b": 0.25}, "energy": 10}
                  for index in range(16)]
        manifest = "// UTF-8 documentation: \u201c\u00e9clairage\u201d\nexport const OFFICE_LIGHTS = " + json.dumps(lights, ensure_ascii=False) + ";\n"
        # Reproduce the exact class of failure on an otherwise UTF-8 host:
        # unspecified text encodings use the Windows cp1252 ANSI code page.
        original_open = Path.open

        def windows_ansi_open(path, mode="r", buffering=-1, encoding=None, errors=None, newline=None):
            if "b" not in mode and encoding in (None, "locale"):
                encoding = "cp1252"
            return original_open(path, mode, buffering, encoding, errors, newline)

        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "office-lighting.ts"
            output = Path(directory) / "generated/office_lighting.hpp"
            source.write_bytes(manifest.encode("utf-8"))
            # Ensure this fixture really detects the original Windows failure.
            with self.assertRaises(UnicodeDecodeError):
                source.read_bytes().decode("cp1252")
            with patch.object(Path, "open", windows_ansi_open), patch.object(
                    sys, "argv", [str(GENERATOR), str(source), str(output)]):
                runpy.run_path(str(GENERATOR), run_name="__main__")
            generated = output.read_bytes()
            self.assertIn(("// " + name).encode("utf-8"), generated)
            self.assertIn("std::array<OfficeLight, 16>", generated.decode("utf-8"))
            self.assertNotIn(b"\r\n", generated)


if __name__ == "__main__":
    unittest.main()
