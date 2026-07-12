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

  @doc "Progression tab: level, XP bar, mission count, recent mission memories."
  def progression(conn, %{"id" => id}) do
    with :ok <- Permissions.authorize(current_member(conn), "agents.view"),
         %{} = agent <- Agents.get_agent(workspace_id(conn), id) do
      json(conn, %{data: Mokaid.Agents.Progression.snapshot(agent)})
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

  # Text-ish formats whose content can be indexed directly. Binary formats
  # (pdf, docx…) are stored but only indexed once an extractor handles them.
  @indexable_extensions ~w(txt md markdown csv json html)

  @doc """
  "Feed data" to an agent: each uploaded file becomes an agent-scoped
  knowledge item (the agent's personal knowledge base), indexed for
  retrieval when readable as text.
  """
  def upload_files(conn, %{"id" => id} = params) do
    uploads = List.wrap(params["files"] || params["file"])

    with :ok <- Permissions.authorize(current_member(conn), "knowledge.upload"),
         %{} = agent <- Agents.get_agent(workspace_id(conn), id) do
      count =
        uploads
        |> Enum.filter(&match?(%Plug.Upload{}, &1))
        |> Enum.count(fn upload ->
          body = readable_body(upload)

          case Mokaid.Knowledge.create_item(
                 workspace_id(conn),
                 %{
                   "title" => upload.filename,
                   "type" => "file",
                   "agent_id" => agent.id,
                   "body" => body,
                   "status" => if(body, do: "processing", else: "published"),
                   "metadata" => %{
                     "original_filename" => upload.filename,
                     "content_type" => upload.content_type,
                     "fed_to_agent" => agent.display_name
                   }
                 },
                 current_member(conn)
               ) do
            {:ok, _item} -> true
            _ -> false
          end
        end)

      json(conn, %{data: %{count: count, agent_id: agent.id}})
    end
  end

  defp readable_body(%Plug.Upload{} = upload) do
    extension = upload.filename |> Path.extname() |> String.trim_leading(".") |> String.downcase()

    with true <- extension in @indexable_extensions,
         {:ok, content} <- File.read(upload.path),
         true <- String.valid?(content) do
      content
    else
      _ -> nil
    end
  end
end
