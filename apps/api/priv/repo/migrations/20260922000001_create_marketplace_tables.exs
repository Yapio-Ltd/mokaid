defmodule Mokaid.Repo.Migrations.CreateMarketplaceTables do
  use Ecto.Migration

  def change do
    create table(:stripe_connect_accounts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all), null: false
      add :stripe_account_id, :string, null: false
      add :charges_enabled, :boolean, null: false, default: false
      add :payouts_enabled, :boolean, null: false, default: false
      add :details_submitted, :boolean, null: false, default: false
      add :country, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:stripe_connect_accounts, [:workspace_id])
    create unique_index(:stripe_connect_accounts, [:stripe_account_id])

    create table(:marketplace_listings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all), null: false
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :created_by_member_id, references(:workspace_members, type: :binary_id, on_delete: :nilify_all)
      add :mode, :string, null: false
      add :rent_billing, :string
      add :fixed_days, :integer
      add :price_cents, :integer, null: false
      add :currency, :string, null: false, default: "usd"
      add :title, :string
      add :description, :text
      add :status, :string, null: false, default: "active"
      add :knowledge_item_count, :integer, null: false, default: 0
      add :agent_level_snapshot, :integer, null: false, default: 10

      timestamps(type: :utc_datetime_usec)
    end

    create index(:marketplace_listings, [:status, :mode])
    create index(:marketplace_listings, [:workspace_id])
    create unique_index(:marketplace_listings, [:agent_id],
             where: "status IN ('active', 'paused')",
             name: :marketplace_listings_one_open_per_agent
           )

    create table(:marketplace_orders, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :listing_id, references(:marketplace_listings, type: :binary_id, on_delete: :restrict), null: false
      add :seller_workspace_id, references(:workspaces, type: :binary_id, on_delete: :restrict), null: false
      add :buyer_workspace_id, references(:workspaces, type: :binary_id, on_delete: :restrict), null: false
      add :buyer_member_id, references(:workspace_members, type: :binary_id, on_delete: :nilify_all)
      add :buyer_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :source_agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all)
      add :cloned_agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all)
      add :mode, :string, null: false
      add :rent_billing, :string
      add :fixed_days, :integer
      add :amount_cents, :integer, null: false
      add :application_fee_cents, :integer, null: false, default: 0
      add :currency, :string, null: false, default: "usd"
      add :status, :string, null: false, default: "pending"
      add :stripe_checkout_session_id, :string
      add :stripe_payment_intent_id, :string
      add :stripe_subscription_id, :string
      add :stripe_customer_id, :string
      add :paid_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:marketplace_orders, [:buyer_workspace_id])
    create index(:marketplace_orders, [:seller_workspace_id])
    create unique_index(:marketplace_orders, [:stripe_checkout_session_id],
             where: "stripe_checkout_session_id IS NOT NULL"
           )

    create table(:marketplace_leases, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :order_id, references(:marketplace_orders, type: :binary_id, on_delete: :delete_all), null: false
      add :listing_id, references(:marketplace_listings, type: :binary_id, on_delete: :nilify_all)
      add :seller_workspace_id, references(:workspaces, type: :binary_id, on_delete: :restrict), null: false
      add :buyer_workspace_id, references(:workspaces, type: :binary_id, on_delete: :restrict), null: false
      add :source_agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all)
      add :cloned_agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all)
      add :rent_billing, :string, null: false
      add :fixed_days, :integer
      add :status, :string, null: false, default: "active"
      add :starts_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec
      add :canceled_at, :utc_datetime_usec
      add :stripe_subscription_id, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:marketplace_leases, [:status, :expires_at])
    create index(:marketplace_leases, [:buyer_workspace_id])
    create unique_index(:marketplace_leases, [:stripe_subscription_id],
             where: "stripe_subscription_id IS NOT NULL"
           )
  end
end
