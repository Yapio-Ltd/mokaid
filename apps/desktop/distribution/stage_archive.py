"""Transfer an unsigned native stage to a separate signer without executing it.

The manifest digest is passed through the exact build job's GitHub outputs. The
artifact carries no build scripts: the signer runs this tool from reviewed source.
"""

from __future__ import annotations

import argparse
import base64
import gzip
import hashlib
import json
import os
import re
import shutil
import stat
import tarfile
import tempfile
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path, PurePosixPath
from typing import Any

HERE = Path(__file__).resolve().parent
REPOSITORY = "Yapio-Ltd/mokaid"
ARCHIVE = "stage.tar.gz"
MANIFEST = "stage-manifest.json"
MAX_FILES = 100_000
MAX_BYTES = 12 * 1024**3
MAX_ARCHIVE_BYTES = 8 * 1024**3
MAX_MANIFEST_BYTES = 32 * 1024**2
PLATFORMS = {"macos-arm64", "windows-x64"}


class LimitedGzip(gzip.GzipFile):
    """Bound header allocation/seek before tarfile parses untrusted metadata."""

    def read(self, size: int | None = -1) -> bytes:
        require(
            size is not None and 0 <= size <= 1024 * 1024, "Oversized tar metadata read"
        )
        assert size is not None
        return super().read(size)

    def seek(self, offset: int, whence: int = 0) -> int:
        if offset == 0 and whence == 1:  # GzipFile.tell() delegates here.
            return super().seek(offset, whence)
        require(
            whence == 0 and 0 <= offset <= MAX_BYTES + MAX_FILES * 4096,
            "Oversized tar seek",
        )
        return super().seek(offset, whence)


@contextmanager
def open_archive(path: Path) -> Iterator[tarfile.TarFile]:
    with LimitedGzip(path, "rb") as compressed, tarfile.open(
        fileobj=compressed, mode="r:"
    ) as source:
        yield source


