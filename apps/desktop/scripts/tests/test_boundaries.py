from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from check_boundaries import check  # noqa: E402


class BoundariesTest(unittest.TestCase):
    def findings(self, files: dict[str, str]):
        with tempfile.TemporaryDirectory(prefix="mokaid-boundaries-") as directory:
            root = Path(directory)
            for name, text in files.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text, encoding="utf-8")
            return check(root)

    def test_allowed_native_split(self):
        self.assertEqual(self.findings({
            "engine/math.hpp": "#include <array>\n",
            "renderer/metal.mm": "#include <mokaid/engine/math.hpp>\n#import <Metal/Metal.h>\n",
            "bridge/item.cpp": "#include <QQuickItem>\n#include <mokaid/renderer/renderer.hpp>\n",
        }), [])

    def test_qt_and_gpu_cannot_enter_core(self):
        findings = self.findings({"engine/scene.cpp": "#include <QObject>\n#include <d3d12.h>\n"})
        self.assertEqual(len(findings), 2)
        self.assertEqual([finding.line for finding in findings], [1, 2])

    def test_dependency_cannot_point_to_viewmodel(self):
        findings = self.findings({
            "network/http.cpp": "#include <mokaid/application/session_controller.hpp>\n",
            "renderer/CMakeLists.txt": "target_link_libraries(mokaid_renderer PUBLIC mokaid_application)\n",
        })
        self.assertEqual(len(findings), 2)

    def test_private_qt_forbidden_even_in_bridge(self):
        self.assertEqual(len(self.findings({"bridge/bad.cpp": "#include <QtGui/private/qrhi_p.h>\n"})), 1)

    def test_no_qt_renderer_link(self):
        self.assertEqual(len(self.findings({"renderer/CMakeLists.txt": "target_link_libraries(mokaid_renderer PRIVATE Qt6::Quick)\n"})), 1)

    def test_comments_and_generated_builds_ignored(self):
        self.assertEqual(self.findings({
            "engine/example.hpp": "/*\n#include <QObject>\n*/\n// #include <QQuickItem>\n",
            "build/engine/generated.cpp": "#include <QObject>\n",
            "renderer/CMakeLists.txt": "# target_link_libraries(mokaid_renderer Qt6::Quick)\n",
        }), [])

    def test_relative_path_cannot_bypass_layer(self):
        self.assertEqual(len(self.findings({
            "engine/local.cpp": '#include "../application/session.hpp"\n',
        })), 1)


if __name__ == "__main__":
    unittest.main()
