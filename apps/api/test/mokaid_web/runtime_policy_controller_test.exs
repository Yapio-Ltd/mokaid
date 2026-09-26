defmodule MokaidWeb.RuntimePolicyControllerTest do
  use MokaidWeb.ConnCase, async: true
  alias Mokaid.{Members, Workspaces}

  setup %{conn: conn} do
    {workspace, user} = workspace_fixture()

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> Mokaid.Auth.Token.sign(user.id))
      |> put_req_header("x-workspace-id", workspace.id)

    %{conn: conn, workspace: workspace, user: user}
  end

  test "only explicit admin consent enables execution and no supplier prices leak", c do
    response = get(c.conn, "/api/ai/runtime-policy") |> json_response(200)
    assert response["data"]["enabled"] == false
    assert response["meta"]["can_update"] == true
    refute Map.has_key?(response["data"], "budget_cents_standard")
    assert patch(c.conn, "/api/ai/runtime-policy", %{enabled: true}) |> json_response(422)

    response =
      patch(c.conn, "/api/ai/runtime-policy", %{enabled: true, data_policy_accepted: true})
      |> json_response(200)

    assert response["data"]["enabled"] == true
    assert response["meta"]["can_update"] == true
    assert response["data"]["standard_credits"] == 500
    policy = Workspaces.get_workspace(c.workspace.id).managed_runtime_policy
    assert policy["accepted_by_member_id"]
    assert policy["policy_version"] == "managed-us-v1"
  end

  test "workspace generic mass assignment cannot activate runtime", c do
    Workspaces.update_workspace(c.workspace, %{
      "managed_runtime_policy" => %{"enabled" => true, "data_policy_accepted" => true}
    })

    assert Workspaces.get_workspace(c.workspace.id).managed_runtime_policy == %{}
    {other, _} = workspace_fixture()

    assert patch(c.conn, "/api/workspaces/#{other.id}/runtime-settings", %{
             enabled: true,
             data_policy_accepted: true
           })
           |> json_response(403)
  end

  test "viewer reads policy but cannot activate it", c do
    user = user_fixture()
    role = Repo.get_by!(Members.Role, name: "Viewer")

    %Members.Member{}
    |> Members.Member.changeset(%{
      "workspace_id" => c.workspace.id,
      "user_id" => user.id,
      "role_id" => role.id
    })
    |> Repo.insert!()

    conn = c.conn |> put_req_header("authorization", "Bearer " <> Mokaid.Auth.Token.sign(user.id))
    response = get(conn, "/api/ai/runtime-policy") |> json_response(200)
    assert response["meta"]["can_update"] == false

    assert patch(conn, "/api/ai/runtime-policy", %{enabled: true, data_policy_accepted: true})
           |> json_response(403)
  end

  test "worker callbacks require authentication and an explicit workspace", c do
    path = "/api/worker/runs/#{Ecto.UUID.generate()}/runtime/reserve"
    assert post(c.conn, path, %{}) |> json_response(401)
    worker = build_conn() |> put_req_header("authorization", "Bearer test-token")
    assert post(worker, path, %{}) |> json_response(422)
    assert post(worker, path, %{workspace_id: c.workspace.id}) |> json_response(404)
  end

  test "authenticated budget extension returns a stable credit receipt without supplier pricing",
       c do
    member = owner_member(c.workspace, c.user)

    {:ok, agent} =
      Mokaid.Agents.create_agent(c.workspace.id, %{"kind" => "ai", "display_name" => "Lead"})

    {:ok, task} =
      Mokaid.Tasks.create_task(
        c.workspace.id,
        %{"title" => "Research", "assigned_agent_id" => agent.id, "status" => "in_progress"},
        member
      )

    {:ok, run} = Mokaid.Tasks.create_execution_run(task, %{})

    Repo.insert!(%Mokaid.Billing.Subscription{
      workspace_id: c.workspace.id,
      monthly_credits: 2000,
      included_credits_remaining: 2000
    })

    Mokaid.AI.RuntimePolicy.update(c.workspace.id, member, %{
      "enabled" => true,
      "data_policy_accepted" => true
    })

    Mokaid.AI.ManagedRuntime.reserve(c.workspace.id, run.id, %{})

    Mokaid.AI.ManagedRuntime.progress(run.id, %{
      "status" => "waiting_for_user_input",
      "output" => %{"runtime" => %{"status" => "waiting_for_budget"}}
    })

    params = %{run_id: run.id, request_id: Ecto.UUID.generate(), additional_credits: 500}

    response = post(c.conn, "/api/tasks/#{task.id}/runtime-budget", params) |> json_response(200)
    assert response["data"]["reserved_credits"] == 1000
    assert response["data"]["budget_revision"] == 1
    refute Map.has_key?(response["data"], "budget_cents")

    assert post(c.conn, "/api/tasks/#{task.id}/runtime-budget", params) |> json_response(200) ==
             response

    assert Mokaid.Billing.Credits.summary(c.workspace.id).spendable == 1000
  end
end
