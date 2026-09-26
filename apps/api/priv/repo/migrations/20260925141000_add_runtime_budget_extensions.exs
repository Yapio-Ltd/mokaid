defmodule Mokaid.Repo.Migrations.AddRuntimeBudgetExtensions do
  use Ecto.Migration

  def change do
    alter table(:managed_runtime_runs) do
      add :budget_revision, :integer, null: false, default: 0
      add :funding, {:array, :map}, null: false, default: []
    end
  end
end
