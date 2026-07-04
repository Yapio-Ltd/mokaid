defmodule MokaidWeb.TaskChannel do
  use MokaidWeb, :channel

  alias Mokaid.Tasks

  @impl true
  def join("task:" <> task_id, %{"workspace_id" => workspace_id}, socket) do
    with %{} = member <-
           Mokaid.Members.get_member_for_user(workspace_id, socket.assigns.current_user.id),
         %{} = _task <- Tasks.get_task(workspace_id, task_id) do
      {:ok, socket |> assign(:workspace_id, workspace_id) |> assign(:member, member)}
    else
      _ -> {:error, %{reason: "forbidden"}}
    end
  end

  def join(_topic, _params, _socket), do: {:error, %{reason: "bad_topic"}}
end
