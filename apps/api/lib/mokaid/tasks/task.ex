defmodule Mokaid.Tasks.Task do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "tasks" do
    belongs_to :workspace, Mokaid.Workspaces.Workspace
    belongs_to :project, Mokaid.Projects.Project
    belongs_to :assigned_agent, Mokaid.Agents.Agent
    belongs_to :assigned_member, Mokaid.Members.Member
    belongs_to :created_by_member, Mokaid.Members.Member

    field :title, :string
    field :description, :string
    field :status, :string, default: "to_do"
    field :priority, :string, default: "medium"
    field :due_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :progress_percent, :integer, default: 0
    field :requires_approval, :boolean, default: false
    field :tags, {:array, :string}, default: []
    field :position, :integer, default: 0
    field :metadata, :map, default: %{}

    has_many :subtasks, Mokaid.Tasks.Subtask
    has_many :comments, Mokaid.Tasks.TaskComment
    has_many :approval_requests, Mokaid.Tasks.TaskApprovalRequest
    has_many :execution_runs, Mokaid.Tasks.TaskExecutionRun

    timestamps()
  end

  @statuses ~w(to_do in_progress in_review waiting blocked completed canceled overdue)
  @priorities ~w(low medium high urgent)

  def changeset(task, attrs) do
    task
    |> cast(attrs, [
      :workspace_id,
      :project_id,
      :title,
      :description,
      :status,
      :priority,
      :assigned_agent_id,
      :assigned_member_id,
      :created_by_member_id,
      :due_at,
      :started_at,
      :completed_at,
      :progress_percent,
      :requires_approval,
      :tags,
      :position,
      :metadata
    ])
    |> validate_required([:workspace_id, :title])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:priority, @priorities)
    |> validate_number(:progress_percent,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 100
    )
    |> maybe_set_completion()
  end

  defp maybe_set_completion(changeset) do
    case get_change(changeset, :status) do
      "completed" ->
        changeset
        |> put_change(:completed_at, DateTime.utc_now())
        |> put_change(:progress_percent, 100)

      "in_progress" ->
        if get_field(changeset, :started_at),
          do: changeset,
          else: put_change(changeset, :started_at, DateTime.utc_now())

      _ ->
        changeset
    end
  end
end
