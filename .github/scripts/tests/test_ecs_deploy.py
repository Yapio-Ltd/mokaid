"""No AWS credentials/network required: every external AWS command is mocked."""
import contextlib
import copy
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("ecs_deploy", Path(__file__).resolve().parents[1] / "ecs_deploy.py")
ecs = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ecs)
PREFIX = "arn:aws:ecs:eu-west-1:123456789012:task-definition/mokaid-prod-api:"
OLD, NEW, OTHER = PREFIX + "12", PREFIX + "13", PREFIX + "14"
TASK = "arn:aws:ecs:eu-west-1:123456789012:task/mokaid-prod/abcdef123456"
IMAGE = "123456789012.dkr.ecr.eu-west-1.amazonaws.com/mokaid-api@sha256:" + "a" * 64
SERVICE, CONTAINER = "service-api", "mokaid-prod-api"
SENSITIVE = "FIXTURE_LEGACY_ENV_MUST_NOT_APPEAR_IN_LOGS"


def service(arn=OLD, rollout="COMPLETED", running=1):
    return {"status": "ACTIVE", "serviceName": SERVICE, "taskDefinition": arn,
            "deploymentController": {"type": "ECS"}, "desiredCount": 1, "runningCount": running,
            "pendingCount": 0, "platformVersion": "1.4.0",
            "deployments": [{"taskDefinition": arn, "status": "PRIMARY", "rolloutState": rollout,
                             "runningCount": running, "pendingCount": 0}],
            "networkConfiguration": {"awsvpcConfiguration": {"subnets": ["subnet-1234"],
                "securityGroups": ["sg-1234"], "assignPublicIp": "DISABLED"}}}


def definition(arn=OLD):
    return {"taskDefinitionArn": arn, "status": "ACTIVE", "revision": 12, "family": "mokaid-prod-api",
            "registeredAt": "server-only", "compatibilities": ["FARGATE"],
            "networkMode": "awsvpc", "requiresCompatibilities": ["FARGATE"],
            "taskRoleArn": "arn:aws:iam::123456789012:role/app", "cpu": "256", "memory": "512",
            "runtimePlatform": {"cpuArchitecture": "ARM64", "operatingSystemFamily": "LINUX"},
            "containerDefinitions": [{"name": "sidecar-first", "image": "sidecar@sha256:" + "b" * 64},
                {"name": CONTAINER, "image": IMAGE if arn == NEW else "old-image:old",
                 "environment": [{"name": "LEGACY", "value": SENSITIVE}],
                 "secrets": [{"name": "DATABASE_URL", "valueFrom": "arn:aws:secretsmanager:fixture"}]}]}


def migration_task(status="STOPPED", exit_code=0):
    return {"taskArn": TASK, "taskDefinitionArn": NEW, "lastStatus": status,
            "stopCode": "EssentialContainerExited",
            "containers": [{"name": "sidecar-first", "exitCode": 137}, {"name": CONTAINER, "exitCode": exit_code}]}


class MockAws:
    def __init__(self, services=None):
        self.services = copy.deepcopy(services or [service()])
        self.definitions = {OLD: definition(), NEW: definition(NEW)}
        self.calls = []
        self.registered = None
        self.run_payload = None
        self.run_result = {"tasks": [migration_task("RUNNING")], "failures": []}
        self.task_result = {"tasks": [migration_task()], "failures": []}
        self.failures = set()

    def call(self, operation, *arguments, payload=None):
        self.calls.append((operation, arguments, copy.deepcopy(payload)))
        if operation in self.failures:
            raise ecs.Failure("Mock AWS operation failed")
        if operation == "describe-services":
            assert arguments == ("--cluster", "mokaid-prod", "--services", SERVICE)
            value = self.services.pop(0) if len(self.services) > 1 else self.services[0]
            return {"services": [copy.deepcopy(value)], "failures": []}
        if operation == "describe-task-definition":
            assert arguments[0] == "--task-definition"
            return {"taskDefinition": copy.deepcopy(self.definitions[arguments[1]]), "tags": [{"key": "project", "value": "mokaid"}]}
        if operation == "register-task-definition":
            self.registered = copy.deepcopy(payload)
            value = copy.deepcopy(payload)
            value.update(taskDefinitionArn=NEW, status="ACTIVE")
            return {"taskDefinition": value}
        if operation == "update-service":
            return {"service": {"taskDefinition": arguments[5]}}
        if operation == "run-task":
            self.run_payload = copy.deepcopy(payload)
            return copy.deepcopy(self.run_result)
        if operation == "describe-tasks":
            assert arguments == ("--cluster", "mokaid-prod", "--tasks", TASK)
            return copy.deepcopy(self.task_result)
        if operation == "stop-task":
            assert arguments[3] == TASK
            return {"task": migration_task()}
        raise AssertionError(f"Unexpected external operation {operation}")


