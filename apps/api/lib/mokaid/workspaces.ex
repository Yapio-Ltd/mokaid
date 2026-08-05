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

  @doc "Workspaces with the caller's role name, for /api/me."
  def list_workspaces_with_role(user_id) do
    Repo.all(
      from w in Workspace,
        join: m in assoc(w, :members),
        join: r in assoc(m, :role),
        where: m.user_id == ^user_id and m.status == "active" and is_nil(w.deleted_at),
        order_by: w.name,
        select: {w, r.name}
    )
  end

  @doc """
  Creates a workspace with its owner membership, an explicit Free
  subscription and a first AI employee — a workspace without an agent cannot
  exist. Everything is atomic: if any step fails, nothing is created.

  Pass `bootstrap: false` to skip the subscription/agent bootstrap (tests
  that need a bare workspace).
  """
  def create_workspace(attrs, owner_user, opts \\ []) do
    attrs = put_default_slug(attrs)
    bootstrap? = Keyword.get(opts, :bootstrap, true)

    Repo.transaction(fn ->
      with {:ok, workspace} <- %Workspace{} |> Workspace.changeset(attrs) |> Repo.insert(),
           {:ok, _roles} <- Members.seed_system_roles(workspace.id),
           {:ok, _member} <- Members.add_owner(workspace.id, owner_user.id),
           :ok <- if(bootstrap?, do: bootstrap_workspace(workspace), else: :ok) do
        workspace
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  # Every workspace starts life billable and staffed: an explicit Free
  # subscription (no lazy "nil subscription = free" states) and a default
  # AI employee the owner can meet in the office right away.
  defp bootstrap_workspace(workspace) do
    case Mokaid.Billing.change_plan(workspace.id, "free") do
      {:ok, _subscription} -> :ok
      # Plan catalog not seeded yet (fresh dev database) — the subscription
      # will be created lazily on the first plan choice or credit grant.
      {:error, :not_found} -> :ok
      {:error, other} -> Repo.rollback(other)
    end

    case Mokaid.Agents.create_bootstrap_agent(workspace.id) do
      {:ok, _agent} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  def update_workspace(%Workspace{} = workspace, attrs) do
    workspace
    |> Workspace.changeset(attrs)
    |> Repo.update()
  end

  def upload_logo(%Workspace{} = workspace, %Plug.Upload{} = file) do
    with {:ok, stored} <- Mokaid.Storage.upload_workspace_logo(workspace.id, file) do
      settings =
        workspace.settings
        |> Kernel.||(%{})
        |> Map.put("logo_storage_key", stored.storage_key)

      update_workspace(workspace, %{"settings" => settings})
    end
  end

  def logo_storage_key(%Workspace{} = workspace) do
    get_in(workspace.settings, ["logo_storage_key"])
  end

  def soft_delete_workspace(%Workspace{} = workspace) do
    workspace
    |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
    |> Repo.update()
  end

  # Callers only need to provide a name; the unique slug is derived here.
  defp put_default_slug(attrs) do
    if is_binary(attrs["slug"]) and attrs["slug"] != "" do
      attrs
    else
      base =
        (attrs["name"] || "workspace")
        |> String.downcase()
        |> String.replace(~r/[^a-z0-9]+/, "-")
        |> String.trim("-")

      suffix = :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)
      Map.put(attrs, "slug", "#{base}-#{suffix}")
    end
  end
end
