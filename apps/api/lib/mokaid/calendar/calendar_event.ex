defmodule Mokaid.Calendar.CalendarEvent do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "calendar_events" do
    belongs_to :workspace, Mokaid.Workspaces.Workspace
    belongs_to :member, Mokaid.Members.Member
    belongs_to :agent, Mokaid.Agents.Agent
    belongs_to :project, Mokaid.Projects.Project
    belongs_to :task, Mokaid.Tasks.Task

    field :title, :string
    field :description, :string
    field :kind, :string, default: "event"
    field :start_at, :utc_datetime_usec
    field :end_at, :utc_datetime_usec
    field :all_day, :boolean, default: false
    field :leave_request_id, :binary_id
    field :color, :string
    field :metadata, :map, default: %{}

    timestamps()
  end

  @kinds ~w(event meeting deadline milestone leave personal schedule)

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :workspace_id,
      :title,
      :description,
      :kind,
      :start_at,
      :end_at,
      :all_day,
      :member_id,
      :agent_id,
      :project_id,
      :task_id,
      :leave_request_id,
      :color,
      :metadata
    ])
    |> validate_required([:workspace_id, :title, :kind, :start_at])
    |> validate_inclusion(:kind, @kinds)
  end
end
