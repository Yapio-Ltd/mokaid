"""Targeted, read-only model regression; creates no tasks or employees."""

import argparse
import asyncio
import hashlib
import json
import logging
import os
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
WORKER = ROOT / "apps/ai-worker"
sys.path[:0] = [str(WORKER), str(WORKER / "evals/jev_routing")]
os.chdir(WORKER)

import structlog  # noqa: E402
from run_eval import CapturedTracker, captured_baseline  # noqa: E402

from app import llm  # noqa: E402
from app.agents import orchestrator_chat  # noqa: E402
from app.config import get_settings  # noqa: E402


async def main(suffix: str) -> None:
    settings = get_settings()
    if not settings.anthropic_api_key:
        raise SystemExit("Anthropic is required for this regression.")
    logging.disable(logging.CRITICAL)
    structlog.configure(logger_factory=structlog.WriteLoggerFactory(file=open(os.devnull, "w")))
    llm.UsageTracker = CapturedTracker
    cases = json.loads((HERE / "cases.json").read_text())["cases"]
    output = HERE / f"{suffix}-results.jsonl"
    if output.exists():
        raise SystemExit("Output already exists; preserve this run.")
    secrets = [settings.anthropic_api_key, settings.openai_api_key, settings.deepseek_api_key]
    source_hashes = {
        "dispatcher_sha256": hashlib.sha256((WORKER / "app/agents/dispatcher.py").read_bytes()).hexdigest(),
        "orchestrator_chat_sha256": hashlib.sha256((WORKER / "app/agents/orchestrator_chat.py").read_bytes()).hexdigest(),
        "runner_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
    }

    def save(row: dict) -> None:
        encoded = json.dumps(row, ensure_ascii=False)
        for secret in secrets:
            if secret:
                encoded = encoded.replace(secret, "[REDACTED]")
        with output.open("a") as stream:
            stream.write(encoded + "\n")
        print(json.dumps({"id": row["id"], "status": row["status"], "correct": row.get("correct")}), flush=True)

    for case in cases:
        result = await captured_baseline(case)
        rec = result.get("result", {}).get("recommendation", {})
        save({"id": case["id"], **result, "correct": result["status"] == "ok" and
              rec.get("mode") == "existing_agent" and rec.get("agent_id") == case["expected_agent_id"]})

    # Exercise the actual two-model path: conversation expands the mission,
    # dispatch then chooses from the same synthetic roster, without confirmation.
    for iteration in range(3):
        case = cases[0]
        started = time.perf_counter()
        conversation = await orchestrator_chat.respond({
            "message": case["payload"]["instruction"], "language": "fr", "conversation": [],
            "agents": case["payload"]["agents"], "missions": [],
        })
        brief = conversation["mission_instruction"]
        result = await captured_baseline({"payload": {**case["payload"], "instruction": brief}})
        rec = result.get("result", {}).get("recommendation", {})
        save({"id": f"chat_then_dispatch_{iteration + 1}", **result, "conversation": conversation,
              "full_path_seconds": round(time.perf_counter() - started, 3),
              "correct": bool(brief) and result["status"] == "ok" and
              rec.get("mode") == "existing_agent" and rec.get("agent_id") == "taya"})

    (HERE / f"{suffix}-manifest.json").write_text(json.dumps({
        "model": settings.anthropic_fast_model,
        "cases_sha256": hashlib.sha256((HERE / "cases.json").read_bytes()).hexdigest(),
        **source_hashes,
        "scope": "8 direct routing cases + 3 full chat-to-dispatch repetitions; no task confirmation or execution.",
    }, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--suffix", default="live")
    args = parser.parse_args()
    asyncio.run(main(args.suffix))
