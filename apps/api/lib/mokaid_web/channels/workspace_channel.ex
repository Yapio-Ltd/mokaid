defmodule MokaidWeb.WorkspaceChannel do
  use MokaidWeb, :channel

  alias Mokaid.Members
  alias MokaidWeb.Presence

  @impl true
  def join("workspace:" <> workspace_id, _params, socket) do
    case Members.get_member_for_user(workspace_id, socket.assigns.current_user.id) do
      nil ->
        {:error, %{reason: "forbidden"}}

      member ->
        send(self(), :after_join)

        {:ok,
         socket
         |> assign(:workspace_id, workspace_id)
         |> assign(:member, member)}
    end
  end

  @impl true
  def handle_info(:after_join, socket) do
    member = socket.assigns.member
    agent = member.linked_agent

    {:ok, _} =
      Presence.track(socket, socket.assigns.current_user.id, %{
        user_id: socket.assigns.current_user.id,
        member_id: member.id,
        agent_id: agent && agent.id,
        status: "online",
        current_page: nil,
        current_task_id: nil,
        last_seen_at: DateTime.utc_now() |> DateTime.to_iso8601()
      })

    push(socket, "presence_state", Presence.list(socket))

    if agent do
      Mokaid.Agents.change_status(%{agent | workspace_id: socket.assigns.workspace_id}, "active",
        reason: "human_online"
      )
    end

    {:noreply, socket}
  end

  @impl true
  def handle_in("page_changed", %{"page" => page}, socket) do
    Presence.update(socket, socket.assigns.current_user.id, fn meta ->
      Map.merge(meta, %{current_page: page, last_seen_at: DateTime.utc_now() |> DateTime.to_iso8601()})
    end)

    {:noreply, socket}
  end

  def handle_in(_event, _payload, socket) do
    {:noreply, socket}
  end
end