class Clock:
    def __init__(self):
        self.value = 0
    def now(self):
        return self.value
    def sleep(self, seconds):
        self.value += seconds


class BatchAws:
    def __init__(self):
        self.entries = [{"cluster": "mokaid-prod", "service": f"mokaid-prod-{name}",
                         "task_definition": NEW.replace("mokaid-prod-api:", f"mokaid-prod-{name}:"),
                         "previous_task_definition": OLD.replace("mokaid-prod-api:", f"mokaid-prod-{name}:")}
                        for name in ("api", "ai-worker", "web", "crm")]
        self.current = {entry["service"]: entry["task_definition"] for entry in self.entries}
        self.updates, self.calls = [], []
        self.reads = {entry["service"]: 0 for entry in self.entries}
        self.changes = {}
        self.update_failures = set()
        self.stalled = set()

    def call(self, operation, *arguments, payload=None):
        self.calls.append((operation, arguments))
        if operation == "describe-services":
            name = arguments[3]
            self.reads[name] += 1
            if (name, self.reads[name]) in self.changes:
                self.current[name] = self.changes[(name, self.reads[name])]
            return {"services": [dict(service(self.current[name], "IN_PROGRESS" if name in self.stalled else "COMPLETED"), serviceName=name)], "failures": []}
        if operation == "describe-task-definition":
            return {"taskDefinition": definition(arguments[1])}
        if operation == "update-service":
            name, arn = arguments[3], arguments[5]
            self.updates.append((name, arn))
            if name in self.update_failures:
                raise ecs.Failure("Mock update denied")
            self.current[name] = arn
            return {"service": {"taskDefinition": arn}}
        raise AssertionError(f"Unexpected external operation {operation}")


class EcsTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.output = Path(self.directory.name) / "github-output"
        self.output.touch()
        self.env = {"CLUSTER": "mokaid-prod", "SERVICE": SERVICE, "CONTAINER": CONTAINER,
                    "IMAGE": IMAGE, "TASK_DEFINITION": NEW, "PREVIOUS_TASK_DEFINITION": OLD,
                    "GITHUB_OUTPUT": str(self.output), "DEPLOY_TIMEOUT_SECONDS": "2",
                    "ROLLBACK_TIMEOUT_SECONDS": "2", "MIGRATION_TIMEOUT_SECONDS": "2", "POLL_INTERVAL_SECONDS": "1"}
        self.stdout, self.stderr = io.StringIO(), io.StringIO()
        self.enterContext(contextlib.redirect_stdout(self.stdout))
        self.enterContext(contextlib.redirect_stderr(self.stderr))
        # A missed mock fails the test rather than ever invoking the AWS CLI.
        self.enterContext(patch.object(ecs.subprocess, "run", side_effect=AssertionError("External commands forbidden in unit tests")))

    def updates(self, aws):
        return [args[5] for operation, args, _ in aws.calls if operation == "update-service"]

    def test_prepare_uses_active_revision_and_named_nonfirst_container(self):
        aws = MockAws()
        ecs.prepare(self.env, aws)
        self.assertEqual(aws.calls[1][1][1], OLD)
        self.assertEqual(aws.registered["containerDefinitions"][0], definition()["containerDefinitions"][0])
        self.assertEqual(aws.registered["containerDefinitions"][1]["image"], IMAGE)
        self.assertEqual(aws.registered["containerDefinitions"][1]["secrets"], definition()["containerDefinitions"][1]["secrets"])
        self.assertEqual(aws.registered["runtimePlatform"], definition()["runtimePlatform"])
        self.assertNotIn("taskDefinitionArn", aws.registered)
        self.assertNotIn("registeredAt", aws.registered)
        self.assertEqual(aws.registered["tags"], [{"key": "project", "value": "mokaid"}])
        self.assertIn(f"task_definition={NEW}\n", self.output.read_text())
        self.assertIn(f"previous_task_definition={OLD}\n", self.output.read_text())
        self.assertNotIn(SENSITIVE, self.stdout.getvalue() + self.stderr.getvalue() + self.output.read_text())
        self.assertEqual(self.updates(aws), [])

    def test_prepare_rejects_mutable_or_missing_image_without_aws(self):
        for value in ("repo:latest", "repo:tag", "", IMAGE + "\nforged=true"):
            aws = MockAws()
            with self.assertRaises(ecs.Failure):
                ecs.prepare(dict(self.env, IMAGE=value), aws)
            self.assertEqual(aws.calls, [])

    def test_prepare_rejects_wrong_or_duplicate_container(self):
        for duplicate in (False, True):
            aws = MockAws()
            if duplicate:
                aws.definitions[OLD]["containerDefinitions"].append(copy.deepcopy(aws.definitions[OLD]["containerDefinitions"][1]))
            else:
                aws.definitions[OLD]["containerDefinitions"].pop()
            with self.assertRaises(ecs.Failure):
                ecs.prepare(self.env, aws)
            self.assertIsNone(aws.registered)

    def test_prepare_rejects_unhealthy_baseline_and_missing_service(self):
        for baseline in (service(rollout="IN_PROGRESS"), service(running=0), dict(service(), status="INACTIVE")):
            aws = MockAws([baseline])
            with self.assertRaises(ecs.Failure):
                ecs.prepare(self.env, aws)
            self.assertIsNone(aws.registered)
        aws = MockAws()
        with patch.object(aws, "call", return_value={"services": [], "failures": [{"reason": "MISSING"}]}):
            with self.assertRaises(ecs.Failure):
                ecs.prepare(self.env, aws)

    def test_only_exact_api_environment_overrides_are_accepted(self):
        aws = MockAws()
        env = dict(self.env, MOKAID_DESKTOP_ONLY_BUSINESS="false", DESKTOP_AUTH_WEB_BASE_URL="https://mokaid.com", ARBITRARY_ENV="ignored")
        ecs.prepare(env, aws)
        settings = {item["name"]: item["value"] for item in aws.registered["containerDefinitions"][1]["environment"]}
        self.assertEqual(settings["MOKAID_DESKTOP_ONLY_BUSINESS"], "false")
        self.assertEqual(settings["DESKTOP_AUTH_WEB_BASE_URL"], "https://mokaid.com")
        self.assertNotIn("ARBITRARY_ENV", settings)
        for invalid in ({"MOKAID_DESKTOP_ONLY_BUSINESS": "1"}, {"DESKTOP_AUTH_WEB_BASE_URL": "https://evil.invalid"},
                        {"CONTAINER": "mokaid-prod-web", "MOKAID_DESKTOP_ONLY_BUSINESS": "true"}):
            with self.assertRaises(ecs.Failure):
                ecs.prepare(dict(self.env, **invalid), MockAws())

    def test_environment_secret_collision_is_rejected(self):
        aws = MockAws()
        aws.definitions[OLD]["containerDefinitions"][1]["secrets"].append({"name": "MOKAID_DESKTOP_ONLY_BUSINESS", "valueFrom": "secret-ref"})
        with self.assertRaises(ecs.Failure):
            ecs.prepare(dict(self.env, MOKAID_DESKTOP_ONLY_BUSINESS="true"), aws)
        self.assertIsNone(aws.registered)

    def test_deploy_requires_prepared_exact_arns_and_refuses_stale_baseline(self):
        for change in ({"TASK_DEFINITION": "mokaid-prod-api"}, {"TASK_DEFINITION": ""}, {"PREVIOUS_TASK_DEFINITION": ""}):
            aws = MockAws()
            with self.assertRaises(ecs.Failure):
                ecs.deploy(dict(self.env, **change), aws)
            self.assertEqual(aws.calls, [])
        aws = MockAws([service(OTHER)])
        with self.assertRaises(ecs.Failure):
            ecs.deploy(self.env, aws)
        self.assertEqual(self.updates(aws), [])

    def test_deploy_success_verifies_exact_completed_revision(self):
        aws = MockAws([service(), service(NEW)])
        ecs.deploy(self.env, aws)
        self.assertEqual(self.updates(aws), [NEW])
        self.assertIn("Verified deployment", self.stdout.getvalue())

    def test_failed_rollout_restores_and_verifies_previous_but_stays_failed(self):
        aws = MockAws([service(), service(NEW, "FAILED"), service(NEW, "FAILED"), service()])
        with self.assertRaisesRegex(ecs.Failure, "previous revision is healthy"):
            ecs.deploy(self.env, aws)
        self.assertEqual(self.updates(aws), [NEW, OLD])
        self.assertNotIn("Verified deployment", self.stdout.getvalue())

    def test_stable_automatic_rollback_never_counts_as_success(self):
        aws = MockAws([service(), service(NEW, "IN_PROGRESS"), service(), service()])
        clock = Clock()
        with patch.object(ecs.time, "monotonic", clock.now), patch.object(ecs.time, "sleep", clock.sleep):
            with self.assertRaises(ecs.Failure):
                ecs.deploy(self.env, aws)
        self.assertEqual(self.updates(aws), [NEW])

    def test_wrong_revision_or_running_counts_timeout_without_false_success(self):
        for wrong in (service(), service(NEW, running=0)):
            aws = MockAws([wrong])
            clock = Clock()
            with self.assertRaisesRegex(ecs.Failure, "Timed out"):
                ecs.await_service(aws, "mokaid-prod", SERVICE, NEW, OLD, 2, 1, clock=clock.now, sleep=clock.sleep)
            self.assertEqual(clock.value, 2)

    def test_concurrent_release_is_never_overwritten_by_rollback(self):
        aws = MockAws([service(), service(OTHER), service(OTHER)])
        with self.assertRaisesRegex(ecs.Failure, "operator attention"):
            ecs.deploy(self.env, aws)
        self.assertEqual(self.updates(aws), [NEW])

    def test_failed_rollback_requires_operator_attention(self):
        aws = MockAws([service(), service(NEW, "FAILED"), service(NEW, "FAILED")])
        original = aws.call
        def fail_previous(operation, *arguments, **kwargs):
            if operation == "update-service" and arguments[5] == OLD:
                raise ecs.Failure("Mock rollback denied")
            return original(operation, *arguments, **kwargs)
        with patch.object(aws, "call", side_effect=fail_previous):
            with self.assertRaisesRegex(ecs.Failure, "rollback could not be verified"):
                ecs.deploy(self.env, aws)
        self.assertNotIn("restored and verified", self.stderr.getvalue())

    def test_migration_uses_exact_revision_service_network_and_named_container(self):
        aws = MockAws()
        ecs.migrate(self.env, aws)
        self.assertEqual(aws.run_payload["taskDefinition"], NEW)
        self.assertEqual(aws.run_payload["networkConfiguration"], service()["networkConfiguration"])
        self.assertEqual(aws.run_payload["overrides"], {"containerOverrides": [{"name": CONTAINER,
            "command": ["bin/mokaid", "eval", "Mokaid.Release.migrate()"]}]})
        self.assertEqual(aws.run_payload["clientToken"], aws.run_payload["startedBy"])
        self.assertRegex(aws.run_payload["clientToken"], r"^mokaid-migration-[a-f0-9]{32}$")
        self.assertEqual(self.updates(aws), [])
        self.assertEqual([call[0] for call in aws.calls if call[0] == "stop-task"], [])

    def test_migration_rejects_wrong_container_and_family_latest(self):
        for change in ({"CONTAINER": "missing"}, {"TASK_DEFINITION": "mokaid-prod-api"}, {"SERVICE": "missing"}):
            aws = MockAws()
            with self.assertRaises((ecs.Failure, AssertionError)):
                ecs.migrate(dict(self.env, **change), aws)
            self.assertIsNone(aws.run_payload)

    def test_migration_run_failures_abort_and_stop_any_known_partial_task(self):
        for tasks in ([], [migration_task("RUNNING")]):
            aws = MockAws()
            aws.run_result = {"tasks": tasks, "failures": [{"reason": "RESOURCE:MEMORY"}]}
            with self.assertRaisesRegex(ecs.Failure, "run-task failed"):
                ecs.migrate(self.env, aws)
            self.assertEqual(sum(call[0] == "stop-task" for call in aws.calls), len(tasks))

    def test_nonzero_missing_or_wrong_container_exit_is_failure(self):
        for containers in ([{"name": CONTAINER, "exitCode": 2}], [{"name": CONTAINER}],
                           [{"name": CONTAINER, "exitCode": False}], [{"name": CONTAINER, "exitCode": "0"}],
                           [{"name": "sidecar-first", "exitCode": 0}]):
            aws = MockAws()
            aws.task_result["tasks"][0]["containers"] = containers
            with self.assertRaisesRegex(ecs.Failure, "did not exit successfully"):
                ecs.migrate(self.env, aws)

    def test_migration_timeout_stops_only_the_created_task(self):
        aws = MockAws()
        aws.task_result["tasks"][0]["lastStatus"] = "RUNNING"
        clock = Clock()
        with patch.object(ecs.time, "monotonic", clock.now), patch.object(ecs.time, "sleep", clock.sleep):
            with self.assertRaisesRegex(ecs.Failure, "bounded timeout"):
                ecs.migrate(self.env, aws)
        self.assertEqual(sum(call[0] == "stop-task" for call in aws.calls), 1)
        self.assertEqual(clock.value, 2)

    def test_migration_lookup_failure_requests_stop(self):
        aws = MockAws()
        aws.task_result = {"tasks": [], "failures": [{"reason": "MISSING"}]}
        with self.assertRaisesRegex(ecs.Failure, "lookup failed"):
            ecs.migrate(self.env, aws)
        self.assertEqual(sum(call[0] == "stop-task" for call in aws.calls), 1)

    def test_migration_retries_only_initial_matching_missing_response(self):
        aws = MockAws()
        original = aws.call
        remaining = [{"tasks": [], "failures": [{"arn": TASK, "reason": "MISSING"}]}, aws.task_result]
        def eventual_task(operation, *arguments, **kwargs):
            if operation == "describe-tasks":
                return remaining.pop(0)
            return original(operation, *arguments, **kwargs)
        clock = Clock()
        with patch.object(aws, "call", side_effect=eventual_task), patch.object(ecs.time, "monotonic", clock.now), patch.object(ecs.time, "sleep", clock.sleep):
            ecs.migrate(self.env, aws)
        self.assertEqual(clock.value, 1)
        self.assertEqual(remaining, [])

    def test_migration_stale_or_unhealthy_baseline_never_runs(self):
        for baseline in (service(OTHER), service(rollout="IN_PROGRESS"), service(running=0)):
            aws = MockAws([baseline])
            with self.assertRaises(ecs.Failure):
                ecs.migrate(self.env, aws)
            self.assertIsNone(aws.run_payload)

    def test_migration_interruption_requests_stop(self):
        aws = MockAws()
        original = aws.call
        def interrupt(operation, *arguments, **kwargs):
            if operation == "describe-tasks":
                raise KeyboardInterrupt()
            return original(operation, *arguments, **kwargs)
        with patch.object(aws, "call", side_effect=interrupt):
            with self.assertRaises(KeyboardInterrupt):
                ecs.migrate(self.env, aws)
        self.assertEqual(sum(call[0] == "stop-task" for call in aws.calls), 1)

    def test_migration_stop_denied_keeps_failure_and_requires_operator(self):
        aws = MockAws()
        aws.failures.add("stop-task")
        aws.task_result = {"tasks": [], "failures": [{"reason": "MISSING"}]}
        with self.assertRaisesRegex(ecs.Failure, "lookup failed"):
            ecs.migrate(self.env, aws)
        self.assertIn("operator action required", self.stderr.getvalue())
        self.assertNotIn("Migration completed successfully", self.stdout.getvalue())

    def test_unknown_run_task_outcome_is_never_blindly_retried(self):
        aws = MockAws()
        aws.failures.add("run-task")
        with self.assertRaisesRegex(ecs.Failure, "submission outcome unknown") as failure:
            ecs.migrate(self.env, aws)
        self.assertRegex(str(failure.exception), r"startedBy=mokaid-migration-[a-f0-9]{32}")
        self.assertEqual(sum(call[0] == "run-task" for call in aws.calls), 1)
        self.assertEqual(sum(call[0] == "stop-task" for call in aws.calls), 0)

    def test_batch_rollback_restores_all_services_in_reverse_order(self):
        aws = BatchAws()
        ecs.rollback_batch(dict(self.env, ROLLBACK_BATCH_JSON=json.dumps(aws.entries)), aws)
        self.assertEqual(aws.updates, [(entry["service"], entry["previous_task_definition"]) for entry in reversed(aws.entries)])
        self.assertTrue(all(aws.current[entry["service"]] == entry["previous_task_definition"] for entry in aws.entries))
        self.assertIn("original release remains failed", self.stdout.getvalue())

    def test_batch_rollback_skips_already_healthy_previous_revision(self):
        aws = BatchAws()
        aws.current[aws.entries[1]["service"]] = aws.entries[1]["previous_task_definition"]
        ecs.rollback_batch(dict(self.env, ROLLBACK_BATCH_JSON=json.dumps(aws.entries)), aws)
        self.assertEqual(len(aws.updates), 3)
        self.assertNotIn(aws.entries[1]["service"], [name for name, _ in aws.updates])

    def test_batch_preserves_third_party_and_restores_other_owned_services(self):
        for change_after_preflight in (False, True):
            aws = BatchAws()
            name = aws.entries[2]["service"]
            other = aws.entries[2]["task_definition"].rsplit(":", 1)[0] + ":99"
            if change_after_preflight:
                aws.changes[(name, 2)] = other
            else:
                aws.current[name] = other
            with self.assertRaisesRegex(ecs.Failure, "incomplete for 1"):
                ecs.rollback_batch(dict(self.env, ROLLBACK_BATCH_JSON=json.dumps(aws.entries)), aws)
            self.assertEqual([service_name for service_name, _ in aws.updates], [aws.entries[index]["service"] for index in (3, 1, 0)])
            self.assertEqual(aws.current[name], other)

    def test_batch_continues_remaining_owned_services_after_update_failure(self):
        aws = BatchAws()
        aws.update_failures.add(aws.entries[1]["service"])
        with self.assertRaisesRegex(ecs.Failure, "operator attention"):
            ecs.rollback_batch(dict(self.env, ROLLBACK_BATCH_JSON=json.dumps(aws.entries)), aws)
        self.assertEqual(aws.updates[-1], (aws.entries[0]["service"], aws.entries[0]["previous_task_definition"]))
        self.assertNotIn("Batch rollback verified", self.stdout.getvalue())

    def test_batch_final_verification_detects_a_late_third_party_change(self):
        aws = BatchAws()
        name = aws.entries[3]["service"]
        other = aws.entries[3]["task_definition"].rsplit(":", 1)[0] + ":99"
        aws.changes[(name, 4)] = other
        with self.assertRaisesRegex(ecs.Failure, "incomplete for 1"):
            ecs.rollback_batch(dict(self.env, ROLLBACK_BATCH_JSON=json.dumps(aws.entries)), aws)
        self.assertEqual(aws.current[name], other)
        self.assertEqual(len([item for item in aws.updates if item[0] == name]), 1)

    def test_batch_timeout_is_bounded_and_other_services_are_restored(self):
        aws = BatchAws()
        aws.stalled.add(aws.entries[2]["service"])
        clock = Clock()
        with patch.object(ecs.time, "monotonic", clock.now), patch.object(ecs.time, "sleep", clock.sleep):
            with self.assertRaisesRegex(ecs.Failure, "incomplete for 1"):
                ecs.rollback_batch(dict(self.env, ROLLBACK_BATCH_JSON=json.dumps(aws.entries)), aws)
        self.assertEqual(clock.value, 2)
        self.assertEqual(len(aws.updates), 4)

    def test_invalid_batch_is_rejected_before_any_aws_call(self):
        entry = BatchAws().entries[0]
        batches = ([], [entry, entry], [dict(entry, service="invalid/name")],
                   [dict(entry, task_definition="mokaid-prod-api")], [dict(entry, extra="unexpected")],
                   [dict(entry, previous_task_definition=entry["task_definition"])],
                   [dict(entry, previous_task_definition=OLD.replace("mokaid-prod-api", "other-family"))])
        for batch in batches:
            aws = BatchAws()
            with self.assertRaises(ecs.Failure):
                ecs.rollback_batch(dict(self.env, ROLLBACK_BATCH_JSON=json.dumps(batch)), aws)
            self.assertEqual(aws.calls, [])

    def test_aws_cli_uses_private_json_file_and_suppresses_sensitive_errors(self):
        def external(command, **kwargs):
            self.assertEqual(command[:3], ["aws", "ecs", "register-task-definition"])
            self.assertNotIn(SENSITIVE, " ".join(command))
            path = Path(command[command.index("--cli-input-json") + 1].removeprefix("file://"))
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(json.loads(path.read_text()), {"environment": SENSITIVE})
            self.assertEqual(kwargs["timeout"], 60)
            return subprocess.CompletedProcess(command, 1, SENSITIVE, SENSITIVE)
        with patch.object(ecs.subprocess, "run", side_effect=external):
            with self.assertRaises(ecs.Failure) as failure:
                ecs.Aws().call("register-task-definition", payload={"environment": SENSITIVE})
        self.assertNotIn(SENSITIVE, str(failure.exception) + self.stdout.getvalue() + self.stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
