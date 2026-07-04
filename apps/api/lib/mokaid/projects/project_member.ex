defmodule Mokaid.Projects.ProjectMember do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "project_members" do
    belongs_to :workspace, Mokaid.Workspaces.Workspace
    belongs_to :project, Mokaid.Projects.Project
    belongs_to :member, Mokaid.Members.Member

    field :role, :string, default: "contributor"

    timestamps()
  end

  def changeset(project_member, attrs) do
    project_member
    |> cast(attrs, [:workspace_id, :project_id, :member_id, :role])
    |> validate_required([:workspace_id, :project_id, :member_id])
    |> unique_constraint([:project_id, :member_id])
  end
end
