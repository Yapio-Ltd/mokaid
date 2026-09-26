defmodule MokaidWeb.TaskControllerTest do
  use MokaidWeb.ConnCase, async: true

  alias Mokaid.{Agents, Members, Tasks}

  setup %{conn: conn} do
    {workspace, user} = workspace_fixture()
    member = owner_member(workspace, user)

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> Mokaid.Auth.Token.sign(user.id))
      |> put_req_header("x-workspace-id", workspace.id)

    {:ok, conn: conn, workspace: workspace, member: member}
  end

  test "board receives current member, update capability and the assigned agent's actual portrait",
       %{
         conn: conn,
         workspace: workspace,
         member: member
       } do
    {:ok, agent} =
      Agents.create_agent(workspace.id, %{
        "kind" => "ai",
        "display_name" => "Assigned designer",
        "avatar_config" => %{"preset" => "design"}
      })

    {:ok, task} =
      Tasks.create_task(
        workspace.id,
        %{
          "title" => "Review the design",
          "assigned_agent_id" => agent.id,
          "assigned_member_id" => member.id
        },
        member
      )

    response = conn |> get("/api/tasks") |> json_response(200)
    assert response["meta"]["current_member_id"] == member.id
    assert response["meta"]["can_update"] == true
    assert [record] = response["data"]
    assert record["id"] == task.id
    assert record["created_by_member_id"] == member.id
    assert record["assigned_member_id"] == member.id
    assert record["assigned_agent_avatar_config"] == agent.avatar_config
  end

  test "status-only moves retain the task brief and relationships", %{
    conn: conn,
    workspace: workspace,
    member: member
  } do
    {:ok, task} =
      Tasks.create_task(
        workspace.id,
        %{
          "title" => "Original title",
          "description" => "Keep the full original brief",
          "assigned_member_id" => member.id,
          "priority" => "high"
        },
        member
      )

    response =
      conn |> patch("/api/tasks/#{task.id}", %{status: "in_review"}) |> json_response(200)

    assert response["data"]["status"] == "in_review"
    updated = Tasks.get_task(workspace.id, task.id)
    assert updated.title == task.title
    assert updated.description == task.description
    assert updated.assigned_member_id == member.id
    assert updated.priority == "high"
  end

  test "viewers receive read-only capability and cannot move tasks", %{
    conn: conn,
    workspace: workspace,
    member: member
  } do
    {:ok, task} = Tasks.create_task(workspace.id, %{"title" => "Read-only task"}, member)
    viewer = Members.get_role_by_name(workspace.id, "Viewer")
    member |> Ecto.Changeset.change(role_id: viewer.id) |> Repo.update!()

    response = conn |> get("/api/tasks") |> json_response(200)
    assert response["meta"]["current_member_id"] == member.id
    assert response["meta"]["can_update"] == false
    assert conn |> patch("/api/tasks/#{task.id}", %{status: "completed"}) |> json_response(403)
    assert Tasks.get_task(workspace.id, task.id).status == "to_do"
  end
end
