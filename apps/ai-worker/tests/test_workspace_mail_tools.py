"""Native Mail access uses only the signed API capability; no real mail providers."""

import json
from types import SimpleNamespace
from unittest.mock import AsyncMock

import httpx
import pytest
import respx

from app import llm
from app.agents import deep_runner, managed_runner
from app.clients.phoenix import PhoenixClient
from app.mcp.client import McpToolbox
from app.policies.approval import ApprovalPolicy
from app.schemas import Colleague, RunRequest, RunState, RunStatus, ToolCall
from app.tools import mail
from app.tools.registry import RunContext, send_email

TOKEN = "private-mail-capability-never-in-a-prompt"
ACCOUNT = {
    "id": "account-a",
    "email_address": "one@example.test",
    "status": "active",
    "provider": "imap",
}


def context(result=None, *, agent="lead"):
    phoenix = SimpleNamespace(mail_tool=AsyncMock(return_value=result or {"accounts": [ACCOUNT]}))
    return RunContext(
        run_id="run",
        workspace_id="workspace",
        task_id="task",
        agent_id=agent,
        phoenix=phoenix,
        workspace_mail={"token": TOKEN, "accounts": [ACCOUNT]},
    )


@respx.mock
async def test_private_callback_binds_real_actor_and_never_returns_provider_secrets():
    client = PhoenixClient()
    route = respx.post(f"{client.base_url}/api/worker/mail/tools").mock(
        return_value=httpx.Response(200, json={"data": {"accounts": [ACCOUNT]}})
    )
    result = await client.mail_tool(TOKEN, "list", {}, acting_agent_id="participant")
    assert result["accounts"] == [ACCOUNT]
    payload = json.loads(route.calls[0].request.content)
    assert payload == {
        "access_token": TOKEN,
        "action": "list",
        "arguments": {},
        "acting_agent_id": "participant",
    }
    assert route.calls[0].request.headers["authorization"] == client.headers["authorization"]
    assert TOKEN not in json.dumps(result)


@pytest.mark.parametrize(
    "status,code",
    [
        (401, "mail_access_denied"),
        (403, "mail_access_denied"),
        (404, "mail_item_unavailable"),
        (422, "invalid_mail_arguments"),
        (429, "mail_rate_limited"),
        (302, "mail_service_unavailable"),
        (500, "mail_service_unavailable"),
    ],
)
@respx.mock
async def test_transport_errors_are_sanitized_and_redirects_are_not_followed(status, code):
    client = PhoenixClient()
    respx.post(f"{client.base_url}/api/worker/mail/tools").mock(
        return_value=httpx.Response(
            status, json={"error": TOKEN}, headers={"location": "https://untrusted.invalid"}
        )
    )
    assert await client.mail_tool(TOKEN, "list", {}) == {"error": code}


@respx.mock
async def test_timeout_and_malformed_response_are_safe_errors():
    client = PhoenixClient()
    route = respx.post(f"{client.base_url}/api/worker/mail/tools").mock(
        side_effect=httpx.ReadTimeout(TOKEN)
    )
    assert await client.mail_tool(TOKEN, "list", {}) == {"error": "mail_service_unavailable"}
    route.mock(return_value=httpx.Response(200, content=b"not-json"))
    assert await client.mail_tool(TOKEN, "list", {}) == {"error": "mail_service_unavailable"}


@respx.mock
async def test_expired_run_token_refreshes_once_and_repeats_only_same_authorized_operation():
    client = PhoenixClient()
    fresh = "refreshed-private-mail-capability"
    tools = respx.post(f"{client.base_url}/api/worker/mail/tools").mock(
        side_effect=[
            httpx.Response(403, json={"error": {"code": "mail_access_denied"}}),
            httpx.Response(
                200, json={"data": {"accounts": [ACCOUNT], "reflected": f"{TOKEN} {fresh}"}}
            ),
        ]
    )
    renewal = respx.post(f"{client.base_url}/api/worker/mail/refresh").mock(
        return_value=httpx.Response(200, json={"data": {"token": fresh}})
    )
    result = await client.mail_tool(TOKEN, "list", {}, acting_agent_id="child", allow_refresh=True)
    assert tools.call_count == 2 and renewal.call_count == 1
    first, repeated = (json.loads(call.request.content) for call in tools.calls)
    assert repeated == {**first, "access_token": fresh}
    assert json.loads(renewal.calls[0].request.content) == {
        "access_token": TOKEN,
        "action": "list",
        "acting_agent_id": "child",
    }
    assert result["accounts"] == [ACCOUNT]
    assert TOKEN not in json.dumps(result) and fresh not in json.dumps(result)


