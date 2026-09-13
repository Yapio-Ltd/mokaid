defmodule Mokaid.Repo.Migrations.CreateDesktopSessions do
  use Ecto.Migration

  def change do
    create table(:desktop_auth_requests) do
      add :code_challenge, :string, null: false
      add :redirect_uri, :text, null: false
      add :state, :string, null: false
      add :code_hash, :binary
      add :user_id, references(:users, on_delete: :delete_all)
      add :expires_at, :utc_datetime_usec, null: false
      add :approved_at, :utc_datetime_usec
      add :consumed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:desktop_auth_requests, [:code_hash])
    create index(:desktop_auth_requests, [:expires_at])

    create table(:desktop_sessions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :revoked_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create index(:desktop_sessions, [:user_id])
    create index(:desktop_sessions, [:expires_at])

    # Retain spent refresh hashes until family expiry to detect replay, even
    # after several rotations. No authorization/refresh token is stored raw.
    create table(:desktop_refresh_tokens) do
      add :session_id, references(:desktop_sessions, on_delete: :delete_all), null: false
      add :token_hash, :binary, null: false
      add :used_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:desktop_refresh_tokens, [:token_hash])
    create index(:desktop_refresh_tokens, [:session_id])
  end
end
