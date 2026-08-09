defmodule Mokaid.Agents.PermissionRule do
  @moduledoc """
  A persisted per-agent tool permission rule ("always allow" / "always deny"),
  mirroring Claude Code's scoped allow/deny rules.

  - `tool_pattern` matches a tool name exactly or with a trailing wildcard
    (`mcp:github:*`).
  - `behavior` "allow" auto-approves the gated tool for this agent;
    "deny" auto-rejects it (the agent adapts and continues without it).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "agent_permission_rules" do
    belongs_to :workspace, Mokaid.Workspaces.Workspace
    belongs_to :agent, Mokaid.Agents.Agent
    belongs_to :created_by_member, Mokaid.Members.Member

    field :tool_pattern, :string
    field :behavior, :string, default: "allow"

    timestamps()
  end

  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [:workspace_id, :agent_id, :tool_pattern, :behavior, :created_by_member_id])
    |> validate_required([:workspace_id, :agent_id, :tool_pattern, :behavior])
    |> validate_inclusion(:behavior, ~w(allow deny))
    |> validate_length(:tool_pattern, min: 1, max: 200)
    |> validate_format(:tool_pattern, ~r/^[\w:\-\*]+$/,
      message: "must be a tool name, optionally with a * wildcard"
    )
    |> unique_constraint([:agent_id, :tool_pattern],
      name: :agent_permission_rules_agent_tool_unique
    )
  end
end
