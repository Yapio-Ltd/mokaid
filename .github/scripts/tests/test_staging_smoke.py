import importlib.util
import json
import os
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("staging_smoke", Path(__file__).parents[1] / "staging_smoke.py")
staging = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(staging)
IMAGE = "sha256:" + "a" * 64
IDENTITY = "b" * 64


def result(stdout="", code=0, stderr=""):
    return subprocess.CompletedProcess([], code, stdout, stderr)


class StagingTests(unittest.TestCase):
    def smoke(self):
        with patch.dict(os.environ, {}, clear=True):
            return staging.Smoke({"api": IMAGE, "web": IMAGE}, 60)

    def test_only_immutable_image_inputs(self):
        for value in ["latest", "api:1234", "--help", "sha256:abc", IMAGE + "\n", "https://bad image@" + IMAGE]:
            with self.subTest(value=value), self.assertRaises(staging.SmokeError):
                staging.image_ref(value, "API_IMAGE")
        self.assertEqual(staging.image_ref("example.com:5000/api@" + IMAGE, "API_IMAGE"), "example.com:5000/api@" + IMAGE)
        self.assertEqual(staging.image_ref(IMAGE, "API_IMAGE"), IMAGE)

    def test_rejects_missing_images_and_unbounded_timeout(self):
        with self.assertRaises(staging.SmokeError):
            staging.Smoke({"api": IMAGE})
        for timeout in (0, 59, 901):
            with self.assertRaises(staging.SmokeError):
                staging.Smoke({"api": IMAGE, "web": IMAGE}, timeout)

    def test_worker_is_optional_and_uses_the_same_immutable_image_contract(self) -> None:
        for optional in ({}, {"crm": IMAGE}, {"worker": IMAGE}, {"crm": IMAGE, "worker": IMAGE}):
            with self.subTest(optional=tuple(optional)):
                smoke = staging.Smoke({"api": IMAGE, "web": IMAGE, **optional}, 60)
                self.assertEqual(smoke.images, {"api": IMAGE, "web": IMAGE, **optional})
        for images in ({"api": IMAGE, "worker": IMAGE},
                       {"api": IMAGE, "web": IMAGE, "worker": "worker:latest"},
                       {"api": IMAGE, "web": IMAGE, "unknown": IMAGE}):
            with self.subTest(images=images), self.assertRaises(staging.SmokeError):
                staging.Smoke(images, 60)

    def test_worker_environment_disables_consumers_providers_and_tracing(self) -> None:
        production = {"AI_RUNS_QUEUE_URL": "https://queue.production", "DATABASE_URL": "production-db",
                      "WORKER_AUTH_TOKEN": "production-token", "OPENAI_API_KEY": "production-key",
                      "AWS_SECRET_ACCESS_KEY": "production-aws", "LANGSMITH_API_KEY": "production-trace",
                      "OTEL_EXPORTER_OTLP_HEADERS": "secret-header", "HTTPS_PROXY": "http://proxy"}
        with patch.dict(os.environ, production):
            first = staging.worker_fixture_environment()
            second = staging.worker_fixture_environment()
            host = staging.host_environment()
        self.assertNotEqual(first["WORKER_AUTH_TOKEN"], second["WORKER_AUTH_TOKEN"])
        self.assertEqual(len(first["WORKER_AUTH_TOKEN"]), 64)
        for name in ("AI_RUNS_QUEUE_URL", "DATABASE_URL", "OPENAI_API_KEY", "ANTHROPIC_API_KEY",
                     "DEEPSEEK_API_KEY", "TAVILY_API_KEY", "LANGSMITH_API_KEY", "LANGCHAIN_API_KEY",
                     "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN"):
            self.assertEqual(first[name], "")
        self.assertEqual(first["PHOENIX_API_URL"], "http://127.0.0.1:9")
        self.assertEqual(first["S3_ENDPOINT"], "http://127.0.0.1:9")
        self.assertEqual(first["LANGSMITH_TRACING"], "false")
        self.assertEqual(first["LANGCHAIN_TRACING_V2"], "false")
        self.assertEqual(first["OTEL_SDK_DISABLED"], "true")
        self.assertEqual(first["AWS_EC2_METADATA_DISABLED"], "true")
        self.assertFalse(set(host) & set(production))

    def test_worker_container_preserves_real_entrypoint_and_separate_fixture(self) -> None:
        smoke = self.smoke()
        smoke.network = smoke.prefix
        smoke.resolved = {"worker": IMAGE}
        inspected = {"Image": IMAGE, "Config": {"Labels": {staging.LABEL: smoke.run_id}},
                     "NetworkSettings": {"Networks": {smoke.network: {}}}}
        with patch.object(smoke, "docker", return_value=result()) as docker, patch.object(smoke, "inspect", return_value=inspected):
            name = smoke.create("worker")
        args = docker.call_args.args
        self.assertEqual(args[-1], IMAGE)
        self.assertNotIn("--entrypoint", args)
        self.assertNotIn("--publish", args)
        self.assertNotIn("--volume", args)
        self.assertNotIn("--mount", args)
        self.assertIn("--pids-limit", args)
        self.assertIn("--memory", args)
        self.assertIn("--cpus", args)
        self.assertIn("--cap-drop", args)
        self.assertIn("WORKER_AUTH_TOKEN", args)
        self.assertNotIn("AI_WORKER_TOKEN", args)
        self.assertNotIn("POSTGRES_PASSWORD", args)
        self.assertNotIn("SECRET_KEY_BASE", args)
        self.assertNotIn(smoke.worker_fixture["WORKER_AUTH_TOKEN"], args)
        self.assertEqual(docker.call_args.kwargs, {"fixture": False, "worker_fixture": True})
        self.assertEqual(smoke.containers, [name])
        with patch.object(staging.subprocess, "run", return_value=result()) as command:
            smoke.command(["docker", "version"], worker_fixture=True)
        passed = command.call_args.kwargs["env"]
        self.assertEqual(passed["DATABASE_URL"], "")
        self.assertNotIn("SECRET_KEY_BASE", passed)
        self.assertNotIn("POSTGRES_PASSWORD", passed)
        self.assertNotIn("AI_WORKER_TOKEN", passed)
        with self.assertRaises(staging.SmokeError):
            smoke.command(["docker", "version"], fixture=True, worker_fixture=True)

    def test_generated_fixtures_do_not_inherit_production_credentials(self):
        with patch.dict(os.environ, {"DATABASE_URL": "production-secret", "AWS_SECRET_ACCESS_KEY": "aws-secret",
                                     "STRIPE_SECRET_KEY": "stripe-secret", "HTTP_PROXY": "http://proxy"}):
            first = staging.fixture_environment("true")
            second = staging.fixture_environment("true")
            env = staging.host_environment()
        self.assertNotEqual(first["POSTGRES_PASSWORD"], second["POSTGRES_PASSWORD"])
        self.assertIn("@postgres:5432/mokaid_staging_test", first["DATABASE_URL"])
        self.assertEqual(first["MOKAID_DESKTOP_ONLY_BUSINESS"], "true")
        self.assertFalse(set(env) & {"DATABASE_URL", "AWS_SECRET_ACCESS_KEY", "STRIPE_SECRET_KEY", "HTTP_PROXY"})
        with self.assertRaises(staging.SmokeError):
            staging.fixture_environment("1")

    def test_container_uses_environment_names_not_secret_argv(self):
        smoke = self.smoke()
        smoke.network = smoke.prefix
        smoke.resolved = {"api": IMAGE}
        inspected = {"Image": IMAGE, "Config": {"Labels": {staging.LABEL: smoke.run_id}},
                     "NetworkSettings": {"Networks": {smoke.network: {}}}}
        with patch.object(smoke, "docker", return_value=result()) as docker, patch.object(smoke, "inspect", return_value=inspected):
            smoke.create("api", command=("bin/mokaid", "eval", staging.START))
        args = docker.call_args.args
        self.assertIn("DATABASE_URL", args)
        self.assertNotIn("--publish", args)
        self.assertNotIn(smoke.fixture["DATABASE_URL"], args)
        self.assertNotIn(smoke.fixture["SECRET_KEY_BASE"], " ".join(args))
        self.assertEqual(args[-4:], (IMAGE, "bin/mokaid", "eval", staging.START))

    def test_create_rejects_extra_network_or_replaced_image(self):
        smoke = self.smoke()
        smoke.network = smoke.prefix
        smoke.resolved = {"web": IMAGE}
        for inspected in [
            {"Image": "sha256:" + "b" * 64, "Config": {"Labels": {staging.LABEL: smoke.run_id}}},
            {"Image": IMAGE, "Config": {"Labels": {staging.LABEL: smoke.run_id}},
             "NetworkSettings": {"Networks": {smoke.network: {}, "bridge": {}}}},
        ]:
            with patch.object(smoke, "docker", return_value=result()), patch.object(smoke, "inspect", return_value=inspected):
                with self.assertRaises(staging.SmokeError):
                    smoke.create("web")

    def test_network_must_be_internal_and_owned(self):
        smoke = self.smoke()
        with patch.object(smoke, "docker", return_value=result()) as docker, patch.object(smoke, "inspect", return_value={"Internal": False}):
            with self.assertRaises(staging.SmokeError):
                smoke.create_network()
        self.assertIn("--internal", docker.call_args.args)
        self.assertEqual(smoke.network, smoke.prefix)

    def test_probe_shares_only_owned_namespace_and_has_no_secrets(self):
        smoke = self.smoke()
        smoke.network = smoke.prefix
        smoke.resolved = {"probe": IMAGE}
        target = {"Id": IDENTITY, "Config": {"Labels": {staging.LABEL: smoke.run_id}},
                  "NetworkSettings": {"Networks": {smoke.network: {}}}}
        probe = {"Image": IMAGE, "Config": {"Labels": {staging.LABEL: smoke.run_id}},
                 "HostConfig": {"NetworkMode": "container:" + IDENTITY}}
        with patch.object(smoke, "inspect", side_effect=[target, probe]), patch.object(smoke, "docker", return_value=result()) as docker, patch.object(smoke, "wait_for"):
            smoke.probe("web", "owned-web")
        args = docker.call_args_list[0].args
        self.assertIn("container:" + IDENTITY, args)
        self.assertNotIn("--env", args)
        self.assertNotIn("--publish", args)
        self.assertIn('const smokeOrigin = "http://127.0.0.1";', args[-1])
        self.assertIn(Path(staging.__file__).with_name("verify-production.mjs").read_text(), args[-1])
        self.assertNotIn(smoke.fixture["SECRET_KEY_BASE"], args[-1])

    def test_probe_rejects_foreign_target(self):
        smoke = self.smoke()
        with patch.object(smoke, "inspect", return_value={"Id": IDENTITY}), patch.object(smoke, "docker") as docker:
            with self.assertRaises(staging.SmokeError):
                smoke.probe("api", "foreign")
        docker.assert_not_called()

    def test_worker_probe_uses_real_loopback_http_and_anonymous_get_only(self) -> None:
        smoke = self.smoke()
        smoke.network = smoke.prefix
        smoke.resolved = {"probe": IMAGE}
        target = {"Id": IDENTITY, "Config": {"Labels": {staging.LABEL: smoke.run_id}},
                  "NetworkSettings": {"Networks": {smoke.network: {}}}}
        probe = {"Image": IMAGE, "Config": {"Labels": {staging.LABEL: smoke.run_id}},
                 "HostConfig": {"NetworkMode": "container:" + IDENTITY}}
        with patch.object(smoke, "inspect", side_effect=[target, probe]), patch.object(smoke, "docker", return_value=result()) as docker, patch.object(smoke, "wait_for"):
            smoke.probe("worker", "owned-worker")
        args = docker.call_args_list[0].args
        code = args[-1]
        self.assertIn("container:" + IDENTITY, args)
        self.assertIn('const smokeOrigin = "http://127.0.0.1:8100";', code)
        self.assertIn('health.status !== "ok"', code)
        self.assertIn('"/runs/fixture-validation"', code)
        self.assertIn('denied.status !== 401', code)
        self.assertIn('method: "GET"', code)
        self.assertNotIn("POST", code)
        self.assertNotIn("Authorization", code)
        self.assertNotIn("Bearer", code)
        self.assertNotIn("--env", args)
        self.assertNotIn("--publish", args)
        self.assertNotIn(smoke.worker_fixture["WORKER_AUTH_TOKEN"], code)

    def test_worker_and_verifier_cleanup_removes_only_owned_ids_in_reverse_order(self) -> None:
        smoke = self.smoke()
        worker = smoke.prefix + "-worker"
        probe = smoke.prefix + "-probe-worker"
        smoke.containers = [worker, probe]
        ids = {worker: "c" * 64, probe: "d" * 64}
        calls: list[tuple[str, ...]] = []
        def docker(*args: str, **kwargs: object) -> subprocess.CompletedProcess[str]:
            calls.append(args)
            if args[:2] == ("container", "inspect"):
                return result(json.dumps([{"Id": ids[args[2]], "Config": {"Labels": {staging.LABEL: smoke.run_id}}}]))
            return result()
        with patch.object(smoke, "docker", side_effect=docker):
            self.assertEqual(smoke.cleanup(), [])
        self.assertEqual([call for call in calls if call[0] == "rm"],
                         [("rm", "--force", "--volumes", ids[probe]),
                          ("rm", "--force", "--volumes", ids[worker])])

    def test_optional_worker_runs_its_image_command_then_http_probe(self) -> None:
        smoke = staging.Smoke({"api": IMAGE, "web": IMAGE, "worker": IMAGE}, 60)
        with patch("builtins.print"), patch.object(smoke, "validate_daemon"), patch.object(smoke, "resolve_images"), patch.object(smoke, "create_network"), patch.object(smoke, "command"), patch.object(smoke, "docker"), patch.object(staging.os, "chmod"), patch.object(smoke, "create", side_effect=lambda role, **kwargs: role) as create, patch.object(smoke, "wait_for"), patch.object(smoke, "probe") as probe:
            smoke.execute()
        create.assert_any_call("worker")
        probe.assert_any_call("worker", "worker")
        self.assertEqual(smoke.checks[-2:], ["worker-health", "worker-unauthenticated-401"])

    def test_entrypoint_accepts_worker_digest_and_always_cleans_up_after_failure(self) -> None:
        images = {"API_IMAGE": IMAGE, "WEB_IMAGE": IMAGE, "WORKER_IMAGE": IMAGE}
        with patch("builtins.print"), patch.dict(os.environ, images, clear=True), patch.object(staging.sys, "argv", ["staging_smoke.py"]), patch.object(staging.signal, "signal"), patch.object(staging, "Smoke") as factory:
            smoke = factory.return_value
            smoke.execute.side_effect = staging.SmokeError("Actual worker loopback verification failed")
            smoke.diagnostics.return_value = None
            smoke.cleanup.return_value = []
            self.assertEqual(staging.main(), 1)
        factory.assert_called_once_with({"api": IMAGE, "web": IMAGE, "worker": IMAGE}, 420)
        smoke.execute.assert_called_once_with()
        smoke.cleanup.assert_called_once_with()

    def test_migration_requires_exit_zero_and_completion_marker(self):
        smoke = self.smoke()
        for state in [{"Running": False, "Status": "exited", "ExitCode": 1},
                      {"Running": False, "Status": "exited", "ExitCode": 0, "OOMKilled": True},
                      {"Running": False, "Status": "created", "ExitCode": 0}]:
            with patch.object(smoke, "inspect", return_value={"State": state}):
                with self.assertRaises(staging.SmokeError):
                    smoke.migration_done("migration")
        with patch.object(smoke, "inspect", return_value={"State": {"Running": False, "Status": "exited", "ExitCode": 0}}):
            with patch.object(smoke, "docker", return_value=result("no marker")), self.assertRaises(staging.SmokeError):
                smoke.migration_done("migration")
            with patch.object(smoke, "docker", return_value=result("STAGING_MIGRATIONS_OK")):
                self.assertTrue(smoke.migration_done("migration"))

    def test_migration_wait_is_bounded(self):
        smoke = self.smoke()
        with patch.object(staging.time, "monotonic", side_effect=[0, 1, 62]), patch.object(staging.time, "sleep"):
            with self.assertRaisesRegex(staging.SmokeError, "Timeout"):
                smoke.wait_for(lambda: False, "migration")

    def test_cleanup_never_removes_foreign_resources_and_continues_owned(self):
        smoke = self.smoke()
        smoke.containers = ["owned", "foreign"]
        smoke.network = "owned-network"
        calls = []
        def docker(*args, **kwargs):
            calls.append(args)
            if args[:2] == ("container", "inspect"):
                label = smoke.run_id if args[2] == "owned" else "another-run"
                return result(json.dumps([{"Id": IDENTITY, "Config": {"Labels": {staging.LABEL: label}}}]))
            if args[:2] == ("network", "inspect"):
                return result(json.dumps([{"Id": "c" * 64, "Labels": {staging.LABEL: smoke.run_id}}]))
            return result()
        with patch.object(smoke, "docker", side_effect=docker):
            self.assertEqual(smoke.cleanup(), ["foreign"])
        self.assertEqual([args for args in calls if args[0] == "rm"], [("rm", "--force", "--volumes", IDENTITY)])
        self.assertIn(("network", "rm", "c" * 64), calls)

    def test_absent_resources_safe_but_unavailable_daemon_fails_cleanup(self):
        smoke = self.smoke()
        smoke.containers = ["owned"]
        with patch.object(smoke, "docker", return_value=result(code=1, stderr="No such container")):
            self.assertEqual(smoke.cleanup(), [])
        with patch.object(smoke, "docker", return_value=result(code=1, stderr="Cannot connect")):
            self.assertEqual(smoke.cleanup(), ["owned"])

    def test_fixture_secrets_and_database_urls_redacted(self):
        smoke = self.smoke()
        original = " ".join(smoke.fixture[key] for key in ("DATABASE_URL", "POSTGRES_PASSWORD", "SECRET_KEY_BASE", "AI_WORKER_TOKEN"))
        redacted = smoke.redact(original + " postgres://u:secret@other/database Bearer secret-token")
        for key in ("DATABASE_URL", "POSTGRES_PASSWORD", "SECRET_KEY_BASE", "AI_WORKER_TOKEN"):
            self.assertNotIn(smoke.fixture[key], redacted)
        self.assertNotIn("secret-token", redacted)
        self.assertNotIn("u:secret", redacted)
        self.assertNotIn(smoke.worker_fixture["WORKER_AUTH_TOKEN"],
                         smoke.redact(smoke.worker_fixture["WORKER_AUTH_TOKEN"]))

    def test_fixed_prelude_preserves_real_migrations_and_db_tls(self):
        self.assertIn("Mokaid.Release.migrate()", staging.MIGRATE)
        self.assertNotIn("ssl: false", staging.PRELUDE)
        self.assertIn("testing: :manual, queues: false, plugins: false", staging.PRELUDE)
        self.assertIn("Req.default_options(adapter:", staging.PRELUDE)
        self.assertIn("Application.ensure_all_started(:mokaid)", staging.START)
        self.assertIn("pg_stat_ssl", staging.START)
        self.assertNotIn("Mokaid.Release.seed()", staging.MIGRATE)

    def test_missing_local_image_is_not_replaced_with_a_mutable_pull(self):
        smoke = self.smoke()
        with patch.object(smoke, "docker", return_value=result(code=1)) as docker:
            with self.assertRaisesRegex(staging.SmokeError, "Local immutable"):
                smoke.resolve_images()
        self.assertEqual(len(docker.call_args_list), 1)
        self.assertEqual(docker.call_args.args[:2], ("image", "inspect"))

    def test_remote_docker_daemons_rejected_before_pulls(self):
        smoke = self.smoke()
        for endpoint in ("ssh://production", "tcp://127.0.0.1:2375", "https://docker.example"):
            smoke.env = {"DOCKER_HOST": endpoint}
            with patch.object(smoke, "docker") as docker, self.assertRaises(staging.SmokeError):
                smoke.validate_daemon()
            docker.assert_not_called()
        smoke.env = {"DOCKER_HOST": "unix:///var/run/docker.sock"}
        smoke.validate_daemon()
        smoke.env = {"DOCKER_CONTEXT": "remote", "DOCKER_HOST": "unix:///var/run/docker.sock"}
        with patch.object(smoke, "docker", return_value=result(json.dumps([{"Endpoints": {"docker": {"Host": "ssh://remote"}}}]))):
            with self.assertRaises(staging.SmokeError):
                smoke.validate_daemon()

    def test_failed_real_migration_never_starts_api(self):
        smoke = self.smoke()
        roles = []
        def create(role, **kwargs):
            roles.append(role)
            return role
        def wait(predicate, label):
            if label == "release migrations":
                raise staging.SmokeError("Real release migration failed")
        with patch.object(smoke, "validate_daemon"), patch.object(smoke, "resolve_images"), patch.object(smoke, "create_network"), patch.object(smoke, "command"), patch.object(smoke, "docker"), patch.object(staging.os, "chmod"), patch.object(smoke, "create", side_effect=create), patch.object(smoke, "wait_for", side_effect=wait):
            with self.assertRaises(staging.SmokeError):
                smoke.execute()
        self.assertEqual(roles, ["postgres", "migration"])
        self.assertEqual(smoke.checks, [])


if __name__ == "__main__":
    unittest.main()
