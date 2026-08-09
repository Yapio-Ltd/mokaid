defmodule Mokaid.Repo.Migrations.CreateMailTables do
  use Ecto.Migration

  def change do
    create table(:mail_accounts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :member_id, references(:workspace_members, type: :binary_id, on_delete: :delete_all),
        null: false

      add :connection_id,
          references(:integration_connections, type: :binary_id, on_delete: :nilify_all)

      add :provider, :string, null: false
      add :email_address, :string, null: false
      add :display_name, :string
      # IMAP/SMTP secrets (password) — Vault AES-GCM, never plaintext.
      add :encrypted_credentials, :binary
      # Non-secret connection settings: imap_host, imap_port, smtp_host…
      add :settings, :map, null: false, default: %{}
      add :status, :string, null: false, default: "active"
      add :error_message, :text
      # Incremental cursors: gmail history_id / graph delta_link / imap uid map.
      add :sync_state, :map, null: false, default: %{}
      add :watch_expires_at, :utc_datetime_usec
      add :subscription_id, :string
      add :subscription_expires_at, :utc_datetime_usec
      add :last_sync_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:mail_accounts, [:workspace_id, :provider, :email_address])
    create index(:mail_accounts, [:workspace_id])
    create index(:mail_accounts, [:member_id])
    create index(:mail_accounts, [:status])
    create index(:mail_accounts, [:subscription_id])

    create table(:mail_messages, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :mail_account_id, references(:mail_accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :provider_message_id, :string, null: false
      add :thread_id, :string
      add :from_name, :string
      add :from_email, :string
      add :to_emails, {:array, :string}, null: false, default: []
      add :cc_emails, {:array, :string}, null: false, default: []
      add :subject, :text
      add :snippet, :text
      add :body_text, :text
      add :folder, :string
      add :labels, {:array, :string}, null: false, default: []
      add :has_attachments, :boolean, null: false, default: false
      add :received_at, :utc_datetime_usec

      add :ai_importance, :integer
      add :ai_category, :string
      add :ai_summary, :text
      add :matched_rule_ids, {:array, :binary_id}, null: false, default: []
      add :analyzed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:mail_messages, [:mail_account_id, :provider_message_id])
    create index(:mail_messages, [:workspace_id, :received_at])
    create index(:mail_messages, [:mail_account_id, :received_at])
    create index(:mail_messages, [:workspace_id, :ai_importance])

    create table(:mail_rules, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :mail_account_id,
          references(:mail_accounts, type: :binary_id, on_delete: :delete_all)

      add :created_by_member_id,
          references(:workspace_members, type: :binary_id, on_delete: :nilify_all)

      add :name, :string, null: false
      add :prompt, :text, null: false
      add :action, :string, null: false, default: "notify"
      add :enabled, :boolean, null: false, default: true
      add :last_matched_at, :utc_datetime_usec
      add :matches_count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create index(:mail_rules, [:workspace_id])
    create index(:mail_rules, [:mail_account_id])
    create index(:mail_rules, [:enabled])
  end
end
