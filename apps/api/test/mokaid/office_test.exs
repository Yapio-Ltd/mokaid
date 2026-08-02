defmodule Mokaid.OfficeTest do
  use Mokaid.DataCase, async: true

  alias Mokaid.Agents
  alias Mokaid.Billing
  alias Mokaid.Office

  setup do
    Billing.seed_plans()
    :ok
  end

  test "tick only sends some idle agents off to a POI" do
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

    # Most agents stay at their desk on any given tick; the office should not
    # empty out into the break area the moment everyone is free.
    # Some agents must stay behind; the room should not empty in one tick.
    assert length(assigned) < limit or limit <= 1

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

  test "foosball is booked as a pair when it is booked at all" do
    {workspace, _owner} = workspace_fixture()
    assert {:ok, _} = Billing.change_plan(workspace.id, "starter")

    for i <- 1..2 do
      {:ok, _} = Agents.create_agent(workspace.id, %{"kind" => "ai", "display_name" => "P#{i}"})
    end

    # The pairing is probabilistic, so drive several ticks and assert the
    # invariant that matters: the table never ends up with a lone player.
    for _ <- 1..40 do
      Office.tick_workspace(workspace.id)

      players =
        workspace.id
        |> Agents.list_agents()
        |> Enum.filter(&(&1.office_poi_id == "foosball"))

      assert length(players) != 1, "foosball had a single player: #{inspect(players)}"

      for p <- players, do: {:ok, _} = Agents.clear_office_activity(p)
    end
  end

  test "tick expires finished activities then may reassign" do
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
  end
end