@respx.mock
async def test_revoked_run_cannot_retry_operation_after_failed_refresh():
    client = PhoenixClient()
    operation = respx.post(f"{client.base_url}/api/worker/mail/tools").mock(
        return_value=httpx.Response(403)
    )
    renewal = respx.post(f"{client.base_url}/api/worker/mail/refresh").mock(
        return_value=httpx.Response(403)
    )
    assert await client.mail_tool(
        TOKEN, "search", {"page": 1}, acting_agent_id="lead", allow_refresh=True
    ) == {"error": "mail_access_denied"}
    assert operation.call_count == 1 and renewal.call_count == 1


@respx.mock
async def test_conversation_token_is_never_automatically_refreshed():
    client = PhoenixClient()
    operation = respx.post(f"{client.base_url}/api/worker/mail/tools").mock(
        return_value=httpx.Response(403)
    )
    renewal = respx.post(f"{client.base_url}/api/worker/mail/refresh")
    assert await client.mail_tool(TOKEN, "list", {}) == {"error": "mail_access_denied"}
    assert operation.call_count == 1 and renewal.call_count == 0


@pytest.mark.parametrize("failure", ["timeout", "invalid_token", "second_denial"])
@respx.mock
async def test_refresh_failure_and_second_denial_cannot_start_another_refresh(failure):
    client = PhoenixClient()
    operation = respx.post(f"{client.base_url}/api/worker/mail/tools").mock(
        return_value=httpx.Response(403)
    )
    renewal = respx.post(f"{client.base_url}/api/worker/mail/refresh")
    if failure == "timeout":
        renewal.mock(side_effect=httpx.ReadTimeout(TOKEN))
    else:
        renewal.mock(
            return_value=httpx.Response(
                200, json={"data": {"token": "new-private" if failure == "second_denial" else ""}}
            )
        )
    result = await client.mail_tool(TOKEN, "read", {"message_id": "m"}, allow_refresh=True)
    assert result == {
        "error": "mail_access_denied" if failure == "second_denial" else "mail_service_unavailable"
    }
    assert operation.call_count == (2 if failure == "second_denial" else 1)
    assert renewal.call_count == 1


@respx.mock
async def test_initial_network_failure_does_not_refresh_or_repeat_operation():
    client = PhoenixClient()
    operation = respx.post(f"{client.base_url}/api/worker/mail/tools").mock(
        side_effect=httpx.ReadTimeout(TOKEN)
    )
    renewal = respx.post(f"{client.base_url}/api/worker/mail/refresh")
    assert await client.mail_tool(
        TOKEN, "save_attachment", {"message_id": "m", "attachment_id": "a"}, allow_refresh=True
    ) == {"error": "mail_service_unavailable"}
    assert operation.call_count == 1 and renewal.call_count == 0


async def test_tools_keep_scope_out_of_arguments_and_project_all_results():
    ctx = context(
        {
            "accounts": [{**ACCOUNT, "settings": {"smtp_password": "secret"}, "token": TOKEN}],
            "credentials": {"refresh_token": "secret"},
            "coverage": {"exhaustive": True},
        }
    )
    result = await mail.list_mail_accounts({"_attached_files": []}, ctx)
    assert result["accounts"][0]["id"] == "account-a"
    assert result["coverage"]["exhaustive"] is False
    assert "secret" not in json.dumps(result) and TOKEN not in json.dumps(result)
    ctx.phoenix.mail_tool.assert_awaited_once_with(
        TOKEN, "list", {}, acting_agent_id="lead", allow_refresh=True
    )
    invalid = await mail.list_mail_accounts(
        {"workspace_id": "other", "acting_agent_id": "other"}, ctx
    )
    assert invalid["error"] == "invalid_mail_arguments"
    assert ctx.phoenix.mail_tool.await_count == 1
    assert TOKEN not in repr(ctx)


@pytest.mark.parametrize(
    "args",
    [
        {"workspace_id": "foreign"},
        {"access_token": "forged"},
        {"acting_agent_id": "owner"},
        {"date_from": "2026-02-30"},
        {"date_from": "2026-10-01", "date_to": "2026-09-01"},
        {"date_from": "20260101"},
        {"per_page": 51},
        {"page": 0},
        {"per_page": True},
        {"query": "x" * 501},
        {"account": "a@example.test", "account_id": "account-a"},
    ],
)
async def test_search_rejects_invalid_and_model_supplied_authority(args):
    ctx = context()
    assert (await mail.search_mail(args, ctx))["error"] == "invalid_mail_arguments"
    ctx.phoenix.mail_tool.assert_not_awaited()


