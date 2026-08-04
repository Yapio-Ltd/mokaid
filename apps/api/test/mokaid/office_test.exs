defmodule Mokaid.OfficeTest do
  use Mokaid.DataCase, async: true

  alias Mokaid.Agents
  alias Mokaid.Billing
  alias Mokaid.Office

  setup do
    Billing.seed_plans()
    :ok
  end

  test "max_away keeps a seated majority" do
    assert Office.max_away(0) == 0
    assert Office.max_away(1) == 1
    assert Office.max_away(2) == 1
    assert Office.max_away(3) == 1
    assert Office.max_away(4) == 1
    assert Office.max_away(5) == 2
    assert Office.max_away(8) == 2
    assert Office.max_away(9) == 2
  end

  test "tick only sends a capped number of idle agents off to a POI" do
    {workspace, _owner} = workspace_fixture()
    assert {:ok, _} = Billing.change_plan(workspace.id, "starter")

    # Fill the workspace up to whatever its plan allows rather than assuming a
    # fixed headcount — the starter limit is billing's to decide, not ours.
    limit = min(Billing.agent_limit(workspace.id), 6)

    agents =
      for i <- 1..limit do
        {:ok, a} =
          Agents.create_agent(workspace.id, %{"kind" => "ai", "display_name" => "A#{i}"})

        a
      end

    Office.tick_workspace(workspace.id)

    assigned =
      agents
      |> Enum.map(&Agents.get_agent(workspace.id, &1.id))
      |> Enum.filter(& &1.office_activity)

    cap = Office.max_away(limit)
    assert length(assigned) <= cap

    # Whatever was assigned must be internally consistent.
    for a <- assigned do
      meta = Map.fetch!(Office.pois(), a.office_poi_id)
      assert a.office_activity == meta.activity
      assert a.office_slot_id in meta.slots
      assert a.office_activity_phase == "approaching"
      assert DateTime.compare(a.office_activity_ends_at, DateTime.utc_now()) == :gt
    end

    # No two agents may hold the same seat.
    slots = Enum.map(assigned, & &1.office_slot_id)
    assert length(Enum.uniq(slots)) == length(slots)
  end

  test "multi-tick never exceeds the concurrent away cap" do
    {workspace, _owner} = workspace_fixture()
    assert {:ok, _} = Billing.change_plan(workspace.id, "starter")

    limit = min(Billing.agent_limit(workspace.id), 6)
    cap = Office.max_away(limit)

    for i <- 1..limit do
      {:ok, _} =
        Agents.create_agent(workspace.id, %{"kind" => "ai", "display_name" => "M#{i}"})
    end

    for _ <- 1..30 do
      Office.tick_workspace(workspace.id)

      away =
        workspace.id
        |> Agents.list_agents()
        |> Enum.count(&(&1.office_activity != nil))

      assert away <= cap, "away=#{away} exceeded cap=#{cap}"

      # Cycle activities so slots free without waiting for wall-clock expiry,
      # exercising reassignment under the same hard ceiling.
      workspace.id
      |> Agents.list_agents()
      |> Enum.filter(& &1.office_activity)
      |> Enum.each(fn a -> {:ok, _} = Agents.clear_office_activity(a) end)
    end
  end

  test "foosball is booked as a pair when it is booked at all and stays under cap" do
    {workspace, _owner} = workspace_fixture()
    # Need roster ≥ 5 so max_away ≥ 2 (ceil(n*0.25) ≥ 2) for a foosball pair.
    assert {:ok, _} = Billing.change_plan(workspace.id, "professional")

    for i <- 1..5 do
      {:ok, _} = Agents.create_agent(workspace.id, %{"kind" => "ai", "display_name" => "P#{i}"})
    end

    cap = Office.max_away(5)

    for _ <- 1..50 do
      Office.tick_workspace(workspace.id)

      agents = Agents.list_agents(workspace.id)
      players = Enum.filter(agents, &(&1.office_poi_id == "foosball"))
      away = Enum.count(agents, &(&1.office_activity != nil))

      assert length(players) != 1, "foosball had a single player: #{inspect(players)}"
      assert away <= cap

      for p <- Enum.filter(agents, & &1.office_activity), do: {:ok, _} = Agents.clear_office_activity(p)
    end
  end

  test "tick expires finished activities then may reassign under the cap" do
    {workspace, _owner} = workspace_fixture()

    {:ok, agent} = Agents.create_agent(workspace.id, %{"kind" => "ai", "display_name" => "C"})

    past = DateTime.add(DateTime.utc_now(), -5, :second)

    {:ok, _} =
      Agents.set_office_activity(agent, %{
        "office_activity" => "preparing_coffee",
        "office_poi_id" => "coffee",
        "office_slot_id" => "coffee_active",
        "office_activity_phase" => "active",
        "office_activity_ends_at" => past
      })

    Office.tick_workspace(workspace.id)
    again = Agents.get_agent(workspace.id, agent.id)

    # Expired activity is cleared; idle agents may receive a fresh POI assignment.
    assert again.office_activity_ends_at == nil or
             DateTime.compare(again.office_activity_ends_at, DateTime.utc_now()) == :gt

    if again.office_activity_ends_at do
      refute DateTime.compare(again.office_activity_ends_at, past) == :eq
    end

    away =
      workspace.id
      |> Agents.list_agents()
      |> Enum.count(&(&1.office_activity != nil))

    assert away <= Office.max_away(1)
  end
end
