defmodule Mokaid.Tasks.TaskComment do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "task_comments" do
    belongs_to :workspace, Mokaid.Workspaces.Workspace
    belongs_to :task, Mokaid.Tasks.Task
    belongs_to :author_member, Mokaid.Members.Member
    belongs_to :author_agent, Mokaid.Agents.Agent

    field :body, :string
    field :deleted_at, :utc_datetime_usec

    timestamps()
  end

  def changeset(comment, attrs) do
    comment
    |> cast(attrs, [:workspace_id, :task_id, :author_member_id, :author_agent_id, :body])
    |> validate_required([:workspace_id, :task_id, :body])
    |> validate_length(:body, min: 1, max: 10_000)
  end
end
