defmodule Mokaid.Repo.Migrations.CreateAgentTables do
  use Ecto.Migration

  def change do
    create table(:agents) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :linked_user_id, references(:users, on_delete: :nilify_all)
      add :linked_member_id, references(:workspace_members, on_delete: :nilify_all)
      add :kind, :string, null: false
      add :display_name, :string, null: false
      add :slug, :string, null: false
      add :email_alias, :string
      add :avatar_config, :map, null: false, default: %{}
      add :avatar_asset_id, :string
      add :role_title, :string
      add :department, :string
      add :manager_agent_id, references(:agents, on_delete: :nilify_all)
      add :status, :string, null: false, default: "idle"
      add :presence_status, :string, null: false, default: "offline"
      add :control_mode, :string, null: false, default: "ai_controlled"
      add :ai_enabled, :boolean, null: false, default: false
      add :human_takeover_enabled, :boolean, null: false, default: false
      add :skills, {:array, :map}, null: false, default: []
      add :capabilities, :map, null: false, default: %{}
      add :current_task_id, :binary_id
      add :performance_score, :decimal
      add :access_scope, :map, null: false, default: %{}
      add :created_by_member_id, references(:workspace_members, on_delete: :nilify_all)
      add :last_active_at, :utc_datetime_usec
      add :archived_at, :utc_datetime_usec

      timestamps()
    end

    create unique_index(:agents, [:workspace_id, :slug])
    create index(:agents, [:workspace_id, :kind])
    create index(:agents, [:workspace_id, :status])
    create index(:agents, [:linked_user_id])

    create constraint(:agents, :kind_must_be_valid,
             check: "kind IN ('ai', 'human_linked', 'hybrid')"
           )

    create constraint(:agents, :human_linked_requires_user,
             check: "kind != 'human_linked' OR linked_user_id IS NOT NULL"
           )

    create table(:agent_skills) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :agent_id, references(:agents, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :level, :integer, null: false, default: 0
      add :xp, :integer, null: false, default: 0

      timestamps()
    end

    create unique_index(:agent_skills, [:agent_id, :name])

    create table(:agent_capabilities) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :agent_id, references(:agents, on_delete: :delete_all), null: false
      add :key, :string, null: false
      add :config, :map, null: false, default: %{}
      add :enabled, :boolean, null: false, default: true

      timestamps()
    end

    create unique_index(:agent_capabilities, [:agent_id, :key])

    create table(:agent_status_events) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :agent_id, references(:agents, on_delete: :delete_all), null: false
      add :from_status, :string
      add :to_status, :string, null: false
      add :reason, :string
      add :metadata, :map, null: false, default: %{}
      add :occurred_at, :utc_datetime_usec, null: false

      timestamps(updated_at: false)
    end

    create index(:agent_status_events, [:workspace_id, :agent_id, :occurred_at])
  end
end
