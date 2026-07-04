defmodule Mokaid.Projects.ProjectAgent do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "project_agents" do
    belongs_to :workspace, Mokaid.Workspaces.Workspace
    belongs_to :project, Mokaid.Projects.Project
    belongs_to :agent, Mokaid.Agents.Agent

    timestamps()
  end

  def changeset(project_agent, attrs) do
    project_agent
    |> cast(attrs, [:workspace_id, :project_id, :agent_id])
    |> validate_required([:workspace_id, :project_id, :agent_id])
    |> unique_constraint([:project_id, :agent_id])
  end
end
