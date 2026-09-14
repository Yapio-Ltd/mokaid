defmodule Mokaid.AI.AgentChatWorkerTest do
  use Mokaid.DataCase, async: false
  import Mokaid.Fixtures
  alias Mokaid.{AgentChat, Agents}
  alias Mokaid.AI.Workers.AgentChatWorker

  test "dispatch captures the trigger conversation, not the active conversation at execution" do
    {workspace, _owner} = workspace_fixture()

    {:ok, agent} =
      Agents.create_agent(workspace.id, %{"kind" => "ai", "display_name" => "Scoped"})

    {:ok, original} = AgentChat.create_conversation(workspace.id, agent.id)

    trigger =
      %AgentChat.ChatMessage{}
      |> AgentChat.ChatMessage.changeset(%{
        "workspace_id" => workspace.id,
        "agent_id" => agent.id,
        "conversation_id" => original.id,
        "author_kind" => "member",
        "body" => "Original prompt"
      })
      |> Repo.insert!()

    {:ok, current} = AgentChat.create_conversation(workspace.id, agent.id)
    original |> Ecto.Changeset.change(status: "archived") |> Repo.update!()

    %AgentChat.ChatMessage{}
    |> AgentChat.ChatMessage.changeset(%{
      "workspace_id" => workspace.id,
      "agent_id" => agent.id,
      "conversation_id" => current.id,
      "author_kind" => "member",
      "body" => "Must not leak into the old execution"
    })
    |> Repo.insert!()

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, {_address, port}} = :inet.sockname(listener)
    config = Application.fetch_env!(:mokaid, :ai_worker)

    on_exit(fn ->
      Application.put_env(:mokaid, :ai_worker, config)
      :gen_tcp.close(listener)
    end)

    Application.put_env(:mokaid, :ai_worker,
      dispatch: :http,
      url: "http://127.0.0.1:#{port}",
      token: "fixture"
    )

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 5_000)
        payload = receive_request(socket, "")

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
          )

        :gen_tcp.close(socket)
        payload
      end)

    assert :ok =
             AgentChatWorker.perform(%Oban.Job{
               args: %{
                 "workspace_id" => workspace.id,
                 "agent_id" => agent.id,
                 "message_id" => trigger.id
               }
             })

    payload = Task.await(server, 5_000)
    assert payload["conversation_id"] == original.id
    assert Enum.map(payload["conversation"], & &1["body"]) == ["Original prompt"]

    # A queued pre-conversation job may still have a message_id, but it cannot
    # safely be attributed to the current thread. It must not contact the worker.
    legacy =
      %AgentChat.ChatMessage{}
      |> AgentChat.ChatMessage.changeset(%{
        "workspace_id" => workspace.id,
        "agent_id" => agent.id,
        "author_kind" => "member",
        "body" => "Old unscoped trigger"
      })
      |> Repo.insert!()

    for id <- [legacy.id, Ecto.UUID.generate(), "invalid", nil] do
      assert :ok =
               AgentChatWorker.perform(%Oban.Job{
                 args: %{
                   "workspace_id" => workspace.id,
                   "agent_id" => agent.id,
                   "message_id" => id
                 }
               })
    end

    assert {:error, :timeout} = :gen_tcp.accept(listener, 100)
  end

  defp receive_request(socket, bytes) do
    case String.split(bytes, "\r\n\r\n", parts: 2) do
      [headers, body] ->
        [_, length] = Regex.run(~r/content-length:\s*(\d+)/i, headers)

        if byte_size(body) >= String.to_integer(length),
          do: Jason.decode!(body),
          else: read_more(socket, bytes)

      _ ->
        read_more(socket, bytes)
    end
  end

  defp read_more(socket, bytes) do
    {:ok, chunk} = :gen_tcp.recv(socket, 0, 5_000)
    receive_request(socket, bytes <> chunk)
  end
end
