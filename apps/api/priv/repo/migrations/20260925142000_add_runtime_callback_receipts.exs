defmodule Mokaid.Repo.Migrations.AddRuntimeCallbackReceipts do
  use Ecto.Migration

  def change do
    alter table(:task_approval_requests) do
      add :operation_key, :string
    end

    create unique_index(:task_approval_requests, [:run_id, :operation_key],
             where: "operation_key IS NOT NULL",
             name: :task_approval_operation_key_unique
           )

    alter table(:managed_runtime_runs) do
      add :finalized_at, :utc_datetime_usec
      add :final_comment_id, references(:task_comments, type: :binary_id, on_delete: :nilify_all)
    end
  end
end
