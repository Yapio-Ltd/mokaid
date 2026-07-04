defmodule Mokaid.Tasks.Subtask do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "subtasks" do
    belongs_to :workspace, Mokaid.Workspaces.Workspace
    belongs_to :task, Mokaid.Tasks.Task

    field :title, :string
    field :done, :boolean, default: false
    field :position, :integer, default: 0

    timestamps()
  end

  def changeset(subtask, attrs) do
    subtask
    |> cast(attrs, [:workspace_id, :task_id, :title, :done, :position])
    |> validate_required([:workspace_id, :task_id, :title])
  end
end
