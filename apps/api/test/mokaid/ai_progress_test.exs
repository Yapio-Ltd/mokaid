defmodule Mokaid.AIProgressTest do
  use Mokaid.DataCase, async: true

  alias Mokaid.{AI, Agents, Notifications, Tasks}

  setup do
    {workspace, owner} = workspace_fixture()
    member = owner_member(workspace, owner)
    {:ok, agent} = Agents.create_agent(workspace.id, %{"kind" => "ai", "display_name" => "Alex"})

    {:ok, task} =
      Tasks.create_task(
        workspace.id,
        %{
          "title" => "Review the attached document",
          "status" => "in_progress",
          "assigned_agent_id" => agent.id
        },
        member
      )

    {:ok, run} = Tasks.create_execution_run(task)
    {:ok, run} = Tasks.update_run_progress(run, %{"status" => "running"})
    {:ok, agent} = Agents.change_status(agent, "busy", current_task_id: task.id)
    %{workspace: workspace, owner: owner, member: member, agent: agent, task: task, run: run}
  end

  test "input requests persist a scoped, actionable notification and update presence only once",
       context do
    %{workspace: workspace, owner: owner, agent: agent, task: task, run: run} = context
    question = "Export a readable PDF copy of source.custom, then relaunch this mission."
    attrs = %{"status" => "waiting_for_user_input", "question" => question}

    assert {:ok, updated} = AI.handle_progress(run.id, attrs)
    assert updated.status == "waiting_for_user_input"
    assert Tasks.get_task(workspace.id, task.id).status == "waiting"
    assert Agents.get_agent(workspace.id, agent.id).status == "waiting"
    assert {:ok, _} = AI.handle_progress(run.id, attrs)

    assert [notification] = Notifications.list_for_user(workspace.id, owner.id)
    assert notification.kind == "ai_run_needs_input"
    assert notification.resource_type == "task"
    assert notification.resource_id == task.id
    assert notification.body == question
    assert notification.resource_status == "waiting"

    {other_workspace, _} = workspace_fixture(owner)
    assert Notifications.list_for_user(other_workspace.id, owner.id) == []
  end

  test "running resumes task and employee presence; a new pause can notify again", context do
    %{workspace: workspace, owner: owner, agent: agent, task: task, run: run} = context
    assert {:ok, _} = AI.handle_progress(run.id, %{"status" => "waiting_for_user_input"})
    assert {:ok, _} = AI.handle_progress(run.id, %{"status" => "running"})
    assert Tasks.get_task(workspace.id, task.id).status == "in_progress"
    assert Agents.get_agent(workspace.id, agent.id).status == "busy"

    assert {:ok, _} =
             AI.handle_progress(run.id, %{
               "status" => "waiting_for_user_input",
               "question" => "One more file is required."
             })

    assert length(Notifications.list_for_user(workspace.id, owner.id)) == 2
  end

  test "delayed input requests cannot reopen a finished run", context do
    %{workspace: workspace, owner: owner, agent: agent, task: task, run: run} = context
    {:ok, _} = Tasks.update_run_progress(run, %{"status" => "completed"})
    {:ok, _} = Tasks.update_task(task, %{"status" => "completed"})
    {:ok, _} = Agents.change_status(agent, "idle", current_task_id: nil)

    assert {:ok, %{status: "completed"}} =
             AI.handle_progress(run.id, %{"status" => "waiting_for_user_input"})

    assert Tasks.get_task(workspace.id, task.id).status == "completed"
    assert Agents.get_agent(workspace.id, agent.id).status == "idle"
    assert Notifications.list_for_user(workspace.id, owner.id) == []
  end

  test "waiting for input releases the employee queue without losing the pending question",
       context do
    %{workspace: workspace, member: member, agent: agent, run: run, task: task} = context

    {:ok, next_task} =
      Tasks.create_task(
        workspace.id,
        %{
          "title" => "Summarize a memo",
          "assigned_agent_id" => agent.id
        },
        member
      )

    {:ok, next_run} = AI.start_run(next_task)
    assert Tasks.get_run(next_run.id).dispatched_at == nil

    assert {:ok, _} =
             AI.handle_progress(run.id, %{
               "status" => "waiting_for_user_input",
               "question" => "Upload a PDF copy."
             })

    assert Tasks.get_run(next_run.id).dispatched_at != nil
    assert Agents.get_agent(workspace.id, agent.id).current_task_id == next_task.id
    assert Tasks.get_task(workspace.id, task.id).status == "waiting"

    assert {:ok, _} = AI.handle_progress(run.id, %{"status" => "waiting_for_user_input"})
    assert Agents.get_agent(workspace.id, agent.id).status == "busy"
    assert Agents.get_agent(workspace.id, agent.id).current_task_id == next_task.id
  end
end
