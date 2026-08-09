defmodule Mokaid.Repo.Migrations.CreateAgentSchedules do
  use Ecto.Migration

  def change do
    create table(:agent_schedules, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :cron_expression, :string, null: false
      add :timezone, :string, null: false, default: "Etc/UTC"
      add :prompt, :text, null: false
      add :enabled, :boolean, null: false, default: true
      add :last_run_at, :utc_datetime_usec
      add :runs_count, :integer, null: false, default: 0
      add :max_runs, :integer
      add :expires_at, :utc_datetime_usec

      add :created_by_member_id,
          references(:workspace_members, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create index(:agent_schedules, [:workspace_id])
    create index(:agent_schedules, [:agent_id])
    create index(:agent_schedules, [:enabled])
  end
end
