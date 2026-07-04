defmodule Mokaid.Audit.AuditLog do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "audit_logs" do
    field :workspace_id, :binary_id
    field :actor_type, :string
    field :actor_id, :binary_id
    field :actor_name, :string
    field :action, :string
    field :resource_type, :string
    field :resource_id, :binary_id
    field :ip_address, :string
    field :user_agent, :string
    field :metadata, :map, default: %{}
    field :occurred_at, :utc_datetime_usec

    timestamps(updated_at: false)
  end

  def changeset(log, attrs) do
    log
    |> cast(attrs, [
      :workspace_id,
      :actor_type,
      :actor_id,
      :actor_name,
      :action,
      :resource_type,
      :resource_id,
      :ip_address,
      :user_agent,
      :metadata
    ])
    |> validate_required([:actor_type, :action])
    |> put_change(:occurred_at, DateTime.utc_now())
  end
end
