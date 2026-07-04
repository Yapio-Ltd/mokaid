defmodule MokaidWeb.AgentChannel do
  use MokaidWeb, :channel

  @impl true
  def join("agent:" <> agent_id, %{"workspace_id" => workspace_id}, socket) do
    with %{} = _member <-
           Mokaid.Members.get_member_for_user(workspace_id, socket.assigns.current_user.id),
         %{} = _agent <- Mokaid.Agents.get_agent(workspace_id, agent_id) do
      {:ok, assign(socket, :workspace_id, workspace_id)}
    else
      _ -> {:error, %{reason: "forbidden"}}
    end
  end

  def join(_topic, _params, _socket), do: {:error, %{reason: "bad_topic"}}
end
