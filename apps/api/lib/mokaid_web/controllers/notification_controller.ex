defmodule MokaidWeb.NotificationController do
  use MokaidWeb, :controller

  alias Mokaid.Notifications
  alias MokaidWeb.JSON, as: Serializer

  def index(conn, _params) do
    notifications = Notifications.list_for_user(workspace_id(conn), current_user(conn).id)
    json(conn, %{data: Enum.map(notifications, &Serializer.notification/1)})
  end

  def mark_read(conn, %{"id" => id}) do
    with {:ok, notification} <-
           Notifications.mark_read(workspace_id(conn), current_user(conn).id, id) do
      json(conn, %{data: Serializer.notification(notification)})
    end
  end
end
