defmodule Mokaid.AI.Schedules do
  @moduledoc """
  CRUD + due-detection for agent automations (`agent_schedules`).

  Timezones: no IANA tz database is bundled, so `timezone` is either
  "Etc/UTC" or a fixed offset like "+02:00" / "-05:30". Anything else
  falls back to UTC.
  """

  import Ecto.Query

  alias Mokaid.AI.Schedule
  alias Mokaid.Realtime
  alias Mokaid.Repo

  def list_schedules(workspace_id, agent_id) do
    Repo.all(
      from s in Schedule,
        where: s.workspace_id == ^workspace_id and s.agent_id == ^agent_id,
        order_by: [asc: s.inserted_at]
    )
  end

  def get_schedule(workspace_id, id) do
    Repo.one(from s in Schedule, where: s.workspace_id == ^workspace_id and s.id == ^id)
  end

  def create_schedule(workspace_id, agent_id, attrs, member \\ nil) do
    result =
      %Schedule{}
      |> Schedule.changeset(
        Map.merge(stringify(attrs), %{
          "workspace_id" => workspace_id,
          "agent_id" => agent_id,
          "created_by_member_id" => member && member.id
        })
      )
      |> Repo.insert()

    with {:ok, schedule} <- result do
      Realtime.broadcast_workspace(workspace_id, "agent.updated", %{agent_id: agent_id})
      {:ok, schedule}
    end
  end

  def update_schedule(%Schedule{} = schedule, attrs) do
    result =
      schedule
      |> Schedule.changeset(
        Map.merge(stringify(attrs), %{"workspace_id" => schedule.workspace_id})
      )
      |> Repo.update()

    with {:ok, updated} <- result do
      Realtime.broadcast_workspace(schedule.workspace_id, "agent.updated", %{
        agent_id: schedule.agent_id
      })

      {:ok, updated}
    end
  end

  def delete_schedule(%Schedule{} = schedule) do
    with {:ok, deleted} <- Repo.delete(schedule) do
      Realtime.broadcast_workspace(schedule.workspace_id, "agent.updated", %{
        agent_id: schedule.agent_id
      })

      {:ok, deleted}
    end
  end

  @doc """
  Enabled, unexpired schedules whose cron matches the current minute in
  their timezone and that did not already fire this minute.
  """
  def due_schedules(now \\ DateTime.utc_now()) do
    minute_start = %{now | second: 0, microsecond: {0, 6}}

    Repo.all(
      from s in Schedule,
        where: s.enabled == true,
        where: is_nil(s.expires_at) or s.expires_at > ^now,
        where: is_nil(s.max_runs) or s.runs_count < s.max_runs,
        where: is_nil(s.last_run_at) or s.last_run_at < ^minute_start
    )
    |> Enum.filter(&due?(&1, now))
  end

  def due?(%Schedule{} = schedule, now) do
    case Oban.Cron.Expression.parse(schedule.cron_expression) do
      {:ok, cron} -> Oban.Cron.Expression.now?(cron, local_time(now, schedule.timezone))
      {:error, _} -> false
    end
  end

  def record_run(%Schedule{} = schedule, now \\ DateTime.utc_now()) do
    schedule
    |> Schedule.run_recorded_changeset(now)
    |> Repo.update()
  end

  # Fixed-offset timezone support ("+02:00", "-05:30", "UTC", "Etc/UTC").
  defp local_time(now, timezone) do
    case offset_minutes(timezone) do
      0 -> now
      minutes -> DateTime.add(now, minutes * 60, :second)
    end
  end

  defp offset_minutes(nil), do: 0
  defp offset_minutes("UTC"), do: 0
  defp offset_minutes("Etc/UTC"), do: 0

  defp offset_minutes(timezone) when is_binary(timezone) do
    case Regex.run(~r/^(?:UTC)?([+-])(\d{1,2})(?::(\d{2}))?$/, String.trim(timezone)) do
      [_, sign, hours, minutes] ->
        total = String.to_integer(hours) * 60 + String.to_integer(minutes)
        if sign == "-", do: -total, else: total

      [_, sign, hours] ->
        total = String.to_integer(hours) * 60
        if sign == "-", do: -total, else: total

      _ ->
        0
    end
  end

  defp stringify(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
