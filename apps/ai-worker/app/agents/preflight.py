"""Readiness checks. Default mode makes no network requests or state changes."""

from __future__ import annotations

import argparse
import asyncio
import json
from importlib.metadata import PackageNotFoundError, version
from typing import Any
from urllib.parse import urlsplit

from app.agents.runtime_cost import PRICES, PRICING_VERSION
from app.config import Settings, get_settings

SDK_VERSION = "3.19.2"
_REQUIRED_METHODS = (
    "beta.agents.sessions.create", "beta.agents.sessions.retrieve", "beta.agents.sessions.delete",
    "beta.agents.sessions.list", "beta.agents.sessions.events.create", "beta.agents.sessions.items.list",
    "beta.agents.sessions.turns.list", "beta.agents.sessions.artifacts.list",
    "beta.agents.sessions.artifacts.with_streaming_response.content", "webhooks.unwrap",
)


def _has_method(client: Any, path: str) -> bool:
    for name in path.split("."):
        client = getattr(client, name, None)
        if client is None:
            return False
    return callable(client)


async def check_readiness(*, settings: Settings | None = None, client: Any = None,
                          sdk_version: str | None = None, remote: bool = False) -> dict[str, Any]:
    """Inspect configuration and SDK shape; --remote adds account read requests.

    No branch creates a session, publishes output, changes policy, or starts a
    billable model turn. Remote checks never emit API resource bodies or keys.
    """
    settings = settings or get_settings()
    checks: list[dict[str, str]] = []

    def add(name: str, passed: bool, message: str) -> None:
        checks.append({"name": name, "status": "pass" if passed else "fail", "message": message})

    if sdk_version is None:
        try:
            sdk_version = version("openai")
        except PackageNotFoundError:
            sdk_version = "missing"
    add("sdk_version", sdk_version == SDK_VERSION, f"Installed {sdk_version}; tested pin {SDK_VERSION}.")
    try:
        database = urlsplit(settings.database_url)
        database_valid = database.scheme in {"postgres", "postgresql", "ecto"} and bool(database.hostname and database.path.strip("/"))
    except ValueError:
        database_valid = False
    add("durable_database", database_valid, "A PostgreSQL DSN is required; connectivity is not tested offline.")
    add("provider_key", bool(settings.openai_api_key), "A provider API key must be configured; its value is never printed.")
    add("webhook_secret", bool(settings.openai_agents_webhook_secret), "The signing secret must match the registered Agents webhook.")
    add("worker_auth", bool(settings.worker_auth_token and settings.worker_auth_token != "dev-worker-token"),
        "Use a dedicated worker credential shared with Phoenix before a pilot.")
    models = list(dict.fromkeys([settings.openai_agents_standard_model, settings.openai_agents_complex_model]))
    add("priced_models", all(model in PRICES for model in models),
        f"Both configured models need a supported estimate in {PRICING_VERSION}; this does not prove account access.")
    add("runtime_limits", settings.openai_agents_poll_seconds > 0 and settings.openai_agents_usage_grace_seconds > 0
        and settings.openai_agents_max_artifact_bytes > 0, "Polling, usage grace and artifact limits must be positive.")
    checks.append({"name": "deployment_gate", "status": "info", "message":
        "Deployment flag is enabled; workspace consent and verified models still apply." if settings.openai_agents_enabled
        else "Deployment flag is disabled. Passing preflight will not enable it."})
    checks.append({"name": "sandbox_network", "status": "info", "message":
        f"Sandbox network uses {len(settings.openai_agents_allowed_domains)} explicitly allowed domains."
        if settings.openai_agents_allowed_domains else "Sandbox network is disabled by default."})
    own_client = client is None
    try:
        if client is None:
            from openai import AsyncOpenAI
            client = AsyncOpenAI(api_key=settings.openai_api_key or "offline-preflight", max_retries=0, timeout=15)
        missing = [path for path in _REQUIRED_METHODS if not _has_method(client, path)]
        add("agents_sdk_surface", not missing, "Required SDK methods are present." if not missing else "Missing SDK methods: " + ", ".join(missing))
        if remote:
            if not settings.openai_api_key or missing:
                add("remote_access", False, "Remote checks require the provider key and complete SDK surface.")
            else:
                async def read_account() -> None:
                    await client.beta.agents.sessions.list(limit=1)
                    for model in models:
                        await client.models.retrieve(model)
                try:
                    await asyncio.wait_for(read_account(), timeout=45)
                    add("remote_access", True, "Account permitted session listing and model retrieval; no turn was executed.")
                except Exception as exc:
                    add("remote_access", False, f"Read-only account check failed ({type(exc).__name__}); no response body is emitted.")
        else:
            checks.append({"name": "remote_access", "status": "not_checked", "message":
                "No network requests made. Use --remote for read-only account checks."})
    except Exception as exc:
        add("agents_sdk_surface", False, f"SDK initialization failed ({type(exc).__name__}).")
    finally:
        if own_client and client is not None:
            await client.close()
    return {"ready": all(check["status"] != "fail" for check in checks),
            "mode": "remote_read_only" if remote else "offline", "deployment_enabled": settings.openai_agents_enabled,
            "activation_changed": False, "model_execution_verified": False, "checks": checks}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--remote", action="store_true", help="Read-only session list/model access checks; never starts a model turn.")
    parser.add_argument("--json", action="store_true", help="Emit a machine-readable report without credentials or provider resources.")
    args = parser.parse_args()
    report = asyncio.run(check_readiness(remote=args.remote))
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"Managed runtime preflight: {'ready for pilot review' if report['ready'] else 'configuration incomplete'} ({report['mode']})")
        for check in report["checks"]:
            print(f"[{check['status']}] {check['name']}: {check['message']}")
        print("No policy was changed. Passing checks does not verify model execution or activate a workspace.")
    return 0 if report["ready"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
