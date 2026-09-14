"""Private Mac probe must never acquire publishing or build-time signing authority."""

import re
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[3]
WORKFLOW = ROOT / ".github/workflows/desktop-macos-signing-probe.yml"


def test_probe_has_only_isolated_build_and_protected_sign_jobs():
    assert WORKFLOW.is_file(), "The isolated private signing probe is missing"
    document = yaml.safe_load(WORKFLOW.read_text())
    assert set(document[True]) == {"workflow_dispatch"}
    assert set(document["jobs"]) == {"build", "sign"}
    assert document["permissions"] == {"contents": "read"}
    build, sign = document["jobs"]["build"], document["jobs"]["sign"]
    assert build["permissions"] == {"contents": "read"}
    assert "environment" not in build
    assert sign["environment"] == "desktop-signing-stable"
    assert sign["permissions"] == {
        "contents": "read",
        "actions": "read",
        "id-token": "write",
    }
    assert sign["needs"] == "build"


def test_only_unsigned_exact_run_archive_may_be_uploaded_and_no_publisher_exists():
    document = yaml.safe_load(WORKFLOW.read_text())
    uploads = [
        (name, step)
        for name, job in document["jobs"].items()
        for step in job["steps"]
        if "actions/upload-artifact@" in step.get("uses", "")
    ]
    assert len(uploads) == 1
    name, upload = uploads[0]
    assert name == "build"
    assert upload["with"]["path"].splitlines() == [
        "unsigned/stage.tar.gz",
        "unsigned/stage-manifest.json",
    ]
    assert upload["with"]["retention-days"] == 1
    assert upload["with"]["if-no-files-found"] == "error"
    assert "${{ github.run_id }}-${{ github.run_attempt }}" in upload["with"]["name"]
    for job in document["jobs"].values():
        assert "write" not in (
            job["permissions"].get("contents"),
            job["permissions"].get("actions"),
        )
        runs = "\n".join(step.get("run", "") for step in job["steps"])
        for forbidden in (
            "gh release",
            "release.py promote",
            "ci.py package",
            "aws s3",
            "s3api",
            "aws iam",
            "gh api",
            "aws secretsmanager",
            "--no-sandbox",
        ):
            assert forbidden not in runs


def test_signer_checks_provenance_before_oidc_and_uses_reviewed_code_not_artifact_code():
    document = yaml.safe_load(WORKFLOW.read_text())
    sign = document["jobs"]["sign"]
    steps = sign["steps"]
    checkout = next(
        step for step in steps if "actions/checkout@" in step.get("uses", "")
    )
    assert checkout["with"]["ref"] == "${{ needs.build.outputs.commit }}"
    assert checkout["with"]["fetch-depth"] == 0
    download = next(
        step for step in steps if "actions/download-artifact@" in step.get("uses", "")
    )
    assert download["with"]["artifact-ids"] == "${{ needs.build.outputs.artifact_id }}"
    assert download["with"]["run-id"] == "${{ github.run_id }}"
    assert "name" not in download["with"] and "pattern" not in download["with"]
    validate = next(
        i
        for i, step in enumerate(steps)
        if "macos_signing_probe.py verify-stage" in step.get("run", "")
    )
    login = next(
        i
        for i, step in enumerate(steps)
        if "configure-aws-credentials@" in step.get("uses", "")
    )
    execute = next(
        i
        for i, step in enumerate(steps)
        if "macos_signing_probe.py sign --execute" in step.get("run", "")
    )
    assert validate < login < execute
    assert (
        steps[login]["with"]["role-session-name"]
        == "desktop-probe-${{ github.run_id }}"
    )
    assert steps[login]["with"]["allowed-account-ids"] == "660601648321"
    assert steps[login]["with"]["aws-region"] == "il-central-1"
    runs = "\n".join(step.get("run", "") for step in steps)
    for forbidden in (
        "cmake",
        "ctest",
        "npm ",
        "configure-build-test",
        "ci.py stage",
        "open ",
        "unittest",
        "Mokaid.app/Contents/MacOS/Mokaid",
    ):
        assert forbidden not in runs
    assert "--only-binary=:all:" in runs
    for step in steps:
        if (
            "macos_signing_probe.py" in step.get("run", "")
            and "metadata" not in step["run"]
        ):
            assert '--manifest-sha256 "$PROBE_MANIFEST_SHA256"' in step["run"]
            assert "--input unsigned" in step["run"]


def test_main_only_inputs_are_not_interpolated_into_shell_and_actions_are_pinned():
    document = yaml.safe_load(WORKFLOW.read_text())
    assert set(document[True]["workflow_dispatch"]["inputs"]) == {
        "source_sha",
        "version",
    }
    for job in document["jobs"].values():
        assert (
            "if" not in job
        ), "An invalid dispatch must FAIL, not become a successful all-skipped run"
        assert job["runs-on"] == "macos-15"
        for step in job["steps"]:
            assert "${{ inputs." not in step.get("run", "")
            if "uses" in step:
                assert re.fullmatch(r"[\w.-]+/[\w./-]+@[0-9a-f]{40}", step["uses"])
            if "actions/checkout@" in step.get("uses", ""):
                assert step["with"]["persist-credentials"] is False
    runs = "\n".join(step.get("run", "") for step in document["jobs"]["build"]["steps"])
    assert 'ci.py configure-build-test --probe-version "$PROBE_VERSION"' in runs
    assert "--release" not in runs and "GITHUB_REF_NAME=" not in runs
