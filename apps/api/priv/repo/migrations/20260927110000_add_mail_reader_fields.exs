defmodule Mokaid.Repo.Migrations.AddMailReaderFields do
  use Ecto.Migration

  def change do
    alter table(:mail_messages) do
      add :body_html, :text
      add :rfc_message_id, :text
      add :references, {:array, :text}, null: false, default: []
      add :attachments, {:array, :map}, null: false, default: []
      add :provider_metadata, :map, null: false, default: %{}
      add :is_read, :boolean, null: false, default: false
      add :is_starred, :boolean, null: false, default: false
    end

    create index(:mail_messages, [:workspace_id, :folder, :received_at])

    execute "UPDATE mail_messages SET is_read = NOT ('UNREAD' = ANY(labels)), is_starred = 'STARRED' = ANY(labels) WHERE mail_account_id IN (SELECT id FROM mail_accounts WHERE provider = 'gmail')",
            "SELECT 1"
  end
end
