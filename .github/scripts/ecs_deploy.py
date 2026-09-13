#!/usr/bin/env python3
"""Fail-closed ECS release steps; AWS configuration/error bodies never reach logs."""
from __future__ import annotations
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time
import uuid


class Failure(RuntimeError):
    pass


TASK_DEFINITION = re.compile(r"arn:(aws|aws-cn|aws-us-gov):ecs:[a-z0-9-]+:\d{12}:task-definition/[A-Za-z0-9_-]+:[1-9]\d*")
TASK_ARN = re.compile(r"arn:(aws|aws-cn|aws-us-gov):ecs:[a-z0-9-]+:\d{12}:task/[A-Za-z0-9_/-]+")
IMAGE_DIGEST = re.compile(r"[a-z0-9][a-z0-9._:/-]*@sha256:[0-9a-f]{64}")
NAME = re.compile(r"[A-Za-z0-9_-]{1,255}")


def required(env, key):
    value = env.get(key, "")
    if not value or any(ord(char) < 32 for char in value):
        raise Failure(f"{key} is required and must not contain control characters")
    return value


def exact_definition(value):
    if not isinstance(value, str) or not TASK_DEFINITION.fullmatch(value):
        raise Failure("An exact revisioned task-definition ARN is required; family/latest references are forbidden")
    return value


def same_family(first, second):
    return first.rsplit(":", 1)[0] == second.rsplit(":", 1)[0]


def duration(env, key, default, maximum=3600):
    try:
        value = int(env.get(key, str(default)))
    except ValueError as error:
        raise Failure(f"{key} must be a bounded positive integer") from error
    if not 1 <= value <= maximum:
        raise Failure(f"{key} must be a bounded positive integer")
    return value


class Aws:
    def call(self, operation, *arguments, payload=None):
        # Task definitions may contain legacy plaintext environment values.
        # Keep CLI input off argv; never print request/response/error JSON.
        with tempfile.TemporaryDirectory(prefix="mokaid-ecs-") as directory:
            command = ["aws", "ecs", operation, *arguments, "--output", "json", "--no-cli-pager",
                       "--cli-connect-timeout", "10", "--cli-read-timeout", "45"]
            if payload is not None:
                source = Path(directory) / "request.json"
                source.write_text(json.dumps(payload), encoding="utf-8")
                source.chmod(0o600)
                command.extend(["--cli-input-json", f"file://{source}"])
            try:
                result = subprocess.run(command, capture_output=True, text=True, timeout=60, check=False)
            except (OSError, subprocess.TimeoutExpired) as error:
                raise Failure(f"AWS ECS {operation} did not complete; response details suppressed") from error
            if result.returncode:
                raise Failure(f"AWS ECS {operation} failed; response details suppressed")
            try:
                decoded = json.loads(result.stdout)
            except (ValueError, TypeError) as error:
                raise Failure(f"AWS ECS {operation} returned invalid JSON") from error
            if not isinstance(decoded, dict):
                raise Failure(f"AWS ECS {operation} returned an unexpected response")
            return decoded


def service(aws, cluster, name):
    response = aws.call("describe-services", "--cluster", cluster, "--services", name)
    entries = response.get("services", [])
    if response.get("failures") or len(entries) != 1:
        raise Failure("Expected exactly one existing ECS service and no lookup failures")
    current = entries[0]
    if current.get("status") != "ACTIVE" or name not in (current.get("serviceName"), current.get("serviceArn")):
        raise Failure("ECS service identity/status does not match the requested active service")
    if current.get("deploymentController", {}).get("type") != "ECS":
        raise Failure("Only the ECS rolling deployment controller is supported")
    exact_definition(current.get("taskDefinition", ""))
    return current


def stable(current, expected):
    deployments = current.get("deployments", [])
    desired = current.get("desiredCount")
    return (current.get("taskDefinition") == expected and type(desired) is int and desired > 0
            and current.get("runningCount") == desired and current.get("pendingCount") == 0
            and len(deployments) == 1 and deployments[0].get("status") == "PRIMARY"
            and deployments[0].get("taskDefinition") == expected
            and deployments[0].get("rolloutState") == "COMPLETED"
            and deployments[0].get("runningCount") == desired
            and deployments[0].get("pendingCount") == 0)


