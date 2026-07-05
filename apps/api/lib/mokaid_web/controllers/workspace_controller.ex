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

  def upload_logo(conn, %{"id" => id, "file" => %Plug.Upload{} = file}) do
    with :ok <- authorize_same_workspace(conn, id),
         :ok <- Permissions.authorize(current_member(conn), "workspace.update"),
         :ok <- validate_logo_file(file),
         %{} = workspace <- Workspaces.get_workspace(id),
         {:ok, updated} <- Workspaces.upload_logo(workspace, file) do
      Audit.log(id, current_member(conn), "workspace.upload_logo", "workspace", id, %{})
      json(conn, %{data: Serializer.workspace(updated)})
    else
      {:error, :invalid_image} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_image", message: "Logo must be a PNG, JPG, WebP or GIF image"}})
    end
  end

  def upload_logo(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: %{code: "missing_file", message: "Expected multipart field \"file\""}})
  end

  def logo(conn, %{"id" => id}) do
    with :ok <- authorize_same_workspace(conn, id),
         :ok <- Permissions.authorize(current_member(conn), "workspace.view"),
         %{} = workspace <- Workspaces.get_workspace(id),
         key when is_binary(key) and key != "" <- Workspaces.logo_storage_key(workspace),
         {:ok, body, content_type} <- Mokaid.Storage.get_object(key) do
      conn
      |> put_resp_content_type(content_type)
      |> put_resp_header("cache-control", "private, max-age=300")
      |> send_resp(200, body)
    else
      nil ->
        conn |> put_status(:not_found) |> json(%{error: %{code: "not_found", message: "No logo uploaded"}})

      {:error, _} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "not_found", message: "Logo file not found"}})
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

  defp validate_logo_file(%Plug.Upload{content_type: ct, filename: name}) do
    ext = name |> Path.extname() |> String.downcase()
    ext_ok = ext in ~w(.jpg .jpeg .png .webp .gif .ico)
    type_ok = is_binary(ct) and String.starts_with?(ct, "image/")

    if ext_ok or type_ok, do: :ok, else: {:error, :invalid_image}
  end
end
