defmodule Mokaid.Repo.Migrations.AddToolActivityToRuns do
  use Ecto.Migration

  def change do
    alter table(:task_execution_runs) do
      # Chronological tool-call feed streamed by the worker (start/end events
      # with human descriptions) — powers the run timeline in the task panel.
      add :tool_activity, :jsonb, default: "[]", null: false
    end
  end
end
