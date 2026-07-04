defmodule Mokaid.Notifications do
  @moduledoc "In-app notifications."

  import Ecto.Query

  alias Mokaid.Notifications.Notification
  alias Mokaid.Realtime
  alias Mokaid.Repo

  def list_for_user(workspace_id, user_id, limit \\ 50) do
    Repo.all(
      from n in Notification,
        where: n.workspace_id == ^workspace_id and n.user_id == ^user_id,
        order_by: [desc: n.inserted_at],
        limit: ^limit
    )
  end

  def notify(workspace_id, user_id, kind, title, opts \\ []) do
    result =
      %Notification{}
      |> Notification.changeset(%{
        "workspace_id" => workspace_id,
        "user_id" => user_id,
        "kind" => kind,
        "title" => title,
        "body" => Keyword.get(opts, :body),
        "resource_type" => Keyword.get(opts, :resource_type),
        "resource_id" => Keyword.get(opts, :resource_id)
      })
      |> Repo.insert()

    with {:ok, notification} <- result do
      Realtime.broadcast_notification(user_id, %{
        notification_id: notification.id,
        kind: kind,
        title: title
      })

      {:ok, notification}
    end
  end

  def mark_read(workspace_id, user_id, id) do
    case Repo.one(
           from n in Notification,
             where: n.workspace_id == ^workspace_id and n.user_id == ^user_id and n.id == ^id
         ) do
      nil ->
        {:error, :not_found}

      notification ->
        notification
        |> Ecto.Changeset.change(read_at: DateTime.utc_now())
        |> Repo.update()
    end
  end
end
