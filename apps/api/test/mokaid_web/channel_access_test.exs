defmodule MokaidWeb.ChannelAccessTest do
  use Mokaid.DataCase, async: true

  alias Mokaid.Auth.{Desktop, Token}
  alias MokaidWeb.{AgentChannel, ChannelAccess, TaskChannel, UserSocket, WorkspaceChannel}

  defp connected(user, :browser) do
    {:ok, socket} = UserSocket.connect(%{"token" => Token.sign(user.id)}, %Phoenix.Socket{}, %{})
    socket
  end

  defp connected(user, :desktop) do
    verifier = String.duplicate("x", 64)
    redirect = "http://127.0.0.1:49152/callback"

    {:ok, request} =
      Desktop.create_request(%{
        "code_challenge" => :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false),
        "redirect_uri" => redirect,
        "state" => String.duplicate("s", 43)
      })

    {:ok, callback} = Desktop.approve(request.id, user)
    %{"code" => code} = URI.decode_query(URI.parse(callback).query)

    {:ok, tokens} =
      Desktop.exchange(%{"code" => code, "code_verifier" => verifier, "redirect_uri" => redirect})

    {:ok, socket} =
      UserSocket.connect(%{}, %Phoenix.Socket{}, %{
        x_headers: [{"x-mokaid-authorization", "Bearer " <> tokens.access_token}]
      })

    socket
  end

  defp transport(socket, topic),
    do: {%{channels: %{topic => {self(), make_ref(), :joined}}}, socket}

  defp broadcast(topic) do
    Phoenix.Socket.V2.JSONSerializer.fastlane!(%Phoenix.Socket.Broadcast{
      topic: topic,
      event: "security.fixture",
      payload: %{body: "Workspace-only synthetic payload"}
    })
  end

  test "removed workspace membership blocks already joined workspace task and agent output" do
    {workspace, user} = workspace_fixture()
    member = owner_member(workspace, user)
    task = Repo.insert!(%Mokaid.Tasks.Task{workspace_id: workspace.id, title: "Synthetic task"})

    agent =
      Repo.insert!(%Mokaid.Agents.Agent{
        workspace_id: workspace.id,
        kind: "ai",
        display_name: "Synthetic agent",
        slug: "synthetic-channel-agent"
      })

    topics = [
      {WorkspaceChannel, "workspace:" <> workspace.id, %{}},
      {TaskChannel, "task:" <> task.id, %{"workspace_id" => workspace.id}},
      {AgentChannel, "agent:" <> agent.id, %{"workspace_id" => workspace.id}}
    ]

    sockets = for type <- [:browser, :desktop], do: connected(user, type)

    for socket <- sockets, {channel, topic, params} <- topics do
      assert {:ok, _} = channel.join(topic, params, socket)
      state = transport(socket, topic)
      assert {:push, _, ^state} = UserSocket.handle_info(broadcast(topic), state)
    end

    member |> change(status: "removed") |> Repo.update!()

    for socket <- sockets, {_channel, topic, _params} <- topics do
      state = transport(socket, topic)
      assert {:stop, :normal, ^state} = UserSocket.handle_info(broadcast(topic), state)
      assert {:stop, :normal, ^state} = UserSocket.handle_in({"ignored", []}, state)
      assert {:stop, :normal, ^state} = UserSocket.handle_info(:auth_session_check, state)
    end
  end

  test "disabled browser and desktop accounts cannot retain notification streams" do
    user = user_fixture()
    sockets = for type <- [:browser, :desktop], do: connected(user, type)
    user |> change(status: "disabled") |> Repo.update!()

    for socket <- sockets do
      topic = "notifications:" <> user.id
      state = transport(socket, topic)
      assert {:stop, :normal, ^state} = UserSocket.handle_info(broadcast(topic), state)
      assert {:stop, :normal, ^state} = UserSocket.handle_info(:auth_session_check, state)
    end
  end

  test "heartbeat before first join and authorized notification payloads keep Phoenix framing" do
    user = user_fixture()

    for type <- [:browser, :desktop] do
      socket = %{connected(user, type) | serializer: Phoenix.Socket.V2.JSONSerializer}
      state = {%{channels: %{}, channels_inverse: %{}}, socket}
      heartbeat = Jason.encode!([nil, "heartbeat-ref", "phoenix", "heartbeat", %{}])

      assert {:reply, :ok, {:text, reply}, ^state} =
               UserSocket.handle_in({heartbeat, [opcode: :text]}, state)

      assert [nil, "heartbeat-ref", "phoenix", "phx_reply", %{"status" => "ok"}] =
               Jason.decode!(IO.iodata_to_binary(reply))

      topic = "notifications:" <> user.id
      state = transport(socket, topic)
      {:socket_push, opcode, payload} = encoded = broadcast(topic)
      assert {:push, {^opcode, ^payload}, ^state} = UserSocket.handle_info(encoded, state)
    end
  end

  test "malformed unknown foreign and mixed joined scopes fail closed even for operators" do
    {own, user} = workspace_fixture()
    user = user |> change(is_platform_admin: true) |> Repo.update!()
    {foreign, outsider} = workspace_fixture()
    known = "workspace:" <> own.id

    for invalid <- [
          "workspace:not-a-uuid",
          "workspace:' OR 1=1--",
          "unreviewed:" <> own.id,
          "notifications:" <> outsider.id,
          "workspace:" <> foreign.id,
          "task:" <> Ecto.UUID.generate(),
          "agent:" <> Ecto.UUID.generate()
        ] do
      refute ChannelAccess.allowed?(user.id, %{known => {}, invalid => {}})
    end

    assert ChannelAccess.allowed?(user.id, %{known => {}})
    refute ChannelAccess.allowed?(user.id, nil)
  end

  test "resource moved out of an authorized workspace cannot keep streaming through its old topic" do
    {own, user} = workspace_fixture()
    {foreign, _} = workspace_fixture()
    task = Repo.insert!(%Mokaid.Tasks.Task{workspace_id: own.id, title: "Synthetic task"})
    topic = "task:" <> task.id
    state = transport(connected(user, :desktop), topic)
    assert {:push, _, ^state} = UserSocket.handle_info(broadcast(topic), state)
    task |> change(workspace_id: foreign.id) |> Repo.update!()
    assert {:stop, :normal, ^state} = UserSocket.handle_info(broadcast(topic), state)
  end
end
