"""Mail sync orchestrator: fetch → analyze → report to Phoenix.

Also manages provider push channels (Gmail watch / Graph subscriptions)
on behalf of the Phoenix renewal cron.
"""

from datetime import UTC, datetime, timedelta
from typing import Any

import httpx
import structlog

from app.clients.phoenix import PhoenixClient
from app.llm import UsageTracker
from app.mail import analyze, fetchers

log = structlog.get_logger()

GRAPH_BASE = "https://graph.microsoft.com/v1.0"
GMAIL_BASE = "https://gmail.googleapis.com/gmail/v1/users/me"

# Graph subscriptions max out around 3 days for messages.
GRAPH_SUBSCRIPTION_MINUTES = 4200


async def sync_account(payload: dict[str, Any]) -> dict[str, Any]:
    """Full sync cycle for one account. `payload` is the Phoenix job body:
    {"account": {...}, "rules": [...]}."""
    account = payload.get("account") or {}
    rules = payload.get("rules") or []
    account_id = account.get("id", "")
    phoenix = PhoenixClient()

    if not account_id:
        return {"error": "missing account"}

    try:
        messages, new_state = await _fetch(account)
    except fetchers.AuthError as exc:
        log.warning("mail_sync_auth_failed", account_id=account_id, error=str(exc))
        await phoenix.update_mail_sync_state(
            account_id, {"status": "error", "error_message": f"authentication failed: {exc}"}
        )
        return {"error": "auth_failed"}
    except Exception as exc:
        log.warning("mail_sync_fetch_failed", account_id=account_id, error=str(exc))
        await phoenix.update_mail_sync_state(
            account_id, {"status": "error", "error_message": str(exc)[:500]}
        )
        return {"error": "fetch_failed"}

    usage = UsageTracker()
    if messages:
        await analyze.analyze_messages(messages, rules, usage)
        await phoenix.ingest_mail_messages(account_id, messages)

    await phoenix.update_mail_sync_state(
        account_id,
        {
            "sync_state": new_state,
            "status": "active",
            "error_message": None,
            "last_sync_at": datetime.now(UTC).isoformat(),
        },
    )

    if usage.cost_cents > 0:
        await phoenix.report_usage(
            account.get("workspace_id", ""),
            "mail_analyze",
            usage.cost_cents,
            token_usage=usage.as_dict(),
        )

    log.info("mail_sync_done", account_id=account_id, messages=len(messages))
    return {"synced": len(messages)}


async def _fetch(account: dict[str, Any]) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    provider = account.get("provider")
    credentials = account.get("credentials") or {}
    sync_state = account.get("sync_state") or {}

    if provider == "gmail":
        return await fetchers.fetch_gmail(credentials, sync_state)
    if provider == "microsoft":
        return await fetchers.fetch_graph(credentials, sync_state)
    if provider == "imap":
        return await fetchers.fetch_imap(credentials, account.get("settings") or {}, sync_state)
    raise ValueError(f"unknown provider {provider}")


# ---------- Push channel management ----------


async def renew_watch(payload: dict[str, Any]) -> dict[str, Any]:
    """Creates/renews the provider push channel and reports expiry to Phoenix."""
    account = payload.get("account") or {}
    webhook = payload.get("webhook") or {}
    account_id = account.get("id", "")
    provider = account.get("provider")
    phoenix = PhoenixClient()

    try:
        if provider == "gmail":
            update = await _renew_gmail_watch(account, webhook)
        elif provider == "microsoft":
            update = await _renew_graph_subscription(account, webhook)
        else:
            return {"skipped": provider}
    except Exception as exc:
        log.warning("mail_watch_failed", account_id=account_id, error=str(exc))
        return {"error": str(exc)[:200]}

    if update:
        await phoenix.update_mail_sync_state(account_id, update)
    return {"renewed": True}


async def _renew_gmail_watch(
    account: dict[str, Any], webhook: dict[str, Any]
) -> dict[str, Any] | None:
    topic = webhook.get("pubsub_topic")
    if not topic:
        log.info("gmail_watch_skipped_no_topic", account_id=account.get("id"))
        return None

    headers = {"authorization": f"Bearer {account['credentials'].get('access_token', '')}"}
    async with httpx.AsyncClient(timeout=30) as client:
        response = await client.post(
            f"{GMAIL_BASE}/watch",
            headers=headers,
            json={"topicName": topic, "labelIds": ["INBOX"]},
        )
        response.raise_for_status()
        body = response.json()

    expires_at = None
    if body.get("expiration"):
        expires_at = datetime.fromtimestamp(int(body["expiration"]) / 1000, tz=UTC).isoformat()

    return {"watch_expires_at": expires_at}


async def _renew_graph_subscription(
    account: dict[str, Any], webhook: dict[str, Any]
) -> dict[str, Any] | None:
    notification_url = webhook.get("notification_url")
    client_state = webhook.get("client_state")
    if not notification_url or not client_state:
        return None

    headers = {"authorization": f"Bearer {account['credentials'].get('access_token', '')}"}
    expiration = (
        (datetime.now(UTC) + timedelta(minutes=GRAPH_SUBSCRIPTION_MINUTES))
        .isoformat()
        .replace("+00:00", "Z")
    )
    subscription_id = account.get("subscription_id")

    async with httpx.AsyncClient(timeout=30) as client:
        if subscription_id:
            response = await client.patch(
                f"{GRAPH_BASE}/subscriptions/{subscription_id}",
                headers=headers,
                json={"expirationDateTime": expiration},
            )
            if response.status_code == 200:
                return {"subscription_expires_at": expiration}
            # Fall through and create a fresh one (expired/deleted).

        response = await client.post(
            f"{GRAPH_BASE}/subscriptions",
            headers=headers,
            json={
                "changeType": "created",
                "notificationUrl": notification_url,
                "resource": "/me/messages",
                "expirationDateTime": expiration,
                "clientState": client_state,
            },
        )
        response.raise_for_status()
        body = response.json()

    return {
        "subscription_id": body.get("id"),
        "subscription_expires_at": body.get("expirationDateTime", expiration),
    }
