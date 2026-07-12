defmodule Mokaid.RealtimeTest do
  use ExUnit.Case, async: true

  test "workspace broadcasts only Phoenix channel messages" do
    workspace_id = Ecto.UUID.generate()
    topic = "workspace:#{workspace_id}"
    Phoenix.PubSub.subscribe(Mokaid.PubSub, topic)

    Mokaid.Realtime.broadcast_workspace(workspace_id, "agent_chat.message", %{id: "msg-1"})

    assert_receive %Phoenix.Socket.Broadcast{
      topic: ^topic,
      event: "agent_chat.message",
      payload: %{id: "msg-1"}
    }

    refute_receive {:realtime, "agent_chat.message", _}, 20
  end
end