def definition(aws, arn):
    exact_definition(arn)
    response = aws.call("describe-task-definition", "--task-definition", arn, "--include", "TAGS")
    task = response.get("taskDefinition", {})
    if task.get("taskDefinitionArn") != arn or task.get("status") != "ACTIVE":
        raise Failure("The exact task-definition revision is missing or inactive")
    return task, response.get("tags", [])


def named_container(task, name):
    matches = [item for item in task.get("containerDefinitions", []) if item.get("name") == name]
    if len(matches) != 1:
        raise Failure("The requested container name must match exactly once in the task definition")
    return matches[0]


def output_file(env):
    path = Path(required(env, "GITHUB_OUTPUT"))
    if not path.is_file() or path.is_symlink():
        raise Failure("GITHUB_OUTPUT must be an existing regular non-symlink file")
    return path


def outputs(path, values):
    if any("\n" in value or "\r" in value for value in values.values()):
        raise Failure("Unsafe output value")
    with path.open("a", encoding="utf-8") as stream:
        for key, value in values.items():
            stream.write(f"{key}={value}\n")


def prepare(env, aws):
    cluster, name, container = (required(env, key) for key in ("CLUSTER", "SERVICE", "CONTAINER"))
    image = required(env, "IMAGE")
    destination = output_file(env)
    if not NAME.fullmatch(container) or not IMAGE_DIGEST.fullmatch(image):
        raise Failure("An exact container name and immutable repository@sha256 image digest are required")
    overrides = {}
    for key in ("MOKAID_DESKTOP_ONLY_BUSINESS", "DESKTOP_AUTH_WEB_BASE_URL"):
        if key in env:
            if container != "mokaid-prod-api":
                raise Failure("Desktop rollout overrides are restricted to mokaid-prod-api")
            value = env[key]
            if (key == "MOKAID_DESKTOP_ONLY_BUSINESS" and value not in ("true", "false")) or (
                    key == "DESKTOP_AUTH_WEB_BASE_URL" and value != "https://mokaid.com"):
                raise Failure("Invalid explicitly allowed desktop rollout setting")
            overrides[key] = value
    current = service(aws, cluster, name)
    previous = current["taskDefinition"]
    if not stable(current, previous):
        raise Failure("Preparation requires a completed healthy baseline deployment")
    task, tags = definition(aws, previous)
    target = named_container(task, container)
    target["image"] = image
    if overrides:
        if any(item.get("name") in overrides for item in target.get("secrets", [])):
            raise Failure("An environment override conflicts with a secret reference")
        target["environment"] = [item for item in target.get("environment", []) if item.get("name") not in overrides]
        target["environment"].extend({"name": key, "value": value} for key, value in overrides.items())
    for key in ("taskDefinitionArn", "revision", "status", "requiresAttributes", "compatibilities",
                "registeredAt", "registeredBy", "deregisteredAt"):
        task.pop(key, None)
    task["tags"] = tags
    registered = aws.call("register-task-definition", payload=task).get("taskDefinition", {})
    prepared = exact_definition(registered.get("taskDefinitionArn", ""))
    if prepared == previous or not same_family(previous, prepared) or registered.get("status") != "ACTIVE":
        raise Failure("Registered task identity does not match the intended new family revision")
    if named_container(registered, container).get("image") != image:
        raise Failure("Registered task definition does not contain the requested immutable image")
    outputs(destination, {"task_definition": prepared, "previous_task_definition": previous,
                          "container": container, "image": image})
    print(f"Prepared exact ECS task revision {prepared}; live service unchanged")


