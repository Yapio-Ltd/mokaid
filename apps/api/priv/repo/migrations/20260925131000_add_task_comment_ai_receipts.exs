defmodule Mokaid.Repo.Migrations.AddTaskCommentAiReceipts do
  use Ecto.Migration

  def change do
    alter table(:task_comments) do
      add :ai_handled_at, :utc_datetime_usec
    end
  end
end
