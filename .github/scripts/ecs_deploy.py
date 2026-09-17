#!/usr/bin/env python3
"""Fail-closed ECS release steps; AWS configuration/error bodies never reach logs."""
from __future__ import annotations
import copy
from collections.abc import Callable, Mapping
import ipaddress
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
from typing import Any, NoReturn, Protocol


class Failure(RuntimeError):
    pass


TASK_DEFINITION = re.compile(r"arn:(aws|aws-cn|aws-us-gov):ecs:[a-z0-9-]+:\d{12}:task-definition/[A-Za-z0-9_-]+:[1-9]\d*")
TASK_ARN = re.compile(r"arn:(aws|aws-cn|aws-us-gov):ecs:[a-z0-9-]+:\d{12}:task/[A-Za-z0-9_/-]+")
IMAGE_DIGEST = re.compile(r"[a-z0-9][a-z0-9._:/-]*@sha256:[0-9a-f]{64}")
NAME = re.compile(r"[A-Za-z0-9_-]{1,255}")
CLUSTER_ARN = re.compile(r"arn:(aws|aws-cn|aws-us-gov):ecs:[a-z0-9-]+:\d{12}:cluster/[A-Za-z0-9_-]+")
# Matches infra/terraform/environments/prod/main.tf. Never fall back to all
# RFC1918 space (or is_private, which also includes reserved/loopback ranges).
PRODUCTION_VPC = ipaddress.IPv4Network("10.10.0.0/16")


class AwsClient(Protocol):
    def call(self, operation: str, *arguments: str,
             payload: dict[str, Any] | None = None) -> dict[str, Any]: ...


def required(env: Mapping[str, str], key: str) -> str:
    value = env.get(key, "")
    if not value or any(ord(char) < 32 for char in value):
        raise Failure(f"{key} is required and must not contain control characters")
    return value


def trusted_alb_cidrs(value: str) -> str:
    """Accept only an explicit, bounded list of narrow production VPC networks."""
    message = "MOKAID_TRUSTED_ALB_CIDRS must contain distinct canonical IPv4 CIDRs within the production VPC, each /24 or narrower"
    if not isinstance(value, str) or not value or len(value) > 512:
        raise Failure(message)
    entries = value.split(",")
    if not 1 <= len(entries) <= 16:
        raise Failure(message)
    networks: list[ipaddress.IPv4Network] = []
    for entry in entries:
        try:
            network = ipaddress.IPv4Network(entry, strict=True)
        except (ipaddress.AddressValueError, ipaddress.NetmaskValueError, ValueError):
            raise Failure(message) from None
        if (str(network) != entry or network.prefixlen < 24
                or not network.subnet_of(PRODUCTION_VPC)
                or any(network.overlaps(previous) for previous in networks)):
            raise Failure(message)
        networks.append(network)
    return value


def validate_trusted_alb(env: Mapping[str, str], _aws: AwsClient) -> None:
    # Offline workflow preflight: no AWS reads, credentials or mutation required.
    trusted_alb_cidrs(required(env, "MOKAID_TRUSTED_ALB_CIDRS"))
    print("Validated explicit production ALB network configuration")


def exact_definition(value: object) -> str:
    if not isinstance(value, str) or not TASK_DEFINITION.fullmatch(value):
        raise Failure("An exact revisioned task-definition ARN is required; family/latest references are forbidden")
    return value


def same_family(first: str, second: str) -> bool:
    return first.rsplit(":", 1)[0] == second.rsplit(":", 1)[0]


def duration(env: Mapping[str, str], key: str, default: int, maximum: int = 3600) -> int:
    try:
        value = int(env.get(key, str(default)))
    except ValueError as error:
        raise Failure(f"{key} must be a bounded positive integer") from error
    if not 1 <= value <= maximum:
        raise Failure(f"{key} must be a bounded positive integer")
    return value


class Aws:
    def call(self, operation: str, *arguments: str,
             payload: dict[str, Any] | None = None) -> dict[str, Any]:
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


def service(aws: AwsClient, cluster: str, name: str) -> dict[str, Any]:
    response = aws.call("describe-services", "--cluster", cluster, "--services", name)
    entries = response.get("services", [])
    if response.get("failures") or len(entries) != 1:
        raise Failure("Expected exactly one existing ECS service and no lookup failures")
    return service_identity(entries[0], cluster, name)