def await_service(aws, cluster, name, expected, previous, timeout, interval, *, clock=None, sleep=None):
    clock, sleep = clock or time.monotonic, sleep or time.sleep
    deadline = clock() + timeout
    observed_expected = False
    while clock() < deadline:
        current = service(aws, cluster, name)
        actual = current["taskDefinition"]
        if actual not in (expected, previous):
            raise Failure("A different release changed the service; refusing to overwrite it")
        if stable(current, expected):
            return
        matching = [item for item in current.get("deployments", []) if item.get("taskDefinition") == expected]
        if any(item.get("rolloutState") == "FAILED" for item in matching):
            raise Failure("The requested ECS rollout failed")
        if actual == expected:
            observed_expected = True
        elif observed_expected and stable(current, previous):
            raise Failure("ECS rolled back to the previous revision; this is not deployment success")
        sleep(min(interval, max(0, deadline - clock())))
    raise Failure("Timed out waiting for the exact completed ECS revision and healthy task counts")


def update(aws, cluster, name, arn):
    response = aws.call("update-service", "--cluster", cluster, "--service", name,
                       "--task-definition", arn, "--force-new-deployment")
    if response.get("service", {}).get("taskDefinition") != arn:
        raise Failure("ECS did not acknowledge the exact requested revision")


def deploy(env, aws):
    cluster, name = (required(env, key) for key in ("CLUSTER", "SERVICE"))
    prepared = exact_definition(required(env, "TASK_DEFINITION"))
    previous = exact_definition(required(env, "PREVIOUS_TASK_DEFINITION"))
    timeout = duration(env, "DEPLOY_TIMEOUT_SECONDS", 1200)
    rollback_timeout = duration(env, "ROLLBACK_TIMEOUT_SECONDS", 600)
    interval = duration(env, "POLL_INTERVAL_SECONDS", 15, 60)
    if prepared == previous or not same_family(prepared, previous):
        raise Failure("Prepared and previous definitions must be distinct revisions of the same family")
    current = service(aws, cluster, name)
    if current["taskDefinition"] != previous or not stable(current, previous):
        raise Failure("The live service changed after preparation or is not healthy; refusing stale deployment")
    definition(aws, prepared)
    try:
        update(aws, cluster, name, prepared)
        await_service(aws, cluster, name, prepared, previous, timeout, interval)
    except (Exception, KeyboardInterrupt) as error:
        try:
            current = service(aws, cluster, name)
            if current["taskDefinition"] not in (prepared, previous):
                raise Failure("Another release owns the live service; automatic rollback refused")
            if not stable(current, previous):
                update(aws, cluster, name, previous)
                await_service(aws, cluster, name, previous, prepared, rollback_timeout, interval)
            print("Previous ECS revision restored and verified; requested deployment remains failed", file=sys.stderr)
        except (Exception, KeyboardInterrupt):
            raise Failure("Deployment failed and rollback could not be verified; operator attention required") from None
        raise Failure("Requested ECS deployment failed; previous revision is healthy") from error
    print(f"Verified deployment of exact ECS task revision {prepared}")


