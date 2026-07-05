defmodule Mokaid.MCP.AgentGrant do
  @moduledoc "Explicit permission: this agent may (or may not) use this MCP installation."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "agent_mcp_grants" do
    belongs_to :workspace, Mokaid.Workspaces.Workspace
    belongs_to :agent, Mokaid.Agents.Agent
    belongs_to :installation, Mokaid.MCP.Installation
    belongs_to :granted_by_member, Mokaid.Members.Member

    field :granted, :boolean, default: true

    timestamps()
  end

  def changeset(grant, attrs) do
    grant
    |> cast(attrs, [:workspace_id, :agent_id, :installation_id, :granted, :granted_by_member_id])
    |> validate_required([:workspace_id, :agent_id, :installation_id])
    |> unique_constraint([:agent_id, :installation_id])
  end
end
