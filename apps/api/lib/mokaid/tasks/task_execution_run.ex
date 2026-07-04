defmodule Mokaid.Tasks.TaskExecutionRun do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "task_execution_runs" do
    belongs_to :workspace, Mokaid.Workspaces.Workspace
    belongs_to :task, Mokaid.Tasks.Task
    belongs_to :agent, Mokaid.Agents.Agent

    field :status, :string, default: "queued"
    field :input, :map, default: %{}
    field :steps, {:array, :map}, default: []
    field :tool_calls, {:array, :map}, default: []
    field :output, :map
    field :error, :string
    field :token_usage, :map, default: %{}
    field :cost_cents, :integer, default: 0
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    timestamps()
  end

  @statuses ~w(queued running waiting_for_approval waiting_for_user_input completed failed canceled)

  def changeset(run, attrs) do
    run
    |> cast(attrs, [:workspace_id, :task_id, :agent_id, :status, :input])
    |> validate_required([:workspace_id, :task_id])
    |> validate_inclusion(:status, @statuses)
  end

  def progress_changeset(run, attrs) do
    run
    |> cast(attrs, [:status, :steps, :tool_calls, :output, :error, :token_usage, :cost_cents])
    |> validate_inclusion(:status, @statuses)
    |> maybe_stamp()
  end

  defp maybe_stamp(changeset) do
    case get_change(changeset, :status) do
      "running" ->
        if get_field(changeset, :started_at),
          do: changeset,
          else: put_change(changeset, :started_at, DateTime.utc_now())

      status when status in ["completed", "failed", "canceled"] ->
        put_change(changeset, :completed_at, DateTime.utc_now())

      _ ->
        changeset
    end
  end
end
