defmodule Mokaid.Repo.Migrations.OperatorPlatformEnrichment do
  use Ecto.Migration

  def up do
    # ---- User moderation / soft lifecycle ----
    alter table(:users) do
      add :banned_at, :utc_datetime_usec
      add :banned_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :ban_reason, :text
      add :ban_expires_at, :utc_datetime_usec
      add :deletion_scheduled_at, :utc_datetime_usec
      add :anonymized_at, :utc_datetime_usec
      add :operator_notes, :text
    end

    create index(:users, [:status])
    create index(:users, [:deletion_scheduled_at], where: "anonymized_at IS NULL")
    create index(:users, [:banned_at], where: "banned_at IS NOT NULL")

    # ---- Login events ----
    create table(:user_login_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :ip_address, :string
      add :user_agent, :text
      add :auth_method, :string, null: false, default: "password"
      add :success, :boolean, null: false, default: true
      add :metadata, :map, null: false, default: %{}
      add :occurred_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:user_login_events, [:user_id, :occurred_at])
    create index(:user_login_events, [:occurred_at])

    # ---- Credit transaction operator metadata ----
    alter table(:credit_transactions) do
      add :idempotency_key, :string
      add :operator_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :reason, :text
    end

    create unique_index(:credit_transactions, [:idempotency_key],
             where: "idempotency_key IS NOT NULL"
           )

    create index(:credit_transactions, [:operator_id])

    # ---- Platform cost snapshots (provider bills) ----
    create table(:platform_cost_snapshots, primary_key: false) do
      add :id, :binary_id, primary_key: true
      # openai | anthropic | aws | internal
      add :provider, :string, null: false
      # hour | day | month
      add :granularity, :string, null: false, default: "day"
      add :period_start, :utc_datetime_usec, null: false
      add :period_end, :utc_datetime_usec, null: false
      add :amount_cents, :integer, null: false, default: 0
      add :currency, :string, null: false, default: "USD"
      # Normalized breakdown (model, line_item, service, …) — no secrets
      add :breakdown, :map, null: false, default: %{}
      # Hash of breakdown used for unique constraint
      add :breakdown_key, :string, null: false, default: "default"
      # admin_api | cost_explorer | internal_estimate
      add :source, :string, null: false, default: "admin_api"
      add :fetched_at, :utc_datetime_usec, null: false
      add :raw_payload, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:platform_cost_snapshots, [
             :provider,
             :period_start,
             :granularity,
             :breakdown_key
           ])

    create index(:platform_cost_snapshots, [:provider, :period_start])
    create index(:platform_cost_snapshots, [:period_start])

    # ---- Daily reconciliation internal vs provider ----
    create table(:cost_reconciliation_daily, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :day, :date, null: false
      add :provider, :string, null: false
      add :provider_reported_cents, :integer, null: false, default: 0
      add :internal_usage_cents, :integer, null: false, default: 0
      add :delta_cents, :integer, null: false, default: 0
      add :notes, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:cost_reconciliation_daily, [:day, :provider])
    create index(:cost_reconciliation_daily, [:day])

    # ---- Append-only platform audit (no workspace FK cascade) ----
    create table(:platform_audit_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :actor_id, :binary_id
      add :actor_email, :string
      add :actor_name, :string
      add :action, :string, null: false
      add :resource_type, :string
      add :resource_id, :binary_id
      add :workspace_id, :binary_id
      add :ip_address, :string
      add :user_agent, :text
      add :metadata, :map, null: false, default: %{}
      add :occurred_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:platform_audit_events, [:occurred_at])
    create index(:platform_audit_events, [:actor_id])
    create index(:platform_audit_events, [:action])
    create index(:platform_audit_events, [:resource_type, :resource_id])

    # Immutability: block UPDATE/DELETE on platform_audit_events
    execute("""
    CREATE OR REPLACE FUNCTION platform_audit_events_immutable()
    RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'platform_audit_events is append-only';
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER platform_audit_events_no_update
      BEFORE UPDATE OR DELETE ON platform_audit_events
      FOR EACH ROW EXECUTE PROCEDURE platform_audit_events_immutable();
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS platform_audit_events_no_update ON platform_audit_events")
    execute("DROP FUNCTION IF EXISTS platform_audit_events_immutable()")

    drop table(:platform_audit_events)
    drop table(:cost_reconciliation_daily)
    drop table(:platform_cost_snapshots)

    drop_if_exists index(:credit_transactions, [:operator_id])
    drop_if_exists index(:credit_transactions, [:idempotency_key])

    alter table(:credit_transactions) do
      remove :idempotency_key
      remove :operator_id
      remove :reason
    end

    drop table(:user_login_events)

    drop_if_exists index(:users, [:banned_at])
    drop_if_exists index(:users, [:deletion_scheduled_at])
    drop_if_exists index(:users, [:status])

    alter table(:users) do
      remove :banned_at
      remove :banned_by_id
      remove :ban_reason
      remove :ban_expires_at
      remove :deletion_scheduled_at
      remove :anonymized_at
      remove :operator_notes
    end
  end
end