def service_identity(current: object, cluster: str, name: str) -> dict[str, Any]:
    """Validate the full service identity for reads and UpdateService responses."""
    if not isinstance(current, dict):
        raise Failure("ECS service response is missing or malformed")
    if current.get("status") != "ACTIVE" or name not in (current.get("serviceName"), current.get("serviceArn")):
        raise Failure("ECS service identity/status does not match the requested active service")
    if current.get("deploymentController", {}).get("type") != "ECS":
        raise Failure("Only the ECS rolling deployment controller is supported")
    arn = exact_definition(current.get("taskDefinition", ""))
    cluster_arn = current.get("clusterArn")
    if (not isinstance(cluster_arn, str) or not CLUSTER_ARN.fullmatch(cluster_arn)
            or cluster not in (cluster_arn, cluster_arn.rsplit("/", 1)[-1])
            or arn.split(":task-definition/", 1)[0] != cluster_arn.split(":cluster/", 1)[0]):
        raise Failure("ECS cluster identity does not match the requested service and task region/account")
    return current


def protected_configuration(current: dict[str, Any]) -> dict[str, Any]:
    """Copy all current settings, changing only the two required breaker flags."""
    configuration = current.get("deploymentConfiguration")
    if (not isinstance(configuration, dict) or not configuration
            or configuration.get("strategy", "ROLLING") != "ROLLING"
            or any(type(configuration.get(key)) is not int
                   for key in ("maximumPercent", "minimumHealthyPercent"))):
        raise Failure("A complete current rolling deployment configuration is required")
    breaker = configuration.get("deploymentCircuitBreaker", {})
    if not isinstance(breaker, dict) or any(
            key in breaker and type(breaker[key]) is not bool for key in ("enable", "rollback")):
        raise Failure("The current deployment circuit breaker configuration is malformed")
    result = copy.deepcopy(configuration)
    # Preserve optional threshold/reset settings as well as alarms, percentages,
    # lifecycle hooks and any other settings supported by the current AWS API.
    result["deploymentCircuitBreaker"] = dict(copy.deepcopy(breaker), enable=True, rollback=True)
    return result


def contains_configuration(actual: object, expected: object) -> bool:
    """Allow AWS-added default fields without dropping/changing requested fields."""
    if isinstance(expected, dict):
        return isinstance(actual, dict) and all(
            key in actual and contains_configuration(actual[key], value)
            for key, value in expected.items())
    return type(actual) is type(expected) and actual == expected


def verify_protection(current: dict[str, Any], expected: dict[str, Any] | None = None) -> None:
    """Require real booleans and preservation of the submitted configuration."""
    actual = current.get("deploymentConfiguration")
    if not isinstance(actual, dict) or not contains_configuration(actual, {
            "deploymentCircuitBreaker": {"enable": True, "rollback": True}}):
        raise Failure("ECS circuit breaker enable/rollback were not both verified true")
    if actual.get("strategy", "ROLLING") != "ROLLING":
        raise Failure("ECS deployment strategy is no longer rolling")
    if expected is not None and not contains_configuration(actual, expected):
        raise Failure("ECS did not preserve the submitted deployment configuration")


def stable(current: dict[str, Any], expected: str) -> bool:
    deployments = current.get("deployments", [])
    desired = current.get("desiredCount")
    return (current.get("taskDefinition") == expected and type(desired) is int and desired > 0
            and current.get("runningCount") == desired and current.get("pendingCount") == 0
            and len(deployments) == 1 and deployments[0].get("status") == "PRIMARY"
            and deployments[0].get("taskDefinition") == expected
            and deployments[0].get("rolloutState") == "COMPLETED"
            and deployments[0].get("runningCount") == desired
            and deployments[0].get("pendingCount") == 0)


def definition(aws: AwsClient, arn: str) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    exact_definition(arn)
    response = aws.call("describe-task-definition", "--task-definition", arn, "--include", "TAGS")
    task = response.get("taskDefinition", {})
    if task.get("taskDefinitionArn") != arn or task.get("status") != "ACTIVE":
        raise Failure("The exact task-definition revision is missing or inactive")
    tags = response.get("tags", [])
    if not isinstance(tags, list) or any(
            not isinstance(tag, dict) or set(tag) - {"key", "value"}
            or not isinstance(tag.get("key"), str) or not tag["key"]
            or ("value" in tag and not isinstance(tag["value"], str))
            for tag in tags):
        raise Failure("The task-definition tags response is malformed")
    return task, tags


