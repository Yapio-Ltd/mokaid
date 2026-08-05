defmodule Mokaid.Audit.PlatformAuditEvent do
  @moduledoc """
  Append-only platform operator audit trail (no UPDATE/DELETE allowed at DB level).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "platform_audit_events" do
    field :actor_id, :binary_id
    field :actor_email, :string
    field :actor_name, :string
    field :action, :string
    field :resource_type, :string
    field :resource_id, :binary_id
    field :workspace_id, :binary_id
    field :ip_address, :string
    field :user_agent, :string
    field :metadata, :map, default: %{}
    field :occurred_at, :utc_datetime_usec

    timestamps(updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :actor_id,
      :actor_email,
      :actor_name,
      :action,
      :resource_type,
      :resource_id,
      :workspace_id,
      :ip_address,
      :user_agent,
      :metadata,
      :occurred_at
    ])
    |> validate_required([:action, :occurred_at])
  end
end
