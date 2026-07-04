defmodule Mokaid.Repo.Migrations.CreateIdentityTables do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :email, :citext, null: false
      add :cognito_sub, :string
      add :hashed_password, :string
      add :full_name, :string, null: false
      add :avatar_url, :string
      add :locale, :string, default: "en"
      add :timezone, :string, default: "UTC"
      add :status, :string, null: false, default: "active"
      add :last_login_at, :utc_datetime_usec
      add :mfa_enabled, :boolean, null: false, default: false

      timestamps()
    end

    create unique_index(:users, [:email])
    create unique_index(:users, [:cognito_sub])

    create table(:workspaces) do
      add :name, :string, null: false
      add :slug, :string, null: false
      add :logo_url, :string
      add :description, :text
      add :industry, :string
      add :timezone, :string, default: "UTC"
      add :date_format, :string, default: "MMM D, YYYY"
      add :time_format, :string, default: "12h"
      add :language, :string, default: "en"
      add :default_landing_page, :string, default: "dashboard"
      add :feature_toggles, :map, null: false, default: %{}
      add :usage_limits, :map, null: false, default: %{}
      add :settings, :map, null: false, default: %{}
      add :deleted_at, :utc_datetime_usec

      timestamps()
    end

    create unique_index(:workspaces, [:slug])

    create table(:roles) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all)
      add :name, :string, null: false
      add :description, :string
      add :is_system, :boolean, null: false, default: false

      timestamps()
    end

    create unique_index(:roles, [:workspace_id, :name])

    create table(:permissions) do
      add :key, :string, null: false
      add :description, :string

      timestamps()
    end

    create unique_index(:permissions, [:key])

    create table(:role_permissions) do
      add :role_id, references(:roles, on_delete: :delete_all), null: false
      add :permission_id, references(:permissions, on_delete: :delete_all), null: false

      timestamps()
    end

    create unique_index(:role_permissions, [:role_id, :permission_id])

    create table(:teams) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :color, :string
      add :description, :string

      timestamps()
    end

    create unique_index(:teams, [:workspace_id, :name])

    create table(:workspace_members) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :role_id, references(:roles, on_delete: :nilify_all)
      add :team_id, references(:teams, on_delete: :nilify_all)
      add :status, :string, null: false, default: "active"
      add :title, :string
      add :manager_member_id, references(:workspace_members, on_delete: :nilify_all)
      add :joined_at, :utc_datetime_usec
      add :last_active_at, :utc_datetime_usec
      add :leave_balances, :map, null: false, default: %{}
      add :settings, :map, null: false, default: %{}

      timestamps()
    end

    create unique_index(:workspace_members, [:workspace_id, :user_id])
    create index(:workspace_members, [:workspace_id, :status])

    create table(:member_invites) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :email, :citext, null: false
      add :role_id, references(:roles, on_delete: :nilify_all)
      add :team_id, references(:teams, on_delete: :nilify_all)
      add :token, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :invited_by_member_id, references(:workspace_members, on_delete: :nilify_all)
      add :expires_at, :utc_datetime_usec

      timestamps()
    end

    create unique_index(:member_invites, [:token])
    create index(:member_invites, [:workspace_id, :status])
  end
end
