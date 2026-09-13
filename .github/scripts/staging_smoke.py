#!/usr/bin/env python3
"""Run exact release images against disposable, outbound-isolated fixture storage.

No production environment is copied into containers. See staging-smoke.md for
the deliberately narrower claim this makes than a production-equivalent stage.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import secrets
import signal
import subprocess
import sys
import tempfile
import time
import uuid

PG_IMAGE = "pgvector/pgvector@sha256:ccc6e83d6e35e931dc7c5def2022729d5a6c370318d099181995567ff1fb4d6b"
PROBE_IMAGE = "node@sha256:83f487e0a63425e5b4d146fb5e5be574bcbe1b7b843d3ebafdd95eaf7767a7e5"
IMAGE_PATTERN = re.compile(r"(?:[a-zA-Z0-9][a-zA-Z0-9._:/-]*@)?sha256:[0-9a-f]{64}\Z")
ID_PATTERN = re.compile(r"[0-9a-f]{64}\Z")
LABEL = "com.mokaid.staging.run"
DB_NAME = "mokaid_staging_test"
DB_USER = "mokaid_staging"

# Fixed code, not a user-supplied eval hook. Runtime production configuration is
# loaded by the real release before this prelude; Repo TLS remains unchanged.
PRELUDE = r'''
Application.load(:mokaid)
database = URI.parse(System.fetch_env!("DATABASE_URL"))
unless database.host == "postgres" and database.path == "/mokaid_staging_test" and
       database.port == 5432 and is_nil(database.query), do: raise "Unsafe staging database"
defmodule Mokaid.Staging.DisabledHTTP do
  @behaviour ExAws.Request.HttpClient
  def request(_, _, _, _, _), do: {:error, %{reason: :staging_outbound_disabled}}
  def req(request), do: {request, RuntimeError.exception("Staging outbound HTTP disabled")}
end
Application.put_env(:mokaid, Oban,
  Keyword.merge(Application.fetch_env!(:mokaid, Oban), testing: :manual, queues: false, plugins: false))
Application.put_env(:mokaid, :ai_worker, dispatch: :none, url: nil, token: nil)
Application.put_env(:mokaid, :imap_probe_enabled, false)
Application.put_env(:mokaid, :auto_seed_mcp_catalog, false)
Application.put_env(:mokaid, :auto_seed_assets_3d, false)
Application.put_env(:mokaid, Mokaid.Repo,
  Keyword.merge(Application.fetch_env!(:mokaid, Mokaid.Repo),
    log: false, show_sensitive_data_on_connection_error: false))
for key <- [:figma_oauth, :google_oauth, :google_auth, :github_oauth, :linear_oauth,
            :slack_oauth, :microsoft_oauth, :notion_oauth, :gmail_pubsub, :provider_costs,
            :resend, :stripe], do: Application.put_env(:mokaid, key, [])
Application.put_env(:ex_aws, :access_key_id, "staging-disabled")
Application.put_env(:ex_aws, :secret_access_key, "staging-disabled")
Application.put_env(:ex_aws, :http_client, Mokaid.Staging.DisabledHTTP)
Application.put_env(:ex_aws, :retries, max_attempts: 0)
for service <- [:s3, :sqs, :sts, :cost_explorer, :cloudwatch_logs] do
  Application.put_env(:ex_aws, service, host: "127.0.0.1", port: 9, scheme: "http://")
end
Req.default_options(adapter: &Mokaid.Staging.DisabledHTTP.req/1, retry: false)
Application.put_env(:opentelemetry, :traces_exporter, :none)
Application.put_env(:opentelemetry, :processors, [])
Logger.configure(level: :warning)
'''
MIGRATE = PRELUDE + '\nMokaid.Release.migrate()\nIO.puts("STAGING_MIGRATIONS_OK")\n'
START = PRELUDE + r'''
{:ok, _} = Application.ensure_all_started(:mokaid)
%{rows: [[database, count]]} = Ecto.Adapters.SQL.query!(Mokaid.Repo,
  "SELECT current_database(), count(*) FROM schema_migrations", [])
unless database == "mokaid_staging_test" and count > 0, do: raise "Missing staging migrations"
%{rows: [[true]]} = Ecto.Adapters.SQL.query!(Mokaid.Repo,
  "SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()", [])
IO.puts("STAGING_API_READY database=mokaid_staging_test tls=true")
Process.sleep(:infinity)
'''
PG_START = (
    "chown postgres:postgres /tmp/staging.key /tmp/staging.crt && "
    "chmod 600 /tmp/staging.key && "
    "exec /usr/local/bin/docker-entrypoint.sh postgres "
    "-c ssl=on -c ssl_cert_file=/tmp/staging.crt -c ssl_key_file=/tmp/staging.key"
)


class SmokeError(RuntimeError):
    """Safe, fixed diagnostics only; never include external command output."""


def image_ref(value: str, name: str) -> str:
    if not IMAGE_PATTERN.fullmatch(value):
        raise SmokeError(f"{name} must be repository@sha256:digest or an immutable local sha256 ID")
    return value


def host_environment() -> dict[str, str]:
    # Docker credential helpers may need HOME/config, but application credentials
    # and cloud/provider/proxy variables are never inherited into subprocesses.
    allowed = ("PATH", "HOME", "DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_CONFIG",
               "DOCKER_TLS_VERIFY", "DOCKER_CERT_PATH", "XDG_RUNTIME_DIR")
    return {key: os.environ[key] for key in allowed if key in os.environ}


def fixture_environment(desktop_only: str) -> dict[str, str]:
    if desktop_only not in ("true", "false"):
        raise SmokeError("MOKAID_DESKTOP_ONLY_BUSINESS must be true or false")
    password = secrets.token_hex(24)
    return {
        "DATABASE_URL": f"ecto://{DB_USER}:{password}@postgres:5432/{DB_NAME}",
        "POSTGRES_USER": DB_USER, "POSTGRES_DB": DB_NAME, "POSTGRES_PASSWORD": password,
        "SECRET_KEY_BASE": secrets.token_hex(64), "AI_WORKER_TOKEN": secrets.token_hex(32),
        "PHX_SERVER": "true", "PHX_HOST": "127.0.0.1", "PORT": "4000", "POOL_SIZE": "4",
        "AUTH_MODE": "cognito", "COGNITO_USER_POOL_ID": "us-east-1_STAGINGFIXTURE",
        "COGNITO_CLIENT_ID": "staging-fixture-not-a-real-client", "COGNITO_REGION": "us-east-1",
        "S3_BUCKET_UPLOADS": "staging-disabled-uploads", "S3_BUCKET_PRIVATE": "staging-disabled-private",
        "S3_BUCKET_OUTPUTS": "staging-disabled-outputs", "S3_BUCKET_EXPORTS": "staging-disabled-exports",
        "AWS_EC2_METADATA_DISABLED": "true", "MOKAID_DESKTOP_ONLY_BUSINESS": desktop_only,
        "DESKTOP_AUTH_WEB_BASE_URL": "https://mokaid.com", "ERL_FLAGS": "+S 2:2",
        "RELEASE_DISTRIBUTION": "none", "RELEASE_TMP": "/tmp",
    }


class Smoke:
    def __init__(self, images: dict[str, str], timeout: int = 420) -> None:
        self.images = {key: image_ref(value, key) for key, value in images.items()}
        if set(self.images) not in ({"api", "web"}, {"api", "web", "crm"}):
            raise SmokeError("Both API_IMAGE and WEB_IMAGE are required")
        if not 60 <= timeout <= 900:
            raise SmokeError("STAGING_TIMEOUT_SECONDS must be between 60 and 900")
        self.timeout = timeout
        self.run_id = uuid.uuid4().hex
        self.prefix = "mokaid-staging-" + self.run_id
        self.network: str | None = None
        self.containers: list[str] = []
        self.resolved: dict[str, str] = {}
        self.fixture = fixture_environment(os.environ.get("MOKAID_DESKTOP_ONLY_BUSINESS", "false"))
        self.env = host_environment()
        self.checks: list[str] = []

    def command(self, args: list[str], *, fixture: bool = False, timeout: int = 45,
                check: bool = True) -> subprocess.CompletedProcess[str]:
        env = dict(self.env)
        if fixture:
            env.update(self.fixture)
        try:
            result = subprocess.run(args, env=env, text=True, capture_output=True, timeout=timeout, check=False)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise SmokeError(f"{args[0]} unavailable or command timeout") from error
        if check and result.returncode:
            raise SmokeError(f"{args[0]} command failed (exit {result.returncode})")
        return result

    def docker(self, *args: str, **kwargs: object) -> subprocess.CompletedProcess[str]:
        return self.command(["docker", *args], **kwargs)

    def inspect(self, kind: str, target: str) -> dict:
        try:
            data = json.loads(self.docker(kind, "inspect", target).stdout)
            if len(data) != 1 or not isinstance(data[0], dict):
                raise ValueError()
            return data[0]
        except (ValueError, TypeError) as error:
            raise SmokeError(f"Invalid Docker {kind} inspection") from error

    def resolve_images(self) -> None:
        for key, ref in {**self.images, "postgres": PG_IMAGE, "probe": PROBE_IMAGE}.items():
            if self.docker("image", "inspect", ref, check=False).returncode:
                if ref.startswith("sha256:"):
                    raise SmokeError(f"Local immutable {key} image is missing")
                self.docker("pull", ref, timeout=240)
            image = self.inspect("image", ref)
            image_id = image.get("Id", "")
            if not re.fullmatch(r"sha256:[0-9a-f]{64}", image_id):
                raise SmokeError("Docker returned an invalid image ID")
            if ref.startswith("sha256:") and image_id != ref:
                raise SmokeError("Local image ID mismatch")
            self.resolved[key] = image_id

    def validate_daemon(self) -> None:
        # A remote Docker context could otherwise turn a "local" smoke into
        # container mutations on a shared/production host. Fail before pulling.
        endpoint = self.env.get("DOCKER_HOST") if not self.env.get("DOCKER_CONTEXT") else None
        if not endpoint:
            try:
                contexts = json.loads(self.docker("context", "inspect").stdout)
                if len(contexts) != 1:
                    raise ValueError()
                endpoint = contexts[0]["Endpoints"]["docker"]["Host"]
            except (ValueError, KeyError, TypeError) as error:
                raise SmokeError("Cannot verify a local Docker daemon") from error
        if not isinstance(endpoint, str) or not endpoint.startswith("unix:///"):
            raise SmokeError("Only a local Unix-socket Docker daemon is allowed")

    def create_network(self) -> None:
        # Record the unique planned name BEFORE creation, covering an uncertain CLI
        # outcome. Cleanup always checks ownership and never trusts that name alone.
        self.network = self.prefix
        self.docker("network", "create", "--internal", "--driver", "bridge", "--label",
                    f"{LABEL}={self.run_id}", self.network)
        network = self.inspect("network", self.network)
        if not network.get("Internal") or network.get("Labels", {}).get(LABEL) != self.run_id:
            raise SmokeError("Staging network is not internally isolated and owned")

    def create(self, role: str, *, command: tuple[str, ...] = ()) -> str:
        name = f"{self.prefix}-{role}"
        key = "api" if role == "migration" else role
        args = ["create", "--name", name, "--label", f"{LABEL}={self.run_id}",
                "--network", self.network or "none", "--pids-limit", "512",
                "--memory", "1536m" if key == "api" else "512m", "--cpus", "2",
                "--security-opt", "no-new-privileges:true", "--log-opt", "max-size=4m",
                "--log-opt", "max-file=1"]
        if key == "postgres":
            args.extend(["--network-alias", "postgres", "--entrypoint", "/bin/sh"])
            names = ("POSTGRES_USER", "POSTGRES_PASSWORD", "POSTGRES_DB")
        elif key == "api":
            args.extend(["--cap-drop", "ALL"])
            names = tuple(name for name in self.fixture if not name.startswith("POSTGRES_"))
        else:
            names = ()
        for env_name in names:
            args.extend(["--env", env_name])
        args.extend([self.resolved[key], *command])
        self.containers.append(name)
        self.docker(*args, fixture=True)
        data = self.inspect("container", name)
        if data.get("Image") != self.resolved[key] or data.get("Config", {}).get("Labels", {}).get(LABEL) != self.run_id:
            raise SmokeError("Container image or ownership mismatch")
        networks = data.get("NetworkSettings", {}).get("Networks", {})
        if set(networks) != {self.network}:
            raise SmokeError("Container has an unexpected network")
        return name

    def wait_for(self, predicate, label: str) -> None:
        deadline = time.monotonic() + self.timeout
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(1)
        raise SmokeError(f"Timeout waiting for {label}")

    def alive(self, name: str) -> dict:
        state = self.inspect("container", name).get("State", {})
        if not state.get("Running"):
            raise SmokeError("Staging container exited before readiness")
        return state

    def migration_done(self, name: str) -> bool:
        state = self.inspect("container", name).get("State", {})
        if state.get("Running"):
            return False
        if state.get("Status") != "exited" or state.get("ExitCode") != 0 or state.get("OOMKilled"):
            raise SmokeError("Real release migration failed")
        if "STAGING_MIGRATIONS_OK" not in self.docker("logs", name).stdout:
            raise SmokeError("Release migration did not reach its completion marker")
        return True

    def probe(self, role: str, target: str) -> None:
        """Loopback checks in the target namespace, never a second egress network.

        Docker 29 does not publish ports on internal-only networks. A verifier
        sharing the target namespace keeps both the production image unchanged
        and its network isolated. The verifier receives no fixture environment.
        """
        port, path = {"api": (4000, "/api/health"), "web": (80, "/"), "crm": (3001, "/login")}[role]
        data = self.inspect("container", target)
        identity = data.get("Id", "")
        if (not ID_PATTERN.fullmatch(identity) or
                data.get("Config", {}).get("Labels", {}).get(LABEL) != self.run_id or
                set(data.get("NetworkSettings", {}).get("Networks", {})) != {self.network}):
            raise SmokeError("Probe target is not owned and isolated")
        # Only fixed role/port/path and a validated integer enter this source.
        origin = "http://127.0.0.1" + (f":{port}" if port != 80 else "")
        code = f'''
const smokeOrigin = {json.dumps(origin)};
const deadline = Date.now() + {self.timeout * 1000};
let available = false;
while (Date.now() < deadline) {{
  try {{
    const response = await fetch(smokeOrigin + {json.dumps(path)}, {{ redirect: "manual", signal: AbortSignal.timeout(3000) }});
    if (response.status === 200) {{ available = true; break; }}
  }} catch {{}}
  await new Promise(resolve => setTimeout(resolve, 500));
}}
if (!available) throw new Error("Staging loopback HTTP readiness timeout");
'''
        if role == "web":
            # Execute the exact existing production verifier, not an approximate
            # duplicate; only its documented local-origin environment is set.
            code += 'process.env.MOKAID_SMOKE_ORIGIN = smokeOrigin;\n'
            code += Path(__file__).with_name("verify-production.mjs").read_text()
        elif role == "api":
            code += '''
const health = await (await fetch(smokeOrigin + "/api/health", {redirect: "manual", signal: AbortSignal.timeout(5000)})).json();
if (health.status !== "ok" || health.service !== "mokaid-api") throw new Error("Invalid API health payload");
for (const path of ["/api/me", "/api/desktop/auth/requests/00000000-0000-4000-8000-000000000000"]) {
  const response = await fetch(smokeOrigin + path, {redirect: "manual", signal: AbortSignal.timeout(5000)});
  if (response.status !== 401) throw new Error("Anonymous authorization guard failed at " + path);
}
'''
        else:
            code += '''
const html = await (await fetch(smokeOrigin + "/login", {redirect: "manual", signal: AbortSignal.timeout(5000)})).text();
if (!/<html/i.test(html)) throw new Error("Missing CRM login HTML");
'''
        code += '\nconsole.log("STAGING_PROBE_OK");\n'
        name = f"{self.prefix}-probe-{role}"
        self.containers.append(name)
        self.docker("create", "--name", name, "--label", f"{LABEL}={self.run_id}",
                    "--network", "container:" + identity, "--memory", "256m", "--cpus", "1",
                    "--pids-limit", "128", "--cap-drop", "ALL", "--user", "node", "--read-only",
                    "--security-opt", "no-new-privileges:true", "--log-opt", "max-size=1m",
                    "--log-opt", "max-file=1", "--entrypoint", "node", self.resolved["probe"],
                    "--input-type=module", "--eval", code)
        probe = self.inspect("container", name)
        if (probe.get("Image") != self.resolved["probe"] or
                probe.get("Config", {}).get("Labels", {}).get(LABEL) != self.run_id or
                probe.get("HostConfig", {}).get("NetworkMode") != "container:" + identity):
            raise SmokeError("Verifier image, network or ownership mismatch")
        self.docker("start", name)
        def completed():
            self.alive(target)
            state = self.inspect("container", name).get("State", {})
            if state.get("Running"):
                return False
            if state.get("Status") != "exited" or state.get("ExitCode") != 0 or state.get("OOMKilled"):
                raise SmokeError(f"Actual {role} loopback verification failed")
            if "STAGING_PROBE_OK" not in self.docker("logs", name).stdout:
                raise SmokeError("Missing verifier completion marker")
            return True
        self.wait_for(completed, f"{role} loopback verification")

    def execute(self) -> None:
        self.validate_daemon()
        self.resolve_images()
        self.create_network()
        with tempfile.TemporaryDirectory(prefix="mokaid-staging-tls-") as directory:
            cert, key = Path(directory) / "server.crt", Path(directory) / "server.key"
            self.command(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                          "-subj", "/CN=postgres", "-keyout", str(key), "-out", str(cert)])
            os.chmod(key, 0o600)
            pg = self.create("postgres", command=("-c", PG_START))
            self.docker("cp", str(cert), pg + ":/tmp/staging.crt")
            self.docker("cp", str(key), pg + ":/tmp/staging.key")
            self.docker("start", pg)
        def pg_ready():
            self.alive(pg)
            return self.docker("exec", pg, "pg_isready", "-U", DB_USER, "-d", DB_NAME, check=False).returncode == 0
        self.wait_for(pg_ready, "PostgreSQL")
        migration = self.create("migration", command=("bin/mokaid", "eval", MIGRATE))
        self.docker("start", migration)
        self.wait_for(lambda: self.migration_done(migration), "release migrations")
        self.checks.append("release-migrations")
        print("Staging: actual release migrations passed.", flush=True)
        api = self.create("api", command=("bin/mokaid", "eval", START))
        self.docker("start", api)
        self.probe("api", api)
        self.wait_for(lambda: "STAGING_API_READY" in self.docker("logs", api).stdout, "API database/TLS check")
        self.checks.extend(["api-schema-tls", "api-health", "api-unauthenticated-401", "desktop-consent-401"])
        print("Staging: API startup, database TLS and anonymous authorization guards passed.", flush=True)
        web = self.create("web")
        self.docker("start", web)
        self.probe("web", web)
        self.checks.append("production-web-verifier")
        print("Staging: actual production web verifier passed.", flush=True)
        if "crm" in self.images:
            crm = self.create("crm")
            self.docker("start", crm)
            self.probe("crm", crm)
            self.checks.append("crm-login-html")

    def redact(self, value: str) -> str:
        for key in ("DATABASE_URL", "POSTGRES_PASSWORD", "SECRET_KEY_BASE", "AI_WORKER_TOKEN"):
            value = value.replace(self.fixture[key], "[REDACTED]")
        value = re.sub(r"(?i)(?:ecto|postgres(?:ql)?)://[^\s\"']+", "[REDACTED_DATABASE_URL]", value)
        value = re.sub(r"(?i)(bearer\s+|(?:access_token|refresh_token)[\s\"':=]+)[^\s\"',}]+", r"\1[REDACTED]", value)
        return value

    def diagnostics(self, error: str) -> str:
        report = {"run": self.run_id, "error": error, "images": self.images,
                  "resolved_images": self.resolved, "checks": self.checks, "containers": []}
        for name in self.containers:
            try:
                data = self.inspect("container", name)
                if data.get("Config", {}).get("Labels", {}).get(LABEL) != self.run_id:
                    continue
                state = data.get("State", {})
                logs = self.docker("logs", "--tail", "100", name, check=False)
                report["containers"].append({"name": name, "status": state.get("Status"),
                    "exit_code": state.get("ExitCode"), "oom": state.get("OOMKilled"),
                    "logs": self.redact((logs.stdout + logs.stderr)[-32000:])})
            except SmokeError:
                report["containers"].append({"name": name, "inspection": "unavailable"})
        return json.dumps(report, indent=2)

    def cleanup(self) -> list[str]:
        failures = []
        for name in reversed(self.containers):
            try:
                found = self.docker("container", "inspect", name, check=False)
                if found.returncode:
                    # Distinguish absence from a Docker connection/permission error.
                    if "No such" in found.stderr:
                        continue
                    raise SmokeError("Cannot verify cleanup ownership")
                data = json.loads(found.stdout)[0]
                identity = data.get("Id", "")
                if data.get("Config", {}).get("Labels", {}).get(LABEL) != self.run_id or not ID_PATTERN.fullmatch(identity):
                    raise SmokeError("Cleanup ownership changed")
                self.docker("rm", "--force", "--volumes", identity)
            except (SmokeError, ValueError, KeyError, IndexError, TypeError):
                failures.append(name)
        if self.network:
            try:
                found = self.docker("network", "inspect", self.network, check=False)
                if found.returncode and "No such" in found.stderr:
                    return failures
                if found.returncode:
                    raise SmokeError("Cannot verify network ownership")
                data = json.loads(found.stdout)[0]
                identity = data.get("Id", "")
                if data.get("Labels", {}).get(LABEL) != self.run_id or not ID_PATTERN.fullmatch(identity):
                    raise SmokeError("Network cleanup ownership changed")
                self.docker("network", "rm", identity)
            except (SmokeError, ValueError, KeyError, IndexError, TypeError):
                failures.append(self.network)
        return failures


def main() -> int:
    smoke = None
    error = None
    diagnostics = None
    try:
        if len(sys.argv) != 1:
            raise SmokeError("No command-line arguments supported; use immutable IMAGE environment inputs")
        images = {key: os.environ.get(key.upper() + "_IMAGE", "") for key in ("api", "web")}
        if os.environ.get("CRM_IMAGE"):
            images["crm"] = os.environ["CRM_IMAGE"]
        smoke = Smoke(images, int(os.environ.get("STAGING_TIMEOUT_SECONDS", "420")))
        def interrupted(_signum, _frame):
            raise SmokeError("Staging interrupted")
        signal.signal(signal.SIGTERM, interrupted)
        smoke.execute()
    except (SmokeError, ValueError, OSError, TimeoutError, ConnectionError, KeyboardInterrupt) as failure:
        error = str(failure) if isinstance(failure, SmokeError) else "Staging interrupted or invalid runtime response"
        if smoke:
            diagnostics = smoke.diagnostics(error)
    finally:
        if smoke:
            failed_cleanup = smoke.cleanup()
            if failed_cleanup:
                error = (error or "Staging checks passed") + "; cleanup incomplete for owned resources: " + ", ".join(failed_cleanup)
                diagnostics = diagnostics or smoke.diagnostics(error)
    if error:
        print("Staging FAILED: " + error, file=sys.stderr)
        if diagnostics:
            # Diagnostics contain only fixture-redacted logs, never Docker Env or
            # full inspect responses. A new private file is used even in CI.
            directory = os.environ.get("STAGING_DIAGNOSTICS_DIR")
            if directory:
                Path(directory).mkdir(parents=True, exist_ok=True)
            with tempfile.NamedTemporaryFile(mode="w", prefix="mokaid-staging-failure-", suffix=".json",
                                             dir=directory, delete=False) as output:
                output.write(diagnostics)
                print("Redacted staging diagnostics: " + output.name, file=sys.stderr)
        return 1
    print("Staging PASSED; all owned containers, volumes and network removed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