def named_container(task: dict[str, Any], name: str) -> dict[str, Any]:
    matches: list[dict[str, Any]] = [item for item in task.get("containerDefinitions", []) if item.get("name") == name]
    if len(matches) != 1:
        raise Failure("The requested container name must match exactly once in the task definition")
    return matches[0]


def output_file(env: Mapping[str, str]) -> Path:
    path = Path(required(env, "GITHUB_OUTPUT"))
    if not path.is_file() or path.is_symlink():
        raise Failure("GITHUB_OUTPUT must be an existing regular non-symlink file")
    return path


def outputs(path: Path, values: dict[str, str]) -> None:
    if any("\n" in value or "\r" in value for value in values.values()):
        raise Failure("Unsafe output value")
    with path.open("a", encoding="utf-8") as stream:
        for key, value in values.items():
            stream.write(f"{key}={value}\n")


def prepare(env: Mapping[str, str], aws: AwsClient) -> None:
    cluster, name, container = (required(env, key) for key in ("CLUSTER", "SERVICE", "CONTAINER"))
    image = required(env, "IMAGE")
    destination = output_file(env)
    if not NAME.fullmatch(container) or not IMAGE_DIGEST.fullmatch(image):
        raise Failure("An exact container name and immutable repository@sha256 image digest are required")
    overrides = {}
    for key in ("MOKAID_DESKTOP_ONLY_BUSINESS", "DESKTOP_AUTH_WEB_BASE_URL", "MOKAID_TRUSTED_ALB_CIDRS", "AI_WORKER_URL"):
        if key in env:
            if container != "mokaid-prod-api":
                raise Failure("API environment overrides are restricted to mokaid-prod-api")
            value = env[key]
            if key == "MOKAID_TRUSTED_ALB_CIDRS":
                value = trusted_alb_cidrs(value)
            if key == "AI_WORKER_URL" and value != "http://ai-worker.mokaid-prod.internal:8100":
                raise Failure("Worker HTTP override must use the private production discovery endpoint")
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
        if any(sum(item.get("name") == key for item in target.get("environment", [])) > 1 for key in overrides):
            raise Failure("An environment override has duplicate existing entries")
        target["environment"] = [item for item in target.get("environment", []) if item.get("name") not in overrides]
        target["environment"].extend({"name": key, "value": value} for key, value in overrides.items())
    for key in ("taskDefinitionArn", "revision", "status", "requiresAttributes", "compatibilities",
                "registeredAt", "registeredBy", "deregisteredAt"):
        task.pop(key, None)
    if tags:
        task["tags"] = tags
    registered = aws.call("register-task-definition", payload=task).get("taskDefinition", {})
    prepared = exact_definition(registered.get("taskDefinitionArn", ""))
    if prepared == previous or not same_family(previous, prepared) or registered.get("status") != "ACTIVE":
        raise Failure("Registered task identity does not match the intended new family revision")
    registered_target = named_container(registered, container)
    if registered_target.get("image") != image:
        raise Failure("Registered task definition does not contain the requested immutable image")
    for key, value in overrides.items():
        entries = [item for item in registered_target.get("environment", []) if item.get("name") == key]
        if len(entries) != 1 or entries[0].get("value") != value:
            raise Failure("Registered task definition did not preserve the explicit API environment override")
    outputs(destination, {"task_definition": prepared, "previous_task_definition": previous,
                          "container": container, "image": image})
    print(f"Prepared exact ECS task revision {prepared}; live service unchanged")


def await_service(aws: AwsClient, cluster: str, name: str, expected: str, previous: str,
                  timeout: int, interval: int, *, clock: Callable[[], float] | None = None,
                  sleep: Callable[[float], None] | None = None,
                  expected_configuration: dict[str, Any] | None = None) -> None:
    clock, sleep = clock or time.monotonic, sleep or time.sleep
    deadline = clock() + timeout
    observed_expected = False
    while clock() < deadline:
        current = service(aws, cluster, name)
        actual = current["taskDefinition"]
        if actual not in (expected, previous):
            raise Failure("A different release changed the service; refusing to overwrite it")
        if stable(current, expected):
            verify_protection(current, expected_configuration)
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


