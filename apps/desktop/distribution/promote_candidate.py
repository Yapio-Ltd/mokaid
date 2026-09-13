#!/usr/bin/env python3
"""Promote an existing GitHub candidate; never rebuild or re-sign it."""
import json
import os
from pathlib import Path
import sys
from release import check_version, required_env, require, run, validate_readiness, promote
from argparse import Namespace


def inputs() -> tuple[str, str, str]:
    tag = required_env("RELEASE_TAG")
    require(tag.startswith("desktop-v"), "Only desktop-v release tags can be promoted")
    version = tag.removeprefix("desktop-v")
    channel = required_env("RELEASE_CHANNEL")
    require(channel in ("stable", "beta"), "Unknown release channel")
    check_version(version, channel)
    return tag, version, channel


if __name__ == "__main__":
    tag, version, channel = inputs()
    artifacts = Path("artifacts").resolve()
    require(len(sys.argv) == 2 and sys.argv[1] in ("prepare", "publish"), "Expected prepare or publish")
    if sys.argv[1] == "prepare":
        require(not artifacts.exists(), "Candidate destination must be empty")
        candidate = json.loads(run("gh", "release", "view", tag, "--repo", "Yapio-Ltd/mokaid",
                                  "--json", "tagName,isDraft,assets", capture=True))
        require(candidate["tagName"] == tag, "Candidate tag mismatch")
        run("gh", "release", "download", tag, "--repo", "Yapio-Ltd/mokaid", "--dir", artifacts)
        validate_readiness(artifacts, version, channel)
    else:
        validate_readiness(artifacts, version, channel)
        # Publish the release notes before a native client can discover the feed.
        run("gh", "release", "edit", tag, "--repo", "Yapio-Ltd/mokaid", "--draft=false",
            f"--prerelease={'true' if channel == 'beta' else 'false'}", "--latest=false",
            "--title", f"Mokaid Desktop {version}")
        promote(Namespace(artifacts=artifacts, version=version, channel=channel))
