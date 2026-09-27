defmodule Mokaid.AI.DispatcherWorkerResponseTest do
  use Mokaid.DataCase, async: false

  alias Mokaid.Agents
  alias Mokaid.AI.Dispatcher
  alias Mokaid.Billing
  alias Mokaid.Tasks

  setup do
    config = Application.fetch_env!(:mokaid, :ai_worker)
    http_options = Application.get_env(:mokaid, :dispatch_analysis_http_options)

    Application.put_env(:mokaid, :ai_worker,
      dispatch: :http,
      url: "http://worker.test",
      token: "test-token"
    )

    Application.put_env(:mokaid, :dispatch_analysis_http_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      Application.put_env(:mokaid, :ai_worker, config)

      if http_options,
        do: Application.put_env(:mokaid, :dispatch_analysis_http_options, http_options),
        else: Application.delete_env(:mokaid, :dispatch_analysis_http_options)
    end)

    Billing.seed_plans()
    {workspace, owner} = workspace_fixture()
    %{workspace: workspace, member: owner_member(workspace, owner)}
  end

  defp response(overrides \\ %{}) do
    %{
      "task" => %{
        "title" => "Diagnose Kubernetes networking",
        "description" => "Diagnose the Kubernetes DNS outage and provide remediation.",
        "priority" => "high"
      },
      "recommendation" =>
        Map.merge(
          %{
            "mode" => "custom_agent",
            "agent_id" => nil,
            "confidence" => 90,
            "reason" => "A DevOps specialist is needed for Kubernetes troubleshooting.",
            "alternatives" => [],
            "custom_agent" => %{
              "display_name" => "DevOps Specialist",
              "role_title" => "DevOps Engineer",
              "archetype_key" => "devops",
              "department" => "Engineering",
              "skills" => [%{"name" => "kubernetes", "level" => 75}]
            }
          },
          overrides
        ),
      "mcp_suggestions" => []
    }
  end

  defp analyze(workspace, body, status \\ 200) do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/dispatch/analyze"
      {:ok, request_body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(request_body)
      assert Enum.any?(payload["agent_archetypes"], &(&1["key"] == "devops"))
      conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
    end)

    Dispatcher.analyze(workspace.id, %{"instruction" => "Diagnose the Kubernetes DNS outage"})
  end

  test "missing specialist profile fails closed instead of becoming a generic agent", ctx do
    assert {:error, :invalid_dispatch_analysis} =
             analyze(ctx.workspace, response(%{"custom_agent" => nil}))

    assert Agents.list_agents(ctx.workspace.id) == []
    assert Tasks.list_tasks(ctx.workspace.id) == []
  end

  test "worker exhausted repair is not hidden by offline routing", ctx do
    assert {:error, :invalid_dispatch_analysis} =
             analyze(ctx.workspace, %{"detail" => "invalid_dispatch_analysis"}, 422)
  end

  test "rejects malformed and blank specialist fields", ctx do
    valid = response()["recommendation"]["custom_agent"]

    for profile <- [
          %{},
          "DevOps",
          Map.put(valid, "display_name", " "),
          Map.put(valid, "role_title", "\n"),
          Map.delete(valid, "archetype_key"),
          Map.put(valid, "archetype_key", "invented-specialist"),
          Map.put(valid, "skills", []),
          Map.put(valid, "skills", [%{"name" => "  "}]),
          Map.put(valid, "skills", %{"name" => "kubernetes"})
        ] do
      assert {:error, :invalid_dispatch_analysis} =
               analyze(ctx.workspace, response(%{"custom_agent" => profile}))
    end
  end

  test "rejects contradictory routes, foreign agents and absent confidence", ctx do
    for overrides <- [
          %{"agent_id" => Ecto.UUID.generate()},
          %{"alternatives" => [%{"agent_id" => Ecto.UUID.generate()}]},
          %{
            "mode" => "existing_agent",
            "agent_id" => Ecto.UUID.generate(),
            "custom_agent" => nil
          },
          %{"mode" => "user_choice", "agent_id" => Ecto.UUID.generate()},
          %{"confidence" => nil},
          %{"confidence" => "90"}
        ] do
      assert {:error, :invalid_dispatch_analysis} = analyze(ctx.workspace, response(overrides))
    end
  end

  test "malformed nested payloads are rejected without raising", ctx do
    for body <- [
          [],
          %{},
          Map.put(response(), "recommendation", []),
          Map.put(response(), "task", "invalid"),
          Map.put(response(), "mcp_suggestions", true),
          put_in(response(), ["recommendation", "alternatives"], true),
          put_in(response(), ["recommendation", "reason"], %{})
        ] do
      assert {:error, :invalid_dispatch_analysis} = analyze(ctx.workspace, body)
    end
  end

  test "worker unavailability retains the existing offline route", ctx do
    assert {:ok, analysis} = analyze(ctx.workspace, %{"detail" => "unavailable"}, 503)
    assert analysis.recommendation.custom_agent.archetype_key == "devops"
  end

  test "SQS execution transport still uses synchronous worker analysis", ctx do
    config = Application.fetch_env!(:mokaid, :ai_worker)
    Application.put_env(:mokaid, :ai_worker, Keyword.put(config, :dispatch, :sqs))

    assert {:ok, analysis} = analyze(ctx.workspace, response())
    assert analysis.recommendation.confidence == 90
    assert analysis.recommendation.custom_agent.display_name == "DevOps Specialist"
  end

  test "missing worker credentials never send an analysis HTTP request", ctx do
    config = Application.fetch_env!(:mokaid, :ai_worker)

    Req.Test.stub(__MODULE__, fn _ -> flunk("Missing worker token must prevent HTTP requests") end)

    for token <- [nil, "", "  "] do
      Application.put_env(:mokaid, :ai_worker, Keyword.put(config, :token, token))

      assert {:ok, analysis} =
               Dispatcher.analyze(ctx.workspace.id, %{"instruction" => "Diagnose Kubernetes DNS"})

      assert analysis.recommendation.confidence == 15
    end
  end

  test "explicit offline mode never sends an analysis HTTP request", ctx do
    config = Application.fetch_env!(:mokaid, :ai_worker)
    Application.put_env(:mokaid, :ai_worker, Keyword.put(config, :dispatch, :none))
    Req.Test.stub(__MODULE__, fn _ -> flunk("Offline mode must prevent HTTP requests") end)

    assert {:ok, analysis} =
             Dispatcher.analyze(ctx.workspace.id, %{"instruction" => "Diagnose Kubernetes DNS"})

    assert analysis.recommendation.confidence == 15
  end

  test "valid specialist keeps its domain through analysis and confirmation", ctx do
    Billing.change_plan(ctx.workspace.id, "professional")
    assert {:ok, analysis} = analyze(ctx.workspace, response())
    assert analysis.recommendation.custom_agent.archetype_key == "devops"

    profile = analysis.recommendation.custom_agent |> Jason.encode!() |> Jason.decode!()

    assert {:ok, %{agent: agent}} =
             Dispatcher.confirm(ctx.workspace.id, ctx.member, %{
               "instruction" => "Diagnose the Kubernetes DNS outage",
               "custom_agent" => profile,
               "start_now" => false
             })

    assert agent.role_title == "DevOps Engineer"
    assert agent.capabilities["learning"]["archetype"] == "devops"
    assert agent.instructions =~ "kubernetes"
    assert Enum.any?(agent.skills, &(&1["name"] == "infrastructure"))
  end

  test "low-confidence existing route never fabricates a custom profile", ctx do
    Billing.change_plan(ctx.workspace.id, "professional")

    {:ok, agent} =
      Agents.create_agent(ctx.workspace.id, %{
        "kind" => "ai",
        "display_name" => "DevOps",
        "archetype_key" => "devops"
      })

    route = %{
      "mode" => "existing_agent",
      "agent_id" => agent.id,
      "confidence" => 30,
      "custom_agent" => nil
    }

    assert {:error, :invalid_dispatch_analysis} = analyze(ctx.workspace, response(route))
    assert {:ok, accepted} = analyze(ctx.workspace, response(Map.put(route, "confidence", 90)))
    assert accepted.recommendation.agent_id == agent.id
    assert accepted.recommendation.custom_agent == nil
  end

  test "user choice requires both a known employee and a complete specialist", ctx do
    Billing.change_plan(ctx.workspace.id, "professional")

    {:ok, agent} =
      Agents.create_agent(ctx.workspace.id, %{
        "kind" => "ai",
        "display_name" => "Engineer",
        "archetype_key" => "developer"
      })

    route = %{"mode" => "user_choice", "agent_id" => agent.id, "confidence" => 55}
    assert {:ok, accepted} = analyze(ctx.workspace, response(route))
    assert accepted.recommendation.agent_id == agent.id
    assert accepted.recommendation.custom_agent.archetype_key == "devops"

    assert {:error, :invalid_dispatch_analysis} =
             analyze(ctx.workspace, response(Map.put(route, "custom_agent", nil)))

    assert {:error, :invalid_dispatch_analysis} =
             analyze(ctx.workspace, response(Map.put(route, "mode", "existing_agent")))
  end

  test "unknown integration references are rejected instead of silently omitted", ctx do
    body =
      Map.put(response(), "mcp_suggestions", [
        %{"server_key" => "invented-server", "reason" => "Needed for troubleshooting"}
      ])

    assert {:error, :invalid_dispatch_analysis} = analyze(ctx.workspace, body)
  end

  test "confirmation rejects incomplete custom requests before creating any state", ctx do
    Billing.change_plan(ctx.workspace.id, "professional")

    for profile <- [
          nil,
          "DevOps",
          %{},
          %{"display_name" => " "},
          %{"display_name" => "DevOps"},
          %{"display_name" => "DevOps", "archetype_key" => "invented-specialist"},
          %{"display_name" => "DevOps", "archetype_key" => "devops", "skills" => []},
          %{"display_name" => "DevOps", "archetype_key" => "devops", "role_title" => " "}
        ] do
      assert {:error, :invalid_custom_agent} =
               Dispatcher.confirm(ctx.workspace.id, ctx.member, %{
                 "instruction" => "Diagnose the Kubernetes DNS outage",
                 "custom_agent" => profile,
                 "start_now" => false
               })
    end

    assert Agents.list_agents(ctx.workspace.id) == []
    assert Tasks.list_tasks(ctx.workspace.id) == []
  end
end
