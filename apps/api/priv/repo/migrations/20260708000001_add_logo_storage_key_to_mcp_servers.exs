defmodule Mokaid.Repo.Migrations.AddLogoStorageKeyToMcpServers do
  use Ecto.Migration

  def change do
    alter table(:mcp_servers) do
      add :logo_storage_key, :string
    end
  end
end
