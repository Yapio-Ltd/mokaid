defmodule Mokaid.Repo.Migrations.CreateWebSessions do
  use Ecto.Migration

  def change do
    create table(:web_sessions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :token_hash, :binary, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :revoked_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:web_sessions, [:token_hash])
    create index(:web_sessions, [:user_id])
    create index(:web_sessions, [:expires_at])
  end
end