async def test_search_supports_multi_account_pagination_dates_and_attachments():
    ctx = context(
        {
            "messages": [
                {
                    "message_id": "m",
                    "account": "two@example.test",
                    "body_html": "evil",
                    "attachments": [
                        {"id": "part", "filename": "invoice.pdf", "content_base64": "secret"}
                    ],
                }
            ],
            "pagination": {"page": 2, "per_page": 25, "total": 80, "has_more": True},
        }
    )
    args = {
        "account": "two@example.test",
        "query": "invoice",
        "date_from": "2026-09-01",
        "date_to": "2026-09-30",
        "has_attachments": True,
        "page": 2,
    }
    result = await mail.search_mail(args, ctx)
    assert result["pagination"] == {"page": 2, "per_page": 25, "total": 80, "has_more": True}
    assert result["messages"][0]["account"] == "two@example.test"
    assert "evil" not in json.dumps(result) and "secret" not in json.dumps(result)
    sent = ctx.phoenix.mail_tool.call_args.args[2]
    assert sent == {**args, "per_page": 25}


async def test_read_is_bounded_plain_text_and_missing_access_fails_closed():
    ctx = context(
        {
            "message": {
                "message_id": "m",
                "body_text": "x" * 51000,
                "body_html": "<script>secret</script>",
                "provider_metadata": {"secret": True},
            }
        }
    )
    result = await mail.read_mail_message({"message_id": "m"}, ctx)
    assert len(result["message"]["body_text"]) == 50000
    assert result["message"]["body_truncated"] and "secret" not in json.dumps(result)
    ctx.workspace_mail = {}
    assert await mail.read_mail_message({"message_id": "m"}, ctx) == {
        "error": "mail_access_unavailable"
    }
    assert ctx.phoenix.mail_tool.await_count == 1


async def test_saved_attachment_receipt_is_real_and_never_contains_binary_or_urls():
    ctx = context(
        {
            "file_id": "file-a",
            "name": "invoice.pdf",
            "folder_id": "folder-a",
            "size_bytes": 45,
            "sha256": "a" * 64,
            "reused": True,
            "content_base64": "secret",
            "download_url": "secret",
        }
    )
    result = await mail.save_mail_attachment(
        {"message_id": "m", "attachment_id": "part", "folder_name": "Invoices"}, ctx
    )
    assert result["file_id"] == "file-a" and result["reused"]
    assert result["_saved_artifacts"] == ["invoice.pdf"]
    assert "secret" not in json.dumps(result)
    assert ctx.phoenix.mail_tool.call_args.args[1] == "save_attachment"


async def test_unwired_agent_sending_never_reports_success():
    result = await send_email({"to": "someone@example.test", "body": "Do not send"}, context())
    assert result["sent"] is False and result["error"] == "agent_mail_sending_unavailable"


async def test_non_mail_conversation_does_not_call_model_or_mail(monkeypatch):
    planner = AsyncMock()
    monkeypatch.setattr(mail.llm, "chat_structured", planner)
    assert await mail.mail_conversation_context({}, "Build a website", llm.UsageTracker()) == {
        "applicable": False,
        "context": {},
    }
    planner.assert_not_awaited()


