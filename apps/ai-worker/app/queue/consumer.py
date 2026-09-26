"""SQS consumer for production dispatch.

Phoenix publishes JSON messages with a `type` discriminator:
- "run": start an agent run (RunRequest payload)
- "resume": deliver a human approval decision to a paused run
- "cancel": abort an in-flight run
- "ingest": chunk + embed a knowledge document

In dev the queue URL is empty and Phoenix calls the HTTP endpoints directly.
"""

import asyncio
import json
from typing import Any

import boto3
import structlog

from app import runtime_dispatch
from app.config import get_settings
from app.memory.ingestion import ingest_document
from app.schemas import ResumeRequest, RunRequest

log = structlog.get_logger()

async def _handle_message(body: dict[str, Any]) -> None:
    kind = body.get("type", "run")

    if kind == "run":
        request = RunRequest.model_validate(body)
        await runtime_dispatch.accept_run(request)

    elif kind == "resume":
        request = ResumeRequest.model_validate(body)
        await runtime_dispatch.submit_command(request.run_id, "resume", request.model_dump(mode="json"),
                                               command_id=body.get("command_id") or body.get("approval_request_id"))

    elif kind == "cancel":
        run_id = str(body.get("run_id") or "")
        await runtime_dispatch.submit_command(run_id, "cancel", command_id=f"cancel:{run_id}")

    elif kind == "converse":
        from app.agents import converse as converse_agent

        if not await converse_agent.converse(body):
            raise RuntimeError("task follow-up was not applied")

    elif kind == "agent_chat":
        from app.agents import direct_chat

        await direct_chat.reply(body)

    elif kind == "ingest":
        await ingest_document(body)

    elif kind == "mail_sync":
        from app.mail import sync as mail_sync

        await mail_sync.sync_account(body)

    elif kind == "mail_watch":
        from app.mail import sync as mail_sync

        await mail_sync.renew_watch(body)

    else:
        raise ValueError("Unknown worker message type")


async def consume_forever() -> None:
    settings = get_settings()
    queue_url = settings.ai_runs_queue_url
    if not queue_url:
        return

    sqs = boto3.client("sqs", region_name=settings.aws_region or None)
    log.info("sqs_consumer_started", queue=queue_url)

    while True:
        try:
            response = await asyncio.to_thread(
                sqs.receive_message,
                QueueUrl=queue_url,
                MaxNumberOfMessages=5,
                WaitTimeSeconds=20,
            )
            for message in response.get("Messages", []):
                try:
                    await _handle_message(json.loads(message["Body"]))
                except Exception as exc:  # noqa: BLE001 — one bad message must not kill the loop
                    log.error("sqs_message_failed", error=type(exc).__name__)
                    # Leave the message visible for retry / the configured DLQ.
                    continue
                else:
                    await asyncio.to_thread(
                        sqs.delete_message,
                        QueueUrl=queue_url,
                        ReceiptHandle=message["ReceiptHandle"],
                    )
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001 — transient AWS errors: back off and retry
            log.error("sqs_poll_failed", error=str(exc))
            await asyncio.sleep(5)
