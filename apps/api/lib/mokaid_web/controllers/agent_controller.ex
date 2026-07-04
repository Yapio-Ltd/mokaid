defmodule MokaidWeb.AgentController do
  use MokaidWeb, :controller

  alias Mokaid.Agents
  alias Mokaid.Tasks
  alias MokaidWeb.JSON, as: Serializer

  def index(conn, params) do
    with :ok <- Permissions.authorize(current_member(conn), "agents.view") do
      agents = Agents.list_agents(workspace_id(conn), params)
      counts = Agents.counts(workspace_id(conn))

      json(conn, %{data: Enum.map(agents, &Serializer.agent/1), meta: %{counts: counts}})
    end
  end

  def create(conn, params) do
    with :ok <- Permissions.authorize(current_member(conn), "agents.create"),
         {:ok, agent} <- Agents.create_agent(workspace_id(conn), params, current_member(conn)) do
      conn
      |> put_status(:created)
      |> json(%{data: Serializer.agent(agent)})
    end
  end

  def show(conn, %{"id" => id}) do
    with :ok <- Permissions.authorize(current_member(conn), "agents.view"),
         %{} = agent <- Agents.get_agent(workspace_id(conn), id) do
      json(conn, %{data: Serializer.agent(agent)})
    end
  end

  def update(conn, %{"id" => id} = params) do
    with :ok <- Permissions.authorize(current_member(conn), "agents.update"),
         %{} = agent <- Agents.get_agent(workspace_id(conn), id),
         {:ok, updated} <- Agents.update_agent(agent, params) do
      json(conn, %{data: Serializer.agent(updated)})
    end
  end

  def delete(conn, %{"id" => id}) do
    with :ok <- Permissions.authorize(current_member(conn), "agents.delete"),
         %{} = agent <- Agents.get_agent(workspace_id(conn), id),
         {:ok, _} <- Agents.archive_agent(agent) do
      json(conn, %{ok: true})
    end
  end

  def link_user(conn, %{"id" => id, "user_id" => user_id, "member_id" => member_id}) do
    with :ok <- Permissions.authorize(current_member(conn), "agents.link_user"),
         %{} = agent <- Agents.get_agent(workspace_id(conn), id),
         {:ok, updated} <- Agents.link_user(agent, user_id, member_id, current_member(conn)) do
      json(conn, %{data: Serializer.agent(updated)})
    end
  end

  def unlink_user(conn, %{"id" => id}) do
    with :ok <- Permissions.authorize(current_member(conn), "agents.link_user"),
         %{} = agent <- Agents.get_agent(workspace_id(conn), id),
         {:ok, updated} <- Agents.unlink_user(agent, current_member(conn)) do
      json(conn, %{data: Serializer.agent(updated)})
    end
  end

  def assign_task(conn, %{"id" => id, "task_id" => task_id}) do
    with :ok <- Permissions.authorize(current_member(conn), "agents.assign_task"),
         %{} = task <- Tasks.get_task(workspace_id(conn), task_id),
         {:ok, updated} <- Tasks.assign_task(task, id, current_member(conn)) do
      json(conn, %{data: Serializer.task(updated)})
    end
  end
end
