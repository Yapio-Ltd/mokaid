defmodule Mokaid.AI.RuntimeRun do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "managed_runtime_runs" do
    belongs_to :workspace, Mokaid.Workspaces.Workspace
    belongs_to :run, Mokaid.Tasks.TaskExecutionRun
    field :status, :string, default: "reserved"
    field :budget_cents, :integer
    field :budget_revision, :integer, default: 0
    field :funding, {:array, :map}, default: []
    field :reserved_credits, :integer
    field :included_reserved, :integer, default: 0
    field :balance_reserved, :integer, default: 0
    field :credits_period_start, :utc_datetime_usec
    field :metered_only, :boolean, default: false
    field :reported_cost_cents, :integer
    field :charged_credits, :integer
    field :usage_status, :string, default: "unknown"
    field :settled_at, :utc_datetime_usec
    field :finalized_at, :utc_datetime_usec
    belongs_to :final_comment, Mokaid.Tasks.TaskComment
    timestamps()
  end
end
