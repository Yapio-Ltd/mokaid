defmodule MokaidWeb.ProjectController do
  use MokaidWeb, :controller

  alias Mokaid.Projects
  alias MokaidWeb.JSON, as: Serializer

  def index(conn, params) do
    with :ok <- Permissions.authorize(current_member(conn), "projects.view") do
      projects = Projects.list_projects(workspace_id(conn), params)
      counts = Projects.counts(workspace_id(conn))
      activity = Projects.list_activity(workspace_id(conn))

      json(conn, %{
        data: Enum.map(projects, &Serializer.project/1),
        meta: %{counts: counts, activity: Enum.map(activity, &activity_json/1)}
      })
    end
  end

  def create(conn, params) do
    with :ok <- Permissions.authorize(current_member(conn), "projects.create"),
         {:ok, project} <-
           Projects.create_project(workspace_id(conn), params, current_member(conn)) do
      conn
      |> put_status(:created)
      |> json(%{data: Serializer.project(project)})
    end
  end

  def show(conn, %{"id" => id}) do
    with :ok <- Permissions.authorize(current_member(conn), "projects.view"),
         %{} = project <- Projects.get_project(workspace_id(conn), id) do
      json(conn, %{data: Serializer.project(project)})
    end
  end

  def update(conn, %{"id" => id} = params) do
    with :ok <- Permissions.authorize(current_member(conn), "projects.update"),
         %{} = project <- Projects.get_project(workspace_id(conn), id),
         {:ok, updated} <- Projects.update_project(project, params, current_member(conn)) do
      json(conn, %{data: Serializer.project(updated)})
    end
  end

  def delete(conn, %{"id" => id}) do
    with :ok <- Permissions.authorize(current_member(conn), "projects.delete"),
         %{} = project <- Projects.get_project(workspace_id(conn), id),
         {:ok, _} <- Projects.delete_project(project) do
      json(conn, %{ok: true})
    end
  end

  defp activity_json(event) do
    %{
      id: event.id,
      project_id: event.project_id,
      actor_type: event.actor_type,
      actor_name: event.actor_name,
      event_type: event.event_type,
      metadata: event.metadata,
      occurred_at: event.occurred_at
    }
  end
end