async def test_conversation_plans_followup_with_safe_inventory_and_real_bounded_results(
    monkeypatch,
):
    planner = AsyncMock(
        return_value={
            "applicable": True,
            "intent": "read",
            "request": "Read September invoices in one@example.test",
            "search": {
                "account": "one@example.test",
                "date_from": "2026-09-01",
                "date_to": "2026-09-30",
            },
            "read_top": 3,
        }
    )
    monkeypatch.setattr(mail.llm, "chat_structured", planner)
    phoenix = SimpleNamespace(
        mail_tool=AsyncMock(
            side_effect=[
                {
                    "messages": [{"message_id": f"m{i}"} for i in range(4)],
                    "pagination": {"total": 4},
                },
                *[{"message": {"message_id": f"m{i}", "body_text": "x" * 30000}} for i in range(3)],
            ]
        )
    )
    monkeypatch.setattr(mail, "PhoenixClient", lambda: phoenix)
    payload = {
        "workspace_mail": {"token": TOKEN, "accounts": [{**ACCOUNT, "password": "secret"}]},
        "agent_id": "chat-agent",
        "server_time_utc": "2026-09-27T12:00:00Z",
        "conversation": [{"role": "user", "body": "Lis mes factures de septembre"}],
    }
    result = await mail.mail_conversation_context(
        payload, "Oui, sur one@example.test", llm.UsageTracker()
    )
    assert result["applicable"] and result["intent"] == "read"
    assert result["context"]["request"] == "Read September invoices in one@example.test"
    assert len(result["context"]["details"]) == 3
    assert all(len(d["message"]["body_text"]) == 12000 for d in result["context"]["details"])
    assert (
        TOKEN not in repr(planner.call_args.kwargs)
        and "secret" not in planner.call_args.kwargs["user"]
    )
    assert TOKEN not in json.dumps(result)
    assert all(
        c.kwargs["acting_agent_id"] == "chat-agent" for c in phoenix.mail_tool.call_args_list
    )
    assert all(c.kwargs["allow_refresh"] is False for c in phoenix.mail_tool.call_args_list)
    assert phoenix.mail_tool.call_args_list[0].args[2]["per_page"] == 15


async def test_export_conversation_never_saves_and_returns_faithful_mission(monkeypatch):
    monkeypatch.setattr(
        mail.llm,
        "chat_structured",
        AsyncMock(
            return_value={
                "applicable": True,
                "intent": "mission",
                "request": "Save September invoice attachments in Invoices",
                "search": {"has_attachments": True},
            }
        ),
    )
    phoenix = SimpleNamespace(
        mail_tool=AsyncMock(return_value={"messages": [], "pagination": {"total": 0}})
    )
    monkeypatch.setattr(mail, "PhoenixClient", lambda: phoenix)
    result = await mail.mail_conversation_context(
        {"workspace_mail": {"token": TOKEN}},
        "Save my invoice attachments",
        llm.UsageTracker(),
        allow_save=True,
    )
    assert result["intent"] == "mission" and result["context"]["request"].startswith(
        "Save September"
    )
    assert [c.args[1] for c in phoenix.mail_tool.call_args_list] == ["search"]


async def test_conversation_planning_errors_never_reflect_secret(monkeypatch):
    monkeypatch.setattr(mail.llm, "chat_structured", AsyncMock(side_effect=RuntimeError(TOKEN)))
    result = await mail.mail_conversation_context(
        {"workspace_mail": {"token": TOKEN}}, "Read my email", llm.UsageTracker()
    )
    assert result["error"] == "mail_query_planning_unavailable" and TOKEN not in json.dumps(result)


def managed_engine(*, participant="", denied=None):
    request = RunRequest(
        run_id="run",
        task_id="task",
        workspace_id="workspace",
        agent_id=participant or "lead",
        workspace_mail={"token": TOKEN},
        autonomy=denied or {},
    )
    phoenix = SimpleNamespace(
        mail_tool=AsyncMock(return_value={"accounts": [ACCOUNT]}), post_task_comment=AsyncMock()
    )
    mission = SimpleNamespace(
        request=request,
        budget=SimpleNamespace(usage={}),
        phoenix=phoenix,
        toolbox=McpToolbox([]),
        mcp_tools=[],
        wait_for_decision=AsyncMock(),
        team=object(),
        authority=AsyncMock(),
        check_budget=lambda: None,
        adapter=SimpleNamespace(tool_result=AsyncMock()),
    )
    return managed_runner.ManagedEngine(mission, request, participant)


async def test_managed_participant_gets_native_mail_without_mcp_and_passes_own_actor():
    engine = managed_engine(participant="colleague")
    definitions = engine.configure_tools()
    assert mail.MAIL_TOOLS <= engine.tools.keys()
    assert mail.READ_TOOLS <= managed_runner.FRESH_TOOLS
    assert TOKEN not in json.dumps(definitions) and TOKEN not in engine.instructions()
    await engine.invoke_registered("list_mail_accounts", {})
    engine.mission.phoenix.mail_tool.assert_awaited_once_with(
        TOKEN, "list", {}, acting_agent_id="colleague", allow_refresh=True
    )


