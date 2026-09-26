defmodule Mokaid.Repo.Migrations.AddDesktopRefreshRequestIds do
  use Ecto.Migration

  def change do
    alter table(:desktop_refresh_tokens) do
      add :refresh_request_id_hash, :binary
    end
  end
end
