from __future__ import annotations

import argparse
import base64
import gzip
import io
import json
import os
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1]))
import stage_archive as archive


class StageArchiveTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="mokaid-stage-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.stage = self.root / "original"
        self.stage.mkdir()
        (self.stage / "Mokaid.exe").write_bytes(b"MZ unsigned fixture never executed")
        (self.stage / "Mokaid.exe").chmod(0o755)
        (self.stage / "resources").mkdir()
        (self.stage / "resources/data.bin").write_bytes(bytes(range(256)))
        self.key = base64.b64encode(bytes(range(32))).decode()
        self.key_file = self.root / "public-keys.json"
        self.key_file.write_text(
            json.dumps({"schemaVersion": 1, "stable": self.key, "beta": self.key})
        )
        self.args = argparse.Namespace(
            platform="windows-x64",
            version="1.2.3",
            channel="stable",
            commit="a" * 40,
            tooling_sha="b" * 40,
            run_id="123456",
            run_attempt="1",
            key_file=self.key_file,
            public_key=self.key,
            stage=self.stage,
            output=self.root / "artifact",
        )

    def packed(self) -> argparse.Namespace:
        digest = archive.create(self.args)
        return argparse.Namespace(
            **{
                **vars(self.args),
                "input": self.args.output,
                "stage": self.root / "restore/stage",
                "manifest_sha256": digest,
            }
        )

    def rewrite_manifest(self, args: argparse.Namespace, mutate) -> None:
        path = args.input / archive.MANIFEST
        document = json.loads(path.read_text())
        mutate(document)
        path.write_bytes(archive.canonical(document))
        args.manifest_sha256 = archive.sha256(path)

    def test_roundtrip_preserves_file_bytes_permissions_and_minimal_ci_config(
        self,
    ) -> None:
        args = self.packed()
        archive.restore(args)
        self.assertEqual(archive.inventory(self.stage), archive.inventory(args.stage))
        self.assertEqual(
            json.loads((args.stage.parent / "ci.json").read_text()),
            {"platform": "windows-x64", "version": "1.2.3", "channel": "stable"},
        )
        self.assertEqual(
            (args.stage / "Mokaid.exe").read_bytes(),
            (self.stage / "Mokaid.exe").read_bytes(),
        )

    @unittest.skipIf(
        os.name == "nt", "Windows distribution has no framework symlink requirement"
    )
    def test_macos_framework_aliases_and_executable_modes_survive(self) -> None:
        framework = self.stage / "Mokaid.app/Contents/Frameworks/QtCore.framework"
        (framework / "Versions/A").mkdir(parents=True)
        (framework / "Versions/A/QtCore").write_bytes(b"native fixture")
        (framework / "Versions/A/QtCore").chmod(0o755)
        (framework / "Versions/Current").symlink_to("A")
        (framework / "QtCore").symlink_to("Versions/Current/QtCore")
        self.args.platform = "macos-arm64"
        args = self.packed()
        archive.restore(args)
        self.assertEqual(archive.inventory(self.stage), archive.inventory(args.stage))
        restored = args.stage / framework.relative_to(self.stage)
        self.assertTrue((restored / "Versions/Current").is_symlink())
        self.assertEqual(os.readlink(restored / "QtCore"), "Versions/Current/QtCore")
        self.assertEqual((restored / "QtCore").stat().st_mode & 0o777, 0o755)

    @unittest.skipUnless(
        os.environ.get("MOKAID_STAGE_ROUNDTRIP_FIXTURE"),
        "Optional local real-bundle transfer check",
    )
    def test_real_bundle_roundtrip_without_execution_or_signature(self) -> None:
        self.args.stage = Path(os.environ["MOKAID_STAGE_ROUNDTRIP_FIXTURE"])
        self.args.platform = "macos-arm64"
        args = self.packed()
        archive.restore(args)
        self.assertEqual(
            archive.inventory(self.args.stage), archive.inventory(args.stage)
        )

    def test_output_records_the_exact_manifest_digest(self) -> None:
        output = self.root / "github-output"
        with patch.dict(os.environ, {"GITHUB_OUTPUT": str(output)}):
            args = self.packed()
        self.assertEqual(
            output.read_text(), f"manifest_sha256={args.manifest_sha256}\n"
        )

    def test_create_and_restore_refuse_overwriting_existing_targets(self) -> None:
        args = self.packed()
        with self.assertRaisesRegex(archive.ArchiveError, "already exists"):
            archive.create(self.args)
        args.stage.mkdir(parents=True)
        with self.assertRaisesRegex(archive.ArchiveError, "must not exist"):
            archive.restore(args)

    def test_manifest_and_archive_corruption_refused_before_extract(self) -> None:
        args = self.packed()
        with self.subTest("manifest"):
            expected = args.manifest_sha256
            args.manifest_sha256 = "0" * 64
            with self.assertRaisesRegex(archive.ArchiveError, "Manifest digest"):
                archive.restore(args)
            args.manifest_sha256 = expected
        with (args.input / archive.ARCHIVE).open("ab") as output:
            output.write(b"corruption")
        with self.assertRaisesRegex(archive.ArchiveError, "Archive digest"):
            archive.restore(args)
        self.assertFalse(args.stage.exists())

    def test_cross_run_attempt_platform_commit_and_tooling_mixups_refused(self) -> None:
        args = self.packed()
        for field, value in (
            ("run_id", "999999"),
            ("run_attempt", "2"),
            ("platform", "macos-arm64"),
            ("commit", "c" * 40),
            ("tooling_sha", "d" * 40),
            ("version", "1.2.4"),
        ):
            with self.subTest(field=field):
                mutated = argparse.Namespace(**{**vars(args), field: value})
                with self.assertRaisesRegex(archive.ArchiveError, "identity"):
                    archive.restore(mutated)
                self.assertFalse(args.stage.exists())

    def test_expected_signing_key_matches_versioned_key(self) -> None:
        args = self.packed()
        args.public_key = base64.b64encode(b"x" * 32).decode()
        with self.assertRaisesRegex(archive.ArchiveError, "differs"):
            archive.restore(args)
        args.public_key = None
        with self.assertRaisesRegex(archive.ArchiveError, "must be supplied"):
            archive.restore(args)

    def test_key_file_null_malformed_wrong_length_unknown_fields_and_schema_fail(
        self,
    ) -> None:
        documents = [
            {"schemaVersion": 1, "stable": value, "beta": None}
            for value in (None, "!", "eA==", 3)
        ]
        documents += [
            {"schemaVersion": True, "stable": self.key, "beta": self.key},
            {
                "schemaVersion": 1,
                "stable": self.key,
                "beta": self.key,
                "privateKey": "no",
            },
        ]
        for document in documents:
            with self.subTest(document=document):
                self.key_file.write_text(json.dumps(document))
                with self.assertRaises(archive.ArchiveError):
                    archive.public_key("stable", self.key_file)

    def test_beta_channel_identity_and_cli_arguments(self) -> None:
        self.args.version, self.args.channel = "1.2.3-beta.2", "beta"
        self.assertEqual(archive.checked_identity(self.args)["channel"], "beta")
        self.assertEqual(
            archive.parser().parse_args(["public-key", "--channel", "beta"]).command,
            "public-key",
        )
        for field, value in (
            ("version", "1.2.3;echo bad"),
            ("commit", "main"),
            ("tooling_sha", "prod"),
            ("run_id", "../123"),
            ("run_attempt", "0"),
            ("platform", "linux"),
            ("channel", "stable"),
        ):
            with self.subTest(field=field), self.assertRaises(archive.ArchiveError):
                archive.checked_identity(
                    argparse.Namespace(**{**vars(self.args), field: value})
                )

    def test_traversal_windows_paths_control_characters_and_aliases_refused(
        self,
    ) -> None:
        for value in (
            "../x",
            "/x",
            "a//x",
            "./x",
            "a/../x",
            "C:/x",
            "a\\x",
            "nul\x00",
            "a\nx",
            "NUL",
            "a/aux.txt",
            "com1",
            "a. ",
        ):
            with self.subTest(value=value), self.assertRaises(archive.ArchiveError):
                archive.safe_path(value)
        for value in ("/outside", "../../outside", "C:/outside", ".."):
            with self.subTest(value=value), self.assertRaises(archive.ArchiveError):
                archive.link_target("a", value)

    def test_malicious_table_types_modes_sizes_duplicates_and_link_parents_refused(
        self,
    ) -> None:
        directory = {"path": "a", "type": "directory", "mode": 0o755}
        file = {
            "path": "a/b",
            "type": "file",
            "mode": 0o644,
            "size": 1,
            "sha256": "0" * 64,
        }
        cases = [
            [directory, directory],
            [directory, {**directory, "path": "A"}],
            [{**directory, "mode": 0o4755}],
            [{**file, "size": -1}],
            [{**directory, "type": "hardlink"}],
            [{**file, "sha256": "invalid"}],
            [file],
            [{**directory, "extra": "unknown"}],
            [{"path": "a", "type": "symlink", "mode": 0o777, "target": "z"}, file],
            [{"path": "a", "type": "symlink", "mode": 0o777, "target": "a"}],
            [{"path": "a", "type": "symlink", "mode": 0o777, "target": "missing"}],
        ]
        for table in cases:
            with self.subTest(table=table), self.assertRaises(archive.ArchiveError):
                archive.validate_table(table)
        with patch.object(archive, "MAX_BYTES", 0), self.assertRaisesRegex(
            archive.ArchiveError, "size"
        ):
            archive.validate_table([directory, file])

    def test_file_hash_is_checked_even_when_archive_digest_matches(self) -> None:
        args = self.packed()
        self.rewrite_manifest(args, lambda d: d["files"][0].update(sha256="f" * 64))
        with self.assertRaisesRegex(archive.ArchiveError, "File content digest"):
            archive.restore(args)
        self.assertFalse(args.stage.exists())

    def test_tar_extra_entry_and_hardlink_rejected_before_any_write(self) -> None:
        for kind in (tarfile.LNKTYPE, tarfile.CHRTYPE, tarfile.REGTYPE):
            with self.subTest(kind=kind):
                output = self.root / f"malicious-{kind.hex()}.tar.gz"
                with tarfile.open(output, "w:gz") as target:
                    info = tarfile.TarInfo("evil")
                    info.type, info.mode = kind, 0o644
                    info.linkname = "/outside"
                    target.addfile(info, io.BytesIO(b""))
                table = {
                    "evil": {
                        "path": "evil",
                        "type": "file",
                        "mode": 0o644,
                        "size": 0,
                        "sha256": "0" * 64,
                    }
                }
                with self.assertRaises(archive.ArchiveError):
                    archive.verify_archive(output, table)
                with self.assertRaisesRegex(archive.ArchiveError, "Unexpected"):
                    archive.verify_archive(output, {})

    def test_oversize_and_unknown_manifest_fields_rejected(self) -> None:
        args = self.packed()
        with patch.object(archive, "MAX_MANIFEST_BYTES", 1), self.assertRaisesRegex(
            archive.ArchiveError, "manifest"
        ):
            archive.restore(args)
        with patch.object(archive, "MAX_ARCHIVE_BYTES", 1), self.assertRaisesRegex(
            archive.ArchiveError, "archive"
        ):
            archive.restore(args)
        self.rewrite_manifest(args, lambda d: d.update(command="do not execute"))
        with self.assertRaisesRegex(archive.ArchiveError, "Unexpected manifest"):
            archive.restore(args)

    def test_tar_metadata_header_cannot_request_unbounded_allocation(self) -> None:
        path = self.root / "oversized-header.tar.gz"
        info = tarfile.TarInfo("././@LongLink")
        info.type, info.size = tarfile.GNUTYPE_LONGNAME, 2 * 1024**3
        with gzip.open(path, "wb") as stream:
            stream.write(info.tobuf(format=tarfile.GNU_FORMAT))
        with self.assertRaisesRegex(archive.ArchiveError, "metadata read"):
            archive.verify_archive(path, {})

    @unittest.skipIf(os.name == "nt", "POSIX symlinks and special permissions")
    def test_export_refuses_escaping_links_and_privileged_modes(self) -> None:
        link = self.stage / "outside"
        link.symlink_to("../../outside")
        with self.assertRaisesRegex(archive.ArchiveError, "escapes"):
            archive.inventory(self.stage)
        link.unlink()
        original_lstat = Path.lstat

        def special_mode(path):
            info = original_lstat(path)
            if path == self.stage / "Mokaid.exe":
                return SimpleNamespace(
                    st_mode=info.st_mode | 0o4000, st_size=info.st_size
                )
            return info

        # A managed sandbox may strip setuid on chmod; simulate the observed
        # filesystem metadata instead of relying on the host's mount options.
        with patch.object(Path, "lstat", special_mode), self.assertRaisesRegex(
            archive.ArchiveError, "Special permission"
        ):
            archive.inventory(self.stage)


if __name__ == "__main__":
    unittest.main()