def update(aws: AwsClient, cluster: str, name: str, arn: str,
           current: dict[str, Any]) -> dict[str, Any]:
    """Set revision and protection together; never run as a separate repair."""
    baseline = service_identity(current, cluster, name)
    exact_definition(arn)
    if baseline["taskDefinition"].rsplit(":", 1)[0] != arn.rsplit(":", 1)[0]:
        raise Failure("Update revision must belong to the current service's task family")
    configuration = protected_configuration(baseline)
    response = aws.call("update-service", payload={
        "cluster": cluster, "service": name, "taskDefinition": arn,
        "forceNewDeployment": True, "deploymentConfiguration": configuration})
    acknowledged = service_identity(response.get("service"), cluster, name)
    if acknowledged["taskDefinition"] != arn:
        raise Failure("ECS did not acknowledge the exact requested revision")
    verify_protection(acknowledged, configuration)
    return configuration


def deploy(env: Mapping[str, str], aws: AwsClient) -> None:
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
        configuration = update(aws, cluster, name, prepared, current)
        await_service(aws, cluster, name, prepared, previous, timeout, interval,
                      expected_configuration=configuration)
    except (Exception, KeyboardInterrupt) as error:
        try:
            current = service(aws, cluster, name)
            if current["taskDefinition"] not in (prepared, previous):
                raise Failure("Another release owns the live service; automatic rollback refused")
            if not stable(current, previous):
                configuration = update(aws, cluster, name, previous, current)
                await_service(aws, cluster, name, previous, prepared, rollback_timeout, interval,
                              expected_configuration=configuration)
            else:
                # Never trigger a deployment merely to repair an already healthy
                # previous revision. An unprotected no-op needs operator attention.
                verify_protection(current)
            print("Previous ECS revision restored and verified; requested deployment remains failed", file=sys.stderr)
        except (Exception, KeyboardInterrupt):
            raise Failure("Deployment failed and rollback could not be verified; operator attention required") from None
        raise Failure("Requested ECS deployment failed; previous revision is healthy") from error
    print(f"Verified deployment of exact ECS task revision {prepared}")


def rollback_batch(env: Mapping[str, str], aws: AwsClient) -> None:
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
    failures: set[int] = set()
    restored_configurations: dict[int, dict[str, Any]] = {}

    def check_owned(entry: dict[str, str]) -> dict[str, Any]:
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
                    restored_configurations[index] = update(aws, entry["cluster"], entry["service"], previous, current)
                # If ECS already began its own rollback, only wait for it.
                await_service(aws, entry["cluster"], entry["service"], previous, prepared, timeout, interval,
                              expected_configuration=restored_configurations.get(index))
            else:
                verify_protection(current)
            print(f"Verified previous revision for service {entry['service']}")
        except Exception:
            failures.add(index)
            print(f"Rollback could not be verified for service {entry['service']}; continuing other owned services", file=sys.stderr)
    for index, entry in enumerate(entries):
        if index not in failures:
            try:
                current = check_owned(entry)
                if not stable(current, entry["previous_task_definition"]):
                    raise Failure("Previous revision is no longer healthy")
                verify_protection(current, restored_configurations.get(index))
            except Exception:
                failures.add(index)
    if failures:
        raise Failure(f"Batch rollback incomplete for {len(failures)} service(s); operator attention required; database unchanged")
    print("Batch rollback verified; the original release remains failed and database migrations are not reversed")


def stop_migration(aws: AwsClient, cluster: str, task: str) -> None:
    try:
        aws.call("stop-task", "--cluster", cluster, "--task", task,
                 "--reason", "Mokaid CI migration failed, interrupted or timed out")
        print(f"Stop requested for migration task {task}", file=sys.stderr)
    except Failure:
        print(f"ERROR: unable to request stop of migration task {task}; operator action required", file=sys.stderr)


def migrate(env: Mapping[str, str], aws: AwsClient) -> None:
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


def interrupted(*_: object) -> NoReturn:
    raise Failure("CI step interrupted")


def main() -> int:
    os.umask(0o077)
    signal.signal(signal.SIGTERM, interrupted)
    try:
        commands = {"prepare": prepare, "deploy": deploy, "migrate": migrate, "rollback-batch": rollback_batch,
                    "validate-trusted-alb": validate_trusted_alb}
        if len(sys.argv) != 2 or sys.argv[1] not in commands:
            raise Failure("Expected prepare, deploy, migrate, rollback-batch or validate-trusted-alb")
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
