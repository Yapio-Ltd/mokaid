"""Runtime-neutral requirements and routing, independent of model prompts."""

from __future__ import annotations

import re
import shlex
from dataclasses import asdict, dataclass, field
from typing import Any, Protocol

from app.agents.mission_kind import (
    detect_mission_kind,
    requires_web_research,
    research_report_requested,
)
from app.config import Settings
from app.schemas import RunRequest


@dataclass(frozen=True)
class Requirements:
    """Capabilities that must survive routing and provider failures."""

    research: bool = False
    artifact: bool = False
    code: bool = False
    calculation: bool = False
    sandbox: bool = False
    complex: bool = False
    managed: bool = False


@dataclass
class RuntimeResult:
    """Common delivery envelope: evidence is distinct from a model's claim."""

    summary: str = ""
    artifacts: list[dict[str, Any]] = field(default_factory=list)
    sources: list[str] = field(default_factory=list)
    commands: list[dict[str, Any]] = field(default_factory=list)
    searches: list[dict[str, Any]] = field(default_factory=list)
    checks: list[dict[str, Any]] = field(default_factory=list)
    limitations: list[str] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        """Return a JSON-compatible result for persistence and UI."""
        return asdict(self)


class RuntimeAdapter(Protocol):
    """Contract for a resumable runtime; Phoenix still owns task lifecycle."""

    async def start(self, configuration: dict[str, Any]) -> dict[str, Any]: ...
    async def continue_session(self, session_id: str, text: str) -> None: ...
    async def retrieve(self, session_id: str) -> dict[str, Any]: ...
    async def items(self, session_id: str) -> list[dict[str, Any]]: ...
    async def cancel(self, session_id: str) -> None: ...


def verification_command(command: str) -> bool:
    """Recognize an executed verification program, never words inside echo output.

    This is evidence of a command, not a guarantee of test coverage. Unknown
    scripts must supply a recognizable test/build invocation to close a task.
    """
    try:
        args = shlex.split(command)
    except ValueError:
        return False
    if not args:
        return False
    program = args[0].rsplit("/", 1)[-1]
    if program in {"bash", "sh", "zsh"} and len(args) == 3 and args[1] in {"-c", "-lc"}:
        return verification_command(args[2])
    if any(token in {";", "||", "|", "&"} for token in args):
        return False
    if "&&" in args:
        # Overall exit status is only proof for the last command in an AND chain.
        last_and = len(args) - 1 - args[::-1].index("&&")
        return verification_command(shlex.join(args[last_and + 1 :]))
    if program in {"pytest", "vitest", "jest", "tsc", "ruff", "mypy"}:
        return True
    if re.fullmatch(r"python(?:\d+(?:\.\d+)?)?", program):
        if args[1:3] in (["-m", "pytest"], ["-m", "unittest"], ["-m", "compileall"]):
            return True
        if args[1:2] == ["-c"] and len(args) == 3:
            import ast

            try:
                code = ast.parse(args[2])
                return any(isinstance(node, ast.Assert) for node in code.body)
            except SyntaxError:
                return False
    if program in {"npm", "pnpm", "yarn", "bun"}:
        remaining = args[1:]
        if remaining[:1] == ["run"]:
            remaining = remaining[1:]
        return bool(
            remaining
            and re.fullmatch(r"(?:test|build|check|lint|typecheck)(?::[\w-]+)?", remaining[0])
        )
    return (
        (
            program in {"cargo", "go", "mix", "dotnet"}
            and args[1:2] in (["test"], ["build"], ["compile"])
        )
        or (program == "cmake" and args[1:2] == ["--build"])
        or program == "ctest"
    )


def requirements_for(request: RunRequest) -> Requirements:
    """Use task intent and trusted hints, never attachments as instructions."""
    instruction = request.input.get("instruction")
    instruction = instruction if isinstance(instruction, str) else ""
    intent = request.model_copy(
        update={"task_description": f"{request.task_description or ''}\n{instruction}"}
    )
    text = f"{intent.task_title or ''}\n{intent.task_description}".lower()
    kind = detect_mission_kind(intent)
    hints = request.runtime_policy.get("required_capabilities", [])
    research = requires_web_research(intent) or "web" in hints
    code = (
        kind in {"website", "webapp"}
        or bool(
            re.search(
                r"\b(debug|codebase|implement\w*|implément\w*|compiler|compile|pytest|refactor\w*|unit tests?|bugfix|python|typescript|javascript|script|développe\w*)\b",
                text,
            )
        )
        or "code" in hints
    )
    calculation = (
        bool(
            re.search(
                r"\b(calcul\w*|calculat\w*|csv|xlsx|spreadsheet|tableur|statistiques|dataset)\b",
                text,
            )
        )
        or "calculation" in hints
    )
    artifact = (
        code
        or research_report_requested(intent)
        or kind in {"website", "webapp", "document", "analysis", "image", "mail_export"}
        or "artifact" in hints
    )
    complex_work = (
        code
        or calculation
        or bool(
            re.search(
                r"\b(complex\w*|multi[- ]?[ée]tapes|multi[- ]?step|comparer|compare|audit|[ée]quipe|team)\b",
                text,
            )
        )
        or "complex" in hints
    )
    # Text reports/media use Mokaid's own exporters. Pay for compute only when
    # executing code, checking data or manipulating attached files requires it.
    sandbox = code or calculation or bool(request.attached_files)
    return Requirements(
        research,
        artifact,
        code,
        calculation,
        sandbox,
        complex_work,
        research or artifact or complex_work or bool(request.attached_files),
    )


def select_runtime(request: RunRequest, settings: Settings) -> tuple[str, Requirements]:
    """Gate managed execution by deployment and explicit workspace consent."""
    requirements = requirements_for(request)
    policy = request.runtime_policy
    enabled = settings.openai_agents_enabled and policy.get("enabled") is True
    consent = policy.get("data_policy_accepted") is True
    if enabled and consent and requirements.managed:
        return "openai_agents", requirements
    return "legacy", requirements


def validate_delivery(result: RuntimeResult, requirements: Requirements) -> list[dict[str, Any]]:
    """Require observable evidence, not a particular generator tool name."""
    checks = [
        {
            "name": "response",
            "passed": bool(result.summary.strip()),
            "message": "A substantive final response is required.",
        }
    ]
    if requirements.artifact:
        checks.append(
            {
                "name": "artifacts",
                "passed": bool(result.artifacts),
                "message": "Requested deliverables must be saved in Mokaid.",
            }
        )
    if requirements.research:
        checks.append(
            {
                "name": "research",
                "passed": bool(result.searches),
                "message": "A real permitted web search is required.",
            }
        )
        # Empty searches are observations, not fabricated sources.
        nonempty = any(item.get("has_results", True) for item in result.searches)
        checks.append(
            {
                "name": "sources",
                "passed": bool(result.sources) or not nonempty,
                "message": "Research findings need source URLs.",
            }
        )
    if requirements.code or requirements.calculation:
        executed = [c for c in result.commands if c.get("exit_code") is not None]
        checks.append(
            {
                "name": "execution",
                "passed": bool(executed),
                "message": "Executable work must actually run.",
            }
        )
        checks.append(
            {
                "name": "verification",
                "passed": any(c.get("exit_code") == 0 and c.get("verification") for c in executed),
                "message": "A successful test, build or data verification is required.",
            }
        )
    return checks