class ArchiveError(ValueError):
    """An input failed the unsigned-to-signer trust boundary."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ArchiveError(message)


def canonical(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def public_key(channel: str, key_file: Path = HERE / "update-public-keys.json") -> str:
    require(channel in ("stable", "beta"), "Unknown release channel")
    document = json.loads(key_file.read_text(encoding="utf-8"))
    require(
        isinstance(document, dict)
        and set(document) == {"schemaVersion", "stable", "beta"},
        "Invalid public-key document",
    )
    require(
        type(document["schemaVersion"]) is int and document["schemaVersion"] == 1,
        "Unsupported public-key schema",
    )
    value = document[channel]
    require(
        isinstance(value, str),
        "Release public key is not initialized; unsigned public releases are forbidden",
    )
    assert isinstance(value, str)
    try:
        decoded = base64.b64decode(value, validate=True)
    except ValueError as error:
        raise ArchiveError("Malformed public update key") from error
    require(
        len(decoded) == 32 and base64.b64encode(decoded).decode() == value,
        "Expected canonical 32-byte public update key",
    )
    return value


def checked_identity(args: argparse.Namespace) -> dict[str, str | int]:
    require(args.platform in PLATFORMS, "Unknown platform")
    pattern = r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-beta\.(0|[1-9]\d*))?"
    require(re.fullmatch(pattern, args.version) is not None, "Invalid release version")
    require(
        args.channel == ("beta" if "-beta." in args.version else "stable"),
        "Version/channel mismatch",
    )
    require(
        re.fullmatch(r"[0-9a-f]{40}", args.commit) is not None, "Invalid source commit"
    )
    require(
        re.fullmatch(r"[0-9a-f]{40}", args.tooling_sha) is not None,
        "Invalid trusted-tooling commit",
    )
    require(
        re.fullmatch(r"[1-9]\d{0,19}", args.run_id) is not None, "Invalid GitHub run id"
    )
    require(
        re.fullmatch(r"[1-9]\d{0,9}", args.run_attempt) is not None,
        "Invalid GitHub run attempt",
    )
    key = public_key(args.channel, args.key_file)
    if args.public_key is not None:
        require(
            args.public_key == key,
            "Signing environment public key differs from reviewed source",
        )
    return {
        "schemaVersion": 1,
        "repository": REPOSITORY,
        "platform": args.platform,
        "version": args.version,
        "channel": args.channel,
        "commit": args.commit,
        "toolingSha": args.tooling_sha,
        "runId": args.run_id,
        "runAttempt": args.run_attempt,
        "publicKey": key,
    }


def safe_path(value: Any) -> str:
    require(
        isinstance(value, str) and bool(value) and len(value) <= 1024,
        "Invalid archive path",
    )
    assert isinstance(value, str)
    require(
        "\\" not in value and ":" not in value and "\x00" not in value,
        "Unsafe archive path",
    )
    parts = value.split("/")
    require(
        all(part not in ("", ".", "..") for part in parts),
        "Archive path traversal or noncanonical path",
    )
    reserved = {"con", "prn", "aux", "nul"} | {
        f"{prefix}{index}" for prefix in ("com", "lpt") for index in range(1, 10)
    }
    require(
        all(
            not part.endswith((".", " "))
            and part.split(".", 1)[0].casefold() not in reserved
            for part in parts
        ),
        "Windows device or noncanonical path",
    )
    require(
        not any(any(ord(char) < 32 for char in part) for part in parts),
        "Control character in archive path",
    )
    return value


def link_target(path: str, value: Any) -> str:
    require(
        isinstance(value, str) and bool(value) and len(value) <= 1024,
        "Invalid symlink target",
    )
    require(
        not value.startswith("/")
        and "\\" not in value
        and ":" not in value
        and "\x00" not in value,
        "Absolute or unsafe symlink target",
    )
    parts = list(PurePosixPath(path).parent.parts)
    for part in value.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            require(bool(parts), "Symlink target escapes stage")
            parts.pop()
        else:
            safe_path(part)
            parts.append(part)
    require(bool(parts), "Symlink cannot replace stage root")
    return "/".join(parts)


def validate_table(table: Any) -> dict[str, dict[str, Any]]:
    require(
        isinstance(table, list) and 0 < len(table) <= MAX_FILES,
        "Invalid or oversized file table",
    )
    result: dict[str, dict[str, Any]] = {}
    folded: set[str] = set()
    total = 0
    for item in table:
        require(isinstance(item, dict), "Invalid file record")
        path = safe_path(item.get("path"))
        require(path.casefold() not in folded, "Duplicate/case-colliding archive paths")
        folded.add(path.casefold())
        kind = item.get("type")
        extras = (
            {"size", "sha256"}
            if kind == "file"
            else {"target"} if kind == "symlink" else set()
        )
        require(
            kind in ("file", "directory", "symlink")
            and set(item) == {"path", "type", "mode"} | extras,
            "Unexpected file record fields/type",
        )
        mode = item["mode"]
        require(type(mode) is int and 0 <= mode <= 0o777, "Unsafe file permissions")
        if kind == "file":
            require(
                type(item["size"]) is int and 0 <= item["size"] <= MAX_BYTES,
                "Invalid file size",
            )
            require(
                isinstance(item["sha256"], str)
                and re.fullmatch(r"[a-f0-9]{64}", item["sha256"]) is not None,
                "Invalid file digest",
            )
            total += item["size"]
        elif kind == "symlink":
            link_target(path, item["target"])
        result[path] = item
    require(total <= MAX_BYTES, "Unpacked stage exceeds size budget")
    for path, item in result.items():
        for parent in PurePosixPath(path).parents:
            if str(parent) != ".":
                require(
                    str(parent) in result
                    and result[str(parent)]["type"] == "directory",
                    "File descends through absent or symlink parent",
                )
        if item["type"] == "symlink":
            target = link_target(path, item["target"])
            seen = {path}
            # Resolve intermediate framework aliases as well as direct chains.
            while True:
                parts = target.split("/")
                replaced = False
                for index in range(1, len(parts) + 1):
                    prefix = "/".join(parts[:index])
                    require(prefix in result, "Dangling symlink target")
                    entry = result[prefix]
                    if entry["type"] == "symlink":
                        require(prefix not in seen, "Symlink cycle")
                        seen.add(prefix)
                        target = link_target(prefix, entry["target"])
                        if index < len(parts):
                            target += "/" + "/".join(parts[index:])
                        replaced = True
                        break
                    require(
                        index == len(parts) or entry["type"] == "directory",
                        "Symlink target has non-directory parent",
                    )
                if not replaced:
                    break
    return result


def inventory(stage: Path) -> list[dict[str, Any]]:
    require(
        stage.is_dir() and not stage.is_symlink(), "Missing or symlink stage directory"
    )
    table: list[dict[str, Any]] = []
    for directory, dirs, files in os.walk(stage, followlinks=False):
        for name in sorted(dirs + files):
            path = Path(directory) / name
            info = path.lstat()
            kind = (
                "symlink"
                if stat.S_ISLNK(info.st_mode)
                else (
                    "directory"
                    if stat.S_ISDIR(info.st_mode)
                    else "file" if stat.S_ISREG(info.st_mode) else "unsupported"
                )
            )
            require(not info.st_mode & 0o7000, "Special permission bits in stage")
            item: dict[str, Any] = {
                "path": path.relative_to(stage).as_posix(),
                "type": kind,
                "mode": stat.S_IMODE(info.st_mode),
            }
            if kind == "symlink":
                item["target"] = os.readlink(path)
            elif kind == "file":
                item.update(size=info.st_size, sha256=sha256(path))
            table.append(item)
            require(len(table) <= MAX_FILES, "Too many staged files")
    table.sort(key=lambda item: item["path"])
    validate_table(table)
    return table


def verify_archive(archive: Path, table: dict[str, dict[str, Any]]) -> None:
    require(
        archive.is_file()
        and not archive.is_symlink()
        and archive.stat().st_size <= MAX_ARCHIVE_BYTES,
        "Missing or oversized archive",
    )
    observed: set[str] = set()
    with open_archive(archive) as source:
        for member in source:
            path = safe_path(member.name)
            require(
                path in table and path not in observed,
                "Unexpected/duplicate archive entry",
            )
            observed.add(path)
            item = table[path]
            kind = (
                "file"
                if member.isfile()
                else (
                    "directory"
                    if member.isdir()
                    else "symlink" if member.issym() else "unsupported"
                )
            )
            require(
                kind == item["type"] and member.mode == item["mode"],
                "Archive type/mode mismatch",
            )
            require(not member.pax_headers, "Extended tar metadata is not permitted")
            if kind == "file":
                require(member.size == item["size"], "Archive size mismatch")
                stream = source.extractfile(member)
                require(stream is not None, "Missing file bytes")
                digest = hashlib.sha256()
                assert stream is not None
                with stream:
                    while chunk := stream.read(1024 * 1024):
                        digest.update(chunk)
                require(
                    digest.hexdigest() == item["sha256"], "File content digest mismatch"
                )
            elif kind == "symlink":
                require(member.linkname == item["target"], "Symlink mismatch")
            else:
                require(member.size == 0, "Directory carries unexpected data")
    require(observed == set(table), "Archive file table is incomplete")


def create(args: argparse.Namespace) -> str:
    identity = checked_identity(args)
    table = inventory(args.stage)
    args.output.mkdir(parents=True, exist_ok=True)
    archive, manifest = args.output / ARCHIVE, args.output / MANIFEST
    require(
        not archive.exists() and not manifest.exists(), "Archive output already exists"
    )
    with tarfile.open(
        archive, "w:gz", format=tarfile.GNU_FORMAT, dereference=False
    ) as target:
        for item in table:
            info = tarfile.TarInfo(item["path"])
            info.mode, info.mtime, info.uid, info.gid = item["mode"], 0, 0, 0
            if item["type"] == "directory":
                info.type = tarfile.DIRTYPE
                target.addfile(info)
            elif item["type"] == "symlink":
                info.type, info.linkname = tarfile.SYMTYPE, item["target"]
                target.addfile(info)
            else:
                info.size = item["size"]
                with (args.stage / item["path"]).open("rb") as source:
                    target.addfile(info, source)
    verify_archive(archive, validate_table(table))
    document = {
        **identity,
        "archive": ARCHIVE,
        "archiveSha256": sha256(archive),
        "files": table,
    }
    manifest.write_bytes(canonical(document) + b"\n")
    require(
        manifest.stat().st_size <= MAX_MANIFEST_BYTES, "Manifest exceeds size budget"
    )
    digest = sha256(manifest)
    if os.environ.get("GITHUB_OUTPUT"):
        with Path(os.environ["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as output:
            output.write(f"manifest_sha256={digest}\n")
    return digest


def restore(args: argparse.Namespace) -> None:
    identity = checked_identity(args)
    require(
        args.public_key is not None, "Signing environment public key must be supplied"
    )
    manifest, archive = args.input / MANIFEST, args.input / ARCHIVE
    require(
        re.fullmatch(r"[a-f0-9]{64}", args.manifest_sha256) is not None,
        "Invalid expected manifest digest",
    )
    require(
        manifest.is_file()
        and not manifest.is_symlink()
        and manifest.stat().st_size <= MAX_MANIFEST_BYTES,
        "Invalid manifest",
    )
    require(
        sha256(manifest) == args.manifest_sha256,
        "Manifest digest differs from exact build-job output",
    )
    document = json.loads(manifest.read_text(encoding="utf-8"))
    require(
        isinstance(document, dict)
        and set(document) == set(identity) | {"archive", "archiveSha256", "files"},
        "Unexpected manifest fields",
    )
    require(
        all(document[key] == value for key, value in identity.items()),
        "Artifact identity does not match exact run/platform/version/source",
    )
    require(document["archive"] == ARCHIVE, "Unexpected archive filename")
    require(
        archive.is_file()
        and not archive.is_symlink()
        and archive.stat().st_size <= MAX_ARCHIVE_BYTES,
        "Invalid archive",
    )
    require(sha256(archive) == document["archiveSha256"], "Archive digest mismatch")
    table = validate_table(document["files"])
    verify_archive(archive, table)  # Validate every member and byte before extraction.
    require(
        not args.stage.exists() and not args.stage.is_symlink(),
        "Restore target must not exist",
    )
    args.stage.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix="mokaid-stage-import-", dir=args.stage.parent
    ) as temp:
        destination = Path(temp) / "stage"
        destination.mkdir()
        for path, item in sorted(
            table.items(), key=lambda pair: len(PurePosixPath(pair[0]).parts)
        ):
            if item["type"] == "directory":
                (destination / path).mkdir()
        with open_archive(archive) as source:
            for member in source:
                item, output_path = table[member.name], destination / member.name
                if item["type"] == "file":
                    stream = source.extractfile(member)
                    require(stream is not None, "Missing extracted file bytes")
                    assert stream is not None
                    with stream, output_path.open("xb") as target:
                        shutil.copyfileobj(stream, target, 1024 * 1024)
                    output_path.chmod(item["mode"])
        # Links are created last, so none can redirect a file write.
        for path, item in table.items():
            if item["type"] == "symlink":
                (destination / path).symlink_to(item["target"])
        for path, item in sorted(
            table.items(), key=lambda pair: -len(PurePosixPath(pair[0]).parts)
        ):
            if item["type"] == "directory":
                (destination / path).chmod(item["mode"])
        require(
            inventory(destination) == document["files"],
            "Restored stage differs from verified inventory",
        )
        destination.rename(args.stage)
    # Reconstruct only package/SBOM metadata; never import arbitrary ci.json paths.
    config = {
        "platform": args.platform,
        "version": args.version,
        "channel": args.channel,
    }
    (args.stage.parent / "ci.json").write_bytes(canonical(config) + b"\n")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    commands = result.add_subparsers(dest="command", required=True)
    key = commands.add_parser("public-key")
    key.add_argument("--channel", required=True, choices=("stable", "beta"))
    key.add_argument("--key-file", type=Path, default=HERE / "update-public-keys.json")
    for command in ("create", "restore"):
        item = commands.add_parser(command)
        for option in (
            "platform",
            "version",
            "channel",
            "commit",
            "tooling-sha",
            "run-id",
            "run-attempt",
        ):
            item.add_argument(f"--{option}", required=True)
        item.add_argument(
            "--key-file", type=Path, default=HERE / "update-public-keys.json"
        )
        item.add_argument("--public-key")
        item.add_argument("--stage", required=True, type=Path)
        if command == "create":
            item.add_argument("--output", required=True, type=Path)
        else:
            item.add_argument("--input", required=True, type=Path)
            item.add_argument("--manifest-sha256", required=True)
    return result


if __name__ == "__main__":
    arguments = parser().parse_args()
    try:
        if arguments.command == "public-key":
            print(public_key(arguments.channel, arguments.key_file))
        elif arguments.command == "create":
            print(create(arguments))
        else:
            restore(arguments)
    except (ArchiveError, OSError, tarfile.TarError, json.JSONDecodeError) as error:
        raise SystemExit(f"Stage transfer refused: {error}") from error
