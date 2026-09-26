from app.schemas import RunRequest, ToolCall


def test_dispatch_payload_preserves_colleague_policy_and_identity():
    request = RunRequest.model_validate(
        {
            "run_id": "run",
            "workspace_id": "workspace",
            "task_id": "task",
            "colleagues": [
                {
                    "id": "researcher",
                    "name": "Researcher",
                    "status": "busy",
                    "agent": {
                        "instructions": "Cite your sources.",
                        "tool_preferences": {"disabled": ["web_search"]},
                    },
                    "autonomy": {
                        "mode": "supervised",
                        "rules": [{"tool_pattern": "generate_image", "behavior": "deny"}],
                    },
                }
            ],
        }
    )

    colleague = request.colleagues[0]
    assert colleague.status == "busy"
    assert colleague.agent["tool_preferences"]["disabled"] == ["web_search"]
    assert colleague.autonomy["rules"][0]["behavior"] == "deny"

    call = ToolCall(tool="web_search", input={"query": "a fact"}, agent_id=colleague.id)
    assert ToolCall.model_validate(call.model_dump()).agent_id == "researcher"


def test_old_dispatches_and_tool_calls_remain_readable():
    request = RunRequest(
        run_id="run",
        workspace_id="workspace",
        task_id="task",
        colleagues=[{"id": "researcher", "name": "Researcher"}],
    )

    colleague = request.colleagues[0]
    assert colleague.status == "idle"
    assert colleague.agent == {}
    assert colleague.autonomy == {}
    assert ToolCall(tool="web_search", input={}).agent_id is None
