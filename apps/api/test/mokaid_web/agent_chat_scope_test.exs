defmodule MokaidWeb.AgentChatScopeTest do
  use MokaidWeb.ConnCase, async: true

  alias Mokaid.{AgentChat, Agents}

  setup %{conn: conn} do
    {workspace, owner} = workspace_fixture()

    {:ok, agent} =
      Agents.create_agent(workspace.id, %{"kind" => "ai", "display_name" => "Primary"})

    {:ok, conversation} = AgentChat.create_conversation(workspace.id, agent.id)

    {:ok, message} =
      AgentChat.post_agent_message(workspace.id, agent.id, "Expected conversation body",
        conversation_id: conversation.id
      )

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> Mokaid.Auth.Token.sign(owner.id))
      |> put_req_header("x-workspace-id", workspace.id)

    {:ok,
     conn: conn, workspace: workspace, agent: agent, conversation: conversation, message: message}
  end

  test "allows the requested agent's conversation", %{
    conn: conn,
    agent: agent,
    conversation: conversation,
    message: message
  } do
    response = get(conn, "/api/agents/#{agent.id}/chat", %{conversation_id: conversation.id})

    assert [%{"id" => id, "body" => "Expected conversation body"}] =
             json_response(response, 200)["data"]

    assert id == message.id
  end

  test "cannot read another agent's conversation in the same workspace", %{
    conn: conn,
    workspace: workspace,
    agent: agent
  } do
    # Authorization must remain scoped even when multiple historical agents
    # exist; do not couple this fixture to the Free plan's current agent quota.
    other =
      %Agents.Agent{}
      |> Agents.Agent.create_changeset(%{
        "workspace_id" => workspace.id,
        "kind" => "ai",
        "display_name" => "Other"
      })
      |> Mokaid.Repo.insert!()

    {:ok, conversation} = AgentChat.create_conversation(workspace.id, other.id)

    {:ok, _} =
      AgentChat.post_agent_message(workspace.id, other.id, "Private other agent",
        conversation_id: conversation.id
      )

    response = get(conn, "/api/agents/#{agent.id}/chat", %{conversation_id: conversation.id})
    assert json_response(response, 404)["error"]["code"] == "not_found"
    refute response.resp_body =~ "Private other agent"
  end

  test "cannot read a conversation in another workspace", %{conn: conn, agent: agent} do
    {foreign, _} = workspace_fixture()
    {:ok, other} = Agents.create_agent(foreign.id, %{"kind" => "ai", "display_name" => "Foreign"})
    {:ok, conversation} = AgentChat.create_conversation(foreign.id, other.id)

    {:ok, _} =
      AgentChat.post_agent_message(foreign.id, other.id, "Foreign private text",
        conversation_id: conversation.id
      )

    response = get(conn, "/api/agents/#{agent.id}/chat", %{conversation_id: conversation.id})
    assert json_response(response, 404)["error"]["code"] == "not_found"
    refute response.resp_body =~ "Foreign private text"
  end

  test "malformed conversation identifiers return not found without an exception", %{
    conn: conn,
    agent: agent
  } do
    assert conn
           |> get("/api/agents/#{agent.id}/chat", %{conversation_id: "invalid"})
           |> json_response(404)
  end
end
