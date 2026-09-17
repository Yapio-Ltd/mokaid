defmodule MokaidWeb.DispatchController do
  use MokaidWeb, :controller

  alias Mokaid.AI.Dispatcher
  alias Mokaid.Audit
  alias MokaidWeb.JSON, as: Serializer

  @doc "Analyzes an instruction + dropped files and recommends an agent / MCP setup."
  def analyze(conn, params) do
    with :ok <- Permissions.authorize(current_member(conn), "tasks.create"),
         {:ok, analysis} <- Dispatcher.analyze(workspace_id(conn), params) do
      json(conn, %{data: analysis})
    else
      {:error, :empty_request} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: %{code: "empty_request", message: "An instruction or files are required"}
        })

      other ->
        other
    end
  end

  @doc "Creates the task (and optional custom agent), grants MCPs and starts the run."
  def confirm(conn, params) do
    member = current_member(conn)

    with :ok <- Permissions.authorize(member, "tasks.create"),
         :ok <- authorize_custom_agent(member, params),
         :ok <- authorize_grants(member, params),
         {:ok, %{task: task, agent: agent, run: run}} <-
           Dispatcher.confirm(workspace_id(conn), member, params) do
      Audit.log(workspace_id(conn), member, "dispatch.confirm", "task", task.id, %{
        agent_id: agent && agent.id,
        run_id: run && run.id
      })

      conn
      |> put_status(:created)
      |> json(%{
        data: %{
          task: Serializer.task(task),
          agent: agent && Serializer.agent(agent),
          run_id: run && run.id
        }
      })
    end
  end

  defp authorize_custom_agent(member, %{"custom_agent" => %{}}),
    do: Permissions.authorize(member, "agents.create")

  defp authorize_custom_agent(_member, _params), do: :ok

  defp authorize_grants(member, %{"grant_installation_ids" => [_ | _]}),
    do: Permissions.authorize(member, "integrations.connect")

  defp authorize_grants(_member, _params), do: :ok
end
