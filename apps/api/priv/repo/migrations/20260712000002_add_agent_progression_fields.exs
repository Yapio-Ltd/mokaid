defmodule Mokaid.Repo.Migrations.AddAgentProgressionFields do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :level, :integer, default: 1, null: false
      add :xp, :integer, default: 0, null: false
      add :xp_for_next_level, :integer, default: 100, null: false
      add :missions_completed, :integer, default: 0, null: false
    end
  end
end
