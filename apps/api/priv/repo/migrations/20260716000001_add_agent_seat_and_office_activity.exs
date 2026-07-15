defmodule Mokaid.Repo.Migrations.AddAgentSeatAndOfficeActivity do
  use Ecto.Migration

  def up do
    alter table(:agents) do
      add :seat_index, :integer
      add :office_activity, :string
      add :office_poi_id, :string
      add :office_slot_id, :string
      add :office_activity_phase, :string
      add :office_activity_ends_at, :utc_datetime_usec
    end

    # Backfill deterministic seats per workspace for existing non-archived agents.
    execute("""
    WITH ranked AS (
      SELECT id,
             row_number() OVER (PARTITION BY workspace_id ORDER BY inserted_at ASC) - 1 AS rn
      FROM agents
      WHERE archived_at IS NULL
    )
    UPDATE agents
    SET seat_index = ranked.rn
    FROM ranked
    WHERE agents.id = ranked.id AND ranked.rn < 9
    """)

    create constraint(:agents, :seat_index_range, check: "seat_index IS NULL OR (seat_index >= 0 AND seat_index <= 8)")

    create unique_index(:agents, [:workspace_id, :seat_index],
      name: :agents_workspace_seat_index_unique,
      where: "archived_at IS NULL AND seat_index IS NOT NULL"
    )
  end

  def down do
    drop_if_exists index(:agents, [:workspace_id, :seat_index], name: :agents_workspace_seat_index_unique)
    drop_if_exists constraint(:agents, :seat_index_range)

    alter table(:agents) do
      remove :seat_index
      remove :office_activity
      remove :office_poi_id
      remove :office_slot_id
      remove :office_activity_phase
      remove :office_activity_ends_at
    end
  end
end
