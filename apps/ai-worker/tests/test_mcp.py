from app.mcp.client import (
    McpToolbox,
    is_write_tool,
    qualified_name,
    split_qualified,
)
from app.policies.approval import requires_approval, risk_for_tool
from app.schemas import McpServerGrant, RiskLevel


def test_qualified_name_round_trip():
    name = qualified_name("figma", "get_file")
    assert name == "mcp:figma:get_file"
    assert split_qualified(name) == ("figma", "get_file")
    assert split_qualified("summarize") is None
    assert split_qualified("mcp:broken") is None


def test_write_tool_detection():
    assert is_write_tool("create_issue")
    assert is_write_tool("send_message")
    assert not is_write_tool("get_file")
    assert not is_write_tool("list_projects")


def test_mcp_risk_policy():
    assert risk_for_tool("mcp:figma:get_file") == RiskLevel.MEDIUM
    assert not requires_approval("mcp:figma:get_file")

    assert risk_for_tool("mcp:github:create_issue") == RiskLevel.HIGH
    assert requires_approval("mcp:github:create_issue")


async def test_toolbox_discovery_and_call(monkeypatch):
    grant = McpServerGrant(
        key="figma",
        name="Figma",
        url="https://mcp.figma.com/mcp",
        credentials={"access_token": "tok"},
    )
    toolbox = McpToolbox([grant])

    async def fake_list_tools(_grant):
        return [{"name": "get_file", "description": "Read a Figma file", "input_schema": {}}]

    async def fake_call_tool(_grant, tool_name, arguments):
        return {"server": "figma", "tool": tool_name, "is_error": False, "content": ["ok"]}

    monkeypatch.setattr(toolbox, "_list_tools", fake_list_tools)
    monkeypatch.setattr(toolbox, "_call_tool", fake_call_tool)

    tools = await toolbox.discover()
    assert [t["name"] for t in tools] == ["mcp:figma:get_file"]
    assert toolbox.has("mcp:figma:get_file")

    result = await toolbox.call("mcp:figma:get_file", {"file_key": "abc"})
    assert result["content"] == ["ok"]


async def test_toolbox_discovery_failure_is_not_fatal(monkeypatch):
    grant = McpServerGrant(key="down", name="Down", url="https://down.example/mcp")
    toolbox = McpToolbox([grant])

    async def broken(_grant):
        raise ConnectionError("unreachable")

    monkeypatch.setattr(toolbox, "_list_tools", broken)
    assert await toolbox.discover() == []
