defmodule Mokaid.TeamActivityTest do
  use Mokaid.DataCase, async: true

  alias Mokaid.Tasks

  test "stale contributor callbacks preserve each other's events and tool completion" do
    {workspace, _owner} = workspace_fixture()
    {:ok, task} = Tasks.create_task(workspace.id, %{"title" => "Team research"})
    {:ok, initial_snapshot} = Tasks.create_execution_run(task)

    assert {:ok, _} =
             Tasks.append_run_activity(initial_snapshot, %{
               "id" => "search-1",
               "agent_id" => "researcher",
               "status" => "running"
             })

    # The second HTTP callback has already fetched the same earlier run.
    assert {:ok, _} =
             Tasks.append_run_activity(initial_snapshot, %{
               "id" => "analysis-1",
               "agent_id" => "analyst",
               "status" => "running"
             })

    assert {:ok, _} =
             Tasks.append_run_activity(initial_snapshot, %{
               "id" => "search-1",
               "status" => "ok",
               "duration_ms" => 15
             })

    activity = Tasks.get_run(initial_snapshot.id).tool_activity
    assert length(activity) == 2

    assert Enum.find(activity, &(&1["id"] == "search-1")) == %{
             "id" => "search-1",
             "agent_id" => "researcher",
             "status" => "ok",
             "duration_ms" => 15
           }

    assert Enum.find(activity, &(&1["id"] == "analysis-1"))["agent_id"] == "analyst"
  end
end
