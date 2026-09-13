defmodule MokaidWeb.ChannelAccess do
  @moduledoc """
  Revalidate already-joined topic scopes before the transport forwards traffic.

  Phoenix fastlane broadcasts bypass individual Channel callbacks. Checking only
  join/handle_out would leave those subscriptions usable after membership removal.
  Read identifiers in batches (at most one query per workspace/task/agent kind),
  not payload contents or stale member structs captured at join time.
  """
  import Ecto.Query
  alias Mokaid.{Repo, Members.Member, Tasks.Task, Agents.Agent}

  def allowed?(user_id, channels) when is_map(channels) do
    groups = %{"workspace" => [], "task" => [], "agent" => []}

    channels
    |> Map.keys()
    |> Enum.reduce_while(groups, fn topic, groups ->
      with true <- is_binary(topic),
           [kind, id] <- String.split(topic, ":", parts: 2),
           {:ok, id} <- Ecto.UUID.cast(id) do
        cond do
          kind == "notifications" and id == user_id -> {:cont, groups}
          Map.has_key?(groups, kind) -> {:cont, Map.update!(groups, kind, &[id | &1])}
          true -> {:halt, :denied}
        end
      else
        _ -> {:halt, :denied}
      end
    end)
    |> case do
      :denied ->
        false

      groups ->
        Enum.all?(groups, fn {kind, ids} -> authorized_ids?(kind, Enum.uniq(ids), user_id) end)
    end
  end

  def allowed?(_, _), do: false

  defp authorized_ids?(_, [], _), do: true

  defp authorized_ids?("workspace", ids, user_id) do
    query =
      from m in Member,
        where: m.workspace_id in ^ids and m.user_id == ^user_id and m.status == "active",
        select: m.workspace_id

    MapSet.new(Repo.all(query)) == MapSet.new(ids)
  end

  defp authorized_ids?("task", ids, user_id) do
    query =
      from t in Task,
        join: m in Member,
        on: m.workspace_id == t.workspace_id,
        where: t.id in ^ids and m.user_id == ^user_id and m.status == "active",
        select: t.id

    MapSet.new(Repo.all(query)) == MapSet.new(ids)
  end

  defp authorized_ids?("agent", ids, user_id) do
    query =
      from a in Agent,
        join: m in Member,
        on: m.workspace_id == a.workspace_id,
        where: a.id in ^ids and m.user_id == ^user_id and m.status == "active",
        select: a.id

    MapSet.new(Repo.all(query)) == MapSet.new(ids)
  end
end
