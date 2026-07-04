defmodule Mokaid.Drive do
  @moduledoc """
  Drive-like file system: folders, files, versions, trash and activity.
  Files live in S3 (MinIO locally); only metadata lives in PostgreSQL.
  """

  import Ecto.Query

  alias Mokaid.Drive.{DriveItem, DriveItemActivityEvent, DriveItemVersion}
  alias Mokaid.Repo

  def get_item(workspace_id, id) do
    Repo.one(
      from d in DriveItem,
        where: d.workspace_id == ^workspace_id and d.id == ^id and d.status != "deleted",
        preload: [
          :versions,
          created_by_member: :user,
          created_by_agent: [],
          last_modified_by_member: :user
        ]
    )
  end

  def list_children(workspace_id, parent_id) do
    from(d in DriveItem,
      where: d.workspace_id == ^workspace_id and d.status == "active",
      preload: [created_by_member: :user, created_by_agent: []],
      order_by: [desc: d.kind == "folder", asc: d.name]
    )
    |> filter_parent(parent_id)
    |> Repo.all()
  end

  defp filter_parent(query, nil), do: where(query, [d], is_nil(d.parent_id))
  defp filter_parent(query, parent_id), do: where(query, [d], d.parent_id == ^parent_id)

  def list_trash(workspace_id) do
    Repo.all(
      from d in DriveItem,
        where: d.workspace_id == ^workspace_id and d.status == "trashed",
        preload: [created_by_member: :user],
        order_by: [desc: d.trashed_at]
    )
  end

  def create_folder(workspace_id, attrs, actor \\ nil) do
    result =
      %DriveItem{}
      |> DriveItem.changeset(
        attrs
        |> Map.merge(%{"workspace_id" => workspace_id, "kind" => "folder"})
        |> Map.merge(actor_attrs(actor))
      )
      |> Repo.insert()

    with {:ok, folder} <- result do
      record_activity(folder, actor, "folder.created")
      {:ok, folder}
    end
  end

  def create_file(workspace_id, attrs, actor \\ nil) do
    Repo.transaction(fn ->
      with {:ok, file} <-
             %DriveItem{}
             |> DriveItem.changeset(
               attrs
               |> Map.merge(%{"workspace_id" => workspace_id, "kind" => "file"})
               |> Map.merge(actor_attrs(actor))
             )
             |> Repo.insert(),
           {:ok, _version} <- create_version(file, actor, "Initial upload") do
        record_activity(file, actor, "file.uploaded")
        file
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  def create_version(%DriveItem{} = item, actor, summary) do
    next_version =
      Repo.aggregate(
        from(v in DriveItemVersion, where: v.drive_item_id == ^item.id),
        :count
      ) + 1

    %DriveItemVersion{}
    |> DriveItemVersion.changeset(
      %{
        "workspace_id" => item.workspace_id,
        "drive_item_id" => item.id,
        "version_number" => next_version,
        "storage_key" => item.storage_key,
        "size_bytes" => item.size_bytes,
        "checksum" => item.checksum,
        "change_summary" => summary
      }
      |> Map.merge(actor_attrs(actor))
    )
    |> Repo.insert()
  end

  def update_item(%DriveItem{} = item, attrs, actor \\ nil) do
    result =
      item
      |> DriveItem.changeset(
        attrs
        |> Map.put("workspace_id", item.workspace_id)
        |> Map.merge(modifier_attrs(actor))
      )
      |> Repo.update()

    with {:ok, updated} <- result do
      event = if Map.has_key?(attrs, "name"), do: "file.renamed", else: "file.updated"
      record_activity(updated, actor, event)
      {:ok, updated}
    end
  end

  def trash_item(%DriveItem{} = item, actor \\ nil) do
    result =
      item
      |> Ecto.Changeset.change(status: "trashed", trashed_at: DateTime.utc_now())
      |> Repo.update()

    with {:ok, trashed} <- result do
      record_activity(trashed, actor, "file.deleted")
      {:ok, trashed}
    end
  end

  def restore_item(%DriveItem{} = item, actor \\ nil) do
    result =
      item
      |> Ecto.Changeset.change(status: "active", trashed_at: nil)
      |> Repo.update()

    with {:ok, restored} <- result do
      record_activity(restored, actor, "file.restored")
      {:ok, restored}
    end
  end

  @doc "Creates the default folder tree for a new project. Returns the root project folder."
  def create_project_folder_tree(project, subfolder_names) do
    projects_root = ensure_system_folder(project.workspace_id, "Projects")

    {:ok, project_folder} =
      create_folder(project.workspace_id, %{
        "name" => project.name,
        "parent_id" => projects_root.id,
        "linked_project_id" => project.id,
        "is_system_folder" => true,
        "visibility" => "project"
      })

    Enum.each(subfolder_names, fn name ->
      {:ok, _} =
        create_folder(project.workspace_id, %{
          "name" => name,
          "parent_id" => project_folder.id,
          "linked_project_id" => project.id,
          "is_system_folder" => true,
          "visibility" => "project"
        })
    end)

    {:ok, project_folder}
  end

  @doc "Finds or creates a top-level system folder (Projects, Agents, Shared, Uploads...)."
  def ensure_system_folder(workspace_id, name) do
    case Repo.one(
           from d in DriveItem,
             where:
               d.workspace_id == ^workspace_id and is_nil(d.parent_id) and d.name == ^name and
                 d.kind == "folder" and d.status == "active"
         ) do
      nil ->
        {:ok, folder} =
          create_folder(workspace_id, %{"name" => name, "is_system_folder" => true})

        folder

      folder ->
        folder
    end
  end

  def list_activity(workspace_id, drive_item_id, limit \\ 50) do
    Repo.all(
      from e in DriveItemActivityEvent,
        where: e.workspace_id == ^workspace_id and e.drive_item_id == ^drive_item_id,
        order_by: [desc: e.occurred_at],
        limit: ^limit
    )
  end

  def record_activity(item, actor, event_type, metadata \\ %{}) do
    {actor_type, actor_id, actor_name} =
      case actor do
        %Mokaid.Members.Member{id: id, user: %{full_name: name}} -> {"member", id, name}
        %Mokaid.Members.Member{id: id} -> {"member", id, nil}
        %Mokaid.Agents.Agent{id: id, display_name: name} -> {"agent", id, name}
        _ -> {"system", nil, nil}
      end

    %DriveItemActivityEvent{}
    |> DriveItemActivityEvent.changeset(%{
      "workspace_id" => item.workspace_id,
      "drive_item_id" => item.id,
      "actor_type" => actor_type,
      "actor_id" => actor_id,
      "actor_name" => actor_name,
      "event_type" => event_type,
      "metadata" => metadata
    })
    |> Repo.insert()
  end

  defp actor_attrs(%Mokaid.Members.Member{id: id}),
    do: %{"created_by_member_id" => id, "owner_member_id" => id}

  defp actor_attrs(%Mokaid.Agents.Agent{id: id}),
    do: %{"created_by_agent_id" => id, "owner_agent_id" => id}

  defp actor_attrs(_), do: %{}

  defp modifier_attrs(%Mokaid.Members.Member{id: id}), do: %{"last_modified_by_member_id" => id}
  defp modifier_attrs(%Mokaid.Agents.Agent{id: id}), do: %{"last_modified_by_agent_id" => id}
  defp modifier_attrs(_), do: %{}
end
