defmodule Mokaid.Agents.AgentStatusEvent do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "agent_status_events" do
    belongs_to :workspace, Mokaid.Workspaces.Workspace
    belongs_to :agent, Mokaid.Agents.Agent

    field :from_status, :string
    field :to_status, :string
    field :reason, :string
    field :metadata, :map, default: %{}
    field :occurred_at, :utc_datetime_usec

    timestamps(updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:workspace_id, :agent_id, :from_status, :to_status, :reason, :metadata])
    |> validate_required([:workspace_id, :agent_id, :to_status])
    |> put_change(:occurred_at, DateTime.utc_now())
  end
end
