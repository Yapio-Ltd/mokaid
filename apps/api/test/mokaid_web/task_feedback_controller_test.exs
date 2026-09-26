defmodule MokaidWeb.TaskFeedbackControllerTest do
  use MokaidWeb.ConnCase, async: true

  alias Mokaid.{AI, Agents, Members, Tasks}

  setup %{conn: conn} do
    {workspace, user} = workspace_fixture()
    member = owner_member(workspace, user)
    {:ok, agent} = Agents.create_agent(workspace.id, %{"kind" => "ai", "display_name" => "Alex"})

    {:ok, task} =
      Tasks.create_task(
        workspace.id,
        %{
          "title" => "Research search visibility",
          "description" => "Keep the original task brief",
          "assigned_agent_id" => agent.id,
          "status" => "in_review"
        },
        member
      )

    {:ok, run} =
      Tasks.create_execution_run(task, %{
        "instruction" => "Research the requested website",
        "chat_task" => true,
        "drive_item_ids" => []
      })

    {:ok, run} =
      Tasks.update_run_progress(run, %{
        "status" => "completed",
        "output" => %{"summary" => "The previous answer", "artifacts" => []}
      })

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> Mokaid.Auth.Token.sign(user.id))
      |> put_req_header("x-workspace-id", workspace.id)

    %{conn: conn, workspace: workspace, member: member, agent: agent, task: task, run: run}
  end

  test "positive feedback accepts the response without starting another run", context do
    %{conn: conn, task: task, run: run, workspace: workspace, member: member} = context

    response =
      conn
      |> post("/api/tasks/#{task.id}/feedback", %{rating: "good", run_id: run.id})
      |> json_response(200)

    assert response["data"]["status"] == "completed"
    assert response["data"]["response_feedback"]["rating"] == "good"
    assert response["data"]["response_feedback"]["run_id"] == run.id
    assert response["data"]["response_feedback"]["submitted_by_member_id"] == member.id
    assert response["meta"]["run_id"] == nil
    assert length(Tasks.list_runs_for_task(workspace.id, task.id)) == 1
  end

  test "improvement resumes the same task with the prompt and previous answer", context do
    %{conn: conn, task: task, run: run, workspace: workspace} = context

    response =
      conn
      |> post("/api/tasks/#{task.id}/feedback", %{
        rating: "needs_improvement",
        run_id: run.id,
        prompt: "  Add precise sources and finish the report.  "
      })
      |> json_response(200)

    assert response["data"]["id"] == task.id
    assert response["data"]["status"] == "in_progress"
    assert response["data"]["description"] == task.description
    assert response["data"]["response_feedback"]["rating"] == "needs_improvement"
    assert response["data"]["response_feedback"]["run_id"] == run.id

    assert response["data"]["response_feedback"]["prompt"] ==
             "Add precise sources and finish the report."

    next_run = Tasks.get_run(response["meta"]["run_id"])
    assert next_run.task_id == task.id
    assert next_run.id != run.id
    assert next_run.input["continuation_of_run_id"] == run.id
    assert next_run.input["previous_output"] == run.output
    assert next_run.input["chat_task"] == true
    assert next_run.input["original_instruction"] == "Research the requested website"
    assert next_run.input["instruction"] =~ "Add precise sources and finish the report."
    assert next_run.input["instruction"] =~ "Research the requested website"
    assert List.last(next_run.input["conversation"])["body"] == next_run.input["feedback"]

    updated = Tasks.get_task(workspace.id, task.id)
    assert Enum.any?(updated.comments, &(&1.body == next_run.input["feedback"]))
    assert length(updated.execution_runs) == 2
  end

  test "a blank correction is rejected before changing the task", context do
    %{conn: conn, task: task, run: run, workspace: workspace} = context

    response =
      conn
      |> post("/api/tasks/#{task.id}/feedback", %{
        rating: "needs_improvement",
        run_id: run.id,
        prompt: "  \n "
      })
      |> json_response(422)

    assert response["error"]["code"] == "feedback_prompt_required"
    assert Tasks.get_task(workspace.id, task.id).status == "in_review"
    assert length(Tasks.list_runs_for_task(workspace.id, task.id)) == 1
  end

  test "stale feedback cannot accept a newer answer", context do
    %{conn: conn, task: task, run: run, workspace: workspace} = context
    {:ok, newer_run} = Tasks.create_execution_run(task)
    {:ok, _} = Tasks.update_run_progress(newer_run, %{"status" => "completed"})

    response =
      conn
      |> post("/api/tasks/#{task.id}/feedback", %{rating: "good", run_id: run.id})
      |> json_response(422)

    assert response["error"]["code"] == "stale_response_feedback"
    assert Tasks.get_task(workspace.id, task.id).status == "in_review"
  end

  test "positive feedback cannot replace a pending action decision", context do
    %{conn: conn, task: task, run: run, workspace: workspace} = context
    {:ok, _} = Tasks.update_run_progress(run, %{"status" => "waiting_for_approval"})

    {:ok, approval} =
      Tasks.create_approval_request(run, %{
        "tool_name" => "send_email",
        "risk_level" => "high",
        "proposed_action" => "An old proposed email"
      })

    response =
      conn
      |> post("/api/tasks/#{task.id}/feedback", %{rating: "good", run_id: run.id})
      |> json_response(422)

    assert response["error"]["code"] == "no_response_to_review"
    assert Tasks.get_run(run.id).status == "waiting_for_approval"
    assert Tasks.get_approval_request(workspace.id, approval.id).status == "pending"
    assert length(Tasks.list_runs_for_task(workspace.id, task.id)) == 1
  end

  test "a paused legacy run can be replaced by a prompted continuation", context do
    %{conn: conn, task: task, run: run, workspace: workspace} = context
    {:ok, _} = Tasks.update_run_progress(run, %{"status" => "waiting_for_approval"})

    response =
      conn
      |> post("/api/tasks/#{task.id}/feedback", %{
        rating: "needs_improvement",
        run_id: run.id,
        prompt: "Finish the PDF and explain the findings."
      })
      |> json_response(200)

    assert Tasks.get_run(run.id).status == "canceled"
    assert response["data"]["latest_run"]["id"] == response["meta"]["run_id"]
    assert Tasks.get_task(workspace.id, task.id).status == "in_progress"
    assert length(Tasks.list_runs_for_task(workspace.id, task.id)) == 2
  end

  test "viewers cannot submit feedback or start a continuation", context do
    %{conn: conn, workspace: workspace, member: member, task: task, run: run} = context
    viewer = Members.get_role_by_name(workspace.id, "Viewer")
    member |> Ecto.Changeset.change(role_id: viewer.id) |> Repo.update!()

    assert conn
           |> post("/api/tasks/#{task.id}/feedback", %{rating: "good", run_id: run.id})
           |> json_response(403)

    assert Tasks.get_task(workspace.id, task.id).status == "in_review"
  end

  test "text-only answers become ready for response feedback", context do
    %{workspace: workspace, task: task, run: run} = context
    {:ok, _} = Tasks.update_task(task, %{"status" => "waiting"})

    assert {:ok, _} =
             AI.handle_completion(run.id, %{"summary" => "A useful answer", "artifacts" => []})

    assert Tasks.get_task(workspace.id, task.id).status == "in_review"
  end

  test "feedback does not interrupt the agent's next active mission", context do
    %{conn: conn, workspace: workspace, task: task, run: run, member: member, agent: agent} =
      context

    {:ok, next_task} =
      Tasks.create_task(
        workspace.id,
        %{"title" => "Next mission", "assigned_agent_id" => agent.id},
        member
      )

    {:ok, next_run} = Tasks.create_execution_run(next_task)
    {:ok, _} = Tasks.update_run_progress(next_run, %{"status" => "running"})
    {:ok, _} = Agents.change_status(agent, "busy", current_task_id: next_task.id)

    assert conn
           |> post("/api/tasks/#{task.id}/feedback", %{rating: "good", run_id: run.id})
           |> json_response(200)

    assert Agents.get_agent(workspace.id, agent.id).current_task_id == next_task.id
    assert Agents.get_agent(workspace.id, agent.id).status == "busy"

    {:ok, _} = Tasks.update_run_progress(run, %{"status" => "waiting_for_user_input"})

    assert conn
           |> post("/api/tasks/#{task.id}/feedback", %{
             rating: "needs_improvement",
             run_id: run.id,
             prompt: "Use the new details."
           })
           |> json_response(200)

    assert Agents.get_agent(workspace.id, agent.id).current_task_id == next_task.id
    assert Agents.get_agent(workspace.id, agent.id).status == "busy"
    assert Tasks.get_run(next_run.id).status == "running"
  end
end
