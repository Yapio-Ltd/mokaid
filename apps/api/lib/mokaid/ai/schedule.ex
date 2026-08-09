defmodule Mokaid.AI.Schedule do
  @moduledoc """
  A recurring automation: "every Monday 9am, prepare the weekly report".

  The `Mokaid.AI.Workers.ScheduleWorker` cron sweeps due schedules every
  minute and turns each into a regular Task + AI run for the agent —
  reusing the whole existing pipeline (queueing, approvals, chat delivery).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "agent_schedules" do
    belongs_to :workspace, Mokaid.Workspaces.Workspace
    belongs_to :agent, Mokaid.Agents.Agent
    belongs_to :created_by_member, Mokaid.Members.Member

    field :name, :string
    field :cron_expression, :string
    field :timezone, :string, default: "Etc/UTC"
    field :prompt, :string
    field :enabled, :boolean, default: true
    field :last_run_at, :utc_datetime_usec
    field :runs_count, :integer, default: 0
    field :max_runs, :integer
    field :expires_at, :utc_datetime_usec

    timestamps()
  end

  def changeset(schedule, attrs) do
    schedule
    |> cast(attrs, [
      :workspace_id,
      :agent_id,
      :name,
      :cron_expression,
      :timezone,
      :prompt,
      :enabled,
      :max_runs,
      :expires_at,
      :created_by_member_id
    ])
    |> validate_required([:workspace_id, :agent_id, :name, :cron_expression, :prompt])
    |> validate_length(:name, min: 1, max: 200)
    |> validate_length(:prompt, min: 1, max: 4000)
    |> validate_number(:max_runs, greater_than: 0)
    |> validate_cron()
  end

  def run_recorded_changeset(schedule, now) do
    change(schedule, last_run_at: now, runs_count: (schedule.runs_count || 0) + 1)
  end

  defp validate_cron(changeset) do
    case get_change(changeset, :cron_expression, :__absent__) do
      :__absent__ ->
        changeset

      expr when is_binary(expr) ->
        case Oban.Cron.Expression.parse(expr) do
          {:ok, _} -> changeset
          {:error, _} -> add_error(changeset, :cron_expression, "is not a valid cron expression")
        end

      _ ->
        add_error(changeset, :cron_expression, "is not a valid cron expression")
    end
  end
end
