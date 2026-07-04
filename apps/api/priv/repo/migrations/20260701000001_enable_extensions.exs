defmodule Mokaid.Repo.Migrations.EnableExtensions do
  use Ecto.Migration

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\""
    execute "CREATE EXTENSION IF NOT EXISTS citext"
    execute "CREATE EXTENSION IF NOT EXISTS vector"
  end

  def down do
    execute "DROP EXTENSION IF EXISTS vector"
    execute "DROP EXTENSION IF EXISTS citext"
    execute "DROP EXTENSION IF EXISTS \"uuid-ossp\""
  end
end
