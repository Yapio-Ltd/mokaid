defmodule Mokaid.Analytics do
  @moduledoc """
  Workspace analytics computed from PostgreSQL. High-volume event aggregation
  moves to ClickHouse via the export pipeline when volumes require it.
  """

  import Ecto.Query

  alias Mokaid.Agents.Agent
  alias Mokaid.Repo
  alias Mokaid.Tasks.Task

  def overview(workspace_id) do
    task_base = from t in Task, where: t.workspace_id == ^workspace_id

    total_tasks = Repo.aggregate(task_base, :count)
    completed = Repo.aggregate(where(task_base, [t], t.status == "completed"), :count)

    %{
      total_tasks: total_tasks,
      completed_tasks: completed,
      completion_rate:
        if(total_tasks > 0, do: Float.round(completed / total_tasks * 100, 1), else: 0.0),
      in_progress: Repo.aggregate(where(task_base, [t], t.status == "in_progress"), :count),
      overdue: Repo.aggregate(where(task_base, [t], t.status == "overdue"), :count),
      active_agents:
        Repo.aggregate(
          from(a in Agent,
            where: a.workspace_id == ^workspace_id and a.status in ["active", "busy"]
          ),
          :count
        ),
      avg_task_hours: avg_completion_hours(workspace_id)
    }
  end

  defp avg_completion_hours(workspace_id) do
    Repo.one(
      from t in Task,
        where:
          t.workspace_id == ^workspace_id and t.status == "completed" and
            not is_nil(t.started_at) and not is_nil(t.completed_at),
        select: avg(fragment("EXTRACT(EPOCH FROM (? - ?)) / 3600", t.completed_at, t.started_at))
    )
    |> case do
      nil -> 0.0
      decimal -> decimal |> Decimal.round(1) |> Decimal.to_float()
    end
  end

  def tasks_by_status(workspace_id) do
    Repo.all(
      from t in Task,
        where: t.workspace_id == ^workspace_id,
        group_by: t.status,
        select: %{status: t.status, count: count(t.id)}
    )
  end

  def tasks_by_priority(workspace_id) do
    Repo.all(
      from t in Task,
        where: t.workspace_id == ^workspace_id,
        group_by: t.priority,
        select: %{priority: t.priority, count: count(t.id)}
    )
  end

  def tasks_completed_daily(workspace_id, days \\ 14) do
    since = DateTime.add(DateTime.utc_now(), -days, :day)

    Repo.all(
      from t in Task,
        where:
          t.workspace_id == ^workspace_id and t.status == "completed" and
            t.completed_at >= ^since,
        group_by: fragment("date_trunc('day', ?)", t.completed_at),
        order_by: fragment("date_trunc('day', ?)", t.completed_at),
        select: %{day: fragment("date_trunc('day', ?)", t.completed_at), count: count(t.id)}
    )
  end

  def top_agents(workspace_id, limit \\ 5) do
    Repo.all(
      from a in Agent,
        left_join: t in Task,
        on: t.assigned_agent_id == a.id and t.status == "completed",
        where: a.workspace_id == ^workspace_id and is_nil(a.archived_at),
        group_by: a.id,
        order_by: [desc: count(t.id)],
        limit: ^limit,
        select: %{
          agent_id: a.id,
          display_name: a.display_name,
          role_title: a.role_title,
          kind: a.kind,
          performance_score: a.performance_score,
          tasks_done: count(t.id)
        }
    )
  end

  def agent_task_split(workspace_id) do
    Repo.all(
      from t in Task,
        join: a in Agent,
        on: a.id == t.assigned_agent_id,
        where: t.workspace_id == ^workspace_id and t.status == "completed",
        group_by: a.kind,
        select: %{kind: a.kind, count: count(t.id)}
    )
  end
end
