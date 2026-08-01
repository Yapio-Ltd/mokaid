defmodule MokaidWeb.AgentController do
  use MokaidWeb, :controller

  alias Mokaid.Agents
  alias Mokaid.Agents.Archetypes
  alias Mokaid.Tasks
  alias MokaidWeb.JSON, as: Serializer

  @create_params ~w(
    display_name role_title department kind avatar_asset_id avatar_config
    archetype_key boost_key knowledge_brief linked_user_id linked_member_id
    human_takeover_enabled email_alias
  )

  @update_params ~w(
    display_name role_title department avatar_asset_id avatar_config
    human_takeover_enabled email_alias status presence_status control_mode
  )

  def index(conn, params) do
    with :ok <- Permissions.authorize(current_member(conn), "agents.view") do
      agents = Agents.list_agents(workspace_id(conn), params)
      counts = Agents.counts(workspace_id(conn))

      json(conn, %{data: Enum.map(agents, &Serializer.agent/1), meta: %{counts: counts}})
    end
  end

  @doc "Catalog of free archetypes and paid creation boosts."
  def catalog(conn, _params) do
    with :ok <- Permissions.authorize(current_member(conn), "agents.view") do
      json(conn, %{data: Archetypes.catalog()})
    end
  end

  def create(conn, params) do
    with :ok <- Permissions.authorize(current_member(conn), "agents.create"),
         {:ok, agent} <-
           Agents.create_agent(
             workspace_id(conn),
             Map.take(params, @create_params),
             current_member(conn)
           ) do
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

  @doc "Progression tab: level, XP bar, mission count, recent mission memories."
  def progression(conn, %{"id" => id}) do
    with :ok <- Permissions.authorize(current_member(conn), "agents.view"),
         %{} = agent <- Agents.get_agent(workspace_id(conn), id) do
      json(conn, %{data: Mokaid.Agents.Progression.snapshot(agent)})
    end
  end

  @doc "Head-start training progress (poll fallback for the training page)."
  def training(conn, %{"id" => id}) do
    with :ok <- Permissions.authorize(current_member(conn), "agents.view"),
         %{} = agent <- Agents.get_agent(workspace_id(conn), id) do
      json(conn, %{data: Agents.training_snapshot(agent)})
    end
  end

  def update(conn, %{"id" => id} = params) do
    with :ok <- Permissions.authorize(current_member(conn), "agents.update"),
         %{} = agent <- Agents.get_agent(workspace_id(conn), id),
         {:ok, updated} <- Agents.update_agent(agent, Map.take(params, @update_params)) do
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

  @doc """
  "Feed data" to an agent: each uploaded file becomes an agent-scoped
  knowledge item (the agent's personal knowledge base). Text formats are
  indexed inline; binary formats (PDF, DOCX, XLSX, PPTX…) are stored and
  indexed asynchronously through the AI worker's extractors.
  """
  def upload_files(conn, %{"id" => id} = params) do
    uploads = List.wrap(params["files"] || params["file"])

    with :ok <- Permissions.authorize(current_member(conn), "knowledge.upload"),
         %{} = agent <- Agents.get_agent(workspace_id(conn), id) do
      count =
        uploads
        |> Enum.filter(&match?(%Plug.Upload{}, &1))
        |> Enum.count(fn upload ->
          case Mokaid.Knowledge.create_from_upload(
                 workspace_id(conn),
                 upload,
                 current_member(conn),
                 agent_id: agent.id,
                 metadata: %{"fed_to_agent" => agent.display_name}
               ) do
            {:ok, _item} -> true
            _ -> false
          end
        end)

      json(conn, %{data: %{count: count, agent_id: agent.id}})
    end
  end
end
