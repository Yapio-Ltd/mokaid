defmodule Mokaid.Office do
  @moduledoc """
  Synchronized social activities for idle agents in the 3D office.

  Ambient rule: most agents stay at their fixed desk seat. A global **away
  budget** caps how many may be on coffee / sofa / foosball at once so the
  room reads as a real office (majority seated), not a permanent break room.

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

  # At most this many agents may be away from their desk simultaneously
  # (coffee / sofa / foosball), so small teams never empty the floor.
  @max_away_absolute 2
  # Soft share of the roster that may be away (ceil). With absolute=2 this
  # keeps ≥75 % at desk for n ≥ 4.
  @max_away_ratio 0.25
  # Chance a tick tries to seat a foosball pair when budget allows two seats.
  @foosball_pair_chance 0.12

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

  @doc """
  Hard cap on concurrent POI agents for a roster of size `n`.

  Exposed for tests. `max_away = min(2, max(1, ceil(n * 0.25)))`.
  """
  def max_away(n) when is_integer(n) and n <= 0, do: 0

  def max_away(n) when is_integer(n) do
    min(@max_away_absolute, max(1, ceil(n * @max_away_ratio)))
  end

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

    roster_n =
      from(a in Agent,
        where: a.workspace_id == ^workspace_id and is_nil(a.archived_at),
        select: count(a.id)
      )
      |> Repo.one()

    currently_away =
      from(a in Agent,
        where:
          a.workspace_id == ^workspace_id and is_nil(a.archived_at) and
            not is_nil(a.office_activity),
        select: count(a.id)
      )
      |> Repo.one()

    budget = max(0, max_away(roster_n) - currently_away)

    if budget == 0 do
      :ok
    else
      idle =
        from(a in Agent,
          where:
            a.workspace_id == ^workspace_id and is_nil(a.archived_at) and
              a.status in ["idle", "active"] and is_nil(a.current_task_id) and
              is_nil(a.office_activity),
          order_by: [asc: a.inserted_at]
        )
        |> Repo.all()

      # Optional foosball duo only when two away seats remain in the budget.
      {idle, free_by_poi, budget} =
        if budget >= 2 and :rand.uniform() < @foosball_pair_chance do
          case maybe_fill_foosball(idle, free_by_poi) do
            {new_idle, new_free, :booked} -> {new_idle, new_free, budget - 2}
            {new_idle, new_free, :noop} -> {new_idle, new_free, budget}
          end
        else
          {idle, free_by_poi, budget}
        end

      candidates = Enum.take_random(idle, budget)

      Enum.reduce(candidates, free_by_poi, fn agent, free_map ->
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
  end

  defp maybe_fill_foosball(idle, free_map) do
    free = Map.get(free_map, "foosball", [])

    if length(idle) >= 2 and length(free) >= 2 do
      [a, b | rest] = Enum.shuffle(idle)
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

      {rest, Map.put(free_map, "foosball", leftover), :booked}
    else
      {idle, free_map, :noop}
    end
  end

  # Picking uniformly over free *slots* let the POI with the most seats win:
  # foosball and the sofa hold five of the six, so the coffee machine was
  # almost never chosen. Weight per POI instead, then pick a seat within it.
  @poi_weights %{"coffee" => 4, "sofa_main" => 3, "foosball" => 2}

  defp pick_poi(free_map) do
    available =
      free_map
      # Foosball needs two players. It is filled as a pair by
      # maybe_fill_foosball; letting the generic picker hand out a single seat
      # left one agent miming a match against an empty end of the table.
      |> Enum.reject(fn {poi_id, slots} -> slots == [] or poi_id == "foosball" end)
      |> Enum.flat_map(fn {poi_id, slots} ->
        List.duplicate({poi_id, slots}, Map.get(@poi_weights, poi_id, 1))
      end)

    case available do
      [] ->
        nil

      list ->
        {poi_id, slots} = Enum.random(list)
        slot = Enum.random(slots)
        {poi_id, slot, List.delete(slots, slot)}
    end
  end

  def pois, do: @pois

  def workspace_exists?(id), do: Repo.get(Workspace, id) != nil
end
