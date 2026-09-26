defmodule Mokaid.Repo.Migrations.AddMailOauthFlowsAndMultipleAccounts do
  use Ecto.Migration

  def up do
    drop unique_index(:integration_connections, [:workspace_id, :provider_id])

    create unique_index(:integration_connections, [
             :workspace_id,
             :provider_id,
             :connected_account
           ])

    create table(:mail_oauth_flows, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :member_id, references(:workspace_members, type: :binary_id, on_delete: :delete_all), null: false
      add :status, :string, null: false, default: "pending"
      add :account_id, references(:mail_accounts, type: :binary_id, on_delete: :nilify_all)
      add :error, :string
      add :expires_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:mail_oauth_flows, [:workspace_id, :member_id])
    create index(:mail_oauth_flows, [:expires_at])
  end

  def down do
    drop table(:mail_oauth_flows)
    # Refuse rollback while multiple accounts exist instead of discarding credentials.
    drop unique_index(:integration_connections, [:workspace_id, :provider_id, :connected_account])
    create unique_index(:integration_connections, [:workspace_id, :provider_id])
  end
end