async def test_managed_authorization_renews_expired_mail_capability_without_model_exposure():
    engine = managed_engine(participant="colleague")
    renewed = {"token": "new-private-mail-capability", "scope": "workspace"}
    engine.mission.authority = AsyncMock(return_value={"allowed": True, "workspace_mail": renewed})
    await engine.authorize("list_mail_accounts")
    assert engine.ctx.workspace_mail == renewed and engine.request.workspace_mail == renewed
    engine.mission.authority.assert_awaited_once_with(
        "authorize", agent_id="colleague", tool_name="list_mail_accounts"
    )
    await engine.invoke_registered("list_mail_accounts", {})
    engine.mission.phoenix.mail_tool.assert_awaited_once_with(
        renewed["token"], "list", {}, acting_agent_id="colleague", allow_refresh=True
    )
    assert renewed["token"] not in json.dumps(engine.configure_tools())
    assert renewed["token"] not in engine.instructions()


async def test_denied_authorization_cannot_renew_or_invoke_mail_access():
    engine = managed_engine(participant="colleague")
    engine.mission.authority = AsyncMock(
        return_value={"allowed": False, "workspace_mail": {"token": "denied-token"}}
    )
    with pytest.raises(managed_runner.RuntimePaused):
        await engine.authorize("list_mail_accounts")
    assert engine.ctx.workspace_mail["token"] == TOKEN
    engine.mission.phoenix.mail_tool.assert_not_awaited()


async def test_managed_live_deny_blocks_native_mail_without_calling_api():
    engine = managed_engine(participant="colleague")
    engine.configure_tools()
    engine.authorize = AsyncMock(
        return_value={
            "allowed": True,
            "autonomy": {"rules": [{"tool_pattern": "*_mail*", "behavior": "deny"}]},
        }
    )
    await engine.handle_action({"name": "list_mail_accounts", "arguments": {}, "call_id": "one"})
    engine.mission.phoenix.mail_tool.assert_not_awaited()
    assert (
        engine.mission.adapter.tool_result.call_args.args[-1]["error"] == "Tool access was revoked."
    )


def test_disabled_native_mail_tools_are_absent_from_managed_tool_schema():
    engine = managed_engine(denied={"rules": [{"tool_pattern": "search_mail", "behavior": "deny"}]})
    engine.request.agent = {"tool_preferences": {"disabled": ["read_mail_message"]}}
    engine.configure_tools()
    assert not {"search_mail", "read_mail_message"} & engine.tools.keys()
    assert ApprovalPolicy().decision("search_mail") == "auto"
    assert ApprovalPolicy().decision("save_mail_attachment") == "auto"


async def test_deep_delegate_keeps_parent_denies_and_passes_its_own_identity(monkeypatch):
    import langchain.agents
    from langchain_core.messages import AIMessage

    ctx = context()
    ctx.phoenix.post_task_comment = AsyncMock()
    ctx.phoenix.post_tool_activity = AsyncMock()
    request = RunRequest(
        run_id="run",
        task_id="task",
        workspace_id="workspace",
        agent_id="lead",
        workspace_mail=ctx.workspace_mail,
        colleagues=[Colleague(id="child", name="Child")],
        autonomy={"rules": [{"tool_pattern": "save_mail_attachment", "behavior": "deny"}]},
    )
    engine = deep_runner._Engine(
        request, ctx, RunState(run_id="run"), ctx.phoenix, McpToolbox([]), [], AsyncMock()
    )
    seen = {}

    def create_graph(**kwargs):
        tools = {t.name: t for t in kwargs["tools"]}
        seen.update(tools)

        class Graph:
            async def astream(self, *_args, **_kwargs):
                await tools["list_mail_accounts"].ainvoke({})
                yield {"messages": [AIMessage(content="One mailbox is available.")]}

        return Graph()

    monkeypatch.setattr(langchain.agents, "create_agent", create_graph)
    monkeypatch.setattr(deep_runner, "_build_model", lambda *_: object())
    await engine._run_participant(
        request.colleagues[0], "List the available mailboxes", engine.team
    )
    assert mail.READ_TOOLS <= seen.keys() and "save_mail_attachment" not in seen
    ctx.phoenix.mail_tool.assert_awaited_once_with(
        TOKEN, "list", {}, acting_agent_id="child", allow_refresh=True
    )


@pytest.mark.parametrize(
    "title", ["Lis mes mails", "Read my inbox", "Save invoice attachments from my emails"]
)
def test_mail_work_cannot_complete_from_fluent_claims_without_mail_evidence(title):
    request = RunRequest(run_id="r", task_id="t", workspace_id="w", task_title=title)
    assert mail.evidence_error(request, [])
    unrelated = ToolCall(tool="draft_document", input={}, output={"content": "I found invoices."})
    assert mail.evidence_error(request, [unrelated])


