"""Offline contracts for CI-gated production migration, staging and recovery."""

from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[3]


def workflow(name):
    return yaml.load(
        (ROOT / ".github/workflows" / name).read_text(), Loader=yaml.BaseLoader
    )


def deployment():
    return workflow("deploy.yml")["jobs"]["deploy"]


def command_step(steps, command):
    matches = [step for step in steps if command in step.get("run", "")]
    assert len(matches) == 1
    return matches[0]


def test_production_requires_exact_successful_push_ci_before_cloud_access():
    data = workflow("deploy.yml")
    job = data["jobs"]["deploy"]
    condition = job["if"]
    assert data["concurrency"]["cancel-in-progress"] == "false"
    assert job["environment"] == "prod"
    for requirement in (
        "vars.AWS_DEPLOY_ENABLED == 'true'",
        "github.ref == 'refs/heads/prod'",
        "github.event.workflow_run.conclusion == 'success'",
        "github.event.workflow_run.head_branch == 'prod'",
        "github.event.workflow_run.event == 'push'",
        "github.event.workflow_run.head_repository.full_name == github.repository",
    ):
        assert requirement in condition
    steps = job["steps"]
    gate = command_step(steps, "gh run list")
    assert 'test "$(git rev-parse HEAD)" = "$IMAGE_TAG"' in gate["run"]
    assert "commits/prod" in gate["run"]
    assert '--commit "$IMAGE_TAG" --branch prod --event push' in gate["run"]
    assert '.status == "completed" and .conclusion == "success"' in gate["run"]
    aws_login = next(
        step for step in steps if "configure-aws-credentials@" in step.get("uses", "")
    )
    assert steps.index(gate) < steps.index(aws_login)


def test_exact_scanned_images_pass_staging_before_production_mutations():
    steps = deployment()["steps"]
    stage = command_step(steps, "staging_smoke.py")
    prepare = next(step for step in steps if step.get("id") == "api_task")
    scans = [step for step in steps if "trivy-action@" in step.get("uses", "")]
    assert len(scans) == 4
    for scan in scans:
        assert steps.index(scan) < steps.index(stage)
        assert scan["with"]["exit-code"] == "1"
        assert "@${{ steps." in scan["with"]["image-ref"]
    assert steps.index(stage) < steps.index(prepare)
    for service, repository in (
        ("api", "api"),
        ("web", "web"),
        ("crm", "crm"),
        ("worker", "ai-worker"),
    ):
        assert stage["env"][service.upper() + "_IMAGE"] == (
            "${{ steps.registry.outputs.registry }}/mokaid-"
            + repository
            + "@${{ steps."
            + service
            + "_image.outputs.digest }}"
        )
    assert stage["env"]["MOKAID_DESKTOP_ONLY_BUSINESS"] == "${{ env.DESKTOP_ONLY }}"
    assert "continue-on-error" not in stage


def test_migration_precedes_every_rollout_and_uses_prepared_exact_revision():
    steps = deployment()["steps"]
    migration = command_step(steps, "run-ecs-migration.sh")
    assert migration["env"]["TASK_DEFINITION"] == (
        "${{ steps.api_task.outputs.task_definition }}"
    )
    assert migration["env"]["PREVIOUS_TASK_DEFINITION"] == (
        "${{ steps.api_task.outputs.previous_task_definition }}"
    )
    rollouts = [
        step for step in steps if "deploy-ecs-service.sh" in step.get("run", "")
    ]
    assert len(rollouts) == 4
    for step, service in zip(rollouts, ("api", "worker", "web", "crm"), strict=True):
        assert steps.index(migration) < steps.index(step)
        for key, output in (
            ("TASK_DEFINITION", "task_definition"),
            ("PREVIOUS_TASK_DEFINITION", "previous_task_definition"),
        ):
            assert step["env"][key] == (
                "${{ steps." + service + "_task.outputs." + output + " }}"
            )
        assert "continue-on-error" not in step


def test_cloud_session_is_renewed_after_builds_and_before_recovery():
    steps = deployment()["steps"]
    stage = command_step(steps, "staging_smoke.py")
    prepare = next(step for step in steps if step.get("id") == "api_task")
    recovery = command_step(steps, "rollback-ecs-batch.sh")
    logins = [
        step for step in steps if "configure-aws-credentials@" in step.get("uses", "")
    ]
    assert len(logins) >= 3
    pre_mutation = [
        step
        for step in logins
        if steps.index(stage) < steps.index(step) < steps.index(prepare)
    ]
    pre_recovery = [
        step
        for step in logins
        if steps.index(prepare) < steps.index(step) < steps.index(recovery)
    ]
    assert pre_mutation and pre_recovery
    for step in (pre_mutation[-1], pre_recovery[-1]):
        assert step["with"]["role-duration-seconds"] == "3600"
        assert step["with"]["allowed-account-ids"] == "660601648321"
        assert step["with"].get("use-existing-credentials", "false") == "false"
    assert pre_recovery[-1]["if"] == recovery["if"]


def test_recovery_includes_cancellation_and_all_recorded_previous_revisions():
    steps = deployment()["steps"]
    recovery = command_step(steps, "rollback-ecs-batch.sh")
    assert "always()" in recovery["if"]
    assert "failure() || cancelled()" in recovery["if"]
    assert "steps.api_task.outputs.task_definition != ''" in recovery["if"]
    assert steps.index(command_step(steps, "verify-production.mjs")) < steps.index(
        recovery
    )
    for service in ("api", "worker", "web", "crm"):
        assert recovery["env"][service.upper() + "_PREVIOUS"] == (
            "${{ steps." + service + "_task.outputs.previous_task_definition }}"
        )
        assert recovery["env"][service.upper() + "_TASK"] == (
            "${{ steps." + service + "_task.outputs.task_definition }}"
        )
    assert "continue-on-error" not in recovery
    assert 'map(select(.task_definition != ""' in recovery["run"]


def test_ci_gates_docker_on_tests_and_verifies_the_real_nginx_target():
    jobs = workflow("ci.yml")["jobs"]
    docker = jobs["docker"]
    assert set(docker["needs"]) == {
        "web",
        "crm",
        "api",
        "ai-worker",
        "terraform",
        "deployment-policy",
    }
    build = next(
        step
        for step in docker["steps"]
        if step.get("with", {}).get("file") == "infra/docker/web.Dockerfile"
    )
    assert build["with"]["target"] == "runtime"
    assert build["with"]["load"] == "true"
    smoke = command_step(docker["steps"], "verify-production.mjs")
    assert "docker run" in smoke["run"] and "127.0.0.1:8418:80" in smoke["run"]
    assert "python3 -m unittest discover -s .github/scripts/tests -v" in "\n".join(
        step.get("run", "") for step in jobs["web"]["steps"]
    )


def test_ci_audits_javascript_before_building_release_images():
    steps = workflow("ci.yml")["jobs"]["web"]["steps"]
    install = command_step(steps, "npm ci")
    audit = command_step(steps, "npm audit")
    build = next(step for step in steps if step.get("name") == "Build")
    assert audit["run"] == "npm audit --audit-level=high"
    assert "continue-on-error" not in audit
    assert steps.index(install) < steps.index(audit) < steps.index(build)
