defmodule Mokaid.Projects.Project do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "projects" do
    belongs_to :workspace, Mokaid.Workspaces.Workspace
    belongs_to :owner_member, Mokaid.Members.Member

    field :name, :string
    field :description, :string
    field :status, :string, default: "planning"
    field :priority, :string, default: "medium"
    field :progress_percent, :integer, default: 0
    field :start_at, :utc_datetime_usec
    field :due_at, :utc_datetime_usec
    field :cover_kind, :string
    field :drive_folder_id, :binary_id
    field :metadata, :map, default: %{}
    field :archived_at, :utc_datetime_usec

    has_many :tasks, Mokaid.Tasks.Task
    has_many :project_agents, Mokaid.Projects.ProjectAgent
    has_many :project_members, Mokaid.Projects.ProjectMember

    timestamps()
  end

  @statuses ~w(planning active in_review on_hold completed archived)

  def changeset(project, attrs) do
    project
    |> cast(attrs, [
      :workspace_id,
      :name,
      :description,
      :status,
      :priority,
      :progress_percent,
      :owner_member_id,
      :start_at,
      :due_at,
      :cover_kind,
      :drive_folder_id,
      :metadata
    ])
    |> validate_required([:workspace_id, :name])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:priority, ~w(low medium high urgent))
  end
end