def rollback_batch(env, aws):
    source = required(env, "ROLLBACK_BATCH_JSON")
    if len(source) > 16384:
        raise Failure("Rollback batch is too large")
    try:
        entries = json.loads(source)
    except ValueError as error:
        raise Failure("Rollback batch must be valid JSON") from error
    if not isinstance(entries, list) or not 1 <= len(entries) <= 4:
        raise Failure("Rollback batch must contain one to four prepared services")
    identities = set()
    keys = {"cluster", "service", "task_definition", "previous_task_definition"}
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != keys or any(not isinstance(value, str) for value in entry.values()):
            raise Failure("Rollback batch entries require exactly cluster, service and both revision ARNs")
        if not NAME.fullmatch(entry["cluster"]) or not NAME.fullmatch(entry["service"]):
            raise Failure("Rollback batch cluster/service must use exact short names")
        identity = (entry["cluster"], entry["service"])
        if identity in identities:
            raise Failure("Rollback batch contains a duplicate service")
        identities.add(identity)
        prepared = exact_definition(entry["task_definition"])
        previous = exact_definition(entry["previous_task_definition"])
        if prepared == previous or not same_family(prepared, previous):
            raise Failure("Rollback batch requires distinct revisions of the same family per service")
    timeout = duration(env, "ROLLBACK_TIMEOUT_SECONDS", 600)
    interval = duration(env, "POLL_INTERVAL_SECONDS", 15, 60)
    failures = set()

    def check_owned(entry):
        current = service(aws, entry["cluster"], entry["service"])
        if current["taskDefinition"] not in (entry["task_definition"], entry["previous_task_definition"]):
            raise Failure("A different release owns this service")
        return current

    # Inspect the complete set first. A changed or unreadable service is never
    # overwritten, but must not prevent restoration of other owned services.
    for index, entry in enumerate(entries):
        try:
            check_owned(entry)
            definition(aws, entry["previous_task_definition"])
        except Exception:
            failures.add(index)
            print(f"Rollback preflight refused for service {entry['service']}; it will not be changed", file=sys.stderr)
    for index in reversed(range(len(entries))):
        if index in failures:
            continue
        entry = entries[index]
        previous, prepared = entry["previous_task_definition"], entry["task_definition"]
        try:
            current = check_owned(entry)
            if not stable(current, previous):
                if current["taskDefinition"] == prepared:
                    update(aws, entry["cluster"], entry["service"], previous)
                # If ECS already began its own rollback, only wait for it.
                await_service(aws, entry["cluster"], entry["service"], previous, prepared, timeout, interval)
            print(f"Verified previous revision for service {entry['service']}")
        except Exception:
            failures.add(index)
            print(f"Rollback could not be verified for service {entry['service']}; continuing other owned services", file=sys.stderr)
    for index, entry in enumerate(entries):
        if index not in failures:
            try:
                if not stable(check_owned(entry), entry["previous_task_definition"]):
                    raise Failure("Previous revision is no longer healthy")
            except Exception:
                failures.add(index)
    if failures:
        raise Failure(f"Batch rollback incomplete for {len(failures)} service(s); operator attention required; database unchanged")
    print("Batch rollback verified; the original release remains failed and database migrations are not reversed")


def stop_migration(aws, cluster, task):
    try:
        aws.call("stop-task", "--cluster", cluster, "--task", task,
                 "--reason", "Mokaid CI migration failed, interrupted or timed out")
        print(f"Stop requested for migration task {task}", file=sys.stderr)
    except Failure:
        print(f"ERROR: unable to request stop of migration task {task}; operator action required", file=sys.stderr)


