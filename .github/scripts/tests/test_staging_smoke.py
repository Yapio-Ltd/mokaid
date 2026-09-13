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
