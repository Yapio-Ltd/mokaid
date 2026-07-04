defmodule MokaidWeb.DriveController do
  use MokaidWeb, :controller

  alias Mokaid.Drive
  alias MokaidWeb.JSON, as: Serializer

  def index(conn, params) do
    with :ok <- Permissions.authorize(current_member(conn), "drive.view") do
      items = Drive.list_children(workspace_id(conn), params["parent_id"])
      json(conn, %{data: Enum.map(items, &Serializer.drive_item/1)})
    end
  end

  def children(conn, %{"id" => id}) do
    with :ok <- Permissions.authorize(current_member(conn), "drive.view") do
      items = Drive.list_children(workspace_id(conn), id)
      json(conn, %{data: Enum.map(items, &Serializer.drive_item/1)})
    end
  end

  def trash(conn, _params) do
    with :ok <- Permissions.authorize(current_member(conn), "drive.view") do
      items = Drive.list_trash(workspace_id(conn))
      json(conn, %{data: Enum.map(items, &Serializer.drive_item/1)})
    end
  end

  def create(conn, %{"kind" => "folder"} = params) do
    with :ok <- Permissions.authorize(current_member(conn), "drive.create_folder"),
         {:ok, folder} <- Drive.create_folder(workspace_id(conn), params, current_member(conn)) do
      conn
      |> put_status(:created)
      |> json(%{data: Serializer.drive_item(folder)})
    end
  end

  def create(conn, params) do
    with :ok <- Permissions.authorize(current_member(conn), "drive.upload"),
         {:ok, file} <- Drive.create_file(workspace_id(conn), params, current_member(conn)) do
      conn
      |> put_status(:created)
      |> json(%{data: Serializer.drive_item(file)})
    end
  end

  def show(conn, %{"id" => id}) do
    with :ok <- Permissions.authorize(current_member(conn), "drive.view"),
         %{} = item <- Drive.get_item(workspace_id(conn), id) do
      activity = Drive.list_activity(workspace_id(conn), id)

      json(conn, %{
        data: Serializer.drive_item(item),
        meta: %{
          activity:
            Enum.map(activity, fn e ->
              %{
                id: e.id,
                actor_type: e.actor_type,
                actor_name: e.actor_name,
                event_type: e.event_type,
                occurred_at: e.occurred_at
              }
            end)
        }
      })
    end
  end

  def update(conn, %{"id" => id} = params) do
    with :ok <- Permissions.authorize(current_member(conn), "drive.rename"),
         %{} = item <- Drive.get_item(workspace_id(conn), id),
         {:ok, updated} <- Drive.update_item(item, params, current_member(conn)) do
      json(conn, %{data: Serializer.drive_item(updated)})
    end
  end

  def delete(conn, %{"id" => id}) do
    with :ok <- Permissions.authorize(current_member(conn), "drive.delete"),
         %{} = item <- Drive.get_item(workspace_id(conn), id),
         {:ok, trashed} <- Drive.trash_item(item, current_member(conn)) do
      json(conn, %{data: Serializer.drive_item(trashed)})
    end
  end

  def restore(conn, %{"id" => id}) do
    with :ok <- Permissions.authorize(current_member(conn), "drive.restore"),
         %{} = item <- get_trashed_item(workspace_id(conn), id),
         {:ok, restored} <- Drive.restore_item(item, current_member(conn)) do
      json(conn, %{data: Serializer.drive_item(restored)})
    end
  end

  defp get_trashed_item(workspace_id, id) do
    import Ecto.Query

    Mokaid.Repo.one(
      from d in Mokaid.Drive.DriveItem,
        where: d.workspace_id == ^workspace_id and d.id == ^id and d.status == "trashed"
    )
  end
end
