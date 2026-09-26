defmodule Mokaid.Repo.Migrations.AddManagedRuntimeAccounting do
  use Ecto.Migration

  def change do
    alter table(:workspaces) do
      add :managed_runtime_policy, :map, null: false, default: %{}
    end

    create table(:managed_runtime_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :run_id, references(:task_execution_runs, type: :binary_id, on_delete: :delete_all),
        null: false

      add :status, :string, null: false, default: "reserved"
      add :budget_cents, :integer, null: false
      add :reserved_credits, :integer, null: false
      add :included_reserved, :integer, null: false, default: 0
      add :balance_reserved, :integer, null: false, default: 0
      add :credits_period_start, :utc_datetime_usec
      add :metered_only, :boolean, null: false, default: false
      add :reported_cost_cents, :integer
      add :charged_credits, :integer
      add :usage_status, :string, null: false, default: "unknown"
      add :settled_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:managed_runtime_runs, [:run_id])
    create index(:managed_runtime_runs, [:workspace_id, :status])

    create table(:managed_runtime_participants, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :run_id, references(:task_execution_runs, type: :binary_id, on_delete: :delete_all),
        null: false

      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :participant_id, :string, null: false
      add :lease_expires_at, :utc_datetime_usec, null: false
      add :released_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:managed_runtime_participants, [:run_id, :participant_id])

    create unique_index(:managed_runtime_participants, [:workspace_id, :agent_id],
             where: "released_at IS NULL",
             name: :managed_runtime_active_agent
           )

    create index(:managed_runtime_participants, [:workspace_id, :lease_expires_at])
  end
end
