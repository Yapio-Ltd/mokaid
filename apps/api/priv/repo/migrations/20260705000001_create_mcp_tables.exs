defmodule Mokaid.Repo.Migrations.CreateMcpTables do
  use Ecto.Migration

  def change do
    # Catalog of MCP servers (seeded, workspace-independent).
    create table(:mcp_servers) do
      add :key, :string, null: false
      add :name, :string, null: false
      add :category, :string, null: false
      add :description, :text
      add :logo_slug, :string
      add :featured, :boolean, null: false, default: false
      add :auth_kind, :string, null: false, default: "api_key"
      add :transport, :string, null: false, default: "http"
      add :server_url, :string
      add :docs_url, :string
      add :capabilities, {:array, :string}, null: false, default: []
      add :enabled, :boolean, null: false, default: true

      timestamps()
    end

    create unique_index(:mcp_servers, [:key])
    create index(:mcp_servers, [:category])

    # Per-workspace installation of a server (credentials encrypted at rest).
    create table(:mcp_installations) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :server_id, references(:mcp_servers, on_delete: :delete_all), null: false
      add :status, :string, null: false, default: "pending"
      add :connected_account, :string
      add :connected_by_member_id, references(:workspace_members, on_delete: :nilify_all)
      add :encrypted_credentials, :binary
      add :settings, :map, null: false, default: %{}
      add :error, :text
      add :last_used_at, :utc_datetime_usec

      timestamps()
    end

    create unique_index(:mcp_installations, [:workspace_id, :server_id])
    create index(:mcp_installations, [:workspace_id, :status])

    # Explicit agent <-> installation permissions (the permission matrix).
    create table(:agent_mcp_grants) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :agent_id, references(:agents, on_delete: :delete_all), null: false
      add :installation_id, references(:mcp_installations, on_delete: :delete_all), null: false
      add :granted, :boolean, null: false, default: true
      add :granted_by_member_id, references(:workspace_members, on_delete: :nilify_all)

      timestamps()
    end

    create unique_index(:agent_mcp_grants, [:agent_id, :installation_id])
    create index(:agent_mcp_grants, [:workspace_id])
    create index(:agent_mcp_grants, [:installation_id])
  end
end
