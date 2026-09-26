"""Verify this API-only release with the repository's isolated staging helpers.

No production credentials, database, published ports or external services are used.
The web image slot required by the helper constructor is unused here.
"""
import importlib.util
import json
import os
from pathlib import Path
import tempfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("staging_smoke", ROOT / ".github/scripts/staging_smoke.py")
staging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(staging)
IMAGE = "sha256:0cde1951a2c4cecb1fe533821016303f41da60dd5bb1443880f58359fb67f0fe"
smoke = staging.Smoke({"api": IMAGE, "web": IMAGE}, timeout=180)
receipt = {"api_image": IMAGE, "scope": "isolated API release only", "checks": []}
try:
    smoke.validate_daemon()
    smoke.resolve_images()
    smoke.create_network()
    with tempfile.TemporaryDirectory(prefix="mokaid-session-staging-tls-") as directory:
        cert, key = Path(directory) / "server.crt", Path(directory) / "server.key"
        smoke.command(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                       "-subj", "/CN=postgres", "-keyout", str(key), "-out", str(cert)])
        os.chmod(key, 0o600)
        postgres = smoke.create("postgres", command=("-c", staging.PG_START))
        smoke.docker("cp", str(cert), postgres + ":/tmp/staging.crt")
        smoke.docker("cp", str(key), postgres + ":/tmp/staging.key")
        smoke.docker("start", postgres)

    def postgres_ready():
        smoke.alive(postgres)
        return smoke.docker("exec", postgres, "pg_isready", "-U", staging.DB_USER,
                            "-d", staging.DB_NAME, check=False).returncode == 0

    smoke.wait_for(postgres_ready, "isolated PostgreSQL")
    migration = smoke.create("migration", command=("bin/mokaid", "eval", staging.MIGRATE))
    smoke.docker("start", migration)
    smoke.wait_for(lambda: smoke.migration_done(migration), "real release migrations")
    receipt["checks"].append("release-migrations")
    print("Real release migrations passed", flush=True)
    api = smoke.create("api", command=("bin/mokaid", "eval", staging.START))
    smoke.docker("start", api)
    smoke.probe("api", api)
    smoke.wait_for(lambda: "STAGING_API_READY" in smoke.docker("logs", api).stdout, "database TLS validation")
    receipt["checks"].extend(["api-schema-tls", "api-health", "anonymous-identity-401", "anonymous-consent-401"])
    probe = '''
const response = await fetch("http://127.0.0.1:4000/api/desktop/auth/refresh", {
  method: "POST", headers: {"Content-Type": "application/json"}, body: "{}",
  redirect: "manual", signal: AbortSignal.timeout(5000)
});
const body = await response.json();
if (response.status !== 400 || body.error?.code !== "invalid_grant") throw Error("Missing refresh route");
if (response.headers.get("cache-control") !== "no-store") throw Error("Missing no-store protection");
console.log("RETRYABLE_REFRESH_ROUTE_OK");
'''
    result = smoke.docker("exec", api, "node", "--input-type=module", "--eval", probe)
    if "RETRYABLE_REFRESH_ROUTE_OK" not in result.stdout:
        raise RuntimeError("Missing refresh probe completion marker")
    receipt["checks"].append("retryable-refresh-route-and-no-store")
    receipt["passed"] = True
    print("API startup, TLS, authorization guards and retryable refresh route passed", flush=True)
except Exception as error:
    receipt["passed"] = False
    receipt["diagnostic"] = smoke.diagnostics(type(error).__name__)
    raise
finally:
    cleanup_errors = smoke.cleanup()
    receipt["cleanup_complete"] = not cleanup_errors
    Path(__file__).with_name("release-image-staging.json").write_text(json.dumps(receipt, indent=2) + "\n")
    if cleanup_errors:
        raise RuntimeError("Isolated staging cleanup incomplete")
