defmodule Mokaid.Tasks.TaskApprovalRequest do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "task_approval_requests" do
    belongs_to :workspace, Mokaid.Workspaces.Workspace
    belongs_to :task, Mokaid.Tasks.Task
    belongs_to :run, Mokaid.Tasks.TaskExecutionRun
    belongs_to :agent, Mokaid.Agents.Agent
    belongs_to :reviewed_by_member, Mokaid.Members.Member

    field :tool_name, :string
    field :risk_level, :string, default: "medium"
    field :proposed_action, :string
    field :input_payload, :map, default: %{}
    field :status, :string, default: "pending"
    field :reviewed_at, :utc_datetime_usec
    field :decision_payload, :map

    timestamps()
  end

  def changeset(request, attrs) do
    request
    |> cast(attrs, [
      :workspace_id,
      :task_id,
      :run_id,
      :agent_id,
      :tool_name,
      :risk_level,
      :proposed_action,
      :input_payload
    ])
    |> validate_required([:workspace_id, :task_id, :tool_name, :proposed_action])
    |> validate_inclusion(:risk_level, ~w(low medium high critical))
  end

  def decision_changeset(request, attrs) do
    request
    |> cast(attrs, [:status, :reviewed_by_member_id, :decision_payload])
    |> validate_inclusion(:status, ~w(approved rejected edited expired))
    |> put_change(:reviewed_at, DateTime.utc_now())
  end
end
