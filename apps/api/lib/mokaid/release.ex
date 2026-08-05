defmodule Mokaid.Release do
  @moduledoc """
  Release tasks executed inside the production container, e.g.:

      bin/mokaid eval "Mokaid.Release.migrate()"
  """

  @app :mokaid

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    seed_catalogs()
  end

  @doc "Seeds integration logos, MCP catalog and 3D asset catalog (idempotent)."
  def seed_catalogs do
    load_app()

    {:ok, _, _} =
      Ecto.Migrator.with_repo(Mokaid.Repo, fn _repo ->
        # Catalog rows first so logo stamp can match keys.
        Mokaid.MCP.seed_catalog()
        Mokaid.Integrations.LogoAssets.seed_all()
        Mokaid.Assets3d.seed_catalog()
      end)
  end

  def seed_integration_logos do
    seed_catalogs()
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  def seed do
    load_app()

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, fn _repo ->
          seeds = Application.app_dir(@app, "priv/repo/seeds.exs")
          if File.exists?(seeds), do: Code.eval_file(seeds)
        end)
    end
  end

  @doc """
  Creates or updates a platform operator (CRM admin). Password is taken from
  arguments or `PLATFORM_ADMIN_PASSWORD` env — never commit secrets to git.

      bin/mokaid eval "Mokaid.Release.provision_platform_admin(\\"email@example.com\\", System.get_env(\\"PLATFORM_ADMIN_PASSWORD\\"))"
  """
  def provision_platform_admin(email, password \\ nil, opts \\ [])

  def provision_platform_admin(email, password, opts) when is_binary(email) do
    load_app()
    password = password || System.get_env("PLATFORM_ADMIN_PASSWORD")
    full_name = Keyword.get(opts, :full_name, "Platform Admin")

    if not is_binary(password) or byte_size(password) < 10 do
      raise "provision_platform_admin requires a password (>= 10 chars) or PLATFORM_ADMIN_PASSWORD"
    end

    {:ok, _, _} =
      Ecto.Migrator.with_repo(Mokaid.Repo, fn _repo ->
        alias Mokaid.{Accounts, Repo}

        user =
          case Accounts.get_user_by_email(email) do
            nil ->
              {:ok, user} =
                Accounts.register_user(%{
                  "email" => email,
                  "full_name" => full_name,
                  "password" => password
                })

              user

            existing ->
              hashed = Bcrypt.hash_pwd_salt(password)

              existing
              |> Ecto.Changeset.change(
                hashed_password: hashed,
                full_name: existing.full_name || full_name,
                status: "active"
              )
              |> Repo.update!()
          end

        user
        |> Ecto.Changeset.change(is_platform_admin: true, status: "active")
        |> Repo.update!()

        IO.puts("provisioned platform admin #{email}")
        :ok
      end)
  end

  @doc """
  Creates or updates a dev-fallback user and attaches them to an existing workspace.
  """
  def provision_dev_user(email, password, opts \\ []) do
    load_app()
    full_name = Keyword.get(opts, :full_name, email |> String.split("@") |> hd())
    workspace_slug = Keyword.get(opts, :workspace_slug, "mokaid-demo")
    role_name = Keyword.get(opts, :role, "Owner")

    {:ok, _, _} =
      Ecto.Migrator.with_repo(Mokaid.Repo, fn _repo ->
        alias Mokaid.{Accounts, Members, Repo, Workspaces}

        user =
          case Accounts.get_user_by_email(email) do
            nil ->
              {:ok, user} =
                Accounts.register_user(%{email: email, full_name: full_name, password: password})

              user

            existing ->
              existing
              |> Mokaid.Accounts.User.registration_changeset(%{
                password: password,
                full_name: existing.full_name
              })
              |> Repo.update!()
          end

        case Repo.get_by(Workspaces.Workspace, slug: workspace_slug) do
          nil ->
            IO.puts("workspace #{workspace_slug} not found")

          workspace ->
            if Members.get_member_for_user(workspace.id, user.id) do
              :ok
            else
              role = Members.get_role_by_name(workspace.id, role_name)

              %Members.Member{}
              |> Members.Member.changeset(%{
                "workspace_id" => workspace.id,
                "user_id" => user.id,
                "role_id" => role.id,
                "status" => "active",
                "joined_at" => DateTime.utc_now()
              })
              |> Repo.insert!()
            end
        end

        IO.puts("provisioned #{email}")
      end)
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