@pytest.mark.parametrize(
    "title",
    [
        "Retrouve mes factures dans mes mails",
        "Search my email invoices",
        "Lis mes mails",
        "Combien de mails ai-je reçus hier ?",
        "List my emails",
        "Show my mailboxes and find the invoices",
        "As-tu accès à mes mails de septembre ?",
        "List my mailboxes and summarize their content",
    ],
)
def test_mail_account_listing_does_not_verify_message_questions(title):
    request = RunRequest(
        run_id="r", task_id="t", workspace_id="w", task_title=title, input={"mission_kind": "mail"}
    )
    accounts = ToolCall(tool="list_mail_accounts", input={}, output={"accounts": [ACCOUNT]})
    assert mail.evidence_error(request, [accounts])
    searched = ToolCall(
        tool="search_mail", input={}, output={"messages": [], "pagination": {"total": 0}}
    )
    assert mail.evidence_error(request, [accounts, searched]) is None


@pytest.mark.parametrize(
    "title",
    [
        "List my mailboxes",
        "Which mail accounts are connected?",
        "Liste mes boîtes mail",
        "As-tu accès à mes mails ?",
        "Can you access my emails?",
        "Quels comptes mail sont disponibles ?",
    ],
)
def test_explicit_mail_inventory_or_access_question_accepts_real_account_listing(title):
    request = RunRequest(
        run_id="r", task_id="t", workspace_id="w", task_title=title, input={"mission_kind": "mail"}
    )
    accounts = ToolCall(tool="list_mail_accounts", input={}, output={"accounts": [ACCOUNT]})
    assert mail.evidence_error(request, [accounts]) is None


def test_mail_export_needs_actual_read_and_saved_source_receipt():
    request = RunRequest(
        run_id="r",
        task_id="t",
        workspace_id="w",
        task_title="Save invoice attachments from my emails",
    )
    searched = ToolCall(
        tool="search_mail", input={}, output={"messages": [], "pagination": {"total": 0}}
    )
    assert mail.evidence_error(request, [searched]).startswith("No matching synchronized messages")
    assert searched.output["messages"] == []  # No fabricated file or matching message.
    saved = ToolCall(
        tool="save_mail_attachment",
        input={},
        output={
            "file_id": "file",
            "name": "invoice.pdf",
            "source": {"message_id": "m", "attachment_id": "a"},
        },
    )
    assert mail.evidence_error(request, [searched, saved]) is None
    saved.approved = False
    assert mail.evidence_error(request, [searched, saved])


async def test_partial_mail_export_cannot_complete_because_another_attachment_saved(
    monkeypatch, phoenix
):
    from app.agents import runner

    request = RunRequest(
        run_id="partial-export",
        task_id="task",
        workspace_id="workspace",
        agent_id="lead",
        task_title="Save invoice attachments from my emails",
    )
    monkeypatch.setattr(
        runner,
        "plan_steps",
        AsyncMock(
            return_value=[
                {"tool": "search_mail", "input": {}},
                {
                    "tool": "save_mail_attachment",
                    "input": {"message_id": "m", "attachment_id": "first"},
                },
                {
                    "tool": "save_mail_attachment",
                    "input": {"message_id": "m", "attachment_id": "second"},
                },
            ]
        ),
    )

    async def execute(params, _ctx):
        if "attachment_id" not in params:
            return {"messages": [{"message_id": "m"}], "pagination": {"total": 1}}
        if params["attachment_id"] == "first":
            return {
                "file_id": "file",
                "name": "invoice.pdf",
                "_saved_artifacts": ["invoice.pdf"],
                "source": {"message_id": "m", "attachment_id": "first"},
            }
        return {"error": "mail_access_denied"}

    monkeypatch.setattr(runner, "get_tool", lambda _: execute)
    result = await runner.execute_run(request, phoenix=phoenix)
    assert result.status == RunStatus.FAILED
    assert not any(kind == "complete" for kind, _ in phoenix.calls)


async def test_first_person_french_mail_uses_structured_query_planner(monkeypatch):
    planner = AsyncMock(return_value={"applicable": False})
    monkeypatch.setattr(mail.llm, "chat_structured", planner)
    await mail.mail_conversation_context(
        {"workspace_mail": {"token": TOKEN}}, "Recherche mes mails", llm.UsageTracker()
    )
    planner.assert_awaited_once()
