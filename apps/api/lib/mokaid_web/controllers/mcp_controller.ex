defmodule MokaidWeb.MCPController do
  @moduledoc """
  MCP Hub API: server catalog, workspace installations and the agent
  permission matrix. Install/uninstall/grants require admin-level
  integration permissions.
  """

  use MokaidWeb, :controller

  alias Mokaid.MCP
  alias MokaidWeb.JSON, as: Serializer

  def index(conn, _params) do
    with :ok <- Permissions.authorize(current_member(conn), "integrations.view") do
      servers = MCP.list_servers()
      installations = MCP.list_installations(workspace_id(conn))

      json(conn, %{
        data: %{
          servers: Enum.map(servers, &Serializer.mcp_server/1),
          installations: Enum.map(installations, &Serializer.mcp_installation/1)
        }
      })
    end
  end

  def install(conn, %{"server" => server_key} = params) do
    with :ok <- Permissions.authorize(current_member(conn), "integrations.connect"),
         {:ok, installation} <-
           MCP.install(workspace_id(conn), server_key, current_member(conn), params) do
      conn
      |> put_status(:created)
      |> json(%{data: Serializer.mcp_installation(installation)})
    end
  end

  def uninstall(conn, %{"id" => id}) do
    with :ok <- Permissions.authorize(current_member(conn), "integrations.disconnect"),
         %{} = installation <- MCP.get_installation(workspace_id(conn), id),
         {:ok, _} <- MCP.uninstall(installation, current_member(conn)) do
      json(conn, %{data: %{id: id, status: "uninstalled"}})
    end
  end

  def agent_grants(conn, %{"agent_id" => agent_id}) do
    with :ok <- Permissions.authorize(current_member(conn), "integrations.view") do
      grants = MCP.list_grants_for_agent(workspace_id(conn), agent_id)
      json(conn, %{data: Enum.map(grants, &Serializer.mcp_grant/1)})
    end
  end

  def set_grant(conn, %{"agent_id" => agent_id, "installation_id" => installation_id} = params) do
    granted = params["granted"] != false

    with :ok <- Permissions.authorize(current_member(conn), "integrations.connect"),
         %{} = _installation <- MCP.get_installation(workspace_id(conn), installation_id),
         {:ok, grant} <-
           MCP.set_grant(
             workspace_id(conn),
             agent_id,
             installation_id,
             granted,
             current_member(conn)
           ) do
      json(conn, %{data: Serializer.mcp_grant(grant)})
    end
  end
end
