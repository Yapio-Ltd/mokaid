defmodule Mokaid.Workspaces do
  @moduledoc "Workspaces, settings, feature toggles and usage limits."

  import Ecto.Query

  alias Mokaid.Members
  alias Mokaid.Repo
  alias Mokaid.Workspaces.Workspace

  def get_workspace(id), do: Repo.get(Workspace, id)

  def get_workspace!(id), do: Repo.get!(Workspace, id)

  def list_workspaces_for_user(user_id) do
    Repo.all(
      from w in Workspace,
        join: m in assoc(w, :members),
        where: m.user_id == ^user_id and m.status == "active" and is_nil(w.deleted_at),
        order_by: w.name
    )
  end

  def create_workspace(attrs, owner_user) do
    Repo.transaction(fn ->
      with {:ok, workspace} <- %Workspace{} |> Workspace.changeset(attrs) |> Repo.insert(),
           {:ok, _roles} <- Members.seed_system_roles(workspace.id),
           {:ok, _member} <- Members.add_owner(workspace.id, owner_user.id) do
        workspace
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  def update_workspace(%Workspace{} = workspace, attrs) do
    workspace
    |> Workspace.changeset(attrs)
    |> Repo.update()
  end

  def soft_delete_workspace(%Workspace{} = workspace) do
    workspace
    |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
    |> Repo.update()
  end
end
