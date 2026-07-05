defmodule MokaidWeb.SearchController do
  use MokaidWeb, :controller

  import Ecto.Query

  alias Mokaid.Agents.Agent
  alias Mokaid.Knowledge.KnowledgeItem
  alias Mokaid.Projects.Project
  alias Mokaid.Repo
  alias Mokaid.Tasks.Task

  @limit_per_type 5

  def index(conn, %{"q" => query}) when byte_size(query) > 0 do
    workspace_id = workspace_id(conn)
    pattern = "%#{String.replace(query, ~r/[%_\\]/, "")}%"

    tasks =
      Repo.all(
        from t in Task,
          where: t.workspace_id == ^workspace_id and ilike(t.title, ^pattern),
          order_by: [desc: t.updated_at],
          limit: @limit_per_type,
          select: %{id: t.id, title: t.title, status: t.status}
      )

    projects =
      Repo.all(
        from p in Project,
          where:
            p.workspace_id == ^workspace_id and is_nil(p.archived_at) and
              ilike(p.name, ^pattern),
          order_by: [desc: p.inserted_at],
          limit: @limit_per_type,
          select: %{id: p.id, title: p.name, status: p.status}
      )

    agents =
      Repo.all(
        from a in Agent,
          where:
            a.workspace_id == ^workspace_id and is_nil(a.archived_at) and
              (ilike(a.display_name, ^pattern) or ilike(a.role_title, ^pattern)),
          order_by: [asc: a.display_name],
          limit: @limit_per_type,
          select: %{id: a.id, title: a.display_name, subtitle: a.role_title, kind: a.kind}
      )

    knowledge =
      Repo.all(
        from k in KnowledgeItem,
          where: k.workspace_id == ^workspace_id and ilike(k.title, ^pattern),
          order_by: [desc: k.updated_at],
          limit: @limit_per_type,
          select: %{id: k.id, title: k.title, type: k.type}
      )

    json(conn, %{
      data: %{tasks: tasks, projects: projects, agents: agents, knowledge: knowledge}
    })
  end

  def index(conn, _params) do
    json(conn, %{data: %{tasks: [], projects: [], agents: [], knowledge: []}})
  end
end
