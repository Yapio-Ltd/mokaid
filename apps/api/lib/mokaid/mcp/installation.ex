defmodule Mokaid.MCP.Installation do
  @moduledoc "A workspace's installation of an MCP server, with encrypted credentials."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @statuses ~w(pending connected error disconnected)

  schema "mcp_installations" do
    belongs_to :workspace, Mokaid.Workspaces.Workspace
    belongs_to :server, Mokaid.MCP.Server
    belongs_to :connected_by_member, Mokaid.Members.Member

    field :status, :string, default: "pending"
    field :connected_account, :string
    field :encrypted_credentials, :binary, redact: true
    field :settings, :map, default: %{}
    field :error, :string
    field :last_used_at, :utc_datetime_usec

    has_many :agent_grants, Mokaid.MCP.AgentGrant, foreign_key: :installation_id

    timestamps()
  end

  def changeset(installation, attrs) do
    installation
    |> cast(attrs, [
      :workspace_id,
      :server_id,
      :status,
      :connected_account,
      :connected_by_member_id,
      :settings,
      :error,
      :last_used_at
    ])
    |> validate_required([:workspace_id, :server_id])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:workspace_id, :server_id])
  end
end
