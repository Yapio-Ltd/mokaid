defmodule Mokaid.AI.Workers.DispatchWorkerTest do
  use Mokaid.DataCase, async: false

  alias Mokaid.{Agents, Tasks}
  alias Mokaid.Agents.Agent
  alias Mokaid.AI.Workers.DispatchWorker

  defmodule WorkerFixture do
    @behaviour Plug
    def init(owner), do: owner

    def call(conn, owner) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:dispatch_payload, Jason.decode!(body)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, "{}")
    end
  end

  test "dispatch preserves colleague restrictions and scopes the roster to eligible workspace agents" do
    {workspace, owner} = workspace_fixture()
    {other_workspace, _other_owner} = workspace_fixture()
    lead = agent(workspace.id, "Lead")

    specialist =
      agent(workspace.id, "Researcher", %{
        "instructions" => "Cite the source of every finding.",
        "role_title" => "Research analyst",
        "skills" => [%{"name" => "Research", "level" => 80}],
        "autonomy_mode" => "supervised",
        "tool_preferences" => %{"disabled" => ["web_search", "mcp:*"]}
      })

    {:ok, _} =
      Agents.upsert_permission_rule(workspace.id, specialist.id, %{
        "tool_pattern" => "generate_image",
        "behavior" => "deny"
      })

    hybrid = agent(workspace.id, "Hybrid", %{"kind" => "hybrid", "status" => "active"})
    busy = agent(workspace.id, "Busy", %{"status" => "busy"})

    excluded = [
      agent(workspace.id, "Archived", %{"status" => "archived"}),
      agent(workspace.id, "Training", %{"status" => "training"}),
      agent(workspace.id, "Offline", %{"status" => "offline"}),
      agent(workspace.id, "Disabled", %{"ai_enabled" => false}),
      agent(workspace.id, "Human", %{"kind" => "human_linked", "linked_user_id" => owner.id}),
      agent(other_workspace.id, "Other workspace")
    ]

    {:ok, task} =
      Tasks.create_task(
        workspace.id,
        %{
          "title" => "Research task",
          "assigned_agent_id" => lead.id
        },
        owner_member(workspace, owner)
      )

    {:ok, run} = Tasks.create_execution_run(task)
    original_config = Application.fetch_env!(:mokaid, :ai_worker)
    on_exit(fn -> Application.put_env(:mokaid, :ai_worker, original_config) end)

    server =
      start_supervised!(
        {Bandit, plug: {WorkerFixture, self()}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)

    Application.put_env(:mokaid, :ai_worker,
      dispatch: :http,
      url: "http://127.0.0.1:#{port}",
      token: "dispatch-fixture"
    )

    assert :ok =
             DispatchWorker.perform(%Oban.Job{
               args: %{"run_id" => run.id},
               attempt: 1,
               max_attempts: 5
             })

    assert_receive {:dispatch_payload, payload}

    assert {:ok, %{agent_id: actor}} =
             Mokaid.Mail.AgentAccess.authorize(
               payload["workspace_mail"]["token"],
               "search",
               specialist.id
             )

    assert actor == specialist.id
    roster = payload["colleagues"]
    ids = Enum.map(roster, & &1["id"])
    assert Enum.sort(ids) == Enum.sort([specialist.id, hybrid.id, busy.id])
    refute lead.id in ids
    refute Enum.any?(excluded, &(&1.id in ids))

    colleague = Enum.find(roster, &(&1["id"] == specialist.id))
    assert colleague["skills"] == ["Research"]
    assert colleague["status"] == "idle"
    assert colleague["agent"]["instructions"] == "Cite the source of every finding."
    assert colleague["agent"]["tool_preferences"] == %{"disabled" => ["web_search", "mcp:*"]}
    assert colleague["autonomy"]["mode"] == "supervised"

    assert colleague["autonomy"]["rules"] == [
             %{"tool_pattern" => "generate_image", "behavior" => "deny"}
           ]

    assert Enum.find(roster, &(&1["id"] == hybrid.id))["status"] == "idle"

    # Busy agents remain consultable, but the worker can reject parallel work
    # using their actual status. Available contributors are offered first.
    assert List.last(roster)["id"] == busy.id
    assert List.last(roster)["status"] == "busy"
    refute Map.has_key?(colleague, "mcp_servers")
  end

  defp agent(workspace_id, name, attrs \\ %{}) do
    %Agent{}
    |> Agent.create_changeset(
      Map.merge(
        %{
          "workspace_id" => workspace_id,
          "display_name" => name,
          "kind" => "ai",
          "ai_enabled" => true,
          "status" => "idle"
        },
        attrs
      )
    )
    |> Repo.insert!()
  end
end
