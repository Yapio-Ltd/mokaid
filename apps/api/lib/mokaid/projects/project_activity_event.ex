defmodule Mokaid.Projects.ProjectActivityEvent do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "project_activity_events" do
    field :workspace_id, :binary_id
    field :project_id, :binary_id
    field :actor_type, :string
    field :actor_id, :binary_id
    field :actor_name, :string
    field :event_type, :string
    field :metadata, :map, default: %{}
    field :occurred_at, :utc_datetime_usec

    timestamps(updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :workspace_id,
      :project_id,
      :actor_type,
      :actor_id,
      :actor_name,
      :event_type,
      :metadata
    ])
    |> validate_required([:workspace_id, :project_id, :actor_type, :event_type])
    |> put_change(:occurred_at, DateTime.utc_now())
  end
end
