"""Offline YAML contracts for the unsigned-build/signing privilege boundary."""

import re
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[3]
WORKFLOW = ROOT / ".github/workflows/desktop-release.yml"


def workflow():
    # BaseLoader follows YAML scalars literally, so GitHub's `on` is not bool True.
    return yaml.load(WORKFLOW.read_text(), Loader=yaml.BaseLoader)


def test_only_signer_has_oidc_and_native_builds_have_no_environment():
    data = workflow()
    assert data["permissions"] == {"contents": "read"}
    assert data["on"]["push"]["tags"] == ["desktop-v*"]
    assert {
        name
        for name, job in data["jobs"].items()
        if job.get("permissions", {}).get("id-token") == "write"
    } == {"sign"}
    for name in ("build_macos", "build_windows"):
        job = data["jobs"][name]
        assert "environment" not in job
        assert job["permissions"] == {"contents": "read"}
        assert not any(
            "SECRET" in key or "AZURE" in key or "AWS" in key for key in job["env"]
        )
        runs = "\n".join(step.get("run", "") for step in job["steps"])
        assert "configure-build-test --release" in runs and "ci.py stage" in runs
        assert "ci.py package" not in runs


def test_signer_imports_exact_platform_artifact_and_hash_before_login():
    sign = workflow()["jobs"]["sign"]
    assert set(sign["needs"]) == {"metadata", "build_macos", "build_windows"}
    assert (
        sign["environment"] == "desktop-signing-${{ needs.metadata.outputs.channel }}"
    )
    assert sign["permissions"] == {
        "contents": "read",
        "actions": "read",
        "id-token": "write",
    }
    steps = sign["steps"]
    download = next(
        step
        for step in steps
        if step.get("uses", "").startswith("actions/download-artifact@")
    )
    assert download["with"]["artifact-ids"] == "${{ matrix.artifact_id }}"
    assert download["with"]["run-id"] == "${{ github.run_id }}"
    assert "pattern" not in download["with"] and "name" not in download["with"]
    restore = next(
        step for step in steps if "stage_archive.py restore" in step.get("run", "")
    )
    command = restore["run"]
    for argument in (
        "--run-id",
        "--run-attempt",
        "--version",
        "--channel",
        "--commit",
        "--tooling-sha",
        "--manifest-sha256",
        "--platform",
        "--public-key",
    ):
        assert argument in command
    assert steps.index(restore) < next(
        i
        for i, step in enumerate(steps)
        if "configure-aws-credentials@" in step.get("uses", "")
    )
    for entry in sign["strategy"]["matrix"]["include"]:
        name = "build_macos" if entry["platform"] == "macos-arm64" else "build_windows"
        assert entry["artifact_id"] == "${{ needs." + name + ".outputs.artifact_id }}"
        assert (
            entry["manifest_sha256"]
            == "${{ needs." + name + ".outputs.manifest_sha256 }}"
        )


def test_no_native_build_or_tag_tooling_executed_in_signer():
    jobs = workflow()["jobs"]
    for name in ("sign", "candidate"):
        job = jobs[name]
        checkout = next(
            step
            for step in job["steps"]
            if step.get("uses", "").startswith("actions/checkout@")
        )
        assert checkout["with"]["ref"] == "${{ needs.metadata.outputs.tooling_sha }}"
        runs = "\n".join(step.get("run", "") for step in job["steps"])
        for forbidden in (
            "configure-build-test",
            "cmake --build",
            "ctest",
            "npm ",
            "ci.py stage",
            "unittest",
        ):
            assert forbidden not in runs
        assert "--only-binary=:all:" in runs


def test_unsigned_upload_is_tar_and_manifest_only_with_unique_run_identity():
    jobs = workflow()["jobs"]
    for name, target in (
        ("build_macos", "macos-arm64"),
        ("build_windows", "windows-x64"),
    ):
        job = jobs[name]
        assert (
            job["outputs"]["artifact_id"] == "${{ steps.upload.outputs.artifact-id }}"
        )
        assert (
            job["outputs"]["manifest_sha256"]
            == "${{ steps.archive.outputs.manifest_sha256 }}"
        )
        upload = next(step for step in job["steps"] if step.get("id") == "upload")
        assert (
            upload["with"]["name"]
            == "desktop-unsigned-"
            + target
            + "-${{ github.run_id }}-${{ github.run_attempt }}"
        )
        assert upload["with"]["path"].splitlines() == [
            "unsigned/stage.tar.gz",
            "unsigned/stage-manifest.json",
        ]
        assert upload["with"]["compression-level"] == "0"


def test_actions_are_immutable_and_checkout_credentials_are_not_persisted():
    for job in workflow()["jobs"].values():
        for step in job["steps"]:
            if "uses" in step:
                assert re.fullmatch(r"[\w.-]+/[\w./-]+@[0-9a-f]{40}", step["uses"])
            if step.get("uses", "").startswith("actions/checkout@"):
                assert step["with"]["persist-credentials"] == "false"


def test_candidate_is_draft_and_fetches_only_two_current_attempt_artifacts():
    candidate = workflow()["jobs"]["candidate"]
    assert set(candidate["needs"]) == {"metadata", "sign"}
    downloads = [
        step["with"]
        for step in candidate["steps"]
        if "actions/download-artifact@" in step.get("uses", "")
    ]
    assert len(downloads) == 2
    assert all(
        "${{ github.run_id }}-${{ github.run_attempt }}" in item["name"]
        for item in downloads
    )
    assert not any("pattern" in item for item in downloads)
    command = next(
        step["run"]
        for step in candidate["steps"]
        if "gh release create" in step.get("run", "")
    )
    assert "--draft --prerelease" in command


def test_release_public_keys_are_versioned_and_fail_closed_until_initialized():
    metadata = workflow()["jobs"]["metadata"]
    keys = next(step for step in metadata["steps"] if step.get("id") == "keys")
    assert "stage_archive.py public-key" in keys["run"]
    assert metadata["outputs"]["public_key"] == "${{ steps.keys.outputs.public_key }}"
    assert (ROOT / "apps/desktop/distribution/update-public-keys.json").is_file()