def migrate(env, aws):
    cluster, name, container = (required(env, key) for key in ("CLUSTER", "SERVICE", "CONTAINER"))
    prepared = exact_definition(required(env, "TASK_DEFINITION"))
    timeout = duration(env, "MIGRATION_TIMEOUT_SECONDS", 600)
    interval = duration(env, "POLL_INTERVAL_SECONDS", 10, 60)
    current = service(aws, cluster, name)
    if not stable(current, current["taskDefinition"]):
        raise Failure("Migration requires a completed healthy baseline deployment")
    if not same_family(prepared, current["taskDefinition"]):
        raise Failure("Migration definition must belong to the active service's task family")
    if "PREVIOUS_TASK_DEFINITION" in env and current["taskDefinition"] != exact_definition(env["PREVIOUS_TASK_DEFINITION"]):
        raise Failure("The live service changed after migration preparation")
    task_definition, _ = definition(aws, prepared)
    named_container(task_definition, container)
    if task_definition.get("networkMode") != "awsvpc" or "FARGATE" not in task_definition.get("requiresCompatibilities", []):
        raise Failure("Migration requires the prepared Fargate/awsvpc definition")
    network = current.get("networkConfiguration", {})
    vpc = network.get("awsvpcConfiguration", {})
    if not vpc.get("subnets") or not vpc.get("securityGroups") or vpc.get("assignPublicIp") not in ("ENABLED", "DISABLED"):
        raise Failure("Active service does not provide a complete awsvpc network configuration")
    operation_id = "mokaid-migration-" + uuid.uuid4().hex
    payload = {"cluster": cluster, "taskDefinition": prepared, "launchType": "FARGATE", "count": 1,
               "networkConfiguration": network, "startedBy": operation_id, "clientToken": operation_id,
               "overrides": {"containerOverrides": [{"name": container,
                   "command": ["bin/mokaid", "eval", "Mokaid.Release.migrate()"]}]}}
    if current.get("platformVersion"):
        payload["platformVersion"] = current["platformVersion"]
    # This public correlation ID lets an operator find an accepted task if the
    # RunTask response is lost. It is not an authentication credential.
    print(f"Submitting migration operation {operation_id}")
    try:
        response = aws.call("run-task", payload=payload)
    except (Exception, KeyboardInterrupt):
        raise Failure(f"Migration submission outcome unknown; inspect ECS tasks startedBy={operation_id} before retrying") from None
    tasks = response.get("tasks", [])
    if response.get("failures") or len(tasks) != 1:
        for item in tasks:
            if TASK_ARN.fullmatch(item.get("taskArn", "")) and item.get("taskDefinitionArn") == prepared:
                stop_migration(aws, cluster, item["taskArn"])
        raise Failure("Migration run-task failed or did not create exactly one task")
    task = tasks[0].get("taskArn", "")
    if not TASK_ARN.fullmatch(task) or tasks[0].get("taskDefinitionArn") != prepared:
        raise Failure("Migration task identity does not match the prepared definition")
    print(f"Started migration task {task} from exact revision {prepared}")
    stopped = False
    try:
        deadline = time.monotonic() + timeout
        seen_task = False
        discovery_delay = min(interval, 2)
        while time.monotonic() < deadline:
            result = aws.call("describe-tasks", "--cluster", cluster, "--tasks", task)
            entries = result.get("tasks", [])
            failures = result.get("failures", [])
            # ECS is eventually consistent immediately after RunTask. Only a
            # matching MISSING result before first observation is retryable.
            if not seen_task and not entries and failures and all(
                    item.get("arn") == task and item.get("reason") == "MISSING" for item in failures):
                time.sleep(min(discovery_delay, max(0, deadline - time.monotonic())))
                discovery_delay = min(discovery_delay * 2, 60)
                continue
            if result.get("failures") or len(entries) != 1:
                raise Failure("Migration task lookup failed")
            current_task = entries[0]
            if current_task.get("taskArn") != task or current_task.get("taskDefinitionArn") != prepared:
                raise Failure("Migration task lookup returned a different task or revision")
            seen_task = True
            if current_task.get("lastStatus") == "STOPPED":
                stopped = True
                containers = [item for item in current_task.get("containers", []) if item.get("name") == container]
                exit_code = containers[0].get("exitCode") if len(containers) == 1 else None
                if type(exit_code) is not int or exit_code != 0 or current_task.get("stopCode") in (
                        "TaskFailedToStart", "UserInitiated", "TerminationNotice"):
                    raise Failure("The exact migration container did not exit successfully")
                print("Migration completed successfully; live ECS service unchanged")
                return
            time.sleep(min(interval, max(0, deadline - time.monotonic())))
        raise Failure("Migration exceeded the bounded timeout")
    finally:
        if not stopped:
            stop_migration(aws, cluster, task)


def interrupted(*_):
    raise Failure("CI step interrupted")


def main():
    os.umask(0o077)
    signal.signal(signal.SIGTERM, interrupted)
    try:
        commands = {"prepare": prepare, "deploy": deploy, "migrate": migrate, "rollback-batch": rollback_batch}
        if len(sys.argv) != 2 or sys.argv[1] not in commands:
            raise Failure("Expected prepare, deploy, migrate or rollback-batch")
        commands[sys.argv[1]](dict(os.environ), Aws())
        return 0
    except (Failure, KeyboardInterrupt) as error:
        print(f"ERROR: {error or 'CI step interrupted'}", file=sys.stderr)
        return 1
    except Exception:
        print("ERROR: unexpected ECS release response; details suppressed; operator review required", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
