defmodule MokaidWeb.WorkspaceController do
  use MokaidWeb, :controller

  alias Mokaid.Audit
  alias Mokaid.Workspaces
  alias MokaidWeb.JSON, as: Serializer

  def index(conn, _params) do
    workspaces = Workspaces.list_workspaces_for_user(current_user(conn).id)
    json(conn, %{data: Enum.map(workspaces, &Serializer.workspace/1)})
  end

  def create(conn, params) do
    with {:ok, workspace} <- Workspaces.create_workspace(params, current_user(conn)) do
      conn
      |> put_status(:created)
      |> json(%{data: Serializer.workspace(workspace)})
    end
  end

  def show(conn, %{"id" => id}) do
    with :ok <- authorize_same_workspace(conn, id),
         :ok <- Permissions.authorize(current_member(conn), "workspace.view"),
         %{} = workspace <- Workspaces.get_workspace(id) do
      json(conn, %{data: Serializer.workspace(workspace)})
    end
  end

  def update(conn, %{"id" => id} = params) do
    with :ok <- authorize_same_workspace(conn, id),
         :ok <- Permissions.authorize(current_member(conn), "workspace.update"),
         %{} = workspace <- Workspaces.get_workspace(id),
         {:ok, updated} <- Workspaces.update_workspace(workspace, params) do
      Audit.log(id, current_member(conn), "workspace.update", "workspace", id, %{})
      json(conn, %{data: Serializer.workspace(updated)})
    end
  end

  def delete(conn, %{"id" => id}) do
    with :ok <- authorize_same_workspace(conn, id),
         :ok <- Permissions.authorize(current_member(conn), "workspace.delete"),
         %{} = workspace <- Workspaces.get_workspace(id),
         {:ok, _} <- Workspaces.soft_delete_workspace(workspace) do
      Audit.log(id, current_member(conn), "workspace.delete", "workspace", id, %{})
      json(conn, %{ok: true})
    end
  end

  defp authorize_same_workspace(conn, id) do
    if workspace_id(conn) == id, do: :ok, else: {:error, :forbidden}
  end
end
