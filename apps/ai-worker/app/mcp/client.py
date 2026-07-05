"""MCP client: connects to the remote MCP servers granted to an agent.

Tools are discovered over streamable HTTP and exposed to the planner under
qualified names (`mcp:<server_key>:<tool_name>`). The agent then decides on
its own whether a granted MCP tool is useful for the task at hand. Sessions
are opened per operation — simple and stateless, at the cost of a handshake
per call.
"""

import asyncio
from typing import Any

import structlog

from app.schemas import McpServerGrant

log = structlog.get_logger()

DISCOVERY_TIMEOUT_S = 15
CALL_TIMEOUT_S = 60
TOOL_PREFIX = "mcp:"

# Substrings that mark an MCP tool as a sensitive write → human approval.
_WRITE_MARKERS = (
    "create",
    "update",
    "delete",
    "write",
    "send",
    "post",
    "publish",
    "execute",
    "run",
    "deploy",
    "insert",
    "remove",
    "pay",
    "charge",
)


def qualified_name(server_key: str, tool_name: str) -> str:
    return f"{TOOL_PREFIX}{server_key}:{tool_name}"


def split_qualified(name: str) -> tuple[str, str] | None:
    """Returns (server_key, tool_name) for a qualified MCP tool name."""
    if not name.startswith(TOOL_PREFIX):
        return None
    rest = name[len(TOOL_PREFIX) :]
    server_key, _, tool_name = rest.partition(":")
    if not server_key or not tool_name:
        return None
    return server_key, tool_name


def is_write_tool(tool_name: str) -> bool:
    lowered = tool_name.lower()
    return any(marker in lowered for marker in _WRITE_MARKERS)


def _auth_headers(grant: McpServerGrant) -> dict[str, str]:
    creds = grant.credentials or {}
    token = creds.get("access_token") or creds.get("token") or creds.get("api_key")
    if token:
        return {"Authorization": f"Bearer {token}"}
    return {}


class McpToolbox:
    """Discovered MCP tools for one run, keyed by qualified name."""

    def __init__(self, grants: list[McpServerGrant]) -> None:
        self._grants = {g.key: g for g in grants}
        self.tools: dict[str, dict[str, Any]] = {}

    async def discover(self) -> list[dict[str, Any]]:
        """Lists tools on every granted server. Failures are logged, not fatal."""
        for grant in self._grants.values():
            try:
                listed = await asyncio.wait_for(
                    self._list_tools(grant), timeout=DISCOVERY_TIMEOUT_S
                )
            except Exception as exc:  # noqa: BLE001 — a dead server must not kill the run
                log.warning("mcp_discovery_failed", server=grant.key, error=str(exc))
                continue

            for tool in listed:
                name = qualified_name(grant.key, tool["name"])
                self.tools[name] = {
                    "name": name,
                    "server": grant.name,
                    "server_key": grant.key,
                    "tool": tool["name"],
                    "description": tool.get("description") or "",
                    "input_schema": tool.get("input_schema") or {},
                }

            log.info("mcp_tools_discovered", server=grant.key, count=len(listed))

        return list(self.tools.values())

    def has(self, name: str) -> bool:
        return name in self.tools

    async def call(self, name: str, arguments: dict[str, Any]) -> Any:
        parts = split_qualified(name)
        if parts is None or name not in self.tools:
            raise ValueError(f"unknown MCP tool: {name}")

        server_key, tool_name = parts
        grant = self._grants[server_key]
        return await asyncio.wait_for(
            self._call_tool(grant, tool_name, arguments), timeout=CALL_TIMEOUT_S
        )

    async def _list_tools(self, grant: McpServerGrant) -> list[dict[str, Any]]:
        from mcp import ClientSession
        from mcp.client.streamable_http import streamablehttp_client

        async with streamablehttp_client(grant.url, headers=_auth_headers(grant)) as (
            read,
            write,
            _get_session_id,
        ):
            async with ClientSession(read, write) as session:
                await session.initialize()
                result = await session.list_tools()
                return [
                    {
                        "name": tool.name,
                        "description": tool.description,
                        "input_schema": tool.inputSchema,
                    }
                    for tool in result.tools
                ]

    async def _call_tool(
        self, grant: McpServerGrant, tool_name: str, arguments: dict[str, Any]
    ) -> Any:
        from mcp import ClientSession
        from mcp.client.streamable_http import streamablehttp_client

        async with streamablehttp_client(grant.url, headers=_auth_headers(grant)) as (
            read,
            write,
            _get_session_id,
        ):
            async with ClientSession(read, write) as session:
                await session.initialize()
                result = await session.call_tool(tool_name, arguments)

                contents: list[Any] = []
                for item in result.content:
                    if getattr(item, "type", None) == "text":
                        contents.append(item.text)
                    else:
                        contents.append(item.model_dump(mode="json"))

                return {
                    "server": grant.key,
                    "tool": tool_name,
                    "is_error": bool(getattr(result, "isError", False)),
                    "content": contents,
                }
