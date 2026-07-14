defmodule Mokaid.Projects do
  @moduledoc "Projects, project members/agents, activity and default drive folders."

  import Ecto.Query

  alias Mokaid.Drive
  alias Mokaid.Projects.{Project, ProjectActivityEvent, ProjectAgent, ProjectMember}
  alias Mokaid.Realtime
  alias Mokaid.Repo

  @default_folders ~w(Briefs Design Development Reports) ++
                     ["AI Outputs", "Client Files", "Archives"]

  @preloads [
    :tasks,
    :project_agents,
    owner_member: :user,
    project_members: [member: :user]
  ]

  def get_project(workspace_id, id) do
    Repo.one(
      from p in Project,
        where: p.workspace_id == ^workspace_id and p.id == ^id,
        preload: ^@preloads
    )
  end

  def list_projects(workspace_id, filters \\ %{}) do
    from(p in Project,
      where: p.workspace_id == ^workspace_id and is_nil(p.archived_at),
      preload: ^@preloads,
      order_by: [desc: p.inserted_at]
    )
    |> maybe_filter_status(filters["status"])
    |> Repo.all()
  end

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, ""), do: query
  defp maybe_filter_status(query, status), do: where(query, [p], p.status == ^status)

  def create_project(workspace_id, attrs, created_by \\ nil) do
    Repo.transaction(fn ->
      with {:ok, project} <-
             %Project{}
             |> Project.changeset(
               Map.merge(attrs, %{
                 "workspace_id" => workspace_id,
                 "owner_member_id" => attrs["owner_member_id"] || (created_by && created_by.id)
               })
             )
             |> Repo.insert(),
           {:ok, folder} <- Drive.create_project_folder_tree(project, @default_folders),
           {:ok, project} <-
             project |> Ecto.Changeset.change(drive_folder_id: folder.id) |> Repo.update() do
        record_activity(project, created_by, "project.created")
        Realtime.broadcast_workspace(workspace_id, "project.created", %{project_id: project.id})
        Repo.preload(project, @preloads)
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  def update_project(%Project{} = project, attrs, actor \\ nil) do
    result =
      project
      |> Project.changeset(Map.put(attrs, "workspace_id", project.workspace_id))
      |> Repo.update()

    with {:ok, updated} <- result do
      record_activity(updated, actor, "project.updated")

      Realtime.broadcast_workspace(project.workspace_id, "project.updated", %{
        project_id: updated.id
      })

      {:ok, Repo.preload(updated, @preloads, force: true)}
    end
  end

  def archive_project(%Project{} = project) do
    project
    |> Ecto.Changeset.change(archived_at: DateTime.utc_now(), status: "archived")
    |> Repo.update()
  end

  @doc """
  Permanently deletes a project and every task linked to it.
  Active AI runs on those tasks are canceled first so agents are released.
  """
  def delete_project(%Project{} = project) do
    Repo.transaction(fn ->
      tasks =
        Repo.all(
          from t in Mokaid.Tasks.Task,
            where: t.project_id == ^project.id
        )

      Enum.each(tasks, fn task ->
        case Mokaid.Tasks.delete_task(task) do
          {:ok, _} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

      case Repo.delete(project) do
        {:ok, deleted} ->
          Realtime.broadcast_workspace(project.workspace_id, "project.deleted", %{
            project_id: deleted.id
          })

          deleted

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  def add_agent(%Project{} = project, agent_id) do
    %ProjectAgent{}
    |> ProjectAgent.changeset(%{
      "workspace_id" => project.workspace_id,
      "project_id" => project.id,
      "agent_id" => agent_id
    })
    |> Repo.insert(on_conflict: :nothing)
  end

  def add_member(%Project{} = project, member_id, role \\ "contributor") do
    %ProjectMember{}
    |> ProjectMember.changeset(%{
      "workspace_id" => project.workspace_id,
      "project_id" => project.id,
      "member_id" => member_id,
      "role" => role
    })
    |> Repo.insert(on_conflict: :nothing)
  end

  def list_activity(workspace_id, limit \\ 30) do
    Repo.all(
      from e in ProjectActivityEvent,
        where: e.workspace_id == ^workspace_id,
        order_by: [desc: e.occurred_at],
        limit: ^limit
    )
  end

  def record_activity(project, actor, event_type, metadata \\ %{}) do
    {actor_type, actor_id, actor_name} =
      case actor do
        %Mokaid.Members.Member{id: id, user: %{full_name: name}} -> {"member", id, name}
        %Mokaid.Members.Member{id: id} -> {"member", id, nil}
        %Mokaid.Agents.Agent{id: id, display_name: name} -> {"agent", id, name}
        _ -> {"system", nil, nil}
      end

    %ProjectActivityEvent{}
    |> ProjectActivityEvent.changeset(%{
      "workspace_id" => project.workspace_id,
      "project_id" => project.id,
      "actor_type" => actor_type,
      "actor_id" => actor_id,
      "actor_name" => actor_name,
      "event_type" => event_type,
      "metadata" => metadata
    })
    |> Repo.insert()
  end

  def counts(workspace_id) do
    base = from p in Project, where: p.workspace_id == ^workspace_id and is_nil(p.archived_at)

    %{
      total: Repo.aggregate(base, :count),
      active: Repo.aggregate(where(base, [p], p.status == "active"), :count),
      completed: Repo.aggregate(where(base, [p], p.status == "completed"), :count),
      on_hold: Repo.aggregate(where(base, [p], p.status == "on_hold"), :count)
    }
  end
end
