defmodule MokaidWeb.OrchestratorController do
  use MokaidWeb, :controller
  alias Mokaid.AI.Coordinator

  def stop(conn, %{"id" => id}) do
    member = current_member(conn)

    with :ok <- Permissions.authorize(member, "agents.run_ai"),
         :ok <- Permissions.authorize(member, "tasks.update"),
         {:ok, task} <- Coordinator.stop(workspace_id(conn), id, member) do
      Mokaid.Audit.log(
        workspace_id(conn),
        member,
        "orchestrator.mission_stopped",
        "task",
        id,
        %{}
      )

      json(conn, %{data: MokaidWeb.JSON.task(task)})
    end
  end

  def missions(conn, _params) do
    with :ok <- Permissions.authorize(current_member(conn), "tasks.view") do
      json(conn, %{data: Coordinator.missions(workspace_id(conn))})
    end
  end

  def chat(conn, params) do
    with :ok <- Permissions.authorize(current_member(conn), "agents.view"),
         :ok <- Permissions.authorize(current_member(conn), "tasks.view"),
         :ok <- Permissions.authorize(current_member(conn), "agents.run_ai"),
         {:ok, result} <- Coordinator.reply(workspace_id(conn), current_member(conn), params) do
      json(conn, %{data: result})
    else
      {:error, :orchestrator_unavailable} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{
          error: %{
            code: "orchestrator_unavailable",
            message:
              "Moked's conversation model is unavailable. Reconnect or check the AI worker configuration; your message is preserved."
          }
        })

      other ->
        other
    end
  end
end
