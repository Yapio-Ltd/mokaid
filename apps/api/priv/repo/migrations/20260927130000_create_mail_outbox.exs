defmodule Mokaid.Repo.Migrations.CreateMailOutbox do
  use Ecto.Migration

  def change do
    create table(:mail_outbox, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :member_id, references(:workspace_members, type: :binary_id, on_delete: :nilify_all)
      add :account_id, references(:mail_accounts, type: :binary_id, on_delete: :nilify_all)
      add :request_id, :uuid, null: false
      add :request_hash, :binary, null: false
      add :status, :string, null: false
      add :error, :string
      add :message_id, references(:mail_messages, type: :binary_id, on_delete: :nilify_all)
      add :provider_message_id, :string
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:mail_outbox, [:workspace_id, :member_id, :request_id])
    create index(:mail_outbox, [:account_id])
  end
end
