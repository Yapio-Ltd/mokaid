defmodule Mokaid.OfficeTest do
  use Mokaid.DataCase, async: true

  alias Mokaid.Agents
  alias Mokaid.Office

  test "tick assigns foosball to a pair of idle agents" do
    {workspace, _owner} = workspace_fixture()

    {:ok, a} = Agents.create_agent(workspace.id, %{"kind" => "ai", "display_name" => "A"})
    {:ok, b} = Agents.create_agent(workspace.id, %{"kind" => "ai", "display_name" => "B"})

    Office.tick_workspace(workspace.id)

    a2 = Agents.get_agent(workspace.id, a.id)
    b2 = Agents.get_agent(workspace.id, b.id)

    assert a2.office_activity == "playing_foosball"
    assert b2.office_activity == "playing_foosball"
    assert a2.office_poi_id == "foosball"
    assert b2.office_poi_id == "foosball"
    assert a2.office_slot_id != b2.office_slot_id
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
