defmodule MokaidWeb.WorkerChatScopeTest do
  use MokaidWeb.ConnCase, async: true
  import Ecto.Query

  alias Mokaid.{AgentChat, Agents}

  setup %{conn: conn} do
    {workspace, owner} = workspace_fixture()
    {:ok, agent} = Agents.create_agent(workspace.id, %{"kind" => "ai", "display_name" => "Agent"})
    {:ok, original} = AgentChat.create_conversation(workspace.id, agent.id)
    {:ok, current} = AgentChat.create_conversation(workspace.id, agent.id)
    original |> Ecto.Changeset.change(status: "archived") |> Repo.update!()
    MokaidWeb.Endpoint.subscribe("workspace:#{workspace.id}")

    {:ok,
     conn: put_req_header(conn, "authorization", "Bearer test-token"),
     workspace: workspace,
     owner: owner,
     agent: agent,
     original: original,
     current: current}
  end

  test "chunks and final replies stay in their original conversation after a new one opens",
       ctx do
    params = %{
      workspace_id: ctx.workspace.id,
      conversation_id: ctx.original.id,
      stream_id: "fixture-stream",
      chunk: "Scoped delta"
    }

    conn = post(ctx.conn, "/api/worker/agents/#{ctx.agent.id}/chat-stream", params)
    assert json_response(conn, 200)["data"]["ok"]
    assert_receive %Phoenix.Socket.Broadcast{event: "agent_chat.chunk", payload: payload}
    assert payload.conversation_id == ctx.original.id
    assert payload.chunk == "Scoped delta"

    conn =
      post(
        ctx.conn,
        "/api/worker/agents/#{ctx.agent.id}/chat-message",
        Map.put(params, :body, "Scoped final")
      )

    assert json_response(conn, 201)["data"]["conversation_id"] == ctx.original.id
    assert_receive %Phoenix.Socket.Broadcast{event: "agent_chat.message", payload: final}
    assert final.conversation_id == ctx.original.id
    assert final.stream_id == "fixture-stream"
    assert AgentChat.list_messages_for_conversation(ctx.current.id) == []
  end

  test "malformed, foreign-workspace and wrong-agent conversation IDs never broadcast or persist",
       ctx do
    {foreign, _owner} = workspace_fixture()
    {:ok, other} = Agents.create_agent(foreign.id, %{"kind" => "ai", "display_name" => "Other"})
    {:ok, foreign_conversation} = AgentChat.create_conversation(foreign.id, other.id)

    local_other =
      %Agents.Agent{}
      |> Agents.Agent.create_changeset(%{
        "workspace_id" => ctx.workspace.id,
        "kind" => "ai",
        "display_name" => "Local other"
      })
      |> Repo.insert!()

    {:ok, wrong_agent} = AgentChat.create_conversation(ctx.workspace.id, local_other.id)

    for id <- ["invalid", Ecto.UUID.generate(), foreign_conversation.id, wrong_agent.id],
        route <- ["chat-stream", "chat-message"] do
      conn =
        post(ctx.conn, "/api/worker/agents/#{ctx.agent.id}/#{route}", %{
          workspace_id: ctx.workspace.id,
          conversation_id: id,
          chunk: "Do not relay",
          body: "Do not persist"
        })

      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end

    refute_receive %Phoenix.Socket.Broadcast{event: "agent_chat.chunk"}, 50
    refute_receive %Phoenix.Socket.Broadcast{event: "agent_chat.message"}, 50
    assert AgentChat.list_messages_for_conversation(ctx.current.id) == []
  end

  test "old producers remain explicitly unscoped and canonical final messages still work", ctx do
    params = %{workspace_id: ctx.workspace.id, stream_id: "legacy", chunk: "Legacy"}

    assert ctx.conn
           |> post("/api/worker/agents/#{ctx.agent.id}/chat-stream", params)
           |> json_response(200)

    assert_receive %Phoenix.Socket.Broadcast{event: "agent_chat.chunk", payload: payload}
    assert payload.conversation_id == nil

    assert ctx.conn
           |> post(
             "/api/worker/agents/#{ctx.agent.id}/chat-message",
             Map.put(params, :body, "Legacy final")
           )
           |> json_response(201)

    assert_receive %Phoenix.Socket.Broadcast{event: "agent_chat.message", payload: final}
    assert final.conversation_id == ctx.current.id
  end

  test "a task requested by a delayed reply inherits the validated original conversation", ctx do
    member = owner_member(ctx.workspace, ctx.owner)

    conn =
      post(ctx.conn, "/api/worker/agents/#{ctx.agent.id}/chat-message", %{
        workspace_id: ctx.workspace.id,
        conversation_id: ctx.original.id,
        body: "I will prepare it",
        start_task: true,
        instruction: "Original conversation task",
        member_id: member.id,
        skip_ack: true,
        stream_id: "original-execution"
      })

    assert json_response(conn, 201)["data"]["conversation_id"] == ctx.original.id

    assert [task] =
             Repo.all(from t in Mokaid.Tasks.Task, where: t.workspace_id == ^ctx.workspace.id)

    assert task.metadata["conversation_id"] == ctx.original.id
    assert task.description == "Original conversation task"
  end
end
