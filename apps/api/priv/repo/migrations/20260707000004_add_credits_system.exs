defmodule Mokaid.Repo.Migrations.AddCreditsSystem do
  use Ecto.Migration

  def change do
    alter table(:subscriptions) do
      # Credits granted by the plan at the start of each period (reset monthly).
      add :monthly_credits, :integer, null: false, default: 0
      # Credits from the current period's plan grant still available. Purchased
      # top-up packs live in credits_balance (they never expire). Spend draws
      # from included first, then balance; balance may go negative for a task
      # already in flight (settled on the next top-up).
      add :included_credits_remaining, :integer, null: false, default: 0
      add :credits_period_start, :utc_datetime_usec

      # Auto-recharge (ElevenLabs style): buy a pack automatically when the
      # spendable balance drops below the threshold.
      add :auto_recharge_enabled, :boolean, null: false, default: false
      add :auto_recharge_pack_key, :string
      add :auto_recharge_threshold, :integer, null: false, default: 0
    end

    # Ledger of every credit movement (spend / grant / purchase / auto-recharge)
    # so the UI can show live consumption and we have a full audit trail.
    create table(:credit_transactions) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      # Negative = spend, positive = grant/purchase.
      add :amount, :integer, null: false
      add :cost_cents, :integer, null: false, default: 0
      add :balance_after, :integer, null: false, default: 0
      add :run_id, references(:task_execution_runs, on_delete: :nilify_all)
      add :agent_id, references(:agents, on_delete: :nilify_all)
      add :description, :string
      add :metadata, :map, null: false, default: %{}

      timestamps()
    end

    create index(:credit_transactions, [:workspace_id, :inserted_at])
    create index(:credit_transactions, [:run_id])
  end
end
