"""Keep security-patched runtime stages wired into the shipped images.

These source contracts complement, and never replace, actual image scans and
staging. Version floors must be reviewed together with their upstream fixes.
"""

import re
import unittest
from pathlib import Path

DOCKER = Path(__file__).resolve().parents[3] / "infra" / "docker"


class RuntimeImageContracts(unittest.TestCase):
    def test_web_targets_inherit_the_same_patched_base(self):
        source = (DOCKER / "web.Dockerfile").read_text()
        self.assertRegex(
            source, r"FROM nginx:[^\n]+@sha256:[0-9a-f]{64} AS nginx-runtime"
        )
        self.assertIn("apk add --no-cache --upgrade 'libuuid>=2.42.3-r1'", source)
        self.assertIn("apk info --exists 'libuuid>=2.42.3-r1'", source)
        self.assertIn("FROM nginx-runtime AS runtime-ci", source)
        self.assertIn("FROM nginx-runtime AS runtime\n", source)

    def test_worker_build_and_runtime_share_an_immutable_patched_base(self):
        source = (DOCKER / "ai-worker.Dockerfile").read_text()
        self.assertRegex(
            source, r"FROM python:[^\n]+@sha256:[0-9a-f]{64} AS python-runtime"
        )
        self.assertIn("FROM python-runtime AS build", source)
        self.assertIn("FROM python-runtime AS runtime", source)
        self.assertEqual(len(re.findall(r"^FROM python:", source, re.MULTILINE)), 1)

    def test_worker_rejects_missing_distro_security_fixes(self):
        source = (DOCKER / "ai-worker.Dockerfile").read_text()
        for package, floor in (
            ("gzip", "1.13-1+deb13u1"),
            ("libpcre2-8-0", "10.46-1~deb13u2"),
            ("libsqlite3-0", "3.46.1-7+deb13u2"),
            ("perl-base", "5.40.1-6+deb13u1"),
        ):
            with self.subTest(package=package):
                self.assertIn(
                    "dpkg --compare-versions \"$(dpkg-query -W -f='${Version}' "
                    + package
                    + ")\" ge '"
                    + floor
                    + "'",
                    source,
                )

    def test_worker_removes_only_install_tooling_after_copying_dependencies(self):
        source = (DOCKER / "ai-worker.Dockerfile").read_text()
        copied = source.index("COPY --from=build /install /usr/local")
        removed = source.index("RUN python -m pip uninstall --yes pip")
        unprivileged = source.index("USER mokaid")
        self.assertLess(copied, removed)
        self.assertLess(removed, unprivileged)
        self.assertIn("assert importlib.util.find_spec('pip') is None", source)
        self.assertIn("! command -v pip && ! command -v pip3", source)
        self.assertIn('CMD ["uvicorn", "app.main:app"', source)


if __name__ == "__main__":
    unittest.main()
