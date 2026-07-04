defmodule Mokaid.Integrations.IntegrationConnection do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "integration_connections" do
    belongs_to :workspace, Mokaid.Workspaces.Workspace
    belongs_to :provider, Mokaid.Integrations.IntegrationProvider
    belongs_to :connected_by_member, Mokaid.Members.Member

    field :status, :string, default: "disconnected"
    field :connected_account, :string
    field :encrypted_credentials, :binary, redact: true
    field :permissions, :map, default: %{}
    field :last_sync_at, :utc_datetime_usec
    field :settings, :map, default: %{}

    timestamps()
  end

  def changeset(connection, attrs) do
    connection
    |> cast(attrs, [
      :workspace_id,
      :provider_id,
      :status,
      :connected_account,
      :connected_by_member_id,
      :permissions,
      :settings
    ])
    |> validate_required([:workspace_id, :provider_id])
    |> validate_inclusion(:status, ~w(connected disconnected error pending))
    |> unique_constraint([:workspace_id, :provider_id])
  end
end
