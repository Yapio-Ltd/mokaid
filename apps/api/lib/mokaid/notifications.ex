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

  @doc "Notifies every workspace member whose role is in `role_names` (e.g. approvers)."
  def notify_roles(workspace_id, role_names, kind, title, opts \\ []) do
    user_ids =
      Repo.all(
        from m in Mokaid.Members.Member,
          join: r in assoc(m, :role),
          where:
            m.workspace_id == ^workspace_id and m.status == "active" and r.name in ^role_names,
          select: m.user_id
      )

    Enum.each(user_ids, &notify(workspace_id, &1, kind, title, opts))
    :ok
  end

  @doc "Notifies the user behind a member id. No-op when the member is missing."
  def notify_member(workspace_id, member_id, kind, title, opts \\ [])
  def notify_member(_workspace_id, nil, _kind, _title, _opts), do: :ok

  def notify_member(workspace_id, member_id, kind, title, opts) do
    case Repo.one(
           from m in Mokaid.Members.Member,
             where: m.workspace_id == ^workspace_id and m.id == ^member_id,
             select: m.user_id
         ) do
      nil -> :ok
      user_id -> notify(workspace_id, user_id, kind, title, opts)
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
