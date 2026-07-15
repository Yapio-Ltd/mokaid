defmodule Mokaid.Office do
  @moduledoc """
  Synchronized social activities for idle agents in the 3D office.

  POI capacities:
  - foosball: 2
  - sofa_main: 3
  - coffee: 1 (+ queue is client-side only; server only books active slots)
  """

  import Ecto.Query

  alias Mokaid.Agents
  alias Mokaid.Agents.Agent
  alias Mokaid.Repo
  alias Mokaid.Workspaces.Workspace

  @pois %{
    "foosball" => %{
      activity: "playing_foosball",
      slots: ["foosball_a", "foosball_b"],
      duration_sec: 45..75
    },
    "sofa_main" => %{
      activity: "sitting_sofa",
      slots: ["sofa_a", "sofa_b", "sofa_c"],
      duration_sec: 40..90
    },
    "coffee" => %{
      activity: "preparing_coffee",
      slots: ["coffee_active"],
      duration_sec: 25..40
    }
  }

  @doc "Expire elapsed activities and assign idle agents to free POI slots."
  def tick_all_workspaces do
    workspace_ids =
      from(a in Agent,
        where: is_nil(a.archived_at),
        distinct: true,
        select: a.workspace_id
      )
      |> Repo.all()

    Enum.each(workspace_ids, &tick_workspace/1)
    :ok
  end

  def tick_workspace(workspace_id) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1::text))", [
        "office:" <> to_string(workspace_id)
      ])

      expire_finished(workspace_id)
      assign_idle_agents(workspace_id)
    end)

    :ok
  end

  defp expire_finished(workspace_id) do
    now = DateTime.utc_now()

    from(a in Agent,
      where:
        a.workspace_id == ^workspace_id and is_nil(a.archived_at) and
          not is_nil(a.office_activity_ends_at) and a.office_activity_ends_at <= ^now
    )
    |> Repo.all()
    |> Enum.each(fn agent ->
      Agents.clear_office_activity(agent)
    end)
  end

  defp assign_idle_agents(workspace_id) do
    free_by_poi =
      Enum.into(@pois, %{}, fn {poi_id, meta} ->
        taken =
          from(a in Agent,
            where:
              a.workspace_id == ^workspace_id and is_nil(a.archived_at) and
                a.office_poi_id == ^poi_id and not is_nil(a.office_slot_id),
            select: a.office_slot_id
          )
          |> Repo.all()
          |> MapSet.new()

        free = Enum.reject(meta.slots, &MapSet.member?(taken, &1))
        {poi_id, free}
      end)

    idle =
      from(a in Agent,
        where:
          a.workspace_id == ^workspace_id and is_nil(a.archived_at) and
            a.status in ["idle", "active"] and is_nil(a.current_task_id) and
            is_nil(a.office_activity),
        order_by: [asc: a.inserted_at]
      )
      |> Repo.all()

    # Prefer filling foosball with pairs when 2+ idle agents exist.
    {idle, free_by_poi} = maybe_fill_foosball(idle, free_by_poi)

    Enum.reduce(idle, free_by_poi, fn agent, free_map ->
      case pick_poi(free_map) do
        nil ->
          free_map

        {poi_id, slot_id, rest_free} ->
          meta = Map.fetch!(@pois, poi_id)
          ends = DateTime.add(DateTime.utc_now(), Enum.random(meta.duration_sec), :second)

          Agents.set_office_activity(agent, %{
            "office_activity" => meta.activity,
            "office_poi_id" => poi_id,
            "office_slot_id" => slot_id,
            "office_activity_phase" => "approaching",
            "office_activity_ends_at" => ends
          })

          Map.put(free_map, poi_id, rest_free)
      end
    end)

    :ok
  end

  defp maybe_fill_foosball(idle, free_map) do
    free = Map.get(free_map, "foosball", [])

    if length(idle) >= 2 and length(free) >= 2 do
      [a, b | rest] = idle
      [s1, s2 | leftover] = free
      meta = Map.fetch!(@pois, "foosball")
      ends = DateTime.add(DateTime.utc_now(), Enum.random(meta.duration_sec), :second)

      Enum.each([{a, s1}, {b, s2}], fn {agent, slot} ->
        Agents.set_office_activity(agent, %{
          "office_activity" => meta.activity,
          "office_poi_id" => "foosball",
          "office_slot_id" => slot,
          "office_activity_phase" => "approaching",
          "office_activity_ends_at" => ends
        })
      end)

      {rest, Map.put(free_map, "foosball", leftover)}
    else
      {idle, free_map}
    end
  end

  defp pick_poi(free_map) do
    candidates =
      free_map
      |> Enum.flat_map(fn {poi_id, slots} ->
        Enum.map(slots, fn slot -> {poi_id, slot, List.delete(slots, slot)} end)
      end)

    case candidates do
      [] -> nil
      list -> Enum.random(list)
    end
  end

  def pois, do: @pois

  def workspace_exists?(id), do: Repo.get(Workspace, id) != nil
end
